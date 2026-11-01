// SPDX-License-Identifier: MIT
//! Reading the tiles (5.11 and 8.3): the partitions, each block's modes,
//! references and vectors, its palette and its transform blocks'
//! coefficients - dequantised here, in the order they were read - and
//! the CDEF and loop restoration settings, into what putting the frame
//! together and filtering it read (`Out`). Nothing here reads a sample.

const common = @import("common.zig");
const tables = @import("tables.zig");
const header = @import("header.zig");
const cdf = @import("cdf.zig");
const symbol = @import("symbol.zig");
const mvpred = @import("mvpred.zig");
const Env = common.Env;
const Error = common.Error;
const Mv = common.Mv;
const Cdfs = cdf.Cdfs;

pub const NO_BLOCK: u32 = 0xFFFF_FFFF;

/// A block as read: what its neighbours' contexts, its prediction and
/// the filters need.
pub const Block = struct {
    row: u32 = 0,
    col: u32 = 0,
    size: u8 = 0,
    skip: bool = false,
    skip_mode: bool = false,
    is_inter: bool = false,
    intrabc: bool = false,
    has_chroma: bool = false,
    lossless: bool = false,
    segment: u8 = 0,
    y_mode: u8 = 0,
    uv_mode: u8 = 0,
    angle_y: i8 = 0,
    angle_uv: i8 = 0,
    filter_intra: bool = false,
    filter_mode: u8 = 0,
    cfl_u: i8 = 0,
    cfl_v: i8 = 0,
    /// The palettes' sizes, their colours at `colors[pal..]` (eight of
    /// the brightness, then eight of each colour plane) and the colour
    /// maps at `maps[map..]` (the brightness's, then the colour's).
    pal_y: u8 = 0,
    pal_uv: u8 = 0,
    pal: u32 = 0,
    map: u32 = 0,
    map_uv: u32 = 0,
    ref: [2]i8 = .{ common.INTRA_FRAME, common.NONE },
    mv: [2]Mv = .{ .{}, .{} },
    filter: [2]u8 = .{ 0, 0 },
    motion_mode: u8 = common.SIMPLE,
    interintra: bool = false,
    ii_mode: u8 = 0,
    wedge_interintra: bool = false,
    wedge_index: u8 = 0,
    wedge_sign: u8 = 0,
    mask_type: u8 = 0,
    compound_type: u8 = common.COMPOUND_AVERAGE,
    comp_group_idx: u8 = 0,
    compound_idx: u8 = 0,
    tx_size: u8 = 0,
    delta_lf: [4]i8 = .{ 0, 0, 0, 0 },
    /// Its local warp's parameters at `warps[warp]`, NO_BLOCK when it
    /// has none that is valid.
    warp: u32 = NO_BLOCK,
    /// AVAIL_* bits, and for an interintra block whether the samples
    /// above right and below left of each plane are decoded (II_*).
    avail: u8 = 0,
    ii_edges: u8 = 0,
    /// Its transform blocks: `txbs[txb .. txb + ntxb]`.
    txb: u32 = 0,
    ntxb: u32 = 0,
};

pub const AVAIL_U = 1;
pub const AVAIL_L = 2;
pub const AVAIL_U_CHROMA = 4;
pub const AVAIL_L_CHROMA = 8;

/// A transform block: where, its size and type, and its coefficients
/// dequantised in scan order, `eob` of them at `coefs[coef..]`. Every
/// one of an intra block (for its prediction), those with coefficients
/// of an inter block.
pub const Txb = struct {
    coef: u32 = 0,
    eob: u16 = 0,
    /// In 4x4 units of its plane.
    x4: u16 = 0,
    y4: u16 = 0,
    plane: u8 = 0,
    txsz: u8 = 0,
    tx_type: u8 = 0,
    /// EDGE_* bits for the intra prediction.
    edges: u8 = 0,
};

pub const EDGE_LEFT = 1;
pub const EDGE_ABOVE = 2;
pub const EDGE_ABOVE_RIGHT = 4;
pub const EDGE_BELOW_LEFT = 8;

/// A local warp: the parameters and whether the estimate is valid.
pub const Warp = struct { params: [6]i32 = header.identity_gm };

/// A plane's loop restoration units.
pub const Lr = struct {
    unit_size: u32 = 64,
    rows: u32 = 0,
    cols: u32 = 0,
    kind: []u8 = &.{},
    wiener: [][2][3]i8 = &.{},
    sgr_set: []u8 = &.{},
    sgr_xqd: [][2]i8 = &.{},
};

/// What the reading of a frame leaves: the blocks by superblock and by
/// 4x4, their transform blocks, coefficients and palettes, the transform
/// sizes the loop filter needs, the CDEF strengths and the loop
/// restoration units.
pub const Out = struct {
    mi_cols: u32 = 0,
    mi_rows: u32 = 0,
    sb128: bool = false,
    sb_cols: u32 = 0,
    sb_rows: u32 = 0,
    /// The block covering each 4x4, NO_BLOCK where none was read yet.
    mi: []u32 = &.{},
    /// The transform size of each 4x4 of each plane (at the stride
    /// `mi_cols`), for the loop filter.
    lf_tx: [3][]u8 = .{ &.{}, &.{}, &.{} },
    /// Of each 64x64, -1 for none.
    cdef_idx: []i8 = &.{},
    cdef_stride: u32 = 0,
    lr: [3]Lr = .{ .{}, .{}, .{} },
    blocks: []Block = &.{},
    nblocks: u32 = 0,
    sb_first: []u32 = &.{},
    sb_count: []u32 = &.{},
    txbs: []Txb = &.{},
    ntxbs: u32 = 0,
    coefs: []i32 = &.{},
    ncoefs: u32 = 0,
    maps: []u8 = &.{},
    nmaps: u32 = 0,
    colors: []u16 = &.{},
    ncolors: u32 = 0,
    warps: []Warp = &.{},
    nwarps: u32 = 0,

    pub fn block(o: *const Out, r: u32, c: u32) *Block {
        return &o.blocks[o.mi[r * o.mi_cols + c]];
    }

    pub fn free(o: *Out, env: Env) void {
        env.freeSlice(u32, o.mi);
        for (&o.lf_tx) |*t| env.freeSlice(u8, t.*);
        env.freeSlice(i8, o.cdef_idx);
        for (&o.lr) |*l| freeLr(env, l);
        env.freeSlice(Block, o.blocks);
        env.freeSlice(u32, o.sb_first);
        env.freeSlice(u32, o.sb_count);
        env.freeSlice(Txb, o.txbs);
        env.freeSlice(i32, o.coefs);
        env.freeSlice(u8, o.maps);
        env.freeSlice(u16, o.colors);
        env.freeSlice(Warp, o.warps);
        o.* = .{};
    }
};

fn freeLr(env: Env, l: *Lr) void {
    env.freeSlice(u8, l.kind);
    env.freeSlice([2][3]i8, l.wiener);
    env.freeSlice(u8, l.sgr_set);
    env.freeSlice([2]i8, l.sgr_xqd);
    l.* = .{};
}

/// What the frame reads of a reference: its motion field and segment
/// map, as it left them, and what the motion field's projection needs.
pub const RefInfo = struct {
    mvs: []const common.MfMv = &.{},
    segs: []const u8 = &.{},
    mi_cols: u32 = 0,
    mi_rows: u32 = 0,
    frame_type: u8 = 0,
    order_hint: u32 = 0,
    saved_order_hints: [8]u32 = @splat(0),
    upscaled_width: u32 = 0,
    frame_height: u32 = 0,
};

