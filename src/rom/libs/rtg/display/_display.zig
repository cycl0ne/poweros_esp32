// SPDX-License-Identifier: MPL-2.0
//! What a board shows: the mode it is in and the bands of buffers in it,
//! as one step.
//!
//! `ShowBoard` and `ShowBitMap` come here (`show`), with the board's
//! lock held. The bands are checked against the mode they are to be
//! shown in, the driver's one op is called with the mode, its timings and
//! the bands (`RtgShow`), and once it has answered RTGERR_OK - and nowhere
//! before - the library takes the step as made: the board's mode and
//! what it says of it, its buffers marked as the display reads them, and
//! its own copy of the bands, which is what is shown again when a monitor
//! comes (`again`).
//!
//! **A show that fails changes nothing.** In the mode the board is in,
//! that is the driver's to keep: it reads what it read. With another mode
//! the driver is handed the mode and the bands together, and where it
//! then answers an error it shows nothing; the library has it show what
//! was shown before, in the mode before, and only where that fails too is
//! the board left in no mode, showing nothing - which is then what the
//! library says of it.
//!
//! A buffer is not touched by a mode change: it keeps its memory, and is
//! shown again in the mode of its size.
//!
//! A show also says how the picture reaches the glass
//! (`compose/_compose.zig`): the display reads the bands itself
//! (`RTGSHOW_DIRECT`) where the board is plain - no more bands than it
//! reads, nothing of the library's over them - and else shows its own
//! picture, which its driver fetches from the library while it is asked.
//! So the bands are put in place before the driver is asked, under the
//! board's compose lock, and put back where it refuses.
//!
//! On a board that is flipped between frames (`compose/_flip.zig`) the
//! picture is the library's to make as well: with another mode the whole
//! picture is made in the first of the mode's frames, which the driver's
//! op is handed to start the display on; in the mode the board is in,
//! the driver's op is asked and then the picture made and flipped to. A
//! flip the driver refuses is the show's answer, and what was in place
//! is put back.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const err = rtg.errors;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const modes = @import("../mode/_mode.zig");
const composer = @import("../compose/_compose.zig");
const flips = @import("../compose/_flip.zig");

/// The board's buffers marked as the display now shows them: the bands'
/// marked RTGBMF_SHOWING - so none of them can be freed - and every other
/// buffer of the board not; the last band's, which covers the display's
/// bottom, is what BoardDisplayBitMap answers. The bands themselves are
/// in place already (`composer.place`). A change of picture is counted.
///
/// INPUTS:
/// - `board` - the board.
/// - `bands` - what the display now shows, none for nothing shown.
fn keep(board: *rtg.RtgBoard, bands: []const rtg.RtgBand) void {
    const private = boards.privateOf(board);
    var node = board.bitmaps.head;
    while (node) |n| : (node = n.succ) {
        if (n.succ == null) break;
        const bm: *rtg.RtgBitMap = @fieldParentPtr("node", n);
        bm.flags &= ~rtg.bitmaps.RTGBMF_SHOWING;
    }
    for (bands) |band| band.bitmap.flags |= rtg.bitmaps.RTGBMF_SHOWING;
    if (bands.len != 0) {
        board.showing = bands[bands.len - 1].bitmap;
        board.info.flags |= rtg.boards.RTGBF_SHOWING;
        private.buffer_swaps +%= 1;
    } else {
        board.showing = null;
        board.info.flags &= ~rtg.boards.RTGBF_SHOWING;
    }
}

/// The board is in a mode from now on: its info follows it, and where its
/// buffers come from system memory, what they may hold together is what
/// its driver said for the mode.
fn enter(board: *rtg.RtgBoard, record: *modes.Record) void {
    const private = boards.privateOf(board);
    if (private.mode) |before| before.mode.flags &= ~rtg.modes.RTGMF_CURRENT;
    record.mode.flags |= rtg.modes.RTGMF_CURRENT;
    private.mode = record;
    if (private.arena.system) {
        private.arena.setLimit(board.region.size);
        board.info.memory_total = private.arena.size;
    }
    const mode = &record.mode;
    board.info.mode_id = mode.id;
    board.info.width = mode.width;
    board.info.height = mode.height;
    board.info.format = mode.format;
    board.info.pitch = mode.pitch;
    board.info.pixel_clock_hz = mode.pixel_clock_hz;
    board.info.refresh_mhz = mode.refresh_mhz;
    board.info.flags |= rtg.boards.RTGBF_MODE_SET;
}

/// The board is in no mode, and shows nothing.
fn leave(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const private = boards.privateOf(board);
    composer.empty(rb, board);
    keep(board, &.{});
    if (private.mode) |before| before.mode.flags &= ~rtg.modes.RTGMF_CURRENT;
    private.mode = null;
    board.info.mode_id = 0;
    board.info.flags &= ~@as(u32, rtg.boards.RTGBF_MODE_SET);
}

