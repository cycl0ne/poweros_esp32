// SPDX-License-Identifier: MIT
//! Dock: a row of icons along an edge of the screen, each opening what it
//! stands for - a program, a file, a drawer or a disk - with one click.
//! Built against the SDK only.
//!
//!   Dock QUIT/S
//!
//! **One dock** runs at a time, known by its public port "Dock": started
//! again it brings that one to the front, and with QUIT ends it. Ctrl-C
//! ends it too.
//!
//! **The window** has no border and stays in front of every ordinary
//! window (`WA_StayInFront`), centred along the edge dock.prefs names. Its
//! pictures are the entries' icons at ICONSIZE, no larger than an eighth
//! of the screen's height, as the desktop shows them; their names in the
//! desktop's font (font.prefs' ICON) are shown under them ALWAYS, in a
//! small window by the entry under the POINTER, or NEVER.
//!
//! **What a hand does with it:**
//! - A click opens the entry as a double click on its icon does
//!   (anvil.library's `OpenObject`).
//! - Files let go on an entry are opened with it; let go between two, or
//!   on a separator, they are put in as entries there.
//! - An entry dragged along the dock moves there; dragged off it, it is
//!   taken off.
//! - A press held still, or the right button while the dock is the active
//!   window, opens the entry's menu: Open, Information, Remove from Dock,
//!   Insert Separator, Quit Dock - the name first, so that a finger sees
//!   it too.
//! - Add to Dock in the desktop's Tools menu puts the icons picked there
//!   at the end.
//!
//! **What is kept:** the entries in ENV:Sys/dock.items, written there and
//! to ENVARC: whenever they change; the look in ENV:Sys/dock.prefs, which
//! Prefs writes. The dock follows both files while it runs, so a change
//! to either shows at once. With no dock.items it has the entries of
//! `sdk.prefs.dock.default_items`.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const icon = sdk.icon;
const anvil = sdk.anvil;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const motion = sdk.motion;
const rtg = sdk.rtg;
const utility = sdk.utility;
const notify = dos.notify;
const prefs = sdk.prefs;
const dock_prefs = prefs.dock;
const font_prefs = prefs.font;
const wn = intuition.windows;
const sc = intuition.screens;
const TagItem = utility.TagItem;
const Rect = graphics.Rect;
const Pen = graphics.Pen;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IconBase = sdk.interface.icon.IconBase;
const AnvilBase = sdk.interface.anvil.AnvilBase;
const MotionBase = sdk.interface.motion.MotionBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Dock";
const VERSION_STRING = "\x00$VER: Dock 1.0 (27.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "QUIT/S";
const arg_quit = 0;

/// The public port the running dock is known by.
const PORT_NAME = "Dock";

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NOSCREEN = "%s: no screen to show on\n";
const MSG_NOWINDOW = "%s: no window\n";
const MSG_NOTRUNNING = "%s: no dock is running\n";

/// The most entries a dock holds.
const entries_max = 48;
/// The longest name shown for an entry.
const label_max = 31;
/// Room round a picture in its cell, and at either end of the row.
const pad = 6;
const end_pad = 4;
/// How long a separator's cell is along the dock.
const separator_span = 2 * pad + 2;
/// How often the pointer is looked at while it matters, in
/// milliseconds; how many looks a press is held still before it opens
/// the entry's menu; and how far it moves, in pixels, before it drags.
const look_every = 100;
const long_press = 6;
const drag_after = 6;
/// How many looks pass between tries at the desktop while it does not
/// have the dock's window and menu item: two seconds.
const desktop_every = 20;

/// What the dock gives the desktop: its window, and Add to Dock.
const ID_WINDOW = 1;
const ID_ADD = 2;

/// What the files followed are told apart by: their requests' user data.
const WATCH_PREFS = 1;
const WATCH_ITEMS = 2;

/// What a second start sends the running dock.
const Command = extern struct {
    message: exec.Message = .{},
    /// Non-zero: quit. Else come to the front.
    quit: u32 = 0,
};

fn pair(t: utility.Tag, data: usize) TagItem {
    return .{ .tag = t, .data = data };
}

/// One entry: what it opens, its icon and picture, its name as shown, and
/// its cell along the dock.
const Entry = struct {
    /// Its full name, the entry's own copy; null for a separator.
    path: ?[*:0]u8 = null,
    object: ?*icon.DiskObject = null,
    /// The icon's picture at the dock's size, held from icon.library.
    picture: ?*const icon.IconImage = null,
    label: [label_max + 1]u8 = @splat(0),
    label_len: u32 = 0,
    /// Where its cell starts along the dock, and how long it is.
    start: i32 = 0,
    span: i32 = 0,

    fn item(e: *const Entry) dock_prefs.Item {
        const path = e.path orelse return .separator;
        return .{ .path = sliceOf(path) };
    }
};

/// How the dock is drawn: the names' font, the pictures' size, and the
/// pens - the ground and its light and dark edges, the names, the plate
/// under an entry held or a menu row under the pointer.
const Look = struct {
    font: ?*graphics.TextFont = null,
    font_height: i32 = 8,
    baseline: i32 = 6,
    size: i32 = 48,
    ground: Pen = 0xFFAA_AAAA,
    shine: Pen = 0xFFFF_FFFF,
    shadow: Pen = 0xFF00_0000,
    text: Pen = 0xFF00_0000,
    fill: Pen = 0xFF66_88BB,
    fill_text: Pen = 0xFF00_0000,
};

/// A press of the left button on the dock, from down to up.
const Press = struct {
    held: bool = false,
    /// The entry pressed; null on the ground between them.
    index: ?usize = null,
    /// Where it went down, in the window.
    x: i32 = 0,
    y: i32 = 0,
    /// Looks since.
    looks: u32 = 0,
    /// Whether it drags the entry, or opened its menu: either way it no
    /// longer opens the entry when it is let go.
    dragging: bool = false,
    spent: bool = false,
};

/// What the entry menu offers.
const Choice = enum { open, information, remove, separator, quit };
const choice_names = [_][*:0]const u8{ "Open", "Information", "Remove from Dock", "Insert Separator", "Quit Dock" };

/// The entry menu: a small window by the dock, the entry's name at its
/// top and a row for each choice.
const Menu = struct {
    window: ?*intuition.Window = null,
    rp: *graphics.RastPort = undefined,
    /// The entry it is for; null for the dock's ground.
    index: ?usize = null,
    choices: [choice_names.len]Choice = undefined,
    count: usize = 0,
    width: i32 = 0,
    /// How tall the name at the top is (0 for none), and each row.
    title_height: i32 = 0,
    row_height: i32 = 0,
    /// The row under the pointer, and whether the left button went down
    /// on the menu - only then does letting it go choose.
    hovered: ?usize = null,
    armed: bool = false,
};

