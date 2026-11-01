// SPDX-License-Identifier: MIT
//! One channel of SILK (RFC 6716 4.2.7): a frame of 10 or 20 ms at 8, 12
//! or 16 kHz decoded from its side information - signal type, gains,
//! NLSFs, pitch lags and LTP filter - and its excitation, the pulses the
//! shell coder splits over blocks of 16 samples; then the excitation
//! through the long-term (pitch) and short-term (LPC) predictors.
//!
//! **A lost frame** is made from the last good one's pitch and noise
//! (`silk_plc.zig`); comfort noise follows the background while frames
//! are inactive.

const fix = @import("silk_fix.zig");
const lpc = @import("silk_lpc.zig");
const tables = @import("silk_tables.zig");
const plc = @import("silk_plc.zig");
const Range = @import("range.zig").Range;
const Resampler = @import("silk_resampler.zig").Resampler;

pub const max_frame_length = 320;
pub const max_sub_frame_length = 80;
pub const max_nb_subfr = 4;
pub const max_lpc_order = lpc.max_order;
pub const ltp_order = 5;

pub const type_no_voice_activity = 0;
pub const type_unvoiced = 1;
pub const type_voiced = 2;

/// How a frame's first gain and its LTP scaling are coded: on their own,
/// on their own without LTP scaling (the side channel after a mid-only
/// frame), or as deltas from the frame before.
pub const CondCoding = enum { independently, independently_no_ltp_scaling, conditionally };

/// What the decoder is asked for: the frame, its low-bitrate copy from
/// the packet after, or a guess for a lost one.
pub const Lost = enum { normal, lost, lbrr };

/// The quantisation indices of a frame's side information.
pub const Indices = struct {
    gains: [max_nb_subfr]i8 = @splat(0),
    ltp: [max_nb_subfr]i8 = @splat(0),
    nlsf: [max_lpc_order + 1]i8 = @splat(0),
    lag_index: i16 = 0,
    contour_index: i8 = 0,
    signal_type: i8 = 0,
    quant_offset_type: i8 = 0,
    nlsf_interp_coef_q2: i8 = 0,
    per_index: i8 = 0,
    ltp_scale_index: i8 = 0,
    seed: i8 = 0,
};

/// A frame's parameters once dequantised.
pub const Control = struct {
    pitch_l: [max_nb_subfr]i32 = @splat(0),
    gains_q16: [max_nb_subfr]i32 = @splat(0),
    /// The first half's (interpolated) and the second half's filters.
    pred_coef_q12: [2][max_lpc_order]i16 = @splat(@splat(0)),
    ltp_coef_q14: [ltp_order * max_nb_subfr]i16 = @splat(0),
    ltp_scale_q14: i32 = 0,
};

pub const Cng = struct {
    exc_buf_q14: [max_frame_length]i32 = @splat(0),
    smth_nlsf_q15: [max_lpc_order]i16 = @splat(0),
    synth_state: [max_lpc_order]i32 = @splat(0),
    smth_gain_q16: i32 = 0,
    rand_seed: i32 = 0,
    fs_khz: u32 = 0,
};

pub const Plc = struct {
    pitch_l_q8: i32 = 0,
    ltp_coef_q14: [ltp_order]i16 = @splat(0),
    prev_lpc_q12: [max_lpc_order]i16 = @splat(0),
    last_frame_lost: bool = false,
    rand_seed: i32 = 0,
    rand_scale_q14: i16 = 0,
    conc_energy: i32 = 0,
    conc_energy_shift: u5 = 0,
    prev_ltp_scale_q14: i16 = 0,
    prev_gain_q16: [2]i32 = @splat(0),
    fs_khz: u32 = 0,
    nb_subfr: u32 = 0,
    subfr_length: u32 = 0,
};

