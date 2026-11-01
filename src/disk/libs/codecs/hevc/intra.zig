// SPDX-License-Identifier: MIT
//! Intra prediction's samples (8.4.4.2): the neighbours of a block made
//! whole where they are missing, smoothed, and the block predicted from
//! them - planar, DC or one of the 33 angles.
//!
//! The 4N + 1 neighbours of an N x N block are kept in one line, from the
//! bottom of the left column up, the corner, then the top row rightwards,
//! the order the substitution goes in (8.4.4.2.2): line[ 2N - 1 - y ] is
//! p[ -1 ][ y ], line[ 2N ] is p[ -1 ][ -1 ] and line[ 2N + 1 + x ] is
//! p[ x ][ -1 ].

const tables = @import("tables.zig");

/// The neighbours of the largest block.
pub const Line = [4 * 32 + 1]i32;

/// What marks a neighbour that is not there.
pub const missing: i32 = -1;

/// The missing neighbours of a block of 1 << `log2` filled from those
/// next to them (8.4.4.2.2).
pub fn substitute(line: *Line, log2: u3, depth: u5) void {
    const len = (@as(usize, 4) << log2) + 1;
    var first: ?usize = null;
    for (line[0..len], 0..) |v, i| {
        if (v != missing) {
            first = i;
            break;
        }
    }
    const f = first orelse {
        @memset(line[0..len], @as(i32, 1) << (depth - 1));
        return;
    };
    line[0] = line[f];
    for (1..len) |i| {
        if (line[i] == missing) line[i] = line[i - 1];
    }
}

/// The neighbours smoothed for `mode` (8.4.4.2.3): `strong` allows the
/// bilinear filter of a 32x32 luma block.
pub fn smooth(line: *Line, log2: u3, mode: u8, strong: bool, depth: u5) void {
    if (mode == 1 or log2 == 2) return;
    const m: i32 = mode;
    const dist = @min(@abs(m - 26), @abs(m - 10));
    const thres: u32 = switch (log2) {
        3 => 7,
        4 => 1,
        else => 0,
    };
    if (dist <= thres) return;
    const n2 = @as(usize, 2) << log2;
    const len = 2 * n2 + 1;
    const corner = line[n2];
    const bottom = line[0];
    const right = line[len - 1];
    if (strong and log2 == 5) {
        const lim = @as(i32, 1) << (depth - 5);
        const mid_l = line[n2 - 32];
        const mid_t = line[n2 + 32];
        if (@abs(corner + right - 2 * mid_t) < lim and @abs(corner + bottom - 2 * mid_l) < lim) {
            // p[ -1 ][ y ] for y 0..62, then p[ x ][ -1 ].
            for (0..63) |y| {
                const yi: i32 = @intCast(y);
                line[n2 - 1 - y] = ((63 - yi) * corner + (yi + 1) * bottom + 32) >> 6;
                line[n2 + 1 + y] = ((63 - yi) * corner + (yi + 1) * right + 32) >> 6;
            }
            return;
        }
    }
    var prev = line[0];
    for (1..len - 1) |i| {
        const cur = line[i];
        line[i] = (prev + 2 * cur + line[i + 1] + 2) >> 2;
        prev = cur;
    }
}

