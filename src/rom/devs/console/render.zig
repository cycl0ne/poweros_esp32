// SPDX-License-Identifier: MPL-2.0
//! Drawing a console's cells into its window.
//!
//! A row is drawn as runs of cells that share their colours and style: one
//! `Text` call each, in JAM2 so the background comes with it. The cursor is
//! the cell under it complemented as on a screen of four pens: background
//! to fill and text to shine, a blue block with a white letter on the
//! default screen.
//!
//! The cells' characters go to `Text` in UTF-8. A wide character is drawn
//! on its own, in the middle of its two cells; its second cell is drawn
//! with it, and one left without the first is drawn blank.
//!
//! The line-drawing set is drawn rather than written, so it needs nothing
//! of the font: a horizontal line is a line across the middle of the cell,
//! a corner is two half lines, and the few every font has - degree,
//! plus-minus, pound, middle dot - are written as themselves.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const utf8 = sdk.utility.utf8;
const term = @import("term.zig");
const Cell = term.Cell;
const Term = term.Term;

/// What a console needs to draw itself: where its cells go on the window.
pub const Layout = struct {
    rp: *graphics.RastPort,
    origin_x: i32,
    origin_y: i32,
    cell_width: i32,
    cell_height: i32,
    baseline: i32,
    /// What COLOR_DEFAULT means here: the screen's text and background.
    fg: graphics.Pen,
    bg: graphics.Pen,
    /// The screen's shine and fill pens: what the cursor turns text and
    /// background into.
    shine: graphics.Pen,
    fill: graphics.Pen,
};

/// The colour a pen becomes under the cursor. The cursor complements the
/// cell, as it would on a screen of four pens: background and fill trade
/// places, and so do text and shine - on the default screen a blue block
/// with the letter in white. A colour that is none of the four is
/// complemented outright.
fn complement(pen: graphics.Pen, l: Layout) graphics.Pen {
    if (pen == l.bg) return l.fill;
    if (pen == l.fill) return l.bg;
    if (pen == l.fg) return l.shine;
    if (pen == l.shine) return l.fg;
    return pen ^ 0x00FF_FFFF;
}

/// The 256 colours, as ARGB: the eight, the eight bright ones, a 6x6x6
/// cube, and 24 greys - xterm's palette, which is what a program that sends
/// `38;5;n` means.
pub const palette: [256]graphics.Pen = blk: {
    var p: [256]graphics.Pen = undefined;
    const basic = [8][3]u8{
        .{ 0, 0, 0 },   .{ 170, 0, 0 },   .{ 0, 170, 0 },   .{ 170, 85, 0 },
        .{ 0, 0, 170 }, .{ 170, 0, 170 }, .{ 0, 170, 170 }, .{ 170, 170, 170 },
    };
    const bright = [8][3]u8{
        .{ 85, 85, 85 },  .{ 255, 85, 85 },  .{ 85, 255, 85 },  .{ 255, 255, 85 },
        .{ 85, 85, 255 }, .{ 255, 85, 255 }, .{ 85, 255, 255 }, .{ 255, 255, 255 },
    };
    for (basic, 0..) |c, i| p[i] = graphics.penRGB(c[0], c[1], c[2]);
    for (bright, 0..) |c, i| p[8 + i] = graphics.penRGB(c[0], c[1], c[2]);
    const steps = [6]u8{ 0, 95, 135, 175, 215, 255 };
    var i: u32 = 16;
    for (steps) |r| for (steps) |g| for (steps) |b| {
        p[i] = graphics.penRGB(r, g, b);
        i += 1;
    };
    var grey: u32 = 0;
    while (grey < 24) : (grey += 1) {
        const v: u8 = @intCast(8 + grey * 10);
        p[232 + grey] = graphics.penRGB(v, v, v);
    }
    break :blk p;
};

fn penOf(color: u16, default: graphics.Pen) graphics.Pen {
    if (color == term.COLOR_DEFAULT) return default;
    return palette[color & 0xFF];
}

