// SPDX-License-Identifier: MIT
//! Film grain synthesis (7.18.3): noise made from the frame's grain
//! settings, added to a copy of a shown frame, 32 rows at a time.

const common = @import("common.zig");
const tables = @import("tables.zig");
const header = @import("header.zig");
const Env = common.Env;
const Error = common.Error;
const Frame = common.Frame;
const Grain = header.Grain;

/// The grain templates, the scaling tables and two stripes of noise for
/// each plane.
pub const Scratch = struct {
    noise: ?*Noise = null,
    stripes: []i16 = &.{},

    pub fn deinit(s: *Scratch, env: Env) void {
        if (s.noise) |n| env.destroy(Noise, n);
        env.freeSlice(i16, s.stripes);
        s.* = .{};
    }
};

const Noise = struct {
    luma: [73][82]i32,
    cb: [73][82]i32,
    cr: [73][82]i32,
    lut: [3][256]i32,
};

const Rng = struct {
    r: u16,

    /// get_random_number.
    fn next(g: *Rng, comptime bits: u5) usize {
        const r = g.r;
        const bit = (r ^ (r >> 1) ^ (r >> 3) ^ (r >> 12)) & 1;
        g.r = (r >> 1) | (bit << 15);
        return (g.r >> (16 - bits)) & ((1 << bits) - 1);
    }
};

/// The working memory for frames `width` wide made, before `apply`.
pub fn prepare(s: *Scratch, env: Env, width: u32) Error!void {
    if (s.noise == null) s.noise = env.create(Noise) orelse return error.NoMemory;
    // Two stripes, three planes, 34 rows, the width and the blocks' reach.
    const need = 2 * 3 * 34 * (@as(usize, width) + 64);
    if (s.stripes.len < need) {
        env.freeSlice(i16, s.stripes);
        s.stripes = &.{};
        s.stripes = env.slice(i16, need) orelse return error.NoMemory;
    }
}

/// `dst` set to `src` with the grain `g` added: `dst` laid out as `src`,
/// `s` prepared for its width.
pub fn apply(dst: *Frame, src: *const Frame, g: *const Grain, s: *const Scratch) void {
    const width: usize = src.width + 64;
    @memcpy(dst.memory, src.memory);
    const syn: Synth = .{ .g = g, .n = s.noise.?, .bd = @intCast(src.bit_depth), .ss_x = src.ss_x, .ss_y = src.ss_y, .mono = src.mono, .matrix = src.matrix };
    syn.generate();
    syn.scaling();
    if (src.alloc_bytes == 2) {
        syn.add(u16, dst, src, s.stripes, width);
    } else {
        syn.add(u8, dst, src, s.stripes, width);
    }
}

