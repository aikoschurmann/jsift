//! Command-line parsing: options and the query (SELECT fields, WHERE conditions).
const std = @import("std");

pub const max_pluck_fields = 256;

pub const Operator = enum { eq, neq, gt, lt, gte, lte, has, exists, in_op };
pub const Condition = struct {
    key: []const u8,
    val: []const u8,
    op: Operator,
    negated: bool = false,
};
pub const ConditionGroup = struct {
    conditions: []Condition,
};
pub const OutputFormat = enum { tsv, csv, json };
pub const PluckType = enum { raw, count, sum, min, max, avg };
pub const PluckField = struct {
    key: []const u8,
    ptype: PluckType,
    original_str: []const u8,
};
pub const Config = struct {
    file_path: ?[]const u8 = null,
    groups: []ConditionGroup,
    pluck: []PluckField,
    /// GROUP BY keys: one aggregation row per distinct combination of their values.
    group_by: []const []const u8 = &.{},
    format: OutputFormat = .tsv,
    limit: ?usize = null,
    count_only: bool = false,
    header: bool = false,
    /// Evaluate on the raw bytes only, without the exact parse.
    fast: bool = false,
    /// Rule lines out with the byte-level search before parsing. Only turned off by tests.
    prefilter: bool = true,
};
pub const Command = union(enum) {
    help,
    version,
    run: Config,
};

pub fn printUsage() void {
    std.debug.print(
        \\jsift - search JSONL with SIMD
        \\
        \\Usage: jsift [--file <path>] [--format json|csv|tsv] [SELECT <fields> WHERE] <key> <op> <val> [AND/OR ...] [GROUP BY <keys>]
        \\
        \\Options:
        \\  --file <path>       Path to JSONL file (reads from stdin if omitted)
        \\  --format <type>     Output format: tsv (default), csv, or json
        \\  --count, -c         Print only the count of matching lines
        \\  --header            Print column header row (for TSV/CSV with SELECT)
        \\  --limit <n>         Stop after n matches
        \\  --fast              Match on raw bytes only: faster, but approximate (keys at any depth,
        \\                      no escape decoding, no validation)
        \\  --help, -h          Show this help message
        \\  --version, -V       Show version
        \\  --                  Treat all following arguments as query terms
        \\
        \\Query Syntax:
        \\  Operators: eq, neq, gt, lt, gte, lte, has, exists, in
        \\  Types:     Auto-detected. Use 's:' for strings or 'n:' for numbers to force types.
        \\  NOT:       Negate any condition with NOT before the key  (e.g. NOT level eq debug)
        \\  exists:    Check key presence only, no value needed       (e.g. error exists)
        \\  Paths:     Keys are top-level; use dots for nested keys   (e.g. user.id eq 5, a\.b for a literal dot)
        \\  AND / OR:  Chain conditions                               (e.g. level eq error AND code gt 500)
        \\  ( ):       Group; AND binds tighter than OR otherwise     (e.g. '(' level eq error OR level eq warn ')' AND code gt 500)
        \\  Aggregations: count:field, sum:field, min:field, max:field, avg:field
        \\  GROUP BY:  One aggregate row per value, at the end         (e.g. SELECT svc,count:id GROUP BY svc)
        \\
        \\Exit Codes:
        \\  0  At least one match found
        \\  1  No matches found
        \\  2  Error
        \\
        \\Examples:
        \\  jsift --file logs.jsonl level eq error
        \\  jsift --file logs.jsonl level in error,critical,warn
        \\  jsift --file data.jsonl SELECT name,age
        \\  cat data.jsonl | jsift SELECT name,sum:balance WHERE active eq b:true
        \\
    , .{});
}

fn parseOp(op_str: []const u8) ?Operator {
    if (std.ascii.eqlIgnoreCase(op_str, "eq")) return .eq;
    if (std.ascii.eqlIgnoreCase(op_str, "neq")) return .neq;
    if (std.ascii.eqlIgnoreCase(op_str, "gt")) return .gt;
    if (std.ascii.eqlIgnoreCase(op_str, "lt")) return .lt;
    if (std.ascii.eqlIgnoreCase(op_str, "gte")) return .gte;
    if (std.ascii.eqlIgnoreCase(op_str, "lte")) return .lte;
    if (std.ascii.eqlIgnoreCase(op_str, "has")) return .has;
    if (std.ascii.eqlIgnoreCase(op_str, "exists")) return .exists;
    if (std.ascii.eqlIgnoreCase(op_str, "in")) return .in_op;
    return null;
}

