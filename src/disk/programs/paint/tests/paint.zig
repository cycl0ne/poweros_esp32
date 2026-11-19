// SPDX-License-Identifier: MIT
//! Host tests of Paint's workings: the brushes' shapes and what they put
//! down, undo and redo over a block that fills, and the view's mapping,
//! zoom and rows. The window is not here.

const std = @import("std");
const picture_zig = @import("../picture.zig");
const brush_zig = @import("../brush.zig");
const history_zig = @import("../history.zig");
const view_zig = @import("../view.zig");
const Picture = picture_zig.Picture;
const Pixel = picture_zig.Pixel;
const Area = picture_zig.Area;
const Brush = brush_zig.Brush;
const History = history_zig.History;
const View = view_zig.View;

const testing = std.testing;

const white: Pixel = 0xFFFFFFFF;
const red: Pixel = 0xFFFF0000;
const blue: Pixel = 0xFF0000FF;

fn made(width: u32, height: u32, colour: Pixel) !Picture {
    const pixels = try testing.allocator.alloc(Pixel, width * height);
    var picture = Picture{ .pixels = pixels.ptr, .width = width, .height = height };
    picture.fill(colour);
    return picture;
}

fn free(picture: Picture) void {
    testing.allocator.free(picture.pixels[0 .. picture.width * picture.height]);
}

fn count(picture: *const Picture, colour: Pixel) usize {
    var found: usize = 0;
    for (picture.pixels[0 .. picture.width * picture.height]) |pixel| {
        if (pixel == colour) found += 1;
    }
    return found;
}

test "brush: a round brush is the disc in its box, a square one the box, held by the middle" {
    const round = Brush{ .shape = .round, .size = 5 };
    // The corners are out, the middle row whole.
    try testing.expect(!round.covers(0, 0));
    try testing.expect(!round.covers(4, 4));
    for (0..5) |dx| try testing.expect(round.covers(@intCast(dx), 2));
    try testing.expect((Brush{ .shape = .round, .size = 2 }).covers(0, 0));
    try testing.expect((Brush{ .shape = .square, .size = 5 }).covers(0, 0));
    try testing.expectEqual([2]i32{ 8, 18 }, round.corner(10, 20));
    // Sizes step along the list and stop at its ends.
    try testing.expectEqual(@as(u32, 6), (Brush{ .size = 4 }).stepped(true).size);
    try testing.expectEqual(@as(u32, 3), (Brush{ .size = 4 }).stepped(false).size);
    try testing.expectEqual(@as(u32, 32), (Brush{ .size = 32 }).stepped(true).size);
    try testing.expectEqual(@as(u32, 1), (Brush{ .size = 1 }).stepped(false).size);
}

test "brush: a stamp cut at the edge, a line with no gaps, the changed area" {
    var picture = try made(20, 10, white);
    defer free(picture);
    var changed = Area.none;
    // A square of 4 at the corner: the part inside, 2 by 2.
    brush_zig.stamp(&picture, .{ .shape = .square, .size = 4 }, 0, 0, red, &changed);
    try testing.expectEqual(@as(usize, 4), count(&picture, red));
    try testing.expectEqual(Area{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }, changed);

    // A steep line of single pixels: one in every row, ends included.
    changed = Area.none;
    brush_zig.line(&picture, .{ .size = 1 }, 15, 0, 18, 9, blue, &changed);
    try testing.expectEqual(@as(usize, 10), count(&picture, blue));
    for (0..10) |y| {
        var in_row: usize = 0;
        for (picture.row(@intCast(y))) |pixel| {
            if (pixel == blue) in_row += 1;
        }
        try testing.expectEqual(@as(usize, 1), in_row);
    }
    try testing.expectEqual(blue, picture.get(15, 0));
    try testing.expectEqual(blue, picture.get(18, 9));
    try testing.expectEqual(Area{ .min_x = 15, .min_y = 0, .max_x = 19, .max_y = 10 }, changed);
}

