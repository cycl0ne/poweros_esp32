// SPDX-License-Identifier: MPL-2.0
//! EraseImage: erases what an image covers.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const ic = intuition.imageclass;
const Object = intuition.Object;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _image = @import("_image.zig");
const nextOf = _image.nextOf;

/// Erases what an image covers.
///
/// SYNOPSIS:
/// ```zig
/// fn EraseImage(ib: *IntuitionBase, rp: *graphics.RastPort,
///     image: ?*Object, left: i32, top: i32) void
/// ```
///
/// SINCE: 0.3. LVO -88.
///
/// INPUTS:
/// - `rp` - where it was drawn.
/// - `image` - the image, or null, which erases nothing.
/// - `left`, `top` - the offset it was drawn at.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// `IM_ERASE` sent to the image's own class. imageclass fills its box with
/// the RastPort's own background pen.
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
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DrawImage`
///
/// EXAMPLES:
/// ```zig
/// ib.EraseImage(rp, arrow, 10, 20);
/// ```
pub fn EraseImage(ib: *IntuitionBase, rp: *graphics.RastPort, image: ?*Object, left: i32, top: i32) void {
    var next = image;
    while (next) |o| : (next = nextOf(ib, o)) {
        var msg = ic.ImpErase{ .method_id = ic.IM_ERASE, .rast_port = rp, .offset = .{ .x = left, .y = top } };
        _ = ib.iface().SendMessage(o, @ptrCast(&msg));
    }
}
