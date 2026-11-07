// SPDX-License-Identifier: MIT
//! HEVC's slice segment header (7.3.6) read into the SDK's structure
//! (`sdk.videoparse.hevc`): what a slice says of itself, its picture's
//! reference picture set, its lists and their weights.

const sdk = @import("sdk");
const syntax = sdk.videoparse.hevc;
const bits_mod = @import("bits.zig");
const Bits = bits_mod.Bits;
const Error = bits_mod.Error;
const params = @import("params.zig");
const nal = @import("nal.zig");

pub const SliceType = syntax.HevcSliceType;
pub const Weights = syntax.HevcWeights;
pub const Header = syntax.HevcSliceHeader;
pub const max_refs = syntax.max_refs;

/// Ceil( Log2( n ) ): the bits of a field that counts to n - 1.
pub fn ceilLog2(n: u32) u5 {
    if (n <= 1) return 0;
    return @intCast(32 - @clz(n - 1));
}

/// The ids at the start of a slice segment header: whether it is its
/// picture's first, and its PPS.
pub fn peekPps(b: *Bits, unit: nal.Header) Error!struct { first: bool, pps: u8 } {
    const first = b.flag();
    if (unit.isIrap()) b.skip(1);
    return .{ .first = first, .pps = @intCast(try b.ueMax(63)) };
}

/// A slice segment header (7.3.6.1) into `h`. A dependent segment takes
/// everything but its address from `prev`, its slice's independent one.
pub fn parse(b: *Bits, h: *Header, unit: nal.Header, sps: *const params.Sps, pps: *const params.Pps, prev: *const Header) Error!void {
    const first = b.flag();
    var no_output = false;
    if (unit.isIrap()) no_output = b.flag();
    const pps_id: u8 = @intCast(try b.ueMax(63));
    var dependent = false;
    var address: u32 = 0;
    const ctbs = sps.widthCtbs() * sps.heightCtbs();
    if (!first) {
        if (pps.dependent_slice_segments) dependent = b.flag();
        address = b.u(ceilLog2(ctbs));
        if (address >= ctbs) return error.Corrupt;
    }
    if (dependent) {
        h.* = prev.*;
    } else {
        h.* = .{};
        h.slice_addr = address;
    }
    h.first_slice_in_pic = first;
    h.no_output_of_prior_pics = no_output;
    h.pps_id = pps_id;
    h.dependent = dependent;
    h.segment_address = address;
    if (!dependent) try independent(b, h, unit, sps, pps);
    if (pps.tiles or pps.entropy_coding_sync) {
        h.num_entry_points = try b.ueMax(ctbs);
        if (h.num_entry_points > 0) {
            const len: u6 = @intCast(try b.ueMax(31) + 1);
            for (0..h.num_entry_points) |_| b.skip(len);
        }
    } else h.num_entry_points = 0;
    if (pps.slice_header_extension_present) {
        const n = try b.ueMax(256);
        b.skip(8 * n);
    }
    // byte_alignment( ): a one, then zeros.
    if (!b.flag()) return error.Corrupt;
    b.alignByte();
    if (b.overrun()) return error.Corrupt;
    h.data_offset = @intCast(b.pos >> 3);
}

