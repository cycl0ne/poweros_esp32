// SPDX-License-Identifier: MPL-2.0
//! GadgetMouse: where the pointer is, measured from a gadget's corner.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const Object = intuition.Object;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _gadget = @import("_gadget.zig");
const _window = @import("../window/_window.zig");
const gadgetOf = @import("../classes/gadgetclass.zig").gadgetOf;

/// Answers where the pointer is, measured from a gadget's top-left corner.
///
/// SYNOPSIS:
/// ```zig
/// fn GadgetMouse(ib: *IntuitionBase, gadget: *Object, info: *GadgetInfo, point: *graphics.Point) void
/// ```
///
/// SINCE: 0.14. LVO -432.
///
/// INPUTS:
/// - `gadget` - the gadget.
/// - `info` - the GadgetInfo its method was handed: which window, and the
///   room the gadget is measured in.
/// - `point` - where the answer goes.
///
/// RESULT:
/// Nothing; the position is in `point`, negative or past the gadget's size
/// when the pointer is outside it.
///
/// BEHAVIOR:
/// The pointer as intuition last saw it, taken into the window, into the
/// gadget's room (the interior of a GimmeZeroZero window, a requester) and
/// then to the gadget's box as it is now - right- and bottom-relative ones
/// worked out against that room.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do; a class calls it from its dispatcher.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// The methods that get input are handed this already, as their `mouse`;
/// this is for one that is not, such as `GM_RENDER` following the pointer.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// gadgetclass (`GpInput`)
///
/// EXAMPLES:
/// ```zig
/// var at = graphics.Point{};
/// ib.GadgetMouse(o, gi, &at);
/// ```
pub fn GadgetMouse(ib: *IntuitionBase, gadget: *Object, info: *intuition.GadgetInfo, point: *graphics.Point) void {
    const g = gadgetOf(ib, gadget);
    const box = _gadget.boxIn(g, info.domain_width, info.domain_height);
    var x = ib.input.x;
    var y = ib.input.y;
    const w: *_window.Window = @ptrCast(@alignCast(info.window));
    x -= w.left;
    y -= w.top;
    point.* = .{ .x = x - info.domain_left - box.left, .y = y - info.domain_top - box.top };
}
