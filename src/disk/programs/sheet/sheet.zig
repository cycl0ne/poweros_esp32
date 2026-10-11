// SPDX-License-Identifier: MIT
//! Sheet: a spreadsheet in a window. Built against the SDK only.
//!
//!   Sheet [FILE]
//!
//! A window on the default public screen: a line at the top with the
//! current cell's name and what was typed into it, the cells below in rows
//! and columns, and a status line at the bottom. FILE, a CSV file, is
//! opened at the start; a name that is not there yet is the file the sheet
//! is saved to.
//!
//! **Cells.** A cell holds a number, a text or a formula - anything that
//! starts with `=`, worked out again whenever a cell changes (formula.zig
//! says what one may hold: operators, references such as `B7` and `$B$7`,
//! ranges such as `A1:C4`, and SUM, AVERAGE, MIN, MAX, COUNT, COUNTA,
//! PRODUCT, ABS, SQRT, ROUND, INT, MOD, POWER, EXP, LN, LOG10, SIN, COS,
//! TAN, PI, IF, AND, OR, NOT, LEN, UPPER, LOWER). Numbers sit against the
//! right of their cell in as many digits as fit, `###` when none do; a
//! text against the left, running on over empty cells beside it; a truth
//! value or an error (`#DIV/0!`, `#VALUE!`, `#REF!`, `#NAME?`, `#NUM!`,
//! `#CIRC!` for a formula that comes round to itself) in the middle. A
//! leading `'` keeps a text that would read as a number a text.
//!
//! **Typing.** A key typed on the cells begins the cell's text again with
//! it; F2, or a press let go on the current cell, edits the text it has.
//! The text is typed into the line at the top - on a board without a
//! keyboard the one on the screen comes up for it. Return keeps it and
//! goes down a row, Tab and Shift-Tab keep it and go right or left, the
//! cursor keys up and down keep it and go up or down, and Escape puts back
//! what was there. A formula that cannot be read is not kept: the status
//! line says what is wrong with it and the line stays to be put right.
//! Pressing elsewhere keeps what was typed too.
//!
//! **Moving.** The cursor keys, Page Up and Page Down, Home and End, Tab
//! (right) and Return (down) move the current cell; a press picks one, and
//! a drag picks the rectangle of cells it goes over. Shift with a cursor
//! key, Page Up or Page Down, or with a press, picks the cells from the
//! current one to where it goes, the current cell staying. A press on a
//! column's letter or a row's number picks the whole column or row, the
//! corner between them everything, and a drag along the letters or numbers
//! several. A drag on the line at the right of a column's letter makes it
//! wider or narrower. The scroll bars in the border - the window object's -
//! and the mouse wheel scroll the cells; the picture the cells are drawn
//! into is as big as the window shows, made anew when the window is sized.
//! While more than one cell is picked, the status line gives the sum, the
//! average and the count of the numbers among them.
//!
//! The menus, with their right-Amiga keys:
//!
//!   Project  New (N), Open... (O), Save (S), Save As..., Quit (Q)
//!   Edit     Undo (Z), Redo (Y), Cut (X), Copy (C), Paste (V),
//!            Clear (Del), Fill Down (D), Fill Right (R), Select All (A)
//!   Sheet    Insert Rows, Delete Rows, Insert Columns, Delete Columns,
//!            Wider Column, Narrower Column
//!
//! Control-X, -C, -V, -Z, -Y and -A do as their menu items do. Copy puts
//! the cells on the clipboard as text - a line per row, their shown values
//! split by tabs - for any program to paste, and keeps their texts for
//! Sheet itself: pasted back into Sheet, a formula's references move with
//! it as far as it moved, a part with a `$` in front staying. Text from
//! another program is pasted a line per row, split at its tabs. Fill Down
//! and Fill Right copy the first row or column of the cells picked over
//! the rest the same way. Inserting and deleting rows and columns moves
//! every formula's references to follow its cells; one to a deleted cell
//! becomes `#REF!`. Every change can be undone, the last hundred of them.
//!
//! **Files** are CSV, which every spreadsheet reads: each cell's text as
//! typed, a formula with its `=`. Open and Save As ask with asl.library's
//! file requester. A file whose fields are split by semicolons and whose
//! numbers have a decimal comma is read so and saved back the same way.
//! A sheet that has changed is not let go - by New, Open, Quit, the close
//! gadget or Ctrl-C - before a requester asks whether to save it; the
//! window's title says the file's name, with a `*` before it while it has
//! changed. A file dragged from the desktop and let go on the window is
//! opened as Open opens one. The columns' widths are the window's, not
//! the file's.
//!
//! While the window is the active one, the screen's title bar says
//! `Sheet` and the version, in place of the screen's own title.

const sdk = @import("sdk");
const asl = sdk.asl;
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const iffparse = sdk.iffparse;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const mn = intuition.menus;
const sc = intuition.screens;
const classusr = intuition.classusr;
const icc = intuition.icclass;
const sg = intuition.sghooks;
const ie = sdk.devices.inputevent;
const sr = sdk.gadgets.scroller;
const st = sdk.gadgets.string;
const tx = sdk.gadgets.text;
const cv = sdk.gadgets.canvas;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const AslBase = sdk.interface.asl.AslBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IFFParseBase = sdk.interface.iffparse.IFFParseBase;
const Object = intuition.Object;
const Window = intuition.Window;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

const cells = @import("cells.zig");
const formula = @import("formula.zig");
const number = @import("number.zig");
const csv = @import("csv.zig");
const eval = @import("eval.zig");

const max_rows = formula.max_rows;
const max_cols = formula.max_cols;

pub const COMMAND_NAME = "Sheet";
const VERSION = "1.1";
const VERSION_STRING = "\x00$VER: Sheet " ++ VERSION ++ " (11.10.2026)\r\n";
/// What the screen's title bar says while the window is the active one.
const SCREEN_TITLE = "Sheet " ++ VERSION;
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FILE";

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display\n";
const MSG_NOMEMORY = "No memory for the window\n";

/// The longest path a file is kept by.
const path_size = 256;

const ID_NAME = 1;
const ID_ENTRY = 2;
const ID_GRID = 3;
const ID_STATUS = 4;
const ID_VERT = 10;
const ID_HORIZ = 11;

// The menus and their items, in the order of `menus` below; a bar counts
// as an item.
const MENU_PROJECT = 0;
const MENU_EDIT = 1;
const MENU_SHEET = 2;

const ITEM_NEW = 0;
const ITEM_OPEN = 1;
const ITEM_SAVE = 2;
const ITEM_SAVE_AS = 3;
const ITEM_QUIT = 5;

const ITEM_UNDO = 0;
const ITEM_REDO = 1;
const ITEM_CUT = 3;
const ITEM_COPY = 4;
const ITEM_PASTE = 5;
const ITEM_CLEAR = 6;
const ITEM_FILL_DOWN = 8;
const ITEM_FILL_RIGHT = 9;
const ITEM_SELECT_ALL = 11;

const ITEM_INSERT_ROWS = 0;
const ITEM_DELETE_ROWS = 1;
const ITEM_INSERT_COLUMNS = 2;
const ITEM_DELETE_COLUMNS = 3;
const ITEM_WIDER = 5;
const ITEM_NARROWER = 6;

fn item(label: [*:0]const u8, key: ?[*:0]const u8) mn.NewMenu {
    return .{ .type = mn.NM_ITEM, .label = label, .comm_key = key };
}

const bar = mn.NewMenu{ .type = mn.NM_ITEM, .label = mn.NM_BARLABEL };

const menus = [_]mn.NewMenu{
    .{ .type = mn.NM_TITLE, .label = "Project" },
    item("New", "N"),
    item("Open...", "O"),
    item("Save", "S"),
    item("Save As...", null),
    bar,
    item("Quit", "Q"),
    .{ .type = mn.NM_TITLE, .label = "Edit" },
    item("Undo", "Z"),
    item("Redo", "Y"),
    bar,
    item("Cut", "X"),
    item("Copy", "C"),
    item("Paste", "V"),
    item("Clear", null),
    bar,
    item("Fill Down", "D"),
    item("Fill Right", "R"),
    bar,
    item("Select All", "A"),
    .{ .type = mn.NM_TITLE, .label = "Sheet" },
    item("Insert Rows", null),
    item("Delete Rows", null),
    item("Insert Columns", null),
    item("Delete Columns", null),
    bar,
    item("Wider Column", null),
    item("Narrower Column", null),
    .{},
};

// Raw key codes the cells move by.
const raw_up = 0x4C;
const raw_down = 0x4D;
const raw_right = 0x4E;
const raw_left = 0x4F;
const raw_page_up = 0x48;
const raw_page_down = 0x49;
const raw_home = 0x70;
const raw_end = 0x71;
const raw_f2 = 0x51;
const raw_escape = 0x45;