fn independent(b: *Bits, h: *Header, unit: nal.Header, sps: *const params.Sps, pps: *const params.Pps) Error!void {
    b.skip(pps.num_extra_slice_header_bits);
    const kind = try b.ueMax(2);
    h.slice_type = @enumFromInt(kind);
    if (pps.output_flag_present) h.pic_output = b.flag();
    if (!unit.isIdr()) {
        h.poc_lsb = b.u(@intCast(sps.log2_max_poc_lsb));
        h.st_rps_sps = b.flag();
        if (!h.st_rps_sps) {
            // The header's own set, which may be predicted from the SPS's:
            // made in a copy of them, as their last.
            var sets: [65]params.StRps = undefined;
            @memcpy(sets[0..sps.num_st_rps], sps.st_rps[0..sps.num_st_rps]);
            const start = b.pos;
            try params.stRefPicSet(b, &sets, sps.num_st_rps, sps.num_st_rps);
            h.st_rps = sets[sps.num_st_rps];
            h.st_rps_bits = @intCast(b.pos - start);
        } else {
            if (sps.num_st_rps == 0) return error.Corrupt;
            if (sps.num_st_rps > 1) h.st_rps_idx = @intCast(b.u(ceilLog2(sps.num_st_rps)));
            if (h.st_rps_idx >= sps.num_st_rps) return error.Corrupt;
        }
        if (sps.long_term_present) {
            var num_sps: u32 = 0;
            if (sps.num_lt_sps > 0) num_sps = try b.ueMax(sps.num_lt_sps);
            const num_pics = try b.ueMax(32 - num_sps);
            h.num_lt = @intCast(num_sps + num_pics);
            for (0..h.num_lt) |i| {
                if (i < num_sps) {
                    var idx: u32 = 0;
                    if (sps.num_lt_sps > 1) idx = b.u(ceilLog2(sps.num_lt_sps));
                    if (idx >= sps.num_lt_sps) return error.Corrupt;
                    h.lt_poc_lsb[i] = sps.lt_poc_lsb_sps[idx];
                    if (sps.lt_used_sps >> @intCast(idx) & 1 != 0) h.lt_used |= @as(u32, 1) << @intCast(i);
                } else {
                    h.lt_poc_lsb[i] = b.u(@intCast(sps.log2_max_poc_lsb));
                    if (b.flag()) h.lt_used |= @as(u32, 1) << @intCast(i);
                }
                var cycle: u32 = 0;
                if (b.flag()) {
                    h.lt_msb_present |= @as(u32, 1) << @intCast(i);
                    cycle = try b.ueMax(1 << 24);
                }
                // DeltaPocMsbCycleLt (7-52): summed within each group.
                if (i != 0 and i != num_sps) cycle += h.lt_msb_cycle[i - 1];
                h.lt_msb_cycle[i] = cycle;
            }
        }
        if (sps.temporal_mvp) h.temporal_mvp = b.flag();
    }
    if (sps.sao) {
        h.sao_luma = b.flag();
        if (sps.chromaArrayType() != 0) h.sao_chroma = b.flag();
    }
    if (h.slice_type != .i) {
        h.num_ref_idx = pps.num_ref_idx_default;
        if (b.flag()) {
            h.num_ref_idx[0] = @intCast(try b.ueMax(14) + 1);
            if (h.slice_type == .b) h.num_ref_idx[1] = @intCast(try b.ueMax(14) + 1);
        }
        if (h.slice_type != .b) h.num_ref_idx[1] = 0;
        const total = h.numPicTotalCurr(sps);
        if (total == 0) return error.Corrupt;
        if (pps.lists_modification_present and total > 1) {
            const len = ceilLog2(total);
            for (0..@as(usize, if (h.slice_type == .b) 2 else 1)) |l| {
                h.list_modified[l] = b.flag();
                if (h.list_modified[l]) {
                    for (0..h.num_ref_idx[l]) |i| {
                        const e = b.u(len);
                        if (e >= total) return error.Corrupt;
                        h.list_entry[l][i] = @intCast(e);
                    }
                }
            }
        }
        if (h.slice_type == .b) h.mvd_l1_zero = b.flag();
        if (pps.cabac_init_present) h.cabac_init = b.flag();
        if (h.temporal_mvp) {
            if (h.slice_type == .b) h.collocated_from_l0 = b.flag();
            const l: usize = if (h.collocated_from_l0) 0 else 1;
            if (h.num_ref_idx[l] > 1) h.collocated_ref_idx = @intCast(try b.ueMax(h.num_ref_idx[l] - 1));
        }
        if ((pps.weighted_pred and h.slice_type == .p) or (pps.weighted_bipred and h.slice_type == .b)) {
            h.weighted = true;
            try predWeightTable(b, h, sps);
        }
        h.max_num_merge_cand = @intCast(5 - try b.ueMax(4));
    }
    const qp = pps.init_qp + try b.se();
    const qp_bd_offset: i32 = 6 * @as(i32, sps.bit_depth_luma - 8);
    if (qp < -qp_bd_offset or qp > 51) return error.Corrupt;
    h.qp = qp;
    if (pps.slice_chroma_qp_offsets_present) {
        h.cb_qp_offset = @intCast(try b.seRange(-12, 12));
        h.cr_qp_offset = @intCast(try b.seRange(-12, 12));
        if (pps.cb_qp_offset + h.cb_qp_offset < -12 or pps.cb_qp_offset + h.cb_qp_offset > 12) return error.Corrupt;
        if (pps.cr_qp_offset + h.cr_qp_offset < -12 or pps.cr_qp_offset + h.cr_qp_offset > 12) return error.Corrupt;
    }
    if (pps.chroma_qp_offset_list_enabled) h.cu_chroma_qp_offset = b.flag();
    var override = false;
    if (pps.deblocking_override_enabled) override = b.flag();
    h.deblocking_disabled = pps.deblocking_disabled;
    h.beta_offset = pps.beta_offset;
    h.tc_offset = pps.tc_offset;
    if (override) {
        h.deblocking_disabled = b.flag();
        if (!h.deblocking_disabled) {
            h.beta_offset = @intCast(2 * try b.seRange(-6, 6));
            h.tc_offset = @intCast(2 * try b.seRange(-6, 6));
        }
    }
    h.loop_filter_across_slices = pps.loop_filter_across_slices;
    if (pps.loop_filter_across_slices and (h.sao_luma or h.sao_chroma or !h.deblocking_disabled))
        h.loop_filter_across_slices = b.flag();
}

