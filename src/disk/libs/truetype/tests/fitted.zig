// SPDX-License-Identifier: MIT
//! Host tests of the heights rendering fits to the rows: the baseline,
//! the x height and the cap height on a row's edge at every size, the
//! heights a font does not say taken from its letters, an outline opened
//! plain rendered as it is drawn, and the fetched fonts' capitals and
//! small letters standing on whole rows.
//!
//! A built font's glyph is a square 500 units wide and 700 tall on the
//! baseline, in a line of 800 above it and 200 below: its first column
//! is covered wholly wherever a row is, so a row of it that is not 15
//! is a row the square's edge crosses.

const std = @import("std");
const sdk = @import("sdk");
const fontimage = sdk.graphics.fontimage;
const truetype = sdk.truetype;
const utility = sdk.utility;
const built = @import("truetype.zig");
const builder = @import("builder.zig");
const reference = @import("reference.zig");
const variation = @import("variation.zig");
const _outline = @import("../outline/_outline.zig");

const testing = std.testing;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;
const File = builder.File;

/// Room for the largest glyph rendered here.
var bytes: [16 * 1024]u8 = undefined;

/// A glyph rendered into the tests' bytes.
fn render(tb: *TrueTypeBase, outline: *truetype.Outline, glyph: u32, rows: u32) !fontimage.Glyph {
    var image = truetype.GlyphImage{ .pixels = &bytes, .room = bytes.len };
    try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, glyph, rows, &image));
    try testing.expectEqual(fontimage.Kind.alpha4, image.kind);
    return image.glyph;
}

/// The coverage of the pixel `x`, `y` of the glyph last rendered.
fn pixel(glyph: *const fontimage.Glyph, x: u32, y: u32) u8 {
    const byte = bytes[y * glyph.pitch + x / 2];
    return if (x % 2 == 0) byte >> 4 else byte & 15;
}

/// The most any pixel of the row `y` is covered.
fn most(glyph: *const fontimage.Glyph, y: u32) u8 {
    var found: u8 = 0;
    for (0..glyph.width) |x| found = @max(found, pixel(glyph, @intCast(x), y));
    return found;
}

/// A height of `units` in a line `rows` tall of `line` units, to the
/// nearest row.
fn nearest(units: i32, rows: u32, line: i32) i32 {
    const factor = @as(f32, @floatFromInt(rows)) / @as(f32, @floatFromInt(line));
    return @intFromFloat(@floor(@as(f32, @floatFromInt(units)) * factor + 0.5));
}

/// A built font whose letters are `first` to `last`, glyphs 1 on, with
/// the tables `more`.
fn lettered(file: *File, first: u16, last: u16, more: []const builder.Table) void {
    var cmap = builder.Cmap.init(1);
    cmap.begin(3, 1);
    cmap.segments(&.{
        .{ .first = first, .last = last, .delta = @bitCast(@as(i16, 1) - @as(i16, @intCast(first))) },
        .{ .first = 0xFFFF, .last = 0xFFFF, .delta = 1 },
    });
    _ = builder.font(file, .{ .cmap = cmap.written(), .glyphs = last - first + 2, .more = more });
}

const plain_tags = [_]utility.TagItem{ .{ .tag = truetype.TTA_Plain, .data = 1 }, .{} };

test "fitted: the baseline, the x height and the cap height a font says lie on rows at every size" {
    var rig = try built.Rig.up();
    const tb = rig.tb;

    // x height 480, cap height 700: the square reaches the cap height.
    var file: File = .{};
    builder.whole(&file);
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;

    var rows: u32 = 2;
    while (rows <= 96) : (rows += 1) {
        const baseline = nearest(800, rows, 1000);
        const x_rows = @max(nearest(480, rows, 1000), 1);
        const cap_rows = @max(nearest(700, rows, 1000), x_rows + 1);
        const glyph = try render(tb, outline, 1, rows);
        try testing.expectEqual(baseline - cap_rows, @as(i32, glyph.top));
        try testing.expectEqual(cap_rows, @as(i32, glyph.rows));
        try testing.expectEqual(@as(i16, 0), glyph.left);
        // Whole rows from the top to the foot.
        for (0..glyph.rows) |y| try testing.expectEqual(@as(u8, 15), pixel(&glyph, 0, @intCast(y)));

        // The image names the row the glyphs stand on.
        const letters = [_]truetype.CodeRange{.{ .first = 'A', .last = 'A' }};
        const image = tb.RenderFontImage(outline, rows, &letters, letters.len) orelse return error.NoImage;
        defer rig.sys.FreeVec(image);
        try testing.expectEqual(baseline, @as(i32, image.baseline));
        const in_image = fontimage.find(image, 'A') orelse return error.NoGlyph;
        try testing.expectEqual(@as(i32, image.baseline), @as(i32, in_image.top) + in_image.rows);
    }

    // What the font says is answered as it says it.
    var metrics: truetype.FontMetrics = .{};
    tb.FontMetrics(outline, &metrics);
    try testing.expectEqual(@as(i32, 480), metrics.x_height);
    try testing.expectEqual(@as(i32, 700), metrics.cap_height);

    tb.CloseOutline(outline);
    try rig.down();
}

