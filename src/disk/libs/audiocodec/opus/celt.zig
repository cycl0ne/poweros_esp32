// SPDX-License-Identifier: MIT
//! The CELT layer of Opus (RFC 6716 4.3): a frame of 2.5 to 20 ms read as
//! its global flags, band energies, time-frequency changes, spreading,
//! bit allocation and band shapes; the spectrum scaled, inverse MDCT'd
//! and overlapped with the frame before; the pitch post-filter run over
//! it; and the pre-emphasis undone.
//!
//! **The state** of each channel is 2048 samples of the signal decoded,
//! and the overlap past them, which the next frame finishes - and which
//! the loss concealment extends a pitch period at a time; the band
//! energies of the last frames, which the next one is predicted from;
//! the post-filter's period, gain and taps.
//!
//! **A frame lost** - none given - is concealed: the first loss repeats
//! the last pitch period found in the signal, through an LPC filter
//! fitted to it, fading; longer losses, or a hybrid frame's high bands,
//! become noise at the energies last decoded, falling. Opus asks for this
//! when it changes between SILK and CELT, to cross-fade.
//!
//! Hybrid frames decode bands 17 up (`start`), and narrower bandwidths
//! stop early (`end`). A mono frame may be played into two channels and a
//! stereo one into one.

const tables = @import("celt_tables.zig");
const Range = @import("range.zig").Range;
const alloc = @import("celt_alloc.zig");
const energy = @import("celt_energy.zig");
const bands = @import("celt_bands.zig");
const pvq = @import("celt_pvq.zig");
const mdct = @import("mdct.zig");

const nb = tables.bands;
pub const buffer_size = 2048;
const overlap = tables.overlap;
const lpc_order = 24;
const max_period = 1024;
const plc_pitch_lag_max = 720;
const plc_pitch_lag_min = 100;
const comb_min_period = 15;
const bitres = alloc.bitres;

/// Room the frames are worked in, kept off the task's stack: a frame's
/// shapes, a band's spectrum and the folding copies while decoding; the
/// concealment's excitation and its filtered and windowed copies, or the
/// signals of its pitch search.
const Work = extern union {
    decode: extern struct {
        x: [2 * 960]f32,
        freq: [960]f32,
        norm: [bands.norm_size]f32,
    },
    plc: extern struct {
        exc: [max_period + lpc_order]f32,
        fir_tmp: [max_period]f32,
        windowed: [max_period]f32,
    },
    pitch: extern struct {
        lp: [buffer_size >> 1]f32,
        x_lp4: [(buffer_size - plc_pitch_lag_max) >> 2]f32,
        y_lp4: [buffer_size >> 2]f32,
        xcorr: [plc_pitch_lag_max >> 1]f32,
    },
};

pub const Celt = struct {
    /// The channels played into, and those the frames carry.
    channels: u32,
    stream_channels: u32,
    /// The bands decoded: from 17 in a hybrid frame, up to the bandwidth.
    start: u32,
    end: u32,
    /// Mono: a stereo frame's side is never inverted.
    disable_inv: bool,

    // Cleared when the decoder is reset.
    rng: u32,
    loss_duration: i32,
    skip_plc: bool,
    last_pitch_index: i32,
    postfilter_period: i32,
    postfilter_period_old: i32,
    postfilter_gain: f32,
    postfilter_gain_old: f32,
    postfilter_tapset: u32,
    postfilter_tapset_old: u32,
    prefilter_and_fold: bool,
    preemph_mem: [2]f32,
    decode_mem: [2][buffer_size + overlap]f32,
    lpc: [2][lpc_order]f32,
    old_band_e: [2 * nb]f32,
    old_log_e: [2 * nb]f32,
    old_log_e2: [2 * nb]f32,
    background_log_e: [2 * nb]f32,
    work: Work,
};

pub fn init(st: *Celt, channels: u32) void {
    st.channels = channels;
    st.stream_channels = channels;
    st.start = 0;
    st.end = nb;
    st.disable_inv = channels == 1;
    reset(st);
}

/// Everything the frames left behind forgotten.
pub fn reset(st: *Celt) void {
    st.rng = 0;
    st.loss_duration = 0;
    st.last_pitch_index = 0;
    st.postfilter_period = 0;
    st.postfilter_period_old = 0;
    st.postfilter_gain = 0;
    st.postfilter_gain_old = 0;
    st.postfilter_tapset = 0;
    st.postfilter_tapset_old = 0;
    st.prefilter_and_fold = false;
    st.preemph_mem = .{ 0, 0 };
    st.decode_mem = @splat(@splat(0));
    st.lpc = @splat(@splat(0));
    st.old_band_e = @splat(0);
    st.old_log_e = @splat(-28.0);
    st.old_log_e2 = @splat(-28.0);
    st.background_log_e = @splat(0);
    st.skip_plc = true;
}

// --- the pitch post-filter --------------------------------------------------------

