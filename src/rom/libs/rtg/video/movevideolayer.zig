// SPDX-License-Identifier: MPL-2.0
//! MoveVideoLayer: a video layer's place on the display.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;

/// Puts a video layer somewhere on the display, or hides it.
///
/// SYNOPSIS:
/// ```zig
/// fn MoveVideoLayer(_: *RtgBase, layer: *rtg.RtgVideoLayer, place: *const rtg.RtgRect) i32
/// ```
///
/// SINCE: 1.10. LVO -276.
///
/// INPUTS:
/// - `layer` - the layer.
/// - `place` - where its picture is shown, scaled to fill it, in the
///   display's coordinates. It may lie partly off the display. An empty
///   one hides the layer.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_BAD_ARG` when the picture shown cannot be scaled
/// into the place (`max_up`, `max_down`), which hides the layer until a
/// place or a picture it can show.
///
/// BEHAVIOR:
/// The place is taken from the next frame. The picture shown stays, and
/// is shown in the new place: a window dragged with a paused film in it
/// takes the film along. Under the board's picture, the layer is seen
/// only where the picture has its key colour, so its place is normally
/// the place a program filled with that colour.
///
/// A screen's coordinates are the display's from its top edge down: a
/// window's place on the display is its place on its screen, its screen's
/// top edge (`SA_Top`) added.
///
/// CONTEXT:
/// - Waits: only if the driver does.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ShowVideoFrame`, `OpenVideoLayer`
///
/// EXAMPLES:
/// ```zig
/// const place = rtg.RtgRect{ .x = left + box.min_x, .y = top + box.min_y, .width = box.width(), .height = box.height() };
/// _ = rb.MoveVideoLayer(layer, &place);
/// ```
pub fn MoveVideoLayer(_: *RtgBase, layer: *rtg.RtgVideoLayer, place: *const rtg.RtgRect) i32 {
    const board = layer.board;
    return board.ops.?.video_move.?(board, layer, place);
}
