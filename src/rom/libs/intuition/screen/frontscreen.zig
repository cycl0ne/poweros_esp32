// SPDX-License-Identifier: MPL-2.0
//! FrontScreen: the screen in front of the others.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;
const frontmost = _screen.frontmost;
const lock = _screen.lock;
const unlock = _screen.unlock;

/// The screen in front of the others.
///
/// SYNOPSIS:
/// ```zig
/// fn FrontScreen(ib: *IntuitionBase) ?*Screen
/// ```
///
/// SINCE: 0.80. LVO -540.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The frontmost screen, or null while none is open.
///
/// BEHAVIOR:
/// It is the screen `ScreenToFront` last brought forward, the newest
/// screen opened without `SA_Behind`, or what was left in front when one
/// closed: the screen whose buffer its display shows from the top down,
/// and the one the menu button and a screen's keyboard commands reach.
/// With more than one display it is the front of the display that holds
/// it; the others' frontmost screens are reached through their windows
/// (`WA_Screen`).
///
/// CONTEXT:
/// - Waits: yes, for the screens' semaphore.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The screen is its opener's. It stays open only while the caller holds
/// `LockIBase`: without it, the screen may close the moment the answer is
/// given. A public screen is better held with `LockPubScreen`, which
/// keeps it open without holding the screens still.
///
/// NOTES:
/// - Cycling the screens is this screen sent to the back
///   (`ScreenToBack`), which brings the next one forward.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ScreenToFront`, `ScreenToBack`, `LockPubScreen`, `NextWindow`,
/// `LockIBase`
///
/// EXAMPLES:
/// ```zig
/// const held = ib.LockIBase(0);
/// defer ib.UnlockIBase(held);
/// if (ib.FrontScreen()) |screen| ib.ScreenToBack(screen);
/// ```
pub fn FrontScreen(ib: *IntuitionBase) ?*Screen {
    lock(ib);
    defer unlock(ib);
    return frontmost(ib);
}
