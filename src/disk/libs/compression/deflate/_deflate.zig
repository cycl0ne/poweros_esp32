// SPDX-License-Identifier: MIT
//! The packing engine: input copied into a window, repeats found in it,
//! and the result written as DEFLATE blocks (RFC 1951) in their wrapping,
//! through a pending buffer the caller's output drains.
//!
//! **Repeats** are found through a table of where each three bytes were
//! last seen and a chain back from each place to the one before with the
//! same three bytes, in a window of 64 KiB: the 32 KiB a repeat may reach
//! back into and as much again of input ahead. Matching is lazy: a repeat
//! found at one place is held while the next place is tried, and the
//! longer of the two is taken. The level decides how far down a chain to
//! look and when a repeat is long enough to stop looking (zlib's table of
//! good, lazy, nice and chain). When the input ahead reaches the window's
//! end, the upper half moves down and every place in the tables with it.
//!
//! **A block** is the symbols since the last one - literals, and lengths
//! with distances - kept in a buffer of 16384. When it fills, before the
//! window moves the block's bytes out of reach, at a FLUSH_SYNC and at
//! the end, the block is written whichever way is smallest: its bytes as
//! they are (stored), in the fixed codes, or in codes made for it from
//! its symbols' counts - Huffman's, limited to 15 bits (7 for the
//! code-length code) by moving the overflow up the tree. Level 0 writes
//! stored blocks only and looks for nothing.
//!
//! The counts, codes and tree a block is written with are kept in the
//! state, not on the stack: a library's call runs on its caller's stack,
//! and these come to some 13 KiB.
//!
//! **The output** of a block goes to a pending buffer large enough for the
//! largest (a stored block of 64 KiB), and from there into the caller's
//! output as there is room; no input is taken while anything is pending.
//! The wrapping's header goes first, its checksum - of the input, as it is
//! copied in - and gzip's length after the last block.

const sdk = @import("sdk");
const exec = sdk.exec;
const compression = sdk.compression;
const ExecBase = sdk.interface.exec.ExecBase;
const _checksum = @import("../checksum/_checksum.zig");

/// What `state` points at in a Stream that InitDeflate set up, first.
pub const magic: u32 = 0x4445_464C; // "DEFL"

const window_size = 32 * 1024;
const window_mask = window_size - 1;
/// The window and the input ahead of it.
const buffer_size = 2 * window_size;
const hash_bits = 15;
const hash_size = 1 << hash_bits;
const min_match = 3;
const max_match = 258;
/// Input ahead that a search wants: a longest repeat and the next three
/// bytes to hash.
const min_lookahead = max_match + min_match + 1;
/// The furthest back a repeat is taken from.
const max_distance = window_size - min_lookahead;
/// A three-byte repeat further back than this costs more than its bytes.
const too_far = 4096;
const symbol_count = 16 * 1024;
/// The largest block (a stored one of all the window's bytes, in two
/// pieces) with the empty block of a FLUSH_SYNC, the header and the
/// trailer.
const pending_size = buffer_size + 256;
const stored_max = 65535;

const literal_symbols = 286;
const distance_symbols = 30;
const length_symbols = 19;

/// zlib's table: a repeat this long makes the chain a quarter as long,
/// one this long is not bettered at the next place, one this long ends
/// the search, and how many places down the chain are tried.
const Config = struct { good: u16, lazy: u16, nice: u16, chain: u16 };
const configs = [10]Config{
    .{ .good = 0, .lazy = 0, .nice = 0, .chain = 0 },
    .{ .good = 4, .lazy = 4, .nice = 8, .chain = 4 },
    .{ .good = 4, .lazy = 5, .nice = 16, .chain = 8 },
    .{ .good = 4, .lazy = 6, .nice = 32, .chain = 32 },
    .{ .good = 4, .lazy = 4, .nice = 16, .chain = 16 },
    .{ .good = 8, .lazy = 16, .nice = 32, .chain = 32 },
    .{ .good = 8, .lazy = 16, .nice = 128, .chain = 128 },
    .{ .good = 8, .lazy = 32, .nice = 128, .chain = 256 },
    .{ .good = 32, .lazy = 128, .nice = 258, .chain = 1024 },
    .{ .good = 32, .lazy = 258, .nice = 258, .chain = 4096 },
};