/// Whether bands can be shown in a mode: RTGERR_OK, or why not.
fn check(board: *rtg.RtgBoard, mode: *const rtg.RtgMode, bands: []const rtg.RtgBand) i32 {
    if (bands.len > rtg.RTG_MAX_BANDS) return err.RTGERR_BAD_ARG;
    for (bands, 0..) |band, i| {
        const bm = band.bitmap;
        if (bm.board != @as(?*anyopaque, @ptrCast(board))) return err.RTGERR_BAD_ARG;
        if (bm.flags & rtg.bitmaps.RTGBMF_DISPLAYABLE == 0) return err.RTGERR_NOT_DISPLAYABLE;
        if (bm.pixels == null) return err.RTGERR_BAD_ARG;
        if (bm.format != mode.format) return err.RTGERR_BAD_FORMAT;
        // A buffer of the mode: its width, and rows as far apart as the
        // mode's are.
        if (bm.width != mode.width or bm.pitch != mode.pitch) return err.RTGERR_NOT_DISPLAYABLE;
        const repeat = band.flags & rtg.RTGBANDF_REPEAT != 0;
        if (if (repeat) bm.height == 0 else bm.height != mode.height) return err.RTGERR_NOT_DISPLAYABLE;
        if (i == 0 and band.line != 0) return err.RTGERR_BAD_ARG;
        if (i > 0 and band.line <= bands[i - 1].line) return err.RTGERR_BAD_ARG;
        if (band.line >= mode.height or band.origin > band.line) return err.RTGERR_BAD_ARG;
        // The band's last line shows a row the buffer has.
        const end = if (i + 1 < bands.len) bands[i + 1].line else mode.height;
        if (!repeat and end - band.origin > bm.height) return err.RTGERR_BAD_ARG;
    }
    // Several buffers, or one that is not shown whole from its first row,
    // are bands: a board shows them only where its driver said so.
    const whole = bands.len == 0 or (bands.len == 1 and bands[0].origin == 0 and bands[0].flags == 0);
    if (!whole and board.info.caps & rtg.boards.RTGBC_BANDS == 0) return err.RTGERR_NOT_SUPPORTED;
    return err.RTGERR_OK;
}

/// The driver's op, with a mode and bands, read the way the board's
/// compose state says: direct, or as the library's picture.
fn ask(board: *rtg.RtgBoard, record: *modes.Record, bands: []const rtg.RtgBand, flags: u32, frame: ?*rtg.RtgBitMap) i32 {
    const op = board.ops.?.show.?;
    const direct = bands.len != 0 and composer.stateOf(board).direct;
    return op(board, &.{
        .mode = &record.mode,
        .timings = &record.timings,
        .bands = if (bands.len != 0) bands.ptr else null,
        .count = @intCast(bands.len),
        .flags = flags | (if (direct) rtg.boards.RTGSHOW_DIRECT else 0),
        .frame = frame,
    });
}

/// The bands in place put on the glass: the driver asked, and on a
/// flipped board the picture made as well - in the mode's first frame,
/// which the driver is handed with a mode it is to be put in, else in
/// the frame the display is not reading, and flipped to.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its locks are held, and the bands are in
///   place.
/// - `record` - the mode they are shown in.
/// - `bands` - the bands.
/// - `flags` - `RTGSHOW_MODE_CHANGED`, or none.
/// - `old` - the bands shown before.
///
/// RESULT:
/// RTGERR_OK, or why the display reads what it read - or, with the mode
/// to be changed, nothing.
fn present(rb: *RtgBase, board: *rtg.RtgBoard, record: *modes.Record, bands: []const rtg.RtgBand, flags: u32, old: []const rtg.RtgBand) i32 {
    if (!flips.flipped(board)) return ask(board, record, bands, flags, null);
    if (flags & rtg.boards.RTGSHOW_MODE_CHANGED != 0) {
        var frame: ?*rtg.RtgBitMap = null;
        const made = flips.first(rb, board, &record.mode, &frame);
        if (made != err.RTGERR_OK) return made;
        const code = ask(board, record, bands, flags, frame);
        if (code == err.RTGERR_OK) flips.begun(rb, board);
        return code;
    }
    const code = ask(board, record, bands, flags, null);
    if (code != err.RTGERR_OK) return code;
    return flips.shown(rb, board, old);
}

