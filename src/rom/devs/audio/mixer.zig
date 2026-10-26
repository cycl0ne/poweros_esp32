// SPDX-License-Identifier: MPL-2.0
//! Streams of samples, each in its own form and at its own rate, mixed
//! into the stereo frames the output takes. Nothing here touches hardware,
//! so the host tests hold all of it.
//!
//! **A voice plays one stream.** Its samples are 8-, 16- or 32-bit, one
//! channel or two interleaved, and every write can be in a form of its
//! own: the voice reads each as the write says. Whatever the form, a
//! sample is worked on at 16 bits: a 32-bit one is rounded to the nearest,
//! not cut, which would pull every sample down by half a step.
//!
//! **Its rate is its own** and the output's is the output's, so a voice
//! keeps a position in its frames - a whole frame and a fraction of one -
//! and a step to add to it per output frame, in 65536ths. What plays is
//! the line between the frame under the position and the one after it, as
//! far along as the fraction says, to 32768ths of the way and rounded:
//! holding each frame for a whole number of output frames instead - two
//! or three, unevenly, for a sound at 22 kHz - is heard as grit, and a
//! coarse fraction as a faint noise under a slow, loud tone.
//!
//! **Loud and where**: a gain for each side, in 4096ths, made from the
//! stream's volume and pan (`gains`). A one-channel stream goes to both
//! sides at their gains; a two-channel one keeps its sides, each at its
//! own. After every voice is summed, the master gain - the device's volume
//! - goes over the lot, and a sum past what a 16-bit sample holds is
//! clipped rather than wrapped: wrapping turns a loud note into a shriek.
//! Every product of a gain is rounded to the nearest.
//!
//! **A voice holds the write after the one it plays**: it takes over in
//! the frame the first one ends in, and so does another loop of a write
//! played more than once, the part of a step that ran past the end
//! carried over. The moment it takes over, the voice asks its owner for
//! the write after that (`Refill`), so a queue of any length - a program
//! that streams sound as one write after another - is heard without a
//! gap. A fill says how many writes each voice played to their end.
//!
//! **The equalizer** (`Equalizer`) shapes the sum, a side at a time,
//! after the master and before the clip: ten bands an octave apart, each a
//! peak an octave wide raised or lowered by whole dB. A band is a
//! second-order filter, worked out in floating point when it is set
//! (`tune`) and run in integers - its coefficients in 2^28ths, the
//! samples with 8 bits below the 16 while they go through, what each
//! output's rounding leaves over carried into the next - so the low bands,
//! whose filters lie close to the edge of feeding back on themselves, stay
//! as quiet as the high ones. A band at 0 dB is no filter at all and costs
//! nothing, and with every band flat the mix is the same to the bit as
//! with none. While a band is raised, the master is turned down by as much
//! as the highest band is raised, before the sum goes in. A band that
//! comes on takes what came into it lately as what it heard and gave out,
//! so moving a band from 0 does not click. An output that plays one side
//! has the bands run once, on the two sides joined.

const std = @import("std");

/// How many voices are mixed: one for each stream, and one for each sound
/// played by trigger.
pub const max_voices: usize = 24;

/// The fraction's width: a position and a step are `1 << shift` to the
/// frame.
pub const shift: u5 = 16;
pub const one: u32 = 1 << shift;

/// A gain of as loud as it came, in 4096ths.
pub const gain_unity: i32 = 1 << gain_shift;
const gain_shift: u5 = 12;
/// Half a 4096th: what a gain's product is rounded by, to the nearest
/// rather than down - down pulls every voice half a step low.
const gain_half: i32 = 1 << (gain_shift - 1);

/// A sample's form in memory, as the SDK numbers it.
pub const s8: u8 = 1;
pub const s16: u8 = 2;
pub const s32: u8 = 3;

/// What goes into the two halves of a frame. I2S sends the left side
/// first, and most boards' speakers take it so; a board whose right
/// speaker plays the first half has the sides the other way round; an
/// output that plays one half only - one speaker, one jack, a codec with
/// one output - is `mono`, and gets both sides together in each.
pub const Sides = enum(u8) { left_first, right_first, mono };

/// A write waiting behind the one a voice plays: its frames, how many
/// times over (0: for ever), and the form they are in.
pub const Queued = extern struct {
    data: ?[*]const u8 = null,
    frames: u32 = 0,
    loops: u32 = 0,
    format: u8 = s16,
    channels: u8 = 2,
    pad: u16 = 0,
};

/// One voice: what it is playing, where it has got to, and how loud on
/// each side.
pub const Voice = extern struct {
    /// The frames, how many, and their form. Null is a voice playing
    /// nothing.
    data: ?[*]const u8 = null,
    frames: u32 = 0,
    format: u8 = s16,
    channels: u8 = 2,
    /// Silent and held where it is until started again (CMD_STOP).
    stopped: u8 = 0,
    /// Whether `loops` is counted at all: a write played for ever.
    endless: u8 = 0,
    /// Times still to play, this one among them.
    loops: u32 = 0,
    /// Where in the frames - the frame, and how far past it in
    /// `1 << shift`ths - and how far an output frame moves it.
    index: u32 = 0,
    fraction: u32 = 0,
    step: u32 = 0,
    /// The two sides' gains, in 4096ths (`gains`).
    gain_left: i32 = gain_unity,
    gain_right: i32 = gain_unity,
    /// The frames played, counted round at 2^32.
    played: u32 = 0,
    /// The write that follows, if there is one (`data` not null).
    queued: Queued = .{},

    /// Whether this voice has frames to play.
    pub fn playing(v: *const Voice) bool {
        return v.data != null and v.frames != 0;
    }
};

