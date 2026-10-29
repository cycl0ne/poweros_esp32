// SPDX-License-Identifier: MPL-2.0
//! ScaleYUVPixelArray: puts a YUV picture down as colours at another
//! size.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const Rect = graphics.Rect;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _blit = @import("_blit.zig");
const RastPort = _blit.RastPort;
const yuv = @import("_yuv.zig");
const drawing = @import("../draw/_draw.zig");
const rastport = @import("../rastport/_rastport.zig");

/// Puts a YUV picture down as colours at another size.
///
/// SYNOPSIS:
/// ```zig
/// fn ScaleYUVPixelArray(gb: *GraphicsBase, rp: *RastPort, picture: *const RtgYuv, src_area: *const Rect, dest_area: *const Rect) void
/// ```
///
/// SINCE: 0.36. LVO -348.
///
/// INPUTS:
/// - `rp` - the RastPort. Its clip decides where the pixels land.
/// - `picture` - the picture, as for `WriteYUVPixelArray`.
/// - `src_area` - the part of the picture to take, half-open, measured
///   in its luma pixels.
/// - `dest_area` - where it lands and how big, half-open.
///
/// RESULT:
/// Nothing. `RPTAG_LastError` says `GERR_BAD_FORMAT` as for
/// `WriteYUVPixelArray`, and nothing was written; an empty `src_area` or
/// `dest_area` writes nothing and is not an error.
///
/// BEHAVIOR:
/// As `ScalePixelArray` scales a picture, with the colours worked out as
/// `WriteYUVPixelArray` works them out. Every pixel of the destination is
/// the nearest pixel of the source, taken from the edges: pixel `k` of
/// `dest_area` is pixel `k * source / destination` of `src_area`, each
/// way. A RastPort that wants it smooth (`RPTAG_Smooth`) has each plane
/// sampled first - made larger, mixed from the nearest pixels by how near
/// each is; made smaller, the mean of all it covers - and the colour
/// worked out from what that gives. Each way is taken by itself.
///
/// The clip cuts the destination, and each piece of it still takes the
/// pixels that belong at that place, so a picture drawn in pieces is the
/// same picture as one drawn in a single call.
///
/// A piece of many pixels is cut into bands of rows, one for each core
/// (`ShareWork`). The nearest pixel costs about what
/// `WriteYUVPixelArray` costs a pixel; smooth costs several times that,
/// most where the picture is made much smaller.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the RastPort's lock
///   (`RPTAG_Lock`), if it has one, and for the cores that share the
///   work.
/// - Interrupts: no. The work is unbounded, and it hands the rows it wrote
///   on to the display at the end.
/// - Locks: the RastPort's own, taken here; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The picture stays the caller's, and is only read
/// until the call returns.
///
/// NOTES:
/// What a video player calls for a frame in a window of any size. No
/// board's engine scales YUV, so this is done here every time.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WriteYUVPixelArray`, `ScalePixelArray`
///
/// EXAMPLES:
/// ```zig
/// // A decoded frame into whatever room the window has.
/// gb.ScaleYUVPixelArray(rp, &picture, &.{ .min_x = 0, .min_y = 0,
///     .max_x = @intCast(frame.width), .max_y = @intCast(frame.height) }, &box);
/// ```
pub fn ScaleYUVPixelArray(gb: *GraphicsBase, rp: *RastPort, picture: *const rtg.RtgYuv, src_area: *const Rect, dest_area: *const Rect) void {
    const held = rastport.hold(gb, rp);
    defer rastport.letGo(gb, held);
    rp.last_error = graphics.GERR_OK;
    const planes = yuv.Planes.of(picture) orelse {
        rp.last_error = graphics.GERR_BAD_FORMAT;
        return;
    };
    if (rastport.packPen(rp.surface.format, 0) == null) {
        rp.last_error = graphics.GERR_BAD_FORMAT;
        return;
    }
    if (src_area.width() <= 0 or src_area.height() <= 0 or dest_area.width() <= 0 or dest_area.height() <= 0) return;

    var it = drawing.visible(rp, dest_area.*);
    var bound = Rect{};
    var any = false;
    while (it.next()) |r| {
        if (r.rect.isEmpty()) continue;
        const to_bytes = _blit.pixelBytes(r.surface);
        // Where each of the piece's pixels comes from is worked out from
        // the destination's own corner, so a piece of a clipped picture
        // takes the same pixels it would have taken whole.
        const piece = yuv.Piece{
            .planes = &planes,
            .to = r.surface.pixels.? + @as(usize, @intCast(r.rect.min_y + r.dy)) * r.surface.pitch +
                @as(usize, @intCast(r.rect.min_x + r.dx)) * to_bytes,
            .to_pitch = r.surface.pitch,
            .format = r.surface.format,
            .width = @intCast(r.rect.width()),
            .height = @intCast(r.rect.height()),
            .how = if (rp.smooth) .smooth else .nearest,
            .x = r.rect.min_x,
            .y = r.rect.min_y,
            .src = src_area.*,
            .dest = dest_area.*,
        };
        yuv.put(gb.sys_base, &piece);
        drawing.grow(&bound, r.rect.min_y, &any);
        drawing.grow(&bound, r.rect.max_y - 1, &any);
    }
    if (any) drawing.handOn(gb, rp, drawing.written(dest_area.*, bound));
}
