// SPDX-License-Identifier: MIT
//! A band's shape (RFC 6716 4.3.4): K pulses over its N coefficients,
//! the vector's index read as one uint below V(N,K) and unfolded
//! dimension by dimension (the CWRS enumeration), scaled to unit energy,
//! then spread by rotations so few pulses do not sound tonal.

const tables = @import("celt_tables.zig");
const Range = @import("range.zig").Range;

pub const spread_none = 0;
pub const spread_light = 1;
pub const spread_normal = 2;
pub const spread_aggressive = 3;

/// U(a, b) for a no larger than b, from the stored row a.
inline fn row(a: u32, b: u32) u32 {
    return tables.pvq_u[tables.pvq_rows[a] + b];
}

/// The pulse vector of index `index` among those of `n` dimensions and
/// `k` pulses into `y`; the sum of its squares.
fn unfold(n_in: u32, k_in: u32, index: u32, y: []i32) f32 {
    var n = n_in;
    var k = k_in;
    var i = index;
    var yy: i32 = 0;
    var at: usize = 0;
    while (n > 2) : (n -= 1) {
        var val: i32 = undefined;
        if (k >= n) {
            // Many pulses: how many in this dimension, and their sign.
            var p = row(n, k + 1);
            const s: i32 = if (i >= p) -1 else 0;
            if (s != 0) i -= p;
            const k0 = k;
            const q = row(n, n);
            if (q > i) {
                k = n;
                while (true) {
                    k -= 1;
                    p = row(k, n);
                    if (p <= i) break;
                }
            } else {
                p = row(n, k);
                while (p > i) {
                    k -= 1;
                    p = row(n, k);
                }
            }
            i -= p;
            val = (@as(i32, @intCast(k0 - k)) + s) ^ s;
        } else {
            // Many dimensions: whether this one has any pulse at all.
            var p = row(k, n);
            const q = row(k + 1, n);
            if (p <= i and i < q) {
                i -= p;
                val = 0;
            } else {
                const s: i32 = if (i >= q) -1 else 0;
                if (s != 0) i -= q;
                const k0 = k;
                while (true) {
                    k -= 1;
                    p = row(k, n);
                    if (p <= i) break;
                }
                i -= p;
                val = (@as(i32, @intCast(k0 - k)) + s) ^ s;
            }
        }
        y[at] = val;
        at += 1;
        yy += val * val;
    }
    // Two dimensions left.
    const p = 2 * k + 1;
    const s: i32 = if (i >= p) -1 else 0;
    if (s != 0) i -= p;
    const k0 = k;
    k = (i + 1) >> 1;
    if (k != 0) i -= 2 * k - 1;
    var val = (@as(i32, @intCast(k0 - k)) + s) ^ s;
    y[at] = val;
    yy += val * val;
    // And the last.
    const s1: i32 = -@as(i32, @intCast(i));
    val = (@as(i32, @intCast(k)) + s1) ^ s1;
    y[at + 1] = val;
    yy += val * val;
    return @floatFromInt(yy);
}

/// A band of `n` coefficients with `k` pulses decoded into `x`, its
/// energy `gain` squared, spread; which of its `b` blocks have a pulse.
pub fn unquant(x: []f32, n: u32, k: u32, spread: u32, b: u32, dec: *Range, gain: f32) u32 {
    var iy: [176]i32 = undefined;
    const ryy = unfold(n, k, dec.uint(tables.pvqV(n, k)), iy[0..n]);
    const g = gain / @sqrt(ryy);
    for (0..n) |i| x[i] = g * @as(f32, @floatFromInt(iy[i]));
    rotate(x, n, -1, b, k, spread);
    return collapseMask(iy[0..n], b);
}

/// Which of `b` blocks of the vector have a pulse: a bit each.
fn collapseMask(iy: []const i32, b: u32) u32 {
    if (b <= 1) return 1;
    const n0 = iy.len / b;
    var mask: u32 = 0;
    for (0..b) |i| {
        var any: i32 = 0;
        for (0..n0) |j| any |= iy[i * n0 + j];
        if (any != 0) mask |= @as(u32, 1) << @intCast(i);
    }
    return mask;
}

/// The vector scaled to the energy `gain` squared.
pub fn renormalise(x: []f32, gain: f32) void {
    var e: f32 = 1e-15;
    for (x) |v| e += v * v;
    const g = gain / @sqrt(e);
    for (x) |*v| v.* *= g;
}

fn rotateOnce(x: []f32, stride: usize, c: f32, s: f32) void {
    const len = x.len;
    const ms = -s;
    var i: usize = 0;
    while (i + stride < len) : (i += 1) {
        const x1 = x[i];
        const x2 = x[i + stride];
        x[i + stride] = c * x2 + s * x1;
        x[i] = c * x1 + ms * x2;
    }
    if (len < 2 * stride + 1) return;
    var j: isize = @as(isize, @intCast(len)) - 2 * @as(isize, @intCast(stride)) - 1;
    while (j >= 0) : (j -= 1) {
        const at: usize = @intCast(j);
        const x1 = x[at];
        const x2 = x[at + stride];
        x[at + stride] = c * x2 + s * x1;
        x[at] = c * x1 + ms * x2;
    }
}

/// The spreading rotation, `dir` -1 undoing what the encoder did, over
/// each of `stride` blocks.
pub fn rotate(x: []f32, len_all: u32, dir: i32, stride: u32, k: u32, spread: u32) void {
    const factors = [3]u32{ 15, 10, 5 };
    if (2 * k >= len_all or spread == spread_none) return;
    const factor = factors[spread - 1];
    const gain = @as(f32, @floatFromInt(len_all)) / @as(f32, @floatFromInt(len_all + factor * k));
    const theta = 0.5 * (gain * gain);
    const half_pi: f32 = 0.5 * 3.141592653;
    const c: f32 = @cos(half_pi * theta);
    const s: f32 = @cos(half_pi * (1.0 - theta));
    var stride2: u32 = 0;
    if (len_all >= 8 * stride) {
        stride2 = 1;
        while ((stride2 * stride2 + stride2) * stride + (stride >> 2) < len_all) stride2 += 1;
    }
    const len = len_all / stride;
    for (0..stride) |i| {
        const block = x[i * len ..][0..len];
        if (dir < 0) {
            if (stride2 != 0) rotateOnce(block, stride2, s, c);
            rotateOnce(block, 1, c, s);
        } else {
            rotateOnce(block, 1, c, -s);
            if (stride2 != 0) rotateOnce(block, stride2, s, -c);
        }
    }
}
