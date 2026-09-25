// SPDX-License-Identifier: MIT
//! layoutgclass: a gadget that sizes and places the gadgets in it.
//!
//! A layout holds its children in a row (`LORIENT_HORIZ`) or a column
//! (`LORIENT_VERT`, the default) and works out every child's box itself,
//! from its own box and what each child says it needs (`GM_DOMAIN`). A
//! layout is a child like any other, so rows in a column make a grid.
//!
//! Along the row or column each child first gets its minimum size; then
//! each grows towards its nominal size as far as the room allows; then
//! what is left is shared by weight (`CHILDA_WeightWidth` in a row,
//! `CHILDA_WeightHeight` in a column), no child past its maximum. Across,
//! a child with a weight fills the layout's height or width up to its
//! maximum; one with weight 0 keeps its nominal size, centred in a row and
//! against the left of a column.
//!
//! A child may have a label: text beside it on the left, in the window's
//! text pen and font. The labels of a column share one column of their
//! own, right-aligned, so the children after them line up.
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

pub const LORIENT_HORIZ: u32 = 1;
pub const LORIENT_VERT: u32 = 2;

pub const CHILDA_Dummy = LAYOUTA_Dummy + 0x0100;
/// Text beside the child, on its left: a C string, not copied.
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
