//! Runs a query over a file or stdin: a reader thread fills blocks while the search scans them.
const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const json = @import("json.zig");
const finder = @import("finder.zig");
const compile = @import("compile.zig");
const values = @import("values.zig");
const match = @import("match.zig");
const output = @import("output.zig");

const block_size = 8 * 1024 * 1024;
/// Pipe input is handed over in small blocks: the consumer then scans data the reader just
/// copied while it is still in L2. Measured ~20% faster than full blocks for `cat | jsift`.
const stream_block_size = 128 * 1024;

const Search = struct {
    plan: *const compile.CompiledPlan,
    agg_states: []output.AggState,
    writer: *std.Io.Writer,
    /// Per anchor: whether it passed at the key occurrence being evaluated.
    passed: []bool,
    scratch: values.Scratch,
    /// The exact layer. After a successful `exactLineMatches`, its slots hold the line's values.
    parser: *json.Parser,
    match_count: usize = 0,
    /// GROUP BY: the aggregation states of each group, by encoded key, in first-seen order.
    /// `agg_states` is then only the template that new groups are copied from.
    group_map: std.StringArrayHashMapUnmanaged([]output.AggState) = .empty,
    /// The encoded key of the current line's group, reused between lines.
    group_key: std.ArrayList(u8) = .empty,

    /// --line-number: the block being scanned, the newlines counted in the file before
    /// `counted_pos` in it, and that position. Newlines are only counted up to a line that is
    /// printed, so lines ruled out without being split out cost one SIMD count per block.
    block: []const u8 = &.{},
    lines_seen: usize = 0,
    counted_pos: usize = 0,

    /// The 1-based line number of `line`, which lies in the current block.
    fn lineNumber(self: *Search, line: []const u8) usize {
        const line_start = @intFromPtr(line.ptr) - @intFromPtr(self.block.ptr);
        self.lines_seen += std.mem.count(u8, self.block[self.counted_pos..line_start], "\n");
        self.counted_pos = line_start;
        return self.lines_seen + 1;
    }

    /// The aggregation states of the group `line` belongs to, created on first sight. The
    /// key encodes each group value as a type byte, its length and its text, with strings
    /// decoded, so `"a"` and `"\u0061"` share a group but `"1"` and `1` don't.
    fn groupStates(self: *Search, line: []const u8) ![]output.AggState {
        const plan = self.plan;
        const gpa = self.scratch.gpa;
        var key_values: [cli.max_pluck_fields]?values.Value = undefined;
        self.group_key.clearRetainingCapacity();

        for (plan.group_keys, key_values[0..plan.group_keys.len]) |*key, *key_value| {
            key_value.* = if (plan.exact)
                values.slotValue(self.parser.slots[key.slot])
            else
                values.extractField(line, &key.finder);
            const value = key_value.* orelse {
                try self.group_key.append(gpa, 0);
                continue;
            };
            const escaped = value.is_string and std.mem.findScalar(u8, value.raw, '\\') != null;
            const text = if (value.is_string)
                try values.stringText(.{ .raw = value.raw, .escaped = escaped }, &self.scratch)
            else
                value.raw;
            try self.group_key.append(gpa, if (value.is_string) 1 else 2);
            try self.group_key.appendSlice(gpa, std.mem.asBytes(&text.len));
            try self.group_key.appendSlice(gpa, text);
        }

        const entry = try self.group_map.getOrPut(gpa, self.group_key.items);
        if (!entry.found_existing) {
            // The key and values point into the input buffer, which is reused, so they are copied.
            entry.key_ptr.* = try gpa.dupe(u8, self.group_key.items);
            const states = try gpa.dupe(output.AggState, self.agg_states);
            for (plan.pluck_group, states) |group_index, *state| {
                const value = key_values[group_index orelse continue] orelse continue;
                state.* = .{ .raw = .{ .raw = try gpa.dupe(u8, value.raw), .is_string = value.is_string } };
            }
            entry.value_ptr.* = states;
        }
        return entry.value_ptr.*;
    }

    /// Records a matching line. Returns true once the match limit is reached.
    fn emit(self: *Search, line_raw: []const u8) !bool {
        self.match_count += 1;
        const reached = if (self.plan.limit) |limit| self.match_count >= limit else false;
        const plan = self.plan;
        if (plan.count_only) return reached;

        // Strip one CR so CRLF input prints as LF.
        const line = if (std.mem.endsWith(u8, line_raw, "\r")) line_raw[0 .. line_raw.len - 1] else line_raw;
        const line_number = if (plan.line_numbers) self.lineNumber(line_raw) else null;
        if (plan.pluck.len == 0) {
            if (line_number) |number| try self.writer.print("{d}:", .{number});
            try self.writer.writeAll(line);
            try self.writer.writeByte('\n');
            return reached;
        }

        var results: [cli.max_pluck_fields]?values.Value = undefined;
        for (plan.pluck, 0..) |*pluck, index| {
            results[index] = if (plan.exact)
                // The parser already decoded the line, so the value comes from its slot.
                values.slotValue(self.parser.slots[pluck.slot])
            else if (pluck.same_as) |earlier|
                // The same field was selected before; reuse its result instead of extracting again.
                results[earlier]
            else
                values.extractField(line, &pluck.finder);
        }

        if (plan.has_aggregations) {
            const states = if (plan.group_keys.len > 0) try self.groupStates(line) else self.agg_states;
            for (results[0..plan.pluck.len], states) |result, *state| {
                if (result) |value| try output.accumulate(state, value, &self.scratch);
            }
        } else {
            try output.printFormatted(results[0..plan.pluck.len], plan.pluck, plan.format, line_number, self.writer);
        }
        return reached;
    }

    /// Processes a block of lines. Every block ends with a newline except possibly the last.
    /// Returns true once the match limit is reached.
    fn scanBlock(self: *Search, data: []const u8) !bool {
        if (!self.plan.line_numbers) return self.scanBlockLines(data);
        self.block = data;
        self.counted_pos = 0;
        const limit_reached = try self.scanBlockLines(data);
        // Count the rest of the block, so the next block continues from its last line.
        self.lines_seen += std.mem.count(u8, data[self.counted_pos..], "\n");
        return limit_reached;
    }

    fn scanBlockLines(self: *Search, data: []const u8) !bool {
        const plan = self.plan;
        if (plan.exact) {
            // Exact mode with prefilter gets the anchored scan, which may rule lines out at byte level.
            if (plan.anchors.len > 0 and plan.prefilter) return self.scanAnchored(true, data);
            return self.scanLines(true, data);
        }
        if (plan.anchors.len > 0) return self.scanAnchored(false, data);
        return self.scanLines(false, data);
    }

    /// Searches the whole block for each group's anchor and only looks at lines where one
    /// passes, so other lines are never split out or evaluated. The anchor streams are
    /// merged by position to keep matches in input order.
    ///
    /// In exact mode the search also stops at escapes that could hide an anchor, and sends
    /// those lines to the parser. Lines with a passing anchor go through a byte-level check
    /// of the other conditions first, which only rules a line out when it provably can't
    /// match.
    fn scanAnchored(self: *Search, comptime exact: bool, data: []const u8) !bool {
        const plan = self.plan;
        // Start of the first line not yet evaluated. Every line before it is done, so
        // searching for a newline never needs to look earlier than this.
        var unscanned_start: usize = 0;
        var pos: usize = 0;

        while (if (exact) plan.anchor_finder.nextOrHazard(data, pos) else plan.anchor_finder.next(data, pos)) |hit| {
            const hazard = exact and hit.key == finder.MultiFinder.hazard_key;
            var any_passed = hazard;
            if (!hazard) {
                // Check every anchor whose key was found here. An anchor passes only if its
                // value (not just its key) matches; `exists` needs the key alone.
                for (plan.anchors, plan.anchor_keys, self.passed) |anchor, needle_index, *passed| {
                    passed.* = needle_index == hit.key and
                        (anchor.op == .exists or try match.valueMatches(data[hit.hit.val_pos..], anchor, &self.scratch));
                    any_passed = any_passed or passed.*;
                }
            }
            if (!any_passed) {
                // No anchor passed here, so no line can match at this occurrence. Move past it.
                pos = hit.pos + 1;
                continue;
            }

            // The line runs from the newline before the key (or the unscanned start) to the next newline.
            const line_start = if (finder.lastNewline(data, unscanned_start, hit.hit.key_pos)) |newline|
                newline + 1
            else
                unscanned_start;
            const line_end = std.mem.findScalarPos(u8, data, hit.hit.key_pos, '\n') orelse data.len;
            const line = data[line_start..line_end];
            const matches = if (exact)
                // A hazard, or a hazard elsewhere in the line, means the bytes can't be trusted,
                // so the byte-level check is skipped and the parser decides.
                (hazard or
                    plan.hazards.inLine(line) or
                    try self.anchoredLineMatches(true, line, hit.hit.key_pos - line_start)) and
                    try self.exactLineMatches(line)
            else
                try self.anchoredLineMatches(false, line, hit.hit.key_pos - line_start);
            if (matches) {
                if (try self.emit(line)) return true;
            }

            // Continue after this line. Its newline is consumed too, so the next line starts cleanly.
            unscanned_start = @min(line_end + 1, data.len);
            pos = unscanned_start;
        }
        return false;
    }

    /// Evaluates a line whose first passing anchor occurrence has its key at `key_offset`. Groups
    /// whose anchor passed there only need their other conditions checked. Every anchor
    /// failed at all earlier occurrences, so the others only need the rest of the line searched.
    ///
    /// With `prefilter`, negated conditions are skipped: the bytes can show that a key is
    /// absent, not that the value at its path fails. The line must then be free of hazards.
    fn anchoredLineMatches(self: *Search, comptime prefilter: bool, line: []const u8, key_offset: usize) !bool {
        const plan = self.plan;
        // Groups whose anchor passed at this occurrence: only the remaining conditions are left.
        for (plan.groups, plan.anchors, self.passed) |*group, anchor, passed| {
            if (passed and try self.otherConditionsMatch(prefilter, line, group, anchor)) return true;
        }
        // Other groups: their anchor has not passed yet. Every occurrence before `key_offset` was
        // already checked for every anchor, so the anchor can only pass at or after `key_offset`.
        for (plan.groups, plan.anchors, self.passed) |*group, anchor, passed| {
            if (passed) continue;
            if (try match.nextPassing(anchor, line, key_offset, &self.scratch) == null) continue;
            if (try self.otherConditionsMatch(prefilter, line, group, anchor)) return true;
        }
        return false;
    }

    /// Checks every condition in `group` except the anchor. With `prefilter`, negated
    /// conditions are skipped too (see `anchoredLineMatches`).
    fn otherConditionsMatch(
        self: *Search,
        comptime prefilter: bool,
        line: []const u8,
        group: *const compile.CompiledGroup,
        anchor: *const compile.CompiledCondition,
    ) !bool {
        for (group.conditions) |*cond| {
            if (cond == anchor or (prefilter and cond.negated)) continue;
            // A condition fails when its result differs from its negation flag.
            if (try match.lineMatches(line, cond, &self.scratch) == cond.negated) return false;
        }
        return true;
    }

    /// Parses the line and evaluates the plan on the values at the query's paths. Invalid
    /// lines never match.
    fn exactLineMatches(self: *Search, line: []const u8) !bool {
        self.parser.parse(line) catch return false;
        const slots = self.parser.slots;
        if (self.plan.groups.len == 0) return true;
        for (self.plan.groups) |*group| {
            // `for ... else`: the else branch runs only when the loop never hit `break`, that is
            // when every condition in this group passed. A `break` means this group failed, so
            // the outer loop moves on to the next group (OR across groups, AND within one).
            for (group.conditions) |*cond| {
                // A missing key (null slot) counts as a failed condition, so its negation passes.
                const pass = if (slots[cond.slot]) |value|
                    try match.valueMatches(value, cond, &self.scratch)
                else
                    false;
                if (pass == cond.negated) break;
            } else return true;
        }
        return false;
    }

    fn scanLines(self: *Search, comptime exact: bool, data: []const u8) !bool {
        var line_start: usize = 0;
        while (line_start < data.len) {
            const newline = finder.findNewline(data, line_start);
            const line = data[line_start..newline];
            const matches = if (exact)
                try self.exactLineMatches(line)
            else
                try match.evaluatePlan(line, self.plan, &self.scratch);
            if (matches) {
                if (try self.emit(line)) return true;
            }
            line_start = newline + 1;
        }
        return false;
    }
};

