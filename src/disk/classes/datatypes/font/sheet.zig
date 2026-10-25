// SPDX-License-Identifier: MIT
//! The sample sheet font.datatype makes of a font: its name and what it
//! is, a table of its characters, and a line of text at each of its
//! sizes, black on white.
//!
//! The sheet is laid out once (`lay`), into lines that each know their
//! rows, and then drawn a line at a time (`drawLine`) into a strip of RGB
//! rows the width of the sheet. So what is held beside the picture while
//! it is made is one line of it, however many sizes there are.
//!
//! A glyph is drawn straight from the font's image, in whichever of the
//! three kinds it is: a bit of `mono1` is ink, a pixel of `alpha4` covers
//! by sixteenths, and one of `indexed8` is its palette entry - the pen's
//! entry in the ink - at that entry's own alpha.

const std = @import("std");
const sdk = @import("sdk");
const fontimage = sdk.graphics.fontimage;
const FontImage = fontimage.FontImage;
const Glyph = fontimage.Glyph;

/// The sheet's colours, 0xRRGGBB.
pub const paper: u32 = 0xFFFFFF;
pub const ink: u32 = 0x000000;
/// What says what the rest is: the sizes, the line under the name.
pub const quiet: u32 = 0x666666;

/// Pixels round the sheet, and between its parts.
pub const margin = 16;
pub const gap = 12;
/// Between a size's number and its line.
const label_gap = 12;
/// Rows between one line of text and the next.
const lead = 6;
/// Pixels round a character in the table.
const cell_pad = 8;
/// Characters in a row of the table.
pub const per_row = 32;

/// The line drawn at every size.
pub const sample = "The quick brown fox jumps over the lazy dog";

/// One size of the font, and its number as the sheet writes it.
pub const Size = struct {
    image: *const FontImage,
    label: []const u8,
};

/// What the sheet shows.
pub const Sheet = struct {
    /// The font the name, the note and the sizes' numbers are in.
    caption: *const FontImage,
    /// The file's name, and what the font is.
    title: []const u8,
    note: []const u8,
    /// The size the table of characters is drawn in.
    table: *const FontImage,
    /// Each size a line of `sample` is drawn in, smallest first.
    sizes: []const Size,
};

/// One line of the sheet: what is in it and which rows it takes.
pub const Line = struct {
    what: What,
    /// Rows from the top of the sheet, and how many.
    top: u32,
    height: u32,
    /// Rows from the line's top to the baseline its text sits on.
    baseline: u32 = 0,
    /// The row of the table, or the size, it is.
    index: u32 = 0,

    pub const What = enum { space, title, note, table, size };
};

/// How big the sheet is, and how many lines it took.
pub const Layout = struct {
    width: u32,
    height: u32,
    count: u32,
    /// The tallest line, which the strip it is drawn in must hold.
    tallest: u32,
};

/// How many lines a sheet of `sizes` sizes takes at most: the margins,
/// the name and note, the gaps, every row of the table and every size.
pub fn linesFor(sizes: usize) usize {
    return 7 + tableRowsMost + sizes;
}

/// The table's rows when a font has every printable Latin-1 character.
const tableRowsMost = (shownMost + per_row - 1) / per_row;
const shownMost = (126 - 33 + 1) + (255 - 161 + 1);

/// How far a text reaches from where it starts: the point's travel, or
/// the ink past it where the last glyph hangs over.
pub fn widthOf(image: *const FontImage, text: []const u8) u32 {
    var x: i32 = 0;
    var right: i32 = 0;
    for (text) |c| {
        const glyph = fontimage.glyphFor(image, c);
        if (glyph.width != 0) right = @max(right, x + glyph.left + glyph.width);
        x += glyph.advance;
    }
    return @intCast(@max(@max(x, right), 0));
}

/// Whether the table shows `code`: a printable Latin-1 character the
/// font has a glyph of its own for, the spaces left out.
pub fn shown(image: *const FontImage, code: u32) bool {
    if (code <= 32 or code > 255 or (code >= 127 and code <= 160)) return false;
    return fontimage.find(image, code) != null;
}

