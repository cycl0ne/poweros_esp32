// SPDX-License-Identifier: MIT
//! Sequence and picture parameter sets (7.3.2.2, 7.3.2.3, annex E's VUI)
//! with their range extensions, the scaling lists (7.3.4) and the
//! short-term reference picture sets (7.3.7): what a stream says once of
//! all its pictures, and once of a few.
//!
//! The video parameter set says nothing a decoder of the base layer
//! needs, and is passed over; so is everything of the layers above it.
//! The screen content extensions are refused, and the 3D one of a
//! sequence.

const bits_mod = @import("bits.zig");
const Bits = bits_mod.Bits;
const Error = bits_mod.Error;

pub const Limits = struct {
    /// How large a picture may be, in luma samples across, down and in
    /// all (level 6.2's).
    max_width: u32 = 16888,
    max_height: u32 = 16888,
    max_samples: u32 = 35_651_584,
};

/// The most pictures of either kind a short-term set holds (each count
/// is bounded by sps_max_dec_pic_buffering_minus1, at most 15).
pub const max_rps = 16;

/// A short-term reference picture set (7.4.8): the pictures before the
/// current one (S0, nearest first) and after it (S1), as differences of
/// picture order count, and which of them the current picture uses.
pub const StRps = struct {
    num_negative: u8 = 0,
    num_positive: u8 = 0,
    delta_s0: [max_rps]i32 = @splat(0),
    delta_s1: [max_rps]i32 = @splat(0),
    used_s0: u16 = 0,
    used_s1: u16 = 0,

    pub fn count(r: *const StRps) u32 {
        return @as(u32, r.num_negative) + r.num_positive;
    }
    /// The pictures of it the current picture refers to.
    pub fn usedCount(r: *const StRps) u32 {
        return @popCount(r.used_s0) + @popCount(r.used_s1);
    }
};

/// Scaling lists as the stream gives them (7.3.4): for each size (4x4,
/// 8x8, 16x16, 32x32) and matrix (intra Y, Cb, Cr, inter Y, Cb, Cr) its
/// coefficients in up-right diagonal order - 16 for 4x4, 64 for the rest
/// - and the DC of the 16x16 and 32x32 ones.
pub const ScalingList = struct {
    coef: [4][6][64]u8 = undefined,
    dc: [2][6]u8 = undefined,

    /// Tables 7-5 and 7-6.
    pub fn default() ScalingList {
        var l: ScalingList = undefined;
        for (0..4) |size| for (0..6) |m| {
            l.coef[size][m] = if (size == 0) @splat(16) else if (m < 3) default_intra else default_inter;
        };
        l.dc = @splat(@splat(16));
        return l;
    }
};

const default_intra = [64]u8{
    16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 17, 16, 17, 16, 17, 18,
    17, 18, 18, 17, 18, 21, 19, 20, 21, 20, 19, 21, 24, 22, 22, 24,
    24, 22, 22, 24, 25, 25, 27, 30, 27, 25, 25, 29, 31, 35, 35, 31,
    29, 36, 41, 44, 41, 36, 47, 54, 54, 47, 65, 70, 65, 88, 88, 115,
};
const default_inter = [64]u8{
    16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 17, 17, 17, 17, 17, 18,
    18, 18, 18, 18, 18, 20, 20, 20, 20, 20, 20, 20, 24, 24, 24, 24,
    24, 24, 24, 24, 25, 25, 25, 25, 25, 25, 25, 28, 28, 28, 28, 28,
    28, 33, 33, 33, 33, 33, 41, 41, 41, 41, 54, 54, 54, 71, 71, 91,
};

