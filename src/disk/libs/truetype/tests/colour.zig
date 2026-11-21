// SPDX-License-Identifier: MIT
//! Host tests of truetype.library's glyphs in colour, on tables built
//! here and put into a built font beside its outlines:
//!
//! - `GlyphPaints` of the first version of `COLR`: each layer its glyph
//!   filled with its colour from `CPAL`, the text's own for 0xFFFF and
//!   for a colour the palette lacks; counted without room, and written
//!   only as far as the room goes.
//! - Of the second version: a glyph filled with a gradient, its stops
//!   sorted and spread over 0 to 1 and its line moved with them; a
//!   composite as two layers inside the clip box the list gives; a glyph
//!   inside another's outline; a glyph that draws itself, no drawing.
//! - `GlyphDocument`: the document of a glyph alone and of a range, none
//!   for a glyph no record holds or one past the table.
//! - `GlyphPicture` of `sbix`: the largest strike that has the glyph, a
//!   `dupe` followed in a smaller one, a file of another kind, where the
//!   picture goes; of `CBDT`, a font of pictures alone.

const std = @import("std");
const sdk = @import("sdk");
const truetype = sdk.truetype;
const builder = @import("builder.zig");
const built = @import("truetype.zig");
const strike = @import("strike.zig");

const testing = std.testing;
const File = builder.File;
const Rig = built.Rig;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;

/// A font of the built kind with `more` beside its own tables.
fn fontWith(file: *File, more: []const builder.Table) void {
    var cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    cmap.segments(&.{.{ .first = 0xFFFF, .last = 0xFFFF, .delta = 1 }});
    _ = builder.font(file, .{ .cmap = cmap.written(), .more = more });
}

/// One palette of two colours, blue, green, red and alpha: orange, and
/// a half-seen blue.
fn palette(file: *File) void {
    file.word(0);
    file.word(2);
    file.word(1);
    file.word(2);
    file.long(14);
    file.word(0);
    file.text(&.{ 0x00, 0x80, 0xFF, 0xFF });
    file.text(&.{ 0xFF, 0x00, 0x00, 0x80 });
}

/// An offset of 24 bits written where it was left open.
fn setTriple(file: *File, where: u32, value: u32) void {
    file.bytes[where] = @truncate(value >> 16);
    file.setWord(where + 1, @truncate(value));
}

fn expectNear(expected: f32, got: f32) !void {
    try testing.expectApproxEqAbs(expected, got, 0.002);
}

fn expectColour(step: truetype.PaintStep, red: f32, green: f32, blue: f32, alpha: f32) !void {
    try testing.expectEqual(@as(u32, 0), step.flags);
    try expectNear(red, step.red);
    try expectNear(green, step.green);
    try expectNear(blue, step.blue);
    try expectNear(alpha, step.alpha);
}

