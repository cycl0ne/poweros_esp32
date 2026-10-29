// SPDX-License-Identifier: MIT
//! listbrowser.gadget: a list in columns under headings, sorted by the
//! heading pressed, its rows a tree whose branches open and close.
//!
//! **The rows** are an exec `List` of `Row`s, the program's and not
//! copied (`LISTBROWSER_Rows`): each holds the text of every column, how
//! deep it is in the tree, and whether its branch is open. A row followed
//! by deeper rows is the head of a branch - those rows, down to the next
//! one as shallow as itself - and has a small triangle at the start of its
//! first column: a press on it opens the branch or closes it. Rows of a
//! closed branch are not shown. `allocRow` makes a row with copies of its
//! texts in one allocation; `freeRows` gives a whole list of them back.
//!
//! **The columns** (`LISTBROWSER_Columns`) are an array of `Column`s ended
//! by one with no title: each a heading, its share of the width, and how
//! its text stands (`COLUMN_RIGHT`) and is compared (`COLUMN_NUMBER`).
//!
//! **Sorting.** A press on a heading sorts the rows by its column, and a
//! second press on the same heading turns the order round; a small
//! triangle in the heading says which way. The program's list is put in
//! that order: every row keeps its branch under it, and the rows of a
//! branch are sorted among themselves. Text is compared in any case, a
//! `COLUMN_NUMBER` column by the number its text starts with - numbers
//! joined by `:` read as one, so a column of lengths (`3:45`, `1:02:33`)
//! sorts by how long each is.
//! `LISTBROWSER_SortColumn` and `LISTBROWSER_SortReverse` sort from the
//! program; a press on a heading tells the target both, since the
//! program's list then stands in another order.
//!
//! **Choosing.** A press on a row selects it, a drag moves the selection,
//! scrolling past the top or the bottom; let go, the gadget reports the
//! row's place in the list as the code - with `LISTBROWSER_DOUBLE` added
//! when it was the second press of a double-click - and tells its target
//! `LISTBROWSER_Selected`. The wheel moves the view three rows a notch,
//! and the key of `GA_Key` moves the selection down a row (up with Shift).
//!
//! **Moving rows.** Made with `LISTBROWSER_Reorder`, a row pressed and
//! dragged up or down moves in the program's list rather than the
//! selection moving: it goes past each row the pointer reaches, and past
//! the top or the bottom the view scrolls on with it. Let go somewhere
//! else, the code is its new place with `LISTBROWSER_MOVED` added, and the
//! target is told `LISTBROWSER_Moved`, the place it came from, with
//! `LISTBROWSER_Selected`, the place it went to; the rows stand as moved,
//! sorted by no column. A tree keeps choosing: its rows move with their
//! branches, which a drag does not.
//!
//! **A marked row** (`ROW_MARKED`) is the one the program has in use - the
//! song being heard: its texts are bold, and its first column starts with
//! a small triangle pointing right.
//!
//! **A scroller in the window's border** instead of its own: made with
//! `LISTBROWSER_Scrollers` false, the gadget is the field alone, and tells
//! its target where its view is - `LISTBROWSER_Top`, `LISTBROWSER_Total`
//! and `LISTBROWSER_Visible`, in rows shown - each time one of them
//! changes. A scroller in the border whose `ICA_TARGET` is the gadget and
//! whose `ICA_MAP` turns `SCROLLER_Top` into `LISTBROWSER_Top` moves the
//! view as it is dragged; the program sets the scroller from what it is
//! told.
//!
//! While the program changes the list - adds rows, removes them, opens a
//! branch by hand - it takes it away from the gadget (`LISTBROWSER_Rows`
//! set to `LISTBROWSER_DETACH`) and gives it back afterwards. Given back,
//! the list keeps its view and its selection - unless the selected row
//! was taken out - where another list starts at its top with none.
//!
//!   const columns = [_]lb.Column{
//!       .{ .title = "Name", .weight = 3 },
//!       .{ .title = "Size", .weight = 1, .flags = lb.COLUMN_RIGHT | lb.COLUMN_NUMBER },
//!       .{},
//!   };
//!   var rows: exec.List = .{};
//!   rows.init(.unknown);
//!   const row = lb.allocRow(sys, &.{ "Startup-Sequence", "1214" }, 0).?;
//!   sys.AddTail(&rows, &row.node);
//!   const browser = ib.NewObjectTagList(null, lb.LISTBROWSER_CLASS, &.{
//!       .{ .tag = lb.LISTBROWSER_Columns, .data = @intFromPtr(&columns) },
//!       .{ .tag = lb.LISTBROWSER_Rows, .data = @intFromPtr(&rows) },
//!       .{},
//!   });
//!   ...
//!   lb.freeRows(sys, &rows); // once the gadget is gone