/// The reading's state: the frame's settings, the tile's contexts and
/// CDFs, and the block being read.
pub const Parse = struct {
    env: Env,
    seq: *const header.Sequence = undefined,
    h: *const header.Frame = undefined,
    out: *Out = undefined,
    /// The references, by slot, and the slots of LAST to ALTREF.
    refs: *const [8]RefInfo = undefined,
    /// The frame's segment map (written) and the one it predicts from
    /// (read; empty for zeros); the frame's motion field for the frames
    /// after it.
    segs: []u8 = &.{},
    prev_segs: []const u8 = &.{},
    /// The projected motion field of each reference (7.9), by 8x8.
    mf: [8][]Mv = @splat(&.{}),
    mf_valid: bool = false,

    // The tile.
    r: symbol.Reader = undefined,
    c: Cdfs = undefined,
    row_start: u32 = 0,
    row_end: u32 = 0,
    col_start: u32 = 0,
    col_end: u32 = 0,
    current_q: i32 = 0,
    delta_lf: [4]i8 = @splat(0),
    read_deltas: bool = false,
    ref_sgr_xqd: [3][2]i8 = undefined,
    ref_lr_wiener: [3][2][3]i8 = undefined,
    above_level: [3][]u8 = .{ &.{}, &.{}, &.{} },
    above_dc: [3][]u8 = .{ &.{}, &.{}, &.{} },
    above_segpred: []u8 = &.{},
    left_level: [3][]u8 = .{ &.{}, &.{}, &.{} },
    left_dc: [3][]u8 = .{ &.{}, &.{}, &.{} },
    left_segpred: []u8 = &.{},
    inter_tx: []u8 = &.{},
    tx_types: []u8 = &.{},
    /// BlockDecoded (by 4x4 of each plane, from -1 to 32 on each side).
    decoded: [3][34][34]bool = undefined,
    sb_size4: u32 = 16,
    /// Tiles whose data did not end as it should: read wrongly.
    bad_tiles: u32 = 0,

    // The block.
    b: Block = .{},
    avail_u: bool = false,
    avail_l: bool = false,
    avail_u_chroma: bool = false,
    avail_l_chroma: bool = false,
    above_ref: [2]i8 = .{ 0, 0 },
    left_ref: [2]i8 = .{ 0, 0 },
    above_intra: bool = false,
    left_intra: bool = false,
    above_single: bool = false,
    left_single: bool = false,
    pal_colors: [3][8]u16 = undefined,
    color_map_y: [64 * 64]u8 = undefined,
    color_map_uv: [64 * 64]u8 = undefined,
    max_luma_w: u32 = 0,
    max_luma_h: u32 = 0,
    /// The levels of the transform block read, at the stride of its
    /// width and TX_PAD; all 0 between blocks.
    levels: [(32 + TX_PAD) * (32 + TX_PAD)]u8 = undefined,

    // The vector prediction's (mvpred.zig).
    mv: mvpred.State = .{},

    pub fn init(env: Env) Parse {
        return .{ .env = env };
    }

    pub fn deinit(ps: *Parse) void {
        const env = ps.env;
        for (0..3) |p| {
            env.freeSlice(u8, ps.above_level[p]);
            env.freeSlice(u8, ps.above_dc[p]);
            env.freeSlice(u8, ps.left_level[p]);
            env.freeSlice(u8, ps.left_dc[p]);
        }
        env.freeSlice(u8, ps.above_segpred);
        env.freeSlice(u8, ps.left_segpred);
        env.freeSlice(u8, ps.inter_tx);
        env.freeSlice(u8, ps.tx_types);
        for (&ps.mf) |*m| env.freeSlice(Mv, m.*);
    }

    /// The arrays sized for a frame of `mi_cols` by `mi_rows`.
    pub fn size(ps: *Parse, out: *Out, mi_cols: u32, mi_rows: u32, sb128: bool) Error!void {
        const env = ps.env;
        const n = mi_cols * mi_rows;
        const wide = mi_cols + 64;
        const high = mi_rows + 64;
        if (ps.inter_tx.len != n) {
            for (0..3) |p| {
                if (!env.resize(u8, &ps.above_level[p], wide)) return error.NoMemory;
                if (!env.resize(u8, &ps.above_dc[p], wide)) return error.NoMemory;
                if (!env.resize(u8, &ps.left_level[p], high)) return error.NoMemory;
                if (!env.resize(u8, &ps.left_dc[p], high)) return error.NoMemory;
            }
            if (!env.resize(u8, &ps.above_segpred, wide)) return error.NoMemory;
            if (!env.resize(u8, &ps.left_segpred, high)) return error.NoMemory;
            if (!env.resize(u8, &ps.inter_tx, n)) return error.NoMemory;
            if (!env.resize(u8, &ps.tx_types, n)) return error.NoMemory;
            const n8 = (mi_cols >> 1) * (mi_rows >> 1);
            for (1..8) |i| {
                if (!env.resize(Mv, &ps.mf[i], n8)) return error.NoMemory;
            }
        }
        const sb_shift: u5 = if (sb128) 5 else 4;
        const sb_cols = (mi_cols + (@as(u32, 1) << sb_shift) - 1) >> sb_shift;
        const sb_rows = (mi_rows + (@as(u32, 1) << sb_shift) - 1) >> sb_shift;
        if (out.mi.len != n) {
            if (!env.resize(u32, &out.mi, n)) return error.NoMemory;
            for (0..3) |p| {
                if (!env.resize(u8, &out.lf_tx[p], n)) return error.NoMemory;
            }
        }
        out.cdef_stride = (mi_cols + 15) >> 4;
        const ncdef = out.cdef_stride * ((mi_rows + 15) >> 4);
        if (out.cdef_idx.len != ncdef) {
            if (!env.resize(i8, &out.cdef_idx, ncdef)) return error.NoMemory;
        }
        if (out.sb_first.len != sb_cols * sb_rows) {
            if (!env.resize(u32, &out.sb_first, sb_cols * sb_rows)) return error.NoMemory;
            if (!env.resize(u32, &out.sb_count, sb_cols * sb_rows)) return error.NoMemory;
        }
        out.mi_cols = mi_cols;
        out.mi_rows = mi_rows;
        out.sb128 = sb128;
        out.sb_cols = sb_cols;
        out.sb_rows = sb_rows;
    }

    /// Ready for the frame's tiles: the maps cleared, the loop
    /// restoration units counted.
    pub fn begin(ps: *Parse, out: *Out, seq: *const header.Sequence, h: *const header.Frame, refs: *const [8]RefInfo, segs: []u8, prev_segs: []const u8) Error!void {
        ps.seq = seq;
        ps.h = h;
        ps.out = out;
        ps.refs = refs;
        ps.segs = segs;
        ps.prev_segs = prev_segs;
        ps.sb_size4 = if (seq.use_128x128) 32 else 16;
        try ps.size(out, h.mi_cols, h.mi_rows, seq.use_128x128);
        @memset(out.mi, NO_BLOCK);
        @memset(out.cdef_idx, -1);
        // After a frame that was not right, what it left.
        @memset(&ps.levels, 0);
        out.nblocks = 0;
        out.ntxbs = 0;
        out.ncoefs = 0;
        out.nmaps = 0;
        out.ncolors = 0;
        out.nwarps = 0;
        for (0..seq.planes()) |p| {
            const l = &out.lr[p];
            if (h.frame_restoration_type[p] == common.RESTORE_NONE) {
                l.rows = 0;
                l.cols = 0;
                continue;
            }
            const ssx: u5 = if (p > 0) seq.ss_x else 0;
            const ssy: u5 = if (p > 0) seq.ss_y else 0;
            l.unit_size = h.loop_restoration_size[p];
            l.rows = countUnits(l.unit_size, @intCast(common.round2(@intCast(h.frame_height), ssy)));
            l.cols = countUnits(l.unit_size, @intCast(common.round2(@intCast(h.upscaled_width), ssx)));
            const n = l.rows * l.cols;
            if (l.kind.len != n) {
                freeLr(ps.env, l);
                l.unit_size = h.loop_restoration_size[p];
                l.rows = countUnits(l.unit_size, @intCast(common.round2(@intCast(h.frame_height), ssy)));
                l.cols = countUnits(l.unit_size, @intCast(common.round2(@intCast(h.upscaled_width), ssx)));
                l.kind = ps.env.slice(u8, n) orelse return error.NoMemory;
                l.wiener = ps.env.slice([2][3]i8, n) orelse return error.NoMemory;
                l.sgr_set = ps.env.slice(u8, n) orelse return error.NoMemory;
                l.sgr_xqd = ps.env.slice([2]i8, n) orelse return error.NoMemory;
            }
            @memset(l.kind, common.RESTORE_NONE);
        }
        if (h.use_ref_frame_mvs) mvpred.motionField(ps);
    }

    /// Tile `tile` of the frame, `data` its bytes, from the frame's CDFs
    /// `frame_cdfs`; its CDFs at the end into `saved` when it is the
    /// tile the frame's CDFs adapt to.
    pub fn tile(ps: *Parse, tile_num: u32, data: []const u8, frame_cdfs: *const Cdfs, saved: ?*Cdfs) Error!void {
        const h = ps.h;
        const out = ps.out;
        const tile_row = tile_num / h.tile_cols;
        const tile_col = tile_num % h.tile_cols;
        ps.row_start = h.mi_row_starts[tile_row];
        ps.row_end = h.mi_row_starts[tile_row + 1];
        ps.col_start = h.mi_col_starts[tile_col];
        ps.col_end = h.mi_col_starts[tile_col + 1];
        ps.current_q = h.base_q_idx;
        ps.c = frame_cdfs.*;
        ps.c.intra_frame_y_mode = @import("cdfs.zig").default_intra_frame_y_mode_cdf;
        ps.r = symbol.Reader.init(data, !h.disable_cdf_update);

        // clear_above_context
        for (0..3) |p| {
            @memset(ps.above_level[p], 0);
            @memset(ps.above_dc[p], 0);
        }
        @memset(ps.above_segpred, 0);
        ps.delta_lf = @splat(0);
        for (0..3) |p| {
            for (0..2) |pass| {
                ps.ref_sgr_xqd[p][pass] = tables.sgrproj_xqd_mid[pass];
                for (0..3) |i| ps.ref_lr_wiener[p][pass][i] = tables.wiener_taps_mid[i];
            }
        }
        const sb_size: u8 = if (ps.seq.use_128x128) common.BLOCK_128X128 else common.BLOCK_64X64;
        const sb4 = ps.sb_size4;
        const sb_shift: u5 = if (ps.seq.use_128x128) 5 else 4;
        var r = ps.row_start;
        while (r < ps.row_end) : (r += sb4) {
            // clear_left_context
            for (0..3) |p| {
                @memset(ps.left_level[p], 0);
                @memset(ps.left_dc[p], 0);
            }
            @memset(ps.left_segpred, 0);
            var c = ps.col_start;
            while (c < ps.col_end) : (c += sb4) {
                const sb = (r >> sb_shift) * out.sb_cols + (c >> sb_shift);
                out.sb_first[sb] = out.nblocks;
                ps.read_deltas = h.delta_q_present;
                ps.clearDecoded(r, c);
                try ps.readLr(r, c, sb_size);
                try ps.partition(r, c, sb_size);
                out.sb_count[sb] = out.nblocks - out.sb_first[sb];
            }
        }
        if (saved) |s| s.* = ps.c;
        if (!ps.r.finished()) ps.bad_tiles += 1;
    }

    fn clearDecoded(ps: *Parse, r: u32, c: u32) void {
        const sb4: i32 = @intCast(ps.sb_size4);
        for (0..ps.seq.planes()) |p| {
            const ssx: u5 = if (p > 0) ps.seq.ss_x else 0;
            const ssy: u5 = if (p > 0) ps.seq.ss_y else 0;
            const sb_w4: i32 = @intCast((ps.col_end - c) >> ssx);
            const sb_h4: i32 = @intCast((ps.row_end - r) >> ssy);
            var y: i32 = -1;
            while (y <= (sb4 >> ssy)) : (y += 1) {
                var x: i32 = -1;
                while (x <= (sb4 >> ssx)) : (x += 1) {
                    const v = if (y < 0 and x < sb_w4) true else if (x < 0 and y < sb_h4) true else false;
                    ps.decoded[p][@intCast(y + 1)][@intCast(x + 1)] = v;
                }
            }
            ps.decoded[p][@intCast((sb4 >> ssy) + 1)][0] = false;
        }
    }

    fn isInside(ps: *const Parse, r: i64, c: i64) bool {
        return c >= ps.col_start and c < ps.col_end and r >= ps.row_start and r < ps.row_end;
    }

    fn sym(ps: *Parse, p: anytype) u32 {
        return ps.r.symbol(p);
    }

    fn lit(ps: *Parse, n: u32) u32 {
        return ps.r.literal(n);
    }

    /// NS(n) with the symbol decoder's bits.
    fn nsBool(ps: *Parse, n: u32) u32 {
        if (n <= 1) return 0;
        const w: u32 = @as(u32, common.floorLog2(n)) + 1;
        const m = (@as(u32, 1) << @intCast(w)) - n;
        const v = ps.lit(w - 1);
        if (v < m) return v;
        return (v << 1) - m + ps.lit(1);
    }

    // --- partitions (5.11.4) ---

    fn partition(ps: *Parse, r: u32, c: u32, bsize: u8) Error!void {
        const out = ps.out;
        if (r >= out.mi_rows or c >= out.mi_cols) return;
        const avail_u = ps.isInside(@as(i64, r) - 1, c);
        const avail_l = ps.isInside(r, @as(i64, c) - 1);
        const num4x4: u32 = tables.num_4x4_blocks_wide[bsize];
        const half = num4x4 >> 1;
        const quarter = half >> 1;
        const has_rows = (r + half) < out.mi_rows;
        const has_cols = (c + half) < out.mi_cols;
        var p: u8 = common.PARTITION_NONE;
        if (bsize < common.BLOCK_8X8) {
            p = common.PARTITION_NONE;
        } else {
            const bsl = tables.mi_width_log2[bsize];
            const above: u32 = @intFromBool(avail_u and tables.mi_width_log2[out.block(r - 1, c).size] < bsl);
            const left: u32 = @intFromBool(avail_l and tables.mi_height_log2[out.block(r, c - 1).size] < bsl);
            const ctx = left * 2 + above;
            if (has_rows and has_cols) {
                p = @intCast(switch (bsl) {
                    1 => ps.sym(&ps.c.partition_w8[ctx]),
                    2 => ps.sym(&ps.c.partition_w16[ctx]),
                    3 => ps.sym(&ps.c.partition_w32[ctx]),
                    4 => ps.sym(&ps.c.partition_w64[ctx]),
                    else => ps.sym(&ps.c.partition_w128[ctx]),
                });
            } else if (has_cols) {
                const pc = ps.partitionCdf(bsl, ctx);
                var psum = prob(pc, common.PARTITION_VERT) + prob(pc, common.PARTITION_SPLIT) +
                    prob(pc, common.PARTITION_HORZ_A) + prob(pc, common.PARTITION_VERT_A) +
                    prob(pc, common.PARTITION_VERT_B);
                if (bsize != common.BLOCK_128X128) psum += prob(pc, common.PARTITION_VERT_4);
                var t = [3]u16{ @intCast(32768 - psum), 32768, 0 };
                p = if (ps.sym(&t) == 1) common.PARTITION_SPLIT else common.PARTITION_HORZ;
            } else if (has_rows) {
                const pc = ps.partitionCdf(bsl, ctx);
                var psum = prob(pc, common.PARTITION_HORZ) + prob(pc, common.PARTITION_SPLIT) +
                    prob(pc, common.PARTITION_HORZ_A) + prob(pc, common.PARTITION_HORZ_B) +
                    prob(pc, common.PARTITION_VERT_A);
                if (bsize != common.BLOCK_128X128) psum += prob(pc, common.PARTITION_HORZ_4);
                var t = [3]u16{ @intCast(32768 - psum), 32768, 0 };
                p = if (ps.sym(&t) == 1) common.PARTITION_SPLIT else common.PARTITION_VERT;
            } else {
                p = common.PARTITION_SPLIT;
            }
        }
        const sub = tables.partition_subsize[p][bsize];
        const split = tables.partition_subsize[common.PARTITION_SPLIT][bsize];
        // A block whose colour would be no size (4x8 in 4:2:2) is not
        // AV1's.
        if (tables.subsampled_size[sub][ps.seq.ss_x][ps.seq.ss_y] == common.BLOCK_INVALID) return error.Corrupt;
        switch (p) {
            common.PARTITION_NONE => try ps.decodeBlock(r, c, sub),
            common.PARTITION_HORZ => {
                try ps.decodeBlock(r, c, sub);
                if (has_rows) try ps.decodeBlock(r + half, c, sub);
            },
            common.PARTITION_VERT => {
                try ps.decodeBlock(r, c, sub);
                if (has_cols) try ps.decodeBlock(r, c + half, sub);
            },
            common.PARTITION_SPLIT => {
                try ps.partition(r, c, sub);
                try ps.partition(r, c + half, sub);
                try ps.partition(r + half, c, sub);
                try ps.partition(r + half, c + half, sub);
            },
            common.PARTITION_HORZ_A => {
                try ps.decodeBlock(r, c, split);
                try ps.decodeBlock(r, c + half, split);
                try ps.decodeBlock(r + half, c, sub);
            },
            common.PARTITION_HORZ_B => {
                try ps.decodeBlock(r, c, sub);
                try ps.decodeBlock(r + half, c, split);
                try ps.decodeBlock(r + half, c + half, split);
            },
            common.PARTITION_VERT_A => {
                try ps.decodeBlock(r, c, split);
                try ps.decodeBlock(r + half, c, split);
                try ps.decodeBlock(r, c + half, sub);
            },
            common.PARTITION_VERT_B => {
                try ps.decodeBlock(r, c, sub);
                try ps.decodeBlock(r, c + half, split);
                try ps.decodeBlock(r + half, c + half, split);
            },
            common.PARTITION_HORZ_4 => {
                try ps.decodeBlock(r, c, sub);
                try ps.decodeBlock(r + quarter, c, sub);
                try ps.decodeBlock(r + quarter * 2, c, sub);
                if (r + quarter * 3 < out.mi_rows) try ps.decodeBlock(r + quarter * 3, c, sub);
            },
            else => {
                try ps.decodeBlock(r, c, sub);
                try ps.decodeBlock(r, c + quarter, sub);
                try ps.decodeBlock(r, c + quarter * 2, sub);
                if (c + quarter * 3 < out.mi_cols) try ps.decodeBlock(r, c + quarter * 3, sub);
            },
        }
    }

    fn partitionCdf(ps: *Parse, bsl: u8, ctx: u32) []const u16 {
        return switch (bsl) {
            2 => &ps.c.partition_w16[ctx],
            3 => &ps.c.partition_w32[ctx],
            4 => &ps.c.partition_w64[ctx],
            else => &ps.c.partition_w128[ctx],
        };
    }

    // --- blocks (5.11.5) ---

    fn decodeBlock(ps: *Parse, r: u32, c: u32, sub: u8) Error!void {
        const out = ps.out;
        const seq = ps.seq;
        const h = ps.h;
        const bw4: u32 = tables.num_4x4_blocks_wide[sub];
        const bh4: u32 = tables.num_4x4_blocks_high[sub];
        ps.b = .{ .row = r, .col = c, .size = sub };
        const b = &ps.b;
        if (bh4 == 1 and seq.ss_y == 1 and (r & 1) == 0) {
            b.has_chroma = false;
        } else if (bw4 == 1 and seq.ss_x == 1 and (c & 1) == 0) {
            b.has_chroma = false;
        } else {
            b.has_chroma = seq.planes() > 1;
        }
        ps.avail_u = ps.isInside(@as(i64, r) - 1, c);
        ps.avail_l = ps.isInside(r, @as(i64, c) - 1);
        ps.avail_u_chroma = ps.avail_u;
        ps.avail_l_chroma = ps.avail_l;
        if (b.has_chroma) {
            if (seq.ss_y == 1 and bh4 == 1) ps.avail_u_chroma = ps.isInside(@as(i64, r) - 2, c);
            if (seq.ss_x == 1 and bw4 == 1) ps.avail_l_chroma = ps.isInside(r, @as(i64, c) - 2);
        } else {
            ps.avail_u_chroma = false;
            ps.avail_l_chroma = false;
        }
        b.avail = @as(u8, if (ps.avail_u) AVAIL_U else 0) | @as(u8, if (ps.avail_l) AVAIL_L else 0) |
            @as(u8, if (ps.avail_u_chroma) AVAIL_U_CHROMA else 0) | @as(u8, if (ps.avail_l_chroma) AVAIL_L_CHROMA else 0);

        if (h.intra) try ps.intraFrameModeInfo() else try ps.interFrameModeInfo();

        // The block is known to its neighbours from here on.
        if (out.nblocks >= out.blocks.len) {
            if (!ps.env.grow(Block, &out.blocks, out.nblocks + 1)) return error.NoMemory;
        }
        const idx = out.nblocks;
        out.nblocks += 1;
        const rows = @min(bh4, out.mi_rows - r);
        const cols = @min(bw4, out.mi_cols - c);
        for (0..rows) |y| {
            const row = out.mi[(r + y) * out.mi_cols + c ..][0..cols];
            @memset(row, idx);
        }
        try ps.paletteTokens();
        ps.readBlockTxSize();
        if (b.skip) ps.resetBlockContext(bw4, bh4);
        b.txb = out.ntxbs;
        if (b.interintra) ps.interIntraEdges();
        try ps.residual();
        b.ntxb = out.ntxbs - b.txb;
        for (0..rows) |y| {
            const at = (r + y) * out.mi_cols + c;
            @memset(ps.segs[at..][0..cols], b.segment);
        }
        out.blocks[idx] = b.*;
    }

    fn resetBlockContext(ps: *Parse, bw4: u32, bh4: u32) void {
        const b = &ps.b;
        const planes: u32 = if (b.has_chroma) 3 else 1;
        for (0..planes) |p| {
            const ssx: u5 = if (p > 0) ps.seq.ss_x else 0;
            const ssy: u5 = if (p > 0) ps.seq.ss_y else 0;
            const x0 = b.col >> ssx;
            const x1 = (b.col + bw4) >> ssx;
            if (x1 > x0) {
                @memset(ps.above_level[p][x0..x1], 0);
                @memset(ps.above_dc[p][x0..x1], 0);
            }
            const y0 = b.row >> ssy;
            const y1 = (b.row + bh4) >> ssy;
            if (y1 > y0) {
                @memset(ps.left_level[p][y0..y1], 0);
                @memset(ps.left_dc[p][y0..y1], 0);
            }
        }
    }

    /// The interintra prediction's edges (compute_prediction): whether
    /// the samples above right and below left of each plane are decoded.
    fn interIntraEdges(ps: *Parse) void {
        const b = &ps.b;
        const mask: u32 = if (ps.seq.use_128x128) 31 else 15;
        const sub_r = b.row & mask;
        const sub_c = b.col & mask;
        var e: u8 = 0;
        const planes: u32 = if (b.has_chroma) 3 else 1;
        for (0..planes) |p| {
            const ssx: u5 = if (p > 0) ps.seq.ss_x else 0;
            const ssy: u5 = if (p > 0) ps.seq.ss_y else 0;
            const psz = tables.subsampled_size[b.size][ssx][ssy];
            const w4: u32 = tables.num_4x4_blocks_wide[psz];
            const h4: u32 = tables.num_4x4_blocks_high[psz];
            const y = sub_r >> ssy;
            const x = sub_c >> ssx;
            if (ps.decoded[p][y][x + w4 + 1]) e |= @as(u8, 1) << @intCast(2 * p);
            if (ps.decoded[p][y + h4 + 1][x]) e |= @as(u8, 2) << @intCast(2 * p);
        }
        b.ii_edges = e;
    }

    // --- mode info (5.11.6 to 5.11.32) ---

    fn intraFrameModeInfo(ps: *Parse) Error!void {
        const h = ps.h;
        const b = &ps.b;
        b.skip = false;
        if (h.seg_id_pre_skip) ps.intraSegmentId();
        b.skip_mode = false;
        ps.readSkip();
        if (!h.seg_id_pre_skip) ps.intraSegmentId();
        ps.readCdef();
        ps.readDeltaQ();
        ps.readDeltaLf();
        ps.read_deltas = false;
        b.ref = .{ common.INTRA_FRAME, common.NONE };
        b.intrabc = if (h.allow_intrabc) ps.sym(&ps.c.intrabc) == 1 else false;
        if (b.intrabc) {
            b.is_inter = true;
            b.y_mode = common.DC_PRED;
            b.uv_mode = common.DC_PRED;
            b.motion_mode = common.SIMPLE;
            b.compound_type = common.COMPOUND_AVERAGE;
            b.pal_y = 0;
            b.pal_uv = 0;
            b.filter = .{ common.BILINEAR, common.BILINEAR };
            mvpred.findMvStack(ps, false);
            try ps.assignMv(false);
        } else {
            b.is_inter = false;
            const out = ps.out;
            const above: u8 = if (ps.avail_u) out.block(b.row - 1, b.col).y_mode else common.DC_PRED;
            const left: u8 = if (ps.avail_l) out.block(b.row, b.col - 1).y_mode else common.DC_PRED;
            const actx = tables.intra_mode_context[above];
            const lctx = tables.intra_mode_context[left];
            b.y_mode = @intCast(ps.sym(&ps.c.intra_frame_y_mode[actx][lctx]));
            ps.intraAngleInfoY();
            if (b.has_chroma) {
                b.uv_mode = @intCast(ps.readUvMode());
                if (b.uv_mode == common.UV_CFL_PRED) ps.readCflAlphas();
                ps.intraAngleInfoUv();
            }
            b.pal_y = 0;
            b.pal_uv = 0;
            if (b.size >= common.BLOCK_8X8 and blockWidth(b.size) <= 64 and blockHeight(b.size) <= 64 and h.allow_screen_content_tools) {
                try ps.paletteModeInfo();
            }
            ps.filterIntraModeInfo();
        }
    }

    fn intraSegmentId(ps: *Parse) void {
        if (ps.h.segmentation_enabled) ps.readSegmentId() else ps.b.segment = 0;
        ps.b.lossless = ps.h.lossless[ps.b.segment];
    }

    fn segAt(ps: *const Parse, r: u32, c: u32) i32 {
        return ps.segs[r * ps.out.mi_cols + c];
    }

    fn readSegmentId(ps: *Parse) void {
        const b = &ps.b;
        const prev_ul: i32 = if (ps.avail_u and ps.avail_l) ps.segAt(b.row - 1, b.col - 1) else -1;
        const prev_u: i32 = if (ps.avail_u) ps.segAt(b.row - 1, b.col) else -1;
        const prev_l: i32 = if (ps.avail_l) ps.segAt(b.row, b.col - 1) else -1;
        var pred: i32 = 0;
        if (prev_u == -1) {
            pred = if (prev_l == -1) 0 else prev_l;
        } else if (prev_l == -1) {
            pred = prev_u;
        } else {
            pred = if (prev_ul == prev_u) prev_u else prev_l;
        }
        if (b.skip) {
            b.segment = @intCast(pred);
            return;
        }
        var ctx: u32 = 0;
        if (prev_ul < 0) {
            ctx = 0;
        } else if (prev_ul == prev_u and prev_ul == prev_l) {
            ctx = 2;
        } else if (prev_ul == prev_u or prev_ul == prev_l or prev_u == prev_l) {
            ctx = 1;
        }
        const v: i32 = @intCast(ps.sym(&ps.c.segment_id[ctx]));
        const seg = negDeinterleave(v, pred, @as(i32, ps.h.last_active_seg_id) + 1);
        b.segment = @intCast(common.clip3(0, ps.h.last_active_seg_id, seg));
    }

    fn readSkipMode(ps: *Parse) void {
        const b = &ps.b;
        const h = ps.h;
        if (h.featureActive(b.segment, common.SEG_LVL_SKIP) or h.featureActive(b.segment, common.SEG_LVL_REF_FRAME) or
            h.featureActive(b.segment, common.SEG_LVL_GLOBALMV) or !h.skip_mode_present or
            blockWidth(b.size) < 8 or blockHeight(b.size) < 8)
        {
            b.skip_mode = false;
            return;
        }
        var ctx: u32 = 0;
        if (ps.avail_u and ps.out.block(b.row - 1, b.col).skip_mode) ctx += 1;
        if (ps.avail_l and ps.out.block(b.row, b.col - 1).skip_mode) ctx += 1;
        b.skip_mode = ps.sym(&ps.c.skip_mode[ctx]) == 1;
    }

    fn readSkip(ps: *Parse) void {
        const b = &ps.b;
        if (ps.h.seg_id_pre_skip and ps.h.featureActive(b.segment, common.SEG_LVL_SKIP)) {
            b.skip = true;
            return;
        }
        var ctx: u32 = 0;
        if (ps.avail_u and ps.out.block(b.row - 1, b.col).skip) ctx += 1;
        if (ps.avail_l and ps.out.block(b.row, b.col - 1).skip) ctx += 1;
        b.skip = ps.sym(&ps.c.skip[ctx]) == 1;
    }

    fn readCdef(ps: *Parse) void {
        const b = &ps.b;
        const h = ps.h;
        if (b.skip or h.coded_lossless or !ps.seq.enable_cdef or h.allow_intrabc) return;
        const out = ps.out;
        const r = b.row & ~@as(u32, 15);
        const c = b.col & ~@as(u32, 15);
        const at = (r >> 4) * out.cdef_stride + (c >> 4);
        if (out.cdef_idx[at] != -1) return;
        const v: i8 = @intCast(ps.lit(h.cdef_bits));
        const w4: u32 = tables.num_4x4_blocks_wide[b.size];
        const h4: u32 = tables.num_4x4_blocks_high[b.size];
        var i = r;
        while (i < r + h4) : (i += 16) {
            var j = c;
            while (j < c + w4) : (j += 16) {
                if (i < out.mi_rows and j < out.mi_cols) out.cdef_idx[(i >> 4) * out.cdef_stride + (j >> 4)] = v;
            }
        }
    }

    fn readDeltaQ(ps: *Parse) void {
        const b = &ps.b;
        const sb_size: u8 = if (ps.seq.use_128x128) common.BLOCK_128X128 else common.BLOCK_64X64;
        if (b.size == sb_size and b.skip) return;
        if (!ps.read_deltas) return;
        var abs: u32 = ps.sym(&ps.c.delta_q);
        if (abs == 3) {
            const rem = ps.lit(3) + 1;
            abs = ps.lit(rem) + (@as(u32, 1) << @intCast(rem)) + 1;
        }
        if (abs != 0) {
            const sign = ps.lit(1);
            const reduced: i32 = if (sign == 1) -@as(i32, @intCast(abs)) else @intCast(abs);
            ps.current_q = common.clip3(1, 255, ps.current_q + (reduced << ps.h.delta_q_res));
        }
    }

    fn readDeltaLf(ps: *Parse) void {
        const b = &ps.b;
        const h = ps.h;
        const sb_size: u8 = if (ps.seq.use_128x128) common.BLOCK_128X128 else common.BLOCK_64X64;
        if (b.size == sb_size and b.skip) return;
        if (!ps.read_deltas or !h.delta_lf_present) return;
        var count: usize = 1;
        if (h.delta_lf_multi) count = if (ps.seq.planes() > 1) 4 else 2;
        for (0..count) |i| {
            var abs: u32 = if (h.delta_lf_multi) ps.sym(&ps.c.delta_lf_multi[i]) else ps.sym(&ps.c.delta_lf);
            if (abs == 3) {
                const n = ps.lit(3) + 1;
                abs = ps.lit(n) + (@as(u32, 1) << @intCast(n)) + 1;
            }
            if (abs != 0) {
                const sign = ps.lit(1);
                const reduced: i32 = if (sign == 1) -@as(i32, @intCast(abs)) else @intCast(abs);
                ps.delta_lf[i] = @intCast(common.clip3(-common.MAX_LOOP_FILTER, common.MAX_LOOP_FILTER, ps.delta_lf[i] + (reduced << h.delta_lf_res)));
            }
        }
    }

    fn readTxSize(ps: *Parse, allow_select: bool) void {
        const b = &ps.b;
        if (b.lossless) {
            b.tx_size = common.TX_4X4;
            return;
        }
        const max_rect = tables.max_tx_size_rect[b.size];
        const max_depth = tables.max_tx_depth[b.size];
        b.tx_size = max_rect;
        if (b.size > common.BLOCK_4X4 and allow_select and ps.h.tx_mode == common.TX_MODE_SELECT) {
            const out = ps.out;
            const max_w: u32 = tables.tx_width[max_rect];
            const max_h: u32 = tables.tx_height[max_rect];
            var above_w: u32 = 0;
            if (ps.avail_u) {
                const a = out.block(b.row - 1, b.col);
                above_w = if (a.is_inter) blockWidth(a.size) else ps.aboveTxWidth(b.row, b.col);
            }
            var left_h: u32 = 0;
            if (ps.avail_l) {
                const l = out.block(b.row, b.col - 1);
                left_h = if (l.is_inter) blockHeight(l.size) else ps.leftTxHeight(b.row, b.col);
            }
            const ctx: u32 = @as(u32, @intFromBool(above_w >= max_w)) + @intFromBool(left_h >= max_h);
            const depth = switch (max_depth) {
                4 => ps.sym(&ps.c.tx_64x64[ctx]),
                3 => ps.sym(&ps.c.tx_32x32[ctx]),
                2 => ps.sym(&ps.c.tx_16x16[ctx]),
                else => ps.sym(&ps.c.tx_8x8[ctx]),
            };
            for (0..depth) |_| b.tx_size = tables.split_tx_size[b.tx_size];
        }
    }

    fn aboveTxWidth(ps: *const Parse, row: u32, col: u32) u32 {
        const out = ps.out;
        if (row == ps.b.row) {
            if (!ps.avail_u) return 64;
            const a = out.block(row - 1, col);
            if (a.skip and a.is_inter) return blockWidth(a.size);
        }
        return tables.tx_width[ps.inter_tx[(row - 1) * out.mi_cols + col]];
    }

    fn leftTxHeight(ps: *const Parse, row: u32, col: u32) u32 {
        const out = ps.out;
        if (col == ps.b.col) {
            if (!ps.avail_l) return 64;
            const l = out.block(row, col - 1);
            if (l.skip and l.is_inter) return blockHeight(l.size);
        }
        return tables.tx_height[ps.inter_tx[row * out.mi_cols + col - 1]];
    }

    fn readBlockTxSize(ps: *Parse) void {
        const b = &ps.b;
        const out = ps.out;
        const bw4: u32 = tables.num_4x4_blocks_wide[b.size];
        const bh4: u32 = tables.num_4x4_blocks_high[b.size];
        if (ps.h.tx_mode == common.TX_MODE_SELECT and b.size > common.BLOCK_4X4 and b.is_inter and !b.skip and !b.lossless) {
            const max_tx = tables.max_tx_size_rect[b.size];
            const tw4: u32 = tables.tx_width[max_tx] / 4;
            const th4: u32 = tables.tx_height[max_tx] / 4;
            var row = b.row;
            while (row < b.row + bh4) : (row += th4) {
                var col = b.col;
                while (col < b.col + bw4) : (col += tw4) ps.readVarTxSize(row, col, max_tx, 0);
            }
        } else {
            ps.readTxSize(!b.skip or !b.is_inter);
            const rows = @min(bh4, out.mi_rows - b.row);
            const cols = @min(bw4, out.mi_cols - b.col);
            for (0..rows) |y| @memset(ps.inter_tx[(b.row + y) * out.mi_cols + b.col ..][0..cols], b.tx_size);
        }
    }

    fn readVarTxSize(ps: *Parse, row: u32, col: u32, txsz: u8, depth: u32) void {
        const out = ps.out;
        const b = &ps.b;
        if (row >= out.mi_rows or col >= out.mi_cols) return;
        var split = false;
        if (txsz != common.TX_4X4 and depth != 2) {
            const above: u32 = @intFromBool(ps.aboveTxWidth(row, col) < tables.tx_width[txsz]);
            const left: u32 = @intFromBool(ps.leftTxHeight(row, col) < tables.tx_height[txsz]);
            const sz = @min(64, @max(blockWidth(b.size), blockHeight(b.size)));
            const max_tx = findTxSize(sz, sz);
            const sqr_up = tables.tx_size_sqr_up[txsz];
            const ctx = @as(u32, @intFromBool(sqr_up != max_tx)) * 3 + (common.TX_64X64 - @as(u32, max_tx)) * 6 + above + left;
            split = ps.sym(&ps.c.txfm_split[ctx]) == 1;
        }
        const w4: u32 = tables.tx_width[txsz] / 4;
        const h4: u32 = tables.tx_height[txsz] / 4;
        if (split) {
            const sub = tables.split_tx_size[txsz];
            const step_w: u32 = tables.tx_width[sub] / 4;
            const step_h: u32 = tables.tx_height[sub] / 4;
            var i: u32 = 0;
            while (i < h4) : (i += step_h) {
                var j: u32 = 0;
                while (j < w4) : (j += step_w) ps.readVarTxSize(row + i, col + j, sub, depth + 1);
            }
        } else {
            const rows = @min(h4, out.mi_rows - row);
            const cols = @min(w4, out.mi_cols - col);
            for (0..rows) |y| @memset(ps.inter_tx[(row + y) * out.mi_cols + col ..][0..cols], txsz);
            b.tx_size = txsz;
        }
    }

    fn interFrameModeInfo(ps: *Parse) Error!void {
        const b = &ps.b;
        const h = ps.h;
        const out = ps.out;
        b.intrabc = false;
        ps.left_ref = .{ common.INTRA_FRAME, common.NONE };
        ps.above_ref = .{ common.INTRA_FRAME, common.NONE };
        if (ps.avail_l) ps.left_ref = out.block(b.row, b.col - 1).ref;
        if (ps.avail_u) ps.above_ref = out.block(b.row - 1, b.col).ref;
        ps.left_intra = ps.left_ref[0] <= common.INTRA_FRAME;
        ps.above_intra = ps.above_ref[0] <= common.INTRA_FRAME;
        ps.left_single = ps.left_ref[1] <= common.INTRA_FRAME;
        ps.above_single = ps.above_ref[1] <= common.INTRA_FRAME;
        b.skip = false;
        ps.interSegmentId(true);
        ps.readSkipMode();
        if (b.skip_mode) b.skip = true else ps.readSkip();
        if (!h.seg_id_pre_skip) ps.interSegmentId(false);
        b.lossless = h.lossless[b.segment];
        ps.readCdef();
        ps.readDeltaQ();
        ps.readDeltaLf();
        ps.read_deltas = false;
        ps.readIsInter();
        if (b.is_inter) try ps.interBlockModeInfo() else try ps.intraBlockModeInfo();
    }

    fn interSegmentId(ps: *Parse, pre_skip: bool) void {
        const b = &ps.b;
        const h = ps.h;
        const out = ps.out;
        if (!h.segmentation_enabled) {
            b.segment = 0;
            return;
        }
        const predicted = ps.predictedSegmentId();
        if (!h.segmentation_update_map) {
            b.segment = predicted;
            return;
        }
        if (pre_skip and !h.seg_id_pre_skip) {
            b.segment = 0;
            return;
        }
        const bw4: u32 = tables.num_4x4_blocks_wide[b.size];
        const bh4: u32 = tables.num_4x4_blocks_high[b.size];
        if (!pre_skip and b.skip) {
            @memset(ps.above_segpred[b.col..][0..bw4], 0);
            @memset(ps.left_segpred[b.row..][0..bh4], 0);
            ps.readSegmentId();
            return;
        }
        if (h.segmentation_temporal_update) {
            const ctx: u32 = @as(u32, ps.left_segpred[b.row]) + ps.above_segpred[b.col];
            const pred = ps.sym(&ps.c.segment_id_predicted[ctx]);
            if (pred == 1) b.segment = predicted else ps.readSegmentId();
            @memset(ps.above_segpred[b.col..][0..bw4], @intCast(pred));
            @memset(ps.left_segpred[b.row..][0..bh4], @intCast(pred));
        } else {
            ps.readSegmentId();
        }
        _ = out;
    }

    fn predictedSegmentId(ps: *const Parse) u8 {
        const b = &ps.b;
        const out = ps.out;
        if (ps.prev_segs.len == 0) return 0;
        const xmis = @min(out.mi_cols - b.col, tables.num_4x4_blocks_wide[b.size]);
        const ymis = @min(out.mi_rows - b.row, tables.num_4x4_blocks_high[b.size]);
        var seg: u8 = 7;
        for (0..ymis) |y| {
            for (ps.prev_segs[(b.row + y) * out.mi_cols + b.col ..][0..xmis]) |s| seg = @min(seg, s);
        }
        return seg;
    }

    fn readIsInter(ps: *Parse) void {
        const b = &ps.b;
        const h = ps.h;
        if (b.skip_mode) {
            b.is_inter = true;
        } else if (h.featureActive(b.segment, common.SEG_LVL_REF_FRAME)) {
            b.is_inter = h.feature_data[b.segment][common.SEG_LVL_REF_FRAME] != common.INTRA_FRAME;
        } else if (h.featureActive(b.segment, common.SEG_LVL_GLOBALMV)) {
            b.is_inter = true;
        } else {
            var ctx: u32 = 0;
            if (ps.avail_u and ps.avail_l) {
                ctx = if (ps.left_intra and ps.above_intra) 3 else @intFromBool(ps.left_intra or ps.above_intra);
            } else if (ps.avail_u or ps.avail_l) {
                ctx = 2 * @as(u32, @intFromBool(if (ps.avail_u) ps.above_intra else ps.left_intra));
            }
            b.is_inter = ps.sym(&ps.c.is_inter[ctx]) == 1;
        }
    }

    fn intraBlockModeInfo(ps: *Parse) Error!void {
        const b = &ps.b;
        b.ref = .{ common.INTRA_FRAME, common.NONE };
        b.y_mode = @intCast(ps.sym(&ps.c.y_mode[tables.size_group[b.size]]));
        ps.intraAngleInfoY();
        if (b.has_chroma) {
            b.uv_mode = @intCast(ps.readUvMode());
            if (b.uv_mode == common.UV_CFL_PRED) ps.readCflAlphas();
            ps.intraAngleInfoUv();
        }
        b.pal_y = 0;
        b.pal_uv = 0;
        if (b.size >= common.BLOCK_8X8 and blockWidth(b.size) <= 64 and blockHeight(b.size) <= 64 and ps.h.allow_screen_content_tools) {
            try ps.paletteModeInfo();
        }
        ps.filterIntraModeInfo();
    }

    fn readUvMode(ps: *Parse) u32 {
        const b = &ps.b;
        const ss = tables.subsampled_size[b.size][ps.seq.ss_x][ps.seq.ss_y];
        const cfl_allowed = if (b.lossless and ss == common.BLOCK_4X4)
            true
        else if (!b.lossless and @max(blockWidth(b.size), blockHeight(b.size)) <= 32)
            true
        else
            false;
        if (cfl_allowed) return ps.sym(&ps.c.uv_mode_cfl_allowed[b.y_mode]);
        return ps.sym(&ps.c.uv_mode_cfl_not_allowed[b.y_mode]);
    }

    fn intraAngleInfoY(ps: *Parse) void {
        const b = &ps.b;
        b.angle_y = 0;
        if (b.size >= common.BLOCK_8X8 and isDirectional(b.y_mode)) {
            b.angle_y = @as(i8, @intCast(ps.sym(&ps.c.angle_delta[b.y_mode - common.V_PRED]))) - 3;
        }
    }

    fn intraAngleInfoUv(ps: *Parse) void {
        const b = &ps.b;
        b.angle_uv = 0;
        if (b.size >= common.BLOCK_8X8 and isDirectional(b.uv_mode)) {
            b.angle_uv = @as(i8, @intCast(ps.sym(&ps.c.angle_delta[b.uv_mode - common.V_PRED]))) - 3;
        }
    }

    fn readCflAlphas(ps: *Parse) void {
        const b = &ps.b;
        const signs = ps.sym(&ps.c.cfl_sign);
        const sign_u = (signs + 1) / 3;
        const sign_v = (signs + 1) % 3;
        b.cfl_u = 0;
        b.cfl_v = 0;
        if (sign_u != 0) {
            const a: i8 = @intCast(1 + ps.sym(&ps.c.cfl_alpha[(sign_u - 1) * 3 + sign_v]));
            b.cfl_u = if (sign_u == 1) -a else a;
        }
        if (sign_v != 0) {
            const a: i8 = @intCast(1 + ps.sym(&ps.c.cfl_alpha[(sign_v - 1) * 3 + sign_u]));
            b.cfl_v = if (sign_v == 1) -a else a;
        }
    }

    fn filterIntraModeInfo(ps: *Parse) void {
        const b = &ps.b;
        b.filter_intra = false;
        if (ps.seq.enable_filter_intra and b.y_mode == common.DC_PRED and b.pal_y == 0 and
            @max(blockWidth(b.size), blockHeight(b.size)) <= 32)
        {
            b.filter_intra = ps.sym(&ps.c.filter_intra[b.size]) == 1;
            if (b.filter_intra) b.filter_mode = @intCast(ps.sym(&ps.c.filter_intra_mode));
        }
    }

    fn paletteModeInfo(ps: *Parse) Error!void {
        const b = &ps.b;
        const out = ps.out;
        const bd: u32 = ps.seq.bit_depth;
        const bsize_ctx = @as(u32, tables.mi_width_log2[b.size]) + tables.mi_height_log2[b.size] - 2;
        if (b.y_mode == common.DC_PRED) {
            var ctx: u32 = 0;
            if (ps.avail_u and out.block(b.row - 1, b.col).pal_y > 0) ctx += 1;
            if (ps.avail_l and out.block(b.row, b.col - 1).pal_y > 0) ctx += 1;
            if (ps.sym(&ps.c.palette_y_mode[bsize_ctx][ctx]) == 1) {
                b.pal_y = @intCast(ps.sym(&ps.c.palette_y_size[bsize_ctx]) + 2);
                var cache: [16]u16 = undefined;
                const n = ps.paletteCache(0, &cache);
                const colors = &ps.pal_colors[0];
                var idx: u32 = 0;
                var i: u32 = 0;
                while (i < n and idx < b.pal_y) : (i += 1) {
                    if (ps.lit(1) == 1) {
                        colors[idx] = cache[i];
                        idx += 1;
                    }
                }
                if (idx < b.pal_y) {
                    colors[idx] = @intCast(ps.lit(bd));
                    idx += 1;
                }
                var bits: u32 = 0;
                if (idx < b.pal_y) bits = bd - 3 + ps.lit(2);
                while (idx < b.pal_y) : (idx += 1) {
                    const delta = ps.lit(bits) + 1;
                    colors[idx] = @intCast(@min(colors[idx - 1] + delta, (@as(u32, 1) << @intCast(bd)) - 1));
                    const range = (@as(u32, 1) << @intCast(bd)) - colors[idx] - 1;
                    bits = @min(bits, common.ceilLog2(range));
                }
                sortColors(colors[0..b.pal_y]);
            }
        }
        if (b.has_chroma and b.uv_mode == common.DC_PRED) {
            const ctx: u32 = @intFromBool(b.pal_y > 0);
            if (ps.sym(&ps.c.palette_uv_mode[ctx]) == 1) {
                b.pal_uv = @intCast(ps.sym(&ps.c.palette_uv_size[bsize_ctx]) + 2);
                var cache: [16]u16 = undefined;
                const n = ps.paletteCache(1, &cache);
                const u = &ps.pal_colors[1];
                var idx: u32 = 0;
                var i: u32 = 0;
                while (i < n and idx < b.pal_uv) : (i += 1) {
                    if (ps.lit(1) == 1) {
                        u[idx] = cache[i];
                        idx += 1;
                    }
                }
                if (idx < b.pal_uv) {
                    u[idx] = @intCast(ps.lit(bd));
                    idx += 1;
                }
                var bits: u32 = 0;
                if (idx < b.pal_uv) bits = bd - 3 + ps.lit(2);
                while (idx < b.pal_uv) : (idx += 1) {
                    const delta = ps.lit(bits);
                    u[idx] = @intCast(@min(u[idx - 1] + delta, (@as(u32, 1) << @intCast(bd)) - 1));
                    const range = (@as(u32, 1) << @intCast(bd)) - u[idx];
                    bits = @min(bits, common.ceilLog2(range));
                }
                sortColors(u[0..b.pal_uv]);

                const v = &ps.pal_colors[2];
                if (ps.lit(1) == 1) {
                    const max_val: i32 = @as(i32, 1) << @intCast(bd);
                    const vbits = bd - 4 + ps.lit(2);
                    v[0] = @intCast(ps.lit(bd));
                    for (1..b.pal_uv) |k| {
                        var delta: i32 = @intCast(ps.lit(vbits));
                        if (delta != 0 and ps.lit(1) == 1) delta = -delta;
                        var val: i32 = @as(i32, v[k - 1]) + delta;
                        if (val < 0) val += max_val;
                        if (val >= max_val) val -= max_val;
                        v[k] = @intCast(common.clip3(0, max_val - 1, val));
                    }
                } else {
                    for (0..b.pal_uv) |k| v[k] = @intCast(ps.lit(bd));
                }
            }
        }
    }

    fn paletteCache(ps: *const Parse, plane: u32, cache: *[16]u16) u32 {
        const b = &ps.b;
        const out = ps.out;
        var above_n: u32 = 0;
        var above_c: []const u16 = &.{};
        if ((b.row * 4) % 64 != 0 and ps.avail_u) {
            const a = out.block(b.row - 1, b.col);
            above_n = if (plane == 0) a.pal_y else a.pal_uv;
            if (above_n > 0) above_c = out.colors[a.pal + 8 * plane ..][0..8];
        }
        var left_n: u32 = 0;
        var left_c: []const u16 = &.{};
        if (ps.avail_l) {
            const l = out.block(b.row, b.col - 1);
            left_n = if (plane == 0) l.pal_y else l.pal_uv;
            if (left_n > 0) left_c = out.colors[l.pal + 8 * plane ..][0..8];
        }
        var ai: u32 = 0;
        var li: u32 = 0;
        var n: u32 = 0;
        while (ai < above_n and li < left_n) {
            const ac = above_c[ai];
            const lc = left_c[li];
            if (lc < ac) {
                if (n == 0 or lc != cache[n - 1]) {
                    cache[n] = lc;
                    n += 1;
                }
                li += 1;
            } else {
                if (n == 0 or ac != cache[n - 1]) {
                    cache[n] = ac;
                    n += 1;
                }
                ai += 1;
                if (lc == ac) li += 1;
            }
        }
        while (ai < above_n) : (ai += 1) {
            const val = above_c[ai];
            if (n == 0 or val != cache[n - 1]) {
                cache[n] = val;
                n += 1;
            }
        }
        while (li < left_n) : (li += 1) {
            const val = left_c[li];
            if (n == 0 or val != cache[n - 1]) {
                cache[n] = val;
                n += 1;
            }
        }
        return n;
    }

    fn paletteTokens(ps: *Parse) Error!void {
        const b = &ps.b;
        const out = ps.out;
        if (b.pal_y == 0 and b.pal_uv == 0) return;
        // The colours, and room for the maps.
        if (out.ncolors + 24 > out.colors.len) {
            if (!ps.env.grow(u16, &out.colors, out.ncolors + 24)) return error.NoMemory;
        }
        b.pal = out.ncolors;
        out.ncolors += 24;
        for (0..3) |p| @memcpy(out.colors[b.pal + 8 * p ..][0..8], &ps.pal_colors[p]);

        var block_h = blockHeight(b.size);
        var block_w = blockWidth(b.size);
        var on_h = @min(block_h, (out.mi_rows - b.row) * 4);
        var on_w = @min(block_w, (out.mi_cols - b.col) * 4);
        if (b.pal_y > 0) {
            const m = &ps.color_map_y;
            try ps.colorMap(m, block_w, block_h, on_w, on_h, b.pal_y, 0);
            b.map = try ps.keepMap(m[0 .. block_w * block_h]);
        }
        if (b.pal_uv > 0) {
            const m = &ps.color_map_uv;
            block_h >>= ps.seq.ss_y;
            block_w >>= ps.seq.ss_x;
            on_h >>= ps.seq.ss_y;
            on_w >>= ps.seq.ss_x;
            if (block_w < 4) {
                block_w += 2;
                on_w += 2;
            }
            if (block_h < 4) {
                block_h += 2;
                on_h += 2;
            }
            try ps.colorMap(m, block_w, block_h, on_w, on_h, b.pal_uv, 1);
            b.map_uv = try ps.keepMap(m[0 .. block_w * block_h]);
        }
    }

    fn keepMap(ps: *Parse, m: []const u8) Error!u32 {
        const out = ps.out;
        if (out.nmaps + m.len > out.maps.len) {
            if (!ps.env.grow(u8, &out.maps, out.nmaps + m.len)) return error.NoMemory;
        }
        const at = out.nmaps;
        @memcpy(out.maps[at..][0..m.len], m);
        out.nmaps += @intCast(m.len);
        return at;
    }

    /// A colour map of `w` by `h` (on the screen `on_w` by `on_h`), at
    /// the stride `w`.
    fn colorMap(ps: *Parse, m: *[64 * 64]u8, w: u32, h: u32, on_w: u32, on_h: u32, n: u32, plane: u32) Error!void {
        m[0] = @intCast(ps.nsBool(n));
        var i: u32 = 1;
        while (i < on_h + on_w - 1) : (i += 1) {
            var j: i32 = @intCast(@min(i, on_w - 1));
            const lo: i32 = @max(0, @as(i32, @intCast(i)) - @as(i32, @intCast(on_h)) + 1);
            while (j >= lo) : (j -= 1) {
                const r: u32 = i - @as(u32, @intCast(j));
                const c: u32 = @intCast(j);
                var order: [8]u8 = undefined;
                const ctx = colorContext(m, w, r, c, n, &order);
                const idx = if (plane == 0) ps.paletteColorY(n, ctx) else ps.paletteColorUv(n, ctx);
                m[r * w + c] = order[idx];
            }
        }
        for (0..on_h) |y| {
            for (on_w..w) |x| m[y * w + x] = m[y * w + on_w - 1];
        }
        for (on_h..h) |y| @memcpy(m[y * w ..][0..w], m[(on_h - 1) * w ..][0..w]);
    }

    fn paletteColorY(ps: *Parse, n: u32, ctx: u32) u32 {
        return switch (n) {
            2 => ps.sym(&ps.c.palette_size_2_y_color[ctx]),
            3 => ps.sym(&ps.c.palette_size_3_y_color[ctx]),
            4 => ps.sym(&ps.c.palette_size_4_y_color[ctx]),
            5 => ps.sym(&ps.c.palette_size_5_y_color[ctx]),
            6 => ps.sym(&ps.c.palette_size_6_y_color[ctx]),
            7 => ps.sym(&ps.c.palette_size_7_y_color[ctx]),
            else => ps.sym(&ps.c.palette_size_8_y_color[ctx]),
        };
    }

    fn paletteColorUv(ps: *Parse, n: u32, ctx: u32) u32 {
        return switch (n) {
            2 => ps.sym(&ps.c.palette_size_2_uv_color[ctx]),
            3 => ps.sym(&ps.c.palette_size_3_uv_color[ctx]),
            4 => ps.sym(&ps.c.palette_size_4_uv_color[ctx]),
            5 => ps.sym(&ps.c.palette_size_5_uv_color[ctx]),
            6 => ps.sym(&ps.c.palette_size_6_uv_color[ctx]),
            7 => ps.sym(&ps.c.palette_size_7_uv_color[ctx]),
            else => ps.sym(&ps.c.palette_size_8_uv_color[ctx]),
        };
    }

    // --- inter blocks ---

    fn interBlockModeInfo(ps: *Parse) Error!void {
        const b = &ps.b;
        const h = ps.h;
        const seq = ps.seq;
        b.pal_y = 0;
        b.pal_uv = 0;
        ps.readRefFrames();
        const compound = b.ref[1] > common.INTRA_FRAME;
        mvpred.findMvStack(ps, compound);
        const st = &ps.mv;
        if (b.skip_mode) {
            b.y_mode = common.NEAREST_NEARESTMV;
        } else if (h.featureActive(b.segment, common.SEG_LVL_SKIP) or h.featureActive(b.segment, common.SEG_LVL_GLOBALMV)) {
            b.y_mode = common.GLOBALMV;
        } else if (compound) {
            const ctx = tables.compound_mode_ctx_map[st.ref_mv_ctx >> 1][@min(st.new_mv_ctx, 4)];
            b.y_mode = @intCast(common.NEAREST_NEARESTMV + ps.sym(&ps.c.compound_mode[ctx]));
        } else {
            if (ps.sym(&ps.c.new_mv[st.new_mv_ctx]) == 0) {
                b.y_mode = common.NEWMV;
            } else if (ps.sym(&ps.c.zero_mv[st.zero_mv_ctx]) == 0) {
                b.y_mode = common.GLOBALMV;
            } else {
                b.y_mode = if (ps.sym(&ps.c.ref_mv[st.ref_mv_ctx]) == 0) common.NEARESTMV else common.NEARMV;
            }
        }
        st.ref_mv_idx = 0;
        if (b.y_mode == common.NEWMV or b.y_mode == common.NEW_NEWMV) {
            var idx: u32 = 0;
            while (idx < 2) : (idx += 1) {
                if (st.num_found > idx + 1) {
                    if (ps.sym(&ps.c.drl_mode[st.drl_ctx[idx]]) == 0) {
                        st.ref_mv_idx = idx;
                        break;
                    }
                    st.ref_mv_idx = idx + 1;
                }
            }
        } else if (hasNearMv(b.y_mode)) {
            st.ref_mv_idx = 1;
            var idx: u32 = 1;
            while (idx < 3) : (idx += 1) {
                if (st.num_found > idx + 1) {
                    if (ps.sym(&ps.c.drl_mode[st.drl_ctx[idx]]) == 0) {
                        st.ref_mv_idx = idx;
                        break;
                    }
                    st.ref_mv_idx = idx + 1;
                }
            }
        }
        try ps.assignMv(compound);
        ps.readInterIntraMode(compound);
        try ps.readMotionMode(compound);
        ps.readCompoundType(compound);
        if (h.interpolation_filter == common.SWITCHABLE) {
            const dirs: u32 = if (seq.enable_dual_filter) 2 else 1;
            for (0..dirs) |dir| {
                if (ps.needsInterpFilter()) {
                    b.filter[dir] = @intCast(ps.sym(&ps.c.interp_filter[ps.interpFilterCtx(@intCast(dir))]));
                } else {
                    b.filter[dir] = common.EIGHTTAP;
                }
            }
            if (!seq.enable_dual_filter) b.filter[1] = b.filter[0];
        } else {
            b.filter = .{ h.interpolation_filter, h.interpolation_filter };
        }
    }

    fn needsInterpFilter(ps: *const Parse) bool {
        const b = &ps.b;
        const h = ps.h;
        const large = @min(blockWidth(b.size), blockHeight(b.size)) >= 8;
        if (b.skip_mode or b.motion_mode == common.LOCALWARP) return false;
        if (large and b.y_mode == common.GLOBALMV) return h.gm_type[@intCast(b.ref[0])] == common.TRANSLATION;
        if (large and b.y_mode == common.GLOBAL_GLOBALMV) {
            return h.gm_type[@intCast(b.ref[0])] == common.TRANSLATION or h.gm_type[@intCast(b.ref[1])] == common.TRANSLATION;
        }
        return true;
    }

    fn interpFilterCtx(ps: *const Parse, dir: u32) u32 {
        const b = &ps.b;
        const out = ps.out;
        var ctx: u32 = ((dir & 1) * 2 + @as(u32, @intFromBool(b.ref[1] > common.INTRA_FRAME))) * 4;
        var left_type: u32 = 3;
        var above_type: u32 = 3;
        if (ps.avail_l) {
            const l = out.block(b.row, b.col - 1);
            if (l.ref[0] == b.ref[0] or l.ref[1] == b.ref[0]) left_type = l.filter[dir];
        }
        if (ps.avail_u) {
            const a = out.block(b.row - 1, b.col);
            if (a.ref[0] == b.ref[0] or a.ref[1] == b.ref[0]) above_type = a.filter[dir];
        }
        if (left_type == above_type) {
            ctx += left_type;
        } else if (left_type == 3) {
            ctx += above_type;
        } else if (above_type == 3) {
            ctx += left_type;
        } else {
            ctx += 3;
        }
        return ctx;
    }

    fn countRefs(ps: *const Parse, frame_type: i8) u32 {
        var n: u32 = 0;
        if (ps.avail_u) {
            if (ps.above_ref[0] == frame_type) n += 1;
            if (ps.above_ref[1] == frame_type) n += 1;
        }
        if (ps.avail_l) {
            if (ps.left_ref[0] == frame_type) n += 1;
            if (ps.left_ref[1] == frame_type) n += 1;
        }
        return n;
    }

    fn refCountCtx(a: u32, b: u32) u32 {
        return if (a < b) 0 else if (a == b) 1 else 2;
    }

    fn ctxCompRef(ps: *const Parse) u32 {
        return refCountCtx(ps.countRefs(common.LAST_FRAME) + ps.countRefs(common.LAST2_FRAME), ps.countRefs(common.LAST3_FRAME) + ps.countRefs(common.GOLDEN_FRAME));
    }
    fn ctxCompRefP1(ps: *const Parse) u32 {
        return refCountCtx(ps.countRefs(common.LAST_FRAME), ps.countRefs(common.LAST2_FRAME));
    }
    fn ctxCompRefP2(ps: *const Parse) u32 {
        return refCountCtx(ps.countRefs(common.LAST3_FRAME), ps.countRefs(common.GOLDEN_FRAME));
    }
    fn ctxCompBwdref(ps: *const Parse) u32 {
        return refCountCtx(ps.countRefs(common.BWDREF_FRAME) + ps.countRefs(common.ALTREF2_FRAME), ps.countRefs(common.ALTREF_FRAME));
    }
    fn ctxCompBwdrefP1(ps: *const Parse) u32 {
        return refCountCtx(ps.countRefs(common.BWDREF_FRAME), ps.countRefs(common.ALTREF2_FRAME));
    }
    fn ctxSingleRefP1(ps: *const Parse) u32 {
        const fwd = ps.countRefs(common.LAST_FRAME) + ps.countRefs(common.LAST2_FRAME) + ps.countRefs(common.LAST3_FRAME) + ps.countRefs(common.GOLDEN_FRAME);
        const bwd = ps.countRefs(common.BWDREF_FRAME) + ps.countRefs(common.ALTREF2_FRAME) + ps.countRefs(common.ALTREF_FRAME);
        return refCountCtx(fwd, bwd);
    }
    fn ctxUniCompRefP1(ps: *const Parse) u32 {
        return refCountCtx(ps.countRefs(common.LAST2_FRAME), ps.countRefs(common.LAST3_FRAME) + ps.countRefs(common.GOLDEN_FRAME));
    }

    fn ctxCompMode(ps: *const Parse) u32 {
        if (ps.avail_u and ps.avail_l) {
            if (ps.above_single and ps.left_single) {
                return @as(u32, @intFromBool(checkBackward(ps.above_ref[0]))) ^ @intFromBool(checkBackward(ps.left_ref[0]));
            } else if (ps.above_single) {
                return 2 + @as(u32, @intFromBool(checkBackward(ps.above_ref[0]) or ps.above_intra));
            } else if (ps.left_single) {
                return 2 + @as(u32, @intFromBool(checkBackward(ps.left_ref[0]) or ps.left_intra));
            }
            return 4;
        } else if (ps.avail_u) {
            return if (ps.above_single) @intFromBool(checkBackward(ps.above_ref[0])) else 3;
        } else if (ps.avail_l) {
            return if (ps.left_single) @intFromBool(checkBackward(ps.left_ref[0])) else 3;
        }
        return 1;
    }

    fn ctxCompRefType(ps: *const Parse) u32 {
        const above0 = ps.above_ref[0];
        const above1 = ps.above_ref[1];
        const left0 = ps.left_ref[0];
        const left1 = ps.left_ref[1];
        const above_comp = ps.avail_u and !ps.above_intra and !ps.above_single;
        const left_comp = ps.avail_l and !ps.left_intra and !ps.left_single;
        const above_uni = above_comp and sameDir(above0, above1);
        const left_uni = left_comp and sameDir(left0, left1);
        if (ps.avail_u and !ps.above_intra and ps.avail_l and !ps.left_intra) {
            const samedir: u32 = @intFromBool(sameDir(above0, left0));
            if (!above_comp and !left_comp) return 1 + 2 * samedir;
            if (!above_comp) return if (!left_uni) 1 else 3 + samedir;
            if (!left_comp) return if (!above_uni) 1 else 3 + samedir;
            if (!above_uni and !left_uni) return 0;
            if (!above_uni or !left_uni) return 2;
            return 3 + @as(u32, @intFromBool((above0 == common.BWDREF_FRAME) == (left0 == common.BWDREF_FRAME)));
        } else if (ps.avail_u and ps.avail_l) {
            if (above_comp) return 1 + 2 * @as(u32, @intFromBool(above_uni));
            if (left_comp) return 1 + 2 * @as(u32, @intFromBool(left_uni));
            return 2;
        } else if (above_comp) {
            return 4 * @as(u32, @intFromBool(above_uni));
        } else if (left_comp) {
            return 4 * @as(u32, @intFromBool(left_uni));
        }
        return 2;
    }

    fn readRefFrames(ps: *Parse) void {
        const b = &ps.b;
        const h = ps.h;
        if (b.skip_mode) {
            b.ref = h.skip_mode_frame;
            return;
        }
        if (h.featureActive(b.segment, common.SEG_LVL_REF_FRAME)) {
            b.ref = .{ @intCast(h.feature_data[b.segment][common.SEG_LVL_REF_FRAME]), common.NONE };
            return;
        }
        if (h.featureActive(b.segment, common.SEG_LVL_SKIP) or h.featureActive(b.segment, common.SEG_LVL_GLOBALMV)) {
            b.ref = .{ common.LAST_FRAME, common.NONE };
            return;
        }
        const bw4 = tables.num_4x4_blocks_wide[b.size];
        const bh4 = tables.num_4x4_blocks_high[b.size];
        var compound = false;
        if (h.reference_select and @min(bw4, bh4) >= 2) compound = ps.sym(&ps.c.comp_mode[ps.ctxCompMode()]) == 1;
        if (compound) {
            const uni = ps.sym(&ps.c.comp_ref_type[ps.ctxCompRefType()]) == 0;
            if (uni) {
                if (ps.sym(&ps.c.uni_comp_ref[ps.ctxSingleRefP1()][0]) == 1) {
                    b.ref = .{ common.BWDREF_FRAME, common.ALTREF_FRAME };
                } else if (ps.sym(&ps.c.uni_comp_ref[ps.ctxUniCompRefP1()][1]) == 1) {
                    if (ps.sym(&ps.c.uni_comp_ref[ps.ctxCompRefP2()][2]) == 1) {
                        b.ref = .{ common.LAST_FRAME, common.GOLDEN_FRAME };
                    } else {
                        b.ref = .{ common.LAST_FRAME, common.LAST3_FRAME };
                    }
                } else {
                    b.ref = .{ common.LAST_FRAME, common.LAST2_FRAME };
                }
            } else {
                if (ps.sym(&ps.c.comp_ref[ps.ctxCompRef()][0]) == 0) {
                    b.ref[0] = if (ps.sym(&ps.c.comp_ref[ps.ctxCompRefP1()][1]) == 1) common.LAST2_FRAME else common.LAST_FRAME;
                } else {
                    b.ref[0] = if (ps.sym(&ps.c.comp_ref[ps.ctxCompRefP2()][2]) == 1) common.GOLDEN_FRAME else common.LAST3_FRAME;
                }
                if (ps.sym(&ps.c.comp_bwd_ref[ps.ctxCompBwdref()][0]) == 0) {
                    b.ref[1] = if (ps.sym(&ps.c.comp_bwd_ref[ps.ctxCompBwdrefP1()][1]) == 1) common.ALTREF2_FRAME else common.BWDREF_FRAME;
                } else {
                    b.ref[1] = common.ALTREF_FRAME;
                }
            }
        } else {
            if (ps.sym(&ps.c.single_ref[ps.ctxSingleRefP1()][0]) == 1) {
                if (ps.sym(&ps.c.single_ref[ps.ctxCompBwdref()][1]) == 0) {
                    b.ref[0] = if (ps.sym(&ps.c.single_ref[ps.ctxCompBwdrefP1()][5]) == 1) common.ALTREF2_FRAME else common.BWDREF_FRAME;
                } else {
                    b.ref[0] = common.ALTREF_FRAME;
                }
            } else {
                if (ps.sym(&ps.c.single_ref[ps.ctxCompRef()][2]) == 1) {
                    b.ref[0] = if (ps.sym(&ps.c.single_ref[ps.ctxCompRefP2()][4]) == 1) common.GOLDEN_FRAME else common.LAST3_FRAME;
                } else {
                    b.ref[0] = if (ps.sym(&ps.c.single_ref[ps.ctxCompRefP1()][3]) == 1) common.LAST2_FRAME else common.LAST_FRAME;
                }
            }
            b.ref[1] = common.NONE;
        }
    }

    fn assignMv(ps: *Parse, compound: bool) Error!void {
        const b = &ps.b;
        const st = &ps.mv;
        var pred: [2]Mv = .{ .{}, .{} };
        for (0..@as(usize, 1) + @intFromBool(compound)) |i| {
            const comp_mode: u8 = if (b.intrabc) common.NEWMV else getMode(b.y_mode, i);
            if (b.intrabc) {
                pred[0] = st.stack[0][0];
                if (pred[0].row == 0 and pred[0].col == 0) pred[0] = st.stack[1][0];
                if (pred[0].row == 0 and pred[0].col == 0) {
                    const sb4: i32 = @intCast(ps.sb_size4);
                    if (@as(i32, @intCast(b.row)) - sb4 < @as(i32, @intCast(ps.row_start))) {
                        pred[0] = .{ .row = 0, .col = @intCast(-(sb4 * 4 + 256) * 8) };
                    } else {
                        pred[0] = .{ .row = @intCast(-(sb4 * 4 * 8)), .col = 0 };
                    }
                }
            } else if (comp_mode == common.GLOBALMV) {
                pred[i] = st.global[i];
            } else {
                var pos: u32 = if (comp_mode == common.NEARESTMV) 0 else st.ref_mv_idx;
                if (comp_mode == common.NEWMV and st.num_found <= 1) pos = 0;
                pred[i] = st.stack[pos][i];
            }
            if (comp_mode == common.NEWMV) {
                b.mv[i] = try ps.readMv(pred[i]);
            } else {
                b.mv[i] = pred[i];
            }
        }
        if (b.intrabc) try ps.checkIntrabc();
    }

    /// An intra block copy's vector must point at what is decoded, in
    /// whole samples, inside the tile and far enough back (6.10.25).
    fn checkIntrabc(ps: *const Parse) Error!void {
        const m = ps.b.mv[0];
        if ((m.row & 7) != 0 or (m.col & 7) != 0) return error.Corrupt;
    }

    fn readMv(ps: *Parse, pred: Mv) Error!Mv {
        const b = &ps.b;
        const ctx: usize = if (b.intrabc) 1 else 0;
        var diff: [2]i32 = .{ 0, 0 };
        const joint = ps.sym(&ps.c.mv[ctx].joint);
        if (joint == 2 or joint == 3) diff[0] = ps.readMvComponent(ctx, 0);
        if (joint == 1 or joint == 3) diff[1] = ps.readMvComponent(ctx, 1);
        const row = @as(i32, pred.row) + diff[0];
        const col = @as(i32, pred.col) + diff[1];
        if (row < -(1 << 14) or row >= (1 << 14) or col < -(1 << 14) or col >= (1 << 14)) return error.Corrupt;
        return .{ .row = @intCast(row), .col = @intCast(col) };
    }

    fn readMvComponent(ps: *Parse, ctx: usize, comp: usize) i32 {
        const h = ps.h;
        const m = &ps.c.mv[ctx];
        const sign = ps.sym(&m.sign[comp]);
        const class = ps.sym(&m.class[comp]);
        var mag: u32 = 0;
        if (class == 0) {
            const c0 = ps.sym(&m.class0_bit[comp]);
            const fr: u32 = if (h.force_integer_mv) 3 else ps.sym(&m.class0_fr[comp][c0]);
            const hp: u32 = if (h.allow_high_precision_mv) ps.sym(&m.class0_hp[comp]) else 1;
            mag = ((c0 << 3) | (fr << 1) | hp) + 1;
        } else {
            var d: u32 = 0;
            for (0..class) |i| d |= ps.sym(&m.bit[comp][i]) << @intCast(i);
            mag = @as(u32, 2) << @intCast(class + 2);
            const fr: u32 = if (h.force_integer_mv) 3 else ps.sym(&m.fr[comp]);
            const hp: u32 = if (h.allow_high_precision_mv) ps.sym(&m.hp[comp]) else 1;
            mag += ((d << 3) | (fr << 1) | hp) + 1;
        }
        const v: i32 = @intCast(mag);
        return if (sign == 1) -v else v;
    }

    fn readInterIntraMode(ps: *Parse, compound: bool) void {
        const b = &ps.b;
        if (!b.skip_mode and ps.seq.enable_interintra_compound and !compound and b.size >= common.BLOCK_8X8 and b.size <= common.BLOCK_32X32) {
            const ctx = tables.size_group[b.size] - 1;
            b.interintra = ps.sym(&ps.c.inter_intra[ctx]) == 1;
            if (b.interintra) {
                b.ii_mode = @intCast(ps.sym(&ps.c.inter_intra_mode[ctx]));
                b.ref[1] = common.INTRA_FRAME;
                b.angle_y = 0;
                b.angle_uv = 0;
                b.filter_intra = false;
                b.wedge_interintra = ps.sym(&ps.c.wedge_inter_intra[b.size]) == 1;
                if (b.wedge_interintra) {
                    b.wedge_index = @intCast(ps.sym(&ps.c.wedge_index[b.size]));
                    b.wedge_sign = 0;
                }
            }
        } else {
            b.interintra = false;
        }
    }

    fn isScaled(ps: *const Parse, ref: i8) bool {
        const h = ps.h;
        const ri = &ps.refs[h.ref_frame_idx[@intCast(ref - common.LAST_FRAME)]];
        const xs = ((ri.upscaled_width << 14) + (h.frame_width / 2)) / h.frame_width;
        const ys = ((ri.frame_height << 14) + (h.frame_height / 2)) / h.frame_height;
        return xs != (1 << 14) or ys != (1 << 14);
    }

    fn readMotionMode(ps: *Parse, compound: bool) Error!void {
        const b = &ps.b;
        const h = ps.h;
        b.motion_mode = common.SIMPLE;
        if (b.skip_mode or !h.is_motion_mode_switchable) return;
        if (@min(blockWidth(b.size), blockHeight(b.size)) < 8) return;
        if (!h.force_integer_mv and (b.y_mode == common.GLOBALMV or b.y_mode == common.GLOBAL_GLOBALMV)) {
            if (h.gm_type[@intCast(b.ref[0])] > common.TRANSLATION) return;
        }
        if (compound or b.ref[1] == common.INTRA_FRAME or !mvpred.hasOverlappableCandidates(ps)) return;
        mvpred.findWarpSamples(ps);
        if (h.force_integer_mv or ps.mv.num_samples == 0 or !h.allow_warped_motion or ps.isScaled(b.ref[0])) {
            b.motion_mode = if (ps.sym(&ps.c.use_obmc[b.size]) == 1) common.OBMC else common.SIMPLE;
        } else {
            b.motion_mode = @intCast(ps.sym(&ps.c.motion_mode[b.size]));
        }
        if (b.motion_mode == common.LOCALWARP) {
            var w: Warp = .{};
            if (mvpred.warpEstimation(ps, &w.params)) {
                const out = ps.out;
                if (out.nwarps >= out.warps.len) {
                    if (!ps.env.grow(Warp, &out.warps, out.nwarps + 1)) return error.NoMemory;
                }
                out.warps[out.nwarps] = w;
                b.warp = out.nwarps;
                out.nwarps += 1;
            }
        }
    }

    fn readCompoundType(ps: *Parse, compound: bool) void {
        const b = &ps.b;
        const seq = ps.seq;
        const out = ps.out;
        b.comp_group_idx = 0;
        b.compound_idx = 1;
        if (b.skip_mode) {
            b.compound_type = common.COMPOUND_AVERAGE;
            return;
        }
        if (compound) {
            const n = tables.wedge_bits[b.size];
            if (seq.enable_masked_compound) {
                var ctx: u32 = 0;
                if (ps.avail_u) {
                    if (!ps.above_single) {
                        ctx += out.block(b.row - 1, b.col).comp_group_idx;
                    } else if (ps.above_ref[0] == common.ALTREF_FRAME) {
                        ctx += 3;
                    }
                }
                if (ps.avail_l) {
                    if (!ps.left_single) {
                        ctx += out.block(b.row, b.col - 1).comp_group_idx;
                    } else if (ps.left_ref[0] == common.ALTREF_FRAME) {
                        ctx += 3;
                    }
                }
                b.comp_group_idx = @intCast(ps.sym(&ps.c.comp_group_idx[@min(5, ctx)]));
            }
            if (b.comp_group_idx == 0) {
                if (seq.enable_jnt_comp) {
                    const fwd = @abs(seq.dist(ps.h.order_hints[@intCast(b.ref[0])], ps.h.order_hint));
                    const bck = @abs(seq.dist(ps.h.order_hints[@intCast(b.ref[1])], ps.h.order_hint));
                    var ctx: u32 = if (fwd == bck) 3 else 0;
                    if (ps.avail_u) {
                        if (!ps.above_single) {
                            ctx += out.block(b.row - 1, b.col).compound_idx;
                        } else if (ps.above_ref[0] == common.ALTREF_FRAME) {
                            ctx += 1;
                        }
                    }
                    if (ps.avail_l) {
                        if (!ps.left_single) {
                            ctx += out.block(b.row, b.col - 1).compound_idx;
                        } else if (ps.left_ref[0] == common.ALTREF_FRAME) {
                            ctx += 1;
                        }
                    }
                    b.compound_idx = @intCast(ps.sym(&ps.c.compound_idx[ctx]));
                    b.compound_type = if (b.compound_idx == 1) common.COMPOUND_AVERAGE else common.COMPOUND_DISTANCE;
                } else {
                    b.compound_type = common.COMPOUND_AVERAGE;
                }
            } else {
                if (n == 0) {
                    b.compound_type = common.COMPOUND_DIFFWTD;
                } else {
                    b.compound_type = @intCast(ps.sym(&ps.c.compound_type[b.size]));
                }
            }
            if (b.compound_type == common.COMPOUND_WEDGE) {
                b.wedge_index = @intCast(ps.sym(&ps.c.wedge_index[b.size]));
                b.wedge_sign = @intCast(ps.lit(1));
            } else if (b.compound_type == common.COMPOUND_DIFFWTD) {
                b.mask_type = @intCast(ps.lit(1));
            }
        } else {
            if (b.interintra) {
                b.compound_type = if (b.wedge_interintra) common.COMPOUND_WEDGE else common.COMPOUND_INTRA;
            } else {
                b.compound_type = common.COMPOUND_AVERAGE;
            }
        }
    }

    // --- the residual (5.11.34 to 5.11.39) ---

    fn residual(ps: *Parse) Error!void {
        const b = &ps.b;
        const seq = ps.seq;
        const width_chunks = @max(1, blockWidth(b.size) >> 6);
        const height_chunks = @max(1, blockHeight(b.size) >> 6);
        const size_chunk: u8 = if (width_chunks > 1 or height_chunks > 1) common.BLOCK_64X64 else b.size;
        const planes: u32 = if (b.has_chroma) 3 else 1;
        for (0..height_chunks) |cy| {
            for (0..width_chunks) |cx| {
                const row_chunk = b.row + @as(u32, @intCast(cy << 4));
                const col_chunk = b.col + @as(u32, @intCast(cx << 4));
                for (0..planes) |pu| {
                    const p: u32 = @intCast(pu);
                    const txsz = if (b.lossless) common.TX_4X4 else ps.getTxSize(p, b.tx_size);
                    const step_x: u32 = tables.tx_width[txsz] >> 2;
                    const step_y: u32 = tables.tx_height[txsz] >> 2;
                    const ssx: u5 = if (p > 0) seq.ss_x else 0;
                    const ssy: u5 = if (p > 0) seq.ss_y else 0;
                    const psz = tables.subsampled_size[size_chunk][ssx][ssy];
                    const n4w: u32 = tables.num_4x4_blocks_wide[psz];
                    const n4h: u32 = tables.num_4x4_blocks_high[psz];
                    if (b.is_inter and !b.lossless and p == 0) {
                        try ps.transformTree((col_chunk >> ssx) * 4, (row_chunk >> ssy) * 4, n4w * 4, n4h * 4);
                    } else {
                        const base_x = (b.col >> ssx) * 4;
                        const base_y = (b.row >> ssy) * 4;
                        var y: u32 = 0;
                        while (y < n4h) : (y += step_y) {
                            var x: u32 = 0;
                            while (x < n4w) : (x += step_x) {
                                try ps.transformBlock(p, base_x, base_y, txsz, x + @as(u32, @intCast((cx << 4) >> ssx)), y + @as(u32, @intCast((cy << 4) >> ssy)));
                            }
                        }
                    }
                }
            }
        }
    }

    fn getTxSize(ps: *const Parse, plane: u32, txsz: u8) u8 {
        if (plane == 0) return txsz;
        const uv = tables.max_tx_size_rect[tables.subsampled_size[ps.b.size][ps.seq.ss_x][ps.seq.ss_y]];
        if (tables.tx_width[uv] == 64 or tables.tx_height[uv] == 64) {
            if (tables.tx_width[uv] == 16) return common.TX_16X32;
            if (tables.tx_height[uv] == 16) return common.TX_32X16;
            return common.TX_32X32;
        }
        return uv;
    }

    fn transformTree(ps: *Parse, x: u32, y: u32, w: u32, hh: u32) Error!void {
        const out = ps.out;
        if (x >= out.mi_cols * 4 or y >= out.mi_rows * 4) return;
        const tx = ps.inter_tx[(y >> 2) * out.mi_cols + (x >> 2)];
        if (w <= tables.tx_width[tx] and hh <= tables.tx_height[tx]) {
            try ps.transformBlock(0, x, y, findTxSize(w, hh), 0, 0);
        } else if (w > hh) {
            try ps.transformTree(x, y, w / 2, hh);
            try ps.transformTree(x + w / 2, y, w / 2, hh);
        } else if (w < hh) {
            try ps.transformTree(x, y, w, hh / 2);
            try ps.transformTree(x, y + hh / 2, w, hh / 2);
        } else {
            try ps.transformTree(x, y, w / 2, hh / 2);
            try ps.transformTree(x + w / 2, y, w / 2, hh / 2);
            try ps.transformTree(x, y + hh / 2, w / 2, hh / 2);
            try ps.transformTree(x + w / 2, y + hh / 2, w / 2, hh / 2);
        }
    }

    fn transformBlock(ps: *Parse, plane: u32, base_x: u32, base_y: u32, txsz: u8, x: u32, y: u32) Error!void {
        const b = &ps.b;
        const out = ps.out;
        const seq = ps.seq;
        const start_x = base_x + 4 * x;
        const start_y = base_y + 4 * y;
        const ssx: u5 = if (plane > 0) seq.ss_x else 0;
        const ssy: u5 = if (plane > 0) seq.ss_y else 0;
        const row = (start_y << ssy) >> 2;
        const col = (start_x << ssx) >> 2;
        const mask: u32 = if (seq.use_128x128) 31 else 15;
        const sub_r = (row & mask) >> ssy;
        const sub_c = (col & mask) >> ssx;
        const step_x: u32 = tables.tx_width[txsz] >> 2;
        const step_y: u32 = tables.tx_height[txsz] >> 2;
        const max_x = (out.mi_cols * 4) >> ssx;
        const max_y = (out.mi_rows * 4) >> ssy;
        if (start_x >= max_x or start_y >= max_y) return;
        var t: Txb = .{ .x4 = @intCast(start_x >> 2), .y4 = @intCast(start_y >> 2), .plane = @intCast(plane), .txsz = txsz };
        var keep = false;
        if (!b.is_inter) {
            keep = true;
            const has_left = (if (plane == 0) ps.avail_l else ps.avail_l_chroma) or x > 0;
            const has_above = (if (plane == 0) ps.avail_u else ps.avail_u_chroma) or y > 0;
            const above_right = ps.decoded[plane][sub_r][sub_c + step_x + 1];
            const below_left = ps.decoded[plane][sub_r + step_y + 1][sub_c];
            t.edges = @as(u8, if (has_left) EDGE_LEFT else 0) | @as(u8, if (has_above) EDGE_ABOVE else 0) |
                @as(u8, if (above_right) EDGE_ABOVE_RIGHT else 0) | @as(u8, if (below_left) EDGE_BELOW_LEFT else 0);
        }
        if (!b.skip) {
            const eob = try ps.coeffs(plane, start_x, start_y, txsz, &t);
            if (eob > 0) keep = true;
        }
        if (keep) {
            if (out.ntxbs >= out.txbs.len) {
                if (!ps.env.grow(Txb, &out.txbs, out.ntxbs + 1)) return error.NoMemory;
            }
            out.txbs[out.ntxbs] = t;
            out.ntxbs += 1;
        }
        const lf = out.lf_tx[plane];
        for (0..step_y) |i| {
            const rr = (row >> ssy) + @as(u32, @intCast(i));
            if (rr >= out.mi_rows) break;
            for (0..step_x) |j| {
                const cc = (col >> ssx) + @as(u32, @intCast(j));
                if (cc < out.mi_cols) lf[rr * out.mi_cols + cc] = txsz;
                ps.decoded[plane][sub_r + i + 1][sub_c + j + 1] = true;
            }
        }
    }

    fn txSet(ps: *const Parse, txsz: u8) u8 {
        const sqr = tables.tx_size_sqr[txsz];
        const sqr_up = tables.tx_size_sqr_up[txsz];
        if (sqr_up > common.TX_32X32) return TX_SET_DCTONLY;
        if (ps.b.is_inter) {
            if (ps.h.reduced_tx_set or sqr_up == common.TX_32X32) return TX_SET_INTER_3;
            if (sqr == common.TX_16X16) return TX_SET_INTER_2;
            return TX_SET_INTER_1;
        }
        if (sqr_up == common.TX_32X32) return TX_SET_DCTONLY;
        if (ps.h.reduced_tx_set) return TX_SET_INTRA_2;
        if (sqr == common.TX_16X16) return TX_SET_INTRA_2;
        return TX_SET_INTRA_1;
    }

    fn txTypeInSet(ps: *const Parse, set: u8, tx_type: u8) bool {
        return if (ps.b.is_inter) tables.tx_type_in_set_inter[set][tx_type] == 1 else tables.tx_type_in_set_intra[set][tx_type] == 1;
    }

    fn computeTxType(ps: *const Parse, plane: u32, txsz: u8, bx: u32, by: u32) u8 {
        const b = &ps.b;
        const out = ps.out;
        if (b.lossless or tables.tx_size_sqr_up[txsz] > common.TX_32X32) return common.DCT_DCT;
        const set = ps.txSet(txsz);
        if (plane == 0) return ps.tx_types[by * out.mi_cols + bx];
        if (b.is_inter) {
            const x4 = @max(b.col, bx << ps.seq.ss_x);
            const y4 = @max(b.row, by << ps.seq.ss_y);
            const t = ps.tx_types[y4 * out.mi_cols + x4];
            return if (ps.txTypeInSet(set, t)) t else common.DCT_DCT;
        }
        const t = tables.mode_to_txfm[b.uv_mode];
        return if (ps.txTypeInSet(set, t)) t else common.DCT_DCT;
    }

    fn readTxType(ps: *Parse, x4: u32, y4: u32, txsz: u8) void {
        const b = &ps.b;
        const h = ps.h;
        const out = ps.out;
        const set = ps.txSet(txsz);
        var t: u8 = common.DCT_DCT;
        const q = if (h.segmentation_enabled) h.qindex(true, ps.current_q, b.segment) else h.base_q_idx;
        if (set > 0 and q > 0) {
            const sqr = tables.tx_size_sqr[txsz];
            if (b.is_inter) {
                if (set == TX_SET_INTER_1) {
                    t = tables.tx_type_inter_inv_set1[ps.sym(&ps.c.inter_tx_type_set1[sqr])];
                } else if (set == TX_SET_INTER_2) {
                    t = tables.tx_type_inter_inv_set2[ps.sym(&ps.c.inter_tx_type_set2)];
                } else {
                    t = tables.tx_type_inter_inv_set3[ps.sym(&ps.c.inter_tx_type_set3[sqr])];
                }
            } else {
                const dir = if (b.filter_intra) tables.filter_intra_mode_to_intra_dir[b.filter_mode] else b.y_mode;
                if (set == TX_SET_INTRA_1) {
                    t = tables.tx_type_intra_inv_set1[ps.sym(&ps.c.intra_tx_type_set1[sqr][dir])];
                } else {
                    t = tables.tx_type_intra_inv_set2[ps.sym(&ps.c.intra_tx_type_set2[sqr][dir])];
                }
            }
        }
        ps.setTxTypes(x4, y4, txsz, t);
        _ = out;
    }

    fn setTxTypes(ps: *Parse, x4: u32, y4: u32, txsz: u8, t: u8) void {
        const out = ps.out;
        const w4: u32 = tables.tx_width[txsz] >> 2;
        const h4: u32 = tables.tx_height[txsz] >> 2;
        const rows = @min(h4, out.mi_rows - @min(y4, out.mi_rows));
        const cols = @min(w4, out.mi_cols - @min(x4, out.mi_cols));
        for (0..rows) |j| @memset(ps.tx_types[(y4 + j) * out.mi_cols + x4 ..][0..cols], t);
    }

    /// coeffs (5.11.39): the transform block's coefficients, dequantised
    /// (7.12.3) into `out.coefs`; the end of block.
    fn coeffs(ps: *Parse, plane: u32, start_x: u32, start_y: u32, txsz: u8, t: *Txb) Error!u32 {
        const b = &ps.b;
        const h = ps.h;
        const seq = ps.seq;
        const out = ps.out;
        const x4 = start_x >> 2;
        const y4 = start_y >> 2;
        const w4: u32 = tables.tx_width[txsz] >> 2;
        const h4: u32 = tables.tx_height[txsz] >> 2;
        const tx_sz_ctx = (@as(u32, tables.tx_size_sqr[txsz]) + tables.tx_size_sqr_up[txsz] + 1) >> 1;
        const ptype: u32 = @intFromBool(plane > 0);
        const ssx: u5 = if (plane > 0) seq.ss_x else 0;
        const ssy: u5 = if (plane > 0) seq.ss_y else 0;
        const max_x4 = out.mi_cols >> ssx;
        const max_y4 = out.mi_rows >> ssy;

        // all_zero's context.
        var ctx: u32 = 0;
        const w: u32 = tables.tx_width[txsz];
        const hh: u32 = tables.tx_height[txsz];
        const bsize = tables.subsampled_size[b.size][ssx][ssy];
        const bw = blockWidth(bsize);
        const bh = blockHeight(bsize);
        if (plane == 0) {
            var top: u32 = 0;
            var left: u32 = 0;
            for (0..w4) |k| {
                if (x4 + k < max_x4) top = @max(top, ps.above_level[plane][x4 + k]);
            }
            for (0..h4) |k| {
                if (y4 + k < max_y4) left = @max(left, ps.left_level[plane][y4 + k]);
            }
            if (bw == w and bh == hh) {
                ctx = 0;
            } else if (top == 0 and left == 0) {
                ctx = 1;
            } else if (top == 0 or left == 0) {
                ctx = 2 + @as(u32, @intFromBool(@max(top, left) > 3));
            } else if (@max(top, left) <= 3) {
                ctx = 4;
            } else if (@min(top, left) <= 3) {
                ctx = 5;
            } else {
                ctx = 6;
            }
        } else {
            var above: u32 = 0;
            var left: u32 = 0;
            for (0..w4) |i| {
                if (x4 + i < max_x4) above |= @as(u32, ps.above_level[plane][x4 + i]) | ps.above_dc[plane][x4 + i];
            }
            for (0..h4) |i| {
                if (y4 + i < max_y4) left |= @as(u32, ps.left_level[plane][y4 + i]) | ps.left_dc[plane][y4 + i];
            }
            ctx = @as(u32, @intFromBool(above != 0)) + @intFromBool(left != 0) + 7;
            if (bw * bh > w * hh) ctx += 3;
        }

        var eob: u32 = 0;
        var cul_level: u32 = 0;
        var dc_category: u8 = 0;
        if (ps.sym(&ps.c.txb_skip[tx_sz_ctx][ctx]) == 1) {
            if (plane == 0) ps.setTxTypes(x4, y4, txsz, common.DCT_DCT);
        } else {
            if (plane == 0) ps.readTxType(x4, y4, txsz);
            const tx_type = ps.computeTxType(plane, txsz, x4, y4);
            t.tx_type = tx_type;
            const scan = getScan(txsz, tx_type);
            const tx_class = txClass(tx_type);
            const adj = tables.adjusted_tx_size[txsz];
            const bwl: u5 = @intCast(tables.tx_width_log2[adj]);
            const th: u32 = tables.tx_height[adj];

            const eob_multisize = @as(u32, @min(tables.tx_width_log2[txsz], 5)) + @min(tables.tx_height_log2[txsz], 5) - 4;
            const ectx: u32 = if (tx_class == TX_CLASS_2D) 0 else 1;
            const eob_pt: u32 = 1 + switch (eob_multisize) {
                0 => ps.sym(&ps.c.eob_pt_16[ptype][ectx]),
                1 => ps.sym(&ps.c.eob_pt_32[ptype][ectx]),
                2 => ps.sym(&ps.c.eob_pt_64[ptype][ectx]),
                3 => ps.sym(&ps.c.eob_pt_128[ptype][ectx]),
                4 => ps.sym(&ps.c.eob_pt_256[ptype][ectx]),
                5 => ps.sym(&ps.c.eob_pt_512[ptype]),
                else => ps.sym(&ps.c.eob_pt_1024[ptype]),
            };
            eob = if (eob_pt < 2) eob_pt else (@as(u32, 1) << @intCast(eob_pt - 2)) + 1;
            if (eob_pt >= 3) {
                const shift: u5 = @intCast(eob_pt - 3);
                if (ps.sym(&ps.c.eob_extra[tx_sz_ctx][ptype][eob_pt - 3]) == 1) eob += @as(u32, 1) << shift;
                var i: u32 = 1;
                while (i < eob_pt - 2) : (i += 1) {
                    const s: u5 = @intCast(eob_pt - 2 - 1 - i);
                    if (ps.lit(1) == 1) eob += @as(u32, 1) << s;
                }
            }
            switch (tx_class) {
                inline TX_CLASS_2D, TX_CLASS_HORIZ, TX_CLASS_VERT => |cls| ps.readLevels(cls, scan, eob, txsz, tx_sz_ctx, ptype, bwl, th),
                else => unreachable,
            }

            // Signs, the rest of the big ones and dequantisation.
            if (out.ncoefs + eob > out.coefs.len) {
                if (!ps.env.grow(i32, &out.coefs, out.ncoefs + eob)) return error.NoMemory;
            }
            t.coef = out.ncoefs;
            t.eob = @intCast(eob);
            const dst = out.coefs[out.ncoefs..][0..eob];
            out.ncoefs += eob;
            const qindex: i32 = h.qindex(false, ps.current_q, b.segment);
            const dc_delta: i32 = switch (plane) {
                0 => h.delta_q_y_dc,
                1 => h.delta_q_u_dc,
                else => h.delta_q_v_dc,
            };
            const ac_delta: i32 = switch (plane) {
                0 => 0,
                1 => h.delta_q_u_ac,
                else => h.delta_q_v_ac,
            };
            const bd_idx = (seq.bit_depth - 8) >> 1;
            const dc_q: i64 = tables.dc_qlookup[bd_idx][@intCast(common.clip3(0, 255, qindex + dc_delta))];
            const ac_q: i64 = tables.ac_qlookup[bd_idx][@intCast(common.clip3(0, 255, qindex + ac_delta))];
            const qm_level = h.seg_qm_level[plane][b.segment];
            const use_qm = h.using_qmatrix and tx_type < common.IDTX and qm_level < 15;
            const qm = &tables.quantizer_matrix[if (use_qm) qm_level else 0][@intFromBool(plane > 0)];
            const qm_off: u32 = tables.qm_offset[txsz];
            const denom_shift: u6 = switch (txsz) {
                common.TX_32X32, common.TX_16X32, common.TX_32X16, common.TX_16X64, common.TX_64X16 => 1,
                common.TX_64X64, common.TX_32X64, common.TX_64X32 => 2,
                else => 0,
            };
            const lim: i64 = @as(i64, 1) << @intCast(7 + seq.bit_depth);
            for (0..eob) |cu| {
                const pos: u32 = scan[cu];
                const at = pos + (pos >> bwl) * TX_PAD;
                var v: u32 = ps.levels[at];
                ps.levels[at] = 0;
                var sign: u32 = 0;
                if (v != 0) {
                    if (cu == 0) {
                        sign = ps.sym(&ps.c.dc_sign[ptype][ps.dcSignCtx(plane, x4, y4, w4, h4, max_x4, max_y4)]);
                    } else {
                        sign = ps.lit(1);
                    }
                }
                if (v > 14) {
                    var length: u32 = 0;
                    while (true) {
                        length += 1;
                        if (ps.lit(1) == 1) break;
                        if (length >= 20) return error.Corrupt;
                    }
                    var xg: u32 = 1;
                    var i: u32 = length - 1;
                    while (i > 0) : (i -= 1) xg = (xg << 1) | ps.lit(1);
                    v = xg + 14;
                }
                if (pos == 0 and v > 0) dc_category = if (sign == 1) 1 else 2;
                v &= 0xFFFFF;
                cul_level += v;
                // Dequantised (7.12.3).
                var q: i64 = if (pos == 0) dc_q else ac_q;
                if (use_qm) q = common.round2_64(q * qm[qm_off + pos], 5);
                const dq: i64 = @as(i64, v) * q;
                var dq2: i64 = (dq & 0xFFFFFF) >> denom_shift;
                if (sign == 1) dq2 = -dq2;
                dst[cu] = @intCast(@max(-lim, @min(lim - 1, dq2)));
            }
            cul_level = @min(63, cul_level);
        }
        for (0..w4) |i| {
            ps.above_level[plane][x4 + i] = @intCast(cul_level);
            ps.above_dc[plane][x4 + i] = dc_category;
        }
        for (0..h4) |i| {
            ps.left_level[plane][y4 + i] = @intCast(cul_level);
            ps.left_dc[plane][y4 + i] = dc_category;
        }
        return eob;
    }

    /// The levels of a transform block's coefficients, of class `cls`,
    /// from the last back to the first, into `levels`: its columns and
    /// rows beyond the block 0, as the contexts read them (get_coeff_base_ctx
    /// and get_br_ctx).
    inline fn readLevels(ps: *Parse, comptime cls: u32, scan: []const u16, eob: u32, txsz: u8, tx_sz_ctx: u32, ptype: u32, bwl: u5, th: u32) void {
        const lv = &ps.levels;
        const stride = (@as(u32, 1) << bwl) + TX_PAD;
        const base_cdfs = &ps.c.coeff_base[tx_sz_ctx][ptype];
        const br_cdfs = &ps.c.coeff_br[@min(tx_sz_ctx, common.TX_32X32)][ptype];
        var c = eob;
        while (c > 0) {
            c -= 1;
            const pos: u32 = scan[c];
            const row = pos >> bwl;
            const col = pos - (row << bwl);
            const at = row * stride + col;
            var level: u32 = undefined;
            if (c == eob - 1) {
                const area = th << bwl;
                const ectx: u32 = if (c == 0) 0 else if (c <= area / 8) 1 else if (c <= area / 4) 2 else 3;
                level = ps.sym(&ps.c.coeff_base_eob[tx_sz_ctx][ptype][ectx]) + 1;
            } else {
                var mag: u32 = 0;
                inline for (tables.sig_ref_diff_offset[cls]) |o| mag += @min(lv[at + o[0] * stride + o[1]], 3);
                const ctx = @min((mag + 1) >> 1, 4);
                const bctx = switch (cls) {
                    TX_CLASS_2D => if (pos == 0) 0 else ctx + tables.coeff_base_ctx_offset[txsz][@min(row, 4)][@min(col, 4)],
                    TX_CLASS_VERT => ctx + tables.coeff_base_pos_ctx_offset[@min(row, 2)],
                    else => ctx + tables.coeff_base_pos_ctx_offset[@min(col, 2)],
                };
                level = ps.sym(&base_cdfs[bctx]);
            }
            if (level > 2) {
                // The levels are 15 at most.
                var mag: u32 = 0;
                inline for (tables.mag_ref_offset_with_tx_class[cls]) |o| mag += lv[at + o[0] * stride + o[1]];
                mag = @min((mag + 1) >> 1, 6);
                const brctx = if (pos == 0) mag else switch (cls) {
                    TX_CLASS_2D => if (row < 2 and col < 2) mag + 7 else mag + 14,
                    TX_CLASS_HORIZ => if (col == 0) mag + 7 else mag + 14,
                    else => if (row == 0) mag + 7 else mag + 14,
                };
                const br = &br_cdfs[brctx];
                for (0..4) |_| {
                    const k = ps.sym(br);
                    level += k;
                    if (k < 3) break;
                }
            }
            lv[at] = @intCast(level);
        }
    }

    fn dcSignCtx(ps: *const Parse, plane: u32, x4: u32, y4: u32, w4: u32, h4: u32, max_x4: u32, max_y4: u32) u32 {
        var s: i32 = 0;
        for (0..w4) |k| {
            if (x4 + k < max_x4) {
                const v = ps.above_dc[plane][x4 + k];
                if (v == 1) s -= 1 else if (v == 2) s += 1;
            }
        }
        for (0..h4) |k| {
            if (y4 + k < max_y4) {
                const v = ps.left_dc[plane][y4 + k];
                if (v == 1) s -= 1 else if (v == 2) s += 1;
            }
        }
        return if (s < 0) 1 else if (s > 0) 2 else 0;
    }

    // --- loop restoration units (5.11.57, 5.11.58) ---

    fn readLr(ps: *Parse, r: u32, c: u32, bsize: u8) Error!void {
        const h = ps.h;
        if (h.allow_intrabc) return;
        const w: u32 = tables.num_4x4_blocks_wide[bsize];
        const hh: u32 = tables.num_4x4_blocks_high[bsize];
        for (0..ps.seq.planes()) |p| {
            if (h.frame_restoration_type[p] == common.RESTORE_NONE) continue;
            const ssx: u5 = if (p > 0) ps.seq.ss_x else 0;
            const ssy: u5 = if (p > 0) ps.seq.ss_y else 0;
            const l = &ps.out.lr[p];
            const unit = l.unit_size;
            const row_start = (r * (@as(u32, 4) >> ssy) + unit - 1) / unit;
            const row_end = @min(l.rows, ((r + hh) * (@as(u32, 4) >> ssy) + unit - 1) / unit);
            var num: u32 = @as(u32, 4) >> ssx;
            var den: u32 = unit;
            if (h.use_superres) {
                num = (@as(u32, 4) >> ssx) * h.superres_denom;
                den = unit * 8;
            }
            const col_start = (c * num + den - 1) / den;
            const col_end = @min(l.cols, ((c + w) * num + den - 1) / den);
            var ur = row_start;
            while (ur < row_end) : (ur += 1) {
                var uc = col_start;
                while (uc < col_end) : (uc += 1) ps.readLrUnit(@intCast(p), ur * l.cols + uc);
            }
        }
    }

    fn readLrUnit(ps: *Parse, p: u32, at: u32) void {
        const l = &ps.out.lr[p];
        const kind: u8 = switch (ps.h.frame_restoration_type[p]) {
            common.RESTORE_WIENER => if (ps.sym(&ps.c.use_wiener) == 1) common.RESTORE_WIENER else common.RESTORE_NONE,
            common.RESTORE_SGRPROJ => if (ps.sym(&ps.c.use_sgrproj) == 1) common.RESTORE_SGRPROJ else common.RESTORE_NONE,
            else => @intCast(ps.sym(&ps.c.restoration_type)),
        };
        l.kind[at] = kind;
        if (kind == common.RESTORE_WIENER) {
            for (0..2) |pass| {
                var first: usize = 0;
                if (p > 0) {
                    first = 1;
                    l.wiener[at][pass][0] = 0;
                }
                for (first..3) |j| {
                    const lo: i32 = tables.wiener_taps_min[j];
                    const hi: i32 = tables.wiener_taps_max[j];
                    const k: u5 = @intCast(tables.wiener_taps_k[j]);
                    const v = ps.subexpRefBool(lo, hi + 1, k, ps.ref_lr_wiener[p][pass][j]);
                    l.wiener[at][pass][j] = @intCast(v);
                    ps.ref_lr_wiener[p][pass][j] = @intCast(v);
                }
            }
        } else if (kind == common.RESTORE_SGRPROJ) {
            const set = ps.lit(4);
            l.sgr_set[at] = @intCast(set);
            for (0..2) |i| {
                const radius = tables.sgr_params[set][i * 2];
                const lo: i32 = tables.sgrproj_xqd_min[i];
                const hi: i32 = tables.sgrproj_xqd_max[i];
                var v: i32 = 0;
                if (radius != 0) {
                    v = ps.subexpRefBool(lo, hi + 1, 4, ps.ref_sgr_xqd[p][i]);
                } else if (i == 1) {
                    v = common.clip3(lo, hi, (1 << 7) - @as(i32, ps.ref_sgr_xqd[p][0]));
                }
                l.sgr_xqd[at][i] = @intCast(v);
                ps.ref_sgr_xqd[p][i] = @intCast(v);
            }
        }
    }

    fn subexpRefBool(ps: *Parse, low: i32, high: i32, k: u5, r: i32) i32 {
        const mx = high - low;
        const rr = r - low;
        // decode_subexp_bool
        var i: u5 = 0;
        var mk: i32 = 0;
        var v: i32 = 0;
        while (true) {
            const b2: u5 = if (i != 0) k + i - 1 else k;
            const a = @as(i32, 1) << b2;
            if (mx <= mk + 3 * a) {
                v = @as(i32, @intCast(ps.nsBool(@intCast(mx - mk)))) + mk;
                break;
            }
            if (ps.lit(1) == 1) {
                i += 1;
                mk += a;
            } else {
                v = @as(i32, @intCast(ps.lit(b2))) + mk;
                break;
            }
        }
        const x = if ((rr << 1) <= mx) inverseRecenter(rr, v) else mx - 1 - inverseRecenter(mx - 1 - rr, v);
        return x + low;
    }
};

