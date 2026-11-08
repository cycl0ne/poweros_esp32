// SPDX-License-Identifier: MIT
//! VP9's syntax as videoparse.library reads it (VP9 Bitstream & Decoding
//! Process Specification 0.6): a frame's uncompressed header (6.2) with
//! what stays from frame to frame applied to it - the colour of the last
//! key or intra-only frame, the loop filter's deltas, the segmentation -
//! and the probabilities a frame starts from after a reset (10.5), which
//! a decoder in software and a chip's both start from.
//!
//! The library hands a frame's header out by pointer with `VPEV_PICTURE`
//! (`sdk.videoparse`): the library's, read only, valid until the next
//! call on the parser. Each field is the specification's syntax element
//! in snake_case, the `segmentation_` and `loop_filter_` before the
//! fields of their own structures left out; the compressed header (6.3)
//! is a decoder's to read, from where the uncompressed one ends.

/// frame_type.
pub const KEY_FRAME: u8 = 0;
pub const NON_KEY_FRAME: u8 = 1;

/// interp_filter, numbered as the decoders take it - the literal of the
/// header mapped by literal_to_type: eight-tap, its smooth and sharp
/// kinds, bilinear, or chosen block by block.
pub const FILTER_EIGHTTAP: u8 = 0;
pub const FILTER_EIGHTTAP_SMOOTH: u8 = 1;
pub const FILTER_EIGHTTAP_SHARP: u8 = 2;
pub const FILTER_BILINEAR: u8 = 3;
pub const FILTER_SWITCHABLE: u8 = 4;

/// color_space (7.2.2).
pub const CS_UNKNOWN: u8 = 0;
pub const CS_BT_601: u8 = 1;
pub const CS_BT_709: u8 = 2;
pub const CS_SMPTE_170: u8 = 3;
pub const CS_SMPTE_240: u8 = 4;
pub const CS_BT_2020: u8 = 5;
pub const CS_RESERVED: u8 = 6;
pub const CS_RGB: u8 = 7;

/// The references a frame names, by ref_frame_sign_bias's index.
pub const LAST_FRAME = 1;
pub const GOLDEN_FRAME = 2;
pub const ALTREF_FRAME = 3;

/// The segmentation's features (6.2.11), by `feature_enabled`'s and
/// `feature_data`'s second index: the quantiser, the loop filter's
/// level, the reference frame, skip.
pub const SEG_LVL_ALT_Q = 0;
pub const SEG_LVL_ALT_L = 1;
pub const SEG_LVL_REF_FRAME = 2;
pub const SEG_LVL_SKIP = 3;

/// The highest loop filter level.
pub const MAX_LOOP_FILTER = 63;

/// The segmentation as it stands after a frame's header (6.2.11): this
/// frame's flags, and the probabilities and features that stay from
/// frame to frame until a header changes them or a reset clears them.
pub const Vp9Segmentation = extern struct {
    enabled: bool = false,
    update_map: bool = false,
    temporal_update: bool = false,
    update_data: bool = false,
    /// segmentation_abs_or_delta_update: the features' values are the
    /// levels themselves, not changes of the frame's.
    abs_delta: bool = false,
    tree_probs: [7]u8 = @splat(255),
    pred_probs: [3]u8 = @splat(255),
    /// FeatureEnabled and FeatureData, by segment and feature.
    feature_enabled: [8][4]bool = @splat(@splat(false)),
    feature_data: [8][4]i16 = @splat(@splat(0)),

    /// Whether `feature` is on for `segment`.
    pub fn active(sg: *const Vp9Segmentation, segment: u8, feature: usize) bool {
        return sg.enabled and sg.feature_enabled[segment][feature];
    }
};

/// The loop filter (6.2.8): this frame's level and sharpness, and the
/// changes of the level by reference and by mode, which stay from frame
/// to frame.
pub const Vp9LoopFilter = extern struct {
    level: u8 = 0,
    sharpness: u8 = 0,
    delta_enabled: bool = false,
    delta_update: bool = false,
    /// By reference, INTRA_FRAME to ALTREF_FRAME.
    ref_deltas: [4]i8 = .{ 1, 0, -1, -1 },
    /// By mode: ZEROMV, and the other inter modes.
    mode_deltas: [2]i8 = .{ 0, 0 },
};

