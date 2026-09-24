// SPDX-License-Identifier: MPL-2.0
//! BltRastPort: moves a rectangle from one RastPort to another.

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

/// Moves a rectangle from one RastPort to another.
///
/// SYNOPSIS:
/// ```zig
/// fn BltRastPort(gb: *GraphicsBase, src: *RastPort, dest: *RastPort, area: *const Rect, dest_x: i32, dest_y: i32) void
/// ```
///
/// SINCE: 0.5. LVO -48.
///
/// INPUTS:
/// - `src` - where the pixels come from. Its clip is not consulted: a clip
///   says what may be *written*.
/// - `dest` - where they go. Its clip decides what lands.
/// - `area` - what to take, in the source's coordinates, half-open.
/// - `dest_x`, `dest_y` - where `area`'s top left lands in the
///   destination.
///
/// RESULT:
/// Nothing. Nothing lands if the two are in different formats, if the area
/// is outside the source, or if where it would land is outside the
/// destination's clip - none of which is an error.
///
/// BEHAVIOR:
/// The area is first cut to what the source actually has, then moved to
/// where it would land and clipped there, and only then copied - which is
/// the only order that gets a partly-clipped copy right.
///
/// The two RastPorts may be the same one and the rectangles may overlap:
/// rows are taken from the end when moving down and bytes from the end
/// when moving right, so a rectangle can be moved over itself.
///
/// Both must be in the same format. Moving between formats means unpacking
/// and repacking every pixel, which is a different operation and will be a
/// different call.
///
/// The rows written in the destination are handed on to the display before
/// it returns, as every drawing call does.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. The work is unbounded and it hands rows on at the end.
/// - Forbid: not held and not wanted.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The destination's surface is written.
///
/// NOTES:
/// - This is the other half of SMART_REFRESH: what was covered is kept in
///   a bitmap of its own and put back with this.
/// - The pen and the draw mode are not consulted. A blit moves pixels; it
///   does not compose them.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocBitMapTagList`, `RectFill`, `rtg.CopyRect`
///
/// EXAMPLES:
/// ```zig
/// // Keep what is under a box, then put it back.
/// gb.BltRastPort(screen_rp, saved_rp, &box, 0, 0);
/// // ... draw over the screen ...
/// gb.BltRastPort(saved_rp, screen_rp, &.{
///     .min_x = 0, .min_y = 0,
///     .max_x = box.width(), .max_y = box.height(),
/// }, box.min_x, box.min_y);
/// ```
pub fn BltRastPort(gb: *GraphicsBase, src: *RastPort, dest: *RastPort, area: *const Rect, dest_x: i32, dest_y: i32) void {
    blitInto(gb, src.surface, area.min_x, area.min_y, dest, dest_x, dest_y, area.width(), area.height(), null, 0);
}
