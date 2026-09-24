// SPDX-License-Identifier: MPL-2.0
//! DrawImageState: draws an image in a state.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const ic = intuition.imageclass;
const Object = intuition.Object;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _image = @import("_image.zig");
const nextOf = _image.nextOf;

/// Draws an image in a state.
///
/// SYNOPSIS:
/// ```zig
/// fn DrawImageState(ib: *IntuitionBase, rp: *graphics.RastPort,
///     image: ?*Object, left: i32, top: i32, state: u32,
///     draw_info: ?*ic.DrawInfo) void
/// ```
///
/// SINCE: 0.3. LVO -84.
///
/// INPUTS:
/// - `rp` - where to draw.
/// - `image` - an image object, or null, which draws nothing.
/// - `left`, `top` - added to the image's own left and top.
/// - `state` - `IDS_NORMAL`, `IDS_SELECTED`, `IDS_DISABLED`, ... Which
///   states look different is the image's class's to say; imageclass
///   draws them all the same.
/// - `draw_info` - a screen's pens for an image that draws in them, or
///   null.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// `IM_DRAW` sent to the image's own class, so a class that draws itself
/// is the one that answers.
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
/// - Nothing makes a DrawInfo yet; screens will.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DrawImage`, `imageclass.IM_DRAW`
///
/// EXAMPLES:
/// ```zig
/// ib.DrawImageState(rp, button_face, 0, 0, imageclass.IDS_SELECTED, null);
/// ```
pub fn DrawImageState(ib: *IntuitionBase, rp: *graphics.RastPort, image: ?*Object, left: i32, top: i32, state: u32, draw_info: ?*ic.DrawInfo) void {
    // A picture may be several images chained together, each drawn at its
    // own place: one call puts all of it down.
    var next = image;
    while (next) |o| : (next = nextOf(ib, o)) {
        var msg = ic.ImpDraw{
            .method_id = ic.IM_DRAW,
            .rast_port = rp,
            .offset = .{ .x = left, .y = top },
            .state = state,
            .draw_info = draw_info,
        };
        _ = ib.iface().SendMessage(o, @ptrCast(&msg));
    }
}
