// SPDX-License-Identifier: MIT
//! The headers in plain bits: OBUs (5.3), the sequence header (5.5) and a
//! frame's uncompressed header (5.9) - its type, size and references, the
//! tiles, the quantiser, the segmentation, the filters, the global motion
//! and the film grain.

const common = @import("common.zig");
const tables = @import("tables.zig");
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
    /// f(n).
    pub fn f(r: *Bits, n: u6) u32 {
        var v: u32 = 0;
        for (0..n) |_| v = (v << 1) | r.bit();
        return v;
    }
    /// su(n): `n` bits, signed.
    pub fn su(r: *Bits, n: u6) i32 {
        const v: i32 = @bitCast(r.f(n));
        const sign = @as(i32, 1) << @intCast(n - 1);
        return if (v & sign != 0) v - 2 * sign else v;
    }
    /// ns(n): a number below `n`, in as few bits as it takes.
    pub fn ns(r: *Bits, n: u32) u32 {
        if (n <= 1) return 0;
        const w: u6 = @as(u6, common.floorLog2(n)) + 1;
        const m = (@as(u32, 1) << @intCast(w)) - n;
        const v = r.f(w - 1);
        if (v < m) return v;
        const extra = r.bit();
        return (v << 1) - m + extra;
    }
    /// uvlc().
    pub fn uvlc(r: *Bits) u32 {
        var zeros: u32 = 0;
        while (r.bit() == 0) {
            zeros += 1;
            if (r.overrun()) return 0xFFFF_FFFF;
        }
        if (zeros >= 32) return 0xFFFF_FFFF;
        return r.f(@intCast(zeros)) + ((@as(u32, 1) << @intCast(zeros)) - 1);
    }
    /// le(n): `n` bytes, the least significant first.
    pub fn le(r: *Bits, n: u32) u32 {
        var v: u32 = 0;
        for (0..n) |i| v |= r.f(8) << @intCast(8 * i);
        return v;
    }
    pub fn byteAlign(r: *Bits) void {
        r.pos = (r.pos + 7) & ~@as(usize, 7);
    }
    pub fn overrun(r: *const Bits) bool {
        return r.pos > r.data.len * 8;
    }
};

/// leb128() at `data[at..]`: the value, and how many bytes it took; null
/// when it does not end in the data or is too big.
pub fn leb128(data: []const u8, at: usize) ?struct { value: u64, len: usize } {
    var v: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        if (at + i >= data.len) return null;
        const b = data[at + i];
        v |= @as(u64, b & 0x7F) << @intCast(7 * i);
        if (b & 0x80 == 0) return .{ .value = v, .len = i + 1 };
    }
    return null;
}

pub const OBU_SEQUENCE_HEADER = 1;
pub const OBU_TEMPORAL_DELIMITER = 2;
pub const OBU_FRAME_HEADER = 3;
pub const OBU_TILE_GROUP = 4;
pub const OBU_METADATA = 5;
pub const OBU_FRAME = 6;
pub const OBU_REDUNDANT_FRAME_HEADER = 7;
pub const OBU_TILE_LIST = 8;
pub const OBU_PADDING = 15;

/// An OBU of a temporal unit: its type, layer and payload.
pub const Obu = struct {
    kind: u8,
    temporal_id: u8 = 0,
    spatial_id: u8 = 0,
    extension: bool = false,
    payload: []const u8,
    /// The whole OBU's length in `data`.
    len: usize,
};

/// The OBU at the start of `data` (5.3.1): with its size field, or the
/// rest of `data` without one.
pub fn obu(data: []const u8) Error!Obu {
    if (data.len < 1) return error.Corrupt;
    const h = data[0];
    if (h & 0x80 != 0) return error.Corrupt;
    var o: Obu = .{ .kind = (h >> 3) & 15, .payload = &.{}, .len = 0 };
    var at: usize = 1;
    if (h & 4 != 0) {
        if (data.len < 2) return error.Corrupt;
        o.extension = true;
        o.temporal_id = data[1] >> 5;
        o.spatial_id = (data[1] >> 3) & 3;
        at = 2;
    }
    var size: usize = data.len - at;
    if (h & 2 != 0) {
        const l = leb128(data, at) orelse return error.Corrupt;
        at += l.len;
        if (l.value > data.len - at) return error.Corrupt;
        size = @intCast(l.value);
    }
    o.payload = data[at .. at + size];
    o.len = at + size;
    return o;
}

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

