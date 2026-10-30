// SPDX-License-Identifier: MIT
//! Exchange: the commodities running, and each of them controlled. Built
//! against the SDK only.
//!
//!   Exchange CX_PRIORITY/K/N,CX_POPKEY/K,CX_POPUP/K
//!
//! Exchange is a commodity itself, "Exchange": its hotkey (CX_POPKEY,
//! "ctrl alt home" unless given) brings its window up, and its broker is
//! where commodities.library sends word that the commodities changed -
//! one started or ended, made active or inactive - so the window follows
//! them.
//!
//! The window lists the commodities by name. Choosing one shows its title
//! and description; the chooser under them makes it active or inactive,
//! Show Interface and Hide Interface open and close the window of one that
//! has one, and Remove ends it. Each is a command to the commodity
//! (BrokerCommand), which it carries out itself. Closing the window - its
//! close gadget, Project > Hide - only hides it; Exchange runs on until
//! Project > Quit, Remove on itself, Ctrl-C or Ctrl-E. Its hotkey, Ctrl-F
//! or a second Exchange started bring the window up again.
//!
//! CX_POPUP=NO starts it without the window; CX_PRIORITY is its broker's
//! place among the others. Started from its icon it reads the three from
//! the icon's tool types instead.
//!
//! The window is made each time it is shown and disposed of each time it
//! is hidden, and opens again where it was and at the size it had.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const icon = sdk.icon;
const intuition = sdk.intuition;
const cx = sdk.commodities;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const classusr = intuition.classusr;
const menus = intuition.menus;
const lv = sdk.gadgets.listview;
const tx = sdk.gadgets.text;
const cy = sdk.gadgets.cycle;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const IconBase = sdk.interface.icon.IconBase;
const CxBase = sdk.interface.commodities.CxBase;
const Object = intuition.Object;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Exchange";
const VERSION = "1.0";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (30.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
/// What the screen's bar says while its window is active.
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const template = "CX_PRIORITY/K/N,CX_POPKEY/K,CX_POPUP/K";
const arg_priority = 0;
const arg_popkey = 1;
const arg_popup = 2;

const default_popkey = "ctrl alt home";
/// The hotkey's sender id.
const popkey_id = 1;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOMEMORY = "No memory\n";
const MSG_NOBROKER = "No broker (error %d)\n";
const MSG_BADPOPKEY = "Not a hotkey: %s\n";

const ID_LIST = 1;
const ID_STATE = 2;
const ID_SHOW = 3;
const ID_HIDE = 4;
const ID_REMOVE = 5;

/// The Project menu, in this order.
const ITEM_HIDE = 0;
const ITEM_QUIT = 1;

const project_menu = [_]menus.NewMenu{
    .{ .type = menus.NM_TITLE, .label = "Project" },
    .{ .type = menus.NM_ITEM, .label = "Hide", .comm_key = "H" },
    .{ .type = menus.NM_ITEM, .label = "Quit", .comm_key = "Q" },
    .{ .type = menus.NM_END },
};

/// The chooser's choices: CXCMD_ENABLE for the first, CXCMD_DISABLE for
/// the second.
const states = [_:null]?[*:0]const u8{ "Active", "Inactive" };

/// The window's gadgets and what it stands on, while it is shown.
const Shown = struct {
    screen: *intuition.Screen,
    object: *Object,
    window: *intuition.Window,
    menu: ?*intuition.Menu,
    list: *Object,
    title: *Object,
    descr: *Object,
    state: *Object,
    show: *Object,
    hide: *Object,
    remove: *Object,
};

/// Where the window was and how big, when it was last hidden.
const Place = struct { left: usize = 0, top: usize = 0, width: usize = 0, height: usize = 0 };

const App = struct {
    sys: *ExecBase,
    ib: *IntuitionBase,
    ub: *UtilityBase,
    cb: *CxBase,
    /// The commodities as CopyBrokerList copied them, in the order of
    /// their names.
    brokers: exec.List = .{},
    /// The name of the one chosen; empty when none is.
    chosen: [cx.CBD_NAMELEN]u8 = @splat(0),
    /// What the information box shows.
    title: [cx.CBD_TITLELEN]u8 = @splat(0),
    descr: [cx.CBD_DESCRLEN]u8 = @splat(0),
    /// "Exchange: Hot Key = <...>".
    window_title: [160]u8 = @splat(0),
    shown: ?Shown = null,
    place: ?Place = null,
};

/// What the program was asked for, from its command line or its icon.
const Asked = struct {
    priority: i32 = 0,
    popkey: [128:0]u8 = @splat(0),
    popup: bool = true,
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var asked: Asked = .{};
    copyText(&asked.popkey, default_popkey);
    if (!readIcon(sys, dl, &asked)) {
        var argv: [3]usize = @splat(0);
        const rda = dl.ReadArgs(template, &argv, null) orelse {
            _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
            return dos.RETURN_FAIL;
        };
        defer dl.FreeArgs(rda);
        if (argv[arg_priority] != 0) asked.priority = @as(*const i32, @ptrFromInt(argv[arg_priority])).*;
        if (argv[arg_popkey] != 0) copyText(&asked.popkey, @ptrFromInt(argv[arg_popkey]));
        if (argv[arg_popup] != 0) asked.popup = !sameWord(@ptrFromInt(argv[arg_popup]), "NO");
    }

    const names = [_][*:0]const u8{ sdk.interface.utility.NAME, intuition.INTUITIONNAME, cx.COMMODITIESNAME, lv.LISTVIEW_LIBRARY, tx.TEXT_LIBRARY, cy.CYCLE_LIBRARY };
    var libraries: [names.len]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    for (names, 0..) |name, i| {
        libraries[i] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{name});
            return dos.RETURN_FAIL;
        };
    }
    var app: App = .{
        .sys = sys,
        .ub = @ptrCast(libraries[0].?),
        .ib = @ptrCast(libraries[1].?),
        .cb = @ptrCast(libraries[2].?),
    };
    const cb = app.cb;
    app.brokers.init(.unknown);
    defer cb.FreeBrokerList(&app.brokers);

    const popkey: [*:0]const u8 = &asked.popkey;
    var check: cx.InputXpression = .{};
    if (cb.ParseIX(popkey, &check) != 0) {
        _ = Printf(dl, MSG_BADPOPKEY, .{popkey});
        return dos.RETURN_ERROR;
    }
    joinTitle(&app.window_title, popkey);

    const port = sys.CreateMsgPort() orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer sys.DeleteMsgPort(port);
    var err: i32 = cx.CBERR_OK;
    const broker = cb.CxBroker(&.{
        .name = COMMAND_NAME,
        .title = "Commodities Exchange",
        .descr = "Controls the commodities",
        .unique = cx.NBU_UNIQUE | cx.NBU_NOTIFY,
        .flags = cx.COF_SHOW_HIDE,
        .pri = asked.priority,
        .port = port,
    }, &err) orelse {
        // A second Exchange: the first was told, and shows its window.
        if (err == cx.CBERR_DUP) return dos.RETURN_OK;
        _ = Printf(dl, MSG_NOBROKER, .{err});
        return dos.RETURN_FAIL;
    };
    // The broker goes before the port, and whatever is still on the port
    // is answered.
    defer {
        cb.DeleteCxObjAll(broker);
        while (sys.GetMsg(port)) |msg| sys.ReplyMsg(msg);
    }
    cb.AttachCxObj(broker, cx.HotKey(cb, popkey, port, popkey_id));
    if (cb.CxObjError(broker) != 0) {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }
    _ = cb.ActivateCxObj(broker, true);

    defer hide(&app);
    if (asked.popup) show(&app);

    // A Ctrl-C from before it started is not a request to stop it.
    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C | exec.SIGBREAKF_CTRL_E | exec.SIGBREAKF_CTRL_F);
    const breaks = exec.SIGBREAKF_CTRL_C | exec.SIGBREAKF_CTRL_E;
    while (true) {
        const window_mask = if (app.shown) |shown| windowSignal(app.ib, shown.object) else 0;
        const got = sys.Wait(port.sigMask() | breaks | exec.SIGBREAKF_CTRL_F | window_mask);
        if (got & breaks != 0) return dos.RETURN_OK;
        if (got & exec.SIGBREAKF_CTRL_F != 0) show(&app);
        while (sys.GetMsg(port)) |msg| {
            if (!commodityMessage(&app, broker, msg)) return dos.RETURN_OK;
        }
        if (!windowMessages(&app)) return dos.RETURN_OK;
    }
}

