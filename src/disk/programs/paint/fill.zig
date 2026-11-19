// SPDX-License-Identifier: MIT
//! Paint's flood fill: the pixels of one colour joined to a place, side
//! by side or above and below, all made another.
//!
//! The fill goes a row's run at a time. A seed is a pixel still to be
//! filled from: its run is found to the left and the right and filled,
//! and the runs of the old colour touching it in the rows above and below
//! become seeds in turn, one each. The seeds wait on a stack whose memory
//! the program gives and makes more of when it is full; a fill that can
//! get no more stops where it is.

const picture_zig = @import("picture.zig");
const Picture = picture_zig.Picture;
const Pixel = picture_zig.Pixel;
const Area = picture_zig.Area;

pub const Seed = [2]i32;

/// The seeds waiting, in memory the program keeps.
pub const Seeds = struct {
    items: [*]Seed,
    capacity: usize,
    len: usize = 0,
    /// Called when the stack is full: false when there is no more room,
    /// otherwise `items` and `capacity` are the larger stack's, the seeds
    /// so far copied into it.
    more: *const fn (seeds: *Seeds) bool,
    /// The program's own, for `more`.
    context: ?*anyopaque = null,

    fn push(seeds: *Seeds, seed: Seed) bool {
        if (seeds.len == seeds.capacity and !seeds.more(seeds)) return false;
        seeds.items[seeds.len] = seed;
        seeds.len += 1;
        return true;
    }
};

/// The pixels of the colour at (`x`, `y`) joined to it made `colour`.
/// False when the stack could not grow and the fill stopped short.
pub fn flood(picture: *Picture, x: i32, y: i32, colour: Pixel, seeds: *Seeds, changed: *Area) bool {
    if (!picture.inside(x, y)) return true;
    const old = picture.get(@intCast(x), @intCast(y));
    if (old == colour) return true;
    seeds.len = 0;
    if (!seeds.push(.{ x, y })) return false;
    const last_x: i32 = @as(i32, @intCast(picture.width)) - 1;
    while (seeds.len > 0) {
        seeds.len -= 1;
        const seed = seeds.items[seeds.len];
        const row = picture.row(@intCast(seed[1]));
        if (row[@intCast(seed[0])] != old) continue;
        var left = seed[0];
        while (left > 0 and row[@intCast(left - 1)] == old) left -= 1;
        var right = seed[0];
        while (right < last_x and row[@intCast(right + 1)] == old) right += 1;
        @memset(row[@intCast(left)..@intCast(right + 1)], colour);
        changed.* = changed.add(.{ .min_x = left, .min_y = seed[1], .max_x = right + 1, .max_y = seed[1] + 1 });
        for ([_]i32{ seed[1] - 1, seed[1] + 1 }) |near| {
            if (near < 0 or near >= picture.height) continue;
            const other = picture.row(@intCast(near));
            var at = left;
            while (at <= right) : (at += 1) {
                // The first pixel of each run of the old colour.
                if (other[@intCast(at)] != old) continue;
                if (at == left or other[@intCast(at - 1)] != old) {
                    if (!seeds.push(.{ at, near })) return false;
                }
            }
        }
    }
    return true;
}