/// sequence_header_obu (5.5).
pub fn sequence(payload: []const u8) Error!Sequence {
    var b: Bits = .{ .data = payload };
    var s: Sequence = .{};
    s.profile = @intCast(b.f(3));
    if (s.profile > 2) return error.Unsupported;
    s.still_picture = b.flag();
    s.reduced_still_picture_header = b.flag();
    var buffer_delay_length: u6 = 0;
    if (s.reduced_still_picture_header) {
        _ = b.f(5);
    } else {
        s.timing_info_present = b.flag();
        if (s.timing_info_present) {
            _ = b.f(32);
            _ = b.f(32);
            s.equal_picture_interval = b.flag();
            if (s.equal_picture_interval) _ = b.uvlc();
            s.decoder_model_info_present = b.flag();
            if (s.decoder_model_info_present) {
                buffer_delay_length = @intCast(b.f(5) + 1);
                _ = b.f(32);
                s.buffer_removal_time_length = @intCast(b.f(5) + 1);
                s.frame_presentation_time_length = @intCast(b.f(5) + 1);
            }
        }
        const initial_display_delay_present = b.flag();
        s.operating_points = @intCast(b.f(5) + 1);
        for (0..s.operating_points) |i| {
            s.operating_point_idc[i] = @intCast(b.f(12));
            const level = b.f(5);
            if (level > 7) _ = b.f(1);
            if (s.decoder_model_info_present) {
                s.decoder_model_present[i] = b.flag();
                if (s.decoder_model_present[i]) {
                    _ = b.f(buffer_delay_length);
                    _ = b.f(buffer_delay_length);
                    _ = b.f(1);
                }
            }
            if (initial_display_delay_present) {
                if (b.flag()) _ = b.f(4);
            }
        }
    }
    s.idc = s.operating_point_idc[0];
    s.frame_width_bits = @intCast(b.f(4) + 1);
    s.frame_height_bits = @intCast(b.f(4) + 1);
    s.max_frame_width = b.f(s.frame_width_bits) + 1;
    s.max_frame_height = b.f(s.frame_height_bits) + 1;
    if (!s.reduced_still_picture_header) s.frame_id_numbers_present = b.flag();
    if (s.frame_id_numbers_present) {
        s.delta_frame_id_length = @intCast(b.f(4) + 2);
        s.frame_id_length = @intCast(b.f(3) + 1 + s.delta_frame_id_length);
    }
    s.use_128x128 = b.flag();
    s.enable_filter_intra = b.flag();
    s.enable_intra_edge_filter = b.flag();
    if (!s.reduced_still_picture_header) {
        s.enable_interintra_compound = b.flag();
        s.enable_masked_compound = b.flag();
        s.enable_warped_motion = b.flag();
        s.enable_dual_filter = b.flag();
        s.enable_order_hint = b.flag();
        if (s.enable_order_hint) {
            s.enable_jnt_comp = b.flag();
            s.enable_ref_frame_mvs = b.flag();
        }
        s.force_screen_content_tools = if (b.flag()) SELECT_SCREEN_CONTENT_TOOLS else b.bit();
        if (s.force_screen_content_tools > 0) {
            s.force_integer_mv = if (b.flag()) SELECT_INTEGER_MV else b.bit();
        }
        if (s.enable_order_hint) s.order_hint_bits = @intCast(b.f(3) + 1);
    }
    s.enable_superres = b.flag();
    s.enable_cdef = b.flag();
    s.enable_restoration = b.flag();

    // color_config (5.5.2)
    const high_bitdepth = b.flag();
    if (s.profile == 2 and high_bitdepth) {
        s.bit_depth = if (b.flag()) 12 else 10;
    } else {
        s.bit_depth = if (high_bitdepth) 10 else 8;
    }
    s.mono = if (s.profile == 1) false else b.flag();
    if (b.flag()) {
        s.primaries = @intCast(b.f(8));
        s.transfer = @intCast(b.f(8));
        s.matrix = @intCast(b.f(8));
    }
    if (s.mono) {
        s.full_range = b.flag();
        s.ss_x = 1;
        s.ss_y = 1;
    } else if (s.primaries == 1 and s.transfer == 13 and s.matrix == common.MC_IDENTITY) {
        s.full_range = true;
        s.ss_x = 0;
        s.ss_y = 0;
    } else {
        s.full_range = b.flag();
        if (s.profile == 0) {
            s.ss_x = 1;
            s.ss_y = 1;
        } else if (s.profile == 1) {
            s.ss_x = 0;
            s.ss_y = 0;
        } else if (s.bit_depth == 12) {
            s.ss_x = b.bit();
            s.ss_y = if (s.ss_x == 1) b.bit() else 0;
        } else {
            s.ss_x = 1;
            s.ss_y = 0;
        }
        if (s.ss_x == 1 and s.ss_y == 1) _ = b.f(2);
    }
    if (!s.mono) s.separate_uv_delta_q = b.flag();
    s.film_grain_params_present = b.flag();
    if (b.overrun()) return error.Corrupt;
    return s;
}

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

/// What a reference slot keeps that the headers after it read
/// (7.20): its size, type and order, and the settings frames inherit.
pub const RefState = struct {
    valid: bool = false,
    frame_id: u32 = 0,
    frame_type: u8 = 0,
    order_hint: u32 = 0,
    upscaled_width: u32 = 0,
    frame_width: u32 = 0,
    frame_height: u32 = 0,
    render_width: u32 = 0,
    render_height: u32 = 0,
    mi_cols: u32 = 0,
    mi_rows: u32 = 0,
    bit_depth: u8 = 8,
    ss_x: u1 = 1,
    ss_y: u1 = 1,
    showable: bool = false,
    saved_order_hints: [8]u32 = @splat(0),
    gm_params: [8][6]i32 = @splat(identity_gm),
    lf_ref_deltas: [8]i8 = default_ref_deltas,
    lf_mode_deltas: [2]i8 = .{ 0, 0 },
    feature_enabled: [8][8]bool = @splat(@splat(false)),
    feature_data: [8][8]i16 = @splat(@splat(0)),
    grain: Grain = .{},
};

pub const identity_gm = [6]i32{ 0, 0, 1 << common.WARPEDMODEL_PREC_BITS, 0, 0, 1 << common.WARPEDMODEL_PREC_BITS };
pub const default_ref_deltas = [8]i8{ 1, 0, 0, 0, -1, 0, -1, -1 };

/// What frames hand on to the next headers outside the reference slots:
/// the order hints of the references, and the frame id.
pub const Carry = struct {
    order_hints: [8]u32 = @splat(0),
    current_frame_id: u32 = 0,
};

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

fn computeImageSize(h: *Frame) void {
    h.mi_cols = 2 * ((h.frame_width + 7) >> 3);
    h.mi_rows = 2 * ((h.frame_height + 7) >> 3);
}

fn superresParams(b: *Bits, seq: *const Sequence, h: *Frame) void {
    h.use_superres = if (seq.enable_superres) b.flag() else false;
    h.superres_denom = if (h.use_superres) b.f(3) + 9 else 8;
    h.upscaled_width = h.frame_width;
    h.frame_width = (h.upscaled_width * 8 + h.superres_denom / 2) / h.superres_denom;
}

fn frameSize(b: *Bits, seq: *const Sequence, h: *Frame) void {
    if (h.frame_size_override_flag) {
        h.frame_width = b.f(seq.frame_width_bits) + 1;
        h.frame_height = b.f(seq.frame_height_bits) + 1;
    } else {
        h.frame_width = seq.max_frame_width;
        h.frame_height = seq.max_frame_height;
    }
    superresParams(b, seq, h);
    computeImageSize(h);
}