test "colour layers of the first version: each glyph filled with its colour, the text's own where the palette has none" {
    var rig = try Rig.up();
    const tb = rig.tb;

    // Glyph 1 of three layers, glyph 6 of one.
    var colr: File = .{};
    colr.word(0);
    colr.word(2);
    colr.long(14);
    colr.long(26);
    colr.word(4);
    for ([_][3]u16{ .{ 1, 0, 3 }, .{ 6, 3, 1 } }) |record| for (record) |value| colr.word(value);
    for ([_][2]u16{ .{ 2, 0 }, .{ 3, 0xFFFF }, .{ 4, 5 }, .{ 2, 1 } }) |layer| for (layer) |value| colr.word(value);
    var cpal: File = .{};
    palette(&cpal);
    var file: File = .{};
    fontWith(&file, &.{ .{ .tag = "COLR", .bytes = colr.written() }, .{ .tag = "CPAL", .bytes = cpal.written() } });
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;

    try testing.expectEqual(@as(u32, 3), tb.GlyphPaints(outline, 1, null, 0));
    var steps: [4]truetype.PaintStep = @splat(.{ .kind = 99 });
    try testing.expectEqual(@as(u32, 3), tb.GlyphPaints(outline, 1, &steps, steps.len));
    for (steps[0..3], [_]u32{ 2, 3, 4 }) |step, glyph| {
        try testing.expectEqual(truetype.STEP_FILL_GLYPH, step.kind);
        try testing.expectEqual(glyph, step.glyph);
        try testing.expectEqual(truetype.BRUSH_SOLID, step.brush);
    }
    try expectColour(steps[0], 1, 128.0 / 255.0, 0, 1);
    try testing.expectEqual(truetype.STEPF_FOREGROUND, steps[1].flags);
    try testing.expectEqual(truetype.STEPF_FOREGROUND, steps[2].flags);
    try expectNear(1, steps[2].alpha);
    try testing.expectEqual(@as(u32, 99), steps[3].kind);

    // As far as the room goes, the count whole.
    var one: [2]truetype.PaintStep = @splat(.{ .kind = 99 });
    try testing.expectEqual(@as(u32, 3), tb.GlyphPaints(outline, 1, &one, 1));
    try testing.expectEqual(@as(u32, 2), one[0].glyph);
    try testing.expectEqual(@as(u32, 99), one[1].kind);

    try testing.expectEqual(@as(u32, 1), tb.GlyphPaints(outline, 6, &steps, steps.len));
    try expectColour(steps[0], 0, 0, 1, 128.0 / 255.0);
    // Glyphs the table does not have, and one past the font.
    try testing.expectEqual(@as(u32, 0), tb.GlyphPaints(outline, 5, null, 0));
    try testing.expectEqual(@as(u32, 0), tb.GlyphPaints(outline, 9, null, 0));
    tb.CloseOutline(outline);
    try rig.down();
}

/// A table of the second version: glyph 1 filled with a gradient, glyph
/// 2 a composite in a clip box, glyph 3 drawing itself, glyph 4 a glyph
/// inside another's outline.
fn secondVersion(colr: *File) void {
    colr.word(1);
    colr.skip(12);
    colr.long(34);
    colr.long(0);
    const clip_offset = colr.len;
    colr.skip(4);
    colr.long(0);
    colr.long(0);

    // The list of base glyphs, each record's offset from it.
    const list = colr.len;
    colr.long(4);
    var records: [4]u32 = undefined;
    for (&records, 1..) |*record, glyph| {
        colr.word(@intCast(glyph));
        record.* = colr.len;
        colr.skip(4);
    }

    // 1: glyph 2 in a gradient from (0, 0) to (100, 0), its stops at 0.75
    // and 0.25.
    colr.setLong(records[0], colr.len - list);
    const glyph_paint = colr.len;
    colr.byte(10);
    colr.skip(3);
    colr.word(2);
    setTriple(colr, glyph_paint + 1, colr.len - glyph_paint);
    const linear = colr.len;
    colr.byte(4);
    colr.skip(3);
    for ([_]i16{ 0, 0, 100, 0, 0, 100 }) |value| colr.signed(value);
    setTriple(colr, linear + 1, colr.len - linear);
    colr.byte(2);
    colr.word(2);
    for ([_][3]u16{ .{ 0x3000, 0, 0x4000 }, .{ 0x1000, 1, 0x2000 } }) |stop| for (stop) |value| colr.word(value);

    // 2: a composite, the source a colour put down in the backdrop -
    // glyph 3 in the other colour.
    colr.setLong(records[1], colr.len - list);
    const composite = colr.len;
    colr.byte(32);
    colr.skip(3);
    colr.byte(@intCast(truetype.COMPOSE_SOURCE_IN));
    colr.skip(3);
    setTriple(colr, composite + 1, colr.len - composite);
    colr.byte(2);
    colr.word(0);
    colr.word(0x4000);
    setTriple(colr, composite + 5, colr.len - composite);
    const backdrop = colr.len;
    colr.byte(10);
    colr.skip(3);
    colr.word(3);
    setTriple(colr, backdrop + 1, colr.len - backdrop);
    colr.byte(2);
    colr.word(1);
    colr.word(0x4000);

    // 3: itself.
    colr.setLong(records[2], colr.len - list);
    colr.byte(11);
    colr.word(3);

    // 4: glyph 6 in the outline of glyph 5.
    colr.setLong(records[3], colr.len - list);
    const outer = colr.len;
    colr.byte(10);
    colr.skip(3);
    colr.word(5);
    setTriple(colr, outer + 1, colr.len - outer);
    const inner = colr.len;
    colr.byte(10);
    colr.skip(3);
    colr.word(6);
    setTriple(colr, inner + 1, colr.len - inner);
    colr.byte(2);
    colr.word(0);
    colr.word(0x4000);

    // The clip list: a box for glyph 2.
    colr.setLong(clip_offset, colr.len);
    const clips = colr.len;
    colr.byte(1);
    colr.long(1);
    colr.word(2);
    colr.word(2);
    const box_offset = colr.len;
    colr.skip(3);
    setTriple(colr, box_offset, colr.len - clips);
    colr.byte(1);
    for ([_]i16{ -10, -20, 510, 720 }) |value| colr.signed(value);
}

