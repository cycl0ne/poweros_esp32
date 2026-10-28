// SPDX-License-Identifier: MIT
//! Host tests of the settings files' forms (`sdk.prefs`): lines read,
//! checked, turned into tags and written back, and the files a fresh disk
//! has written in the form the SDK writes.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");
const prefs = sdk.prefs;
const style = sdk.intuition.style;
const UtilityBase = sdk.interface.utility.UtilityBase;
const kexec = @import("host_rom").exec;
const utility_library = @import("host_rom").utility;

/// utility.library on the host: the forms read their lines through its
/// NextSetting.
fn utilityUp() !*UtilityBase {
    return @ptrCast(try utility_library.setUp());
}

/// utility.library taken down again, and nothing of it left.
fn utilityDown(ub: *UtilityBase) !void {
    try utility_library.tearDown(@ptrCast(@alignCast(ub)));
}

test "style.prefs: a line read, its shorthands as both sides, its tags, written back" {
    const ub = try utilityUp();
    defer kexec.deinit();
    var line: prefs.style.Line = undefined;
    try testing.expect(prefs.style.parse(ub, "part=main STATE=HOVERED BORDER=FLAT BORDERCOLOUR=#3A6EA5 PADDING 4 TRANSITION=250", &line) == null);
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
    try testing.expect(prefs.style.parse(ub, written, &again) == null);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&line), std.mem.asBytes(&again));

    // A shaded background is a fill.
    try testing.expect(prefs.style.parse(ub, "PART=MAIN BACKGROUND=#FAFBFC..#D8DCE2", &line) == null);
    try testing.expect(prefs.style.shaded(&line));
    _ = prefs.style.toTags(&line, &tags, &fill);
    try testing.expectEqual(style.STYLE_BackgroundFill, tags[1].tag);
    try testing.expectEqual(@as(u32, 0xFFD8_DCE2), fill.stops[1].pen);

    // What is wrong is said.
    try testing.expect(prefs.style.parse(ub, "PART=NOPE", &line) != null);
    try testing.expect(prefs.style.parse(ub, "STATE=PRESSED", &line) != null);
    try testing.expect(prefs.style.parse(ub, "PART=MAIN BORDER=WAVY", &line) != null);
    try testing.expect(prefs.style.parse(ub, "PART=MAIN TEXT=#12", &line) != null);
    try testing.expect(prefs.style.parse(ub, "PART=MAIN WHAT=1", &line) != null);
    try utilityDown(ub);
}

