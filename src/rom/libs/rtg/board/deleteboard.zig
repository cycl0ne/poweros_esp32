// SPDX-License-Identifier: MPL-2.0
//! DeleteBoard: Stop a board and give everything back.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const err = rtg.errors;
const RtgBase = @import("../rtg.zig").RtgBase;
const bitmaps = @import("../bitmap/_bitmap.zig");
const privateOf = _board.privateOf;
const _board = @import("_board.zig");

/// Stops a board and gives back everything it held.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteBoard(rb: *RtgBase, board: ?*rtg.RtgBoard) void
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `board` - the board. Null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A board that still has an event server on it is refused, with
/// `RTGERR_IN_USE` in `RtgLastError`, and nothing of it is touched: the
/// server's node would be left linked into a list that is freed.
/// Otherwise it is taken off the display first, then every buffer it still has is
/// freed, the driver's `destroy` is called, and the board leaves the list.
/// The driver and a transport it used are one open less.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the board list, and if the
///   driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Forbid: must not be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The board, its buffers and its display memory are gone. Event servers
/// are the caller's, and are taken off with `RemRtgEventServer` first.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateBoardTagList`, `RemRtgEventServer`
///
/// EXAMPLES:
/// ```zig
/// rb.DeleteBoard(board);
/// ```
pub fn DeleteBoard(rb: *RtgBase, board: ?*rtg.RtgBoard) void {
    const rtg_lib = rb.iface();
    const gone = board orelse return;
    const sys = rb.sys_base;
    const private = privateOf(gone);

    // A server still on it is someone's node in a list about to be freed.
    for (&gone.event_lists) |*list| {
        if (list.first() != null) {
            rb.last_error = err.RTGERR_IN_USE;
            return;
        }
    }

    // Nothing is left looking at it, and nothing of it is left up.
    if (gone.showing != null) _ = rtg_lib.ShowBitMap(gone, null, 0, 0);
    bitmaps.freeAll(rb, gone);

    if (gone.ops) |ops| {
        if (ops.destroy) |destroy| destroy(gone);
    }

    sys.ObtainSemaphore(&rb.board_lock);
    sys.Remove(&gone.node);
    sys.ReleaseSemaphore(&rb.board_lock);

    private.arena.deinit(sys);
    if (gone.transport) |io| {
        if (io.open_cnt != 0) io.open_cnt -= 1;
    }
    if (gone.driver) |driver| {
        if (driver.open_cnt != 0) driver.open_cnt -= 1;
    }
    if (gone.instance) |instance| sys.FreeVec(instance);
    sys.FreeVec(private);
}