/// What a fill did to the voices.
pub const Done = struct {
    /// How many writes each voice played to their end in this fill.
    ended: [max_voices]u16 = @splat(0),
    /// The voices left with nothing to play, one bit each.
    finished: u32 = 0,
};

/// Where a voice gets the write after the one it has just taken over:
/// `next` answers it, or null when there is none yet. Called inside a
/// fill, in the frame the takeover happens.
pub const Refill = struct {
    context: *anyopaque,
    next: *const fn (context: *anyopaque, voice: usize) ?Queued,
};

/// The step for a stream at `rate` frames a second in an output at
/// `out_rate`. A rate of 0 is nothing to play.
pub fn stepFor(rate: u32, out_rate: u32) u32 {
    if (rate == 0 or out_rate == 0) return 0;
    const wide = @as(u64, rate) * one / out_rate;
    return @intCast(@min(wide, std.math.maxInt(u32)));
}

/// The two sides' gains for a volume (65536 as recorded) and a pan
/// (-65536 left only to 65536 right only): the side the pan leans away
/// from is turned down, the other stays, so the middle is both at the
/// volume.
pub fn gains(volume: u32, pan: i32) struct { left: i32, right: i32 } {
    const level: i64 = @min(volume, 4 << 16) >> (16 - gain_shift);
    const toward: i64 = @max(@min(pan, 0x10000), -0x10000);
    const left = if (toward > 0) level * (0x10000 - toward) >> 16 else level;
    const right = if (toward < 0) level * (0x10000 + toward) >> 16 else level;
    return .{ .left = @intCast(left), .right = @intCast(right) };
}

/// The master gain for a volume (65536 as recorded), in 4096ths.
pub fn masterGain(volume: u32) i32 {
    return @intCast(@min(volume, 4 << 16) >> (16 - gain_shift));
}

/// `frames` stereo frames into `out`, taken from whichever voices are
/// playing, the master gain over their sum, then `equalizer`'s bands when
/// there is one. `out` holds two samples a frame, in the order `sides`
/// gives. A voice that takes over its queued write asks `refill` for the
/// next. Answers what ended.
pub fn fill(voices: []Voice, out: []i16, sides: Sides, master: i32, refill: ?Refill, equalizer: ?*Equalizer) Done {
    var done: Done = .{};
    const frames = out.len / 2;
    const gain: i64 = if (equalizer) |eq| (@as(i64, master) * eq.preamp + gain_half) >> gain_shift else master;
    var start: usize = 0;
    while (start < frames) : (start += run_frames) {
        const count: usize = @min(run_frames, frames - start);
        var sums: [run_frames * 2]i32 = @splat(0);
        for (voices, 0..) |*v, i| addVoice(v, i, sums[0 .. count * 2], &done, refill);
        for (0..count) |frame| {
            // Sixteen voices at four times their volume overrun 32 bits
            // once the master goes over them, so the master is taken in 64.
            var first: i64 = (@as(i64, sums[frame * 2]) * gain + gain_half) >> gain_shift;
            var second: i64 = (@as(i64, sums[frame * 2 + 1]) * gain + gain_half) >> gain_shift;
            switch (sides) {
                .left_first => {},
                .right_first => {
                    const swap = first;
                    first = second;
                    second = swap;
                },
                .mono => {
                    first = @divTrunc(first + second, 2);
                    second = first;
                },
            }
            // One side heard through both halves goes through the bands
            // once.
            if (equalizer) |eq| {
                first = eq.equalize(0, first);
                second = if (sides == .mono) first else eq.equalize(1, second);
            }
            out[(start + frame) * 2] = clip(first);
            out[(start + frame) * 2 + 1] = clip(second);
        }
    }
    return done;
}

/// Frames mixed at a time. Their sums are kept while each voice is added
/// in, a voice at a time, so a voice's loop is the one made for its form
/// and channels: a choice of form made for every sample read costs a
/// quarter of the mix.
const run_frames: usize = 64;

/// One voice added into the sums of a run of frames, each write it gets
/// to in the loop for its form and channels.
fn addVoice(v: *Voice, voice: usize, sums: []i32, done: *Done, refill: ?Refill) void {
    const count = sums.len / 2;
    var frame: usize = 0;
    while (frame < count) {
        if (!v.playing() or v.stopped != 0) return;
        if (v.index >= v.frames and !advance(v, voice, done, refill)) return;
        const stereo = v.channels == 2;
        frame = switch (v.format) {
            s8 => if (stereo) addFrames(s8, 2, v, sums, frame) else addFrames(s8, 1, v, sums, frame),
            s32 => if (stereo) addFrames(s32, 2, v, sums, frame) else addFrames(s32, 1, v, sums, frame),
            else => if (stereo) addFrames(s16, 2, v, sums, frame) else addFrames(s16, 1, v, sums, frame),
        };
    }
}