test "font.prefs and intuition.prefs: a line read and written back" {
    const ub = try utilityUp();
    defer kexec.deinit();
    var fonts: prefs.font.Line = undefined;
    try testing.expect(prefs.font.parse(ub, "SCREEN=go.font/10P DEFAULT go.font/9P", &fonts) == null);
    try testing.expectEqualStrings("go.font/9P", fonts.get(.default).?);
    try testing.expect(fonts.get(.fixed) == null);
    var name: [prefs.font.value_len:0]u8 = undefined;
    const attr = prefs.font.attrOf(fonts.get(.screen).?, &name).?;
    try testing.expectEqual(@as(u16, 10), attr.y_size);
    try testing.expect(attr.flags & sdk.graphics.FPF_POINTS != 0);
    var out: [128]u8 = undefined;
    try testing.expectEqualStrings("SCREEN=go.font/10P DEFAULT=go.font/9P", out[0..prefs.font.write(&fonts, &out)]);
    try testing.expect(prefs.font.parse(ub, "SCREEN=go.font", &fonts) != null);
    // The desktop's icons have a font of their own, written last.
    try testing.expect(prefs.font.parse(ub, "ICON=go.font/12 FIXED=go-mono.font/16", &fonts) == null);
    try testing.expectEqualStrings("go.font/12", fonts.get(.icon).?);
    try testing.expectEqualStrings("FIXED=go-mono.font/16 ICON=go.font/12", out[0..prefs.font.write(&fonts, &out)]);
    // So have documents and the code in them, written after the icons'.
    try testing.expect(prefs.font.parse(ub, "CODE=go-mono.font/15 DOCUMENT=go.font/18 ICON=go.font/12", &fonts) == null);
    try testing.expectEqualStrings("go.font/18", fonts.get(.document).?);
    try testing.expectEqualStrings("ICON=go.font/12 DOCUMENT=go.font/18 CODE=go-mono.font/15", out[0..prefs.font.write(&fonts, &out)]);
    try testing.expectEqual(prefs.font.Which.fixed, prefs.font.standIn(.code).?);
    try testing.expectEqual(prefs.font.Which.default, prefs.font.standIn(.document).?);
    try testing.expect(prefs.font.standIn(.screen) == null);

    var settings: prefs.intuition.Settings = .{};
    try testing.expect(prefs.intuition.parse(ub, "DOUBLECLICK=400 KEYBOARD=always", &settings) == null);
    try testing.expectEqual(@as(u32, 400), settings.double_click);
    try testing.expectEqual(sdk.intuition.KEYBOARD_ALWAYS, settings.keyboard);
    try testing.expectEqual(@as(u32, 16), settings.screen_font);
    try testing.expectEqualStrings("DOUBLECLICK=400 SCREENFONT=16 KEYBOARD=ALWAYS OFFSCREEN=NO WIDEGADGETS=NO CORNERS=6 SHADOW=12 FADE=160", out[0..prefs.intuition.write(&settings, &out)]);
    // Only what the line gave becomes a tag: the font height was left out.
    var tags: [5]sdk.utility.TagItem = undefined;
    try testing.expectEqual(@as(usize, 2), prefs.intuition.toTags(&settings, &tags));
    try testing.expectEqual(sdk.intuition.IPREFS_DoubleClick, tags[0].tag);
    try testing.expectEqual(@as(usize, 400), tags[0].data);
    try testing.expectEqual(sdk.intuition.IPREFS_Keyboard, tags[1].tag);
    try testing.expect(prefs.intuition.parse(ub, "KEYBOARD=SOMETIMES", &settings) != null);
    // Windows past the screen's edges: YES or NO, and a tag of its own.
    try testing.expect(prefs.intuition.parse(ub, "OFFSCREEN=yes", &settings) == null);
    try testing.expectEqual(@as(u32, 1), settings.off_screen);
    try testing.expectEqual(@as(usize, 3), prefs.intuition.toTags(&settings, &tags));
    try testing.expectEqual(sdk.intuition.IPREFS_OffScreen, tags[2].tag);
    try testing.expectEqual(@as(usize, 1), tags[2].data);
    try testing.expectEqualStrings("DOUBLECLICK=400 SCREENFONT=16 KEYBOARD=ALWAYS OFFSCREEN=YES WIDEGADGETS=NO CORNERS=6 SHADOW=12 FADE=160", out[0..prefs.intuition.write(&settings, &out)]);
    try testing.expect(prefs.intuition.parse(ub, "OFFSCREEN=MAYBE", &settings) != null);
    // The title bars' gadgets wide: YES or NO, and a tag of its own.
    try testing.expect(prefs.intuition.parse(ub, "WIDEGADGETS=yes", &settings) == null);
    try testing.expectEqual(@as(u32, 1), settings.wide_gadgets);
    try testing.expectEqual(@as(usize, 4), prefs.intuition.toTags(&settings, &tags));
    try testing.expectEqual(sdk.intuition.IPREFS_WideGadgets, tags[3].tag);
    try testing.expectEqual(@as(usize, 1), tags[3].data);
    try testing.expectEqualStrings("DOUBLECLICK=400 SCREENFONT=16 KEYBOARD=ALWAYS OFFSCREEN=YES WIDEGADGETS=YES CORNERS=6 SHADOW=12 FADE=160", out[0..prefs.intuition.write(&settings, &out)]);
    try testing.expect(prefs.intuition.parse(ub, "WIDEGADGETS=SOMETIMES", &settings) != null);
    // A window's corners, shadow and fade: numbers, 0 for none, each a
    // tag of its own.
    try testing.expect(prefs.intuition.parse(ub, "CORNERS=0 SHADOW=20 FADE=0", &settings) == null);
    var more: [8]sdk.utility.TagItem = undefined;
    try testing.expectEqual(@as(usize, 7), prefs.intuition.toTags(&settings, &more));
    try testing.expectEqual(sdk.intuition.IPREFS_WindowCorners, more[4].tag);
    try testing.expectEqual(@as(usize, 0), more[4].data);
    try testing.expectEqual(sdk.intuition.IPREFS_WindowShadow, more[5].tag);
    try testing.expectEqual(@as(usize, 20), more[5].data);
    try testing.expectEqual(sdk.intuition.IPREFS_WindowFade, more[6].tag);
    try testing.expectEqualStrings("DOUBLECLICK=400 SCREENFONT=16 KEYBOARD=ALWAYS OFFSCREEN=YES WIDEGADGETS=YES CORNERS=0 SHADOW=20 FADE=0", out[0..prefs.intuition.write(&settings, &out)]);
    try testing.expect(prefs.intuition.parse(ub, "CORNERS=17", &settings) != null);
    try testing.expect(prefs.intuition.parse(ub, "SHADOW=33", &settings) != null);
    try testing.expect(prefs.intuition.parse(ub, "FADE=1001", &settings) != null);
    try utilityDown(ub);
}

