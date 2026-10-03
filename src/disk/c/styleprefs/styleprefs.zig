// SPDX-License-Identifier: MIT
//! StylePrefs: the system's style, from ENV:Sys/style.prefs. Built against
//! the SDK only.
//!
//!   StylePrefs FROM/K,RESET/S
//!
//! Reads FROM, ENV:Sys/style.prefs unless named, and hands what it says to
//! intuition.library as the system's style (`SetStyle`): every screen
//! takes it at once, those already open among them, under a screen's own
//! style and over the system's default. RESET leaves the default alone. A
//! missing file changes nothing. S:Startup-Sequence runs this once; run it
//! again after changing the file.
//!
//! The file is a line per part in a state, `#` or `;` starting a comment:
//!
//!   PART=MAIN STATE=HOVERED BORDER=FLAT BORDERCOLOUR=#3A6EA5
//!
//! - PART: MAIN, GROUP, INDICATOR, KNOB, TRACK, SELECTION, TITLE, or one
//!   of intuition's own - FRAME, DROPBOX, CHECK, RADIO, CHECKMARK,
//!   RADIOMARK, TITLEINACTIVE, FIELD, WINDOWBORDER, SCREENBAR, MENU,
//!   REQUESTER - or a number.
//! - STATE: NORMAL (left out, the same), HOVERED, PRESSED, CHECKED,
//!   FOCUSED, DISABLED, or several joined by `+`: PRESSED+FOCUSED.
//! - BACKGROUND, BORDERCOLOUR, SHINE, SHADOW, TEXT: a screen pen by name
//!   (DETAIL, BLOCK, TEXT, SHINE, SHADOW, FILL, FILLTEXT, BACKGROUND,
//!   HIGHLIGHTTEXT, BARDETAIL, BARBLOCK, BARTRIM) or a colour, `#RRGGBB`
//!   or `#AARRGGBB`. BACKGROUND may be two colours, `#FAFBFC..#D8DCE2`:
//!   shaded from the first at the top to the second at the bottom.
//! - BORDER: NONE, FLAT, RAISED, RECESSED, RIDGE, GROOVE; JOINS: NONE,
//!   ANGLED.
//! - BORDERWIDTH (both), BORDERX, BORDERY, RADIUS, PADDING (both),
//!   PADDINGX, PADDINGY, OPACITY (0-255), GAP (a ridge's two bevels
//!   apart, in border thicknesses), TRANSITION (milliseconds a change into
//!   the state takes): numbers.
//!
//! The file's form is `sdk.prefs.style`'s, which the preferences editor
//! (SYS:Programs/Prefs) writes too.
//!
//! What a line leaves out, and every part no line names, stays as the
//! default draws it. A line that cannot be read is reported with its
//! number and passed over; the rest are taken.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const TagItem = utility.TagItem;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "StylePrefs";
const VERSION_STRING = "\x00$VER: StylePrefs 1.2 (3.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FROM/K,RESET/S";
const arg_from = 0;
const arg_reset = 1;

const style_file = sdk.prefs.style;

const default_file = style_file.ENV_FILE;
/// The most of the file read.
const max_file = 16384;
const max_line = style_file.max_line;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOMEMORY = "No memory for the style\n";
const MSG_BADLINE = "%s, line %ld: %s\n";
const MSG_LONG = "%s is longer than %ld bytes: the rest is not read\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    if (argv[arg_reset] != 0) {
        _ = ib.SetStyle(null, null);
        return dos.RETURN_OK;
    }

    // The file whole, or as much of it as is read.
    const from = rdargs.string(argv[arg_from]) orelse default_file;
    const fh = dl.Open(from, dos.MODE_OLDFILE) orelse return dos.RETURN_OK;
    const text_mem = sys.AllocVec(max_file, exec.MEMF_ANY) orelse {
        _ = dl.Close(fh);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(text_mem);
    const text: [*]u8 = @ptrCast(text_mem);
    const got = dl.Read(fh, text, max_file);
    _ = dl.Close(fh);
    if (got < 0) {
        _ = dl.PrintFault(dl.IoErr(), from);
        return dos.RETURN_FAIL;
    }
    const size: usize = @intCast(got);
    var result: i32 = dos.RETURN_OK;
    if (size == max_file) {
        _ = Printf(dl, MSG_LONG, .{ from, @as(u64, max_file) });
        result = dos.RETURN_WARN;
    }

    // Room for every line that has words in it.
    var lines: usize = 0;
    var start: usize = 0;
    while (start < size) {
        var end = start;
        while (end < size and text[end] != '\n') end += 1;
        if (style_file.hasWords(text[start..end])) lines += 1;
        start = end + 1;
    }
    if (lines == 0) {
        _ = ib.SetStyle(null, null);
        return result;
    }
    const tag_bytes = (lines * style_file.tags_per_line + 1) * @sizeOf(TagItem);
    const room = sys.AllocVec(tag_bytes + lines * @sizeOf(graphics.FillStyle), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(room);
    const tags: [*]TagItem = @ptrCast(@alignCast(room));
    const fills: [*]graphics.FillStyle = @ptrCast(@alignCast(@as([*]u8, @ptrCast(room)) + tag_bytes));

    // A line at a time.
    var count: usize = 0;
    var fill_count: usize = 0;
    var number: u64 = 0;
    start = 0;
    while (start < size) {
        var end = start;
        while (end < size and text[end] != '\n') end += 1;
        number += 1;
        const words = text[start..end];
        start = end + 1;
        if (!style_file.hasWords(words)) continue;
        if (words.len > max_line) {
            _ = Printf(dl, MSG_BADLINE, .{ from, number, @as([*:0]const u8, "longer than 256 characters") });
            result = dos.RETURN_WARN;
            continue;
        }
        var line: style_file.Line = undefined;
        if (style_file.parse(words, &line)) |wrong| {
            _ = Printf(dl, MSG_BADLINE, .{ from, number, wrong });
            result = dos.RETURN_WARN;
            continue;
        }
        count += style_file.toTags(&line, tags[count .. count + style_file.tags_per_line], &fills[fill_count]);
        if (style_file.shaded(&line)) fill_count += 1;
    }
    tags[count] = .{};

    if (!ib.SetStyle(null, tags)) {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }
    return result;
}
