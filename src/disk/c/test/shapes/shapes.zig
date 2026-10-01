// SPDX-License-Identifier: MIT
//! Shapes: what graphics.library's rounded rectangles, arcs, coverage
//! blits and fitted text look like. Built against the SDK only.
//!
//!   Shapes NOWINDOW/S,SMOOTH/S
//!
//! It opens a window on the default public screen and draws one panel for
//! each call, with a heading over it:
//!
//! - `FillRoundRect` and `DrawRoundRect`: boxes of rising radius, the last
//!   rounded past half its shorter side so it comes out a stadium, and one
//!   outline drawn round a fill of the same shape to show they meet.
//! - `FillArc`: a disc, a quarter, a ring, and a gauge part of the way
//!   round.
//! - `RPTAG_FillStyle`: the same fills taking a gradient - down, across,
//!   from a centre - and a tile instead of the pen.
//! - `BltCoverBitMapRastPort`: a picture laid down at four coverages, and
//!   once through a plane so its edges are soft.
//! - `BlurCoverage`: a shape drawn into a coverage surface, softened, and
//!   laid down as a shadow under the shape itself.
//! - `TextFitted`: one long name drawn in boxes too narrow for it.
//!
//! SMOOTH draws all of it with `RPTAG_Smooth`: curves, rings, wedges,
//! round corners and slanted lines with smooth edges, and the pictures
//! scaled by sampling between their pixels. Run it with and without to
//! compare.
//!
//! The window stays until the close gadget or Ctrl-C. NOWINDOW draws
//! nothing and only says what it would have drawn.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const rtg = sdk.rtg;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const wn = intuition.windows;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;
const RastPort = graphics.RastPort;
const Rect = graphics.Rect;
const Pen = graphics.Pen;

pub const COMMAND_NAME = "Shapes";
const VERSION_STRING = "\x00$VER: Shapes 1.2 (1.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "NOWINDOW/S,SMOOTH/S";
const arg_nowindow = 0;
const arg_smooth = 1;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display, or it shows another screen\n";
const MSG_NOWINDOW = "No window - the screen would not open one that size\n";
const MSG_NOSURFACE = "No memory for the %s surface\n";
const MSG_WAITING = "The close gadget or Ctrl-C closes the window\n";
const MSG_PANELS = "%d panels: round rectangles, arcs, fill styles, coverage blits, a blurred shadow, fitted text\n";

/// How large the window wants to be inside, and the room round things.
const inner_w: i32 = 620;
const inner_h: i32 = 540;
const margin: i32 = 14;

/// The picture the coverage blits lay down, and the coverage plane that
/// softens it.
const picture_w: u32 = 72;
const picture_h: u32 = 56;

/// A panel: a heading, and the room under it the drawing goes in.
const Panel = struct {
    rp: *RastPort,
    gb: *GraphicsBase,
    /// The left edge everything is measured from: a window's RastPort
    /// starts at the window's own corner, border and all, so this is the
    /// border's width and the room inside it.
    x0: i32,
    /// Where the next panel starts.
    y: i32,

    fn heading(p: *Panel, ink: Pen, text: [*]const u8, count: u32) void {
        pen(p.gb, p.rp, ink);
        p.gb.Move(p.rp, p.x0, p.y + 10);
        p.gb.Text(p.rp, text, count);
        p.y += 18;
    }

    fn done(p: *Panel, height: i32) void {
        p.y += height + 12;
    }
};

/// The RastPort's pen, set in one line rather than four.
fn pen(gb: *GraphicsBase, rp: *RastPort, ink: Pen) void {
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = ink }, .{} });
}

/// One of the window's numbers.
fn wattr(ib: *IntuitionBase, window: *intuition.Window, tag: sdk.utility.Tag) usize {
    var storage: usize = 0;
    ib.GetWindowAttrs(window, &[_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&storage) }, .{} });
    return storage;
}

// --- the panels -------------------------------------------------------------

