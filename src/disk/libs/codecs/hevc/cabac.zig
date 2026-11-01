// SPDX-License-Identifier: MIT
//! CABAC (9.3): the arithmetic decoding engine, and the contexts - where
//! each syntax element's are, and their initialisation from a slice's
//! QP (9.3.2.2).
//!
//! A context is a byte: its probability state times two, plus the value
//! of its most probable symbol. The engine keeps ivlCurrRange as the
//! standard does, and ivlOffset together with the bits after it in one
//! 64-bit `value` - ivlOffset times 2^cnt plus the next cnt bits - so
//! that a renormalisation only counts `cnt` down and a refill takes
//! several bytes at once.

/// rangeTabLps (Table 9-52), by pStateIdx and qRangeIdx.
const range_lps: [64][4]u8 = .{
    .{ 128, 176, 208, 240 }, .{ 128, 167, 197, 227 }, .{ 128, 158, 187, 216 }, .{ 123, 150, 178, 205 },
    .{ 116, 142, 169, 195 }, .{ 111, 135, 160, 185 }, .{ 105, 128, 152, 175 }, .{ 100, 122, 144, 166 },
    .{ 95, 116, 137, 158 },  .{ 90, 110, 130, 150 },  .{ 85, 104, 123, 142 },  .{ 81, 99, 117, 135 },
    .{ 77, 94, 111, 128 },   .{ 73, 89, 105, 122 },   .{ 69, 85, 100, 116 },   .{ 66, 80, 95, 110 },
    .{ 62, 76, 90, 104 },    .{ 59, 72, 86, 99 },     .{ 56, 69, 81, 94 },     .{ 53, 65, 77, 89 },
    .{ 51, 62, 73, 85 },     .{ 48, 59, 69, 80 },     .{ 46, 56, 66, 76 },     .{ 43, 53, 63, 72 },
    .{ 41, 50, 59, 69 },     .{ 39, 48, 56, 65 },     .{ 37, 45, 54, 62 },     .{ 35, 43, 51, 59 },
    .{ 33, 41, 48, 56 },     .{ 32, 39, 46, 53 },     .{ 30, 37, 43, 50 },     .{ 29, 35, 41, 48 },
    .{ 27, 33, 39, 45 },     .{ 26, 31, 37, 43 },     .{ 24, 30, 35, 41 },     .{ 23, 28, 33, 39 },
    .{ 22, 27, 32, 37 },     .{ 21, 26, 30, 35 },     .{ 20, 24, 29, 33 },     .{ 19, 23, 27, 31 },
    .{ 18, 22, 26, 30 },     .{ 17, 21, 25, 28 },     .{ 16, 20, 23, 27 },     .{ 15, 19, 22, 25 },
    .{ 14, 18, 21, 24 },     .{ 14, 17, 20, 23 },     .{ 13, 16, 19, 22 },     .{ 12, 15, 18, 21 },
    .{ 12, 14, 17, 20 },     .{ 11, 14, 16, 19 },     .{ 11, 13, 15, 18 },     .{ 10, 12, 15, 17 },
    .{ 10, 12, 14, 16 },     .{ 9, 11, 13, 15 },      .{ 9, 11, 12, 14 },      .{ 8, 10, 12, 14 },
    .{ 8, 9, 11, 13 },       .{ 7, 9, 11, 12 },       .{ 7, 9, 10, 12 },       .{ 7, 8, 10, 11 },
    .{ 6, 8, 9, 11 },        .{ 6, 7, 9, 10 },        .{ 6, 7, 8, 9 },         .{ 2, 2, 2, 2 },
};

/// transIdxLps (Table 9-53).
const trans_lps: [64]u8 = .{
    0,  0,  1,  2,  2,  4,  4,  5,  6,  7,  8,  9,  9,  11, 11, 12,
    13, 13, 15, 15, 16, 16, 18, 18, 19, 19, 21, 21, 22, 22, 23, 24,
    24, 25, 26, 26, 27, 27, 28, 29, 29, 30, 30, 30, 31, 32, 32, 33,
    33, 33, 34, 34, 35, 35, 35, 36, 36, 36, 37, 37, 37, 38, 38, 63,
};

