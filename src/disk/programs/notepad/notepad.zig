// SPDX-License-Identifier: MIT
//! Notepad: a text file in a window, to read and to write. Built against
//! the SDK only.
//!
//!   Notepad [FILE]
//!
//! A window on the default public screen that is all textedit.gadget: the
//! file's text, typed into where the cursor is (the gadget's own keys are
//! in sdk/libs/gadgets/textedit.zig). FILE is opened at the start; a name
//! that is not there yet is the file the text is saved to.
//!
//! The scroll bars are in the window's border, one down the right and one
//! along the bottom, the sizing gadget in the corner between them. Each is
//! joined to the text: its `ICA_TARGET` is the gadget and its `ICA_MAP`
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
//!   View     Word Wrap (W), on to begin with
//!
//! Control-X, -C and -V cut, copy and paste as the menu does: the gadget
//! hands those keys to the window, and Notepad works the clipboard from
//! its own process. Open and Save As ask with asl.library's file
//! requester. A text that has changed is not let go - by New, Open, Quit
//! or the close gadget - before a requester asks whether to save it; the
//! window's title says the file's name, with a `*` before it while it has
//! changed.
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
const pg = intuition.propgclass;
const st = sdk.gadgets.string;
const cb = sdk.gadgets.checkbox;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const AslBase = sdk.interface.asl.AslBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const IFFParseBase = sdk.interface.iffparse.IFFParseBase;
const Object = intuition.Object;
const Window = intuition.Window;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Notepad";
const VERSION_STRING = "\x00$VER: Notepad 1.0 (06.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

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
const ID_FIND_TEXT = 2;
const ID_WITH_TEXT = 3;
const ID_ANY_CASE = 4;
const ID_FIND = 5;
const ID_REPLACE = 6;
const ID_REPLACE_ALL = 7;

// The menus and their items, in the order of `menus` below; a bar counts
// as an item.
const MENU_PROJECT = 0;
const MENU_EDIT = 1;
const MENU_SEARCH = 2;
const MENU_VIEW = 3;

const ITEM_NEW = 0;
const ITEM_OPEN = 1;
const ITEM_SAVE = 2;
const ITEM_SAVE_AS = 3;
const ITEM_QUIT = 5;

const ITEM_UNDO = 0;
const ITEM_REDO = 1;
const ITEM_CUT = 3;
const ITEM_COPY = 4;
const ITEM_PASTE = 5;
const ITEM_SELECT_ALL = 7;

const ITEM_FIND = 0;
const ITEM_FIND_NEXT = 1;
const ITEM_FIND_PREVIOUS = 2;
const ITEM_REPLACE = 3;

const ITEM_WRAP = 0;

fn item(label: [*:0]const u8, key: ?[*:0]const u8) mn.NewMenu {
    return .{ .type = mn.NM_ITEM, .label = label, .comm_key = key };
}

const bar = mn.NewMenu{ .type = mn.NM_ITEM, .label = mn.NM_BARLABEL };

