// SPDX-License-Identifier: MIT
//! The headers as the decoder works from them: the sequence header (5.5)
//! and a frame's uncompressed header (5.9) that videoparse.library read,
//! copied from its structures (`sdk.videoparse.av1`) into the decoder's,
//! whose fields have the widths the decoder computes with and some of
//! them shorter names.
//!
//! The copy goes field by field, made at compile time from the decoder's
//! structures: each field is taken from the library's of the same name,
//! or of the name `renamed` gives it, narrowed to its type - so a field
//! the library lacks is a compile error, and one it adds is passed by.

const common = @import("common.zig");
const av1 = @import("sdk").videoparse.av1;

pub const SELECT_SCREEN_CONTENT_TOOLS = 2;
pub const SELECT_INTEGER_MV = 2;

/// The sequence header (5.5).
pub const Sequence = struct {
    profile: u8 = 0,
    still_picture: bool = false,
    reduced_still_picture_header: bool = false,
    timing_info_present: bool = false,
    decoder_model_info_present: bool = false,
    equal_picture_interval: bool = false,
    buffer_removal_time_length: u6 = 0,
    frame_presentation_time_length: u6 = 0,
    operating_points: u8 = 1,
    operating_point_idc: [32]u16 = @splat(0),
    decoder_model_present: [32]bool = @splat(false),
    /// The operating point chosen's: 0, all layers.
    idc: u16 = 0,
    frame_width_bits: u6 = 0,
    frame_height_bits: u6 = 0,
    max_frame_width: u32 = 0,
    max_frame_height: u32 = 0,
    frame_id_numbers_present: bool = false,
    delta_frame_id_length: u6 = 0,
    frame_id_length: u6 = 0,
    use_128x128: bool = false,
    enable_filter_intra: bool = false,
    enable_intra_edge_filter: bool = false,
    enable_interintra_compound: bool = false,
    enable_masked_compound: bool = false,
    enable_warped_motion: bool = false,
    enable_dual_filter: bool = false,
    enable_order_hint: bool = false,
    enable_jnt_comp: bool = false,
    enable_ref_frame_mvs: bool = false,
    force_screen_content_tools: u8 = SELECT_SCREEN_CONTENT_TOOLS,
    force_integer_mv: u8 = SELECT_INTEGER_MV,
    order_hint_bits: u6 = 0,
    enable_superres: bool = false,
    enable_cdef: bool = false,
    enable_restoration: bool = false,
    bit_depth: u8 = 8,
    mono: bool = false,
    primaries: u8 = 2,
    transfer: u8 = 2,
    matrix: u8 = 2,
    full_range: bool = false,
    ss_x: u1 = 1,
    ss_y: u1 = 1,
    separate_uv_delta_q: bool = false,
    film_grain_params_present: bool = false,

    pub fn planes(s: *const Sequence) u32 {
        return if (s.mono) 1 else 3;
    }

    /// get_relative_dist (5.9.24).
    pub fn dist(s: *const Sequence, a: u32, b: u32) i32 {
        if (!s.enable_order_hint) return 0;
        const diff: i32 = @as(i32, @intCast(a)) - @as(i32, @intCast(b));
        const m = @as(i32, 1) << @intCast(s.order_hint_bits - 1);
        return (diff & (m - 1)) - (diff & m);
    }
};