/// A context byte after its most probable symbol, and after its least.
const after_mps: [128]u8 = blk: {
    var t: [128]u8 = undefined;
    for (0..128) |c| {
        const up: usize = if ((c >> 1) + 1 > 62) 62 else (c >> 1) + 1;
        t[c] = @intCast((up << 1) | (c & 1));
    }
    break :blk t;
};
const after_lps: [128]u8 = blk: {
    var t: [128]u8 = undefined;
    for (0..128) |c| {
        const state = c >> 1;
        const mps = if (state == 0) (c & 1) ^ 1 else c & 1;
        t[c] = @intCast((trans_lps[state] << 1) | mps);
    }
    break :blk t;
};

pub const Engine = struct {
    data: []const u8,
    /// The next byte to load into `value`.
    next: usize = 0,
    /// ivlOffset * 2^cnt + the cnt bits after it.
    value: u64 = 0,
    cnt: u32 = 0,
    range: u32 = 510,

    /// The engine started on `data` from its byte `at` (9.3.2.6): false
    /// when ivlOffset comes out as 510 or 511, which the standard forbids.
    pub fn init(e: *Engine, data: []const u8, at: usize) bool {
        e.* = .{ .data = data, .next = at };
        e.refill();
        e.cnt -= 9;
        return (e.value >> @intCast(e.cnt)) < 510;
    }

    /// As many bytes as fit loaded: cnt from 48 to 55.
    fn refill(e: *Engine) void {
        while (e.cnt <= 47) {
            const byte: u64 = if (e.next < e.data.len) e.data[e.next] else 0;
            e.next += 1;
            e.value = (e.value << 8) | byte;
            e.cnt += 8;
        }
    }

    /// DecodeDecision (9.3.4.3.2) with the context `ctx`.
    pub inline fn decision(e: *Engine, ctx: *u8) u1 {
        if (e.cnt < 8) e.refill();
        const c = ctx.*;
        const lps: u32 = range_lps[c >> 1][(e.range >> 6) & 3];
        const rmps = e.range - lps;
        const scaled = @as(u64, rmps) << @intCast(e.cnt);
        if (e.value < scaled) {
            ctx.* = after_mps[c];
            e.range = rmps;
            if (rmps < 256) {
                e.range = rmps << 1;
                e.cnt -= 1;
            }
            return @intCast(c & 1);
        }
        e.value -= scaled;
        const n: u5 = @intCast(@clz(lps) - 23);
        e.range = lps << n;
        e.cnt -= n;
        ctx.* = after_lps[c];
        return @intCast((c & 1) ^ 1);
    }

    /// DecodeBypass (9.3.4.3.4).
    pub inline fn bypass(e: *Engine) u1 {
        if (e.cnt < 8) e.refill();
        e.cnt -= 1;
        const scaled = @as(u64, e.range) << @intCast(e.cnt);
        if (e.value >= scaled) {
            e.value -= scaled;
            return 1;
        }
        return 0;
    }

    /// `n` bypass bins (at most 32), the first the highest bit.
    pub fn bypassBits(e: *Engine, n: u32) u32 {
        var v: u32 = 0;
        for (0..n) |_| v = (v << 1) | e.bypass();
        return v;
    }

    /// DecodeTerminate (9.3.4.3.5).
    pub fn terminate(e: *Engine) u1 {
        if (e.cnt < 8) e.refill();
        e.range -= 2;
        const scaled = @as(u64, e.range) << @intCast(e.cnt);
        if (e.value >= scaled) return 1;
        if (e.range < 256) {
            e.range <<= 1;
            e.cnt -= 1;
        }
        return 0;
    }

    /// The alignment before aligned bypass bins (9.3.4.3.6).
    pub fn alignBypass(e: *Engine) void {
        e.range = 256;
    }

    /// The byte after the arithmetic code, once terminate gave 1: where
    /// the next substream or PCM samples start, after the alignment bits.
    pub fn bytePosition(e: *const Engine) usize {
        return (e.next * 8 - e.cnt + 7) / 8;
    }

    /// Whether the engine read past the end of its data.
    pub fn overrun(e: *const Engine) bool {
        return e.next > e.data.len + 8;
    }
};

// --- the contexts ------------------------------------------------------------

