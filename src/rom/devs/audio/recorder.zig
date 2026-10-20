// SPDX-License-Identifier: MPL-2.0
//! Frames as a way in hears them, turned into the form a recording asks
//! for. Nothing here touches hardware, so the host tests hold all of it.
//!
//! **What comes in** is a source's buffers: stereo frames of 16-bit
//! samples at the rate the source runs at, the two halves as its mode's
//! sides say - for a part that hears one side, that side in the first
//! half. **What goes out** is the recording's own form: 8-, 16- or 32-bit
//! samples, one channel or two, at a rate of its own and a volume. A
//! one-channel recording of two sides is the middle of the two; a
//! two-channel recording of one side has it on both.
//!
//! **The rate is converted** the way the mixer converts it: a position in
//! the heard frames, a whole frame and a fraction of one in 65536ths, and
//! a step to add to it for each frame recorded; what is recorded is the
//! line between the heard frame under the position and the one after it,
//! to 32768ths of the way and rounded. The position counts from the last
//! frame of the buffer before, so the line runs on from one buffer into
//! the next without a seam. A buffer is handed in as often as the reads
//! it fills need - one read may end inside a buffer, the next go on from
//! there - and given up (`passed`) once every frame of it has been
//! reached.
//!
//! **The volume** is a gain in 4096ths, its product rounded, the result
//! clipped to what a 16-bit sample holds before it is put in the
//! recording's form: an 8-bit sample is rounded to the nearest, a 32-bit
//! one is the 16-bit one in its top half.

const std = @import("std");
const mixer = @import("mixer.zig");

const shift = mixer.shift;
const one = mixer.one;
/// How finely the line between two frames is followed.
const fine_shift: u5 = 15;
const gain_shift: u5 = 12;
const gain_half: i32 = 1 << (gain_shift - 1);

/// A sample's form in memory, as the SDK numbers it.
pub const s8 = mixer.s8;
pub const s16 = mixer.s16;
pub const s32 = mixer.s32;

/// One recording's conversion: where it is in what it hears, and what it
/// turns that into.
pub const Recorder = extern struct {
    /// Heard frames for each frame recorded, in 65536ths
    /// (`mixer.stepFor`), and the next recorded frame's place: whole
    /// frames past the last frame of the buffer before - 1 is the first of
    /// this one - and a fraction.
    step: u32 = one,
    position: u32 = one,
    /// The last frame of the buffer before, its two sides; silence at the
    /// start.
    last: [2]i32 = .{ 0, 0 },
    /// The recording's form, and its gain in 4096ths
    /// (`mixer.masterGain` of its volume).
    format: u8 = s16,
    channels: u8 = 2,
    /// What the halves of a heard frame carry, as the way in's mode says.
    heard: mixer.Sides = .left_first,
    pad: u8 = 0,
    gain: i32 = 1 << gain_shift,

    /// The recording started afresh: from the first frame of the next
    /// buffer, after silence.
    pub fn restart(r: *Recorder) void {
        r.position = one;
        r.last = .{ 0, 0 };
    }
};

/// Bytes a recorded frame takes, 0 for a form not known.
pub fn frameBytes(format: u8, channels: u8) u32 {
    const sample: u32 = switch (format) {
        s8 => 1,
        s16 => 2,
        s32 => 4,
        else => return 0,
    };
    return if (channels == 1 or channels == 2) sample * channels else 0;
}

/// Frames recorded from `heard` - a buffer of stereo frames - into `into`,
/// from where the recorder stands, until `into` has no room for another
/// frame or every frame of `heard` up to its last has been reached: the
/// bytes written, whole frames.
pub fn take(r: *Recorder, heard: []const i16, into: []u8) usize {
    const frames: u32 = @intCast(heard.len / 2);
    const bytes = frameBytes(r.format, r.channels);
    var written: usize = 0;
    while (written + bytes <= into.len) {
        // The frame under the position and the one after it, 0 the last of
        // the buffer before; on the last frame itself, that frame alone.
        const index = r.position >> shift;
        const fraction = r.position & (one - 1);
        if (index > frames or (index == frames and fraction != 0)) break;
        const fine: i32 = @intCast(fraction >> (shift - fine_shift));
        var sides: [2]i32 = undefined;
        for (0..2) |side| {
            const here = heardAt(r, heard, index, side);
            sides[side] = if (fine == 0) here else blk: {
                const after = heardAt(r, heard, index + 1, side);
                break :blk here + (((after - here) * fine + (1 << (fine_shift - 1))) >> fine_shift);
            };
        }
        put(r, into[written..], sides);
        written += bytes;
        r.position += r.step;
    }
    return written;
}