/// How many characters the table shows.
pub fn shownCount(image: *const FontImage) u32 {
    var count: u32 = 0;
    var code: u32 = 33;
    while (code <= 255) : (code += 1) {
        if (shown(image, code)) count += 1;
    }
    return count;
}

/// The width of a cell of the table: room for its widest character.
fn cellOf(image: *const FontImage) u32 {
    var widest: i32 = 1;
    var code: u32 = 33;
    while (code <= 255) : (code += 1) {
        if (!shown(image, code)) continue;
        const glyph = fontimage.find(image, code).?;
        widest = @max(widest, glyph.advance);
        widest = @max(widest, @as(i32, glyph.width) + @max(glyph.left, 0));
    }
    return @as(u32, @intCast(widest)) + cell_pad;
}

/// Rows above and below the baseline of a line in two fonts at once.
fn rowsOf(a: *const FontImage, b: *const FontImage) struct { above: u32, below: u32 } {
    return .{
        .above = @max(a.baseline, b.baseline),
        .below = @max(a.height - a.baseline, b.height - b.baseline),
    };
}

/// Where the sizes' lines start: past the widest number.
fn sampleLeft(sheet: *const Sheet) u32 {
    var widest: u32 = 0;
    for (sheet.sizes) |size| widest = @max(widest, widthOf(sheet.caption, size.label));
    return margin + widest + label_gap;
}

/// The sheet laid out into `lines`, which holds `linesFor` of its sizes.
pub fn lay(sheet: *const Sheet, lines: []Line) Layout {
    var count: u32 = 0;
    var top: u32 = 0;
    var width: u32 = 0;
    var tallest: u32 = 0;
    const add = struct {
        fn add(into: []Line, n: *u32, at: *u32, high: *u32, line: Line) void {
            into[n.*] = line;
            into[n.*].top = at.*;
            n.* += 1;
            at.* += line.height;
            high.* = @max(high.*, line.height);
        }
    }.add;

    add(lines, &count, &top, &tallest, .{ .what = .space, .top = 0, .height = margin });
    const caption = sheet.caption;
    add(lines, &count, &top, &tallest, .{ .what = .title, .top = 0, .height = caption.height + lead, .baseline = lead / 2 + caption.baseline });
    add(lines, &count, &top, &tallest, .{ .what = .note, .top = 0, .height = caption.height + lead, .baseline = lead / 2 + caption.baseline });
    width = @max(width, widthOf(caption, sheet.title));
    width = @max(width, widthOf(caption, sheet.note));

    const table = sheet.table;
    const characters = shownCount(table);
    if (characters != 0) {
        add(lines, &count, &top, &tallest, .{ .what = .space, .top = 0, .height = gap });
        const rows = (characters + per_row - 1) / per_row;
        var row: u32 = 0;
        while (row < rows) : (row += 1) {
            add(lines, &count, &top, &tallest, .{ .what = .table, .top = 0, .height = table.height + cell_pad, .baseline = cell_pad / 2 + table.baseline, .index = row });
        }
        width = @max(width, cellOf(table) * @min(characters, per_row));
    }

    if (sheet.sizes.len != 0) {
        add(lines, &count, &top, &tallest, .{ .what = .space, .top = 0, .height = gap });
        const left = sampleLeft(sheet) - margin;
        for (sheet.sizes, 0..) |size, i| {
            const rows = rowsOf(size.image, caption);
            add(lines, &count, &top, &tallest, .{ .what = .size, .top = 0, .height = rows.above + rows.below + lead, .baseline = lead / 2 + rows.above, .index = @intCast(i) });
            width = @max(width, left + widthOf(size.image, sample));
        }
    }
    add(lines, &count, &top, &tallest, .{ .what = .space, .top = 0, .height = margin });
    return .{ .width = width + 2 * margin, .height = top, .count = count, .tallest = tallest };
}

