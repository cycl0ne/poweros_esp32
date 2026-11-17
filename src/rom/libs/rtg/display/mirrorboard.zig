// SPDX-License-Identifier: MPL-2.0
//! MirrorBoard: Mirror the picture about each axis.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const composer = @import("../compose/_compose.zig");

/// Mirrors a board's picture about each axis, or shows it unturned.
///
/// SYNOPSIS:
/// ```zig
/// fn MirrorBoard(rb: *RtgBase, board: *rtg.RtgBoard, mirror_x: bool, mirror_y: bool) i32
/// ```
///
/// SINCE: 1.0. LVO -136.
///
/// INPUTS:
/// - `board` - the board.
/// - `mirror_x` - whether the picture is mirrored left to right.
/// - `mirror_y` - whether it is mirrored top to bottom.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_NOT_SUPPORTED` for an axis the board cannot
/// mirror (`RTGBC_MIRROR_X`, `RTGBC_MIRROR_Y`) - nothing changes then -
/// or what the driver answered, and the picture turned as it was.
///
/// BEHAVIOR:
/// Each axis is set on its own: false leaves it unturned. The picture,
/// the overlay and the pointer are mirrored alike on the way to the
/// glass, so nothing above the board changes: whoever draws and whoever
/// moves the pointer works in the picture's own coordinates. What is
/// shown is on the glass mirrored when this returns.
///
/// A board whose own hardware turns an axis - a controller's scan
/// direction, planes read backwards, a stream's lines sent last first -
/// does that axis itself. On a board whose picture the library composes
/// it mirrors every other axis as it composes; such a picture is not
/// read by the display itself for as long as it is mirrored.
///
/// `GetBoardInfo` says how the picture is turned (`mirror_x`,
/// `mirror_y`): what a touch panel's driver reads, so that a finger
/// lands on the picture. The tasks that asked are told of a change
/// (`AddRtgNotify`). A quarter turn is not this: it is a mode with its
/// sides exchanged (`RTGMF_TURNED`).
///
/// CONTEXT:
/// - Waits: for the picture delivered again, where the driver waits,
///   and while another task holds the board's lock.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: takes the board's lock, and inside it the board's compose
///   lock. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetBoardInfo`, `ComposeLines`, `MoveBoardPointer`
///
/// EXAMPLES:
/// ```zig
/// // Left and right exchanged, top and bottom as they are.
/// _ = rb.MirrorBoard(board, true, false);
/// ```
pub fn MirrorBoard(rb: *RtgBase, board: *rtg.RtgBoard, mirror_x: bool, mirror_y: bool) i32 {
    return composer.mirror(rb, board, mirror_x, mirror_y);
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "mirrored by the board's own hardware: the axes its driver said, handed on as asked, the picture shown again" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const board = try fixture.makeDisplay(rb, 16, 16);
    const both = rtg.boards.RTGBC_MIRROR_X | rtg.boards.RTGBC_MIRROR_Y;

    var info = fixture.infoOf(rb, board);
    try testing.expectEqual(both, info.caps & both);
    // A board reports itself the right way up until it is turned.
    try testing.expectEqual(@as(u8, 0), info.mirror_x);
    try testing.expectEqual(@as(u8, 0), info.mirror_y);
    const picture = fixture.base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, picture));
    const shown = fk.log.shown;
    const changes = info.changes;

    // Mirroring is handed to the board as asked and remembered, what a
    // caller draws on keeps its sides, and the driver is asked for what
    // it shows again: a stream sends its lines the other way round.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).MirrorBoard(board, true, false));
    try testing.expectEqual(@as(u32, 1), fk.log.mirrors);
    try testing.expect(fk.log.last_mirror_x and !fk.log.last_mirror_y);
    try testing.expectEqual(shown + 1, fk.log.shown);
    try testing.expectEqual(picture, fk.log.bands[0].bitmap);
    info = fixture.infoOf(rb, board);
    try testing.expectEqual(@as(u8, 1), info.mirror_x);
    try testing.expectEqual(@as(u8, 0), info.mirror_y);
    try testing.expectEqual(@as(u32, 16), info.width);
    try testing.expect(info.changes != changes);
    // The same again changes nothing and asks nobody.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).MirrorBoard(board, true, false));
    try testing.expectEqual(@as(u32, 1), fk.log.mirrors);
    try testing.expectEqual(shown + 1, fk.log.shown);

    // A turn the driver refuses leaves the picture as it was turned.
    fk.mirror_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, fixture.base(rb).MirrorBoard(board, true, true));
    fk.mirror_answer = rtg.errors.RTGERR_OK;
    info = fixture.infoOf(rb, board);
    try testing.expectEqual(@as(u8, 1), info.mirror_x);
    try testing.expectEqual(@as(u8, 0), info.mirror_y);
    // And one whose picture cannot be shown again is turned back.
    fk.show_answer = rtg.errors.RTGERR_NO_DISPLAY;
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, fixture.base(rb).MirrorBoard(board, false, true));
    try testing.expect(fk.log.last_mirror_x and !fk.log.last_mirror_y);
    try testing.expectEqual(@as(u8, 0), fixture.infoOf(rb, board).mirror_y);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).MirrorBoard(board, false, false));
    try testing.expect(!fk.log.last_mirror_x and !fk.log.last_mirror_y);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, null));
    fixture.base(rb).FreeBitMap(picture);
    fixture.driverBase(rb).DeleteBoard(board);

    // A stream that can send its lines last first and cannot turn one
    // round: top to bottom alone, and the other axis refused whole.
    fk.mirror_axes = rtg.boards.RTGBC_MIRROR_Y;
    const stream = try fixture.makeBoard(rb);
    fk.mirror_axes = both;
    try testing.expectEqual(rtg.boards.RTGBC_MIRROR_Y, fixture.infoOf(rb, stream).caps & both);
    const mirrors = fk.log.mirrors;
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, fixture.base(rb).MirrorBoard(stream, true, true));
    try testing.expectEqual(mirrors, fk.log.mirrors);
    try testing.expectEqual(@as(u8, 0), fixture.infoOf(rb, stream).mirror_y);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).MirrorBoard(stream, false, true));
    try testing.expect(!fk.log.last_mirror_x and fk.log.last_mirror_y);
    try testing.expectEqual(@as(u8, 1), fixture.infoOf(rb, stream).mirror_y);
    fixture.driverBase(rb).DeleteBoard(stream);
    try fixture.tearDown(rb);
}

