// SPDX-License-Identifier: MIT
//! Host tests of Paint's workings: the brushes' shapes and what they put
//! down, the shapes, the fill and the spray, undo and redo over a block
//! that fills, and the view's mapping, zoom and rows. The window is not
//! here.

const std = @import("std");
const picture_zig = @import("../picture.zig");
const brush_zig = @import("../brush.zig");
const history_zig = @import("../history.zig");
const view_zig = @import("../view.zig");
const shapes = @import("../shapes.zig");
const fill_zig = @import("../fill.zig");
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

/// Whether the pixel is the colour, for pictures drawn in the tests.
fn at(picture: *const Picture, x: u32, y: u32) Pixel {
    return picture.get(x, y);
}

test "shapes: a rectangle's outline and its filled box, both corners in it" {
    var picture = try made(12, 10, white);
    defer free(picture);
    var changed = Area.none;
    shapes.rectangle(&picture, .{ .size = 1 }, .{ 8, 7 }, .{ 2, 1 }, red, false, &changed);
    try testing.expectEqual(Area{ .min_x = 2, .min_y = 1, .max_x = 9, .max_y = 8 }, changed);
    // The outline: 7 by 7, its inside left alone.
    try testing.expectEqual(@as(usize, 24), count(&picture, red));
    try testing.expectEqual(white, at(&picture, 5, 4));
    try testing.expectEqual(red, at(&picture, 8, 7));

    changed = Area.none;
    shapes.rectangle(&picture, .{ .size = 1 }, .{ -3, -3 }, .{ 1, 1 }, blue, true, &changed);
    try testing.expectEqual(@as(usize, 4), count(&picture, blue));
    try testing.expectEqual(Area{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }, changed);
}

test "shapes: an ellipse fills its box's middles, its outline is its edge" {
    var picture = try made(16, 16, white);
    defer free(picture);
    var changed = Area.none;
    // A box of 3 by 3: a plus.
    shapes.ellipse(&picture, .{ .size = 1 }, .{ 0, 0 }, .{ 2, 2 }, red, true, &changed);
    try testing.expectEqual(@as(usize, 5), count(&picture, red));
    try testing.expectEqual(white, at(&picture, 0, 0));
    try testing.expectEqual(red, at(&picture, 1, 0));
    try testing.expectEqual(red, at(&picture, 0, 1));

    // A circle of 11: every row from its top to its bottom, and as wide as
    // the box in the middle row; its outline leaves the middle open and
    // meets the filled one at the edge.
    picture.fill(white);
    shapes.ellipse(&picture, .{ .size = 1 }, .{ 2, 2 }, .{ 12, 12 }, red, true, &changed);
    const filled = count(&picture, red);
    for (2..13) |y| {
        var in_row: usize = 0;
        for (picture.row(@intCast(y))) |pixel| if (pixel == red) {
            in_row += 1;
        };
        try testing.expect(in_row > 0);
    }
    try testing.expectEqual(red, at(&picture, 2, 7));
    try testing.expectEqual(red, at(&picture, 12, 7));
    try testing.expectEqual(white, at(&picture, 1, 7));
    var rim = try made(16, 16, white);
    defer free(rim);
    shapes.ellipse(&rim, .{ .size = 1 }, .{ 2, 2 }, .{ 12, 12 }, red, false, &changed);
    try testing.expectEqual(white, at(&rim, 7, 7));
    try testing.expect(count(&rim, red) < filled);
    for (0..16) |y| for (0..16) |x| {
        if (at(&rim, @intCast(x), @intCast(y)) == red) try testing.expectEqual(red, at(&picture, @intCast(x), @intCast(y)));
    };
    // A box one row tall is a line; one column wide too.
    picture.fill(white);
    shapes.ellipse(&picture, .{ .size = 1 }, .{ 1, 3 }, .{ 9, 3 }, blue, false, &changed);
    try testing.expectEqual(@as(usize, 9), count(&picture, blue));
    picture.fill(white);
    shapes.ellipse(&picture, .{ .size = 1 }, .{ 4, 0 }, .{ 4, 5 }, blue, true, &changed);
    try testing.expectEqual(@as(usize, 6), count(&picture, blue));
}

test "shapes: a curve from end to end through its bend, a straight one a line" {
    var picture = try made(40, 30, white);
    defer free(picture);
    var changed = Area.none;
    shapes.curve(&picture, .{ .size = 1 }, .{ 2, 20 }, .{ 36, 20 }, .{ 19, 4 }, red, &changed);
    try testing.expectEqual(red, at(&picture, 2, 20));
    try testing.expectEqual(red, at(&picture, 36, 20));
    try testing.expectEqual(red, at(&picture, 19, 4));
    // Nothing on the straight line between the ends' middle.
    try testing.expectEqual(white, at(&picture, 19, 20));

    picture.fill(white);
    shapes.curve(&picture, .{ .size = 1 }, .{ 0, 5 }, .{ 10, 5 }, .{ 5, 5 }, blue, &changed);
    try testing.expectEqual(@as(usize, 11), count(&picture, blue));
}

