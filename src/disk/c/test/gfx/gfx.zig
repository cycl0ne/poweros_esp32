// SPDX-License-Identifier: MIT
//! Gfx: what graphics.library can do on this machine, and whether it can
//! do it here. Built against the SDK only.
//!
//!   Gfx DISPLAY/S,MEMORY/S,FORMATS/S,FILL/S,BLIT/S,LINES/S,REGION/S,DRAW/S,
//!       GURU/S,LAYERS/S,ALL/S
//!
//! With nothing asked for it prints a line each: the library's release,
//! whether a RastPort can be had on the display, whether one can be had on
//! plain memory, and how many pixel formats it will take. A switch prints
//! that one section alone, which is what a script wants.
//!
//! It asks graphics.library only, and never rtg.library - which is the
//! point. A program that wants to draw on the display opens one library
//! and asks for a RastPort; the display, the board and the buffer are
//! graphics.library's to find. `Rtg` is the command that reports the
//! boards themselves.
//!
//! FORMATS is a probe rather than a table: it offers the library a small
//! surface in each pixel format and prints what came back. So it tells the
//! truth about the ROM it is running on, not about the one it was built
//! against - which matters, because a pen has to be packed into the
//! surface's format and three formats have no packing decided yet.
//!
//! FILL is the drawing test: it puts a pattern on the display that cannot
//! be misread - colour bars with a half-covering white across them, so
//! that a composed pixel sits next to the flat colour it was composed
//! with. In the emulator, `zig build qemu-display` shows it.
//!
//! BLIT is the off-screen test, and it is the shape SMART_REFRESH has:
//! part of the screen is kept in a bitmap that is not the screen, and put
//! back somewhere from there. It draws the FILL pattern, keeps a strip of
//! it, and stamps that strip down the screen.
//!
//! DRAW is the picture: one drawing that uses every primitive there is,
//! rather than a switch for each. A switch per call would be a list of
//! things that work on their own; a single picture is the only way to see
//! that they agree with one another - the same pens, the same clip, the
//! same pattern running through all of them. See docs/graphics.md.
//!
//! LAYERS is three windows sharing the display, from layers.library. Each
//! fills all of itself in its own coordinates and what is in front of it
//! simply does not receive the pixels. **Each window's caption says where
//! it is in the order**, because a picture of overlapping rectangles does
//! not: which one is on top is exactly what the reader cannot work out
//! for themselves. Then the back one is raised over the others and put
//! away again - covering a window is not damage, but uncovering one is,
//! unless the layer kept what was there. The front window is smart and
//! the other two are simple, so both modes are in the one picture: the
//! smart one's pixels come back on their own, and the two simple ones
//! repaint the whole of themselves inside BeginUpdate. Only the
//! damage lands, so what shows is exactly where the raised window had
//! been. **Both** uncovered windows redraw, and their damage abuts
//! exactly - together they are the footprint of the raised window - so
//! each paints its own in a lighter shade of its own colour. That says
//! which window is coming back without having to be read, where one
//! colour for both would be a single block with two labels on it.
//!
//! GURU draws the alert the machine puts up when it has stopped, with the
//! words on it - the band, the border, and two lines of text centred in
//! it. The kernel draws the same band and leaves it empty, because there
//! is no font in the kernel; there is one out here. It stays a
//! demonstration: a library that draws the alert is a library that has to
//! be working for the alert to appear, and what is being reported may be
//! the reason it is not.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const layers = sdk.layers;
const LayersBase = sdk.interface.layers.LayersBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Gfx";
const VERSION_STRING = "\x00$VER: Gfx 1.0 (17.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DISPLAY/S,MEMORY/S,FORMATS/S,FILL/S,BLIT/S,LINES/S,REGION/S,DRAW/S,GURU/S,LAYERS/S,ALL/S";
const arg_display = 0;
const arg_memory = 1;
const arg_formats = 2;
const arg_fill = 3;
const arg_blit = 4;
const arg_lines = 5;
const arg_region = 6;
const arg_draw = 7;
const arg_guru = 8;
const arg_layers = 9;
const arg_all = 10;

const MSG_NOLIBRARY = "No %s - this machine has no drawing layer\n";
const MSG_RELEASE = "%s %d.%d\n";
const MSG_DISPLAY_YES = "Display    %dx%d %s\n";
const MSG_DISPLAY_NO = "Display    none - %s\n";
const MSG_MEMORY_YES = "Memory     a RastPort on a %s surface of its own\n";
const MSG_MEMORY_NO = "Memory     refused a %s surface\n";
const MSG_FORMATS = "Formats    %d of %d taken\n";
const MSG_FILLED = "Filled     %dx%d: bars, then a half-covering white over them\n";
const MSG_NOFILL = "Filled     nothing - there is no display to fill\n";
const MSG_BLITTED = "Blitted    a %dx%d strip kept off-screen, stamped back %d times\n";
const MSG_NOBLIT = "Blitted    nothing - %s\n";
const MSG_LINES = "Lines      %d from the middle, most of them running off the edges\n";
const MSG_NOLINES = "Lines      nothing - there is no display to draw on\n";
const MSG_REGION = "Region     %d squares less a hole; a full-screen fill and %d lines cut to it\n";
const MSG_NOREGION = "Region     nothing - no display, or no memory for a region\n";
const MSG_DRAWN = "Drawn      %dx%d: every primitive the library has\n";
const MSG_NODRAWN = "Drawn      nothing - there is no display to draw on\n";
const MSG_GURU = "Guru       the alert box the kernel draws, with the words on it\n";
const MSG_LAYERS = "Layers     %d windows sharing the display, the back one then raised\n";
const MSG_NOLAYERS = "Layers     no layers.library, or no display to put windows on\n";
const MSG_NOGURU = "Guru       nothing - no display, or no font\n";
const MSG_FORMAT_ROW = "  %-10s %s\n";
const MSG_TAKEN: [*:0]const u8 = "taken";
const MSG_REFUSED: [*:0]const u8 = "refused - no packing for a pen in this format";

/// The formats a surface can be in, and what to call each. The library is
/// asked about every one of them rather than told.
const Format = struct { name: [*:0]const u8, format: rtg.bitmaps.PixelFormat };
const formats = [_]Format{
    .{ .name = "rgba32", .format = .rgba32 },
    .{ .name = "bgra32", .format = .bgra32 },
    .{ .name = "rgb24", .format = .rgb24 },
    .{ .name = "bgr24", .format = .bgr24 },
    .{ .name = "rgb565", .format = .rgb565 },
    .{ .name = "argb1555", .format = .argb1555 },
    .{ .name = "indexed8", .format = .indexed8 },
    .{ .name = "gray8", .format = .gray8 },
    .{ .name = "mono1", .format = .mono1 },
};

