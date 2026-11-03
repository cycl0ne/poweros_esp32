// SPDX-License-Identifier: MIT
//! FKey: functions on freely chosen keys. Built against the SDK only.
//!
//!   FKey CX_PRIORITY/K/N,CX_POPKEY/K,CX_POPUP/K
//!
//! Each key is a description - the qualifiers that must be held and the
//! key itself, "ctrl alt f1" - and one of seven things to do with it:
//!
//! - Cycle Windows: the window at the back of the screen in front comes
//!   forward and takes the keyboard.
//! - Cycle Screens: the screen in front goes behind the others.
//! - Enlarge Window, Shrink Window: the active window grown to the room
//!   its screen leaves it, or back to the least it asked for.
//! - Toggle Window: the active window to its other size, as its zoom
//!   gadget does.
//! - Insert Text: the key types the text instead - `\n` a Return, `\t` a
//!   Tab, `<f1>` a key by its description - into whatever window is
//!   active. The text goes in in the network, in place of the key, so it
//!   arrives wherever the key would have.
//! - Run Program: a command line run in a shell of its own.
//!
//! A key that is defined does not reach the windows: the function is
//! what it does now.
//!
//! Its window (CX_POPKEY, "ctrl alt k" unless given; CX_POPUP=NO to start
//! without it) lists the keys. Picking one shows its description, its
//! command and the command's text to the right, where each can be
//! changed; New Key adds one and Delete Key takes the one picked away. A
//! change holds at once, and Project > Save writes the keys to
//! ENV:Sys/fkey.keys and ENVARC:Sys/fkey.keys, which is where they are
//! read from when it starts. Up to 32 keys.
//!
//! Running a script is not here: that needs a script language, which the
//! system has not got. A script file run by a shell is Run Program.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const utility = sdk.utility;
const intuition = sdk.intuition;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const sc = intuition.screens;
const classusr = intuition.classusr;
const menus = intuition.menus;
const lv = sdk.gadgets.listview;
const st = sdk.gadgets.string;
const cy = sdk.gadgets.cycle;
const cx = sdk.commodities;
const ie = sdk.devices.inputevent;
const prefs = sdk.prefs;
const frame = @import("commodity");
const keyform = @import("keys.zig");
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const CxBase = sdk.interface.commodities.CxBase;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "FKey";
const VERSION = "1.1";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (03.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const template = "CX_PRIORITY/K/N,CX_POPKEY/K,CX_POPUP/K";
const arg_standard = 0;

const default_popkey = "ctrl alt k";
/// The hotkey's sender id. A key's own id is its place in the list, from
/// 0, so the hotkey's is past them all.
const popkey_id = 1000;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOMEMORY = "No memory\n";
const MSG_BADPOPKEY = "Not a hotkey: %s\n";
const MSG_BADLINE = "%s line %d: %s\n";

/// How many keys there is room for.
const most_keys = 32;
/// How long a key's description and its text may be.
const description_len = 64;
const args_len = 160;
/// A line of the window's list: the description, the command's name and
/// the text.
const line_len = description_len + args_len + 24;

const ID_LIST = 1;
const ID_NEW = 2;
const ID_DELETE = 3;
const ID_KEY = 4;
const ID_COMMAND = 5;
const ID_ARGS = 6;

/// The Project menu, in this order.
const ITEM_SAVE = 0;
const ITEM_HIDE = 1;
const ITEM_QUIT = 2;

const project_menu = [_]menus.NewMenu{
    .{ .type = menus.NM_TITLE, .label = "Project" },
    .{ .type = menus.NM_ITEM, .label = "Save", .comm_key = "S" },
    .{ .type = menus.NM_ITEM, .label = "Hide", .comm_key = "H" },
    .{ .type = menus.NM_ITEM, .label = "Quit", .comm_key = "Q" },
    .{ .type = menus.NM_END },
};

/// One key: what it is, what it does, and the line the window lists it
/// by, whose node is on the list the listview shows.
const Key = struct {
    node: exec.Node = .{},
    line: [line_len:0]u8 = @splat(0),
    description: [description_len:0]u8 = @splat(0),
    args: [args_len:0]u8 = @splat(0),
    command: keyform.Command = .cycle_windows,
    /// For Insert Text: the events typed in the key's place, read by the
    /// translator in the network, freed when the key changes or goes.
    events: ?*ie.InputEvent = null,
    used: bool = false,
};

/// The window's gadgets and what it stands on, while it is shown.
const Shown = struct {
    screen: *intuition.Screen,
    object: *Object,
    window: *intuition.Window,
    menu: ?*intuition.Menu,
    list: *Object,
    new: *Object,
    delete: *Object,
    key: *Object,
    command: *Object,
    args: *Object,
};

/// Where the window was and how big, when it was last hidden.
const Place = struct { left: usize = 0, top: usize = 0, width: usize = 0, height: usize = 0 };

const App = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ub: *UtilityBase,
    ib: *IntuitionBase,
    cb: *CxBase,
    keys: [most_keys]Key = @splat(.{}),
    /// The lines of the keys in use, in order, for the listview.
    lines: exec.List = .{},
    /// Which key the window shows, or null for none.
    chosen: ?usize = null,
    /// The filter every key's own filter hangs under, so that the lot can
    /// be built again in one go.
    group: ?*cx.CxObj = null,
    shown: ?Shown = null,
    place: ?Place = null,
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
        sdk.interface.utility.NAME, intuition.INTUITIONNAME, cx.COMMODITIESNAME,
        lv.LISTVIEW_LIBRARY,        st.STRING_LIBRARY,       cy.CYCLE_LIBRARY,
    };
    var libraries: [names.len]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    for (names, 0..) |name, i| {
        libraries[i] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{name});
            return dos.RETURN_FAIL;
        };
    }
    // The keys and their lines are more than a shell's stack holds: the
    // whole of it is allocated, cleared, and every field that is not zero
    // set by hand.
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
    app.cb = @ptrCast(libraries[2].?);
    app.chosen = null;
    app.group = null;
    app.shown = null;
    app.place = null;
    const cb = app.cb;
    app.lines.init(.unknown);
    defer forgetEvents(app);

    const popkey: [*:0]const u8 = &standard.popkey;
    var check: cx.InputXpression = .{};
    if (cb.ParseIX(popkey, &check) != 0) {
        _ = Printf(dl, MSG_BADPOPKEY, .{popkey});
        return dos.RETURN_ERROR;
    }

    const commodity = frame.Commodity.open(sys, cb, .{
        .name = COMMAND_NAME,
        .title = "FKey",
        .descr = "Functions on keys",
        .unique = cx.NBU_UNIQUE | cx.NBU_NOTIFY,
        .flags = cx.COF_SHOW_HIDE,
        .pri = standard.priority,
    }) catch |err| {
        // A second FKey: the first was told, and shows its window.
        if (err == error.Duplicate) return dos.RETURN_OK;
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer commodity.close();
    if (!commodity.attach(cx.HotKey(cb, popkey, commodity.port, popkey_id))) {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }

    load(app);
    rebuild(app, commodity);
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
                if (in.id == popkey_id) show(app) else carry(app, in.id);
            },
            .show => show(app),
            .hide => hide(app),
            // Made inactive, the keys reach the windows again; made
            // active they are taken over as they were.
            .disabled, .enabled, .list_changed => {},
        };
        if (!windowMessages(app, commodity)) return dos.RETURN_OK;
    }
    return dos.RETURN_OK;
}