const comb_gains = [3][3]f32{
    .{ 0.3066406250, 0.2170410156, 0.1296386719 },
    .{ 0.4638671875, 0.2680664062, 0.0 },
    .{ 0.7998046875, 0.1000976562, 0.0 },
};

/// The comb filter from x into y over n samples - y may be x - its
/// period, gain and taps changing from the first set to the second over
/// the overlap, through the window squared. x reaches back a period and
/// two.
fn combFilter(y: [*]f32, x: [*]f32, t0_in: i32, t1_in: i32, n: usize, g0: f32, g1: f32, tapset0: u32, tapset1: u32, window: ?[*]const f32, overlap_in: usize) void {
    if (g0 == 0 and g1 == 0) {
        if (x != y) copyForward(y, x, n);
        return;
    }
    const t0: usize = @intCast(@max(t0_in, comb_min_period));
    const t1: usize = @intCast(@max(t1_in, comb_min_period));
    const g00 = g0 * comb_gains[tapset0][0];
    const g01 = g0 * comb_gains[tapset0][1];
    const g02 = g0 * comb_gains[tapset0][2];
    const g10 = g1 * comb_gains[tapset1][0];
    const g11 = g1 * comb_gains[tapset1][1];
    const g12 = g1 * comb_gains[tapset1][2];
    const xb = x - t1;
    var x1 = (xb + 1)[0];
    var x2 = xb[0];
    var x3 = (xb - 1)[0];
    var x4 = (xb - 2)[0];
    var ov = overlap_in;
    if (g0 == g1 and t0 == t1 and tapset0 == tapset1) ov = 0;
    var i: usize = 0;
    while (i < ov) : (i += 1) {
        const x0 = (x + i - t1 + 2)[0];
        const w = window.?[i];
        const f = w * w;
        const xa = x + i - t0;
        y[i] = x[i] + ((1.0 - f) * g00) * xa[0] +
            ((1.0 - f) * g01) * ((xa + 1)[0] + (xa - 1)[0]) +
            ((1.0 - f) * g02) * ((xa + 2)[0] + (xa - 2)[0]) +
            (f * g10) * x2 + (f * g11) * (x1 + x3) + (f * g12) * (x0 + x4);
        x4 = x3;
        x3 = x2;
        x2 = x1;
        x1 = x0;
    }
    if (g1 == 0) {
        if (x != y) copyForward(y + ov, x + ov, n - ov);
        return;
    }
    // The rest with the second filter alone.
    while (i < n) : (i += 1) {
        const x0 = (x + i - t1 + 2)[0];
        y[i] = x[i] + g10 * x2 + g11 * (x1 + x3) + g12 * (x0 + x4);
        x4 = x3;
        x3 = x2;
        x2 = x1;
        x1 = x0;
    }
}

fn copyForward(to: [*]f32, from: [*]const f32, count: usize) void {
    for (0..count) |k| to[k] = from[k];
}

fn copyBackward(to: [*]f32, from: [*]const f32, count: usize) void {
    var k = count;
    while (k > 0) {
        k -= 1;
        to[k] = from[k];
    }
}

/// The decoded signal moved `n` to the left to make room for a frame.
fn shiftMemory(st: *Celt, n: usize, length: usize) void {
    for (0..st.channels) |c| {
        const mem: [*]f32 = &st.decode_mem[c];
        copyForward(mem, mem + n, length);
    }
}

// --- synthesis --------------------------------------------------------------------

/// The shapes `x` into the signal from `out_at` on in each channel's
/// memory: scaled by the energies, transformed, overlapped.
fn synthesis(st: *Celt, x: [*]f32, out_at: usize, start: u32, eff_end: u32, c_stream: u32, cc: u32, transient: bool, lm: u32, silence: bool) void {
    const m: u32 = @as(u32, 1) << @intCast(lm);
    const n: usize = tables.short_mdct << @intCast(lm);
    const freq = &st.work.decode.freq;
    var b_count: usize = 1;
    var nb_step: usize = n;
    var shift: u2 = @intCast(tables.max_lm - lm);
    if (transient) {
        b_count = m;
        nb_step = tables.short_mdct;
        shift = tables.max_lm;
    }
    const half = overlap / 2;
    if (cc == 2 and c_stream == 1) {
        // A mono frame into two channels: the transform eats its input,
        // so a copy waits in the second channel's output.
        bands.denormalise(x, freq, &st.old_band_e, start, eff_end, m, 1, silence);
        const freq2: [*]f32 = @as([*]f32, &st.decode_mem[1]) + out_at + half;
        copyForward(freq2, freq, n);
        for (0..b_count) |b| mdct.backward(freq2 + b, @as([*]f32, &st.decode_mem[0]) + out_at + nb_step * b, shift, b_count);
        for (0..b_count) |b| mdct.backward(@as([*]f32, freq) + b, @as([*]f32, &st.decode_mem[1]) + out_at + nb_step * b, shift, b_count);
    } else if (cc == 1 and c_stream == 2) {
        // A stereo frame into one channel: both spectra halved and added.
        const freq2: [*]f32 = @as([*]f32, &st.decode_mem[0]) + out_at + half;
        bands.denormalise(x, freq, &st.old_band_e, start, eff_end, m, 1, silence);
        bands.denormalise(x + n, freq2, @as([*]const f32, &st.old_band_e) + nb, start, eff_end, m, 1, silence);
        for (0..n) |i| freq[i] = 0.5 * freq[i] + 0.5 * freq2[i];
        for (0..b_count) |b| mdct.backward(@as([*]f32, freq) + b, @as([*]f32, &st.decode_mem[0]) + out_at + nb_step * b, shift, b_count);
    } else {
        for (0..cc) |c| {
            bands.denormalise(x + c * n, freq, @as([*]const f32, &st.old_band_e) + c * nb, start, eff_end, m, 1, silence);
            for (0..b_count) |b| mdct.backward(@as([*]f32, freq) + b, @as([*]f32, &st.decode_mem[c]) + out_at + nb_step * b, shift, b_count);
        }
    }
}

