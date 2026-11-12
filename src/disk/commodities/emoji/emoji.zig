// SPDX-License-Identifier: MIT
//! Emoji: a window to pick an emoji from, which is typed into the window
//! that was being worked in. Built against the SDK only.
//!
//!   Emoji CX_PRIORITY/K/N,CX_POPKEY/K,CX_POPUP/K
//!
//! Its window (CX_POPKEY, "ctrl alt e" unless given; CX_POPUP=NO to start
//! without it) shows the emoji of `LOCALE:Emoji/emoji.list` as a grid,
//! a group at a time: a row of tabs picks the group, and the first tab
//! holds the ones used last, the newest first. Typing into the line
//! above them searches instead - every word typed must be part of an
//! emoji's name or of one of the words it is found by, in the first of
//! the locale's languages that `LOCALE:Emoji` has names in, and in
//! English for what that language does not name. Return types the first
//! one found; a press on a tab ends the search.
//!
//! A press on an emoji shows its name below the grid, and letting go
//! over it types it: into the window that had the keyboard before this
//! one took it, which gets the keyboard back first, and with it the
//! gadget that was being typed into (`ReturnActivation`). The emoji goes
//! as one character event for each of its code points
//! (IECLASS_CHARACTER), so it arrives wherever typing would: in a text
//! or string gadget, a console, a program reading characters. With no
//! such window, or one that has closed since, the screen flashes and
//! nothing is typed. The window stays open for the next one.
//!
//! The chooser at the bottom is the skin tone the emoji that have tones
//! are shown and typed in. It and the ones used last are kept in
//! ENV:Sys/emoji.used and ENVARC:Sys/emoji.used, written when the window
//! is put away and when the program ends.
//!
//! The emoji are drawn as text in the screen's font, opened larger: what
//! each one looks like is whatever the fonts draw for its characters.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const utility = sdk.utility;
const utf8 = sdk.utility.utf8;
const graphics = sdk.graphics;
const diskfont = sdk.diskfont;
const locale = sdk.locale;
const emoji = sdk.emoji;
const intuition = sdk.intuition;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const sc = intuition.screens;
const pg = intuition.propgclass;
const icc = intuition.icclass;
const classusr = intuition.classusr;
const cv = sdk.gadgets.canvas;
const sr = sdk.gadgets.scroller;
const st = sdk.gadgets.string;
const ct = sdk.gadgets.clicktab;
const cy = sdk.gadgets.cycle;
const tx = sdk.gadgets.text;
const cx = sdk.commodities;
const ie = sdk.devices.inputevent;
const prefs = sdk.prefs;
const frame = @import("commodity");
const picker = @import("picker.zig");
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const LocaleBase = sdk.interface.locale.LocaleBase;
const CxBase = sdk.interface.commodities.CxBase;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Emoji";
const VERSION = "1.0";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (12.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const template = "CX_PRIORITY/K/N,CX_POPKEY/K,CX_POPUP/K";
const arg_standard = 0;

const default_popkey = "ctrl alt e";
const popkey_id = 1;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOMEMORY = "No memory\n";
const MSG_BADPOPKEY = "Not a hotkey: %s\n";
const MSG_NOLIST = "No emoji in %s\n";

const TEXT_USED = "Used last";
const TEXT_NONE_USED = "None used yet";
const TEXT_NOT_FOUND = "None found";

/// The language whose names fill in what the locale's leaves.
const ENGLISH = "english";

const ID_SEARCH = 1;
const ID_TABS = 2;
const ID_GRID = 3;
const ID_BAR = 4;
const ID_TONE = 5;

/// How many rows high the emoji are drawn, and the room around one in
/// its cell.
const emoji_rows = 24;
const cell_room = 12;
/// The grid the window opens with.
const start_columns = 10;
const start_lines = 6;
/// How many grid lines a notch of the wheel moves.
const wheel_lines = 1;

const search_len = 64;
const line_len = 160;
const label_len = 48;
/// The most code points an emoji is typed as.
const most_chars = 16;

/// The tab of the ones used last: the clock at three.
const used_label = "\u{1F552}";

const tone_labels = [_:null]?[*:0]const u8{
    "No tone",
    "Light",
    "Medium-light",
    "Medium",
    "Medium-dark",
    "Dark",
};

/// The window's gadgets and what it stands on, while it is shown.
const Shown = struct {
    screen: *intuition.Screen,
    draw_info: *sc.DrawInfo,
    object: *Object,
    window: *intuition.Window,
    search: *Object,
    tabs: *Object,
    canvas: *Object,
    bar: *Object,
    name: *Object,
    tone: *Object,
    /// The font the emoji are drawn in, when a larger one than the
    /// screen's could be opened.
    font: ?*graphics.TextFont,
    /// The canvas's picture and what is drawn into it.
    rp: *graphics.RastPort,
    width: i32 = 0,
    height: i32 = 0,
    font_height: i32 = 16,
    baseline: i32 = 12,
    grid: picker.Grid,
};

/// Where the window was and how big, when it was last hidden.
const Place = struct { left: usize = 0, top: usize = 0, width: usize = 0, height: usize = 0 };

const App = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ub: *UtilityBase,
    ib: *IntuitionBase,
    gb: *GraphicsBase,
    cb: *CxBase,
    dfb: ?*DiskfontBase,
    book: picker.Book,
    used: picker.Used,
    /// The ones used last or the tone are not what the file says.
    used_changed: bool,
    /// The tab shown: 0 the ones used last, then the groups.
    tab: u32,
    query: picker.Query,
    /// The entries the grid shows, in order.
    view: []u32,
    view_count: u32,
    /// The grid line at the top of the canvas.
    top: u32,
    /// The cell of the view a press is on.
    pressed: ?u32,
    shown: ?Shown,
    place: ?Place,
    /// The tabs' labels: the ones used last, then each group's first
    /// emoji.
    labels: [picker.MOST_GROUPS + 2]?[*:0]const u8,
    label_text: [picker.MOST_GROUPS + 1][label_len:0]u8,
    /// The line below the grid.
    line: [line_len:0]u8,
    file: [picker.USED_ROOM]u8,
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [3]usize = @splat(0);
    var settings = frame.Settings.read(sys, dl, COMMAND_NAME, template, &argv) orelse return dos.RETURN_FAIL;
    defer settings.done();
    var standard: frame.Asked = .{};
    frame.copyText(&standard.popkey, default_popkey);
    settings.standard(&standard, arg_standard);

    const names = [_][*:0]const u8{
        sdk.interface.utility.NAME, intuition.INTUITIONNAME, graphics.GRAPHICSNAME, cx.COMMODITIESNAME,
        cv.CANVAS_LIBRARY,          sr.SCROLLER_LIBRARY,     st.STRING_LIBRARY,     ct.CLICKTAB_LIBRARY,
        cy.CYCLE_LIBRARY,           tx.TEXT_LIBRARY,
    };
    var libraries: [names.len]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    for (names, 0..) |name, i| {
        libraries[i] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{name});
            return dos.RETURN_FAIL;
        };
    }
    // Without diskfont.library the emoji are as high as the screen's
    // font; without locale.library their names are the English ones.
    const diskfont_lib = sys.OpenLibrary(diskfont.DISKFONTNAME, 0);
    defer sys.CloseLibrary(diskfont_lib);
    const locale_lib = sys.OpenLibrary(locale.LOCALENAME, 0);
    defer sys.CloseLibrary(locale_lib);

    // The list, and the room for its emoji.
    const list = prefs.loadWhole(sys, dl, emoji.LIST_FILE) orelse {
        _ = Printf(dl, MSG_NOLIST, .{@as([*:0]const u8, emoji.LIST_FILE)});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(list.ptr);
    const listed = if (emoji.List.open(list)) |opened| opened.emoji else 0;
    if (listed == 0) {
        _ = Printf(dl, MSG_NOLIST, .{@as([*:0]const u8, emoji.LIST_FILE)});
        return dos.RETURN_FAIL;
    }
    const entries_memory = sys.AllocVec(listed * @sizeOf(picker.Entry), exec.MEMF_ANY) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(entries_memory);
    const entries: [*]picker.Entry = @ptrCast(@alignCast(entries_memory));
    const view_memory = sys.AllocVec(listed * @sizeOf(u32), exec.MEMF_ANY) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(view_memory);
    const view: [*]u32 = @ptrCast(@alignCast(view_memory));

    // More than a shell's stack holds: allocated, cleared, and every
    // field that is not zero set by hand.
    const memory = sys.AllocVec(@sizeOf(App), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const app: *App = @ptrCast(@alignCast(memory));
    app.sys = sys;
    app.dl = dl;
    app.ub = @ptrCast(libraries[0].?);
    app.ib = @ptrCast(libraries[1].?);
    app.gb = @ptrCast(libraries[2].?);
    app.cb = @ptrCast(libraries[3].?);
    app.dfb = if (diskfont_lib) |lib| @ptrCast(lib) else null;
    app.book = .{ .entries = entries[0..listed] };
    app.used = .{};
    app.used_changed = false;
    app.query = .{};
    app.view = view[0..listed];
    app.pressed = null;
    app.shown = null;
    app.place = null;
    app.labels = @splat(null);
    const cb = app.cb;

    if (!app.book.read(list) or app.book.count == 0) {
        _ = Printf(dl, MSG_NOLIST, .{@as([*:0]const u8, emoji.LIST_FILE)});
        return dos.RETURN_FAIL;
    }
    // The names, which the entries point into for as long as they are.
    var name_files: [2]?[]u8 = @splat(null);
    defer for (name_files) |held| {
        if (held) |bytes| sys.FreeVec(bytes.ptr);
    };
    loadNames(app, if (locale_lib) |lib| @ptrCast(lib) else null, &name_files);
    loadUsed(app);
    makeLabels(app);

    const popkey: [*:0]const u8 = &standard.popkey;
    var check: cx.InputXpression = .{};
    if (cb.ParseIX(popkey, &check) != 0) {
        _ = Printf(dl, MSG_BADPOPKEY, .{popkey});
        return dos.RETURN_ERROR;
    }

    const commodity = frame.Commodity.open(sys, cb, .{
        .name = COMMAND_NAME,
        .title = "Emoji",
        .descr = "Picks an emoji and types it",
        .unique = cx.NBU_UNIQUE | cx.NBU_NOTIFY,
        .flags = cx.COF_SHOW_HIDE,
        .pri = standard.priority,
    }) catch |err| {
        // A second Emoji: the first was told, and shows its window.
        if (err == error.Duplicate) return dos.RETURN_OK;
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer commodity.close();
    if (!commodity.attach(cx.HotKey(cb, popkey, commodity.port, popkey_id))) {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }
    commodity.activate(true);

    defer hide(app);
    if (standard.popup) show(app);

    while (true) {
        const window_mask = if (app.shown) |shown| windowSignal(app.ib, shown.object) else 0;
        const got = sys.Wait(commodity.signals() | window_mask);
        if (frame.Commodity.stopped(got)) break;
        while (commodity.next()) |event| switch (event) {
            .end => return dos.RETURN_OK,
            .input => |in| {
                if (in.id == popkey_id) show(app);
            },
            .show => show(app),
            .hide => hide(app),
            .disabled, .enabled, .list_changed => {},
        };
        windowMessages(app);
    }
    return dos.RETURN_OK;
}

// --- what is read as it starts -------------------------------------------------------

/// The names of the first of the locale's languages that has a file, and
/// the English ones for what that left without. The files stay in
/// `files`, the caller's to free.
fn loadNames(app: *App, lb: ?*LocaleBase, files: *[2]?[]u8) void {
    var path: [96]u8 = undefined;
    var english_read = false;
    if (lb) |locales| {
        if (locales.OpenLocale(null)) |loc| {
            defer locales.CloseLocale(loc);
            for (loc.pref_languages) |language| {
                const words = span(language orelse break);
                const file = emoji.namesPath(&path, words) orelse continue;
                const bytes = prefs.loadWhole(app.sys, app.dl, file) orelse continue;
                files[0] = bytes;
                _ = app.book.name(bytes);
                english_read = same(words, ENGLISH);
                break;
            }
        }
    }
    if (english_read) return;
    const file = emoji.namesPath(&path, ENGLISH) orelse return;
    const bytes = prefs.loadWhole(app.sys, app.dl, file) orelse return;
    files[1] = bytes;
    _ = app.book.name(bytes);
}

/// The ones used last and the tone, from ENV:Sys/emoji.used, or from
/// ENVARC: when there is none there yet.
fn loadUsed(app: *App) void {
    const sys = app.sys;
    const text = prefs.loadWhole(sys, app.dl, picker.USED_ENV) orelse
        prefs.loadWhole(sys, app.dl, picker.USED_ENVARC) orelse return;
    defer sys.FreeVec(text.ptr);
    _ = app.used.read(&app.book, text);
}

/// The same written back, when something changed.
fn saveUsed(app: *App) void {
    if (!app.used_changed) return;
    const length = app.used.write(&app.book, &app.file);
    if (length == 0) return;
    const wrote = prefs.save(app.dl, picker.USED_ENV, app.file[0..length]);
    const kept = prefs.save(app.dl, picker.USED_ENVARC, app.file[0..length]);
    if (wrote and kept) app.used_changed = false;
}

/// A label for each tab: the clock for the ones used last, and for a
/// group the first of its emoji.
fn makeLabels(app: *App) void {
    copySlice(&app.label_text[0], used_label);
    app.labels[0] = &app.label_text[0];
    var which: u32 = 0;
    while (which < app.book.group_count) : (which += 1) {
        const group = app.book.groups[which];
        const text = if (group.count != 0) app.book.entries[group.first].emoji.text else "-";
        copySlice(&app.label_text[which + 1], if (text.len < label_len) text else "-");
        app.labels[which + 1] = &app.label_text[which + 1];
    }
    app.labels[app.book.group_count + 1] = null;
}

// --- what the grid shows -------------------------------------------------------------

/// The view filled again: what the search finds while there is one, or
/// the tab's emoji; shown from its top, with a word about it below.
fn refill(app: *App) void {
    if (!app.query.empty()) {
        app.view_count = app.book.search(app.ub, &app.query, app.view);
        say(app, if (app.view_count != 0) app.book.entries[app.view[0]].name else TEXT_NOT_FOUND);
    } else if (app.tab == 0) {
        app.view_count = app.used.count;
        @memcpy(app.view[0..app.used.count], app.used.items[0..app.used.count]);
        say(app, if (app.view_count != 0) TEXT_USED else TEXT_NONE_USED);
    } else {
        app.view_count = app.book.group(app.tab - 1, app.view);
        say(app, app.book.groups[app.tab - 1].name);
    }
    app.top = 0;
    app.pressed = null;
    setBar(app);
    draw(app);
}

/// The line below the grid.
fn say(app: *App, text: []const u8) void {
    const shown = app.shown orelse return;
    copySlice(&app.line, text);
    _ = app.ib.SetGadgetAttrsTagList(shown.name, shown.window, &[_]TagItem{
        pair(tx.TEXT_Text, @intFromPtr(&app.line)),
        .{},
    });
}

/// The scroll bar told what the grid shows of the view.
fn setBar(app: *App) void {
    const shown = app.shown orelse return;
    _ = app.ib.SetGadgetAttrsTagList(shown.bar, shown.window, &[_]TagItem{
        pair(sr.SCROLLER_Total, @max(shown.grid.lines(app.view_count), 1)),
        pair(sr.SCROLLER_Visible, @max(shown.grid.rows, 1)),
        pair(sr.SCROLLER_Top, app.top),
        .{},
    });
}

/// The grid moved to line `top`, as far as there are lines.
fn scrollTo(app: *App, top: i64) void {
    const shown = app.shown orelse return;
    const last: i64 = shown.grid.lastTop(app.view_count);
    const line: u32 = @intCast(@max(@min(top, last), 0));
    if (line == app.top) return;
    app.top = line;
    draw(app);
}

/// The emoji as it is typed and shown: in the tone chosen, where it has
/// tones.
fn textOf(app: *const App, entry: u32) []const u8 {
    return app.book.entries[entry].emoji.toned(app.used.tone);
}

/// The grid drawn: the ground, the cell under a press in the fill
/// colour, and each emoji in the middle of its cell.
fn draw(app: *App) void {
    const shown = app.shown orelse return;
    const gb = app.gb;
    const rp = shown.rp;
    const grid = shown.grid;
    const cell: i32 = @intCast(grid.cell);
    setPen(gb, rp, shown.draw_info.pens[sc.BACKGROUNDPEN]);
    gb.RectFill(rp, &.{ .max_x = shown.width, .max_y = shown.height });

    var which: u32 = app.top * grid.columns;
    const end: u32 = @min(app.view_count, (app.top + grid.drawn) * grid.columns);
    while (which < end) : (which += 1) {
        const place = grid.place(which, app.top) orelse continue;
        if (app.pressed == which) {
            setPen(gb, rp, shown.draw_info.pens[sc.FILLPEN]);
            gb.RectFill(rp, &.{ .min_x = place.x + 1, .min_y = place.y + 1, .max_x = place.x + cell - 1, .max_y = place.y + cell - 1 });
        }
        const text = textOf(app, app.view[which]);
        const count: u32 = @intCast(text.len);
        const wide = gb.TextLength(rp, text.ptr, count);
        setPen(gb, rp, shown.draw_info.pens[sc.TEXTPEN]);
        gb.Move(rp, place.x + @divTrunc(cell - wide, 2), place.y + @divTrunc(cell - shown.font_height, 2) + shown.baseline);
        gb.Text(rp, text.ptr, count);
    }
    app.ib.QueueGadgetRefresh(shown.canvas);
}

/// The canvas's picture made as big as its box, and the grid that fits.
fn fit(app: *App) void {
    const ib = app.ib;
    const shown = if (app.shown) |*held| held else return;
    _ = ib.SetGadgetAttrsTagList(shown.canvas, shown.window, &[_]TagItem{
        pair(cv.CANVAS_Width, 0),
        pair(cv.CANVAS_Height, 0),
        .{},
    });
    var value: usize = 0;
    _ = ib.GetAttr(cv.CANVAS_RastPort, shown.canvas, &value);
    shown.rp = @ptrFromInt(value);
    _ = ib.GetAttr(cv.CANVAS_Width, shown.canvas, &value);
    shown.width = @intCast(value);
    _ = ib.GetAttr(cv.CANVAS_Height, shown.canvas, &value);
    shown.height = @intCast(value);
    if (shown.font orelse shown.draw_info.font) |font| graphics.SetFont(app.gb, shown.rp, font);
    shown.font_height = @max(rpAttr(app.gb, shown.rp, graphics.RPTAG_FontHeight), 8);
    shown.baseline = rpAttr(app.gb, shown.rp, graphics.RPTAG_FontBaseline);
    const cell: u32 = @intCast(shown.font_height + cell_room);
    shown.grid = picker.Grid.init(@intCast(@max(shown.width, 1)), @intCast(@max(shown.height, 1)), cell);
    app.top = @min(app.top, shown.grid.lastTop(app.view_count));
}

fn rpAttr(gb: *GraphicsBase, rp: *graphics.RastPort, attr: utility.Tag) i32 {
    var value: u32 = 0;
    gb.GetRPAttrs(rp, &[_]TagItem{ pair(attr, @intFromPtr(&value)), .{} });
    return @intCast(value);
}

fn setPen(gb: *GraphicsBase, rp: *graphics.RastPort, pen: graphics.Pen) void {
    gb.SetRPAttrs(rp, &[_]TagItem{ pair(graphics.RPTAG_APen, pen), .{} });
}

// --- a choice ------------------------------------------------------------------------

/// The cell of the view the pointer is over, or null beside them all.
fn cellUnderPointer(app: *App) ?u32 {
    const shown = app.shown orelse return null;
    var x: usize = 0;
    var y: usize = 0;
    _ = app.ib.GetAttr(cv.CANVAS_X, shown.canvas, &x);
    _ = app.ib.GetAttr(cv.CANVAS_Y, shown.canvas, &y);
    const left: i32 = @truncate(@as(isize, @bitCast(x)));
    const down: i32 = @truncate(@as(isize, @bitCast(y)));
    return shown.grid.at(left, down, app.top, app.view_count);
}

/// A press on the grid: the emoji under it named, its cell marked.
fn press(app: *App) void {
    app.pressed = cellUnderPointer(app);
    if (app.pressed) |cell| say(app, app.book.entries[app.view[cell]].name);
    draw(app);
}

/// The press let go: over the cell it began on, that emoji is typed.
fn release(app: *App) void {
    const cell = app.pressed orelse return;
    app.pressed = null;
    if (cellUnderPointer(app) == cell) choose(app, app.view[cell]);
    draw(app);
}

/// An emoji typed into the window worked in before this one, and put
/// first among the ones used last; the screen flashed when there is no
/// such window.
fn choose(app: *App, entry: u32) void {
    const shown = app.shown orelse return;
    if (!typeFrom(app, shown.window, textOf(app, entry))) {
        app.ib.DisplayBeep(null);
        return;
    }
    if (app.used.use(entry)) app.used_changed = true;
}

/// `text` typed into the window `window` took the keyboard from, which
/// is given it back first: a character event for each code point, into
/// the network, from where they go on down the input chain as typing
/// does. False when there is no such window any more, or the text is
/// more than an emoji.
fn typeFrom(app: *App, window: *intuition.Window, text: []const u8) bool {
    var events: [most_chars]ie.InputEvent = undefined;
    var count: usize = 0;
    var rest = text;
    while (rest.len != 0) : (count += 1) {
        if (count == events.len) return false;
        const got = utf8.read(rest);
        events[count] = .{ .class = ie.IECLASS_CHARACTER, .code = got.char };
        rest = rest[got.length..];
    }
    if (count == 0) return false;
    var linked: usize = 0;
    while (linked + 1 < count) : (linked += 1) events[linked].next = &events[linked + 1];
    if (!app.ib.ReturnActivation(window)) return false;
    app.cb.AddIEvents(&events[0]);
    return true;
}

// --- the window ----------------------------------------------------------------------

/// The window shown, or brought forward when it is; the line to search
/// in takes the keyboard.
fn show(app: *App) void {
    const ib = app.ib;
    if (app.shown) |shown| {
        ib.WindowToFront(shown.window);
        ib.ActivateWindow(shown.window);
        _ = ib.ActivateGadget(shown.search, shown.window, null);
        return;
    }
    const screen = ib.LockPubScreen(null) orelse return;
    app.shown = build(app, screen) orelse {
        ib.UnlockPubScreen(null, screen);
        return;
    };
    app.query = .{};
    app.tab = if (app.used.count != 0) 0 else 1;
    const shown = app.shown.?;
    _ = ib.SetGadgetAttrsTagList(shown.tabs, shown.window, &[_]TagItem{ pair(ct.CLICKTAB_Current, app.tab), .{} });
    fit(app);
    refill(app);
    _ = ib.ActivateGadget(shown.search, shown.window, null);
}

/// The window hidden: where it was kept, the ones used last written, and
/// it and its gadgets gone.
fn hide(app: *App) void {
    const ib = app.ib;
    saveUsed(app);
    const shown = app.shown orelse return;
    var place: Place = .{};
    ib.GetWindowAttrs(shown.window, &[_]TagItem{
        pair(wn.WA_Left, @intFromPtr(&place.left)),
        pair(wn.WA_Top, @intFromPtr(&place.top)),
        pair(wn.WA_Width, @intFromPtr(&place.width)),
        pair(wn.WA_Height, @intFromPtr(&place.height)),
        .{},
    });
    app.place = place;
    // The window object takes the layout and every gadget in it along.
    ib.DisposeObject(shown.object);
    if (shown.font) |font| app.gb.CloseFont(font);
    ib.FreeScreenDrawInfo(shown.screen, shown.draw_info);
    ib.UnlockPubScreen(null, shown.screen);
    app.shown = null;
}

/// The screen's font `emoji_rows` high, from diskfont.library; null
/// without it.
fn largeFont(app: *App) ?*graphics.TextFont {
    const fonts = app.dfb orelse return null;
    const system = app.ib.OpenSystemFont(sc.SYSFONT_DEFAULT) orelse return null;
    defer app.gb.CloseFont(system);
    const name = system.node.name orelse return null;
    return fonts.OpenDiskFont(&.{ .name = name, .y_size = emoji_rows });
}

/// The window's gadgets, the window made with them and opened.
fn build(app: *App, screen: *intuition.Screen) ?Shown {
    const ib = app.ib;
    const draw_info = ib.GetScreenDrawInfo(screen);
    const font = largeFont(app);
    const cell: usize = cell_room + @as(usize, if (font != null) emoji_rows else 16);

    const search = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_SEARCH),
        pair(gc.GA_RelVerify, 1),
        pair(gc.STRINGA_MaxChars, search_len),
        pair(icc.ICA_TARGET, icc.ICTARGET_IDCMP),
        .{},
    });
    const tabs = ib.NewObjectTagList(null, ct.CLICKTAB_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_TABS),
        pair(gc.GA_RelVerify, 1),
        pair(ct.CLICKTAB_Labels, @intFromPtr(&app.labels)),
        .{},
    });
    const canvas = ib.NewObjectTagList(null, cv.CANVAS_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_GRID),
        pair(gc.GA_Immediate, 1),
        pair(gc.GA_RelVerify, 1),
        pair(cv.CANVAS_Width, start_columns * cell),
        pair(cv.CANVAS_Height, start_lines * cell),
        pair(icc.ICA_TARGET, icc.ICTARGET_IDCMP),
        .{},
    });
    const bar = ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_BAR),
        pair(gc.GA_RelVerify, 1),
        pair(pg.PGA_Freedom, pg.FREEVERT),
        pair(sr.SCROLLER_Total, 1),
        pair(sr.SCROLLER_Visible, 1),
        pair(sr.SCROLLER_Arrows, 16),
        pair(icc.ICA_TARGET, icc.ICTARGET_IDCMP),
        .{},
    });
    app.line[0] = 0;
    const name = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        pair(tx.TEXT_Text, @intFromPtr(&app.line)),
        pair(tx.TEXT_Clipped, 1),
        .{},
    });
    const tone = ib.NewObjectTagList(null, cy.CYCLE_CLASS, &[_]TagItem{
        pair(gc.GA_ID, ID_TONE),
        pair(gc.GA_RelVerify, 1),
        pair(cy.CYCLE_Labels, @intFromPtr(&tone_labels)),
        pair(cy.CYCLE_Active, if (app.used.tone) |which| which + 1 else 0),
        .{},
    });

    const middle = if (canvas != null and bar != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 2),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(canvas)),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(bar)),
        pair(lg.CHILDA_WeightWidth, 0),
        .{},
    }) else null;
    const bottom = if (name != null and tone != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_HORIZ),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(name)),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(tone)),
        pair(lg.CHILDA_WeightWidth, 0),
        .{},
    }) else null;
    const layout = if (search != null and tabs != null and middle != null and bottom != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 4),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(search)),
        pair(lg.CHILDA_Label, @intFromPtr("Search")),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(tabs)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(middle)),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(bottom)),
        pair(lg.CHILDA_WeightHeight, 0),
        .{},
    }) else null;
    const made = layout orelse {
        // What a layout took is its own; only what none took goes here.
        if (middle == null) {
            ib.DisposeObject(canvas);
            ib.DisposeObject(bar);
        }
        if (bottom == null) {
            ib.DisposeObject(name);
            ib.DisposeObject(tone);
        }
        ib.DisposeObject(search);
        ib.DisposeObject(tabs);
        ib.DisposeObject(middle);
        ib.DisposeObject(bottom);
        if (font) |opened| app.gb.CloseFont(opened);
        ib.FreeScreenDrawInfo(screen, draw_info);
        return null;
    };

    const place = app.place;
    const put = place orelse Place{};
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr(COMMAND_NAME)),
        pair(wn.WA_ScreenTitle, @intFromPtr(SCREEN_TITLE)),
        pair(wn.WA_PubScreen, @intFromPtr(screen)),
        pair(if (place != null) wn.WA_Left else utility.TAG_IGNORE, put.left),
        pair(if (place != null) wn.WA_Top else utility.TAG_IGNORE, put.top),
        pair(if (place != null) wn.WA_Width else utility.TAG_IGNORE, put.width),
        pair(if (place != null) wn.WA_Height else utility.TAG_IGNORE, put.height),
        pair(wn.WA_AutoAdjust, 1),
        pair(wn.WA_CloseGadget, 1),
        pair(wn.WA_DragBar, 1),
        pair(wn.WA_DepthGadget, 1),
        pair(wn.WA_SizeGadget, 1),
        pair(wn.WA_Activate, 1),
        pair(wn.WA_IDCMP, wn.IDCMP_IDCMPUPDATE | wn.IDCMP_NEWSIZE | wn.IDCMP_MOUSEWHEEL),
        pair(wc.WINDOWA_Layout, @intFromPtr(made)),
        .{},
    });
    var open = wc.WmOpen{};
    const opened = if (object) |window_object| ib.SendMessage(window_object, @ptrCast(&open)) else 0;
    if (opened == 0) {
        if (object) |window_object| ib.DisposeObject(window_object) else ib.DisposeObject(made);
        if (font) |held| app.gb.CloseFont(held);
        ib.FreeScreenDrawInfo(screen, draw_info);
        return null;
    }
    const window: *intuition.Window = @ptrFromInt(opened);
    var rp: usize = 0;
    _ = ib.GetAttr(cv.CANVAS_RastPort, canvas.?, &rp);
    return .{
        .screen = screen,
        .draw_info = draw_info,
        .object = object.?,
        .window = window,
        .search = search.?,
        .tabs = tabs.?,
        .canvas = canvas.?,
        .bar = bar.?,
        .name = name.?,
        .tone = tone.?,
        .font = font,
        .rp = @ptrFromInt(rp),
        .grid = picker.Grid.init(1, 1, @intCast(cell)),
    };
}

