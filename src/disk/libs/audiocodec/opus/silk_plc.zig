// SPDX-License-Identifier: MIT
//! SILK's packet loss concealment and comfort noise, as libopus does them
//! (they are not part of the bitstream): a lost frame continues the last
//! good one's pitch with its LTP filter fading and noise from its
//! excitation; the next good frame fades in from the concealment's
//! energy. While frames are inactive the decoder follows the background's
//! spectrum and level, and adds that noise to what it conceals.

const fix = @import("silk_fix.zig");
const lpc = @import("silk_lpc.zig");
const frame = @import("silk_frame.zig");
const Channel = frame.Channel;
const Control = frame.Control;
const max_lpc_order = frame.max_lpc_order;
const ltp_order = frame.ltp_order;

const harm_att_q15 = [2]i16{ 32440, 31130 };
const rand_attenuate_v_q15 = [2]i16{ 31130, 26214 };
const rand_attenuate_uv_q15 = [2]i16{ 32440, 29491 };
const pitch_gain_start_min_q14 = 11469;
const pitch_gain_start_max_q14 = 15565;
const rand_buf_size = 128;

pub fn reset(ch: *Channel) void {
    ch.plc.pitch_l_q8 = @intCast(ch.frame_length << 7);
    ch.plc.prev_gain_q16 = .{ 65536, 65536 };
    ch.plc.subfr_length = 20;
    ch.plc.nb_subfr = 2;
}

/// After a good frame the state is updated from it; a lost one is made.
pub fn plc(ch: *Channel, ctrl: *Control, out: []i16, lost: bool, scratch: *frame.Scratch) void {
    if (ch.fs_khz != ch.plc.fs_khz) {
        reset(ch);
        ch.plc.fs_khz = ch.fs_khz;
    }
    if (lost) {
        conceal(ch, ctrl, out, scratch);
        ch.loss_cnt += 1;
    } else {
        update(ch, ctrl);
    }
}

/// What a loss would continue: the strongest pitch pulse's LTP filter
/// (limited), the filter and the last two gains.
fn update(ch: *Channel, ctrl: *const Control) void {
    const p = &ch.plc;
    ch.prev_signal_type = ch.indices.signal_type;
    var ltp_gain_q14: i32 = 0;
    const nb = ch.nb_subfr;
    if (ch.indices.signal_type == frame.type_voiced) {
        var j: usize = 0;
        while (j * ch.subfr_length < ctrl.pitch_l[nb - 1]) : (j += 1) {
            if (j == nb) break;
            var temp: i32 = 0;
            for (0..ltp_order) |i| temp += ctrl.ltp_coef_q14[(nb - 1 - j) * ltp_order + i];
            if (temp > ltp_gain_q14) {
                ltp_gain_q14 = temp;
                @memcpy(&p.ltp_coef_q14, ctrl.ltp_coef_q14[(nb - 1 - j) * ltp_order ..][0..ltp_order]);
                p.pitch_l_q8 = ctrl.pitch_l[nb - 1 - j] << 8;
            }
        }
        p.ltp_coef_q14 = @splat(0);
        p.ltp_coef_q14[ltp_order / 2] = @truncate(ltp_gain_q14);

        if (ltp_gain_q14 < pitch_gain_start_min_q14) {
            const scale_q10 = @divTrunc(@as(i32, pitch_gain_start_min_q14) << 10, @max(ltp_gain_q14, 1));
            for (&p.ltp_coef_q14) |*c| c.* = @truncate(fix.smulbb(c.*, scale_q10) >> 10);
        } else if (ltp_gain_q14 > pitch_gain_start_max_q14) {
            const scale_q14 = @divTrunc(@as(i32, pitch_gain_start_max_q14) << 14, @max(ltp_gain_q14, 1));
            for (&p.ltp_coef_q14) |*c| c.* = @truncate(fix.smulbb(c.*, scale_q14) >> 14);
        }
    } else {
        p.pitch_l_q8 = @intCast((ch.fs_khz * 18) << 8);
        p.ltp_coef_q14 = @splat(0);
    }
    @memcpy(p.prev_lpc_q12[0..ch.lpc_order], ctrl.pred_coef_q12[1][0..ch.lpc_order]);
    p.prev_ltp_scale_q14 = @intCast(ctrl.ltp_scale_q14);
    p.prev_gain_q16 = .{ ctrl.gains_q16[nb - 2], ctrl.gains_q16[nb - 1] };
    p.subfr_length = ch.subfr_length;
    p.nb_subfr = nb;
}