test "a board whose pixels go out as they are written will not turn" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    fk.cannot_turn = true;
    const board = try fixture.makeBoard(rb);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.setMode(rb, board, 0));

    var info: rtg.RtgBoardInfo = .{};
    _ = fixture.base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u32, 0), info.caps & (rtg.boards.RTGBC_MIRROR_X | rtg.boards.RTGBC_MIRROR_Y));

    const width = info.width;
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, fixture.base(rb).MirrorBoard(board, true, true));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, fixture.base(rb).MirrorBoard(board, false, true));
    // Refused means nothing moved: what it says about itself is unchanged.
    _ = fixture.base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(width, info.width);
    try testing.expectEqual(@as(u8, 0), info.mirror_x);
    try testing.expectEqual(@as(u8, 0), info.mirror_y);
    try testing.expectEqual(@as(u32, 0), fk.log.mirrors);
    // Unturned is what it is.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).MirrorBoard(board, false, false));

    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}

test "mirrored by the library: the picture, the pointer and what is written, each way, in the display's own coordinates" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeComposed(rb, 16, 12, 1);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const direct = rtg.boards.RTGSHOW_DIRECT;
    const both = rtg.boards.RTGBC_MIRROR_X | rtg.boards.RTGBC_MIRROR_Y;
    // Its driver wrote no mirror, and the board has both axes.
    try testing.expectEqual(both, fixture.infoOf(rb, board).caps & both);

    const picture = fixture.base(rb).AllocBitMap(board, 16, 12, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    fixture.paint(picture, 1);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, picture));
    try testing.expect(fk.log.last_flags & direct != 0);
    const changes = fixture.infoOf(rb, board).changes;

    // Left to right: the display reads the buffer no more, and is
    // delivered the picture with each row turned round.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).MirrorBoard(board, true, false));
    try testing.expectEqual(@as(u32, 0), fk.log.last_flags & direct);
    var info = fixture.infoOf(rb, board);
    try testing.expectEqual(@as(u8, 1), info.mirror_x);
    try testing.expectEqual(@as(u8, 0), info.mirror_y);
    try testing.expect(info.changes != changes);
    var y: u32 = 0;
    while (y < 12) : (y += 1) {
        var x: u32 = 0;
        while (x < 16) : (x += 1) try testing.expectEqual(fixture.painted(1, 15 - x, y), fixture.onGlass(board, x, y));
    }
    // What is written is delivered where the display shows it.
    fixture.poke(picture, 2, 1, fixture.white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RefreshRect(picture, &.{ .x = 2, .y = 1, .width = 3, .height = 2 }));
    try testing.expectEqual(rtg.RtgRect{ .x = 11, .y = 1, .width = 3, .height = 2 }, fk.log.last_update);
    try testing.expectEqual(fixture.white, fixture.onGlass(board, 13, 1));
    try testing.expectEqual(fixture.painted(1, 3, 1), fixture.onGlass(board, 12, 1));
    fixture.poke(picture, 2, 1, fixture.painted(1, 2, 1));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RefreshRect(picture, null));

    // The pointer is placed in the picture's coordinates, and laid
    // where the display shows that place.
    var dot = [_]u32{fixture.rgba(0xFF0000FF)};
    const pointer = rtg.Surface{ .pixels = @ptrCast(&dot), .width = 1, .height = 1, .pitch = 4, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardPointer(board, &pointer, 0, 0));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBoardPointer(board, true));
    fixture.base(rb).MoveBoardPointer(board, 3, 2);
    try testing.expectEqual(fixture.red, fixture.onGlass(board, 12, 2));
    try testing.expectEqual(rtg.RtgRect{ .x = 12, .y = 2, .width = 1, .height = 1 }, fk.log.last_update);
    try testing.expectEqual(fixture.painted(1, 0, 0), fixture.onGlass(board, 15, 0));

    // Both ways: the picture upside down as well, the pointer with it.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).MirrorBoard(board, true, true));
    y = 0;
    while (y < 12) : (y += 1) {
        var x: u32 = 0;
        while (x < 16) : (x += 1) {
            const expected = if (x == 12 and y == 9) fixture.red else fixture.painted(1, 15 - x, 11 - y);
            try testing.expectEqual(expected, fixture.onGlass(board, x, y));
        }
    }
    // Top to bottom alone, and a rectangle fetched is the display's.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).MirrorBoard(board, false, true));
    try testing.expectEqual(fixture.red, fixture.onGlass(board, 3, 9));
    var fetched: [6]u16 = undefined;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.driverBase(rb).ComposeLines(board, &.{ .x = 4, .y = 2, .width = 3, .height = 2 }, @ptrCast(&fetched), 6));
    try testing.expectEqual([6]u16{ fixture.painted(1, 4, 9), fixture.painted(1, 5, 9), fixture.painted(1, 6, 9), fixture.painted(1, 4, 8), fixture.painted(1, 5, 8), fixture.painted(1, 6, 8) }, fetched);

    // Unturned with nothing over it, the display reads the buffer again.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardPointer(board, null, 0, 0));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).MirrorBoard(board, false, false));
    try testing.expect(fk.log.last_flags & direct != 0);
    info = fixture.infoOf(rb, board);
    try testing.expectEqual(@as(u8, 0), info.mirror_x);
    try testing.expectEqual(@as(u8, 0), info.mirror_y);

    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, null));
    fixture.base(rb).FreeBitMap(picture);
    fixture.driverBase(rb).DeleteBoard(board);

    // A flipped board the same: the next picture is made mirrored, and
    // what is written is noted where the display shows it.
    const flipped = try fixture.makeFlipped(rb, 16, 12);
    const frame = fixture.base(rb).AllocBitMap(flipped, 16, 12, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    fixture.paint(frame, 2);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(flipped, frame));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).MirrorBoard(flipped, true, true));
    fixture.flips.service(rb, flipped);
    y = 0;
    while (y < 12) : (y += 1) {
        var x: u32 = 0;
        while (x < 16) : (x += 1) try testing.expectEqual(fixture.painted(2, 15 - x, 11 - y), fixture.glassAt(flipped, x, y));
    }
    fixture.poke(frame, 1, 0, fixture.white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RefreshRect(frame, &.{ .x = 1, .y = 0, .width = 1, .height = 1 }));
    fixture.flips.service(rb, flipped);
    try testing.expectEqual(fixture.white, fixture.glassAt(flipped, 14, 11));
    try testing.expectEqual(fixture.painted(2, 2, 0), fixture.glassAt(flipped, 13, 11));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(flipped, null));
    fixture.base(rb).FreeBitMap(frame);
    fixture.driverBase(rb).DeleteBoard(flipped);
    try fixture.tearDown(rb);
}