/// One channel's decoder.
pub const Channel = struct {
    prev_gain_q16: i32 = 0,
    exc_q14: [max_frame_length]i32 = @splat(0),
    slpc_q14_buf: [max_lpc_order]i32 = @splat(0),
    /// The output of the last 20 ms, the LTP's history; and room for the
    /// first half of this frame when the second half rewhitens.
    out_buf: [max_frame_length + 2 * max_sub_frame_length]i16 = @splat(0),
    lag_prev: i32 = 0,
    last_gain_index: i8 = 0,
    fs_khz: u32 = 0,
    fs_api_hz: i32 = 0,
    nb_subfr: u32 = 0,
    frame_length: u32 = 0,
    subfr_length: u32 = 0,
    ltp_mem_length: u32 = 0,
    lpc_order: u32 = 0,
    prev_nlsf_q15: [max_lpc_order]i16 = @splat(0),
    first_frame_after_reset: bool = false,
    pitch_lag_low_bits_icdf: []const u8 = &tables.uniform4_icdf,
    pitch_contour_icdf: []const u8 = &tables.pitch_contour_nb_icdf,
    frames_decoded: u32 = 0,
    frames_per_packet: u32 = 0,
    ec_prev_signal_type: i32 = 0,
    ec_prev_lag_index: i16 = 0,
    vad_flags: [3]bool = @splat(false),
    lbrr_flag: bool = false,
    lbrr_flags: [3]bool = @splat(false),
    resampler: Resampler = .{},
    nlsf_cb: *const tables.NlsfCodebook = &tables.nlsf_cb_nb_mb,
    indices: Indices = .{},
    cng: Cng = .{},
    loss_cnt: i32 = 0,
    prev_signal_type: i32 = 0,
    plc: Plc = .{},

    /// Everything cleared, as at the start of a stream.
    pub fn reset(ch: *Channel) void {
        ch.* = .{};
        ch.first_frame_after_reset = true;
        ch.prev_gain_q16 = 65536;
        plc.cngReset(ch);
        plc.reset(ch);
    }

    /// The internal rate and the frame's subframes; a new rate starts the
    /// filters over.
    pub fn setFs(ch: *Channel, fs_khz: u32, fs_api_hz: i32) void {
        ch.subfr_length = 5 * fs_khz;
        const frame_length = ch.nb_subfr * ch.subfr_length;
        if (ch.fs_khz != fs_khz or ch.fs_api_hz != fs_api_hz) {
            ch.resampler.init(fs_khz);
            ch.fs_api_hz = fs_api_hz;
        }
        if (ch.fs_khz != fs_khz or frame_length != ch.frame_length) {
            if (fs_khz == 8) {
                ch.pitch_contour_icdf = if (ch.nb_subfr == max_nb_subfr) &tables.pitch_contour_nb_icdf else &tables.pitch_contour_10_ms_nb_icdf;
            } else {
                ch.pitch_contour_icdf = if (ch.nb_subfr == max_nb_subfr) &tables.pitch_contour_icdf else &tables.pitch_contour_10_ms_icdf;
            }
            if (ch.fs_khz != fs_khz) {
                ch.ltp_mem_length = 20 * fs_khz;
                if (fs_khz == 16) {
                    ch.lpc_order = 16;
                    ch.nlsf_cb = &tables.nlsf_cb_wb;
                    ch.pitch_lag_low_bits_icdf = &tables.uniform8_icdf;
                } else {
                    ch.lpc_order = 10;
                    ch.nlsf_cb = &tables.nlsf_cb_nb_mb;
                    ch.pitch_lag_low_bits_icdf = if (fs_khz == 12) &tables.uniform6_icdf else &tables.uniform4_icdf;
                }
                ch.first_frame_after_reset = true;
                ch.lag_prev = 100;
                ch.last_gain_index = 10;
                ch.prev_signal_type = type_no_voice_activity;
                ch.out_buf = @splat(0);
                ch.slpc_q14_buf = @splat(0);
            }
            ch.fs_khz = fs_khz;
            ch.frame_length = frame_length;
        }
    }

    /// The side channel's history forgotten, for its first frame after
    /// mid-only ones.
    pub fn resetSide(ch: *Channel) void {
        ch.out_buf = @splat(0);
        ch.slpc_q14_buf = @splat(0);
        ch.lag_prev = 100;
        ch.last_gain_index = 10;
        ch.prev_signal_type = type_no_voice_activity;
        ch.first_frame_after_reset = true;
    }
};

