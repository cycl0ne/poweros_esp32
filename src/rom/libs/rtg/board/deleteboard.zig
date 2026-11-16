// SPDX-License-Identifier: MPL-2.0
//! DeleteBoard: Give a board back.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const bitmaps = @import("../bitmap/_bitmap.zig");
const modes = @import("../mode/_mode.zig");
const monitors = @import("../monitor/_monitor.zig");
const shows = @import("../display/_display.zig");
const frames = @import("../frame/_frame.zig");
const flips = @import("../compose/_flip.zig");
const privateOf = _board.privateOf;
const _board = @import("_board.zig");

/// Gives a board back: stops it and frees everything it held.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteBoard(rb: *RtgBase, board: ?*rtg.RtgBoard) void
/// ```
///
/// SINCE: 1.0. LVO -364.
///
/// INPUTS:
/// - `board` - the board, as `CreateBoard` answered it. Null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// A driver's call, for two cases. An `attach` that fails after it made a
/// board deletes it: the board has not joined the list, the driver has
/// given back what it took for it, and the handle and the instance are
/// freed - its `destroy` is not called. And a driver that is being removed
/// deletes its boards, which only a test's driver is: a program is never
/// handed a board that goes away.
///
/// A board on the list that a task still waits for a frame of
/// (`WaitVBlank`) is refused - it stays on the list, which is how a
/// caller sees it - and nothing of it is touched: the waiter would be
/// left linked into a list that is freed. So is one with a video layer
/// still open (`CloseVideoLayer` first). Otherwise it is taken off the display first, then every buffer
/// it still has is freed, the driver's `destroy` is called, and the board
/// leaves the list and its device. The driver is one board less.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the board list, and if the
///   driver does.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: no spinlock may be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The board, its buffers and its display memory are gone.
///
/// BUGS:
/// The answer of taking the board off the display is not looked at: one
/// whose driver refuses to show nothing has its buffers freed and its
/// driver's `destroy` called all the same.
///
/// SEE ALSO:
/// `CreateBoard`, `RemRtgDevice`, `RemRtgDriver`
///
/// EXAMPLES:
/// ```zig
/// rb.DeleteBoard(board);
/// ```
pub fn DeleteBoard(rb: *RtgBase, board: ?*rtg.RtgBoard) void {
    const gone = board orelse return;
    const sys = rb.sys_base;
    const private = privateOf(gone);

    // One its attach never finished: nothing was shown, nothing cut from
    // its display memory, and its driver has undone what it did.
    if (!private.listed) return _board.free(rb, gone);

    // A task that waits for a frame has its waiter on a list about to be
    // freed, and a video layer is someone's handle on a plane of it.
    if (frames.waiting(sys, &private.frames)) return;
    if (private.video_layers != 0) return;

    // Nothing is left looking at it, and nothing of it is left up: a
    // flipped board's task is stopped, and its frames go.
    _board.obtain(rb, gone);
    _ = shows.clear(rb, gone);
    _board.release(rb, gone);
    flips.stop(rb, gone);
    bitmaps.freeAll(rb, gone);

    if (gone.ops) |ops| {
        if (ops.destroy) |destroy| destroy(gone);
    }
    // The driver is gone, so nothing reads the pointer's image any more.
    if (gone.pointer) |image| sys.FreeVec(image);
    gone.pointer = null;
    if (gone.overlay) |image| sys.FreeVec(image);
    gone.overlay = null;

    sys.ObtainSemaphore(&rb.board_lock);
    sys.Remove(&gone.node);
    sys.ReleaseSemaphore(&rb.board_lock);
    // Off its device's list, unless the device went first.
    if (gone.device != null) sys.Remove(&private.device_link);

    private.arena.deinit(sys);
    modes.freeAll(rb, gone);
    monitors.free(rb, gone);
    if (gone.driver) |driver| {
        if (driver.boards != 0) driver.boards -= 1;
    }
    if (gone.instance) |instance| sys.FreeVec(instance);
    sys.FreeVec(private);
}
