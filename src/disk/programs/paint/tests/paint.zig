// SPDX-License-Identifier: MIT
//! Host tests of Paint's workings: the brushes' shapes and what they put
//! down, an own brush cut, inked, shown and transformed, the shapes, the
//! fill and the spray, undo and redo over a block that fills, and the
//! view's mapping, zoom and rows. The window is not here.

const std = @import("std");
const picture_zig = @import("../picture.zig");
const brush_zig = @import("../brush.zig");
const history_zig = @import("../history.zig");
const view_zig = @import("../view.zig");
const shapes = @import("../shapes.zig");
const fill_zig = @import("../fill.zig");
const layers_zig = @import("../layers.zig");
const selection_zig = @import("../selection.zig");
const Selection = selection_zig.Selection;
const Scratch = selection_zig.Scratch;
const Stack = layers_zig.Stack;
const Layer = layers_zig.Layer;
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
const black: Pixel = 0xFF000000;

fn made(width: u32, height: u32, colour: Pixel) !Picture {
    const pixels = try testing.allocator.alloc(Pixel, width * height);
    var picture = Picture{ .pixels = pixels.ptr, .width = width, .height = height };
    picture.fill(colour);
    return picture;
}

fn free(picture: Picture) void {
    testing.allocator.free(picture.pixels[0 .. picture.width * picture.height]);
}

/// An ink of whole paint in `colour` for `picture`, fresh each time.
var test_ink: brush_zig.Ink = undefined;
fn inked(picture: *Picture, colour: Pixel) *brush_zig.Ink {
    test_ink = .{ .picture = picture, .colour = colour };
    return &test_ink;
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
    try testing.expectEqual(@as(u32, 64), (Brush{ .size = 64 }).stepped(true).size);
    // A size between the steps, as the slider sets, goes to the next.
    try testing.expectEqual(@as(u32, 48), (Brush{ .size = 41 }).stepped(true).size);
    try testing.expectEqual(@as(u32, 32), (Brush{ .size = 41 }).stepped(false).size);
    try testing.expectEqual(@as(u32, 1), (Brush{ .size = 1 }).stepped(false).size);
}

