// SPDX-License-Identifier: MIT
//! The motion vector prediction (7.9 and 7.10): the frame's projected
//! motion field, each inter block's stack of candidate vectors and the
//! contexts its modes are read by, whether it may overlap its
//! neighbours' predictions, and the samples and least squares fit of a
//! local warp.

const common = @import("common.zig");
const tables = @import("tables.zig");
const parse = @import("parse.zig");
const warp = @import("warp.zig");
const Mv = common.Mv;
const Parse = parse.Parse;

const MAX_STACK = 8;
const REF_CAT_LEVEL = 640;
const MV_BORDER = 128;
const MAX_FRAME_DISTANCE = 31;
const MFMV_STACK_SIZE = 3;
const MAX_OFFSET_WIDTH = 8;
const MAX_OFFSET_HEIGHT = 0;
const LS_MV_MAX = 256;
const SAMPLES_MAX = 8;
const INVALID: i16 = -32768;

/// A block's candidates and the contexts they give.
pub const State = struct {
    stack: [MAX_STACK][2]Mv = undefined,
    weight: [MAX_STACK]u32 = undefined,
    num_found: u32 = 0,
    new_count: u32 = 0,
    global: [2]Mv = .{ .{}, .{} },
    found_match: bool = false,
    close_matches: u32 = 0,
    total_matches: u32 = 0,
    new_mv_ctx: u32 = 0,
    ref_mv_ctx: u32 = 0,
    zero_mv_ctx: u32 = 0,
    drl_ctx: [MAX_STACK]u8 = undefined,
    ref_mv_idx: u32 = 0,
    /// The local warp's samples.
    num_samples: u32 = 0,
    num_scanned: u32 = 0,
    cand: [SAMPLES_MAX][4]i32 = undefined,
};

fn isInside(ps: *const Parse, r: i64, c: i64) bool {
    return c >= ps.col_start and c < ps.col_end and r >= ps.row_start and r < ps.row_end;
}

fn blockAt(ps: *const Parse, r: i64, c: i64) *const parse.Block {
    return ps.out.block(@intCast(r), @intCast(c));
}

fn written(ps: *const Parse, r: i64, c: i64) bool {
    return ps.out.mi[@as(usize, @intCast(r)) * ps.out.mi_cols + @as(usize, @intCast(c))] != parse.NO_BLOCK;
}

fn lowerPrecision(ps: *const Parse, m: *Mv) void {
    const h = ps.h;
    if (h.allow_high_precision_mv) return;
    inline for (.{ &m.row, &m.col }) |v| {
        if (h.force_integer_mv) {
            const a: i32 = @abs(v.*);
            const a_int = (a + 3) >> 3;
            v.* = @intCast(if (v.* > 0) a_int << 3 else -(a_int << 3));
        } else if (v.* & 1 != 0) {
            v.* += if (v.* > 0) -1 else 1;
        }
    }
}

/// setup_global_mv for `list`.
fn globalMv(ps: *const Parse, list: usize) Mv {
    const b = &ps.b;
    const h = ps.h;
    const ref = b.ref[list];
    var m: Mv = .{};
    const typ = if (ref > common.INTRA_FRAME) h.gm_type[@intCast(ref)] else common.IDENTITY;
    if (ref == common.INTRA_FRAME or ref == common.NONE or typ == common.IDENTITY) {
        m = .{};
    } else if (typ == common.TRANSLATION) {
        const g = &h.gm_params[@intCast(ref)];
        m = .{ .row = @intCast(g[0] >> (warp.PREC_BITS - 3)), .col = @intCast(g[1] >> (warp.PREC_BITS - 3)) };
    } else {
        const g = &h.gm_params[@intCast(ref)];
        const x: i64 = @as(i64, b.col) * 4 + parse.blockWidth(b.size) / 2 - 1;
        const y: i64 = @as(i64, b.row) * 4 + parse.blockHeight(b.size) / 2 - 1;
        const one: i64 = 1 << warp.PREC_BITS;
        const xc = (g[2] - one) * x + g[3] * y + g[0];
        const yc = g[4] * x + (g[5] - one) * y + g[1];
        if (h.allow_high_precision_mv) {
            m = .{ .row = @intCast(common.round2Signed(yc, warp.PREC_BITS - 3)), .col = @intCast(common.round2Signed(xc, warp.PREC_BITS - 3)) };
        } else {
            m = .{ .row = @intCast(common.round2Signed(yc, warp.PREC_BITS - 2) * 2), .col = @intCast(common.round2Signed(xc, warp.PREC_BITS - 2) * 2) };
        }
    }
    lowerPrecision(ps, &m);
    return m;
}

fn hasNewmv(mode: u8) bool {
    return mode == common.NEWMV or mode == common.NEW_NEWMV or mode == common.NEAR_NEWMV or
        mode == common.NEW_NEARMV or mode == common.NEAREST_NEWMV or mode == common.NEW_NEARESTMV;
}

