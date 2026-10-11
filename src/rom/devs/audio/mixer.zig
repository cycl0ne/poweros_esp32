// SPDX-License-Identifier: MPL-2.0
//! Four channels of 8-bit samples into one stereo stream, which is what
//! this machine's codec takes. Nothing here touches hardware, so the host
//! tests hold all of it.
//!
//! A channel plays its samples at a rate of its own: one sample every
//! `period` ticks of the audio clock. The output runs at a rate of its
//! own too, and the two have nothing to do with each other, so a channel
//! keeps a position in its samples - a whole sample and a fraction of one
//! - and a step to add to it per output frame, in sixteenths of
//! sixteenths, because a step is rarely a whole sample. What plays is the
//! line between the sample under the position and the one after it, as
//! far along as the fraction says. Taking the sample under the position
//! alone would hold each one for a whole number of output frames - two
//! or three of them, unevenly, for a sound at 22 kHz - and the unevenness
//! is heard as grit; a chip that holds every sample for exactly its
//! period, with a filter after it, sounds like the line.
//!
//! A channel holds the write after the one it plays, as the hardware's
//! double-buffered registers did: it takes over in the frame the first
//! one ends in, and so does another cycle of a write played more than
//! once, the part of a step that ran past the end carried over. The
//! moment it takes over, the channel asks its owner for the write after
//! that (`Refill`), so a queue of any length - and a program that streams
//! sound as one write after another - is heard without a gap.
//!
//! A fill says what happened at its edges: how many writes each channel
//! played out, and how many cycles ended - each pass through a write's
//! samples - which is when a period and volume held for the end of the
//! cycle (`Channel.sync_step`) take over.
//!
//! The channels are summed as the hardware they are named for wired them:
//! 0 and 3 to the left, 1 and 2 to the right. An output with one speaker
//! gets the two sides' average in both halves of the frame instead, so
//! every channel is heard - and a sound written to a left and a right
//! channel at the level it has on each. A sum past what a 16-bit sample
//! holds is clipped rather than wrapped - wrapping turns a loud note into
//! a shriek.

const std = @import("std");

/// How many channels there are.
pub const channels: usize = 4;

/// The fraction's width: a position and a step are `1 << shift` to the
/// sample.
pub const shift: u5 = 16;
pub const one: u32 = 1 << shift;

/// Which side a channel is summed into, by the hardware's own wiring.
pub fn leftOf(channel: usize) bool {
    return channel == 0 or channel == 3;
}

/// What goes into the two halves of a frame. I2S sends the left side
/// first, and most boards' speakers take it so; a board whose right
/// speaker plays the first half has the sides the other way round; an
/// output that plays one half only - one speaker, one jack - is `mono`,
/// and gets both sides in each.
pub const Sides = enum(u8) { left_first, right_first, mono };

/// A write waiting behind the one a channel plays: its samples, how
/// many, how many times over (0: for ever), and the step and volume it
/// starts with - a step of 0 keeps the channel's own.
pub const Queued = extern struct {
    data: ?[*]const i8 = null,
    length: u32 = 0,
    step: u32 = 0,
    volume: u16 = 0,
    cycles: u16 = 0,
};

/// One channel: what it is playing, where it has got to and how loud.
pub const Channel = extern struct {
    /// The samples, and how many. Null is a channel playing nothing.
    data: ?[*]const i8 = null,
    length: u32 = 0,
    /// Where in the samples - the sample, and how far past it in
    /// `1 << shift`ths - and how far a frame moves it.
    index: u32 = 0,
    fraction: u32 = 0,
    step: u32 = 0,
    /// 0 to 64, as the hardware counted loudness.
    volume: u16 = 0,
    /// Silent and held where it is until started again (CMD_STOP).
    stopped: u16 = 0,
    /// Times still to play; 0 while it plays for ever.
    cycles: u16 = 0,
    /// Whether `cycles` is counted at all.
    endless: u16 = 0,
    /// The write that follows, if there is one (`data` not null).
    queued: Queued = .{},
    /// A step and volume that take over when the cycle playing now ends,
    /// if `has_sync` is set.
    sync_step: u32 = 0,
    sync_volume: u16 = 0,
    has_sync: u16 = 0,

    /// Whether this channel has samples to play.
    pub fn playing(c: *const Channel) bool {
        return c.data != null and c.length != 0;
    }
};