/// Wide enough that a row is a row in every format, small enough to cost
/// nothing: the probe never draws into it.
const probe_width = 8;
const probe_height = 4;

/// Whether the library will make a RastPort on a surface of this format.
///
/// It allocates the pixels, offers them, and gives everything back, so it
/// can be asked about every format in turn without leaving anything
/// behind. False also when the memory could not be had, which is not worth
/// telling apart here: a machine that cannot spare 32 bytes has a larger
/// problem than this command.
fn takesFormat(sys: *ExecBase, gb: *GraphicsBase, format: rtg.bitmaps.PixelFormat) bool {
    const bytes_per_pixel = @max(rtg.bitmaps.formatBits(format) / 8, 1);
    const pitch = probe_width * bytes_per_pixel;
    const size = pitch * probe_height;

    const pixels = sys.AllocVec(size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return false;
    defer sys.FreeVec(pixels);

    var surface = rtg.Surface{
        .pixels = @ptrCast(pixels),
        .width = probe_width,
        .height = probe_height,
        .pitch = pitch,
        .size_bytes = size,
        .format = format,
    };
    const tag_list = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{},
    };

    const rp = gb.CreateRastPortTagList(&tag_list) orelse return false;
    gb.FreeRastPort(rp);
    return true;
}

/// What the display turned out to be: its size, and the format its pixels
/// are in. Null when there is no display to ask.
///
/// Nothing but the library is asked. A RastPort on the display knows how
/// big its surface is and what shape its pixels are, and GetRPAttrs is how
/// that is got out - there is no other way to find out, and a program that
/// wants to cover a screen needs it.
fn displayShape(gb: *GraphicsBase, why: *i32) ?struct { graphics.Rect, u32 } {
    const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_ErrorPtr, .data = @intFromPtr(why) }, .{} };
    const rp = gb.CreateRastPortTagList(&tags) orelse return null;
    defer gb.FreeRastPort(rp);

    var bounds: graphics.Rect = .{};
    var format: u32 = 0;
    const ask = [_]TagItem{
        .{ .tag = graphics.RPTAG_Bounds, .data = @intFromPtr(&bounds) },
        .{ .tag = graphics.RPTAG_Format, .data = @intFromPtr(&format) },
        .{},
    };
    gb.GetRPAttrs(rp, &ask);
    return .{ bounds, format };
}

/// What to call a format, for a person reading a line of output.
fn formatName(format: u32) [*:0]const u8 {
    for (formats) |entry| {
        if (@intFromEnum(entry.format) == format) return entry.name;
    }
    return "unknown";
}

/// Something on the display that cannot be misread: a black ground, four
/// colour bars, and a half-covering white laid over their middle so that
/// composing is visible beside the flat colour it composed with.
///
/// It asks the display how big it is and fits the pattern to that, so it
/// says something true on a screen that is not this machine's. One
/// RastPort does all of it: the pen and the draw mode are changed between
/// fills with SetRPAttrs rather than by making a new one each time.
fn fillDisplay(gb: *GraphicsBase) ?graphics.Rect {
    const rp = gb.CreateRastPortTagList(null) orelse return null;
    defer gb.FreeRastPort(rp);

    // Ask how big it is, and fit the pattern to that, so this says
    // something true on a display that is not this machine's.
    var bounds: graphics.Rect = .{};
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_Bounds, .data = @intFromPtr(&bounds) }, .{} };
    gb.GetRPAttrs(rp, &ask);
    if (bounds.isEmpty()) return null;

    const black = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(0, 0, 0) }, .{} };
    gb.SetRPAttrs(rp, &black);
    gb.RectFill(rp, &bounds);

    const pens = [_]graphics.Pen{
        graphics.penRGB(255, 0, 0),
        graphics.penRGB(0, 255, 0),
        graphics.penRGB(0, 0, 255),
        graphics.penRGB(255, 255, 255),
    };
    const bar_width = @divTrunc(bounds.width(), pens.len);
    const top = @divTrunc(bounds.height(), 8);
    const bottom = @divTrunc(bounds.height(), 2);
    for (pens, 0..) |pen, i| {
        const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = pen }, .{} };
        gb.SetRPAttrs(rp, &tags);
        const from: i32 = @intCast(@as(i32, @intCast(i)) * bar_width);
        gb.RectFill(rp, &.{
            .min_x = from,
            .min_y = top,
            .max_x = from + bar_width,
            .max_y = bottom,
        });
    }

    // Half-covering white across all four, composed with each rather than
    // written over it - so every bar keeps its own colour underneath and
    // no two come out the same.
    const shade = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penARGB(128, 255, 255, 255) },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_BLEND },
        .{},
    };
    gb.SetRPAttrs(rp, &shade);
    const band = @divTrunc(bottom - top, 3);
    gb.RectFill(rp, &.{
        .min_x = 0,
        .min_y = top + band,
        .max_x = bounds.max_x,
        .max_y = top + band * 2,
    });
    return bounds;
}

/// Keep part of the screen in a bitmap of its own and put it back
/// elsewhere - which is what SMART_REFRESH does with what a window covers.
///
/// Returns the strip's size and how many times it was stamped, or null
/// with `why` saying which of the several reasons it was.
fn blitFromOffscreen(gb: *GraphicsBase, why: *i32) ?struct { i32, i32, u32 } {
    const bounds = fillDisplay(gb) orelse return null;

    const screen = gb.CreateRastPortTagList(null) orelse return null;
    defer gb.FreeRastPort(screen);

    // A strip across the bars, kept somewhere that is not the screen. Its
    // format comes from the screen, so moving it either way converts
    // nothing.
    const strip_height = @divTrunc(bounds.height(), 12);
    const tags = [_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = @intCast(bounds.width()) },
        .{ .tag = graphics.BMTAG_Height, .data = @intCast(strip_height) },
        .{ .tag = graphics.BMTAG_Friend, .data = @intFromPtr(screen) },
        .{ .tag = graphics.BMTAG_ErrorPtr, .data = @intFromPtr(why) },
        .{},
    };
    const kept = gb.AllocBitMapTagList(&tags) orelse return null;
    defer gb.FreeBitMap(kept);

    const kept_tags = [_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(kept) }, .{} };
    const kept_rp = gb.CreateRastPortTagList(&kept_tags) orelse return null;
    defer gb.FreeRastPort(kept_rp);

    // Take a strip through the middle of the bars, where the half-covering
    // white crosses them, so what is stamped is unmistakably a copy.
    const from = graphics.Rect{
        .min_x = 0,
        .min_y = @divTrunc(bounds.height(), 4),
        .max_x = bounds.max_x,
        .max_y = @divTrunc(bounds.height(), 4) + strip_height,
    };
    gb.BltRastPort(screen, kept_rp, &from, 0, 0);

    const whole = graphics.Rect{ .min_x = 0, .min_y = 0, .max_x = bounds.width(), .max_y = strip_height };
    var stamped: u32 = 0;
    var y: i32 = @divTrunc(bounds.height(), 2) + strip_height;
    while (y + strip_height <= bounds.max_y) : (y += strip_height * 2) {
        gb.BltRastPort(kept_rp, screen, &whole, 0, y);
        stamped += 1;
    }
    return .{ bounds.width(), strip_height, stamped };
}

