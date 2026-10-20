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
/// playing, the master gain over their sum. `out` holds two samples a
/// frame, in the order `sides` gives. A voice that takes over its queued
/// write asks `refill` for the next. Answers what ended.
pub fn fill(voices: []Voice, out: []i16, sides: Sides, master: i32, refill: ?Refill) Done {
    var done: Done = .{};
    const frames = out.len / 2;
    var start: usize = 0;
    while (start < frames) : (start += run_frames) {
        const count: usize = @min(run_frames, frames - start);
        var sums: [run_frames * 2]i32 = @splat(0);
        for (voices, 0..) |*v, i| addVoice(v, i, sums[0 .. count * 2], &done, refill);
        for (0..count) |frame| {
            // Sixteen voices at four times their volume overrun 32 bits
            // once the master goes over them, so the master is taken in 64.
            var first: i64 = (@as(i64, sums[frame * 2]) * master + gain_half) >> gain_shift;
            var second: i64 = (@as(i64, sums[frame * 2 + 1]) * master + gain_half) >> gain_shift;
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
    const done = fill(&voices, &out, .left_first, gain_unity, null);
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
    _ = fill(&voices, &out, .left_first, gain_unity, null);
    try testing.expectEqualSlices(i16, &.{ 100 * 256, 100 * 256, -100 * 256, -100 * 256 }, &out);

    // A 32-bit sample: its top 16 bits, the low ones rounded away.
    const word: u32 = @bitCast(@as(i32, -1234) << 16 | 0x55);
    const wide = [4]u8{ @truncate(word), @truncate(word >> 8), @truncate(word >> 16), @truncate(word >> 24) };
    voices[0] = .{ .data = &wide, .frames = 1, .format = s32, .channels = 1, .step = one, .loops = 1 };
    var one_frame: [2]i16 = @splat(0);
    _ = fill(&voices, &one_frame, .left_first, gain_unity, null);
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
    _ = fill(&voices, &out, .left_first, gain_unity, null);
    try testing.expectEqualSlices(i16, &.{ 500, -3000 }, &out);
}

test "voices are summed, the master goes over them, and the sum is clipped" {
    const loud = pcm16(&.{20_000});
    var voices: [max_voices]Voice = @splat(.{});
    voices[0] = monoVoice(&loud);
    voices[0].endless = 1;
    voices[1] = voices[0];
    var out: [2]i16 = @splat(0);
    _ = fill(&voices, &out, .left_first, gain_unity, null);
    try testing.expectEqual(std.math.maxInt(i16), out[0]);
    // At half the master the pair fits.
    _ = fill(&voices, &out, .left_first, gain_unity / 2, null);
    try testing.expectEqual(@as(i16, 20_000), out[0]);
    // Nothing at all.
    _ = fill(&voices, &out, .left_first, 0, null);
    try testing.expectEqual(@as(i16, 0), out[0]);
}

test "loops: a write played n times, or for ever" {
    const data = pcm16(&.{ 1, 2 });
    var voices: [max_voices]Voice = @splat(.{});
    voices[0] = monoVoice(&data);
    voices[0].loops = 2;
    var out: [10]i16 = @splat(0);
    const done = fill(&voices, &out, .left_first, gain_unity, null);
    try testing.expectEqualSlices(i16, &.{ 1, 1, 2, 2, 1, 1, 2, 2, 0, 0 }, &out);
    try testing.expectEqual(@as(u16, 1), done.ended[0]);

    voices[0] = monoVoice(&data);
    voices[0].endless = 1;
    var forever: [16]i16 = @splat(0);
    const none = fill(&voices, &forever, .left_first, gain_unity, null);
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
    const done = fill(&voices, &out, .left_first, gain_unity, null);
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
    _ = fill(&voices, &out, .left_first, gain_unity, null);
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
    _ = fill(&voices, &out, .left_first, gain_unity, null);
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
    _ = fill(&voices, &out, .left_first, gain_unity, null);
    try testing.expectEqual(@as(i16, 10), out[0]);
    voices[0].stopped = 1;
    _ = fill(&voices, &out, .left_first, gain_unity, null);
    try testing.expectEqual(@as(i16, 0), out[0]);
    voices[0].stopped = 0;
    _ = fill(&voices, &out, .left_first, gain_unity, null);
    try testing.expectEqual(@as(i16, 20), out[0]);
}

test "a mono output hears both sides together; sides the other way round" {
    const data = pcm16(&.{ 1000, -400 });
    var voices: [max_voices]Voice = @splat(.{});
    voices[0] = .{ .data = &data, .frames = 1, .format = s16, .channels = 2, .step = 0, .endless = 1 };
    var out: [2]i16 = @splat(0);
    _ = fill(&voices, &out, .mono, gain_unity, null);
    try testing.expectEqualSlices(i16, &.{ 300, 300 }, &out);
    _ = fill(&voices, &out, .right_first, gain_unity, null);
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
    const done = fill(&voices, &out, .left_first, gain_unity, .{ .context = &feed, .next = Feed.next });
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
        const done = fill(&voices, &out, .left_first, gain_unity, null);
        try testing.expectEqual(@as(u16, 0), done.ended[0]);
    }
    try testing.expectEqual(@as(i16, 99), out[out.len - 2]);
    const done = fill(&voices, &out, .left_first, gain_unity, null);
    try testing.expectEqual(@as(u16, 1), done.ended[0]);
}