// --- the keys ------------------------------------------------------------------------

/// The keys read from ENV:Sys/fkey.keys, or from ENVARC: when there is
/// none there yet. A line that is not a key is said so and passed over.
fn load(app: *App) void {
    const sys = app.sys;
    const text = prefs.loadWhole(sys, app.dl, keyform.ENV_FILE) orelse
        prefs.loadWhole(sys, app.dl, keyform.ENVARC_FILE) orelse return;
    defer sys.FreeVec(text.ptr);
    const from: [*:0]const u8 = if (prefs.loadWhole(sys, app.dl, keyform.ENV_FILE) != null)
        keyform.ENV_FILE
    else
        keyform.ENVARC_FILE;
    var keys = keyform.Keys.init(app.ub, text);
    while (keys.next()) |key| {
        const at = free(app) orelse break;
        set(app, at, key);
        if (keys.problem) |problem| {
            _ = Printf(app.dl, MSG_BADLINE, .{ from, keys.bad_line, problem });
            keys.problem = null;
        }
    }
    if (keys.problem) |problem| _ = Printf(app.dl, MSG_BADLINE, .{ from, keys.bad_line, problem });
    relist(app);
}

/// The keys written to ENV: and ENVARC:; whether both were written.
fn save(app: *App) bool {
    const room = keyform.header.len + most_keys * (line_len + 24);
    const memory = app.sys.AllocVec(room, exec.MEMF_ANY) orelse return false;
    defer app.sys.FreeVec(memory);
    const bytes: [*]u8 = @ptrCast(memory);
    const text = bytes[0..room];
    var at: usize = keyform.header.len;
    @memcpy(text[0..at], keyform.header);
    for (&app.keys) |*key| {
        if (!key.used) continue;
        const written = keyform.keyLine(.{
            .description = span(&key.description),
            .command = key.command,
            .args = span(&key.args),
        }, text[at..]) orelse continue;
        at += written;
    }
    const whole = text[0..at];
    const in_force = prefs.save(app.dl, keyform.ENV_FILE, whole);
    const kept = prefs.save(app.dl, keyform.ENVARC_FILE, whole);
    return in_force and kept;
}

