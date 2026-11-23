// SPDX-License-Identifier: MPL-2.0
//! ShowBoard: Put the board in a mode and show bands of buffers in it,
//! as one step.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const _display = @import("_display.zig");
const boards = @import("../board/_board.zig");
const modes = @import("../mode/_mode.zig");

/// Puts a board in a mode and shows buffers in it, each in a band of
/// display lines.
///
/// SYNOPSIS:
/// ```zig
/// fn ShowBoard(rb: *RtgBase, board: *rtg.RtgBoard, mode_id: u32, bands: ?[*]const rtg.RtgBand, count: u32) i32
/// ```
///
/// SINCE: 1.21. LVO -244.
///
/// INPUTS:
/// - `board` - the board.
/// - `mode_id` - the number of the mode to put it in, as `FindBoardMode`,
///   `BestBoardMode` and `GetBoardModes` answer it; 0 keeps the mode it is
///   in, or takes its default where it is in none.
/// - `bands` - `count` bands, from the top of the display down: each a
///   buffer of the board made `RTGBMF_DISPLAYABLE`, in the mode's format
///   and as large as the mode, the display `line` its band starts at, and
///   the display line its first row sits at (`origin`, at most `line`);
///   or, with `RTGBANDF_REPEAT` in its `flags`, a buffer as wide as the
///   mode and at least a row high, whose first row every line of the band
///   shows. On a board that scales its bands (`RTGBC_SCALE_BANDS`) a
///   buffer may be of any size. The first band starts at line 0, every
///   other below the one before, and the last runs to the display's
///   bottom. Null with a `count` of 0.
/// - `count` - 0 to `RTG_MAX_BANDS`; 0 shows nothing.
///
/// RESULT:
/// `RTGERR_OK`, or: `RTGERR_BAD_MODE` for a number the board has no mode
/// of now; `RTGERR_NO_MODE` on a board with no mode; `RTGERR_BAD_ARG` for
/// more bands than a display shows, bands out of order, another board's
/// buffer or a buffer with no pixels; `RTGERR_NOT_DISPLAYABLE` for a
/// buffer that was not made to be shown, and for one that is not the
/// mode's size on a board that scales no bands; `RTGERR_BAD_FORMAT` for
/// one not in the mode's format, and for bands the library would compose
/// in a format whose pixels are not whole bytes; `RTGERR_NO_DISPLAY` on a
/// board whose device has gone; `RTGERR_NOT_SUPPORTED` for a board that
/// shows nothing, or bands on one that shows only a whole buffer
/// (`RTGBC_BANDS`); or what the driver answered.
///
/// BEHAVIOR:
/// The mode and what is shown in it change together. Display line `y` of
/// a band shows its buffer's row `y - origin`, so a screen pulled down a
/// hundred lines is a band from line 100 with its origin there, and the
/// screen behind it a band from line 0 above it. A band whose buffer is
/// not the mode's width is shown scaled, by the ratio of the mode's width
/// to the buffer's, both ways the same: it fills the display's width,
/// line `y` shows the buffer's row `(y - origin) * buffer width / mode
/// width`, and neighbouring pixels are mixed where the mode's width is
/// not a whole number of the buffer's. A line whose row the buffer has
/// not got is black. A repeating band shows
/// one row on all its lines: an empty stretch of the display in a colour,
/// from a buffer of one row. Every buffer in a band is marked showing and
/// cannot be freed; the others of the board are not. `BoardDisplayBitMap`
/// answers the last band's buffer, the one at the display's bottom. A
/// display that is already showing takes the new bands up at the start of
/// a frame, and this returns when it has.
///
/// A buffer is not touched by a mode change: every buffer of the board
/// keeps its memory, and one of another size is shown again by showing it
/// in the mode of its size. What the board says of itself follows the
/// mode (`GetBoardInfo`), and the tasks that asked are told
/// (`AddRtgNotify`).
///
/// A show that fails changes nothing: on any answer but `RTGERR_OK` the
/// board is in the mode it was in and shows what it showed, marked as it
/// was, and a buffer of the bands refused that was not showing is not
/// marked, so it can be freed. For another mode the driver may have to be
/// asked for what was shown again; where it then cannot show that either,
/// the board is in no mode and shows nothing, and says so. On a board
/// that is sent its picture over a bus, rows of a buffer refused may have
/// reached the glass before the send failed: a row stays so until it is
/// handed on again.
///
/// CONTEXT:
/// - Waits: for the display's next frame, where the board streams one,
///   for a link to come up where the mode changes, and while another task
///   holds the board's lock.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: takes the board's lock around the checks, the driver's show
///   and the marks on the board's buffers, so two shows of one board
///   follow each other, and inside it the board's compose lock, so
///   nothing is handed on and no pointer moved between the old picture
///   and the new. No spinlock may be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bands are read, not kept: the library keeps its own copy. The
/// buffers stay the caller's.
///
/// NOTES:
/// What is drawn into any shown buffer is handed on by `RefreshRect` as
/// for one shown alone: the library knows which of its rows are on the
/// glass.
///
/// How the bands reach the glass is the board's: a display that reads
/// buffers itself reads as many bands as it can, and one with a picture
/// of its own is delivered the picture the library composes of them. A
/// board that has both ways reads the buffers itself for as long as
/// nothing lies over the picture - no more bands than it reads, none
/// the library scales, no overlay, no pointer the library lays.
///
/// A band of another size is scaled by the library where it composes
/// the board's picture, and read as it is by a display whose planes
/// scale (`RTGBF_SCALES`). What is written into such a buffer is handed
/// on as into any other, and reaches the glass scaled.
///
/// BUGS:
/// The DSI boards' driver keeps the bands it was handed when it answers
/// an error - no memory for the stream's chain, a flip that did not land -
/// and reads them when the pointer next moves or is first laid.
///
/// SEE ALSO:
/// `ShowBitMap`, `BoardDisplayBitMap`, `BestBoardMode`, `RefreshRect`
///
/// EXAMPLES:
/// ```zig
/// // The front screen pulled down 120 lines, the one behind above it.
/// const bands = [_]rtg.RtgBand{
///     .{ .bitmap = behind, .line = 0, .origin = 0 },
///     .{ .bitmap = front, .line = 120, .origin = 120 },
/// };
/// _ = rb.ShowBoard(board, 0, &bands, bands.len);
/// ```
pub fn ShowBoard(rb: *RtgBase, board: *rtg.RtgBoard, mode_id: u32, bands: ?[*]const rtg.RtgBand, count: u32) i32 {
    if (count > rtg.RTG_MAX_BANDS) return err.RTGERR_BAD_ARG;
    const shown: []const rtg.RtgBand = if (bands) |given| given[0..count] else &.{};
    if (shown.len != count) return err.RTGERR_BAD_ARG;
    // The mode, the bands and the marks on the board's buffers are one
    // step: no buffer is freed, and no other picture asked for, in
    // between.
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    var wanted: ?*modes.Record = null;
    if (mode_id != 0) wanted = modes.byId(board, mode_id) orelse return err.RTGERR_BAD_MODE;
    const code = _display.show(rb, board, wanted, shown);
    // The first picture is what the backlight is lit with.
    if (code == err.RTGERR_OK) _display.light(rb, board);
    return code;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "the mode and the bands as one step; a buffer lives through a mode change" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeDisplay(rb, 16, 16);
    try testing.expectEqual(@as(u32, 2), fixture.addMode(rb, board, 32, 8));
    const glass = fixture.fake.instanceOf(board);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    const showing = rtg.bitmaps.RTGBMF_SHOWING;
    const changed = rtg.boards.RTGSHOW_MODE_CHANGED;
    // A picture this board is shown is one its display reads itself.
    const direct = rtg.boards.RTGSHOW_DIRECT;
    // Buffers are the board's, in a mode or not.
    const square = fixture.base(rb).AllocBitMap(board, 16, 16, format, displayable).?;
    const wide = fixture.base(rb).AllocBitMap(board, 32, 8, format, displayable).?;
    const square_pixels = square.pixels.?;
    const free_before = fixture.freeOf(rb, board);

    // The first show of a board in no mode puts it in its default: one
    // call of the driver's, with the mode and the picture.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, square));
    try testing.expectEqual(@as(u32, 1), fk.log.shown);
    try testing.expectEqual(changed | direct, fk.log.last_flags);
    try testing.expectEqual(@as(u32, 1), fk.log.last_mode.id);
    try testing.expectEqual(@as(u32, 1), fixture.infoOf(rb, board).mode_id);

    // Another mode and what is shown in it: one step, one call.
    const in_wide = [_]rtg.RtgBand{.{ .bitmap = wide }};
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBoard(board, 2, &in_wide, in_wide.len));
    try testing.expectEqual(@as(u32, 2), fk.log.shown);
    try testing.expectEqual(changed | direct, fk.log.last_flags);
    try testing.expectEqual(@as(u32, 2), fk.log.last_mode.id);
    try testing.expectEqual(@as(u32, 32), fk.log.last_timings.h_active);
    try testing.expectEqual(wide, fk.log.last_show_bitmap.?);
    try testing.expectEqual(@as(u32, 2), glass.mode_id);
    var info = fixture.infoOf(rb, board);
    try testing.expectEqual(@as(u32, 2), info.mode_id);
    try testing.expectEqual(@as(u32, 32), info.width);
    try testing.expectEqual(@as(u32, 8), info.height);
    try testing.expectEqual(wide.pitch, info.pitch);
    try testing.expect(wide.flags & showing != 0);
    try testing.expect(square.flags & showing == 0);
    try testing.expectEqual(wide, fixture.base(rb).BoardDisplayBitMap(board).?);
    // The buffer of the other mode was not touched: its memory is its
    // own, and none was given back.
    try testing.expectEqual(square_pixels, square.pixels.?);
    try testing.expectEqual(free_before, fixture.freeOf(rb, board));
    // It is no picture of this mode, and the driver is not asked.
    try testing.expectEqual(rtg.errors.RTGERR_NOT_DISPLAYABLE, fixture.base(rb).ShowBitMap(board, square));
    try testing.expectEqual(@as(u32, 2), fk.log.shown);

    // Shown again in the mode of its size.
    const in_square = [_]rtg.RtgBand{.{ .bitmap = square }};
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBoard(board, 1, &in_square, in_square.len));
    try testing.expect(square.flags & showing != 0);
    try testing.expect(wide.flags & showing == 0);
    try testing.expectEqual(@as(u32, 16), fixture.infoOf(rb, board).width);
    // The mode it is in, named or kept, is no mode set anew.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBoard(board, 1, &in_square, in_square.len));
    try testing.expectEqual(direct, fk.log.last_flags);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBoard(board, 0, &in_square, in_square.len));
    try testing.expectEqual(direct, fk.log.last_flags);

    // A mode with nothing shown in it.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBoard(board, 2, null, 0));
    try testing.expectEqual(changed, fk.log.last_flags);
    try testing.expectEqual(@as(u32, 0), fk.log.band_count);
    try testing.expect(fixture.base(rb).BoardDisplayBitMap(board) == null);
    info = fixture.infoOf(rb, board);
    try testing.expectEqual(@as(u32, 2), info.mode_id);
    try testing.expectEqual(@as(u32, 0), info.flags & rtg.boards.RTGBF_SHOWING);

    // A number the board has no mode of, and more bands than a display
    // shows: refused before anything is asked.
    const shown = fk.log.shown;
    try testing.expectEqual(rtg.errors.RTGERR_BAD_MODE, fixture.base(rb).ShowBoard(board, 9, null, 0));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).ShowBoard(board, 0, &in_wide, rtg.RTG_MAX_BANDS + 1));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).ShowBoard(board, 0, null, 1));
    try testing.expectEqual(shown, fk.log.shown);

    fixture.base(rb).FreeBitMap(wide);
    fixture.base(rb).FreeBitMap(square);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}