/// The pre-emphasis undone: `n` samples of each channel's signal from
/// `at` into `pcm`, interleaved, at full scale 1.
fn deemphasis(st: *Celt, at: usize, pcm: [*]f32, n: usize) void {
    const cc = st.channels;
    for (0..cc) |c| {
        const x: [*]const f32 = @as([*]const f32, &st.decode_mem[c]) + at;
        var m = st.preemph_mem[c];
        for (0..n) |j| {
            const tmp = x[j] + 1e-30 + m;
            m = tables.preemph * tmp;
            pcm[j * cc + c] = tmp * (1.0 / 32768.0);
        }
        st.preemph_mem[c] = m;
    }
}

// --- frames -----------------------------------------------------------------------

fn tfDecode(start: u32, end: u32, transient: bool, tf_res: *[nb]i32, lm: u32, dec: *Range) void {
    var budget: u32 = dec.storage * 8;
    var tell: u32 = @intCast(dec.tell());
    var logp: u5 = if (transient) 2 else 4;
    const tf_select_rsv = lm > 0 and tell + logp + 1 <= budget;
    budget -= @intFromBool(tf_select_rsv);
    var tf_changed: i32 = 0;
    var curr: i32 = 0;
    for (start..end) |i| {
        if (tell + logp <= budget) {
            curr ^= @intFromBool(dec.bitLogp(logp));
            tell = @intCast(dec.tell());
            tf_changed |= curr;
        }
        tf_res[i] = curr;
        logp = if (transient) 4 else 5;
    }
    var tf_select: u32 = 0;
    const row = &tables.tf_select_table[lm];
    const base: usize = 4 * @as(usize, @intFromBool(transient));
    if (tf_select_rsv and row[base + @as(usize, @intCast(tf_changed))] != row[base + 2 + @as(usize, @intCast(tf_changed))]) {
        tf_select = @intFromBool(dec.bitLogp(1));
    }
    for (start..end) |i| tf_res[i] = row[base + 2 * tf_select + @as(usize, @intCast(tf_res[i]))];
}