/// A message on the broker's port, answered. False when it says to end.
fn commodityMessage(app: *App, broker: *cx.CxObj, msg: *exec.Message) bool {
    const cb = app.cb;
    const cxm = cx.CxMsg.from(msg);
    const kind = cb.CxMsgType(cxm);
    const id = cb.CxMsgID(cxm);
    app.sys.ReplyMsg(msg);
    if (kind == cx.CXM_IEVENT) {
        if (id == popkey_id) show(app);
        return true;
    }
    switch (id) {
        cx.CXCMD_DISABLE => _ = cb.ActivateCxObj(broker, false),
        cx.CXCMD_ENABLE => _ = cb.ActivateCxObj(broker, true),
        cx.CXCMD_APPEAR, cx.CXCMD_UNIQUE => show(app),
        cx.CXCMD_DISAPPEAR => hide(app),
        cx.CXCMD_KILL => return false,
        cx.CXCMD_LIST_CHG => refresh(app, true),
        else => {},
    }
    return true;
}

/// Every message the window has, worked. False when one says to end.
fn windowMessages(app: *App) bool {
    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    while (app.shown) |shown| {
        const word = app.ib.SendMessage(shown.object, @ptrCast(&handle));
        if (word == wc.WMHI_LASTMSG) return true;
        switch (word & wc.WMHI_CLASSMASK) {
            // Closing hides: the window and whatever else it had go.
            wc.WMHI_CLOSEWINDOW => hide(app),
            wc.WMHI_GADGETUP => gadget(app, word & wc.WMHI_GADGETMASK, code),
            wc.WMHI_MENUPICK => {
                const number: u32 = @truncate(word & wc.WMHI_MENUMASK);
                if (number == menus.MENUNULL) continue;
                switch (menus.ITEMNUM(number)) {
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

/// A gadget let go: a commodity chosen, or a command to the one chosen.
fn gadget(app: *App, id: usize, code: u32) void {
    if (id == ID_LIST) {
        const copy = copyAt(app, code & ~lv.LISTVIEW_DOUBLE) orelse return;
        app.chosen = copy.name_buffer;
        refresh(app, false);
        return;
    }
    if (app.chosen[0] == 0) return;
    const command: i32 = switch (id) {
        ID_STATE => if (code == 0) cx.CXCMD_ENABLE else cx.CXCMD_DISABLE,
        ID_SHOW => cx.CXCMD_APPEAR,
        ID_HIDE => cx.CXCMD_DISAPPEAR,
        ID_REMOVE => cx.CXCMD_KILL,
        else => return,
    };
    _ = app.cb.BrokerCommand(@ptrCast(&app.chosen), command);
    // The list as it is now: a commodity that took the command tells the
    // library, which sends word again once it has.
    refresh(app, true);
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
    // The menu is how the window is hidden or Exchange ended from the
    // keyboard; one that will not go on is left out rather than given up
    // over.
    shown.menu = blk: {
        const made = ib.CreateMenusA(&project_menu, null) orelse break :blk null;
        if (!ib.LayoutMenusA(made, screen, null) or !ib.SetMenuStrip(shown.window, made)) {
            ib.FreeMenus(made);
            break :blk null;
        }
        break :blk made;
    };
    app.shown = shown;
    refresh(app, true);
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
    const title = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&app.title) },
        .{ .tag = tx.TEXT_Clipped, .data = 1 },
        .{ .tag = tx.TEXT_Justification, .data = tx.TEXT_JUSTIFY_LEFT },
        .{},
    });
    const descr = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&app.descr) },
        .{ .tag = tx.TEXT_Clipped, .data = 1 },
        .{ .tag = tx.TEXT_Justification, .data = tx.TEXT_JUSTIFY_LEFT },
        .{},
    });
    const state = ib.NewObjectTagList(null, cy.CYCLE_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_STATE },
        .{ .tag = gc.GA_Disabled, .data = 1 },
        .{ .tag = cy.CYCLE_Labels, .data = @intFromPtr(&states) },
        .{},
    });
    const show_button = button(ib, "Show Interface", ID_SHOW);
    const hide_button = button(ib, "Hide Interface", ID_HIDE);
    const remove = button(ib, "Remove", ID_REMOVE);

    const info = if (title != null and descr != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT },
        .{ .tag = lg.LAYOUTA_FrameTitle, .data = @intFromPtr("Information") },
        .{ .tag = lg.LAYOUTA_Margin, .data = 6 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 4 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(title) },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(descr) },
        .{},
    }) else null;
    const buttons = if (show_button != null and hide_button != null and state != null and remove != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_GRID },
        .{ .tag = lg.LAYOUTA_Columns, .data = 2 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 4 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(show_button) },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(hide_button) },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(state) },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(remove) },
        .{},
    }) else null;
    const right = if (info != null and buttons != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(info) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddSpace, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(buttons) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{},
    }) else null;
    const layout = if (list != null and right != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
        .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 8 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(list) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Commodities") },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 2 },
        .{ .tag = lg.CHILDA_MinHeight, .data = 120 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(right) },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 3 },
        .{},
    }) else null;
    const made = layout orelse {
        // What a layout took is its own; only what none took goes here.
        if (right == null) {
            if (info == null) {
                ib.DisposeObject(title);
                ib.DisposeObject(descr);
            }
            if (buttons == null) {
                ib.DisposeObject(show_button);
                ib.DisposeObject(hide_button);
                ib.DisposeObject(state);
                ib.DisposeObject(remove);
            }
            ib.DisposeObject(info);
            ib.DisposeObject(buttons);
        }
        ib.DisposeObject(list);
        ib.DisposeObject(right);
        return null;
    };

    const place = app.place;
    const placed: sdk.utility.Tag = if (place != null) wn.WA_Left else sdk.utility.TAG_IGNORE;
    const at = place orelse Place{};
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr(&app.window_title) },
        .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr(SCREEN_TITLE) },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = placed, .data = at.left },
        .{ .tag = if (place != null) wn.WA_Top else sdk.utility.TAG_IGNORE, .data = at.top },
        .{ .tag = if (place != null) wn.WA_Width else wn.WA_InnerWidth, .data = if (place != null) at.width else 600 },
        .{ .tag = if (place != null) wn.WA_Height else wn.WA_InnerHeight, .data = if (place != null) at.height else 200 },
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
        .title = title.?,
        .descr = descr.?,
        .state = state.?,
        .show = show_button.?,
        .hide = hide_button.?,
        .remove = remove.?,
    };
}