/// Boxes of rising radius, and an outline drawn round a fill.
fn roundRectangles(p: *Panel) void {
    const gb = p.gb;
    const rp = p.rp;
    const height: i32 = 44;
    const width: i32 = 84;
    const radii = [_]u32{ 0, 4, 10, 22, 99 };
    // Each outline wider than the last: it grows inward, so every box
    // keeps its size.
    const outline_widths = [_]usize{ 1, 1, 2, 3, 4 };

    var x: i32 = p.x0;
    for (radii, outline_widths) |radius, outline| {
        const box = Rect{ .min_x = x, .min_y = p.y, .max_x = x + width, .max_y = p.y + height };
        pen(gb, rp, graphics.penRGB(0x36, 0x6C, 0xA8));
        gb.FillRoundRect(rp, &box, radius);
        // The outline of the same shape, in a darker ink: where the two
        // disagree by a pixel it shows at once, so this is the check as
        // well as the picture.
        pen(gb, rp, graphics.penRGB(0x10, 0x28, 0x40));
        gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_LineWidth, .data = outline }, .{} });
        gb.DrawRoundRect(rp, &box, radius);
        gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_LineWidth, .data = 1 }, .{} });
        x += width + 12;
    }
    p.done(height);
}

/// A disc, a quarter, a ring, and a gauge.
fn arcs(p: *Panel) void {
    const gb = p.gb;
    const rp = p.rp;
    const height: i32 = 96;
    const r: i32 = 44;
    const cy = p.y + height / 2;
    var cx: i32 = p.x0 + r;

    pen(gb, rp, graphics.penRGB(0xC8, 0x50, 0x30));
    gb.FillArc(rp, &.{ .cx = cx, .cy = cy, .radius = r });
    cx += 2 * r + 20;

    // A quarter: 0 degrees is to the right and the numbers go up the
    // screen, so 0 to 90 is the top right.
    pen(gb, rp, graphics.penRGB(0xE0, 0x9C, 0x20));
    gb.FillArc(rp, &.{ .cx = cx, .cy = cy, .radius = r, .from = 0, .to = 90 });
    pen(gb, rp, graphics.penRGB(0x60, 0x60, 0x60));
    gb.DrawCircle(rp, cx, cy, r);
    cx += 2 * r + 20;

    pen(gb, rp, graphics.penRGB(0x38, 0x90, 0x58));
    gb.FillArc(rp, &.{ .cx = cx, .cy = cy, .radius = r, .inner = r - 12 });
    cx += 2 * r + 20;

    // A gauge: the track all the way round, and the part of it filled
    // from the top clockwise, which is the way the degrees count down.
    pen(gb, rp, graphics.penRGB(0xD0, 0xD0, 0xD0));
    gb.FillArc(rp, &.{ .cx = cx, .cy = cy, .radius = r, .inner = r - 14 });
    pen(gb, rp, graphics.penRGB(0x80, 0x30, 0xA0));
    gb.FillArc(rp, &.{ .cx = cx, .cy = cy, .radius = r, .inner = r - 14, .from = 250, .to = 90 });

    p.done(height);
}

/// Shapes filled from a fill style instead of the pen.
fn fills(p: *Panel) void {
    const gb = p.gb;
    const rp = p.rp;
    const height: i32 = 50;
    const width: i32 = 96;
    const blue_to_white = [4]graphics.GradientStop{
        .{ .at = 0, .pen = graphics.penRGB(0x1C, 0x3F, 0x8A) },
        .{ .at = graphics.FILL_ONE, .pen = graphics.penRGB(0xE8, 0xF0, 0xFF) },
        .{},
        .{},
    };
    var tile_pixels = [16]u16{
        0xFFE0, 0xFFE0, 0x0000, 0x0000,
        0xFFE0, 0xFFE0, 0x0000, 0x0000,
        0x0000, 0x0000, 0xFFE0, 0xFFE0,
        0x0000, 0x0000, 0xFFE0, 0xFFE0,
    };
    const tile = rtg.Surface{ .pixels = @ptrCast(&tile_pixels), .width = 4, .height = 4, .pitch = 8, .size_bytes = 32, .format = .rgb565 };
    const styles = [_]graphics.FillStyle{
        // Down the box.
        .{ .stops = blue_to_white },
        // Across it.
        .{ .to_x = graphics.FILL_ONE, .to_y = 0, .stops = blue_to_white },
        // From the middle out to a corner.
        .{ .kind = graphics.FILL_RADIAL, .from_x = graphics.FILL_ONE / 2, .from_y = graphics.FILL_ONE / 2, .to_x = graphics.FILL_ONE, .to_y = graphics.FILL_ONE, .stops = .{
            .{ .at = 0, .pen = graphics.penRGB(0xFF, 0xE0, 0x60) },
            .{ .at = graphics.FILL_ONE, .pen = graphics.penRGB(0xC0, 0x30, 0x20) },
            .{},
            .{},
        } },
        // A picture repeated.
        .{ .kind = graphics.FILL_TILE, .tile = &tile },
    };
    var x: i32 = p.x0;
    for (&styles) |*style| {
        gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FillStyle, .data = @intFromPtr(style) }, .{} });
        gb.RectFill(rp, &.{ .min_x = x, .min_y = p.y, .max_x = x + width, .max_y = p.y + height });
        x += width + 12;
    }
    // The same gradient in a round shape: the fill style is laid across
    // the shape's own box, whatever the shape.
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FillStyle, .data = @intFromPtr(&styles[0]) }, .{} });
    gb.FillRoundRect(rp, &.{ .min_x = x, .min_y = p.y, .max_x = x + width, .max_y = p.y + height }, 14);
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FillStyle, .data = 0 }, .{} });
    p.done(height);
}