const gadgets = @import("gadgets.zig");
const exec = @import("../exec/exec.zig");
const ExecBase = @import("../../interface/exec.zig").ExecBase;

/// What a program opens, and the class it then asks for.
pub const LISTBROWSER_LIBRARY = "gadgets/listbrowser.gadget";
pub const LISTBROWSER_CLASS = "listbrowser.gadget";

pub const LISTBROWSER_Dummy = gadgets.GADGETS_Dummy + 31 * gadgets.GADGETS_Step;
/// The columns: `[*]const Column`, ended by one with no title, not
/// copied. Made and set.
pub const LISTBROWSER_Columns = LISTBROWSER_Dummy + 0x01;
/// The rows: a `*exec.List` of `Row`s, not copied, or
/// `LISTBROWSER_DETACH` while the program changes it. Made, set and read.
pub const LISTBROWSER_Rows = LISTBROWSER_Dummy + 0x02;
/// The selected row's place in the list, counting every row, shown or
/// not; `LISTBROWSER_NONE` for none. Made, set and read; told to the
/// target when a press ends.
pub const LISTBROWSER_Selected = LISTBROWSER_Dummy + 0x03;
/// The selected row itself, `?*Row`. Read only.
pub const LISTBROWSER_SelectedRow = LISTBROWSER_Dummy + 0x04;
/// The first row shown, counting the rows that are shown. Made, set and
/// read.
pub const LISTBROWSER_Top = LISTBROWSER_Dummy + 0x05;
/// The column the rows are sorted by, from 0, or `LISTBROWSER_NONE` while
/// they stand as given. Made, set and read; set, it sorts them. Told to
/// the target, with `LISTBROWSER_SortReverse`, when a press on a heading
/// has sorted them.
pub const LISTBROWSER_SortColumn = LISTBROWSER_Dummy + 0x06;
/// Bool: sorted from the end - Z to A, the largest first. Made, set and
/// read; with `LISTBROWSER_SortColumn`.
pub const LISTBROWSER_SortReverse = LISTBROWSER_Dummy + 0x07;
/// Bool: the headings shown (true). Made only.
pub const LISTBROWSER_Headings = LISTBROWSER_Dummy + 0x08;
/// Bool, made only: its own scroller at its right. True unless said
/// otherwise; false for a program that puts one in the window's border.
pub const LISTBROWSER_Scrollers = LISTBROWSER_Dummy + 0x09;
/// How many rows are shown, branches closed left out, and how many fit
/// the view. Read only; told to the target, with the top, when any of
/// them changes.
pub const LISTBROWSER_Total = LISTBROWSER_Dummy + 0x0A;
pub const LISTBROWSER_Visible = LISTBROWSER_Dummy + 0x0B;
/// Bool: a row dragged moves in the list (false: the selection moves).
/// Made and set; a list that is a tree is not moved.
pub const LISTBROWSER_Reorder = LISTBROWSER_Dummy + 0x0C;
/// Where the row the last press moved was before it, counting every row;
/// `LISTBROWSER_NONE` when that press moved none. Read only; told to the
/// target with `LISTBROWSER_Selected` when a press ends.
pub const LISTBROWSER_Moved = LISTBROWSER_Dummy + 0x0D;

