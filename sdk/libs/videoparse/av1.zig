// SPDX-License-Identifier: MIT
//! AV1's syntax as videoparse.library reads it (AV1 Bitstream & Decoding
//! Process Specification, 2019): the sequence header (5.5) and a frame's
//! uncompressed header (5.9) with what it takes from the frames before
//! it applied - the loop filter's deltas, the segmentation's features,
//! the global motion it predicts from, and for a frame shown again the
//! film grain it was stored with.
//!
//! The library hands them out by pointer with `VPEV_PICTURE` and with an
//! AV1 frame's `VPEV_SHOW` (`sdk.videoparse`): the library's, read only,
//! valid until the next call on the parser. Each field is the
//! specification's syntax element or variable in snake_case; where the
//! stream codes a value less one or two (`_minus_1`), the field holds
//! the value.

/// frame_type.
pub const KEY_FRAME: u8 = 0;
pub const INTER_FRAME: u8 = 1;
pub const INTRA_ONLY_FRAME: u8 = 2;
pub const SWITCH_FRAME: u8 = 3;

/// primary_ref_frame of a frame that starts from the defaults.
pub const PRIMARY_REF_NONE: u8 = 7;

/// The references a frame names, by `ref_frame_idx`'s index plus 1 and
/// by `ref_frame_sign_bias`'s, `order_hints`' and `gm_params`' index.
pub const INTRA_FRAME = 0;
pub const LAST_FRAME = 1;
pub const LAST2_FRAME = 2;
pub const LAST3_FRAME = 3;
pub const GOLDEN_FRAME = 4;
pub const BWDREF_FRAME = 5;
pub const ALTREF2_FRAME = 6;
pub const ALTREF_FRAME = 7;

/// interpolation_filter: the four filters, or chosen block by block.
pub const EIGHTTAP: u8 = 0;
pub const EIGHTTAP_SMOOTH: u8 = 1;
pub const EIGHTTAP_SHARP: u8 = 2;
pub const BILINEAR: u8 = 3;
pub const SWITCHABLE: u8 = 4;

/// GmType: the global motion of a reference.
pub const IDENTITY: u8 = 0;
pub const TRANSLATION: u8 = 1;
pub const ROTZOOM: u8 = 2;
pub const AFFINE: u8 = 3;
/// The fraction bits of `gm_params`.
pub const WARPEDMODEL_PREC_BITS = 16;

/// FrameRestorationType, as lr_type is mapped (remap_lr_type).
pub const RESTORE_NONE: u8 = 0;
pub const RESTORE_WIENER: u8 = 1;
pub const RESTORE_SGRPROJ: u8 = 2;
pub const RESTORE_SWITCHABLE: u8 = 3;

/// TxMode.
pub const ONLY_4X4: u8 = 0;
pub const TX_MODE_LARGEST: u8 = 1;
pub const TX_MODE_SELECT: u8 = 2;

/// The segmentation's features, by `feature_enabled`'s and
/// `feature_data`'s second index.
pub const SEG_LVL_ALT_Q = 0;
pub const SEG_LVL_ALT_LF_Y_V = 1;
pub const SEG_LVL_REF_FRAME = 5;
pub const SEG_LVL_SKIP = 6;
pub const SEG_LVL_GLOBALMV = 7;
pub const MAX_SEGMENTS = 8;
pub const SEG_LVL_MAX = 8;

/// seq_force_screen_content_tools and seq_force_integer_mv: chosen frame
/// by frame.
pub const SELECT_SCREEN_CONTENT_TOOLS: u8 = 2;
pub const SELECT_INTEGER_MV: u8 = 2;

/// The colour descriptions (6.4.2) a stream coded as RGB says.
pub const CP_BT_709: u8 = 1;
pub const TC_SRGB: u8 = 13;
pub const MC_IDENTITY: u8 = 0;

/// The tiles a frame has across and down at most.
pub const MAX_TILE_COLS = 64;
pub const MAX_TILE_ROWS = 64;

