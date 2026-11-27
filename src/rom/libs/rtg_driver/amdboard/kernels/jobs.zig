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

const AddressSpace = @import("std").builtin.AddressSpace;
const pixels = @import("pixels.zig");

/// BlendPixels: a picture laid over the rectangle, each pixel by its
/// coverage at `alpha`, 1 to 255; `picture` is its pixel that lands on
/// the rectangle's top left. `flags`: `rgba`, `whole`.
pub const BlendPixels = extern struct { dest: u64, picture: u64, dest_pitch: u32, picture_pitch: u32, width: u32, height: u32, alpha: u32, flags: u32 };

/// BlendRect: `pen` laid over the rectangle by its coverage.
pub const BlendRect = extern struct { dest: u64, dest_pitch: u32, width: u32, height: u32, pen: u32 };

/// ScalePixels: a part of a picture, `src_width` x `src_height` pixels
/// from `picture`, its top left, scaled to the rectangle's size and laid
/// over it by its coverage. `flags`: `rgba`, `shrinks`.
pub const ScalePixels = extern struct { dest: u64, picture: u64, dest_pitch: u32, picture_pitch: u32, width: u32, height: u32, src_width: u32, src_height: u32, flags: u32 };

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

/// A picture's pixel as a pen.
inline fn penAt(comptime space: AddressSpace, address: u64, flags: u32) u32 {
    const value = word(space, address).*;
    return if (flags & pixels.rgba != 0) pixels.fromRgba(value) else value;
}

/// `pen` laid over the `bgra32` pixel at `address` by its coverage; the
/// pixel is not touched where the pen covers none of it.
inline fn layAt(comptime space: AddressSpace, address: u64, pen: u32) void {
    const coverage = pen >> 24;
    if (coverage == 0) return;
    const to = word(space, address);
    to.* = if (coverage == 0xFF) pen else pixels.over(pen, to.*);
}

pub inline fn blendPixels(comptime space: AddressSpace, job: BlendPixels, column: u32, y: u32) void {
    if (y >= job.height) return;
    const line = job.dest + @as(u64, y) * job.dest_pitch;
    const x = rowPixel(line, 2, column);
    if (x >= job.width) return;
    const from = job.picture + @as(u64, y) * job.picture_pitch + @as(u64, x) * 4;
    const pen = pixels.strength(penAt(space, from, job.flags), job.alpha, job.flags & pixels.whole != 0);
    layAt(space, line + @as(u64, x) * 4, pen);
}

pub inline fn blendRect(comptime space: AddressSpace, job: BlendRect, column: u32, y: u32) void {
    if (y >= job.height) return;
    const line = job.dest + @as(u64, y) * job.dest_pitch;
    const x = rowPixel(line, 2, column);
    if (x >= job.width) return;
    layAt(space, line + @as(u64, x) * 4, job.pen);
}

pub inline fn scalePixels(comptime space: AddressSpace, job: ScalePixels, column: u32, y: u32) void {
    if (y >= job.height) return;
    const line = job.dest + @as(u64, y) * job.dest_pitch;
    const x = rowPixel(line, 2, column);
    if (x >= job.width) return;
    const pen = if (job.flags & pixels.shrinks != 0) meanAt(space, job, x, y) else mixedAt(space, job, x, y);
    layAt(space, line + @as(u64, x) * 4, pen);
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
