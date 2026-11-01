// SPDX-License-Identifier: MIT
//! A frame's tiles read (6.4): each block's partition, segment, modes,
//! motion vectors and coefficients, into the blocks and coefficients the
//! reconstruction works from. Reading never needs a sample, so a frame
//! can be read while the one before it is still being reconstructed.

const common = @import("common.zig");
const tables = @import("tables.zig");
const header = @import("header.zig");
const probs = @import("probs.zig");
const Bool = @import("bool.zig").Bool;
const Block = common.Block;
const Mv = common.Mv;
const MvRef = common.MvRef;
const Error = common.Error;

/// The most coefficient words a block can add: three 64x64 planes and an
/// end word for each of their 4x4s.
pub const max_block_words = 3 * (4096 + 256);

/// What reading a frame makes, which its reconstruction and loop filter
/// work from: its blocks and their coefficients.
pub const Out = struct {
    mi_cols: u32 = 0,
    mi_rows: u32 = 0,
    /// Each 8x8's block: an index into `blocks`.
    grid: []u32 = &.{},
    blocks: []Block = &.{},
    n_blocks: u32 = 0,
    /// Each superblock's first block and how many it has.
    sb_first: []u32 = &.{},
    sb_count: []u32 = &.{},
    /// For each coded block, by plane, for each of its transform blocks
    /// on screen in raster order: the number of coefficients, then the
    /// coefficients dequantised in scan order.
    coef: []i32 = &.{},
    n_coef: usize = 0,

    /// The arrays for a frame of `mi_cols` by `mi_rows` 8x8s; false when
    /// there is no memory.
    pub fn fit(out: *Out, env: common.Env, mi_cols: u32, mi_rows: u32) bool {
        const n: usize = @as(usize, mi_cols) * mi_rows;
        const sbs = @as(usize, (mi_cols + 7) >> 3) * ((mi_rows + 7) >> 3);
        out.mi_cols = mi_cols;
        out.mi_rows = mi_rows;
        if (out.grid.len == n and out.sb_first.len == sbs) return true;
        if (!env.resize(u32, &out.grid, n)) return false;
        if (!env.resize(Block, &out.blocks, n)) return false;
        if (!env.resize(u32, &out.sb_first, sbs)) return false;
        if (!env.resize(u32, &out.sb_count, sbs)) return false;
        return true;
    }

    pub fn deinit(out: *Out, env: common.Env) void {
        env.freeSlice(u32, out.grid);
        env.freeSlice(Block, out.blocks);
        env.freeSlice(u32, out.sb_first);
        env.freeSlice(u32, out.sb_count);
        env.freeSlice(i32, out.coef);
        out.* = .{};
    }
};

