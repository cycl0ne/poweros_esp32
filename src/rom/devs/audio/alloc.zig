// SPDX-License-Identifier: MPL-2.0
//! Which channels an allocation gets: the choice ADCMD_ALLOCATE makes
//! among the combinations it is offered. Nothing here touches the device,
//! so the host tests hold it.
//!
//! A combination is four bits, one a channel. It can be had when none of
//! its channels is held at the asked precedence or above - an allocation
//! never steals from its equal. Of those that can be had, the one that
//! steals from the lowest precedence wins: first a combination of free
//! channels only, in the order the caller gave them; then one that steals
//! nothing above the lowest precedence held; then the next level up; and
//! so on. The order the caller gave decides among combinations at the
//! same level.

/// The precedence of a channel nobody has: below every precedence a
/// request can have, so a free channel is always the cheapest to take.
pub const free_precedence: i16 = -129;

/// How many channels there are.
const channels = 4;
const all: u8 = (1 << channels) - 1;

/// The combination `wanted` gets of `combinations`, given each channel's
/// precedence (`free_precedence` for a free one), or null when none can
/// be had. A combination of no channels is had at once.
pub fn choose(combinations: []const u8, precedences: [channels]i16, wanted: i8) ?u8 {
    // The levels below the asked precedence, lowest first: each one lets
    // the channels at or below it be taken.
    var level: i16 = free_precedence - 1;
    while (true) {
        const above = lowestAbove(precedences, level, wanted) orelse break;
        level = above;
        var allowed: u8 = 0;
        for (precedences, 0..) |precedence, i| {
            if (precedence <= level) allowed |= @as(u8, 1) << @intCast(i);
        }
        for (combinations) |combination| {
            const mask = combination & all;
            if (mask & ~allowed == 0) return mask;
        }
    }
    // Every channel held at the asked precedence or above: only a
    // combination of no channels can be had.
    for (combinations) |combination| {
        if (combination & all == 0) return 0;
    }
    return null;
}

/// The lowest precedence above `level` and below `wanted` that a channel
/// has, or null.
fn lowestAbove(precedences: [channels]i16, level: i16, wanted: i8) ?i16 {
    var lowest: ?i16 = null;
    for (precedences) |precedence| {
        if (precedence <= level or precedence >= wanted) continue;
        if (lowest == null or precedence < lowest.?) lowest = precedence;
    }
    return lowest;
}

// --- tests --------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;
const nobody = free_precedence;

test "free channels: the first combination asked for" {
    const free = [_]i16{ nobody, nobody, nobody, nobody };
    try testing.expectEqual(@as(?u8, 0x3), choose(&.{ 0x3, 0x5, 0xA, 0xC }, free, 0));
}

test "a combination that steals nothing wins over one asked for before it" {
    const held = [_]i16{ 10, nobody, nobody, nobody };
    try testing.expectEqual(@as(?u8, 0xC), choose(&.{ 0x3, 0xC }, held, 20));
}

test "when something must be stolen, the lowest precedence goes" {
    const held = [_]i16{ 10, 5, 30, 30 };
    try testing.expectEqual(@as(?u8, 0x2), choose(&.{ 0x1, 0x2 }, held, 20));
    try testing.expectEqual(@as(?u8, 0x3), choose(&.{ 0x3, 0x4 }, held, 20));
}

test "an equal or higher precedence is never stolen" {
    const held = [_]i16{ 20, 40, nobody, nobody };
    try testing.expectEqual(@as(?u8, null), choose(&.{ 0x1, 0x2, 0x3 }, held, 20));
    try testing.expectEqual(@as(?u8, 0x4), choose(&.{ 0x1, 0x4 }, held, 20));
}

test "no channels at all is had at once, and nothing else when all is held" {
    const held = [_]i16{ 127, 127, 127, 127 };
    try testing.expectEqual(@as(?u8, 0), choose(&.{ 0x1, 0x0 }, held, 0));
    try testing.expectEqual(@as(?u8, null), choose(&.{0x1}, held, 0));
    try testing.expectEqual(@as(?u8, null), choose(&.{}, held, 0));
}
