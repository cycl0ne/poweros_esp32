// SPDX-License-Identifier: MPL-2.0
//! ZipWindow: flips a window to its other box and back.

const sdk = @import("sdk");
const wn = sdk.intuition.windows;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const WF_ZOOMED = _window.WF_ZOOMED;
const lock = _window.lock;
const unlock = _window.unlock;

/// Flips a window to its other box and back.
///
/// SYNOPSIS:
/// ```zig
/// fn ZipWindow(ib: *IntuitionBase, window: *Window) void
/// ```
///
/// SINCE: 0.10. LVO -228.
///
/// INPUTS:
/// - `window` - the window.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The window goes to the box it was told to flip to - `WA_Zoom`, or else
/// its largest size when it opened at its smallest and its smallest
/// otherwise - and remembers where it was, so the next call puts it back.
/// A box whose corner is -1, -1 changes the size and not the place, which
/// is what a window that only wants to grow and shrink asks for. It is
/// what the zoom gadget does, and works on a window without one.
///
/// The box is changed with `ChangeWindowBox`, so it is kept within the
/// window's limits and its screen, and the window is told
/// `IDCMP_NEWSIZE` and `IDCMP_CHANGEWINDOW` as it asked.
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
/// `ChangeWindowBox`, `sdk.intuition.windows.WA_Zoom`
///
/// EXAMPLES:
/// ```zig
/// ib.ZipWindow(window);
/// ```
pub fn ZipWindow(ib: *IntuitionBase, window: *Window) void {
    lock(ib);
    const zoomed = window.flags & WF_ZOOMED != 0;
    var to = if (zoomed) window.unzoom_box else window.zoom_box;
    var from = wn.WindowBox{ .left = window.left, .top = window.top, .width = window.width, .height = window.height };
    if (to.left == -1 and to.top == -1) {
        to.left = from.left;
        to.top = from.top;
        from.left = -1;
        from.top = -1;
    }
    if (zoomed) window.zoom_box = from else window.unzoom_box = from;
    window.flags ^= WF_ZOOMED;
    unlock(ib);
    // Outside the lock: changing the box takes it itself, and takes the
    // layer locks under it.
    ib.iface().ChangeWindowBox(@ptrCast(window), to.left, to.top, to.width, to.height);
}