/// The two pens a cell is drawn with, reverse video and conceal included.
fn pensOf(cell: Cell, l: Layout) struct { graphics.Pen, graphics.Pen } {
    var fg = penOf(cell.fg, l.fg);
    var bg = penOf(cell.bg, l.bg);
    if (cell.flags & term.CELL_BOLD != 0) {
        fg = if (cell.fg == term.COLOR_DEFAULT) palette[15] else palette[(cell.fg & 0xFF) | 8];
    }
    // Faint is bold's mirror: the dimmer of the pair, which for one of the
    // sixteen named colours is itself with the bright bit off. The rest of
    // the 256 are a cube and a grey ramp, where no colour has a dim twin,
    // so one of those is left as it is.
    if (cell.flags & term.CELL_FAINT != 0) {
        if (cell.fg == term.COLOR_DEFAULT) fg = palette[7] else if (cell.fg < 16) fg = palette[cell.fg & 7];
    }
    if (cell.flags & term.CELL_REVERSE != 0) {
        const swap = fg;
        fg = bg;
        bg = swap;
    }
    if (cell.flags & term.CELL_CONCEAL != 0) fg = bg;
    return .{ fg, bg };
}

fn sameLook(a: Cell, b: Cell) bool {
    return a.fg == b.fg and a.bg == b.bg and a.flags == b.flags;
}

fn setPens(gb: *GraphicsBase, l: Layout, fg: graphics.Pen, bg: graphics.Pen, cell: Cell) void {
    // Bold is the brighter colour and not the font's bold: that one is a
    // pixel wider per character, and a run would walk out of its cells.
    var style: u32 = 0;
    if (cell.flags & term.CELL_ITALIC != 0) style |= graphics.FSF_ITALIC;
    if (cell.flags & term.CELL_UNDERLINE != 0) style |= graphics.FSF_UNDERLINED;
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = fg },
        .{ .tag = graphics.RPTAG_BPen, .data = bg },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM2 },
        .{ .tag = graphics.RPTAG_TextStyle, .data = style },
        .{},
    };
    gb.SetRPAttrs(l.rp, &tags);
}

fn fillCells(gb: *GraphicsBase, l: Layout, x: i32, y: i32, count: i32, pen: graphics.Pen) void {
    const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = pen }, .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} };
    gb.SetRPAttrs(l.rp, &tags);
    const left = l.origin_x + x * l.cell_width;
    const top = l.origin_y + y * l.cell_height;
    gb.RectFill(l.rp, &.{ .min_x = left, .min_y = top, .max_x = left + count * l.cell_width, .max_y = top + l.cell_height });
}

/// One cell of the line-drawing set, drawn rather than written.
fn drawGraphic(gb: *GraphicsBase, l: Layout, x: i32, y: i32, cell: Cell, fg: graphics.Pen, bg: graphics.Pen) void {
    fillCells(gb, l, x, y, 1, bg);
    const left = l.origin_x + x * l.cell_width;
    const top = l.origin_y + y * l.cell_height;
    const right = left + l.cell_width - 1;
    const bottom = top + l.cell_height - 1;
    const mid_x = left + @divTrunc(l.cell_width - 1, 2);
    const mid_y = top + @divTrunc(l.cell_height - 1, 2);
    const pen = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = fg }, .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} };
    gb.SetRPAttrs(l.rp, &pen);

    // Which half-lines the character is made of: left, right, up, down.
    const parts: [4]bool = switch (cell.ch) {
        'q' => .{ true, true, false, false }, // horizontal
        'x' => .{ false, false, true, true }, // vertical
        'l' => .{ false, true, false, true }, // top left corner
        'k' => .{ true, false, false, true }, // top right
        'm' => .{ false, true, true, false }, // bottom left
        'j' => .{ true, false, true, false }, // bottom right
        't' => .{ false, true, true, true }, // tee right
        'u' => .{ true, false, true, true }, // tee left
        'v' => .{ true, true, true, false }, // tee up
        'w' => .{ true, true, false, true }, // tee down
        'n' => .{ true, true, true, true }, // cross
        else => .{ false, false, false, false },
    };
    if (parts[0]) gb.DrawHLine(l.rp, left, mid_y, mid_x - left + 1);
    if (parts[1]) gb.DrawHLine(l.rp, mid_x, mid_y, right - mid_x + 1);
    if (parts[2]) gb.DrawVLine(l.rp, mid_x, top, mid_y - top + 1);
    if (parts[3]) gb.DrawVLine(l.rp, mid_x, mid_y, bottom - mid_y + 1);
    if (parts[0] or parts[1] or parts[2] or parts[3]) return;

    // The rest: the scan lines, and the few Latin-1 has characters for.
    const scan: ?i32 = switch (cell.ch) {
        'o' => top,
        'p' => top + @divTrunc(l.cell_height, 4),
        'r' => mid_y + @divTrunc(l.cell_height, 4),
        's' => bottom,
        else => null,
    };
    if (scan) |row| {
        gb.DrawHLine(l.rp, left, row, l.cell_width);
        return;
    }
    const near: u32 = switch (cell.ch) {
        'f' => 0xB0, // degree
        'g' => 0xB1, // plus-minus
        '}' => 0xA3, // pound
        '~' => 0xB7, // middle dot
        '`' => 0xB7, // diamond, as near as every font comes
        'a' => 0xB0, // checkerboard
        'y' => '<',
        'z' => '>',
        '{' => 'p', // pi
        '|' => '!', // not equal
        else => ' ',
    };
    var bytes: [4]u8 = undefined;
    setPens(gb, l, fg, bg, cell);
    gb.Move(l.rp, left, top + l.baseline);
    gb.Text(l.rp, &bytes, @intCast(utf8.encode(near, &bytes)));
}