pub const Sps = struct {
    valid: bool = false,
    profile_idc: u8 = 0,
    /// general_profile_compatibility_flag[ j ] as bit j.
    profile_compat: u32 = 0,
    level_idc: u8 = 0,
    max_sub_layers: u8 = 1,
    chroma_format_idc: u2 = 1,
    separate_colour_plane: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    /// The conformance window, in chroma samples (luma when grey).
    conf_left: u32 = 0,
    conf_right: u32 = 0,
    conf_top: u32 = 0,
    conf_bottom: u32 = 0,
    bit_depth_luma: u5 = 8,
    bit_depth_chroma: u5 = 8,
    log2_max_poc_lsb: u5 = 4,
    /// Of the highest sub-layer: sps_max_dec_pic_buffering_minus1 + 1,
    /// sps_max_num_reorder_pics and SpsMaxLatencyPictures (0: none).
    max_dec_pic_buffering: u32 = 1,
    max_num_reorder: u32 = 0,
    max_latency: u32 = 0,
    log2_min_cb: u3 = 3,
    log2_ctb: u3 = 4,
    log2_min_tb: u3 = 2,
    log2_max_tb: u3 = 5,
    max_th_depth_inter: u3 = 0,
    max_th_depth_intra: u3 = 0,
    scaling_enabled: bool = false,
    scaling: ScalingList = undefined,
    amp: bool = false,
    sao: bool = false,
    pcm: bool = false,
    pcm_depth_luma: u5 = 8,
    pcm_depth_chroma: u5 = 8,
    log2_min_pcm: u3 = 3,
    log2_max_pcm: u3 = 3,
    pcm_loop_filter_disabled: bool = false,
    num_st_rps: u8 = 0,
    st_rps: [64]StRps = undefined,
    long_term_present: bool = false,
    num_lt_sps: u8 = 0,
    lt_poc_lsb_sps: [32]u16 = undefined,
    lt_used_sps: u32 = 0,
    temporal_mvp: bool = false,
    strong_intra_smoothing: bool = false,
    // The range extension (7.3.2.2.2).
    transform_skip_rotation: bool = false,
    transform_skip_context: bool = false,
    implicit_rdpcm: bool = false,
    explicit_rdpcm: bool = false,
    extended_precision: bool = false,
    intra_smoothing_disabled: bool = false,
    high_precision_offsets: bool = false,
    persistent_rice: bool = false,
    cabac_bypass_alignment: bool = false,
    // VUI
    timing: bool = false,
    num_units_in_tick: u32 = 0,
    time_scale: u32 = 0,
    full_range: bool = false,
    matrix: u8 = 2,
    colour_primaries: u8 = 2,
    transfer: u8 = 2,

    /// A profile of the second edition or later, whose streams may use
    /// the extensions: the range extensions (4) and those after them.
    pub fn extensionProfile(s: *const Sps) bool {
        return s.profile_idc >= 4 or s.profile_compat >> 4 != 0;
    }

    /// ChromaArrayType: 0 with separate colour planes.
    pub fn chromaArrayType(s: *const Sps) u2 {
        return if (s.separate_colour_plane) 0 else s.chroma_format_idc;
    }
    /// SubWidthC and SubHeightC as shifts (Table 6-1).
    pub fn shiftW(s: *const Sps) u1 {
        return if (s.chroma_format_idc == 1 or s.chroma_format_idc == 2) 1 else 0;
    }
    pub fn shiftH(s: *const Sps) u1 {
        return if (s.chroma_format_idc == 1) 1 else 0;
    }
    pub fn ctbSize(s: *const Sps) u32 {
        return @as(u32, 1) << s.log2_ctb;
    }
    pub fn widthCtbs(s: *const Sps) u32 {
        return (s.width + s.ctbSize() - 1) >> s.log2_ctb;
    }
    pub fn heightCtbs(s: *const Sps) u32 {
        return (s.height + s.ctbSize() - 1) >> s.log2_ctb;
    }
    /// The picture's size as shown: its conformance window.
    pub fn croppedWidth(s: *const Sps) u32 {
        return s.width - ((s.conf_left + s.conf_right) << s.shiftW());
    }
    pub fn croppedHeight(s: *const Sps) u32 {
        return s.height - ((s.conf_top + s.conf_bottom) << s.shiftH());
    }
    pub fn cropX(s: *const Sps) u32 {
        return s.conf_left << s.shiftW();
    }
    pub fn cropY(s: *const Sps) u32 {
        return s.conf_top << s.shiftH();
    }
};

pub const max_tile_columns = 64;
pub const max_tile_rows = 64;