/// What a fill did to the channels.
pub const Done = struct {
    /// How many writes each channel played to their end in this fill, in
    /// the order they were played.
    ended: [channels]u16 = @splat(0),
    /// How many cycles each channel ended: every pass through a write's
    /// samples, the last one of a write included.
    cycles: [channels]u16 = @splat(0),
    /// The channels left with nothing to play, one bit each.
    finished: u32 = 0,
};

/// Where a channel gets the write after the one it has just taken over:
/// `next` answers it, or null when there is none yet. Called inside a
/// fill, in the frame the takeover happens.
pub const Refill = struct {
    context: *anyopaque,
    next: *const fn (context: *anyopaque, channel: usize) ?Queued,
};

/// The step for a channel whose sample rate is `clock / period`, in an
/// output running at `rate`. A period of 0 is nothing to play.
pub fn stepFor(clock: u32, period: u16, rate: u32) u32 {
    if (period == 0 or rate == 0) return 0;
    return @intCast(@as(u64, clock) * one / (@as(u64, period) * rate));
}

/// `frames` stereo frames into `out`, taken from whichever channels are
/// playing. `out` holds two samples a frame, in the order `sides` gives.
/// A channel that takes over its queued write asks `refill` for the next.
/// Answers what ended.
pub fn fill(list: *[channels]Channel, out: []i16, sides: Sides, refill: ?Refill) Done {
    var done: Done = .{};
    const frames = out.len / 2;
    for (0..frames) |frame| {
        var left: i32 = 0;
        var right: i32 = 0;
        for (list, 0..) |*c, i| {
            if (!c.playing() or c.stopped != 0) continue;
            if (c.index >= c.length and !advance(c, i, &done, refill)) continue;
            // The sample and the next, in 256ths: -32768 to 32512.
            const here: i32 = c.data.?[c.index];
            const fine = here * 256 + (nextSample(c) - here) * @as(i32, @intCast(c.fraction >> (shift - 8)));
            // A sample is -128 to 127 and a volume 0 to 64; four times
            // that fills a 16-bit sample, and two channels a side fit
            // because the clip below catches the pair that does not.
            const value = (fine * @as(i32, @intCast(c.volume))) >> 6;
            if (leftOf(i)) left += value else right += value;
            c.fraction += c.step;
            c.index += c.fraction >> shift;
            c.fraction &= one - 1;
        }
        var first = left;
        var second = right;
        switch (sides) {
            .left_first => {},
            .right_first => {
                first = right;
                second = left;
            },
            .mono => {
                first = @divTrunc(left + right, 2);
                second = first;
            },
        }
        out[frame * 2] = clip(first);
        out[frame * 2 + 1] = clip(second);
    }
    return done;
}

/// The sample after the one under a channel's position: the next of its
/// samples, the first again for another cycle, the queued write's first,
/// or silence after the last.
fn nextSample(c: *const Channel) i32 {
    const after = c.index + 1;
    if (after < c.length) return c.data.?[after];
    if (c.endless != 0 or c.cycles > 1) return c.data.?[0];
    if (c.queued.data) |data| return data[0];
    return 0;
}

/// A channel whose position has run past its samples: another cycle of
/// them, the write queued behind them, or silence - false then. What ran
/// past the end is carried into what comes next.
fn advance(c: *Channel, channel: usize, done: *Done, refill: ?Refill) bool {
    while (c.index >= c.length) {
        const past = c.index - c.length;
        done.cycles[channel] +|= 1;
        if (c.has_sync != 0) {
            c.step = c.sync_step;
            c.volume = c.sync_volume;
            c.has_sync = 0;
        }
        if (c.endless != 0 or c.cycles > 1) {
            if (c.endless == 0) c.cycles -= 1;
            c.index = past;
            continue;
        }
        done.ended[channel] +|= 1;
        const next = c.queued;
        c.queued = .{};
        const data = next.data orelse {
            c.data = null;
            c.cycles = 0;
            done.finished |= @as(u32, 1) << @intCast(channel);
            return false;
        };
        c.data = data;
        c.length = next.length;
        c.cycles = next.cycles;
        c.endless = if (next.cycles == 0) 1 else 0;
        if (next.step != 0) {
            c.step = next.step;
            c.volume = next.volume;
        }
        c.index = past;
        if (refill) |source| {
            if (source.next(source.context, channel)) |following| c.queued = following;
        }
    }
    return true;
}

