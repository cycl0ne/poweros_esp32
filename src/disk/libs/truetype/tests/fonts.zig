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
//! size: as an image of its characters, and every glyph by its number,
//! which for a glyph with a character is the image's glyph byte for byte.
//!
//! A font whose glyphs are pictures is compared further: each picture's
//! measures and its pixels at full size - read with the library's own
//! reader (`_picture.read`), as rendering a glyph reads it - with what
//! fontTools and Pillow find, and glyphs rendered at another size with
//! the mean over each pixel's area the script works out: the coverage of
//! many glyphs summed, and a few pixel by pixel. The library adds an area
//! up in 32 bits and the script in 64: `scaled_apart` says how far apart
//! a rounded value may be.
//!
//! A test is skipped when its font is not fetched, and fails by the
//! font's name when the file is not the one the values were read from.
//!
//! A font of cubic curves is compared further: its glyphs' outlines verb
//! by verb and point by point with fontTools' drawing of them, and its
//! glyphs rendered with libfreetype's rendering of the same outlines -
//! the ink of many glyphs, and a few pixel by pixel. The two renderers
//! measure the same area and round it differently, the library to 16
//! levels: `ink_apart` and `pixel_apart` say how far apart they may be.
//!
//! A variable font is compared further, at each place on its axes it
//! has values for: its axes and the places it names, where the place
//! is, the measures there, and of every glyph its measures, its advance
//! and its points - read with the library's own reader
//! (`_outline.contours`), as rendering a glyph reads them - bit for bit
//! with what the script works out from fontTools' reading of the font's
//! tables. The advance a font without `HVAR` has is compared too: on the
//! same file with that table's tag changed in its directory, so that
//! the library takes every advance from the glyph's two side points.
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
const _strike = @import("../outline/_strike.zig");
const _picture = @import("../render/_picture.zig");
const _render = @import("../render/_render.zig");
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

/// How far the library's ink of a glyph may be from libfreetype's: so
/// many thousandths of the larger and so many whole pixels' worth more;
/// and how far one pixel may be, in levels of 15. Of the 3619 glyphs
/// compared the furthest is 1.7 pixels' worth past the thousandths, and
/// no pixel is more than a level off.
const ink_apart = 20;
const ink_least = 2;
const pixel_apart = 1;

/// How far a value of a scaled picture's pixel may be from the script's:
/// one, where the two round a half differently.
const scaled_apart = 1;

/// A verb of a cubic outline: its number in a hashed outline, its letter
/// in one written out, and how many points it has.
const Verb = struct { number: u32, letter: u8, points: u32 };

fn verbOf(verb: u8) ?Verb {
    return switch (verb) {
        sdk.vector.SEG_MOVE => .{ .number = 0, .letter = 'M', .points = 1 },
        sdk.vector.SEG_LINE => .{ .number = 1, .letter = 'L', .points = 1 },
        sdk.vector.SEG_CUBIC => .{ .number = 2, .letter = 'C', .points = 3 },
        sdk.vector.SEG_CLOSE => .{ .number = 3, .letter = 'Z', .points = 0 },
        else => null,
    };
}

/// A coordinate of a glyph of cubic curves: a whole number of units.
fn whole(value: f32) !i32 {
    if (@round(value) != value) return error.ReadDiffers;
    return @intFromFloat(value);
}

/// The coverage of pixel (`x`, `y`) of the line in levels of 15, of a
/// glyph rendered into `pixels`; 0 outside its box.
fn levelAt(box: *const fontimage.Glyph, pixels: []const u8, x: i32, y: i32) u8 {
    const column = x - box.left;
    const row = y - box.top;
    if (column < 0 or row < 0 or column >= box.width or row >= box.rows) return 0;
    const byte = pixels[@as(usize, @intCast(row)) * box.pitch + @as(usize, @intCast(column)) / 2];
    return if (column & 1 == 0) byte >> 4 else byte & 0x0F;
}

/// The room a glyph is rendered into, the bytes after a glyph's that are
/// looked at for a write, and what those hold.
const glyph_room = 256 * 1024;
const watched = 16;
const untouched: u8 = 0xAA;

/// What rendering every glyph of a font found.
const Rendered = struct {
    /// Glyphs whose outline has a box of some width and height.
    drawn: u32 = 0,
    /// Glyphs that came out with ink.
    inked: u32 = 0,
};

