// SPDX-License-Identifier: MPL-2.0
//! DrawImage: draws an image.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const ic = intuition.imageclass;
const Object = intuition.Object;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;

/// Draws an image.
///
/// SYNOPSIS:
/// ```zig
/// fn DrawImage(ib: *IntuitionBase, rp: *graphics.RastPort,
///     image: ?*Object, left: i32, top: i32) void
/// ```
///
/// SINCE: 0.3. LVO -80.
///
/// INPUTS:
/// - `rp` - where to draw.
/// - `image` - an image object, or null, which draws nothing.
/// - `left`, `top` - added to the image's own left and top.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// `DrawImageState` in `IDS_NORMAL` with no DrawInfo: `IM_DRAW` sent to
/// the image's own class.
///
/// CONTEXT:
/// - Waits: whatever the image's class does; imageclass does not.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands. imageclass gives the RastPort back with its pens
/// and draw mode as they were.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DrawImageState`, `EraseImage`
///
/// EXAMPLES:
/// ```zig
/// ib.DrawImage(rp, arrow, 10, 20);
/// ```
pub fn DrawImage(ib: *IntuitionBase, rp: *graphics.RastPort, image: ?*Object, left: i32, top: i32) void {
    ib.iface().DrawImageState(rp, image, left, top, ic.IDS_NORMAL, null);
}
