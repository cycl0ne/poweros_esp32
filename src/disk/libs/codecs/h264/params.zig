// SPDX-License-Identifier: MIT
//! Sequence and picture parameter sets (7.3.2.1, 7.3.2.2, annex E's VUI):
//! what a stream says once of all its pictures, and once of a few.

const bits_mod = @import("bits.zig");
const Bits = bits_mod.Bits;
const Error = bits_mod.Error;
const tables = @import("tables.zig");

/// The raster position of each place in the 4x4 zigzag scan (8.5.6).
pub const zigzag4 = [16]u8{ 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };
/// ... and in the 8x8 one.
pub const zigzag8 = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

/// The scaling matrices in raster order: six 4x4 (intra Y, Cb, Cr, inter
/// Y, Cb, Cr) and six 8x8 (intra Y, inter Y, intra Cb, inter Cb, intra
/// Cr, inter Cr).
pub const Scaling = struct {
    m4: [6][16]u8 = @splat(@splat(16)),
    m8: [6][64]u8 = @splat(@splat(16)),
};

pub const Sps = struct {
    valid: bool = false,
    profile_idc: u8 = 0,
    constraint_flags: u8 = 0,
    level_idc: u8 = 0,
    chroma_format_idc: u2 = 1,
    separate_colour_plane: bool = false,
    bit_depth_luma: u8 = 8,
    bit_depth_chroma: u8 = 8,
    transform_bypass: bool = false,
    scaling_present: bool = false,
    scaling: Scaling = .{},
    log2_max_frame_num: u5 = 4,
    poc_type: u2 = 0,
    log2_max_poc_lsb: u5 = 4,
    delta_pic_order_always_zero: bool = false,
    offset_for_non_ref_pic: i32 = 0,
    offset_for_top_to_bottom_field: i32 = 0,
    num_ref_frames_in_poc_cycle: u8 = 0,
    offset_for_ref_frame: [255]i32 = @splat(0),
    max_num_ref_frames: u8 = 0,
    gaps_allowed: bool = false,
    width_mbs: u32 = 0,
    height_map_units: u32 = 0,
    frame_mbs_only: bool = true,
    mbaff: bool = false,
    direct_8x8_inference: bool = false,
    crop_left: u32 = 0,
    crop_right: u32 = 0,
    crop_top: u32 = 0,
    crop_bottom: u32 = 0,
    // VUI
    timing: bool = false,
    num_units_in_tick: u32 = 0,
    time_scale: u32 = 0,
    full_range: bool = false,
    matrix: u8 = 2,
    colour_primaries: u8 = 2,
    transfer: u8 = 2,
    restriction: bool = false,
    num_reorder_frames: u32 = 0,
    max_dec_frame_buffering: u32 = 0,

    /// ChromaArrayType: 0 with separate colour planes.
    pub fn chromaArrayType(s: *const Sps) u2 {
        return if (s.separate_colour_plane) 0 else s.chroma_format_idc;
    }
    pub fn heightMbs(s: *const Sps) u32 {
        return s.height_map_units * @as(u32, if (s.frame_mbs_only) 1 else 2);
    }
    pub fn subWidthC(s: *const Sps) u32 {
        return if (s.chroma_format_idc == 1 or s.chroma_format_idc == 2) 2 else 1;
    }
    pub fn subHeightC(s: *const Sps) u32 {
        return if (s.chroma_format_idc == 1) 2 else 1;
    }
    /// The picture's size as shown, after cropping.
    pub fn croppedWidth(s: *const Sps) u32 {
        const unit: u32 = if (s.chromaArrayType() == 0) 1 else s.subWidthC();
        return s.width_mbs * 16 - unit * (s.crop_left + s.crop_right);
    }
    pub fn croppedHeight(s: *const Sps) u32 {
        const unit_y: u32 = (if (s.chromaArrayType() == 0) 1 else s.subHeightC()) * @as(u32, if (s.frame_mbs_only) 1 else 2);
        return s.heightMbs() * 16 - unit_y * (s.crop_top + s.crop_bottom);
    }
    pub fn cropX(s: *const Sps) u32 {
        return s.crop_left * (if (s.chromaArrayType() == 0) 1 else s.subWidthC());
    }
    pub fn cropY(s: *const Sps) u32 {
        return s.crop_top * (if (s.chromaArrayType() == 0) 1 else s.subHeightC()) * @as(u32, if (s.frame_mbs_only) 1 else 2);
    }
    /// The frames the decoded picture buffer holds (A.3.1, A.3.2), or what
    /// the VUI says it needs.
    pub fn dpbFrames(s: *const Sps) u32 {
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

pub const Pps = struct {
    valid: bool = false,
    sps_id: u8 = 0,
    cabac: bool = false,
    bottom_field_poc_present: bool = false,
    num_slice_groups: u8 = 1,
    slice_group_map_type: u8 = 0,
    run_length: [8]u32 = @splat(0),
    top_left: [8]u32 = @splat(0),
    bottom_right: [8]u32 = @splat(0),
    change_direction: bool = false,
    change_rate: u32 = 1,
    /// Type 6: a group for each map unit, the decoder's memory.
    group_ids: []u8 = &.{},
    num_ref_idx_default: [2]u8 = .{ 1, 1 },
    weighted_pred: bool = false,
    weighted_bipred_idc: u2 = 0,
    init_qp: i32 = 26,
    init_qs: i32 = 26,
    chroma_qp_offset: [2]i32 = .{ 0, 0 },
    deblocking_control: bool = false,
    constrained_intra_pred: bool = false,
    redundant_pic_cnt_present: bool = false,
    transform_8x8: bool = false,
    scaling: Scaling = .{},
};

pub const Limits = struct {
    /// How large a picture may be, in macroblocks across and down.
    max_width_mbs: u32 = 512,
    max_height_mbs: u32 = 512,
};

/// One scaling list (7.3.2.1.1.1) into `out`, in raster order; whether
/// the default one is to be used instead.
fn scalingList(b: *Bits, out: []u8, comptime n: usize, scan: *const [n]u8) Error!bool {
    var last: i32 = 8;
    var next: i32 = 8;
    for (0..n) |j| {
        if (next != 0) {
            const delta = try b.seRange(-128, 127);
            next = @mod(last + delta + 256, 256);
            if (j == 0 and next == 0) return true;
        }
        const value: i32 = if (next == 0) last else next;
        out[scan[j]] = @intCast(value);
        last = value;
    }
    return false;
}

/// The scaling lists of an SPS or a PPS (7.4.2.1.1, 7.4.2.2), with table
/// 7-2's fall-back: rule A from the defaults, rule B from `fallback` (the
/// sequence's lists, for a picture's when the sequence had its own).
fn scalingLists(b: *Bits, out: *Scaling, lists8: u32, fallback: ?*const Scaling) Error!void {
    for (0..6) |i| {
        if (b.flag()) {
            if (try scalingList(b, &out.m4[i], 16, &zigzag4)) out.m4[i] = tables.default_scaling4[if (i < 3) 0 else 1];
        } else if (i == 0 or i == 3) {
            out.m4[i] = if (fallback) |f| f.m4[i] else tables.default_scaling4[if (i < 3) 0 else 1];
        } else out.m4[i] = out.m4[i - 1];
    }
    for (0..6) |i| {
        if (i < lists8 and b.flag()) {
            if (try scalingList(b, &out.m8[i], 64, &zigzag8)) out.m8[i] = tables.default_scaling8[i & 1];
        } else if (i < 2) {
            out.m8[i] = if (fallback) |f| f.m8[i] else tables.default_scaling8[i & 1];
        } else out.m8[i] = out.m8[i - 2];
    }
}

fn hasHighFields(profile: u8) bool {
    return switch (profile) {
        100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135 => true,
        else => false,
    };
}

/// An SPS's RBSP (after its NAL header) into `s`; its id.
pub fn parseSps(b: *Bits, s: *Sps, limits: Limits) Error!u8 {
    s.* = .{};
    s.profile_idc = @intCast(b.u(8));
    s.constraint_flags = @intCast(b.u(8));
    s.level_idc = @intCast(b.u(8));
    const id = try b.ueMax(31);
    if (hasHighFields(s.profile_idc)) {
        s.chroma_format_idc = @intCast(try b.ueMax(3));
        if (s.chroma_format_idc == 3) s.separate_colour_plane = b.flag();
        s.bit_depth_luma = @intCast(8 + try b.ueMax(6));
        s.bit_depth_chroma = @intCast(8 + try b.ueMax(6));
        s.transform_bypass = b.flag();
        s.scaling_present = b.flag();
        if (s.scaling_present) try scalingLists(b, &s.scaling, if (s.chroma_format_idc == 3) 6 else 2, null);
    }
    s.log2_max_frame_num = @intCast(4 + try b.ueMax(12));
    s.poc_type = @intCast(try b.ueMax(2));
    if (s.poc_type == 0) {
        s.log2_max_poc_lsb = @intCast(4 + try b.ueMax(12));
    } else if (s.poc_type == 1) {
        s.delta_pic_order_always_zero = b.flag();
        s.offset_for_non_ref_pic = try b.se();
        s.offset_for_top_to_bottom_field = try b.se();
        s.num_ref_frames_in_poc_cycle = @intCast(try b.ueMax(255));
        for (0..s.num_ref_frames_in_poc_cycle) |i| s.offset_for_ref_frame[i] = try b.se();
    }
    s.max_num_ref_frames = @intCast(try b.ueMax(16));
    s.gaps_allowed = b.flag();
    s.width_mbs = try b.ueMax(limits.max_width_mbs - 1) + 1;
    s.height_map_units = try b.ueMax(limits.max_height_mbs - 1) + 1;
    s.frame_mbs_only = b.flag();
    if (!s.frame_mbs_only) {
        s.mbaff = b.flag();
        if (s.height_map_units * 2 > limits.max_height_mbs) return error.Unsupported;
    }
    s.direct_8x8_inference = b.flag();
    if (b.flag()) {
        s.crop_left = try b.ue();
        s.crop_right = try b.ue();
        s.crop_top = try b.ue();
        s.crop_bottom = try b.ue();
        const unit_x: u64 = if (s.chromaArrayType() == 0) 1 else s.subWidthC();
        const unit_y: u64 = (if (s.chromaArrayType() == 0) 1 else s.subHeightC()) * @as(u64, if (s.frame_mbs_only) 1 else 2);
        if ((@as(u64, s.crop_left) + s.crop_right) * unit_x >= @as(u64, s.width_mbs) * 16 or
            (@as(u64, s.crop_top) + s.crop_bottom) * unit_y >= @as(u64, s.heightMbs()) * 16)
        {
            s.crop_left = 0;
            s.crop_right = 0;
            s.crop_top = 0;
            s.crop_bottom = 0;
        }
    }
    if (b.flag()) try parseVui(b, s);
    if (b.overrun()) return error.Corrupt;
    s.valid = true;
    return @intCast(id);
}

fn skipHrd(b: *Bits) Error!void {
    const count = try b.ueMax(31) + 1;
    b.skip(8); // bit_rate_scale, cpb_size_scale
    for (0..count) |_| {
        _ = try b.ue();
        _ = try b.ue();
        b.skip(1);
    }
    b.skip(20); // the four lengths of five bits
}

fn parseVui(b: *Bits, s: *Sps) Error!void {
    if (b.flag()) { // aspect_ratio_info_present_flag
        if (b.u(8) == 255) b.skip(32);
    }
    if (b.flag()) b.skip(1); // overscan
    if (b.flag()) { // video_signal_type_present_flag
        b.skip(3);
        s.full_range = b.flag();
        if (b.flag()) {
            s.colour_primaries = @intCast(b.u(8));
            s.transfer = @intCast(b.u(8));
            s.matrix = @intCast(b.u(8));
        }
    }
    if (b.flag()) { // chroma_loc_info_present_flag
        _ = try b.ue();
        _ = try b.ue();
    }
    s.timing = b.flag();
    if (s.timing) {
        s.num_units_in_tick = b.u(32);
        s.time_scale = b.u(32);
        b.skip(1);
    }
    const nal_hrd = b.flag();
    if (nal_hrd) try skipHrd(b);
    const vcl_hrd = b.flag();
    if (vcl_hrd) try skipHrd(b);
    if (nal_hrd or vcl_hrd) b.skip(1);
    b.skip(1); // pic_struct_present_flag
    // A VUI cut short (as some encoders write) leaves the rest out.
    if (b.bitsLeft() <= 0) return;
    s.restriction = b.flag();
    if (s.restriction) {
        b.skip(1);
        _ = try b.ue();
        _ = try b.ue();
        _ = try b.ue();
        _ = try b.ue();
        s.num_reorder_frames = try b.ue();
        s.max_dec_frame_buffering = try b.ue();
        if (b.overrun() or s.num_reorder_frames > 16 or s.max_dec_frame_buffering > 16) {
            s.restriction = false;
            s.num_reorder_frames = 0;
            s.max_dec_frame_buffering = 0;
        }
    }
}

/// The id of the PPS in an RBSP, and the id of its SPS.
pub fn ppsIds(b: *Bits) Error!struct { pps: u8, sps: u8 } {
    const pps = try b.ueMax(255);
    const sps = try b.ueMax(31);
    return .{ .pps = @intCast(pps), .sps = @intCast(sps) };
}

/// A PPS's RBSP into `p`, with what its SPS says. `group_ids` is memory
/// for a slice group map of type 6, at least the picture's map units.
pub fn parsePps(b: *Bits, p: *Pps, sps: *const Sps, group_ids: []u8) Error!void {
    p.* = .{};
    const ids = try ppsIds(b);
    p.sps_id = ids.sps;
    p.cabac = b.flag();
    p.bottom_field_poc_present = b.flag();
    p.num_slice_groups = @intCast(try b.ueMax(7) + 1);
    if (p.num_slice_groups > 1) {
        p.slice_group_map_type = @intCast(try b.ueMax(6));
        const map_units = sps.width_mbs * sps.height_map_units;
        switch (p.slice_group_map_type) {
            0 => for (0..p.num_slice_groups) |g| {
                p.run_length[g] = try b.ueMax(map_units - 1) + 1;
            },
            2 => for (0..p.num_slice_groups - 1) |g| {
                p.top_left[g] = try b.ueMax(map_units - 1);
                p.bottom_right[g] = try b.ueMax(map_units - 1);
                if (p.top_left[g] > p.bottom_right[g] or p.top_left[g] % sps.width_mbs > p.bottom_right[g] % sps.width_mbs) return error.Corrupt;
            },
            3, 4, 5 => {
                p.change_direction = b.flag();
                p.change_rate = try b.ueMax(map_units - 1) + 1;
            },
            6 => {
                const count = try b.ue() + 1;
                if (count != map_units or count > group_ids.len) return error.Corrupt;
                var width: u6 = 0;
                while ((@as(u32, 1) << @intCast(width)) < p.num_slice_groups) width += 1;
                for (0..count) |i| {
                    const g = b.u(width);
                    if (g >= p.num_slice_groups) return error.Corrupt;
                    group_ids[i] = @intCast(g);
                }
                p.group_ids = group_ids[0..count];
            },
            else => {},
        }
    }
    p.num_ref_idx_default[0] = @intCast(try b.ueMax(31) + 1);
    p.num_ref_idx_default[1] = @intCast(try b.ueMax(31) + 1);
    p.weighted_pred = b.flag();
    p.weighted_bipred_idc = @intCast(b.u(2));
    if (p.weighted_bipred_idc == 3) return error.Corrupt;
    const qp_offset: i32 = 6 * (@as(i32, sps.bit_depth_luma) - 8);
    p.init_qp = 26 + try b.seRange(-26 - qp_offset, 25);
    p.init_qs = 26 + try b.seRange(-26, 25);
    p.chroma_qp_offset[0] = try b.seRange(-12, 12);
    p.chroma_qp_offset[1] = p.chroma_qp_offset[0];
    p.deblocking_control = b.flag();
    p.constrained_intra_pred = b.flag();
    p.redundant_pic_cnt_present = b.flag();
    p.scaling = sps.scaling;
    if (b.moreRbspData()) {
        p.transform_8x8 = b.flag();
        if (b.flag()) {
            const lists8: u32 = if (p.transform_8x8) (if (sps.chroma_format_idc == 3) 6 else 2) else 0;
            try scalingLists(b, &p.scaling, lists8, if (sps.scaling_present) &sps.scaling else null);
        }
        p.chroma_qp_offset[1] = try b.seRange(-12, 12);
    }
    if (b.overrun()) return error.Corrupt;
    p.valid = true;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "a sequence parameter set: a 176 x 144 Baseline one, cropped to 176 x 136" {
    // profile 66, level 30, id 0, log2_max_frame_num 4, poc type 2,
    // 1 ref frame, 11 x 9 MBs, frame MBs only, direct 8x8, cropping
    // bottom 4, no VUI. Written bit by bit below.
    const fields = "1" ++ // sps id 0
        "1" ++ // log2_max_frame_num_minus4 0
        "011" ++ // poc type 2
        "010" ++ // max_num_ref_frames 1
        "0" ++ // gaps
        "0001011" ++ // width_mbs_minus1 10
        "0001001" ++ // height_minus1 8
        "1" ++ "1" ++ // frame_mbs_only, direct_8x8
        "1" ++ "1" ++ "1" ++ "1" ++ "00101" ++ // crop 0 0 0 4
        "0" ++ "1"; // no VUI, stop bit
    var data: [16]u8 = @splat(0);
    data[0] = 66;
    data[1] = 0;
    data[2] = 30;
    var pos: usize = 24;
    for (fields) |c| {
        if (c == '1') data[pos >> 3] |= @as(u8, 0x80) >> @intCast(pos & 7);
        pos += 1;
    }
    var b = Bits.init(data[0 .. (pos + 7) / 8]);
    var s: Sps = .{};
    try testing.expectEqual(@as(u8, 0), try parseSps(&b, &s, .{}));
    try testing.expectEqual(@as(u32, 11), s.width_mbs);
    try testing.expectEqual(@as(u32, 9), s.heightMbs());
    try testing.expectEqual(@as(u2, 2), s.poc_type);
    try testing.expectEqual(@as(u32, 176), s.croppedWidth());
    try testing.expectEqual(@as(u32, 136), s.croppedHeight());
}
