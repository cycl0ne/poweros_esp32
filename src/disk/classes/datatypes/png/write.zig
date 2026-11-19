// SPDX-License-Identifier: MIT
//! `DTM_WRITE` with `DTWM_RAW`: the picture written out as a PNG.
//!
//! What is written is the superclass's picture, read where it keeps it
//! (`PDTA_Pixels`, a pen a pixel, `PDTA_BytesPerRow` apart): 8 bits a
//! channel, RGB - or RGB with its coverage when the picture has any,
//! which is what the superclass decides drawing by too (its source mode
//! is RGBA or ARGB, or its header masks with alpha). Not interlaced, and
//! with no chunk but `IHDR`, `IDAT` and `IEND`.
//!
//! **A row at a time.** Each row is made from the pens and filtered with
//! whichever of the five filters makes the smallest sum of its bytes taken
//! as signed - the usual guess at what compresses best - against the row
//! above as it was, which is kept beside it. The filtered row goes into
//! compression.library's Deflate at its default level, in a zlib
//! wrapping, written straight into the `IDAT` chunk being filled; a chunk
//! goes out when its 32 KiB are full, and the last when the stream has
//! ended. So the memory it takes is three rows and a chunk, whatever the
//! picture's height, and Deflate's state.
//!
//! Each chunk's CRC-32 is the decoder's (`sdk.datatypes.png.decode`).
//! The encoder (`encode`) writes to a `Sink` and knows nothing of the
//! object or the file, so its host tests collect the file in memory.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const gadgets = sdk.gadgets;
const datatypes = sdk.datatypes;
const subclass = datatypes.subclass;
const dtc = datatypes.datatypesclass;
const pic = datatypes.pictureclass;
const decode = datatypes.png.decode;
const compression = sdk.compression;
const Class = classes.Class;
const Object = classes.Object;
const DosBase = sdk.interface.dos.DosBase;
const CompressionBase = sdk.interface.compression.CompressionBase;
const Base = gadgets.Base;

const chunk_data = 32 * 1024;

/// Where the file's bytes go: `put` takes them all or says false.
pub const Sink = struct {
    context: *anyopaque,
    put: *const fn (context: *anyopaque, bytes: []const u8) bool,
};

/// How a write ended.
pub const Result = enum { written, sink_failed, no_memory };

/// What an encoder works in, in one block: the chunk being filled - its
/// type, then its data - and where it goes.
pub const Work = struct {
    chunk: [4 + chunk_data]u8,
    used: usize,
    sink: Sink,
};

/// The bytes `encode` needs beside its `Work` for rows `width` pixels
/// wide: the row as it is, the one above, and the row filtered.
pub fn rowRoom(width: u32, alpha: bool) usize {
    return 3 * (@as(usize, width) * (if (alpha) @as(usize, 4) else 3) + 1);
}

/// `DTM_WRITE`: a PNG on the caller's open file for `DTWM_RAW`; anything
/// else is the superclass's (an IFF ILBM). 1 when it was written, 0 when
/// not - with `IoErr` saying why: dos's for the file, `ERROR_NO_FREE_STORE`
/// for memory, `DTERROR_NOT_ENOUGH_DATA` for a picture with no pixels.
pub fn write(base: *Base, cl: *Class, o: *Object, msg: *dtc.DtWrite) usize {
    const ib = base.intuition_base;
    if (msg.mode != dtc.DTWM_RAW) return ib.SendSuperMessage(cl, o, @ptrCast(msg));
    const sys = base.sys_base;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return 0;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    const file: *dos.FileHandle = @ptrCast(@alignCast(msg.file orelse {
        _ = dl.SetIoErr(dos.ERROR_REQUIRED_ARG_MISSING);
        return 0;
    }));

    const header: *const pic.BitMapHeader = @ptrFromInt(subclass.superAsk(ib, cl, o, pic.PDTA_BitMapHeader));
    const pens_at = subclass.superAsk(ib, cl, o, pic.PDTA_Pixels);
    const pitch = subclass.superAsk(ib, cl, o, pic.PDTA_BytesPerRow);
    const width: u32 = header.width;
    const height: u32 = header.height;
    if (pens_at == 0 or width == 0 or height == 0) {
        _ = dl.SetIoErr(datatypes.DTERROR_NOT_ENOUGH_DATA);
        return 0;
    }
    const mode = subclass.superAsk(ib, cl, o, pic.PDTA_SourceMode);
    const alpha = mode == pic.PBPAFMT_RGBA or mode == pic.PBPAFMT_ARGB or header.masking == pic.mskHasAlpha;

    const room = rowRoom(width, alpha);
    const work_memory = sys.AllocVec(@sizeOf(Work) + room, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = dl.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return 0;
    };
    defer sys.FreeVec(work_memory);
    const work: *Work = @ptrCast(@alignCast(work_memory));
    const rows = (@as([*]u8, @ptrCast(work_memory)) + @sizeOf(Work))[0..room];
    var output = Output{ .dl = dl, .file = file };
    const cb: *CompressionBase = @ptrCast(base.opened[1].?);
    const pens: [*]const u8 = @ptrFromInt(pens_at);
    switch (encode(work, cb, .{ .context = &output, .put = Output.put }, pens, pitch, width, height, alpha, rows)) {
        .written => return 1,
        // dos has said why.
        .sink_failed => return 0,
        .no_memory => {
            _ = dl.SetIoErr(dos.ERROR_NO_FREE_STORE);
            return 0;
        },
    }
}

