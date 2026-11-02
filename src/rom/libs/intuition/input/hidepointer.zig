// SPDX-License-Identifier: MPL-2.0
//! HidePointer: the pointer kept from being shown at all.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const pointer = @import("pointer.zig");

/// The pointer kept from being shown at all, or shown again.
///
/// SYNOPSIS:
/// ```zig
/// fn HidePointer(ib: *IntuitionBase, hidden: bool) void
/// ```
///
/// SINCE: 0.80. LVO -544.
///
/// INPUTS:
/// - `hidden` - true for no pointer on the display, false to show it
///   again.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The pointer stops being laid over the picture, whatever window is
/// active and whatever picture that window asked for: the display is left
/// without one until it is shown again. The mouse still moves it, and a
/// press still reaches whatever the pointer stands over, so what the
/// machine does is unchanged - only the picture of it is not there.
///
/// The last call wins; it does not nest. Hidden with no mouse plugged in,
/// the pointer stays unseen when one is - showing it again is what brings
/// it back.
///
/// CONTEXT:
/// - Waits: yes, for the screens' semaphore.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands. Whoever hides the pointer shows it again: a
/// program that ends while it is hidden leaves the display without one.
///
/// NOTES:
/// - A window hides the pointer for itself with `SetWindowPointerA` and
///   `WA_HidePointer`, which is the active window's own business and goes
///   back to normal as soon as another window is active. This is for a
///   program that blanks the pointer across the machine - while the
///   keyboard is being used, say.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetWindowPointerA` (`WA_HidePointer`), `ActiveWindow`
///
/// EXAMPLES:
/// ```zig
/// ib.HidePointer(true); // a key was typed
/// defer ib.HidePointer(false); // and the mouse moved, or the program ends
/// ```
pub fn HidePointer(ib: *IntuitionBase, hidden: bool) void {
    _window.lock(ib);
    defer _window.unlock(ib);
    const st = &ib.pointer;
    const want: u8 = @intFromBool(hidden);
    if (st.blanked == want) return;
    st.blanked = want;
    pointer.update(ib);
}
