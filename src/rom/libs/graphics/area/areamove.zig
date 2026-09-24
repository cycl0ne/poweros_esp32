// SPDX-License-Identifier: MPL-2.0
//! AreaMove: begins a shape.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const addPoint = _area.addPoint;
const shapeStarts = _area.shapeStarts;
const RastPort = _area.RastPort;
const _area = @import("_area.zig");

/// Begins a shape.
///
/// SYNOPSIS:
/// ```zig
/// fn AreaMove(gb: *GraphicsBase, rp: *RastPort, x: i32, y: i32) bool
/// ```
///
/// SINCE: 0.10. LVO -100.
///
/// INPUTS:
/// - `rp` - the RastPort, with room from `InitArea`.
/// - `x` - the shape's first corner, across.
/// - `y` - its first corner, down.
///
/// RESULT:
/// False with `GERR_NO_MEMORY` if `InitArea` was never called, or
/// `GERR_BAD_SIZE` if there is no room for another corner.
///
/// BEHAVIOR:
/// A shape already begun is kept, to be filled along with this one. That is
/// what gives holes: the fill is even-odd, so a shape inside another leaves
/// the middle empty, and neither has to be wound any particular way.
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
/// `AreaDraw`, `AreaEnd`, `InitArea`
///
/// EXAMPLES:
/// ```zig
/// _ = gb.AreaMove(rp, 10, 10);
/// ```
pub fn AreaMove(gb: *GraphicsBase, rp: *RastPort, x: i32, y: i32) bool {
    _ = gb;
    rp.last_error = graphics.GERR_OK;
    if (rp.area_points == null) {
        rp.last_error = graphics.GERR_NO_MEMORY;
        return false;
    }
    if (rp.area_shapes >= rp.area_max) {
        rp.last_error = graphics.GERR_BAD_SIZE;
        return false;
    }
    shapeStarts(rp)[rp.area_shapes] = rp.area_count;
    rp.area_shapes += 1;
    return addPoint(rp, x, y);
}
