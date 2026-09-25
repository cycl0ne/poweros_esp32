// SPDX-License-Identifier: MPL-2.0
//! The terminal: a grid of cells, and the parser that writes into it.
//!
//! Nothing here draws or waits, so the host tests hold all of it: bytes go
//! in with `write`, and what came of them is read out cell by cell. The
//! device renders the cells (`render.zig`) and hands `takeReply` back to
//! whoever is reading the console.
//!
//! It speaks VT100 with the parts of xterm a program expects today, and
//! keeps what the older console had: an 8-bit `0x9B` opens a control
//! sequence exactly as `ESC [` does, tab stops are the console's own, and a
//! line that wrapped swallows the newline that follows it, so a program
//! that fills the last column and then writes a newline does not leave a
//! blank line behind.
//!
//! Characters are Latin-1 - the set the ROM fonts draw. The one exception
//! is the line-drawing set (`ESC ( 0`), which Latin-1 has no characters
//! for: those cells are marked `CELL_GRAPHIC` and the renderer draws the
//! lines and corners itself.

const std = @import("std");

/// A colour is an index: 0-7 the basic ones, 8-15 the bright ones, 16-255
/// the rest of the 256-colour cube. `COLOR_DEFAULT` is the console's own.
pub const COLOR_DEFAULT: u16 = 0x100;

pub const CELL_BOLD: u8 = 1 << 0;
pub const CELL_ITALIC: u8 = 1 << 1;
pub const CELL_UNDERLINE: u8 = 1 << 2;
pub const CELL_REVERSE: u8 = 1 << 3;
pub const CELL_CONCEAL: u8 = 1 << 4;
/// The character is from the line-drawing set: the renderer draws it.
pub const CELL_GRAPHIC: u8 = 1 << 5;

/// The last cell of a row whose line runs on into the next row: it filled
/// up rather than ending. A resize lays the lines out again at the new
/// width, and this is how it tells one line of two rows from two lines.
/// It rides in the cells, so scrolling and clearing carry it along.
pub const CELL_WRAP: u8 = 1 << 6;

/// The secondary colour: the mirror of CELL_BOLD, drawn in the dimmer
/// half of the palette. Bold and faint are the two directions of one
/// choice, so each clears the other and 22 clears both.
pub const CELL_FAINT: u8 = 1 << 7;

pub const Cell = extern struct {
    ch: u8 = ' ',
    flags: u8 = 0,
    fg: u16 = COLOR_DEFAULT,
    bg: u16 = COLOR_DEFAULT,
    /// Something was written here - a character, or a blank a line was
    /// opened up with - and not erased since. A selection is made of these
    /// cells and not of the empty room beside them.
    written: bool = false,
};

/// How much of a cell a selection covers. `half` is the empty cell just
/// after the text of a row, or at the start of an empty row, standing for
/// the row's end: half of it shows, so a line break taken into the
/// selection can be seen without the room after it looking selected.
pub const Selected = enum { no, whole, half };

/// Where the cursor is, and whether it shows.
pub const Cursor = struct { x: u32, y: u32, visible: bool };

const max_params = 16;
const max_rows = 256;
const reply_size = 32;

const State = enum { ground, esc, esc_intermediate, csi_param, csi_intermediate, string };

/// What a program asked for with `CSI ?1049h` and its like.
pub const AltRequest = enum { none, enter, leave };

/// How much of the pointer a program asked to be told about.
/// - `off`: nothing, and the pointer selects text instead.
/// - `buttons` (`CSI ?1000h`): pressed and let go.
/// - `drag` (`?1002h`): those, and moving with a button down.
/// - `any` (`?1003h`): those, and moving with none.
pub const MouseMode = enum { off, buttons, drag, any };

/// Which button a report is about. `release` is what the older form has
/// to send instead of a button, since it cannot say which was let go.
pub const MouseButton = enum(u8) { left = 0, middle = 1, right = 2, release = 3 };