test "an axis the board's hardware turns is the hardware's, the other the library's; the whole picture is delivered again" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    fk.hardware = true;
    fk.mirror_axes = rtg.boards.RTGBC_MIRROR_X;
    const board = try fixture.makeComposed(rb, 16, 12, 0);
    fk.hardware = false;
    fk.mirror_axes = rtg.boards.RTGBC_MIRROR_X | rtg.boards.RTGBC_MIRROR_Y;
    const picture = fixture.base(rb).AllocBitMap(board, 16, 12, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    fixture.paint(picture, 1);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, picture));

    // Left to right is the hardware's: the driver is told, the picture
    // delivered again whole and as it lies - a controller whose scan
    // direction changed holds a picture written the other way round.
    const updates = fk.log.updates;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).MirrorBoard(board, true, false));
    try testing.expectEqual(@as(u32, 1), fk.log.mirrors);
    try testing.expect(fk.log.last_mirror_x and !fk.log.last_mirror_y);
    try testing.expectEqual(updates + 1, fk.log.updates);
    try testing.expectEqual(rtg.RtgRect{ .width = 16, .height = 12 }, fk.log.last_update);
    try testing.expect(fixture.seesOnly(board, 1));

    // Top to bottom is the library's: the driver hears of its own axis
    // alone, and is delivered the picture upside down.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).MirrorBoard(board, true, true));
    try testing.expectEqual(@as(u32, 1), fk.log.mirrors);
    try testing.expectEqual(fixture.painted(1, 5, 11), fixture.onGlass(board, 5, 0));
    try testing.expectEqual(fixture.painted(1, 15, 0), fixture.onGlass(board, 15, 11));
    const info = fixture.infoOf(rb, board);
    try testing.expectEqual(@as(u8, 1), info.mirror_x);
    try testing.expectEqual(@as(u8, 1), info.mirror_y);
    // The hardware's axis back: the driver is told, the library's stays.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).MirrorBoard(board, false, true));
    try testing.expectEqual(@as(u32, 2), fk.log.mirrors);
    try testing.expect(!fk.log.last_mirror_x);
    try testing.expectEqual(fixture.painted(1, 5, 11), fixture.onGlass(board, 5, 0));

    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, null));
    fixture.base(rb).FreeBitMap(picture);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}
