// SPDX-License-Identifier: MIT
//! The slice header (7.3.3): what picture a slice belongs to, its kind,
//! how its reference lists are made, its weights, how the references are
//! marked after it, its quantiser and how it is filtered.

const bits_mod = @import("h264sets").bits;
const Bits = bits_mod.Bits;
const Error = bits_mod.Error;
const params = @import("h264sets").params;
const nal = @import("h264sets").nal;

const h264 = @import("sdk").videoparse.h264;
pub const Kind = h264.H264SliceKind;
pub const ListOp = h264.H264ListOp;
pub const Mmco = h264.H264Mmco;
pub const Weights = h264.H264Weights;
pub const Header = h264.H264SliceHeader;

/// The PPS id of a slice header, read ahead, so its parameter sets can be
/// found before the rest is read.
pub fn peekPpsId(data: []const u8) Error!u8 {
    var b = Bits.init(data);
    _ = try b.ue();
    _ = try b.ueMax(9);
    return @intCast(try b.ueMax(255));
}

fn ceilLog2(v: u32) u6 {
    var n: u6 = 0;
    while ((@as(u64, 1) << n) < v) n += 1;
    return n;
}

/// The header of a slice whose NAL unit is `unit` (type and nal_ref_idc)
/// from its RBSP, with the parameter sets it names.
pub fn parse(b: *Bits, h: *Header, unit: nal.Header, sps: *const params.Sps, pps: *const params.Pps) Error!void {
    h.* = .{};
    h.nal_kind = unit.kind;
    h.nal_ref_idc = unit.ref_idc;
    h.idr = unit.kind == nal.Type.idr;
    h.first_mb = try b.ue();
    const st = try b.ueMax(9);
    h.kind = @enumFromInt(st % 5);
    h.all_same = st >= 5;
    h.pps_id = @intCast(try b.ueMax(255));
    if (sps.separate_colour_plane) h.colour_plane = @intCast(b.u(2));
    if (h.colour_plane == 3) return error.Corrupt;
    h.frame_num = b.u(@intCast(sps.log2_max_frame_num));
    if (!sps.frame_mbs_only) {
        h.field_pic = b.flag();
        if (h.field_pic) h.bottom_field = b.flag();
    }
    const mbs = sps.width_mbs * sps.heightMbs();
    if (h.first_mb * @as(u32, if (h.mbaff(sps)) 2 else 1) >= (if (h.field_pic) mbs / 2 else mbs)) return error.Corrupt;
    if (h.idr) {
        if (h.kind != .i and h.kind != .si) return error.Corrupt;
        h.idr_pic_id = try b.ueMax(65535);
    }
    if (sps.poc_type == 0) {
        h.poc_lsb = b.u(@intCast(sps.log2_max_poc_lsb));
        if (pps.bottom_field_poc_present and !h.field_pic) h.delta_poc_bottom = try b.se();
    } else if (sps.poc_type == 1 and !sps.delta_pic_order_always_zero) {
        h.delta_poc[0] = try b.se();
        if (pps.bottom_field_poc_present and !h.field_pic) h.delta_poc[1] = try b.se();
    }
    if (pps.redundant_pic_cnt_present) h.redundant_pic_cnt = try b.ueMax(127);
    if (h.kind == .b) h.direct_spatial = b.flag();
    if (h.kind == .p or h.kind == .sp or h.kind == .b) {
        h.num_ref_idx = pps.num_ref_idx_default;
        if (b.flag()) {
            const most: u32 = if (h.field_pic) 31 else 15;
            h.num_ref_idx[0] = @intCast(try b.ueMax(most) + 1);
            if (h.kind == .b) h.num_ref_idx[1] = @intCast(try b.ueMax(most) + 1);
        } else if (!h.field_pic and (h.num_ref_idx[0] > 16 or h.num_ref_idx[1] > 16)) return error.Corrupt;
        if (h.kind != .b) h.num_ref_idx[1] = 0;
    }
    if (unit.kind == nal.Type.ext_slice) return error.Unsupported;
    // ref_pic_list_modification
    const lists: u32 = if (h.kind == .b) 2 else if (h.kind == .i or h.kind == .si) 0 else 1;
    for (0..lists) |l| {
        if (!b.flag()) continue;
        while (true) {
            const idc = try b.ueMax(5);
            if (idc == 3) break;
            if (idc > 2) return error.Unsupported; // the MVC view ops
            if (h.list_op_count[l] >= 33) return error.Corrupt;
            const value = try b.ue();
            h.list_ops[l][h.list_op_count[l]] = .{ .idc = @intCast(idc), .value = value };
            h.list_op_count[l] += 1;
        }
    }
    if ((pps.weighted_pred and (h.kind == .p or h.kind == .sp)) or (pps.weighted_bipred_idc == 1 and h.kind == .b)) {
        h.weighted = true;
        try parseWeights(b, h, sps);
    }
    if (unit.ref_idc != 0) {
        if (h.idr) {
            h.no_output_of_prior_pics = b.flag();
            h.long_term_reference = b.flag();
        } else {
            h.adaptive_marking = b.flag();
            if (h.adaptive_marking) {
                while (true) {
                    const op = try b.ueMax(6);
                    if (op == 0) break;
                    if (h.mmco_count >= h.mmco.len) return error.Corrupt;
                    var m: Mmco = .{ .op = @intCast(op) };
                    if (op == 1 or op == 3) m.a = try b.ue();
                    if (op == 2) m.a = try b.ue();
                    if (op == 3 or op == 6) m.b = try b.ueMax(31);
                    if (op == 4) m.a = try b.ueMax(16);
                    h.mmco[h.mmco_count] = m;
                    h.mmco_count += 1;
                }
            }
        }
    }
    if (pps.cabac and h.kind != .i and h.kind != .si) h.cabac_init_idc = @intCast(try b.ueMax(2));
    const qp_offset: i32 = 6 * (@as(i32, sps.bit_depth_luma) - 8);
    h.qp = pps.init_qp + try b.se();
    if (h.qp < -qp_offset or h.qp > 51) return error.Corrupt;
    if (h.kind == .sp or h.kind == .si) {
        if (h.kind == .sp) h.sp_for_switch = b.flag();
        h.qs = pps.init_qs + try b.se();
        if (h.qs < 0 or h.qs > 51) return error.Corrupt;
    }
    if (pps.deblocking_control) {
        h.disable_deblocking = @intCast(try b.ueMax(2));
        if (h.disable_deblocking != 1) {
            h.alpha_offset = @intCast(2 * try b.seRange(-6, 6));
            h.beta_offset = @intCast(2 * try b.seRange(-6, 6));
        }
    }
    if (pps.num_slice_groups > 1 and pps.slice_group_map_type >= 3 and pps.slice_group_map_type <= 5) {
        // Ceil(Log2(PicSizeInMapUnits ÷ SliceGroupChangeRate + 1)), the
        // division exact: the quotient rounded up.
        const units = sps.width_mbs * sps.height_map_units;
        const n = ceilLog2((units + pps.change_rate - 1) / pps.change_rate + 1);
        h.slice_group_change_cycle = b.u(n);
    }
    if (b.overrun()) return error.Corrupt;
}

