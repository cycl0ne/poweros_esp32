// SPDX-License-Identifier: MIT
//! Host tests of the settings files' forms (`sdk.prefs`): lines read,
//! checked, turned into tags and written back, and the files a fresh disk
//! has written in the form the SDK writes.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");
const prefs = sdk.prefs;
const style = sdk.intuition.style;

test "style.prefs: a line read, its shorthands as both sides, its tags, written back" {
    var line: prefs.style.Line = undefined;
    try testing.expect(prefs.style.parse("part=main STATE=HOVERED BORDER=FLAT BORDERCOLOUR=#3A6EA5 PADDING 4 TRANSITION=250", &line) == null);
    try testing.expectEqualStrings("MAIN", line.get(.part).?);
    try testing.expectEqualStrings("4", line.get(.padding_x).?);
    try testing.expectEqualStrings("4", line.get(.padding_y).?);
    try testing.expect(line.get(.padding) == null);

    var tags: [prefs.style.tags_per_line]sdk.utility.TagItem = undefined;
    var fill: sdk.graphics.FillStyle = undefined;
    const n = prefs.style.toTags(&line, &tags, &fill);
    try testing.expectEqual(@as(usize, 7), n);
    try testing.expectEqual(style.STYLE_Part, tags[0].tag);
    try testing.expectEqual(@as(usize, style.STATE_HOVERED), tags[1].data);
    try testing.expectEqual(style.STYLE_BorderRGB, tags[3].tag);
    try testing.expectEqual(@as(usize, 0xFF3A_6EA5), tags[3].data);
    try testing.expectEqual(style.STYLE_Transition, tags[6].tag);

    var out: [prefs.style.max_line]u8 = undefined;
    const written = out[0..prefs.style.write(&line, &out)];
    try testing.expectEqualStrings("PART=MAIN STATE=HOVERED BORDER=FLAT BORDERCOLOUR=#3A6EA5 PADDINGX=4 PADDINGY=4 TRANSITION=250", written);
    var again: prefs.style.Line = undefined;
    try testing.expect(prefs.style.parse(written, &again) == null);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&line), std.mem.asBytes(&again));

    // A shaded background is a fill.
    try testing.expect(prefs.style.parse("PART=MAIN BACKGROUND=#FAFBFC..#D8DCE2", &line) == null);
    try testing.expect(prefs.style.shaded(&line));
    _ = prefs.style.toTags(&line, &tags, &fill);
    try testing.expectEqual(style.STYLE_BackgroundFill, tags[1].tag);
    try testing.expectEqual(@as(u32, 0xFFD8_DCE2), fill.stops[1].pen);

    // What is wrong is said.
    try testing.expect(prefs.style.parse("PART=NOPE", &line) != null);
    try testing.expect(prefs.style.parse("STATE=PRESSED", &line) != null);
    try testing.expect(prefs.style.parse("PART=MAIN BORDER=WAVY", &line) != null);
    try testing.expect(prefs.style.parse("PART=MAIN TEXT=#12", &line) != null);
    try testing.expect(prefs.style.parse("PART=MAIN WHAT=1", &line) != null);
}

test "font.prefs and intuition.prefs: a line read and written back" {
    var fonts: prefs.font.Line = undefined;
    try testing.expect(prefs.font.parse("SCREEN=go.font/10P DEFAULT go.font/9P", &fonts) == null);
    try testing.expectEqualStrings("go.font/9P", fonts.get(.default).?);
    try testing.expect(fonts.get(.fixed) == null);
    var name: [prefs.font.value_len:0]u8 = undefined;
    const attr = prefs.font.attrOf(fonts.get(.screen).?, &name).?;
    try testing.expectEqual(@as(u16, 10), attr.y_size);
    try testing.expect(attr.flags & sdk.graphics.FPF_POINTS != 0);
    var out: [128]u8 = undefined;
    try testing.expectEqualStrings("SCREEN=go.font/10P DEFAULT=go.font/9P", out[0..prefs.font.write(&fonts, &out)]);
    try testing.expect(prefs.font.parse("SCREEN=go.font", &fonts) != null);

    var settings: prefs.intuition.Settings = .{};
    try testing.expect(prefs.intuition.parse("DOUBLECLICK=400 KEYBOARD=always", &settings) == null);
    try testing.expectEqual(@as(u32, 400), settings.double_click);
    try testing.expectEqual(sdk.intuition.KEYBOARD_ALWAYS, settings.keyboard);
    try testing.expectEqual(@as(u32, 16), settings.screen_font);
    try testing.expectEqualStrings("DOUBLECLICK=400 SCREENFONT=16 KEYBOARD=ALWAYS", out[0..prefs.intuition.write(&settings, &out)]);
    // Only what the line gave becomes a tag: the font height was left out.
    var tags: [3]sdk.utility.TagItem = undefined;
    try testing.expectEqual(@as(usize, 2), prefs.intuition.toTags(&settings, &tags));
    try testing.expectEqual(sdk.intuition.IPREFS_DoubleClick, tags[0].tag);
    try testing.expectEqual(@as(usize, 400), tags[0].data);
    try testing.expectEqual(sdk.intuition.IPREFS_Keyboard, tags[1].tag);
    try testing.expect(prefs.intuition.parse("KEYBOARD=SOMETIMES", &settings) != null);
}