test "fitted: a point between two heights keeps its share of the way, and one outside them its distance" {
    var rig = try built.Rig.up();
    const tb = rig.tb;

    // At 14 rows the baseline is 11 down, the x height 7 rows and the cap
    // height 10. An x height of 350 units is 5 rows there: the square's
    // top, 700, is the cap height of a font that says 700 - and in a font
    // whose cap height is 1000 it is half way from 350 to 1000, between
    // 5 rows and 14.
    var os2: File = .{};
    os2.word(2);
    os2.skip(94);
    os2.setWord(86, 350);
    os2.setWord(88, 1000);
    var file: File = .{};
    lettered(&file, 'A', 'C', &.{.{ .tag = "OS/2", .bytes = os2.written() }});
    const outline = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;

    // 700 is 350 of the 650 from the x height to the cap height: 5 rows
    // and 350/650 of 9, 9.846 rows above the baseline at 11.
    const glyph = try render(tb, outline, 1, 14);
    try testing.expectEqual(@as(i16, 1), glyph.top);
    try testing.expectEqual(@as(u16, 10), glyph.rows);
    // The top row is covered by 0.846 of it, the others wholly.
    try testing.expectEqual(@as(u8, 13), pixel(&glyph, 0, 0));
    for (1..glyph.rows) |y| try testing.expectEqual(@as(u8, 15), pixel(&glyph, 0, @intCast(y)));

    tb.CloseOutline(outline);
    try rig.down();
}

test "fitted: a font that says no height has its letters' tops, and one without the letter none" {
    var rig = try built.Rig.up();
    const tb = rig.tb;

    // No `OS/2` table, an 'H': the cap height is the square's top, and
    // there is no x height.
    var with: File = .{};
    lettered(&with, 'A', 'J', &.{});
    const lettered_outline = tb.OpenOutline(&with.bytes, with.len, null) orelse return error.NotRead;
    const font: *const _outline.Font = @ptrCast(@alignCast(lettered_outline));
    try testing.expectEqual(@as(i32, 0), font.fit_x_height);
    try testing.expectEqual(@as(i32, 700), font.fit_cap_height);
    var metrics: truetype.FontMetrics = .{};
    tb.FontMetrics(lettered_outline, &metrics);
    try testing.expectEqual(@as(i32, 0), metrics.cap_height);
    var rows: u32 = 2;
    while (rows <= 64) : (rows += 1) {
        const baseline = nearest(800, rows, 1000);
        const cap_rows = @max(nearest(700, rows, 1000), 1);
        const glyph = try render(tb, lettered_outline, 1, rows);
        try testing.expectEqual(baseline - cap_rows, @as(i32, glyph.top));
        try testing.expectEqual(cap_rows, @as(i32, glyph.rows));
        for (0..glyph.rows) |y| try testing.expectEqual(@as(u8, 15), pixel(&glyph, 0, @intCast(y)));
    }
    tb.CloseOutline(lettered_outline);

    // An x and no `OS/2` table: the x height is the square's top.
    var small: File = .{};
    lettered(&small, 'x', 'z', &.{});
    const small_outline = tb.OpenOutline(&small.bytes, small.len, null) orelse return error.NotRead;
    const small_font: *const _outline.Font = @ptrCast(@alignCast(small_outline));
    try testing.expectEqual(@as(i32, 700), small_font.fit_x_height);
    try testing.expectEqual(@as(i32, 0), small_font.fit_cap_height);
    tb.CloseOutline(small_outline);

    // Neither letter: the baseline alone is on a row. At 14 rows it is
    // 11 down and the square's top 9.8 rows above it.
    var without: File = .{};
    lettered(&without, 'A', 'C', &.{});
    const bare = tb.OpenOutline(&without.bytes, without.len, null) orelse return error.NotRead;
    const bare_font: *const _outline.Font = @ptrCast(@alignCast(bare));
    try testing.expectEqual(@as(i32, 0), bare_font.fit_x_height);
    try testing.expectEqual(@as(i32, 0), bare_font.fit_cap_height);
    const glyph = try render(tb, bare, 1, 14);
    try testing.expectEqual(@as(i16, 1), glyph.top);
    try testing.expectEqual(@as(u16, 10), glyph.rows);
    try testing.expectEqual(@as(u8, 12), pixel(&glyph, 0, 0));
    try testing.expectEqual(@as(u8, 15), pixel(&glyph, 0, 9));
    tb.CloseOutline(bare);

    try rig.down();
}