const SelectClause = struct {
    fields: []PluckField,
    /// Token index just after the SELECT clause, including the WHERE keyword if present.
    next_token: usize,
};

/// Parses the comma-separated fields after SELECT, up to WHERE or the end of the tokens.
/// A field is a key, or an aggregation such as `sum:balance`.
fn parseSelectClause(
    allocator: std.mem.Allocator,
    tokens: []const []const u8,
    start: usize,
) !SelectClause {
    var pluck_keys: std.ArrayList(PluckField) = .empty;
    var token_index = start;

    while (token_index < tokens.len and !std.ascii.eqlIgnoreCase(tokens[token_index], "where")) : (token_index += 1) {
        var fields = std.mem.splitScalar(u8, tokens[token_index], ',');
        while (fields.next()) |field| {
            // Empty items, as in `name,,age`, are skipped.
            if (field.len == 0) continue;

            const ptype, const key = parseSelectField(field);
            if (key.len == 0) return error.InvalidSelectField;
            try pluck_keys.append(allocator, .{ .key = key, .ptype = ptype, .original_str = field });
        }
    }

    // SELECT with no fields before WHERE or the end.
    if (token_index == start) return error.MissingArguments;

    if (token_index < tokens.len and std.ascii.eqlIgnoreCase(tokens[token_index], "where")) {
        token_index += 1;
    }

    const fields = try pluck_keys.toOwnedSlice(allocator);
    if (fields.len > max_pluck_fields) return error.TooManyPluckFields;
    return .{ .fields = fields, .next_token = token_index };
}

/// Parses the comma-separated keys after GROUP BY, which may be spread over several tokens
/// (`GROUP BY a,b` or `GROUP BY a, b`).
fn parseGroupKeys(allocator: std.mem.Allocator, tokens: []const []const u8) ![]const []const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    for (tokens) |token| {
        var items = std.mem.splitScalar(u8, token, ',');
        while (items.next()) |key| {
            if (key.len > 0) try keys.append(allocator, key);
        }
    }
    if (keys.items.len == 0) return error.InvalidGroupBy;
    if (keys.items.len > max_pluck_fields) return error.TooManyPluckFields;
    return keys.toOwnedSlice(allocator);
}

/// Splits an aggregation prefix (`count:`, `sum:`, ...) off a SELECT field.
fn parseSelectField(field: []const u8) struct { PluckType, []const u8 } {
    inline for (.{ .count, .sum, .min, .max, .avg }) |ptype| {
        const prefix = @tagName(ptype) ++ ":";
        if (std.ascii.startsWithIgnoreCase(field, prefix)) return .{ ptype, field[prefix.len..] };
    }
    return .{ .raw, field };
}

/// The most OR groups a WHERE clause may expand to. Parentheses are multiplied out into
/// OR'ed groups of AND'ed conditions, which can grow exponentially:
/// `(a OR b) AND (c OR d) AND ...` doubles with every factor.
pub const max_groups = 1024;

/// A WHERE clause as parsed, before it is flattened into groups.
const Expr = union(enum) {
    condition: Condition,
    all: []const Expr,
    any: []const Expr,
    not: *const Expr,
};

/// The query tokens, read one at a time. Parentheses may stand alone (`(`, `)`) or be
/// attached to a token: leading ones to a key (`(level`), trailing ones to a value or to
/// `exists` (`500)`). Trailing ones are only split off while a parenthesis is open, so a
/// value such as `(none)` outside parentheses stays as it is.
const TokenStream = struct {
    tokens: []const []const u8,
    index: usize = 0,
    /// Leading `(` already consumed from `tokens[index]`.
    front: usize = 0,
    /// `)` split off the end of the previous token and not consumed yet.
    closes: usize = 0,
    /// Parentheses currently open.
    depth: usize = 0,

    fn peek(self: *const TokenStream) ?[]const u8 {
        if (self.closes > 0) return ")";
        if (self.index >= self.tokens.len) return null;
        return self.tokens[self.index][self.front..];
    }

    /// The token after the current one, for the keyword check in `isKeyword`.
    fn peekSecond(self: *const TokenStream) ?[]const u8 {
        if (self.closes > 0 or self.index + 1 >= self.tokens.len) return null;
        return self.tokens[self.index + 1];
    }

    fn advance(self: *TokenStream) void {
        if (self.closes > 0) {
            self.closes -= 1;
        } else {
            self.index += 1;
            self.front = 0;
        }
    }

    /// Takes the current token, splitting off as many trailing `)` as there are open
    /// parentheses. They are returned as separate tokens afterwards.
    fn takeClosing(self: *TokenStream) []const u8 {
        const token = self.peek().?;
        var end = token.len;
        while (end > 0 and token[end - 1] == ')' and token.len - end < self.depth) end -= 1;
        self.advance();
        self.closes = token.len - end;
        return token[0..end];
    }
};

