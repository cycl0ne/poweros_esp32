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
const Object = intuition.Object;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const _screen = @import("../screen/_screen.zig");
const sc = intuition.screens;
const _render = @import("../render/_render.zig");
const runOf = _render.runOf;
const setTag = _render.setTag;

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

/// How wide a run is, in its own font or the screen's, and its style.
pub fn textWidth(ib: *IntuitionBase, w: *Window, tags: [*]const TagItem) i32 {
    const run = runOf(ib.utility_base, tags);
    const measured = [_]TagItem{
        .{ .tag = intuition.IT_Text, .data = @intFromPtr(run.text) },
        .{ .tag = intuition.IT_Font, .data = @intFromPtr(run.font orelse w.screen.font) },
        .{ .tag = intuition.IT_Style, .data = run.style orelse graphics.FS_NORMAL },
        .{},
    };
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
            const tags: [*]const TagItem = @ptrCast(@alignCast(given));
            const run = runOf(ib.utility_base, tags);
            shown = Box.of(run.left, run.top, textWidth(ib, w, tags), metric(ib, w, run.font).height);
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

// --- menus from a table ---------------------------------------------------------------
//
// What CreateMenusA keeps beside what it makes, and how LayoutMenusA and
// LayoutMenuItemsA place it.

/// After every title and item CreateMenusA makes: its user data, and for
/// an item the left its image had when it was given, which each layout
/// starts from again.
pub const Extra = extern struct {
    user_data: ?*anyopaque = null,
    image_left: isize = 0,
};

/// The extra of a title or an item CreateMenusA made.
pub fn extraOf(comptime T: type, it: *T) *Extra {
    return @ptrCast(@alignCast(@as([*]T, @ptrCast(it)) + 1));
}

/// A separator is the one item whose highlighting is none: CreateMenusA
/// makes it so, and nothing else there does.
pub fn isBar(item: *const MenuItem) bool {
    return item.flags & mn.ITEMTEXT == 0 and item.flags & mn.HIGHFLAGS == mn.HIGHNONE;
}

/// Pixels between the columns of a panel too tall for the screen.
const multicolumn_gap = 8;

/// What a layout needs to know of the screen and the tags.
pub const Layout = struct {
    ib: *IntuitionBase,
    screen: *_screen.Screen,
    /// The items' font, and one character's width and a line's height of
    /// it.
    font: *graphics.TextFont,
    font_x: i32,
    item_height: i32,
    /// How wide the checkmark and the Amiga key are.
    check_width: i32,
    comm_width: i32,
    front_pen: graphics.Pen,

    pub fn of(ib: *IntuitionBase, s: *_screen.Screen, tags: ?[*]const TagItem) Layout {
        const ub = ib.utility_base;
        const font: *graphics.TextFont = @ptrFromInt(ub.GetTagData(mn.GTMN_Font, @intFromPtr(s.font), tags));
        var extent = graphics.FontExtent{};
        ib.graphics_base.FontExtent(font, &extent);
        const check: ?*Object = @ptrFromInt(ub.GetTagData(mn.GTMN_Checkmark, @intFromPtr(s.draw_info.check_mark), tags));
        const key: ?*Object = @ptrFromInt(ub.GetTagData(mn.GTMN_AmigaKey, @intFromPtr(s.draw_info.amiga_key), tags));
        return .{
            .ib = ib,
            .screen = s,
            .font = font,
            .font_x = extent.width,
            // Never less than eight rows and one, so the Amiga key is not
            // crowded.
            .item_height = @max(extent.height, 8) + 1,
            .check_width = imageWidth(ib, check),
            .comm_width = imageWidth(ib, key),
            .front_pen = @truncate(ub.GetTagData(mn.GTMN_FrontPen, ib.iface().GetStyleAttr(&s.draw_info, null, sdk.intuition.imageclass.PART_MENU, sdk.intuition.style.STATE_NORMAL, sdk.intuition.style.STYLE_TextPen), tags)),
        };
    }

    fn textWidth(l: *const Layout, text: ?[*:0]const u8) i32 {
        const run = intuition.text.plainRun(text orelse return 0, l.font);
        return l.ib.iface().IntuiTextLength(&run);
    }
};

/// Every item's height, font and pen, and every separator's pen, subitems
/// too: what does not depend on where the items go.
pub fn sizeItems(l: *const Layout, first: ?*MenuItem) void {
    var item = first;
    while (item) |entry| : (item = entry.next_item) {
        if (entry.flags & mn.ITEMTEXT != 0) {
            entry.height = l.item_height;
            const ub = l.ib.utility_base;
            var run: ?[*]const TagItem = @ptrCast(@alignCast(entry.item_fill));
            while (run) |each| : (run = runOf(ub, each).next) {
                _ = setTag(ub, each, intuition.IT_Font, @intFromPtr(l.font));
                _ = setTag(ub, each, intuition.IT_FrontPen, l.front_pen);
            }
        } else if (isBar(entry)) {
            entry.height = 6;
            const pen = [_]TagItem{ .{ .tag = ic.IA_FGPen, .data = l.front_pen }, .{} };
            _ = l.ib.iface().SetAttrsTagList(@ptrCast(entry.item_fill), &pen);
        } else {
            entry.height = imageHeight(l.ib, @ptrCast(entry.item_fill)) + 1;
        }
        sizeItems(l, entry.sub_item);
    }
}

/// One column of a panel: how wide its items are, how tall together, how
/// many fit, and the first item of the next column.
const Column = struct {
    width: i32 = 0,
    height: i32 = 0,
    count: u32 = 0,
    next: ?*MenuItem = null,
};

/// The column that starts at `first`: as many items as fit in
/// `max_height`, and as wide as the widest of them with room at its right
/// for a shortcut, the words at its right, or the mark of its subitems.
/// Each text's and image's place across is set on the way.
fn aboutColumn(l: *const Layout, first: *MenuItem, max_height: i32) Column {
    var column = Column{};
    var item: ?*MenuItem = first;
    while (item) |entry| : (item = entry.next_item) {
        if (column.height + entry.height > max_height and column.count > 0) {
            column.next = entry;
            break;
        }
        column.height += entry.height;
        column.count += 1;
    }
    var right_trim: i32 = 2;
    var longest: i32 = 0;
    item = first;
    var n = column.count;
    while (n > 0) : (n -= 1) {
        const entry = item.?;
        defer item = entry.next_item;
        if (entry.flags & mn.COMMSEQ != 0) {
            const chars = [2:0]u8{ entry.command, 0 };
            right_trim = @max(right_trim, l.textWidth(&chars) + l.comm_width + l.font_x);
        } else if (entry.flags & mn.ITEMTEXT != 0) {
            const run = runOf(l.ib.utility_base, @ptrCast(@alignCast(entry.item_fill.?)));
            if (run.next) |more| right_trim = @max(right_trim, l.textWidth(runOf(l.ib.utility_base, more).text) + l.font_x);
        }
        const check: i32 = if (entry.flags & mn.CHECKIT != 0) l.check_width else 0;
        if (entry.flags & mn.ITEMTEXT != 0) {
            const tags: [*]const TagItem = @ptrCast(@alignCast(entry.item_fill.?));
            const left = 2 + check;
            _ = setTag(l.ib.utility_base, tags, intuition.IT_Left, @bitCast(@as(isize, left)));
            longest = @max(longest, left + l.textWidth(runOf(l.ib.utility_base, tags).text));
        } else if (!isBar(entry)) {
            const image: *Object = @ptrCast(entry.item_fill.?);
            const left: i32 = @as(i32, @intCast(extraOf(MenuItem, entry).image_left)) + 2 + check;
            const place = [_]TagItem{ .{ .tag = ic.IA_Left, .data = @bitCast(@as(isize, left)) }, .{} };
            _ = l.ib.iface().SetAttrsTagList(image, &place);
            longest = @max(longest, left + imageWidth(l.ib, image));
        }
    }
    column.width = longest + right_trim;
    return column;
}

/// A panel's items placed: in columns as tall as the screen allows, the
/// panel at least `min_width` wide and moved left when it would run off
/// the screen's right, each item's text at its right put against its
/// edge, separators across it, and each item's subitems placed beside it.
///
/// `left` and `top` are where the items start from the panel's corner -
/// for subitems, from their item's; `real_left` and `real_top` where that
/// corner is on the screen.
pub fn placeItems(l: *const Layout, first: ?*MenuItem, left_start: i32, top_start: i32, real_left: i32, real_top: i32, min_width: i32, is_sub: bool) void {
    const head = first orelse return;
    const s = l.screen;
    var top_offset = top_start;
    var left_offset = left_start;
    const max_height = s.height - 2 - (top_offset + real_top);

    // The whole panel: its columns side by side.
    var panel_width: i32 = -multicolumn_gap;
    var panel_height: i32 = 0;
    var columns: i32 = 0;
    var scan: ?*MenuItem = head;
    while (scan) |start| {
        const column = aboutColumn(l, start, max_height);
        columns += 1;
        panel_width += column.width + multicolumn_gap;
        panel_height = @max(panel_height, column.height);
        scan = column.next;
    }
    // A narrow panel is stretched to its title, or a third of its item.
    const extra_width = @divTrunc(@max(min_width - panel_width, 0), columns) + 1;
    panel_width += extra_width * columns;
    // A panel of subitems starts a pixel above its item when it fits, and
    // higher when that lets it fit without another column.
    if (is_sub) top_offset = @min(-1, s.height - 2 - real_top - panel_height);
    // Off the right of the screen: moved left, but never past the panel's
    // own trim.
    const over = real_left + panel_width - s.width + 4;
    if (over > 0) left_offset -= @min(over, real_left - 4);

    var column = Column{};
    left_offset -= multicolumn_gap;
    var item_top: i32 = top_offset;
    var item: ?*MenuItem = head;
    while (item) |entry| {
        if (column.count == 0) {
            item_top = top_offset;
            left_offset += column.width + multicolumn_gap;
            column = aboutColumn(l, entry, max_height);
            column.width += extra_width;
            continue;
        }
        column.count -= 1;
        entry.top = item_top;
        entry.left = left_offset;
        entry.width = column.width;
        if (entry.flags & mn.ITEMTEXT != 0) {
            const ub = l.ib.utility_base;
            const run = runOf(ub, @ptrCast(@alignCast(entry.item_fill.?)));
            if (run.next) |more| {
                const left = column.width - 2 - l.textWidth(runOf(ub, more).text);
                _ = setTag(ub, more, intuition.IT_Left, @bitCast(@as(isize, left)));
            }
        } else if (isBar(entry)) {
            const size = [_]TagItem{ .{ .tag = ic.IA_Width, .data = @intCast(@max(column.width - 4, 1)) }, .{} };
            _ = l.ib.iface().SetAttrsTagList(@ptrCast(entry.item_fill), &size);
        }
        // Subitems start three quarters of the way across their item.
        const sub_min = column.width >> 2;
        const sub_left = column.width - sub_min;
        placeItems(l, entry.sub_item, sub_left, -1 - item_top, real_left + left_offset + sub_left, item_top + real_top, sub_min, true);
        item_top += entry.height;
        item = entry.next_item;
    }
}