/// Rows of RGB the width of the sheet, one line of it at a time.
pub const Band = struct {
    rgb: []u8,
    width: u32,
    height: u32,

    /// Every pixel `colour`.
    pub fn fill(band: Band, colour: u32) void {
        var i: usize = 0;
        while (i + 3 <= band.width * band.height * 3) : (i += 3) {
            band.rgb[i] = @truncate(colour >> 16);
            band.rgb[i + 1] = @truncate(colour >> 8);
            band.rgb[i + 2] = @truncate(colour);
        }
    }

    /// `colour` laid over one pixel at `alpha` of 255; one outside the
    /// band is left.
    fn blend(band: Band, x: i32, y: i32, colour: u32, alpha: u32) void {
        if (x < 0 or y < 0 or x >= band.width or y >= band.height or alpha == 0) return;
        const at = (@as(usize, @intCast(y)) * band.width + @as(usize, @intCast(x))) * 3;
        const channels = [3]u32{ (colour >> 16) & 0xFF, (colour >> 8) & 0xFF, colour & 0xFF };
        for (channels, 0..) |value, c| {
            const under: u32 = band.rgb[at + c];
            band.rgb[at + c] = @intCast((value * alpha + under * (255 - alpha) + 127) / 255);
        }
    }

    /// One glyph with its line's top at row `line_top` and the point at
    /// column `x`.
    fn glyph(band: Band, image: *const FontImage, g: *const Glyph, x: i32, line_top: i32, colour: u32) void {
        const pixels = fontimage.pixelsOf(image, g);
        const palette = fontimage.paletteOf(image);
        const left = x + g.left;
        const top = line_top + g.top;
        var row: u32 = 0;
        while (row < g.rows) : (row += 1) {
            const line = pixels + @as(usize, row) * g.pitch;
            var column: u32 = 0;
            while (column < g.width) : (column += 1) {
                const px = left + @as(i32, @intCast(column));
                const py = top + @as(i32, @intCast(row));
                switch (image.kind) {
                    .mono1 => if (line[column / 8] & (@as(u8, 0x80) >> @intCast(column % 8)) != 0) band.blend(px, py, colour, 255),
                    .alpha4 => {
                        const byte = line[column / 2];
                        const cover: u32 = if (column % 2 == 0) byte >> 4 else byte & 15;
                        band.blend(px, py, colour, cover * 17);
                    },
                    .indexed8 => {
                        const index = line[column];
                        if (index == 0 or index >= palette.len) continue;
                        const entry = palette[index];
                        const own = if (index == image.pen_index) colour else entry & 0xFFFFFF;
                        band.blend(px, py, own, entry >> 24);
                    },
                    _ => return,
                }
            }
        }
    }

    /// `text` in `image`, its baseline on row `baseline`, starting at
    /// column `x`.
    pub fn text(band: Band, image: *const FontImage, x: i32, baseline: i32, words: []const u8, colour: u32) void {
        var point = x;
        const line_top = baseline - @as(i32, image.baseline);
        for (words) |c| {
            const g = fontimage.glyphFor(image, c);
            if (g.width != 0) band.glyph(image, g, point, line_top, colour);
            point += g.advance;
        }
    }
};

/// The line `line` of `sheet` drawn into `band`, which is the sheet's
/// width and at least the line's height: paper first, then its text.
pub fn drawLine(sheet: *const Sheet, line: *const Line, band: Band) void {
    band.fill(paper);
    const baseline: i32 = @intCast(line.baseline);
    switch (line.what) {
        .space => {},
        .title => band.text(sheet.caption, margin, baseline, sheet.title, ink),
        .note => band.text(sheet.caption, margin, baseline, sheet.note, quiet),
        .table => {
            const table = sheet.table;
            const cell = cellOf(table);
            const first = line.index * per_row;
            var index: u32 = 0;
            var placed: u32 = 0;
            var code: u32 = 33;
            while (code <= 255 and placed < per_row) : (code += 1) {
                if (!shown(table, code)) continue;
                defer index += 1;
                if (index < first) continue;
                const g = fontimage.find(table, code).?;
                const room: i32 = @intCast(cell);
                const x = margin + @as(i32, @intCast(placed * cell)) + @divTrunc(room - g.advance, 2);
                band.text(table, x, baseline, &[_]u8{@intCast(code)}, ink);
                placed += 1;
            }
        },
        .size => {
            const size = sheet.sizes[line.index];
            band.text(sheet.caption, margin, baseline, size.label, quiet);
            band.text(size.image, @intCast(sampleLeft(sheet)), baseline, sample, ink);
        },
    }
}