pub const State = struct {
    magic: u32 = magic,
    format: u32,
    level: u32,
    config: Config,
    /// The window, and the input ahead of `start`.
    window: [buffer_size]u8 = undefined,
    /// For each hash, the latest place with those three bytes; 0 for none
    /// (place 0 is never a repeat's source).
    head: [hash_size]u16 = @splat(0),
    /// For each place (modulo the window), the place before it with the
    /// same three bytes.
    prev: [window_size]u16 = @splat(0),
    /// The place being looked at, and the input from there on.
    start: u32 = 0,
    lookahead: u32 = 0,
    /// The first byte of the block being gathered.
    block_start: u32 = 0,
    /// The lazy match: the repeat found at the place before, and whether
    /// that place's literal is still to be written.
    match_length: u32 = min_match - 1,
    match_start: u32 = 0,
    previous_length: u32 = min_match - 1,
    previous_match: u32 = 0,
    match_waiting: bool = false,
    /// The block's symbols: a distance (0 for a literal) and the literal or
    /// the length less three.
    symbol_distance: [symbol_count]u16 = undefined,
    symbol_value: [symbol_count]u8 = undefined,
    symbols: u32 = 0,
    /// Bits waiting for a whole byte, and bytes waiting for the output.
    bit_buffer: u64 = 0,
    bit_count: u32 = 0,
    pending: [pending_size]u8 = undefined,
    pending_start: u32 = 0,
    pending_end: u32 = 0,
    /// The checksum of the input, and how much there has been.
    check: u32 = 0,
    taken: u64 = 0,
    header_written: bool = false,
    /// A FLUSH_SYNC done since the last input; the end written.
    synced: bool = false,
    finished: bool = false,
    /// What writing a block works with.
    block: Block = undefined,
};

/// The work of writing one block: its symbols' counts, the code lengths
/// made from them, those lengths shortened into runs, and the codes.
const Block = struct {
    literal_counts: [288]u32,
    distance_counts: [30]u32,
    literal_lengths: [literal_symbols]u8,
    distance_lengths: [distance_symbols]u8,
    all: [literal_symbols + distance_symbols]u8,
    runs: [literal_symbols + distance_symbols]Run,
    length_counts: [length_symbols]u32,
    length_lengths: [length_symbols]u8,
    literal_code: Code,
    distance_code: Code,
    length_code: Code,
    tree: Tree,
};

/// Huffman's tree for up to 288 symbols: the symbols in order of how
/// often they come, and each node's weight, parent and depth.
const Tree = struct {
    order: [288]u16,
    weight: [2 * 288]u32,
    parent: [2 * 288]u16,
    depth: [2 * 288]u16,
};

/// A state set up for `format` and `level`, which the caller has
/// checked. Large (about 320 KiB): the caller allocates it.
pub fn begin(state: *State, format: u32, level: u32) void {
    state.magic = magic;
    state.format = format;
    state.level = level;
    state.config = configs[level];
    state.head = @splat(0);
    state.prev = @splat(0);
    state.start = 0;
    state.lookahead = 0;
    state.block_start = 0;
    state.match_length = min_match - 1;
    state.match_start = 0;
    state.previous_length = min_match - 1;
    state.previous_match = 0;
    state.match_waiting = false;
    state.symbols = 0;
    state.bit_buffer = 0;
    state.bit_count = 0;
    state.pending_start = 0;
    state.pending_end = 0;
    state.check = if (format == compression.FORMAT_ZLIB) 1 else 0;
    state.taken = 0;
    state.header_written = false;
    state.synced = false;
    state.finished = false;
}

