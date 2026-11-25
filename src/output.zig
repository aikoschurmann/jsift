//! Writing results: selected fields as TSV, CSV or JSON, headers, and aggregations.
const std = @import("std");
const cli = @import("cli.zig");
const compile = @import("compile.zig");
const values = @import("values.zig");

const Value = values.Value;

/// Writes `text` with JSON escapes. Control characters without a short escape become \u00XX.
fn writeJsonEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0c => try writer.writeAll("\\f"),
        0...0x07, 0x0b, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
        else => try writer.writeByte(byte),
    };
}

/// `text` JSON-escaped, and wrapped in quotes when `quoted` is set.
pub fn jsonEscapeAlloc(allocator: std.mem.Allocator, text: []const u8, quoted: bool) ![]const u8 {
    var allocating: std.Io.Writer.Allocating = .init(allocator);

    if (quoted) try allocating.writer.writeByte('"');
    try writeJsonEscaped(&allocating.writer, text);
    if (quoted) try allocating.writer.writeByte('"');
    return allocating.toOwnedSlice();
}

/// A running sum. It stays exact while every value is an integer, and switches to
/// compensated (Neumaier) summation once a fraction appears, so 0.1 + 0.2 sums to 0.3.
pub const Sum = struct {
    /// Exact sum of the integers. An i128 can't overflow: it would take 2^64 values of i64.
    int: i128 = 0,
    all_int: bool = true,
    float: f64 = 0,
    /// The low-order bits that `float` lost, added back at the end.
    compensation: f64 = 0,
    count: usize = 0,

    fn add(self: *Sum, number: f64, int: ?i64) void {
        if (int) |int_value| self.int += int_value else self.all_int = false;
        const next = self.float + number;
        // An infinity would turn the compensation into nan. The sum is infinite anyway.
        if (std.math.isFinite(next)) {
            if (@abs(self.float) >= @abs(number)) {
                self.compensation += (self.float - next) + number;
            } else {
                self.compensation += (number - next) + self.float;
            }
        }
        self.float = next;
        self.count += 1;
    }

    fn total(self: Sum) Number {
        return if (self.all_int) .{ .int = self.int } else .{ .float = self.float + self.compensation };
    }

    fn mean(self: Sum) f64 {
        const sum: f64 = if (self.all_int) @floatFromInt(self.int) else self.float + self.compensation;
        return sum / @as(f64, @floatFromInt(self.count));
    }
};

/// The smallest or largest number seen so far. Integers are kept exactly, so integers above
/// 2^53 neither compare nor print rounded.
pub const Extreme = struct {
    value: f64 = 0,
    int: ?i64 = null,
    seen: bool = false,

    /// Whether `number` comes before the current value: smaller for min, larger for max.
    fn before(self: Extreme, number: f64, int: ?i64, comptime is_min: bool) bool {
        if (int != null and self.int != null) {
            return if (is_min) int.? < self.int.? else int.? > self.int.?;
        }
        return if (is_min) number < self.value else number > self.value;
    }

    fn add(self: *Extreme, number: f64, int: ?i64, comptime is_min: bool) void {
        if (!self.seen or self.before(number, int, is_min)) {
            self.* = .{ .value = number, .int = int, .seen = true };
        }
    }

    fn result(self: Extreme) Number {
        return if (self.int) |int_value| .{ .int = int_value } else .{ .float = self.value };
    }
};

/// An aggregation result, printed by `writeNumber`.
const Number = union(enum) { int: i128, float: f64 };

/// Writes a number in its shortest form: integers without a fraction (`5`, not `5.0000`),
/// other values rounded to 15 significant digits, the most an f64 holds for any decimal, so
/// float noise doesn't show (0.1 + 0.2 prints `0.3`). Very large or small magnitudes use
/// exponent notation.
fn writeNumber(writer: *std.Io.Writer, number: Number) !void {
    switch (number) {
        .int => |int_value| try writer.print("{d}", .{int_value}),
        .float => |exact| {
            if (!std.math.isFinite(exact)) return writer.print("{d}", .{exact});
            // Round to 15 significant digits by printing them and reading them back. The
            // shortest form of the result then has no digits beyond those 15.
            var digits_buf: [32]u8 = undefined;
            const digits = std.fmt.bufPrint(&digits_buf, "{e:.14}", .{exact}) catch unreachable;
            const value = std.fmt.parseFloat(f64, digits) catch unreachable;
            const magnitude = @abs(value);
            if (value == @floor(value) and magnitude < 9007199254740992.0) {
                // Whole numbers below 2^53 are exact integers. This also turns -0 into 0.
                try writer.print("{d}", .{@as(i64, @intFromFloat(value))});
            } else if (magnitude >= 1e-6 and magnitude < 1e21) {
                try writer.print("{d}", .{value});
            } else {
                try writer.print("{e}", .{value});
            }
        },
    }
}

