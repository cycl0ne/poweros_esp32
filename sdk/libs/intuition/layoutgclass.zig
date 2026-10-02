// SPDX-License-Identifier: MIT
//! layoutgclass: a gadget that sizes and places the gadgets in it.
//!
//! A layout holds its children in a row (`LORIENT_HORIZ`), a column
//! (`LORIENT_VERT`, the default) or a grid (`LORIENT_GRID`), and works
//! out every child's box itself,
//! from its own box and what each child says it needs (`GM_DOMAIN`). A
//! layout is a child like any other, so rows in a column make a grid.
//!
//! Along the row or column each child first gets its minimum size; then
//! each grows towards its nominal size as far as the room allows; then
//! what is left is shared by weight (`CHILDA_WeightWidth` in a row,
//! `CHILDA_WeightHeight` in a column), no child past its maximum. Across,
//! a child with a weight fills the layout's height or width up to its
//! maximum; one with weight 0 keeps its nominal size, centred in a row and
//! against the left of a column unless `CHILDA_Align` puts it elsewhere.
//!
//! A layout can be drawn in a frame with a title in its top edge
//! (`LAYOUTA_Frame`, `LAYOUTA_FrameTitle`): the frame and the title take
//! their room off the layout before the children are placed, so a window
//! of framed groups is written as layouts inside layouts.
//!
//! A child may have a label: text beside it on the left, in the window's
//! text pen and font. The labels of a column share one column of their
//! own, right-aligned, so the children after them line up.
//!
//! **A grid** (`LORIENT_GRID`, `LAYOUTA_Columns`) puts its children in
//! cells, in reading order unless a child names its cell (`CHILDA_Column`,
//! `CHILDA_Row`); one may cover several (`CHILDA_ColumnSpan`,
//! `CHILDA_RowSpan`). Every column is as wide as the widest child in it
//! needs and every row as tall as its tallest, so cells line up across
//! the whole grid; the room there is shared between columns and between
//! rows by the same rule as along a row, a column's weight being the
//! largest of its children's. A labelled child's label sits in the left of
//! its cell, and the label part of every cell in a column is as wide as
//! the widest label in that column - two columns of labelled fields line
//! up label with label and field with field. The children are kept in
//! row-by-row order, which is the order Tab goes through them.
//!
//! Given to a window as a gadget sized with `GA_RelWidth` and
//! `GA_RelHeight`, a layout fills its interior and lays everything out
//! again whenever the window changes size. When the window opens with it,
//! or it is added (`AddGList`), the window's smallest size becomes the one
//! the layout fits in (`WindowLimits`) - or the window's size then, if
//! that is smaller. A program that wants a larger smallest size sets it
//! afterwards.
//!
//! A layout made without a size is its nominal size, from the first time
//! it is laid out. Inside another layout its box is that layout's to set.
//!
//! What a child reports reaches the window in the child's own name: an
//! `IDCMP_GADGETUP` from a button in a layout carries that button, and its
//! `GA_ID`, not the layout's.
//!
//! Disposing of a layout disposes of its children.
//!
//! ```zig
//! const buttons = ib.NewObjectTagList(null, lg.LAYOUTGCLASS, &.{
//!     .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
//!     .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(ok) },
//!     .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(cancel) },
//!     .{},
//! });
//! const layout = ib.NewObjectTagList(null, lg.LAYOUTGCLASS, &.{
//!     .{ .tag = gc.GA_Left, .data = left_border },
//!     .{ .tag = gc.GA_Top, .data = top_border },
//!     .{ .tag = gc.GA_RelWidth, .data = @bitCast(@as(isize, -(left_border + right_border))) },
//!     .{ .tag = gc.GA_RelHeight, .data = @bitCast(@as(isize, -(top_border + bottom_border))) },
//!     .{ .tag = lg.LAYOUTA_Margin, .data = 4 },
//!     .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(name_field) },
//!     .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Name") },
//!     .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
//!     .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(buttons) },
//!     .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
//!     .{},
//! });
//! ```

const utility = @import("../utility/utility.zig");

/// The name to make one by, or to subclass.
pub const LAYOUTGCLASS = "layoutgclass";

