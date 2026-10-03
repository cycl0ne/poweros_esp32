// SPDX-License-Identifier: MPL-2.0
//! CreateMenusA: a menu strip made from a table, in one allocation.
//!
//! The table is read twice: once to count what it needs and to find out
//! whether it is a menu at all, once to fill the allocation in. In the
//! allocation, in front of the first title or item, is a `Header` and the
//! separators' rule images before it, which is how FreeMenus finds both.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const mn = intuition.menus;
const ic = intuition.imageclass;
const Menu = mn.Menu;
const MenuItem = mn.MenuItem;
const NewMenu = mn.NewMenu;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _menu = @import("_menu.zig");
const Extra = _menu.Extra;
const _render = @import("../render/_render.zig");
const RunTags = _render.RunTags;

/// Right in front of the first title or item: where the allocation starts
/// and the separators' images, which FreeMenus disposes of.
pub const Header = extern struct {
    start: *anyopaque,
    bars: [*]?*Object,
    bar_count: u32,
    pad: u32 = 0,
};

/// The header of what CreateMenusA made, from its first title or item.
pub fn headerOf(first: *anyopaque) *Header {
    return @ptrFromInt(@intFromPtr(first) - @sizeOf(Header));
}

/// "»": what an item with subitems shows at its right.
const more_mark: [*:0]const u8 = "\xbb";

fn trueType(nm: *const NewMenu) u8 {
    return nm.type & ~mn.MENU_IMAGE;
}

fn isBarLabel(nm: *const NewMenu) bool {
    return nm.label == mn.NM_BARLABEL;
}

/// What a table needs: bytes for the titles, items and texts, and how many
/// separators it has. Null for a table that is not a menu.
const Tally = struct { bytes: usize, bars: u32 };

fn tally(table: [*]const NewMenu, full: bool) ?Tally {
    var bytes: usize = 0;
    var bars: u32 = 0;
    var previous: u8 = 0;
    if (full and table[0].type != mn.NM_TITLE) return null;
    var i: usize = 0;
    while (table[i].type != mn.NM_END) : (i += 1) {
        const nm = &table[i];
        if (nm.type & mn.NM_IGNORE != 0) continue;
        const kind = trueType(nm);
        if (nm.type == mn.NM_TITLE) {
            bytes += @sizeOf(Menu) + @sizeOf(Extra);
        } else {
            bytes += @sizeOf(MenuItem) + @sizeOf(Extra);
            if (isBarLabel(nm)) {
                bars += 1;
            } else if (nm.type & mn.MENU_IMAGE == 0) {
                bytes += @sizeOf(RunTags);
                if (nm.flags & mn.NM_COMMANDSTRING != 0) bytes += @sizeOf(RunTags);
            }
            if (kind == mn.NM_SUB) {
                // Subitems follow an item or each other, never a title.
                if (previous == mn.NM_TITLE) return null;
                // The first of them: room for the mark on its item.
                if (previous == mn.NM_ITEM) bytes += @sizeOf(RunTags);
            }
        }
        previous = nm.type;
    }
    if (bytes == 0) return null;
    return .{ .bytes = bytes, .bars = bars };
}

/// Hands out the allocation in order, each piece where the one before
/// ended.
const Bump = struct {
    at: [*]u8,

    fn take(bump: *Bump, comptime T: type) *T {
        const it: *T = @ptrCast(@alignCast(bump.at));
        bump.at += @sizeOf(T);
        return it;
    }
};

