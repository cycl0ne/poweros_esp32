// SPDX-License-Identifier: MIT
//! IPrefs: intuition.library's own settings, from ENV:Sys/intuition.prefs,
//! and the system's pens, from ENV:Sys/palette.prefs. Built against the
//! SDK only.
//!
//!   IPrefs FROM/K
//!
//! Reads FROM, ENV:Sys/intuition.prefs unless named - its first line that
//! is not a comment, `DOUBLECLICK=500 SCREENFONT=16 KEYBOARD=AUTO` - and
//! hands it to intuition (`SetPrefs`), every window that listens told.
//! What the line leaves out keeps the value it has; a missing file changes
//! nothing. S:Startup-Sequence runs this once, and so does the
//! preferences editor (SYS:Programs/Prefs) after it writes the files.
//!
//! Then the pens: ENV:Sys/palette.prefs' line, a pen's name and its colour
//! for each, handed to intuition as the system's pens (`SetScreenPens`) -
//! every screen without pens of its own takes them, those open too. A pen
//! the line leaves out keeps the colour the default screen has; no file,
//! or no line, changes nothing. The files' forms are `sdk.prefs.intuition`
//! and `sdk.prefs.palette`.

const sdk = @import("sdk");
const dos = sdk.dos;
const intuition = sdk.intuition;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "IPrefs";
const VERSION_STRING = "\x00$VER: IPrefs 1.1 (3.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FROM/K";
const arg_from = 0;

const MSG_NOLIBRARY = "No %s\n";
const MSG_BAD = "%s: %s\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const from = rdargs.string(argv[arg_from]) orelse sdk.prefs.intuition.ENV_FILE;
    var text: [1024]u8 = undefined;

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);
    var result: i32 = dos.RETURN_OK;
    if (sdk.prefs.load(dl, from, &text)) |read| if (sdk.prefs.firstLine(read)) |words| {
        var prefs: intuition.Preferences = .{};
        _ = ib.GetPrefs(&prefs, @sizeOf(intuition.Preferences));
        if (sdk.prefs.intuition.parse(words, &prefs)) |wrong| {
            _ = Printf(dl, MSG_BAD, .{ from, wrong });
            result = dos.RETURN_FAIL;
        } else {
            _ = ib.SetPrefs(&prefs, @sizeOf(intuition.Preferences), true);
        }
    };
    if (setPens(dl, ib, &text) != dos.RETURN_OK) result = dos.RETURN_FAIL;
    return result;
}

/// The system's pens from ENV:Sys/palette.prefs, what it leaves out as the
/// default screen has them.
fn setPens(dl: *DosBase, ib: *IntuitionBase, text: []u8) i32 {
    const palette_file = sdk.prefs.palette;
    const read = sdk.prefs.load(dl, palette_file.ENV_FILE, text) orelse return dos.RETURN_OK;
    const words = sdk.prefs.firstLine(read) orelse return dos.RETURN_OK;
    var palette: palette_file.Palette = .{};
    if (ib.LockPubScreen(null)) |screen| {
        const dri = ib.GetScreenDrawInfo(screen);
        for (&palette.pens, 0..) |*pen, i| pen.* = dri.pens[i];
        ib.FreeScreenDrawInfo(screen, dri);
        ib.UnlockPubScreen(null, screen);
    }
    if (palette_file.parse(words, &palette)) |wrong| {
        _ = Printf(dl, MSG_BAD, .{ @as([*:0]const u8, palette_file.ENV_FILE), wrong });
        return dos.RETURN_FAIL;
    }
    ib.SetScreenPens(null, &palette.pens);
    return dos.RETURN_OK;
}
