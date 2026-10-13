// SPDX-License-Identifier: MIT
//! A PNG written: a picture of 8-bit RGB, its rows filtered and the whole
//! deflated in one stream, handed to the caller's sink as the file's
//! bytes.
//!
//! **The rows** come in the form a PNG's data has before it is
//! compressed: each row a filter byte and then its pixels, three bytes
//! each. Each row is filtered in place with whichever of the five filters
//! makes the smallest sum of its bytes taken as signed - the usual guess
//! at what compresses best, and the one that suits a screen, whose rows
//! are mostly a copy of the row above or of the pixel before. Filtering
//! goes from the last row up, so the row above is still as it was when a
//! row is filtered against it.
//!
//! **The stream** is zlib around one deflate block of the fixed codes:
//! each place in the rows looks for the longest run that began within the
//! last 32 KiB - through a table of where each three bytes were last seen
//! and a chain back from there - and writes it as a length and a distance
//! when it is three bytes or more, as a byte otherwise. The fixed codes
//! need no table in the file; a screen's long runs are what makes it
//! small, not the codes. The compressed bytes go out in IDAT chunks of up
//! to 32 KiB.
//!
//! The checksums - each chunk's CRC-32, the stream's Adler-32 - are the
//! PNG decoder's own (sdk/libs/datatypes/png/).

const sdk = @import("sdk");
const decode = sdk.datatypes.png.decode;
const inflate = sdk.datatypes.png.inflate;

/// Where the file's bytes go: false when they could not be taken.
pub const Sink = struct {
    context: *anyopaque,
    put: *const fn (context: *anyopaque, bytes: []const u8) bool,
};

const window = 32 * 1024;
const hash_bits = 15;
const hash_size = 1 << hash_bits;
/// How many earlier places with the same three bytes are tried.
const chain_tries = 48;
const min_match = 3;
const max_match = 258;
const chunk_data = 32 * 1024;

/// The memory the writer works in: the caller's, about 290 KiB.
pub const Work = struct {
    /// Where each three bytes were last seen, plus one; 0 for nowhere.
    head: [hash_size]u32,
    /// For each place in the window, the place before it with the same
    /// three bytes, plus one.
    chain: [window]u32,
    /// The chunk being filled: its type, then its data.
    chunk: [4 + chunk_data]u8,
    used: usize,
    bits: u64,
    bit_count: u6,
    sink: Sink,
    failed: bool,
};

/// The bytes the rows of a picture `width` pixels wide take: a filter byte
/// and three bytes a pixel each.
pub fn rowBytes(width: u32) usize {
    return 1 + @as(usize, width) * 3;
}

