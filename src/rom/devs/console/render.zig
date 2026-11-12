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
//! A character the console's font has no glyph of its own for comes from
//! one of the font's fallback fonts, at that font's advance. Where that
//! is not a cell's width the character is no part of a run: its cell is
//! filled with the row's runs, and the character is drawn after them, in
//! the middle of its cell and without a background of its own, so what a
//! wider one has past its cell lies over the cells beside it.
//!
//! A cell that keeps marks (`Cell.marks`) is no part of a run either: its
//! character and the marks go to `Text` as one piece, after the runs and
//! in the middle of the cell, so the marks land where the font's shaping
//! puts them on that character. A font that does not shape draws them as
//! it draws any character, behind the one they belong to.
//!
//! A font that shapes its text (`TextFont.shape`) may draw a run another
//! width than its cells - a pair brought closer, a ligature. Such a run
//! is measured first, and one that is not a cell a character is drawn a
//! cell at a time, each character shaped by itself: the cells are the
//! console's, whatever the font would make of the line.
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

/// Whether a cell can be part of a run: it keeps no marks, and its
/// character is one cell wide in the console's font, as a run takes
/// every one of its characters to be. ASCII is the font's own; a
/// character past it may be a fallback font's glyph, whose advance is
/// that font's.
fn fitsCell(gb: *GraphicsBase, l: Layout, cell: Cell) bool {
    if (cell.marks[0] != 0) return false;
    const ch = shownChar(cell);
    if (ch < 0x80) return true;
    var bytes: [4]u8 = undefined;
    const length: u32 = @intCast(utf8.encode(ch, &bytes));
    return gb.TextLength(l.rp, &bytes, length) == l.cell_width;
}

/// A cell that is no part of a run (`fitsCell`) - its character is not a
/// cell wide, or it keeps marks - in the middle of the cell and without a
/// background: the caller has filled the cell. A wider one reaches into
/// the cells beside it by half of what it is wider.
fn drawOffWidth(gb: *GraphicsBase, l: Layout, x: i32, y: i32, cell: Cell, fg: graphics.Pen, bg: graphics.Pen) void {
    var bytes: [term.cell_text]u8 = undefined;
    const length = shownText(cell, &bytes);
    setPens(gb, l, fg, bg, cell);
    const over = [_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} };
    gb.SetRPAttrs(l.rp, &over);
    const drawn: i32 = @intCast(gb.TextLength(l.rp, &bytes, length));
    gb.Move(l.rp, l.origin_x + x * l.cell_width + @divTrunc(l.cell_width - drawn, 2), l.origin_y + y * l.cell_height + l.baseline);
    gb.Text(l.rp, &bytes, length);
}

/// Whether the console's font, or one it falls back to, shapes its
/// text: a run may then come out another width than its cells.
fn shapesText(gb: *GraphicsBase, l: Layout) bool {
    var font: ?*const graphics.TextFont = null;
    gb.GetRPAttrs(l.rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(&font) }, .{} });
    const one = font orelse return false;
    return one.shapes();
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

/// What a cell is written as, by itself: its character (`shownChar`) and
/// the marks it keeps, in UTF-8. How many bytes.
fn shownText(cell: Cell, into: *[term.cell_text]u8) u32 {
    if (cell.ch < 0x20) {
        into[0] = ' ';
        return 1;
    }
    return @intCast(cell.text(into));
}