/// The side information of frame `frame_index` of the packet.
pub fn decodeIndices(ch: *Channel, dec: *Range, frame_index: usize, decode_lbrr: bool, cond: CondCoding) void {
    const ix: u32 = if (decode_lbrr or ch.vad_flags[frame_index])
        dec.icdf(&tables.type_offset_vad_icdf, 8) + 2
    else
        dec.icdf(&tables.type_offset_no_vad_icdf, 8);
    const signal_type: u32 = ix >> 1;
    ch.indices.signal_type = @intCast(signal_type);
    ch.indices.quant_offset_type = @intCast(ix & 1);

    // The gains: the first by itself (3 bits by the signal type, 3 more
    // uniform) or as a delta; the rest as deltas.
    if (cond == .conditionally) {
        ch.indices.gains[0] = @intCast(dec.icdf(&tables.delta_gain_icdf, 8));
    } else {
        ch.indices.gains[0] = @intCast((dec.icdf(&tables.gain_icdf[signal_type], 8) << 3) + dec.icdf(&tables.uniform8_icdf, 8));
    }
    for (1..ch.nb_subfr) |i| ch.indices.gains[i] = @intCast(dec.icdf(&tables.delta_gain_icdf, 8));

    // The NLSFs: the first-stage vector, then each residual, the outer
    // values extended.
    const cb = ch.nlsf_cb;
    const cb1 = dec.icdf(cb.cb1_icdf[(signal_type >> 1) * cb.n_vectors ..], 8);
    ch.indices.nlsf[0] = @intCast(cb1);
    var ec_ix: [max_lpc_order]i16 = undefined;
    var pred_q8: [max_lpc_order]u8 = undefined;
    lpc.nlsfUnpack(&ec_ix, &pred_q8, cb, cb1);
    for (0..cb.order) |i| {
        var v: i32 = @intCast(dec.icdf(cb.ec_icdf[@intCast(ec_ix[i])..], 8));
        if (v == 0) {
            v -= @intCast(dec.icdf(&tables.nlsf_ext_icdf, 8));
        } else if (v == 8) {
            v += @intCast(dec.icdf(&tables.nlsf_ext_icdf, 8));
        }
        ch.indices.nlsf[i + 1] = @intCast(v - 4);
    }
    ch.indices.nlsf_interp_coef_q2 = if (ch.nb_subfr == max_nb_subfr) @intCast(dec.icdf(&tables.nlsf_interpolation_factor_icdf, 8)) else 4;

    if (signal_type == type_voiced) {
        // The pitch lag: a delta from the frame before's, or absolute.
        var absolute = true;
        if (cond == .conditionally and ch.ec_prev_signal_type == type_voiced) {
            const delta: i32 = @intCast(dec.icdf(&tables.pitch_delta_icdf, 8));
            if (delta > 0) {
                ch.indices.lag_index = @truncate(@as(i32, ch.ec_prev_lag_index) + delta - 9);
                absolute = false;
            }
        }
        if (absolute) {
            const high = dec.icdf(&tables.pitch_lag_icdf, 8) * (ch.fs_khz >> 1);
            ch.indices.lag_index = @intCast(high + dec.icdf(ch.pitch_lag_low_bits_icdf, 8));
        }
        ch.ec_prev_lag_index = ch.indices.lag_index;
        ch.indices.contour_index = @intCast(dec.icdf(ch.pitch_contour_icdf, 8));

        // The LTP filters: a codebook, then a vector of it a subframe.
        const per = dec.icdf(&tables.ltp_per_index_icdf, 8);
        ch.indices.per_index = @intCast(per);
        for (0..ch.nb_subfr) |k| ch.indices.ltp[k] = @intCast(dec.icdf(tables.ltp_gain_icdf[per], 8));
        ch.indices.ltp_scale_index = if (cond == .independently) @intCast(dec.icdf(&tables.ltp_scale_icdf, 8)) else 0;
    }
    ch.ec_prev_signal_type = @intCast(signal_type);
    ch.indices.seed = @intCast(dec.icdf(&tables.uniform4_icdf, 8));
}

