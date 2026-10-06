// SPDX-License-Identifier: MPL-2.0
//! SizeWindow: sizes a window.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;

/// Sizes a window.
///
/// SYNOPSIS:
/// ```zig
/// fn SizeWindow(ib: *IntuitionBase, window: *Window, dw: i32,
///     dh: i32) void
/// ```
///
/// SINCE: 0.5. LVO -148.
///
/// INPUTS:
/// - `window` - the window.
/// - `dw`, `dh` - how much wider and taller; negative is smaller.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// `ChangeWindowBox` at its place and a new size, kept within its limits.
/// **The window stays where it is**: it grows no further than its
/// screen's right and bottom edges, measured from its own left and top -
/// or, while windows may hang past those edges (`IPREFS_OffScreen`), no
/// larger than the screen. `ChangeWindowBox` given a size that does not
/// fit at the place it is given moves the window to make room; a size is
/// not a move.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and the layers' locks.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ChangeWindowBox`, `MoveWindow`
///
/// EXAMPLES:
/// ```zig
/// ib.SizeWindow(window, 20, 20);
/// ```
pub fn SizeWindow(ib: *IntuitionBase, window: *Window, dw: i32, dh: i32) void {
    const s = window.screen;
    const past_edges = ib.off_screen != 0;
    const width = if (past_edges) window.width + dw else @min(window.width + dw, s.width - window.left);
    const height = if (past_edges) window.height + dh else @min(window.height + dh, s.height - window.top);
    ib.iface().ChangeWindowBox(@ptrCast(window), window.left, window.top, width, height);
}