/// A picture at four coverages, and once with soft edges.
fn coverBlits(p: *Panel, picture: *rtg.Surface, soft: *rtg.Surface) void {
    const gb = p.gb;
    const rp = p.rp;
    const height: i32 = @intCast(picture_h);
    const whole = Rect{ .max_x = @intCast(picture_w), .max_y = @intCast(picture_h) };
    const amounts = [_]u8{ 255, 176, 96, 40 };

    var x: i32 = p.x0;
    for (amounts) |alpha| {
        gb.BltCoverBitMapRastPort(picture, &whole, rp, x, p.y, &.{ .alpha = alpha });
        x += @as(i32, @intCast(picture_w)) + 10;
    }
    // The same picture through a coverage plane: the edges fall away
    // instead of stopping.
    gb.BltCoverBitMapRastPort(picture, &whole, rp, x, p.y, &.{
        .bits = soft.pixels.?,
        .pitch = soft.pitch,
    });
    p.done(height);
}

/// A shape's own coverage, blurred, laid down as a shadow under it.
fn shadow(p: *Panel, cover: *rtg.Surface, ink: *rtg.Surface) void {
    const gb = p.gb;
    const rp = p.rp;
    const height: i32 = @intCast(cover.height);
    const whole = Rect{ .max_x = @intCast(cover.width), .max_y = @intCast(cover.height) };

    // The shadow first, offset down and right of where the shape goes,
    // then the shape over it.
    gb.BltCoverBitMapRastPort(ink, &whole, rp, p.x0 + 6, p.y + 6, &.{
        .bits = cover.pixels.?,
        .pitch = cover.pitch,
        .alpha = 150,
    });
    const box = Rect{
        .min_x = p.x0 + 12,
        .min_y = p.y + 2,
        .max_x = p.x0 + 12 + 150,
        .max_y = p.y + 2 + 52,
    };
    pen(gb, rp, graphics.penRGB(0xF4, 0xF2, 0xEC));
    gb.FillRoundRect(rp, &box, 12);
    pen(gb, rp, graphics.penRGB(0x70, 0x70, 0x70));
    gb.DrawRoundRect(rp, &box, 12);

    pen(gb, rp, graphics.penRGB(0x20, 0x20, 0x20));
    gb.Move(rp, box.min_x + 16, box.min_y + 32);
    gb.Text(rp, "blurred", 7);

    p.done(height);
}

/// One long name in boxes too narrow for it.
fn fittedText(p: *Panel) void {
    const gb = p.gb;
    const rp = p.rp;
    const name = "Mandelbrot-in-a-very-long-drawer-name.png";
    const widths = [_]i32{ 260, 150, 88, 40, 16 };
    const height: i32 = 22;

    var x: i32 = p.x0;
    for (widths) |width| {
        const box = Rect{ .min_x = x, .min_y = p.y, .max_x = x + width, .max_y = p.y + height };
        pen(gb, rp, graphics.penRGB(0xFF, 0xFF, 0xFF));
        gb.RectFill(rp, &box);
        pen(gb, rp, graphics.penRGB(0xA0, 0xA0, 0xA0));
        gb.DrawRect(rp, &box);
        pen(gb, rp, graphics.penRGB(0x10, 0x10, 0x10));
        gb.Move(rp, box.min_x + 3, box.min_y + 15);
        _ = gb.TextFitted(rp, name, name.len, width - 6);
        x += width + 10;
    }
    p.done(height);
}