pub const Term = struct {
    /// `rows * cols` cells, the caller's memory.
    cells: [*]Cell,
    cols: u32,
    rows: u32,
    x: u32 = 0,
    y: u32 = 0,
    /// The scrolling region, rows, both inclusive.
    top: u32 = 0,
    bottom: u32 = 0,
    /// What the next character is written with.
    attr: Cell = .{},
    /// DECSC's cursor and attributes.
    saved_x: u32 = 0,
    saved_y: u32 = 0,
    saved_attr: Cell = .{},
    /// The next character would be past the right edge, so it wraps first.
    wrap_pending: bool = false,
    /// A BEL came: the device rings it, and takes it with `takeBell`.
    bell: bool = false,
    autowrap: bool = true,
    insert: bool = false,
    /// LNM: a line feed is a new line - it returns to column 0 as well, and
    /// the return key sends a line feed after its return. On to begin with,
    /// as the older console has it.
    lnm: bool = true,
    cursor_on: bool = true,
    /// DECCKM: the cursor keys send `ESC O A` rather than `ESC [ A`.
    app_cursor: bool = false,
    /// What the program wants told about the pointer, and in which form.
    mouse: MouseMode = .off,
    mouse_sgr: bool = false,
    /// A tab stop per column, up to 256.
    tabs: [256 / 8]u8 = @splat(0),
    /// Which rows have changed since the renderer last looked.
    dirty: [max_rows / 8]u8 = @splat(0),

    /// The line-drawing set is in G0 or G1, and which of the two is in use.
    g0_graphic: bool = false,
    g1_graphic: bool = false,
    shift_out: bool = false,

    state: State = .ground,
    params: [max_params]i32 = @splat(-1),
    param_count: u32 = 0,
    /// A `?`, `>` or `<` before the parameters.
    private: u8 = 0,
    intermediate: u8 = 0,
    /// What the terminal answers with - a cursor position report, a size
    /// report - waiting to be read.
    reply: [reply_size]u8 = @splat(0),
    reply_len: u32 = 0,

    /// What the renderer can do by moving pixels rather than drawing the
    /// rows again: `scroll_lines` rows of `scroll_top`..`scroll_bottom`, up
    /// when positive. The dirty rows have been moved with it, so what is
    /// drawn after the blit lands where it belongs.
    scroll_top: u32 = 0,
    scroll_bottom: u32 = 0,
    scroll_lines: i32 = 0,
    /// The program asked for the other screen, or for its own back.
    alt_request: AltRequest = .none,
    /// It is on the other screen now.
    alternate: bool = false,
    /// The program asked for a window of this many characters.
    want_cols: u32 = 0,
    want_rows: u32 = 0,
    /// What the pointer has selected, as cell numbers, `sel_end` not
    /// included; empty when they are equal.
    sel_start: u32 = 0,
    sel_end: u32 = 0,
    /// Where the output ended when the selection was made (`textEnd`):
    /// nothing from there on is selected.
    sel_limit: u32 = 0,

    /// A terminal over `cells`, which must hold `cols * rows` of them.
    pub fn init(cells: []Cell, cols: u32, rows: u32) Term {
        var t = Term{ .cells = cells.ptr, .cols = cols, .rows = @min(rows, max_rows) };
        t.reset();
        return t;
    }

    /// ESC c: everything as it was when the console opened.
    pub fn reset(t: *Term) void {
        t.x = 0;
        t.y = 0;
        t.top = 0;
        t.bottom = t.rows -| 1;
        t.attr = .{};
        t.saved_x = 0;
        t.saved_y = 0;
        t.saved_attr = .{};
        t.wrap_pending = false;
        t.autowrap = true;
        t.insert = false;
        t.cursor_on = true;
        t.app_cursor = false;
        t.mouse = .off;
        t.mouse_sgr = false;
        t.g0_graphic = false;
        t.g1_graphic = false;
        t.shift_out = false;
        t.state = .ground;
        t.lnm = true;
        t.scroll_lines = 0;
        t.sel_start = 0;
        t.sel_end = 0;
        t.tabs = @splat(0);
        var stop: u32 = 8;
        while (stop < t.cols) : (stop += 8) t.setTab(stop);
        t.clearCells(0, t.rows * t.cols);
        t.allDirty();
    }

    // --- the cells ----------------------------------------------------------

    pub fn at(t: *const Term, x: u32, y: u32) *Cell {
        return &t.cells[y * t.cols + x];
    }

    fn clearCells(t: *Term, from: u32, cells_n: u32) void {
        // Cleared in the colours in force, as a terminal does, so that a
        // program that sets a background and clears gets that background.
        const blank = Cell{ .ch = ' ', .flags = t.attr.flags & CELL_REVERSE, .fg = t.attr.fg, .bg = t.attr.bg };
        for (t.cells[from..][0..cells_n]) |*c| c.* = blank;
    }

    fn markDirty(t: *Term, y: u32) void {
        if (y >= t.rows) return;
        t.dirty[y / 8] |= @as(u8, 1) << @intCast(y % 8);
    }

    fn dirtyRange(t: *Term, from: u32, to: u32) void {
        var y = from;
        while (y <= to and y < t.rows) : (y += 1) t.markDirty(y);
    }

    pub fn allDirty(t: *Term) void {
        t.dirtyRange(0, t.rows -| 1);
    }

    /// Whether a row has changed since `clearDirty`.
    pub fn isDirty(t: *const Term, y: u32) bool {
        return t.dirty[y / 8] & (@as(u8, 1) << @intCast(y % 8)) != 0;
    }

    pub fn clearDirty(t: *Term) void {
        t.dirty = @splat(0);
    }

    pub fn cursor(t: *const Term) Cursor {
        return .{ .x = @min(t.x, t.cols -| 1), .y = t.y, .visible = t.cursor_on };
    }

    /// A new size, with new memory for it: what fits of the old text is
    /// kept, from the top left.
    /// The last row with anything on it, 0 when the grid is empty.
    fn lastRowUsed(t: *const Term) u32 {
        var y = t.rows;
        while (y > 0) {
            y -= 1;
            var x: u32 = 0;
            while (x < t.cols) : (x += 1) {
                const c = t.at(x, y);
                if (c.ch != 0 and c.ch != ' ') return y;
                if (c.bg != COLOR_DEFAULT or c.flags & CELL_REVERSE != 0) return y;
            }
        }
        return 0;
    }

    /// Where the text lands at a given width: how many rows it takes, and
    /// where the cursor ends up. With `into` it writes as well, leaving
    /// out the first `drop` rows - what a grid too short for the text
    /// gives up.
    const Flow = struct { rows: u32 = 0, cursor_row: u32 = 0, cursor_col: u32 = 0 };

    fn flow(t: *const Term, into: ?[]Cell, cols: u32, drop: u32) Flow {
        var out: Flow = .{};
        var out_row: u32 = 0;
        var y: u32 = 0;
        // Empty rows below the last one written are room, not text: the
        // grid ends at whichever is lower down, the last row with anything
        // on it or the row the cursor is on.
        const end = @max(t.lastRowUsed(), t.y) + 1;
        while (y < end) {
            // The line: this row and every row it runs on into.
            var last = y;
            while (last + 1 < end and t.at(t.cols - 1, last).flags & CELL_WRAP != 0) last += 1;
            var len = (last - y + 1) * t.cols;
            // The blanks a line ends in are not part of it.
            while (len > 0) {
                const c = t.cells[y * t.cols + len - 1];
                if (c.ch != 0 and c.ch != ' ') break;
                if (c.bg != COLOR_DEFAULT or c.flags & CELL_REVERSE != 0) break;
                len -= 1;
            }
            const has_cursor = t.y >= y and t.y <= last;
            const cursor_at = if (has_cursor) (t.y - y) * t.cols + t.x else 0;
            // Blanks the cursor stands beyond were written, as a prompt's
            // closing space is: they stay, or what is typed next would
            // land against the text before them.
            if (has_cursor) len = @max(len, cursor_at);

            var out_col: u32 = 0;
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                if (out_col == cols) {
                    if (into) |cells| if (out_row >= drop) {
                        cells[(out_row - drop) * cols + cols - 1].flags |= CELL_WRAP;
                    };
                    out_row += 1;
                    out_col = 0;
                }
                if (has_cursor and i == cursor_at) {
                    out.cursor_row = out_row;
                    out.cursor_col = out_col;
                }
                if (into) |cells| if (out_row >= drop) {
                    const slot = (out_row - drop) * cols + out_col;
                    if (slot < cells.len) cells[slot] = t.cells[y * t.cols + i];
                };
                out_col += 1;
            }
            // A cursor past the end of its line sits where the next
            // character would go.
            if (has_cursor and cursor_at >= len) {
                out.cursor_row = out_row;
                out.cursor_col = @min(out_col, cols - 1);
            }
            out_row += 1;
            y = last + 1;
        }
        out.rows = out_row;
        return out;
    }

    /// A grid of a new size, with the text laid out again to fit it.
    ///
    /// `cells` must not be the grid's own memory: the text is read out of
    /// the old grid while it is written into the new one, and the new one
    /// is cleared first.
    ///
    /// A row that filled up carries `CELL_WRAP`, so the rows of one line
    /// are known; the line is taken as a whole, the blanks it ends in
    /// dropped, and written out again wrapping at the new width. A window
    /// made narrower and wide again therefore reads as it did, which a
    /// grid copied corner to corner cannot manage - the ends of its lines
    /// are gone for good. What does not fit is taken off the **top**: a
    /// terminal's last line is the one being written, so that is the one
    /// to keep.
    pub fn resize(t: *Term, cells: []Cell, cols: u32, rows: u32) void {
        const new_rows = @min(rows, max_rows);
        for (cells) |*c| c.* = .{};
        if (cols == 0 or new_rows == 0) return;

        // What the text needs at the new width, so that what will not fit
        // is known before anything is written.
        const needed = t.flow(null, cols, 0);
        const drop = if (needed.rows > new_rows) needed.rows - new_rows else 0;
        const placed = t.flow(cells, cols, drop);

        t.cells = cells.ptr;
        t.cols = cols;
        t.rows = new_rows;
        t.top = 0;
        t.bottom = new_rows -| 1;
        t.x = @min(placed.cursor_col, cols -| 1);
        t.y = @min(placed.cursor_row -| drop, new_rows -| 1);
        t.wrap_pending = false;
        t.clearSelection();
        t.scroll_lines = 0;
        t.allDirty();
    }

    // --- scrolling ----------------------------------------------------------

    fn scrollUp(t: *Term, lines: u32) void {
        const n = @min(lines, t.bottom - t.top + 1);
        var y = t.top;
        while (y + n <= t.bottom) : (y += 1) {
            const to = t.cells[y * t.cols ..][0..t.cols];
            const from = t.cells[(y + n) * t.cols ..][0..t.cols];
            @memcpy(to, from);
        }
        while (y <= t.bottom) : (y += 1) t.clearCells(y * t.cols, t.cols);
        t.scrolled(@intCast(n));
    }

    fn scrollDown(t: *Term, lines: u32) void {
        const n = @min(lines, t.bottom - t.top + 1);
        var y = t.bottom + 1;
        while (y > t.top + n) {
            y -= 1;
            const to = t.cells[y * t.cols ..][0..t.cols];
            const from = t.cells[(y - n) * t.cols ..][0..t.cols];
            @memcpy(to, from);
        }
        while (y > t.top) {
            y -= 1;
            t.clearCells(y * t.cols, t.cols);
        }
        t.scrolled(-@as(i32, @intCast(n)));
    }

    /// The region moved by `lines`, up when positive: the rows that were
    /// waiting to be drawn move with it, the rows that came in are waiting,
    /// and the renderer is told so it can move the pixels instead of
    /// drawing every row again. A scroll of another region than the one
    /// already recorded gives that up and draws.
    fn scrolled(t: *Term, lines: i32) void {
        const n: u32 = @intCast(@abs(lines));
        // What is selected has moved out from under the selection, so there
        // is nothing sensible left to hold on to.
        t.clearSelection();
        var moved: [max_rows / 8]u8 = @splat(0);
        var y = t.top;
        while (y <= t.bottom) : (y += 1) {
            if (!t.isDirty(y)) continue;
            const to: i32 = @as(i32, @intCast(y)) - lines;
            if (to >= @as(i32, @intCast(t.top)) and to <= @as(i32, @intCast(t.bottom))) {
                const row: u32 = @intCast(to);
                moved[row / 8] |= @as(u8, 1) << @intCast(row % 8);
            }
        }
        y = t.top;
        while (y <= t.bottom) : (y += 1) {
            const bit = @as(u8, 1) << @intCast(y % 8);
            if (moved[y / 8] & bit != 0) t.dirty[y / 8] |= bit else t.dirty[y / 8] &= ~bit;
        }
        // The rows the scroll brought in have nothing on them yet.
        if (lines > 0) t.dirtyRange(t.bottom -| (n - 1), t.bottom) else t.dirtyRange(t.top, t.top + n - 1);

        if (t.scroll_lines != 0 and (t.scroll_top != t.top or t.scroll_bottom != t.bottom)) {
            // Two regions between one drawing: give up and draw the rows.
            t.scroll_lines = 0;
            t.dirtyRange(0, t.rows -| 1);
            return;
        }
        t.scroll_top = t.top;
        t.scroll_bottom = t.bottom;
        t.scroll_lines += lines;
    }

    // --- the other screen ----------------------------------------------------

    /// On to the other screen: `cells` is a grid of the same size, kept by
    /// the device. What was on the first screen stays where it was.
    pub fn enterAlternate(t: *Term, cells: []Cell) void {
        if (t.alternate) return;
        t.alternate = true;
        t.cells = cells.ptr;
        t.x = 0;
        t.y = 0;
        t.top = 0;
        t.bottom = t.rows -| 1;
        t.wrap_pending = false;
        t.clearCells(0, t.rows * t.cols);
        t.clearSelection();
        t.allDirty();
        t.scroll_lines = 0;
    }

    /// Back to the program's own screen: `cells` is the grid it had.
    pub fn leaveAlternate(t: *Term, cells: []Cell) void {
        if (!t.alternate) return;
        t.alternate = false;
        t.cells = cells.ptr;
        t.x = @min(t.saved_x, t.cols -| 1);
        t.y = @min(t.saved_y, t.rows -| 1);
        t.attr = t.saved_attr;
        t.top = 0;
        t.bottom = t.rows -| 1;
        t.wrap_pending = false;
        t.clearSelection();
        t.allDirty();
        t.scroll_lines = 0;
    }

    // --- what the pointer has selected ----------------------------------------

    /// Cells `from` up to `to`, counted across the rows. The rows it
    /// touches are drawn again, selected or not.
    pub fn select(t: *Term, from: u32, to: u32) void {
        const first = @min(from, to);
        const last = @max(from, to);
        const was_first = @min(t.sel_start, t.sel_end);
        const was_last = @max(t.sel_start, t.sel_end);
        t.sel_start = @min(first, t.rows * t.cols);
        t.sel_end = @min(last, t.rows * t.cols);
        t.sel_limit = t.textEnd();
        // Every row either side of the change.
        const low = @min(first, was_first) / t.cols;
        const high = @max(last, was_last) / t.cols;
        t.dirtyRange(low, @min(high, t.rows -| 1));
    }

    pub fn clearSelection(t: *Term) void {
        if (t.sel_start != t.sel_end) t.select(0, 0) else {
            t.sel_start = 0;
            t.sel_end = 0;
        }
    }

    pub fn isSelected(t: *const Term, x: u32, y: u32) bool {
        return t.selection(x, y) != .no;
    }

    /// The cell the output has reached: one past the last written cell,
    /// or the cursor's cell if that is further on. What is beyond it has
    /// never been written, and a selection stops there.
    pub fn textEnd(t: *const Term) u32 {
        var end = t.rows * t.cols;
        while (end > 0 and !t.cells[end - 1].written) end -= 1;
        const cursor_at = t.y * t.cols + @min(t.x, t.cols -| 1);
        return @max(end, cursor_at);
    }

    /// How much of a cell the selection covers. Within the span a written
    /// cell is selected whole. An empty cell is selected only as a row's
    /// end, and then by half: the first one after written text in the
    /// span, or the first of a row. The empty room after that is not
    /// selected, and nothing is from where the output ended (`textEnd`,
    /// as it was when the selection was made): the last line has no end
    /// yet, and the rows below it have never been written.
    pub fn selection(t: *const Term, x: u32, y: u32) Selected {
        if (t.sel_start == t.sel_end or x >= t.cols or y >= t.rows) return .no;
        const cell_at = y * t.cols + x;
        if (cell_at < t.sel_start or cell_at >= t.sel_end or cell_at >= t.sel_limit) return .no;
        if (t.at(x, y).written) return .whole;
        const ends_row = x == 0 or (cell_at > t.sel_start and t.at(x - 1, y).written);
        return if (ends_row) .half else .no;
    }

    /// The selected text, into `buf`: of each row, the written cells in
    /// the span - an empty cell between two of them as a space - and a
    /// newline where the span takes in a row's end, except after a row that
    /// runs on into the next. How many bytes.
    pub fn selectionText(t: *const Term, buf: []u8) usize {
        if (t.sel_start == t.sel_end) return 0;
        var n: usize = 0;
        var y = t.sel_start / t.cols;
        const last_row = (t.sel_end - 1) / t.cols;
        while (y <= last_row and y < t.rows) : (y += 1) {
            const row_start = y * t.cols;
            const from = if (t.sel_start > row_start) t.sel_start - row_start else 0;
            const to = @min(if (t.sel_end < row_start + t.cols) t.sel_end - row_start else t.cols, t.cols);
            var end = to;
            while (end > from and !t.at(end - 1, y).written) end -= 1;
            var x = from;
            while (x < end) : (x += 1) {
                if (n >= buf.len) return n;
                const c = t.at(x, y);
                buf[n] = if (c.written) c.ch else ' ';
                n += 1;
            }
            const breaks = end < t.cols and t.selection(end, y) == .half;
            const runs_on = t.at(t.cols - 1, y).flags & CELL_WRAP != 0;
            if (breaks and !runs_on) {
                if (n >= buf.len) return n;
                buf[n] = '\n';
                n += 1;
            }
        }
        return n;
    }

    /// The scroll the renderer is to make, and it is made only once.
    pub fn takeScroll(t: *Term) ?struct { top: u32, bottom: u32, lines: i32 } {
        if (t.scroll_lines == 0) return null;
        defer t.scroll_lines = 0;
        return .{ .top = t.scroll_top, .bottom = t.scroll_bottom, .lines = t.scroll_lines };
    }

    /// Down one line, scrolling at the bottom of the region.
    fn index(t: *Term) void {
        if (t.y == t.bottom) t.scrollUp(1) else if (t.y + 1 < t.rows) t.y += 1;
    }

    fn reverseIndex(t: *Term) void {
        if (t.y == t.top) t.scrollDown(1) else if (t.y > 0) t.y -= 1;
    }

    /// Down one line and back to the first column: NEL, and what an LF is
    /// in new-line mode.
    fn nextLine(t: *Term) void {
        t.index();
        t.x = 0;
        t.wrap_pending = false;
    }

    // --- tabs ---------------------------------------------------------------

    fn setTab(t: *Term, x: u32) void {
        if (x < 256) t.tabs[x / 8] |= @as(u8, 1) << @intCast(x % 8);
    }

    fn clearTab(t: *Term, x: u32) void {
        if (x < 256) t.tabs[x / 8] &= ~(@as(u8, 1) << @intCast(x % 8));
    }

    fn isTab(t: *const Term, x: u32) bool {
        return x < 256 and t.tabs[x / 8] & (@as(u8, 1) << @intCast(x % 8)) != 0;
    }

    fn tabForward(t: *Term, times: u32) void {
        var n = times;
        while (n > 0) : (n -= 1) {
            var x = t.x + 1;
            while (x < t.cols -| 1 and !t.isTab(x)) x += 1;
            t.x = @min(x, t.cols -| 1);
        }
        t.wrap_pending = false;
    }

    fn tabBack(t: *Term, times: u32) void {
        var n = times;
        while (n > 0) : (n -= 1) {
            var x = t.x;
            while (x > 0) {
                x -= 1;
                if (t.isTab(x)) break;
            }
            t.x = x;
        }
    }

    // --- writing ------------------------------------------------------------

    /// The bytes, parsed and applied.
    pub fn write(t: *Term, bytes: []const u8) void {
        for (bytes) |c| t.byte(c);
    }

    /// As much of `bytes` as can be taken before the screen itself has to
    /// change hands: how many were taken. A program asks for the other
    /// screen and writes on it in one breath, so whoever owns the cells
    /// has to be let in between the two - it is the one that has the
    /// memory. Nothing else stops it, so a caller that answers the
    /// requests each time round gets through the whole of it.
    /// Whether a BEL came since the last time this was asked.
    pub fn takeBell(t: *Term) bool {
        const rang = t.bell;
        t.bell = false;
        return rang;
    }

    pub fn writeSome(t: *Term, bytes: []const u8) usize {
        for (bytes, 0..) |c, i| {
            t.byte(c);
            if (t.alt_request != .none) return i + 1;
        }
        return bytes.len;
    }

    fn byte(t: *Term, c: u8) void {
        // A control character is acted on wherever it arrives, as a
        // terminal does - except inside a string, which swallows all it is
        // given until its end.
        if (t.state != .string and c < 0x20) {
            t.control(c);
            return;
        }
        switch (t.state) {
            .ground => t.ground(c),
            .esc => t.escByte(c),
            .esc_intermediate => t.escIntermediate(c),
            .csi_param => t.csiParam(c),
            .csi_intermediate => t.csiIntermediate(c),
            .string => {
                // OSC, DCS and the rest: swallowed to ST (ESC \) or BEL.
                if (c == 0x07) t.state = .ground;
                if (c == 0x1B) t.state = .esc;
            },
        }
    }

    fn control(t: *Term, c: u8) void {
        switch (c) {
            0x07 => t.bell = true, // the device rings it
            0x08 => {
                if (t.x > 0) t.x -= 1;
                t.wrap_pending = false;
            },
            0x09 => t.tabForward(1),
            0x0A, 0x0B, 0x0C => {
                // A line that wrapped has had its newline already.
                if (t.wrap_pending) {
                    t.wrap_pending = false;
                } else {
                    t.index();
                    if (t.lnm and c == 0x0A) t.x = 0;
                }
            },
            0x0D => {
                t.x = 0;
                t.wrap_pending = false;
            },
            0x0E => t.shift_out = true,
            0x0F => t.shift_out = false,
            0x1B => {
                t.state = .esc;
                t.intermediate = 0;
            },
            else => {},
        }
    }

    fn ground(t: *Term, c: u8) void {
        // The 8-bit C1 controls. Five of the thirty-two mean something:
        // the four `ESC D/E/H/M` also reach, and CSI.
        switch (c) {
            0x84 => t.index(), // IND
            0x85 => t.nextLine(), // NEL
            0x88 => t.setTab(t.x), // HTS
            0x8D => t.reverseIndex(), // RI
            0x9B => t.startCsi(), // CSI
            0x80...0x83, 0x86...0x87, 0x89...0x8C, 0x8E...0x9A, 0x9C...0x9F => {},
            else => t.put(c),
        }
    }

    fn put(t: *Term, c: u8) void {
        if (t.wrap_pending and t.autowrap) {
            // The row filled up and there is more: it is one line with the
            // row the text goes on in.
            t.at(t.cols - 1, t.y).flags |= CELL_WRAP;
            t.x = 0;
            t.index();
            t.wrap_pending = false;
        }
        if (t.x >= t.cols or t.y >= t.rows) return;
        // What is selected is the text that was there, so a character
        // written over any of it ends the selection rather than leaving
        // the mark on whatever arrives next.
        const here = t.y * t.cols + t.x;
        if (here >= t.sel_start and here < t.sel_end) t.clearSelection();
        if (t.insert) {
            // The rest of the line moves right, and the last cell goes.
            var x = t.cols - 1;
            while (x > t.x) : (x -= 1) t.at(x, t.y).* = t.at(x - 1, t.y).*;
        }
        const graphic = if (t.shift_out) t.g1_graphic else t.g0_graphic;
        const cell = t.at(t.x, t.y);
        cell.* = t.attr;
        cell.ch = c;
        cell.written = true;
        // The line-drawing set is 0x60-0x7E; anything else is itself.
        if (graphic and c >= 0x60 and c <= 0x7E) cell.flags |= CELL_GRAPHIC;
        t.markDirty(t.y);
        if (t.x + 1 >= t.cols) t.wrap_pending = true else t.x += 1;
    }

    // --- escape sequences ----------------------------------------------------

    fn escByte(t: *Term, c: u8) void {
        switch (c) {
            0x20...0x2F => {
                t.intermediate = c;
                t.state = .esc_intermediate;
            },
            '[' => t.startCsi(),
            'P', ']', '^', '_' => t.state = .string, // DCS, OSC, PM, APC
            'D' => {
                t.index();
                t.state = .ground;
            },
            'E' => {
                t.nextLine();
                t.state = .ground;
            },
            'H' => {
                t.setTab(t.x);
                t.state = .ground;
            },
            'M' => {
                t.reverseIndex();
                t.state = .ground;
            },
            'c' => t.reset(),
            '7' => {
                t.saved_x = t.x;
                t.saved_y = t.y;
                t.saved_attr = t.attr;
                t.state = .ground;
            },
            '8' => {
                t.x = @min(t.saved_x, t.cols -| 1);
                t.y = @min(t.saved_y, t.rows -| 1);
                t.attr = t.saved_attr;
                t.wrap_pending = false;
                t.state = .ground;
            },
            '\\' => t.state = .ground, // ST, the end of a string
            else => t.state = .ground,
        }
    }

    fn escIntermediate(t: *Term, c: u8) void {
        // `ESC ( x` and `ESC ) x`: which set G0 and G1 are.
        if (t.intermediate == '(' or t.intermediate == ')') {
            const graphic = c == '0';
            if (t.intermediate == '(') t.g0_graphic = graphic else t.g1_graphic = graphic;
        }
        t.state = .ground;
    }

    fn startCsi(t: *Term) void {
        t.state = .csi_param;
        t.params = @splat(-1);
        t.param_count = 0;
        t.private = 0;
        t.intermediate = 0;
    }

    fn csiParam(t: *Term, c: u8) void {
        switch (c) {
            '0'...'9' => {
                if (t.param_count == 0) t.param_count = 1;
                const p = &t.params[t.param_count - 1];
                if (p.* < 0) p.* = 0;
                p.* = @min(p.* *| 10 +| (c - '0'), 65535);
            },
            ';' => {
                if (t.param_count == 0) t.param_count = 1;
                if (t.param_count < max_params) t.param_count += 1;
            },
            '<', '=', '>', '?' => t.private = c,
            0x20...0x2F => {
                t.intermediate = c;
                t.state = .csi_intermediate;
            },
            0x40...0x7E => {
                t.state = .ground;
                t.csi(c);
            },
            else => t.state = .ground,
        }
    }

    fn csiIntermediate(t: *Term, c: u8) void {
        switch (c) {
            0x20...0x2F => t.intermediate = c,
            0x40...0x7E => {
                t.state = .ground;
                t.csi(c);
            },
            else => t.state = .ground,
        }
    }

    /// Parameter `n`, or `default` when it was left out.
    fn param(t: *const Term, n: u32, default: i32) i32 {
        if (n >= t.param_count) return default;
        const p = t.params[n];
        return if (p < 0) default else p;
    }

    /// Parameter `n` as a count, at least 1.
    fn count(t: *const Term, n: u32) u32 {
        return @intCast(@max(t.param(n, 1), 1));
    }

    fn csi(t: *Term, final: u8) void {
        if (t.private == '?') {
            switch (final) {
                'h', 'l' => t.privateMode(final == 'h'),
                else => {},
            }
            return;
        }
        // A private prefix this terminal does not know makes the whole
        // sequence nothing. Letting one through would run it as though it
        // had no prefix, and the two mean different things: the older
        // console's global background is `CSI >0m`, which unprefixed is
        // SGR 0 and would throw every attribute away.
        if (t.private != 0) return;
        if (t.intermediate != 0) return; // no sequence here takes one
        switch (final) {
            '@' => t.insertChars(t.count(0)),
            'A' => t.up(t.count(0)),
            'B' => t.down(t.count(0)),
            'C' => t.right(t.count(0)),
            'D' => t.left(t.count(0)),
            'E' => {
                t.down(t.count(0));
                t.x = 0;
            },
            'F' => {
                t.up(t.count(0));
                t.x = 0;
            },
            'G', '`' => t.moveTo(@intCast(@max(t.param(0, 1), 1) - 1), t.y),
            'H', 'f' => t.moveTo(@intCast(@max(t.param(1, 1), 1) - 1), @intCast(@max(t.param(0, 1), 1) - 1)),
            'I' => t.tabForward(t.count(0)),
            'J' => t.eraseDisplay(t.param(0, 0)),
            'K' => t.eraseLine(t.param(0, 0)),
            'L' => t.insertLines(t.count(0)),
            'M' => t.deleteLines(t.count(0)),
            'P' => t.deleteChars(t.count(0)),
            'S' => t.scrollUp(t.count(0)),
            'T' => t.scrollDown(t.count(0)),
            'X' => t.eraseChars(t.count(0)),
            'W' => t.ctc(),
            'Z' => t.tabBack(t.count(0)),
            'b' => t.repeat(t.count(0)),
            'd' => t.moveTo(t.x, @intCast(@max(t.param(0, 1), 1) - 1)),
            'g' => switch (t.param(0, 0)) {
                3 => t.tabs = @splat(0),
                else => t.clearTab(t.x),
            },
            'h', 'l' => t.mode(final == 'h'),
            'm' => t.sgr(),
            'n' => if (t.param(0, 0) == 6) t.reportCursor(),
            'r' => t.setRegion(),
            's' => {
                t.saved_x = t.x;
                t.saved_y = t.y;
                t.saved_attr = t.attr;
            },
            't' => switch (t.param(0, 0)) {
                8 => {
                    // The program asks for a window of this many
                    // characters; the device sizes the window.
                    t.want_rows = @intCast(@max(t.param(1, 0), 0));
                    t.want_cols = @intCast(@max(t.param(2, 0), 0));
                },
                18 => t.reportSize(),
                else => {},
            },
            'u' => {
                t.x = @min(t.saved_x, t.cols -| 1);
                t.y = @min(t.saved_y, t.rows -| 1);
                t.attr = t.saved_attr;
            },
            else => {},
        }
    }

    // --- what the sequences do ------------------------------------------------

    fn moveTo(t: *Term, x: u32, y: u32) void {
        t.x = @min(x, t.cols -| 1);
        t.y = @min(y, t.rows -| 1);
        t.wrap_pending = false;
    }

    fn up(t: *Term, n: u32) void {
        // Stopped by the top of the region when the cursor is inside it.
        const limit = if (t.y >= t.top) t.top else 0;
        t.y = if (t.y -| n < limit) limit else t.y - n;
        t.wrap_pending = false;
    }

    fn down(t: *Term, n: u32) void {
        const limit = if (t.y <= t.bottom) t.bottom else t.rows -| 1;
        t.y = @min(t.y + n, limit);
        t.wrap_pending = false;
    }

    fn left(t: *Term, n: u32) void {
        t.x -|= n;
        t.wrap_pending = false;
    }

    fn right(t: *Term, n: u32) void {
        t.x = @min(t.x + n, t.cols -| 1);
        t.wrap_pending = false;
    }

    fn eraseDisplay(t: *Term, how: i32) void {
        switch (how) {
            1 => {
                t.clearCells(0, t.y * t.cols + t.x + 1);
                t.dirtyRange(0, t.y);
            },
            2, 3 => {
                t.clearCells(0, t.rows * t.cols);
                t.allDirty();
            },
            else => {
                const from = t.y * t.cols + t.x;
                t.clearCells(from, t.rows * t.cols - from);
                t.dirtyRange(t.y, t.rows -| 1);
            },
        }
        t.wrap_pending = false;
    }

    fn eraseLine(t: *Term, how: i32) void {
        const row = t.y * t.cols;
        switch (how) {
            1 => t.clearCells(row, @min(t.x + 1, t.cols)),
            2 => t.clearCells(row, t.cols),
            else => t.clearCells(row + t.x, t.cols - t.x),
        }
        t.markDirty(t.y);
        t.wrap_pending = false;
    }

    fn eraseChars(t: *Term, n: u32) void {
        const room = t.cols - t.x;
        t.clearCells(t.y * t.cols + t.x, @min(n, room));
        t.markDirty(t.y);
    }

    fn insertChars(t: *Term, n: u32) void {
        const move = @min(n, t.cols - t.x);
        var x = t.cols;
        while (x > t.x + move) {
            x -= 1;
            t.at(x, t.y).* = t.at(x - move, t.y).*;
        }
        t.clearCells(t.y * t.cols + t.x, move);
        // The blanks a line is opened up with belong to it.
        for (t.cells[t.y * t.cols + t.x ..][0..move]) |*c| c.written = true;
        t.markDirty(t.y);
    }

    fn deleteChars(t: *Term, n: u32) void {
        const move = @min(n, t.cols - t.x);
        var x = t.x;
        while (x + move < t.cols) : (x += 1) t.at(x, t.y).* = t.at(x + move, t.y).*;
        t.clearCells(t.y * t.cols + t.cols - move, move);
        t.markDirty(t.y);
    }

    fn insertLines(t: *Term, n: u32) void {
        if (t.y < t.top or t.y > t.bottom) return;
        // Within the region, from the cursor's line down.
        const was_top = t.top;
        t.top = t.y;
        t.scrollDown(n);
        t.top = was_top;
    }

    fn deleteLines(t: *Term, n: u32) void {
        if (t.y < t.top or t.y > t.bottom) return;
        const was_top = t.top;
        t.top = t.y;
        t.scrollUp(n);
        t.top = was_top;
    }

    fn repeat(t: *Term, n: u32) void {
        if (t.x == 0 and !t.wrap_pending) return;
        const last = if (t.wrap_pending) t.at(t.cols - 1, t.y).* else t.at(t.x - 1, t.y).*;
        var i: u32 = 0;
        while (i < n) : (i += 1) t.put(last.ch);
    }

    fn setRegion(t: *Term) void {
        const first: u32 = @intCast(@max(t.param(0, 1), 1) - 1);
        const last: u32 = @intCast(@max(t.param(1, @intCast(t.rows)), 1) - 1);
        if (first >= last or last >= t.rows) {
            t.top = 0;
            t.bottom = t.rows -| 1;
        } else {
            t.top = first;
            t.bottom = last;
        }
        // DECSTBM puts the cursor home.
        t.x = 0;
        t.y = t.top;
        t.wrap_pending = false;
    }

    /// CTC, cursor tabulation control: every parameter in turn says what
    /// to do with the tab stops at the cursor. 4 clears them all as 5 does
    /// - the older console takes both.
    fn ctc(t: *Term) void {
        var i: u32 = 0;
        while (i < @max(t.param_count, 1)) : (i += 1) {
            switch (t.param(i, 0)) {
                0 => t.setTab(t.x),
                2 => t.clearTab(t.x),
                4, 5 => t.tabs = @splat(0),
                else => {},
            }
        }
    }

    fn mode(t: *Term, set: bool) void {
        var i: u32 = 0;
        while (i < @max(t.param_count, 1)) : (i += 1) {
            switch (t.param(i, 0)) {
                4 => t.insert = set,
                20 => t.lnm = set,
                else => {},
            }
        }
    }

    fn privateMode(t: *Term, set: bool) void {
        var i: u32 = 0;
        while (i < @max(t.param_count, 1)) : (i += 1) {
            switch (t.param(i, 0)) {
                1 => t.app_cursor = set,
                7 => t.autowrap = set,
                25 => t.cursor_on = set,
                1000 => t.mouse = if (set) .buttons else .off,
                1002 => t.mouse = if (set) .drag else .off,
                1003 => t.mouse = if (set) .any else .off,
                1006 => t.mouse_sgr = set,
                47, 1047 => t.alt_request = if (set) .enter else .leave,
                1048 => if (set) {
                    t.saved_x = t.x;
                    t.saved_y = t.y;
                    t.saved_attr = t.attr;
                } else {
                    t.x = @min(t.saved_x, t.cols -| 1);
                    t.y = @min(t.saved_y, t.rows -| 1);
                    t.attr = t.saved_attr;
                },
                1049 => {
                    if (set) {
                        t.saved_x = t.x;
                        t.saved_y = t.y;
                        t.saved_attr = t.attr;
                    }
                    t.alt_request = if (set) .enter else .leave;
                },
                else => {},
            }
        }
    }

    fn sgr(t: *Term) void {
        if (t.param_count == 0) {
            t.attr = .{};
            return;
        }
        var i: u32 = 0;
        while (i < t.param_count) : (i += 1) {
            const p = t.param(i, 0);
            switch (p) {
                0 => t.attr = .{},
                1 => t.attr.flags = t.attr.flags & ~CELL_FAINT | CELL_BOLD,
                2 => t.attr.flags = t.attr.flags & ~CELL_BOLD | CELL_FAINT,
                3 => t.attr.flags |= CELL_ITALIC,
                4 => t.attr.flags |= CELL_UNDERLINE,
                7 => t.attr.flags |= CELL_REVERSE,
                8 => t.attr.flags |= CELL_CONCEAL,
                22 => t.attr.flags &= ~(CELL_BOLD | CELL_FAINT),
                23 => t.attr.flags &= ~CELL_ITALIC,
                24 => t.attr.flags &= ~CELL_UNDERLINE,
                27 => t.attr.flags &= ~CELL_REVERSE,
                28 => t.attr.flags &= ~CELL_CONCEAL,
                30...37 => t.attr.fg = @intCast(p - 30),
                39 => t.attr.fg = COLOR_DEFAULT,
                40...47 => t.attr.bg = @intCast(p - 40),
                49 => t.attr.bg = COLOR_DEFAULT,
                90...97 => t.attr.fg = @intCast(p - 90 + 8),
                100...107 => t.attr.bg = @intCast(p - 100 + 8),
                38, 48 => {
                    // 38;5;n and 48;5;n: one of the 256 colours.
                    if (t.param(i + 1, 0) == 5) {
                        const c: u16 = @intCast(@max(t.param(i + 2, 0), 0) & 0xFF);
                        if (p == 38) t.attr.fg = c else t.attr.bg = c;
                        i += 2;
                    }
                },
                else => {},
            }
        }
    }

    // --- what it answers -------------------------------------------------------

    fn say(t: *Term, comptime fmt: []const u8, args: anytype) void {
        var buf: [reply_size]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        if (t.reply_len + text.len > t.reply.len) return;
        @memcpy(t.reply[t.reply_len..][0..text.len], text);
        t.reply_len += @intCast(text.len);
    }

    fn reportCursor(t: *Term) void {
        t.say("\x1b[{d};{d}R", .{ t.y + 1, @min(t.x, t.cols -| 1) + 1 });
    }

    fn reportSize(t: *Term) void {
        t.say("\x1b[8;{d};{d}t", .{ t.rows, t.cols });
    }

    /// Whether this pointer event is one the program asked to hear about:
    /// a press or a release always, a move only in the modes that want
    /// moves, and nothing at all when reporting is off.
    pub fn wantsMouse(t: *const Term, moving: bool, button_down: bool) bool {
        return switch (t.mouse) {
            .off => false,
            .buttons => !moving,
            .drag => !moving or button_down,
            .any => true,
        };
    }

    /// A pointer event to the program, at cell `x`, `y` counted from zero.
    /// `SHIFT`, `CTRL` and `ALT` ride in the button byte as xterm has them
    /// (4, 16 and 8), and a move sets 32.
    pub fn reportMouse(
        t: *Term,
        button: MouseButton,
        x: u32,
        y: u32,
        moving: bool,
        release: bool,
        shift: bool,
        ctrl: bool,
        alt: bool,
    ) void {
        var b: u32 = @intFromEnum(button);
        if (moving) b |= 32;
        if (shift) b |= 4;
        if (alt) b |= 8;
        if (ctrl) b |= 16;
        const col = @min(x, t.cols -| 1) + 1;
        const row = @min(y, t.rows -| 1) + 1;
        if (t.mouse_sgr) {
            // The SGR form says which button was let go, and has no limit
            // at column 223 the way the older one does.
            t.say("\x1b[<{d};{d};{d}{c}", .{ b, col, row, @as(u8, if (release) 'm' else 'M') });
            return;
        }
        // The older form adds 32 to each, so a coordinate past 223 cannot
        // be said at all - those are left out rather than sent wrong.
        if (col > 223 or row > 223) return;
        const legacy: u32 = if (release) @intFromEnum(MouseButton.release) | (b & ~@as(u32, 3)) else b;
        t.say("\x1b[M{c}{c}{c}", .{
            @as(u8, @intCast(32 + (legacy & 0xFF))),
            @as(u8, @intCast(32 + col)),
            @as(u8, @intCast(32 + row)),
        });
    }

    /// What the terminal has to say, into `buf`; how many bytes, and they
    /// are not said twice.
    pub fn takeReply(t: *Term, buf: []u8) usize {
        const n = @min(buf.len, t.reply_len);
        @memcpy(buf[0..n], t.reply[0..n]);
        const rest = t.reply_len - n;
        for (0..rest) |i| t.reply[i] = t.reply[n + i];
        t.reply_len = @intCast(rest);
        return n;
    }
};