test "anvil.prefs: a line read, its picture quoted, written back" {
    const ub = try utilityUp();
    defer kexec.deinit();
    var settings: prefs.anvil.Settings = .{};
    try testing.expect(prefs.anvil.parse(ub, "ground=#3A5F8A..#14253A PICTURE=\"SYS:Prefs/Sea Side.png\" place=scaled ICONSIZE=64 VIEW=name snap=yes newwindow=YES", &settings) == null);
    try testing.expect(settings.ground_given);
    try testing.expect(settings.shaded());
    try testing.expectEqual(@as(u32, 0xFF3A_5F8A), settings.top);
    try testing.expectEqual(@as(u32, 0xFF14_253A), settings.bottom);
    try testing.expectEqualStrings("SYS:Prefs/Sea Side.png", settings.pictureName().?);
    try testing.expectEqual(prefs.anvil.Place.scaled, settings.place);
    try testing.expectEqual(@as(u32, 64), settings.icon_size);
    try testing.expectEqual(prefs.anvil.View.name, settings.view);
    try testing.expect(settings.snap);
    try testing.expect(settings.new_window);
    var out: [240]u8 = undefined;
    const written = out[0..prefs.anvil.write(&settings, &out)];
    try testing.expectEqualStrings("GROUND=#3A5F8A..#14253A PICTURE=\"SYS:Prefs/Sea Side.png\" PLACE=SCALED ICONSIZE=64 VIEW=NAME SNAP=YES NEWWINDOW=YES", written);
    var again: prefs.anvil.Settings = .{};
    try testing.expect(prefs.anvil.parse(ub, written, &again) == null);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&settings), std.mem.asBytes(&again));

    // One colour, no picture, and what is left out kept.
    var plain: prefs.anvil.Settings = .{};
    try testing.expect(prefs.anvil.parse(ub, "GROUND=#336699 PICTURE=NONE", &plain) == null);
    try testing.expect(!plain.shaded());
    try testing.expect(plain.pictureName() == null);
    try testing.expectEqualStrings("GROUND=#336699 PICTURE=NONE PLACE=TILED ICONSIZE=48 VIEW=ICON SNAP=NO NEWWINDOW=NO", out[0..prefs.anvil.write(&plain, &out)]);
    // Left out entirely, the ground is the screen's pen and is not written.
    try testing.expectEqualStrings("PICTURE=NONE PLACE=TILED ICONSIZE=48 VIEW=ICON SNAP=NO NEWWINDOW=NO", out[0..prefs.anvil.write(&prefs.anvil.Settings{}, &out)]);
    try testing.expectEqual(@as(?[2]u32, null), prefs.anvil.groundOf("#33669"));
    try testing.expectEqual(@as(?[2]u32, .{ 0xFF33_6699, 0xFF00_0000 }), prefs.anvil.groundOf("#336699..#000000"));

    // What is wrong is said.
    try testing.expect(prefs.anvil.parse(ub, "ICONSIZE=8", &plain) != null);
    try testing.expect(prefs.anvil.parse(ub, "ICONSIZE=300", &plain) != null);
    try testing.expect(prefs.anvil.parse(ub, "PLACE=STRETCHED", &plain) != null);
    try testing.expect(prefs.anvil.parse(ub, "VIEW=TYPE", &plain) != null);
    try testing.expect(prefs.anvil.parse(ub, "NEWWINDOW=MAYBE", &plain) != null);
    try testing.expect(prefs.anvil.parse(ub, "GROUND=blue", &plain) != null);
    try testing.expect(prefs.anvil.parse(ub, "PICTURE=\"open", &plain) != null);
    try testing.expect(prefs.anvil.parse(ub, "WALLPAPER=x", &plain) != null);
    try testing.expect(prefs.anvil.parse(ub, "SNAP=SOMETIMES", &plain) != null);
    try utilityDown(ub);
}

test "anvil.prefs: SNAP alone draws the desktop alike, anything else does not" {
    const ub = try utilityUp();
    defer kexec.deinit();
    var one: prefs.anvil.Settings = .{};
    try testing.expect(prefs.anvil.parse(ub, "GROUND=#336699 PICTURE=\"SYS:Prefs/Sea.png\"", &one) == null);
    var two = one;
    two.snap = true;
    try testing.expect(prefs.anvil.sameLook(&one, &two));
    two.view = .size;
    try testing.expect(!prefs.anvil.sameLook(&one, &two));
    two = one;
    try testing.expect(two.setPicture("SYS:Prefs/Sky.png"));
    try testing.expect(!prefs.anvil.sameLook(&one, &two));
    two = one;
    two.icon_size = 64;
    try testing.expect(!prefs.anvil.sameLook(&one, &two));
    try utilityDown(ub);
}

