// SPDX-License-Identifier: MPL-2.0
//! BlendPixelArray: puts a rectangle of one's own pixels down over what
//! is already there, by their own coverage.

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

/// Puts a rectangle of one's own pixels down over what is already there,
/// mixing each with the pixel under it by its own coverage.
///
/// SYNOPSIS:
/// ```zig
/// fn BlendPixelArray(gb: *GraphicsBase, rp: *RastPort, pixels: [*]const u8, pitch: u32, format: u32, src_x: i32, src_y: i32, area: *const Rect) void
/// ```
///
/// SINCE: 0.20. LVO -308.
///
/// INPUTS:
/// - `rp` - the RastPort. Its clip decides where the pixels land.
/// - `pixels` - the picture: rows of `pitch` bytes, each pixel in
///   `format`.
/// - `pitch` - bytes from one row of it to the next.
/// - `format` - a `rtg.bitmaps.PixelFormat` with colours. One that
///   carries coverage - `rgba32`, `bgra32`, `argb1555` - is what this
///   call is for; one that does not covers what is under it outright,
///   and then this is `WritePixelArray` at greater cost.
/// - `src_x` - where in the picture to start, across.
/// - `src_y` - where in it to start, down.
/// - `area` - where it lands, half-open. Its size is how much is taken.
///
/// RESULT:
/// Nothing. `RPTAG_LastError` says `GERR_BAD_FORMAT` for a format with
/// no colours in it - `indexed8`, `mono1` - on either side, and then
/// nothing was written. `gray8` is taken on either side as a coverage:
/// read, it is the grey it stands for; written, a colour becomes its
/// brightness.
///
/// BEHAVIOR:
/// Each pixel is mixed with the one under it, channel by channel, by its
/// own coverage: fully covered goes down as it is, not covered at all
/// leaves the surface alone, and between the two the colours are mixed
/// in that proportion. The pens and the draw mode are not used.
///
/// The surface keeps no coverage of its own: what is written is opaque,
/// because it is what the display will show. Blending a picture onto a
/// window twice therefore is not the same as blending it once.
///
/// When the clip cuts the front off, the picture starts that much
/// further in, so a clipped picture is cut rather than slid.
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
/// Every pixel is read back from the surface before it is written, so
/// this costs more than `WritePixelArray` and is worth using only for a
/// picture that really has soft or clear places in it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WritePixelArray`, `ScalePixelArray`, `BltMaskRastPort`
///
/// EXAMPLES:
/// ```zig
/// gb.BlendPixelArray(rp, icon.ptr, 32 * 4, @intFromEnum(PixelFormat.rgba32), 0, 0, &.{ .min_x = x, .min_y = y, .max_x = x + 32, .max_y = y + 32 });
/// ```
pub fn BlendPixelArray(gb: *GraphicsBase, rp: *RastPort, pixels: [*]const u8, pitch: u32, format: u32, src_x: i32, src_y: i32, area: *const Rect) void {
    rp.last_error = graphics.GERR_OK;
    const from: PixelFormat = @enumFromInt(format);
    if (rastport.packPen(from, 0) == null or rastport.packPen(rp.surface.format, 0) == null) {
        rp.last_error = graphics.GERR_BAD_FORMAT;
        return;
    }
    const src_bytes = rtg.bitmaps.formatBits(from) / 8;
    var it = drawing.visible(rp, area.*);
    var bound = Rect{};
    var any = false;

    while (it.next()) |r| {
        const to_format = r.surface.format;
        const to_bytes = _blit.pixelBytes(r.surface);
        // The clip took some off the front: the picture starts that much
        // further in.
        const from_x = src_x + (r.rect.min_x - area.min_x);
        const from_y = src_y + (r.rect.min_y - area.min_y);
        const width: usize = @intCast(r.rect.width());
        var y: i32 = r.rect.min_y;
        while (y < r.rect.max_y) : (y += 1) {
            const row = pixels + @as(usize, @intCast(from_y + (y - r.rect.min_y))) * pitch +
                @as(usize, @intCast(from_x)) * src_bytes;
            const to = r.surface.pixels.? + @as(usize, @intCast(y + r.dy)) * r.surface.pitch +
                @as(usize, @intCast(r.rect.min_x + r.dx)) * to_bytes;
            for (0..width) |i| {
                const pen = rastport.unpackPen(from, drawing.getPixel(row + i * src_bytes, src_bytes));
                _blit.blendPixel(to + i * to_bytes, to_bytes, to_format, pen);
            }
            drawing.grow(&bound, y, &any);
        }
    }
    if (any) drawing.handOn(gb, rp, bound.min_y, bound.max_y);
}