/// Whether the cell at `x` is the first of a wide character whose second
/// cell is still beside it.
fn isWide(t: *const Term, x: u32, y: u32) bool {
    return x + 1 < t.cols and t.at(x, y).ch != term.WIDE_TAIL and t.at(x + 1, y).ch == term.WIDE_TAIL;
}

/// What a cell's character is written as: a control or nothing as a
/// blank.
fn shownChar(cell: Cell) u32 {
    return if (cell.ch < 0x20) ' ' else cell.ch;
}

/// A wide character over its two cells, from the cell at `x`: both cells'
/// background, and the character in the middle of them.
fn drawWide(gb: *GraphicsBase, l: Layout, x: i32, y: i32, cell: Cell, fg: graphics.Pen, bg: graphics.Pen) void {
    fillCells(gb, l, x, y, 2, bg);
    var bytes: [4]u8 = undefined;
    const length: u32 = @intCast(utf8.encode(shownChar(cell), &bytes));
    setPens(gb, l, fg, bg, cell);
    const drawn: i32 = @intCast(gb.TextLength(l.rp, &bytes, length));
    const left = l.origin_x + x * l.cell_width + @divTrunc(@max(2 * l.cell_width - drawn, 0), 2);
    gb.Move(l.rp, left, l.origin_y + y * l.cell_height + l.baseline);
    gb.Text(l.rp, &bytes, length);
}

/// Whether a cell is drawn selected: complemented, as the cursor is
/// (`complement`). A cell selected by half is drawn as it is and given its
/// half afterwards, by `drawHalves`.
fn isShownSelected(t: *const Term, x: u32, y: u32) bool {
    return t.selection(x, y) == .whole;
}

/// The pens a cell is drawn in, selected or not.
fn pensAt(t: *const Term, x: u32, y: u32, l: Layout) struct { graphics.Pen, graphics.Pen } {
    const fg, const bg = pensOf(t.at(x, y).*, l);
    if (!isShownSelected(t, x, y)) return .{ fg, bg };
    return .{ complement(fg, l), complement(bg, l) };
}

/// The left half of each cell from `from` to `to` that the selection
/// covers by half - a row's end - in the colour a selected cell's
/// background takes, its background complemented.
fn drawHalves(gb: *GraphicsBase, l: Layout, t: *const Term, y: u32, from: u32, to: u32) void {
    var x = from;
    while (x < to) : (x += 1) {
        if (t.selection(x, y) != .half) continue;
        _, const plain_bg = pensOf(t.at(x, y).*, l);
        const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = complement(plain_bg, l) }, .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} };
        gb.SetRPAttrs(l.rp, &tags);
        const left = l.origin_x + @as(i32, @intCast(x)) * l.cell_width;
        const top = l.origin_y + @as(i32, @intCast(y)) * l.cell_height;
        const half = l.cell_width - @divTrunc(l.cell_width, 2);
        gb.RectFill(l.rp, &.{ .min_x = left, .min_y = top, .max_x = left + half, .max_y = top + l.cell_height });
    }
}