/// Every glyph of `outline` rendered by its number for a line `rows`
/// tall into `pixels`, which hold `untouched` and do so again after: each
/// is rendered, its pixels of `kind`, its advance is the font's scaled to
/// the line, a row's bytes hold its pixels and nothing after them, and no
/// byte past the glyph's is written. A glyph of an outline has its box
/// cut to its ink; one that is a picture (`pictured`) has the picture's.
fn expectGlyphsRendered(tb: *TrueTypeBase, outline: *truetype.Outline, metrics: *const truetype.FontMetrics, rows: u32, pixels: []u8, kind: fontimage.Kind, pictured: bool) !Rendered {
    var found: Rendered = .{};
    const line: i64 = metrics.ascender - metrics.descender;
    var measures: truetype.GlyphMetrics = .{};
    var glyph: u32 = 0;
    while (glyph < metrics.glyph_count) : (glyph += 1) {
        var image = truetype.GlyphImage{ .pixels = pixels.ptr, .room = glyph_room, .size = 1, .kind = .mono1 };
        const answer = tb.RenderGlyph(outline, glyph, rows, &image);
        const box = image.glyph;
        const size = image.size;
        errdefer std.debug.print("glyph {d} at {d} rows answers {d}: {d} by {d} at {d}, {d}, advance {d}, {d} bytes a row, {d} bytes\n", .{
            glyph, rows, answer, box.width, box.rows, box.left, box.top, box.advance, box.pitch, size,
        });
        try testing.expectEqual(truetype.TRUETYPE_OK, answer);
        try testing.expectEqual(kind, image.kind);
        try testing.expectEqual(@as(u32, 0), box.data);
        try testing.expectEqual(fontimage.pitchOf(kind, box.width), @as(u32, box.pitch));
        try testing.expectEqual(@as(u32, box.pitch) * box.rows, size);
        try testing.expect((box.width == 0) == (box.rows == 0));
        for (pixels[size..][0..watched]) |byte| try testing.expectEqual(untouched, byte);

        // The advance: the font's, scaled, to the nearest pixel.
        try testing.expect(tb.GlyphMetrics(outline, glyph, &measures));
        const apart = @abs(@as(i64, box.advance) * line - @as(i64, measures.advance) * rows);
        try testing.expect(2 * apart <= line + 2);

        if (measures.x_max > measures.x_min and measures.y_max > measures.y_min) found.drawn += 1;
        if (box.width == 0) continue;
        found.inked += 1;
        if (pictured) {
            @memset(pixels[0..size], untouched);
            continue;
        }

        // Cut to the ink: its first and last row and column each have a
        // pixel covered. A row of an odd width ends in half a byte of
        // nothing.
        var top = false;
        var bottom = false;
        var left = false;
        var right = false;
        const last_at = (box.width - 1) / 2;
        const last_shift: u3 = if (box.width & 1 == 1) 4 else 0;
        for (0..box.rows) |y| {
            const row = pixels[y * box.pitch ..][0..box.pitch];
            if (box.width & 1 == 1) try testing.expectEqual(@as(u8, 0), row[last_at] & 0x0F);
            if (row[0] >> 4 != 0) left = true;
            if ((row[last_at] >> last_shift) & 0x0F != 0) right = true;
            for (row) |byte| {
                if (byte == 0) continue;
                if (y == 0) top = true;
                if (y == box.rows - 1) bottom = true;
            }
        }
        try testing.expect(top and bottom and left and right);
        @memset(pixels[0..size], untouched);
    }
    return found;
}

