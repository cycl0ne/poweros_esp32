// SPDX-License-Identifier: MIT
//! SetPrefs: the system's settings, from the files in ENV:Sys. Built
//! against the SDK only.
//!
//!   SetPrefs FROM/K,RESET/S,SHOW/S
//!
//! Reads the six settings files from FROM, a directory - ENV:Sys unless
//! named; ENVARC:Sys for the ones kept over a restart - and hands five of
//! them to intuition.library in one `SetPrefs`, and the sixth to
//! audio.device:
//!
//! - intuition.prefs: the double-click time, the height of a screen's
//!   font when it is given none, when the keyboard on the screen comes up,
//!   whether a window may be moved partly past the screen's edges, and
//!   whether the gadgets in the title bars are wide.
//! - font.prefs: the fonts of screens' bars and menus, of windows and
//!   gadgets, and of consoles - each opened with diskfont.library, so any
//!   size of any family in FONTS: will do; one left out is pospaz from the
//!   ROM, and a console font that is not fixed-width is refused.
//! - palette.prefs: the system's twelve pens; one left out keeps its
//!   colour.
//! - style.prefs: the system's style, a line per part in a state; a line
//!   that cannot be read is reported with its number and passed over.
//! - sound.prefs: what a beep does - whether the display flashes, and the
//!   sound: none, a tone made from the line, or a sound file decoded
//!   whole through datatypes.library (four seconds of it at most). A file
//!   that cannot be read is reported, and the tone is played instead.
//! - audio.prefs: each output's volume, those not plugged in too, and the
//!   output preferred - played through whenever it is there. A line that
//!   cannot be read is reported with its number and passed over; a
//!   machine without audio.device takes none of it.
//!
//! A file that is not there changes nothing of its own. Every screen and
//! window takes the pens, the style and the title bars' gadgets at once,
//! those open too; the
//! fonts and the font height reach what opens from then on. The files'
//! forms are `sdk.prefs`'s, which SYS:Programs/Prefs writes too, and
//! S:Startup-Sequence runs this once at boot.
//!
//! RESET puts every setting back to what the system starts with, and the
//! style to the default - no output preferred, every output listed at
//! full volume; the files are not read. SHOW prints the settings in force
//! - after setting them when FROM or RESET is given, and on its own
//! changes nothing:
//!
//!   DOUBLECLICK  1500 ms
//!   SCREENFONT   16 rows
//!   KEYBOARD     AUTO
//!   OFFSCREEN    NO
//!   WIDEGADGETS  NO
//!   SCREEN       go.font 24 rows
//!   DEFAULT      go.font 21 rows
//!   FIXED        pospaz.font 16 rows (ROM)
//!   PENS         DETAIL=#AAAAAA BLOCK=#000000 ...
//!   BEEPFLASH    YES
//!   OUTPUT       es8311 80%
//!   OUTPUT       QEMU USB Audio 40%
//!   PREFERRED    QEMU USB Audio
//!
//! An OUTPUT line for each output there is, with its volume; PREFERRED
//! names the one preferred, by its number when it is not there.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const diskfont = sdk.diskfont;
const prefs = sdk.prefs;
const style_file = prefs.style;
const font_file = prefs.font;
const intuition_file = prefs.intuition;
const palette_file = prefs.palette;
const sound_file = prefs.sound;
const audio_file = prefs.audio;
const audiocontrol = sdk.devices.audiocontrol;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const sdt = datatypes.soundclass;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const sc = intuition.screens;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const TagItem = utility.TagItem;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "SetPrefs";
const VERSION_STRING = "\x00$VER: SetPrefs 1.3 (20.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FROM/K,RESET/S,SHOW/S";
const arg_from = 0;
const arg_reset = 1;
const arg_show = 2;