/// Where each syntax element's contexts start (Table 9-4), the same for
/// every initType.
pub const Ctx = struct {
    pub const sao_merge = 0;
    pub const sao_type = 1;
    pub const split_cu = 2;
    pub const transquant_bypass = 5;
    pub const cu_skip = 6;
    pub const pred_mode = 9;
    pub const part_mode = 10;
    pub const prev_intra_luma_pred = 14;
    pub const intra_chroma_pred_mode = 15;
    pub const rqt_root_cbf = 16;
    pub const merge_flag = 17;
    pub const merge_idx = 18;
    pub const inter_pred_idc = 19;
    pub const ref_idx = 24;
    pub const mvp_flag = 26;
    pub const split_transform = 27;
    pub const cbf_luma = 30;
    pub const cbf_chroma = 32;
    pub const mvd_greater0 = 37;
    pub const mvd_greater1 = 38;
    pub const cu_qp_delta_abs = 39;
    /// Luma's, then chroma's.
    pub const transform_skip = 41;
    pub const last_x_prefix = 43;
    pub const last_y_prefix = 61;
    pub const coded_sub_block = 79;
    /// 42 by position, then the transform-skip ones, luma's (42) and
    /// chroma's (43).
    pub const sig_coeff = 83;
    pub const greater1 = 127;
    pub const greater2 = 151;
    /// Luma's, then chroma's.
    pub const explicit_rdpcm = 157;
    pub const explicit_rdpcm_dir = 159;
    pub const log2_res_scale_abs = 161;
    pub const res_scale_sign = 169;
    pub const cu_chroma_qp_offset_flag = 171;
    pub const cu_chroma_qp_offset_idx = 172;
    pub const count = 173;
};

/// initValue of every context (Tables 9-5 to 9-37), by initType; 154
/// for the ones an initType does not use.
const init_values: [3][Ctx.count]u8 = .{
    .{
        153, // sao_merge
        200, // sao_type
        139, 141, 157, // split_cu
        154, // transquant_bypass
        154, 154, 154, // cu_skip
        154, // pred_mode
        184, 154, 154, 154, // part_mode
        184, // prev_intra_luma_pred
        63, // intra_chroma_pred_mode
        154, // rqt_root_cbf
        154, // merge_flag
        154, // merge_idx
        154, 154, 154, 154, 154, // inter_pred_idc
        154, 154, // ref_idx
        154, // mvp_flag
        153, 138, 138, // split_transform
        111, 141, // cbf_luma
        94, 138, 182, 154, 154, // cbf_chroma
        154, 154, // mvd_greater0, mvd_greater1
        154, 154, // cu_qp_delta_abs
        139, 139, // transform_skip
        110, 110, 124, 125, 140, 153, 125, 127, 140, 109, 111, 143, 127, 111, 79, 108, 123, 63, // last_x
        110, 110, 124, 125, 140, 153, 125, 127, 140, 109, 111, 143, 127, 111, 79, 108, 123, 63, // last_y
        91, 171, 134, 141, // coded_sub_block
        111, 111, 125, 110, 110, 94,  124, 108, 124, 107, 125, 141, 179, 153, 125, 107, // sig_coeff
        125, 141, 179, 153, 125, 107, 125, 141, 179, 153, 125, 140, 139, 182, 182, 152,
        136, 152, 136, 153, 136, 139, 111, 136, 139, 111, 141, 111,
        140, 92,  137, 138, 140, 152, 138, 139, 153, 74, 149, 92, 139, 107, 122, 152, // greater1
        140, 179, 166, 182, 140, 227, 122, 197,
        138, 153, 136, 167, 152, 152, // greater2
        154, 154, 154, 154, // explicit_rdpcm, explicit_rdpcm_dir
        154, 154, 154, 154, 154, 154, 154, 154, // log2_res_scale_abs
        154, 154, // res_scale_sign
        154, 154, // cu_chroma_qp_offset_flag, cu_chroma_qp_offset_idx
    },
    .{
        153, // sao_merge
        185, // sao_type
        107, 139, 126, // split_cu
        154, // transquant_bypass
        197, 185, 201, // cu_skip
        149, // pred_mode
        154, 139, 154, 154, // part_mode
        154, // prev_intra_luma_pred
        152, // intra_chroma_pred_mode
        79, // rqt_root_cbf
        110, // merge_flag
        122, // merge_idx
        95, 79, 63, 31, 31, // inter_pred_idc
        153, 153, // ref_idx
        168, // mvp_flag
        124, 138, 94, // split_transform
        153, 111, // cbf_luma
        149, 107, 167, 154, 154, // cbf_chroma
        140, 198, // mvd_greater0, mvd_greater1
        154, 154, // cu_qp_delta_abs
        139, 139, // transform_skip
        125, 110, 94, 110, 95, 79, 125, 111, 110, 78, 110, 111, 111, 95, 94, 108, 123, 108, // last_x
        125, 110, 94, 110, 95, 79, 125, 111, 110, 78, 110, 111, 111, 95, 94, 108, 123, 108, // last_y
        121, 140, 61, 154, // coded_sub_block
        155, 154, 139, 153, 139, 123, 123, 63,  153, 166, 183, 140, 136, 153, 154, 166, // sig_coeff
        183, 140, 136, 153, 154, 166, 183, 140, 136, 153, 154, 170, 153, 123, 123, 107,
        121, 107, 121, 167, 151, 183, 140, 151, 183, 140, 140, 140,
        154, 196, 196, 167, 154, 152, 167, 182, 182, 134, 149, 136, 153, 121, 136, 137, // greater1
        169, 194, 166, 167, 154, 167, 137, 182,
        107, 167, 91, 122, 107, 167, // greater2
        139, 139, 139, 139, // explicit_rdpcm, explicit_rdpcm_dir
        154, 154, 154, 154, 154, 154, 154, 154, // log2_res_scale_abs
        154, 154, // res_scale_sign
        154, 154, // cu_chroma_qp_offset_flag, cu_chroma_qp_offset_idx
    },
    .{
        153, // sao_merge
        160, // sao_type
        107, 139, 126, // split_cu
        154, // transquant_bypass
        197, 185, 201, // cu_skip
        134, // pred_mode
        154, 139, 154, 154, // part_mode
        183, // prev_intra_luma_pred
        152, // intra_chroma_pred_mode
        79, // rqt_root_cbf
        154, // merge_flag
        137, // merge_idx
        95, 79, 63, 31, 31, // inter_pred_idc
        153, 153, // ref_idx
        168, // mvp_flag
        224, 167, 122, // split_transform
        153, 111, // cbf_luma
        149, 92, 167, 154, 154, // cbf_chroma
        169, 198, // mvd_greater0, mvd_greater1
        154, 154, // cu_qp_delta_abs
        139, 139, // transform_skip
        125, 110, 124, 110, 95, 94, 125, 111, 111, 79, 125, 126, 111, 111, 79, 108, 123, 93, // last_x
        125, 110, 124, 110, 95, 94, 125, 111, 111, 79, 125, 126, 111, 111, 79, 108, 123, 93, // last_y
        121, 140, 61, 154, // coded_sub_block
        170, 154, 139, 153, 139, 123, 123, 63,  124, 166, 183, 140, 136, 153, 154, 166, // sig_coeff
        183, 140, 136, 153, 154, 166, 183, 140, 136, 153, 154, 170, 153, 138, 138, 122,
        121, 122, 121, 167, 151, 183, 140, 151, 183, 140, 140, 140,
        154, 196, 167, 167, 154, 152, 167, 182, 182, 134, 149, 136, 153, 121, 136, 122, // greater1
        169, 208, 166, 167, 154, 152, 167, 182,
        107, 167, 91, 107, 107, 167, // greater2
        139, 139, 139, 139, // explicit_rdpcm, explicit_rdpcm_dir
        154, 154, 154, 154, 154, 154, 154, 154, // log2_res_scale_abs
        154, 154, // res_scale_sign
        154, 154, // cu_chroma_qp_offset_flag, cu_chroma_qp_offset_idx
    },
};