/// Whether every frame of a buffer of `frames` frames has been reached:
/// the next one recorded lies past it.
pub fn usedUp(r: *const Recorder, frames: u32) bool {
    return r.position > frames << shift;
}

/// `heard` given up - the next buffer goes on from its last frame.
pub fn passed(r: *Recorder, heard: []const i16) void {
    const frames: u32 = @intCast(heard.len / 2);
    if (frames == 0) return;
    r.last = .{ sideOf(r, heard, frames - 1, 0), sideOf(r, heard, frames - 1, 1) };
    r.position -|= frames << shift;
}

/// `heard` let go by unrecorded - a held recording, or one no read waits
/// on: the next buffer is recorded from its first frame, the line into it
/// from this one's last.
pub fn skip(r: *Recorder, heard: []const i16) void {
    const frames: u32 = @intCast(heard.len / 2);
    if (frames == 0) return;
    r.last = .{ sideOf(r, heard, frames - 1, 0), sideOf(r, heard, frames - 1, 1) };
    r.position = one;
}

/// The heard frame at `index` - 0 the last of the buffer before, 1 the
/// first of this one - on `side`.
fn heardAt(r: *const Recorder, heard: []const i16, index: u32, side: usize) i32 {
    if (index == 0) return r.last[side];
    return sideOf(r, heard, index - 1, side);
}

/// Side `side` of heard frame `frame`, 0 the left: the first half for
/// both on a part that hears one side.
fn sideOf(r: *const Recorder, heard: []const i16, frame: u32, side: usize) i32 {
    const half: usize = switch (r.heard) {
        .left_first => side,
        .right_first => 1 - side,
        .mono => 0,
    };
    return heard[@as(usize, frame) * 2 + half];
}

/// A recorded frame of the two sides put into `into`, in the recording's
/// form: one channel their middle.
fn put(r: *const Recorder, into: []u8, sides: [2]i32) void {
    if (r.channels == 1) {
        const middle = if (r.heard == .mono) sides[0] else @divFloor(sides[0] + sides[1] + 1, 2);
        putSample(r, into, 0, middle);
        return;
    }
    putSample(r, into, 0, sides[0]);
    putSample(r, into, 1, sides[1]);
}

/// Sample `slot` of a frame, at the recording's gain, clipped, in its form
/// and in the machine's byte order.
fn putSample(r: *const Recorder, into: []u8, slot: usize, sample: i32) void {
    const loud = clip((@as(i64, sample) * r.gain + gain_half) >> gain_shift);
    switch (r.format) {
        s8 => into[slot] = @bitCast(@as(i8, @intCast(@min((@as(i32, loud) + 128) >> 8, 127)))),
        s32 => {
            const word: u32 = @bitCast(@as(i32, loud) << 16);
            const at = slot * 4;
            into[at] = @truncate(word);
            into[at + 1] = @truncate(word >> 8);
            into[at + 2] = @truncate(word >> 16);
            into[at + 3] = @truncate(word >> 24);
        },
        else => {
            const half: u16 = @bitCast(loud);
            into[slot * 2] = @truncate(half);
            into[slot * 2 + 1] = @truncate(half >> 8);
        },
    }
}

fn clip(value: i64) i16 {
    if (value > std.math.maxInt(i16)) return std.math.maxInt(i16);
    if (value < std.math.minInt(i16)) return std.math.minInt(i16);
    return @intCast(value);
}

// --- tests --------------------------------------------------------------------------

const testing = std.testing;

fn samplesOf(bytes: []const u8) [64]i16 {
    var out: [64]i16 = @splat(0);
    for (0..bytes.len / 2) |n| out[n] = @bitCast(@as(u16, bytes[n * 2]) | @as(u16, bytes[n * 2 + 1]) << 8);
    return out;
}

