// SPDX-License-Identifier: MIT
//! Notepad: a text file in a window, to read and to write. Built against
//! the SDK only.
//!
//!   Notepad [FILE]
//!
//! A window on the default public screen: a ribbon of commands along the
//! top, and under it textedit.gadget with the file's text, typed into
//! where the cursor is (the gadget's own keys are in
//! sdk/libs/gadgets/textedit.zig). FILE is opened at the start; a name
//! that is not there yet is the file the text is saved to.
//!
//! The scroll bars are in the window's border, one down the right and one
//! along the bottom, the sizing gadget in the corner between them; the
//! window object makes them (`WINDOWA_VertScroller`,
//! `WINDOWA_HorizScroller`) with Notepad's tags. Each is joined to the
//! text: its `ICA_TARGET` is the gadget and its `ICA_MAP`
//! turns its top into `TEXTEDIT_TopVert` or `TEXTEDIT_TopHoriz`, so a drag
//! moves the text without Notepad hearing of it. The other way, the gadget
//! tells the window where its view is (`IDCMP_IDCMPUPDATE`) and Notepad
//! sets the bars from that. While lines wrap nothing is wider than the
//! window, and the bar along the bottom shows a knob as long as itself.
//!
//! The menus, with their right-Amiga keys:
//!
//!   Project  New (N), Open... (O), Save (S), Save As..., Quit (Q)
//!   Edit     Undo (Z), Redo (Y), Cut (X), Copy (C), Paste (V),
//!            Select All (A)
//!   Search   Find... (F), Find Next (G), Find Previous (P),
//!            Replace... (R)
//!   View     Word Wrap (W), Line Numbers (L), both on to begin with;
//!            Zig Highlighting (H), off; Ribbon
//!
//! **The ribbon** (ribbon.gadget, made from a table with `rb.build`) has
//! two tabs. Home has the commands of the text: Clipboard (Paste, Cut,
//! Copy), Undo (Undo and Redo, disabled while there is nothing to undo or
//! redo - textedit.gadget 1.4's `TEXTEDIT_CanUndo`, `TEXTEDIT_CanRedo`)
//! and Editing (Find, which drops down Find Next and Find Previous;
//! Replace; Select All). View has its toggles: Word Wrap and Line Numbers,
//! and Zig. A menu item and a ribbon button are one command: the item's
//! user data is the button's ID, and a toggle and its check mark say the
//! same whichever was used. No label marks a key, since a key typed is
//! the text's. View's Ribbon hides it and shows it again, and
//! `ENV:Notepad.prefs` keeps that (`RIBBON=NO`), ENVARC: too. In a window
//! lower than 400 pixels inside, a small board's, the ribbon is its row
//! of tabs alone, a tab dropping its page down. Without toolbutton.gadget,
//! command.image or ribbon.gadget Notepad has no ribbon and works as
//! before.
//!
//! Zig Highlighting gives the text a highlight hook (highlight.zig) that
//! labels each line as Zig - keywords, types, built-in functions, strings,
//! numbers, comments - and the text draws each kind in a colour of its
//! own.
//!
//! Control-X, -C and -V cut, copy and paste as the menu does: the gadget
//! hands those keys to the window, and Notepad works the clipboard from
//! its own process. Open and Save As ask with asl.library's file
//! requester. A text that has changed is not let go - by New, Open, Quit
//! or the close gadget - before a requester asks whether to save it; the
//! window's title says the file's name, with a `*` before it while it has
//! changed. A file dragged from the desktop and let go on the window is
//! opened as Open opens one.
//!
//! Find... and Replace... open a small window: the text to find, what to
//! put in its place, whether case matters, and buttons that find the next
//! one, replace it and find the next, or replace every one. Find Next and
//! Find Previous go on with the last text looked for. Ctrl-C ends Notepad
//! as Quit does.