/// A frame of `frame_size` samples (120 to 960) into `pcm`, interleaved
/// in `channels`: from `data`, read through `dec` when Opus has begun it
/// (a hybrid frame's SILK part came first), or concealed when there is
/// no data. False when the frame is damaged.
pub fn decode(st: *Celt, data: ?[]const u8, pcm: [*]f32, frame_size: usize, dec_in: ?*Range) bool {
    const cc = st.channels;
    const c_stream = st.stream_channels;
    const start = st.start;
    const end = st.end;
    var lm: u32 = 0;
    while (lm <= tables.max_lm) : (lm += 1) {
        if (tables.short_mdct << @intCast(lm) == frame_size) break;
    }
    if (lm > tables.max_lm) return false;
    const m: u32 = @as(u32, 1) << @intCast(lm);
    const n: usize = frame_size;
    const out_at = buffer_size - n;
    const eff_end = @min(end, nb);

    const bytes = data orelse &[_]u8{};
    if (data == null or bytes.len <= 1) {
        decodeLost(st, n, lm);
        deemphasis(st, out_at, pcm, n);
        return true;
    }
    if (bytes.len > 1275) return false;
    // A loss is concealed with the pitch only after two frames in a row.
    if (st.loss_duration == 0) st.skip_plc = false;

    var own: Range = undefined;
    const dec = dec_in orelse blk: {
        own = Range.init(bytes);
        break :blk &own;
    };

    if (c_stream == 1) {
        for (0..nb) |i| st.old_band_e[i] = @max(st.old_band_e[i], st.old_band_e[nb + i]);
    }
    var total_bits: i32 = @intCast(bytes.len * 8);
    var tell = dec.tell();
    var silence = false;
    if (tell >= total_bits) {
        silence = true;
    } else if (tell == 1) {
        silence = dec.bitLogp(15);
    }
    if (silence) {
        // As if every bit was read.
        tell = @intCast(bytes.len * 8);
        dec.nbits_total += tell - dec.tell();
    }

    var postfilter_gain: f32 = 0;
    var postfilter_pitch: i32 = 0;
    var postfilter_tapset: u32 = 0;
    if (start == 0 and tell + 16 <= total_bits) {
        if (dec.bitLogp(1)) {
            const octave = dec.uint(6);
            postfilter_pitch = @as(i32, @intCast((@as(u32, 16) << @intCast(octave)) + dec.bits(@intCast(4 + octave)))) - 1;
            const qg = dec.bits(3);
            if (dec.tell() + 2 <= total_bits) postfilter_tapset = dec.icdf(&tables.tapset_icdf, 2);
            postfilter_gain = 0.09375 * @as(f32, @floatFromInt(qg + 1));
        }
        tell = dec.tell();
    }

    var transient = false;
    if (lm > 0 and tell + 3 <= total_bits) {
        transient = dec.bitLogp(3);
        tell = dec.tell();
    }
    const intra_ener = if (tell + 3 <= total_bits) dec.bitLogp(3) else false;

    if (!intra_ener and st.loss_duration != 0) {
        // After a loss, the prediction made safe.
        for (0..2) |c| {
            const missing: i32 = @min(10, st.loss_duration >> @intCast(lm));
            const safety: f32 = if (lm == 0) 1.5 else if (lm == 1) 0.5 else 0;
            for (start..end) |i| {
                const at = c * nb + i;
                if (st.old_band_e[at] < @max(st.old_log_e[at], st.old_log_e2[at])) {
                    var e0 = st.old_band_e[at];
                    const e1 = st.old_log_e[at];
                    const e2 = st.old_log_e2[at];
                    const slope = @max(e1 - e0, 0.5 * (e2 - e0));
                    e0 -= @max(0, @as(f32, @floatFromInt(1 + missing)) * slope);
                    st.old_band_e[at] = @max(-20.0, e0);
                } else {
                    st.old_band_e[at] = @min(@min(st.old_band_e[at], st.old_log_e[at]), st.old_log_e2[at]);
                }
                st.old_band_e[at] -= safety;
            }
        }
    }

    energy.coarse(start, end, &st.old_band_e, intra_ener, dec, c_stream, lm);

    var tf_res: [nb]i32 = undefined;
    tfDecode(start, end, transient, &tf_res, lm, dec);

    tell = dec.tell();
    var spread: u32 = pvq.spread_normal;
    if (tell + 4 <= total_bits) spread = dec.icdf(&tables.spread_icdf, 5);

    var cap: [nb]i32 = undefined;
    alloc.initCaps(&cap, lm, c_stream);
    var offsets: [nb]i32 = @splat(0);
    var dynalloc_logp: u32 = 6;
    total_bits <<= bitres;
    var tell_frac: i32 = @intCast(dec.tellFrac());
    for (start..end) |i| {
        const width: i32 = @as(i32, @intCast(c_stream)) * (tables.e_bands[i + 1] - tables.e_bands[i]) << @intCast(lm);
        // A boost step is 6 bits, but no more than 1 bit a sample and
        // no less than 1/8.
        const quanta: i32 = @min(width << bitres, @max(6 << bitres, width));
        var loop_logp = dynalloc_logp;
        var boost: i32 = 0;
        while (tell_frac + (@as(i32, @intCast(loop_logp)) << bitres) < total_bits and boost < cap[i]) {
            const flag = dec.bitLogp(@intCast(loop_logp));
            tell_frac = @intCast(dec.tellFrac());
            if (!flag) break;
            boost += quanta;
            total_bits -= quanta;
            loop_logp = 1;
        }
        offsets[i] = boost;
        if (boost > 0) dynalloc_logp = @max(2, dynalloc_logp - 1);
    }

    const alloc_trim: i32 = if (tell_frac + (6 << bitres) <= total_bits) @intCast(dec.icdf(&tables.trim_icdf, 7)) else 5;
    var bits: i32 = (@as(i32, @intCast(bytes.len)) * 8 << bitres) - @as(i32, @intCast(dec.tellFrac())) - 1;
    const anti_collapse_rsv: i32 = if (transient and lm >= 2 and bits >= (@as(i32, @intCast(lm)) + 2) << bitres) 1 << bitres else 0;
    bits -= anti_collapse_rsv;
    var allocation: alloc.Allocation = undefined;
    alloc.compute(start, end, &offsets, &cap, alloc_trim, bits, c_stream, lm, dec, &allocation);
    energy.fine(start, end, &st.old_band_e, &allocation.fine_bits, dec, c_stream);

    shiftMemory(st, n, buffer_size - n + overlap);

    var collapse_masks: [2 * nb]u8 = undefined;
    const x = &st.work.decode.x;
    const frame: bands.Frame = .{
        .start = start,
        .end = end,
        .lm = lm,
        .short_blocks = transient,
        .spread = spread,
        .dual_stereo = allocation.dual_stereo,
        .intensity = allocation.intensity,
        .tf_res = &tf_res,
        .total_bits = @as(i32, @intCast(bytes.len)) * (8 << bitres) - anti_collapse_rsv,
        .balance = allocation.balance,
        .coded_bands = allocation.coded_bands,
        .pulses = &allocation.pulses,
        .disable_inv = st.disable_inv,
    };
    bands.decodeAll(&frame, x, if (c_stream == 2) @as([*]f32, x) + n else null, &collapse_masks, &st.work.decode.norm, dec, &st.rng);

    var anti_collapse_on = false;
    if (anti_collapse_rsv > 0) anti_collapse_on = dec.bits(1) != 0;
    energy.finalise(start, end, &st.old_band_e, &allocation.fine_bits, &allocation.fine_priority, @as(i32, @intCast(bytes.len * 8)) - dec.tell(), dec, c_stream);
    if (anti_collapse_on) {
        bands.antiCollapse(x, &collapse_masks, lm, c_stream, n, start, end, &st.old_band_e, &st.old_log_e, &st.old_log_e2, &allocation.pulses, st.rng);
    }
    if (silence) {
        for (0..c_stream * nb) |i| st.old_band_e[i] = -28.0;
    }
    if (st.prefilter_and_fold) prefilterAndFold(st, n);
    synthesis(st, x, out_at, start, eff_end, c_stream, cc, transient, lm, silence);

    for (0..cc) |c| {
        const out: [*]f32 = @as([*]f32, &st.decode_mem[c]) + out_at;
        st.postfilter_period = @max(st.postfilter_period, comb_min_period);
        st.postfilter_period_old = @max(st.postfilter_period_old, comb_min_period);
        combFilter(out, out, st.postfilter_period_old, st.postfilter_period, tables.short_mdct, st.postfilter_gain_old, st.postfilter_gain, st.postfilter_tapset_old, st.postfilter_tapset, &tables.window, overlap);
        if (lm != 0) {
            combFilter(out + tables.short_mdct, out + tables.short_mdct, st.postfilter_period, postfilter_pitch, n - tables.short_mdct, st.postfilter_gain, postfilter_gain, st.postfilter_tapset, postfilter_tapset, &tables.window, overlap);
        }
    }
    st.postfilter_period_old = st.postfilter_period;
    st.postfilter_gain_old = st.postfilter_gain;
    st.postfilter_tapset_old = st.postfilter_tapset;
    st.postfilter_period = postfilter_pitch;
    st.postfilter_gain = postfilter_gain;
    st.postfilter_tapset = postfilter_tapset;
    if (lm != 0) {
        st.postfilter_period_old = st.postfilter_period;
        st.postfilter_gain_old = st.postfilter_gain;
        st.postfilter_tapset_old = st.postfilter_tapset;
    }

    if (c_stream == 1) @memcpy(st.old_band_e[nb..], st.old_band_e[0..nb]);
    if (!transient) {
        st.old_log_e2 = st.old_log_e;
        st.old_log_e = st.old_band_e;
    } else {
        for (0..2 * nb) |i| st.old_log_e[i] = @min(st.old_log_e[i], st.old_band_e[i]);
    }
    // The noise floor rises 2.4 dB a second at most - by all the frames
    // a DTX gap missed at once.
    const max_background_increase = @as(f32, @floatFromInt(@min(160, st.loss_duration + @as(i32, @intCast(m))))) * 0.001;
    for (0..2 * nb) |i| st.background_log_e[i] = @min(st.background_log_e[i] + max_background_increase, st.old_band_e[i]);
    for (0..2) |c| {
        for (0..start) |i| {
            st.old_band_e[c * nb + i] = 0;
            st.old_log_e[c * nb + i] = -28.0;
            st.old_log_e2[c * nb + i] = -28.0;
        }
        for (end..nb) |i| {
            st.old_band_e[c * nb + i] = 0;
            st.old_log_e[c * nb + i] = -28.0;
            st.old_log_e2[c * nb + i] = -28.0;
        }
    }
    st.rng = dec.rng;
    deemphasis(st, out_at, pcm, n);
    st.loss_duration = 0;
    st.prefilter_and_fold = false;
    if (dec.tell() > @as(i32, @intCast(8 * bytes.len))) return false;
    return true;
}

