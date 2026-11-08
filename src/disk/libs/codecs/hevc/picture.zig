// SPDX-License-Identifier: MIT
//! What the decoding of a picture keeps of each part of it, for the parts
//! decoded after it and for the loop filters: each 8x8's coding unit,
//! each 4x4's intra mode and motion, the strength of the edges between
//! them, and each CTB's slice and SAO; the tiles the picture is cut in,
//! and the availability of a neighbour (6.4.1).

const common = @import("common.zig");
const params = @import("params.zig");
const tables = @import("tables.zig");

/// The motion of a 4x4 block: for each list its vector and reference
/// index (-1: the list unused), and the store of the picture that index
/// named, which is what the deblocking compares across slices.
pub const MvField = extern struct {
    mv: [2][2]i16 = .{ .{ 0, 0 }, .{ 0, 0 } },
    ref_idx: [2]i8 = .{ -1, -1 },
    ref_id: [2]u8 = .{ 0xff, 0xff },

    pub inline fn uses(f: MvField, x: usize) bool {
        return f.ref_idx[x] >= 0;
    }
    /// The same motion vectors and reference indices.
    pub inline fn same(a: MvField, b: MvField) bool {
        return @as(u64, @bitCast(a.mv)) == @as(u64, @bitCast(b.mv)) and @as(u16, @bitCast(a.ref_idx)) == @as(u16, @bitCast(b.ref_idx));
    }
};

/// A coding unit, kept for each 8x8 it covers.
pub const Cu = extern struct {
    /// CtDepth: what split_cu_flag's context counts.
    depth: u8 = 0,
    flags: u8 = 0,
    /// QpY.
    qp: i8 = 0,
};

pub const cu_skip: u8 = 1;
pub const cu_intra: u8 = 2;
/// Samples the loop filters leave alone: PCM ones with
/// pcm_loop_filter_disabled_flag, and those of cu_transquant_bypass.
pub const cu_nofilter: u8 = 4;

/// sao( ) of a CTB (7.3.8.3), for luma, Cb and Cr.
pub const Sao = struct {
    /// SaoTypeIdx: 0 off, 1 band offset, 2 edge offset.
    kind: [3]u8 = .{ 0, 0, 0 },
    /// sao_band_position, or SaoEoClass.
    class: [3]u8 = .{ 0, 0, 0 },
    /// SaoOffsetVal[ 1..4 ] (7-72), scaled to the sample depth.
    offsets: [3][4]i16 = @splat(@splat(0)),
};

/// What the loop filters need of a slice.
pub const SliceInfo = struct {
    /// SliceAddrRs.
    addr: u32 = 0,
    /// slice_beta_offset_div2 and slice_tc_offset_div2, times 2.
    beta: i8 = 0,
    tc: i8 = 0,
    deblock: bool = true,
    across: bool = false,
    sao_luma: bool = false,
    sao_chroma: bool = false,
};

/// A reference picture list entry.
pub const Ref = struct {
    store: ?*common.Store = null,
    poc: i32 = 0,
    long: bool = false,
    /// The store's number in the picture buffer.
    id: u8 = 0xff,
};

/// A slice's reference picture lists (8.3.4), and what the temporal
/// motion vector prediction takes from them.
pub const Lists = struct {
    refs: [2][16]Ref = @splat(@splat(.{})),
    count: [2]u8 = .{ 0, 0 },
    /// The collocated picture (8.5.3.2.8), when the slice uses one.
    col: ?*common.Store = null,
    /// NoBackwardPredFlag: no reference after the current picture.
    no_backward: bool = true,
};