fn parseWeights(b: *Bits, h: *Header, sps: *const params.Sps) Error!void {
    const luma_denom: u8 = @intCast(try b.ueMax(7));
    var chroma_denom: u8 = 0;
    if (sps.chromaArrayType() != 0) chroma_denom = @intCast(try b.ueMax(7));
    const lists: u32 = if (h.kind == .b) 2 else 1;
    for (0..lists) |l| {
        const w = &h.weights[l];
        w.luma_denom = luma_denom;
        w.chroma_denom = chroma_denom;
        for (0..h.num_ref_idx[l]) |i| {
            w.luma[i] = .{ @as(i16, 1) << @intCast(luma_denom), 0 };
            w.chroma[i] = @splat(.{ @as(i16, 1) << @intCast(chroma_denom), 0 });
            if (b.flag()) {
                w.luma_flag[i] = true;
                w.luma[i] = .{ @intCast(try b.seRange(-128, 127)), @intCast(try b.seRange(-128, 127)) };
            }
            if (sps.chromaArrayType() != 0 and b.flag()) {
                w.chroma_flag[i] = true;
                for (0..2) |c| w.chroma[i][c] = .{ @intCast(try b.seRange(-128, 127)), @intCast(try b.seRange(-128, 127)) };
            }
        }
    }
}
