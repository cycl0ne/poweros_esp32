// SPDX-License-Identifier: MIT
//! Paint: pictures painted with the pointer. Built against the SDK only.
//!
//!   Paint [FILE] [SCREEN=OWN|DESKTOP]
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
//! open anywhere else. The brush is round or square and 1 to 32 pixels
//! (brush.zig), chosen in the Brush menu or with `[` and `]` - or `<`
//! and `>`, one key on a German keyboard - or an own brush (below).
//! While the pointer is over the picture and no button is down, the
//! brush is shown where it would go down: the window reports the mouse,
//! and the view lays the brush over the rows it makes, never into the
//! picture. The tools, down the right and in the Tools menu, each with a
//! key of its own:
//!
//!   - freehand (`p`), a line along the way the pointer goes, and dotted
//!     freehand (`.`), the brush put down wherever the pointer is told to
//!     be; the airbrush (`a`) sprays round the pointer, and keeps
//!     spraying where it is held - the canvas tells every tick then
//!     (`CANVAS_Ticks`);
//!   - line (`l`), rectangle (`r`) and ellipse (`e`), pulled from where
//!     the button goes down to where it is let go; curve (`c`), a line
//!     pulled out and then, with a second press, bent through the
//!     pointer; polygon (`n`), a corner at each release, closed by a
//!     release on its first corner or on its last again, or by Return.
//!     Rectangles, ellipses and polygons are outlines in the brush, or
//!     filled (`F`, the button under the tools, or Tools' Filled
//!     Shapes). A shape is drawn into the picture over what `kept` holds,
//!     drawn again from there as it changes, and kept for undoing when it
//!     is done (shapes.zig); Escape puts it away, Undo too;
//!   - fill (`f`), the area of one colour pressed on (fill.zig);
//!   - pick colour (`i`), the colour under the pointer made the
//!     foreground, or the background with the menu button, and then the
//!     tool before it again;
//!   - text (`t`): a click asks for the text and its font (getfont.gadget,
//!     the screen's font to begin with) and puts it down with its top
//!     left there, drawn by graphics.library into a surface over the
//!     picture's own pixels;
//!   - cut brush (`b`): a frame of dashes pulled over the picture, and
//!     what it holds made the own brush - with the menu button cut out,
//!     the background colour left there - and then the tool before it
//!     again, or dotted freehand when that one puts no brush down.
//!
//! **The own brush** is a picture of its own, up to 1024 pixels a side:
//! cut from the picture, the background colour's pixels left out, or
//! opened from any picture file. It goes down in its own colours or, in
//! One Colour or with the menu button, as its shape in the stroke's
//! colour. Brush's items flip it (`h`, `v`) and turn it a quarter to the
//! right (`z`); Smaller and Larger halve and double it; Save Brush...
//! writes it as a PNG, or an ILBM for a name ending as one does. Round,
//! Square or a size go back to the built-in brushes, Own Brush to it.
//!
//! **The colours.** palette.gadget shows the picture's 32 colours: the
//! select button picks the foreground, the menu button the background
//! (`PALETTE_Button`); the two are shown beside it, the foreground in
//! front, and a click there swaps them, as `x` does.
//!
//! **Files** go through paintio.library, which is Paint's own and lies in
//! its drawer: it is opened by its path, `PROGDIR:Libs/paintio.library`,
//! the first time a file is opened or saved, and closed at the end. Open...
//! (and FILE at the start) reads a project or any picture datatypes
//! reads, and takes its palette when it has one. Save As...
//! writes what the name ends in: `.png` a PNG, `.iff`, `.ilbm` or `.lbm`
//! an ILBM, anything else a project (`FORM PNTG`), which keeps the
//! palette too; Save writes the file again in its form, or asks for a
//! name when the picture came from a format Paint does not write. The
//! window's title, or the screen's bar on a screen of its own, names the
//! file, with a `*` before it while it has changes.
//!
//! **Undo.** Every stroke, clear and so on is kept for undoing and redoing
//! (history.zig), as far back as a block of three pictures' worth - or half
//! the memory free, when that is less - reaches; the oldest go first.
//!
//! The menus, with their keys (pressed with the right command key):
//!
//!   Project   New... (N), Open... (O), Save (S), Save As... (A), Quit (Q)
//!   Edit      Undo (Z), Redo (Y), Swap Colours, Clear (K)
//!   Tools     the tools, Filled Shapes
//!   View      Zoom In (+), Zoom Out (-), Actual Size (1), Grid (G)
//!   Brush     Round, Square, Own Brush, Size, Smaller ([), Larger (]),
//!             Own Colours, One Colour, Flip Horizontally, Flip
//!             Vertically, Turn Right, Open Brush..., Save Brush...
//!   Settings  Own Screen
//!
//! Without a menu key: `+` and `-` zoom, `[` and `]` (or `<` and `>`)
//! size the brush, `h`, `v` and `z` flip and turn an own brush, `x` swaps
//! the colours, the tools' letters choose them,
//! Return ends a shape and Escape puts it away, the cursor keys scroll.
//! A picture that has changed is not let go - by New, Open, Quit, Ctrl-C
//! or the close gadget - before a requester asks whether to save it.
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
const sg = sdk.gadgets.string;
const gfo = sdk.gadgets.getfont;
const command = sdk.images.command;
const prefs = sdk.prefs;
const paintio = sdk.paintio;
const asl = sdk.asl;
const rdargs = dos.rdargs;
const PixelFormat = sdk.rtg.PixelFormat;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const IconBase = sdk.interface.icon.IconBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const PaintIOBase = sdk.interface.paintio.PaintIOBase;
const AslBase = sdk.interface.asl.AslBase;
const Object = intuition.Object;
const Window = intuition.Window;
const Screen = intuition.Screen;
const RastPort = graphics.RastPort;
const TagItem = sdk.utility.TagItem;

const picture_zig = @import("picture.zig");
const brush_zig = @import("brush.zig");
const history_zig = @import("history.zig");
const view_zig = @import("view.zig");
const shapes = @import("shapes.zig");
const fill_zig = @import("fill.zig");
const Picture = picture_zig.Picture;
const Pixel = picture_zig.Pixel;
const Area = picture_zig.Area;
const Brush = brush_zig.Brush;
const History = history_zig.History;
const View = view_zig.View;
const Point = shapes.Point;

