// SPDX-License-Identifier: MIT
//! Clock: the time in a window, on a dial or in figures. Built against the
//! SDK only.
//!
//!   Clock MODE/K,SECONDS/K,DATE/K,HOURS/K/N,LEFT/K/N,TOP/K/N,
//!         ANALOGSIZE/K,DIGITALSIZE/K,PUBSCREEN/K
//!
//! MODE is ANALOG, a dial with hands (`face.zig`), or DIGITAL, figures on
//! a panel (`panel.zig`). SECONDS and DATE are YES or NO: whether the
//! seconds and the date are shown, both YES. HOURS is 12 or 24, and
//! without it the locale's way of writing the time decides. LEFT and TOP
//! are where the window opens; ANALOGSIZE and DIGITALSIZE how large its
//! inside is in each mode, as WIDTHxHEIGHT. Started from its icon it reads
//! the same from the icon's tool types.
//!
//! The Project menu switches between the dial and the figures, and so
//! does a double click in the window, the window taking the size it last
//! had in that mode. The Settings menu turns the seconds, the date and the
//! 24-hour clock on and off; Save Settings writes all of it - the
//! window's place and its size in both modes too - into the program's
//! icon as tool types, the icon's others kept.
//!
//! One Clock runs: the first keeps the public port `Clock`, and a second
//! start brings its window to the front and ends. A click on the dock's
//! clock is such a start once one is open.
//!
//! It wakes when what it shows changes - each half second while the
//! figures' colon blinks, each second while the second hand goes round,
//! each minute with neither - and puts the picture together off the
//! screen before it is copied into the window, so nothing flickers. The
//! close gadget, Quit or Ctrl-C end it.

const sdk = @import("sdk");
const strings = @import("strings");
const time = @import("time.zig");
const faces = @import("face.zig");
const panels = @import("panel.zig");
const picture = @import("picture.zig");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const icon = sdk.icon;
const locale = sdk.locale;
const timer = sdk.devices.timer;
const mn = intuition.menus;
const wn = intuition.windows;
const sc = intuition.screens;
const support = sdk.gadgets.support;
const rdargs = dos.rdargs;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IconBase = sdk.interface.icon.IconBase;
const Text = sdk.locale.Strings(strings);
const Id = strings.Id;
const Pen = graphics.Pen;

pub const COMMAND_NAME = "Clock";
const VERSION = "1.0";
const DATE = "09.11.2026";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (" ++ DATE ++ ")\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
/// What the screen's bar says while its window is active.
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;
const ABOUT_VERSION = COMMAND_NAME ++ " " ++ VERSION ++ " (" ++ DATE ++ ")";

/// The public port of the Clock that runs.
pub const PORT_NAME = "Clock";

const template = "MODE/K,SECONDS/K,DATE/K,HOURS/K/N,LEFT/K/N,TOP/K/N,ANALOGSIZE/K,DIGITALSIZE/K,PUBSCREEN/K";
const Arg = enum(usize) { mode, seconds, date, hours, left, top, analog_size, digital_size, pubscreen };
const arg_count = @typeInfo(Arg).@"enum".fields.len;

/// The tool types Save Settings writes, each by an argument's name; any
/// other the icon has it keeps.
const kept = [_]struct { name: [*:0]const u8, arg: Arg }{
    .{ .name = "MODE", .arg = .mode },
    .{ .name = "SECONDS", .arg = .seconds },
    .{ .name = "DATE", .arg = .date },
    .{ .name = "HOURS", .arg = .hours },
    .{ .name = "LEFT", .arg = .left },
    .{ .name = "TOP", .arg = .top },
    .{ .name = "ANALOGSIZE", .arg = .analog_size },
    .{ .name = "DIGITALSIZE", .arg = .digital_size },
};

/// What it shows and where.
const Settings = struct {
    digital: bool = false,
    seconds: bool = true,
    date: bool = true,
    /// 12 or 24; null to follow the locale.
    hours: ?i32 = null,
    /// Where the window opens; -1 for the middle of the screen.
    left: i32 = -1,
    top: i32 = -1,
    analog: time.Size = .{ .width = 200, .height = 224 },
    figures: time.Size = .{ .width = 300, .height = 116 },
    pubscreen: [64:0]u8 = @splat(0),

    /// The window's inside in the mode it is in.
    fn size(settings: *Settings) *time.Size {
        return if (settings.digital) &settings.figures else &settings.analog;
    }
};