/// What reading a frame needs. The decoder sets the inputs, sizes the
/// contexts (`size`) and hands it the `Out` that `tiles` fills.
pub const Parse = struct {
    env: common.Env,
    h: *const header.Header = undefined,
    seg: *const header.Segmentation = undefined,
    p: *const probs.Probs = undefined,
    /// Always there; filled only when `count`.
    counts: *probs.Counts = undefined,
    /// Whether the frame counts what it reads, for the adaptation.
    count: bool = false,
    bit_depth: u8 = 8,
    ss_x: u1 = 1,
    ss_y: u1 = 1,
    mi_cols: u32 = 0,
    mi_rows: u32 = 0,
    /// The previous frame's vectors, when this one may use them, and
    /// this one's for the next; by 8x8, MiRows * MiCols.
    use_prev_mvs: bool = false,
    prev_mvs: []const MvRef = &.{},
    cur_mvs: []MvRef = &.{},
    /// The segment map the frame predicts from, and the one it writes
    /// when it updates the map.
    prev_seg: []const u8 = &.{},
    cur_seg: []u8 = &.{},

    out: *Out = undefined,

    /// By segment, plane > 0 and AC: the dequantiser (8.6.1).
    dq: [8][2][2]i32 = undefined,
    /// By segment, reference and mode type: the loop filter level.
    lvl: [8][4][2]u8 = undefined,

    // The contexts (9.3.2): above by 4x4 or 8x8 across the frame, left
    // within the superblock row.
    above_nz: [3][]u8 = .{ &.{}, &.{}, &.{} },
    above_part: []u8 = &.{},
    above_seg: []u8 = &.{},
    left_nz: [3][16]u8 = undefined,
    left_part: [8]u8 = undefined,
    left_seg: [8]u8 = undefined,

    col_start: u32 = 0,
    col_end: u32 = 0,
    b: Bool = .{},
    token_cache: [1024]u8 = undefined,

    /// The contexts for a frame of `mi_cols` by `mi_rows` 8x8s; false when
    /// there is no memory.
    pub fn size(ps: *Parse, mi_cols: u32, mi_rows: u32, ss_x: u1) bool {
        const env = ps.env;
        const sb_cols: usize = (mi_cols + 7) >> 3;
        ps.mi_cols = mi_cols;
        ps.mi_rows = mi_rows;
        if (!env.resize(u8, &ps.above_nz[0], sb_cols * 16)) return false;
        for (1..3) |i| {
            if (!env.resize(u8, &ps.above_nz[i], (sb_cols * 16) >> ss_x)) return false;
        }
        if (!env.resize(u8, &ps.above_part, sb_cols * 8)) return false;
        if (!env.resize(u8, &ps.above_seg, sb_cols * 8)) return false;
        return true;
    }

    pub fn deinit(ps: *Parse) void {
        const env = ps.env;
        for (ps.above_nz) |a| env.freeSlice(u8, a);
        env.freeSlice(u8, ps.above_part);
        env.freeSlice(u8, ps.above_seg);
        ps.* = .{ .env = env };
    }

    /// The dequantisers and loop filter levels of the frame's segments
    /// (8.6.1, 8.8.1).
    pub fn frameTables(ps: *Parse, deltas: *const header.Deltas) void {
        const h = ps.h;
        const sg = ps.seg;
        const bd: usize = (ps.bit_depth - 8) >> 1;
        for (0..8) |s| {
            var q: i32 = h.base_q_idx;
            if (sg.active(@intCast(s), common.SEG_LVL_ALT_Q)) {
                const d = sg.feature_data[s][common.SEG_LVL_ALT_Q];
                q = clamp(if (sg.abs_delta) d else q + d, 0, 255);
            }
            ps.dq[s][0][0] = tables.dc_qlookup[bd][@intCast(clamp(q + h.delta_q_y_dc, 0, 255))];
            ps.dq[s][0][1] = tables.ac_qlookup[bd][@intCast(q)];
            ps.dq[s][1][0] = tables.dc_qlookup[bd][@intCast(clamp(q + h.delta_q_uv_dc, 0, 255))];
            ps.dq[s][1][1] = tables.ac_qlookup[bd][@intCast(clamp(q + h.delta_q_uv_ac, 0, 255))];

            const level: i32 = h.filter_level;
            var lvl = level;
            if (sg.active(@intCast(s), common.SEG_LVL_ALT_L)) {
                const d = sg.feature_data[s][common.SEG_LVL_ALT_L];
                lvl = clamp(if (sg.abs_delta) d else lvl + d, 0, 63);
            }
            if (!deltas.enabled) {
                ps.lvl[s] = @splat(@splat(@intCast(lvl)));
            } else {
                const scale: i32 = @as(i32, 1) << @intCast(level >> 5);
                ps.lvl[s][0][0] = @intCast(clamp(lvl + deltas.ref[0] * scale, 0, 63));
                ps.lvl[s][0][1] = ps.lvl[s][0][0];
                for (1..4) |ref| {
                    for (0..2) |mode| {
                        ps.lvl[s][ref][mode] = @intCast(clamp(lvl + deltas.ref[ref] * scale + deltas.mode[mode] * scale, 0, 63));
                    }
                }
            }
        }
    }

    /// The frame's tiles, `data` from the end of the compressed header,
    /// into `out`, which `Out.fit` made for the frame's size.
    pub fn tiles(ps: *Parse, data: []const u8) Error!void {
        const h = ps.h;
        for (ps.above_nz) |a| @memset(a, 0);
        @memset(ps.above_part, 0);
        @memset(ps.above_seg, 0);
        ps.out.n_blocks = 0;
        ps.out.n_coef = 0;
        const cols_log2: u5 = @intCast(h.tile_cols_log2);
        const rows_log2: u5 = @intCast(h.tile_rows_log2);
        const tile_cols = @as(u32, 1) << cols_log2;
        const tile_rows = @as(u32, 1) << rows_log2;
        var pos: usize = 0;
        for (0..tile_rows) |tr| {
            for (0..tile_cols) |tc| {
                const last = tr == tile_rows - 1 and tc == tile_cols - 1;
                var len: usize = data.len - pos;
                if (!last) {
                    if (len < 4) return error.Corrupt;
                    len = @as(u32, data[pos]) << 24 | @as(u32, data[pos + 1]) << 16 | @as(u32, data[pos + 2]) << 8 | data[pos + 3];
                    pos += 4;
                    if (len > data.len - pos) return error.Corrupt;
                }
                const row_start = tileOffset(@intCast(tr), ps.mi_rows, rows_log2);
                const row_end = tileOffset(@intCast(tr + 1), ps.mi_rows, rows_log2);
                ps.col_start = tileOffset(@intCast(tc), ps.mi_cols, cols_log2);
                ps.col_end = tileOffset(@intCast(tc + 1), ps.mi_cols, cols_log2);
                // Every tile has data and starts right, as libvpx wants,
                // even one with no superblocks.
                if (len == 0) return error.Corrupt;
                const tile = data[pos .. pos + len];
                pos += len;
                ps.b = Bool.init(tile) orelse return error.Corrupt;
                if (row_start == row_end or ps.col_start == ps.col_end) continue;
                var r = row_start;
                while (r < row_end) : (r += 8) {
                    for (&ps.left_nz) |*l| l.* = @splat(0);
                    ps.left_part = @splat(0);
                    ps.left_seg = @splat(0);
                    var c = ps.col_start;
                    while (c < ps.col_end) : (c += 8) {
                        const sb = (r >> 3) * ((ps.mi_cols + 7) >> 3) + (c >> 3);
                        ps.out.sb_first[sb] = ps.out.n_blocks;
                        try ps.partition(r, c, common.BLOCK_64X64);
                        ps.out.sb_count[sb] = ps.out.n_blocks - ps.out.sb_first[sb];
                    }
                }
                if (ps.b.overrun()) return error.Corrupt;
            }
        }
    }

    fn tileOffset(n: u32, mis: u32, log2: u5) u32 {
        const sbs = (mis + 7) >> 3;
        return @min(((n * sbs) >> log2) << 3, mis);
    }

    fn read(ps: *Parse, prob: u8) u1 {
        return ps.b.read(prob);
    }

    fn partition(ps: *Parse, r: u32, c: u32, bsize: u8) Error!void {
        if (r >= ps.mi_rows or c >= ps.mi_cols) return;
        const num8x8 = tables.num_8x8_wide[bsize];
        const half = num8x8 >> 1;
        const has_rows = r + half < ps.mi_rows;
        const has_cols = c + half < ps.mi_cols;
        const bsl = tables.mi_width_log2[bsize];
        const boffset: u3 = @intCast(3 - bsl);
        const above = (ps.above_part[c] >> boffset) & 1;
        const left = (ps.left_part[r & 7] >> boffset) & 1;
        const ctx: usize = bsl * 4 + left * 2 + above;
        const pp: *const [3]u8 = if (ps.h.intra) &tables.kf_partition_probs[ctx] else &ps.p.partition[ctx];
        var part: u8 = common.PARTITION_SPLIT;
        if (has_rows and has_cols) {
            part = ps.b.tree(&tables.partition_tree, pp);
        } else if (has_cols) {
            if (ps.read(pp[1]) == 0) part = common.PARTITION_HORZ;
        } else if (has_rows) {
            if (ps.read(pp[2]) == 0) part = common.PARTITION_VERT;
        }
        if (ps.count) ps.counts.partition[ctx][part] += 1;
        const subsize = tables.subsize_lookup[part][bsize];
        if (subsize < common.BLOCK_8X8 or part == common.PARTITION_NONE) {
            try ps.block(r, c, subsize);
        } else if (part == common.PARTITION_HORZ) {
            try ps.block(r, c, subsize);
            if (has_rows) try ps.block(r + half, c, subsize);
        } else if (part == common.PARTITION_VERT) {
            try ps.block(r, c, subsize);
            if (has_cols) try ps.block(r, c + half, subsize);
        } else {
            try ps.partition(r, c, subsize);
            try ps.partition(r, c + half, subsize);
            try ps.partition(r + half, c, subsize);
            try ps.partition(r + half, c + half, subsize);
        }
        if (bsize == common.BLOCK_8X8 or part != common.PARTITION_SPLIT) {
            @memset(ps.above_part[c .. c + num8x8], @as(u8, 15) >> @intCast(tables.b_width_log2[subsize]));
            for (0..num8x8) |i| ps.left_part[(r + i) & 7] = @as(u8, 15) >> @intCast(tables.b_height_log2[subsize]);
        }
    }

    /// What reading a block keeps besides the block: its neighbours and
    /// its candidate vectors.
    const Ctx = struct {
        r: u32,
        c: u32,
        avail_u: bool,
        avail_l: bool,
        above: ?*const Block,
        left: ?*const Block,
        /// The neighbours' references, {INTRA_FRAME, NONE} when not there.
        above_ref: [2]i8,
        left_ref: [2]i8,
        nearest: [2]Mv = .{ .{}, .{} },
        near: [2]Mv = .{ .{}, .{} },
        best: [2]Mv = .{ .{}, .{} },
    };

    fn block(ps: *Parse, r: u32, c: u32, bsize: u8) Error!void {
        if (ps.out.coef.len - ps.out.n_coef < max_block_words) try ps.growCoef();
        if (bsize >= common.BLOCK_8X8 and tables.ss_size_lookup[bsize][ps.ss_x][ps.ss_y] == tables.BLOCK_INVALID)
            return error.Corrupt;
        const index = ps.out.n_blocks;
        const b = &ps.out.blocks[index];
        ps.out.n_blocks += 1;
        b.* = .{ .row = @intCast(r), .col = @intCast(c), .size = bsize, .avail_l = c > ps.col_start };
        var x: Ctx = .{
            .r = r,
            .c = c,
            .avail_u = r > 0,
            .avail_l = c > ps.col_start,
            .above = null,
            .left = null,
            .above_ref = .{ common.INTRA_FRAME, common.NONE },
            .left_ref = .{ common.INTRA_FRAME, common.NONE },
        };
        if (x.avail_u) {
            x.above = &ps.out.blocks[ps.out.grid[(r - 1) * ps.mi_cols + c]];
            x.above_ref = x.above.?.ref_frame;
        }
        if (x.avail_l) {
            x.left = &ps.out.blocks[ps.out.grid[r * ps.mi_cols + c - 1]];
            x.left_ref = x.left.?.ref_frame;
        }
        if (ps.h.intra) {
            ps.intraFrameModeInfo(b, &x);
        } else {
            try ps.interFrameModeInfo(b, &x);
        }

        // Its 8x8s on screen.
        const bw = @min(tables.num_8x8_wide[bsize], ps.mi_cols - c);
        const bh = @min(tables.num_8x8_high[bsize], ps.mi_rows - r);
        const write_seg = ps.seg.enabled and ps.seg.update_map;
        for (0..bh) |y| {
            const row = (r + y) * ps.mi_cols + c;
            @memset(ps.out.grid[row .. row + bw], index);
            if (write_seg) @memset(ps.cur_seg[row .. row + bw], b.segment_id);
            if (!ps.h.intra) {
                @memset(ps.cur_mvs[row .. row + bw], .{
                    .ref_frame = b.ref_frame,
                    .mv = .{ b.mvs[0][3], b.mvs[1][3] },
                });
            }
        }

        b.coeffs = @intCast(ps.out.n_coef);
        const eobs = ps.residual(b);
        b.coded = !b.skip;
        if (b.is_inter and bsize >= common.BLOCK_8X8 and eobs == 0) b.skip = true;
        const mode_type: usize = if (b.y_mode >= common.NEARESTMV and b.y_mode != common.ZEROMV) 1 else 0;
        b.filter_level = ps.lvl[b.segment_id][@intCast(b.ref_frame[0])][mode_type];
    }

    fn growCoef(ps: *Parse) Error!void {
        const n = @max(ps.out.coef.len * 2, 64 * 1024);
        const new = ps.env.slice(i32, n) orelse return error.NoMemory;
        @memcpy(new[0..ps.out.n_coef], ps.out.coef[0..ps.out.n_coef]);
        ps.env.freeSlice(i32, ps.out.coef);
        ps.out.coef = new;
    }

    // Mode info (6.4.5 to 6.4.20).

    fn intraFrameModeInfo(ps: *Parse, b: *Block, x: *const Ctx) void {
        const sg = ps.seg;
        if (sg.enabled and sg.update_map) b.segment_id = ps.b.tree(&tables.segment_tree, &sg.tree_probs);
        ps.readSkip(b, x);
        b.tx_size = ps.readTxSize(b, x, true);
        b.ref_frame = .{ common.INTRA_FRAME, common.NONE };
        b.is_inter = false;
        if (b.size >= common.BLOCK_8X8) {
            const above = if (x.above) |a| a.sub_modes[2] else common.DC_PRED;
            const left = if (x.left) |l| l.sub_modes[1] else common.DC_PRED;
            b.y_mode = ps.b.tree(&tables.intra_mode_tree, &tables.kf_y_mode_probs[above][left]);
            b.sub_modes = @splat(b.y_mode);
        } else {
            const w = tables.num_4x4_wide[b.size];
            const hh = tables.num_4x4_high[b.size];
            var idy: usize = 0;
            while (idy < 2) : (idy += hh) {
                var idx: usize = 0;
                while (idx < 2) : (idx += w) {
                    const above = if (idy > 0) b.sub_modes[idx] else if (x.above) |a| a.sub_modes[2 + idx] else common.DC_PRED;
                    const left = if (idx > 0) b.sub_modes[idy * 2] else if (x.left) |l| l.sub_modes[1 + idy * 2] else common.DC_PRED;
                    const mode = ps.b.tree(&tables.intra_mode_tree, &tables.kf_y_mode_probs[above][left]);
                    setSubModes(b, idy, idx, hh, w, mode);
                    b.y_mode = mode;
                }
            }
        }
        b.uv_mode = ps.b.tree(&tables.intra_mode_tree, &tables.kf_uv_mode_probs[b.y_mode]);
    }

    fn setSubModes(b: *Block, idy: usize, idx: usize, hh: usize, w: usize, mode: u8) void {
        for (0..hh) |y2| {
            for (0..w) |x2| b.sub_modes[(idy + y2) * 2 + idx + x2] = mode;
        }
    }

    fn readSkip(ps: *Parse, b: *Block, x: *const Ctx) void {
        if (ps.seg.active(b.segment_id, common.SEG_LVL_SKIP)) {
            b.skip = true;
            return;
        }
        var ctx: usize = 0;
        if (x.above) |a| ctx += @intFromBool(a.skip);
        if (x.left) |l| ctx += @intFromBool(l.skip);
        const v = ps.read(ps.p.skip[ctx]);
        if (ps.count) ps.counts.skip[ctx][v] += 1;
        b.skip = v == 1;
    }

    fn readTxSize(ps: *Parse, b: *const Block, x: *const Ctx, allow_select: bool) u8 {
        const max_tx = tables.max_txsize[b.size];
        const tx_mode = ps.h.tx_mode;
        if (!allow_select or tx_mode != common.TX_MODE_SELECT or b.size < common.BLOCK_8X8)
            return @min(max_tx, tables.tx_mode_to_biggest_tx_size[tx_mode]);
        var above: u8 = max_tx;
        var left: u8 = max_tx;
        if (x.above) |a| {
            if (!a.skip) above = a.tx_size;
        }
        if (x.left) |l| {
            if (!l.skip) left = l.tx_size;
        }
        if (x.left == null) left = above;
        if (x.above == null) above = left;
        const ctx: usize = @intFromBool(above + left > max_tx);
        const p = ps.p;
        var tx: u8 = 0;
        switch (max_tx) {
            common.TX_8X8 => {
                tx = ps.read(p.tx8[ctx][0]);
                if (ps.count) ps.counts.tx8[ctx][tx] += 1;
            },
            common.TX_16X16 => {
                tx = ps.read(p.tx16[ctx][0]);
                if (tx != 0) tx += ps.read(p.tx16[ctx][1]);
                if (ps.count) ps.counts.tx16[ctx][tx] += 1;
            },
            else => {
                tx = ps.read(p.tx32[ctx][0]);
                if (tx != 0) {
                    tx += ps.read(p.tx32[ctx][1]);
                    if (tx != 1) tx += ps.read(p.tx32[ctx][2]);
                }
                if (ps.count) ps.counts.tx32[ctx][tx] += 1;
            },
        }
        return tx;
    }

    fn interFrameModeInfo(ps: *Parse, b: *Block, x: *Ctx) Error!void {
        b.segment_id = ps.interSegmentId(b, x);
        ps.readSkip(b, x);
        // Is inter (6.4.13).
        if (ps.seg.active(b.segment_id, common.SEG_LVL_REF_FRAME)) {
            b.is_inter = ps.seg.feature_data[b.segment_id][common.SEG_LVL_REF_FRAME] != common.INTRA_FRAME;
        } else {
            const left_intra = x.left_ref[0] <= common.INTRA_FRAME;
            const above_intra = x.above_ref[0] <= common.INTRA_FRAME;
            var ctx: usize = 0;
            if (x.avail_u and x.avail_l) {
                ctx = if (left_intra and above_intra) 3 else @intFromBool(left_intra or above_intra);
            } else if (x.avail_u or x.avail_l) {
                ctx = 2 * @as(usize, @intFromBool(if (x.avail_u) above_intra else left_intra));
            }
            const v = ps.read(ps.p.is_inter[ctx]);
            if (ps.count) ps.counts.is_inter[ctx][v] += 1;
            b.is_inter = v == 1;
        }
        b.tx_size = ps.readTxSize(b, x, !b.skip or !b.is_inter);
        if (b.is_inter) {
            try ps.interBlockModeInfo(b, x);
        } else {
            ps.intraBlockModeInfo(b);
        }
    }

    fn interSegmentId(ps: *Parse, b: *const Block, x: *const Ctx) u8 {
        const sg = ps.seg;
        if (!sg.enabled) return 0;
        // The smallest segment of the 8x8s on screen in the previous map.
        const bw = @min(tables.num_8x8_wide[b.size], ps.mi_cols - x.c);
        const bh = @min(tables.num_8x8_high[b.size], ps.mi_rows - x.r);
        var predicted: u8 = 7;
        for (0..bh) |y| {
            const row = (x.r + y) * ps.mi_cols + x.c;
            for (ps.prev_seg[row .. row + bw]) |s| predicted = @min(predicted, s);
        }
        if (!sg.update_map) return predicted;
        if (!sg.temporal_update) return ps.b.tree(&tables.segment_tree, &sg.tree_probs);
        const ctx = ps.left_seg[x.r & 7] + ps.above_seg[x.c];
        const flag = ps.read(sg.pred_probs[ctx]);
        const n8w = tables.num_8x8_wide[b.size];
        @memset(ps.above_seg[x.c .. x.c + n8w], flag);
        for (0..tables.num_8x8_high[b.size]) |i| ps.left_seg[(x.r + i) & 7] = flag;
        return if (flag == 1) predicted else ps.b.tree(&tables.segment_tree, &sg.tree_probs);
    }

    fn intraBlockModeInfo(ps: *Parse, b: *Block) void {
        const p = ps.p;
        b.ref_frame = .{ common.INTRA_FRAME, common.NONE };
        if (b.size >= common.BLOCK_8X8) {
            const ctx = tables.size_group[b.size];
            b.y_mode = ps.b.tree(&tables.intra_mode_tree, &p.y_mode[ctx]);
            if (ps.count) ps.counts.intra_mode[ctx][b.y_mode] += 1;
            b.sub_modes = @splat(b.y_mode);
        } else {
            const w = tables.num_4x4_wide[b.size];
            const hh = tables.num_4x4_high[b.size];
            var idy: usize = 0;
            while (idy < 2) : (idy += hh) {
                var idx: usize = 0;
                while (idx < 2) : (idx += w) {
                    const mode = ps.b.tree(&tables.intra_mode_tree, &p.y_mode[0]);
                    if (ps.count) ps.counts.intra_mode[0][mode] += 1;
                    setSubModes(b, idy, idx, hh, w, mode);
                    b.y_mode = mode;
                }
            }
        }
        b.uv_mode = ps.b.tree(&tables.intra_mode_tree, &p.uv_mode[b.y_mode]);
        if (ps.count) ps.counts.uv_mode[b.y_mode][b.uv_mode] += 1;
    }

    fn interBlockModeInfo(ps: *Parse, b: *Block, x: *Ctx) Error!void {
        const h = ps.h;
        try ps.readRefFrames(b, x);
        const compound = b.ref_frame[1] > common.INTRA_FRAME;
        const lists: usize = if (compound) 2 else 1;
        for (0..lists) |j| {
            var list = ps.findMvRefs(b, x, b.ref_frame[j], -1);
            for (&list) |*m| lowerPrecision(m, h.allow_hp);
            x.nearest[j] = list[0];
            x.near[j] = list[1];
            x.best[j] = list[0];
        }
        const mode_ctx = ps.modeContext(b, x);
        if (ps.seg.active(b.segment_id, common.SEG_LVL_SKIP)) {
            b.y_mode = common.ZEROMV;
            if (b.size < common.BLOCK_8X8) return error.Corrupt;
        } else if (b.size >= common.BLOCK_8X8) {
            b.y_mode = ps.readInterMode(mode_ctx);
        }
        if (h.interp_filter == common.SWITCHABLE) {
            const left: u8 = if (x.left != null and x.left_ref[0] > common.INTRA_FRAME) x.left.?.interp_filter else 3;
            const above: u8 = if (x.above != null and x.above_ref[0] > common.INTRA_FRAME) x.above.?.interp_filter else 3;
            const ctx: usize = if (left == above) left else if (left == 3) above else if (above == 3) left else 3;
            b.interp_filter = ps.b.tree(&tables.interp_filter_tree, &ps.p.interp_filter[ctx]);
            if (ps.count) ps.counts.interp_filter[ctx][b.interp_filter] += 1;
        } else {
            b.interp_filter = h.interp_filter;
        }
        if (b.size < common.BLOCK_8X8) {
            const w = tables.num_4x4_wide[b.size];
            const hh = tables.num_4x4_high[b.size];
            var idy: usize = 0;
            while (idy < 2) : (idy += hh) {
                var idx: usize = 0;
                while (idx < 2) : (idx += w) {
                    b.y_mode = ps.readInterMode(mode_ctx);
                    const k = idy * 2 + idx;
                    if (b.y_mode == common.NEARESTMV or b.y_mode == common.NEARMV) {
                        for (0..lists) |j| ps.appendSub8x8Mvs(b, x, k, j);
                    }
                    var mv: [2]Mv = undefined;
                    try ps.assignMv(b, x, &mv, compound);
                    for (0..hh) |y2| {
                        for (0..w) |x2| {
                            const n = (idy + y2) * 2 + idx + x2;
                            b.mvs[0][n] = mv[0];
                            b.mvs[1][n] = mv[1];
                        }
                    }
                }
            }
        } else {
            var mv: [2]Mv = undefined;
            try ps.assignMv(b, x, &mv, compound);
            b.mvs[0] = @splat(mv[0]);
            b.mvs[1] = @splat(mv[1]);
        }
    }

    fn readInterMode(ps: *Parse, ctx: usize) u8 {
        const v = ps.b.tree(&tables.inter_mode_tree, &ps.p.inter_mode[ctx]);
        if (ps.count) ps.counts.inter_mode[ctx][v] += 1;
        return common.NEARESTMV + v;
    }

    fn readRefFrames(ps: *Parse, b: *Block, x: *const Ctx) Error!void {
        const h = ps.h;
        const sg = ps.seg;
        if (sg.active(b.segment_id, common.SEG_LVL_REF_FRAME)) {
            const ref = sg.feature_data[b.segment_id][common.SEG_LVL_REF_FRAME];
            if (ref < common.LAST_FRAME or ref > common.ALTREF_FRAME) return error.Corrupt;
            b.ref_frame = .{ @intCast(ref), common.NONE };
            return;
        }
        var comp_mode = h.reference_mode;
        if (comp_mode == header.REFERENCE_MODE_SELECT) {
            const ctx = compModeCtx(h, x);
            const v = ps.read(ps.p.comp_mode[ctx]);
            if (ps.count) ps.counts.comp_mode[ctx][v] += 1;
            comp_mode = v;
        }
        if (comp_mode == header.COMPOUND_REFERENCE) {
            const idx: usize = @intFromBool(h.sign_bias[@intCast(h.comp_fixed_ref)]);
            const ctx = compRefCtx(h, x);
            const v = ps.read(ps.p.comp_ref[ctx]);
            if (ps.count) ps.counts.comp_ref[ctx][v] += 1;
            b.ref_frame[idx] = h.comp_fixed_ref;
            b.ref_frame[idx ^ 1] = h.comp_var_ref[v];
        } else {
            const ctx1 = singleRefP1Ctx(x);
            const v1 = ps.read(ps.p.single_ref[ctx1][0]);
            if (ps.count) ps.counts.single_ref[ctx1][0][v1] += 1;
            if (v1 == 1) {
                const ctx2 = singleRefP2Ctx(x);
                const v2 = ps.read(ps.p.single_ref[ctx2][1]);
                if (ps.count) ps.counts.single_ref[ctx2][1][v2] += 1;
                b.ref_frame[0] = if (v2 == 1) common.ALTREF_FRAME else common.GOLDEN_FRAME;
            } else {
                b.ref_frame[0] = common.LAST_FRAME;
            }
            b.ref_frame[1] = common.NONE;
        }
    }

    fn compModeCtx(h: *const header.Header, x: *const Ctx) usize {
        const a = x.above_ref;
        const l = x.left_ref;
        const fixed = h.comp_fixed_ref;
        const a_single = a[1] <= common.NONE;
        const l_single = l[1] <= common.NONE;
        if (x.avail_u and x.avail_l) {
            if (a_single and l_single) return @intFromBool((a[0] == fixed) != (l[0] == fixed));
            if (a_single) return 2 + @as(usize, @intFromBool(a[0] == fixed or a[0] <= common.INTRA_FRAME));
            if (l_single) return 2 + @as(usize, @intFromBool(l[0] == fixed or l[0] <= common.INTRA_FRAME));
            return 4;
        }
        if (x.avail_u) return if (a_single) @intFromBool(a[0] == fixed) else 3;
        if (x.avail_l) return if (l_single) @intFromBool(l[0] == fixed) else 3;
        return 1;
    }

    fn compRefCtx(h: *const header.Header, x: *const Ctx) usize {
        const a = x.above_ref;
        const l = x.left_ref;
        const fix_idx: usize = @intFromBool(h.sign_bias[@intCast(h.comp_fixed_ref)]);
        const var_idx = fix_idx ^ 1;
        const var0 = h.comp_var_ref[0];
        const var1 = h.comp_var_ref[1];
        const a_intra = a[0] <= common.INTRA_FRAME;
        const l_intra = l[0] <= common.INTRA_FRAME;
        const a_single = a[1] <= common.NONE;
        const l_single = l[1] <= common.NONE;
        if (x.avail_u and x.avail_l) {
            if (a_intra and l_intra) return 2;
            if (l_intra) {
                const v = if (a_single) a[0] else a[var_idx];
                return 1 + 2 * @as(usize, @intFromBool(v != var1));
            }
            if (a_intra) {
                const v = if (l_single) l[0] else l[var_idx];
                return 1 + 2 * @as(usize, @intFromBool(v != var1));
            }
            const vrfa = if (a_single) a[0] else a[var_idx];
            const vrfl = if (l_single) l[0] else l[var_idx];
            if (vrfa == vrfl and var1 == vrfa) return 0;
            if (l_single and a_single) {
                if ((vrfa == h.comp_fixed_ref and vrfl == var0) or (vrfl == h.comp_fixed_ref and vrfa == var0)) return 4;
                if (vrfa == vrfl) return 3;
                return 1;
            }
            if (l_single or a_single) {
                const vrfc = if (l_single) vrfa else vrfl;
                const rfs = if (a_single) vrfa else vrfl;
                if (vrfc == var1 and rfs != var1) return 1;
                if (rfs == var1 and vrfc != var1) return 2;
                return 4;
            }
            if (vrfa == vrfl) return 4;
            return 2;
        }
        if (x.avail_u) {
            if (a_intra) return 2;
            if (a_single) return 3 * @as(usize, @intFromBool(a[0] != var1));
            return 4 * @as(usize, @intFromBool(a[var_idx] != var1));
        }
        if (x.avail_l) {
            if (l_intra) return 2;
            if (l_single) return 3 * @as(usize, @intFromBool(l[0] != var1));
            return 4 * @as(usize, @intFromBool(l[var_idx] != var1));
        }
        return 2;
    }

    fn singleRefP1Ctx(x: *const Ctx) usize {
        const LAST = common.LAST_FRAME;
        const a = x.above_ref;
        const l = x.left_ref;
        const a_intra = a[0] <= common.INTRA_FRAME;
        const l_intra = l[0] <= common.INTRA_FRAME;
        const a_single = a[1] <= common.NONE;
        const l_single = l[1] <= common.NONE;
        if (x.avail_u and x.avail_l) {
            if (a_intra and l_intra) return 2;
            if (l_intra) {
                if (a_single) return 4 * @as(usize, @intFromBool(a[0] == LAST));
                return 1 + @as(usize, @intFromBool(a[0] == LAST or a[1] == LAST));
            }
            if (a_intra) {
                if (l_single) return 4 * @as(usize, @intFromBool(l[0] == LAST));
                return 1 + @as(usize, @intFromBool(l[0] == LAST or l[1] == LAST));
            }
            if (a_single and l_single) return 2 * @as(usize, @intFromBool(a[0] == LAST)) + 2 * @as(usize, @intFromBool(l[0] == LAST));
            if (!a_single and !l_single) return 1 + @as(usize, @intFromBool(a[0] == LAST or a[1] == LAST or l[0] == LAST or l[1] == LAST));
            const rfs = if (a_single) a[0] else l[0];
            const crf1 = if (a_single) l[0] else a[0];
            const crf2 = if (a_single) l[1] else a[1];
            if (rfs == LAST) return 3 + @as(usize, @intFromBool(crf1 == LAST or crf2 == LAST));
            return @intFromBool(crf1 == LAST or crf2 == LAST);
        }
        if (x.avail_u) {
            if (a_intra) return 2;
            if (a_single) return 4 * @as(usize, @intFromBool(a[0] == LAST));
            return 1 + @as(usize, @intFromBool(a[0] == LAST or a[1] == LAST));
        }
        if (x.avail_l) {
            if (l_intra) return 2;
            if (l_single) return 4 * @as(usize, @intFromBool(l[0] == LAST));
            return 1 + @as(usize, @intFromBool(l[0] == LAST or l[1] == LAST));
        }
        return 2;
    }

    fn singleRefP2Ctx(x: *const Ctx) usize {
        const LAST = common.LAST_FRAME;
        const GOLDEN = common.GOLDEN_FRAME;
        const a = x.above_ref;
        const l = x.left_ref;
        const a_intra = a[0] <= common.INTRA_FRAME;
        const l_intra = l[0] <= common.INTRA_FRAME;
        const a_single = a[1] <= common.NONE;
        const l_single = l[1] <= common.NONE;
        if (x.avail_u and x.avail_l) {
            if (a_intra and l_intra) return 2;
            if (l_intra) {
                if (a_single) {
                    if (a[0] == LAST) return 3;
                    return 4 * @as(usize, @intFromBool(a[0] == GOLDEN));
                }
                return 1 + 2 * @as(usize, @intFromBool(a[0] == GOLDEN or a[1] == GOLDEN));
            }
            if (a_intra) {
                if (l_single) {
                    if (l[0] == LAST) return 3;
                    return 4 * @as(usize, @intFromBool(l[0] == GOLDEN));
                }
                return 1 + 2 * @as(usize, @intFromBool(l[0] == GOLDEN or l[1] == GOLDEN));
            }
            if (a_single and l_single) {
                if (a[0] == LAST and l[0] == LAST) return 3;
                if (a[0] == LAST) return 4 * @as(usize, @intFromBool(l[0] == GOLDEN));
                if (l[0] == LAST) return 4 * @as(usize, @intFromBool(a[0] == GOLDEN));
                return 2 * @as(usize, @intFromBool(a[0] == GOLDEN)) + 2 * @as(usize, @intFromBool(l[0] == GOLDEN));
            }
            if (!a_single and !l_single) {
                if (a[0] == l[0] and a[1] == l[1]) return 3 * @as(usize, @intFromBool(a[0] == GOLDEN or a[1] == GOLDEN));
                return 2;
            }
            const rfs = if (a_single) a[0] else l[0];
            const crf1 = if (a_single) l[0] else a[0];
            const crf2 = if (a_single) l[1] else a[1];
            const golden: usize = @intFromBool(crf1 == GOLDEN or crf2 == GOLDEN);
            if (rfs == GOLDEN) return 3 + golden;
            if (rfs == common.ALTREF_FRAME) return golden;
            return 1 + 2 * golden;
        }
        if (x.avail_u) {
            if (a_intra or (a[0] == LAST and a_single)) return 2;
            if (a_single) return 4 * @as(usize, @intFromBool(a[0] == GOLDEN));
            return 3 * @as(usize, @intFromBool(a[0] == GOLDEN or a[1] == GOLDEN));
        }
        if (x.avail_l) {
            if (l_intra or (l[0] == LAST and l_single)) return 2;
            if (l_single) return 4 * @as(usize, @intFromBool(l[0] == GOLDEN));
            return 3 * @as(usize, @intFromBool(l[0] == GOLDEN or l[1] == GOLDEN));
        }
        return 2;
    }

    // Motion vector prediction (6.5).

    fn isInside(ps: *const Parse, x: *const Ctx, pos: [2]i8) ?*const Block {
        const r = @as(i64, x.r) + pos[0];
        const c = @as(i64, x.c) + pos[1];
        if (r < 0 or r >= ps.mi_rows or c < ps.col_start or c >= ps.col_end) return null;
        return &ps.out.blocks[ps.out.grid[@as(usize, @intCast(r)) * ps.mi_cols + @as(usize, @intCast(c))]];
    }

    /// The context the inter modes are read in: the modes of the two
    /// nearest candidates.
    fn modeContext(ps: *const Parse, b: *const Block, x: *const Ctx) usize {
        const search = &tables.mv_ref_blocks[b.size];
        var counter: usize = 0;
        for (search[0..2]) |pos| {
            if (ps.isInside(x, pos)) |cand| counter += tables.mode_2_counter[cand.y_mode];
        }
        return tables.counter_to_context[counter];
    }

    const List = struct {
        mv: [2]Mv = .{ .{}, .{} },
        n: u8 = 0,

        fn add(l: *List, m: Mv) void {
            if (l.n >= 2) return;
            if (l.n > 0 and m.eql(l.mv[0])) return;
            l.mv[l.n] = m;
            l.n += 1;
        }
    };

    fn scaled(ps: *const Parse, m: Mv, cand: i8, ref: i8) Mv {
        const sb = &ps.h.sign_bias;
        if (sb[@intCast(cand)] != sb[@intCast(ref)]) return .{ .row = -%m.row, .col = -%m.col };
        return m;
    }

    /// The two candidate vectors for `ref`, clamped (6.5.1); `sub` is the
    /// 4x4 of a block under 8x8 they are for, or -1 for the block.
    fn findMvRefs(ps: *const Parse, b: *const Block, x: *const Ctx, ref: i8, sub: i8) [2]Mv {
        const search = &tables.mv_ref_blocks[b.size];
        var list: List = .{};
        var found = false;
        const prev: ?*const MvRef = if (ps.use_prev_mvs) &ps.prev_mvs[x.r * ps.mi_cols + x.c] else null;
        done: {
            for (search, 0..) |pos, i| {
                const cand = ps.isInside(x, pos) orelse continue;
                found = true;
                for (0..2) |j| {
                    if (cand.ref_frame[j] == ref) {
                        const k: usize = if (i < 2 and sub >= 0)
                            tables.idx_n_column_to_subblock[@intCast(sub)][@intFromBool(pos[1] == 0)]
                        else
                            3;
                        list.add(cand.mvs[j][k]);
                        break;
                    }
                }
                if (list.n == 2) break :done;
            }
            if (prev) |pv| {
                for (0..2) |j| {
                    if (pv.ref_frame[j] == ref) {
                        list.add(pv.mv[j]);
                        break;
                    }
                }
                if (list.n == 2) break :done;
            }
            if (found) {
                for (search) |pos| {
                    const cand = ps.isInside(x, pos) orelse continue;
                    ps.addDifferent(&list, cand.ref_frame, .{ cand.mvs[0][3], cand.mvs[1][3] }, ref);
                    if (list.n == 2) break :done;
                }
            }
            if (prev) |pv| ps.addDifferent(&list, pv.ref_frame, pv.mv, ref);
        }
        for (&list.mv) |*m| ps.clampMv(m, b, x, 16 << 3);
        return list.mv;
    }

    fn addDifferent(ps: *const Parse, list: *List, refs: [2]i8, mvs: [2]Mv, ref: i8) void {
        const same = mvs[0].eql(mvs[1]);
        if (refs[0] > common.INTRA_FRAME and refs[0] != ref) list.add(ps.scaled(mvs[0], refs[0], ref));
        if (refs[1] > common.INTRA_FRAME and refs[1] != ref and !same) list.add(ps.scaled(mvs[1], refs[1], ref));
    }

    fn clampMv(ps: *const Parse, m: *Mv, b: *const Block, x: *const Ctx, border: i32) void {
        const bh: i32 = tables.num_8x8_high[b.size];
        const bw: i32 = tables.num_8x8_wide[b.size];
        const r: i32 = @intCast(x.r);
        const c: i32 = @intCast(x.c);
        const top = -(r * 64) - border;
        const bottom = (@as(i32, @intCast(ps.mi_rows)) - bh - r) * 64 + border;
        const left = -(c * 64) - border;
        const right = (@as(i32, @intCast(ps.mi_cols)) - bw - c) * 64 + border;
        m.row = @intCast(clamp(m.row, top, bottom));
        m.col = @intCast(clamp(m.col, left, right));
    }

    fn appendSub8x8Mvs(ps: *const Parse, b: *const Block, x: *Ctx, k: usize, j: usize) void {
        const list = ps.findMvRefs(b, x, b.ref_frame[j], @intCast(k));
        var out: [2]Mv = .{ .{}, .{} };
        var n: usize = 0;
        if (k == 0) {
            out = list;
            n = 2;
        } else if (k <= 2) {
            out[0] = b.mvs[j][0];
            n = 1;
        } else {
            out[0] = b.mvs[j][2];
            n = 1;
            var idx: usize = 2;
            while (idx > 0 and n < 2) {
                idx -= 1;
                if (!b.mvs[j][idx].eql(out[0])) {
                    out[n] = b.mvs[j][idx];
                    n += 1;
                }
            }
        }
        for (list) |m| {
            if (n < 2 and !m.eql(out[0])) {
                out[n] = m;
                n += 1;
            }
        }
        if (n < 2) out[n] = .{};
        x.nearest[j] = out[0];
        x.near[j] = out[1];
    }

    fn assignMv(ps: *Parse, b: *const Block, x: *const Ctx, mv: *[2]Mv, compound: bool) Error!void {
        mv[1] = .{};
        for (0..@as(usize, if (compound) 2 else 1)) |i| {
            mv[i] = switch (b.y_mode) {
                common.NEWMV => try ps.readMv(x.best[i]),
                common.NEARESTMV => x.nearest[i],
                common.NEARMV => x.near[i],
                else => .{},
            };
        }
    }

    fn readMv(ps: *Parse, best: Mv) Error!Mv {
        const p = ps.p;
        const use_hp = ps.h.allow_hp and useHp(best);
        const joint = ps.b.tree(&tables.mv_joint_tree, &p.mv_joint);
        if (ps.count) ps.counts.mv_joint[joint] += 1;
        var diff: [2]i32 = .{ 0, 0 };
        if (joint == 2 or joint == 3) diff[0] = ps.readMvComponent(0, use_hp);
        if (joint == 1 or joint == 3) diff[1] = ps.readMvComponent(1, use_hp);
        const row = best.row + diff[0];
        const col = best.col + diff[1];
        const lim = 1 << 14;
        if (row <= -lim or row >= lim or col <= -lim or col >= lim) return error.Corrupt;
        return .{ .row = @intCast(row), .col = @intCast(col) };
    }

    fn readMvComponent(ps: *Parse, comp: usize, use_hp: bool) i32 {
        const p = ps.p;
        const sign = ps.read(p.mv_sign[comp]);
        const class = ps.b.tree(&tables.mv_class_tree, &p.mv_class[comp]);
        var mag: i32 = 0;
        var d: u32 = 0;
        var fr: u8 = 0;
        var hp: u1 = 1;
        if (class == 0) {
            d = ps.read(p.mv_class0_bit[comp]);
            fr = ps.b.tree(&tables.mv_fr_tree, &p.mv_class0_fr[comp][d]);
            if (use_hp) hp = ps.read(p.mv_class0_hp[comp]);
        } else {
            for (0..class) |i| d |= @as(u32, ps.read(p.mv_bits[comp][i])) << @intCast(i);
            mag = @as(i32, 2) << @intCast(class + 2);
            fr = ps.b.tree(&tables.mv_fr_tree, &p.mv_fr[comp]);
            if (use_hp) hp = ps.read(p.mv_hp[comp]);
        }
        if (ps.count) {
            const c = ps.counts;
            c.mv_sign[comp][sign] += 1;
            c.mv_class[comp][class] += 1;
            if (class == 0) {
                c.mv_class0_bit[comp][d] += 1;
                c.mv_class0_fr[comp][d][fr] += 1;
                c.mv_class0_hp[comp][hp] += 1;
            } else {
                for (0..class) |i| c.mv_bits[comp][i][(d >> @intCast(i)) & 1] += 1;
                c.mv_fr[comp][fr] += 1;
                c.mv_hp[comp][hp] += 1;
            }
        }
        mag += @as(i32, @intCast((d << 3) | (@as(u32, fr) << 1) | hp)) + 1;
        return if (sign == 1) -mag else mag;
    }

    // Coefficients (6.4.21 to 6.4.26).

    /// The block's coefficients into `coef`; how many transform blocks
    /// have any.
    fn residual(ps: *Parse, b: *Block) u32 {
        const bsize = @max(b.size, common.BLOCK_8X8);
        var eobs: u32 = 0;
        for (0..3) |plane| {
            const sx: u5 = if (plane > 0) ps.ss_x else 0;
            const sy: u5 = if (plane > 0) ps.ss_y else 0;
            const tx = if (plane == 0) b.tx_size else uvTxSize(b, ps.ss_x, ps.ss_y);
            const step = @as(u32, 1) << @intCast(tx);
            const plane_size = tables.ss_size_lookup[bsize][sx][sy];
            const w4: u32 = tables.num_4x4_wide[plane_size];
            const h4: u32 = tables.num_4x4_high[plane_size];
            const base_x4 = (@as(u32, b.col) * 2) >> sx;
            const base_y4 = (@as(u32, b.row) * 2) >> sy;
            const above = ps.above_nz[plane];
            const left = &ps.left_nz[plane];
            if (b.skip) {
                @memset(above[base_x4 .. base_x4 + w4], 0);
                for (0..h4) |i| left[(base_y4 + i) & 15] = 0;
                continue;
            }
            const max_x4 = (ps.mi_cols * 2) >> sx;
            const max_y4 = (ps.mi_rows * 2) >> sy;
            var y: u32 = 0;
            var k: usize = 0;
            while (y < h4) : (y += step) {
                var x: u32 = 0;
                while (x < w4) : (x += step) {
                    const x4 = base_x4 + x;
                    const y4 = base_y4 + y;
                    var nonzero: u8 = 0;
                    if (x4 < max_x4 and y4 < max_y4) {
                        var a: u8 = 0;
                        var l: u8 = 0;
                        for (0..step) |i| {
                            if (x4 + i < max_x4) a |= above[x4 + i];
                            if (y4 + i < max_y4) l |= left[(y4 + i) & 15];
                        }
                        const tx_type = txType(b, plane, tx, k, ps.h.lossless);
                        const eob = ps.tokens(b, plane, tx, tx_type, a + l);
                        nonzero = @intFromBool(eob > 0);
                        eobs += nonzero;
                    }
                    @memset(above[x4 .. x4 + step], nonzero);
                    for (0..step) |i| left[(y4 + i) & 15] = nonzero;
                    k += 1;
                }
            }
        }
        return eobs;
    }

    pub fn uvTxSize(b: *const Block, ss_x: u1, ss_y: u1) u8 {
        if (b.size < common.BLOCK_8X8) return common.TX_4X4;
        return @min(b.tx_size, tables.max_txsize[tables.ss_size_lookup[b.size][ss_x][ss_y]]);
    }

    /// The transform type of transform block `k` (raster order) of
    /// `plane` (6.4.25).
    pub fn txType(b: *const Block, plane: usize, tx: u8, k: usize, lossless: bool) u8 {
        if (plane > 0 or tx == common.TX_32X32) return tables.DCT_DCT;
        if (tx == common.TX_4X4) {
            if (lossless or b.is_inter) return tables.DCT_DCT;
            return tables.mode2txfm[if (b.size < common.BLOCK_8X8) b.sub_modes[k] else b.y_mode];
        }
        return tables.mode2txfm[b.y_mode];
    }

    fn tokens(ps: *Parse, b: *const Block, plane: usize, tx: u8, tx_type: u8, ctx0: u8) u32 {
        const scan = scanOf(tx, tx_type);
        const nb = neighbours(tx, tx_type);
        const bands: []const u8 = if (tx == common.TX_4X4) &tables.coefband_4x4 else &tables.coefband_8x8plus;
        const ref: usize = @intFromBool(b.is_inter);
        const pt: usize = @intFromBool(plane > 0);
        const cp = &ps.p.coef[tx][pt][ref];
        const ct = &ps.counts.token[tx][pt][ref];
        const cm = &ps.counts.more_coefs[tx][pt][ref];
        const dq = ps.dq[b.segment_id][pt];
        const shift: u5 = @intFromBool(tx == common.TX_32X32);
        const max_eob = @as(u32, 16) << @intCast(tx * 2);
        const out = ps.out.coef[ps.out.n_coef + 1 ..];
        const cache = &ps.token_cache;
        const bd = ps.bit_depth;
        const br = &ps.b;
        const count = ps.count;
        var c: u32 = 0;
        var ctx: usize = ctx0;
        var dqv: i64 = dq[0];
        outer: while (c < max_eob) {
            var band = bands[c];
            var prob = &cp[band][ctx];
            const more = br.read(prob[0]);
            if (count) cm[band][ctx][more] += 1;
            if (more == 0) break;
            while (br.read(prob[1]) == 0) {
                if (count) ct[band][ctx][0] += 1;
                cache[scan[c]] = 0;
                out[c] = 0;
                dqv = dq[1];
                c += 1;
                if (c >= max_eob) break :outer;
                ctx = (1 + @as(usize, cache[nb[c][0]]) + cache[nb[c][1]]) >> 1;
                band = bands[c];
                prob = &cp[band][ctx];
            }
            var val: u32 = 1;
            if (br.read(prob[2]) == 0) {
                if (count) ct[band][ctx][1] += 1;
                cache[scan[c]] = 1;
            } else {
                if (count) ct[band][ctx][2] += 1;
                const p = &tables.pareto_full[prob[2]];
                if (br.read(p[0]) == 1) {
                    if (br.read(p[3]) == 1) {
                        cache[scan[c]] = 5;
                        if (br.read(p[5]) == 1) {
                            if (br.read(p[7]) == 1) {
                                // The bits above 8 bits' first.
                                var high: u32 = 0;
                                for (0..bd - 8) |_| high = (high << 1) | br.read(255);
                                val = 67 + ((high << 14) | extra(br, &tables.cat_probs[6], 14));
                            } else {
                                val = 35 + extra(br, &tables.cat_probs[5], 5);
                            }
                        } else if (br.read(p[6]) == 1) {
                            val = 19 + extra(br, &tables.cat_probs[4], 4);
                        } else {
                            val = 11 + extra(br, &tables.cat_probs[3], 3);
                        }
                    } else {
                        cache[scan[c]] = 4;
                        if (br.read(p[4]) == 1) {
                            val = 7 + extra(br, &tables.cat_probs[2], 2);
                        } else {
                            val = 5 + extra(br, &tables.cat_probs[1], 1);
                        }
                    }
                } else if (br.read(p[1]) == 1) {
                    cache[scan[c]] = 3;
                    val = 3 + @as(u32, br.read(p[2]));
                } else {
                    cache[scan[c]] = 2;
                    val = 2;
                }
            }
            const v: i32 = @truncate((@as(i64, val) * dqv) >> shift);
            out[c] = if (br.read(128) == 1) -%v else v;
            c += 1;
            dqv = dq[1];
            if (c < max_eob) ctx = (1 + @as(usize, cache[nb[c][0]]) + cache[nb[c][1]]) >> 1;
        }
        ps.out.coef[ps.out.n_coef] = @intCast(c);
        ps.out.n_coef += 1 + c;
        return c;
    }

    fn extra(br: *Bool, p: []const u8, n: usize) u32 {
        var v: u32 = 0;
        for (p[0..n]) |q| v = (v << 1) | br.read(q);
        return v;
    }
};