/// What a drag on the cells is doing.
const Drag = enum { none, cells, rows, cols, resize };

/// The colours the cells are drawn in, from the screen's pens.
const Pens = struct {
    paper: graphics.Pen = 0,
    ink: graphics.Pen = 0,
    line: graphics.Pen = 0,
    header: graphics.Pen = 0,
    mark: graphics.Pen = 0,
    mark_header: graphics.Pen = 0,
    mark_header_ink: graphics.Pen = 0,
    frame: graphics.Pen = 0,
};

/// `part` eighths of `over` laid on `under`.
fn mix(under: graphics.Pen, over: graphics.Pen, part: u32) graphics.Pen {
    var out: graphics.Pen = 0xFF00_0000;
    var shift: u5 = 0;
    while (shift < 24) : (shift += 8) {
        const beneath = (under >> shift) & 0xFF;
        const above = (over >> shift) & 0xFF;
        out |= ((beneath * (8 - part) + above * part) / 8) << shift;
    }
    return out;
}

/// The two scroll bars in the border, the window object's; either is
/// null when it could not be made.
const Bars = struct { vert: ?*Object, horiz: ?*Object };

const App = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ib: *IntuitionBase,
    gb: *GraphicsBase,
    screen: *intuition.Screen,
    draw_info: *intuition.DrawInfo,
    object: *Object,
    window: *Window = undefined,
    name_box: *Object,
    entry: *Object,
    grid: *Object,
    status: *Object,
    bars: Bars = .{ .vert = null, .horiz = null },
    /// The picture the cells are drawn into, as big as the screen.
    rp: *graphics.RastPort,
    picture_w: i32,
    picture_h: i32,
    sheet: *cells.Sheet,

    // --- the view -----------------------------------------------------------
    top_row: u32 = 0,
    left_col: u32 = 0,
    col_width: [max_cols]u16 = undefined,
    row_h: i32 = 20,
    header_w: i32 = 40,
    baseline: i32 = 12,
    char_w: i32 = 8,
    pens: Pens = .{},

    // --- what is picked -------------------------------------------------------
    /// The current cell.
    row: u32 = 0,
    col: u32 = 0,
    /// Where a drag began: the corner of the area that stays.
    anchor_row: u32 = 0,
    anchor_col: u32 = 0,
    /// The corner across from it, which a drag or Shift and a cursor key
    /// moves.
    far_row: u32 = 0,
    far_col: u32 = 0,
    area: cells.Area = .{ .top = 0, .left = 0, .bottom = 0, .right = 0 },
    drag: Drag = .none,
    resizing: u32 = 0,
    /// The press was on the current cell, and has not left it: let go
    /// there, it edits the cell.
    press_again: bool = false,

    // --- texts the gadgets show -----------------------------------------------
    name_text: [16:0]u8 = @splat(0),
    status_text: [160:0]u8 = @splat(0),
    /// The status line says something that stays until the next move.
    telling: bool = false,

    // --- files ----------------------------------------------------------------
    path: [path_size:0]u8 = @splat(0),
    title: [path_size + 16:0]u8 = @splat(0),
    shown_changed: bool = false,
    form: csv.Form = .{},

    // --- the clipboard --------------------------------------------------------
    block: cells.Block = .{},
    /// What Sheet last put on the clipboard, to know its own when it comes
    /// back.
    clip: ?[*]u8 = null,
    clip_len: u32 = 0,
    asl_lib: ?*exec.Library = null,
    iff_lib: ?*exec.Library = null,

    /// The window as one files can be dropped on, while the desktop runs.
    drop: sdk.anvil.DropTarget = .{},

    fn deinit(app: *App) void {
        app.block.deinit(app.sys);
        if (app.clip) |clip| app.sys.FreeVec(clip);
        for ([_]?*exec.Library{ app.asl_lib, app.iff_lib }) |lib| {
            if (lib) |opened| app.sys.CloseLibrary(opened);
        }
    }

    // --- measures and pens ----------------------------------------------------

    fn rpAttr(app: *App, attr: sdk.utility.Tag) i32 {
        var value: u32 = 0;
        app.gb.GetRPAttrs(app.rp, &[_]TagItem{ .{ .tag = attr, .data = @intFromPtr(&value) }, .{} });
        return @intCast(value);
    }

    fn textWidth(app: *App, text: []const u8) i32 {
        if (text.len == 0) return 0;
        return app.gb.TextLength(app.rp, text.ptr, @intCast(text.len));
    }

    /// The screen's font on the picture and the measures that follow from
    /// it; the pens from the screen's.
    fn takeLook(app: *App) void {
        if (app.draw_info.font) |font| graphics.SetFont(app.gb, app.rp, font);
        const height = @max(app.rpAttr(graphics.RPTAG_FontHeight), 8);
        app.row_h = height + 6;
        app.baseline = 3 + app.rpAttr(graphics.RPTAG_FontBaseline);
        app.char_w = @max(app.textWidth("0"), 4);
        app.header_w = app.textWidth("9999") + 12;
        const pens = app.draw_info.pens;
        const paper = pens[sc.BACKGROUNDPEN];
        const ink = pens[sc.TEXTPEN];
        app.pens = .{
            .paper = paper,
            .ink = ink,
            .line = mix(paper, ink, 2),
            .header = mix(paper, ink, 1),
            .mark = mix(paper, pens[sc.FILLPEN], 2),
            .mark_header = pens[sc.FILLPEN],
            .mark_header_ink = pens[sc.FILLTEXTPEN],
            .frame = pens[sc.FILLPEN],
        };
    }

    fn defaultWidth(app: *App) u16 {
        return @intCast(app.char_w * 10 + 8);
    }

    /// How much of the picture the gadget shows.
    fn viewW(app: *App) i32 {
        return @min(gc.gadget(app.grid).width, app.picture_w);
    }

    fn viewH(app: *App) i32 {
        return @min(gc.gadget(app.grid).height, app.picture_h);
    }

    /// The picture made as big as the gadget's box now, and the RastPort
    /// the new one has; its font and pens come with it.
    fn fitPicture(app: *App) void {
        _ = app.ib.SetGadgetAttrsTagList(app.grid, app.window, &[_]TagItem{
            .{ .tag = cv.CANVAS_Width, .data = 0 },
            .{ .tag = cv.CANVAS_Height, .data = 0 },
            .{},
        });
        var value: usize = 0;
        _ = app.ib.GetAttr(cv.CANVAS_RastPort, app.grid, &value);
        app.rp = @ptrFromInt(value);
        _ = app.ib.GetAttr(cv.CANVAS_Width, app.grid, &value);
        app.picture_w = @intCast(value);
        _ = app.ib.GetAttr(cv.CANVAS_Height, app.grid, &value);
        app.picture_h = @intCast(value);
    }

    /// The rows wholly in view, at least one.
    fn visibleRows(app: *App) u32 {
        const rows = @divTrunc(app.viewH() - app.row_h, app.row_h);
        return if (rows < 1) 1 else @intCast(rows);
    }

    /// The columns wholly in view, at least one.
    fn visibleCols(app: *App) u32 {
        var x = app.header_w;
        var count: u32 = 0;
        var col = app.left_col;
        while (col < max_cols) : (col += 1) {
            x += app.col_width[col];
            if (x > app.viewW()) break;
            count += 1;
        }
        return @max(count, 1);
    }

    /// The left edge of a column in view, or null for one left of it.
    fn colLeft(app: *App, col: u32) ?i32 {
        if (col < app.left_col) return null;
        var x = app.header_w;
        var at = app.left_col;
        while (at < col) : (at += 1) x += app.col_width[at];
        return x;
    }

    // --- drawing --------------------------------------------------------------

    fn setPen(app: *App, pen: graphics.Pen) void {
        app.gb.SetRPAttrs(app.rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = pen }, .{} });
    }

    fn fill(app: *App, left: i32, top: i32, right: i32, bottom: i32, pen: graphics.Pen) void {
        if (right <= left or bottom <= top) return;
        app.setPen(pen);
        app.gb.RectFill(app.rp, &.{ .min_x = left, .min_y = top, .max_x = right, .max_y = bottom });
    }

    fn clipTo(app: *App, rect: graphics.Rect) void {
        app.gb.SetRPAttrs(app.rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_ClipRect, .data = @intFromPtr(&rect) }, .{} });
    }

    fn unclip(app: *App) void {
        app.clipTo(.{ .max_x = app.picture_w, .max_y = app.picture_h });
    }

    /// `text` at `x` on the row whose top is `top`, cut to `left`..`right`.
    fn write(app: *App, text: []const u8, x: i32, top: i32, left: i32, right: i32, pen: graphics.Pen) void {
        if (text.len == 0 or right <= left) return;
        app.clipTo(.{ .min_x = left, .min_y = top, .max_x = right, .max_y = top + app.row_h });
        app.setPen(pen);
        app.gb.Move(app.rp, x, top + app.baseline);
        app.gb.Text(app.rp, text.ptr, @intCast(text.len));
        app.unclip();
    }

    /// A number in as many digits as the width has room for, or `###`.
    fn numberText(app: *App, value: f64, room: i32, out: *[32]u8) []const u8 {
        var digits: u32 = 10;
        while (digits >= 1) : (digits -= 1) {
            const text = number.format(value, digits, out);
            if (app.textWidth(text) <= room) return text;
        }
        const hash_w = @max(app.textWidth("#"), 1);
        const count: usize = @intCast(@max(1, @min(31, @divTrunc(room, hash_w))));
        @memset(out[0..count], '#');
        return out[0..count];
    }

    /// One row's cells: their grounds, then their texts, then the lines
    /// between them that no text runs over.
    fn drawRow(app: *App, row: u32, top: i32, width: i32) void {
        const bottom = top + app.row_h;
        const picked_many = app.area.cells() > 1;
        var x = app.header_w;
        var col = app.left_col;
        while (x < width and col < max_cols) : (col += 1) {
            const cw: i32 = app.col_width[col];
            const current = row == app.row and col == app.col;
            if (picked_many and !current and app.area.holds(row, col)) app.fill(x, top, x + cw, bottom, app.pens.mark);
            x += cw;
        }

        // The texts. `covered` marks the columns whose right-hand line a
        // text runs over.
        var covered: [max_cols]bool = undefined;
        @memset(covered[0..], false);
        x = app.header_w;
        col = app.left_col;
        while (x < width and col < max_cols) : (col += 1) {
            const cw: i32 = app.col_width[col];
            defer x += cw;
            const cell = app.sheet.find(row, col) orelse continue;
            const value = cell.value;
            var digits: [32]u8 = undefined;
            switch (value.kind) {
                .number => {
                    const text = app.numberText(value.number, cw - 6, &digits);
                    app.write(text, x + cw - 3 - app.textWidth(text), top, x + 1, x + cw - 1, app.pens.ink);
                },
                .text => {
                    // Over the empty cells to its right, as far as it needs.
                    const text_w = app.textWidth(value.text);
                    var right = x + cw;
                    var next = col + 1;
                    while (text_w + 6 > right - x and right < width and next < max_cols and app.sheet.find(row, next) == null) : (next += 1) {
                        covered[next - 1] = true;
                        right += app.col_width[next];
                    }
                    app.write(value.text, x + 3, top, x + 1, right - 1, app.pens.ink);
                },
                .boolean, .err => {
                    const text = cells.shownText(value, 10, &digits);
                    app.write(text, x + @divTrunc(cw - app.textWidth(text), 2), top, x + 1, x + cw - 1, app.pens.ink);
                },
                .empty, .range => {},
            }
        }

        x = app.header_w;
        col = app.left_col;
        app.setPen(app.pens.line);
        while (x < width and col < max_cols) : (col += 1) {
            x += app.col_width[col];
            if (!covered[col]) app.gb.DrawVLine(app.rp, x - 1, top, app.row_h);
        }
    }

    /// The cells drawn into the picture, and the picture shown.
    fn draw(app: *App) void {
        const width = app.viewW();
        const height = app.viewH();
        if (width <= 0 or height <= 0) return;
        app.unclip();
        app.fill(0, 0, width, height, app.pens.paper);

        // The columns' letters.
        app.fill(0, 0, width, app.row_h, app.pens.header);
        var x = app.header_w;
        var col = app.left_col;
        while (x < width and col < max_cols) : (col += 1) {
            const cw: i32 = app.col_width[col];
            const marked = col >= app.area.left and col <= app.area.right;
            if (marked) app.fill(x, 0, x + cw, app.row_h, app.pens.mark_header);
            var letters: [2]u8 = undefined;
            const name = formula.columnName(col, &letters);
            app.write(name, x + @divTrunc(cw - app.textWidth(name), 2), 0, x, x + cw, if (marked) app.pens.mark_header_ink else app.pens.ink);
            app.setPen(app.pens.line);
            app.gb.DrawVLine(app.rp, x + cw - 1, 0, app.row_h);
            x += cw;
        }
        const cells_right = @min(x, width);

        // The rows, each with its number.
        var top = app.row_h;
        var row = app.top_row;
        while (top < height and row < max_rows) : (row += 1) {
            const marked = row >= app.area.top and row <= app.area.bottom;
            app.fill(0, top, app.header_w, top + app.row_h, if (marked) app.pens.mark_header else app.pens.header);
            var name: [8]u8 = undefined;
            const digits = formula.cellName(row, 0, &name)[1..];
            app.write(digits, app.header_w - 6 - app.textWidth(digits), top, 0, app.header_w, if (marked) app.pens.mark_header_ink else app.pens.ink);
            app.drawRow(row, top, width);
            app.setPen(app.pens.line);
            app.gb.DrawHLine(app.rp, 0, top + app.row_h - 1, cells_right);
            top += app.row_h;
        }
        app.setPen(app.pens.line);
        app.gb.DrawVLine(app.rp, app.header_w - 1, 0, height);
        app.gb.DrawHLine(app.rp, 0, app.row_h - 1, width);

        // The current cell's frame, two pixels inside its lines.
        if (app.row >= app.top_row and app.colLeft(app.col) != null) {
            const left = app.colLeft(app.col).?;
            const frame_top = app.row_h + @as(i32, @intCast(app.row - app.top_row)) * app.row_h;
            const right = left + app.col_width[app.col];
            if (frame_top < height and left < width) {
                app.setPen(app.pens.frame);
                app.gb.DrawRect(app.rp, &.{ .min_x = left - 1, .min_y = frame_top - 1, .max_x = right, .max_y = frame_top + app.row_h });
                app.gb.DrawRect(app.rp, &.{ .min_x = left, .min_y = frame_top, .max_x = right - 1, .max_y = frame_top + app.row_h - 1 });
            }
        }
        app.ib.QueueGadgetRefresh(app.grid);
    }

    // --- the line at the top and the status line ------------------------------

    /// The current cell's name and text in the line at the top, and the
    /// status line brought up to date.
    fn showCurrent(app: *App) void {
        var name: [8]u8 = undefined;
        const text = formula.cellName(app.row, app.col, &name);
        @memcpy(app.name_text[0..text.len], text);
        app.name_text[text.len] = 0;
        _ = app.ib.SetGadgetAttrsTagList(app.name_box, app.window, &[_]TagItem{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&app.name_text) }, .{} });
        const input = app.sheet.textAt(app.row, app.col);
        // A cell's text has a 0 after it; "" is one too.
        _ = app.ib.SetGadgetAttrsTagList(app.entry, app.window, &[_]TagItem{ .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(input.ptr) }, .{} });
        app.showStatus();
    }

    fn setStatus(app: *App, text: []const u8) void {
        const length = @min(text.len, app.status_text.len);
        @memcpy(app.status_text[0..length], text[0..length]);
        app.status_text[length] = 0;
        _ = app.ib.SetGadgetAttrsTagList(app.status, app.window, &[_]TagItem{ .{ .tag = tx.TEXT_Text, .data = @intFromPtr(&app.status_text) }, .{} });
    }

    /// A message in the status line, kept until the next move.
    fn say(app: *App, text: []const u8) void {
        app.setStatus(text);
        app.telling = true;
    }

    /// The status line: the sum, average and count of the numbers among
    /// the cells picked, when there are several.
    fn showStatus(app: *App) void {
        if (app.telling) return;
        if (app.area.cells() <= 1) return app.setStatus("");
        var gather = Totals{};
        app.sheet.eachInRange(app.area.top, app.area.left, app.area.bottom, app.area.right, &gather);
        var line: [160]u8 = undefined;
        var used: usize = 0;
        const parts = [_]struct { label: []const u8, value: ?f64 }{
            .{ .label = "Sum ", .value = gather.sum },
            .{ .label = "   Average ", .value = if (gather.count > 0) gather.sum / @as(f64, @floatFromInt(gather.count)) else null },
            .{ .label = "   Count ", .value = @floatFromInt(gather.count) },
        };
        for (parts) |part| {
            const shown = part.value orelse continue;
            @memcpy(line[used..][0..part.label.len], part.label);
            used += part.label.len;
            var digits: [32]u8 = undefined;
            const text = number.format(shown, 10, &digits);
            @memcpy(line[used..][0..text.len], text);
            used += text.len;
        }
        app.setStatus(line[0..used]);
    }

    /// What the line at the top holds now.
    fn entryText(app: *App) []const u8 {
        var value: usize = 0;
        _ = app.ib.GetAttr(gc.STRINGA_TextVal, app.entry, &value);
        if (value == 0) return "";
        const text: [*:0]const u8 = @ptrFromInt(value);
        var length: usize = 0;
        while (text[length] != 0) length += 1;
        return text[0..length];
    }

    /// The keyboard given to the line at the top, the cursor at the end of
    /// its text: the cell's text, or `begun` in its place - the character
    /// typed on the cells, or nothing.
    fn startEdit(app: *App, begun: ?[]const u8) void {
        // As a C string: the character and a 0.
        var typed = [2]u8{ 0, 0 };
        var text: []const u8 = app.sheet.textAt(app.row, app.col);
        if (begun) |start| {
            if (start.len > 0) typed[0] = start[0];
            text = typed[0..start.len];
        }
        _ = app.ib.SetGadgetAttrsTagList(app.entry, app.window, &[_]TagItem{
            .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(text.ptr) },
            .{ .tag = gc.STRINGA_BufferPos, .data = text.len },
            .{},
        });
        _ = app.ib.ActivateGadget(app.entry, app.window, null);
    }

    /// What the line at the top holds, kept in the current cell. False when
    /// it is a formula that cannot be read: the status line says why, and
    /// the line is given the keyboard again to put it right.
    fn commit(app: *App) bool {
        const text = app.entryText();
        if (cells.sameText(text, app.sheet.textAt(app.row, app.col))) return true;
        if (text.len > 0 and text[0] == '=') {
            const compiled = formula.compile(text, &app.sheet.scratch.ops);
            if (compiled.problem != .none) {
                app.tellProblem(compiled);
                app.ib.DisplayBeep(app.screen);
                _ = app.ib.ActivateGadget(app.entry, app.window, null);
                return false;
            }
        }
        // Copied first: the line's text is the gadget's, and the change
        // redraws nothing of it, but a cell's own text it is not.
        var kept: [cells.max_text]u8 = undefined;
        const length = @min(text.len, kept.len);
        @memcpy(kept[0..length], text[0..length]);
        app.sheet.begin();
        const ok = app.sheet.changeText(app.row, app.col, kept[0..length]);
        if (!app.sheet.end() or !ok) app.say("Not enough memory to keep all of that");
        app.followChanges();
        return true;
    }

    fn tellProblem(app: *App, compiled: formula.Compiled) void {
        const what: []const u8 = switch (compiled.problem) {
            .unknown_name => "No such function or name",
            .arguments => "Wrong number of arguments",
            .parentheses => "A parenthesis has no partner",
            .too_long => "The formula is too long",
            else => "The formula cannot be read",
        };
        var line: [96]u8 = undefined;
        var used: usize = 0;
        for ([_][]const u8{ what, ", at character " }) |part| {
            @memcpy(line[used..][0..part.len], part);
            used += part.len;
        }
        var digits: [32]u8 = undefined;
        const at = number.format(@floatFromInt(compiled.at + 1), 10, &digits);
        @memcpy(line[used..][0..at.len], at);
        used += at.len;
        app.say(line[0..used]);
    }

    /// Typing left in the line at the top kept before anything else is
    /// done. False when it cannot be.
    fn settle(app: *App) bool {
        if (cells.sameText(app.entryText(), app.sheet.textAt(app.row, app.col))) return true;
        return app.commit();
    }

    // --- moving -----------------------------------------------------------------

    /// The view scrolled so the cell is in it.
    fn reveal(app: *App, row: u32, col: u32) void {
        const rows = app.visibleRows();
        if (row < app.top_row) app.top_row = row;
        if (row >= app.top_row + rows) app.top_row = row - rows + 1;
        if (col < app.left_col) app.left_col = col;
        while (app.left_col < col) {
            const left = app.colLeft(col).?;
            if (left + app.col_width[col] <= app.viewW()) break;
            app.left_col += 1;
        }
    }

    /// The current cell moved to `row`, `col`, the only one picked.
    fn moveTo(app: *App, row: u32, col: u32) void {
        app.row = @min(row, max_rows - 1);
        app.col = @min(col, max_cols - 1);
        app.anchor_row = app.row;
        app.anchor_col = app.col;
        app.far_row = app.row;
        app.far_col = app.col;
        app.area = .{ .top = app.row, .left = app.col, .bottom = app.row, .right = app.col };
        app.telling = false;
        app.reveal(app.row, app.col);
        app.showCurrent();
        app.draw();
        app.followBars();
    }

    fn moveBy(app: *App, rows: i32, cols: i32) void {
        const row = @as(i64, app.row) + rows;
        const col = @as(i64, app.col) + cols;
        app.moveTo(@intCast(@max(0, @min(row, max_rows - 1))), @intCast(@max(0, @min(col, max_cols - 1))));
    }

    /// The corner of the cells picked across from the current cell moved,
    /// the current cell staying where it is: Shift and a cursor key.
    fn extendBy(app: *App, rows: i32, cols: i32) void {
        const row = @as(i64, app.far_row) + rows;
        const col = @as(i64, app.far_col) + cols;
        app.far_row = @intCast(@max(0, @min(row, max_rows - 1)));
        app.far_col = @intCast(@max(0, @min(col, max_cols - 1)));
        app.area = between(app.row, app.col, app.far_row, app.far_col);
        app.telling = false;
        app.reveal(app.far_row, app.far_col);
        app.showStatus();
        app.draw();
        app.followBars();
    }

    fn pickAll(app: *App) void {
        app.area = .{ .top = 0, .left = 0, .bottom = max_rows - 1, .right = max_cols - 1 };
        app.telling = false;
        app.showStatus();
        app.draw();
    }

    // --- the pointer ------------------------------------------------------------

    fn pointer(app: *App) struct { x: i32, y: i32 } {
        var x: usize = 0;
        var y: usize = 0;
        _ = app.ib.GetAttr(cv.CANVAS_X, app.grid, &x);
        _ = app.ib.GetAttr(cv.CANVAS_Y, app.grid, &y);
        return .{ .x = @truncate(@as(isize, @bitCast(x))), .y = @truncate(@as(isize, @bitCast(y))) };
    }

    /// The row at `y`, scrolling when it is past the cells shown.
    fn rowAt(app: *App, y: i32) u32 {
        if (y < app.row_h) return app.top_row -| 1;
        const row = app.top_row + @as(u32, @intCast(@divTrunc(y - app.row_h, app.row_h)));
        return @min(row, max_rows - 1);
    }

    /// The column at `x`, scrolling when it is past the cells shown.
    fn colAt(app: *App, x: i32) u32 {
        if (x < app.header_w) return app.left_col -| 1;
        var right = app.header_w;
        var col = app.left_col;
        while (col < max_cols) : (col += 1) {
            right += app.col_width[col];
            if (x < right) return col;
        }
        return max_cols - 1;
    }

    /// The column whose right-hand line is within reach of `x` on the
    /// letters, to be dragged wider or narrower.
    fn edgeAt(app: *App, x: i32) ?u32 {
        var right = app.header_w;
        var col = app.left_col;
        while (col < max_cols and right < app.viewW() + 4) : (col += 1) {
            right += app.col_width[col];
            if (x >= right - 5 and x <= right + 3) return col;
        }
        return null;
    }

    /// A press on the cells; with Shift on a cell, the cells from the
    /// current one to it picked.
    fn press(app: *App, shifted: bool) void {
        if (!app.settle()) return;
        const at = app.pointer();
        app.telling = false;
        if (at.y < app.row_h and at.x < app.header_w) {
            app.drag = .none;
            app.pickAll();
            return;
        }
        if (at.y < app.row_h) {
            if (app.edgeAt(at.x)) |col| {
                app.drag = .resize;
                app.resizing = col;
                return;
            }
            const col = app.colAt(at.x);
            app.row = app.top_row;
            app.col = col;
            app.anchor_col = col;
            app.drag = .cols;
            app.area = .{ .top = 0, .left = col, .bottom = max_rows - 1, .right = col };
            app.far_row = app.row;
            app.far_col = col;
        } else if (at.x < app.header_w) {
            const row = app.rowAt(at.y);
            app.row = row;
            app.col = app.left_col;
            app.anchor_row = row;
            app.drag = .rows;
            app.area = .{ .top = row, .left = 0, .bottom = row, .right = max_cols - 1 };
            app.far_row = row;
            app.far_col = app.col;
        } else {
            const row = app.rowAt(at.y);
            const col = app.colAt(at.x);
            app.drag = .cells;
            app.far_row = row;
            app.far_col = col;
            if (shifted) {
                // From the current cell, which stays current; a drag goes
                // on from there.
                app.press_again = false;
                app.anchor_row = app.row;
                app.anchor_col = app.col;
                app.area = between(app.row, app.col, row, col);
                app.showStatus();
                app.draw();
                app.followBars();
                return;
            }
            app.press_again = row == app.row and col == app.col and app.area.cells() == 1;
            app.row = row;
            app.col = col;
            app.anchor_row = row;
            app.anchor_col = col;
            app.area = .{ .top = row, .left = col, .bottom = row, .right = col };
        }
        app.showCurrent();
        app.draw();
    }

    fn dragTo(app: *App) void {
        const at = app.pointer();
        switch (app.drag) {
            .none => return,
            .resize => {
                const left = app.colLeft(app.resizing) orelse return;
                const width = @max(@min(at.x - left, 600), app.char_w * 2);
                app.col_width[app.resizing] = @intCast(width);
                app.draw();
                app.followBars();
                return;
            },
            .cells => {
                const row = app.rowAt(at.y);
                const col = app.colAt(at.x);
                if (row != app.anchor_row or col != app.anchor_col) app.press_again = false;
                app.far_row = row;
                app.far_col = col;
                app.area = between(app.anchor_row, app.anchor_col, row, col);
                app.reveal(row, col);
            },
            .cols => {
                const col = app.colAt(at.x);
                app.area.left = @min(col, app.anchor_col);
                app.area.right = @max(col, app.anchor_col);
                app.reveal(app.top_row, col);
            },
            .rows => {
                const row = app.rowAt(at.y);
                app.area.top = @min(row, app.anchor_row);
                app.area.bottom = @max(row, app.anchor_row);
                app.reveal(row, app.left_col);
            },
        }
        app.showStatus();
        app.draw();
        app.followBars();
    }

    // --- the scroll bars --------------------------------------------------------

    fn barTop(app: *App, gadget: *Object) u32 {
        var value: usize = 0;
        _ = app.ib.GetAttr(sr.SCROLLER_Top, gadget, &value);
        return @truncate(value);
    }

    /// The bars set from the view: as far as the cells reach, and a screen
    /// further, so there is always somewhere to scroll to.
    fn followBars(app: *App) void {
        const bars = app.bars;
        const reach = app.sheet.extent();
        const rows = app.visibleRows();
        const cols = app.visibleCols();
        const total_rows = @min(@max(reach.rows, app.row + 1, app.top_row + rows) + rows, max_rows);
        const total_cols = @min(@max(reach.cols, app.col + 1, app.left_col + cols) + cols, max_cols);
        const pairs = [_]struct { gadget: ?*Object, total: u32, visible: u32, top: u32 }{
            .{ .gadget = bars.vert, .total = total_rows, .visible = rows, .top = app.top_row },
            .{ .gadget = bars.horiz, .total = total_cols, .visible = cols, .top = app.left_col },
        };
        for (pairs) |pair| {
            const gadget = pair.gadget orelse continue;
            _ = app.ib.SetGadgetAttrsTagList(gadget, app.window, &[_]TagItem{
                .{ .tag = sr.SCROLLER_Total, .data = pair.total },
                .{ .tag = sr.SCROLLER_Visible, .data = pair.visible },
                .{ .tag = sr.SCROLLER_Top, .data = pair.top },
                .{},
            });
        }
    }

    /// The view moved to where the bars are.
    fn followScrollers(app: *App) void {
        const top = if (app.bars.vert) |scroller| @min(app.barTop(scroller), max_rows - 1) else app.top_row;
        const left = if (app.bars.horiz) |scroller| @min(app.barTop(scroller), max_cols - 1) else app.left_col;
        if (top == app.top_row and left == app.left_col) return;
        app.top_row = top;
        app.left_col = left;
        app.draw();
    }

    fn scrollRows(app: *App, rows: i32) void {
        const top = @as(i64, app.top_row) + rows;
        app.top_row = @intCast(@max(0, @min(top, max_rows - 1)));
        app.draw();
        app.followBars();
    }

    // --- the title ----------------------------------------------------------------

    /// The title made to say the file's name, and whether the sheet has
    /// changed since it was read or saved.
    fn showTitle(app: *App) void {
        const now = app.sheet.changed;
        app.shown_changed = now;
        const name: [*:0]const u8 = if (app.path[0] != 0) app.dl.FilePart(&app.path) else "Untitled";
        var used: usize = 0;
        if (now) {
            app.title[0] = '*';
            used = 1;
        }
        var at: usize = 0;
        while (name[at] != 0 and used < app.title.len - 12) : (at += 1) {
            app.title[used] = name[at];
            used += 1;
        }
        for (" - Sheet") |byte| {
            app.title[used] = byte;
            used += 1;
        }
        app.title[used] = 0;
        app.ib.SetWindowTitles(app.window, &app.title, wn.TITLE_UNCHANGED);
    }

    /// After a change: the cells drawn, the line at the top, the bars and
    /// the title brought up to date.
    fn followChanges(app: *App) void {
        app.showCurrent();
        app.draw();
        app.followBars();
        if (app.sheet.changed != app.shown_changed) app.showTitle();
    }

    fn tell(app: *App, comptime format: [*:0]const u8, name: [*:0]const u8) void {
        const easy = intuition.requesters.EasyStruct{ .title = "Sheet", .text_format = format, .gadget_format = "OK" };
        const args = [_]usize{@intFromPtr(name)};
        _ = app.ib.EasyRequestArgs(app.window, &easy, null, &args);
    }

    // --- files ------------------------------------------------------------------

    /// The view back at the first cell, every column as wide as it starts.
    fn resetView(app: *App) void {
        const width = app.defaultWidth();
        for (&app.col_width) |*one| one.* = width;
        app.top_row = 0;
        app.left_col = 0;
        app.moveTo(0, 0);
    }

    /// The file read into the sheet, and its name kept. False, and the
    /// sheet as it was, when it cannot be read; quietly when `quiet` and it
    /// is not there.
    fn load(app: *App, name: [*:0]const u8, quiet: bool) bool {
        const dl = app.dl;
        const sys = app.sys;
        const file = dl.Open(name, dos.MODE_OLDFILE) orelse {
            if (!quiet) app.tell("Cannot open %s", name);
            return false;
        };
        defer _ = dl.Close(file);
        var fib: dos.FileInfoBlock = .{};
        if (!dl.ExamineFH(file, &fib)) {
            app.tell("Cannot read %s", name);
            return false;
        }
        if (fib.size > 0x7FFF_FFFF) {
            app.tell("%s is too big", name);
            return false;
        }
        const size: u32 = @intCast(fib.size);
        const memory: [*]u8 = @ptrCast(sys.AllocVec(@max(size, 1), exec.MEMF_ANY) orelse {
            app.tell("No memory for %s", name);
            return false;
        });
        defer sys.FreeVec(memory);
        if (dl.Read(file, memory, @intCast(size)) != size) {
            app.tell("Cannot read %s", name);
            return false;
        }
        const result = csv.read(app.sheet, memory[0..size]);
        app.form = result.form;
        app.keepPath(name);
        app.resetView();
        app.showTitle();
        if (result.short) {
            app.say("Not enough memory for all of the file");
        } else if (result.cut) app.say("Cells past row 9999 or column IV were left out");
        return true;
    }

    /// The sheet written to the file, and the file's name kept. Whether it
    /// was.
    fn save(app: *App, name: [*:0]const u8) bool {
        const dl = app.dl;
        const bytes = csv.write(app.sheet, app.form) orelse {
            app.tell("No memory to save %s", name);
            return false;
        };
        defer if (bytes.len > 0) app.sys.FreeVec(@constCast(bytes.ptr));
        const file = dl.Open(name, dos.MODE_NEWFILE) orelse {
            app.tell("Cannot write %s", name);
            return false;
        };
        const wrote = if (bytes.len == 0) 0 else dl.Write(file, bytes.ptr, @intCast(bytes.len));
        const closed = dl.Close(file);
        if (wrote != bytes.len or !closed) {
            app.tell("Cannot write %s", name);
            return false;
        }
        app.sheet.changed = false;
        app.keepPath(name);
        app.showTitle();
        return true;
    }

    fn keepPath(app: *App, name: [*:0]const u8) void {
        if (name == @as([*:0]const u8, &app.path)) return;
        var at: usize = 0;
        while (name[at] != 0 and at < app.path.len) : (at += 1) app.path[at] = name[at];
        app.path[at] = 0;
    }

    /// A file asked for with asl's requester, into `into`. False when the
    /// requester was cancelled or could not be had.
    fn askFile(app: *App, title: [*:0]const u8, saving: bool, into: *[path_size:0]u8) bool {
        if (app.asl_lib == null) app.asl_lib = app.sys.OpenLibrary(asl.ASLNAME, 0);
        const ab: *AslBase = @ptrCast(app.asl_lib orelse {
            app.tell("No %s", asl.ASLNAME);
            return false;
        });
        // The drawer and the name the file has now, to begin with.
        var drawer: [path_size:0]u8 = @splat(0);
        var file: [*:0]const u8 = "";
        if (app.path[0] != 0) {
            drawer = app.path;
            file = app.dl.FilePart(&app.path);
            const path_end = @intFromPtr(app.dl.PathPart(&drawer)) - @intFromPtr(&drawer);
            drawer[path_end] = 0;
        }
        const handle = ab.AllocAslRequest(asl.ASL_FileRequest, &[_]TagItem{
            .{ .tag = asl.ASLFR_TitleText, .data = @intFromPtr(title) },
            .{ .tag = asl.ASLFR_Window, .data = @intFromPtr(app.window) },
            .{ .tag = asl.ASLFR_SleepWindow, .data = 1 },
            .{ .tag = asl.ASLFR_InitialDrawer, .data = @intFromPtr(&drawer) },
            .{ .tag = asl.ASLFR_InitialFile, .data = @intFromPtr(file) },
            .{ .tag = asl.ASLFR_DoSaveMode, .data = @intFromBool(saving) },
            .{},
        }) orelse return false;
        defer ab.FreeAslRequest(handle);
        if (!ab.AslRequest(handle, null)) return false;
        const req: *asl.FileRequester = @ptrCast(@alignCast(handle));
        const chosen = req.file orelse return false;
        if (chosen[0] == 0) return false;
        into.* = @splat(0);
        if (req.drawer) |dir| {
            var at: usize = 0;
            while (dir[at] != 0 and at < into.len) : (at += 1) into[at] = dir[at];
        }
        return app.dl.AddPart(into, chosen, into.len);
    }

    /// Saved under its own name, or one asked for when it has none.
    /// Whether it was.
    fn saveKept(app: *App) bool {
        if (app.path[0] == 0) return app.saveAs();
        return app.save(&app.path);
    }

    fn saveAs(app: *App) bool {
        var name: [path_size:0]u8 = undefined;
        if (!app.askFile("Save the sheet as", true, &name)) return false;
        return app.save(&name);
    }

    /// Whether the sheet may go: it has not changed, or it was saved, or
    /// the requester was told not to.
    fn mayLeave(app: *App) bool {
        if (!app.settle()) return false;
        if (!app.sheet.changed) return true;
        const easy = intuition.requesters.EasyStruct{
            .title = "Sheet",
            .text_format = "The sheet has changed.\nSave it first?",
            .gadget_format = "Save|Don't save|Cancel",
        };
        return switch (app.ib.EasyRequestArgs(app.window, &easy, null, null)) {
            1 => app.saveKept(),
            2 => true,
            else => false,
        };
    }

    // --- the clipboard ----------------------------------------------------------

    fn iff(app: *App) ?*IFFParseBase {
        if (app.iff_lib == null) app.iff_lib = app.sys.OpenLibrary(iffparse.IFFPARSENAME, 0);
        return @ptrCast(app.iff_lib orelse return null);
    }

    /// The picked cells' shown values as text, a line per row split by
    /// tabs, in memory of its own; null for none or no memory.
    fn areaText(app: *App) ?[]u8 {
        const sheet = app.sheet;
        const reach = sheet.extent();
        if (reach.rows == 0) return null;
        const bottom = @min(app.area.bottom, reach.rows - 1);
        const right = @min(app.area.right, reach.cols - 1);
        if (bottom < app.area.top or right < app.area.left) return null;
        var out: exec.Array(u8) = .{};
        var failed = false;
        var row = app.area.top;
        while (row <= bottom) : (row += 1) {
            var col = app.area.left;
            while (col <= right) : (col += 1) {
                if (col > app.area.left) failed = !out.append(app.sys, '\t') or failed;
                const cell = sheet.find(row, col) orelse continue;
                var digits: [32]u8 = undefined;
                const shown = cells.shownText(cell.value, number.max_digits, &digits);
                failed = !out.appendSlice(app.sys, shown) or failed;
            }
            failed = !out.append(app.sys, '\n') or failed;
        }
        if (failed) {
            out.deinit(app.sys);
            return null;
        }
        return out.slice();
    }

    /// The picked cells kept for Sheet and put on the clipboard as text.
    fn copy(app: *App) bool {
        if (!app.sheet.copyBlock(app.area, &app.block)) {
            app.block.deinit(app.sys);
            app.say("No memory to copy that much");
            return false;
        }
        if (app.clip) |old| app.sys.FreeVec(old);
        app.clip = null;
        app.clip_len = 0;
        const text = app.areaText() orelse return true;
        const ip = app.iff() orelse {
            app.sys.FreeVec(text.ptr);
            return true;
        };
        if (iffparse.clip.writeText(ip, text)) {
            app.clip = text.ptr;
            app.clip_len = @intCast(text.len);
        } else app.sys.FreeVec(text.ptr);
        return true;
    }

    fn cut(app: *App) void {
        if (!app.copy()) return;
        if (!app.sheet.clear(app.area)) app.say("Not enough memory to clear all of it");
        app.followChanges();
    }

    /// What the clipboard holds put in at the current cell: Sheet's own
    /// cells when it is what Sheet put there, else its text.
    fn paste(app: *App) void {
        const text = if (app.iff()) |ip| iffparse.clip.readText(app.sys, ip) else null;
        defer if (text) |held| app.sys.FreeVec(held.ptr);
        const own = if (text) |held| (app.clip != null and cells.sameText(held, app.clip.?[0..app.clip_len])) else app.block.entries.len > 0;
        var ok = true;
        if (own and (app.block.rows > 0)) {
            ok = app.sheet.pasteBlock(&app.block, app.row, app.col);
            app.area = .{
                .top = app.row,
                .left = app.col,
                .bottom = @min(app.row + app.block.rows - 1, max_rows - 1),
                .right = @min(app.col + app.block.cols - 1, max_cols - 1),
            };
        } else if (text) |held| {
            ok = app.sheet.pasteText(held, app.row, app.col);
        } else {
            app.ib.DisplayBeep(app.screen);
            return;
        }
        if (!ok) app.say("Not enough memory to paste all of it");
        app.followChanges();
    }

    // --- the menus ----------------------------------------------------------------

    /// Rows or columns put in or taken out where the cells picked are.
    fn shift(app: *App, columns: bool, insert: bool) void {
        const at = if (columns) app.area.left else app.area.top;
        const count = if (columns) app.area.right - app.area.left + 1 else app.area.bottom - app.area.top + 1;
        if (count >= (if (columns) max_cols else max_rows)) {
            app.ib.DisplayBeep(app.screen);
            return;
        }
        switch (app.sheet.shiftLines(columns, at, count, insert)) {
            .done => {},
            .no_room => {
                app.say(if (columns) "No room: the last columns have something in them" else "No room: the last rows have something in them");
                return;
            },
            .no_memory => app.say("Not enough memory for that"),
        }
        if (columns) {
            // The columns' widths move with them.
            const widths = &app.col_width;
            if (insert) {
                var col: u32 = max_cols - 1;
                while (col >= at + count) : (col -= 1) widths[col] = widths[col - count];
                var opened = at;
                while (opened < at + count) : (opened += 1) widths[opened] = app.defaultWidth();
            } else {
                var col = at;
                while (col + count < max_cols) : (col += 1) widths[col] = widths[col + count];
                while (col < max_cols) : (col += 1) widths[col] = app.defaultWidth();
            }
        }
        app.followChanges();
    }

    fn widen(app: *App, by: i32) void {
        var col = app.area.left;
        while (col <= app.area.right) : (col += 1) {
            const width = @as(i32, app.col_width[col]) + by;
            app.col_width[col] = @intCast(@max(app.char_w * 2, @min(width, 600)));
        }
        app.draw();
        app.followBars();
    }

    /// A menu item picked. False to end.
    fn picked(app: *App, menu_number: u32) bool {
        if (!app.settle()) return true;
        const sheet = app.sheet;
        switch (mn.MENUNUM(menu_number)) {
            MENU_PROJECT => switch (mn.ITEMNUM(menu_number)) {
                ITEM_NEW => if (app.mayLeave()) {
                    sheet.clearAll();
                    app.path[0] = 0;
                    app.form = .{};
                    app.resetView();
                    app.showTitle();
                },
                ITEM_OPEN => if (app.mayLeave()) {
                    var name: [path_size:0]u8 = undefined;
                    if (app.askFile("Open a sheet", false, &name)) _ = app.load(&name, false);
                },
                ITEM_SAVE => _ = app.saveKept(),
                ITEM_SAVE_AS => _ = app.saveAs(),
                ITEM_QUIT => return !app.mayLeave(),
                else => {},
            },
            MENU_EDIT => switch (mn.ITEMNUM(menu_number)) {
                ITEM_UNDO => {
                    if (!sheet.undo()) app.ib.DisplayBeep(app.screen);
                    app.followChanges();
                },
                ITEM_REDO => {
                    if (!sheet.redo()) app.ib.DisplayBeep(app.screen);
                    app.followChanges();
                },
                ITEM_CUT => app.cut(),
                ITEM_COPY => _ = app.copy(),
                ITEM_PASTE => app.paste(),
                ITEM_CLEAR => {
                    if (!sheet.clear(app.area)) app.say("Not enough memory to clear all of it");
                    app.followChanges();
                },
                ITEM_FILL_DOWN, ITEM_FILL_RIGHT => {
                    const down = mn.ITEMNUM(menu_number) == ITEM_FILL_DOWN;
                    if ((down and app.area.bottom == app.area.top) or (!down and app.area.right == app.area.left)) {
                        app.ib.DisplayBeep(app.screen);
                    } else if (!sheet.fill(app.area, down)) app.say("Not enough memory to fill all of it");
                    app.followChanges();
                },
                ITEM_SELECT_ALL => app.pickAll(),
                else => {},
            },
            MENU_SHEET => switch (mn.ITEMNUM(menu_number)) {
                ITEM_INSERT_ROWS => app.shift(false, true),
                ITEM_DELETE_ROWS => app.shift(false, false),
                ITEM_INSERT_COLUMNS => app.shift(true, true),
                ITEM_DELETE_COLUMNS => app.shift(true, false),
                ITEM_WIDER => app.widen(app.char_w * 2),
                ITEM_NARROWER => app.widen(-app.char_w * 2),
                else => {},
            },
            else => {},
        }
        return true;
    }

    // --- keys ---------------------------------------------------------------------

    /// A character typed while the cells have the keyboard.
    fn keyed(app: *App, code: u32) void {
        if (!app.settle()) return;
        switch (code) {
            '\r' => app.moveBy(1, 0),
            '\t' => app.moveBy(0, 1),
            // Backspace begins the cell's text again, from nothing.
            0x08 => app.startEdit(""),
            0x7F => {
                if (!app.sheet.clear(app.area)) app.say("Not enough memory to clear all of it");
                app.followChanges();
            },
            0x1B => app.moveTo(app.row, app.col),
            0x03 => _ = app.copy(),
            0x18 => app.cut(),
            0x16 => app.paste(),
            0x1A => _ = app.picked(mn.FULLMENUNUM(MENU_EDIT, ITEM_UNDO, mn.NOSUB)),
            0x19 => _ = app.picked(mn.FULLMENUNUM(MENU_EDIT, ITEM_REDO, mn.NOSUB)),
            0x01 => app.pickAll(),
            else => if (code >= 0x20 and code <= 0xFF and !(code >= 0x80 and code < 0xA0)) {
                const typed = [1]u8{@intCast(code)};
                app.startEdit(&typed);
            },
        }
    }

    /// A key that is not a character: the cursor keys and their kin; with
    /// Shift, the cursor keys and Page Up and Down move the far corner of
    /// the cells picked instead of the current cell.
    fn rawKeyed(app: *App, code: u32, shifted: bool) void {
        if (code & 0x80 != 0) return;
        switch (code) {
            raw_up, raw_down, raw_left, raw_right, raw_page_up, raw_page_down, raw_home, raw_end, raw_f2 => {},
            else => return,
        }
        if (!app.settle()) return;
        const page: i32 = @intCast(app.visibleRows());
        if (shifted) switch (code) {
            raw_up => return app.extendBy(-1, 0),
            raw_down => return app.extendBy(1, 0),
            raw_left => return app.extendBy(0, -1),
            raw_right => return app.extendBy(0, 1),
            raw_page_up => return app.extendBy(-page, 0),
            raw_page_down => return app.extendBy(page, 0),
            else => {},
        };
        switch (code) {
            raw_up => app.moveBy(-1, 0),
            raw_down => app.moveBy(1, 0),
            raw_left => app.moveBy(0, -1),
            raw_right => app.moveBy(0, 1),
            raw_page_up => {
                app.top_row -|= @intCast(page);
                app.moveBy(-page, 0);
            },
            raw_page_down => {
                app.top_row = @min(app.top_row + @as(u32, @intCast(page)), max_rows - 1);
                app.moveBy(page, 0);
            },
            raw_home => app.moveTo(app.row, 0),
            raw_end => {
                // The last cell of the row with something in it.
                var last: u32 = 0;
                var col: u32 = 0;
                while (col < max_cols) : (col += 1) {
                    if (app.sheet.find(app.row, col) != null) last = col;
                }
                app.moveTo(app.row, last);
            },
            raw_f2 => app.startEdit(null),
            else => {},
        }
    }

    // --- the window's messages ----------------------------------------------------

    /// What the line at the top finished with: Escape, its text put back;
    /// anything else, its text kept and the cell the key points to made
    /// current - the one below for Return (`entryKey` turns Tab and the
    /// cursor keys into their directions).
    fn entryDone(app: *App, code: u32) void {
        if (code == raw_escape) {
            app.showCurrent();
            return;
        }
        if (!app.commit()) return;
        switch (code) {
            raw_up => app.moveBy(-1, 0),
            raw_right => app.moveBy(0, 1),
            raw_left => app.moveBy(0, -1),
            else => app.moveBy(1, 0),
        }
    }

    /// Everything the window has to say. False to end.
    fn windowMessages(app: *App) bool {
        var code: u32 = 0;
        var input = wc.WmHandleInput{ .code = &code };
        while (true) {
            const word = app.ib.SendMessage(app.object, @ptrCast(&input));
            if (word == wc.WMHI_LASTMSG) return true;
            // What the word does not say: the keys held, the gadget.
            var qualifier: usize = 0;
            var gadget: usize = wc.WINDOW_NOGADGET;
            _ = app.ib.GetAttr(wc.WINDOWA_Qualifier, app.object, &qualifier);
            _ = app.ib.GetAttr(wc.WINDOWA_GadgetID, app.object, &gadget);
            const shifted = qualifier & (ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT) != 0;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => if (app.mayLeave()) return false,
                wc.WMHI_MENUPICK => {
                    const menu_number: u32 = @truncate(word & wc.WMHI_MENUMASK);
                    if (menu_number != mn.MENUNULL and !app.picked(menu_number)) return false;
                },
                wc.WMHI_GADGETDOWN => if (word & wc.WMHI_GADGETMASK == ID_GRID) app.press(shifted),
                wc.WMHI_GADGETUP => switch (word & wc.WMHI_GADGETMASK) {
                    ID_GRID => {
                        app.dragTo();
                        app.drag = .none;
                        // Pressed and let go on the current cell: edited.
                        if (app.press_again) {
                            app.press_again = false;
                            app.startEdit(null);
                        }
                    },
                    ID_ENTRY => app.entryDone(code),
                    ID_VERT, ID_HORIZ => app.followScrollers(),
                    else => {},
                },
                // A drag on the cells, or a bar moved.
                wc.WMHI_IDCMPUPDATE => switch (gadget) {
                    ID_GRID => if (app.drag != .none) app.dragTo(),
                    ID_VERT, ID_HORIZ => app.followScrollers(),
                    else => {},
                },
                wc.WMHI_VANILLAKEY => app.keyed(@truncate(word & wc.WMHI_KEYMASK)),
                wc.WMHI_RAWKEY => app.rawKeyed(@truncate(word & wc.WMHI_KEYMASK), shifted),
                wc.WMHI_MOUSEWHEEL => {
                    const notches: i16 = @bitCast(@as(u16, @truncate(word & 0xFFFF)));
                    app.scrollRows(@as(i32, notches) * 3);
                },
                wc.WMHI_NEWSIZE => {
                    app.fitPicture();
                    app.reveal(app.row, app.col);
                    app.draw();
                    app.followBars();
                },
                wc.WMHI_NEWPREFS => {
                    app.ib.FreeScreenDrawInfo(app.screen, app.draw_info);
                    app.draw_info = app.ib.GetScreenDrawInfo(app.screen);
                    app.takeLook();
                    app.draw();
                    app.followBars();
                },
                else => {},
            }
        }
    }

    /// Files let go on the window: each opened, as Open would, once the
    /// sheet before it may go.
    fn dropped(app: *App) void {
        var name: [path_size:0]u8 = undefined;
        while (app.drop.next(app.dl, &name)) |file| {
            if (file.is_drawer) continue;
            app.ib.ActivateWindow(app.window);
            if (app.mayLeave()) _ = app.load(file.name, false);
        }
    }

    fn signalOf(app: *App) u32 {
        var mask: usize = 0;
        _ = app.ib.GetAttr(wc.WINDOWA_SigMask, app.object, &mask);
        return @truncate(mask);
    }

    fn run(app: *App) void {
        while (true) {
            const window_signal = app.signalOf();
            const drop_signal = app.drop.signal();
            const got = app.sys.Wait(window_signal | drop_signal | exec.SIGBREAKF_CTRL_C);
            if (got & exec.SIGBREAKF_CTRL_C != 0 and app.mayLeave()) return;
            if (got & drop_signal != 0) app.dropped();
            if (!app.windowMessages()) return;
            if (app.sheet.changed != app.shown_changed) app.showTitle();
        }
    }
};