// --- loss concealment -------------------------------------------------------------

/// The post-filter run backwards over the overlap a concealed frame left,
/// and its aliasing made, so the next decoded frame blends with it.
fn prefilterAndFold(st: *Celt, n: usize) void {
    var etmp: [overlap]f32 = undefined;
    for (0..st.channels) |c| {
        const mem: [*]f32 = &st.decode_mem[c];
        combFilter(&etmp, mem + buffer_size - n, st.postfilter_period_old, st.postfilter_period, overlap, -st.postfilter_gain_old, -st.postfilter_gain, st.postfilter_tapset_old, st.postfilter_tapset, null, 0);
        for (0..overlap / 2) |i| {
            mem[buffer_size - n + i] = tables.window[i] * etmp[overlap - 1 - i] + tables.window[overlap - i - 1] * etmp[i];
        }
    }
}

fn decodeLost(st: *Celt, n: usize, lm: u32) void {
    const c_count = st.channels;
    const start = st.start;
    const loss_duration = st.loss_duration;
    const noise_based = loss_duration >= 40 or start != 0 or st.skip_plc;
    if (noise_based) {
        // Noise at the energies last decoded, falling.
        const end = st.end;
        const eff_end = @max(start, @min(end, nb));
        shiftMemory(st, n, buffer_size - n + overlap);
        if (st.prefilter_and_fold) prefilterAndFold(st, n);
        const decay: f32 = if (loss_duration == 0) 1.5 else 0.5;
        for (0..c_count) |c| {
            for (start..end) |i| {
                const at = c * nb + i;
                st.old_band_e[at] = @max(st.background_log_e[at], st.old_band_e[at] - decay);
            }
        }
        const x = &st.work.decode.x;
        var seed = st.rng;
        for (0..c_count) |c| {
            for (start..eff_end) |i| {
                const boffs = n * c + (@as(usize, @intCast(tables.e_bands[i])) << @intCast(lm));
                const blen = @as(usize, @intCast(tables.e_bands[i + 1] - tables.e_bands[i])) << @intCast(lm);
                for (0..blen) |j| {
                    seed = bands.lcgRand(seed);
                    x[boffs + j] = @floatFromInt(@as(i32, @bitCast(seed)) >> 20);
                }
                pvq.renormalise(x[boffs..][0..blen], 1.0);
            }
        }
        st.rng = seed;
        synthesis(st, x, buffer_size - n, start, eff_end, c_count, c_count, false, lm, false);
        st.prefilter_and_fold = false;
        st.skip_plc = true;
    } else {
        // The last pitch period again, through the signal's LPC filter.
        var fade: f32 = 1.0;
        var pitch_index: i32 = undefined;
        if (loss_duration == 0) {
            pitch_index = plcPitchSearch(st);
            st.last_pitch_index = pitch_index;
        } else {
            pitch_index = st.last_pitch_index;
            fade = 0.8;
        }
        const pitch: usize = @intCast(pitch_index);
        const exc_length: usize = @min(2 * pitch, max_period);
        const work = &st.work.plc;
        const exc_buffer = &work.exc;
        const exc: [*]f32 = @as([*]f32, exc_buffer) + lpc_order;
        const fir_tmp = &work.fir_tmp;
        const window = &tables.window;
        for (0..c_count) |c| {
            const buf: [*]f32 = &st.decode_mem[c];
            for (0..max_period + lpc_order) |i| exc_buffer[i] = buf[buffer_size - max_period - lpc_order + i];
            if (loss_duration == 0) {
                var ac: [lpc_order + 1]f32 = undefined;
                // Its ends windowed.
                const xx = &work.windowed;
                @memcpy(xx, exc[0..max_period]);
                for (0..overlap) |i| {
                    xx[i] *= window[i];
                    xx[max_period - i - 1] *= window[i];
                }
                autocorr(xx, &ac, lpc_order);
                // A noise floor of -40 dB, and lag windowing.
                ac[0] *= 1.0001;
                for (1..lpc_order + 1) |i| {
                    const fi: f32 = @floatFromInt(i);
                    ac[i] -= ac[i] * (0.008 * 0.008) * fi * fi;
                }
                lpcFromAutocorr(&st.lpc[c], &ac);
            }
            // The excitation of the last two periods.
            fir(exc + max_period - exc_length, &st.lpc[c], fir_tmp, exc_length);
            copyForward(exc + max_period - exc_length, fir_tmp, exc_length);

            // How fast it decays, so none is added.
            var decay: f32 = undefined;
            {
                var e1: f32 = 1;
                var e2: f32 = 1;
                const decay_length = exc_length >> 1;
                for (0..decay_length) |i| {
                    var e = exc[max_period - decay_length + i];
                    e1 += e * e;
                    e = exc[max_period - 2 * decay_length + i];
                    e2 += e * e;
                }
                e1 = @min(e1, e2);
                decay = @sqrt(e1 / e2);
            }

            copyForward(buf, buf + n, buffer_size - n);
            const extrapolation_offset = max_period - pitch;
            const extrapolation_len = n + overlap;
            var attenuation = fade * decay;
            var s1: f32 = 0;
            var j: usize = 0;
            for (0..extrapolation_len) |i| {
                if (j >= pitch) {
                    j -= pitch;
                    attenuation *= decay;
                }
                buf[buffer_size - n + i] = attenuation * exc[extrapolation_offset + j];
                const tmp = buf[buffer_size - max_period - n + extrapolation_offset + j];
                s1 += tmp * tmp;
                j += 1;
            }
            {
                var lpc_mem: [lpc_order]f32 = undefined;
                for (0..lpc_order) |i| lpc_mem[i] = buf[buffer_size - n - 1 - i];
                iir(buf + buffer_size - n, &st.lpc[c], extrapolation_len, &lpc_mem);
            }
            // An explosion in the synthesis silenced, too much energy
            // faded down.
            var s2: f32 = 0;
            for (0..extrapolation_len) |i| {
                const tmp = buf[buffer_size - n + i];
                s2 += tmp * tmp;
            }
            if (!(s1 > 0.2 * s2)) {
                for (0..extrapolation_len) |i| buf[buffer_size - n + i] = 0;
            } else if (s1 < s2) {
                const ratio = @sqrt((s1 * 0.5 + 1) / (s2 + 1));
                for (0..overlap) |i| {
                    const tmp_g = 1.0 - window[i] * (1.0 - ratio);
                    buf[buffer_size - n + i] *= tmp_g;
                }
                for (overlap..extrapolation_len) |i| buf[buffer_size - n + i] *= ratio;
            }
        }
        st.prefilter_and_fold = true;
    }
    st.loss_duration = @min(10000, loss_duration + (@as(i32, 1) << @intCast(lm)));
}