/// The caller's file as a sink.
const Output = struct {
    dl: *DosBase,
    file: *dos.FileHandle,

    fn put(context: *anyopaque, bytes: []const u8) bool {
        const output: *Output = @ptrCast(@alignCast(context));
        return output.dl.Write(output.file, bytes.ptr, @intCast(bytes.len)) == @as(isize, @intCast(bytes.len));
    }
};

/// A picture of pens - `height` rows of `width`, `pitch` bytes apart - as
/// a PNG into `sink`, with or without its coverage. `rows` is
/// `rowRoom(width, alpha)` bytes.
pub fn encode(work: *Work, cb: *CompressionBase, sink: Sink, pens: [*]const u8, pitch: usize, width: u32, height: u32, alpha: bool, rows: []u8) Result {
    work.used = 0;
    work.sink = sink;
    const pixel: usize = if (alpha) 4 else 3;
    const row_bytes = @as(usize, width) * pixel;
    // The row as it is, the one above as it was (zeroes above the first,
    // as the format has it), and the row filtered, its filter byte first.
    const this = rows[0..row_bytes];
    const above = rows[row_bytes + 1 ..][0..row_bytes];
    const out = rows[2 * (row_bytes + 1) ..][0 .. row_bytes + 1];

    if (!put(work, &.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' })) return .sink_failed;
    var ihdr: [13]u8 = undefined;
    big32(ihdr[0..4], width);
    big32(ihdr[4..8], height);
    // 8 bits a channel, RGB or RGBA, deflate, the five filters, not
    // interlaced.
    @memcpy(ihdr[8..13], &[_]u8{ 8, if (alpha) 6 else 2, 0, 0, 0 });
    if (!putChunk(work, "IHDR", &ihdr)) return .sink_failed;

    var stream: compression.Stream = .{};
    if (cb.InitDeflate(&stream, compression.FORMAT_ZLIB, compression.LEVEL_DEFAULT) != compression.COMPRESS_OK) return .no_memory;
    defer cb.EndDeflate(&stream);
    work.chunk[0..4].* = "IDAT".*;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row: [*]const graphics.Pen = @ptrCast(@alignCast(pens + @as(usize, y) * pitch));
        colours(row, width, alpha, this);
        filterRow(this, if (y == 0) null else above, pixel, out);
        @memcpy(above, this);
        const flush = if (y + 1 == height) compression.FLUSH_FINISH else compression.FLUSH_NONE;
        const result = deflate(work, cb, &stream, out, flush);
        if (result != .written) return result;
    }
    if (!flushChunk(work)) return .sink_failed;
    if (!putChunk(work, "IEND", &.{})) return .sink_failed;
    return .written;
}

/// `bytes` through Deflate into the chunk being filled, each full chunk
/// going out as it fills; with `FLUSH_FINISH`, until the stream has ended.
fn deflate(work: *Work, cb: *CompressionBase, stream: *compression.Stream, bytes: []const u8, flush: u32) Result {
    stream.next_in = bytes.ptr;
    stream.avail_in = @intCast(bytes.len);
    while (true) {
        stream.next_out = work.chunk[4 + work.used ..].ptr;
        stream.avail_out = @intCast(chunk_data - work.used);
        const room = stream.avail_out;
        const left = stream.avail_in;
        const result = cb.Deflate(stream, flush);
        work.used += room - stream.avail_out;
        if (result == compression.COMPRESS_END) return .written;
        if (result != compression.COMPRESS_OK) return .no_memory;
        if (work.used == chunk_data) {
            if (!flushChunk(work)) return .sink_failed;
            continue;
        }
        // Everything taken and room left over: Deflate has done what it
        // will for now - unless the stream is to end, which it says.
        if (stream.avail_in == 0 and flush != compression.FLUSH_FINISH) return .written;
        // Room, input and nothing done is a stream that will not go on.
        if (stream.avail_in == left and stream.avail_out == room) return .no_memory;
    }
}

/// A row of pens as the file's bytes: red, green, blue, and the coverage
/// after them when the picture has it.
fn colours(row: [*]const graphics.Pen, width: u32, alpha: bool, into: []u8) void {
    var x: usize = 0;
    var at: usize = 0;
    while (x < width) : (x += 1) {
        const pen = row[x];
        into[at] = @truncate(pen >> 16);
        into[at + 1] = @truncate(pen >> 8);
        into[at + 2] = @truncate(pen);
        if (alpha) {
            into[at + 3] = @truncate(pen >> 24);
            at += 4;
        } else at += 3;
    }
}

// --- filters ----------------------------------------------------------------------

/// `row` filtered against `above` (null for the first) into `out`, its
/// filter byte first, by the filter whose bytes come to the least.
pub fn filterRow(row: []const u8, above: ?[]const u8, pixel: usize, out: []u8) void {
    var best: u8 = 0;
    var best_sum: u64 = ~@as(u64, 0);
    for (0..5) |kind| {
        var sum: u64 = 0;
        for (row, 0..) |byte, i| {
            const value = byte -% predict(@intCast(kind), row, above, pixel, i);
            sum += if (value < 128) value else 256 - @as(u32, value);
        }
        if (sum < best_sum) {
            best_sum = sum;
            best = @intCast(kind);
        }
    }
    out[0] = best;
    for (row, 0..) |byte, i| out[1 + i] = byte -% predict(best, row, above, pixel, i);
}

/// What filter `kind` predicts byte `i` of a row to be, from the byte a
/// pixel to the left, the byte above, and the one above that to the left.
fn predict(kind: u8, row: []const u8, above: ?[]const u8, pixel: usize, i: usize) u8 {
    const left: u8 = if (i >= pixel) row[i - pixel] else 0;
    const up: u8 = if (above) |prior| prior[i] else 0;
    const corner: u8 = if (above != null and i >= pixel) above.?[i - pixel] else 0;
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

/// Bytes to the sink: false when it did not take them all.
fn put(work: *Work, bytes: []const u8) bool {
    if (bytes.len == 0) return true;
    return work.sink.put(work.sink.context, bytes);
}

/// The chunk filled so far out, when it holds anything.
fn flushChunk(work: *Work) bool {
    if (work.used == 0) return true;
    defer work.used = 0;
    return putTyped(work, work.chunk[0 .. 4 + work.used]);
}

/// A small chunk of `kind` holding `data`.
fn putChunk(work: *Work, kind: *const [4]u8, data: []const u8) bool {
    var small: [4 + 13]u8 = undefined;
    @memcpy(small[0..4], kind);
    @memcpy(small[4..][0..data.len], data);
    return putTyped(work, small[0 .. 4 + data.len]);
}

/// A chunk whose type and data lie together in `typed`: its length in
/// front, its CRC behind.
fn putTyped(work: *Work, typed: []const u8) bool {
    var length: [4]u8 = undefined;
    big32(&length, @intCast(typed.len - 4));
    var crc: [4]u8 = undefined;
    big32(&crc, decode.crc32(typed));
    return put(work, &length) and put(work, typed) and put(work, &crc);
}

fn big32(into: *[4]u8, value: u32) void {
    into.* = .{ @truncate(value >> 24), @truncate(value >> 16), @truncate(value >> 8), @truncate(value) };
}