test "another mode refused leaves the mode and what was shown; where that is gone too, the board is in none" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeDisplay(rb, 16, 16);
    _ = fixture.addMode(rb, board, 32, 8);
    const glass = fixture.fake.instanceOf(board);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    const showing = rtg.bitmaps.RTGBMF_SHOWING;
    const square = fixture.base(rb).AllocBitMap(board, 16, 16, format, displayable).?;
    const wide = fixture.base(rb).AllocBitMap(board, 32, 8, format, displayable).?;
    const in_wide = [_]rtg.RtgBand{.{ .bitmap = wide }};

    // A board in no mode whose first show is refused stays in none.
    fk.show_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, fixture.base(rb).ShowBitMap(board, square));
    try testing.expectEqual(@as(u32, 1), fk.log.shown);
    try testing.expectEqual(@as(u32, 0), fixture.infoOf(rb, board).mode_id);
    try testing.expect(square.flags & showing == 0);

    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, square));
    const swaps = fixture.swapsOf(rb, board);
    const changes = fixture.infoOf(rb, board).changes;
    const shown = fk.log.shown;

    // Another mode the driver refuses: it shows nothing then, and is
    // asked for what was shown before, in the mode before. Neither side
    // has moved when the call comes back.
    fk.show_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, fixture.base(rb).ShowBoard(board, 2, &in_wide, in_wide.len));
    try testing.expectEqual(shown + 2, fk.log.shown);
    try testing.expectEqual(@as(u32, 1), fk.log.last_mode.id);
    try testing.expectEqual(square, fk.log.last_show_bitmap.?);
    try testing.expectEqual(@as(u32, 1), glass.mode_id);
    try testing.expectEqual(@as(u32, 1), glass.showing_count);
    try testing.expectEqual(square, glass.showing[0].bitmap);
    var info = fixture.infoOf(rb, board);
    try testing.expectEqual(@as(u32, 1), info.mode_id);
    try testing.expectEqual(@as(u32, 16), info.width);
    try testing.expectEqual(changes, info.changes);
    try testing.expectEqual(square, fixture.base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(square.flags & showing != 0);
    try testing.expect(wide.flags & showing == 0);
    try testing.expectEqual(swaps, fixture.swapsOf(rb, board));
    // The buffer refused can go, the one shown cannot.
    fixture.base(rb).FreeBitMap(square);
    try testing.expectEqual(square, fixture.base(rb).BoardDisplayBitMap(board).?);

    // Where the driver cannot show what was shown either, the board is in
    // no mode and shows nothing, on both sides, and says so.
    fk.show_answer = rtg.errors.RTGERR_NO_MEMORY;
    fk.show_refusals = 2;
    try testing.expectEqual(rtg.errors.RTGERR_NO_MEMORY, fixture.base(rb).ShowBoard(board, 2, &in_wide, in_wide.len));
    try testing.expectEqual(@as(u32, 0), glass.showing_count);
    info = fixture.infoOf(rb, board);
    try testing.expectEqual(@as(u32, 0), info.mode_id);
    try testing.expectEqual(@as(u32, 0), info.flags & (rtg.boards.RTGBF_MODE_SET | rtg.boards.RTGBF_SHOWING));
    try testing.expectEqual(changes + 1, info.changes);
    try testing.expect(fixture.base(rb).BoardDisplayBitMap(board) == null);
    try testing.expect(square.flags & showing == 0);
    var found: [4]rtg.RtgMode = undefined;
    _ = fixture.modesOf4(rb, board, &found);
    try testing.expectEqual(@as(u32, 0), (found[0].flags | found[1].flags) & rtg.modes.RTGMF_CURRENT);

    // The next show puts it in a mode again.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBoard(board, 2, &in_wide, in_wide.len));
    try testing.expectEqual(rtg.boards.RTGSHOW_MODE_CHANGED | rtg.boards.RTGSHOW_DIRECT, fk.log.last_flags);
    try testing.expectEqual(@as(u32, 2), fixture.infoOf(rb, board).mode_id);

    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, null));
    fixture.base(rb).FreeBitMap(wide);
    fixture.base(rb).FreeBitMap(square);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}