/// The table filled into the allocation. Answers `GTMENU_TRIMMED` when
/// there was more than menu numbers can name, else 0; null when a
/// separator's image could not be made.
fn fill(ib: *IntuitionBase, table: [*]const NewMenu, bump: *Bump, header: *Header, front_pen: graphics.Pen) ?u32 {
    const it = ib.iface();
    const ub = ib.utility_base;
    var menu: ?*Menu = null;
    var item: ?*MenuItem = null;
    var sub: ?*MenuItem = null;
    var menu_count: i32 = -1;
    var item_count: i32 = -1;
    var sub_count: i32 = -1;
    var trimmed: u32 = 0;
    var i: usize = 0;
    while (table[i].type != mn.NM_END and menu_count < mn.NOMENU) : (i += 1) {
        const nm = &table[i];
        if (nm.type & mn.NM_IGNORE != 0) continue;
        if (nm.type == mn.NM_TITLE) {
            menu_count += 1;
            if (menu_count >= mn.NOMENU) {
                trimmed = mn.GTMENU_TRIMMED;
                continue;
            }
            const this = bump.take(Menu);
            _ = bump.take(Extra);
            this.* = .{ .name = nm.label, .flags = (nm.flags & mn.MENUENABLED) ^ mn.NM_MENUDISABLED };
            _menu.extraOf(Menu, this).* = .{ .user_data = nm.user_data };
            if (menu) |before| before.next_menu = this;
            menu = this;
            item = null;
            item_count = -1;
            continue;
        }

        const this = bump.take(MenuItem);
        _ = bump.take(Extra);
        this.* = .{};
        _menu.extraOf(MenuItem, this).* = .{ .user_data = nm.user_data };
        if (trueType(nm) == mn.NM_ITEM) {
            item_count += 1;
            if (item_count >= mn.NOITEM) {
                trimmed = mn.GTMENU_TRIMMED;
                sub_count = mn.NOSUB;
                continue;
            }
            if (item) |before| before.next_item = this else if (menu) |m| m.first_item = this;
            item = this;
            sub = null;
            sub_count = -1;
        } else {
            sub_count += 1;
            if (sub_count >= mn.NOSUB) {
                trimmed = mn.GTMENU_TRIMMED;
                continue;
            }
            if (sub) |before| before.next_item = this else if (item) |parent| {
                parent.sub_item = this;
                // A text item says it has subitems at its right.
                if (parent.flags & mn.ITEMTEXT != 0) {
                    const mark = bump.take(RunTags);
                    mark.* = _render.makeRun(more_mark, front_pen, 0, 1, null, null);
                    _ = _render.setTag(ub, @ptrCast(@alignCast(parent.item_fill.?)), intuition.IT_Next, @intFromPtr(mark));
                }
            }
            sub = this;
        }

        // The table says what is off; the item what is on.
        this.flags = (nm.flags & ~(mn.ITEMTEXT | mn.HIGHFLAGS)) ^ mn.NM_ITEMDISABLED;
        var words = false;
        if (nm.comm_key) |key| {
            this.flags ^= mn.NM_COMMANDSTRING;
            if (this.flags & mn.COMMSEQ != 0) this.command = key[0] else words = true;
        }
        this.mutual_exclude = nm.mutual_exclude;
        if (isBarLabel(nm)) {
            const rule = it.NewObjectTagList(ib.fillrect_class, null, &[_]TagItem{
                .{ .tag = ic.IA_Left, .data = 2 },
                .{ .tag = ic.IA_Top, .data = 2 },
                .{ .tag = ic.IA_Width, .data = 1 },
                .{ .tag = ic.IA_Height, .data = 2 },
                .{ .tag = ic.IA_FGPen, .data = front_pen },
                .{},
            }) orelse return null;
            header.bars[header.bar_count] = rule;
            header.bar_count += 1;
            this.item_fill = rule;
            // Neither picked nor highlighted.
            this.flags = (this.flags | mn.HIGHNONE) & ~(mn.ITEMENABLED | mn.COMMSEQ);
        } else if (nm.type & mn.MENU_IMAGE != 0) {
            const image: *Object = @ptrCast(@constCast(nm.label.?));
            var left: usize = 0;
            var top: usize = 0;
            _ = it.GetAttr(ic.IA_Left, image, &left);
            _ = it.GetAttr(ic.IA_Top, image, &top);
            const below = [_]TagItem{ .{ .tag = ic.IA_Top, .data = top + 1 }, .{} };
            _ = it.SetAttrsTagList(image, &below);
            _menu.extraOf(MenuItem, this).image_left = @bitCast(left);
            this.item_fill = image;
            this.flags |= mn.HIGHCOMP;
        } else {
            const run = bump.take(RunTags);
            run.* = _render.makeRun(nm.label, front_pen, 0, 1, null, null);
            this.item_fill = run;
            this.flags |= mn.ITEMTEXT | mn.HIGHCOMP;
            if (words) {
                const right = bump.take(RunTags);
                right.* = _render.makeRun(nm.comm_key, front_pen, 0, 1, null, null);
                _ = _render.setTag(ub, run, intuition.IT_Next, @intFromPtr(right));
            }
        }
    }
    return trimmed;
}