test "the settings files of a fresh disk: the explanation the SDK writes" {
    const ub = try utilityUp();
    defer kexec.deinit();
    try testing.expectEqualStrings(prefs.anvil.header, @embedFile("../env-archive/Sys/anvil.prefs"));
    try testing.expectEqualStrings(prefs.style.header, @embedFile("../env-archive/Sys/style.prefs"));
    try testing.expectEqualStrings(prefs.intuition.header, @embedFile("../env-archive/Sys/intuition.prefs"));
    try testing.expectEqualStrings(prefs.palette.header, @embedFile("../env-archive/Sys/palette.prefs"));
    try testing.expectEqualStrings(prefs.sound.header, @embedFile("../env-archive/Sys/sound.prefs"));
    try testing.expectEqualStrings(prefs.audio.header, @embedFile("../env-archive/Sys/audio.prefs"));
    try testing.expectEqualStrings(prefs.dock.header, @embedFile("../env-archive/Sys/dock.prefs"));
    const fonts = @embedFile("../env-archive/Sys/font.prefs");
    try testing.expect(std.mem.startsWith(u8, fonts, prefs.font.header));
    // Every commented line of the style's default reads as a line.
    var lines = prefs.Lines{ .text = prefs.style.header };
    var read: u32 = 0;
    while (lines.next()) |l| {
        if (!std.mem.startsWith(u8, l.text, "# PART=")) continue;
        var line: prefs.style.Line = undefined;
        try testing.expect(prefs.style.parse(ub, l.text[2..], &line) == null);
        read += 1;
    }
    try testing.expect(read > 20);
    try utilityDown(ub);
}

test "sound.prefs: a line read, its file quoted, written back; the tone rises, sounds and dies away" {
    const ub = try utilityUp();
    defer kexec.deinit();
    var settings: prefs.sound.Settings = .{};
    try testing.expect(prefs.sound.parse(ub, "FLASH=no SOUND=beep TONE=1000 DURATION=50", &settings) == null);
    try testing.expectEqual(@as(u32, 0), settings.flash);
    try testing.expectEqual(prefs.sound.SOUND_BEEP, settings.sound);
    // One left out has the system's value.
    try testing.expectEqual(@as(u32, 80), settings.volume);
    var out: [352]u8 = undefined;
    try testing.expectEqualStrings("FLASH=NO SOUND=BEEP VOLUME=80 TONE=1000 DURATION=50", out[0..prefs.sound.write(&settings, &out)]);

    // A file with a space in its name is quoted, and read back.
    try testing.expect(prefs.sound.parse(ub, "SOUND=SAMPLE SAMPLE=\"SYS:Sounds/a ding.wav\" VOLUME=40", &settings) == null);
    try testing.expectEqualStrings("SYS:Sounds/a ding.wav", std.mem.sliceTo(&settings.sample, 0));
    const line = out[0..prefs.sound.write(&settings, &out)];
    try testing.expectEqualStrings("FLASH=NO SOUND=SAMPLE VOLUME=40 TONE=1000 DURATION=50 SAMPLE=\"SYS:Sounds/a ding.wav\"", line);
    var again: prefs.sound.Settings = .{};
    try testing.expect(prefs.sound.parse(ub, line, &again) == null);
    try testing.expectEqualStrings(std.mem.sliceTo(&settings.sample, 0), std.mem.sliceTo(&again.sample, 0));
    // As loud as 40% is everywhere: the cube, 0.064 of as recorded.
    try testing.expectEqual(sdk.devices.audiocontrol.volumeOf(40), prefs.sound.volumeOf(&again));
    try testing.expectEqual(@as(u32, 4194), prefs.sound.volumeOf(&again));

    // What it does not take.
    var bad: prefs.sound.Settings = .{};
    try testing.expect(prefs.sound.parse(ub, "SOUND=SAMPLE", &bad) != null);
    try testing.expect(prefs.sound.parse(ub, "TONE=20", &bad) != null);
    try testing.expect(prefs.sound.parse(ub, "VOLUME=0", &bad) != null);
    try testing.expect(prefs.sound.parse(ub, "SAMPLE=\"open", &bad) != null);
    try testing.expect(prefs.sound.parse(ub, "SOUND=LOUD", &bad) != null);

    // The tone: 50 ms at 48 kHz, silent at its start, as loud as it gets
    // within its first part, and nearly silent again at its end.
    var tone: prefs.sound.Settings = .{ .sound = prefs.sound.SOUND_BEEP, .tone = 1000, .duration = 50 };
    var samples: [prefs.sound.beep_rate / 20]i16 = undefined;
    const beep = prefs.sound.makeBeep(&tone, &samples);
    try testing.expectEqual(@as(u32, samples.len), beep.frames);
    try testing.expectEqual(prefs.sound.beep_rate, beep.rate);
    try testing.expectEqual(@as(u32, 1), beep.channels);
    try testing.expectEqual(@as(i16, 0), samples[0]);
    var loudest: i32 = 0;
    for (samples[0..480]) |sample| loudest = @max(loudest, @as(i32, sample));
    try testing.expect(loudest > 25_000 and loudest <= 30_000);
    for (samples[samples.len - 24 ..]) |sample| try testing.expect(sample < 400 and sample > -400);
    tone.duration = 10;
    try testing.expectEqual(@as(u32, 480), prefs.sound.beepFrames(&tone));
    try utilityDown(ub);
}