test "showing buffers in bands, and what may not be shown so" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeDisplay(rb, 16, 16);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);

    const back = fixture.base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const front = fixture.base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const hidden = fixture.base(rb).AllocBitMap(board, 16, 16, format, 0).?;
    const small = fixture.base(rb).AllocBitMap(board, 16, 8, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;

    // The back buffer from the top, the front one from line 6 on, its own
    // first row there.
    const two = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = front, .line = 6, .origin = 6 } };
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBoard(board, 0, &two, two.len));
    try testing.expectEqual(@as(u32, 2), fk.log.band_count);
    try testing.expectEqual(@as(u32, 6), fk.log.bands[1].line);
    try testing.expectEqual(front, fixture.base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(back.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);
    try testing.expect(front.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);

    // Lines out of order, a first band below the top, a buffer that
    // cannot be shown, one that is not the mode's size.
    const unordered = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = front, .line = 6 }, .{ .bitmap = back, .line = 4 } };
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).ShowBoard(board, 0, &unordered, unordered.len));
    const low = [_]rtg.RtgBand{.{ .bitmap = back, .line = 2 }};
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).ShowBoard(board, 0, &low, low.len));
    const unseen = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = hidden, .line = 8 } };
    try testing.expectEqual(rtg.errors.RTGERR_NOT_DISPLAYABLE, fixture.base(rb).ShowBoard(board, 0, &unseen, unseen.len));
    const short = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = small, .line = 4 } };
    try testing.expectEqual(rtg.errors.RTGERR_NOT_DISPLAYABLE, fixture.base(rb).ShowBoard(board, 0, &short, short.len));
    try testing.expectEqual(@as(u32, 1), fk.log.shown);
    // One row repeated over a band; a buffer of no rows refused for it.
    const row = fixture.base(rb).AllocBitMap(board, 16, 1, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const repeated = [_]rtg.RtgBand{ .{ .bitmap = row, .flags = rtg.RTGBANDF_REPEAT }, .{ .bitmap = front, .line = 6, .origin = 6 } };
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBoard(board, 0, &repeated, repeated.len));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBoard(board, 0, &two, two.len));
    fixture.base(rb).FreeBitMap(row);
    try testing.expectEqual(@as(u32, 3), fk.log.shown);

    // One buffer again: the other is no longer read. No bands at all
    // show nothing.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, back));
    try testing.expect(front.flags & rtg.bitmaps.RTGBMF_SHOWING == 0);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBoard(board, 0, null, 0));
    try testing.expect(fixture.base(rb).BoardDisplayBitMap(board) == null);
    try testing.expect(back.flags & rtg.bitmaps.RTGBMF_SHOWING == 0);

    fixture.base(rb).FreeBitMap(small);
    fixture.base(rb).FreeBitMap(hidden);
    fixture.base(rb).FreeBitMap(front);
    fixture.base(rb).FreeBitMap(back);
    fixture.driverBase(rb).DeleteBoard(board);

    // A board that shows one whole buffer takes no bands, and says so:
    // one buffer from its own top is what ShowBitMap shows.
    fk.without_engine = true;
    const plain = try fixture.makeDisplay(rb, 16, 16);
    try testing.expectEqual(@as(u32, 0), fixture.infoOf(rb, plain).caps & rtg.boards.RTGBC_BANDS);
    const one = fixture.base(rb).AllocBitMap(plain, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const another = fixture.base(rb).AllocBitMap(plain, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const banded = [_]rtg.RtgBand{ .{ .bitmap = one }, .{ .bitmap = another, .line = 6, .origin = 6 } };
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, fixture.base(rb).ShowBoard(plain, 0, &banded, banded.len));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBoard(plain, 0, &banded, 1));
    try testing.expectEqual(one, fixture.base(rb).BoardDisplayBitMap(plain).?);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(plain, null));
    fixture.base(rb).FreeBitMap(another);
    fixture.base(rb).FreeBitMap(one);
    fixture.driverBase(rb).DeleteBoard(plain);
    try fixture.tearDown(rb);
}