// --- tests --------------------------------------------------------------------------

const testing = std.testing;

fn scratch(cols: u32, rows: u32) struct { Term, []Cell } {
    const cells = testing.allocator.alloc(Cell, cols * rows) catch unreachable;
    return .{ Term.init(cells, cols, rows), cells };
}

/// A row as text, spaces and all.
fn rowText(t: *const Term, y: u32, buf: []u8) []const u8 {
    for (0..t.cols) |x| buf[x] = t.at(@intCast(x), y).ch;
    return buf[0..t.cols];
}

test "writing, wrapping, and the newline a wrapped line swallows" {
    var t, const cells = scratch(8, 4);
    defer testing.allocator.free(cells);
    var buf: [8]u8 = undefined;

    t.write("hello");
    try testing.expectEqualStrings("hello   ", rowText(&t, 0, &buf));
    try testing.expectEqual(@as(u32, 5), t.cursor().x);

    // Filling the last column leaves the wrap for the next character.
    t.write("\r\nabcdefgh");
    try testing.expectEqualStrings("abcdefgh", rowText(&t, 1, &buf));
    try testing.expectEqual(@as(u32, 1), t.cursor().y);
    t.write("i");
    try testing.expectEqual(@as(u32, 2), t.cursor().y);
    try testing.expectEqualStrings("i       ", rowText(&t, 2, &buf));

    // A newline right after the wrap is the one the wrap already made.
    t.write("\r\njklmnopq\n");
    try testing.expectEqual(@as(u32, 3), t.cursor().y);

    // Without autowrap the last column is written over.
    t.write("\x1b[?7l\x1b[1;1Habcdefghij");
    try testing.expectEqualStrings("abcdefgj", rowText(&t, 0, &buf));
}

