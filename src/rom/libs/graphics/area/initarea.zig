// SPDX-License-Identifier: MPL-2.0
//! InitArea: room to collect a filled shape in.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const Point = graphics.Point;
const _area = @import("_area.zig");
const RastPort = rastport.RastPort;
const bytes_per_point = @sizeOf(Point) + @sizeOf(u32) + @sizeOf(i32);
const reset = _area.reset;

/// Room to collect a filled shape in.
///
/// SYNOPSIS:
/// ```zig
/// fn InitArea(gb: *GraphicsBase, rp: *RastPort, max_points: u32) bool
/// ```
///
/// SINCE: 0.10. LVO -96.
///
/// INPUTS:
/// - `rp` - the RastPort the shapes will be filled on.
/// - `max_points` - as many corners as will be needed. A curve becomes
///   corners too, about one for each degree of a small one and fewer as it
///   grows, so an ellipse wants up to 360. 0 gives the room back.
///
/// RESULT:
/// False with `GERR_NO_MEMORY` if the room could not be had.
///
/// BEHAVIOR:
/// Room already there is given back first, with anything collected in it,
/// so the call can be made again to grow the room.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It allocates.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The room is the library's and goes with the RastPort: `FreeRastPort`
/// gives it back, so a shape collected and never ended leaves nothing
/// behind. The RastPort is opaque, so there is nowhere for a caller to keep
/// it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AreaMove`, `AreaEnd`
///
/// EXAMPLES:
/// ```zig
/// if (!gb.InitArea(rp, 360)) return error.NoMemory;
/// ```
pub fn InitArea(gb: *GraphicsBase, rp: *RastPort, max_points: u32) bool {
    if (rp.area_points) |old| {
        gb.sys_base.FreeVec(old);
        rp.area_points = null;
        rp.area_max = 0;
    }
    reset(rp);
    rp.last_error = graphics.GERR_OK;
    // Nothing asked for is how a caller gives the room back.
    if (max_points == 0) return true;

    const mem = gb.sys_base.AllocVec(bytes_per_point * max_points, 0) orelse {
        rp.last_error = graphics.GERR_NO_MEMORY;
        return false;
    };
    rp.area_points = @ptrCast(@alignCast(mem));
    rp.area_max = max_points;
    return true;
}
