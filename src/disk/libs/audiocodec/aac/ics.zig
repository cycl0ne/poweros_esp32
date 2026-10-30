// SPDX-License-Identifier: MIT
//! One channel's part of an AAC packet - an individual channel stream,
//! ISO/IEC 14496-3 4.4.2.7 - read: how its frame is windowed, which
//! codebook codes each band, each band's scale factor, the pulses and the
//! TNS filters, and the spectrum, which is then scaled into the channel's
//! coefficients.
//!
//! **The windows**: a frame is one long window of 1024 lines - or a long
//! one that starts or stops a run of short ones - or eight short windows
//! of 128. The short ones are put in groups that share their codebooks and
//! scale factors, and their spectra are written band by band across the
//! windows of a group: a band's lines in the first window, then in the
//! next. The coefficients are kept window after window, 128 lines each.
//!
//! **A band's codebook** (section data) is 0 for silence, 1 to 11 for
//! the spectral codebooks, 13 for noise (PNS: no lines are sent, only how
//! loud it is), 14 and 15 for intensity stereo (none either: the right
//! channel is the left one scaled). Each kind has its own run of scale
//! factors, each coded as a difference from the one before: the gain of
//! the lines from the global gain, the noise's loudness from 90 below it
//! - its first one in 9 bits - and the intensity's position from 0.
//!
//! **A line** is sign(q) |q|^(4/3) 2^((sf - 100) / 4), q the value its
//! codebook gave and a pulse added. The transform's 2/N is folded in
//! here, so the filter bank only adds.

const std = @import("std");
const tables = @import("tables.zig");
const huffman = @import("huffman.zig");
const Bits = @import("bits.zig").Bits;

pub const ONLY_LONG: u8 = 0;
pub const LONG_START: u8 = 1;
pub const EIGHT_SHORT: u8 = 2;
pub const LONG_STOP: u8 = 3;

pub const ZERO_BOOK: u8 = 0;
pub const NOISE_BOOK: u8 = 13;
pub const INTENSITY_OUT: u8 = 14;
pub const INTENSITY_IN: u8 = 15;

/// The most bands a frame has: 51 of a long window, or 8 groups of 15.
pub const max_bands = 8 * 16;

/// How a frame is windowed: its window sequence and shape, the bands it
/// codes, and how its short windows are grouped.
pub const Info = struct {
    sequence: u8 = ONLY_LONG,
    /// 0 for the sine window, 1 for Kaiser-Bessel derived.
    shape: u8 = 0,
    max_sfb: u8 = 0,
    windows: u8 = 1,
    groups: u8 = 1,
    group_len: [8]u8 = .{ 1, 0, 0, 0, 0, 0, 0, 0 },
    /// The bands of a window at the stream's rate: where each starts, the
    /// last entry the window's length; how many there are; how many TNS
    /// may filter.
    offsets: []const u16 = &.{},
    bands: u8 = 0,
    tns_bands: u8 = 0,

    pub fn short(info: *const Info) bool {
        return info.sequence == EIGHT_SHORT;
    }
};

/// A window's TNS filters: up to three for a long window, one for each
/// short one.
pub const Tns = struct {
    present: bool = false,
    filters: [8]u8 = @splat(0),
    length: [8][3]u8 = undefined,
    order: [8][3]u8 = undefined,
    downward: [8][3]bool = undefined,
    /// The reflection coefficients, made into a filter's when it is used.
    coef: [8][3][12]f32 = undefined,
};

pub const Pulse = struct {
    count: u8 = 0,
    start: u8 = 0,
    offset: [4]u8 = undefined,
    amp: [4]u8 = undefined,
};

/// A channel of a frame: what its stream says, and its coefficients.
pub const Channel = struct {
    info: Info = .{},
    global_gain: u8 = 0,
    /// Each band's codebook and scale factor, group after group,
    /// `info.max_sfb` bands each.
    book: [max_bands]u8 = undefined,
    sf: [max_bands]i16 = undefined,
    tns: Tns = .{},
    pulse: Pulse = .{},
};

pub const Error = error{ Corrupt, Unsupported };

