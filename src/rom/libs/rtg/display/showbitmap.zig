// SPDX-License-Identifier: MPL-2.0
//! ShowBitMap: Show that buffer, whole, in the mode the board is in; null
//! shows nothing.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _display = @import("_display.zig");
const boards = @import("../board/_board.zig");

/// Shows a buffer on a board's display.
///
/// SYNOPSIS:
/// ```zig
/// fn ShowBitMap(rb: *RtgBase, board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap) i32
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// - `board` - the board.
/// - `bitmap` - one of its buffers made `RTGBMF_DISPLAYABLE`, in the
///   format and of the size of the mode the board is in - of any size on
///   a board that scales its bands (`RTGBC_SCALE_BANDS`), where it is
///   shown scaled to the display's width - or null to show nothing.
///
/// RESULT:
/// `RTGERR_OK`, or what `ShowBoard` answers for that one buffer from the
/// display's top: `RTGERR_BAD_ARG` for another board's buffer or one with
/// no pixels, `RTGERR_NOT_DISPLAYABLE`, `RTGERR_BAD_FORMAT`,
/// `RTGERR_NO_DISPLAY` for a buffer on a board whose device has gone,
/// `RTGERR_NO_MODE` on a board with no mode, `RTGERR_NOT_SUPPORTED` for a
/// board that shows nothing, or what the driver answered.
///
/// BEHAVIOR:
/// It is `ShowBoard` with the mode kept and one band: the buffer, its
/// first row at the display's top. A board that is in no mode yet is put
/// in its default with it. The buffers shown before - one, or several in
/// bands - are no longer marked showing, so they can be freed; the new one
/// is, so it cannot. A display that is already showing takes the new
/// buffer up whole, at the start of a frame, and this returns when it
/// has: the one shown before is no longer read and may be drawn into -
/// which is how a program shows a frame while it draws the next.
///
/// A show that fails changes nothing, as `ShowBoard` has it. The same for
/// null: a board that could not be made to show nothing goes on showing
/// its picture.
///
/// CONTEXT:
/// - Waits: for the display's next frame, where the board streams one,
///   and while another task holds the board's lock.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: takes the board's lock around the driver's show and the marks
///   on the board's buffers, so two shows of one board follow each other.
///   No spinlock may be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The buffer stays the caller's.
///
/// BUGS:
/// `ShowBoard`'s BUGS has what a driver does not keep yet.
///
/// SEE ALSO:
/// `ShowBoard`, `BoardDisplayBitMap`, `AllocBitMap`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.ShowBitMap(board, buffer);
/// ```
pub fn ShowBitMap(rb: *RtgBase, board: *rtg.RtgBoard, bitmap: ?*rtg.RtgBitMap) i32 {
    // One show at a time on a board, the driver's and the marks together.
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    const whole = bitmap orelse return _display.show(rb, board, null, &.{});
    const code = _display.show(rb, board, null, &.{.{ .bitmap = whole }});
    // The first picture is what the backlight is lit with.
    if (code == rtg.errors.RTGERR_OK) _display.light(rb, board);
    return code;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "showing a buffer, and what may not be shown" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeDisplay(rb, 16, 16);
    const other = try fixture.makeDisplay(rb, 16, 16);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;

    const hidden = fixture.base(rb).AllocBitMap(board, 16, 16, format, 0).?;
    const up = fixture.base(rb).AllocBitMap(board, 16, 16, format, displayable).?;
    const small = fixture.base(rb).AllocBitMap(board, 8, 16, format, displayable).?;
    const short = fixture.base(rb).AllocBitMap(board, 16, 8, format, displayable).?;
    const deep = fixture.base(rb).AllocBitMap(board, 16, 16, @intFromEnum(rtg.PixelFormat.bgra32), displayable).?;
    const elsewhere = fixture.base(rb).AllocBitMap(other, 16, 16, format, displayable).?;

    // Not made to be shown, not the mode's size, not its format, not this
    // board's: each refused by the library, the driver not asked.
    try testing.expectEqual(rtg.errors.RTGERR_NOT_DISPLAYABLE, fixture.base(rb).ShowBitMap(board, hidden));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_DISPLAYABLE, fixture.base(rb).ShowBitMap(board, small));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_DISPLAYABLE, fixture.base(rb).ShowBitMap(board, short));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_FORMAT, fixture.base(rb).ShowBitMap(board, deep));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).ShowBitMap(board, elsewhere));
    try testing.expectEqual(@as(u32, 0), fk.log.shown);
    try testing.expectEqual(@as(u32, 0), fixture.infoOf(rb, board).mode_id);

    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, up));
    try testing.expectEqual(up, fixture.base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(up.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);
    // The driver was handed the one buffer as a band from the top.
    try testing.expectEqual(@as(u32, 1), fk.log.band_count);
    try testing.expectEqual(up, fk.log.bands[0].bitmap);
    try testing.expectEqual(@as(u32, 0), fk.log.bands[0].line);

    // What the board is reading is not the caller's to take away.
    fixture.base(rb).FreeBitMap(up);
    try testing.expectEqual(up, fixture.base(rb).BoardDisplayBitMap(board).?);

    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, null));
    try testing.expect(fixture.base(rb).BoardDisplayBitMap(board) == null);
    try testing.expect(up.flags & rtg.bitmaps.RTGBMF_SHOWING == 0);
    // The board stays in its mode with nothing shown.
    try testing.expectEqual(@as(u32, 1), fixture.infoOf(rb, board).mode_id);

    fixture.base(rb).FreeBitMap(elsewhere);
    fixture.base(rb).FreeBitMap(deep);
    fixture.base(rb).FreeBitMap(short);
    fixture.base(rb).FreeBitMap(small);
    fixture.base(rb).FreeBitMap(up);
    fixture.base(rb).FreeBitMap(hidden);
    fixture.driverBase(rb).DeleteBoard(other);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}