/// The deflate state of `stream`, or null when the Stream is too small
/// or was not set up by InitDeflate (or has been ended).
pub fn of(stream: *compression.Stream) ?*State {
    if (stream.size < @sizeOf(compression.Stream)) return null;
    const raw = stream.state orelse return null;
    const state: *State = @ptrCast(@alignCast(raw));
    return if (state.magic == magic) state else null;
}

// --- the codes' tables ------------------------------------------------------------

const length_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const length_extra = [29]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const distance_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const distance_extra = [30]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
const length_order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

/// The length code (0 to 28) of each length less three.
const length_code = blk: {
    @setEvalBranchQuota(20_000);
    var table: [256]u8 = undefined;
    for (0..256) |less| {
        var code: u8 = 28;
        while (length_base[code] > less + 3) code -= 1;
        table[less] = code;
    }
    break :blk table;
};

fn distanceCode(distance: u32) u32 {
    var code: u32 = 29;
    while (distance_base[code] > distance) code -= 1;
    return code;
}

/// The fixed codes' lengths.
const fixed_literal_lengths = blk: {
    @setEvalBranchQuota(4_000);
    var lengths: [288]u8 = undefined;
    for (&lengths, 0..) |*length, symbol| length.* = if (symbol < 144) 8 else if (symbol < 256) 9 else if (symbol < 280) 7 else 8;
    break :blk lengths;
};
const fixed_distance_lengths: [30]u8 = @splat(5);

/// A code to write with: each symbol's length and its bits, reversed for
/// the stream's low-bit-first order.
const Code = struct {
    lengths: [288]u8 = @splat(0),
    bits: [288]u16 = @splat(0),

    /// The canonical codes for `lengths`.
    fn make(code: *Code, lengths: []const u8) void {
        code.lengths = @splat(0);
        @memcpy(code.lengths[0..lengths.len], lengths);
        var count: [16]u16 = @splat(0);
        for (lengths) |length| count[length] += 1;
        count[0] = 0;
        var next: [16]u16 = undefined;
        var value: u16 = 0;
        for (1..16) |length| {
            value = (value + count[length - 1]) << 1;
            next[length] = value;
        }
        for (lengths, 0..) |length, symbol| {
            if (length == 0) continue;
            code.bits[symbol] = reverse(next[length], length);
            next[length] += 1;
        }
    }
};

fn reverse(value: u16, length: u8) u16 {
    var result: u16 = 0;
    var rest = value;
    for (0..length) |_| {
        result = result << 1 | (rest & 1);
        rest >>= 1;
    }
    return result;
}

/// Huffman's code lengths for `counts`, none longer than `limit`, into
/// `lengths`: 0 for a symbol that does not come. `tree` is worked in.
fn huffman(tree: *Tree, counts: []const u32, lengths: []u8, limit: u8) void {
    @memset(lengths, 0);
    // The symbols that come, least often first.
    const order = &tree.order;
    var used: usize = 0;
    for (counts, 0..) |count, symbol| {
        if (count == 0) continue;
        var at = used;
        while (at > 0 and counts[order[at - 1]] > count) : (at -= 1) order[at] = order[at - 1];
        order[at] = @intCast(symbol);
        used += 1;
    }
    if (used == 0) return;
    if (used == 1) {
        lengths[order[0]] = 1;
        return;
    }

    // The tree, by two queues: the leaves in order, and the nodes made of
    // them, which come out in order too. Each node's parent is kept, so a
    // leaf's depth is its parent's and one.
    const weight = &tree.weight;
    const parent = &tree.parent;
    for (order[0..used], 0..) |symbol, index| weight[index] = counts[symbol];
    var leaf: usize = 0;
    var node: usize = used;
    var made: usize = used;
    while (made < 2 * used - 1) : (made += 1) {
        var pair: [2]usize = undefined;
        for (&pair) |*pick| {
            if (leaf < used and (node >= made or weight[leaf] <= weight[node])) {
                pick.* = leaf;
                leaf += 1;
            } else {
                pick.* = node;
                node += 1;
            }
        }
        weight[made] = weight[pair[0]] + weight[pair[1]];
        parent[pair[0]] = @intCast(made);
        parent[pair[1]] = @intCast(made);
    }
    // Depths from the root down: a node is made after its children, so in
    // reverse order of making each parent's depth is known first.
    const depth = &tree.depth;
    depth[made - 1] = 0;
    var at = made - 1;
    while (at > 0) {
        at -= 1;
        depth[at] = depth[parent[at]] + 1;
    }

    // How many leaves at each length, the too long counted at the limit,
    // and the room they take back made by moving leaves down (zlib's
    // gen_bitlen).
    // How many leaves at each length, the too long cut to the limit; then,
    // while the lengths ask for more room than a code has (the sum of
    // 2^(limit - length) above 2^limit), a leaf at the limit and one
    // above it both go just below the shorter one (zlib's gen_bitlen),
    // which gives back one unit at a time.
    var count: [16]u16 = @splat(0);
    var room: u32 = 0;
    for (0..used) |index| {
        const length: u8 = @intCast(@min(depth[index], limit));
        count[length] += 1;
        room += @as(u32, 1) << @intCast(limit - length);
    }
    while (room > @as(u32, 1) << @intCast(limit)) : (room -= 1) {
        var bits = limit - 1;
        while (count[bits] == 0) bits -= 1;
        count[bits] -= 1;
        count[bits + 1] += 2;
        count[limit] -= 1;
    }
    // The longest codes to the least often.
    var symbol_at: usize = 0;
    var length: u8 = limit;
    while (length > 0) : (length -= 1) {
        for (0..count[length]) |_| {
            lengths[order[symbol_at]] = length;
            symbol_at += 1;
        }
    }
}