/// A wide character over its two cells, from the cell at `x`: both cells'
/// background, and the character in the middle of them.
fn drawWide(gb: *GraphicsBase, l: Layout, x: i32, y: i32, cell: Cell, fg: graphics.Pen, bg: graphics.Pen) void {
    fillCells(gb, l, x, y, 2, bg);
    var bytes: [term.cell_text]u8 = undefined;
    const length = shownText(cell, &bytes);
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
    var off_width = false;
    const shapes = shapesText(gb, l);
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
        if (!fitsCell(gb, l, first)) {
            // Its cell now, the character once the runs are down.
            _, const bg = pensAt(t, x, y, l);
            fillCells(gb, l, @intCast(x), @intCast(y), 1, bg);
            off_width = true;
            x += 1;
            continue;
        }
        // As many cells as share their colours and style, up to a wide
        // character, one that is not a cell wide or one with marks.
        var n: u32 = 0;
        var length: usize = 0;
        while (x + n < to and length + 4 <= run_text.len) : (n += 1) {
            const c = t.at(x + n, y).*;
            if (c.flags & term.CELL_GRAPHIC != 0 or !sameLook(first, c)) break;
            if (c.ch == term.WIDE_TAIL or isWide(t, x + n, y)) break;
            if (isShownSelected(t, x + n, y) != selected) break;
            if (!fitsCell(gb, l, c)) break;
            length += utf8.encode(shownChar(c), run_text[length..][0..4]);
        }
        const fg, const bg = pensAt(t, x, y, l);
        setPens(gb, l, fg, bg, first);
        const line_y = l.origin_y + @as(i32, @intCast(y)) * l.cell_height + l.baseline;
        if (shapes and n > 1 and gb.TextLength(l.rp, &run_text, @intCast(length)) != @as(i32, @intCast(n)) * l.cell_width) {
            // Shaped as one piece the run would leave its cells: a cell
            // at a time, then.
            var at: usize = 0;
            var cell_x = x;
            while (at < length) : (cell_x += 1) {
                const size: usize = utf8.read(run_text[at..length]).length;
                gb.Move(l.rp, l.origin_x + @as(i32, @intCast(cell_x)) * l.cell_width, line_y);
                gb.Text(l.rp, run_text[at..].ptr, @intCast(size));
                at += size;
            }
        } else {
            gb.Move(l.rp, l.origin_x + @as(i32, @intCast(x)) * l.cell_width, line_y);
            gb.Text(l.rp, &run_text, @intCast(length));
        }
        x += n;
    }
    x = from;
    while (off_width and x < to) : (x += 1) {
        const cell = t.at(x, y).*;
        if (cell.flags & term.CELL_GRAPHIC != 0 or cell.ch == term.WIDE_TAIL or isWide(t, x, y)) continue;
        if (fitsCell(gb, l, cell)) continue;
        const fg, const bg = pensAt(t, x, y, l);
        drawOffWidth(gb, l, @intCast(x), @intCast(y), cell, fg, bg);
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
    } else if (!fitsCell(gb, l, cell)) {
        fillCells(gb, l, @intCast(x), @intCast(c.y), 1, bg);
        drawOffWidth(gb, l, @intCast(x), @intCast(c.y), cell, fg, bg);
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

// --- Host tests --------------------------------------------------------------

const std = @import("std");
const testing = std.testing;
const fontimage = graphics.fontimage;
const kexec = @import("../../libs/exec/exec.zig");
const kutility = @import("../../libs/utility/utility.zig");
const krtg = @import("../../libs/rtg/rtg.zig");
const kgraphics = @import("../../libs/graphics/graphics.zig");

/// A glyph of one row of ink, `width` across, `top` rows under the
/// line's top.
fn barGlyph(code: u32, advance: i16, top: i16, width: u16) fontimage.GlyphSpec {
    const ink: []const u8 = if (width > 8) &.{ 0xFF, 0xF0 } else if (width == 8) &.{0xFF} else &.{0xF0};
    return .{ .code = code, .advance = advance, .left = 0, .top = top, .width = width, .rows = 1, .pixels = ink };
}

/// The console's font: 8 rows, every character a cell of 8 across. 'a'
/// is a bar on its third row.
const cell_spec = fontimage.Spec{
    .height = 8,
    .baseline = 6,
    .x_size = 8,
    .default_char = '?',
    .glyphs = &.{ barGlyph('?', 8, 0, 8), barGlyph('a', 8, 2, 8) },
};
const cell_font: [fontimage.imageSize(cell_spec)]u8 align(4) = fontimage.build(cell_spec);

/// Its fallback, of other widths: U+0394 twelve across, a bar on the
/// sixth row, and U+03B9 four across, one on the fifth.
const other_spec = fontimage.Spec{
    .height = 8,
    .baseline = 6,
    .x_size = 8,
    .default_char = '?',
    .glyphs = &.{ barGlyph('?', 8, 0, 8), barGlyph(0x394, 12, 5, 12), barGlyph(0x3B9, 4, 4, 4) },
};
const other_font: [fontimage.imageSize(other_spec)]u8 align(4) = fontimage.build(other_spec);

fn pixelAt(surface: *const sdk.rtg.Surface, x: u32, y: u32) u16 {
    const at = surface.pixels.? + @as(usize, y) * surface.pitch + x * 2;
    return @as(u16, at[0]) | @as(u16, at[1]) << 8;
}

/// How many of a row's pixels from `from` to `to` (not included) are
/// `colour`.
fn countIn(surface: *const sdk.rtg.Surface, y: u32, from: u32, to: u32, colour: u16) u32 {
    var found: u32 = 0;
    var x = from;
    while (x < to) : (x += 1) {
        if (pixelAt(surface, x, y) == colour) found += 1;
    }
    return found;
}

test "a fallback font's character of another width stands in the middle of its cell, over its neighbours" {
    try kexec.setUp();
    defer kexec.deinit();
    _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
    _ = kexec.InitResident(kexec.SysBase, &krtg.rtg_library_tag, null) orelse return error.NoRtg;
    const made = kexec.InitResident(kexec.SysBase, &kgraphics.graphics_library_tag, null) orelse return error.NoGraphics;
    const gb: *GraphicsBase = @ptrCast(@alignCast(made));

    var pixels: [48 * 8 * 2]u8 = @splat(0);
    var surface = sdk.rtg.Surface{ .pixels = &pixels, .width = 48, .height = 8, .pitch = 96, .size_bytes = pixels.len, .format = .rgb565 };
    var other = graphics.TextFont{ .node = .{ .name = "other.font" }, .image = @ptrCast(&other_font) };
    var cells_font = graphics.TextFont{ .node = .{ .name = "cell.font" }, .image = @ptrCast(&cell_font), .fallback = &other };
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(&cells_font) },
        .{},
    };
    const rp = gb.CreateRastPortTagList(&tags) orelse return error.NoRastPort;
    const white: u16 = 0xFFFF;
    const blue: u16 = 0x001F;
    const red: u16 = 0xF800;
    const green: u16 = 0x07E0;
    const layout = Layout{
        .rp = rp,
        .origin_x = 0,
        .origin_y = 0,
        .cell_width = 8,
        .cell_height = 8,
        .baseline = 6,
        .fg = graphics.penRGB(255, 255, 255),
        .bg = graphics.penRGB(0, 0, 255),
        .shine = graphics.penRGB(255, 0, 0),
        .fill = graphics.penRGB(0, 255, 0),
    };

    // Five cells: the font's own letter, the wide one of the fallback,
    // the font's, the narrow one, the font's.
    var cells: [5]Cell = undefined;
    var grid = Term.init(&cells, 5, 1);
    grid.write("a\xCE\x94a\xCE\xB9a");
    drawRow(gb, layout, &grid, 0, 0, 5);

    // Every cell has its background, and nothing is drawn past the row.
    var y: u32 = 0;
    while (y < 8) : (y += 1) {
        try testing.expectEqual(@as(u32, 0), countIn(&surface, y, 0, 40, 0));
        try testing.expectEqual(@as(u32, 8), countIn(&surface, y, 40, 48, 0));
    }
    // The font's own letters are where a run puts them: a cell each,
    // whatever stands between them.
    try testing.expectEqual(@as(u32, 24), countIn(&surface, 2, 0, 40, white));
    try testing.expectEqual(@as(u32, 8), countIn(&surface, 2, 0, 8, white));
    try testing.expectEqual(@as(u32, 8), countIn(&surface, 2, 16, 24, white));
    try testing.expectEqual(@as(u32, 8), countIn(&surface, 2, 32, 40, white));
    // The wide one: twelve across in the middle of the second cell, two
    // of them over each neighbour, whose background is whole around them.
    try testing.expectEqual(@as(u32, 12), countIn(&surface, 5, 0, 40, white));
    try testing.expectEqual(@as(u32, 12), countIn(&surface, 5, 6, 18, white));
    try testing.expectEqual(blue, pixelAt(&surface, 6, 4));
    try testing.expectEqual(blue, pixelAt(&surface, 17, 6));
    // The narrow one: four across in the middle of the fourth.
    try testing.expectEqual(@as(u32, 4), countIn(&surface, 4, 0, 40, white));
    try testing.expectEqual(@as(u32, 4), countIn(&surface, 4, 26, 30, white));

    // The cursor on the wide one: its cell in the cursor's colours, the
    // character still in the middle of it and over the cells beside it.
    grid.x = 1;
    drawCursor(gb, layout, &grid, .solid);
    try testing.expectEqual(@as(u32, 8), countIn(&surface, 0, 8, 16, green));
    try testing.expectEqual(@as(u32, 12), countIn(&surface, 5, 6, 18, red));
    try testing.expectEqual(@as(u32, 0), countIn(&surface, 5, 0, 40, green));
    try testing.expectEqual(blue, pixelAt(&surface, 5, 5));
    try testing.expectEqual(@as(u32, 8), countIn(&surface, 2, 0, 8, white));

    // And taken away again, the row is as it was drawn.
    drawCursor(gb, layout, &grid, .off);
    try testing.expectEqual(@as(u32, 12), countIn(&surface, 5, 6, 18, white));
    try testing.expectEqual(@as(u32, 0), countIn(&surface, 0, 0, 40, green));

    // One cell drawn again on its own - the neighbour of the wide one -
    // takes back what reached into it, and the row drawn again has it.
    drawRow(gb, layout, &grid, 0, 2, 3);
    try testing.expectEqual(@as(u32, 10), countIn(&surface, 5, 0, 40, white));
    drawRow(gb, layout, &grid, 0, 0, 5);
    try testing.expectEqual(@as(u32, 12), countIn(&surface, 5, 6, 18, white));

    gb.FreeRastPort(rp);
}

