// SPDX-License-Identifier: MIT
//! The desktop's process: what it holds, how it comes up and goes, and
//! the one Wait it spends its life in.
//!
//! **What it holds** is one block (`Desktop`), made by StartAnvil and
//! freed by the process as it ends: the libraries it draws with, the
//! Workbench screen (locked, so it stays), the backdrop window under the
//! screen's bar, the ground, the icons on it, and the ports it waits on.
//!
//! **Its ports**: one that every window of the desktop shares
//! (`WA_UserPort`), so a message says by its `window` which it is for;
//! one for the notifications of the files it follows; one its own
//! requests come back to - the clock's two-second tick, which brings the
//! free memory in the title up to date and looks for disks that came or
//! went; and one the programs' replies to its messages come back to. A
//! signal of its own tells it a program added or removed something
//! (`app.zig`).
//!
//! **It draws with the window's layer held** (`holdRoot`, and a
//! drawer's own): another window moved meanwhile would rebuild the list
//! of places a drawing call walks. Only graphics is called while it is
//! held - intuition takes its own lock before a layer's.
//!
//! **It follows** `ENV:Sys/anvil.prefs` and `ENV:Sys/font.prefs`
//! (StartNotify), and the screen's pens (`IDCMP_NEWPREFS`): a change
//! makes the ground and the icons anew and draws them again.
//!
//! **Once it is up** it starts the programs of its startup drawer
//! (`startup.zig`), and goes on answering while it waits for them.
//!
//! **It ends** when Quit is picked, nothing it started still runs and no
//! program has anything added to it, or on CTRL-C: what programs added
//! is let go of, everything goes in the reverse of the order it came,
//! and the library is closed by dos once the process's code has
//! returned.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const utility = sdk.utility;
const icon = sdk.icon;
const timer = sdk.devices.timer;
const anvil_prefs = sdk.prefs.anvil;
const font_prefs = sdk.prefs.font;
const notify = dos.notify;
const wn = intuition.windows;
const sc = intuition.screens;
const mn = intuition.menus;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const IconBase = sdk.interface.icon.IconBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const TagItem = utility.TagItem;
const Rect = graphics.Rect;
const Pen = graphics.Pen;
const _base = @import("../anvil_base.zig");
const AnvilBase = _base.AnvilBase;
const anvil_init = @import("../anvil_init.zig");
const icons = @import("../icons/_icons.zig");
const Icon = icons.Icon;
const ground_area = @import("ground.zig");
const volumes = @import("volumes.zig");
const title_text = @import("title.zig");
const menus = @import("menus.zig");
const drawer = @import("../drawer/_drawer.zig");
const Drawer = drawer.Drawer;
const drawer_path = @import("../drawer/path.zig");
const select = @import("select.zig");
const drag = @import("drag.zig");
const commands = @import("commands.zig");
const run_area = @import("run.zig");
const app_area = @import("app.zig");
const startup_area = @import("startup.zig");

/// How often the title and the disks are looked at, in seconds.
pub const tick_seconds = 2;

/// The IDCMP classes every desktop window takes. The pointer's moves come
/// only while a box is being drawn (ReportMouse).
const backdrop_idcmp = wn.IDCMP_MOUSEBUTTONS | wn.IDCMP_MOUSEMOVE | wn.IDCMP_MENUPICK | wn.IDCMP_REFRESHWINDOW |
    wn.IDCMP_DISKINSERTED | wn.IDCMP_DISKREMOVED | wn.IDCMP_NEWPREFS | wn.IDCMP_ACTIVEWINDOW | wn.IDCMP_NEWSIZE;

/// Which library is which in `libraries`.
const Lib = enum(u3) { intuition, graphics, utility, icon, layers, datatypes, diskfont, scroller };

/// What a message from a window said, copied before it is replied.
pub const Said = struct {
    class: u32,
    code: u32,
    qualifier: u32,
    x: i32,
    y: i32,
    seconds: u32,
    micros: u32,
    window: ?*intuition.Window,
    /// An update from a gadget: its ID and where its bar is.
    gadget: u32 = 0,
    top: i32 = 0,
};