/// A frame's uncompressed header, what stays from the frames before it
/// applied.
pub const Vp9Header = extern struct {
    profile: u8 = 0,
    /// The frame only shows the one in reference slot
    /// `frame_to_show_map_idx`: nothing else of it is read.
    show_existing_frame: bool = false,
    frame_to_show_map_idx: u8 = 0,
    frame_type: u8 = KEY_FRAME,
    show_frame: bool = true,
    error_resilient_mode: bool = false,
    intra_only: bool = false,
    reset_frame_context: u8 = 0,
    /// The reference slots the frame goes into, bit i for slot i: all of
    /// them for a key frame.
    refresh_frame_flags: u8 = 0,
    /// The slots LAST_FRAME, GOLDEN_FRAME and ALTREF_FRAME name, and
    /// their sign biases by the same index plus 1 (0 unused).
    ref_frame_idx: [3]u8 = .{ 0, 0, 0 },
    ref_frame_sign_bias: [4]bool = @splat(false),
    allow_high_precision_mv: bool = false,
    /// FILTER_*.
    interp_filter: u8 = 0,
    refresh_frame_context: bool = false,
    frame_parallel_decoding_mode: bool = true,
    /// As read: a decoder that resets past independence uses set 0.
    frame_context_idx: u8 = 0,
    /// The frame is a key frame or an intra-only one (FrameIsIntra).
    frame_is_intra: bool = true,
    /// setup_past_independence ran (7.2): a key frame, an intra-only or
    /// an error resilient one, which keeps nothing of the probabilities,
    /// the segment map or the vectors before it.
    reset_past: bool = false,
    /// UsePrevFrameMvs: the vectors of the frame decoded before it are
    /// read - the same size, shown, not intra-only, not after a key frame,
    /// and the frame not error resilient.
    use_prev_frame_mvs: bool = false,
    /// The colour, as the last key frame or intra-only one said it.
    bit_depth: u8 = 8,
    color_space: u8 = CS_UNKNOWN,
    /// color_range: the whole byte.
    color_range: bool = false,
    subsampling_x: u8 = 1,
    subsampling_y: u8 = 1,
    /// FrameWidth and FrameHeight, and the size it is meant to be shown
    /// at.
    width: u32 = 0,
    height: u32 = 0,
    render_width: u32 = 0,
    render_height: u32 = 0,
    base_q_idx: u8 = 0,
    delta_q_y_dc: i8 = 0,
    delta_q_uv_dc: i8 = 0,
    delta_q_uv_ac: i8 = 0,
    /// Lossless: the quantiser and its changes all 0.
    lossless: bool = false,
    tile_cols_log2: u8 = 0,
    tile_rows_log2: u8 = 0,
    loop_filter: Vp9LoopFilter = .{},
    segmentation: Vp9Segmentation = .{},
    /// The uncompressed header's bytes - where the compressed one starts
    /// - and the compressed header's (header_size_in_bytes).
    uncompressed_bytes: u32 = 0,
    compressed_bytes: u32 = 0,
};

/// The probabilities a frame reads its blocks with (10.5's set): what
/// every saved set holds after a reset is `default_probs`.
pub const Vp9Probs = extern struct {
    tx8: [2][1]u8,
    tx16: [2][2]u8,
    tx32: [2][3]u8,
    coef: [4][2][2][6][6][3]u8,
    skip: [3]u8,
    inter_mode: [7][3]u8,
    interp_filter: [4][2]u8,
    is_inter: [4]u8,
    comp_mode: [5]u8,
    single_ref: [5][2]u8,
    comp_ref: [5]u8,
    y_mode: [4][9]u8,
    uv_mode: [10][9]u8,
    partition: [16][3]u8,
    mv_joint: [3]u8,
    mv_sign: [2]u8,
    mv_class: [2][10]u8,
    mv_class0_bit: [2]u8,
    mv_bits: [2][10]u8,
    mv_class0_fr: [2][2][3]u8,
    mv_fr: [2][3]u8,
    mv_class0_hp: [2]u8,
    mv_hp: [2]u8,
};

/// The probabilities after a reset (10.5).
pub const default_probs: Vp9Probs = .{
    .tx8 = .{ .{default_tx_probs[1][0][0]}, .{default_tx_probs[1][1][0]} },
    .tx16 = .{ default_tx_probs[2][0][0..2].*, default_tx_probs[2][1][0..2].* },
    .tx32 = default_tx_probs[3],
    .coef = default_coef_probs,
    .skip = default_skip_prob,
    .inter_mode = default_inter_mode_probs,
    .interp_filter = default_interp_filter_probs,
    .is_inter = default_is_inter_prob,
    .comp_mode = default_comp_mode_prob,
    .single_ref = default_single_ref_prob,
    .comp_ref = default_comp_ref_prob,
    .y_mode = default_y_mode_probs,
    .uv_mode = default_uv_mode_probs,
    .partition = default_partition_probs,
    .mv_joint = default_mv_joint_probs,
    .mv_sign = default_mv_sign_prob,
    .mv_class = default_mv_class_probs,
    .mv_class0_bit = default_mv_class0_bit_prob,
    .mv_bits = default_mv_bits_prob,
    .mv_class0_fr = default_mv_class0_fr_probs,
    .mv_fr = default_mv_fr_probs,
    .mv_class0_hp = default_mv_class0_hp_prob,
    .mv_hp = default_mv_hp_prob,
};