/// The excitation's pulses: a rate level, the count of each block of 16
/// (with extra low bits when there are more than 16), the counts split
/// down the shell tree, the low bits, then the signs.
pub fn decodePulses(dec: *Range, pulses: []i16, signal_type: i32, quant_offset_type: i32, frame_length: u32) void {
    const rate_level = dec.icdf(&tables.rate_levels_icdf[@intCast(signal_type >> 1)], 8);
    var iter = frame_length >> 4;
    if (iter * 16 < frame_length) iter += 1;

    var sum_pulses: [max_frame_length / 16]i32 = undefined;
    var n_lshifts: [max_frame_length / 16]u32 = undefined;
    for (0..iter) |i| {
        n_lshifts[i] = 0;
        var sum = dec.icdf(&tables.pulses_per_block_icdf[rate_level], 8);
        while (sum == 17) {
            n_lshifts[i] += 1;
            // After 10 low bits the escape is no longer possible.
            const skip: usize = @intFromBool(n_lshifts[i] == 10);
            sum = dec.icdf(tables.pulses_per_block_icdf[9][skip..], 8);
        }
        sum_pulses[i] = @intCast(sum);
    }

    for (0..iter) |i| {
        const block = pulses[i * 16 ..][0..16];
        if (sum_pulses[i] > 0) {
            shellDecode(block, dec, sum_pulses[i]);
        } else {
            @memset(block, 0);
        }
    }

    for (0..iter) |i| {
        const nls = n_lshifts[i];
        if (nls == 0) continue;
        const block = pulses[i * 16 ..][0..16];
        for (block) |*p| {
            var abs_q: i32 = p.*;
            for (0..nls) |_| abs_q = (abs_q << 1) + @as(i32, @intCast(dec.icdf(&tables.lsb_icdf, 8)));
            p.* = @intCast(abs_q);
        }
        sum_pulses[i] |= @intCast(nls << 5);
    }

    // The signs, by the pulses in the block.
    var icdf = [2]u8{ 0, 0 };
    const sign = tables.sign_icdf[@intCast(7 * (quant_offset_type + (signal_type << 1)))..];
    const blocks = (frame_length + 8) >> 4;
    for (0..blocks) |i| {
        const p = sum_pulses[i];
        if (p <= 0) continue;
        icdf[0] = sign[@intCast(@min(p & 0x1F, 6))];
        for (pulses[i * 16 ..][0..16]) |*q| {
            if (q.* > 0) q.* *= @as(i16, @intCast(dec.icdf(&icdf, 8) << 1)) - 1;
        }
    }
}

/// `p` pulses split over 16 samples: halves, quarters, eighths, pairs.
fn shellDecode(out: *[16]i16, dec: *Range, p: i32) void {
    var p3: [2]i16 = undefined;
    var p2: [4]i16 = undefined;
    var p1: [8]i16 = undefined;
    split(&p3[0], &p3[1], dec, p, &tables.shell_code_table3);
    split(&p2[0], &p2[1], dec, p3[0], &tables.shell_code_table2);
    split(&p1[0], &p1[1], dec, p2[0], &tables.shell_code_table1);
    split(&out[0], &out[1], dec, p1[0], &tables.shell_code_table0);
    split(&out[2], &out[3], dec, p1[1], &tables.shell_code_table0);
    split(&p1[2], &p1[3], dec, p2[1], &tables.shell_code_table1);
    split(&out[4], &out[5], dec, p1[2], &tables.shell_code_table0);
    split(&out[6], &out[7], dec, p1[3], &tables.shell_code_table0);
    split(&p2[2], &p2[3], dec, p3[1], &tables.shell_code_table2);
    split(&p1[4], &p1[5], dec, p2[2], &tables.shell_code_table1);
    split(&out[8], &out[9], dec, p1[4], &tables.shell_code_table0);
    split(&out[10], &out[11], dec, p1[5], &tables.shell_code_table0);
    split(&p1[6], &p1[7], dec, p2[3], &tables.shell_code_table1);
    split(&out[12], &out[13], dec, p1[6], &tables.shell_code_table0);
    split(&out[14], &out[15], dec, p1[7], &tables.shell_code_table0);
}

fn split(child1: *i16, child2: *i16, dec: *Range, p: i32, table: []const u8) void {
    if (p > 0) {
        const c: i32 = @intCast(dec.icdf(table[tables.shell_code_table_offsets[@intCast(p)]..], 8));
        child1.* = @intCast(c);
        child2.* = @intCast(p - c);
    } else {
        child1.* = 0;
        child2.* = 0;
    }
}