/// What the status line adds up: the numbers among the cells picked.
const Totals = struct {
    sum: f64 = 0,
    count: u32 = 0,

    pub fn visit(totals: *Totals, value: eval.Value) void {
        if (value.kind != .number) return;
        totals.sum += value.number;
        totals.count += 1;
    }
};

/// The line at the top's own edit hook, run on intuition's input handler
/// after its global one: Tab and Shift-Tab, and the cursor keys up and
/// down, end the line as Return does, each with the raw key of its
/// direction as the code - so the program keeps the text and moves, where
/// Tab would hand the keyboard to a next gadget and say nothing. It changes
/// the edit and nothing else.
fn entryKey(_: *sdk.utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const work: *sg.SGWork = @ptrCast(@alignCast(object orelse return 0));
    const command: *const u32 = @ptrCast(@alignCast(message orelse return 0));
    if (command.* != sg.SGH_KEY) return 0;
    const shifted = work.event.qualifier & (ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT) != 0;
    if (work.actions & (sg.SGA_NEXTACTIVE | sg.SGA_PREVACTIVE) != 0) {
        work.actions &= ~(sg.SGA_NEXTACTIVE | sg.SGA_PREVACTIVE);
        work.code = if (shifted) raw_left else raw_right;
        return 1;
    }
    if (work.event.code == raw_up or work.event.code == raw_down) {
        work.actions |= sg.SGA_END;
        work.code = work.event.code;
    }
    return 1;
}