/// ics_info: the window sequence, the shape, the bands coded, and the
/// grouping of short windows.
pub fn readInfo(bits: *Bits, rate_index: u8, info: *Info) Error!void {
    _ = bits.read(1);
    info.sequence = @intCast(bits.read(2));
    info.shape = @intCast(bits.read(1));
    if (info.sequence == EIGHT_SHORT) {
        info.max_sfb = @intCast(bits.read(4));
        const grouping = bits.read(7);
        info.windows = 8;
        info.groups = 1;
        info.group_len = .{ 1, 0, 0, 0, 0, 0, 0, 0 };
        var window: u3 = 1;
        while (true) : (window += 1) {
            // A set bit puts the window with the one before it.
            if (grouping & (@as(u32, 0x40) >> (window - 1)) != 0) {
                info.group_len[info.groups - 1] += 1;
            } else {
                info.group_len[info.groups] = 1;
                info.groups += 1;
            }
            if (window == 7) break;
        }
        info.offsets = tables.swb_offset_short[rate_index];
        info.bands = tables.num_swb_short[rate_index];
        info.tns_bands = tables.tns_max_bands_short[rate_index];
    } else {
        info.max_sfb = @intCast(bits.read(6));
        info.windows = 1;
        info.groups = 1;
        info.group_len = .{ 1, 0, 0, 0, 0, 0, 0, 0 };
        info.offsets = tables.swb_offset_long[rate_index];
        info.bands = tables.num_swb_long[rate_index];
        info.tns_bands = tables.tns_max_bands_long[rate_index];
        // The predictor of AAC Main; an LC stream has none.
        if (bits.bit()) return error.Unsupported;
    }
    if (info.max_sfb > info.bands) return error.Corrupt;
}

/// An individual channel stream up to its spectrum: the global gain, the
/// window info unless the pair shares it, the sections, the scale
/// factors, the pulses, TNS.
pub fn readSide(bits: *Bits, rate_index: u8, common_window: bool, ch: *Channel) Error!void {
    ch.global_gain = @intCast(bits.read(8));
    if (!common_window) try readInfo(bits, rate_index, &ch.info);
    try sections(bits, ch);
    try scaleFactors(bits, ch);
    ch.pulse.count = 0;
    if (bits.bit()) {
        if (ch.info.short()) return error.Corrupt;
        try pulses(bits, ch);
    }
    ch.tns.present = bits.bit();
    if (ch.tns.present) try tns(bits, ch);
    // Gain control belongs to the SSR profile.
    if (bits.bit()) return error.Unsupported;
}

/// section_data: a codebook for each run of bands, in each group.
fn sections(bits: *Bits, ch: *Channel) Error!void {
    const info = &ch.info;
    const length_bits: u5 = if (info.short()) 3 else 5;
    const run_escape: u32 = (@as(u32, 1) << length_bits) - 1;
    for (0..info.groups) |g| {
        var band: usize = 0;
        while (band < info.max_sfb) {
            const book: u8 = @intCast(bits.read(4));
            if (book == 12) return error.Corrupt;
            var length: usize = 0;
            while (true) {
                const more = bits.read(length_bits);
                length += more;
                if (more != run_escape) break;
                if (bits.overrun()) return error.Corrupt;
            }
            if (band + length > info.max_sfb) return error.Corrupt;
            @memset(ch.book[g * info.max_sfb + band ..][0..length], book);
            band += length;
            if (bits.overrun()) return error.Corrupt;
        }
    }
}

/// scale_factor_data: each band's scale factor, by its kind.
fn scaleFactors(bits: *Bits, ch: *Channel) Error!void {
    const info = &ch.info;
    var gain: i32 = ch.global_gain;
    var noise: i32 = @as(i32, ch.global_gain) - 90;
    var position: i32 = 0;
    var first_noise = true;
    const count = @as(usize, info.groups) * info.max_sfb;
    for (0..count) |i| {
        switch (ch.book[i]) {
            ZERO_BOOK => ch.sf[i] = 0,
            INTENSITY_OUT, INTENSITY_IN => {
                position += try difference(bits);
                ch.sf[i] = @intCast(std.math.clamp(position, -155, 155));
            },
            NOISE_BOOK => {
                if (first_noise) {
                    first_noise = false;
                    noise += @as(i32, @intCast(bits.read(9))) - 256;
                } else {
                    noise += try difference(bits);
                }
                ch.sf[i] = @intCast(std.math.clamp(noise, -155, 155));
            },
            else => {
                gain += try difference(bits);
                if (gain < 0 or gain > 255) return error.Corrupt;
                ch.sf[i] = @intCast(gain);
            },
        }
    }
}