test "colour layers of the second version: a gradient, a composite in its clip box, a glyph in another's outline, a circle" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var colr: File = .{};
    secondVersion(&colr);
    var cpal: File = .{};
    palette(&cpal);
    var file: File = .{};
    fontWith(&file, &.{ .{ .tag = "COLR", .bytes = colr.written() }, .{ .tag = "CPAL", .bytes = cpal.written() } });
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    var steps: [12]truetype.PaintStep = undefined;

    // The gradient: its stops sorted, spread from 0 to 1, and its line
    // from a quarter of the way to three quarters.
    try testing.expectEqual(@as(u32, 3), tb.GlyphPaints(outline, 1, &steps, steps.len));
    try testing.expectEqual(truetype.STEP_FILL_GLYPH, steps[0].kind);
    try testing.expectEqual(@as(u32, 2), steps[0].glyph);
    try testing.expectEqual(truetype.BRUSH_LINEAR, steps[0].brush);
    try testing.expectEqual(truetype.EXTEND_REFLECT, steps[0].extend);
    try testing.expectEqual(@as(u32, 2), steps[0].stop_count);
    try expectNear(25, steps[0].x0);
    try expectNear(0, steps[0].y0);
    try expectNear(75, steps[0].x1);
    try expectNear(0, steps[0].y1);
    try testing.expectEqual(truetype.STEP_STOP, steps[1].kind);
    try expectNear(0, steps[1].offset);
    try expectColour(steps[1], 0, 0, 1, 0.5 * 128.0 / 255.0);
    try expectNear(1, steps[2].offset);
    try expectColour(steps[2], 1, 128.0 / 255.0, 0, 1);

    // The composite: in its box, the backdrop's layer and the source's
    // on it.
    const kinds = [_]u32{ truetype.STEP_PUSH_CLIP_BOX, truetype.STEP_PUSH_LAYER, truetype.STEP_FILL_GLYPH, truetype.STEP_PUSH_LAYER, truetype.STEP_FILL, truetype.STEP_POP_LAYER, truetype.STEP_POP_LAYER, truetype.STEP_POP_CLIP };
    try testing.expectEqual(@as(u32, kinds.len), tb.GlyphPaints(outline, 2, &steps, steps.len));
    for (kinds, steps[0..kinds.len]) |kind, step| try testing.expectEqual(kind, step.kind);
    try expectNear(-10, steps[0].x0);
    try expectNear(-20, steps[0].y0);
    try expectNear(510, steps[0].x1);
    try expectNear(720, steps[0].y1);
    try testing.expectEqual(truetype.COMPOSE_SOURCE_OVER, steps[1].mode);
    try testing.expectEqual(@as(u32, 3), steps[2].glyph);
    try expectColour(steps[2], 0, 0, 1, 128.0 / 255.0);
    try testing.expectEqual(truetype.COMPOSE_SOURCE_IN, steps[3].mode);
    try expectColour(steps[4], 1, 128.0 / 255.0, 0, 1);

    // A glyph that draws itself is no drawing.
    try testing.expectEqual(@as(u32, 0), tb.GlyphPaints(outline, 3, &steps, steps.len));

    // A glyph inside another's outline: the outline a clip.
    try testing.expectEqual(@as(u32, 3), tb.GlyphPaints(outline, 4, &steps, steps.len));
    try testing.expectEqual(truetype.STEP_PUSH_CLIP_GLYPH, steps[0].kind);
    try testing.expectEqual(@as(u32, 5), steps[0].glyph);
    try testing.expectEqual(truetype.STEP_FILL_GLYPH, steps[1].kind);
    try testing.expectEqual(@as(u32, 6), steps[1].glyph);
    try testing.expectEqual(truetype.STEP_POP_CLIP, steps[2].kind);
    tb.CloseOutline(outline);
    try rig.down();
}