pub const TX_SET_DCTONLY = 0;
pub const TX_SET_INTRA_1 = 1;
pub const TX_SET_INTRA_2 = 2;
pub const TX_SET_INTER_1 = 1;
pub const TX_SET_INTER_2 = 2;
pub const TX_SET_INTER_3 = 3;

/// The columns and rows `levels` has beyond a transform block, which its
/// contexts reach.
const TX_PAD = 4;

pub const TX_CLASS_2D = 0;
pub const TX_CLASS_HORIZ = 1;
pub const TX_CLASS_VERT = 2;

pub fn txClass(t: u8) u32 {
    return switch (t) {
        common.V_DCT, common.V_ADST, common.V_FLIPADST => TX_CLASS_VERT,
        common.H_DCT, common.H_ADST, common.H_FLIPADST => TX_CLASS_HORIZ,
        else => TX_CLASS_2D,
    };
}

/// get_scan (5.11.41).
pub fn getScan(txsz: u8, tx_type: u8) []const u16 {
    if (txsz == common.TX_16X64) return &tables.default_scan_16x32;
    if (txsz == common.TX_64X16) return &tables.default_scan_32x16;
    if (tables.tx_size_sqr_up[txsz] == common.TX_64X64) return &tables.default_scan_32x32;
    if (tx_type == common.IDTX) return defaultScan(txsz);
    const prefer_row = tx_type == common.V_DCT or tx_type == common.V_ADST or tx_type == common.V_FLIPADST;
    const prefer_col = tx_type == common.H_DCT or tx_type == common.H_ADST or tx_type == common.H_FLIPADST;
    if (prefer_row) {
        return switch (txsz) {
            common.TX_4X4 => &tables.mrow_scan_4x4,
            common.TX_4X8 => &tables.mrow_scan_4x8,
            common.TX_8X4 => &tables.mrow_scan_8x4,
            common.TX_8X8 => &tables.mrow_scan_8x8,
            common.TX_8X16 => &tables.mrow_scan_8x16,
            common.TX_16X8 => &tables.mrow_scan_16x8,
            common.TX_16X16 => &tables.mrow_scan_16x16,
            common.TX_4X16 => &tables.mrow_scan_4x16,
            else => &tables.mrow_scan_16x4,
        };
    }
    if (prefer_col) {
        return switch (txsz) {
            common.TX_4X4 => &tables.mcol_scan_4x4,
            common.TX_4X8 => &tables.mcol_scan_4x8,
            common.TX_8X4 => &tables.mcol_scan_8x4,
            common.TX_8X8 => &tables.mcol_scan_8x8,
            common.TX_8X16 => &tables.mcol_scan_8x16,
            common.TX_16X8 => &tables.mcol_scan_16x8,
            common.TX_16X16 => &tables.mcol_scan_16x16,
            common.TX_4X16 => &tables.mcol_scan_4x16,
            else => &tables.mcol_scan_16x4,
        };
    }
    return defaultScan(txsz);
}

