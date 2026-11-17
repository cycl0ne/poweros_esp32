// SPDX-License-Identifier: MPL-2.0
//! ComposeLines: The pixels of a rectangle of a board's display as they
//! are to be seen.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _compose = @import("_compose.zig");

/// Fetches the pixels of a rectangle of a board's picture, as the library
/// composes it.
///
/// SYNOPSIS:
/// ```zig
/// fn ComposeLines(rb: *RtgBase, board: *rtg.RtgBoard, area: *const rtg.RtgRect, into: [*]u8, pitch: u32) i32
/// ```
///
/// SINCE: 1.24. LVO -316.
///
/// INPUTS:
/// - `board` - the board: one of the caller's own, whose display has a
///   picture of its own (`update`).
/// - `area` - the rectangle, in the display's coordinates - the
///   picture's own, mirrored where the library mirrors the picture -
///   wholly inside the display in the mode the board is shown in: the
///   rectangle `update` was handed, as it is.
/// - `into` - where the pixels go, the rectangle's top left first:
///   `area.height` rows of `area.width` pixels in the mode's format.
/// - `pitch` - bytes from one row of `into` to the next; at least a row
///   of the rectangle.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_BAD_ARG` for a rectangle that is empty or not
/// wholly inside the display; `RTGERR_BAD_FORMAT` in a mode whose pixels
/// are not whole bytes, and on a board that was never shown.
///
/// BEHAVIOR:
/// Each line of the rectangle comes from the band that covers it - the
/// buffer's row that far below the band's origin, its first row for a
/// repeating band - and is black where no band does, as on a board that
/// shows nothing. A band whose buffer is not the display's width comes
/// scaled, by the ratio of the two widths both ways, its neighbouring
/// pixels mixed where that is no whole number; a line whose row the
/// buffer has not got is black. Over that the overlay is laid, and over
/// both the pointer where it is shown: each a masked copy of the part of
/// its image inside the rectangle. An image the board lays itself
/// (`RtgPointerOps`, `RtgOverlayOps`) is not laid here.
///
/// A picture the library mirrors (`MirrorBoard`, an axis the board's
/// own hardware does not turn) comes mirrored: its rows the other way
/// round, each row turned round. On a board that is blank or asleep
/// (`SetBoardPower`) every pixel is black.
///
/// It is what a driver calls from its `update`, for the rectangle it was
/// handed, and from its `show` for the whole display when the board is
/// shown without `RTGSHOW_DIRECT`: the bands of that show are in place
/// then. The pixels may go straight into the display's own memory or
/// into a block the driver sends.
///
/// CONTEXT:
/// - Waits: for the board's compose lock, where the caller does not hold
///   it; inside `update` and `show` it does.
/// - Interrupts: no.
/// - Locks: takes the board's compose lock, which nests for the task
///   that holds it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. `into` is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateBoard`, `RefreshRect`, `SetBoardPointer`, `ShowBoard`
///
/// EXAMPLES:
/// ```zig
/// // update: the rectangle straight into the display's own frame.
/// fn update(board: *rtg.RtgBoard, area: *const rtg.RtgRect) callconv(.c) i32 {
///     const screen = screenOf(board);
///     const at = screen.frame + @as(usize, @intCast(area.y)) * screen.pitch + @as(usize, @intCast(area.x)) * 4;
///     return screen.rtg_base.ComposeLines(board, area, at, screen.pitch);
/// }
/// ```
pub fn ComposeLines(rb: *RtgBase, board: *rtg.RtgBoard, area: *const rtg.RtgRect, into: [*]u8, pitch: u32) i32 {
    _compose.obtain(rb, board);
    defer _compose.release(rb, board);
    return _compose.lines(rb, board, area, into, pitch);
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const std = fixture.std;
const testing = fixture.testing;

test "ComposeLines: a rectangle of the picture, and what is none" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const board = try fixture.makeComposed(rb, 16, 12, 0);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    var into: [8 * 4]u16 = undefined;
    const whole_lines = rtg.RtgRect{ .x = 4, .y = 2, .width = 8, .height = 4 };

    // A board never shown has no picture to say the size of.
    try testing.expectEqual(rtg.errors.RTGERR_BAD_FORMAT, fixture.driverBase(rb).ComposeLines(board, &whole_lines, @ptrCast(&into), 16));

    const picture = fixture.base(rb).AllocBitMap(board, 16, 12, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    fixture.paint(picture, 5);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, picture));

    // The rectangle's rows, its own pitch apart, and nothing past them.
    @memset(&into, 0xAAAA);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.driverBase(rb).ComposeLines(board, &.{ .x = 4, .y = 2, .width = 3, .height = 2 }, @ptrCast(&into), 16));
    try testing.expectEqual(fixture.painted(5, 4, 2), into[0]);
    try testing.expectEqual(fixture.painted(5, 6, 2), into[2]);
    try testing.expectEqual(@as(u16, 0xAAAA), into[3]);
    try testing.expectEqual(fixture.painted(5, 4, 3), into[8]);
    try testing.expectEqual(@as(u16, 0xAAAA), into[16]);

    // The last pixel of the picture is inside; a rectangle that is empty,
    // starts before the picture or ends past it is none.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.driverBase(rb).ComposeLines(board, &.{ .x = 15, .y = 11, .width = 1, .height = 1 }, @ptrCast(&into), 2));
    try testing.expectEqual(fixture.painted(5, 15, 11), into[0]);
    for ([_]rtg.RtgRect{
        .{ .x = 0, .y = 0, .width = 0, .height = 4 },
        .{ .x = 0, .y = 0, .width = 4, .height = -1 },
        .{ .x = -1, .y = 0, .width = 4, .height = 4 },
        .{ .x = 0, .y = -1, .width = 4, .height = 4 },
        .{ .x = 13, .y = 0, .width = 4, .height = 4 },
        .{ .x = 0, .y = 9, .width = 4, .height = 4 },
        .{ .x = std.math.maxInt(i32), .y = 0, .width = std.math.maxInt(i32), .height = 1 },
    }) |area| {
        try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.driverBase(rb).ComposeLines(board, &area, @ptrCast(&into), 16));
    }

    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, null));
    fixture.base(rb).FreeBitMap(picture);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}