/// Makes a menu strip, or one panel's items, from a table.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateMenusA(ib: *IntuitionBase, new_menu: [*]const NewMenu, tags: ?[*]const TagItem) ?*Menu
/// ```
///
/// SINCE: 0.17. LVO -436.
///
/// INPUTS:
/// - `new_menu` - the table, ended by an entry of type `NM_END`: titles
///   (`NM_TITLE`), each followed by its items (`NM_ITEM`, `IM_ITEM`), each
///   of those by its subitems (`NM_SUB`, `IM_SUB`). A table that starts
///   with an item is one panel's items.
/// - `tags` - `GTMN_FrontPen`, the text's colour until a layout sets it;
///   `GTMN_FullMenu`, the table must start with a title;
///   `GTMN_SecondaryError`, where to say what went wrong.
///
/// RESULT:
/// The first title, or for a table of items the first item (cast to it),
/// with every title, item and subitem linked; null when the table is not
/// a menu - a subitem right after a title, nothing in it, or a fragment
/// under `GTMN_FullMenu` - or there is no memory. `GTMN_SecondaryError`
/// is told `GTMENU_INVALID`, `GTMENU_NOMEM`, `GTMENU_TRIMMED` - more
/// titles, items or subitems than menu numbers can name, the strip made
/// without them - or 0.
///
/// BEHAVIOR:
/// An item's words are an IntuiText of their own, one row down: a tag
/// list with every `IT_` tag the layout fills in - `IT_Left`,
/// `IT_FrontPen`, `IT_Font` - in it, and writable. A key in `comm_key`
/// makes it `COMMSEQ`; with `NM_COMMANDSTRING` the words in `comm_key`
/// are a second run, linked by `IT_Next` and put at the item's right by
/// the layout. The first subitem of a text item gives that item a second
/// run, "»", at its right. `NM_BARLABEL` is a separator: a
/// fillrectclass rule two rows high, neither picked nor highlighted.
/// `IM_ITEM`'s image object is the item's, moved down a row; it is not
/// copied. `NM_MENUDISABLED` and `NM_ITEMDISABLED` make it disabled; the
/// rest of `flags` is the item's. Each title and item keeps the table's
/// `user_data` right after it (`GTMENU_USERDATA`, `GTMENUITEM_USERDATA`).
/// Nothing is placed: `LayoutMenusA` does that.
///
/// CONTEXT:
/// - Waits: no; it allocates.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The strip is the caller's, given back with `FreeMenus` once it is off
/// every window. The table's words and images are the caller's and must
/// last as long as the strip.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeMenus`, `LayoutMenusA`, `LayoutMenuItemsA`, `SetMenuStrip`
///
/// EXAMPLES:
/// ```zig
/// const table = [_]mn.NewMenu{
///     .{ .type = mn.NM_TITLE, .label = "Project" },
///     .{ .type = mn.NM_ITEM, .label = "Open...", .comm_key = "O" },
///     .{ .type = mn.NM_ITEM, .label = mn.NM_BARLABEL },
///     .{ .type = mn.NM_ITEM, .label = "Quit", .comm_key = "Q" },
///     .{ .type = mn.NM_END },
/// };
/// const strip = ib.CreateMenusA(&table, null) orelse return;
/// defer ib.FreeMenus(strip);
/// ```
pub fn CreateMenusA(ib: *IntuitionBase, new_menu: [*]const NewMenu, tags: ?[*]const TagItem) ?*Menu {
    const ub = ib.utility_base;
    const sys = ib.sys_base;
    const error_at: ?*u32 = @ptrFromInt(ub.GetTagData(mn.GTMN_SecondaryError, 0, tags));
    const full = ub.GetTagData(mn.GTMN_FullMenu, 0, tags) != 0;
    const front_pen: graphics.Pen = @truncate(ub.GetTagData(mn.GTMN_FrontPen, 0, tags));

    const needed = tally(new_menu, full) orelse {
        if (error_at) |at| at.* = mn.GTMENU_INVALID;
        return null;
    };
    const bars_bytes = needed.bars * @sizeOf(?*Object);
    const header_at = alignUp(bars_bytes, @alignOf(Header));
    const total = header_at + @sizeOf(Header) + needed.bytes;
    const block: [*]u8 = @ptrCast(sys.AllocVec(total, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        if (error_at) |at| at.* = mn.GTMENU_NOMEM;
        return null;
    });
    const header: *Header = @ptrCast(@alignCast(block + header_at));
    header.* = .{ .start = block, .bars = @ptrCast(@alignCast(block)), .bar_count = 0 };
    const first = block + header_at + @sizeOf(Header);
    var bump = Bump{ .at = first };
    const trimmed = fill(ib, new_menu, &bump, header, front_pen) orelse {
        freeAll(ib, header);
        if (error_at) |at| at.* = mn.GTMENU_NOMEM;
        return null;
    };
    if (error_at) |at| at.* = trimmed;
    return @ptrCast(@alignCast(first));
}

