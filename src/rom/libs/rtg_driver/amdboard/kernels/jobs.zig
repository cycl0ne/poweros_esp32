// SPDX-License-Identifier: MPL-2.0
//! The board's kernels' jobs: what each kernel is handed - one
//! structure, its one argument, which the board fills in
//! (`../kernels.zig`) - and what it makes of the pixel a thread is
//! given. The kernels (`engine.zig`) run them on the compute engine over
//! the device's addresses; the host tests (`tests.zig`) run them on the
//! host over its own, pixel after pixel, and hold each to
//! graphics.library's.
//!
//! A job's rectangle starts at `dest`, the address of its first pixel,
//! `dest_pitch` bytes from one of its rows to the next; what is read for
//! it starts at the second address. Pixels are of four bytes on four
//! bytes, a shape's or a tile's of two bytes or of four. A pixel is read
//! only by the thread that writes it.
//!
//! A thread is handed its row and its column among its row's groups. The
//! groups lie on whole spans of 64 pixels of the buffer's memory, the
//! first of them from the span the row's first pixel lies in, and a
//! thread's pixel is its column less the pixels of that span before the
//! row's first (`rowPixel`): so two groups of a row never write parts of
//! one cache line - laid from the row's first pixel instead, jobs whose
//! rows start part way into a span took the kernels up to two thirds
//! longer. A row takes as many groups as the spans its pixels can reach
//! into.
//!
//! A job that lays what it lands on - a picture, a colour, a scale laid -
//! would lay it twice where it ran twice, so its threads go through
//! `layOnce`: the job names its marks, a byte for each wave of 32 threads
//! of its groups (`wavesAcross` of them for each row), and its
//! generation, 1 to 255, which none of them holds as it is sent. A wave
//! reads its mark as it starts; where it holds the job's generation, the
//! wave laid its pixels in a run of the job before - one the queue's
//! reset gave up, or wrote again whole - and each of its threads writes
//! its pixel back as it reads it, which leaves it as that run laid it.
//! Its threads write the generation into the mark once the wave's pixels
//! are written, the mark's store issued after the pixels': a mark that
//! holds the generation is a wave's pixels laid. The queue's reset lets
//! the waves on the engine finish before it gives a job up
//! (ResetGPUCompute), 100 ms at most, so only a wave still running then -
//! a kernel's that spins, not one of these, of some microseconds - is
//! ended part way; one ended between the two stores would lay its pixels
//! again. A stored scale, a
//! job of the same kernel, sets its marks and stores its pixels whatever
//! they hold; a shape and a tile write the same pixels however often they
//! run, and take no marks.

const AddressSpace = @import("std").builtin.AddressSpace;
const pixels = @import("pixels.zig");

/// The threads of a group, along a row, and of a wave, as the kernels are
/// built for the engine: a group is two waves.
pub const group: u32 = 64;
pub const wave: u32 = 32;

/// The waves along a row of a job `width` pixels wide - a job's marks
/// have that many bytes for each of its rows: two for each of the row's
/// groups, as many as the spans of 64 pixels the row can reach into.
pub inline fn wavesAcross(width: u32) u32 {
    return (width + 2 * group - 2) / group * (group / wave);
}

/// BlendPixels: a picture laid over the rectangle, each pixel by its
/// coverage at `alpha`, 1 to 255; `picture` is its pixel that lands on
/// the rectangle's top left, `marks` and `generation` the job's marks.
/// `flags`: `rgba`, `whole`.
pub const BlendPixels = extern struct { dest: u64, picture: u64, marks: u64, dest_pitch: u32, picture_pitch: u32, width: u32, height: u32, alpha: u32, flags: u32, generation: u32 };

/// BlendRect: `pen` laid over the rectangle by its coverage; `marks` and
/// `generation` the job's marks.
pub const BlendRect = extern struct { dest: u64, marks: u64, dest_pitch: u32, width: u32, height: u32, pen: u32, generation: u32 };

/// ScalePixels: a part of a picture, `src_width` x `src_height` pixels
/// from `picture`, its top left, scaled to the rectangle's size and laid
/// over it by its coverage, or stored; `marks` and `generation` the job's
/// marks. `flags`: `rgba`, `shrinks`, `store`.
pub const ScalePixels = extern struct { dest: u64, picture: u64, marks: u64, dest_pitch: u32, picture_pitch: u32, width: u32, height: u32, src_width: u32, src_height: u32, flags: u32, generation: u32 };

/// BlitTemplate: a shape in two colours, its bit `first_bit` of the row
/// at `bits` landing on the rectangle's top left, a row of bits for each
/// row. `flags`: `transparent`, `invert`, `halves`.
pub const BlitTemplate = extern struct { dest: u64, bits: u64, dest_pitch: u32, bits_pitch: u32, width: u32, height: u32, first_bit: u32, fg: u32, bg: u32, flags: u32 };

