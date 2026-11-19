// SPDX-License-Identifier: MIT
//! Paint: pictures painted with the pointer. Built against the SDK only.
//!
//!   Paint [FILE] [SCREEN=OWN|DESKTOP]
//!
//! A window with the tools, the two colours and the palette down its left,
//! a side panel of sections beside them, the picture under a zoom bar,
//! and a status line along the bottom. Its menu titles stay in the
//! screen's bar while it is active (`WA_MenuBar`), a click opening one.
//! It opens on the desktop's screen, or on a screen of its own
//! (`SCREEN=OWN`, from the shell or as the icon's tool type): a window
//! without a border over the whole screen under its bar. Without either
//! it opens where it did the last time - View's Own Screen switches while
//! it runs, and `ENV:Paint.prefs` keeps the
//! choice (`SCREEN=OWN`), ENVARC: too. A switch takes the window down and
//! makes it again on the other screen; the picture, the zoom, the brush,
//! the colours, the folded sections and what can be undone stay.
//!
//! **The side panel.** Each section is a button with its name over its
//! gadgets; a press folds them away (`CHILDA_Hidden`) and unfolds them,
//! and the window is laid out again. Layers: the opacity of the layer
//! painted with the buttons that delete it and add one, its blend mode in
//! a chooser, and a listbrowser of the layers, top first, each with an
//! eye that shows and hides it (a toggle column) and its name; a click
//! paints a layer, a double-click renames it, a drag moves it. Brush:
//! Round, Square or Own Brush in
//! a chooser, and sliders for the size (1 to 64), the softness, the
//! opacity, the flow, the jitter and the rotation, and Dither (brush.zig
//! says what each does; every stroke, shape and spray goes down through
//! its `Ink`, whose mask is a byte a pixel kept with the picture and
//! emptied where a change ends). Colour: the foreground on
//! a colour wheel (colorwheel.gadget) with its brightness beside it
//! (gradientslider.gadget, from the colour at its brightest down to
//! black). The panel follows the brush and the foreground however they
//! change.
//!
//! **The picture** is true colour, `0xAARRGGBB` a pixel, as large as the
//! screen to begin with; File's New... asks for another size. It is a
//! stack of layers (layers.zig), at most 64: `picture` is the one being
//! painted and `kept` its copy from before the change being made. What is
//! shown is the stack composed where it changed into a picture of its
//! own, made when the stack first needs one - one layer, shown, at full
//! opacity is shown as it is. It is
//! shown in canvas.gadget, which follows its box: Paint makes the rows the
//! window shows from the picture (view.zig) - at a zoom of 1 to 16, with a
//! grid from 8 on, a smaller picture in the middle on a dark ground - and
//! writes only the area a change touched. There are no scroll bars: the
//! hand tool, or Space held, drags a picture larger than the view, and
//! the wheel (with Shift across) and the cursor keys move it. The zoom
//! bar above it makes it smaller and larger, says the zoom in per cent,
//! and fits the whole picture to the view.
//!
//! **Painting.** The select button paints in the foreground colour, the
//! menu button in the background colour - the canvas takes the menu
//! button over its box (`GA_MenuButton`), so the menus stay shut there and
//! open anywhere else. The brush is round or square and 1 to 64 pixels
//! (brush.zig), chosen in the Brush menu or with `[` and `]` - or `<`
//! and `>`, one key on a German keyboard - or an own brush (below).
//! While the pointer is over the picture and no button is down, the
//! brush is shown where it would go down: the window reports the mouse,
//! and the view lays the brush over the rows it makes, never into the
//! picture. The tools, two to a row down the left and in the Tools menu,
//! each but the hand with a key of its own:
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
//!   - gradient (`g`): a drag, shown as a guide line (`shapes.guide`),
//!     lays the foreground at its start shading to the background at its
//!     end over the layer painted, inside what is chosen, with the
//!     brush's opacity and dither - along the drag, or round its start
//!     with Tools' Round Gradient (gradient.zig);
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
//!     again, or dotted freehand when that one puts no brush down;
//!   - the eraser (`E`): the picture made see-through where the brush
//!     goes, by the same settings as paint;
//!   - smudge (`s`): the colours under the brush dragged along the
//!     stroke, in memory of the brush's size while it is made;
//!   - the rectangle selection (`R`), the lasso (`L`) and the magic wand
//!     (`w`), which choose what may be painted (below);
//!   - the hand: the picture moved with the pointer, as Space held does
//!     with any tool;
//!   - zoom (`m`): a click zooms in about where it is, the menu button
//!     out.
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
//! (`PALETTE_Button`); the two are shown above it, the foreground in
//! front, and a click there or on the swap beside them swaps them, as `x`
//! does.
//!
//! **The Image menu** (image.zig) changes every layer: turned, flipped,
//! cropped to the selection, trimmed, scaled, or put on a canvas of
//! another size. Each layer and its mask is made anew at the new size and
//! swapped in, the old ones held by the history - one step to undo - and
//! the memory beside the layers (`kept`, the mask, the composite) is
//! made again for the size (`fitSides`), on undo and redo too
//! (`followSize`). Flatten makes the layers one as they show.
//!
//! **Effects, scaling and transforms** are paintfx.library's, Paint's
//! own in its drawer like paintio, opened by its path the first time
//! one is wanted (`paintFX`): Picture Size scales each layer through
//! `ScalePixels`. The Effects window (`effects`, modal) makes the layer
//! painted anew from `kept` each time its sliders settle - the colours
//! (`AdjustColours`), then blur and sharpening - cut to the selection
//! and shown; OK records it as any change is, Cancel copies `kept` back.
//! Free Transform (`freeTransform`) lifts what shows of the layer painted
//! - of what is chosen of it - into a buffer of its own and leaves its
//! place as a cut does (`leaveBehind`, from `kept`); its shape
//! (transform.zig) changes with each press, and `showTransform` lays the
//! lifted pixels over what is left through `TransformPixels`: the
//! nearest pixel while it is dragged, mixed when it is taken. The view
//! draws its frame. A transform is ended as a shape is: `endShape` takes
//! it, one change recorded over where it was and where it went;
//! `cancelShape` - Escape, Undo - copies `kept` back.
//!
//! **The palette** (palette.zig). The Palette menu edits it in a window
//! of its own (`editPalette`, modal): a colour by red, green and blue,
//! hue, saturation and value, or hex text, and a run spread, a colour
//! copied or two swapped; OK takes the colours, and with Change the
//! Pixels Too first makes the pixels of each colour changed its new one
//! in every layer, a step to undo. It also takes the colours what is
//! shown uses most, a preset, or a file - a palette's text, or the
//! palette of a picture or project - and writes its text. Reduce makes
//! the layer painted of its colours alone, plain or dithered
//! (`palette.reduceRow`). Its ranges cycle on Tab: timer.device's beat
//! (`beat`) turns each as far as the E-clock's time since the start
//! takes it, and the view shows the colours turned (`View.turned`); the
//! pixels stay. A project keeps the ranges.
//!
//! **Selections** (selection.zig). The rectangle selection (`R`), the
//! lasso (`L`) and the magic wand (`w`) choose pixels - in place of what
//! was chosen, or with Shift added to it, with Alt taken from it - as do
//! the Selection menu's Select items. While something is chosen it is a
//! stencil: a change is cut to it before it is kept for undoing, and a
//! stroke or a shape on its way is shown cut to it (`flush`). Its edge is
//! drawn by the view in dashes (the zoom bar's Outline turns that off),
//! and a choice being made is outlined from the scratch mask, which is
//! the paint mask's memory - a choice and a change are never made at
//! once. What is chosen can be copied or cut to a new layer, or copied to
//! the brush.
//!
//! **Layers.** The Layer menu puts a new one in over the one painted
//! (see-through, or a copy), deletes, renames, moves, merges down and
//! flips it. Every tool works on the layer painted, but pick colour,
//! which takes what is shown; Clear and the cut leave the bottom layer
//! the background colour and any other see-through.
//!
//! **Masks.** A layer may have a mask (layers.zig): greys that say how
//! much of each pixel shows. While it is painted (`painting_mask`),
//! `picture` is the mask, and the history names it by the layer's id
//! with `mask_id` added, so every tool, the stencil and undo work on it
//! unchanged. A mask put on, applied or deleted is a step to undo; the
//! zoom bar's Mask shows it in the view in place of the composite. A
//! project keeps it as a byte a pixel, how much it shows.
//!
//! **Files** go through paintio.library, which is Paint's own and lies in
//! its drawer: it is opened by its path, `PROGDIR:Libs/paintio.library`,
//! the first time a file is opened or saved, and closed at the end. Open...
//! (and FILE at the start) reads a project or any picture datatypes
//! reads, and takes its palette when it has one. Save As...
//! writes what the name ends in: `.png` a PNG, `.iff`, `.ilbm` or `.lbm`
//! an ILBM, both of what is shown, anything else a project (`FORM PNTG`),
//! which keeps every layer - its name, opacity, blend mode, whether it
//! is shown and its mask - the layer painted and the palette; Save writes the file again in its form, or asks for a
//! name when the picture came from a format Paint does not write. The
//! window's title, or the screen's bar on a screen of its own, names the
//! file, with a `*` before it while it has changes.
//!
//! **Undo.** Every stroke, clear and so on is kept for undoing and redoing
//! (history.zig), as far back as a block of three pictures' worth - or half
//! the memory free, when that is less - reaches; the oldest go first. A
//! layer put in, taken out or moved is a step too: a layer taken out is
//! held by the history until its step is gone, and a merge down is the
//! lower layer's pixels and the upper one taken out, undone as one.
//!
//! The menus, with their keys (pressed with the right command key):
//!
//!   File      New... (N), Open... (O), Save (S), Save As... (A), Quit (Q)
//!   Edit      Undo (Z), Redo (Y), Swap Colours, Clear (K)
//!   Image     Rotate (90° Clockwise, 90° Anticlockwise, 180°), Flip
//!             Horizontally, Flip Vertically, Crop to the Selection,
//!             Trim, Picture Size... (R), Canvas Size..., Flatten
//!   Tools     the tools, Filled Shapes, Round Gradient
//!   Layer     New Layer (L), Duplicate (D), Delete, Rename..., Move Up,
//!             Move Down, Merge Down (M), Flip Horizontally, Flip
//!             Vertically, Effects... (F), Free Transform (T), Add Mask
//!             (Show All, Hide All, Show the Selection), Paint the Mask
//!             (E), Apply the Mask, Delete the Mask
//!   Selection Select (All, Pixels of the Layer, Pixels of the Colour,
//!             See-through Pixels, Pixels Not in the Palette), Deselect,
//!             Invert, Copy to Layer, Cut to Layer, Copy to Brush (B)
//!   Brush     Round, Square, Own Brush, Size, Smaller ([), Larger (]),
//!             Own Colours, One Colour, Flip Horizontally, Flip
//!             Vertically, Turn Right, Open Brush..., Save Brush...
//!   Palette   Edit... (P), From the Picture, Presets (Paint's Own,
//!             Greys, Spectrum, Pastel, Earth), Reduce (No Dither,
//!             Ordered Dither, Error Diffusion), Cycle Colours (Tab),
//!             Open Palette..., Save Palette...
//!   View      Zoom In (+), Zoom Out (-), Actual Size (1), Zoom to Fit,
//!             Grid (G), Own Screen
//!   Help      About Paint...
//!
//! Without a menu key: `+` and `-` zoom, `[` and `]` (or `<` and `>`)
//! size the brush, `h`, `v` and `z` flip and turn an own brush, `x` swaps
//! the colours, the tools' letters choose them,
//! Return ends a shape and Escape puts it away, the cursor keys move the
//! picture, and Space held lets a drag move it.
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
const timer = sdk.devices.timer;
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
const ch = sdk.gadgets.chooser;
const sl = sdk.gadgets.slider;
const cw = sdk.gadgets.colorwheel;
const gs = sdk.gadgets.gradientslider;
const lb = sdk.gadgets.listbrowser;
const cb = sdk.gadgets.checkbox;
const ig = sdk.gadgets.integer;
const sg = sdk.gadgets.string;
const gfo = sdk.gadgets.getfont;
const command = sdk.images.command;
const prefs = sdk.prefs;
const paintio = sdk.paintio;
const paintfx = sdk.paintfx;
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
const PaintFXBase = sdk.interface.paintfx.PaintFXBase;
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
const layers_zig = @import("layers.zig");
const palette_zig = @import("palette.zig");
const gradient_zig = @import("gradient.zig");
const transform_zig = @import("transform.zig");
const image_zig = @import("image.zig");
const selection_zig = @import("selection.zig");
const Picture = picture_zig.Picture;
const Pixel = picture_zig.Pixel;
const Area = picture_zig.Area;
const Brush = brush_zig.Brush;
const History = history_zig.History;
const Stack = layers_zig.Stack;
const Layer = layers_zig.Layer;
const Blend = layers_zig.Blend;
const Selection = selection_zig.Selection;
const Scratch = selection_zig.Scratch;
const Outline = selection_zig.Outline;
const View = view_zig.View;
const Point = shapes.Point;

pub const COMMAND_NAME = "Paint";
const VERSION = "1.13";
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
const ID_ZOOM = 5;
// The side panel.
const ID_SHAPE = 6;
const ID_SIZE = 7;
const ID_WHEEL = 8;
const ID_BRIGHTNESS = 9;
/// The brush's settings: softness, opacity, flow, jitter and rotation on
/// sliders, in this order, and dither.
const ID_SETTING = 11;
const ID_DITHER = 16;
/// A section's button: this and the section's place.
const ID_SECTION = 30;
// The Layers section: the list, the opacity, the blend mode, and the
// buttons that add and delete.
const ID_LAYERS = 40;
const ID_LAYER_OPACITY = 41;
const ID_BLEND = 42;
const ID_LAYER_ADD = 43;
const ID_LAYER_DELETE = 44;
// The rename window's name.
const ID_NAME = 26;
/// The zoom bar's box that shows the outline of what is chosen.
const ID_OUTLINE = 28;
/// The zoom bar's box that shows the mask of the layer painted.
const ID_SHOW_MASK = 29;
// The palette editor: its colours, its sliders - red, green, blue, hue,
// saturation, value - the hex text, the box that changes the pixels too,
// and the buttons that spread, copy and swap.
const ID_EDIT_PALETTE = 60;
const ID_EDIT_SLIDER = 61;
const ID_EDIT_HEX = 67;
const ID_EDIT_PIXELS = 68;
const ID_EDIT_SPREAD = 69;
const ID_EDIT_COPY = 70;
const ID_EDIT_SWAP = 71;
// Its range: which of them, the button that sets it, its speed, and the
// box that turns it backwards.
const ID_EDIT_RANGE = 72;
const ID_EDIT_SET_RANGE = 73;
const ID_EDIT_SPEED = 74;
const ID_EDIT_BACKWARDS = 75;
// The new picture's window.
const ID_WIDTH = 20;
const ID_HEIGHT = 21;
/// Canvas Size's choice of where the picture goes.
const ID_PLACE = 76;

/// The places Canvas Size puts the picture, by rows from the top left.
const place_texts = [_]Id{
    .MSG_PLACE_TOP_LEFT,    .MSG_PLACE_TOP,    .MSG_PLACE_TOP_RIGHT,
    .MSG_PLACE_LEFT,        .MSG_PLACE_MIDDLE, .MSG_PLACE_RIGHT,
    .MSG_PLACE_BOTTOM_LEFT, .MSG_PLACE_BOTTOM, .MSG_PLACE_BOTTOM_RIGHT,
};
// Picture Size's window: how the pixels are scaled, and whether one
// side follows the other.
const ID_SCALING = 77;
const ID_KEEP = 78;
const scale_texts = [_]Id{ .MSG_SCALE_SMOOTH, .MSG_SCALE_HARD };
// The Effects window: Reset, and its sliders from ID_EFFECT on.
const ID_EFFECT_RESET = 79;
const ID_EFFECT = 80;

/// The Effects window's sliders, in its order.
const Effect = enum { brightness, contrast, saturation, hue, blur, sharpen, texture, dehaze, sepia, invert, cyan_red, magenta_green, yellow_blue };
const EffectSlider = struct { label: Id, least: i32, most: i32 };
const effect_sliders = [_]EffectSlider{
    .{ .label = .MSG_FX_BRIGHTNESS, .least = -100, .most = 100 },
    .{ .label = .MSG_FX_CONTRAST, .least = -100, .most = 100 },
    .{ .label = .MSG_FX_SATURATION, .least = -100, .most = 100 },
    .{ .label = .MSG_FX_HUE, .least = -180, .most = 180 },
    // Its radius in pixels.
    .{ .label = .MSG_FX_BLUR, .least = 0, .most = 50 },
    .{ .label = .MSG_FX_SHARPEN, .least = 0, .most = 100 },
    .{ .label = .MSG_FX_TEXTURE, .least = 0, .most = 100 },
    .{ .label = .MSG_FX_DEHAZE, .least = 0, .most = 100 },
    .{ .label = .MSG_FX_SEPIA, .least = 0, .most = 100 },
    .{ .label = .MSG_FX_INVERT, .least = 0, .most = 100 },
    .{ .label = .MSG_FX_CYAN_RED, .least = -100, .most = 100 },
    .{ .label = .MSG_FX_MAGENTA_GREEN, .least = -100, .most = 100 },
    .{ .label = .MSG_FX_YELLOW_BLUE, .least = -100, .most = 100 },
};
comptime {
    if (effect_sliders.len != @typeInfo(Effect).@"enum".fields.len) @compileError("an effect without its slider");
}
/// What Sharpen and Texture ask of SharpenPixels: a level of Sharpen is
/// twice that many percent over the next pixels, one of Texture that
/// many over a wide blur.
const sharpen_radius = 1;
const texture_radius = 16;
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
/// Space, and a key let go: its code with `raw_released`.
const raw_space = 0x40;
const raw_released = 0x80;

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
    gradient,
    airbrush,
    eraser,
    smudge,
    pick,
    text,
    grab,
    select_box,
    lasso,
    wand,
    hand,
    zoom,

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
    fit,
    about,
    new_layer,
    duplicate_layer,
    delete_layer,
    rename_layer,
    layer_up,
    layer_down,
    merge_down,
    flip_layer_across,
    flip_layer_down,
    select_all,
    select_layer,
    select_colour,
    select_see_through,
    select_not_in_palette,
    deselect,
    invert_selection,
    copy_to_layer,
    cut_to_layer,
    copy_to_brush,
    mask_show_all,
    mask_hide_all,
    mask_selection,
    paint_mask,
    apply_mask,
    delete_mask,
    edit_palette,
    palette_from_picture,
    preset_standard,
    preset_greys,
    preset_spectrum,
    preset_pastel,
    preset_earth,
    open_palette,
    save_palette,
    reduce_plain,
    reduce_ordered,
    reduce_diffused,
    cycle,
    round_gradient,
    image_turn_right,
    image_turn_left,
    image_turn_half,
    image_flip_across,
    image_flip_down,
    crop,
    trim,
    canvas_size,
    flatten,
    picture_size,
    effects,
    free_transform,

    fn id(which: Command) u32 {
        return @intFromEnum(which);
    }

    fn of(value: usize) ?Command {
        if (value < @intFromEnum(Command.new) or value > @intFromEnum(Command.free_transform)) return null;
        return @enumFromInt(value);
    }
};

/// The Size submenu's items have `size_base` and the size's place in
/// `brush_zig.sizes` as their user data.
const size_base = 200;
const size_labels = [_][*:0]const u8{ "1", "2", "3", "4", "6", "8", "12", "16", "24", "32", "48", "64" };
comptime {
    if (size_labels.len != brush_zig.sizes.len) @compileError("a label for every brush size");
}

/// The colours the palette offers to begin with.
const colours = palette_zig.standard;
const black_index = 0;
const white_index = 1;

/// The tools down the left, and the commands with them.
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
    .{ .tool = .gradient, .glyph = command.CMD_GRADIENT, .hint = .MSG_TOOL_GRADIENT, .label = .MSG_MENU_GRADIENT },
    .{ .tool = .airbrush, .glyph = command.CMD_AIRBRUSH, .hint = .MSG_TOOL_AIRBRUSH, .label = .MSG_MENU_AIRBRUSH },
    .{ .tool = .eraser, .glyph = command.CMD_ERASER, .hint = .MSG_TOOL_ERASER, .label = .MSG_MENU_ERASER },
    .{ .tool = .smudge, .glyph = command.CMD_SMUDGE, .hint = .MSG_TOOL_SMUDGE, .label = .MSG_MENU_SMUDGE },
    .{ .tool = .pick, .glyph = command.CMD_PICK_COLOUR, .hint = .MSG_TOOL_PICK, .label = .MSG_MENU_PICK },
    .{ .tool = .text, .glyph = command.CMD_TEXT, .hint = .MSG_TOOL_TEXT, .label = .MSG_MENU_TEXT },
    .{ .tool = .grab, .glyph = command.CMD_GRAB_BRUSH, .hint = .MSG_TOOL_GRAB, .label = .MSG_MENU_GRAB },
    .{ .tool = .select_box, .glyph = command.CMD_SELECT_BOX, .hint = .MSG_TOOL_SELECT_BOX, .label = .MSG_MENU_SELECT_BOX },
    .{ .tool = .lasso, .glyph = command.CMD_LASSO, .hint = .MSG_TOOL_LASSO, .label = .MSG_MENU_LASSO },
    .{ .tool = .wand, .glyph = command.CMD_WAND, .hint = .MSG_TOOL_WAND, .label = .MSG_MENU_WAND },
    .{ .tool = .hand, .glyph = command.CMD_HAND, .hint = .MSG_TOOL_HAND, .label = .MSG_MENU_HAND },
    .{ .tool = .zoom, .glyph = command.CMD_ZOOM_IN, .hint = .MSG_TOOL_ZOOM, .label = .MSG_MENU_ZOOM_TOOL },
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
    .{ .which = .zoom_out, .glyph = command.CMD_ZOOM_OUT, .hint = .MSG_ZOOM_OUT_HINT },
    .{ .which = .zoom_in, .glyph = command.CMD_ZOOM_IN, .hint = .MSG_ZOOM_IN_HINT },
    .{ .which = .fit, .glyph = command.CMD_ZOOM_FIT, .hint = .MSG_FIT_HINT },
    .{ .which = .swap, .glyph = command.CMD_SWAP, .hint = .MSG_SWAP_HINT },
};
const filled_button = 0;
const undo_button = 1;
const redo_button = 2;
/// The first buttons go under the tools; the zoom's above the picture,
/// the swap beside the two colours.
const column_buttons = 3;
const zoom_out_button = 3;
const zoom_in_button = 4;
const fit_button = 5;
const swap_button = 6;

/// The side panel's sections, each a button over its gadgets that folds
/// them away and unfolds them.
const section_names = [_]Id{ .MSG_SECTION_LAYERS, .MSG_SECTION_BRUSH, .MSG_SECTION_COLOUR };
const layers_section = 0;
const brush_section = 1;
const colour_section = 2;

/// The blend modes as the Layers section's chooser lists them, in
/// `Blend`'s order, which is the project file's.
const blend_names = [_]Id{
    .MSG_BLEND_NORMAL,     .MSG_BLEND_ADD,     .MSG_BLEND_MULTIPLY,   .MSG_BLEND_SCREEN, .MSG_BLEND_OVERLAY,
    .MSG_BLEND_DARKEN,     .MSG_BLEND_LIGHTEN, .MSG_BLEND_DODGE,      .MSG_BLEND_BURN,   .MSG_BLEND_HARD_LIGHT,
    .MSG_BLEND_SOFT_LIGHT, .MSG_BLEND_HUE,     .MSG_BLEND_SATURATION, .MSG_BLEND_COLOUR, .MSG_BLEND_LUMINOSITY,
};
comptime {
    if (blend_names.len != Blend.count) @compileError("a name for every blend mode");
    if (@intFromEnum(Blend.luminosity) != paintio.LAYERBLEND_LUMINOSITY or @intFromEnum(Blend.hard_light) != paintio.LAYERBLEND_HARD_LIGHT)
        @compileError("the blend modes in the project file's order");
    if (layers_zig.max_layers != paintio.MAX_LAYERS or layers_zig.name_size != paintio.NAME_SIZE)
        @compileError("a layer as the project file keeps it");
}
/// How many rows of layers the list shows at the least.
const layer_rows_shown = 5;
/// The most corners a lasso keeps; past that every second goes.
const max_lasso = 2048;
/// The largest brush the panel's slider sets.
const panel_brush_max = brush_zig.max_size;

/// The characters of room every slider of the panel gives its level -
/// more than "100%" takes - so their bars are as long as each other.
const level_room = 5;

