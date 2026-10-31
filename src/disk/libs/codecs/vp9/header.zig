// SPDX-License-Identifier: MIT
//! A frame's headers: the uncompressed one in plain bits (6.2) - the
//! frame's type and size, its references, the loop filter, the quantiser,
//! the segmentation and the tiles - and the compressed one (6.3), which
//! changes the probabilities the blocks are read with.

const common = @import("common.zig");
const tables = @import("tables.zig");
const Bool = @import("bool.zig").Bool;
const Probs = @import("probs.zig").Probs;
const Error = common.Error;

/// Bits read from the most significant on; zeros past the end.
pub const Bits = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn bit(r: *Bits) u1 {
        const i = r.pos >> 3;
        if (i >= r.data.len) {
            r.pos += 1;
            return 0;
        }
        const b: u1 = @intCast((r.data[i] >> @intCast(7 - (r.pos & 7))) & 1);
        r.pos += 1;
        return b;
    }
    pub fn flag(r: *Bits) bool {
        return r.bit() == 1;
    }
    pub fn f(r: *Bits, n: u6) u32 {
        var v: u32 = 0;
        for (0..n) |_| v = (v << 1) | r.bit();
        return v;
    }
    /// An `n`-bit magnitude, then its sign.
    pub fn s(r: *Bits, n: u6) i32 {
        const v: i32 = @intCast(r.f(n));
        return if (r.flag()) -v else v;
    }
    pub fn overrun(r: *const Bits) bool {
        return r.pos > r.data.len * 8;
    }
};

/// Segmentation (6.2.11), which stays from frame to frame.
pub const Segmentation = struct {
    enabled: bool = false,
    update_map: bool = false,
    temporal_update: bool = false,
    abs_delta: bool = false,
    tree_probs: [7]u8 = @splat(255),
    pred_probs: [3]u8 = @splat(255),
    feature_enabled: [8][4]bool = @splat(@splat(false)),
    feature_data: [8][4]i16 = @splat(@splat(0)),

    pub fn active(sg: *const Segmentation, segment: u8, feature: usize) bool {
        return sg.enabled and sg.feature_enabled[segment][feature];
    }
};

/// The loop filter's adjustments by reference and mode, which stay too.
pub const Deltas = struct {
    enabled: bool = false,
    ref: [4]i8 = .{ 1, 0, -1, -1 },
    mode: [2]i8 = .{ 0, 0 },
};

/// The colour as the last key frame or intra-only frame set it.
pub const Color = struct {
    bit_depth: u8 = 8,
    color_space: u8 = 0,
    full_range: bool = false,
    ss_x: u1 = 1,
    ss_y: u1 = 1,
};

/// What the decoder keeps from frame to frame that the uncompressed
/// header reads or changes.
pub const State = struct {
    seg: Segmentation = .{},
    deltas: Deltas = .{},
    color: Color = .{},
    /// The size of the frame in each reference slot; 0 when empty.
    ref_width: [8]u32 = @splat(0),
    ref_height: [8]u32 = @splat(0),
};

pub const KEY_FRAME = 0;

pub const Header = struct {
    profile: u8 = 0,
    show_existing_frame: bool = false,
    frame_to_show: u8 = 0,
    frame_type: u1 = KEY_FRAME,
    show_frame: bool = true,
    error_resilient: bool = false,
    intra_only: bool = false,
    /// A key frame or an intra-only frame.
    intra: bool = true,
    reset_frame_context: u2 = 0,
    refresh_frame_flags: u8 = 0,
    ref_frame_idx: [3]u8 = .{ 0, 0, 0 },
    /// By reference, LAST_FRAME to ALTREF_FRAME; 0 unused.
    sign_bias: [4]bool = @splat(false),
    allow_hp: bool = false,
    interp_filter: u8 = 0,
    refresh_frame_context: bool = false,
    frame_parallel: bool = true,
    frame_context_idx: u2 = 0,
    /// Set when the frame resets what earlier frames left
    /// (setup_past_independence).
    reset_past: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    filter_level: u8 = 0,
    sharpness: u8 = 0,
    base_q_idx: u8 = 0,
    delta_q_y_dc: i8 = 0,
    delta_q_uv_dc: i8 = 0,
    delta_q_uv_ac: i8 = 0,
    lossless: bool = false,
    tile_cols_log2: u8 = 0,
    tile_rows_log2: u8 = 0,
    /// The compressed header's size, and where it starts.
    header_size: u32 = 0,
    header_start: u32 = 0,
    // The compressed header's.
    tx_mode: u8 = 0,
    reference_mode: u8 = 0,
    comp_fixed_ref: i8 = 0,
    comp_var_ref: [2]i8 = .{ 0, 0 },
};