pub const Pps = struct {
    valid: bool = false,
    sps_id: u8 = 0,
    dependent_slice_segments: bool = false,
    output_flag_present: bool = false,
    num_extra_slice_header_bits: u3 = 0,
    sign_data_hiding: bool = false,
    cabac_init_present: bool = false,
    num_ref_idx_default: [2]u8 = .{ 1, 1 },
    /// 26 + init_qp_minus26.
    init_qp: i32 = 26,
    constrained_intra_pred: bool = false,
    transform_skip: bool = false,
    cu_qp_delta_enabled: bool = false,
    diff_cu_qp_delta_depth: u3 = 0,
    cb_qp_offset: i8 = 0,
    cr_qp_offset: i8 = 0,
    slice_chroma_qp_offsets_present: bool = false,
    weighted_pred: bool = false,
    weighted_bipred: bool = false,
    transquant_bypass: bool = false,
    tiles: bool = false,
    entropy_coding_sync: bool = false,
    num_tile_columns: u32 = 1,
    num_tile_rows: u32 = 1,
    uniform_spacing: bool = true,
    column_width: [max_tile_columns]u16 = undefined,
    row_height: [max_tile_rows]u16 = undefined,
    loop_filter_across_tiles: bool = true,
    loop_filter_across_slices: bool = false,
    deblocking_override_enabled: bool = false,
    deblocking_disabled: bool = false,
    /// pps_beta_offset_div2 and pps_tc_offset_div2, times 2.
    beta_offset: i8 = 0,
    tc_offset: i8 = 0,
    scaling_present: bool = false,
    scaling: ScalingList = undefined,
    lists_modification_present: bool = false,
    log2_parallel_merge_level: u3 = 2,
    slice_header_extension_present: bool = false,
    // The range extension (7.3.2.3.2).
    log2_max_transform_skip_size: u3 = 2,
    cross_component_prediction: bool = false,
    chroma_qp_offset_list_enabled: bool = false,
    diff_cu_chroma_qp_offset_depth: u3 = 0,
    chroma_qp_offset_list_len: u3 = 0,
    cb_qp_offset_list: [6]i8 = @splat(0),
    cr_qp_offset_list: [6]i8 = @splat(0),
    log2_sao_offset_scale_luma: u3 = 0,
    log2_sao_offset_scale_chroma: u3 = 0,
};

// --- the parts ---------------------------------------------------------------

/// profile_tier_level( 1, maxNumSubLayersMinus1 ) (7.3.3): the general
/// profile and level kept, the rest passed over.
fn profileTierLevel(b: *Bits, s: *Sps, max_sub_layers_minus1: u32) void {
    // profile_space, tier, profile_idc
    const first = b.u(8);
    s.profile_idc = @intCast(first & 31);
    s.profile_compat = @bitReverse(b.u(32));
    // progressive, interlaced, non_packed, frame_only, then 43 bits of
    // constraints and one more.
    b.skip(4 + 43 + 1);
    s.level_idc = @intCast(b.u(8));
    var profile_present: u32 = 0;
    var level_present: u32 = 0;
    for (0..max_sub_layers_minus1) |i| {
        if (b.flag()) profile_present |= @as(u32, 1) << @intCast(i);
        if (b.flag()) level_present |= @as(u32, 1) << @intCast(i);
    }
    if (max_sub_layers_minus1 > 0) b.skip(2 * (8 - max_sub_layers_minus1));
    for (0..max_sub_layers_minus1) |i| {
        if (profile_present >> @intCast(i) & 1 != 0) b.skip(2 + 1 + 5 + 32 + 4 + 43 + 1);
        if (level_present >> @intCast(i) & 1 != 0) b.skip(8);
    }
}

/// scaling_list_data( ) (7.3.4) into `l`.
fn scalingListData(b: *Bits, l: *ScalingList) Error!void {
    for (0..4) |size| {
        const coefs: usize = if (size == 0) 16 else 64;
        var m: usize = 0;
        while (m < 6) : (m += if (size == 3) 3 else 1) {
            if (!b.flag()) {
                // Predicted: from the default list, or an earlier one.
                const step: usize = if (size == 3) 3 else 1;
                const delta = try b.ueMax(@intCast(m / step));
                if (delta == 0) {
                    const d = ScalingList.default();
                    l.coef[size][m] = d.coef[size][m];
                    if (size > 1) l.dc[size - 2][m] = 16;
                } else {
                    const ref = m - delta * step;
                    l.coef[size][m] = l.coef[size][ref];
                    if (size > 1) l.dc[size - 2][m] = l.dc[size - 2][ref];
                }
            } else {
                var next: i32 = 8;
                if (size > 1) {
                    const dc = try b.seRange(-7, 247);
                    next = dc + 8;
                    l.dc[size - 2][m] = @intCast(next);
                }
                for (0..coefs) |i| {
                    const delta = try b.seRange(-128, 127);
                    next = @mod(next + delta + 256, 256);
                    if (next == 0) return error.Corrupt;
                    l.coef[size][m][i] = @intCast(next);
                }
            }
        }
    }
    // The 32x32 chroma lists, for 4:4:4 (7-50, 7-51): the 16x16 ones.
    for ([_]usize{ 1, 2, 4, 5 }) |m| {
        l.coef[3][m] = l.coef[2][m];
        l.dc[1][m] = l.dc[0][m];
    }
}