/// A fan of lines from the middle of the display, every one of them aimed
/// well past an edge.
///
/// Aiming past the edge is the point: what lands is what the clip left, so
/// a fan that is cut off cleanly at all four sides says the clipping is
/// right, and one that wraps or runs off a row says it is not. The box
/// around the outside is drawn as four Draws from one Move, which is what
/// the current point is for.
fn drawLines(gb: *GraphicsBase) ?u32 {
    const rp = gb.CreateRastPortTagList(null) orelse return null;
    defer gb.FreeRastPort(rp);

    var bounds: graphics.Rect = .{};
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_Bounds, .data = @intFromPtr(&bounds) }, .{} };
    gb.GetRPAttrs(rp, &ask);
    if (bounds.isEmpty()) return null;

    const black = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(0, 0, 0) }, .{} };
    gb.SetRPAttrs(rp, &black);
    gb.RectFill(rp, &bounds);

    const mid_x = @divTrunc(bounds.width(), 2);
    const mid_y = @divTrunc(bounds.height(), 2);
    const reach = bounds.width();

    // Sixteen spokes, walked as a diamond so no trigonometry is needed:
    // the far point goes round the edges of a square well outside the
    // display, which gives every direction a turn.
    const spokes: u32 = 16;
    const pens = [_]graphics.Pen{
        graphics.penRGB(255, 80, 80),
        graphics.penRGB(80, 255, 80),
        graphics.penRGB(80, 80, 255),
        graphics.penRGB(255, 255, 80),
    };
    var i: u32 = 0;
    while (i < spokes) : (i += 1) {
        const step: i32 = @intCast(i);
        const round: i32 = @intCast(spokes);
        // Round the square: 4 sides, `spokes / 4` steps each.
        const side = @divTrunc(step * 4, round);
        const along = @mod(step * 4, round);
        const span = @divTrunc(reach * 2 * along, round);
        const far_x: i32 = switch (side) {
            0 => -reach + span,
            1 => reach,
            2 => reach - span,
            else => -reach,
        };
        const far_y: i32 = switch (side) {
            0 => -reach,
            1 => -reach + span,
            2 => reach,
            else => reach - span,
        };
        const pen = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = pens[i % pens.len] }, .{} };
        gb.SetRPAttrs(rp, &pen);
        gb.Move(rp, mid_x, mid_y);
        gb.Draw(rp, mid_x + far_x, mid_y + far_y);
    }

    // A box just inside the edges, four Draws from one Move.
    const white = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) }, .{} };
    gb.SetRPAttrs(rp, &white);
    const edge: i32 = 4;
    gb.Move(rp, edge, edge);
    gb.Draw(rp, bounds.max_x - 1 - edge, edge);
    gb.Draw(rp, bounds.max_x - 1 - edge, bounds.max_y - 1 - edge);
    gb.Draw(rp, edge, bounds.max_y - 1 - edge);
    gb.Draw(rp, edge, edge);
    return spokes;
}

/// Build a shape out of rectangles, clip to it, and then draw over
/// everything - so what lands is the shape and nothing else.
///
/// A lattice of squares with a hole taken out of the middle of it: the
/// squares show that a region is many rectangles at once, and the hole
/// shows that taking one away is as ordinary as adding one. Then a
/// full-screen fill and a fan of lines, neither of which knows anything
/// about the region - they go through the same clip every drawing call
/// goes through.
fn drawRegion(gb: *GraphicsBase) ?struct { u32, u32 } {
    const rp = gb.CreateRastPortTagList(null) orelse return null;
    defer gb.FreeRastPort(rp);

    var bounds: graphics.Rect = .{};
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_Bounds, .data = @intFromPtr(&bounds) }, .{} };
    gb.GetRPAttrs(rp, &ask);
    if (bounds.isEmpty()) return null;

    const black = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(0, 0, 0) }, .{} };
    gb.SetRPAttrs(rp, &black);
    gb.RectFill(rp, &bounds);

    const region = gb.NewRegion() orelse return null;
    defer gb.DisposeRegion(region);

    const across: i32 = 6;
    const down: i32 = 4;
    const cell_w = @divTrunc(bounds.width(), across + 1);
    const cell_h = @divTrunc(bounds.height(), down + 1);
    const gap_w = @divTrunc(cell_w, 4);
    const gap_h = @divTrunc(cell_h, 4);

    var squares: u32 = 0;
    var row: i32 = 0;
    while (row < down) : (row += 1) {
        var col: i32 = 0;
        while (col < across) : (col += 1) {
            const x = gap_w + col * cell_w;
            const y = gap_h + row * cell_h;
            if (!gb.OrRectRegion(region, &.{
                .min_x = x,
                .min_y = y,
                .max_x = x + cell_w - gap_w,
                .max_y = y + cell_h - gap_h,
            })) return null;
            squares += 1;
        }
    }

    // A hole through the middle of the lattice, taken out of whatever
    // squares it crosses.
    const hole_w = @divTrunc(bounds.width(), 5);
    const hole_h = @divTrunc(bounds.height(), 5);
    if (!gb.ClearRectRegion(region, &.{
        .min_x = @divTrunc(bounds.width(), 2) - @divTrunc(hole_w, 2),
        .min_y = @divTrunc(bounds.height(), 2) - @divTrunc(hole_h, 2),
        .max_x = @divTrunc(bounds.width(), 2) + @divTrunc(hole_w, 2),
        .max_y = @divTrunc(bounds.height(), 2) + @divTrunc(hole_h, 2),
    })) return null;

    const install = [_]TagItem{
        .{ .tag = graphics.RPTAG_ClipRegion, .data = @intFromPtr(region) },
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(60, 90, 200) },
        .{},
    };
    gb.SetRPAttrs(rp, &install);
    // Over the whole screen: only the lattice takes it.
    gb.RectFill(rp, &bounds);

    // And lines, which are cut by the same clip without knowing it.
    const yellow = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 220, 0) }, .{} };
    gb.SetRPAttrs(rp, &yellow);
    const lines: u32 = 12;
    var i: u32 = 0;
    while (i < lines) : (i += 1) {
        const y = @divTrunc(bounds.height() * @as(i32, @intCast(i)), @as(i32, @intCast(lines)));
        gb.Move(rp, 0, y);
        gb.Draw(rp, bounds.max_x - 1, bounds.max_y - 1 - y);
    }

    // The region must come off the RastPort before it is disposed of.
    const off = [_]TagItem{ .{ .tag = graphics.RPTAG_ClipRegion, .data = 0 }, .{} };
    gb.SetRPAttrs(rp, &off);
    return .{ squares, lines };
}

