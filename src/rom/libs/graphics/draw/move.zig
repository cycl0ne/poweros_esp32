// SPDX-License-Identifier: MPL-2.0
//! Move: puts the current point somewhere, drawing nothing.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const _draw = @import("_draw.zig");
const RastPort = rastport.RastPort;

/// Puts the current point somewhere, drawing nothing.
///
/// SYNOPSIS:
/// ```zig
/// fn Move(_: *GraphicsBase, rp: *RastPort, x: i32, y: i32) void
/// ```
///
/// SINCE: 0.6. LVO -52.
///
/// INPUTS:
/// - `rp` - the RastPort.
/// - `x` - where the next `Draw` starts, across. It may be outside the
///   surface: the clipping sorts that out.
/// - `y` - where it starts, down.
///
/// RESULT:
/// Nothing, and nothing is drawn.
///
/// BEHAVIOR:
/// The current point is where the next `Draw` starts. Nothing is clipped
/// or handed on, and `last_error` is left alone: a call that cannot fail
/// saying so would clear what the call before it found.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It changes the caller's RastPort, which an interrupt
///   does not share.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// - `RPTAG_Cursor` does the same thing and reads it back.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Draw`, `GetRPAttrs`
///
/// EXAMPLES:
/// ```zig
/// gb.Move(rp, 10, 10);
/// gb.Draw(rp, 100, 60);
/// ```
pub fn Move(_: *GraphicsBase, rp: *RastPort, x: i32, y: i32) void {
    rp.cp_x = x;
    rp.cp_y = y;
}
