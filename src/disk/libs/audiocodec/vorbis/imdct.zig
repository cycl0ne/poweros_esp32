// SPDX-License-Identifier: MIT
//! The inverse MDCT a Vorbis block's spectrum is turned into sound with,
//! and the window its two ends are faded with.
//!
//! **The transform** of a block of n samples from its n/2 coefficients:
//!
//!   y[i] = sum over k of X[k] cos(2 pi / n (i + 1/2 + n/4)(k + 1/2))
//!
//! is a DCT-IV of size n/2 unfolded: its first quarter as it is, the rest
//! mirrored and negated. The DCT-IV is made with a complex FFT of n/4:
//! the coefficients paired - X[2k] with X[n/2-1-2k] - and turned by
//! e^(-i pi (4k+1) / 2n), transformed, turned again by e^(-2 pi i j / n);
//! the real parts are the even outputs, the imaginary parts negated the
//! odd ones, from the far end. The FFT is radix 2, in place, its input
//! in bit-reversed order.
//!
//! **The window's slope** over L samples is sin(pi/2 sin^2((i + 1/2) / L
//! pi/2)), rising; the falling slope is the same read backwards.
//!
//! The tables are made once for each of a stream's two block sizes, in
//! its pool.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const setup = @import("setup.zig");

pub const Transform = struct {
    n: u32,
    /// The turns before the FFT and after it, cos and sin of each, n/4 of
    /// them; the FFT's own, n/8; where each of the n/4 inputs goes.
    before: [*]f32,
    after: [*]f32,
    twiddle: [*]f32,
    reverse: [*]u16,
    /// The FFT's n/4 complex values.
    work: [*]f32,
    /// The rising slope of a window n/2 long.
    window: [*]f32,
};

/// The tables for blocks of `n` samples: false without memory.
pub fn init(sys: *ExecBase, pool: *anyopaque, n: u32, out: *Transform) bool {
    const quarter = n / 4;
    out.n = n;
    out.before = setup.allocate(sys, pool, f32, n / 2) orelse return false;
    out.after = setup.allocate(sys, pool, f32, n / 2) orelse return false;
    out.twiddle = setup.allocate(sys, pool, f32, n / 4) orelse return false;
    out.reverse = setup.allocate(sys, pool, u16, quarter) orelse return false;
    out.work = setup.allocate(sys, pool, f32, n / 2) orelse return false;
    out.window = setup.allocate(sys, pool, f32, n / 2) orelse return false;

    const pi: f64 = 3.14159265358979323846;
    const size: f64 = @floatFromInt(n);
    for (0..quarter) |k| {
        const turn = pi * @as(f64, @floatFromInt(4 * k + 1)) / (2.0 * size);
        out.before[2 * k] = @floatCast(@cos(turn));
        out.before[2 * k + 1] = @floatCast(@sin(turn));
        const back = 2.0 * pi * @as(f64, @floatFromInt(k)) / size;
        out.after[2 * k] = @floatCast(@cos(back));
        out.after[2 * k + 1] = @floatCast(@sin(back));
    }
    for (0..quarter / 2) |m| {
        const turn = 2.0 * pi * @as(f64, @floatFromInt(m)) / @as(f64, @floatFromInt(quarter));
        out.twiddle[2 * m] = @floatCast(@cos(turn));
        out.twiddle[2 * m + 1] = @floatCast(@sin(turn));
    }
    const levels = setup.ilog(quarter) - 1;
    for (0..quarter) |i| {
        const reversed = @bitReverse(@as(u32, @intCast(i))) >> @intCast(32 - levels);
        out.reverse[i] = @intCast(reversed);
    }
    const half = n / 2;
    const length: f64 = @floatFromInt(half);
    for (0..half) |i| {
        const inner = @sin((@as(f64, @floatFromInt(i)) + 0.5) / length * pi / 2.0);
        out.window[i] = @floatCast(@sin(pi / 2.0 * inner * inner));
    }
    return true;
}

/// `buffer[0..n/2]`, a block's coefficients, made its n samples in
/// `buffer[0..n]`.
pub fn inverse(t: *const Transform, buffer: [*]f32) void {
    const n = t.n;
    const half = n / 2;
    const quarter = n / 4;
    const work = t.work;

    // Paired, turned, and put in bit-reversed order.
    for (0..quarter) |k| {
        const re = buffer[2 * k];
        const im = buffer[half - 1 - 2 * k];
        const c = t.before[2 * k];
        const s = t.before[2 * k + 1];
        const to: usize = t.reverse[k];
        work[2 * to] = re * c + im * s;
        work[2 * to + 1] = im * c - re * s;
    }

    // The FFT, radix 2.
    var span: usize = 2;
    while (span <= quarter) : (span *= 2) {
        const step = quarter / span;
        const middle = span / 2;
        var start: usize = 0;
        while (start < quarter) : (start += span) {
            for (0..middle) |k| {
                const c = t.twiddle[2 * k * step];
                const s = t.twiddle[2 * k * step + 1];
                const a = 2 * (start + k);
                const b = 2 * (start + k + middle);
                const b_re = work[b] * c + work[b + 1] * s;
                const b_im = work[b + 1] * c - work[b] * s;
                work[b] = work[a] - b_re;
                work[b + 1] = work[a + 1] - b_im;
                work[a] += b_re;
                work[a + 1] += b_im;
            }
        }
    }

    // Turned again: the real parts the even outputs of the DCT-IV, the
    // imaginary parts the odd ones from the far end, negated.
    for (0..quarter) |j| {
        const c = t.after[2 * j];
        const s = t.after[2 * j + 1];
        const re = work[2 * j];
        const im = work[2 * j + 1];
        work[2 * j] = re * c + im * s;
        work[2 * j + 1] = im * c - re * s;
    }
    for (0..quarter / 2) |j| {
        const near = 2 * j + 1;
        const far = half - 1 - 2 * j;
        const held = work[near];
        work[near] = -work[far];
        work[far] = -held;
    }

    // Unfolded into the block.
    const three = 3 * quarter;
    for (0..quarter) |i| buffer[i] = work[i + quarter];
    for (quarter..three) |i| buffer[i] = -work[three - 1 - i];
    for (three..n) |i| buffer[i] = -work[i - three];
}
