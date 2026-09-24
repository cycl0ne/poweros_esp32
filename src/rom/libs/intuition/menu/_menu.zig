// SPDX-License-Identifier: MPL-2.0
//! Menus: what the menu calls and the menu session share - finding an item
//! by its menu number, and working out where a panel goes and how big it
//! is.
//!
//! A panel is the smallest rectangle that holds every item of it - each
//! item's box, and what its text or image and its checkmark and shortcut
//! take up - with a trim around it, stretched to reach the title of its
//! menu (or, for a panel of subitems, to touch the corner of its item).
//! Rectangles here are inclusive, `max` being the last pixel inside, since
//! that is what a menu's `jazz_x`..`beat_y` hold.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const intuition = sdk.intuition;
const mn = intuition.menus;
const ic = intuition.imageclass;
const Menu = mn.Menu;
const MenuItem = mn.MenuItem;
const IntuiText = intuition.IntuiText;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;

/// A panel's trim: how far its edge is from what its items take up,
/// across and down.
pub const menu_hborder = 4;
pub const menu_vborder = 2;

/// A rectangle, both corners inside it.
pub const Box = struct {
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,

    /// Inside out, so the first hull taken is the other box.
    pub const empty = Box{ .min_x = 32767, .min_y = 32767, .max_x = -32767, .max_y = -32767 };

    pub fn hull(a: Box, b: Box) Box {
        return .{
            .min_x = @min(a.min_x, b.min_x),
            .min_y = @min(a.min_y, b.min_y),
            .max_x = @max(a.max_x, b.max_x),
            .max_y = @max(a.max_y, b.max_y),
        };
    }

    pub fn offset(a: Box, dx: i32, dy: i32) Box {
        return .{ .min_x = a.min_x + dx, .min_y = a.min_y + dy, .max_x = a.max_x + dx, .max_y = a.max_y + dy };
    }

    pub fn contains(a: Box, x: i32, y: i32) bool {
        return x >= a.min_x and x <= a.max_x and y >= a.min_y and y <= a.max_y;
    }

    fn of(left: i32, top: i32, width: i32, height: i32) Box {
        return .{ .min_x = left, .min_y = top, .max_x = left + width - 1, .max_y = top + height - 1 };
    }
};

// --- menu numbers -------------------------------------------------------------------

/// The menu a number names, or null for none.
pub fn grabMenu(strip: ?*Menu, number: u32) ?*Menu {
    const which = mn.MENUNUM(number);
    if (which == mn.NOMENU) return null;
    var menu = strip;
    var i: u32 = 0;
    while (menu) |m| : (menu = m.next_menu) {
        if (i == which) return m;
        i += 1;
    }
    return null;
}

/// The item of `menu` a number names, or null for none.
pub fn grabItem(menu: ?*Menu, number: u32) ?*MenuItem {
    const m = menu orelse return null;
    return nth(m.first_item, mn.ITEMNUM(number), mn.NOITEM);
}

/// The subitem of `item` a number names, or null for none.
pub fn grabSub(item: ?*MenuItem, number: u32) ?*MenuItem {
    const parent = item orelse return null;
    return nth(parent.sub_item, mn.SUBNUM(number), mn.NOSUB);
}

fn nth(first: ?*MenuItem, which: u32, none: u32) ?*MenuItem {
    if (which == none) return null;
    var item = first;
    var i: u32 = 0;
    while (item) |entry| : (item = entry.next_item) {
        if (i == which) return entry;
        i += 1;
    }
    return null;
}

/// Each flag of the strip masked: a menu's with `menu_mask`, an item's with
/// `item_mask`, a subitem's with `sub_mask` - how a session starts clean.
pub fn resetMenu(strip: ?*Menu, menu_mask: u32, item_mask: u32, sub_mask: u32) void {
    var menu = strip;
    while (menu) |m| : (menu = m.next_menu) {
        var item = m.first_item;
        while (item) |entry| : (item = entry.next_item) {
            entry.flags &= item_mask;
            var sub = entry.sub_item;
            while (sub) |each| : (sub = each.next_item) each.flags &= sub_mask;
        }
        m.flags &= menu_mask;
    }
}

/// What a session starts from: nothing drawn, highlighted or toggled.
pub fn resetDrawn(strip: ?*Menu) void {
    resetMenu(strip, ~mn.MIDRAWN, ~(mn.ISDRAWN | mn.HIGHITEM | mn.MENUTOGGLED), ~(mn.HIGHITEM | mn.MENUTOGGLED));
}

/// A menu, an item or a subitem enabled or disabled, by its menu number:
/// the menu itself when the number names no item, the item when it names
/// no subitem.
pub fn onOff(strip: ?*Menu, number: u32, on: bool) void {
    const menu = grabMenu(strip, number) orelse return;
    const item = grabItem(menu, number) orelse {
        if (on) menu.flags |= mn.MENUENABLED else menu.flags &= ~mn.MENUENABLED;
        return;
    };
    const target = grabSub(item, number) orelse item;
    if (on) target.flags |= mn.ITEMENABLED else target.flags &= ~mn.ITEMENABLED;
}

// --- measuring ------------------------------------------------------------------------

/// How tall a font is and where its baseline is: the screen's when null.
pub const Metric = struct { height: i32, baseline: i32 };