const App = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ub: *UtilityBase,
    ib: *IntuitionBase,
    gb: *GraphicsBase,
    icons: *IconBase,
    ab: *AnvilBase,
    mb: *MotionBase,
    df: ?*DiskfontBase,
    screen: *intuition.Screen,
    screen_width: i32 = 0,
    screen_height: i32 = 0,
    bar_height: i32 = 0,

    settings: dock_prefs.Settings = .{},
    look: Look = .{},
    /// The names' font when it is font.prefs' and not the screen's: the
    /// dock's to close.
    own_font: ?*graphics.TextFont = null,
    entries: [entries_max]Entry = @splat(.{}),
    count: usize = 0,

    window: ?*intuition.Window = null,
    rp: *graphics.RastPort = undefined,
    /// The window's box on the screen.
    box: Rect = .{},
    press: Press = .{},
    menu: Menu = .{},
    /// The name by the entry under the pointer, and which entry.
    tip: ?*intuition.Window = null,
    tip_index: ?usize = null,

    app_port: *exec.MsgPort,
    app_window: ?*anvil.AppWindow = null,
    app_item: ?*anvil.AppMenuItem = null,
    /// Looks since the desktop was last tried.
    desktop_looks: u32 = 0,
    tick: *motion.Timer = undefined,
    ticking: bool = false,
    running: bool = true,

    // --- the entries ---------------------------------------------------------

    /// An entry made for `item`; null when there is no memory, or no
    /// name.
    fn makeEntry(app: *App, item: dock_prefs.Item) ?Entry {
        var e = Entry{};
        const path = switch (item) {
            .separator => return e,
            .path => |path| path,
        };
        if (path.len == 0 or path.len > dos.path_max) return null;
        const memory = app.sys.AllocVec(path.len + 1, exec.MEMF_ANY) orelse return null;
        const copy: [*]u8 = @ptrCast(memory);
        @memcpy(copy[0..path.len], path);
        copy[path.len] = 0;
        e.path = @ptrCast(copy);
        e.object = app.iconOf(e.path.?);
        app.takePicture(&e);
        // The name: the last part, or a disk's before its colon.
        var label = sliceOf(app.dl.FilePart(e.path.?));
        if (label.len == 0) label = if (indexOf(path, ':')) |colon| path[0..colon] else path;
        const length = @min(label.len, label_max);
        @memcpy(e.label[0..length], label[0..length]);
        e.label_len = @intCast(length);
        return e;
    }

    /// The icon of `path` - a disk's for a name that ends in its colon -
    /// or a default one for a file that has none.
    fn iconOf(app: *App, path: [*:0]const u8) ?*icon.DiskObject {
        const text = sliceOf(path);
        if (text.len == 0 or text[text.len - 1] != ':') return app.icons.GetDiskObjectNew(path);
        var name: [dos.path_max + 5]u8 = undefined;
        @memcpy(name[0..text.len], text);
        @memcpy(name[text.len..][0..5], "Disk\x00");
        return app.icons.GetDiskObjectNew(@ptrCast(&name));
    }

    /// The entry's picture at the look's size, the one it had given back.
    fn takePicture(app: *App, e: *Entry) void {
        if (e.picture) |held| app.icons.ReleaseIconImage(held);
        e.picture = null;
        const object = e.object orelse return;
        const image = object.image orelse return;
        e.picture = app.icons.ObtainIconImage(image, @intCast(app.look.size));
    }

    fn freeEntry(app: *App, e: *Entry) void {
        if (e.picture) |held| app.icons.ReleaseIconImage(held);
        app.icons.FreeDiskObject(e.object);
        if (e.path) |path| app.sys.FreeVec(path);
        e.* = .{};
    }

    /// `item` put in at `at`; whether there was room.
    fn insert(app: *App, at: usize, item: dock_prefs.Item) bool {
        if (app.count == entries_max) return false;
        const made = app.makeEntry(item) orelse return false;
        var i = app.count;
        while (i > at) : (i -= 1) app.entries[i] = app.entries[i - 1];
        app.entries[at] = made;
        app.count += 1;
        return true;
    }

    fn remove(app: *App, at: usize) void {
        app.freeEntry(&app.entries[at]);
        for (at..app.count - 1) |i| app.entries[i] = app.entries[i + 1];
        app.count -= 1;
        app.entries[app.count] = .{};
    }

    /// The entry at `from` moved to stand before the one now at `to`
    /// (`count` for the end).
    fn move(app: *App, from: usize, to: usize) void {
        const moving = app.entries[from];
        if (to > from) {
            for (from..to - 1) |i| app.entries[i] = app.entries[i + 1];
            app.entries[to - 1] = moving;
        } else {
            var i = from;
            while (i > to) : (i -= 1) app.entries[i] = app.entries[i - 1];
            app.entries[to] = moving;
        }
    }

    fn removeAll(app: *App) void {
        while (app.count > 0) app.remove(app.count - 1);
    }

    /// The entries dock.items lists, or the dock's own without one.
    fn readItems(app: *App) void {
        const text = prefs.loadWhole(app.sys, app.dl, dock_prefs.ITEMS_ENV_FILE) orelse {
            for (dock_prefs.default_items) |item| _ = app.insert(app.count, item);
            return;
        };
        defer app.sys.FreeVec(text.ptr);
        var items = dock_prefs.Items.init(app.ub, text);
        while (items.next()) |item| _ = app.insert(app.count, item);
    }

    /// dock.items changed: read again, and shown when it is not what the
    /// dock has - as it is after the dock wrote it itself.
    fn itemsChanged(app: *App) void {
        const text = prefs.loadWhole(app.sys, app.dl, dock_prefs.ITEMS_ENV_FILE) orelse return;
        defer app.sys.FreeVec(text.ptr);
        var items = dock_prefs.Items.init(app.ub, text);
        var n: usize = 0;
        const same = while (items.next()) |item| : (n += 1) {
            if (n == app.count or !sameItem(item, app.entries[n].item())) break false;
        } else n == app.count;
        if (same) return;
        app.closeMenu();
        app.closeTip();
        app.removeAll();
        items = dock_prefs.Items.init(app.ub, text);
        while (items.next()) |item| _ = app.insert(app.count, item);
        app.reshape();
    }

    /// The entries written to ENV: and ENVARC:.
    fn save(app: *App) void {
        var length: usize = dock_prefs.items_header.len;
        for (app.entries[0..app.count]) |*e| length += dock_prefs.itemLength(e.item());
        const memory = app.sys.AllocVec(length, exec.MEMF_ANY) orelse return;
        defer app.sys.FreeVec(memory);
        const text: [*]u8 = @ptrCast(memory);
        @memcpy(text[0..dock_prefs.items_header.len], dock_prefs.items_header);
        var n: usize = dock_prefs.items_header.len;
        for (app.entries[0..app.count]) |*e| n += dock_prefs.itemLine(e.item(), text[n..length]) orelse 0;
        _ = prefs.save(app.dl, dock_prefs.ITEMS_ENV_FILE, text[0..n]);
        _ = prefs.save(app.dl, dock_prefs.ITEMS_ENVARC_FILE, text[0..n]);
    }

    // --- the look and the shape -----------------------------------------------

    fn readSettings(app: *App) void {
        var settings = dock_prefs.Settings{};
        if (prefs.loadWhole(app.sys, app.dl, dock_prefs.ENV_FILE)) |text| {
            defer app.sys.FreeVec(text.ptr);
            if (prefs.firstLine(text)) |line| {
                var read = settings;
                if (dock_prefs.parse(app.ub, line, &read) == null) settings = read;
            }
        }
        app.settings = settings;
    }

    /// The names' font: font.prefs' ICON, else its DEFAULT; null for the
    /// screen's.
    fn readFont(app: *App) ?*graphics.TextFont {
        const df = app.df orelse return null;
        const read = prefs.loadWhole(app.sys, app.dl, font_prefs.ENV_FILE) orelse return null;
        defer app.sys.FreeVec(read.ptr);
        const words = prefs.firstLine(read) orelse return null;
        var line: font_prefs.Line = .{};
        if (font_prefs.parse(app.ub, words, &line) != null) return null;
        const given = line.get(.icon) orelse line.get(.default) orelse return null;
        var family: [font_prefs.value_len:0]u8 = undefined;
        const wanted = font_prefs.attrOf(given, &family) orelse return null;
        return df.OpenDiskFont(&wanted);
    }

    /// The look as the settings, the font and the screen's pens have it:
    /// the pictures no larger than an eighth of the screen's height.
    fn makeLook(app: *App) void {
        const old_font = app.own_font;
        app.own_font = app.readFont();
        const draw_info = app.ib.GetScreenDrawInfo(app.screen);
        defer app.ib.FreeScreenDrawInfo(app.screen, draw_info);
        const font = app.own_font orelse draw_info.font;
        const pens = draw_info.pens;
        app.look = .{
            .font = font,
            .size = @intCast(@min(app.settings.icon_size, @max(24, @as(u32, @intCast(app.screen_height)) / 8))),
            .ground = pens[sc.BACKGROUNDPEN],
            .shine = pens[sc.SHINEPEN],
            .shadow = pens[sc.SHADOWPEN],
            .text = pens[sc.TEXTPEN],
            .fill = pens[sc.FILLPEN],
            .fill_text = pens[sc.FILLTEXTPEN],
        };
        if (font) |shown| {
            app.look.font_height = shown.image.height;
            app.look.baseline = shown.image.baseline;
        }
        if (old_font) |held| app.gb.CloseFont(held);
    }

    /// An entry's cell: as wide as a picture and the room round it - half
    /// a picture wider when the names are always shown - and as tall,
    /// with a line for the name under it then.
    fn cellWidth(app: *const App) i32 {
        var width = app.look.size + 2 * pad;
        if (app.settings.labels == .always) width += @divTrunc(app.look.size, 2);
        return width;
    }

    fn cellHeight(app: *const App) i32 {
        var height = app.look.size + 2 * pad;
        if (app.settings.labels == .always) height += app.look.font_height + 2;
        return height;
    }

    fn upright(app: *const App) bool {
        return app.settings.upright();
    }

    /// Each entry's cell along the dock, and the window's box: along its
    /// edge, centred, no longer than the screen.
    fn layout(app: *App) Rect {
        const span = if (app.upright()) app.cellHeight() else app.cellWidth();
        const across = if (app.upright()) app.cellWidth() else app.cellHeight();
        var along: i32 = end_pad;
        for (app.entries[0..app.count]) |*e| {
            e.start = along;
            e.span = if (e.path == null) separator_span else span;
            along += e.span;
        }
        // An empty dock keeps a cell's room, to let files go on.
        if (app.count == 0) along += span;
        along += end_pad;
        const room_top = app.bar_height;
        const room_height = app.screen_height - room_top;
        return switch (app.settings.edge) {
            .bottom, .top => blk: {
                const width = @min(along, app.screen_width);
                const left = @divTrunc(app.screen_width - width, 2);
                const top = if (app.settings.edge == .bottom) app.screen_height - across else room_top;
                break :blk .{ .min_x = left, .min_y = top, .max_x = left + width, .max_y = top + across };
            },
            .left, .right => blk: {
                const height = @min(along, room_height);
                const top = room_top + @divTrunc(room_height - height, 2);
                const left = if (app.settings.edge == .left) 0 else app.screen_width - across;
                break :blk .{ .min_x = left, .min_y = top, .max_x = left + across, .max_y = top + height };
            },
        };
    }

    /// The entries changed: laid out again, the window given its new box
    /// and drawn.
    fn reshape(app: *App) void {
        const box = app.layout();
        const window = app.window orelse return;
        if (box.min_x != app.box.min_x or box.min_y != app.box.min_y or box.max_x != app.box.max_x or box.max_y != app.box.max_y) {
            app.ib.ChangeWindowBox(window, box.min_x, box.min_y, box.max_x - box.min_x, box.max_y - box.min_y);
            app.readBox();
        }
        app.draw();
    }

    /// dock.prefs or font.prefs changed: the look made again, every
    /// picture taken at its size, and the dock shaped anew.
    fn renew(app: *App) void {
        app.closeMenu();
        app.closeTip();
        app.readSettings();
        app.makeLook();
        if (app.window != null) app.setFont(app.rp);
        for (app.entries[0..app.count]) |*e| app.takePicture(e);
        app.reshape();
        app.tickAsNeeded();
    }

    fn readBox(app: *App) void {
        const window = app.window orelse return;
        var left: usize = 0;
        var top: usize = 0;
        var width: usize = 0;
        var height: usize = 0;
        app.ib.GetWindowAttrs(window, &[_]TagItem{
            pair(wn.WA_Left, @intFromPtr(&left)),
            pair(wn.WA_Top, @intFromPtr(&top)),
            pair(wn.WA_Width, @intFromPtr(&width)),
            pair(wn.WA_Height, @intFromPtr(&height)),
            .{},
        });
        const x: i32 = @intCast(@as(isize, @bitCast(left)));
        const y: i32 = @intCast(@as(isize, @bitCast(top)));
        app.box = .{ .min_x = x, .min_y = y, .max_x = x + @as(i32, @intCast(width)), .max_y = y + @as(i32, @intCast(height)) };
    }

    // --- drawing --------------------------------------------------------------

    fn setFont(app: *App, rp: *graphics.RastPort) void {
        if (app.look.font) |font| app.gb.SetRPAttrs(rp, &[_]TagItem{ pair(graphics.RPTAG_Font, @intFromPtr(font)), .{} });
    }

    fn pen(app: *App, rp: *graphics.RastPort, colour: Pen) void {
        app.gb.SetRPAttrs(rp, &[_]TagItem{ pair(graphics.RPTAG_APen, colour), pair(graphics.RPTAG_DrMd, graphics.DRMD_JAM1), .{} });
    }

    fn fill(app: *App, rp: *graphics.RastPort, colour: Pen, area: Rect) void {
        app.pen(rp, colour);
        app.gb.RectFill(rp, &area);
    }

    /// A light line along the top and left of `area`, a dark one along
    /// its bottom and right.
    fn bevel(app: *App, rp: *graphics.RastPort, area: Rect) void {
        app.fill(rp, app.look.shine, .{ .min_x = area.min_x, .min_y = area.min_y, .max_x = area.max_x, .max_y = area.min_y + 1 });
        app.fill(rp, app.look.shine, .{ .min_x = area.min_x, .min_y = area.min_y, .max_x = area.min_x + 1, .max_y = area.max_y });
        app.fill(rp, app.look.shadow, .{ .min_x = area.min_x, .min_y = area.max_y - 1, .max_x = area.max_x, .max_y = area.max_y });
        app.fill(rp, app.look.shadow, .{ .min_x = area.max_x - 1, .min_y = area.min_y, .max_x = area.max_x, .max_y = area.max_y });
    }

    /// An entry's cell in the window.
    fn cellOf(app: *const App, e: *const Entry) Rect {
        const width = app.box.max_x - app.box.min_x;
        const height = app.box.max_y - app.box.min_y;
        if (app.upright()) return .{ .min_x = 0, .min_y = e.start, .max_x = width, .max_y = e.start + e.span };
        return .{ .min_x = e.start, .min_y = 0, .max_x = e.start + e.span, .max_y = height };
    }

    /// Where an entry's picture is drawn: centred across its cell, its
    /// foot on the line every picture stands on.
    fn pictureOf(app: *const App, e: *const Entry) ?Rect {
        const picture = e.picture orelse return null;
        const cell = app.cellOf(e);
        const w: i32 = @intCast(picture.width);
        const h: i32 = @intCast(picture.height);
        const x = cell.min_x + @divTrunc(cell.max_x - cell.min_x - w, 2);
        const y = cell.min_y + pad + app.look.size - h;
        return .{ .min_x = x, .min_y = y, .max_x = x + w, .max_y = y + h };
    }

    fn draw(app: *App) void {
        if (app.window == null) return;
        const whole = Rect{ .min_x = 0, .min_y = 0, .max_x = app.box.max_x - app.box.min_x, .max_y = app.box.max_y - app.box.min_y };
        app.gb.BeginDraw(app.rp);
        app.fill(app.rp, app.look.ground, whole);
        app.bevel(app.rp, whole);
        for (0..app.count) |i| app.drawEntry(i);
        app.gb.EndDraw(app.rp);
    }

    /// One entry drawn on the ground: a separator's line, or the picture -
    /// on the fill pen's plate while it is held - and the name when the
    /// names are always shown.
    fn drawEntry(app: *App, index: usize) void {
        const rp = app.rp;
        const e = &app.entries[index];
        var cell = app.cellOf(e);
        // Inside the dock's bevel.
        if (app.upright()) {
            cell.min_x += 1;
            cell.max_x -= 1;
        } else {
            cell.min_y += 1;
            cell.max_y -= 1;
        }
        app.fill(rp, app.look.ground, cell);
        if (e.path == null) {
            const line = if (app.upright())
                Rect{ .min_x = cell.min_x + pad, .min_y = cell.min_y + @divTrunc(e.span, 2) - 1, .max_x = cell.max_x - pad, .max_y = cell.min_y + @divTrunc(e.span, 2) }
            else
                Rect{ .min_x = cell.min_x + @divTrunc(e.span, 2) - 1, .min_y = cell.min_y + pad, .max_x = cell.min_x + @divTrunc(e.span, 2), .max_y = cell.max_y - pad };
            app.fill(rp, app.look.shadow, line);
            const light = if (app.upright())
                Rect{ .min_x = line.min_x, .min_y = line.max_y, .max_x = line.max_x, .max_y = line.max_y + 1 }
            else
                Rect{ .min_x = line.max_x, .min_y = line.min_y, .max_x = line.max_x + 1, .max_y = line.max_y };
            app.fill(rp, app.look.shine, light);
            return;
        }
        const held = app.press.held and app.press.index == index and !app.press.dragging and !app.press.spent;
        if (app.pictureOf(e)) |area| {
            if (held) {
                const plate = Rect{ .min_x = area.min_x - 3, .min_y = area.min_y - 3, .max_x = area.max_x + 3, .max_y = area.max_y + 3 };
                app.pen(rp, (app.look.fill & 0x00FF_FFFF) | 0x8000_0000);
                app.gb.FillRoundRect(rp, &plate, 6);
            }
            const picture = e.picture.?;
            app.gb.BlendPixelArray(rp, picture.pixels, picture.width * 4, @intFromEnum(rtg.PixelFormat.rgba32), 0, 0, &area);
        }
        if (app.settings.labels != .always) return;
        const room = cell.max_x - cell.min_x - 4;
        var extent: graphics.TextExtent = undefined;
        const fits = app.gb.TextFit(rp, &e.label, e.label_len, &extent, null, 1, room, app.look.font_height + 8);
        const width = app.gb.TextLength(rp, &e.label, fits);
        const x = cell.min_x + @divTrunc(cell.max_x - cell.min_x - width, 2);
        const y = cell.min_y + pad + app.look.size + 2;
        app.pen(rp, app.look.text);
        app.gb.Move(rp, x, y + app.look.baseline);
        app.gb.Text(rp, &e.label, fits);
    }

    // --- where things are -----------------------------------------------------

    /// The entry at (`x`, `y`) in the window.
    fn entryAt(app: *const App, x: i32, y: i32) ?usize {
        if (x < 0 or y < 0 or x >= app.box.max_x - app.box.min_x or y >= app.box.max_y - app.box.min_y) return null;
        const along = if (app.upright()) y else x;
        for (app.entries[0..app.count], 0..) |*e, i| {
            if (along >= e.start and along < e.start + e.span) return i;
        }
        return null;
    }

    /// Where something let go at (`x`, `y`) goes: before which entry -
    /// the one whose cell's middle is past it - `count` for the end.
    fn placeAt(app: *const App, x: i32, y: i32) usize {
        const along = if (app.upright()) y else x;
        for (app.entries[0..app.count], 0..) |*e, i| {
            if (along < e.start + @divTrunc(e.span, 2)) return i;
        }
        return app.count;
    }

    /// The entry files let go at (`x`, `y`) are opened with: one whose
    /// middle half they are on - not a separator's.
    fn targetAt(app: *const App, x: i32, y: i32) ?usize {
        const index = app.entryAt(x, y) orelse return null;
        const e = &app.entries[index];
        if (e.path == null) return null;
        const along = if (app.upright()) y else x;
        const quarter = @divTrunc(e.span, 4);
        if (along < e.start + quarter or along >= e.start + e.span - quarter) return null;
        return index;
    }

    fn pointer(app: *App) struct { x: i32, y: i32 } {
        var x: usize = 0;
        var y: usize = 0;
        app.ib.GetScreenAttrs(app.screen, &[_]TagItem{ pair(sc.SA_MouseX, @intFromPtr(&x)), pair(sc.SA_MouseY, @intFromPtr(&y)), .{} });
        return .{ .x = @intCast(@as(isize, @bitCast(x))), .y = @intCast(@as(isize, @bitCast(y))) };
    }

    // --- what the entries do --------------------------------------------------

    fn open(app: *App, index: usize) void {
        const path = app.entries[index].path orelse return;
        if (!app.ab.OpenObject(path, null)) app.ib.DisplayBeep(app.screen);
    }

    /// The entry opened with the files a message carries.
    fn openWith(app: *App, index: usize, args: []const dos.WBArg) void {
        const path = app.entries[index].path orelse return;
        const count = @min(args.len, anvil.OPEN_FILES_MAX);
        const each = dos.path_max + 1;
        const memory = app.sys.AllocVec(count * each, exec.MEMF_ANY) orelse return;
        defer app.sys.FreeVec(memory);
        const names: [*]u8 = @ptrCast(memory);
        var tags: [anvil.OPEN_FILES_MAX + 1]TagItem = undefined;
        var n: usize = 0;
        for (args[0..count]) |arg| {
            const name = fullName(app.dl, arg, names[n * each ..][0..each]) orelse continue;
            tags[n] = pair(anvil.ANVO_File, @intFromPtr(name));
            n += 1;
        }
        tags[n] = .{};
        if (!app.ab.OpenObject(path, &tags)) app.ib.DisplayBeep(app.screen);
    }

    /// The files a message carries put in as entries from `at` on.
    fn putIn(app: *App, at: usize, args: []const dos.WBArg) void {
        var name: [dos.path_max + 1]u8 = undefined;
        var place = at;
        for (args) |arg| {
            const full = fullName(app.dl, arg, &name) orelse continue;
            if (!app.insert(place, .{ .path = sliceOf(full) })) break;
            place += 1;
        }
        if (place == at) return;
        app.save();
        app.reshape();
    }

    // --- the dock's window ----------------------------------------------------

    fn dockInput(app: *App, class: u32, code: u32, x: i32, y: i32) void {
        switch (class) {
            wn.IDCMP_MOUSEBUTTONS => switch (code) {
                wn.SELECTDOWN => app.pressDown(x, y),
                wn.SELECTUP => app.pressUp(x, y),
                wn.MENUDOWN => {
                    if (app.press.held) return;
                    const at = app.pointer();
                    app.openMenu(app.entryAt(x, y), at.x, at.y);
                },
                else => {},
            },
            wn.IDCMP_MOUSEMOVE => app.pressMoved(x, y),
            wn.IDCMP_REFRESHWINDOW => {
                const window = app.window.?;
                app.ib.BeginRefresh(window);
                app.draw();
                app.ib.EndRefresh(window, true);
            },
            else => {},
        }
    }

    fn pressDown(app: *App, x: i32, y: i32) void {
        app.closeTip();
        app.closeMenu();
        app.press = .{ .held = true, .index = app.entryAt(x, y), .x = x, .y = y };
        if (app.press.index) |index| app.redrawEntry(index);
        app.tickAsNeeded();
    }

    /// The pointer moved with the button down: far enough, and the entry
    /// is dragged.
    fn pressMoved(app: *App, x: i32, y: i32) void {
        if (!app.press.held or app.press.dragging or app.press.spent) return;
        const index = app.press.index orelse return;
        if (@abs(x - app.press.x) < drag_after and @abs(y - app.press.y) < drag_after) return;
        const e = &app.entries[index];
        const area = app.pictureOf(e) orelse return;
        const picture = e.picture.?;
        const surface = rtg.Surface{ .pixels = @constCast(picture.pixels), .width = picture.width, .height = picture.height, .pitch = picture.width * 4, .format = .rgba32 };
        const hot_x: u32 = @intCast(@max(0, @min(app.press.x - area.min_x, area.max_x - area.min_x - 1)));
        const hot_y: u32 = @intCast(@max(0, @min(app.press.y - area.min_y, area.max_y - area.min_y - 1)));
        if (!app.ib.BeginDrag(app.window.?, &surface, hot_x, hot_y)) {
            app.press.spent = true;
        } else {
            app.press.dragging = true;
        }
        app.redrawEntry(index);
    }

    fn pressUp(app: *App, x: i32, y: i32) void {
        const press = app.press;
        app.press = .{};
        app.tickAsNeeded();
        if (!press.held) return;
        const index = press.index orelse return;
        if (press.dragging) return app.dropped(index, x, y);
        app.redrawEntry(index);
        if (press.spent) return;
        if (app.entryAt(x, y) == index) app.open(index);
    }

    /// A press that opened the menu let go on the menu, not the dock.
    fn pressGone(app: *App) void {
        if (!app.press.held or app.press.dragging) return;
        app.press = .{};
        app.tickAsNeeded();
    }

    /// A dragged entry let go: on the dock it moves there, anywhere else
    /// it is taken off.
    fn dropped(app: *App, index: usize, x: i32, y: i32) void {
        const over = app.ib.EndDrag(app.window.?, 0);
        if (over == app.window) {
            const to = app.placeAt(x, y);
            if (to == index or to == index + 1) return app.redrawEntry(index);
            app.move(index, to);
        } else {
            app.remove(index);
        }
        app.save();
        app.reshape();
    }

    fn redrawEntry(app: *App, index: usize) void {
        if (app.window == null or index >= app.count) return;
        app.gb.BeginDraw(app.rp);
        app.drawEntry(index);
        app.gb.EndDraw(app.rp);
    }

    // --- the pointer looked at ------------------------------------------------

    /// Whether the dock needs to look at the pointer: a press is held, its
    /// names are shown by the pointer, or the desktop is to be tried.
    fn wantsTicks(app: *const App) bool {
        return app.press.held or app.settings.labels == .pointer or app.app_window == null or app.app_item == null;
    }

    fn tickAsNeeded(app: *App) void {
        const wanted = app.wantsTicks();
        if (wanted == app.ticking) return;
        if (wanted) app.mb.StartTimer(app.tick) else app.mb.StopTimer(app.tick);
        app.ticking = wanted;
    }

    fn ticked(app: *App) void {
        if (app.app_window == null or app.app_item == null) {
            app.desktop_looks += 1;
            if (app.desktop_looks >= desktop_every) {
                app.desktop_looks = 0;
                app.joinDesktop();
            }
        }
        if (app.press.held) {
            app.press.looks += 1;
            // A pointer that does not report its moves is looked at.
            const at = app.pointer();
            app.pressMoved(at.x - app.box.min_x, at.y - app.box.min_y);
            if (app.press.looks >= long_press and !app.press.dragging and !app.press.spent) {
                app.press.spent = true;
                if (app.press.index) |index| app.redrawEntry(index);
                app.openMenu(app.press.index, at.x, at.y);
            }
        } else if (app.settings.labels == .pointer and app.menu.window == null) {
            const at = app.pointer();
            const index = app.entryAt(at.x - app.box.min_x, at.y - app.box.min_y);
            const named = if (index) |i| (if (app.entries[i].path != null) i else null) else null;
            if (named != app.tip_index) {
                app.closeTip();
                if (named) |i| app.openTip(i);
            }
        }
        app.tickAsNeeded();
    }

    /// The window and Add to Dock given to the desktop, those it does not
    /// have yet; false for each while no desktop runs.
    fn joinDesktop(app: *App) void {
        if (app.app_window == null) app.app_window = app.ab.AddAppWindow(ID_WINDOW, 0, app.window.?, app.app_port, null);
        if (app.app_item == null) app.app_item = app.ab.AddAppMenuItem(ID_ADD, 0, "Add to Dock", app.app_port, null);
    }

    fn appMessage(app: *App, am: *const anvil.AppMessage) void {
        const args: []const dos.WBArg = if (am.arg_list) |list| list[0..am.num_args] else &.{};
        switch (am.kind) {
            anvil.AMTYPE_APPWINDOW => {
                if (args.len == 0) return;
                if (app.targetAt(am.mouse_x, am.mouse_y)) |index| return app.openWith(index, args);
                app.putIn(app.placeAt(am.mouse_x, am.mouse_y), args);
            },
            anvil.AMTYPE_APPMENUITEM => app.putIn(app.count, args),
            // The desktop quits: taken back, and given to the next one.
            anvil.AMTYPE_QUIT => {
                if (am.id == ID_WINDOW) {
                    _ = app.ab.RemoveAppWindow(app.app_window);
                    app.app_window = null;
                } else if (am.id == ID_ADD) {
                    _ = app.ab.RemoveAppMenuItem(app.app_item);
                    app.app_item = null;
                }
                app.tickAsNeeded();
            },
            else => {},
        }
    }

    // --- the name by the pointer ----------------------------------------------

    fn openTip(app: *App, index: usize) void {
        const e = &app.entries[index];
        if (e.label_len == 0) return;
        app.setFont(app.rp);
        const text_width = app.gb.TextLength(app.rp, &e.label, e.label_len);
        const width = text_width + 12;
        const height = app.look.font_height + 6;
        const cell = app.cellOf(e);
        const middle_x = app.box.min_x + @divTrunc(cell.min_x + cell.max_x, 2);
        const middle_y = app.box.min_y + @divTrunc(cell.min_y + cell.max_y, 2);
        var x: i32 = undefined;
        var y: i32 = undefined;
        switch (app.settings.edge) {
            .bottom => {
                x = middle_x - @divTrunc(width, 2);
                y = app.box.min_y - height - 2;
            },
            .top => {
                x = middle_x - @divTrunc(width, 2);
                y = app.box.max_y + 2;
            },
            .left => {
                x = app.box.max_x + 2;
                y = middle_y - @divTrunc(height, 2);
            },
            .right => {
                x = app.box.min_x - width - 2;
                y = middle_y - @divTrunc(height, 2);
            },
        }
        x = @max(0, @min(x, app.screen_width - width));
        y = @max(app.bar_height, @min(y, app.screen_height - height));
        const tip = app.ib.OpenWindowTagList(&[_]TagItem{
            pair(wn.WA_Left, @bitCast(@as(isize, x))),
            pair(wn.WA_Top, @bitCast(@as(isize, y))),
            pair(wn.WA_Width, @intCast(width)),
            pair(wn.WA_Height, @intCast(height)),
            pair(wn.WA_PubScreen, @intFromPtr(app.screen)),
            pair(wn.WA_Borderless, 1),
            pair(wn.WA_StayInFront, 1),
            pair(wn.WA_IDCMP, 0),
            .{},
        }) orelse return;
        app.tip = tip;
        app.tip_index = index;
        const rp: *graphics.RastPort = @ptrFromInt(windowAttr(app.ib, tip, wn.WA_RastPort));
        app.setFont(rp);
        const whole = Rect{ .min_x = 0, .min_y = 0, .max_x = width, .max_y = height };
        app.gb.BeginDraw(rp);
        app.fill(rp, app.look.ground, whole);
        app.bevel(rp, whole);
        app.pen(rp, app.look.text);
        app.gb.Move(rp, 6, 3 + app.look.baseline);
        app.gb.Text(rp, &e.label, e.label_len);
        app.gb.EndDraw(rp);
    }

    fn closeTip(app: *App) void {
        if (app.tip) |tip| app.ib.CloseWindow(tip);
        app.tip = null;
        app.tip_index = null;
    }

    // --- the entry menu -------------------------------------------------------

    /// The menu for the entry `index` (null: the dock's ground), by the
    /// dock where the pointer is (`x`, `y` on the screen) - beside it, so
    /// that a button let go where it went down chooses nothing.
    fn openMenu(app: *App, index: ?usize, x: i32, y: i32) void {
        app.closeTip();
        app.closeMenu();
        var m = Menu{ .index = index };
        const e: ?*const Entry = if (index) |i| &app.entries[i] else null;
        const is_entry = if (e) |shown| shown.path != null else false;
        const choices: []const Choice = if (is_entry)
            &.{ .open, .information, .remove, .separator, .quit }
        else if (e != null)
            &.{ .remove, .quit }
        else
            &.{ .separator, .quit };
        @memcpy(m.choices[0..choices.len], choices);
        m.count = choices.len;

        app.setFont(app.rp);
        m.row_height = app.look.font_height + 6;
        var widest: i32 = 0;
        for (choices) |choice| {
            const name = choice_names[@intFromEnum(choice)];
            widest = @max(widest, app.gb.TextLength(app.rp, name, @intCast(sliceOf(name).len)));
        }
        if (is_entry) {
            widest = @max(widest, app.gb.TextLength(app.rp, &e.?.label, e.?.label_len));
            m.title_height = m.row_height + 2;
        }
        m.width = widest + 24;
        const height = m.title_height + @as(i32, @intCast(m.count)) * m.row_height + 4;
        var left: i32 = undefined;
        var top: i32 = undefined;
        switch (app.settings.edge) {
            .bottom => {
                left = x - @divTrunc(m.width, 2);
                top = app.box.min_y - height - 2;
            },
            .top => {
                left = x - @divTrunc(m.width, 2);
                top = app.box.max_y + 2;
            },
            .left => {
                left = app.box.max_x + 2;
                top = y - @divTrunc(height, 2);
            },
            .right => {
                left = app.box.min_x - m.width - 2;
                top = y - @divTrunc(height, 2);
            },
        }
        left = @max(0, @min(left, app.screen_width - m.width));
        top = @max(app.bar_height, @min(top, app.screen_height - height));
        const window = app.ib.OpenWindowTagList(&[_]TagItem{
            pair(wn.WA_Left, @bitCast(@as(isize, left))),
            pair(wn.WA_Top, @bitCast(@as(isize, top))),
            pair(wn.WA_Width, @intCast(m.width)),
            pair(wn.WA_Height, @intCast(height)),
            pair(wn.WA_PubScreen, @intFromPtr(app.screen)),
            pair(wn.WA_Borderless, 1),
            pair(wn.WA_StayInFront, 1),
            pair(wn.WA_Activate, 1),
            pair(wn.WA_RMBTrap, 1),
            pair(wn.WA_ReportMouse, 1),
            pair(wn.WA_IDCMP, wn.IDCMP_MOUSEBUTTONS | wn.IDCMP_MOUSEMOVE | wn.IDCMP_INACTIVEWINDOW | wn.IDCMP_VANILLAKEY),
            .{},
        }) orelse return;
        m.window = window;
        m.rp = @ptrFromInt(windowAttr(app.ib, window, wn.WA_RastPort));
        app.menu = m;
        app.setFont(m.rp);
        app.drawMenu();
        app.tickAsNeeded();
    }

    fn closeMenu(app: *App) void {
        if (app.menu.window) |window| app.ib.CloseWindow(window);
        app.menu = .{};
    }

    fn drawMenu(app: *App) void {
        const m = &app.menu;
        if (m.window == null) return;
        const rp = m.rp;
        const whole = Rect{ .min_x = 0, .min_y = 0, .max_x = m.width, .max_y = m.title_height + @as(i32, @intCast(m.count)) * m.row_height + 4 };
        app.gb.BeginDraw(rp);
        app.fill(rp, app.look.ground, whole);
        app.bevel(rp, whole);
        if (m.title_height > 0) {
            const e = &app.entries[m.index.?];
            app.pen(rp, app.look.text);
            app.gb.Move(rp, 12, 2 + 3 + app.look.baseline);
            app.gb.Text(rp, &e.label, e.label_len);
            app.fill(rp, app.look.shadow, .{ .min_x = 4, .min_y = m.title_height, .max_x = m.width - 4, .max_y = m.title_height + 1 });
        }
        for (0..m.count) |row| {
            const area = app.rowBox(row);
            const hovered = m.hovered == row;
            if (hovered) app.fill(rp, app.look.fill, area);
            const name = choice_names[@intFromEnum(m.choices[row])];
            app.pen(rp, if (hovered) app.look.fill_text else app.look.text);
            app.gb.Move(rp, 12, area.min_y + 3 + app.look.baseline);
            app.gb.Text(rp, name, @intCast(sliceOf(name).len));
        }
        app.gb.EndDraw(rp);
    }

    fn rowBox(app: *const App, row: usize) Rect {
        const m = &app.menu;
        const top = 2 + m.title_height + @as(i32, @intCast(row)) * m.row_height;
        return .{ .min_x = 2, .min_y = top, .max_x = m.width - 2, .max_y = top + m.row_height };
    }

    fn rowAt(app: *const App, x: i32, y: i32) ?usize {
        for (0..app.menu.count) |row| {
            const area = app.rowBox(row);
            if (x >= area.min_x and x < area.max_x and y >= area.min_y and y < area.max_y) return row;
        }
        return null;
    }

    fn menuInput(app: *App, class: u32, code: u32, x: i32, y: i32) void {
        switch (class) {
            wn.IDCMP_MOUSEMOVE => app.hover(app.rowAt(x, y)),
            wn.IDCMP_MOUSEBUTTONS => switch (code) {
                wn.SELECTDOWN => {
                    app.menu.armed = true;
                    app.hover(app.rowAt(x, y));
                },
                wn.SELECTUP => {
                    // The press held on the dock that opened the menu,
                    // let go here: it is over, and chooses nothing.
                    if (!app.menu.armed) return app.pressGone();
                    app.menu.armed = false;
                    if (app.rowAt(x, y)) |row| app.choose(row);
                },
                // The right button held from the dock and let go on a row.
                wn.MENUUP => if (app.rowAt(x, y)) |row| app.choose(row),
                else => {},
            },
            wn.IDCMP_VANILLAKEY => switch (code) {
                0x1B => app.closeMenu(),
                '\r', '\n' => if (app.menu.hovered) |row| app.choose(row),
                else => {},
            },
            wn.IDCMP_INACTIVEWINDOW => app.closeMenu(),
            else => {},
        }
    }

    fn hover(app: *App, row: ?usize) void {
        if (row == app.menu.hovered) return;
        app.menu.hovered = row;
        app.drawMenu();
    }

    fn choose(app: *App, row: usize) void {
        const choice = app.menu.choices[row];
        const index = app.menu.index;
        app.closeMenu();
        app.tickAsNeeded();
        if (index) |i| if (i >= app.count) return;
        switch (choice) {
            .open => app.open(index.?),
            .information => if (app.entries[index.?].path) |path| {
                if (!app.ab.Information(null, path, app.screen)) app.ib.DisplayBeep(app.screen);
            },
            .remove => {
                app.remove(index.?);
                app.save();
                app.reshape();
            },
            .separator => {
                const at = if (index) |i| i + 1 else app.count;
                if (!app.insert(at, .separator)) return;
                app.save();
                app.reshape();
            },
            .quit => app.running = false,
        }
    }
};