/// No row, no column.
pub const LISTBROWSER_NONE: u32 = 0xFFFF_FFFF;
/// `LISTBROWSER_Rows`: the list taken away while the program changes it.
pub const LISTBROWSER_DETACH: usize = ~@as(usize, 0);
/// Added to a press's code when it was the second of a double-click.
pub const LISTBROWSER_DOUBLE: u32 = 0x8000_0000;
/// Added to a press's code when it moved its row to another place.
pub const LISTBROWSER_MOVED: u32 = 0x4000_0000;

/// One column: its heading, its share of the width, and its flags. An
/// array of them ends with one whose `title` is null.
pub const Column = extern struct {
    title: ?[*:0]const u8 = null,
    /// Its share of the width: the columns' weights are added up and each
    /// gets its part of the room.
    weight: u16 = 1,
    flags: u16 = 0,
};

/// `Column.flags`: its text set to the right of the column - numbers.
pub const COLUMN_RIGHT: u16 = 1 << 0;
/// Compared by the number its text starts with, not as text; numbers
/// joined by `:` are one, each part sixty of the next - a length,
/// `1:02:33`, is its seconds.
pub const COLUMN_NUMBER: u16 = 1 << 1;
/// A press on its heading does not sort.
pub const COLUMN_NOSORT: u16 = 1 << 2;

/// One row: the text of each of the columns, how deep it is in the tree,
/// and whether its branch is open.
pub const Row = extern struct {
    /// On the list. Its name is the first column's text, for whoever walks
    /// the list by names.
    node: exec.Node = .{},
    /// A text for each column, as many as there are columns; null shows
    /// nothing.
    cells: [*]const ?[*:0]const u8,
    /// 0 at the top of the tree, one more for each branch it is in.
    depth: u16 = 0,
    /// `ROW_OPEN`, `ROW_MARKED`.
    flags: u16 = 0,
    /// The program's own.
    user_data: usize = 0,
};

/// `Row.flags`: its branch is open - the rows under it are shown.
pub const ROW_OPEN: u16 = 1 << 0;
/// `Row.flags`: the row the program has in use, drawn bold and marked at
/// its start. Set by the program, which then gives the list back
/// (`LISTBROWSER_Rows`, the same list) to have it drawn so.
pub const ROW_MARKED: u16 = 1 << 1;

/// A row holding copies of `texts`, one for each column, `depth` deep:
/// the row, the column pointers and the texts in one allocation, given
/// back with `freeRow`. Null without the memory.
pub fn allocRow(sys: *ExecBase, texts: []const [*:0]const u8, depth: u16) ?*Row {
    var size: usize = @sizeOf(Row) + texts.len * @sizeOf(?[*:0]const u8);
    for (texts) |text| size += lengthOf(text) + 1;
    const memory: [*]u8 = @ptrCast(sys.AllocVec(@intCast(size), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null);
    const row: *Row = @ptrCast(@alignCast(memory));
    const cells: [*]?[*:0]const u8 = @ptrCast(@alignCast(memory + @sizeOf(Row)));
    var at: usize = @sizeOf(Row) + texts.len * @sizeOf(?[*:0]const u8);
    for (texts, 0..) |text, i| {
        const length = lengthOf(text);
        for (0..length) |n| memory[at + n] = text[n];
        memory[at + length] = 0;
        cells[i] = @ptrCast(memory + at);
        at += length + 1;
    }
    row.* = .{ .cells = cells, .depth = depth };
    if (texts.len > 0) row.node.name = cells[0];
    return row;
}

/// A row from `allocRow` given back; it is off any list first.
pub fn freeRow(sys: *ExecBase, row: *Row) void {
    sys.FreeVec(@ptrCast(row));
}

/// Every row of `list` given back, each made by `allocRow`, and the list
/// left empty.
pub fn freeRows(sys: *ExecBase, list: *exec.List) void {
    while (sys.RemHead(list)) |node| {
        const row: *Row = @fieldParentPtr("node", node);
        freeRow(sys, row);
    }
}

fn lengthOf(text: [*:0]const u8) usize {
    var n: usize = 0;
    while (text[n] != 0) n += 1;
    return n;
}
