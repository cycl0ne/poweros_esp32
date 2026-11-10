// SPDX-License-Identifier: MIT
//! Host tests of the Movie's subtitles: their text kept in UTF-8, cut
//! where a character starts.

const std = @import("std");
const subtitles = @import("../subtitles.zig");

const testing = std.testing;

test "the text kept in UTF-8, cut where a character starts, the NUL kept" {
    var into: [64]u8 = undefined;
    const made = subtitles.textOf("„Grüß dich“ – sagte er… ♪", &into);
    try testing.expectEqualStrings("„Grüß dich“ – sagte er… ♪", into[0..made]);
    try testing.expectEqual(@as(u8, 0), into[made]);
    var small: [6]u8 = undefined;
    const cut = subtitles.textOf("Grüße!", &small);
    try testing.expectEqualStrings("Grü", small[0..cut]);
    try testing.expectEqual(@as(u8, 0), small[cut]);
}
