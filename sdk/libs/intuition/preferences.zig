// SPDX-License-Identifier: MIT
//! The settings intuition.library keeps for the whole system: what a
//! program may change while the system runs - set with `SetPrefs`, read
//! with `GetPrefs`, and the ones the system starts with read from
//! `GetDefPrefs` - each a tag (`IPREFS_`).
//!
//!   _ = ib.SetPrefs(&[_]TagItem{
//!       .{ .tag = intuition.IPREFS_DoubleClick, .data = 400 },
//!       .{ .tag = intuition.IPREFS_Keyboard, .data = intuition.KEYBOARD_NEVER },
//!       .{},
//!   });
//!
//!   var ms: u32 = 0;
//!   _ = ib.GetPrefs(&[_]TagItem{ .{ .tag = intuition.IPREFS_DoubleClick, .data = @intFromPtr(&ms) }, .{} });
//!
//! A setting left out keeps its value. To `SetPrefs` a tag's data is the
//! value; to `GetPrefs` and `GetDefPrefs` it is where the value is
//! written, and each tag says what it points to.
//!
//! These are the system's: what every screen and window takes unless it
//! is given its own. A screen's own style and pens are `SetStyle` and
//! `SetScreenPens` with that screen. A change reaches every window that
//! asked for `IDCMP_NEWPREFS`, whichever screen it is on: a window that
//! draws something the settings decide reads them again and draws it
//! anew.

const utility = @import("../utility/utility.zig");

pub const IPREFS_Dummy = utility.TAG_USER + 0x3D000;

/// How far apart two presses may be and still be one double-click, in
/// milliseconds; `DoubleClick` answers by it. Got: a `*u32`.
pub const IPREFS_DoubleClick = IPREFS_Dummy + 1;
/// How tall the font a screen opens with is, in rows, when the screen is
/// given none. Got: a `*u32`.
pub const IPREFS_ScreenFontHeight = IPREFS_Dummy + 2;
/// When a keyboard comes up on the screen while a field is typed into:
/// `KEYBOARD_AUTO`, `KEYBOARD_ALWAYS` or `KEYBOARD_NEVER`. Got: a `*u32`.
pub const IPREFS_Keyboard = IPREFS_Dummy + 3;
/// The font of screens' title bars and menus: a `*graphics.TextFont`,
/// which intuition opens once more for itself, so the caller closes its
/// own; null for pospaz from the ROM. Got: a `*?*graphics.TextFont`,
/// opened for the caller, who closes it.
pub const IPREFS_ScreenFont = IPREFS_Dummy + 4;
/// The font of text in windows and gadgets that name none; as
/// `IPREFS_ScreenFont`.
pub const IPREFS_DefaultFont = IPREFS_Dummy + 5;
/// The font of consoles, which must be fixed-width; as
/// `IPREFS_ScreenFont`.
pub const IPREFS_FixedFont = IPREFS_Dummy + 6;
/// The system's pens: `NUMDRIPENS` colours, a `[*]const graphics.Pen`
/// read once; null for the built-in ones. Every screen opened without
/// pens of its own takes them, those open too. Got: a
/// `*[NUMDRIPENS]graphics.Pen`.
pub const IPREFS_Pens = IPREFS_Dummy + 7;
/// The system's style: a style tag list (`STYLE_`), read once; null for
/// none, which leaves the default. Set only: a style once read is
/// intuition's own, and there is nothing to give back.
pub const IPREFS_Style = IPREFS_Dummy + 8;

/// `IPREFS_Keyboard`: on a board with no keyboard of its own.
pub const KEYBOARD_AUTO: u32 = 0;
/// On every board.
pub const KEYBOARD_ALWAYS: u32 = 1;
/// On none.
pub const KEYBOARD_NEVER: u32 = 2;
