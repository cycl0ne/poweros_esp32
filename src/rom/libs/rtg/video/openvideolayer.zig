// SPDX-License-Identifier: MPL-2.0
//! OpenVideoLayer: one of a board's video layers, for a film's frames.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const Tag = sdk.utility.Tag;
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
///   over the picture. `RTGVA_Matrix`, `RTGVA_Transfer`,
///   `RTGVA_Primaries`, `RTGVA_Range` and `RTGVA_Depth` (u8 each): what
///   the pictures will be, as `RtgYuv` says them - BT.709, the ordinary
///   range, video's range and eight bits unless given.
///
/// RESULT:
/// The layer, or null with `RtgLastError` saying why:
/// `RTGERR_NOT_SUPPORTED` for a board without `RTGBC_VIDEO` or one whose
/// controller cannot make the display's colours out of such a picture,
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
/// A board takes only a picture its controller can turn into the
/// display's colours itself, and the tags say which that will be. One it
/// cannot convert - a film of high dynamic range, one in BT.2020's
/// colours, one of ten bits - is refused outright, so that the caller
/// puts the film down through graphics, which maps it into the screen's
/// range, rather than having it shown flat and grey. What was asked for
/// stays in the layer's fields.
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
/// const tags = [_]TagItem{
///     .{ .tag = rtg.RTGVA_Matrix, .data = picture.matrix },
///     .{ .tag = rtg.RTGVA_Transfer, .data = picture.transfer },
///     .{ .tag = rtg.RTGVA_Primaries, .data = picture.primaries },
///     .{ .tag = rtg.RTGVA_Range, .data = picture.range },
///     .{ .tag = rtg.RTGVA_Depth, .data = picture.depth },
///     .{},
/// };
/// const layer = rb.OpenVideoLayer(board, &tags) orelse return putThroughGraphics();
/// defer rb.CloseVideoLayer(layer);
/// ```
pub fn OpenVideoLayer(rb: *RtgBase, board: *rtg.RtgBoard, tag_list: ?[*]const TagItem) ?*rtg.RtgVideoLayer {
    const sys = rb.sys_base;
    const ops = board.ops orelse return failed(rb, err.RTGERR_NOT_SUPPORTED);
    if (board.info.caps & rtg.boards.RTGBC_VIDEO == 0) return failed(rb, err.RTGERR_NOT_SUPPORTED);
    const memory = sys.AllocVec(@sizeOf(rtg.RtgVideoLayer), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return failed(rb, err.RTGERR_NO_MEMORY);
    const layer: *rtg.RtgVideoLayer = @ptrCast(@alignCast(memory));
    const under = rb.utility_base.GetTagData(rtg.RTGVA_Under, 1, tag_list) != 0;
    layer.* = .{
        .board = board,
        .flags = if (under) rtg.RTGVLF_UNDER else 0,
        .matrix = kind(rb, rtg.RTGVA_Matrix, rtg.RTGYUV_BT709, tag_list),
        .transfer = kind(rb, rtg.RTGVA_Transfer, rtg.RTGYUV_SDR, tag_list),
        .primaries = kind(rb, rtg.RTGVA_Primaries, rtg.RTGYUV_BT709, tag_list),
        .range = kind(rb, rtg.RTGVA_Range, rtg.RTGYUV_LIMITED, tag_list),
        .depth = kind(rb, rtg.RTGVA_Depth, 8, tag_list),
    };
    const result = ops.video_open.?(board, layer);
    if (result != err.RTGERR_OK) {
        sys.FreeVec(memory);
        return failed(rb, result);
    }
    if (layer.flags & rtg.RTGVLF_UNDER == 0) layer.key = 0;
    _ = @atomicRmw(u32, &privateOf(board).video_layers, .Add, 1, .monotonic);
    return layer;
}

/// One of the tags that say what the picture will be: all of them are
/// small numbers, and anything that does not fit a byte is taken as the
/// tag not given at all - no driver would know it anyway.
fn kind(rb: *RtgBase, tag: Tag, unless: u8, tag_list: ?[*]const TagItem) u8 {
    const told = rb.utility_base.GetTagData(tag, unless, tag_list);
    return if (told <= 255) @intCast(told) else unless;
}

fn failed(rb: *RtgBase, code: i32) ?*rtg.RtgVideoLayer {
    rb.last_error = code;
    return null;
}
