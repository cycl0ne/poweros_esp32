// SPDX-License-Identifier: MIT
//! HEVC's syntax as videoparse.library reads it (ITU-T H.265 / ISO
//! 23008-2): the sequence and picture parameter sets with their range
//! extensions (7.3.2.2, 7.3.2.3, annex E's VUI), the scaling lists
//! (7.3.4), the short-term reference picture sets (7.3.7) and the slice
//! segment header (7.3.6), each field the standard's syntax element in
//! snake_case, with what follows from them.
//!
//! The library hands these out by pointer in its events (`sdk.videoparse`):
//! the parameter sets a picture uses with `VPEV_PICTURE`, a slice
//! segment's header with `VPEV_SLICE`. They are the library's, read only,
//! valid until the next call on the parser. The scaling lists are
//! resolved - predicted ones copied, the defaults put where a set says
//! none - and kept in the up-right diagonal order they are coded in.
//!
//! The video parameter set says nothing a decoder of the base layer needs
//! and is passed over; so is everything of the layers above it.

/// The most pictures of either kind a short-term set holds (each count
/// is bounded by sps_max_dec_pic_buffering_minus1, at most 15).
pub const max_rps = 16;

/// The most entries of a reference picture list.
pub const max_refs = 16;

/// A short-term reference picture set (7.4.8): the pictures before the
/// current one (S0, nearest first) and after it (S1), as differences of
/// picture order count, and which of them the current picture uses.
pub const HevcStRps = extern struct {
    num_negative: u8 = 0,
    num_positive: u8 = 0,
    /// used_by_curr_pic_s0_flag and _s1_flag, bit i for entry i.
    used_s0: u16 = 0,
    used_s1: u16 = 0,
    delta_s0: [max_rps]i32 = @splat(0),
    delta_s1: [max_rps]i32 = @splat(0),

    pub fn count(r: *const HevcStRps) u32 {
        return @as(u32, r.num_negative) + r.num_positive;
    }
    /// The pictures of it the current picture refers to.
    pub fn usedCount(r: *const HevcStRps) u32 {
        return @popCount(r.used_s0) + @popCount(r.used_s1);
    }
};