fn button(ib: *IntuitionBase, text: [*:0]const u8, id: usize) ?*Object {
    return ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr(text) },
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = gc.GA_Disabled, .data = 1 },
        .{},
    });
}

/// The gadgets brought up to date: with `again`, the list read anew and
/// the one chosen found in it; then the information, the chooser and the
/// buttons for the one chosen, or for none.
fn refresh(app: *App, again: bool) void {
    const ib = app.ib;
    const shown = app.shown orelse return;
    if (again) {
        _ = ib.SetGadgetAttrsTagList(shown.list, shown.window, &[_]TagItem{ .{ .tag = lv.LISTVIEW_Labels, .data = lv.LISTVIEW_DETACH }, .{} });
        readList(app);
        const line = if (chosenCopy(app)) |copy| lineOf(app, copy) else blk: {
            app.chosen[0] = 0;
            break :blk lv.LISTVIEW_NONE;
        };
        _ = ib.SetGadgetAttrsTagList(shown.list, shown.window, &[_]TagItem{
            .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&app.brokers) },
            .{ .tag = lv.LISTVIEW_Selected, .data = line },
            .{ .tag = lv.LISTVIEW_MakeVisible, .data = if (line == lv.LISTVIEW_NONE) 0 else line },
            .{},
        });
    }
    const chosen = chosenCopy(app);
    if (chosen) |copy| {
        app.title = copy.title;
        app.descr = copy.descr;
    } else {
        app.title[0] = 0;
        app.descr[0] = 0;
    }
    _ = ib.SetGadgetAttrsTagList(shown.title, shown.window, &[_]TagItem{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&app.title) }, .{} });
    _ = ib.SetGadgetAttrsTagList(shown.descr, shown.window, &[_]TagItem{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&app.descr) }, .{} });
    const none: usize = @intFromBool(chosen == null);
    // With none chosen the chooser stands on its first choice, off.
    const flags = if (chosen) |copy| copy.flags else cx.COF_ACTIVE;
    const no_window: usize = @intFromBool(chosen == null or flags & cx.COF_SHOW_HIDE == 0);
    _ = ib.SetGadgetAttrsTagList(shown.state, shown.window, &[_]TagItem{
        .{ .tag = cy.CYCLE_Active, .data = @intFromBool(flags & cx.COF_ACTIVE == 0) },
        .{ .tag = gc.GA_Disabled, .data = none },
        .{},
    });
    _ = ib.SetGadgetAttrsTagList(shown.show, shown.window, &[_]TagItem{ .{ .tag = gc.GA_Disabled, .data = no_window }, .{} });
    _ = ib.SetGadgetAttrsTagList(shown.hide, shown.window, &[_]TagItem{ .{ .tag = gc.GA_Disabled, .data = no_window }, .{} });
    _ = ib.SetGadgetAttrsTagList(shown.remove, shown.window, &[_]TagItem{ .{ .tag = gc.GA_Disabled, .data = none }, .{} });
}