/// The tiles of a picture (6.5.1): where their columns and rows begin, in
/// CTBs, and the CTB raster and tile scans of each other.
pub const Tiles = struct {
    col_bd: [params.max_tile_columns + 1]u32 = undefined,
    row_bd: [params.max_tile_rows + 1]u32 = undefined,
    cols: u32 = 1,
    rows: u32 = 1,
    /// CtbAddrRsToTs and CtbAddrTsToRs.
    rs2ts: []u32 = &.{},
    ts2rs: []u32 = &.{},
    /// TileId, by raster address (the standard's is by tile scan).
    tile: []u16 = &.{},

    /// The scans of a picture of `w` x `h` CTBs cut as `pps` says
    /// (6-3 to 6-10).
    pub fn set(t: *Tiles, pps: *const params.Pps, w: u32, h: u32) void {
        t.cols = if (pps.tiles) pps.num_tile_columns else 1;
        t.rows = if (pps.tiles) pps.num_tile_rows else 1;
        t.col_bd[0] = 0;
        for (0..t.cols) |i| {
            const width = if (!pps.tiles or pps.uniform_spacing)
                ((@as(u32, @intCast(i)) + 1) * w) / t.cols - (@as(u32, @intCast(i)) * w) / t.cols
            else if (i + 1 < t.cols) pps.column_width[i] else w - t.col_bd[i];
            t.col_bd[i + 1] = t.col_bd[i] + width;
        }
        t.row_bd[0] = 0;
        for (0..t.rows) |j| {
            const height = if (!pps.tiles or pps.uniform_spacing)
                ((@as(u32, @intCast(j)) + 1) * h) / t.rows - (@as(u32, @intCast(j)) * h) / t.rows
            else if (j + 1 < t.rows) pps.row_height[j] else h - t.row_bd[j];
            t.row_bd[j + 1] = t.row_bd[j] + height;
        }
        var ts: u32 = 0;
        var id: u16 = 0;
        for (0..t.rows) |j| {
            for (0..t.cols) |i| {
                for (t.row_bd[j]..t.row_bd[j + 1]) |y| {
                    for (t.col_bd[i]..t.col_bd[i + 1]) |x| {
                        const rs: u32 = @intCast(y * w + x);
                        t.rs2ts[rs] = ts;
                        t.ts2rs[ts] = rs;
                        t.tile[rs] = id;
                        ts += 1;
                    }
                }
                id += 1;
            }
        }
    }
};

