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
/// SINCE: 1.10. LVO -180.
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
/// The layer, or null: for a board without `RTGBC_VIDEO` or one whose
/// controller cannot make the display's colours out of such a picture,
/// when its layers are all taken, or without memory for the handle.
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
    const ops = board.ops orelse return null;
    const video = ops.video orelse return null;
    const memory = sys.AllocVec(@sizeOf(rtg.RtgVideoLayer), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
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
    const result = video.open(board, layer);
    if (result != err.RTGERR_OK) {
        sys.FreeVec(memory);
        return null;
    }
    if (layer.flags & rtg.RTGVLF_UNDER == 0) layer.key = 0;
    _ = @atomicRmw(u32, &privateOf(board).video_layers, .Add, 1, .monotonic);
    return layer;
}

/// One of the tags that say what the picture will be: all of them are
/// small numbers, and anything that does not fit a byte is taken as the
/// tag not given at all - no driver would know it anyway.
///
/// INPUTS:
/// - `rb` - the library's base, for utility.library.
/// - `tag` - the tag to read.
/// - `unless` - what the tag means when it is not given.
/// - `tag_list` - the caller's tags, or null.
///
/// RESULT:
/// The tag's value, or `unless`.
fn kind(rb: *RtgBase, tag: Tag, unless: u8, tag_list: ?[*]const TagItem) u8 {
    const told = rb.utility_base.GetTagData(tag, unless, tag_list);
    return if (told <= 255) @intCast(told) else unless;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const std = fixture.std;
const testing = fixture.testing;

test "video layers: one to a board, a picture needs its part, the limits kept, closed before the board goes" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeBoard(rb);
    var info: rtg.RtgBoardInfo = .{};
    _ = fixture.base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expect(info.caps & rtg.boards.RTGBC_VIDEO != 0);

    // A layer is asked for a kind of picture, and a board whose converter
    // cannot make the display's colours out of it hands out none: a film
    // of high dynamic range, one in BT.2020's colours, one of ten bits.
    // Nothing is taken by a refusal.
    const kinds = [_]TagItem{
        .{ .tag = rtg.RTGVA_Transfer, .data = rtg.RTGYUV_PQ },
        .{ .tag = rtg.RTGVA_Transfer, .data = rtg.RTGYUV_HLG },
        .{ .tag = rtg.RTGVA_Primaries, .data = rtg.RTGYUV_BT2020 },
        .{ .tag = rtg.RTGVA_Matrix, .data = rtg.RTGYUV_BT2020 },
        .{ .tag = rtg.RTGVA_Depth, .data = 10 },
    };
    for (kinds) |one| {
        try testing.expect(fixture.base(rb).OpenVideoLayer(board, &[_]TagItem{ one, .{} }) == null);
    }
    try testing.expectEqual(@as(u32, 0), fk.log.video_opens);

    // Under the picture unless asked otherwise, with its key and limits;
    // the board's one layer is then taken. What it was asked for stays in
    // its fields, where the driver read them.
    const layer = fixture.base(rb).OpenVideoLayer(board, &[_]TagItem{ .{ .tag = rtg.RTGVA_Matrix, .data = rtg.RTGYUV_BT601 }, .{ .tag = rtg.RTGVA_Range, .data = rtg.RTGYUV_FULL }, .{} }) orelse return error.NoLayer;
    try testing.expectEqual(rtg.RTGYUV_BT601, layer.matrix);
    try testing.expectEqual(rtg.RTGYUV_FULL, layer.range);
    try testing.expectEqual(rtg.RTGYUV_SDR, layer.transfer);
    try testing.expectEqual(rtg.RTGYUV_BT709, layer.primaries);
    try testing.expectEqual(@as(u8, 8), layer.depth);
    try testing.expectEqual(board, layer.board);
    try testing.expect(layer.flags & rtg.RTGVLF_UNDER != 0);
    try testing.expectEqual(@as(u32, 0x0008_0008), layer.key);
    try testing.expectEqual(@as(u32, 3), layer.max_up);
    try testing.expect(fixture.base(rb).OpenVideoLayer(board, null) == null);

    // A picture is shown with its part, which says how big it is.
    var luma: [16]u8 = @splat(16);
    var chroma: [8]u8 = @splat(128);
    const picture = rtg.RtgYuv{ .y = &luma, .cb = &chroma, .y_pitch = 4, .c_pitch = 4 };
    const all = rtg.RtgRect{ .width = 4, .height = 4 };
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).ShowVideoFrame(layer, &picture, null));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).ShowVideoFrame(layer, &picture, &.{ .width = 0, .height = 4 }));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).ShowVideoFrame(layer, &picture, &.{ .x = 4090, .width = 8, .height = 4 }));
    // A part at the end of the numbers is past the limit too, each way.
    const far = std.math.maxInt(i32);
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).ShowVideoFrame(layer, &picture, &.{ .x = far, .width = 8, .height = 4 }));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).ShowVideoFrame(layer, &picture, &.{ .y = far, .width = 4, .height = 8 }));
    try testing.expectEqual(@as(u32, 0), fk.log.video_shows);
    const moves = fk.log.video_moves;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).MoveVideoLayer(layer, &.{ .x = 10, .y = 20, .width = 12, .height = 12 }));
    try testing.expectEqual(moves + 1, fk.log.video_moves);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowVideoFrame(layer, &picture, &all));
    try testing.expectEqual(&picture, fk.log.video_picture.?);
    try testing.expectEqual(all, fk.log.video_src);

    // A place the picture cannot be scaled into is the driver's to refuse;
    // nothing shown takes no part.
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).MoveVideoLayer(layer, &.{ .width = 13, .height = 12 }));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowVideoFrame(layer, null, &all));
    try testing.expect(fk.log.video_picture == null);

    // The board is not deleted under an open layer.
    fixture.driverBase(rb).DeleteBoard(board);
    try testing.expectEqual(@as(u32, 0), fk.log.destroyed);
    fixture.base(rb).CloseVideoLayer(layer);
    fixture.base(rb).CloseVideoLayer(null);
    try testing.expectEqual(@as(u32, 1), fk.log.video_closes);

    // Over the picture when asked, or when the board cannot lay its
    // picture over a layer: no key then.
    const over = fixture.base(rb).OpenVideoLayer(board, &[_]TagItem{ .{ .tag = rtg.RTGVA_Under, .data = 0 }, .{} }) orelse return error.NoLayer;
    try testing.expectEqual(@as(u32, 0), over.flags & rtg.RTGVLF_UNDER);
    fixture.base(rb).CloseVideoLayer(over);
    fk.video_over_only = true;
    const forced = fixture.base(rb).OpenVideoLayer(board, null) orelse return error.NoLayer;
    try testing.expectEqual(@as(u32, 0), forced.flags & rtg.RTGVLF_UNDER);
    try testing.expectEqual(@as(u32, 0), forced.key);
    fixture.base(rb).CloseVideoLayer(forced);
    fixture.driverBase(rb).DeleteBoard(board);
    try testing.expectEqual(@as(u32, 1), fk.log.destroyed);
    try fixture.tearDown(rb);
}

test "a board with no video layer says so" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    fixture.fakeOf(rb).without_engine = true;
    const board = try fixture.makeBoard(rb);
    var info: rtg.RtgBoardInfo = .{};
    _ = fixture.base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u32, 0), info.caps & rtg.boards.RTGBC_VIDEO);
    try testing.expect(fixture.base(rb).OpenVideoLayer(board, null) == null);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}