/// find_mv_stack (7.10.2).
pub fn findMvStack(ps: *Parse, compound: bool) void {
    const b = &ps.b;
    const st = &ps.mv;
    const bw4: u32 = tables.num_4x4_blocks_wide[b.size];
    const bh4: u32 = tables.num_4x4_blocks_high[b.size];
    st.num_found = 0;
    st.new_count = 0;
    st.global[0] = globalMv(ps, 0);
    if (compound) st.global[1] = globalMv(ps, 1);
    st.found_match = false;
    scanRow(ps, -1, compound);
    var found_above = st.found_match;
    st.found_match = false;
    scanCol(ps, -1, compound);
    var found_left = st.found_match;
    st.found_match = false;
    if (@max(bw4, bh4) <= 16) scanPoint(ps, -1, @intCast(bw4), compound);
    if (st.found_match) found_above = true;
    st.close_matches = @as(u32, @intFromBool(found_above)) + @intFromBool(found_left);
    const num_nearest = st.num_found;
    const num_new = st.new_count;
    for (0..num_nearest) |i| st.weight[i] += REF_CAT_LEVEL;
    st.zero_mv_ctx = 0;
    if (ps.h.use_ref_frame_mvs) temporalScan(ps, compound);
    st.found_match = false;
    scanPoint(ps, -1, -1, compound);
    if (st.found_match) found_above = true;
    st.found_match = false;
    scanRow(ps, -3, compound);
    if (st.found_match) found_above = true;
    st.found_match = false;
    scanCol(ps, -3, compound);
    if (st.found_match) found_left = true;
    st.found_match = false;
    if (bh4 > 1) scanRow(ps, -5, compound);
    if (st.found_match) found_above = true;
    st.found_match = false;
    if (bw4 > 1) scanCol(ps, -5, compound);
    if (st.found_match) found_left = true;
    st.total_matches = @as(u32, @intFromBool(found_above)) + @intFromBool(found_left);
    sort(st, 0, num_nearest, compound);
    sort(st, num_nearest, st.num_found, compound);
    if (st.num_found < 2) extraSearch(ps, compound);

    // Context and clamping.
    for (0..st.num_found) |i| {
        var z: u8 = 0;
        if (i + 1 < st.num_found) {
            const w0 = st.weight[i];
            const w1 = st.weight[i + 1];
            if (w0 >= REF_CAT_LEVEL) {
                if (w1 < REF_CAT_LEVEL) z = 1;
            } else {
                z = 2;
            }
        }
        st.drl_ctx[i] = z;
    }
    const lists: usize = if (compound) 2 else 1;
    const bw: i32 = @intCast(parse.blockWidth(b.size));
    const bh: i32 = @intCast(parse.blockHeight(b.size));
    for (0..lists) |list| {
        for (0..st.num_found) |i| {
            const m = &st.stack[i][list];
            m.row = @intCast(clampRow(ps, m.row, MV_BORDER + bh * 8));
            m.col = @intCast(clampCol(ps, m.col, MV_BORDER + bw * 8));
        }
    }
    if (st.close_matches == 0) {
        st.new_mv_ctx = @as(u32, @min(st.total_matches, 1));
        st.ref_mv_ctx = st.total_matches;
    } else if (st.close_matches == 1) {
        st.new_mv_ctx = 3 - @as(u32, @min(num_new, 1));
        st.ref_mv_ctx = 2 + st.total_matches;
    } else {
        st.new_mv_ctx = 5 - @as(u32, @min(num_new, 1));
        st.ref_mv_ctx = 5;
    }
}

fn clampRow(ps: *const Parse, v: i32, border: i32) i32 {
    const b = &ps.b;
    const bh4: i32 = tables.num_4x4_blocks_high[b.size];
    const top: i32 = -@as(i32, @intCast(b.row * 4 * 8));
    const bottom: i32 = (@as(i32, @intCast(ps.out.mi_rows)) - bh4 - @as(i32, @intCast(b.row))) * 4 * 8;
    return common.clip3(top - border, bottom + border, v);
}

fn clampCol(ps: *const Parse, v: i32, border: i32) i32 {
    const b = &ps.b;
    const bw4: i32 = tables.num_4x4_blocks_wide[b.size];
    const left: i32 = -@as(i32, @intCast(b.col * 4 * 8));
    const right: i32 = (@as(i32, @intCast(ps.out.mi_cols)) - bw4 - @as(i32, @intCast(b.col))) * 4 * 8;
    return common.clip3(left - border, right + border, v);
}