fn defaultScan(txsz: u8) []const u16 {
    return switch (txsz) {
        common.TX_4X4 => &tables.default_scan_4x4,
        common.TX_4X8 => &tables.default_scan_4x8,
        common.TX_8X4 => &tables.default_scan_8x4,
        common.TX_8X8 => &tables.default_scan_8x8,
        common.TX_8X16 => &tables.default_scan_8x16,
        common.TX_16X8 => &tables.default_scan_16x8,
        common.TX_16X16 => &tables.default_scan_16x16,
        common.TX_16X32 => &tables.default_scan_16x32,
        common.TX_32X16 => &tables.default_scan_32x16,
        common.TX_4X16 => &tables.default_scan_4x16,
        common.TX_16X4 => &tables.default_scan_16x4,
        common.TX_8X32 => &tables.default_scan_8x32,
        common.TX_32X8 => &tables.default_scan_32x8,
        else => &tables.default_scan_32x32,
    };
}

pub fn blockWidth(size: u8) u32 {
    return @as(u32, tables.num_4x4_blocks_wide[size]) * 4;
}

pub fn blockHeight(size: u8) u32 {
    return @as(u32, tables.num_4x4_blocks_high[size]) * 4;
}

pub fn findTxSize(w: u32, hh: u32) u8 {
    var t: u8 = 0;
    while (t < 19) : (t += 1) {
        if (tables.tx_width[t] == w and tables.tx_height[t] == hh) break;
    }
    return t;
}

