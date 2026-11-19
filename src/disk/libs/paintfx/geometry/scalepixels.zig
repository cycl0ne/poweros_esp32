// SPDX-License-Identifier: MIT
//! ScalePixels: pixels made another size - the nearest pixel, or smooth
//! in two passes, across each row into a copy of the call's own, then
//! down each column into `into`.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const paintfx = sdk.paintfx;
const PaintFXBase = @import("../paintfx_base.zig").PaintFXBase;
const _pixels = @import("../pixels/_pixels.zig");
const Weighed = _pixels.Weighed;

/// Scales pixels to another size: hard, each new pixel the nearest old
/// one, or smooth.
///
/// SYNOPSIS:
/// ```zig
/// fn ScalePixels(base: *PaintFXBase, from: *const paintfx.Pixels, into: *const paintfx.Pixels, how: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `from`: the pixels to scale.
/// - `into`: where they go, at its own width and height; not over
///   `from`.
/// - `how`: `PFXSCALE_HARD` or `PFXSCALE_SMOOTH`.
///
/// RESULT:
/// 0, or `ERROR_NO_FREE_STORE` when a smooth scale had no memory for its
/// copy - `into` is as it was then.
///
/// BEHAVIOR:
/// Hard, each pixel of `into` is the pixel of `from` its centre falls
/// on: the picture's own colours, its pixels grown into blocks or some
/// of them left out. Smooth, each way on its own: where `into` is
/// smaller, a pixel is the average of the part of `from` it covers,
/// each old pixel counted by how much of it is covered; where it is
/// larger, a mix of the two old pixels nearest its centre. Colours are
/// weighted by their alpha in either.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not from an interrupt.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pixels stay the caller's. A smooth scale's copy, `into`'s width
/// by `from`'s height at four bytes a pixel, and two lines of weighted
/// colours are the call's and freed before it answers.
///
/// NOTES:
/// A smooth scale keeps its first pass a byte a channel, weighted, so a
/// colour whose alpha is low comes back a little coarser.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `TransformPixels`
///
/// EXAMPLES:
/// ```zig
/// const from = paintfx.Pixels{ .pixels = old, .width = 640, .height = 480, .pitch = 640 };
/// const into = paintfx.Pixels{ .pixels = new, .width = 320, .height = 240, .pitch = 320 };
/// if (fx.ScalePixels(&from, &into, paintfx.PFXSCALE_SMOOTH) != 0) {
///     // no memory
/// }
/// ```
pub fn ScalePixels(base: *PaintFXBase, from: *const paintfx.Pixels, into: *const paintfx.Pixels, how: u32) i32 {
    if (!_pixels.usable(from) or !_pixels.usable(into)) return 0;
    if (how != paintfx.PFXSCALE_SMOOTH) {
        hard(from, into);
        return 0;
    }
    const sys = base.sys_base;
    const longest: usize = @max(@max(from.width, from.height), @max(into.width, into.height));
    const lines_memory = sys.AllocVec(2 * longest * @sizeOf(Weighed), exec.MEMF_ANY) orelse return dos.ERROR_NO_FREE_STORE;
    defer sys.FreeVec(lines_memory);
    const copy_memory = sys.AllocVec(@as(usize, into.width) * from.height * 4, exec.MEMF_ANY) orelse return dos.ERROR_NO_FREE_STORE;
    defer sys.FreeVec(copy_memory);
    const lines: [*]Weighed = @ptrCast(@alignCast(lines_memory));
    const line = lines[0..longest];
    const other = lines[longest .. 2 * longest];
    const across = paintfx.Pixels{ .pixels = @ptrCast(@alignCast(copy_memory)), .width = into.width, .height = from.height, .pitch = into.width };

    var y: u32 = 0;
    while (y < from.height) : (y += 1) {
        for (line[0..from.width], _pixels.row(from, y)) |*place, pixel| place.* = _pixels.weighed(pixel);
        resample(line[0..from.width], other[0..into.width]);
        for (_pixels.row(&across, y), other[0..into.width]) |*pixel, colour| pixel.* = _pixels.packWeighed(colour);
    }
    var x: u32 = 0;
    while (x < into.width) : (x += 1) {
        var down: u32 = 0;
        while (down < from.height) : (down += 1) line[down] = _pixels.unpackWeighed(_pixels.row(&across, down)[x]);
        resample(line[0..from.height], other[0..into.height]);
        down = 0;
        while (down < into.height) : (down += 1) _pixels.row(into, down)[x] = _pixels.unweighed(other[down]);
    }
    return 0;
}

/// Each pixel of `into` the pixel of `from` under its centre.
fn hard(from: *const paintfx.Pixels, into: *const paintfx.Pixels) void {
    var y: u32 = 0;
    while (y < into.height) : (y += 1) {
        const source_y: u32 = @intCast((2 * @as(u64, y) + 1) * from.height / (2 * @as(u64, into.height)));
        const source = _pixels.row(from, source_y);
        for (_pixels.row(into, y), 0..) |*pixel, x| {
            pixel.* = source[@intCast((2 * @as(u64, x) + 1) * from.width / (2 * @as(u64, into.width)))];
        }
    }
}

/// `from` made `into`'s length: an average of what each new place covers
/// when it is shorter, a mix of the two nearest when it is longer.
fn resample(from: []const Weighed, into: []Weighed) void {
    const length_in: u64 = from.len;
    const length_out: u64 = into.len;
    if (length_in == length_out) {
        @memcpy(into, from);
        return;
    }
    if (length_in > length_out) {
        // On a scale where an old place is `length_out` long and a new
        // one `length_in`: each new place covers whole old ones and parts
        // of the two at its ends.
        for (into, 0..) |*place, index| {
            const start = index * length_in;
            const end = start + length_in;
            var sum = [4]u64{ 0, 0, 0, 0 };
            var old = start / length_out;
            while (old * length_out < end) : (old += 1) {
                const covered = @min((old + 1) * length_out, end) - @max(old * length_out, start);
                const colour = from[@intCast(old)];
                inline for (0..4) |channel| sum[channel] += covered * colour[channel];
            }
            inline for (0..4) |channel| place[channel] = @intCast((sum[channel] + length_in / 2) / length_in);
        }
        return;
    }
    const last: i64 = @intCast(length_in - 1);
    for (into, 0..) |*place, index| {
        // The new place's centre among the old ones', 16.16.
        const centre: i64 = @intCast(((2 * index + 1) * length_in << 16) / (2 * length_out));
        const at = centre - (1 << 15);
        const first = at >> 16;
        const part: u64 = @intCast(at & 0xFFFF);
        const left = from[@intCast(@max(0, @min(last, first)))];
        const right = from[@intCast(@max(0, @min(last, first + 1)))];
        inline for (0..4) |channel| place[channel] = @intCast((left[channel] * (0x10000 - part) + right[channel] * part + 0x8000) >> 16);
    }
}