/// One row of cells, `from` to `to` (both in cells, `to` not included).
/// A wide character whose first cell is the last one asked for is drawn
/// whole.
pub fn drawRow(gb: *GraphicsBase, l: Layout, t: *const Term, y: u32, from: u32, to: u32) void {
    var run_text: [512]u8 = undefined;
    var x = from;
    while (x < to) {
        const first = t.at(x, y).*;
        const selected = isShownSelected(t, x, y);
        if (first.flags & term.CELL_GRAPHIC != 0) {
            const fg, const bg = pensAt(t, x, y, l);
            drawGraphic(gb, l, @intCast(x), @intCast(y), first, fg, bg);
            x += 1;
            continue;
        }
        if (first.ch == term.WIDE_TAIL) {
            // The second half of a wide character drawn with its first,
            // or left alone: blank.
            _, const bg = pensAt(t, x, y, l);
            fillCells(gb, l, @intCast(x), @intCast(y), 1, bg);
            x += 1;
            continue;
        }
        if (isWide(t, x, y)) {
            const fg, const bg = pensAt(t, x, y, l);
            drawWide(gb, l, @intCast(x), @intCast(y), first, fg, bg);
            x += 2;
            continue;
        }
        // As many cells as share their colours and style, up to a wide
        // character.
        var n: u32 = 0;
        var length: usize = 0;
        while (x + n < to and length + 4 <= run_text.len) : (n += 1) {
            const c = t.at(x + n, y).*;
            if (c.flags & term.CELL_GRAPHIC != 0 or !sameLook(first, c)) break;
            if (c.ch == term.WIDE_TAIL or isWide(t, x + n, y)) break;
            if (isShownSelected(t, x + n, y) != selected) break;
            length += utf8.encode(shownChar(c), run_text[length..][0..4]);
        }
        const fg, const bg = pensAt(t, x, y, l);
        setPens(gb, l, fg, bg, first);
        gb.Move(l.rp, l.origin_x + @as(i32, @intCast(x)) * l.cell_width, l.origin_y + @as(i32, @intCast(y)) * l.cell_height + l.baseline);
        gb.Text(l.rp, &run_text, @intCast(length));
        x += n;
    }
    drawHalves(gb, l, t, y, from, to);
}

/// How the cursor is drawn: filled where the window is the active one,
/// an outline where it is not - so a person can see which of several
/// consoles a key would go to, and where the text would land in each -
/// and not at all when it has been taken away.
pub const CursorLook = enum { off, solid, ghost };

/// The cursor's cell: complemented for `solid` (`complement`), outlined
/// for `ghost`, and drawn plainly again for `off`, which is how it comes
/// away.
pub fn drawCursor(gb: *GraphicsBase, l: Layout, t: *const Term, look: CursorLook) void {
    const c = t.cursor();
    if (c.x >= t.cols or c.y >= t.rows) return;
    // On either half of a wide character the cursor is the whole of it.
    const x = if (c.x > 0 and t.at(c.x, c.y).ch == term.WIDE_TAIL and isWide(t, c.x - 1, c.y)) c.x - 1 else c.x;
    const wide = isWide(t, x, c.y);
    const cell = t.at(x, c.y).*;
    const plain_fg, const plain_bg = pensAt(t, x, c.y, l);
    const fg = if (look == .solid) complement(plain_fg, l) else plain_fg;
    const bg = if (look == .solid) complement(plain_bg, l) else plain_bg;
    const px = l.origin_x + @as(i32, @intCast(x)) * l.cell_width;
    const py = l.origin_y + @as(i32, @intCast(c.y)) * l.cell_height;
    if (cell.flags & term.CELL_GRAPHIC != 0) {
        drawGraphic(gb, l, @intCast(x), @intCast(c.y), cell, fg, bg);
    } else if (wide) {
        drawWide(gb, l, @intCast(x), @intCast(c.y), cell, fg, bg);
    } else if (cell.ch == term.WIDE_TAIL) {
        fillCells(gb, l, @intCast(x), @intCast(c.y), 1, bg);
    } else {
        var bytes: [4]u8 = undefined;
        setPens(gb, l, fg, bg, cell);
        gb.Move(l.rp, px, py + l.baseline);
        gb.Text(l.rp, &bytes, @intCast(utf8.encode(shownChar(cell), &bytes)));
    }
    // The outline goes round the cell the character was just drawn in, so
    // the character shows through it.
    if (look == .ghost) {
        const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = fg }, .{} };
        gb.SetRPAttrs(l.rp, &tags);
        // Half-open, so the cell's own pixels and no more.
        const box = graphics.Rect{
            .min_x = px,
            .min_y = py,
            .max_x = px + l.cell_width * @as(i32, if (wide) 2 else 1),
            .max_y = py + l.cell_height,
        };
        gb.DrawRect(l.rp, &box);
    }
}