test "moving, erasing and the 8-bit CSI" {
    var t, const cells = scratch(10, 4);
    defer testing.allocator.free(cells);
    var buf: [10]u8 = undefined;

    t.write("\x1b[2;3Hhere");
    try testing.expectEqualStrings("  here    ", rowText(&t, 1, &buf));
    // The same sequence with the one-byte CSI.
    t.write("\x9b3;1Hthere");
    try testing.expectEqualStrings("there     ", rowText(&t, 2, &buf));

    // Erase to the end of the line, to its start, and all of it.
    t.write("\x1b[2;5H\x1b[K");
    try testing.expectEqualStrings("  he      ", rowText(&t, 1, &buf));
    t.write("\x1b[3;3H\x1b[1K");
    try testing.expectEqualStrings("   re     ", rowText(&t, 2, &buf));
    t.write("\x1b[2K");
    try testing.expectEqualStrings("          ", rowText(&t, 2, &buf));

    // Cursor position report, and the size.
    t.write("\x1b[2;4H\x1b[6n");
    var reply: [16]u8 = undefined;
    try testing.expectEqualStrings("\x1b[2;4R", reply[0..t.takeReply(&reply)]);
    t.write("\x1b[18t");
    try testing.expectEqualStrings("\x1b[8;4;10t", reply[0..t.takeReply(&reply)]);

    // Clear the display, and the cursor's column with CHA, row with VPA.
    t.write("\x1b[2J\x1b[5G\x1b[3d");
    try testing.expectEqual(@as(u32, 4), t.cursor().x);
    try testing.expectEqual(@as(u32, 2), t.cursor().y);
    try testing.expectEqualStrings("          ", rowText(&t, 1, &buf));
}