test "fitted: a variable font away from its default takes no letter's top" {
    var rig = try built.Rig.up();
    const tb = rig.tb;

    // 'G' to 'K' are its glyphs 1 to 5, and it has no `OS/2` table.
    var file: File = .{};
    variation.letteredFont(&file, 'G');
    const wght = truetype.tableTag("wght");

    const at_default = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;
    const default_font: *const _outline.Font = @ptrCast(@alignCast(at_default));
    try testing.expectEqual(@as(i32, 700), default_font.fit_cap_height);
    tb.CloseOutline(at_default);

    const away = try variation.openAt(tb, &file, &.{.{ .tag = wght, .value = 700 }});
    const away_font: *const _outline.Font = @ptrCast(@alignCast(away));
    try testing.expect(_outline.isVaried(away_font));
    try testing.expectEqual(@as(i32, 0), away_font.fit_cap_height);
    // Its baseline is on a row all the same.
    const letters = [_]truetype.CodeRange{.{ .first = 'G', .last = 'G' }};
    const image = tb.RenderFontImage(away, 14, &letters, letters.len) orelse return error.NoImage;
    const in_image = fontimage.find(image, 'G') orelse return error.NoGlyph;
    try testing.expectEqual(@as(i32, image.baseline), @as(i32, in_image.top) + in_image.rows);
    rig.sys.FreeVec(image);
    tb.CloseOutline(away);

    try rig.down();
}

test "fitted: an outline opened plain is rendered as it is drawn" {
    var rig = try built.Rig.up();
    const tb = rig.tb;

    var file: File = .{};
    builder.whole(&file);
    const plain = tb.OpenOutline(&file.bytes, file.len, &plain_tags) orelse return error.NotRead;
    const fitted = tb.OpenOutline(&file.bytes, file.len, null) orelse return error.NotRead;

    // At 14 rows the baseline is 11.2 rows down and the square's top 1.4:
    // the top row is covered by 0.6 of it and the row under the foot by
    // 0.2.
    const drawn = try render(tb, plain, 1, 14);
    try testing.expectEqual(fontimage.Glyph{ .width = 7, .rows = 11, .top = 1, .left = 0, .advance = 8, .pitch = 4 }, drawn);
    try testing.expectEqual(@as(u8, 9), pixel(&drawn, 0, 0));
    try testing.expectEqual(@as(u8, 15), pixel(&drawn, 0, 5));
    try testing.expectEqual(@as(u8, 3), pixel(&drawn, 0, 10));

    // Fitted, it is ten whole rows on the eleventh row's edge.
    const whole = try render(tb, fitted, 1, 14);
    try testing.expectEqual(fontimage.Glyph{ .width = 7, .rows = 10, .top = 1, .left = 0, .advance = 8, .pitch = 4 }, whole);
    for (0..10) |y| try testing.expectEqual(@as(u8, 15), pixel(&whole, 0, @intCast(y)));

    // A plain font image names the nearest row as its baseline.
    const letters = [_]truetype.CodeRange{.{ .first = 'A', .last = 'A' }};
    const image = tb.RenderFontImage(plain, 14, &letters, letters.len) orelse return error.NoImage;
    try testing.expectEqual(@as(u16, 11), image.baseline);
    rig.sys.FreeVec(image);

    // At every size the two differ in rows only: the columns and the
    // advance are the same.
    var rows: u32 = 1;
    while (rows <= 64) : (rows += 1) {
        const one = try render(tb, plain, 1, rows);
        const other = try render(tb, fitted, 1, rows);
        try testing.expectEqual(one.advance, other.advance);
        try testing.expectEqual(one.left, other.left);
        try testing.expectEqual(one.width, other.width);
    }

    tb.CloseOutline(fitted);
    tb.CloseOutline(plain);
    try rig.down();
}

