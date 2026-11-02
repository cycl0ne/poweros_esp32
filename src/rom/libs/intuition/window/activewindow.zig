// SPDX-License-Identifier: MPL-2.0
//! ActiveWindow: the window the keyboard reaches.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const lock = _window.lock;
const unlock = _window.unlock;

/// The window the keyboard reaches.
///
/// SYNOPSIS:
/// ```zig
/// fn ActiveWindow(ib: *IntuitionBase) ?*Window
/// ```
///
/// SINCE: 0.80. LVO -528.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The active window, or null while none is - no window has been
/// activated yet, or the one that was has closed.
///
/// BEHAVIOR:
/// One window at a time is active, on whichever screen: what a key typed
/// now would reach, drawn with its title bar in the active colours. It is
/// the window `ActivateWindow` last made active, or the one intuition
/// activated when a window was clicked, opened or closed.
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
/// - A program that acts on the window it is given keeps its number
///   (`WA_Number`) rather than the pointer, and finds it again with
///   `FindWindowNumber`: a pointer kept may by then be another window's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ActivateWindow`, `WindowUnderPointer`, `NextWindow`,
/// `FindWindowNumber`, `LockIBase`
///
/// EXAMPLES:
/// ```zig
/// const held = ib.LockIBase(0);
/// defer ib.UnlockIBase(held);
/// if (ib.ActiveWindow()) |window| ib.ZipWindow(window);
/// ```
pub fn ActiveWindow(ib: *IntuitionBase) ?*Window {
    lock(ib);
    defer unlock(ib);
    return ib.active_window;
}