const sdk = @import("sdk");
const asl = sdk.asl;
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const iffparse = sdk.iffparse;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const mn = intuition.menus;
const classusr = intuition.classusr;
const icc = intuition.icclass;
const te = sdk.gadgets.textedit;
const sr = sdk.gadgets.scroller;
const highlight = @import("highlight.zig");
const st = sdk.gadgets.string;
const cb = sdk.gadgets.checkbox;
const tb = sdk.gadgets.toolbutton;
const rb = sdk.gadgets.ribbon;
const command = sdk.images.command;
const prefs = sdk.prefs;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const AslBase = sdk.interface.asl.AslBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const IFFParseBase = sdk.interface.iffparse.IFFParseBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const Object = intuition.Object;
const Window = intuition.Window;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Notepad";
const VERSION = "1.5";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (29.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
/// What the screen's bar says while one of its windows is active.
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const template = "FILE";

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display\n";
const MSG_NOMEMORY = "No memory for the window\n";

/// The longest path a file is kept by.
const path_size = 256;
/// The longest text looked for, or put in its place.
const search_size = 128;

const ID_EDITOR = 1;
const ID_VERT = 10;
const ID_HORIZ = 11;
const ID_RIBBON = 12;
// The ribbon's Find, whose list says to find the next or the one before.
const ID_FINDS = 20;
// The find window's.
const ID_FIND_TEXT = 2;
const ID_WITH_TEXT = 3;
const ID_ANY_CASE = 4;
const ID_FIND = 5;
const ID_REPLACE = 6;
const ID_REPLACE_ALL = 7;

/// What Notepad does when asked: a menu item's user data and a ribbon
/// button's `GA_ID` both, so the two are one command.
const Command = enum(u32) {
    new = 100,
    open,
    save,
    save_as,
    quit,
    undo,
    redo,
    cut,
    copy,
    paste,
    select_all,
    find,
    find_next,
    find_previous,
    replace,
    wrap,
    numbers,
    zig,
    ribbon,

    fn id(which: Command) u32 {
        return @intFromEnum(which);
    }

    /// The command of a menu item's user data or a gadget's ID; null for
    /// none.
    fn of(value: usize) ?Command {
        if (value < @intFromEnum(Command.new) or value > @intFromEnum(Command.ribbon)) return null;
        return @enumFromInt(value);
    }
};

fn item(label: [*:0]const u8, key: ?[*:0]const u8, which: Command) mn.NewMenu {
    return .{ .type = mn.NM_ITEM, .label = label, .comm_key = key, .user_data = @ptrFromInt(which.id()) };
}

/// A View item with a check mark, toggled as it is picked.
fn toggleItem(label: [*:0]const u8, key: ?[*:0]const u8, which: Command, on: bool) mn.NewMenu {
    const checked: u32 = if (on) mn.CHECKED else 0;
    return .{ .type = mn.NM_ITEM, .label = label, .comm_key = key, .flags = mn.CHECKIT | mn.MENUTOGGLE | checked, .user_data = @ptrFromInt(which.id()) };
}

const bar = mn.NewMenu{ .type = mn.NM_ITEM, .label = mn.NM_BARLABEL };

const menus = [_]mn.NewMenu{
    .{ .type = mn.NM_TITLE, .label = "Project" },
    item("New", "N", .new),
    item("Open...", "O", .open),
    item("Save", "S", .save),
    item("Save As...", null, .save_as),
    bar,
    item("Quit", "Q", .quit),
    .{ .type = mn.NM_TITLE, .label = "Edit" },
    item("Undo", "Z", .undo),
    item("Redo", "Y", .redo),
    bar,
    item("Cut", "X", .cut),
    item("Copy", "C", .copy),
    item("Paste", "V", .paste),
    bar,
    item("Select All", "A", .select_all),
    .{ .type = mn.NM_TITLE, .label = "Search" },
    item("Find...", "F", .find),
    item("Find Next", "G", .find_next),
    item("Find Previous", "P", .find_previous),
    item("Replace...", "R", .replace),
    .{ .type = mn.NM_TITLE, .label = "View" },
    toggleItem("Word Wrap", "W", .wrap, true),
    toggleItem("Line Numbers", "L", .numbers, true),
    toggleItem("Zig Highlighting", "H", .zig, false),
    bar,
    toggleItem("Ribbon", null, .ribbon, false),
    .{},
};

/// Where the View menu's Ribbon item is in `menus`, to be checked or not
/// before the strip is made.
const ribbon_item = blk: {
    for (menus, 0..) |entry, at| {
        if (entry.user_data == @as(?*anyopaque, @ptrFromInt(Command.ribbon.id()))) break :blk at;
    }
    unreachable;
};

const finds = [_:null]?[*:0]const u8{ "Find Next", "Find Previous" };

/// The ribbon: the menus' commands for the text on Home, the toggles on
/// View. No label has a key marked: a key typed is the text's.
const ribbon_table = [_]rb.NewRibbon{
    .{ .type = rb.RB_TAB, .label = "Home" },
    .{ .type = rb.RB_GROUP, .label = "Clipboard", .glyph = command.CMD_PASTE, .reduce = 1 },
    .{ .type = rb.RB_LARGE, .id = Command.paste.id(), .label = "Paste", .glyph = command.CMD_PASTE, .hint = "Put in what was cut or copied" },
    .{ .type = rb.RB_MEDIUM, .id = Command.cut.id(), .label = "Cut", .glyph = command.CMD_CUT },
    .{ .type = rb.RB_MEDIUM, .id = Command.copy.id(), .label = "Copy", .glyph = command.CMD_COPY },
    .{ .type = rb.RB_GROUP, .label = "Undo", .glyph = command.CMD_UNDO, .reduce = 2 },
    .{ .type = rb.RB_MEDIUM, .id = Command.undo.id(), .label = "Undo", .glyph = command.CMD_UNDO, .flags = rb.RBF_DISABLED },
    .{ .type = rb.RB_MEDIUM, .id = Command.redo.id(), .label = "Redo", .glyph = command.CMD_REDO, .flags = rb.RBF_DISABLED },
    .{ .type = rb.RB_GROUP, .label = "Editing", .glyph = command.CMD_FIND },
    .{ .type = rb.RB_LARGE, .id = ID_FINDS, .label = "Find", .glyph = command.CMD_FIND, .kind = tb.TBKIND_SPLIT, .labels = &finds, .hint = "Find a text; the list finds the next again, or the one before" },
    .{ .type = rb.RB_MEDIUM, .id = Command.replace.id(), .label = "Replace", .glyph = command.CMD_REPLACE, .hint = "Put another text in the place of one found" },
    .{ .type = rb.RB_MEDIUM, .id = Command.select_all.id(), .label = "Select All", .glyph = command.CMD_SELECT_ALL, .hint = "Select the whole text" },
    .{ .type = rb.RB_TAB, .label = "View" },
    .{ .type = rb.RB_GROUP, .label = "Lines", .glyph = command.CMD_WRAP },
    .{ .type = rb.RB_LARGE, .id = Command.wrap.id(), .label = "Word Wrap", .glyph = command.CMD_WRAP, .kind = tb.TBKIND_TOGGLE, .flags = rb.RBF_CHECKED, .hint = "Go on in the next row rather than past the window's edge" },
    .{ .type = rb.RB_LARGE, .id = Command.numbers.id(), .label = "Line Numbers", .glyph = command.CMD_LINE_NUMBERS, .kind = tb.TBKIND_TOGGLE, .flags = rb.RBF_CHECKED, .hint = "Number each line at the left" },
    .{ .type = rb.RB_GROUP, .label = "Highlighting", .glyph = command.CMD_HIGHLIGHT },
    .{ .type = rb.RB_LARGE, .id = Command.zig.id(), .label = "Zig", .glyph = command.CMD_HIGHLIGHT, .kind = tb.TBKIND_TOGGLE, .hint = "Show Zig's keywords, strings and comments each in a colour" },
    .{ .type = rb.RB_END },
};

/// The window's room under which the ribbon is its row of tabs alone: a
/// small board's screen.
const ribbon_minimize_below = 400;

/// Where Notepad keeps whether it shows the ribbon: `RIBBON=YES` or `NO`.
const ENV_FILE = "ENV:Notepad.prefs";
const ENVARC_FILE = "ENVARC:Notepad.prefs";

/// The find window, while it is open.
const Finder = struct {
    object: *Object,
    window: *Window,
    find_field: *Object,
    with_field: *Object,
    any_case: *Object,
};

const Notepad = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ib: *IntuitionBase,
    screen: *intuition.Screen,
    object: *Object,
    window: *Window,
    editor: *Object,
    /// The scroll bars in the border.
    bars: Bars = .{ .vert = null, .horiz = null },
    /// Opened the first time they are wanted.
    asl_lib: ?*exec.Library = null,
    iff_lib: ?*exec.Library = null,
    string_lib: ?*exec.Library = null,
    checkbox_lib: ?*exec.Library = null,
    path: [path_size:0]u8 = @splat(0),
    title: [path_size + 16:0]u8 = @splat(0),
    /// What the title says about the text: changed or not.
    shown_changed: bool = false,
    wrap: bool = true,
    numbers: bool = true,
    /// Zig Highlighting is on, the text labelled through `zig_hook`.
    zig: bool = false,
    zig_hook: sdk.utility.Hook = .{ .entry = highlightZig },
    finder: ?Finder = null,
    search: [search_size:0]u8 = @splat(0),
    with: [search_size:0]u8 = @splat(0),
    any_case: bool = false,
    /// The window as one files can be dropped on, while the desktop runs.
    drop: sdk.anvil.DropTarget = .{},
    /// The window's layout and, when its classes could be had, the ribbon
    /// in it, which comes and goes.
    layout: *Object,
    built: ?*rb.Built = null,
    ribbon_shown: bool = false,
    strip: ?*intuition.Menu = null,
    /// What the ribbon's Undo and Redo were last set to; null to set them
    /// again whatever they are.
    undo_shown: ?[2]bool = null,

    fn deinit(np: *Notepad) void {
        np.closeFinder();
        for ([_]?*exec.Library{ np.asl_lib, np.iff_lib, np.string_lib, np.checkbox_lib }) |lib| {
            if (lib) |opened| np.sys.CloseLibrary(opened);
        }
    }

    // --- the title ----------------------------------------------------------

    fn changed(np: *Notepad) bool {
        var value: usize = 0;
        _ = np.ib.GetAttr(te.TEXTEDIT_Changed, np.editor, &value);
        return value != 0;
    }

    /// The title made to say the file's name, and whether the text has
    /// changed since it was read or saved.
    fn showTitle(np: *Notepad) void {
        const now = np.changed();
        np.shown_changed = now;
        const name: [*:0]const u8 = if (np.path[0] != 0) np.dl.FilePart(&np.path) else "Untitled";
        var used: usize = 0;
        if (now) {
            np.title[0] = '*';
            used = 1;
        }
        var at: usize = 0;
        while (name[at] != 0 and used < np.title.len - 12) : (at += 1) {
            np.title[used] = name[at];
            used += 1;
        }
        for (" - Notepad") |byte| {
            np.title[used] = byte;
            used += 1;
        }
        np.title[used] = 0;
        np.ib.SetWindowTitles(np.window, &np.title, wn.TITLE_UNCHANGED);
    }

    fn followChanges(np: *Notepad) void {
        if (np.changed() != np.shown_changed) np.showTitle();
    }

    /// The keyboard given back to the text.
    fn focus(np: *Notepad) void {
        _ = np.ib.ActivateGadget(np.editor, np.window, null);
    }

    fn tell(np: *Notepad, comptime format: [*:0]const u8, name: [*:0]const u8) void {
        const easy = intuition.requesters.EasyStruct{ .title = "Notepad", .text_format = format, .gadget_format = "OK" };
        const args = [_]usize{@intFromPtr(name)};
        _ = np.ib.EasyRequestArgs(np.window, &easy, null, &args);
    }

    // --- files --------------------------------------------------------------

    /// The text set to `bytes`.
    fn setText(np: *Notepad, bytes: [*]const u8, length: u32) void {
        _ = np.ib.SetGadgetAttrsTagList(np.editor, np.window, &[_]TagItem{
            .{ .tag = te.TEXTEDIT_Text, .data = @intFromPtr(bytes) },
            .{ .tag = te.TEXTEDIT_TextLength, .data = length },
            .{},
        });
    }

    /// The file read into the text, and its name kept. False, and the text
    /// as it was, when it cannot be read; quietly when `quiet` and it is
    /// not there.
    fn load(np: *Notepad, name: [*:0]const u8, quiet: bool) bool {
        const dl = np.dl;
        const sys = np.sys;
        const file = dl.Open(name, dos.MODE_OLDFILE) orelse {
            if (!quiet) np.tell("Cannot open %s", name);
            return false;
        };
        defer _ = dl.Close(file);
        var fib: dos.FileInfoBlock = .{};
        if (!dl.ExamineFH(file, &fib)) {
            np.tell("Cannot read %s", name);
            return false;
        }
        if (fib.size > 0x7FFF_FFFF) {
            np.tell("%s is too big", name);
            return false;
        }
        const size: u32 = @intCast(fib.size);
        const memory: [*]u8 = @ptrCast(sys.AllocVec(@max(size, 1), exec.MEMF_ANY) orelse {
            np.tell("No memory for %s", name);
            return false;
        });
        defer sys.FreeVec(memory);
        if (dl.Read(file, memory, @intCast(size)) != size) {
            np.tell("Cannot read %s", name);
            return false;
        }
        np.setText(memory, size);
        np.keepPath(name);
        np.showTitle();
        return true;
    }

    /// The text written to the file, and the file's name kept. Whether it
    /// was.
    fn save(np: *Notepad, name: [*:0]const u8) bool {
        const dl = np.dl;
        const sys = np.sys;
        var length: usize = 0;
        _ = np.ib.GetAttr(te.TEXTEDIT_Length, np.editor, &length);
        const size: u32 = @intCast(length);
        const memory: [*]u8 = @ptrCast(sys.AllocVec(@max(size, 1), exec.MEMF_ANY) orelse {
            np.tell("No memory to save %s", name);
            return false;
        });
        defer sys.FreeVec(memory);
        var take = te.TepText{ .method_id = te.TEM_GETTEXT, .buffer = memory, .size = size };
        _ = np.ib.DoGadgetMethodA(np.editor, np.window, null, @ptrCast(&take));
        const file = dl.Open(name, dos.MODE_NEWFILE) orelse {
            np.tell("Cannot write %s", name);
            return false;
        };
        const wrote = dl.Write(file, memory, @intCast(size));
        const closed = dl.Close(file);
        if (wrote != size or !closed) {
            np.tell("Cannot write %s", name);
            return false;
        }
        _ = np.ib.SetGadgetAttrsTagList(np.editor, np.window, &[_]TagItem{ .{ .tag = te.TEXTEDIT_Changed, .data = 0 }, .{} });
        np.keepPath(name);
        np.showTitle();
        return true;
    }

    fn keepPath(np: *Notepad, name: [*:0]const u8) void {
        if (name == @as([*:0]const u8, &np.path)) return;
        var at: usize = 0;
        while (name[at] != 0 and at < np.path.len) : (at += 1) np.path[at] = name[at];
        np.path[at] = 0;
    }

    /// A file asked for with asl's requester, into `into`. False when the
    /// requester was cancelled or could not be had.
    fn askFile(np: *Notepad, title: [*:0]const u8, saving: bool, into: *[path_size:0]u8) bool {
        if (np.asl_lib == null) np.asl_lib = np.sys.OpenLibrary(asl.ASLNAME, 0);
        const ab: *AslBase = @ptrCast(np.asl_lib orelse {
            np.tell("No %s", asl.ASLNAME);
            return false;
        });
        // The drawer and the name the file has now, to begin with.
        var drawer: [path_size:0]u8 = @splat(0);
        var file: [*:0]const u8 = "";
        if (np.path[0] != 0) {
            drawer = np.path;
            file = np.dl.FilePart(&np.path);
            const path_end = @intFromPtr(np.dl.PathPart(&drawer)) - @intFromPtr(&drawer);
            drawer[path_end] = 0;
        }
        const handle = ab.AllocAslRequest(asl.ASL_FileRequest, &[_]TagItem{
            .{ .tag = asl.ASLFR_TitleText, .data = @intFromPtr(title) },
            .{ .tag = asl.ASLFR_Window, .data = @intFromPtr(np.window) },
            .{ .tag = asl.ASLFR_SleepWindow, .data = 1 },
            .{ .tag = asl.ASLFR_InitialDrawer, .data = @intFromPtr(&drawer) },
            .{ .tag = asl.ASLFR_InitialFile, .data = @intFromPtr(file) },
            .{ .tag = asl.ASLFR_DoSaveMode, .data = @intFromBool(saving) },
            .{},
        }) orelse return false;
        defer ab.FreeAslRequest(handle);
        if (!ab.AslRequest(handle, null)) return false;
        const req: *asl.FileRequester = @ptrCast(@alignCast(handle));
        const chosen = req.file orelse return false;
        if (chosen[0] == 0) return false;
        into.* = @splat(0);
        if (req.drawer) |dir| {
            var at: usize = 0;
            while (dir[at] != 0 and at < into.len) : (at += 1) into[at] = dir[at];
        }
        return np.dl.AddPart(into, chosen, into.len);
    }

    /// Saved under its own name, or one asked for when it has none.
    /// Whether it was.
    fn saveKept(np: *Notepad) bool {
        if (np.path[0] == 0) return np.saveAs();
        return np.save(&np.path);
    }

    fn saveAs(np: *Notepad) bool {
        var name: [path_size:0]u8 = undefined;
        if (!np.askFile("Save the text as", true, &name)) return false;
        return np.save(&name);
    }

    /// Whether the text may go: it has not changed, or it was saved, or
    /// the requester was told not to.
    fn mayLeave(np: *Notepad) bool {
        if (!np.changed()) return true;
        const easy = intuition.requesters.EasyStruct{
            .title = "Notepad",
            .text_format = "The text has changed.\nSave it first?",
            .gadget_format = "Save|Don't save|Cancel",
        };
        return switch (np.ib.EasyRequestArgs(np.window, &easy, null, null)) {
            1 => np.saveKept(),
            2 => true,
            else => false,
        };
    }

    // --- the clipboard and the edit menu ------------------------------------

    fn iff(np: *Notepad) ?*IFFParseBase {
        if (np.iff_lib == null) np.iff_lib = np.sys.OpenLibrary(iffparse.IFFPARSENAME, 0);
        return @ptrCast(np.iff_lib orelse return null);
    }

    fn cut(np: *Notepad) void {
        const ip = np.iff() orelse return;
        _ = te.cut(np.sys, np.ib, ip, np.editor, np.window);
    }

    fn copy(np: *Notepad) void {
        const ip = np.iff() orelse return;
        _ = te.copy(np.sys, np.ib, ip, np.editor, np.window);
    }

    fn paste(np: *Notepad) void {
        const ip = np.iff() orelse return;
        _ = te.paste(np.sys, np.ib, ip, np.editor, np.window);
    }

    fn send(np: *Notepad, method: classusr.MethodID) void {
        var msg = te.TepCommand{ .method_id = method };
        _ = np.ib.DoGadgetMethodA(np.editor, np.window, null, @ptrCast(&msg));
    }

    /// `bytes` typed in where the cursor is.
    fn typeIn(np: *Notepad, bytes: []const u8) void {
        var in = te.TepInsert{ .text = bytes.ptr, .length = @intCast(bytes.len) };
        _ = np.ib.DoGadgetMethodA(np.editor, np.window, null, @ptrCast(&in));
    }

    // --- the scroll bars ----------------------------------------------------

    fn ask(np: *Notepad, attr: sdk.utility.Tag) usize {
        var value: usize = 0;
        _ = np.ib.GetAttr(attr, np.editor, &value);
        return value;
    }

    /// The bars set from where the text's view is.
    fn followEditor(np: *Notepad) void {
        const bars = np.bars;
        const pairs = [_]struct { bar: ?*Object, total: sdk.utility.Tag, visible: sdk.utility.Tag, top: sdk.utility.Tag }{
            .{ .bar = bars.vert, .total = te.TEXTEDIT_TotalVert, .visible = te.TEXTEDIT_VisibleVert, .top = te.TEXTEDIT_TopVert },
            .{ .bar = bars.horiz, .total = te.TEXTEDIT_TotalHoriz, .visible = te.TEXTEDIT_VisibleHoriz, .top = te.TEXTEDIT_TopHoriz },
        };
        for (pairs) |pair| {
            const scroller = pair.bar orelse continue;
            _ = np.ib.SetGadgetAttrsTagList(scroller, np.window, &[_]TagItem{
                .{ .tag = sr.SCROLLER_Total, .data = np.ask(pair.total) },
                .{ .tag = sr.SCROLLER_Visible, .data = np.ask(pair.visible) },
                .{ .tag = sr.SCROLLER_Top, .data = np.ask(pair.top) },
                .{},
            });
        }
    }

    // --- finding ------------------------------------------------------------

    /// The last text looked for again, forwards or backwards. False when
    /// there is none to look for.
    fn findAgain(np: *Notepad, backwards: bool) bool {
        const length = np.lengthOf(&np.search);
        if (length == 0) return false;
        var find = te.TepFind{
            .method_id = te.TEM_FIND,
            .text = &np.search,
            .length = length,
            .flags = (if (backwards) te.TEFF_BACKWARDS else 0) | (if (np.any_case) te.TEFF_ANYCASE else 0),
        };
        if (np.ib.DoGadgetMethodA(np.editor, np.window, null, @ptrCast(&find)) == 0) np.ib.DisplayBeep(np.screen);
        return true;
    }

    fn lengthOf(_: *Notepad, text: [*:0]const u8) u32 {
        var length: u32 = 0;
        while (text[length] != 0) length += 1;
        return length;
    }

    /// What the find window's fields and box say, taken into `search`,
    /// `with` and `any_case`.
    fn readFinder(np: *Notepad, finder: Finder) void {
        for ([_]struct { field: *Object, into: *[search_size:0]u8 }{
            .{ .field = finder.find_field, .into = &np.search },
            .{ .field = finder.with_field, .into = &np.with },
        }) |pair| {
            var value: usize = 0;
            _ = np.ib.GetAttr(gc.STRINGA_TextVal, pair.field, &value);
            pair.into.* = @splat(0);
            if (value == 0) continue;
            const text: [*:0]const u8 = @ptrFromInt(value);
            var at: usize = 0;
            while (text[at] != 0 and at < search_size) : (at += 1) pair.into[at] = text[at];
        }
        var selected: usize = 0;
        _ = np.ib.GetAttr(gc.GA_Selected, finder.any_case, &selected);
        np.any_case = selected != 0;
    }

    /// The find window opened, or brought to the front with the keyboard
    /// in its first field.
    fn openFinder(np: *Notepad) void {
        if (np.finder) |finder| {
            np.ib.WindowToFront(finder.window);
            np.ib.ActivateWindow(finder.window);
            _ = np.ib.ActivateGadget(finder.find_field, finder.window, null);
            return;
        }
        const sys = np.sys;
        const ib = np.ib;
        if (np.string_lib == null) np.string_lib = sys.OpenLibrary(st.STRING_LIBRARY, 0);
        if (np.checkbox_lib == null) np.checkbox_lib = sys.OpenLibrary(cb.CHECKBOX_LIBRARY, 0);
        if (np.string_lib == null or np.checkbox_lib == null) return;

        const find_field = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_FIND_TEXT },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = gc.GA_TabCycle, .data = 1 },
            .{ .tag = gc.STRINGA_MaxChars, .data = search_size },
            .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(&np.search) },
            .{},
        });
        const with_field = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_WITH_TEXT },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = gc.GA_TabCycle, .data = 1 },
            .{ .tag = gc.STRINGA_MaxChars, .data = search_size },
            .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(&np.with) },
            .{},
        });
        const any_case = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_ANY_CASE },
            .{ .tag = gc.GA_Selected, .data = @intFromBool(np.any_case) },
            .{},
        });
        const buttons = [_]?*Object{
            button(ib, "Find next", ID_FIND),
            button(ib, "Replace", ID_REPLACE),
            button(ib, "Replace all", ID_REPLACE_ALL),
        };
        var whole = find_field != null and with_field != null and any_case != null;
        for (buttons) |made| whole = whole and made != null;
        const row = if (whole) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(buttons[0]) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(buttons[1]) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(buttons[2]) },
            .{},
        }) else null;
        const layout = if (row != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(find_field) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Find") },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(with_field) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Replace with") },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(any_case) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Any case") },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(row) },
            .{},
        }) else null;
        const made_layout = layout orelse {
            // What a layout took is its own; only what none took goes here.
            if (row == null) {
                for (buttons) |made| ib.DisposeObject(made);
            } else ib.DisposeObject(row);
            for ([_]?*Object{ find_field, with_field, any_case }) |made| ib.DisposeObject(made);
            return;
        };
        const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
            .{ .tag = wn.WA_Title, .data = @intFromPtr("Find and Replace") },
            .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr(SCREEN_TITLE) },
            .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(np.screen) },
            .{ .tag = wn.WA_AutoAdjust, .data = 1 },
            .{ .tag = wn.WA_CloseGadget, .data = 1 },
            .{ .tag = wn.WA_DragBar, .data = 1 },
            .{ .tag = wn.WA_DepthGadget, .data = 1 },
            .{ .tag = wn.WA_Activate, .data = 1 },
            .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(made_layout) },
            .{},
        }) orelse {
            ib.DisposeObject(made_layout);
            return;
        };
        var open = wc.WmOpen{};
        if (ib.SendMessage(object, @ptrCast(&open)) == 0) {
            ib.DisposeObject(object);
            return;
        }
        var window_ptr: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_ptr);
        const window: *Window = @ptrFromInt(window_ptr);
        np.finder = .{ .object = object, .window = window, .find_field = find_field.?, .with_field = with_field.?, .any_case = any_case.? };
        _ = ib.ActivateGadget(find_field.?, window, null);
    }

    fn closeFinder(np: *Notepad) void {
        const finder = np.finder orelse return;
        np.readFinder(finder);
        np.ib.DisposeObject(finder.object);
        np.finder = null;
    }

    /// What a gadget of the find window did.
    fn finderPressed(np: *Notepad, id: usize) void {
        const finder = np.finder orelse return;
        np.readFinder(finder);
        const length = np.lengthOf(&np.search);
        if (length == 0) return;
        const flags: u32 = if (np.any_case) te.TEFF_ANYCASE else 0;
        var find = te.TepFind{
            .method_id = te.TEM_FIND,
            .text = &np.search,
            .length = length,
            .with = &np.with,
            .with_length = np.lengthOf(&np.with),
            .flags = flags,
        };
        switch (id) {
            ID_FIND, ID_FIND_TEXT => {},
            ID_REPLACE => find.method_id = te.TEM_REPLACE,
            ID_REPLACE_ALL => find.method_id = te.TEM_REPLACEALL,
            else => return,
        }
        const answer = np.ib.DoGadgetMethodA(np.editor, np.window, null, @ptrCast(&find));
        if (answer == 0 and find.method_id != te.TEM_REPLACE) np.ib.DisplayBeep(np.screen);
        np.followChanges();
    }

    // --- the view and the ribbon --------------------------------------------

    /// Word Wrap, Line Numbers or Zig Highlighting turned on or off: the
    /// text told, and the menu's check mark and the ribbon's toggle made
    /// to say the same, whichever of them was used.
    fn showView(np: *Notepad, which: Command, on: bool) void {
        const tag: TagItem = switch (which) {
            .wrap => blk: {
                np.wrap = on;
                break :blk .{ .tag = te.TEXTEDIT_WordWrap, .data = @intFromBool(on) };
            },
            .numbers => blk: {
                np.numbers = on;
                break :blk .{ .tag = te.TEXTEDIT_LineNumbers, .data = @intFromBool(on) };
            },
            .zig => blk: {
                np.zig = on;
                break :blk .{ .tag = te.TEXTEDIT_HighlightHook, .data = if (on) @intFromPtr(&np.zig_hook) else 0 };
            },
            else => return,
        };
        _ = np.ib.SetGadgetAttrsTagList(np.editor, np.window, &[_]TagItem{ tag, .{} });
        np.followEditor();
        np.check(which, on);
        if (np.built) |built| if (built.entry(which.id())) |toggle| {
            _ = np.ib.SetGadgetAttrsTagList(toggle, np.window, &[_]TagItem{ .{ .tag = tb.TOOLBUTTON_Checked, .data = @intFromBool(on) }, .{} });
        };
    }

    /// The menu item of `which` checked or not, the strip taken off the
    /// window while it changes.
    fn check(np: *Notepad, which: Command, on: bool) void {
        const strip = np.strip orelse return;
        var menu: ?*intuition.Menu = strip;
        while (menu) |title| : (menu = title.next_menu) {
            var entry = title.first_item;
            while (entry) |menu_item| : (entry = menu_item.next_item) {
                if (@intFromPtr(mn.GTMENUITEM_USERDATA(menu_item)) != which.id()) continue;
                if ((menu_item.flags & mn.CHECKED != 0) == on) return;
                np.ib.ClearMenuStrip(np.window);
                menu_item.flags ^= mn.CHECKED;
                _ = np.ib.ResetMenuStrip(np.window, strip);
                return;
            }
        }
    }

    /// The ribbon's Undo and Redo disabled while there is nothing to undo
    /// or redo; set only when that has changed.
    fn followRibbon(np: *Notepad) void {
        const built = np.built orelse return;
        const can = [2]bool{ np.ask(te.TEXTEDIT_CanUndo) != 0, np.ask(te.TEXTEDIT_CanRedo) != 0 };
        if (np.undo_shown) |shown| if (shown[0] == can[0] and shown[1] == can[1]) return;
        np.undo_shown = can;
        for ([_]Command{ .undo, .redo }, can) |which, possible| {
            const undo_button = built.entry(which.id()) orelse continue;
            _ = np.ib.SetGadgetAttrsTagList(undo_button, np.window, &[_]TagItem{ .{ .tag = gc.GA_Disabled, .data = @intFromBool(!possible) }, .{} });
        }
    }

    /// The ribbon shown or hidden - the layout's child hidden, the window
    /// laid out again - and that kept for the next time.
    fn showRibbon(np: *Notepad, shown: bool) void {
        const built = np.built orelse return;
        if (shown == np.ribbon_shown) return;
        np.ribbon_shown = shown;
        _ = np.ib.SetGadgetAttrsTagList(np.layout, np.window, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_ModifyChild, .data = @intFromPtr(built.ribbon) },
            .{ .tag = lg.CHILDA_Hidden, .data = @intFromBool(!shown) },
            .{},
        });
        np.rethink();
        np.keepSettings();
    }

    /// The window laid out again, the bars following the text's new size.
    fn rethink(np: *Notepad) void {
        var again = wc.WmRethink{};
        _ = np.ib.SendMessage(np.object, @ptrCast(&again));
        np.followEditor();
    }

    /// Whether the ribbon is shown, written to ENV: and ENVARC:.
    fn keepSettings(np: *Notepad) void {
        const header = "; Notepad's settings: RIBBON=NO hides the ribbon\n";
        const text: []const u8 = if (np.ribbon_shown) header ++ "RIBBON=YES\n" else header ++ "RIBBON=NO\n";
        for ([_][*:0]const u8{ ENV_FILE, ENVARC_FILE }) |path| _ = prefs.save(np.dl, path, text);
    }

    // --- the commands -------------------------------------------------------

    /// A menu item picked: its command. False to end.
    fn picked(np: *Notepad, number: u32) bool {
        const strip = np.strip orelse return true;
        const picked_item = np.ib.ItemAddress(strip, number) orelse return true;
        const which = Command.of(@intFromPtr(mn.GTMENUITEM_USERDATA(picked_item))) orelse return true;
        // An item with a check mark has checked or unchecked itself.
        const checked = picked_item.flags & mn.CHECKED != 0;
        switch (which) {
            .wrap, .numbers, .zig => np.showView(which, checked),
            .ribbon => np.showRibbon(checked),
            else => return np.perform(which),
        }
        np.focus();
        return true;
    }

    /// A ribbon button pressed - `code` what a toggle turned to, or which
    /// of Find's list was taken. False to end.
    fn pressed(np: *Notepad, id: u32, code: u32) bool {
        if (id == ID_FINDS) {
            const taken: i32 = @bitCast(code);
            return np.perform(if (taken == tb.TBCODE_MAIN) .find else if (taken == 0) .find_next else .find_previous);
        }
        const which = Command.of(id) orelse return true;
        switch (which) {
            .wrap, .numbers, .zig => np.showView(which, code != 0),
            else => return np.perform(which),
        }
        np.focus();
        return true;
    }

    /// A command, from a menu, the ribbon or a key. False to end.
    fn perform(np: *Notepad, which: Command) bool {
        switch (which) {
            .new => if (np.mayLeave()) {
                np.setText("", 0);
                np.path[0] = 0;
                np.showTitle();
            },
            .open => if (np.mayLeave()) {
                var name: [path_size:0]u8 = undefined;
                if (np.askFile("Open a text", false, &name)) _ = np.load(&name, false);
            },
            .save => _ = np.saveKept(),
            .save_as => _ = np.saveAs(),
            .quit => return !np.mayLeave(),
            .undo => np.send(te.TEM_UNDO),
            .redo => np.send(te.TEM_REDO),
            .cut => np.cut(),
            .copy => np.copy(),
            .paste => np.paste(),
            .select_all => np.send(te.TEM_SELECTALL),
            // The find window keeps the keyboard.
            .find, .replace => {
                np.openFinder();
                return true;
            },
            .find_next, .find_previous => if (!np.findAgain(which == .find_previous)) {
                np.openFinder();
                return true;
            },
            .wrap => np.showView(.wrap, !np.wrap),
            .numbers => np.showView(.numbers, !np.numbers),
            .zig => np.showView(.zig, !np.zig),
            .ribbon => np.showRibbon(!np.ribbon_shown),
        }
        np.focus();
        return true;
    }

    /// A key no gadget took: the clipboard's Control keys, or typing that
    /// came while the text did not have the keyboard.
    fn keyed(np: *Notepad, code: u32) void {
        switch (code) {
            0x03 => np.copy(),
            0x18 => np.cut(),
            0x16 => np.paste(),
            '\r' => np.typeIn("\n"),
            '\t' => np.typeIn("\t"),
            else => if (code >= 0x20 and code != 0x7F and !(code >= 0x80 and code < 0xA0)) {
                const char = [1]u8{@intCast(code)};
                np.typeIn(&char);
            },
        }
        np.focus();
    }

    // --- the windows' messages ----------------------------------------------

    /// Everything the main window has to say. False to end.
    fn mainWindow(np: *Notepad) bool {
        var code: u32 = 0;
        var handle = wc.WmHandleInput{ .code = &code };
        while (true) {
            const word = np.ib.SendMessage(np.object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) return true;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => if (np.mayLeave()) return false,
                wc.WMHI_MENUPICK => {
                    const number: u32 = @truncate(word & wc.WMHI_MENUMASK);
                    if (number != mn.MENUNULL and !np.picked(number)) return false;
                },
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    // Minimized or brought back: its height has changed.
                    ID_RIBBON => if (@as(i32, @bitCast(code)) == rb.RBCODE_MINIMIZED) np.rethink(),
                    else => |id| if (!np.pressed(@truncate(id), code)) return false,
                },
                wc.WMHI_VANILLAKEY => np.keyed(@truncate(word & wc.WMHI_KEYMASK)),
                // The text's view moved, or its size: the bars follow.
                wc.WMHI_IDCMPUPDATE, wc.WMHI_NEWSIZE => np.followEditor(),
                else => {},
            }
        }
    }

    fn findWindow(np: *Notepad) void {
        const finder = np.finder orelse return;
        var code: u32 = 0;
        var handle = wc.WmHandleInput{ .code = &code };
        while (true) {
            const word = np.ib.SendMessage(finder.object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) return;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => {
                    np.closeFinder();
                    return;
                },
                wc.WMHI_GADGETUP => np.finderPressed(word & wc.WMHI_GADGETMASK),
                else => {},
            }
        }
    }

    /// Files let go on the window: each opened, as Open would, once the
    /// text before it may go.
    fn dropped(np: *Notepad) void {
        var name: [path_size:0]u8 = undefined;
        while (np.drop.next(np.dl, &name)) |file| {
            if (file.is_drawer) continue;
            np.ib.ActivateWindow(np.window);
            if (np.mayLeave()) _ = np.load(file.name, false);
            np.focus();
        }
    }

    fn signalOf(np: *Notepad, object: *Object) u32 {
        var mask: usize = 0;
        _ = np.ib.GetAttr(wc.WINDOWA_SigMask, object, &mask);
        return @truncate(mask);
    }

    fn run(np: *Notepad) void {
        np.focus();
        while (true) {
            const main_signal = np.signalOf(np.object);
            const find_signal = if (np.finder) |finder| np.signalOf(finder.object) else 0;
            const drop_signal = np.drop.signal();
            const got = np.sys.Wait(main_signal | find_signal | drop_signal | exec.SIGBREAKF_CTRL_C);
            if (got & exec.SIGBREAKF_CTRL_C != 0 and np.mayLeave()) return;
            if (got & find_signal != 0) np.findWindow();
            if (got & drop_signal != 0) np.dropped();
            if (!np.mainWindow()) return;
            np.followChanges();
            np.followRibbon();
        }
    }
};