/// A key not in use, or null when there is no room for another.
fn free(app: *App) ?usize {
    for (&app.keys, 0..) |*key, i| {
        if (!key.used) return i;
    }
    return null;
}

/// One key filled in, with the events an Insert Text key types.
fn set(app: *App, at: usize, from: keyform.Key) void {
    const key = &app.keys[at];
    forget(app, key);
    key.used = true;
    key.command = from.command;
    copySlice(&key.description, from.description);
    copySlice(&key.args, if (keyform.takesArgs(from.command)) from.args else &.{});
    if (key.command == .insert and key.args[0] != 0) {
        key.events = cx.InvertString(app.sys, app.cb, &key.args, null);
    }
    describe(key);
}

/// The line the window lists a key by: "ctrl alt f1  Cycle Windows".
fn describe(key: *Key) void {
    var at: usize = 0;
    const label = keyform.labels[@intFromEnum(key.command)].?;
    for ([_][*:0]const u8{ &key.description, "   ", label }) |part| {
        var i: usize = 0;
        while (part[i] != 0 and at + 1 < key.line.len) : (i += 1) {
            key.line[at] = part[i];
            at += 1;
        }
    }
    if (keyform.takesArgs(key.command) and key.args[0] != 0) {
        for ([_][*:0]const u8{ ": ", &key.args }) |part| {
            var i: usize = 0;
            while (part[i] != 0 and at + 1 < key.line.len) : (i += 1) {
                key.line[at] = part[i];
                at += 1;
            }
        }
    }
    key.line[at] = 0;
    key.node.name = &key.line;
}

/// The events a key typed, given back.
fn forget(app: *App, key: *Key) void {
    if (key.events) |events| cx.FreeIEvents(app.sys, events);
    key.events = null;
}

fn forgetEvents(app: *App) void {
    for (&app.keys) |*key| forget(app, key);
}