const Buffer = struct { data: []u8, len: usize = 0, eof: bool = false };

/// State shared by the reader thread and the consumer. The two sides hand the buffers
/// back and forth with two semaphores:
///   - `read_sem` counts buffers the reader may fill. It starts at 2, so both are free.
///   - `fill_sem` counts filled buffers the consumer may scan.
/// Both sides walk `bufs[0]` and `bufs[1]` in the same order, so neither side has to
/// send the buffer index to the other.
const ReaderCtx = struct {
    file: std.Io.File,
    io: std.Io,
    /// Input is a pipe or terminal: hand data over as soon as nothing more is immediately
    /// readable instead of waiting for a full block.
    streaming: bool,

    bufs: [2]Buffer,

    /// Set by `abandonReader` to make the reader exit at its next check.
    stop: std.atomic.Value(bool) = .init(false),
    read_err: ?anyerror = null,

    fill_sem: std.Io.Semaphore = .{ .permits = 0 },
    read_sem: std.Io.Semaphore = .{ .permits = 2 },
};

/// True when a read on `file` would return without blocking. Always false on Windows, where
/// the check is not implemented, so data is then gathered in full blocks.
fn dataReady(file: std.Io.File) bool {
    if (builtin.os.tag == .windows) return false;
    var fds = [_]std.posix.pollfd{.{ .fd = file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    return (std.posix.poll(&fds, 0) catch return false) > 0;
}

/// Reads into `buf` until it is full, or for streaming input until a small block is
/// gathered or nothing more is immediately readable (so `tail -f` matches show up right
/// away). Always reads at least once. Returns true at end of input or on a read error.
fn fillBuffer(ctx: *ReaderCtx, buf: *Buffer, total: *usize) bool {
    while (total.* < buf.data.len) {
        const read_len = ctx.file.readStreaming(ctx.io, &.{buf.data[total.*..]}) catch |err| {
            // End of stream is a normal end of input, so only other errors are recorded.
            if (err != error.EndOfStream) ctx.read_err = err;
            return true;
        };
        if (read_len == 0) return true;

        total.* += read_len;
        // Streaming input: stop once a small block is full or the pipe has no more data right now.
        const block_full = total.* >= stream_block_size;
        if (ctx.streaming and (block_full or !dataReady(ctx.file))) return false;
    }
    return false;
}

fn growBuffer(buf: *Buffer, new_len: usize) !void {
    buf.data = try std.heap.page_allocator.realloc(buf.data, new_len);
}

fn readerThread(ctx: *ReaderCtx) void {
    const io = ctx.io;
    var buf_index: usize = 0;
    // Partial last line of the previously filled buffer. It sits past that buffer's `len`,
    // which the consumer never reads, so it can be copied straight into the next buffer.
    // The other buffer is never resized in this round, so this slice stays valid until copied.
    var carry: []const u8 = &.{};

    while (true) {
        // Wait until the consumer has released a buffer. Bail out if abandoned.
        ctx.read_sem.wait(io) catch return;
        if (ctx.stop.load(.acquire)) return;
        const buf = &ctx.bufs[buf_index];

        // Make room for the carry plus at least half a block of fresh data. Growing
        // only when this fails keeps the common path free of reallocations.
        if (carry.len + block_size / 2 > buf.data.len) {
            growBuffer(buf, carry.len + block_size) catch |err| {
                // Report the failure through the same path as end of input so the consumer
                // exits instead of waiting for a buffer that will never come.
                ctx.read_err = err;
                buf.len = 0;
                buf.eof = true;
                ctx.fill_sem.post(io);
                return;
            };
        }
        @memcpy(buf.data[0..carry.len], carry);
        var total = carry.len;
        // The carried bytes contain no newline, so the newline search can start after them.
        var scanned = carry.len;

        while (true) {
            if (fillBuffer(ctx, buf, &total)) {
                // End of input: the whole buffer, including a last line without a newline, is
                // the final block. Nothing is carried over.
                buf.len = total;
                buf.eof = true;
                ctx.fill_sem.post(io);
                return;
            }
            if (finder.lastNewline(buf.data, scanned, total)) |newline| {
                // Hand over everything up to the last newline. The rest is carried over.
                buf.len = newline + 1;
                carry = buf.data[newline + 1 .. total];
                break;
            }
            // No complete line yet: keep reading, growing the buffer if a line outgrew it.
            scanned = total;
            if (total == buf.data.len) {
                growBuffer(buf, buf.data.len * 2) catch |err| {
                    ctx.read_err = err;
                    buf.len = total;
                    buf.eof = true;
                    ctx.fill_sem.post(io);
                    return;
                };
            }
        }
        ctx.fill_sem.post(io);
        buf_index = 1 - buf_index;
    }
}

/// Returns true when all input was consumed, false when the match limit stopped it early.
fn consume(search: *Search, ctx: *ReaderCtx, io: std.Io) !bool {
    var buf_index: usize = 0;
    while (true) {
        try ctx.fill_sem.wait(io);
        const buf = &ctx.bufs[buf_index];
        const limit_reached = try search.scanBlock(buf.data[0..buf.len]);
        // Flush per block so streaming input (`tail -f`) produces output as it arrives.
        try search.writer.flush();
        if (limit_reached) return false;
        if (buf.eof) {
            if (ctx.read_err) |err| return err;
            return true;
        }
        // Release the buffer back to the reader and move to the other one.
        ctx.read_sem.post(io);
        buf_index = 1 - buf_index;
    }
}

/// Returns true when all input was consumed, false when the match limit stopped it early.
fn runSearch(search: *Search, file: std.Io.File, io: std.Io) !bool {
    // When we stop early the reader may be blocked in a read that never returns (e.g. on
    // `tail -f`), so it is detached rather than joined. Its context and buffers must then
    // outlive this function, so they come from page_allocator and are freed only after a join.
    const page_allocator = std.heap.page_allocator;
    const ctx = try page_allocator.create(ReaderCtx);
    // Regular files are read in full blocks. Pipes, terminals and sockets are streamed.
    // If stat fails, assume streaming, which is the safe choice for an unknown source.
    const streaming = if (file.stat(io)) |stat| stat.kind != .file else |_| true;

    const first_data = try page_allocator.alloc(u8, block_size);
    errdefer page_allocator.free(first_data);
    const second_data = try page_allocator.alloc(u8, block_size);

    ctx.* = .{
        .file = file,
        .io = io,
        .streaming = streaming,
        .bufs = .{ .{ .data = first_data }, .{ .data = second_data } },
    };
    const thread = try std.Thread.spawn(.{}, readerThread, .{ctx});

    // Consume on this thread. An early stop abandons the reader instead of joining it.
    const finished = consume(search, ctx, io) catch |err| {
        abandonReader(ctx, thread, io);
        return err;
    };
    if (!finished) {
        abandonReader(ctx, thread, io);
        return false;
    }

    thread.join();
    page_allocator.free(ctx.bufs[0].data);
    page_allocator.free(ctx.bufs[1].data);
    page_allocator.destroy(ctx);
    return true;
}

/// Stops the reader without waiting for it. Setting `stop` and posting `read_sem` wakes a
/// reader that is waiting for a free buffer. A reader blocked inside a read is not woken and
/// keeps running until its read returns. Its memory is intentionally not freed.
fn abandonReader(ctx: *ReaderCtx, thread: std.Thread, io: std.Io) void {
    ctx.stop.store(true, .release);
    ctx.read_sem.post(io);
    thread.detach();
}

/// Runs the query over `config.files` in order, as one input: the limit, counts and
/// aggregates span all of them. When opening or reading a file fails, `failed_path` names it.
pub fn searchFiles(
    allocator: std.mem.Allocator,
    config: cli.Config,
    writer: *std.Io.Writer,
    io: std.Io,
    failed_path: *?[]const u8,
) !usize {
    return try searchInput(allocator, .{ .files = .{ .paths = config.files, .failed = failed_path } }, config, writer, io);
}

pub fn searchStream(allocator: std.mem.Allocator, config: cli.Config, writer: *std.Io.Writer, io: std.Io) !usize {
    return try searchOpenFile(allocator, std.Io.File.stdin(), config, writer, io);
}

/// Runs the query on input already in memory (used by the library API). No reader thread.
pub fn searchBytes(allocator: std.mem.Allocator, data: []const u8, config: cli.Config, writer: *std.Io.Writer) !usize {
    return try searchInput(allocator, .{ .bytes = data }, config, writer, undefined);
}

/// Runs the query on an open file and writes its output. Returns the number of matching lines.
fn searchOpenFile(
    allocator: std.mem.Allocator,
    file: std.Io.File,
    config: cli.Config,
    writer: *std.Io.Writer,
    io: std.Io,
) !usize {
    return try searchInput(allocator, .{ .file = file }, config, writer, io);
}

const Input = union(enum) {
    file: std.Io.File,
    files: struct { paths: []const []const u8, failed: *?[]const u8 },
    bytes: []const u8,
};

fn searchInput(
    allocator: std.mem.Allocator,
    input: Input,
    config: cli.Config,
    writer: *std.Io.Writer,
    io: std.Io,
) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const plan = try compile.compilePlan(arena.allocator(), config);

    var agg_states = try arena.allocator().alloc(output.AggState, plan.pluck.len);
    for (plan.pluck, 0..) |pluck, index| {
        agg_states[index] = switch (pluck.ptype) {
            .raw => .{ .raw = null },
            .count => .{ .count = 0 },
            .sum => .{ .sum = .{} },
            .min => .{ .min = .{} },
            .max => .{ .max = .{} },
            .avg => .{ .avg = .{} },
        };
    }

    try output.printHeader(&plan, writer);

    // The parser and its slots live in the arena, so they outlive the reader thread's use.
    const parser = try arena.allocator().create(json.Parser);
    const slots = try arena.allocator().alloc(?[]const u8, plan.trie.slot_count);
    parser.* = .{ .trie = &plan.trie, .slots = slots };

    var search: Search = .{
        .plan = &plan,
        .agg_states = agg_states,
        .writer = writer,
        .passed = try arena.allocator().alloc(bool, plan.anchors.len),
        .scratch = .{ .gpa = arena.allocator() },
        .parser = parser,
    };
    // `--limit 0` can never produce output, so the reader thread is not started at all.
    const limit_zero = if (plan.limit) |limit| limit == 0 else false;
    if (!limit_zero) switch (input) {
        .file => |file| _ = try runSearch(&search, file, io),
        .files => |files| for (files.paths) |path| {
            files.failed.* = path;
            // Line numbers restart in every file, as in grep.
            search.lines_seen = 0;
            const file = try std.Io.Dir.cwd().openFile(io, path, .{});
            defer file.close(io);
            const finished = try runSearch(&search, file, io);
            files.failed.* = null;
            if (!finished) break;
        },
        .bytes => |data| _ = try search.scanBlock(data),
    };

    if (plan.count_only) {
        try writer.print("{d}\n", .{search.match_count});
    } else if (plan.group_keys.len > 0) {
        for (search.group_map.values()) |states| try output.printAggregations(states, plan.pluck, plan.format, writer);
    } else if (plan.has_aggregations) {
        try output.printAggregations(agg_states, plan.pluck, plan.format, writer);
    }
    return search.match_count;
}

const testing = std.testing;

test {
    _ = json;
    _ = finder;
    _ = values;
    _ = compile;
}

/// Runs a query on `input`, returning its output (allocated in `a`).
fn runTestQuery(a: std.mem.Allocator, input: []const u8, config: cli.Config) ![]const u8 {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.jsonl", .data = input });
    const file = try tmp.dir.openFile(io, "in.jsonl", .{});
    defer file.close(io);

    var out: std.Io.Writer.Allocating = .init(a);
    _ = try searchOpenFile(a, file, config, &out.writer, io);
    return out.written();
}

fn expectQuery(input: []const u8, args: []const []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try cli.parseArgs(a, args)).run;
    try testing.expectEqualStrings(expected, try runTestQuery(a, input, config));
    // The in-memory path (used by the library) gives the same output as the file path.
    var bytes_out: std.Io.Writer.Allocating = .init(a);
    _ = try searchBytes(a, input, config, &bytes_out.writer);
    try testing.expectEqualStrings(expected, bytes_out.written());
    if (!config.fast) {
        // The prefilter never changes the result.
        var unfiltered = config;
        unfiltered.prefilter = false;
        try testing.expectEqualStrings(expected, try runTestQuery(a, input, unfiltered));
    }
}