/// The brush's settings on the panel's sliders: their labels, their
/// ranges, and the format their level is shown in.
const Setting = enum { softness, opacity, flow, jitter, rotation };
const SettingEntry = struct { label: Id, least: u32, most: u32, format: [*:0]const u8 };
const setting_entries = [_]SettingEntry{
    .{ .label = .MSG_SOFTNESS, .least = 0, .most = 100, .format = "%ld%%" },
    .{ .label = .MSG_OPACITY, .least = 1, .most = 100, .format = "%ld%%" },
    .{ .label = .MSG_FLOW, .least = 1, .most = 100, .format = "%ld%%" },
    .{ .label = .MSG_JITTER, .least = 0, .most = 100, .format = "%ld%%" },
    .{ .label = .MSG_ROTATION, .least = 0, .most = 359, .format = "%ld" },
};

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
    .{ .key = 'g', .tool = .gradient },
    .{ .key = 'a', .tool = .airbrush },
    .{ .key = 'E', .tool = .eraser },
    .{ .key = 's', .tool = .smudge },
    .{ .key = 'm', .tool = .zoom },
    .{ .key = 'i', .tool = .pick },
    .{ .key = 't', .tool = .text },
    .{ .key = 'b', .tool = .grab },
    .{ .key = 'R', .tool = .select_box },
    .{ .key = 'L', .tool = .lasso },
    .{ .key = 'w', .tool = .wand },
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