test "the equalizer's presets: each found by its bands and by its name, any case; others Custom" {
    const audiocontrol = sdk.devices.audiocontrol;
    for (&audiocontrol.presets, 0..) |*preset, at| {
        try testing.expectEqual(at, audiocontrol.presetOf(&preset.bands));
        try testing.expectEqual(preset, audiocontrol.presetNamed(std.mem.span(preset.name)).?);
        try testing.expectEqualStrings(std.mem.span(preset.name), std.mem.span(audiocontrol.preset_labels[at].?));
    }
    try testing.expectEqualStrings("Custom", std.mem.span(audiocontrol.preset_labels[audiocontrol.preset_custom].?));
    try testing.expectEqual(null, audiocontrol.preset_labels[audiocontrol.preset_custom + 1]);
    const flat: audiocontrol.Bands = @splat(0);
    try testing.expectEqual(0, audiocontrol.presetOf(&flat));
    var bent = audiocontrol.presets[6].bands;
    bent[4] += 1;
    try testing.expectEqual(audiocontrol.preset_custom, audiocontrol.presetOf(&bent));
    try testing.expectEqualStrings("Techno", std.mem.span(audiocontrol.presetNamed("tECHNO").?.name));
    try testing.expectEqualStrings("More bass", std.mem.span(audiocontrol.presetNamed("more BASS").?.name));
    try testing.expectEqual(null, audiocontrol.presetNamed("Tech"));
    try testing.expectEqual(null, audiocontrol.presetNamed("Technos"));
    try testing.expectEqual(null, audiocontrol.presetNamed(""));
}