/// Everything a picture keeps of its parts as it is decoded, for a
/// picture of up to the size it was made for.
pub const Info = struct {
    width: u32 = 0,
    height: u32 = 0,
    log2_ctb: u3 = 4,
    /// The picture in CTBs, 8x8s and 4x4s.
    wctb: u32 = 0,
    hctb: u32 = 0,
    w8: u32 = 0,
    w4: u32 = 0,
    h4: u32 = 0,
    cus: []Cu = &.{},
    /// Each 4x4's intra luma mode (DC where not intra), and in bit 7
    /// whether its luma transform block has coefficients.
    modes: []u8 = &.{},
    mvf: []MvField = &.{},
    /// Each 4x4's edges on the 8x8 grid: bits 0-1 the bS of its left
    /// edge, bits 2-3 that of its top edge.
    bs: []u8 = &.{},
    /// Each CTB's slice, an index into `slices` (none: not decoded).
    ctb_slice: []u16 = &.{},
    /// Each CTB whose decoding broke off: its slice's, part of its samples
    /// not written, concealed as one no segment brought.
    broken: []bool = &.{},
    sao: []Sao = &.{},
    slices: []SliceInfo = &.{},
    num_slices: u32 = 0,
    tiles: Tiles = .{},
    /// Each CTB row's decoded CTBs.
    row_done: []u32 = &.{},
    /// Each component's last line of each CTB row as it was decoded, for
    /// the intra prediction of the row below - so a row is filtered as
    /// soon as it is whole: two lines of the picture's width in CTBs, the
    /// even rows' and the odd rows', so that a row does not write over
    /// the line it reads.
    above: [3][]u8 = .{ &.{}, &.{}, &.{} },
    /// Some coding unit is cu_nofilter.
    any_nofilter: bool = false,

    pub const no_slice: u16 = 0xffff;

    /// The arrays for a picture of `sps`'s size.
    pub fn alloc(info: *Info, env: common.Env, sps: *const params.Sps) bool {
        info.free(env);
        info.width = sps.width;
        info.height = sps.height;
        info.log2_ctb = @intCast(sps.log2_ctb);
        info.wctb = sps.widthCtbs();
        info.hctb = sps.heightCtbs();
        // Whole CTBs, so that what a CTB writes past the picture's edge
        // stays inside.
        const w = info.wctb << info.log2_ctb;
        const h = info.hctb << info.log2_ctb;
        info.w8 = w >> 3;
        info.w4 = w >> 2;
        info.h4 = h >> 2;
        const ctbs = info.wctb * info.hctb;
        info.cus = env.slice(Cu, (w >> 3) * (h >> 3)) orelse return info.fail(env);
        info.modes = env.slice(u8, info.w4 * info.h4) orelse return info.fail(env);
        info.mvf = env.slice(MvField, info.w4 * info.h4) orelse return info.fail(env);
        info.bs = env.slice(u8, info.w4 * info.h4) orelse return info.fail(env);
        info.ctb_slice = env.slice(u16, ctbs) orelse return info.fail(env);
        info.broken = env.slice(bool, ctbs) orelse return info.fail(env);
        info.sao = env.slice(Sao, ctbs) orelse return info.fail(env);
        info.slices = env.slice(SliceInfo, ctbs) orelse return info.fail(env);
        info.tiles.rs2ts = env.slice(u32, ctbs) orelse return info.fail(env);
        info.tiles.ts2rs = env.slice(u32, ctbs) orelse return info.fail(env);
        info.tiles.tile = env.slice(u16, ctbs) orelse return info.fail(env);
        info.row_done = env.slice(u32, info.hctb) orelse return info.fail(env);
        const bytes: usize = if (sps.bit_depth_luma > 8 or sps.bit_depth_chroma > 8) 2 else 1;
        for (&info.above) |*a| a.* = env.slice(u8, 2 * w * bytes) orelse return info.fail(env);
        return true;
    }

    fn fail(info: *Info, env: common.Env) bool {
        info.free(env);
        return false;
    }

    pub fn free(info: *Info, env: common.Env) void {
        env.freeSlice(Cu, info.cus);
        env.freeSlice(u8, info.modes);
        env.freeSlice(MvField, info.mvf);
        env.freeSlice(u8, info.bs);
        env.freeSlice(u16, info.ctb_slice);
        env.freeSlice(bool, info.broken);
        env.freeSlice(Sao, info.sao);
        env.freeSlice(SliceInfo, info.slices);
        env.freeSlice(u32, info.tiles.rs2ts);
        env.freeSlice(u32, info.tiles.ts2rs);
        env.freeSlice(u16, info.tiles.tile);
        env.freeSlice(u32, info.row_done);
        for (info.above) |a| env.freeSlice(u8, a);
        info.* = .{};
    }

    /// Whether the arrays fit a picture of `sps`.
    pub fn fits(info: *const Info, sps: *const params.Sps) bool {
        return info.cus.len != 0 and info.width == sps.width and info.height == sps.height and info.log2_ctb == sps.log2_ctb;
    }

    /// Ready for a new picture with `pps`'s tiles: nothing decoded yet.
    pub fn begin(info: *Info, pps: *const params.Pps) void {
        info.tiles.set(pps, info.wctb, info.hctb);
        @memset(info.ctb_slice, no_slice);
        @memset(info.broken, false);
        @memset(info.cus, .{});
        @memset(info.bs, 0);
        // What a SAO merge takes from a CTB no segment brought.
        @memset(info.sao, .{});
        @memset(info.row_done, 0);
        info.num_slices = 0;
        info.any_nofilter = false;
    }

    /// Component `c`'s line kept of CTB row `row`, of samples of type T.
    pub inline fn aboveLine(info: *const Info, comptime T: type, c: usize, row: u32) [*]T {
        const line: [*]T = @ptrCast(@alignCast(info.above[c].ptr));
        return line + (row & 1) * (info.wctb << info.log2_ctb);
    }

    pub inline fn cu(info: *const Info, x: u32, y: u32) *Cu {
        return &info.cus[(y >> 3) * info.w8 + (x >> 3)];
    }
    pub inline fn at4(info: *const Info, x: u32, y: u32) usize {
        return (y >> 2) * info.w4 + (x >> 2);
    }
    pub inline fn ctbOf(info: *const Info, x: u32, y: u32) u32 {
        return (y >> info.log2_ctb) * info.wctb + (x >> info.log2_ctb);
    }

    /// Where the 4x4 at (x, y) comes in decoding order, as MinTbAddrZs
    /// would say it (6-10) - the same order, by 4x4 rather than by the
    /// smallest transform block.
    inline fn zOrder(info: *const Info, x: u32, y: u32) u32 {
        const shift: u5 = 2 * @as(u5, info.log2_ctb - 2);
        const m: u32 = (@as(u32, 1) << (info.log2_ctb - 2)) - 1;
        const ts = info.tiles.rs2ts[info.ctbOf(x, y)];
        return (ts << shift) | tables.morton[(((y >> 2) & m) << 4) | ((x >> 2) & m)];
    }

    /// Whether the block at (xn, yn) is available to the one at (x, y)
    /// (6.4.1): inside the picture, decoded before it, in its slice and
    /// in its tile.
    pub fn available(info: *const Info, x: u32, y: u32, xn: i32, yn: i32) bool {
        if (xn < 0 or yn < 0 or xn >= info.width or yn >= info.height) return false;
        const ux: u32 = @intCast(xn);
        const uy: u32 = @intCast(yn);
        if (info.zOrder(ux, uy) > info.zOrder(x, y)) return false;
        const a = info.ctbOf(x, y);
        const b = info.ctbOf(ux, uy);
        if (a == b) return true;
        const sb = info.ctb_slice[b];
        if (sb == no_slice or info.slices[sb].addr != info.slices[info.ctb_slice[a]].addr) return false;
        return info.tiles.tile[a] == info.tiles.tile[b];
    }
};