/// The text's highlight hook while Zig Highlighting is on: a line's bytes
/// labelled as Zig. Called while the text draws, on whichever task draws
/// it.
fn highlightZig(_: *sdk.utility.Hook, _: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const line: *te.TeHighlightMsg = @ptrCast(@alignCast(message orelse return 0));
    highlight.label(line.text[0..line.length], line.kinds[0..line.length]);
    return 0;
}

/// The two scroll bars in the border, the window object's; either is
/// null when it could not be made.
const Bars = struct { vert: ?*Object, horiz: ?*Object };

/// What a bar tells the text as it is dragged; its GA_ID goes no further,
/// or the text would take it for its own.
const vert_map = [_]TagItem{
    .{ .tag = sr.SCROLLER_Top, .data = te.TEXTEDIT_TopVert },
    .{ .tag = gc.GA_ID, .data = sdk.utility.TAG_IGNORE },
    .{},
};
const horiz_map = [_]TagItem{
    .{ .tag = sr.SCROLLER_Top, .data = te.TEXTEDIT_TopHoriz },
    .{ .tag = gc.GA_ID, .data = sdk.utility.TAG_IGNORE },
    .{},
};

fn button(ib: *IntuitionBase, label: [*:0]const u8, id: u32) ?*Object {
    return ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr(label) },
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    });
}