/// An item of the item above it, shown beside it when it is pointed at.
fn subItem(text: Id, which: Command) MenuEntry {
    return .{ .menu = .{ .type = mn.NM_SUB, .label = strings.builtin(text), .user_data = @ptrFromInt(which.id()) }, .text = text };
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
    menuTitle(.MSG_MENU_FILE),
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
    menuTitle(.MSG_MENU_IMAGE),
    .{ .menu = .{ .type = mn.NM_ITEM, .label = strings.builtin(.MSG_MENU_ROTATE) }, .text = .MSG_MENU_ROTATE },
    subItem(.MSG_TURN_RIGHT, .image_turn_right),
    subItem(.MSG_TURN_LEFT, .image_turn_left),
    subItem(.MSG_TURN_HALF, .image_turn_half),
    item(.MSG_MENU_FLIP_ACROSS, null, .image_flip_across),
    item(.MSG_MENU_FLIP_DOWN, null, .image_flip_down),
    bar,
    item(.MSG_MENU_CROP, null, .crop),
    item(.MSG_MENU_TRIM, null, .trim),
    item(.MSG_MENU_PICTURE_SIZE, "R", .picture_size),
    item(.MSG_MENU_CANVAS_SIZE, null, .canvas_size),
    bar,
    item(.MSG_MENU_FLATTEN, null, .flatten),
    menuTitle(.MSG_MENU_TOOLS),
} ++ toolItems() ++ [_]MenuEntry{
    bar,
    toggleItem(.MSG_MENU_FILLED, null, .filled),
    toggleItem(.MSG_MENU_ROUND_GRADIENT, null, .round_gradient),
    menuTitle(.MSG_MENU_LAYER),
    item(.MSG_MENU_NEW_LAYER, "L", .new_layer),
    item(.MSG_MENU_DUPLICATE_LAYER, "D", .duplicate_layer),
    item(.MSG_MENU_DELETE_LAYER, null, .delete_layer),
    item(.MSG_MENU_RENAME_LAYER, null, .rename_layer),
    bar,
    item(.MSG_MENU_LAYER_UP, null, .layer_up),
    item(.MSG_MENU_LAYER_DOWN, null, .layer_down),
    item(.MSG_MENU_MERGE_DOWN, "M", .merge_down),
    bar,
    item(.MSG_MENU_FLIP_ACROSS, null, .flip_layer_across),
    item(.MSG_MENU_FLIP_DOWN, null, .flip_layer_down),
    item(.MSG_MENU_EFFECTS, "F", .effects),
    item(.MSG_MENU_FREE_TRANSFORM, "T", .free_transform),
    bar,
    .{ .menu = .{ .type = mn.NM_ITEM, .label = strings.builtin(.MSG_MENU_ADD_MASK) }, .text = .MSG_MENU_ADD_MASK },
    subItem(.MSG_MENU_MASK_SHOW_ALL, .mask_show_all),
    subItem(.MSG_MENU_MASK_HIDE_ALL, .mask_hide_all),
    subItem(.MSG_MENU_MASK_SELECTION, .mask_selection),
    toggleItem(.MSG_MENU_PAINT_MASK, "E", .paint_mask),
    item(.MSG_MENU_APPLY_MASK, null, .apply_mask),
    item(.MSG_MENU_DELETE_MASK, null, .delete_mask),
    menuTitle(.MSG_MENU_SELECTION),
    .{ .menu = .{ .type = mn.NM_ITEM, .label = strings.builtin(.MSG_MENU_SELECT) }, .text = .MSG_MENU_SELECT },
    subItem(.MSG_MENU_SELECT_ALL, .select_all),
    subItem(.MSG_MENU_SELECT_LAYER, .select_layer),
    subItem(.MSG_MENU_SELECT_COLOUR, .select_colour),
    subItem(.MSG_MENU_SELECT_SEE_THROUGH, .select_see_through),
    subItem(.MSG_MENU_SELECT_NOT_IN_PALETTE, .select_not_in_palette),
    item(.MSG_MENU_DESELECT, null, .deselect),
    item(.MSG_MENU_INVERT, null, .invert_selection),
    bar,
    item(.MSG_MENU_COPY_TO_LAYER, null, .copy_to_layer),
    item(.MSG_MENU_CUT_TO_LAYER, null, .cut_to_layer),
    item(.MSG_MENU_COPY_TO_BRUSH, "B", .copy_to_brush),
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
    menuTitle(.MSG_MENU_PALETTE),
    item(.MSG_MENU_EDIT_PALETTE, "P", .edit_palette),
    item(.MSG_MENU_FROM_PICTURE, null, .palette_from_picture),
    .{ .menu = .{ .type = mn.NM_ITEM, .label = strings.builtin(.MSG_MENU_PRESETS) }, .text = .MSG_MENU_PRESETS },
    subItem(.MSG_PRESET_STANDARD, .preset_standard),
    subItem(.MSG_PRESET_GREYS, .preset_greys),
    subItem(.MSG_PRESET_SPECTRUM, .preset_spectrum),
    subItem(.MSG_PRESET_PASTEL, .preset_pastel),
    subItem(.MSG_PRESET_EARTH, .preset_earth),
    .{ .menu = .{ .type = mn.NM_ITEM, .label = strings.builtin(.MSG_MENU_REDUCE) }, .text = .MSG_MENU_REDUCE },
    subItem(.MSG_DITHER_NONE, .reduce_plain),
    subItem(.MSG_DITHER_ORDERED, .reduce_ordered),
    subItem(.MSG_DITHER_DIFFUSED, .reduce_diffused),
    toggleItem(.MSG_MENU_CYCLE, null, .cycle),
    bar,
    item(.MSG_MENU_OPEN_PALETTE, null, .open_palette),
    item(.MSG_MENU_SAVE_PALETTE, null, .save_palette),
    menuTitle(.MSG_MENU_VIEW),
    item(.MSG_MENU_ZOOM_IN, "+", .zoom_in),
    item(.MSG_MENU_ZOOM_OUT, "-", .zoom_out),
    item(.MSG_MENU_ACTUAL_SIZE, "1", .actual_size),
    item(.MSG_MENU_FIT, null, .fit),
    bar,
    toggleItem(.MSG_MENU_GRID, "G", .grid),
    bar,
    toggleItem(.MSG_MENU_OWN_SCREEN, null, .own_screen),
    menuTitle(.MSG_MENU_HELP),
    item(.MSG_MENU_ABOUT, null, .about),
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
    /// How many layers there are, and which is painted.
    layers: u32,
    current: u32,
    /// Whether anything is chosen.
    selected: bool,
    /// The layer painted has a mask; it is painted in the mask.
    has_mask: bool,
    painting_mask: bool,
    /// The palette cycles.
    cycling: bool,
    round_gradient: bool,
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
    zoom_text: *Object = undefined,
    tool_buttons: [tools.len]*Object = undefined,
    command_buttons: [buttons.len]*Object = undefined,
    /// The side panel, its sections' buttons and what each folds away.
    panel: *Object = undefined,
    section_buttons: [section_names.len]*Object = undefined,
    section_bodies: [section_names.len]*Object = undefined,
    /// The brush's shape and size, and the foreground's wheel and its
    /// brightness.
    shape: *Object = undefined,
    size: *Object = undefined,
    /// The brush's settings' sliders, in `Setting`'s order, and dither.
    setting_sliders: [setting_entries.len]*Object = undefined,
    dither: *Object = undefined,
    wheel: *Object = undefined,
    brightness: *Object = undefined,
    /// The pictures of a section folded and unfolded.
    fold_images: [2]?*Object = .{ null, null },
    /// The Layers section: the list, the opacity, the blend mode, and
    /// the pictures of the eye and of the buttons that add and delete.
    layer_list: *Object = undefined,
    layer_opacity: *Object = undefined,
    blend: *Object = undefined,
    /// The zoom bar's boxes for the outline and the mask.
    outline_box: *Object = undefined,
    show_mask_box: *Object = undefined,
    layer_images: [3]?*Object = .{ null, null, null },
    strip: ?*intuition.Menu = null,
    /// Onto the view's and the colours' pictures.
    view_rp: *RastPort = undefined,
    colours_rp: *RastPort = undefined,
    /// The window's own ground, round the two colours.
    ground: Pixel = 0xFFA0A0A0,
    shown_menus: ?MenuState = null,
    shown_undo: ?[2]bool = null,
    shown_filled: ?bool = null,
    /// What the panel and the zoom bar show, as last set.
    shown_shape: ?u32 = null,
    shown_size: ?u32 = null,
    shown_size_off: ?bool = null,
    shown_colour: ?Pixel = null,
    shown_zoom: ?u32 = null,
    /// The layer painted, its opacity and its blend mode as the Layers
    /// section shows them.
    shown_layer: ?u32 = null,
    shown_layer_opacity: ?u8 = null,
    shown_blend: ?Blend = null,
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
        for (gui.fold_images) |image| ib.DisposeObject(image);
        for (gui.layer_images) |image| ib.DisposeObject(image);
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
    /// What it puts its paint down with, and how far its lines have
    /// walked.
    ink: brush_zig.Ink,
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
    kind: brush_zig.Kind = .paint,
    changes: u32 = 0,

    fn same(mark: GhostMark, other: GhostMark) bool {
        return mark.area.min_x == other.area.min_x and mark.area.min_y == other.area.min_y and
            mark.area.max_x == other.area.max_x and mark.area.max_y == other.area.max_y and
            mark.colour == other.colour and mark.shape == other.shape and mark.size == other.size and
            mark.own == other.own and mark.mode == other.mode and mark.kind == other.kind and mark.changes == other.changes;
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

    /// The layers; the slots for them are AllocVec's, given at the start.
    stack: Stack = .{ .layers = undefined },
    /// The layer being painted: the stack's current one.
    picture: Picture = undefined,
    kept: Picture = undefined,
    history: History = undefined,
    /// How much paint each pixel has had in the change being made, a
    /// byte a pixel (brush.zig's `Ink`).
    mask: []u8 = &.{},
    /// The memory of `kept`, the history, the mask, the composite and the
    /// selection, AllocVec's; null before the first. Each layer has its
    /// own.
    memory: [5]?*anyopaque = @splat(null),
    /// What a change may touch (selection.zig): picture-wide, made when
    /// something is first chosen.
    selection: Selection = .{},
    /// A choice being made, in the mask's memory - which no change uses
    /// while a choice is made.
    scratch: Scratch = .{ .mask = &.{}, .width = 0, .height = 0 },
    /// A choice is being made with the pointer: its outline is shown
    /// rather than the selection's.
    choosing: bool = false,
    choose_how: selection_zig.How = .replace,
    choose_from: Point = .{ 0, 0 },
    /// The keys held as the last message came: Shift adds to what is
    /// chosen, Alt takes from it.
    qualifier: usize = 0,
    /// The lasso's corners, in memory made the first time it is used.
    lasso: []Point = &.{},
    lasso_count: usize = 0,
    /// Whether the outline of what is chosen is shown.
    show_outline: bool = true,
    /// The layer painted is painted in its mask (`picture` is the mask).
    painting_mask: bool = false,
    /// The view shows the mask of the layer painted, when it has one.
    show_mask: bool = false,
    /// What a new layer is called after: one more each time.
    layer_number: u32 = 0,
    /// The Layers section's rows, top layer first, rebuilt when the
    /// layers change (`layers_stale`).
    layer_rows: exec.List = .{},
    layers_stale: bool = true,
    /// The blend modes' names for the chooser.
    blend_labels: [Blend.count:null]?[*:0]const u8 = @splat(null),
    /// The list's columns - the eye, the name - which it reads while it
    /// is there.
    layer_columns: [4]lb.Column = @splat(.{}),
    /// Changed since it was made.
    changed: bool = false,

    tool: Tool = .freehand,
    brush: Brush = .{},
    /// How the brush's paint goes down: opacity, flow, jitter, dither.
    settings: brush_zig.Settings = .{},
    /// The colours a smudge carries along, the brush's box in size, and
    /// their memory, AllocVec's, while one is being made.
    carried: Picture = undefined,
    carried_memory: ?*anyopaque = null,
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
    /// Where a palette was opened from or saved to last.
    palette_path: [path_size:0]u8 = @splat(0),
    /// The palette editor's Change the Pixels Too, kept for the next time.
    recolour_pixels: bool = false,
    /// The palette's ranges, and whether they cycle: how far each has
    /// turned since the E-clock's tick cycling started at, and the colours
    /// shown for theirs.
    ranges: [palette_zig.max_ranges]palette_zig.Range = @splat(.{}),
    cycling: bool = false,
    turns: [palette_zig.max_ranges]u32 = @splat(0),
    cycle_start: u64 = 0,
    turned: palette_zig.Turned = .{},
    /// The beat cycling keeps: timer.device's request, its port, and
    /// whether the request is out.
    clock: timer.TimeRequest = .{},
    clock_port: ?*exec.MsgPort = null,
    clock_out: bool = false,
    /// The gradient tool shades round its drag's start rather than
    /// along it.
    round_gradient: bool = false,
    /// Where Canvas Size puts the picture, 0 to 8 by rows from the top
    /// left: in the middle to begin with.
    canvas_place: u32 = 4,
    /// How Picture Size scales, as last asked.
    scaling: Scaling = .{},
    /// The free transform under way, if one is.
    transforming: ?Transforming = null,
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
    /// paintfx.library, opened the first time an effect, a scale or a
    /// transform wants it.
    fx_lib: ?*exec.Library = null,
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
    /// The zoom as the zoom bar says it.
    zoom_line: [16:0]u8 = @splat(0),
    /// The side panel's sections that are unfolded.
    open_sections: [section_names.len]bool = @splat(true),
    /// The brush's shapes as the panel's chooser lists them.
    shape_labels: [3:null]?[*:0]const u8 = .{ null, null, null },
    /// The brightness slider's colours: the foreground at its brightest,
    /// then black.
    shades: [3]graphics.Pen = .{ 0xFFFFFFFF, 0xFF000000, gs.GRAD_PEN_END },
    /// Space is held: the picture moves under the pointer, as with the
    /// hand.
    space_held: bool = false,
    /// Where a drag of the hand began in the view, and the view's corner
    /// then.
    pan_from: [2]i32 = .{ 0, 0 },
    pan_start: [2]i32 = .{ 0, 0 },

    /// The window's state while it is open.
    fn ui(app: *App) ?*Gui {
        return if (app.gui) |*gui| gui else null;
    }

    // --- the picture ----------------------------------------------------------

    /// A new picture of that size in the background colour, one layer,
    /// the history emptied; the old one stays when there is no memory for
    /// it.
    fn newPicture(app: *App, width: u32, height: u32) bool {
        if (width == 0 or height == 0 or width > max_side or height > max_side) return false;
        const memory = app.sys.AllocVec(Picture.bytesFor(width, height), exec.MEMF_ANY) orelse return false;
        var made = Picture{ .pixels = @ptrCast(@alignCast(memory)), .width = width, .height = height };
        made.fill(app.background);
        if (!app.takePicture(width, height, true)) {
            app.sys.FreeVec(memory);
            return false;
        }
        app.layer_number = 0;
        var layer = Layer{ .picture = made, .memory = memory, .id = app.stack.newId() };
        app.nameLayer(&layer);
        app.stack.insert(0, layer);
        app.showPicture();
        return true;
    }

    /// The memory beside the layers for a picture of that size - to keep
    /// and undo with, the mask, and the composite unless the picture is
    /// `plain` - made, and the old picture given up for it: the stack is
    /// empty then, for the caller to fill, and `showPicture` after. False
    /// when there is no memory for those: the old picture stays.
    fn takePicture(app: *App, width: u32, height: u32, plain: bool) bool {
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
        const fourth = sys.AllocVec(@as(usize, width) * height, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
            sys.FreeVec(third);
            sys.FreeVec(second);
            return false;
        };
        const fifth: ?*anyopaque = if (plain) null else sys.AllocVec(bytes, exec.MEMF_ANY) orelse {
            sys.FreeVec(fourth);
            sys.FreeVec(third);
            sys.FreeVec(second);
            return false;
        };
        app.freePicture();
        app.memory = .{ second, third, fourth, fifth, null };
        app.mask = @as([*]u8, @ptrCast(fourth))[0 .. @as(usize, width) * height];
        app.scratch = .{ .mask = app.mask, .width = width, .height = height };
        app.kept = .{ .pixels = @ptrCast(@alignCast(second)), .width = width, .height = height };
        app.history = .{ .memory = @ptrCast(@alignCast(third)), .size = room, .release = releaseLayer, .context = app };
        app.stack.count = 0;
        app.stack.current = 0;
        app.stack.composite = if (fifth) |memory| Picture{ .pixels = @ptrCast(@alignCast(memory)), .width = width, .height = height } else null;
        return true;
    }

    /// The layers just put in shown from the start: the one painted kept,
    /// nothing changed yet, the view at the top left.
    fn showPicture(app: *App) void {
        if (app.stack.current >= app.stack.count) app.stack.current = app.stack.count - 1;
        app.paintLayer();
        const width = app.picture.width;
        const height = app.picture.height;
        app.changed = false;
        app.stroke = null;
        app.drawing = null;
        app.view.left = 0;
        app.view.top = 0;
        app.view.fit(width, height);
        app.whole = true;
        app.layers_stale = true;
        app.show(app.picture.whole());
    }

    /// The layer the stack has as its current one made the one painted -
    /// its mask when that is painted and it has one - and `kept` a copy
    /// of it.
    fn paintLayer(app: *App) void {
        const layer = app.stack.currentLayer();
        if (layer.mask == null) app.painting_mask = false;
        app.picture = if (app.painting_mask) layer.mask.? else layer.picture;
        app.kept.copyArea(&app.picture, app.picture.whole());
    }

    /// The id the history knows what is painted by: the layer's, or its
    /// mask's.
    fn paintedId(app: *App) u32 {
        const id = app.stack.currentLayer().id;
        return if (app.painting_mask) id | layers_zig.mask_id else id;
    }

    /// A layer's memory given back, its mask's with it.
    fn freeLayer(app: *App, layer: Layer) void {
        app.sys.FreeVec(layer.memory);
        if (layer.mask_memory) |memory| app.sys.FreeVec(memory);
    }

    /// The composite made when the stack needs one first: false, said in
    /// a requester, when there is no memory for it.
    fn haveComposite(app: *App) bool {
        if (app.stack.composite != null) return true;
        const memory = app.sys.AllocVec(Picture.bytesFor(app.picture.width, app.picture.height), exec.MEMF_ANY) orelse {
            app.tell(.MSG_NO_LAYER);
            return false;
        };
        app.memory[3] = memory;
        app.stack.composite = .{ .pixels = @ptrCast(@alignCast(memory)), .width = app.picture.width, .height = app.picture.height };
        return true;
    }

    /// A new layer called "Layer" and the next number.
    fn nameLayer(app: *App, layer: *Layer) void {
        app.layer_number += 1;
        var name: [layers_zig.name_size]u8 = undefined;
        const made = app.text.format(&name, .MSG_LAYER_NAME, .{@as(i64, app.layer_number)});
        layer.setName(made[0..@min(made.len, name.len)]);
    }

    /// The layers, the memory beside them and the history given back.
    fn freePicture(app: *App) void {
        if (app.memory[1] != null) app.history.clear();
        for (app.stack.all()) |layer| app.freeLayer(layer);
        app.stack.count = 0;
        app.stack.composite = null;
        app.painting_mask = false;
        app.selection = .{};
        app.choosing = false;
        for (&app.memory) |*memory| {
            if (memory.*) |block| app.sys.FreeVec(block);
            memory.* = null;
        }
    }

    /// A change of `area` made to the layer painted: kept for undoing,
    /// and shown.
    fn changedArea(app: *App, area: Area) void {
        if (area.isEmpty()) return;
        app.changed = true;
        app.recordChange(area);
        app.show(area);
    }

    /// What a change did to the layer painted, cut to what is chosen,
    /// kept for undoing; said in a requester when it was too large.
    fn recordChange(app: *App, area: Area) void {
        app.selection.stencil(&app.picture, &app.kept, area);
        app.recordWhole(area);
    }

    /// What a change did to the layer painted kept for undoing as it is,
    /// whatever is chosen.
    fn recordWhole(app: *App, area: Area) void {
        if (!app.history.record(app.paintedId(), &app.picture, &app.kept, area)) app.tell(.MSG_NO_UNDO);
    }

    /// Memory for the selection, made the first time something is
    /// chosen; false, said in a requester, when there is none.
    fn haveSelection(app: *App) bool {
        if (app.selection.mask.len != 0) return true;
        const bytes = @as(usize, app.picture.width) * app.picture.height;
        const memory = app.sys.AllocVec(bytes, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
            app.tell(.MSG_NO_SELECTION);
            return false;
        };
        app.memory[4] = memory;
        app.selection = .{ .mask = @as([*]u8, @ptrCast(memory))[0..bytes], .width = app.picture.width, .height = app.picture.height };
        return true;
    }

    /// What an undo or a redo did shown, and the layer painted followed:
    /// `painted` was its id before.
    fn applied(app: *App, change: history_zig.Change, painted: u32) void {
        app.changed = true;
        const was_mask = app.painting_mask;
        if (change.painted_mask) |mask| app.painting_mask = mask;
        if (change.layers or app.stack.currentLayer().id != painted or app.painting_mask != was_mask) {
            app.paintLayer();
            app.layers_stale = true;
        } else {
            app.kept.copyArea(&app.picture, change.area);
        }
        app.show(change.area);
    }

    /// What a cleared or cut area of the layer painted becomes: the
    /// background colour at the bottom, see-through above it; in a mask,
    /// black, which hides.
    fn emptyColour(app: *const App) Pixel {
        if (app.painting_mask) return 0xFF00_0000;
        return if (app.stack.current == 0) app.background else 0;
    }

    // --- what is chosen ---------------------------------------------------------

    /// How a choice made now meets what is chosen: Shift held adds to it,
    /// Alt takes from it, otherwise it takes its place.
    fn howWanted(app: *const App) selection_zig.How {
        if (app.qualifier & (ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT) != 0) return .add;
        if (app.qualifier & (ie.IEQUALIFIER_LALT | ie.IEQUALIFIER_RALT) != 0) return .take;
        return .replace;
    }

    /// A choice begun with the pointer: false when there is no memory
    /// for it.
    fn beginChoice(app: *App, at: Point) bool {
        if (!app.haveSelection()) return false;
        app.choosing = true;
        app.choose_how = app.howWanted();
        app.choose_from = at;
        // What is chosen is not outlined while the new choice is.
        app.show(app.selection.box);
        return true;
    }

    /// The choice being made laid into what is chosen - a click, which
    /// chooses nothing, takes its place by nothing - and shown.
    fn endChoice(app: *App, click: bool) void {
        app.choosing = false;
        const was = app.selection.box.add(app.scratch.box);
        if (click and app.choose_how == .replace) {
            app.scratch.empty();
            app.selection.clear();
        } else {
            app.selection.take(&app.scratch, app.choose_how);
        }
        app.show(was.add(app.selection.box));
    }

    /// The rectangle from where the button went down to `at` chosen, as
    /// it is dragged; let go, it is laid into what is chosen.
    fn chooseBoxTo(app: *App, at: Point, first: bool, final: bool) void {
        if ((first or !app.choosing) and !app.beginChoice(at)) return;
        const was = app.scratch.box;
        app.scratch.rectangle(shapes.areaOf(app.choose_from, at));
        app.show(was.add(app.scratch.box));
        if (final) app.endChoice(at[0] == app.choose_from[0] and at[1] == app.choose_from[1]);
    }

    /// The lasso drawn on to `at`, its shape - closed straight back to
    /// where it began - chosen as it goes; let go, laid into what is
    /// chosen.
    fn lassoTo(app: *App, at: Point, first: bool, final: bool) void {
        if (first or !app.choosing) {
            if (!app.haveLasso() or !app.beginChoice(at)) return;
            app.lasso_count = 0;
        }
        const points = app.lasso;
        if (app.lasso_count == 0 or points[app.lasso_count - 1][0] != at[0] or points[app.lasso_count - 1][1] != at[1]) {
            // Full, every second corner let go.
            if (app.lasso_count == points.len) {
                var kept: usize = 0;
                var place: usize = 0;
                while (place < points.len) : (place += 2) {
                    points[kept] = points[place];
                    kept += 1;
                }
                app.lasso_count = kept;
            }
            points[app.lasso_count] = at;
            app.lasso_count += 1;
        }
        const was = app.scratch.box;
        app.scratch.polygon(points[0..app.lasso_count]);
        app.show(was.add(app.scratch.box));
        if (final) app.endChoice(app.lasso_count < 3);
    }

    /// Memory for the lasso's corners, made the first time; false, said
    /// in a requester, when there is none.
    fn haveLasso(app: *App) bool {
        if (app.lasso.len != 0) return true;
        const memory = app.sys.AllocVec(max_lasso * @sizeOf(Point), exec.MEMF_ANY) orelse {
            app.tell(.MSG_NO_SELECTION);
            return false;
        };
        app.lasso = @as([*]Point, @ptrCast(@alignCast(memory)))[0..max_lasso];
        return true;
    }

    /// The pixels of the colour at `at` in the layer painted, joined to
    /// it, chosen.
    fn wandAt(app: *App, at: Point) void {
        if (!app.haveSelection()) return;
        const memory = app.sys.AllocVec(first_seeds * @sizeOf(fill_zig.Seed), exec.MEMF_ANY) orelse {
            app.tell(.MSG_CHOICE_SHORT);
            return;
        };
        var seeds = fill_zig.Seeds{ .items = @ptrCast(@alignCast(memory)), .capacity = first_seeds, .more = moreSeeds, .context = app.sys };
        const whole = app.scratch.wand(&app.picture, at[0], at[1], &seeds);
        app.sys.FreeVec(@ptrCast(seeds.items));
        app.choose_how = app.howWanted();
        app.endChoice(false);
        if (!whole) app.tell(.MSG_CHOICE_SHORT);
    }

    /// Every pixel chosen.
    fn selectAll(app: *App) void {
        if (!app.haveSelection()) return;
        app.selection.all();
        app.show(app.picture.whole());
    }

    /// The pixels of the layer painted chosen by what they are: as far as
    /// they are there, the foreground's, as far as they are see-through,
    /// or those of no colour in the palette.
    fn selectBy(app: *App, which: enum { layer, colour, see_through, not_in_palette }) void {
        if (!app.haveSelection()) return;
        switch (which) {
            .layer => app.scratch.alpha(&app.picture, false),
            .colour => app.scratch.colour(&app.picture, app.foreground),
            .see_through => app.scratch.alpha(&app.picture, true),
            .not_in_palette => app.scratch.notIn(&app.picture, &app.palette),
        }
        app.choose_how = .replace;
        app.endChoice(false);
    }

    /// Nothing chosen: every pixel may change.
    fn deselect(app: *App) void {
        const was = app.selection.box;
        app.selection.clear();
        app.show(was);
    }

    /// What is chosen let go and what is not chosen.
    fn invertSelection(app: *App) void {
        if (!app.haveSelection()) return;
        const was = app.selection.box;
        app.selection.invert();
        app.show(was.add(app.selection.box));
    }

    /// What is chosen of the layer painted put in a new layer over it,
    /// and painted - cut, it is taken from the layer it was in, which
    /// undoing puts back in the same step.
    fn selectionToLayer(app: *App, cut: bool) void {
        if (!app.selection.any() or app.stack.count >= layers_zig.max_layers or !app.haveComposite()) return;
        const width = app.picture.width;
        const height = app.picture.height;
        const memory = app.sys.AllocVec(Picture.bytesFor(width, height), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
            app.tell(.MSG_NO_LAYER);
            return;
        };
        var layer = Layer{ .picture = .{ .pixels = @ptrCast(@alignCast(memory)), .width = width, .height = height }, .memory = memory, .id = app.stack.newId() };
        app.nameLayer(&layer);
        const box = app.selection.box;
        const empty = app.emptyColour();
        const from: usize = @intCast(box.min_x);
        const to: usize = @intCast(box.max_x);
        var y: u32 = @intCast(box.min_y);
        while (y < box.max_y) : (y += 1) {
            const parts = app.selection.mask[@as(usize, y) * width ..][from..to];
            for (parts, app.picture.row(y)[from..to], layer.picture.row(y)[from..to]) |part, *pixel, *taken| {
                if (part == 0) continue;
                taken.* = selection_zig.partOf(pixel.*, part);
                if (cut) pixel.* = selection_zig.takenFrom(pixel.*, part, empty);
            }
        }
        var joined = false;
        if (cut) {
            if (app.history.remember(app.paintedId(), &app.kept, box, false)) joined = true else app.tell(.MSG_NO_UNDO);
            app.kept.copyArea(&app.picture, box);
        }
        const place = app.stack.current + 1;
        app.stack.insert(place, layer);
        app.stack.current = place;
        if (!app.history.layerIn(&app.stack, place, joined)) app.tell(.MSG_NO_UNDO);
        app.layersChanged();
    }

    /// What is chosen of the layer painted made the own brush, in use.
    fn selectionToBrush(app: *App) void {
        if (!app.selection.any()) return;
        const box = app.selection.box;
        const memory = app.brushMemory(box.width(), box.height()) orelse return;
        var made = Picture{ .pixels = @ptrCast(@alignCast(memory)), .width = box.width(), .height = box.height() };
        const from: usize = @intCast(box.min_x);
        const to: usize = @intCast(box.max_x);
        var y: u32 = 0;
        while (y < made.height) : (y += 1) {
            const at_y = @as(usize, y) + @as(usize, @intCast(box.min_y));
            const parts = app.selection.mask[at_y * app.picture.width ..][from..to];
            for (made.row(y), parts, app.picture.row(@intCast(at_y))[from..to]) |*into, part, pixel| into.* = selection_zig.partOf(pixel, part);
        }
        app.takeBrush(memory, made.width, made.height);
        // A tool that puts the brush down.
        switch (app.tool) {
            .freehand, .dots, .line, .curve => {},
            .rectangle, .ellipse, .polygon => if (app.filled) app.chooseTool(.dots),
            else => app.chooseTool(.dots),
        }
    }

    // --- the layers -------------------------------------------------------------

    /// A layer put in over the one painted and painted: see-through, or
    /// a copy of the one painted.
    fn addLayer(app: *App, copy: bool) void {
        if (app.stack.count >= layers_zig.max_layers or !app.haveComposite()) return;
        const width = app.picture.width;
        const height = app.picture.height;
        const memory = app.sys.AllocVec(Picture.bytesFor(width, height), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
            app.tell(.MSG_NO_LAYER);
            return;
        };
        var layer = Layer{ .picture = .{ .pixels = @ptrCast(@alignCast(memory)), .width = width, .height = height }, .memory = memory, .id = app.stack.newId() };
        if (copy) {
            const from = app.stack.currentLayer();
            if (from.mask) |*mask| {
                const mask_memory = app.sys.AllocVec(Picture.bytesFor(width, height), exec.MEMF_ANY) orelse {
                    app.sys.FreeVec(memory);
                    app.tell(.MSG_NO_LAYER);
                    return;
                };
                layer.mask = .{ .pixels = @ptrCast(@alignCast(mask_memory)), .width = width, .height = height };
                layer.mask.?.copyArea(mask, mask.whole());
                layer.mask_memory = mask_memory;
            }
            layer.picture.copyArea(&from.picture, from.picture.whole());
            layer.opacity = from.opacity;
            layer.blend = from.blend;
            layer.shown = from.shown;
            var name: [layers_zig.name_size]u8 = undefined;
            const made = app.text.format(&name, .MSG_LAYER_COPY, .{@as([*:0]const u8, @ptrCast(&from.name))});
            layer.setName(made[0..@min(made.len, name.len)]);
        } else {
            app.nameLayer(&layer);
        }
        const place = app.stack.current + 1;
        app.stack.insert(place, layer);
        app.stack.current = place;
        if (!app.history.layerIn(&app.stack, place, false)) app.tell(.MSG_NO_UNDO);
        app.layersChanged();
    }

    /// The layer painted taken out, the one under it painted; never the
    /// last.
    fn deleteLayer(app: *App) void {
        if (app.stack.count <= 1) return;
        const place = app.stack.current;
        const layer = app.stack.remove(place);
        if (!app.history.layerOut(layer, place, false)) {
            app.freeLayer(layer);
            app.tell(.MSG_NO_UNDO);
        }
        app.layersChanged();
    }

    /// The layer at `from` moved to `to`, and painted.
    fn moveLayer(app: *App, from: u32, to: u32) void {
        if (from == to or from >= app.stack.count or to >= app.stack.count) return;
        app.stack.move(from, to);
        app.stack.current = to;
        if (!app.history.moved(from, to, false)) app.tell(.MSG_NO_UNDO);
        app.layersChanged();
    }

    /// The layer painted laid into the one under it as it shows over it
    /// - through its mask, nothing when it is hidden - and taken out; one
    /// step to undo. The one under keeps its own opacity and blend mode;
    /// its mask, when something is laid in, is laid into it first, so
    /// that it does not hide what comes from above.
    fn mergeDown(app: *App) void {
        const place = app.stack.current;
        if (place == 0) return;
        const upper = app.stack.layers[place];
        const lower = &app.stack.layers[place - 1];
        const area = if (upper.shown and upper.opacity != 0) coveredArea(&upper.picture) else Area{};
        // The lower layer's pixels kept, its mask taken off, then the
        // upper one taken out, joined to those; with nothing to lay in,
        // the taking out alone.
        const joined = !area.isEmpty();
        const lower_masked = joined and lower.mask != null;
        const kept_area = if (lower_masked) lower.picture.whole() else area;
        var kept = !joined or app.history.remember(lower.id, &lower.picture, kept_area, false);
        if (lower_masked) {
            maskInto(&lower.picture, &lower.mask.?);
            const mask = lower.mask.?;
            const mask_memory = lower.mask_memory.?;
            lower.mask = null;
            lower.mask_memory = null;
            if (!kept or !app.history.maskOut(lower.id, mask, mask_memory, true)) {
                app.sys.FreeVec(mask_memory);
                kept = false;
            }
        }
        if (joined) {
            var y: u32 = @intCast(area.min_y);
            const from: usize = @intCast(area.min_x);
            const to: usize = @intCast(area.max_x);
            while (y < area.max_y) : (y += 1) {
                const mask_row: ?[]const Pixel = if (upper.mask) |*mask| mask.row(y)[from..to] else null;
                layers_zig.blendRow(lower.picture.row(y)[from..to], upper.picture.row(y)[from..to], mask_row, upper.blend, upper.opacity);
            }
        }
        const taken = app.stack.remove(place);
        if (!kept or !app.history.layerOut(taken, place, joined)) {
            app.freeLayer(taken);
            app.tell(.MSG_NO_UNDO);
        }
        app.layersChanged();
    }

    // --- the palette ------------------------------------------------------------

    /// The palette's first colours made `given`, and shown.
    fn setPalette(app: *App, given: []const Pixel) void {
        for (app.palette[0..given.len], given) |*colour, made| colour.* = made | 0xFF00_0000;
        app.changed = true;
        app.showPalette();
        app.retune();
    }

    /// The palette made the colours what is shown uses most; a requester
    /// says when there is no memory to count them.
    fn paletteFromPicture(app: *App) void {
        const memory = app.sys.AllocVec(palette_zig.bins * @sizeOf(u32), exec.MEMF_ANY) orelse {
            app.tell(.MSG_NO_COUNT);
            return;
        };
        defer app.sys.FreeVec(memory);
        const counts = @as([*]u32, @ptrCast(@alignCast(memory)))[0..palette_zig.bins];
        app.stack.compose(app.picture.whole());
        const shown = app.stack.shown();
        var found: palette_zig.Palette = undefined;
        const count = palette_zig.mostUsed(shown.pixels[0 .. @as(usize, shown.width) * shown.height], counts, &found);
        if (count != 0) app.setPalette(found[0..count]);
    }

    /// A palette read from a file: a palette's text, or the palette of a
    /// picture or a project that has one.
    fn openPalette(app: *App) void {
        var name: [path_size:0]u8 = undefined;
        if (!app.askFile(app.text.get(.MSG_OPEN_PALETTE_TITLE), false, &app.palette_path, &name)) return;
        const dl = app.dl;
        const file = dl.Open(&name, dos.MODE_OLDFILE) orelse {
            app.tellFault(.MSG_NO_OPEN, &name, dl.IoErr());
            return;
        };
        var text: [palette_text_size]u8 = undefined;
        const got = dl.Read(file, &text, text.len);
        _ = dl.Close(file);
        var found: palette_zig.Palette = undefined;
        var count: usize = 0;
        if (got > 0 and palette_zig.isText(text[0..@intCast(got)])) count = palette_zig.fromText(text[0..@intCast(got)], &found);
        if (count == 0) {
            const pio = app.paintIO() orelse return;
            var project = paintio.Project{};
            const failure = pio.LoadProject(&name, &project);
            if (failure != 0) {
                app.tellFault(.MSG_NO_OPEN, &name, failure);
                return;
            }
            defer pio.FreeProject(&project);
            count = @min(project.palette_count, found.len);
            @memcpy(found[0..count], project.palette[0..count]);
        }
        if (count == 0) {
            app.tellName(.MSG_NO_PALETTE, &name);
            return;
        }
        app.setPalette(found[0..count]);
        app.palette_path = name;
    }

    /// The palette written to a file as text, a colour a line.
    fn savePalette(app: *App) void {
        var name: [path_size:0]u8 = undefined;
        if (!app.askFile(app.text.get(.MSG_SAVE_PALETTE_TITLE), true, &app.palette_path, &name)) return;
        var text: [palette_zig.size * 7]u8 = undefined;
        const length: isize = @intCast(palette_zig.toText(&app.palette, &text));
        const dl = app.dl;
        const file = dl.Open(&name, dos.MODE_NEWFILE) orelse {
            app.tellFault(.MSG_NO_SAVE_PALETTE, &name, dl.IoErr());
            return;
        };
        var failure: i32 = if (dl.Write(file, &text, length) != length) dl.IoErr() else 0;
        if (!dl.Close(file) and failure == 0) failure = dl.IoErr();
        if (failure != 0) {
            _ = dl.DeleteFile(&name);
            app.tellFault(.MSG_NO_SAVE_PALETTE, &name, failure);
            return;
        }
        app.palette_path = name;
    }

    /// The palette edited in a window of its own. A colour picked from
    /// the 32 is changed by its red, green and blue, its hue, saturation
    /// and value, or its hex text; Spread, Copy and Swap act between it
    /// and the next one picked. OK takes the colours - and with Change the
    /// Pixels Too makes the pixels of each colour changed the new one, a
    /// step to undo - Cancel leaves them.
    fn editPalette(app: *App) void {
        const gui = app.ui() orelse return;
        const sys = app.sys;
        const string_lib = sys.OpenLibrary(sg.STRING_LIBRARY, 0) orelse return;
        defer sys.CloseLibrary(string_lib);
        const ib = app.ib;
        var editor = Editor{ .colours = app.palette, .chosen = @min(app.foreground_index, palette_zig.size - 1), .ranges = app.ranges };

        var made = Builder{ .ib = ib };
        const swatches = made.take(ib.NewObjectTagList(null, pa.PALETTE_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_EDIT_PALETTE },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = pa.PALETTE_ColorTable, .data = @intFromPtr(&editor.colours) },
            .{ .tag = pa.PALETTE_NumColors, .data = palette_zig.size },
            .{ .tag = pa.PALETTE_Color, .data = editor.chosen },
            .{},
        }));
        var sliders: [editor_sliders.len]?*Object = undefined;
        for (&sliders, editor_sliders, 0..) |*slider, entry, place| slider.* = made.take(ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_EDIT_SLIDER + place },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
            .{ .tag = sl.SLIDER_Min, .data = 0 },
            .{ .tag = sl.SLIDER_Max, .data = entry.most },
            .{ .tag = sl.SLIDER_LevelFormat, .data = @intFromPtr("%ld") },
            .{ .tag = sl.SLIDER_LevelPlace, .data = sl.SLIDER_PLACE_RIGHT },
            .{ .tag = sl.SLIDER_MaxLevelLen, .data = 3 },
            .{},
        }));
        _ = palette_zig.hexText(editor.colours[editor.chosen], &editor.hex);
        const hex_field = made.take(ib.NewObjectTagList(null, sg.STRING_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_EDIT_HEX },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = gc.STRINGA_MaxChars, .data = editor.hex.len },
            .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(&editor.hex) },
            .{},
        }));
        const pixels_box = made.take(ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_EDIT_PIXELS },
            .{ .tag = cb.CHECKBOX_Checked, .data = @intFromBool(app.recolour_pixels) },
            .{},
        }));
        const range_choice = made.take(ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_EDIT_RANGE },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = ch.CHOOSER_Labels, .data = @intFromPtr(&range_labels) },
            .{ .tag = ch.CHOOSER_Active, .data = 0 },
            .{},
        }));
        const set_range = made.take(textButton(ib, app.text.get(.MSG_SET_RANGE), ID_EDIT_SET_RANGE));
        const speed = made.take(ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_EDIT_SPEED },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
            .{ .tag = sl.SLIDER_Min, .data = 0 },
            .{ .tag = sl.SLIDER_Max, .data = palette_zig.max_speed },
            .{ .tag = sl.SLIDER_Level, .data = editor.ranges[0].speed },
            .{ .tag = sl.SLIDER_LevelFormat, .data = @intFromPtr("%ld") },
            .{ .tag = sl.SLIDER_LevelPlace, .data = sl.SLIDER_PLACE_RIGHT },
            .{ .tag = sl.SLIDER_MaxLevelLen, .data = 2 },
            .{},
        }));
        const backwards = made.take(ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_EDIT_BACKWARDS },
            .{ .tag = cb.CHECKBOX_Checked, .data = @intFromBool(editor.ranges[0].backwards) },
            .{},
        }));
        const actions = [3]?*Object{
            made.take(textButton(ib, app.text.get(.MSG_SPREAD), ID_EDIT_SPREAD)),
            made.take(textButton(ib, app.text.get(.MSG_COPY_COLOUR), ID_EDIT_COPY)),
            made.take(textButton(ib, app.text.get(.MSG_SWAP_COLOURS), ID_EDIT_SWAP)),
        };
        const answers = [2]?*Object{ made.take(textButton(ib, app.text.get(.MSG_OK), ID_OK)), made.take(textButton(ib, app.text.get(.MSG_CANCEL), ID_CANCEL)) };
        const hint = made.take(ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
            .{ .tag = tx.TEXT_Text, .data = @intFromPtr(app.text.get(.MSG_PICK_COLOUR)) },
            .{ .tag = tx.TEXT_RoomFor, .data = @intFromPtr(app.text.get(.MSG_PICK_SPREAD)) },
            .{},
        }));
        var value_tags: [2 + 3 * editor_sliders.len + 1]TagItem = undefined;
        value_tags[0] = .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT };
        value_tags[1] = .{ .tag = lg.LAYOUTA_Spacing, .data = 4 };
        var tag_count: usize = 2;
        for (sliders, editor_sliders) |slider, entry| {
            value_tags[tag_count] = .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(slider) };
            value_tags[tag_count + 1] = .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(entry.label)) };
            value_tags[tag_count + 2] = .{ .tag = lg.CHILDA_MinWidth, .data = 160 };
            tag_count += 3;
        }
        value_tags[tag_count] = .{};
        const values = made.layout(&value_tags);
        const top = made.layout(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 8 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(swatches) },
            .{ .tag = lg.CHILDA_MinWidth, .data = 8 * 22 },
            .{ .tag = lg.CHILDA_MinHeight, .data = 4 * 22 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(values) },
            .{},
        });
        const action_row = made.layout(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(actions[0]) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(actions[1]) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(actions[2]) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(hex_field) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(.MSG_HEX)) },
            .{ .tag = lg.CHILDA_MinWidth, .data = 80 },
            .{},
        });
        const range_row = made.layout(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(range_choice) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(.MSG_RANGE)) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(set_range) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(speed) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(.MSG_SPEED)) },
            .{ .tag = lg.CHILDA_MinWidth, .data = 100 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(backwards) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(.MSG_BACKWARDS)) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{},
        });
        const answer_row = made.layout(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(pixels_box) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(.MSG_CHANGE_PIXELS)) },
            .{ .tag = lg.LAYOUTA_AddSpace, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(answers[0]) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(answers[1]) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{},
        });
        const layout = made.layout(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(top) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(action_row) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(range_row) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(hint) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(answer_row) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{},
        });
        if (made.failed or layout == null) {
            made.drop();
            return;
        }
        const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
            screenTag(gui),
            .{ .tag = wn.WA_Title, .data = @intFromPtr(app.text.get(.MSG_PALETTE_TITLE)) },
            .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr(SCREEN_TITLE) },
            .{ .tag = wn.WA_AutoAdjust, .data = 1 },
            .{ .tag = wn.WA_CloseGadget, .data = 1 },
            .{ .tag = wn.WA_DragBar, .data = 1 },
            .{ .tag = wn.WA_DepthGadget, .data = 1 },
            .{ .tag = wn.WA_Activate, .data = 1 },
            .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_IDCMPUPDATE },
            .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(layout) },
            .{},
        }) orelse {
            made.drop();
            return;
        };
        made.keep(layout.?);
        defer ib.DisposeObject(object);
        var open = wc.WmOpen{};
        if (ib.SendMessage(object, @ptrCast(&open)) == 0) return;
        editor.window = @ptrFromInt(windowOf(ib, object));
        editor.palette = swatches.?;
        for (&editor.sliders, sliders) |*into, slider| into.* = slider.?;
        editor.hex_field = hex_field.?;
        editor.hint = hint.?;
        editor.speed = speed.?;
        editor.backwards = backwards.?;
        app.showEdited(&editor, true, null);

        var signal: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_SigMask, object, &signal);
        var code: u32 = 0;
        var handle = wc.WmHandleInput{ .code = &code };
        const taken = done: {
            while (true) {
                _ = sys.Wait(@truncate(signal));
                while (true) {
                    const word = ib.SendMessage(object, @ptrCast(&handle));
                    if (word == wc.WMHI_LASTMSG) break;
                    var gadget: usize = wc.WINDOW_NOGADGET;
                    _ = ib.GetAttr(wc.WINDOWA_GadgetID, object, &gadget);
                    const id = switch (word & wc.WMHI_CLASSMASK) {
                        wc.WMHI_CLOSEWINDOW => break :done false,
                        wc.WMHI_GADGETUP => word & wc.WMHI_GADGETMASK,
                        wc.WMHI_IDCMPUPDATE => gadget,
                        wc.WMHI_VANILLAKEY => switch (word & wc.WMHI_KEYMASK) {
                            '\r' => break :done true,
                            0x1B => break :done false,
                            else => continue,
                        },
                        else => continue,
                    };
                    switch (id) {
                        ID_OK => break :done true,
                        ID_CANCEL => break :done false,
                        ID_EDIT_PALETTE => app.pickEdited(&editor, code),
                        ID_EDIT_HEX => {
                            var value: usize = 0;
                            _ = ib.GetAttr(gc.STRINGA_TextVal, hex_field.?, &value);
                            if (value != 0) {
                                const typed: [*:0]const u8 = @ptrFromInt(value);
                                var length: usize = 0;
                                while (typed[length] != 0) length += 1;
                                if (palette_zig.parseHex(typed[0..length])) |colour| editor.colours[editor.chosen] = colour;
                            }
                            app.showEdited(&editor, true, null);
                        },
                        ID_EDIT_PIXELS => app.recolour_pixels = code != 0,
                        ID_EDIT_SPREAD => app.awaitPick(&editor, .spread),
                        ID_EDIT_COPY => app.awaitPick(&editor, .copy),
                        ID_EDIT_SWAP => app.awaitPick(&editor, .swap),
                        ID_EDIT_RANGE => if (code < palette_zig.max_ranges) {
                            editor.range = code;
                            app.showRange(&editor);
                        },
                        ID_EDIT_SET_RANGE => app.awaitPick(&editor, .range),
                        ID_EDIT_SPEED => {
                            var level: usize = 0;
                            _ = ib.GetAttr(sl.SLIDER_Level, editor.speed, &level);
                            editor.ranges[editor.range].speed = @intCast(@min(level, palette_zig.max_speed));
                        },
                        ID_EDIT_BACKWARDS => editor.ranges[editor.range].backwards = code != 0,
                        else => if (id >= ID_EDIT_SLIDER and id < ID_EDIT_SLIDER + editor_sliders.len) {
                            var level: usize = 0;
                            _ = ib.GetAttr(sl.SLIDER_Level, editor.sliders[id - ID_EDIT_SLIDER], &level);
                            app.slidEdited(&editor, id - ID_EDIT_SLIDER, @truncate(level));
                        },
                    }
                }
            }
        };
        if (taken) {
            app.ranges = editor.ranges;
            app.takeEdited(&editor.colours);
        }
    }

    /// The editor's sliders, hex text and swatches set from the colour
    /// chosen: its hue, saturation and value worked out again with
    /// `hsv_too`, and the slider `moving` left as the pointer has it.
    fn showEdited(app: *App, editor: *Editor, hsv_too: bool, moving: ?usize) void {
        const ib = app.ib;
        const colour = editor.colours[editor.chosen];
        if (hsv_too) editor.hsv = palette_zig.toHsv(colour);
        const levels = [editor_sliders.len]u32{ (colour >> 16) & 0xFF, (colour >> 8) & 0xFF, colour & 0xFF, editor.hsv.hue, editor.hsv.saturation, editor.hsv.value };
        for (editor.sliders, levels, 0..) |slider, level, place| {
            if (moving == place) continue;
            _ = ib.SetGadgetAttrsTagList(slider, editor.window, &[_]TagItem{ .{ .tag = sl.SLIDER_Level, .data = level }, .{} });
        }
        _ = palette_zig.hexText(colour, &editor.hex);
        _ = ib.SetGadgetAttrsTagList(editor.hex_field, editor.window, &[_]TagItem{ .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(&editor.hex) }, .{} });
        _ = ib.SetGadgetAttrsTagList(editor.palette, editor.window, &[_]TagItem{
            .{ .tag = pa.PALETTE_ColorTable, .data = @intFromPtr(&editor.colours) },
            .{ .tag = pa.PALETTE_Color, .data = editor.chosen },
            .{},
        });
    }

    /// A colour picked in the editor: the run spread to it, the one
    /// chosen copied onto it or swapped with it when one of those waits;
    /// then it is the one chosen.
    fn pickEdited(app: *App, editor: *Editor, place: u32) void {
        if (place >= palette_zig.size) return;
        const waited = editor.waiting;
        switch (waited) {
            .none => {},
            .range => {
                const range = &editor.ranges[editor.range];
                range.first = @intCast(@min(editor.chosen, place));
                range.last = @intCast(@max(editor.chosen, place));
                if (range.speed == 0) range.speed = palette_zig.first_speed;
            },
            .spread => palette_zig.spread(&editor.colours, editor.chosen, place),
            .copy => editor.colours[place] = editor.colours[editor.chosen],
            .swap => {
                const held = editor.colours[place];
                editor.colours[place] = editor.colours[editor.chosen];
                editor.colours[editor.chosen] = held;
            },
        }
        if (waited != .none) app.awaitPick(editor, .none);
        editor.chosen = place;
        app.showEdited(editor, true, null);
        if (waited == .range) app.showRange(editor);
    }

    /// The editor's speed and Backwards set from the range chosen, and
    /// the colours it runs over said under the colours.
    fn showRange(app: *App, editor: *Editor) void {
        const ib = app.ib;
        const range = editor.ranges[editor.range];
        _ = ib.SetGadgetAttrsTagList(editor.speed, editor.window, &[_]TagItem{ .{ .tag = sl.SLIDER_Level, .data = range.speed }, .{} });
        _ = ib.SetGadgetAttrsTagList(editor.backwards, editor.window, &[_]TagItem{ .{ .tag = cb.CHECKBOX_Checked, .data = @intFromBool(range.backwards) }, .{} });
        const number: i64 = editor.range + 1;
        const said = if (range.last > range.first)
            app.text.format(&editor.said, .MSG_RANGE_SPAN, .{ number, @as(i64, range.first) + 1, @as(i64, range.last) + 1 })
        else
            app.text.format(&editor.said, .MSG_RANGE_UNSET, .{number});
        _ = ib.SetGadgetAttrsTagList(editor.hint, editor.window, &[_]TagItem{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr(said.ptr) }, .{} });
    }

    /// What the next colour picked in the editor does, said under the
    /// colours.
    fn awaitPick(app: *App, editor: *Editor, waiting: Editor.Waiting) void {
        editor.waiting = waiting;
        const hint = app.text.get(switch (waiting) {
            .none => .MSG_PICK_COLOUR,
            .spread => .MSG_PICK_SPREAD,
            .copy => .MSG_PICK_COPY,
            .swap => .MSG_PICK_SWAP,
            .range => .MSG_PICK_RANGE,
        });
        _ = app.ib.SetGadgetAttrsTagList(editor.hint, editor.window, &[_]TagItem{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr(hint) }, .{} });
    }

    /// One of the editor's sliders moved: red, green or blue, or hue,
    /// saturation or value.
    fn slidEdited(app: *App, editor: *Editor, place: usize, level: u32) void {
        const colour = &editor.colours[editor.chosen];
        switch (place) {
            0, 1, 2 => {
                const shift: u5 = @intCast(16 - place * 8);
                colour.* = (colour.* & ~(@as(Pixel, 0xFF) << shift)) | @as(Pixel, @min(level, 255)) << shift;
                app.showEdited(editor, true, place);
            },
            else => {
                switch (place) {
                    3 => editor.hsv.hue = level,
                    4 => editor.hsv.saturation = level,
                    else => editor.hsv.value = level,
                }
                colour.* = palette_zig.fromHsv(editor.hsv);
                app.showEdited(editor, false, place);
            },
        }
    }

    /// The editor's colours taken as the palette. With Change the Pixels
    /// Too, the pixels of each colour that changed are made the new one
    /// in every layer first. The foreground, picked from the palette and
    /// not changed since, becomes its colour's new one.
    fn takeEdited(app: *App, edited: *const palette_zig.Palette) void {
        if (app.recolour_pixels) {
            var old: palette_zig.Palette = undefined;
            var new: palette_zig.Palette = undefined;
            var count: usize = 0;
            for (app.palette, edited) |was, now| {
                if ((was ^ now) & 0x00FF_FFFF == 0) continue;
                old[count] = was;
                new[count] = now;
                count += 1;
            }
            if (count != 0) app.recolourLayers(old[0..count], new[0..count]);
        }
        // The foreground, still its colour of the palette, follows it.
        const place = app.foreground_index;
        if (place < edited.len and app.palette[place] == app.foreground and edited[place] != app.foreground) {
            app.foreground = edited[place];
            app.drawColours();
        }
        app.setPalette(edited);
    }

    /// The pixels of each of `old`'s colours made the colour at the same
    /// place in `new`, in every layer: one step to undo.
    fn recolourLayers(app: *App, old: []const Pixel, new: []const Pixel) void {
        var joined = false;
        var whole = Area.none;
        for (app.stack.all()) |*layer| {
            const picture = &layer.picture;
            var area = Area.none;
            var y: u32 = 0;
            while (y < picture.height) : (y += 1) {
                const range = palette_zig.find(picture.row(y), old) orelse continue;
                area = area.add(.{ .min_x = @intCast(range[0]), .min_y = @intCast(y), .max_x = @intCast(range[1]), .max_y = @intCast(y + 1) });
            }
            if (area.isEmpty()) continue;
            if (app.history.remember(layer.id, picture, area, joined)) joined = true else app.tell(.MSG_NO_UNDO);
            y = @intCast(area.min_y);
            while (y < area.max_y) : (y += 1) _ = palette_zig.recolour(picture.row(y)[@intCast(area.min_x)..@intCast(area.max_x)], old, new);
            whole = whole.add(area);
        }
        if (whole.isEmpty()) return;
        app.changed = true;
        app.paintLayer();
        app.show(whole);
    }

    /// The layer painted made of the palette's colours alone, each pixel
    /// the nearest, dithered as `dither` says; one step to undo. A
    /// requester says when there is no memory for error diffusion.
    fn reduce(app: *App, dither: palette_zig.Dither) void {
        const layer = app.stack.currentLayer();
        const picture = &layer.picture;
        const width: usize = picture.width;
        var memory: ?*anyopaque = null;
        var carried: ?palette_zig.Diffusion = null;
        if (dither == .diffused) {
            memory = app.sys.AllocVec(width * 2 * @sizeOf([3]i16), exec.MEMF_ANY) orelse {
                app.tell(.MSG_NO_REDUCE);
                return;
            };
            const rows: [*][3]i16 = @ptrCast(@alignCast(memory));
            carried = .{ .this = rows[0..width], .next = rows[width .. 2 * width] };
            carried.?.start();
        }
        defer if (memory) |given| app.sys.FreeVec(given);
        if (!app.history.remember(layer.id, picture, picture.whole(), false)) app.tell(.MSG_NO_UNDO);
        var y: u32 = 0;
        while (y < picture.height) : (y += 1) palette_zig.reduceRow(picture.row(y), y, &app.palette, dither, if (carried) |*carry| carry else null);
        app.changed = true;
        app.paintLayer();
        app.show(picture.whole());
    }

    // --- cycling ----------------------------------------------------------------

    /// The palette's ranges set turning, or stopped; a requester says
    /// when none of them would turn.
    fn cycle(app: *App, on: bool) void {
        if (on == app.cycling) return;
        if (on) {
            if (!palette_zig.anyTurns(&app.ranges)) {
                // The item's check mark, turned by the pick, turned back.
                if (app.gui) |*gui| gui.shown_menus = null;
                app.tell(.MSG_NO_RANGE);
                return;
            }
            if (app.clock_port == null and !app.openClock()) {
                if (app.gui) |*gui| gui.shown_menus = null;
                return;
            }
            app.cycling = true;
            app.cycle_start = app.eclock()[0];
            app.turns = @splat(0);
            app.retune();
            app.beat();
            return;
        }
        app.stopClock();
        app.cycling = false;
        app.turned = .{};
        app.whole = true;
    }

    /// The colours cycling shows made again from the palette and its
    /// ranges, after either changed; cycling stops when no range turns.
    fn retune(app: *App) void {
        if (!app.cycling) return;
        if (!palette_zig.anyTurns(&app.ranges)) return app.cycle(false);
        app.turned = palette_zig.Turned.make(&app.palette, &app.ranges, &app.turns);
        app.whole = true;
    }

    /// The E-clock's tick and its ticks a second.
    fn eclock(app: *App) [2]u64 {
        const timer_base: *timer.TimerBase = @ptrCast(app.clock.node.device orelse return .{ 0, 0 });
        var clock: timer.EClockVal = .{};
        const rate = timer_base.ReadEClock(&clock);
        return .{ clock.toTicks(), rate };
    }

    /// A beat of cycling: the ranges turned on as far as the time since
    /// it started takes them - a slow redraw makes a range jump, never
    /// lag - and the next beat asked for.
    fn beat(app: *App) void {
        const sys = app.sys;
        const port = app.clock_port orelse return;
        if (app.clock_out) {
            if (sys.CheckIO(&app.clock.node) == null) return;
            _ = sys.WaitIO(&app.clock.node);
            app.clock_out = false;
            const clock = app.eclock();
            var moved = false;
            for (app.ranges, &app.turns) |range, *turn| {
                const now = range.turnAt(clock[0] -% app.cycle_start, clock[1]);
                if (now == turn.*) continue;
                turn.* = now;
                moved = true;
            }
            if (moved) app.retune();
        }
        if (!app.cycling) return;
        // A signal left from a beat cut short is not this one's.
        _ = sys.SetSignal(0, port.sigMask());
        app.clock.node.command = timer.TR_ADDREQUEST;
        app.clock.time = .{ .micro = 1_000_000 / beats_per_second };
        sys.SendIO(&app.clock.node);
        app.clock_out = true;
    }

    /// timer.device opened for the beat; false, with nothing open, when
    /// it cannot be.
    fn openClock(app: *App) bool {
        const sys = app.sys;
        const port = sys.CreateMsgPort() orelse return false;
        app.clock = .{};
        app.clock.node.message.reply_port = port;
        app.clock.node.message.length = @sizeOf(timer.TimeRequest);
        if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_VBLANK, &app.clock.node, 0) != 0) {
            sys.DeleteMsgPort(port);
            return false;
        }
        app.clock_port = port;
        return true;
    }

    /// The beat waiting called back.
    fn stopClock(app: *App) void {
        if (!app.clock_out) return;
        const sys = app.sys;
        if (sys.CheckIO(&app.clock.node) == null) _ = sys.AbortIO(&app.clock.node);
        _ = sys.WaitIO(&app.clock.node);
        app.clock_out = false;
    }

    /// timer.device closed, at the end.
    fn closeClock(app: *App) void {
        const port = app.clock_port orelse return;
        app.stopClock();
        app.sys.CloseDevice(&app.clock.node);
        app.sys.DeleteMsgPort(port);
        app.clock_port = null;
    }

    // --- the Image menu ---------------------------------------------------------

    /// The picture scaled to another size, asked with how - smooth or
    /// hard, and whether a side left as it was follows the other: every
    /// layer and mask, one step to undo.
    fn pictureSize(app: *App) void {
        _ = app.paintFX() orelse return;
        var scaling = app.scaling;
        const asked = app.askSize(.MSG_PICTURE_SIZE_TITLE, .{ .scale = &scaling }) orelse return;
        app.scaling = scaling;
        const bottom = app.stack.layers[0].picture;
        const size = if (scaling.keep) image_zig.proportioned(.{ bottom.width, bottom.height }, asked) else asked;
        if (size[0] == bottom.width and size[1] == bottom.height) return;
        app.changeImage(.{ .scale = .{ .width = size[0], .height = size[1], .smooth = scaling.smooth } });
    }

    /// Every layer, with its mask, made anew by `change`; one step to
    /// undo. A requester says when there is no memory for it: nothing
    /// changes then.
    fn changeImage(app: *App, change: image_zig.Change) void {
        const bottom = app.stack.layers[0].picture;
        const size = image_zig.sizeAfter(change, bottom.width, bottom.height);
        if (size[0] == 0 or size[1] == 0 or size[0] > max_side or size[1] > max_side) return;
        const count = app.stack.count;
        const sys = app.sys;
        const list = sys.AllocVec(@sizeOf(Layer) * count, exec.MEMF_ANY) orelse return app.tell(.MSG_NO_IMAGE_MEMORY);
        defer sys.FreeVec(list);
        const made: [*]Layer = @ptrCast(@alignCast(list));
        var done: u32 = 0;
        while (done < count) : (done += 1) {
            // The bottom layer's new canvas the background colour, the
            // others' see-through.
            const fill: Pixel = if (done == 0) app.background else 0;
            made[done] = app.changedLayer(&app.stack.layers[done], change, size, fill) orelse break;
        }
        const new_size = size[0] != bottom.width or size[1] != bottom.height;
        if (done < count or (new_size and !app.fitSides(size[0], size[1]))) {
            for (made[0..done]) |layer| app.freeLayer(layer);
            app.tell(.MSG_NO_IMAGE_MEMORY);
            return;
        }
        app.swapLayers(made[0..count]);
    }

    /// A copy of `layer` made by `change` at `size`, a canvas's new part
    /// `fill` - its mask's white, showing; null when there is no memory
    /// for it.
    fn changedLayer(app: *App, layer: *const Layer, change: image_zig.Change, size: [2]u32, fill: Pixel) ?Layer {
        const sys = app.sys;
        const bytes = Picture.bytesFor(size[0], size[1]);
        const memory = sys.AllocVec(bytes, exec.MEMF_ANY) orelse return null;
        var made = layer.*;
        made.memory = memory;
        made.picture = .{ .pixels = @ptrCast(@alignCast(memory)), .width = size[0], .height = size[1] };
        made.id = app.stack.newId();
        made.mask = null;
        made.mask_memory = null;
        if (!app.changePicture(change, &layer.picture, &made.picture, fill)) {
            sys.FreeVec(memory);
            return null;
        }
        if (layer.mask) |*mask| {
            const mask_memory = sys.AllocVec(bytes, exec.MEMF_ANY) orelse {
                sys.FreeVec(memory);
                return null;
            };
            made.mask = .{ .pixels = @ptrCast(@alignCast(mask_memory)), .width = size[0], .height = size[1] };
            made.mask_memory = mask_memory;
            if (!app.changePicture(change, mask, &made.mask.?, 0xFFFFFFFF)) {
                sys.FreeVec(mask_memory);
                sys.FreeVec(memory);
                return null;
            }
        }
        return made;
    }

    /// `from` made into `into` by `change`: a scale by paintfx.library,
    /// opened before the change was asked for, anything else by
    /// image.zig. False when the library had no memory for it.
    fn changePicture(app: *App, change: image_zig.Change, from: *const Picture, into: *Picture, fill: Pixel) bool {
        if (change != .scale) {
            image_zig.apply(change, from, into, fill);
            return true;
        }
        const fx: *PaintFXBase = @ptrCast(app.fx_lib orelse return false);
        const how = if (change.scale.smooth) paintfx.PFXSCALE_SMOOTH else paintfx.PFXSCALE_HARD;
        return fx.ScalePixels(&pixelsOf(from, from.whole()), &pixelsOf(into, into.whole()), how) == 0;
    }

    /// The layers swapped for `made`, place by place: each taken out and
    /// its new one put in, the whole one step to undo; then shown again.
    /// The layer painted goes last, its new one put in above it before it
    /// is taken out, so that undoing the step - which paints the layer
    /// its last record puts back - paints it again.
    fn swapLayers(app: *App, made: []const Layer) void {
        const painted = app.stack.current;
        const count: u32 = @intCast(made.len);
        var kept = true;
        var turn: u32 = 0;
        while (turn < count) : (turn += 1) {
            const place = if (turn + 1 == count) painted else if (turn < painted) turn else turn + 1;
            const joined = turn != 0;
            if (place == painted and app.stack.count < layers_zig.max_layers) {
                app.stack.insert(place + 1, made[place]);
                if (!app.history.layerIn(&app.stack, place + 1, joined)) kept = false;
                const old = app.stack.remove(place);
                if (!app.history.layerOut(old, place, true)) {
                    app.freeLayer(old);
                    kept = false;
                }
                continue;
            }
            const old = app.stack.remove(place);
            if (!app.history.layerOut(old, place, joined)) {
                app.freeLayer(old);
                kept = false;
            }
            app.stack.insert(place, made[place]);
            if (!app.history.layerIn(&app.stack, place, true)) kept = false;
        }
        app.stack.current = painted;
        if (!kept) app.tell(.MSG_NO_UNDO);
        app.resized();
    }

    /// The memory beside the layers - `kept`, the mask, the composite
    /// when there is one - made again for a picture `width` by `height`,
    /// the selection let go; the history stays. False, with nothing
    /// changed, when there is no memory for it.
    fn fitSides(app: *App, width: u32, height: u32) bool {
        const sys = app.sys;
        const bytes = Picture.bytesFor(width, height);
        const kept = sys.AllocVec(bytes, exec.MEMF_ANY) orelse return false;
        const mask = sys.AllocVec(@as(usize, width) * height, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
            sys.FreeVec(kept);
            return false;
        };
        const composite: ?*anyopaque = if (app.memory[3] == null) null else sys.AllocVec(bytes, exec.MEMF_ANY) orelse {
            sys.FreeVec(mask);
            sys.FreeVec(kept);
            return false;
        };
        for ([_]usize{ 0, 2, 3, 4 }) |slot| if (app.memory[slot]) |block| sys.FreeVec(block);
        app.memory[0] = kept;
        app.memory[2] = mask;
        app.memory[3] = composite;
        app.memory[4] = null;
        app.mask = @as([*]u8, @ptrCast(mask))[0 .. @as(usize, width) * height];
        app.scratch = .{ .mask = app.mask, .width = width, .height = height };
        app.kept = .{ .pixels = @ptrCast(@alignCast(kept)), .width = width, .height = height };
        app.stack.composite = if (composite) |memory| Picture{ .pixels = @ptrCast(@alignCast(memory)), .width = width, .height = height } else null;
        app.selection = .{};
        app.choosing = false;
        return true;
    }

    /// After an undo or a redo, the memory beside the layers fitted to
    /// their size, and the view to it, when that changed; false when
    /// there is no memory for it.
    fn followSize(app: *App) bool {
        const bottom = app.stack.layers[0].picture;
        if (bottom.width == app.kept.width and bottom.height == app.kept.height) return true;
        if (!app.fitSides(bottom.width, bottom.height)) return false;
        app.view.fit(bottom.width, bottom.height);
        app.whole = true;
        return true;
    }

    /// The picture shown again after its layers changed whole: the layer
    /// painted kept, the view fitted to its size.
    fn resized(app: *App) void {
        app.changed = true;
        app.paintLayer();
        app.view.fit(app.picture.width, app.picture.height);
        app.whole = true;
        app.layers_stale = true;
        app.show(app.picture.whole());
    }

    /// The picture cut to the box of what is chosen.
    fn crop(app: *App) void {
        if (!app.selection.any()) return;
        const box = app.selection.box.clip(app.picture.width, app.picture.height);
        if (box.isEmpty()) return;
        app.changeImage(.{ .place = .{ .width = box.width(), .height = box.height(), .left = -box.min_x, .top = -box.min_y } });
    }

    /// The picture's edges cut away where what is shown there is all the
    /// colour of its top left corner.
    fn trim(app: *App) void {
        if (!app.stack.plain() and !app.haveComposite()) return;
        const whole = app.stack.layers[0].picture.whole();
        app.stack.compose(whole);
        const box = image_zig.trimmed(app.stack.shown());
        if (box.isEmpty() or (box.width() == whole.width() and box.height() == whole.height())) return;
        app.changeImage(.{ .place = .{ .width = box.width(), .height = box.height(), .left = -box.min_x, .top = -box.min_y } });
    }

    /// The canvas made another size, asked with where the picture goes on
    /// it: cut where it is smaller, the background colour - see-through
    /// in the layers above the bottom one - where it is larger.
    fn canvasSize(app: *App) void {
        var where = app.canvas_place;
        const size = app.askSize(.MSG_CANVAS_TITLE, .{ .place = &where }) orelse return;
        app.canvas_place = where;
        const bottom = app.stack.layers[0].picture;
        if (size[0] == bottom.width and size[1] == bottom.height) return;
        app.changeImage(.{ .place = image_zig.placed(bottom.width, bottom.height, size[0], size[1], where) });
    }

    /// The layers made one, as they show - hidden ones left out, masks
    /// and blend modes laid in - named as the bottom one; one step to
    /// undo.
    fn flatten(app: *App) void {
        const count = app.stack.count;
        if (count < 2 or !app.haveComposite()) return;
        const whole = app.stack.layers[0].picture.whole();
        app.stack.compose(whole);
        const shown = app.stack.shown();
        const memory = app.sys.AllocVec(Picture.bytesFor(shown.width, shown.height), exec.MEMF_ANY) orelse return app.tell(.MSG_NO_IMAGE_MEMORY);
        var layer = Layer{ .picture = .{ .pixels = @ptrCast(@alignCast(memory)), .width = shown.width, .height = shown.height }, .memory = memory, .id = app.stack.newId() };
        layer.picture.copyArea(shown, whole);
        layer.name = app.stack.layers[0].name;
        // The one layer put in at the top, then the others taken out -
        // the stack is never empty: those above the layer painted from the
        // top down, those under it, and it last, so that undoing the step
        // paints it again.
        const painted = app.stack.current;
        app.stack.insert(count, layer);
        var kept = app.history.layerIn(&app.stack, count, false);
        var turn: u32 = 0;
        while (turn < count) : (turn += 1) {
            const above = count - 1 - painted;
            const place = if (turn < above) count - 1 - turn else if (turn + 1 < count) painted - 1 - (turn - above) else 0;
            const old = app.stack.remove(place);
            if (!app.history.layerOut(old, place, true)) {
                app.freeLayer(old);
                kept = false;
            }
        }
        app.stack.current = 0;
        app.painting_mask = false;
        if (!kept) app.tell(.MSG_NO_UNDO);
        app.resized();
    }

    // --- masks ------------------------------------------------------------------

    /// A mask put on the layer painted - white over all of it, black, or
    /// as much as is chosen of each pixel - and painted.
    fn addMask(app: *App, how: enum { show_all, hide_all, selection }) void {
        const layer = app.stack.currentLayer();
        if (layer.mask != null or !app.haveComposite()) return;
        if (how == .selection and !app.selection.any()) return;
        const width = app.picture.width;
        const height = app.picture.height;
        const memory = app.sys.AllocVec(Picture.bytesFor(width, height), exec.MEMF_ANY) orelse {
            app.tell(.MSG_NO_MASK);
            return;
        };
        var mask = Picture{ .pixels = @ptrCast(@alignCast(memory)), .width = width, .height = height };
        switch (how) {
            .show_all => mask.fill(0xFFFF_FFFF),
            .hide_all => mask.fill(0xFF00_0000),
            .selection => for (app.selection.mask, mask.pixels[0..app.selection.mask.len]) |part, *pixel| {
                pixel.* = 0xFF00_0000 | @as(Pixel, part) * 0x01_01_01;
            },
        }
        layer.mask = mask;
        layer.mask_memory = memory;
        if (!app.history.maskIn(layer.id, false)) app.tell(.MSG_NO_UNDO);
        app.painting_mask = true;
        app.layersChanged();
    }

    /// The mask of the layer painted painted, or the layer itself.
    fn paintMask(app: *App, mask: bool) void {
        if (app.painting_mask == mask or (mask and app.stack.currentLayer().mask == null)) return;
        app.painting_mask = mask;
        app.paintLayer();
        app.layers_stale = true;
        if (app.show_mask) app.whole = true;
    }

    /// The mask of the layer painted laid into its pixels - each keeps as
    /// much of its alpha as the mask let show - or only deleted; and the
    /// layer painted. One step to undo.
    fn takeMask(app: *App, apply: bool) void {
        const layer = app.stack.currentLayer();
        if (layer.mask == null) return;
        var kept = true;
        if (apply) {
            kept = app.history.remember(layer.id, &layer.picture, layer.picture.whole(), false);
            maskInto(&layer.picture, &layer.mask.?);
        }
        const mask = layer.mask.?;
        const memory = layer.mask_memory.?;
        layer.mask = null;
        layer.mask_memory = null;
        if (!kept or !app.history.maskOut(layer.id, mask, memory, apply)) {
            app.sys.FreeVec(memory);
            app.tell(.MSG_NO_UNDO);
        }
        app.painting_mask = false;
        app.layersChanged();
    }

    /// The picture the view shows: the mask of the layer painted while
    /// Show Mask is on and it has one, otherwise what the layers make.
    fn viewed(app: *const App) *const Picture {
        if (app.show_mask) {
            if (app.stack.layers[app.stack.current].mask) |*mask| return mask;
        }
        return app.stack.shown();
    }

    /// The layer painted flipped across, or upside down, with its mask;
    /// one step to undo.
    fn flipLayer(app: *App, across: bool) void {
        const picture = &app.picture;
        flipPicture(picture, across);
        // The whole layer, whatever is chosen.
        app.changed = true;
        app.recordWhole(picture.whole());
        // The mask, or the layer when the mask is painted, flipped too.
        const layer = app.stack.currentLayer();
        if (layer.mask) |*mask| {
            const other = if (app.painting_mask) &layer.picture else mask;
            const other_id = if (app.painting_mask) layer.id else layer.id | layers_zig.mask_id;
            if (!app.history.remember(other_id, other, other.whole(), true)) app.tell(.MSG_NO_UNDO);
            flipPicture(other, across);
        }
        app.show(picture.whole());
    }

    // --- the free transform ----------------------------------------------------

    /// Layer → Free Transform: what shows of the layer painted - of what
    /// is chosen of it when something is - lifted into a frame with
    /// handles, the place it was left as a cut leaves it. Presses on the
    /// picture then size, move and turn it (`transformTo`); Return or
    /// any command that ends a shape takes it, Escape or Undo puts it
    /// back.
    fn freeTransform(app: *App) void {
        app.endShape();
        if (app.transforming != null) return;
        _ = app.paintFX() orelse return;
        const picture = &app.picture;
        const box = if (app.selection.any()) app.selection.box.clip(picture.width, picture.height) else picture.whole();
        const area = app.liftedArea(box);
        if (area.isEmpty()) return;
        const memory = app.sys.AllocVec(@as(usize, area.width()) * area.height() * @sizeOf(Pixel), exec.MEMF_ANY) orelse {
            app.tell(.MSG_NO_IMAGE_MEMORY);
            return;
        };
        const lifted: [*]Pixel = @ptrCast(@alignCast(memory));
        var at: usize = 0;
        var y = area.min_y;
        while (y < area.max_y) : (y += 1) {
            var x = area.min_x;
            while (x < area.max_x) : (x += 1) {
                lifted[at] = app.liftedAt(x, y);
                at += 1;
            }
        }
        const shape = transform_zig.Shape.of(area);
        // What it covered begins as where it was, so the first showing
        // leaves that place as a cut does.
        app.transforming = .{ .lifted = lifted, .memory = memory, .area = area, .shape = shape, .covered = area, .framed = area, .before = shape };
        if (!app.showTransform(paintfx.PFXSCALE_HARD)) app.tell(.MSG_NO_IMAGE_MEMORY);
    }

    /// How much of the pixel (`x`, `y`) a transform lifts: all of it with
    /// nothing chosen.
    fn liftedPart(app: *const App, x: i32, y: i32) u8 {
        return if (app.selection.any()) app.selection.at(x, y) else 255;
    }

    /// What a transform lifts of the pixel (`x`, `y`), as it was before.
    fn liftedAt(app: *const App, x: i32, y: i32) Pixel {
        return selection_zig.partOf(app.kept.get(@intCast(x), @intCast(y)), app.liftedPart(x, y));
    }

    /// The least area of `box` holding something a transform lifts: a
    /// pixel that shows, chosen at least in part.
    fn liftedArea(app: *const App, box: Area) Area {
        var found = Area.none;
        var y = box.min_y;
        while (y < box.max_y) : (y += 1) {
            var x = box.min_x;
            while (x < box.max_x) : (x += 1) {
                if (app.liftedAt(x, y) >> 24 == 0) continue;
                found = found.add(.{ .min_x = x, .min_y = y, .max_x = x + 1, .max_y = y + 1 });
            }
        }
        return if (found.isEmpty()) Area{} else found;
    }

    /// The layer painted over `area` as the transform leaves it: as it
    /// was, with what was lifted taken away.
    fn leaveBehind(app: *App, lifted_from: Area, area: Area) void {
        const picture = &app.picture;
        const cut = area.clip(picture.width, picture.height);
        picture.copyArea(&app.kept, cut);
        const empty = app.emptyColour();
        var y = @max(cut.min_y, lifted_from.min_y);
        while (y < @min(cut.max_y, lifted_from.max_y)) : (y += 1) {
            var x = @max(cut.min_x, lifted_from.min_x);
            while (x < @min(cut.max_x, lifted_from.max_x)) : (x += 1) {
                const part = app.liftedPart(x, y);
                if (part == 0) continue;
                const place_x: u32 = @intCast(x);
                const place_y: u32 = @intCast(y);
                picture.set(place_x, place_y, selection_zig.takenFrom(app.kept.get(place_x, place_y), part, empty));
            }
        }
    }

    /// The layer painted shown with the transform's pixels in their
    /// shape over what is left: each pixel the nearest lifted one
    /// (`PFXSCALE_HARD`) while it is dragged, mixed (`PFXSCALE_SMOOTH`)
    /// when it is taken. False when there was no memory for the pixels it
    /// makes: the layer is left without them then.
    fn showTransform(app: *App, how: u32) bool {
        const moving = &(app.transforming orelse return false);
        const fx: *PaintFXBase = @ptrCast(app.fx_lib orelse return false);
        const picture = &app.picture;
        const covered = moving.shape.area().clip(picture.width, picture.height);
        app.leaveBehind(moving.area, moving.covered.add(covered));
        // The frame shown round it, and taken from where it was.
        const reach: i32 = @intCast(transform_zig.handle_half / app.view.zoom + 2);
        const box = moving.shape.area();
        const framed = Area{ .min_x = box.min_x - reach, .min_y = box.min_y - reach, .max_x = box.max_x + reach, .max_y = box.max_y + reach };
        app.show(moving.framed.add(framed).add(moving.covered).add(covered));
        moving.framed = framed;
        moving.covered = covered;
        if (covered.isEmpty()) return true;
        const memory = app.sys.AllocVec(@as(usize, covered.width()) * covered.height() * @sizeOf(Pixel), exec.MEMF_ANY) orelse return false;
        defer app.sys.FreeVec(memory);
        const made: [*]Pixel = @ptrCast(@alignCast(memory));
        const from = paintfx.Pixels{ .pixels = moving.lifted, .width = moving.area.width(), .height = moving.area.height(), .pitch = moving.area.width() };
        const into = paintfx.Pixels{ .pixels = made, .width = covered.width(), .height = covered.height(), .pitch = covered.width() };
        const matrix = moving.shape.matrix(covered.min_x, covered.min_y);
        fx.TransformPixels(&from, &into, &matrix, how);
        var at: usize = 0;
        var y: u32 = @intCast(covered.min_y);
        while (y < covered.max_y) : (y += 1) {
            for (picture.row(y)[@intCast(covered.min_x)..@intCast(covered.max_x)]) |*pixel| {
                pixel.* = brush_zig.overlay(made[at], pixel.*);
                at += 1;
            }
        }
        return true;
    }

    /// A press on the view, at its pixel (`view_x`, `view_y`), while a
    /// transform is under way: on a handle it sizes the shape, inside it
    /// moves it, outside it turns it - Shift keeping a corner's
    /// proportions and turning in steps of 15 degrees.
    fn transformTo(app: *App, view_x: i32, view_y: i32, first: bool) void {
        const moving = &(app.transforming orelse return);
        const zoom: f32 = @floatFromInt(app.view.zoom);
        const point = transform_zig.Spot{
            @as(f32, @floatFromInt(app.view.left)) + (@as(f32, @floatFromInt(view_x - app.view.offset_x)) + 0.5) / zoom,
            @as(f32, @floatFromInt(app.view.top)) + (@as(f32, @floatFromInt(view_y - app.view.offset_y)) + 0.5) / zoom,
        };
        if (first) {
            moving.grip = transform_zig.gripAt(moving.shape, point, @as(f32, handle_reach) / zoom);
            moving.from = point;
            moving.before = moving.shape;
            return;
        }
        const keep = app.qualifier & (ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT) != 0;
        const shape = transform_zig.dragged(moving.before, moving.grip, moving.from, point, keep);
        if (shape.same(moving.shape)) return;
        moving.shape = shape;
        // Without memory the shape is shown when there is.
        _ = app.showTransform(paintfx.PFXSCALE_HARD);
    }

    /// The transform taken: its pixels mixed into the layer painted in
    /// their shape, one step to undo. What was chosen has moved, so
    /// nothing is chosen after it.
    fn takeTransform(app: *App) void {
        const moving = app.transforming orelse return;
        if (moving.shape.same(transform_zig.Shape.of(moving.area))) return app.dropTransform();
        // Without memory for the mix the nearest pixels stay.
        if (!app.showTransform(paintfx.PFXSCALE_SMOOTH)) app.tell(.MSG_NO_IMAGE_MEMORY);
        const changed = moving.area.add(app.transforming.?.covered);
        app.endTransform();
        app.changed = true;
        app.recordWhole(changed);
        if (app.selection.any()) app.deselect();
    }

    /// The transform put away: the layer painted as it was.
    fn dropTransform(app: *App) void {
        const moving = app.transforming orelse return;
        app.picture.copyArea(&app.kept, moving.area.add(moving.covered));
        app.show(moving.area);
        app.endTransform();
    }

    /// The transform's memory given back and its frame taken away.
    fn endTransform(app: *App) void {
        const moving = app.transforming orelse return;
        app.sys.FreeVec(moving.memory);
        app.show(moving.framed);
        app.transforming = null;
    }

    /// A transform's frame in the view.
    fn frameOf(app: *const App, shape: transform_zig.Shape) transform_zig.Frame {
        const zoom: f32 = @floatFromInt(app.view.zoom);
        const origin = transform_zig.Spot{
            @as(f32, @floatFromInt(app.view.offset_x)) - @as(f32, @floatFromInt(app.view.left)) * zoom,
            @as(f32, @floatFromInt(app.view.offset_y)) - @as(f32, @floatFromInt(app.view.top)) * zoom,
        };
        return transform_zig.Frame.of(shape, origin, zoom);
    }

    /// The Effects window: its sliders change the layer painted - what
    /// is chosen of it - as they move, the picture showing it; OK keeps
    /// that, one step to undo, Cancel puts the layer back as it was.
    fn effects(app: *App) void {
        const gui = app.ui() orelse return;
        const fx = app.paintFX() orelse return;
        const picture = &app.picture;
        const area = if (app.selection.any()) app.selection.box.clip(picture.width, picture.height) else picture.whole();
        if (area.isEmpty()) return;
        const ib = app.ib;
        var made = Builder{ .ib = ib };
        var sliders: [effect_sliders.len]?*Object = undefined;
        for (&sliders, effect_sliders, 0..) |*slider, entry, place| slider.* = made.take(ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_EFFECT + place },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
            .{ .tag = sl.SLIDER_Min, .data = @bitCast(@as(isize, entry.least)) },
            .{ .tag = sl.SLIDER_Max, .data = @bitCast(@as(isize, entry.most)) },
            .{ .tag = sl.SLIDER_Level, .data = 0 },
            .{ .tag = sl.SLIDER_LevelFormat, .data = @intFromPtr("%ld") },
            .{ .tag = sl.SLIDER_LevelPlace, .data = sl.SLIDER_PLACE_RIGHT },
            .{ .tag = sl.SLIDER_MaxLevelLen, .data = 4 },
            .{},
        }));
        const reset = made.take(textButton(ib, app.text.get(.MSG_RESET), ID_EFFECT_RESET));
        const answers = [2]?*Object{ made.take(textButton(ib, app.text.get(.MSG_OK), ID_OK)), made.take(textButton(ib, app.text.get(.MSG_CANCEL), ID_CANCEL)) };
        var slider_tags: [2 + 3 * effect_sliders.len + 1]TagItem = undefined;
        slider_tags[0] = .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT };
        slider_tags[1] = .{ .tag = lg.LAYOUTA_Spacing, .data = 4 };
        var tag_count: usize = 2;
        for (sliders, effect_sliders) |slider, entry| {
            slider_tags[tag_count] = .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(slider) };
            slider_tags[tag_count + 1] = .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(entry.label)) };
            slider_tags[tag_count + 2] = .{ .tag = lg.CHILDA_MinWidth, .data = 200 };
            tag_count += 3;
        }
        slider_tags[tag_count] = .{};
        const values = made.layout(&slider_tags);
        const answer_row = made.layout(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(reset) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddSpace, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(answers[0]) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(answers[1]) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{},
        });
        const layout = made.layout(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 8 },
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(values) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(answer_row) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{},
        });
        if (made.failed or layout == null) {
            made.drop();
            return;
        }
        const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
            screenTag(gui),
            .{ .tag = wn.WA_Title, .data = @intFromPtr(app.text.get(.MSG_EFFECTS_TITLE)) },
            .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr(SCREEN_TITLE) },
            // Over the tools and the panel, leaving the picture to be
            // seen.
            .{ .tag = wn.WA_Left, .data = 8 },
            .{ .tag = wn.WA_Top, .data = 40 },
            .{ .tag = wn.WA_AutoAdjust, .data = 1 },
            .{ .tag = wn.WA_CloseGadget, .data = 1 },
            .{ .tag = wn.WA_DragBar, .data = 1 },
            .{ .tag = wn.WA_DepthGadget, .data = 1 },
            .{ .tag = wn.WA_Activate, .data = 1 },
            .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_IDCMPUPDATE },
            .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(layout) },
            .{},
        }) orelse {
            made.drop();
            return;
        };
        made.keep(layout.?);
        defer ib.DisposeObject(object);
        var open = wc.WmOpen{};
        if (ib.SendMessage(object, @ptrCast(&open)) == 0) return;
        const window: *Window = @ptrFromInt(windowOf(ib, object));

        var signal: usize = 0;
        _ = ib.GetAttr(wc.WINDOWA_SigMask, object, &signal);
        var code: u32 = 0;
        var handle = wc.WmHandleInput{ .code = &code };
        var levels: [effect_sliders.len]i32 = @splat(0);
        var shown = levels;
        var told = false;
        const taken = done: {
            while (true) {
                _ = app.sys.Wait(@truncate(signal));
                while (true) {
                    const word = ib.SendMessage(object, @ptrCast(&handle));
                    if (word == wc.WMHI_LASTMSG) break;
                    var gadget: usize = wc.WINDOW_NOGADGET;
                    _ = ib.GetAttr(wc.WINDOWA_GadgetID, object, &gadget);
                    const id = switch (word & wc.WMHI_CLASSMASK) {
                        wc.WMHI_CLOSEWINDOW => break :done false,
                        wc.WMHI_GADGETUP => word & wc.WMHI_GADGETMASK,
                        wc.WMHI_IDCMPUPDATE => gadget,
                        wc.WMHI_VANILLAKEY => switch (word & wc.WMHI_KEYMASK) {
                            '\r' => break :done true,
                            0x1B => break :done false,
                            else => continue,
                        },
                        else => continue,
                    };
                    switch (id) {
                        ID_OK => break :done true,
                        ID_CANCEL => break :done false,
                        ID_EFFECT_RESET => {
                            levels = @splat(0);
                            for (sliders) |slider| _ = ib.SetGadgetAttrsTagList(slider.?, window, &[_]TagItem{ .{ .tag = sl.SLIDER_Level, .data = 0 }, .{} });
                        },
                        else => if (id >= ID_EFFECT and id < ID_EFFECT + effect_sliders.len) {
                            var level: usize = 0;
                            _ = ib.GetAttr(sl.SLIDER_Level, sliders[id - ID_EFFECT].?, &level);
                            levels[id - ID_EFFECT] = @truncate(@as(isize, @bitCast(level)));
                        },
                    }
                }
                // What came in together shown once.
                if (sameLevels(&levels, &shown)) continue;
                if (!app.showEffects(fx, &levels, area) and !told) {
                    told = true;
                    app.tell(.MSG_NO_IMAGE_MEMORY);
                }
                shown = levels;
                app.flush();
            }
        };
        if (taken and !sameLevels(&levels, &shown)) {
            _ = app.showEffects(fx, &levels, area);
            shown = levels;
        }
        if (taken and !sameLevels(&shown, &@as([effect_sliders.len]i32, @splat(0)))) {
            app.changed = true;
            app.recordWhole(area);
        } else {
            picture.copyArea(&app.kept, area);
            app.show(area);
        }
    }

    /// The layer painted over `area` made from `kept` with the effects at
    /// `levels` - the colours, then the blur, the sharpening and the
    /// texture - cut to what is chosen and shown. False when
    /// paintfx.library had no memory for one of the last three: the rest
    /// is made.
    fn showEffects(app: *App, fx: *PaintFXBase, levels: *const [effect_sliders.len]i32, area: Area) bool {
        const picture = &app.picture;
        picture.copyArea(&app.kept, area);
        const pixels = pixelsOf(picture, area);
        fx.AdjustColours(&pixels, &.{
            .dehaze = @intCast(levelOf(levels, .dehaze)),
            .red = levelOf(levels, .cyan_red),
            .green = levelOf(levels, .magenta_green),
            .blue = levelOf(levels, .yellow_blue),
            .brightness = levelOf(levels, .brightness),
            .contrast = levelOf(levels, .contrast),
            .saturation = levelOf(levels, .saturation),
            .hue = levelOf(levels, .hue),
            .sepia = @intCast(levelOf(levels, .sepia)),
            .invert = @intCast(levelOf(levels, .invert)),
        });
        var whole = true;
        const blur = levelOf(levels, .blur);
        if (blur > 0 and fx.BlurPixels(&pixels, &pixels, @intCast(blur)) != 0) whole = false;
        const sharpen = levelOf(levels, .sharpen);
        if (sharpen > 0 and fx.SharpenPixels(&pixels, &pixels, @intCast(2 * sharpen), sharpen_radius) != 0) whole = false;
        const texture = levelOf(levels, .texture);
        if (texture > 0 and fx.SharpenPixels(&pixels, &pixels, @intCast(texture), texture_radius) != 0) whole = false;
        app.selection.stencil(picture, &app.kept, area);
        app.show(area);
        return whole;
    }

    /// The layer at `place` from the bottom painted.
    fn chooseLayer(app: *App, place: u32) void {
        if (place >= app.stack.count or place == app.stack.current) return;
        app.endShape();
        // Which row's mask is painted changes.
        if (app.painting_mask) app.layers_stale = true;
        app.stack.current = place;
        app.paintLayer();
        if (app.show_mask) app.whole = true;
    }

    /// The layer at `place` shown or hidden, as its eye in the list says.
    fn showLayer(app: *App, place: u32, shown: bool) void {
        if (place >= app.stack.count) return;
        if (!app.haveComposite()) {
            app.layers_stale = true;
            return;
        }
        app.stack.layers[place].shown = shown;
        app.changed = true;
        app.show(app.picture.whole());
    }

    /// The layer painted given an opacity, 0 to 100.
    fn setLayerOpacity(app: *App, level: u32) void {
        const layer = app.stack.currentLayer();
        const opacity: u8 = @intCast(@min(level, 100));
        if (opacity == layer.opacity or !app.haveComposite()) return;
        layer.opacity = opacity;
        app.changed = true;
        app.show(app.picture.whole());
    }

    /// The layer painted given a blend mode.
    fn setBlend(app: *App, which: u32) void {
        if (which >= Blend.count) return;
        const layer = app.stack.currentLayer();
        const mode: Blend = @enumFromInt(which);
        if (mode == layer.blend) return;
        layer.blend = mode;
        app.changed = true;
        app.show(app.picture.whole());
    }

    /// A press on the list of layers: one chosen, shown or hidden by its
    /// eye, moved by a drag, renamed by a double-click.
    fn layerPicked(app: *App, code: u32) void {
        const flags = lb.LISTBROWSER_TOGGLED | lb.LISTBROWSER_MOVED | lb.LISTBROWSER_DOUBLE;
        const row = code & ~flags;
        const count = app.stack.count;
        if (row >= count) return;
        // The list has the top layer first.
        const place = count - 1 - row;
        if (code & lb.LISTBROWSER_TOGGLED != 0) {
            app.showLayer(place, !app.stack.layers[place].shown);
        } else if (code & lb.LISTBROWSER_MOVED != 0) {
            const gui = app.ui() orelse return;
            var from_row: usize = 0;
            _ = app.ib.GetAttr(lb.LISTBROWSER_Moved, gui.layer_list, &from_row);
            app.endShape();
            if (from_row < count) app.moveLayer(count - 1 - @as(u32, @intCast(from_row)), place);
        } else {
            app.chooseLayer(place);
            if (code & lb.LISTBROWSER_DOUBLE != 0) app.renameLayer();
        }
    }

    /// The stack has changed: the layer painted followed, the list made
    /// again, and all shown.
    fn layersChanged(app: *App) void {
        app.changed = true;
        app.paintLayer();
        app.layers_stale = true;
        app.show(app.picture.whole());
    }

    /// The layer painted given the name asked for.
    fn renameLayer(app: *App) void {
        const layer = app.stack.currentLayer();
        var name: [layers_zig.name_size:0]u8 = @splat(0);
        @memcpy(name[0..layers_zig.name_size], &layer.name);
        if (!app.askName(&name)) return;
        layer.setName(name[0..lengthOf(&name)]);
        app.changed = true;
        app.layers_stale = true;
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

    /// paintfx.library from Paint's drawer, opened the first time;
    /// null, said in a requester, when it cannot be.
    fn paintFX(app: *App) ?*PaintFXBase {
        if (app.fx_lib == null) app.fx_lib = app.sys.OpenLibrary(paintfx.PAINTFXPATH, 1);
        return @ptrCast(app.fx_lib orelse {
            app.tellMissing(paintfx.PAINTFXPATH);
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
        const given = project.layers.?[0..@min(project.layer_count, layers_zig.max_layers)];
        const plain = given.len == 1 and given[0].flags & paintio.LAYERF_HIDDEN == 0 and given[0].opacity == 255 and given[0].mask == null;
        if (given.len == 0 or !app.takePicture(project.width, project.height, plain)) {
            app.tellSize(.MSG_NO_PICTURE, .{ project.width, project.height });
            return false;
        }
        // The pixels are the layers' now, not the project's to free.
        app.layer_number = 0;
        for (given) |*from| {
            var layer = Layer{
                .picture = .{ .pixels = from.pixels.?, .width = project.width, .height = project.height },
                .memory = @ptrCast(from.pixels.?),
                .opacity = @intCast((@as(u32, from.opacity) * 100 + 127) / 255),
                .blend = if (from.blend <= paintio.LAYERBLEND_LAST) @enumFromInt(from.blend) else .normal,
                .shown = from.flags & paintio.LAYERF_HIDDEN == 0,
                .id = app.stack.newId(),
            };
            from.pixels = null;
            if (from.mask) |parts| app.takeMaskOf(&layer, parts);
            layer.name = from.name;
            layer.name[layers_zig.name_size - 1] = 0;
            if (layer.name[0] == 0) app.nameLayer(&layer) else app.layer_number += 1;
            app.stack.insert(app.stack.count, layer);
        }
        app.stack.current = @min(project.current, app.stack.count - 1);
        app.showPicture();
        if (project.palette_count != 0) {
            const count = @min(project.palette_count, app.palette.len);
            @memcpy(app.palette[0..count], project.palette[0..count]);
            app.ranges = readRanges(&project.ranges);
            app.showPalette();
            app.retune();
        }
        app.keepPath(name);
        app.writes_back = (project.kind == paintio.PIOKIND_PROJECT) == (formatOf(name) == .project);
        return true;
    }

    /// A mask read from a file - how much each pixel shows, a byte each -
    /// put on `layer` as greys; left off, as a requester says, when there
    /// is no memory for it.
    fn takeMaskOf(app: *App, layer: *Layer, parts: [*]const u8) void {
        const width = layer.picture.width;
        const height = layer.picture.height;
        const memory = app.sys.AllocVec(Picture.bytesFor(width, height), exec.MEMF_ANY) orelse {
            app.tell(.MSG_NO_MASK);
            return;
        };
        const mask = Picture{ .pixels = @ptrCast(@alignCast(memory)), .width = width, .height = height };
        const count = @as(usize, width) * height;
        for (mask.pixels[0..count], parts[0..count]) |*pixel, part| pixel.* = 0xFF00_0000 | @as(Pixel, part) * 0x01_01_01;
        layer.mask = mask;
        layer.mask_memory = memory;
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

    /// The picture written as the name's ending says: a PNG or an ILBM
    /// of what is shown, or a project of every layer with the palette.
    /// Whether it was.
    fn saveTo(app: *App, name: [*:0]const u8) bool {
        const pio = app.paintIO() orelse return false;
        const width = app.picture.width;
        const height = app.picture.height;
        // What is shown, made whole.
        app.stack.compose(app.picture.whole());
        const shown = app.stack.shown().pixels;
        const failure = switch (formatOf(name)) {
            .png => pio.SavePicture(name, shown, width, height, paintio.PIOFORMAT_PNG),
            .ilbm => pio.SavePicture(name, shown, width, height, paintio.PIOFORMAT_ILBM),
            .project => blk: {
                const count = app.stack.count;
                const memory = app.sys.AllocVec(@sizeOf(paintio.Layer) * count, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse break :blk dos.ERROR_NO_FREE_STORE;
                defer app.sys.FreeVec(memory);
                const layers: [*]paintio.Layer = @ptrCast(@alignCast(memory));
                // A mask goes to the file as how much it shows, a byte a
                // pixel, in memory made for the saving.
                defer for (layers[0..count]) |layer| {
                    if (layer.mask) |parts| app.sys.FreeVec(parts);
                };
                for (app.stack.all(), layers[0..count]) |*layer, *into| {
                    into.* = .{
                        .pixels = layer.picture.pixels,
                        .name = layer.name,
                        .opacity = @intCast((@as(u32, layer.opacity) * 255 + 50) / 100),
                        .flags = if (layer.shown) 0 else paintio.LAYERF_HIDDEN,
                        .blend = @intFromEnum(layer.blend),
                    };
                    const mask = layer.mask orelse continue;
                    const pixels = @as(usize, width) * height;
                    const parts: [*]u8 = @ptrCast(app.sys.AllocVec(pixels, exec.MEMF_ANY) orelse break :blk dos.ERROR_NO_FREE_STORE);
                    for (parts[0..pixels], mask.pixels[0..pixels]) |*part, pixel| part.* = layers_zig.shownBy(pixel);
                    into.mask = parts;
                }
                var project = paintio.Project{ .width = width, .height = height, .layer_count = count, .current = app.stack.current, .layers = layers, .palette_count = app.palette.len, .ranges = savedRanges(&app.ranges) };
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
        const view_x: i32 = @truncate(@as(isize, @bitCast(x)));
        const view_y: i32 = @truncate(@as(isize, @bitCast(y)));
        const first = !app.pressing;
        app.pressing = !final;
        // The hand, or Space held: the picture moved, nothing painted.
        if (app.tool == .hand or app.space_held) {
            app.panTo(.{ view_x, view_y }, first);
            return;
        }
        // A transform under way takes every press, whatever the tool.
        if (app.transforming != null) return app.transformTo(view_x, view_y, first);
        const under = app.view.toPicture(view_x, view_y);
        // Far past the picture is as good as just past it.
        const at = Point{ @max(-max_side, @min(2 * max_side, under[0])), @max(-max_side, @min(2 * max_side, under[1])) };
        const menu_button = button == cv.CANVAS_MENU;
        const colour = if (menu_button) app.background else app.foreground;
        app.at = at;
        switch (app.tool) {
            .freehand, .dots, .airbrush, .eraser, .smudge => app.strokeTo(at, colour, menu_button, final),
            .line, .curve, .rectangle, .ellipse, .gradient => app.dragShape(at, colour, menu_button, first, final),
            .polygon => app.polygonTo(at, colour, menu_button, first, final),
            .fill => if (first) app.floodAt(at, colour),
            .pick => if (final) app.pickAt(at, menu_button),
            .text => if (final) app.placeText(at, colour),
            .grab => app.grabTo(at, menu_button, first, final),
            .select_box => app.chooseBoxTo(at, first, final),
            .lasso => app.lassoTo(at, first, final),
            .wand => if (first) app.wandAt(at),
            .hand => {},
            .zoom => if (first) app.zoomClick(view_x, view_y, menu_button),
        }
        // Let go, the pointer is where the brush is shown again.
        if (final) {
            app.hover = at;
            app.at = if (app.picture.inside(at[0], at[1])) at else null;
        }
    }

    /// The hand dragged from where it was pressed, `point` in the view:
    /// the picture follows it.
    fn panTo(app: *App, point: [2]i32, first: bool) void {
        if (first) {
            app.pan_from = point;
            app.pan_start = .{ app.view.left, app.view.top };
            return;
        }
        const was = [2]i32{ app.view.left, app.view.top };
        app.view.panTo(app.pan_start, app.pan_from, point, app.picture.width, app.picture.height);
        if (app.view.left != was[0] or app.view.top != was[1]) app.whole = true;
    }

    /// The brush as a stroke puts it down: an own brush in the stroke's
    /// colour rather than its own colours, when made with the menu
    /// button.
    fn brushFor(app: *const App, menu_button: bool) Brush {
        var used = app.brush;
        if (menu_button) used.mode = .one_colour;
        return used;
    }

    /// The ink a change puts its paint down with: in `colour`, as the
    /// brush's settings say, taking paint away for the eraser.
    fn inkFor(app: *App, colour: Pixel) brush_zig.Ink {
        return .{
            .picture = &app.picture,
            .colour = colour,
            .settings = app.settings,
            .kind = if (app.tool == .eraser) .erase else .paint,
            .mask = app.mask,
            .random = &app.random,
        };
    }

    /// The freehand tools, the airbrush, the eraser and smudge, from
    /// where the pointer was to where it is.
    fn strokeTo(app: *App, at: Point, colour: Pixel, menu_button: bool, final: bool) void {
        const brush = app.brushFor(menu_button);
        if (app.stroke == null) {
            app.stroke = .{ .colour = colour, .menu = menu_button, .ink = app.inkFor(colour) };
            // Smudge first takes up what is under the brush.
            if (app.tool == .smudge and !app.takeUp(brush, at)) {
                app.stroke = null;
                return;
            }
        }
        const stroke = &app.stroke.?;
        var changed = Area.none;
        switch (app.tool) {
            .freehand, .eraser => if (stroke.last) |last| {
                brush_zig.line(&stroke.ink, brush, last[0], last[1], at[0], at[1], &changed);
            } else {
                brush_zig.stamp(&stroke.ink, brush, at[0], at[1], &changed);
                stroke.ink.walked = 1;
            },
            .smudge => if (stroke.last) |last| {
                brush_zig.smearLine(&stroke.ink, brush, &app.carried, last[0], last[1], at[0], at[1], &changed);
            } else {
                stroke.ink.walked = 1;
            },
            .airbrush => brush_zig.spray(&stroke.ink, brush, at[0], at[1], &app.random, &changed),
            else => brush_zig.stamp(&stroke.ink, brush, at[0], at[1], &changed),
        }
        if (final and (app.tool == .freehand or app.tool == .eraser)) brush_zig.finish(&stroke.ink, brush, at[0], at[1], &changed);
        stroke.last = at;
        stroke.changed = stroke.changed.add(changed);
        app.show(changed);
        if (final) app.endStroke();
    }

    /// The colours under the brush at `at` taken up for a smudge, in
    /// memory of their own; false when there is none.
    fn takeUp(app: *App, brush: Brush, at: Point) bool {
        app.dropCarried();
        const box = brush.box();
        const memory = app.sys.AllocVec(Picture.bytesFor(box[0], box[1]), exec.MEMF_ANY) orelse return false;
        app.carried_memory = memory;
        app.carried = .{ .pixels = @ptrCast(@alignCast(memory)), .width = box[0], .height = box[1] };
        brush_zig.takeUp(&app.picture, brush, at[0], at[1], &app.carried);
        return true;
    }

    fn dropCarried(app: *App) void {
        if (app.carried_memory) |memory| app.sys.FreeVec(memory);
        app.carried_memory = null;
    }

    /// A press of the zoom tool at (`x`, `y`) in the view: the next zoom
    /// in, or out with the menu button, the pixel there kept under it.
    fn zoomClick(app: *App, x: i32, y: i32, out: bool) void {
        const zoom = app.view.nextZoom(!out);
        if (zoom == app.view.zoom) return;
        app.view.zoomAt(zoom, x, y, app.picture.width, app.picture.height);
        app.whole = true;
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
        brush_zig.clearMask(app.mask, app.picture.width, drawing.shown);
        var drawn = Area.none;
        const points = drawing.points[0..drawing.count];
        const brush = app.brushFor(drawing.menu);
        var ink = app.inkFor(drawing.colour);
        // The same jitter each time it is drawn again, so it holds still.
        var random = brush_zig.Random{};
        ink.random = &random;
        switch (drawing.tool) {
            .rectangle => shapes.rectangle(&ink, brush, points[0], points[1], app.filled, &drawn),
            .ellipse => shapes.ellipse(&ink, brush, points[0], points[1], app.filled, &drawn),
            .curve => if (points.len == 3)
                shapes.curve(&ink, brush, points[0], points[1], points[2], &drawn)
            else
                app.straight(&ink, brush, points[0], points[1], &drawn),
            .polygon => if (drawing.closed)
                shapes.polygon(&ink, brush, points, app.filled, &drawn)
            else
                shapes.polyline(&ink, brush, points, &drawn),
            .grab => shapes.frame(&app.picture, points[0], points[1], &drawn),
            .gradient => shapes.guide(&app.picture, points[0], points[1], &drawn),
            else => app.straight(&ink, brush, points[0], points[1], &drawn),
        }
        app.show(drawing.shown.add(drawn));
        drawing.shown = drawn;
    }

    /// A straight line from `from` to `to`, its end reached.
    fn straight(_: *App, ink: *brush_zig.Ink, brush: Brush, from: Point, to: Point, drawn: *Area) void {
        brush_zig.line(ink, brush, from[0], from[1], to[0], to[1], drawn);
        brush_zig.finish(ink, brush, to[0], to[1], drawn);
    }

    /// The shape done: a polygon closed, and what it covers kept for
    /// undoing.
    fn endShape(app: *App) void {
        if (app.transforming != null) return app.takeTransform();
        // A brush's frame is never kept: it goes as it is. A gradient's
        // drag goes, and the gradient is laid.
        if (app.drawing) |drawing| if (drawing.tool == .grab or drawing.tool == .gradient) {
            _ = app.cancelShape();
            if (drawing.tool == .gradient) app.shade(drawing);
            return;
        };
        if (app.drawing) |*drawing| if (drawing.tool == .polygon and !drawing.closed) {
            drawing.closed = true;
            app.drawShape();
        };
        const drawing = app.drawing orelse return;
        app.drawing = null;
        brush_zig.clearMask(app.mask, app.picture.width, drawing.shown);
        if (drawing.shown.isEmpty()) return;
        app.changed = true;
        app.recordChange(drawing.shown);
    }

    /// A gradient laid over the layer painted, inside what is chosen: from
    /// the drag's colour at its start to the other colour in use at its
    /// end, with the brush's opacity and dither; round its start with
    /// Round Gradient. One step to undo.
    fn shade(app: *App, drawing: Drawing) void {
        const other = if (drawing.menu) app.foreground else app.background;
        const shading = gradient_zig.Shade.of(drawing.points[0], drawing.points[1], drawing.colour, other, app.round_gradient) orelse return;
        // Laid once, so the flow has nothing to build up.
        var settings = app.settings;
        settings.flow = 100;
        const picture = &app.picture;
        const area = if (app.selection.any()) app.selection.box.clip(picture.width, picture.height) else picture.whole();
        var y = area.min_y;
        while (y < area.max_y) : (y += 1) {
            const row = picture.row(@intCast(y));
            var x = area.min_x;
            while (x < area.max_x) : (x += 1) {
                const pixel = &row[@intCast(x)];
                pixel.* = brush_zig.lay(settings, .paint, pixel.*, shading.at(x, y), 255, 0, x, y).pixel;
            }
        }
        app.changedArea(area);
    }

    /// The shape put away, the picture as it was. False with none.
    fn cancelShape(app: *App) bool {
        if (app.transforming != null) {
            app.dropTransform();
            return true;
        }
        const drawing = app.drawing orelse return false;
        app.drawing = null;
        app.picture.copyArea(&app.kept, drawing.shown);
        brush_zig.clearMask(app.mask, app.picture.width, drawing.shown);
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
        if (app.choosing) app.endChoice(false);
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
            app.picture.fillArea(area, app.emptyColour());
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
        if (app.pressing or app.space_held or app.drawing != null or app.transforming != null or app.gui == null) return null;
        switch (app.tool) {
            .freehand, .dots, .line, .curve, .eraser => {},
            .rectangle, .ellipse, .polygon => if (app.filled) return null,
            else => return null,
        }
        const kind: brush_zig.Kind = if (app.tool == .eraser) .erase else .paint;
        return brush_zig.Ghost.at(app.brush, at[0], at[1], app.foreground, app.settings, kind);
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
            .kind = shown.kind,
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
            const colour = app.stack.pixelAt(@intCast(at[0]), @intCast(at[1]));
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
        app.dropCarried();
        brush_zig.clearMask(app.mask, app.picture.width, stroke.changed);
        if (stroke.changed.isEmpty()) return;
        app.changed = true;
        app.recordChange(stroke.changed);
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
    }

    /// Whether a stroke or a shape is being made in the layer painted.
    fn changeUnderWay(app: *const App) bool {
        if (app.stroke != null) return true;
        const drawing = app.drawing orelse return false;
        return drawing.tool != .grab;
    }

    /// The outline to show: of the choice being made, or of the
    /// selection when it is to be shown; null for none.
    fn outlineShown(app: *const App) ?Outline {
        if (app.transforming != null) return null;
        if (app.choosing) return if (app.scratch.box.isEmpty()) null else app.scratch.outline();
        if (!app.show_outline or !app.selection.any()) return null;
        return app.selection.outline();
    }

    /// What is pending drawn into the canvas and shown, with the status
    /// and the menus brought up to date.
    fn flush(app: *App) void {
        const gui = app.ui() orelse return;
        const pointer_brush = app.pointerBrush();
        app.followPointerBrush(pointer_brush);
        // A change being made shown only where it may go, and the layers
        // made into what is shown where they changed.
        if (app.changeUnderWay()) app.selection.stencil(&app.picture, &app.kept, app.pending);
        app.stack.compose(app.pending);
        app.view.turned = if (app.cycling and !app.show_mask) &app.turned else null;
        const outline = app.outlineShown();
        const frame = if (app.transforming) |moving| app.frameOf(moving.shape) else null;
        app.view.frame = if (frame) |*shown| shown else null;
        defer app.view.frame = null;
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
                    app.view.row(app.viewed(), y + row, area.min_x, area.max_x, band[start .. start + width], if (pointer_brush) |*shown| shown else null, if (outline) |*shown| shown else null);
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
        app.syncPanel();
        app.syncTitle();
    }

    /// The view scrolled by picture pixels.
    fn scrollBy(app: *App, across: i32, down: i32) void {
        app.view.left += across;
        app.view.top += down;
        app.view.fit(app.picture.width, app.picture.height);
        app.whole = true;
    }

    /// The zoom changed about the view's middle.
    fn zoomTo(app: *App, zoom: u32) void {
        if (zoom == app.view.zoom) return;
        app.view.zoomAt(zoom, @intCast(app.view.width / 2), @intCast(app.view.height / 2), app.picture.width, app.picture.height);
        app.whole = true;
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
            .layers = app.stack.count,
            .current = app.stack.current,
            .selected = app.selection.any(),
            .has_mask = app.stack.layers[app.stack.current].mask != null,
            .painting_mask = app.painting_mask,
            .cycling = app.cycling,
            .round_gradient = app.round_gradient,
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

    /// The side panel and the zoom bar set from the brush, the foreground
    /// and the zoom, where they changed.
    fn syncPanel(app: *App) void {
        const gui = app.ui() orelse return;
        app.syncLayers(gui);
        const shape: u32 = if (app.brush.own != null) 2 else if (app.brush.shape == .round) 0 else 1;
        if (gui.shown_shape == null or gui.shown_shape.? != shape) {
            gui.shown_shape = shape;
            _ = app.ib.SetGadgetAttrsTagList(gui.shape, gui.window, &[_]TagItem{ .{ .tag = ch.CHOOSER_Active, .data = shape }, .{} });
        }
        // An own brush has a size of its own: the slider waits.
        const size = @min(app.brush.size, panel_brush_max);
        const size_off = app.brush.own != null;
        if (gui.shown_size == null or gui.shown_size.? != size or gui.shown_size_off.? != size_off) {
            gui.shown_size = size;
            gui.shown_size_off = size_off;
            _ = app.ib.SetGadgetAttrsTagList(gui.size, gui.window, &[_]TagItem{
                .{ .tag = sl.SLIDER_Level, .data = size },
                .{ .tag = gc.GA_Disabled, .data = @intFromBool(size_off) },
                .{},
            });
        }
        if (gui.shown_colour == null or gui.shown_colour.? != app.foreground) {
            gui.shown_colour = app.foreground;
            const rgb = wheelRGB(app.foreground);
            _ = app.ib.SetGadgetAttrsTagList(gui.wheel, gui.window, &[_]TagItem{ .{ .tag = cw.WHEEL_RGB, .data = @intFromPtr(&rgb) }, .{} });
            app.showShades();
        }
        if (gui.shown_zoom == null or gui.shown_zoom.? != app.view.zoom) {
            gui.shown_zoom = app.view.zoom;
            const made = app.text.format(&app.zoom_line, .MSG_ZOOM, .{@as(i64, app.view.zoom) * 100});
            app.zoom_line[@min(made.len, app.zoom_line.len)] = 0;
            _ = app.ib.SetGadgetAttrsTagList(gui.zoom_text, gui.window, &[_]TagItem{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&app.zoom_line) }, .{} });
        }
    }

    /// The brightness slider running from the foreground at its brightest
    /// to black.
    fn showShades(app: *App) void {
        const gui = app.ui() orelse return;
        const brightest = brightestOf(app.foreground);
        if (app.shades[0] == brightest) return;
        app.shades[0] = brightest;
        _ = app.ib.SetGadgetAttrsTagList(gui.brightness, gui.window, &[_]TagItem{ .{ .tag = gs.GRAD_PenArray, .data = @intFromPtr(&app.shades) }, .{} });
    }

    /// The foreground taken from the colour wheel and its brightness.
    fn takeColour(app: *App) void {
        const gui = app.ui() orelse return;
        var rgb: cw.ColorWheelRGB align(@alignOf(usize)) = .{};
        _ = app.ib.GetAttr(cw.WHEEL_RGB, gui.wheel, @ptrCast(&rgb));
        const colour: Pixel = 0xFF00_0000 | (rgb.red >> 24) << 16 | (rgb.green >> 24) << 8 | rgb.blue >> 24;
        if (colour == app.foreground) return;
        app.foreground = colour;
        // The wheel shows it already.
        gui.shown_colour = colour;
        app.showShades();
        app.drawColours();
        app.drawShape();
    }

    /// The brush's shape picked in the panel: an own brush only when
    /// there is one, the chooser put back otherwise.
    fn pickShape(app: *App, place: u32) void {
        const which: Command = switch (place) {
            0 => .round,
            1 => .square,
            else => .own_brush,
        };
        _ = app.perform(which);
        if (app.ui()) |gui| gui.shown_shape = null;
    }

    /// The Layers section set from the stack, where it changed: the list
    /// made again when the layers did, the layer painted chosen in it,
    /// its opacity and its blend mode.
    fn syncLayers(app: *App, gui: *Gui) void {
        const count = app.stack.count;
        const current = app.stack.current;
        if (app.layers_stale) {
            app.layers_stale = false;
            _ = app.ib.SetGadgetAttrsTagList(gui.layer_list, gui.window, &[_]TagItem{ .{ .tag = lb.LISTBROWSER_Rows, .data = lb.LISTBROWSER_DETACH }, .{} });
            app.buildLayerRows();
            _ = app.ib.SetGadgetAttrsTagList(gui.layer_list, gui.window, &[_]TagItem{ .{ .tag = lb.LISTBROWSER_Rows, .data = @intFromPtr(&app.layer_rows) }, .{} });
            gui.shown_layer = null;
        }
        if (gui.shown_layer == null or gui.shown_layer.? != current) {
            gui.shown_layer = current;
            _ = app.ib.SetGadgetAttrsTagList(gui.layer_list, gui.window, &[_]TagItem{ .{ .tag = lb.LISTBROWSER_Selected, .data = count - 1 - current }, .{} });
        }
        const layer = app.stack.currentLayer();
        if (gui.shown_layer_opacity == null or gui.shown_layer_opacity.? != layer.opacity) {
            gui.shown_layer_opacity = layer.opacity;
            _ = app.ib.SetGadgetAttrsTagList(gui.layer_opacity, gui.window, &[_]TagItem{ .{ .tag = sl.SLIDER_Level, .data = layer.opacity }, .{} });
        }
        if (gui.shown_blend == null or gui.shown_blend.? != layer.blend) {
            gui.shown_blend = layer.blend;
            _ = app.ib.SetGadgetAttrsTagList(gui.blend, gui.window, &[_]TagItem{ .{ .tag = ch.CHOOSER_Active, .data = @intFromEnum(layer.blend) }, .{} });
        }
    }

    /// The list's rows made again from the stack, top layer first: each
    /// its eye, on while the layer is shown, its name, and whether it has
    /// a mask and the mask is painted.
    fn buildLayerRows(app: *App) void {
        const sys = app.sys;
        lb.freeRows(sys, &app.layer_rows);
        var place = app.stack.count;
        while (place > 0) {
            place -= 1;
            const layer = &app.stack.layers[place];
            const mask: [*:0]const u8 = if (layer.mask == null)
                ""
            else if (app.painting_mask and place == app.stack.current)
                app.text.get(.MSG_MASK_PAINTED)
            else
                app.text.get(.MSG_MASK_ROW);
            const row = lb.allocRow(sys, &.{ "", @as([*:0]const u8, @ptrCast(&layer.name)), mask }, 0) orelse continue;
            row.flags = if (layer.shown) lb.ROW_ON else 0;
            row.user_data = layer.id;
            sys.AddTail(&app.layer_rows, &row.node);
        }
    }

    /// A brush setting as its slider shows it.
    fn settingLevel(app: *const App, which: Setting) u32 {
        return switch (which) {
            .softness => app.brush.softness,
            .opacity => app.settings.opacity,
            .flow => app.settings.flow,
            .jitter => app.settings.jitter,
            .rotation => app.brush.rotation,
        };
    }

    /// A brush setting from its slider.
    fn setSetting(app: *App, which: Setting, level: u32) void {
        const entry = setting_entries[@intFromEnum(which)];
        const value = @max(entry.least, @min(level, entry.most));
        if (value == app.settingLevel(which)) return;
        switch (which) {
            .softness => app.brush.softness = @intCast(value),
            .opacity => app.settings.opacity = @intCast(value),
            .flow => app.settings.flow = @intCast(value),
            .jitter => app.settings.jitter = @intCast(value),
            .rotation => app.brush.rotation = @intCast(value),
        }
        // The brush under the pointer shown again.
        app.brush_changes +%= 1;
    }

    /// The brush's size from the panel's slider: a built-in brush that
    /// size.
    fn sizeBrush(app: *App, level: u32) void {
        const size = @max(1, @min(level, panel_brush_max));
        if (app.brush.own != null or app.brush.size == size) return;
        app.brush.size = size;
        if (app.ui()) |gui| gui.shown_size = size;
        app.drawShape();
    }

    /// A section of the side panel folded or unfolded, as its button
    /// now is, and the window laid out again round it.
    fn foldSection(app: *App, place: usize, open: bool) void {
        const gui = app.ui() orelse return;
        app.open_sections[place] = open;
        _ = app.ib.SetGadgetAttrsTagList(gui.section_buttons[place], gui.window, &[_]TagItem{ .{ .tag = tb.TOOLBUTTON_Image, .data = @intFromPtr(gui.fold_images[@intFromBool(open)]) }, .{} });
        _ = app.ib.SetGadgetAttrsTagList(gui.panel, gui.window, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_ModifyChild, .data = @intFromPtr(gui.section_bodies[place]) },
            .{ .tag = lg.CHILDA_Hidden, .data = @intFromBool(!open) },
            .{},
        });
        // Laid out again, the picture's box with it.
        var again = wc.WmRethink{};
        _ = app.ib.SendMessage(gui.object, @ptrCast(&again));
        app.fitView();
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
            .new_layer, .duplicate_layer, .delete_layer, .layer_up, .layer_down, .merge_down, .flip_layer_across, .flip_layer_down => app.endShape(),
            .select_all, .select_layer, .select_colour, .select_see_through, .select_not_in_palette, .deselect, .invert_selection, .copy_to_layer, .cut_to_layer, .copy_to_brush => app.endShape(),
            .mask_show_all, .mask_hide_all, .mask_selection, .paint_mask, .apply_mask, .delete_mask, .edit_palette, .reduce_plain, .reduce_ordered, .reduce_diffused, .image_turn_right, .image_turn_left, .image_turn_half, .image_flip_across, .image_flip_down, .crop, .trim, .canvas_size, .flatten, .picture_size, .effects => app.endShape(),
            else => {},
        }
        switch (which) {
            .new => if (app.mayLeave()) {
                if (app.askSize(.MSG_NEW_TITLE, .plain)) |size| {
                    if (app.newPicture(size[0], size[1])) app.forgetPath() else app.tellSize(.MSG_NO_PICTURE, size);
                }
            },
            .open => if (app.mayLeave()) {
                var name: [path_size:0]u8 = undefined;
                if (app.askFile(app.text.get(.MSG_OPEN_TITLE), false, &app.path, &name)) _ = app.load(&name);
            },
            .save => _ = app.saveKept(),
            .save_as => _ = app.saveAs(),
            .quit => return !app.mayLeave(),
            .undo => {
                const painted = app.stack.currentLayer().id;
                if (app.history.undo(&app.stack)) |change| {
                    if (app.followSize()) app.applied(change, painted) else {
                        // Done again, the picture is the size it was.
                        _ = app.history.redo(&app.stack);
                        app.tell(.MSG_NO_IMAGE_MEMORY);
                    }
                }
                if (app.show_mask) app.whole = true;
            },
            .redo => {
                const painted = app.stack.currentLayer().id;
                if (app.history.redo(&app.stack)) |change| {
                    if (app.followSize()) app.applied(change, painted) else {
                        _ = app.history.undo(&app.stack);
                        app.tell(.MSG_NO_IMAGE_MEMORY);
                    }
                }
                if (app.show_mask) app.whole = true;
            },
            .swap => {
                const was = app.foreground;
                app.foreground = app.background;
                app.background = was;
                app.drawColours();
            },
            .clear => {
                app.picture.fill(app.emptyColour());
                app.changedArea(app.picture.whole());
            },
            .zoom_in => app.zoomTo(app.view.nextZoom(true)),
            .zoom_out => app.zoomTo(app.view.nextZoom(false)),
            .actual_size => app.zoomTo(1),
            .fit => app.zoomTo(app.view.fitZoom(app.picture.width, app.picture.height)),
            .new_layer => app.addLayer(false),
            .duplicate_layer => app.addLayer(true),
            .delete_layer => app.deleteLayer(),
            .rename_layer => app.renameLayer(),
            .layer_up => app.moveLayer(app.stack.current, app.stack.current + 1),
            .layer_down => if (app.stack.current > 0) app.moveLayer(app.stack.current, app.stack.current - 1),
            .merge_down => app.mergeDown(),
            .flip_layer_across => app.flipLayer(true),
            .flip_layer_down => app.flipLayer(false),
            .select_all => app.selectAll(),
            .select_layer => app.selectBy(.layer),
            .select_colour => app.selectBy(.colour),
            .select_see_through => app.selectBy(.see_through),
            .select_not_in_palette => app.selectBy(.not_in_palette),
            .deselect => app.deselect(),
            .invert_selection => app.invertSelection(),
            .copy_to_layer => app.selectionToLayer(false),
            .cut_to_layer => app.selectionToLayer(true),
            .copy_to_brush => app.selectionToBrush(),
            .mask_show_all => app.addMask(.show_all),
            .mask_hide_all => app.addMask(.hide_all),
            .mask_selection => app.addMask(.selection),
            .paint_mask => app.paintMask(!app.painting_mask),
            .apply_mask => app.takeMask(true),
            .delete_mask => app.takeMask(false),
            .edit_palette => app.editPalette(),
            .palette_from_picture => app.paletteFromPicture(),
            .preset_standard => app.setPalette(&palette_zig.standard),
            .preset_greys => app.setPalette(&palette_zig.greys),
            .preset_spectrum => app.setPalette(&palette_zig.spectrum),
            .preset_pastel => app.setPalette(&palette_zig.pastel),
            .preset_earth => app.setPalette(&palette_zig.earth),
            .open_palette => app.openPalette(),
            .save_palette => app.savePalette(),
            .reduce_plain => app.reduce(.none),
            .reduce_ordered => app.reduce(.ordered),
            .reduce_diffused => app.reduce(.diffused),
            .cycle => app.cycle(!app.cycling),
            .round_gradient => app.round_gradient = !app.round_gradient,
            .image_turn_right => app.changeImage(.turn_right),
            .image_turn_left => app.changeImage(.turn_left),
            .image_turn_half => app.changeImage(.turn_half),
            .image_flip_across => app.changeImage(.flip_across),
            .image_flip_down => app.changeImage(.flip_down),
            .crop => app.crop(),
            .trim => app.trim(),
            .canvas_size => app.canvasSize(),
            .flatten => app.flatten(),
            .picture_size => app.pictureSize(),
            .effects => app.effects(),
            // Asked again while one is under way, it takes it.
            .free_transform => if (app.transforming != null) app.endShape() else app.freeTransform(),
            .about => app.about(),
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
            '\t' => _ = app.perform(.cycle),
            'F' => _ = app.perform(.filled),
            'h' => _ = app.perform(.flip_across),
            'v' => _ = app.perform(.flip_down),
            'z' => _ = app.perform(.turn),
            // Return ends a polygon or a curve as it is, Escape puts it
            // away.
            '\r' => app.endShape(),
            0x1B => if (!app.cancelShape()) app.deselect(),
            // Space held moves the picture; its release comes as a raw
            // key.
            ' ' => app.space_held = true,
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
            raw_space | raw_released => app.space_held = false,
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
        app.tellName(.MSG_NO_PART, name);
    }

    /// A requester whose `message` takes a name.
    fn tellName(app: *App, comptime message: Id, name: [*:0]const u8) void {
        const gui = app.ui() orelse return;
        comptime sdk.exec.checkFormat(strings.builtin(message), struct { [*:0]const u8 });
        const easy = intuition.requesters.EasyStruct{ .title = COMMAND_NAME, .text_format = app.text.get(message), .gadget_format = app.text.get(.MSG_OK) };
        const args = [_]usize{@intFromPtr(name)};
        _ = app.ib.EasyRequestArgs(gui.window, &easy, null, &args);
    }

    /// What Paint is, and its version.
    fn about(app: *App) void {
        const gui = app.ui() orelse return;
        comptime sdk.exec.checkFormat(strings.builtin(.MSG_ABOUT), struct { [*:0]const u8 });
        const easy = intuition.requesters.EasyStruct{ .title = COMMAND_NAME, .text_format = app.text.get(.MSG_ABOUT), .gadget_format = app.text.get(.MSG_OK) };
        const args = [_]usize{@intFromPtr(VERSION)};
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

    /// A picture's size, asked in a window of its own titled `title`,
    /// with what `question` asks besides - where on the canvas the
    /// picture goes, or how it is scaled - read from there and written
    /// back: null when it was closed or cancelled.
    fn askSize(app: *App, comptime title: Id, question: SizeQuestion) ?[2]u32 {
        const gui = app.ui() orelse return null;
        const lib = app.sys.OpenLibrary(ig.INTEGER_LIBRARY, 0) orelse return null;
        defer app.sys.CloseLibrary(lib);
        const ib = app.ib;
        var made = Builder{ .ib = ib };
        const fields = [2]?*Object{ made.take(integerField(ib, ID_WIDTH, app.picture.width)), made.take(integerField(ib, ID_HEIGHT, app.picture.height)) };
        const answers = [2]?*Object{ made.take(textButton(ib, app.text.get(.MSG_OK), ID_OK)), made.take(textButton(ib, app.text.get(.MSG_CANCEL), ID_CANCEL)) };
        // Made at run time, so the lists' ends are set as the rest is.
        var place_labels: [place_texts.len:null]?[*:0]const u8 = @splat(null);
        for (&place_labels, place_texts) |*label, text| label.* = app.text.get(text);
        var scale_labels: [scale_texts.len:null]?[*:0]const u8 = @splat(null);
        for (&scale_labels, scale_texts) |*label, text| label.* = app.text.get(text);
        const choice: ?*Object = switch (question) {
            .plain => null,
            .place => |where| made.take(ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
                .{ .tag = gc.GA_ID, .data = ID_PLACE },
                .{ .tag = ch.CHOOSER_Labels, .data = @intFromPtr(&place_labels) },
                .{ .tag = ch.CHOOSER_Active, .data = @min(where.*, place_texts.len - 1) },
                .{},
            })),
            .scale => |scaling| made.take(ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
                .{ .tag = gc.GA_ID, .data = ID_SCALING },
                .{ .tag = ch.CHOOSER_Labels, .data = @intFromPtr(&scale_labels) },
                .{ .tag = ch.CHOOSER_Active, .data = @intFromBool(!scaling.smooth) },
                .{},
            })),
        };
        const keep_box: ?*Object = switch (question) {
            .scale => |scaling| made.take(ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
                .{ .tag = gc.GA_ID, .data = ID_KEEP },
                .{ .tag = cb.CHECKBOX_Checked, .data = @intFromBool(scaling.keep) },
                .{},
            })),
            else => null,
        };
        const row = made.layout(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(answers[0]) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(answers[1]) },
            .{},
        });
        const choice_label: Id = if (question == .scale) .MSG_SCALING else .MSG_PLACE;
        const ignore = sdk.utility.TAG_IGNORE;
        const layout = made.layout(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(fields[0]) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(.MSG_WIDTH)) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(fields[1]) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(.MSG_HEIGHT)) },
            .{ .tag = if (choice != null) lg.LAYOUTA_AddChild else ignore, .data = @intFromPtr(choice) },
            .{ .tag = if (choice != null) lg.CHILDA_Label else ignore, .data = @intFromPtr(app.text.get(choice_label)) },
            .{ .tag = if (keep_box != null) lg.LAYOUTA_AddChild else ignore, .data = @intFromPtr(keep_box) },
            .{ .tag = if (keep_box != null) lg.CHILDA_Label else ignore, .data = @intFromPtr(app.text.get(.MSG_KEEP_PROPORTIONS)) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(row) },
            .{},
        });
        if (made.failed or layout == null) {
            made.drop();
            return null;
        }
        const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
            screenTag(gui),
            .{ .tag = wn.WA_Title, .data = @intFromPtr(app.text.get(title)) },
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
            made.drop();
            return null;
        };
        made.keep(layout.?);
        defer ib.DisposeObject(object);
        var open = wc.WmOpen{};
        if (ib.SendMessage(object, @ptrCast(&open)) == 0) return null;
        const window: *Window = @ptrFromInt(windowOf(ib, object));
        const asked = SizeWindow{ .fields = fields, .choice = choice, .keep_box = keep_box, .question = question };

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
                        ID_OK, ID_HEIGHT => return answered(ib, &asked),
                        else => {},
                    },
                    // Return with no field typed into is OK, Escape Cancel.
                    wc.WMHI_VANILLAKEY => switch (word & wc.WMHI_KEYMASK) {
                        '\r' => return answered(ib, &asked),
                        0x1B => return null,
                        else => {},
                    },
                    else => {},
                }
            }
        }
    }

    /// A layer's name, asked in a window of its own starting from `name`
    /// and written back there: false when it was closed or cancelled.
    fn askName(app: *App, name: *[layers_zig.name_size:0]u8) bool {
        const gui = app.ui() orelse return false;
        const sys = app.sys;
        const string_lib = sys.OpenLibrary(sg.STRING_LIBRARY, 0) orelse return false;
        defer sys.CloseLibrary(string_lib);
        const ib = app.ib;
        const field = ib.NewObjectTagList(null, sg.STRING_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_NAME },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = gc.STRINGA_MaxChars, .data = layers_zig.name_size },
            .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(name) },
            .{},
        });
        const answers = [2]?*Object{ textButton(ib, app.text.get(.MSG_OK), ID_OK), textButton(ib, app.text.get(.MSG_CANCEL), ID_CANCEL) };
        if (field == null or answers[0] == null or answers[1] == null) {
            for ([_]?*Object{field} ++ answers) |made| ib.DisposeObject(made);
            return false;
        }
        const row = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(answers[0]) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(answers[1]) },
            .{},
        }) orelse {
            for ([_]?*Object{field} ++ answers) |made| ib.DisposeObject(made);
            return false;
        };
        const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(field) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(.MSG_NAME)) },
            .{ .tag = lg.CHILDA_MinWidth, .data = 200 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(row) },
            .{},
        }) orelse {
            ib.DisposeObject(row);
            ib.DisposeObject(field);
            return false;
        };
        const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
            screenTag(gui),
            .{ .tag = wn.WA_Title, .data = @intFromPtr(app.text.get(.MSG_RENAME_TITLE)) },
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
                const done = switch (word & wc.WMHI_CLASSMASK) {
                    wc.WMHI_CLOSEWINDOW => return false,
                    wc.WMHI_ACTIVE => blk: {
                        _ = ib.ActivateGadget(field.?, window, null);
                        break :blk false;
                    },
                    wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                        ID_CANCEL => return false,
                        ID_OK, ID_NAME => true,
                        else => false,
                    },
                    wc.WMHI_VANILLAKEY => switch (word & wc.WMHI_KEYMASK) {
                        '\r' => true,
                        0x1B => return false,
                        else => false,
                    },
                    else => false,
                };
                if (!done) continue;
                var value: usize = 0;
                if (ib.GetAttr(gc.STRINGA_TextVal, field.?, &value) == 0 or value == 0) return false;
                copyName(name, @ptrFromInt(value));
                return true;
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
            app.qualifier = qualifier;
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
                    ID_SHAPE => app.pickShape(code),
                    ID_SIZE => app.sizeBrush(code),
                    ID_WHEEL, ID_BRIGHTNESS => app.takeColour(),
                    ID_LAYERS => app.layerPicked(code),
                    ID_LAYER_OPACITY => app.setLayerOpacity(code),
                    ID_BLEND => app.setBlend(code),
                    ID_LAYER_ADD => _ = app.perform(.new_layer),
                    ID_LAYER_DELETE => _ = app.perform(.delete_layer),
                    ID_OUTLINE => {
                        app.show_outline = code != 0;
                        app.show(app.selection.box);
                    },
                    ID_SHOW_MASK => {
                        app.show_mask = code != 0;
                        app.whole = true;
                    },
                    else => |id| {
                        if (id >= ID_SECTION and id < ID_SECTION + section_names.len) {
                            app.foldSection(id - ID_SECTION, code != 0);
                        } else if (id >= ID_SETTING and id < ID_SETTING + setting_entries.len) {
                            app.setSetting(@enumFromInt(id - ID_SETTING), code);
                        } else if (id == ID_DITHER) {
                            app.settings.dither = code != 0;
                            app.brush_changes +%= 1;
                        } else if (Tool.of(id)) |tool| {
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
                // The pointer on the picture, the size's slider or the
                // colour's wheel moved.
                wc.WMHI_IDCMPUPDATE => switch (gadget) {
                    ID_VIEW => app.paintTo(qualifier & ie.IEQUALIFIER_REPEAT == 0),
                    ID_SIZE => {
                        var level: usize = 0;
                        _ = app.ib.GetAttr(sl.SLIDER_Level, gui.size, &level);
                        app.sizeBrush(@truncate(level));
                    },
                    ID_WHEEL, ID_BRIGHTNESS => app.takeColour(),
                    ID_LAYER_OPACITY => {
                        var level: usize = 0;
                        _ = app.ib.GetAttr(sl.SLIDER_Level, gui.layer_opacity, &level);
                        app.setLayerOpacity(@truncate(level));
                    },
                    else => |id| if (id >= ID_SETTING and id < ID_SETTING + setting_entries.len) {
                        var level: usize = 0;
                        _ = app.ib.GetAttr(sl.SLIDER_Level, gui.setting_sliders[id - ID_SETTING], &level);
                        app.setSetting(@enumFromInt(id - ID_SETTING), @truncate(level));
                    },
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
                    app.space_held = false;
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
            const clock: u32 = if (app.clock_port) |port| port.sigMask() else 0;
            const got = app.sys.Wait(@as(u32, @truncate(signal)) | exec.SIGBREAKF_CTRL_C | clock);
            if (got & clock != 0) app.beat();
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

        // The pictures of the tools and the commands, and of a section
        // folded and unfolded.
        for (tools, 0..) |entry, place| gui.images[place] = glyph(ib, entry.glyph);
        for (buttons, tools.len..) |entry, place| gui.images[place] = glyph(ib, entry.glyph);
        gui.fold_images = .{ glyph(ib, command.CMD_FOLDED), glyph(ib, command.CMD_UNFOLDED) };
        gui.layer_images = .{ glyph(ib, command.CMD_EYE), glyph(ib, command.CMD_NEW), glyph(ib, command.CMD_DELETE) };
        for (&app.blend_labels, blend_names) |*label, id| label.* = app.text.get(id);
        app.layer_columns = .{
            .{ .title = "", .weight = 1, .flags = lb.COLUMN_TOGGLE | lb.COLUMN_NOSORT, .image = gui.layer_images[0] },
            .{ .title = "", .weight = 5, .flags = lb.COLUMN_NOSORT },
            .{ .title = "", .weight = 2, .flags = lb.COLUMN_NOSORT },
            .{},
        };
        app.buildLayerRows();
        for (&app.shape_labels, [_]Id{ .MSG_MENU_ROUND, .MSG_MENU_SQUARE, .MSG_MENU_OWN_BRUSH }) |*label, id| label.* = app.text.get(id);

        // The gadgets, the program's to dispose of until a layout takes
        // them.
        var made = Builder{ .ib = ib };
        var tool_gadgets: [tools.len]?*Object = undefined;
        for (tools, 0..) |entry, place| tool_gadgets[place] = made.take(toolButton(ib, entry.tool.id(), gui.images[place], app.text.get(entry.hint), tb.TBKIND_TOGGLE));
        var button_gadgets: [buttons.len]?*Object = undefined;
        for (buttons, 0..) |entry, place| button_gadgets[place] = made.take(toolButton(ib, entry.which.id(), gui.images[tools.len + place], app.text.get(entry.hint), entry.kind));
        // The Layers section: the list, top layer first, the opacity with
        // the buttons that delete and add, the blend mode.
        // Room for a few rows; as wide as the panel makes it.
        const line_height: u32 = if (info.font) |font| font.image.height else 8;
        const layer_list = made.take(ib.NewObjectTagList(null, lb.LISTBROWSER_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_LAYERS },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = lb.LISTBROWSER_Columns, .data = @intFromPtr(&app.layer_columns) },
            .{ .tag = lb.LISTBROWSER_Rows, .data = @intFromPtr(&app.layer_rows) },
            .{ .tag = lb.LISTBROWSER_Headings, .data = 0 },
            .{ .tag = lb.LISTBROWSER_Reorder, .data = 1 },
            .{ .tag = lb.LISTBROWSER_Selected, .data = app.stack.count - 1 - app.stack.current },
            .{ .tag = gc.GA_Width, .data = 100 },
            .{ .tag = gc.GA_Height, .data = layer_rows_shown * line_height + 6 },
            .{},
        }));
        const layer_opacity = made.take(ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_LAYER_OPACITY },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
            .{ .tag = sl.SLIDER_Min, .data = 0 },
            .{ .tag = sl.SLIDER_Max, .data = 100 },
            .{ .tag = sl.SLIDER_Level, .data = app.stack.currentLayer().opacity },
            .{ .tag = sl.SLIDER_LevelFormat, .data = @intFromPtr("%ld%%") },
            .{ .tag = sl.SLIDER_LevelPlace, .data = sl.SLIDER_PLACE_RIGHT },
            .{ .tag = sl.SLIDER_MaxLevelLen, .data = level_room },
            .{},
        }));
        const layer_delete = made.take(toolButton(ib, ID_LAYER_DELETE, gui.layer_images[2], app.text.get(.MSG_DELETE_LAYER_HINT), tb.TBKIND_PUSH));
        const layer_add = made.take(toolButton(ib, ID_LAYER_ADD, gui.layer_images[1], app.text.get(.MSG_NEW_LAYER_HINT), tb.TBKIND_PUSH));
        const blend = made.take(ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_BLEND },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = ch.CHOOSER_Labels, .data = @intFromPtr(&app.blend_labels) },
            .{ .tag = ch.CHOOSER_Active, .data = @intFromEnum(app.stack.currentLayer().blend) },
            .{},
        }));
        var section_gadgets: [section_names.len]?*Object = undefined;
        for (section_names, 0..) |name, place| {
            const open = app.open_sections[place];
            section_gadgets[place] = made.take(sectionButton(ib, ID_SECTION + @as(u32, @intCast(place)), gui.fold_images[@intFromBool(open)], app.text.get(name), open));
        }
        const view = made.take(ib.NewObjectTagList(null, cv.CANVAS_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_VIEW },
            .{ .tag = gc.GA_MenuButton, .data = 1 },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
            .{},
        }));
        const colours_box = made.take(ib.NewObjectTagList(null, cv.CANVAS_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_COLOURS },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = cv.CANVAS_Width, .data = 30 },
            .{ .tag = cv.CANVAS_Height, .data = 30 },
            .{},
        }));
        const palette = made.take(ib.NewObjectTagList(null, pa.PALETTE_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_PALETTE },
            .{ .tag = gc.GA_MenuButton, .data = 1 },
            .{ .tag = pa.PALETTE_ColorTable, .data = @intFromPtr(&app.palette) },
            .{ .tag = pa.PALETTE_NumColors, .data = app.palette.len },
            .{ .tag = pa.PALETTE_Color, .data = app.foreground_index },
            .{},
        }));
        const status = made.take(ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_STATUS },
            .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&app.status) },
            .{ .tag = tx.TEXT_RoomFor, .data = @intFromPtr("16384 x 16384   16:1   brush 1024 x 1024   at -00000, -00000") },
            .{},
        }));
        const zoom_text = made.take(ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_ZOOM },
            .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&app.zoom_line) },
            .{ .tag = tx.TEXT_RoomFor, .data = @intFromPtr("1600 %") },
            .{ .tag = tx.TEXT_Justification, .data = tx.TEXT_JUSTIFY_CENTER },
            .{},
        }));
        const shape = made.take(ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_SHAPE },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = ch.CHOOSER_Labels, .data = @intFromPtr(&app.shape_labels) },
            .{ .tag = ch.CHOOSER_Active, .data = 0 },
            .{},
        }));
        const size = made.take(ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_SIZE },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
            .{ .tag = sl.SLIDER_Min, .data = 1 },
            .{ .tag = sl.SLIDER_Max, .data = panel_brush_max },
            .{ .tag = sl.SLIDER_Level, .data = @min(app.brush.size, panel_brush_max) },
            .{ .tag = sl.SLIDER_LevelFormat, .data = @intFromPtr("%ld") },
            .{ .tag = sl.SLIDER_LevelPlace, .data = sl.SLIDER_PLACE_RIGHT },
            .{ .tag = sl.SLIDER_MaxLevelLen, .data = level_room },
            .{},
        }));
        var setting_gadgets: [setting_entries.len]?*Object = undefined;
        for (setting_entries, 0..) |entry, place| {
            setting_gadgets[place] = made.take(ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
                .{ .tag = gc.GA_ID, .data = ID_SETTING + place },
                .{ .tag = gc.GA_RelVerify, .data = 1 },
                .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
                .{ .tag = sl.SLIDER_Min, .data = entry.least },
                .{ .tag = sl.SLIDER_Max, .data = entry.most },
                .{ .tag = sl.SLIDER_Level, .data = app.settingLevel(@enumFromInt(place)) },
                .{ .tag = sl.SLIDER_LevelFormat, .data = @intFromPtr(entry.format) },
                .{ .tag = sl.SLIDER_LevelPlace, .data = sl.SLIDER_PLACE_RIGHT },
                .{ .tag = sl.SLIDER_MaxLevelLen, .data = level_room },
                .{},
            }));
        }
        const dither = made.take(ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_DITHER },
            .{ .tag = gc.GA_Selected, .data = @intFromBool(app.settings.dither) },
            .{},
        }));
        app.shades[0] = brightestOf(app.foreground);
        const brightness = made.take(ib.NewObjectTagList(null, gs.GRAD_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_BRIGHTNESS },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
            .{ .tag = sdk.intuition.propgclass.PGA_Freedom, .data = sdk.intuition.propgclass.FREEVERT },
            .{ .tag = gc.GA_Width, .data = 18 },
            .{ .tag = gc.GA_Height, .data = 140 },
            .{ .tag = gs.GRAD_PenArray, .data = @intFromPtr(&app.shades) },
            .{ .tag = gs.GRAD_KnobPixels, .data = 7 },
            .{},
        }));
        const rgb = wheelRGB(app.foreground);
        const wheel = if (brightness) |slider| made.take(ib.NewObjectTagList(null, cw.WHEEL_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_WHEEL },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
            .{ .tag = gc.GA_Width, .data = 140 },
            .{ .tag = gc.GA_Height, .data = 140 },
            .{ .tag = cw.WHEEL_RGB, .data = @intFromPtr(&rgb) },
            .{ .tag = cw.WHEEL_GradientSlider, .data = @intFromPtr(slider) },
            .{},
        })) else null;
        if (made.failed) {
            made.drop();
            return false;
        }

        // Down the left: the tools, the filling, Undo and Redo two to a
        // row, the two colours and the swap, and the palette under them.
        var grid_tags: [3 + tools.len + column_buttons + 1]TagItem = undefined;
        grid_tags[0] = .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_GRID };
        grid_tags[1] = .{ .tag = lg.LAYOUTA_Columns, .data = 2 };
        grid_tags[2] = .{ .tag = lg.LAYOUTA_Spacing, .data = 2 };
        for (tool_gadgets, 3..) |gadget, place| grid_tags[place] = .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(gadget) };
        for (button_gadgets[0..column_buttons], 3 + tools.len..) |gadget, place| grid_tags[place] = .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(gadget) };
        grid_tags[grid_tags.len - 1] = .{};
        const tool_grid = made.layout(&grid_tags);
        const colour_row = made.layout(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 4 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(colours_box) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(button_gadgets[swap_button]) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{},
        });
        const column = made.layout(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(tool_grid) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(colour_row) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(palette) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddSpace, .data = 0 },
            .{},
        });

        // Beside them the side panel: each section's button over what it
        // folds away, the sections at the top.
        var brush_tags: [8 + 2 * setting_entries.len + 3]TagItem = undefined;
        var tag_count: usize = 0;
        for ([_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 4 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(shape) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(size) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(.MSG_SIZE)) },
        }) |tag| {
            brush_tags[tag_count] = tag;
            tag_count += 1;
        }
        for (setting_gadgets, setting_entries) |gadget, entry| {
            brush_tags[tag_count] = .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(gadget) };
            brush_tags[tag_count + 1] = .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(entry.label)) };
            tag_count += 2;
        }
        brush_tags[tag_count] = .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(dither) };
        brush_tags[tag_count + 1] = .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(.MSG_DITHER)) };
        brush_tags[tag_count + 2] = .{};
        const brush_body = made.layout(brush_tags[0 .. tag_count + 3]);
        const opacity_row = made.layout(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 2 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(layer_opacity) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(layer_delete) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(layer_add) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{},
        });
        const layers_body = made.layout(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 4 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(opacity_row) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(.MSG_OPACITY)) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(blend) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(.MSG_BLEND)) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(layer_list) },
            .{},
        });
        const colour_body = made.layout(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 4 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(wheel) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(brightness) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{},
        });
        const panel = made.layout(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 4 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(section_gadgets[layers_section]) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(layers_body) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.CHILDA_Hidden, .data = @intFromBool(!app.open_sections[layers_section]) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(section_gadgets[brush_section]) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(brush_body) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.CHILDA_Hidden, .data = @intFromBool(!app.open_sections[brush_section]) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(section_gadgets[colour_section]) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(colour_body) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.CHILDA_Hidden, .data = @intFromBool(!app.open_sections[colour_section]) },
            .{ .tag = lg.LAYOUTA_AddSpace, .data = 0 },
            .{},
        });

        // The picture, under the zoom bar.
        const outline_box = made.take(ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_OUTLINE },
            .{ .tag = gc.GA_Selected, .data = @intFromBool(app.show_outline) },
            .{},
        }));
        const show_mask_box = made.take(ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = ID_SHOW_MASK },
            .{ .tag = gc.GA_Selected, .data = @intFromBool(app.show_mask) },
            .{},
        }));
        const zoom_bar = made.layout(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 4 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(button_gadgets[zoom_out_button]) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(zoom_text) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(button_gadgets[zoom_in_button]) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(button_gadgets[fit_button]) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddSpace, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(show_mask_box) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(.MSG_SHOW_MASK)) },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(outline_box) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(app.text.get(.MSG_OUTLINE)) },
            .{},
        });
        const centre = made.layout(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 2 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(zoom_bar) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(view) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 1 },
            .{},
        });
        const main_row = made.layout(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(column) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(panel) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(centre) },
            .{ .tag = lg.CHILDA_WeightWidth, .data = 1 },
            .{},
        });
        const layout = made.layout(&[_]TagItem{
            .{ .tag = lg.LAYOUTA_Margin, .data = 2 },
            .{ .tag = lg.LAYOUTA_Spacing, .data = 4 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(main_row) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 1 },
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(status) },
            .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
            .{},
        }) orelse {
            made.drop();
            return false;
        };
        for (tool_gadgets, &gui.tool_buttons) |gadget, *slot| slot.* = gadget.?;
        for (button_gadgets, &gui.command_buttons) |gadget, *slot| slot.* = gadget.?;
        for (section_gadgets, &gui.section_buttons) |gadget, *slot| slot.* = gadget.?;
        gui.section_bodies = .{ layers_body.?, brush_body.?, colour_body.? };
        gui.layer_list = layer_list.?;
        gui.outline_box = outline_box.?;
        gui.show_mask_box = show_mask_box.?;
        gui.layer_opacity = layer_opacity.?;
        gui.blend = blend.?;
        gui.shown_layer = app.stack.current;
        app.layers_stale = false;
        gui.view = view.?;
        gui.colours = colours_box.?;
        gui.palette = palette.?;
        gui.status = status.?;
        gui.zoom_text = zoom_text.?;
        gui.shape = shape.?;
        gui.size = size.?;
        for (setting_gadgets, &gui.setting_sliders) |gadget, *slot| slot.* = gadget.?;
        gui.dither = dither.?;
        gui.wheel = wheel.?;
        gui.brightness = brightness.?;
        gui.panel = panel.?;

        // On its own screen the window fills it under the bar, without a
        // border; on the desktop's it takes most of the screen.
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
            .{ .tag = wn.WA_Borderless, .data = 1 },
            .{ .tag = sdk.utility.TAG_IGNORE, .data = 0 },
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
            .{ .tag = wn.WA_SizeGadget, .data = 1 },
            // No scroll bars: the sizing gadget in the bottom border, the
            // right one thin.
            .{ .tag = wn.WA_SizeBBottom, .data = 1 },
            .{ .tag = wn.WA_AutoAdjust, .data = 1 },
        };
        const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
            screenTag(gui),
            .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr(SCREEN_TITLE) },
            .{ .tag = wn.WA_Activate, .data = 1 },
            // The pointer's moves: where the brush is shown.
            .{ .tag = wn.WA_ReportMouse, .data = 1 },
            // The menu titles always in the screen's bar, a click opening
            // them: the picture takes the menu button.
            .{ .tag = wn.WA_MenuBar, .data = 1 },
            .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_IDCMPUPDATE | wn.IDCMP_NEWSIZE | wn.IDCMP_RAWKEY | wn.IDCMP_MOUSEWHEEL | wn.IDCMP_INACTIVEWINDOW | wn.IDCMP_MOUSEMOVE },
            .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(layout) },
            .{ .tag = sdk.utility.TAG_MORE, .data = @intFromPtr(&place_tags) },
        }) orelse {
            made.drop();
            return false;
        };
        made.keep(layout);
        gui.object = object;
        var open = wc.WmOpen{};
        if (ib.SendMessage(object, @ptrCast(&open)) == 0) return false;
        gui.window = @ptrFromInt(windowOf(ib, object));
        var value: usize = 0;
        _ = ib.GetAttr(cv.CANVAS_RastPort, gui.colours, &value);
        gui.colours_rp = @ptrFromInt(value);

        // The menus, with the catalog's labels, made from a copy of the
        // table in memory of its own - as large as the menus, it would
        // crowd the stack. Without them Paint still paints.
        const room = app.sys.AllocVec(@sizeOf(@TypeOf(menus[0].menu)) * menus.len, exec.MEMF_ANY) orelse return true;
        defer app.sys.FreeVec(room);
        const table = @as([*]mn.NewMenu, @ptrCast(@alignCast(room)))[0..menus.len];
        for (menus, table) |entry, *one| {
            one.* = entry.menu;
            if (entry.text) |id| one.label = app.text.get(id);
        }
        if (ib.CreateMenusA(table.ptr, null)) |strip| {
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

/// How near to a handle, in view pixels, a press takes it.
const handle_reach = 5;

/// A free transform under way: the pixels lifted from the layer painted,
/// where they were, the shape they have now, and the press that changes
/// it.
const Transforming = struct {
    /// The lifted pixels, `area`'s size, a row after another.
    lifted: [*]Pixel,
    memory: *anyopaque,
    /// Where they were lifted from.
    area: Area,
    shape: transform_zig.Shape,
    /// What the shape covered of the picture, and the area round its
    /// frame, as last shown.
    covered: Area,
    framed: Area,
    /// The press under way: what it took, where it began, and the shape
    /// then.
    grip: transform_zig.Grip = .move,
    from: transform_zig.Spot = .{ 0, 0 },
    before: transform_zig.Shape,
};

/// What a size window asks besides the width and the height.
const SizeQuestion = union(enum) {
    plain,
    /// Where on the canvas the picture goes, 0 to 8 by rows from the top
    /// left.
    place: *u32,
    /// How the picture is scaled.
    scale: *Scaling,
};

/// How Picture Size scales: smoothly or with the nearest pixel, and
/// whether a side left as it was follows the other.
const Scaling = struct { smooth: bool = true, keep: bool = true };

/// A size window's gadgets, and the question they answer.
const SizeWindow = struct { fields: [2]?*Object, choice: ?*Object, keep_box: ?*Object, question: SizeQuestion };

/// The size typed, and the rest of the question's answer written back.
fn answered(ib: *IntuitionBase, asked: *const SizeWindow) [2]u32 {
    var active: usize = 0;
    if (asked.choice) |chooser| _ = ib.GetAttr(ch.CHOOSER_Active, chooser, &active);
    switch (asked.question) {
        .plain => {},
        .place => |where| where.* = @intCast(@min(active, place_texts.len - 1)),
        .scale => |scaling| {
            scaling.smooth = active == 0;
            var checked: usize = 0;
            if (asked.keep_box) |box| _ = ib.GetAttr(cb.CHECKBOX_Checked, box, &checked);
            scaling.keep = checked != 0;
        },
    }
    return sizeOf(ib, asked.fields);
}

/// A view of `area` of `picture`, for paintfx.library.
fn pixelsOf(picture: *const Picture, area: Area) paintfx.Pixels {
    const first = @as(usize, @intCast(area.min_y)) * picture.width + @as(usize, @intCast(area.min_x));
    return .{ .pixels = picture.pixels + first, .width = area.width(), .height = area.height(), .pitch = picture.width };
}

/// The level of `effect` among the Effects window's.
fn levelOf(levels: *const [effect_sliders.len]i32, effect: Effect) i32 {
    return levels[@intFromEnum(effect)];
}

/// Whether two sets of the Effects window's levels are alike.
fn sameLevels(a: *const [effect_sliders.len]i32, b: *const [effect_sliders.len]i32) bool {
    for (a, b) |one, other| if (one != other) return false;
    return true;
}

fn windowOf(ib: *IntuitionBase, object: *Object) usize {
    var window: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, object, &window);
    return window;
}

