// SPDX-License-Identifier: MIT
//! keyboard.gadget: keys on the screen, for a board with none of its own.
//!
//! Five rows of keys laid out as a keyboard is - the digits, three rows
//! of letters, the space bar - each labelled with what the keymap in use
//! gives it, so a German keymap shows QWERTZ and its umlauts. Shift turns
//! the labels for the next key and then lets go; the page key shows the
//! keymap's Alt layer of the same keys, its symbols. A key pressed is
//! shown again, larger, above itself.
//!
//! A key goes down and up as a raw key through input.device, with Shift
//! or Alt as its qualifier, the moment it is pressed - so it reaches
//! whatever has the keyboard, a string gadget, a console or a program, as
//! a key from a keyboard would - and again while it is held, as a held
//! key repeats. The keys take their look from the style's `PART_MAIN`
//! (pressed while held, checked for Shift and the page key).
//!
//! intuition opens one by itself at the bottom of the screen when a field
//! gets the input on a board with no keyboard (`IPREFS_Keyboard`).
//!
//!   const keys = ib.NewObjectTagList(null, kb.KEYBOARD_CLASS, &.{
//!       .{ .tag = gc.GA_RelWidth, .data = 0 },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const KEYBOARD_LIBRARY = "gadgets/keyboard.gadget";
pub const KEYBOARD_CLASS = "keyboard.gadget";

pub const KEYBOARD_Dummy = gadgets.GADGETS_Dummy + 28 * gadgets.GADGETS_Step;
/// Bool: Shift is on for the next key. Made, set and read.
pub const KEYBOARD_Shift = KEYBOARD_Dummy + 0x01;
/// Bool: the symbols page is shown. Made, set and read.
pub const KEYBOARD_Symbols = KEYBOARD_Dummy + 0x02;
