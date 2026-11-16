// SPDX-License-Identifier: MPL-2.0
//! SetBoardMode: Put the board in the mode of that number, or in its
//! default for 0.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const bitmaps = @import("../bitmap/_bitmap.zig");
const memory_mod = @import("../memory/_memory.zig");
const modes = @import("../mode/_mode.zig");
const err = rtg.errors;
const privateOf = _board.privateOf;
const _board = @import("_board.zig");

/// Puts a board in a mode.
///
/// SYNOPSIS:
/// ```zig
/// fn SetBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, mode_id: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -80.
///
/// INPUTS:
/// - `board` - the board.
/// - `mode_id` - the number of one of its modes, as `FindBoardMode`,
///   `BestBoardMode` and `GetBoardModes` answer it, or 0 for its default.
///
/// RESULT:
/// `RTGERR_OK`, or: `RTGERR_NOT_SUPPORTED` for a board with no modes to
/// set, `RTGERR_NO_DISPLAY` on a board whose device has gone,
/// `RTGERR_BAD_MODE` for a number the board has no mode of, and with no
/// default, `RTGERR_IN_USE` while a buffer that is not `RTGBMF_VOLATILE`
/// is alive, or what the driver answered.
///
/// BEHAVIOR:
/// The board stops showing what it was showing, and every volatile buffer
/// loses its memory but keeps its handle. A buffer that has not agreed to
/// that keeps the board in the mode it is in: the new mode may be smaller,
/// and re-homing it would move its pixels under whoever draws into it. The
/// driver is handed the mode and its timings. The display memory is laid
/// out afresh for the new mode, and the board's information follows it:
/// its size, format and row length, its pixel clock and refresh, and the
/// mode's number.
///
/// CONTEXT:
/// - Waits: if the driver does, and while another task holds the board's
///   lock.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: takes the board's lock around all of it - the buffers, the
///   driver's mode, the display memory. No spinlock may be held: a driver
///   may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The display memory of volatile buffers is gone; their handles stay
/// the caller's.
///
/// BUGS:
/// The answer of taking the picture off the display is not looked at: a
/// board whose driver refuses to show nothing has its volatile buffers
/// emptied and its mode set under the picture it still shows.
///
/// SEE ALSO:
/// `FindBoardMode`, `BestBoardMode`, `GetBoardInfo`, `AllocBitMap`
///
/// EXAMPLES:
/// ```zig
/// if (rb.SetBoardMode(board, 0) != rtg.errors.RTGERR_OK) return error.NoMode;
/// ```
pub fn SetBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, mode_id: u32) i32 {
    const rtg_lib = rb.iface();
    const sys = rb.sys_base;
    const private = privateOf(board);
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const set = ops.set_mode orelse return err.RTGERR_NOT_SUPPORTED;
    // The buffers looked at, the picture taken down, the driver's mode and
    // the display memory laid out afresh are one step: no buffer is made
    // and nothing shown in between.
    _board.obtain(rb, board);
    defer _board.release(rb, board);
    // A board whose device has gone is put in no mode any more.
    if (_board.dark(board)) return err.RTGERR_NO_DISPLAY;
    const wanted = (if (mode_id == 0) modes.defaultOf(board) else modes.byId(board, mode_id)) orelse return err.RTGERR_BAD_MODE;

    // A buffer that has not agreed to lose its memory keeps the board in
    // the mode it is in: the new mode may be smaller, and a buffer that
    // was quietly re-homed would be a buffer whose pixels moved under
    // whoever was drawing into it.
    if (bitmaps.anyFixed(board)) return err.RTGERR_IN_USE;
    if (board.showing != null) _ = rtg_lib.ShowBitMap(board, null, 0, 0);
    bitmaps.emptyVolatile(rb, board);

    const code = set(board, &wanted.mode, &wanted.timings);
    if (code != err.RTGERR_OK) return code;

    if (private.mode) |before| before.mode.flags &= ~rtg.modes.RTGMF_CURRENT;
    wanted.mode.flags |= rtg.modes.RTGMF_CURRENT;
    private.mode = wanted;

    // The driver may have replaced the memory; what was cut out of the old
    // one has gone with it, and a row is as long as the new one makes it.
    private.arena.deinit(sys);
    if (board.region.flags & rtg.boards.RTGRF_SYSTEM_MEMORY != 0) {
        private.arena.initSystem(sys, board.region.size, board.region.alignment, memory_mod.attributesOf(board.region.flags));
    } else {
        private.arena.init(sys, @intFromPtr(board.region.base), board.region.size, board.region.alignment);
    }
    board.region.alignment = private.arena.alignment;
    board.info.memory_total = private.arena.free_bytes;
    modes.setPitches(rb, board);

    const mode = &wanted.mode;
    board.info.mode_id = mode.id;
    board.info.width = mode.width;
    board.info.height = mode.height;
    board.info.format = mode.format;
    board.info.pitch = mode.pitch;
    board.info.flags |= rtg.boards.RTGBF_MODE_SET;
    board.info.pixel_clock_hz = mode.pixel_clock_hz;
    board.info.refresh_mhz = mode.refresh_mhz;
    // The board is in another mode: whoever asked is told.
    _board.changed(rb, board);
    return err.RTGERR_OK;
}