/// The gains in Q16 from their indices: the first absolute (no more than
/// 16 steps below the last) or a delta, the rest deltas - large ones in
/// double steps.
fn gainsDequant(gain_q16: []i32, ind: []const i8, prev_ind: *i8, conditional: bool) void {
    var prev: i32 = prev_ind.*;
    for (gain_q16, 0..) |*g, k| {
        if (k == 0 and !conditional) {
            prev = @max(ind[k], prev - 16);
        } else {
            const delta = @as(i32, ind[k]) - 4;
            const threshold = 2 * 36 - 64 + prev;
            if (delta > threshold) {
                prev += (delta << 1) - threshold;
            } else {
                prev += delta;
            }
        }
        prev = @max(0, @min(63, prev));
        g.* = fix.log2lin(@min(fix.smulwb(1907825, prev) + 2090, 3967));
    }
    prev_ind.* = @intCast(prev);
}

/// The pitch lag of each subframe: the lag and its contour.
fn decodePitch(lag_index: i16, contour_index: i8, pitch_lags: []i32, fs_khz: u32, nb_subfr: u32) void {
    const min_lag: i32 = @intCast(2 * fs_khz);
    const max_lag: i32 = @intCast(18 * fs_khz);
    const lag = min_lag + lag_index;
    const c: usize = @intCast(contour_index);
    for (0..nb_subfr) |k| {
        const off: i32 = if (fs_khz == 8)
            (if (nb_subfr == max_nb_subfr) tables.cb_lags_stage2[k][c] else tables.cb_lags_stage2_10_ms[k][c])
        else
            (if (nb_subfr == max_nb_subfr) tables.cb_lags_stage3[k][c] else tables.cb_lags_stage3_10_ms[k][c]);
        pitch_lags[k] = fix.limit(lag + off, min_lag, max_lag);
    }
}

/// The frame's parameters from its indices.
fn decodeParameters(ch: *Channel, ctrl: *Control, cond: CondCoding) void {
    const order = ch.lpc_order;
    gainsDequant(ctrl.gains_q16[0..ch.nb_subfr], &ch.indices.gains, &ch.last_gain_index, cond == .conditionally);

    var nlsf: [max_lpc_order]i16 = undefined;
    lpc.nlsfDecode(&nlsf, &ch.indices.nlsf, ch.nlsf_cb);
    lpc.nlsf2a(&ctrl.pred_coef_q12[1], &nlsf, order);

    // No interpolation from a frame that was not decoded.
    if (ch.first_frame_after_reset) ch.indices.nlsf_interp_coef_q2 = 4;
    if (ch.indices.nlsf_interp_coef_q2 < 4) {
        var nlsf0: [max_lpc_order]i16 = undefined;
        for (0..order) |i| {
            const d = @as(i32, nlsf[i]) - ch.prev_nlsf_q15[i];
            nlsf0[i] = @truncate(ch.prev_nlsf_q15[i] + ((ch.indices.nlsf_interp_coef_q2 * d) >> 2));
        }
        lpc.nlsf2a(&ctrl.pred_coef_q12[0], &nlsf0, order);
    } else {
        ctrl.pred_coef_q12[0] = ctrl.pred_coef_q12[1];
    }
    @memcpy(ch.prev_nlsf_q15[0..order], nlsf[0..order]);

    // After a loss the filters are widened a little.
    if (ch.loss_cnt != 0) {
        lpc.bwexpander(ctrl.pred_coef_q12[0][0..order], 63570);
        lpc.bwexpander(ctrl.pred_coef_q12[1][0..order], 63570);
    }

    if (ch.indices.signal_type == type_voiced) {
        decodePitch(ch.indices.lag_index, ch.indices.contour_index, &ctrl.pitch_l, ch.fs_khz, ch.nb_subfr);
        const cbk = tables.ltp_vq_q7[@intCast(ch.indices.per_index)];
        for (0..ch.nb_subfr) |k| {
            const v = cbk[@intCast(ch.indices.ltp[k])];
            for (0..ltp_order) |i| ctrl.ltp_coef_q14[k * ltp_order + i] = @as(i16, v[i]) << 7;
        }
        ctrl.ltp_scale_q14 = tables.ltp_scales_q14[@intCast(ch.indices.ltp_scale_index)];
    } else {
        @memset(ctrl.pitch_l[0..ch.nb_subfr], 0);
        @memset(ctrl.ltp_coef_q14[0 .. ltp_order * ch.nb_subfr], 0);
        ch.indices.per_index = 0;
        ctrl.ltp_scale_q14 = 0;
    }
}