fn scanRow(ps: *Parse, delta_row_in: i32, compound: bool) void {
    const b = &ps.b;
    const bw4: u32 = tables.num_4x4_blocks_wide[b.size];
    const end4 = @min(@min(bw4, ps.out.mi_cols - b.col), 16);
    var delta_row: i64 = delta_row_in;
    var delta_col: i64 = 0;
    const step16 = bw4 >= 16;
    if (@abs(delta_row_in) > 1) {
        delta_row += b.row & 1;
        delta_col = 1 - @as(i64, b.col & 1);
    }
    var i: u32 = 0;
    while (i < end4) {
        const r = @as(i64, b.row) + delta_row;
        const c = @as(i64, b.col) + delta_col + i;
        if (!isInside(ps, r, c)) break;
        var len: u32 = @min(bw4, tables.num_4x4_blocks_wide[blockAt(ps, r, c).size]);
        if (@abs(delta_row_in) > 1) len = @max(2, len);
        if (step16) len = @max(4, len);
        addRefMvCandidate(ps, r, c, compound, len * 2);
        i += len;
    }
}

fn scanCol(ps: *Parse, delta_col_in: i32, compound: bool) void {
    const b = &ps.b;
    const bh4: u32 = tables.num_4x4_blocks_high[b.size];
    const end4 = @min(@min(bh4, ps.out.mi_rows - b.row), 16);
    var delta_row: i64 = 0;
    var delta_col: i64 = delta_col_in;
    const step16 = bh4 >= 16;
    if (@abs(delta_col_in) > 1) {
        delta_row = 1 - @as(i64, b.row & 1);
        delta_col += b.col & 1;
    }
    var i: u32 = 0;
    while (i < end4) {
        const r = @as(i64, b.row) + delta_row + i;
        const c = @as(i64, b.col) + delta_col;
        if (!isInside(ps, r, c)) break;
        var len: u32 = @min(bh4, tables.num_4x4_blocks_high[blockAt(ps, r, c).size]);
        if (@abs(delta_col_in) > 1) len = @max(2, len);
        if (step16) len = @max(4, len);
        addRefMvCandidate(ps, r, c, compound, len * 2);
        i += len;
    }
}

fn scanPoint(ps: *Parse, delta_row: i32, delta_col: i32, compound: bool) void {
    const r = @as(i64, ps.b.row) + delta_row;
    const c = @as(i64, ps.b.col) + delta_col;
    if (isInside(ps, r, c) and written(ps, r, c)) addRefMvCandidate(ps, r, c, compound, 4);
}

fn temporalScan(ps: *Parse, compound: bool) void {
    const b = &ps.b;
    const bw4: i32 = tables.num_4x4_blocks_wide[b.size];
    const bh4: i32 = tables.num_4x4_blocks_high[b.size];
    const step_w4: i32 = if (bw4 >= 16) 4 else 2;
    const step_h4: i32 = if (bh4 >= 16) 4 else 2;
    var dr: i32 = 0;
    while (dr < @min(bh4, 16)) : (dr += step_h4) {
        var dc: i32 = 0;
        while (dc < @min(bw4, 16)) : (dc += step_w4) addTplRefMv(ps, dr, dc, compound);
    }
    const allow = bh4 >= 2 and bh4 < 16 and bw4 >= 2 and bw4 < 16;
    if (allow) {
        const pos = [3][2]i32{ .{ bh4, -2 }, .{ bh4, bw4 }, .{ bh4 - 2, bw4 } };
        for (pos) |p| {
            const row = @as(i32, @intCast(b.row & 15)) + p[0];
            const col = @as(i32, @intCast(b.col & 15)) + p[1];
            if (row >= 0 and row < 16 and col >= 0 and col < 16) addTplRefMv(ps, p[0], p[1], compound);
        }
    }
}