// --- one call -----------------------------------------------------------------------

/// The stream in `stream` run on as far as its input and output let it,
/// with `flush` saying what to do when the input is used up.
pub fn run(state: *State, stream: *compression.Stream, flush: u32) i32 {
    var input: []const u8 = if (stream.next_in) |next| next[0..stream.avail_in] else &.{};
    var output: []u8 = if (stream.next_out) |next| next[0..stream.avail_out] else &.{};
    const input_start = input.len;
    const output_start = output.len;
    defer {
        const taken = input_start - input.len;
        const written = output_start - output.len;
        if (taken != 0) stream.next_in = stream.next_in.? + taken;
        stream.avail_in -= @intCast(taken);
        stream.total_in += taken;
        if (written != 0) stream.next_out = stream.next_out.? + written;
        stream.avail_out -= @intCast(written);
        stream.total_out += written;
        stream.format = state.format;
    }

    if (!state.header_written) {
        writeHeader(state);
        state.header_written = true;
    }
    while (true) {
        drain(state, &output);
        if (state.pending_end != 0) return compression.COMPRESS_OK;
        if (state.finished) return compression.COMPRESS_END;

        if (input.len != 0) {
            state.synced = false;
            fill(state, &input);
            // Moving the window may have written the block.
            if (state.pending_end != 0) continue;
        }
        const ending = input.len == 0 and flush != compression.FLUSH_NONE;
        if (gather(state, ending)) {
            // The symbols are full: out with the block, and on.
            writeBlock(state, false);
            continue;
        }
        if (input.len != 0) continue;
        switch (flush) {
            compression.FLUSH_SYNC => {
                if (state.synced) return compression.COMPRESS_OK;
                if (state.start > state.block_start) writeBlock(state, false);
                // An empty stored block: everything so far ends on a byte.
                putBits(state, 0, 3);
                alignBits(state);
                putPending(state, &.{ 0, 0, 0xFF, 0xFF });
                state.synced = true;
            },
            compression.FLUSH_FINISH => {
                writeBlock(state, true);
                alignBits(state);
                writeTrailer(state);
                state.finished = true;
            },
            else => return compression.COMPRESS_OK,
        }
    }
}

/// As much of the pending output as there is room for.
fn drain(state: *State, output: *[]u8) void {
    const count = @min(output.len, state.pending_end - state.pending_start);
    @memcpy(output.*[0..count], state.pending[state.pending_start..][0..count]);
    output.* = output.*[count..];
    state.pending_start += @intCast(count);
    if (state.pending_start == state.pending_end) {
        state.pending_start = 0;
        state.pending_end = 0;
    }
}