/// The pictures of a font of them are what the script found: each one's
/// measures and its pixels at full size, and rendered for a line
/// `scaled_rows` tall the coverage of every `scaled_step`th glyph summed
/// and a few glyphs pixel by pixel, in their box.
fn expectPictures(rig: *Rig, outline: *truetype.Outline, expected: *const reference.Font, pixels: []u8) !void {
    const tb = rig.tb;
    const font: *const _outline.Font = @ptrCast(@alignCast(outline));
    const each: u32 = if (expected.strike_colour) 4 else 1;

    var measured: reference.Digest = .{};
    var shown: reference.Digest = .{};
    var found: u32 = 0;
    var glyph: u32 = 0;
    while (glyph < expected.glyph_count) : (glyph += 1) {
        const picture = _strike.pictureOf(font, glyph, null) orelse continue;
        found += 1;
        measured.add(glyph);
        measured.add(picture.strike.ppem_x);
        measured.add(picture.strike.ppem_y);
        measured.add(picture.strike.depth);
        measured.add(picture.metrics.width);
        measured.add(picture.metrics.rows);
        measured.addSigned(picture.metrics.left);
        measured.addSigned(picture.metrics.top);
        const canvas = _picture.read(rig.sys, font, &picture) catch |failure| {
            std.debug.print("glyph {d}: its picture is not read: {s}\n", .{ glyph, @errorName(failure) });
            return error.ReadDiffers;
        };
        defer rig.sys.FreeVec(canvas.ptr);
        try testing.expectEqual(picture.metrics.width * picture.metrics.rows * each, canvas.len);
        shown.add(glyph);
        shown.addBytes(canvas);
    }
    try expectDigest("the pictures' measures", expected.strike_count, expected.strike_measures_sha256, found, &measured);
    try expectDigest("the pictures' pixels", expected.strike_count, expected.strike_pixels_sha256, found, &shown);

    // Scaled: the coverage of all a glyph's pixels summed, each no
    // further off than a rounding.
    for (expected.scaled_inks, 0..) |theirs, i| {
        const number: u32 = @intCast(i * expected.scaled_step);
        var one = truetype.GlyphImage{ .pixels = pixels.ptr, .room = glyph_room };
        try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, number, expected.scaled_rows, &one));
        var ours: u32 = 0;
        if (expected.strike_colour) {
            var at: usize = 3;
            while (at < one.size) : (at += 4) ours += pixels[at];
        } else {
            for (pixels[0..one.size]) |byte| ours += (byte >> 4) + (byte & 0x0F);
        }
        @memset(pixels[0..one.size], untouched);
        const apart = @max(ours, theirs) - @min(ours, theirs);
        if (apart <= scaled_apart * @as(u32, one.glyph.width) * one.glyph.rows / 16) continue;
        std.debug.print("glyph {d} at {d} rows: coverage {d}, the area's {d}\n", .{ number, expected.scaled_rows, ours, theirs });
        return error.ReadDiffers;
    }
    // A few pixel by pixel.
    for (expected.scaled) |want| {
        var one = truetype.GlyphImage{ .pixels = pixels.ptr, .room = glyph_room };
        try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, want.glyph, expected.scaled_rows, &one));
        const box = one.glyph;
        errdefer std.debug.print("glyph {d} at {d} rows: {d} by {d} at {d}, {d}\n", .{ want.glyph, expected.scaled_rows, box.width, box.rows, box.left, box.top });
        try testing.expectEqual(want.left, @as(i32, box.left));
        try testing.expectEqual(want.top, @as(i32, box.top));
        try testing.expectEqual(want.width, @as(u32, box.width));
        try testing.expectEqual(want.rows.len, @as(usize, box.rows));
        for (want.rows, 0..) |row, y| {
            const line = pixels[y * box.pitch ..][0..box.pitch];
            for (0..want.width) |x| {
                if (expected.strike_colour) {
                    for (0..4) |channel| {
                        const theirs: i32 = try std.fmt.parseInt(u8, row[x * 8 + channel * 2 ..][0..2], 16);
                        const ours: i32 = line[x * 4 + channel];
                        if (@abs(ours - theirs) <= scaled_apart) continue;
                        std.debug.print("pixel {d}, {d}: channel {d} is {d}, the area's {d}\n", .{ x, y, channel, ours, theirs });
                        return error.ReadDiffers;
                    }
                } else {
                    const theirs: i32 = try std.fmt.charToDigit(row[x], 16);
                    const ours: i32 = if (x & 1 == 0) line[x / 2] >> 4 else line[x / 2] & 0x0F;
                    if (@abs(ours - theirs) <= scaled_apart) continue;
                    std.debug.print("pixel {d}, {d} is {d}, the area's {d}\n", .{ x, y, ours, theirs });
                    return error.ReadDiffers;
                }
            }
        }
        @memset(pixels[0..one.size], untouched);
    }
}

/// The font `expected` is of, read by the library, is what fontTools
/// reads.
/// The most axes a font with values has.
const axis_room = 8;

/// A variable font opened at a place: the tags `OpenOutline` takes for
/// it, built from what was asked.
fn openAt(tb: *TrueTypeBase, bytes: []const u8, expected: *const reference.Font, instance: *const reference.Instance) !*truetype.Outline {
    var asked: [axis_room]truetype.AxisValue = undefined;
    try testing.expect(instance.asked.len <= asked.len);
    for (instance.asked, 0..) |one, i| asked[i] = .{ .tag = truetype.tableTag(one.tag), .value = one.value };
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = truetype.TTA_FontIndex, .data = expected.index },
        .{ .tag = truetype.TTA_Axes, .data = @intFromPtr(&asked) },
        .{ .tag = truetype.TTA_AxisCount, .data = instance.asked.len },
        .{},
    };
    return tb.OpenOutline(bytes.ptr, @intCast(bytes.len), &tags) orelse error.NotRead;
}