const demo =
    \\{"name": "Alice", "age": 25, "balance": 100.50, "active": true, "tier": 1}
    \\{"name": "Bob", "age": 30, "balance": -50.25, "active": false, "tier": 2}
    \\{"name": "Charlie", "age": 30, "balance": 0.0, "active": true, "tier": 3}
    \\{"name": "Dave", "age": 45, "balance": 5000.00, "active": true, "tier": 4}
    \\{"name": "Eve", "age": "45", "balance": "99.99", "active": "true", "tier": 5}
    \\
;

test "README examples" {
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "age", "eq", "30" }, "Bob\nCharlie\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "age", "eq", "30", "AND", "tier", "gt", "2" }, "Charlie\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "tier", "eq", "1", "OR", "tier", "eq", "5" }, "Alice\nEve\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "NOT", "age", "eq", "30" }, "Alice\nDave\nEve\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "tier", "eq", "1", "OR", "age", "eq", "30", "AND", "balance", "lt", "0" }, "Alice\nBob\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "name", "has", "li" }, "Alice\nCharlie\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "tier", "in", "1,3,5" }, "Alice\nCharlie\nEve\n");
    try expectQuery(demo, &.{ "SELECT", "name,tier", "WHERE", "balance", "lt", "100" }, "Bob\t2\nCharlie\t3\nEve\t5\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "balance", "lt", "s:100" }, "Eve\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "balance", "lt", "n:100" }, "Bob\nCharlie\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "active", "eq", "b:true" }, "Alice\nCharlie\nDave\n");
    try expectQuery(demo, &.{ "--count", "tier", "gte", "2" }, "4\n");
    try expectQuery(demo, &.{ "SELECT", "min:age,max:age", "WHERE", "active", "eq", "true" }, "25\t45\n");
    try expectQuery(demo, &.{ "--format", "json", "SELECT", "count:name,sum:balance", "WHERE", "tier", "gte", "2" }, "{\"count:name\": 4, \"sum:balance\": 5049.74}\n");
    try expectQuery(demo, &.{ "--limit", "2", "SELECT", "name", "WHERE", "active", "eq", "true" }, "Alice\nCharlie\n");
    try expectQuery(demo, &.{ "--header", "SELECT", "name,tier", "WHERE", "balance", "lt", "100" }, "name\ttier\nBob\t2\nCharlie\t3\nEve\t5\n");
}

