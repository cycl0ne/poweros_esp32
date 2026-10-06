// SPDX-License-Identifier: MIT
//! SetPrefs: the system's settings, from the files in ENV:Sys. Built
//! against the SDK only.
//!
//!   SetPrefs FROM/K,RESET/S,SHOW/S
//!
//! Reads the four settings files from FROM, a directory - ENV:Sys unless
//! named; ENVARC:Sys for the ones kept over a restart - and hands them to
//! intuition.library in one `SetPrefs`:
//!
//! - intuition.prefs: the double-click time, the height of a screen's
//!   font when it is given none, when the keyboard on the screen comes up,
//!   and whether a window may be moved partly past the screen's edges.
//! - font.prefs: the fonts of screens' bars and menus, of windows and
//!   gadgets, and of consoles - each opened with diskfont.library, so any
//!   size of any family in FONTS: will do; one left out is pospaz from the
//!   ROM, and a console font that is not fixed-width is refused.
//! - palette.prefs: the system's twelve pens; one left out keeps its
//!   colour.
//! - style.prefs: the system's style, a line per part in a state; a line
//!   that cannot be read is reported with its number and passed over.
//!
//! A file that is not there changes nothing of its own. Every screen and
//! window takes the pens and the style at once, those open too; the
//! fonts and the font height reach what opens from then on. The files'
//! forms are `sdk.prefs`'s, which SYS:Programs/Prefs writes too, and
//! S:Startup-Sequence runs this once at boot.
//!
//! RESET puts every setting back to what the system starts with, and the
//! style to the default; the files are not read. SHOW prints the settings
//! in force - after setting them when FROM or RESET is given, and on its
//! own changes nothing:
//!
//!   DOUBLECLICK  1500 ms
//!   SCREENFONT   16 rows
//!   KEYBOARD     AUTO
//!   OFFSCREEN    NO
//!   SCREEN       go.font 24 rows
//!   DEFAULT      go.font 21 rows
//!   FIXED        pospaz.font 16 rows (ROM)
//!   PENS         DETAIL=#AAAAAA BLOCK=#000000 ...

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
const VERSION_STRING = "\x00$VER: SetPrefs 1.0 (3.10.2026)\r\n";
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

/// What the system starts with, every setting, and the default style.
fn gatherReset(l: Libs, g: *Gathered) void {
    var ms: u32 = 0;
    var rows: u32 = 0;
    var keys: u32 = 0;
    var off_screen: u32 = 0;
    _ = l.ib.GetDefPrefs(&[_]TagItem{
        .{ .tag = intuition.IPREFS_DoubleClick, .data = @intFromPtr(&ms) },
        .{ .tag = intuition.IPREFS_ScreenFontHeight, .data = @intFromPtr(&rows) },
        .{ .tag = intuition.IPREFS_Keyboard, .data = @intFromPtr(&keys) },
        .{ .tag = intuition.IPREFS_OffScreen, .data = @intFromPtr(&off_screen) },
        .{},
    });
    g.add(intuition.IPREFS_DoubleClick, ms);
    g.add(intuition.IPREFS_ScreenFontHeight, rows);
    g.add(intuition.IPREFS_Keyboard, keys);
    g.add(intuition.IPREFS_OffScreen, off_screen);
    for (font_tags) |tag| g.add(tag, 0);
    g.add(intuition.IPREFS_Pens, 0);
    g.add(intuition.IPREFS_Style, 0);
}

/// The settings in force, a line each.
fn show(l: Libs) void {
    var ms: u32 = 0;
    var rows: u32 = 0;
    var keys: u32 = 0;
    var off_screen: u32 = 0;
    var fonts: [3]?*graphics.TextFont = @splat(null);
    var pens: [sc.NUMDRIPENS]graphics.Pen = undefined;
    _ = l.ib.GetPrefs(&[_]TagItem{
        .{ .tag = intuition.IPREFS_DoubleClick, .data = @intFromPtr(&ms) },
        .{ .tag = intuition.IPREFS_ScreenFontHeight, .data = @intFromPtr(&rows) },
        .{ .tag = intuition.IPREFS_Keyboard, .data = @intFromPtr(&keys) },
        .{ .tag = intuition.IPREFS_OffScreen, .data = @intFromPtr(&off_screen) },
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
    const font_names = [3][*:0]const u8{ "SCREEN", "DEFAULT", "FIXED" };
    for (fonts, font_names) |font, label| {
        const f = font orelse continue;
        const rom: [*:0]const u8 = if (f.flags & graphics.FPF_ROMFONT != 0) " (ROM)" else "";
        _ = Printf(l.dl, MSG_FONT, .{ label, f.node.name orelse "?", @as(u64, f.image.height), rom });
    }
    var line: [256:0]u8 = @splat(0);
    _ = palette_file.write(&pens, &line);
    _ = Printf(l.dl, MSG_WORD, .{ @as([*:0]const u8, "PENS"), @as([*:0]const u8, &line) });
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
    }
    var result: i32 = dos.RETURN_OK;
    if (reset) {
        gatherReset(l, &g);
    } else {
        const dir = from orelse default_dir;
        const steps = [_]*const fn (Libs, [*:0]const u8, *Gathered) i32{ readSettings, readFonts, readPens, readStyle };
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