fn addTplRefMv(ps: *Parse, dr: i32, dc: i32, compound: bool) void {
    const b = &ps.b;
    const st = &ps.mv;
    const r = (@as(i64, b.row) + dr) | 1;
    const c = (@as(i64, b.col) + dc) | 1;
    if (!isInside(ps, r, c)) return;
    const at = @as(usize, @intCast(r >> 1)) * (ps.out.mi_cols >> 1) + @as(usize, @intCast(c >> 1));
    if (dr == 0 and dc == 0) st.zero_mv_ctx = 1;
    if (!compound) {
        var cand = ps.mf[@intCast(b.ref[0])][at];
        if (cand.row == INVALID) return;
        lowerPrecision(ps, &cand);
        if (dr == 0 and dc == 0) {
            st.zero_mv_ctx = @intFromBool(@abs(@as(i32, cand.row) - st.global[0].row) >= 16 or
                @abs(@as(i32, cand.col) - st.global[0].col) >= 16);
        }
        var i: u32 = 0;
        while (i < st.num_found) : (i += 1) {
            if (cand.eql(st.stack[i][0])) break;
        }
        if (i < st.num_found) {
            st.weight[i] += 2;
        } else if (st.num_found < MAX_STACK) {
            st.stack[st.num_found][0] = cand;
            st.weight[st.num_found] = 2;
            st.num_found += 1;
        }
    } else {
        var c0 = ps.mf[@intCast(b.ref[0])][at];
        if (c0.row == INVALID) return;
        var c1 = ps.mf[@intCast(b.ref[1])][at];
        if (c1.row == INVALID) return;
        lowerPrecision(ps, &c0);
        lowerPrecision(ps, &c1);
        if (dr == 0 and dc == 0) {
            st.zero_mv_ctx = @intFromBool(@abs(@as(i32, c0.row) - st.global[0].row) >= 16 or
                @abs(@as(i32, c0.col) - st.global[0].col) >= 16 or
                @abs(@as(i32, c1.row) - st.global[1].row) >= 16 or
                @abs(@as(i32, c1.col) - st.global[1].col) >= 16);
        }
        var i: u32 = 0;
        while (i < st.num_found) : (i += 1) {
            if (c0.eql(st.stack[i][0]) and c1.eql(st.stack[i][1])) break;
        }
        if (i < st.num_found) {
            st.weight[i] += 2;
        } else if (st.num_found < MAX_STACK) {
            st.stack[st.num_found] = .{ c0, c1 };
            st.weight[st.num_found] = 2;
            st.num_found += 1;
        }
    }
}

fn addRefMvCandidate(ps: *Parse, r: i64, c: i64, compound: bool, weight: u32) void {
    const cand = blockAt(ps, r, c);
    if (!cand.is_inter) return;
    const b = &ps.b;
    if (!compound) {
        for (0..2) |list| {
            if (cand.ref[list] == b.ref[0]) searchStack(ps, cand, list, weight);
        }
    } else if (cand.ref[0] == b.ref[0] and cand.ref[1] == b.ref[1]) {
        compoundSearchStack(ps, cand, weight);
    }
}

fn searchStack(ps: *Parse, cand: *const parse.Block, list: usize, weight: u32) void {
    const st = &ps.mv;
    const b = &ps.b;
    const large = @min(parse.blockWidth(cand.size), parse.blockHeight(cand.size)) >= 8;
    var m: Mv = cand.mv[list];
    if ((cand.y_mode == common.GLOBALMV or cand.y_mode == common.GLOBAL_GLOBALMV) and
        ps.h.gm_type[@intCast(@max(b.ref[0], 0))] > common.TRANSLATION and large)
    {
        m = st.global[0];
    }
    lowerPrecision(ps, &m);
    if (hasNewmv(cand.y_mode)) st.new_count += 1;
    st.found_match = true;
    var i: u32 = 0;
    while (i < st.num_found) : (i += 1) {
        if (m.eql(st.stack[i][0])) break;
    }
    if (i < st.num_found) {
        st.weight[i] += weight;
    } else if (st.num_found < MAX_STACK) {
        st.stack[st.num_found][0] = m;
        st.weight[st.num_found] = weight;
        st.num_found += 1;
    }
}

fn compoundSearchStack(ps: *Parse, cand: *const parse.Block, weight: u32) void {
    const st = &ps.mv;
    const b = &ps.b;
    var m = cand.mv;
    if (cand.y_mode == common.GLOBAL_GLOBALMV) {
        for (0..2) |list| {
            if (ps.h.gm_type[@intCast(b.ref[list])] > common.TRANSLATION) m[list] = st.global[list];
        }
    }
    lowerPrecision(ps, &m[0]);
    lowerPrecision(ps, &m[1]);
    st.found_match = true;
    var i: u32 = 0;
    while (i < st.num_found) : (i += 1) {
        if (m[0].eql(st.stack[i][0]) and m[1].eql(st.stack[i][1])) break;
    }
    if (i < st.num_found) {
        st.weight[i] += weight;
    } else if (st.num_found < MAX_STACK) {
        st.stack[st.num_found] = m;
        st.weight[st.num_found] = weight;
        st.num_found += 1;
    }
    if (hasNewmv(cand.y_mode)) st.new_count += 1;
}

fn sort(st: *State, start: u32, end_in: u32, compound: bool) void {
    var end = end_in;
    while (end > start) {
        var new_end = start;
        var i = start + 1;
        while (i < end) : (i += 1) {
            if (st.weight[i - 1] < st.weight[i]) {
                const w = st.weight[i - 1];
                st.weight[i - 1] = st.weight[i];
                st.weight[i] = w;
                const lists: usize = if (compound) 2 else 1;
                for (0..lists) |l| {
                    const m = st.stack[i - 1][l];
                    st.stack[i - 1][l] = st.stack[i][l];
                    st.stack[i][l] = m;
                }
                new_end = i;
            }
        }
        end = new_end;
    }
}

