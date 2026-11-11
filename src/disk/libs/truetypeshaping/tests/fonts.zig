// SPDX-License-Identifier: MIT
//! Host tests of truetypeshaping.library on the fonts
//! `scripts/fetch-fonts.sh` fetches, against what a second applier makes
//! of fontTools' reading of the same tables.
//!
//! There is a test for each font `reference.zig` has values for. It reads
//! the file, opens it with truetype.library, and for each case written
//! for the font shapes every one of the font's runs with ShapeGlyphs
//! through the jump table: all the font's glyphs, eight at a time, and
//! the runs the reference writes out. What comes out is hashed and
//! compared with the case's digest, and the runs that changed are
//! counted. A test is skipped when its font is not fetched, and fails by
//! the font's name when the file is not the one the values were made
//! from.
//!
//! A case whose digest differs is shaped once more and printed, a run a
//! line, in the form `scripts/shape-reference.py --show <font> <case>`
//! prints the reference's: the two are compared line by line to find the
//! run and the glyph that differ.

const std = @import("std");
const sdk = @import("sdk");
const truetype = sdk.truetype;
const tts = sdk.truetypeshaping;
const reference = @import("reference.zig");
const Rig = @import("library.zig").Rig;

const testing = std.testing;

/// The most glyphs a run goes in with, and the room it is shaped in.
const most_in = 32;
const room = 256;

/// The most features a case names.
const most_features = 32;

/// The runs of a font, one after another: every glyph, `reference.every`
/// to a run, and then the ones written out.
const Runs = struct {
    glyph_count: u32,
    /// The first glyph of the next run of every glyph.
    start: u32 = 0,
    /// The written runs still to come.
    rest: []const u8,

    /// The next run in `glyphs`: how many it has, or null after the last.
    fn next(runs: *Runs, glyphs: *[most_in]u32) !?u32 {
        if (runs.start < runs.glyph_count) {
            var count: u32 = 0;
            while (count < reference.every and runs.start + count < runs.glyph_count) : (count += 1) {
                glyphs[count] = runs.start + count;
            }
            runs.start += count;
            return count;
        }
        if (runs.rest.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, runs.rest, '\n') orelse runs.rest.len;
        const line = runs.rest[0..end];
        runs.rest = runs.rest[@min(end + 1, runs.rest.len)..];
        var count: u32 = 0;
        var numbers = std.mem.tokenizeScalar(u8, line, ' ');
        while (numbers.next()) |number| : (count += 1) {
            if (count == most_in) return error.RunTooLong;
            glyphs[count] = try std.fmt.parseInt(u32, number, 16);
        }
        return count;
    }
};

/// What a case's runs were shaped to: their digest, and how many came
/// out other than they went in.
const Outcome = struct {
    sha256: [64]u8,
    changed: u32,
};

/// A tag of four characters as a number, 0 for an empty one.
fn tagOf(text: []const u8) u32 {
    return if (text.len == 4) truetype.tableTag(text[0..4]) else 0;
}

