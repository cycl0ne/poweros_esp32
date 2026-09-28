// SPDX-License-Identifier: MIT
//! listview.gadget: a scrolling list of the nodes of an exec `List`, a
//! line each, of which one may be selected.
//!
//! Each line is a node's name, or whatever `LISTVIEW_CallBack` draws for
//! it. A scroller.gadget at its right moves the view; so does dragging
//! past the list's top or bottom edge, a line at each tick. A press on a
//! line selects it, and the selection follows the pointer while the button
//! is held; let go, the window hears `IDCMP_GADGETUP` with the selected
//! line's number as the code, and the target `LISTVIEW_Selected`. A
//! read-only list selects nothing and only scrolls.
//!
//! `LISTVIEW_SelectString` names a string.gadget the selected line's name
//! is written into, so the name can be read and edited there.
//!
//! `LISTVIEW_MultiSelect` lets several lines be selected at once: a press
//! selects one line and clears the rest, a press with Shift held adds a
//! line or takes it away, and a drag with Shift held passes the state of
//! the line it started on over the lines it crosses. Which lines are
//! selected is read as `LISTVIEW_SelectedArray`, a bit for each.
//!
//! A second press on the line last pressed, inside the time
//! `DoubleClick` allows, carries `LISTVIEW_DOUBLE` in the code beside the
//! line's number, so a list can be answered without a button of its own.
//!
//! A program that changes the list detaches it first - `LISTVIEW_Labels`
//! of `LISTVIEW_DETACH` - and gives it back afterwards, so the gadget
//! never walks a list that is being changed.
//!
//!   const view = ib.NewObjectTagList(null, lv.LISTVIEW_CLASS, &.{
//!       .{ .tag = gc.GA_ID, .data = 5 },
//!       .{ .tag = lv.LISTVIEW_Labels, .data = @intFromPtr(&names) },
//!       .{ .tag = lv.LISTVIEW_ShowSelected, .data = 1 },
//!       .{},
//!   });
//!
//! What a window does with the code of a `WMHI_GADGETUP` from a list:
//!
//!   const line = code & ~lv.LISTVIEW_DOUBLE;
//!   if (code & lv.LISTVIEW_DOUBLE != 0) open(line) else show(line);
//!
//! It needs scroller.gadget as well, which it opens itself.

const exec = @import("../exec/exec.zig");
const graphics = @import("../graphics/graphics.zig");
const screens = @import("../intuition/screens.zig");
const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const LISTVIEW_LIBRARY = "gadgets/listview.gadget";
pub const LISTVIEW_CLASS = "listview.gadget";

pub const LISTVIEW_Dummy = gadgets.GADGETS_Dummy + 7 * gadgets.GADGETS_Step;
/// The list: a `*exec.List` whose nodes are the lines, not copied; null
/// for none, `LISTVIEW_DETACH` to let go of it while it is changed. Made,
/// set and read. A new list starts at its top with nothing selected.
pub const LISTVIEW_Labels = LISTVIEW_Dummy + 0x01;
/// The first line shown. Made, set and read.
pub const LISTVIEW_Top = LISTVIEW_Dummy + 0x02;
/// Set only: scroll as little as makes this line shown.
pub const LISTVIEW_MakeVisible = LISTVIEW_Dummy + 0x03;
/// The selected line, or `LISTVIEW_NONE`. Made, set and read; told to the
/// target when a press changes it.
pub const LISTVIEW_Selected = LISTVIEW_Dummy + 0x04;
/// Bool, made only: nothing is selected, the list only scrolls.
pub const LISTVIEW_ReadOnly = LISTVIEW_Dummy + 0x05;
/// Bool, made only: the selected line is drawn in the fill pen.
pub const LISTVIEW_ShowSelected = LISTVIEW_Dummy + 0x06;
/// How tall a line is; a line of the font unless given. Made only.
pub const LISTVIEW_ItemHeight = LISTVIEW_Dummy + 0x07;
/// A `*utility.Hook` that draws a line: called with the node as its
/// object and an `LVDrawMsg` as its message, and answering `LVCB_OK` when
/// it drew it or `LVCB_UNKNOWN` for the gadget to draw the name. It is
/// asked `LV_ISDISABLED` of a line as well. Made only.
pub const LISTVIEW_CallBack = LISTVIEW_Dummy + 0x08;
/// How wide the scroller at the right is; 16 unless given. Made only.
pub const LISTVIEW_ScrollWidth = LISTVIEW_Dummy + 0x09;
/// Bool, made only: several lines may be selected at once, and the
/// selected lines are drawn in the fill pen whether `LISTVIEW_ShowSelected`
/// was given or not.
pub const LISTVIEW_MultiSelect = LISTVIEW_Dummy + 0x0A;
/// Read only: a `*const LVSelected`, the bit for each line, or null when
/// the list is not a multi-select one. It holds until the list is
/// changed; `LISTVIEW_Labels` clears it and sizes it to the new list.
pub const LISTVIEW_SelectedArray = LISTVIEW_Dummy + 0x0B;
/// A string.gadget object the selected line's name is written into
/// whenever the selection changes, and emptied when nothing is selected.
/// The program reads and edits the name there. Made and set; null for
/// none. The object stays the program's to dispose of.
pub const LISTVIEW_SelectString = LISTVIEW_Dummy + 0x0C;