test "json output keeps string values quoted" {
    try expectQuery(
        "{\"name\":\"nancy\",\"id\":\"42\",\"n\":7,\"t\":true,\"o\":{\"a\":[1, 2]}}\n",
        &.{ "--format", "json", "SELECT", "name,id,n,t,o,missing" },
        "{\"name\": \"nancy\", \"id\": \"42\", \"n\": 7, \"t\": true, \"o\": {\"a\":[1, 2]}, \"missing\": null}\n",
    );
}

test "json output skips header and escapes keys" {
    try expectQuery("{\"a\":1}\n", &.{ "--header", "--format", "json", "SELECT", "a" }, "{\"a\": 1}\n");
}

test "keys are only matched in key position" {
    // A value equal to the key name is not the key.
    try expectQuery("{\"msg\":\"error\"}\n", &.{ "--count", "error", "exists" }, "0\n");
    try expectQuery("{\"tag\":\"level\",\"level\":\"debug\"}\n", &.{ "--count", "level", "neq", "debug" }, "0\n");
    try expectQuery("{\"a\":\"name\",\"name\":\"Bob\"}\n", &.{ "SELECT", "name" }, "Bob\n");
    try expectQuery("{\"a\":\"name\",\"name\":\"Bob\"}\n", &.{ "SELECT", "name,a" }, "Bob\tname\n");
    // Escaped quotes inside a string don't start a key.
    try expectQuery("{\"m\":\"x \\\"k\\\": 1\",\"k\":2}\n", &.{ "SELECT", "k" }, "2\n");
    try expectQuery("{\"m\":\"x \\\"k\\\": 1\"}\n", &.{ "--count", "k", "exists" }, "0\n");
    // Whitespace around the colon is fine.
    try expectQuery("{\"k\" :  5}\n", &.{ "SELECT", "k", "WHERE", "k", "eq", "5" }, "5\n");
}