pub const Desktop = struct {
    base: *AnvilBase,
    sys: *ExecBase,
    dl: *DosBase,
    /// The disks' icons placed anew (`ANVA_CleanUp`).
    clean_up: bool = false,

    // StartAnvil waits for the word that the desktop is up, or why not.
    starter: ?*exec.Task = null,
    start_signal: u5 = 0,
    start_error: i32 = 0,

    libraries: [8]?*exec.Library = @splat(null),
    ib: *IntuitionBase = undefined,
    gb: *GraphicsBase = undefined,
    ub: *UtilityBase = undefined,
    icon_base: *IconBase = undefined,
    lb: *sdk.interface.layers.LayersBase = undefined,
    dt: ?*DataTypesBase = null,
    df: ?*DiskfontBase = null,
    /// Whether drawers have scroll bars: scroller.gadget opened.
    has_scroller: bool = false,
    /// The signal the desktop gives itself while a drawer is still being
    /// read, so its loop goes on between pieces.
    read_signal: i8 = -1,

    windows_port: ?*exec.MsgPort = null,
    notify_port: ?*exec.MsgPort = null,
    reply_port: ?*exec.MsgPort = null,
    clock: timer.TimeRequest = undefined,
    clock_open: bool = false,
    clock_out: bool = false,
    /// How many times the clock has ticked: what waits are counted in.
    ticks: u32 = 0,
    /// The startup drawer, while its programs are being started.
    startup: ?*startup_area.Startup = null,

    screen: ?*intuition.Screen = null,
    screen_width: i32 = 0,
    screen_height: i32 = 0,
    bar_height: i32 = 0,
    /// The screen's background pen: the ground when the prefs give none.
    background: Pen = 0xFFAA_AAAA,

    /// The desktop's own window: a backdrop across the screen, or with
    /// Backdrop off an ordinary window holding the disks.
    backdrop: ?*intuition.Window = null,
    backdrop_rp: *graphics.RastPort = undefined,
    /// Its layer, held while anything is drawn into it.
    backdrop_layer: *sdk.layers.Layer = undefined,
    as_backdrop: bool = true,
    /// Where its inside starts in it: nothing as a backdrop, its borders
    /// as a window. The messages' points are made the inside's on arrival.
    root_offset: icons.Origin = .{},
    /// The desktop's window that is active, if one is.
    active_window: ?*intuition.Window = null,
    width: i32 = 0,
    height: i32 = 0,
    menu_strip: ?*intuition.Menu = null,

    prefs: anvil_prefs.Settings = .{},
    /// The ground, which the backfill hook paints from on any task: it is
    /// swapped for a new one under `ground_lock`.
    ground: ?*ground_area.Ground = null,
    ground_lock: exec.SignalSemaphore = .{},
    ground_hook: utility.Hook = .{},

    look: icons.Look = .{},
    /// How icons and rows look in a drawer's window: the screen's text
    /// pen on the window's own ground, no shadow.
    drawer_look: icons.Look = .{},
    /// The names' font when the desktop opened one; the screen's otherwise.
    own_font: ?*graphics.TextFont = null,
    pictures: icons.picture.Pictures = .{},
    /// The disks' icons, and the drawers open.
    volumes: exec.List = .{},
    drawers: exec.List = .{},
    /// The last press on an icon, for a double click.
    last_icon: ?*Icon = null,
    last_tap: intuition.Tap = .{},
    /// The box being drawn round icons, while the button is held.
    band: ?select.Band = null,
    /// An icon held, and perhaps dragged, while the button is held.
    held: ?drag.Held = null,
    /// What the desktop last said in the screen's title, and for how many
    /// more ticks the title says it instead of the memory.
    message: [96:0]u8 = @splat(0),
    message_ticks: u8 = 0,
    seen: [volumes.max_volumes]volumes.Seen = undefined,

    /// `anvil.prefs` and `font.prefs`, followed.
    watching: [2]notify.NotifyRequest = @splat(.{}),
    watched: [2]bool = @splat(false),

    title: [96:0]u8 = @splat(0),
    /// Programs it started that still run.
    running: u32 = 0,
    /// What programs add: the signal the desktop is told with, the port
    /// their replies come to and how many are still out, and the Tools
    /// menu's items.
    app_signal: i8 = -1,
    app_replies: ?*exec.MsgPort = null,
    app_out: u32 = 0,
    tools: app_area.Tools = .{},
    quit: bool = false,

    // --- coming up -------------------------------------------------------

    /// Everything the desktop needs, in order; 0, or the dos error that
    /// stopped it (whatever came before it is still held, for `tearDown`).
    fn setUp(d: *Desktop) i32 {
        const sys = d.sys;
        d.volumes.init(.unknown);
        d.drawers.init(.unknown);
        d.pictures.init();
        d.read_signal = sys.AllocSignal(-1);
        if (d.read_signal < 0) return dos.ERROR_NO_FREE_STORE;
        sys.InitSemaphore(&d.ground_lock);
        d.ground_hook = .{ .entry = &paintGround, .data = d };

        d.ib = @ptrCast(d.open(.intuition, intuition.INTUITIONNAME, 0) orelse return dos.ERROR_INVALID_RESIDENT_LIBRARY);
        d.gb = @ptrCast(d.open(.graphics, graphics.GRAPHICSNAME, 0) orelse return dos.ERROR_INVALID_RESIDENT_LIBRARY);
        d.ub = @ptrCast(d.open(.utility, sdk.interface.utility.NAME, 0) orelse return dos.ERROR_INVALID_RESIDENT_LIBRARY);
        d.icon_base = @ptrCast(d.open(.icon, icon.ICONNAME, 1) orelse return dos.ERROR_INVALID_RESIDENT_LIBRARY);
        d.lb = @ptrCast(d.open(.layers, sdk.layers.LAYERSNAME, 0) orelse return dos.ERROR_INVALID_RESIDENT_LIBRARY);
        // A picture and a font of the prefs' choosing: without either
        // library the desktop still comes up, with a colour and the
        // screen's font.
        d.dt = @ptrCast(d.open(.datatypes, sdk.datatypes.DATATYPESNAME, 0));
        d.df = @ptrCast(d.open(.diskfont, sdk.diskfont.DISKFONTNAME, 0));
        d.has_scroller = d.open(.scroller, sdk.gadgets.scroller.SCROLLER_LIBRARY, 0) != null;

        d.windows_port = sys.CreateMsgPort() orelse return dos.ERROR_NO_FREE_STORE;
        d.notify_port = sys.CreateMsgPort() orelse return dos.ERROR_NO_FREE_STORE;
        d.reply_port = sys.CreateMsgPort() orelse return dos.ERROR_NO_FREE_STORE;
        d.clock = .{ .node = .{ .message = .{ .reply_port = d.reply_port, .length = @sizeOf(timer.TimeRequest) } } };
        if (sys.OpenDevice(timer.TIMERNAME, timer.UNIT_VBLANK, &d.clock.node, 0) != 0) return dos.ERROR_INVALID_RESIDENT_LIBRARY;
        d.clock_open = true;
        if (!app_area.setUp(d)) return dos.ERROR_NO_FREE_STORE;

        d.screen = d.ib.LockPubScreen(null) orelse return dos.ERROR_OBJECT_NOT_FOUND;
        d.measureScreen();

        d.readPrefs();
        d.ground = d.makeGround();
        if (!d.openBackdrop()) return dos.ERROR_NO_FREE_STORE;
        d.readFont();
        d.makeLook();
        d.setMenus();
        d.updateTitle();
        volumes.scan(d);
        d.follow();
        d.tickLater();
        return 0;
    }

    fn open(d: *Desktop, which: Lib, name: [*:0]const u8, version: u32) ?*exec.Library {
        const lib = d.sys.OpenLibrary(name, version) orelse return null;
        d.libraries[@intFromEnum(which)] = lib;
        return lib;
    }

    /// The screen's size, its bar, and its background pen.
    fn measureScreen(d: *Desktop) void {
        const screen = d.screen.?;
        var width: usize = 0;
        var height: usize = 0;
        var bar: usize = 0;
        d.ib.GetScreenAttrs(screen, &[_]TagItem{
            .{ .tag = sc.SA_Width, .data = @intFromPtr(&width) },
            .{ .tag = sc.SA_Height, .data = @intFromPtr(&height) },
            .{ .tag = sc.SA_BarHeight, .data = @intFromPtr(&bar) },
            .{},
        });
        d.screen_width = @intCast(width);
        d.screen_height = @intCast(height);
        d.bar_height = @intCast(bar);
        const draw_info = d.ib.GetScreenDrawInfo(screen);
        d.background = draw_info.pens[sc.BACKGROUNDPEN];
        d.ib.FreeScreenDrawInfo(screen, draw_info);
    }

    /// The desktop's window: the whole screen under its bar - a borderless
    /// backdrop, or with Backdrop off an ordinary window of the same box
    /// with its title, gadgets and an inside of its own - painted by the
    /// ground's hook, on the shared port.
    fn openBackdrop(d: *Desktop) bool {
        const top = d.bar_height + 1;
        const plain: usize = @intFromBool(!d.as_backdrop);
        const window = d.ib.OpenWindowTagList(&[_]TagItem{
            .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(d.screen) },
            .{ .tag = wn.WA_Left, .data = 0 },
            .{ .tag = wn.WA_Top, .data = @intCast(top) },
            .{ .tag = wn.WA_Width, .data = @intCast(d.screen_width) },
            .{ .tag = wn.WA_Height, .data = @intCast(d.screen_height - top) },
            .{ .tag = wn.WA_Backdrop, .data = 1 - plain },
            .{ .tag = wn.WA_Borderless, .data = 1 - plain },
            .{ .tag = if (plain != 0) wn.WA_Title else utility.TAG_IGNORE, .data = @intFromPtr("Anvil") },
            .{ .tag = wn.WA_DragBar, .data = plain },
            .{ .tag = wn.WA_DepthGadget, .data = plain },
            .{ .tag = wn.WA_SizeGadget, .data = plain },
            .{ .tag = wn.WA_GimmeZeroZero, .data = plain },
            .{ .tag = wn.WA_MinWidth, .data = 160 },
            .{ .tag = wn.WA_MinHeight, .data = 100 },
            .{ .tag = wn.WA_SimpleRefresh, .data = 1 },
            .{ .tag = if (d.ground != null) wn.WA_BackFill else utility.TAG_IGNORE, .data = @intFromPtr(&d.ground_hook) },
            .{ .tag = wn.WA_NewLookMenus, .data = 1 },
            .{ .tag = wn.WA_Activate, .data = 1 },
            .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr(&d.title) },
            .{ .tag = wn.WA_UserPort, .data = @intFromPtr(d.windows_port) },
            .{ .tag = wn.WA_IDCMP, .data = backdrop_idcmp },
            .{},
        }) orelse return false;
        d.backdrop = window;
        var rp: usize = 0;
        d.ib.GetWindowAttrs(window, &[_]TagItem{ .{ .tag = wn.WA_RastPort, .data = @intFromPtr(&rp) }, .{} });
        d.backdrop_rp = @ptrFromInt(rp);
        var layer: usize = 0;
        d.ib.GetWindowAttrs(window, &[_]TagItem{ .{ .tag = wn.WA_Layer, .data = @intFromPtr(&layer) }, .{} });
        d.backdrop_layer = @ptrFromInt(layer);
        d.measureRoot();
        return true;
    }

    /// The root window's inside: its size and where it starts.
    fn measureRoot(d: *Desktop) void {
        const window = d.backdrop orelse return;
        var values: [6]usize = @splat(0);
        const tags = [_]utility.Tag{ wn.WA_Width, wn.WA_Height, wn.WA_BorderLeft, wn.WA_BorderTop, wn.WA_BorderRight, wn.WA_BorderBottom };
        for (tags, &values) |tag, *value| d.ib.GetWindowAttrs(window, &[_]TagItem{ .{ .tag = tag, .data = @intFromPtr(value) }, .{} });
        const v: [6]i32 = .{ @intCast(values[0]), @intCast(values[1]), @intCast(values[2]), @intCast(values[3]), @intCast(values[4]), @intCast(values[5]) };
        if (d.as_backdrop) {
            d.root_offset = .{};
            d.width = v[0];
            d.height = v[1];
        } else {
            d.root_offset = .{ .x = v[2], .y = v[3] };
            d.width = v[0] - v[2] - v[4];
            d.height = v[1] - v[3] - v[5];
        }
    }

    /// Backdrop: the desktop's window made the other kind - closed and
    /// opened again, its icons where they were.
    fn toggleBackdrop(d: *Desktop) void {
        const old = d.backdrop orelse return;
        d.letGoOfRoot();
        if (d.menu_strip != null) d.ib.ClearMenuStrip(old);
        d.ib.CloseWindow(old);
        d.backdrop = null;
        d.as_backdrop = !d.as_backdrop;
        if (!d.openBackdrop()) {
            d.as_backdrop = !d.as_backdrop;
            if (!d.openBackdrop()) {
                d.quit = true;
                return;
            }
        }
        if (d.menu_strip) |strip| _ = d.ib.SetMenuStrip(d.backdrop.?, strip);
        d.updateTitle();
        d.drawWhole();
    }

    /// A drag or a box in the desktop's own window given up.
    fn letGoOfRoot(d: *Desktop) void {
        const window = d.backdrop orelse return;
        if (d.held) |held| if (held.window == window) drag.forget(d, window);
        if (d.band) |band| if (band.window == window) {
            d.band = null;
        };
        d.last_icon = null;
    }

    /// A point of a window of the desktop's, as the inside's own: a
    /// point of the screen.
    pub fn screenOf(d: *Desktop, window: *intuition.Window, x: i32, y: i32) icons.Origin {
        var left: usize = 0;
        var top: usize = 0;
        d.ib.GetWindowAttrs(window, &[_]TagItem{ .{ .tag = wn.WA_Left, .data = @intFromPtr(&left) }, .{ .tag = wn.WA_Top, .data = @intFromPtr(&top) }, .{} });
        var at = icons.Origin{ .x = @as(i32, @intCast(left)) + x, .y = @as(i32, @intCast(top)) + y };
        if (window == d.backdrop) {
            at.x += d.root_offset.x;
            at.y += d.root_offset.y;
        }
        return at;
    }

    /// A point of the screen as a point of a desktop window, the way its
    /// messages give them: the root window's inside's own.
    pub fn windowPoint(d: *Desktop, window: *intuition.Window, x: i32, y: i32) icons.Origin {
        const corner = d.screenOf(window, 0, 0);
        return .{ .x = x - corner.x, .y = y - corner.y };
    }

    fn setMenus(d: *Desktop) void {
        const made = d.makeMenus() orelse return;
        if (!d.ib.SetMenuStrip(d.backdrop.?, made)) {
            d.ib.FreeMenus(made);
            return;
        }
        d.menu_strip = made;
    }

    /// The strip made and laid out: the desktop's menus, and Tools with
    /// the programs' items.
    fn makeMenus(d: *Desktop) ?*intuition.Menu {
        var entries: [menus.table.len + 1 + app_area.tools_max]mn.NewMenu = undefined;
        var labels: [app_area.tools_max][*:0]const u8 = undefined;
        for (0..d.tools.count) |i| labels[i] = &d.tools.labels[i];
        const made = d.ib.CreateMenusA(menus.build(&entries, labels[0..d.tools.count]).ptr, null) orelse return null;
        if (!d.ib.LayoutMenusA(made, d.screen.?, null)) {
            d.ib.FreeMenus(made);
            return null;
        }
        return made;
    }

    /// The Tools items changed: the strip made again and put on every
    /// window of the desktop in place of the old one.
    pub fn renewMenus(d: *Desktop) void {
        const made = d.makeMenus() orelse return;
        const old = d.menu_strip;
        if (old != null) {
            if (d.backdrop) |window| d.ib.ClearMenuStrip(window);
            var it = d.drawers.iterator();
            while (it.next()) |node| d.ib.ClearMenuStrip(@as(*Drawer, @alignCast(@fieldParentPtr("node", node))).window);
        }
        d.menu_strip = made;
        if (d.backdrop) |window| _ = d.ib.SetMenuStrip(window, made);
        var it = d.drawers.iterator();
        while (it.next()) |node| _ = d.ib.SetMenuStrip(@as(*Drawer, @alignCast(@fieldParentPtr("node", node))).window, made);
        if (old) |strip| d.ib.FreeMenus(strip);
        commands.rethink(d, d.active_window);
    }

    // --- the prefs ---------------------------------------------------------

    /// `anvil.prefs` read; a file that is not there, or says something
    /// wrong, leaves the desktop's own.
    fn readPrefs(d: *Desktop) void {
        var text: [1024]u8 = undefined;
        var settings: anvil_prefs.Settings = .{};
        if (sdk.prefs.load(d.dl, anvil_prefs.ENV_FILE, &text)) |read| {
            if (sdk.prefs.firstLine(read)) |line| {
                if (anvil_prefs.parse(line, &settings) != null) settings = .{};
            }
        }
        d.prefs = settings;
    }

    /// The names' font: `font.prefs`'s ICON, else its DEFAULT, else the
    /// screen's.
    fn readFont(d: *Desktop) void {
        if (d.own_font) |font| d.gb.CloseFont(font);
        d.own_font = null;
        const df = d.df orelse return;
        var text: [512]u8 = undefined;
        const read = sdk.prefs.load(d.dl, font_prefs.ENV_FILE, &text) orelse return;
        const words = sdk.prefs.firstLine(read) orelse return;
        var line: font_prefs.Line = .{};
        if (font_prefs.parse(words, &line) != null) return;
        const given = line.get(.icon) orelse line.get(.default) orelse return;
        var family: [font_prefs.value_len:0]u8 = undefined;
        const wanted = font_prefs.attrOf(given, &family) orelse return;
        d.own_font = df.OpenDiskFont(&wanted);
    }

    /// How icons look on this screen with these prefs: the picture no
    /// larger than an eighth of the screen's height, a cell twice its
    /// width, the names in the font's height under it, black on a light
    /// ground and white on a dark one.
    fn makeLook(d: *Desktop) void {
        const rp = d.backdrop_rp;
        var font = d.own_font;
        if (font == null) {
            const draw_info = d.ib.GetScreenDrawInfo(d.screen.?);
            font = draw_info.font;
            d.ib.FreeScreenDrawInfo(d.screen.?, draw_info);
        }
        if (font) |chosen| d.gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(chosen) }, .{} });
        var font_height: usize = 8;
        var baseline: usize = 6;
        d.gb.GetRPAttrs(rp, &[_]TagItem{
            .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&font_height) },
            .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
            .{},
        });
        const size: u32 = @min(d.prefs.icon_size, @max(24, @as(u32, @intCast(d.screen_height)) / 8));
        const light = if (d.ground) |g| g.light else ground_area.isLight(d.background);
        d.look = .{
            .font = font,
            .font_height = @intCast(font_height),
            .baseline = @intCast(baseline),
            .icon_size = size,
            .cell = .{ .width = @intCast(size * 2), .height = @as(i32, @intCast(size)) + 2 + @as(i32, @intCast(font_height)) + 10 },
            .text = if (light) 0xFF00_0000 else 0xFFFF_FFFF,
            .shadow = if (light) 0xFFFF_FFFF else 0xFF00_0000,
        };
        const draw_info = d.ib.GetScreenDrawInfo(d.screen.?);
        d.look.fill = draw_info.pens[sc.FILLPEN];
        d.look.fill_text = draw_info.pens[sc.FILLTEXTPEN];
        d.drawer_look = d.look;
        d.drawer_look.text = draw_info.pens[sc.TEXTPEN];
        d.drawer_look.shadow = null;
        d.ib.FreeScreenDrawInfo(d.screen.?, draw_info);
    }

    fn makeGround(d: *Desktop) ?*ground_area.Ground {
        var friend: usize = 0;
        d.ib.GetScreenAttrs(d.screen.?, &[_]TagItem{ .{ .tag = sc.SA_RastPort, .data = @intFromPtr(&friend) }, .{} });
        const height = d.screen_height - d.bar_height - 1;
        return ground_area.make(d.groundLibs(), &d.prefs, d.screen_width, height, @ptrFromInt(friend), d.background);
    }

    fn groundLibs(d: *Desktop) ground_area.Libs {
        return .{ .sys = d.sys, .gb = d.gb, .dt = d.dt };
    }

    /// The prefs, the font or the pens changed: the ground and the icons
    /// made anew, and the whole desktop drawn again.
    fn renew(d: *Desktop) void {
        d.readPrefs();
        d.readFont();
        if (d.makeGround()) |fresh| {
            d.sys.ObtainSemaphore(&d.ground_lock);
            const old = d.ground;
            d.ground = fresh;
            d.sys.ReleaseSemaphore(&d.ground_lock);
            ground_area.free(d.groundLibs(), old);
        }
        d.makeLook();
        volumes.forgetAll(d);
        d.drawWhole();
        volumes.scan(d);
        app_area.showAgain(d);
    }

    /// StartNotify on the two files, a message each when it changes.
    fn follow(d: *Desktop) void {
        const names = [2][*:0]const u8{ anvil_prefs.ENV_FILE, font_prefs.ENV_FILE };
        for (&d.watching, names, 0..) |*request, name, i| {
            request.* = .{ .name = name, .flags = notify.NRF_SEND_MESSAGE, .port = d.notify_port };
            d.watched[i] = d.dl.StartNotify(request);
        }
    }

    // --- drawing -------------------------------------------------------------

    /// The desktop's own window's layer held, for drawing into it; a
    /// holder may take it again.
    pub fn holdRoot(d: *Desktop) void {
        d.lb.LockLayer(d.backdrop_layer);
    }

    pub fn releaseRoot(d: *Desktop) void {
        d.lb.UnlockLayer(d.backdrop_layer);
    }

    /// Every icon drawn through the backdrop's RastPort.
    pub fn drawIcons(d: *Desktop) void {
        d.holdRoot();
        defer d.releaseRoot();
        var it = d.volumes.iterator();
        while (it.next()) |node| {
            const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
            ic.draw(d.gb, d.backdrop_rp, &d.look, .{});
        }
    }

    /// The ground painted over the whole backdrop, and the icons on it.
    pub fn drawWholeNow(d: *Desktop) void {
        d.drawWhole();
    }

    fn drawWhole(d: *Desktop) void {
        d.holdRoot();
        defer d.releaseRoot();
        const whole = Rect{ .min_x = 0, .min_y = 0, .max_x = d.width, .max_y = d.height };
        d.gb.EraseRect(d.backdrop_rp, &whole);
        d.drawIcons();
    }

    /// `area` of the backdrop painted again: the ground, then every icon
    /// that reaches into it.
    pub fn drawArea(d: *Desktop, area: Rect) void {
        d.holdRoot();
        defer d.releaseRoot();
        d.gb.EraseRect(d.backdrop_rp, &area);
        var it = d.volumes.iterator();
        while (it.next()) |node| {
            const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
            const b = ic.box(&d.look);
            if (b.min_x < area.max_x and area.min_x < b.max_x and b.min_y < area.max_y and area.min_y < b.max_y) {
                ic.draw(d.gb, d.backdrop_rp, &d.look, .{});
            }
        }
    }

    fn updateTitle(d: *Desktop) void {
        // A message stays for its few ticks.
        if (d.message_ticks != 0) {
            d.message_ticks -= 1;
            if (d.message_ticks != 0) return;
        }
        const internal = d.sys.AvailMem(exec.MEMF_INTERNAL);
        const external = d.sys.AvailMem(exec.MEMF_EXTERNAL);
        _ = title_text.memoryTitle(&d.title, internal, external);
        if (d.backdrop) |window| d.ib.SetWindowTitles(window, wn.TITLE_UNCHANGED, &d.title);
        var it = d.drawers.iterator();
        while (it.next()) |node| {
            const dr: *Drawer = @alignCast(@fieldParentPtr("node", node));
            d.ib.SetWindowTitles(dr.window, wn.TITLE_UNCHANGED, &d.title);
        }
    }

    // --- the loop --------------------------------------------------------------

    fn run(d: *Desktop) void {
        const sys = d.sys;
        const windows = d.windows_port.?.sigMask();
        const notes = d.notify_port.?.sigMask();
        const replies = d.reply_port.?.sigMask();
        const more = @as(u32, 1) << @intCast(d.read_signal);
        const apps = @as(u32, 1) << @intCast(d.app_signal);
        const app_replies = d.app_replies.?.sigMask();
        while (!d.quit) {
            const got = sys.Wait(windows | notes | replies | more | apps | app_replies | exec.SIGBREAKF_CTRL_C);
            // CTRL-C quits without asking - but not while a program it
            // started runs, whose end comes back to the desktop's port.
            if (got & exec.SIGBREAKF_CTRL_C != 0) {
                if (d.running == 0) d.quit = true else d.say("Programs started from the desktop still run");
            }
            if (got & replies != 0) d.replied();
            if (got & app_replies != 0) app_area.replied(d);
            if (got & apps != 0) app_area.changed(d);
            if (got & notes != 0) d.notified();
            if (got & windows != 0) d.windowMessages();
            // A piece of every drawer still being read, and the loop
            // woken again at once while any has more.
            if (got & more != 0 and drawer.readSome(d)) d.readingMore();
        }
    }

    /// The loop told to go round again at once: a drawer has more to read.
    pub fn readingMore(d: *Desktop) void {
        d.sys.Signal(d.sys.FindTask(null).?, @as(u32, 1) << @intCast(d.read_signal));
    }

    fn windowMessages(d: *Desktop) void {
        const port = d.windows_port.?;
        while (d.sys.GetMsg(port)) |message| {
            const im: *wn.IntuiMessage = @ptrCast(@alignCast(message));
            var said = Said{
                .class = im.class,
                .code = im.code,
                .qualifier = im.qualifier,
                .x = im.mouse_x,
                .y = im.mouse_y,
                .seconds = im.seconds,
                .micros = im.micros,
                .window = im.window,
            };
            // The desktop's own window as its inside: its points the
            // inside's.
            if (said.window != null and said.window == d.backdrop) {
                said.x -= d.root_offset.x;
                said.y -= d.root_offset.y;
            }
            // An update's tags are the message's: read before it goes.
            if (said.class == wn.IDCMP_IDCMPUPDATE) {
                const tags: ?[*]const TagItem = @ptrCast(@alignCast(im.iaddress));
                said.gadget = @truncate(d.ub.GetTagData(intuition.gadgetclass.GA_ID, 0, tags));
                said.top = @bitCast(@as(u32, @truncate(d.ub.GetTagData(sdk.gadgets.scroller.SCROLLER_Top, 0, tags))));
            }
            // A refresh is answered between BeginRefresh and EndRefresh
            // before the message goes back, as intuition asks.
            if (said.class == wn.IDCMP_REFRESHWINDOW) d.refresh(said.window);
            d.sys.ReplyMsg(message);
            d.handle(said);
        }
    }

    fn refresh(d: *Desktop, window: ?*intuition.Window) void {
        if (drawer.find(d, window)) |dr| return drawer.refresh(d, dr);
        const backdrop = d.backdrop orelse return;
        if (window != backdrop) return;
        // Painted first: what is reported uncovered may already have icons
        // drawn in it, and a name drawn twice comes out heavier.
        d.ib.BeginRefresh(backdrop);
        d.holdRoot();
        d.gb.EraseRect(d.backdrop_rp, &.{ .min_x = 0, .min_y = 0, .max_x = d.width, .max_y = d.height });
        d.drawIcons();
        d.releaseRoot();
        d.ib.EndRefresh(backdrop, true);
    }

    fn handle(d: *Desktop, said: Said) void {
        const in_drawer = drawer.find(d, said.window);
        switch (said.class) {
            wn.IDCMP_MENUPICK => d.picked(said.window, said.code),
            wn.IDCMP_CLOSEWINDOW => if (in_drawer) |dr| drawer.close(d, dr),
            wn.IDCMP_NEWSIZE => if (in_drawer) |dr| drawer.resized(d, dr) else if (said.window == d.backdrop) {
                d.measureRoot();
                d.drawWhole();
            },
            wn.IDCMP_IDCMPUPDATE => if (in_drawer) |dr| drawer.scrolled(d, dr, said.gadget, said.top),
            wn.IDCMP_ACTIVEWINDOW => d.active_window = said.window,
            wn.IDCMP_MOUSEBUTTONS => switch (said.code) {
                wn.SELECTDOWN => select.press(d, said, in_drawer),
                wn.SELECTUP => {
                    select.released(d);
                    drag.released(d, said);
                },
                else => {},
            },
            wn.IDCMP_MOUSEMOVE => {
                select.moved(d, said);
                drag.moved(d, said);
            },
            wn.IDCMP_DISKINSERTED, wn.IDCMP_DISKREMOVED => volumes.scan(d),
            wn.IDCMP_NEWPREFS => {
                const was = d.background;
                d.measureScreen();
                if (d.background != was and !d.prefs.ground_given) d.renew();
            },
            else => {},
        }
        // What the menus may do depends on the window and what is picked.
        switch (said.class) {
            wn.IDCMP_MOUSEBUTTONS, wn.IDCMP_MENUPICK, wn.IDCMP_ACTIVEWINDOW => commands.rethink(d, d.active_window),
            else => {},
        }
    }

    /// Redraw All: the desktop and every drawer drawn again.
    fn redrawAll(d: *Desktop) void {
        d.drawWhole();
        var it = d.drawers.iterator();
        while (it.next()) |node| drawer.drawInside(d, @alignCast(@fieldParentPtr("node", node)));
    }

    /// Update All: the disks looked at and every drawer read again.
    fn updateAll(d: *Desktop) void {
        volumes.scan(d);
        var it = d.drawers.iterator();
        while (it.next()) |node| drawer.reread(d, @alignCast(@fieldParentPtr("node", node)));
    }

    /// Last Message: the last thing the desktop said, said again.
    fn lastMessage(d: *Desktop) void {
        if (d.message[0] == 0) return d.say("Nothing has been said");
        var again: [96]u8 = undefined;
        var length: usize = 0;
        while (d.message[length] != 0) : (length += 1) again[length] = d.message[length];
        d.say(again[0..length]);
    }

    /// A drawer's icons about to go - it closes, or is read again: nothing
    /// the desktop holds points at them any more, and a drag or a box in
    /// its window is given up.
    pub fn letGoOf(d: *Desktop, dr: *Drawer) void {
        if (d.held) |held| if (held.drawer == dr) drag.forget(d, held.window);
        if (d.band) |band| if (band.drawer == dr) {
            d.band = null;
            d.ib.ReportMouse(band.window, false);
        };
        d.last_icon = null;
    }

    /// Whether the file `path` is left out on the desktop.
    pub fn isLeftOut(d: *Desktop, wanted: []const u8) bool {
        var it = d.volumes.iterator();
        while (it.next()) |node| {
            const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
            const held = ic.path orelse continue;
            var length: usize = 0;
            while (held[length] != 0) length += 1;
            if (length != wanted.len) continue;
            for (held[0..length], wanted) |a, b| {
                const left = if (a >= 'a' and a <= 'z') a - 32 else a;
                const right = if (b >= 'a' and b <= 'z') b - 32 else b;
                if (left != right) break;
            } else return true;
        }
        return false;
    }

    /// The disk's icon at the point (`x`, `y`) of the desktop, if any.
    pub fn volumeAt(d: *Desktop, x: i32, y: i32) ?*Icon {
        var found: ?*Icon = null;
        var it = d.volumes.iterator();
        while (it.next()) |node| {
            const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
            if (ic.hit(&d.look, .{}, x, y)) found = ic;
        }
        return found;
    }

    /// Something said in the screen's title for a few seconds - and kept
    /// for Last Message.
    pub fn say(d: *Desktop, text: []const u8) void {
        const length = @min(text.len, d.message.len);
        @memcpy(d.message[0..length], text[0..length]);
        d.message[length] = 0;
        d.message_ticks = 3;
        if (d.backdrop) |window| d.ib.SetWindowTitles(window, wn.TITLE_UNCHANGED, &d.message);
        var it = d.drawers.iterator();
        while (it.next()) |node| {
            const dr: *Drawer = @alignCast(@fieldParentPtr("node", node));
            d.ib.SetWindowTitles(dr.window, wn.TITLE_UNCHANGED, &d.message);
        }
    }

    /// The Show and View By marks set as a drawer has them.
    pub fn showChecks(d: *Desktop, view: anvil_prefs.View, show_all: bool) void {
        const strip = d.menu_strip orelse return;
        const marks = [_]struct { item: u32, sub: u32, on: bool }{
            .{ .item = menus.ITEM_SHOW, .sub = menus.SUB_ONLY_ICONS, .on = !show_all },
            .{ .item = menus.ITEM_SHOW, .sub = menus.SUB_ALL_FILES, .on = show_all },
            .{ .item = menus.ITEM_VIEW_BY, .sub = menus.SUB_BY_ICON, .on = view == .icon },
            .{ .item = menus.ITEM_VIEW_BY, .sub = menus.SUB_BY_NAME, .on = view == .name },
            .{ .item = menus.ITEM_VIEW_BY, .sub = menus.SUB_BY_DATE, .on = view == .date },
            .{ .item = menus.ITEM_VIEW_BY, .sub = menus.SUB_BY_SIZE, .on = view == .size },
        };
        for (marks) |mark| {
            const item = d.ib.ItemAddress(strip, mn.FULLMENUNUM(menus.MENU_WINDOW, mark.item, mark.sub)) orelse continue;
            if (mark.on) item.flags |= mn.CHECKED else item.flags &= ~mn.CHECKED;
        }
    }

    /// Menu items picked in `window`, each in turn.
    fn picked(d: *Desktop, window: ?*intuition.Window, first: u32) void {
        var number = first;
        while (number != mn.MENUNULL and !d.quit) {
            const item = d.ib.ItemAddress(d.menu_strip, number) orelse break;
            const next = item.next_select;
            switch (mn.MENUNUM(number)) {
                menus.MENU_ANVIL => switch (mn.ITEMNUM(number)) {
                    menus.ITEM_BACKDROP => {
                        d.toggleBackdrop();
                        // The window the item was picked in is gone.
                        return;
                    },
                    menus.ITEM_EXECUTE => commands.executeCommand(d),
                    menus.ITEM_REDRAW_ALL => d.redrawAll(),
                    menus.ITEM_UPDATE_ALL => d.updateAll(),
                    menus.ITEM_LAST_MESSAGE => d.lastMessage(),
                    menus.ITEM_ABOUT => d.about(),
                    menus.ITEM_QUIT => d.askQuit(),
                    else => {},
                },
                menus.MENU_WINDOW => d.windowItem(window, number),
                menus.MENU_ICONS => commands.iconsItem(d, number),
                menus.MENU_TOOLS => app_area.chosen(d, mn.ITEMNUM(number)),
                else => {},
            }
            // A drawer closed by the item is gone: nothing after it.
            if (drawer.find(d, window) == null and window != d.backdrop) break;
            number = next;
        }
    }

    /// An item of the Window menu, for the drawer it was picked in.
    fn windowItem(d: *Desktop, window: ?*intuition.Window, number: u32) void {
        const dr = drawer.find(d, window) orelse {
            // On the desktop's own ground, only what is about its icons.
            if (window != d.backdrop) return;
            switch (mn.ITEMNUM(number)) {
                menus.ITEM_SELECT_CONTENTS => select.contents(d, null),
                menus.ITEM_CLEAN_UP => commands.cleanUp(d, null),
                else => {},
            }
            return;
        };
        switch (mn.ITEMNUM(number)) {
            menus.ITEM_NEW_DRAWER => commands.newDrawer(d, dr),
            menus.ITEM_CLEAN_UP => commands.cleanUp(d, dr),
            menus.ITEM_SNAPSHOT_WINDOW => commands.snapshotWindow(d, dr, mn.SUBNUM(number) == menus.SUB_SNAPSHOT_ALL),
            menus.ITEM_SELECT_CONTENTS => select.contents(d, dr),
            menus.ITEM_OPEN_PARENT => drawer.openParent(d, dr),
            menus.ITEM_CLOSE => drawer.close(d, dr),
            menus.ITEM_UPDATE => drawer.reread(d, dr),
            menus.ITEM_SHOW => drawer.showAs(d, dr, dr.view, mn.SUBNUM(number) == menus.SUB_ALL_FILES),
            menus.ITEM_VIEW_BY => {
                const sub = mn.SUBNUM(number);
                if (sub <= menus.SUB_BY_SIZE) drawer.showAs(d, dr, @enumFromInt(sub), dr.show_all);
            },
            else => {},
        }
    }

    fn about(d: *Desktop) void {
        const easy = intuition.requesters.EasyStruct{
            .title = "About Anvil",
            .text_format = "Anvil %s\nThe PowerOS desktop",
            .gadget_format = "OK",
        };
        const args = [_]usize{@intFromPtr(anvil_init.VERSION_TEXT.ptr)};
        _ = d.ib.EasyRequestArgs(d.backdrop, &easy, null, &args);
    }

    /// Quit asked for: refused while programs it started still run, or
    /// programs have windows, icons or menu items added to it; confirmed
    /// otherwise.
    fn askQuit(d: *Desktop) void {
        const added = app_area.count(d);
        if (added != 0) {
            const busy = intuition.requesters.EasyStruct{
                .title = "Anvil",
                .text_format = "The desktop cannot quit while programs\nhave windows, icons or menu items\nadded to it (%lu now).",
                .gadget_format = "OK",
            };
            const args = [_]u64{added};
            _ = d.ib.EasyRequestArgs(d.backdrop, &busy, null, &args);
            return;
        }
        if (d.running != 0) {
            const busy = intuition.requesters.EasyStruct{
                .title = "Anvil",
                .text_format = "The desktop cannot quit while programs\nit started still run (%lu now).",
                .gadget_format = "OK",
            };
            const args = [_]u64{d.running};
            _ = d.ib.EasyRequestArgs(d.backdrop, &busy, null, &args);
            return;
        }
        const ask = intuition.requesters.EasyStruct{
            .title = "Anvil",
            .text_format = "Quit the desktop?",
            .gadget_format = "Quit|Cancel",
        };
        if (d.ib.EasyRequestArgs(d.backdrop, &ask, null, null) == 1) d.quit = true;
    }

    /// Requests of its own come back: the clock's tick brings the title
    /// up to date and looks for disks, and is sent again.
    fn replied(d: *Desktop) void {
        while (d.sys.GetMsg(d.reply_port.?)) |message| {
            if (message == @as(*exec.Message, @ptrCast(&d.clock.node))) {
                d.clock_out = false;
                d.ticks +%= 1;
                d.updateTitle();
                volumes.scan(d);
                if (!d.quit) d.tickLater();
                startup_area.tick(d);
                continue;
            }
            // A program it started has ended: the next of the startup
            // drawer's may start.
            const ended: *run_area.Ended = @fieldParentPtr("message", message);
            d.running -|= 1;
            startup_area.ended(d, ended);
            d.sys.FreeVec(ended);
        }
    }

    fn tickLater(d: *Desktop) void {
        if (!d.clock_open or d.clock_out) return;
        d.clock.node.command = timer.TR_ADDREQUEST;
        d.clock.time = .{ .secs = tick_seconds, .micro = 0 };
        d.sys.SendIO(&d.clock.node);
        d.clock_out = true;
    }

    /// A file it follows changed: the prefs made anew from, or a drawer
    /// read again.
    fn notified(d: *Desktop) void {
        var prefs_changed = false;
        while (d.sys.GetMsg(d.notify_port.?)) |message| {
            const told: *notify.NotifyMessage = @fieldParentPtr("message", message);
            const request = told.request;
            d.sys.ReplyMsg(message);
            if (request == &d.watching[0] or request == &d.watching[1]) {
                prefs_changed = true;
                continue;
            }
            const wanted = request orelse continue;
            var it = d.drawers.iterator();
            while (it.next()) |node| {
                const dr: *Drawer = @alignCast(@fieldParentPtr("node", node));
                if (&dr.watch == wanted) {
                    drawer.reread(d, dr);
                    break;
                }
            }
        }
        if (prefs_changed) d.renew();
    }

    /// The desktop's screen brought to the front - from any task.
    pub fn toFront(d: *Desktop) void {
        if (d.screen) |screen| d.ib.ScreenToFront(screen);
    }

    // --- going ---------------------------------------------------------------

    /// No longer the desktop that runs: StartAnvil may start another.
    fn leave(d: *Desktop) void {
        const base = d.base;
        d.sys.ObtainSemaphore(&base.start_lock);
        base.desktop = null;
        d.sys.ReleaseSemaphore(&base.start_lock);
    }

    /// Everything given back that `setUp` got, in the reverse order.
    fn tearDown(d: *Desktop) void {
        const sys = d.sys;
        for (&d.watching, d.watched) |*request, on| {
            if (on) d.dl.EndNotify(request);
        }
        if (d.clock_out) {
            _ = sys.AbortIO(&d.clock.node);
            _ = sys.WaitIO(&d.clock.node);
        }
        if (d.clock_open) sys.CloseDevice(&d.clock.node);
        app_area.leave(d);
        startup_area.finish(d);
        if (d.libraries[@intFromEnum(Lib.icon)] != null) {
            drawer.closeAll(d);
            volumes.forgetAll(d);
        }
        app_area.tearDown(d);
        if (d.backdrop) |window| {
            if (d.menu_strip != null) d.ib.ClearMenuStrip(window);
            d.ib.CloseWindow(window);
        }
        if (d.menu_strip) |strip| d.ib.FreeMenus(strip);
        if (d.libraries[@intFromEnum(Lib.graphics)] != null) {
            ground_area.free(d.groundLibs(), d.ground);
            if (d.own_font) |font| d.gb.CloseFont(font);
        }
        if (d.screen) |screen| d.ib.UnlockPubScreen(null, screen);
        // Whatever is still on a port was sent to the desktop: replied.
        for ([_]?*exec.MsgPort{ d.notify_port, d.windows_port }) |held| {
            const port = held orelse continue;
            while (sys.GetMsg(port)) |message| sys.ReplyMsg(message);
        }
        sys.DeleteMsgPort(d.reply_port);
        sys.DeleteMsgPort(d.notify_port);
        sys.DeleteMsgPort(d.windows_port);
        var i = d.libraries.len;
        while (i > 0) {
            i -= 1;
            if (d.libraries[i]) |lib| sys.CloseLibrary(lib);
        }
        if (d.read_signal >= 0) sys.FreeSignal(d.read_signal);
    }

    /// StartAnvil told the desktop is up, or why not. After this, a desktop
    /// that failed is StartAnvil's to free: nothing of it is touched.
    fn tellStarter(d: *Desktop, code: i32) void {
        const starter = d.starter.?;
        const signal = d.start_signal;
        d.start_error = code;
        d.sys.Signal(starter, @as(u32, 1) << signal);
    }
};

/// The backfill hook: a strip of the backdrop painted from the ground.
/// Called on whichever task uncovered it.
fn paintGround(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const d: *Desktop = @ptrCast(@alignCast(hook.data orelse return 0));
    const rp: *graphics.RastPort = @ptrCast(object orelse return 0);
    const msg: *const graphics.BackFillMsg = @ptrCast(@alignCast(message orelse return 0));
    d.sys.ObtainSemaphore(&d.ground_lock);
    defer d.sys.ReleaseSemaphore(&d.ground_lock);
    if (d.ground) |ground| ground_area.paint(d.gb, ground, rp, msg.area);
    return 0;
}

/// The desktop's process: up, around its Wait until it quits, gone.
pub fn desktopMain(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const d: *Desktop = @ptrCast(@alignCast(me.user_data orelse return));
    const code = d.setUp();
    if (code != 0) {
        d.tearDown();
        d.tellStarter(code);
        return;
    }
    d.tellStarter(0);
    startup_area.begin(d);
    d.run();
    // What programs added let go of before another desktop may start.
    app_area.leave(d);
    d.leave();
    d.tearDown();
    sys.FreeVec(d);
}
