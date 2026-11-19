// SPDX-License-Identifier: MIT
//! Paint: pictures painted with the pointer. Built against the SDK only.
//!
//!   Paint [SCREEN=OWN|DESKTOP]
//!
//! A window with the picture, the tools down its right and the colours
//! along its bottom. It opens on the desktop's screen, or on a screen of
//! its own (`SCREEN=OWN`, from the shell or as the icon's tool type): a
//! window over the whole screen under its bar, the menus in the bar.
//! Without either it opens where it did the last time - Settings' Own
//! Screen switches while it runs, and `ENV:Paint.prefs` keeps the
//! choice (`SCREEN=OWN`), ENVARC: too. A switch takes the window down and
//! makes it again on the other screen; the picture, the zoom, the brush,
//! the colours and what can be undone stay.
//!
//! **The picture** is true colour, `0xAARRGGBB` a pixel, as large as the
//! screen to begin with; Project's New... asks for another size. It is
//! shown in canvas.gadget, which follows its box: Paint makes the rows the
//! window shows from the picture (view.zig) - at a zoom of 1 to 16, with a
//! grid from 8 on, a smaller picture in the middle - and writes only the
//! area a change touched. The scroll bars in the border move over a
//! picture larger than the view; so do the wheel (with Shift across) and
//! the cursor keys.
//!
//! **Painting.** The select button paints in the foreground colour, the
//! menu button in the background colour - the canvas takes the menu
//! button over its box (`GA_MenuButton`), so the menus stay shut there and
//! open anywhere else. The tools: freehand, a line along the way the
//! pointer goes, and dotted freehand, the brush put down wherever the
//! pointer is told to be. The brush is round or square and 1 to 32 pixels
//! (brush.zig), chosen in the Brush menu or with `[` and `]` - or `<`
//! and `>`, one key on a German keyboard.
//!
//! **The colours.** palette.gadget shows 32 colours: the select button
//! picks the foreground, the menu button the background (`PALETTE_Button`);
//! the two are shown beside it, the foreground in front, and a click there
//! swaps them, as `x` does.
//!
//! **Undo.** Every stroke, clear and so on is kept for undoing and redoing
//! (history.zig), as far back as a block of three pictures' worth - or half
//! the memory free, when that is less - reaches; the oldest go first.
//!
//! The menus, with their keys (pressed with the right command key):
//!
//!   Project   New... (N), Quit (Q)
//!   Edit      Undo (Z), Redo (Y), Swap Colours, Clear (K)
//!   View      Zoom In (+), Zoom Out (-), Actual Size (1), Grid (G)
//!   Brush     Round, Square, Size, Smaller ([), Larger (])
//!   Settings  Own Screen
//!
//! Without a menu key: `+` and `-` zoom, `[` and `]` (or `<` and `>`)
//! size the brush, `x` swaps the colours, the cursor keys scroll. A picture that has changed is not let go - by New,
//! Quit, Ctrl-C or the close gadget - before a requester asks.
//!
//! Its texts are in `paint.cd`, read through `sdk.locale.Strings`.

const sdk = @import("sdk");
const strings = @import("strings");
const Text = sdk.locale.Strings(strings);
const Id = strings.Id;
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const icon = sdk.icon;
const ie = sdk.devices.inputevent;
const wn = intuition.windows;
const sc = intuition.screens;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const mn = intuition.menus;
const classusr = intuition.classusr;
const icc = intuition.icclass;
const cv = sdk.gadgets.canvas;
const pa = sdk.gadgets.palette;
const tb = sdk.gadgets.toolbutton;
const tx = sdk.gadgets.text;
const sr = sdk.gadgets.scroller;
const ig = sdk.gadgets.integer;
const command = sdk.images.command;
const prefs = sdk.prefs;
const rdargs = dos.rdargs;
const PixelFormat = sdk.rtg.PixelFormat;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const IconBase = sdk.interface.icon.IconBase;
const Object = intuition.Object;
const Window = intuition.Window;
const Screen = intuition.Screen;
const RastPort = graphics.RastPort;
const TagItem = sdk.utility.TagItem;

const picture_zig = @import("picture.zig");
const brush_zig = @import("brush.zig");
const history_zig = @import("history.zig");
const view_zig = @import("view.zig");
const Picture = picture_zig.Picture;
const Pixel = picture_zig.Pixel;
const Area = picture_zig.Area;
const Brush = brush_zig.Brush;
const History = history_zig.History;
const View = view_zig.View;