/// st_ref_pic_set( idx ) (7.3.7) into `sets[idx]`; `sets[0..idx]` are
/// the SPS's sets before it, `count` the SPS's number of them.
pub fn stRefPicSet(b: *Bits, sets: []StRps, idx: usize, count: usize) Error!void {
    const r = &sets[idx];
    r.* = .{};
    if (idx != 0 and b.flag()) {
        // Predicted from another set (7-61, 7-62).
        var delta_idx: usize = 1;
        if (idx == count) delta_idx = try b.ueMax(@intCast(idx - 1)) + 1;
        const src = &sets[idx - delta_idx];
        const sign = b.flag();
        const abs = try b.ueMax(32767) + 1;
        const delta_rps: i32 = if (sign) -@as(i32, @intCast(abs)) else @intCast(abs);
        const n = src.count();
        var used: u32 = 0;
        var use_delta: u32 = 0;
        for (0..n + 1) |j| {
            const u = b.flag();
            var d = true;
            if (!u) d = b.flag();
            if (u) used |= @as(u32, 1) << @intCast(j);
            if (d) use_delta |= @as(u32, 1) << @intCast(j);
        }
        const neg: usize = src.num_negative;
        const pos: usize = src.num_positive;
        var i: usize = 0;
        var j: usize = pos;
        while (j > 0) {
            j -= 1;
            const d = src.delta_s1[j] + delta_rps;
            if (d < 0 and use_delta >> @intCast(neg + j) & 1 != 0) {
                if (i >= max_rps) return error.Corrupt;
                r.delta_s0[i] = d;
                if (used >> @intCast(neg + j) & 1 != 0) r.used_s0 |= @as(u16, 1) << @intCast(i);
                i += 1;
            }
        }
        if (delta_rps < 0 and use_delta >> @intCast(n) & 1 != 0) {
            if (i >= max_rps) return error.Corrupt;
            r.delta_s0[i] = delta_rps;
            if (used >> @intCast(n) & 1 != 0) r.used_s0 |= @as(u16, 1) << @intCast(i);
            i += 1;
        }
        for (0..neg) |k| {
            const d = src.delta_s0[k] + delta_rps;
            if (d < 0 and use_delta >> @intCast(k) & 1 != 0) {
                if (i >= max_rps) return error.Corrupt;
                r.delta_s0[i] = d;
                if (used >> @intCast(k) & 1 != 0) r.used_s0 |= @as(u16, 1) << @intCast(i);
                i += 1;
            }
        }
        r.num_negative = @intCast(i);
        i = 0;
        j = neg;
        while (j > 0) {
            j -= 1;
            const d = src.delta_s0[j] + delta_rps;
            if (d > 0 and use_delta >> @intCast(j) & 1 != 0) {
                if (i >= max_rps) return error.Corrupt;
                r.delta_s1[i] = d;
                if (used >> @intCast(j) & 1 != 0) r.used_s1 |= @as(u16, 1) << @intCast(i);
                i += 1;
            }
        }
        if (delta_rps > 0 and use_delta >> @intCast(n) & 1 != 0) {
            if (i >= max_rps) return error.Corrupt;
            r.delta_s1[i] = delta_rps;
            if (used >> @intCast(n) & 1 != 0) r.used_s1 |= @as(u16, 1) << @intCast(i);
            i += 1;
        }
        for (0..pos) |k| {
            const d = src.delta_s1[k] + delta_rps;
            if (d > 0 and use_delta >> @intCast(neg + k) & 1 != 0) {
                if (i >= max_rps) return error.Corrupt;
                r.delta_s1[i] = d;
                if (used >> @intCast(neg + k) & 1 != 0) r.used_s1 |= @as(u16, 1) << @intCast(i);
                i += 1;
            }
        }
        r.num_positive = @intCast(i);
        return;
    }
    const neg = try b.ueMax(max_rps - 1);
    const pos = try b.ueMax(max_rps - 1);
    r.num_negative = @intCast(neg);
    r.num_positive = @intCast(pos);
    var poc: i32 = 0;
    for (0..neg) |i| {
        poc -= @intCast(try b.ueMax(32767) + 1);
        r.delta_s0[i] = poc;
        if (b.flag()) r.used_s0 |= @as(u16, 1) << @intCast(i);
    }
    poc = 0;
    for (0..pos) |i| {
        poc += @intCast(try b.ueMax(32767) + 1);
        r.delta_s1[i] = poc;
        if (b.flag()) r.used_s1 |= @as(u16, 1) << @intCast(i);
    }
}