/// Input into the window behind what is there, the window moved down
/// first when the input ahead has reached its end.
fn fill(state: *State, input: *[]const u8) void {
    if (state.start >= window_size + max_distance) slide(state);
    const end = state.start + state.lookahead;
    const count = @min(input.len, buffer_size - end);
    const fresh = input.*[0..count];
    @memcpy(state.window[end..][0..count], fresh);
    switch (state.format) {
        compression.FORMAT_ZLIB => state.check = _checksum.adler32(state.check, fresh),
        compression.FORMAT_GZIP => state.check = _checksum.crc32(state.check, fresh),
        else => {},
    }
    state.taken += count;
    state.lookahead += @intCast(count);
    input.* = input.*[count..];
}

/// The window's upper half moved down, and every place with it; the block
/// written first when its bytes would go.
fn slide(state: *State) void {
    if (state.block_start < window_size) writeBlock(state, false);
    @memcpy(state.window[0..window_size], state.window[window_size..buffer_size]);
    state.start -= window_size;
    state.block_start -= window_size;
    state.match_start -|= window_size;
    state.previous_match -|= window_size;
    for (&state.head) |*place| place.* = if (place.* >= window_size) place.* - window_size else 0;
    for (&state.prev) |*place| place.* = if (place.* >= window_size) place.* - window_size else 0;
}

fn hashAt(state: *State, place: u32) u32 {
    const bytes = state.window[place..][0..3];
    const value = @as(u32, bytes[0]) << 16 | @as(u32, bytes[1]) << 8 | bytes[2];
    return (value *% 2654435761) >> (32 - hash_bits);
}

/// `place` put at the head of its chain; the head before, which is where
/// a search from it starts.
fn insert(state: *State, place: u32) u32 {
    const hash = hashAt(state, place);
    const before = state.head[hash];
    state.prev[place & window_mask] = before;
    state.head[hash] = @intCast(place);
    return before;
}

/// The longest repeat of what is at `start` that the chain from
/// `candidate` has, longer than `state.previous_length`.
fn longest(state: *State, first_candidate: u32) void {
    var chain: u32 = state.config.chain;
    if (state.previous_length >= state.config.good) chain >>= 2;
    const scan = state.start;
    const limit = if (scan > max_distance) scan - max_distance else 0;
    const most = @min(max_match, state.lookahead);
    const nice = @min(state.config.nice, most);
    var best = state.previous_length;
    var candidate = first_candidate;
    const window = &state.window;
    while (true) {
        if (best < most and window[candidate + best] == window[scan + best] and window[candidate] == window[scan]) {
            var length: u32 = 1;
            while (length < most and window[candidate + length] == window[scan + length]) length += 1;
            if (length > best) {
                best = length;
                state.match_start = candidate;
                if (length >= nice) break;
            }
        }
        const next = state.prev[candidate & window_mask];
        if (next <= limit or next >= candidate) break;
        candidate = next;
        chain -= 1;
        if (chain == 0) break;
    }
    state.match_length = @min(best, state.lookahead);
}

