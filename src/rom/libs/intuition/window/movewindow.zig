// SPDX-License-Identifier: MPL-2.0
//! MoveWindow: moves a window.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;

/// Moves a window.
///
/// SYNOPSIS:
/// ```zig
/// fn MoveWindow(ib: *IntuitionBase, window: *Window, dx: i32,
///     dy: i32) void
/// ```
///
/// SINCE: 0.5. LVO -144.
///
/// INPUTS:
/// - `window` - the window.
/// - `dx`, `dy` - how far, right and down.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// `ChangeWindowBox` at its size and a new place, kept on the screen.
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
/// `ChangeWindowBox`, `SizeWindow`
///
/// EXAMPLES:
/// ```zig
/// ib.MoveWindow(window, 10, 0);
/// ```
pub fn MoveWindow(ib: *IntuitionBase, window: *Window, dx: i32, dy: i32) void {
    ib.iface().ChangeWindowBox(@ptrCast(window), window.left + dx, window.top + dy, window.width, window.height);
}
