// SPDX-License-Identifier: MIT
//! Host tests of truetype.library on the fonts `scripts/fetch-fonts.sh`
//! fetches, against what fontTools reads from the same files.
//!
//! There is a test for each font `reference.zig` has values for. It reads
//! the file, opens it through the library's jump table, and compares
//! everything the library says of it with the values written for it: the
//! font's measures, its table directory, the character map character by
//! character, the variation sequences, the names, every glyph's measures.
//! Every glyph is read as an outline, and the font is rendered at one
//! size. A test is skipped when its font is not fetched, and fails by the
//! font's name when the file is not the one the values were read from.
//!
//! The library reads characters by one of a font's maps. To compare the
//! others too, the test takes the opened font's state, puts each subtable
//! in the place of the one picked, and asks the library's own reader
//! (`_outline.glyphIndex`) for every character: each format a font has is
//! read in full, whichever the library picks.

const std = @import("std");
const sdk = @import("sdk");
const graphics = sdk.graphics;
const fontimage = graphics.fontimage;
const truetype = sdk.truetype;
const reference = @import("reference.zig");
const _outline = @import("../outline/_outline.zig");
const Rig = @import("truetype.zig").Rig;

const testing = std.testing;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;

/// The last character there is.
const last_code = 0x10_FFFF;

/// A digest compared with the one written: on a difference the test
/// fails saying what was hashed.
fn expectDigest(what: []const u8, want_count: u32, want: []const u8, count: u32, digest: *reference.Digest) !void {
    const got = digest.hex();
    if (count == want_count and std.mem.eql(u8, want, &got)) return;
    std.debug.print("{s}: {d} entries hashing to {s}, not {d} to {s}\n", .{ what, count, got, want_count, want });
    return error.ReadDiffers;
}

/// Every character `font` has a glyph for, counted and hashed as a
/// character map is.
fn expectMap(what: []const u8, want_count: u32, want: []const u8, font: *const _outline.Font) !void {
    var digest: reference.Digest = .{};
    var count: u32 = 0;
    var code: u32 = 0;
    while (code <= last_code) : (code += 1) {
        const glyph = _outline.glyphIndex(font, code);
        if (glyph == 0) continue;
        digest.add(code);
        digest.add(glyph);
        count += 1;
    }
    try expectDigest(what, want_count, want, count, &digest);
}

