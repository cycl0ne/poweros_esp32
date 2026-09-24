// SPDX-License-Identifier: MPL-2.0
//! BltMaskRastPort: moves a rectangle, leaving alone the pixels the mask does not cover.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const _blit = @import("_blit.zig");
const Rect = graphics.Rect;
const RastPort = rastport.RastPort;
const blitInto = _blit.blitInto;

/// Moves a rectangle, leaving alone the pixels the mask does not cover.
///
/// SYNOPSIS:
/// ```zig
/// fn BltMaskRastPort(gb: *GraphicsBase, src: *RastPort, dest: *RastPort, area: *const Rect, dest_x: i32, dest_y: i32, mask: [*]const u8, mask_pitch: u32) void
/// ```
///
/// SINCE: 0.12. LVO -148.
///
/// INPUTS:
/// - `src` - where the pixels come from.
/// - `dest` - where they go. Both must be in one format.
/// - `area` - what to take, in the source's coordinates.
/// - `dest_x` - where its top-left lands, across.
/// - `dest_y` - where it lands, down.
/// - `mask` - one bit to a pixel, the same shape as `area`, read where the
///   source is read, so it travels with the shape.
/// - `mask_pitch` - bytes from one row of the mask to the next.
///
/// RESULT:
/// Nothing. `GERR_BAD_FORMAT` in `dest` if the formats differ.
///
/// BEHAVIOR:
/// A set bit is copied and a clear bit is left alone, and
/// `DRMD_INVERSVID` swaps that. This is the blit an icon wants: a shape
/// moved over a background it does not cover.
///
/// No engine: an engine copies rectangles, and this is a rectangle with
/// holes in it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. The work is unbounded, and it hands the rows it wrote on
///   to the display at the end.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The mask stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BltRastPort`, `BltTemplate`
///
/// EXAMPLES:
/// ```zig
/// gb.BltMaskRastPort(icons, rp, &icon_area, x, y, &icon_mask, 4);
/// ```
pub fn BltMaskRastPort(gb: *GraphicsBase, src: *RastPort, dest: *RastPort, area: *const Rect, dest_x: i32, dest_y: i32, mask: [*]const u8, mask_pitch: u32) void {
    blitInto(gb, src.surface, area.min_x, area.min_y, dest, dest_x, dest_y, area.width(), area.height(), mask, mask_pitch);
}