test "at the source's own rate every frame is recorded as it was heard, across buffers" {
    var r: Recorder = .{};
    const first = [_]i16{ 100, -100, 200, -200, 300, -300 };
    const second = [_]i16{ 400, -400, 500, -500 };
    var into: [64]u8 = undefined;
    var got = take(&r, &first, &into);
    try testing.expectEqual(@as(usize, 12), got);
    try testing.expect(usedUp(&r, 3));
    passed(&r, &first);
    got += take(&r, &second, into[got..]);
    try testing.expectEqual(@as(usize, 20), got);
    const samples = samplesOf(into[0..got]);
    try testing.expectEqualSlices(i16, &.{ 100, -100, 200, -200, 300, -300, 400, -400, 500, -500 }, samples[0..10]);
}

test "a read that ends inside a buffer leaves the rest of it for the next" {
    var r: Recorder = .{ .channels = 1 };
    const heard = [_]i16{ 10, 30, 20, 40, 30, 50, 40, 60 };
    var small: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), take(&r, &heard, &small));
    try testing.expect(!usedUp(&r, 4));
    // The middle of the two sides, rounded.
    try testing.expectEqualSlices(i16, &.{ 20, 30 }, samplesOf(&small)[0..2]);
    try testing.expectEqual(@as(usize, 4), take(&r, &heard, &small));
    try testing.expectEqualSlices(i16, &.{ 40, 50 }, samplesOf(&small)[0..2]);
    try testing.expect(usedUp(&r, 4));
}

test "half the source's rate takes every other frame; double it puts the middle between" {
    var half: Recorder = .{ .step = mixer.stepFor(48_000, 24_000), .channels = 1, .heard = .mono };
    const heard = [_]i16{ 0, 0, 1000, 0, 2000, 0, 3000, 0 };
    var into: [64]u8 = undefined;
    const got = take(&half, &heard, &into);
    try testing.expectEqualSlices(i16, &.{ 0, 2000 }, samplesOf(into[0..got])[0..2]);

    var double: Recorder = .{ .step = mixer.stepFor(24_000, 48_000), .channels = 1, .heard = .mono };
    const twice = take(&double, &heard, &into);
    try testing.expectEqualSlices(i16, &.{ 0, 500, 1000, 1500, 2000, 2500, 3000 }, samplesOf(into[0..twice])[0..7]);
    // Past the last heard frame it waits for the next buffer, and the line
    // runs on into it.
    passed(&double, &heard);
    const next = [_]i16{ 4000, 0 };
    const more = take(&double, &next, &into);
    try testing.expectEqualSlices(i16, &.{ 3500, 4000 }, samplesOf(into[0..more])[0..2]);
}

test "one side heard is recorded on both; 8- and 32-bit forms; the volume is a rounded gain, clipped" {
    var r: Recorder = .{ .heard = .mono, .format = s8, .gain = 1 << gain_shift };
    const heard = [_]i16{ 1000, 9999, -32768, 9999 };
    var into: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), take(&r, &heard, &into));
    try testing.expectEqual(@as(i8, 4), @as(i8, @bitCast(into[0])));
    try testing.expectEqual(@as(i8, 4), @as(i8, @bitCast(into[1])));
    try testing.expectEqual(@as(i8, -128), @as(i8, @bitCast(into[2])));

    var wide: Recorder = .{ .format = s32, .channels = 1, .heard = .mono, .gain = 2 << gain_shift };
    var words: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 8), take(&wide, &.{ 1000, 0, 30000, 0 }, &words));
    const first = @as(u32, words[0]) | @as(u32, words[1]) << 8 | @as(u32, words[2]) << 16 | @as(u32, words[3]) << 24;
    const second = @as(u32, words[4]) | @as(u32, words[5]) << 8 | @as(u32, words[6]) << 16 | @as(u32, words[7]) << 24;
    try testing.expectEqual(@as(i32, 2000 << 16), @as(i32, @bitCast(first)));
    try testing.expectEqual(@as(i32, 32767 << 16), @as(i32, @bitCast(second)));
}
