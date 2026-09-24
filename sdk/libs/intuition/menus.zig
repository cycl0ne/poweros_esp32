// SPDX-License-Identifier: MIT
//! Menus: a strip of titles a window shows in its screen's bar while the
//! menu button is held, each with a panel of items, and an item with a
//! panel of subitems of its own.
//!
//! A program builds the strip itself - `Menu` headers linked through
//! `next_menu`, each with its `MenuItem`s linked through `next_item`, an
//! item's subitems through its `sub_item` - and hands it to the window with
//! `SetMenuStrip`. The strip stays the program's: intuition.library reads
//! it and writes the few flags that say what is checked and drawn, and it
//! must be taken off again with `ClearMenuStrip` before it is changed or
//! freed, and before the window closes.
//!
//! **Where things go.** A menu's title is at `left` along the bar, `width`
//! wide. Its panel's items are placed from a corner just under the bar at
//! the title's left; a subitem from the corner of the item it belongs to.
//! The panel is made just big enough for the items and what they show,
//! and at least as wide as the title.
//!
//! **What comes back.** The user picks with the menu button: letting it go
//! over an item picks it, and the select button pressed while it is held
//! picks each item it is dragged over as well. The window gets
//! `IDCMP_MENUPICK` with the first item's **menu number** in `code`, and
//! each item picked carries the next one's in `next_select`, ending in
//! `MENUNULL` - so the program reads the chain with `ItemAddress`. A menu
//! number packs which menu, which item and which subitem into 16 bits;
//! `MENUNUM`, `ITEMNUM` and `SUBNUM` take it apart and `FULLMENUNUM` puts
//! one together. A right-Amiga key with an item's `command` character
//! picks that item without the menus being shown.

/// One title in the strip, and the items of its panel.
pub const Menu = extern struct {
    /// NextMenu: the next title along the bar, or null.
    next_menu: ?*Menu = null,
    /// LeftEdge: where along the bar its title is. TopEdge and Height are
    /// kept for the program; the bar decides both.
    left: i32 = 0,
    top: i32 = 0,
    /// Width: how wide its title is, and so how wide the part of the bar
    /// that opens it.
    width: i32 = 0,
    height: i32 = 0,
    /// Flags: `MENUENABLED`, and `MIDRAWN` while its panel is shown.
    flags: u32 = MENUENABLED,
    /// MenuName: the title, a C string.
    name: ?[*:0]const u8 = null,
    /// FirstItem: the first of its items.
    first_item: ?*MenuItem = null,
    /// JazzX, JazzY, BeatX, BeatY: the panel's corners, worked out by
    /// `SetMenuStrip` from the items. intuition.library's own.
    jazz_x: i32 = 0,
    jazz_y: i32 = 0,
    beat_x: i32 = 0,
    beat_y: i32 = 0,
};

/// One item of a panel, or of an item's own panel.
pub const MenuItem = extern struct {
    /// NextItem: the next item of the same panel, or null.
    next_item: ?*MenuItem = null,
    /// LeftEdge, TopEdge, Width, Height: its box, from the panel's corner.
    /// The pointer over the box is the pointer over the item.
    left: i32 = 0,
    top: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    /// Flags: what it is and how it is shown - `CHECKIT`, `ITEMTEXT`,
    /// `COMMSEQ`, `MENUTOGGLE`, `ITEMENABLED`, a `HIGH` mode, `CHECKED` -
    /// and the bits intuition.library keeps in it while it is shown.
    flags: u32 = ITEMTEXT | ITEMENABLED | HIGHCOMP,
    /// MutualExclude: the other items of the panel this one unchecks when
    /// it is picked, a bit for each by its place - bit 0 the first.
    mutual_exclude: u32 = 0,
    /// ItemFill: what it shows - an `IntuiText` with `ITEMTEXT`, an image
    /// object without.
    item_fill: ?*anyopaque = null,
    /// SelectFill: what it shows while the pointer is over it, for
    /// `HIGHIMAGE`: the same kind of thing as `item_fill`.
    select_fill: ?*anyopaque = null,
    /// Command: the character that picks it with the right-Amiga key, for
    /// `COMMSEQ`.
    command: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// SubItem: the first item of its own panel, or null. An item with
    /// subitems is not picked itself; one of them is.
    sub_item: ?*MenuItem = null,
    /// NextSelect: the menu number of the item picked after this one in
    /// the same session, or `MENUNULL`. intuition.library's own.
    next_select: u32 = MENUNULL,
};