/// One picture, drawn with every primitive the library has.
///
/// Not a switch per call: a call tested on its own only shows that it
/// works on its own. Drawn together, they have to agree about the pens,
/// the clip, the line pattern and the draw mode, and a disagreement shows
/// up as something in the wrong place or the wrong colour.
///
/// Laid out in a grid so it fits any display: everything is worked out
/// from the bounds the library reports.
fn drawEverything(gb: *GraphicsBase) ?graphics.Rect {
    const rp = gb.CreateRastPortTagList(null) orelse return null;
    defer gb.FreeRastPort(rp);

    var bounds: graphics.Rect = .{};
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_Bounds, .data = @intFromPtr(&bounds) }, .{} };
    gb.GetRPAttrs(rp, &ask);
    if (bounds.isEmpty()) return null;

    const w = bounds.width();
    const h = bounds.height();
    const cell_w = @divTrunc(w, 4);
    const cell_h = @divTrunc(h, 2);

    const black = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(0, 0, 0) }, .{} };
    gb.SetRPAttrs(rp, &black);
    gb.RectFill(rp, &bounds);

    // --- one: runs, an outline and a filled panel -----------------------
    var pen = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(70, 120, 220) }, .{} };
    gb.SetRPAttrs(rp, &pen);
    gb.RectFill(rp, &.{
        .min_x = @divTrunc(cell_w, 8),
        .min_y = @divTrunc(cell_h, 8),
        .max_x = @divTrunc(cell_w * 7, 8),
        .max_y = @divTrunc(cell_h * 3, 8),
    });
    pen[0].data = graphics.penRGB(255, 255, 255);
    gb.SetRPAttrs(rp, &pen);
    gb.DrawRect(rp, &.{
        .min_x = @divTrunc(cell_w, 8),
        .min_y = @divTrunc(cell_h, 2),
        .max_x = @divTrunc(cell_w * 7, 8),
        .max_y = @divTrunc(cell_h * 7, 8),
    });
    // Runs, and single pixels scattered between them.
    pen[0].data = graphics.penRGB(0, 220, 120);
    gb.SetRPAttrs(rp, &pen);
    var i: i32 = 0;
    while (i < 6) : (i += 1) {
        gb.DrawHLine(rp, @divTrunc(cell_w, 6), @divTrunc(cell_h * 5, 8) + i * 3, @divTrunc(cell_w, 2));
    }
    gb.DrawVLine(rp, @divTrunc(cell_w * 3, 4), @divTrunc(cell_h * 5, 8), @divTrunc(cell_h, 6));
    i = 0;
    while (i < 40) : (i += 1) {
        gb.WritePixel(rp, @divTrunc(cell_w, 6) + i * 3, @divTrunc(cell_h * 7, 16));
    }

    // --- two: circles and an ellipse ------------------------------------
    const cx2 = cell_w + @divTrunc(cell_w, 2);
    const cy2 = @divTrunc(cell_h, 2);
    pen[0].data = graphics.penRGB(255, 200, 40);
    gb.SetRPAttrs(rp, &pen);
    var r: i32 = @divTrunc(cell_h, 10);
    while (r < @divTrunc(cell_h, 3)) : (r += @divTrunc(cell_h, 16) + 1) {
        gb.DrawCircle(rp, cx2, cy2, r);
    }
    pen[0].data = graphics.penRGB(255, 90, 90);
    gb.SetRPAttrs(rp, &pen);
    gb.DrawEllipse(rp, cx2, cy2 + cell_h, @divTrunc(cell_w, 3), @divTrunc(cell_h, 5));
    gb.DrawEllipse(rp, cx2, cy2 + cell_h, @divTrunc(cell_w, 5), @divTrunc(cell_h, 3));

    // --- three: arcs, as a fan of quarters ------------------------------
    const cx3 = cell_w * 2 + @divTrunc(cell_w, 2);
    const cy3 = @divTrunc(cell_h, 2);
    const arc_pens = [_]graphics.Pen{
        graphics.penRGB(255, 80, 80),  graphics.penRGB(80, 255, 80),
        graphics.penRGB(80, 160, 255), graphics.penRGB(255, 255, 80),
    };
    i = 0;
    while (i < 4) : (i += 1) {
        pen[0].data = arc_pens[@intCast(i)];
        gb.SetRPAttrs(rp, &pen);
        var rr: i32 = @divTrunc(cell_h, 8);
        while (rr < @divTrunc(cell_h, 3)) : (rr += 3) {
            gb.DrawArc(rp, cx3, cy3, rr, i * 90 + 6, i * 90 + 84);
        }
    }

    // --- four: a polygon, and the line pattern --------------------------
    const cx4 = cell_w * 3 + @divTrunc(cell_w, 2);
    const cy4 = @divTrunc(cell_h, 2);
    const reach = @divTrunc(cell_h, 3);
    pen[0].data = graphics.penRGB(200, 120, 255);
    gb.SetRPAttrs(rp, &pen);
    // A five-pointed star: every second corner of ten round a circle.
    var star: [11]graphics.Point = undefined;
    i = 0;
    while (i < 11) : (i += 1) {
        const step = @mod(i * 4, 10);
        const far = if (@mod(step, 2) == 0) reach else @divTrunc(reach, 2);
        // Corners by eye rather than by trigonometry, which a command has
        // no business doing: ten points round a circle, written down.
        const around = [_][2]i32{
            .{ 0, -100 }, .{ 59, -81 }, .{ 95, -31 }, .{ 95, 31 },   .{ 59, 81 },
            .{ 0, 100 },  .{ -59, 81 }, .{ -95, 31 }, .{ -95, -31 }, .{ -59, -81 },
        };
        star[@intCast(i)] = .{
            .x = cx4 + @divTrunc(around[@intCast(step)][0] * far, 100),
            .y = cy4 + @divTrunc(around[@intCast(step)][1] * far, 100),
        };
    }
    gb.Move(rp, star[0].x, star[0].y);
    gb.DrawPoly(rp, star.len - 1, star[1..].ptr);

    // Dotted, then dashed in two colours, so the pattern and JAM2 are
    // visible side by side.
    const dotted = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) },
        .{ .tag = graphics.RPTAG_LinePattern, .data = 0xAAAA },
        .{},
    };
    gb.SetRPAttrs(rp, &dotted);
    gb.Move(rp, cell_w * 3 + @divTrunc(cell_w, 8), cy4 + cell_h - @divTrunc(cell_h, 4));
    gb.Draw(rp, cell_w * 4 - @divTrunc(cell_w, 8), cy4 + cell_h - @divTrunc(cell_h, 4));

    const dashed = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 0) },
        .{ .tag = graphics.RPTAG_BPen, .data = graphics.penRGB(120, 0, 0) },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM2 },
        .{ .tag = graphics.RPTAG_LinePattern, .data = 0xF0F0 },
        .{},
    };
    gb.SetRPAttrs(rp, &dashed);
    gb.Move(rp, cell_w * 3 + @divTrunc(cell_w, 8), cy4 + cell_h - @divTrunc(cell_h, 8));
    gb.Draw(rp, cell_w * 4 - @divTrunc(cell_w, 8), cy4 + cell_h - @divTrunc(cell_h, 8));

    // --- filled shapes, in the space below the first cell ---------------
    // Room for the corners: a curve becomes corners too, and a small one
    // wants about one for each degree of it.
    if (gb.InitArea(rp, 512)) {
        const fx = @divTrunc(cell_w, 2);
        const fy = cell_h + @divTrunc(cell_h, 2);
        const reach2 = @divTrunc(cell_h, 4);

        // A filled square with a round hole in it. The hole needs nothing
        // said about it: the fill is even-odd, so a shape inside another
        // leaves the middle empty.
        pen[0].data = graphics.penRGB(120, 200, 120);
        gb.SetRPAttrs(rp, &pen);
        _ = gb.AreaMove(rp, fx - reach2, fy - reach2);
        _ = gb.AreaDraw(rp, fx + reach2, fy - reach2);
        _ = gb.AreaDraw(rp, fx + reach2, fy + reach2);
        _ = gb.AreaDraw(rp, fx - reach2, fy + reach2);
        _ = gb.AreaCircle(rp, fx, fy, @divTrunc(reach2, 2));
        _ = gb.AreaEnd(rp);

        // And a pie, which is a wedge rather than a slice of outline.
        pen[0].data = graphics.penRGB(255, 160, 40);
        gb.SetRPAttrs(rp, &pen);
        _ = gb.AreaArc(rp, fx + cell_w - @divTrunc(cell_w, 6), fy, reach2, 30, 300);
        _ = gb.AreaEnd(rp);
    }

    // --- text, in both fonts and a few styles --------------------------
    // Opened by name and height. Sixteen is eight drawn twice as tall.
    const heights = [_]u32{ 8, 16 };
    const labels = [_][]const u8{ "pospaz 8  ABCdef 0123", "pospaz 16 ABCdef 0123" };
    const tops = [_]i32{ 0, 18 };
    var line: i32 = 0;
    while (line < 2) : (line += 1) {
        const font = gb.OpenFont(graphics.POSPAZNAME, heights[@intCast(line)]) orelse continue;
        defer gb.CloseFont(font);
        const with_font = [_]TagItem{
            .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(font) },
            .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) },
            .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
            .{ .tag = graphics.RPTAG_TextStyle, .data = graphics.FS_NORMAL },
            .{},
        };
        gb.SetRPAttrs(rp, &with_font);
        const text = labels[@intCast(line)];
        gb.Move(rp, cell_w * 2 + @divTrunc(cell_w, 8), cell_h + @divTrunc(cell_h, 4) + tops[@intCast(line)]);
        gb.Text(rp, text.ptr, @intCast(text.len));
    }

    // The styles, and JAM2 so the paper goes down behind the letters -
    // which is what makes a line of text readable over a picture.
    const eight = gb.OpenFont(graphics.POSPAZNAME, 8);
    if (eight) |font| {
        defer gb.CloseFont(font);
        const styles = [_]struct { style: graphics.FontStyle, what: []const u8 }{
            .{ .style = graphics.FSF_BOLD, .what = "bold" },
            .{ .style = graphics.FSF_ITALIC, .what = "italic" },
            .{ .style = graphics.FSF_UNDERLINED, .what = "underlined" },
        };
        var at: i32 = 0;
        for (styles) |entry| {
            const tags2 = [_]TagItem{
                .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(font) },
                .{ .tag = graphics.RPTAG_TextStyle, .data = entry.style },
                .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM2 },
                .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(0, 0, 0) },
                .{ .tag = graphics.RPTAG_BPen, .data = graphics.penRGB(255, 220, 120) },
                .{},
            };
            gb.SetRPAttrs(rp, &tags2);
            gb.Move(rp, cell_w * 2 + @divTrunc(cell_w, 8) + at, cell_h + @divTrunc(cell_h, 4) + 58);
            gb.Text(rp, entry.what.ptr, @intCast(entry.what.len));
            at += gb.TextLength(rp, entry.what.ptr, @intCast(entry.what.len)) + 8;
        }
    }

    // --- a pattern and a template ---------------------------------------
    // A grey made of alternate pixels, which is what a desktop is made of.
    // Drawn as two rectangles side by side on purpose: the tile is
    // anchored to the surface, so the join does not show.
    const grey = [_]u8{ 0xAA, 0x55 };
    const patterned = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(190, 190, 190) },
        .{ .tag = graphics.RPTAG_BPen, .data = graphics.penRGB(40, 40, 60) },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM2 },
        .{},
    };
    gb.SetRPAttrs(rp, &patterned);
    // The clear strip along the bottom left, where nothing else sits.
    const band_top = h - 56;
    const band_end = @divTrunc(w, 4) - 8;
    const mid = @divTrunc(band_end, 2);
    gb.BltPattern(rp, &grey, 1, 2, 2, &.{
        .min_x = 16,
        .min_y = band_top,
        .max_x = mid,
        .max_y = band_top + 20,
    });
    gb.BltPattern(rp, &grey, 1, 2, 2, &.{
        .min_x = mid,
        .min_y = band_top,
        .max_x = band_end,
        .max_y = band_top + 20,
    });

    // A shape one bit to a pixel, stencilled in the pens - which is what
    // an icon or a pointer is. An arrow, sixteen wide and sixteen tall.
    const arrow = [_]u8{
        0b1000_0000, 0b0000_0000,
        0b1100_0000, 0b0000_0000,
        0b1110_0000, 0b0000_0000,
        0b1111_0000, 0b0000_0000,
        0b1111_1000, 0b0000_0000,
        0b1111_1100, 0b0000_0000,
        0b1111_1110, 0b0000_0000,
        0b1111_1111, 0b0000_0000,
        0b1111_1111, 0b1000_0000,
        0b1111_1100, 0b0000_0000,
        0b1101_1110, 0b0000_0000,
        0b1000_1110, 0b0000_0000,
        0b0000_0111, 0b0000_0000,
        0b0000_0111, 0b0000_0000,
        0b0000_0011, 0b1000_0000,
        0b0000_0000, 0b0000_0000,
    };
    const stencilled = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
        .{},
    };
    gb.SetRPAttrs(rp, &stencilled);
    var shape_at: i32 = 0;
    while (shape_at < 6) : (shape_at += 1) {
        gb.BltTemplate(rp, &arrow, 2, 0, 0, &.{
            .min_x = 16 + shape_at * 26,
            .min_y = band_top + 26,
            .max_x = 16 + shape_at * 26 + 16,
            .max_y = band_top + 42,
        });
    }

    // --- across the whole picture: complement, then blend ---------------
    // A box drawn by inverting what is under it, so it shows against
    // everything it crosses without knowing what any of it was.
    const invert = [_]TagItem{
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_COMPLEMENT },
        .{ .tag = graphics.RPTAG_LinePattern, .data = graphics.LINE_SOLID },
        .{},
    };
    gb.SetRPAttrs(rp, &invert);
    gb.DrawRect(rp, &.{
        .min_x = @divTrunc(w, 8),
        .min_y = @divTrunc(h, 3),
        .max_x = @divTrunc(w * 7, 8),
        .max_y = @divTrunc(h * 2, 3),
    });

    // And a half-covering wash over the lower middle, which composes with
    // whatever it lands on rather than replacing it.
    const wash = [_]TagItem{
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_BLEND },
        .{ .tag = graphics.RPTAG_APen, .data = graphics.penARGB(110, 255, 255, 255) },
        .{},
    };
    gb.SetRPAttrs(rp, &wash);
    gb.RectFill(rp, &.{
        .min_x = @divTrunc(w, 4),
        .min_y = @divTrunc(h * 5, 6),
        .max_x = @divTrunc(w * 3, 4),
        .max_y = h,
    });
    return bounds;
}