pub fn metric(ib: *IntuitionBase, w: *Window, font: ?*graphics.TextFont) Metric {
    const gb = ib.graphics_base;
    // A RastPort needs something to draw into; nothing is drawn, so one
    // pixel on the stack is all it gets.
    var pixel: u32 = 0;
    var surface = rtg.bitmaps.Surface{
        .pixels = @ptrCast(&pixel),
        .width = 1,
        .height = 1,
        .pitch = @sizeOf(u32),
        .size_bytes = @sizeOf(u32),
        .format = .rgba32,
    };
    const rp = gb.CreateRastPortTagList(&[_]TagItem{
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(font orelse w.screen.font) },
        .{},
    }) orelse return .{ .height = 0, .baseline = 0 };
    defer gb.FreeRastPort(rp);
    var height: u32 = 0;
    var baseline: u32 = 0;
    const ask = [_]TagItem{
        .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) },
        .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
        .{},
    };
    gb.GetRPAttrs(rp, &ask);
    return .{ .height = @intCast(height), .baseline = @intCast(baseline) };
}

/// How wide a run is, in its own font or the screen's.
pub fn textWidth(ib: *IntuitionBase, w: *Window, run: *const IntuiText) i32 {
    var measured = run.*;
    measured.font = run.font orelse w.screen.font;
    measured.next = null;
    return ib.iface().IntuiTextLength(&measured);
}

/// An image object's box, from the corner it is drawn at.
pub fn imageBox(ib: *IntuitionBase, image: ?*Object) Box {
    const it = ib.iface();
    var left: usize = 0;
    var top: usize = 0;
    var width: usize = 0;
    var height: usize = 0;
    _ = it.GetAttr(ic.IA_Left, image, &left);
    _ = it.GetAttr(ic.IA_Top, image, &top);
    _ = it.GetAttr(ic.IA_Width, image, &width);
    _ = it.GetAttr(ic.IA_Height, image, &height);
    return Box.of(@bitCast(@as(u32, @truncate(left))), @bitCast(@as(u32, @truncate(top))), @intCast(width), @intCast(height));
}

/// How tall an image object is, 0 for none.
pub fn imageHeight(ib: *IntuitionBase, image: ?*Object) i32 {
    if (image == null) return 0;
    const b = imageBox(ib, image);
    return b.max_y - b.min_y + 1;
}

/// How wide an image object is, 0 for none.
pub fn imageWidth(ib: *IntuitionBase, image: ?*Object) i32 {
    if (image == null) return 0;
    const b = imageBox(ib, image);
    return b.max_x - b.min_x + 1;
}

/// What an item takes up, from its panel's corner: its box, and its fill
/// and select fill where they reach beyond it - a text's width and its
/// font's height, an image's box - each at least as tall as the checkmark
/// with `CHECKIT` and the Amiga key with `COMMSEQ`.
fn itemExtent(ib: *IntuitionBase, w: *Window, item: *const MenuItem) Box {
    var extent = Box.of(item.left, item.top, item.width, item.height);
    for ([_]?*anyopaque{ item.item_fill, item.select_fill }) |fill| {
        const given = fill orelse continue;
        var shown: Box = undefined;
        if (item.flags & mn.ITEMTEXT != 0) {
            const run: *const IntuiText = @ptrCast(@alignCast(given));
            shown = Box.of(run.left, run.top, textWidth(ib, w, run), metric(ib, w, run.font).height);
        } else {
            shown = imageBox(ib, @ptrCast(given));
        }
        var height = shown.max_y - shown.min_y + 1;
        if (item.flags & mn.COMMSEQ != 0) height = @max(height, imageHeight(ib, w.amiga_key));
        if (item.flags & mn.CHECKIT != 0) height = @max(height, imageHeight(ib, w.check_mark));
        shown.max_y = shown.min_y + height - 1;
        extent = extent.hull(shown.offset(item.left, item.top));
    }
    return extent;
}

/// A panel's rectangle from its corner: what its items take up, with the
/// trim around it, stretched to take in `reach`. A menu's panel starts at
/// its corner whatever its items say, so it never overlaps the bar.
pub fn boxer(ib: *IntuitionBase, w: *Window, first: ?*MenuItem, reach: Box, is_sub: bool) Box {
    var extent = Box.empty;
    var item = first;
    while (item) |entry| : (item = entry.next_item) extent = extent.hull(itemExtent(ib, w, entry));
    if (!is_sub) extent.min_y = 0;
    extent.min_x -= menu_hborder;
    extent.min_y -= menu_vborder;
    extent.max_x += menu_hborder;
    extent.max_y += menu_vborder;
    return extent.hull(reach);
}

/// Every menu's panel worked out into its `jazz_x`..`beat_y`: at least as
/// wide as its title, as tall as its items make it.
pub fn layOut(ib: *IntuitionBase, w: *Window, strip: ?*Menu) void {
    var menu = strip;
    while (menu) |m| : (menu = m.next_menu) {
        const reach = Box{ .min_x = 0, .min_y = 32767, .max_x = m.width - 1, .max_y = -32767 };
        const panel = boxer(ib, w, m.first_item, reach, false);
        m.jazz_x = panel.min_x;
        m.jazz_y = panel.min_y;
        m.beat_x = panel.max_x;
        m.beat_y = panel.max_y;
    }
}
