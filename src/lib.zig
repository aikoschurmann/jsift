//! C ABI for embedding jsift (used by the Python bindings). A query is given as the same
//! argument list the CLI takes, the input as a file path or a byte buffer, and the output
//! comes back as one buffer that the caller releases with `jsift_free_result`.
const std = @import("std");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const Scanner = @import("scanner.zig");

pub const JsiftResult = extern struct {
    /// Output bytes, exactly what the CLI would print to stdout. Null when status is an error.
    output: ?[*]u8 = null,
    output_len: usize = 0,
    /// Number of matching lines.
    matched: usize = 0,
    /// Null-terminated error message when status is `status_error`, else null.
    error_message: ?[*:0]u8 = null,
};

pub const status_ok: c_int = 0;
pub const status_error: c_int = 2;

const gpa = std.heap.c_allocator;
const version_z: [:0]const u8 = build_options.version ++ "";

export fn jsift_version() [*:0]const u8 {
    return version_z;
}

/// Runs a query. Exactly one of `file_path` and `input` is used: `file_path` when non-null,
/// otherwise `input[0..input_len]`. `args` are the CLI arguments without the program name;
/// `--help`, `--version` and `--file` are rejected (the caller passes the input instead).
/// Returns `status_ok` or `status_error`; in both cases `result` must be released with
/// `jsift_free_result`. Safe to call from several threads at once.
export fn jsift_query(
    args: [*]const [*:0]const u8,
    args_len: usize,
    file_path: ?[*:0]const u8,
    input: ?[*]const u8,
    input_len: usize,
    result: *JsiftResult,
) c_int {
    result.* = .{};
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    query(arena, args[0..args_len], file_path, if (input) |ptr| ptr[0..input_len] else "", result) catch |err| {
        result.error_message = gpa.dupeZ(u8, errorMessage(err, file_path)) catch null;
        if (result.output) |ptr| gpa.free(ptr[0..result.output_len]);
        result.output = null;
        result.output_len = 0;
        return status_error;
    };
    return status_ok;
}

export fn jsift_free_result(result: *JsiftResult) void {
    if (result.output) |ptr| gpa.free(ptr[0..result.output_len]);
    if (result.error_message) |msg| gpa.free(std.mem.span(msg));
    result.* = .{};
}

fn query(
    arena: std.mem.Allocator,
    raw_args: []const [*:0]const u8,
    file_path: ?[*:0]const u8,
    input: []const u8,
    result: *JsiftResult,
) !void {
    const args = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, args) |raw, *arg| arg.* = std.mem.span(raw);

    var config = switch (try cli.parseArgs(arena, args)) {
        .help, .version => return error.UnsupportedOption,
        .run => |config| config,
    };
    // The input comes from the caller, so leftover terms aren't files here.
    if (config.files.len > 0) return error.TrailingTerms;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    if (file_path) |path_z| {
        // Single-threaded `Io` instance: it installs no signal handlers in the host process.
        // The scanner still runs its reader on its own OS thread.
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        config.files = &.{std.mem.span(path_z)};
        var failed_path: ?[]const u8 = null;
        result.matched = try Scanner.searchFiles(arena, config, &out.writer, io, &failed_path);
    } else {
        result.matched = try Scanner.searchBytes(arena, input, config, &out.writer);
    }

    const owned = try out.toOwnedSlice();
    result.output = owned.ptr;
    result.output_len = owned.len;
}

fn errorMessage(err: anyerror, file_path: ?[*:0]const u8) []const u8 {
    return switch (err) {
        error.MissingFileValue => "--file is not supported here",
        error.TrailingTerms => "unexpected terms after the query (a missing AND or OR?); pass the input as file= or data=",
        error.MissingLimitValue => "--limit needs a number",
        error.InvalidLimit => "--limit must be a non-negative integer",
        error.MissingFormatValue => "--format needs json, csv or tsv",
        error.InvalidFormat => "--format must be json, csv or tsv",
        error.InvalidCondition => "incomplete condition, expected <key> <op> <val>",
        error.GroupWithoutSelect => "GROUP BY needs a SELECT, e.g. SELECT service,count:id GROUP BY service",
        error.InvalidGroupBy => "GROUP BY needs at least one key",
        error.UngroupedField => "with GROUP BY, every plain SELECT field must be a group key",
        error.UnbalancedParentheses => "unbalanced parentheses",
        error.QueryTooComplex => "query too complex: it expands to more than 1024 OR'ed groups of AND'ed conditions",
        error.UnknownOperator => "unknown operator (eq, neq, gt, lt, gte, lte, has, exists, in)",
        error.InvertWithoutCondition => "invert needs a condition to invert",
        error.UnknownOption => "unknown option (put -- before query terms that start with --)",
        error.MissingArguments => "no query given, expected a condition or SELECT",
        error.TooManyPluckFields => "too many SELECT fields (max 256)",
        error.InvalidSelectField => "aggregation needs a field, e.g. sum:balance",
        error.SelectNeedsCommas => "separate SELECT fields with commas, e.g. SELECT name,age WHERE ...",
        error.UnsupportedOption => "--file, --help and --version are not supported here",
        error.NonNumericComparison => "gt, lt, gte and lte need a numeric value",
        error.InvalidKey => "keys can't be empty or have empty path segments",
        error.FileNotFound => if (file_path != null) "no such file" else "file not found",
        error.OutOfMemory => "out of memory",
        else => @errorName(err),
    };
}