/// The voice's write added into the sums from `from` on, until the run
/// ends or the write's frames do: the frame it stopped at. A one-channel
/// write is heard on both sides, each at its gain; a two-channel one
/// keeps its sides.
fn addFrames(comptime format: u8, comptime channels: u8, v: *Voice, sums: []i32, from: usize) usize {
    const count = sums.len / 2;
    var frame = from;
    while (frame < count and v.index < v.frames) : (frame += 1) {
        const fine = v.fraction >> (shift - fine_shift);
        const first = blendIn(format, v, 0, fine);
        const second = if (channels == 2) blendIn(format, v, 1, fine) else first;
        sums[frame * 2] += (first * v.gain_left + gain_half) >> gain_shift;
        sums[frame * 2 + 1] += (second * v.gain_right + gain_half) >> gain_shift;
        v.fraction += v.step;
        const moved = v.fraction >> shift;
        v.index += moved;
        v.played +%= moved;
        v.fraction &= one - 1;
    }
    return frame;
}

/// How finely the line between two frames is followed: to `1 <<
/// fine_shift`ths of the way.
const fine_shift: u5 = 15;

/// The line between a voice's frame under its position and the one after
/// it, in `format`, on channel `channel`, `fine` 32768ths of the way
/// along, rounded to the nearest: a 16-bit sample. The difference of two
/// 16-bit samples times a 15-bit fraction, rounded, still fits 32 bits.
fn blendIn(comptime format: u8, v: *const Voice, channel: usize, fine: u32) i32 {
    const data = v.data.?;
    const here = sampleIn(format, data, v.channels, v.index, channel);
    const after = v.index + 1;
    const next = if (after < v.frames) sampleIn(format, data, v.channels, after, channel) else nextSample(v, channel);
    return here + (((next - here) * @as(i32, @intCast(fine)) + (1 << (fine_shift - 1))) >> fine_shift);
}

/// Frame `frame`'s sample on `channel` of frames in `format`, at 16 bits.
/// A one-channel write has its one sample for either channel.
fn sampleAt(data: [*]const u8, format: u8, channels: u8, frame: u32, channel: usize) i32 {
    return switch (format) {
        s8 => sampleIn(s8, data, channels, frame, channel),
        s32 => sampleIn(s32, data, channels, frame, channel),
        else => sampleIn(s16, data, channels, frame, channel),
    };
}

/// `sampleAt` for a form known while compiling. A 32-bit sample is
/// rounded to the nearest: the bit below the cut added - the top of the
/// scale rounds to 32768, which the mix clips.
fn sampleIn(comptime format: u8, data: [*]const u8, channels: u8, frame: u32, channel: usize) i32 {
    const slot = @as(usize, frame) * channels + @min(channel, channels - 1);
    switch (format) {
        s8 => return @as(i32, @as(i8, @bitCast(data[slot]))) * 256,
        s32 => {
            const at = slot * 4;
            const word = @as(u32, data[at]) | @as(u32, data[at + 1]) << 8 | @as(u32, data[at + 2]) << 16 | @as(u32, data[at + 3]) << 24;
            return (@as(i32, @bitCast(word)) >> 16) + @as(i32, @intCast((word >> 15) & 1));
        },
        else => {
            const at = slot * 2;
            const half = @as(u16, data[at]) | @as(u16, data[at + 1]) << 8;
            return @as(i16, @bitCast(half));
        },
    }
}

/// The sample after the frame under a voice's position: the next of its
/// frames, the first again for another loop, the queued write's first, or
/// silence after the last.
fn nextSample(v: *const Voice, channel: usize) i32 {
    const after = v.index + 1;
    if (after < v.frames) return sampleAt(v.data.?, v.format, v.channels, after, channel);
    if (v.endless != 0 or v.loops > 1) return sampleAt(v.data.?, v.format, v.channels, 0, channel);
    if (v.queued.data) |data| return sampleAt(data, v.queued.format, v.queued.channels, 0, channel);
    return 0;
}

/// A voice whose position has run past its frames: another loop of them,
/// the write queued behind them, or silence - false then. What ran past
/// the end is carried into what comes next.
fn advance(v: *Voice, voice: usize, done: *Done, refill: ?Refill) bool {
    while (v.index >= v.frames) {
        const past = v.index - v.frames;
        if (v.endless != 0 or v.loops > 1) {
            if (v.endless == 0) v.loops -= 1;
            v.index = past;
            continue;
        }
        done.ended[voice] +|= 1;
        const next = v.queued;
        v.queued = .{};
        const data = next.data orelse {
            v.data = null;
            v.loops = 0;
            done.finished |= @as(u32, 1) << @intCast(voice);
            return false;
        };
        v.data = data;
        v.frames = next.frames;
        v.format = next.format;
        v.channels = next.channels;
        v.loops = next.loops;
        v.endless = if (next.loops == 0) 1 else 0;
        v.index = past;
        if (refill) |source| {
            if (source.next(source.context, voice)) |following| v.queued = following;
        }
    }
    return true;
}

fn clip(value: i64) i16 {
    if (value > std.math.maxInt(i16)) return std.math.maxInt(i16);
    if (value < std.math.minInt(i16)) return std.math.minInt(i16);
    return @intCast(value);
}

// --- the equalizer --------------------------------------------------------

/// The bands: how many, the frequency in the middle of each in Hz, an
/// octave apart, and how many dB a band is raised or lowered at most.
pub const eq_bands = 10;
pub const eq_frequencies = [eq_bands]u32{ 31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 };
pub const eq_range = 12;

