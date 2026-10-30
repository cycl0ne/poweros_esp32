// SPDX-License-Identifier: MIT
//! AAC's filter bank: a frame's coefficients turned back into sound -
//! one inverse MDCT of 2048 samples, or eight of 256 - windowed, and its
//! first half added to the second half the frame before left.
//!
//! The transform is the one Vorbis uses (`vorbis/imdct.zig`): the same
//! sum, so the same code, its 2/N already in the coefficients.
//!
//! **The window** of each half is a sine window or a Kaiser-Bessel
//! derived one (alpha 4 for a long window, 6 for a short one): the
//! frame's shape bit says which for its right half, the frame before's
//! for its left. A frame that starts a run of short windows ends with a
//! short slope in the middle of its right half, flat before and silent
//! after it; one that stops a run begins the same way round; eight short
//! windows lie at 448 + 128 w, each overlapping the next by half.

const std = @import("std");
const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const imdct = @import("../vorbis/imdct.zig");
const setup = @import("../vorbis/setup.zig");
const ics = @import("ics.zig");

pub const Bank = struct {
    long: imdct.Transform,
    short: imdct.Transform,
    /// The rising half of each window, by its shape: 1024 samples long,
    /// 128 short.
    long_windows: [2][*]f32,
    short_windows: [2][*]f32,
    /// A transform's samples; the eight short windows added together.
    block: [*]f32,
    frame: [*]f32,
};

/// The transforms and the windows, made in `pool`: false without memory.
pub fn init(sys: *ExecBase, pool: *anyopaque, bank: *Bank) bool {
    if (!imdct.init(sys, pool, 2048, &bank.long)) return false;
    if (!imdct.init(sys, pool, 256, &bank.short)) return false;
    for (0..2) |shape| {
        bank.long_windows[shape] = setup.allocate(sys, pool, f32, 1024) orelse return false;
        bank.short_windows[shape] = setup.allocate(sys, pool, f32, 128) orelse return false;
    }
    bank.block = setup.allocate(sys, pool, f32, 2048) orelse return false;
    bank.frame = setup.allocate(sys, pool, f32, 2048) orelse return false;
    sine(bank.long_windows[0][0..1024]);
    sine(bank.short_windows[0][0..128]);
    kaiserBessel(bank.long_windows[1][0..1024], 4.0);
    kaiserBessel(bank.short_windows[1][0..128], 6.0);
    return true;
}

/// sin(pi / N (n + 1/2)) over the first half of a window N long.
fn sine(half: []f32) void {
    const size: f64 = @floatFromInt(2 * half.len);
    for (half, 0..) |*slot, n| {
        slot.* = @floatCast(@sin(std.math.pi / size * (@as(f64, @floatFromInt(n)) + 0.5)));
    }
}

/// The rising half of a Kaiser-Bessel derived window: the square root of
/// the running sum of a Kaiser kernel of N/2 + 1 points, over its whole.
fn kaiserBessel(half: []f32, alpha: f64) void {
    const n = half.len;
    var total: f64 = 0;
    for (0..n + 1) |p| total += kernel(p, n, alpha);
    var sum: f64 = 0;
    for (half, 0..) |*slot, p| {
        sum += kernel(p, n, alpha);
        slot.* = @floatCast(@sqrt(sum / total));
    }
}

fn kernel(p: usize, n: usize, alpha: f64) f64 {
    const x = 2.0 * @as(f64, @floatFromInt(p)) / @as(f64, @floatFromInt(n)) - 1.0;
    return besselI0(std.math.pi * alpha * @sqrt(@max(0.0, 1.0 - x * x)));
}

/// The modified Bessel function of order 0, by its series.
fn besselI0(x: f64) f64 {
    const quarter = x * x / 4.0;
    var term: f64 = 1.0;
    var sum: f64 = 1.0;
    var k: f64 = 1.0;
    while (term > sum * 1e-14) : (k += 1.0) {
        term *= quarter / (k * k);
        sum += term;
    }
    return sum;
}

/// A frame of one channel: its 1024 samples into `out`, its tail kept in
/// `overlap` for the next. `previous_shape` is the shape of the frame
/// before.
pub fn synthesize(bank: *const Bank, info: *const ics.Info, previous_shape: u8, coef: [*]const f32, overlap: [*]f32, out: [*]f32) void {
    const block = bank.block;
    const now = info.shape;
    if (info.sequence == ics.EIGHT_SHORT) {
        const frame = bank.frame;
        @memset(frame[0..2048], 0);
        for (0..8) |w| {
            @memcpy(block[0..128], coef[w * 128 ..][0..128]);
            imdct.inverse(&bank.short, block);
            const rising = bank.short_windows[if (w == 0) previous_shape else now];
            const falling = bank.short_windows[now];
            const at = frame + 448 + 128 * w;
            for (0..128) |n| at[n] += block[n] * rising[n];
            for (0..128) |n| at[128 + n] += block[128 + n] * falling[127 - n];
        }
        for (0..1024) |n| out[n] = overlap[n] + frame[n];
        @memcpy(overlap[0..1024], frame[1024..2048]);
        return;
    }

    @memcpy(block[0..1024], coef[0..1024]);
    imdct.inverse(&bank.long, block);
    if (info.sequence == ics.LONG_STOP) {
        const rising = bank.short_windows[previous_shape];
        for (0..448) |n| out[n] = overlap[n];
        for (448..576) |n| out[n] = overlap[n] + block[n] * rising[n - 448];
        for (576..1024) |n| out[n] = overlap[n] + block[n];
    } else {
        const rising = bank.long_windows[previous_shape];
        for (0..1024) |n| out[n] = overlap[n] + block[n] * rising[n];
    }
    const tail = block + 1024;
    if (info.sequence == ics.LONG_START) {
        const falling = bank.short_windows[now];
        for (0..448) |n| overlap[n] = tail[n];
        for (448..576) |n| overlap[n] = tail[n] * falling[575 - n];
        @memset(overlap[576..1024], 0);
    } else {
        const falling = bank.long_windows[now];
        for (0..1024) |n| overlap[n] = tail[n] * falling[1023 - n];
    }
}

test "the windows meet the Princen-Bradley condition" {
    var long: [2][1024]f32 = undefined;
    var short: [2][128]f32 = undefined;
    sine(&long[0]);
    kaiserBessel(&long[1], 4.0);
    sine(&short[0]);
    kaiserBessel(&short[1], 6.0);
    // w(n)^2 + w(N/2 - 1 - n)^2 = 1: the halves of two frames add up.
    for (0..2) |shape| {
        for (0..1024) |n| {
            const a = long[shape][n];
            const b = long[shape][1023 - n];
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), a * a + b * b, 1e-5);
        }
        for (0..128) |n| {
            const a = short[shape][n];
            const b = short[shape][127 - n];
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), a * a + b * b, 1e-5);
        }
    }
    try std.testing.expect(long[1][0] < long[0][0]);
}