/// Where the settings came from: the icon it was started from, or the
/// command line.
const Given = struct {
    sys: *ExecBase,
    dl: *DosBase,
    icon_base: ?*IconBase = null,
    object: ?*icon.DiskObject = null,
    rda: ?*dos.RDArgs = null,
    argv: [arg_count]usize = @splat(0),
    /// The icon started: its drawer and its name, where Save Settings
    /// writes. Both null from a shell.
    lock: ?*dos.FileLock = null,
    name: ?[*:0]const u8 = null,

    /// Null when the command line was refused, having said why.
    fn read(sys: *ExecBase, dl: *DosBase) ?Given {
        var given = Given{ .sys = sys, .dl = dl };
        var count: u32 = 0;
        const files = dl.GetArgList(&count);
        if (files != null and count > 0) {
            given.lock = files.?[0].lock;
            given.name = files.?[0].name;
            const library = sys.OpenLibrary(icon.ICONNAME, 1) orelse return given;
            given.icon_base = @ptrCast(library);
            const old = dl.CurrentDir(given.lock);
            defer _ = dl.CurrentDir(old);
            if (given.name) |name| given.object = given.icon_base.?.GetDiskObject(name);
            return given;
        }
        given.rda = dl.ReadArgs(template, &given.argv, null) orelse {
            _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
            return null;
        };
        return given;
    }

    fn done(given: *Given) void {
        if (given.object) |object| given.icon_base.?.FreeDiskObject(object);
        if (given.icon_base) |base| given.sys.CloseLibrary(base.lib());
        if (given.rda) |rda| given.dl.FreeArgs(rda);
        given.object = null;
        given.icon_base = null;
        given.rda = null;
    }

    fn text(given: *const Given, comptime arg: Arg) ?[*:0]const u8 {
        if (given.object) |object| return given.icon_base.?.FindToolType(object.tool_types, keptName(arg));
        return rdargs.string(given.argv[@intFromEnum(arg)]);
    }

    fn number(given: *const Given, comptime arg: Arg) ?i32 {
        if (given.object != null) {
            const found = given.text(arg) orelse return null;
            var value: i32 = 0;
            return if (given.dl.StrToLong(found, &value) > 0) value else null;
        }
        const value = rdargs.number(given.argv[@intFromEnum(arg)]) orelse return null;
        return @intCast(value);
    }

    fn settings(given: *const Given) Settings {
        var made = Settings{};
        if (given.text(.mode)) |mode| made.digital = time.sameWord(mode, "DIGITAL");
        if (given.text(.seconds)) |value| made.seconds = !time.sameWord(value, "NO");
        if (given.text(.date)) |value| made.date = !time.sameWord(value, "NO");
        if (given.number(.hours)) |hours| {
            if (hours == 12 or hours == 24) made.hours = hours;
        }
        if (given.number(.left)) |left| made.left = @max(left, 0);
        if (given.number(.top)) |top| made.top = @max(top, 0);
        if (given.text(.analog_size)) |value| {
            if (time.Size.parse(value)) |size| made.analog = size;
        }
        if (given.text(.digital_size)) |value| {
            if (time.Size.parse(value)) |size| made.figures = size;
        }
        const pubscreen: ?[*:0]const u8 = if (given.object) |object| given.icon_base.?.FindToolType(object.tool_types, "PUBSCREEN") else rdargs.string(given.argv[@intFromEnum(Arg.pubscreen)]);
        if (pubscreen) |name| copyText(&made.pubscreen, name);
        return made;
    }
};

fn keptName(comptime arg: Arg) [*:0]const u8 {
    for (kept) |entry| if (entry.arg == arg) return entry.name;
    return "PUBSCREEN";
}

fn copyText(into: []u8, from: [*:0]const u8) void {
    var at: usize = 0;
    while (from[at] != 0 and at + 1 < into.len) : (at += 1) into[at] = from[at];
    into[at] = 0;
}

fn length(text: [*:0]const u8) u32 {
    var count: u32 = 0;
    while (text[count] != 0) count += 1;
    return count;
}

// --- the menus --------------------------------------------------------------------

const MENU_PROJECT = 0;
const ITEM_ANALOG = 0;
const ITEM_DIGITAL = 1;
const ITEM_ABOUT = 3;
const ITEM_QUIT = 5;
const MENU_SETTINGS = 1;
const ITEM_SECONDS = 0;
const ITEM_DATE = 1;
const ITEM_24_HOURS = 2;
const ITEM_SAVE = 4;

/// A menu's entry, and the string its label is.
const MenuEntry = struct { menu: mn.NewMenu, text: ?Id = null };

fn menuTitle(text: Id) MenuEntry {
    return .{ .menu = .{ .type = mn.NM_TITLE, .label = strings.builtin(text) }, .text = text };
}

fn menuItem(text: Id, key: ?[*:0]const u8, flags: u32, exclude: u32) MenuEntry {
    return .{ .menu = .{ .type = mn.NM_ITEM, .label = strings.builtin(text), .comm_key = key, .flags = flags, .mutual_exclude = exclude }, .text = text };
}

const bar = MenuEntry{ .menu = .{ .type = mn.NM_ITEM, .label = mn.NM_BARLABEL } };

