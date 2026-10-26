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
//! **The stream** is compression.library's Deflate at its default level,
//! in a zlib wrapping, written straight into the IDAT chunk being filled;
//! a chunk goes out when its 32 KiB are full, and the last when the
//! stream has ended.
//!
//! Each chunk's CRC-32 is the PNG decoder's (sdk/libs/datatypes/png/).

const sdk = @import("sdk");
const compression = sdk.compression;
const CompressionBase = sdk.interface.compression.CompressionBase;
const decode = sdk.datatypes.png.decode;

/// Where the file's bytes go: false when they could not be taken.
pub const Sink = struct {
    context: *anyopaque,
    put: *const fn (context: *anyopaque, bytes: []const u8) bool,
};

const chunk_data = 32 * 1024;

/// The memory the writer works in: the caller's, 32 KiB and a little.
/// Deflate's own is the library's, for as long as the stream lasts.
pub const Work = struct {
    /// The chunk being filled: its type, then its data.
    chunk: [4 + chunk_data]u8,
    used: usize,
    sink: Sink,
};

/// How writing went.
pub const Result = enum {
    written,
    /// The sink did not take the bytes.
    sink_failed,
    /// Deflate's memory could not be had.
    no_memory,
};

/// The bytes the rows of a picture `width` pixels wide take: a filter byte
/// and three bytes a pixel each.
pub fn rowBytes(width: u32) usize {
    return 1 + @as(usize, width) * 3;
}

/// The picture in `rows` - `height` of `rowBytes(width)` bytes, the first
/// of each left for its filter - written as a PNG to `sink`, packed with
/// `cb`. The rows are filtered in place.
pub fn write(work: *Work, cb: *CompressionBase, sink: Sink, width: u32, height: u32, rows: []u8) Result {
    work.sink = sink;
    work.used = 0;

    if (!sink.put(sink.context, &.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' })) return .sink_failed;
    var header: [13]u8 = undefined;
    big32(header[0..4], width);
    big32(header[4..8], height);
    // 8 bits a channel, RGB, deflate, the five filters, not interlaced.
    @memcpy(header[8..13], &[_]u8{ 8, 2, 0, 0, 0 });
    if (!putChunk(work, "IHDR", &header)) return .sink_failed;

    const stride = rowBytes(width);
    var row = height;
    while (row > 0) {
        row -= 1;
        const this = rows[row * stride ..][0..stride];
        const above = if (row > 0) rows[(row - 1) * stride ..][0..stride] else null;
        filterRow(this, above);
    }

    work.chunk[0..4].* = "IDAT".*;
    var stream: compression.Stream = .{};
    if (cb.InitDeflate(&stream, compression.FORMAT_ZLIB, compression.LEVEL_DEFAULT) != compression.COMPRESS_OK) return .no_memory;
    defer cb.EndDeflate(&stream);
    const bytes = rows[0 .. stride * height];
    stream.next_in = bytes.ptr;
    stream.avail_in = @intCast(bytes.len);
    while (true) {
        stream.next_out = work.chunk[4 + work.used ..].ptr;
        stream.avail_out = @intCast(chunk_data - work.used);
        const room = stream.avail_out;
        const result = cb.Deflate(&stream, compression.FLUSH_FINISH);
        work.used += room - stream.avail_out;
        if (result == compression.COMPRESS_END) break;
        if (result != compression.COMPRESS_OK) return .no_memory;
        if (work.used == chunk_data and !flushChunk(work)) return .sink_failed;
    }
    if (!flushChunk(work)) return .sink_failed;
    return if (putChunk(work, "IEND", &.{})) .written else .sink_failed;
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

// --- chunks -----------------------------------------------------------------------

/// The chunk filled so far out, when it holds anything: false when the
/// sink did not take it.
fn flushChunk(work: *Work) bool {
    if (work.used == 0) return true;
    defer work.used = 0;
    return putChunkRaw(work, work.chunk[0 .. 4 + work.used]);
}

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
