// SPDX-License-Identifier: MIT
//! Blanker: the screen goes dark when nothing has been typed or moved for
//! a while. Built against the SDK only.
//!
//!   Blanker SECONDS/K/N,CYCLECOLORS/K,ANIMATION/K,CX_PRIORITY/K/N,CX_POPKEY/K,CX_POPUP/K
//!
//! After SECONDS of quiet - no key, no mouse, no finger, and no mouse
//! button held - a screen of its own comes to the front with nothing on
//! it, and the pointer stops being drawn. The first key, move or touch
//! after that closes it again and goes no further, so the stroke that
//! wakes the screen does not also land in whatever window was active.
//!
//! ANIMATION draws a figure of straight lines that moves and leaves a
//! trail; CYCLECOLORS walks it through the colours - or, with no
//! animation, fills the screen with a colour that changes slowly. With
//! neither, the screen stays black and the panel's backlight goes off
//! as well, which is what saves a panel that is on all day; with
//! something moving the backlight has to stay on to be seen.
//!
//! Its window (CX_POPKEY, "ctrl alt b" unless given; CX_POPUP=NO to start
//! without it) holds the three settings, and changing one takes effect at
//! once. They are not written anywhere: the lasting settings are the tool
//! types of the program's own icon, which it reads when it is started
//! from one - SECONDS, CYCLECOLORS and ANIMATION, the same names.
//!
//! The quiet is counted in the network, on input.device's ticks, and the
//! screen is opened and closed on the program's own task, which the
//! network signals: opening a screen waits, and nothing in the network
//! may.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const rtg = sdk.rtg;
const sc = intuition.screens;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const classusr = intuition.classusr;
const menus = intuition.menus;
const ig = sdk.gadgets.integer;
const cbox = sdk.gadgets.checkbox;
const cx = sdk.commodities;
const ie = sdk.devices.inputevent;
const frame = @import("commodity");
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const CxBase = sdk.interface.commodities.CxBase;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Blanker";
const VERSION = "1.0";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (02.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const template = "SECONDS/K/N,CYCLECOLORS/K,ANIMATION/K,CX_PRIORITY/K/N,CX_POPKEY/K,CX_POPUP/K";
const arg_seconds = 0;
const arg_cyclecolors = 1;
const arg_animation = 2;
/// CX_PRIORITY, CX_POPKEY and CX_POPUP follow in that order.
const arg_standard = 3;

const default_popkey = "ctrl alt b";
/// The hotkey's sender id.
const popkey_id = 1;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOMEMORY = "No memory\n";
const MSG_DUPLICATE = "%s runs already\n";
const MSG_BADPOPKEY = "Not a hotkey: %s\n";

/// How long the quiet has to last, in input.device's ticks a second.
const ticks_a_second = 10;
/// The least and most SECONDS may be.
const least_seconds = 1;
const most_seconds = 9999;

/// How long a step of the animation lasts, in dos ticks (fiftieths).
const step_delay = 2;
/// With nothing moving, the colour changes this many steps apart.
const slow_steps = 5;

/// The points of the figure, and how many figures the trail is long.
const points = 6;
const trail = 24;

const ID_SECONDS = 1;
const ID_CYCLE = 2;
const ID_ANIMATION = 3;

/// The Project menu, in this order.
const ITEM_HIDE = 0;
const ITEM_QUIT = 1;

const project_menu = [_]menus.NewMenu{
    .{ .type = menus.NM_TITLE, .label = "Project" },
    .{ .type = menus.NM_ITEM, .label = "Hide", .comm_key = "H" },
    .{ .type = menus.NM_ITEM, .label = "Quit", .comm_key = "Q" },
    .{ .type = menus.NM_END },
};

/// What the custom object in the network and the program's task share:
/// the quiet counted, and what the task is asked to do about it. The
/// custom object's function is handed nothing of the program's own, and
/// this is the one program of its name (NBU_UNIQUE).
const Watch = struct {
    sys: ?*ExecBase = null,
    task: ?*exec.Task = null,
    mask: u32 = 0,
    /// Ticks of quiet so far, and how many make it dark.
    quiet: u32 = 0,
    limit: u32 = 60 * ticks_a_second,
    /// Written by the task: whether the screen is up.
    dark: bool = false,
    /// What the task is asked for: nothing, or one of the two.
    asked: enum(u8) { nothing, blank, unblank } = .nothing,
};
var watch: Watch = .{};

/// What the settings say.
const Asked = struct {
    seconds: i32 = 60,
    cycle_colors: bool = true,
    animation: bool = true,
};

/// The dark screen while it is up.
const Dark = struct {
    screen: *intuition.Screen,
    rp: *graphics.RastPort,
    width: i32,
    height: i32,
    /// The display it is on, and what its brightness was before: a panel
    /// with nothing to show on it is turned off as well.
    board: ?*rtg.RtgBoard = null,
    was_bright: u32 = 0,
    dimmed: bool = false,
};

/// The window's gadgets and what it stands on, while it is shown.
const Shown = struct {
    screen: *intuition.Screen,
    object: *Object,
    window: *intuition.Window,
    menu: ?*intuition.Menu,
    seconds: *Object,
    cycle: *Object,
    animation: *Object,
};

/// Where the window was and how big, when it was last hidden.
const Place = struct { left: usize = 0, top: usize = 0, width: usize = 0, height: usize = 0 };

const App = struct {
    sys: *ExecBase,
    dl: *DosBase,
    gb: *GraphicsBase,
    ib: *IntuitionBase,
    rb: ?*RtgBase,
    cb: *CxBase,
    asked: Asked = .{},
    dark: ?Dark = null,
    shown: ?Shown = null,
    place: ?Place = null,
    /// The figure: where its points are, where they are going, the
    /// figures still on the screen, and the colour they are drawn in.
    x: [points]i32 = @splat(0),
    y: [points]i32 = @splat(0),
    dx: [points]i32 = @splat(0),
    dy: [points]i32 = @splat(0),
    was: [trail][points][2]i32 = @splat(@splat(@splat(0))),
    drawn: u32 = 0,
    red: i32 = 53,
    green: i32 = 33,
    blue: i32 = 35,
    dred: i32 = -3,
    dgreen: i32 = 5,
    dblue: i32 = 7,
    /// Counts the steps between colours with nothing moving.
    slow: u32 = 0,
    seed: u32 = 0,
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [6]usize = @splat(0);
    var settings = frame.Settings.read(sys, dl, COMMAND_NAME, template, &argv) orelse return dos.RETURN_FAIL;
    defer settings.done();
    var asked: Asked = .{};
    var standard: frame.Asked = .{};
    frame.copyText(&standard.popkey, default_popkey);
    settings.number("SECONDS", arg_seconds, &asked.seconds);
    settings.yesNo("CYCLECOLORS", arg_cyclecolors, &asked.cycle_colors);
    settings.yesNo("ANIMATION", arg_animation, &asked.animation);
    settings.standard(&standard, arg_standard);
    asked.seconds = @max(least_seconds, @min(most_seconds, asked.seconds));

    const names = [_][*:0]const u8{
        graphics.GRAPHICSNAME, intuition.INTUITIONNAME, cx.COMMODITIESNAME,
        ig.INTEGER_LIBRARY,    cbox.CHECKBOX_LIBRARY,
    };
    var libraries: [names.len]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    for (names, 0..) |name, i| {
        libraries[i] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{name});
            return dos.RETURN_FAIL;
        };
    }
    // The display layer is only wanted for the backlight: a machine
    // without it blanks the screen and leaves the panel alone.
    const rtg_lib = sys.OpenLibrary(rtg.RTGNAME, 0);
    defer sys.CloseLibrary(rtg_lib);

    // The trail of figures is more than a shell's stack holds: the whole
    // of it is allocated, cleared, and every field that is not zero set
    // by hand.
    const memory = sys.AllocVec(@sizeOf(App), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const app: *App = @ptrCast(@alignCast(memory));
    app.sys = sys;
    app.dl = dl;
    app.gb = @ptrCast(libraries[0].?);
    app.ib = @ptrCast(libraries[1].?);
    app.rb = if (rtg_lib) |lib| @ptrCast(lib) else null;
    app.cb = @ptrCast(libraries[2].?);
    app.asked = asked;
    app.dark = null;
    app.shown = null;
    app.place = null;
    app.red = 53;
    app.green = 33;
    app.blue = 35;
    app.dred = -3;
    app.dgreen = 5;
    app.dblue = 7;
    const cb = app.cb;

    const popkey: [*:0]const u8 = &standard.popkey;
    var check: cx.InputXpression = .{};
    if (cb.ParseIX(popkey, &check) != 0) {
        _ = Printf(dl, MSG_BADPOPKEY, .{popkey});
        return dos.RETURN_ERROR;
    }

    const bit = sys.AllocSignal(-1);
    if (bit < 0) {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }
    defer sys.FreeSignal(bit);
    const wake: u32 = @as(u32, 1) << @as(u5, @intCast(bit));
    watch = .{
        .sys = sys,
        .task = sys.FindTask(null),
        .mask = wake,
        .limit = @as(u32, @intCast(asked.seconds)) * ticks_a_second,
    };

    const commodity = frame.Commodity.open(sys, cb, .{
        .name = COMMAND_NAME,
        .title = "Blanker",
        .descr = "Darkens an idle screen",
        .unique = cx.NBU_UNIQUE | cx.NBU_NOTIFY,
        .flags = cx.COF_SHOW_HIDE,
        .pri = standard.priority,
    }) catch |err| {
        // A second Blanker: the first was told, and shows its window.
        if (err == error.Duplicate) return dos.RETURN_OK;
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer commodity.close();

    // Every event, whatever its class: the quiet is the absence of all of
    // them. The hotkey is a filter of its own under the broker.
    if (!commodity.attach(cx.CxCustom(cb, &quiet, 0)) or
        !commodity.attach(cx.HotKey(cb, popkey, commodity.port, popkey_id)))
    {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }
    commodity.activate(true);

    // However it ends, the screen goes and the pointer comes back.
    defer unblank(app);
    defer hide(app);
    if (standard.popup) show(app);

    while (true) {
        const window_mask = if (app.shown) |shown| windowSignal(app.ib, shown.object) else 0;
        const mask = commodity.signals() | wake | window_mask;
        // While something is being drawn the task does not wait for the
        // next event: it draws a step and looks at what has arrived.
        const got = if (app.dark != null and drawing(app)) blk: {
            step(app);
            _ = dl.Delay(step_delay);
            break :blk sys.SetSignal(0, mask);
        } else sys.Wait(mask);
        if (frame.Commodity.stopped(got)) break;
        if (got & wake != 0) asBidden(app);
        while (commodity.next()) |event| switch (event) {
            .end => return dos.RETURN_OK,
            .input => |in| if (in.id == popkey_id) show(app),
            .show => show(app),
            .hide => hide(app),
            // Made inactive it counts no more quiet: the screen goes.
            .disabled => {
                unblank(app);
                watch.quiet = 0;
                watch.asked = .nothing;
            },
            .enabled, .list_changed => {},
        };
        if (!windowMessages(app)) return dos.RETURN_OK;
    }
    return dos.RETURN_OK;
}

/// Whether anything is drawn on the dark screen: with neither the
/// animation nor the colours it stays black, and the task waits.
fn drawing(app: *const App) bool {
    return app.asked.animation or app.asked.cycle_colors;
}

/// What the network asked for, done.
fn asBidden(app: *App) void {
    switch (watch.asked) {
        .nothing => {},
        .blank => {
            watch.asked = .nothing;
            blank(app);
            // The screen would not open: the quiet starts again rather
            // than asking for it at every tick.
            if (app.dark == null) watch.quiet = 0;
        },
        .unblank => {
            watch.asked = .nothing;
            unblank(app);
        },
    }
}

// --- the dark screen -----------------------------------------------------------------

/// The screen opened in front of everything, the pointer hidden, and the
/// figure started.
fn blank(app: *App) void {
    if (app.dark != null) return;
    const ib = app.ib;
    const screen = ib.OpenScreenTagList(&[_]TagItem{
        .{ .tag = sc.SA_Quiet, .data = 1 },
        .{ .tag = sc.SA_Title, .data = @intFromPtr(SCREEN_TITLE) },
        .{},
    }) orelse return;
    var rp: usize = 0;
    var width: usize = 0;
    var height: usize = 0;
    var board: usize = 0;
    ib.GetScreenAttrs(screen, &[_]TagItem{
        .{ .tag = sc.SA_RastPort, .data = @intFromPtr(&rp) },
        .{ .tag = sc.SA_Width, .data = @intFromPtr(&width) },
        .{ .tag = sc.SA_Height, .data = @intFromPtr(&height) },
        .{ .tag = sc.SA_Board, .data = @intFromPtr(&board) },
        .{},
    });
    if (rp == 0 or width == 0 or height == 0) {
        _ = ib.CloseScreen(screen);
        return;
    }
    app.dark = .{
        .screen = screen,
        .rp = @ptrFromInt(rp),
        .width = @intCast(width),
        .height = @intCast(height),
        .board = if (board == 0) null else @ptrFromInt(board),
    };
    watch.dark = true;
    ib.HidePointer(true);
    paint(app, 0xFF00_0000);
    begin(app);
    // Nothing to see: the panel goes off too.
    if (!drawing(app)) dim(app);
}

/// The screen closed, the pointer and the backlight back as they were.
fn unblank(app: *App) void {
    const dark = app.dark orelse return;
    bright(app);
    app.ib.HidePointer(false);
    app.dark = null;
    watch.dark = false;
    _ = app.ib.CloseScreen(dark.screen);
}

/// The display's backlight off, with what it was kept.
fn dim(app: *App) void {
    const rb = app.rb orelse return;
    const dark = &(app.dark orelse return);
    const board = dark.board orelse return;
    const was = rb.BoardBrightness(board);
    if (rb.SetBoardBrightness(board, 0) != rtg.errors.RTGERR_OK) return;
    dark.was_bright = was;
    dark.dimmed = true;
}

/// The backlight back where it was.
fn bright(app: *App) void {
    const rb = app.rb orelse return;
    const dark = &(app.dark orelse return);
    if (!dark.dimmed) return;
    const board = dark.board orelse return;
    _ = rb.SetBoardBrightness(board, dark.was_bright);
    dark.dimmed = false;
}

/// The whole screen in one colour.
fn paint(app: *App, colour: graphics.Pen) void {
    const dark = app.dark orelse return;
    app.gb.SetRPAttrs(dark.rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = colour }, .{} });
    app.gb.RectFill(dark.rp, &.{ .min_x = 0, .min_y = 0, .max_x = dark.width, .max_y = dark.height });
}

