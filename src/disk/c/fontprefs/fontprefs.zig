// SPDX-License-Identifier: MIT
//! FontPrefs: the system's fonts, from ENV:Sys/font.prefs or as given.
//! Built against the SDK only.
//!
//!   FontPrefs FROM/K,SCREEN/K,DEFAULT/K,FIXED/K,SHOW/S
//!
//! Each font is a family and a size: `spleen.font/16` for 16 rows,
//! `spleen.font/10P` for 10 points. SCREEN is the font of screens' title
//! bars and menus, DEFAULT the text in windows and gadgets, FIXED the
//! consoles', which must be fixed-width. One left out is pospaz from the
//! ROM.
//!
//! Given none of the three, they are read from FROM, ENV:Sys/font.prefs
//! unless named: its first line that is not a comment, in the same form.
//! A missing file changes nothing.
//!
//! Each font is opened with diskfont.library, so any size of any family
//! in FONTS: will do, and handed to intuition.library, which uses them for
//! every screen, window and console opened from then on. S:Startup-Sequence
//! runs this once; run it again after changing the file.
//!
//! SHOW prints the three fonts intuition uses now - after setting them,
//! if fonts are given, and on its own changes nothing:
//!
//!   SCREEN   go.font 24 rows
//!   DEFAULT  go.font 21 rows
//!   FIXED    pospaz.font 16 rows (ROM)
//!
//! A shell or window already open keeps the font it was opened with; the
//! boot shell's window opens before S:Startup-Sequence runs this.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const diskfont = sdk.diskfont;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "FontPrefs";
const VERSION_STRING = "\x00$VER: FontPrefs 1.0 (28.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FROM/K,SCREEN/K,DEFAULT/K,FIXED/K,SHOW/S";
const arg_from = 0;
const arg_show = 4;
/// SCREEN, DEFAULT and FIXED follow, in that order.
const arg_first_font = 1;
const file_template = "SCREEN/K,DEFAULT/K,FIXED/K";

const default_file = "ENV:Sys/font.prefs";

const MSG_NOLIBRARY = "No %s\n";
const MSG_BADSIZE = "%s: a font is written family/size, as spleen.font/16 or spleen.font/10P\n";
const MSG_NOFONT = "%s: not in FONTS:, at no size that will do\n";
const MSG_NOTFIXED = "%s is proportional: consoles keep pospaz\n";
const MSG_SHOWN = "%-8s %s %d rows%s\n";

/// The three in the templates' order.
const screen_at = 0;
const default_at = 1;
const fixed_at = 2;

/// The longest line of the file read.
const max_line = 256;

/// `family/size[P]` split: the family's name into `name`, and the
/// TextAttr asking for it. Null for text not in that form.
fn parse(text: [*:0]const u8, name: *[64:0]u8) ?graphics.TextAttr {
    var len: usize = 0;
    while (text[len] != 0) len += 1;
    var slash: ?usize = null;
    for (0..len) |i| {
        if (text[i] == '/') slash = i;
    }
    const at = slash orelse return null;
    if (at == 0 or at >= name.len) return null;
    for (0..at) |i| name[i] = text[i];
    name[at] = 0;
    var size: u32 = 0;
    var flags: graphics.FontFlags = 0;
    var i = at + 1;
    if (i == len) return null;
    while (i < len) : (i += 1) {
        const c = text[i];
        if (c >= '0' and c <= '9') {
            size = size * 10 + (c - '0');
            if (size > 999) return null;
        } else if ((c == 'P' or c == 'p') and i == len - 1) {
            flags = graphics.FPF_POINTS;
        } else return null;
    }
    if (size == 0) return null;
    return .{ .name = name, .y_size = @intCast(size), .flags = flags };
}

/// The file's first line that is not blank or a comment, into `line`
/// with a newline after it; its length, or null when there is none.
fn readLine(dl: *DosBase, path: [*:0]const u8, line: *[max_line + 1]u8) ?usize {
    const fh = dl.Open(path, dos.MODE_OLDFILE) orelse return null;
    defer _ = dl.Close(fh);
    var text: [1024]u8 = undefined;
    const got = dl.Read(fh, &text, text.len);
    if (got <= 0) return null;
    const bytes = text[0..@intCast(got)];
    var start: usize = 0;
    while (start < bytes.len) {
        var end = start;
        while (end < bytes.len and bytes[end] != '\n') end += 1;
        var first = start;
        while (first < end and (bytes[first] == ' ' or bytes[first] == '\t')) first += 1;
        if (first < end and bytes[first] != '#' and bytes[first] != ';' and end - start <= max_line) {
            const len = end - start;
            for (0..len) |i| line[i] = bytes[start + i];
            line[len] = '\n';
            return len + 1;
        }
        start = end + 1;
    }
    return null;
}