/// A band's coefficients are in `1 << coef_shift`ths: room for the
/// largest, near 2.3 for a high band raised 12 dB, and fine enough for
/// the 31 Hz band's, which differ from 1 and 2 by a few thousandths.
const coef_shift: u6 = 28;
const coef_one: i64 = 1 << coef_shift;
/// The bits a sample carries below its 16 while it goes through the
/// bands: each band's rounding lands there, not on what is heard.
const eq_fraction: u6 = 8;
/// The most a sample going in may be: 32 times full scale, past which it
/// is clipped whatever the bands do, since they lower by 12 dB at most.
/// With the fraction, 2^28.
const in_limit: i64 = 32 << 15;
/// The most a band gives out, with the fraction: 2^29 - twice the most
/// that goes in - so that the difference of a sample in and one out fits
/// 32 bits, and a product of a sample and a coefficient, four of them
/// summed, 64.
const out_limit: i64 = 1 << 29;

/// A band's filter: a peak an octave wide, its coefficients in
/// `1 << coef_shift`ths with the first of the feedback ones made 1. A
/// peak's middle ones, b1 and a1, are the same, so one does for both:
/// b1 x1 - a1 y1 is `middle` (x1 - y1), a product less a sample.
pub const Filter = extern struct {
    b0: i32 = 0,
    middle: i32 = 0,
    b2: i32 = 0,
    a2: i32 = 0,
};

/// What a band remembers of one side: the two samples that went in last
/// and the two that came out, and what the rounding of the last left over,
/// added to the next.
pub const History = extern struct {
    x1: i32 = 0,
    x2: i32 = 0,
    y1: i32 = 0,
    y2: i32 = 0,
    rest: i32 = 0,
};

/// The bands as the mix runs them: the filters of those raised or
/// lowered, each side's history through each, and the gain that goes over
/// the sum first.
pub const Equalizer = extern struct {
    filters: [eq_bands]Filter = @splat(.{}),
    history: [eq_bands][2]History = @splat(@splat(.{})),
    /// The last two samples into the first band, a side each: what a band
    /// that comes on takes as having heard and given out.
    heard: [2][2]i32 = @splat(@splat(0)),
    /// The bands that filter, a bit each: those raised or lowered, below
    /// 0.45 of the output's rate.
    on: u32 = 0,
    /// The gain over the sum before the bands, in 4096ths: down by as much
    /// as the highest band is raised.
    preamp: i32 = gain_unity,

    /// The filters made for `bands` - each band raised or lowered that
    /// many dB, past `eq_range` held to it - at an output's `rate`. A band
    /// so high that its peak would reach half the rate is left out. A band
    /// that comes on is given what came into it lately as its history; one
    /// that stays on keeps its own.
    pub fn tune(eq: *Equalizer, bands: *const [eq_bands]i8, rate: u32) void {
        const before = eq.on;
        eq.on = 0;
        var raised: usize = 0;
        for (bands, 0..) |given, band| {
            const db: i32 = @max(@min(given, eq_range), -eq_range);
            if (db == 0 or @as(u64, eq_frequencies[band]) * 20 >= @as(u64, rate) * 9) continue;
            eq.filters[band] = peak(eq_frequencies[band], db, rate);
            eq.on |= @as(u32, 1) << @intCast(band);
            if (db > 0) raised = @max(raised, @as(usize, @intCast(db)));
        }
        eq.preamp = preamps[raised];
        for (0..2) |side| {
            var x1 = eq.heard[side][0];
            var x2 = eq.heard[side][1];
            for (0..eq_bands) |band| {
                const bit = @as(u32, 1) << @intCast(band);
                if (eq.on & bit == 0) continue;
                const history = &eq.history[band][side];
                if (before & bit == 0) history.* = .{ .x1 = x1, .x2 = x2, .y1 = x1, .y2 = x2 };
                x1 = history.y1;
                x2 = history.y2;
            }
        }
    }

    /// One side's sample, at 16 bits, through every band that is on.
    fn equalize(eq: *Equalizer, side: usize, sample: i64) i64 {
        const in: i32 = @intCast(@max(@min(sample, in_limit), -in_limit) << eq_fraction);
        const heard = &eq.heard[side];
        heard[1] = heard[0];
        heard[0] = in;
        if (eq.on == 0) return sample;
        var x = in;
        var on = eq.on;
        while (on != 0) : (on &= on - 1) {
            const band = @ctz(on);
            const filter = &eq.filters[band];
            const history = &eq.history[band][side];
            // Wrapping: the limits keep every sum inside 64 bits, and the
            // checks the operators would add are a fifth of what a band
            // costs a 32-bit chip.
            const sum = (@as(i64, filter.b0) *% x) +% (@as(i64, filter.middle) *% (history.x1 -% history.y1)) +%
                (@as(i64, filter.b2) *% history.x2) -% (@as(i64, filter.a2) *% history.y2) +% history.rest;
            const y: i32 = @truncate(@max(@min(sum >> coef_shift, out_limit), -out_limit));
            history.rest = @truncate(sum & (coef_one - 1));
            history.x2 = history.x1;
            history.x1 = x;
            history.y2 = history.y1;
            history.y1 = y;
            x = y;
        }
        return (@as(i64, x) + (1 << (eq_fraction - 1))) >> eq_fraction;
    }
};

/// How wide a band's peak is: an octave, from half its height below to
/// half above.
const q_octave: f64 = std.math.sqrt2;