fn sliceOf(text: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (text[n] != 0) n += 1;
    return text[0..n];
}

fn indexOf(text: []const u8, c: u8) ?usize {
    for (text, 0..) |t, i| if (t == c) return i;
    return null;
}

fn sameItem(a: dock_prefs.Item, b: dock_prefs.Item) bool {
    return switch (a) {
        .separator => b == .separator,
        .path => |path| switch (b) {
            .separator => false,
            .path => |other| path.len == other.len and for (path, other) |x, y| {
                if (x != y) break false;
            } else true,
        },
    };
}

/// A file a message carries by its full name, into `into`; null when it
/// does not fit.
fn fullName(dl: *DosBase, arg: dos.WBArg, into: []u8) ?[*:0]const u8 {
    if (!dl.NameFromLock(arg.lock, into.ptr, @intCast(into.len))) return null;
    if (arg.name) |name| if (name[0] != 0) {
        if (!dl.AddPart(@ptrCast(into.ptr), name, @intCast(into.len))) return null;
    };
    return @ptrCast(into.ptr);
}

fn windowAttr(ib: *IntuitionBase, window: *intuition.Window, tag: utility.Tag) usize {
    var value: usize = 0;
    ib.GetWindowAttrs(window, &[_]TagItem{ pair(tag, @intFromPtr(&value)), .{} });
    return value;
}