const menu_table = [_]MenuEntry{
    menuTitle(.MSG_MENU_PROJECT),
    menuItem(.MSG_MENU_ANALOG, "A", mn.CHECKIT, 1 << ITEM_DIGITAL),
    menuItem(.MSG_MENU_DIGITAL, "D", mn.CHECKIT, 1 << ITEM_ANALOG),
    bar,
    menuItem(.MSG_MENU_ABOUT, null, 0, 0),
    bar,
    menuItem(.MSG_MENU_QUIT, "Q", 0, 0),
    menuTitle(.MSG_MENU_SETTINGS),
    menuItem(.MSG_MENU_SECONDS, null, mn.CHECKIT | mn.MENUTOGGLE, 0),
    menuItem(.MSG_MENU_DATE, null, mn.CHECKIT | mn.MENUTOGGLE, 0),
    menuItem(.MSG_MENU_24_HOURS, null, mn.CHECKIT | mn.MENUTOGGLE, 0),
    bar,
    menuItem(.MSG_MENU_SAVE, "S", 0, 0),
};

// --- the program --------------------------------------------------------------------

const App = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ib: *IntuitionBase,
    gb: *GraphicsBase,
    text: *const Text,
    given: *Given,
    settings: Settings,
    /// The locale's own: whether its time is on a 24-hour clock.
    locale_24: bool = true,

    window: *intuition.Window,
    /// The window's RastPort, whose (0, 0) is its inside's corner.
    rp: *graphics.RastPort,
    menu: ?*mn.Menu = null,
    ground: Pen,
    ink: Pen,
    font: usize = 0,
    font_height: i32 = 0,
    baseline: i32 = 0,

    /// The inside, and the picture of it put together off the screen.
    width: i32 = 0,
    height: i32 = 0,
    canvas: ?*picture.Surface = null,
    canvas_rp: ?*graphics.RastPort = null,
    face: faces.Face = .{},
    panel: panels.Panel = .{},

    /// The date in the locale's words, and the day it was written for.
    date_long: [96:0]u8 = @splat(0),
    date_short: [32:0]u8 = @splat(0),
    date_days: i32 = -1,
    am: [*:0]const u8 = "AM",
    pm: [*:0]const u8 = "PM",

    /// The wait for the next change.
    due: timer.TimeRequest = .{},
    due_pending: bool = false,
    /// When the last press of the left button came, for a double click.
    pressed: [2]u32 = .{ 0, 0 },

    fn twentyFour(app: *const App) bool {
        return if (app.settings.hours) |hours| hours == 24 else app.locale_24;
    }

    /// How often the picture changes.
    fn step(app: *const App) time.Step {
        if (app.settings.digital) return .half_second;
        return if (app.settings.seconds) .second else .minute;
    }

    // --- the wait ------------------------------------------------------------------

    fn arm(app: *App, us: u64) void {
        app.disarm();
        const port = app.due.node.message.reply_port orelse return;
        // AbortIO leaves the port's signal set; cleared, or the next
        // Wait comes back at once.
        _ = app.sys.SetSignal(0, port.sigMask());
        app.due.node.command = timer.TR_ADDREQUEST;
        app.due.time = timer.TimeVal.fromMicros(us);
        app.sys.SendIO(&app.due.node);
        app.due_pending = true;
    }

    fn disarm(app: *App) void {
        if (!app.due_pending) return;
        _ = app.sys.AbortIO(&app.due.node);
        _ = app.sys.WaitIO(&app.due.node);
        app.due_pending = false;
    }

    // --- the picture ---------------------------------------------------------------

    /// The off-screen picture made the size of the window's inside, as it
    /// is now; false without the memory for it.
    fn fit(app: *App) bool {
        var width: usize = 0;
        var height: usize = 0;
        app.ib.GetWindowAttrs(app.window, &[_]TagItem{
            .{ .tag = wn.WA_InnerWidth, .data = @intFromPtr(&width) },
            .{ .tag = wn.WA_InnerHeight, .data = @intFromPtr(&height) },
            .{},
        });
        const w: i32 = @intCast(@max(width, 1));
        const h: i32 = @intCast(@max(height, 1));
        if (app.canvas != null and w == app.width and h == app.height) return true;
        app.dropCanvas();
        app.width = w;
        app.height = h;
        app.canvas = app.gb.AllocBitMapTagList(&[_]TagItem{
            .{ .tag = graphics.BMTAG_Width, .data = @intCast(w) },
            .{ .tag = graphics.BMTAG_Height, .data = @intCast(h) },
            .{ .tag = graphics.BMTAG_Friend, .data = @intFromPtr(app.rp) },
            .{},
        }) orelse return false;
        app.canvas_rp = app.gb.CreateRastPortTagList(&[_]TagItem{
            .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(app.canvas.?) },
            .{ .tag = graphics.RPTAG_Font, .data = app.font },
            .{},
        }) orelse {
            app.dropCanvas();
            return false;
        };
        return true;
    }

    fn dropCanvas(app: *App) void {
        app.gb.FreeRastPort(app.canvas_rp);
        app.gb.FreeBitMap(app.canvas);
        app.canvas_rp = null;
        app.canvas = null;
    }

    /// The date of `now` in the locale's words, long or short, whichever
    /// fits `room` pixels on `rp`; null when neither does.
    fn dateText(app: *App, rp: *graphics.RastPort, now: dos.DateStamp, room: i32) ?[*:0]const u8 {
        if (now.days != app.date_days) {
            app.date_days = now.days;
            app.writeDate(now);
        }
        for ([_][*:0]const u8{ &app.date_long, &app.date_short }) |date| {
            const count = length(date);
            if (count > 0 and app.gb.TextLength(rp, date, count) <= room) return date;
        }
        return null;
    }

    fn writeDate(app: *App, now: dos.DateStamp) void {
        app.date_long[0] = 0;
        app.date_short[0] = 0;
        if (app.text.library) |lb| if (app.text.locale) |loc| {
            var long = locale.BufferHook.init(&app.date_long);
            lb.FormatDate(loc, loc.date_format, &now, &long.hook);
            var short = locale.BufferHook.init(&app.date_short);
            lb.FormatDate(loc, loc.short_date_format, &now, &short.hook);
            return;
        };
        // Without locale.library: the day and the date as dos writes them.
        var day: [16:0]u8 = @splat(0);
        var date: [16:0]u8 = @splat(0);
        var told = dos.DateTime{ .stamp = now, .format = dos.FORMAT_DEF, .str_day = &day, .str_date = &date };
        if (!app.dl.DateToStr(&told)) return;
        const stream = exec.fmtStream(.{ @as([*:0]const u8, &day), @as([*:0]const u8, &date) });
        comptime exec.checkFormat("%s %s", @TypeOf(.{ @as([*:0]const u8, ""), @as([*:0]const u8, "") }));
        _ = app.sys.RawDoFmt("%s %s", &stream, null, &app.date_long);
        copyText(&app.date_short, &date);
    }

    /// The window drawn as it is at `now`: put together off the screen,
    /// then copied in. Without the memory for that, its ground only.
    fn draw(app: *App, now: dos.DateStamp) void {
        const gb = app.gb;
        if (!app.fit()) {
            support.setPen(gb, app.rp, app.ground);
            gb.RectFill(app.rp, &.{ .max_x = app.width, .max_y = app.height });
            return;
        }
        const rp = app.canvas_rp.?;
        const shown = time.Shown.of(now);
        support.setPen(gb, rp, app.ground);
        gb.RectFill(rp, &.{ .max_x = app.width, .max_y = app.height });
        if (app.settings.digital) app.drawFigures(rp, now, shown) else app.drawDial(rp, now, shown);
        gb.BltBitMapRastPort(app.canvas.?, 0, 0, app.rp, 0, 0, app.width, app.height);
    }

    fn drawDial(app: *App, rp: *graphics.RastPort, now: dos.DateStamp, shown: time.Shown) void {
        const gb = app.gb;
        const margin = @max(3, @divTrunc(@min(app.width, app.height), 28));
        const date_height: i32 = if (app.settings.date) app.font_height + @divTrunc(app.font_height, 2) else 0;
        const size = @min(app.width - 2 * margin, app.height - 2 * margin - date_height);
        // The panel's figures go when the dial is too small for them.
        if (size < 16) return;
        const x = @divTrunc(app.width - size, 2);
        const y = margin + @divTrunc(app.height - 2 * margin - date_height - size, 2);
        if (app.face.fit(gb, rp, size)) {
            if (app.face.at(gb, rp, shown, app.settings.seconds)) |dial| picture.putDown(gb, rp, dial, x, y);
        }
        if (!app.settings.date) return;
        const date = app.dateText(rp, now, app.width - 2 * margin) orelse return;
        const count = length(date);
        support.setPen(gb, rp, app.ink);
        gb.Move(rp, @divTrunc(app.width - gb.TextLength(rp, date, count), 2), y + size + @divTrunc(app.font_height, 3) + app.baseline);
        gb.Text(rp, date, count);
    }

    fn drawFigures(app: *App, rp: *graphics.RastPort, now: dos.DateStamp, shown: time.Shown) void {
        const date: ?[*:0]const u8 = if (app.settings.date) app.dateText(rp, now, app.width - 24) else null;
        _ = app.panel.draw(app.gb, rp, app.width, app.height, shown, .{
            .seconds = app.settings.seconds,
            .marker = if (app.twentyFour()) null else if (shown.afternoon()) app.pm else app.am,
            .date = date,
            .font_height = app.font_height,
            .baseline = app.baseline,
        });
    }

    /// The picture put together already, copied in again: what a refresh
    /// wants.
    fn refresh(app: *App) void {
        app.ib.BeginRefresh(app.window);
        defer app.ib.EndRefresh(app.window, true);
        const canvas = app.canvas orelse return;
        app.gb.BltBitMapRastPort(canvas, 0, 0, app.rp, 0, 0, app.width, app.height);
    }

    // --- the window ----------------------------------------------------------------

    /// The window's inside, as it is now, kept as the size of the mode it
    /// is in.
    fn keepSize(app: *App) void {
        if (app.width < 1 or app.height < 1) return;
        app.settings.size().* = .{ .width = app.width, .height = app.height };
    }

    /// The dial or the figures, the window taking its size in that mode.
    fn setMode(app: *App, digital: bool) void {
        if (app.settings.digital == digital) return;
        app.keepSize();
        app.settings.digital = digital;
        app.check(MENU_PROJECT, ITEM_ANALOG, !digital);
        app.check(MENU_PROJECT, ITEM_DIGITAL, digital);
        var place: [6]usize = @splat(0);
        app.ib.GetWindowAttrs(app.window, &[_]TagItem{
            .{ .tag = wn.WA_Left, .data = @intFromPtr(&place[0]) },
            .{ .tag = wn.WA_Top, .data = @intFromPtr(&place[1]) },
            .{ .tag = wn.WA_BorderLeft, .data = @intFromPtr(&place[2]) },
            .{ .tag = wn.WA_BorderTop, .data = @intFromPtr(&place[3]) },
            .{ .tag = wn.WA_BorderRight, .data = @intFromPtr(&place[4]) },
            .{ .tag = wn.WA_BorderBottom, .data = @intFromPtr(&place[5]) },
            .{},
        });
        const size = app.settings.size().*;
        const left: i32 = @bitCast(@as(u32, @truncate(place[0])));
        const top: i32 = @bitCast(@as(u32, @truncate(place[1])));
        const across: i32 = @intCast(place[2] + place[4]);
        const down: i32 = @intCast(place[3] + place[5]);
        app.ib.ChangeWindowBox(app.window, left, top, size.width + across, size.height + down);
    }

    /// The item's checkmark set or taken away.
    fn check(app: *App, menu_number: u32, item_number: u32, on: bool) void {
        const strip = app.menu orelse return;
        const item = app.ib.ItemAddress(strip, mn.FULLMENUNUM(menu_number, item_number, mn.NOSUB)) orelse return;
        if ((item.flags & mn.CHECKED != 0) == on) return;
        app.ib.ClearMenuStrip(app.window);
        item.flags = if (on) item.flags | mn.CHECKED else item.flags & ~mn.CHECKED;
        _ = app.ib.ResetMenuStrip(app.window, strip);
    }

    /// The menus, their labels in the catalog's words and their checks as
    /// the settings are; none when they will not go on.
    fn makeMenus(app: *App, screen: *intuition.Screen) void {
        var table: [menu_table.len + 1]mn.NewMenu = undefined;
        for (menu_table, 0..) |entry, at| {
            table[at] = entry.menu;
            if (entry.text) |id| table[at].label = app.text.get(id);
        }
        table[menu_table.len] = .{};
        const on = [_]struct { at: usize, checked: bool }{
            .{ .at = 1, .checked = !app.settings.digital },
            .{ .at = 2, .checked = app.settings.digital },
            .{ .at = 8, .checked = app.settings.seconds },
            .{ .at = 9, .checked = app.settings.date },
            .{ .at = 10, .checked = app.twentyFour() },
        };
        for (on) |entry| {
            if (entry.checked) table[entry.at].flags |= mn.CHECKED;
        }
        const made = app.ib.CreateMenusA(&table, null) orelse return;
        if (!app.ib.LayoutMenusA(made, screen, null) or !app.ib.SetMenuStrip(app.window, made)) {
            app.ib.FreeMenus(made);
            return;
        }
        app.menu = made;
    }

    fn dropMenus(app: *App) void {
        const made = app.menu orelse return;
        app.ib.ClearMenuStrip(app.window);
        app.ib.FreeMenus(made);
        app.menu = null;
    }

    /// The items picked, one after another; false for Quit.
    fn picked(app: *App, first: u32) bool {
        var number = first;
        while (number != mn.MENUNULL) {
            const item = app.ib.ItemAddress(app.menu, number) orelse break;
            const on = item.flags & mn.CHECKED != 0;
            switch (mn.MENUNUM(number)) {
                MENU_PROJECT => switch (mn.ITEMNUM(number)) {
                    ITEM_ANALOG => app.setMode(false),
                    ITEM_DIGITAL => app.setMode(true),
                    ITEM_ABOUT => app.about(),
                    ITEM_QUIT => return false,
                    else => {},
                },
                MENU_SETTINGS => switch (mn.ITEMNUM(number)) {
                    ITEM_SECONDS => app.settings.seconds = on,
                    ITEM_DATE => app.settings.date = on,
                    ITEM_24_HOURS => app.settings.hours = if (on) 24 else 12,
                    ITEM_SAVE => app.save(),
                    else => {},
                },
                else => {},
            }
            number = item.next_select;
        }
        return true;
    }

    fn about(app: *App) void {
        const easy = intuition.EasyStruct{
            .title = app.text.get(.MSG_ABOUT_TITLE),
            .text_format = app.text.get(.MSG_ABOUT),
            .gadget_format = app.text.get(.MSG_OK),
        };
        comptime exec.checkFormat(strings.builtin(.MSG_ABOUT), @TypeOf(.{@as([*:0]const u8, ABOUT_VERSION)}));
        const stream = exec.fmtStream(.{@as([*:0]const u8, ABOUT_VERSION)});
        _ = app.ib.EasyRequestArgs(app.window, &easy, null, &stream);
    }

    // --- the settings kept ---------------------------------------------------------

    /// The settings written into the program's icon as tool types: the
    /// icon started, or the one beside the program when it was started
    /// from a shell - made when there is none. Its other tool types are
    /// kept.
    fn save(app: *App) void {
        const sys = app.sys;
        const dl = app.dl;
        app.keepSize();
        var place: [2]usize = .{ 0, 0 };
        app.ib.GetWindowAttrs(app.window, &[_]TagItem{
            .{ .tag = wn.WA_Left, .data = @intFromPtr(&place[0]) },
            .{ .tag = wn.WA_Top, .data = @intFromPtr(&place[1]) },
            .{},
        });
        app.settings.left = @max(0, @as(i32, @bitCast(@as(u32, @truncate(place[0])))));
        app.settings.top = @max(0, @as(i32, @bitCast(@as(u32, @truncate(place[1])))));

        var name: [dos.path_max + 1:0]u8 = @splat(0);
        if (app.given.name) |started| copyText(&name, started) else ownName(dl, &name);
        const library = sys.OpenLibrary(icon.ICONNAME, 1) orelse return app.notSaved(&name);
        defer sys.CloseLibrary(library);
        const icon_base: *IconBase = @ptrCast(library);
        const old = dl.CurrentDir(app.given.lock);
        defer _ = dl.CurrentDir(old);
        const object = icon_base.GetDiskObject(&name) orelse icon_base.GetDefDiskObject(icon.WBTOOL) orelse return app.notSaved(&name);
        defer icon_base.FreeDiskObject(object);

        var lines: [kept.len][48:0]u8 = undefined;
        var list: [48]?[*:0]const u8 = @splat(null);
        var count: usize = 0;
        if (object.tool_types) |types| {
            var at: usize = 0;
            while (types[at]) |entry| : (at += 1) {
                if (count + kept.len + 1 >= list.len) break;
                if (isKept(entry)) continue;
                list[count] = entry;
                count += 1;
            }
        }
        for (kept, &lines) |entry, *line| {
            if (!app.setting(entry.arg, entry.name, line)) continue;
            list[count] = line;
            count += 1;
        }
        // The icon's fields pointed at these while it is written, and put
        // back after, for FreeDiskObject.
        const was = object.*;
        defer object.* = was;
        object.tool_types = &list;
        if (!icon_base.PutDiskObject(&name, object)) app.notSaved(&name);
    }

    /// The setting `arg` as its tool type, `NAME=value`, into `line`;
    /// false for one not to be written - the hours, while they follow the
    /// locale.
    fn setting(app: *App, arg: Arg, name: [*:0]const u8, line: *[48:0]u8) bool {
        const settings = &app.settings;
        var value: [24:0]u8 = @splat(0);
        switch (arg) {
            .mode => copyText(&value, if (settings.digital) "DIGITAL" else "ANALOG"),
            .seconds => copyText(&value, if (settings.seconds) "YES" else "NO"),
            .date => copyText(&value, if (settings.date) "YES" else "NO"),
            .hours => {
                const hours = settings.hours orelse return false;
                copyText(&value, if (hours == 24) "24" else "12");
            },
            .left => writeNumber(app.sys, &value, settings.left),
            .top => writeNumber(app.sys, &value, settings.top),
            .analog_size => {
                _ = settings.analog.write(&value);
            },
            .digital_size => {
                _ = settings.figures.write(&value);
            },
            .pubscreen => return false,
        }
        const stream = exec.fmtStream(.{ name, @as([*:0]const u8, &value) });
        comptime exec.checkFormat("%s=%s", @TypeOf(.{ @as([*:0]const u8, ""), @as([*:0]const u8, "") }));
        _ = app.sys.RawDoFmt("%s=%s", &stream, null, line);
        return true;
    }

    fn notSaved(app: *App, name: [*:0]const u8) void {
        const easy = intuition.EasyStruct{
            .title = app.text.get(.MSG_WINDOW_TITLE),
            .text_format = app.text.get(.MSG_NOT_SAVED),
            .gadget_format = app.text.get(.MSG_OK),
        };
        comptime exec.checkFormat(strings.builtin(.MSG_NOT_SAVED), @TypeOf(.{@as([*:0]const u8, "")}));
        const stream = exec.fmtStream(.{name});
        _ = app.ib.EasyRequestArgs(app.window, &easy, null, &stream);
    }
};

