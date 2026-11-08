// SPDX-License-Identifier: MIT
//! H.264's syntax as videoparse.library reads it (ITU-T H.264 / ISO
//! 14496-10): the sequence and picture parameter sets (7.3.2.1, 7.3.2.2,
//! annex E's VUI) and the slice header (7.3.3), each field the standard's
//! syntax element in snake_case, with what follows from them.
//!
//! The library hands these out by pointer in its events (`sdk.videoparse`):
//! the parameter sets a picture uses with `VPEV_PICTURE`, a slice's header
//! with `VPEV_SLICE`. They are the library's, read only, valid until the
//! next call on the parser. The scaling lists are resolved - the
//! fall-backs and the defaults applied - and in raster order.

/// The scan orders the lists are coded in: where the j-th coded value
/// goes in raster order, 4x4 and 8x8 (8.5.6, frame scan).
pub const zigzag4 = [16]u8{ 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };
pub const zigzag8 = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

/// The scaling matrices in raster order: six 4x4 (intra Y, Cb, Cr, inter
/// Y, Cb, Cr) and six 8x8 (intra Y, inter Y, intra Cb, inter Cb, intra
/// Cr, inter Cr).
pub const H264Scaling = extern struct {
    m4: [6][16]u8 = @splat(@splat(16)),
    m8: [6][64]u8 = @splat(@splat(16)),
};

/// A sequence parameter set.
pub const H264Sps = extern struct {
    /// Read whole: a slice may name it.
    valid: bool = false,
    sps_id: u8 = 0,
    profile_idc: u8 = 0,
    /// constraint_set0_flag to constraint_set5_flag and the two reserved
    /// bits, as the byte holds them.
    constraint_flags: u8 = 0,
    level_idc: u8 = 0,
    chroma_format_idc: u8 = 1,
    separate_colour_plane: bool = false,
    /// BitDepthY and BitDepthC: 8 plus the coded value.
    bit_depth_luma: u8 = 8,
    bit_depth_chroma: u8 = 8,
    /// qpprime_y_zero_transform_bypass_flag.
    transform_bypass: bool = false,
    /// seq_scaling_matrix_present_flag.
    scaling_present: bool = false,
    /// log2_max_frame_num_minus4 + 4, and log2_max_pic_order_cnt_lsb_minus4
    /// + 4.
    log2_max_frame_num: u8 = 4,
    poc_type: u8 = 0,
    log2_max_poc_lsb: u8 = 4,
    delta_pic_order_always_zero: bool = false,
    num_ref_frames_in_poc_cycle: u8 = 0,
    max_num_ref_frames: u8 = 0,
    /// gaps_in_frame_num_value_allowed_flag.
    gaps_allowed: bool = false,
    frame_mbs_only: bool = true,
    /// mb_adaptive_frame_field_flag.
    mbaff: bool = false,
    direct_8x8_inference: bool = false,
    offset_for_non_ref_pic: i32 = 0,
    offset_for_top_to_bottom_field: i32 = 0,
    /// pic_width_in_mbs_minus1 + 1, pic_height_in_map_units_minus1 + 1.
    width_mbs: u32 = 0,
    height_map_units: u32 = 0,
    /// frame_crop_*_offset, in the crop units of 7.4.2.1.1.
    crop_left: u32 = 0,
    crop_right: u32 = 0,
    crop_top: u32 = 0,
    crop_bottom: u32 = 0,
    // The VUI's: timing_info_present_flag and its two, video_full_range_flag
    // and the three colour descriptions (2, unspecified, when absent),
    // bitstream_restriction_flag and its two.
    timing: bool = false,
    full_range: bool = false,
    matrix: u8 = 2,
    colour_primaries: u8 = 2,
    transfer: u8 = 2,
    restriction: bool = false,
    num_units_in_tick: u32 = 0,
    time_scale: u32 = 0,
    num_reorder_frames: u32 = 0,
    max_dec_frame_buffering: u32 = 0,
    scaling: H264Scaling = .{},
    offset_for_ref_frame: [255]i32 = @splat(0),

    /// ChromaArrayType: 0 with separate colour planes.
    pub fn chromaArrayType(s: *const H264Sps) u2 {
        return if (s.separate_colour_plane) 0 else @intCast(s.chroma_format_idc);
    }
    pub fn heightMbs(s: *const H264Sps) u32 {
        return s.height_map_units * @as(u32, if (s.frame_mbs_only) 1 else 2);
    }
    pub fn subWidthC(s: *const H264Sps) u32 {
        return if (s.chroma_format_idc == 1 or s.chroma_format_idc == 2) 2 else 1;
    }
    pub fn subHeightC(s: *const H264Sps) u32 {
        return if (s.chroma_format_idc == 1) 2 else 1;
    }
    /// The picture's size as shown, after cropping.
    pub fn croppedWidth(s: *const H264Sps) u32 {
        const unit: u32 = if (s.chromaArrayType() == 0) 1 else s.subWidthC();
        return s.width_mbs * 16 - unit * (s.crop_left + s.crop_right);
    }
    pub fn croppedHeight(s: *const H264Sps) u32 {
        const unit_y: u32 = (if (s.chromaArrayType() == 0) 1 else s.subHeightC()) * @as(u32, if (s.frame_mbs_only) 1 else 2);
        return s.heightMbs() * 16 - unit_y * (s.crop_top + s.crop_bottom);
    }
    pub fn cropX(s: *const H264Sps) u32 {
        return s.crop_left * (if (s.chromaArrayType() == 0) 1 else s.subWidthC());
    }
    pub fn cropY(s: *const H264Sps) u32 {
        return s.crop_top * (if (s.chromaArrayType() == 0) 1 else s.subHeightC()) * @as(u32, if (s.frame_mbs_only) 1 else 2);
    }
    /// MaxFrameNum.
    pub fn maxFrameNum(s: *const H264Sps) u32 {
        return @as(u32, 1) << @intCast(s.log2_max_frame_num);
    }
    /// The frames the decoded picture buffer holds (A.3.1, A.3.2), or what
    /// the VUI says it needs.
    pub fn dpbFrames(s: *const H264Sps) u32 {
        const mbs = s.width_mbs * s.heightMbs();
        const max_dpb_mbs: u32 = switch (s.level_idc) {
            9 => 396,
            10 => 396,
            11 => if (s.constraint_flags & 0x10 != 0 and s.profile_idc != 100 and s.profile_idc != 110 and s.profile_idc != 122 and s.profile_idc != 244) 396 else 900,
            12, 13, 20 => 2376,
            21 => 4752,
            22, 30 => 8100,
            31 => 18000,
            32 => 20480,
            40, 41 => 32768,
            42 => 34816,
            50 => 110400,
            51, 52 => 184320,
            else => 696320,
        };
        var frames: u32 = if (mbs == 0) 16 else @min(16, max_dpb_mbs / mbs);
        if (s.restriction and s.max_dec_frame_buffering != 0) frames = s.max_dec_frame_buffering;
        frames = @max(frames, s.max_num_ref_frames);
        return @max(1, @min(16, frames));
    }
};