test "string eq is found by its value" {
    const lines =
        \\{"type": "Push", "n": 1}
        \\{"other":"Push","type":"Fork"}
        \\{"type":["Push"]}
        \\{"m":"\"type\":\"Push\"","type":"x"}
        \\{"Push":"type"}
        \\{"a":{"type" : "Push"}}
        \\
    ;
    try expectQuery(lines, &.{ "SELECT", "n", "WHERE", "type", "eq", "Push" }, "1\n");
    try expectQuery(lines, &.{ "--count", "type", "eq", "Push", "OR", "type", "eq", "Fork" }, "2\n");
    try expectQuery(lines, &.{ "--count", "type", "eq", "Push", "AND", "n", "eq", "1" }, "1\n");
    try expectQuery(lines, &.{ "--count", "a.type", "eq", "Push" }, "1\n");
    // --fast also finds the nested key.
    try expectQuery(lines, &.{ "--fast", "SELECT", "n", "WHERE", "type", "eq", "Push" }, "1\n\n");
    try expectQuery(lines, &.{ "--fast", "--count", "type", "eq", "Push", "OR", "type", "eq", "Fork" }, "3\n");
    try expectQuery("{\"type\"\t:\t\"Push\"}\n", &.{ "--count", "type", "eq", "Push" }, "1\n");
    // A value that could be a bare literal is still matched as one.
    try expectQuery("{\"v\":12}\n{\"v\":\"12\"}\n{\"v\":true}\n", &.{ "--count", "v", "eq", "12" }, "2\n");
    try expectQuery("{\"v\":12}\n{\"v\":\"12\"}\n{\"v\":true}\n", &.{ "--count", "v", "eq", "true", "OR", "v", "eq", "12" }, "3\n");

    // An unterminated string ending in a backslash stops at the end of its line: the newline
    // is not an escaped character, so the `{` on the next line is not part of the value.
    const cut_off = "{\"a\":\"abc\\\n{\"b\":1}\n";
    try expectQuery(cut_off, &.{ "--fast", "--count", "a", "has", "{" }, "0\n");
    try expectQuery(cut_off, &.{ "--count", "a", "has", "{" }, "0\n");
}

test "OR over several distinct keys" {
    const keys = [_][]const u8{ "a", "bb", "ccc", "dddd", "eeeee", "ffffff" };
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(testing.allocator);
    var expected3: usize = 0;
    var expected5: usize = 0;
    for (0..3000) |i| {
        // Varying padding puts the needles at every offset relative to the SIMD chunks.
        try lines.print(testing.allocator, "{{\"pad\":\"{s}\",\"{s}\":\"v{d}\"}}\n", .{ ("x" ** 40)[0 .. i % 37], keys[i % 6], i % 4 });
        const key_index = i % 6;
        if (key_index == 0 or key_index == 1 or (key_index == 2 and i % 4 == 1)) expected3 += 1;
        if (key_index < 4 or (key_index == 4 and i % 4 == 2)) expected5 += 1;
    }
    var buf: [32]u8 = undefined;
    try expectQuery(lines.items, &.{ "--count", "a", "exists", "OR", "bb", "exists", "OR", "ccc", "eq", "v1" }, try std.fmt.bufPrint(&buf, "{d}\n", .{expected3}));
    // Five needles take the Teddy path where the target supports it.
    try expectQuery(lines.items, &.{
        "--count", "a", "exists", "OR", "bb", "exists", "OR", "ccc", "exists", "OR", "dddd", "exists", "OR", "eeeee", "eq", "v2",
    }, try std.fmt.bufPrint(&buf, "{d}\n", .{expected5}));
}

test "multi-field select survives escaped quotes in arrays" {
    try expectQuery("{\"arr\":[\"a\\\"b\",\"c\"],\"x\":1,\"y\":\"z\"}\n", &.{ "SELECT", "x,y" }, "1\tz\n");
}

test "integers beyond i64 compare correctly" {
    try expectQuery("{\"id\":18446744073709551615}\n{\"id\":-1}\n", &.{ "--count", "id", "gt", "0" }, "1\n");
    try expectQuery("{\"id\":9223372036854775807}\n", &.{ "--count", "id", "gte", "9223372036854775807" }, "1\n");
}

test "non-numbers are not treated as numbers" {
    try expectQuery("{\"v\":\"nan\"}\n{\"v\":\"inf\"}\n{\"v\":\"0x10\"}\n{\"v\":3}\n", &.{ "SELECT", "sum:v,count:v" }, "3\t4\n");
    try expectQuery("{\"v\":\"inf\"}\n", &.{ "--count", "v", "gt", "0" }, "0\n");
}

test "aggregates print exact, shortest numbers" {
    // Integers stay exact past 2^53, in sums and in min/max.
    try expectQuery("{\"n\":1152921504606846976}\n{\"n\":1}\n", &.{ "SELECT", "sum:n,max:n,min:n" }, "1152921504606846977\t1152921504606846976\t1\n");
    try expectQuery("{\"n\":9007199254740993}\n{\"n\":9007199254740992}\n", &.{ "SELECT", "max:n,min:n" }, "9007199254740993\t9007199254740992\n");
    // Compensated summation: 0.1 + 0.2 is 0.3, not 0.30000000000000004.
    try expectQuery("{\"b\":0.1}\n{\"b\":0.2}\n", &.{ "SELECT", "sum:b,avg:b" }, "0.3\t0.15\n");
    try expectQuery("{\"b\":1}\n{\"b\":2}\n", &.{ "SELECT", "avg:b,min:b" }, "1.5\t1\n");
    try expectQuery("{\"b\":1}\n{\"b\":1}\n{\"b\":2}\n", &.{ "SELECT", "avg:b" }, "1.33333333333333\n");
    try expectQuery("{\"b\":2.0}\n{\"b\":-0.0}\n", &.{ "SELECT", "sum:b,min:b" }, "2\t0\n");
    try expectQuery("{\"b\":1e300}\n{\"b\":1e-9}\n", &.{ "SELECT", "max:b,min:b" }, "1e300\t1e-9\n");
    try expectQuery("{\"b\":1e400}\n{\"b\":1}\n", &.{ "SELECT", "sum:b" }, "inf\n");
}

test "GROUP BY" {
    const input =
        \\{"svc":"auth","ms":10,"ok":true}
        \\{"svc":"api","ms":30,"ok":false}
        \\{"svc":"auth","ms":20,"ok":true}
        \\{"svc":"\u0061pi","ms":50,"ok":true}
        \\{"ms":5}
        \\{"svc":1,"ms":1}
        \\{"svc":"1","ms":2}
        \\
    ;
    // Groups come out in first-seen order. Escapes are decoded for the key, so "\u0061pi" is
    // "api"; a missing key is a group of its own; "1" and 1 are different groups. A group
    // prints the spelling it was first seen with.
    try expectQuery(input, &.{ "SELECT", "svc,count:ms,sum:ms,avg:ms", "GROUP", "BY", "svc" }, "auth\t2\t30\t15\napi\t2\t80\t40\n\t1\t5\t5\n1\t1\t1\t1\n1\t1\t2\t2\n");
    try expectQuery(input, &.{ "SELECT", "svc,max:ms", "WHERE", "ok", "eq", "b:true", "GROUP", "BY", "svc" }, "auth\t20\n\\u0061pi\t50\n");
    try expectQuery(input, &.{ "--format", "json", "SELECT", "count:ms,svc", "WHERE", "svc", "exists", "GROUP", "BY", "svc" }, "{\"count:ms\": 2, \"svc\": \"auth\"}\n{\"count:ms\": 2, \"svc\": \"api\"}\n{\"count:ms\": 1, \"svc\": 1}\n{\"count:ms\": 1, \"svc\": \"1\"}\n");
    // Several keys, and keys that aren't selected.
    try expectQuery(input, &.{ "SELECT", "svc,ok,count:ms", "WHERE", "ok", "exists", "GROUP", "BY", "svc,ok" }, "auth\ttrue\t2\napi\tfalse\t1\n\\u0061pi\ttrue\t1\n");
    try expectQuery(input, &.{ "SELECT", "count:ms", "WHERE", "ok", "exists", "GROUP", "BY", "ok" }, "3\n1\n");
    // SELECT without aggregations lists the distinct values; nothing matched prints nothing.
    try expectQuery(input, &.{ "SELECT", "ok", "GROUP", "BY", "ok" }, "true\nfalse\n\n");
    try expectQuery(input, &.{ "SELECT", "svc,count:ms", "WHERE", "nope", "exists", "GROUP", "BY", "svc" }, "");
    try expectQuery(demo, &.{ "--header", "--format", "csv", "SELECT", "active,count:name", "GROUP", "BY", "active" }, "active,count:name\n\"true\",3\n\"false\",1\n\"true\",1\n");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const config = (try cli.parseArgs(arena.allocator(), &.{ "SELECT", "svc,ms", "GROUP", "BY", "svc" })).run;
    try testing.expectError(error.UngroupedField, searchBytes(arena.allocator(), input, config, undefined));
}