test "the settings files of a fresh disk: the explanation the SDK writes" {
    try testing.expectEqualStrings(prefs.style.header, @embedFile("../env-archive/Sys/style.prefs"));
    try testing.expectEqualStrings(prefs.intuition.header, @embedFile("../env-archive/Sys/intuition.prefs"));
    try testing.expectEqualStrings(prefs.palette.header, @embedFile("../env-archive/Sys/palette.prefs"));
    const fonts = @embedFile("../env-archive/Sys/font.prefs");
    try testing.expect(std.mem.startsWith(u8, fonts, prefs.font.header));
    // Every commented line of the style's default reads as a line.
    var lines = prefs.Lines{ .text = prefs.style.header };
    var read: u32 = 0;
    while (lines.next()) |l| {
        if (!std.mem.startsWith(u8, l.text, "# PART=")) continue;
        var line: prefs.style.Line = undefined;
        try testing.expect(prefs.style.parse(l.text[2..], &line) == null);
        read += 1;
    }
    try testing.expect(read > 20);
}

test "the styles the editor offers: every line read" {
    const presets = [_][]const u8{
        @embedFile("../presets/styles/Classic.prefs"),
        @embedFile("../presets/styles/Rounded.prefs"),
        @embedFile("../presets/styles/Flat.prefs"),
        @embedFile("../presets/styles/Soft.prefs"),
        @embedFile("../presets/styles/Contrast.prefs"),
    };
    for (presets) |text| {
        // A comment first, saying what it is.
        try testing.expect(std.mem.startsWith(u8, text, "# "));
        var lines = prefs.Lines{ .text = text };
        while (lines.next()) |l| {
            if (!prefs.style.hasWords(l.text)) continue;
            var line: prefs.style.Line = undefined;
            try testing.expect(prefs.style.parse(l.text, &line) == null);
        }
    }
}

test "palette.prefs: the pens read and written back" {
    const sc = sdk.intuition.screens;
    var palette: prefs.palette.Palette = .{};
    try testing.expect(prefs.palette.parse("BACKGROUND=#336699 text=#FFFFFF", &palette) == null);
    try testing.expectEqual(@as(u32, 0xFF33_6699), palette.pens[sc.BACKGROUNDPEN]);
    try testing.expect(palette.given & (@as(u32, 1) << sc.TEXTPEN) != 0);
    try testing.expect(palette.given & (@as(u32, 1) << sc.FILLPEN) == 0);
    var out: [256]u8 = undefined;
    const line = out[0..prefs.palette.write(&palette.pens, &out)];
    var again: prefs.palette.Palette = .{};
    try testing.expect(prefs.palette.parse(line, &again) == null);
    try testing.expectEqual(palette.pens[sc.BACKGROUNDPEN] & 0xFFFFFF, again.pens[sc.BACKGROUNDPEN] & 0xFFFFFF);
    try testing.expectEqual(@as(u32, 0xFFF), again.given);
    try testing.expect(prefs.palette.parse("BACKGROUND=blue", &again) != null);
    // The built-in pens the header writes out read as a line.
    var lines = prefs.Lines{ .text = prefs.palette.header };
    var found = false;
    while (lines.next()) |l| {
        if (!std.mem.startsWith(u8, l.text, "# DETAIL=")) continue;
        try testing.expect(prefs.palette.parse(l.text[2..], &again) == null);
        found = true;
    }
    try testing.expect(found);
}