/// hrd_parameters( ) (E.2.2), passed over.
fn hrdParameters(b: *Bits, common: bool, max_sub_layers_minus1: u32) Error!void {
    var nal = false;
    var vcl = false;
    var sub_pic = false;
    if (common) {
        nal = b.flag();
        vcl = b.flag();
        if (nal or vcl) {
            sub_pic = b.flag();
            if (sub_pic) b.skip(8 + 5 + 1 + 5);
            b.skip(4 + 4);
            if (sub_pic) b.skip(4);
            b.skip(5 + 5 + 5);
        }
    }
    for (0..max_sub_layers_minus1 + 1) |_| {
        const fixed_general = b.flag();
        var fixed_cvs = true;
        if (!fixed_general) fixed_cvs = b.flag();
        var low_delay = false;
        if (fixed_cvs) _ = try b.ue() else low_delay = b.flag();
        var cpb_count: u32 = 1;
        if (!low_delay) cpb_count = try b.ueMax(31) + 1;
        const lists = @as(u32, @intFromBool(nal)) + @intFromBool(vcl);
        for (0..lists) |_| {
            for (0..cpb_count) |_| {
                _ = try b.ue();
                _ = try b.ue();
                if (sub_pic) {
                    _ = try b.ue();
                    _ = try b.ue();
                }
                b.skip(1);
            }
        }
    }
}

/// vui_parameters( ) (E.2.1): the colours and the timing kept.
fn vuiParameters(b: *Bits, s: *Sps, max_sub_layers_minus1: u32) Error!void {
    if (b.flag()) {
        // aspect_ratio_idc, EXTENDED_SAR's size
        if (b.u(8) == 255) b.skip(32);
    }
    if (b.flag()) b.skip(1);
    if (b.flag()) {
        b.skip(3);
        s.full_range = b.flag();
        if (b.flag()) {
            s.colour_primaries = @intCast(b.u(8));
            s.transfer = @intCast(b.u(8));
            s.matrix = @intCast(b.u(8));
        }
    }
    if (b.flag()) {
        _ = try b.ue();
        _ = try b.ue();
    }
    // neutral_chroma_indication, field_seq, frame_field_info_present
    b.skip(3);
    if (b.flag()) {
        for (0..4) |_| _ = try b.ue();
    }
    if (b.flag()) {
        s.num_units_in_tick = b.u(32);
        s.time_scale = b.u(32);
        s.timing = true;
        if (b.flag()) _ = try b.ue();
        if (b.flag()) try hrdParameters(b, true, max_sub_layers_minus1);
    }
    if (b.flag()) {
        b.skip(3);
        for (0..5) |_| _ = try b.ue();
    }
}

// --- the sets ----------------------------------------------------------------