pub const COMMAND_NAME = "Paint";
const VERSION = "1.0";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (19.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
/// What the screen's bar says while the window is active, and the own
/// screen's title.
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const template = "SCREEN/K";
const ENV_FILE = "ENV:Paint.prefs";
const ENVARC_FILE = "ENVARC:Paint.prefs";

/// The largest side of a picture.
const max_side = 16384;
/// The view's rows made at a time before they are written.
const band_rows = 16;
/// The least the history is given, and what it gives up trying below.
const least_history = 16 * 1024;

const ID_VIEW = 1;
const ID_COLOURS = 2;
const ID_PALETTE = 3;
const ID_STATUS = 4;
const ID_VERT = 10;
const ID_HORIZ = 11;
// The new picture's window.
const ID_WIDTH = 20;
const ID_HEIGHT = 21;
const ID_OK = 22;
const ID_CANCEL = 23;

const raw_up = 0x4C;
const raw_down = 0x4D;
const raw_right = 0x4E;
const raw_left = 0x4F;

/// The painting tools; a tool's button has `id()` as its `GA_ID`.
const Tool = enum(u32) {
    freehand,
    dots,

    const base = 300;

    fn id(tool: Tool) u32 {
        return base + @intFromEnum(tool);
    }

    fn of(value: usize) ?Tool {
        if (value < base or value >= base + @typeInfo(Tool).@"enum".fields.len) return null;
        return @enumFromInt(value - base);
    }
};

/// What Paint does when asked: a menu item's user data, and a button's
/// `GA_ID`, so the two are one command.
const Command = enum(u32) {
    new = 100,
    quit,
    undo,
    redo,
    swap,
    clear,
    zoom_in,
    zoom_out,
    actual_size,
    grid,
    round,
    square,
    smaller,
    larger,
    own_screen,

    fn id(which: Command) u32 {
        return @intFromEnum(which);
    }

    fn of(value: usize) ?Command {
        if (value < @intFromEnum(Command.new) or value > @intFromEnum(Command.own_screen)) return null;
        return @enumFromInt(value);
    }
};

/// The Size submenu's items have `size_base` and the size's place in
/// `brush_zig.sizes` as their user data.
const size_base = 200;
const size_labels = [_][*:0]const u8{ "1", "2", "3", "4", "6", "8", "12", "16", "24", "32" };
comptime {
    if (size_labels.len != brush_zig.sizes.len) @compileError("a label for every brush size");
}

/// The colours the palette offers to begin with: black, white and greys,
/// a ring of hues, the same darker, and earth and skin.
const colours = [32]Pixel{
    0xFF000000, 0xFFFFFFFF, 0xFF404040, 0xFF808080, 0xFFC0C0C0, 0xFFE02828, 0xFFF08A1E, 0xFFF5D820,
    0xFF8CD02A, 0xFF22A447, 0xFF1FB3A3, 0xFF2AB4F0, 0xFF2858D8, 0xFF5A35C8, 0xFF9A35C8, 0xFFE03AA0,
    0xFF202020, 0xFF606060, 0xFFA0A0A0, 0xFFE0E0E0, 0xFF801818, 0xFF8A4A10, 0xFF8A7A10, 0xFF4A7A18,
    0xFF145A28, 0xFF106A60, 0xFF186A90, 0xFF183480, 0xFF341E78, 0xFF581E78, 0xFF801E5A, 0xFF5A3A22,
};
const black_index = 0;
const white_index = 1;

/// The tools down the right, and the commands under them.
const ToolEntry = struct { tool: Tool, glyph: u32, hint: Id };
const tools = [_]ToolEntry{
    .{ .tool = .freehand, .glyph = command.CMD_PENCIL, .hint = .MSG_TOOL_FREEHAND },
    .{ .tool = .dots, .glyph = command.CMD_BRUSH, .hint = .MSG_TOOL_DOTS },
};
const ButtonEntry = struct { which: Command, glyph: u32, hint: Id };
const buttons = [_]ButtonEntry{
    .{ .which = .undo, .glyph = command.CMD_UNDO, .hint = .MSG_UNDO_HINT },
    .{ .which = .redo, .glyph = command.CMD_REDO, .hint = .MSG_REDO_HINT },
    .{ .which = .zoom_in, .glyph = command.CMD_ZOOM_IN, .hint = .MSG_ZOOM_IN_HINT },
    .{ .which = .zoom_out, .glyph = command.CMD_ZOOM_OUT, .hint = .MSG_ZOOM_OUT_HINT },
};
const undo_button = 0;
const redo_button = 1;

// --- the menus ---------------------------------------------------------------

/// A menu's entry, and the string its label is.
const MenuEntry = struct { menu: mn.NewMenu, text: ?Id = null };

fn menuTitle(text: Id) MenuEntry {
    return .{ .menu = .{ .type = mn.NM_TITLE, .label = strings.builtin(text) }, .text = text };
}

fn item(text: Id, key: ?[*:0]const u8, which: Command) MenuEntry {
    return .{ .menu = .{ .type = mn.NM_ITEM, .label = strings.builtin(text), .comm_key = key, .user_data = @ptrFromInt(which.id()) }, .text = text };
}

/// An item with a check mark that turns as it is picked.
fn toggleItem(text: Id, key: ?[*:0]const u8, which: Command) MenuEntry {
    var made = item(text, key, which);
    made.menu.flags = mn.CHECKIT | mn.MENUTOGGLE;
    return made;
}

/// One of a group with check marks, `exclude` the others' places.
fn choiceItem(text: Id, which: Command, exclude: u32) MenuEntry {
    var made = item(text, null, which);
    made.menu.flags = mn.CHECKIT;
    made.menu.mutual_exclude = exclude;
    return made;
}

fn sizeItem(comptime place: usize) MenuEntry {
    const all: u32 = (1 << size_labels.len) - 1;
    return .{ .menu = .{
        .type = mn.NM_SUB,
        .label = size_labels[place],
        .flags = mn.CHECKIT,
        .mutual_exclude = all & ~@as(u32, 1 << place),
        .user_data = @ptrFromInt(size_base + place),
    } };
}

const bar = MenuEntry{ .menu = .{ .type = mn.NM_ITEM, .label = mn.NM_BARLABEL } };

const menus = [_]MenuEntry{
    menuTitle(.MSG_MENU_PROJECT),
    item(.MSG_MENU_NEW, "N", .new),
    bar,
    item(.MSG_MENU_QUIT, "Q", .quit),
    menuTitle(.MSG_MENU_EDIT),
    item(.MSG_MENU_UNDO, "Z", .undo),
    item(.MSG_MENU_REDO, "Y", .redo),
    bar,
    item(.MSG_MENU_SWAP, null, .swap),
    item(.MSG_MENU_CLEAR, "K", .clear),
    menuTitle(.MSG_MENU_VIEW),
    item(.MSG_MENU_ZOOM_IN, "+", .zoom_in),
    item(.MSG_MENU_ZOOM_OUT, "-", .zoom_out),
    item(.MSG_MENU_ACTUAL_SIZE, "1", .actual_size),
    bar,
    toggleItem(.MSG_MENU_GRID, "G", .grid),
    menuTitle(.MSG_MENU_BRUSH),
    // Round and Square, the first two, rule each other out.
    choiceItem(.MSG_MENU_ROUND, .round, 1 << 1),
    choiceItem(.MSG_MENU_SQUARE, .square, 1 << 0),
    bar,
    .{ .menu = .{ .type = mn.NM_ITEM, .label = strings.builtin(.MSG_MENU_SIZE) }, .text = .MSG_MENU_SIZE },
} ++ sizeItems() ++ [_]MenuEntry{
    item(.MSG_MENU_SMALLER, "[", .smaller),
    item(.MSG_MENU_LARGER, "]", .larger),
    menuTitle(.MSG_MENU_SETTINGS),
    toggleItem(.MSG_MENU_OWN_SCREEN, null, .own_screen),
    .{ .menu = .{} },
};

fn sizeItems() [size_labels.len]MenuEntry {
    var made: [size_labels.len]MenuEntry = undefined;
    inline for (0..size_labels.len) |place| made[place] = sizeItem(place);
    return made;
}

/// What the menus' check marks and the undo items show, as last set.
const MenuState = struct {
    round: bool,
    size: u32,
    grid: bool,
    own: bool,
    can_undo: bool,
    can_redo: bool,
};

// --- the window ----------------------------------------------------------------

/// The window and what is in it, made for one screen; made again for the
/// other when the screen changes.
const Gui = struct {
    screen: ?*Screen = null,
    own: bool = false,
    draw_info: ?*sc.DrawInfo = null,
    images: [tools.len + buttons.len]?*Object = @splat(null),
    object: ?*Object = null,
    window: *Window = undefined,
    view: *Object = undefined,
    colours: *Object = undefined,
    palette: *Object = undefined,
    status: *Object = undefined,
    tool_buttons: [tools.len]*Object = undefined,
    command_buttons: [buttons.len]*Object = undefined,
    vert: ?*Object = null,
    horiz: ?*Object = null,
    strip: ?*intuition.Menu = null,
    /// Onto the view's and the colours' pictures.
    view_rp: *RastPort = undefined,
    colours_rp: *RastPort = undefined,
    /// The window's own ground, round the two colours.
    ground: Pixel = 0xFFA0A0A0,
    shown_menus: ?MenuState = null,
    shown_undo: ?[2]bool = null,

    fn close(gui: *Gui, ib: *IntuitionBase) void {
        if (gui.strip) |strip| {
            ib.ClearMenuStrip(gui.window);
            ib.FreeMenus(strip);
        }
        // The layout and every gadget in it go with the window object.
        ib.DisposeObject(gui.object);
        for (gui.images) |image| ib.DisposeObject(image);
        const screen = gui.screen orelse return;
        if (gui.draw_info) |info| ib.FreeScreenDrawInfo(screen, info);
        if (gui.own) _ = ib.CloseScreen(screen) else ib.UnlockPubScreen(null, screen);
        gui.* = .{};
    }
};

/// A stroke being painted: its colour, where the pointer was last, and
/// what it has changed.
const Stroke = struct {
    colour: Pixel,
    last: ?[2]i32 = null,
    changed: Area = Area.none,
};

const App = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ib: *IntuitionBase,
    gb: *GraphicsBase,
    ub: ?*UtilityBase,
    text: *const Text,

    picture: Picture = undefined,
    kept: Picture = undefined,
    history: History = undefined,
    /// The memory of the three, AllocVec's; null before the first.
    memory: [3]?*anyopaque = @splat(null),
    /// Changed since it was made.
    changed: bool = false,

    tool: Tool = .freehand,
    brush: Brush = .{},
    foreground: Pixel = colours[black_index],
    background: Pixel = colours[white_index],
    /// The foreground's place in the palette.
    foreground_index: u32 = black_index,
    stroke: ?Stroke = null,
    /// Where the pointer was told to be while painting, for the status.
    at: ?[2]i32 = null,

    view: View = .{},
    /// What is to be shown again: an area of the picture, or all.
    pending: Area = Area.none,
    whole: bool = false,
    band: ?[*]Pixel = null,
    band_width: u32 = 0,

    gui: ?Gui = null,
    own: bool = false,
    switch_wanted: bool = false,
    status: [128:0]u8 = @splat(0),

    /// The window's state while it is open.
    fn ui(app: *App) ?*Gui {
        return if (app.gui) |*gui| gui else null;
    }

    // --- the picture ----------------------------------------------------------

    /// A new picture of that size in the background colour, the history
    /// emptied; the old one stays when there is no memory for it.
    fn newPicture(app: *App, width: u32, height: u32) bool {
        if (width == 0 or height == 0 or width > max_side or height > max_side) return false;
        const bytes = Picture.bytesFor(width, height);
        const sys = app.sys;
        const first = sys.AllocVec(bytes, exec.MEMF_ANY) orelse return false;
        const second = sys.AllocVec(bytes, exec.MEMF_ANY) orelse {
            sys.FreeVec(first);
            return false;
        };
        // Three pictures' worth to undo with, or half of the largest block
        // free when that is less.
        var room = @min(3 * bytes, sys.AvailMem(exec.MEMF_ANY | exec.MEMF_LARGEST) / 2) & ~@as(usize, 3);
        const third = while (room >= least_history) : (room = (room / 2) & ~@as(usize, 3)) {
            if (sys.AllocVec(room, exec.MEMF_ANY)) |made| break made;
        } else {
            sys.FreeVec(first);
            sys.FreeVec(second);
            return false;
        };
        app.freePicture();
        app.memory = .{ first, second, third };
        app.picture = .{ .pixels = @ptrCast(@alignCast(first)), .width = width, .height = height };
        app.kept = .{ .pixels = @ptrCast(@alignCast(second)), .width = width, .height = height };
        app.history = .{ .memory = @ptrCast(@alignCast(third)), .size = room };
        app.picture.fill(app.background);
        app.kept.fill(app.background);
        app.changed = false;
        app.stroke = null;
        app.view.left = 0;
        app.view.top = 0;
        app.view.fit(width, height);
        app.whole = true;
        return true;
    }

    fn freePicture(app: *App) void {
        for (&app.memory) |*memory| {
            if (memory.*) |block| app.sys.FreeVec(block);
            memory.* = null;
        }
    }

    /// A change of `area` made: kept for undoing, and shown.
    fn changedArea(app: *App, area: Area) void {
        if (area.isEmpty()) return;
        app.changed = true;
        if (!app.history.record(&app.picture, &app.kept, area)) app.tell(.MSG_NO_UNDO);
        app.show(area);
    }

    // --- painting -------------------------------------------------------------

    /// The pointer pressed on the picture, or moved while pressed: the
    /// tool at work there. `final` for the place it was let go at.
    fn paintTo(app: *App, final: bool) void {
        const gui = app.ui() orelse return;
        var x: usize = 0;
        var y: usize = 0;
        var button: usize = cv.CANVAS_SELECT;
        _ = app.ib.GetAttr(cv.CANVAS_X, gui.view, &x);
        _ = app.ib.GetAttr(cv.CANVAS_Y, gui.view, &y);
        _ = app.ib.GetAttr(cv.CANVAS_Button, gui.view, &button);
        const at = app.view.toPicture(@truncate(@as(isize, @bitCast(x))), @truncate(@as(isize, @bitCast(y))));
        if (app.stroke == null) app.stroke = .{ .colour = if (button == cv.CANVAS_MENU) app.background else app.foreground };
        const stroke = &app.stroke.?;
        var changed = Area.none;
        switch (app.tool) {
            .freehand => if (stroke.last) |last|
                brush_zig.line(&app.picture, app.brush, last[0], last[1], at[0], at[1], stroke.colour, &changed)
            else
                brush_zig.stamp(&app.picture, app.brush, at[0], at[1], stroke.colour, &changed),
            .dots => brush_zig.stamp(&app.picture, app.brush, at[0], at[1], stroke.colour, &changed),
        }
        stroke.last = at;
        stroke.changed = stroke.changed.add(changed);
        app.at = at;
        app.show(changed);
        if (final) app.endStroke();
    }

    /// The stroke over: what it changed kept for undoing.
    fn endStroke(app: *App) void {
        const stroke = app.stroke orelse return;
        app.stroke = null;
        app.at = null;
        if (stroke.changed.isEmpty()) return;
        app.changed = true;
        if (!app.history.record(&app.picture, &app.kept, stroke.changed)) app.tell(.MSG_NO_UNDO);
    }

    // --- the view -------------------------------------------------------------

    fn show(app: *App, area: Area) void {
        app.pending = app.pending.add(area);
    }

    /// The canvas made as large as its box, after the window opened or
    /// was sized; the view follows.
    fn fitView(app: *App) void {
        const gui = app.ui() orelse return;
        _ = app.ib.SetGadgetAttrsTagList(gui.view, gui.window, &[_]TagItem{
            .{ .tag = cv.CANVAS_Width, .data = 0 },
            .{ .tag = cv.CANVAS_Height, .data = 0 },
            .{},
        });
        var value: usize = 0;
        _ = app.ib.GetAttr(cv.CANVAS_RastPort, gui.view, &value);
        gui.view_rp = @ptrFromInt(value);
        _ = app.ib.GetAttr(cv.CANVAS_Width, gui.view, &value);
        app.view.width = @truncate(value);
        _ = app.ib.GetAttr(cv.CANVAS_Height, gui.view, &value);
        app.view.height = @truncate(value);
        if (app.view.width > app.band_width) {
            if (app.band) |band| app.sys.FreeVec(band);
            app.band = @ptrCast(@alignCast(app.sys.AllocVec(@as(usize, app.view.width) * band_rows * @sizeOf(Pixel), exec.MEMF_ANY)));
            app.band_width = if (app.band != null) app.view.width else 0;
        }
        app.view.fit(app.picture.width, app.picture.height);
        app.whole = true;
        app.followBars();
    }

    /// What is pending drawn into the canvas and shown, with the status
    /// and the menus brought up to date.
    fn flush(app: *App) void {
        const gui = app.ui() orelse return;
        const area = if (app.whole) Area{ .max_x = @intCast(app.view.width), .max_y = @intCast(app.view.height) } else app.view.toView(app.pending);
        app.whole = false;
        app.pending = Area.none;
        if (!area.isEmpty() and app.band != null) {
            const band = app.band.?;
            const width = area.width();
            var y = area.min_y;
            while (y < area.max_y) {
                const rows: i32 = @min(band_rows, area.max_y - y);
                var row: i32 = 0;
                while (row < rows) : (row += 1) {
                    const start: usize = @as(usize, @intCast(row)) * width;
                    app.view.row(&app.picture, y + row, area.min_x, area.max_x, band[start .. start + width]);
                }
                app.gb.WritePixelArray(gui.view_rp, @ptrCast(band), width * @sizeOf(Pixel), @intFromEnum(PixelFormat.bgra32), 0, 0, &.{
                    .min_x = area.min_x,
                    .min_y = y,
                    .max_x = area.max_x,
                    .max_y = y + rows,
                });
                y += rows;
            }
            app.ib.QueueGadgetRefresh(gui.view);
        }
        app.showStatus();
        app.syncMenus();
        app.syncButtons();
    }

    /// The bars set from the view: the picture's pixels across and down,
    /// those shown, and the first shown.
    fn followBars(app: *App) void {
        const gui = app.ui() orelse return;
        const pairs = [_]struct { gadget: ?*Object, total: u32, visible: u32, top: i32 }{
            .{ .gadget = gui.horiz, .total = app.picture.width, .visible = @min(app.view.columns(), app.picture.width), .top = app.view.left },
            .{ .gadget = gui.vert, .total = app.picture.height, .visible = @min(app.view.rows(), app.picture.height), .top = app.view.top },
        };
        for (pairs) |pair| {
            const gadget = pair.gadget orelse continue;
            _ = app.ib.SetGadgetAttrsTagList(gadget, gui.window, &[_]TagItem{
                .{ .tag = sr.SCROLLER_Total, .data = pair.total },
                .{ .tag = sr.SCROLLER_Visible, .data = pair.visible },
                .{ .tag = sr.SCROLLER_Top, .data = @intCast(pair.top) },
                .{},
            });
        }
    }

    /// The view moved to where the bars are.
    fn followScrollers(app: *App) void {
        const gui = app.ui() orelse return;
        var left: usize = @intCast(app.view.left);
        var top: usize = @intCast(app.view.top);
        if (gui.horiz) |scroller| _ = app.ib.GetAttr(sr.SCROLLER_Top, scroller, &left);
        if (gui.vert) |scroller| _ = app.ib.GetAttr(sr.SCROLLER_Top, scroller, &top);
        if (left == app.view.left and top == app.view.top) return;
        app.view.left = @intCast(left);
        app.view.top = @intCast(top);
        app.view.fit(app.picture.width, app.picture.height);
        app.whole = true;
    }

    /// The view scrolled by picture pixels.
    fn scrollBy(app: *App, across: i32, down: i32) void {
        app.view.left += across;
        app.view.top += down;
        app.view.fit(app.picture.width, app.picture.height);
        app.whole = true;
        app.followBars();
    }

    /// The zoom changed about the view's middle.
    fn zoomTo(app: *App, zoom: u32) void {
        if (zoom == app.view.zoom) return;
        app.view.zoomAt(zoom, @intCast(app.view.width / 2), @intCast(app.view.height / 2), app.picture.width, app.picture.height);
        app.whole = true;
        app.followBars();
    }

    /// The two colours, the foreground in front of the background.
    fn drawColours(app: *App) void {
        const gui = app.ui() orelse return;
        const rp = gui.colours_rp;
        const fills = [_]struct { colour: Pixel, area: graphics.Rect }{
            .{ .colour = gui.ground, .area = .{ .max_x = 30, .max_y = 30 } },
            .{ .colour = 0xFF000000, .area = .{ .min_x = 10, .min_y = 10, .max_x = 30, .max_y = 30 } },
            .{ .colour = app.background, .area = .{ .min_x = 11, .min_y = 11, .max_x = 29, .max_y = 29 } },
            .{ .colour = 0xFF000000, .area = .{ .max_x = 20, .max_y = 20 } },
            .{ .colour = app.foreground, .area = .{ .min_x = 1, .min_y = 1, .max_x = 19, .max_y = 19 } },
        };
        for (fills) |fill| {
            app.gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = fill.colour }, .{} });
            app.gb.RectFill(rp, &fill.area);
        }
        app.ib.QueueGadgetRefresh(gui.colours);
    }

    /// The line under the picture: its size, the zoom, the brush, and
    /// where the pointer is while painting.
    fn showStatus(app: *App) void {
        const gui = app.ui() orelse return;
        var line: [128]u8 = undefined;
        const made = if (app.at) |at|
            app.text.format(&line, .MSG_STATUS_AT, .{ @as(i64, app.picture.width), @as(i64, app.picture.height), @as(i64, app.view.zoom), @as(i64, app.brush.size), @as(i64, at[0]), @as(i64, at[1]) })
        else
            app.text.format(&line, .MSG_STATUS, .{ @as(i64, app.picture.width), @as(i64, app.picture.height), @as(i64, app.view.zoom), @as(i64, app.brush.size) });
        if (same(made, &app.status)) return;
        const length = @min(made.len, app.status.len);
        @memcpy(app.status[0..length], made[0..length]);
        app.status[length] = 0;
        _ = app.ib.SetGadgetAttrsTagList(gui.status, gui.window, &[_]TagItem{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&app.status) }, .{} });
    }

    // --- the menus and the buttons --------------------------------------------

    fn menuState(app: *const App) MenuState {
        return .{
            .round = app.brush.shape == .round,
            .size = app.brush.size,
            .grid = app.view.grid,
            .own = app.own,
            .can_undo = app.history.canUndo(),
            .can_redo = app.history.canRedo(),
        };
    }

    /// The check marks and Undo and Redo set from what Paint is doing,
    /// when that has changed since they were.
    fn syncMenus(app: *App) void {
        const gui = app.ui() orelse return;
        const strip = gui.strip orelse return;
        const state = app.menuState();
        if (gui.shown_menus) |shown| {
            if (sameState(shown, state)) return;
        }
        gui.shown_menus = state;
        app.ib.ClearMenuStrip(gui.window);
        var menu: ?*intuition.Menu = strip;
        while (menu) |title| : (menu = title.next_menu) {
            var entry = title.first_item;
            while (entry) |menu_item| : (entry = menu_item.next_item) {
                syncItem(state, menu_item);
                var sub = menu_item.sub_item;
                while (sub) |sub_item| : (sub = sub_item.next_item) syncItem(state, sub_item);
            }
        }
        _ = app.ib.ResetMenuStrip(gui.window, strip);
    }

    /// Undo and Redo's buttons disabled while there is nothing to do.
    fn syncButtons(app: *App) void {
        const gui = app.ui() orelse return;
        const state = [2]bool{ app.history.canUndo(), app.history.canRedo() };
        if (gui.shown_undo) |shown| {
            if (shown[0] == state[0] and shown[1] == state[1]) return;
        }
        gui.shown_undo = state;
        for ([_]usize{ undo_button, redo_button }, state) |place, can| {
            _ = app.ib.SetGadgetAttrsTagList(gui.command_buttons[place], gui.window, &[_]TagItem{ .{ .tag = gc.GA_Disabled, .data = @intFromBool(!can) }, .{} });
        }
    }

    /// The tool chosen, its button down and the others up.
    fn chooseTool(app: *App, tool: Tool) void {
        app.tool = tool;
        const gui = app.ui() orelse return;
        for (tools, gui.tool_buttons) |entry, button| {
            _ = app.ib.SetGadgetAttrsTagList(button, gui.window, &[_]TagItem{ .{ .tag = tb.TOOLBUTTON_Checked, .data = @intFromBool(entry.tool == tool) }, .{} });
        }
    }

    // --- the commands ---------------------------------------------------------

    /// A menu item picked. False to end.
    fn picked(app: *App, number: u32) bool {
        const gui = app.ui() orelse return true;
        const strip = gui.strip orelse return true;
        const picked_item = app.ib.ItemAddress(strip, number) orelse return true;
        const value = @intFromPtr(mn.GTMENUITEM_USERDATA(picked_item));
        if (value >= size_base and value < size_base + brush_zig.sizes.len) {
            app.brush.size = brush_zig.sizes[value - size_base];
            return true;
        }
        const which = Command.of(value) orelse return true;
        // An item with a check mark has turned itself.
        const checked = picked_item.flags & mn.CHECKED != 0;
        switch (which) {
            .grid => {
                app.view.grid = checked;
                app.whole = true;
            },
            .own_screen => app.switch_wanted = checked != app.own,
            else => return app.perform(which),
        }
        return true;
    }

    /// A command, from a menu, a button or a key. False to end.
    fn perform(app: *App, which: Command) bool {
        switch (which) {
            .new => if (app.mayLeave()) {
                if (app.askSize()) |size| {
                    if (!app.newPicture(size[0], size[1])) app.tellSize(size);
                    app.followBars();
                }
            },
            .quit => return !app.mayLeave(),
            .undo => if (app.history.undo(&app.picture, &app.kept)) |area| {
                app.changed = true;
                app.show(area);
            },
            .redo => if (app.history.redo(&app.picture, &app.kept)) |area| {
                app.changed = true;
                app.show(area);
            },
            .swap => {
                const was = app.foreground;
                app.foreground = app.background;
                app.background = was;
                app.drawColours();
            },
            .clear => {
                app.picture.fill(app.background);
                app.changedArea(app.picture.whole());
            },
            .zoom_in => app.zoomTo(app.view.nextZoom(true)),
            .zoom_out => app.zoomTo(app.view.nextZoom(false)),
            .actual_size => app.zoomTo(1),
            .grid => {
                app.view.grid = !app.view.grid;
                app.whole = true;
            },
            .round => app.brush.shape = .round,
            .square => app.brush.shape = .square,
            .smaller => app.brush = app.brush.stepped(false),
            .larger => app.brush = app.brush.stepped(true),
            .own_screen => app.switch_wanted = true,
        }
        return true;
    }

    /// A colour of the palette picked: the select button's the
    /// foreground, the menu button's the background, which leaves the
    /// palette showing the foreground.
    fn pickedColour(app: *App, place: u32) void {
        const gui = app.ui() orelse return;
        if (place >= colours.len) return;
        var button: usize = pa.PALETTE_SELECT;
        _ = app.ib.GetAttr(pa.PALETTE_Button, gui.palette, &button);
        if (button == pa.PALETTE_MENU) {
            app.background = colours[place];
            _ = app.ib.SetGadgetAttrsTagList(gui.palette, gui.window, &[_]TagItem{ .{ .tag = pa.PALETTE_Color, .data = app.foreground_index }, .{} });
        } else {
            app.foreground = colours[place];
            app.foreground_index = place;
        }
        app.drawColours();
    }

    fn keyed(app: *App, code: u32) void {
        switch (code) {
            '+', '=' => app.zoomTo(app.view.nextZoom(true)),
            '-' => app.zoomTo(app.view.nextZoom(false)),
            '[', '<' => app.brush = app.brush.stepped(false),
            ']', '>' => app.brush = app.brush.stepped(true),
            'x', 'X' => _ = app.perform(.swap),
            else => {},
        }
    }

    fn rawKeyed(app: *App, code: u32) void {
        // An eighth of the view at a time.
        const across: i32 = @intCast(@max(app.view.columns() / 8, 1));
        const down: i32 = @intCast(@max(app.view.rows() / 8, 1));
        switch (code) {
            raw_up => app.scrollBy(0, -down),
            raw_down => app.scrollBy(0, down),
            raw_left => app.scrollBy(-across, 0),
            raw_right => app.scrollBy(across, 0),
            else => {},
        }
    }

    // --- requesters -------------------------------------------------------------

    /// Whether the picture may go: unchanged, or let go of when asked.
    fn mayLeave(app: *App) bool {
        if (!app.changed) return true;
        const gui = app.ui() orelse return true;
        const easy = intuition.requesters.EasyStruct{
            .title = COMMAND_NAME,
            .text_format = app.text.get(.MSG_CHANGED),
            .gadget_format = app.text.get(.MSG_CHANGED_BUTTONS),
        };
        return app.ib.EasyRequestArgs(gui.window, &easy, null, null) == 1;
    }

    fn tell(app: *App, comptime message: Id) void {
        const gui = app.ui() orelse return;
        const easy = intuition.requesters.EasyStruct{ .title = COMMAND_NAME, .text_format = app.text.get(message), .gadget_format = app.text.get(.MSG_OK) };
        _ = app.ib.EasyRequestArgs(gui.window, &easy, null, null);
    }

    fn tellSize(app: *App, size: [2]u32) void {
        const gui = app.ui() orelse return;
        comptime sdk.exec.checkFormat(strings.builtin(.MSG_NO_PICTURE), struct { i64, i64 });
        const easy = intuition.requesters.EasyStruct{ .title = COMMAND_NAME, .text_format = app.text.get(.MSG_NO_PICTURE), .gadget_format = app.text.get(.MSG_OK) };
        const args = [_]i64{ size[0], size[1] };
        _ = app.ib.EasyRequestArgs(gui.window, &easy, null, &args);
    }

    /// The new picture's size, asked in a window of its own: null when
    /// it was closed or cancelled.
    fn askSize(app: *App) ?[2]u32 {
        const gui = app.ui() orelse return null;
        const lib = app.sys.OpenLibrary(ig.INTEGER_LIBRARY, 0) orelse return null;
        defer app.sys.CloseLibrary(lib);
        const ib = app.ib;
        const fields = [2]?*Object{ integerField(ib, ID_WIDTH, app.picture.width), integerField(ib, ID_HEIGHT, app.picture.height) };
        const answers = [2]?*Object{ textButton(ib, app.text.get(.MSG_OK), ID_OK), textButton(ib, app.text.get(.MSG_CANCEL), ID_CANCEL) };
        if (fields[0] == null or fields[1] == null or answers[0] == null or answers[1] == null) {
            for (fields ++ answers) |made| ib.DisposeObject(made);
            return null;
        }
        const row = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(answers[0]) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(answers[1]) },
            .{},
        }) orelse {
            for (fields ++ answers) |made| ib.DisposeObject(made);
            return null;
        };
        const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(fields[0]) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(.MSG_WIDTH)) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(fields[1]) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(.MSG_HEIGHT)) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(row) },
            .{},
        }) orelse {
            ib.DisposeObject(row);
            for (fields) |made| ib.DisposeObject(made);
            return null;
        };
        const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
            screenTag(gui),
            .{ .tag = wn.WA_Title, .data = @intFromPtr(app.text.get(.MSG_NEW_TITLE)) },
            .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr(SCREEN_TITLE) },
            .{ .tag = wn.WA_AutoAdjust, .data = 1 },
            .{ .tag = wn.WA_CloseGadget, .data = 1 },
            .{ .tag = wn.WA_DragBar, .data = 1 },
            .{ .tag = wn.WA_DepthGadget, .data = 1 },
            .{ .tag = wn.WA_Activate, .data = 1 },
            .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_ACTIVEWINDOW },
            .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(layout) },
            .{},
        }) orelse {
            ib.DisposeObject(layout);
            return null;
        };
        defer ib.DisposeObject(object);
        var open = wc.WmOpen{};
        if (ib.SendMessage(object, @ptrCast(&open)) == 0) return null;
        const window: *Window = @ptrFromInt(windowOf(ib, object));

        var signal: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_SigMask, object, &signal);
        var code: u32 = 0;
        var handle = wc.WmHandleInput{ .code = &code };
        while (true) {
            _ = app.sys.Wait(@truncate(signal));
            while (true) {
                const word = ib.SendMessage(object, @ptrCast(&handle));
                if (word == wc.WMHI_LASTMSG) break;
                switch (word & wc.WMHI_CLASSMASK) {
                    wc.WMHI_CLOSEWINDOW => return null,
                    // Once the window has the keyboard, the width has it.
                    wc.WMHI_ACTIVE => _ = ib.ActivateGadget(fields[0].?, window, null),
                    wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                        ID_CANCEL => return null,
                        // Return in the height is OK too; in the width it
                        // goes on to the height.
                        ID_WIDTH => _ = ib.ActivateGadget(fields[1].?, window, null),
                        ID_OK, ID_HEIGHT => return sizeOf(ib, fields),
                        else => {},
                    },
                    // Return with no field typed into is OK, Escape Cancel.
                    wc.WMHI_VANILLAKEY => switch (word & wc.WMHI_KEYMASK) {
                        '\r' => return sizeOf(ib, fields),
                        0x1B => return null,
                        else => {},
                    },
                    else => {},
                }
            }
        }
    }

    // --- the window's messages ------------------------------------------------

    /// Everything the window has to say. False to end.
    fn messages(app: *App) bool {
        const gui = app.ui() orelse return false;
        var code: u32 = 0;
        var handle = wc.WmHandleInput{ .code = &code };
        while (true) {
            const word = app.ib.SendMessage(gui.object.?, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) return true;
            var qualifier: usize = 0;
            var gadget: usize = wc.WINDOW_NOGADGET;
            _ = app.ib.GetAttr(wc.WINDOWA_Qualifier, gui.object.?, &qualifier);
            _ = app.ib.GetAttr(wc.WINDOWA_GadgetID, gui.object.?, &gadget);
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => if (app.mayLeave()) return false,
                wc.WMHI_MENUPICK => {
                    const number: u32 = @truncate(word & wc.WMHI_MENUMASK);
                    if (number != mn.MENUNULL and !app.picked(number)) return false;
                },
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    ID_VIEW => app.endStroke(),
                    ID_COLOURS => _ = app.perform(.swap),
                    ID_PALETTE => app.pickedColour(code),
                    ID_VERT, ID_HORIZ => app.followScrollers(),
                    else => |id| {
                        if (Tool.of(id)) |tool| {
                            app.chooseTool(tool);
                        } else if (Command.of(id)) |which| {
                            if (!app.perform(which)) return false;
                        }
                    },
                },
                // The pointer on the picture, or a bar moved.
                wc.WMHI_IDCMPUPDATE => switch (gadget) {
                    ID_VIEW => app.paintTo(qualifier & ie.IEQUALIFIER_REPEAT == 0),
                    ID_VERT, ID_HORIZ => app.followScrollers(),
                    else => {},
                },
                wc.WMHI_VANILLAKEY => app.keyed(@truncate(word & wc.WMHI_KEYMASK)),
                wc.WMHI_RAWKEY => app.rawKeyed(@truncate(word & wc.WMHI_KEYMASK)),
                wc.WMHI_MOUSEWHEEL => {
                    const notches: i16 = @bitCast(@as(u16, @truncate(word & 0xFFFF)));
                    const step: i32 = @intCast(@max(app.view.rows() / 10, 1));
                    const shifted = qualifier & (ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT) != 0;
                    if (shifted) app.scrollBy(@as(i32, notches) * step, 0) else app.scrollBy(0, @as(i32, notches) * step);
                },
                wc.WMHI_NEWSIZE => app.fitView(),
                else => {},
            }
            if (app.switch_wanted) return true;
        }
    }

    fn run(app: *App) void {
        while (true) {
            const gui = app.ui() orelse return;
            var signal: usize = 0;
            _ = app.ib.GetAttr(wc.WINDOWA_SigMask, gui.object.?, &signal);
            const got = app.sys.Wait(@as(u32, @truncate(signal)) | exec.SIGBREAKF_CTRL_C);
            if (got & exec.SIGBREAKF_CTRL_C != 0 and app.mayLeave()) return;
            if (!app.messages()) return;
            if (app.switch_wanted) {
                app.switch_wanted = false;
                if (!app.switchScreen()) return;
                continue;
            }
            app.flush();
        }
    }

    // --- the screens ------------------------------------------------------------

    /// The window taken down and made again on the other screen; false
    /// when it cannot be made on either.
    fn switchScreen(app: *App) bool {
        const to = !app.own;
        app.endStroke();
        if (app.gui) |*gui| gui.close(app.ib);
        app.gui = null;
        if (app.openGui(to)) {
            app.own = to;
            app.keepSettings();
            return true;
        }
        if (!app.openGui(!to)) return false;
        if (to) app.tell(.MSG_NO_OWN_SCREEN);
        return true;
    }

    /// The choice of screen written to ENV: and ENVARC:.
    fn keepSettings(app: *App) void {
        const header = "; Paint's settings: SCREEN=OWN opens a screen of its own\n";
        const text: []const u8 = if (app.own) header ++ "SCREEN=OWN\n" else header ++ "SCREEN=DESKTOP\n";
        for ([_][*:0]const u8{ ENV_FILE, ENVARC_FILE }) |path| _ = prefs.save(app.dl, path, text);
    }

    /// The window made on the desktop's screen or a screen of its own,
    /// and the picture shown in it.
    fn openGui(app: *App, own: bool) bool {
        var gui = Gui{ .own = own };
        if (!app.makeGui(&gui)) {
            gui.close(app.ib);
            return false;
        }
        app.gui = gui;
        app.own = own;
        app.drawColours();
        app.chooseTool(app.tool);
        app.fitView();
        app.flush();
        return true;
    }

    fn makeGui(app: *App, gui: *Gui) bool {
        const ib = app.ib;
        gui.screen = if (gui.own) ib.OpenScreenTagList(&[_]TagItem{
            .{ .tag = sc.SA_LikeWorkbench, .data = 1 },
            .{ .tag = sc.SA_Title, .data = @intFromPtr(SCREEN_TITLE) },
            .{},
        }) else ib.LockPubScreen(null);
        const screen = gui.screen orelse return false;
        const info = ib.GetScreenDrawInfo(screen);
        gui.draw_info = info;
        gui.ground = info.pens[sc.BACKGROUNDPEN];

        // The pictures of the tools and the commands.
        for (tools, 0..) |entry, place| gui.images[place] = glyph(ib, entry.glyph);
        for (buttons, tools.len..) |entry, place| gui.images[place] = glyph(ib, entry.glyph);

        // The gadgets; each one the program's to dispose of until a layout
        // takes it.
        var made: [tools.len + buttons.len + 4]?*Object = @splat(null);
        for (tools, 0..) |entry, place| made[place] = toolButton(ib, entry.tool.id(), gui.images[place], app.text.get(entry.hint), tb.TBKIND_TOGGLE);
        for (buttons, tools.len..) |entry, place| made[place] = toolButton(ib, entry.which.id(), gui.images[place], app.text.get(entry.hint), tb.TBKIND_PUSH);
        const others = tools.len + buttons.len;
        made[others] = ib.NewObjectTagList(null, cv.CANVAS_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_VIEW },
            .{ .tag = gc.GA_MenuButton, .data = 1 },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
            .{},
        });
        made[others + 1] = ib.NewObjectTagList(null, cv.CANVAS_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_COLOURS },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = cv.CANVAS_Width, .data = 30 },
            .{ .tag = cv.CANVAS_Height, .data = 30 },
            .{},
        });
        made[others + 2] = ib.NewObjectTagList(null, pa.PALETTE_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_PALETTE },
            .{ .tag = gc.GA_MenuButton, .data = 1 },
            .{ .tag = pa.PALETTE_ColorTable, .data = @intFromPtr(&colours) },
            .{ .tag = pa.PALETTE_NumColors, .data = colours.len },
            .{ .tag = pa.PALETTE_Color, .data = app.foreground_index },
            .{},
        });
        made[others + 3] = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_STATUS },
            .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&app.status) },
            .{ .tag = tx.TEXT_RoomFor, .data = @intFromPtr("16384 x 16384   16:1   brush 32   at -00000, -00000") },
            .{},
        });
        for (made) |one| if (one == null) {
            for (made) |gadget| ib.DisposeObject(gadget);
            return false;
        };
        for (0..tools.len) |place| gui.tool_buttons[place] = made[place].?;
        for (0..buttons.len) |place| gui.command_buttons[place] = made[tools.len + place].?;
        gui.view = made[others].?;
        gui.colours = made[others + 1].?;
        gui.palette = made[others + 2].?;
        gui.status = made[others + 3].?;

        // The tools two to a row; the picture and the tools side by side;
        // the colours and the status under them.
        var tool_tags: [tools.len + buttons.len + 4]TagItem = undefined;
        tool_tags[0] = .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_GRID };
        tool_tags[1] = .{ .tag = lg.LAYOUTA_Columns, .data = 2 };
        tool_tags[2] = .{ .tag = lg.LAYOUTA_Spacing, .data = 2 };
        for (0..others) |place| tool_tags[3 + place] = .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(made[place]) };
        tool_tags[3 + others] = .{};
        const tool_layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &tool_tags) orelse {
            for (made) |gadget| ib.DisposeObject(gadget);
            return false;
        };
        const upper = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 4 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(gui.view) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 1 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(tool_layout) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{ .tag = lg.CHILDA_Align, .data = lg.CALIGN_TOP },
            .{},
        }) orelse {
            ib.DisposeObject(tool_layout);
            for (made[others..]) |gadget| ib.DisposeObject(gadget);
            return false;
        };
        const lower = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(gui.colours) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(gui.palette) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 1 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(gui.status) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{},
        }) orelse {
            ib.DisposeObject(upper);
            for (made[others + 1 ..]) |gadget| ib.DisposeObject(gadget);
            return false;
        };
        const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_Margin, .data = 2 },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 4 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(upper) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 1 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(lower) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{},
        }) orelse {
            ib.DisposeObject(upper);
            ib.DisposeObject(lower);
            return false;
        };

        // On its own screen the window fills it under the bar, without a
        // title or the gadgets that move it - not a backdrop, which has no
        // sizing gadget and so no room for the bars in its borders; on the
        // desktop's it takes most of the screen.
        var screen_width: usize = 0;
        var screen_height: usize = 0;
        var bar_height: usize = 0;
        ib.GetScreenAttrs(screen, &[_]TagItem{
            .{ .tag = sc.SA_Width, .data = @intFromPtr(&screen_width) },
            .{ .tag = sc.SA_Height, .data = @intFromPtr(&screen_height) },
            .{ .tag = sc.SA_BarHeight, .data = @intFromPtr(&bar_height) },
            .{},
        });
        const top = bar_height + 1;
        const place_tags = if (gui.own) [_]TagItem{
            .{ .tag = wn.WA_Left, .data = 0 },
            .{ .tag = wn.WA_Top, .data = top },
            .{ .tag = wn.WA_Width, .data = screen_width },
            .{ .tag = wn.WA_Height, .data = screen_height -| top },
            .{ .tag = sdk.utility.TAG_IGNORE, .data = 0 },
            .{ .tag = sdk.utility.TAG_IGNORE, .data = 0 },
            .{ .tag = sdk.utility.TAG_IGNORE, .data = 0 },
            .{ .tag = sdk.utility.TAG_IGNORE, .data = 0 },
            .{ .tag = sdk.utility.TAG_IGNORE, .data = 0 },
        } else [_]TagItem{
            .{ .tag = wn.WA_Width, .data = screen_width * 7 / 8 },
            .{ .tag = wn.WA_Height, .data = (screen_height -| top) * 7 / 8 },
            .{ .tag = wn.WA_Left, .data = screen_width / 16 },
            .{ .tag = wn.WA_Top, .data = top + (screen_height -| top) / 16 },
            .{ .tag = wn.WA_Title, .data = @intFromPtr(COMMAND_NAME) },
            .{ .tag = wn.WA_CloseGadget, .data = 1 },
            .{ .tag = wn.WA_DragBar, .data = 1 },
            .{ .tag = wn.WA_DepthGadget, .data = 1 },
            .{ .tag = wn.WA_AutoAdjust, .data = 1 },
        };
        const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
            screenTag(gui),
            .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr(SCREEN_TITLE) },
            .{ .tag = wn.WA_SizeGadget, .data = 1 },
            .{ .tag = wn.WA_Activate, .data = 1 },
            .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_IDCMPUPDATE | wn.IDCMP_NEWSIZE | wn.IDCMP_RAWKEY | wn.IDCMP_MOUSEWHEEL },
            .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(layout) },
            // The bars tell the window as they move, and as they are let go.
            .{ .tag = wc.WINDOWA_VertScroller, .data = @intFromPtr(&[_]TagItem{
                .{ .tag = gc.GA_ID, .data = ID_VERT },
                .{ .tag = gc.GA_RelVerify, .data = 1 },
                .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
                .{},
            }) },
            .{ .tag = wc.WINDOWA_HorizScroller, .data = @intFromPtr(&[_]TagItem{
                .{ .tag = gc.GA_ID, .data = ID_HORIZ },
                .{ .tag = gc.GA_RelVerify, .data = 1 },
                .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
                .{},
            }) },
            .{ .tag = sdk.utility.TAG_MORE, .data = @intFromPtr(&place_tags) },
        }) orelse {
            ib.DisposeObject(layout);
            return false;
        };
        gui.object = object;
        var open = wc.WmOpen{};
        if (ib.SendMessage(object, @ptrCast(&open)) == 0) return false;
        gui.window = @ptrFromInt(windowOf(ib, object));
        var value: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_VertScroller, object, &value);
        gui.vert = @ptrFromInt(value);
        value = 0;
        _ = ib.GetAttr(wc.WINDOWA_HorizScroller, object, &value);
        gui.horiz = @ptrFromInt(value);
        _ = ib.GetAttr(cv.CANVAS_RastPort, gui.colours, &value);
        gui.colours_rp = @ptrFromInt(value);

        // The menus; without them Paint still paints.
        var table: [menus.len]mn.NewMenu = undefined;
        for (menus, &table) |entry, *one| {
            one.* = entry.menu;
            if (entry.text) |id| one.label = app.text.get(id);
        }
        if (ib.CreateMenusA(&table, null)) |strip| {
            if (ib.LayoutMenusA(strip, screen, null) and ib.SetMenuStrip(gui.window, strip)) {
                gui.strip = strip;
            } else ib.FreeMenus(strip);
        }
        return true;
    }
};