/// The alert box, with the words on it.
///
/// The kernel draws nothing when the machine stops: its alert goes out on
/// exec's raw port (`src/arch/esp32s3/alert.zig`), which is where a
/// stopped machine is read from, since it needs no display and no library.
///
/// This is what an alert box looks like once something above the kernel
/// can draw text. It is a picture of an alert and not a report of one: nothing
/// has gone wrong, and the numbers are the ones a Zig panic would carry.
///
/// Only the words on the raw port are sure to appear: a library that draws
/// the alert has to be working for it to show, and the thing being
/// reported may be the reason it is not.
/// Three windows sharing the display, then the back one raised.
///
/// It is the whole of layers in one picture: each window fills all of
/// itself in its own coordinates and what is in front of it simply does
/// not receive the pixels; then the back one is raised, which uncovers
/// what the others had, and the damage that comes back confines a second
/// full redraw to exactly the uncovered part. If the tiling were wrong the
/// windows would bleed into one another; if the coordinates were wrong
/// they would be drawn in the wrong place; and if the damage were wrong
/// the second redraw would repaint a whole window instead of a corner.
fn drawLayers(sys: *ExecBase, gb: *GraphicsBase) ?u32 {
    const lib = sys.OpenLibrary(layers.LAYERSNAME, layers.LAYERS_VERSION) orelse return null;
    defer sys.CloseLibrary(lib);
    const lb: *LayersBase = @ptrCast(lib);

    const screen = gb.CreateRastPortTagList(null) orelse return null;
    defer gb.FreeRastPort(screen);

    var bounds: graphics.Rect = .{};
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_Bounds, .data = @intFromPtr(&bounds) }, .{} };
    gb.GetRPAttrs(screen, &ask);
    if (bounds.isEmpty()) return null;

    // Clear to something that is plainly not a window, so a gap between
    // them shows up rather than blending in.
    const grey = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(40, 40, 60) }, .{} };
    gb.SetRPAttrs(screen, &grey);
    gb.RectFill(screen, &bounds);

    const info = lb.NewLayerInfo(screen) orelse return null;
    defer lb.DisposeLayerInfo(info);

    const font = gb.OpenFont(graphics.POSPAZNAME, 8);
    defer if (font) |f| gb.CloseFont(f);

    // Three windows, each overlapping the one before, stepped across the
    // display so the picture says something on any size of screen.
    const step_x = @divTrunc(bounds.width(), 6);
    const step_y = @divTrunc(bounds.height(), 6);
    const wide = step_x * 3;
    const high = step_y * 3;
    const pens = [_]graphics.Pen{
        graphics.penRGB(160, 40, 40),
        graphics.penRGB(40, 140, 60),
        graphics.penRGB(50, 70, 170),
    };
    // The name says where the window is in the order, because a picture of
    // overlapping rectangles does not: which one is on top is exactly what
    // the reader cannot work out for themselves. These are the positions
    // the windows end in - one starts at the back, is raised over the
    // others and put away again, so the order it finishes in is the one it
    // started in.
    const names = [_][*:0]const u8{
        "one - 3 of 3, at the back (simple)",
        "two - 2 of 3, in the middle (simple)",
        "three - 1 of 3, in front (smart)",
    };
    // The front one keeps what is covered instead of losing it, so when it
    // is uncovered again its pixels come back on their own. That is the
    // whole difference between the two refresh modes, and putting one of
    // each in the picture is the only way to see it.
    const refresh = [_]usize{ layers.LAYERSIMPLE, layers.LAYERSIMPLE, layers.LAYERSMART };

    // Both windows that get uncovered redraw, and their damage happens to
    // abut exactly - together they are the whole footprint of the raised
    // window - so in one colour the two would read as a single block with
    // two labels on it. Each paints its damage in a **lighter shade of its
    // own colour**, which says what it is without having to be read: that
    // is the green window coming back, and that is the blue one.
    const redraw_names = [_][*:0]const u8{
        "",
        "two redrawn - window one had been here",
        "three redrawn - window one had been here",
    };

    var made: [3]*layers.Layer = undefined;
    var count: u32 = 0;
    for (pens, 0..) |pen, i| {
        const left = step_x * @as(i32, @intCast(i)) + @divTrunc(step_x, 2);
        const top = step_y * @as(i32, @intCast(i)) + @divTrunc(step_y, 2);
        const at = graphics.Rect{
            .min_x = left,
            .min_y = top,
            .max_x = left + wide,
            .max_y = top + high,
        };
        const tags = [_]TagItem{
            .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&at) },
            .{ .tag = layers.LATAG_Refresh, .data = refresh[i] },
            .{},
        };
        const layer = lb.CreateLayerTagList(info, &tags) orelse break;
        made[i] = layer;
        count += 1;
        if (rastPortOf(lb, layer)) |rp| {
            fillLayer(gb, rp, pen, wide, high, true);
            label(gb, rp, font, 6, 14, names[i], graphics.penRGB(255, 255, 255));
        }
    }
    if (count == 0) return null;

    // Raise the one at the back over the others, and then put it away
    // again. Covering a layer is not damage - its pixels are simply not
    // written - but *uncovering* one is, because with the simple refresh
    // nothing kept what was underneath.
    _ = lb.UpfrontLayer(made[0]);
    _ = lb.BehindLayer(made[0]);
    if (rastPortOf(lb, made[0])) |rp| {
        fillLayer(gb, rp, pens[0], wide, high, true);
        label(gb, rp, font, 6, 14, names[0], graphics.penRGB(255, 255, 255));
    }

    // A smart layer answers false here, having nothing to redraw: its
    // pixels were put back the moment it was uncovered. So the loop paints
    // only the simple ones, and what is left in its own colour is the
    // smart one that never had to.
    var i: u32 = 1;
    while (i < count) : (i += 1) {
        // Where the damage is, read before the update clears it, so the
        // block can be labelled at its own corner rather than at the
        // window's - which may well be nowhere near it.
        var corner = graphics.Rect{};
        var owed: usize = 0;
        const ask_damage = [_]TagItem{ .{ .tag = layers.LATAG_GetDamage, .data = @intFromPtr(&owed) }, .{} };
        lb.GetLayerAttrs(made[i], &ask_damage);
        const have_corner = owed != 0 and gb.RegionRectangles(@ptrFromInt(owed), @ptrCast(&corner), 1) != 0;

        if (!lb.BeginUpdate(made[i])) continue;
        const rp = rastPortOf(lb, made[i]) orelse continue;
        // A whole repaint in a colour of its own. Only what was uncovered
        // can land, so what shows is the shape of the damage - which is
        // exactly where the raised window had been over this one. No
        // border: that belongs to the window, and drawn here it would be
        // cut to the damage and read as an edge of something else.
        fillLayer(gb, rp, lighter(pens[i]), wide, high, false);
        if (have_corner) {
            // The caption in the window's own colour, on the lighter
            // shade of it: legible, and it ties the two together.
            label(gb, rp, font, corner.min_x + 4, corner.min_y + 12, redraw_names[i], pens[i]);
        }
        lb.EndUpdate(made[i], true);
    }
    return count;
}

