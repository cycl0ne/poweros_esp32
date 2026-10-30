// SPDX-License-Identifier: MPL-2.0
//! OpenVideoLayer: one of a board's video layers, for a film's frames.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const privateOf = @import("../board/_board.zig").privateOf;

/// Takes one of a board's video layers: a plane of its controller that
/// shows a picture in YUV itself, scaled into a place on the display.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenVideoLayer(rb: *RtgBase, board: *rtg.RtgBoard, tag_list: ?[*]const TagItem) ?*rtg.RtgVideoLayer
/// ```
///
/// SINCE: 1.10. LVO -264.
///
/// INPUTS:
/// - `board` - the board, a screen's (intuition's `SA_Board`) or one of
///   the caller's own.
/// - `tag_list` - `RTGVA_Under` (bool): under the board's picture, seen
///   through the layer's key colour - TRUE unless given; FALSE puts it
///   over the picture.
///
/// RESULT:
/// The layer, or null with `RtgLastError` saying why:
/// `RTGERR_NOT_SUPPORTED` for a board without `RTGBC_VIDEO`,
/// `RTGERR_IN_USE` when its layers are all taken, `RTGERR_NO_MEMORY`.
///
/// BEHAVIOR:
/// The layer comes with nothing on it and no place: `MoveVideoLayer`
/// puts it somewhere, and `ShowVideoFrame` hands it pictures. Its fields
/// say what it is: `RTGVLF_UNDER` in `flags` where it is under the
/// picture - a board that cannot put its picture over a layer opens it
/// over, asked or not - with `key` the colour the picture shows it
/// through; and how large a picture it takes and how far it scales one.
///
/// Under the picture, the layer is seen only where the picture is `key`:
/// a program fills its film's place with that colour, and whatever is
/// laid over the place - another window, a menu, the pointer - hides the
/// film as it would hide anything. While a layer is under it, the board's
/// whole picture shows that colour as the layer, or as black off the
/// layer's place.
///
/// CONTEXT:
/// - Waits: if the driver does.
/// - Interrupts: no.
/// - Locks: no spinlock may be held: a driver may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The layer is the caller's until `CloseVideoLayer`, which must come
/// before the board is deleted.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseVideoLayer`, `ShowVideoFrame`, `MoveVideoLayer`
///
/// EXAMPLES:
/// ```zig
/// const layer = rb.OpenVideoLayer(board, null) orelse return putThroughGraphics();
/// defer rb.CloseVideoLayer(layer);
/// ```
pub fn OpenVideoLayer(rb: *RtgBase, board: *rtg.RtgBoard, tag_list: ?[*]const TagItem) ?*rtg.RtgVideoLayer {
    const sys = rb.sys_base;
    const ops = board.ops orelse return failed(rb, err.RTGERR_NOT_SUPPORTED);
    if (board.info.caps & rtg.boards.RTGBC_VIDEO == 0) return failed(rb, err.RTGERR_NOT_SUPPORTED);
    const memory = sys.AllocVec(@sizeOf(rtg.RtgVideoLayer), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return failed(rb, err.RTGERR_NO_MEMORY);
    const layer: *rtg.RtgVideoLayer = @ptrCast(@alignCast(memory));
    const under = rb.utility_base.GetTagData(rtg.RTGVA_Under, 1, tag_list) != 0;
    layer.* = .{ .board = board, .flags = if (under) rtg.RTGVLF_UNDER else 0 };
    const result = ops.video_open.?(board, layer);
    if (result != err.RTGERR_OK) {
        sys.FreeVec(memory);
        return failed(rb, result);
    }
    if (layer.flags & rtg.RTGVLF_UNDER == 0) layer.key = 0;
    _ = @atomicRmw(u32, &privateOf(board).video_layers, .Add, 1, .monotonic);
    return layer;
}

fn failed(rb: *RtgBase, code: i32) ?*rtg.RtgVideoLayer {
    rb.last_error = code;
    return null;
}