pub const COMMAND_NAME = "Paint";
const VERSION = "1.3";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (19.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
/// What the screen's bar says while the window is active, and the own
/// screen's title.
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const template = "FILE,SCREEN/K";
const arg_file = 0;
const arg_screen = 1;
/// The room for a file's path.
const path_size = 256;
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
// The text's window.
const ID_TEXT = 24;
const ID_FONT = 25;

/// The seeds a fill starts with room for; it makes more as it needs them.
const first_seeds = 4096;
/// How far from a polygon's first corner, in the view's pixels, a release
/// closes it.
const close_reach = 4;

const raw_up = 0x4C;
const raw_down = 0x4D;
const raw_right = 0x4E;
const raw_left = 0x4F;

/// The painting tools; a tool's button has `id()` as its `GA_ID`.
const Tool = enum(u32) {
    freehand,
    dots,
    line,
    curve,
    rectangle,
    ellipse,
    polygon,
    fill,
    airbrush,
    pick,
    text,
    grab,

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
    filled,
    open,
    save,
    save_as,
    own_brush,
    own_colours,
    one_colour,
    flip_across,
    flip_down,
    turn,
    open_brush,
    save_brush,

    fn id(which: Command) u32 {
        return @intFromEnum(which);
    }

    fn of(value: usize) ?Command {
        if (value < @intFromEnum(Command.new) or value > @intFromEnum(Command.save_brush)) return null;
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
/// In the order of `Tool`, which is the Tools menu's order too.
const ToolEntry = struct { tool: Tool, glyph: u32, hint: Id, label: Id };
const tools = [_]ToolEntry{
    .{ .tool = .freehand, .glyph = command.CMD_PENCIL, .hint = .MSG_TOOL_FREEHAND, .label = .MSG_MENU_FREEHAND },
    .{ .tool = .dots, .glyph = command.CMD_BRUSH, .hint = .MSG_TOOL_DOTS, .label = .MSG_MENU_DOTS },
    .{ .tool = .line, .glyph = command.CMD_LINE, .hint = .MSG_TOOL_LINE, .label = .MSG_MENU_LINE },
    .{ .tool = .curve, .glyph = command.CMD_CURVE, .hint = .MSG_TOOL_CURVE, .label = .MSG_MENU_CURVE },
    .{ .tool = .rectangle, .glyph = command.CMD_RECTANGLE, .hint = .MSG_TOOL_RECTANGLE, .label = .MSG_MENU_RECTANGLE },
    .{ .tool = .ellipse, .glyph = command.CMD_ELLIPSE, .hint = .MSG_TOOL_ELLIPSE, .label = .MSG_MENU_ELLIPSE },
    .{ .tool = .polygon, .glyph = command.CMD_POLYGON, .hint = .MSG_TOOL_POLYGON, .label = .MSG_MENU_POLYGON },
    .{ .tool = .fill, .glyph = command.CMD_FLOOD_FILL, .hint = .MSG_TOOL_FILL, .label = .MSG_MENU_FILL },
    .{ .tool = .airbrush, .glyph = command.CMD_AIRBRUSH, .hint = .MSG_TOOL_AIRBRUSH, .label = .MSG_MENU_AIRBRUSH },
    .{ .tool = .pick, .glyph = command.CMD_PICK_COLOUR, .hint = .MSG_TOOL_PICK, .label = .MSG_MENU_PICK },
    .{ .tool = .text, .glyph = command.CMD_TEXT, .hint = .MSG_TOOL_TEXT, .label = .MSG_MENU_TEXT },
    .{ .tool = .grab, .glyph = command.CMD_GRAB_BRUSH, .hint = .MSG_TOOL_GRAB, .label = .MSG_MENU_GRAB },
};
comptime {
    for (tools, 0..) |entry, place| {
        if (@intFromEnum(entry.tool) != place) @compileError("the tools in Tool's order");
    }
}
const ButtonEntry = struct { which: Command, glyph: u32, hint: Id, kind: u32 = tb.TBKIND_PUSH };
const buttons = [_]ButtonEntry{
    .{ .which = .filled, .glyph = command.CMD_FILLED, .hint = .MSG_FILLED_HINT, .kind = tb.TBKIND_TOGGLE },
    .{ .which = .undo, .glyph = command.CMD_UNDO, .hint = .MSG_UNDO_HINT },
    .{ .which = .redo, .glyph = command.CMD_REDO, .hint = .MSG_REDO_HINT },
    .{ .which = .zoom_in, .glyph = command.CMD_ZOOM_IN, .hint = .MSG_ZOOM_IN_HINT },
    .{ .which = .zoom_out, .glyph = command.CMD_ZOOM_OUT, .hint = .MSG_ZOOM_OUT_HINT },
};
const filled_button = 0;
const undo_button = 1;
const redo_button = 2;

/// The keys that choose a tool.
const ToolKey = struct { key: u32, tool: Tool };
const tool_keys = [_]ToolKey{
    .{ .key = 'p', .tool = .freehand },
    .{ .key = '.', .tool = .dots },
    .{ .key = 'l', .tool = .line },
    .{ .key = 'c', .tool = .curve },
    .{ .key = 'r', .tool = .rectangle },
    .{ .key = 'e', .tool = .ellipse },
    .{ .key = 'n', .tool = .polygon },
    .{ .key = 'f', .tool = .fill },
    .{ .key = 'a', .tool = .airbrush },
    .{ .key = 'i', .tool = .pick },
    .{ .key = 't', .tool = .text },
    .{ .key = 'b', .tool = .grab },
};

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

/// A tool's item: one of the Tools menu's first items, each ruling the
/// others out.
fn toolItem(comptime entry: ToolEntry) MenuEntry {
    const all: u32 = (1 << tools.len) - 1;
    const place = @intFromEnum(entry.tool);
    return .{ .menu = .{
        .type = mn.NM_ITEM,
        .label = strings.builtin(entry.label),
        .flags = mn.CHECKIT,
        .mutual_exclude = all & ~@as(u32, 1 << place),
        .user_data = @ptrFromInt(entry.tool.id()),
    }, .text = entry.label };
}

fn toolItems() [tools.len]MenuEntry {
    var made: [tools.len]MenuEntry = undefined;
    inline for (tools, 0..) |entry, place| made[place] = toolItem(entry);
    return made;
}

const bar = MenuEntry{ .menu = .{ .type = mn.NM_ITEM, .label = mn.NM_BARLABEL } };

const menus = [_]MenuEntry{
    menuTitle(.MSG_MENU_PROJECT),
    item(.MSG_MENU_NEW, "N", .new),
    item(.MSG_MENU_OPEN, "O", .open),
    bar,
    item(.MSG_MENU_SAVE, "S", .save),
    item(.MSG_MENU_SAVE_AS, "A", .save_as),
    bar,
    item(.MSG_MENU_QUIT, "Q", .quit),
    menuTitle(.MSG_MENU_EDIT),
    item(.MSG_MENU_UNDO, "Z", .undo),
    item(.MSG_MENU_REDO, "Y", .redo),
    bar,
    item(.MSG_MENU_SWAP, null, .swap),
    item(.MSG_MENU_CLEAR, "K", .clear),
    menuTitle(.MSG_MENU_TOOLS),
} ++ toolItems() ++ [_]MenuEntry{
    bar,
    toggleItem(.MSG_MENU_FILLED, null, .filled),
    menuTitle(.MSG_MENU_VIEW),
    item(.MSG_MENU_ZOOM_IN, "+", .zoom_in),
    item(.MSG_MENU_ZOOM_OUT, "-", .zoom_out),
    item(.MSG_MENU_ACTUAL_SIZE, "1", .actual_size),
    bar,
    toggleItem(.MSG_MENU_GRID, "G", .grid),
    menuTitle(.MSG_MENU_BRUSH),
    // Round, Square and Own Brush, the first three, rule each other out;
    // so do the two ways an own brush goes down, the ninth and tenth.
    choiceItem(.MSG_MENU_ROUND, .round, 1 << 1 | 1 << 2),
    choiceItem(.MSG_MENU_SQUARE, .square, 1 << 0 | 1 << 2),
    choiceItem(.MSG_MENU_OWN_BRUSH, .own_brush, 1 << 0 | 1 << 1),
    bar,
    .{ .menu = .{ .type = mn.NM_ITEM, .label = strings.builtin(.MSG_MENU_SIZE) }, .text = .MSG_MENU_SIZE },
} ++ sizeItems() ++ [_]MenuEntry{
    item(.MSG_MENU_SMALLER, "[", .smaller),
    item(.MSG_MENU_LARGER, "]", .larger),
    bar,
    choiceItem(.MSG_MENU_OWN_COLOURS, .own_colours, 1 << 9),
    choiceItem(.MSG_MENU_ONE_COLOUR, .one_colour, 1 << 8),
    bar,
    item(.MSG_MENU_FLIP_ACROSS, null, .flip_across),
    item(.MSG_MENU_FLIP_DOWN, null, .flip_down),
    item(.MSG_MENU_TURN, null, .turn),
    bar,
    item(.MSG_MENU_OPEN_BRUSH, null, .open_brush),
    item(.MSG_MENU_SAVE_BRUSH, null, .save_brush),
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
    tool: Tool,
    filled: bool,
    round: bool,
    size: u32,
    /// The own brush is in use; there is one; it goes down in one colour.
    own_brush: bool,
    has_own: bool,
    one_colour: bool,
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
    shown_filled: ?bool = null,
    /// Whether the title shown has the mark of a change; null before the
    /// first, and when the file's name has changed.
    shown_changed: ?bool = null,

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
    /// Made with the menu button: an own brush goes down in the colour.
    menu: bool = false,
    last: ?[2]i32 = null,
    changed: Area = Area.none,
};

/// The brush as it was shown under the pointer: where, in which colour,
/// and which brush - by its settings and its changes.
const GhostMark = struct {
    area: Area = .{},
    colour: Pixel = 0,
    shape: brush_zig.Shape = .round,
    size: u32 = 0,
    own: bool = false,
    mode: brush_zig.Mode = .own_colours,
    changes: u32 = 0,

    fn same(mark: GhostMark, other: GhostMark) bool {
        return mark.area.min_x == other.area.min_x and mark.area.min_y == other.area.min_y and
            mark.area.max_x == other.area.max_x and mark.area.max_y == other.area.max_y and
            mark.colour == other.colour and mark.shape == other.shape and mark.size == other.size and
            mark.own == other.own and mark.mode == other.mode and mark.changes == other.changes;
    }
};

/// A shape being drawn: drawn into the picture over what `kept` holds,
/// and drawn again from there each time it changes, until it is ended -
/// kept for undoing - or put away.
const Drawing = struct {
    tool: Tool,
    colour: Pixel,
    /// Made with the menu button.
    menu: bool = false,
    /// Its corners: a line's, a rectangle's and an ellipse's two, a
    /// curve's two ends and its bend, a polygon's as they are put down.
    points: [shapes.max_points]Point = undefined,
    count: usize = 0,
    /// A curve's line is down and waits to be bent.
    bending: bool = false,
    /// A polygon is closed: drawn whole, filled when that is wanted.
    closed: bool = false,
    /// What it covers in the picture now.
    shown: Area = Area.none,
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
    drawing: ?Drawing = null,
    /// The button is down on the picture.
    pressing: bool = false,
    /// Shapes drawn filled.
    filled: bool = false,
    /// The tool the colour picker goes back to.
    before_pick: Tool = .freehand,
    /// The tool cutting a brush goes back to: one that puts the brush
    /// down.
    before_grab: Tool = .dots,
    /// The own brush - cut from the picture or loaded - and its memory,
    /// AllocVec's; null before the first. `brush.own` points here while
    /// it is in use.
    own_brush: Picture = undefined,
    own_memory: ?*anyopaque = null,
    /// Counts the changes to the own brush's pixels, which the brush
    /// shown under the pointer follows.
    brush_changes: u32 = 0,
    /// The file the own brush was last opened from or saved to.
    brush_path: [path_size:0]u8 = @splat(0),
    /// The picture pixel under the pointer while it is over the view and
    /// no button is down; null otherwise.
    hover: ?Point = null,
    /// The brush as it is shown under the pointer, to tell when it must
    /// be drawn again.
    ghost_shown: GhostMark = .{},
    random: brush_zig.Random = .{},
    /// The text tool's last text and its font.
    typed: [256:0]u8 = @splat(0),
    font_name: [108:0]u8 = @splat(0),
    font_size: u32 = 24,
    /// Where the pointer was told to be while painting, for the status.
    at: ?[2]i32 = null,
    /// The picture's colours, which the palette shows: a file's own when
    /// it had some.
    palette: [colours.len]Pixel = colours,

    /// The file the picture is, empty for a new one; and whether Save
    /// writes it again as it is - false for a picture from a format
    /// Paint does not write.
    path: [path_size:0]u8 = @splat(0),
    writes_back: bool = false,
    /// paintio.library and asl.library, opened the first time a file is
    /// opened or saved.
    pio_lib: ?*exec.Library = null,
    asl_lib: ?*exec.Library = null,
    /// What the window or the screen's bar says: the file's name.
    title: [path_size + 16:0]u8 = @splat(0),

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
        const first = app.sys.AllocVec(Picture.bytesFor(width, height), exec.MEMF_ANY) orelse return false;
        var made = Picture{ .pixels = @ptrCast(@alignCast(first)), .width = width, .height = height };
        made.fill(app.background);
        if (!app.takePicture(first, width, height)) {
            app.sys.FreeVec(first);
            return false;
        }
        return true;
    }

    /// `first`, a picture's pixels of that size from AllocVec, made the
    /// picture, with the memory beside it to keep and undo with, and the
    /// history emptied. False when there is no memory for those: the old
    /// picture stays, and `first` is still the caller's.
    fn takePicture(app: *App, first: *anyopaque, width: u32, height: u32) bool {
        const bytes = Picture.bytesFor(width, height);
        const sys = app.sys;
        const second = sys.AllocVec(bytes, exec.MEMF_ANY) orelse return false;
        // Three pictures' worth to undo with, or half of the largest block
        // free when that is less.
        var room = @min(3 * bytes, sys.AvailMem(exec.MEMF_ANY | exec.MEMF_LARGEST) / 2) & ~@as(usize, 3);
        const third = while (room >= least_history) : (room = (room / 2) & ~@as(usize, 3)) {
            if (sys.AllocVec(room, exec.MEMF_ANY)) |made| break made;
        } else {
            sys.FreeVec(second);
            return false;
        };
        app.freePicture();
        app.memory = .{ first, second, third };
        app.picture = .{ .pixels = @ptrCast(@alignCast(first)), .width = width, .height = height };
        app.kept = .{ .pixels = @ptrCast(@alignCast(second)), .width = width, .height = height };
        app.history = .{ .memory = @ptrCast(@alignCast(third)), .size = room };
        app.kept.copyArea(&app.picture, app.picture.whole());
        app.changed = false;
        app.stroke = null;
        app.drawing = null;
        app.view.left = 0;
        app.view.top = 0;
        app.view.fit(width, height);
        app.whole = true;
        return true;
    }

    // --- files --------------------------------------------------------------

    /// paintio.library from Paint's drawer, opened the first time;
    /// null, said in a requester, when it cannot be.
    fn paintIO(app: *App) ?*PaintIOBase {
        if (app.pio_lib == null) app.pio_lib = app.sys.OpenLibrary(paintio.PAINTIOPATH, 1);
        return @ptrCast(app.pio_lib orelse {
            app.tellMissing(paintio.PAINTIOPATH);
            return null;
        });
    }

    /// The picture's file read: a project, or a picture as it is in any
    /// format datatypes reads, with its palette when it has one. False,
    /// the picture as it was, when it could not be.
    fn load(app: *App, name: [*:0]const u8) bool {
        const pio = app.paintIO() orelse return false;
        var project = paintio.Project{};
        const failure = pio.LoadProject(name, &project);
        if (failure != 0) {
            app.tellFault(.MSG_NO_OPEN, name, failure);
            return false;
        }
        defer pio.FreeProject(&project);
        // The bottom layer is the picture: Paint paints one.
        const layer = &project.layers.?[0];
        if (!app.takePicture(layer.pixels.?, project.width, project.height)) {
            app.tellSize(.MSG_NO_PICTURE, .{ project.width, project.height });
            return false;
        }
        // The pixels are the picture's now, not the project's to free.
        layer.pixels = null;
        app.stroke = null;
        app.drawing = null;
        app.view.left = 0;
        app.view.top = 0;
        app.view.fit(project.width, project.height);
        app.whole = true;
        if (project.palette_count != 0) {
            const count = @min(project.palette_count, app.palette.len);
            @memcpy(app.palette[0..count], project.palette[0..count]);
            app.showPalette();
        }
        app.keepPath(name);
        app.writes_back = (project.kind == paintio.PIOKIND_PROJECT) == (formatOf(name) == .project);
        app.followBars();
        return true;
    }

    /// The palette's boxes drawn again from `palette`.
    fn showPalette(app: *App) void {
        const gui = app.ui() orelse return;
        _ = app.ib.SetGadgetAttrsTagList(gui.palette, gui.window, &[_]TagItem{
            .{ .tag = pa.PALETTE_ColorTable, .data = @intFromPtr(&app.palette) },
            .{},
        });
    }

    /// Saved where it came from, in the form it was, or under a name
    /// asked for when it has none or came from a form Paint does not
    /// write. Whether it was.
    fn saveKept(app: *App) bool {
        if (app.path[0] == 0 or !app.writes_back) return app.saveAs();
        return app.saveTo(&app.path);
    }

    fn saveAs(app: *App) bool {
        var name: [path_size:0]u8 = undefined;
        if (!app.askFile(app.text.get(.MSG_SAVE_AS_TITLE), true, &app.path, &name)) return false;
        return app.saveTo(&name);
    }

    /// The picture written as the name's ending says: a PNG, an ILBM,
    /// or a project with the palette. Whether it was.
    fn saveTo(app: *App, name: [*:0]const u8) bool {
        const pio = app.paintIO() orelse return false;
        const width = app.picture.width;
        const height = app.picture.height;
        const failure = switch (formatOf(name)) {
            .png => pio.SavePicture(name, app.picture.pixels, width, height, paintio.PIOFORMAT_PNG),
            .ilbm => pio.SavePicture(name, app.picture.pixels, width, height, paintio.PIOFORMAT_ILBM),
            .project => blk: {
                var layers = [1]paintio.Layer{.{ .pixels = app.picture.pixels }};
                var project = paintio.Project{ .width = width, .height = height, .layer_count = 1, .layers = &layers, .palette_count = app.palette.len };
                @memcpy(project.palette[0..app.palette.len], &app.palette);
                break :blk pio.SaveProject(name, &project);
            },
        };
        if (failure != 0) {
            app.tellFault(.MSG_NO_SAVE, name, failure);
            return false;
        }
        app.changed = false;
        app.keepPath(name);
        app.writes_back = true;
        return true;
    }

    /// The file's name kept, and the title made to show it.
    fn keepPath(app: *App, name: [*:0]const u8) void {
        if (name != @as([*:0]const u8, &app.path)) {
            var at: usize = 0;
            while (name[at] != 0 and at < app.path.len) : (at += 1) app.path[at] = name[at];
            app.path[at] = 0;
        }
        if (app.ui()) |gui| gui.shown_changed = null;
    }

    /// A new picture has no file.
    fn forgetPath(app: *App) void {
        app.path[0] = 0;
        app.writes_back = false;
        if (app.ui()) |gui| gui.shown_changed = null;
    }

    /// A file asked for with asl's requester, into `into`. False when the
    /// requester was cancelled or could not be had.
    fn askFile(app: *App, title: [*:0]const u8, saving: bool, start: *const [path_size:0]u8, into: *[path_size:0]u8) bool {
        const gui = app.ui() orelse return false;
        if (app.asl_lib == null) app.asl_lib = app.sys.OpenLibrary(asl.ASLNAME, 0);
        const ab: *AslBase = @ptrCast(app.asl_lib orelse {
            app.tellMissing(asl.ASLNAME);
            return false;
        });
        // The drawer and the name of the file `start` is, to begin with.
        var drawer: [path_size:0]u8 = @splat(0);
        var file: [*:0]const u8 = "";
        if (start[0] != 0) {
            drawer = start.*;
            file = app.dl.FilePart(start);
            const path_end = @intFromPtr(app.dl.PathPart(&drawer)) - @intFromPtr(&drawer);
            drawer[path_end] = 0;
        }
        const handle = ab.AllocAslRequest(asl.ASL_FileRequest, &[_]TagItem{
            .{ .tag = asl.ASLFR_TitleText, .data = @intFromPtr(title) },
            .{ .tag = asl.ASLFR_Window, .data = @intFromPtr(gui.window) },
            .{ .tag = asl.ASLFR_SleepWindow, .data = 1 },
            .{ .tag = asl.ASLFR_InitialDrawer, .data = @intFromPtr(&drawer) },
            .{ .tag = asl.ASLFR_InitialFile, .data = @intFromPtr(file) },
            .{ .tag = asl.ASLFR_DoSaveMode, .data = @intFromBool(saving) },
            .{},
        }) orelse return false;
        defer ab.FreeAslRequest(handle);
        if (!ab.AslRequest(handle, null)) return false;
        const request: *asl.FileRequester = @ptrCast(@alignCast(handle));
        const chosen = request.file orelse return false;
        if (chosen[0] == 0) return false;
        into.* = @splat(0);
        if (request.drawer) |dir| {
            var at: usize = 0;
            while (dir[at] != 0 and at < into.len) : (at += 1) into[at] = dir[at];
        }
        return app.dl.AddPart(into, chosen, into.len);
    }

    /// The window's title - or on a screen of its own, the screen's bar -
    /// naming the file, a `*` before it while it has changes.
    fn syncTitle(app: *App) void {
        const gui = app.ui() orelse return;
        if (gui.shown_changed) |shown| {
            if (shown == app.changed) return;
        }
        gui.shown_changed = app.changed;
        const name: [*:0]const u8 = if (app.path[0] != 0) app.dl.FilePart(&app.path) else app.text.get(.MSG_UNTITLED);
        const tail = " - " ++ COMMAND_NAME;
        var used: usize = 0;
        if (app.changed) {
            app.title[0] = '*';
            used = 1;
        }
        var at: usize = 0;
        while (name[at] != 0 and used < app.title.len - tail.len) : (at += 1) {
            app.title[used] = name[at];
            used += 1;
        }
        for (tail) |byte| {
            app.title[used] = byte;
            used += 1;
        }
        app.title[used] = 0;
        if (gui.own) app.ib.SetWindowTitles(gui.window, wn.TITLE_UNCHANGED, &app.title) else app.ib.SetWindowTitles(gui.window, &app.title, wn.TITLE_UNCHANGED);
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
        const under = app.view.toPicture(@truncate(@as(isize, @bitCast(x))), @truncate(@as(isize, @bitCast(y))));
        // Far past the picture is as good as just past it.
        const at = Point{ @max(-max_side, @min(2 * max_side, under[0])), @max(-max_side, @min(2 * max_side, under[1])) };
        const first = !app.pressing;
        app.pressing = !final;
        const menu_button = button == cv.CANVAS_MENU;
        const colour = if (menu_button) app.background else app.foreground;
        app.at = at;
        switch (app.tool) {
            .freehand, .dots, .airbrush => app.strokeTo(at, colour, menu_button, final),
            .line, .curve, .rectangle, .ellipse => app.dragShape(at, colour, menu_button, first, final),
            .polygon => app.polygonTo(at, colour, menu_button, first, final),
            .fill => if (first) app.floodAt(at, colour),
            .pick => if (final) app.pickAt(at, menu_button),
            .text => if (final) app.placeText(at, colour),
            .grab => app.grabTo(at, menu_button, first, final),
        }
        // Let go, the pointer is where the brush is shown again.
        if (final) {
            app.hover = at;
            app.at = if (app.picture.inside(at[0], at[1])) at else null;
        }
    }

    /// The brush as a stroke puts it down: an own brush in the stroke's
    /// colour rather than its own colours, when made with the menu
    /// button.
    fn brushFor(app: *const App, menu_button: bool) Brush {
        var used = app.brush;
        if (menu_button) used.mode = .one_colour;
        return used;
    }

    /// The freehand tools and the airbrush, from where the pointer was
    /// to where it is.
    fn strokeTo(app: *App, at: Point, colour: Pixel, menu_button: bool, final: bool) void {
        if (app.stroke == null) app.stroke = .{ .colour = colour, .menu = menu_button };
        const stroke = &app.stroke.?;
        const brush = app.brushFor(stroke.menu);
        var changed = Area.none;
        switch (app.tool) {
            .freehand => if (stroke.last) |last|
                brush_zig.line(&app.picture, brush, last[0], last[1], at[0], at[1], stroke.colour, &changed)
            else
                brush_zig.stamp(&app.picture, brush, at[0], at[1], stroke.colour, &changed),
            .airbrush => brush_zig.spray(&app.picture, brush, at[0], at[1], stroke.colour, &app.random, &changed),
            else => brush_zig.stamp(&app.picture, brush, at[0], at[1], stroke.colour, &changed),
        }
        stroke.last = at;
        stroke.changed = stroke.changed.add(changed);
        app.show(changed);
        if (final) app.endStroke();
    }

    /// A line, a rectangle or an ellipse pulled from where the button
    /// went down to where it is; a curve's line the same, and then, on
    /// the next press, its bend.
    fn dragShape(app: *App, at: Point, colour: Pixel, menu_button: bool, first: bool, final: bool) void {
        if (app.drawing) |*drawing| if (drawing.bending) {
            drawing.points[2] = at;
            drawing.count = 3;
            app.drawShape();
            if (final) app.endShape();
            return;
        };
        if (first or app.drawing == null) {
            app.endShape();
            app.drawing = .{ .tool = app.tool, .colour = colour, .menu = menu_button, .count = 2 };
            app.drawing.?.points[0] = at;
        }
        const drawing = &app.drawing.?;
        drawing.points[1] = at;
        app.drawShape();
        if (!final) return;
        // A curve's line waits to be bent - unless it is a single point.
        const points = drawing.points;
        if (drawing.tool == .curve and (points[0][0] != points[1][0] or points[0][1] != points[1][1])) {
            drawing.bending = true;
            return;
        }
        app.endShape();
    }

    /// A polygon's corners: each press starts an edge from the last
    /// corner, its release puts the edge's end down. Let go on the first
    /// corner, or on the last one again, it is closed and done.
    fn polygonTo(app: *App, at: Point, colour: Pixel, menu_button: bool, first: bool, final: bool) void {
        if (app.drawing == null) {
            if (!first) return;
            app.drawing = .{ .tool = .polygon, .colour = colour, .menu = menu_button, .count = 2 };
            app.drawing.?.points[0] = at;
            app.drawing.?.points[1] = at;
        } else if (first) {
            const drawing = &app.drawing.?;
            if (drawing.count < drawing.points.len) {
                drawing.points[drawing.count] = at;
                drawing.count += 1;
            }
        }
        const drawing = &app.drawing.?;
        drawing.points[drawing.count - 1] = at;
        app.drawShape();
        if (!final or drawing.count < 3) return;
        const reach: i32 = @intCast(close_reach / app.view.zoom);
        const end = drawing.points[drawing.count - 1];
        if (near(end, drawing.points[0], reach) or near(end, drawing.points[drawing.count - 2], reach)) {
            // The corner let go of is that one.
            drawing.count -= 1;
            app.endShape();
        }
    }

    /// The shape drawn again: the picture as `kept` has it where it was,
    /// and the shape as it is now.
    fn drawShape(app: *App) void {
        const drawing = if (app.drawing) |*drawing| drawing else return;
        app.picture.copyArea(&app.kept, drawing.shown);
        var drawn = Area.none;
        const points = drawing.points[0..drawing.count];
        const picture = &app.picture;
        const colour = drawing.colour;
        const brush = app.brushFor(drawing.menu);
        switch (drawing.tool) {
            .rectangle => shapes.rectangle(picture, brush, points[0], points[1], colour, app.filled, &drawn),
            .ellipse => shapes.ellipse(picture, brush, points[0], points[1], colour, app.filled, &drawn),
            .curve => if (points.len == 3)
                shapes.curve(picture, brush, points[0], points[1], points[2], colour, &drawn)
            else
                brush_zig.line(picture, brush, points[0][0], points[0][1], points[1][0], points[1][1], colour, &drawn),
            .polygon => if (drawing.closed)
                shapes.polygon(picture, brush, points, colour, app.filled, &drawn)
            else
                shapes.polyline(picture, brush, points, colour, &drawn),
            .grab => shapes.frame(picture, points[0], points[1], &drawn),
            else => brush_zig.line(picture, brush, points[0][0], points[0][1], points[1][0], points[1][1], colour, &drawn),
        }
        app.show(drawing.shown.add(drawn));
        drawing.shown = drawn;
    }

    /// The shape done: a polygon closed, and what it covers kept for
    /// undoing.
    fn endShape(app: *App) void {
        // A brush's frame is never kept: it goes as it is.
        if (app.drawing) |drawing| if (drawing.tool == .grab) {
            _ = app.cancelShape();
            return;
        };
        if (app.drawing) |*drawing| if (drawing.tool == .polygon and !drawing.closed) {
            drawing.closed = true;
            app.drawShape();
        };
        const drawing = app.drawing orelse return;
        app.drawing = null;
        if (drawing.shown.isEmpty()) return;
        app.changed = true;
        if (!app.history.record(&app.picture, &app.kept, drawing.shown)) app.tell(.MSG_NO_UNDO);
    }

    /// The shape put away, the picture as it was. False with none.
    fn cancelShape(app: *App) bool {
        const drawing = app.drawing orelse return false;
        app.drawing = null;
        app.picture.copyArea(&app.kept, drawing.shown);
        app.show(drawing.shown);
        return true;
    }

    /// The press ended without its release - the window lost the input:
    /// what was being dragged ends where it is.
    fn letGo(app: *App) void {
        if (!app.pressing) return;
        app.pressing = false;
        app.at = null;
        app.endStroke();
        if (app.drawing) |drawing| {
            if (drawing.tool != .polygon and !drawing.bending) app.endShape();
        }
    }

    // --- the own brush ----------------------------------------------------------

    /// The frame of what is cut as a brush, pulled from where the button
    /// went down to where it is. Let go, what it holds is the brush, in
    /// use - with the menu button cut out, the picture left the
    /// background colour there - and the tool before is chosen again.
    fn grabTo(app: *App, at: Point, menu_button: bool, first: bool, final: bool) void {
        if (first or app.drawing == null) {
            app.endShape();
            app.drawing = .{ .tool = .grab, .colour = 0, .menu = menu_button, .count = 2 };
            app.drawing.?.points[0] = at;
        }
        const drawing = &app.drawing.?;
        drawing.points[1] = at;
        app.drawShape();
        if (!final) return;
        const area = shapes.areaOf(drawing.points[0], drawing.points[1]).clip(app.picture.width, app.picture.height);
        _ = app.cancelShape();
        if (area.isEmpty()) return;
        const memory = app.brushMemory(area.width(), area.height()) orelse return;
        var made = Picture{ .pixels = @ptrCast(@alignCast(memory)), .width = area.width(), .height = area.height() };
        brush_zig.grab(&app.picture, area, app.background, &made);
        app.takeBrush(memory, made.width, made.height);
        if (menu_button) {
            app.picture.fillArea(area, app.background);
            app.changedArea(area);
        }
        app.chooseTool(app.before_grab);
    }

    /// Memory for an own brush of that size; null, said in a requester,
    /// when it is larger than a brush may be or there is none.
    fn brushMemory(app: *App, width: u32, height: u32) ?*anyopaque {
        if (width > brush_zig.max_own_side or height > brush_zig.max_own_side) {
            app.tellSize(.MSG_BRUSH_TOO_LARGE, .{ brush_zig.max_own_side, brush_zig.max_own_side });
            return null;
        }
        return app.sys.AllocVec(Picture.bytesFor(width, height), exec.MEMF_ANY) orelse {
            app.tellSize(.MSG_NO_BRUSH, .{ width, height });
            return null;
        };
    }

    /// `memory`, an own brush's pixels of that size from AllocVec, made
    /// the own brush and put in use; the one before freed.
    fn takeBrush(app: *App, memory: *anyopaque, width: u32, height: u32) void {
        if (app.own_memory) |old| app.sys.FreeVec(old);
        app.own_memory = memory;
        app.own_brush = .{ .pixels = @ptrCast(@alignCast(memory)), .width = width, .height = height };
        app.brush.own = &app.own_brush;
        app.brush_changes +%= 1;
    }

    /// The own brush flipped, turned, halved or doubled, and put in use.
    fn transformBrush(app: *App, which: brush_zig.Transform) void {
        if (app.own_memory == null) return;
        const from = app.own_brush;
        const size = brush_zig.transformedSize(which, from.width, from.height) orelse {
            app.tellSize(.MSG_BRUSH_TOO_LARGE, .{ brush_zig.max_own_side, brush_zig.max_own_side });
            return;
        };
        const memory = app.brushMemory(size[0], size[1]) orelse return;
        var made = Picture{ .pixels = @ptrCast(@alignCast(memory)), .width = size[0], .height = size[1] };
        brush_zig.transform(which, &from, &made);
        app.takeBrush(memory, size[0], size[1]);
    }

    /// A brush read from a file - any picture, as it is, or a project's
    /// bottom layer - made the own brush, in use.
    fn openBrush(app: *App) void {
        var name: [path_size:0]u8 = undefined;
        if (!app.askFile(app.text.get(.MSG_OPEN_BRUSH_TITLE), false, &app.brush_path, &name)) return;
        const pio = app.paintIO() orelse return;
        var project = paintio.Project{};
        const failure = pio.LoadProject(&name, &project);
        if (failure != 0) {
            app.tellFault(.MSG_NO_OPEN, &name, failure);
            return;
        }
        defer pio.FreeProject(&project);
        if (project.width > brush_zig.max_own_side or project.height > brush_zig.max_own_side) {
            app.tellSize(.MSG_BRUSH_TOO_LARGE, .{ brush_zig.max_own_side, brush_zig.max_own_side });
            return;
        }
        // The pixels are the brush's now, not the project's to free.
        const layer = &project.layers.?[0];
        app.takeBrush(layer.pixels.?, project.width, project.height);
        layer.pixels = null;
        app.brush_path = name;
    }

    /// The own brush written to a file: an ILBM for a name ending as one
    /// does, a PNG otherwise, with its see-through parts.
    fn saveBrush(app: *App) void {
        if (app.own_memory == null) return;
        var name: [path_size:0]u8 = undefined;
        if (!app.askFile(app.text.get(.MSG_SAVE_BRUSH_TITLE), true, &app.brush_path, &name)) return;
        const pio = app.paintIO() orelse return;
        const format = if (formatOf(&name) == .ilbm) paintio.PIOFORMAT_ILBM else paintio.PIOFORMAT_PNG;
        const failure = pio.SavePicture(&name, app.own_brush.pixels, app.own_brush.width, app.own_brush.height, format);
        if (failure != 0) {
            app.tellFault(.MSG_NO_SAVE_BRUSH, &name, failure);
            return;
        }
        app.brush_path = name;
    }

    /// The brush shown under the pointer: while the pointer is over the
    /// view, no button is down, nothing is being drawn and the tool puts
    /// the brush down.
    fn pointerBrush(app: *const App) ?brush_zig.Ghost {
        const at = app.hover orelse return null;
        if (app.pressing or app.drawing != null or app.gui == null) return null;
        switch (app.tool) {
            .freehand, .dots, .line, .curve => {},
            .rectangle, .ellipse, .polygon => if (app.filled) return null,
            else => return null,
        }
        return brush_zig.Ghost.at(app.brush, at[0], at[1], app.foreground);
    }

    /// Where the brush under the pointer was and where it is now drawn
    /// again, when it has moved or changed.
    fn followPointerBrush(app: *App, now: ?brush_zig.Ghost) void {
        const mark: GhostMark = if (now) |shown| .{
            .area = shown.area,
            .colour = shown.colour,
            .shape = app.brush.shape,
            .size = app.brush.size,
            .own = app.brush.own != null,
            .mode = app.brush.mode,
            .changes = app.brush_changes,
        } else .{};
        if (mark.same(app.ghost_shown)) return;
        app.show(app.ghost_shown.area);
        app.show(mark.area);
        app.ghost_shown = mark;
    }

    /// The pointer moved: the picture pixel under it, while it is over the
    /// view and no button is down - where the brush is shown, and what
    /// the status says.
    fn hoverAt(app: *App) void {
        const gui = app.ui() orelse return;
        if (app.pressing) return;
        var mouse_x: usize = 0;
        var mouse_y: usize = 0;
        _ = app.ib.GetAttr(wc.WINDOWA_MouseX, gui.object.?, &mouse_x);
        _ = app.ib.GetAttr(wc.WINDOWA_MouseY, gui.object.?, &mouse_y);
        var width: usize = 0;
        var height: usize = 0;
        app.ib.GetWindowAttrs(gui.window, &[_]TagItem{
            .{ .tag = wn.WA_Width, .data = @intFromPtr(&width) },
            .{ .tag = wn.WA_Height, .data = @intFromPtr(&height) },
            .{},
        });
        const box = gc.boxIn(gc.gadget(gui.view), @intCast(width), @intCast(height));
        const x = @as(i32, @truncate(@as(isize, @bitCast(mouse_x)))) - box.left;
        const y = @as(i32, @truncate(@as(isize, @bitCast(mouse_y)))) - box.top;
        if (x < 0 or y < 0 or x >= app.view.width or y >= app.view.height) {
            app.hover = null;
            app.at = null;
            return;
        }
        const at = app.view.toPicture(x, y);
        app.hover = at;
        app.at = if (app.picture.inside(at[0], at[1])) at else null;
    }

    /// The area of one colour at `at` filled.
    fn floodAt(app: *App, at: Point, colour: Pixel) void {
        const memory = app.sys.AllocVec(first_seeds * @sizeOf(fill_zig.Seed), exec.MEMF_ANY) orelse {
            app.tell(.MSG_FILL_SHORT);
            return;
        };
        var seeds = fill_zig.Seeds{ .items = @ptrCast(@alignCast(memory)), .capacity = first_seeds, .more = moreSeeds, .context = app.sys };
        var changed = Area.none;
        const whole = fill_zig.flood(&app.picture, at[0], at[1], colour, &seeds, &changed);
        app.sys.FreeVec(@ptrCast(seeds.items));
        app.changedArea(changed);
        if (!whole) app.tell(.MSG_FILL_SHORT);
    }

    /// The colour under `at` taken as the foreground, or with the menu
    /// button the background; the tool before the picker chosen again.
    fn pickAt(app: *App, at: Point, menu_button: bool) void {
        if (app.picture.inside(at[0], at[1])) {
            const colour = app.picture.get(@intCast(at[0]), @intCast(at[1]));
            if (menu_button) app.background = colour else {
                app.foreground = colour;
                // The palette shows it when it has it.
                for (app.palette, 0..) |offered, place| if (offered == colour) {
                    app.foreground_index = @intCast(place);
                    if (app.ui()) |gui| _ = app.ib.SetGadgetAttrsTagList(gui.palette, gui.window, &[_]TagItem{ .{ .tag = pa.PALETTE_Color, .data = place }, .{} });
                    break;
                };
            }
            app.drawColours();
        }
        app.chooseTool(app.before_pick);
    }

    /// A text asked for and put down with its top left at `at`.
    fn placeText(app: *App, at: Point, colour: Pixel) void {
        if (!app.askText()) return;
        var length: u32 = 0;
        while (app.typed[length] != 0) length += 1;
        if (length == 0) return;
        const lib = app.sys.OpenLibrary(sdk.diskfont.DISKFONTNAME, 0) orelse {
            app.tell(.MSG_NO_FONT);
            return;
        };
        defer app.sys.CloseLibrary(lib);
        const df: *DiskfontBase = @ptrCast(lib);
        const font = df.OpenDiskFont(&.{ .name = &app.font_name, .y_size = @intCast(@min(app.font_size, 0xFFFF)) }) orelse {
            app.tell(.MSG_NO_FONT);
            return;
        };
        defer app.gb.CloseFont(font);
        // A surface over the picture's own pixels, which graphics draws
        // the text into.
        var surface = sdk.rtg.Surface{
            .pixels = @ptrCast(app.picture.pixels),
            .width = app.picture.width,
            .height = app.picture.height,
            .pitch = app.picture.width * @sizeOf(Pixel),
            .size_bytes = Picture.bytesFor(app.picture.width, app.picture.height),
            .format = .bgra32,
        };
        const rp = app.gb.CreateRastPortTagList(&[_]TagItem{
            .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
            .{ .tag = graphics.RPTAG_APen, .data = colour },
            .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
            .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(font) },
            .{},
        }) orelse return;
        defer app.gb.FreeRastPort(rp);
        var baseline: u32 = 0;
        var height: u32 = 0;
        app.gb.GetRPAttrs(rp, &[_]TagItem{
            .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
            .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) },
            .{},
        });
        var extent = graphics.TextExtent{};
        app.gb.TextExtent(rp, &app.typed, length, &extent);
        const line_y = at[1] + @as(i32, @intCast(baseline));
        app.gb.Move(rp, at[0], line_y);
        app.gb.Text(rp, &app.typed, length);
        // What the letters reach, and a margin for what leans past it.
        const margin: i32 = @intCast(height / 4 + 2);
        const area = Area{
            .min_x = at[0] + @min(extent.extent.min_x, 0) - margin,
            .min_y = line_y + @min(extent.extent.min_y, -@as(i32, @intCast(baseline))) - margin,
            .max_x = at[0] + @max(extent.extent.max_x, extent.width) + margin,
            .max_y = line_y + @max(extent.extent.max_y, @as(i32, @intCast(height -| baseline))) + margin,
        };
        app.changedArea(area.clip(app.picture.width, app.picture.height));
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
        const pointer_brush = app.pointerBrush();
        app.followPointerBrush(pointer_brush);
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
                    app.view.row(&app.picture, y + row, area.min_x, area.max_x, band[start .. start + width], if (pointer_brush) |*shown| shown else null);
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
        app.syncTitle();
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
        const width: i64 = app.picture.width;
        const height: i64 = app.picture.height;
        const zoom: i64 = app.view.zoom;
        const made = if (app.brush.own) |own| (if (app.at) |at|
            app.text.format(&line, .MSG_STATUS_OWN_AT, .{ width, height, zoom, @as(i64, own.width), @as(i64, own.height), @as(i64, at[0]), @as(i64, at[1]) })
        else
            app.text.format(&line, .MSG_STATUS_OWN, .{ width, height, zoom, @as(i64, own.width), @as(i64, own.height) })) else if (app.at) |at|
            app.text.format(&line, .MSG_STATUS_AT, .{ width, height, zoom, @as(i64, app.brush.size), @as(i64, at[0]), @as(i64, at[1]) })
        else
            app.text.format(&line, .MSG_STATUS, .{ width, height, zoom, @as(i64, app.brush.size) });
        if (same(made, &app.status)) return;
        const length = @min(made.len, app.status.len);
        @memcpy(app.status[0..length], made[0..length]);
        app.status[length] = 0;
        _ = app.ib.SetGadgetAttrsTagList(gui.status, gui.window, &[_]TagItem{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&app.status) }, .{} });
    }

    // --- the menus and the buttons --------------------------------------------

    fn menuState(app: *const App) MenuState {
        return .{
            .tool = app.tool,
            .filled = app.filled,
            .round = app.brush.shape == .round,
            .size = app.brush.size,
            .own_brush = app.brush.own != null,
            .has_own = app.own_memory != null,
            .one_colour = app.brush.mode == .one_colour,
            .grid = app.view.grid,
            .own = app.own,
            .can_undo = app.history.canUndo() or app.drawing != null,
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

    /// Undo and Redo's buttons disabled while there is nothing to do, and
    /// the filled shapes' button as they are.
    fn syncButtons(app: *App) void {
        const gui = app.ui() orelse return;
        if (gui.shown_filled == null or gui.shown_filled.? != app.filled) {
            gui.shown_filled = app.filled;
            _ = app.ib.SetGadgetAttrsTagList(gui.command_buttons[filled_button], gui.window, &[_]TagItem{ .{ .tag = tb.TOOLBUTTON_Checked, .data = @intFromBool(app.filled) }, .{} });
        }
        const state = [2]bool{ app.history.canUndo() or app.drawing != null, app.history.canRedo() };
        if (gui.shown_undo) |shown| {
            if (shown[0] == state[0] and shown[1] == state[1]) return;
        }
        gui.shown_undo = state;
        for ([_]usize{ undo_button, redo_button }, state) |place, can| {
            _ = app.ib.SetGadgetAttrsTagList(gui.command_buttons[place], gui.window, &[_]TagItem{ .{ .tag = gc.GA_Disabled, .data = @intFromBool(!can) }, .{} });
        }
    }

    /// The tool chosen, its button down and the others up; a shape
    /// being drawn is done first. The airbrush keeps spraying where the
    /// pointer is held, so the picture tells it at every tick then.
    fn chooseTool(app: *App, tool: Tool) void {
        app.endShape();
        if (tool == .pick and app.tool != .pick) app.before_pick = app.tool;
        if (tool == .grab and app.tool != .grab) app.before_grab = switch (app.tool) {
            .freehand, .dots, .line, .curve => app.tool,
            .rectangle, .ellipse, .polygon => if (app.filled) .dots else app.tool,
            else => .dots,
        };
        app.tool = tool;
        const gui = app.ui() orelse return;
        for (tools, gui.tool_buttons) |entry, button| {
            _ = app.ib.SetGadgetAttrsTagList(button, gui.window, &[_]TagItem{ .{ .tag = tb.TOOLBUTTON_Checked, .data = @intFromBool(entry.tool == tool) }, .{} });
        }
        _ = app.ib.SetGadgetAttrsTagList(gui.view, gui.window, &[_]TagItem{ .{ .tag = cv.CANVAS_Ticks, .data = @intFromBool(tool == .airbrush) }, .{} });
    }

    // --- the commands ---------------------------------------------------------

    /// A menu item picked. False to end.
    fn picked(app: *App, number: u32) bool {
        const gui = app.ui() orelse return true;
        const strip = gui.strip orelse return true;
        const picked_item = app.ib.ItemAddress(strip, number) orelse return true;
        const value = @intFromPtr(mn.GTMENUITEM_USERDATA(picked_item));
        if (Tool.of(value)) |tool| {
            app.chooseTool(tool);
            return true;
        }
        if (value >= size_base and value < size_base + brush_zig.sizes.len) {
            app.brush.size = brush_zig.sizes[value - size_base];
            app.brush.own = null;
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
            .filled => app.filled = checked,
            else => return app.perform(which),
        }
        return true;
    }

    /// A command, from a menu, a button or a key. False to end.
    fn perform(app: *App, which: Command) bool {
        // A shape being drawn: Undo puts it away, what changes the picture
        // ends it first.
        switch (which) {
            .undo => if (app.cancelShape()) return true,
            .new, .quit, .redo, .clear, .open, .save, .save_as, .open_brush, .save_brush => app.endShape(),
            else => {},
        }
        switch (which) {
            .new => if (app.mayLeave()) {
                if (app.askSize()) |size| {
                    if (app.newPicture(size[0], size[1])) app.forgetPath() else app.tellSize(.MSG_NO_PICTURE, size);
                    app.followBars();
                }
            },
            .open => if (app.mayLeave()) {
                var name: [path_size:0]u8 = undefined;
                if (app.askFile(app.text.get(.MSG_OPEN_TITLE), false, &app.path, &name)) _ = app.load(&name);
            },
            .save => _ = app.saveKept(),
            .save_as => _ = app.saveAs(),
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
            .round, .square => {
                app.brush.shape = if (which == .round) .round else .square;
                app.brush.own = null;
            },
            // An own brush is halved and doubled.
            .smaller => if (app.brush.own != null) app.transformBrush(.halve) else {
                app.brush = app.brush.stepped(false);
            },
            .larger => if (app.brush.own != null) app.transformBrush(.double) else {
                app.brush = app.brush.stepped(true);
            },
            .own_brush => if (app.own_memory != null) {
                app.brush.own = &app.own_brush;
            },
            .own_colours => app.brush.mode = .own_colours,
            .one_colour => app.brush.mode = .one_colour,
            .flip_across => app.transformBrush(.flip_across),
            .flip_down => app.transformBrush(.flip_down),
            .turn => app.transformBrush(.turn),
            .open_brush => app.openBrush(),
            .save_brush => app.saveBrush(),
            .own_screen => app.switch_wanted = true,
            .filled => app.filled = !app.filled,
        }
        // A shape being drawn follows the brush and the filling.
        switch (which) {
            .round, .square, .smaller, .larger, .filled, .own_brush, .own_colours, .one_colour, .flip_across, .flip_down, .turn, .open_brush => app.drawShape(),
            else => {},
        }
        return true;
    }

    /// A colour of the palette picked: the select button's the
    /// foreground, the menu button's the background, which leaves the
    /// palette showing the foreground.
    fn pickedColour(app: *App, place: u32) void {
        const gui = app.ui() orelse return;
        if (place >= app.palette.len) return;
        var button: usize = pa.PALETTE_SELECT;
        _ = app.ib.GetAttr(pa.PALETTE_Button, gui.palette, &button);
        if (button == pa.PALETTE_MENU) {
            app.background = app.palette[place];
            _ = app.ib.SetGadgetAttrsTagList(gui.palette, gui.window, &[_]TagItem{ .{ .tag = pa.PALETTE_Color, .data = app.foreground_index }, .{} });
        } else {
            app.foreground = app.palette[place];
            app.foreground_index = place;
        }
        app.drawColours();
    }

    fn keyed(app: *App, code: u32) void {
        switch (code) {
            '+', '=' => app.zoomTo(app.view.nextZoom(true)),
            '-' => app.zoomTo(app.view.nextZoom(false)),
            '[', '<' => _ = app.perform(.smaller),
            ']', '>' => _ = app.perform(.larger),
            'x', 'X' => _ = app.perform(.swap),
            'F' => _ = app.perform(.filled),
            'h' => _ = app.perform(.flip_across),
            'v' => _ = app.perform(.flip_down),
            'z' => _ = app.perform(.turn),
            // Return ends a polygon or a curve as it is, Escape puts it
            // away.
            '\r' => app.endShape(),
            0x1B => _ = app.cancelShape(),
            else => for (tool_keys) |pair| if (pair.key == code) {
                app.chooseTool(pair.tool);
                break;
            },
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

    /// Whether the picture may go: unchanged, saved when asked, or let go
    /// of.
    fn mayLeave(app: *App) bool {
        if (!app.changed) return true;
        const gui = app.ui() orelse return true;
        const easy = intuition.requesters.EasyStruct{
            .title = COMMAND_NAME,
            .text_format = app.text.get(.MSG_CHANGED),
            .gadget_format = app.text.get(.MSG_CHANGED_BUTTONS),
        };
        return switch (app.ib.EasyRequestArgs(gui.window, &easy, null, null)) {
            1 => app.saveKept(),
            2 => true,
            else => false,
        };
    }

    /// A requester naming a file and saying why it failed, in dos's words.
    fn tellFault(app: *App, comptime message: Id, name: [*:0]const u8, failure: i32) void {
        const gui = app.ui() orelse return;
        comptime sdk.exec.checkFormat(strings.builtin(message), struct { [*:0]const u8, [*:0]const u8 });
        var why: [100:0]u8 = @splat(0);
        _ = app.dl.Fault(failure, null, &why, why.len);
        const easy = intuition.requesters.EasyStruct{ .title = COMMAND_NAME, .text_format = app.text.get(message), .gadget_format = app.text.get(.MSG_OK) };
        const args = [_]usize{ @intFromPtr(name), @intFromPtr(&why) };
        _ = app.ib.EasyRequestArgs(gui.window, &easy, null, &args);
    }

    /// A requester saying a library is missing.
    fn tellMissing(app: *App, name: [*:0]const u8) void {
        const gui = app.ui() orelse return;
        comptime sdk.exec.checkFormat(strings.builtin(.MSG_NO_PART), struct { [*:0]const u8 });
        const easy = intuition.requesters.EasyStruct{ .title = COMMAND_NAME, .text_format = app.text.get(.MSG_NO_PART), .gadget_format = app.text.get(.MSG_OK) };
        const args = [_]usize{@intFromPtr(name)};
        _ = app.ib.EasyRequestArgs(gui.window, &easy, null, &args);
    }

    fn tell(app: *App, comptime message: Id) void {
        const gui = app.ui() orelse return;
        const easy = intuition.requesters.EasyStruct{ .title = COMMAND_NAME, .text_format = app.text.get(message), .gadget_format = app.text.get(.MSG_OK) };
        _ = app.ib.EasyRequestArgs(gui.window, &easy, null, null);
    }

    /// A requester naming a size: `message` takes the width and the
    /// height.
    fn tellSize(app: *App, comptime message: Id, size: [2]u32) void {
        const gui = app.ui() orelse return;
        comptime sdk.exec.checkFormat(strings.builtin(message), struct { i64, i64 });
        const easy = intuition.requesters.EasyStruct{ .title = COMMAND_NAME, .text_format = app.text.get(message), .gadget_format = app.text.get(.MSG_OK) };
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

    /// The text and its font, asked in a window of its own: false when
    /// it was closed or cancelled. What is typed, and the font, are kept
    /// for the next time.
    fn askText(app: *App) bool {
        const gui = app.ui() orelse return false;
        const sys = app.sys;
        const string_lib = sys.OpenLibrary(sg.STRING_LIBRARY, 0) orelse return false;
        defer sys.CloseLibrary(string_lib);
        const font_lib = sys.OpenLibrary(gfo.GETFONT_LIBRARY, 0) orelse return false;
        defer sys.CloseLibrary(font_lib);
        const ib = app.ib;
        const field = ib.NewObjectTagList(null, sg.STRING_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_TEXT },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = gc.STRINGA_MaxChars, .data = app.typed.len },
            .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(&app.typed) },
            .{},
        });
        const font = ib.NewObjectTagList(null, gfo.GETFONT_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_FONT },
            .{ .tag = gfo.GETFONT_TitleText, .data = @intFromPtr(app.text.get(.MSG_FONT_TITLE)) },
            .{ .tag = gfo.GETFONT_Name, .data = @intFromPtr(&app.font_name) },
            .{ .tag = gfo.GETFONT_Size, .data = app.font_size },
            .{},
        });
        const answers = [2]?*Object{ textButton(ib, app.text.get(.MSG_OK), ID_OK), textButton(ib, app.text.get(.MSG_CANCEL), ID_CANCEL) };
        if (field == null or font == null or answers[0] == null or answers[1] == null) {
            for ([_]?*Object{ field, font } ++ answers) |made| ib.DisposeObject(made);
            return false;
        }
        const row = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(answers[0]) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(answers[1]) },
            .{},
        }) orelse {
            for ([_]?*Object{ field, font } ++ answers) |made| ib.DisposeObject(made);
            return false;
        };
        const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(field) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(.MSG_TEXT)) },
            .{ .tag = lg.CHILDA_MinWidth, .data = 240 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(font) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(.MSG_FONT)) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(row) },
            .{},
        }) orelse {
            ib.DisposeObject(row);
            ib.DisposeObject(field);
            ib.DisposeObject(font);
            return false;
        };
        const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
            screenTag(gui),
            .{ .tag = wn.WA_Title, .data = @intFromPtr(app.text.get(.MSG_TEXT_TITLE)) },
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
            return false;
        };
        defer ib.DisposeObject(object);
        var open = wc.WmOpen{};
        if (ib.SendMessage(object, @ptrCast(&open)) == 0) return false;
        const window: *Window = @ptrFromInt(windowOf(ib, object));

        var signal: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_SigMask, object, &signal);
        var code: u32 = 0;
        var handle = wc.WmHandleInput{ .code = &code };
        while (true) {
            _ = sys.Wait(@truncate(signal));
            while (true) {
                const word = ib.SendMessage(object, @ptrCast(&handle));
                if (word == wc.WMHI_LASTMSG) break;
                switch (word & wc.WMHI_CLASSMASK) {
                    wc.WMHI_CLOSEWINDOW => return false,
                    wc.WMHI_ACTIVE => _ = ib.ActivateGadget(field.?, window, null),
                    wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                        ID_CANCEL => return false,
                        ID_OK, ID_TEXT => {
                            app.keepText(field.?, font.?);
                            return true;
                        },
                        else => {},
                    },
                    wc.WMHI_VANILLAKEY => switch (word & wc.WMHI_KEYMASK) {
                        '\r' => {
                            app.keepText(field.?, font.?);
                            return true;
                        },
                        0x1B => return false,
                        else => {},
                    },
                    else => {},
                }
            }
        }
    }

    /// What the text window's fields say, kept.
    fn keepText(app: *App, field: *Object, font: *Object) void {
        var value: usize = 0;
        if (app.ib.GetAttr(gc.STRINGA_TextVal, field, &value) != 0 and value != 0) copyName(&app.typed, @ptrFromInt(value));
        value = 0;
        if (app.ib.GetAttr(gfo.GETFONT_Name, font, &value) != 0 and value != 0) copyName(&app.font_name, @ptrFromInt(value));
        value = 0;
        if (app.ib.GetAttr(gfo.GETFONT_Size, font, &value) != 0 and value != 0) app.font_size = @truncate(value);
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
                        } else if (id == Command.filled.id()) {
                            // The button has turned itself.
                            var on: usize = 0;
                            _ = app.ib.GetAttr(tb.TOOLBUTTON_Checked, gui.command_buttons[filled_button], &on);
                            app.filled = on != 0;
                            gui.shown_filled = app.filled;
                            app.drawShape();
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
                wc.WMHI_MOUSEMOVE => app.hoverAt(),
                wc.WMHI_NEWSIZE => app.fitView(),
                wc.WMHI_INACTIVE => {
                    app.letGo();
                    app.hover = null;
                    app.at = null;
                },
                else => {},
            }
            if (app.switch_wanted) return true;
        }
    }

    fn run(app: *App) void {
        while (true) {
            // What changed since the last wait shown first: a file opened
            // at the start has not been yet.
            app.flush();
            const gui = app.ui() orelse return;
            var signal: usize = 0;
            _ = app.ib.GetAttr(wc.WINDOWA_SigMask, gui.object.?, &signal);
            const got = app.sys.Wait(@as(u32, @truncate(signal)) | exec.SIGBREAKF_CTRL_C);
            if (got & exec.SIGBREAKF_CTRL_C != 0 and app.mayLeave()) return;
            if (!app.messages()) return;
            if (app.switch_wanted) {
                app.switch_wanted = false;
                if (!app.switchScreen()) return;
            }
        }
    }

    // --- the screens ------------------------------------------------------------

    /// The window taken down and made again on the other screen; false
    /// when it cannot be made on either.
    fn switchScreen(app: *App) bool {
        const to = !app.own;
        app.letGo();
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
        // The text tool's font is the screen's until another is chosen.
        if (app.font_name[0] == 0) {
            const name: [*:0]const u8 = if (info.font) |font| font.node.name orelse graphics.POSPAZNAME else graphics.POSPAZNAME;
            copyName(&app.font_name, name);
        }

        // The pictures of the tools and the commands.
        for (tools, 0..) |entry, place| gui.images[place] = glyph(ib, entry.glyph);
        for (buttons, tools.len..) |entry, place| gui.images[place] = glyph(ib, entry.glyph);

        // The gadgets; each one the program's to dispose of until a layout
        // takes it.
        var made: [tools.len + buttons.len + 4]?*Object = @splat(null);
        for (tools, 0..) |entry, place| made[place] = toolButton(ib, entry.tool.id(), gui.images[place], app.text.get(entry.hint), tb.TBKIND_TOGGLE);
        for (buttons, tools.len..) |entry, place| made[place] = toolButton(ib, entry.which.id(), gui.images[place], app.text.get(entry.hint), entry.kind);
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
            .{ .tag = pa.PALETTE_ColorTable, .data = @intFromPtr(&app.palette) },
            .{ .tag = pa.PALETTE_NumColors, .data = app.palette.len },
            .{ .tag = pa.PALETTE_Color, .data = app.foreground_index },
            .{},
        });
        made[others + 3] = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_STATUS },
            .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&app.status) },
            .{ .tag = tx.TEXT_RoomFor, .data = @intFromPtr("16384 x 16384   16:1   brush 1024 x 1024   at -00000, -00000") },
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
            // The pointer's moves: where the brush is shown.
            .{ .tag = wn.WA_ReportMouse, .data = 1 },
            // The menu titles always in the screen's bar, a click opening
            // them: the picture takes the menu button.
            .{ .tag = wn.WA_MenuBar, .data = 1 },
            .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_IDCMPUPDATE | wn.IDCMP_NEWSIZE | wn.IDCMP_RAWKEY | wn.IDCMP_MOUSEWHEEL | wn.IDCMP_INACTIVEWINDOW | wn.IDCMP_MOUSEMOVE },
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