fn clip(value: i32) i16 {
    if (value > std.math.maxInt(i16)) return std.math.maxInt(i16);
    if (value < std.math.minInt(i16)) return std.math.minInt(i16);
    return @intCast(value);
}

// --- tests --------------------------------------------------------------------------

const testing = std.testing;

test "the step: a period against the output's rate" {
    // The clock over the period is the channel's rate; at 48000 out, a
    // channel at 24000 steps half a sample a frame.
    try testing.expectEqual(one / 2, stepFor(48_000, 2, 48_000));
    // And one at twice the output's rate steps two.
    try testing.expectEqual(one * 2, stepFor(48_000 * 2, 1, 48_000));
    try testing.expectEqual(one, stepFor(48_000, 1, 48_000));
    try testing.expectEqual(@as(u32, 0), stepFor(48_000, 0, 48_000));
}

test "a channel plays its samples, once or over and over" {
    const samples = [_]i8{ 100, -100 };
    var list: [channels]Channel = @splat(.{});
    list[0] = .{
        .data = &samples,
        .length = samples.len,
        .step = one, // a sample a frame
        .volume = 64,
        .cycles = 1,
    };
    var out: [8]i16 = @splat(0);
    const done = fill(&list, &out, .left_first, null);
    // Left is channel 0: the two samples, then silence once it has ended.
    try testing.expectEqual(@as(i16, 100 * 64 * 4), out[0]);
    try testing.expectEqual(@as(i16, -100 * 64 * 4), out[2]);
    try testing.expectEqual(@as(i16, 0), out[4]);
    // Nothing reached the right.
    try testing.expectEqual(@as(i16, 0), out[1]);
    try testing.expectEqual(@as(u32, 1), done.finished);
    try testing.expect(!list[0].playing());

    // Two cycles: the samples come round again.
    list[0] = .{ .data = &samples, .length = samples.len, .step = one, .volume = 64, .cycles = 2 };
    var twice: [8]i16 = @splat(0);
    _ = fill(&list, &twice, .left_first, null);
    try testing.expectEqual(@as(i16, 100 * 64 * 4), twice[0]);
    try testing.expectEqual(@as(i16, 100 * 64 * 4), twice[4]);

    // Endless: still playing after the samples ran out.
    list[0] = .{ .data = &samples, .length = samples.len, .step = one, .volume = 64, .endless = 1 };
    var forever: [16]i16 = @splat(0);
    const none = fill(&list, &forever, .left_first, null);
    try testing.expectEqual(@as(u32, 0), none.finished);
    try testing.expect(list[0].playing());
}

test "the sides, the volume and the clip" {
    const loud = [_]i8{127};
    var list: [channels]Channel = @splat(.{});
    // Channels 1 and 2 are the right side; both at once clip rather than
    // wrap.
    list[1] = .{ .data = &loud, .length = 1, .step = 0, .volume = 64, .endless = 1 };
    list[2] = .{ .data = &loud, .length = 1, .step = 0, .volume = 64, .endless = 1 };
    var out: [2]i16 = @splat(0);
    _ = fill(&list, &out, .left_first, null);
    try testing.expectEqual(@as(i16, 0), out[0]);
    try testing.expectEqual(std.math.maxInt(i16), out[1]);

    // Half the volume is half the sample.
    list[2] = .{};
    list[1].volume = 32;
    _ = fill(&list, &out, .left_first, null);
    try testing.expectEqual(@as(i16, 127 * 32 * 4), out[1]);

    // A silent channel is silent.
    list[1].volume = 0;
    _ = fill(&list, &out, .left_first, null);
    try testing.expectEqual(@as(i16, 0), out[1]);
}