test "history: undone and redone, a new change drops the redo, the oldest go when the block is full" {
    var picture = try made(16, 16, white);
    defer free(picture);
    var kept = try made(16, 16, white);
    defer free(kept);
    // Room for three records of 4 by 4, not four.
    const room = 3 * History.recordBytes(.{ .max_x = 4, .max_y = 4 }) + 8;
    const memory = try testing.allocator.alignedAlloc(u8, .@"4", room);
    defer testing.allocator.free(memory);
    var history = History{ .memory = memory.ptr, .size = room };

    const colours = [_]Pixel{ 0xFF000001, 0xFF000002, 0xFF000003, 0xFF000004 };
    for (colours, 0..) |colour, i| {
        var changed = Area.none;
        brush_zig.stamp(&picture, .{ .shape = .square, .size = 4 }, @intCast(i * 4 + 2), 2, colour, &changed);
        try testing.expect(history.record(&picture, &kept, changed));
        try testing.expectEqual(colour, kept.get(@intCast(i * 4), 0));
    }
    // Three can be undone, the first change is kept for good.
    var undone: usize = 0;
    while (history.undo(&picture, &kept)) |area| : (undone += 1) {
        try testing.expectEqual(@as(u32, 4), area.width());
    }
    try testing.expectEqual(@as(usize, 3), undone);
    try testing.expectEqual(colours[0], picture.get(0, 0));
    try testing.expectEqual(white, picture.get(4, 0));
    try testing.expectEqual(white, kept.get(12, 0));

    // Redone, two of them; then a new change, and nothing to redo.
    _ = history.redo(&picture, &kept).?;
    _ = history.redo(&picture, &kept).?;
    try testing.expectEqual(colours[2], picture.get(8, 0));
    try testing.expectEqual(white, picture.get(12, 0));
    var changed = Area.none;
    brush_zig.stamp(&picture, .{ .size = 1 }, 15, 15, red, &changed);
    try testing.expect(history.record(&picture, &kept, changed));
    try testing.expect(!history.canRedo());
    _ = history.undo(&picture, &kept).?;
    try testing.expectEqual(white, picture.get(15, 15));
    try testing.expectEqual(colours[2], picture.get(8, 0));

    // A change larger than the block: kept from then on, nothing to undo.
    changed = Area.none;
    brush_zig.stamp(&picture, .{ .shape = .square, .size = 16 }, 8, 8, red, &changed);
    try testing.expect(!history.record(&picture, &kept, changed));
    try testing.expect(!history.canUndo());
    try testing.expectEqual(red, kept.get(0, 0));
}

test "view: a small picture in the middle, a large one scrolled inside, the zoom kept under a point" {
    var view = View{ .width = 100, .height = 50 };
    view.fit(40, 20);
    try testing.expectEqual(@as(i32, 30), view.offset_x);
    try testing.expectEqual(@as(i32, 15), view.offset_y);
    try testing.expectEqual([2]i32{ 0, 0 }, view.toPicture(30, 15));
    try testing.expectEqual([2]i32{ -1, -1 }, view.toPicture(29, 14));

    // At 4 the picture is 160 by 80: scrolled, and kept inside.
    view.zoom = 4;
    view.left = 500;
    view.top = -3;
    view.fit(40, 20);
    try testing.expectEqual(@as(i32, 0), view.offset_x);
    try testing.expectEqual(@as(i32, 15), view.left);
    try testing.expectEqual(@as(i32, 0), view.top);
    try testing.expectEqual([2]i32{ 17, 2 }, view.toPicture(9, 11));
    try testing.expectEqual(Area{ .min_x = 4, .min_y = 4, .max_x = 12, .max_y = 12 }, view.toView(.{ .min_x = 16, .min_y = 1, .max_x = 18, .max_y = 3 }));
    // Nothing changed at a zoom: nothing to show, and no overflow.
    view.zoom = 16;
    try testing.expect(view.toView(Area.none).isEmpty());
    view.zoom = 4;

    // Zoomed from 4 to 8 at the view's (40, 20): the pixel under it stays.
    const under = view.toPicture(40, 20);
    view.zoomAt(8, 40, 20, 40, 20);
    try testing.expectEqual(under, view.toPicture(40, 20));
    try testing.expectEqual(@as(u32, 12), view.nextZoom(true));
    try testing.expectEqual(@as(u32, 6), view.nextZoom(false));
}

test "view: a row at a zoom, the backdrop round it, the grid and the checkerboard" {
    var picture = try made(3, 2, red);
    defer free(picture);
    picture.set(1, 0, blue);
    picture.set(2, 0, 0x00000000);
    var view = View{ .width = 10, .height = 4, .zoom = 2 };
    view.fit(3, 2);
    try testing.expectEqual(@as(i32, 2), view.offset_x);
    var out: [10]Pixel = undefined;
    view.row(&picture, 1, 0, 10, &out);
    try testing.expectEqual(view_zig.backdrop, out[0]);
    try testing.expectEqual(view_zig.backdrop, out[1]);
    try testing.expectEqual(red, out[2]);
    try testing.expectEqual(red, out[3]);
    try testing.expectEqual(blue, out[4]);
    try testing.expectEqual(blue, out[5]);
    // Wholly see-through: the checkerboard's own colour.
    try testing.expect(out[6] == 0xFFFFFFFF or out[6] == 0xFFCCCCCC);
    try testing.expectEqual(view_zig.backdrop, out[8]);

    // At 8 the grid marks each pixel's first column and row.
    var close = View{ .width = 24, .height = 16, .zoom = 8 };
    close.fit(3, 2);
    var line: [24]Pixel = undefined;
    close.row(&picture, 1, 0, 24, &line);
    try testing.expect(line[0] != red);
    try testing.expectEqual(red, line[1]);
    try testing.expect(line[8] != blue);
    try testing.expectEqual(blue, line[9]);
    close.row(&picture, 0, 0, 24, &line);
    try testing.expect(line[1] != red);
    close.grid = false;
    close.row(&picture, 0, 0, 24, &line);
    try testing.expectEqual(red, line[1]);
}
