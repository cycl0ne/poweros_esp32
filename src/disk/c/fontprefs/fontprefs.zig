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
const VERSION_STRING = "\x00$VER: FontPrefs 1.1 (3.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FROM/K,SCREEN/K,DEFAULT/K,FIXED/K,SHOW/S";
const arg_from = 0;
const arg_show = 4;
/// SCREEN, DEFAULT and FIXED follow, in that order.
const arg_first_font = 1;
const font_file = sdk.prefs.font;

const default_file = font_file.ENV_FILE;

const MSG_NOLIBRARY = "No %s\n";
const MSG_BADSIZE = "%s: a font is written family/size, as spleen.font/16 or spleen.font/10P\n";
const MSG_NOFONT = "%s: not in FONTS:, at no size that will do\n";
const MSG_NOTFIXED = "%s is proportional: consoles keep pospaz\n";
const MSG_SHOWN = "%-8s %s %d rows%s\n";

/// The three in the templates' order.
const screen_at = 0;
const default_at = 1;
const fixed_at = 2;

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
    var line: font_file.Line = .{};
    const show = argv[arg_show] != 0;
    const none_given = given[0] == null and given[1] == null and given[2] == null;
    if (show and none_given) return showFonts(sys, dl);
    if (none_given) {
        const from = rdargs.string(argv[arg_from]) orelse default_file;
        var text: [1024]u8 = undefined;
        const read = sdk.prefs.load(dl, from, &text) orelse return dos.RETURN_OK;
        const words = sdk.prefs.firstLine(read) orelse return dos.RETURN_OK;
        if (font_file.parse(words, &line)) |wrong| {
            _ = Printf(dl, "%s: %s\n", .{ from, wrong });
            return dos.RETURN_FAIL;
        }
        for (0..3) |i| {
            if (line.get(@enumFromInt(i)) != null) given[i] = @ptrCast(&line.values[i]);
        }
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
    var family: [3][font_file.value_len:0]u8 = undefined;
    for (given, 0..) |text_or_null, i| {
        const text = text_or_null orelse continue;
        var length: usize = 0;
        while (text[length] != 0) length += 1;
        const want = font_file.attrOf(text[0..length], &family[i]) orelse {
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