fn isDirectional(mode: u8) bool {
    return mode >= common.V_PRED and mode <= common.D67_PRED;
}

fn hasNearMv(m: u8) bool {
    return m == common.NEARMV or m == common.NEAR_NEARMV or m == common.NEAR_NEWMV or m == common.NEW_NEARMV;
}

pub fn getMode(y_mode: u8, ref_list: usize) u8 {
    if (ref_list == 0) {
        if (y_mode < common.NEAREST_NEARESTMV) return y_mode;
        if (y_mode == common.NEW_NEWMV or y_mode == common.NEW_NEARESTMV or y_mode == common.NEW_NEARMV) return common.NEWMV;
        if (y_mode == common.NEAREST_NEARESTMV or y_mode == common.NEAREST_NEWMV) return common.NEARESTMV;
        if (y_mode == common.NEAR_NEARMV or y_mode == common.NEAR_NEWMV) return common.NEARMV;
        return common.GLOBALMV;
    }
    if (y_mode == common.NEW_NEWMV or y_mode == common.NEAREST_NEWMV or y_mode == common.NEAR_NEWMV) return common.NEWMV;
    if (y_mode == common.NEAREST_NEARESTMV or y_mode == common.NEW_NEARESTMV) return common.NEARESTMV;
    if (y_mode == common.NEAR_NEARMV or y_mode == common.NEW_NEARMV) return common.NEARMV;
    return common.GLOBALMV;
}

