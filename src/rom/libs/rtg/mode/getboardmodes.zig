// SPDX-License-Identifier: MPL-2.0
//! GetBoardModes: Copy out a board's modes.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const _mode = @import("_mode.zig");

/// Copies out the modes a board can be put into.
///
/// SYNOPSIS:
/// ```zig
/// fn GetBoardModes(rb: *RtgBase, board: *rtg.RtgBoard, into: ?[*]rtg.RtgMode, count: u32) u32
/// ```
///
/// SINCE: 1.19. LVO -220.
///
/// INPUTS:
/// - `board` - the board.
/// - `into` - where the modes go, or null to ask how many there are.
/// - `count` - how many `into` has room for.
///
/// RESULT:
/// How many modes the board has, which may be more than were copied.
///
/// BEHAVIOR:
/// Up to `count` modes are copied, the larger picture first and of one
/// size the higher refresh. Each says its number, its size, format and
/// row length, its pixel clock and refresh, its name, and in its flags
/// whether it is the board's default (`RTGMF_DEFAULT`) and the mode the
/// board is in (`RTGMF_CURRENT`).
///
/// CONTEXT:
/// - Waits: while another task holds the board's lock - through a show,
///   which may last a frame.
/// - Interrupts: no.
/// - Locks: takes the board's lock. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated: the copies are the caller's, and hold no pointer
/// into the library.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindBoardMode`, `BestBoardMode`, `ShowBoard`
///
/// EXAMPLES:
/// ```zig
/// var found: [16]rtg.RtgMode = undefined;
/// const there = rb.GetBoardModes(board, &found, found.len);
/// for (found[0..@min(there, found.len)]) |*mode| list(mode);
/// ```
pub fn GetBoardModes(rb: *RtgBase, board: *rtg.RtgBoard, into: ?[*]rtg.RtgMode, count: u32) u32 {
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    var there: u32 = 0;
    var node = boards.privateOf(board).modes.first();
    while (node) |one| : (node = one.next()) {
        if (into != null and there < count) into.?[there] = _mode.recordOf(one).mode;
        there += 1;
    }
    return there;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const std = fixture.std;
const testing = fixture.testing;

test "modes: copied out the larger picture first, named and numbered as they were made" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const board = try fixture.makeBoard(rb);

    // How many there are, asked alone, and no more copied than there is
    // room for.
    try testing.expectEqual(@as(u32, 3), fixture.base(rb).GetBoardModes(board, null, 0));
    var one: [1]rtg.RtgMode = undefined;
    try testing.expectEqual(@as(u32, 3), fixture.base(rb).GetBoardModes(board, &one, one.len));
    try testing.expectEqual(@as(u32, 640), one[0].width);

    var found: [8]rtg.RtgMode = undefined;
    try testing.expectEqual(@as(u32, 3), fixture.modesOf(rb, board, &found));
    // The second the driver added is the largest, and has kept its number.
    try testing.expectEqual(@as(u32, 2), found[0].id);
    try testing.expectEqualStrings("640x480", std.mem.sliceTo(&found[0].name, 0));
    try testing.expectEqual(@as(u32, 60_000), found[0].refresh_mhz);
    try testing.expectEqual(@as(u32, 25_200_000), found[0].pixel_clock_hz);
    // A row is the width in the format, on what the display memory is
    // aligned to: what a buffer of the mode has.
    try testing.expectEqual(@as(u32, 1280), found[0].pitch);
    try testing.expectEqual(@as(u32, 1), found[1].id);
    try testing.expectEqualStrings("320x200", std.mem.sliceTo(&found[1].name, 0));
    try testing.expectEqual(rtg.modes.RTGMF_DEFAULT, found[1].flags);
    // A display with no clock says no refresh; a row of one bit a pixel is
    // rounded up as any other.
    try testing.expectEqual(@as(u32, 3), found[2].id);
    try testing.expectEqualStrings("64x64", std.mem.sliceTo(&found[2].name, 0));
    try testing.expectEqual(rtg.PixelFormat.mono1, found[2].format);
    try testing.expectEqual(@as(u32, 0), found[2].refresh_mhz);
    try testing.expectEqual(@as(u32, 64), found[2].pitch);

    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}