// --- tests -------------------------------------------------------------

const testing = std.testing;

/// A font of two characters and the default: 'A' a 2x2 block of ink,
/// '.' one pixel, '?' the default, each 4 wide in an 8-row line.
const test_font align(4) = fontimage.build(.{
    .height = 8,
    .baseline = 6,
    .x_size = 4,
    .default_char = '?',
    .glyphs = &.{
        .{ .code = '.', .advance = 4, .left = 1, .top = 5, .width = 1, .rows = 1, .pixels = &.{0x80} },
        .{ .code = '?', .advance = 4, .left = 0, .top = 2, .width = 2, .rows = 1, .pixels = &.{0xC0} },
        .{ .code = 'A', .advance = 4, .left = 1, .top = 2, .width = 2, .rows = 2, .pixels = &.{ 0xC0, 0xC0 } },
    },
});

fn testImage() *const FontImage {
    return @ptrCast(@alignCast(&test_font));
}

test "font.datatype: a text's width is the point's travel, or its ink past it" {
    const image = testImage();
    try testing.expectEqual(@as(u32, 8), widthOf(image, "AA"));
    try testing.expectEqual(@as(u32, 0), widthOf(image, ""));
}

test "font.datatype: the table shows printable characters the font has, not the default" {
    const image = testImage();
    try testing.expect(shown(image, 'A'));
    try testing.expect(shown(image, '.'));
    try testing.expect(!shown(image, ' '));
    try testing.expect(!shown(image, 'B'));
    try testing.expect(!shown(image, 0xA0));
    try testing.expectEqual(@as(u32, 3), shownCount(image));
}

test "font.datatype: the sheet is laid out top to bottom with every line in it" {
    const image = testImage();
    const sizes = [_]Size{ .{ .image = image, .label = "8" }, .{ .image = image, .label = "8" } };
    const sheet = Sheet{ .caption = image, .title = "test.font", .note = "AA", .table = image, .sizes = &sizes };
    var lines: [linesFor(2)]Line = undefined;
    const layout = lay(&sheet, &lines);
    // Margin, title, note, gap, one row of the table, gap, two sizes,
    // margin.
    try testing.expectEqual(@as(u32, 9), layout.count);
    var top: u32 = 0;
    for (lines[0..layout.count]) |line| {
        try testing.expectEqual(top, line.top);
        top += line.height;
    }
    try testing.expectEqual(top, layout.height);
    try testing.expectEqual(Line.What.table, lines[4].what);
    try testing.expectEqual(Line.What.size, lines[7].what);
    try testing.expectEqual(@as(u32, 1), lines[7].index);
    // The widest line is a size's: its number, the gap, the sample.
    const sample_width = widthOf(image, sample);
    try testing.expectEqual(margin + widthOf(image, "8") + label_gap + sample_width + margin, layout.width);
}

test "font.datatype: a line is drawn on paper, its glyphs in the ink" {
    const image = testImage();
    const sheet = Sheet{ .caption = image, .title = "A", .note = "", .table = image, .sizes = &.{} };
    var lines: [linesFor(0)]Line = undefined;
    const layout = lay(&sheet, &lines);
    const width: usize = layout.width;
    const rgb = try testing.allocator.alloc(u8, width * layout.tallest * 3);
    defer testing.allocator.free(rgb);
    const band = Band{ .rgb = rgb, .width = layout.width, .height = lines[1].height };
    drawLine(&sheet, &lines[1], band);
    // 'A' is drawn from the margin, one column in, two rows down from the
    // line's top: a 2x2 block of black.
    const top: usize = lines[1].baseline - image.baseline + 2;
    const left: usize = margin + 1;
    for ([_]usize{ 0, 1 }) |dy| {
        for ([_]usize{ 0, 1 }) |dx| {
            const at = ((top + dy) * width + left + dx) * 3;
            try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, rgb[at .. at + 3]);
        }
    }
    // Beside it, paper.
    const beside = (top * width + left + 2) * 3;
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xFF, 0xFF }, rgb[beside .. beside + 3]);
}
