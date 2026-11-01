// SPDX-License-Identifier: MIT
//! A macroblock's coefficients (RFC 6386 13), from its token partition,
//! dequantised as they are read, in 16 bits as libvpx keeps them.

const common = @import("common.zig");
const tables = @import("tables.zig");
const Bool = @import("bool.zig").Bool;

/// Whether each block had coefficients, as its neighbours' first token
/// sees it: four of the brightness across (or down), two of each colour,
/// the second-order block.
pub const Nz = [9]u8;

/// The coefficients of a macroblock: 16 brightness blocks, 4 Cb, 4 Cr,
/// then the second-order block; raster order within each.
pub const Coeffs = [25][16]i16;

/// The coefficients of block `out` read with its type's probabilities
/// and context `ctx`, from position `first`: the position after the last
/// one read, `first` when there were none.
fn block(b: *Bool, probs: *const [8][3][11]u8, ctx: u8, first: u8, out: *[16]i16, dc: i16, ac: i16) u8 {
    var c: u8 = first;
    var p = &probs[tables.bands[c]][ctx];
    if (b.read(p[0]) == 0) return first;
    while (true) {
        if (b.read(p[1]) == 0) {
            // A zero, which no end of block follows.
            c += 1;
            if (c == 16) return 16;
            p = &probs[tables.bands[c]][0];
            continue;
        }
        var v: i32 = undefined;
        var next: u8 = 2;
        if (b.read(p[2]) == 0) {
            v = 1;
            next = 1;
        } else if (b.read(p[3]) == 0) {
            v = if (b.read(p[4]) == 0) 2 else 3 + @as(i32, b.read(p[5]));
        } else {
            const cat: usize = if (b.read(p[6]) == 0)
                b.read(p[7])
            else if (b.read(p[8]) == 0)
                2 + @as(usize, b.read(p[9]))
            else
                4 + @as(usize, b.read(p[10]));
            var extra: i32 = 0;
            for (tables.cat_probs[cat]) |q| extra = (extra << 1) | b.read(q);
            v = tables.cat_base[cat] + extra;
        }
        if (b.read(128) == 1) v = -v;
        const factor: i32 = if (c > 0) ac else dc;
        out[tables.zigzag[c]] = @truncate(v * factor);
        c += 1;
        if (c == 16) return 16;
        p = &probs[tables.bands[c]][next];
        if (b.read(p[0]) == 0) return c;
    }
}

/// The coefficients of a macroblock not skipped, into `out` (cleared),
/// with its neighbours' contexts, which it leaves for the next: a bit
/// per block that had any, 24 for the second-order block.
pub fn macroblock(b: *Bool, probs: *const [4][8][3][11]u8, left: *Nz, above: *Nz, out: *Coeffs, has_y2: bool, q: *const common.Quant) u32 {
    var mask: u32 = 0;
    var first: u8 = 0;
    var kind: usize = 3;
    if (has_y2) {
        const n = block(b, &probs[1], left[8] + above[8], 0, &out[24], q.y2[0], q.y2[1]);
        const nz: u8 = @intFromBool(n > 0);
        left[8] = nz;
        above[8] = nz;
        mask |= @as(u32, nz) << 24;
        first = 1;
        kind = 0;
    }
    for (0..16) |i| {
        const n = block(b, &probs[kind], left[i >> 2] + above[i & 3], first, &out[i], q.y[0], q.y[1]);
        const nz: u8 = @intFromBool(n > first);
        left[i >> 2] = nz;
        above[i & 3] = nz;
        mask |= @as(u32, nz) << @intCast(i);
    }
    for (16..24) |i| {
        const j = i - 16;
        // Cb's 2x2 blocks on contexts 4 and 5, Cr's on 6 and 7.
        const l = 4 + (j >> 1);
        const a = 4 + (j >> 2) * 2 + (j & 1);
        const n = block(b, &probs[2], left[l] + above[a], 0, &out[i], q.uv[0], q.uv[1]);
        const nz: u8 = @intFromBool(n > 0);
        left[l] = nz;
        above[a] = nz;
        mask |= @as(u32, nz) << @intCast(i);
    }
    return mask;
}

/// A skipped macroblock's contexts: none of its blocks had coefficients,
/// though the second-order block's stays when it has none.
pub fn skip(left: *Nz, above: *Nz, has_y2: bool) void {
    const n: usize = if (has_y2) 9 else 8;
    @memset(left[0..n], 0);
    @memset(above[0..n], 0);
}