test "brush: a stamp cut at the edge, a line with no gaps, the changed area" {
    var picture = try made(20, 10, white);
    defer free(picture);
    var changed = Area.none;
    // A square of 4 at the corner: the part inside, 2 by 2.
    brush_zig.stamp(inked(&picture, red), .{ .shape = .square, .size = 4 }, 0, 0, &changed);
    try testing.expectEqual(@as(usize, 4), count(&picture, red));
    try testing.expectEqual(Area{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }, changed);

    // A steep line of single pixels: one in every row, ends included.
    changed = Area.none;
    brush_zig.line(inked(&picture, blue), .{ .size = 1 }, 15, 0, 18, 9, &changed);
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

test "brush: an own brush cut from the picture, the background left out, held by its middle" {
    var picture = try made(8, 6, white);
    defer free(picture);
    picture.set(2, 1, red);
    picture.set(4, 3, blue);
    var pixels: [3 * 3]Pixel = undefined;
    var own = Picture{ .pixels = &pixels, .width = 3, .height = 3 };
    brush_zig.grab(&picture, shapes.areaOf(.{ 4, 3 }, .{ 2, 1 }), white, &own);
    try testing.expectEqual(red, own.get(0, 0));
    try testing.expectEqual(blue, own.get(2, 2));
    try testing.expectEqual(@as(Pixel, 0), own.get(1, 1));

    const brush = Brush{ .size = 7, .own = &own };
    try testing.expectEqual(@as(u32, 3), brush.width());
    try testing.expectEqual([2]i32{ 9, 19 }, brush.corner(10, 20));
    try testing.expect(brush.covers(0, 0));
    try testing.expect(!brush.covers(1, 1));

    // Its own colours, stamped: the see-through middle leaves the picture.
    var into = try made(5, 5, white);
    defer free(into);
    var changed = Area.none;
    brush_zig.stamp(inked(&into, 0xFF00FF00), brush, 2, 2, &changed);
    try testing.expectEqual(red, into.get(1, 1));
    try testing.expectEqual(blue, into.get(3, 3));
    try testing.expectEqual(white, into.get(2, 2));
    try testing.expectEqual(Area{ .min_x = 1, .min_y = 1, .max_x = 4, .max_y = 4 }, changed);
    // In one colour: its shape in the stroke's.
    var one = brush;
    one.mode = .one_colour;
    brush_zig.stamp(inked(&into, 0xFF00FF00), one, 2, 2, &changed);
    try testing.expectEqual(@as(Pixel, 0xFF00FF00), into.get(1, 1));
    try testing.expectEqual(white, into.get(2, 2));
}

test "brush: a pixel covered in part is laid over, one covered wholly replaced" {
    // Half black over white: grey, wholly covering.
    try testing.expectEqual(@as(Pixel, 0xFF7F7F7F), brush_zig.overlay(0x80000000, white));
    try testing.expectEqual(red, brush_zig.overlay(red, blue));
    try testing.expectEqual(blue, brush_zig.overlay(0x00FF0000, blue));
    // Over nothing, the colour stays and the coverage is its own.
    try testing.expectEqual(@as(Pixel, 0x80FF0000), brush_zig.overlay(0x80FF0000, 0));

    var pixels = [_]Pixel{ 0x80FF0000, 0xFFFF0000 };
    const own = Picture{ .pixels = &pixels, .width = 2, .height = 1 };
    const brush = Brush{ .own = &own, .mode = .one_colour };
    // A colour at half coverage is mixed; at full coverage it replaces,
    // see-through colours too.
    const half = brush.tip(0, 0, 0xFF0000FF).?;
    try testing.expectEqual(@as(Pixel, 0xFF7F7FFF), brush_zig.lay(.{}, .paint, white, half.colour, half.coverage, 0, 0, 0).pixel);
    const whole = brush.tip(1, 0, 0x000000FF).?;
    try testing.expectEqual(@as(Pixel, 0x000000FF), brush_zig.lay(.{}, .paint, white, whole.colour, whole.coverage, 0, 1, 0).pixel);

    // The brush shown under the pointer is what a stamp would make.
    const shown = brush_zig.Ghost.at(brush, 10, 5, 0xFF0000FF, .{}, .paint);
    try testing.expect(shown.crosses(5));
    try testing.expect(!shown.crosses(6));
    try testing.expectEqual(@as(Pixel, 0xFF7F7FFF), shown.shown(9, 5, white));
    try testing.expectEqual(white, shown.shown(11, 5, white));
}

test "brush: flipped, turned a quarter to the right, halved and doubled" {
    // 1 2 3
    // 4 5 6
    var pixels = [_]Pixel{ 1, 2, 3, 4, 5, 6 };
    const own = Picture{ .pixels = &pixels, .width = 3, .height = 2 };
    var out: [12]Pixel = undefined;

    var into = Picture{ .pixels = &out, .width = 3, .height = 2 };
    brush_zig.transform(.flip_across, &own, &into);
    try testing.expectEqualSlices(Pixel, &.{ 3, 2, 1, 6, 5, 4 }, out[0..6]);
    brush_zig.transform(.flip_down, &own, &into);
    try testing.expectEqualSlices(Pixel, &.{ 4, 5, 6, 1, 2, 3 }, out[0..6]);

    try testing.expectEqual([2]u32{ 2, 3 }, brush_zig.transformedSize(.turn, 3, 2).?);
    into = .{ .pixels = &out, .width = 2, .height = 3 };
    brush_zig.transform(.turn, &own, &into);
    try testing.expectEqualSlices(Pixel, &.{ 4, 1, 5, 2, 6, 3 }, out[0..6]);

    try testing.expectEqual([2]u32{ 2, 1 }, brush_zig.transformedSize(.halve, 3, 2).?);
    into = .{ .pixels = &out, .width = 2, .height = 1 };
    brush_zig.transform(.halve, &own, &into);
    try testing.expectEqualSlices(Pixel, &.{ 1, 3 }, out[0..2]);

    into = .{ .pixels = &out, .width = 6, .height = 2 };
    const top = Picture{ .pixels = &pixels, .width = 3, .height = 1 };
    brush_zig.transform(.double, &top, &into);
    try testing.expectEqualSlices(Pixel, &.{ 1, 1, 2, 2, 3, 3, 1, 1, 2, 2, 3, 3 }, out[0..12]);

    // No larger than a brush may be.
    try testing.expect(brush_zig.transformedSize(.double, brush_zig.max_own_side / 2 + 1, 4) == null);
}

test "brush: a soft brush fades to its edge, a turned one turns its box and its pixels" {
    // Round, 9 across: the middle whole, the edge in part, the corner not.
    const soft = Brush{ .size = 9, .softness = 100 };
    try testing.expectEqual(@as(u32, 255), soft.coverage(4, 4));
    const edge = soft.coverage(0, 4);
    try testing.expect(edge > 0 and edge < 255);
    try testing.expectEqual(@as(u32, 0), soft.coverage(0, 0));
    // Hard, as ever.
    try testing.expectEqual(@as(u32, 255), (Brush{ .size = 9 }).coverage(0, 4));

    // A square of 4 turned 45 degrees takes a box of 6, its corner bare
    // and its middle covered; turned 90 it is as it was.
    const diamond = Brush{ .shape = .square, .size = 4, .rotation = 45 };
    try testing.expectEqual([2]u32{ 6, 6 }, diamond.box());
    try testing.expect(!diamond.covers(0, 0));
    try testing.expect(diamond.covers(2, 2));
    try testing.expectEqual([2]u32{ 4, 4 }, (Brush{ .shape = .square, .size = 4, .rotation = 90 }).box());
    // A round brush is never turned.
    try testing.expectEqual([2]u32{ 5, 5 }, (Brush{ .size = 5, .rotation = 30 }).box());

    // An own brush two across, turned a quarter right: its left end on
    // top, as Turn Right makes it.
    var pixels = [_]Pixel{ red, blue };
    const own = Picture{ .pixels = &pixels, .width = 2, .height = 1 };
    const turned = Brush{ .own = &own, .rotation = 90 };
    try testing.expectEqual([2]u32{ 1, 2 }, turned.box());
    try testing.expectEqual(red, turned.tip(0, 0, 0).?.colour);
    try testing.expectEqual(blue, turned.tip(0, 1, 0).?.colour);
}

test "brush: a change never puts more than the opacity on a pixel; the flow builds up to it" {
    var picture = try made(8, 8, white);
    defer free(picture);
    var mask = [_]u8{0} ** 64;
    var changed = Area.none;
    const square = Brush{ .shape = .square, .size = 4 };

    // Half the opacity: half red over white, and no more for a second
    // stamp in the same change.
    var ink = brush_zig.Ink{ .picture = &picture, .colour = red, .settings = .{ .opacity = 50 }, .mask = &mask };
    brush_zig.stamp(&ink, square, 2, 2, &changed);
    try testing.expectEqual(@as(Pixel, 0xFFFF7F7F), picture.get(1, 1));
    brush_zig.stamp(&ink, square, 2, 2, &changed);
    try testing.expectEqual(@as(Pixel, 0xFFFF7F7F), picture.get(1, 1));
    // A new change starts from nothing again.
    brush_zig.clearMask(&mask, 8, changed);
    try testing.expectEqual(@as(u8, 0), mask[9]);

    // Half the flow: half at first, more where the brush goes again.
    picture.fill(white);
    ink.settings = .{ .flow = 50 };
    brush_zig.stamp(&ink, square, 2, 2, &changed);
    try testing.expectEqual(@as(Pixel, 0xFFFF7F7F), picture.get(1, 1));
    brush_zig.stamp(&ink, square, 2, 2, &changed);
    try testing.expect(picture.get(1, 1) & 0xFF < 0x7F);
}

test "brush: dithered paint is whole or none, the eraser takes paint away" {
    var picture = try made(4, 4, white);
    defer free(picture);
    var mask = [_]u8{0} ** 16;
    var changed = Area.none;
    const square = Brush{ .shape = .square, .size = 4 };
    // Half the opacity, dithered: half the pixels red, the rest white.
    var ink = brush_zig.Ink{ .picture = &picture, .colour = red, .settings = .{ .opacity = 50, .dither = true }, .mask = &mask };
    brush_zig.stamp(&ink, square, 2, 2, &changed);
    try testing.expectEqual(@as(usize, 8), count(&picture, red));
    try testing.expectEqual(@as(usize, 8), count(&picture, white));

    // The eraser, whole: see-through; at half: half of it left.
    picture.fill(white);
    @memset(&mask, 0);
    ink = .{ .picture = &picture, .colour = red, .kind = .erase };
    brush_zig.stamp(&ink, .{ .size = 1 }, 0, 0, &changed);
    try testing.expectEqual(@as(Pixel, 0), picture.get(0, 0));
    ink.settings = .{ .opacity = 50 };
    ink.mask = &mask;
    brush_zig.stamp(&ink, .{ .size = 1 }, 1, 0, &changed);
    try testing.expectEqual(@as(Pixel, 0x7FFFFFFF), picture.get(1, 0));
}

test "brush: paint that builds up is stamped a quarter of the brush apart, without gaps; jitter stays near" {
    var picture = try made(40, 12, white);
    defer free(picture);
    var mask = [_]u8{0} ** (40 * 12);
    var changed = Area.none;
    var ink = brush_zig.Ink{ .picture = &picture, .colour = red, .settings = .{ .flow = 50 }, .mask = &mask };
    brush_zig.line(&ink, .{ .shape = .square, .size = 8 }, 4, 5, 35, 5, &changed);
    // Every second pixel stamped: none along the line left white, but
    // the last stamp is short of the end until the line is finished.
    try testing.expectEqual(@as(u32, 32), ink.walked);
    try testing.expectEqual(white, picture.get(38, 5));
    brush_zig.finish(&ink, .{ .shape = .square, .size = 8 }, 35, 5, &changed);
    var x: u32 = 0;
    while (x < 39) : (x += 1) try testing.expect(picture.get(x, 5) != white);

    // Jittered stamps land within the brush's side of where they were put.
    picture.fill(white);
    var random = brush_zig.Random{};
    var jittered = brush_zig.Ink{ .picture = &picture, .colour = red, .settings = .{ .jitter = 100 }, .random = &random };
    for (0..20) |_| {
        var one = Area.none;
        brush_zig.stamp(&jittered, .{ .size = 2 }, 20, 6, &one);
        try testing.expect(one.min_x >= 17 and one.max_x <= 23);
    }
}

test "brush: smudging drags the colours under the brush along" {
    // Red on the left half, white on the right.
    var picture = try made(20, 4, white);
    defer free(picture);
    var y: u32 = 0;
    while (y < 4) : (y += 1) for (0..10) |x| picture.set(@intCast(x), y, red);
    var carried_pixels = [_]Pixel{0} ** 4;
    var carried = Picture{ .pixels = &carried_pixels, .width = 2, .height = 2 };
    const brush = Brush{ .shape = .square, .size = 2 };
    var changed = Area.none;

    // Taken up in the red and dragged two pixels into the white: whole,
    // red goes with it.
    brush_zig.takeUp(&picture, brush, 8, 2, &carried);
    var ink = brush_zig.Ink{ .picture = &picture, .colour = 0 };
    brush_zig.smearLine(&ink, brush, &carried, 8, 2, 12, 2, &changed);
    try testing.expectEqual(red, picture.get(11, 2));

    // At half the flow it thins as it goes.
    picture.fill(white);
    y = 0;
    while (y < 4) : (y += 1) for (0..10) |x| picture.set(@intCast(x), y, red);
    brush_zig.takeUp(&picture, brush, 8, 2, &carried);
    ink = .{ .picture = &picture, .colour = 0, .settings = .{ .flow = 50 } };
    brush_zig.smearLine(&ink, brush, &carried, 8, 2, 14, 2, &changed);
    const near = picture.get(10, 2) & 0xFF;
    const far = picture.get(13, 2) & 0xFF;
    try testing.expect(near < far and far < 0xFF);
}

test "shapes: the frame round what is cut is dashes, black and white, cut to the picture" {
    var picture = try made(12, 10, red);
    defer free(picture);
    var changed = Area.none;
    shapes.frame(&picture, .{ 9, 7 }, .{ 1, 1 }, &changed);
    try testing.expectEqual(Area{ .min_x = 1, .min_y = 1, .max_x = 10, .max_y = 8 }, changed);
    try testing.expectEqual(@as(Pixel, 0xFF000000), picture.get(1, 1));
    try testing.expectEqual(@as(Pixel, 0xFFFFFFFF), picture.get(4, 1));
    // The inside is left alone; the outline of 9 by 7 is all there is.
    try testing.expectEqual(red, picture.get(5, 4));
    try testing.expectEqual(@as(usize, 12 * 10 - (2 * 9 + 2 * 7 - 4)), count(&picture, red));

    changed = Area.none;
    shapes.frame(&picture, .{ -5, -5 }, .{ 40, 40 }, &changed);
    try testing.expect(changed.isEmpty());
}

/// Layers for the tests, `test_side` square: their memory is the pixels,
/// from the testing allocator, which `releaseLayer` gives back.
const test_side = 16;

fn layerOf(stack: *Stack, colour: Pixel) !Layer {
    const picture = try made(test_side, test_side, colour);
    return .{ .picture = picture, .memory = @ptrCast(picture.pixels), .id = stack.newId() };
}

var released: usize = 0;

fn releaseLayer(_: *anyopaque, memory: *anyopaque) void {
    free(.{ .pixels = @ptrCast(@alignCast(memory)), .width = test_side, .height = test_side });
    released += 1;
}

fn freeStack(stack: *Stack) void {
    for (stack.all()) |layer| free(layer.picture);
    stack.count = 0;
}

fn historyOf(memory: []align(4) u8) History {
    return .{ .memory = memory.ptr, .size = memory.len, .release = releaseLayer, .context = undefined };
}

test "history: undone and redone, a new change drops the redo, the oldest go when the block is full" {
    var slots: [layers_zig.max_layers]Layer = undefined;
    var stack = Stack{ .layers = &slots };
    stack.insert(0, try layerOf(&stack, white));
    defer freeStack(&stack);
    const picture = &stack.layers[0].picture;
    const id = stack.layers[0].id;
    var kept = try made(test_side, test_side, white);
    defer free(kept);
    // Room for three records of 4 by 4, not four.
    const room = 3 * History.recordBytes(.{ .max_x = 4, .max_y = 4 }) + 8;
    const memory = try testing.allocator.alignedAlloc(u8, .@"4", room);
    defer testing.allocator.free(memory);
    var history = historyOf(memory);
    defer history.clear();

    const colours = [_]Pixel{ 0xFF000001, 0xFF000002, 0xFF000003, 0xFF000004 };
    for (colours, 0..) |colour, i| {
        var changed = Area.none;
        brush_zig.stamp(inked(picture, colour), .{ .shape = .square, .size = 4 }, @intCast(i * 4 + 2), 2, &changed);
        try testing.expect(history.record(id, picture, &kept, changed));
        try testing.expectEqual(colour, kept.get(@intCast(i * 4), 0));
    }
    // Three can be undone, the first change is kept for good.
    var undone: usize = 0;
    while (history.undo(&stack)) |change| : (undone += 1) {
        try testing.expectEqual(@as(u32, 4), change.area.width());
        try testing.expect(!change.layers);
        kept.copyArea(picture, change.area);
    }
    try testing.expectEqual(@as(usize, 3), undone);
    try testing.expectEqual(colours[0], picture.get(0, 0));
    try testing.expectEqual(white, picture.get(4, 0));

    // Redone, two of them; then a new change, and nothing to redo.
    kept.copyArea(picture, history.redo(&stack).?.area);
    kept.copyArea(picture, history.redo(&stack).?.area);
    try testing.expectEqual(colours[2], picture.get(8, 0));
    try testing.expectEqual(white, picture.get(12, 0));
    var changed = Area.none;
    brush_zig.stamp(inked(picture, red), .{ .size = 1 }, 15, 15, &changed);
    try testing.expect(history.record(id, picture, &kept, changed));
    try testing.expect(!history.canRedo());
    kept.copyArea(picture, history.undo(&stack).?.area);
    try testing.expectEqual(white, picture.get(15, 15));
    try testing.expectEqual(colours[2], picture.get(8, 0));

    // A change larger than the block: kept from then on, nothing to undo.
    changed = Area.none;
    brush_zig.stamp(inked(picture, red), .{ .shape = .square, .size = 16 }, 8, 8, &changed);
    try testing.expect(!history.record(id, picture, &kept, changed));
    try testing.expect(!history.canUndo());
    try testing.expectEqual(red, kept.get(0, 0));
}

test "history: layers put in, painted, moved, deleted and merged down, each undone and done again" {
    released = 0;
    var slots: [layers_zig.max_layers]Layer = undefined;
    var stack = Stack{ .layers = &slots };
    stack.insert(0, try layerOf(&stack, white));
    defer freeStack(&stack);
    const room = 4 * History.recordBytes(.{ .max_x = test_side, .max_y = test_side });
    const memory = try testing.allocator.alignedAlloc(u8, .@"4", room);
    defer testing.allocator.free(memory);
    var history = historyOf(memory);
    defer history.clear();
    const white_id = stack.layers[0].id;

    // A red layer over it, painted; a blue one over that, moved to the
    // bottom.
    stack.insert(1, try layerOf(&stack, 0));
    stack.current = 1;
    try testing.expect(history.layerIn(&stack, 1, false));
    const red_id = stack.layers[1].id;
    try testing.expect(history.remember(red_id, &stack.layers[1].picture, stack.layers[1].picture.whole(), false));
    stack.layers[1].picture.fill(red);
    stack.insert(2, try layerOf(&stack, blue));
    stack.current = 2;
    try testing.expect(history.layerIn(&stack, 2, false));
    const blue_id = stack.layers[2].id;
    stack.move(2, 0);
    try testing.expect(history.moved(2, 0, false));
    try testing.expectEqual(@as(u32, 0), stack.current);
    // Red, now at the top, deleted.
    const red_layer = stack.remove(2);
    try testing.expect(history.layerOut(red_layer, 2, false));
    // White merged down into blue: blue's pixels kept, made white, and
    // white taken out - one step.
    try testing.expect(history.remember(blue_id, &stack.layers[0].picture, stack.layers[0].picture.whole(), false));
    stack.layers[0].picture.fill(white);
    stack.current = 1;
    const white_layer = stack.remove(1);
    try testing.expect(history.layerOut(white_layer, 1, true));
    try testing.expectEqual(@as(u32, 1), stack.count);
    try testing.expectEqual(white, stack.layers[0].picture.get(0, 0));

    // The merge undone in one: white back and painted, blue blue again.
    var change = history.undo(&stack).?;
    try testing.expect(change.layers);
    try testing.expectEqual(@as(u32, 2), stack.count);
    try testing.expectEqual(white_id, stack.layers[1].id);
    try testing.expectEqual(@as(u32, 1), stack.current);
    try testing.expectEqual(blue, stack.layers[0].picture.get(0, 0));
    // Red's deletion: red back at the top.
    change = history.undo(&stack).?;
    try testing.expectEqual(@as(u32, 3), stack.count);
    try testing.expectEqual(red_id, stack.layers[2].id);
    try testing.expectEqual(@as(u32, 2), stack.current);
    // The move: blue back at the top.
    _ = history.undo(&stack).?;
    try testing.expectEqual(blue_id, stack.layers[2].id);
    try testing.expectEqual(white_id, stack.layers[0].id);
    // Blue put in, red painted, red put in: white alone.
    _ = history.undo(&stack).?;
    try testing.expectEqual(@as(u32, 2), stack.count);
    _ = history.undo(&stack).?;
    try testing.expectEqual(@as(u32, 0), stack.layers[1].picture.get(0, 0));
    _ = history.undo(&stack).?;
    try testing.expectEqual(@as(u32, 1), stack.count);
    try testing.expect(!history.canUndo());
    try testing.expectEqual(@as(usize, 0), released);

    // All done again: blue alone, made white by the merge.
    while (history.redo(&stack)) |_| {}
    try testing.expectEqual(@as(u32, 1), stack.count);
    try testing.expectEqual(blue_id, stack.layers[0].id);
    try testing.expectEqual(white, stack.layers[0].picture.get(0, 0));
    try testing.expectEqual(@as(u32, 0), stack.current);

    // Back to the start, and a new change: the layers only the dropped
    // records held, red and blue, are given back.
    while (history.undo(&stack)) |_| {}
    var kept = try made(test_side, test_side, white);
    defer free(kept);
    stack.layers[0].picture.set(0, 0, red);
    try testing.expect(history.record(white_id, &stack.layers[0].picture, &kept, .{ .max_x = 1, .max_y = 1 }));
    try testing.expectEqual(@as(usize, 2), released);
}

test "history: a deleted layer is given back once its deletion can no longer be undone" {
    released = 0;
    var slots: [layers_zig.max_layers]Layer = undefined;
    var stack = Stack{ .layers = &slots };
    stack.insert(0, try layerOf(&stack, white));
    stack.insert(1, try layerOf(&stack, red));
    defer freeStack(&stack);
    // Room for the deletion and a record of the whole picture, not two.
    const room = History.recordBytes(.{ .max_x = test_side, .max_y = test_side }) + 40;
    const memory = try testing.allocator.alignedAlloc(u8, .@"4", room);
    defer testing.allocator.free(memory);
    var history = historyOf(memory);
    defer history.clear();
    try testing.expect(history.layerOut(stack.remove(1), 1, false));
    try testing.expectEqual(@as(usize, 0), released);
    var kept = try made(test_side, test_side, white);
    defer free(kept);
    stack.layers[0].picture.fill(blue);
    try testing.expect(history.record(stack.layers[0].id, &stack.layers[0].picture, &kept, stack.layers[0].picture.whole()));
    try testing.expectEqual(@as(usize, 1), released);
    _ = history.undo(&stack).?;
    try testing.expect(!history.canUndo());
}

test "history: a mask put on, painted, taken off, each undone and done again, then given back" {
    released = 0;
    var slots: [layers_zig.max_layers]Layer = undefined;
    var stack = Stack{ .layers = &slots };
    stack.insert(0, try layerOf(&stack, red));
    defer freeStack(&stack);
    const room = 4 * History.recordBytes(.{ .max_x = test_side, .max_y = test_side });
    const memory = try testing.allocator.alignedAlloc(u8, .@"4", room);
    defer testing.allocator.free(memory);
    var history = historyOf(memory);
    defer history.clear();
    const layer = &stack.layers[0];
    const id = layer.id;
    const corner = Area{ .max_x = 4, .max_y = 4 };

    // A white mask put on, painted black in a corner.
    const mask = try made(test_side, test_side, 0xFFFFFFFF);
    layer.mask = mask;
    layer.mask_memory = @ptrCast(mask.pixels);
    try testing.expect(history.maskIn(id, false));
    try testing.expect(history.remember(id | layers_zig.mask_id, &layer.mask.?, corner, false));
    layer.mask.?.fillArea(corner, black);

    // The painting undone is the mask's, and makes the mask the one
    // painted; then the mask comes off, held by its record.
    var change = history.undo(&stack).?;
    try testing.expectEqual(@as(?bool, true), change.painted_mask);
    try testing.expectEqual(@as(Pixel, 0xFFFFFFFF), mask.get(0, 0));
    change = history.undo(&stack).?;
    try testing.expect(change.layers);
    try testing.expect(layer.mask == null);
    try testing.expectEqual(red, layer.picture.get(0, 0));
    // Both done again.
    _ = history.redo(&stack).?;
    try testing.expect(layer.mask != null);
    _ = history.redo(&stack).?;
    try testing.expectEqual(black, layer.mask.?.get(0, 0));

    // Taken off: undone it is back, done again it is held once more.
    try testing.expect(history.maskOut(id, layer.mask.?, layer.mask_memory.?, false));
    layer.mask = null;
    layer.mask_memory = null;
    _ = history.undo(&stack).?;
    try testing.expectEqual(black, layer.mask.?.get(0, 0));
    _ = history.redo(&stack).?;
    try testing.expect(layer.mask == null);
    try testing.expectEqual(@as(usize, 0), released);
    // The history emptied: the mask its record held is given back.
    history.clear();
    try testing.expectEqual(@as(usize, 1), released);
}

test "layers: a mask hides where it is black or see-through, shows where it is white, a grey in part" {
    var slots: [layers_zig.max_layers]Layer = undefined;
    var stack = Stack{ .layers = &slots };
    stack.insert(0, try layerOf(&stack, white));
    defer freeStack(&stack);
    var mask = try made(test_side, test_side, 0xFFFFFFFF);
    defer free(mask);
    // One layer with a mask needs a composite.
    stack.layers[0].mask = mask;
    try testing.expect(!stack.plain());
    stack.layers[0].mask = null;
    try testing.expect(stack.plain());

    var composite = try made(test_side, test_side, 0);
    defer free(composite);
    stack.composite = composite;
    stack.insert(1, try layerOf(&stack, red));
    mask.fillArea(.{ .max_x = 4, .max_y = 4 }, black);
    mask.fillArea(.{ .min_x = 4, .max_x = 8, .max_y = 4 }, 0xFF808080);
    mask.set(8, 0, 0x00FFFFFF);
    stack.layers[1].mask = mask;
    defer stack.layers[1].mask = null;

    // The ids name the layer's pixels and its mask.
    const id = stack.layers[1].id;
    try testing.expectEqual(&stack.layers[1].picture, stack.pictureOf(id).?);
    try testing.expectEqual(&stack.layers[1].mask.?, stack.pictureOf(id | layers_zig.mask_id).?);
    try testing.expect(stack.pictureOf(stack.layers[0].id | layers_zig.mask_id) == null);
    try testing.expectEqual(@as(?u32, 1), stack.placeOf(id | layers_zig.mask_id));

    stack.compose(composite.whole());
    try testing.expectEqual(white, composite.get(0, 0));
    try testing.expectEqual(@as(Pixel, 0xFFFF7F7F), composite.get(5, 0));
    try testing.expectEqual(white, composite.get(8, 0));
    try testing.expectEqual(red, composite.get(9, 9));
    try testing.expectEqual(composite.get(5, 0), stack.pixelAt(5, 0));

    try testing.expectEqual(@as(u8, 128), layers_zig.shownBy(0xFF808080));
    try testing.expectEqual(@as(u8, 128), layers_zig.shownBy(0x80FFFFFF));
    try testing.expectEqual(@as(Pixel, 0x00FF0000), layers_zig.masked(red, black));
    try testing.expectEqual(red, layers_zig.masked(red, 0xFFFFFFFF));
}

test "layers: each blend mode on a known pair, by opacity and coverage" {
    const grey: Pixel = 0xFF808080;
    const green: Pixel = 0xFF00FF00;
    const blend = layers_zig.blendOver;
    // Over nothing, every mode is the layer at its opacity.
    try testing.expectEqual(@as(Pixel, 0x80FF0000), blend(0, red, .multiply, 50));
    try testing.expectEqual(red, blend(blue, red, .normal, 100));
    try testing.expectEqual(blue, blend(blue, red, .normal, 0));
    try testing.expectEqual(blue, blend(blue, 0x00FF0000, .screen, 100));
    try testing.expectEqual(@as(Pixel, 0xFFFF7F7F), blend(white, red, .normal, 50));
    try testing.expectEqual(@as(Pixel, 0xFFFFFF00), blend(red, green, .add, 100));
    try testing.expectEqual(red, blend(red, white, .multiply, 100));
    try testing.expectEqual(black, blend(red, black, .multiply, 100));
    try testing.expectEqual(red, blend(red, black, .screen, 100));
    try testing.expectEqual(white, blend(red, white, .screen, 100));
    try testing.expectEqual(black, blend(red, green, .darken, 100));
    try testing.expectEqual(@as(Pixel, 0xFFFFFF00), blend(red, green, .lighten, 100));
    // Overlay keeps what is under at its ends; hard light keeps the layer.
    try testing.expectEqual(black, blend(black, grey, .overlay, 100));
    try testing.expectEqual(white, blend(white, grey, .overlay, 100));
    try testing.expectEqual(white, blend(grey, white, .hard_light, 100));
    // Dodge brightens, burn darkens, by the layer.
    try testing.expectEqual(@as(Pixel, 0xFF7F7F7F) | 0, blend(0xFF7F7F7F, black, .colour_dodge, 100));
    try testing.expectEqual(white, blend(grey, white, .colour_dodge, 100));
    try testing.expectEqual(black, blend(grey, black, .colour_burn, 100));
    try testing.expectEqual(grey, blend(grey, white, .colour_burn, 100));
    // Soft light: grey changes nothing, white lightens, black darkens.
    const soft_grey = blend(0xFF404040, grey, .soft_light, 100) & 0xFF;
    try testing.expect(soft_grey >= 0x3F and soft_grey <= 0x41);
    try testing.expect(blend(0xFF404040, white, .soft_light, 100) & 0xFF > 0x40);
    try testing.expect(blend(0xFF404040, black, .soft_light, 100) & 0xFF < 0x40);
    // Luminosity: a grey layer's brightness with what is under's colour;
    // colour: the layer's colour at the brightness under it.
    const lit = blend(red, grey, .luminosity, 100);
    try testing.expect((lit >> 16) & 0xFF > (lit >> 8) & 0xFF);
    try testing.expectEqual(grey, blend(grey, grey, .colour, 100));
    const coloured = blend(grey, red, .colour, 100);
    try testing.expect((coloured >> 16) & 0xFF > coloured & 0xFF);
    // Hue: the layer's hue at what is under's saturation: under grey,
    // grey still.
    try testing.expectEqual(grey, blend(grey, red, .hue, 100));
    try testing.expectEqual(grey, blend(grey, red, .saturation, 100));
    try testing.expectEqual(red, blend(red, green, .saturation, 100));
}

test "layers: the stack plain or composed, layers moved and taken out keep the one painted" {
    var slots: [layers_zig.max_layers]Layer = undefined;
    var stack = Stack{ .layers = &slots };
    stack.insert(0, try layerOf(&stack, white));
    defer freeStack(&stack);
    try testing.expect(stack.plain());
    try testing.expectEqual(&stack.layers[0].picture, stack.shown());
    var composite = try made(test_side, test_side, 0);
    defer free(composite);
    stack.composite = composite;
    // Half red over white in a corner, a hidden blue over all.
    stack.insert(1, try layerOf(&stack, 0));
    stack.layers[1].picture.fillArea(.{ .max_x = 4, .max_y = 4 }, red);
    stack.layers[1].opacity = 50;
    stack.insert(2, try layerOf(&stack, blue));
    stack.layers[2].shown = false;
    try testing.expect(!stack.plain());
    stack.compose(stack.layers[0].picture.whole());
    try testing.expectEqual(@as(Pixel, 0xFFFF7F7F), composite.get(0, 0));
    try testing.expectEqual(white, composite.get(8, 8));
    try testing.expectEqual(composite.get(0, 0), stack.pixelAt(0, 0));
    // Shown, the blue covers all, but only where it is composed again.
    stack.layers[2].shown = true;
    stack.compose(.{ .max_x = 2, .max_y = 2 });
    try testing.expectEqual(blue, composite.get(1, 1));
    try testing.expectEqual(@as(Pixel, 0xFFFF7F7F), composite.get(3, 3));

    // The painted layer stays itself as layers move and go.
    stack.current = 1;
    const painted = stack.layers[1].id;
    stack.move(2, 0);
    try testing.expectEqual(painted, stack.currentLayer().id);
    stack.move(1, 2);
    try testing.expectEqual(painted, stack.currentLayer().id);
    const top = stack.remove(2);
    free(top.picture);
    try testing.expectEqual(@as(u32, 1), stack.current);
    const bottom = stack.remove(0);
    free(bottom.picture);
    try testing.expectEqual(@as(u32, 0), stack.current);
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

test "view: fitted, the largest zoom the whole picture shows at; dragged, the picture follows the hand" {
    var view = View{ .width = 100, .height = 50 };
    try testing.expectEqual(@as(u32, 2), view.fitZoom(40, 20));
    try testing.expectEqual(@as(u32, 12), view.fitZoom(8, 4));
    try testing.expectEqual(@as(u32, 16), view.fitZoom(1, 1));
    // Larger than the view: shown as it is.
    try testing.expectEqual(@as(u32, 1), view.fitZoom(200, 20));

    // At 4 the 40 by 20 picture is 160 by 80: dragged 8 view pixels to the
    // left and 4 up, it moves 2 picture pixels and 1.
    view.zoom = 4;
    view.left = 5;
    view.top = 5;
    view.fit(40, 20);
    view.panTo(.{ 5, 5 }, .{ 50, 20 }, .{ 42, 16 }, 40, 20);
    try testing.expectEqual(@as(i32, 7), view.left);
    try testing.expectEqual(@as(i32, 6), view.top);
    // Dragged far, it stops where the picture's edge meets the view's.
    view.panTo(.{ 5, 5 }, .{ 50, 20 }, .{ 950, -500 }, 40, 20);
    try testing.expectEqual(@as(i32, 0), view.left);
    try testing.expectEqual(@as(i32, 8), view.top);
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
    view.row(&picture, 1, 0, 10, &out, null, null);
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
    close.row(&picture, 1, 0, 24, &line, null, null);
    try testing.expect(line[0] != red);
    try testing.expectEqual(red, line[1]);
    try testing.expect(line[8] != blue);
    try testing.expectEqual(blue, line[9]);
    close.row(&picture, 0, 0, 24, &line, null, null);
    try testing.expect(line[1] != red);
    close.grid = false;
    close.row(&picture, 0, 0, 24, &line, null, null);
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
    shapes.rectangle(inked(&picture, red), .{ .size = 1 }, .{ 8, 7 }, .{ 2, 1 }, false, &changed);
    try testing.expectEqual(Area{ .min_x = 2, .min_y = 1, .max_x = 9, .max_y = 8 }, changed);
    // The outline: 7 by 7, its inside left alone.
    try testing.expectEqual(@as(usize, 24), count(&picture, red));
    try testing.expectEqual(white, at(&picture, 5, 4));
    try testing.expectEqual(red, at(&picture, 8, 7));

    changed = Area.none;
    shapes.rectangle(inked(&picture, blue), .{ .size = 1 }, .{ -3, -3 }, .{ 1, 1 }, true, &changed);
    try testing.expectEqual(@as(usize, 4), count(&picture, blue));
    try testing.expectEqual(Area{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }, changed);
}

test "shapes: an ellipse fills its box's middles, its outline is its edge" {
    var picture = try made(16, 16, white);
    defer free(picture);
    var changed = Area.none;
    // A box of 3 by 3: a plus.
    shapes.ellipse(inked(&picture, red), .{ .size = 1 }, .{ 0, 0 }, .{ 2, 2 }, true, &changed);
    try testing.expectEqual(@as(usize, 5), count(&picture, red));
    try testing.expectEqual(white, at(&picture, 0, 0));
    try testing.expectEqual(red, at(&picture, 1, 0));
    try testing.expectEqual(red, at(&picture, 0, 1));

    // A circle of 11: every row from its top to its bottom, and as wide as
    // the box in the middle row; its outline leaves the middle open and
    // meets the filled one at the edge.
    picture.fill(white);
    shapes.ellipse(inked(&picture, red), .{ .size = 1 }, .{ 2, 2 }, .{ 12, 12 }, true, &changed);
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
    shapes.ellipse(inked(&rim, red), .{ .size = 1 }, .{ 2, 2 }, .{ 12, 12 }, false, &changed);
    try testing.expectEqual(white, at(&rim, 7, 7));
    try testing.expect(count(&rim, red) < filled);
    for (0..16) |y| for (0..16) |x| {
        if (at(&rim, @intCast(x), @intCast(y)) == red) try testing.expectEqual(red, at(&picture, @intCast(x), @intCast(y)));
    };
    // A box one row tall is a line; one column wide too.
    picture.fill(white);
    shapes.ellipse(inked(&picture, blue), .{ .size = 1 }, .{ 1, 3 }, .{ 9, 3 }, false, &changed);
    try testing.expectEqual(@as(usize, 9), count(&picture, blue));
    picture.fill(white);
    shapes.ellipse(inked(&picture, blue), .{ .size = 1 }, .{ 4, 0 }, .{ 4, 5 }, true, &changed);
    try testing.expectEqual(@as(usize, 6), count(&picture, blue));
}

test "shapes: a curve from end to end through its bend, a straight one a line" {
    var picture = try made(40, 30, white);
    defer free(picture);
    var changed = Area.none;
    shapes.curve(inked(&picture, red), .{ .size = 1 }, .{ 2, 20 }, .{ 36, 20 }, .{ 19, 4 }, &changed);
    try testing.expectEqual(red, at(&picture, 2, 20));
    try testing.expectEqual(red, at(&picture, 36, 20));
    try testing.expectEqual(red, at(&picture, 19, 4));
    // Nothing on the straight line between the ends' middle.
    try testing.expectEqual(white, at(&picture, 19, 20));

    picture.fill(white);
    shapes.curve(inked(&picture, blue), .{ .size = 1 }, .{ 0, 5 }, .{ 10, 5 }, .{ 5, 5 }, &changed);
    try testing.expectEqual(@as(usize, 11), count(&picture, blue));
}

test "shapes: a polygon's outline closes, filled it takes its inside and its edge" {
    var picture = try made(20, 20, white);
    defer free(picture);
    var changed = Area.none;
    const triangle = [_]shapes.Point{ .{ 2, 2 }, .{ 17, 2 }, .{ 2, 17 } };
    shapes.polygon(inked(&picture, red), .{ .size = 1 }, &triangle, false, &changed);
    try testing.expectEqual(red, at(&picture, 10, 9));
    try testing.expectEqual(red, at(&picture, 2, 10));
    try testing.expectEqual(white, at(&picture, 5, 5));

    picture.fill(white);
    shapes.polygon(inked(&picture, blue), .{ .size = 1 }, &triangle, true, &changed);
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
    shapes.polyline(inked(&picture, red), .{ .size = 1 }, &triangle, &changed);
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
    shapes.rectangle(inked(&picture, red), .{ .size = 1 }, .{ 8, 0 }, .{ 8, 9 }, false, &changed);
    shapes.rectangle(inked(&picture, red), .{ .size = 1 }, .{ 10, 2 }, .{ 14, 6 }, false, &changed);
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
    brush_zig.spray(inked(&picture, red), brush, 20, 20, &random, &changed);
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
    brush_zig.spray(inked(&picture, blue), brush, 0, 0, &random, &changed);
    try testing.expect(changed.min_x >= 0 and changed.min_y >= 0);
}

/// A selection and a scratch mask for a picture `width` by `height`.
const Choosing = struct {
    selection: Selection,
    scratch: Scratch,

    fn of(width: u32, height: u32) !Choosing {
        const bytes = @as(usize, width) * height;
        const mask = try testing.allocator.alloc(u8, bytes);
        @memset(mask, 0);
        const scratch = try testing.allocator.alloc(u8, bytes);
        @memset(scratch, 0);
        return .{
            .selection = .{ .mask = mask, .width = width, .height = height },
            .scratch = .{ .mask = scratch, .width = width, .height = height },
        };
    }

    fn deinit(choosing: Choosing) void {
        testing.allocator.free(choosing.selection.mask);
        testing.allocator.free(choosing.scratch.mask);
    }

    fn scratchEmpty(choosing: *const Choosing) bool {
        for (choosing.scratch.mask) |part| if (part != 0) return false;
        return true;
    }
};

test "selection: rectangles put in place, added and taken away, inverted and cleared" {
    var choosing = try Choosing.of(16, 12);
    defer choosing.deinit();
    const selection = &choosing.selection;
    try testing.expect(!selection.any());
    choosing.scratch.rectangle(.{ .min_x = 2, .min_y = 2, .max_x = 6, .max_y = 5 });
    selection.take(&choosing.scratch, .replace);
    try testing.expect(choosing.scratchEmpty());
    try testing.expectEqual(Area{ .min_x = 2, .min_y = 2, .max_x = 6, .max_y = 5 }, selection.box);
    try testing.expectEqual(@as(u8, 255), selection.at(2, 2));
    try testing.expectEqual(@as(u8, 0), selection.at(6, 2));
    // Another added, reaching past the picture: cut to it.
    choosing.scratch.rectangle(.{ .min_x = 10, .min_y = 8, .max_x = 40, .max_y = 40 });
    selection.take(&choosing.scratch, .add);
    try testing.expectEqual(Area{ .min_x = 2, .min_y = 2, .max_x = 16, .max_y = 12 }, selection.box);
    try testing.expectEqual(@as(u8, 255), selection.at(3, 3));
    // Taken away: the second again, and the box shrinks to the first.
    choosing.scratch.rectangle(.{ .min_x = 8, .min_y = 6, .max_x = 16, .max_y = 12 });
    selection.take(&choosing.scratch, .take);
    try testing.expectEqual(Area{ .min_x = 2, .min_y = 2, .max_x = 6, .max_y = 5 }, selection.box);
    // In place of what was.
    choosing.scratch.rectangle(.{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 });
    selection.take(&choosing.scratch, .replace);
    try testing.expectEqual(Area{ .max_x = 1, .max_y = 1 }, selection.box);
    try testing.expectEqual(@as(u8, 0), selection.at(3, 3));
    selection.invert();
    try testing.expectEqual(@as(u8, 0), selection.at(0, 0));
    try testing.expectEqual(@as(u8, 255), selection.at(1, 0));
    try testing.expectEqual(Area{ .max_x = 16, .max_y = 12 }, selection.box);
    selection.clear();
    try testing.expect(!selection.any());
    for (selection.mask) |part| try testing.expectEqual(@as(u8, 0), part);
    selection.all();
    try testing.expectEqual(@as(u8, 255), selection.at(15, 11));
}

test "selection: a lasso's shape, the wand's joined colour, a colour, alpha and the palette" {
    var picture = try made(16, 12, white);
    defer free(picture);
    var choosing = try Choosing.of(16, 12);
    defer choosing.deinit();
    const selection = &choosing.selection;
    // A triangle: pixels whose middles it holds.
    choosing.scratch.polygon(&.{ .{ 0, 0 }, .{ 10, 0 }, .{ 0, 10 } });
    selection.take(&choosing.scratch, .replace);
    try testing.expectEqual(@as(u8, 255), selection.at(1, 1));
    try testing.expectEqual(@as(u8, 0), selection.at(8, 8));
    try testing.expectEqual(@as(i32, 0), selection.box.min_x);
    try testing.expect(choosing.scratchEmpty());
    // A red wall down the middle: the wand on the left takes the left.
    picture.fillArea(.{ .min_x = 8, .max_x = 9, .max_y = 12 }, red);
    picture.set(12, 4, red);
    const start = try testing.allocator.alloc(fill_zig.Seed, 2);
    var seeds = fill_zig.Seeds{ .items = start.ptr, .capacity = start.len, .more = TestSeeds.more };
    defer testing.allocator.free(seeds.items[0..seeds.capacity]);
    try testing.expect(choosing.scratch.wand(&picture, 1, 1, &seeds));
    selection.take(&choosing.scratch, .replace);
    try testing.expectEqual(Area{ .max_x = 8, .max_y = 12 }, selection.box);
    try testing.expectEqual(@as(u8, 0), selection.at(10, 1));
    // Every red pixel, joined or not.
    choosing.scratch.colour(&picture, red);
    selection.take(&choosing.scratch, .replace);
    try testing.expectEqual(Area{ .min_x = 8, .max_x = 13, .max_y = 12 }, selection.box);
    try testing.expectEqual(@as(u8, 255), selection.at(12, 4));
    try testing.expectEqual(@as(u8, 0), selection.at(11, 4));
    // As far as a pixel is there; what is see-through.
    picture.set(3, 3, 0x40000000);
    picture.set(4, 3, 0);
    choosing.scratch.alpha(&picture, false);
    selection.take(&choosing.scratch, .replace);
    try testing.expectEqual(@as(u8, 0x40), selection.at(3, 3));
    try testing.expectEqual(@as(u8, 0), selection.at(4, 3));
    choosing.scratch.alpha(&picture, true);
    selection.take(&choosing.scratch, .replace);
    try testing.expectEqual(Area{ .min_x = 3, .min_y = 3, .max_x = 5, .max_y = 4 }, selection.box);
    // Not in a palette of white: the red, and the dim pixel.
    choosing.scratch.notIn(&picture, &.{white});
    selection.take(&choosing.scratch, .replace);
    try testing.expectEqual(@as(u8, 255), selection.at(8, 0));
    try testing.expectEqual(@as(u8, 255), selection.at(3, 3));
    try testing.expectEqual(@as(u8, 0), selection.at(4, 3));
    try testing.expectEqual(@as(u8, 0), selection.at(0, 0));
}

test "selection: the stencil keeps a change inside, puts back outside, and mixes a part" {
    var picture = try made(8, 4, white);
    defer free(picture);
    var kept = try made(8, 4, white);
    defer free(kept);
    var choosing = try Choosing.of(8, 4);
    defer choosing.deinit();
    const selection = &choosing.selection;
    // With nothing chosen the change stays whole.
    picture.fill(red);
    selection.stencil(&picture, &kept, picture.whole());
    try testing.expectEqual(red, picture.get(7, 3));
    choosing.scratch.rectangle(.{ .min_x = 2, .min_y = 1, .max_x = 4, .max_y = 3 });
    selection.take(&choosing.scratch, .replace);
    selection.mask[1 * 8 + 3] = 128;
    selection.stencil(&picture, &kept, picture.whole());
    try testing.expectEqual(red, picture.get(2, 1));
    try testing.expectEqual(white, picture.get(1, 1));
    try testing.expectEqual(white, picture.get(0, 0));
    try testing.expectEqual(@as(Pixel, 0xFFFF7F7F), picture.get(3, 1));
    // The outline: the chosen pixels, half and more.
    const outline = selection.outline();
    try testing.expect(outline.chosen(3, 1));
    try testing.expect(!outline.chosen(4, 1));
    try testing.expect(!outline.chosen(-1, 1));
}

test "view: the outline of what is chosen in dashes over the rows" {
    var picture = try made(8, 8, red);
    defer free(picture);
    var choosing = try Choosing.of(8, 8);
    defer choosing.deinit();
    choosing.scratch.rectangle(.{ .min_x = 2, .min_y = 2, .max_x = 6, .max_y = 6 });
    choosing.selection.take(&choosing.scratch, .replace);
    const outline = choosing.selection.outline();
    var view = View{ .width = 8, .height = 8, .grid = false };
    view.fit(8, 8);
    var line: [8]Pixel = undefined;
    // Inside, a row away from the edge: only its ends are dashes.
    view.row(&picture, 3, 0, 8, &line, null, &outline);
    try testing.expectEqual(red, line[1]);
    try testing.expect(line[2] == 0xFF000000 or line[2] == 0xFFFFFFFF);
    try testing.expectEqual(red, line[3]);
    try testing.expect(line[5] == 0xFF000000 or line[5] == 0xFFFFFFFF);
    // The top edge: dashes all along it.
    view.row(&picture, 2, 0, 8, &line, null, &outline);
    for (line[2..6]) |pixel| try testing.expect(pixel == 0xFF000000 or pixel == 0xFFFFFFFF);
    try testing.expectEqual(red, line[6]);
    // At a zoom of 2 a chosen pixel's inner half is no edge: the lower
    // half of the top row chosen, its first pixel's left half a dash.
    view.zoom = 2;
    view.fit(8, 8);
    view.row(&picture, 5, 0, 8, &line, null, &outline);
    try testing.expect(line[4] == 0xFF000000 or line[4] == 0xFFFFFFFF);
    try testing.expectEqual(red, line[5]);
}