/// The list the window shows, made again from the keys in use.
fn relist(app: *App) void {
    app.lines.init(.unknown);
    for (&app.keys) |*key| {
        if (key.used) app.sys.AddTail(&app.lines, &key.node);
    }
}

/// The network built again: a filter for each key, under one filter of
/// their own so that the lot goes in a single call. An Insert Text key is
/// a translator - its events go in where the key was, inside the network;
/// every other key is a sender to this program with the key's place as
/// its id, and a translator with nothing in it, so the key itself goes no
/// further.
fn rebuild(app: *App, commodity: frame.Commodity) void {
    const cb = app.cb;
    if (app.group) |group| cb.DeleteCxObjAll(group);
    app.group = null;
    const everything: cx.InputXpression = .{ .class = ie.IECLASS_NULL };
    const group = cx.CxFilter(cb, null) orelse return;
    cb.SetFilterIX(group, &everything);
    for (&app.keys, 0..) |*key, i| {
        if (!key.used) continue;
        const filter = cx.CxFilter(cb, &key.description);
        if (key.command == .insert) {
            cb.AttachCxObj(filter, cx.CxTranslate(cb, key.events));
        } else {
            cb.AttachCxObj(filter, cx.CxSender(cb, commodity.port, @intCast(i)));
            cb.AttachCxObj(filter, cx.CxTranslate(cb, null));
        }
        cb.AttachCxObj(group, filter);
    }
    cb.AttachCxObj(commodity.broker, group);
    app.group = group;
}

// --- what a key does -----------------------------------------------------------------

/// The command of the key that was pressed.
fn carry(app: *App, id: i32) void {
    if (id < 0 or id >= most_keys) return;
    const key = &app.keys[@intCast(id)];
    if (!key.used) return;
    switch (key.command) {
        .cycle_windows => cycleWindows(app),
        .cycle_screens => cycleScreens(app),
        .enlarge => resize(app, true),
        .shrink => resize(app, false),
        .toggle => toggle(app),
        // Done in the network by the translator under its filter.
        .insert => {},
        .program => run(app, &key.args),
    }
}

/// The window at the back of the screen in front brought forward and
/// given the keyboard. A backdrop window - the desktop - is passed over:
/// it stays behind the others whatever is asked, and would take the
/// keyboard away from every window in turn. A window put away keeps its
/// place in the screen's list, and is passed over too: nothing of it is
/// on the display, so it takes no keyboard and the round would stop at
/// it. It comes back the way it was put away, from wherever holds it.
fn cycleWindows(app: *App) void {
    const ib = app.ib;
    const held = ib.LockIBase(0);
    defer ib.UnlockIBase(held);
    var rearmost: ?*intuition.Window = null;
    var window = ib.NextWindow(null);
    while (window) |w| : (window = ib.NextWindow(w)) {
        if (windowAttr(ib, w, wn.WA_Hidden) != 0) continue;
        if (windowAttr(ib, w, wn.WA_Backdrop) == 0) rearmost = w;
    }
    const bring = rearmost orelse return;
    ib.WindowToFront(bring);
    ib.ActivateWindow(bring);
}

/// The screen in front sent behind the others, which brings the next one
/// forward.
fn cycleScreens(app: *App) void {
    const ib = app.ib;
    const held = ib.LockIBase(0);
    defer ib.UnlockIBase(held);
    const screen = ib.FrontScreen() orelse return;
    ib.ScreenToBack(screen);
}