/// The RastPort a layer draws through, which is the only way to draw into
/// one.
fn rastPortOf(lb: *LayersBase, layer: *layers.Layer) ?*graphics.RastPort {
    var where: usize = 0;
    const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetRastPort, .data = @intFromPtr(&where) }, .{} };
    lb.GetLayerAttrs(layer, &ask);
    if (where == 0) return null;
    return @ptrFromInt(where);
}

/// Fill the whole of a layer, in the layer's own coordinates - which is
/// the point being made: it asks for all of itself and gets whatever it
/// can actually see.
fn fillLayer(gb: *GraphicsBase, rp: *graphics.RastPort, pen: graphics.Pen, wide: i32, high: i32, border: bool) void {
    const ink = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = pen }, .{} };
    gb.SetRPAttrs(rp, &ink);
    gb.RectFill(rp, &.{ .max_x = wide, .max_y = high });

    if (!border) return;
    // A border, so where one window ends and the next begins is never in
    // doubt.
    const edge = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(255, 255, 255) }, .{} };
    gb.SetRPAttrs(rp, &edge);
    gb.DrawRect(rp, &.{ .max_x = wide, .max_y = high });
}

/// The same colour, half way to white.
///
/// A window paints its damage in this rather than in a colour of its own,
/// so that what appears is plainly the window coming back rather than
/// something new arriving. A pen is 0xAARRGGBB, so this is arithmetic on
/// the three components and nothing more.
fn lighter(pen: graphics.Pen) graphics.Pen {
    const r: u32 = (pen >> 16) & 0xFF;
    const g: u32 = (pen >> 8) & 0xFF;
    const b: u32 = pen & 0xFF;
    return graphics.penRGB(
        @intCast(r + (255 - r) / 2),
        @intCast(g + (255 - g) / 2),
        @intCast(b + (255 - b) / 2),
    );
}