/// An N x N block (N = 1 << `log2`) predicted by `mode` from `line` into
/// `dst`: `edges` for the luma filters along the block's edges (8-48 to
/// 8-50, 8-60, 8-68) - `boundary` keeps those of the angles off.
pub fn predict(comptime T: type, line: *const Line, log2: u3, mode: u8, edges: bool, boundary: bool, depth: u5, dst: [*]T, stride: usize) void {
    const n: usize = @as(usize, 1) << log2;
    const n2 = 2 * n;
    const left = line[0..n2];
    const corner = line[n2];
    const top = line[n2 + 1 ..];
    const max: i32 = (@as(i32, 1) << depth) - 1;
    switch (mode) {
        0 => {
            const sh: u5 = @as(u5, log2) + 1;
            const tr = top[n];
            const bl = left[n2 - 1 - n];
            for (0..n) |y| {
                const l = left[n2 - 1 - y];
                const row = dst + y * stride;
                const yi: i32 = @intCast(y);
                for (0..n) |x| {
                    const xi: i32 = @intCast(x);
                    const ni: i32 = @intCast(n);
                    const v = (ni - 1 - xi) * l + (xi + 1) * tr + (ni - 1 - yi) * top[x] + (yi + 1) * bl + ni;
                    row[x] = @intCast(v >> sh);
                }
            }
        },
        1 => {
            var sum: i32 = @intCast(n);
            for (0..n) |i| sum += top[i] + left[n2 - 1 - i];
            const dc = sum >> (@as(u5, log2) + 1);
            for (0..n) |y| @memset((dst + y * stride)[0..n], @intCast(dc));
            if (edges and log2 < 5) {
                dst[0] = @intCast((left[n2 - 1] + 2 * dc + top[0] + 2) >> 2);
                for (1..n) |x| dst[x] = @intCast((top[x] + 3 * dc + 2) >> 2);
                for (1..n) |y| dst[y * stride] = @intCast((left[n2 - 1 - y] + 3 * dc + 2) >> 2);
            }
        },
        else => {
            const angle: i32 = tables.intra_angle[mode];
            // ref[ x ] at refs[ 32 + x ], x from -N to 2N.
            var refs: [3 * 32 + 1]i32 = undefined;
            const r = refs[32..];
            const vertical = mode >= 18;
            // The main side, and the other one it extends into.
            r[0] = corner;
            for (1..n2 + 1) |i| r[i] = if (vertical) top[i - 1] else left[n2 - i];
            const ni: i32 = @intCast(n);
            const last = (ni * angle) >> 5;
            if (angle < 0 and last < -1) {
                const inv: i32 = tables.inv_angle[mode - 11];
                var x: i32 = -1;
                while (x >= last) : (x -= 1) {
                    const k = -1 + ((x * inv + 128) >> 8);
                    // p[ -1 ][ k ] for vertical modes, p[ k ][ -1 ] else.
                    const v = if (k < 0) corner else if (vertical) left[n2 - 1 - @as(usize, @intCast(k))] else top[@intCast(k)];
                    refs[@intCast(32 + x)] = v;
                }
            }
            for (0..n) |j| {
                const pos: i32 = (@as(i32, @intCast(j)) + 1) * angle;
                const idx = pos >> 5;
                const fact = pos & 31;
                for (0..n) |i| {
                    const base: usize = @intCast(32 + @as(i32, @intCast(i)) + idx + 1);
                    const v = if (fact != 0) ((32 - fact) * refs[base] + fact * refs[base + 1] + 16) >> 5 else refs[base];
                    // j runs over rows for vertical modes, over columns else.
                    if (vertical) dst[j * stride + i] = @intCast(v) else dst[i * stride + j] = @intCast(v);
                }
            }
            if (edges and !boundary and log2 < 5) {
                if (mode == 26) {
                    for (0..n) |y| dst[y * stride] = @intCast(clip(top[0] + ((left[n2 - 1 - y] - corner) >> 1), max));
                } else if (mode == 10) {
                    for (0..n) |x| dst[x] = @intCast(clip(left[n2 - 1] + ((top[x] - corner) >> 1), max));
                }
            }
        },
    }
}