/// The figure put somewhere to start from, with nothing of it drawn yet.
fn begin(app: *App) void {
    const dark = app.dark orelse return;
    app.drawn = 0;
    app.slow = 0;
    for (0..points) |i| {
        app.x[i] = @intCast(random(app, @intCast(dark.width)));
        app.y[i] = @intCast(random(app, @intCast(dark.height)));
        app.dx[i] = 2 + @as(i32, @intCast(random(app, 4)));
        app.dy[i] = 2 + @as(i32, @intCast(random(app, 4)));
    }
}

/// One step: the figure moved on, the oldest of the trail wiped out, and
/// the colour walked on.
fn step(app: *App) void {
    if (!app.asked.animation) {
        // Nothing moves: the whole screen takes the colour, slowly.
        app.slow += 1;
        if (app.slow < slow_steps) return;
        app.slow = 0;
        walk(app);
        paint(app, pen(app));
        return;
    }
    if (app.asked.cycle_colors) walk(app);
    const dark = app.dark orelse return;
    // The figure at the end of the trail, drawn again in black.
    if (app.drawn >= trail) {
        const oldest = app.was[app.drawn % trail];
        figure(app, &oldest, 0xFF00_0000);
    }
    for (0..points) |i| {
        app.x[i] = bounce(&app.x[i], &app.dx[i], dark.width);
        app.y[i] = bounce(&app.y[i], &app.dy[i], dark.height);
    }
    var now: [points][2]i32 = undefined;
    for (0..points) |i| now[i] = .{ app.x[i], app.y[i] };
    app.was[app.drawn % trail] = now;
    figure(app, &now, pen(app));
    app.drawn += 1;
}