test "several files are read in order as one input" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // The first file has no trailing newline: its last line must still end before the next file.
    try tmp.dir.writeFile(io, .{ .sub_path = "one.jsonl", .data = "{\"n\":1}\n{\"n\":2}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "two.jsonl", .data = "{\"n\":3}\n" });
    // testing.tmpDir lives under .zig-cache/tmp in the working directory.
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/", .{tmp.sub_path});
    const one = try std.mem.concat(a, u8, &.{ dir, "one.jsonl" });
    const two = try std.mem.concat(a, u8, &.{ dir, "two.jsonl" });
    const missing = try std.mem.concat(a, u8, &.{ dir, "missing.jsonl" });

    const Case = struct { args: []const []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .args = &.{ "n", "exists", one, two }, .expected = "{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n" },
        .{ .args = &.{ "--limit", "3", "n", "gte", "2", "--file", two, one }, .expected = "{\"n\":3}\n{\"n\":2}\n" },
        .{ .args = &.{ "--limit", "2", "n", "exists", one, two }, .expected = "{\"n\":1}\n{\"n\":2}\n" },
        .{ .args = &.{ "SELECT", "sum:n,count:n", one, two }, .expected = "6\t3\n" },
    };
    for (cases) |case| {
        const config = (try cli.parseArgs(a, case.args)).run;
        var out: std.Io.Writer.Allocating = .init(a);
        var failed: ?[]const u8 = null;
        _ = try searchFiles(a, config, &out.writer, io, &failed);
        try testing.expectEqualStrings(case.expected, out.written());
        try testing.expect(failed == null);
    }

    // A missing file is reported by name, after the earlier files were searched.
    const config = (try cli.parseArgs(a, &.{ "n", "exists", one, missing, two })).run;
    var out: std.Io.Writer.Allocating = .init(a);
    var failed: ?[]const u8 = null;
    try testing.expectError(error.FileNotFound, searchFiles(a, config, &out.writer, io, &failed));
    try testing.expectEqualStrings(missing, failed.?);
}

test "line numbers" {
    try expectQuery(demo, &.{ "-n", "tier", "in", "2,4" },
        \\2:{"name": "Bob", "age": 30, "balance": -50.25, "active": false, "tier": 2}
        \\4:{"name": "Dave", "age": 45, "balance": 5000.00, "active": true, "tier": 4}
        \\
    );
    try expectQuery(demo, &.{ "-n", "--header", "SELECT", "name", "WHERE", "age", "eq", "30" }, "line\tname\n2\tBob\n3\tCharlie\n");
    try expectQuery(demo, &.{ "-n", "--format", "json", "SELECT", "name", "WHERE", "tier", "eq", "5" }, "{\"line\": 5, \"name\": \"Eve\"}\n");
    try expectQuery(demo, &.{ "-n", "--format", "csv", "SELECT", "name", "WHERE", "NOT", "active", "eq", "true" }, "2,\"Bob\"\n");
    // Counts and aggregations print no per-line rows, so -n changes nothing.
    try expectQuery(demo, &.{ "-n", "-c", "tier", "gte", "2" }, "4\n");
    try expectQuery(demo, &.{ "-n", "SELECT", "count:name" }, "5\n");
    // Invalid and skipped lines still count, and CRLF ends a line like LF.
    try expectQuery("junk\r\n{\"a\":1}\r\n\n{\"a\":2}", &.{ "-n", "a", "exists" }, "2:{\"a\":1}\n4:{\"a\":2}\n");

    // Numbers continue across blocks: a big input spans several 8 MB blocks.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var big: std.ArrayList(u8) = .empty;
    // Lines are 17 bytes: {"i":1000000000} and a newline.
    const line_count = 2 * block_size / 17;
    for (0..line_count) |index| try big.print(a, "{{\"i\":{d}}}\n", .{1_000_000_000 + index});
    const config = (try cli.parseArgs(a, &.{ "-n", "SELECT", "i", "WHERE", "i", "gte", "1000600000" })).run;
    const out = try runTestQuery(a, big.items, config);
    try testing.expect(std.mem.startsWith(u8, out, "600001\t1000600000\n"));
    try testing.expect(std.mem.endsWith(u8, out, try std.fmt.allocPrint(a, "{d}\t{d}\n", .{ line_count, 1_000_000_000 + line_count - 1 })));
}

test "invert" {
    try expectQuery(demo, &.{ "-v", "SELECT", "name", "WHERE", "age", "eq", "30", "OR", "tier", "eq", "5" }, "Alice\nDave\n");
    try expectQuery(demo, &.{ "--invert", "SELECT", "name", "WHERE", "active", "eq", "b:true", "AND", "tier", "gt", "1" }, "Alice\nBob\nEve\n");
    // Same as NOT (...). Invalid lines are skipped either way, and a missing key fails the
    // condition, so its line is printed.
    try expectQuery("{\"a\":1}\nnot json\n{\"b\":2}\n{\"a\":2}\n", &.{ "-v", "a", "eq", "1" }, "{\"b\":2}\n{\"a\":2}\n");
    try expectQuery(demo, &.{ "-v", "-c", "NOT", "tier", "gte", "3" }, "3\n");
}

test "parentheses group conditions" {
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "(tier", "eq", "1", "OR", "tier", "eq", "5)", "AND", "active", "eq", "b:true" }, "Alice\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "NOT", "(", "age", "eq", "30", "OR", "tier", "eq", "5", ")" }, "Alice\nDave\n");
    try expectQuery(demo, &.{ "SELECT", "name", "WHERE", "(age", "eq", "30", "OR", "age", "eq", "45)", "AND", "(tier", "lt", "3", "OR", "tier", "gt", "4)" }, "Bob\nEve\n");
}

test "in values can contain escaped commas" {
    const input = "{\"a\":\"x,y\"}\n{\"a\":\"x\"}\n{\"a\":\"z\"}\n";
    try expectQuery(input, &.{ "a", "in", "x\\,y,z" }, "{\"a\":\"x,y\"}\n{\"a\":\"z\"}\n");
    try expectQuery(input, &.{ "--fast", "a", "in", "x\\,y,z" }, "{\"a\":\"x,y\"}\n{\"a\":\"z\"}\n");
    try expectQuery(input, &.{ "a", "in", "x,y" }, "{\"a\":\"x\"}\n");
}

test "limit 0 outputs nothing" {
    try expectQuery("{\"a\":1}\n{\"a\":2}\n", &.{ "--limit", "0", "a", "exists" }, "");
    try expectQuery("{\"a\":1}\n", &.{ "--limit", "0", "--count", "a", "exists" }, "0\n");
}

test "nested objects and arrays are extracted whole" {
    try expectQuery("{\"a\": {\"b\": [1, \"]\"]}, \"c\": 2}\n", &.{ "SELECT", "a,c" }, "{\"b\": [1, \"]\"]}\t2\n");
}

test "count skips nulls" {
    try expectQuery("{\"x\":null}\n{\"x\":1}\n{\"y\":1}\n", &.{ "SELECT", "count:x" }, "1\n");
}