fn glyph(ib: *IntuitionBase, which: u32) ?*Object {
    return ib.NewObjectTagList(null, command.COMMAND_CLASS, &[_]TagItem{ .{ .tag = command.COMMAND_Glyph, .data = which }, .{} });
}

/// The least area holding every pixel of `picture` that is not wholly
/// see-through; empty when there is none.
fn coveredArea(picture: *const Picture) Area {
    var area = Area.none;
    var y: u32 = 0;
    while (y < picture.height) : (y += 1) {
        const row = picture.row(y);
        var first: ?usize = null;
        var last: usize = 0;
        for (row, 0..) |pixel, x| if (pixel >> 24 != 0) {
            if (first == null) first = x;
            last = x;
        };
        const left = first orelse continue;
        area = area.add(.{ .min_x = @intCast(left), .min_y = @intCast(y), .max_x = @intCast(last + 1), .max_y = @intCast(y + 1) });
    }
    return if (area.isEmpty()) Area{} else area;
}

fn lengthOf(text: [*:0]const u8) usize {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return length;
}

/// Each pixel of `picture` left with as much of its alpha as `mask` lets
/// show.
fn maskInto(picture: *Picture, mask: *const Picture) void {
    const count = @as(usize, picture.width) * picture.height;
    for (picture.pixels[0..count], mask.pixels[0..count]) |*pixel, part| pixel.* = layers_zig.masked(pixel.*, part);
}