const entry_hook = sdk.utility.Hook{ .entry = entryKey };

/// The cells from one corner to the other, whichever way round.
fn between(row: u32, col: u32, other_row: u32, other_col: u32) cells.Area {
    return .{
        .top = @min(row, other_row),
        .left = @min(col, other_col),
        .bottom = @max(row, other_row),
        .right = @max(col, other_col),
    };
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
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);

    // The libraries, open until the window object is gone.
    const names = [_][*:0]const u8{ intuition.INTUITIONNAME, graphics.GRAPHICSNAME, st.STRING_LIBRARY, tx.TEXT_LIBRARY, cv.CANVAS_LIBRARY, sr.SCROLLER_LIBRARY };
    var libraries: [names.len]*exec.Library = undefined;
    var opened: usize = 0;
    defer {
        while (opened > 0) {
            opened -= 1;
            sys.CloseLibrary(libraries[opened]);
        }
    }
    for (names) |name| {
        libraries[opened] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{name});
            return dos.RETURN_FAIL;
        };
        opened += 1;
    }
    const ib: *IntuitionBase = @ptrCast(libraries[0]);
    const gb: *GraphicsBase = @ptrCast(libraries[1]);

    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);
    const draw_info = ib.GetScreenDrawInfo(screen);

    const sheet = cells.Sheet.create(sys) orelse {
        ib.FreeScreenDrawInfo(screen, draw_info);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer sheet.destroy();

    // The cells are a picture the size of the gadget's box, made anew
    // whenever the window is sized; this is the size it starts at, and
    // what it asks the layout for.
    const picture_w = 560;
    const picture_h = 300;
    const grid = ib.NewObjectTagList(null, cv.CANVAS_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_GRID },
        .{ .tag = gc.GA_Immediate, .data = 1 },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = cv.CANVAS_Width, .data = picture_w },
        .{ .tag = cv.CANVAS_Height, .data = picture_h },
        .{ .tag = icc.ICA_TARGET, .data = icc.ICTARGET_IDCMP },
        .{},
    });
    const name_box = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_NAME },
        .{ .tag = tx.TEXT_Text, .data = @intFromPtr("A1") },
        .{ .tag = tx.TEXT_Border, .data = 1 },
        .{ .tag = tx.TEXT_Justification, .data = tx.TEXT_JUSTIFY_CENTER },
        .{},
    });
    const entry = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_ENTRY },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = gc.STRINGA_MaxChars, .data = cells.max_text + 1 },
        .{ .tag = gc.STRINGA_EditHook, .data = @intFromPtr(&entry_hook) },
        .{},
    });
    const status = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_STATUS },
        .{ .tag = tx.TEXT_Text, .data = @intFromPtr("") },
        .{},
    });
    const parts = [_]?*Object{ grid, name_box, entry, status };
    var whole = true;
    for (parts) |part| whole = whole and part != null;
    const top_line = if (whole) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 4 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(name_box) },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
        .{ .tag = lg.CHILDA_MinWidth, .data = 72 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(entry) },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 1 },
        .{},
    }) else null;
    const layout = if (top_line != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Margin, .data = 2 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 2 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(top_line) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(grid) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 1 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(status) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{},
    }) else null;
    const made_layout = layout orelse {
        // What a layout took is its own; only what none took goes here.
        if (top_line) |line| {
            ib.DisposeObject(line);
            ib.DisposeObject(grid);
            ib.DisposeObject(status);
        } else for (parts) |part| ib.DisposeObject(part);
        ib.FreeScreenDrawInfo(screen, draw_info);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Sheet") },
        .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr(SCREEN_TITLE) },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_InnerWidth, .data = 600 },
        .{ .tag = wn.WA_InnerHeight, .data = 380 },
        .{ .tag = wn.WA_AutoAdjust, .data = 1 },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_IDCMPUPDATE | wn.IDCMP_NEWSIZE | wn.IDCMP_RAWKEY | wn.IDCMP_MOUSEWHEEL | wn.IDCMP_NEWPREFS },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(made_layout) },
        // The bars tell the window as they move, and are let go of.
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
        .{},
    }) orelse {
        ib.DisposeObject(made_layout);
        ib.FreeScreenDrawInfo(screen, draw_info);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.DisposeObject(object);

    var picture: usize = 0;
    _ = ib.GetAttr(cv.CANVAS_RastPort, grid.?, &picture);

    // The program's state is large for a stack of 16 KiB: it lives in
    // memory of its own.
    const app: *App = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(App), exec.MEMF_ANY) orelse {
        ib.FreeScreenDrawInfo(screen, draw_info);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }));
    defer sys.FreeVec(app);
    app.* = .{
        .sys = sys,
        .dl = dl,
        .ib = ib,
        .gb = gb,
        .screen = screen,
        .draw_info = draw_info,
        .object = object,
        .name_box = name_box.?,
        .entry = entry.?,
        .grid = grid.?,
        .status = status.?,
        .rp = @ptrFromInt(picture),
        .picture_w = picture_w,
        .picture_h = picture_h,
        .sheet = sheet,
    };
    defer ib.FreeScreenDrawInfo(screen, app.draw_info);
    defer app.deinit();
    app.takeLook();
    const width = app.defaultWidth();
    for (&app.col_width) |*one| one.* = width;

    var open = wc.WmOpen{};
    const opened_window = ib.SendMessage(object, @ptrCast(&open));
    if (opened_window == 0) {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }
    app.window = @ptrFromInt(opened_window);
    var vert: usize = 0;
    var horiz: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_VertScroller, object, &vert);
    _ = ib.GetAttr(wc.WINDOWA_HorizScroller, object, &horiz);
    app.bars = .{ .vert = @ptrFromInt(vert), .horiz = @ptrFromInt(horiz) };
    // The picture as big as the grid's box, now that it has one.
    app.fitPicture();

    // The menus; a sheet without them still works, so a strip that will
    // not go on is left off rather than given up over.
    const strip = blk: {
        const made = ib.CreateMenusA(&menus, null) orelse break :blk null;
        if (!ib.LayoutMenusA(made, screen, null) or !ib.SetMenuStrip(app.window, made)) {
            ib.FreeMenus(made);
            break :blk null;
        }
        break :blk made;
    };
    defer if (strip) |made| {
        ib.ClearMenuStrip(app.window);
        ib.FreeMenus(made);
    };

    // Taken off the desktop's list before the window closes.
    app.drop.add(sys, app.window);
    defer app.drop.remove();
    if (dos.rdargs.string(argv[0])) |name| {
        // A name that is not there yet is where the sheet will be saved.
        if (!app.load(name, true)) app.keepPath(name);
    }
    app.moveTo(app.row, app.col);
    app.showTitle();
    app.run();
    return dos.RETURN_OK;
}
