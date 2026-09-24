// SPDX-License-Identifier: MPL-2.0
//! BltBitMapRastPort: moves a rectangle of pixels into a RastPort.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const _blit = @import("_blit.zig");
const RastPort = rastport.RastPort;
const blitInto = _blit.blitInto;

/// Moves a rectangle of pixels into a RastPort.
///
/// SYNOPSIS:
/// ```zig
/// fn BltBitMapRastPort(gb: *GraphicsBase, src: *const rtg.Surface, src_x: i32, src_y: i32, dest: *RastPort, dest_x: i32, dest_y: i32, width: i32, height: i32) void
/// ```
///
/// SINCE: 0.13. LVO -156.
///
/// INPUTS:
/// - `src` - where the pixels come from. A surface and not a RastPort: the
///   source of a blit has no clip, no pens and no draw mode.
/// - `src_x` - the rectangle's left edge in the source.
/// - `src_y` - its top edge.
/// - `dest` - where they go. Its clip decides what lands, and the rows are
///   handed on.
/// - `dest_x` - where the left edge lands.
/// - `dest_y` - where the top edge lands.
/// - `width` - how wide the rectangle is.
/// - `height` - how tall.
///
/// RESULT:
/// Nothing. `GERR_BAD_FORMAT` if the two formats differ - converting is a
/// different operation and will be a different call.
///
/// BEHAVIOR:
/// The destination's clip cuts it, and the board's engine moves it when
/// the destination is a board's buffer and the engine can.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. The work is unbounded, and it hands the rows it wrote on
///   to the display at the end.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The surface stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BltMaskBitMapRastPort`, `BitMapScale`
///
/// EXAMPLES:
/// ```zig
/// gb.BltBitMapRastPort(picture, 0, 0, rp, 20, 20, 64, 48);
/// ```
pub fn BltBitMapRastPort(gb: *GraphicsBase, src: *const rtg.Surface, src_x: i32, src_y: i32, dest: *RastPort, dest_x: i32, dest_y: i32, width: i32, height: i32) void {
    blitInto(gb, src, src_x, src_y, dest, dest_x, dest_y, width, height, null, 0);
}
