// SPDX-License-Identifier: MPL-2.0
//! A drag: the picture a program drags across the screen, laid by the
//! board over its picture as the pointer is - rtg.library's overlay - so
//! nothing that draws has to know about it, and nothing is locked.
//!
//! `BeginDrag` hands the picture to the board of the window's screen,
//! where it follows the pointer by itself: the pointer's moves already
//! go to the board, and the board takes the overlay with them. `EndDrag`
//! takes it away again - after flying it back to where the drag began
//! when the program asks - and says which window is under the pointer.
//!
//! One drag at a time, the dragging window's; a window closed while it
//! drags ends its drag. Everything here runs under the screen semaphore.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;

/// intuition.library's drag, in its base: the window dragging, the board
/// the picture is on, and where on the display the drag began.
pub const State = extern struct {
    window: ?*Window = null,
    board: ?*rtg.RtgBoard = null,
    start_x: i32 = 0,
    start_y: i32 = 0,
};

/// The picture taken off the board and the drag forgotten. Under the
/// screen semaphore.
pub fn stop(ib: *IntuitionBase) void {
    const st = &ib.drag;
    if (st.board) |board| {
        if (ib.rtg_base) |rb| _ = rb.SetBoardOverlay(board, null, 0, 0);
    }
    st.* = .{};
}

/// A window is closing: its drag, if it has one, ends.
pub fn forget(ib: *IntuitionBase, w: *Window) void {
    if (ib.drag.window == w) stop(ib);
}