/// A picture parameter set.
pub const H264Pps = extern struct {
    valid: bool = false,
    pps_id: u8 = 0,
    sps_id: u8 = 0,
    /// entropy_coding_mode_flag.
    cabac: bool = false,
    /// bottom_field_pic_order_in_frame_present_flag.
    bottom_field_poc_present: bool = false,
    /// num_slice_groups_minus1 + 1.
    num_slice_groups: u8 = 1,
    slice_group_map_type: u8 = 0,
    /// slice_group_change_direction_flag.
    change_direction: bool = false,
    /// num_ref_idx_l0/l1_default_active_minus1 + 1.
    num_ref_idx_default: [2]u8 = .{ 1, 1 },
    weighted_pred: bool = false,
    weighted_bipred_idc: u8 = 0,
    /// deblocking_filter_control_present_flag.
    deblocking_control: bool = false,
    constrained_intra_pred: bool = false,
    redundant_pic_cnt_present: bool = false,
    /// transform_8x8_mode_flag.
    transform_8x8: bool = false,
    /// pic_scaling_matrix_present_flag.
    scaling_present: bool = false,
    /// run_length_minus1 + 1, top_left and bottom_right of each group.
    run_length: [8]u32 = @splat(0),
    top_left: [8]u32 = @splat(0),
    bottom_right: [8]u32 = @splat(0),
    /// slice_group_change_rate_minus1 + 1.
    change_rate: u32 = 1,
    /// pic_init_qp_minus26 + 26, pic_init_qs_minus26 + 26.
    init_qp: i32 = 26,
    init_qs: i32 = 26,
    /// chroma_qp_index_offset and second_chroma_qp_index_offset.
    chroma_qp_offset: [2]i32 = .{ 0, 0 },
    /// Map type 6's slice_group_id of each map unit, PicSizeInMapUnits of
    /// them; null for the other types.
    group_ids: ?[*]const u8 = null,
    /// The lists the picture uses: its own, or the sequence's, or the
    /// flat 16 where neither has any.
    scaling: H264Scaling = .{},
};