/// BlitPattern: a tile `tile_width` x `tile_height` bits repeated over the
/// rectangle, its bit (`first_column`, `first_row`) on the top left.
/// `flags`: `transparent`, `invert`, `halves`.
pub const BlitPattern = extern struct { dest: u64, tile: u64, dest_pitch: u32, tile_pitch: u32, width: u32, height: u32, first_column: u32, first_row: u32, tile_width: u32, tile_height: u32, fg: u32, bg: u32, flags: u32 };

/// The pixel of a row starting at `line`, of `1 << shift` bytes each,
/// that the thread in `column` of the row's groups takes: one past the
/// row's last for a thread before its first, so that the bound on the
/// row's width turns both ends away.
inline fn rowPixel(line: u64, shift: u6, column: u32) u32 {
    return column -% @as(u32, @truncate((line >> shift) & 63));
}

/// The shift of a shape's or a tile's pixels, two bytes or four.
inline fn shiftOf(flags: u32) u6 {
    return if (flags & pixels.halves != 0) 1 else 2;
}

inline fn word(comptime space: AddressSpace, address: u64) *addrspace(space) u32 {
    return @ptrFromInt(address);
}

inline fn half(comptime space: AddressSpace, address: u64) *addrspace(space) u16 {
    return @ptrFromInt(address);
}

inline fn byte(comptime space: AddressSpace, address: u64) *addrspace(space) const u8 {
    return @ptrFromInt(address);
}

/// Where the mark of the wave of the thread in `column` of row `y`'s
/// groups of `job` is: the waves' marks one after another, along the
/// job's rows.
pub inline fn markAt(job: anytype, column: u32, y: u32) u64 {
    return job.marks + y * wavesAcross(job.width) + column / wave;
}

/// The mark of the wave of the thread in `column` of row `y`'s groups of
/// `job`.
pub inline fn markOf(comptime space: AddressSpace, job: anytype, column: u32, y: u32) *addrspace(space) u8 {
    return @ptrFromInt(markAt(job, column, y));
}

/// Whether a wave's mark `own` says it laid its pixels in a run of `job`
/// before: it holds the job's generation.
pub inline fn laidBefore(own: anytype, job: anytype) bool {
    return own.* == @as(u8, @truncate(job.generation));
}

/// A wave's mark `own` set, the job's generation written into it - by
/// each of its threads alike.
pub inline fn markLaid(own: anytype, job: anytype) void {
    own.* = @truncate(job.generation);
}

/// The thread in `column` of row `y`'s groups of a job that lays what it
/// lands on: `work` - blendPixels, blendRect or scalePixels - told
/// whether its wave laid its pixels before, then the wave's mark set, the
/// store after the pixel's. The wave's threads run in step, so each reads
/// the mark before any writes it. A thread of a row past the job's
/// touches neither.
pub inline fn layOnce(comptime space: AddressSpace, comptime work: anytype, job: anytype, column: u32, y: u32) void {
    if (y >= job.height) return;
    const own = markOf(space, job, column, y);
    work(space, job, column, y, laidBefore(own, job));
    markLaid(own, job);
}

/// A picture's pixel as a pen.
inline fn penAt(comptime space: AddressSpace, address: u64, flags: u32) u32 {
    const value = word(space, address).*;
    return if (flags & pixels.rgba != 0) pixels.fromRgba(value) else value;
}

/// `pen` laid over the `bgra32` pixel at `address` by its coverage; the
/// pixel is not touched where the pen covers none of it. Where `laid` -
/// the pixel laid in a run of the job before - one the pen covers in
/// part is written back as it is read: read either way, so that the
/// read goes out beside the mark's rather than after it. One it covers
/// fully is the pen either way.
inline fn layAt(comptime space: AddressSpace, address: u64, pen: u32, laid: bool) void {
    const coverage = pen >> 24;
    if (coverage == 0) return;
    const to = word(space, address);
    if (coverage == 0xFF) {
        to.* = pen;
        return;
    }
    const under = to.*;
    to.* = if (laid) under else pixels.over(pen, under);
}

pub inline fn blendPixels(comptime space: AddressSpace, job: BlendPixels, column: u32, y: u32, laid: bool) void {
    if (y >= job.height) return;
    const line = job.dest + @as(u64, y) * job.dest_pitch;
    const x = rowPixel(line, 2, column);
    if (x >= job.width) return;
    const from = job.picture + @as(u64, y) * job.picture_pitch + @as(u64, x) * 4;
    const pen = pixels.strength(penAt(space, from, job.flags), job.alpha, job.flags & pixels.whole != 0);
    layAt(space, line + @as(u64, x) * 4, pen, laid);
}