// --- what the panels need drawn for them ------------------------------------

/// A surface of the display's format with a ramp of colour on it, for the
/// coverage blits to lay down.
fn makePicture(gb: *GraphicsBase, friend: *RastPort) ?*rtg.Surface {
    const tags = [_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = picture_w },
        .{ .tag = graphics.BMTAG_Height, .data = picture_h },
        .{ .tag = graphics.BMTAG_Friend, .data = @intFromPtr(friend) },
        .{},
    };
    const surface = gb.AllocBitMapTagList(&tags) orelse return null;
    const on = [_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(surface) }, .{} };
    const rp = gb.CreateRastPortTagList(&on) orelse {
        gb.FreeBitMap(surface);
        return null;
    };
    defer gb.FreeRastPort(rp);

    var y: i32 = 0;
    while (y < picture_h) : (y += 1) {
        const up: u32 = @intCast(@divTrunc(y * 255, @as(i32, @intCast(picture_h))));
        pen(gb, rp, graphics.penRGB(@truncate(255 - up), @truncate(64 + up / 2), @truncate(up)));
        gb.DrawHLine(rp, 0, y, @intCast(picture_w));
    }
    return surface;
}

/// A coverage surface the size of `width` by `height`, with `shape` drawn
/// into it at full coverage and then blurred.
///
/// A coverage is a `gray8` surface: a pen's brightness is how much of
/// something lands, so white is all of it and the surface starts at none
/// of it. That is what makes every drawing call a way to build one.
fn makeCoverage(gb: *GraphicsBase, width: u32, height: u32, shape: *const Rect, radius: u32, blur: u32) ?*rtg.Surface {
    const tags = [_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = width },
        .{ .tag = graphics.BMTAG_Height, .data = height },
        .{ .tag = graphics.BMTAG_Format, .data = @intFromEnum(rtg.PixelFormat.gray8) },
        .{},
    };
    const surface = gb.AllocBitMapTagList(&tags) orelse return null;
    const on = [_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(surface) }, .{} };
    const rp = gb.CreateRastPortTagList(&on) orelse {
        gb.FreeBitMap(surface);
        return null;
    };
    defer gb.FreeRastPort(rp);

    pen(gb, rp, graphics.penRGB(0, 0, 0));
    gb.RectFill(rp, &.{ .max_x = @intCast(width), .max_y = @intCast(height) });
    pen(gb, rp, graphics.penRGB(255, 255, 255));
    gb.FillRoundRect(rp, shape, radius);
    if (blur != 0) gb.BlurCoverage(surface, &.{ .max_x = @intCast(width), .max_y = @intCast(height) }, blur);
    return surface;
}

/// A surface of one colour, which a coverage lays down as a shadow.
fn makeInk(gb: *GraphicsBase, friend: *RastPort, width: u32, height: u32, ink: Pen) ?*rtg.Surface {
    const tags = [_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = width },
        .{ .tag = graphics.BMTAG_Height, .data = height },
        .{ .tag = graphics.BMTAG_Friend, .data = @intFromPtr(friend) },
        .{},
    };
    const surface = gb.AllocBitMapTagList(&tags) orelse return null;
    const on = [_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(surface) }, .{} };
    const rp = gb.CreateRastPortTagList(&on) orelse {
        gb.FreeBitMap(surface);
        return null;
    };
    defer gb.FreeRastPort(rp);
    pen(gb, rp, ink);
    gb.RectFill(rp, &.{ .max_x = @intCast(width), .max_y = @intCast(height) });
    return surface;
}