fn difference(bits: *Bits) Error!i32 {
    const value = huffman.scalefactor.decode(bits) orelse return error.Corrupt;
    return @as(i32, value) - 60;
}

/// pulse_data: up to four lines a little louder, in a long window.
fn pulses(bits: *Bits, ch: *Channel) Error!void {
    const p = &ch.pulse;
    p.count = @intCast(bits.read(2) + 1);
    p.start = @intCast(bits.read(6));
    if (p.start >= ch.info.bands) return error.Corrupt;
    for (0..p.count) |i| {
        p.offset[i] = @intCast(bits.read(5));
        p.amp[i] = @intCast(bits.read(4));
    }
}

/// tns_data: each window's filters - how many bands down from the top
/// each covers, its order, its direction and its coefficients.
fn tns(bits: *Bits, ch: *Channel) Error!void {
    const t = &ch.tns;
    const short = ch.info.short();
    const max_order: u32 = if (short) 7 else 12;
    for (0..ch.info.windows) |w| {
        t.filters[w] = @intCast(bits.read(if (short) 1 else 2));
        if (t.filters[w] == 0) continue;
        const resolution: u5 = @intCast(bits.read(1) + 3);
        for (0..t.filters[w]) |f| {
            t.length[w][f] = @intCast(bits.read(if (short) 4 else 6));
            const order = bits.read(if (short) 3 else 5);
            if (order > max_order) return error.Corrupt;
            t.order[w][f] = @intCast(order);
            if (order == 0) continue;
            t.downward[w][f] = bits.bit();
            const compressed: u5 = @intCast(bits.read(1));
            const width = resolution - compressed;
            // The inverse quantiser: a sine of the coded step, finer for
            // the positive side.
            const top: f32 = @floatFromInt(@as(u32, 1) << (resolution - 1));
            const half_pi: f32 = std.math.pi / 2.0;
            for (0..order) |i| {
                const raw = bits.read(width);
                // Sign-extended from its width.
                const shift: u5 = @intCast(32 - @as(u32, width));
                const value: i32 = @as(i32, @bitCast(raw << shift)) >> shift;
                const step: f32 = if (value >= 0) (top - 0.5) / half_pi else (top + 0.5) / half_pi;
                t.coef[w][f][i] = @sin(@as(f32, @floatFromInt(value)) / step);
            }
        }
    }
}

/// spectral_data: the quantised lines, into `quant` window after window
/// (128 lines each for short windows), the pulses added.
pub fn readSpectrum(bits: *Bits, ch: *const Channel, quant: *[1024]i32) Error!void {
    @memset(quant, 0);
    const info = &ch.info;
    const offsets = info.offsets;
    var window: usize = 0;
    for (0..info.groups) |g| {
        const len = info.group_len[g];
        for (0..info.max_sfb) |band| {
            const book = ch.book[g * info.max_sfb + band];
            if (book == ZERO_BOOK or book >= NOISE_BOOK) continue;
            const spec = huffman.books[book - 1];
            const dimension: usize = spec.dimension;
            const start = offsets[band];
            const end = offsets[band + 1];
            for (0..len) |w| {
                const line = quant[(window + w) * 128 ..];
                var k: usize = start;
                while (k < end) : (k += dimension) {
                    const values = huffman.spectralValues(book, bits) orelse return error.Corrupt;
                    var out: [4]i32 = .{ values[0], values[1], values[2], values[3] };
                    if (!spec.signed) {
                        for (out[0..dimension]) |*v| {
                            if (v.* != 0 and bits.bit()) v.* = -v.*;
                        }
                    }
                    if (book == 11) {
                        for (out[0..2]) |*v| {
                            if (v.* == 16 or v.* == -16) {
                                const magnitude = try escape(bits);
                                v.* = if (v.* < 0) -magnitude else magnitude;
                            }
                        }
                    }
                    for (0..dimension) |i| line[k + i] = out[i];
                }
            }
            if (bits.overrun()) return error.Corrupt;
        }
        window += len;
    }
    const p = &ch.pulse;
    if (p.count != 0) {
        var k: usize = offsets[p.start];
        for (0..p.count) |i| {
            k += p.offset[i];
            if (k >= 1024) return error.Corrupt;
            const amp: i32 = p.amp[i];
            quant[k] = if (quant[k] > 0) quant[k] + amp else quant[k] - amp;
        }
    }
}

