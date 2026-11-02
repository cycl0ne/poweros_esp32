// SPDX-License-Identifier: MPL-2.0
//! WindowUnderPointer: the window the pointer stands over.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const lock = _window.lock;
const unlock = _window.unlock;
const _input = @import("../input/_input.zig");

/// The window the pointer stands over.
///
/// SYNOPSIS:
/// ```zig
/// fn WindowUnderPointer(ib: *IntuitionBase) ?*Window
/// ```
///
/// SINCE: 0.80. LVO -532.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The window, or null where there is none: over a screen's bar, over a
/// panel in front of the windows - a menu, a list a gadget popped up -
/// over the screen's ground, or while no screen is open.
///
/// BEHAVIOR:
/// The screen at the pointer's line of the display is taken, and on it
/// the frontmost window whose visible part is under the pointer: what a
/// press there would reach. A window covered at that point by another is
/// not it, and the border counts as the window.
///
/// CONTEXT:
/// - Waits: yes, for the screens' semaphore.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The window is its opener's. It stays open only while the caller holds
/// `LockIBase`: without it, the window may close the moment the answer is
/// given.
///
/// NOTES:
/// - The pointer has moved on by the time a program acts on the answer.
///   One that wants the window a particular event happened over asks
///   while it handles that event.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ActiveWindow`, `ActivateWindow`, `WindowToFront`, `LockIBase`
///
/// EXAMPLES:
/// ```zig
/// const held = ib.LockIBase(0);
/// defer ib.UnlockIBase(held);
/// if (ib.WindowUnderPointer()) |window| {
///     if (window != ib.ActiveWindow()) ib.ActivateWindow(window);
/// }
/// ```
pub fn WindowUnderPointer(ib: *IntuitionBase) ?*Window {
    lock(ib);
    defer unlock(ib);
    const screen = _input.screenUnder(ib) orelse return null;
    const place = _input.pointerOn(ib, screen);
    return _input.windowAt(ib, screen, place.x, place.y);
}