/// Whether `token`, followed by `next`, is the keyword `word`. `NOT` and `SELECT` directly
/// followed by an operator are keys instead, so `select eq 1` and `not exists` are conditions.
fn isKeyword(token: []const u8, next: ?[]const u8, comptime word: []const u8) bool {
    if (!std.ascii.eqlIgnoreCase(token, word)) return false;
    const following = next orelse return true;
    return parseOp(std.mem.trimEnd(u8, following, ")")) == null;
}

fn parseOr(allocator: std.mem.Allocator, stream: *TokenStream) error{ OutOfMemory, InvalidCondition, UnknownOperator, UnbalancedParentheses }!Expr {
    var items: std.ArrayList(Expr) = .empty;
    try items.append(allocator, try parseAnd(allocator, stream));
    while (stream.peek()) |token| {
        if (!std.ascii.eqlIgnoreCase(token, "or")) break;
        stream.advance();
        try items.append(allocator, try parseAnd(allocator, stream));
    }
    return if (items.items.len == 1) items.items[0] else .{ .any = try items.toOwnedSlice(allocator) };
}

fn parseAnd(allocator: std.mem.Allocator, stream: *TokenStream) !Expr {
    var items: std.ArrayList(Expr) = .empty;
    try items.append(allocator, try parseUnary(allocator, stream));
    while (stream.peek()) |token| {
        if (!std.ascii.eqlIgnoreCase(token, "and")) break;
        stream.advance();
        try items.append(allocator, try parseUnary(allocator, stream));
    }
    return if (items.items.len == 1) items.items[0] else .{ .all = try items.toOwnedSlice(allocator) };
}

/// `NOT <unary>`, `( <or> )` or a condition `<key> <op> [<val>]`.
fn parseUnary(allocator: std.mem.Allocator, stream: *TokenStream) !Expr {
    // Running out of tokens here means a trailing AND, OR, NOT or `(`.
    const token = stream.peek() orelse return error.InvalidCondition;

    if (stream.front == 0 and isKeyword(token, stream.peekSecond(), "not")) {
        stream.advance();
        const inner = try allocator.create(Expr);
        inner.* = try parseUnary(allocator, stream);
        return .{ .not = inner };
    }

    if (token.len > 0 and token[0] == '(') {
        if (token.len == 1) stream.advance() else stream.front += 1;
        stream.depth += 1;
        const inner = try parseOr(allocator, stream);
        const close = stream.peek() orelse return error.UnbalancedParentheses;
        if (!std.mem.eql(u8, close, ")")) return error.InvalidCondition;
        stream.advance();
        stream.depth -= 1;
        return inner;
    }
    // A `)` where a condition should start: an empty `()` inside parentheses, else a stray one.
    if (std.mem.eql(u8, token, ")")) return if (stream.depth > 0) error.InvalidCondition else error.UnbalancedParentheses;

    const key = token;
    stream.advance();
    const op_token = stream.peek() orelse return error.InvalidCondition;
    // `exists` takes no value, so closing parentheses may be attached to it.
    const op_trimmed = std.mem.trimEnd(u8, op_token, ")");
    if (op_trimmed.len < op_token.len and parseOp(op_trimmed) == .exists) {
        _ = stream.takeClosing();
        return .{ .condition = .{ .key = key, .val = "", .op = .exists } };
    }
    const op = parseOp(op_token) orelse return error.UnknownOperator;
    stream.advance();
    if (op == .exists) return .{ .condition = .{ .key = key, .val = "", .op = op } };

    // Every operator except `exists` takes a value.
    if (stream.peek() == null) return error.InvalidCondition;
    return .{ .condition = .{ .key = key, .val = stream.takeClosing(), .op = op } };
}

