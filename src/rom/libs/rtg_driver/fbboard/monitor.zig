// SPDX-License-Identifier: MPL-2.0
//! What a monitor on the JH7110's HDMI port takes, and which picture it
//! gets.
//!
//! The port sends a mode whose pixel clock the transmitter's PLL makes
//! (`phy.zig`): CEA's and VESA's clocks and most others a monitor names,
//! up to 297 MHz - 3840x2160 at 30 Hz, not at 60. So the modes the
//! monitor names are taken as it names them (`edid.zig`): a detailed
//! timing as it is, a size or a number with the standard's timing.
//!
//! The picture shown first is the one the monitor prefers, its first
//! detailed timing, where the port can send it; else 1920x1080 at 60 Hz
//! where the monitor takes that, which a 3840x2160 monitor shows sharp,
//! four of its pixels to one; else the largest it names. Without an EDID
//! there is one mode, the board's own.

const edid = @import("../edid.zig");

/// The most modes a board lists.
pub const max_modes = 16;

/// The modes, largest first, and which is shown first.
pub const List = struct {
    modes: [max_modes]edid.Timing = undefined,
    count: u32 = 0,
    default: u32 = 0,

    fn holds(list: *const List, timing: *const edid.Timing) bool {
        for (list.modes[0..list.count]) |*mode| {
            if (mode.sameAs(timing)) return true;
        }
        return false;
    }

    /// `timing` added unless a mode of its picture and refresh is there
    /// already, or the list is full.
    fn add(list: *List, timing: edid.Timing) void {
        if (list.count == max_modes or list.holds(&timing)) return;
        list.modes[list.count] = timing;
        list.count += 1;
    }

    fn indexOf(list: *const List, timing: *const edid.Timing) ?u32 {
        for (list.modes[0..list.count], 0..) |*mode, i| {
            if (mode.sameAs(timing)) return @intCast(i);
        }
        return null;
    }
};

/// Larger picture first; of one size, the higher refresh.
fn before(a: *const edid.Timing, b: *const edid.Timing) bool {
    const area_a = a.width * a.height;
    const area_b = b.width * b.height;
    if (area_a != area_b) return area_a > area_b;
    return a.milliHz() > b.milliHz();
}