pub const Contexts = [Ctx.count]u8;

/// The contexts initialised for a slice of `init_type` and SliceQpY
/// `qp` (9-4 to 9-6).
pub fn initContexts(ctx: *Contexts, init_type: u2, qp: i32) void {
    const q: i32 = @max(0, @min(51, qp));
    for (ctx, init_values[init_type]) |*c, v| {
        const m: i32 = @as(i32, v >> 4) * 5 - 45;
        const n: i32 = (@as(i32, v & 15) << 3) - 16;
        const pre = @max(1, @min(126, ((m * q) >> 4) + n));
        c.* = if (pre <= 63) @intCast((63 - pre) << 1) else @intCast(((pre - 64) << 1) | 1);
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

/// A CABAC encoder (9.3.5, informative) to check the decoder against.
const Encoder = struct {
    low: u32 = 0,
    range: u32 = 510,
    outstanding: u32 = 0,
    first: bool = true,
    out: [256]u8 = @splat(0),
    bits: usize = 0,

    fn put(enc: *Encoder, bit: u1) void {
        if (enc.first) {
            enc.first = false;
        } else {
            if (bit != 0) enc.out[enc.bits >> 3] |= @as(u8, 0x80) >> @intCast(enc.bits & 7);
            enc.bits += 1;
        }
        while (enc.outstanding > 0) : (enc.outstanding -= 1) {
            if (bit == 0) enc.out[enc.bits >> 3] |= @as(u8, 0x80) >> @intCast(enc.bits & 7);
            enc.bits += 1;
        }
    }
    fn renorm(enc: *Encoder) void {
        while (enc.range < 256) {
            if (enc.low < 256) {
                enc.put(0);
            } else if (enc.low >= 512) {
                enc.low -= 512;
                enc.put(1);
            } else {
                enc.low -= 256;
                enc.outstanding += 1;
            }
            enc.range <<= 1;
            enc.low <<= 1;
        }
    }
    fn decision(enc: *Encoder, ctx: *u8, bin: u1) void {
        const c = ctx.*;
        const lps: u32 = range_lps[c >> 1][(enc.range >> 6) & 3];
        enc.range -= lps;
        if (bin != c & 1) {
            enc.low += enc.range;
            enc.range = lps;
            ctx.* = after_lps[c];
        } else ctx.* = after_mps[c];
        enc.renorm();
    }
    fn bypass(enc: *Encoder, bin: u1) void {
        enc.low <<= 1;
        if (bin != 0) enc.low += enc.range;
        if (enc.low >= 1024) {
            enc.put(1);
            enc.low -= 1024;
        } else if (enc.low < 512) {
            enc.put(0);
        } else {
            enc.low -= 512;
            enc.outstanding += 1;
        }
    }
    fn terminate(enc: *Encoder, bin: u1) void {
        enc.range -= 2;
        if (bin != 0) {
            enc.low += enc.range;
            // EncodeFlush
            enc.range = 2;
            enc.renorm();
            enc.put(@intCast((enc.low >> 9) & 1));
            // WriteBits( ( ( ivlLow >> 7 ) & 3 ) | 1, 2 )
            const two = ((enc.low >> 7) & 3) | 1;
            for ([_]u5{ 1, 0 }) |k| {
                if (two >> k & 1 != 0) enc.out[enc.bits >> 3] |= @as(u8, 0x80) >> @intCast(enc.bits & 7);
                enc.bits += 1;
            }
        } else enc.renorm();
    }
};

test "the engine reads back what the informative encoder wrote" {
    var enc: Encoder = .{};
    var ctx_e: Contexts = undefined;
    initContexts(&ctx_e, 1, 30);
    var seed: u32 = 12345;
    var bins: [600]u1 = undefined;
    var kinds: [600]u8 = undefined;
    for (0..600) |i| {
        seed = seed *% 1103515245 +% 12345;
        kinds[i] = @intCast((seed >> 16) % 3);
        seed = seed *% 1103515245 +% 12345;
        // Skewed towards 0 for the decisions.
        bins[i] = @intFromBool((seed >> 16) % 5 == 0);
        switch (kinds[i]) {
            0, 1 => enc.decision(&ctx_e[(seed >> 8) % 7], bins[i]),
            else => enc.bypass(bins[i]),
        }
    }
    enc.terminate(1);
    var ctx_d: Contexts = undefined;
    initContexts(&ctx_d, 1, 30);
    var e: Engine = undefined;
    try testing.expect(e.init(enc.out[0 .. (enc.bits + 7) / 8 + 2], 0));
    seed = 12345;
    for (0..600) |i| {
        seed = seed *% 1103515245 +% 12345;
        seed = seed *% 1103515245 +% 12345;
        const got = switch (kinds[i]) {
            0, 1 => e.decision(&ctx_d[(seed >> 8) % 7]),
            else => e.bypass(),
        };
        try testing.expectEqual(bins[i], got);
    }
    try testing.expectEqual(@as(u1, 1), e.terminate());
    try testing.expectEqual((enc.bits + 7) / 8, e.bytePosition());
}

test "contexts start from initValue and the slice's QP" {
    var ctx: Contexts = undefined;
    initContexts(&ctx, 0, 26);
    // split_cu_flag's first, 139: m = 8*5-45 = -5, n = 88-16 = 72;
    // ((-5 * 26) >> 4) + 72 = -9 + 72 = 63 -> pStateIdx 0, MPS 0.
    try testing.expectEqual(@as(u8, 0), ctx[Ctx.split_cu]);
    // 154 (m 0, n 64): 64 -> pStateIdx 0, MPS 1, whatever the QP.
    try testing.expectEqual(@as(u8, 1), ctx[Ctx.transquant_bypass]);
}
