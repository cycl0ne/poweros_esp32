// SPDX-License-Identifier: MIT
//! The desktop's menus, as a table `CreateMenusA` makes them from, and
//! their numbers. A bar counts as an item. Every window of the desktop
//! has the same strip: what an item does depends on the window it was
//! picked in and what is selected, and an item that can do nothing there
//! is off. The table holds each label's string (`anvil.cd`), and the
//! labels are put in from the catalog of the language the user prefers
//! as the strip is made (`build`).

const sdk = @import("sdk");
const mn = sdk.intuition.menus;
const strings = @import("strings");
const Text = sdk.locale.Strings(strings);
const Id = strings.Id;

pub const MENU_ANVIL = 0;
pub const MENU_WINDOW = 1;
pub const MENU_ICONS = 2;
/// The items programs add (AddAppMenuItem), in the order they came.
pub const MENU_TOOLS = 3;

// Anvil
pub const ITEM_BACKDROP = 0;
pub const ITEM_EXECUTE = 1;
pub const ITEM_REDRAW_ALL = 2;
pub const ITEM_UPDATE_ALL = 3;
pub const ITEM_LAST_MESSAGE = 4;
pub const ITEM_VOLUME = 6;
pub const ITEM_ABOUT = 7;
pub const ITEM_QUIT = 9;
/// The machine started again, every drive held still first.
pub const ITEM_REBOOT = 10;

// Window
pub const ITEM_NEW_DRAWER = 0;
pub const ITEM_OPEN_PARENT = 1;
pub const ITEM_BACK = 2;
pub const ITEM_FORWARD = 3;
pub const ITEM_CLOSE = 4;
pub const ITEM_UPDATE = 5;
/// A shell whose current directory is the drawer.
pub const ITEM_SHELL = 6;
pub const ITEM_SELECT_CONTENTS = 8;
pub const ITEM_CLEAN_UP = 9;
pub const ITEM_CLEAN_UP_BY = 10;
pub const ITEM_SNAP_TO_GRID = 11;
/// The icons the desktop placed laid out again as a drawer's window is
/// sized.
pub const ITEM_ARRANGE = 12;
pub const ITEM_SNAPSHOT_WINDOW = 14;
pub const ITEM_SHOW = 15;
pub const ITEM_VIEW_BY = 16;
/// Every drawer's window with its ribbon, or none.
pub const ITEM_RIBBON = 18;
/// Clean Up By's subitems.
pub const SUB_CLEAN_BY_NAME = 0;
pub const SUB_CLEAN_BY_DATE = 1;
pub const SUB_CLEAN_BY_SIZE = 2;
/// Snapshot's subitems.
pub const SUB_SNAPSHOT_WINDOW = 0;
pub const SUB_SNAPSHOT_ALL = 1;
/// Show's subitems.
pub const SUB_ONLY_ICONS = 0;
pub const SUB_ALL_FILES = 1;
/// View By's subitems, in `View`'s order.
pub const SUB_BY_ICON = 0;
pub const SUB_BY_NAME = 1;
pub const SUB_BY_DATE = 2;
pub const SUB_BY_SIZE = 3;

// Icons
pub const ITEM_OPEN = 0;
pub const ITEM_COPY = 1;
pub const ITEM_RENAME = 2;
pub const ITEM_INFORMATION = 3;
pub const ITEM_SNAPSHOT = 4;
pub const ITEM_UNSNAPSHOT = 5;
pub const ITEM_LEAVE_OUT = 6;
pub const ITEM_PUT_AWAY = 7;
pub const ITEM_DELETE = 9;
pub const ITEM_FORMAT = 10;
pub const ITEM_EMPTY_TRASH = 11;

/// A menu's entry, and the string its label is.
pub const Entry = struct { menu: mn.NewMenu, text: ?Id = null };

fn title(text: Id) Entry {
    return .{ .menu = .{ .type = mn.NM_TITLE, .label = strings.builtin(text) }, .text = text };
}

fn item(text: Id, key: ?[*:0]const u8, flags: u32) Entry {
    return .{ .menu = .{ .type = mn.NM_ITEM, .label = strings.builtin(text), .comm_key = key, .flags = flags }, .text = text };
}

fn sub(text: Id, flags: u32, exclude: u32) Entry {
    return .{ .menu = .{ .type = mn.NM_SUB, .label = strings.builtin(text), .flags = flags, .mutual_exclude = exclude }, .text = text };
}

const bar = Entry{ .menu = .{ .type = mn.NM_ITEM, .label = mn.NM_BARLABEL } };
const pick = mn.CHECKIT;