fn renderSize(b: *Bits, h: *Frame) void {
    if (b.flag()) {
        h.render_width = b.f(16) + 1;
        h.render_height = b.f(16) + 1;
    } else {
        h.render_width = h.upscaled_width;
        h.render_height = h.frame_height;
    }
}

fn tileLog2(blk: u32, target: u32) u5 {
    var k: u5 = 0;
    while ((blk << k) < target) k += 1;
    return k;
}

fn tileInfo(b: *Bits, seq: *const Sequence, h: *Frame) Error!void {
    const sb_cols = if (seq.use_128x128) (h.mi_cols + 31) >> 5 else (h.mi_cols + 15) >> 4;
    const sb_rows = if (seq.use_128x128) (h.mi_rows + 31) >> 5 else (h.mi_rows + 15) >> 4;
    const sb_shift: u5 = if (seq.use_128x128) 5 else 4;
    const sb_size: u5 = sb_shift + 2;
    const max_tile_width_sb = @as(u32, 4096) >> sb_size;
    var max_tile_area_sb = @as(u32, 4096 * 2304) >> (2 * sb_size);
    const min_log2_tile_cols = tileLog2(max_tile_width_sb, sb_cols);
    const max_log2_tile_cols = tileLog2(1, @min(sb_cols, max_tiles));
    const max_log2_tile_rows = tileLog2(1, @min(sb_rows, max_tiles));
    const min_log2_tiles = @max(min_log2_tile_cols, tileLog2(max_tile_area_sb, sb_rows * sb_cols));
    if (b.flag()) {
        h.tile_cols_log2 = min_log2_tile_cols;
        while (h.tile_cols_log2 < max_log2_tile_cols) {
            if (!b.flag()) break;
            h.tile_cols_log2 += 1;
        }
        const tile_width_sb = (sb_cols + (@as(u32, 1) << h.tile_cols_log2) - 1) >> h.tile_cols_log2;
        var i: u32 = 0;
        var start: u32 = 0;
        while (start < sb_cols) : (start += tile_width_sb) {
            if (i >= max_tiles) return error.Corrupt;
            h.mi_col_starts[i] = start << sb_shift;
            i += 1;
        }
        h.mi_col_starts[i] = h.mi_cols;
        h.tile_cols = i;
        const min_log2_tile_rows = if (min_log2_tiles > h.tile_cols_log2) min_log2_tiles - h.tile_cols_log2 else 0;
        h.tile_rows_log2 = min_log2_tile_rows;
        while (h.tile_rows_log2 < max_log2_tile_rows) {
            if (!b.flag()) break;
            h.tile_rows_log2 += 1;
        }
        const tile_height_sb = (sb_rows + (@as(u32, 1) << h.tile_rows_log2) - 1) >> h.tile_rows_log2;
        i = 0;
        start = 0;
        while (start < sb_rows) : (start += tile_height_sb) {
            if (i >= max_tiles) return error.Corrupt;
            h.mi_row_starts[i] = start << sb_shift;
            i += 1;
        }
        h.mi_row_starts[i] = h.mi_rows;
        h.tile_rows = i;
    } else {
        var widest: u32 = 0;
        var start: u32 = 0;
        var i: u32 = 0;
        while (start < sb_cols) : (i += 1) {
            if (i >= max_tiles) return error.Corrupt;
            h.mi_col_starts[i] = start << sb_shift;
            const max_width = @min(sb_cols - start, max_tile_width_sb);
            const size = b.ns(max_width) + 1;
            widest = @max(widest, size);
            start += size;
        }
        h.mi_col_starts[i] = h.mi_cols;
        h.tile_cols = i;
        h.tile_cols_log2 = tileLog2(1, h.tile_cols);
        if (min_log2_tiles > 0) {
            max_tile_area_sb = (sb_rows * sb_cols) >> (min_log2_tiles + 1);
        } else {
            max_tile_area_sb = sb_rows * sb_cols;
        }
        const max_tile_height_sb = @max(max_tile_area_sb / widest, 1);
        start = 0;
        i = 0;
        while (start < sb_rows) : (i += 1) {
            if (i >= max_tiles) return error.Corrupt;
            h.mi_row_starts[i] = start << sb_shift;
            const max_height = @min(sb_rows - start, max_tile_height_sb);
            start += b.ns(max_height) + 1;
        }
        h.mi_row_starts[i] = h.mi_rows;
        h.tile_rows = i;
        h.tile_rows_log2 = tileLog2(1, h.tile_rows);
    }
    if (h.tile_cols_log2 > 0 or h.tile_rows_log2 > 0) {
        h.context_update_tile_id = b.f(@as(u6, h.tile_rows_log2) + h.tile_cols_log2);
        h.tile_size_bytes = b.f(2) + 1;
        if (h.context_update_tile_id >= h.tile_cols * h.tile_rows) return error.Corrupt;
    } else {
        h.context_update_tile_id = 0;
    }
}

fn readDeltaQ(b: *Bits) i8 {
    return if (b.flag()) @intCast(b.su(7)) else 0;
}

fn decodeSubexp(b: *Bits, num_syms: i32) i32 {
    var i: u5 = 0;
    var mk: i32 = 0;
    const k: u5 = 3;
    while (true) {
        const b2: u5 = if (i != 0) k + i - 1 else k;
        const a = @as(i32, 1) << b2;
        if (num_syms <= mk + 3 * a) {
            return @as(i32, @intCast(b.ns(@intCast(num_syms - mk)))) + mk;
        }
        if (b.flag()) {
            i += 1;
            mk += a;
        } else {
            return @as(i32, @intCast(b.f(b2))) + mk;
        }
    }
}

