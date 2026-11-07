// SPDX-License-Identifier: MIT
//! A frame's headers as the decoder works from them: the uncompressed one
//! (6.2) as videoparse.library read it, and the compressed one (6.3),
//! read here, which says the transform and reference modes and changes
//! the probabilities the blocks are read with.

const common = @import("common.zig");
const tables = @import("tables.zig");
const v9 = @import("sdk").videoparse.vp9;
const Bool = @import("bool.zig").Bool;
const Probs = @import("probs.zig").Probs;
const Error = common.Error;

pub const KEY_FRAME = 0;

pub const Header = struct {
    profile: u8 = 0,
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

/// The uncompressed header the library read, as the decoder keeps it.
pub fn of(v: *const v9.Vp9Header) Header {
    return .{
        .profile = v.profile,
        .frame_type = @intCast(v.frame_type),
        .show_frame = v.show_frame,
        .error_resilient = v.error_resilient_mode,
        .intra_only = v.intra_only,
        .intra = v.frame_is_intra,
        .reset_frame_context = @intCast(v.reset_frame_context),
        .refresh_frame_flags = v.refresh_frame_flags,
        .ref_frame_idx = v.ref_frame_idx,
        .sign_bias = v.ref_frame_sign_bias,
        .allow_hp = v.allow_high_precision_mv,
        .interp_filter = v.interp_filter,
        .refresh_frame_context = v.refresh_frame_context,
        .frame_parallel = v.frame_parallel_decoding_mode,
        .frame_context_idx = @intCast(v.frame_context_idx),
        .reset_past = v.reset_past,
        .width = v.width,
        .height = v.height,
        .filter_level = v.loop_filter.level,
        .sharpness = v.loop_filter.sharpness,
        .base_q_idx = v.base_q_idx,
        .delta_q_y_dc = v.delta_q_y_dc,
        .delta_q_uv_dc = v.delta_q_uv_dc,
        .delta_q_uv_ac = v.delta_q_uv_ac,
        .lossless = v.lossless,
        .tile_cols_log2 = v.tile_cols_log2,
        .tile_rows_log2 = v.tile_rows_log2,
        .header_size = v.compressed_bytes,
        .header_start = v.uncompressed_bytes,
    };
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