/// pred_weight_table( ) (7.3.6.3). Every entry of the lists is another
/// picture than the current one: a flag for each.
fn predWeightTable(b: *Bits, h: *Header, sps: *const params.Sps) Error!void {
    const w = &h.weights;
    w.* = .{};
    const chroma = sps.chromaArrayType() != 0;
    w.luma_log2_denom = @intCast(try b.ueMax(7));
    var denom_c: i32 = w.luma_log2_denom;
    if (chroma) denom_c += try b.seRange(-7, 7);
    if (denom_c < 0 or denom_c > 7) return error.Corrupt;
    w.chroma_log2_denom = @intCast(denom_c);
    const half_y: i32 = @as(i32, 1) << @intCast(if (sps.high_precision_offsets) sps.bit_depth_luma - 1 else 7);
    const half_c: i32 = @as(i32, 1) << @intCast(if (sps.high_precision_offsets) sps.bit_depth_chroma - 1 else 7);
    for (0..@as(usize, if (h.slice_type == .b) 2 else 1)) |l| {
        const n = h.num_ref_idx[l];
        var luma_flags: u32 = 0;
        var chroma_flags: u32 = 0;
        for (0..n) |i| {
            if (b.flag()) luma_flags |= @as(u32, 1) << @intCast(i);
        }
        if (chroma) for (0..n) |i| {
            if (b.flag()) chroma_flags |= @as(u32, 1) << @intCast(i);
        };
        for (0..n) |i| {
            w.luma_weight[l][i] = @as(i16, 1) << @intCast(w.luma_log2_denom);
            if (luma_flags >> @intCast(i) & 1 != 0) {
                w.luma_weight[l][i] += @intCast(try b.seRange(-128, 127));
                w.luma_offset[l][i] = @intCast(try b.seRange(-half_y, half_y - 1));
            }
            for (0..2) |j| {
                w.chroma_weight[l][i][j] = @as(i16, 1) << @intCast(w.chroma_log2_denom);
                if (chroma_flags >> @intCast(i) & 1 != 0) {
                    w.chroma_weight[l][i][j] += @intCast(try b.seRange(-128, 127));
                    const delta = try b.seRange(-4 * half_c, 4 * half_c - 1);
                    const o = half_c + delta - ((half_c * w.chroma_weight[l][i][j]) >> @intCast(w.chroma_log2_denom));
                    w.chroma_offset[l][i][j] = @intCast(@max(-half_c, @min(half_c - 1, o)));
                }
            }
        }
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "field lengths" {
    try testing.expectEqual(@as(u5, 0), ceilLog2(1));
    try testing.expectEqual(@as(u5, 1), ceilLog2(2));
    try testing.expectEqual(@as(u5, 2), ceilLog2(3));
    try testing.expectEqual(@as(u5, 2), ceilLog2(4));
    try testing.expectEqual(@as(u5, 9), ceilLog2(510));
}