/// A variable font at each place it has values for.
fn expectInstances(rig: *Rig, bytes: []const u8, expected: *const reference.Font) !void {
    const tb = rig.tb;
    const sys = rig.sys;
    const identity = [6]f32{ 1, 0, 0, 1, 0, 0 };
    try testing.expect(expected.axes.len <= axis_room);

    // The same file as a font without `HVAR`: the table's tag changed in
    // the directory, so that no reader finds it.
    const sided = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(sided);
    var hidden_tables: u32 = 0;
    for (0..expected.tables.len) |i| {
        const record = sided[expected.directory + 12 + i * 16 ..][0..4];
        if (!std.mem.eql(u8, record, "HVAR")) continue;
        record.* = "hvar".*;
        hidden_tables += 1;
    }
    try testing.expectEqual(@as(u32, 1), hidden_tables);

    for (expected.instances) |*instance| {
        const outline = try openAt(tb, bytes, expected, instance);
        const font: *const _outline.Font = @ptrCast(@alignCast(outline));
        var what_buffer: [96]u8 = undefined;

        // The axes, with the value the outline is at on each, and the
        // coordinates.
        var axes: [axis_room]truetype.Axis = undefined;
        try testing.expectEqual(@as(u32, @intCast(expected.axes.len)), tb.FontAxes(outline, &axes, axis_room));
        try testing.expectEqual(expected.axes.len, instance.values.len);
        for (expected.axes, instance.values, axes[0..expected.axes.len]) |axis, value, found| {
            try testing.expectEqual(truetype.Axis{
                .tag = truetype.tableTag(axis.tag),
                .minimum = axis.minimum,
                .default = axis.default,
                .maximum = axis.maximum,
                .value = value,
                .name = axis.name,
                .hidden = axis.hidden,
            }, found);
        }
        var coords: [axis_room]i16 = undefined;
        try testing.expectEqual(@as(u32, @intCast(expected.axes.len)), tb.FontCoordinates(outline, &coords, axis_room));
        try testing.expectEqualSlices(i16, instance.coords, coords[0..expected.axes.len]);

        // The places the font names: the same from every outline of it.
        var values: [axis_room]truetype.AxisValue = undefined;
        for (expected.named, 0..) |named, number| {
            try testing.expectEqual(named.name, tb.FontInstance(outline, @intCast(number), &values, axis_room));
            for (expected.axes, named.values, values[0..expected.axes.len]) |axis, value, found| {
                try testing.expectEqual(truetype.AxisValue{ .tag = truetype.tableTag(axis.tag), .value = value }, found);
            }
        }
        try testing.expectEqual(@as(u32, 0), tb.FontInstance(outline, @intCast(expected.named.len), &values, axis_room));

        // The measures: those that vary, and those that do not.
        var metrics: truetype.FontMetrics = .{};
        tb.FontMetrics(outline, &metrics);
        try testing.expectEqual(expected.glyph_count, metrics.glyph_count);
        try testing.expectEqual(expected.units_per_em, metrics.units_per_em);
        try testing.expectEqual(expected.ascender, metrics.ascender);
        try testing.expectEqual(expected.descender, metrics.descender);
        try testing.expectEqual(expected.line_gap, metrics.line_gap);
        try testing.expectEqual(instance.x_height, metrics.x_height);
        try testing.expectEqual(instance.cap_height, metrics.cap_height);
        try testing.expectEqual(instance.underline_position, metrics.underline_position);
        try testing.expectEqual(instance.underline_thickness, metrics.underline_thickness);
        try testing.expectEqual(instance.strikeout_position, metrics.strikeout_position);
        try testing.expectEqual(instance.strikeout_thickness, metrics.strikeout_thickness);

        // The few glyphs written out, point by point.
        var work = _render.Work.init(sys, font) orelse return error.NoMemory;
        const c = &work.contours;
        for (instance.shapes) |shape| {
            c.point_count = 0;
            c.end_count = 0;
            c.part_count = 0;
            if (!_outline.contours(font, shape.glyph, c, identity, 0)) return error.GlyphNotRead;
            var same = c.point_count == shape.points.len and c.end_count == shape.ends.len;
            if (same) {
                for (shape.points, c.points[0..c.point_count]) |want, point| {
                    if (@as(u32, @bitCast(want.x)) != @as(u32, @bitCast(point.x)) or @as(u32, @bitCast(want.y)) != @as(u32, @bitCast(point.y)) or want.on != point.on) same = false;
                }
                if (!std.mem.eql(u32, shape.ends, c.ends[0..c.end_count])) same = false;
            }
            if (same) continue;
            std.debug.print("glyph {d} at coordinate {d} has {d} points in {d} contours:\n", .{ shape.glyph, instance.coords[0], c.point_count, c.end_count });
            for (c.points[0..c.point_count], 0..) |point, i| {
                const want: reference.Placed = if (i < shape.points.len) shape.points[i] else .{ .x = 0, .y = 0, .on = false };
                std.debug.print("  {d}: {d} {d} {}, for {d} {d} {}\n", .{ i, point.x, point.y, point.on, want.x, want.y, want.on });
            }
            return error.ReadDiffers;
        }

        // Every glyph: its measures, and its points.
        var measured: reference.Digest = .{};
        var shapes: reference.Digest = .{};
        var glyph: u32 = 0;
        while (glyph < expected.glyph_count) : (glyph += 1) {
            var one: truetype.GlyphMetrics = .{};
            try testing.expect(tb.GlyphMetrics(outline, glyph, &one));
            try testing.expectEqual(one.advance, tb.GlyphAdvance(outline, glyph));
            measured.addSigned(one.advance);
            measured.addSigned(one.left_bearing);
            measured.addSigned(one.x_min);
            measured.addSigned(one.y_min);
            measured.addSigned(one.x_max);
            measured.addSigned(one.y_max);
            c.point_count = 0;
            c.end_count = 0;
            c.part_count = 0;
            if (!_outline.contours(font, glyph, c, identity, 0)) return error.GlyphNotRead;
            shapes.add(c.point_count);
            shapes.add(c.end_count);
            for (c.points[0..c.point_count]) |point| {
                shapes.add(@bitCast(point.x));
                shapes.add(@bitCast(point.y));
                shapes.add(@intFromBool(point.on));
            }
            for (c.ends[0..c.end_count]) |end| shapes.add(end);
        }
        work.deinit(sys);
        var what = try std.fmt.bufPrint(&what_buffer, "the glyphs' measures at coordinate {d}", .{instance.coords[0]});
        try expectDigest(what, 0, instance.metrics_sha256, 0, &measured);
        what = try std.fmt.bufPrint(&what_buffer, "the glyphs' points at coordinate {d}", .{instance.coords[0]});
        try expectDigest(what, 0, instance.contours_sha256, 0, &shapes);
        tb.CloseOutline(outline);

        // The advances a font without `HVAR` has there.
        const without = try openAt(tb, sided, expected, instance);
        var advances: reference.Digest = .{};
        glyph = 0;
        while (glyph < expected.glyph_count) : (glyph += 1) {
            const advance = tb.GlyphAdvance(without, glyph);
            var one: truetype.GlyphMetrics = .{};
            try testing.expect(tb.GlyphMetrics(without, glyph, &one));
            try testing.expectEqual(advance, one.advance);
            advances.addSigned(advance);
        }
        what = try std.fmt.bufPrint(&what_buffer, "the advances by the side points at coordinate {d}", .{instance.coords[0]});
        try expectDigest(what, 0, instance.sides_sha256, 0, &advances);
        tb.CloseOutline(without);
    }
}

