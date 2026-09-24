// SPDX-License-Identifier: MPL-2.0
//! AreaCircle: a whole circle as a shape of its own.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const _area = @import("_area.zig");
const RastPort = rastport.RastPort;

/// A whole circle as a shape of its own.
///
/// SYNOPSIS:
/// ```zig
/// fn AreaCircle(gb: *GraphicsBase, rp: *RastPort, cx: i32, cy: i32, radius: i32) bool
/// ```
///
/// SINCE: 0.10. LVO -112.
///
/// INPUTS:
/// - `rp` - the RastPort, with room from `InitArea`.
/// - `cx` - the centre's column.
/// - `cy` - the centre's row.
/// - `radius` - in pixels; below 0 adds nothing.
///
/// RESULT:
/// False, with the error in the RastPort, if the room ran out part way.
///
/// BEHAVIOR:
/// `AreaEllipse` with both radii the same.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It changes the caller's RastPort.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The corners go into the room `InitArea` gave.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AreaEllipse`, `DrawCircle`
///
/// EXAMPLES:
/// ```zig
/// _ = gb.AreaCircle(rp, 35, 35, 12);
/// ```
pub fn AreaCircle(gb: *GraphicsBase, rp: *RastPort, cx: i32, cy: i32, radius: i32) bool {
    const graphics_lib = gb.iface();
    return graphics_lib.AreaEllipse(@ptrCast(rp), cx, cy, radius, radius);
}