/// The scratch of a frame: the rewhitened history and the LTP's state.
pub const Scratch = struct {
    sltp: [max_frame_length]i16 = undefined,
    sltp_q15: [2 * max_frame_length]i32 = undefined,
};

/// A subframe's excitation plus the prediction from a pitch period back,
/// into `res`; the LTP state, from `at`, goes on with it. The history is
/// read through a pointer: with a bounds check for each tap, LLVM's
/// Xtensa backend makes a constant it cannot select.
fn ltpFilter(sltp_q15: *[2 * max_frame_length]i32, at: usize, lag: usize, b_q14: []const i16, exc: []const i32, res: []i32) void {
    const taps = b_q14[0..ltp_order];
    // The five samples around a pitch period back, the earliest first.
    const back: [*]const i32 = sltp_q15[at - lag - ltp_order / 2 ..].ptr;
    const into = sltp_q15[at..][0..res.len];
    for (res, into, 0..) |*r, *s, i| {
        var ltp_pred_q13: i32 = 2;
        inline for (0..ltp_order) |j| ltp_pred_q13 = fix.smlawb(ltp_pred_q13, back[i + ltp_order - 1 - j], taps[j]);
        r.* = exc[i] +% (ltp_pred_q13 << 1);
        s.* = r.* << 1;
    }
}

/// The excitation through the long-term and the short-term predictor.
fn decodeCore(ch: *Channel, ctrl: *Control, xq: []i16, pulses: []const i16, scratch: *Scratch) void {
    const sltp = &scratch.sltp;
    const sltp_q15 = &scratch.sltp_q15;
    var res_q14: [max_sub_frame_length]i32 = undefined;
    var slpc_q14: [max_sub_frame_length + max_lpc_order]i32 = undefined;
    const order = ch.lpc_order;
    const subfr = ch.subfr_length;
    const ltp_mem = ch.ltp_mem_length;

    const offset_q10: i32 = tables.quantization_offsets_q10[@intCast(ch.indices.signal_type >> 1)][@intCast(ch.indices.quant_offset_type)];
    const nlsf_interpolation = ch.indices.nlsf_interp_coef_q2 < 4;

    // The excitation: the pulses less a little, plus the offset, signs
    // turned by the generator.
    var rand_seed: i32 = ch.indices.seed;
    for (0..ch.frame_length) |i| {
        rand_seed = fix.rand(rand_seed);
        var e: i32 = @as(i32, pulses[i]) << 14;
        if (e > 0) {
            e -= 80 << 4;
        } else if (e < 0) {
            e += 80 << 4;
        }
        e += offset_q10 << 4;
        if (rand_seed < 0) e = -e;
        ch.exc_q14[i] = e;
        rand_seed +%= pulses[i];
    }

    slpc_q14[0..max_lpc_order].* = ch.slpc_q14_buf;
    var sltp_buf_idx: usize = ltp_mem;
    var lag: usize = 0;
    for (0..ch.nb_subfr) |k| {
        const a_q12 = &ctrl.pred_coef_q12[k >> 1];
        const b_q14 = ctrl.ltp_coef_q14[k * ltp_order ..][0..ltp_order];
        var signal_type: i32 = ch.indices.signal_type;
        const exc = ch.exc_q14[k * subfr ..][0..subfr];

        const gain = ctrl.gains_q16[k];
        const gain_q10 = gain >> 6;
        var inv_gain_q31 = fix.inverse32VarQ(gain, 47);

        // A new gain rescales the filter states.
        var gain_adj_q16: i32 = 1 << 16;
        if (gain != ch.prev_gain_q16) {
            gain_adj_q16 = fix.div32VarQ(ch.prev_gain_q16, gain, 16);
            for (slpc_q14[0..max_lpc_order]) |*s| s.* = fix.smulww(gain_adj_q16, s.*);
        }
        ch.prev_gain_q16 = gain;

        // No sudden switch from a voiced concealment to unvoiced frames.
        if (ch.loss_cnt != 0 and ch.prev_signal_type == type_voiced and ch.indices.signal_type != type_voiced and k < max_nb_subfr / 2) {
            @memset(b_q14, 0);
            b_q14[ltp_order / 2] = 4096;
            signal_type = type_voiced;
            ctrl.pitch_l[k] = ch.lag_prev;
        }

        if (signal_type == type_voiced) {
            lag = @intCast(ctrl.pitch_l[k]);
            if (k == 0 or (k == 2 and nlsf_interpolation)) {
                // The history rewhitened with this half's filter.
                const start = ltp_mem - lag - order - ltp_order / 2;
                if (k == 2) @memcpy(ch.out_buf[ltp_mem..][0 .. 2 * subfr], xq[0 .. 2 * subfr]);
                lpc.analysisFilter(sltp[start..], ch.out_buf[start + k * subfr ..], a_q12, ltp_mem - start, order);
                // Less dependence on the packet before.
                if (k == 0) inv_gain_q31 = fix.smulwb(inv_gain_q31, ctrl.ltp_scale_q14) << 2;
                for (0..lag + ltp_order / 2) |i| sltp_q15[sltp_buf_idx - i - 1] = fix.smulwb(inv_gain_q31, sltp[ltp_mem - i - 1]);
            } else if (gain_adj_q16 != 1 << 16) {
                for (0..lag + ltp_order / 2) |i| {
                    const at = sltp_buf_idx - i - 1;
                    sltp_q15[at] = fix.smulww(gain_adj_q16, sltp_q15[at]);
                }
            }
        }

        var res: []const i32 = exc;
        if (signal_type == type_voiced) {
            ltpFilter(sltp_q15, sltp_buf_idx, lag, b_q14, exc, res_q14[0..subfr]);
            sltp_buf_idx += subfr;
            res = res_q14[0..subfr];
        }

        const out = xq[k * subfr ..][0..subfr];
        for (0..subfr) |i| {
            var lpc_pred_q10: i32 = @intCast(order >> 1);
            for (0..order) |j| lpc_pred_q10 = fix.smlawb(lpc_pred_q10, slpc_q14[max_lpc_order + i - j - 1], a_q12[j]);
            slpc_q14[max_lpc_order + i] = fix.addSat32(res[i], fix.lshiftSat32(lpc_pred_q10, 4));
            out[i] = fix.sat16(fix.rshiftRound(fix.smulww(slpc_q14[max_lpc_order + i], gain_q10), 8));
        }
        slpc_q14[0..max_lpc_order].* = slpc_q14[subfr..][0..max_lpc_order].*;
    }
    ch.slpc_q14_buf = slpc_q14[0..max_lpc_order].*;
}