inline fn clip(v: i32, max: i32) i32 {
    return if (v < 0) 0 else if (v > max) max else v;
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

/// p[ x ][ y ] of the standard, from a line.
fn p(line: *const Line, n: usize, x: i32, y: i32) i32 {
    if (x == -1) return line[@intCast(@as(i32, @intCast(2 * n)) - 1 - y)];
    return line[2 * n + 1 + @as(usize, @intCast(x))];
}

/// The angular prediction as the standard writes it (8.4.4.2.6).
fn angularNaive(line: *const Line, n: usize, mode: u8, x: usize, y: usize) i32 {
    const angle: i32 = tables.intra_angle[mode];
    const ni: i32 = @intCast(n);
    var ref: [200]i32 = undefined;
    const o: i32 = 100;
    if (mode >= 18) {
        for (0..n + 1) |k| ref[@intCast(o + @as(i32, @intCast(k)))] = p(line, n, @as(i32, @intCast(k)) - 1, -1);
        if (angle < 0 and (ni * angle) >> 5 < -1) {
            var k: i32 = -1;
            while (k >= (ni * angle) >> 5) : (k -= 1) ref[@intCast(o + k)] = p(line, n, -1, -1 + ((k * tables.inv_angle[mode - 11] + 128) >> 8));
        } else {
            for (n + 1..2 * n + 1) |k| ref[@intCast(o + @as(i32, @intCast(k)))] = p(line, n, @as(i32, @intCast(k)) - 1, -1);
        }
        const idx = ((@as(i32, @intCast(y)) + 1) * angle) >> 5;
        const f = ((@as(i32, @intCast(y)) + 1) * angle) & 31;
        const b = o + @as(i32, @intCast(x)) + idx + 1;
        return if (f != 0) ((32 - f) * ref[@intCast(b)] + f * ref[@intCast(b + 1)] + 16) >> 5 else ref[@intCast(b)];
    }
    for (0..n + 1) |k| ref[@intCast(o + @as(i32, @intCast(k)))] = p(line, n, -1, @as(i32, @intCast(k)) - 1);
    if (angle < 0 and (ni * angle) >> 5 < -1) {
        var k: i32 = -1;
        while (k >= (ni * angle) >> 5) : (k -= 1) ref[@intCast(o + k)] = p(line, n, -1 + ((k * tables.inv_angle[mode - 11] + 128) >> 8), -1);
    } else {
        for (n + 1..2 * n + 1) |k| ref[@intCast(o + @as(i32, @intCast(k)))] = p(line, n, -1, @as(i32, @intCast(k)) - 1);
    }
    const idx = ((@as(i32, @intCast(x)) + 1) * angle) >> 5;
    const f = ((@as(i32, @intCast(x)) + 1) * angle) & 31;
    const b = o + @as(i32, @intCast(y)) + idx + 1;
    return if (f != 0) ((32 - f) * ref[@intCast(b)] + f * ref[@intCast(b + 1)] + 16) >> 5 else ref[@intCast(b)];
}

test "angular prediction against the standard's" {
    var prng = std.Random.DefaultPrng.init(3);
    const rnd = prng.random();
    var line: Line = undefined;
    var out: [32 * 32]u8 = undefined;
    for (2..6) |l| {
        const log2: u3 = @intCast(l);
        const n: usize = @as(usize, 1) << log2;
        for (2..35) |m| {
            const mode: u8 = @intCast(m);
            for (0..4 * n + 1) |i| line[i] = rnd.intRangeAtMost(i32, 0, 255);
            predict(u8, &line, log2, mode, false, false, 8, &out, n);
            for (0..n) |y| {
                for (0..n) |x| try testing.expectEqual(angularNaive(&line, n, mode, x, y), out[y * n + x]);
            }
        }
    }
}

test "substitution and smoothing" {
    var line: Line = undefined;
    // A 4x4 block with only its top row: everything takes its first.
    for (0..17) |i| line[i] = if (i >= 9 and i < 13) @intCast(i * 10) else missing;
    substitute(&line, 2, 8);
    for (0..10) |i| try testing.expectEqual(@as(i32, 90), line[i]);
    try testing.expectEqual(@as(i32, 120), line[16]);
    for (0..17) |i| line[i] = missing;
    substitute(&line, 2, 10);
    try testing.expectEqual(@as(i32, 512), line[8]);
    // 8x8 planar: [1 2 1] smoothing, the ends kept.
    for (0..33) |i| line[i] = @intCast(i * 4);
    smooth(&line, 3, 0, false, 8);
    try testing.expectEqual(@as(i32, 0), line[0]);
    try testing.expectEqual(@as(i32, 40), line[10]);
    try testing.expectEqual(@as(i32, 128), line[32]);
}