/// The tag that puts a window on the GUI's screen.
fn screenTag(gui: *const Gui) TagItem {
    return .{ .tag = if (gui.own) wn.WA_CustomScreen else wn.WA_PubScreen, .data = @intFromPtr(gui.screen) };
}

/// The width and the height the new picture's fields say.
fn sizeOf(ib: *IntuitionBase, fields: [2]?*Object) [2]u32 {
    var width: usize = 0;
    var height: usize = 0;
    _ = ib.GetAttr(ig.INTEGER_Number, fields[0].?, &width);
    _ = ib.GetAttr(ig.INTEGER_Number, fields[1].?, &height);
    return .{ @truncate(width), @truncate(height) };
}

fn windowOf(ib: *IntuitionBase, object: *Object) usize {
    var window: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, object, &window);
    return window;
}

fn glyph(ib: *IntuitionBase, which: u32) ?*Object {
    return ib.NewObjectTagList(null, command.COMMAND_CLASS, &[_]TagItem{ .{ .tag = command.COMMAND_Glyph, .data = which }, .{} });
}

fn toolButton(ib: *IntuitionBase, id: u32, image: ?*Object, hint: [*:0]const u8, kind: u32) ?*Object {
    return ib.NewObjectTagList(null, tb.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = if (image != null) tb.TOOLBUTTON_Image else sdk.utility.TAG_IGNORE, .data = @intFromPtr(image) },
        .{ .tag = gc.GA_Text, .data = @intFromPtr(hint) },
        .{ .tag = tb.TOOLBUTTON_Size, .data = tb.TBSIZE_SMALL },
        .{ .tag = tb.TOOLBUTTON_Kind, .data = kind },
        .{ .tag = tb.TOOLBUTTON_Hint, .data = @intFromPtr(hint) },
        .{},
    });
}

