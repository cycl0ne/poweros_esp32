// SPDX-License-Identifier: MPL-2.0
//! WriteYUVPixelArray: puts a YUV picture down as colours, converted to
//! the surface's format.

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

/// Puts a YUV picture down as colours, converted to the surface's format.
///
/// SYNOPSIS:
/// ```zig
/// fn WriteYUVPixelArray(gb: *GraphicsBase, rp: *RastPort, picture: *const RtgYuv, src_x: i32, src_y: i32, area: *const Rect) void
/// ```
///
/// SINCE: 0.36. LVO -344.
///
/// INPUTS:
/// - `rp` - the RastPort. Its clip decides where the pixels land.
/// - `picture` - the picture: its luma and chroma planes, their layout
///   (`RTGYUV_NV12` or `RTGYUV_I420`) and how its numbers stand for
///   colours (`RTGYUV_BT601` or `RTGYUV_BT709`, with `RTGYUV_FULL` for
///   the whole byte).
/// - `src_x` - where in the picture to start, across, in luma pixels.
/// - `src_y` - where in it to start, down.
/// - `area` - where it lands, half-open. Its size is how much is taken.
///
/// RESULT:
/// Nothing. `RPTAG_LastError` says `GERR_BAD_FORMAT` for a layout or
/// colours this library does not know, an I420 picture with no Cr plane,
/// or a surface with no colours in it (`indexed8`, `mono1`); then nothing
/// was written.
///
/// BEHAVIOR:
/// Each pixel's colour comes from its own Y and the Cb and Cr of the two
/// by two pixels it is in, through the picture's matrix and range, and
/// goes down opaque: the pens, the draw mode and what was there are not
/// used. Below black and above white are held to them. This is how a
/// frame from a video decoder is put on the display as it comes - no copy
/// of it in RGB first.
///
/// When the clip cuts the front off, the picture starts that much further
/// in, so a clipped picture is cut rather than slid; an odd `src_x` or
/// `src_y` takes the chroma of the pair it falls in.
///
/// A piece of many pixels - a frame of any size - is cut into bands of
/// rows, one for each core (`ShareWork`).
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
/// A video decoder's frame is in memory its engine wrote: the caller
/// makes sure the cores see it (`CachePostDMA`, which videodec.resource's
/// `DecodeVideoFrame` has done) before handing it here.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ScaleYUVPixelArray`, `WritePixelArray`
///
/// EXAMPLES:
/// ```zig
/// const picture = rtg.RtgYuv{ .y = frame.y, .cb = frame.cbcr, .y_pitch = frame.pitch,
///     .c_pitch = frame.pitch, .layout = rtg.RTGYUV_NV12, .colors = rtg.RTGYUV_BT709 };
/// gb.WriteYUVPixelArray(rp, &picture, 0, 0, &.{ .min_x = 10, .min_y = 10,
///     .max_x = 10 + @as(i32, @intCast(frame.width)), .max_y = 10 + @as(i32, @intCast(frame.height)) });
/// ```
pub fn WriteYUVPixelArray(gb: *GraphicsBase, rp: *RastPort, picture: *const rtg.RtgYuv, src_x: i32, src_y: i32, area: *const Rect) void {
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
    var it = drawing.visible(rp, area.*);
    var bound = Rect{};
    var any = false;

    while (it.next()) |r| {
        if (r.rect.isEmpty()) continue;
        const to_bytes = _blit.pixelBytes(r.surface);
        // The clip took some off the front: the picture starts that much
        // further in.
        const piece = yuv.Piece{
            .planes = &planes,
            .to = r.surface.pixels.? + @as(usize, @intCast(r.rect.min_y + r.dy)) * r.surface.pitch +
                @as(usize, @intCast(r.rect.min_x + r.dx)) * to_bytes,
            .to_pitch = r.surface.pitch,
            .format = r.surface.format,
            .width = @intCast(r.rect.width()),
            .height = @intCast(r.rect.height()),
            .how = .straight,
            .from_x = src_x + (r.rect.min_x - area.min_x),
            .from_y = src_y + (r.rect.min_y - area.min_y),
        };
        yuv.put(gb.sys_base, &piece);
        drawing.grow(&bound, r.rect.min_y, &any);
        drawing.grow(&bound, r.rect.max_y - 1, &any);
    }
    if (any) drawing.handOn(gb, rp, drawing.written(area.*, bound));
}