/// The running state of one SELECT field. `raw` fields are plain values, not aggregations.
pub const AggState = union(enum) {
    /// A plain field. In a grouped query it holds the group's value for that field.
    raw: ?Value,
    count: usize,
    sum: Sum,
    min: Extreme,
    max: Extreme,
    avg: Sum,
};

/// Writes one byte inside a CSV quoted field. A quote is doubled, which is CSV's escape.
fn writeCsvByte(writer: *std.Io.Writer, byte: u8) !void {
    if (byte == '"') {
        try writer.writeAll("\"\"");
    } else {
        try writer.writeByte(byte);
    }
}

/// Parses the four hex digits of a `\u` escape, or returns null if they are missing or invalid.
fn parseHex4(hex: []const u8) ?u16 {
    if (hex.len < 4) return null;
    return std.fmt.parseInt(u16, hex[0..4], 16) catch null;
}

/// Writes the contents of a JSON string with escapes decoded, doubling quotes for CSV.
fn writeCsvUnescaped(writer: *std.Io.Writer, raw: []const u8) !void {
    var pos: usize = 0;

    while (pos < raw.len) {
        const byte = raw[pos];
        // A backslash at the very end has no escape character after it, so it is copied as is.
        if (byte != '\\' or pos + 1 == raw.len) {
            try writeCsvByte(writer, byte);
            pos += 1;
            continue;
        }

        const escape = raw[pos + 1];
        pos += 2;
        switch (escape) {
            'n' => try writer.writeByte('\n'),
            't' => try writer.writeByte('\t'),
            'r' => try writer.writeByte('\r'),
            'b' => try writer.writeByte(0x08),
            'f' => try writer.writeByte(0x0c),
            'u' => {
                // A malformed `\u` escape is kept as text. The characters after it are then
                // copied by the loop as they are.
                const unit = parseHex4(raw[pos..]) orelse {
                    try writer.writeAll("\\u");
                    continue;
                };
                pos += 4;

                var code_point: u21 = unit;
                // A high surrogate followed by an escaped low surrogate encodes one code point
                // outside the BMP. Any other surrogate is not valid UTF-8 and becomes U+FFFD.
                if (unit >= 0xd800 and unit <= 0xdbff and pos + 6 <= raw.len and
                    raw[pos] == '\\' and raw[pos + 1] == 'u')
                {
                    if (parseHex4(raw[pos + 2 ..])) |low| {
                        if (low >= 0xdc00 and low <= 0xdfff) {
                            code_point = 0x10000 + ((@as(u21, unit) - 0xd800) << 10) + (low - 0xdc00);
                            pos += 6;
                        }
                    }
                }

                var utf8: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(code_point, &utf8) catch {
                    try writer.writeAll("\u{fffd}");
                    continue;
                };
                try writer.writeAll(utf8[0..len]);
            },
            // Quotes, backslashes and slashes stand for themselves.
            else => try writeCsvByte(writer, escape),
        }
    }
}

/// Writes one CSV field. Value fields are always quoted, so commas and newlines inside them
/// need no care. Strings are JSON-decoded first.
fn writeCsvField(writer: *std.Io.Writer, value: Value) !void {
    try writer.writeByte('"');
    if (value.is_string) {
        try writeCsvUnescaped(writer, value.raw);
    } else {
        for (value.raw) |byte| try writeCsvByte(writer, byte);
    }
    try writer.writeByte('"');
}

fn writeJsonKey(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.writeByte('"');
    try writeJsonEscaped(writer, name);
    try writer.writeAll("\": ");
}

/// Writes one field value in `format`. JSON keeps a string's raw text, which still has its
/// escapes, between quotes; other values are valid JSON as they are. CSV quotes and decodes.
/// TSV writes the raw text unchanged, so string escapes stay escaped and a value can't put a
/// literal tab or newline into the row.
inline fn writeValue(value: Value, comptime format: cli.OutputFormat, writer: *std.Io.Writer) !void {
    switch (format) {
        .json => if (value.is_string) {
            try writer.writeByte('"');
            try writer.writeAll(value.raw);
            try writer.writeByte('"');
        } else {
            try writer.writeAll(value.raw);
        },
        .csv => try writeCsvField(writer, value),
        .tsv => try writer.writeAll(value.raw),
    }
}