test "a queued write follows in the frame the first one ends in" {
    const first = [_]i8{ 10, 20 };
    const second = [_]i8{ 30, 40, 50 };
    var list: [channels]Channel = @splat(.{});
    list[0] = .{ .data = &first, .length = first.len, .step = one, .volume = 64, .cycles = 1 };
    list[0].queued = .{ .data = &second, .length = second.len, .cycles = 1 };
    var out: [14]i16 = @splat(0);
    const done = fill(&list, &out, .left_first, null);
    const heard = [_]i16{ 10, 20, 30, 40, 50, 0, 0 };
    for (heard, 0..) |sample, frame| {
        try testing.expectEqual(sample * 64 * 4, out[frame * 2]);
    }
    try testing.expectEqual(@as(u16, 2), done.ended[0]);
    try testing.expectEqual(@as(u32, 1), done.finished);
}

test "what runs past the end is carried into the next write and the next cycle" {
    // A step and a half: the first write's last sample is left at index
    // 3, one past its end, so the next write starts at its second sample.
    const first = [_]i8{ 1, 2 };
    const second = [_]i8{ 3, 4, 5, 6 };
    var list: [channels]Channel = @splat(.{});
    list[0] = .{ .data = &first, .length = first.len, .step = one + one / 2, .volume = 64, .cycles = 1 };
    list[0].queued = .{ .data = &second, .length = second.len, .cycles = 1 };
    var out: [6]i16 = @splat(0);
    const done = fill(&list, &out, .left_first, null);
    // Half way between the first write's last sample and the next one's
    // first, then the next one's second.
    try testing.expectEqual(@as(i16, 1 * 256), out[0]);
    try testing.expectEqual(@as(i16, 640), out[2]);
    try testing.expectEqual(@as(i16, 4 * 256), out[4]);
    try testing.expectEqual(@as(u16, 1), done.ended[0]);
    try testing.expectEqual(@as(u32, 0), done.finished);

    // The same for a write played round and round.
    const loop = [_]i8{ 7, 8 };
    list[0] = .{ .data = &loop, .length = loop.len, .step = one + one / 2, .volume = 64, .endless = 1 };
    _ = fill(&list, &out, .left_first, null);
    try testing.expectEqual(@as(i16, 7 * 256), out[0]);
    try testing.expectEqual(@as(i16, 1920), out[2]);
    try testing.expectEqual(@as(i16, 8 * 256), out[4]);
}

test "between two samples the line between them plays" {
    const ramp = [_]i8{ 0, 100 };
    var list: [channels]Channel = @splat(.{});
    list[0] = .{ .data = &ramp, .length = ramp.len, .step = one / 4, .volume = 64, .cycles = 1 };
    var out: [12]i16 = @splat(0);
    _ = fill(&list, &out, .left_first, null);
    // A quarter of a sample a frame: 0, 25, 50, 75, then the second
    // sample, and on towards the silence after it.
    const heard = [_]i16{ 0, 25, 50, 75, 100, 75 };
    for (heard, 0..) |sample, frame| {
        try testing.expectEqual(sample * 256, out[frame * 2]);
    }
}

var long_write: [70_000]i8 = @splat(0);

test "a write longer than 65536 samples plays to its end" {
    long_write[long_write.len - 1] = 99;
    var list: [channels]Channel = @splat(.{});
    list[0] = .{ .data = &long_write, .length = long_write.len, .step = one, .volume = 64, .cycles = 1 };
    var out: [2000]i16 = @splat(0);
    for (0..long_write.len / 1000) |_| {
        const done = fill(&list, &out, .left_first, null);
        try testing.expectEqual(@as(u16, 0), done.ended[0]);
    }
    try testing.expectEqual(@as(i16, 99 * 256), out[out.len - 2]);
    const done = fill(&list, &out, .left_first, null);
    try testing.expectEqual(@as(u16, 1), done.ended[0]);
}

test "a stopped channel is silent and keeps its place" {
    const ramp = [_]i8{ 10, 20, 30 };
    var list: [channels]Channel = @splat(.{});
    list[0] = .{ .data = &ramp, .length = ramp.len, .step = one, .volume = 64, .cycles = 1 };
    var out: [2]i16 = @splat(0);
    _ = fill(&list, &out, .left_first, null);
    try testing.expectEqual(@as(i16, 10 * 256), out[0]);
    list[0].stopped = 1;
    _ = fill(&list, &out, .left_first, null);
    try testing.expectEqual(@as(i16, 0), out[0]);
    list[0].stopped = 0;
    _ = fill(&list, &out, .left_first, null);
    try testing.expectEqual(@as(i16, 20 * 256), out[0]);
}

