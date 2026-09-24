// SPDX-License-Identifier: MPL-2.0
//! Four channels of 8-bit samples into one stereo stream, which is what
//! this machine's codec takes. Nothing here touches hardware, so the host
//! tests hold all of it.
//!
//! A channel plays its samples at a rate of its own: one sample every
//! `period` ticks of the audio clock. The output runs at a rate of its
//! own too, and the two have nothing to do with each other, so a channel
//! keeps a position in its samples and a step to add to it per output
//! frame - both in sixteenths of sixteenths, because a step is rarely a
//! whole sample. The sample under the position is the one that plays,
//! which is what a chip that fetched a sample per period would have made
//! of the same numbers.
//!
//! The channels are summed as the hardware they are named for wired them:
//! 0 and 3 to the left, 1 and 2 to the right. A sum past what a 16-bit
//! sample holds is clipped rather than wrapped - wrapping turns a loud
//! note into a shriek.

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

/// One channel: what it is playing, where it has got to and how loud.
pub const Channel = extern struct {
    /// The samples, and how many. Null is a channel playing nothing.
    data: ?[*]const i8 = null,
    length: u32 = 0,
    /// Where in the samples, and how far a frame moves it.
    position: u32 = 0,
    step: u32 = 0,
    /// 0 to 64, as the hardware counted loudness.
    volume: u16 = 0,
    pad: u16 = 0,
    /// Times still to play; 0 while it plays for ever.
    cycles: u16 = 0,
    /// Whether `cycles` is counted at all.
    endless: u16 = 0,

    /// Whether this channel has samples to play.
    pub fn playing(c: *const Channel) bool {
        return c.data != null and c.length != 0;
    }
};

/// What a fill did to a channel.
pub const Done = struct {
    /// The channels that reached the end of their samples in this fill,
    /// one bit each.
    finished: u32 = 0,
};

/// The step for a channel whose sample rate is `clock / period`, in an
/// output running at `rate`. A period of 0 is nothing to play.
pub fn stepFor(clock: u32, period: u16, rate: u32) u32 {
    if (period == 0 or rate == 0) return 0;
    const samples_per_second = clock / period;
    return @intCast(@as(u64, samples_per_second) * one / rate);
}

/// `frames` stereo frames into `out`, taken from whichever channels are
/// playing. `out` holds two samples a frame, left first. Answers which
/// channels ended.
pub fn fill(list: *[channels]Channel, out: []i16) Done {
    var done: Done = .{};
    const frames = out.len / 2;
    for (0..frames) |frame| {
        var left: i32 = 0;
        var right: i32 = 0;
        for (list, 0..) |*c, i| {
            if (!c.playing()) continue;
            const at = c.position >> shift;
            if (at >= c.length) {
                if (!wrap(c)) {
                    done.finished |= @as(u32, 1) << @intCast(i);
                    continue;
                }
            }
            const sample: i32 = c.data.?[c.position >> shift];
            // A sample is -128 to 127 and a volume 0 to 64; four times
            // that fills a 16-bit sample, and two channels a side fit
            // because the clip below catches the pair that does not.
            const value = sample * @as(i32, @intCast(c.volume)) * 4;
            if (leftOf(i)) left += value else right += value;
            c.position +%= c.step;
        }
        out[frame * 2] = clip(left);
        out[frame * 2 + 1] = clip(right);
    }
    return done;
}

/// A channel that has run out of samples: back to the start for another
/// cycle, or false when it has none left.
fn wrap(c: *Channel) bool {
    if (c.endless == 0) {
        if (c.cycles <= 1) {
            c.cycles = 0;
            c.data = null;
            return false;
        }
        c.cycles -= 1;
    }
    c.position = 0;
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
    const done = fill(&list, &out);
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
    _ = fill(&list, &twice);
    try testing.expectEqual(@as(i16, 100 * 64 * 4), twice[0]);
    try testing.expectEqual(@as(i16, 100 * 64 * 4), twice[4]);

    // Endless: still playing after the samples ran out.
    list[0] = .{ .data = &samples, .length = samples.len, .step = one, .volume = 64, .endless = 1 };
    var forever: [16]i16 = @splat(0);
    const none = fill(&list, &forever);
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
    _ = fill(&list, &out);
    try testing.expectEqual(@as(i16, 0), out[0]);
    try testing.expectEqual(std.math.maxInt(i16), out[1]);

    // Half the volume is half the sample.
    list[2] = .{};
    list[1].volume = 32;
    _ = fill(&list, &out);
    try testing.expectEqual(@as(i16, 127 * 32 * 4), out[1]);

    // A silent channel is silent.
    list[1].volume = 0;
    _ = fill(&list, &out);
    try testing.expectEqual(@as(i16, 0), out[1]);
}