/// The window's input turned into symbols, lazily, until the symbols are
/// full - or at level 0 a stored block's worth is there - (true), or the
/// input ahead is too short to search well (or, when `ending`, all gone).
fn gather(state: *State, ending: bool) bool {
    if (state.level == 0) {
        // Stored only: the bytes are the block.
        state.start += state.lookahead;
        state.lookahead = 0;
        return state.start - state.block_start >= stored_max;
    }
    while (state.lookahead >= min_lookahead or (ending and state.lookahead > 0)) {
        if (state.symbols >= symbol_count - 1) return true;
        var head: u32 = 0;
        if (state.lookahead >= min_match) head = insert(state, state.start);
        state.previous_length = state.match_length;
        state.previous_match = state.match_start;
        state.match_length = min_match - 1;
        if (head != 0 and state.previous_length < state.config.lazy and state.start - head <= max_distance) {
            longest(state, head);
            if (state.match_length == min_match and state.start - state.match_start > too_far) state.match_length = min_match - 1;
            if (state.match_length < min_match) state.match_length = min_match - 1;
        }
        if (state.previous_length >= min_match and state.match_length <= state.previous_length) {
            // The repeat before is the better one: it starts one back.
            record(state, state.start - 1 - state.previous_match, state.previous_length - min_match);
            // Its places into the chains, but for the two already there;
            // the last place a hash can be taken at is three short of the
            // input's end.
            const hashable = state.start + state.lookahead;
            state.lookahead -= state.previous_length - 1;
            var left = state.previous_length - 2;
            while (left > 0) : (left -= 1) {
                state.start += 1;
                if (state.start + min_match <= hashable) _ = insert(state, state.start);
            }
            state.start += 1;
            state.match_waiting = false;
            state.match_length = min_match - 1;
        } else if (state.match_waiting) {
            record(state, 0, state.window[state.start - 1]);
            state.start += 1;
            state.lookahead -= 1;
        } else {
            state.match_waiting = true;
            state.start += 1;
            state.lookahead -= 1;
        }
    }
    if (ending) {
        // All the input is symbols now: nothing is held for the next.
        if (state.match_waiting) record(state, 0, state.window[state.start - 1]);
        state.match_waiting = false;
        state.match_length = min_match - 1;
        state.previous_length = min_match - 1;
    }
    return false;
}

fn record(state: *State, distance: u32, value: u32) void {
    state.symbol_distance[state.symbols] = @intCast(distance);
    state.symbol_value[state.symbols] = @intCast(value);
    state.symbols += 1;
}

// --- writing ------------------------------------------------------------------------

fn putBits(state: *State, value: u32, count: u32) void {
    state.bit_buffer |= @as(u64, value) << @intCast(state.bit_count);
    state.bit_count += count;
    while (state.bit_count >= 8) {
        state.pending[state.pending_end] = @truncate(state.bit_buffer);
        state.pending_end += 1;
        state.bit_buffer >>= 8;
        state.bit_count -= 8;
    }
}

/// The bits to the next byte filled with zeros.
fn alignBits(state: *State) void {
    if (state.bit_count != 0) putBits(state, 0, 8 - state.bit_count);
}

fn putPending(state: *State, bytes: []const u8) void {
    @memcpy(state.pending[state.pending_end..][0..bytes.len], bytes);
    state.pending_end += @intCast(bytes.len);
}

fn writeHeader(state: *State) void {
    switch (state.format) {
        compression.FORMAT_ZLIB => {
            const level_flags: u16 = if (state.level < 2) 0 else if (state.level < 6) 1 else if (state.level == 6) 2 else 3;
            var header: u16 = 0x7800 | level_flags << 6;
            header += (31 - header % 31) % 31;
            putPending(state, &.{ @truncate(header >> 8), @truncate(header) });
        },
        // No name, no time, made on an unknown system.
        compression.FORMAT_GZIP => putPending(state, &.{ 0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF }),
        else => {},
    }
}

fn writeTrailer(state: *State) void {
    const check = state.check;
    switch (state.format) {
        compression.FORMAT_ZLIB => putPending(state, &.{ @truncate(check >> 24), @truncate(check >> 16), @truncate(check >> 8), @truncate(check) }),
        compression.FORMAT_GZIP => {
            const size: u32 = @truncate(state.taken);
            putPending(state, &.{ @truncate(check), @truncate(check >> 8), @truncate(check >> 16), @truncate(check >> 24), @truncate(size), @truncate(size >> 8), @truncate(size >> 16), @truncate(size >> 24) });
        },
        else => {},
    }
}