// --- the tables of 10.5 -------------------------------------------------------

const default_partition_probs: [16][3]u8 = .{
    .{ 199, 122, 141 },
    .{ 147, 63, 159 },
    .{ 148, 133, 118 },
    .{ 121, 104, 114 },
    .{ 174, 73, 87 },
    .{ 92, 41, 83 },
    .{ 82, 99, 50 },
    .{ 53, 39, 39 },
    .{ 177, 58, 59 },
    .{ 68, 26, 63 },
    .{ 52, 79, 25 },
    .{ 17, 14, 12 },
    .{ 222, 34, 30 },
    .{ 72, 16, 44 },
    .{ 58, 32, 12 },
    .{ 10, 7, 6 },
};

const default_y_mode_probs: [4][9]u8 = .{
    .{ 65, 32, 18, 144, 162, 194, 41, 51, 98 },
    .{ 132, 68, 18, 165, 217, 196, 45, 40, 78 },
    .{ 173, 80, 19, 176, 240, 193, 64, 35, 46 },
    .{ 221, 135, 38, 194, 248, 121, 96, 85, 29 },
};

const default_uv_mode_probs: [10][9]u8 = .{
    .{ 120, 7, 76, 176, 208, 126, 28, 54, 103 },
    .{ 48, 12, 154, 155, 139, 90, 34, 117, 119 },
    .{ 67, 6, 25, 204, 243, 158, 13, 21, 96 },
    .{ 97, 5, 44, 131, 176, 139, 48, 68, 97 },
    .{ 83, 5, 42, 156, 111, 152, 26, 49, 152 },
    .{ 80, 5, 58, 178, 74, 83, 33, 62, 145 },
    .{ 86, 5, 32, 154, 192, 168, 14, 22, 163 },
    .{ 85, 5, 32, 156, 216, 148, 19, 29, 73 },
    .{ 77, 7, 64, 116, 132, 122, 37, 126, 120 },
    .{ 101, 21, 107, 181, 192, 103, 19, 67, 125 },
};

const default_skip_prob: [3]u8 = .{ 192, 128, 64 };

const default_is_inter_prob: [4]u8 = .{ 9, 102, 187, 225 };

const default_comp_mode_prob: [5]u8 = .{ 239, 183, 119, 96, 41 };

const default_comp_ref_prob: [5]u8 = .{ 50, 126, 123, 221, 226 };

const default_single_ref_prob: [5][2]u8 = .{
    .{ 33, 16 },
    .{ 77, 74 },
    .{ 142, 142 },
    .{ 172, 170 },
    .{ 238, 247 },
};

const default_mv_sign_prob: [2]u8 = .{ 128, 128 };

const default_mv_bits_prob: [2][10]u8 = .{
    .{ 136, 140, 148, 160, 176, 192, 224, 234, 234, 240 },
    .{ 136, 140, 148, 160, 176, 192, 224, 234, 234, 240 },
};

const default_mv_class0_bit_prob: [2]u8 = .{ 216, 208 };

const default_tx_probs: [4][2][3]u8 = .{
    .{
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
    },
    .{
        .{ 100, 0, 0 },
        .{ 66, 0, 0 },
    },
    .{
        .{ 20, 152, 0 },
        .{ 15, 101, 0 },
    },
    .{
        .{ 3, 136, 37 },
        .{ 5, 52, 13 },
    },
};

const default_inter_mode_probs: [7][3]u8 = .{
    .{ 2, 173, 34 },
    .{ 7, 145, 85 },
    .{ 7, 166, 63 },
    .{ 7, 94, 66 },
    .{ 8, 64, 46 },
    .{ 17, 81, 31 },
    .{ 25, 29, 30 },
};

const default_interp_filter_probs: [4][2]u8 = .{
    .{ 235, 162 },
    .{ 36, 255 },
    .{ 34, 3 },
    .{ 149, 144 },
};

const default_mv_joint_probs: [3]u8 = .{ 32, 64, 96 };

const default_mv_class_probs: [2][10]u8 = .{
    .{ 224, 144, 192, 168, 192, 176, 192, 198, 198, 245 },
    .{ 216, 128, 176, 160, 176, 176, 192, 198, 198, 208 },
};

const default_mv_class0_fr_probs: [2][2][3]u8 = .{
    .{
        .{ 128, 128, 64 },
        .{ 96, 112, 64 },
    },
    .{
        .{ 128, 128, 64 },
        .{ 96, 112, 64 },
    },
};

const default_mv_class0_hp_prob: [2]u8 = .{ 160, 160 };