/// The picture in `rows` - `height` of `rowBytes(width)` bytes, the first
/// of each left for its filter - written as a PNG to `sink`. The rows are
/// filtered in place. False when the sink failed.
pub fn write(work: *Work, sink: Sink, width: u32, height: u32, rows: []u8) bool {
    work.sink = sink;
    work.failed = false;
    work.used = 0;
    work.bits = 0;
    work.bit_count = 0;

    if (!sink.put(sink.context, &.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' })) return false;
    var header: [13]u8 = undefined;
    big32(header[0..4], width);
    big32(header[4..8], height);
    // 8 bits a channel, RGB, deflate, the five filters, not interlaced.
    @memcpy(header[8..13], &[_]u8{ 8, 2, 0, 0, 0 });
    if (!putChunk(work, "IHDR", &header)) return false;

    const stride = rowBytes(width);
    var row = height;
    while (row > 0) {
        row -= 1;
        const this = rows[row * stride ..][0..stride];
        const above = if (row > 0) rows[(row - 1) * stride ..][0..stride] else null;
        filterRow(this, above);
    }

    work.chunk[0..4].* = "IDAT".*;
    // zlib: deflate with a 32 KiB window, no dictionary, the check bits.
    putByte(work, 0x78);
    putByte(work, 0x01);
    deflate(work, rows[0 .. stride * height]);
    var check: [4]u8 = undefined;
    big32(&check, inflate.adler32(rows[0 .. stride * height]));
    for (check) |byte| putByte(work, byte);
    flushChunk(work);
    if (work.failed) return false;
    return putChunk(work, "IEND", &.{});
}

// --- filters ----------------------------------------------------------------------

/// A row filtered in place against the one above (null for the first),
/// by the filter whose bytes come to the least.
fn filterRow(row: []u8, above: ?[]const u8) void {
    const pixels = row[1..];
    var best: u8 = 0;
    var best_sum: u64 = ~@as(u64, 0);
    for (0..5) |kind| {
        var sum: u64 = 0;
        for (pixels, 0..) |byte, i| {
            const value = byte -% predict(@intCast(kind), pixels, above, i);
            sum += if (value < 128) value else 256 - @as(u32, value);
        }
        if (sum < best_sum) {
            best_sum = sum;
            best = @intCast(kind);
        }
    }
    // From the right, so what the prediction reads to the left is still
    // the pixel itself.
    var i = pixels.len;
    while (i > 0) {
        i -= 1;
        pixels[i] -%= predict(best, pixels, above, i);
    }
    row[0] = best;
}

/// What filter `kind` predicts byte `i` of a row to be, from the byte a
/// pixel to the left, the byte above, and the one above that to the left.
fn predict(kind: u8, pixels: []const u8, above: ?[]const u8, i: usize) u8 {
    const left: u8 = if (i >= 3) pixels[i - 3] else 0;
    const up: u8 = if (above) |row| row[1 + i] else 0;
    const corner: u8 = if (above != null and i >= 3) above.?[1 + i - 3] else 0;
    return switch (kind) {
        0 => 0,
        1 => left,
        2 => up,
        3 => @intCast((@as(u32, left) + up) / 2),
        else => paeth(left, up, corner),
    };
}

fn paeth(left: u8, up: u8, corner: u8) u8 {
    const estimate = @as(i32, left) + up - corner;
    const to_left = @abs(estimate - left);
    const to_up = @abs(estimate - up);
    const to_corner = @abs(estimate - corner);
    if (to_left <= to_up and to_left <= to_corner) return left;
    if (to_up <= to_corner) return up;
    return corner;
}

// --- deflate ----------------------------------------------------------------------

const length_base = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const length_extra = [_]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const distance_base = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const distance_extra = [_]u5{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

/// The fixed code of each literal and length, bits reversed - deflate sends
/// a code's first bit first, into a stream filled from the low bit - and
/// its length.
const Code = struct { bits: u16, length: u5 };
const literal_codes = blk: {
    @setEvalBranchQuota(20_000);
    var codes: [288]Code = undefined;
    for (&codes, 0..) |*code, symbol| {
        const fixed: struct { u16, u5 } = if (symbol < 144)
            .{ 0x30 + symbol, 8 }
        else if (symbol < 256)
            .{ 0x190 + symbol - 144, 9 }
        else if (symbol < 280)
            .{ symbol - 256, 7 }
        else
            .{ 0xC0 + symbol - 280, 8 };
        code.* = .{ .bits = reverse(fixed[0], fixed[1]), .length = fixed[1] };
    }
    break :blk codes;
};

fn reverse(value: u16, length: u5) u16 {
    var out: u16 = 0;
    for (0..length) |i| out |= ((value >> @intCast(i)) & 1) << @intCast(length - 1 - i);
    return out;
}

/// `bytes` as one final block of the fixed codes.
fn deflate(work: *Work, bytes: []const u8) void {
    putBits(work, 1, 1); // the last block
    putBits(work, 1, 2); // of the fixed codes
    @memset(&work.head, 0);
    var at: usize = 0;
    while (at < bytes.len) {
        const found = longest(work, bytes, at);
        if (found.length >= min_match) {
            putLength(work, found.length);
            putDistance(work, found.distance);
            for (0..found.length) |step| remember(work, bytes, at + step);
            at += found.length;
        } else {
            putSymbol(work, bytes[at]);
            remember(work, bytes, at);
            at += 1;
        }
        if (work.failed) return;
    }
    putSymbol(work, 256);
    // To a whole byte.
    if (work.bit_count > 0) putBits(work, 0, 8 - @as(u7, work.bit_count % 8));
}

fn hashAt(bytes: []const u8, at: usize) u32 {
    const three = @as(u32, bytes[at]) << 16 | @as(u32, bytes[at + 1]) << 8 | bytes[at + 2];
    return (three *% 2654435761) >> (32 - hash_bits);
}

/// Place `at` entered in the table and the chain.
fn remember(work: *Work, bytes: []const u8, at: usize) void {
    if (at + min_match > bytes.len) return;
    const hash = hashAt(bytes, at);
    work.chain[at % window] = work.head[hash];
    work.head[hash] = @intCast(at + 1);
}

/// The longest earlier run within the window that `at` repeats.
fn longest(work: *Work, bytes: []const u8, at: usize) struct { length: usize, distance: usize } {
    if (at + min_match > bytes.len) return .{ .length = 0, .distance = 0 };
    const most = @min(max_match, bytes.len - at);
    var best: usize = 0;
    var best_distance: usize = 0;
    var candidate = work.head[hashAt(bytes, at)];
    var tries: usize = chain_tries;
    while (candidate != 0 and tries > 0) : (tries -= 1) {
        const from: usize = candidate - 1;
        if (at - from > window) break;
        if (bytes[from + best] == bytes[at + best]) {
            var length: usize = 0;
            while (length < most and bytes[from + length] == bytes[at + length]) length += 1;
            if (length > best) {
                best = length;
                best_distance = at - from;
                if (length == most) break;
            }
        }
        const next = work.chain[from % window];
        // A chain entry older than the one it hangs on is from a place
        // the window has passed and the slot was taken again.
        if (next >= candidate) break;
        candidate = next;
    }
    return .{ .length = best, .distance = best_distance };
}

fn putSymbol(work: *Work, symbol: u16) void {
    const code = literal_codes[symbol];
    putBits(work, code.bits, code.length);
}

fn putLength(work: *Work, length: usize) void {
    var index: usize = length_base.len - 1;
    while (length_base[index] > length) index -= 1;
    putSymbol(work, @intCast(257 + index));
    putBits(work, @intCast(length - length_base[index]), length_extra[index]);
}

fn putDistance(work: *Work, distance: usize) void {
    var index: usize = distance_base.len - 1;
    while (distance_base[index] > distance) index -= 1;
    putBits(work, reverse(@intCast(index), 5), 5);
    putBits(work, @intCast(distance - distance_base[index]), distance_extra[index]);
}

fn putBits(work: *Work, value: u32, count: u7) void {
    if (count == 0) return;
    work.bits |= @as(u64, value) << work.bit_count;
    var filled: u7 = @as(u7, work.bit_count) + count;
    while (filled >= 8) : (filled -= 8) {
        putByte(work, @truncate(work.bits));
        work.bits >>= 8;
    }
    work.bit_count = @intCast(filled);
}

/// One byte of the stream into the chunk being filled, which goes out
/// when it is full.
fn putByte(work: *Work, byte: u8) void {
    work.chunk[4 + work.used] = byte;
    work.used += 1;
    if (work.used == chunk_data) flushChunk(work);
}

fn flushChunk(work: *Work) void {
    if (work.used == 0 or work.failed) return;
    if (!putChunkRaw(work, work.chunk[0 .. 4 + work.used])) work.failed = true;
    work.used = 0;
}

// --- chunks -----------------------------------------------------------------------

/// A chunk of `kind` holding `data`.
fn putChunk(work: *Work, kind: *const [4]u8, data: []const u8) bool {
    var small: [4 + 13]u8 = undefined;
    @memcpy(small[0..4], kind);
    @memcpy(small[4..][0..data.len], data);
    return putChunkRaw(work, small[0 .. 4 + data.len]);
}

/// A chunk whose type and data lie together in `typed`: its length in
/// front, its CRC behind.
fn putChunkRaw(work: *Work, typed: []const u8) bool {
    var length: [4]u8 = undefined;
    big32(&length, @intCast(typed.len - 4));
    var crc: [4]u8 = undefined;
    big32(&crc, decode.crc32(typed));
    const sink = work.sink;
    return sink.put(sink.context, &length) and sink.put(sink.context, typed) and sink.put(sink.context, &crc);
}

fn big32(into: *[4]u8, value: u32) void {
    into.* = .{ @truncate(value >> 24), @truncate(value >> 16), @truncate(value >> 8), @truncate(value) };
}

// --- tests --------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

const Collect = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn put(context: *anyopaque, bytes: []const u8) bool {
        const collect: *Collect = @ptrCast(@alignCast(context));
        collect.bytes.appendSlice(testing.allocator, bytes) catch return false;
        return true;
    }
};

/// A picture like a screen: flat areas, edges, text-like noise, a ramp.
fn screenLike(rows: []u8, width: u32, height: u32) void {
    const stride = rowBytes(width);
    var seed: u32 = 7;
    for (0..height) |y| {
        for (0..width) |x| {
            const at = y * stride + 1 + x * 3;
            var pixel = [3]u8{ 170, 170, 175 };
            if (y < 16) pixel = .{ 255, 255, 255 };
            if (x > 40 and x < 200 and y > 40 and y < 120) pixel = .{ 90, 130, 200 };
            if (y > 150) pixel = .{ @truncate(x), @truncate(y), @truncate(x + y) };
            seed = seed *% 1103515245 +% 12345;
            if (y > 60 and y < 70 and (seed >> 16) & 3 == 0) pixel = .{ 0, 0, 0 };
            @memcpy(rows[at..][0..3], &pixel);
        }
    }
}

test "a screen-like picture written and read back is the same picture, and smaller" {
    const width = 237;
    const height = 181;
    const stride = comptime rowBytes(width);
    const rows = try testing.allocator.alloc(u8, stride * height);
    defer testing.allocator.free(rows);
    screenLike(rows, width, height);
    const original = try testing.allocator.dupe(u8, rows);
    defer testing.allocator.free(original);

    const work = try testing.allocator.create(Work);
    defer testing.allocator.destroy(work);
    var collect: Collect = .{};
    defer collect.bytes.deinit(testing.allocator);
    try testing.expect(write(work, .{ .context = &collect, .put = Collect.put }, width, height, rows));
    const file = collect.bytes.items;

    const info = try decode.readInfo(file);
    try testing.expectEqual(@as(u32, width), info.width);
    try testing.expectEqual(@as(u32, height), info.height);
    // The IDAT chunks together, unpacked, then unfiltered row by row.
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(testing.allocator);
    var walk = try decode.Walk.start(file);
    while (try walk.next()) |chunk| {
        if (chunk.id == decode.ID_IDAT) try stream.appendSlice(testing.allocator, chunk.data);
    }
    try testing.expect(stream.items.len < original.len / 3);
    const raw = try testing.allocator.alloc(u8, original.len);
    defer testing.allocator.free(raw);
    const unpack = try testing.allocator.create(inflate.Work);
    defer testing.allocator.destroy(unpack);
    unpack.* = .{};
    try testing.expectEqual(original.len, try inflate.uncompress(unpack, stream.items, raw));
    const zero: [stride]u8 = @splat(0);
    for (0..height) |y| {
        const row = raw[y * stride ..][0..stride];
        const above: []const u8 = if (y > 0) raw[(y - 1) * stride ..][0..stride] else &zero;
        try decode.unfilter(row[0], row[1..], above[1..], 3);
        try testing.expectEqualSlices(u8, original[y * stride + 1 ..][0 .. stride - 1], row[1..]);
    }
}