test "the scrolling region, insert and delete" {
    var t, const cells = scratch(5, 6);
    defer testing.allocator.free(cells);
    var buf: [5]u8 = undefined;

    t.write("one\r\ntwo\r\nsix\r\nfor\r\nfiv\r\nsix");
    // Rows 2 to 4 scroll; everything outside them stays.
    t.write("\x1b[2;4r\x1b[4;1Hlast\n");
    try testing.expectEqualStrings("one  ", rowText(&t, 0, &buf));
    try testing.expectEqualStrings("six  ", rowText(&t, 1, &buf));
    try testing.expectEqualStrings("last ", rowText(&t, 2, &buf));
    try testing.expectEqualStrings("     ", rowText(&t, 3, &buf));
    try testing.expectEqualStrings("fiv  ", rowText(&t, 4, &buf));

    // Reverse index at the top of the region scrolls it the other way.
    t.write("\x1b[2;1H\x1bM");
    try testing.expectEqualStrings("     ", rowText(&t, 1, &buf));
    try testing.expectEqualStrings("six  ", rowText(&t, 2, &buf));
    try testing.expectEqualStrings("last ", rowText(&t, 3, &buf));

    // Insert a line at the cursor, then take it away again.
    t.write("\x1b[3;1H\x1b[L");
    try testing.expectEqualStrings("     ", rowText(&t, 2, &buf));
    try testing.expectEqualStrings("six  ", rowText(&t, 3, &buf));
    t.write("\x1b[M");
    try testing.expectEqualStrings("six  ", rowText(&t, 2, &buf));

    // Characters: inserted, deleted, erased.
    t.write("\x1b[1;1Habcd\x1b[1;2H\x1b[@");
    try testing.expectEqualStrings("a bcd", rowText(&t, 0, &buf));
    t.write("\x1b[P");
    try testing.expectEqualStrings("abcd ", rowText(&t, 0, &buf));
    t.write("\x1b[2X");
    try testing.expectEqualStrings("a  d ", rowText(&t, 0, &buf));

    // The region given up puts the cursor home and reaches every row.
    t.write("\x1b[r");
    try testing.expectEqual(@as(u32, 0), t.cursor().y);
    try testing.expectEqual(@as(u32, 5), t.bottom);
}