fn expectFont(expected: *const reference.Font) !void {
    const bytes = try reference.read(expected);
    defer testing.allocator.free(bytes);
    const size: u32 = @intCast(bytes.len);
    const start = @intFromPtr(bytes.ptr);

    var rig = try Rig.up();
    const sys = rig.sys;
    const tb = rig.tb;

    try testing.expectEqual(expected.font_count == 1, truetype.isTrueType(bytes));
    try testing.expectEqual(expected.font_count, truetype.fontCount(bytes));
    try testing.expectEqual(@as(?u32, expected.directory), truetype.fontDirectory(bytes, expected.index));
    try testing.expectEqual(@as(?u32, null), truetype.fontDirectory(bytes, expected.font_count));
    const which = [_]sdk.utility.TagItem{ .{ .tag = truetype.TTA_FontIndex, .data = expected.index }, .{} };
    const outline = tb.OpenOutline(bytes.ptr, size, &which) orelse return error.NotRead;
    const curves = expected.outlines or expected.cubic;
    const pixel_kind: fontimage.Kind = if (expected.strike_colour) .rgba32 else .alpha4;

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
    // A file's style is its first font's.
    if (expected.index == 0) try testing.expectEqual(style, truetype.styleOf(bytes));

    // Every table of the directory, where the file has it.
    try testing.expectEqual(expected.tables.len, std.mem.readInt(u16, bytes[expected.directory + 4 ..][0..2], .big));
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

    // Every glyph, or every `glyph_step`th: its measures, and its outline
    // read into the room the font says the largest takes, each contour
    // closed. Of a font of cubic curves the outline itself: the verbs and
    // the points counted, then each verb and its points.
    const verbs = try testing.allocator.alloc(u8, @max(metrics.most_verbs, 1));
    defer testing.allocator.free(verbs);
    const points = try testing.allocator.alloc(sdk.vector.Point, @max(metrics.most_points, 1));
    defer testing.allocator.free(points);
    var measures: truetype.GlyphMetrics = .{};
    digest = .{};
    var drawing: reference.Digest = .{};
    count = 0;
    var glyph: u32 = 0;
    while (glyph < expected.glyph_count) : (glyph += expected.glyph_step) {
        count += 1;
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
        if (result != truetype.TRUETYPE_OK or moves != closes or (curves and drawn and moves == 0) or (!curves and moves != 0)) {
            std.debug.print("glyph {d}: its outline answers {d}, {d} contours begun and {d} closed\n", .{ glyph, result, moves, closes });
            return error.ReadDiffers;
        }
        if (!expected.cubic) continue;
        errdefer std.debug.print("glyph {d}: its outline is not of whole units, or has a verb no cubic outline has\n", .{glyph});
        drawing.add(segments.verb_count);
        drawing.add(segments.point_count);
        var next: usize = 0;
        for (verbs[0..segments.verb_count]) |verb| {
            const kind = verbOf(verb) orelse return error.ReadDiffers;
            drawing.add(kind.number);
            for (points[next..][0..kind.points]) |point| {
                drawing.addSigned(try whole(point.x));
                drawing.addSigned(try whole(point.y));
            }
            next += kind.points;
        }
    }
    const measured = (expected.glyph_count + expected.glyph_step - 1) / expected.glyph_step;
    try expectDigest("the glyphs' measures", measured, expected.metrics_sha256, count, &digest);
    if (expected.cubic) try expectDigest("the glyphs' outlines", measured, expected.outlines_sha256, count, &drawing);
    // The few outlines written out.
    for (expected.shapes) |shape| {
        var segments = truetype.Segments{ .verbs = verbs.ptr, .points = points.ptr, .verb_room = metrics.most_verbs, .point_room = metrics.most_points };
        try testing.expectEqual(truetype.TRUETYPE_OK, tb.GlyphSegments(outline, shape.glyph, &segments));
        errdefer std.debug.print("glyph {d}: {d} verbs and {d} points, not {s}\n", .{ shape.glyph, segments.verb_count, segments.point_count, shape.verbs });
        try testing.expectEqual(shape.verbs.len, segments.verb_count);
        try testing.expectEqual(shape.points.len, segments.point_count);
        for (shape.verbs, verbs[0..shape.verbs.len]) |letter, verb| {
            const kind = verbOf(verb) orelse return error.ReadDiffers;
            try testing.expectEqual(letter, kind.letter);
        }
        for (shape.points, points[0..shape.points.len]) |want, point| {
            try testing.expectEqual(@as(f32, @floatFromInt(want[0])), point.x);
            try testing.expectEqual(@as(f32, @floatFromInt(want[1])), point.y);
        }
    }
    // One past the last.
    try testing.expect(!tb.GlyphMetrics(outline, expected.glyph_count, &measures));
    try testing.expectEqual(truetype.GlyphMetrics{}, measures);
    var none = truetype.Segments{ .verbs = verbs.ptr, .points = points.ptr, .verb_room = metrics.most_verbs, .point_room = metrics.most_points };
    try testing.expectEqual(truetype.TRUETYPEERR_GLYPH, tb.GlyphSegments(outline, expected.glyph_count, &none));

    // Rendered: an image of the characters the font has a glyph for, and
    // none of a font with neither outlines nor pictures.
    const ranges = [_]truetype.CodeRange{
        .{ .first = 0x20, .last = 0x7E },
        .{ .first = 0xA0, .last = 0x17F },
        .{ .first = 0x900, .last = 0x97F },
        .{ .first = 0x2000, .last = 0x206F },
        .{ .first = 0x1F600, .last = 0x1F64F },
    };
    const rendered = tb.RenderFontImage(outline, 16, &ranges, ranges.len);
    if (curves or expected.strikes) {
        const image = rendered orelse return error.NoImage;
        const block: [*]const u8 = @ptrCast(image);
        try testing.expect(fontimage.check(block, image.size));
        try testing.expect(fontimage.sound(block, image.size));
        try testing.expectEqual(pixel_kind, image.kind);
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
        // A glyph with a character, rendered by its number, is the
        // image's glyph byte for byte.
        const pixels = try testing.allocator.alloc(u8, glyph_room + watched);
        defer testing.allocator.free(pixels);
        @memset(pixels, untouched);
        var compared: u32 = 0;
        for (ranges) |range| {
            code = range.first;
            while (code <= range.last) : (code += 1) {
                const in_image = fontimage.find(image, code) orelse continue;
                var one = truetype.GlyphImage{ .pixels = pixels.ptr, .room = glyph_room };
                const answer = tb.RenderGlyph(outline, tb.GlyphIndex(outline, code), 16, &one);
                var by_number = one.glyph;
                by_number.data = in_image.data;
                const same = answer == truetype.TRUETYPE_OK and one.kind == image.kind and
                    std.meta.eql(by_number, in_image.*) and
                    std.mem.eql(u8, fontimage.pixelsOf(image, in_image)[0..one.size], pixels[0..one.size]);
                if (!same) {
                    std.debug.print("U+{X:0>4}: by its number it answers {d} and is not the image's glyph\n", .{ code, answer });
                    return error.ReadDiffers;
                }
                for (pixels[one.size..][0..watched]) |byte| try testing.expectEqual(untouched, byte);
                @memset(pixels[0..one.size], untouched);
                compared += 1;
            }
        }
        try testing.expect(compared >= 95);
        sys.FreeVec(image);

        // Every glyph by its number, at the image's height and at a
        // taller one, where each glyph with an outline or a picture has
        // ink.
        _ = try expectGlyphsRendered(tb, outline, &metrics, 16, pixels, pixel_kind, expected.strikes);
        const tall = try expectGlyphsRendered(tb, outline, &metrics, 64, pixels, pixel_kind, expected.strikes);
        try testing.expectEqual(tall.drawn, tall.inked);
        try testing.expect(tall.inked > expected.glyph_count / 2);

        // Against libfreetype: the ink of every `ink_step`th glyph, the
        // coverage of all its pixels summed.
        for (expected.inks, 0..) |theirs, i| {
            const number: u32 = @intCast(i * expected.ink_step);
            var one = truetype.GlyphImage{ .pixels = pixels.ptr, .room = glyph_room };
            try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, number, expected.ink_rows, &one));
            var ours: u32 = 0;
            for (pixels[0..one.size]) |byte| ours += @as(u32, (byte >> 4) + (byte & 0x0F)) * 17;
            @memset(pixels[0..one.size], untouched);
            const apart = @max(ours, theirs) - @min(ours, theirs);
            if (apart <= ink_least * 255 + @max(ours, theirs) * ink_apart / 1000) continue;
            std.debug.print("glyph {d} at {d} rows: ink {d}, libfreetype's {d}\n", .{ number, expected.ink_rows, ours, theirs });
            return error.ReadDiffers;
        }
        // A few pixel by pixel, over both boxes.
        for (expected.pictures) |picture| {
            var one = truetype.GlyphImage{ .pixels = pixels.ptr, .room = glyph_room };
            try testing.expectEqual(truetype.TRUETYPE_OK, tb.RenderGlyph(outline, picture.glyph, expected.picture_rows, &one));
            const box = one.glyph;
            const height: i32 = @intCast(picture.rows.len);
            const width: i32 = @intCast(picture.width);
            var y = @min(picture.top, box.top);
            while (y < @max(picture.top + height, @as(i32, box.top) + box.rows)) : (y += 1) {
                var x = @min(picture.left, box.left);
                while (x < @max(picture.left + width, @as(i32, box.left) + box.width)) : (x += 1) {
                    const inside = y >= picture.top and y < picture.top + height and x >= picture.left and x < picture.left + width;
                    const theirs: i32 = if (inside) try std.fmt.charToDigit(picture.rows[@intCast(y - picture.top)][@intCast(x - picture.left)], 16) else 0;
                    const ours: i32 = levelAt(&box, pixels, x, y);
                    if (@abs(ours - theirs) <= pixel_apart) continue;
                    std.debug.print("glyph {d} at {d} rows: pixel {d}, {d} is {d}, libfreetype's {d}\n", .{ picture.glyph, expected.picture_rows, x, y, ours, theirs });
                    return error.ReadDiffers;
                }
            }
            @memset(pixels[0..one.size], untouched);
        }
        // One past the last.
        var past = truetype.GlyphImage{ .pixels = pixels.ptr, .room = glyph_room, .size = 1 };
        try testing.expectEqual(truetype.TRUETYPEERR_GLYPH, tb.RenderGlyph(outline, expected.glyph_count, 16, &past));
        try testing.expectEqual(@as(u32, 0), past.size);
        try testing.expectEqual(fontimage.Glyph{}, past.glyph);

        if (expected.strikes) try expectPictures(&rig, outline, expected, pixels);
    } else {
        try testing.expect(rendered == null);
        // A font of neither has no glyph to render by its number.
        var byte: [1]u8 = .{untouched};
        var glyph_number: u32 = 0;
        while (glyph_number < expected.glyph_count) : (glyph_number += 97) {
            var none_of = truetype.GlyphImage{ .pixels = &byte, .room = 1, .size = 1 };
            try testing.expectEqual(truetype.TRUETYPEERR_GLYPH, tb.RenderGlyph(outline, glyph_number, 16, &none_of));
            try testing.expectEqual(@as(u32, 0), none_of.size);
            try testing.expectEqual(fontimage.Glyph{}, none_of.glyph);
        }
        try testing.expectEqual(untouched, byte[0]);
    }

    tb.CloseOutline(outline);
    if (expected.instances.len != 0) try expectInstances(&rig, bytes, expected);
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

