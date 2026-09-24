// SPDX-License-Identifier: MPL-2.0
//! WindowLimits: sets how small and how large a window may be sized.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const lock = _window.lock;
const unlock = _window.unlock;

/// Sets how small and how large a window may be sized.
///
/// SYNOPSIS:
/// ```zig
/// fn WindowLimits(ib: *IntuitionBase, window: *Window, min_width: i32,
///     min_height: i32, max_width: i32, max_height: i32) bool
/// ```
///
/// SINCE: 0.10. LVO -236.
///
/// INPUTS:
/// - `window` - the window.
/// - `min_width`, `min_height` - the smallest it may be, border included;
///   0 leaves the limit as it is.
/// - `max_width`, `max_height` - the largest; 0 leaves it, and a negative
///   one is as large as the screen.
///
/// RESULT:
/// True when every limit asked for was taken. False when a minimum is
/// larger than the window is now or a maximum smaller: that limit is left
/// as it was, and the others are still taken.
///
/// BEHAVIOR:
/// Only the limits change: the window keeps its size, which every limit
/// taken already allows. Sizing it afterwards - with its size gadget,
/// `SizeWindow`, `ChangeWindowBox` or `ZipWindow` - stays within them, and
/// within its screen whatever the maximum says.
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
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenWindowTagList` (`WA_MinWidth` ... `WA_MaxHeight`), `SizeWindow`
///
/// EXAMPLES:
/// ```zig
/// _ = ib.WindowLimits(window, 200, 80, -1, -1);
/// ```
pub fn WindowLimits(ib: *IntuitionBase, window: *Window, min_width: i32, min_height: i32, max_width: i32, max_height: i32) bool {
    lock(ib);
    defer unlock(ib);
    var taken = true;
    if (min_width != 0) {
        if (min_width > window.width) taken = false else window.min_width = min_width;
    }
    if (min_height != 0) {
        if (min_height > window.height) taken = false else window.min_height = min_height;
    }
    if (max_width != 0) {
        const most = if (max_width < 0) window.screen.width else max_width;
        if (most < window.width) taken = false else window.max_width = most;
    }
    if (max_height != 0) {
        const most = if (max_height < 0) window.screen.height else max_height;
        if (most < window.height) taken = false else window.max_height = most;
    }
    return taken;
}