/// A shaper that brings an `a` two closer to an `a` after it.
fn tightShape(hook: *sdk.utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = hook;
    _ = object;
    const request: *graphics.ShapeRequest = @ptrCast(@alignCast(message.?));
    const text = request.text[0..request.length];
    request.count = @intCast(text.len);
    if (text.len > request.room) return graphics.SHAPE_ROOM;
    for (text, 0..) |char, at| {
        const tight = at + 1 < text.len and text[at + 1] == 'a';
        request.glyphs[at] = .{ .which = char, .cluster = @intCast(at), .advance = if (tight) 6 else 8 };
    }
    return graphics.SHAPE_OK;
}

test "a font that shapes its text: a run that would leave its cells is drawn a cell at a time" {
    try kexec.setUp();
    defer kexec.deinit();
    _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
    _ = kexec.InitResident(kexec.SysBase, &krtg.rtg_library_tag, null) orelse return error.NoRtg;
    const made = kexec.InitResident(kexec.SysBase, &kgraphics.graphics_library_tag, null) orelse return error.NoGraphics;
    const gb: *GraphicsBase = @ptrCast(@alignCast(made));

    var pixels: [32 * 8 * 2]u8 = @splat(0);
    var surface = sdk.rtg.Surface{ .pixels = &pixels, .width = 32, .height = 8, .pitch = 64, .size_bytes = pixels.len, .format = .rgb565 };
    var hook = sdk.utility.Hook{ .entry = &tightShape };
    var cells_font = graphics.TextFont{ .node = .{ .name = "cell.font" }, .image = @ptrCast(&cell_font), .shape = &hook };
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(&cells_font) },
        .{},
    };
    const rp = gb.CreateRastPortTagList(&tags) orelse return error.NoRastPort;
    const white: u16 = 0xFFFF;
    const layout = Layout{
        .rp = rp,
        .origin_x = 0,
        .origin_y = 0,
        .cell_width = 8,
        .cell_height = 8,
        .baseline = 6,
        .fg = graphics.penRGB(255, 255, 255),
        .bg = graphics.penRGB(0, 0, 255),
        .shine = graphics.penRGB(255, 0, 0),
        .fill = graphics.penRGB(0, 255, 0),
    };

    // Three of the letter the shaper brings together: as one piece they
    // are 20 across, and the row has them a cell each all the same.
    var cells: [3]Cell = undefined;
    var grid = Term.init(&cells, 3, 1);
    grid.write("aaa");
    try testing.expectEqual(@as(i32, 20), gb.TextLength(rp, "aaa", 3));
    drawRow(gb, layout, &grid, 0, 0, 3);
    try testing.expectEqual(@as(u32, 24), countIn(&surface, 2, 0, 32, white));
    var y: u32 = 0;
    while (y < 8) : (y += 1) try testing.expectEqual(@as(u32, 8), countIn(&surface, y, 24, 32, 0));

    gb.FreeRastPort(rp);
}

