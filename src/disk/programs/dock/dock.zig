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
//! - Files let go on an entry are opened with it; let go in the room
//!   between two pictures, on a separator or at an end of the dock, they
//!   are put in as entries there.
//! - An entry dragged along the dock moves there; dragged off it, it is
//!   taken off.
//! - A press held still, or the right button while the dock is the active
//!   window, opens the entry's menu: Open, Information, Remove from Dock,
//!   Insert Separator, Dock Settings (Prefs on its Dock page), Quit Dock -
//!   the name first, so that a finger sees it too.
//! - Add to Dock in the desktop's Tools menu puts the icons picked there
//!   at the end.
//! - A click on a drawer or a disk lists what is in it, by the entry - a
//!   stack - each opened with a click there, and the last row opens its
//!   window.
//!
//! **What it shows on its own:**
//! - A dot under an entry whose program, started from the dock, still
//!   runs (anvil.library's `ANVO_EndMsg`).
//! - Files dragged over it from anywhere (intuition's `SA_Dragging`): the
//!   entry that would open them lit, or a bar where they would be put in.
//! - HIDE=AUTO: the dock goes past its edge when the pointer has left it
//!   for half a second, all but a strip, and comes back when the pointer
//!   touches the strip or the edge there, or a finger taps it.
//! - MAGNIFY: the pictures near the pointer grow, the one under it to that
//!   many pixels, and the dock with them.
//!
//! On a composed screen - the 64-bit machines' - the dock slides as it
//! goes and comes (motion.library); on the ESP32 boards it goes at once,
//! and does not magnify.
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
const VERSION_STRING = "\x00$VER: Dock 1.2 (27.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "QUIT/S";
const arg_quit = 0;

/// The public port the running dock is known by.
const PORT_NAME = "Dock";

const MSG_NOLIBRARY = "%s: can't open %s\n";
const MSG_NOSCREEN = "%s: no screen to show on\n";
const MSG_NOWINDOW = "%s: no window\n";
const MSG_NOTRUNNING = "%s: no dock is running\n";

/// Whether the screen's windows are composed, each in a buffer of its
/// own - the 64-bit machines': only there do the pictures grow under the
/// pointer, and does a dock that hides slide.
const composed = @sizeOf(usize) == 8;

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
/// How many looks the pointer is off a dock that hides before it goes,
/// how thick the strip is that it leaves along its edge - to point at,
/// or tap - and how long it slides, in milliseconds.
const hide_after = 5;
const strip = 4;
const slide_time = 180;
/// How often the pictures follow the pointer while they grow, in
/// milliseconds, and how far from it they still grow: two and a half
/// cells, in tenths of one.
const grow_every = 30;
const grow_reach = 25;
/// The most programs started from the dock that are followed at once.
const runs_max = 32;
/// The most of a drawer's contents its stack lists, and the size of each
/// one's picture there.
const stack_max = 20;
const stack_picture = 20;

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
    /// The icon's picture at the dock's size, held from icon.library;
    /// and at the size the one under the pointer grows to, while the dock
    /// magnifies - icon.library's too when the icon is that large, else
    /// made larger by the dock (`big_own`), which frees it.
    picture: ?*const icon.IconImage = null,
    big: ?*const icon.IconImage = null,
    big_own: bool = false,
    label: [label_max + 1]u8 = @splat(0),
    label_len: u32 = 0,
    /// Whether a click lists what is in it - a drawer's, a disk's - rather
    /// than opening its window.
    stacks: bool = false,
    /// Its cell along the dock, where it starts and how long it is - now,
    /// and at rest - and its picture's size now.
    start: i32 = 0,
    span: i32 = 0,
    rest_start: i32 = 0,
    rest_span: i32 = 0,
    size: i32 = 0,

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

/// A program started from an entry, followed until it ends: the message
/// OpenObject replies then (`ANVO_EndMsg`), and the entry's full name it
/// is matched to - the entries may have moved, or gone, by then. The name
/// follows it in the same memory.
const Run = struct {
    message: exec.Message = .{},
    path: [*:0]const u8 = "",
};

/// One row of a stack: a name in the drawer, whether it is a drawer
/// itself, and its icon and picture.
const StackRow = struct {
    name: [dos.name_max + 1]u8 = @splat(0),
    name_len: u32 = 0,
    drawer: bool = false,
    object: ?*icon.DiskObject = null,
    picture: ?*const icon.IconImage = null,
};

/// A drawer's or a disk's contents listed by its entry - drawers first,
/// then the rest, each by name - in a small window like the menu's, its
/// last row opening its window.
const Stack = struct {
    window: ?*intuition.Window = null,
    rp: *graphics.RastPort = undefined,
    /// The entry it is for.
    index: usize = 0,
    rows: [stack_max]StackRow = @splat(.{}),
    count: usize = 0,
    width: i32 = 0,
    title_height: i32 = 0,
    row_height: i32 = 0,
    hovered: ?usize = null,
    armed: bool = false,
};

/// What the entry menu offers.
const Choice = enum { open, information, remove, separator, settings, quit };
const choice_names = [_][*:0]const u8{ "Open", "Information", "Remove from Dock", "Insert Separator", "Dock Settings...", "Quit Dock" };

