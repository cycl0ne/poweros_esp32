// SPDX-License-Identifier: MPL-2.0
//! BltPattern: fills a rectangle with a tile, repeated.

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
const drawing = @import("../draw/_draw.zig");
const bitAt = _blit.bitAt;
const shapeFlags = _blit.shapeFlags;
const engineUsable = _blit.engineUsable;
const asRtgRect = _blit.asRtgRect;
const stencil = _blit.stencil;
const writesPensOnly = _blit.writesPensOnly;
const patternRows = _blit.patternRows;

/// Fills a rectangle with a tile, repeated.
///
/// SYNOPSIS:
/// ```zig
/// fn BltPattern(gb: *GraphicsBase, rp: *RastPort, bits: [*]const u8, pitch: u32, width: u32, height: u32, area: *const Rect) void
/// ```
///
/// SINCE: 0.12. LVO -144.
///
/// INPUTS:
/// - `rp` - the RastPort. Its pens, draw mode and clip decide the result.
/// - `bits` - the tile, one bit to a pixel, as a template's shape is.
/// - `pitch` - bytes from one row of the tile to the next.
/// - `width` - how wide the tile is before it repeats.
/// - `height` - how tall. 0 either way is `GERR_BAD_SIZE`.
/// - `area` - what to fill, half-open.
///
/// RESULT:
/// Nothing. `GERR_BAD_SIZE` in the RastPort for a tile of no size.
///
/// BEHAVIOR:
/// **The tile is anchored to the surface, not to the rectangle.** So two
/// rectangles filled with one pattern line up where they meet, and a
/// desktop repainted in pieces looks like one desktop rather than a grid
/// of them. That is the whole reason a pattern is a call of its own rather
/// than a loop in the caller.
///
/// Clear bits and the engine work as for a template.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. The work is unbounded, and it hands the rows it wrote on
///   to the display at the end.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The tile stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BltTemplate`, `RectFill`
///
/// EXAMPLES:
/// ```zig
/// gb.BltPattern(rp, &checker, 1, 8, 8, &desktop);
/// ```
pub fn BltPattern(gb: *GraphicsBase, rp: *RastPort, bits: [*]const u8, pitch: u32, width: u32, height: u32, area: *const Rect) void {
    rp.last_error = graphics.GERR_OK;
    if (width == 0 or height == 0) {
        rp.last_error = graphics.GERR_BAD_SIZE;
        return;
    }
    var it = drawing.visible(rp, area.*);
    var bound = Rect{};
    var any = false;

    while (it.next()) |r| {
        if (engineUsable(rp, r)) {
            const tile = rtg.bitmaps.RtgPattern{
                .bits = bits,
                .pitch = pitch,
                .width = width,
                .height = height,
                // Anchored to the surface, so two rectangles of one
                // pattern line up where they meet.
                .origin_x = 0,
                .origin_y = 0,
                .fg = rp.fg_packed,
                .bg = rp.bg_packed,
                .flags = shapeFlags(rp),
            };
            const rect = asRtgRect(r.on(r.rect));
            if (gb.rtg_base.BlitPattern(r.bitmap.?, &rect, &tile) == rtg.errors.RTGERR_OK) {
                drawing.grow(&bound, r.rect.min_y, &any);
                drawing.grow(&bound, r.rect.max_y - 1, &any);
                continue;
            }
        }

        if (writesPensOnly(rp)) {
            patternRows(rp, r, bits, pitch, width, height);
            drawing.grow(&bound, r.rect.min_y, &any);
            drawing.grow(&bound, r.rect.max_y - 1, &any);
            continue;
        }

        var y: i32 = r.rect.min_y;
        while (y < r.rect.max_y) : (y += 1) {
            // Where the pattern is anchored is the surface's origin, not
            // the RastPort's, so it is the same tiling either way in and
            // the two rectangles of one pattern still line up.
            const row: i32 = @mod(y + r.dy, @as(i32, @intCast(height)));
            var x: i32 = r.rect.min_x;
            while (x < r.rect.max_x) : (x += 1) {
                const col: i32 = @mod(x + r.dx, @as(i32, @intCast(width)));
                stencil(rp, r, x, y, bitAt(bits, pitch, col, row));
            }
            drawing.grow(&bound, y, &any);
        }
    }
    if (any) drawing.handOn(gb, rp, bound.min_y, bound.max_y);
}