/// A point moved by its step, turned round at the edges.
fn bounce(at: *i32, by: *i32, length: i32) i32 {
    var next = at.* + by.*;
    if (next < 0) {
        next = 0;
        by.* = 1 + @as(i32, @intCast(@mod(@abs(by.*), 6)));
    } else if (next >= length) {
        next = length - 1;
        by.* = -1 - @as(i32, @intCast(@mod(@abs(by.*), 6)));
    }
    at.* = next;
    return next;
}

/// The lines from point to point, in one colour.
fn figure(app: *App, at: *const [points][2]i32, pen_value: graphics.Pen) void {
    const dark = app.dark orelse return;
    const gb = app.gb;
    gb.SetRPAttrs(dark.rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = pen_value }, .{} });
    gb.Move(dark.rp, at[0][0], at[0][1]);
    for (1..points) |i| gb.Draw(dark.rp, at[i][0], at[i][1]);
    gb.Draw(dark.rp, at[0][0], at[0][1]);
}

/// The colour as it is now.
fn pen(app: *const App) graphics.Pen {
    if (!app.asked.cycle_colors) return graphics.penARGB(0xFF, 0xBB, 0xBB, 0xBB);
    const red: u8 = @intCast(@as(u32, @intCast(app.red)) * 2);
    const green: u8 = @intCast(@as(u32, @intCast(app.green)) * 2);
    const blue: u8 = @intCast(@as(u32, @intCast(app.blue)) * 2);
    return graphics.penARGB(0xFF, red, green, blue);
}

