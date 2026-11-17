// SPDX-License-Identifier: MPL-2.0
//! FindBoardMode: The number of the board's mode of exactly that size,
//! refresh and format.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const _mode = @import("_mode.zig");

/// Finds a board's mode by its size, refresh and format.
///
/// SYNOPSIS:
/// ```zig
/// fn FindBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, refresh_mhz: u32, format: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `board` - the board.
/// - `width` - the width wanted, or `RTG_ANY`.
/// - `height` - the height wanted, or `RTG_ANY`.
/// - `refresh_mhz` - the refresh wanted, in milli-Hertz as the mode says
///   it, or `RTG_ANY`.
/// - `format` - the pixel format wanted, as a number, or `RTG_ANY`.
///
/// RESULT:
/// The number of a mode that is exactly that, or 0. Where several are,
/// the board's default if it is one of them, else the first of the list.
///
/// BEHAVIOR:
/// Each `RTG_ANY` matches whatever the mode has, so a caller can ask for
/// any mode 1024 wide, and all four `RTG_ANY` is the board's default
/// mode. A mode that is only near what was asked is not answered:
/// `BestBoardMode` does that.
///
/// CONTEXT:
/// - Waits: while another task holds the board's lock.
/// - Interrupts: no.
/// - Locks: takes the board's lock. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BestBoardMode`, `GetBoardModes`, `ShowBoard`
///
/// EXAMPLES:
/// ```zig
/// const mode_id = rb.FindBoardMode(board, 1024, 600, rtg.RTG_ANY, rtg.RTG_ANY);
/// if (mode_id == 0) return error.NoMode;
/// ```
pub fn FindBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, refresh_mhz: u32, format: u32) u32 {
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    const record = _mode.find(board, width, height, refresh_mhz, format) orelse return 0;
    return record.mode.id;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "a mode: found by its figures, set by its number, and the board says what it is in" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeBoard(rb);
    const any = rtg.RTG_ANY;
    const rgb565 = @intFromEnum(rtg.PixelFormat.rgb565);

    // Nothing asked for is the board's default.
    try testing.expectEqual(@as(u32, 1), fixture.base(rb).FindBoardMode(board, any, any, any, any));
    try testing.expectEqual(@as(u32, 2), fixture.base(rb).FindBoardMode(board, 640, any, any, any));
    try testing.expectEqual(@as(u32, 2), fixture.base(rb).FindBoardMode(board, 640, 480, 60_000, rgb565));
    // Only what is exactly that: a size it has not, a refresh it has not,
    // and a format the mode of that size is not in. Format 0 is a format.
    try testing.expectEqual(@as(u32, 0), fixture.base(rb).FindBoardMode(board, 800, 600, any, any));
    try testing.expectEqual(@as(u32, 0), fixture.base(rb).FindBoardMode(board, 640, 480, 75_000, any));
    try testing.expectEqual(@as(u32, 0), fixture.base(rb).FindBoardMode(board, 640, 480, any, @intFromEnum(rtg.PixelFormat.rgba32)));
    try testing.expectEqual(@as(u32, 3), fixture.base(rb).FindBoardMode(board, any, any, 0, any));

    var before: rtg.RtgBoardInfo = .{};
    _ = fixture.base(rb).GetBoardInfo(board, &before, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u32, 0), before.flags & rtg.boards.RTGBF_MODE_SET);
    try testing.expectEqual(@as(u32, 0), before.mode_id);

    // A number the board has no mode of is refused, and the driver not
    // asked.
    try testing.expectEqual(rtg.errors.RTGERR_BAD_MODE, fixture.setMode(rb, board, 9));
    try testing.expectEqual(@as(u32, 0), fk.log.set_mode);

    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.setMode(rb, board, 2));
    // The driver was handed the mode and its timings.
    try testing.expectEqual(@as(u32, 2), fk.log.last_mode.id);
    try testing.expectEqual(@as(u32, 640), fk.log.last_timings.h_active);
    try testing.expectEqual(@as(u32, 96), fk.log.last_timings.h_sync);
    try testing.expectEqual(@as(u32, 25_200_000), fk.log.last_timings.pixel_clock_hz);

    var info: rtg.RtgBoardInfo = .{};
    _ = fixture.base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u32, 640), info.width);
    try testing.expectEqual(@as(u32, 480), info.height);
    try testing.expectEqual(@as(u32, 1280), info.pitch);
    try testing.expectEqual(@as(u32, 2), info.mode_id);
    try testing.expectEqual(@as(u32, 60_000), info.refresh_mhz);
    try testing.expectEqual(@as(u32, 25_200_000), info.pixel_clock_hz);
    try testing.expect(info.flags & rtg.boards.RTGBF_MODE_SET != 0);

    // The copies say which mode the board is in; 0 is the default.
    var found: [8]rtg.RtgMode = undefined;
    _ = fixture.modesOf(rb, board, &found);
    try testing.expect(found[0].flags & rtg.modes.RTGMF_CURRENT != 0);
    try testing.expect(found[1].flags & rtg.modes.RTGMF_CURRENT == 0);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.setMode(rb, board, 0));
    _ = fixture.modesOf(rb, board, &found);
    try testing.expect(found[0].flags & rtg.modes.RTGMF_CURRENT == 0);
    try testing.expectEqual(rtg.modes.RTGMF_DEFAULT | rtg.modes.RTGMF_CURRENT, found[1].flags);
    // A mode with no clock leaves the board saying none.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.setMode(rb, board, 3));
    _ = fixture.base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u32, 0), info.refresh_mhz);
    try testing.expectEqual(@as(u32, 0), info.pixel_clock_hz);

    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}