/// The rows a scroll moved, moved on the window as well: the pixels are
/// copied rather than the text drawn again, which is what makes a console
/// that is scrolling cost one row and not a windowful.
fn blitScroll(gb: *GraphicsBase, l: Layout, t: *Term) void {
    const s = t.takeScroll() orelse return;
    const lines: u32 = @intCast(@abs(s.lines));
    const height = s.bottom - s.top + 1;
    if (lines >= height) return; // nothing of it is left to move
    const width: i32 = @intCast(t.cols * @as(u32, @intCast(l.cell_width)));
    const top: i32 = l.origin_y + @as(i32, @intCast(s.top)) * l.cell_height;
    const moved: i32 = @as(i32, @intCast(lines)) * l.cell_height;
    const area = graphics.Rect{
        .min_x = l.origin_x,
        .min_y = top,
        .max_x = l.origin_x + width,
        .max_y = top + @as(i32, @intCast(height)) * l.cell_height,
    };
    // Not all of it could be moved - the window is covered - so the rows
    // are drawn instead, which is what every row being changed asks for.
    if (!gb.ScrollRaster(l.rp, 0, if (s.lines > 0) moved else -moved, &area)) t.allDirty();
}

/// Every row that has changed, and then no row has.
pub fn drawDirty(gb: *GraphicsBase, l: Layout, t: *Term) void {
    blitScroll(gb, l, t);
    var y: u32 = 0;
    while (y < t.rows) : (y += 1) {
        if (!t.isDirty(y)) continue;
        drawRow(gb, l, t, y, 0, t.cols);
    }
    t.clearDirty();
}

/// All of it but the cursor's cell: after a resize, or when a window that
/// keeps nothing is uncovered. That cell is left to `drawCursor`, which
/// paints it once in the look it keeps; drawn here as well, it would show
/// without the cursor until then, and a window being sized would blink it
/// at every step.
pub fn drawAll(gb: *GraphicsBase, l: Layout, t: *Term) void {
    _ = t.takeScroll();
    const c = t.cursor();
    var y: u32 = 0;
    while (y < t.rows) : (y += 1) {
        if (y == c.y and c.x < t.cols) {
            drawRow(gb, l, t, y, 0, c.x);
            drawRow(gb, l, t, y, c.x + 1, t.cols);
        } else {
            drawRow(gb, l, t, y, 0, t.cols);
        }
    }
    t.clearDirty();
}

/// What is left of the window below and right of the cells, in the
/// background: a window is rarely a whole number of cells.
pub fn drawEdges(gb: *GraphicsBase, l: Layout, t: *const Term, width: i32, height: i32) void {
    const used_w = @as(i32, @intCast(t.cols)) * l.cell_width;
    const used_h = @as(i32, @intCast(t.rows)) * l.cell_height;
    const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = l.bg }, .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} };
    gb.SetRPAttrs(l.rp, &tags);
    if (used_w < width) {
        gb.RectFill(l.rp, &.{ .min_x = l.origin_x + used_w, .min_y = l.origin_y, .max_x = l.origin_x + width, .max_y = l.origin_y + height });
    }
    if (used_h < height) {
        gb.RectFill(l.rp, &.{ .min_x = l.origin_x, .min_y = l.origin_y + used_h, .max_x = l.origin_x + width, .max_y = l.origin_y + height });
    }
}