/// The colour a step on, each part turning round at its ends.
fn walk(app: *App) void {
    _ = bounce(&app.red, &app.dred, 128);
    _ = bounce(&app.green, &app.dgreen, 128);
    _ = bounce(&app.blue, &app.dblue, 128);
}

/// A number from 0 to `upto` - 1, from where the pointer was and what has
/// been asked for: the figure starts somewhere else each time.
fn random(app: *App, upto: u32) u32 {
    if (upto == 0) return 0;
    if (app.seed == 0) app.seed = 0x1357_9BDF ^ watch.quiet ^ app.drawn;
    app.seed = app.seed *% 1_103_515_245 +% 12345;
    return (app.seed >> 16) % upto;
}

// --- the network ---------------------------------------------------------------------

/// One event looked at: the quiet counted on each tick, and anything else
/// as a sign of life. On input.device's task, inside the network: it may
/// not wait, so it only counts and signals.
fn quiet(cb: *CxBase, cxm: *cx.CxMsg, _: *cx.CxObj) callconv(.c) void {
    const event = cb.CxMsgData(cxm) orelse return;
    const held = ie.IEQUALIFIER_LEFTBUTTON | ie.IEQUALIFIER_MIDBUTTON | ie.IEQUALIFIER_RBUTTON;
    if (event.class == ie.IECLASS_TIMER) {
        if (watch.dark) return;
        // A button held is someone at work, however still it is.
        if (event.qualifier & held != 0) {
            watch.quiet = 0;
            return;
        }
        watch.quiet += 1;
        if (watch.quiet < watch.limit or watch.asked == .blank) return;
        watch.asked = .blank;
        signalTask();
        return;
    }
    watch.quiet = 0;
    if (!watch.dark) return;
    if (watch.asked != .unblank) {
        watch.asked = .unblank;
        signalTask();
    }
    // The stroke that wakes the screen does nothing else: a key or a
    // button press is taken out of the stream, while a move or a finger
    // lifted goes on to whatever was waiting for it.
    const press = (event.class == ie.IECLASS_RAWKEY or event.class == ie.IECLASS_RAWMOUSE) and
        event.code & ie.IECODE_UP_PREFIX == 0;
    if (press) cb.DisposeCxMsg(cxm);
}