fn textButton(ib: *IntuitionBase, label: [*:0]const u8, id: u32) ?*Object {
    return ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr(label) },
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    });
}

fn integerField(ib: *IntuitionBase, id: u32, value: u32) ?*Object {
    return ib.NewObjectTagList(null, ig.INTEGER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = ig.INTEGER_Min, .data = 1 },
        .{ .tag = ig.INTEGER_Max, .data = max_side },
        .{ .tag = ig.INTEGER_Number, .data = value },
        .{},
    });
}

/// A check mark's item set from what Paint is doing.
fn syncItem(state: MenuState, menu_item: *intuition.MenuItem) void {
    const value = @intFromPtr(mn.GTMENUITEM_USERDATA(menu_item));
    const on: ?bool = if (value >= size_base and value < size_base + brush_zig.sizes.len)
        brush_zig.sizes[value - size_base] == state.size
    else if (Command.of(value)) |which| switch (which) {
        .round => state.round,
        .square => !state.round,
        .grid => state.grid,
        .own_screen => state.own,
        .undo, .redo => {
            const can = if (which == .undo) state.can_undo else state.can_redo;
            if (can) menu_item.flags |= mn.ITEMENABLED else menu_item.flags &= ~mn.ITEMENABLED;
            return;
        },
        else => null,
    } else null;
    const checked = on orelse return;
    if (checked) menu_item.flags |= mn.CHECKED else menu_item.flags &= ~mn.CHECKED;
}