/// Whether the ribbon is to be shown, from `ENV:Notepad.prefs`: yes unless
/// it says `RIBBON=NO`, and yes without utility.library to read it.
fn ribbonWanted(sys: *ExecBase, dl: *DosBase, ub: ?*UtilityBase) bool {
    const utility_base = ub orelse return true;
    const text = prefs.loadWhole(sys, dl, ENV_FILE) orelse return true;
    defer sys.FreeVec(text.ptr);
    const line = prefs.firstLine(text) orelse return true;
    var pairs = prefs.Pairs.init(utility_base, line);
    while (pairs.next() catch null) |pair| {
        if (prefs.style.same(pair.key, "RIBBON")) return prefs.yesOrNo(pair.value) orelse true;
    }
    return true;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);

    const intuition_lib = sys.OpenLibrary("intuition.library", 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{@as([*:0]const u8, "intuition.library")});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(intuition_lib);
    const ib: *IntuitionBase = @ptrCast(intuition_lib);
    const editor_lib = sys.OpenLibrary(te.TEXTEDIT_LIBRARY, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{@as([*:0]const u8, te.TEXTEDIT_LIBRARY)});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(editor_lib);

    // What Notepad does without: utility.library, which reads its
    // settings, and the ribbon's classes. Open until the window object is
    // gone too.
    const optional_names = [_][*:0]const u8{ sdk.utility.UTILITYNAME, tb.TOOLBUTTON_LIBRARY, command.COMMAND_LIBRARY, rb.RIBBON_LIBRARY };
    var optional: [optional_names.len]?*exec.Library = @splat(null);
    defer for (optional) |lib| {
        if (lib) |opened| sys.CloseLibrary(opened);
    };
    for (optional_names, 0..) |name, i| optional[i] = sys.OpenLibrary(name, 0);
    const ub: ?*UtilityBase = @ptrCast(optional[0]);
    const built: ?*rb.Built = if (optional[1] != null and optional[2] != null and optional[3] != null) rb.build(sys, ib, &ribbon_table, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_RIBBON },
        .{ .tag = rb.RIBBON_MinimizeBelow, .data = ribbon_minimize_below },
        .{},
    }) else null;
    // After the window object, which disposes of the ribbon.
    defer if (built) |made| made.free(sys, ib);
    const ribbon_shown = built != null and ribbonWanted(sys, dl, ub);

    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);

    // What the editor tells comes to the window, so that a change to the
    // text wakes Notepad to put the mark in the title.
    const editor = ib.NewObjectTagList(null, te.TEXTEDIT_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_EDITOR },
        .{ .tag = te.TEXTEDIT_WordWrap, .data = 1 },
        .{ .tag = te.TEXTEDIT_LineNumbers, .data = 1 },
        .{ .tag = te.TEXTEDIT_Scrollers, .data = 0 },
        .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
        .{},
    }) orelse {
        if (built) |made| ib.DisposeObject(made.ribbon);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    // The ribbon on top, when there is one, and the text under it.
    const ribbon_tags = [_]TagItem{
        .{ .tag = lg.LAYOUTA_AddChild, .data = if (built) |made| @intFromPtr(made.ribbon) else 0 },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.CHILDA_Hidden, .data = @intFromBool(!ribbon_shown) },
        .{ .tag = sdk.utility.TAG_MORE, .data = @intFromPtr(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(editor) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 1 },
            .{},
        }) },
    };
    const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Margin, .data = 2 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 2 },
        .{ .tag = sdk.utility.TAG_MORE, .data = @intFromPtr(if (built != null) &ribbon_tags else ribbon_tags[3..].ptr) },
    }) orelse {
        // What the layout did not take is still Notepad's.
        ib.DisposeObject(editor);
        if (built) |made| ib.DisposeObject(made.ribbon);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Notepad") },
        .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr(SCREEN_TITLE) },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_InnerWidth, .data = 600 },
        .{ .tag = wn.WA_InnerHeight, .data = 460 },
        .{ .tag = wn.WA_AutoAdjust, .data = 1 },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_IDCMPUPDATE | wn.IDCMP_NEWSIZE },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(layout) },
        // Each bar joined to the text, a drag moving it.
        .{ .tag = wc.WINDOWA_VertScroller, .data = @intFromPtr(&[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_VERT },
            .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(editor) },
            .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&vert_map) },
            .{},
        }) },
        .{ .tag = wc.WINDOWA_HorizScroller, .data = @intFromPtr(&[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_HORIZ },
            .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(editor) },
            .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&horiz_map) },
            .{},
        }) },
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.DisposeObject(object);

    var open = wc.WmOpen{};
    if (ib.SendMessage(object, @ptrCast(&open)) == 0) {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }
    var window_ptr: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_ptr);
    const window: *Window = @ptrFromInt(window_ptr);
    var vert: usize = 0;
    var horiz: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_VertScroller, object, &vert);
    _ = ib.GetAttr(wc.WINDOWA_HorizScroller, object, &horiz);
    const bars = Bars{ .vert = @ptrFromInt(vert), .horiz = @ptrFromInt(horiz) };

    // The menus; a program without them still edits, so a strip that will
    // not go on is left off rather than given up over. View's Ribbon is
    // checked while it is shown, and there only when there is one.
    var table = menus;
    if (built == null) {
        table[ribbon_item].flags |= mn.NM_ITEMDISABLED;
    } else if (ribbon_shown) table[ribbon_item].flags |= mn.CHECKED;
    const strip = blk: {
        const made = ib.CreateMenusA(&table, null) orelse break :blk null;
        if (!ib.LayoutMenusA(made, screen, null) or !ib.SetMenuStrip(window, made)) {
            ib.FreeMenus(made);
            break :blk null;
        }
        break :blk made;
    };
    defer if (strip) |made| {
        ib.ClearMenuStrip(window);
        ib.FreeMenus(made);
    };

    var np = Notepad{
        .sys = sys,
        .dl = dl,
        .ib = ib,
        .screen = screen,
        .object = object,
        .window = window,
        .editor = editor,
        .bars = bars,
        .layout = layout,
        .built = built,
        .ribbon_shown = ribbon_shown,
        .strip = strip,
    };
    defer np.deinit();
    // Taken off the desktop's list before the window closes.
    np.drop.add(sys, window);
    defer np.drop.remove();
    if (dos.rdargs.string(argv[0])) |name| {
        // A name that is not there yet is where the text will be saved.
        if (!np.load(name, true)) np.keepPath(name);
    }
    np.showTitle();
    np.followEditor();
    np.run();
    return dos.RETURN_OK;
}