/// The active window grown to the room its screen leaves it, or back to
/// the least it asked for. A window with no size gadget is not sized: it
/// asked to be left at the size it has.
fn resize(app: *App, bigger: bool) void {
    const ib = app.ib;
    const held = ib.LockIBase(0);
    defer ib.UnlockIBase(held);
    const window = ib.ActiveWindow() orelse return;
    if (windowAttr(ib, window, wn.WA_Flags) & wn.WFLG_SIZEGADGET == 0) return;
    const left: i32 = @truncate(@as(isize, @bitCast(windowAttr(ib, window, wn.WA_Left))));
    const top: i32 = @truncate(@as(isize, @bitCast(windowAttr(ib, window, wn.WA_Top))));
    const width: i32 = @intCast(windowAttr(ib, window, wn.WA_Width));
    const height: i32 = @intCast(windowAttr(ib, window, wn.WA_Height));
    var want_width: i32 = 0;
    var want_height: i32 = 0;
    if (bigger) {
        const screen: *intuition.Screen = @ptrFromInt(windowAttr(ib, window, wn.WA_Screen));
        var screen_width: usize = 0;
        var screen_height: usize = 0;
        ib.GetScreenAttrs(screen, &[_]TagItem{
            .{ .tag = sc.SA_Width, .data = @intFromPtr(&screen_width) },
            .{ .tag = sc.SA_Height, .data = @intFromPtr(&screen_height) },
            .{},
        });
        const most_width: i32 = @intCast(windowAttr(ib, window, wn.WA_MaxWidth));
        const most_height: i32 = @intCast(windowAttr(ib, window, wn.WA_MaxHeight));
        want_width = @min(@as(i32, @intCast(screen_width)) - left, most_width);
        want_height = @min(@as(i32, @intCast(screen_height)) - top, most_height);
    } else {
        want_width = @intCast(windowAttr(ib, window, wn.WA_MinWidth));
        want_height = @intCast(windowAttr(ib, window, wn.WA_MinHeight));
    }
    if (want_width == width and want_height == height) return;
    ib.SizeWindow(window, want_width - width, want_height - height);
}

/// The active window to its other size, as its zoom gadget does.
fn toggle(app: *App) void {
    const ib = app.ib;
    const held = ib.LockIBase(0);
    defer ib.UnlockIBase(held);
    const window = ib.ActiveWindow() orelse return;
    // The ground the others stand on is not a window to resize: the
    // desktop's covers its whole screen and has no other size.
    if (windowAttr(ib, window, wn.WA_Flags) & wn.WFLG_BACKDROP != 0) return;
    ib.ZipWindow(window);
}

/// A command line run in a shell of its own, which this program does not
/// wait for.
fn run(app: *App, command: [*:0]const u8) void {
    const dl = app.dl;
    if (command[0] == 0) return;
    const input = dl.Open("NIL:", dos.MODE_OLDFILE) orelse return;
    const output = dl.Open("NIL:", dos.MODE_NEWFILE) orelse {
        _ = dl.Close(input);
        return;
    };
    const tags = [_]TagItem{
        .{ .tag = dos.SYS_Asynch, .data = 1 },
        .{ .tag = dos.SYS_UserShell, .data = 1 },
        .{ .tag = dos.SYS_Input, .data = @intFromPtr(input) },
        .{ .tag = dos.SYS_Output, .data = @intFromPtr(output) },
        .{},
    };
    // With SYS_Asynch the shell closes both; only a shell that never
    // started leaves them to this program.
    if (dl.SystemTagList(command, &tags) < 0) {
        _ = dl.Close(input);
        _ = dl.Close(output);
    }
}

fn windowAttr(ib: *IntuitionBase, window: *intuition.Window, tag: utility.Tag) usize {
    var value: usize = 0;
    ib.GetWindowAttrs(window, &[_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} });
    return value;
}

// --- the window ----------------------------------------------------------------------

