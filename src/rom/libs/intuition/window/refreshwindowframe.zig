// SPDX-License-Identifier: MPL-2.0
//! RefreshWindowFrame: draws a window's border again.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const drawBorder = _window.drawBorder;
const lock = _window.lock;
const unlock = _window.unlock;

/// Draws a window's border again.
///
/// SYNOPSIS:
/// ```zig
/// fn RefreshWindowFrame(ib: *IntuitionBase, window: *Window) void
/// ```
///
/// SINCE: 0.5. LVO -180.
///
/// INPUTS:
/// - `window` - the window.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The frame, the title bar and the gadget images, in the colours of
/// whether it is active - after a program has drawn over them.
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
/// `OpenWindowTagList`
///
/// EXAMPLES:
/// ```zig
/// ib.RefreshWindowFrame(window);
/// ```
pub fn RefreshWindowFrame(ib: *IntuitionBase, window: *Window) void {
    lock(ib);
    defer unlock(ib);
    drawBorder(ib, window);
}