/// What Dock Settings runs: Prefs, on the dock's page.
const SETTINGS_COMMAND = "SYS:Programs/Prefs PAGE=DOCK";

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
    /// The dock's content: how long it is along its edge and how far
    /// across - more of both while it magnifies - and where along the
    /// screen it starts, now and at rest.
    length: i32 = 0,
    across: i32 = 0,
    lead: i32 = 0,
    rest_lead: i32 = 0,
    /// Whether the pictures grow about the pointer, and where it is along
    /// the screen.
    magnified: bool = false,
    pointed: i32 = 0,
    /// How much of the dock is past its edge - 0 shown, all but the strip
    /// hidden - whether it is hidden or on its way there, and the looks
    /// the pointer has been off it.
    shift: i32 = 0,
    hiding: bool = false,
    away: u32 = 0,
    /// Whether the slide's steps count: not once the settings changed
    /// under it, when a step late on its way is passed over.
    sliding: bool = false,
    /// Where files dragged over the dock would go: the entry that would
    /// open them, or the place they would be put in.
    drop_target: ?usize = null,
    drop_gap: ?usize = null,
    press: Press = .{},
    menu: Menu = .{},
    stack: Stack = .{},
    /// The name by the entry under the pointer, which entry, and its box.
    tip: ?*intuition.Window = null,
    tip_index: ?usize = null,
    tip_x: i32 = 0,
    tip_y: i32 = 0,
    tip_width: i32 = 0,
    tip_height: i32 = 0,

    app_port: *exec.MsgPort,
    app_window: ?*anvil.AppWindow = null,
    app_item: ?*anvil.AppMenuItem = null,
    /// Looks since the desktop was last tried.
    desktop_looks: u32 = 0,
    /// What was started from the entries and runs yet, and where its
    /// ending is told.
    run_port: *exec.MsgPort,
    runs: [runs_max]?*Run = @splat(null),
    run_count: usize = 0,
    /// The pointer looked at; the pictures' quicker clock while they
    /// grow, and the slide - those two on a composed screen alone.
    tick: *motion.Timer = undefined,
    quick: ?*motion.Timer = null,
    slide: ?*motion.Animation = null,
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
        if (e.object) |object| e.stacks = object.kind == icon.WBDRAWER or object.kind == icon.WBDISK or object.kind == icon.WBGARBAGE;
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

    /// The entry's picture at the look's size, and at the size it grows
    /// to when the dock magnifies; those it had given back.
    fn takePicture(app: *App, e: *Entry) void {
        if (e.picture) |held| app.icons.ReleaseIconImage(held);
        app.dropBig(e);
        e.picture = null;
        const object = e.object orelse return;
        const image = object.image orelse return;
        e.picture = app.icons.ObtainIconImage(image, @intCast(app.look.size));
        if (!app.magnifies()) return;
        const big: u32 = @intCast(app.bigSize());
        const held = app.icons.ObtainIconImage(image, big) orelse return;
        if (@max(held.width, held.height) >= big) {
            e.big = held;
            return;
        }
        // The icon is smaller than it is to grow to: made larger here.
        app.icons.ReleaseIconImage(held);
        e.big = app.enlarged(image, big);
        e.big_own = e.big != null;
    }

    fn dropBig(app: *App, e: *Entry) void {
        if (e.big) |held| {
            if (e.big_own) app.sys.FreeVec(@constCast(held)) else app.icons.ReleaseIconImage(held);
        }
        e.big = null;
        e.big_own = false;
    }

    /// `image` made larger, its shape kept, to `most` pixels the longer
    /// way: each pixel mixed from the four of `image` round its place,
    /// weighted by their coverage so that a clear one lends no colour.
    /// The picture follows its header in one piece of memory; null
    /// without it.
    fn enlarged(app: *App, image: *const icon.IconImage, most: u32) ?*const icon.IconImage {
        const sw: u32 = @max(1, image.width);
        const sh: u32 = @max(1, image.height);
        const width: u32 = if (sw >= sh) most else @max(1, sw * most / sh);
        const height: u32 = if (sw >= sh) @max(1, sh * most / sw) else most;
        const memory = app.sys.AllocVec(@sizeOf(icon.IconImage) + width * height * 4, exec.MEMF_ANY) orelse return null;
        const made: *icon.IconImage = @ptrCast(@alignCast(memory));
        const pixels: [*]u8 = @as([*]u8, @ptrCast(memory)) + @sizeOf(icon.IconImage);
        made.* = .{ .width = width, .height = height, .pixels = pixels };
        const from = image.pixels;
        for (0..height) |dy| {
            // The middle of the pixel, in the picture's pixels, 16.16.
            const fy: i64 = @max(0, @divTrunc(@as(i64, @intCast(2 * dy + 1)) * sh * 0x10000, 2 * @as(i64, height)) - 0x8000);
            const y0: u32 = @intCast(fy >> 16);
            const y1 = @min(y0 + 1, sh - 1);
            const wy: i64 = fy & 0xFFFF;
            for (0..width) |dx| {
                const fx: i64 = @max(0, @divTrunc(@as(i64, @intCast(2 * dx + 1)) * sw * 0x10000, 2 * @as(i64, width)) - 0x8000);
                const x0: u32 = @intCast(fx >> 16);
                const x1 = @min(x0 + 1, sw - 1);
                const wx: i64 = fx & 0xFFFF;
                const corners = [4]struct { x: u32, y: u32, w: i64 }{
                    .{ .x = x0, .y = y0, .w = (0x10000 - wx) * (0x10000 - wy) >> 16 },
                    .{ .x = x1, .y = y0, .w = wx * (0x10000 - wy) >> 16 },
                    .{ .x = x0, .y = y1, .w = (0x10000 - wx) * wy >> 16 },
                    .{ .x = x1, .y = y1, .w = wx * wy >> 16 },
                };
                var cover: i64 = 0;
                var colour: [3]i64 = @splat(0);
                for (corners) |c| {
                    const at = (c.y * sw + c.x) * 4;
                    const a: i64 = from[at + 3];
                    cover += a * c.w;
                    for (&colour, 0..) |*sum, k| sum.* += @as(i64, from[at + k]) * a * c.w;
                }
                const out = pixels + (dy * width + dx) * 4;
                out[3] = @intCast(@min(255, cover >> 16));
                for (0..3) |k| out[k] = if (cover > 0) @intCast(@min(255, @divTrunc(colour[k], cover))) else 0;
            }
        }
        return made;
    }

    fn freeEntry(app: *App, e: *Entry) void {
        if (e.picture) |held| app.icons.ReleaseIconImage(held);
        app.dropBig(e);
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
        app.closeStack();
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
        return app.look.size + 2 * pad + app.labelLine();
    }

    /// The line under a picture its name takes when names are always
    /// shown.
    fn labelLine(app: *const App) i32 {
        return if (app.settings.labels == .always) app.look.font_height + 2 else 0;
    }

    fn upright(app: *const App) bool {
        return app.settings.upright();
    }

    /// A cell at rest: how long along the dock, and how far across.
    fn restSpan(app: *const App) i32 {
        return if (app.upright()) app.cellHeight() else app.cellWidth();
    }

    fn restAcross(app: *const App) i32 {
        return if (app.upright()) app.cellWidth() else app.cellHeight();
    }

    /// How far a picture is in from the near side of a cell across an
    /// upright dock: centred at rest, and growing away from the edge.
    fn inset(app: *const App) i32 {
        return @divTrunc(app.restAcross() - app.look.size, 2);
    }

    /// The pixels the entry under the pointer grows to: MAGNIFY's, no
    /// more than a quarter of the screen; 0 for none.
    fn bigSize(app: *const App) i32 {
        if (!composed or app.settings.magnify == 0) return 0;
        const most = @divTrunc(@min(app.screen_width, app.screen_height), 4);
        return @min(@as(i32, @intCast(app.settings.magnify)), most);
    }

    /// Whether the pictures grow under the pointer.
    fn magnifies(app: *const App) bool {
        return app.bigSize() > app.look.size and app.look.size > 0;
    }

    /// The room along the dock's edge: the screen's width, or its height
    /// under the title bar.
    fn roomAlong(app: *const App) struct { start: i32, size: i32 } {
        if (app.upright()) return .{ .start = app.bar_height, .size = app.screen_height - app.bar_height };
        return .{ .start = 0, .size = app.screen_width };
    }

    /// Each entry's cell along the dock at rest, the content's length and
    /// breadth, and where it starts: centred along its edge, no longer
    /// than the screen. Grown about the pointer while it magnifies.
    fn layout(app: *App) void {
        const span = app.restSpan();
        var along: i32 = end_pad;
        for (app.entries[0..app.count]) |*e| {
            e.rest_start = along;
            e.rest_span = if (e.path == null) separator_span else span;
            e.start = e.rest_start;
            e.span = e.rest_span;
            e.size = app.look.size;
            along += e.rest_span;
        }
        // An empty dock keeps a cell's room, to let files go on.
        if (app.count == 0) along += span;
        along += end_pad;
        const room = app.roomAlong();
        app.length = @min(along, room.size);
        app.across = app.restAcross();
        app.rest_lead = room.start + @divTrunc(room.size - app.length, 2);
        app.lead = app.rest_lead;
        if (app.magnified) app.grow();
    }

    /// The pictures grown about the pointer (`pointed`): each by how near
    /// its middle at rest is to it, the nearest to `bigSize`, those two
    /// and a half cells away not at all; its cell with it. The entry the
    /// pointer is on at rest stays under it, the rest moved aside, and
    /// the dock is as long and as broad as they make it.
    fn grow(app: *App) void {
        if (!app.magnifies() or app.count == 0) return;
        const big = app.bigSize();
        const extra = big - app.look.size;
        const reach = @max(1, @divTrunc(app.restSpan() * grow_reach, 10));
        const at = app.pointed - app.rest_lead;
        for (app.entries[0..app.count]) |*e| {
            if (e.path == null) continue;
            var off = at - (e.rest_start + @divTrunc(e.rest_span, 2));
            if (off < 0) off = -off;
            // (1 - t*t)^2, in 256ths: round by the pointer, falling away
            // and flattening out to nothing.
            const t = @divTrunc(@min(off, reach) * 256, reach);
            const near = 256 - @divTrunc(t * t, 256);
            const weight = @divTrunc(near * near, 256);
            const delta = @divTrunc(extra * weight, 256);
            e.size = app.look.size + delta;
            e.span = e.rest_span + delta;
            if (!app.upright() and app.settings.labels == .always) e.span += @divTrunc(delta, 2);
        }
        var k: usize = app.count - 1;
        for (app.entries[0..app.count], 0..) |*e, i| {
            if (at < e.rest_start + e.rest_span) {
                k = i;
                break;
            }
        }
        const anchor = &app.entries[k];
        const into = @max(0, @min(at - anchor.rest_start, anchor.rest_span));
        anchor.start = at - @divTrunc(into * anchor.span, anchor.rest_span);
        var i = k;
        while (i > 0) : (i -= 1) app.entries[i - 1].start = app.entries[i].start - app.entries[i - 1].span;
        for (k + 1..app.count) |j| app.entries[j].start = app.entries[j - 1].start + app.entries[j - 1].span;
        // Counted from the dock's new start, which is kept on the screen.
        const first = app.entries[0].start - end_pad;
        const last = app.entries[app.count - 1].start + app.entries[app.count - 1].span + end_pad;
        for (app.entries[0..app.count]) |*e| e.start -= first;
        const room = app.roomAlong();
        app.length = @min(last - first, room.size);
        app.lead = @max(room.start, @min(app.rest_lead + first, room.start + room.size - app.length));
        app.across = if (app.upright()) big + 2 * app.inset() else big + 2 * pad + app.labelLine();
    }

    /// The window's box: the content along its edge, less what is past
    /// the edge while it hides.
    fn boxFor(app: *const App) Rect {
        const shown = app.across - app.shift;
        const far = app.lead + app.length;
        return switch (app.settings.edge) {
            .bottom => .{ .min_x = app.lead, .min_y = app.screen_height - shown, .max_x = far, .max_y = app.screen_height },
            .top => .{ .min_x = app.lead, .min_y = app.bar_height, .max_x = far, .max_y = app.bar_height + shown },
            .left => .{ .min_x = 0, .min_y = app.lead, .max_x = shown, .max_y = far },
            .right => .{ .min_x = app.screen_width - shown, .min_y = app.lead, .max_x = app.screen_width, .max_y = far },
        };
    }

    /// Where the content starts across, in the window: past its near side
    /// for a dock along the top or the left that is going, whose far side
    /// is what stays in sight.
    fn origin(app: *const App) i32 {
        return switch (app.settings.edge) {
            .top, .left => -app.shift,
            .bottom, .right => 0,
        };
    }

    /// The entries changed, or the pointer they grow about moved: laid
    /// out again, and the window given its box and drawn.
    fn reshape(app: *App) void {
        app.layout();
        app.fitWindow();
    }

    /// The window given the box the dock has now, and drawn; the name by
    /// the pointer kept by its entry.
    fn fitWindow(app: *App) void {
        const window = app.window orelse return;
        const box = app.boxFor();
        if (box.min_x != app.box.min_x or box.min_y != app.box.min_y or box.max_x != app.box.max_x or box.max_y != app.box.max_y) {
            app.ib.ChangeWindowBox(window, box.min_x, box.min_y, box.max_x - box.min_x, box.max_y - box.min_y);
            app.readBox();
        }
        app.draw();
        app.placeTip();
    }

    /// dock.prefs or font.prefs changed: the look made again, every
    /// picture taken at its size, and the dock shaped anew - shown, should
    /// it have been hidden.
    fn renew(app: *App) void {
        app.closeMenu();
        app.closeStack();
        app.closeTip();
        app.stopGrowing();
        if (app.slide) |slide| app.mb.StopAnimation(slide, motion.STOP_WHERE_IT_IS);
        app.sliding = false;
        app.shift = 0;
        app.hiding = false;
        app.away = 0;
        app.readSettings();
        app.makeLook();
        if (app.window != null) app.setFont(app.rp);
        for (app.entries[0..app.count]) |*e| app.takePicture(e);
        app.reshape();
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
        const o = app.origin();
        if (app.upright()) return .{ .min_x = o, .min_y = e.start, .max_x = o + app.across, .max_y = e.start + e.span };
        return .{ .min_x = e.start, .min_y = o, .max_x = e.start + e.span, .max_y = o + app.across };
    }

    /// The square an entry's picture is drawn in, at its size now: centred
    /// along its cell, and across it grown away from the screen's edge -
    /// with the name's line under it, when names are always shown.
    fn pictureBox(app: *const App, e: *const Entry) Rect {
        const cell = app.cellOf(e);
        const size = e.size;
        var x: i32 = undefined;
        var y: i32 = undefined;
        if (app.upright()) {
            x = if (app.settings.edge == .left) cell.min_x + app.inset() else cell.max_x - app.inset() - size;
            y = cell.min_y + pad;
        } else {
            x = cell.min_x + @divTrunc(e.span - size, 2);
            y = if (app.settings.edge == .bottom) cell.max_y - pad - app.labelLine() - size else cell.min_y + pad;
        }
        return .{ .min_x = x, .min_y = y, .max_x = x + size, .max_y = y + size };
    }

    /// Where an entry's picture is drawn: centred across its square, its
    /// foot on the square's bottom, the line every picture stands on.
    fn pictureOf(app: *const App, e: *const Entry) ?Rect {
        const picture = e.picture orelse return null;
        const box = app.pictureBox(e);
        var w: i32 = @intCast(picture.width);
        var h: i32 = @intCast(picture.height);
        if (e.size != app.look.size) if (e.big) |big| {
            const made: i32 = @intCast(@max(big.width, big.height));
            w = @divTrunc(@as(i32, @intCast(big.width)) * e.size, made);
            h = @divTrunc(@as(i32, @intCast(big.height)) * e.size, made);
        };
        const x = box.min_x + @divTrunc(e.size - w, 2);
        const y = box.min_y + e.size - h;
        return .{ .min_x = x, .min_y = y, .max_x = x + w, .max_y = y + h };
    }

    fn draw(app: *App) void {
        if (app.window == null) return;
        const o = app.origin();
        const whole = if (app.upright())
            Rect{ .min_x = o, .min_y = 0, .max_x = o + app.across, .max_y = app.length }
        else
            Rect{ .min_x = 0, .min_y = o, .max_x = app.length, .max_y = o + app.across };
        app.gb.BeginDraw(app.rp);
        app.fill(app.rp, app.look.ground, whole);
        app.bevel(app.rp, whole);
        for (0..app.count) |i| app.drawEntry(i);
        // Where files dragged over it would be put in: a bar across.
        if (app.drop_gap) |gap| {
            const at = if (gap < app.count)
                app.entries[gap].start
            else if (app.count > 0)
                app.entries[app.count - 1].start + app.entries[app.count - 1].span
            else
                end_pad;
            const bar = if (app.upright())
                Rect{ .min_x = o + pad, .min_y = at - 1, .max_x = o + app.across - pad, .max_y = at + 2 }
            else
                Rect{ .min_x = at - 1, .min_y = o + pad, .max_x = at + 2, .max_y = o + app.across - pad };
            app.fill(app.rp, app.look.fill, bar);
        }
        app.gb.EndDraw(app.rp);
    }

    /// One entry drawn on the ground: a separator's line, or the picture -
    /// on the fill pen's plate while it is held, or files dragged over it
    /// would open with it - with a dot by it while what it started runs,
    /// and the name when the names are always shown.
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
        // Files that would open with it light the whole cell: the picture
        // dragged over it covers its own.
        if (app.drop_target == index) {
            const plate = Rect{ .min_x = cell.min_x + 2, .min_y = cell.min_y + 2, .max_x = cell.max_x - 2, .max_y = cell.max_y - 2 };
            app.pen(rp, (app.look.fill & 0x00FF_FFFF) | 0x8000_0000);
            app.gb.FillRoundRect(rp, &plate, 6);
        }
        if (app.pictureOf(e)) |area| {
            if (held) {
                const plate = Rect{ .min_x = area.min_x - 3, .min_y = area.min_y - 3, .max_x = area.max_x + 3, .max_y = area.max_y + 3 };
                app.pen(rp, (app.look.fill & 0x00FF_FFFF) | 0x8000_0000);
                app.gb.FillRoundRect(rp, &plate, 6);
            }
            app.drawPicture(e, area);
        }
        if (app.isRunning(e)) app.drawDot(e, cell);
        if (app.settings.labels != .always) return;
        const box = app.pictureBox(e);
        const room = cell.max_x - cell.min_x - 4;
        var extent: graphics.TextExtent = undefined;
        const fits = app.gb.TextFit(rp, &e.label, e.label_len, &extent, null, 1, room, app.look.font_height + 8);
        const width = app.gb.TextLength(rp, &e.label, fits);
        const x = cell.min_x + @divTrunc(cell.max_x - cell.min_x - width, 2);
        const y = box.max_y + 2;
        app.pen(rp, app.look.text);
        app.gb.Move(rp, x, y + app.look.baseline);
        app.gb.Text(rp, &e.label, fits);
    }

    /// The picture at its size now: as it was taken at rest, or the large
    /// one made smaller while it grows.
    fn drawPicture(app: *App, e: *const Entry, area: Rect) void {
        const format = @intFromEnum(rtg.PixelFormat.rgba32);
        if (e.size != app.look.size) if (e.big) |big| {
            if (area.max_x - area.min_x == big.width and area.max_y - area.min_y == big.height) {
                app.gb.BlendPixelArray(app.rp, big.pixels, big.width * 4, format, 0, 0, &area);
            } else {
                const whole = Rect{ .min_x = 0, .min_y = 0, .max_x = @intCast(big.width), .max_y = @intCast(big.height) };
                app.gb.ScalePixelArray(app.rp, big.pixels, big.width * 4, format, &whole, &area);
            }
            return;
        };
        const picture = e.picture.?;
        app.gb.BlendPixelArray(app.rp, picture.pixels, picture.width * 4, format, 0, 0, &area);
    }

    /// The dot of an entry whose program runs: between its picture and
    /// the screen's edge, inside `cell`.
    fn drawDot(app: *App, e: *const Entry, cell: Rect) void {
        const box = app.pictureBox(e);
        const middle_x = @divTrunc(box.min_x + box.max_x, 2);
        const middle_y = @divTrunc(box.min_y + box.max_y, 2);
        const d = 4;
        const dot: Rect = switch (app.settings.edge) {
            .bottom => .{ .min_x = middle_x - 2, .min_y = cell.max_y - d - 1, .max_x = middle_x + 2, .max_y = cell.max_y - 1 },
            .top => .{ .min_x = middle_x - 2, .min_y = cell.min_y + 1, .max_x = middle_x + 2, .max_y = cell.min_y + d + 1 },
            .left => .{ .min_x = cell.min_x + 1, .min_y = middle_y - 2, .max_x = cell.min_x + d + 1, .max_y = middle_y + 2 },
            .right => .{ .min_x = cell.max_x - d - 1, .min_y = middle_y - 2, .max_x = cell.max_x - 1, .max_y = middle_y + 2 },
        };
        app.pen(app.rp, app.look.text);
        app.gb.FillRoundRect(app.rp, &dot, 2);
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

    /// The entry files let go at (`x`, `y`) are opened with: the one they
    /// are on, but for the room round its picture at either end of its
    /// cell - that, the room between two pictures, is where they are put
    /// in. Not a separator.
    fn targetAt(app: *const App, x: i32, y: i32) ?usize {
        const index = app.entryAt(x, y) orelse return null;
        const e = &app.entries[index];
        if (e.path == null) return null;
        const along = if (app.upright()) y else x;
        if (along < e.start + pad or along >= e.start + e.span - pad) return null;
        return index;
    }

    /// Whether (`x`, `y`) on the screen is on the dock's window.
    fn inBox(app: *const App, x: i32, y: i32) bool {
        return x >= app.box.min_x and x < app.box.max_x and y >= app.box.min_y and y < app.box.max_y;
    }

    /// Whether (`x`, `y`) on the screen touches a hidden dock: on its
    /// strip, or past it at the screen's edge, along its length.
    fn touches(app: *const App, x: i32, y: i32) bool {
        const b = app.box;
        return switch (app.settings.edge) {
            .bottom => x >= b.min_x and x < b.max_x and y >= b.min_y,
            .top => x >= b.min_x and x < b.max_x and y < b.max_y,
            .left => y >= b.min_y and y < b.max_y and x < b.max_x,
            .right => y >= b.min_y and y < b.max_y and x >= b.min_x,
        };
    }

    fn pointer(app: *App) struct { x: i32, y: i32 } {
        var x: usize = 0;
        var y: usize = 0;
        app.ib.GetScreenAttrs(app.screen, &[_]TagItem{ pair(sc.SA_MouseX, @intFromPtr(&x)), pair(sc.SA_MouseY, @intFromPtr(&y)), .{} });
        return .{ .x = @intCast(@as(isize, @bitCast(x))), .y = @intCast(@as(isize, @bitCast(y))) };
    }

    // --- what the entries do --------------------------------------------------

    /// A click on an entry: a drawer or a disk lists what is in it, the
    /// rest open.
    fn activate(app: *App, index: usize) void {
        if (app.entries[index].stacks) return app.openStack(index);
        app.openEntry(index, &.{});
    }

    /// The entry opened, as a double click on its icon opens it - with
    /// `files` (`ANVO_File` tags) when there are any - and what it starts
    /// followed until it ends. A drawer's or a disk's window is not.
    fn openEntry(app: *App, index: usize, files: []const TagItem) void {
        const e = &app.entries[index];
        const path = e.path orelse return;
        var tags: [anvil.OPEN_FILES_MAX + 2]TagItem = undefined;
        @memcpy(tags[0..files.len], files);
        var n = files.len;
        const run = if (e.stacks) null else app.newRun(path);
        if (run) |started| {
            tags[n] = pair(anvil.ANVO_EndMsg, @intFromPtr(&started.message));
            n += 1;
        }
        tags[n] = .{};
        if (!app.ab.OpenObject(path, &tags)) {
            if (run) |started| app.sys.FreeVec(started);
            return app.ib.DisplayBeep(app.screen);
        }
        const started = run orelse return;
        for (&app.runs) |*slot| if (slot.* == null) {
            slot.* = started;
            break;
        };
        app.run_count += 1;
        app.redrawEntry(index);
    }

    /// The entry opened with the files a message carries.
    fn openWith(app: *App, index: usize, args: []const dos.WBArg) void {
        const count = @min(args.len, anvil.OPEN_FILES_MAX);
        const each = dos.path_max + 1;
        const memory = app.sys.AllocVec(count * each, exec.MEMF_ANY) orelse return;
        defer app.sys.FreeVec(memory);
        const names: [*]u8 = @ptrCast(memory);
        var tags: [anvil.OPEN_FILES_MAX]TagItem = undefined;
        var n: usize = 0;
        for (args[0..count]) |arg| {
            const name = fullName(app.dl, arg, names[n * each ..][0..each]) orelse continue;
            tags[n] = pair(anvil.ANVO_File, @intFromPtr(name));
            n += 1;
        }
        app.openEntry(index, tags[0..n]);
    }

    // --- what runs ------------------------------------------------------------

    /// A run for what `path` starts, its name copied after it; null when
    /// as many run as are followed, or there is no memory.
    fn newRun(app: *App, path: [*:0]const u8) ?*Run {
        if (app.run_count == runs_max) return null;
        const text = sliceOf(path);
        const memory = app.sys.AllocVec(@sizeOf(Run) + text.len + 1, exec.MEMF_CLEAR) orelse return null;
        const run: *Run = @ptrCast(@alignCast(memory));
        const name: [*]u8 = @as([*]u8, @ptrCast(memory)) + @sizeOf(Run);
        @memcpy(name[0..text.len], text);
        name[text.len] = 0;
        run.* = .{ .message = .{ .reply_port = app.run_port, .length = @sizeOf(Run) }, .path = @ptrCast(name) };
        return run;
    }

    /// What an entry started has ended: its run let go, and the dock
    /// drawn without its dot.
    fn runEnded(app: *App, message: *exec.Message) void {
        const run: *Run = @fieldParentPtr("message", message);
        for (&app.runs) |*slot| if (slot.* == run) {
            slot.* = null;
            app.run_count -= 1;
            break;
        };
        app.sys.FreeVec(run);
        app.draw();
    }

    /// Whether something started from an entry for the same name runs.
    fn isRunning(app: *const App, e: *const Entry) bool {
        if (app.run_count == 0) return false;
        const path = sliceOf(e.path orelse return false);
        for (app.runs) |slot| if (slot) |run| {
            if (sameText(sliceOf(run.path), path)) return true;
        };
        return false;
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
                // A hidden dock tapped comes back, and nothing is pressed.
                wn.SELECTDOWN => if (app.hiding) app.slideTo(false) else if (app.shift == 0) app.pressDown(x, y),
                wn.SELECTUP => app.pressUp(x, y),
                wn.MENUDOWN => {
                    if (app.press.held or app.hiding or app.shift != 0) return;
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
        app.closeStack();
        app.press = .{ .held = true, .index = app.entryAt(x, y), .x = x, .y = y };
        if (app.press.index) |index| app.redrawEntry(index);
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
        // Where it was taken hold of, on the picture as it was taken: the
        // one shown may be grown.
        const w: i32 = @intCast(picture.width);
        const h: i32 = @intCast(picture.height);
        const hot_x: u32 = @intCast(@max(0, @min(@divTrunc((app.press.x - area.min_x) * w, @max(1, area.max_x - area.min_x)), w - 1)));
        const hot_y: u32 = @intCast(@max(0, @min(@divTrunc((app.press.y - area.min_y) * h, @max(1, area.max_y - area.min_y)), h - 1)));
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
        if (!press.held) return;
        const index = press.index orelse return;
        if (press.dragging) return app.dropped(index, x, y);
        app.redrawEntry(index);
        if (press.spent) return;
        if (app.entryAt(x, y) == index) app.activate(index);
    }

    /// A press that opened the menu let go on the menu, not the dock.
    fn pressGone(app: *App) void {
        if (!app.press.held or app.press.dragging) return;
        app.press = .{};
    }

    /// A dragged entry let go: on the dock it moves there, anywhere else
    /// it is taken off.
    fn dropped(app: *App, index: usize, x: i32, y: i32) void {
        const over = app.ib.EndDrag(app.window.?, 0);
        app.drop_gap = null;
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

    /// Ten times a second: the desktop tried again while it is not
    /// joined, a held press timed and followed, files dragged over shown
    /// where they go, a dock that hides sent or brought back, the
    /// pictures set growing, and the name by the pointer shown.
    fn ticked(app: *App) void {
        if (app.app_window == null or app.app_item == null) {
            app.desktop_looks += 1;
            if (app.desktop_looks >= desktop_every) {
                app.desktop_looks = 0;
                app.joinDesktop();
            }
        }
        const at = app.pointer();
        const x = at.x - app.box.min_x;
        const y = at.y - app.box.min_y;
        const inside = app.inBox(at.x, at.y);
        if (app.press.held) {
            app.press.looks += 1;
            // A pointer that does not report its moves is looked at.
            app.pressMoved(x, y);
            if (app.press.looks >= long_press and !app.press.dragging and !app.press.spent) {
                app.press.spent = true;
                if (app.press.index) |index| app.redrawEntry(index);
                app.openMenu(app.press.index, at.x, at.y);
            }
        }
        app.dragOver(x, y, inside);
        app.hideOrShow(at.x, at.y, inside);
        if (!app.magnified and inside and app.calm() and app.magnifies()) {
            app.magnified = true;
            app.pointed = if (app.upright()) at.y else at.x;
            if (app.quick) |quick| app.mb.StartTimer(quick);
            app.reshape();
        }
        if (app.settings.labels == .pointer and !app.press.held and app.menu.window == null and app.stack.window == null and !app.hiding) {
            const index = app.entryAt(x, y);
            const named = if (index) |i| (if (app.entries[i].path != null) i else null) else null;
            if (named != app.tip_index) {
                app.closeTip();
                if (named) |i| app.openTip(i);
            }
        }
    }

    /// Whether nothing is going on with the dock: no press held, no menu
    /// or stack open, nothing dragged over it, all of it in sight.
    fn calm(app: *const App) bool {
        return !app.press.held and app.menu.window == null and app.stack.window == null and
            !app.hiding and app.shift == 0 and app.drop_target == null and app.drop_gap == null;
    }

    /// Files dragged over the dock - by the desktop, or an entry by the
    /// dock itself - shown where they would go: the entry lit that would
    /// open them, or a bar where they would be put in.
    fn dragOver(app: *App, x: i32, y: i32, inside: bool) void {
        var target: ?usize = null;
        var gap: ?usize = null;
        if (inside and !app.hiding and app.dragging()) {
            if (app.press.dragging) {
                const to = app.placeAt(x, y);
                const from = app.press.index.?;
                if (to != from and to != from + 1) gap = to;
            } else if (app.targetAt(x, y)) |index| {
                target = index;
            } else gap = app.placeAt(x, y);
        }
        if (target == app.drop_target and gap == app.drop_gap) return;
        app.drop_target = target;
        app.drop_gap = gap;
        app.draw();
    }

    /// Whether a picture is being dragged across the screen.
    fn dragging(app: *App) bool {
        var value: usize = 0;
        app.ib.GetScreenAttrs(app.screen, &[_]TagItem{ pair(sc.SA_Dragging, @intFromPtr(&value)), .{} });
        return value != 0;
    }

    /// HIDE=AUTO: the dock sent away when the pointer has been off it for
    /// `hide_after` looks with nothing going on, and brought back when it
    /// touches the strip - with files dragged to it too.
    fn hideOrShow(app: *App, x: i32, y: i32, inside: bool) void {
        if (!app.settings.hide) return;
        if (app.hiding) {
            if (app.touches(x, y)) app.slideTo(false);
            return;
        }
        // The title bar between a dock along the top and the screen's
        // edge counts as the dock: the pointer that brought it is there.
        if (inside or app.touches(x, y) or !app.calm()) {
            app.away = 0;
            return;
        }
        app.away += 1;
        if (app.away >= hide_after) app.slideTo(true);
    }

    /// The dock sent past its edge, all but the strip, or brought back:
    /// sliding on a composed screen, at once on any other.
    fn slideTo(app: *App, hide: bool) void {
        app.hiding = hide;
        app.away = 0;
        if (hide) {
            app.closeTip();
            app.closeMenu();
            app.closeStack();
            app.stopGrowing();
            app.layout();
        }
        const to: i32 = if (hide) app.across - strip else 0;
        const slide = app.slide orelse return app.setShift(to);
        app.sliding = true;
        if (app.mb.GetAnimationAttr(slide, motion.ANIM_Running) != 0) {
            _ = app.mb.SetAnimationAttrsTagList(slide, &[_]TagItem{ pair(motion.ANIM_To, @intCast(to)), .{} });
            return;
        }
        _ = app.mb.SetAnimationAttrsTagList(slide, &[_]TagItem{
            pair(motion.ANIM_From, @intCast(app.shift)),
            pair(motion.ANIM_To, @intCast(to)),
            .{},
        });
        app.mb.StartAnimation(slide);
    }

    /// A step of the slide: the dock as far past its edge as it says.
    fn slid(app: *App) void {
        const slide = app.slide orelse return;
        if (!app.sliding) return;
        if (app.mb.GetAnimationAttr(slide, motion.ANIM_Running) == 0) app.sliding = false;
        const raw: isize = @bitCast(app.mb.GetAnimationAttr(slide, motion.ANIM_Value));
        const value: i32 = @intCast(@max(0, @min(raw, app.across - strip)));
        if (value != app.shift) app.setShift(value);
    }

    fn setShift(app: *App, shift: i32) void {
        app.shift = shift;
        app.fitWindow();
    }

    /// The pictures grown again about the pointer, 33 times a second; back
    /// to rest once it has left the dock with nothing going on.
    fn grown(app: *App) void {
        if (!app.magnified) return;
        if (!app.calm()) return;
        const at = app.pointer();
        if (!app.inBox(at.x, at.y)) {
            app.stopGrowing();
            return app.reshape();
        }
        const along = if (app.upright()) at.y else at.x;
        if (along == app.pointed) return;
        app.pointed = along;
        app.reshape();
    }

    /// The pictures at rest from now on; laid out so by the next reshape.
    fn stopGrowing(app: *App) void {
        if (!app.magnified) return;
        app.magnified = false;
        if (app.quick) |quick| app.mb.StopTimer(quick);
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
                // Let go: where they were going is shown no more.
                const shown = app.drop_target != null or app.drop_gap != null;
                app.drop_target = null;
                app.drop_gap = null;
                if (shown) app.draw();
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
        app.tip_width = width;
        app.tip_height = height;
        const where = app.tipPlace(index);
        const x = where.x;
        const y = where.y;
        app.tip_x = x;
        app.tip_y = y;
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

    /// Where the name of the entry `index` goes: beside the dock, by the
    /// entry's middle, on the screen.
    fn tipPlace(app: *const App, index: usize) struct { x: i32, y: i32 } {
        const width = app.tip_width;
        const height = app.tip_height;
        const cell = app.cellOf(&app.entries[index]);
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
        return .{ .x = x, .y = y };
    }

    /// The name moved with its entry, as the dock grows or goes.
    fn placeTip(app: *App) void {
        const tip = app.tip orelse return;
        const index = app.tip_index orelse return;
        if (index >= app.count) return app.closeTip();
        const where = app.tipPlace(index);
        if (where.x == app.tip_x and where.y == app.tip_y) return;
        app.tip_x = where.x;
        app.tip_y = where.y;
        app.ib.ChangeWindowBox(tip, where.x, where.y, app.tip_width, app.tip_height);
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
        app.closeStack();
        var m = Menu{ .index = index };
        const e: ?*const Entry = if (index) |i| &app.entries[i] else null;
        const is_entry = if (e) |shown| shown.path != null else false;
        const choices: []const Choice = if (is_entry)
            &.{ .open, .information, .remove, .separator, .settings, .quit }
        else if (e != null)
            &.{ .remove, .settings, .quit }
        else
            &.{ .separator, .settings, .quit };
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
        const window = app.openBeside(m.width, height, x, y) orelse return;
        m.window = window;
        m.rp = @ptrFromInt(windowAttr(app.ib, window, wn.WA_RastPort));
        app.menu = m;
        app.setFont(m.rp);
        app.drawMenu();
    }

    /// A small window by the dock - a menu, a stack - `width` by `height`,
    /// beside it where (`x`, `y`) on the screen is, so that a button let
    /// go where it went down chooses nothing; kept on the screen.
    fn openBeside(app: *App, width: i32, height: i32, x: i32, y: i32) ?*intuition.Window {
        var left: i32 = undefined;
        var top: i32 = undefined;
        switch (app.settings.edge) {
            .bottom => {
                left = x - @divTrunc(width, 2);
                top = app.box.min_y - height - 2;
            },
            .top => {
                left = x - @divTrunc(width, 2);
                top = app.box.max_y + 2;
            },
            .left => {
                left = app.box.max_x + 2;
                top = y - @divTrunc(height, 2);
            },
            .right => {
                left = app.box.min_x - width - 2;
                top = y - @divTrunc(height, 2);
            },
        }
        left = @max(0, @min(left, app.screen_width - width));
        top = @max(app.bar_height, @min(top, app.screen_height - height));
        return app.ib.OpenWindowTagList(&[_]TagItem{
            pair(wn.WA_Left, @bitCast(@as(isize, left))),
            pair(wn.WA_Top, @bitCast(@as(isize, top))),
            pair(wn.WA_Width, @intCast(width)),
            pair(wn.WA_Height, @intCast(height)),
            pair(wn.WA_PubScreen, @intFromPtr(app.screen)),
            pair(wn.WA_Borderless, 1),
            pair(wn.WA_StayInFront, 1),
            pair(wn.WA_Activate, 1),
            pair(wn.WA_RMBTrap, 1),
            pair(wn.WA_ReportMouse, 1),
            pair(wn.WA_IDCMP, wn.IDCMP_MOUSEBUTTONS | wn.IDCMP_MOUSEMOVE | wn.IDCMP_INACTIVEWINDOW | wn.IDCMP_VANILLAKEY),
            .{},
        });
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
        if (index) |i| if (i >= app.count) return;
        switch (choice) {
            .open => app.openEntry(index.?, &.{}),
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
            .settings => app.openSettings(),
            .quit => app.running = false,
        }
    }

    /// Prefs started on the dock's page, on its own: the dock does not
    /// wait for it.
    fn openSettings(app: *App) void {
        const dl = app.dl;
        const input = dl.Open("NIL:", dos.MODE_OLDFILE) orelse return app.ib.DisplayBeep(app.screen);
        const output = dl.Open("NIL:", dos.MODE_NEWFILE) orelse {
            _ = dl.Close(input);
            return app.ib.DisplayBeep(app.screen);
        };
        const tags = [_]TagItem{
            pair(dos.SYS_Asynch, 1),
            pair(dos.SYS_Input, @intFromPtr(input)),
            pair(dos.SYS_Output, @intFromPtr(output)),
            .{},
        };
        if (dl.SystemTagList(SETTINGS_COMMAND, &tags) < 0) {
            _ = dl.Close(input);
            _ = dl.Close(output);
            app.ib.DisplayBeep(app.screen);
        }
    }

    // --- a drawer's stack -----------------------------------------------------

    /// What is in the entry's drawer or disk, listed by it - as many as
    /// the screen has room for beside the dock, up to `stack_max` - and a
    /// last row that opens its window. One that cannot be read opens its
    /// window at once.
    fn openStack(app: *App, index: usize) void {
        app.closeTip();
        app.closeMenu();
        app.closeStack();
        const e = &app.entries[index];
        const path = e.path orelse return;
        const s = &app.stack;
        s.index = index;
        s.count = 0;
        s.hovered = null;
        s.armed = false;
        if (!app.readStack(path)) return app.openEntry(index, &.{});

        app.setFont(app.rp);
        s.row_height = @max(app.look.font_height + 6, stack_picture + 4);
        s.title_height = app.look.font_height + 8;
        const room = if (app.upright()) app.screen_height - app.bar_height else app.screen_height - app.bar_height - app.across;
        const fit = @max(0, @divTrunc(room - s.title_height - 8, s.row_height) - 1);
        s.count = @min(s.count, @as(usize, @intCast(fit)));
        // Each row's picture, from its icon or the default one.
        var full: [dos.path_max + 1]u8 = undefined;
        var widest = app.gb.TextLength(app.rp, &e.label, e.label_len) - stack_picture - 6;
        const last = openName(e);
        widest = @max(widest, app.gb.TextLength(app.rp, last, @intCast(sliceOf(last).len)));
        for (s.rows[0..s.count]) |*row| {
            widest = @max(widest, app.gb.TextLength(app.rp, &row.name, row.name_len));
            const name = app.inDrawer(path, row, &full) orelse continue;
            row.object = app.icons.GetDiskObjectNew(name);
            const object = row.object orelse continue;
            const image = object.image orelse continue;
            row.picture = app.icons.ObtainIconImage(image, stack_picture);
        }
        s.width = @min(widest + stack_picture + 30, @max(160, @divTrunc(app.screen_width, 3)));
        const height = s.title_height + @as(i32, @intCast(s.count + 1)) * s.row_height + 4;
        const cell = app.cellOf(e);
        const x = app.box.min_x + @divTrunc(cell.min_x + cell.max_x, 2);
        const y = app.box.min_y + @divTrunc(cell.min_y + cell.max_y, 2);
        const window = app.openBeside(s.width, height, x, y) orelse return app.closeStack();
        s.window = window;
        s.rp = @ptrFromInt(windowAttr(app.ib, window, wn.WA_RastPort));
        app.setFont(s.rp);
        app.drawStack();
    }

    /// The drawer's names read into the stack's rows in order; false when
    /// it is not a drawer that can be read.
    fn readStack(app: *App, path: [*:0]const u8) bool {
        const dl = app.dl;
        const lock = dl.Lock(path, dos.ACCESS_READ) orelse return false;
        defer dl.UnLock(lock);
        var fib: dos.FileInfoBlock = .{};
        if (!dl.Examine(lock, &fib) or fib.dir_entry_type <= 0) return false;
        while (dl.ExNext(lock, &fib)) {
            const name = sliceOf(@ptrCast(&fib.file_name));
            if (isIconFile(name)) continue;
            app.stackRow(name, fib.dir_entry_type > 0);
        }
        return true;
    }

    /// A name put among the rows in order - drawers first, then by name -
    /// while there is room, or when it comes before the last.
    fn stackRow(app: *App, name: []const u8, drawer: bool) void {
        const s = &app.stack;
        if (name.len == 0 or name.len > dos.name_max) return;
        var at = s.count;
        while (at > 0 and comesBefore(name, drawer, &s.rows[at - 1])) at -= 1;
        if (at == stack_max) return;
        var i = @min(s.count, stack_max - 1);
        while (i > at) : (i -= 1) s.rows[i] = s.rows[i - 1];
        if (s.count < stack_max) s.count += 1;
        const row = &s.rows[at];
        @memcpy(row.name[0..name.len], name);
        row.name[name.len] = 0;
        row.name_len = @intCast(name.len);
        row.drawer = drawer;
        row.object = null;
        row.picture = null;
    }

    /// A row's full name, the drawer's and its own, into `into`; null
    /// when it does not fit.
    fn inDrawer(app: *App, path: [*:0]const u8, row: *const StackRow, into: *[dos.path_max + 1]u8) ?[*:0]const u8 {
        const text = sliceOf(path);
        if (text.len >= into.len) return null;
        @memcpy(into[0..text.len], text);
        into[text.len] = 0;
        if (!app.dl.AddPart(@ptrCast(into), @ptrCast(&row.name), into.len)) return null;
        return @ptrCast(into);
    }

    fn closeStack(app: *App) void {
        const s = &app.stack;
        if (s.window) |window| app.ib.CloseWindow(window);
        s.window = null;
        for (s.rows[0..s.count]) |*row| {
            if (row.picture) |held| app.icons.ReleaseIconImage(held);
            app.icons.FreeDiskObject(row.object);
            row.picture = null;
            row.object = null;
        }
        s.count = 0;
        s.hovered = null;
        s.armed = false;
    }

    fn drawStack(app: *App) void {
        const s = &app.stack;
        if (s.window == null) return;
        const rp = s.rp;
        const e = &app.entries[s.index];
        const whole = Rect{ .min_x = 0, .min_y = 0, .max_x = s.width, .max_y = s.title_height + @as(i32, @intCast(s.count + 1)) * s.row_height + 4 };
        const text_x = 6 + stack_picture + 6;
        app.gb.BeginDraw(rp);
        app.fill(rp, app.look.ground, whole);
        app.bevel(rp, whole);
        app.pen(rp, app.look.text);
        app.gb.Move(rp, 12, 2 + 4 + app.look.baseline);
        app.gb.Text(rp, &e.label, e.label_len);
        app.fill(rp, app.look.shadow, .{ .min_x = 4, .min_y = s.title_height, .max_x = s.width - 4, .max_y = s.title_height + 1 });
        for (0..s.count + 1) |row| {
            const area = app.stackRowBox(row);
            const hovered = s.hovered == row;
            if (hovered) app.fill(rp, app.look.fill, area);
            const text_y = area.min_y + @divTrunc(s.row_height - app.look.font_height, 2) + app.look.baseline;
            app.pen(rp, if (hovered) app.look.fill_text else app.look.text);
            if (row == s.count) {
                const last = openName(e);
                app.gb.Move(rp, text_x, text_y);
                app.gb.Text(rp, last, @intCast(sliceOf(last).len));
                continue;
            }
            const r = &s.rows[row];
            if (r.picture) |picture| {
                const w: i32 = @intCast(picture.width);
                const h: i32 = @intCast(picture.height);
                const x = 6 + @divTrunc(stack_picture - w, 2);
                const y = area.min_y + @divTrunc(s.row_height - h, 2);
                const spot = Rect{ .min_x = x, .min_y = y, .max_x = x + w, .max_y = y + h };
                app.gb.BlendPixelArray(rp, picture.pixels, picture.width * 4, @intFromEnum(rtg.PixelFormat.rgba32), 0, 0, &spot);
            }
            var extent: graphics.TextExtent = undefined;
            const fits = app.gb.TextFit(rp, &r.name, r.name_len, &extent, null, 1, s.width - text_x - 8, app.look.font_height + 8);
            app.gb.Move(rp, text_x, text_y);
            app.gb.Text(rp, &r.name, fits);
        }
        app.gb.EndDraw(rp);
    }

    /// A stack's row - `count` for the last, which opens the window.
    fn stackRowBox(app: *const App, row: usize) Rect {
        const s = &app.stack;
        const top = 2 + s.title_height + @as(i32, @intCast(row)) * s.row_height;
        return .{ .min_x = 2, .min_y = top, .max_x = s.width - 2, .max_y = top + s.row_height };
    }

    fn stackRowAt(app: *const App, x: i32, y: i32) ?usize {
        for (0..app.stack.count + 1) |row| {
            const area = app.stackRowBox(row);
            if (x >= area.min_x and x < area.max_x and y >= area.min_y and y < area.max_y) return row;
        }
        return null;
    }

    fn stackInput(app: *App, class: u32, code: u32, x: i32, y: i32) void {
        switch (class) {
            wn.IDCMP_MOUSEMOVE => app.stackHover(app.stackRowAt(x, y)),
            wn.IDCMP_MOUSEBUTTONS => switch (code) {
                wn.SELECTDOWN => {
                    app.stack.armed = true;
                    app.stackHover(app.stackRowAt(x, y));
                },
                wn.SELECTUP => {
                    if (!app.stack.armed) return;
                    app.stack.armed = false;
                    if (app.stackRowAt(x, y)) |row| app.stackChoose(row);
                },
                else => {},
            },
            wn.IDCMP_VANILLAKEY => switch (code) {
                0x1B => app.closeStack(),
                '\r', '\n' => if (app.stack.hovered) |row| app.stackChoose(row),
                else => {},
            },
            wn.IDCMP_INACTIVEWINDOW => app.closeStack(),
            else => {},
        }
    }

    fn stackHover(app: *App, row: ?usize) void {
        if (row == app.stack.hovered) return;
        app.stack.hovered = row;
        app.drawStack();
    }

    /// A row of the stack chosen: what it names opened, or - the last -
    /// the drawer's window.
    fn stackChoose(app: *App, row: usize) void {
        const s = &app.stack;
        const index = s.index;
        if (index >= app.count) return app.closeStack();
        if (row >= s.count) {
            app.closeStack();
            return app.openEntry(index, &.{});
        }
        const path = app.entries[index].path orelse return app.closeStack();
        var full: [dos.path_max + 1]u8 = undefined;
        const name = app.inDrawer(path, &s.rows[row], &full);
        app.closeStack();
        const chosen = name orelse return app.ib.DisplayBeep(app.screen);
        if (!app.ab.OpenObject(chosen, null)) app.ib.DisplayBeep(app.screen);
    }
};

/// The stack's last row: what opens the entry's own window.
fn openName(e: *const Entry) [*:0]const u8 {
    const object = e.object orelse return "Open Drawer";
    return if (object.kind == icon.WBDISK) "Open Disk" else "Open Drawer";
}

/// Whether a name is an icon's file, "name.info", which the stack leaves
/// out as the desktop does.
fn isIconFile(name: []const u8) bool {
    const suffix = ".info";
    if (name.len <= suffix.len) return false;
    for (name[name.len - suffix.len ..], suffix) |c, want| {
        if (lower(c) != want) return false;
    }
    return true;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

/// Whether a name comes before a row's: a drawer before a file, else by
/// the letters, their case aside.
fn comesBefore(name: []const u8, drawer: bool, row: *const StackRow) bool {
    if (drawer != row.drawer) return drawer;
    const other = row.name[0..row.name_len];
    for (name[0..@min(name.len, other.len)], other[0..@min(name.len, other.len)]) |a, b| {
        if (lower(a) != lower(b)) return lower(a) < lower(b);
    }
    return name.len < other.len;
}

fn sameText(a: []const u8, b: []const u8) bool {
    return a.len == b.len and for (a, b) |x, y| {
        if (x != y) break false;
    } else true;
}

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
    // Taken off first, so that nothing more comes - unless it was, by a
    // dock waiting for what it started; what came is answered.
    var listed = true;
    defer {
        if (listed) sys.RemPort(public);
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
    // Every run is back before the dock ends (see below), so nothing is
    // left here when the port goes.
    const run_port = sys.CreateMsgPort() orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.DeleteMsgPort(run_port);

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
        .run_port = run_port,
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

    app.layout();
    const box = app.boxFor();
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
    // Closed here unless it was, by a dock waiting for what it started.
    defer if (app.window) |shown| ib.CloseWindow(shown);
    app.window = window;
    app.rp = @ptrFromInt(windowAttr(ib, window, wn.WA_RastPort));
    app.setFont(app.rp);
    app.readBox();
    app.draw();
    defer app.closeTip();
    defer app.closeMenu();
    defer app.closeStack();

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
    app.mb.StartTimer(app.tick);

    // On a composed screen: the pictures' quicker clock, and the slide.
    var quick_mask: u32 = 0;
    var slide_mask: u32 = 0;
    const quick_bit: i8 = if (composed) sys.AllocSignal(-1) else -1;
    defer if (quick_bit >= 0) sys.FreeSignal(quick_bit);
    const slide_bit: i8 = if (composed) sys.AllocSignal(-1) else -1;
    defer if (slide_bit >= 0) sys.FreeSignal(slide_bit);
    if (quick_bit >= 0) {
        app.quick = app.mb.CreateTimerTagList(&[_]TagItem{
            pair(motion.TIMER_Period, grow_every),
            pair(motion.TIMER_Repeat, motion.TIMER_FOREVER),
            pair(motion.TIMER_Signal, @intCast(quick_bit)),
            .{},
        });
        if (app.quick != null) quick_mask = @as(u32, 1) << @intCast(quick_bit);
    }
    defer app.mb.DeleteTimer(app.quick);
    if (slide_bit >= 0) {
        app.slide = app.mb.CreateAnimationTagList(&[_]TagItem{
            pair(motion.ANIM_Duration, slide_time),
            pair(motion.ANIM_Easing, motion.EASE_INOUT),
            pair(motion.ANIM_Rate, 60),
            pair(motion.ANIM_Signal, @intCast(slide_bit)),
            .{},
        });
        if (app.slide != null) slide_mask = @as(u32, 1) << @intCast(slide_bit);
    }
    defer app.mb.DeleteAnimation(app.slide);

    app.joinDesktop();
    defer {
        _ = app.ab.RemoveAppWindow(app.app_window);
        _ = app.ab.RemoveAppMenuItem(app.app_item);
    }

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
        const windows = portMask(ib, window) | portMask(ib, app.menu.window) | portMask(ib, app.stack.window);
        const got = sys.Wait(windows | public.sigMask() | app_port.sigMask() | notify_port.sigMask() | run_port.sigMask() | tick_mask | quick_mask | slide_mask | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) break;
        if (got & tick_mask != 0) app.ticked();
        if (got & quick_mask != 0) app.grown();
        if (got & slide_mask != 0) app.slid();
        while (take(ib, window)) |input| app.dockInput(input.class, input.code, input.x, input.y);
        while (app.menu.window) |shown| {
            const input = take(ib, shown) orelse break;
            app.menuInput(input.class, input.code, input.x, input.y);
        }
        while (app.stack.window) |shown| {
            const input = take(ib, shown) orelse break;
            app.stackInput(input.class, input.code, input.x, input.y);
        }
        while (sys.GetMsg(run_port)) |message| app.runEnded(message);
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

    // What it started runs yet, and will tell this dock when it ends: the
    // dock goes - no longer found as the dock, nor the desktop's, nor
    // seen - and waits for each to end before its port and its memory go.
    if (app.run_count > 0) {
        sys.RemPort(public);
        listed = false;
        _ = app.ab.RemoveAppWindow(app.app_window);
        _ = app.ab.RemoveAppMenuItem(app.app_item);
        app.app_window = null;
        app.app_item = null;
        app.closeStack();
        app.closeMenu();
        app.closeTip();
        ib.CloseWindow(window);
        app.window = null;
        while (app.run_count > 0) {
            _ = sys.WaitPort(run_port);
            while (sys.GetMsg(run_port)) |message| app.runEnded(message);
        }
    }
    return dos.RETURN_OK;
}
