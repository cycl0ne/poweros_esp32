// SPDX-License-Identifier: MPL-2.0
//! RemoveGList: takes gadgets out of a window.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const Object = intuition.Object;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const gadgetclass = @import("../classes/gadgetclass.zig");
const gadgetOf = gadgetclass.gadgetOf;
const _gadget = @import("_gadget.zig");
const lastOf = _gadget.lastOf;

/// Takes gadgets out of a window.
///
/// SYNOPSIS:
/// ```zig
/// fn RemoveGList(ib: *IntuitionBase, window: *Window, gadget: *Object,
///     count: i32) i32
/// ```
///
/// SINCE: 0.6. LVO -188.
///
/// INPUTS:
/// - `window` - the window.
/// - `gadget` - the first of them.
/// - `count` - how many from it on; -1 for the rest of the list.
///
/// RESULT:
/// The position the first one had, or -1 if it was not the window's.
///
/// BEHAVIOR:
/// A gadget that has the input is told it has lost it (`GM_GOINACTIVE`,
/// `abort` 1) first. The gadgets taken out are linked to one another as
/// they were, and the last one to nothing. What they drew stays in the
/// window until the program draws over it.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The gadgets are wholly the program's again.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddGList`
///
/// EXAMPLES:
/// ```zig
/// _ = ib.RemoveGList(window, ok_button, 1);
/// ib.DisposeObject(ok_button);
/// ```
pub fn RemoveGList(ib: *IntuitionBase, window: *Window, gadget: *Object, count: i32) i32 {
    _window.lock(ib);
    defer _window.unlock(ib);
    var at: i32 = 0;
    var prev: ?*Object = null;
    var cur = window.gadgets;
    while (cur) |c| : (cur = gadgetOf(ib, c).next) {
        if (c == gadget) break;
        prev = c;
        at += 1;
    } else return -1;
    const last = lastOf(ib, gadget, count);
    const after = gadgetOf(ib, last).next;
    if (prev) |p| gadgetOf(ib, p).next = after else window.gadgets = after;
    gadgetOf(ib, last).next = null;
    var o: ?*Object = gadget;
    while (o) |g| : (o = gadgetOf(ib, g).next) {
        @import("../input/_input.zig").forgetGadget(ib, g);
        gadgetOf(ib, g).window = null;
    }
    return at;
}
