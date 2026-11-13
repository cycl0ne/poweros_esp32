// SPDX-License-Identifier: MPL-2.0
//! RefreshWindowFrame: draws a window's border again.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const Window = _window.Window;
const drawBorder = _window.drawBorder;
const lock = _window.lock;
const unlock = _window.unlock;

/// Draws a window's border again, as deep at the top as its gadgets need.
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
/// The top border is measured first: it is as deep as the gadgets that
/// live in it (`GA_TopBorder`) reach below the title bar, and the title
/// bar's height without any. A gadget added there, taken out or made
/// another height since the border was last measured moves the inside's
/// top edge with it: the gadgets are laid out against the new inside and
/// the window hears IDCMP_NEWSIZE. The top border under the title bar is
/// the window's ground, between the window's sides.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and the layers' locks.
/// - Interrupts: no.
/// - Locks: none needed.
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
    _window.measureTop(ib, window);
    drawBorder(ib, window);
}
