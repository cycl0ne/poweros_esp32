// SPDX-License-Identifier: MPL-2.0
//! ShowVideoFrame: a picture handed to a video layer.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;

/// Shows a picture in YUV on a video layer, scaled into its place.
///
/// SYNOPSIS:
/// ```zig
/// fn ShowVideoFrame(_: *RtgBase, layer: *rtg.RtgVideoLayer, picture: ?*const rtg.RtgYuv, src: ?*const rtg.RtgRect) i32
/// ```
///
/// SINCE: 1.10. LVO -272.
///
/// INPUTS:
/// - `layer` - the layer.
/// - `picture` - the planes, as a decoder lends them (`RtgYuv`), or null
///   to show nothing.
/// - `src` - the part of the picture shown, which is how its size is
///   known: the whole of a frame is (0, 0) by its width and height.
///   Needed with a picture; not read without one.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_BAD_ARG` for a picture without a part, an empty
/// part, or one the layer cannot read - its planes where the controller
/// does not reach, rows it cannot step, more than `max_width` by
/// `max_height` - or scale into its place (`max_up`, `max_down`).
///
/// BEHAVIOR:
/// The picture is shown from the next frame on, its part scaled into the
/// layer's place (`MoveVideoLayer`), its colours as `RtgYuv.colors` says.
/// The call returns once the controller has taken it: the picture shown
/// before is no longer read, and may be given back. This one is read
/// until the next is shown, or the layer is closed, so it stays lent
/// until then.
///
/// A picture the layer cannot take shows nothing, and is put down
/// through graphics instead (`ScaleYUVPixelArray`).
///
/// CONTEXT:
/// - Waits: for the next frame.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The planes stay the caller's; the layer reads them until the next
/// picture is shown.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MoveVideoLayer`, `OpenVideoLayer`
///
/// EXAMPLES:
/// ```zig
/// const all = rtg.RtgRect{ .width = @intCast(frame.width), .height = @intCast(frame.height) };
/// if (rb.ShowVideoFrame(layer, &frame.picture, &all) == rtg.errors.RTGERR_OK) {
///     if (shown) |*old| vcb.ReleaseVideoFrame(film, old);
///     shown = frame;
/// }
/// ```
pub fn ShowVideoFrame(_: *RtgBase, layer: *rtg.RtgVideoLayer, picture: ?*const rtg.RtgYuv, src: ?*const rtg.RtgRect) i32 {
    const board = layer.board;
    if (picture != null) {
        const part = src orelse return err.RTGERR_BAD_ARG;
        if (part.x < 0 or part.y < 0 or part.width <= 0 or part.height <= 0) return err.RTGERR_BAD_ARG;
        if (part.x + part.width > layer.max_width or part.y + part.height > layer.max_height) return err.RTGERR_BAD_ARG;
    }
    return board.ops.?.video_show.?(board, layer, picture, if (picture != null) src else null);
}
