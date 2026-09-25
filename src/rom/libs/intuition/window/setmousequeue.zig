// SPDX-License-Identifier: MPL-2.0
//! SetMouseQueue: how many pointer moves a window may have waiting.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const lock = _window.lock;
const unlock = _window.unlock;

/// Sets how many pointer moves a window may have waiting.
///
/// SYNOPSIS:
/// ```zig
/// fn SetMouseQueue(ib: *IntuitionBase, window: *Window, length: u32) u32
/// ```
///
/// SINCE: 0.14. LVO -352.
///
/// INPUTS:
/// - `window` - the window.
/// - `length` - how many IDCMP_MOUSEMOVE messages may be out unreplied; 0
///   is taken as 1.
///
/// RESULT:
/// The length it had before.
///
/// BEHAVIOR:
/// Beyond that many, further moves are not sent until the program replies:
/// the next one says where the pointer is anyway. Moves already waiting
/// stay. It is what `WA_MouseQueue` sets when the window opens.
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
/// A drawing program that wants every point of a stroke asks for more; a
/// program that only wants to know where the pointer is now needs one.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReportMouse`, `OpenWindowTagList` (`WA_MouseQueue`)
///
/// EXAMPLES:
/// ```zig
/// _ = ib.SetMouseQueue(window, 16);
/// ```
pub fn SetMouseQueue(ib: *IntuitionBase, window: *Window, length: u32) u32 {
    lock(ib);
    defer unlock(ib);
    const old = window.mouse_limit;
    window.mouse_limit = @max(length, 1);
    return old;
}