/// Scaling lists (7.3.4): for each size (4x4, 8x8, 16x16, 32x32) and
/// matrix (intra Y, Cb, Cr, inter Y, Cb, Cr) its coefficients in up-right
/// diagonal order - 16 for 4x4, 64 for the rest - and the DC of the
/// 16x16 and 32x32 ones.
pub const HevcScaling = extern struct {
    coef: [4][6][64]u8 = undefined,
    dc: [2][6]u8 = undefined,

    /// Tables 7-5 and 7-6.
    pub fn default() HevcScaling {
        var l: HevcScaling = undefined;
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

/// A sequence parameter set.
pub const HevcSps = extern struct {
    /// Read whole: a picture parameter set may name it.
    valid: bool = false,
    sps_id: u8 = 0,
    /// general_profile_idc, general_level_idc, and
    /// general_profile_compatibility_flag[ j ] as bit j.
    profile_idc: u8 = 0,
    level_idc: u8 = 0,
    profile_compat: u32 = 0,
    /// sps_max_sub_layers_minus1 + 1.
    max_sub_layers: u8 = 1,
    chroma_format_idc: u8 = 1,
    separate_colour_plane: bool = false,
    /// BitDepthY and BitDepthC: 8 plus the coded value.
    bit_depth_luma: u8 = 8,
    bit_depth_chroma: u8 = 8,
    /// log2_max_pic_order_cnt_lsb_minus4 + 4.
    log2_max_poc_lsb: u8 = 4,
    /// pic_width_in_luma_samples and pic_height_in_luma_samples.
    width: u32 = 0,
    height: u32 = 0,
    /// The conformance window, in chroma samples (luma when grey).
    conf_left: u32 = 0,
    conf_right: u32 = 0,
    conf_top: u32 = 0,
    conf_bottom: u32 = 0,
    /// Of the highest sub-layer: sps_max_dec_pic_buffering_minus1 + 1,
    /// sps_max_num_reorder_pics and SpsMaxLatencyPictures (0: none).
    max_dec_pic_buffering: u32 = 1,
    max_num_reorder: u32 = 0,
    max_latency: u32 = 0,
    /// MinCbLog2SizeY, CtbLog2SizeY, MinTbLog2SizeY, MaxTbLog2SizeY.
    log2_min_cb: u8 = 3,
    log2_ctb: u8 = 4,
    log2_min_tb: u8 = 2,
    log2_max_tb: u8 = 5,
    /// max_transform_hierarchy_depth_inter and _intra.
    max_th_depth_inter: u8 = 0,
    max_th_depth_intra: u8 = 0,
    /// scaling_list_enabled_flag; `scaling` holds the lists, the default
    /// ones where the SPS gives none.
    scaling_enabled: bool = false,
    /// amp_enabled_flag, sample_adaptive_offset_enabled_flag,
    /// pcm_enabled_flag.
    amp: bool = false,
    sao: bool = false,
    pcm: bool = false,
    /// PcmBitDepthY, PcmBitDepthC, Log2MinIpcmCbSizeY, Log2MaxIpcmCbSizeY.
    pcm_depth_luma: u8 = 8,
    pcm_depth_chroma: u8 = 8,
    log2_min_pcm: u8 = 3,
    log2_max_pcm: u8 = 3,
    pcm_loop_filter_disabled: bool = false,
    /// num_short_term_ref_pic_sets, long_term_ref_pics_present_flag,
    /// num_long_term_ref_pics_sps.
    num_st_rps: u8 = 0,
    long_term_present: bool = false,
    num_lt_sps: u8 = 0,
    /// sps_temporal_mvp_enabled_flag, strong_intra_smoothing_enabled_flag.
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
    // The VUI's: timing_info_present_flag and its two, video_full_range_flag
    // and the three colour descriptions (2, unspecified, when absent).
    timing: bool = false,
    full_range: bool = false,
    matrix: u8 = 2,
    colour_primaries: u8 = 2,
    transfer: u8 = 2,
    num_units_in_tick: u32 = 0,
    time_scale: u32 = 0,
    /// lt_ref_pic_poc_lsb_sps[ i ], and used_by_curr_pic_lt_sps_flag[ i ]
    /// as bit i.
    lt_poc_lsb_sps: [32]u16 = undefined,
    lt_used_sps: u32 = 0,
    st_rps: [64]HevcStRps = undefined,
    scaling: HevcScaling = undefined,

    /// A profile of the second edition or later, whose streams may use
    /// the extensions: the range extensions (4) and those after them.
    pub fn extensionProfile(s: *const HevcSps) bool {
        return s.profile_idc >= 4 or s.profile_compat >> 4 != 0;
    }
    /// ChromaArrayType: 0 with separate colour planes.
    pub fn chromaArrayType(s: *const HevcSps) u2 {
        return if (s.separate_colour_plane) 0 else @intCast(s.chroma_format_idc);
    }
    /// SubWidthC and SubHeightC as shifts (Table 6-1).
    pub fn shiftW(s: *const HevcSps) u1 {
        return if (s.chroma_format_idc == 1 or s.chroma_format_idc == 2) 1 else 0;
    }
    pub fn shiftH(s: *const HevcSps) u1 {
        return if (s.chroma_format_idc == 1) 1 else 0;
    }
    /// CtbSizeY, PicWidthInCtbsY, PicHeightInCtbsY.
    pub fn ctbSize(s: *const HevcSps) u32 {
        return @as(u32, 1) << @intCast(s.log2_ctb);
    }
    pub fn widthCtbs(s: *const HevcSps) u32 {
        return (s.width + s.ctbSize() - 1) >> @intCast(s.log2_ctb);
    }
    pub fn heightCtbs(s: *const HevcSps) u32 {
        return (s.height + s.ctbSize() - 1) >> @intCast(s.log2_ctb);
    }
    /// The picture's size as shown: its conformance window.
    pub fn croppedWidth(s: *const HevcSps) u32 {
        return s.width - ((s.conf_left + s.conf_right) << s.shiftW());
    }
    pub fn croppedHeight(s: *const HevcSps) u32 {
        return s.height - ((s.conf_top + s.conf_bottom) << s.shiftH());
    }
    pub fn cropX(s: *const HevcSps) u32 {
        return s.conf_left << s.shiftW();
    }
    pub fn cropY(s: *const HevcSps) u32 {
        return s.conf_top << s.shiftH();
    }
};

/// The most tile columns and rows a picture parameter set may say.
pub const max_tile_columns = 64;
pub const max_tile_rows = 64;

/// A picture parameter set.
pub const HevcPps = extern struct {
    /// Read whole: a slice may name it.
    valid: bool = false,
    pps_id: u8 = 0,
    sps_id: u8 = 0,
    /// dependent_slice_segments_enabled_flag, output_flag_present_flag,
    /// num_extra_slice_header_bits, sign_data_hiding_enabled_flag,
    /// cabac_init_present_flag.
    dependent_slice_segments: bool = false,
    output_flag_present: bool = false,
    num_extra_slice_header_bits: u8 = 0,
    sign_data_hiding: bool = false,
    cabac_init_present: bool = false,
    /// num_ref_idx_l0_default_active_minus1 + 1, and l1's.
    num_ref_idx_default: [2]u8 = .{ 1, 1 },
    constrained_intra_pred: bool = false,
    /// transform_skip_enabled_flag, cu_qp_delta_enabled_flag,
    /// diff_cu_qp_delta_depth.
    transform_skip: bool = false,
    cu_qp_delta_enabled: bool = false,
    diff_cu_qp_delta_depth: u8 = 0,
    /// pps_cb_qp_offset, pps_cr_qp_offset,
    /// pps_slice_chroma_qp_offsets_present_flag.
    cb_qp_offset: i8 = 0,
    cr_qp_offset: i8 = 0,
    slice_chroma_qp_offsets_present: bool = false,
    weighted_pred: bool = false,
    weighted_bipred: bool = false,
    /// transquant_bypass_enabled_flag, tiles_enabled_flag,
    /// entropy_coding_sync_enabled_flag.
    transquant_bypass: bool = false,
    tiles: bool = false,
    entropy_coding_sync: bool = false,
    /// uniform_spacing_flag, loop_filter_across_tiles_enabled_flag,
    /// pps_loop_filter_across_slices_enabled_flag.
    uniform_spacing: bool = true,
    loop_filter_across_tiles: bool = true,
    loop_filter_across_slices: bool = false,
    /// deblocking_filter_override_enabled_flag,
    /// pps_deblocking_filter_disabled_flag.
    deblocking_override_enabled: bool = false,
    deblocking_disabled: bool = false,
    /// pps_beta_offset_div2 and pps_tc_offset_div2, times 2.
    beta_offset: i8 = 0,
    tc_offset: i8 = 0,
    /// pps_scaling_list_data_present_flag: `scaling` holds its lists.
    scaling_present: bool = false,
    lists_modification_present: bool = false,
    /// log2_parallel_merge_level_minus2 + 2.
    log2_parallel_merge_level: u8 = 2,
    slice_header_extension_present: bool = false,
    // The range extension (7.3.2.3.2): log2_max_transform_skip_block_size_minus2
    // + 2, cross_component_prediction_enabled_flag,
    // chroma_qp_offset_list_enabled_flag, diff_cu_chroma_qp_offset_depth,
    // chroma_qp_offset_list_len_minus1 + 1 and the lists,
    // log2_sao_offset_scale_luma and _chroma.
    log2_max_transform_skip_size: u8 = 2,
    cross_component_prediction: bool = false,
    chroma_qp_offset_list_enabled: bool = false,
    diff_cu_chroma_qp_offset_depth: u8 = 0,
    chroma_qp_offset_list_len: u8 = 0,
    cb_qp_offset_list: [6]i8 = @splat(0),
    cr_qp_offset_list: [6]i8 = @splat(0),
    log2_sao_offset_scale_luma: u8 = 0,
    log2_sao_offset_scale_chroma: u8 = 0,
    /// 26 + init_qp_minus26.
    init_qp: i32 = 26,
    /// num_tile_columns_minus1 + 1, num_tile_rows_minus1 + 1, and the
    /// columns' widths and rows' heights in CTBs but the last (when not
    /// uniform).
    num_tile_columns: u32 = 1,
    num_tile_rows: u32 = 1,
    column_width: [max_tile_columns]u16 = undefined,
    row_height: [max_tile_rows]u16 = undefined,
    scaling: HevcScaling = undefined,
};

/// slice_type.
pub const HevcSliceType = enum(u8) { b = 0, p = 1, i = 2 };

/// pred_weight_table( ) (7.3.6.3) as the weighted prediction uses it.
pub const HevcWeights = extern struct {
    luma_log2_denom: u8 = 0,
    /// ChromaLog2WeightDenom.
    chroma_log2_denom: u8 = 0,
    /// LumaWeightLX and luma_offset_lX, ChromaWeightLX for Cb and Cr.
    luma_weight: [2][max_refs]i16 = @splat(@splat(0)),
    luma_offset: [2][max_refs]i16 = @splat(@splat(0)),
    chroma_weight: [2][max_refs][2]i16 = @splat(@splat(.{ 0, 0 })),
    /// ChromaOffsetLX (7-58), not yet shifted to the sample depth.
    chroma_offset: [2][max_refs][2]i16 = @splat(@splat(.{ 0, 0 })),
};

/// A slice segment header. A dependent segment's holds its slice's
/// independent segment's fields, its own address, and its own entry
/// points.
pub const HevcSliceHeader = extern struct {
    first_slice_in_pic: bool = false,
    no_output_of_prior_pics: bool = false,
    pps_id: u8 = 0,
    /// dependent_slice_segment_flag.
    dependent: bool = false,
    /// slice_segment_address, and SliceAddrRs: the address of the
    /// independent segment the slice began with.
    segment_address: u32 = 0,
    slice_addr: u32 = 0,
    slice_type: HevcSliceType = .i,
    /// pic_output_flag.
    pic_output: bool = true,
    /// short_term_ref_pic_set_sps_flag, short_term_ref_pic_set_idx.
    st_rps_sps: bool = false,
    st_rps_idx: u8 = 0,
    /// slice_pic_order_cnt_lsb.
    poc_lsb: u32 = 0,
    /// The bits the header's own st_ref_pic_set( ) took (0 when it names
    /// one of the SPS's).
    st_rps_bits: u32 = 0,
    /// num_long_term_sps + num_long_term_pics.
    num_lt: u8 = 0,
    /// slice_temporal_mvp_enabled_flag, slice_sao_luma_flag,
    /// slice_sao_chroma_flag.
    temporal_mvp: bool = false,
    sao_luma: bool = false,
    sao_chroma: bool = false,
    /// num_ref_idx_l0_active_minus1 + 1, and l1's (0 where there is no
    /// such list).
    num_ref_idx: [2]u8 = .{ 0, 0 },
    /// ref_pic_list_modification_flag_lX, and list_entry_lX.
    list_modified: [2]bool = .{ false, false },
    list_entry: [2][max_refs]u8 = @splat(@splat(0)),
    mvd_l1_zero: bool = false,
    /// cabac_init_flag, collocated_from_l0_flag, collocated_ref_idx.
    cabac_init: bool = false,
    collocated_from_l0: bool = true,
    collocated_ref_idx: u8 = 0,
    /// The PPS weights this slice's lists: `weights` holds them.
    weighted: bool = false,
    /// MaxNumMergeCand.
    max_num_merge_cand: u8 = 5,
    /// slice_cb_qp_offset, slice_cr_qp_offset,
    /// cu_chroma_qp_offset_enabled_flag.
    cb_qp_offset: i8 = 0,
    cr_qp_offset: i8 = 0,
    cu_chroma_qp_offset: bool = false,
    /// slice_deblocking_filter_disabled_flag, and slice_beta_offset_div2
    /// and slice_tc_offset_div2 times 2 (the PPS's where not overridden).
    deblocking_disabled: bool = false,
    beta_offset: i8 = 0,
    tc_offset: i8 = 0,
    /// slice_loop_filter_across_slices_enabled_flag.
    loop_filter_across_slices: bool = false,
    /// SliceQpY.
    qp: i32 = 26,
    /// num_entry_point_offsets.
    num_entry_points: u32 = 0,
    /// Where the slice data starts, in bytes of the payload after the
    /// unit's header, the emulation prevention bytes taken out.
    data_offset: u32 = 0,
    // The long-term pictures: PocLsbLt, UsedByCurrPicLt and
    // delta_poc_msb_present_flag of each as bit i, and DeltaPocMsbCycleLt.
    lt_used: u32 = 0,
    lt_msb_present: u32 = 0,
    lt_poc_lsb: [32]u32 = undefined,
    lt_msb_cycle: [32]u32 = undefined,
    /// The header's own short-term set (when `st_rps_sps` is not set).
    st_rps: HevcStRps = .{},
    weights: HevcWeights = .{},

    /// The short-term set the picture uses.
    pub fn rps(h: *const HevcSliceHeader, sps: *const HevcSps) *const HevcStRps {
        return if (h.st_rps_sps) &sps.st_rps[h.st_rps_idx] else &h.st_rps;
    }
    /// NumPicTotalCurr (7-55).
    pub fn numPicTotalCurr(h: *const HevcSliceHeader, sps: *const HevcSps) u32 {
        return h.rps(sps).usedCount() + @popCount(h.lt_used);
    }
    /// initType (9-7).
    pub fn initType(h: *const HevcSliceHeader) u2 {
        return switch (h.slice_type) {
            .i => 0,
            .p => if (h.cabac_init) 2 else 1,
            .b => if (h.cabac_init) 1 else 2,
        };
    }
};