test "csv escapes quotes and decodes JSON escapes" {
    try expectQuery(
        "{\"s\":\"say \\\"hi\\\"\\n\\u00e9\\ud83d\\ude00\",\"n\":5}\n",
        &.{ "--format", "csv", "SELECT", "s,n,missing" },
        "\"say \"\"hi\"\"\n\u{e9}\u{1f600}\",\"5\",\n",
    );
}

test "query values are JSON-escaped before matching" {
    try expectQuery("{\"s\":\"a\\\"b\"}\n", &.{ "--count", "s", "eq", "a\"b" }, "1\n");
    try expectQuery("{\"s\":\"a\\\"b\"}\n", &.{ "--count", "s", "has", "\"" }, "1\n");
}

test "has respects type prefixes" {
    try expectQuery("{\"v\":123}\n{\"v\":\"123\"}\n", &.{ "--count", "v", "has", "s:2" }, "1\n");
    try expectQuery("{\"v\":123}\n{\"v\":\"123\"}\n", &.{ "--count", "v", "has", "n:2" }, "1\n");
}

test "last line without trailing newline is processed" {
    try expectQuery("{\"a\":1}\n{\"a\":2}", &.{ "--count", "a", "exists" }, "2\n");
    try expectQuery("{\"a\":1}\n{\"a\":2}", &.{ "SELECT", "a", "WHERE", "NOT", "b", "exists" }, "1\n2\n");
    try expectQuery("{\"a\":1}\r\n{\"a\":2}\r\n", &.{ "a", "eq", "2" }, "{\"a\":2}\n");
}

test "lines longer than a block are handled" {
    const a = testing.allocator;
    const big = try a.alloc(u8, block_size + block_size / 2);
    defer a.free(big);
    @memset(big, 'x');
    const input = try std.mem.concat(a, u8, &.{ "{\"a\":0}\n{\"pad\":\"", big, "\",\"a\":1}\n{\"a\":2}\n{\"a\":3}" });
    defer a.free(input);
    try expectQuery(input, &.{ "--count", "a", "exists" }, "4\n");
    try expectQuery(input, &.{ "SELECT", "a", "WHERE", "a", "gte", "1" }, "1\n2\n3\n");
}

test "many blocks with multi-condition and OR plans" {
    const a = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(a);
    var expected_and: usize = 0;
    var expected_or: usize = 0;
    var i: usize = 0;
    while (list.items.len < 2 * block_size + 12345) : (i += 1) {
        const level = if (i % 7 == 0) "error" else "info";
        const status = 200 + (i % 5) * 100;
        try list.print(a, "{{\"i\":{d},\"level\":\"{s}\",\"status\":{d},\"msg\":\"some text {d}\"}}\n", .{ i, level, status, i });
        if (i % 7 == 0 and status >= 500) expected_and += 1;
        if (i % 7 == 0 or status == 300) expected_or += 1;
    }
    var buf: [32]u8 = undefined;
    try expectQuery(list.items, &.{ "--count", "level", "eq", "error", "AND", "status", "gte", "500" }, try std.fmt.bufPrint(&buf, "{d}\n", .{expected_and}));
    try expectQuery(list.items, &.{ "--count", "level", "eq", "error", "OR", "status", "eq", "300" }, try std.fmt.bufPrint(&buf, "{d}\n", .{expected_or}));
}

test "exact: keys are top-level and paths walk into objects" {
    const line = "{\"id\": 5, \"meta\": {\"id\": 10, \"user\": {\"name\": \"x\"}}}\n";
    try expectQuery(line, &.{ "--count", "id", "eq", "10" }, "0\n");
    try expectQuery(line, &.{ "--count", "meta.id", "eq", "10" }, "1\n");
    try expectQuery(line, &.{ "SELECT", "id,meta.user.name,meta.user,nope.x" }, "5\tx\t{\"name\": \"x\"}\t\n");
    try expectQuery("{\"a.b\":1,\"a\":{\"b\":2}}\n", &.{ "SELECT", "a\\.b,a.b" }, "1\t2\n");
    // A path through a non-object is absent.
    try expectQuery("{\"a\":[{\"b\":1}]}\n", &.{ "--count", "a.b", "exists" }, "0\n");
    try expectQuery(line, &.{ "--fast", "--count", "id", "eq", "10" }, "1\n");
}

test "exact: NOT sees only the value at the path" {
    // The nested "a" must not make `NOT a eq 1` fail.
    try expectQuery("{\"a\":2,\"x\":{\"a\":1}}\n", &.{ "--count", "NOT", "a", "eq", "1" }, "1\n");
    try expectQuery("{\"a\":2,\"x\":{\"a\":1}}\n", &.{ "--count", "a", "eq", "2", "AND", "NOT", "a", "eq", "1" }, "1\n");
    try expectQuery("{\"b\":1}\n", &.{ "--count", "NOT", "a", "exists" }, "1\n");
}

test "exact: escapes are decoded" {
    const lines =
        \\{"\u006cevel": "error"}
        \\{"level": "\u0065rror"}
        \\{"level": "err\/or"}
        \\{"msg": "caf\u00e9 \ud83d\ude00", "path": "a\/b"}
        \\{"level": "error"}
        \\
    ;
    try expectQuery(lines, &.{ "--count", "level", "eq", "error" }, "3\n");
    try expectQuery(lines, &.{ "--count", "level", "eq", "err/or" }, "1\n");
    try expectQuery(lines, &.{ "--count", "msg", "has", "caf\u{e9} \u{1f600}" }, "1\n");
    try expectQuery(lines, &.{ "--count", "path", "eq", "a/b" }, "1\n");
    try expectQuery(lines, &.{ "--count", "level", "in", "x,error" }, "3\n");
    // Many anchors take the Teddy path, which must stop at escapes too.
    try expectQuery(lines, &.{ "--count", "level", "eq", "error", "OR", "p1", "exists", "OR", "p2", "exists", "OR", "p3", "exists", "OR", "p4", "exists" }, "3\n");
}

test "exact: numbers compare by value" {
    const lines = "{\"v\":90}\n{\"v\":90.0}\n{\"v\":9e1}\n{\"v\":\"90\"}\n{\"v\":\"90.0\"}\n{\"v\":900}\n{\"v\":-0}\n";
    try expectQuery(lines, &.{ "--count", "v", "eq", "90" }, "5\n");
    try expectQuery(lines, &.{ "--count", "v", "eq", "n:90.0" }, "3\n");
    try expectQuery(lines, &.{ "--count", "v", "eq", "s:90" }, "1\n");
    try expectQuery(lines, &.{ "--count", "v", "in", "0,9e1" }, "6\n");
    try expectQuery(lines, &.{ "--count", "v", "neq", "90" }, "2\n");
}

test "exact: duplicate keys, last wins" {
    try expectQuery("{\"a\":1,\"a\":2}\n", &.{ "--count", "a", "eq", "1" }, "0\n");
    try expectQuery("{\"a\":1,\"a\":2}\n", &.{ "SELECT", "a" }, "2\n");
    try expectQuery("{\"a\":{\"b\":1},\"a\":3}\n", &.{ "--count", "a.b", "exists" }, "0\n");
}

test "exact: invalid lines are skipped" {
    const lines = "{\"a\":1}\n{\"a\":1,}\n{\"a\":01}\n\n{\"a\":\"\xff\"}\n{\"a\":1} x\n[1]\n";
    try expectQuery(lines, &.{ "--count", "a", "exists" }, "1\n");
    try expectQuery(lines, &.{ "--count", "NOT", "a", "exists" }, "1\n");
    try expectQuery(lines, &.{"--count"}, "2\n");
}