fn portMask(ib: *IntuitionBase, window: ?*intuition.Window) u32 {
    const shown = window orelse return 0;
    const port: ?*exec.MsgPort = @ptrFromInt(windowAttr(ib, shown, wn.WA_UserPort));
    return if (port) |p| p.sigMask() else 0;
}

/// An IntuiMessage's fields, read before it goes back.
const Input = struct { class: u32, code: u32, x: i32, y: i32 };

fn take(ib: *IntuitionBase, window: *intuition.Window) ?Input {
    const message = ib.GetIMsg(window) orelse return null;
    const input = Input{ .class = message.class, .code = message.code, .x = message.mouse_x, .y = message.mouse_y };
    ib.ReplyIMsg(message);
    return input;
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
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    // A dock running already is told, and this one ends; else this one's
    // port is the public one.
    const public = sys.CreateMsgPort() orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    var command = Command{ .message = .{ .reply_port = public, .length = @sizeOf(Command) }, .quit = @intFromBool(argv[arg_quit] != 0) };
    if (sys.SafePutToPort(&command.message, PORT_NAME)) {
        _ = sys.WaitPort(public);
        _ = sys.GetMsg(public);
        sys.DeleteMsgPort(public);
        return dos.RETURN_OK;
    }
    if (argv[arg_quit] != 0) {
        sys.DeleteMsgPort(public);
        _ = Printf(dl, MSG_NOTRUNNING, .{COMMAND_NAME});
        return dos.RETURN_WARN;
    }
    public.node.name = PORT_NAME;
    sys.AddPort(public);
    // Taken off first, so that nothing more comes; what came is answered.
    defer {
        sys.RemPort(public);
        while (sys.GetMsg(public)) |message| sys.ReplyMsg(message);
        sys.DeleteMsgPort(public);
    }

    const names = [_][*:0]const u8{ intuition.INTUITIONNAME, graphics.GRAPHICSNAME, utility.UTILITYNAME, icon.ICONNAME, anvil.ANVILNAME, motion.MOTIONNAME };
    const versions = [_]u32{ 0, 0, 0, 1, 1, 0 };
    var libraries: [names.len]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    for (names, versions, 0..) |name, version, i| {
        libraries[i] = sys.OpenLibrary(name, version) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, name });
            return dos.RETURN_FAIL;
        };
    }
    // The desktop's font when there is diskfont.library, else the screen's.
    const diskfont_lib = sys.OpenLibrary(sdk.diskfont.DISKFONTNAME, 0);
    defer sys.CloseLibrary(diskfont_lib);
    const ib: *IntuitionBase = @ptrCast(libraries[0].?);

    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);

    const app_port = sys.CreateMsgPort() orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer {
        while (sys.GetMsg(app_port)) |message| sys.ReplyMsg(message);
        sys.DeleteMsgPort(app_port);
    }
    const notify_port = sys.CreateMsgPort() orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer {
        while (sys.GetMsg(notify_port)) |message| sys.ReplyMsg(message);
        sys.DeleteMsgPort(notify_port);
    }

    // The dock's state is larger than a small board's stack likes.
    const memory = sys.AllocVec(@sizeOf(App), exec.MEMF_CLEAR) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const app: *App = @ptrCast(@alignCast(memory));
    app.* = .{
        .sys = sys,
        .dl = dl,
        .ub = @ptrCast(libraries[2].?),
        .ib = ib,
        .gb = @ptrCast(libraries[1].?),
        .icons = @ptrCast(libraries[3].?),
        .ab = @ptrCast(libraries[4].?),
        .mb = @ptrCast(libraries[5].?),
        .df = @ptrCast(diskfont_lib),
        .screen = screen,
        .app_port = app_port,
    };
    var width: usize = 0;
    var height: usize = 0;
    var bar: usize = 0;
    ib.GetScreenAttrs(screen, &[_]TagItem{
        pair(sc.SA_Width, @intFromPtr(&width)),
        pair(sc.SA_Height, @intFromPtr(&height)),
        pair(sc.SA_BarHeight, @intFromPtr(&bar)),
        .{},
    });
    app.screen_width = @intCast(width);
    app.screen_height = @intCast(height);
    app.bar_height = @intCast(bar);

    app.readSettings();
    app.makeLook();
    defer if (app.own_font) |font| app.gb.CloseFont(font);
    app.readItems();
    defer app.removeAll();

    const box = app.layout();
    const window = ib.OpenWindowTagList(&[_]TagItem{
        pair(wn.WA_Left, @bitCast(@as(isize, box.min_x))),
        pair(wn.WA_Top, @bitCast(@as(isize, box.min_y))),
        pair(wn.WA_Width, @intCast(box.max_x - box.min_x)),
        pair(wn.WA_Height, @intCast(box.max_y - box.min_y)),
        // Any size its entries and its edge make it, not only larger
        // than it opened.
        pair(wn.WA_MinWidth, 1),
        pair(wn.WA_MinHeight, 1),
        pair(wn.WA_MaxWidth, @bitCast(@as(isize, -1))),
        pair(wn.WA_MaxHeight, @bitCast(@as(isize, -1))),
        pair(wn.WA_PubScreen, @intFromPtr(screen)),
        pair(wn.WA_Borderless, 1),
        pair(wn.WA_StayInFront, 1),
        pair(wn.WA_RMBTrap, 1),
        pair(wn.WA_ReportMouse, 1),
        pair(wn.WA_IDCMP, wn.IDCMP_MOUSEBUTTONS | wn.IDCMP_MOUSEMOVE | wn.IDCMP_REFRESHWINDOW),
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOWINDOW, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer ib.CloseWindow(window);
    app.window = window;
    app.rp = @ptrFromInt(windowAttr(ib, window, wn.WA_RastPort));
    app.setFont(app.rp);
    app.readBox();
    app.draw();
    defer app.closeTip();
    defer app.closeMenu();

    const bit = sys.AllocSignal(-1);
    if (bit < 0) return dos.RETURN_FAIL;
    defer sys.FreeSignal(bit);
    app.tick = app.mb.CreateTimerTagList(&[_]TagItem{
        pair(motion.TIMER_Period, look_every),
        pair(motion.TIMER_Repeat, motion.TIMER_FOREVER),
        pair(motion.TIMER_Signal, @intCast(bit)),
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer app.mb.DeleteTimer(app.tick);
    const tick_mask = @as(u32, 1) << @intCast(bit);

    app.joinDesktop();
    defer {
        _ = app.ab.RemoveAppWindow(app.app_window);
        _ = app.ab.RemoveAppMenuItem(app.app_item);
    }
    app.tickAsNeeded();

    // dock.prefs and dock.items followed; font.prefs as well, for the
    // names' font.
    const watched_names = [_][*:0]const u8{ dock_prefs.ENV_FILE, dock_prefs.ITEMS_ENV_FILE, font_prefs.ENV_FILE };
    const watched_kinds = [_]usize{ WATCH_PREFS, WATCH_ITEMS, WATCH_PREFS };
    var requests: [watched_names.len]notify.NotifyRequest = undefined;
    var watching: [watched_names.len]bool = @splat(false);
    for (&requests, &watching, watched_names, watched_kinds) |*request, *on, name, kind| {
        request.* = .{ .name = name, .flags = notify.NRF_SEND_MESSAGE, .port = notify_port, .user_data = kind };
        on.* = dl.StartNotify(request);
    }
    defer for (&requests, watching) |*request, on| if (on) dl.EndNotify(request);

    while (app.running) {
        const got = sys.Wait(portMask(ib, window) | portMask(ib, app.menu.window) | public.sigMask() | app_port.sigMask() | notify_port.sigMask() | tick_mask | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) break;
        if (got & tick_mask != 0) app.ticked();
        while (take(ib, window)) |input| app.dockInput(input.class, input.code, input.x, input.y);
        while (app.menu.window) |shown| {
            const input = take(ib, shown) orelse break;
            app.menuInput(input.class, input.code, input.x, input.y);
        }
        while (sys.GetMsg(public)) |message| {
            const told: *Command = @fieldParentPtr("message", message);
            if (told.quit != 0) app.running = false else ib.WindowToFront(window);
            sys.ReplyMsg(message);
        }
        while (sys.GetMsg(app_port)) |message| {
            const am: *anvil.AppMessage = @fieldParentPtr("message", message);
            app.appMessage(am);
            sys.ReplyMsg(message);
        }
        var prefs_changed = false;
        var items_changed = false;
        while (sys.GetMsg(notify_port)) |message| {
            const told: *notify.NotifyMessage = @fieldParentPtr("message", message);
            if (told.request) |request| switch (request.user_data) {
                WATCH_PREFS => prefs_changed = true,
                WATCH_ITEMS => items_changed = true,
                else => {},
            };
            sys.ReplyMsg(message);
        }
        if (prefs_changed) app.renew();
        if (items_changed) app.itemsChanged();
    }
    if (app.press.dragging) _ = ib.EndDrag(window, 0);
    return dos.RETURN_OK;
}