/// The three fonts intuition uses now, a line each.
fn showFonts(sys: *ExecBase, dl: *DosBase) i32 {
    const gfx_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, graphics.GRAPHICS_VERSION) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(gfx_lib);
    const gb: *GraphicsBase = @ptrCast(gfx_lib);
    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);
    const sf = intuition.screens;
    const which = [_]struct { name: [*:0]const u8, font: u32 }{
        .{ .name = "SCREEN", .font = sf.SYSFONT_SCREEN },
        .{ .name = "DEFAULT", .font = sf.SYSFONT_DEFAULT },
        .{ .name = "FIXED", .font = sf.SYSFONT_FIXED },
    };
    for (which) |one| {
        const font = ib.OpenSystemFont(one.font) orelse continue;
        defer gb.CloseFont(font);
        const rom: [*:0]const u8 = if (font.flags & graphics.FPF_ROMFONT != 0) " (ROM)" else "";
        _ = Printf(dl, MSG_SHOWN, .{ one.name, font.node.name orelse "?", @as(u32, font.image.height), rom });
    }
    return dos.RETURN_OK;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [5]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    // The three as given, or from the file.
    var given: [3]?[*:0]const u8 = @splat(null);
    for (0..3) |i| given[i] = rdargs.string(argv[arg_first_font + i]);
    var file_args: ?*dos.RDArgs = null;
    var file_argv: [3]usize = @splat(0);
    var line: [max_line + 1]u8 = undefined;
    defer if (file_args) |fa| dl.FreeArgs(fa);
    const show = argv[arg_show] != 0;
    const none_given = given[0] == null and given[1] == null and given[2] == null;
    if (show and none_given) return showFonts(sys, dl);
    if (none_given) {
        const from = rdargs.string(argv[arg_from]) orelse default_file;
        const length = readLine(dl, from, &line) orelse return dos.RETURN_OK;
        var source: dos.RDArgs = .{ .source = .{ .buffer = &line, .length = @intCast(length) } };
        file_args = dl.ReadArgs(file_template, &file_argv, &source) orelse {
            _ = dl.PrintFault(dl.IoErr(), from);
            return dos.RETURN_FAIL;
        };
        for (0..3) |i| given[i] = rdargs.string(file_argv[i]);
    }

    const df_lib = sys.OpenLibrary(diskfont.DISKFONTNAME, diskfont.DISKFONT_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{diskfont.DISKFONTNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(df_lib);
    const dfb: *DiskfontBase = @ptrCast(df_lib);
    const gfx_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, graphics.GRAPHICS_VERSION) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(gfx_lib);
    const gb: *GraphicsBase = @ptrCast(gfx_lib);
    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    var fonts: [3]?*graphics.TextFont = @splat(null);
    defer for (fonts) |font| if (font) |f| gb.CloseFont(f);
    var result: i32 = dos.RETURN_OK;
    var family: [3][64:0]u8 = undefined;
    for (given, 0..) |text_or_null, i| {
        const text = text_or_null orelse continue;
        const want = parse(text, &family[i]) orelse {
            _ = Printf(dl, MSG_BADSIZE, .{text});
            result = dos.RETURN_WARN;
            continue;
        };
        fonts[i] = dfb.OpenDiskFont(&want);
        if (fonts[i] == null) {
            _ = Printf(dl, MSG_NOFONT, .{text});
            result = dos.RETURN_WARN;
        }
    }
    // The fixed font is refused when it is not fixed-width; the other two
    // are set all the same.
    if (fonts[fixed_at]) |f| {
        if (f.image.flags & graphics.FPF_PROPORTIONAL != 0) {
            _ = Printf(dl, MSG_NOTFIXED, .{given[fixed_at].?});
            gb.CloseFont(f);
            fonts[fixed_at] = null;
            result = dos.RETURN_WARN;
        }
    }
    _ = ib.SetSystemFonts(fonts[screen_at], fonts[default_at], fonts[fixed_at]);
    if (show) {
        const shown = showFonts(sys, dl);
        if (shown != dos.RETURN_OK) return shown;
    }
    return result;
}