/// Frame `frame_length` samples into `out`: decoded, its LBRR copy, or
/// concealed.
pub fn decodeFrame(ch: *Channel, dec: *Range, out: []i16, lost: Lost, cond: CondCoding, scratch: *Scratch) u32 {
    const l = ch.frame_length;
    var ctrl: Control = .{};
    if (lost == .normal or (lost == .lbrr and ch.lbrr_flags[ch.frames_decoded])) {
        var pulses: [max_frame_length]i16 = undefined;
        decodeIndices(ch, dec, ch.frames_decoded, lost == .lbrr, cond);
        decodePulses(dec, &pulses, ch.indices.signal_type, ch.indices.quant_offset_type, l);
        decodeParameters(ch, &ctrl, cond);
        decodeCore(ch, &ctrl, out, &pulses, scratch);
        updateOutBuf(ch, out);
        plc.plc(ch, &ctrl, out, false, scratch);
        ch.loss_cnt = 0;
        ch.prev_signal_type = ch.indices.signal_type;
        ch.first_frame_after_reset = false;
    } else {
        plc.plc(ch, &ctrl, out, true, scratch);
        updateOutBuf(ch, out);
    }
    plc.cng(ch, &ctrl, out[0..l]);
    plc.glueFrames(ch, out[0..l]);
    ch.lag_prev = ctrl.pitch_l[ch.nb_subfr - 1];
    return l;
}

fn updateOutBuf(ch: *Channel, out: []const i16) void {
    const mv = ch.ltp_mem_length - ch.frame_length;
    for (0..mv) |i| ch.out_buf[i] = ch.out_buf[i + ch.frame_length];
    @memcpy(ch.out_buf[mv..][0..ch.frame_length], out[0..ch.frame_length]);
}