fn sameState(a: MenuState, b: MenuState) bool {
    return a.round == b.round and a.size == b.size and a.grid == b.grid and a.own == b.own and a.can_undo == b.can_undo and a.can_redo == b.can_redo;
}

/// Whether the text made and the C string are the same.
fn same(made: []const u8, shown: [*:0]const u8) bool {
    for (made, 0..) |char, at| {
        if (shown[at] != char) return false;
    }
    return shown[made.len] == 0;
}

/// Where the settings came from: the icon Paint was started from, or the
/// command line.
fn screenWanted(sys: *ExecBase, dl: *DosBase, ub: ?*UtilityBase) ?bool {
    var count: u32 = 0;
    const files = dl.GetArgList(&count);
    if (files != null and count > 0) {
        const lib = sys.OpenLibrary(icon.ICONNAME, 1) orelse return keptScreen(sys, dl, ub);
        defer sys.CloseLibrary(lib);
        const icon_base: *IconBase = @ptrCast(lib);
        const old = dl.CurrentDir(files.?[0].lock);
        defer _ = dl.CurrentDir(old);
        const object = icon_base.GetDiskObject(files.?[0].name) orelse return keptScreen(sys, dl, ub);
        defer icon_base.FreeDiskObject(object);
        const value = icon_base.FindToolType(object.tool_types, "SCREEN") orelse return keptScreen(sys, dl, ub);
        return ownOrDesktop(value) orelse keptScreen(sys, dl, ub);
    }
    return null;
}

