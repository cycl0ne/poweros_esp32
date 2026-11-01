// SPDX-License-Identifier: MIT
//! SILK's packet layer (RFC 6716 4.2): the VAD and LBRR flags of the
//! frames a packet holds (10 to 60 ms), the low-bitrate redundant copies
//! skipped, stereo as mid and side with a predictor from mid to side, and
//! each frame resampled to 48 kHz.

const fix = @import("silk_fix.zig");
const tables = @import("silk_tables.zig");
const frame = @import("silk_frame.zig");
const Range = @import("range.zig").Range;

pub const Lost = frame.Lost;

/// What the Opus layer says of the frame it hands over.
pub const Control = struct {
    /// The channels wanted: 1 or 2.
    channels_api: u32,
    /// The channels coded.
    channels_internal: u32,
    /// 8000, 12000 or 16000.
    internal_sample_rate: u32,
    /// 10, 20, 40 or 60.
    payload_size_ms: u32,
};

const Stereo = struct {
    pred_prev_q13: [2]i16 = @splat(0),
    s_mid: [2]i16 = @splat(0),
    s_side: [2]i16 = @splat(0),
};

pub const Decoder = struct {
    channel: [2]frame.Channel,
    stereo: Stereo,
    channels_api: u32,
    channels_internal: u32,
    prev_decode_only_middle: bool,
    scratch: frame.Scratch,
    /// Each channel's frame two samples in, for the stereo filter's
    /// history; a channel at 48 kHz before it is interleaved.
    mid_side: [2][frame.max_frame_length + 2]i16,
    resampled: [960]i16,

    pub fn init(d: *Decoder) void {
        d.reset();
        d.channels_api = 0;
        d.channels_internal = 0;
    }

    pub fn reset(d: *Decoder) void {
        for (&d.channel) |*ch| ch.reset();
        d.stereo = .{};
        d.prev_decode_only_middle = false;
    }

    /// One frame of the packet (the first when `new_packet`) to `out` at
    /// 48 kHz, `channels_api` interleaved; its samples a channel, or null
    /// for a frame length the decoder has not.
    pub fn decode(d: *Decoder, ctl: *const Control, lost: Lost, new_packet: bool, dec: *Range, out: []i16) ?u32 {
        const chans = &d.channel;
        const internal = ctl.channels_internal;
        if (new_packet) {
            for (chans[0..internal]) |*ch| ch.frames_decoded = 0;
        }
        // A second channel starting: its decoder starts clean.
        if (internal > d.channels_internal) chans[1].reset();

        const stereo_to_mono = internal == 1 and d.channels_internal == 2 and ctl.internal_sample_rate == 1000 * chans[0].fs_khz;

        if (chans[0].frames_decoded == 0) {
            for (chans[0..internal]) |*ch| {
                switch (ctl.payload_size_ms) {
                    0, 10 => {
                        ch.frames_per_packet = 1;
                        ch.nb_subfr = 2;
                    },
                    20 => {
                        ch.frames_per_packet = 1;
                        ch.nb_subfr = 4;
                    },
                    40 => {
                        ch.frames_per_packet = 2;
                        ch.nb_subfr = 4;
                    },
                    60 => {
                        ch.frames_per_packet = 3;
                        ch.nb_subfr = 4;
                    },
                    else => return null,
                }
                const fs_khz = (ctl.internal_sample_rate >> 10) + 1;
                if (fs_khz != 8 and fs_khz != 12 and fs_khz != 16) return null;
                ch.setFs(fs_khz, 48000);
            }
        }

        if (ctl.channels_api == 2 and internal == 2 and (d.channels_api == 1 or d.channels_internal == 1)) {
            d.stereo.pred_prev_q13 = @splat(0);
            d.stereo.s_side = @splat(0);
            chans[1].resampler = chans[0].resampler;
        }
        d.channels_api = ctl.channels_api;
        d.channels_internal = internal;

        var ms_pred_q13 = [2]i32{ 0, 0 };
        var decode_only_middle = false;
        if (lost != .lost and chans[0].frames_decoded == 0) {
            // The packet's flags: VAD per frame and LBRR per channel, then
            // which frames have an LBRR copy.
            for (chans[0..internal]) |*ch| {
                for (0..ch.frames_per_packet) |i| ch.vad_flags[i] = dec.bitLogp(1);
                ch.lbrr_flag = dec.bitLogp(1);
            }
            for (chans[0..internal]) |*ch| {
                ch.lbrr_flags = @splat(false);
                if (!ch.lbrr_flag) continue;
                if (ch.frames_per_packet == 1) {
                    ch.lbrr_flags[0] = true;
                } else {
                    const symbol = dec.icdf(tables.lbrr_flags_icdf[ch.frames_per_packet - 2], 8) + 1;
                    for (0..ch.frames_per_packet) |i| ch.lbrr_flags[i] = (symbol >> @intCast(i)) & 1 != 0;
                }
            }
            if (lost == .normal) {
                // The LBRR frames are read past.
                var pulses: [frame.max_frame_length]i16 = undefined;
                for (0..chans[0].frames_per_packet) |i| {
                    for (chans[0..internal], 0..) |*ch, n| {
                        if (!ch.lbrr_flags[i]) continue;
                        if (internal == 2 and n == 0) {
                            stereoDecodePred(dec, &ms_pred_q13);
                            if (!chans[1].lbrr_flags[i]) decode_only_middle = dec.icdf(&tables.stereo_only_code_mid_icdf, 8) != 0;
                        }
                        const cond: frame.CondCoding = if (i > 0 and ch.lbrr_flags[i - 1]) .conditionally else .independently;
                        frame.decodeIndices(ch, dec, i, true, cond);
                        frame.decodePulses(dec, &pulses, ch.indices.signal_type, ch.indices.quant_offset_type, ch.frame_length);
                    }
                }
            }
        }

        if (internal == 2) {
            const fi = chans[0].frames_decoded;
            if (lost == .normal or (lost == .lbrr and chans[0].lbrr_flags[fi])) {
                stereoDecodePred(dec, &ms_pred_q13);
                // Mid only, unless the side has a frame here.
                if ((lost == .normal and !chans[1].vad_flags[fi]) or (lost == .lbrr and !chans[1].lbrr_flags[fi])) {
                    decode_only_middle = dec.icdf(&tables.stereo_only_code_mid_icdf, 8) != 0;
                } else {
                    decode_only_middle = false;
                }
            } else {
                ms_pred_q13 = .{ d.stereo.pred_prev_q13[0], d.stereo.pred_prev_q13[1] };
            }
        }

        if (internal == 2 and !decode_only_middle and d.prev_decode_only_middle) chans[1].resetSide();

        const tmp = &d.mid_side;
        const has_side = if (lost == .normal)
            !decode_only_middle
        else
            !d.prev_decode_only_middle or (internal == 2 and lost == .lbrr and chans[1].lbrr_flags[chans[1].frames_decoded]);

        var n_dec: u32 = 0;
        for (chans[0..internal], 0..) |*ch, n| {
            if (n == 0 or has_side) {
                const frame_index = @as(i32, @intCast(chans[0].frames_decoded)) - @as(i32, @intCast(n));
                const cond: frame.CondCoding = if (frame_index <= 0)
                    .independently
                else if (lost == .lbrr)
                    (if (ch.lbrr_flags[@intCast(frame_index - 1)]) .conditionally else .independently)
                else if (n > 0 and d.prev_decode_only_middle)
                    // A side frame skipped in this packet leaves the LTP
                    // state well defined.
                    .independently_no_ltp_scaling
                else
                    .conditionally;
                n_dec = frame.decodeFrame(ch, dec, tmp[n][2..], lost, cond, &d.scratch);
            } else {
                @memset(tmp[n][2..][0..n_dec], 0);
            }
            ch.frames_decoded += 1;
        }

        if (ctl.channels_api == 2 and internal == 2) {
            msToLr(&d.stereo, &tmp[0], &tmp[1], &ms_pred_q13, chans[0].fs_khz, n_dec);
        } else {
            tmp[0][0..2].* = d.stereo.s_mid;
            d.stereo.s_mid = tmp[0][n_dec..][0..2].*;
        }

        const n_out = n_dec * 48 / chans[0].fs_khz;
        const resampled = &d.resampled;
        const api = ctl.channels_api;
        for (0..@min(api, internal)) |n| {
            const dst: []i16 = if (api == 2) resampled else out;
            chans[n].resampler.process(dst, tmp[n][1..][0..n_dec]);
            if (api == 2) {
                for (0..n_out) |i| out[n + 2 * i] = resampled[i];
            }
        }
        if (api == 2 and internal == 1) {
            if (stereo_to_mono) {
                // The right channel's resampler, in case the stream was
                // not collapsing before it went mono.
                chans[1].resampler.process(resampled, tmp[0][1..][0..n_dec]);
                for (0..n_out) |i| out[1 + 2 * i] = resampled[i];
            } else {
                for (0..n_out) |i| out[1 + 2 * i] = out[2 * i];
            }
        }

        if (lost == .lost) {
            // No gain floor after a loss: the level may be falling.
            for (chans[0..d.channels_internal]) |*ch| ch.last_gain_index = 10;
        } else {
            d.prev_decode_only_middle = decode_only_middle;
        }
        return n_out;
    }
};

