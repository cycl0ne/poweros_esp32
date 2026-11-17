// SPDX-License-Identifier: MPL-2.0
//! SetBoardSettings: A board's line changed, and applied.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const boards = @import("../board/_board.zig");
const settings = @import("_settings.zig");

/// Makes a structure the board's settings line, and applies it.
///
/// SYNOPSIS:
/// ```zig
/// fn SetBoardSettings(rb: *RtgBase, board: *rtg.RtgBoard, line: *const rtg.RtgSettings) i32
/// ```
///
/// SINCE: 1.34. LVO -116.
///
/// INPUTS:
/// - `board` - the board.
/// - `line` - what the line says: the fields whose flags are set. Its
///   `RTGSET_MONITOR`, `maker`, `product` and `serial` are not read.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_BAD_ARG` for a brightness above 100, a mode of
/// no size, or timings without a clock, a size and a sync pulse each
/// way; `RTGERR_NO_MEMORY` without room for a new line. Nothing changes
/// on either.
///
/// BEHAVIOR:
/// The line is for the monitor on the board now: where that monitor
/// says who it is, the line names it and is passed over while another
/// is on the output; on a panel's board, and with nothing or a monitor
/// that says nothing on the connector, the line names none. It takes
/// the place of the line that was there for that monitor; lines for
/// other monitors of the output stay. A line whose flags are all clear
/// takes the line away.
///
/// Applied at once:
/// - `RTGSET_MODE`: the mode of that size - at that refresh to the
///   nearest Hertz, or with a refresh of 0 the one the board prefers of
///   that size - is the board's default, where the board has it:
///   `BestBoardMode` with everything left open answers it. The mode the
///   board is in stays; intuition.library puts a display in the mode
///   its line names when the display's first screen opens. Where the
///   board has not got the mode, the default is its own.
/// - `RTGSET_TIMINGS`: on a board whose monitor names no mode the board
///   can make, a mode of these timings is added and is the default.
/// - `RTGSET_MIRROR`: the picture is mirrored about the axes set, as
///   `MirrorBoard` does it.
/// - `RTGSET_BRIGHTNESS`: as `SetBoardBrightness` sets it.
/// - `RTGSET_RANGE`: the board's `color_range` is the line's, and a
///   board whose driver reads it (`RTGBC_COLOR_RANGE`) is shown again
///   with its link's colours in that range. Without the flag the range
///   is the monitor's own again.
/// - `RTGSET_FIRST`: the board is the first of the library's list,
///   `NextBoard(null)`, and no other output's line says so any more.
///   Without the flag it stands where it was made.
///
/// What a board cannot do - a mirror without the cap, a brightness with
/// no backlight to set - stays in the line and does nothing. The tasks
/// that asked are told where the board's modes or its place changed
/// (`AddRtgNotify`).
///
/// The change is in force and is not on the disk: `SaveBoardSettings`
/// writes it.
///
/// CONTEXT:
/// - Waits: where a driver waits for its display, and while another
///   task holds the board's lock.
/// - Interrupts: no.
/// - Locks: takes the board's lock and the settings' inside it, then
///   the board list's. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The line is copied; `line` is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetBoardSettings`, `SaveBoardSettings`, `MirrorBoard`,
/// `SetBoardBrightness`, `BestBoardMode`
///
/// EXAMPLES:
/// ```zig
/// // The board comes up in 1920x1080 from now on, and is kept so.
/// var line: rtg.RtgSettings = .{};
/// _ = rb.GetBoardSettings(board, &line, @sizeOf(rtg.RtgSettings));
/// line.flags |= rtg.RTGSET_MODE;
/// line.mode_width = 1920;
/// line.mode_height = 1080;
/// line.mode_refresh_mhz = 0;
/// if (rb.SetBoardSettings(board, &line) == rtg.errors.RTGERR_OK) {
///     _ = rb.SaveBoardSettings(rtg.RTG_SETTINGS_ENVARC);
/// }
/// ```
pub fn SetBoardSettings(rb: *RtgBase, board: *rtg.RtgBoard, line: *const rtg.RtgSettings) i32 {
    var kept = line.*;
    if (kept.flags & rtg.RTGSET_BRIGHTNESS != 0 and kept.brightness > 100) return err.RTGERR_BAD_ARG;
    if (kept.flags & rtg.RTGSET_MODE != 0 and (kept.mode_width == 0 or kept.mode_height == 0)) return err.RTGERR_BAD_ARG;
    if (kept.flags & rtg.RTGSET_TIMINGS != 0 and !settings.timingsMakeSense(&kept.timings)) return err.RTGERR_BAD_ARG;

    // For the monitor that is there, and the line put on the list, as one
    // step under the board's lock: a monitor that comes meanwhile finds
    // either the old line or the new.
    boards.obtain(rb, board);
    kept.flags &= ~@as(u32, rtg.RTGSET_MONITOR);
    kept.maker = @splat(0);
    kept.product = 0;
    kept.serial = 0;
    if (settings.identityOf(board)) |who| {
        kept.flags |= rtg.RTGSET_MONITOR;
        kept.maker = who.maker;
        kept.product = who.product;
        kept.serial = who.serial;
    }
    settings.obtain(rb);
    const name = settings.nameOf(board);
    const put = settings.put(rb, name, &kept);
    if (put and kept.flags & rtg.RTGSET_FIRST != 0) settings.onlyFirst(rb, name);
    settings.release(rb);
    boards.release(rb, board);
    if (!put) return err.RTGERR_NO_MEMORY;

    // One board is the first: the others' places are put right before
    // this one's.
    if (kept.flags & rtg.RTGSET_FIRST != 0) {
        var other = rb.iface().NextBoard(null);
        while (other) |one| {
            other = rb.iface().NextBoard(one);
            if (one != board) boards.setFirst(rb, one, false);
        }
    }
    settings.applyTo(rb, board);
    return err.RTGERR_OK;
}