const default_dir = "ENV:Sys";
/// The most of the style file read.
const max_style = 16384;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOMEMORY = "No memory for the settings\n";
const MSG_BAD = "%s: %s\n";
const MSG_BADLINE = "%s, line %ld: %s\n";
const MSG_LONG = "%s is longer than %ld bytes: the rest is not read\n";
const MSG_BADSIZE = "%s: a font is written family/size, as spleen.font/16 or spleen.font/10P\n";
const MSG_NOFONT = "%s: not in FONTS:, at no size that will do\n";
const MSG_NOTFIXED = "%s is proportional: consoles keep pospaz\n";
const MSG_NOTTAKEN = "Not every setting was taken\n";
const MSG_NUMBER = "%-12s %ld %s\n";
const MSG_WORD = "%-12s %s\n";
const MSG_FONT = "%-12s %s %ld rows%s\n";
const MSG_NOSAMPLE = "%s: cannot be read as a sound - the tone plays instead\n";
const MSG_OUTPUT = "%-12s %s %u%%\n";
const MSG_PREFERRED = "%-12s %s\n";
const MSG_PREFERRED_GONE = "%-12s %s, not there\n";

/// The most of a beep's sound file read, in seconds.
const max_sample_seconds = 4;

/// The font lines' three, in their order in the file, and the tag each is.
const font_tags = [3]utility.Tag{ intuition.IPREFS_ScreenFont, intuition.IPREFS_DefaultFont, intuition.IPREFS_FixedFont };
const fixed_at = 2;

/// Everything the tags point into, kept until `SetPrefs` has read it.
const Gathered = struct {
    tags: [16]TagItem = undefined,
    count: usize = 0,
    fonts: [3]?*graphics.TextFont = @splat(null),
    pens: [sc.NUMDRIPENS]graphics.Pen = undefined,
    /// The style's tags and fills, allocated.
    style_memory: ?*anyopaque = null,
    /// The beep's sound and its samples, allocated.
    beep: intuition.BeepSound = undefined,
    beep_memory: ?*anyopaque = null,

    fn add(g: *Gathered, tag: utility.Tag, data: usize) void {
        g.tags[g.count] = .{ .tag = tag, .data = data };
        g.count += 1;
    }
};

/// `dir` and `name` joined into `into`, `/` between them unless `dir`
/// ends in a device or a directory.
fn pathOf(into: *[128:0]u8, dir: [*:0]const u8, name: []const u8) [*:0]const u8 {
    var n: usize = 0;
    while (dir[n] != 0 and n < 100) : (n += 1) into[n] = dir[n];
    if (n > 0 and into[n - 1] != ':' and into[n - 1] != '/') {
        into[n] = '/';
        n += 1;
    }
    @memcpy(into[n..][0..name.len], name);
    into[n + name.len] = 0;
    return into;
}

const Libs = struct {
    sys: *ExecBase,
    dl: *DosBase,
    gb: *GraphicsBase,
    ib: *IntuitionBase,
};

/// intuition.prefs: its line's settings.
fn readSettings(l: Libs, dir: [*:0]const u8, g: *Gathered) i32 {
    var path: [128:0]u8 = undefined;
    const from = pathOf(&path, dir, "intuition.prefs");
    var text: [1024]u8 = undefined;
    const read = prefs.load(l.dl, from, &text) orelse return dos.RETURN_OK;
    const words = prefs.firstLine(read) orelse return dos.RETURN_OK;
    var settings: intuition_file.Settings = .{};
    if (intuition_file.parse(words, &settings)) |wrong| {
        _ = Printf(l.dl, MSG_BAD, .{ from, wrong });
        return dos.RETURN_WARN;
    }
    g.count += intuition_file.toTags(&settings, g.tags[g.count..]);
    return dos.RETURN_OK;
}

/// palette.prefs: the pens, those it leaves out as they are now.
fn readPens(l: Libs, dir: [*:0]const u8, g: *Gathered) i32 {
    var path: [128:0]u8 = undefined;
    const from = pathOf(&path, dir, "palette.prefs");
    var text: [1024]u8 = undefined;
    const read = prefs.load(l.dl, from, &text) orelse return dos.RETURN_OK;
    const words = prefs.firstLine(read) orelse return dos.RETURN_OK;
    var palette: palette_file.Palette = .{};
    _ = l.ib.GetPrefs(&[_]TagItem{ .{ .tag = intuition.IPREFS_Pens, .data = @intFromPtr(&palette.pens) }, .{} });
    if (palette_file.parse(words, &palette)) |wrong| {
        _ = Printf(l.dl, MSG_BAD, .{ from, wrong });
        return dos.RETURN_WARN;
    }
    g.pens = palette.pens;
    g.add(intuition.IPREFS_Pens, @intFromPtr(&g.pens));
    return dos.RETURN_OK;
}