fn alignUp(n: usize, a: usize) usize {
    return (n + a - 1) / a * a;
}

/// Everything a header stands for given back: the separators' images and
/// the allocation.
pub fn freeAll(ib: *IntuitionBase, header: *Header) void {
    const it = ib.iface();
    for (header.bars[0..header.bar_count]) |rule| it.DisposeObject(rule);
    ib.sys_base.FreeVec(header.start);
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;
const kintuition = @import("../intuition.zig");
const kexec = @import("../../exec/exec.zig");
const _screen = @import("../screen/_screen.zig");
const sc = intuition.screens;

/// What a layout reads of a screen, and nothing more: a font, a size, a
/// bar, the pens and the two menu images.
const TestScreen = struct {
    screen: _screen.Screen,
    font: *graphics.TextFont,

    fn up(ts: *TestScreen, ib: *IntuitionBase, width: i32, height: i32) !void {
        const font = ib.graphics_base.OpenFont(&.{ .name = graphics.POSPAZNAME, .y_size = 8 }) orelse return error.NoFont;
        ts.font = font;
        ts.screen = undefined;
        ts.screen.font = font;
        ts.screen.width = width;
        ts.screen.height = height;
        ts.screen.bar_height = 11;
        ts.screen.pens = _screen.default_pens;
        ts.screen.draw_info = .{ .pens = &ts.screen.pens, .font = font };
        const it = ib.iface();
        ts.screen.draw_info.check_mark = it.NewObjectTagList(ib.sys_class, null, &[_]TagItem{
            .{ .tag = ic.SYSIA_Which, .data = ic.MENUCHECK },
            .{ .tag = ic.IA_Width, .data = 15 },
            .{ .tag = ic.IA_Height, .data = 8 },
            .{},
        });
        ts.screen.draw_info.amiga_key = it.NewObjectTagList(ib.sys_class, null, &[_]TagItem{
            .{ .tag = ic.SYSIA_Which, .data = ic.AMIGAKEY },
            .{ .tag = ic.IA_Width, .data = 23 },
            .{ .tag = ic.IA_Height, .data = 8 },
            .{},
        });
    }

    fn down(ts: *TestScreen, ib: *IntuitionBase) void {
        ib.iface().DisposeObject(ts.screen.draw_info.check_mark);
        ib.iface().DisposeObject(ts.screen.draw_info.amiga_key);
        ib.graphics_base.CloseFont(ts.font);
    }

    fn handle(ts: *TestScreen) *intuition.Screen {
        return @ptrCast(&ts.screen);
    }
};

fn runOf(ib: *IntuitionBase, fill_or_next: ?*const anyopaque) _render.Run {
    return _render.runOf(ib.utility_base, @ptrCast(@alignCast(fill_or_next.?)));
}

fn textOf(ib: *IntuitionBase, item: *const MenuItem) [*:0]const u8 {
    return runOf(ib, item.item_fill).text.?;
}

var marker: u8 = 0;

test "CreateMenusA and LayoutMenusA: titles, items, subitems, separators, shortcuts" {
    const ib = try kintuition.setUp();
    defer kexec.deinit();
    const it = ib.iface();

    const table = [_]NewMenu{
        .{ .type = mn.NM_TITLE, .label = "Project", .user_data = &marker },
        .{ .type = mn.NM_ITEM, .label = "Open...", .comm_key = "O", .user_data = &marker },
        .{ .type = mn.NM_ITEM, .label = "Export" },
        .{ .type = mn.NM_SUB, .label = "Text", .comm_key = "T" },
        .{ .type = mn.NM_SUB, .label = "Picture" },
        .{ .type = mn.NM_ITEM, .label = mn.NM_BARLABEL },
        .{ .type = mn.NM_ITEM | mn.NM_IGNORE, .label = "Skipped" },
        .{ .type = mn.NM_ITEM, .label = "Quit", .comm_key = "Q" },
        .{ .type = mn.NM_TITLE, .label = "Options", .flags = mn.NM_MENUDISABLED },
        .{ .type = mn.NM_ITEM, .label = "Grid", .flags = mn.CHECKIT | mn.CHECKED | mn.MENUTOGGLE },
        .{ .type = mn.NM_ITEM, .label = "Size", .comm_key = "Ctrl-S", .flags = mn.NM_COMMANDSTRING | mn.NM_ITEMDISABLED },
        .{ .type = mn.NM_END },
    };
    var err: u32 = 99;
    const strip = it.CreateMenusA(&table, &[_]TagItem{ .{ .tag = mn.GTMN_SecondaryError, .data = @intFromPtr(&err) }, .{} }).?;
    try testing.expectEqual(@as(u32, 0), err);

    // The strip, linked.
    try testing.expectEqualStrings("Project", std.mem.span(strip.name.?));
    try testing.expect(strip.flags & mn.MENUENABLED != 0);
    try testing.expectEqual(@as(?*anyopaque, &marker), mn.GTMENU_USERDATA(strip));
    const options = strip.next_menu.?;
    try testing.expect(options.flags & mn.MENUENABLED == 0);
    try testing.expect(options.next_menu == null);

    const open = strip.first_item.?;
    try testing.expectEqualStrings("Open...", std.mem.span(textOf(ib, open)));
    try testing.expect(open.flags & mn.COMMSEQ != 0 and open.flags & mn.ITEMENABLED != 0 and open.flags & mn.ITEMTEXT != 0);
    try testing.expectEqual(@as(u8, 'O'), open.command);
    try testing.expectEqual(@as(?*anyopaque, &marker), mn.GTMENUITEM_USERDATA(open));
    // An item with subitems shows the mark at its right.
    const export_item = open.next_item.?;
    const export_tags: [*]const TagItem = @ptrCast(@alignCast(export_item.item_fill.?));
    try testing.expectEqualStrings("\xbb", std.mem.span(runOf(ib, runOf(ib, export_tags).next).text.?));
    try testing.expectEqualStrings("Text", std.mem.span(textOf(ib, export_item.sub_item.?)));
    try testing.expectEqualStrings("Picture", std.mem.span(textOf(ib, export_item.sub_item.?.next_item.?)));
    // A separator is an image, neither picked nor highlighted; the entry
    // marked to be skipped is not there.
    const bar = export_item.next_item.?;
    try testing.expect(bar.flags & mn.ITEMTEXT == 0 and bar.flags & mn.ITEMENABLED == 0);
    try testing.expectEqual(mn.HIGHNONE, bar.flags & mn.HIGHFLAGS);
    try testing.expectEqualStrings("Quit", std.mem.span(textOf(ib, bar.next_item.?)));
    // A check item as the table has it; words at the right, disabled.
    const grid = options.first_item.?;
    try testing.expect(grid.flags & (mn.CHECKIT | mn.CHECKED | mn.MENUTOGGLE) == mn.CHECKIT | mn.CHECKED | mn.MENUTOGGLE);
    const size = grid.next_item.?;
    try testing.expect(size.flags & mn.COMMSEQ == 0 and size.flags & mn.ITEMENABLED == 0);
    try testing.expectEqualStrings("Ctrl-S", std.mem.span(runOf(ib, runOf(ib, size.item_fill).next).text.?));

    // Laid out on a screen 640 by 200 with the 8-row font.
    var ts: TestScreen = undefined;
    try ts.up(ib, 640, 200);
    try testing.expect(it.LayoutMenusA(strip, ts.handle(), null));
    try testing.expectEqual(@as(i32, 0), strip.left);
    try testing.expect(options.left > strip.left + strip.width);
    // Items down the panel: a line and a row each, the separator six.
    try testing.expectEqual(@as(i32, 9), open.height);
    try testing.expectEqual(@as(i32, 0), open.top);
    try testing.expectEqual(@as(i32, 9), export_item.top);
    try testing.expectEqual(@as(i32, 6), bar.height);
    try testing.expectEqual(@as(i32, 24), bar.next_item.?.top);
    // One width for the column: room for the words and a shortcut.
    try testing.expectEqual(open.width, bar.next_item.?.width);
    try testing.expect(open.width >= it.IntuiTextLength(export_tags) + 23);
    // The colour is the bar's, the font the screen's; a check item's
    // words start past the mark.
    const export_run = runOf(ib, export_tags);
    try testing.expectEqual(_screen.default_pens[sc.BARDETAILPEN], export_run.front_pen.?);
    try testing.expectEqual(ts.font, export_run.font.?);
    try testing.expectEqual(@as(i32, 2 + 15), runOf(ib, grid.item_fill).left);
    // The mark at the item's right edge.
    try testing.expect(runOf(ib, export_run.next).left > export_run.left);
    // Subitems three quarters across their item, a row above it.
    const text_item = export_item.sub_item.?;
    try testing.expectEqual(export_item.width - (export_item.width >> 2), text_item.left);
    try testing.expectEqual(@as(i32, -1), text_item.top);

    it.FreeMenus(strip);
    ts.down(ib);
    try kintuition.tearDown(ib);
}

test "LayoutMenusA: a panel too tall goes into columns, one too wide moves left" {
    const ib = try kintuition.setUp();
    defer kexec.deinit();
    const it = ib.iface();

    var table: [42]NewMenu = undefined;
    table[0] = .{ .type = mn.NM_TITLE, .label = "Many" };
    for (1..41) |i| table[i] = .{ .type = mn.NM_ITEM, .label = "An item" };
    table[41] = .{ .type = mn.NM_END };
    const strip = it.CreateMenusA(&table, null).?;
    var ts: TestScreen = undefined;
    // 200 high, a bar of 11: 187 rows for items of 9 - twenty to a column.
    try ts.up(ib, 640, 200);
    _ = it.LayoutMenusA(strip, ts.handle(), null);
    var item = strip.first_item.?;
    for (0..20) |_| item = item.next_item.?;
    try testing.expectEqual(@as(i32, 0), item.top);
    try testing.expectEqual(strip.first_item.?.width + 8, item.left);
    ts.down(ib);

    // On a screen as narrow as the panel, moved left to fit.
    try ts.up(ib, 60, 200);
    _ = it.LayoutMenusA(strip, ts.handle(), null);
    try testing.expect(strip.first_item.?.left < 0);
    ts.down(ib);

    it.FreeMenus(strip);
    try kintuition.tearDown(ib);
}

test "CreateMenusA: what is not a menu, and what is too long" {
    const ib = try kintuition.setUp();
    defer kexec.deinit();
    const it = ib.iface();
    var err: u32 = 0;
    const tags = [_]TagItem{ .{ .tag = mn.GTMN_SecondaryError, .data = @intFromPtr(&err) }, .{} };

    // A subitem straight after a title.
    const bad = [_]NewMenu{
        .{ .type = mn.NM_TITLE, .label = "A" },
        .{ .type = mn.NM_SUB, .label = "B" },
        .{ .type = mn.NM_END },
    };
    try testing.expect(it.CreateMenusA(&bad, &tags) == null);
    try testing.expectEqual(mn.GTMENU_INVALID, err);
    // Nothing at all.
    const empty = [_]NewMenu{.{ .type = mn.NM_END }};
    try testing.expect(it.CreateMenusA(&empty, &tags) == null);
    // A panel's items are a menu fragment, refused when a whole strip is
    // asked for.
    const items = [_]NewMenu{ .{ .type = mn.NM_ITEM, .label = "Only" }, .{ .type = mn.NM_END } };
    const full = [_]TagItem{
        .{ .tag = mn.GTMN_SecondaryError, .data = @intFromPtr(&err) },
        .{ .tag = mn.GTMN_FullMenu, .data = 1 },
        .{},
    };
    try testing.expect(it.CreateMenusA(&items, &full) == null);
    try testing.expectEqual(mn.GTMENU_INVALID, err);
    const fragment = it.CreateMenusA(&items, &tags).?;
    const only: *MenuItem = @ptrCast(@alignCast(fragment));
    try testing.expectEqualStrings("Only", std.mem.span(textOf(ib, only)));
    it.FreeMenus(fragment);

    // More titles than menu numbers name: made without the rest.
    var many: [34]NewMenu = undefined;
    for (0..33) |i| many[i] = .{ .type = mn.NM_TITLE, .label = "T" };
    many[33] = .{ .type = mn.NM_END };
    const trimmed = it.CreateMenusA(&many, &tags).?;
    try testing.expectEqual(mn.GTMENU_TRIMMED, err);
    var count: u32 = 0;
    var menu: ?*Menu = trimmed;
    while (menu) |m| : (menu = m.next_menu) count += 1;
    try testing.expectEqual(mn.NOMENU, count);
    it.FreeMenus(trimmed);
    it.FreeMenus(null);

    try kintuition.tearDown(ib);
}