/// The font `expected` is of, read by the library, is what fontTools
/// reads.
fn expectFont(expected: *const reference.Font) !void {
    const bytes = try reference.read(expected);
    defer testing.allocator.free(bytes);
    const size: u32 = @intCast(bytes.len);
    const start = @intFromPtr(bytes.ptr);

    var rig = try Rig.up();
    const sys = rig.sys;
    const tb = rig.tb;

    try testing.expect(truetype.isTrueType(bytes));
    try testing.expectEqual(@as(u32, 1), truetype.fontCount(bytes));
    try testing.expectEqual(@as(?u32, 0), truetype.fontDirectory(bytes, 0));
    const outline = tb.OpenOutline(bytes.ptr, size, null) orelse return error.NotRead;

    // The font's measures.
    var metrics: truetype.FontMetrics = .{};
    tb.FontMetrics(outline, &metrics);
    try testing.expectEqual(expected.glyph_count, metrics.glyph_count);
    try testing.expectEqual(expected.units_per_em, metrics.units_per_em);
    try testing.expectEqual(expected.ascender, metrics.ascender);
    try testing.expectEqual(expected.descender, metrics.descender);
    try testing.expectEqual(expected.line_gap, metrics.line_gap);
    try testing.expectEqual(expected.x_height, metrics.x_height);
    try testing.expectEqual(expected.cap_height, metrics.cap_height);
    try testing.expectEqual(expected.underline_position, metrics.underline_position);
    try testing.expectEqual(expected.underline_thickness, metrics.underline_thickness);
    try testing.expectEqual(expected.strikeout_position, metrics.strikeout_position);
    try testing.expectEqual(expected.strikeout_thickness, metrics.strikeout_thickness);
    var style: graphics.FontStyle = graphics.FS_NORMAL;
    if (expected.bold) style |= graphics.FSF_BOLD;
    if (expected.italic) style |= graphics.FSF_ITALIC;
    try testing.expectEqual(style, metrics.style);
    try testing.expectEqual(style, truetype.styleOf(bytes));

    // Every table of the directory, where the file has it.
    try testing.expectEqual(expected.tables.len, std.mem.readInt(u16, bytes[4..6], .big));
    var length: u32 = 0;
    for (expected.tables) |entry| {
        const table = tb.FontTable(outline, truetype.tableTag(entry.tag), &length);
        if (table == null or @intFromPtr(table.?) - start != entry.at or length != entry.len) {
            std.debug.print("table {s}: not {d} bytes at {d}\n", .{ entry.tag, entry.len, entry.at });
            return error.ReadDiffers;
        }
    }
    length = 1;
    try testing.expect(tb.FontTable(outline, truetype.tableTag("zzzz"), &length) == null);
    try testing.expectEqual(@as(u32, 0), length);

    // The characters, by the map the library picks: the few written out,
    // then all of them.
    for (expected.pairs) |pair| {
        const glyph = tb.GlyphIndex(outline, pair.code);
        if (glyph == pair.glyph) continue;
        std.debug.print("U+{X:0>4} is glyph {d}, not {d}\n", .{ pair.code, glyph, pair.glyph });
        return error.ReadDiffers;
    }
    var digest: reference.Digest = .{};
    var count: u32 = 0;
    var code: u32 = 0;
    while (code <= last_code) : (code += 1) {
        const glyph = tb.GlyphIndex(outline, code);
        if (glyph == 0) continue;
        digest.add(code);
        digest.add(glyph);
        count += 1;
    }
    try expectDigest("the characters", expected.best_count, expected.best_sha256, count, &digest);
    try testing.expectEqual(@as(u32, 0), tb.GlyphIndex(outline, last_code + 1));
    try testing.expectEqual(@as(u32, 0), tb.GlyphIndex(outline, 0xFFFF_FFFF));

    // Each subtable of the character map in the picked one's place.
    const opened: *const _outline.Font = @ptrCast(@alignCast(outline));
    const map = tb.FontTable(outline, truetype.tableTag("cmap"), &length) orelse return error.NoTable;
    const map_at: u32 = @intCast(@intFromPtr(map) - start);
    const cmap = map[0..length];
    try testing.expectEqual(expected.subtables.len, std.mem.readInt(u16, cmap[2..4], .big));
    for (expected.subtables, 0..) |subtable, i| {
        const record = cmap[4 + i * 8 ..][0..8];
        const offset = std.mem.readInt(u32, record[4..8], .big);
        const format = std.mem.readInt(u16, cmap[offset..][0..2], .big);
        try testing.expectEqual(subtable.platform, std.mem.readInt(u16, record[0..2], .big));
        try testing.expectEqual(subtable.encoding, std.mem.readInt(u16, record[2..4], .big));
        try testing.expectEqual(subtable.format, format);
        // The sequences are no map of characters: they follow.
        if (format == 14) continue;
        var probe = opened.*;
        probe.cmap = .{ .at = map_at + offset, .len = length - offset };
        probe.cmap_format = format;
        var what_buffer: [64]u8 = undefined;
        const what = try std.fmt.bufPrint(&what_buffer, "subtable {d} ({d}, {d}) of format {d}", .{ i, subtable.platform, subtable.encoding, format });
        try expectMap(what, subtable.count, subtable.sha256, &probe);
    }

    // The variation sequences: the few written out, then every character
    // after every selector the font has sequences for.
    for (expected.sequences) |sequence| {
        const glyph = tb.GlyphVariant(outline, sequence.code, sequence.selector);
        if (glyph == sequence.glyph) continue;
        std.debug.print("U+{X:0>4} U+{X:0>4} is glyph {d}, not {d}\n", .{ sequence.code, sequence.selector, glyph, sequence.glyph });
        return error.ReadDiffers;
    }
    digest = .{};
    count = 0;
    for (expected.selectors) |selector| {
        code = 0;
        while (code <= last_code) : (code += 1) {
            const glyph = tb.GlyphVariant(outline, code, selector);
            if (glyph == 0) continue;
            digest.add(selector);
            digest.add(code);
            digest.add(glyph);
            count += 1;
        }
    }
    try expectDigest("the variation sequences", expected.sequence_count, expected.sequences_sha256, count, &digest);
    // A selector it has none for.
    for ([_]u32{ 0, 0xFE00, 0xFE0E, 0xFE0F, 0xE0100, 0xE01EF, 0xFFFF_FFFF }) |selector| {
        if (std.mem.indexOfScalar(u32, expected.selectors, selector) != null) continue;
        for ([_]u32{ 0x23, 'A', 0x915, 0x1F600 }) |base| try testing.expectEqual(@as(u32, 0), tb.GlyphVariant(outline, base, selector));
    }

    // The names: each whole, and cut to half the room it takes.
    const text_buffer = try testing.allocator.alloc(u8, 64 * 1024);
    defer testing.allocator.free(text_buffer);
    for (expected.names) |name| {
        try testing.expect(name.text.len < text_buffer.len);
        @memset(text_buffer[0 .. name.text.len + 1], 0xAA);
        const needed = tb.FontName(outline, name.id, text_buffer.ptr, @intCast(text_buffer.len));
        if (needed != name.text.len or !std.mem.eql(u8, name.text, text_buffer[0..name.text.len]) or text_buffer[name.text.len] != 0) {
            std.debug.print("name {d} is \"{s}\" ({d} bytes), not \"{s}\"\n", .{ name.id, std.mem.sliceTo(text_buffer, 0), needed, name.text });
            return error.ReadDiffers;
        }
        const room: u32 = @intCast(name.text.len / 2 + 1);
        @memset(text_buffer[0 .. room + 1], 0xAA);
        try testing.expectEqual(needed, tb.FontName(outline, name.id, text_buffer.ptr, room));
        const cut = std.mem.sliceTo(text_buffer[0..room], 0);
        try testing.expect(cut.len < room);
        try testing.expect(std.mem.startsWith(u8, name.text, cut));
        try testing.expect(std.unicode.utf8ValidateSlice(cut));
        try testing.expectEqual(@as(u8, 0xAA), text_buffer[room]);
    }
    // A name the table has no record of.
    var absent: u32 = 0;
    for (expected.names) |name| {
        if (name.id == absent) absent += 1;
    }
    for ([_]u32{ absent, 0xFFFF, 0x1_0000 }) |id| {
        text_buffer[0] = 0xAA;
        try testing.expectEqual(@as(u32, 0), tb.FontName(outline, id, text_buffer.ptr, 16));
        try testing.expectEqual(@as(u8, 0), text_buffer[0]);
    }

    // Every glyph: its measures, and its outline read into the room the
    // font says the largest takes, each contour closed.
    const verbs = try testing.allocator.alloc(u8, @max(metrics.most_verbs, 1));
    defer testing.allocator.free(verbs);
    const points = try testing.allocator.alloc(sdk.vector.Point, @max(metrics.most_points, 1));
    defer testing.allocator.free(points);
    var measures: truetype.GlyphMetrics = .{};
    digest = .{};
    var glyph: u32 = 0;
    while (glyph < expected.glyph_count) : (glyph += 1) {
        try testing.expect(tb.GlyphMetrics(outline, glyph, &measures));
        digest.addSigned(measures.advance);
        digest.addSigned(measures.left_bearing);
        digest.addSigned(measures.x_min);
        digest.addSigned(measures.y_min);
        digest.addSigned(measures.x_max);
        digest.addSigned(measures.y_max);

        var segments = truetype.Segments{
            .verbs = verbs.ptr,
            .points = points.ptr,
            .verb_room = metrics.most_verbs,
            .point_room = metrics.most_points,
        };
        const result = tb.GlyphSegments(outline, glyph, &segments);
        var moves: u32 = 0;
        var closes: u32 = 0;
        for (verbs[0..segments.verb_count]) |verb| {
            if (verb == sdk.vector.SEG_MOVE) moves += 1;
            if (verb == sdk.vector.SEG_CLOSE) closes += 1;
        }
        const drawn = measures.x_max > measures.x_min and measures.y_max > measures.y_min;
        if (result != truetype.TRUETYPE_OK or moves != closes or (drawn and moves == 0) or (!expected.outlines and moves != 0)) {
            std.debug.print("glyph {d}: its outline answers {d}, {d} contours begun and {d} closed\n", .{ glyph, result, moves, closes });
            return error.ReadDiffers;
        }
    }
    try expectDigest("the glyphs' measures", expected.glyph_count, expected.metrics_sha256, glyph, &digest);
    // One past the last.
    try testing.expect(!tb.GlyphMetrics(outline, expected.glyph_count, &measures));
    try testing.expectEqual(truetype.GlyphMetrics{}, measures);
    var none = truetype.Segments{ .verbs = verbs.ptr, .points = points.ptr, .verb_room = metrics.most_verbs, .point_room = metrics.most_points };
    try testing.expectEqual(truetype.TRUETYPEERR_GLYPH, tb.GlyphSegments(outline, expected.glyph_count, &none));

    // Rendered: an image of the characters the font has a glyph for, and
    // none of a font without outlines.
    const ranges = [_]truetype.CodeRange{
        .{ .first = 0x20, .last = 0x7E },
        .{ .first = 0xA0, .last = 0x17F },
        .{ .first = 0x900, .last = 0x97F },
        .{ .first = 0x2000, .last = 0x206F },
        .{ .first = 0x1F600, .last = 0x1F64F },
    };
    const rendered = tb.RenderFontImage(outline, 16, &ranges, ranges.len);
    if (expected.outlines) {
        const image = rendered orelse return error.NoImage;
        const block: [*]const u8 = @ptrCast(image);
        try testing.expect(fontimage.check(block, image.size));
        try testing.expect(fontimage.sound(block, image.size));
        try testing.expectEqual(@as(u16, 16), image.height);
        try testing.expectEqual(style, image.style);
        for (ranges) |range| {
            code = range.first;
            while (code <= range.last) : (code += 1) {
                const has = tb.GlyphIndex(outline, code) != 0;
                if (has == (fontimage.find(image, code) != null)) continue;
                std.debug.print("U+{X:0>4}: in the font {}, in its image {}\n", .{ code, has, !has });
                return error.ReadDiffers;
            }
        }
        sys.FreeVec(image);
    } else {
        try testing.expect(rendered == null);
    }

    tb.CloseOutline(outline);
    try rig.down();
}

test "truetype: go/Go-Regular.ttf as fontTools reads it" {
    try expectFont(reference.go_regular);
}

test "truetype: liberation-fonts-ttf-2.1.5/LiberationSans-Regular.ttf as fontTools reads it" {
    try expectFont(reference.liberation_sans_regular);
}

test "truetype: noto/NotoSansDevanagari-Regular.ttf as fontTools reads it" {
    try expectFont(reference.noto_sans_devanagari_regular);
}

test "truetype: noto/NotoColorEmoji.ttf as fontTools reads it" {
    try expectFont(reference.noto_color_emoji);
}

test "truetype: there is a test for every font with values" {
    // The four above, each named with its file.
    try testing.expectEqual(@as(usize, 4), reference.fonts.len);
    try testing.expectEqualStrings("go/Go-Regular.ttf", reference.go_regular.file);
    try testing.expectEqualStrings("liberation-fonts-ttf-2.1.5/LiberationSans-Regular.ttf", reference.liberation_sans_regular.file);
    try testing.expectEqualStrings("noto/NotoSansDevanagari-Regular.ttf", reference.noto_sans_devanagari_regular.file);
    try testing.expectEqualStrings("noto/NotoColorEmoji.ttf", reference.noto_color_emoji.file);
}