/// OWN or DESKTOP, any case.
fn ownOrDesktop(value: [*:0]const u8) ?bool {
    var length: usize = 0;
    while (value[length] != 0) length += 1;
    if (prefs.style.same(value[0..length], "OWN")) return true;
    if (prefs.style.same(value[0..length], "DESKTOP")) return false;
    return null;
}

/// The screen chosen the last time, from `ENV:Paint.prefs`; the desktop's
/// without one.
fn keptScreen(sys: *ExecBase, dl: *DosBase, ub: ?*UtilityBase) bool {
    const utility_base = ub orelse return false;
    const text = prefs.loadWhole(sys, dl, ENV_FILE) orelse return false;
    defer sys.FreeVec(text.ptr);
    const line = prefs.firstLine(text) orelse return false;
    var pairs = prefs.Pairs.init(utility_base, line);
    while (pairs.next() catch null) |pair| {
        if (!prefs.style.same(pair.key, "SCREEN")) continue;
        if (prefs.style.same(pair.value, "OWN")) return true;
        return false;
    }
    return false;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    var text = Text.open(sys);
    defer text.close();

    // Opened until the end: what the window is made of.
    const names = [_][*:0]const u8{ intuition.INTUITIONNAME, graphics.GRAPHICSNAME, cv.CANVAS_LIBRARY, pa.PALETTE_LIBRARY, tb.TOOLBUTTON_LIBRARY, tx.TEXT_LIBRARY, command.COMMAND_LIBRARY };
    var libs: [names.len]?*exec.Library = @splat(null);
    defer for (libs) |lib| {
        if (lib) |opened| sys.CloseLibrary(opened);
    };
    for (names, &libs) |name, *lib| {
        lib.* = sys.OpenLibrary(name, 0) orelse {
            _ = text.printf(dl, .MSG_NOLIBRARY, .{name});
            return dos.RETURN_FAIL;
        };
    }
    const utility_lib = sys.OpenLibrary(sdk.utility.UTILITYNAME, 0);
    defer if (utility_lib) |lib| sys.CloseLibrary(lib);
    const ub: ?*UtilityBase = @ptrCast(utility_lib);

    // The screen: SCREEN= from the shell or the icon, or the last choice.
    var own = screenWanted(sys, dl, ub);
    if (own == null) {
        var argv: [1]usize = @splat(0);
        const rda = dl.ReadArgs(template, &argv, null) orelse {
            _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
            return dos.RETURN_ERROR;
        };
        defer dl.FreeArgs(rda);
        if (rdargs.string(argv[0])) |value| {
            own = ownOrDesktop(value) orelse {
                _ = text.printf(dl, .MSG_BADSCREEN, .{});
                return dos.RETURN_ERROR;
            };
        } else own = keptScreen(sys, dl, ub);
    }

    var app = App{
        .sys = sys,
        .dl = dl,
        .ib = @ptrCast(libs[0]),
        .gb = @ptrCast(libs[1]),
        .ub = ub,
        .text = &text,
    };
    defer {
        if (app.gui) |*gui| gui.close(app.ib);
        if (app.band) |band| sys.FreeVec(band);
        app.freePicture();
    }

    // A picture as large as the screen to begin with.
    const desktop = app.ib.LockPubScreen(null) orelse {
        _ = text.printf(dl, .MSG_NOSCREEN, .{});
        return dos.RETURN_FAIL;
    };
    var width: usize = 640;
    var height: usize = 480;
    app.ib.GetScreenAttrs(desktop, &[_]TagItem{
        .{ .tag = sc.SA_Width, .data = @intFromPtr(&width) },
        .{ .tag = sc.SA_Height, .data = @intFromPtr(&height) },
        .{},
    });
    app.ib.UnlockPubScreen(null, desktop);
    if (!app.newPicture(@intCast(@max(width, 1)), @intCast(@max(height, 1))) and !app.newPicture(320, 200)) {
        _ = text.printf(dl, .MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }

    if (!app.openGui(own.?)) {
        if (!own.? or !app.openGui(false)) {
            _ = text.printf(dl, .MSG_NOMEMORY, .{});
            return dos.RETURN_FAIL;
        }
        app.tell(.MSG_NO_OWN_SCREEN);
    }
    app.run();
    return dos.RETURN_OK;
}