/// The pitch period of the signal decoded, for concealment.
fn plcPitchSearch(st: *Celt) i32 {
    const work = &st.work.pitch;
    const lp = &work.lp;
    pitchDownsample(st, lp, buffer_size);
    const pitch_index = pitchSearch(work, @as([*]const f32, lp) + (plc_pitch_lag_max >> 1), lp, buffer_size - plc_pitch_lag_max, plc_pitch_lag_max - plc_pitch_lag_min);
    return plc_pitch_lag_max - pitch_index;
}

/// The channels' signal at half the rate, whitened by a 4th order LPC
/// with a zero added.
fn pitchDownsample(st: *Celt, x_lp: *[buffer_size >> 1]f32, len: usize) void {
    const half = len >> 1;
    for (0..st.channels) |c| {
        const x: [*]const f32 = &st.decode_mem[c];
        for (1..half) |i| {
            const v = 0.25 * x[2 * i - 1] + 0.25 * x[2 * i + 1] + 0.5 * x[2 * i];
            if (c == 0) x_lp[i] = v else x_lp[i] += v;
        }
        const v0 = 0.25 * x[1] + 0.5 * x[0];
        if (c == 0) x_lp[0] = v0 else x_lp[0] += v0;
    }
    var ac: [5]f32 = undefined;
    autocorr(x_lp[0..half], &ac, 4);
    ac[0] *= 1.0001;
    for (1..5) |i| {
        const fi: f32 = @floatFromInt(i);
        ac[i] -= ac[i] * (0.008 * fi) * (0.008 * fi);
    }
    var lpc: [4]f32 = undefined;
    lpcFromAutocorr(&lpc, &ac);
    var tmp: f32 = 1.0;
    for (0..4) |i| {
        tmp *= 0.9;
        lpc[i] *= tmp;
    }
    const c1: f32 = 0.8;
    const lpc2 = [5]f32{ lpc[0] + 0.8, lpc[1] + c1 * lpc[0], lpc[2] + c1 * lpc[1], lpc[3] + c1 * lpc[2], c1 * lpc[3] };
    var mem = [5]f32{ 0, 0, 0, 0, 0 };
    for (0..half) |i| {
        const sum = x_lp[i] + lpc2[0] * mem[0] + lpc2[1] * mem[1] + lpc2[2] * mem[2] + lpc2[3] * mem[3] + lpc2[4] * mem[4];
        mem[4] = mem[3];
        mem[3] = mem[2];
        mem[2] = mem[1];
        mem[1] = mem[0];
        mem[0] = x_lp[i];
        x_lp[i] = sum;
    }
}

