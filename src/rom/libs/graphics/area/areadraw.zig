// SPDX-License-Identifier: MPL-2.0
//! AreaDraw: the next corner of the shape being collected.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const _area = @import("_area.zig");
const RastPort = rastport.RastPort;
const addPoint = _area.addPoint;

/// The next corner of the shape being collected.
///
/// SYNOPSIS:
/// ```zig
/// fn AreaDraw(gb: *GraphicsBase, rp: *RastPort, x: i32, y: i32) bool
/// ```
///
/// SINCE: 0.10. LVO -104.
///
/// INPUTS:
/// - `rp` - the RastPort, with a shape begun.
/// - `x` - the next corner, across.
/// - `y` - the next corner, down.
///
/// RESULT:
/// False with `GERR_BAD_SIZE` if no shape has been begun. A corner with no
/// shape is the caller's slip rather than a new shape, and saying so is
/// more use than quietly starting one.
///
/// BEHAVIOR:
/// The corner joins the shape begun last. The edge back from the last
/// corner to the first is implied: `AreaEnd` closes every shape.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It changes the caller's RastPort.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The corner goes into the room `InitArea` gave.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AreaMove`, `AreaEnd`
///
/// EXAMPLES:
/// ```zig
/// _ = gb.AreaDraw(rp, 60, 10);
/// ```
pub fn AreaDraw(gb: *GraphicsBase, rp: *RastPort, x: i32, y: i32) bool {
    _ = gb;
    rp.last_error = graphics.GERR_OK;
    // A corner with no shape begun is the caller's slip, not a new shape:
    // saying so is more use than quietly starting one.
    if (rp.area_shapes == 0) {
        rp.last_error = graphics.GERR_BAD_SIZE;
        return false;
    }
    return addPoint(rp, x, y);
}