// --- the program ------------------------------------------------------------

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    if (argv[arg_nowindow] != 0) {
        _ = Printf(dl, MSG_PANELS, .{@as(u32, 6)});
        return dos.RETURN_OK;
    }

    const gfx_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{graphics.GRAPHICSNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(gfx_lib);
    const gb: *GraphicsBase = @ptrCast(gfx_lib);

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);

    const window_tags = [_]TagItem{
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_Left, .data = 20 },
        .{ .tag = wn.WA_Top, .data = 18 },
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(inner_w) },
        .{ .tag = wn.WA_InnerHeight, .data = @intCast(inner_h) },
        .{ .tag = wn.WA_AutoAdjust, .data = 1 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Shapes") },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_SmartRefresh, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW },
        .{},
    };
    const w = ib.OpenWindowTagList(&window_tags) orelse {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.CloseWindow(w);

    const rp: *RastPort = @ptrFromInt(wattr(ib, w, wn.WA_RastPort));
    if (argv[arg_smooth] != 0) gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 1 }, .{} });
    const left: i32 = @intCast(wattr(ib, w, wn.WA_BorderLeft));
    const top: i32 = @intCast(wattr(ib, w, wn.WA_BorderTop));

    // Everything the panels lay down, made once.
    const picture = makePicture(gb, rp) orelse {
        _ = Printf(dl, MSG_NOSURFACE, .{"picture"});
        return dos.RETURN_FAIL;
    };
    defer gb.FreeBitMap(picture);

    // The picture's soft edges: a rounded shape blurred a little, the
    // picture's own size.
    const soft = makeCoverage(gb, picture_w, picture_h, &.{
        .min_x = 6,
        .min_y = 6,
        .max_x = @intCast(picture_w - 6),
        .max_y = @intCast(picture_h - 6),
    }, 14, 5) orelse {
        _ = Printf(dl, MSG_NOSURFACE, .{"soft"});
        return dos.RETURN_FAIL;
    };
    defer gb.FreeBitMap(soft);

    // The shadow: the shape's coverage, blurred wider.
    const shadow_w: u32 = 186;
    const shadow_h: u32 = 76;
    const cover = makeCoverage(gb, shadow_w, shadow_h, &.{
        .min_x = 12,
        .min_y = 8,
        .max_x = 162,
        .max_y = 60,
    }, 12, 6) orelse {
        _ = Printf(dl, MSG_NOSURFACE, .{"shadow"});
        return dos.RETURN_FAIL;
    };
    defer gb.FreeBitMap(cover);

    const ink = makeInk(gb, rp, shadow_w, shadow_h, graphics.penRGB(0x18, 0x1C, 0x24)) orelse {
        _ = Printf(dl, MSG_NOSURFACE, .{"ink"});
        return dos.RETURN_FAIL;
    };
    defer gb.FreeBitMap(ink);

    // The window's inside, cleared, and then a panel at a time down it.
    // Everything is drawn relative to the border, so the panels sit
    // inside whatever borders this screen gives a window.
    var panel = Panel{ .rp = rp, .gb = gb, .x0 = left + margin, .y = top + 4 };
    const heading_ink = graphics.penRGB(0x18, 0x18, 0x18);

    panel.heading(heading_ink, "FillRoundRect, DrawRoundRect, RPTAG_LineWidth 1 to 4", 52);
    roundRectangles(&panel);
    panel.heading(heading_ink, "FillArc: disc, quarter, ring, gauge", 35);
    arcs(&panel);
    panel.heading(heading_ink, "RPTAG_FillStyle: down, across, radial, tile, round", 50);
    fills(&panel);
    panel.heading(heading_ink, "BltCoverBitMapRastPort: 255, 176, 96, 40, and a plane", 53);
    coverBlits(&panel, picture, soft);
    panel.heading(heading_ink, "BlurCoverage: a shape's own coverage, softened", 46);
    shadow(&panel, cover, ink);
    panel.heading(heading_ink, "TextFitted: one name, five widths", 33);
    fittedText(&panel);

    _ = Printf(dl, MSG_WAITING, .{});

    var open = true;
    while (open) {
        const got = ib.WaitIMsg(w, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) break;
        while (ib.GetIMsg(w)) |im| {
            const class = im.class;
            ib.ReplyIMsg(im);
            if (class == wn.IDCMP_CLOSEWINDOW) open = false;
        }
    }
    return dos.RETURN_OK;
}