/// `picture` flipped across, or upside down.
fn flipPicture(picture: *Picture, across: bool) void {
    if (across) {
        var y: u32 = 0;
        while (y < picture.height) : (y += 1) {
            const row = picture.row(y);
            var left: usize = 0;
            var right: usize = row.len;
            while (left + 1 < right) : (left += 1) {
                right -= 1;
                const held = row[left];
                row[left] = row[right];
                row[right] = held;
            }
        }
    } else {
        var top: u32 = 0;
        var bottom: u32 = picture.height;
        while (top + 1 < bottom) : (top += 1) {
            bottom -= 1;
            for (picture.row(top), picture.row(bottom)) |*upper, *lower| {
                const held = upper.*;
                upper.* = lower.*;
                lower.* = held;
            }
        }
    }
}

/// The bytes of a palette file read: room for 32 colours with a name
/// each, and a heading.
const palette_text_size = 2048;

/// A slider of the palette editor: its label and its largest level.
const EditorSlider = struct { label: Id, most: u32 };
const editor_sliders = [_]EditorSlider{
    .{ .label = .MSG_RED, .most = 255 },
    .{ .label = .MSG_GREEN, .most = 255 },
    .{ .label = .MSG_BLUE, .most = 255 },
    .{ .label = .MSG_HUE, .most = 359 },
    .{ .label = .MSG_SATURATION, .most = 100 },
    .{ .label = .MSG_VALUE, .most = 100 },
};

