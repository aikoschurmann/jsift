const std = @import("std");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const Scanner = @import("scanner.zig");

const version = build_options.version;

/// Exit codes follow grep: 0 = match found, 1 = no match, 2 = error.
pub fn main(init: std.process.Init) u8 {
    const io = init.io;
    const allocator = init.arena.allocator();

    var args: std.ArrayList([]const u8) = .empty;
    var args_iter = std.process.Args.Iterator.initAllocator(init.minimal.args, allocator) catch return outOfMemory();
    // The first argument is the program name.
    _ = args_iter.skip();
    while (args_iter.next()) |arg| args.append(allocator, arg) catch return outOfMemory();

    const command = cli.parseArgs(allocator, args.items) catch |err| {
        const msg = switch (err) {
            error.MissingFileValue => "jsift: --file needs a path",
            error.MissingLimitValue => "jsift: --limit needs a number",
            error.InvalidLimit => "jsift: --limit must be a non-negative integer",
            error.MissingThreadsValue => "jsift: --threads needs a number",
            error.InvalidThreads => "jsift: --threads must be a positive integer",
            error.MissingFormatValue => "jsift: --format needs json, csv or tsv",
            error.InvalidCondition => "jsift: incomplete condition, expected <key> <op> <val>",
            error.GroupWithoutSelect => "jsift: GROUP BY needs a SELECT, e.g. SELECT service,count:id GROUP BY service",
            error.InvalidGroupBy => "jsift: GROUP BY needs at least one key",
            error.UnbalancedParentheses => "jsift: unbalanced parentheses",
            error.QueryTooComplex => "jsift: query too complex: it expands to more than 1024 OR'ed groups of AND'ed conditions",
            error.UnknownOperator => "jsift: unknown operator (eq, neq, gt, lt, gte, lte, has, exists, in)",
            error.InvertWithoutCondition => "jsift: --invert needs a condition to invert",
            error.UnknownOption => "jsift: unknown option (put -- before query terms that start with --)",
            error.MissingArguments => "jsift: no query given, expected a condition or SELECT",
            error.TooManyPluckFields => "jsift: too many SELECT fields (max 256)",
            error.InvalidSelectField => "jsift: aggregation needs a field, e.g. sum:balance",
            error.SelectNeedsCommas => "jsift: separate SELECT fields with commas, e.g. SELECT name,age WHERE ...",
            error.InvalidFormat => "jsift: --format must be json, csv or tsv",
            error.OutOfMemory => return outOfMemory(),
        };
        std.debug.print("{s}\n\n", .{msg});
        cli.printUsage();
        return 2;
    };

    const config = switch (command) {
        .help => {
            cli.printUsage();
            return 0;
        },
        .version => {
            var ver_buf: [64]u8 = undefined;
            var ver_writer = std.Io.File.stdout().writerStreaming(io, &ver_buf);
            ver_writer.interface.print("jsift v{s}\n", .{version}) catch {};
            ver_writer.interface.flush() catch {};
            return 0;
        },
        .run => |run_config| run_config,
    };

    // Without --file the input is stdin. A terminal would wait for typed input, so refuse it.
    if (config.files.len == 0) {
        if (std.Io.File.stdin().isTty(io) catch false) {
            std.debug.print("jsift: no input: pass --file <path> or pipe data in\n", .{});
            return 2;
        }
    }

    // A 128 KiB buffer keeps the number of write calls small.
    var stdout_buffer: [128 * 1024]u8 = undefined;
    // Streaming rather than positional, so `jsift ... >> out` appends instead of overwriting
    // the file from offset 0.
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    // The file being read when an error happened, for the message.
    var failed_path: ?[]const u8 = null;
    const matched = runQuery(allocator, config, stdout, io, &failed_path) catch |err| {
        switch (err) {
            error.WriteFailed => {
                // `WriteFailed` only says that a write failed. The OS error is kept in `err`.
                const write_err = stdout_writer.err orelse error.WriteFailed;
                // The reader went away (e.g. `jsift ... | head -1`): not an error for us.
                if (write_err == error.BrokenPipe) return 0;
                std.debug.print("jsift: write error: {s}\n", .{@errorName(write_err)});
            },
            error.NonNumericComparison => std.debug.print("jsift: gt, lt, gte and lte need a numeric value.\n", .{}),
            error.UngroupedField => std.debug.print("jsift: with GROUP BY, every plain SELECT field must be a group key.\n", .{}),
            error.InvalidKey => std.debug.print("jsift: keys can't be empty or have empty path segments.\n", .{}),
            error.FileNotFound => std.debug.print("jsift: {s}: No such file\n", .{failed_path orelse "?"}),
            else => if (failed_path) |path|
                std.debug.print("jsift: {s}: {s}\n", .{ path, @errorName(err) })
            else
                std.debug.print("jsift: {s}\n", .{@errorName(err)}),
        }
        return 2;
    };
    // grep's convention: 1 when nothing matched, 0 when something did.
    return if (matched == 0) 1 else 0;
}

fn runQuery(
    allocator: std.mem.Allocator,
    config: cli.Config,
    stdout: *std.Io.Writer,
    io: std.Io,
    failed_path: *?[]const u8,
) !usize {
    const matched = if (config.files.len > 0)
        try Scanner.searchFiles(allocator, config, stdout, io, failed_path)
    else
        try Scanner.searchStream(allocator, config, stdout, io);
    // Flush inside the `try` so a write error in the last chunk reaches the handler in `main`.
    try stdout.flush();
    return matched;
}

fn outOfMemory() u8 {
    std.debug.print("jsift: out of memory\n", .{});
    return 2;
}

test {
    _ = cli;
    _ = Scanner;
}
