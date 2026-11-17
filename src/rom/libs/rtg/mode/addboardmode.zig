// SPDX-License-Identifier: MPL-2.0
//! AddBoardMode: A mode of a board, from its driver.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const _mode = @import("_mode.zig");

/// Adds a mode to a board's list.
///
/// SYNOPSIS:
/// ```zig
/// fn AddBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, timings: *const rtg.RtgTimings, format: u32, flags: u32) u32
/// ```
///
/// SINCE: 1.19. LVO -300.
///
/// INPUTS:
/// - `board` - the board, one of the caller's own.
/// - `timings` - the mode's timings: its picture's size, and where the
///   display has a clock, the clock and the blanking. Copied.
/// - `format` - the pixel format the board shows the mode in, as a number.
/// - `flags` - `RTGMF_DEFAULT` for the mode the board comes up in,
///   `RTGMF_TURNED` for a picture that lies on the panel a quarter turn
///   round.
///
/// RESULT:
/// The mode's number, from 1; 0 for timings whose picture is empty, for a
/// format this build does not know, and without memory.
///
/// BEHAVIOR:
/// The library makes the mode: its name is its size ("1024x600") - with
/// the refresh behind it where the board has that size at more than one -
/// its refresh is what the timings come to, 0 where they have no clock,
/// and its number is the next the board has not used. The list is kept
/// with the larger picture first. The first mode added is the board's
/// default until one is added with `RTGMF_DEFAULT`. A mode added again -
/// the same size, format, refresh and turn - is the one that is there: it
/// takes the timings handed over and keeps its number.
///
/// On a board with a connector (`detect`) the modes are what the monitor
/// names, made by the library; the ones added with this call are the
/// board's own, which stand while no monitor is there or the one there
/// names none the board can make.
///
/// A row of a buffer of the mode is as long as `AllocBitMap` makes one:
/// the width in the format, rounded up to what the board's display memory
/// is aligned to. It is set once the board has joined the list, so a
/// driver that needs the figure in its `attach` works it out from its own
/// region.
///
/// CONTEXT:
/// - Waits: while another task holds the board's lock.
/// - Interrupts: no.
/// - Locks: takes the board's lock. No spinlock may be held.
/// - Process: a Task will do. A driver calls it in its `attach`.
///
/// OWNERSHIP:
/// The mode is the library's and goes with the board. Nothing is kept of
/// `timings`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadTimingTags`, `GetBoardModes`, `CreateBoard`
///
/// EXAMPLES:
/// ```zig
/// var timings: rtg.RtgTimings = .{};
/// if (!rb.ReadTimingTags(tag_list, &timings)) return rtg.errors.RTGERR_BAD_TAGS;
/// _ = rb.AddBoardMode(board, &timings, @intFromEnum(rtg.PixelFormat.rgb565), rtg.modes.RTGMF_DEFAULT);
/// ```
pub fn AddBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, timings: *const rtg.RtgTimings, format: u32, flags: u32) u32 {
    if (timings.h_active == 0 or timings.v_active == 0) return 0;
    if (rb.iface().RtgFormatBits(format) == 0) return 0;
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    const record = _mode.add(rb, board, timings, format, flags, .driver) orelse return 0;
    // On a board whose monitor names modes, the driver's own stand by:
    // they are offered while it names none.
    if (boards.privateOf(board).monitor) |state| {
        if (state.names_modes) _mode.withdraw(rb, board, .driver);
    }
    return record.mode.id;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const std = fixture.std;
const testing = fixture.testing;

test "a mode added: its name with the refresh where a size has two, the default moved, the same figures the same mode" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const board = try fixture.makeBoard(rb);
    const rgb565 = @intFromEnum(rtg.PixelFormat.rgb565);
    var found: [8]rtg.RtgMode = undefined;

    const faster: rtg.RtgTimings = .{ .pixel_clock_hz = 31_500_000, .h_active = 640, .h_front = 16, .h_sync = 64, .h_back = 120, .v_active = 480, .v_front = 1, .v_sync = 3, .v_back = 16 };
    try testing.expectEqual(@as(u32, 4), fixture.driverBase(rb).AddBoardMode(board, &faster, rgb565, rtg.modes.RTGMF_DEFAULT));
    try testing.expectEqual(@as(u32, 4), fixture.modesOf(rb, board, &found));
    // Of one size the higher refresh first, and both say which they are.
    try testing.expectEqual(@as(u32, 4), found[0].id);
    try testing.expectEqualStrings("640x480@75", std.mem.sliceTo(&found[0].name, 0));
    try testing.expectEqualStrings("640x480@60", std.mem.sliceTo(&found[1].name, 0));
    try testing.expectEqualStrings("320x200", std.mem.sliceTo(&found[2].name, 0));
    // The default is the one added as it, and no other.
    try testing.expectEqual(rtg.modes.RTGMF_DEFAULT, found[0].flags);
    try testing.expectEqual(@as(u32, 0), found[2].flags);
    try testing.expectEqual(@as(u32, 4), fixture.base(rb).FindBoardMode(board, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY));
    // A row was set as it was added: the board has its display memory.
    try testing.expectEqual(@as(u32, 1280), found[0].pitch);

    // The same figures again are the mode that is there, with the timings
    // handed over now.
    var again = faster;
    again.h_front = 24;
    again.h_back = 112;
    try testing.expectEqual(@as(u32, 4), fixture.driverBase(rb).AddBoardMode(board, &again, rgb565, 0));
    try testing.expectEqual(@as(u32, 4), fixture.base(rb).GetBoardModes(board, null, 0));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.setMode(rb, board, 4));
    try testing.expectEqual(@as(u32, 24), fixture.fakeOf(rb).log.last_timings.h_front);
    // It stays the default: a mode is not made less by being added again.
    try testing.expectEqual(@as(u32, 4), fixture.base(rb).FindBoardMode(board, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY));

    // A picture a quarter turn round is a mode of its own, and says so;
    // an interlaced one is named for it.
    const turned: rtg.RtgTimings = .{ .h_active = 64, .v_active = 64 };
    try testing.expectEqual(@as(u32, 5), fixture.driverBase(rb).AddBoardMode(board, &turned, @intFromEnum(rtg.PixelFormat.mono1), rtg.modes.RTGMF_TURNED));
    var fields = faster;
    fields.h_active = 720;
    fields.flags = rtg.modes.RTGTM_INTERLACED;
    try testing.expectEqual(@as(u32, 6), fixture.driverBase(rb).AddBoardMode(board, &fields, rgb565, 0));
    try testing.expectEqual(@as(u32, 6), fixture.modesOf(rb, board, &found));
    try testing.expectEqualStrings("720x480i", std.mem.sliceTo(&found[0].name, 0));
    try testing.expect(found[0].flags & rtg.modes.RTGMF_INTERLACED != 0);
    try testing.expect(found[5].flags & rtg.modes.RTGMF_TURNED != 0);

    // What is no mode: an empty picture, and a format that is none.
    const empty: rtg.RtgTimings = .{ .h_active = 640 };
    try testing.expectEqual(@as(u32, 0), fixture.driverBase(rb).AddBoardMode(board, &empty, rgb565, 0));
    try testing.expectEqual(@as(u32, 0), fixture.driverBase(rb).AddBoardMode(board, &faster, 200, 0));
    try testing.expectEqual(@as(u32, 0), fixture.driverBase(rb).AddBoardMode(board, &faster, 0x1_0004, 0));
    try testing.expectEqual(@as(u32, 6), fixture.base(rb).GetBoardModes(board, null, 0));

    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}