test "audio.prefs: lines read, the preferred one alone, written back; volumes in percent; equalizers" {
    const ub = try utilityUp();
    defer kexec.deinit();
    var settings: prefs.audio.Settings = .{};
    const text =
        \\# a comment
        \\OUTPUT=24b61a00 VOLUME=80 NAME=es8311 PREFERRED=yes
        \\output=ECD5FB99 NAME="QEMU USB Audio" PREFERRED=YES
        \\OUTPUT=0 VOLUME=50
        \\OUTPUT=12 VOLUME=101
        \\VOLUME=20
        \\OUTPUT=24B61A00 VOLUME=70 EQ=4,+3,0,0,0,0,0,-2,12,-12 NAME=es8311
    ;
    try testing.expectEqual(@as(u32, 3), settings.load(ub, text));
    try testing.expectEqual(@as(usize, 2), settings.count);
    // The second line of a number takes the first's place; the last line
    // naming one preferred is the one.
    try testing.expectEqual(@as(u32, 0x24B6_1A00), settings.outputs[0].id);
    try testing.expectEqual(@as(u32, 70), settings.outputs[0].volume);
    try testing.expectEqual([_]i8{ 4, 3, 0, 0, 0, 0, 0, -2, 12, -12 }, settings.outputs[0].bands);
    try testing.expect(!settings.outputs[0].preferred);
    try testing.expect(settings.outputs[1].flat());
    try testing.expectEqualStrings("QEMU USB Audio", settings.outputs[1].nameText());
    try testing.expectEqual(@as(u32, 100), settings.outputs[1].volume);
    try testing.expectEqual(@as(u32, 0xECD5_FB99), settings.preferred().?.id);

    var output: prefs.audio.Output = .{};
    try testing.expectEqualStrings("VOLUME is 0 to 100 percent", std.mem.span(prefs.audio.parseLine(ub, "OUTPUT=1 VOLUME=x", &output).?));
    try testing.expectEqualStrings("a line names its OUTPUT", std.mem.span(prefs.audio.parseLine(ub, "VOLUME=1", &output).?));
    const eq_wrong = "EQ is ten numbers of dB, -12 to 12, split by commas";
    for ([_][]const u8{
        "OUTPUT=1 EQ=0,0,0,0,0,0,0,0,0",
        "OUTPUT=1 EQ=0,0,0,0,0,0,0,0,0,0,0",
        "OUTPUT=1 EQ=0,0,0,0,13,0,0,0,0,0",
        "OUTPUT=1 EQ=0,0,0,0,-13,0,0,0,0,0",
        "OUTPUT=1 EQ=0,0,,0,0,0,0,0,0,0",
        "OUTPUT=1 EQ=0,0,a,0,0,0,0,0,0,0",
        "OUTPUT=1 EQ=",
    }) |line| try testing.expectEqualStrings(eq_wrong, std.mem.span(prefs.audio.parseLine(ub, line, &output).?));

    var out: [prefs.audio.max_file]u8 = undefined;
    const n = prefs.audio.write(&settings, &out);
    try testing.expect(std.mem.startsWith(u8, out[0..n], prefs.audio.header));
    try testing.expectEqualStrings(
        \\OUTPUT=24B61A00 VOLUME=70 EQ=4,3,0,0,0,0,0,-2,12,-12 NAME=es8311
        \\OUTPUT=ECD5FB99 VOLUME=100 NAME="QEMU USB Audio" PREFERRED=YES
        \\
    , out[prefs.audio.header.len..n]);
    var again: prefs.audio.Settings = .{};
    try testing.expectEqual(@as(u32, 0), again.load(ub, out[0..n]));
    try testing.expectEqual(@as(u32, 0xECD5_FB99), again.preferred().?.id);
    try testing.expectEqual(settings.outputs[0].bands, again.outputs[0].bands);
    // The longest line there can be fits.
    var longest: prefs.audio.Output = .{ .id = 0xFFFF_FFFF, .volume = 100, .preferred = true, .bands = @splat(-12) };
    longest.setName("A name thirty-one letters long..");
    var line: [prefs.audio.max_line]u8 = undefined;
    try testing.expect(prefs.audio.writeLine(&longest, &line) < prefs.audio.max_line);

    // Preferring one the file does not name puts it at the end; none
    // prefers none.
    settings.prefer(0x1234);
    try testing.expectEqual(@as(usize, 3), settings.count);
    try testing.expectEqual(@as(u32, 0x1234), settings.preferred().?.id);
    settings.prefer(0);
    try testing.expect(settings.preferred() == null);

    const ac = sdk.devices.audiocontrol;
    try testing.expectEqual(sdk.devices.audio.AUDIO_VOLUME_UNITY, ac.volumeOf(100));
    try testing.expectEqual(@as(u32, 0), ac.volumeOf(0));
    for (0..101) |percent| try testing.expectEqual(@as(u32, @intCast(percent)), ac.percentOf(ac.volumeOf(@intCast(percent))));
    try testing.expectEqual(@as(u32, 100), ac.percentOf(sdk.devices.audio.AUDIO_VOLUME_MAX));
    // A percent is as loud as it sounds: half way an eighth of the wave,
    // -18 dB, and a tenth a thousandth, -60 dB.
    try testing.expectEqual(sdk.devices.audio.AUDIO_VOLUME_UNITY / 8, ac.volumeOf(50));
    try testing.expectEqual(@as(u32, 66), ac.volumeOf(10));
    // Past 100 in proportion, as a boost: 200 twice as recorded, and no
    // more than the device takes.
    try testing.expectEqual(2 * sdk.devices.audio.AUDIO_VOLUME_UNITY, ac.volumeOf(200));
    try testing.expectEqual(sdk.devices.audio.AUDIO_VOLUME_MAX, ac.volumeOf(1000));
    // Every percent louder than the one before, so none is lost.
    for (1..401) |percent| try testing.expect(ac.volumeOf(@intCast(percent)) > ac.volumeOf(@intCast(percent - 1)));
    // A volume between two steps is the nearer one's.
    try testing.expectEqual(@as(u32, 50), ac.percentOf(sdk.devices.audio.AUDIO_VOLUME_UNITY / 8 + 100));
    try utilityDown(ub);
}

test "the styles the editor offers: every line read" {
    const ub = try utilityUp();
    defer kexec.deinit();
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
            try testing.expect(prefs.style.parse(ub, l.text, &line) == null);
        }
    }
    try utilityDown(ub);
}