test "exact: any JSON whitespace around colons" {
    try expectQuery("{\"a\"\r:\r1}\n", &.{ "--count", "a", "eq", "1" }, "1\n");
    try expectQuery("{\"t\" :\r\"x\"}\n", &.{ "--count", "t", "eq", "x" }, "1\n");
}

/// Writes random JSONL that exercises everything the byte search must see through:
/// escaped spellings of key and value characters, nesting, repeated keys, unusual
/// whitespace, numbers spelled several ways, and some invalid lines.
const FuzzGen = struct {
    rand: std.Random,
    a: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    const keys = [_][]const u8{ "a", "b", "ab", "k/", "\u{e9}", "a.b", "p1", "q\"" };
    const strings = [_][]const u8{ "x", "ab", "Push", "1", "90", "90.0", "true", "a/b", "\u{e9}t\u{e9}", "q\"t", "", "-0", "\u{1f600}", "line\nbreak" };
    const numbers = [_][]const u8{ "1", "1.0", "1e0", "90", "9E1", "-0", "0", "12.5", "100", "1E2", "-3" };

    fn print(g: *FuzzGen, comptime fmt: []const u8, args: anytype) !void {
        try g.out.print(g.a, fmt, args);
    }

    fn chance(g: *FuzzGen, n: u32) bool {
        return g.rand.uintLessThan(u32, n) == 0;
    }

    fn ws(g: *FuzzGen) !void {
        try g.out.appendSlice(g.a, switch (g.rand.uintLessThan(u32, 8)) {
            0 => " ",
            1 => "\t",
            2 => "\r",
            3 => "  ",
            else => "",
        });
    }

    fn hex(g: *FuzzGen, unit: u21) !void {
        if (g.rand.boolean()) try g.print("\\u{x:0>4}", .{unit}) else try g.print("\\u{X:0>4}", .{unit});
    }

    /// A string, with characters randomly written as escapes.
    fn string(g: *FuzzGen, s: []const u8) !void {
        try g.out.append(g.a, '"');
        var it = (std.unicode.Utf8View.init(s) catch unreachable).iterator();
        while (it.nextCodepoint()) |cp| {
            if (g.chance(5)) {
                if (cp >= 0x10000) {
                    const offset = cp - 0x10000;
                    try g.hex(@intCast(0xd800 + (offset >> 10)));
                    try g.hex(@intCast(0xdc00 + (offset & 0x3ff)));
                } else try g.hex(cp);
            } else switch (cp) {
                '"' => try g.print("\\\"", .{}),
                '\\' => try g.print("\\\\", .{}),
                '\n' => try g.print("\\n", .{}),
                '/' => try g.print("{s}", .{if (g.rand.boolean()) "\\/" else "/"}),
                else => try g.print("{u}", .{cp}),
            }
        }
        try g.out.append(g.a, '"');
    }

    fn value(g: *FuzzGen, depth: u32) error{ OutOfMemory, WriteFailed }!void {
        switch (g.rand.uintLessThan(u32, if (depth < 3) 9 else 6)) {
            0, 1 => try g.string(strings[g.rand.uintLessThan(usize, strings.len)]),
            2, 3 => try g.print("{s}", .{numbers[g.rand.uintLessThan(usize, numbers.len)]}),
            4 => try g.print("{s}", .{([_][]const u8{ "true", "false", "null" })[g.rand.uintLessThan(usize, 3)]}),
            5 => try g.print("{d}", .{g.rand.intRangeAtMost(i32, -200, 200)}),
            6, 7 => try g.object(depth + 1),
            else => {
                try g.out.append(g.a, '[');
                const n = g.rand.uintLessThan(u32, 3);
                for (0..n) |i| {
                    if (i > 0) try g.out.append(g.a, ',');
                    try g.ws();
                    try g.value(depth + 1);
                }
                try g.out.append(g.a, ']');
            },
        }
    }

    fn object(g: *FuzzGen, depth: u32) !void {
        try g.out.append(g.a, '{');
        const n = g.rand.uintLessThan(u32, 5);
        for (0..n) |i| {
            if (i > 0) try g.out.append(g.a, ',');
            try g.ws();
            try g.string(keys[g.rand.uintLessThan(usize, keys.len)]);
            try g.ws();
            try g.out.append(g.a, ':');
            try g.ws();
            try g.value(depth);
        }
        // Padding moves the needles around relative to the SIMD chunks.
        if (g.chance(2)) try g.print(",\"pad\":\"{s}\"", .{("." ** 40)[0..g.rand.uintLessThan(usize, 40)]});
        try g.out.append(g.a, '}');
    }

    fn line(g: *FuzzGen) !void {
        const start = g.out.items.len;
        if (g.chance(20)) try g.value(2) else try g.object(0);
        if (g.chance(20)) g.out.items.len = start + g.rand.uintLessThan(usize, g.out.items.len - start + 1);
        if (g.chance(10)) try g.out.append(g.a, '\r');
        try g.out.append(g.a, '\n');
    }
};

test "differential: the prefilter never drops a line the parser accepts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(0x2e60);
    const rand = prng.random();

    const query_keys = [_][]const u8{ "a", "b", "ab", "k/", "\u{e9}", "a\\.b", "a.b", "a.ab", "b.a", "p1", "q\"", "nope" };
    const query_vals = FuzzGen.strings ++ FuzzGen.numbers ++ [_][]const u8{ "false", "null", "t", "/", "\u{e9}" };
    const ops = [_][]const u8{ "eq", "eq", "neq", "has", "in", "exists", "gt", "lte" };

    for (0..20) |_| {
        var gen: FuzzGen = .{ .rand = rand, .a = a };
        for (0..300) |_| try gen.line();

        for (0..40) |_| {
            var args: std.ArrayList([]const u8) = .empty;
            const groups = 1 + rand.uintLessThan(u32, if (rand.boolean()) 2 else 6);
            for (0..groups) |gi| {
                if (gi > 0) try args.append(a, "OR");
                const conds = 1 + rand.uintLessThan(u32, 2);
                for (0..conds) |ci| {
                    if (ci > 0) try args.append(a, "AND");
                    if (rand.uintLessThan(u32, 4) == 0) try args.append(a, "NOT");
                    try args.append(a, query_keys[rand.uintLessThan(usize, query_keys.len)]);
                    const op = ops[rand.uintLessThan(usize, ops.len)];
                    try args.append(a, op);
                    if (std.mem.eql(u8, op, "exists")) continue;
                    const pool: []const []const u8 = if (op[0] == 'g' or op[0] == 'l') &FuzzGen.numbers else &query_vals;
                    var v = pool[rand.uintLessThan(usize, pool.len)];
                    if (std.mem.eql(u8, op, "in")) v = try std.mem.concat(a, u8, &.{ v, ",", pool[rand.uintLessThan(usize, pool.len)] });
                    v = try std.mem.concat(a, u8, &.{ ([_][]const u8{ "", "", "s:", "n:" })[rand.uintLessThan(usize, 4)], v });
                    try args.append(a, v);
                }
            }
            if (rand.boolean()) try args.insertSlice(a, 0, &.{ "SELECT", "a,a.b,p1" });

            const config = (try cli.parseArgs(a, args.items)).run;
            const got = try runTestQuery(a, gen.out.items, config);
            var unfiltered = config;
            unfiltered.prefilter = false;
            const want = try runTestQuery(a, gen.out.items, unfiltered);
            if (!std.mem.eql(u8, want, got)) {
                std.debug.print("query:", .{});
                for (args.items) |t| std.debug.print(" '{s}'", .{t});
                std.debug.print("\nwant:\n{s}\ngot:\n{s}\n", .{ want, got });
                return error.TestUnexpectedResult;
            }
        }
    }
}