pub inline fn blendRect(comptime space: AddressSpace, job: BlendRect, column: u32, y: u32, laid: bool) void {
    if (y >= job.height) return;
    const line = job.dest + @as(u64, y) * job.dest_pitch;
    const x = rowPixel(line, 2, column);
    if (x >= job.width) return;
    layAt(space, line + @as(u64, x) * 4, job.pen, laid);
}

pub inline fn scalePixels(comptime space: AddressSpace, job: ScalePixels, column: u32, y: u32, laid: bool) void {
    if (y >= job.height) return;
    const line = job.dest + @as(u64, y) * job.dest_pitch;
    const x = rowPixel(line, 2, column);
    if (x >= job.width) return;
    const pen = if (job.flags & pixels.shrinks != 0) meanAt(space, job, x, y) else mixedAt(space, job, x, y);
    if (job.flags & pixels.store != 0) {
        word(space, line + @as(u64, x) * 4).* = pen;
    } else {
        layAt(space, line + @as(u64, x) * 4, pen, laid);
    }
}

/// The four pixels round where pixel (x, y)'s middle falls, mixed.
inline fn mixedAt(comptime space: AddressSpace, job: ScalePixels, x: u32, y: u32) u32 {
    const across = pixels.between(pixels.sourceOf(x, job.width, job.src_width), job.src_width);
    const down = pixels.between(pixels.sourceOf(y, job.height, job.src_height), job.src_height);
    const top = job.picture + @as(u64, down.first) * job.picture_pitch;
    const bottom = job.picture + @as(u64, down.second) * job.picture_pitch;
    const wx = across.weight;
    const wy = down.weight;
    return pixels.sample(.{
        penAt(space, top + @as(u64, across.first) * 4, job.flags),
        penAt(space, top + @as(u64, across.second) * 4, job.flags),
        penAt(space, bottom + @as(u64, across.first) * 4, job.flags),
        penAt(space, bottom + @as(u64, across.second) * 4, job.flags),
    }, .{ (256 - wx) * (256 - wy), wx * (256 - wy), (256 - wx) * wy, wx * wy });
}

/// The mean of the pixels pixel (x, y) covers.
inline fn meanAt(comptime space: AddressSpace, job: ScalePixels, x: u32, y: u32) u32 {
    const across = pixels.spanOf(x, job.width, job.src_width);
    const down = pixels.spanOf(y, job.height, job.src_height);
    const first_x = across.first();
    const last_x = across.last(job.src_width);
    const last_y = down.last(job.src_height);
    var mean: pixels.Mean = .{};
    var sy = down.first();
    while (sy <= last_y) : (sy += 1) {
        const weight_y = down.share(sy);
        if (weight_y == 0) continue;
        const line = job.picture + @as(u64, @intCast(sy)) * job.picture_pitch;
        var line_mean: pixels.Mean = .{};
        var sx = first_x;
        while (sx <= last_x) : (sx += 1) line_mean.take(penAt(space, line + @as(u64, @intCast(sx)) * 4, job.flags), across.share(sx));
        mean.add(line_mean, weight_y);
    }
    return mean.result();
}

pub inline fn blitTemplate(comptime space: AddressSpace, job: BlitTemplate, column: u32, y: u32) void {
    if (y >= job.height) return;
    const line = job.dest + @as(u64, y) * job.dest_pitch;
    const x = rowPixel(line, shiftOf(job.flags), column);
    if (x >= job.width) return;
    const bit = job.first_bit + x;
    const ink = pixels.inked(pixels.bitOf(byte(space, job.bits + @as(u64, y) * job.bits_pitch + (bit >> 3)).*, bit), job.flags);
    if (!ink and job.flags & pixels.transparent != 0) return;
    put(space, line, x, if (ink) job.fg else job.bg, job.flags);
}

pub inline fn blitPattern(comptime space: AddressSpace, job: BlitPattern, column: u32, y: u32) void {
    if (y >= job.height) return;
    const line = job.dest + @as(u64, y) * job.dest_pitch;
    const x = rowPixel(line, shiftOf(job.flags), column);
    if (x >= job.width) return;
    const bit = (job.first_column + x) % job.tile_width;
    const tile_row = (job.first_row + y) % job.tile_height;
    const ink = pixels.inked(pixels.bitOf(byte(space, job.tile + @as(u64, tile_row) * job.tile_pitch + (bit >> 3)).*, bit), job.flags);
    if (!ink and job.flags & pixels.transparent != 0) return;
    put(space, line, x, if (ink) job.fg else job.bg, job.flags);
}

/// Pixel `x` of a row set to `colour`, of two bytes or of four.
inline fn put(comptime space: AddressSpace, line: u64, x: u32, colour: u32, flags: u32) void {
    if (flags & pixels.halves != 0) {
        half(space, line + @as(u64, x) * 2).* = @truncate(colour);
    } else {
        word(space, line + @as(u64, x) * 4).* = colour;
    }
}
