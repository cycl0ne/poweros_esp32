// SPDX-License-Identifier: MPL-2.0
//! ScalePixelArray: puts a rectangle of one's own pixels down at another
//! size.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const PixelFormat = rtg.bitmaps.PixelFormat;
const Rect = graphics.Rect;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _blit = @import("_blit.zig");
const RastPort = _blit.RastPort;
const drawing = @import("../draw/_draw.zig");
const rastport = @import("../rastport/_rastport.zig");

/// Puts a rectangle of one's own pixels down at another size.
///
/// SYNOPSIS:
/// ```zig
/// fn ScalePixelArray(gb: *GraphicsBase, rp: *RastPort, pixels: [*]const u8, pitch: u32, format: u32, src_area: *const Rect, dest_area: *const Rect) void
/// ```
///
/// SINCE: 0.20. LVO -312.
///
/// INPUTS:
/// - `rp` - the RastPort. Its clip decides where the pixels land.
/// - `pixels` - the picture: rows of `pitch` bytes, each pixel in
///   `format`.
/// - `pitch` - bytes from one row of it to the next.
/// - `format` - a `rtg.bitmaps.PixelFormat` with colours.
/// - `src_area` - the part of the picture to take, half-open, measured
///   in the picture's own pixels.
/// - `dest_area` - where it lands and how big, half-open.
///
/// RESULT:
/// Nothing. `RPTAG_LastError` says `GERR_BAD_FORMAT` for a format with
/// no colours in it on either side, and nothing was written; an empty
/// `src_area` or `dest_area` writes nothing and is not an error.
///
/// BEHAVIOR:
/// Every pixel of the destination is the nearest pixel of the source: no
/// two are mixed, so a picture made larger has square pixels and one
/// made smaller drops rows and columns whole. That is what a picture
/// wants - a screenshot or a drawing scaled this way stays sharp and
/// stays itself - and it is what makes the work one pass with no memory
/// of its own.
///
/// Coverage is honoured where the format carries it, exactly as
/// `BlendPixelArray` does, so a picture with soft edges scales without
/// losing them.
///
/// The clip cuts the destination, and each piece of it still takes the
/// pixels that belong at that place, so a picture drawn in pieces is the
/// same picture as one drawn in a single call.
///
/// A smooth scale whose destination is one whole piece of a board's
/// buffer goes to the board's engine (`rtg.ScalePixels`) where it takes
/// the job - for an engine that scales in fixed steps, a size those steps
/// reach exactly; everything else is done here.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. The work is unbounded, and it hands the rows it
///   wrote on to the display at the end.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The picture stays the caller's.
///
/// NOTES:
/// `BitMapScale` does the same for a surface that is already in memory
/// as a bitmap; this is for pixels a program holds itself - a decoded
/// picture, a frame that came over the network.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WritePixelArray`, `BlendPixelArray`, `BitMapScale`
///
/// EXAMPLES:
/// ```zig
/// // A 640 by 400 picture into whatever room the gadget has.
/// gb.ScalePixelArray(rp, picture.ptr, 640 * 3, @intFromEnum(PixelFormat.rgb24),
///     &.{ .min_x = 0, .min_y = 0, .max_x = 640, .max_y = 400 }, &box);
/// ```
pub fn ScalePixelArray(gb: *GraphicsBase, rp: *RastPort, pixels: [*]const u8, pitch: u32, format: u32, src_area: *const Rect, dest_area: *const Rect) void {
    rp.last_error = graphics.GERR_OK;
    const from: PixelFormat = @enumFromInt(format);
    if (rastport.packPen(from, 0) == null or rastport.packPen(rp.surface.format, 0) == null) {
        rp.last_error = graphics.GERR_BAD_FORMAT;
        return;
    }
    const src_w = src_area.width();
    const src_h = src_area.height();
    const dest_w = dest_area.width();
    const dest_h = dest_area.height();
    if (src_w <= 0 or src_h <= 0 or dest_w <= 0 or dest_h <= 0) return;

    const described = rtg.RtgPixels{ .pixels = pixels, .pitch = pitch, .format = from, .x = src_area.min_x, .y = src_area.min_y };
    if (_blit.scaleByEngine(gb, rp, &described, src_area.*, dest_area.*)) {
        drawing.handOn(gb, rp, dest_area.min_y, dest_area.max_y);
        return;
    }

    const src_bytes = rtg.bitmaps.formatBits(from) / 8;
    var it = drawing.visible(rp, dest_area.*);
    var bound = Rect{};
    var any = false;

    while (it.next()) |r| {
        const to_format = r.surface.format;
        const to_bytes = _blit.pixelBytes(r.surface);
        var y: i32 = r.rect.min_y;
        while (y < r.rect.max_y) : (y += 1) {
            // Where this row of the destination sits in the picture. The
            // sum is worked out from the destination's own corner, so a
            // piece of a clipped picture takes the same pixels it would
            // have taken whole.
            const sy = src_area.min_y + @divTrunc((y - dest_area.min_y) * src_h, dest_h);
            const row = pixels + @as(usize, @intCast(sy)) * pitch;
            const to = r.surface.pixels.? + @as(usize, @intCast(y + r.dy)) * r.surface.pitch +
                @as(usize, @intCast(r.rect.min_x + r.dx)) * to_bytes;
            var x: i32 = r.rect.min_x;
            if (rp.smooth) {
                // Between the pixels, for a RastPort that wants it smooth.
                const fy = _blit.sourceOf(y, dest_area.min_y, dest_h, src_area.min_y, src_h);
                while (x < r.rect.max_x) : (x += 1) {
                    const fx = _blit.sourceOf(x, dest_area.min_x, dest_w, src_area.min_x, src_w);
                    const pen = _blit.sampleBetween(pixels, pitch, from, src_area.*, fx, fy);
                    _blit.blendPixel(to + @as(usize, @intCast(x - r.rect.min_x)) * to_bytes, to_bytes, to_format, pen);
                }
                drawing.grow(&bound, y, &any);
                continue;
            }
            while (x < r.rect.max_x) : (x += 1) {
                const sx = src_area.min_x + @divTrunc((x - dest_area.min_x) * src_w, dest_w);
                const pen = rastport.unpackPen(from, drawing.getPixel(row + @as(usize, @intCast(sx)) * src_bytes, src_bytes));
                _blit.blendPixel(to + @as(usize, @intCast(x - r.rect.min_x)) * to_bytes, to_bytes, to_format, pen);
            }
            drawing.grow(&bound, y, &any);
        }
    }
    if (any) drawing.handOn(gb, rp, bound.min_y, bound.max_y);
}