/// A sequence parameter set (7.3.2.2.1) into `s`; its id.
pub fn parseSps(b: *Bits, s: *Sps, limits: Limits) Error!u8 {
    s.* = .{};
    b.skip(4); // sps_video_parameter_set_id
    const max_sub_layers_minus1 = b.u(3);
    if (max_sub_layers_minus1 > 6) return error.Corrupt;
    s.max_sub_layers = @intCast(max_sub_layers_minus1 + 1);
    b.skip(1);
    profileTierLevel(b, s, max_sub_layers_minus1);
    const id = try b.ueMax(15);
    s.chroma_format_idc = @intCast(try b.ueMax(3));
    if (s.chroma_format_idc == 3) s.separate_colour_plane = b.flag();
    if (s.separate_colour_plane) return error.Unsupported;
    s.width = try b.ue();
    s.height = try b.ue();
    if (s.width == 0 or s.height == 0) return error.Corrupt;
    if (s.width > limits.max_width or s.height > limits.max_height or s.width * s.height > limits.max_samples) return error.Unsupported;
    if (b.flag()) {
        s.conf_left = try b.ueMax(s.width);
        s.conf_right = try b.ueMax(s.width);
        s.conf_top = try b.ueMax(s.height);
        s.conf_bottom = try b.ueMax(s.height);
    }
    if ((s.conf_left + s.conf_right) << s.shiftW() >= s.width or (s.conf_top + s.conf_bottom) << s.shiftH() >= s.height) return error.Corrupt;
    const depth_y = try b.ueMax(8);
    const depth_c = try b.ueMax(8);
    s.bit_depth_luma = @intCast(depth_y + 8);
    s.bit_depth_chroma = @intCast(depth_c + 8);
    s.log2_max_poc_lsb = @intCast(try b.ueMax(12) + 4);
    const ordering_all = b.flag();
    var i: u32 = if (ordering_all) 0 else max_sub_layers_minus1;
    while (i <= max_sub_layers_minus1) : (i += 1) {
        s.max_dec_pic_buffering = try b.ueMax(15) + 1;
        s.max_num_reorder = try b.ueMax(s.max_dec_pic_buffering - 1);
        const latency_plus1 = try b.ue();
        s.max_latency = if (latency_plus1 != 0) s.max_num_reorder + latency_plus1 - 1 else 0;
    }
    const min_cb = try b.ueMax(3) + 3;
    const diff_cb = try b.ueMax(3);
    if (min_cb + diff_cb > 6) return error.Corrupt;
    s.log2_min_cb = @intCast(min_cb);
    s.log2_ctb = @intCast(min_cb + diff_cb);
    if (s.width & ((@as(u32, 1) << s.log2_min_cb) - 1) != 0 or s.height & ((@as(u32, 1) << s.log2_min_cb) - 1) != 0) return error.Corrupt;
    const min_tb = try b.ueMax(3) + 2;
    const diff_tb = try b.ueMax(3);
    if (min_tb >= min_cb or min_tb + diff_tb > @min(5, s.log2_ctb)) return error.Corrupt;
    s.log2_min_tb = @intCast(min_tb);
    s.log2_max_tb = @intCast(min_tb + diff_tb);
    s.max_th_depth_inter = @intCast(try b.ueMax(s.log2_ctb - min_tb));
    s.max_th_depth_intra = @intCast(try b.ueMax(s.log2_ctb - min_tb));
    s.scaling_enabled = b.flag();
    if (s.scaling_enabled) {
        s.scaling = ScalingList.default();
        if (b.flag()) try scalingListData(b, &s.scaling);
    }
    s.amp = b.flag();
    s.sao = b.flag();
    s.pcm = b.flag();
    if (s.pcm) {
        s.pcm_depth_luma = @intCast(b.u(4) + 1);
        s.pcm_depth_chroma = @intCast(b.u(4) + 1);
        if (s.pcm_depth_luma > s.bit_depth_luma or s.pcm_depth_chroma > s.bit_depth_chroma) return error.Corrupt;
        const min_pcm = try b.ueMax(2) + 3;
        const diff_pcm = try b.ueMax(2);
        // The sizes outside the coding block sizes are never used.
        if (min_pcm + diff_pcm > 5) return error.Corrupt;
        s.log2_min_pcm = @intCast(min_pcm);
        s.log2_max_pcm = @intCast(min_pcm + diff_pcm);
        s.pcm_loop_filter_disabled = b.flag();
    }
    s.num_st_rps = @intCast(try b.ueMax(64));
    for (0..s.num_st_rps) |k| try stRefPicSet(b, &s.st_rps, k, s.num_st_rps);
    s.long_term_present = b.flag();
    if (s.long_term_present) {
        s.num_lt_sps = @intCast(try b.ueMax(32));
        for (0..s.num_lt_sps) |k| {
            s.lt_poc_lsb_sps[k] = @intCast(b.u(s.log2_max_poc_lsb));
            if (b.flag()) s.lt_used_sps |= @as(u32, 1) << @intCast(k);
        }
    }
    s.temporal_mvp = b.flag();
    s.strong_intra_smoothing = b.flag();
    if (b.flag()) try vuiParameters(b, s, max_sub_layers_minus1);
    // Streams of the first edition may carry anything after
    // sps_extension_flag; only a profile with the extensions reads them.
    if (b.flag() and s.extensionProfile()) {
        const range = b.flag();
        const multilayer = b.flag();
        const ext3d = b.flag();
        const scc = b.flag();
        _ = b.u(4);
        if (range) {
            s.transform_skip_rotation = b.flag();
            s.transform_skip_context = b.flag();
            s.implicit_rdpcm = b.flag();
            s.explicit_rdpcm = b.flag();
            s.extended_precision = b.flag();
            s.intra_smoothing_disabled = b.flag();
            s.high_precision_offsets = b.flag();
            s.persistent_rice = b.flag();
            s.cabac_bypass_alignment = b.flag();
        }
        // inter_view_mv_vert_constraint_flag: of the layers above.
        if (multilayer) b.skip(1);
        if (ext3d or scc) return error.Unsupported;
    }
    if (b.overrun()) return error.Corrupt;
    s.valid = true;
    return @intCast(id);
}

