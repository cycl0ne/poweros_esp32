// SPDX-License-Identifier: MPL-2.0
//! BestBoardMode: The board's mode nearest a wish.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const _mode = @import("_mode.zig");

/// Finds the mode of a board that comes nearest a wish.
///
/// SYNOPSIS:
/// ```zig
/// fn BestBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, refresh_mhz: u32, format: u32, mode: ?*rtg.RtgMode) u32
/// ```
///
/// SINCE: 1.19. LVO -224.
///
/// INPUTS:
/// - `board` - the board.
/// - `width` - the width wished for, or `RTG_ANY`.
/// - `height` - the height wished for, or `RTG_ANY`.
/// - `refresh_mhz` - the refresh wished for, in milli-Hertz, or `RTG_ANY`.
/// - `format` - the pixel format wished for, as a number, or `RTG_ANY`.
/// - `mode` - where the mode found is copied to, or null.
///
/// RESULT:
/// The number of the mode, and what it is in `mode`. 0, and `mode` left
/// as it was, only on a board that has no mode.
///
/// BEHAVIOR:
/// A format wished for is looked for among the board's modes of that
/// format, where it has any; else among all of them. Then the size
/// decides: a mode of the size wished for where there is one, else the
/// smallest that holds it, else the largest. Of several modes of one size
/// the refresh nearest the one wished for is taken - with the refresh left
/// open the board's default where it is of that size, else the highest. A
/// wish that leaves both sides of the size open is for the size of the
/// board's default mode.
///
/// So a display of one mode always answers that mode: whoever asks for
/// another size is handed the board's, and sees which it got by comparing
/// `mode` with what it asked for.
///
/// CONTEXT:
/// - Waits: while another task holds the board's lock.
/// - Interrupts: no.
/// - Locks: takes the board's lock. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated: the copy is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindBoardMode`, `GetBoardModes`, `ShowBoard`
///
/// EXAMPLES:
/// ```zig
/// var got: rtg.RtgMode = .{};
/// const mode_id = rb.BestBoardMode(board, 800, 600, rtg.RTG_ANY, rtg.RTG_ANY, &got);
/// if (got.width != 800 or got.height != 600) tellOf(&got);
/// ```
pub fn BestBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32, refresh_mhz: u32, format: u32, mode: ?*rtg.RtgMode) u32 {
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    const record = _mode.best(board, width, height, refresh_mhz, format) orelse return 0;
    if (mode) |into| into.* = record.mode;
    return record.mode.id;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "the nearest mode to a wish: on a board of one mode always that mode" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    fk.modes = 1;
    const board = try fixture.makeBoard(rb);
    const any = rtg.RTG_ANY;

    var got: rtg.RtgMode = .{};
    // Whoever asks for another size gets the board's, and sees which.
    try testing.expectEqual(@as(u32, 1), fixture.base(rb).BestBoardMode(board, 640, 800, any, any, &got));
    try testing.expectEqual(@as(u32, 320), got.width);
    try testing.expectEqual(@as(u32, 200), got.height);
    try testing.expectEqual(@as(u32, 1), fixture.base(rb).BestBoardMode(board, 16, 16, 75_000, @intFromEnum(rtg.PixelFormat.bgra32), null));
    try testing.expectEqual(@as(u32, 1), fixture.base(rb).BestBoardMode(board, any, any, any, any, null));
    // The exact one is still asked for exactly.
    try testing.expectEqual(@as(u32, 0), fixture.base(rb).FindBoardMode(board, 640, 800, any, any));

    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}

test "the nearest mode to a wish: by format, then size, then refresh; none on a board with no mode" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const any = rtg.RTG_ANY;
    const rgb565 = @intFromEnum(rtg.PixelFormat.rgb565);
    const mono1 = @intFromEnum(rtg.PixelFormat.mono1);

    // A board with no mode answers 0 and leaves the copy alone.
    fk.modes = 0;
    const bare = try fixture.makeBoard(rb);
    var got: rtg.RtgMode = .{ .id = 77 };
    try testing.expectEqual(@as(u32, 0), fixture.base(rb).BestBoardMode(bare, 320, 200, any, any, &got));
    try testing.expectEqual(@as(u32, 77), got.id);
    try testing.expectEqual(rtg.errors.RTGERR_BAD_MODE, fixture.setMode(rb, bare, 0));
    fixture.driverBase(rb).DeleteBoard(bare);

    fk.modes = fixture.fake.mode_table.len;
    const board = try fixture.makeBoard(rb);
    // The size itself.
    try testing.expectEqual(@as(u32, 1), fixture.base(rb).BestBoardMode(board, 320, 200, any, any, &got));
    try testing.expectEqual(@as(u32, 320), got.width);
    // Else the smallest that holds it.
    try testing.expectEqual(@as(u32, 2), fixture.base(rb).BestBoardMode(board, 400, 300, any, any, null));
    try testing.expectEqual(@as(u32, 1), fixture.base(rb).BestBoardMode(board, 100, 100, any, any, null));
    try testing.expectEqual(@as(u32, 3), fixture.base(rb).BestBoardMode(board, 32, 32, any, any, null));
    // Else the largest.
    try testing.expectEqual(@as(u32, 2), fixture.base(rb).BestBoardMode(board, 800, 600, any, any, &got));
    try testing.expectEqual(@as(u32, 640), got.width);
    // One side left open holds whatever it is.
    try testing.expectEqual(@as(u32, 2), fixture.base(rb).BestBoardMode(board, any, 480, any, any, null));
    // A format wished for is looked for among the modes of that format.
    try testing.expectEqual(@as(u32, 1), fixture.base(rb).BestBoardMode(board, 32, 32, any, rgb565, null));
    try testing.expectEqual(@as(u32, 3), fixture.base(rb).BestBoardMode(board, 640, 480, any, mono1, null));
    // One the board has none of leaves the size to decide.
    try testing.expectEqual(@as(u32, 2), fixture.base(rb).BestBoardMode(board, 640, 480, any, @intFromEnum(rtg.PixelFormat.bgra32), null));
    // Nothing wished for is the default.
    try testing.expectEqual(@as(u32, 1), fixture.base(rb).BestBoardMode(board, any, any, any, any, null));

    // The size at a second refresh: 840 by 500 at 31.5 MHz is 75 a second.
    const faster: rtg.RtgTimings = .{ .pixel_clock_hz = 31_500_000, .h_active = 640, .h_front = 16, .h_sync = 64, .h_back = 120, .v_active = 480, .v_front = 1, .v_sync = 3, .v_back = 16 };
    try testing.expectEqual(@as(u32, 4), fixture.driverBase(rb).AddBoardMode(board, &faster, rgb565, 0));
    try testing.expectEqual(@as(u32, 4), fixture.base(rb).BestBoardMode(board, 640, 480, 75_000, any, null));
    try testing.expectEqual(@as(u32, 2), fixture.base(rb).BestBoardMode(board, 640, 480, 61_000, any, null));
    try testing.expectEqual(@as(u32, 4), fixture.base(rb).BestBoardMode(board, 640, 480, 70_000, any, null));
    // The refresh left open: the higher, unless the default is of that
    // size.
    try testing.expectEqual(@as(u32, 4), fixture.base(rb).BestBoardMode(board, 640, 480, any, any, null));
    try testing.expectEqual(@as(u32, 1), fixture.base(rb).BestBoardMode(board, 320, 200, any, any, null));

    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}