/// The ranges the palette editor offers, by number.
const range_labels = [palette_zig.max_ranges:null]?[*:0]const u8{ "1", "2", "3", "4" };

/// How often cycling looks whether a range has turned a step.
const beats_per_second = 50;

/// The ranges as a project keeps them.
fn savedRanges(ranges: *const [palette_zig.max_ranges]palette_zig.Range) [paintio.MAX_RANGES]paintio.Range {
    comptime if (paintio.MAX_RANGES != palette_zig.max_ranges) @compileError("a project keeps as many ranges as the palette has");
    var saved: [paintio.MAX_RANGES]paintio.Range = undefined;
    for (&saved, ranges) |*into, range| into.* = .{ .first = range.first, .last = range.last, .speed = range.speed, .flags = if (range.backwards) paintio.RANGEF_BACKWARDS else 0 };
    return saved;
}

/// The ranges a project kept; speeds past the fastest made the fastest.
fn readRanges(saved: *const [paintio.MAX_RANGES]paintio.Range) [palette_zig.max_ranges]palette_zig.Range {
    var ranges: [palette_zig.max_ranges]palette_zig.Range = undefined;
    for (&ranges, saved) |*into, range| into.* = .{ .first = range.first, .last = range.last, .speed = @min(range.speed, palette_zig.max_speed), .backwards = range.flags & paintio.RANGEF_BACKWARDS != 0 };
    return ranges;
}