fn writeNumber(sys: *ExecBase, into: *[24:0]u8, value: i32) void {
    const stream = exec.fmtStream(.{value});
    comptime exec.checkFormat("%d", @TypeOf(.{@as(i32, 0)}));
    _ = sys.RawDoFmt("%d", &stream, null, into);
}

fn isKept(entry: [*:0]const u8) bool {
    for (kept) |each| if (time.namedAs(entry, each.name)) return true;
    return false;
}

/// The program's own icon's name when it was started from a shell: its
/// name in its own drawer.
fn ownName(dl: *DosBase, into: *[dos.path_max + 1:0]u8) void {
    var program: [dos.path_max + 1:0]u8 = @splat(0);
    if (!dl.GetProgramName(&program, program.len)) copyText(&program, COMMAND_NAME);
    copyText(into, "PROGDIR:");
    _ = dl.AddPart(into, dl.FilePart(&program), into.len);
}

/// The Clock running, if there is one, told to show its window. True
/// when it was, and this start has nothing more to do.
fn handOver(sys: *ExecBase) bool {
    const reply = sys.CreateMsgPort() orelse return false;
    defer sys.DeleteMsgPort(reply);
    var message = exec.Message{ .reply_port = reply, .length = @sizeOf(exec.Message) };
    if (!sys.SafePutToPort(&message, PORT_NAME)) return false;
    _ = sys.WaitPort(reply);
    _ = sys.GetMsg(reply);
    return true;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var given = Given.read(sys, dl) orelse return dos.RETURN_FAIL;
    defer given.done();

    if (handOver(sys)) return dos.RETURN_OK;

    var text = Text.open(sys);
    defer text.close();

    var libraries: [2]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    for ([_][*:0]const u8{ intuition.INTUITIONNAME, graphics.GRAPHICSNAME }, 0..) |name, at| {
        libraries[at] = sys.OpenLibrary(name, 0) orelse {
            _ = text.printf(dl, .MSG_NOLIBRARY, .{ @as([*:0]const u8, COMMAND_NAME), name });
            return dos.RETURN_FAIL;
        };
    }
    const ib: *IntuitionBase = @ptrCast(libraries[0].?);
    const gb: *GraphicsBase = @ptrCast(libraries[1].?);

    // The port a second start finds; taken off first, so that nothing
    // more comes, and what came meanwhile answered.
    const public = sys.CreateMsgPort() orelse {
        _ = text.printf(dl, .MSG_NOMEMORY, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    };
    public.node.name = PORT_NAME;
    sys.AddPort(public);
    defer {
        sys.RemPort(public);
        while (sys.GetMsg(public)) |message| sys.ReplyMsg(message);
        sys.DeleteMsgPort(public);
    }

    var due: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &due.node, 0) != 0) {
        _ = text.printf(dl, .MSG_NOLIBRARY, .{ @as([*:0]const u8, COMMAND_NAME), @as([*:0]const u8, sdk.interface.timer.NAME) });
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(&due.node);
    const due_port = sys.CreateMsgPort() orelse {
        _ = text.printf(dl, .MSG_NOMEMORY, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    };
    defer sys.DeleteMsgPort(due_port);
    due.node.message.reply_port = due_port;

    var settings = given.settings();
    const screen_name: ?[*:0]const u8 = if (settings.pubscreen[0] != 0) &settings.pubscreen else null;
    const screen = ib.LockPubScreen(screen_name) orelse ib.LockPubScreen(null) orelse {
        _ = text.printf(dl, .MSG_NOWINDOW, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);
    const dri = ib.GetScreenDrawInfo(screen);
    defer ib.FreeScreenDrawInfo(screen, dri);

    const size = settings.size().*;
    var window_tags = [_]TagItem{
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_Title, .data = @intFromPtr(text.get(.MSG_WINDOW_TITLE)) },
        .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr(SCREEN_TITLE) },
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(@max(size.width, 48)) },
        .{ .tag = wn.WA_InnerHeight, .data = @intCast(@max(size.height, 40)) },
        .{ .tag = wn.WA_MinWidth, .data = 72 },
        .{ .tag = wn.WA_MinHeight, .data = 56 },
        .{ .tag = wn.WA_MaxWidth, .data = 0xFFFF },
        .{ .tag = wn.WA_MaxHeight, .data = 0xFFFF },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        // In the bottom border, which the date is beside anyway, rather
        // than a right border as wide as the gadget.
        .{ .tag = wn.WA_SizeBBottom, .data = 1 },
        .{ .tag = wn.WA_GimmeZeroZero, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW | wn.IDCMP_NEWSIZE | wn.IDCMP_REFRESHWINDOW | wn.IDCMP_MENUPICK | wn.IDCMP_MOUSEBUTTONS },
        // Where it was kept, or in the middle of the screen.
        .{ .tag = wn.WA_Position, .data = wn.WPOS_CENTERSCREEN },
        .{},
        .{},
    };
    if (settings.left >= 0 and settings.top >= 0) {
        window_tags[window_tags.len - 3] = .{ .tag = wn.WA_Left, .data = @intCast(settings.left) };
        window_tags[window_tags.len - 2] = .{ .tag = wn.WA_Top, .data = @intCast(settings.top) };
    }
    const window = ib.OpenWindowTagList(&window_tags) orelse {
        _ = text.printf(dl, .MSG_NOWINDOW, .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    };
    defer ib.CloseWindow(window);
    var rast_port: usize = 0;
    var user_port: usize = 0;
    ib.GetWindowAttrs(window, &[_]TagItem{
        .{ .tag = wn.WA_RastPort, .data = @intFromPtr(&rast_port) },
        .{ .tag = wn.WA_UserPort, .data = @intFromPtr(&user_port) },
        .{},
    });
    if (rast_port == 0 or user_port == 0) return dos.RETURN_FAIL;
    const window_port: *exec.MsgPort = @ptrFromInt(user_port);

    var app = App{
        .sys = sys,
        .dl = dl,
        .ib = ib,
        .gb = gb,
        .text = &text,
        .given = &given,
        .settings = settings,
        .window = window,
        .rp = @ptrFromInt(rast_port),
        .ground = dri.pens[sc.BACKGROUNDPEN],
        .ink = dri.pens[sc.TEXTPEN],
        .due = due,
    };
    defer app.disarm();
    defer app.dropCanvas();
    defer app.face.free(gb);
    defer app.panel.free(gb);
    if (text.locale) |loc| {
        app.locale_24 = time.twentyFour(loc.time_format);
        if (text.library) |lb| {
            if (lb.GetLocaleStr(loc, locale.AM_STR)) |am| app.am = am;
            if (lb.GetLocaleStr(loc, locale.PM_STR)) |pm| app.pm = pm;
        }
    }
    // The date and AM and PM in the screen's font, as the title bar is,
    // or the window's without one.
    var measure: [3]usize = @splat(0);
    gb.GetRPAttrs(app.rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(&measure[0]) }, .{} });
    if (dri.font) |font| measure[0] = @intFromPtr(font);
    app.font = measure[0];
    if (app.fit()) {
        gb.GetRPAttrs(app.canvas_rp.?, &[_]TagItem{
            .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&measure[1]) },
            .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&measure[2]) },
            .{},
        });
    }
    app.font_height = @intCast(measure[1]);
    app.baseline = @intCast(measure[2]);
    app.makeMenus(screen);
    defer app.dropMenus();

    const masks = .{ .window = window_port.sigMask(), .due = due_port.sigMask(), .public = public.sigMask() };
    while (true) {
        var now: dos.DateStamp = .{};
        _ = dl.DateStamp(&now);
        app.draw(now);
        app.arm(time.untilNext(now, app.step()));
        const got = sys.Wait(masks.window | masks.due | masks.public | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) break;
        if (got & masks.due != 0 and app.due_pending and sys.CheckIO(&app.due.node) != null) {
            _ = sys.WaitIO(&app.due.node);
            app.due_pending = false;
        }
        if (got & masks.public != 0) {
            while (sys.GetMsg(public)) |message| {
                ib.WindowToFront(window);
                ib.ActivateWindow(window);
                sys.ReplyMsg(message);
            }
        }
        if (!windowMessages(&app)) break;
    }
    return dos.RETURN_OK;
}

/// The window's messages, each answered; false when it is to close.
fn windowMessages(app: *App) bool {
    const ib = app.ib;
    while (ib.GetIMsg(app.window)) |message| {
        const class = message.class;
        const code = message.code;
        const seconds = message.seconds;
        const micros = message.micros;
        ib.ReplyIMsg(message);
        switch (class) {
            wn.IDCMP_CLOSEWINDOW => return false,
            wn.IDCMP_NEWSIZE => {
                _ = app.fit();
                app.keepSize();
            },
            wn.IDCMP_REFRESHWINDOW => app.refresh(),
            wn.IDCMP_MENUPICK => if (!app.picked(code)) return false,
            wn.IDCMP_MOUSEBUTTONS => if (code == wn.SELECTDOWN) {
                if (ib.DoubleClick(app.pressed[0], app.pressed[1], seconds, micros)) {
                    app.setMode(!app.settings.digital);
                    app.pressed = .{ 0, 0 };
                } else {
                    app.pressed = .{ seconds, micros };
                }
            },
            else => {},
        }
    }
    return true;
}