/// The console's font with a mark beside its letter: U+0301, four
/// across on the line's top row, which moves the point nowhere.
const marked_spec = fontimage.Spec{
    .height = 8,
    .baseline = 6,
    .x_size = 8,
    .default_char = '?',
    .glyphs = &.{ barGlyph('?', 8, 0, 8), barGlyph('a', 8, 2, 8), barGlyph(0x301, 0, 0, 4) },
};
const marked_font: [fontimage.imageSize(marked_spec)]u8 align(4) = fontimage.build(marked_spec);

/// A shaper that sets U+0301 over the middle of the letter before it.
fn markShape(hook: *sdk.utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = hook;
    _ = object;
    const request: *graphics.ShapeRequest = @ptrCast(@alignCast(message.?));
    const text = request.text[0..request.length];
    var count: u32 = 0;
    var at: usize = 0;
    var letter_at: usize = 0;
    while (at < text.len) : (count += 1) {
        const found = utf8.read(text[at..]);
        const mark = found.char == 0x301;
        if (!mark) letter_at = at;
        if (count < request.room) request.glyphs[count] = .{
            .which = found.char,
            .cluster = @intCast(letter_at),
            .advance = if (mark) 0 else 8,
            .x = if (mark) -6 else 0,
        };
        at += found.length;
    }
    request.count = count;
    return if (count > request.room) graphics.SHAPE_ROOM else graphics.SHAPE_OK;
}