fn extraSearch(ps: *Parse, compound: bool) void {
    const b = &ps.b;
    const st = &ps.mv;
    const out = ps.out;
    var id_mvs: [2][2]Mv = undefined;
    var diff_mvs: [2][2]Mv = undefined;
    var id_count = [2]u32{ 0, 0 };
    var diff_count = [2]u32{ 0, 0 };
    var w4: u32 = @min(16, tables.num_4x4_blocks_wide[b.size]);
    var h4: u32 = @min(16, tables.num_4x4_blocks_high[b.size]);
    w4 = @min(w4, out.mi_cols - b.col);
    h4 = @min(h4, out.mi_rows - b.row);
    const num4x4 = @min(w4, h4);
    for (0..2) |pass| {
        var idx: u32 = 0;
        while (idx < num4x4 and st.num_found < 2) {
            var r: i64 = 0;
            var c: i64 = 0;
            if (pass == 0) {
                r = @as(i64, b.row) - 1;
                c = @as(i64, b.col) + idx;
            } else {
                r = @as(i64, b.row) + idx;
                c = @as(i64, b.col) - 1;
            }
            if (!isInside(ps, r, c)) break;
            const cand = blockAt(ps, r, c);
            // add_extra_mv_candidate
            if (compound) {
                for (0..2) |cl| {
                    const cref = cand.ref[cl];
                    if (cref > common.INTRA_FRAME) {
                        for (0..2) |list| {
                            var m = cand.mv[cl];
                            if (cref == b.ref[list] and id_count[list] < 2) {
                                id_mvs[list][id_count[list]] = m;
                                id_count[list] += 1;
                            } else if (diff_count[list] < 2) {
                                if (ps.h.ref_frame_sign_bias[@intCast(cref)] != ps.h.ref_frame_sign_bias[@intCast(b.ref[list])]) {
                                    m.row = -m.row;
                                    m.col = -m.col;
                                }
                                diff_mvs[list][diff_count[list]] = m;
                                diff_count[list] += 1;
                            }
                        }
                    }
                }
            } else {
                for (0..2) |cl| {
                    const cref = cand.ref[cl];
                    if (cref > common.INTRA_FRAME) {
                        var m = cand.mv[cl];
                        if (ps.h.ref_frame_sign_bias[@intCast(cref)] != ps.h.ref_frame_sign_bias[@intCast(@max(b.ref[0], 0))]) {
                            m.row = -m.row;
                            m.col = -m.col;
                        }
                        var i: u32 = 0;
                        while (i < st.num_found) : (i += 1) {
                            if (m.eql(st.stack[i][0])) break;
                        }
                        if (i == st.num_found) {
                            st.stack[i][0] = m;
                            st.weight[i] = 2;
                            st.num_found += 1;
                        }
                    }
                }
            }
            if (pass == 0) {
                idx += tables.num_4x4_blocks_wide[cand.size];
            } else {
                idx += tables.num_4x4_blocks_high[cand.size];
            }
        }
    }
    if (compound) {
        var combined: [2][2]Mv = undefined;
        for (0..2) |list| {
            var n: u32 = 0;
            for (0..id_count[list]) |i| {
                combined[n][list] = id_mvs[list][i];
                n += 1;
            }
            var i: u32 = 0;
            while (i < diff_count[list] and n < 2) : (i += 1) {
                combined[n][list] = diff_mvs[list][i];
                n += 1;
            }
            while (n < 2) : (n += 1) combined[n][list] = st.global[list];
        }
        if (st.num_found == 1) {
            if (combined[0][0].eql(st.stack[0][0]) and combined[0][1].eql(st.stack[0][1])) {
                st.stack[1] = combined[1];
            } else {
                st.stack[1] = combined[0];
            }
            st.weight[1] = 2;
            st.num_found = 2;
        } else {
            for (0..2) |i| {
                st.stack[st.num_found] = combined[i];
                st.weight[st.num_found] = 2;
                st.num_found += 1;
            }
        }
    } else {
        var i = st.num_found;
        while (i < 2) : (i += 1) st.stack[i][0] = st.global[0];
    }
}

/// has_overlappable_candidates (7.10.3).
pub fn hasOverlappableCandidates(ps: *const Parse) bool {
    const b = &ps.b;
    const out = ps.out;
    if (ps.avail_u) {
        const w4: u32 = tables.num_4x4_blocks_wide[b.size];
        var x = b.col;
        while (x < @min(out.mi_cols, b.col + w4)) : (x += 2) {
            if (out.block(b.row - 1, @min(x | 1, out.mi_cols - 1)).ref[0] > common.INTRA_FRAME) return true;
        }
    }
    if (ps.avail_l) {
        const h4: u32 = tables.num_4x4_blocks_high[b.size];
        var y = b.row;
        while (y < @min(out.mi_rows, b.row + h4)) : (y += 2) {
            if (out.block(@min(y | 1, out.mi_rows - 1), b.col - 1).ref[0] > common.INTRA_FRAME) return true;
        }
    }
    return false;
}