/// A C string copied into a buffer, cut to fit.
fn copyName(into: anytype, from: [*:0]const u8) void {
    var at: usize = 0;
    while (at < into.len and from[at] != 0) : (at += 1) into[at] = from[at];
    into[at] = 0;
}

/// Whether two places are within `reach` of each other, across and down.
fn near(a: Point, b: Point, reach: i32) bool {
    const across = a[0] - b[0];
    const down = a[1] - b[1];
    return across >= -reach and across <= reach and down >= -reach and down <= reach;
}

/// A fill's seeds out of room: a stack twice the size, with exec's
/// memory (`context` is exec).
fn moreSeeds(seeds: *fill_zig.Seeds) bool {
    const sys: *ExecBase = @ptrCast(@alignCast(seeds.context orelse return false));
    const capacity = seeds.capacity * 2;
    const memory = sys.AllocVec(capacity * @sizeOf(fill_zig.Seed), exec.MEMF_ANY) orelse return false;
    const items: [*]fill_zig.Seed = @ptrCast(@alignCast(memory));
    @memcpy(items[0..seeds.len], seeds.items[0..seeds.len]);
    sys.FreeVec(@ptrCast(seeds.items));
    seeds.items = items;
    seeds.capacity = capacity;
    return true;
}

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
    const on: ?bool = if (Tool.of(value)) |tool|
        tool == state.tool
    else if (value >= size_base and value < size_base + brush_zig.sizes.len)
        !state.own_brush and brush_zig.sizes[value - size_base] == state.size
    else if (Command.of(value)) |which| switch (which) {
        .filled => state.filled,
        .round => !state.own_brush and state.round,
        .square => !state.own_brush and !state.round,
        .own_colours => !state.one_colour,
        .one_colour => state.one_colour,
        // What there must be an own brush for.
        .own_brush, .flip_across, .flip_down, .turn, .save_brush => {
            if (state.has_own) menu_item.flags |= mn.ITEMENABLED else menu_item.flags &= ~mn.ITEMENABLED;
            if (which != .own_brush) return;
            if (state.own_brush) menu_item.flags |= mn.CHECKED else menu_item.flags &= ~mn.CHECKED;
            return;
        },
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

/// What a file is written as, by its name's ending.
const Format = enum { project, png, ilbm };

fn formatOf(name: [*:0]const u8) Format {
    var length: usize = 0;
    while (name[length] != 0) length += 1;
    var dot = length;
    while (dot > 0) {
        dot -= 1;
        switch (name[dot]) {
            '.' => break,
            '/', ':' => return .project,
            else => {},
        }
    } else return .project;
    const ending = name[dot + 1 .. length];
    if (prefs.style.same(ending, "PNG")) return .png;
    for ([_][]const u8{ "IFF", "ILBM", "LBM" }) |known| {
        if (prefs.style.same(ending, known)) return .ilbm;
    }
    return .project;
}

fn sameState(a: MenuState, b: MenuState) bool {
    return a.tool == b.tool and a.filled == b.filled and a.round == b.round and a.size == b.size and
        a.own_brush == b.own_brush and a.has_own == b.has_own and a.one_colour == b.one_colour and
        a.grid == b.grid and a.own == b.own and a.can_undo == b.can_undo and a.can_redo == b.can_redo;
}

/// Whether the text made and the C string are the same.
fn same(made: []const u8, shown: [*:0]const u8) bool {
    for (made, 0..) |char, at| {
        if (shown[at] != char) return false;
    }
    return shown[made.len] == 0;
}

/// The screen the icon Paint was started from asks for with its tool
/// type, or the last choice when it asks for none; null when Paint was
/// not started from an icon.
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

    // The file to open, and the screen: SCREEN= from the shell, the
    // icon's tool type, or the last choice.
    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    var own: ?bool = null;
    if (rdargs.string(argv[arg_screen])) |value| {
        own = ownOrDesktop(value) orelse {
            _ = text.printf(dl, .MSG_BADSCREEN, .{});
            return dos.RETURN_ERROR;
        };
    }
    if (own == null) own = screenWanted(sys, dl, ub) orelse keptScreen(sys, dl, ub);

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
        if (app.own_memory) |memory| sys.FreeVec(memory);
        app.freePicture();
        if (app.pio_lib) |lib| sys.CloseLibrary(lib);
        if (app.asl_lib) |lib| sys.CloseLibrary(lib);
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
    if (rdargs.string(argv[arg_file])) |name| _ = app.load(name);
    app.run();
    return dos.RETURN_OK;
}