pub const table = [_]Entry{
    title(.MSG_MENU_ANVIL),
    item(.MSG_MENU_BACKDROP, "B", mn.CHECKIT | mn.MENUTOGGLE | mn.CHECKED),
    item(.MSG_MENU_EXECUTE, "E", 0),
    item(.MSG_MENU_REDRAW_ALL, null, 0),
    item(.MSG_MENU_UPDATE_ALL, null, 0),
    item(.MSG_MENU_LAST_MESSAGE, null, 0),
    bar,
    item(.MSG_MENU_VOLUME, null, 0),
    item(.MSG_MENU_ABOUT, null, 0),
    bar,
    item(.MSG_MENU_QUIT, "Q", 0),
    item(.MSG_MENU_REBOOT, null, 0),

    title(.MSG_MENU_WINDOW),
    item(.MSG_MENU_NEW_DRAWER, "N", 0),
    item(.MSG_MENU_OPEN_PARENT, "K", 0),
    item(.MSG_MENU_BACK, null, 0),
    item(.MSG_MENU_FORWARD, null, 0),
    item(.MSG_MENU_CLOSE, "W", 0),
    item(.MSG_MENU_UPDATE, null, 0),
    item(.MSG_MENU_SHELL, null, 0),
    bar,
    item(.MSG_MENU_SELECT_CONTENTS, "A", 0),
    item(.MSG_MENU_CLEAN_UP, ".", 0),
    item(.MSG_MENU_CLEAN_UP_BY, null, 0),
    sub(.MSG_MENU_BY_NAME, 0, 0),
    sub(.MSG_MENU_BY_DATE, 0, 0),
    sub(.MSG_MENU_BY_SIZE, 0, 0),
    item(.MSG_MENU_SNAP, null, mn.CHECKIT | mn.MENUTOGGLE),
    item(.MSG_MENU_ARRANGE, null, mn.CHECKIT | mn.MENUTOGGLE | mn.CHECKED),
    bar,
    item(.MSG_MENU_SNAPSHOT, null, 0),
    sub(.MSG_MENU_SNAPSHOT_WINDOW, 0, 0),
    sub(.MSG_MENU_SNAPSHOT_ALL, 0, 0),
    item(.MSG_MENU_SHOW, null, 0),
    sub(.MSG_MENU_ONLY_ICONS, pick, 0b10),
    sub(.MSG_MENU_ALL_FILES, pick | mn.CHECKED, 0b01),
    item(.MSG_MENU_VIEW_BY, null, 0),
    sub(.MSG_MENU_BY_ICON, pick | mn.CHECKED, 0b1110),
    sub(.MSG_MENU_BY_NAME, pick, 0b1101),
    sub(.MSG_MENU_BY_DATE, pick, 0b1011),
    sub(.MSG_MENU_BY_SIZE, pick, 0b0111),
    bar,
    item(.MSG_MENU_RIBBON, null, mn.CHECKIT | mn.MENUTOGGLE),

    title(.MSG_MENU_ICONS),
    item(.MSG_MENU_OPEN, "O", 0),
    item(.MSG_MENU_COPY, "C", 0),
    item(.MSG_MENU_RENAME, "R", 0),
    item(.MSG_MENU_INFORMATION, "I", 0),
    item(.MSG_MENU_SNAPSHOT, "S", 0),
    item(.MSG_MENU_UNSNAPSHOT, "U", 0),
    item(.MSG_MENU_LEAVE_OUT, "L", 0),
    item(.MSG_MENU_PUT_AWAY, "P", 0),
    bar,
    item(.MSG_MENU_DELETE, "D", 0),
    item(.MSG_MENU_FORMAT, null, 0),
    item(.MSG_MENU_EMPTY_TRASH, null, 0),
    .{ .menu = .{} },
};

/// The whole table into `into`, each label in `text`'s language: the
/// menus above, then Tools with an item for each of `labels` - off while
/// there are none. The labels are not copied; `into` must hold
/// `table.len + 1 + labels.len` entries.
pub fn build(into: []mn.NewMenu, text: *const Text, labels: []const [*:0]const u8) []mn.NewMenu {
    const fixed = table.len - 1;
    for (table[0..fixed], into[0..fixed]) |entry, *made| {
        made.* = entry.menu;
        if (entry.text) |id| made.label = text.get(id);
    }
    into[fixed] = .{ .type = mn.NM_TITLE, .label = text.get(.MSG_MENU_TOOLS), .flags = if (labels.len == 0) mn.NM_MENUDISABLED else 0 };
    for (labels, fixed + 1..) |label, at| into[at] = .{ .type = mn.NM_ITEM, .label = label };
    into[fixed + 1 + labels.len] = .{};
    return into[0 .. fixed + 2 + labels.len];
}