fn innerProduct(x: [*]const f32, y: [*]const f32, n: usize) f32 {
    var sum: f32 = 0;
    for (0..n) |i| sum += x[i] * y[i];
    return sum;
}

fn findBestPitch(xcorr: [*]const f32, y: [*]const f32, len: usize, max_pitch: usize, best_pitch: *[2]i32) void {
    var syy: f32 = 1;
    var best_num = [2]f32{ -1, -1 };
    var best_den = [2]f32{ 0, 0 };
    best_pitch.* = .{ 0, 1 };
    for (0..len) |j| syy += y[j] * y[j];
    for (0..max_pitch) |i| {
        if (xcorr[i] > 0) {
            var xcorr16 = xcorr[i];
            xcorr16 *= 1e-12;
            const num = xcorr16 * xcorr16;
            if (num * best_den[1] > best_num[1] * syy) {
                if (num * best_den[0] > best_num[0] * syy) {
                    best_num[1] = best_num[0];
                    best_den[1] = best_den[0];
                    best_pitch[1] = best_pitch[0];
                    best_num[0] = num;
                    best_den[0] = syy;
                    best_pitch[0] = @intCast(i);
                } else {
                    best_num[1] = num;
                    best_den[1] = syy;
                    best_pitch[1] = @intCast(i);
                }
            }
        }
        syy += y[i + len] * y[i + len] - y[i] * y[i];
        syy = @max(1, syy);
    }
}