/// Every message the window has, worked. False when one says to end.
fn windowMessages(app: *App, commodity: frame.Commodity) bool {
    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    while (app.shown) |shown| {
        const word = app.ib.SendMessage(shown.object, @ptrCast(&handle));
        if (word == wc.WMHI_LASTMSG) return true;
        switch (word & wc.WMHI_CLASSMASK) {
            // Closing hides: the window and whatever else it had go.
            wc.WMHI_CLOSEWINDOW => hide(app),
            wc.WMHI_GADGETUP => gadget(app, commodity, word & wc.WMHI_GADGETMASK, code),
            wc.WMHI_MENUPICK => {
                const number: u32 = @truncate(word & wc.WMHI_MENUMASK);
                if (number == menus.MENUNULL) continue;
                switch (menus.ITEMNUM(number)) {
                    ITEM_SAVE => if (!save(app)) app.ib.DisplayBeep(null),
                    ITEM_HIDE => hide(app),
                    ITEM_QUIT => return false,
                    else => {},
                }
            },
            else => {},
        }
    }
    return true;
}

/// A gadget let go: a key picked, added, taken away, or one of the three
/// things about it changed. Every change holds from here on; it is saved
/// when the Save menu item is picked.
fn gadget(app: *App, commodity: frame.Commodity, id: usize, code: u32) void {
    const shown = app.shown orelse return;
    switch (id) {
        ID_LIST => {
            app.chosen = keyOnLine(app, code & ~lv.LISTVIEW_DOUBLE);
            refresh(app);
            return;
        },
        ID_NEW => {
            const made = free(app) orelse return app.ib.DisplayBeep(null);
            set(app, made, .{ .description = "f1", .command = .cycle_windows });
            relist(app);
            app.chosen = made;
            rebuild(app, commodity);
            refresh(app);
            return;
        },
        ID_DELETE => {
            const which = app.chosen orelse return;
            const key = &app.keys[which];
            forget(app, key);
            key.used = false;
            relist(app);
            app.chosen = null;
            rebuild(app, commodity);
            refresh(app);
            return;
        },
        else => {},
    }
    const which = app.chosen orelse return;
    const key = &app.keys[which];
    switch (id) {
        ID_KEY => {
            var text: usize = 0;
            _ = app.ib.GetAttr(gc.STRINGA_TextVal, shown.key, &text);
            if (text == 0) return;
            copyText(&key.description, @ptrFromInt(text));
        },
        ID_COMMAND => {
            if (code >= keyform.names.len) return;
            key.command = @enumFromInt(code);
        },
        ID_ARGS => {
            var text: usize = 0;
            _ = app.ib.GetAttr(gc.STRINGA_TextVal, shown.args, &text);
            if (text == 0) return;
            copyText(&key.args, @ptrFromInt(text));
        },
        else => return,
    }
    // The events an Insert Text key types, and the line it is listed by,
    // follow whatever changed.
    forget(app, key);
    if (key.command == .insert and key.args[0] != 0) {
        key.events = cx.InvertString(app.sys, app.cb, &key.args, null);
    }
    describe(key);
    rebuild(app, commodity);
    refresh(app);
}

/// The gadgets brought up to date: the list, and the three gadgets for
/// the key picked - off altogether while none is.
fn refresh(app: *App) void {
    const ib = app.ib;
    const shown = app.shown orelse return;
    _ = ib.SetGadgetAttrsTagList(shown.list, shown.window, &[_]TagItem{ .{ .tag = lv.LISTVIEW_Labels, .data = lv.LISTVIEW_DETACH }, .{} });
    const line: u32 = if (app.chosen) |which| lineOf(app, which) else lv.LISTVIEW_NONE;
    _ = ib.SetGadgetAttrsTagList(shown.list, shown.window, &[_]TagItem{
        .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&app.lines) },
        .{ .tag = lv.LISTVIEW_Selected, .data = line },
        .{ .tag = lv.LISTVIEW_MakeVisible, .data = if (line == lv.LISTVIEW_NONE) 0 else line },
        .{},
    });
    const key: ?*Key = if (app.chosen) |which| &app.keys[which] else null;
    const none: usize = @intFromBool(key == null);
    const empty: [*:0]const u8 = "";
    _ = ib.SetGadgetAttrsTagList(shown.key, shown.window, &[_]TagItem{
        .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(if (key) |k| @as([*:0]const u8, &k.description) else empty) },
        .{ .tag = gc.GA_Disabled, .data = none },
        .{},
    });
    _ = ib.SetGadgetAttrsTagList(shown.command, shown.window, &[_]TagItem{
        .{ .tag = cy.CYCLE_Active, .data = if (key) |k| @intFromEnum(k.command) else 0 },
        .{ .tag = gc.GA_Disabled, .data = none },
        .{},
    });
    const takes: usize = @intFromBool(key == null or !keyform.takesArgs(key.?.command));
    _ = ib.SetGadgetAttrsTagList(shown.args, shown.window, &[_]TagItem{
        .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(if (key) |k| @as([*:0]const u8, &k.args) else empty) },
        .{ .tag = gc.GA_Disabled, .data = takes },
        .{},
    });
    _ = ib.SetGadgetAttrsTagList(shown.delete, shown.window, &[_]TagItem{ .{ .tag = gc.GA_Disabled, .data = none }, .{} });
}