/// find_warp_samples (7.10.4).
pub fn findWarpSamples(ps: *Parse) void {
    const b = &ps.b;
    const out = ps.out;
    const st = &ps.mv;
    st.num_samples = 0;
    st.num_scanned = 0;
    const w4: u32 = tables.num_4x4_blocks_wide[b.size];
    const h4: u32 = tables.num_4x4_blocks_high[b.size];
    var do_top_left = true;
    var do_top_right = true;
    if (ps.avail_u) {
        const src_w: u32 = tables.num_4x4_blocks_wide[out.block(b.row - 1, b.col).size];
        if (w4 <= src_w) {
            const col_offset = -@as(i64, b.col & (src_w - 1));
            if (col_offset < 0) do_top_left = false;
            if (col_offset + src_w > w4) do_top_right = false;
            addSample(ps, -1, 0);
        } else {
            var i: u32 = 0;
            while (i < @min(w4, out.mi_cols - b.col)) {
                const sw: u32 = tables.num_4x4_blocks_wide[out.block(b.row - 1, b.col + i).size];
                addSample(ps, -1, @intCast(i));
                i += @min(w4, sw);
            }
        }
    }
    if (ps.avail_l) {
        const src_h: u32 = tables.num_4x4_blocks_high[out.block(b.row, b.col - 1).size];
        if (h4 <= src_h) {
            const row_offset = -@as(i64, b.row & (src_h - 1));
            if (row_offset < 0) do_top_left = false;
            addSample(ps, 0, -1);
        } else {
            var i: u32 = 0;
            while (i < @min(h4, out.mi_rows - b.row)) {
                const sh: u32 = tables.num_4x4_blocks_high[out.block(b.row + i, b.col - 1).size];
                addSample(ps, @intCast(i), -1);
                i += @min(h4, sh);
            }
        }
    }
    if (do_top_left) addSample(ps, -1, -1);
    if (do_top_right and @max(w4, h4) <= 16) addSample(ps, -1, @intCast(w4));
    if (st.num_samples == 0 and st.num_scanned > 0) st.num_samples = 1;
}

fn addSample(ps: *Parse, dr: i32, dc: i32) void {
    const b = &ps.b;
    const st = &ps.mv;
    if (st.num_scanned >= SAMPLES_MAX) return;
    const r = @as(i64, b.row) + dr;
    const c = @as(i64, b.col) + dc;
    if (!isInside(ps, r, c) or !written(ps, r, c)) return;
    const cand = blockAt(ps, r, c);
    if (cand.ref[0] != b.ref[0] or cand.ref[1] != common.NONE) return;
    const cw4: i64 = tables.num_4x4_blocks_wide[cand.size];
    const ch4: i64 = tables.num_4x4_blocks_high[cand.size];
    const cand_row = r & ~(ch4 - 1);
    const cand_col = c & ~(cw4 - 1);
    const mid_y: i32 = @intCast(cand_row * 4 + ch4 * 2 - 1);
    const mid_x: i32 = @intCast(cand_col * 4 + cw4 * 2 - 1);
    const threshold: i32 = common.clip3(16, 112, @intCast(@max(parse.blockWidth(b.size), parse.blockHeight(b.size))));
    const cm = blockAt(ps, cand_row, cand_col).mv[0];
    const diff_r: i32 = @intCast(@abs(@as(i32, cm.row) - b.mv[0].row));
    const diff_c: i32 = @intCast(@abs(@as(i32, cm.col) - b.mv[0].col));
    const valid = diff_r + diff_c <= threshold;
    st.num_scanned += 1;
    if (!valid and st.num_scanned > 1) return;
    st.cand[st.num_samples] = .{ mid_y * 8, mid_x * 8, mid_y * 8 + cm.row, mid_x * 8 + cm.col };
    if (valid) st.num_samples += 1;
}

fn lsProduct(a: i64, b: i64) i64 {
    return ((a * b) >> 2) + (a + b);
}