/// The palette editor's colours, what it is doing, and its gadgets.
const Editor = struct {
    colours: palette_zig.Palette,
    /// The colour the sliders show.
    chosen: u32,
    /// Its ranges, and the one its range gadgets show.
    ranges: [palette_zig.max_ranges]palette_zig.Range,
    range: u32 = 0,
    /// The text under the colours when it tells a range.
    said: [64]u8 = @splat(0),
    /// The colour chosen as hue, saturation and value, kept while those
    /// sliders move so that a grey keeps its hue.
    hsv: palette_zig.Hsv = .{},
    /// What the next colour picked does with the one chosen.
    waiting: Waiting = .none,
    hex: [8]u8 = @splat(0),
    window: *Window = undefined,
    palette: *Object = undefined,
    sliders: [editor_sliders.len]*Object = undefined,
    hex_field: *Object = undefined,
    hint: *Object = undefined,
    speed: *Object = undefined,
    backwards: *Object = undefined,

    const Waiting = enum { none, spread, copy, swap, range };
};

/// The history's way to give back a layer it held: `context` is the App.
fn releaseLayer(context: *anyopaque, memory: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(context));
    app.sys.FreeVec(memory);
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

/// A section of the side panel's button: its name beside the picture of
/// it folded or unfolded, on while the section is unfolded.
fn sectionButton(ib: *IntuitionBase, id: u32, image: ?*Object, label: [*:0]const u8, open: bool) ?*Object {
    return ib.NewObjectTagList(null, tb.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = if (image != null) tb.TOOLBUTTON_Image else sdk.utility.TAG_IGNORE, .data = @intFromPtr(image) },
        .{ .tag = gc.GA_Text, .data = @intFromPtr(label) },
        .{ .tag = tb.TOOLBUTTON_Size, .data = tb.TBSIZE_MEDIUM },
        .{ .tag = tb.TOOLBUTTON_Kind, .data = tb.TBKIND_TOGGLE },
        .{ .tag = tb.TOOLBUTTON_Checked, .data = @intFromBool(open) },
        .{},
    });
}

