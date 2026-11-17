// SPDX-License-Identifier: MPL-2.0
//! SetBoardOverlay: the image a board lays over its picture under the
//! pointer - a dragged icon - made once in the board's own pixel format,
//! its coverage dithered into a mask.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const setboardpointer = @import("setboardpointer.zig");
const composer = @import("../compose/_compose.zig");

/// Gives a board a second image to lay over its picture, under the
/// pointer, which from then on follows the pointer.
///
/// SYNOPSIS:
/// ```zig
/// fn SetBoardOverlay(rb: *RtgBase, board: *rtg.RtgBoard, image: ?*const rtg.Surface, hot_x: u32, hot_y: u32) i32
/// ```
///
/// SINCE: 1.3. LVO -152.
///
/// INPUTS:
/// - `board` - the board.
/// - `image` - a surface in `rgba32`, `bgra32` or `argb1555`, at most
///   `RTG_OVERLAY_MAX` pixels each way; null takes the overlay away.
/// - `hot_x`, `hot_y` - the pixel of the image that is its point, inside
///   it: the one that sits at the pointer's point.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_NOT_SUPPORTED` for a board without
/// `RTGBC_OVERLAY`; `RTGERR_BAD_FORMAT` for an image with no alpha, or a
/// board whose format a pixel is not whole bytes of; `RTGERR_BAD_ARG` for
/// an image too large, empty, or with its point outside it;
/// `RTGERR_NO_MEMORY`; or what the driver answered. On any failure the
/// board keeps the overlay it had.
///
/// BEHAVIOR:
/// The image is converted here and not again, as SetBoardPointer's is:
/// every pixel into the board's format, and its coverage into a mask of
/// one bit a pixel - dithered by a 4x4 ordered pattern rather than cut in
/// half, so a soft edge, a shadow or an image made see-through keeps its
/// look as a pattern of dots. It is laid over the picture on the way to
/// the glass, under the pointer, the picture never holding it - by the
/// board itself where it has the means, by the library where it composes
/// the board's picture; it is shown whether the pointer is or not, so a
/// finger dragging on a touch panel, where the pointer is hidden, sees
/// it. Its point is put at the pointer's, and it follows the pointer's
/// moves until `MoveBoardOverlay` puts it somewhere of its own.
///
/// CONTEXT:
/// - Waits: for the board's compose lock while another task moves the
///   pointer or hands on what it drew, for the board's lock where the
///   library lays the overlay, and for a driver that sends the rows over
///   a bus.
/// - Interrupts: no. It allocates.
/// - Locks: takes the board's compose lock while the image changes, and
///   the board's lock before it where the library lays the overlay; no
///   spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's image is read and not kept. The converted one is the
/// library's - in internal memory where a driver whose interrupts read
/// it lays it - freed by the next SetBoardOverlay or by DeleteBoard.
///
/// NOTES:
/// intuition's `BeginDrag` and `EndDrag` are how a program drags: they
/// set the overlay on the right board and take it away again.
///
/// BUGS:
/// As `SetBoardPointer`: an image made for one pixel format is not laid
/// by the library in a mode of another.
///
/// SEE ALSO:
/// `MoveBoardOverlay`, `SetBoardPointer`, `MoveBoardPointer`
///
/// EXAMPLES:
/// ```zig
/// if (rb.SetBoardOverlay(board, &icon_surface, 24, 24) == rtg.errors.RTGERR_OK) {
///     // ... the pointer moves; the icon with it ...
///     _ = rb.SetBoardOverlay(board, null, 0, 0);
/// }
/// ```
pub fn SetBoardOverlay(rb: *RtgBase, board: *rtg.RtgBoard, image: ?*const rtg.Surface, hot_x: u32, hot_y: u32) i32 {
    if (board.info.caps & rtg.boards.RTGBC_OVERLAY == 0) return err.RTGERR_NOT_SUPPORTED;

    const made: ?*rtg.RtgPointerImage = if (image) |source| blk: {
        const converted = setboardpointer.convert(rb, board, source, hot_x, hot_y, rtg.boards.RTG_OVERLAY_MAX, .dither, composer.laysOverlay(board));
        if (converted.code != err.RTGERR_OK) return converted.code;
        break :blk converted.image;
    } else null;

    const code = composer.setOverlay(rb, board, made);
    if (code != err.RTGERR_OK) {
        if (made) |refused| rb.sys_base.FreeVec(refused);
    }
    return code;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "the overlay: its coverage dithered, following the pointer, placed on its own, freed with the board" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeBoard(rb);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.setMode(rb, board, 0));
    var info: rtg.RtgBoardInfo = .{};
    _ = fixture.base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expect(info.caps & rtg.boards.RTGBC_OVERLAY != 0);

    // Eight by four, rgba32: a row of full coverage, a row of none, two
    // rows at half.
    var pixels: [32]u32 = undefined;
    for (&pixels, 0..) |*pixel, i| pixel.* = fixture.rgba(switch (i / 8) {
        0 => 0xFF0000FF,
        1 => 0xFF000000,
        else => 0x00FF0080,
    });
    const image = rtg.Surface{ .pixels = @ptrCast(&pixels), .width = 8, .height = 4, .pitch = 32, .format = .rgba32 };

    fixture.base(rb).MoveBoardPointer(board, 100, 50);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardOverlay(board, &image, 4, 2));
    const made = fk.log.overlay_image.?;
    try testing.expectEqual(made, board.overlay.?);
    for (0..8) |x| {
        try testing.expect(fixture.opaqueAt(made, @intCast(x), 0)); // full: every pixel
        try testing.expect(!fixture.opaqueAt(made, @intCast(x), 1)); // none: no pixel
    }
    var half: u32 = 0;
    for (2..4) |y| for (0..8) |x| {
        if (fixture.opaqueAt(made, @intCast(x), @intCast(y))) half += 1;
    };
    try testing.expectEqual(@as(u32, 8), half); // half: half of them, as dots
    // Its point at the pointer's, and with the pointer when it moves.
    try testing.expectEqual(@as(i32, 96), fk.log.overlay_left);
    try testing.expectEqual(@as(i32, 48), fk.log.overlay_top);
    fixture.base(rb).MoveBoardPointer(board, 110, 60);
    try testing.expectEqual(@as(i32, 106), fk.log.overlay_left);
    try testing.expectEqual(@as(i32, 58), fk.log.overlay_top);

    // Placed on its own, it stays when the pointer moves on.
    fixture.base(rb).MoveBoardOverlay(board, 20, 30);
    try testing.expectEqual(@as(i32, 16), fk.log.overlay_left);
    try testing.expectEqual(@as(i32, 28), fk.log.overlay_top);
    const moves = fk.log.overlay_moves;
    fixture.base(rb).MoveBoardPointer(board, 200, 200);
    try testing.expectEqual(moves, fk.log.overlay_moves);
    fixture.base(rb).MoveBoardOverlay(board, 20, 30); // the same place: no move
    try testing.expectEqual(moves, fk.log.overlay_moves);

    // A new image follows the pointer again; too large is refused and the
    // one there stays.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardOverlay(board, &image, 0, 0));
    try testing.expectEqual(@as(i32, 200), fk.log.overlay_left);
    const huge = rtg.Surface{ .pixels = @ptrCast(&pixels), .width = rtg.boards.RTG_OVERLAY_MAX + 1, .height = 1, .pitch = 4, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).SetBoardOverlay(board, &huge, 0, 0));
    try testing.expect(board.overlay != null);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardOverlay(board, null, 0, 0));
    try testing.expect(board.overlay == null and fk.log.overlay_image == null);

    // One still set when the board goes is freed with it.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardOverlay(board, &image, 0, 0));
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}