/// A picture parameter set (7.3.2.3.1) into `p`; its id. Its extensions
/// are read when `sps`, the sequence it names as far as it is known
/// yet, has a profile with them.
pub fn parsePps(b: *Bits, p: *Pps, sps: ?*const Sps) Error!u8 {
    p.* = .{};
    const id = try b.ueMax(63);
    p.sps_id = @intCast(try b.ueMax(15));
    p.dependent_slice_segments = b.flag();
    p.output_flag_present = b.flag();
    p.num_extra_slice_header_bits = @intCast(b.u(3));
    p.sign_data_hiding = b.flag();
    p.cabac_init_present = b.flag();
    p.num_ref_idx_default[0] = @intCast(try b.ueMax(14) + 1);
    p.num_ref_idx_default[1] = @intCast(try b.ueMax(14) + 1);
    // Down to -(26 + QpBdOffsetY): checked against the SPS when used.
    p.init_qp = 26 + try b.seRange(-26 - 48, 25);
    p.constrained_intra_pred = b.flag();
    p.transform_skip = b.flag();
    p.cu_qp_delta_enabled = b.flag();
    if (p.cu_qp_delta_enabled) p.diff_cu_qp_delta_depth = @intCast(try b.ueMax(3));
    p.cb_qp_offset = @intCast(try b.seRange(-12, 12));
    p.cr_qp_offset = @intCast(try b.seRange(-12, 12));
    p.slice_chroma_qp_offsets_present = b.flag();
    p.weighted_pred = b.flag();
    p.weighted_bipred = b.flag();
    p.transquant_bypass = b.flag();
    p.tiles = b.flag();
    p.entropy_coding_sync = b.flag();
    if (p.tiles) {
        p.num_tile_columns = try b.ue() + 1;
        p.num_tile_rows = try b.ue() + 1;
        if (p.num_tile_columns > max_tile_columns or p.num_tile_rows > max_tile_rows) return error.Unsupported;
        p.uniform_spacing = b.flag();
        if (!p.uniform_spacing) {
            for (0..p.num_tile_columns - 1) |k| p.column_width[k] = @intCast(try b.ueMax(4095) + 1);
            for (0..p.num_tile_rows - 1) |k| p.row_height[k] = @intCast(try b.ueMax(4095) + 1);
        }
        p.loop_filter_across_tiles = b.flag();
    }
    p.loop_filter_across_slices = b.flag();
    if (b.flag()) {
        p.deblocking_override_enabled = b.flag();
        p.deblocking_disabled = b.flag();
        if (!p.deblocking_disabled) {
            p.beta_offset = @intCast(2 * try b.seRange(-6, 6));
            p.tc_offset = @intCast(2 * try b.seRange(-6, 6));
        }
    }
    p.scaling_present = b.flag();
    if (p.scaling_present) {
        p.scaling = ScalingList.default();
        try scalingListData(b, &p.scaling);
    }
    p.lists_modification_present = b.flag();
    p.log2_parallel_merge_level = @intCast(try b.ueMax(4) + 2);
    p.slice_header_extension_present = b.flag();
    const extensions = if (sps) |s| s.valid and s.extensionProfile() else true;
    if (b.flag() and extensions) {
        const range = b.flag();
        const multilayer = b.flag();
        const ext3d = b.flag();
        const scc = b.flag();
        _ = b.u(4);
        if (range) {
            // Streams from before the extension was final may say more
            // than 3; any size up to 32x32 is what that comes to.
            if (p.transform_skip) p.log2_max_transform_skip_size = @intCast(@min(try b.ueMax(31) + 2, 5));
            p.cross_component_prediction = b.flag();
            p.chroma_qp_offset_list_enabled = b.flag();
            if (p.chroma_qp_offset_list_enabled) {
                p.diff_cu_chroma_qp_offset_depth = @intCast(try b.ueMax(3));
                p.chroma_qp_offset_list_len = @intCast(try b.ueMax(5) + 1);
                for (0..p.chroma_qp_offset_list_len) |k| {
                    p.cb_qp_offset_list[k] = @intCast(try b.seRange(-12, 12));
                    p.cr_qp_offset_list[k] = @intCast(try b.seRange(-12, 12));
                }
            }
            p.log2_sao_offset_scale_luma = @intCast(try b.ueMax(6));
            p.log2_sao_offset_scale_chroma = @intCast(try b.ueMax(6));
        }
        // The multilayer and 3D extensions are of the layers above, and
        // the last of what the base layer needs came before them.
        _ = multilayer;
        _ = ext3d;
        if (scc) return error.Unsupported;
    }
    if (b.overrun()) return error.Corrupt;
    p.valid = true;
    return @intCast(id);
}

