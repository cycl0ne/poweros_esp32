// SPDX-License-Identifier: MPL-2.0
//! BltTemplate: stencils a shape onto the surface in the pens.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const bitAt = _blit.bitAt;
const stencil = _blit.stencil;
const asRtgRect = _blit.asRtgRect;
const shapeFlags = _blit.shapeFlags;
const engineUsable = _blit.engineUsable;
const drawing = @import("../draw/_draw.zig");
const Rect = graphics.Rect;
const RastPort = _blit.RastPort;
const _blit = @import("_blit.zig");

/// Stencils a shape onto the surface in the pens.
///
/// SYNOPSIS:
/// ```zig
/// fn BltTemplate(gb: *GraphicsBase, rp: *RastPort, bits: [*]const u8, pitch: u32, src_x: i32, src_y: i32, area: *const Rect) void
/// ```
///
/// SINCE: 0.12. LVO -140.
///
/// INPUTS:
/// - `rp` - the RastPort. Its pens, draw mode and clip decide the result.
/// - `bits` - the shape, one bit to a pixel, the leftmost pixel of a row in
///   the highest bit of its first byte.
/// - `pitch` - bytes from one row of the shape to the next.
/// - `src_x` - where in the shape to start, across. So one sheet of glyphs or
///   icons can be drawn from without cutting it up.
/// - `src_y` - where in the shape to start, down.
/// - `area` - where it lands, half-open. Its size is how much is taken.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// **The draw mode says what a clear bit means**, so there are no flags to
/// pass: `DRMD_JAM1` leaves the surface alone where the shape is clear,
/// `DRMD_JAM2` puts the background pen there, and `DRMD_INVERSVID` swaps
/// set and clear. That is the rule the line pattern already follows - a
/// shape and a dotted line are the same idea at different sizes.
///
/// The board's engine does it when it can. It writes the two colours it is
/// given and nothing else, so a mode that inverts the destination or a pen
/// that is not opaque comes back here instead.
///
/// When the clip cuts the front off, the shape starts that much further
/// in - otherwise a clipped shape would slide rather than be cut.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. The work is unbounded, and it hands the rows it wrote on
///   to the display at the end.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The shape stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BltPattern`, `BltMaskRastPort`, `Text`
///
/// EXAMPLES:
/// ```zig
/// gb.BltTemplate(rp, &arrow_bits, 2, 0, 0, &.{ .min_x = x, .min_y = y, .max_x = x + 16, .max_y = y + 16 });
/// ```
pub fn BltTemplate(gb: *GraphicsBase, rp: *RastPort, bits: [*]const u8, pitch: u32, src_x: i32, src_y: i32, area: *const Rect) void {
    rp.last_error = graphics.GERR_OK;
    var it = drawing.visible(rp, area.*);
    var bound = Rect{};
    var any = false;

    while (it.next()) |r| {
        // The clip took some off the front, so the shape starts that much
        // further in - or the picture would slide.
        const from_x = src_x + (r.rect.min_x - area.min_x);
        const from_y = src_y + (r.rect.min_y - area.min_y);

        if (engineUsable(rp, r)) {
            const shape = rtg.bitmaps.RtgTemplate{
                .bits = bits,
                .pitch = pitch,
                .src_x = @intCast(from_x),
                .src_y = @intCast(from_y),
                .fg = rp.fg_packed,
                .bg = rp.bg_packed,
                .flags = shapeFlags(rp),
            };
            const rect = asRtgRect(r.on(r.rect));
            if (gb.rtg_base.BlitTemplate(r.bitmap.?, &rect, &shape) == rtg.errors.RTGERR_OK) {
                drawing.grow(&bound, r.rect.min_y, &any);
                drawing.grow(&bound, r.rect.max_y - 1, &any);
                continue;
            }
        }

        var y: i32 = r.rect.min_y;
        while (y < r.rect.max_y) : (y += 1) {
            var x: i32 = r.rect.min_x;
            while (x < r.rect.max_x) : (x += 1) {
                stencil(rp, r, x, y, bitAt(bits, pitch, from_x + (x - r.rect.min_x), from_y + (y - r.rect.min_y)));
            }
            drawing.grow(&bound, y, &any);
        }
    }
    if (any) drawing.handOn(gb, rp, bound.min_y, bound.max_y);
}