// --- Menu flags -----------------------------------------------------------------

/// It can be opened. A disabled title is shown ghosted, and so are its
/// items; none of them can be picked.
pub const MENUENABLED: u32 = 0x0001;
/// Its panel is shown. intuition.library's own.
pub const MIDRAWN: u32 = 0x0100;

// --- MenuItem flags ---------------------------------------------------------------

/// It is checked and unchecked: picking it sets `CHECKED`, and a checked
/// one shows the window's checkmark at its left.
pub const CHECKIT: u32 = 0x0001;
/// Its `item_fill` and `select_fill` are IntuiTexts; without it, image
/// objects.
pub const ITEMTEXT: u32 = 0x0002;
/// Right-Amiga and `command` picks it, and the panel shows both at its
/// right.
pub const COMMSEQ: u32 = 0x0004;
/// Picking it again unchecks it, rather than leaving it checked.
pub const MENUTOGGLE: u32 = 0x0008;
/// It can be picked. A disabled item is shown ghosted.
pub const ITEMENABLED: u32 = 0x0010;
/// How it is shown while the pointer is over it: one of the four below.
pub const HIGHFLAGS: u32 = 0x00C0;
/// Its `select_fill` in place of its `item_fill`.
pub const HIGHIMAGE: u32 = 0x0000;
/// Its box inverted.
pub const HIGHCOMP: u32 = 0x0040;
/// An inverted frame around its box.
pub const HIGHBOX: u32 = 0x0080;
/// Nothing.
pub const HIGHNONE: u32 = 0x00C0;
/// It is checked. The program may set it before the strip is shown.
pub const CHECKED: u32 = 0x0100;
/// Its subitems are shown. intuition.library's own.
pub const ISDRAWN: u32 = 0x1000;
/// It is shown highlighted. intuition.library's own.
pub const HIGHITEM: u32 = 0x2000;
/// It has been checked or unchecked in this session already, so dragging
/// over it again does not undo that. intuition.library's own.
pub const MENUTOGGLED: u32 = 0x4000;

// --- menu numbers -----------------------------------------------------------------

/// No menu, no item and no subitem: nothing was picked, or the chain
/// ends.
pub const MENUNULL: u32 = 0xFFFF;
/// The parts of a menu number that say "none": a number with `NOITEM` is
/// the title itself, one with `NOSUB` an item with no subitem.
pub const NOMENU: u32 = 0x001F;
pub const NOITEM: u32 = 0x003F;
pub const NOSUB: u32 = 0x001F;

/// Which menu along the strip, from 0.
pub fn MENUNUM(number: u32) u32 {
    return number & 0x1F;
}

/// Which item of its panel, from 0, or `NOITEM`.
pub fn ITEMNUM(number: u32) u32 {
    return (number >> 5) & 0x3F;
}

/// Which subitem of its item's panel, from 0, or `NOSUB`.
pub fn SUBNUM(number: u32) u32 {
    return (number >> 11) & 0x1F;
}

/// The three put together into one menu number.
pub fn FULLMENUNUM(menu: u32, item: u32, sub: u32) u32 {
    return (menu & 0x1F) | ((item & 0x3F) << 5) | ((sub & 0x1F) << 11);
}

/// How much room at an item's left the checkmark takes, and at its right
/// the Amiga key and a character: what a program leaves when it lays
/// items out for the default font.
pub const CHECKWIDTH: i32 = 19;
pub const COMMWIDTH: i32 = 27;
pub const LOWCHECKWIDTH: i32 = 13;
pub const LOWCOMMWIDTH: i32 = 16;

// --- IDCMP_MENUVERIFY -------------------------------------------------------------

/// `code` of the IDCMP_MENUVERIFY the active window gets: its menus are
/// about to be shown. Replying with `code` set to `MENUCANCEL` stops them.
pub const MENUHOT: u32 = 0x0001;
pub const MENUCANCEL: u32 = 0x0002;
/// `code` of the one every other window that asked for IDCMP_MENUVERIFY
/// gets: another window's menus are about to be shown over it. It is told
/// they are gone with IDCMP_MOUSEBUTTONS `MENUUP`.
pub const MENUWAITING: u32 = 0x0003;