pub const SINGLE_REFERENCE = 0;
pub const COMPOUND_REFERENCE = 1;
pub const REFERENCE_MODE_SELECT = 2;

fn syncCode(r: *Bits) Error!void {
    if (r.f(8) != 0x49 or r.f(8) != 0x83 or r.f(8) != 0x42) return error.Corrupt;
}

fn colorConfig(r: *Bits, h: *const Header, c: *Color) Error!void {
    c.bit_depth = if (h.profile >= 2) (if (r.flag()) 12 else 10) else 8;
    c.color_space = @intCast(r.f(3));
    if (c.color_space != common.CS_RGB) {
        c.full_range = r.flag();
        if (h.profile == 1 or h.profile == 3) {
            c.ss_x = r.bit();
            c.ss_y = r.bit();
            if (r.flag()) return error.Unsupported;
            // 4:2:0 is profile 0's and 2's.
            if (c.ss_x == 1 and c.ss_y == 1) return error.Corrupt;
        } else {
            c.ss_x = 1;
            c.ss_y = 1;
        }
    } else {
        c.full_range = true;
        if (h.profile == 1 or h.profile == 3) {
            c.ss_x = 0;
            c.ss_y = 0;
            if (r.flag()) return error.Unsupported;
        } else return error.Corrupt;
    }
}

fn frameSize(r: *Bits, h: *Header) void {
    h.width = r.f(16) + 1;
    h.height = r.f(16) + 1;
}

fn renderSize(r: *Bits) void {
    if (r.flag()) _ = r.f(32);
}

fn readDeltaQ(r: *Bits) i8 {
    return if (r.flag()) @intCast(r.s(4)) else 0;
}

fn readProb(r: *Bits) u8 {
    return if (r.flag()) @intCast(r.f(8)) else 255;
}

