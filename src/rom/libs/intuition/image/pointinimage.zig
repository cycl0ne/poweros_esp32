// SPDX-License-Identifier: MPL-2.0
//! PointInImage: whether a point is inside an image.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const ic = intuition.imageclass;
const Object = intuition.Object;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Whether a point is inside an image.
///
/// SYNOPSIS:
/// ```zig
/// fn PointInImage(ib: *IntuitionBase, x: i32, y: i32,
///     image: ?*Object) bool
/// ```
///
/// SINCE: 0.3. LVO -92.
///
/// INPUTS:
/// - `x`, `y` - the point, in the coordinates the image's left and top are
///   in.
/// - `image` - the image, or null, which contains every point.
///
/// RESULT:
/// True when the image says the point is its own.
///
/// BEHAVIOR:
/// `IM_HITTEST` sent to the image's own class. imageclass answers by its
/// box; a class with a shape that is not a box can answer by the shape.
///
/// CONTEXT:
/// - Waits: whatever the image's class does.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// - A null image containing every point lets a gadget with no image of
///   its own be hit anywhere in its box without a test of its own.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `imageclass.IM_HITTEST`
///
/// EXAMPLES:
/// ```zig
/// if (ib.PointInImage(mouse_x, mouse_y, button_face)) press();
/// ```
pub fn PointInImage(ib: *IntuitionBase, x: i32, y: i32, image: ?*Object) bool {
    const o = image orelse return true;
    var msg = ic.ImpHitTest{ .method_id = ic.IM_HITTEST, .point = .{ .x = x, .y = y } };
    return ib.iface().SendMessage(o, @ptrCast(&msg)) != 0;
}