/// The sequence header (5.5), of the operating point the library reads:
/// operating point 0, the stream's every layer most often.
pub const Av1Sequence = extern struct {
    seq_profile: u8 = 0,
    still_picture: bool = false,
    reduced_still_picture_header: bool = false,
    timing_info_present_flag: bool = false,
    /// timing_info: the clock's ticks a display tick lasts and their
    /// rate, and with `equal_picture_interval` the display ticks a
    /// picture lasts.
    num_units_in_display_tick: u32 = 0,
    time_scale: u32 = 0,
    equal_picture_interval: bool = false,
    num_ticks_per_picture: u32 = 0,
    decoder_model_info_present_flag: bool = false,
    buffer_removal_time_length: u8 = 0,
    frame_presentation_time_length: u8 = 0,
    /// The operating points, and each one's layers, level and whether a
    /// decoder model is given for it.
    operating_points: u8 = 1,
    operating_point_idc: [32]u16 = @splat(0),
    seq_level_idx: [32]u8 = @splat(0),
    decoder_model_present_for_this_op: [32]bool = @splat(false),
    /// OperatingPointIdc: the layers of the operating point read - 0, all
    /// of them.
    chosen_operating_point_idc: u16 = 0,
    frame_width_bits: u8 = 0,
    frame_height_bits: u8 = 0,
    /// The largest frame the header says. A frame larger is read all the
    /// same: some encoders round the largest down where the frames' sizes
    /// are rounded up.
    max_frame_width: u32 = 0,
    max_frame_height: u32 = 0,
    frame_id_numbers_present_flag: bool = false,
    delta_frame_id_length: u8 = 0,
    /// The frame id's bits: additional_frame_id_length and
    /// `delta_frame_id_length`.
    frame_id_length: u8 = 0,
    use_128x128_superblock: bool = false,
    enable_filter_intra: bool = false,
    enable_intra_edge_filter: bool = false,
    enable_interintra_compound: bool = false,
    enable_masked_compound: bool = false,
    enable_warped_motion: bool = false,
    enable_dual_filter: bool = false,
    enable_order_hint: bool = false,
    enable_jnt_comp: bool = false,
    enable_ref_frame_mvs: bool = false,
    /// 0, 1, or SELECT_SCREEN_CONTENT_TOOLS / SELECT_INTEGER_MV.
    seq_force_screen_content_tools: u8 = SELECT_SCREEN_CONTENT_TOOLS,
    seq_force_integer_mv: u8 = SELECT_INTEGER_MV,
    /// OrderHintBits: 0 without order hints.
    order_hint_bits: u8 = 0,
    enable_superres: bool = false,
    enable_cdef: bool = false,
    enable_restoration: bool = false,
    /// color_config (5.5.2): BitDepth, and the colour.
    bit_depth: u8 = 8,
    mono_chrome: bool = false,
    color_primaries: u8 = 2,
    transfer_characteristics: u8 = 2,
    matrix_coefficients: u8 = 2,
    /// The whole byte.
    color_range: bool = false,
    subsampling_x: u8 = 1,
    subsampling_y: u8 = 1,
    chroma_sample_position: u8 = 0,
    separate_uv_delta_q: bool = false,
    film_grain_params_present: bool = false,
};

/// The film grain's parameters (5.9.30), `apply_grain` false where none
/// is added.
pub const Av1FilmGrain = extern struct {
    apply_grain: bool = false,
    grain_seed: u16 = 0,
    num_y_points: u8 = 0,
    point_y_value: [16]u8 = @splat(0),
    point_y_scaling: [16]u8 = @splat(0),
    chroma_scaling_from_luma: bool = false,
    num_cb_points: u8 = 0,
    point_cb_value: [16]u8 = @splat(0),
    point_cb_scaling: [16]u8 = @splat(0),
    num_cr_points: u8 = 0,
    point_cr_value: [16]u8 = @splat(0),
    point_cr_scaling: [16]u8 = @splat(0),
    grain_scaling_minus_8: u8 = 0,
    ar_coeff_lag: u8 = 0,
    ar_coeffs_y_plus_128: [24]u8 = @splat(0),
    ar_coeffs_cb_plus_128: [25]u8 = @splat(0),
    ar_coeffs_cr_plus_128: [25]u8 = @splat(0),
    ar_coeff_shift_minus_6: u8 = 0,
    grain_scale_shift: u8 = 0,
    cb_mult: u8 = 0,
    cb_luma_mult: u8 = 0,
    cb_offset: u16 = 0,
    cr_mult: u8 = 0,
    cr_luma_mult: u8 = 0,
    cr_offset: u16 = 0,
    overlap_flag: bool = false,
    clip_to_restricted_range: bool = false,
};