test "tabs, repeat, insert mode, save and restore" {
    var t, const cells = scratch(24, 2);
    defer testing.allocator.free(cells);
    var buf: [24]u8 = undefined;

    // Every eight columns to start with.
    t.write("a\tb\tc");
    try testing.expectEqualStrings("a       b       c       ", rowText(&t, 0, &buf));
    // A stop of its own, and one cleared.
    t.write("\r\x1b[4G\x1bH\x1b[1G\ta");
    try testing.expectEqual(@as(u32, 4), t.cursor().x);
    t.write("\x1b[4G\x1b[g\x1b[1G\t");
    try testing.expectEqual(@as(u32, 8), t.cursor().x);
    // Back a tab.
    t.write("\x1b[Z");
    try testing.expectEqual(@as(u32, 0), t.cursor().x);

    // REP repeats the last character; insert mode pushes the rest along.
    t.write("\x1b[2;1Hx\x1b[3b");
    try testing.expectEqualStrings("xxxx", rowText(&t, 1, &buf)[0..4]);
    t.write("\x1b[2;2H\x1b[4h-\x1b[4l");
    try testing.expectEqualStrings("x-xxx", rowText(&t, 1, &buf)[0..5]);

    // The cursor and its attributes, put away and fetched back.
    t.write("\x1b[2;7H\x1b[1m\x1b7\x1b[1;1H\x1b[m\x1b8");
    try testing.expectEqual(@as(u32, 6), t.cursor().x);
    try testing.expectEqual(@as(u32, 1), t.cursor().y);
    try testing.expectEqual(CELL_BOLD, t.attr.flags & CELL_BOLD);
}

test "colours, attributes and the line-drawing set" {
    var t, const cells = scratch(8, 2);
    defer testing.allocator.free(cells);

    t.write("\x1b[31;44mA\x1b[1;4mB\x1b[m C");
    try testing.expectEqual(@as(u16, 1), t.at(0, 0).fg);
    try testing.expectEqual(@as(u16, 4), t.at(0, 0).bg);
    try testing.expectEqual(@as(u8, 0), t.at(0, 0).flags);
    try testing.expectEqual(CELL_BOLD | CELL_UNDERLINE, t.at(1, 0).flags);
    try testing.expectEqual(COLOR_DEFAULT, t.at(3, 0).fg);

    // Bright, and one of the 256.
    t.write("\r\x1b[92mD\x1b[38;5;200mE");
    try testing.expectEqual(@as(u16, 10), t.at(0, 0).fg);
    try testing.expectEqual(@as(u16, 200), t.at(1, 0).fg);

    // ESC ( 0 makes the letters box-drawing characters, ESC ( B gives them
    // back; the renderer draws those cells itself.
    t.write("\x1b[2;1H\x1b(0lqk\x1b(Bx");
    try testing.expectEqual(CELL_GRAPHIC, t.at(0, 1).flags & CELL_GRAPHIC);
    try testing.expectEqual(@as(u8, 'q'), t.at(1, 1).ch);
    try testing.expectEqual(@as(u8, 0), t.at(3, 1).flags & CELL_GRAPHIC);
}