/// What a picture parameter set may say only of a sequence it suits:
/// checked once the sequence is known, when a picture uses the two.
pub fn checkPps(p: *const Pps, s: *const Sps) Error!void {
    const qp_bd_offset: i32 = 6 * @as(i32, s.bit_depth_luma - 8);
    if (p.init_qp < -qp_bd_offset) return error.Corrupt;
    if (p.diff_cu_qp_delta_depth > s.log2_ctb - s.log2_min_cb) return error.Corrupt;
    if (p.log2_parallel_merge_level > s.log2_ctb) return error.Corrupt;
    if (p.log2_max_transform_skip_size > 5) return error.Corrupt;
    if (p.diff_cu_chroma_qp_offset_depth > s.log2_ctb - s.log2_min_cb) return error.Corrupt;
    if (p.log2_sao_offset_scale_luma > @max(0, @as(i32, s.bit_depth_luma) - 10)) return error.Corrupt;
    if (p.log2_sao_offset_scale_chroma > @max(0, @as(i32, s.bit_depth_chroma) - 10)) return error.Corrupt;
    if (p.tiles) {
        if (p.num_tile_columns > s.widthCtbs() or p.num_tile_rows > s.heightCtbs()) return error.Corrupt;
        if (!p.uniform_spacing) {
            var sum: u32 = 0;
            for (p.column_width[0 .. p.num_tile_columns - 1]) |w| sum += w;
            if (sum >= s.widthCtbs()) return error.Corrupt;
            sum = 0;
            for (p.row_height[0 .. p.num_tile_rows - 1]) |h| sum += h;
            if (sum >= s.heightCtbs()) return error.Corrupt;
        }
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "short-term sets: coded, and predicted from another" {
    // Set 0: two before (-1 used, -3 not), one after (+2 used).
    // 1 | 011 | 1 | 011 (delta 2) 0 | 010 (delta 2) 1
    // Then set 1, predicted from set 0 by deltaRps -1:
    // inter flag 1 | sign 1 | abs-1 = 0: 1 | four used flags 1,1,1,1
    var data = [_]u8{ 0, 0, 0, 0, 0, 0 };
    var w: usize = 0;
    const put = struct {
        fn f(d: []u8, at: *usize, v: u32, n: u5) void {
            var k: u5 = n;
            while (k > 0) {
                k -= 1;
                if (v >> k & 1 != 0) d[at.* >> 3] |= @as(u8, 0x80) >> @intCast(at.* & 7);
                at.* += 1;
            }
        }
    }.f;
    put(&data, &w, 0b011, 3); // num_negative 2
    put(&data, &w, 0b010, 3); // num_positive 1
    put(&data, &w, 0b1, 1); // delta_poc_s0_minus1 0 -> -1
    put(&data, &w, 0b1, 1); // used
    put(&data, &w, 0b010, 3); // delta_poc_s0_minus1 1 -> -3
    put(&data, &w, 0b0, 1); // not used
    put(&data, &w, 0b010, 3); // delta_poc_s1_minus1 1 -> +2
    put(&data, &w, 0b1, 1); // used
    put(&data, &w, 0b1, 1); // inter_ref_pic_set_prediction_flag
    put(&data, &w, 0b1, 1); // delta_rps_sign
    put(&data, &w, 0b1, 1); // abs_delta_rps_minus1 0
    put(&data, &w, 0b1111, 4); // used_by_curr_pic_flag for -1, -3, +2 and the deltaRps itself
    var b = Bits.init(&data);
    var sets: [2]StRps = undefined;
    try stRefPicSet(&b, &sets, 0, 2);
    try testing.expectEqual(@as(u8, 2), sets[0].num_negative);
    try testing.expectEqual(@as(i32, -3), sets[0].delta_s0[1]);
    try testing.expectEqual(@as(u16, 1), sets[0].used_s0);
    try stRefPicSet(&b, &sets, 1, 2);
    // -1-1 = -2, -3-1 = -4, +2-1 = +1, and deltaRps -1 itself.
    try testing.expectEqual(@as(u8, 3), sets[1].num_negative);
    try testing.expectEqual(@as(u8, 1), sets[1].num_positive);
    try testing.expectEqualSlices(i32, &.{ -1, -2, -4 }, sets[1].delta_s0[0..3]);
    try testing.expectEqual(@as(i32, 1), sets[1].delta_s1[0]);
    try testing.expectEqual(@as(u32, 4), sets[1].usedCount());
}