/// Every run of `expected` shaped for `case`; each printed too when
/// `show` is set.
fn shapeCase(rig: *Rig, outline: *truetype.Outline, expected: *const reference.Font, case: *const reference.Case, show: bool) !Outcome {
    var features: [most_features + 1]tts.Feature = undefined;
    const feature_count = case.features.len / 4;
    if (case.features.len % 4 != 0 or feature_count > most_features) return error.CaseNotRead;
    for (0..feature_count) |index| features[index] = .{ .tag = tagOf(case.features[index * 4 ..][0..4]) };
    features[feature_count] = .{ .tag = 0 };
    const direction: u32 = if (case.backward) tts.TTS_RIGHT_TO_LEFT else tts.TTS_LEFT_TO_RIGHT;

    var digest: reference.Digest = .{};
    var changed: u32 = 0;
    var place: u32 = 0;
    var runs: Runs = .{ .glyph_count = expected.glyph_count, .rest = expected.runs };
    var glyphs: [most_in]u32 = undefined;
    var shaped: [room]tts.ShapedGlyph = undefined;
    while (try runs.next(&glyphs)) |count| : (place += 1) {
        for (glyphs[0..count], 0..) |glyph, index| shaped[index] = .{ .glyph = glyph, .cluster = @intCast(index) };
        var run: tts.ShapedRun = .{ .glyphs = &shaped, .room = room, .count = count };
        try testing.expectEqual(tts.TTS_OK, rig.sb.ShapeGlyphs(outline, tagOf(case.script), direction, tagOf(case.language), &features, &run));

        digest.add(run.count);
        var same = run.count == count;
        for (shaped[0..run.count], 0..) |glyph, index| {
            digest.add(glyph.glyph);
            digest.add(glyph.cluster);
            digest.addSigned(glyph.advance);
            digest.addSigned(glyph.x_offset);
            digest.addSigned(glyph.y_offset);
            if (!same) continue;
            var metrics: truetype.GlyphMetrics = .{};
            _ = rig.tb.GlyphMetrics(outline, glyph.glyph, &metrics);
            same = glyph.glyph == glyphs[index] and glyph.cluster == index and glyph.advance == metrics.advance and
                glyph.x_offset == 0 and glyph.y_offset == 0;
        }
        if (!same) changed += 1;

        if (!show) continue;
        std.debug.print("{d}:", .{place});
        for (shaped[0..run.count]) |glyph| {
            std.debug.print(" {d}/{d}/{d}/{d}/{d}", .{ glyph.glyph, glyph.cluster, glyph.advance, glyph.x_offset, glyph.y_offset });
        }
        std.debug.print("\n", .{});
    }
    return .{ .sha256 = digest.hex(), .changed = changed };
}

/// The font `expected` is of, shaped by the library for each of its
/// cases, gives what the reference has.
fn expectFont(expected: *const reference.Font) !void {
    const bytes = try reference.read(expected);
    defer testing.allocator.free(bytes);

    var rig = try Rig.up();
    const outline = rig.tb.OpenOutline(bytes.ptr, @intCast(bytes.len), null) orelse return error.NotRead;
    var metrics: truetype.FontMetrics = .{};
    rig.tb.FontMetrics(outline, &metrics);
    try testing.expectEqual(expected.glyph_count, metrics.glyph_count);

    for (expected.cases, 0..) |*case, number| {
        const outcome = try shapeCase(&rig, outline, expected, case, false);
        if (outcome.changed == case.changed and std.mem.eql(u8, &outcome.sha256, case.sha256)) continue;
        std.debug.print("case {d} (script \"{s}\", language \"{s}\", features \"{s}\", backward {}): {d} runs changed, hashing to {s}, not {d} to {s}\n", .{
            number,          case.script,    case.language, case.features, case.backward,
            outcome.changed, outcome.sha256, case.changed,  case.sha256,
        });
        _ = try shapeCase(&rig, outline, expected, case, true);
        return error.ShapedDiffers;
    }

    rig.tb.CloseOutline(outline);
    try rig.down();
}

test "truetypeshaping: go/Go-Regular.ttf, a font of no layout tables" {
    try expectFont(reference.go_regular);
}

test "truetypeshaping: liberation-fonts-ttf-2.1.5/LiberationSans-Regular.ttf as its lookups are read" {
    try expectFont(reference.liberation_sans_regular);
}

test "truetypeshaping: noto/NotoSansDevanagari-Regular.ttf as its lookups are read" {
    try expectFont(reference.noto_sans_devanagari_regular);
}

test "truetypeshaping: noto/NotoColorEmoji.ttf as its lookups are read" {
    try expectFont(reference.noto_color_emoji);
}

test "truetypeshaping: there is a test for every font with values" {
    // The four above, each named with its file.
    try testing.expectEqual(@as(usize, 4), reference.all.len);
    try testing.expectEqualStrings("go/Go-Regular.ttf", reference.go_regular.file);
    try testing.expectEqualStrings("liberation-fonts-ttf-2.1.5/LiberationSans-Regular.ttf", reference.liberation_sans_regular.file);
    try testing.expectEqualStrings("noto/NotoSansDevanagari-Regular.ttf", reference.noto_sans_devanagari_regular.file);
    try testing.expectEqualStrings("noto/NotoColorEmoji.ttf", reference.noto_color_emoji.file);
}