/// `LISTVIEW_Labels`: let go of the list while it is changed.
pub const LISTVIEW_DETACH: usize = ~@as(usize, 0);
/// `LISTVIEW_Selected`: nothing.
pub const LISTVIEW_NONE: u32 = ~@as(u32, 0);
/// In the code of the `IDCMP_GADGETUP` a press ends with: the press was
/// the second on that line inside the double-click time. The line's
/// number is the rest of the code, `code & ~LISTVIEW_DOUBLE`.
pub const LISTVIEW_DOUBLE: u32 = 0x8000_0000;

/// Which lines are selected: a bit each, the lowest bit of the first word
/// line 0. `LISTVIEW_SelectedArray` answers a pointer to one of these.
pub const LVSelected = extern struct {
    bits: ?[*]const u32 = null,
    /// How many lines the bits are for.
    count: u32 = 0,

    /// Whether `line` is selected.
    pub fn has(self: *const LVSelected, line: u32) bool {
        if (line >= self.count) return false;
        const bits = self.bits orelse return false;
        return bits[line / 32] & (@as(u32, 1) << @intCast(line % 32)) != 0;
    }

    /// How many lines are selected.
    pub fn selected(self: *const LVSelected) u32 {
        const bits = self.bits orelse return 0;
        var n: u32 = 0;
        var word: u32 = 0;
        while (word * 32 < self.count) : (word += 1) n += @popCount(bits[word]);
        return n;
    }
};

/// The hook's messages: draw a line, and is a line disabled?
pub const LV_DRAW: u32 = 0x202;
pub const LV_ISDISABLED: u32 = 0x203;

/// `LV_DRAW`'s answers: drawn, or left to the gadget.
pub const LVCB_OK: usize = 0;
pub const LVCB_UNKNOWN: usize = 1;
/// `LV_ISDISABLED`'s answer for a line that is disabled: drawn ghosted,
/// and not selected. Anything else is an enabled line.
pub const LVCB_DISABLED: usize = 2;

/// The state a line is drawn in.
pub const LVR_NORMAL: u32 = 0;
pub const LVR_SELECTED: u32 = 1;
pub const LVR_NORMALDISABLED: u32 = 2;
pub const LVR_SELECTEDDISABLED: u32 = 8;

/// `LV_DRAW` and `LV_ISDISABLED`: which line, and for `LV_DRAW` where and
/// how. The hook draws inside `bounds`, in the RastPort's font, and leaves
/// the RastPort's pens as they were.
pub const LVDrawMsg = extern struct {
    method_id: u32 = LV_DRAW,
    rast_port: ?*graphics.RastPort = null,
    draw_info: ?*screens.DrawInfo = null,
    bounds: graphics.Rect = .{},
    /// `LVR_*`.
    state: u32 = LVR_NORMAL,
    /// The line's number, from 0.
    line: u32 = 0,
};

/// The node a line is: the list's `line`th, or null past its end.
pub fn nodeAt(list: *exec.List, line: u32) ?*exec.Node {
    var node = list.first();
    var i: u32 = 0;
    while (node) |n| : (node = n.next()) {
        if (i == line) return n;
        i += 1;
    }
    return null;
}