fn signalTask() void {
    const sys = watch.sys orelse return;
    sys.Signal(watch.task orelse return, watch.mask);
}

// --- the window ----------------------------------------------------------------------

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

/// A gadget let go: a setting changed, which holds from now on.
fn gadget(app: *App, id: usize, code: u32) void {
    switch (id) {
        ID_SECONDS => {
            app.asked.seconds = @max(least_seconds, @min(most_seconds, @as(i32, @bitCast(code))));
            watch.limit = @as(u32, @intCast(app.asked.seconds)) * ticks_a_second;
            watch.quiet = 0;
        },
        ID_CYCLE => app.asked.cycle_colors = code != 0,
        ID_ANIMATION => app.asked.animation = code != 0,
        else => return,
    }
    // What is drawn has changed under the screen that is up: start again
    // from black, and let the panel follow.
    if (app.dark != null and id != ID_SECONDS) {
        if (drawing(app)) bright(app) else dim(app);
        paint(app, 0xFF00_0000);
        begin(app);
    }
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
    // The menu is how the window is hidden or the Blanker ended from the
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
    const seconds = ib.NewObjectTagList(null, ig.INTEGER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_SECONDS },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = ig.INTEGER_Min, .data = least_seconds },
        .{ .tag = ig.INTEGER_Max, .data = most_seconds },
        .{ .tag = ig.INTEGER_Number, .data = @as(usize, @intCast(app.asked.seconds)) },
        .{},
    });
    const cycle = box(ib, ID_CYCLE, app.asked.cycle_colors);
    const animation = box(ib, ID_ANIMATION, app.asked.animation);
    const layout = if (seconds != null and cycle != null and animation != null)
        ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT },
            .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(seconds) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Seconds until it blanks") },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(cycle) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Cycle colours") },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(animation) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Animation") },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{},
        })
    else
        null;
    const made = layout orelse {
        ib.DisposeObject(seconds);
        ib.DisposeObject(cycle);
        ib.DisposeObject(animation);
        return null;
    };

    const place = app.place;
    const at = place orelse Place{};
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr(COMMAND_NAME) },
        .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr(SCREEN_TITLE) },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = if (place != null) wn.WA_Left else utility.TAG_IGNORE, .data = at.left },
        .{ .tag = if (place != null) wn.WA_Top else utility.TAG_IGNORE, .data = at.top },
        .{ .tag = if (place != null) wn.WA_Width else wn.WA_InnerWidth, .data = if (place != null) at.width else 280 },
        .{ .tag = if (place != null) wn.WA_Height else wn.WA_InnerHeight, .data = if (place != null) at.height else 120 },
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
        .seconds = seconds.?,
        .cycle = cycle.?,
        .animation = animation.?,
    };
}

fn box(ib: *IntuitionBase, id: usize, ticked: bool) ?*Object {
    return ib.NewObjectTagList(null, cbox.CHECKBOX_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = cbox.CHECKBOX_Checked, .data = @intFromBool(ticked) },
        .{},
    });
}

fn windowSignal(ib: *IntuitionBase, object: *Object) u32 {
    var mask: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_SigMask, object, &mask);
    return @truncate(mask);
}
