// SPDX-License-Identifier: MIT
//! A frame's CDFs (the arrays init_non_coeff_cdfs and init_coeff_cdfs
//! name): set to the defaults, loaded from a reference with the counters
//! cleared, copied for each tile and saved from one.

const d = @import("cdfs.zig");

/// The motion vectors' CDFs, of one context.
pub const MvCdfs = struct {
    joint: @TypeOf(d.default_mv_joint_cdf),
    class: @TypeOf(d.default_mv_class_cdf),
    class0_bit: [2]@TypeOf(d.default_mv_class0_bit_cdf),
    fr: @TypeOf(d.default_mv_fr_cdf),
    class0_fr: @TypeOf(d.default_mv_class0_fr_cdf),
    class0_hp: [2]@TypeOf(d.default_mv_class0_hp_cdf),
    sign: [2]@TypeOf(d.default_mv_sign_cdf),
    bit: [2]@TypeOf(d.default_mv_bit_cdf),
    hp: [2]@TypeOf(d.default_mv_hp_cdf),
};

pub const MV_CONTEXTS = 2;

/// Every CDF a tile reads; each field named as its default in
/// cdfs.zig, without the default_ and _cdf.
pub const Cdfs = struct {
    intra_frame_y_mode: @TypeOf(d.default_intra_frame_y_mode_cdf),
    y_mode: @TypeOf(d.default_y_mode_cdf),
    uv_mode_cfl_not_allowed: @TypeOf(d.default_uv_mode_cfl_not_allowed_cdf),
    uv_mode_cfl_allowed: @TypeOf(d.default_uv_mode_cfl_allowed_cdf),
    angle_delta: @TypeOf(d.default_angle_delta_cdf),
    intrabc: @TypeOf(d.default_intrabc_cdf),
    partition_w8: @TypeOf(d.default_partition_w8_cdf),
    partition_w16: @TypeOf(d.default_partition_w16_cdf),
    partition_w32: @TypeOf(d.default_partition_w32_cdf),
    partition_w64: @TypeOf(d.default_partition_w64_cdf),
    partition_w128: @TypeOf(d.default_partition_w128_cdf),
    segment_id: @TypeOf(d.default_segment_id_cdf),
    segment_id_predicted: @TypeOf(d.default_segment_id_predicted_cdf),
    tx_8x8: @TypeOf(d.default_tx_8x8_cdf),
    tx_16x16: @TypeOf(d.default_tx_16x16_cdf),
    tx_32x32: @TypeOf(d.default_tx_32x32_cdf),
    tx_64x64: @TypeOf(d.default_tx_64x64_cdf),
    txfm_split: @TypeOf(d.default_txfm_split_cdf),
    filter_intra_mode: @TypeOf(d.default_filter_intra_mode_cdf),
    filter_intra: @TypeOf(d.default_filter_intra_cdf),
    interp_filter: @TypeOf(d.default_interp_filter_cdf),
    motion_mode: @TypeOf(d.default_motion_mode_cdf),
    new_mv: @TypeOf(d.default_new_mv_cdf),
    zero_mv: @TypeOf(d.default_zero_mv_cdf),
    ref_mv: @TypeOf(d.default_ref_mv_cdf),
    compound_mode: @TypeOf(d.default_compound_mode_cdf),
    drl_mode: @TypeOf(d.default_drl_mode_cdf),
    is_inter: @TypeOf(d.default_is_inter_cdf),
    comp_mode: @TypeOf(d.default_comp_mode_cdf),
    skip_mode: @TypeOf(d.default_skip_mode_cdf),
    skip: @TypeOf(d.default_skip_cdf),
    comp_ref: @TypeOf(d.default_comp_ref_cdf),
    comp_bwd_ref: @TypeOf(d.default_comp_bwd_ref_cdf),
    single_ref: @TypeOf(d.default_single_ref_cdf),
    mv: [MV_CONTEXTS]MvCdfs,
    palette_y_mode: @TypeOf(d.default_palette_y_mode_cdf),
    palette_uv_mode: @TypeOf(d.default_palette_uv_mode_cdf),
    palette_y_size: @TypeOf(d.default_palette_y_size_cdf),
    palette_uv_size: @TypeOf(d.default_palette_uv_size_cdf),
    palette_size_2_y_color: @TypeOf(d.default_palette_size_2_y_color_cdf),
    palette_size_3_y_color: @TypeOf(d.default_palette_size_3_y_color_cdf),
    palette_size_4_y_color: @TypeOf(d.default_palette_size_4_y_color_cdf),
    palette_size_5_y_color: @TypeOf(d.default_palette_size_5_y_color_cdf),
    palette_size_6_y_color: @TypeOf(d.default_palette_size_6_y_color_cdf),
    palette_size_7_y_color: @TypeOf(d.default_palette_size_7_y_color_cdf),
    palette_size_8_y_color: @TypeOf(d.default_palette_size_8_y_color_cdf),
    palette_size_2_uv_color: @TypeOf(d.default_palette_size_2_uv_color_cdf),
    palette_size_3_uv_color: @TypeOf(d.default_palette_size_3_uv_color_cdf),
    palette_size_4_uv_color: @TypeOf(d.default_palette_size_4_uv_color_cdf),
    palette_size_5_uv_color: @TypeOf(d.default_palette_size_5_uv_color_cdf),
    palette_size_6_uv_color: @TypeOf(d.default_palette_size_6_uv_color_cdf),
    palette_size_7_uv_color: @TypeOf(d.default_palette_size_7_uv_color_cdf),
    palette_size_8_uv_color: @TypeOf(d.default_palette_size_8_uv_color_cdf),
    delta_q: @TypeOf(d.default_delta_q_cdf),
    delta_lf: @TypeOf(d.default_delta_lf_cdf),
    delta_lf_multi: [4]@TypeOf(d.default_delta_lf_cdf),
    intra_tx_type_set1: @TypeOf(d.default_intra_tx_type_set1_cdf),
    intra_tx_type_set2: @TypeOf(d.default_intra_tx_type_set2_cdf),
    inter_tx_type_set1: @TypeOf(d.default_inter_tx_type_set1_cdf),
    inter_tx_type_set2: @TypeOf(d.default_inter_tx_type_set2_cdf),
    inter_tx_type_set3: @TypeOf(d.default_inter_tx_type_set3_cdf),
    use_obmc: @TypeOf(d.default_use_obmc_cdf),
    inter_intra: @TypeOf(d.default_inter_intra_cdf),
    comp_ref_type: @TypeOf(d.default_comp_ref_type_cdf),
    cfl_sign: @TypeOf(d.default_cfl_sign_cdf),
    uni_comp_ref: @TypeOf(d.default_uni_comp_ref_cdf),
    wedge_inter_intra: @TypeOf(d.default_wedge_inter_intra_cdf),
    comp_group_idx: @TypeOf(d.default_comp_group_idx_cdf),
    compound_idx: @TypeOf(d.default_compound_idx_cdf),
    compound_type: @TypeOf(d.default_compound_type_cdf),
    inter_intra_mode: @TypeOf(d.default_inter_intra_mode_cdf),
    wedge_index: @TypeOf(d.default_wedge_index_cdf),
    cfl_alpha: @TypeOf(d.default_cfl_alpha_cdf),
    use_wiener: @TypeOf(d.default_use_wiener_cdf),
    use_sgrproj: @TypeOf(d.default_use_sgrproj_cdf),
    restoration_type: @TypeOf(d.default_restoration_type_cdf),

    // The coefficients', by the quantiser's class.
    txb_skip: @TypeOf(d.default_txb_skip_cdf[0]),
    eob_pt_16: @TypeOf(d.default_eob_pt_16_cdf[0]),
    eob_pt_32: @TypeOf(d.default_eob_pt_32_cdf[0]),
    eob_pt_64: @TypeOf(d.default_eob_pt_64_cdf[0]),
    eob_pt_128: @TypeOf(d.default_eob_pt_128_cdf[0]),
    eob_pt_256: @TypeOf(d.default_eob_pt_256_cdf[0]),
    eob_pt_512: @TypeOf(d.default_eob_pt_512_cdf[0]),
    eob_pt_1024: @TypeOf(d.default_eob_pt_1024_cdf[0]),
    eob_extra: @TypeOf(d.default_eob_extra_cdf[0]),
    dc_sign: @TypeOf(d.default_dc_sign_cdf[0]),
    coeff_base_eob: @TypeOf(d.default_coeff_base_eob_cdf[0]),
    coeff_base: @TypeOf(d.default_coeff_base_cdf[0]),
    coeff_br: @TypeOf(d.default_coeff_br_cdf[0]),

    const coeff_first = "txb_skip";

    fn isCoeff(comptime name: []const u8) bool {
        @setEvalBranchQuota(100000);
        const fields = @typeInfo(Cdfs).@"struct".fields;
        comptime var seen = false;
        inline for (fields) |fl| {
            if (comptime eql(fl.name, coeff_first)) seen = true;
            if (comptime eql(fl.name, name)) return seen;
        }
        unreachable;
    }

    /// init_non_coeff_cdfs.
    pub fn initNonCoeff(c: *Cdfs) void {
        inline for (@typeInfo(Cdfs).@"struct".fields) |fl| {
            const def = "default_" ++ fl.name ++ "_cdf";
            if (comptime !isCoeff(fl.name) and @hasDecl(d, def)) @field(c, fl.name) = @field(d, def);
        }
        const mv: MvCdfs = .{
            .joint = d.default_mv_joint_cdf,
            .class = d.default_mv_class_cdf,
            .class0_bit = @splat(d.default_mv_class0_bit_cdf),
            .fr = d.default_mv_fr_cdf,
            .class0_fr = d.default_mv_class0_fr_cdf,
            .class0_hp = @splat(d.default_mv_class0_hp_cdf),
            .sign = @splat(d.default_mv_sign_cdf),
            .bit = @splat(d.default_mv_bit_cdf),
            .hp = @splat(d.default_mv_hp_cdf),
        };
        c.mv = @splat(mv);
        c.delta_lf_multi = @splat(d.default_delta_lf_cdf);
    }

    /// init_coeff_cdfs, for the frame's base_q_idx.
    pub fn initCoeff(c: *Cdfs, base_q_idx: u8) void {
        const idx: usize = if (base_q_idx <= 20) 0 else if (base_q_idx <= 60) 1 else if (base_q_idx <= 120) 2 else 3;
        inline for (@typeInfo(Cdfs).@"struct".fields) |fl| {
            if (comptime isCoeff(fl.name)) @field(c, fl.name) = @field(d, "default_" ++ fl.name ++ "_cdf")[idx];
        }
    }

    /// The counters cleared, as load_cdfs leaves them.
    pub fn clearCounts(c: *Cdfs) void {
        clear(Cdfs, c);
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn clear(comptime T: type, p: *T) void {
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.fields) |fl| clear(fl.type, &@field(p, fl.name)),
        .array => |a| {
            if (a.child == u16) {
                p[a.len - 1] = 0;
            } else {
                for (p) |*e| clear(a.child, e);
            }
        },
        else => @compileError("not a CDF"),
    }
}
