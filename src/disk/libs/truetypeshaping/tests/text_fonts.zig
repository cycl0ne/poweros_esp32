// SPDX-License-Identifier: MIT
//! Host tests of ShapeText on the fonts `scripts/fetch-fonts.sh` fetches,
//! against what HarfBuzz shapes the same texts to.
//!
//! There is a test for each font `text_reference.zig` has texts for. It
//! reads the file, opens it with truetype.library, and shapes each of the
//! font's texts with ShapeText through the jump table, with the case's
//! direction, language and features - a text of a variable font's
//! instance with the font opened there. Each glyph that comes out is
//! compared with the one written down: its number, its cluster, its
//! advance and its offsets. A test is skipped when its font is not
//! fetched, and fails by the font's name when the file is not the one
//! the values were made with.
//!
//! Every case that differs is printed, the glyphs shaped in one line and
//! those expected in the next, each as glyph/cluster/advance/right/up -
//! the form `scripts/shape-text-reference.py --show <font>` prints.

const std = @import("std");
const sdk = @import("sdk");
const truetype = sdk.truetype;
const tts = sdk.truetypeshaping;
const reference = @import("text_reference.zig");
const Rig = @import("library.zig").Rig;

const testing = std.testing;

/// The room a text is shaped in, and the most features and axes a case
/// names.
const room = 256;
const most_features = 16;
const most_axes = 4;

/// A tag of four characters as a number, 0 for an empty one.
fn tagOf(text: []const u8) u32 {
    return if (text.len == 4) truetype.tableTag(text[0..4]) else 0;
}

/// Whether the text of `case`, shaped with `outline`, gives the glyphs
/// written down for it. One that does not is printed.
fn sameAsWritten(rig: *Rig, outline: *truetype.Outline, case: *const reference.Case) !bool {
    var features: [most_features + 1]tts.Feature = undefined;
    if (case.features.len > most_features) return error.CaseNotRead;
    for (case.features, 0..) |feature, index| {
        features[index] = .{ .tag = tagOf(feature.tag), .value = feature.value, .first = feature.first, .last = feature.last };
    }
    features[case.features.len] = .{ .tag = 0 };
    const direction: u32 = if (case.backward) tts.TTS_RIGHT_TO_LEFT else tts.TTS_LEFT_TO_RIGHT;

    var shaped: [room]tts.ShapedGlyph = undefined;
    var run: tts.ShapedRun = .{ .glyphs = &shaped, .room = room };
    const result = rig.sb.ShapeText(outline, case.text.ptr, @intCast(case.text.len), direction, tagOf(case.language), &features, &run);
    try testing.expectEqual(tts.TTS_OK, result);

    var same = run.count == case.glyphs.len;
    if (same) {
        for (shaped[0..run.count], case.glyphs) |glyph, written| {
            if (glyph.glyph == written[0] and glyph.cluster == written[1] and glyph.advance == written[2] and
                glyph.x_offset == written[3] and glyph.y_offset == written[4]) continue;
            same = false;
            break;
        }
    }
    if (same) return true;
    std.debug.print("\"{s}\" is shaped to\n ", .{case.name});
    for (shaped[0..run.count]) |glyph| {
        std.debug.print(" {d}/{d}/{d}/{d}/{d}", .{ glyph.glyph, glyph.cluster, glyph.advance, glyph.x_offset, glyph.y_offset });
    }
    std.debug.print("\nand not to\n ", .{});
    for (case.glyphs) |written| {
        std.debug.print(" {d}/{d}/{d}/{d}/{d}", .{ written[0], written[1], written[2], written[3], written[4] });
    }
    std.debug.print("\n", .{});
    return false;
}

/// The texts of `expected`, shaped by the library with the font they are
/// of, give what is written down for them.
fn expectFont(expected: *const reference.Font) !void {
    const bytes = try reference.read(expected);
    defer testing.allocator.free(bytes);

    var rig = try Rig.up();
    const outline = rig.tb.OpenOutline(bytes.ptr, @intCast(bytes.len), null) orelse return error.NotRead;
    var differing: u32 = 0;
    for (expected.cases) |*case| {
        if (case.axes.len == 0) {
            if (!try sameAsWritten(&rig, outline, case)) differing += 1;
            continue;
        }
        // The font opened at the case's instance.
        if (case.axes.len > most_axes) return error.CaseNotRead;
        var asked: [most_axes]truetype.AxisValue = undefined;
        for (case.axes, 0..) |axis, index| asked[index] = .{ .tag = tagOf(axis.tag), .value = axis.value };
        const tags = [_]sdk.utility.TagItem{
            .{ .tag = truetype.TTA_Axes, .data = @intFromPtr(&asked) },
            .{ .tag = truetype.TTA_AxisCount, .data = case.axes.len },
            .{},
        };
        const instance = rig.tb.OpenOutline(bytes.ptr, @intCast(bytes.len), &tags) orelse return error.NotRead;
        if (!try sameAsWritten(&rig, instance, case)) differing += 1;
        rig.tb.CloseOutline(instance);
    }
    rig.tb.CloseOutline(outline);
    try rig.down();
    if (differing != 0) return error.ShapedDiffers;
}

test "truetypeshaping: texts in go/Go-Regular.ttf, a font of no layout tables" {
    try expectFont(reference.go_regular);
}

test "truetypeshaping: texts in liberation-fonts-ttf-2.1.5/LiberationSans-Regular.ttf" {
    try expectFont(reference.liberation_sans_regular);
}

test "truetypeshaping: texts in noto/NotoSansDevanagari-Regular.ttf" {
    try expectFont(reference.noto_sans_devanagari_regular);
}

test "truetypeshaping: texts in noto/NotoColorEmoji.ttf" {
    try expectFont(reference.noto_color_emoji);
}

test "truetypeshaping: texts in source-sans/SourceSans3VF-Upright.ttf, at its default and at other weights" {
    try expectFont(reference.source_sans_3_vf);
}

test "truetypeshaping: texts in source-sans/SourceSans3VF-Upright.otf, at its default and at other weights" {
    try expectFont(reference.source_sans_3_vf_otf);
}

test "truetypeshaping: there is a test for every font with texts" {
    // The six above, each named with its file.
    try testing.expectEqual(@as(usize, 6), reference.all.len);
    try testing.expectEqualStrings("go/Go-Regular.ttf", reference.go_regular.file);
    try testing.expectEqualStrings("liberation-fonts-ttf-2.1.5/LiberationSans-Regular.ttf", reference.liberation_sans_regular.file);
    try testing.expectEqualStrings("noto/NotoSansDevanagari-Regular.ttf", reference.noto_sans_devanagari_regular.file);
    try testing.expectEqualStrings("noto/NotoColorEmoji.ttf", reference.noto_color_emoji.file);
    try testing.expectEqualStrings("source-sans/SourceSans3VF-Upright.ttf", reference.source_sans_3_vf.file);
    try testing.expectEqualStrings("source-sans/SourceSans3VF-Upright.otf", reference.source_sans_3_vf_otf.file);
}