test "truetype: spleen-2.2.0/spleen-8x16.otb as fontTools reads it" {
    try expectFont(reference.spleen_8x16);
}

test "truetype: source-sans/SourceSans3-Regular.otf as fontTools reads it" {
    try expectFont(reference.source_sans_3_regular);
}

test "truetype: source-sans/SourceSans3VF-Upright.ttf as fontTools reads it, at its default and away from it" {
    try testing.expect(reference.source_sans_3_vf.instances.len != 0);
    try expectFont(reference.source_sans_3_vf);
}

test "truetype: noto/NotoSansCJK-Regular.ttc, its first font, as fontTools reads it" {
    try expectFont(reference.noto_sans_cjk_jp_regular);
}

test "truetype: noto/NotoSansCJK-Regular.ttc, its third font, as fontTools reads it" {
    try expectFont(reference.noto_sans_cjk_sc_regular);
}

test "truetype: there is a test for every font with values" {
    // The nine above, each named with its file.
    try testing.expectEqual(@as(usize, 9), reference.fonts.len);
    try testing.expectEqualStrings("source-sans/SourceSans3VF-Upright.ttf", reference.source_sans_3_vf.file);
    try testing.expectEqualStrings("spleen-2.2.0/spleen-8x16.otb", reference.spleen_8x16.file);
    try testing.expectEqualStrings("source-sans/SourceSans3-Regular.otf", reference.source_sans_3_regular.file);
    try testing.expectEqualStrings("noto/NotoSansCJK-Regular.ttc", reference.noto_sans_cjk_jp_regular.file);
    try testing.expectEqual(@as(u32, 0), reference.noto_sans_cjk_jp_regular.index);
    try testing.expectEqualStrings("noto/NotoSansCJK-Regular.ttc", reference.noto_sans_cjk_sc_regular.file);
    try testing.expectEqual(@as(u32, 2), reference.noto_sans_cjk_sc_regular.index);
    try testing.expectEqualStrings("go/Go-Regular.ttf", reference.go_regular.file);
    try testing.expectEqualStrings("liberation-fonts-ttf-2.1.5/LiberationSans-Regular.ttf", reference.liberation_sans_regular.file);
    try testing.expectEqualStrings("noto/NotoSansDevanagari-Regular.ttf", reference.noto_sans_devanagari_regular.file);
    try testing.expectEqualStrings("noto/NotoColorEmoji.ttf", reference.noto_color_emoji.file);
}
