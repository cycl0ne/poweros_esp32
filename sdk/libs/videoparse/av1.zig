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

/// The default CDFs (the specification's Default_*_Cdf tables), each a
/// symbol's cumulative probabilities times 32768, ending in 32768 and
/// the adaptation counter's 0: what a frame that starts from the
/// defaults reads with.
pub const cdfs = @import("av1_cdfs.zig");

/// Gaussian_Sequence (7.18.3.3): the values film grain's random numbers
/// pick, by 11 bits of them.
pub const gaussian_sequence: [2048]i16 = .{
    56,    568,   -180,  172,   124,   -84,   172,   -64,   -900,  24,    820,   224,   1248,  996,   272,   -8,    -916,  -388,
    -732,  -104,  -188,  800,   112,   -652,  -320,  -376,  140,   -252,  492,   -168,  44,    -788,  588,   -584,  500,   -228,
    12,    680,   272,   -476,  972,   -100,  652,   368,   432,   -196,  -720,  -192,  1000,  -332,  652,   -136,  -552,  -604,
    -4,    192,   -220,  -136,  1000,  -52,   372,   -96,   -624,  124,   -24,   396,   540,   -12,   -104,  640,   464,   244,
    -208,  -84,   368,   -528,  -740,  248,   -968,  -848,  608,   376,   -60,   -292,  -40,   -156,  252,   -292,  248,   224,
    -280,  400,   -244,  244,   -60,   76,    -80,   212,   532,   340,   128,   -36,   824,   -352,  -60,   -264,  -96,   -612,
    416,   -704,  220,   -204,  640,   -160,  1220,  -408,  900,   336,   20,    -336,  -96,   -792,  304,   48,    -28,   -1232,
    -1172, -448,  104,   -292,  -520,  244,   60,    -948,  0,     -708,  268,   108,   356,   -548,  488,   -344,  -136,  488,
    -196,  -224,  656,   -236,  -1128, 60,    4,     140,   276,   -676,  -376,  168,   -108,  464,   8,     564,   64,    240,
    308,   -300,  -400,  -456,  -136,  56,    120,   -408,  -116,  436,   504,   -232,  328,   844,   -164,  -84,   784,   -168,
    232,   -224,  348,   -376,  128,   568,   96,    -1244, -288,  276,   848,   832,   -360,  656,   464,   -384,  -332,  -356,
    728,   -388,  160,   -192,  468,   296,   224,   140,   -776,  -100,  280,   4,     196,   44,    -36,   -648,  932,   16,
    1428,  28,    528,   808,   772,   20,    268,   88,    -332,  -284,  124,   -384,  -448,  208,   -228,  -1044, -328,  660,
    380,   -148,  -300,  588,   240,   540,   28,    136,   -88,   -436,  256,   296,   -1000, 1400,  0,     -48,   1056,  -136,
    264,   -528,  -1108, 632,   -484,  -592,  -344,  796,   124,   -668,  -768,  388,   1296,  -232,  -188,  -200,  -288,  -4,
    308,   100,   -168,  256,   -500,  204,   -508,  648,   -136,  372,   -272,  -120,  -1004, -552,  -548,  -384,  548,   -296,
    428,   -108,  -8,    -912,  -324,  -224,  -88,   -112,  -220,  -100,  996,   -796,  548,   360,   -216,  180,   428,   -200,
    -212,  148,   96,    148,   284,   216,   -412,  -320,  120,   -300,  -384,  -604,  -572,  -332,  -8,    -180,  -176,  696,
    116,   -88,   628,   76,    44,    -516,  240,   -208,  -40,   100,   -592,  344,   -308,  -452,  -228,  20,    916,   -1752,
    -136,  -340,  -804,  140,   40,    512,   340,   248,   184,   -492,  896,   -156,  932,   -628,  328,   -688,  -448,  -616,
    -752,  -100,  560,   -1020, 180,   -800,  -64,   76,    576,   1068,  396,   660,   552,   -108,  -28,   320,   -628,  312,
    -92,   -92,   -472,  268,   16,    560,   516,   -672,  -52,   492,   -100,  260,   384,   284,   292,   304,   -148,  88,
    -152,  1012,  1064,  -228,  164,   -376,  -684,  592,   -392,  156,   196,   -524,  -64,   -884,  160,   -176,  636,   648,
    404,   -396,  -436,  864,   424,   -728,  988,   -604,  904,   -592,  296,   -224,  536,   -176,  -920,  436,   -48,   1176,
    -884,  416,   -776,  -824,  -884,  524,   -548,  -564,  -68,   -164,  -96,   692,   364,   -692,  -1012, -68,   260,   -480,
    876,   -1116, 452,   -332,  -352,  892,   -1088, 1220,  -676,  12,    -292,  244,   496,   372,   -32,   280,   200,   112,
    -440,  -96,   24,    -644,  -184,  56,    -432,  224,   -980,  272,   -260,  144,   -436,  420,   356,   364,   -528,  76,
    172,   -744,  -368,  404,   -752,  -416,  684,   -688,  72,    540,   416,   92,    444,   480,   -72,   -1416, 164,   -1172,
    -68,   24,    424,   264,   1040,  128,   -912,  -524,  -356,  64,    876,   -12,   4,     -88,   532,   272,   -524,  320,
    276,   -508,  940,   24,    -400,  -120,  756,   60,    236,   -412,  100,   376,   -484,  400,   -100,  -740,  -108,  -260,
    328,   -268,  224,   -200,  -416,  184,   -604,  -564,  -20,   296,   60,    892,   -888,  60,    164,   68,    -760,  216,
    -296,  904,   -336,  -28,   404,   -356,  -568,  -208,  -1480, -512,  296,   328,   -360,  -164,  -1560, -776,  1156,  -428,
    164,   -504,  -112,  120,   -216,  -148,  -264,  308,   32,    64,    -72,   72,    116,   176,   -64,   -272,  460,   -536,
    -784,  -280,  348,   108,   -752,  -132,  524,   -540,  -776,  116,   -296,  -1196, -288,  -560,  1040,  -472,  116,   -848,
    -1116, 116,   636,   696,   284,   -176,  1016,  204,   -864,  -648,  -248,  356,   972,   -584,  -204,  264,   880,   528,
    -24,   -184,  116,   448,   -144,  828,   524,   212,   -212,  52,    12,    200,   268,   -488,  -404,  -880,  824,   -672,
    -40,   908,   -248,  500,   716,   -576,  492,   -576,  16,    720,   -108,  384,   124,   344,   280,   576,   -500,  252,
    104,   -308,  196,   -188,  -8,    1268,  296,   1032,  -1196, 436,   316,   372,   -432,  -200,  -660,  704,   -224,  596,
    -132,  268,   32,    -452,  884,   104,   -1008, 424,   -1348, -280,  4,     -1168, 368,   476,   696,   300,   -8,    24,
    180,   -592,  -196,  388,   304,   500,   724,   -160,  244,   -84,   272,   -256,  -420,  320,   208,   -144,  -156,  156,
    364,   452,   28,    540,   316,   220,   -644,  -248,  464,   72,    360,   32,    -388,  496,   -680,  -48,   208,   -116,
    -408,  60,    -604,  -392,  548,   -840,  784,   -460,  656,   -544,  -388,  -264,  908,   -800,  -628,  -612,  -568,  572,
    -220,  164,   288,   -16,   -308,  308,   -112,  -636,  -760,  280,   -668,  432,   364,   240,   -196,  604,   340,   384,
    196,   592,   -44,   -500,  432,   -580,  -132,  636,   -76,   392,   4,     -412,  540,   508,   328,   -356,  -36,   16,
    -220,  -64,   -248,  -60,   24,    -192,  368,   1040,  92,    -24,   -1044, -32,   40,    104,   148,   192,   -136,  -520,
    56,    -816,  -224,  732,   392,   356,   212,   -80,   -424,  -1008, -324,  588,   -1496, 576,   460,   -816,  -848,  56,
    -580,  -92,   -1372, -112,  -496,  200,   364,   52,    -140,  48,    -48,   -60,   84,    72,    40,    132,   -356,  -268,
    -104,  -284,  -404,  732,   -520,  164,   -304,  -540,  120,   328,   -76,   -460,  756,   388,   588,   236,   -436,  -72,
    -176,  -404,  -316,  -148,  716,   -604,  404,   -72,   -88,   -888,  -68,   944,   88,    -220,  -344,  960,   472,   460,
    -232,  704,   120,   832,   -228,  692,   -508,  132,   -476,  844,   -748,  -364,  -44,   1116,  -1104, -1056, 76,    428,
    552,   -692,  60,    356,   96,    -384,  -188,  -612,  -576,  736,   508,   892,   352,   -1132, 504,   -24,   -352,  324,
    332,   -600,  -312,  292,   508,   -144,  -8,    484,   48,    284,   -260,  -240,  256,   -100,  -292,  -204,  -44,   472,
    -204,  908,   -188,  -1000, -256,  92,    1164,  -392,  564,   356,   652,   -28,   -884,  256,   484,   -192,  760,   -176,
    376,   -524,  -452,  -436,  860,   -736,  212,   124,   504,   -476,  468,   76,    -472,  552,   -692,  -944,  -620,  740,
    -240,  400,   132,   20,    192,   -196,  264,   -668,  -1012, -60,   296,   -316,  -828,  76,    -156,  284,   -768,  -448,
    -832,  148,   248,   652,   616,   1236,  288,   -328,  -400,  -124,  588,   220,   520,   -696,  1032,  768,   -740,  -92,
    -272,  296,   448,   -464,  412,   -200,  392,   440,   -200,  264,   -152,  -260,  320,   1032,  216,   320,   -8,    -64,
    156,   -1016, 1084,  1172,  536,   484,   -432,  132,   372,   -52,   -256,  84,    116,   -352,  48,    116,   304,   -384,
    412,   924,   -300,  528,   628,   180,   648,   44,    -980,  -220,  1320,  48,    332,   748,   524,   -268,  -720,  540,
    -276,  564,   -344,  -208,  -196,  436,   896,   88,    -392,  132,   80,    -964,  -288,  568,   56,    -48,   -456,  888,
    8,     552,   -156,  -292,  948,   288,   128,   -716,  -292,  1192,  -152,  876,   352,   -600,  -260,  -812,  -468,  -28,
    -120,  -32,   -44,   1284,  496,   192,   464,   312,   -76,   -516,  -380,  -456,  -1012, -48,   308,   -156,  36,    492,
    -156,  -808,  188,   1652,  68,    -120,  -116,  316,   160,   -140,  352,   808,   -416,  592,   316,   -480,  56,    528,
    -204,  -568,  372,   -232,  752,   -344,  744,   -4,    324,   -416,  -600,  768,   268,   -248,  -88,   -132,  -420,  -432,
    80,    -288,  404,   -316,  -1216, -588,  520,   -108,  92,    -320,  368,   -480,  -216,  -92,   1688,  -300,  180,   1020,
    -176,  820,   -68,   -228,  -260,  436,   -904,  20,    40,    -508,  440,   -736,  312,   332,   204,   760,   -372,  728,
    96,    -20,   -632,  -520,  -560,  336,   1076,  -64,   -532,  776,   584,   192,   396,   -728,  -520,  276,   -188,  80,
    -52,   -612,  -252,  -48,   648,   212,   -688,  228,   -52,   -260,  428,   -412,  -272,  -404,  180,   816,   -796,  48,
    152,   484,   -88,   -216,  988,   696,   188,   -528,  648,   -116,  -180,  316,   476,   12,    -564,  96,    476,   -252,
    -364,  -376,  -392,  556,   -256,  -576,  260,   -352,  120,   -16,   -136,  -260,  -492,  72,    556,   660,   580,   616,
    772,   436,   424,   -32,   -324,  -1268, 416,   -324,  -80,   920,   160,   228,   724,   32,    -516,  64,    384,   68,
    -128,  136,   240,   248,   -204,  -68,   252,   -932,  -120,  -480,  -628,  -84,   192,   852,   -404,  -288,  -132,  204,
    100,   168,   -68,   -196,  -868,  460,   1080,  380,   -80,   244,   0,     484,   -888,  64,    184,   352,   600,   460,
    164,   604,   -196,  320,   -64,   588,   -184,  228,   12,    372,   48,    -848,  -344,  224,   208,   -200,  484,   128,
    -20,   272,   -468,  -840,  384,   256,   -720,  -520,  -464,  -580,  112,   -120,  644,   -356,  -208,  -608,  -528,  704,
    560,   -424,  392,   828,   40,    84,    200,   -152,  0,     -144,  584,   280,   -120,  80,    -556,  -972,  -196,  -472,
    724,   80,    168,   -32,   88,    160,   -688,  0,     160,   356,   372,   -776,  740,   -128,  676,   -248,  -480,  4,
    -364,  96,    544,   232,   -1032, 956,   236,   356,   20,    -40,   300,   24,    -676,  -596,  132,   1120,  -104,  532,
    -1096, 568,   648,   444,   508,   380,   188,   -376,  -604,  1488,  424,   24,    756,   -220,  -192,  716,   120,   920,
    688,   168,   44,    -460,  568,   284,   1144,  1160,  600,   424,   888,   656,   -356,  -320,  220,   316,   -176,  -724,
    -188,  -816,  -628,  -348,  -228,  -380,  1012,  -452,  -660,  736,   928,   404,   -696,  -72,   -268,  -892,  128,   184,
    -344,  -780,  360,   336,   400,   344,   428,   548,   -112,  136,   -228,  -216,  -820,  -516,  340,   92,    -136,  116,
    -300,  376,   -244,  100,   -316,  -520,  -284,  -12,   824,   164,   -548,  -180,  -128,  116,   -924,  -828,  268,   -368,
    -580,  620,   192,   160,   0,     -1676, 1068,  424,   -56,   -360,  468,   -156,  720,   288,   -528,  556,   -364,  548,
    -148,  504,   316,   152,   -648,  -620,  -684,  -24,   -376,  -384,  -108,  -920,  -1032, 768,   180,   -264,  -508,  -1268,
    -260,  -60,   300,   -240,  988,   724,   -376,  -576,  -212,  -736,  556,   192,   1092,  -620,  -880,  376,   -56,   -4,
    -216,  -32,   836,   268,   396,   1332,  864,   -600,  100,   56,    -412,  -92,   356,   180,   884,   -468,  -436,  292,
    -388,  -804,  -704,  -840,  368,   -348,  140,   -724,  1536,  940,   372,   112,   -372,  436,   -480,  1136,  296,   -32,
    -228,  132,   -48,   -220,  868,   -1016, -60,   -1044, -464,  328,   916,   244,   12,    -736,  -296,  360,   468,   -376,
    -108,  -92,   788,   368,   -56,   544,   400,   -672,  -420,  728,   16,    320,   44,    -284,  -380,  -796,  488,   132,
    204,   -596,  -372,  88,    -152,  -908,  -636,  -572,  -624,  -116,  -692,  -200,  -56,   276,   -88,   484,   -324,  948,
    864,   1000,  -456,  -184,  -276,  292,   -296,  156,   676,   320,   160,   908,   -84,   -1236, -288,  -116,  260,   -372,
    -644,  732,   -756,  -96,   84,    344,   -520,  348,   -688,  240,   -84,   216,   -1044, -136,  -676,  -396,  -1500, 960,
    -40,   176,   168,   1516,  420,   -504,  -344,  -364,  -360,  1216,  -940,  -380,  -212,  252,   -660,  -708,  484,   -444,
    -152,  928,   -120,  1112,  476,   -260,  560,   -148,  -344,  108,   -196,  228,   -288,  504,   560,   -328,  -88,   288,
    -1008, 460,   -228,  468,   -836,  -196,  76,    388,   232,   412,   -1168, -716,  -644,  756,   -172,  -356,  -504,  116,
    432,   528,   48,    476,   -168,  -608,  448,   160,   -532,  -272,  28,    -676,  -12,   828,   980,   456,   520,   104,
    -104,  256,   -344,  -4,    -28,   -368,  -52,   -524,  -572,  -556,  -200,  768,   1124,  -208,  -512,  176,   232,   248,
    -148,  -888,  604,   -600,  -304,  804,   -156,  -212,  488,   -192,  -804,  -256,  368,   -360,  -916,  -328,  228,   -240,
    -448,  -472,  856,   -556,  -364,  572,   -12,   -156,  -368,  -340,  432,   252,   -752,  -152,  288,   268,   -580,  -848,
    -592,  108,   -76,   244,   312,   -716,  592,   -80,   436,   360,   4,     -248,  160,   516,   584,   732,   44,    -468,
    -280,  -292,  -156,  -588,  28,    308,   912,   24,    124,   156,   180,   -252,  944,   -924,  -772,  -520,  -428,  -624,
    300,   -212,  -1144, 32,    -724,  800,   -1128, -212,  -1288, -848,  180,   -416,  440,   192,   -576,  -792,  -76,   -1080,
    80,    -532,  -352,  -132,  380,   -820,  148,   1112,  128,   164,   456,   700,   -924,  144,   -668,  -384,  648,   -832,
    508,   552,   -52,   -100,  -656,  208,   -568,  748,   -88,   680,   232,   300,   192,   -408,  -1012, -152,  -252,  -268,
    272,   -876,  -664,  -648,  -332,  -136,  16,    12,    1152,  -28,   332,   -536,  320,   -672,  -460,  -316,  532,   -260,
    228,   -40,   1052,  -816,  180,   88,    -496,  -556,  -672,  -368,  428,   92,    356,   404,   -408,  252,   196,   -176,
    -556,  792,   268,   32,    372,   40,    96,    -332,  328,   120,   372,   -900,  -40,   472,   -264,  -592,  952,   128,
    656,   112,   664,   -232,  420,   4,     -344,  -464,  556,   244,   -416,  -32,   252,   0,     -412,  188,   -696,  508,
    -476,  324,   -1096, 656,   -312,  560,   264,   -136,  304,   160,   -64,   -580,  248,   336,   -720,  560,   -348,  -288,
    -276,  -196,  -500,  852,   -544,  -236,  -1128, -992,  -776,  116,   56,    52,    860,   884,   212,   -12,   168,   1020,
    512,   -552,  924,   -148,  716,   188,   164,   -340,  -520,  -184,  880,   -152,  -680,  -208,  -1156, -300,  -528,  -472,
    364,   100,   -744,  -1056, -32,   540,   280,   144,   -676,  -32,   -232,  -280,  -224,  96,    568,   -76,   172,   148,
    148,   104,   32,    -296,  -32,   788,   -80,   32,    -16,   280,   288,   944,   428,   -484,
};