/// The commodities copied afresh, in the order of their names, case
/// aside.
fn readList(app: *App) void {
    const sys = app.sys;
    app.cb.FreeBrokerList(&app.brokers);
    var copied: exec.List = .{};
    copied.init(.unknown);
    _ = app.cb.CopyBrokerList(&copied);
    while (sys.RemHead(&copied)) |node| {
        var after: ?*exec.Node = null;
        var it = app.brokers.iterator();
        while (it.next()) |have| {
            if (app.ub.Stricmp(have.name.?, node.name.?) >= 0) break;
            after = have;
        }
        sys.Insert(&app.brokers, node, after);
    }
}

/// The copy of the commodity chosen, or null when none is or it has gone.
fn chosenCopy(app: *App) ?*cx.BrokerCopy {
    if (app.chosen[0] == 0) return null;
    const node = app.sys.FindName(&app.brokers, @ptrCast(&app.chosen)) orelse return null;
    return @fieldParentPtr("node", node);
}

/// The copy on line `line` of the list.
fn copyAt(app: *App, line: u32) ?*cx.BrokerCopy {
    var at: u32 = 0;
    var it = app.brokers.iterator();
    while (it.next()) |node| : (at += 1) {
        if (at == line) return @fieldParentPtr("node", node);
    }
    return null;
}