test "a cell's marks are drawn with its character, where the font's shaping puts them" {
    try kexec.setUp();
    defer kexec.deinit();
    _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
    _ = kexec.InitResident(kexec.SysBase, &krtg.rtg_library_tag, null) orelse return error.NoRtg;
    const made = kexec.InitResident(kexec.SysBase, &kgraphics.graphics_library_tag, null) orelse return error.NoGraphics;
    const gb: *GraphicsBase = @ptrCast(@alignCast(made));

    var pixels: [32 * 8 * 2]u8 = @splat(0);
    var surface = sdk.rtg.Surface{ .pixels = &pixels, .width = 32, .height = 8, .pitch = 64, .size_bytes = pixels.len, .format = .rgb565 };
    var hook = sdk.utility.Hook{ .entry = &markShape };
    var cells_font = graphics.TextFont{ .node = .{ .name = "cell.font" }, .image = @ptrCast(&marked_font), .shape = &hook };
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(&cells_font) },
        .{},
    };
    const rp = gb.CreateRastPortTagList(&tags) orelse return error.NoRastPort;
    const white: u16 = 0xFFFF;
    const blue: u16 = 0x001F;
    const red: u16 = 0xF800;
    const green: u16 = 0x07E0;
    const layout = Layout{
        .rp = rp,
        .origin_x = 0,
        .origin_y = 0,
        .cell_width = 8,
        .cell_height = 8,
        .baseline = 6,
        .fg = graphics.penRGB(255, 255, 255),
        .bg = graphics.penRGB(0, 0, 255),
        .shine = graphics.penRGB(255, 0, 0),
        .fill = graphics.penRGB(0, 255, 0),
    };

    // Three letters, the second with the mark: three cells.
    var cells: [4]Cell = undefined;
    var grid = Term.init(&cells, 4, 1);
    grid.write("aa\xCC\x81a");
    try testing.expectEqual(@as(u32, 3), grid.cursor().x);
    drawRow(gb, layout, &grid, 0, 0, 4);

    // Each letter in its cell, and the mark over the middle of the
    // second and nowhere else.
    try testing.expectEqual(@as(u32, 24), countIn(&surface, 2, 0, 24, white));
    try testing.expectEqual(@as(u32, 4), countIn(&surface, 0, 10, 14, white));
    try testing.expectEqual(@as(u32, 4), countIn(&surface, 0, 0, 32, white));
    try testing.expectEqual(@as(u32, 28), countIn(&surface, 0, 0, 32, blue));

    // Under the cursor the cell is complemented, marks and all.
    grid.write("\x1b[1;2H");
    drawCursor(gb, layout, &grid, .solid);
    try testing.expectEqual(@as(u32, 8), countIn(&surface, 2, 8, 16, red));
    try testing.expectEqual(@as(u32, 4), countIn(&surface, 0, 10, 14, red));
    try testing.expectEqual(@as(u32, 4), countIn(&surface, 0, 8, 16, green));

    gb.FreeRastPort(rp);
}