const menus = [_]mn.NewMenu{
    .{ .type = mn.NM_TITLE, .label = "Project" },
    item("New", "N"),
    item("Open...", "O"),
    item("Save", "S"),
    item("Save As...", null),
    bar,
    item("Quit", "Q"),
    .{ .type = mn.NM_TITLE, .label = "Edit" },
    item("Undo", "Z"),
    item("Redo", "Y"),
    bar,
    item("Cut", "X"),
    item("Copy", "C"),
    item("Paste", "V"),
    bar,
    item("Select All", "A"),
    .{ .type = mn.NM_TITLE, .label = "Search" },
    item("Find...", "F"),
    item("Find Next", "G"),
    item("Find Previous", "P"),
    item("Replace...", "R"),
    .{ .type = mn.NM_TITLE, .label = "View" },
    .{ .type = mn.NM_ITEM, .label = "Word Wrap", .comm_key = "W", .flags = mn.CHECKIT | mn.MENUTOGGLE | mn.CHECKED },
    .{},
};

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
    /// The scroll bars in the border; null when they could not be made.
    bars: ?Bars = null,
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
    finder: ?Finder = null,
    search: [search_size:0]u8 = @splat(0),
    with: [search_size:0]u8 = @splat(0),
    any_case: bool = false,

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

    fn command(np: *Notepad, method: classusr.MethodID) void {
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
        const bars = np.bars orelse return;
        const pairs = [_]struct { bar: *Object, total: sdk.utility.Tag, visible: sdk.utility.Tag, top: sdk.utility.Tag }{
            .{ .bar = bars.vert, .total = te.TEXTEDIT_TotalVert, .visible = te.TEXTEDIT_VisibleVert, .top = te.TEXTEDIT_TopVert },
            .{ .bar = bars.horiz, .total = te.TEXTEDIT_TotalHoriz, .visible = te.TEXTEDIT_VisibleHoriz, .top = te.TEXTEDIT_TopHoriz },
        };
        for (pairs) |pair| {
            _ = np.ib.SetGadgetAttrsTagList(pair.bar, np.window, &[_]TagItem{
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

    // --- the menus ----------------------------------------------------------

    /// A menu item picked. False to end.
    fn picked(np: *Notepad, number: u32) bool {
        switch (mn.MENUNUM(number)) {
            MENU_PROJECT => switch (mn.ITEMNUM(number)) {
                ITEM_NEW => if (np.mayLeave()) {
                    np.setText("", 0);
                    np.path[0] = 0;
                    np.showTitle();
                },
                ITEM_OPEN => if (np.mayLeave()) {
                    var name: [path_size:0]u8 = undefined;
                    if (np.askFile("Open a text", false, &name)) _ = np.load(&name, false);
                },
                ITEM_SAVE => _ = np.saveKept(),
                ITEM_SAVE_AS => _ = np.saveAs(),
                ITEM_QUIT => return !np.mayLeave(),
                else => {},
            },
            MENU_EDIT => switch (mn.ITEMNUM(number)) {
                ITEM_UNDO => np.command(te.TEM_UNDO),
                ITEM_REDO => np.command(te.TEM_REDO),
                ITEM_CUT => np.cut(),
                ITEM_COPY => np.copy(),
                ITEM_PASTE => np.paste(),
                ITEM_SELECT_ALL => np.command(te.TEM_SELECTALL),
                else => {},
            },
            MENU_SEARCH => switch (mn.ITEMNUM(number)) {
                ITEM_FIND, ITEM_REPLACE => {
                    np.openFinder();
                    return true;
                },
                ITEM_FIND_NEXT => if (!np.findAgain(false)) {
                    np.openFinder();
                    return true;
                },
                ITEM_FIND_PREVIOUS => if (!np.findAgain(true)) {
                    np.openFinder();
                    return true;
                },
                else => {},
            },
            MENU_VIEW => if (mn.ITEMNUM(number) == ITEM_WRAP) {
                np.wrap = !np.wrap;
                _ = np.ib.SetGadgetAttrsTagList(np.editor, np.window, &[_]TagItem{ .{ .tag = te.TEXTEDIT_WordWrap, .data = @intFromBool(np.wrap) }, .{} });
                np.followEditor();
            },
            else => {},
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
            const got = np.sys.Wait(main_signal | find_signal | exec.SIGBREAKF_CTRL_C);
            if (got & exec.SIGBREAKF_CTRL_C != 0 and np.mayLeave()) return;
            if (got & find_signal != 0) np.findWindow();
            if (!np.mainWindow()) return;
            np.followChanges();
        }
    }
};

/// The two scroll bars in the border.
const Bars = struct { vert: *Object, horiz: *Object };

/// What a bar tells the text as it is dragged.
const vert_map = [_]TagItem{ .{ .tag = sr.SCROLLER_Top, .data = te.TEXTEDIT_TopVert }, .{} };
const horiz_map = [_]TagItem{ .{ .tag = sr.SCROLLER_Top, .data = te.TEXTEDIT_TopHoriz }, .{} };

fn windowAttr(ib: *IntuitionBase, window: *Window, attr: sdk.utility.Tag) isize {
    var value: usize = 0;
    const wanted = [_]TagItem{ .{ .tag = attr, .data = @intFromPtr(&value) }, .{} };
    ib.GetWindowAttrs(window, &wanted);
    return @bitCast(value);
}

/// A bar down the right border and one along the bottom one, each from the
/// window's edge to the sizing gadget in the corner, joined to the text;
/// made once the window is open and how deep its borders are is known.
fn makeBars(ib: *IntuitionBase, window: *Window, editor: *Object) ?Bars {
    const left = windowAttr(ib, window, wn.WA_BorderLeft);
    const top = windowAttr(ib, window, wn.WA_BorderTop);
    const right = windowAttr(ib, window, wn.WA_BorderRight);
    const bottom = windowAttr(ib, window, wn.WA_BorderBottom);
    const vert = ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_VERT },
        .{ .tag = gc.GA_RightBorder, .data = 1 },
        .{ .tag = gc.GA_RelRight, .data = @bitCast(-(right - 1)) },
        .{ .tag = gc.GA_Top, .data = @bitCast(top) },
        .{ .tag = gc.GA_Width, .data = @bitCast(right) },
        .{ .tag = gc.GA_RelHeight, .data = @bitCast(-(top + bottom)) },
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEVERT },
        .{ .tag = sr.SCROLLER_Arrows, .data = @bitCast(bottom) },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(editor) },
        .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&vert_map) },
        .{},
    }) orelse return null;
    const horiz = ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_HORIZ },
        .{ .tag = gc.GA_BottomBorder, .data = 1 },
        .{ .tag = gc.GA_Left, .data = @bitCast(left) },
        .{ .tag = gc.GA_RelBottom, .data = @bitCast(-(bottom - 1)) },
        .{ .tag = gc.GA_RelWidth, .data = @bitCast(-(left + right)) },
        .{ .tag = gc.GA_Height, .data = @bitCast(bottom) },
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEHORIZ },
        .{ .tag = sr.SCROLLER_Arrows, .data = @bitCast(@divTrunc(bottom * 16, 11)) },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(editor) },
        .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&horiz_map) },
        .{},
    }) orelse {
        ib.DisposeObject(vert);
        return null;
    };
    _ = ib.AddGList(window, vert, -1, 1);
    _ = ib.AddGList(window, horiz, -1, 1);
    // A bar keeps at least its arrows and as much again.
    _ = ib.WindowLimits(window, left + right + 4 * bottom, top + bottom + 4 * right, -1, -1);
    ib.RefreshWindowFrame(window);
    return .{ .vert = vert, .horiz = horiz };
}