test "a show that fails changes nothing: the buffer shown stays, the one refused can go" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeDisplay(rb, 16, 16);
    const glass = fixture.fake.instanceOf(board);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const showing = rtg.bitmaps.RTGBMF_SHOWING;
    const first = fixture.base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const second = fixture.base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;

    // The board is handed what was asked for: the buffer.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, first));
    try testing.expectEqual(first, fk.log.last_show_bitmap.?);
    try testing.expectEqual(@as(u32, 1), glass.showing_count);
    try testing.expectEqual(first, glass.showing[0].bitmap);
    // A show that works is a picture counted.
    const swaps = fixture.swapsOf(rb, board);
    try testing.expectEqual(@as(u32, 1), swaps);

    // Refused: the answer is the driver's, and neither side has moved -
    // the library's marks, what it answers, its count of pictures, and
    // what the board itself shows.
    fk.show_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, fixture.base(rb).ShowBitMap(board, second));
    try testing.expectEqual(second, fk.log.last_show_bitmap.?);
    try testing.expectEqual(first, fixture.base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(first.flags & showing != 0);
    try testing.expect(second.flags & showing == 0);
    try testing.expectEqual(swaps, fixture.swapsOf(rb, board));
    try testing.expectEqual(@as(u32, 1), glass.showing_count);
    try testing.expectEqual(first, glass.showing[0].bitmap);

    // The one still shown cannot be freed; the one refused can.
    fixture.base(rb).FreeBitMap(first);
    try testing.expectEqual(first, fixture.base(rb).BoardDisplayBitMap(board).?);
    const free_before = fixture.freeOf(rb, board);
    fixture.base(rb).FreeBitMap(second);
    try testing.expect(fixture.freeOf(rb, board) > free_before);

    // Showing nothing refused: the picture stays up, and stays marked.
    fk.show_answer = rtg.errors.RTGERR_NO_DISPLAY;
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, fixture.base(rb).ShowBitMap(board, null));
    try testing.expectEqual(first, fixture.base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(first.flags & showing != 0);
    try testing.expect(board.info.flags & rtg.boards.RTGBF_SHOWING != 0);
    try testing.expectEqual(@as(u32, 1), glass.showing_count);

    // The refusal was that show's alone: the next one works.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, null));
    try testing.expect(fixture.base(rb).BoardDisplayBitMap(board) == null);
    try testing.expectEqual(@as(u32, 0), glass.showing_count);

    fixture.base(rb).FreeBitMap(first);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}