/// The block from `block_start` to `start` - but for a literal held back -
/// with the symbols gathered for it, written whichever way is smallest.
fn writeBlock(state: *State, last: bool) void {
    // A literal held back for a better repeat is not a symbol yet: it
    // belongs to the next block, stored or not.
    const end = state.start - @intFromBool(state.match_waiting);
    const raw = state.window[state.block_start..end];
    defer {
        state.block_start = end;
        state.symbols = 0;
    }
    if (state.level == 0) return writeStored(state, raw, last);

    const block = &state.block;
    const literal_counts = &block.literal_counts;
    const distance_counts = &block.distance_counts;
    literal_counts.* = @splat(0);
    distance_counts.* = @splat(0);
    for (state.symbol_distance[0..state.symbols], state.symbol_value[0..state.symbols]) |distance, value| {
        if (distance == 0) {
            literal_counts[value] += 1;
        } else {
            literal_counts[257 + @as(usize, length_code[value])] += 1;
            distance_counts[distanceCode(distance)] += 1;
        }
    }
    literal_counts[256] = 1;

    const literal_lengths = &block.literal_lengths;
    const distance_lengths = &block.distance_lengths;
    huffman(&block.tree, literal_counts[0..literal_symbols], literal_lengths, 15);
    huffman(&block.tree, distance_counts, distance_lengths, 15);

    var literal_used: u32 = literal_symbols;
    while (literal_used > 257 and literal_lengths[literal_used - 1] == 0) literal_used -= 1;
    var distance_used: u32 = distance_symbols;
    while (distance_used > 1 and distance_lengths[distance_used - 1] == 0) distance_used -= 1;

    // The lengths of both codes in one run, shortened by repeats.
    const all = &block.all;
    @memcpy(all[0..literal_used], literal_lengths[0..literal_used]);
    @memcpy(all[literal_used..][0..distance_used], distance_lengths[0..distance_used]);
    const runs = &block.runs;
    const run_count = shorten(all[0 .. literal_used + distance_used], runs);
    const length_counts = &block.length_counts;
    length_counts.* = @splat(0);
    for (runs[0..run_count]) |item| length_counts[item.symbol] += 1;
    // A decoder takes a code-length code of two codes at least: a lone one
    // gets a partner that is never sent.
    var length_kinds: u32 = 0;
    for (length_counts.*) |count| length_kinds += @intFromBool(count != 0);
    var spare: usize = 0;
    while (length_kinds < 2) : (spare += 1) {
        if (length_counts[spare] == 0) {
            length_counts[spare] = 1;
            length_kinds += 1;
        }
    }
    const length_lengths = &block.length_lengths;
    huffman(&block.tree, length_counts, length_lengths, 7);
    var length_used: u32 = length_symbols;
    while (length_used > 4 and length_lengths[length_order[length_used - 1]] == 0) length_used -= 1;

    // Each way's size in bits.
    const data_dynamic = dataBits(literal_counts, distance_counts, literal_lengths, distance_lengths);
    var dynamic_bits: u64 = 3 + 14 + 3 * @as(u64, length_used) + data_dynamic;
    for (runs[0..run_count]) |item| dynamic_bits += length_lengths[item.symbol] + item.extra_bits;
    const fixed_bits: u64 = 3 + dataBits(literal_counts, distance_counts, fixed_literal_lengths[0..literal_symbols], &fixed_distance_lengths);
    const pieces: u64 = @max(1, (raw.len + stored_max - 1) / stored_max);
    const stored_bits: u64 = 7 + pieces * (3 + 32 + 8) + 8 * @as(u64, raw.len);

    if (stored_bits <= fixed_bits and stored_bits <= dynamic_bits) return writeStored(state, raw, last);

    const literal_code = &block.literal_code;
    const distance_code = &block.distance_code;
    if (fixed_bits <= dynamic_bits) {
        putBits(state, @as(u32, @intFromBool(last)) | 1 << 1, 3);
        literal_code.make(&fixed_literal_lengths);
        distance_code.make(&fixed_distance_lengths);
    } else {
        putBits(state, @as(u32, @intFromBool(last)) | 2 << 1, 3);
        putBits(state, literal_used - 257, 5);
        putBits(state, distance_used - 1, 5);
        putBits(state, length_used - 4, 4);
        for (length_order[0..length_used]) |symbol| putBits(state, length_lengths[symbol], 3);
        const length_code_bits = &block.length_code;
        length_code_bits.make(length_lengths);
        for (runs[0..run_count]) |item| {
            putBits(state, length_code_bits.bits[item.symbol], length_lengths[item.symbol]);
            if (item.extra_bits != 0) putBits(state, item.extra, item.extra_bits);
        }
        literal_code.make(literal_lengths);
        distance_code.make(distance_lengths);
    }
    for (state.symbol_distance[0..state.symbols], state.symbol_value[0..state.symbols]) |distance, value| {
        if (distance == 0) {
            putBits(state, literal_code.bits[value], literal_code.lengths[value]);
            continue;
        }
        const code = length_code[value];
        const symbol = 257 + @as(usize, code);
        putBits(state, literal_code.bits[symbol], literal_code.lengths[symbol]);
        if (length_extra[code] != 0) putBits(state, @as(u32, value) + 3 - length_base[code], length_extra[code]);
        const distance_symbol = distanceCode(distance);
        putBits(state, distance_code.bits[distance_symbol], distance_code.lengths[distance_symbol]);
        if (distance_extra[distance_symbol] != 0) putBits(state, distance - distance_base[distance_symbol], distance_extra[distance_symbol]);
    }
    putBits(state, literal_code.bits[256], literal_code.lengths[256]);
}