fn button(ib: *IntuitionBase, label: [*:0]const u8, id: u32) ?*Object {
    return ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr(label) },
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    });
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
    const scroller_lib = sys.OpenLibrary(sr.SCROLLER_LIBRARY, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{@as([*:0]const u8, sr.SCROLLER_LIBRARY)});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(scroller_lib);

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
        .{ .tag = te.TEXTEDIT_Scrollers, .data = 0 },
        .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Margin, .data = 2 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(editor) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 1 },
        .{},
    }) orelse {
        ib.DisposeObject(editor);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Notepad") },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_InnerWidth, .data = 600 },
        .{ .tag = wn.WA_InnerHeight, .data = 380 },
        .{ .tag = wn.WA_AutoAdjust, .data = 1 },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_SizeBRight, .data = 1 },
        .{ .tag = wn.WA_SizeBBottom, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_IDCMPUPDATE | wn.IDCMP_NEWSIZE },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(layout) },
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
    // The bars are Notepad's, not the window object's: the window is
    // closed first, which takes them out of it, and then they go.
    const bars = makeBars(ib, window, editor);
    defer {
        var shut = wc.WmClose{};
        _ = ib.SendMessage(object, @ptrCast(&shut));
        if (bars) |made| {
            ib.DisposeObject(made.vert);
            ib.DisposeObject(made.horiz);
        }
    }

    // The menus; a program without them still edits, so a strip that will
    // not go on is left off rather than given up over.
    const strip = blk: {
        const made = ib.CreateMenusA(&menus, null) orelse break :blk null;
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

    var np = Notepad{ .sys = sys, .dl = dl, .ib = ib, .screen = screen, .object = object, .window = window, .editor = editor, .bars = bars };
    defer np.deinit();
    if (dos.rdargs.string(argv[0])) |name| {
        // A name that is not there yet is where the text will be saved.
        if (!np.load(name, true)) np.keepPath(name);
    }
    np.showTitle();
    np.followEditor();
    np.run();
    return dos.RETURN_OK;
}