/// A lost frame: the history rewhitened and continued by the fading LTP
/// filter plus noise, then through the (widened) LPC filter.
fn conceal(ch: *Channel, ctrl: *Control, out: []i16, scratch: *frame.Scratch) void {
    const p = &ch.plc;
    const order = ch.lpc_order;
    const ltp_mem = ch.ltp_mem_length;
    const sltp = &scratch.sltp;
    const sltp_q14 = &scratch.sltp_q15;
    @memset(sltp_q14[0 .. ltp_mem + ch.frame_length], 0);

    const prev_gain_q10 = [2]i32{ p.prev_gain_q16[0] >> 6, p.prev_gain_q16[1] >> 6 };
    if (ch.first_frame_after_reset) p.prev_lpc_q12 = @splat(0);

    // The noise comes from the quieter of the last two subframes.
    var exc_buf: [2 * frame.max_sub_frame_length]i16 = undefined;
    const subfr = ch.subfr_length;
    for (0..2) |k| {
        for (0..subfr) |i| {
            const e = ch.exc_q14[i + (k + ch.nb_subfr - 2) * subfr];
            exc_buf[k * subfr + i] = fix.sat16(fix.smulww(e, prev_gain_q10[k]) >> 8);
        }
    }
    const e1 = fix.sumSqrShift(exc_buf[0..subfr]);
    const e2 = fix.sumSqrShift(exc_buf[subfr .. 2 * subfr]);
    const rand_start: i32 = if ((e1.energy >> e2.shift) < (e2.energy >> e1.shift))
        @max(0, @as(i32, @intCast((p.nb_subfr - 1) * p.subfr_length)) - rand_buf_size)
    else
        @max(0, @as(i32, @intCast(p.nb_subfr * p.subfr_length)) - rand_buf_size);
    const rand_ptr = ch.exc_q14[@intCast(rand_start)..];

    const b_q14 = &p.ltp_coef_q14;
    var rand_scale_q14: i16 = p.rand_scale_q14;
    const att: usize = @intCast(@min(1, ch.loss_cnt));
    const harm_gain_q15: i32 = harm_att_q15[att];
    var rand_gain_q15: i32 = if (ch.prev_signal_type == frame.type_voiced) rand_attenuate_v_q15[att] else rand_attenuate_uv_q15[att];

    lpc.bwexpander(p.prev_lpc_q12[0..order], 64881);
    var a_q12: [max_lpc_order]i16 = p.prev_lpc_q12;

    if (ch.loss_cnt == 0) {
        rand_scale_q14 = 1 << 14;
        if (ch.prev_signal_type == frame.type_voiced) {
            // Less noise where the pitch carries the signal.
            for (b_q14) |b| rand_scale_q14 -%= b;
            rand_scale_q14 = @max(3277, rand_scale_q14);
            rand_scale_q14 = @truncate(fix.smulbb(rand_scale_q14, p.prev_ltp_scale_q14) >> 14);
        } else {
            // And less where the filter's gain is high.
            const inv_gain_q30 = lpc.inversePredGain(p.prev_lpc_q12[0..order]);
            var down: i32 = @min((@as(i32, 1) << 30) >> 3, inv_gain_q30);
            down = @max((@as(i32, 1) << 30) >> 8, down);
            down <<= 3;
            rand_gain_q15 = fix.smulwb(down, rand_gain_q15) >> 14;
        }
    }

    var rand_seed = p.rand_seed;
    var lag: usize = @intCast(fix.rshiftRound(p.pitch_l_q8, 8));
    var sltp_buf_idx: usize = ltp_mem;

    const start = ltp_mem - lag - order - ltp_order / 2;
    lpc.analysisFilter(sltp[start..], ch.out_buf[start..], &a_q12, ltp_mem - start, order);
    var inv_gain_q30 = fix.inverse32VarQ(p.prev_gain_q16[1], 46);
    inv_gain_q30 = @min(inv_gain_q30, 0x7FFF_FFFF >> 1);
    for (start + order..ltp_mem) |i| sltp_q14[i] = fix.smulwb(inv_gain_q30, sltp[i]);

    for (0..ch.nb_subfr) |_| {
        var pred = sltp_buf_idx - lag + ltp_order / 2;
        for (0..subfr) |_| {
            var ltp_pred_q12: i32 = 2;
            inline for (0..ltp_order) |j| ltp_pred_q12 = fix.smlawb(ltp_pred_q12, sltp_q14[pred - j], b_q14[j]);
            pred += 1;
            rand_seed = fix.rand(rand_seed);
            const idx: usize = @intCast((rand_seed >> 25) & (rand_buf_size - 1));
            sltp_q14[sltp_buf_idx] = fix.smlawb(ltp_pred_q12, rand_ptr[idx], rand_scale_q14) << 2;
            sltp_buf_idx += 1;
        }
        // Both fade, and the pitch drifts down.
        for (b_q14) |*b| b.* = @truncate(fix.smulbb(harm_gain_q15, b.*) >> 15);
        rand_scale_q14 = @truncate(fix.smulbb(rand_scale_q14, rand_gain_q15) >> 15);
        p.pitch_l_q8 = fix.smlawb(p.pitch_l_q8, p.pitch_l_q8, 655);
        p.pitch_l_q8 = @min(p.pitch_l_q8, @as(i32, @intCast((18 * ch.fs_khz) << 8)));
        lag = @intCast(fix.rshiftRound(p.pitch_l_q8, 8));
    }

    // The LPC synthesis in place of the LTP output.
    const slpc = sltp_q14[ltp_mem - max_lpc_order ..];
    slpc[0..max_lpc_order].* = ch.slpc_q14_buf;
    for (0..ch.frame_length) |i| {
        var lpc_pred_q10: i32 = @intCast(order >> 1);
        for (0..order) |j| lpc_pred_q10 = fix.smlawb(lpc_pred_q10, slpc[max_lpc_order + i - j - 1], a_q12[j]);
        slpc[max_lpc_order + i] = fix.addSat32(slpc[max_lpc_order + i], fix.lshiftSat32(lpc_pred_q10, 4));
        out[i] = fix.sat16(fix.rshiftRound(fix.smulww(slpc[max_lpc_order + i], prev_gain_q10[1]), 8));
    }
    ch.slpc_q14_buf = slpc[ch.frame_length..][0..max_lpc_order].*;

    p.rand_seed = rand_seed;
    p.rand_scale_q14 = rand_scale_q14;
    for (&ctrl.pitch_l) |*l| l.* = @intCast(lag);
}