/// `raw` as stored blocks of 65535 bytes at most; none of them the last
/// unless `last`.
fn writeStored(state: *State, raw: []const u8, last: bool) void {
    var rest = raw;
    while (true) {
        const count = @min(rest.len, stored_max);
        const final = last and count == rest.len;
        putBits(state, @intFromBool(final), 3);
        alignBits(state);
        const length: u16 = @intCast(count);
        putPending(state, &.{ @truncate(length), @truncate(length >> 8), @truncate(~length), @truncate(~length >> 8) });
        putPending(state, rest[0..count]);
        rest = rest[count..];
        if (rest.len == 0) break;
    }
}

fn dataBits(literal_counts: *const [288]u32, distance_counts: *const [30]u32, literal_lengths: []const u8, distance_lengths: []const u8) u64 {
    var bits: u64 = 0;
    for (0..literal_symbols) |symbol| {
        bits += @as(u64, literal_counts[symbol]) * literal_lengths[symbol];
        if (symbol >= 257) bits += @as(u64, literal_counts[symbol]) * length_extra[symbol - 257];
    }
    for (0..distance_symbols) |symbol| bits += @as(u64, distance_counts[symbol]) * (distance_lengths[symbol] + distance_extra[symbol]);
    return bits;
}

/// One symbol of the code-length code and its extra bits.
const Run = struct { symbol: u8, extra: u32 = 0, extra_bits: u8 = 0 };

/// Code lengths as the code-length code's symbols: runs of zeros as 17
/// and 18, runs of another length as the length and then 16s.
fn shorten(lengths: []const u8, into: []Run) usize {
    var count: usize = 0;
    var at: usize = 0;
    while (at < lengths.len) {
        const value = lengths[at];
        var same: usize = 1;
        while (at + same < lengths.len and lengths[at + same] == value) same += 1;
        at += same;
        if (value == 0) {
            while (same >= 11) {
                const part = @min(same, 138);
                into[count] = .{ .symbol = 18, .extra = @intCast(part - 11), .extra_bits = 7 };
                count += 1;
                same -= part;
            }
            if (same >= 3) {
                into[count] = .{ .symbol = 17, .extra = @intCast(same - 3), .extra_bits = 3 };
                count += 1;
                same = 0;
            }
        } else {
            into[count] = .{ .symbol = value };
            count += 1;
            same -= 1;
            while (same >= 3) {
                const part = @min(same, 6);
                into[count] = .{ .symbol = 16, .extra = @intCast(part - 3), .extra_bits = 2 };
                count += 1;
                same -= part;
            }
        }
        while (same > 0) : (same -= 1) {
            into[count] = .{ .symbol = value };
            count += 1;
        }
    }
    return count;
}