/// The line `copy` is on.
fn lineOf(app: *App, copy: *cx.BrokerCopy) u32 {
    var at: u32 = 0;
    var it = app.brokers.iterator();
    while (it.next()) |node| : (at += 1) {
        if (node == &copy.node) return at;
    }
    return lv.LISTVIEW_NONE;
}

fn windowSignal(ib: *IntuitionBase, object: *Object) u32 {
    var mask: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_SigMask, object, &mask);
    return @truncate(mask);
}

/// CX_PRIORITY, CX_POPKEY and CX_POPUP from the program's own icon, when
/// it was started with one: the first file it was handed is itself.
/// False when it was not, and the command line says.
fn readIcon(sys: *ExecBase, dl: *DosBase, asked: *Asked) bool {
    var count: u32 = 0;
    const files = dl.GetArgList(&count) orelse return false;
    if (count == 0) return false;
    const program = files[0];
    const name = program.name orelse return true;
    const icon_lib = sys.OpenLibrary(icon.ICONNAME, 1) orelse return true;
    defer sys.CloseLibrary(icon_lib);
    const ib: *IconBase = @ptrCast(icon_lib);
    const old = dl.CurrentDir(program.lock);
    defer _ = dl.CurrentDir(old);
    const object = ib.GetDiskObject(name) orelse return true;
    defer ib.FreeDiskObject(object);
    if (ib.FindToolType(object.tool_types, "CX_PRIORITY")) |text| {
        var value: i32 = 0;
        if (dl.StrToLong(text, &value) > 0) asked.priority = value;
    }
    if (ib.FindToolType(object.tool_types, "CX_POPKEY")) |text| copyText(&asked.popkey, text);
    if (ib.FindToolType(object.tool_types, "CX_POPUP")) |text| asked.popup = !ib.MatchToolValue(text, "NO");
    return true;
}

/// "Exchange: Hot Key = <popkey>", cut to fit.
fn joinTitle(into: []u8, popkey: [*:0]const u8) void {
    var at: usize = 0;
    for ([_][*:0]const u8{ COMMAND_NAME ++ ": Hot Key = <", popkey, ">" }) |part| {
        var i: usize = 0;
        while (part[i] != 0 and at + 1 < into.len) : (i += 1) {
            into[at] = part[i];
            at += 1;
        }
    }
    into[at] = 0;
}

fn copyText(into: *[128:0]u8, text: [*:0]const u8) void {
    var length: usize = 0;
    while (text[length] != 0 and length < into.len) : (length += 1) into[length] = text[length];
    into[length] = 0;
}

/// Whether two words are the same, ignoring the case of ASCII letters.
fn sameWord(left: [*:0]const u8, right: [*:0]const u8) bool {
    var at: usize = 0;
    while (true) : (at += 1) {
        const a = if (left[at] >= 'a' and left[at] <= 'z') left[at] - 32 else left[at];
        const b = if (right[at] >= 'a' and right[at] <= 'z') right[at] - 32 else right[at];
        if (a != b) return false;
        if (a == 0) return true;
    }
}