const Synth = struct {
    g: *const Grain,
    n: *Noise,
    bd: u5,
    ss_x: u1,
    ss_y: u1,
    mono: bool,
    matrix: u8,

    fn grainMin(syn: *const Synth) i32 {
        return -(@as(i32, 128) << (syn.bd - 8));
    }

    fn grainMax(syn: *const Synth) i32 {
        return (@as(i32, 256) << (syn.bd - 8)) - 1 - (@as(i32, 128) << (syn.bd - 8));
    }

    /// The generate grain process: the luma and chroma templates.
    fn generate(syn: *const Synth) void {
        const g = syn.g;
        const n = syn.n;
        const lo = syn.grainMin();
        const hi = syn.grainMax();
        const shift: u5 = @intCast(12 - @as(u32, syn.bd) + g.grain_scale_shift);
        const ar_shift: u5 = @intCast(g.ar_coeff_shift_minus_6 + 6);
        const lag: i32 = g.ar_coeff_lag;
        var rng: Rng = .{ .r = g.grain_seed };
        for (0..73) |y| {
            for (0..82) |x| {
                const v: i32 = if (g.num_y_points > 0) tables.gaussian_sequence[rng.next(11)] else 0;
                n.luma[y][x] = common.round2(v, shift);
            }
        }
        for (3..73) |y| {
            for (3..82 - 3) |x| {
                var s: i32 = 0;
                var pos: usize = 0;
                var dr = -lag;
                outer: while (dr <= 0) : (dr += 1) {
                    var dc = -lag;
                    while (dc <= lag) : (dc += 1) {
                        if (dr == 0 and dc == 0) break :outer;
                        const c = @as(i32, g.ar_coeffs_y_plus_128[pos]) - 128;
                        s += n.luma[@intCast(@as(i32, @intCast(y)) + dr)][@intCast(@as(i32, @intCast(x)) + dc)] * c;
                        pos += 1;
                    }
                }
                n.luma[y][x] = common.clip3(lo, hi, n.luma[y][x] + common.round2(s, ar_shift));
            }
        }
        if (syn.mono) return;
        const cw: usize = if (syn.ss_x == 1) 44 else 82;
        const ch: usize = if (syn.ss_y == 1) 38 else 73;
        const chroma_noise = [2]bool{ g.num_cb_points > 0 or g.chroma_scaling_from_luma, g.num_cr_points > 0 or g.chroma_scaling_from_luma };
        const seeds = [2]u16{ 0xb524, 0x49d8 };
        for (0..2) |k| {
            const t = if (k == 0) &n.cb else &n.cr;
            rng.r = g.grain_seed ^ seeds[k];
            for (0..ch) |y| {
                for (0..cw) |x| {
                    const v: i32 = if (chroma_noise[k]) tables.gaussian_sequence[rng.next(11)] else 0;
                    t[y][x] = common.round2(v, shift);
                }
            }
        }
        for (3..ch) |y| {
            for (3..cw - 3) |x| {
                var s0: i32 = 0;
                var s1: i32 = 0;
                var pos: usize = 0;
                var dr = -lag;
                outer: while (dr <= 0) : (dr += 1) {
                    var dc = -lag;
                    while (dc <= lag) : (dc += 1) {
                        const c0 = @as(i32, g.ar_coeffs_cb_plus_128[pos]) - 128;
                        const c1 = @as(i32, g.ar_coeffs_cr_plus_128[pos]) - 128;
                        if (dr == 0 and dc == 0) {
                            if (g.num_y_points > 0) {
                                var luma: i32 = 0;
                                const lx = ((x - 3) << syn.ss_x) + 3;
                                const ly = ((y - 3) << syn.ss_y) + 3;
                                for (0..@as(usize, syn.ss_y) + 1) |i| {
                                    for (0..@as(usize, syn.ss_x) + 1) |j| luma += n.luma[ly + i][lx + j];
                                }
                                luma = common.round2(luma, @as(u5, syn.ss_x) + syn.ss_y);
                                s0 += luma * c0;
                                s1 += luma * c1;
                            }
                            break :outer;
                        }
                        const yy: usize = @intCast(@as(i32, @intCast(y)) + dr);
                        const xx: usize = @intCast(@as(i32, @intCast(x)) + dc);
                        s0 += n.cb[yy][xx] * c0;
                        s1 += n.cr[yy][xx] * c1;
                        pos += 1;
                    }
                }
                n.cb[y][x] = common.clip3(lo, hi, n.cb[y][x] + common.round2(s0, ar_shift));
                n.cr[y][x] = common.clip3(lo, hi, n.cr[y][x] + common.round2(s1, ar_shift));
            }
        }
    }

    fn points(syn: *const Synth, p: usize) struct { n: usize, x: []const u8, y: []const u8 } {
        const g = syn.g;
        if (p == 0 or g.chroma_scaling_from_luma) return .{ .n = g.num_y_points, .x = &g.point_y_value, .y = &g.point_y_scaling };
        if (p == 1) return .{ .n = g.num_cb_points, .x = &g.point_cb_value, .y = &g.point_cb_scaling };
        return .{ .n = g.num_cr_points, .x = &g.point_cr_value, .y = &g.point_cr_scaling };
    }

    /// The scaling lookup initialisation process.
    fn scaling(syn: *const Synth) void {
        const planes: usize = if (syn.mono) 1 else 3;
        for (0..planes) |p| {
            const lut = &syn.n.lut[p];
            const pt = syn.points(p);
            if (pt.n == 0) {
                @memset(lut, 0);
                continue;
            }
            for (0..pt.x[0]) |x| lut[x] = pt.y[0];
            for (0..pt.n - 1) |i| {
                const dy = @as(i32, pt.y[i + 1]) - pt.y[i];
                const dx = @as(i32, pt.x[i + 1]) - pt.x[i];
                const delta = dy * @divTrunc(65536 + (dx >> 1), dx);
                for (0..@intCast(dx)) |x| {
                    lut[pt.x[i] + x] = pt.y[i] + ((@as(i32, @intCast(x)) * delta + 32768) >> 16);
                }
            }
            for (pt.x[pt.n - 1]..256) |x| lut[x] = pt.y[pt.n - 1];
        }
    }

    fn scaleLut(syn: *const Synth, p: usize, index: i32) i32 {
        const shift: u5 = syn.bd - 8;
        const x: usize = @intCast(index >> shift);
        const rem = index - (@as(i32, @intCast(x)) << shift);
        const lut = &syn.n.lut[p];
        if (syn.bd == 8 or x == 255) return lut[x];
        return lut[x] + common.round2((lut[x + 1] - lut[x]) * rem, shift);
    }

    /// The add noise process, a stripe of 32 luma rows at a time: its
    /// noise blocks, blended with the stripe above, added to the colour
    /// planes and then to the brightness.
    fn add(syn: *const Synth, comptime P: type, dst: *Frame, src: *const Frame, stripes: []i16, width: usize) void {
        const g = syn.g;
        const n = syn.n;
        const lo = syn.grainMin();
        const hi = syn.grainMax();
        const w = src.width;
        const h = src.height;
        const planes: usize = if (syn.mono) 1 else 3;
        const plane_rows = 34 * width;
        const stripe_len = 3 * plane_rows;
        var luma_num: u32 = 0;
        var y0: u32 = 0;
        while (y0 < (h + 1) / 2) : (y0 += 16) {
            const cur = stripes[(luma_num & 1) * stripe_len ..][0..stripe_len];
            const prev = stripes[((luma_num + 1) & 1) * stripe_len ..][0..stripe_len];
            var rng: Rng = .{ .r = g.grain_seed };
            rng.r ^= @intCast(((luma_num * 37 + 178) & 255) << 8);
            rng.r ^= @intCast((luma_num * 173 + 105) & 255);
            var x: u32 = 0;
            while (x < (w + 1) / 2) : (x += 16) {
                const rand = rng.next(8);
                const off_x = rand >> 4;
                const off_y = rand & 15;
                for (0..planes) |p| {
                    const sx: u5 = if (p > 0) syn.ss_x else 0;
                    const sy: u5 = if (p > 0) syn.ss_y else 0;
                    const px = if (sx == 1) 6 + off_x else 9 + off_x * 2;
                    const py = if (sy == 1) 6 + off_y else 9 + off_y * 2;
                    const t = if (p == 0) &n.luma else if (p == 1) &n.cb else &n.cr;
                    const out = cur[p * plane_rows ..];
                    for (0..@as(usize, 34) >> sy) |i| {
                        for (0..@as(usize, 34) >> sx) |j| {
                            var v = t[py + i][px + j];
                            const col = if (sx == 0) x * 2 + j else x + j;
                            if (g.overlap_flag and x > 0) {
                                if (sx == 0 and j < 2) {
                                    const old: i32 = out[i * width + col];
                                    v = if (j == 0) old * 27 + v * 17 else old * 17 + v * 27;
                                    v = common.clip3(lo, hi, common.round2(v, 5));
                                } else if (sx == 1 and j == 0) {
                                    const old: i32 = out[i * width + col];
                                    v = common.clip3(lo, hi, common.round2(old * 23 + v * 22, 5));
                                }
                            }
                            out[i * width + col] = @intCast(v);
                        }
                    }
                }
            }
            syn.stripe(P, dst, src, cur, prev, luma_num, width);
            luma_num += 1;
        }
    }

    fn noiseAt(syn: *const Synth, cur: []const i16, prev: []const i16, p: usize, luma_num: u32, i: usize, x: usize, width: usize) i32 {
        const lo = syn.grainMin();
        const hi = syn.grainMax();
        const plane_rows = 34 * width;
        const sy = p > 0 and syn.ss_y == 1;
        var v: i32 = cur[p * plane_rows + i * width + x];
        if (syn.g.overlap_flag and luma_num > 0) {
            if (!sy and i < 2) {
                const old: i32 = prev[p * plane_rows + (i + 32) * width + x];
                v = if (i == 0) old * 27 + v * 17 else old * 17 + v * 27;
                v = common.clip3(lo, hi, common.round2(v, 5));
            } else if (sy and i < 1) {
                const old: i32 = prev[p * plane_rows + (i + 16) * width + x];
                v = common.clip3(lo, hi, common.round2(old * 23 + v * 22, 5));
            }
        }
        return v;
    }

    fn stripe(syn: *const Synth, comptime P: type, dst: *Frame, src: *const Frame, cur: []const i16, prev: []const i16, luma_num: u32, width: usize) void {
        const g = syn.g;
        const w = src.width;
        const h = src.height;
        const bd = syn.bd;
        var min_v: i32 = 0;
        var max_luma: i32 = (@as(i32, 256) << (bd - 8)) - 1;
        var max_chroma = max_luma;
        if (g.clip_to_restricted_range) {
            min_v = @as(i32, 16) << (bd - 8);
            max_luma = @as(i32, 235) << (bd - 8);
            max_chroma = if (syn.matrix == common.MC_IDENTITY) max_luma else @as(i32, 240) << (bd - 8);
        }
        const scaling_shift: u5 = @intCast(g.grain_scaling_minus_8 + 8);
        const pixel_max = (@as(i32, 1) << bd) - 1;
        if (!syn.mono) {
            const sx: u5 = syn.ss_x;
            const sy: u5 = syn.ss_y;
            const rows = (h + sy) >> sy;
            const first = luma_num << (5 - sy);
            const last = @min(rows, (luma_num + 1) << (5 - sy));
            const cols = (w + sx) >> sx;
            const mults = [2][3]i32{
                .{ g.cb_mult, g.cb_luma_mult, g.cb_offset },
                .{ g.cr_mult, g.cr_luma_mult, g.cr_offset },
            };
            const on = [2]bool{ g.num_cb_points > 0 or g.chroma_scaling_from_luma, g.num_cr_points > 0 or g.chroma_scaling_from_luma };
            var y = first;
            while (y < last) : (y += 1) {
                const ly = y << sy;
                const yrow = src.plane(P, 0) + ly * src.stride[0];
                for (0..2) |k| {
                    if (!on[k]) continue;
                    const p = k + 1;
                    const in = src.plane(P, p) + y * src.stride[p];
                    const o = dst.plane(P, p) + y * dst.stride[p];
                    for (0..cols) |x| {
                        const lx = x << sx;
                        const nx = @min(lx + 1, w - 1);
                        const avg: i32 = if (sx == 1) common.round2(@as(i32, yrow[lx]) + yrow[nx], 1) else yrow[lx];
                        const orig: i32 = in[x];
                        const merged = if (g.chroma_scaling_from_luma) avg else blk: {
                            const combined = avg * (mults[k][1] - 128) + orig * (mults[k][0] - 128);
                            break :blk common.clip3(0, pixel_max, (combined >> 6) + ((mults[k][2] - 256) << (bd - 8)));
                        };
                        var noise = syn.noiseAt(cur, prev, p, luma_num, y - first, x, width);
                        noise = common.round2(syn.scaleLut(p, merged) * noise, scaling_shift);
                        o[x] = @intCast(common.clip3(min_v, max_chroma, orig + noise));
                    }
                }
            }
        }
        if (g.num_y_points == 0) return;
        const first = luma_num << 5;
        const last = @min(h, (luma_num + 1) << 5);
        var y = first;
        while (y < last) : (y += 1) {
            const in = src.plane(P, 0) + y * src.stride[0];
            const o = dst.plane(P, 0) + y * dst.stride[0];
            for (0..w) |x| {
                const orig: i32 = in[x];
                var noise = syn.noiseAt(cur, prev, 0, luma_num, y - first, x, width);
                noise = common.round2(syn.scaleLut(0, orig) * noise, scaling_shift);
                o[x] = @intCast(common.clip3(min_v, max_luma, orig + noise));
            }
        }
    }
};