fn clamp(v: i32, lo: i32, hi: i32) i32 {
    return @max(lo, @min(hi, v));
}

fn useHp(m: Mv) bool {
    return (@abs(m.row) >> 3) < 8 and (@abs(m.col) >> 3) < 8;
}

fn lowerPrecision(m: *Mv, allow_hp: bool) void {
    if (allow_hp and useHp(m.*)) return;
    if (m.row & 1 != 0) m.row += if (m.row > 0) -1 else 1;
    if (m.col & 1 != 0) m.col += if (m.col > 0) -1 else 1;
}

/// The scan of a transform size and type.
pub fn scanOf(tx: u8, tx_type: u8) []const u16 {
    return switch (tx) {
        common.TX_4X4 => switch (tx_type) {
            tables.ADST_DCT => &tables.row_scan_4x4,
            tables.DCT_ADST => &tables.col_scan_4x4,
            else => &tables.default_scan_4x4,
        },
        common.TX_8X8 => switch (tx_type) {
            tables.ADST_DCT => &tables.row_scan_8x8,
            tables.DCT_ADST => &tables.col_scan_8x8,
            else => &tables.default_scan_8x8,
        },
        common.TX_16X16 => switch (tx_type) {
            tables.ADST_DCT => &tables.row_scan_16x16,
            tables.DCT_ADST => &tables.col_scan_16x16,
            else => &tables.default_scan_16x16,
        },
        else => &tables.default_scan_32x32,
    };
}