/// Flattens `expr` into OR'ed groups of AND'ed conditions. NOT is pushed down to the
/// conditions with De Morgan's laws, and AND is multiplied out over OR.
fn toGroups(allocator: std.mem.Allocator, expr: Expr, negated: bool) error{ OutOfMemory, QueryTooComplex }![]const []const Condition {
    switch (expr) {
        .condition => |condition| {
            var flipped = condition;
            flipped.negated = condition.negated != negated;
            const conditions = try allocator.dupe(Condition, &.{flipped});
            return allocator.dupe([]const Condition, &.{conditions});
        },
        .not => |inner| return toGroups(allocator, inner.*, !negated),
        .all, .any => |items| {
            // NOT (a AND b) is (NOT a) OR (NOT b), and NOT (a OR b) is (NOT a) AND (NOT b).
            const is_or = (expr == .any) != negated;
            var result: std.ArrayList([]const Condition) = .empty;
            if (is_or) {
                for (items) |item| try result.appendSlice(allocator, try toGroups(allocator, item, negated));
                if (result.items.len > max_groups) return error.QueryTooComplex;
                return result.toOwnedSlice(allocator);
            }
            // AND: every combination of one group from each item.
            try result.append(allocator, &.{});
            for (items) |item| {
                const item_groups = try toGroups(allocator, item, negated);
                if (result.items.len * item_groups.len > max_groups) return error.QueryTooComplex;
                var product: std.ArrayList([]const Condition) = .empty;
                for (result.items) |left| {
                    for (item_groups) |right| {
                        try product.append(allocator, try std.mem.concat(allocator, Condition, &.{ left, right }));
                    }
                }
                result = product;
            }
            return result.toOwnedSlice(allocator);
        },
    }
}

/// Parses the WHERE clause: conditions `[NOT] <key> <op> [<val>]` joined by AND and OR,
/// with parentheses. AND binds tighter than OR. The result is a list of OR'ed groups whose
/// conditions are AND'ed, which is the form the search evaluates.
fn parseWhereClause(allocator: std.mem.Allocator, tokens: []const []const u8, start: usize) ![]ConditionGroup {
    if (start == tokens.len) return &.{};
    var stream: TokenStream = .{ .tokens = tokens[start..] };
    const expr = try parseOr(allocator, &stream);
    if (stream.peek()) |token| {
        return if (std.mem.eql(u8, token, ")")) error.UnbalancedParentheses else error.InvalidCondition;
    }

    const flat = try toGroups(allocator, expr, false);
    const groups = try allocator.alloc(ConditionGroup, flat.len);
    for (flat, groups) |conditions, *group| group.* = .{ .conditions = try allocator.dupe(Condition, conditions) };
    return groups;
}

/// Parses the arguments after the program name. `allocator` should be an arena: nothing
/// allocated here is freed individually.
pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Command {
    var tokens: std.ArrayList([]const u8) = .empty;
    var config = Config{ .groups = undefined, .pluck = &[_]PluckField{} };

    // Options may appear anywhere. Everything else is a query token, in order.
    var arg_index: usize = 0;
    while (arg_index < args.len) : (arg_index += 1) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "--")) {
            // Everything after `--` is a query token, even if it starts with dashes.
            try tokens.appendSlice(allocator, args[arg_index + 1 ..]);
            break;
        } else if (std.mem.eql(u8, arg, "--file")) {
            arg_index += 1;
            if (arg_index == args.len) return error.MissingFileValue;
            // Only one input is read. A second --file would silently replace the first.
            if (config.file_path != null) return error.DuplicateFile;
            config.file_path = args[arg_index];
        } else if (std.mem.eql(u8, arg, "--limit")) {
            arg_index += 1;
            if (arg_index == args.len) return error.MissingLimitValue;
            config.limit = std.fmt.parseInt(usize, args[arg_index], 10) catch return error.InvalidLimit;
        } else if (std.mem.eql(u8, arg, "--format")) {
            arg_index += 1;
            if (arg_index == args.len) return error.MissingFormatValue;
            config.format = for (std.enums.values(OutputFormat)) |format| {
                if (std.ascii.eqlIgnoreCase(args[arg_index], @tagName(format))) break format;
            } else return error.InvalidFormat;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            return .version;
        } else if (std.mem.eql(u8, arg, "-v")) {
            // grep's -v inverts the match. Rejected rather than read as a key, so it can't
            // silently do something else.
            return error.InvertOption;
        } else if (std.mem.eql(u8, arg, "--count") or std.mem.eql(u8, arg, "-c")) {
            config.count_only = true;
        } else if (std.mem.eql(u8, arg, "--header")) {
            config.header = true;
        } else if (std.mem.eql(u8, arg, "--fast")) {
            config.fast = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownOption;
        } else {
            try tokens.append(allocator, arg);
        }
    }

    // GROUP BY, if present, comes last. Everything after it is the group keys.
    var query_tokens = tokens.items;
    for (query_tokens, 0..) |token, index| {
        if (index + 1 < query_tokens.len and std.ascii.eqlIgnoreCase(token, "group") and
            std.ascii.eqlIgnoreCase(query_tokens[index + 1], "by"))
        {
            config.group_by = try parseGroupKeys(allocator, query_tokens[index + 2 ..]);
            query_tokens = query_tokens[0..index];
            break;
        }
    }

    // SELECT, if present, comes first among the query tokens.
    var next_token: usize = 0;
    if (next_token < query_tokens.len and isKeyword(
        query_tokens[next_token],
        if (next_token + 1 < query_tokens.len) query_tokens[next_token + 1] else null,
        "select",
    )) {
        next_token += 1;
        const select = try parseSelectClause(allocator, query_tokens, next_token);
        config.pluck = select.fields;
        next_token = select.next_token;
    }
    if (config.group_by.len > 0 and config.pluck.len == 0) return error.GroupWithoutSelect;

    config.groups = try parseWhereClause(allocator, query_tokens, next_token);

    if (config.groups.len == 0 and config.pluck.len == 0 and !config.count_only) {
        return error.MissingArguments;
    }
    return .{ .run = config };
}