fn inverseRecenter(r: i32, v: i32) i32 {
    if (v > 2 * r) return v;
    if (v & 1 != 0) return r - ((v + 1) >> 1);
    return r + (v >> 1);
}

fn decodeUnsignedSubexpWithRef(b: *Bits, mx: i32, r: i32) i32 {
    const v = decodeSubexp(b, mx);
    if ((r << 1) <= mx) return inverseRecenter(r, v);
    return mx - 1 - inverseRecenter(mx - 1 - r, v);
}

fn decodeSignedSubexpWithRef(b: *Bits, low: i32, high: i32, r: i32) i32 {
    return decodeUnsignedSubexpWithRef(b, high - low, r - low) + low;
}

fn readGlobalParam(b: *Bits, h: *Frame, prev: *const [8][6]i32, kind: u8, ref: usize, idx: usize) void {
    var abs_bits: u5 = 12;
    var prec_bits: u5 = 15;
    if (idx < 2) {
        if (kind == common.TRANSLATION) {
            const hp: u5 = @intFromBool(!h.allow_high_precision_mv);
            abs_bits = 9 - hp;
            prec_bits = 3 - hp;
        } else {
            abs_bits = 12;
            prec_bits = 6;
        }
    }
    const prec_diff: u5 = common.WARPEDMODEL_PREC_BITS - prec_bits;
    const round: i32 = if (idx % 3 == 2) 1 << common.WARPEDMODEL_PREC_BITS else 0;
    const sub: i32 = if (idx % 3 == 2) @as(i32, 1) << prec_bits else 0;
    const mx = @as(i32, 1) << abs_bits;
    const r = (prev[ref][idx] >> prec_diff) - sub;
    h.gm_params[ref][idx] = (decodeSignedSubexpWithRef(b, -mx, mx + 1, r) << prec_diff) + round;
}

fn filmGrain(b: *Bits, seq: *const Sequence, refs: *const [8]RefState, h: *Frame) Error!void {
    if (!seq.film_grain_params_present or (!h.show_frame and !h.showable_frame)) {
        h.grain = .{};
        return;
    }
    var g: Grain = .{};
    g.apply_grain = b.flag();
    if (!g.apply_grain) {
        h.grain = .{};
        return;
    }
    g.grain_seed = @intCast(b.f(16));
    const update_grain = if (h.frame_type == common.INTER_FRAME) b.flag() else true;
    if (!update_grain) {
        const idx = b.f(3);
        // A reference this frame does not name cannot be loaded.
        var named = false;
        for (h.ref_frame_idx) |r| named = named or r == idx;
        if (!named) return error.Corrupt;
        const seed = g.grain_seed;
        h.grain = refs[idx].grain;
        h.grain.grain_seed = seed;
        return;
    }
    g.num_y_points = @intCast(b.f(4));
    if (g.num_y_points > 14) return error.Corrupt;
    for (0..g.num_y_points) |i| {
        g.point_y_value[i] = @intCast(b.f(8));
        g.point_y_scaling[i] = @intCast(b.f(8));
        if (i > 0 and g.point_y_value[i] <= g.point_y_value[i - 1]) return error.Corrupt;
    }
    g.chroma_scaling_from_luma = if (seq.mono) false else b.flag();
    if (seq.mono or g.chroma_scaling_from_luma or (seq.ss_x == 1 and seq.ss_y == 1 and g.num_y_points == 0)) {
        g.num_cb_points = 0;
        g.num_cr_points = 0;
    } else {
        g.num_cb_points = @intCast(b.f(4));
        if (g.num_cb_points > 10) return error.Corrupt;
        for (0..g.num_cb_points) |i| {
            g.point_cb_value[i] = @intCast(b.f(8));
            g.point_cb_scaling[i] = @intCast(b.f(8));
            if (i > 0 and g.point_cb_value[i] <= g.point_cb_value[i - 1]) return error.Corrupt;
        }
        g.num_cr_points = @intCast(b.f(4));
        if (g.num_cr_points > 10) return error.Corrupt;
        for (0..g.num_cr_points) |i| {
            g.point_cr_value[i] = @intCast(b.f(8));
            g.point_cr_scaling[i] = @intCast(b.f(8));
            if (i > 0 and g.point_cr_value[i] <= g.point_cr_value[i - 1]) return error.Corrupt;
        }
    }
    g.grain_scaling_minus_8 = @intCast(b.f(2));
    g.ar_coeff_lag = @intCast(b.f(2));
    const num_pos_luma: u32 = 2 * @as(u32, g.ar_coeff_lag) * (g.ar_coeff_lag + 1);
    var num_pos_chroma = num_pos_luma;
    if (g.num_y_points > 0) {
        num_pos_chroma = num_pos_luma + 1;
        for (0..num_pos_luma) |i| g.ar_coeffs_y_plus_128[i] = @intCast(b.f(8));
    }
    if (g.chroma_scaling_from_luma or g.num_cb_points > 0) {
        for (0..num_pos_chroma) |i| g.ar_coeffs_cb_plus_128[i] = @intCast(b.f(8));
    }
    if (g.chroma_scaling_from_luma or g.num_cr_points > 0) {
        for (0..num_pos_chroma) |i| g.ar_coeffs_cr_plus_128[i] = @intCast(b.f(8));
    }
    g.ar_coeff_shift_minus_6 = @intCast(b.f(2));
    g.grain_scale_shift = @intCast(b.f(2));
    if (g.num_cb_points > 0) {
        g.cb_mult = @intCast(b.f(8));
        g.cb_luma_mult = @intCast(b.f(8));
        g.cb_offset = @intCast(b.f(9));
    }
    if (g.num_cr_points > 0) {
        g.cr_mult = @intCast(b.f(8));
        g.cr_luma_mult = @intCast(b.f(8));
        g.cr_offset = @intCast(b.f(9));
    }
    g.overlap_flag = b.flag();
    g.clip_to_restricted_range = b.flag();
    h.grain = g;
}