/// 10^(dB/40) for each dB from -`eq_range` to `eq_range`: the root of a
/// peak's height, as its coefficients take it.
const amplitudes = table: {
    var made: [2 * eq_range + 1]f64 = undefined;
    for (&made, 0..) |*amplitude, at| {
        const db: f64 = @floatFromInt(@as(i32, @intCast(at)) - eq_range);
        amplitude.* = @exp(db / 40.0 * std.math.ln10);
    }
    break :table made;
};

/// The gain over the sum for each dB the highest band is raised, from 0
/// to `eq_range`, in 4096ths: that many dB down.
const preamps = table: {
    var made: [eq_range + 1]i32 = undefined;
    for (&made, 0..) |*preamp, raised| {
        const db: f64 = @floatFromInt(raised);
        preamp.* = @intFromFloat(@round(@as(f64, @floatFromInt(gain_unity)) * @exp(-db / 20.0 * std.math.ln10)));
    }
    break :table made;
};

/// A band's filter: a peak `db` dB high in the middle, at `frequency` in
/// an output at `rate`, an octave wide. With A = 10^(dB/40), w0 = 2 pi
/// frequency / rate and alpha = sin(w0) / 2Q, it is
///
///   b0 = 1 + alpha A    b1 = -2 cos(w0)    b2 = 1 - alpha A
///   a0 = 1 + alpha / A  a1 = -2 cos(w0)    a2 = 1 - alpha / A
///
/// each divided by a0: at `frequency` it gives A squared, far from it 1.
fn peak(frequency: u32, db: i32, rate: u32) Filter {
    const amplitude = amplitudes[@intCast(db + eq_range)];
    const w0 = 2.0 * std.math.pi * @as(f64, @floatFromInt(frequency)) / @as(f64, @floatFromInt(rate));
    const alpha = @sin(w0) / (2.0 * q_octave);
    const cos_w0 = @cos(w0);
    const a0 = 1.0 + alpha / amplitude;
    return .{
        .b0 = coefficient((1.0 + alpha * amplitude) / a0),
        .middle = coefficient(-2.0 * cos_w0 / a0),
        .b2 = coefficient((1.0 - alpha * amplitude) / a0),
        .a2 = coefficient((1.0 - alpha / amplitude) / a0),
    };
}

fn coefficient(value: f64) i32 {
    return @intFromFloat(@floor(value * @as(f64, @floatFromInt(coef_one)) + 0.5));
}

// --- tests --------------------------------------------------------------------------

const testing = std.testing;

/// Bytes of 16-bit samples, in the machine's order, for a test's writes.
fn pcm16(comptime samples: []const i16) [samples.len * 2]u8 {
    var bytes: [samples.len * 2]u8 = undefined;
    for (samples, 0..) |sample, i| {
        const word: u16 = @bitCast(sample);
        bytes[i * 2] = @truncate(word);
        bytes[i * 2 + 1] = @truncate(word >> 8);
    }
    return bytes;
}

fn bytesOf(comptime samples: []const i8) [samples.len]u8 {
    var bytes: [samples.len]u8 = undefined;
    for (samples, 0..) |sample, i| bytes[i] = @bitCast(sample);
    return bytes;
}

/// A voice of 16-bit mono frames, a frame an output frame, played once.
fn monoVoice(data: []const u8) Voice {
    return .{ .data = data.ptr, .frames = @intCast(data.len / 2), .format = s16, .channels = 1, .step = one, .loops = 1 };
}

test "the step: a stream's rate against the output's" {
    try testing.expectEqual(one / 2, stepFor(24_000, 48_000));
    try testing.expectEqual(one * 2, stepFor(96_000, 48_000));
    try testing.expectEqual(one, stepFor(48_000, 48_000));
    try testing.expectEqual(@as(u32, 0), stepFor(0, 48_000));
    // 44.1 kHz into 48: a little under a frame each.
    try testing.expectEqual(@as(u32, 60_211), stepFor(44_100, 48_000));
}

test "the gains: the middle is both sides at the volume, a pan turns the other side down" {
    const middle = gains(0x10000, 0);
    try testing.expectEqual(gain_unity, middle.left);
    try testing.expectEqual(gain_unity, middle.right);
    const right_only = gains(0x10000, 0x10000);
    try testing.expectEqual(@as(i32, 0), right_only.left);
    try testing.expectEqual(gain_unity, right_only.right);
    const half_left = gains(0x10000, -0x8000);
    try testing.expectEqual(gain_unity, half_left.left);
    try testing.expectEqual(gain_unity / 2, half_left.right);
    // Twice as loud, and no more than four times.
    try testing.expectEqual(gain_unity * 2, gains(0x20000, 0).left);
    try testing.expectEqual(gain_unity * 4, gains(0x100000, 0).left);
}

test "16-bit mono plays on both sides, once, then silence" {
    const data = pcm16(&.{ 1000, -2000 });
    var voices: [max_voices]Voice = @splat(.{});
    voices[0] = monoVoice(&data);
    var out: [8]i16 = @splat(0);
    const done = fill(&voices, &out, .left_first, gain_unity, null, null);
    try testing.expectEqualSlices(i16, &.{ 1000, 1000, -2000, -2000, 0, 0, 0, 0 }, &out);
    try testing.expectEqual(@as(u16, 1), done.ended[0]);
    try testing.expectEqual(@as(u32, 1), done.finished);
    try testing.expectEqual(@as(u32, 2), voices[0].played);
}