test "palette.prefs: the pens read and written back" {
    const ub = try utilityUp();
    defer kexec.deinit();
    const sc = sdk.intuition.screens;
    var palette: prefs.palette.Palette = .{};
    try testing.expect(prefs.palette.parse(ub, "BACKGROUND=#336699 text=#FFFFFF", &palette) == null);
    try testing.expectEqual(@as(u32, 0xFF33_6699), palette.pens[sc.BACKGROUNDPEN]);
    try testing.expect(palette.given & (@as(u32, 1) << sc.TEXTPEN) != 0);
    try testing.expect(palette.given & (@as(u32, 1) << sc.FILLPEN) == 0);
    var out: [256]u8 = undefined;
    const line = out[0..prefs.palette.write(&palette.pens, &out)];
    var again: prefs.palette.Palette = .{};
    try testing.expect(prefs.palette.parse(ub, line, &again) == null);
    try testing.expectEqual(palette.pens[sc.BACKGROUNDPEN] & 0xFFFFFF, again.pens[sc.BACKGROUNDPEN] & 0xFFFFFF);
    try testing.expectEqual(@as(u32, 0xFFF), again.given);
    // The dim text: mixed while the line leaves it out, whatever it was;
    // given, written back.
    again.pens[sc.DIMTEXTPEN] = 0xFF12_3456;
    try testing.expect(prefs.palette.parse(ub, "TEXT=#000000", &again) == null);
    try testing.expectEqual(@as(sdk.graphics.Pen, 0), again.pens[sc.DIMTEXTPEN]);
    try testing.expect(prefs.palette.parse(ub, "DIMTEXT=#123456", &again) == null);
    try testing.expectEqual(@as(sdk.graphics.Pen, 0xFF12_3456), again.pens[sc.DIMTEXTPEN]);
    const dim_line = out[0..prefs.palette.write(&again.pens, &out)];
    try testing.expect(std.mem.indexOf(u8, dim_line, "DIMTEXT=#123456") != null);
    try testing.expect(prefs.palette.parse(ub, "BACKGROUND=blue", &again) != null);
    // The built-in pens the header writes out read as a line.
    var lines = prefs.Lines{ .text = prefs.palette.header };
    var found = false;
    while (lines.next()) |l| {
        if (!std.mem.startsWith(u8, l.text, "# DETAIL=")) continue;
        try testing.expect(prefs.palette.parse(ub, l.text[2..], &again) == null);
        found = true;
    }
    try testing.expect(found);
    // The built-in pens, read as the compiler builds, are what the line
    // reads as through NextSetting.
    var built: prefs.palette.Palette = .{};
    try testing.expect(prefs.palette.parse(ub, prefs.palette.default_line, &built) == null);
    try testing.expectEqual(prefs.palette.defaults, built.pens);
    try utilityDown(ub);
}

test "dock.prefs: a line read and written back; what it does not take is told" {
    const ub = try utilityUp();
    defer kexec.deinit();
    var settings: prefs.dock.Settings = .{};
    try testing.expect(prefs.dock.parse(ub, "edge=left ICONSIZE=32 LABELS=always HIDE=auto KEEPCLEAR=no MAGNIFY=64", &settings) == null);
    try testing.expectEqual(prefs.dock.Edge.left, settings.edge);
    try testing.expect(settings.upright());
    try testing.expectEqual(@as(u32, 32), settings.icon_size);
    try testing.expectEqual(prefs.dock.Labels.always, settings.labels);
    try testing.expect(settings.hide);
    try testing.expect(!settings.keep_clear);
    try testing.expectEqual(@as(u32, 64), settings.magnify);

    var text: [96]u8 = undefined;
    const written = text[0..prefs.dock.write(&settings, &text)];
    try testing.expectEqualStrings("EDGE=LEFT ICONSIZE=32 LABELS=ALWAYS HIDE=AUTO KEEPCLEAR=NO MAGNIFY=64", written);
    var again: prefs.dock.Settings = .{};
    try testing.expect(prefs.dock.parse(ub, written, &again) == null);
    try testing.expectEqual(settings, again);

    // The dock's own, written as the explanation says.
    const own: prefs.dock.Settings = .{};
    const plain = text[0..prefs.dock.write(&own, &text)];
    try testing.expect(std.mem.indexOf(u8, prefs.dock.header, plain) != null);

    // One left out keeps its value; MAGNIFY is checked against the
    // ICONSIZE the whole line leaves.
    var kept: prefs.dock.Settings = .{ .magnify = 96 };
    try testing.expect(prefs.dock.parse(ub, "MAGNIFY=40 ICONSIZE=24", &kept) == null);
    try testing.expectEqual(prefs.dock.Edge.bottom, kept.edge);
    try testing.expect(prefs.dock.parse(ub, "ICONSIZE=32", &kept) == null);
    try testing.expect(prefs.dock.parse(ub, "ICONSIZE=40", &kept) != null);

    var bad: prefs.dock.Settings = .{};
    try testing.expect(prefs.dock.parse(ub, "EDGE=MIDDLE", &bad) != null);
    try testing.expect(prefs.dock.parse(ub, "ICONSIZE=8", &bad) != null);
    try testing.expect(prefs.dock.parse(ub, "ICONSIZE=129", &bad) != null);
    try testing.expect(prefs.dock.parse(ub, "LABELS=SOMETIMES", &bad) != null);
    try testing.expect(prefs.dock.parse(ub, "HIDE=YES", &bad) != null);
    try testing.expect(prefs.dock.parse(ub, "KEEPCLEAR=MAYBE", &bad) != null);
    try testing.expect(prefs.dock.parse(ub, "MAGNIFY=200", &bad) != null);
    try testing.expect(prefs.dock.parse(ub, "WIDTH=3", &bad) != null);
    try testing.expectEqualStrings(prefs.Pairs.quote_not_closed, std.mem.span(prefs.dock.parse(ub, "EDGE=\"LEFT", &bad).?));
    try utilityDown(ub);
}

