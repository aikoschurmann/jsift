//! Runs a query over files, stdin or bytes in memory. A reader thread fills blocks while the
//! search scans them, on one thread or, for large inputs, on several (`runParallel`).
const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const json = @import("json.zig");
const finder = @import("finder.zig");
const compile = @import("compile.zig");
const values = @import("values.zig");
const match = @import("match.zig");
const output = @import("output.zig");

const Search = struct {
    plan: *const compile.CompiledPlan,
    agg_states: []output.AggState,
    writer: *std.Io.Writer,
    /// Per anchor: whether it passed at the key occurrence being evaluated.
    passed: []bool,
    scratch: values.Scratch,
    /// Allocates the groups in `group_map`. In the parallel scan it is the chunk's arena,
    /// since every chunk collects its own groups.
    group_alloc: std.mem.Allocator,
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
        const gpa = self.group_alloc;
        var key_values: [cli.max_pluck_fields]?values.Value = undefined;
        self.group_key.clearRetainingCapacity();

        for (plan.group_keys, key_values[0..plan.group_keys.len]) |*key, *key_value| {
            key_value.* = if (plan.exact)
                values.slotValue(self.parser.slots[key.slot])
            else
                values.extractField(line, &key.finder);
            const value = key_value.* orelse {
                try self.group_key.append(self.scratch.gpa, 0);
                continue;
            };
            const escaped = value.is_string and std.mem.findScalar(u8, value.raw, '\\') != null;
            const text = if (value.is_string)
                try values.stringText(.{ .raw = value.raw, .escaped = escaped }, &self.scratch)
            else
                value.raw;
            try self.group_key.append(self.scratch.gpa, if (value.is_string) 1 else 2);
            try self.group_key.appendSlice(self.scratch.gpa, std.mem.asBytes(&text.len));
            try self.group_key.appendSlice(self.scratch.gpa, text);
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

const page_allocator = std.heap.page_allocator;

/// Where blocks are read from, and how.
const ReadTarget = struct {
    file: std.Io.File,
    io: std.Io,
    /// Input is a pipe or terminal: hand data over as soon as nothing more is immediately
    /// readable instead of waiting for a full block.
    streaming: bool,
    /// Bytes per block: `Config.block_size`, or `Config.stream_block_size` when streaming.
    block_size: usize,

    /// Regular files are read in full blocks. Pipes, terminals and sockets are streamed.
    /// If stat fails, assume streaming, which is the safe choice for an unknown source.
    fn init(file: std.Io.File, block_size: usize, stream_block_size: usize, io: std.Io) ReadTarget {
        const streaming = if (file.stat(io)) |stat| stat.kind != .file else |_| true;
        return .{
            .file = file,
            .io = io,
            .streaming = streaming,
            .block_size = if (streaming) stream_block_size else block_size,
        };
    }
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
/// away). Always reads at least once. Returns true at end of input or on a read error,
/// which is stored in `read_err`.
fn fillBuffer(target: ReadTarget, buf: []u8, total: *usize, read_err: *?anyerror) bool {
    while (total.* < buf.len) {
        const read_len = target.file.readStreaming(target.io, &.{buf[total.*..]}) catch |err| {
            // End of stream is a normal end of input, so only other errors are recorded.
            if (err != error.EndOfStream) read_err.* = err;
            return true;
        };
        if (read_len == 0) return true;

        total.* += read_len;
        // Streaming input: stop once a small block is full or the pipe has no more data right now.
        const block_full = total.* >= target.block_size;
        if (target.streaming and (block_full or !dataReady(target.file))) return false;
    }
    return false;
}

fn growBuffer(buf: *[]u8, new_len: usize) !void {
    buf.* = try page_allocator.realloc(buf.*, new_len);
}

/// One block of input as read by `readBlock`.
const Block = struct {
    /// Bytes at the start of the buffer that form whole lines (or the rest of the input).
    len: usize,
    /// The input ended with this block, normally or because of `read_err`.
    eof: bool,
    read_err: ?anyerror = null,
};

/// Fills `buf` with `carry` followed by fresh input, up to the last complete line, growing
/// `buf` when it is too small (an empty `buf` is allocated here). On return, `carry` is the
/// partial last line. It sits in `buf` past the block's `len`, which no scan reads, so it
/// stays valid until the next call copies it into the next buffer. That buffer must be a
/// different one: `buf` is the only one this call resizes.
fn readBlock(target: ReadTarget, buf: *[]u8, carry: *[]const u8) Block {
    // Make room for the carry plus at least half a block of fresh data. Growing
    // only when this fails keeps the common path free of reallocations.
    if (carry.len + target.block_size / 2 > buf.len or buf.len == 0) {
        // A failure ends the input like a read error, so the scan stops instead of waiting
        // for a block that will never come.
        growBuffer(buf, carry.len + @max(target.block_size, 1)) catch |err| return .{ .len = 0, .eof = true, .read_err = err };
    }
    @memcpy(buf.*[0..carry.len], carry.*);
    var total = carry.len;
    // The carried bytes contain no newline, so the newline search can start after them.
    var scanned = carry.len;
    carry.* = &.{};

    while (true) {
        var read_err: ?anyerror = null;
        if (fillBuffer(target, buf.*, &total, &read_err)) {
            // End of input: the whole buffer, including a last line without a newline, is
            // the final block. Nothing is carried over.
            return .{ .len = total, .eof = true, .read_err = read_err };
        }
        if (finder.lastNewline(buf.*, scanned, total)) |newline| {
            // Hand over everything up to the last newline. The rest is carried over.
            carry.* = buf.*[newline + 1 .. total];
            return .{ .len = newline + 1, .eof = false };
        }
        // No complete line yet: keep reading, growing the buffer if a line outgrew it.
        scanned = total;
        if (total == buf.len) {
            growBuffer(buf, buf.len * 2) catch |err| return .{ .len = total, .eof = true, .read_err = err };
        }
    }
}

const Buffer = struct { data: []u8 = &.{}, len: usize = 0, eof: bool = false };

/// State shared by the reader thread and the consumer of the single-threaded scan. The two
/// sides hand the buffers back and forth with two semaphores:
///   - `read_sem` counts buffers the reader may fill. It starts at 2, so both are free.
///   - `fill_sem` counts filled buffers the consumer may scan.
/// Both sides walk `bufs[0]` and `bufs[1]` in the same order, so neither side has to
/// send the buffer index to the other.
const ReaderCtx = struct {
    target: ReadTarget,
    bufs: [2]Buffer = .{ .{}, .{} },

    /// Set by `stopReader` to make the reader exit at its next check.
    stop: std.atomic.Value(bool) = .init(false),
    read_err: ?anyerror = null,

    fill_sem: std.Io.Semaphore = .{ .permits = 0 },
    read_sem: std.Io.Semaphore = .{ .permits = 2 },

    fn destroy(ctx: *ReaderCtx) void {
        for (ctx.bufs) |buf| page_allocator.free(buf.data);
        page_allocator.destroy(ctx);
    }
};

fn readerThread(ctx: *ReaderCtx) void {
    const io = ctx.target.io;
    var buf_index: usize = 0;
    // Partial last line of the previously filled buffer (see `readBlock`).
    var carry: []const u8 = &.{};

    while (true) {
        // Wait until the consumer has released a buffer. Bail out if stopped.
        ctx.read_sem.wait(io) catch return;
        if (ctx.stop.load(.acquire)) return;
        const buf = &ctx.bufs[buf_index];
        const block = readBlock(ctx.target, &buf.data, &carry);
        buf.len = block.len;
        buf.eof = block.eof;
        if (block.read_err) |err| ctx.read_err = err;
        ctx.fill_sem.post(io);
        if (block.eof) return;
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

/// The single-threaded scan of one file: a reader thread fills two buffers in turn while
/// this thread scans them. Returns true when all input was consumed, false when the match
/// limit stopped it early.
fn runSearch(search: *Search, file: std.Io.File, config: cli.Config, io: std.Io) !bool {
    // When we stop early the reader may be blocked in a read that never returns (e.g. on
    // `tail -f`), so it is then detached rather than joined. Its context and buffers must
    // outlive this function, so they come from page_allocator.
    const ctx = try page_allocator.create(ReaderCtx);
    ctx.* = .{ .target = .init(file, config.block_size, config.stream_block_size, io) };
    const thread = std.Thread.spawn(.{}, readerThread, .{ctx}) catch |err| {
        ctx.destroy();
        return err;
    };

    // Consume on this thread. An early stop stops the reader instead of waiting for the end.
    const finished = consume(search, ctx, io) catch |err| {
        stopReader(ctx, thread);
        return err;
    };
    if (!finished) {
        stopReader(ctx, thread);
        return false;
    }

    thread.join();
    ctx.destroy();
    return true;
}

/// Stops the reader early. Setting `stop` and posting `read_sem` wakes a reader that is
/// waiting for a free buffer. A read from a regular file always returns, so that reader is
/// joined. A reader blocked on a pipe is not woken: it is detached, and keeps running until
/// its read returns. Its memory is then intentionally not freed.
fn stopReader(ctx: *ReaderCtx, thread: std.Thread) void {
    ctx.stop.store(true, .release);
    ctx.read_sem.post(ctx.target.io);
    if (ctx.target.streaming) {
        thread.detach();
    } else {
        thread.join();
        ctx.destroy();
    }
}

// The parallel scan. A feeder thread cuts the input into newline-aligned chunks, workers
// scan chunks into per-chunk results, and the calling thread writes the results out in
// input order. Chunk `n` goes through slot `n % slot count`: the feeder fills the slot's
// `Chunk`, a worker fills the slot's `ChunkResult`, and the calling thread hands the slot
// back to the feeder once it has written it out. Two slots per thread keep every worker busy
// while the chunk at the head of the line is still being scanned.
//
// The calling thread scans the head chunk itself whenever no worker has taken it yet, and
// workers only take chunks past the head. Input that arrives no faster than one thread can
// scan it (a pipe, usually) then goes through one handoff per chunk, as in the
// single-threaded scan, and the workers sleep. Only when the feeder gets ahead do workers
// pick up the chunks past the head. While a worker still has the head, the calling thread
// scans the next untaken chunk like a worker, so it is never idle while there is work.

/// Chunks of a regular file in the parallel scan. Smaller than a single-threaded block:
/// the feeder's copy of each chunk is then still in the shared cache when a worker scans it,
/// and the last chunks to finish hold up the end less. Measured fastest on an Apple M2 Pro
/// for both cheap and parse-bound queries.
const parallel_block_size = 512 * 1024;

/// Chunks that must be waiting past the head before a worker is woken or started for
/// them. A single one is usually scanned by the calling thread as soon as it is done with
/// the head, sooner than a worker would wake up, so waking a worker for it costs more than
/// it saves. This keeps input that one thread nearly keeps up with, such as a pipe, on the
/// cheaper single-thread path.
const min_backlog = 2;

/// Input for the parallel scan.
const FeedSource = union(enum) {
    bytes: []const u8,
    file: std.Io.File,
    /// Opened and read in order by the feeder. Copied into `Feed.arena`.
    files: []const []const u8,
};

/// The feeder's half of a slot: one chunk of input.
const Chunk = struct {
    /// Buffer the feeder reads into. Kept across uses of the slot, and grown as needed.
    buf: []u8 = &.{},
    /// The newline-aligned bytes to scan: a prefix of `buf`, or a slice of in-memory input.
    input: []const u8 = &.{},
    /// Lines in the same file before `input`, for --line-number.
    first_line: usize = 0,
    /// Nothing follows this chunk.
    last: bool = false,
    /// An error that ended the input after this chunk, and the index of the file it
    /// happened in, among `FeedSource.files`.
    read_err: ?anyerror = null,
    file_index: ?usize = null,
};

/// Which chunks are filled and who scans them. Guarded by `mutex`, as is `ChunkResult.done`.
const Queue = struct {
    mutex: std.Io.Mutex = .init,
    /// Idle workers wait here for a chunk past the head.
    work: std.Io.Condition = .init,
    /// The calling thread waits here for a chunk to be filled or the head to be scanned.
    progress: std.Io.Condition = .init,
    /// Chunks filled so far.
    filled: usize = 0,
    /// The first chunk nobody has taken. Chunks are taken in order.
    next: usize = 0,
    /// The chunk the calling thread is on: written out up to here.
    head: usize = 0,
    /// Workers waiting on `work` that no signal is on its way to yet.
    idle: usize = 0,
    /// Workers started. Workers are started by the feeder when a chunk is ready for a worker
    /// and none is idle, so a small input or a slow stream only starts the workers it needs.
    spawned: usize = 0,
};

/// The parts of the parallel scan the feeder uses. When the scan stops early, the feeder
/// may be blocked in a read that never returns (`tail -f`), so it is detached rather than
/// joined. This is therefore reference-counted: the feeder and the calling thread each hold
/// a reference, and whoever drops the last one frees it.
const Feed = struct {
    io: std.Io,
    source: FeedSource,
    block_size: usize,
    stream_block_size: usize,
    /// Count each chunk's newlines, for --line-number.
    count_lines: bool,
    chunks: []Chunk,
    /// Slots the feeder may fill. Starts at the slot count. The calling thread posts it when
    /// it has written a slot out.
    free: std.Io.Semaphore,
    queue: Queue = .{},
    /// Set, under `queue.mutex`, once the calling thread needs no more chunks. The feeder
    /// also reads it outside the lock, after waiting for a slot.
    stop: std.atomic.Value(bool) = .init(false),
    refs: std.atomic.Value(u32) = .init(2),
    /// Holds the copy of the file paths: a detached feeder may outlive the caller's list.
    arena: std.heap.ArenaAllocator = .init(page_allocator),
    /// Owned by the calling thread. The feeder only starts them, under `queue.mutex` and
    /// before `stop`, so the calling thread knows which ones to join.
    workers: []Worker,
    /// Owned by the calling thread. Workers set `done` under `queue.mutex`.
    results: []ChunkResult,

    fn create(source: FeedSource, config: cli.Config, workers: []Worker, results: []ChunkResult, io: std.Io) !*Feed {
        const slot_count = results.len;
        const feed = try page_allocator.create(Feed);
        errdefer page_allocator.destroy(feed);
        const chunks = try page_allocator.alloc(Chunk, slot_count);
        errdefer page_allocator.free(chunks);
        @memset(chunks, .{});
        feed.* = .{
            .io = io,
            .source = source,
            .block_size = @min(config.block_size, parallel_block_size),
            .stream_block_size = config.stream_block_size,
            .count_lines = false,
            .chunks = chunks,
            .free = .{ .permits = slot_count },
            .workers = workers,
            .results = results,
        };
        errdefer feed.arena.deinit();
        if (source == .files) {
            const paths = try feed.arena.allocator().alloc([]const u8, source.files.len);
            for (source.files, paths) |path, *copy| copy.* = try feed.arena.allocator().dupe(u8, path);
            feed.source = .{ .files = paths };
        }
        return feed;
    }

    /// Drops one reference, and frees everything when it was the last.
    fn release(feed: *Feed) void {
        if (feed.refs.fetchSub(1, .acq_rel) != 1) return;
        for (feed.chunks) |chunk| page_allocator.free(chunk.buf);
        page_allocator.free(feed.chunks);
        feed.arena.deinit();
        page_allocator.destroy(feed);
    }

    /// Feeder: waits until the slot for chunk `seq` is free. Null once the scan is stopped.
    fn acquire(feed: *Feed, seq: usize) ?*Chunk {
        feed.free.waitUncancelable(feed.io);
        if (feed.stop.load(.acquire)) return null;
        return &feed.chunks[seq % feed.chunks.len];
    }

    /// Feeder: hands chunk `seq.*` over and moves on to the next.
    fn publish(feed: *Feed, seq: *usize) void {
        const io = feed.io;
        const queue = &feed.queue;
        queue.mutex.lockUncancelable(io);
        defer queue.mutex.unlock(io);
        queue.filled += 1;
        // Neither signal makes a system call when nobody waits.
        queue.progress.signal(io);
        // Chunks past the head that nobody has taken yet.
        const waiting = queue.filled - @max(queue.next, queue.head + 1);
        if (queue.filled > queue.head + 1 and waiting >= min_backlog) {
            // A chunk for a worker.
            if (queue.idle > 0) {
                queue.idle -= 1;
                queue.work.signal(io);
            } else if (queue.spawned < feed.workers.len and !feed.stop.load(.monotonic)) {
                // A failure is ignored: the threads already running finish the scan.
                const worker = &feed.workers[queue.spawned];
                if (std.Thread.spawn(.{}, workerMain, .{worker})) |thread| {
                    worker.thread = thread;
                    queue.spawned += 1;
                } else |_| {}
            }
        }
        seq.* += 1;
    }

    /// Worker: takes the next chunk past the head, waiting for one. Null once stopped.
    fn take(feed: *Feed) ?usize {
        const io = feed.io;
        const queue = &feed.queue;
        queue.mutex.lockUncancelable(io);
        defer queue.mutex.unlock(io);
        while (true) {
            if (feed.stop.load(.monotonic)) return null;
            if (queue.next < queue.filled and queue.next > queue.head) return feed.takeNext();
            // `publish` decrements `idle` when it signals, so a worker is never counted twice.
            queue.idle += 1;
            queue.work.waitUncancelable(io, &queue.mutex);
        }
    }

    /// Takes chunk `queue.next`, which must be filled. Locked.
    fn takeNext(feed: *Feed) usize {
        const seq = feed.queue.next;
        feed.queue.next += 1;
        feed.results[seq % feed.results.len].done = false;
        return seq;
    }

    /// Worker or helping calling thread: marks chunk `seq`'s result as ready.
    fn finish(feed: *Feed, seq: usize) void {
        const io = feed.io;
        const queue = &feed.queue;
        queue.mutex.lockUncancelable(io);
        defer queue.mutex.unlock(io);
        feed.results[seq % feed.results.len].done = true;
        if (seq == queue.head) queue.progress.signal(io);
    }

    /// What the calling thread does next while it is on chunk `head`.
    const Step = union(enum) {
        /// Nobody took the head: scan it straight into the output.
        scan_head,
        /// A worker scanned the head: write its result.
        write_head,
        /// A worker still has the head: meanwhile, scan this later chunk like a worker.
        help: usize,
    };

    /// Calling thread: moves the head to chunk `head` and waits until there is something to do.
    fn nextStep(feed: *Feed, head: usize) Step {
        const io = feed.io;
        const queue = &feed.queue;
        queue.mutex.lockUncancelable(io);
        defer queue.mutex.unlock(io);
        queue.head = head;
        while (true) {
            // No worker takes the head, so it stays untaken while this thread waits. The
            // feeder fills one more chunk until the input ends, so the wait ends.
            if (queue.next == head) {
                if (queue.filled > head) {
                    _ = feed.takeNext();
                    return .scan_head;
                }
            } else if (feed.results[head % feed.results.len].done) {
                return .write_head;
            } else if (queue.next < queue.filled) {
                return .{ .help = feed.takeNext() };
            }
            queue.progress.waitUncancelable(io, &queue.mutex);
        }
    }
};

fn feederThread(feed: *Feed) void {
    defer feed.release();
    var seq: usize = 0;
    switch (feed.source) {
        .bytes => |data| feedBytes(feed, data, &seq),
        .file => |file| _ = feedFile(feed, file, null, true, &seq),
        .files => |paths| for (paths, 0..) |path, index| {
            const file = std.Io.Dir.cwd().openFile(feed.io, path, .{}) catch |err| {
                // The error ends the input. It is reported once the earlier files are written out.
                const chunk = feed.acquire(seq) orelse return;
                chunk.* = .{ .buf = chunk.buf, .last = true, .read_err = err, .file_index = index };
                feed.publish(&seq);
                return;
            };
            defer file.close(feed.io);
            if (!feedFile(feed, file, index, index + 1 == paths.len, &seq)) return;
        },
    }
}

/// Cuts in-memory input into chunks of about `block_size` bytes, each ending at a newline.
fn feedBytes(feed: *Feed, data: []const u8, seq: *usize) void {
    var start: usize = 0;
    var lines: usize = 0;
    while (true) {
        const chunk = feed.acquire(seq.*) orelse return;
        var end = @min(start + @max(feed.block_size, 1), data.len);
        // Extend the chunk to the end of the line its last byte is in.
        if (end < data.len) end = if (std.mem.findScalarPos(u8, data, end - 1, '\n')) |newline| newline + 1 else data.len;
        const last = end == data.len;
        chunk.* = .{ .buf = chunk.buf, .input = data[start..end], .first_line = lines, .last = last };
        if (feed.count_lines) lines += std.mem.countScalar(u8, chunk.input, '\n');
        feed.publish(seq);
        if (last) return;
        start = end;
    }
}

/// Reads one file in chunks. Returns true when the file ended and more input follows, false
/// when the input ended or the scan was stopped.
fn feedFile(feed: *Feed, file: std.Io.File, file_index: ?usize, last_file: bool, seq: *usize) bool {
    const target: ReadTarget = .init(file, feed.block_size, feed.stream_block_size, feed.io);
    // Partial last line of the previous chunk (see `readBlock`). There are two slots at
    // least, so the previous chunk's buffer is never the one being filled.
    var carry: []const u8 = &.{};
    // Line numbers restart in every file, as in grep.
    var lines: usize = 0;
    while (true) {
        const chunk = feed.acquire(seq.*) orelse return false;
        const block = readBlock(target, &chunk.buf, &carry);
        const last = block.eof and (last_file or block.read_err != null);
        chunk.input = chunk.buf[0..block.len];
        chunk.first_line = lines;
        chunk.last = last;
        chunk.read_err = block.read_err;
        chunk.file_index = file_index;
        if (feed.count_lines) lines += std.mem.countScalar(u8, chunk.input, '\n');
        feed.publish(seq);
        if (block.eof) return !last;
    }
}

/// A worker's half of a slot: what scanning its chunk produced.
const ChunkResult = struct {
    /// The rows the chunk printed.
    out: std.Io.Writer.Allocating,
    match_count: usize = 0,
    /// The chunk's own aggregates, merged into the totals in input order.
    agg_states: []output.AggState,
    /// GROUP BY: the chunk's own groups, in first-seen order, allocated in `arena`.
    group_map: std.StringArrayHashMapUnmanaged([]output.AggState) = .empty,
    arena: std.heap.ArenaAllocator,
    /// Why scanning the chunk failed. Reported when the chunk's turn comes.
    scan_err: ?anyerror = null,
    /// The fields above are ready. Guarded by `Queue.mutex`.
    done: bool = false,
};

/// One scanning thread, with its own parser, scratch space and match state.
const Worker = struct {
    feed: *Feed,
    /// The aggregation states every chunk starts from.
    template: []const output.AggState,
    search: Search,
    /// Backs the parser slots, `passed` and the scratch space. Only this worker uses it.
    arena: std.heap.ArenaAllocator,
    thread: std.Thread = undefined,

    /// Scans chunk `seq` into its slot's result and marks it done.
    fn scan(worker: *Worker, seq: usize) void {
        const feed = worker.feed;
        const index = seq % feed.chunks.len;
        const result = &feed.results[index];
        result.scan_err = null;
        worker.scanChunk(&feed.chunks[index], result) catch |err| {
            // Writing into memory only fails when the memory runs out.
            result.scan_err = if (err == error.WriteFailed) error.OutOfMemory else err;
        };
        feed.finish(seq);
    }

    fn scanChunk(worker: *Worker, chunk: *const Chunk, result: *ChunkResult) !void {
        result.out.clearRetainingCapacity();
        result.group_map = .empty;
        _ = result.arena.reset(.retain_capacity);
        @memcpy(result.agg_states, worker.template);

        const search = &worker.search;
        search.writer = &result.out.writer;
        search.agg_states = result.agg_states;
        search.group_map = .empty;
        search.group_alloc = result.arena.allocator();
        search.match_count = 0;
        search.lines_seen = chunk.first_line;
        defer {
            result.match_count = search.match_count;
            result.group_map = search.group_map;
        }
        // The chunk stops at the limit by itself: more matches than that can't be printed.
        // Whether fewer are depends on the chunks before it, which `writeInOrder` checks.
        _ = try search.scanBlock(chunk.input);
    }
};

fn workerMain(worker: *Worker) void {
    while (worker.feed.take()) |seq| worker.scan(seq);
}

/// A search with its own parser, slots and scratch space, allocated in `allocator`.
fn initSearch(
    allocator: std.mem.Allocator,
    plan: *const compile.CompiledPlan,
    agg_states: []output.AggState,
    writer: *std.Io.Writer,
) !Search {
    const parser = try allocator.create(json.Parser);
    parser.* = .{ .trie = &plan.trie, .slots = try allocator.alloc(?[]const u8, plan.trie.slot_count) };
    return .{
        .plan = plan,
        .agg_states = agg_states,
        .writer = writer,
        .passed = try allocator.alloc(bool, plan.anchors.len),
        .scratch = .{ .gpa = allocator },
        .group_alloc = allocator,
        .parser = parser,
    };
}

/// Where to report the file a read or open error happened in.
const FailedFile = struct { paths: []const []const u8, failed: *?[]const u8 };

/// Runs the parallel scan on `threads` threads: the calling thread and up to `threads - 1`
/// workers. `search` writes the output and holds the totals. With `may_block`, the input may
/// be a pipe whose reads never return, so the feeder is detached at the end instead of joined.
fn runParallel(
    search: *Search,
    source: FeedSource,
    config: cli.Config,
    threads: usize,
    may_block: bool,
    io: std.Io,
    failed_file: ?FailedFile,
) !void {
    const plan = search.plan;
    const allocator = search.scratch.gpa;
    const slot_count = 2 * threads;

    // Every allocation from `allocator` happens here, before any thread starts. Workers
    // allocate only from page_allocator-backed arenas of their own.
    const results = try allocator.alloc(ChunkResult, slot_count);
    for (results) |*result| result.* = .{
        .out = .init(page_allocator),
        .agg_states = try allocator.alloc(output.AggState, plan.pluck.len),
        .arena = .init(page_allocator),
    };
    // The last one is the calling thread's, for the chunks it scans while it helps.
    const workers = try allocator.alloc(Worker, threads);
    var workers_ready: usize = 0;
    defer {
        for (results) |*result| {
            result.out.deinit();
            result.arena.deinit();
        }
        for (workers[0..workers_ready]) |*worker| worker.arena.deinit();
    }

    const feed = try Feed.create(source, config, workers[0 .. threads - 1], results, io);
    feed.count_lines = plan.line_numbers;
    for (workers) |*worker| {
        worker.* = .{
            .feed = feed,
            .template = search.agg_states,
            .search = undefined,
            .arena = .init(page_allocator),
        };
        workers_ready += 1;
        worker.search = initSearch(worker.arena.allocator(), plan, &.{}, undefined) catch |err| {
            // No thread has started, so this is the only reference.
            feed.refs.store(1, .monotonic);
            feed.release();
            return err;
        };
    }

    const feeder = std.Thread.spawn(.{}, feederThread, .{feed}) catch |err| {
        feed.refs.store(1, .monotonic);
        feed.release();
        return err;
    };
    defer stopPool(feed, feeder, may_block);
    return writeInOrder(search, &workers[threads - 1], failed_file);
}

/// Stops the workers and the feeder, and drops the calling thread's reference to `feed`.
fn stopPool(feed: *Feed, feeder: std.Thread, may_block: bool) void {
    const io = feed.io;
    const queue = &feed.queue;
    queue.mutex.lockUncancelable(io);
    feed.stop.store(true, .release);
    // No worker starts after this, so these are the ones to join.
    const started = queue.spawned;
    queue.work.broadcast(io);
    queue.mutex.unlock(io);

    // Wake the feeder if it waits for a slot. It sees `stop` and returns. A worker in the
    // middle of a chunk finishes it first.
    feed.free.post(io);
    for (feed.workers[0..started]) |*worker| worker.thread.join();
    if (may_block) feeder.detach() else feeder.join();
    feed.release();
}

/// Scans the chunks the workers haven't taken and writes every chunk's output in input
/// order, until the input ends or the match limit is reached. Errors are reported in input
/// order too: a chunk's scan error, or the read error after it, comes out after every
/// earlier chunk's output.
fn writeInOrder(search: *Search, helper: *Worker, failed_file: ?FailedFile) !void {
    const feed = helper.feed;
    const limit = search.plan.limit orelse std.math.maxInt(usize);
    var seq: usize = 0;
    while (true) : (seq += 1) {
        const index = seq % feed.chunks.len;
        const chunk = &feed.chunks[index];
        step: switch (feed.nextStep(seq)) {
            .help => |later| {
                helper.scan(later);
                continue :step feed.nextStep(seq);
            },
            .scan_head => {
                // Straight into the output and the totals.
                search.lines_seen = chunk.first_line;
                const limit_reached = try search.scanBlock(chunk.input);
                try search.writer.flush();
                if (limit_reached) return;
            },
            .write_head => {
                const result = &feed.results[index];
                if (result.scan_err) |err| return err;
                if (result.match_count > limit - search.match_count) {
                    // This chunk reaches the limit, but its worker didn't know how many
                    // matches came before it, so it printed too many. Scanning it again here,
                    // where the count is known, stops at exactly the right match.
                    search.lines_seen = chunk.first_line;
                    _ = try search.scanBlock(chunk.input);
                    try search.writer.flush();
                    return;
                }
                try search.writer.writeAll(result.out.written());
                search.match_count += result.match_count;
                // Flush per chunk so streaming input (`tail -f`) produces output as it arrives.
                try search.writer.flush();
                if (search.match_count == limit) return;
            },
        }

        if (chunk.read_err) |err| {
            // The caller's own path: the feeder's copy is freed when the scan ends.
            if (failed_file) |failed| failed.failed.* = failed.paths[chunk.file_index.?];
            return err;
        }
        if (chunk.last) return;
        // Hand the slot back to the feeder.
        feed.free.post(feed.io);
    }
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

/// Runs the query on input already in memory (used by the library API). Safe to call from
/// several threads at once: every call has its own threads and state.
pub fn searchBytes(allocator: std.mem.Allocator, data: []const u8, config: cli.Config, writer: *std.Io.Writer) !usize {
    // An `Io` of its own for the threads' semaphores. Single-threaded, so it installs no
    // signal handlers in a host process; blocking still works across OS threads.
    var threaded: std.Io.Threaded = .init_single_threaded;
    return try searchInput(allocator, .{ .bytes = data }, config, writer, threaded.io());
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

/// The most workers the default thread count uses. Measured on an Apple M2 Pro (6
/// performance and 4 efficiency cores): parse-bound queries stop improving at about 8.
pub const max_default_threads = 8;

/// The thread count when --threads isn't given: one per CPU, up to `max_default_threads`.
pub fn defaultThreads() usize {
    const cpus = std.Thread.getCpuCount() catch 1;
    return @max(1, @min(cpus, max_default_threads));
}

/// How the input will be scanned.
const ScanMode = struct {
    /// Scanning threads, the calling thread included. 1 for the single-threaded scan.
    threads: usize,
    /// Some input may be a pipe or terminal, whose reads can block forever.
    may_block: bool,
};

/// Inputs up to this many parallel chunks stay single-threaded: they take well under a
/// millisecond to scan, so starting threads would cost about as much as it saves.
const min_parallel_chunks = 4;

/// Picks the scan for `input`. Inputs whose size is unknown (pipes) always get the parallel
/// scan: it only starts workers once chunks pile up (see `Queue.spawned`).
fn chooseScan(input: Input, config: cli.Config, plan: *const compile.CompiledPlan, io: std.Io) ScanMode {
    const single: ScanMode = .{ .threads = 1, .may_block = false };
    const threads = config.threads orelse defaultThreads();
    if (threads <= 1 or plan.has_aggregations or plan.line_numbers) return single;
    const probe = probeInput(input, io);
    const chunk_size: usize = @min(config.block_size, parallel_block_size);
    if (probe.size) |bytes| if (bytes <= min_parallel_chunks * chunk_size) return single;
    return .{ .threads = threads, .may_block = probe.may_block };
}

/// The total size of the input, when it is known up front, and whether some of it may be a
/// pipe or terminal.
fn probeInput(input: Input, io: std.Io) struct { size: ?u64, may_block: bool } {
    switch (input) {
        .bytes => |data| return .{ .size = data.len, .may_block = false },
        .file => |file| {
            const stat = file.stat(io) catch return .{ .size = null, .may_block = true };
            if (stat.kind != .file) return .{ .size = null, .may_block = true };
            return .{ .size = stat.size, .may_block = false };
        },
        .files => |files| {
            var total: ?u64 = 0;
            var may_block = false;
            for (files.paths) |path| {
                // A file that can't be stat'ed fails to open too, which ends the input quickly.
                const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
                    total = null;
                    continue;
                };
                if (stat.kind != .file) {
                    may_block = true;
                    total = null;
                } else if (total) |sum| total = sum + stat.size;
            }
            return .{ .size = total, .may_block = may_block };
        },
    }
}

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

    var search = try initSearch(arena.allocator(), &plan, agg_states, writer);
    // `--limit 0` can never produce output, so no thread is started at all.
    const limit_zero = if (plan.limit) |limit| limit == 0 else false;
    const scan = chooseScan(input, config, &plan, io);
    if (limit_zero) {
        // Nothing to scan.
    } else if (scan.threads > 1) {
        const source: FeedSource, const failed = switch (input) {
            .bytes => |data| .{ .{ .bytes = data }, null },
            .file => |file| .{ .{ .file = file }, null },
            .files => |files| .{ .{ .files = files.paths }, FailedFile{ .paths = files.paths, .failed = files.failed } },
        };
        try runParallel(&search, source, config, scan.threads, scan.may_block, io, failed);
    } else switch (input) {
        .file => |file| _ = try runSearch(&search, file, config, io),
        .files => |files| for (files.paths) |path| {
            files.failed.* = path;
            // Line numbers restart in every file, as in grep.
            search.lines_seen = 0;
            const file = try std.Io.Dir.cwd().openFile(io, path, .{});
            defer file.close(io);
            const finished = try runSearch(&search, file, config, io);
            files.failed.* = null;
            if (!finished) break;
        },
        .bytes => |data| _ = try search.scanBlock(data),
    }

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

/// A block size small enough that `input` spans a few dozen blocks, so that every test also
/// covers lines split across reads, carried over and longer than a block.
fn tinyBlockSize(input: []const u8) usize {
    return @max(16, input.len / 24);
}

/// The ways of running a query that must all give the same output: as given (one block
/// for small inputs), and in tiny blocks on one thread and on several. Each variant is run
/// on a file and on bytes in memory.
fn testVariants(config: cli.Config, input: []const u8) [3]cli.Config {
    var single = config;
    single.block_size = tinyBlockSize(input);
    single.stream_block_size = single.block_size;
    single.threads = 1;
    var parallel = single;
    parallel.threads = 4;
    return .{ config, single, parallel };
}

/// Runs `config` through the file path and the in-memory path (used by the library) and
/// checks that both print `expected`.
fn expectBothPaths(a: std.mem.Allocator, input: []const u8, config: cli.Config, expected: []const u8) !void {
    try testing.expectEqualStrings(expected, try runTestQuery(a, input, config));
    var bytes_out: std.Io.Writer.Allocating = .init(a);
    _ = try searchBytes(a, input, config, &bytes_out.writer);
    try testing.expectEqualStrings(expected, bytes_out.written());
}

fn expectQuery(input: []const u8, args: []const []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const config = (try cli.parseArgs(a, args)).run;
    for (testVariants(config, input)) |variant| try expectBothPaths(a, input, variant, expected);
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
    // One line per block, so the files span several chunks, on one thread and on several.
    const Variant = struct { block_size: usize, threads: usize };
    const variants = [_]Variant{ .{ .block_size = cli.default_block_size, .threads = 1 }, .{ .block_size = 4, .threads = 1 }, .{ .block_size = 4, .threads = 4 } };
    for (variants) |variant| {
        for (cases) |case| {
            var config = (try cli.parseArgs(a, case.args)).run;
            config.block_size = variant.block_size;
            config.threads = variant.threads;
            var out: std.Io.Writer.Allocating = .init(a);
            var failed: ?[]const u8 = null;
            _ = try searchFiles(a, config, &out.writer, io, &failed);
            try testing.expectEqualStrings(case.expected, out.written());
            try testing.expect(failed == null);
        }

        // A missing file is reported by name, after the earlier files were searched.
        var config = (try cli.parseArgs(a, &.{ "n", "exists", one, missing, two })).run;
        config.block_size = variant.block_size;
        config.threads = variant.threads;
        var out: std.Io.Writer.Allocating = .init(a);
        var failed: ?[]const u8 = null;
        try testing.expectError(error.FileNotFound, searchFiles(a, config, &out.writer, io, &failed));
        try testing.expectEqualStrings(missing, failed.?);
        try testing.expectEqualStrings("{\"n\":1}\n{\"n\":2}\n", out.written());
    }
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
    const line_count = 2 * cli.default_block_size / 17;
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

test "limit cuts the output at the same match across chunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Matches cluster in some chunks and are absent from others, so the limit falls in
    // chunks scanned by a worker and in chunks the calling thread scans.
    var input: std.ArrayList(u8) = .empty;
    var matches: std.ArrayList(usize) = .empty;
    for (0..2000) |index| {
        const hit = (index / 50) % 3 != 1 and index % 7 != 3;
        try input.print(a, "{{\"i\":{d},\"hit\":{}}}\n", .{ index, hit });
        if (hit) try matches.append(a, index);
    }
    for ([_]usize{ 1, 2, 3, 49, 50, 51, 333, 700, matches.items.len - 1, matches.items.len, matches.items.len + 1 }) |limit| {
        var expected: std.ArrayList(u8) = .empty;
        for (matches.items[0..@min(limit, matches.items.len)]) |index| try expected.print(a, "{d}\n", .{index});
        const limit_arg = try std.fmt.allocPrint(a, "{d}", .{limit});
        try expectQuery(input.items, &.{ "--limit", limit_arg, "SELECT", "i", "WHERE", "hit", "eq", "true" }, expected.items);
        const count = try std.fmt.allocPrint(a, "{d}\n", .{@min(limit, matches.items.len)});
        try expectQuery(input.items, &.{ "--limit", limit_arg, "-c", "hit", "eq", "true" }, count);
    }
}

test "a failing writer stops the parallel scan" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var input: std.ArrayList(u8) = .empty;
    for (0..5000) |index| try input.print(a, "{{\"i\":{d}}}\n", .{index});
    var config = (try cli.parseArgs(a, &.{ "i", "exists" })).run;
    config.block_size = 256;
    config.threads = 4;
    // The output fills the writer's buffer early on. The scan must report the failure and
    // return, with every thread stopped (testing.allocator would report leaked memory).
    var buf: [1000]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buf);
    try testing.expectError(error.WriteFailed, searchBytes(testing.allocator, input.items, config, &fixed));

    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.jsonl", .data = input.items });
    const file = try tmp.dir.openFile(io, "in.jsonl", .{});
    defer file.close(io);
    fixed = .fixed(&buf);
    try testing.expectError(error.WriteFailed, searchOpenFile(testing.allocator, file, config, &fixed, io));
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
    const big = try a.alloc(u8, cli.default_block_size + cli.default_block_size / 2);
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
    while (list.items.len < 2 * cli.default_block_size + 12345) : (i += 1) {
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
            var unfiltered = config;
            unfiltered.prefilter = false;
            unfiltered.threads = 1;
            const want = try runTestQuery(a, gen.out.items, unfiltered);
            // The prefilter, and splitting the input into chunks scanned on several threads,
            // never change the output.
            for (testVariants(config, gen.out.items)) |variant| {
                const got = try runTestQuery(a, gen.out.items, variant);
                if (!std.mem.eql(u8, want, got)) {
                    std.debug.print("query (block size {d}, threads {?d}):", .{ variant.block_size, variant.threads });
                    for (args.items) |t| std.debug.print(" '{s}'", .{t});
                    std.debug.print("\nwant:\n{s}\ngot:\n{s}\n", .{ want, got });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}
