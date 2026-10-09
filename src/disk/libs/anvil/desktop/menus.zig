// SPDX-License-Identifier: MIT
//! The desktop's menus, as a table `CreateMenusA` makes them from, and
//! their numbers. A bar counts as an item. Every window of the desktop
//! has the same strip: what an item does depends on the window it was
//! picked in and what is selected, and an item that can do nothing there
//! is off.

const sdk = @import("sdk");
const mn = sdk.intuition.menus;

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
pub const ITEM_ABOUT = 6;
pub const ITEM_QUIT = 8;

// Window
pub const ITEM_NEW_DRAWER = 0;
pub const ITEM_OPEN_PARENT = 1;
pub const ITEM_CLOSE = 2;
pub const ITEM_UPDATE = 3;
pub const ITEM_SELECT_CONTENTS = 5;
pub const ITEM_CLEAN_UP = 6;
pub const ITEM_SNAPSHOT_WINDOW = 8;
pub const ITEM_SHOW = 9;
pub const ITEM_VIEW_BY = 10;
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

fn item(label: [*:0]const u8, key: ?[*:0]const u8, flags: u32) mn.NewMenu {
    return .{ .type = mn.NM_ITEM, .label = label, .comm_key = key, .flags = flags };
}

fn sub(label: [*:0]const u8, flags: u32, exclude: u32) mn.NewMenu {
    return .{ .type = mn.NM_SUB, .label = label, .flags = flags, .mutual_exclude = exclude };
}

const bar = mn.NewMenu{ .type = mn.NM_ITEM, .label = mn.NM_BARLABEL };
const pick = mn.CHECKIT;

pub const table = [_]mn.NewMenu{
    .{ .type = mn.NM_TITLE, .label = "Anvil" },
    item("Backdrop", "B", mn.CHECKIT | mn.MENUTOGGLE | mn.CHECKED),
    item("Execute Command...", "E", 0),
    item("Redraw All", null, 0),
    item("Update All", null, 0),
    item("Last Message", null, 0),
    bar,
    item("About...", null, 0),
    bar,
    item("Quit...", "Q", 0),

    .{ .type = mn.NM_TITLE, .label = "Window" },
    item("New Drawer", "N", 0),
    item("Open Parent", "K", 0),
    item("Close", "W", 0),
    item("Update", null, 0),
    bar,
    item("Select Contents", "A", 0),
    item("Clean Up", ".", 0),
    bar,
    item("Snapshot", null, 0),
    sub("Window", 0, 0),
    sub("All", 0, 0),
    item("Show", null, 0),
    sub("Only Icons", pick, 0b10),
    sub("All Files", pick | mn.CHECKED, 0b01),
    item("View By", null, 0),
    sub("Icon", pick | mn.CHECKED, 0b1110),
    sub("Name", pick, 0b1101),
    sub("Date", pick, 0b1011),
    sub("Size", pick, 0b0111),

    .{ .type = mn.NM_TITLE, .label = "Icons" },
    item("Open", "O", 0),
    item("Copy", "C", 0),
    item("Rename...", "R", 0),
    item("Information...", "I", 0),
    item("Snapshot", "S", 0),
    item("UnSnapshot", "U", 0),
    item("Leave Out", "L", 0),
    item("Put Away", "P", 0),
    bar,
    item("Delete...", "D", 0),
    item("Format Disk...", null, 0),
    item("Empty Trash", null, 0),
    .{},
};

/// The whole table into `into`: the menus above, then Tools with an item
/// for each of `labels` - off while there are none. The labels are not
/// copied; `into` must hold `table.len + 1 + labels.len` entries.
pub fn build(into: []mn.NewMenu, labels: []const [*:0]const u8) []mn.NewMenu {
    const fixed = table.len - 1;
    @memcpy(into[0..fixed], table[0..fixed]);
    into[fixed] = .{ .type = mn.NM_TITLE, .label = "Tools", .flags = if (labels.len == 0) mn.NM_MENUDISABLED else 0 };
    for (labels, fixed + 1..) |label, at| into[at] = item(label, null, 0);
    into[fixed + 1 + labels.len] = .{};
    return into[0 .. fixed + 2 + labels.len];
}