/// The uncompressed header (6.2) of `data`; `st` changes as it says.
pub fn uncompressed(data: []const u8, st: *State) Error!Header {
    var r: Bits = .{ .data = data };
    var h: Header = .{};
    if (r.f(2) != 2) return error.Corrupt;
    const low = r.bit();
    h.profile = (@as(u8, r.bit()) << 1) | low;
    if (h.profile == 3 and r.flag()) return error.Unsupported;
    h.show_existing_frame = r.flag();
    if (h.show_existing_frame) {
        h.frame_to_show = @intCast(r.f(3));
        return h;
    }
    h.frame_type = r.bit();
    h.show_frame = r.flag();
    h.error_resilient = r.flag();
    if (h.frame_type == KEY_FRAME) {
        try syncCode(&r);
        try colorConfig(&r, &h, &st.color);
        frameSize(&r, &h);
        renderSize(&r);
        h.refresh_frame_flags = 0xFF;
        h.intra = true;
    } else {
        h.intra_only = if (h.show_frame) false else r.flag();
        h.intra = h.intra_only;
        h.reset_frame_context = if (h.error_resilient) 0 else @intCast(r.f(2));
        if (h.intra_only) {
            try syncCode(&r);
            if (h.profile > 0) {
                try colorConfig(&r, &h, &st.color);
            } else {
                st.color = .{ .color_space = 1 };
            }
            h.refresh_frame_flags = @intCast(r.f(8));
            frameSize(&r, &h);
            renderSize(&r);
        } else {
            h.refresh_frame_flags = @intCast(r.f(8));
            for (0..3) |i| {
                h.ref_frame_idx[i] = @intCast(r.f(3));
                h.sign_bias[1 + i] = r.flag();
            }
            var found = false;
            for (h.ref_frame_idx) |idx| {
                if (r.flag()) {
                    h.width = st.ref_width[idx];
                    h.height = st.ref_height[idx];
                    found = true;
                    break;
                }
            }
            if (!found) frameSize(&r, &h);
            if (h.width == 0) return error.Corrupt;
            renderSize(&r);
            h.allow_hp = r.flag();
            h.interp_filter = if (r.flag()) common.SWITCHABLE else tables.literal_to_type[r.f(2)];
        }
    }
    if (!h.error_resilient) {
        h.refresh_frame_context = r.flag();
        h.frame_parallel = r.flag();
    } else {
        h.refresh_frame_context = false;
        h.frame_parallel = true;
    }
    h.frame_context_idx = @intCast(r.f(2));
    if (h.intra or h.error_resilient) {
        // setup_past_independence: what the rest of this header reads;
        // the decoder resets the probabilities and the segment map.
        h.reset_past = true;
        st.seg.feature_enabled = @splat(@splat(false));
        st.seg.feature_data = @splat(@splat(0));
        st.seg.abs_delta = false;
        st.deltas = .{ .enabled = true };
        h.sign_bias = @splat(false);
    }
    // Loop filter (6.2.8).
    h.filter_level = @intCast(r.f(6));
    h.sharpness = @intCast(r.f(3));
    st.deltas.enabled = r.flag();
    if (st.deltas.enabled and r.flag()) {
        for (&st.deltas.ref) |*d| {
            if (r.flag()) d.* = @intCast(r.s(6));
        }
        for (&st.deltas.mode) |*d| {
            if (r.flag()) d.* = @intCast(r.s(6));
        }
    }
    // Quantisation (6.2.9).
    h.base_q_idx = @intCast(r.f(8));
    h.delta_q_y_dc = readDeltaQ(&r);
    h.delta_q_uv_dc = readDeltaQ(&r);
    h.delta_q_uv_ac = readDeltaQ(&r);
    h.lossless = h.base_q_idx == 0 and h.delta_q_y_dc == 0 and h.delta_q_uv_dc == 0 and h.delta_q_uv_ac == 0;
    // Segmentation (6.2.11).
    const sg = &st.seg;
    sg.update_map = false;
    sg.enabled = r.flag();
    if (sg.enabled) {
        sg.update_map = r.flag();
        if (sg.update_map) {
            for (&sg.tree_probs) |*p| p.* = readProb(&r);
            sg.temporal_update = r.flag();
            for (&sg.pred_probs) |*p| p.* = if (sg.temporal_update) readProb(&r) else 255;
        }
        if (r.flag()) {
            sg.abs_delta = r.flag();
            for (0..8) |i| {
                for (0..4) |j| {
                    var v: i16 = 0;
                    sg.feature_enabled[i][j] = r.flag();
                    if (sg.feature_enabled[i][j]) {
                        v = @intCast(r.f(tables.segmentation_feature_bits[j]));
                        if (tables.segmentation_feature_signed[j] and r.flag()) v = -v;
                    }
                    sg.feature_data[i][j] = v;
                }
            }
        }
    }
    // Tiles (6.2.13).
    const sb_cols = (((h.width + 7) >> 3) + 7) >> 3;
    var min_log2: u8 = 0;
    while ((@as(u32, 64) << @intCast(min_log2)) < sb_cols) min_log2 += 1;
    var max_log2: u8 = 1;
    while ((sb_cols >> @intCast(max_log2)) >= 4) max_log2 += 1;
    max_log2 -= 1;
    h.tile_cols_log2 = min_log2;
    while (h.tile_cols_log2 < max_log2 and r.flag()) h.tile_cols_log2 += 1;
    h.tile_rows_log2 = r.bit();
    if (h.tile_rows_log2 == 1) h.tile_rows_log2 += r.bit();
    h.header_size = r.f(16);
    // The trailing bits (6.1.1).
    h.header_start = @intCast((r.pos + 7) >> 3);
    if (r.overrun() or h.header_start > data.len) return error.Corrupt;
    return h;
}

/// An update of `prob` (6.3.3 to 6.3.6).
fn diffUpdate(b: *Bool, prob: *u8) void {
    if (b.read(252) == 0) return;
    var delta: u32 = undefined;
    if (b.read(128) == 0) {
        delta = b.literal(4);
    } else if (b.read(128) == 0) {
        delta = b.literal(4) + 16;
    } else if (b.read(128) == 0) {
        delta = b.literal(5) + 32;
    } else {
        const v = b.literal(7);
        delta = if (v < 65) v + 64 else (v << 1) - 1 + b.read(128);
    }
    if (delta >= tables.inv_map_table.len) return;
    const v: i32 = tables.inv_map_table[delta];
    const m: i32 = @as(i32, prob.*) - 1;
    const result = if ((m << 1) <= 255) 1 + recenter(v, m) else 255 - recenter(v, 255 - 1 - m);
    prob.* = @intCast(@max(1, @min(255, result)));
}

fn recenter(v: i32, m: i32) i32 {
    if (v > 2 * m) return v;
    if (v & 1 != 0) return m - ((v + 1) >> 1);
    return m + (v >> 1);
}

fn mvUpdate(b: *Bool, prob: *u8) void {
    if (b.read(252) == 1) prob.* = @intCast((b.literal(7) << 1) | 1);
}

