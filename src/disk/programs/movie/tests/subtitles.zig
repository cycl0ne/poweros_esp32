// SPDX-License-Identifier: MIT
//! Host tests of the Movie's subtitles: their text made Latin-1 by the
//! ROM's utility.library.

const std = @import("std");
const sdk = @import("sdk");
const host = @import("host_rom");
const subtitles = @import("../subtitles.zig");
const UtilityBase = sdk.interface.utility.UtilityBase;

const testing = std.testing;

test "UTF-8 made Latin-1: umlauts kept, typesetting's quotes, dashes and dots plain, the rest a ?" {
    const rom_ub = try host.utility.setUp();
    defer host.exec.deinit();
    const ub: *UtilityBase = @ptrCast(rom_ub);
    var into: [64]u8 = undefined;
    const made = subtitles.latin1(ub, "„Grüß dich“ – sagte er… ♪", &into);
    try testing.expectEqualStrings("\"Gr\xfc\xdf dich\" - sagte er... ?", into[0..made]);
    try testing.expectEqual(@as(u8, 0), into[made]);
    // Cut to the buffer, the NUL kept.
    var small: [6]u8 = undefined;
    const cut = subtitles.latin1(ub, "Grüße!", &small);
    try testing.expectEqualStrings("Gr\xfc\xdfe", small[0..cut]);
    try testing.expectEqual(@as(u8, 0), small[cut]);
    try host.utility.tearDown(rom_ub);
}