test "a string is swallowed, and a reset puts everything back" {
    var t, const cells = scratch(8, 2);
    defer testing.allocator.free(cells);
    var buf: [8]u8 = undefined;

    // An OSC title runs to its terminator and prints nothing.
    t.write("\x1b]0;a title\x07done");
    try testing.expectEqualStrings("done    ", rowText(&t, 0, &buf));
    t.write("\x1b]2;another\x1b\\!");
    try testing.expectEqualStrings("done!   ", rowText(&t, 0, &buf));

    t.write("\x1b[31m\x1b[?25l\x1b[2;3H\x1bc");
    try testing.expectEqual(@as(u32, 0), t.cursor().x);
    try testing.expectEqual(@as(u32, 0), t.cursor().y);
    try testing.expect(t.cursor().visible);
    try testing.expectEqual(COLOR_DEFAULT, t.attr.fg);
    try testing.expectEqualStrings("        ", rowText(&t, 0, &buf));
}

test "dirty rows: only what changed, and a scroll the renderer can blit" {
    var t, const cells = scratch(8, 4);
    defer testing.allocator.free(cells);

    t.clearDirty();
    t.write("\x1b[3;1Hhi");
    try testing.expect(!t.isDirty(0));
    try testing.expect(t.isDirty(2));

    // A scroll moves the rows that are waiting to be drawn with it, marks
    // the row it brought in, and says what the renderer may blit instead.
    t.clearDirty();
    t.write("\x1b[3;1Hx");
    t.write("\x1b[4;1H\n");
    const scroll = t.takeScroll().?;
    try testing.expectEqual(@as(i32, 1), scroll.lines);
    try testing.expectEqual(@as(u32, 0), scroll.top);
    try testing.expectEqual(@as(u32, 3), scroll.bottom);
    try testing.expect(t.isDirty(1)); // the row that was 2
    try testing.expect(t.isDirty(3)); // the row it brought in
    try testing.expect(!t.isDirty(2));
    try testing.expect(t.takeScroll() == null);
}

test "a line feed is a new line, unless the program says otherwise" {
    var t, const cells = scratch(8, 3);
    defer testing.allocator.free(cells);
    var buf: [8]u8 = undefined;

    // LNM is on to begin with: a line feed returns to column 0 as well.
    t.write("ab\ncd");
    try testing.expectEqualStrings("ab      ", rowText(&t, 0, &buf));
    try testing.expectEqualStrings("cd      ", rowText(&t, 1, &buf));

    // Turned off, a line feed only moves down.
    t.write("\x1b[2J\x1b[20l\x1b[1;1Hab\ncd");
    try testing.expectEqualStrings("ab      ", rowText(&t, 0, &buf));
    try testing.expectEqualStrings("  cd    ", rowText(&t, 1, &buf));
    t.write("\x1b[20h");
    try testing.expect(t.lnm);
}

test "the other screen, and a window of a size the program asks for" {
    var t, const cells = scratch(8, 3);
    defer testing.allocator.free(cells);
    var alt = [_]Cell{.{}} ** 24;
    var buf: [8]u8 = undefined;

    t.write("main\r\n");
    t.write("\x1b[?1049h");
    try testing.expectEqual(AltRequest.enter, t.alt_request);
    t.alt_request = .none;
    t.enterAlternate(&alt);
    try testing.expectEqualStrings("        ", rowText(&t, 0, &buf));
    t.write("other");
    try testing.expectEqualStrings("other   ", rowText(&t, 0, &buf));

    // Back, and what was there is still there.
    t.write("\x1b[?1049l");
    try testing.expectEqual(AltRequest.leave, t.alt_request);
    t.alt_request = .none;
    t.leaveAlternate(cells);
    try testing.expectEqualStrings("main    ", rowText(&t, 0, &buf));

    // A window of 20 by 5 characters, asked for.
    t.write("\x1b[8;5;20t");
    try testing.expectEqual(@as(u32, 5), t.want_rows);
    try testing.expectEqual(@as(u32, 20), t.want_cols);

    // A program asks for the other screen and writes on it in one breath,
    // so a write stops the moment the screen has to change hands: what
    // follows would otherwise be written on the screen being left.
    t.want_rows = 0;
    t.want_cols = 0;
    const both = "\x1b[?1049hhere";
    const took = t.writeSome(both);
    try testing.expectEqual(AltRequest.enter, t.alt_request);
    try testing.expectEqual(both.len - "here".len, took);
    t.alt_request = .none;
    t.enterAlternate(&alt);
    try testing.expectEqual(both.len - took, t.writeSome(both[took..]));
    try testing.expectEqualStrings("here    ", rowText(&t, 0, &buf));
}

test "a resize lays the lines out again at the new width" {
    var t, const cells = scratch(10, 4);
    defer testing.allocator.free(cells);
    var buf: [24]u8 = undefined;

    // One line of fifteen characters in ten columns: it wraps, so the two
    // rows are one line and the second is the row it runs on into.
    t.write("abcdefghijklmno");
    try testing.expectEqualStrings("abcdefghij", rowText(&t, 0, &buf));
    try testing.expect(t.at(9, 0).flags & CELL_WRAP != 0);

    // Narrower: the line is laid out again rather than cut off.
    const narrow = testing.allocator.alloc(Cell, 6 * 6) catch unreachable;
    defer testing.allocator.free(narrow);
    t.resize(narrow, 6, 6);
    try testing.expectEqualStrings("abcdef", rowText(&t, 0, &buf));
    try testing.expectEqualStrings("ghijkl", rowText(&t, 1, &buf));
    try testing.expectEqualStrings("mno   ", rowText(&t, 2, &buf));
    // The cursor is still after the last character it wrote.
    try testing.expectEqual(@as(u32, 2), t.cursor().y);
    try testing.expectEqual(@as(u32, 3), t.cursor().x);

    // Wider than it ever was: the whole line is on one row, which a grid
    // copied corner to corner could not give back.
    const wide = testing.allocator.alloc(Cell, 20 * 4) catch unreachable;
    defer testing.allocator.free(wide);
    t.resize(wide, 20, 4);
    try testing.expectEqualStrings("abcdefghijklmno     ", rowText(&t, 0, &buf));
    try testing.expectEqual(@as(u32, 0), t.cursor().y);
    try testing.expectEqual(@as(u32, 15), t.cursor().x);

    // Lines of their own stay lines of their own, and what does not fit is
    // the top: the last line written is the one worth keeping.
    var tall, const tall_cells = scratch(8, 6);
    defer testing.allocator.free(tall_cells);
    tall.write("one\r\ntwo\r\nthree\r\nfour\r\nfive");
    const short = testing.allocator.alloc(Cell, 8 * 3) catch unreachable;
    defer testing.allocator.free(short);
    tall.resize(short, 8, 3);
    try testing.expectEqualStrings("three   ", rowText(&tall, 0, &buf));
    try testing.expectEqualStrings("four    ", rowText(&tall, 1, &buf));
    try testing.expectEqualStrings("five    ", rowText(&tall, 2, &buf));

    // A cursor beyond blanks - a prompt's closing space - stays beyond
    // them, so the next character does not land against the prompt.
    var prompt, const prompt_cells = scratch(10, 2);
    defer testing.allocator.free(prompt_cells);
    prompt.write("1.Sys:> ");
    const wider = testing.allocator.alloc(Cell, 12 * 2) catch unreachable;
    defer testing.allocator.free(wider);
    prompt.resize(wider, 12, 2);
    try testing.expectEqual(@as(u32, 8), prompt.cursor().x);
    prompt.write("x");
    try testing.expectEqualStrings("1.Sys:> x   ", rowText(&prompt, 0, &buf));
}

test "selecting cells, and the text that comes of it" {
    var t, const cells = scratch(8, 3);
    defer testing.allocator.free(cells);

    t.write("hello\r\nworld");
    t.clearDirty();
    t.select(0, 5);
    try testing.expect(t.isSelected(0, 0));
    try testing.expect(!t.isSelected(5, 0));
    try testing.expect(t.isDirty(0));

    var text: [32]u8 = undefined;
    try testing.expectEqualStrings("hello", text[0..t.selectionText(&text)]);

    // Two rows: the end of a row is a new line, and the room after it is
    // not text.
    t.select(0, 8 + 5);
    try testing.expectEqualStrings("hello\nworld", text[0..t.selectionText(&text)]);

    t.clearSelection();
    try testing.expect(!t.isSelected(0, 0));
}