/// font.prefs: the three fonts opened; one left out, or one that cannot
/// be had, is pospaz.
fn readFonts(l: Libs, dir: [*:0]const u8, g: *Gathered) i32 {
    var path: [128:0]u8 = undefined;
    const from = pathOf(&path, dir, "font.prefs");
    var text: [1024]u8 = undefined;
    const read = prefs.load(l.dl, from, &text) orelse return dos.RETURN_OK;
    const words = prefs.firstLine(read) orelse return dos.RETURN_OK;
    var line: font_file.Line = .{};
    if (font_file.parse(words, &line)) |wrong| {
        _ = Printf(l.dl, MSG_BAD, .{ from, wrong });
        return dos.RETURN_WARN;
    }
    const df_lib = l.sys.OpenLibrary(diskfont.DISKFONTNAME, diskfont.DISKFONT_VERSION) orelse {
        _ = Printf(l.dl, MSG_NOLIBRARY, .{diskfont.DISKFONTNAME});
        return dos.RETURN_WARN;
    };
    defer l.sys.CloseLibrary(df_lib);
    const dfb: *DiskfontBase = @ptrCast(df_lib);
    var result: i32 = dos.RETURN_OK;
    var family: [3][font_file.value_len:0]u8 = undefined;
    for (0..3) |i| {
        const given = line.get(@enumFromInt(i)) orelse continue;
        const want = font_file.attrOf(given, &family[i]) orelse {
            _ = Printf(l.dl, MSG_BADSIZE, .{@as([*:0]const u8, @ptrCast(&line.values[i]))});
            result = dos.RETURN_WARN;
            continue;
        };
        g.fonts[i] = dfb.OpenDiskFont(&want);
        if (g.fonts[i] == null) {
            _ = Printf(l.dl, MSG_NOFONT, .{@as([*:0]const u8, @ptrCast(&line.values[i]))});
            result = dos.RETURN_WARN;
        }
    }
    // The console font is refused when it is not fixed-width; the other
    // two are set all the same.
    if (g.fonts[fixed_at]) |f| {
        if (f.image.flags & graphics.FPF_PROPORTIONAL != 0) {
            _ = Printf(l.dl, MSG_NOTFIXED, .{@as([*:0]const u8, @ptrCast(&line.values[fixed_at]))});
            l.gb.CloseFont(f);
            g.fonts[fixed_at] = null;
            result = dos.RETURN_WARN;
        }
    }
    for (font_tags, g.fonts) |tag, font| g.add(tag, @intFromPtr(font));
    return result;
}