/// set_frame_refs (7.8): the references other than LAST and GOLDEN from
/// the order hints.
fn setFrameRefs(seq: *const Sequence, refs: *const [8]RefState, h: *Frame, last: u8, gold: u8) void {
    var idx: [7]i32 = @splat(-1);
    idx[0] = last;
    idx[@as(usize, @intCast(common.GOLDEN_FRAME)) - 1] = gold;
    var used: [8]bool = @splat(false);
    used[last] = true;
    used[gold] = true;
    const cur_hint = @as(i32, 1) << @intCast(seq.order_hint_bits - 1);
    var shifted: [8]i32 = undefined;
    for (0..8) |i| shifted[i] = cur_hint + seq.dist(refs[i].order_hint, h.order_hint);

    // ALTREF: the latest backward reference; BWDREF and ALTREF2 the
    // earliest ones after that.
    {
        var ref: i32 = -1;
        var latest: i32 = 0;
        for (0..8) |i| {
            const hint = shifted[i];
            if (!used[i] and hint >= cur_hint and (ref < 0 or hint >= latest)) {
                ref = @intCast(i);
                latest = hint;
            }
        }
        if (ref >= 0) {
            idx[@as(usize, @intCast(common.ALTREF_FRAME)) - 1] = ref;
            used[@intCast(ref)] = true;
        }
    }
    for ([2]i8{ common.BWDREF_FRAME, common.ALTREF2_FRAME }) |which| {
        var ref: i32 = -1;
        var earliest: i32 = 0;
        for (0..8) |i| {
            const hint = shifted[i];
            if (!used[i] and hint >= cur_hint and (ref < 0 or hint < earliest)) {
                ref = @intCast(i);
                earliest = hint;
            }
        }
        if (ref >= 0) {
            idx[@as(usize, @intCast(which)) - 1] = ref;
            used[@intCast(ref)] = true;
        }
    }
    for (tables.ref_frame_list) |which| {
        if (idx[which - 1] >= 0) continue;
        var ref: i32 = -1;
        var latest: i32 = 0;
        for (0..8) |i| {
            const hint = shifted[i];
            if (!used[i] and hint < cur_hint and (ref < 0 or hint >= latest)) {
                ref = @intCast(i);
                latest = hint;
            }
        }
        if (ref >= 0) {
            idx[which - 1] = ref;
            used[@intCast(ref)] = true;
        }
    }
    var ref: i32 = -1;
    var earliest: i32 = 0;
    for (0..8) |i| {
        const hint = shifted[i];
        if (ref < 0 or hint < earliest) {
            ref = @intCast(i);
            earliest = hint;
        }
    }
    for (0..7) |i| {
        if (idx[i] < 0) idx[i] = ref;
        h.ref_frame_idx[i] = @intCast(idx[i]);
    }
}