/// An escape: as many 1s as bits past four, a 0, then those bits.
fn escape(bits: *Bits) Error!i32 {
    var width: u5 = 4;
    while (bits.bit()) {
        width += 1;
        if (width == 13) return error.Corrupt;
    }
    return @intCast((@as(u32, 1) << width) + bits.read(width));
}

/// |q|^(4/3) for the small values, made once.
pub const Powers = [256]f32;

pub fn makePowers(out: *Powers) void {
    for (out, 0..) |*slot, q| {
        const x: f64 = @floatFromInt(q);
        slot.* = @floatCast(x * std.math.cbrt(x));
    }
}

fn power(powers: *const Powers, q: i32) f32 {
    const magnitude: u32 = @abs(q);
    const value = if (magnitude < powers.len) powers[magnitude] else blk: {
        const x: f32 = @floatFromInt(magnitude);
        break :blk x * std.math.cbrt(x);
    };
    return if (q < 0) -value else value;
}

/// 2^(e/4), e from -500 to 500.
pub fn quarterPower(e: i32) f32 {
    const fractions = [4]f32{ 1.0, 1.189207115, 1.414213562, 1.681792831 };
    const whole = e >> 2;
    return std.math.ldexp(fractions[@intCast(e & 3)], whole);
}

/// The noise of PNS: the same generator as FFmpeg's, so a file decodes
/// to the same samples.
pub const Noise = struct {
    state: u32 = 0x1f2e3d4c,

    fn next(n: *Noise) f32 {
        n.state = n.state *% 1664525 +% 1013904223;
        return @floatFromInt(@as(i32, @bitCast(n.state)));
    }
};

/// The lines scaled into the channel's coefficients, window after window,
/// the transform's 2/N with them: 1/1024 for a long window, 1/128 for a
/// short one. Noise bands are filled from `noise`; intensity bands are
/// left at 0 for the pair to fill.
pub fn dequantise(ch: *const Channel, quant: *const [1024]i32, powers: *const Powers, noise: *Noise, coef: [*]f32) void {
    const info = &ch.info;
    const offsets = info.offsets;
    const norm: i32 = if (info.short()) -7 * 4 else -10 * 4;
    @memset(coef[0..1024], 0);
    var window: usize = 0;
    for (0..info.groups) |g| {
        const len = info.group_len[g];
        for (0..info.max_sfb) |band| {
            const index = g * info.max_sfb + band;
            const book = ch.book[index];
            const start = offsets[band];
            const end = offsets[band + 1];
            switch (book) {
                ZERO_BOOK, INTENSITY_OUT, INTENSITY_IN => {},
                NOISE_BOOK => {
                    const loud = quarterPower(@as(i32, ch.sf[index]) + norm);
                    for (0..len) |w| {
                        const line = coef + (window + w) * 128;
                        var energy: f32 = 0;
                        for (start..end) |k| {
                            const v = noise.next();
                            line[k] = v;
                            energy += v * v;
                        }
                        const scale = loud / @sqrt(energy);
                        for (start..end) |k| line[k] *= scale;
                    }
                },
                else => {
                    const gain = quarterPower(@as(i32, ch.sf[index]) - 100 + norm);
                    for (0..len) |w| {
                        const at = (window + w) * 128;
                        for (start..end) |k| {
                            const q = quant[at + k];
                            if (q != 0) coef[at + k] = power(powers, q) * gain;
                        }
                    }
                },
            }
        }
        window += len;
    }
}

