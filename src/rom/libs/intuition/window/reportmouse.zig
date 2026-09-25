// SPDX-License-Identifier: MPL-2.0
//! ReportMouse: whether a window is told where the pointer goes.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const WF_REPORTMOUSE = _window.WF_REPORTMOUSE;
const lock = _window.lock;
const unlock = _window.unlock;

/// Turns the reports of the pointer's moves to a window on or off.
///
/// SYNOPSIS:
/// ```zig
/// fn ReportMouse(ib: *IntuitionBase, window: *Window, on: bool) void
/// ```
///
/// SINCE: 0.14. LVO -356.
///
/// INPUTS:
/// - `window` - the window.
/// - `on` - true to be told of the pointer's moves with no button held
///   while the window is active, false not to be.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// It is what `WA_ReportMouse` sets when the window opens. The moves come
/// as IDCMP_MOUSEMOVE messages, so the window's IDCMP must ask for them
/// too; how many may wait is `SetMouseQueue`'s.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// A program that follows the pointer only in some mode - a tool that
/// shows where it would draw - turns the reports on for that mode, and is
/// not woken by every move otherwise.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetMouseQueue`, `ModifyIDCMP`, `OpenWindowTagList` (`WA_ReportMouse`)
///
/// EXAMPLES:
/// ```zig
/// ib.ReportMouse(window, true); // the button went down: follow the drag
/// ```
pub fn ReportMouse(ib: *IntuitionBase, window: *Window, on: bool) void {
    lock(ib);
    defer unlock(ib);
    if (on) window.flags |= WF_REPORTMOUSE else window.flags &= ~WF_REPORTMOUSE;
}