test "shapes: a polygon's outline closes, filled it takes its inside and its edge" {
    var picture = try made(20, 20, white);
    defer free(picture);
    var changed = Area.none;
    const triangle = [_]shapes.Point{ .{ 2, 2 }, .{ 17, 2 }, .{ 2, 17 } };
    shapes.polygon(&picture, .{ .size = 1 }, &triangle, red, false, &changed);
    try testing.expectEqual(red, at(&picture, 10, 9));
    try testing.expectEqual(red, at(&picture, 2, 10));
    try testing.expectEqual(white, at(&picture, 5, 5));

    picture.fill(white);
    shapes.polygon(&picture, .{ .size = 1 }, &triangle, blue, true, &changed);
    try testing.expectEqual(blue, at(&picture, 5, 5));
    try testing.expectEqual(blue, at(&picture, 17, 2));
    try testing.expectEqual(blue, at(&picture, 2, 17));
    try testing.expectEqual(white, at(&picture, 15, 15));
    try testing.expectEqual(white, at(&picture, 1, 1));
    // Every row from the top corner to the bottom one, without a gap.
    for (2..18) |y| {
        var x: u32 = 2;
        while (x < 20 and at(&picture, x, @intCast(y)) == blue) x += 1;
        try testing.expect(x > 2);
        while (x < 20) : (x += 1) try testing.expectEqual(white, at(&picture, x, @intCast(y)));
    }

    // An open polyline: no closing edge.
    picture.fill(white);
    shapes.polyline(&picture, .{ .size = 1 }, &triangle, red, &changed);
    try testing.expectEqual(white, at(&picture, 2, 10));
    try testing.expectEqual(red, at(&picture, 10, 9));
}

/// A stack for the fill's seeds from the test's allocator, made larger
/// as it fills.
const TestSeeds = struct {
    fn more(seeds: *fill_zig.Seeds) bool {
        const larger = testing.allocator.alloc(fill_zig.Seed, seeds.capacity * 2) catch return false;
        @memcpy(larger[0..seeds.len], seeds.items[0..seeds.len]);
        testing.allocator.free(seeds.items[0..seeds.capacity]);
        seeds.items = larger.ptr;
        seeds.capacity = larger.len;
        return true;
    }
};

test "fill: the joined area made the colour, through every turn, and no further" {
    var picture = try made(16, 12, white);
    defer free(picture);
    var changed = Area.none;
    // A wall with a gap at its bottom, and a closed box.
    shapes.rectangle(&picture, .{ .size = 1 }, .{ 8, 0 }, .{ 8, 9 }, red, false, &changed);
    shapes.rectangle(&picture, .{ .size = 1 }, .{ 10, 2 }, .{ 14, 6 }, red, false, &changed);
    const start = try testing.allocator.alloc(fill_zig.Seed, 2);
    var seeds = fill_zig.Seeds{ .items = start.ptr, .capacity = start.len, .more = TestSeeds.more };
    defer testing.allocator.free(seeds.items[0..seeds.capacity]);
    changed = Area.none;
    try testing.expect(fill_zig.flood(&picture, 1, 1, blue, &seeds, &changed));
    // Round the wall's foot and up the other side; the box's inside not.
    try testing.expectEqual(blue, at(&picture, 9, 0));
    try testing.expectEqual(blue, at(&picture, 15, 11));
    try testing.expectEqual(white, at(&picture, 12, 4));
    try testing.expectEqual(red, at(&picture, 8, 5));
    try testing.expectEqual(Area{ .min_x = 0, .min_y = 0, .max_x = 16, .max_y = 12 }, changed);
    try testing.expect(seeds.capacity > 2);
    // The same colour again changes nothing.
    changed = Area.none;
    try testing.expect(fill_zig.flood(&picture, 1, 1, blue, &seeds, &changed));
    try testing.expect(changed.isEmpty());
}

test "brush: a spray puts its pixels within its reach, and stops at the picture's edge" {
    var picture = try made(40, 40, white);
    defer free(picture);
    var changed = Area.none;
    var random = brush_zig.Random{};
    const brush = Brush{ .size = 4 };
    brush_zig.spray(&picture, brush, 20, 20, red, &random, &changed);
    const reach: i32 = @intCast(brush_zig.sprayRadius(brush));
    try testing.expect(count(&picture, red) > 0);
    try testing.expect(count(&picture, red) <= brush_zig.sprayCount(brush));
    try testing.expect(changed.min_x >= 20 - reach and changed.max_x <= 20 + reach + 1);
    for (0..40) |y| for (0..40) |x| {
        if (at(&picture, @intCast(x), @intCast(y)) != red) continue;
        const dx = @as(i32, @intCast(x)) - 20;
        const dy = @as(i32, @intCast(y)) - 20;
        try testing.expect(dx * dx + dy * dy <= reach * reach);
    };
    // At the corner, only what falls inside.
    changed = Area.none;
    brush_zig.spray(&picture, brush, 0, 0, blue, &random, &changed);
    try testing.expect(changed.min_x >= 0 and changed.min_y >= 0);
}