test "a selection is the written cells: a row's end by half, the room after it not at all" {
    var t, const cells = scratch(8, 4);
    defer testing.allocator.free(cells);

    // Row 0 "ab", row 1 empty, row 2 "cd  " with two written spaces, and
    // the cursor on row 3.
    t.write("ab\r\n\r\ncd  \r\n");
    t.select(0, 4 * 8);
    try testing.expectEqual(Selected.whole, t.selection(1, 0));
    // The first empty cell after the text is the row's end, by half.
    try testing.expectEqual(Selected.half, t.selection(2, 0));
    try testing.expectEqual(Selected.no, t.selection(3, 0));
    // An empty row shows its end at its first cell.
    try testing.expectEqual(Selected.half, t.selection(0, 1));
    try testing.expectEqual(Selected.no, t.selection(1, 1));
    // Written spaces are text.
    try testing.expectEqual(Selected.whole, t.selection(3, 2));
    try testing.expectEqual(Selected.half, t.selection(4, 2));
    try testing.expectEqual(Selected.no, t.selection(5, 2));

    var text: [32]u8 = undefined;
    // The cursor's empty row is where the output ends: none of it is taken.
    try testing.expectEqual(Selected.no, t.selection(0, 3));
    try testing.expectEqualStrings("ab\n\ncd  \n", text[0..t.selectionText(&text)]);

    // Begun in the empty room, nothing there is selected; the next row's
    // start is.
    t.select(4, 8 + 1);
    try testing.expectEqual(Selected.no, t.selection(4, 0));
    try testing.expectEqual(Selected.half, t.selection(0, 1));

    // The span's end past the text on the cursor's row is not a row end:
    // that row has none yet.
    t.write("ef");
    t.select(3 * 8, 3 * 8 + 3);
    try testing.expectEqual(Selected.whole, t.selection(1, 3));
    try testing.expectEqual(Selected.no, t.selection(2, 3));
    try testing.expectEqualStrings("ef", text[0..t.selectionText(&text)]);

    // Erased cells are room again.
    t.write("\x1b[1;1H\x1b[K");
    t.select(0, 4);
    try testing.expectEqual(Selected.half, t.selection(0, 0));
    try testing.expectEqual(Selected.no, t.selection(1, 0));
}

test "blanks a line is opened up with are written; a wrapped row copies without a break" {
    var t, const cells = scratch(4, 3);
    defer testing.allocator.free(cells);

    t.write("abcdef");
    t.select(0, 4 + 2);
    var text: [32]u8 = undefined;
    try testing.expectEqualStrings("abcdef", text[0..t.selectionText(&text)]);

    t.clearSelection();
    t.write("\x1b[1;2H\x1b[2@");
    try testing.expect(t.at(1, 0).written and t.at(2, 0).written);
    try testing.expectEqual(@as(u8, 'b'), t.at(3, 0).ch);
}

test "a private prefix the terminal does not know makes the sequence nothing" {
    var t, const cells = scratch(8, 2);
    defer testing.allocator.free(cells);

    // The older console's global background is `CSI >0m`. Run as though it
    // had no prefix it would be SGR 0 and throw the attributes away.
    t.write("\x1b[31;1m");
    t.write("\x1b[>0m");
    try testing.expectEqual(@as(u16, 1), t.attr.fg);
    try testing.expectEqual(CELL_BOLD, t.attr.flags & CELL_BOLD);

    // Its auto-scroll mode is `CSI >1h`, which unprefixed is SM 1.
    t.write("\x1b[>1h");
    try testing.expect(!t.insert);

    // `=` and `<` likewise, and a `?` the terminal does know still works.
    t.write("\x1b[=7l");
    try testing.expect(t.autowrap);
    t.write("\x1b[?7l");
    try testing.expect(!t.autowrap);
}

test "the 8-bit C1 controls, and CTC" {
    // Wide enough to have default tab stops: they go in every 8 columns
    // up to the width, so an 8-column terminal has none at all.
    var t, const cells = scratch(40, 4);
    defer testing.allocator.free(cells);

    // 0x84 IND, 0x85 NEL, 0x8D RI - what ESC D, ESC E and ESC M reach.
    t.write("ab\x84");
    try testing.expectEqual(@as(u32, 1), t.y);
    try testing.expectEqual(@as(u32, 2), t.x);
    t.write("\x85");
    try testing.expectEqual(@as(u32, 2), t.y);
    try testing.expectEqual(@as(u32, 0), t.x);
    t.write("\x8D");
    try testing.expectEqual(@as(u32, 1), t.y);

    // 0x88 HTS sets a stop where the cursor is; the rest of the C1s do
    // nothing and print nothing.
    t.write("\x1b[1;1H\x1b[3C\x88\x1b[1;1H\x89\x9C");
    try testing.expectEqual(@as(u32, 0), t.x);
    t.write("\t");
    try testing.expectEqual(@as(u32, 3), t.x);

    // CTC 2 clears the stop at the cursor, so the tab falls through to
    // the default one at 8.
    t.write("\x1b[2W\x1b[1;1H\t");
    try testing.expectEqual(@as(u32, 8), t.x);
    // CTC 0 sets one where the cursor is.
    t.write("\x1b[1;1H\x1b[5C\x1b[0W\x1b[1;1H\t");
    try testing.expectEqual(@as(u32, 5), t.x);
    // CTC 5 clears the lot, so a tab runs to the last column.
    t.write("\x1b[5W\x1b[1;1H\t");
    try testing.expectEqual(t.cols - 1, t.x);
}

test "SGR 2 is bold's mirror: each clears the other, and 22 clears both" {
    var t, const cells = scratch(8, 2);
    defer testing.allocator.free(cells);

    t.write("\x1b[2mA");
    try testing.expectEqual(CELL_FAINT, t.at(0, 0).flags & CELL_FAINT);
    t.write("\x1b[1mB");
    try testing.expectEqual(CELL_BOLD, t.at(1, 0).flags & (CELL_BOLD | CELL_FAINT));
    t.write("\x1b[2mC");
    try testing.expectEqual(CELL_FAINT, t.at(2, 0).flags & (CELL_BOLD | CELL_FAINT));
    t.write("\x1b[22mD");
    try testing.expectEqual(@as(u8, 0), t.at(3, 0).flags & (CELL_BOLD | CELL_FAINT));
}

test "mouse reporting: which events are wanted, and what is said" {
    // Wider than 223 columns, so that the older form's limit is reachable.
    var t, const cells = scratch(240, 24);
    defer testing.allocator.free(cells);
    var buf: [reply_size]u8 = undefined;

    // Off to begin with, and nothing is wanted.
    try testing.expectEqual(MouseMode.off, t.mouse);
    try testing.expect(!t.wantsMouse(false, false));

    // ?1000 is buttons only; ?1002 adds a move with a button down; ?1003
    // wants every move.
    t.write("\x1b[?1000h");
    try testing.expect(t.wantsMouse(false, false));
    try testing.expect(!t.wantsMouse(true, true));
    t.write("\x1b[?1002h");
    try testing.expect(t.wantsMouse(true, true));
    try testing.expect(!t.wantsMouse(true, false));
    t.write("\x1b[?1003h");
    try testing.expect(t.wantsMouse(true, false));

    // The older form: each of button, column and row plus 32, and a
    // release cannot say which button it was.
    t.write("\x1b[?1000h");
    t.reportMouse(.left, 3, 5, false, false, false, false, false);
    try testing.expectEqualStrings("\x1b[M\x20\x24\x26", buf[0..t.takeReply(&buf)]);
    t.reportMouse(.right, 3, 5, false, true, false, false, false);
    try testing.expectEqualStrings("\x1b[M\x23\x24\x26", buf[0..t.takeReply(&buf)]);

    // A coordinate the older form cannot say is left out rather than sent
    // wrong.
    t.reportMouse(.left, 250, 5, false, false, false, false, false);
    try testing.expectEqual(@as(usize, 0), t.takeReply(&buf));

    // The SGR form says which button was let go, and has no such limit.
    t.write("\x1b[?1006h");
    t.reportMouse(.left, 3, 5, false, false, false, false, false);
    try testing.expectEqualStrings("\x1b[<0;4;6M", buf[0..t.takeReply(&buf)]);
    t.reportMouse(.right, 3, 5, false, true, false, false, false);
    try testing.expectEqualStrings("\x1b[<2;4;6m", buf[0..t.takeReply(&buf)]);

    // The modifiers and a move ride in the button: shift 4, alt 8,
    // control 16, moving 32.
    t.reportMouse(.middle, 0, 0, true, false, true, true, true);
    try testing.expectEqualStrings("\x1b[<61;1;1M", buf[0..t.takeReply(&buf)]);

    // A reset gives the pointer back.
    t.write("\x1bc");
    try testing.expectEqual(MouseMode.off, t.mouse);
    try testing.expect(!t.mouse_sgr);
}