/// A frame's uncompressed header, what it takes from the frames before it
/// applied: the settings `primary_ref_frame` loads (load_previous), the
/// references set_frame_refs finds, the film grain load_grain_params
/// loads.
pub const Av1FrameHeader = extern struct {
    /// The frame only shows the one in reference slot
    /// `frame_to_show_map_idx`: its type, and the film grain it is shown
    /// with, are that frame's; nothing else of the header is read.
    show_existing_frame: bool = false,
    frame_to_show_map_idx: u8 = 0,
    frame_type: u8 = KEY_FRAME,
    /// FrameIsIntra: a key frame or an intra-only one.
    frame_is_intra: bool = false,
    show_frame: bool = false,
    showable_frame: bool = false,
    error_resilient_mode: bool = false,
    disable_cdf_update: bool = false,
    allow_screen_content_tools: bool = false,
    force_integer_mv: bool = false,
    current_frame_id: u32 = 0,
    frame_size_override_flag: bool = false,
    order_hint: u32 = 0,
    primary_ref_frame: u8 = PRIMARY_REF_NONE,
    /// The reference slots the frame goes into, bit i for slot i.
    refresh_frame_flags: u8 = 0,
    allow_intrabc: bool = false,
    /// The slots LAST_FRAME to ALTREF_FRAME name, by their number less 1.
    ref_frame_idx: [7]u8 = @splat(0),
    allow_high_precision_mv: bool = false,
    /// EIGHTTAP to SWITCHABLE.
    interpolation_filter: u8 = 0,
    is_motion_mode_switchable: bool = false,
    use_ref_frame_mvs: bool = false,
    disable_frame_end_update_cdf: bool = true,
    /// OrderHints and RefFrameSignBias, by reference, LAST_FRAME to
    /// ALTREF_FRAME.
    order_hints: [8]u32 = @splat(0),
    ref_frame_sign_bias: [8]bool = @splat(false),
    /// RefOrderHint as the frame sees the eight slots: an error resilient
    /// frame says them again.
    ref_order_hint: [8]u32 = @splat(0),

    /// FrameWidth - narrower than UpscaledWidth with superres - and
    /// FrameHeight, and the size the frame is meant to be shown at.
    frame_width: u32 = 0,
    frame_height: u32 = 0,
    upscaled_width: u32 = 0,
    render_width: u32 = 0,
    render_height: u32 = 0,
    use_superres: bool = false,
    /// SuperresDenom: 8 without superres.
    superres_denom: u32 = 8,
    mi_cols: u32 = 0,
    mi_rows: u32 = 0,

    /// tile_info (5.9.15): TileCols and TileRows, their logarithms, and
    /// where each tile column and row starts, in 4x4 units (MiColStarts,
    /// MiRowStarts), one past the last its end.
    tile_cols: u32 = 1,
    tile_rows: u32 = 1,
    tile_cols_log2: u8 = 0,
    tile_rows_log2: u8 = 0,
    mi_col_starts: [MAX_TILE_COLS + 1]u32 = @splat(0),
    mi_row_starts: [MAX_TILE_ROWS + 1]u32 = @splat(0),
    context_update_tile_id: u32 = 0,
    /// TileSizeBytes: the bytes of each tile's size in a tile group.
    tile_size_bytes: u32 = 4,

    /// quantization_params (5.9.12), delta_q_params and delta_lf_params
    /// (5.9.17, 5.9.18): `delta_q_res` and `delta_lf_res` as read, the
    /// steps' logarithms.
    base_q_idx: u8 = 0,
    delta_q_y_dc: i8 = 0,
    delta_q_u_dc: i8 = 0,
    delta_q_u_ac: i8 = 0,
    delta_q_v_dc: i8 = 0,
    delta_q_v_ac: i8 = 0,
    using_qmatrix: bool = false,
    qm_y: u8 = 15,
    qm_u: u8 = 15,
    qm_v: u8 = 15,
    delta_q_present: bool = false,
    delta_q_res: u8 = 0,
    delta_lf_present: bool = false,
    delta_lf_res: u8 = 0,
    delta_lf_multi: bool = false,
    /// LosslessArray by segment, CodedLossless, AllLossless and
    /// SegQMLevel.
    lossless: [8]bool = @splat(false),
    coded_lossless: bool = false,
    all_lossless: bool = false,
    seg_qm_level: [3][8]u8 = @splat(@splat(15)),

    /// segmentation_params (5.9.14): FeatureEnabled and FeatureData by
    /// segment and feature, SegIdPreSkip and LastActiveSegId.
    segmentation_enabled: bool = false,
    segmentation_update_map: bool = false,
    segmentation_temporal_update: bool = false,
    segmentation_update_data: bool = false,
    feature_enabled: [8][8]bool = @splat(@splat(false)),
    feature_data: [8][8]i16 = @splat(@splat(0)),
    seg_id_pre_skip: bool = false,
    last_active_seg_id: u8 = 0,

    /// loop_filter_params (5.9.11): the four levels, and the changes by
    /// reference (INTRA_FRAME to ALTREF_FRAME) and by mode.
    loop_filter_level: [4]u8 = @splat(0),
    loop_filter_sharpness: u8 = 0,
    loop_filter_delta_enabled: bool = false,
    loop_filter_delta_update: bool = false,
    loop_filter_ref_deltas: [8]i8 = .{ 1, 0, 0, 0, -1, 0, -1, -1 },
    loop_filter_mode_deltas: [2]i8 = .{ 0, 0 },

    /// cdef_params (5.9.19): CdefDamping, and the strengths, secondary
    /// ones 4 where the stream says 3. `enable_cdef`: the filter runs on
    /// the frame - the sequence allows it, and the frame is neither coded
    /// lossless nor copies blocks within itself.
    cdef_damping: u8 = 3,
    cdef_bits: u8 = 0,
    cdef_y_pri_strength: [8]u8 = @splat(0),
    cdef_y_sec_strength: [8]u8 = @splat(0),
    cdef_uv_pri_strength: [8]u8 = @splat(0),
    cdef_uv_sec_strength: [8]u8 = @splat(0),
    enable_cdef: bool = false,

    /// lr_params (5.9.20): FrameRestorationType and LoopRestorationSize
    /// by plane, and UsesLr.
    frame_restoration_type: [3]u8 = @splat(RESTORE_NONE),
    loop_restoration_size: [3]u32 = @splat(64),
    uses_lr: bool = false,

    /// TxMode.
    tx_mode: u8 = 0,
    reference_select: bool = false,
    skip_mode_present: bool = false,
    /// SkipModeFrame: the two references skip mode reads.
    skip_mode_frame: [2]i8 = .{ 0, 0 },
    allow_warped_motion: bool = false,
    reduced_tx_set: bool = false,
    /// global_motion_params (5.9.24): GmType and gm_params by reference,
    /// LAST_FRAME to ALTREF_FRAME; the identity at INTRA_FRAME and for a
    /// reference without global motion.
    gm_type: [8]u8 = @splat(IDENTITY),
    gm_params: [8][6]i32 = @splat(.{ 0, 0, 1 << WARPEDMODEL_PREC_BITS, 0, 0, 1 << WARPEDMODEL_PREC_BITS }),
    film_grain: Av1FilmGrain = .{},
};