test "SVG documents: of one glyph, of a range, of none" {
    var rig = try Rig.up();
    const tb = rig.tb;

    const alone = "<svg id=\"glyph1\"/>";
    const shared = "<svg><g id=\"glyph3\"/><g id=\"glyph4\"/></svg>";
    var table: File = .{};
    table.word(0);
    table.long(10);
    table.long(0);
    const list = table.len;
    table.word(3);
    const records = table.len;
    table.skip(3 * 12);
    for ([_][2]u16{ .{ 1, 1 }, .{ 3, 5 }, .{ 7, 7 } }, [_][]const u8{ alone, shared, "" }, 0..) |range, text, nth| {
        const record: u32 = records + @as(u32, @intCast(nth)) * 12;
        table.setWord(record, range[0]);
        table.setWord(record + 2, range[1]);
        table.setLong(record + 4, table.len - list);
        // The last one's runs past the table.
        table.setLong(record + 8, if (text.len == 0) 100 else @intCast(text.len));
        table.text(text);
    }
    var file: File = .{};
    fontWith(&file, &.{.{ .tag = "SVG ", .bytes = table.written() }});
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;

    var document: truetype.Document = undefined;
    try testing.expect(tb.GlyphDocument(outline, 1, &document));
    try testing.expectEqualStrings(alone, document.bytes.?[0..document.size]);
    try testing.expectEqual(@as(u32, 1), document.first);
    try testing.expectEqual(@as(u32, 1), document.last);
    try testing.expect(tb.GlyphDocument(outline, 4, &document));
    try testing.expectEqualStrings(shared, document.bytes.?[0..document.size]);
    try testing.expectEqual(@as(u32, 3), document.first);
    try testing.expectEqual(@as(u32, 5), document.last);
    for ([_]u32{ 2, 6, 7 }) |glyph| {
        try testing.expect(!tb.GlyphDocument(outline, glyph, &document));
        try testing.expect(document.bytes == null);
    }
    tb.CloseOutline(outline);
    try rig.down();
}

/// A PNG file's start: its signature and header, of `width` by `height`.
fn pngStart(file: *File, width: u32, height: u32) void {
    file.text(&.{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });
    file.long(13);
    file.text("IHDR");
    file.long(width);
    file.long(height);
}

/// A strike of `sbix` at `ppem`: glyph 1's picture, and for each other
/// glyph `files` names a file of its kind.
fn sbixStrike(file: *File, ppem: u16, files: []const struct { glyph: u16, kind: *const [4]u8, width: u32 = 0, height: u32 = 0, at: [2]i16 = .{ 0, 0 }, dupe: u16 = 0 }) void {
    const start = file.len;
    file.word(ppem);
    file.word(72);
    const offsets = file.len;
    file.skip(9 * 4);
    var glyph: u16 = 0;
    while (glyph <= 8) : (glyph += 1) {
        file.setLong(offsets + @as(u32, glyph) * 4, file.len - start);
        for (files) |made| {
            if (made.glyph != glyph) continue;
            file.signed(made.at[0]);
            file.signed(made.at[1]);
            file.text(made.kind);
            if (std.mem.eql(u8, made.kind, "png ")) {
                pngStart(file, made.width, made.height);
            } else if (std.mem.eql(u8, made.kind, "dupe")) {
                file.word(made.dupe);
            } else {
                file.text("JFIF");
            }
        }
    }
}