test "8-bit and 32-bit samples are heard at 16 bits" {
    const eight = bytesOf(&.{ 100, -100 });
    var voices: [max_voices]Voice = @splat(.{});
    voices[0] = .{ .data = &eight, .frames = 2, .format = s8, .channels = 1, .step = one, .loops = 1 };
    var out: [4]i16 = @splat(0);
    _ = fill(&voices, &out, .left_first, gain_unity, null, null);
    try testing.expectEqualSlices(i16, &.{ 100 * 256, 100 * 256, -100 * 256, -100 * 256 }, &out);

    // A 32-bit sample: its top 16 bits, the low ones rounded away.
    const word: u32 = @bitCast(@as(i32, -1234) << 16 | 0x55);
    const wide = [4]u8{ @truncate(word), @truncate(word >> 8), @truncate(word >> 16), @truncate(word >> 24) };
    voices[0] = .{ .data = &wide, .frames = 1, .format = s32, .channels = 1, .step = one, .loops = 1 };
    var one_frame: [2]i16 = @splat(0);
    _ = fill(&voices, &one_frame, .left_first, gain_unity, null, null);
    try testing.expectEqual(@as(i16, -1234), one_frame[0]);
}

test "a stereo stream keeps its sides, each at its own gain" {
    const data = pcm16(&.{ 1000, -3000 });
    var voices: [max_voices]Voice = @splat(.{});
    voices[0] = .{ .data = &data, .frames = 1, .format = s16, .channels = 2, .step = one, .loops = 1 };
    const g = gains(0x10000, 0x8000); // the left side halved
    voices[0].gain_left = g.left;
    voices[0].gain_right = g.right;
    var out: [2]i16 = @splat(0);
    _ = fill(&voices, &out, .left_first, gain_unity, null, null);
    try testing.expectEqualSlices(i16, &.{ 500, -3000 }, &out);
}

test "voices are summed, the master goes over them, and the sum is clipped" {
    const loud = pcm16(&.{20_000});
    var voices: [max_voices]Voice = @splat(.{});
    voices[0] = monoVoice(&loud);
    voices[0].endless = 1;
    voices[1] = voices[0];
    var out: [2]i16 = @splat(0);
    _ = fill(&voices, &out, .left_first, gain_unity, null, null);
    try testing.expectEqual(std.math.maxInt(i16), out[0]);
    // At half the master the pair fits.
    _ = fill(&voices, &out, .left_first, gain_unity / 2, null, null);
    try testing.expectEqual(@as(i16, 20_000), out[0]);
    // Nothing at all.
    _ = fill(&voices, &out, .left_first, 0, null, null);
    try testing.expectEqual(@as(i16, 0), out[0]);
}

test "loops: a write played n times, or for ever" {
    const data = pcm16(&.{ 1, 2 });
    var voices: [max_voices]Voice = @splat(.{});
    voices[0] = monoVoice(&data);
    voices[0].loops = 2;
    var out: [10]i16 = @splat(0);
    const done = fill(&voices, &out, .left_first, gain_unity, null, null);
    try testing.expectEqualSlices(i16, &.{ 1, 1, 2, 2, 1, 1, 2, 2, 0, 0 }, &out);
    try testing.expectEqual(@as(u16, 1), done.ended[0]);

    voices[0] = monoVoice(&data);
    voices[0].endless = 1;
    var forever: [16]i16 = @splat(0);
    const none = fill(&voices, &forever, .left_first, gain_unity, null, null);
    try testing.expectEqual(@as(u32, 0), none.finished);
    try testing.expect(voices[0].playing());
}

test "a queued write in another form follows in the frame the first one ends in" {
    const first = pcm16(&.{ 10, 20 });
    const second = bytesOf(&.{ 1, 2 });
    var voices: [max_voices]Voice = @splat(.{});
    voices[0] = monoVoice(&first);
    voices[0].queued = .{ .data = &second, .frames = 2, .loops = 1, .format = s8, .channels = 1 };
    var out: [10]i16 = @splat(0);
    const done = fill(&voices, &out, .left_first, gain_unity, null, null);
    const heard = [_]i16{ 10, 20, 256, 512, 0 };
    for (heard, 0..) |sample, frame| try testing.expectEqual(sample, out[frame * 2]);
    try testing.expectEqual(@as(u16, 2), done.ended[0]);
    try testing.expectEqual(@as(u32, 1), done.finished);
}

test "between two frames the line between them plays" {
    const ramp = pcm16(&.{ 0, 1000 });
    var voices: [max_voices]Voice = @splat(.{});
    voices[0] = monoVoice(&ramp);
    voices[0].step = one / 4;
    var out: [12]i16 = @splat(0);
    _ = fill(&voices, &out, .left_first, gain_unity, null, null);
    const heard = [_]i16{ 0, 250, 500, 750, 1000, 750 };
    for (heard, 0..) |sample, frame| try testing.expectEqual(sample, out[frame * 2]);
}

test "a 32-bit sample is rounded to the nearest 16-bit one, not cut" {
    const cases = [_]struct { word: u32, heard: i32 }{
        .{ .word = 0x0000_7FFF, .heard = 0 },
        .{ .word = 0x0000_8000, .heard = 1 },
        .{ .word = 0x0123_C000, .heard = 0x124 },
        .{ .word = 0xFFFF_8000, .heard = 0 },
        .{ .word = 0xFFFF_7FFF, .heard = -1 },
        .{ .word = 0x8000_0000, .heard = -32768 },
        // The top of the scale rounds past it; the mix clips it back.
        .{ .word = 0x7FFF_FFFF, .heard = 32768 },
    };
    for (cases) |case| {
        const wide = [4]u8{ @truncate(case.word), @truncate(case.word >> 8), @truncate(case.word >> 16), @truncate(case.word >> 24) };
        try testing.expectEqual(case.heard, sampleAt(&wide, s32, 1, 0, 0));
    }
}