fn checkBackward(r: i8) bool {
    return r >= common.BWDREF_FRAME and r <= common.ALTREF_FRAME;
}

fn sameDir(a: i8, b: i8) bool {
    return (a >= common.BWDREF_FRAME) == (b >= common.BWDREF_FRAME);
}

fn prob(c: []const u16, i: usize) u32 {
    return @as(u32, c[i]) - c[i - 1];
}

fn negDeinterleave(diff: i32, r: i32, max: i32) i32 {
    if (r == 0) return diff;
    if (r >= max - 1) return max - diff - 1;
    if (2 * r < max) {
        if (diff <= 2 * r) {
            if (diff & 1 != 0) return r + ((diff + 1) >> 1);
            return r - (diff >> 1);
        }
        return diff;
    }
    if (diff <= 2 * (max - r - 1)) {
        if (diff & 1 != 0) return r + ((diff + 1) >> 1);
        return r - (diff >> 1);
    }
    return max - (diff + 1);
}

fn inverseRecenter(r: i32, v: i32) i32 {
    if (v > 2 * r) return v;
    if (v & 1 != 0) return r - ((v + 1) >> 1);
    return r + (v >> 1);
}

fn sortColors(c: []u16) void {
    var i: usize = 1;
    while (i < c.len) : (i += 1) {
        const v = c[i];
        var j = i;
        while (j > 0 and c[j - 1] > v) : (j -= 1) c[j] = c[j - 1];
        c[j] = v;
    }
}