/// The first good frame after a loss fades in from the concealment's
/// energy when it is louder.
pub fn glueFrames(ch: *Channel, out: []i16) void {
    const p = &ch.plc;
    if (ch.loss_cnt != 0) {
        const e = fix.sumSqrShift(out);
        p.conc_energy = e.energy;
        p.conc_energy_shift = e.shift;
        p.last_frame_lost = true;
        return;
    }
    if (p.last_frame_lost) {
        const e = fix.sumSqrShift(out);
        var energy = e.energy;
        if (e.shift > p.conc_energy_shift) {
            p.conc_energy >>= e.shift - p.conc_energy_shift;
        } else if (e.shift < p.conc_energy_shift) {
            energy >>= p.conc_energy_shift - e.shift;
        }
        if (energy > p.conc_energy) {
            const lz = fix.clz32(p.conc_energy) - 1;
            p.conc_energy = fix.lshift(p.conc_energy, @intCast(lz));
            energy >>= @intCast(@max(24 - lz, 0));
            const frac_q24 = @divTrunc(p.conc_energy, @max(energy, 1));
            var gain_q16 = fix.sqrtApprox(frac_q24) << 4;
            var slope_q16 = @divTrunc((@as(i32, 1) << 16) - gain_q16, @as(i32, @intCast(out.len)));
            // Four times as steep, not to lose an onset after silence.
            slope_q16 <<= 2;
            for (out) |*s| {
                s.* = @truncate(fix.smulwb(gain_q16, s.*));
                gain_q16 += slope_q16;
                if (gain_q16 > 1 << 16) break;
            }
        }
    }
    p.last_frame_lost = false;
}

pub fn cngReset(ch: *Channel) void {
    const step: i32 = @divTrunc(32767, @as(i32, @intCast(ch.lpc_order + 1)));
    var acc: i32 = 0;
    for (0..ch.lpc_order) |i| {
        acc += step;
        ch.cng.smth_nlsf_q15[i] = @intCast(acc);
    }
    ch.cng.smth_gain_q16 = 0;
    ch.cng.rand_seed = 3176576;
}

