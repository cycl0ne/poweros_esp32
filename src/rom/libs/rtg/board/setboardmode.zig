// SPDX-License-Identifier: MPL-2.0
//! SetBoardMode: Put the board in that mode, or in its default for
//! null.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;
const bitmaps = @import("../bitmap/_bitmap.zig");
const err = rtg.errors;
const privateOf = _board.privateOf;
const _board = @import("_board.zig");

/// Puts a board in a mode.
///
/// SYNOPSIS:
/// ```zig
/// fn SetBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, mode: ?*rtg.RtgMode) i32
/// ```
///
/// SINCE: 1.0. LVO -80.
///
/// INPUTS:
/// - `board` - the board.
/// - `mode` - one of its modes, or null for its default.
///
/// RESULT:
/// `RTGERR_OK`, or: `RTGERR_NOT_SUPPORTED` for a board with no modes to
/// set, `RTGERR_BAD_MODE` with no default, `RTGERR_IN_USE` while a buffer
/// that is not `RTGBMF_VOLATILE` is alive, or what the driver answered.
///
/// BEHAVIOR:
/// The board stops showing what it was showing, and every volatile buffer
/// loses its memory but keeps its handle. A buffer that has not agreed to
/// that keeps the board in the mode it is in: the new mode may be smaller,
/// and re-homing it would move its pixels under whoever draws into it. The
/// display memory is laid out afresh for the new mode, and the board's
/// information follows it.
///
/// CONTEXT:
/// - Waits: only if the driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Forbid: must not be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The display memory of volatile buffers is gone; their handles stay
/// the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindBoardMode`, `BoardMode`, `AllocBitMap`
///
/// EXAMPLES:
/// ```zig
/// if (rb.SetBoardMode(board, null) != rtg.errors.RTGERR_OK) return error.NoMode;
/// ```
pub fn SetBoardMode(rb: *RtgBase, board: *rtg.RtgBoard, mode: ?*rtg.RtgMode) i32 {
    const rtg_lib = rb.iface();
    const sys = rb.sys_base;
    const private = privateOf(board);
    const ops = board.ops orelse return err.RTGERR_NOT_SUPPORTED;
    const set = ops.set_mode orelse return err.RTGERR_NOT_SUPPORTED;
    const wanted = mode orelse rtg_lib.FindBoardMode(board, 0, 0, 0) orelse return err.RTGERR_BAD_MODE;

    // A buffer that has not agreed to lose its memory keeps the board in
    // the mode it is in: the new mode may be smaller, and a buffer that
    // was quietly re-homed would be a buffer whose pixels moved under
    // whoever was drawing into it.
    if (bitmaps.anyFixed(board)) return err.RTGERR_IN_USE;
    if (board.showing != null) _ = rtg_lib.ShowBitMap(board, null, 0, 0);
    bitmaps.emptyVolatile(rb, board);

    const code = set(board, wanted);
    if (code != err.RTGERR_OK) return code;

    var walk = rtg_lib.NextBoardMode(board, null);
    while (walk) |m| : (walk = rtg_lib.NextBoardMode(board, m)) {
        m.flags &= ~rtg.boards.RTGMF_CURRENT;
    }
    wanted.flags |= rtg.boards.RTGMF_CURRENT;
    private.mode = wanted;
    board.info.mode_id = wanted.id;
    board.info.width = wanted.width;
    board.info.height = wanted.height;
    board.info.format = wanted.format;
    board.info.flags |= rtg.boards.RTGBF_MODE_SET;
    if (wanted.pixel_clock_hz != 0) board.info.pixel_clock_hz = wanted.pixel_clock_hz;
    if (wanted.refresh_mhz != 0) board.info.refresh_mhz = wanted.refresh_mhz;

    // The driver may have replaced the memory; what was cut out of the old
    // one has gone with it.
    private.arena.deinit(sys);
    private.arena.init(sys, @intFromPtr(board.region.base), board.region.size, board.region.alignment);
    board.region.alignment = private.arena.alignment;
    board.info.memory_total = private.arena.free_bytes;
    board.info.pitch = if (wanted.pitch != 0)
        wanted.pitch
    else
        @truncate(private.arena.roundUp(rtg.bitmaps.formatRowBytes(wanted.format, wanted.width)));
    return err.RTGERR_OK;
}