/// get_palette_color_context (5.11.50): the context, and the colours
/// ordered by their neighbours' scores in `order`.
fn colorContext(m: *const [64 * 64]u8, stride: u32, r: u32, c: u32, n: u32, order: *[8]u8) u32 {
    var scores: [8]u32 = @splat(0);
    for (0..8) |i| order[i] = @intCast(i);
    if (c > 0) scores[m[r * stride + c - 1]] += 2;
    if (r > 0 and c > 0) scores[m[(r - 1) * stride + c - 1]] += 1;
    if (r > 0) scores[m[(r - 1) * stride + c]] += 2;
    for (0..3) |i| {
        var max_score = scores[i];
        var max_idx = i;
        var j = i + 1;
        while (j < n) : (j += 1) {
            if (scores[j] > max_score) {
                max_score = scores[j];
                max_idx = j;
            }
        }
        if (max_idx != i) {
            max_score = scores[max_idx];
            const max_order = order[max_idx];
            var k = max_idx;
            while (k > i) : (k -= 1) {
                scores[k] = scores[k - 1];
                order[k] = order[k - 1];
            }
            scores[i] = max_score;
            order[i] = max_order;
        }
    }
    var hash: u32 = 0;
    for (0..3) |i| hash += scores[i] * tables.palette_color_hash_multipliers[i];
    return @intCast(tables.palette_color_context[hash]);
}

fn countUnits(unit: u32, frame_size: u32) u32 {
    return @max((frame_size + (unit >> 1)) / unit, 1);
}