/// Comfort noise: its spectrum and level followed while frames are
/// inactive, added to a concealed frame.
pub fn cng(ch: *Channel, ctrl: *const Control, out: []i16) void {
    const c = &ch.cng;
    const order = ch.lpc_order;
    if (ch.fs_khz != c.fs_khz) {
        cngReset(ch);
        c.fs_khz = ch.fs_khz;
    }
    if (ch.loss_cnt == 0 and ch.prev_signal_type == frame.type_no_voice_activity) {
        for (0..order) |i| {
            const d = @as(i32, ch.prev_nlsf_q15[i]) - c.smth_nlsf_q15[i];
            c.smth_nlsf_q15[i] = @truncate(c.smth_nlsf_q15[i] + fix.smulwb(d, 16348));
        }
        // The loudest subframe's excitation goes to the noise buffer.
        var max_gain: i32 = 0;
        var subfr: usize = 0;
        for (0..ch.nb_subfr) |i| {
            if (ctrl.gains_q16[i] > max_gain) {
                max_gain = ctrl.gains_q16[i];
                subfr = i;
            }
        }
        const sl = ch.subfr_length;
        var i: usize = (ch.nb_subfr - 1) * sl;
        while (i > 0) {
            i -= 1;
            c.exc_buf_q14[i + sl] = c.exc_buf_q14[i];
        }
        @memcpy(c.exc_buf_q14[0..sl], ch.exc_q14[subfr * sl ..][0..sl]);
        for (0..ch.nb_subfr) |k| {
            c.smth_gain_q16 +%= fix.smulwb(ctrl.gains_q16[k] -% c.smth_gain_q16, 4634);
            // 3 dB above this subframe's gain: follow it at once.
            if (fix.smulww(c.smth_gain_q16, 46396) > ctrl.gains_q16[k]) c.smth_gain_q16 = ctrl.gains_q16[k];
        }
    }

    if (ch.loss_cnt == 0) {
        @memset(c.synth_state[0..order], 0);
        return;
    }

    var gain_q16 = fix.smulww(ch.plc.rand_scale_q14, ch.plc.prev_gain_q16[1]);
    if (gain_q16 >= 1 << 21 or c.smth_gain_q16 > 1 << 23) {
        gain_q16 = fix.smultt(gain_q16, gain_q16);
        gain_q16 = fix.smultt(c.smth_gain_q16, c.smth_gain_q16) -% fix.lshift(gain_q16, 5);
        gain_q16 = fix.lshift(fix.sqrtApprox(gain_q16), 16);
    } else {
        gain_q16 = fix.smulww(gain_q16, gain_q16);
        gain_q16 = fix.smulww(c.smth_gain_q16, c.smth_gain_q16) -% fix.lshift(gain_q16, 5);
        gain_q16 = fix.lshift(fix.sqrtApprox(gain_q16), 8);
    }
    const gain_q10 = gain_q16 >> 6;

    var sig: [frame.max_frame_length + max_lpc_order]i32 = undefined;
    var mask: usize = 255;
    while (mask > out.len) mask >>= 1;
    var seed = c.rand_seed;
    for (0..out.len) |i| {
        seed = fix.rand(seed);
        sig[max_lpc_order + i] = c.exc_buf_q14[@as(usize, @intCast((seed >> 24) & 0xFF)) & mask];
    }
    c.rand_seed = seed;

    var a_q12: [max_lpc_order]i16 = undefined;
    lpc.nlsf2a(&a_q12, &c.smth_nlsf_q15, order);
    sig[0..max_lpc_order].* = c.synth_state;
    for (0..out.len) |i| {
        var lpc_pred_q10: i32 = @intCast(order >> 1);
        for (0..order) |j| lpc_pred_q10 = fix.smlawb(lpc_pred_q10, sig[max_lpc_order + i - j - 1], a_q12[j]);
        sig[max_lpc_order + i] = fix.addSat32(sig[max_lpc_order + i], fix.lshiftSat32(lpc_pred_q10, 4));
        const n = fix.sat16(fix.rshiftRound(fix.smulww(sig[max_lpc_order + i], gain_q10), 8));
        out[i] = fix.sat16(@as(i32, out[i]) + n);
    }
    c.synth_state = sig[out.len..][0..max_lpc_order].*;
}