/// The modes the monitor whose EDID is `first` (and `extension`, when it
/// has one) takes that a port sending the pixel clocks `sends` can send,
/// and the monitor takes - up to the fastest clock its extension says
/// (`edid.Sink.mostKhz`); `own` alone when there is no EDID, or nothing
/// in it can be sent.
pub fn modesOf(first: ?*const edid.Block, extension: ?*const edid.Block, own: edid.Timing, sends: *const fn (u32) bool) List {
    var found: List = .{};
    var preferred: ?edid.Timing = null;
    if (first) |base| {
        const most_khz = edid.sinkOf(extension).mostKhz();
        var timings: [10]edid.Timing = undefined;
        const count = edid.detailedTimings(base, extension, &timings);
        for (timings[0..count], 0..) |timing, i| {
            if (!sends(timing.pixel_khz) or timing.pixel_khz > most_khz) continue;
            var named = timing;
            named.vic = edid.vicOf(&timing);
            if (i == 0 and edid.detailed(base, 54) != null) preferred = named;
            found.add(named);
        }
        for (&edid.known) |*mode| {
            if (!sends(mode.pixel_khz) or mode.pixel_khz > most_khz) continue;
            if (edid.takes(base, extension, .{ .width = mode.width, .height = mode.height, .refresh_hz = mode.hz(), .vic = mode.vic })) found.add(mode.*);
        }
    }
    if (found.count == 0) {
        found.add(own);
        return found;
    }

    // Largest first, as the board lists them: an insertion sort, which
    // keeps a detailed timing ahead of a standard mode of its size.
    var i: u32 = 1;
    while (i < found.count) : (i += 1) {
        const moving = found.modes[i];
        var j = i;
        while (j > 0 and before(&moving, &found.modes[j - 1])) : (j -= 1) found.modes[j] = found.modes[j - 1];
        found.modes[j] = moving;
    }

    const full_hd = edid.knownMode(1920, 1080, 60).?;
    found.default = if (preferred) |mode| found.indexOf(&mode).? else found.indexOf(&full_hd) orelse 0;
    return found;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;
const phy = @import("phy.zig");

const board_own = edid.knownMode(1920, 1080, 60).?;

test "the portable monitor: its own 1080p first, then what it names that the port sends" {
    const found = modesOf(&edid.portable_1080p[0], &edid.portable_1080p[1], board_own, phy.sends);
    const expected = [_][3]u32{
        .{ 1920, 1080, 60 }, .{ 1280, 1024, 60 }, .{ 1440, 900, 60 }, .{ 1280, 960, 60 },
        .{ 1280, 720, 60 },  .{ 1024, 768, 60 },  .{ 800, 600, 60 },  .{ 720, 480, 60 },
        .{ 640, 480, 60 },
    };
    try testing.expectEqual(@as(u32, expected.len), found.count);
    for (expected, found.modes[0..found.count]) |want, *got| {
        try testing.expectEqual(want[0], got.width);
        try testing.expectEqual(want[1], got.height);
        try testing.expectEqual(want[2], got.hz());
    }
    // The monitor's detailed timing, its sync a line early, with CEA's
    // number; 1400x1050 is not sent at DMT's 121.75 MHz.
    try testing.expectEqual(@as(u32, 0), found.default);
    try testing.expectEqual(@as(u32, 3), found.modes[0].v_front);
    try testing.expectEqual(@as(u8, 16), found.modes[0].vic);
    try testing.expectEqual(@as(u8, 3), found.modes[7].vic);
}

test "no EDID, the board's own mode alone" {
    const found = modesOf(null, null, board_own, phy.sends);
    try testing.expectEqual(@as(u32, 1), found.count);
    try testing.expectEqual(@as(u32, 0), found.default);
    try testing.expectEqual(@as(u32, 148_500), found.modes[0].pixel_khz);
}

test "a monitor that prefers what the port cannot send gets 1080p60" {
    // A 3840x2160 monitor: 4K60 preferred at 594 MHz, VICs 95 and 16.
    var first: edid.Block = @splat(0);
    for (38..54) |i| first[i] = 0x01;
    const uhd60 = [18]u8{ 0x08, 0xE8, 0x00, 0x30, 0xF2, 0x70, 0x5A, 0x80, 0xB0, 0x58, 0x8A, 0x00, 0x50, 0x1D, 0x74, 0x00, 0x00, 0x1E };
    @memcpy(first[54..72], &uhd60);
    var cea: edid.Block = @splat(0);
    cea[0] = 0x02;
    cea[2] = 7;
    cea[4] = 2 << 5 | 2;
    cea[5] = 95;
    cea[6] = 16;
    const found = modesOf(&first, &cea, board_own, phy.sends);
    try testing.expectEqual(@as(u32, 2), found.count);
    try testing.expectEqual(@as(u32, 3840), found.modes[0].width);
    try testing.expectEqual(@as(u32, 30), found.modes[0].hz());
    try testing.expectEqual(@as(u32, 1), found.default);
    try testing.expectEqual(@as(u32, 1080), found.modes[found.default].height);
}

test "a 1440p monitor gets its own mode, from its detailed timing" {
    // 2560x1440 at 60 Hz, reduced blanking: 241.5 MHz, 2720 x 1481.
    var first: edid.Block = @splat(0);
    for (38..54) |i| first[i] = 0x01;
    const qhd = [18]u8{ 0x56, 0x5E, 0x00, 0xA0, 0xA0, 0xA0, 0x29, 0x50, 0x30, 0x20, 0x35, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1A };
    @memcpy(first[54..72], &qhd);
    const found = modesOf(&first, null, board_own, phy.sends);
    try testing.expectEqual(@as(u32, 1), found.count);
    try testing.expectEqual(@as(u32, 2560), found.modes[0].width);
    try testing.expectEqual(@as(u32, 60), found.modes[0].hz());
    try testing.expect(found.modes[0].hsync_high and !found.modes[0].vsync_high);
}