const default_mv_fr_probs: [2][3]u8 = .{
    .{ 64, 96, 64 },
    .{ 64, 96, 64 },
};

const default_mv_hp_prob: [2]u8 = .{ 128, 128 };

const default_coef_probs: [4][2][2][6][6][3]u8 = .{
    .{
        .{
            .{
                .{
                    .{ 195, 29, 183 },
                    .{ 84, 49, 136 },
                    .{ 8, 42, 71 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                },
                .{
                    .{ 31, 107, 169 },
                    .{ 35, 99, 159 },
                    .{ 17, 82, 140 },
                    .{ 8, 66, 114 },
                    .{ 2, 44, 76 },
                    .{ 1, 19, 32 },
                },
                .{
                    .{ 40, 132, 201 },
                    .{ 29, 114, 187 },
                    .{ 13, 91, 157 },
                    .{ 7, 75, 127 },
                    .{ 3, 58, 95 },
                    .{ 1, 28, 47 },
                },
                .{
                    .{ 69, 142, 221 },
                    .{ 42, 122, 201 },
                    .{ 15, 91, 159 },
                    .{ 6, 67, 121 },
                    .{ 1, 42, 77 },
                    .{ 1, 17, 31 },
                },
                .{
                    .{ 102, 148, 228 },
                    .{ 67, 117, 204 },
                    .{ 17, 82, 154 },
                    .{ 6, 59, 114 },
                    .{ 2, 39, 75 },
                    .{ 1, 15, 29 },
                },
                .{
                    .{ 156, 57, 233 },
                    .{ 119, 57, 212 },
                    .{ 58, 48, 163 },
                    .{ 29, 40, 124 },
                    .{ 12, 30, 81 },
                    .{ 3, 12, 31 },
                },
            },
            .{
                .{
                    .{ 191, 107, 226 },
                    .{ 124, 117, 204 },
                    .{ 25, 99, 155 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                },
                .{
                    .{ 29, 148, 210 },
                    .{ 37, 126, 194 },
                    .{ 8, 93, 157 },
                    .{ 2, 68, 118 },
                    .{ 1, 39, 69 },
                    .{ 1, 17, 33 },
                },
                .{
                    .{ 41, 151, 213 },
                    .{ 27, 123, 193 },
                    .{ 3, 82, 144 },
                    .{ 1, 58, 105 },
                    .{ 1, 32, 60 },
                    .{ 1, 13, 26 },
                },
                .{
                    .{ 59, 159, 220 },
                    .{ 23, 126, 198 },
                    .{ 4, 88, 151 },
                    .{ 1, 66, 114 },
                    .{ 1, 38, 71 },
                    .{ 1, 18, 34 },
                },
                .{
                    .{ 114, 136, 232 },
                    .{ 51, 114, 207 },
                    .{ 11, 83, 155 },
                    .{ 3, 56, 105 },
                    .{ 1, 33, 65 },
                    .{ 1, 17, 34 },
                },
                .{
                    .{ 149, 65, 234 },
                    .{ 121, 57, 215 },
                    .{ 61, 49, 166 },
                    .{ 28, 36, 114 },
                    .{ 12, 25, 76 },
                    .{ 3, 16, 42 },
                },
            },
        },
        .{
            .{
                .{
                    .{ 214, 49, 220 },
                    .{ 132, 63, 188 },
                    .{ 42, 65, 137 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                },
                .{
                    .{ 85, 137, 221 },
                    .{ 104, 131, 216 },
                    .{ 49, 111, 192 },
                    .{ 21, 87, 155 },
                    .{ 2, 49, 87 },
                    .{ 1, 16, 28 },
                },
                .{
                    .{ 89, 163, 230 },
                    .{ 90, 137, 220 },
                    .{ 29, 100, 183 },
                    .{ 10, 70, 135 },
                    .{ 2, 42, 81 },
                    .{ 1, 17, 33 },
                },
                .{
                    .{ 108, 167, 237 },
                    .{ 55, 133, 222 },
                    .{ 15, 97, 179 },
                    .{ 4, 72, 135 },
                    .{ 1, 45, 85 },
                    .{ 1, 19, 38 },
                },
                .{
                    .{ 124, 146, 240 },
                    .{ 66, 124, 224 },
                    .{ 17, 88, 175 },
                    .{ 4, 58, 122 },
                    .{ 1, 36, 75 },
                    .{ 1, 18, 37 },
                },
                .{
                    .{ 141, 79, 241 },
                    .{ 126, 70, 227 },
                    .{ 66, 58, 182 },
                    .{ 30, 44, 136 },
                    .{ 12, 34, 96 },
                    .{ 2, 20, 47 },
                },
            },
            .{
                .{
                    .{ 229, 99, 249 },
                    .{ 143, 111, 235 },
                    .{ 46, 109, 192 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                },
                .{
                    .{ 82, 158, 236 },
                    .{ 94, 146, 224 },
                    .{ 25, 117, 191 },
                    .{ 9, 87, 149 },
                    .{ 3, 56, 99 },
                    .{ 1, 33, 57 },
                },
                .{
                    .{ 83, 167, 237 },
                    .{ 68, 145, 222 },
                    .{ 10, 103, 177 },
                    .{ 2, 72, 131 },
                    .{ 1, 41, 79 },
                    .{ 1, 20, 39 },
                },
                .{
                    .{ 99, 167, 239 },
                    .{ 47, 141, 224 },
                    .{ 10, 104, 178 },
                    .{ 2, 73, 133 },
                    .{ 1, 44, 85 },
                    .{ 1, 22, 47 },
                },
                .{
                    .{ 127, 145, 243 },
                    .{ 71, 129, 228 },
                    .{ 17, 93, 177 },
                    .{ 3, 61, 124 },
                    .{ 1, 41, 84 },
                    .{ 1, 21, 52 },
                },
                .{
                    .{ 157, 78, 244 },
                    .{ 140, 72, 231 },
                    .{ 69, 58, 184 },
                    .{ 31, 44, 137 },
                    .{ 14, 38, 105 },
                    .{ 8, 23, 61 },
                },
            },
        },
    },
    .{
        .{
            .{
                .{
                    .{ 125, 34, 187 },
                    .{ 52, 41, 133 },
                    .{ 6, 31, 56 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                },
                .{
                    .{ 37, 109, 153 },
                    .{ 51, 102, 147 },
                    .{ 23, 87, 128 },
                    .{ 8, 67, 101 },
                    .{ 1, 41, 63 },
                    .{ 1, 19, 29 },
                },
                .{
                    .{ 31, 154, 185 },
                    .{ 17, 127, 175 },
                    .{ 6, 96, 145 },
                    .{ 2, 73, 114 },
                    .{ 1, 51, 82 },
                    .{ 1, 28, 45 },
                },
                .{
                    .{ 23, 163, 200 },
                    .{ 10, 131, 185 },
                    .{ 2, 93, 148 },
                    .{ 1, 67, 111 },
                    .{ 1, 41, 69 },
                    .{ 1, 14, 24 },
                },
                .{
                    .{ 29, 176, 217 },
                    .{ 12, 145, 201 },
                    .{ 3, 101, 156 },
                    .{ 1, 69, 111 },
                    .{ 1, 39, 63 },
                    .{ 1, 14, 23 },
                },
                .{
                    .{ 57, 192, 233 },
                    .{ 25, 154, 215 },
                    .{ 6, 109, 167 },
                    .{ 3, 78, 118 },
                    .{ 1, 48, 69 },
                    .{ 1, 21, 29 },
                },
            },
            .{
                .{
                    .{ 202, 105, 245 },
                    .{ 108, 106, 216 },
                    .{ 18, 90, 144 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                },
                .{
                    .{ 33, 172, 219 },
                    .{ 64, 149, 206 },
                    .{ 14, 117, 177 },
                    .{ 5, 90, 141 },
                    .{ 2, 61, 95 },
                    .{ 1, 37, 57 },
                },
                .{
                    .{ 33, 179, 220 },
                    .{ 11, 140, 198 },
                    .{ 1, 89, 148 },
                    .{ 1, 60, 104 },
                    .{ 1, 33, 57 },
                    .{ 1, 12, 21 },
                },
                .{
                    .{ 30, 181, 221 },
                    .{ 8, 141, 198 },
                    .{ 1, 87, 145 },
                    .{ 1, 58, 100 },
                    .{ 1, 31, 55 },
                    .{ 1, 12, 20 },
                },
                .{
                    .{ 32, 186, 224 },
                    .{ 7, 142, 198 },
                    .{ 1, 86, 143 },
                    .{ 1, 58, 100 },
                    .{ 1, 31, 55 },
                    .{ 1, 12, 22 },
                },
                .{
                    .{ 57, 192, 227 },
                    .{ 20, 143, 204 },
                    .{ 3, 96, 154 },
                    .{ 1, 68, 112 },
                    .{ 1, 42, 69 },
                    .{ 1, 19, 32 },
                },
            },
        },
        .{
            .{
                .{
                    .{ 212, 35, 215 },
                    .{ 113, 47, 169 },
                    .{ 29, 48, 105 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                },
                .{
                    .{ 74, 129, 203 },
                    .{ 106, 120, 203 },
                    .{ 49, 107, 178 },
                    .{ 19, 84, 144 },
                    .{ 4, 50, 84 },
                    .{ 1, 15, 25 },
                },
                .{
                    .{ 71, 172, 217 },
                    .{ 44, 141, 209 },
                    .{ 15, 102, 173 },
                    .{ 6, 76, 133 },
                    .{ 2, 51, 89 },
                    .{ 1, 24, 42 },
                },
                .{
                    .{ 64, 185, 231 },
                    .{ 31, 148, 216 },
                    .{ 8, 103, 175 },
                    .{ 3, 74, 131 },
                    .{ 1, 46, 81 },
                    .{ 1, 18, 30 },
                },
                .{
                    .{ 65, 196, 235 },
                    .{ 25, 157, 221 },
                    .{ 5, 105, 174 },
                    .{ 1, 67, 120 },
                    .{ 1, 38, 69 },
                    .{ 1, 15, 30 },
                },
                .{
                    .{ 65, 204, 238 },
                    .{ 30, 156, 224 },
                    .{ 7, 107, 177 },
                    .{ 2, 70, 124 },
                    .{ 1, 42, 73 },
                    .{ 1, 18, 34 },
                },
            },
            .{
                .{
                    .{ 225, 86, 251 },
                    .{ 144, 104, 235 },
                    .{ 42, 99, 181 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                },
                .{
                    .{ 85, 175, 239 },
                    .{ 112, 165, 229 },
                    .{ 29, 136, 200 },
                    .{ 12, 103, 162 },
                    .{ 6, 77, 123 },
                    .{ 2, 53, 84 },
                },
                .{
                    .{ 75, 183, 239 },
                    .{ 30, 155, 221 },
                    .{ 3, 106, 171 },
                    .{ 1, 74, 128 },
                    .{ 1, 44, 76 },
                    .{ 1, 17, 28 },
                },
                .{
                    .{ 73, 185, 240 },
                    .{ 27, 159, 222 },
                    .{ 2, 107, 172 },
                    .{ 1, 75, 127 },
                    .{ 1, 42, 73 },
                    .{ 1, 17, 29 },
                },
                .{
                    .{ 62, 190, 238 },
                    .{ 21, 159, 222 },
                    .{ 2, 107, 172 },
                    .{ 1, 72, 122 },
                    .{ 1, 40, 71 },
                    .{ 1, 18, 32 },
                },
                .{
                    .{ 61, 199, 240 },
                    .{ 27, 161, 226 },
                    .{ 4, 113, 180 },
                    .{ 1, 76, 129 },
                    .{ 1, 46, 80 },
                    .{ 1, 23, 41 },
                },
            },
        },
    },
    .{
        .{
            .{
                .{
                    .{ 7, 27, 153 },
                    .{ 5, 30, 95 },
                    .{ 1, 16, 30 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                },
                .{
                    .{ 50, 75, 127 },
                    .{ 57, 75, 124 },
                    .{ 27, 67, 108 },
                    .{ 10, 54, 86 },
                    .{ 1, 33, 52 },
                    .{ 1, 12, 18 },
                },
                .{
                    .{ 43, 125, 151 },
                    .{ 26, 108, 148 },
                    .{ 7, 83, 122 },
                    .{ 2, 59, 89 },
                    .{ 1, 38, 60 },
                    .{ 1, 17, 27 },
                },
                .{
                    .{ 23, 144, 163 },
                    .{ 13, 112, 154 },
                    .{ 2, 75, 117 },
                    .{ 1, 50, 81 },
                    .{ 1, 31, 51 },
                    .{ 1, 14, 23 },
                },
                .{
                    .{ 18, 162, 185 },
                    .{ 6, 123, 171 },
                    .{ 1, 78, 125 },
                    .{ 1, 51, 86 },
                    .{ 1, 31, 54 },
                    .{ 1, 14, 23 },
                },
                .{
                    .{ 15, 199, 227 },
                    .{ 3, 150, 204 },
                    .{ 1, 91, 146 },
                    .{ 1, 55, 95 },
                    .{ 1, 30, 53 },
                    .{ 1, 11, 20 },
                },
            },
            .{
                .{
                    .{ 19, 55, 240 },
                    .{ 19, 59, 196 },
                    .{ 3, 52, 105 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                },
                .{
                    .{ 41, 166, 207 },
                    .{ 104, 153, 199 },
                    .{ 31, 123, 181 },
                    .{ 14, 101, 152 },
                    .{ 5, 72, 106 },
                    .{ 1, 36, 52 },
                },
                .{
                    .{ 35, 176, 211 },
                    .{ 12, 131, 190 },
                    .{ 2, 88, 144 },
                    .{ 1, 60, 101 },
                    .{ 1, 36, 60 },
                    .{ 1, 16, 28 },
                },
                .{
                    .{ 28, 183, 213 },
                    .{ 8, 134, 191 },
                    .{ 1, 86, 142 },
                    .{ 1, 56, 96 },
                    .{ 1, 30, 53 },
                    .{ 1, 12, 20 },
                },
                .{
                    .{ 20, 190, 215 },
                    .{ 4, 135, 192 },
                    .{ 1, 84, 139 },
                    .{ 1, 53, 91 },
                    .{ 1, 28, 49 },
                    .{ 1, 11, 20 },
                },
                .{
                    .{ 13, 196, 216 },
                    .{ 2, 137, 192 },
                    .{ 1, 86, 143 },
                    .{ 1, 57, 99 },
                    .{ 1, 32, 56 },
                    .{ 1, 13, 24 },
                },
            },
        },
        .{
            .{
                .{
                    .{ 211, 29, 217 },
                    .{ 96, 47, 156 },
                    .{ 22, 43, 87 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                },
                .{
                    .{ 78, 120, 193 },
                    .{ 111, 116, 186 },
                    .{ 46, 102, 164 },
                    .{ 15, 80, 128 },
                    .{ 2, 49, 76 },
                    .{ 1, 18, 28 },
                },
                .{
                    .{ 71, 161, 203 },
                    .{ 42, 132, 192 },
                    .{ 10, 98, 150 },
                    .{ 3, 69, 109 },
                    .{ 1, 44, 70 },
                    .{ 1, 18, 29 },
                },
                .{
                    .{ 57, 186, 211 },
                    .{ 30, 140, 196 },
                    .{ 4, 93, 146 },
                    .{ 1, 62, 102 },
                    .{ 1, 38, 65 },
                    .{ 1, 16, 27 },
                },
                .{
                    .{ 47, 199, 217 },
                    .{ 14, 145, 196 },
                    .{ 1, 88, 142 },
                    .{ 1, 57, 98 },
                    .{ 1, 36, 62 },
                    .{ 1, 15, 26 },
                },
                .{
                    .{ 26, 219, 229 },
                    .{ 5, 155, 207 },
                    .{ 1, 94, 151 },
                    .{ 1, 60, 104 },
                    .{ 1, 36, 62 },
                    .{ 1, 16, 28 },
                },
            },
            .{
                .{
                    .{ 233, 29, 248 },
                    .{ 146, 47, 220 },
                    .{ 43, 52, 140 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                },
                .{
                    .{ 100, 163, 232 },
                    .{ 179, 161, 222 },
                    .{ 63, 142, 204 },
                    .{ 37, 113, 174 },
                    .{ 26, 89, 137 },
                    .{ 18, 68, 97 },
                },
                .{
                    .{ 85, 181, 230 },
                    .{ 32, 146, 209 },
                    .{ 7, 100, 164 },
                    .{ 3, 71, 121 },
                    .{ 1, 45, 77 },
                    .{ 1, 18, 30 },
                },
                .{
                    .{ 65, 187, 230 },
                    .{ 20, 148, 207 },
                    .{ 2, 97, 159 },
                    .{ 1, 68, 116 },
                    .{ 1, 40, 70 },
                    .{ 1, 14, 29 },
                },
                .{
                    .{ 40, 194, 227 },
                    .{ 8, 147, 204 },
                    .{ 1, 94, 155 },
                    .{ 1, 65, 112 },
                    .{ 1, 39, 66 },
                    .{ 1, 14, 26 },
                },
                .{
                    .{ 16, 208, 228 },
                    .{ 3, 151, 207 },
                    .{ 1, 98, 160 },
                    .{ 1, 67, 117 },
                    .{ 1, 41, 74 },
                    .{ 1, 17, 31 },
                },
            },
        },
    },
    .{
        .{
            .{
                .{
                    .{ 17, 38, 140 },
                    .{ 7, 34, 80 },
                    .{ 1, 17, 29 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                },
                .{
                    .{ 37, 75, 128 },
                    .{ 41, 76, 128 },
                    .{ 26, 66, 116 },
                    .{ 12, 52, 94 },
                    .{ 2, 32, 55 },
                    .{ 1, 10, 16 },
                },
                .{
                    .{ 50, 127, 154 },
                    .{ 37, 109, 152 },
                    .{ 16, 82, 121 },
                    .{ 5, 59, 85 },
                    .{ 1, 35, 54 },
                    .{ 1, 13, 20 },
                },
                .{
                    .{ 40, 142, 167 },
                    .{ 17, 110, 157 },
                    .{ 2, 71, 112 },
                    .{ 1, 44, 72 },
                    .{ 1, 27, 45 },
                    .{ 1, 11, 17 },
                },
                .{
                    .{ 30, 175, 188 },
                    .{ 9, 124, 169 },
                    .{ 1, 74, 116 },
                    .{ 1, 48, 78 },
                    .{ 1, 30, 49 },
                    .{ 1, 11, 18 },
                },
                .{
                    .{ 10, 222, 223 },
                    .{ 2, 150, 194 },
                    .{ 1, 83, 128 },
                    .{ 1, 48, 79 },
                    .{ 1, 27, 45 },
                    .{ 1, 11, 17 },
                },
            },
            .{
                .{
                    .{ 36, 41, 235 },
                    .{ 29, 36, 193 },
                    .{ 10, 27, 111 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                },
                .{
                    .{ 85, 165, 222 },
                    .{ 177, 162, 215 },
                    .{ 110, 135, 195 },
                    .{ 57, 113, 168 },
                    .{ 23, 83, 120 },
                    .{ 10, 49, 61 },
                },
                .{
                    .{ 85, 190, 223 },
                    .{ 36, 139, 200 },
                    .{ 5, 90, 146 },
                    .{ 1, 60, 103 },
                    .{ 1, 38, 65 },
                    .{ 1, 18, 30 },
                },
                .{
                    .{ 72, 202, 223 },
                    .{ 23, 141, 199 },
                    .{ 2, 86, 140 },
                    .{ 1, 56, 97 },
                    .{ 1, 36, 61 },
                    .{ 1, 16, 27 },
                },
                .{
                    .{ 55, 218, 225 },
                    .{ 13, 145, 200 },
                    .{ 1, 86, 141 },
                    .{ 1, 57, 99 },
                    .{ 1, 35, 61 },
                    .{ 1, 13, 22 },
                },
                .{
                    .{ 15, 235, 212 },
                    .{ 1, 132, 184 },
                    .{ 1, 84, 139 },
                    .{ 1, 57, 97 },
                    .{ 1, 34, 56 },
                    .{ 1, 14, 23 },
                },
            },
        },
        .{
            .{
                .{
                    .{ 181, 21, 201 },
                    .{ 61, 37, 123 },
                    .{ 10, 38, 71 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                },
                .{
                    .{ 47, 106, 172 },
                    .{ 95, 104, 173 },
                    .{ 42, 93, 159 },
                    .{ 18, 77, 131 },
                    .{ 4, 50, 81 },
                    .{ 1, 17, 23 },
                },
                .{
                    .{ 62, 147, 199 },
                    .{ 44, 130, 189 },
                    .{ 28, 102, 154 },
                    .{ 18, 75, 115 },
                    .{ 2, 44, 65 },
                    .{ 1, 12, 19 },
                },
                .{
                    .{ 55, 153, 210 },
                    .{ 24, 130, 194 },
                    .{ 3, 93, 146 },
                    .{ 1, 61, 97 },
                    .{ 1, 31, 50 },
                    .{ 1, 10, 16 },
                },
                .{
                    .{ 49, 186, 223 },
                    .{ 17, 148, 204 },
                    .{ 1, 96, 142 },
                    .{ 1, 53, 83 },
                    .{ 1, 26, 44 },
                    .{ 1, 11, 17 },
                },
                .{
                    .{ 13, 217, 212 },
                    .{ 2, 136, 180 },
                    .{ 1, 78, 124 },
                    .{ 1, 50, 83 },
                    .{ 1, 29, 49 },
                    .{ 1, 14, 23 },
                },
            },
            .{
                .{
                    .{ 197, 13, 247 },
                    .{ 82, 17, 222 },
                    .{ 25, 17, 162 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                    .{ 0, 0, 0 },
                },
                .{
                    .{ 126, 186, 247 },
                    .{ 234, 191, 243 },
                    .{ 176, 177, 234 },
                    .{ 104, 158, 220 },
                    .{ 66, 128, 186 },
                    .{ 55, 90, 137 },
                },
                .{
                    .{ 111, 197, 242 },
                    .{ 46, 158, 219 },
                    .{ 9, 104, 171 },
                    .{ 2, 65, 125 },
                    .{ 1, 44, 80 },
                    .{ 1, 17, 91 },
                },
                .{
                    .{ 104, 208, 245 },
                    .{ 39, 168, 224 },
                    .{ 3, 109, 162 },
                    .{ 1, 79, 124 },
                    .{ 1, 50, 102 },
                    .{ 1, 43, 102 },
                },
                .{
                    .{ 84, 220, 246 },
                    .{ 31, 177, 231 },
                    .{ 2, 115, 180 },
                    .{ 1, 79, 134 },
                    .{ 1, 55, 77 },
                    .{ 1, 60, 79 },
                },
                .{
                    .{ 43, 243, 240 },
                    .{ 8, 180, 217 },
                    .{ 1, 115, 166 },
                    .{ 1, 84, 121 },
                    .{ 1, 51, 67 },
                    .{ 1, 16, 6 },
                },
            },
        },
    },
};