test "the line between two frames is followed to within half a step, wherever along it" {
    const ramp = pcm16(&.{ -30_000, 30_000 });
    const v = monoVoice(&ramp);
    var fine: u32 = 0;
    while (fine < 1 << fine_shift) : (fine += 1) {
        const heard: i64 = blendIn(s16, &v, 0, fine);
        // The exact point, doubled and in 32768ths: -30000 + 60000 * fine / 32768.
        const exact2: i64 = 2 * (-30_000 * 32_768 + 60_000 * @as(i64, fine));
        const off = heard * 2 * 32_768 - exact2;
        try testing.expect(off <= 32_768 and off >= -32_768);
    }
}

test "what runs past the end is carried into the next write" {
    const first = pcm16(&.{ 100, 200 });
    const second = pcm16(&.{ 300, 400, 500, 600 });
    var voices: [max_voices]Voice = @splat(.{});
    voices[0] = monoVoice(&first);
    voices[0].step = one + one / 2;
    voices[0].queued = .{ .data = &second, .frames = 4, .loops = 1, .format = s16, .channels = 1 };
    var out: [6]i16 = @splat(0);
    _ = fill(&voices, &out, .left_first, gain_unity, null, null);
    // 100, half way from 200 to 300, then the next write's second frame.
    try testing.expectEqual(@as(i16, 100), out[0]);
    try testing.expectEqual(@as(i16, 250), out[2]);
    try testing.expectEqual(@as(i16, 400), out[4]);
}

test "a stopped voice is silent and keeps its place" {
    const ramp = pcm16(&.{ 10, 20, 30 });
    var voices: [max_voices]Voice = @splat(.{});
    voices[0] = monoVoice(&ramp);
    var out: [2]i16 = @splat(0);
    _ = fill(&voices, &out, .left_first, gain_unity, null, null);
    try testing.expectEqual(@as(i16, 10), out[0]);
    voices[0].stopped = 1;
    _ = fill(&voices, &out, .left_first, gain_unity, null, null);
    try testing.expectEqual(@as(i16, 0), out[0]);
    voices[0].stopped = 0;
    _ = fill(&voices, &out, .left_first, gain_unity, null, null);
    try testing.expectEqual(@as(i16, 20), out[0]);
}

test "a mono output hears both sides together; sides the other way round" {
    const data = pcm16(&.{ 1000, -400 });
    var voices: [max_voices]Voice = @splat(.{});
    voices[0] = .{ .data = &data, .frames = 1, .format = s16, .channels = 2, .step = 0, .endless = 1 };
    var out: [2]i16 = @splat(0);
    _ = fill(&voices, &out, .mono, gain_unity, null, null);
    try testing.expectEqualSlices(i16, &.{ 300, 300 }, &out);
    _ = fill(&voices, &out, .right_first, gain_unity, null, null);
    try testing.expectEqualSlices(i16, &.{ -400, 1000 }, &out);
}

/// Short writes one after another, handed over as each is taken.
const Feed = struct {
    blocks: []const []const u8,
    given: usize = 0,

    fn next(context: *anyopaque, _: usize) ?Queued {
        const feed: *Feed = @ptrCast(@alignCast(context));
        if (feed.given == feed.blocks.len) return null;
        const block = feed.blocks[feed.given];
        feed.given += 1;
        return .{ .data = block.ptr, .frames = @intCast(block.len / 2), .loops = 1, .format = s16, .channels = 1 };
    }
};

test "a queue of short writes plays without a gap, each asked for as the last is taken" {
    const a = pcm16(&.{1});
    const b = pcm16(&.{ 2, 3 });
    const c = pcm16(&.{4});
    const d = pcm16(&.{5});
    var feed: Feed = .{ .blocks = &.{ &b, &c, &d } };
    var voices: [max_voices]Voice = @splat(.{});
    voices[0] = monoVoice(&a);
    voices[0].queued = Feed.next(&feed, 0).?;
    var out: [14]i16 = @splat(0);
    const done = fill(&voices, &out, .left_first, gain_unity, .{ .context = &feed, .next = Feed.next }, null);
    const heard = [_]i16{ 1, 2, 3, 4, 5, 0, 0 };
    for (heard, 0..) |sample, frame| try testing.expectEqual(sample, out[frame * 2]);
    try testing.expectEqual(@as(u16, 4), done.ended[0]);
    try testing.expectEqual(@as(u32, 5), voices[0].played);
}

var long_write: [140_000]u8 = @splat(0);

test "a write longer than 65536 frames plays to its end" {
    long_write[long_write.len - 2] = 99;
    var voices: [max_voices]Voice = @splat(.{});
    voices[0] = monoVoice(&long_write);
    var out: [2000]i16 = @splat(0);
    for (0..long_write.len / 2 / 1000) |_| {
        const done = fill(&voices, &out, .left_first, gain_unity, null, null);
        try testing.expectEqual(@as(u16, 0), done.ended[0]);
    }
    try testing.expectEqual(@as(i16, 99), out[out.len - 2]);
    const done = fill(&voices, &out, .left_first, gain_unity, null, null);
    try testing.expectEqual(@as(u16, 1), done.ended[0]);
}

