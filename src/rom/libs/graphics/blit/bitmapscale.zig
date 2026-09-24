// SPDX-License-Identifier: MPL-2.0
//! BitMapScale: stretches a rectangle to fill another.

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
const rows = @import("../rows/_rows.zig");
const pixelBytes = _blit.pixelBytes;

/// Stretches a rectangle to fill another.
///
/// SYNOPSIS:
/// ```zig
/// fn BitMapScale(gb: *GraphicsBase, src: *const rtg.Surface, src_area: *const Rect, dest: *RastPort, dest_area: *const Rect) void
/// ```
///
/// SINCE: 0.13. LVO -164.
///
/// INPUTS:
/// - `src` - the surface to stretch from.
/// - `src_area` - what of it to stretch, cut to what the surface has.
/// - `dest` - where it goes. Its clip decides what lands.
/// - `dest_area` - how big it becomes, and where.
///
/// RESULT:
/// Nothing. `GERR_BAD_FORMAT` if the formats differ, `GERR_BAD_SIZE` if
/// either rectangle is empty.
///
/// BEHAVIOR:
/// The nearest pixel for each, stepped with whole numbers - no smoothing.
/// It keeps a
/// scaled-up shape's edges where they were rather than blurring them
/// across the pixels either side. Scaling down drops pixels rather than
/// averaging them.
///
/// Which source pixel a destination pixel comes from is worked out from the
/// destination rectangle's own corner and not from the clipped one, so a
/// stretch that is partly off the screen shows the right part of the
/// picture rather than sliding.
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
/// `BltBitMapRastPort`
///
/// EXAMPLES:
/// ```zig
/// gb.BitMapScale(thumb, &.{ .max_x = 32, .max_y = 32 }, rp, &.{ .min_x = 10, .min_y = 10, .max_x = 138, .max_y = 138 });
/// ```
pub fn BitMapScale(gb: *GraphicsBase, src: *const rtg.Surface, src_area: *const Rect, dest: *RastPort, dest_area: *const Rect) void {
    dest.last_error = graphics.GERR_OK;
    if (src.format != dest.surface.format) {
        dest.last_error = graphics.GERR_BAD_FORMAT;
        return;
    }
    const from = Rect.intersect(src_area.*, .{
        .min_x = 0,
        .min_y = 0,
        .max_x = @intCast(src.width),
        .max_y = @intCast(src.height),
    });
    if (from.isEmpty() or dest_area.isEmpty()) {
        dest.last_error = graphics.GERR_BAD_SIZE;
        return;
    }

    const src_w = from.width();
    const src_h = from.height();
    const dest_w = dest_area.width();
    const dest_h = dest_area.height();

    var it = drawing.visible(dest, dest_area.*);
    var bound = Rect{};
    var any = false;
    const bytes = pixelBytes(src);
    while (it.next()) |r| {
        const count: usize = @intCast(r.rect.width());
        const run = count * bytes;
        var previous: ?[*]u8 = null;
        var previous_sy: i32 = -1;
        var y: i32 = r.rect.min_y;
        while (y < r.rect.max_y) : (y += 1) {
            // Which source row this destination row came from. Worked out
            // from the rectangle's own top, not the clipped one, or a
            // clipped stretch would take from the wrong place.
            const sy = from.min_y + @divTrunc((y - dest_area.min_y) * src_h, dest_h);
            const to = r.surface.pixels.? + @as(usize, @intCast(y + r.dy)) * r.surface.pitch +
                @as(usize, @intCast(r.rect.min_x + r.dx)) * bytes;
            if (previous != null and previous_sy == sy) {
                // The row above took the same source row: it is this row
                // already, and it is the one just written, so it is still
                // in the cache where the source row may not be.
                rows.copy(to, previous.?, run);
            } else {
                const from_row = src.pixels.? + @as(usize, @intCast(sy)) * src.pitch;
                rows.stretch(to, from_row, bytes, count, from.min_x, r.rect.min_x - dest_area.min_x, src_w, dest_w);
            }
            previous = to;
            previous_sy = sy;
            drawing.grow(&bound, y, &any);
        }
    }
    if (any) drawing.handOn(gb, dest, bound.min_y, bound.max_y);
}