/// The compressed header (6.3): the transform mode, the reference mode
/// and the probabilities' updates into `p`.
pub fn compressed(data: []const u8, h: *Header, p: *Probs) Error!void {
    var b = Bool.init(data) orelse return error.Corrupt;
    // Transform mode (6.3.1, 6.3.2).
    if (h.lossless) {
        h.tx_mode = 0;
    } else {
        h.tx_mode = @intCast(b.literal(2));
        if (h.tx_mode == 3) h.tx_mode += b.read(128);
    }
    if (h.tx_mode == common.TX_MODE_SELECT) {
        for (&p.tx8) |*q| diffUpdate(&b, &q[0]);
        for (&p.tx16) |*q| {
            for (q) |*x| diffUpdate(&b, x);
        }
        for (&p.tx32) |*q| {
            for (q) |*x| diffUpdate(&b, x);
        }
    }
    // Coefficients (6.3.7).
    const max_tx = tables.tx_mode_to_biggest_tx_size[h.tx_mode];
    for (p.coef[0 .. max_tx + 1]) |*t| {
        if (b.read(128) == 0) continue;
        for (t) |*i| {
            for (i) |*j| {
                for (j, 0..) |*k, band| {
                    const contexts: usize = if (band == 0) 3 else 6;
                    for (k[0..contexts]) |*l| {
                        for (l) |*m| diffUpdate(&b, m);
                    }
                }
            }
        }
    }
    for (&p.skip) |*q| diffUpdate(&b, q);
    if (!h.intra) {
        for (&p.inter_mode) |*q| {
            for (q) |*x| diffUpdate(&b, x);
        }
        if (h.interp_filter == common.SWITCHABLE) {
            for (&p.interp_filter) |*q| {
                for (q) |*x| diffUpdate(&b, x);
            }
        }
        for (&p.is_inter) |*q| diffUpdate(&b, q);
        // Reference mode (6.3.12, 6.3.13, 6.3.18).
        var compound_allowed = false;
        for (2..4) |i| {
            if (h.sign_bias[i] != h.sign_bias[1]) compound_allowed = true;
        }
        h.reference_mode = SINGLE_REFERENCE;
        if (compound_allowed and b.read(128) == 1) {
            h.reference_mode = if (b.read(128) == 0) COMPOUND_REFERENCE else REFERENCE_MODE_SELECT;
            if (h.sign_bias[common.LAST_FRAME] == h.sign_bias[common.GOLDEN_FRAME]) {
                h.comp_fixed_ref = common.ALTREF_FRAME;
                h.comp_var_ref = .{ common.LAST_FRAME, common.GOLDEN_FRAME };
            } else if (h.sign_bias[common.LAST_FRAME] == h.sign_bias[common.ALTREF_FRAME]) {
                h.comp_fixed_ref = common.GOLDEN_FRAME;
                h.comp_var_ref = .{ common.LAST_FRAME, common.ALTREF_FRAME };
            } else {
                h.comp_fixed_ref = common.LAST_FRAME;
                h.comp_var_ref = .{ common.GOLDEN_FRAME, common.ALTREF_FRAME };
            }
        }
        if (h.reference_mode == REFERENCE_MODE_SELECT) {
            for (&p.comp_mode) |*q| diffUpdate(&b, q);
        }
        if (h.reference_mode != COMPOUND_REFERENCE) {
            for (&p.single_ref) |*q| {
                diffUpdate(&b, &q[0]);
                diffUpdate(&b, &q[1]);
            }
        }
        if (h.reference_mode != SINGLE_REFERENCE) {
            for (&p.comp_ref) |*q| diffUpdate(&b, q);
        }
        for (&p.y_mode) |*q| {
            for (q) |*x| diffUpdate(&b, x);
        }
        for (&p.partition) |*q| {
            for (q) |*x| diffUpdate(&b, x);
        }
        // Motion vectors (6.3.16).
        for (&p.mv_joint) |*q| mvUpdate(&b, q);
        for (0..2) |i| {
            mvUpdate(&b, &p.mv_sign[i]);
            for (&p.mv_class[i]) |*q| mvUpdate(&b, q);
            mvUpdate(&b, &p.mv_class0_bit[i]);
            for (&p.mv_bits[i]) |*q| mvUpdate(&b, q);
        }
        for (0..2) |i| {
            for (&p.mv_class0_fr[i]) |*q| {
                for (q) |*x| mvUpdate(&b, x);
            }
            for (&p.mv_fr[i]) |*q| mvUpdate(&b, q);
        }
        if (h.allow_hp) {
            for (0..2) |i| {
                mvUpdate(&b, &p.mv_class0_hp[i]);
                mvUpdate(&b, &p.mv_hp[i]);
            }
        }
    }
}