test "dock.items: the entries and docklets read a line at a time, written back; a line that is not one is passed over" {
    const ub = try utilityUp();
    defer kexec.deinit();
    // A fresh disk's file: the explanation, and the dock's own entries as
    // itemLine writes them.
    const fresh = @embedFile("../env-archive/Sys/dock.items");
    try testing.expect(std.mem.startsWith(u8, fresh, prefs.dock.items_header));
    var written: [512]u8 = undefined;
    var n: usize = 0;
    for (prefs.dock.default_items) |item| {
        try testing.expect(prefs.dock.itemLength(item) <= written.len - n);
        n += prefs.dock.itemLine(item, written[n..]).?;
    }
    try testing.expectEqualStrings(written[0..n], std.mem.trimStart(u8, fresh[prefs.dock.items_header.len..], "\n"));
    var items = prefs.dock.Items.init(ub, fresh);
    for (prefs.dock.default_items) |want| {
        const got = items.next().?;
        switch (want) {
            .path => |path| try testing.expectEqualStrings(path, got.path),
            .separator => try testing.expect(got == .separator),
            .docklet => |name| try testing.expectEqualStrings(name, got.docklet),
        }
    }
    try testing.expect(items.next() == null);
    try testing.expectEqual(@as(u32, 0), items.bad_line);

    // Any case, KEY value, a name with blanks in quotes; lines that are
    // not entries passed over, the last of them told.
    const text =
        \\item "Work:My Tools/Edit"
        \\# a comment
        \\SEPARATOR=1
        \\separator
        \\ITEM=
        \\ITEM=Work: SEPARATOR
        \\ITEM="RAM:
        \\ITEM=Work:
        \\docklet clock.docklet
        \\DOCKLET="SYS:classes/docklets/cpu.docklet"
    ;
    var mixed = prefs.dock.Items.init(ub, text);
    try testing.expectEqualStrings("Work:My Tools/Edit", mixed.next().?.path);
    try testing.expect(mixed.next().? == .separator);
    try testing.expectEqualStrings("Work:", mixed.next().?.path);
    // A docklet by its name alone, not by a path.
    try testing.expectEqualStrings("clock.docklet", mixed.next().?.docklet);
    try testing.expect(mixed.next() == null);
    try testing.expectEqual(@as(u32, 10), mixed.bad_line);
    try testing.expectEqualStrings("DOCKLET is a docklet's name, \"clock.docklet\"", std.mem.span(mixed.problem.?));

    // A docklet's line, read back as it was.
    const line_length = prefs.dock.itemLine(.{ .docklet = "battery.docklet" }, &written).?;
    try testing.expectEqualStrings("DOCKLET=\"battery.docklet\"\n", written[0..line_length]);
    try testing.expectEqual(prefs.dock.itemLength(.{ .docklet = "battery.docklet" }), line_length);
    var again = prefs.dock.Items.init(ub, written[0..line_length]);
    try testing.expectEqualStrings("battery.docklet", again.next().?.docklet);

    // A name with a double quote in it has no line.
    try testing.expect(prefs.dock.itemLine(.{ .path = "Work:a\"b" }, &written) == null);
    try utilityDown(ub);
}

test "every form reads its line alike: KEY value, and a value in quotes" {
    const ub = try utilityUp();
    defer kexec.deinit();
    // Quotes, which these forms did not take before they read through
    // NextSetting.
    var fonts: prefs.font.Line = .{};
    try testing.expect(prefs.font.parse(ub, "ICON=\"go.font/12\" DEFAULT go.font/9", &fonts) == null);
    try testing.expectEqualStrings("go.font/12", fonts.get(.icon).?);
    try testing.expectEqualStrings("go.font/9", fonts.get(.default).?);
    var settings: prefs.intuition.Settings = .{};
    try testing.expect(prefs.intuition.parse(ub, "DOUBLECLICK \"400\"", &settings) == null);
    try testing.expectEqual(@as(u32, 400), settings.double_click);
    var palette: prefs.palette.Palette = .{};
    try testing.expect(prefs.palette.parse(ub, "BACKGROUND=\"#336699\"", &palette) == null);
    var line: prefs.style.Line = undefined;
    try testing.expect(prefs.style.parse(ub, "PART=\"MAIN\" BORDER FLAT", &line) == null);
    // KEY value, which audio.prefs did not take before.
    var output: prefs.audio.Output = .{};
    try testing.expect(prefs.audio.parseLine(ub, "OUTPUT 1 NAME \"Line out\"", &output) == null);
    try testing.expectEqual(@as(u32, 1), output.id);
    try testing.expectEqualStrings("Line out", output.nameText());
    // A quote not closed is said alike by all of them.
    try testing.expectEqualStrings(prefs.Pairs.quote_not_closed, std.mem.span(prefs.intuition.parse(ub, "FADE=\"10", &settings).?));
    try testing.expectEqualStrings(prefs.Pairs.quote_not_closed, std.mem.span(prefs.audio.parseLine(ub, "OUTPUT=\"1", &output).?));
    try utilityDown(ub);
}