/// Every message the window has, worked.
fn windowMessages(app: *App) void {
    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    while (app.shown) |shown| {
        const ib = app.ib;
        const word = ib.SendMessage(shown.object, @ptrCast(&handle));
        if (word == wc.WMHI_LASTMSG) return;
        var gadget: usize = wc.WINDOW_NOGADGET;
        _ = ib.GetAttr(wc.WINDOWA_GadgetID, shown.object, &gadget);
        switch (word & wc.WMHI_CLASSMASK) {
            // Closing hides: the window and whatever else it had go.
            wc.WMHI_CLOSEWINDOW => hide(app),
            wc.WMHI_GADGETDOWN => if (word & wc.WMHI_GADGETMASK == ID_GRID) press(app),
            wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                ID_GRID => release(app),
                ID_BAR => scrollTo(app, code),
                ID_TABS => {
                    // A group picked ends a search.
                    app.tab = @min(code, app.book.group_count);
                    app.query = .{};
                    _ = ib.SetGadgetAttrsTagList(shown.search, shown.window, &[_]TagItem{
                        pair(gc.STRINGA_TextVal, @intFromPtr("")),
                        .{},
                    });
                    refill(app);
                },
                // Return in the search line: the first one found.
                ID_SEARCH => if (!app.query.empty() and app.view_count != 0) choose(app, app.view[0]),
                ID_TONE => {
                    const tone: ?u32 = if (code == 0 or code > emoji.TONES) null else code - 1;
                    if (tone != app.used.tone) {
                        app.used.tone = tone;
                        app.used_changed = true;
                        draw(app);
                    }
                },
                else => {},
            },
            wc.WMHI_IDCMPUPDATE => switch (gadget) {
                ID_BAR => {
                    var top: usize = 0;
                    _ = ib.GetAttr(sr.SCROLLER_Top, shown.bar, &top);
                    scrollTo(app, @intCast(top));
                },
                ID_SEARCH => {
                    var value: usize = 0;
                    _ = ib.GetAttr(gc.STRINGA_TextVal, shown.search, &value);
                    const typed: ?[*:0]const u8 = @ptrFromInt(value);
                    const was_empty = app.query.empty();
                    app.query = picker.Query.init(app.ub, if (typed) |text| span(text) else "");
                    // A line emptied by a tab's press was shown already.
                    if (!(was_empty and app.query.empty())) refill(app);
                },
                else => {},
            },
            wc.WMHI_MOUSEWHEEL => {
                const notches: i16 = @bitCast(@as(u16, @truncate(word & 0xFFFF)));
                scrollTo(app, @as(i64, app.top) + @as(i64, notches) * wheel_lines);
                setBar(app);
            },
            wc.WMHI_NEWSIZE => {
                fit(app);
                setBar(app);
                draw(app);
            },
            else => {},
        }
    }
}

fn windowSignal(ib: *IntuitionBase, object: *Object) u32 {
    var mask: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_SigMask, object, &mask);
    return @truncate(mask);
}

fn pair(tag: utility.Tag, data: usize) TagItem {
    return .{ .tag = tag, .data = data };
}

// --- text ----------------------------------------------------------------------------

/// `text` into `into` with its end of string, cut where it does not fit.
fn copySlice(into: []u8, text: []const u8) void {
    const fits = @min(text.len, into.len - 1);
    @memcpy(into[0..fits], text[0..fits]);
    into[fits] = 0;
}

/// The text of a buffer, up to its end of string.
fn span(buffer: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (buffer[length] != 0) length += 1;
    return buffer[0..length];
}

fn same(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |one, other| {
        if (one != other) return false;
    }
    return true;
}