/// The warp estimation (7.11.3.8) of the block's samples, into `p`; and
/// whether it is valid and its shears are (7.11.3.6).
pub fn warpEstimation(ps: *const Parse, p: *[6]i32) bool {
    const b = &ps.b;
    const st = &ps.mv;
    var a = [2][2]i64{ .{ 0, 0 }, .{ 0, 0 } };
    var bx = [2]i64{ 0, 0 };
    var by = [2]i64{ 0, 0 };
    const w4: i64 = tables.num_4x4_blocks_wide[b.size];
    const h4: i64 = tables.num_4x4_blocks_high[b.size];
    const mid_y: i64 = @as(i64, b.row) * 4 + h4 * 2 - 1;
    const mid_x: i64 = @as(i64, b.col) * 4 + w4 * 2 - 1;
    const suy = mid_y * 8;
    const sux = mid_x * 8;
    const duy = suy + b.mv[0].row;
    const dux = sux + b.mv[0].col;
    for (0..st.num_samples) |i| {
        const sy = st.cand[i][0] - suy;
        const sx = st.cand[i][1] - sux;
        const dy = st.cand[i][2] - duy;
        const dx = st.cand[i][3] - dux;
        if (@abs(sx - dx) < LS_MV_MAX and @abs(sy - dy) < LS_MV_MAX) {
            a[0][0] += lsProduct(sx, sx) + 8;
            a[0][1] += lsProduct(sx, sy) + 4;
            a[1][1] += lsProduct(sy, sy) + 8;
            bx[0] += lsProduct(sx, dx) + 8;
            bx[1] += lsProduct(sy, dx) + 4;
            by[0] += lsProduct(sx, dy) + 4;
            by[1] += lsProduct(sy, dy) + 8;
        }
    }
    const det = a[0][0] * a[1][1] - a[0][1] * a[0][1];
    if (det == 0) return false;
    const div = warp.resolveDivisor(det);
    var shift: i32 = div.shift - warp.PREC_BITS;
    var factor: i64 = div.factor;
    if (shift < 0) {
        factor <<= @intCast(-shift);
        shift = 0;
    }
    const sh: u6 = @intCast(shift);
    p[2] = diag(a[1][1] *% bx[0] -% a[0][1] *% bx[1], factor, sh);
    p[3] = nondiag(-a[0][1] *% bx[0] +% a[0][0] *% bx[1], factor, sh);
    p[4] = nondiag(a[1][1] *% by[0] -% a[0][1] *% by[1], factor, sh);
    p[5] = diag(-a[0][1] *% by[0] +% a[0][0] *% by[1], factor, sh);
    const one: i64 = 1 << warp.PREC_BITS;
    const vx = @as(i64, b.mv[0].col) * (1 << (warp.PREC_BITS - 3)) - (mid_x * (p[2] - one) + mid_y * p[3]);
    const vy = @as(i64, b.mv[0].row) * (1 << (warp.PREC_BITS - 3)) - (mid_x * p[4] + mid_y * (p[5] - one));
    const clamp: i64 = 1 << 23;
    p[0] = @intCast(@max(-clamp, @min(clamp - 1, vx)));
    p[1] = @intCast(@max(-clamp, @min(clamp - 1, vy)));
    return warp.setupShear(p).valid;
}

fn divide(v: i64, factor: i64, shift: u6) i64 {
    return common.round2Signed(v *% factor, shift);
}

fn nondiag(v: i64, factor: i64, shift: u6) i32 {
    const lim: i64 = 1 << 13;
    return @intCast(@max(-lim + 1, @min(lim - 1, divide(v, factor, shift))));
}

fn diag(v: i64, factor: i64, shift: u6) i32 {
    const lim: i64 = 1 << 13;
    const one: i64 = 1 << warp.PREC_BITS;
    return @intCast(@max(one - lim + 1, @min(one + lim - 1, divide(v, factor, shift))));
}

/// motion_field_estimation (7.9), planned: the references whose fields
/// are projected, in turn - a later one's vectors over an earlier one's.
pub fn planMotionField(ps: *Parse) void {
    const h = ps.h;
    const seq = ps.seq;
    ps.mf_count = 0;
    ps.mf_rows = 0;
    const last_idx = h.ref_frame_idx[0];
    const cur_gold = h.order_hints[@intCast(common.GOLDEN_FRAME)];
    const last_alt = ps.refs[last_idx].saved_order_hints[@intCast(common.ALTREF_FRAME)];
    if (last_alt != cur_gold) _ = plan(ps, common.LAST_FRAME, -1);
    var stamp: i32 = MFMV_STACK_SIZE - 2;
    if (seq.dist(h.order_hints[@intCast(common.BWDREF_FRAME)], h.order_hint) > 0) {
        if (plan(ps, common.BWDREF_FRAME, 1)) stamp -= 1;
    }
    if (seq.dist(h.order_hints[@intCast(common.ALTREF2_FRAME)], h.order_hint) > 0) {
        if (plan(ps, common.ALTREF2_FRAME, 1)) stamp -= 1;
    }
    if (seq.dist(h.order_hints[@intCast(common.ALTREF_FRAME)], h.order_hint) > 0 and stamp >= 0) {
        if (plan(ps, common.ALTREF_FRAME, 1)) stamp -= 1;
    }
    if (stamp >= 0) _ = plan(ps, common.LAST2_FRAME, -1);
}