test "bands that fail change nothing: what was shown stays, in the library and on the board" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeDisplay(rb, 16, 16);
    const glass = fixture.fake.instanceOf(board);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const showing = rtg.bitmaps.RTGBMF_SHOWING;
    const back = fixture.base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const front = fixture.base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const third = fixture.base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const two = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = front, .line = 6, .origin = 6 } };

    // One buffer up, then bands the board refuses: the one buffer stays,
    // and no picture is counted.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, back));
    const swaps = fixture.swapsOf(rb, board);
    fk.show_answer = rtg.errors.RTGERR_NO_MEMORY;
    try testing.expectEqual(rtg.errors.RTGERR_NO_MEMORY, fixture.base(rb).ShowBoard(board, 0, &two, two.len));
    try testing.expectEqual(swaps, fixture.swapsOf(rb, board));
    try testing.expectEqual(@as(u32, 2), fk.log.band_count); // it was asked
    try testing.expectEqual(back, fixture.base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(back.flags & showing != 0);
    try testing.expect(front.flags & showing == 0);
    try testing.expectEqual(@as(u32, 1), glass.showing_count);
    try testing.expectEqual(back, glass.showing[0].bitmap);

    // The same bands again, and they are up on both sides: a picture.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBoard(board, 0, &two, two.len));
    try testing.expectEqual(swaps + 1, fixture.swapsOf(rb, board));
    try testing.expectEqual(front, fixture.base(rb).BoardDisplayBitMap(board).?);
    try testing.expectEqual(@as(u32, 2), glass.showing_count);
    try testing.expectEqual(@as(u32, 6), glass.showing[1].line);

    // A buffer refused over bands: the bands stay, and the buffer can go.
    fk.show_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, fixture.base(rb).ShowBitMap(board, third));
    try testing.expectEqual(front, fixture.base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(back.flags & showing != 0 and front.flags & showing != 0);
    try testing.expect(third.flags & showing == 0);
    try testing.expectEqual(@as(u32, 2), glass.showing_count);
    fixture.base(rb).FreeBitMap(third);

    // One of the bands' own buffers refused alone: it is still up in its
    // band, so it stays marked.
    fk.show_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, fixture.base(rb).ShowBitMap(board, front));
    try testing.expect(front.flags & showing != 0);
    try testing.expectEqual(@as(u32, 2), glass.showing_count);

    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, null));
    fixture.base(rb).FreeBitMap(front);
    fixture.base(rb).FreeBitMap(back);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}