/// Which key is on line `which` of the list.
fn keyOnLine(app: *App, which: u32) ?usize {
    var n: u32 = 0;
    for (&app.keys, 0..) |*key, i| {
        if (!key.used) continue;
        if (n == which) return i;
        n += 1;
    }
    return null;
}

/// Which line of the list a key is on.
fn lineOf(app: *App, which: usize) u32 {
    var n: u32 = 0;
    for (&app.keys, 0..) |*key, i| {
        if (!key.used) continue;
        if (i == which) return n;
        n += 1;
    }
    return lv.LISTVIEW_NONE;
}

/// The window brought up: made when it is not there, to the front and
/// active when it is.
fn show(app: *App) void {
    const ib = app.ib;
    if (app.shown) |shown| {
        ib.WindowToFront(shown.window);
        ib.ActivateWindow(shown.window);
        return;
    }
    const screen = ib.LockPubScreen(null) orelse return;
    var shown = build(app, screen) orelse {
        ib.UnlockPubScreen(null, screen);
        return;
    };
    // The menu is how the keys are saved, the window hidden or FKey
    // ended from the keyboard; one that will not go on is left out
    // rather than given up over.
    shown.menu = blk: {
        const made = ib.CreateMenusA(&project_menu, null) orelse break :blk null;
        if (!ib.LayoutMenusA(made, screen, null) or !ib.SetMenuStrip(shown.window, made)) {
            ib.FreeMenus(made);
            break :blk null;
        }
        break :blk made;
    };
    app.shown = shown;
    refresh(app);
}

/// The window hidden: where it was kept, and it and its gadgets gone.
fn hide(app: *App) void {
    const ib = app.ib;
    const shown = app.shown orelse return;
    var place: Place = .{};
    ib.GetWindowAttrs(shown.window, &[_]TagItem{
        .{ .tag = wn.WA_Left, .data = @intFromPtr(&place.left) },
        .{ .tag = wn.WA_Top, .data = @intFromPtr(&place.top) },
        .{ .tag = wn.WA_Width, .data = @intFromPtr(&place.width) },
        .{ .tag = wn.WA_Height, .data = @intFromPtr(&place.height) },
        .{},
    });
    app.place = place;
    if (shown.menu) |menu| {
        ib.ClearMenuStrip(shown.window);
        ib.FreeMenus(menu);
    }
    // The window object takes the layout and every gadget in it along.
    ib.DisposeObject(shown.object);
    ib.UnlockPubScreen(null, shown.screen);
    app.shown = null;
}