/// Whether reference `src` has a field to project: then planned.
fn plan(ps: *Parse, src: i8, dst_sign: i32) bool {
    const out = ps.out;
    const ri = &ps.refs[ps.h.ref_frame_idx[@intCast(src - common.LAST_FRAME)]];
    if (ri.mi_rows != out.mi_rows or ri.mi_cols != out.mi_cols or
        ri.frame_type == common.INTRA_ONLY_FRAME or ri.frame_type == common.KEY_FRAME) return false;
    if (ri.mvs.len < (out.mi_cols >> 1) * (out.mi_rows >> 1)) return false;
    ps.mf_plan[ps.mf_count] = .{ .src = src, .sign = dst_sign };
    ps.mf_count += 1;
    return true;
}

/// The projected fields down to mi row `rows`, by bands of 16 rows - a
/// vector is projected within its band, and read within the band of the
/// block reading it - once each reference's field is there for the band.
pub fn projectRows(ps: *Parse, rows: u32) void {
    const out = ps.out;
    const w8 = out.mi_cols >> 1;
    const end = @min(rows, out.mi_rows);
    while (ps.mf_rows < end) {
        const to = @min(ps.mf_rows + 16, out.mi_rows);
        const from8 = ps.mf_rows >> 1;
        const to8 = to >> 1;
        for (1..8) |r| @memset(ps.mf[r][from8 * w8 .. to8 * w8], Mv{ .row = INVALID, .col = INVALID });
        for (ps.mf_plan[0..ps.mf_count]) |p| {
            if (ps.hooks) |hooks| hooks.until(hooks.ctx, p.src, to);
            project(ps, p.src, p.sign, from8, to8);
        }
        ps.mf_rows = to;
    }
}

/// Reference `src`'s field projected, of its rows `from8` to `to8` by 8x8.
fn project(ps: *Parse, src: i8, dst_sign: i32, from8: u32, to8: u32) void {
    const h = ps.h;
    const seq = ps.seq;
    const out = ps.out;
    const src_idx = h.ref_frame_idx[@intCast(src - common.LAST_FRAME)];
    const ri = &ps.refs[src_idx];
    const w8 = out.mi_cols >> 1;
    const h8 = out.mi_rows >> 1;
    const ref_to_cur = seq.dist(h.order_hints[@intCast(src)], h.order_hint);
    var ref_to_dst: [8]i32 = undefined;
    for (1..8) |d| ref_to_dst[d] = seq.dist(h.order_hint, h.order_hints[d]);
    for (from8..to8) |y8| {
        for (0..w8) |x8| {
            const saved = ri.mvs[y8 * w8 + x8];
            if (saved.ref <= common.INTRA_FRAME) continue;
            const ref_offset = seq.dist(h.order_hints[@intCast(src)], ri.saved_order_hints[@intCast(saved.ref)]);
            if (!(@abs(ref_to_cur) <= MAX_FRAME_DISTANCE and @abs(ref_offset) <= MAX_FRAME_DISTANCE and ref_offset > 0)) continue;
            const proj = mvProjection(saved.mv, ref_to_cur * dst_sign, ref_offset);
            var valid = true;
            const pos_y = projectPos(@intCast(y8), proj.row, dst_sign, @intCast(h8), MAX_OFFSET_HEIGHT, &valid);
            const pos_x = projectPos(@intCast(x8), proj.col, dst_sign, @intCast(w8), MAX_OFFSET_WIDTH, &valid);
            if (!valid) continue;
            const at = @as(usize, @intCast(pos_y)) * w8 + @as(usize, @intCast(pos_x));
            for (1..8) |d| ps.mf[d][at] = mvProjection(saved.mv, ref_to_dst[d], ref_offset);
        }
    }
}

fn mvProjection(m: Mv, numerator: i32, denominator: i32) Mv {
    const den: usize = @intCast(@min(MAX_FRAME_DISTANCE, denominator));
    const num: i64 = common.clip3(-MAX_FRAME_DISTANCE, MAX_FRAME_DISTANCE, numerator);
    const mult: i64 = tables.div_mult[den];
    var r: [2]i16 = undefined;
    for ([2]i16{ m.row, m.col }, 0..) |v, i| {
        const scaled = common.round2Signed(@as(i64, v) * num * mult, 14);
        r[i] = @intCast(@max(-(1 << 14) + 1, @min((1 << 14) - 1, scaled)));
    }
    return .{ .row = r[0], .col = r[1] };
}

fn projectPos(v8_in: i32, delta: i32, dst_sign: i32, max8: i32, max_off8: i32, valid: *bool) i32 {
    var v8 = v8_in;
    const base8 = (v8 >> 3) << 3;
    const offset8 = if (delta >= 0) delta >> (3 + 1 + 2) else -((-delta) >> (3 + 1 + 2));
    v8 += dst_sign * offset8;
    if (v8 < 0 or v8 >= max8 or v8 < base8 - max_off8 or v8 >= base8 + 8 + max_off8) valid.* = false;
    return v8;
}
