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
/// `ChangeWindowBox` at its place and a new size, kept within its limits
/// and its screen.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and the layers' locks.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
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
    ib.iface().ChangeWindowBox(@ptrCast(window), window.left, window.top, window.width + dw, window.height + dh);
}