/// style.prefs: every line that can be read, as one style.
fn readStyle(l: Libs, dir: [*:0]const u8, g: *Gathered) i32 {
    var path: [128:0]u8 = undefined;
    const from = pathOf(&path, dir, "style.prefs");
    const sys = l.sys;
    const text_mem = sys.AllocVec(max_style, exec.MEMF_ANY) orelse {
        _ = Printf(l.dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(text_mem);
    const buffer: [*]u8 = @ptrCast(text_mem);
    const text = prefs.load(l.dl, from, buffer[0..max_style]) orelse return dos.RETURN_OK;
    var result: i32 = dos.RETURN_OK;
    if (text.len == max_style) {
        _ = Printf(l.dl, MSG_LONG, .{ from, @as(u64, max_style) });
        result = dos.RETURN_WARN;
    }

    // Room for every line that has words in it; a file with none is the
    // default.
    var lines: usize = 0;
    var counting = prefs.Lines{ .text = text };
    while (counting.next()) |line| {
        if (style_file.hasWords(line.text)) lines += 1;
    }
    if (lines == 0) {
        g.add(intuition.IPREFS_Style, 0);
        return result;
    }
    const tag_bytes = (lines * style_file.tags_per_line + 1) * @sizeOf(TagItem);
    const room = sys.AllocVec(@intCast(tag_bytes + lines * @sizeOf(graphics.FillStyle)), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = Printf(l.dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    g.style_memory = room;
    const tags: [*]TagItem = @ptrCast(@alignCast(room));
    const fills: [*]graphics.FillStyle = @ptrCast(@alignCast(@as([*]u8, @ptrCast(room)) + tag_bytes));

    var count: usize = 0;
    var fill_count: usize = 0;
    var reading = prefs.Lines{ .text = text };
    while (reading.next()) |line| {
        if (!style_file.hasWords(line.text)) continue;
        const number: u64 = line.number;
        if (line.text.len > style_file.max_line) {
            _ = Printf(l.dl, MSG_BADLINE, .{ from, number, @as([*:0]const u8, "longer than 256 characters") });
            result = dos.RETURN_WARN;
            continue;
        }
        var parsed: style_file.Line = undefined;
        if (style_file.parse(line.text, &parsed)) |wrong| {
            _ = Printf(l.dl, MSG_BADLINE, .{ from, number, wrong });
            result = dos.RETURN_WARN;
            continue;
        }
        count += style_file.toTags(&parsed, tags[count .. count + style_file.tags_per_line], &fills[fill_count]);
        if (style_file.shaded(&parsed)) fill_count += 1;
    }
    tags[count] = .{};
    g.add(intuition.IPREFS_Style, @intFromPtr(tags));
    return result;
}

/// sound.prefs: whether a beep flashes, and its sound.
fn readSound(l: Libs, dir: [*:0]const u8, g: *Gathered) i32 {
    var path: [128:0]u8 = undefined;
    const from = pathOf(&path, dir, "sound.prefs");
    var text: [1024]u8 = undefined;
    const read = prefs.load(l.dl, from, &text) orelse return dos.RETURN_OK;
    const words = prefs.firstLine(read) orelse return dos.RETURN_OK;
    var settings: sound_file.Settings = .{};
    if (sound_file.parse(words, &settings)) |wrong| {
        _ = Printf(l.dl, MSG_BAD, .{ from, wrong });
        return dos.RETURN_WARN;
    }
    g.add(intuition.IPREFS_BeepFlash, settings.flash);
    var result: i32 = dos.RETURN_OK;
    if (settings.sound == sound_file.SOUND_SAMPLE) {
        if (readSample(l, &settings, g)) {
            g.add(intuition.IPREFS_BeepSound, @intFromPtr(&g.beep));
            return result;
        }
        _ = Printf(l.dl, MSG_NOSAMPLE, .{@as([*:0]const u8, &settings.sample)});
        result = dos.RETURN_WARN;
    }
    if (settings.sound == sound_file.SOUND_NONE) {
        g.add(intuition.IPREFS_BeepSound, 0);
        return result;
    }
    const frames = sound_file.beepFrames(&settings);
    const memory = l.sys.AllocVec(frames * @sizeOf(i16), exec.MEMF_ANY) orelse {
        _ = Printf(l.dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    g.beep_memory = memory;
    const samples: [*]i16 = @ptrCast(@alignCast(memory));
    g.beep = sound_file.makeBeep(&settings, samples[0..frames]);
    g.add(intuition.IPREFS_BeepSound, @intFromPtr(&g.beep));
    return result;
}

/// audio.prefs: every line that can be read, handed to audio.device - the
/// volumes, then the preferred output.
fn readAudio(l: Libs, dir: [*:0]const u8, _: *Gathered) i32 {
    var path: [128:0]u8 = undefined;
    const from = pathOf(&path, dir, "audio.prefs");
    var text: [audio_file.max_file]u8 = undefined;
    const read = prefs.load(l.dl, from, &text) orelse return dos.RETURN_OK;
    var settings: audio_file.Settings = .{};
    var result: i32 = dos.RETURN_OK;
    var lines = prefs.Lines{ .text = read };
    while (lines.next()) |line| {
        if (!style_file.hasWords(line.text)) continue;
        var output: audio_file.Output = .{};
        if (audio_file.parseLine(line.text, &output)) |wrong| {
            _ = Printf(l.dl, MSG_BADLINE, .{ from, @as(u64, line.number), wrong });
            result = dos.RETURN_WARN;
            continue;
        }
        settings.put(&output);
    }
    var control = audiocontrol.Control.open(l.sys) orelse return result;
    defer control.close();
    audio_file.apply(&control, &settings);
    return result;
}

/// What the system starts with, for audio.device: no output preferred,
/// and every output listed at full volume.
fn resetAudio(l: Libs) void {
    var control = audiocontrol.Control.open(l.sys) orelse return;
    defer control.close();
    _ = control.prefer(0);
    var outputs: audiocontrol.Outputs = .{};
    outputs.read(&control);
    for (outputs.infos[0..outputs.count]) |*info| control.setVolume(info.id, 100);
}

/// Every output there is and its volume, and the one preferred: by its
/// name when it is there, by its number when it is not.
fn showAudio(l: Libs) void {
    var control = audiocontrol.Control.open(l.sys) orelse return;
    defer control.close();
    var outputs: audiocontrol.Outputs = .{};
    outputs.read(&control);
    for (outputs.infos[0..outputs.count], 0..) |*info, at| {
        _ = Printf(l.dl, MSG_OUTPUT, .{ @as([*:0]const u8, "OUTPUT"), outputs.labels[at].?, audiocontrol.percentOf(info.volume) });
    }
    var device: sdk.devices.audio.AudioInfo = .{};
    if (!control.query(&device) or device.preferred_id == 0) return;
    if (outputs.indexOf(device.preferred_id)) |at| {
        _ = Printf(l.dl, MSG_PREFERRED, .{ @as([*:0]const u8, "PREFERRED"), outputs.labels[at].? });
    } else {
        var number: [8:0]u8 = @splat(0);
        audio_file.hexText(number[0..8], device.preferred_id);
        _ = Printf(l.dl, MSG_PREFERRED_GONE, .{ @as([*:0]const u8, "PREFERRED"), @as([*:0]const u8, &number) });
    }
}

/// The line's SAMPLE file decoded whole into memory as the beep's sound,
/// through its sound datatype: false when it cannot be.
fn readSample(l: Libs, settings: *const sound_file.Settings, g: *Gathered) bool {
    const sys = l.sys;
    const dt_lib = sys.OpenLibrary(datatypes.DATATYPESNAME, 0) orelse return false;
    defer sys.CloseLibrary(dt_lib);
    const dt: *DataTypesBase = @ptrCast(dt_lib);
    const object = dt.NewDTObjectA(&settings.sample, &[_]TagItem{
        .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_SOUND },
        .{},
    }) orelse return false;
    defer dt.DisposeDTObject(object);
    var rate: usize = 0;
    var channels: usize = 0;
    var frames: usize = 0;
    _ = dt.GetDTAttrsA(object, &[_]TagItem{
        .{ .tag = sdt.SDTA_SampleRate, .data = @intFromPtr(&rate) },
        .{ .tag = sdt.SDTA_Channels, .data = @intFromPtr(&channels) },
        .{ .tag = sdt.SDTA_Frames, .data = @intFromPtr(&frames) },
        .{},
    });
    if (rate == 0 or rate > sdk.devices.audio.AUDIO_MAX_RATE or (channels != 1 and channels != 2)) return false;
    // A length not known is read up to the most there is room for.
    const most = rate * max_sample_seconds;
    const room: u32 = @intCast(if (frames == 0 or frames > most) most else frames);
    const memory = sys.AllocVec(room * channels * @sizeOf(i16), exec.MEMF_ANY) orelse return false;
    const samples: [*]i16 = @ptrCast(@alignCast(memory));
    var got: u32 = 0;
    while (got < room) {
        var decode = sdt.SdtDecode{ .samples = samples + got * channels, .frames = room - got };
        // Sent straight to the object: DoDTMethodA would write a window's
        // GadgetInfo where the message keeps its samples.
        const more: u32 = @intCast(@min(l.ib.SendMessage(object, @ptrCast(&decode)), room - got));
        if (more == 0) break;
        got += more;
    }
    if (got == 0) {
        sys.FreeVec(memory);
        return false;
    }
    g.beep_memory = memory;
    g.beep = .{
        .samples = samples,
        .frames = got,
        .rate = @intCast(rate),
        .channels = @intCast(channels),
        .volume = sound_file.volumeOf(settings),
    };
    return true;
}

/// What the system starts with, every setting, and the default style.
fn gatherReset(l: Libs, g: *Gathered) void {
    var ms: u32 = 0;
    var rows: u32 = 0;
    var keys: u32 = 0;
    var off_screen: u32 = 0;
    var wide_gadgets: u32 = 0;
    var beep_flash: u32 = 0;
    _ = l.ib.GetDefPrefs(&[_]TagItem{
        .{ .tag = intuition.IPREFS_DoubleClick, .data = @intFromPtr(&ms) },
        .{ .tag = intuition.IPREFS_ScreenFontHeight, .data = @intFromPtr(&rows) },
        .{ .tag = intuition.IPREFS_Keyboard, .data = @intFromPtr(&keys) },
        .{ .tag = intuition.IPREFS_OffScreen, .data = @intFromPtr(&off_screen) },
        .{ .tag = intuition.IPREFS_WideGadgets, .data = @intFromPtr(&wide_gadgets) },
        .{ .tag = intuition.IPREFS_BeepFlash, .data = @intFromPtr(&beep_flash) },
        .{},
    });
    g.add(intuition.IPREFS_DoubleClick, ms);
    g.add(intuition.IPREFS_ScreenFontHeight, rows);
    g.add(intuition.IPREFS_Keyboard, keys);
    g.add(intuition.IPREFS_OffScreen, off_screen);
    g.add(intuition.IPREFS_WideGadgets, wide_gadgets);
    for (font_tags) |tag| g.add(tag, 0);
    g.add(intuition.IPREFS_Pens, 0);
    g.add(intuition.IPREFS_Style, 0);
    g.add(intuition.IPREFS_BeepFlash, beep_flash);
    g.add(intuition.IPREFS_BeepSound, 0);
}

/// The settings in force, a line each.
fn show(l: Libs) void {
    var ms: u32 = 0;
    var rows: u32 = 0;
    var keys: u32 = 0;
    var off_screen: u32 = 0;
    var wide_gadgets: u32 = 0;
    var fonts: [3]?*graphics.TextFont = @splat(null);
    var pens: [sc.NUMDRIPENS]graphics.Pen = undefined;
    var beep_flash: u32 = 0;
    _ = l.ib.GetPrefs(&[_]TagItem{
        .{ .tag = intuition.IPREFS_BeepFlash, .data = @intFromPtr(&beep_flash) },
        .{ .tag = intuition.IPREFS_DoubleClick, .data = @intFromPtr(&ms) },
        .{ .tag = intuition.IPREFS_ScreenFontHeight, .data = @intFromPtr(&rows) },
        .{ .tag = intuition.IPREFS_Keyboard, .data = @intFromPtr(&keys) },
        .{ .tag = intuition.IPREFS_OffScreen, .data = @intFromPtr(&off_screen) },
        .{ .tag = intuition.IPREFS_WideGadgets, .data = @intFromPtr(&wide_gadgets) },
        .{ .tag = font_tags[0], .data = @intFromPtr(&fonts[0]) },
        .{ .tag = font_tags[1], .data = @intFromPtr(&fonts[1]) },
        .{ .tag = font_tags[2], .data = @intFromPtr(&fonts[2]) },
        .{ .tag = intuition.IPREFS_Pens, .data = @intFromPtr(&pens) },
        .{},
    });
    defer for (fonts) |font| if (font) |f| l.gb.CloseFont(f);
    _ = Printf(l.dl, MSG_NUMBER, .{ @as([*:0]const u8, "DOUBLECLICK"), @as(u64, ms), @as([*:0]const u8, "ms") });
    _ = Printf(l.dl, MSG_NUMBER, .{ @as([*:0]const u8, "SCREENFONT"), @as(u64, rows), @as([*:0]const u8, "rows") });
    var keyboard: [8:0]u8 = @splat(0);
    const name = intuition_file.keyboard_names[@min(keys, 2)];
    @memcpy(keyboard[0..name.len], name);
    _ = Printf(l.dl, MSG_WORD, .{ @as([*:0]const u8, "KEYBOARD"), @as([*:0]const u8, &keyboard) });
    var past_edges: [4:0]u8 = @splat(0);
    const answer = intuition_file.off_screen_names[@min(off_screen, 1)];
    @memcpy(past_edges[0..answer.len], answer);
    _ = Printf(l.dl, MSG_WORD, .{ @as([*:0]const u8, "OFFSCREEN"), @as([*:0]const u8, &past_edges) });
    var wide: [4:0]u8 = @splat(0);
    const shape = intuition_file.off_screen_names[@min(wide_gadgets, 1)];
    @memcpy(wide[0..shape.len], shape);
    _ = Printf(l.dl, MSG_WORD, .{ @as([*:0]const u8, "WIDEGADGETS"), @as([*:0]const u8, &wide) });
    const font_names = [3][*:0]const u8{ "SCREEN", "DEFAULT", "FIXED" };
    for (fonts, font_names) |font, label| {
        const f = font orelse continue;
        const rom: [*:0]const u8 = if (f.flags & graphics.FPF_ROMFONT != 0) " (ROM)" else "";
        _ = Printf(l.dl, MSG_FONT, .{ label, f.node.name orelse "?", @as(u64, f.image.height), rom });
    }
    var line: [256:0]u8 = @splat(0);
    _ = palette_file.write(&pens, &line);
    _ = Printf(l.dl, MSG_WORD, .{ @as([*:0]const u8, "PENS"), @as([*:0]const u8, &line) });
    var flashes: [4:0]u8 = @splat(0);
    const flash_word = sound_file.flash_names[@min(beep_flash, 1)];
    @memcpy(flashes[0..flash_word.len], flash_word);
    _ = Printf(l.dl, MSG_WORD, .{ @as([*:0]const u8, "BEEPFLASH"), @as([*:0]const u8, &flashes) });
    showAudio(l);
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const gfx_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, graphics.GRAPHICS_VERSION) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(gfx_lib);
    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const l = Libs{ .sys = sys, .dl = dl, .gb = @ptrCast(gfx_lib), .ib = @ptrCast(int_lib) };

    const from = rdargs.string(argv[arg_from]);
    const reset = argv[arg_reset] != 0;
    const showing = argv[arg_show] != 0;
    // SHOW on its own changes nothing.
    if (showing and from == null and !reset) {
        show(l);
        return dos.RETURN_OK;
    }

    var g = Gathered{};
    defer {
        for (g.fonts) |font| if (font) |f| l.gb.CloseFont(f);
        if (g.style_memory) |memory| sys.FreeVec(memory);
        if (g.beep_memory) |memory| sys.FreeVec(memory);
    }
    var result: i32 = dos.RETURN_OK;
    if (reset) {
        gatherReset(l, &g);
        resetAudio(l);
    } else {
        const dir = from orelse default_dir;
        const steps = [_]*const fn (Libs, [*:0]const u8, *Gathered) i32{ readAudio, readSettings, readFonts, readPens, readStyle, readSound };
        for (steps) |step| result = @max(result, step(l, dir, &g));
        if (result == dos.RETURN_FAIL) return result;
    }
    g.tags[g.count] = .{};
    if (!l.ib.SetPrefs(&g.tags)) {
        _ = Printf(dl, MSG_NOTTAKEN, .{});
        result = @max(result, dos.RETURN_WARN);
    }
    if (showing) show(l);
    return result;
}