/// Puts a board in a mode and shows bands in it, as one step.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its lock is held.
/// - `wanted` - the mode, or null for the one the board is in - its
///   default where it is in none.
/// - `bands` - what to show, from the top; none shows nothing.
///
/// RESULT:
/// RTGERR_OK, or why nothing changed - `ShowBoard`'s contract has them.
pub fn show(rb: *RtgBase, board: *rtg.RtgBoard, wanted: ?*modes.Record, bands: []const rtg.RtgBand) i32 {
    const private = boards.privateOf(board);
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    if (ops.show == null) return err.RTGERR_NOT_SUPPORTED;
    // A board whose device has gone shows nothing any more, and nothing
    // is what it shows already.
    if (boards.dark(board)) return if (bands.len == 0 and wanted == null) err.RTGERR_OK else err.RTGERR_NO_DISPLAY;
    const before = private.mode;
    const target = wanted orelse before orelse modes.defaultOf(board) orelse return err.RTGERR_NO_MODE;
    // A mode the board does not offer now - a monitor's that went - is
    // none to put it in.
    if (!target.offered) return err.RTGERR_BAD_MODE;
    const checked = check(board, &target.mode, bands);
    if (checked != err.RTGERR_OK) return checked;

    // What the picture is made of changes under the compose lock: nothing
    // is handed on and no pointer moved between the old and the new. On
    // a flipped board no picture is being made either.
    composer.obtainWhole(rb, board);
    defer composer.releaseWhole(rb, board);
    const direct = composer.plain(board, bands);
    // A picture the library composes is of whole bytes a pixel - and on
    // a flipped board every picture is the library's, black too.
    const composed = if (flips.flipped(board)) true else !direct and bands.len != 0;
    if (composed and !composer.takes(rb, target.mode.format)) return err.RTGERR_BAD_FORMAT;
    // In place while the driver is asked: the picture is made of them.
    const kept = composer.place(rb, board, &target.mode, bands, direct);
    const old = kept.bands[0..kept.count];

    if (target == before) {
        // What it shows changes, and the driver keeps what was on any
        // answer but RTGERR_OK.
        const code = present(rb, board, target, bands, 0, old);
        if (code != err.RTGERR_OK) {
            composer.putBack(rb, board, &kept);
            return code;
        }
        keep(board, bands);
        return err.RTGERR_OK;
    }

    // Another mode, and the bands in it. A driver that answers an error
    // here shows nothing: what was shown is asked for again, in the mode
    // before - and where that is no longer to be had, the board is in no
    // mode and says so.
    const code = present(rb, board, target, bands, rtg.boards.RTGSHOW_MODE_CHANGED, old);
    if (code == err.RTGERR_OK) {
        enter(board, target);
        keep(board, bands);
        boards.changed(rb, board);
        return err.RTGERR_OK;
    }
    composer.putBack(rb, board, &kept);
    if (before) |old_mode| {
        const shown = private.bands[0..private.band_count];
        if (old_mode.offered and present(rb, board, old_mode, shown, rtg.boards.RTGSHOW_MODE_CHANGED, shown) == err.RTGERR_OK) return code;
        leave(rb, board);
        boards.changed(rb, board);
    }
    return code;
}

/// What a board shows, shown again in the mode it is in, for a monitor
/// that came: its driver brings the link up again, with the timings the
/// monitor gives the mode now. Where the driver cannot, the board is in
/// no mode and shows nothing.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board, in a mode it offers; its lock is held.
pub fn again(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const private = boards.privateOf(board);
    const current = private.mode orelse return;
    const ops = board.ops orelse return;
    if (ops.show == null) return;
    composer.obtainWhole(rb, board);
    defer composer.releaseWhole(rb, board);
    const shown = private.bands[0..private.band_count];
    if (present(rb, board, current, shown, rtg.boards.RTGSHOW_MODE_CHANGED, shown) == err.RTGERR_OK) {
        enter(board, current);
        return;
    }
    leave(rb, board);
}

/// What a board shows, shown the other way: its compose state says
/// whether the display reads the bands itself from now on or shows the
/// library's picture, and its driver is asked for that, in the mode the
/// board is in.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board, showing something; its locks are held, and its
///   compose state already says the new way.
///
/// RESULT:
/// What the driver answered: on anything but RTGERR_OK the display reads
/// what it read.
pub fn otherWay(rb: *RtgBase, board: *rtg.RtgBoard) i32 {
    const private = boards.privateOf(board);
    const current = private.mode orelse return err.RTGERR_NO_MODE;
    const shown = private.bands[0..private.band_count];
    return present(rb, board, current, shown, 0, shown);
}

/// A board made to show nothing and put in no mode: its monitor has not
/// got the mode it is in, or the board itself is going. Where its driver
/// will not show nothing, everything stays as it is: a buffer on the
/// glass is not let go.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its lock is held.
///
/// RESULT:
/// Whether the board shows nothing now.
pub fn clear(rb: *RtgBase, board: *rtg.RtgBoard) bool {
    const private = boards.privateOf(board);
    const current = private.mode orelse return private.band_count == 0;
    composer.obtainWhole(rb, board);
    defer composer.releaseWhole(rb, board);
    if (private.band_count != 0) {
        const ops = board.ops orelse return false;
        if (ops.show == null) return false;
        // Nothing in place while the driver is asked, and what was there
        // again where it will not.
        const kept = composer.place(rb, board, &current.mode, &.{}, composer.stateOf(board).direct);
        if (present(rb, board, current, &.{}, 0, kept.bands[0..kept.count]) != err.RTGERR_OK) {
            composer.putBack(rb, board, &kept);
            return false;
        }
    }
    leave(rb, board);
    return true;
}