/// uncompressed_header (5.9.2) of a frame with layer `temporal_id` and
/// `spatial_id`, from the references' state `refs`; `carry` is updated.
pub fn frame(b: *Bits, seq: *const Sequence, refs: *const [8]RefState, carry: *Carry, temporal_id: u8, spatial_id: u8) Error!Frame {
    var h: Frame = .{};
    const all_frames: u8 = 0xFF;
    if (seq.reduced_still_picture_header) {
        h.frame_type = common.KEY_FRAME;
        h.intra = true;
        h.show_frame = true;
        h.showable_frame = false;
        h.error_resilient_mode = true;
    } else {
        h.show_existing_frame = b.flag();
        if (h.show_existing_frame) {
            h.frame_to_show_map_idx = @intCast(b.f(3));
            if (seq.decoder_model_info_present and !seq.equal_picture_interval) _ = b.f(seq.frame_presentation_time_length);
            if (seq.frame_id_numbers_present) _ = b.f(seq.frame_id_length);
            const r = &refs[h.frame_to_show_map_idx];
            if (!r.valid) return error.Corrupt;
            h.frame_type = r.frame_type;
            h.refresh_frame_flags = if (h.frame_type == common.KEY_FRAME) all_frames else 0;
            if (seq.film_grain_params_present) h.grain = r.grain;
            h.show_frame = true;
            return h;
        }
        h.frame_type = @intCast(b.f(2));
        h.intra = h.frame_type == common.INTRA_ONLY_FRAME or h.frame_type == common.KEY_FRAME;
        h.show_frame = b.flag();
        if (h.show_frame and seq.decoder_model_info_present and !seq.equal_picture_interval) _ = b.f(seq.frame_presentation_time_length);
        h.showable_frame = if (h.show_frame) h.frame_type != common.KEY_FRAME else b.flag();
        if (h.frame_type == common.SWITCH_FRAME or (h.frame_type == common.KEY_FRAME and h.show_frame)) {
            h.error_resilient_mode = true;
        } else {
            h.error_resilient_mode = b.flag();
        }
    }
    var valid: [8]bool = undefined;
    var ref_order_hint: [8]u32 = undefined;
    for (0..8) |i| {
        valid[i] = refs[i].valid;
        ref_order_hint[i] = refs[i].order_hint;
    }
    if (h.frame_type == common.KEY_FRAME and h.show_frame) {
        valid = @splat(false);
        ref_order_hint = @splat(0);
        for (1..8) |i| carry.order_hints[i] = 0;
    }
    h.disable_cdf_update = b.flag();
    if (seq.force_screen_content_tools == SELECT_SCREEN_CONTENT_TOOLS) {
        h.allow_screen_content_tools = b.flag();
    } else {
        h.allow_screen_content_tools = seq.force_screen_content_tools == 1;
    }
    if (h.allow_screen_content_tools) {
        if (seq.force_integer_mv == SELECT_INTEGER_MV) {
            h.force_integer_mv = b.flag();
        } else {
            h.force_integer_mv = seq.force_integer_mv == 1;
        }
    }
    if (h.intra) h.force_integer_mv = true;
    if (seq.frame_id_numbers_present) {
        h.current_frame_id = b.f(seq.frame_id_length);
        carry.current_frame_id = h.current_frame_id;
    }
    if (h.frame_type == common.SWITCH_FRAME) {
        h.frame_size_override_flag = true;
    } else if (seq.reduced_still_picture_header) {
        h.frame_size_override_flag = false;
    } else {
        h.frame_size_override_flag = b.flag();
    }
    h.order_hint = b.f(seq.order_hint_bits);
    if (h.intra or h.error_resilient_mode) {
        h.primary_ref_frame = common.PRIMARY_REF_NONE;
    } else {
        h.primary_ref_frame = @intCast(b.f(3));
    }
    if (seq.decoder_model_info_present) {
        if (b.flag()) {
            for (0..seq.operating_points) |op| {
                if (!seq.decoder_model_present[op]) continue;
                const idc = seq.operating_point_idc[op];
                const in_temporal = (idc >> @intCast(temporal_id)) & 1 != 0;
                const in_spatial = (idc >> @intCast(spatial_id + 8)) & 1 != 0;
                if (idc == 0 or (in_temporal and in_spatial)) _ = b.f(seq.buffer_removal_time_length);
            }
        }
    }
    if (h.frame_type == common.SWITCH_FRAME or (h.frame_type == common.KEY_FRAME and h.show_frame)) {
        h.refresh_frame_flags = all_frames;
    } else {
        h.refresh_frame_flags = @intCast(b.f(8));
    }
    if (h.intra and h.frame_type == common.INTRA_ONLY_FRAME and h.refresh_frame_flags == all_frames) return error.Corrupt;
    if (!h.intra or h.refresh_frame_flags != all_frames) {
        if (h.error_resilient_mode and seq.enable_order_hint) {
            for (0..8) |i| {
                const hint = b.f(seq.order_hint_bits);
                if (hint != ref_order_hint[i]) {
                    valid[i] = false;
                    ref_order_hint[i] = hint;
                }
            }
        }
    }
    // The references' state as this header sees it.
    var rs = refs.*;
    for (0..8) |i| {
        rs[i].valid = valid[i];
        rs[i].order_hint = ref_order_hint[i];
    }
    if (h.intra) {
        frameSize(b, seq, &h);
        renderSize(b, &h);
        if (h.allow_screen_content_tools and h.upscaled_width == h.frame_width) h.allow_intrabc = b.flag();
    } else {
        var short_signaling = false;
        if (seq.enable_order_hint) {
            short_signaling = b.flag();
            if (short_signaling) {
                const last: u8 = @intCast(b.f(3));
                const gold: u8 = @intCast(b.f(3));
                if (!rs[last].valid or !rs[gold].valid) return error.Corrupt;
                setFrameRefs(seq, &rs, &h, last, gold);
            }
        }
        for (0..7) |i| {
            if (!short_signaling) h.ref_frame_idx[i] = @intCast(b.f(3));
            if (seq.frame_id_numbers_present) _ = b.f(seq.delta_frame_id_length);
            if (!rs[h.ref_frame_idx[i]].valid) return error.Corrupt;
        }
        if (h.frame_size_override_flag and !h.error_resilient_mode) {
            // frame_size_with_refs (5.9.7)
            var found = false;
            for (0..7) |i| {
                if (b.flag()) {
                    const r = &rs[h.ref_frame_idx[i]];
                    h.upscaled_width = r.upscaled_width;
                    h.frame_width = h.upscaled_width;
                    h.frame_height = r.frame_height;
                    h.render_width = r.render_width;
                    h.render_height = r.render_height;
                    found = true;
                    break;
                }
            }
            if (!found) {
                frameSize(b, seq, &h);
                renderSize(b, &h);
            } else {
                superresParams(b, seq, &h);
                computeImageSize(&h);
            }
        } else {
            frameSize(b, seq, &h);
            renderSize(b, &h);
        }
        h.allow_high_precision_mv = if (h.force_integer_mv) false else b.flag();
        h.interpolation_filter = if (b.flag()) common.SWITCHABLE else @intCast(b.f(2));
        h.is_motion_mode_switchable = b.flag();
        if (h.error_resilient_mode or !seq.enable_ref_frame_mvs) {
            h.use_ref_frame_mvs = false;
        } else {
            h.use_ref_frame_mvs = b.flag();
        }
        for (0..7) |i| {
            const hint = rs[h.ref_frame_idx[i]].order_hint;
            carry.order_hints[i + 1] = hint;
            h.ref_frame_sign_bias[i + 1] = if (!seq.enable_order_hint) false else seq.dist(hint, h.order_hint) > 0;
        }
    }
    h.order_hints = carry.order_hints;
    // A frame larger than the sequence header's largest is taken, as
    // dav1d takes it (libaom does not): SVT-AV1 writes such frames, its
    // largest rounded down where the frames' are rounded up to 8, and
    // every frame here is made at its own size.
    if (seq.reduced_still_picture_header or h.disable_cdf_update) {
        h.disable_frame_end_update_cdf = true;
    } else {
        h.disable_frame_end_update_cdf = b.flag();
    }
    // setup_past_independence or load_previous (7.20): the settings the
    // frame starts from.
    var prev_gm: [8][6]i32 = @splat(identity_gm);
    if (h.primary_ref_frame == common.PRIMARY_REF_NONE) {
        h.loop_filter_delta_enabled = true;
        h.loop_filter_ref_deltas = default_ref_deltas;
        h.loop_filter_mode_deltas = .{ 0, 0 };
    } else {
        const p = &rs[h.ref_frame_idx[h.primary_ref_frame]];
        prev_gm = p.gm_params;
        h.loop_filter_ref_deltas = p.lf_ref_deltas;
        h.loop_filter_mode_deltas = p.lf_mode_deltas;
        h.feature_enabled = p.feature_enabled;
        h.feature_data = p.feature_data;
    }
    try tileInfo(b, seq, &h);

    // quantization_params (5.9.12)
    h.base_q_idx = @intCast(b.f(8));
    h.delta_q_y_dc = readDeltaQ(b);
    if (seq.planes() > 1) {
        const diff_uv_delta = if (seq.separate_uv_delta_q) b.flag() else false;
        h.delta_q_u_dc = readDeltaQ(b);
        h.delta_q_u_ac = readDeltaQ(b);
        if (diff_uv_delta) {
            h.delta_q_v_dc = readDeltaQ(b);
            h.delta_q_v_ac = readDeltaQ(b);
        } else {
            h.delta_q_v_dc = h.delta_q_u_dc;
            h.delta_q_v_ac = h.delta_q_u_ac;
        }
    }
    h.using_qmatrix = b.flag();
    if (h.using_qmatrix) {
        h.qm_y = @intCast(b.f(4));
        h.qm_u = @intCast(b.f(4));
        h.qm_v = if (!seq.separate_uv_delta_q) h.qm_u else @intCast(b.f(4));
    }

    // segmentation_params (5.9.14)
    h.segmentation_enabled = b.flag();
    if (h.segmentation_enabled) {
        if (h.primary_ref_frame == common.PRIMARY_REF_NONE) {
            h.segmentation_update_map = true;
            h.segmentation_temporal_update = false;
            h.segmentation_update_data = true;
        } else {
            h.segmentation_update_map = b.flag();
            if (h.segmentation_update_map) h.segmentation_temporal_update = b.flag();
            h.segmentation_update_data = b.flag();
        }
        if (h.segmentation_update_data) {
            for (0..8) |i| {
                for (0..8) |j| {
                    const enabled = b.flag();
                    h.feature_enabled[i][j] = enabled;
                    var clipped: i32 = 0;
                    if (enabled) {
                        const bits: u6 = @intCast(tables.segmentation_feature_bits[j]);
                        const limit: i32 = tables.segmentation_feature_max[j];
                        if (tables.segmentation_feature_signed[j] == 1) {
                            clipped = common.clip3(-limit, limit, b.su(1 + bits));
                        } else {
                            clipped = common.clip3(0, limit, @intCast(b.f(bits)));
                        }
                    }
                    h.feature_data[i][j] = @intCast(clipped);
                }
            }
        }
    } else {
        h.feature_enabled = @splat(@splat(false));
        h.feature_data = @splat(@splat(0));
    }
    h.seg_id_pre_skip = false;
    h.last_active_seg_id = 0;
    for (0..8) |i| {
        for (0..8) |j| {
            if (h.feature_enabled[i][j]) {
                h.last_active_seg_id = @intCast(i);
                if (j >= common.SEG_LVL_REF_FRAME) h.seg_id_pre_skip = true;
            }
        }
    }

    // delta_q_params, delta_lf_params (5.9.17, 5.9.18)
    if (h.base_q_idx > 0) h.delta_q_present = b.flag();
    if (h.delta_q_present) h.delta_q_res = @intCast(b.f(2));
    if (h.delta_q_present) {
        if (!h.allow_intrabc) h.delta_lf_present = b.flag();
        if (h.delta_lf_present) {
            h.delta_lf_res = @intCast(b.f(2));
            h.delta_lf_multi = b.flag();
        }
    }
    h.coded_lossless = true;
    for (0..8) |si| {
        const seg: u8 = @intCast(si);
        const q = h.qindex(true, 0, seg);
        h.lossless[si] = q == 0 and h.delta_q_y_dc == 0 and h.delta_q_u_ac == 0 and h.delta_q_u_dc == 0 and
            h.delta_q_v_ac == 0 and h.delta_q_v_dc == 0;
        if (!h.lossless[si]) h.coded_lossless = false;
        if (h.using_qmatrix) {
            if (h.lossless[si]) {
                h.seg_qm_level[0][si] = 15;
                h.seg_qm_level[1][si] = 15;
                h.seg_qm_level[2][si] = 15;
            } else {
                h.seg_qm_level[0][si] = h.qm_y;
                h.seg_qm_level[1][si] = h.qm_u;
                h.seg_qm_level[2][si] = h.qm_v;
            }
        }
    }
    h.all_lossless = h.coded_lossless and h.frame_width == h.upscaled_width;

    // loop_filter_params (5.9.11)
    if (h.coded_lossless or h.allow_intrabc) {
        h.loop_filter_level = @splat(0);
        h.loop_filter_ref_deltas = default_ref_deltas;
        h.loop_filter_mode_deltas = .{ 0, 0 };
    } else {
        h.loop_filter_level[0] = @intCast(b.f(6));
        h.loop_filter_level[1] = @intCast(b.f(6));
        if (seq.planes() > 1) {
            if (h.loop_filter_level[0] != 0 or h.loop_filter_level[1] != 0) {
                h.loop_filter_level[2] = @intCast(b.f(6));
                h.loop_filter_level[3] = @intCast(b.f(6));
            }
        }
        h.loop_filter_sharpness = @intCast(b.f(3));
        h.loop_filter_delta_enabled = b.flag();
        if (h.loop_filter_delta_enabled) {
            if (b.flag()) {
                for (0..8) |i| {
                    if (b.flag()) h.loop_filter_ref_deltas[i] = @intCast(b.su(7));
                }
                for (0..2) |i| {
                    if (b.flag()) h.loop_filter_mode_deltas[i] = @intCast(b.su(7));
                }
            }
        }
    }

    // cdef_params (5.9.19)
    if (h.coded_lossless or h.allow_intrabc or !seq.enable_cdef) {
        h.cdef_bits = 0;
        h.cdef_y_pri_strength[0] = 0;
        h.cdef_y_sec_strength[0] = 0;
        h.cdef_uv_pri_strength[0] = 0;
        h.cdef_uv_sec_strength[0] = 0;
        h.cdef_damping = 3;
        h.enable_cdef = false;
    } else {
        h.enable_cdef = true;
        h.cdef_damping = @intCast(b.f(2) + 3);
        h.cdef_bits = @intCast(b.f(2));
        for (0..(@as(u32, 1) << h.cdef_bits)) |i| {
            h.cdef_y_pri_strength[i] = @intCast(b.f(4));
            h.cdef_y_sec_strength[i] = @intCast(b.f(2));
            if (h.cdef_y_sec_strength[i] == 3) h.cdef_y_sec_strength[i] += 1;
            if (seq.planes() > 1) {
                h.cdef_uv_pri_strength[i] = @intCast(b.f(4));
                h.cdef_uv_sec_strength[i] = @intCast(b.f(2));
                if (h.cdef_uv_sec_strength[i] == 3) h.cdef_uv_sec_strength[i] += 1;
            }
        }
    }

    // lr_params (5.9.20)
    if (h.all_lossless or h.allow_intrabc or !seq.enable_restoration) {
        h.frame_restoration_type = @splat(common.RESTORE_NONE);
        h.uses_lr = false;
    } else {
        var uses_chroma_lr = false;
        for (0..seq.planes()) |i| {
            h.frame_restoration_type[i] = tables.remap_lr_type[b.f(2)];
            if (h.frame_restoration_type[i] != common.RESTORE_NONE) {
                h.uses_lr = true;
                if (i > 0) uses_chroma_lr = true;
            }
        }
        if (h.uses_lr) {
            var shift: u5 = 0;
            if (seq.use_128x128) {
                shift = @as(u5, b.bit()) + 1;
            } else {
                shift = b.bit();
                if (shift != 0) shift += b.bit();
            }
            h.loop_restoration_size[0] = @as(u32, 256) >> (2 - shift);
            const uv_shift: u5 = if (seq.ss_x == 1 and seq.ss_y == 1 and uses_chroma_lr) b.bit() else 0;
            h.loop_restoration_size[1] = h.loop_restoration_size[0] >> uv_shift;
            h.loop_restoration_size[2] = h.loop_restoration_size[0] >> uv_shift;
        }
    }

    // read_tx_mode (5.9.21)
    if (h.coded_lossless) {
        h.tx_mode = common.ONLY_4X4;
    } else {
        h.tx_mode = if (b.flag()) common.TX_MODE_SELECT else common.TX_MODE_LARGEST;
    }

    // frame_reference_mode (5.9.23)
    h.reference_select = if (h.intra) false else b.flag();

    // skip_mode_params (5.9.22)
    var skip_mode_allowed = false;
    if (!h.intra and h.reference_select and seq.enable_order_hint) {
        var forward_idx: i32 = -1;
        var backward_idx: i32 = -1;
        var forward_hint: u32 = 0;
        var backward_hint: u32 = 0;
        for (0..7) |i| {
            const ref_hint = rs[h.ref_frame_idx[i]].order_hint;
            if (seq.dist(ref_hint, h.order_hint) < 0) {
                if (forward_idx < 0 or seq.dist(ref_hint, forward_hint) > 0) {
                    forward_idx = @intCast(i);
                    forward_hint = ref_hint;
                }
            } else if (seq.dist(ref_hint, h.order_hint) > 0) {
                if (backward_idx < 0 or seq.dist(ref_hint, backward_hint) < 0) {
                    backward_idx = @intCast(i);
                    backward_hint = ref_hint;
                }
            }
        }
        if (forward_idx < 0) {
            skip_mode_allowed = false;
        } else if (backward_idx >= 0) {
            skip_mode_allowed = true;
            h.skip_mode_frame[0] = @intCast(common.LAST_FRAME + @min(forward_idx, backward_idx));
            h.skip_mode_frame[1] = @intCast(common.LAST_FRAME + @max(forward_idx, backward_idx));
        } else {
            var second_idx: i32 = -1;
            var second_hint: u32 = 0;
            for (0..7) |i| {
                const ref_hint = rs[h.ref_frame_idx[i]].order_hint;
                if (seq.dist(ref_hint, forward_hint) < 0) {
                    if (second_idx < 0 or seq.dist(ref_hint, second_hint) > 0) {
                        second_idx = @intCast(i);
                        second_hint = ref_hint;
                    }
                }
            }
            if (second_idx >= 0) {
                skip_mode_allowed = true;
                h.skip_mode_frame[0] = @intCast(common.LAST_FRAME + @min(forward_idx, second_idx));
                h.skip_mode_frame[1] = @intCast(common.LAST_FRAME + @max(forward_idx, second_idx));
            }
        }
    }
    h.skip_mode_present = if (skip_mode_allowed) b.flag() else false;

    if (h.intra or h.error_resilient_mode or !seq.enable_warped_motion) {
        h.allow_warped_motion = false;
    } else {
        h.allow_warped_motion = b.flag();
    }
    h.reduced_tx_set = b.flag();

    // global_motion_params (5.9.24)
    if (!h.intra) {
        for (1..8) |ref| {
            var kind: u8 = common.IDENTITY;
            if (b.flag()) {
                if (b.flag()) {
                    kind = common.ROTZOOM;
                } else {
                    kind = if (b.flag()) common.TRANSLATION else common.AFFINE;
                }
            }
            h.gm_type[ref] = kind;
            if (kind >= common.ROTZOOM) {
                readGlobalParam(b, &h, &prev_gm, kind, ref, 2);
                readGlobalParam(b, &h, &prev_gm, kind, ref, 3);
                if (kind == common.AFFINE) {
                    readGlobalParam(b, &h, &prev_gm, kind, ref, 4);
                    readGlobalParam(b, &h, &prev_gm, kind, ref, 5);
                } else {
                    h.gm_params[ref][4] = -h.gm_params[ref][3];
                    h.gm_params[ref][5] = h.gm_params[ref][2];
                }
            }
            if (kind >= common.TRANSLATION) {
                readGlobalParam(b, &h, &prev_gm, kind, ref, 0);
                readGlobalParam(b, &h, &prev_gm, kind, ref, 1);
            }
        }
    }
    try filmGrain(b, seq, &rs, &h);
    if (b.overrun()) return error.Corrupt;
    return h;
}