test "parseArgs flags and errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.InvalidLimit, parseArgs(allocator, &.{ "--limit", "x", "a", "exists" }));
    try std.testing.expectError(error.UnknownOption, parseArgs(allocator, &.{ "--lmit", "5", "a", "exists" }));
    try std.testing.expectError(error.InvalidSelectField, parseArgs(allocator, &.{ "SELECT", "sum:" }));
    try std.testing.expectError(error.InvalidCondition, parseArgs(allocator, &.{ "a", "exists", "AND" }));
    try std.testing.expectError(error.InvalidCondition, parseArgs(allocator, &.{ "a", "exists", "AND", "NOT" }));
    try std.testing.expectError(error.MissingArguments, parseArgs(allocator, &.{}));
    try std.testing.expectEqual(Command.help, try parseArgs(allocator, &.{ "a", "--help" }));
    try std.testing.expectEqual(Command.version, try parseArgs(allocator, &.{ "-V", "a", "exists" }));
    try std.testing.expectError(error.DuplicateFile, parseArgs(allocator, &.{ "--file", "a", "--file", "b", "a", "exists" }));
    try std.testing.expectError(error.InvertOption, parseArgs(allocator, &.{ "-v", "a", "exists" }));

    // `--` lets query terms start with dashes; negative numbers never needed it.
    const dashed = (try parseArgs(allocator, &.{ "--", "--weird", "eq", "--x" })).run;
    try std.testing.expectEqualStrings("--weird", dashed.groups[0].conditions[0].key);
    const negative = (try parseArgs(allocator, &.{ "balance", "gt", "-5" })).run;
    try std.testing.expectEqualStrings("-5", negative.groups[0].conditions[0].val);

    const not_not = (try parseArgs(allocator, &.{ "NOT", "NOT", "a", "exists" })).run;
    try std.testing.expect(!not_not.groups[0].conditions[0].negated);

    // Keywords directly followed by an operator are keys.
    const select_key = (try parseArgs(allocator, &.{ "select", "eq", "1" })).run;
    try std.testing.expectEqual(@as(usize, 0), select_key.pluck.len);
    try std.testing.expectEqualStrings("select", select_key.groups[0].conditions[0].key);
    const not_key = (try parseArgs(allocator, &.{ "not", "exists" })).run;
    try std.testing.expectEqualStrings("not", not_key.groups[0].conditions[0].key);
    try std.testing.expect(!not_key.groups[0].conditions[0].negated);
    const not_not_key = (try parseArgs(allocator, &.{ "NOT", "not", "eq", "1" })).run;
    try std.testing.expectEqualStrings("not", not_not_key.groups[0].conditions[0].key);
    try std.testing.expect(not_not_key.groups[0].conditions[0].negated);
    const where_key = (try parseArgs(allocator, &.{ "SELECT", "a", "WHERE", "where", "eq", "1" })).run;
    try std.testing.expectEqualStrings("where", where_key.groups[0].conditions[0].key);

    const grouped = (try parseArgs(allocator, &.{ "SELECT", "s,count:x", "WHERE", "a", "exists", "GROUP", "BY", "s,", "t" })).run;
    try std.testing.expectEqual(@as(usize, 2), grouped.group_by.len);
    try std.testing.expectEqualStrings("t", grouped.group_by[1]);
    try std.testing.expectEqual(@as(usize, 1), grouped.groups.len);
    const grouped_no_where = (try parseArgs(allocator, &.{ "select", "group,count:x", "group", "by", "group" })).run;
    try std.testing.expectEqualStrings("group", grouped_no_where.group_by[0]);
    try std.testing.expectEqualStrings("group", grouped_no_where.pluck[0].key);
    try std.testing.expectError(error.GroupWithoutSelect, parseArgs(allocator, &.{ "a", "exists", "GROUP", "BY", "s" }));
    try std.testing.expectError(error.InvalidGroupBy, parseArgs(allocator, &.{ "SELECT", "count:x", "GROUP", "BY" }));

    const limit0 = (try parseArgs(allocator, &.{ "--limit", "0", "a", "exists" })).run;
    try std.testing.expectEqual(@as(?usize, 0), limit0.limit);
}

