// SPDX-License-Identifier: MPL-2.0
//! FreeRastPort: gives a RastPort back.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _rastport = @import("_rastport.zig");
const areas = @import("../area/_area.zig");
const RastPort = _rastport.RastPort;

/// Gives a RastPort back.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeRastPort(gb: *GraphicsBase, rp: ?*RastPort) void
/// ```
///
/// SINCE: 0.2. LVO -24.
///
/// INPUTS:
/// - `rp` - the RastPort, or null, which does nothing. Passing one twice
///   is the caller's bug and is not caught.
///
/// RESULT:
/// Nothing. It cannot fail.
///
/// BEHAVIOR:
/// The buffer it drew into is not touched. A board's buffer belongs to
/// rtg.library and is given back with `FreeBitMap`; plain memory belongs
/// to whoever lent it. What is drawn stays drawn - nothing is cleared and
/// nothing is refreshed.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no; it frees memory.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The RastPort's own memory, and nothing else.
///
/// NOTES:
/// - It does not wait for a board's engine. A drawing call still in flight
///   is finished with `rtg.WaitBlit` before the RastPort goes, once there
///   are drawing calls to be in flight.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateRastPortTagList`, `rtg.FreeBitMap`, `rtg.WaitBlit`
///
/// EXAMPLES:
/// ```zig
/// const rp = gb.CreateRastPortTagList(null) orelse return;
/// defer gb.FreeRastPort(rp);
/// ```
pub fn FreeRastPort(gb: *GraphicsBase, rp: ?*RastPort) void {
    const port = rp orelse return;
    // Whatever InitArea took goes with it, so a caller that collected a
    // shape and never ended it still leaves nothing behind.
    areas.freeArea(gb, port);
    gb.sys_base.FreeVec(port);
}