/// A line of text at a point in the layer's own coordinates.
fn label(gb: *GraphicsBase, rp: *graphics.RastPort, font: ?*graphics.TextFont, x: i32, y: i32, text: [*:0]const u8, pen: graphics.Pen) void {
    const f = font orelse return;
    graphics.SetFont(gb, rp, f);
    const ink = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = pen }, .{} };
    gb.SetRPAttrs(rp, &ink);
    gb.Move(rp, x, y);
    gb.Text(rp, text, textLen(text));
}

fn textLen(s: [*:0]const u8) u32 {
    var n: u32 = 0;
    while (s[n] != 0) n += 1;
    return n;
}

fn drawGuru(gb: *GraphicsBase) bool {
    const rp = gb.CreateRastPortTagList(null) orelse return false;
    defer gb.FreeRastPort(rp);

    var bounds: graphics.Rect = .{};
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_Bounds, .data = @intFromPtr(&bounds) }, .{} };
    gb.GetRPAttrs(rp, &ask);
    if (bounds.isEmpty()) return false;

    const font = gb.OpenFont(graphics.POSPAZNAME, 8) orelse return false;
    defer gb.CloseFont(font);
    // Opening a font does not put it on a RastPort - a font is shared, and
    // OpenFont has no RastPort to put it on. Without this the text calls
    // draw nothing and answer GERR_NO_FONT.
    graphics.SetFont(gb, rp, font);

    // Where the box goes and how big it is.
    const top: i32 = 24;
    const height: i32 = 88;
    const border: i32 = 6;
    const red = graphics.penRGB(255, 0, 0);

    // Black everywhere, so the band is plainly a band and not a screen
    // that failed to come up - which is what the kernel's comment says the
    // shape is for.
    const black = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = graphics.penRGB(0, 0, 0) }, .{} };
    gb.SetRPAttrs(rp, &black);
    gb.RectFill(rp, &bounds);

    // The border as four runs rather than a filled rectangle with a black
    // one inside it: the inside is already black, and DrawRect would give
    // a border one pixel thick.
    const in_red = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = red }, .{} };
    gb.SetRPAttrs(rp, &in_red);
    gb.RectFill(rp, &.{ .min_x = 0, .min_y = top, .max_x = bounds.max_x, .max_y = top + border });
    gb.RectFill(rp, &.{ .min_x = 0, .min_y = top + height - border, .max_x = bounds.max_x, .max_y = top + height });
    gb.RectFill(rp, &.{ .min_x = 0, .min_y = top, .max_x = border, .max_y = top + height });
    gb.RectFill(rp, &.{ .min_x = bounds.max_x - border, .min_y = top, .max_x = bounds.max_x, .max_y = top + height });

    // The two lines the kernel prints, centred in what the border leaves.
    const lines = [_][]const u8{
        "Software Failure.  Press left mouse button to continue.",
        "Guru Meditation #81000100.4038A1C4",
    };
    var height_of: u32 = 0;
    const metrics = [_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height_of) }, .{} };
    gb.GetRPAttrs(rp, &metrics);
    const line_height: i32 = @as(i32, @intCast(height_of)) + 4;
    const inside_top = top + border;
    const inside_height = height - border * 2;
    const block = line_height * @as(i32, lines.len);
    var y = inside_top + @divTrunc(inside_height - block, 2);

    for (lines) |line| {
        // Centred by measuring rather than by counting characters, so it
        // stays centred in a font that is not eight wide.
        const wide = gb.TextLength(rp, line.ptr, @intCast(line.len));
        gb.Move(rp, @divTrunc(bounds.width() - wide, 2), y + @as(i32, @intCast(height_of)) - 2);
        gb.Text(rp, line.ptr, @intCast(line.len));
        y += line_height;
    }
    return true;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [11]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const lib = sys.OpenLibrary(graphics.GRAPHICSNAME, graphics.GRAPHICS_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{graphics.GRAPHICSNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(lib);
    const gb: *GraphicsBase = @ptrCast(lib);

    const all = argv[arg_all] != 0;
    const want_display = all or argv[arg_display] != 0;
    const want_memory = all or argv[arg_memory] != 0;
    const want_formats = all or argv[arg_formats] != 0;
    // Nothing asked for is the summary: every line, but the formats as a
    // count rather than a table.
    const summary = !want_display and !want_memory and !want_formats;

    if (summary) {
        _ = Printf(dl, MSG_RELEASE, .{
            lib.name(),
            @as(u32, lib.version),
            @as(u32, lib.revision),
        });
    }

    // A format string is comptime, so the branch is on the call and not on
    // the string.
    if (summary or want_display) {
        var why: i32 = 0;
        if (displayShape(gb, &why)) |shape| {
            const bounds, const format = shape;
            _ = Printf(dl, MSG_DISPLAY_YES, .{ bounds.width(), bounds.height(), formatName(format) });
        } else {
            // The library says which of the several reasons it was, so this
            // does not have to guess at a list of them.
            _ = Printf(dl, MSG_DISPLAY_NO, .{gb.GraphicsErrorText(why)});
        }
    }

    if (summary or want_memory) {
        // rgb565 is the panel's format, so it is the one worth reporting
        // when nobody named another.
        if (takesFormat(sys, gb, .rgb565)) {
            _ = Printf(dl, MSG_MEMORY_YES, .{"rgb565"});
        } else {
            _ = Printf(dl, MSG_MEMORY_NO, .{"rgb565"});
        }
    }

    if (argv[arg_fill] != 0) {
        if (fillDisplay(gb)) |bounds| {
            _ = Printf(dl, MSG_FILLED, .{ bounds.width(), bounds.height() });
        } else {
            _ = Printf(dl, MSG_NOFILL, .{});
        }
        return dos.RETURN_OK;
    }

    if (argv[arg_blit] != 0) {
        var why: i32 = graphics.GERR_NO_DISPLAY;
        if (blitFromOffscreen(gb, &why)) |what| {
            const w, const h, const times = what;
            _ = Printf(dl, MSG_BLITTED, .{ w, h, times });
        } else {
            _ = Printf(dl, MSG_NOBLIT, .{gb.GraphicsErrorText(why)});
        }
        return dos.RETURN_OK;
    }

    if (argv[arg_lines] != 0) {
        if (drawLines(gb)) |spokes| {
            _ = Printf(dl, MSG_LINES, .{spokes});
        } else {
            _ = Printf(dl, MSG_NOLINES, .{});
        }
        return dos.RETURN_OK;
    }

    if (argv[arg_region] != 0) {
        if (drawRegion(gb)) |what| {
            const squares, const lines = what;
            _ = Printf(dl, MSG_REGION, .{ squares, lines });
        } else {
            _ = Printf(dl, MSG_NOREGION, .{});
        }
        return dos.RETURN_OK;
    }

    if (argv[arg_draw] != 0) {
        if (drawEverything(gb)) |bounds| {
            _ = Printf(dl, MSG_DRAWN, .{ bounds.width(), bounds.height() });
        } else {
            _ = Printf(dl, MSG_NODRAWN, .{});
        }
        return dos.RETURN_OK;
    }

    if (argv[arg_guru] != 0) {
        if (drawGuru(gb)) {
            _ = Printf(dl, MSG_GURU, .{});
        } else {
            _ = Printf(dl, MSG_NOGURU, .{});
        }
        return dos.RETURN_OK;
    }

    if (argv[arg_layers] != 0) {
        if (drawLayers(sys, gb)) |made| {
            _ = Printf(dl, MSG_LAYERS, .{made});
        } else {
            _ = Printf(dl, MSG_NOLAYERS, .{});
        }
        return dos.RETURN_OK;
    }

    if (want_formats) {
        var taken: u32 = 0;
        for (formats) |entry| {
            const ok = takesFormat(sys, gb, entry.format);
            if (ok) taken += 1;
            _ = Printf(dl, MSG_FORMAT_ROW, .{ entry.name, if (ok) MSG_TAKEN else MSG_REFUSED });
        }
        _ = Printf(dl, MSG_FORMATS, .{ taken, @as(u32, formats.len) });
    } else if (summary) {
        var taken: u32 = 0;
        for (formats) |entry| {
            if (takesFormat(sys, gb, entry.format)) taken += 1;
        }
        _ = Printf(dl, MSG_FORMATS, .{ taken, @as(u32, formats.len) });
    }

    return dos.RETURN_OK;
}
