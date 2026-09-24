// SPDX-License-Identifier: MPL-2.0
//! WritePixelArray: puts a rectangle of one's own pixels down, converted to
//! the surface's format.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const PixelFormat = rtg.bitmaps.PixelFormat;
const Rect = graphics.Rect;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _blit = @import("_blit.zig");
const RastPort = _blit.RastPort;
const drawing = @import("../draw/_draw.zig");
const rows = @import("../rows/_rows.zig");
const rastport = @import("../rastport/_rastport.zig");

/// Puts a rectangle of one's own pixels down, converted to the surface's
/// format.
///
/// SYNOPSIS:
/// ```zig
/// fn WritePixelArray(gb: *GraphicsBase, rp: *RastPort, pixels: [*]const u8, pitch: u32, format: u32, src_x: i32, src_y: i32, area: *const Rect) void
/// ```
///
/// SINCE: 0.18. LVO -264.
///
/// INPUTS:
/// - `rp` - the RastPort. Its clip decides where the pixels land.
/// - `pixels` - the picture: rows of `pitch` bytes, each pixel in `format`.
/// - `pitch` - bytes from one row of it to the next.
/// - `format` - a `rtg.bitmaps.PixelFormat` with colours: `rgba32`,
///   `bgra32`, `rgb24`, `bgr24`, `rgb565` or `argb1555`.
/// - `src_x` - where in the picture to start, across.
/// - `src_y` - where in it to start, down.
/// - `area` - where it lands, half-open. Its size is how much is taken.
///
/// RESULT:
/// Nothing. `RPTAG_LastError` says `GERR_BAD_FORMAT` for a format with no
/// colours in it - `indexed8`, `gray8`, `mono1` - on either side, and then
/// nothing was written.
///
/// BEHAVIOR:
/// Each pixel goes down as it is: the pens, the draw mode and any alpha in
/// the picture are not used, so this is how a decoded image, a captured
/// screen or a frame drawn elsewhere is put back. Where the picture's
/// format is the surface's, each row of a piece is one copy; otherwise
/// each pixel is converted, through the same colour a pen would be.
///
/// When the clip cuts the front off, the picture starts that much further
/// in, so a clipped picture is cut rather than slid.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. The work is unbounded, and it hands the rows it wrote
///   on to the display at the end.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The picture stays the caller's.
///
/// NOTES:
/// A window's RastPort is drawn through with the window's layer held, as
/// for any drawing call.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WriteLUTPixelArray`, `BltBitMapRastPort`, `ReadPixel`
///
/// EXAMPLES:
/// ```zig
/// gb.WritePixelArray(rp, frame.ptr, 320 * 4, @intFromEnum(PixelFormat.rgba32), 0, 0, &.{ .min_x = 10, .min_y = 10, .max_x = 330, .max_y = 250 });
/// ```
pub fn WritePixelArray(gb: *GraphicsBase, rp: *RastPort, pixels: [*]const u8, pitch: u32, format: u32, src_x: i32, src_y: i32, area: *const Rect) void {
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
            if (to_format == from) {
                rows.copy(to, row, width * to_bytes);
            } else {
                for (0..width) |i| {
                    const pen = rastport.unpackPen(from, drawing.getPixel(row + i * src_bytes, src_bytes));
                    rows.store(to + i * to_bytes, to_bytes, rastport.packPen(to_format, pen) orelse 0);
                }
            }
            drawing.grow(&bound, y, &any);
        }
    }
    if (any) drawing.handOn(gb, rp, bound.min_y, bound.max_y);
}