/// The gadgets of a window being made: each kept loose - the program's
/// to dispose of - until a layout takes it, and the layouts the same
/// until the window takes the outermost. Whatever is loose when making
/// fails is disposed of.
const Builder = struct {
    ib: *IntuitionBase,
    loose: [64]?*Object = @splat(null),
    /// Something could not be made: nothing more is.
    failed: bool = false,

    /// A gadget made, or null when it could not be.
    fn take(builder: *Builder, made: ?*Object) ?*Object {
        const object = made orelse {
            builder.failed = true;
            return null;
        };
        for (&builder.loose) |*slot| {
            if (slot.* == null) {
                slot.* = object;
                return object;
            }
        }
        builder.failed = true;
        builder.ib.DisposeObject(object);
        return null;
    }

    /// A layout made of `tags`, which takes the children they add.
    fn layout(builder: *Builder, tags: []const TagItem) ?*Object {
        if (builder.failed) return null;
        const made = builder.ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, tags.ptr) orelse {
            builder.failed = true;
            return null;
        };
        for (tags) |tag| {
            if (tag.tag != lg.LAYOUTA_AddChild) continue;
            for (&builder.loose) |*slot| {
                if (slot.* != null and @intFromPtr(slot.*.?) == tag.data) slot.* = null;
            }
        }
        return builder.take(made);
    }

    /// Something taken by what is not a layout: no longer loose.
    fn keep(builder: *Builder, object: *Object) void {
        for (&builder.loose) |*slot| {
            if (slot.* == object) slot.* = null;
        }
    }

    /// Whatever is loose disposed of.
    fn drop(builder: *Builder) void {
        for (&builder.loose) |*slot| {
            builder.ib.DisposeObject(slot.*);
            slot.* = null;
        }
    }
};

/// A colour as the colour wheel takes it.
fn wheelRGB(colour: Pixel) cw.ColorWheelRGB {
    return .{
        .red = (colour >> 16 & 0xFF) * 0x0101_0101,
        .green = (colour >> 8 & 0xFF) * 0x0101_0101,
        .blue = (colour & 0xFF) * 0x0101_0101,
    };
}

/// The colour at its brightest, its hue and saturation kept: white for
/// black, which has neither.
fn brightestOf(colour: Pixel) Pixel {
    const red = colour >> 16 & 0xFF;
    const green = colour >> 8 & 0xFF;
    const blue = colour & 0xFF;
    const most = @max(red, @max(green, blue));
    if (most == 0) return 0xFFFF_FFFF;
    return 0xFF00_0000 | (red * 255 / most) << 16 | (green * 255 / most) << 8 | blue * 255 / most;
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
    const on: ?bool = blk: {
        break :blk if (Tool.of(value)) |tool|
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
            .cycle => state.cycling,
            .round_gradient => state.round_gradient,
            .paint_mask => {
                if (state.has_mask) menu_item.flags |= mn.ITEMENABLED else menu_item.flags &= ~mn.ITEMENABLED;
                break :blk state.painting_mask;
            },
            .undo, .redo, .new_layer, .duplicate_layer, .delete_layer, .layer_up, .layer_down, .merge_down, .deselect, .copy_to_layer, .cut_to_layer, .copy_to_brush, .mask_show_all, .mask_hide_all, .mask_selection, .apply_mask, .delete_mask, .crop, .flatten => {
                const can = switch (which) {
                    .mask_show_all, .mask_hide_all => !state.has_mask,
                    .mask_selection => !state.has_mask and state.selected,
                    .apply_mask, .delete_mask => state.has_mask,
                    .undo => state.can_undo,
                    .redo => state.can_redo,
                    .new_layer, .duplicate_layer => state.layers < layers_zig.max_layers,
                    .deselect, .copy_to_brush, .crop => state.selected,
                    .flatten => state.layers > 1,
                    .copy_to_layer, .cut_to_layer => state.selected and state.layers < layers_zig.max_layers,
                    .delete_layer => state.layers > 1,
                    .layer_up => state.current + 1 < state.layers,
                    else => state.current > 0,
                };
                if (can) menu_item.flags |= mn.ITEMENABLED else menu_item.flags &= ~mn.ITEMENABLED;
                return;
            },
            else => null,
        } else null;
    };
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
        a.grid == b.grid and a.own == b.own and a.can_undo == b.can_undo and a.can_redo == b.can_redo and
        a.layers == b.layers and a.current == b.current and a.selected == b.selected and
        a.has_mask == b.has_mask and a.painting_mask == b.painting_mask and a.cycling == b.cycling and
        a.round_gradient == b.round_gradient;
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
    const names = [_][*:0]const u8{ intuition.INTUITIONNAME, graphics.GRAPHICSNAME, cv.CANVAS_LIBRARY, pa.PALETTE_LIBRARY, tb.TOOLBUTTON_LIBRARY, tx.TEXT_LIBRARY, command.COMMAND_LIBRARY, ch.CHOOSER_LIBRARY, sl.SLIDER_LIBRARY, cw.WHEEL_LIBRARY, gs.GRAD_LIBRARY, cb.CHECKBOX_LIBRARY, lb.LISTBROWSER_LIBRARY };
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

    // Room for every layer there can be.
    const slots = sys.AllocVec(@sizeOf([layers_zig.max_layers]Layer), exec.MEMF_ANY) orelse {
        _ = text.printf(dl, .MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(slots);
    var app = App{
        .sys = sys,
        .dl = dl,
        .ib = @ptrCast(libs[0]),
        .gb = @ptrCast(libs[1]),
        .ub = ub,
        .text = &text,
        .stack = .{ .layers = @ptrCast(@alignCast(slots)) },
    };
    app.layer_rows.init(.unknown);
    defer {
        app.closeClock();
        if (app.gui) |*gui| gui.close(app.ib);
        lb.freeRows(sys, &app.layer_rows);
        if (app.lasso.len != 0) sys.FreeVec(@ptrCast(app.lasso.ptr));
        if (app.band) |band| sys.FreeVec(band);
        if (app.own_memory) |memory| sys.FreeVec(memory);
        app.freePicture();
        if (app.pio_lib) |lib| sys.CloseLibrary(lib);
        if (app.asl_lib) |lib| sys.CloseLibrary(lib);
        if (app.transforming) |moving| sys.FreeVec(moving.memory);
        if (app.fx_lib) |lib| sys.CloseLibrary(lib);
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