/// The TNS filters run over the coefficients: each an all-pole filter
/// over its bands, upward or downward.
pub fn applyTns(ch: *const Channel, coef: [*]f32) void {
    const t = &ch.tns;
    if (!t.present) return;
    const info = &ch.info;
    const limit = @min(info.tns_bands, info.max_sfb);
    for (0..info.windows) |w| {
        var bottom: u32 = info.bands;
        for (0..t.filters[w]) |f| {
            const top = bottom;
            bottom = top -| t.length[w][f];
            const order = t.order[w][f];
            if (order == 0) continue;
            var lpc: [13]f32 = undefined;
            toLpc(t.coef[w][f][0..order], &lpc);
            const start: usize = info.offsets[@min(bottom, limit)];
            const end: usize = info.offsets[@min(top, limit)];
            if (end <= start) continue;
            const line = coef + w * 128;
            const size = end - start;
            var state: [12]f32 = @splat(0);
            for (0..size) |m| {
                const k = if (t.downward[w][f]) end - 1 - m else start + m;
                var y = line[k];
                for (0..order) |j| y -= lpc[j + 1] * state[j];
                var j: usize = order - 1;
                while (j > 0) : (j -= 1) state[j] = state[j - 1];
                state[0] = y;
                line[k] = y;
            }
        }
    }
}

/// Reflection coefficients made into a filter's, step by step up.
fn toLpc(reflection: []const f32, lpc: *[13]f32) void {
    lpc[0] = 1.0;
    var before: [13]f32 = undefined;
    for (reflection, 1..) |k, m| {
        @memcpy(before[0..m], lpc[0..m]);
        for (1..m) |i| lpc[i] = before[i] + k * before[m - i];
        lpc[m] = k;
    }
}

/// The pair's M/S stereo: where a band is sent as middle and side, left
/// and right made of them - not in noise or intensity bands.
pub fn applyMs(left: *const Channel, right: *const Channel, ms: *const [max_bands]bool, l: [*]f32, r: [*]f32) void {
    const info = &left.info;
    var window: usize = 0;
    for (0..info.groups) |g| {
        const len = info.group_len[g];
        for (0..info.max_sfb) |band| {
            const index = g * info.max_sfb + band;
            if (!ms[index] or left.book[index] >= NOISE_BOOK or right.book[index] >= NOISE_BOOK) continue;
            for (0..len) |w| {
                const at = (window + w) * 128;
                for (info.offsets[band]..info.offsets[band + 1]) |k| {
                    const middle = l[at + k];
                    const side = r[at + k];
                    l[at + k] = middle + side;
                    r[at + k] = middle - side;
                }
            }
        }
        window += len;
    }
}

/// The pair's intensity stereo: the right channel's intensity bands made
/// of the left's, scaled by 2^(-position/4), turned over by book 14 and,
/// where M/S is signalled band by band, by the band's flag.
pub fn applyIntensity(left: *const Channel, right: *const Channel, ms_present: u8, ms: *const [max_bands]bool, l: [*]const f32, r: [*]f32) void {
    const info = &right.info;
    var window: usize = 0;
    for (0..info.groups) |g| {
        const len = info.group_len[g];
        for (0..info.max_sfb) |band| {
            const index = g * info.max_sfb + band;
            const book = right.book[index];
            if (book != INTENSITY_OUT and book != INTENSITY_IN) continue;
            var scale = quarterPower(-@as(i32, right.sf[index]));
            if (book == INTENSITY_OUT) scale = -scale;
            if (ms_present == 1 and ms[index]) scale = -scale;
            for (0..len) |w| {
                const at = (window + w) * 128;
                for (info.offsets[band]..info.offsets[band + 1]) |k| r[at + k] = l[at + k] * scale;
            }
        }
        window += len;
    }
    _ = left;
}

test "short windows grouped by their bits" {
    // max_sfb 14, grouping 1100101: windows 0-2 together, 3, 4-5, 6-7.
    var bytes: [4]u8 = undefined;
    const word: u32 = (0 << 31) | (2 << 29) | (1 << 28) | (14 << 24) | (0b1100101 << 17);
    std.mem.writeInt(u32, &bytes, word, .big);
    var bits: Bits = .{ .bytes = &bytes };
    var info: Info = .{};
    try readInfo(&bits, 4, &info);
    try std.testing.expectEqual(@as(u8, 4), info.groups);
    try std.testing.expectEqualSlices(u8, &.{ 3, 1, 2, 2 }, info.group_len[0..4]);
    try std.testing.expectEqual(@as(u8, 14), info.max_sfb);
    try std.testing.expectEqual(@as(usize, 15), bits.at);
}

test "a filter from reflection coefficients" {
    var lpc: [13]f32 = undefined;
    toLpc(&.{ 0.5, -0.25 }, &lpc);
    // a1 = k1 + k2 k1, a2 = k2.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5 - 0.125), lpc[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -0.25), lpc[2], 1e-6);
}