fn pitchSearch(work: *@FieldType(Work, "pitch"), x_lp: [*]const f32, y: [*]const f32, len: usize, max_pitch: usize) i32 {
    const lag = len + max_pitch;
    const x_lp4 = &work.x_lp4;
    const y_lp4 = &work.y_lp4;
    const xcorr = &work.xcorr;
    for (0..len >> 2) |j| x_lp4[j] = x_lp[2 * j];
    for (0..lag >> 2) |j| y_lp4[j] = y[2 * j];
    // Coarse, at a quarter of the rate.
    for (0..max_pitch >> 2) |i| xcorr[i] = innerProduct(x_lp4, @as([*]const f32, y_lp4) + i, len >> 2);
    var best_pitch = [2]i32{ 0, 0 };
    findBestPitch(xcorr, y_lp4, len >> 2, max_pitch >> 2, &best_pitch);
    // Finer, at half, near the two best.
    for (0..max_pitch >> 1) |i| {
        xcorr[i] = 0;
        const ii: i32 = @intCast(i);
        if (@abs(ii - 2 * best_pitch[0]) > 2 and @abs(ii - 2 * best_pitch[1]) > 2) continue;
        const sum = innerProduct(x_lp, y + i, len >> 1);
        xcorr[i] = @max(-1, sum);
    }
    findBestPitch(xcorr, y, len >> 1, max_pitch >> 1, &best_pitch);
    var offset: i32 = 0;
    if (best_pitch[0] > 0 and best_pitch[0] < @as(i32, @intCast(max_pitch >> 1)) - 1) {
        const bp: usize = @intCast(best_pitch[0]);
        const a = xcorr[bp - 1];
        const b = xcorr[bp];
        const c = xcorr[bp + 1];
        if ((c - a) > 0.7 * (b - a)) {
            offset = 1;
        } else if ((a - c) > 0.7 * (b - c)) {
            offset = -1;
        }
    }
    return 2 * best_pitch[0] - offset;
}

/// The autocorrelation of `x` up to `lag`.
fn autocorr(x: []const f32, ac: []f32, lag: usize) void {
    const n = x.len;
    for (0..lag + 1) |k| {
        var d: f32 = 0;
        for (k..n) |i| d += x[i] * x[i - k];
        ac[k] = d;
    }
}

/// LPC coefficients from an autocorrelation (Levinson-Durbin), stopping
/// at 30 dB of prediction gain.
fn lpcFromAutocorr(lpc: []f32, ac: []const f32) void {
    const p = lpc.len;
    @memset(lpc, 0);
    var err = ac[0];
    if (ac[0] <= 1e-10) return;
    for (0..p) |i| {
        var rr: f32 = 0;
        for (0..i) |j| rr += lpc[j] * ac[i - j];
        rr += ac[i + 1];
        const r = -rr / err;
        lpc[i] = r;
        for (0..(i + 1) >> 1) |j| {
            const tmp1 = lpc[j];
            const tmp2 = lpc[i - 1 - j];
            lpc[j] = tmp1 + r * tmp2;
            lpc[i - 1 - j] = tmp2 + r * tmp1;
        }
        err = err - r * r * err;
        if (err <= 0.001 * ac[0]) break;
    }
}

/// The LPC analysis filter: `x` reaches back the filter's order.
fn fir(x: [*]const f32, num: *const [lpc_order]f32, y: [*]f32, n: usize) void {
    for (0..n) |i| {
        var sum = x[i];
        for (0..lpc_order) |j| sum += num[j] * (x + i - j - 1)[0];
        y[i] = sum;
    }
}

/// The LPC synthesis filter in place, its memory the samples before.
fn iir(x: [*]f32, den: *const [lpc_order]f32, n: usize, mem: *[lpc_order]f32) void {
    for (0..n) |i| {
        var sum = x[i];
        for (0..lpc_order) |j| sum -= den[j] * mem[j];
        var j: usize = lpc_order - 1;
        while (j >= 1) : (j -= 1) mem[j] = mem[j - 1];
        mem[0] = sum;
        x[i] = sum;
    }
}