test "pictures of sbix: the largest strike with the glyph, a dupe followed, where it goes" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var table: File = .{};
    table.word(1);
    table.word(1);
    table.long(2);
    table.skip(8);
    table.setLong(8, table.len);
    sbixStrike(&table, 32, &.{
        .{ .glyph = 1, .kind = "png ", .width = 20, .height = 30 },
        .{ .glyph = 2, .kind = "dupe", .dupe = 1 },
    });
    table.setLong(12, table.len);
    sbixStrike(&table, 64, &.{
        .{ .glyph = 1, .kind = "png ", .width = 40, .height = 60, .at = .{ 2, -4 } },
        .{ .glyph = 3, .kind = "jpg " },
    });
    var file: File = .{};
    fontWith(&file, &.{.{ .tag = "sbix", .bytes = table.written() }});
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;

    // The larger strike's, from the outline's left side bearing and
    // bottom - both 0 - its offsets in pixels of 1000 / 64 units.
    var picture: truetype.Picture = undefined;
    try testing.expect(tb.GlyphPicture(outline, 1, &picture));
    try testing.expectEqual(truetype.tableTag("png "), picture.kind);
    try testing.expectEqual(@as(u32, 40), picture.width);
    try testing.expectEqual(@as(u32, 60), picture.height);
    try expectNear(15.625, picture.pixel_x);
    try expectNear(15.625, picture.pixel_y);
    try expectNear(31.25, picture.x);
    try expectNear(-62.5, picture.y);
    try testing.expectEqual(truetype.PICTUREF_BOTTOM, picture.flags);
    try testing.expectEqual(@as(u8, 0x89), picture.bytes.?[0]);

    // Only the smaller strike has glyph 2: glyph 1's picture there.
    try testing.expect(tb.GlyphPicture(outline, 2, &picture));
    try testing.expectEqual(@as(u32, 20), picture.width);
    try testing.expectEqual(@as(u32, 30), picture.height);
    try expectNear(31.25, picture.pixel_x);

    // A file of another kind, handed out as it is.
    try testing.expect(tb.GlyphPicture(outline, 3, &picture));
    try testing.expectEqual(truetype.tableTag("jpg "), picture.kind);
    try testing.expectEqual(@as(u32, 0), picture.width);

    try testing.expect(!tb.GlyphPicture(outline, 4, &picture));
    try testing.expect(picture.bytes == null);
    try testing.expect(!tb.GlyphPicture(outline, 9, &picture));
    tb.CloseOutline(outline);
    try rig.down();
}

test "pictures of CBDT: a font of pictures alone, its top left corner where its measures put it" {
    var rig = try Rig.up();
    const tb = rig.tb;

    var file: File = .{};
    strike.colourFont(&file);
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;

    // Two by two pixels at 20 an em, 0 across and 2 up.
    var picture: truetype.Picture = undefined;
    try testing.expect(tb.GlyphPicture(outline, 1, &picture));
    try testing.expectEqual(truetype.tableTag("png "), picture.kind);
    try testing.expectEqual(@as(u32, 2), picture.width);
    try testing.expectEqual(@as(u32, 2), picture.height);
    try expectNear(50, picture.pixel_x);
    try expectNear(0, picture.x);
    try expectNear(100, picture.y);
    try testing.expectEqual(@as(u32, 0), picture.flags);
    try testing.expectEqual(@as(u32, 0), tb.GlyphPaints(outline, 1, null, 0));
    tb.CloseOutline(outline);
    try rig.down();
}