/// A second of a tone and of what came out of the mix, for the
/// equalizer's tests: too big for a test's stack.
var eq_tone: [48_000 * 2]u8 = @splat(0);
var eq_out: [48_000 * 2]i16 = @splat(0);

/// `buffer` filled with a tone of `frequency` at 48 kHz, `amplitude` high,
/// as 16-bit mono.
fn toneOf(buffer: []u8, frequency: f64, amplitude: f64) void {
    for (0..buffer.len / 2) |frame| {
        const along = 2.0 * std.math.pi * frequency * @as(f64, @floatFromInt(frame)) / 48_000.0;
        const word: u16 = @bitCast(@as(i16, @intFromFloat(@round(amplitude * @sin(along)))));
        buffer[frame * 2] = @truncate(word);
        buffer[frame * 2 + 1] = @truncate(word >> 8);
    }
}

/// How loud a tone of `frequency` comes out through `bands`, in dB
/// against how loud it went in: over the second half of a second, once
/// the bands have settled.
fn heardDb(frequency: f64, bands: *const [eq_bands]i8) f64 {
    toneOf(&eq_tone, frequency, 8000);
    var voices: [max_voices]Voice = @splat(.{});
    voices[0] = monoVoice(&eq_tone);
    var eq: Equalizer = .{};
    eq.tune(bands, 48_000);
    _ = fill(&voices, &eq_out, .left_first, gain_unity, null, &eq);
    var went: f64 = 0;
    var came: f64 = 0;
    for (24_000..48_000) |frame| {
        const in: f64 = @floatFromInt(sampleAt(&eq_tone, s16, 1, @intCast(frame), 0));
        const out: f64 = @floatFromInt(eq_out[frame * 2]);
        went += in * in;
        came += out * out;
    }
    return 10.0 * std.math.log10(came / went);
}

fn expectDb(expected: f64, heard: f64) !void {
    try testing.expectApproxEqAbs(expected, heard, 0.5);
}

test "the equalizer flat leaves the mix as it was, to the bit, even after a band was moved and put back" {
    toneOf(&eq_tone, 440, 12_000);
    var voices: [max_voices]Voice = @splat(.{});
    voices[0] = monoVoice(&eq_tone);
    voices[0].step = one + one / 3;
    var plain: [4096]i16 = undefined;
    _ = fill(&voices, &plain, .left_first, gain_unity * 3, null, null);

    voices[0] = monoVoice(&eq_tone);
    voices[0].step = one + one / 3;
    var eq: Equalizer = .{};
    var bands: [eq_bands]i8 = @splat(0);
    bands[2] = 5;
    eq.tune(&bands, 48_000);
    bands[2] = 0;
    eq.tune(&bands, 48_000);
    try testing.expectEqual(@as(u32, 0), eq.on);
    var equalized: [4096]i16 = undefined;
    _ = fill(&voices, &equalized, .left_first, gain_unity * 3, null, &eq);
    try testing.expectEqualSlices(i16, &plain, &equalized);
}

test "a band raised keeps its tone where it was and turns the rest down by as much" {
    var bands: [eq_bands]i8 = @splat(0);
    bands[5] = 12; // 1 kHz
    try expectDb(0, heardDb(1000, &bands));
    try expectDb(-12, heardDb(62.5, &bands));
    try expectDb(-12, heardDb(16_000, &bands));
    // Half way to the next band, half the height.
    try expectDb(-6, heardDb(1414, &bands));
}

test "a band lowered takes its tone down and leaves the rest" {
    var bands: [eq_bands]i8 = @splat(0);
    bands[1] = -12; // 62 Hz
    try expectDb(-12, heardDb(62, &bands));
    try expectDb(0, heardDb(1000, &bands));
    bands = @splat(0);
    bands[9] = -6; // 16 kHz
    try expectDb(-6, heardDb(16_000, &bands));
    try expectDb(0, heardDb(250, &bands));
}

test "the lowest bands, raised and lowered, die away to nothing once the sound has gone" {
    var bands: [eq_bands]i8 = @splat(0);
    bands[0] = 12;
    bands[1] = -12;
    bands[2] = 7;
    var eq: Equalizer = .{};
    eq.tune(&bands, 48_000);
    toneOf(&eq_tone, 40, 30_000);
    var voices: [max_voices]Voice = @splat(.{});
    voices[0] = monoVoice(eq_tone[0 .. 12_000 * 2]);
    var out: [2 * 4800]i16 = undefined;
    // A quarter of a second of loud bass, then two seconds of nothing.
    for (0..55) |_| _ = fill(&voices, &out, .left_first, gain_unity, null, &eq);
    for (out) |sample| try testing.expectEqual(@as(i16, 0), sample);
}

test "a band whose peak would reach half the output's rate is left out" {
    var bands: [eq_bands]i8 = @splat(3);
    var eq: Equalizer = .{};
    eq.tune(&bands, 48_000);
    try testing.expectEqual(@as(u32, 0x3FF), eq.on);
    eq.tune(&bands, 22_050);
    try testing.expectEqual(@as(u32, 0x1FF), eq.on);
    eq.tune(&bands, 16_000);
    try testing.expectEqual(@as(u32, 0x0FF), eq.on);
    // Past the range, held to it.
    bands = @splat(0);
    bands[4] = 40;
    eq.tune(&bands, 48_000);
    try testing.expectEqual(preamps[eq_range], eq.preamp);
}