/// The film grain's parameters (5.9.30).
pub const Grain = struct {
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

pub const identity_gm = [6]i32{ 0, 0, 1 << common.WARPEDMODEL_PREC_BITS, 0, 0, 1 << common.WARPEDMODEL_PREC_BITS };
pub const default_ref_deltas = [8]i8{ 1, 0, 0, 0, -1, 0, -1, -1 };

pub const max_tiles = 64;

/// A frame's uncompressed header (5.9), with what follows from it.
pub const Frame = struct {
    show_existing_frame: bool = false,
    frame_to_show_map_idx: u8 = 0,
    frame_type: u8 = 0,
    intra: bool = false,
    show_frame: bool = false,
    showable_frame: bool = false,
    error_resilient_mode: bool = false,
    disable_cdf_update: bool = false,
    allow_screen_content_tools: bool = false,
    force_integer_mv: bool = false,
    current_frame_id: u32 = 0,
    frame_size_override_flag: bool = false,
    order_hint: u32 = 0,
    primary_ref_frame: u8 = common.PRIMARY_REF_NONE,
    refresh_frame_flags: u8 = 0,
    allow_intrabc: bool = false,
    ref_frame_idx: [7]u8 = @splat(0),
    allow_high_precision_mv: bool = false,
    interpolation_filter: u8 = 0,
    is_motion_mode_switchable: bool = false,
    use_ref_frame_mvs: bool = false,
    disable_frame_end_update_cdf: bool = true,
    order_hints: [8]u32 = @splat(0),
    ref_frame_sign_bias: [8]bool = @splat(false),

    // Size.
    frame_width: u32 = 0,
    frame_height: u32 = 0,
    upscaled_width: u32 = 0,
    render_width: u32 = 0,
    render_height: u32 = 0,
    use_superres: bool = false,
    superres_denom: u32 = 8,
    mi_cols: u32 = 0,
    mi_rows: u32 = 0,

    // Tiles.
    tile_cols: u32 = 1,
    tile_rows: u32 = 1,
    tile_cols_log2: u5 = 0,
    tile_rows_log2: u5 = 0,
    mi_col_starts: [max_tiles + 1]u32 = @splat(0),
    mi_row_starts: [max_tiles + 1]u32 = @splat(0),
    context_update_tile_id: u32 = 0,
    tile_size_bytes: u32 = 4,

    // Quantiser.
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
    delta_q_res: u2 = 0,
    delta_lf_present: bool = false,
    delta_lf_res: u2 = 0,
    delta_lf_multi: bool = false,
    lossless: [8]bool = @splat(false),
    coded_lossless: bool = false,
    all_lossless: bool = false,
    seg_qm_level: [3][8]u8 = @splat(@splat(15)),

    // Segmentation.
    segmentation_enabled: bool = false,
    segmentation_update_map: bool = false,
    segmentation_temporal_update: bool = false,
    segmentation_update_data: bool = false,
    feature_enabled: [8][8]bool = @splat(@splat(false)),
    feature_data: [8][8]i16 = @splat(@splat(0)),
    seg_id_pre_skip: bool = false,
    last_active_seg_id: u8 = 0,

    // Loop filter.
    loop_filter_level: [4]u8 = @splat(0),
    loop_filter_sharpness: u8 = 0,
    loop_filter_delta_enabled: bool = false,
    loop_filter_ref_deltas: [8]i8 = default_ref_deltas,
    loop_filter_mode_deltas: [2]i8 = .{ 0, 0 },

    // CDEF.
    cdef_damping: u8 = 3,
    cdef_bits: u2 = 0,
    cdef_y_pri_strength: [8]u8 = @splat(0),
    cdef_y_sec_strength: [8]u8 = @splat(0),
    cdef_uv_pri_strength: [8]u8 = @splat(0),
    cdef_uv_sec_strength: [8]u8 = @splat(0),
    enable_cdef: bool = false,

    // Loop restoration.
    frame_restoration_type: [3]u8 = @splat(common.RESTORE_NONE),
    loop_restoration_size: [3]u32 = @splat(64),
    uses_lr: bool = false,

    tx_mode: u8 = 0,
    reference_select: bool = false,
    skip_mode_present: bool = false,
    skip_mode_frame: [2]i8 = .{ 0, 0 },
    allow_warped_motion: bool = false,
    reduced_tx_set: bool = false,
    gm_type: [8]u8 = @splat(common.IDENTITY),
    gm_params: [8][6]i32 = @splat(identity_gm),
    grain: Grain = .{},

    pub fn qindex(h: *const Frame, ignore_delta: bool, current: i32, segment: u8) u8 {
        if (h.featureActive(segment, common.SEG_LVL_ALT_Q)) {
            const data: i32 = h.feature_data[segment][common.SEG_LVL_ALT_Q];
            var q: i32 = @as(i32, h.base_q_idx) + data;
            if (!ignore_delta and h.delta_q_present) q = current + data;
            return @intCast(common.clip3(0, 255, q));
        }
        if (!ignore_delta and h.delta_q_present) return @intCast(current);
        return h.base_q_idx;
    }

    pub fn featureActive(h: *const Frame, segment: u8, feature: usize) bool {
        return h.segmentation_enabled and h.feature_enabled[segment][feature];
    }

    pub fn sbSize(h: *const Frame, seq: *const Sequence) u32 {
        _ = h;
        return if (seq.use_128x128) 128 else 64;
    }
};

/// The library's names of the sequence header's fields the decoder names
/// otherwise.
const sequence_renamed = .{
    .{ "profile", "seq_profile" },
    .{ "timing_info_present", "timing_info_present_flag" },
    .{ "decoder_model_info_present", "decoder_model_info_present_flag" },
    .{ "decoder_model_present", "decoder_model_present_for_this_op" },
    .{ "idc", "chosen_operating_point_idc" },
    .{ "frame_id_numbers_present", "frame_id_numbers_present_flag" },
    .{ "use_128x128", "use_128x128_superblock" },
    .{ "force_screen_content_tools", "seq_force_screen_content_tools" },
    .{ "force_integer_mv", "seq_force_integer_mv" },
    .{ "mono", "mono_chrome" },
    .{ "primaries", "color_primaries" },
    .{ "transfer", "transfer_characteristics" },
    .{ "matrix", "matrix_coefficients" },
    .{ "full_range", "color_range" },
    .{ "ss_x", "subsampling_x" },
    .{ "ss_y", "subsampling_y" },
};

/// And of the frame header's.
const frame_renamed = .{
    .{ "intra", "frame_is_intra" },
    .{ "grain", "film_grain" },
};

/// The sequence header the library read, as the decoder keeps it.
pub fn sequenceOf(s: *const av1.Av1Sequence) Sequence {
    return copy(Sequence, s, sequence_renamed);
}

/// The frame header the library read, as the decoder keeps it.
pub fn frameOf(h: *const av1.Av1FrameHeader) Frame {
    return copy(Frame, h, frame_renamed);
}

/// The film grain the library read, as the decoder keeps it.
pub fn grainOf(g: *const av1.Av1FilmGrain) Grain {
    return copy(Grain, g, .{});
}

fn libraryName(comptime name: []const u8, comptime names: anytype) []const u8 {
    @setEvalBranchQuota(10_000);
    inline for (names) |pair| {
        if (comptime eql(pair[0], name)) return pair[1];
    }
    return name;
}

fn eql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// A `T` from `from`, field by field; `names` the library's names of the
/// fields named otherwise.
fn copy(comptime T: type, from: anytype, comptime names: anytype) T {
    const From = @TypeOf(from.*);
    var out: T = .{};
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const name = comptime libraryName(f.name, names);
        if (!@hasField(From, name)) @compileError("the library's " ++ @typeName(From) ++ " has no " ++ name);
        @field(out, f.name) = convert(f.type, @field(from.*, name));
    }
    return out;
}

/// `value` as a `T`: an integer narrowed, an array element by element,
/// the film grain field by field.
fn convert(comptime T: type, value: anytype) T {
    const V = @TypeOf(value);
    if (T == V) return value;
    switch (@typeInfo(T)) {
        .int => return @intCast(value),
        .array => |a| {
            var out: T = undefined;
            for (&out, value) |*o, v| o.* = convert(a.child, v);
            return out;
        },
        .@"struct" => return copy(T, &value, .{}),
        else => @compileError("no copy of " ++ @typeName(V) ++ " into " ++ @typeName(T)),
    }
}