/// Writes the SELECT fields of one matching line. A missing field is empty, or `null` in JSON.
/// With `line_number`, the row starts with it: a first column, or a `"line"` member in JSON.
pub fn printFormatted(
    results: []const ?Value,
    plucks: []const compile.CompiledPluck,
    format: cli.OutputFormat,
    line_number: ?usize,
    writer: *std.Io.Writer,
) !void {
    switch (format) {
        .json => {
            try writer.writeByte('{');
            if (line_number) |number| try writer.print("\"line\": {d}{s}", .{ number, if (results.len > 0) ", " else "" });
            for (results, plucks, 0..) |result, pluck, index| {
                if (index > 0) try writer.writeAll(", ");
                try writeJsonKey(writer, pluck.original_str);
                if (result) |value| try writeValue(value, .json, writer) else try writer.writeAll("null");
            }
            try writer.writeAll("}\n");
        },
        inline .csv, .tsv => |row_format| {
            const separator: u8 = if (row_format == .csv) ',' else '\t';
            if (line_number) |number| try writer.print("{d}{c}", .{ number, separator });
            for (results, 0..) |result, index| {
                if (index > 0) try writer.writeByte(separator);
                if (result) |value| try writeValue(value, row_format, writer);
            }
            try writer.writeByte('\n');
        },
    }
}

/// Writes one aggregation value. An aggregation with nothing folded in has no value: it is
/// `null` in JSON (`with_nulls`) and an empty field in TSV and CSV. A sum of nothing is 0.
inline fn formatAggValue(state: AggState, comptime format: cli.OutputFormat, writer: *std.Io.Writer) !void {
    const with_nulls = format == .json;
    switch (state) {
        .raw => |maybe_value| {
            if (maybe_value) |value| {
                try writeValue(value, format, writer);
            } else if (with_nulls) {
                try writer.writeAll("null");
            }
        },
        .count => |count| try writer.print("{d}", .{count}),
        .sum => |sum| try writeNumber(writer, sum.total()),
        .min, .max => |extreme| {
            if (extreme.seen) {
                try writeNumber(writer, extreme.result());
            } else if (with_nulls) {
                try writer.writeAll("null");
            }
        },
        .avg => |avg| {
            if (avg.count > 0) {
                try writeNumber(writer, .{ .float = avg.mean() });
            } else if (with_nulls) {
                try writer.writeAll("null");
            }
        },
    }
}

/// Writes the single result row of an aggregating query.
pub fn printAggregations(
    agg_states: []const AggState,
    plucks: []const compile.CompiledPluck,
    format: cli.OutputFormat,
    writer: *std.Io.Writer,
) !void {
    if (format == .json) {
        try writer.writeAll("{");
        for (agg_states, 0..) |state, index| {
            if (index > 0) try writer.writeAll(", ");
            try writeJsonKey(writer, plucks[index].original_str);
            try formatAggValue(state, .json, writer);
        }
        try writer.writeAll("}\n");
    } else if (format == .csv) {
        for (agg_states, 0..) |state, index| {
            if (index > 0) try writer.writeByte(',');
            try formatAggValue(state, .csv, writer);
        }
        try writer.writeByte('\n');
    } else {
        for (agg_states, 0..) |state, index| {
            if (index > 0) try writer.writeByte('\t');
            try formatAggValue(state, .tsv, writer);
        }
        try writer.writeByte('\n');
    }
}

/// Writes the column names, if --header was given and the output has columns.
pub fn printHeader(plan: *const compile.CompiledPlan, writer: *std.Io.Writer) !void {
    // JSON output carries field names in every object, so a header line would only corrupt it.
    if (!plan.header or plan.pluck.len == 0 or plan.count_only or plan.format == .json) return;

    if (plan.line_numbers) try writer.writeAll(if (plan.format == .csv) "line," else "line\t");
    for (plan.pluck, 0..) |pluck, index| {
        if (plan.format == .csv) {
            if (index > 0) try writer.writeByte(',');
            // Unlike value fields, header names are quoted only when they need it.
            if (std.mem.findAny(u8, pluck.original_str, ",\"\n") != null) {
                try writeCsvField(writer, .{ .raw = pluck.original_str, .is_string = false });
            } else {
                try writer.writeAll(pluck.original_str);
            }
        } else {
            if (index > 0) try writer.writeByte('\t');
            try writer.writeAll(pluck.original_str);
        }
    }
    try writer.writeByte('\n');
}

/// Folds one value into an aggregation. A `null` value is skipped by every aggregation.
/// Non-numeric values are skipped by sum, min, max and avg, but `count` counts them.
pub fn accumulate(state: *AggState, value: Value, scratch: *values.Scratch) !void {
    if (!value.is_string and std.mem.eql(u8, value.raw, "null")) return;

    switch (state.*) {
        .raw => {},
        .count => |*count| count.* += 1,
        .sum, .min, .max, .avg => {
            // A string only needs decoding when it has a backslash in it.
            const escaped = std.mem.findScalar(u8, value.raw, '\\') != null;
            const text = if (value.is_string)
                try values.stringText(.{ .raw = value.raw, .escaped = escaped }, scratch)
            else
                value.raw;
            const number = values.parseNumber(text) orelse return;
            const int = values.parseFastInt(text);

            switch (state.*) {
                .sum, .avg => |*sum| sum.add(number, int),
                .min => |*extreme| extreme.add(number, int, true),
                .max => |*extreme| extreme.add(number, int, false),
                .raw, .count => unreachable,
            }
        },
    }
}