/// The window's gadgets, the window made with them and opened.
fn build(app: *App, screen: *intuition.Screen) ?Shown {
    const ib = app.ib;
    const list = ib.NewObjectTagList(null, lv.LISTVIEW_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_LIST },
        .{ .tag = lv.LISTVIEW_ShowSelected, .data = 1 },
        .{},
    });
    const new = button(ib, "New Key", ID_NEW);
    const delete = button(ib, "Delete Key", ID_DELETE);
    const key = textField(ib, ID_KEY, description_len);
    const command = ib.NewObjectTagList(null, cy.CYCLE_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_COMMAND },
        .{ .tag = gc.GA_Disabled, .data = 1 },
        .{ .tag = cy.CYCLE_Labels, .data = @intFromPtr(&keyform.labels) },
        .{},
    });
    const args = textField(ib, ID_ARGS, args_len);

    const buttons = if (new != null and delete != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 4 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(new) },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(delete) },
        .{},
    }) else null;
    const left = if (list != null and buttons != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(list) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Keys") },
        .{ .tag = lg.CHILDA_MinHeight, .data = 120 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(buttons) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{},
    }) else null;
    const right = if (key != null and command != null and args != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT },
        .{ .tag = lg.LAYOUTA_FrameTitle, .data = @intFromPtr("The key picked") },
        .{ .tag = lg.LAYOUTA_Margin, .data = 6 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(key) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Key") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(command) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Command") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(args) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Text") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddSpace, .data = 0 },
        .{},
    }) else null;
    const layout = if (left != null and right != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
        .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 8 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(left) },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 3 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(right) },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 4 },
        .{},
    }) else null;
    const made = layout orelse {
        // What a layout took is its own; only what none took goes here.
        if (buttons == null) {
            ib.DisposeObject(new);
            ib.DisposeObject(delete);
        }
        if (right == null) {
            ib.DisposeObject(key);
            ib.DisposeObject(command);
            ib.DisposeObject(args);
        }
        if (left == null) {
            ib.DisposeObject(list);
            ib.DisposeObject(buttons);
        }
        ib.DisposeObject(left);
        ib.DisposeObject(right);
        return null;
    };

    const place = app.place;
    const put = place orelse Place{};
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr(COMMAND_NAME) },
        .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr(SCREEN_TITLE) },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = if (place != null) wn.WA_Left else utility.TAG_IGNORE, .data = put.left },
        .{ .tag = if (place != null) wn.WA_Top else utility.TAG_IGNORE, .data = put.top },
        .{ .tag = if (place != null) wn.WA_Width else wn.WA_InnerWidth, .data = if (place != null) put.width else 620 },
        .{ .tag = if (place != null) wn.WA_Height else wn.WA_InnerHeight, .data = if (place != null) put.height else 220 },
        .{ .tag = wn.WA_AutoAdjust, .data = 1 },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(made) },
        .{},
    }) orelse {
        ib.DisposeObject(made);
        return null;
    };
    var open = wc.WmOpen{};
    const opened = ib.SendMessage(object, @ptrCast(&open));
    if (opened == 0) {
        ib.DisposeObject(object);
        return null;
    }
    return .{
        .screen = screen,
        .object = object,
        .window = @ptrFromInt(opened),
        .menu = null,
        .list = list.?,
        .new = new.?,
        .delete = delete.?,
        .key = key.?,
        .command = command.?,
        .args = args.?,
    };
}

fn button(ib: *IntuitionBase, text: [*:0]const u8, id: usize) ?*Object {
    return ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr(text) },
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    });
}

fn textField(ib: *IntuitionBase, id: usize, most: usize) ?*Object {
    return ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = gc.GA_Disabled, .data = 1 },
        .{ .tag = gc.STRINGA_MaxChars, .data = most },
        .{},
    });
}

fn windowSignal(ib: *IntuitionBase, object: *Object) u32 {
    var mask: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_SigMask, object, &mask);
    return @truncate(mask);
}

// --- text ----------------------------------------------------------------------------

fn copyText(into: []u8, text: [*:0]const u8) void {
    var at_text: usize = 0;
    while (text[at_text] != 0 and at_text + 1 < into.len) : (at_text += 1) into[at_text] = text[at_text];
    into[at_text] = 0;
}

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