test "a mono output hears both sides in each half of the frame" {
    const left_note = [_]i8{100};
    const right_note = [_]i8{-50};
    var list: [channels]Channel = @splat(.{});
    list[0] = .{ .data = &left_note, .length = 1, .step = 0, .volume = 64, .endless = 1 };
    list[1] = .{ .data = &right_note, .length = 1, .step = 0, .volume = 64, .endless = 1 };
    var out: [4]i16 = @splat(0);
    _ = fill(&list, &out, .mono, null);
    for (out) |sample| try testing.expectEqual(@as(i16, 25 * 256), sample);

    // The same sound on a left and a right channel keeps its level.
    list[1] = list[0];
    _ = fill(&list, &out, .mono, null);
    for (out) |sample| try testing.expectEqual(@as(i16, 100 * 256), sample);
}

/// Short writes one after another, handed over as each is taken.
const Feed = struct {
    blocks: []const []const i8,
    given: usize = 0,

    fn next(context: *anyopaque, _: usize) ?Queued {
        const feed: *Feed = @ptrCast(@alignCast(context));
        if (feed.given == feed.blocks.len) return null;
        const block = feed.blocks[feed.given];
        feed.given += 1;
        return .{ .data = block.ptr, .length = @intCast(block.len), .cycles = 1 };
    }
};

test "a queue of short writes plays without a gap, each asked for as the last is taken" {
    const a = [_]i8{1};
    const b = [_]i8{ 2, 3 };
    const c = [_]i8{4};
    const d = [_]i8{5};
    var feed: Feed = .{ .blocks = &.{ &b, &c, &d } };
    var list: [channels]Channel = @splat(.{});
    list[0] = .{ .data = &a, .length = a.len, .step = one, .volume = 64, .cycles = 1 };
    list[0].queued = Feed.next(&feed, 0).?;
    var out: [14]i16 = @splat(0);
    const done = fill(&list, &out, .left_first, .{ .context = &feed, .next = Feed.next });
    const heard = [_]i16{ 1, 2, 3, 4, 5, 0, 0 };
    for (heard, 0..) |sample, frame| {
        try testing.expectEqual(sample * 256, out[frame * 2]);
    }
    try testing.expectEqual(@as(u16, 4), done.ended[0]);
    try testing.expectEqual(@as(u16, 4), done.cycles[0]);
}

test "cycles are counted, and a period and volume held for the cycle's end take over there" {
    const loop = [_]i8{ 100, 100 };
    var list: [channels]Channel = @splat(.{});
    list[0] = .{ .data = &loop, .length = loop.len, .step = one, .volume = 64, .cycles = 3 };
    list[0].sync_step = one;
    list[0].sync_volume = 32;
    list[0].has_sync = 1;
    var out: [12]i16 = @splat(0);
    const done = fill(&list, &out, .left_first, null);
    // Two frames at the old volume, then half as loud from the second
    // cycle on.
    try testing.expectEqual(@as(i16, 100 * 256), out[0]);
    try testing.expectEqual(@as(i16, 100 * 256), out[2]);
    try testing.expectEqual(@as(i16, 100 * 128), out[4]);
    try testing.expectEqual(@as(i16, 100 * 128), out[10]);
    try testing.expectEqual(@as(u16, 2), done.cycles[0]);
    try testing.expectEqual(@as(u16, 0), done.ended[0]);
}

test "sides the other way round: the right side goes first" {
    const left_note = [_]i8{100};
    const right_note = [_]i8{-50};
    var list: [channels]Channel = @splat(.{});
    list[0] = .{ .data = &left_note, .length = 1, .step = 0, .volume = 64, .endless = 1 };
    list[1] = .{ .data = &right_note, .length = 1, .step = 0, .volume = 64, .endless = 1 };
    var out: [4]i16 = @splat(0);
    _ = fill(&list, &out, .right_first, null);
    for (0..2) |frame| {
        try testing.expectEqual(@as(i16, -50 * 64 * 4), out[frame * 2]);
        try testing.expectEqual(@as(i16, 100 * 64 * 4), out[frame * 2 + 1]);
    }
}