/// For each place in a scan, the positions of the two coefficients its
/// context comes from (9.3.2, more_coefs).
fn Neighbours(comptime n: usize) type {
    return [n * n][2]u16;
}

fn makeNeighbours(comptime tx: u8, comptime tx_type: u8) Neighbours(4 << tx) {
    @setEvalBranchQuota(100000);
    const n: u16 = 4 << tx;
    const scan = scanOf(tx, tx_type);
    var nb: Neighbours(n) = undefined;
    nb[0] = .{ 0, 0 };
    for (1..n * n) |c| {
        const pos = scan[c];
        const i = pos / n;
        const j = pos % n;
        if (i > 0 and j > 0) {
            const a = (i - 1) * n + j;
            const a2 = i * n + j - 1;
            nb[c] = switch (tx_type) {
                tables.DCT_ADST => .{ a, a },
                tables.ADST_DCT => .{ a2, a2 },
                else => .{ a, a2 },
            };
        } else if (i > 0) {
            nb[c] = .{ (i - 1) * n + j, (i - 1) * n + j };
        } else {
            nb[c] = .{ j - 1, j - 1 };
        }
    }
    return nb;
}

const nb_4x4 = [3]Neighbours(4){ makeNeighbours(0, tables.DCT_DCT), makeNeighbours(0, tables.ADST_DCT), makeNeighbours(0, tables.DCT_ADST) };
const nb_8x8 = [3]Neighbours(8){ makeNeighbours(1, tables.DCT_DCT), makeNeighbours(1, tables.ADST_DCT), makeNeighbours(1, tables.DCT_ADST) };
const nb_16x16 = [3]Neighbours(16){ makeNeighbours(2, tables.DCT_DCT), makeNeighbours(2, tables.ADST_DCT), makeNeighbours(2, tables.DCT_ADST) };
const nb_32x32 = makeNeighbours(3, tables.DCT_DCT);

fn neighbours(tx: u8, tx_type: u8) []const [2]u16 {
    // ADST_ADST scans and contexts as DCT_DCT.
    const t: usize = if (tx_type == tables.ADST_ADST) 0 else tx_type;
    return switch (tx) {
        common.TX_4X4 => &nb_4x4[t],
        common.TX_8X8 => &nb_8x8[t],
        common.TX_16X16 => &nb_16x16[t],
        else => &nb_32x32,
    };
}