/// Renders the groups as `a&!b|c`, one letter per key, for compact assertions.
fn renderGroups(allocator: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    const config = (try parseArgs(allocator, args)).run;
    var out: std.ArrayList(u8) = .empty;
    for (config.groups, 0..) |group, group_index| {
        if (group_index > 0) try out.append(allocator, '|');
        for (group.conditions, 0..) |condition, index| {
            if (index > 0) try out.append(allocator, '&');
            if (condition.negated) try out.append(allocator, '!');
            try out.appendSlice(allocator, condition.key);
            if (condition.val.len > 0) {
                try out.append(allocator, '=');
                try out.appendSlice(allocator, condition.val);
            }
        }
    }
    return out.items;
}

test "parentheses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expect = std.testing.expectEqualStrings;

    // Without parentheses AND binds tighter.
    try expect("a&b|c", try renderGroups(a, &.{ "a", "exists", "AND", "b", "exists", "OR", "c", "exists" }));
    // Standalone and attached parentheses.
    try expect("a&c|b&c", try renderGroups(a, &.{ "(", "a", "exists", "OR", "b", "exists", ")", "AND", "c", "exists" }));
    try expect("a=1&c=3|b=2&c=3", try renderGroups(a, &.{ "(a", "eq", "1", "OR", "b", "eq", "2)", "AND", "c", "eq", "3" }));
    try expect("a&b", try renderGroups(a, &.{ "((a", "exists)", "AND", "(b", "exists))" }));
    // NOT is pushed down with De Morgan's laws.
    try expect("!a&!b", try renderGroups(a, &.{ "NOT", "(a", "exists", "OR", "b", "exists)" }));
    try expect("!a|!b", try renderGroups(a, &.{ "NOT", "(", "a", "exists", "AND", "b", "exists", ")" }));
    try expect("a|b", try renderGroups(a, &.{ "NOT", "NOT", "(a", "exists", "OR", "b", "exists)" }));
    // A trailing `)` is only split off while a parenthesis is open.
    try expect("a=(none)", try renderGroups(a, &.{ "a", "eq", "(none)" }));
    try expect("a=(none)", try renderGroups(a, &.{ "(a", "eq", "(none))" }));
    try expect("a=x)", try renderGroups(a, &.{ "(a", "eq", "x))" }));

    try std.testing.expectError(error.UnbalancedParentheses, parseArgs(a, &.{ "(a", "exists" }));
    try std.testing.expectError(error.UnbalancedParentheses, parseArgs(a, &.{ "a", "exists", ")" }));
    try std.testing.expectError(error.InvalidCondition, parseArgs(a, &.{ "(", ")" }));
    try std.testing.expectError(error.InvalidCondition, parseArgs(a, &.{ "a", "exists", "b", "exists" }));

    // 11 factors of two alternatives expand to 2048 groups, over the limit.
    var many: std.ArrayList([]const u8) = .empty;
    for (0..11) |index| {
        if (index > 0) try many.append(a, "AND");
        try many.appendSlice(a, &.{ "(a", "exists", "OR", "b", "exists)" });
    }
    try std.testing.expectError(error.QueryTooComplex, parseArgs(a, many.items));
}