/// The capitals and the small letters of a fetched font stand on whole
/// rows from 8 rows to 40: an `H` and an `x` whose tops are the font's
/// cap height and x height have their ink from that many rows above the
/// baseline down to it, and the `H`'s upright stems are covered in
/// their first and last rows as in the rows next to them. A letter
/// whose top is not the height the font says is passed over; `exact`
/// says how many of the two are looked at. An advance is what the
/// plain outline's is.
fn expectStanding(expected: *const reference.Font, exact: u32) !void {
    const file = try reference.read(expected);
    defer testing.allocator.free(file);
    var rig = try built.Rig.up();
    const tb = rig.tb;
    const which = [_]utility.TagItem{ .{ .tag = truetype.TTA_FontIndex, .data = expected.index }, .{} };
    const plain_which = [_]utility.TagItem{
        .{ .tag = truetype.TTA_FontIndex, .data = expected.index },
        .{ .tag = truetype.TTA_Plain, .data = 1 },
        .{},
    };
    const outline = tb.OpenOutline(file.ptr, @intCast(file.len), &which) orelse return error.NotRead;
    const plain = tb.OpenOutline(file.ptr, @intCast(file.len), &plain_which) orelse return error.NotRead;
    var metrics: truetype.FontMetrics = .{};
    tb.FontMetrics(outline, &metrics);
    try testing.expect(metrics.x_height > 0 and metrics.cap_height > metrics.x_height);
    const line = metrics.ascender - metrics.descender;

    var rows: u32 = 8;
    while (rows <= 40) : (rows += 1) {
        var looked_at: u32 = 0;
        const baseline = nearest(metrics.ascender, rows, line);
        const x_rows = @max(nearest(metrics.x_height, rows, line), 1);
        const cap_rows = @max(nearest(metrics.cap_height, rows, line), x_rows + 1);
        for ([_]struct { letter: u32, height: i32, rows: i32 }{
            .{ .letter = 'H', .height = metrics.cap_height, .rows = cap_rows },
            .{ .letter = 'x', .height = metrics.x_height, .rows = x_rows },
        }) |one| {
            const number = tb.GlyphIndex(outline, one.letter);
            try testing.expect(number != 0);
            var box: truetype.GlyphMetrics = .{};
            try testing.expect(tb.GlyphMetrics(outline, number, &box));
            try testing.expectEqual(@as(i32, 0), box.y_min);
            if (box.y_max != one.height) continue;
            looked_at += 1;
            const glyph = try render(tb, outline, number, rows);
            try testing.expectEqual(baseline - one.rows, @as(i32, glyph.top));
            try testing.expectEqual(one.rows, @as(i32, glyph.rows));
            if (one.letter == 'H' and glyph.rows >= 4) {
                try testing.expectEqual(most(&glyph, 1), most(&glyph, 0));
                try testing.expectEqual(most(&glyph, glyph.rows - 2), most(&glyph, glyph.rows - 1));
            }
        }
        try testing.expectEqual(exact, looked_at);
        var code: u32 = ' ';
        while (code <= '~') : (code += 1) {
            const number = tb.GlyphIndex(outline, code);
            const fitted_glyph = try render(tb, outline, number, rows);
            const plain_glyph = try render(tb, plain, number, rows);
            try testing.expectEqual(plain_glyph.advance, fitted_glyph.advance);
        }
    }

    tb.CloseOutline(plain);
    tb.CloseOutline(outline);
    try rig.down();
}

test "fitted: go/Go-Regular.ttf stands on whole rows" {
    try expectStanding(reference.go_regular, 2);
}

test "fitted: liberation/LiberationSans-Regular.ttf stands on whole rows" {
    try expectStanding(reference.liberation_sans_regular, 2);
}

test "fitted: source-sans/SourceSans3-Regular.otf, of cubic curves, stands on whole rows" {
    // Its `H` ends 4 units under the cap height it says.
    try expectStanding(reference.source_sans_3_regular, 1);
}
