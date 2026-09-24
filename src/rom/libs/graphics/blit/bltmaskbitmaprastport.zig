// SPDX-License-Identifier: MPL-2.0
//! BltMaskBitMapRastPort: the same, leaving alone the pixels the mask does not cover.

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

/// The same, leaving alone the pixels the mask does not cover.
///
/// SYNOPSIS:
/// ```zig
/// fn BltMaskBitMapRastPort(gb: *GraphicsBase, src: *const rtg.Surface, src_x: i32, src_y: i32, dest: *RastPort, dest_x: i32, dest_y: i32, width: i32, height: i32, mask: [*]const u8, mask_pitch: u32) void
/// ```
///
/// SINCE: 0.13. LVO -160.
///
/// INPUTS:
/// - `src` - where the pixels come from.
/// - `src_x` - the rectangle's left edge in the source.
/// - `src_y` - its top edge.
/// - `dest` - where they go. Its clip decides what lands.
/// - `dest_x` - where the left edge lands.
/// - `dest_y` - where the top edge lands.
/// - `width` - how wide the rectangle is.
/// - `height` - how tall.
/// - `mask` - one bit to a pixel, read from the source's corner, so it
///   travels with the shape. `DRMD_INVERSVID` swaps which bit means copy.
/// - `mask_pitch` - bytes from one row of the mask to the next.
///
/// RESULT:
/// Nothing. `GERR_BAD_FORMAT` in `dest` if the formats differ.
///
/// BEHAVIOR:
/// This is the blit an icon wants: a shape moved over a background it does
/// not cover. No engine is asked - an engine copies rectangles, and this is
/// a rectangle with holes in it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. The work is unbounded, and it hands the rows it wrote on
///   to the display at the end.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The surface and the mask stay the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BltBitMapRastPort`, `BltMaskRastPort`
///
/// EXAMPLES:
/// ```zig
/// gb.BltMaskBitMapRastPort(icon, 0, 0, rp, x, y, 32, 32, &icon_mask, 4);
/// ```
pub fn BltMaskBitMapRastPort(gb: *GraphicsBase, src: *const rtg.Surface, src_x: i32, src_y: i32, dest: *RastPort, dest_x: i32, dest_y: i32, width: i32, height: i32, mask: [*]const u8, mask_pitch: u32) void {
    blitInto(gb, src, src_x, src_y, dest, dest_x, dest_y, width, height, mask, mask_pitch);
}
