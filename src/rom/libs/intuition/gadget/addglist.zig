// SPDX-License-Identifier: MPL-2.0
//! AddGList: puts gadgets into a window.

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
const layoutRange = _gadget.layoutRange;

/// Puts gadgets into a window.
///
/// SYNOPSIS:
/// ```zig
/// fn AddGList(ib: *IntuitionBase, window: *Window, gadget: *Object,
///     position: i32, count: i32) u32
/// ```
///
/// SINCE: 0.6. LVO -184.
///
/// INPUTS:
/// - `window` - the window.
/// - `gadget` - the first gadget: a gadgetclass object, or one of a class
///   made from it, in no window.
/// - `position` - how many of the window's gadgets go before it; -1, or
///   more than it has, puts them at the end.
/// - `count` - how many, following each gadget's link to the next
///   (`GA_Previous`); -1 for all of them.
///
/// RESULT:
/// The position they went in at.
///
/// BEHAVIOR:
/// The gadgets are linked into the window's list and from then on are
/// hit-tested and fed input there. Nothing is drawn: `RefreshGList` does
/// that.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The gadgets stay the program's. The window only holds them, until
/// `RemoveGList` or `CloseWindow`; they are disposed of by the program.
///
/// NOTES:
/// Not while holding the window's layer lock: the input task draws gadgets
/// with the screen list's semaphore held and then takes that lock.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemoveGList`, `RefreshGList`, `sdk.intuition.windows.WA_Gadgets`
///
/// EXAMPLES:
/// ```zig
/// _ = ib.AddGList(window, ok_button, -1, 1);
/// ib.RefreshGList(ok_button, window, 1);
/// ```
pub fn AddGList(ib: *IntuitionBase, window: *Window, gadget: *Object, position: i32, count: i32) u32 {
    _window.lock(ib);
    defer _window.unlock(ib);
    const last = lastOf(ib, gadget, count);
    var o: ?*Object = gadget;
    while (o) |g| : (o = gadgetOf(ib, g).next) {
        gadgetOf(ib, g).window = window;
        if (g == last) break;
    }
    // Where it goes: after `position` gadgets, or at the end.
    var at: u32 = 0;
    var prev: ?*Object = null;
    var cur = window.gadgets;
    while (cur) |c| {
        if (position >= 0 and at == @as(u32, @intCast(position))) break;
        prev = c;
        cur = gadgetOf(ib, c).next;
        at += 1;
    }
    gadgetOf(ib, last).next = cur;
    if (prev) |p| gadgetOf(ib, p).next = gadget else window.gadgets = gadget;
    layoutRange(ib, window, gadget, last, true);
    return at;
}