/// The two stereo predictors.
fn stereoDecodePred(dec: *Range, pred_q13: *[2]i32) void {
    var ix: [2][3]i32 = undefined;
    const n: i32 = @intCast(dec.icdf(&tables.stereo_pred_joint_icdf, 8));
    ix[0][2] = @divTrunc(n, 5);
    ix[1][2] = n - 5 * ix[0][2];
    for (0..2) |k| {
        ix[k][0] = @intCast(dec.icdf(&tables.uniform3_icdf, 8));
        ix[k][1] = @intCast(dec.icdf(&tables.uniform5_icdf, 8));
    }
    for (0..2) |k| {
        ix[k][0] += 3 * ix[k][2];
        const at: usize = @intCast(ix[k][0]);
        const low: i32 = tables.stereo_pred_quant_q13[at];
        const step = fix.smulwb(@as(i32, tables.stereo_pred_quant_q13[at + 1]) - low, 6554);
        pred_q13[k] = fix.smlabb(low, step, 2 * ix[k][1] + 1);
    }
    // The second taken from the first helps when they are applied.
    pred_q13[0] -= pred_q13[1];
}

/// Mid and side to left and right: the side plus the predictions from
/// mid (interpolated over the first 8 ms), one sample behind.
fn msToLr(st: *Stereo, x1: []i16, x2: []i16, pred_q13: *const [2]i32, fs_khz: u32, len: u32) void {
    x1[0..2].* = st.s_mid;
    x2[0..2].* = st.s_side;
    st.s_mid = x1[len..][0..2].*;
    st.s_side = x2[len..][0..2].*;

    var pred0: i32 = st.pred_prev_q13[0];
    var pred1: i32 = st.pred_prev_q13[1];
    const interp = 8 * fs_khz;
    const denom_q16: i32 = @divTrunc(@as(i32, 1) << 16, @as(i32, @intCast(interp)));
    const delta0 = fix.rshiftRound(fix.smulbb(pred_q13[0] - st.pred_prev_q13[0], denom_q16), 16);
    const delta1 = fix.rshiftRound(fix.smulbb(pred_q13[1] - st.pred_prev_q13[1], denom_q16), 16);
    for (0..len) |n| {
        if (n < interp) {
            pred0 += delta0;
            pred1 += delta1;
        } else if (n == interp) {
            pred0 = pred_q13[0];
            pred1 = pred_q13[1];
        }
        var sum = fix.lshift((@as(i32, x1[n]) + x1[n + 2]) + (@as(i32, x1[n + 1]) << 1), 9);
        sum = fix.smlawb(@as(i32, x2[n + 1]) << 8, sum, pred0);
        sum = fix.smlawb(sum, @as(i32, x1[n + 1]) << 11, pred1);
        x2[n + 1] = fix.sat16(fix.rshiftRound(sum, 8));
    }
    st.pred_prev_q13 = .{ @truncate(pred_q13[0]), @truncate(pred_q13[1]) };

    for (0..len) |n| {
        const s = @as(i32, x1[n + 1]) + x2[n + 1];
        const df = @as(i32, x1[n + 1]) - x2[n + 1];
        x1[n + 1] = fix.sat16(s);
        x2[n + 1] = fix.sat16(df);
    }
}