pub const LAYOUTA_Dummy = utility.TAG_USER + 0x38000;
/// Pixels between one child and the next (4 unless told).
pub const LAYOUTA_Spacing = LAYOUTA_Dummy + 0x0002;
/// `LORIENT_HORIZ`: the children in a row; `LORIENT_VERT`: in a column.
pub const LAYOUTA_Orientation = LAYOUTA_Dummy + 0x0003;
/// Pixels between the layout's edges and its children, on all four sides
/// (0 unless told).
pub const LAYOUTA_Margin = LAYOUTA_Dummy + 0x0004;
/// A gadget to put at the end of the row or column; the layout's from
/// then on. The `CHILDA_` tags that follow it, up to the next one, are
/// about it.
pub const LAYOUTA_AddChild = LAYOUTA_Dummy + 0x0005;
/// Bool: a frame round the layout, with the children inside it. A ridge
/// unless `LAYOUTA_FrameType` says otherwise. This is what groups the
/// settings of a window into boxes.
pub const LAYOUTA_Frame = LAYOUTA_Dummy + 0x0006;
/// An `imageclass.FRAME_` kind for the frame, in place of the ridge.
pub const LAYOUTA_FrameType = LAYOUTA_Dummy + 0x0007;
/// Text in the frame's top edge, which breaks the frame's top line: a C
/// string, not copied. It gives the layout a frame if it has none.
pub const LAYOUTA_FrameTitle = LAYOUTA_Dummy + 0x0008;
/// How many columns a grid has (1 unless told).
pub const LAYOUTA_Columns = LAYOUTA_Dummy + 0x0009;
/// Bool: a row that has less room than its children's minimums need puts
/// them in rows beneath one another, a column in columns beside, each line
/// on its own with its children at their nominal size - so its smallest
/// width is its widest child's. How deep it is then depends on how long
/// its lines are: it answers `GM_DOMAIN` for the length it was last
/// given, and is asked again when that changes.
pub const LAYOUTA_Wrap = LAYOUTA_Dummy + 0x000A;

pub const LORIENT_HORIZ: u32 = 1;
pub const LORIENT_VERT: u32 = 2;
/// The children in cells, `LAYOUTA_Columns` across.
pub const LORIENT_GRID: u32 = 3;

pub const CHILDA_Dummy = LAYOUTA_Dummy + 0x0100;
/// Text beside the child, on its left: a C string, not copied.
///
/// An `_` in it marks the character after it as the key that works the
/// child: the `_` is not drawn, the character it marks is underlined, and
/// the child's `GA_Key` becomes that character. A label without one
/// leaves the key the child already has.
pub const CHILDA_Label = CHILDA_Dummy + 0x01;
/// How much of the spare width it takes in a row, against the others'
/// (100 unless told). 0 keeps it at its nominal width; across a column,
/// 0 keeps it at its nominal width rather than the column's.
pub const CHILDA_WeightWidth = CHILDA_Dummy + 0x02;
/// The same for height: the spare height of a column, and across a row.
pub const CHILDA_WeightHeight = CHILDA_Dummy + 0x03;
/// Its smallest size, in place of what it says: a button kept big enough
/// for a finger, say. 0 leaves the child's own.
pub const CHILDA_MinWidth = CHILDA_Dummy + 0x04;
pub const CHILDA_MinHeight = CHILDA_Dummy + 0x05;
/// Its largest size, in place of what it says. 0 leaves the child's own.
pub const CHILDA_MaxWidth = CHILDA_Dummy + 0x06;
pub const CHILDA_MaxHeight = CHILDA_Dummy + 0x07;
/// Where it sits in its room when it is smaller than the room: one
/// `CALIGN_` across and one down, or'd together. Either left out is where
/// a child sits without it: centred down a row, at the left across a
/// column, centred down a line taller than it.
pub const CHILDA_Align = CHILDA_Dummy + 0x08;

/// `CHILDA_Align`, across.
pub const CALIGN_LEFT: u32 = 1;
pub const CALIGN_HCENTRE: u32 = 2;
pub const CALIGN_RIGHT: u32 = 3;
/// `CHILDA_Align`, down.
pub const CALIGN_TOP: u32 = 1 << 4;
pub const CALIGN_VCENTRE: u32 = 2 << 4;
pub const CALIGN_BOTTOM: u32 = 3 << 4;

/// In a grid, the column and the row of its cell, from 0. Either left out
/// is the next free cell in reading order after the child before.
pub const CHILDA_Column = CHILDA_Dummy + 0x09;
pub const CHILDA_Row = CHILDA_Dummy + 0x0A;
/// In a grid, how many columns and rows its cell covers (1 unless told).
pub const CHILDA_ColumnSpan = CHILDA_Dummy + 0x0B;
pub const CHILDA_RowSpan = CHILDA_Dummy + 0x0C;