/// slice_type, modulo 5.
pub const H264SliceKind = enum(u8) { p = 0, b = 1, i = 2, sp = 3, si = 4 };

/// A change to a reference list (7.3.3.1): modification_of_pic_nums_idc
/// and abs_diff_pic_num_minus1 or long_term_pic_num.
pub const H264ListOp = extern struct { idc: u8 = 0, value: u32 = 0 };

/// A memory management control operation (7.3.3.3): its number, and its
/// one or two values - difference_of_pic_nums_minus1 or long_term_pic_num
/// as `a`, long_term_frame_idx or max_long_term_frame_idx_plus1 as `b`
/// for 3 and 6 and as `a` for 4.
pub const H264Mmco = extern struct { op: u8 = 0, a: u32 = 0, b: u32 = 0 };

/// Explicit weights (7.3.3.2) for one list: luma, then Cb and Cr, each a
/// weight and an offset, by reference index.
pub const H264Weights = extern struct {
    luma_denom: u8 = 0,
    chroma_denom: u8 = 0,
    /// Whether the index has weights of its own, luma and chroma.
    luma_flag: [32]bool = @splat(false),
    chroma_flag: [32]bool = @splat(false),
    luma: [32][2]i16 = @splat(.{ 1, 0 }),
    chroma: [32][2][2]i16 = @splat(@splat(.{ 1, 0 })),
};

/// A slice header.
pub const H264SliceHeader = extern struct {
    /// The NAL unit's nal_unit_type and nal_ref_idc; an IDR picture's.
    nal_kind: u8 = 0,
    nal_ref_idc: u8 = 0,
    idr: bool = false,
    kind: H264SliceKind = .i,
    /// slice_type 5 to 9: every slice of the picture is this kind.
    all_same: bool = false,
    pps_id: u8 = 0,
    colour_plane: u8 = 0,
    field_pic: bool = false,
    bottom_field: bool = false,
    /// direct_spatial_mv_pred_flag.
    direct_spatial: bool = false,
    /// num_ref_idx_l0/l1_active_minus1 + 1 as they apply: the slice's or
    /// the PPS's.
    num_ref_idx: [2]u8 = .{ 0, 0 },
    list_op_count: [2]u8 = .{ 0, 0 },
    /// Explicit weights given: weighted_pred_flag for P and SP,
    /// weighted_bipred_idc 1 for B.
    weighted: bool = false,
    no_output_of_prior_pics: bool = false,
    long_term_reference: bool = false,
    /// adaptive_ref_pic_marking_mode_flag.
    adaptive_marking: bool = false,
    mmco_count: u8 = 0,
    cabac_init_idc: u8 = 0,
    /// sp_for_switch_flag.
    sp_for_switch: bool = false,
    /// disable_deblocking_filter_idc, slice_alpha_c0_offset_div2 * 2 and
    /// slice_beta_offset_div2 * 2.
    disable_deblocking: u8 = 0,
    alpha_offset: i8 = 0,
    beta_offset: i8 = 0,
    /// first_mb_in_slice.
    first_mb: u32 = 0,
    frame_num: u32 = 0,
    idr_pic_id: u32 = 0,
    /// pic_order_cnt_lsb, delta_pic_order_cnt_bottom, delta_pic_order_cnt.
    poc_lsb: u32 = 0,
    delta_poc_bottom: i32 = 0,
    delta_poc: [2]i32 = .{ 0, 0 },
    redundant_pic_cnt: u32 = 0,
    /// SliceQPY and QSY: 26 plus the PPS's plus the slice's delta.
    qp: i32 = 26,
    qs: i32 = 26,
    slice_group_change_cycle: u32 = 0,
    list_ops: [2][33]H264ListOp = @splat(@splat(.{})),
    weights: [2]H264Weights = .{ .{}, .{} },
    mmco: [66]H264Mmco = @splat(.{}),

    /// MbaffFrameFlag.
    pub fn mbaff(h: *const H264SliceHeader, sps: *const H264Sps) bool {
        return sps.mbaff and !h.field_pic;
    }
    pub fn isInter(h: *const H264SliceHeader) bool {
        return h.kind == .p or h.kind == .b or h.kind == .sp;
    }
};
