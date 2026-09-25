// SPDX-License-Identifier: MIT
//! string.gadget: a line of text, or a whole number, to type in a ridge.
//!
//! It is strgclass in a frame, and strgclass's attributes are its own:
//! `STRINGA_TextVal` (the text, set and read), `STRINGA_MaxChars`,
//! `STRINGA_LongVal` (the number, set and read), `STRINGA_Justification`,
//! `STRINGA_ReplaceMode`, `STRINGA_EditHook`, `STRINGA_Buffer` and the
//! rest, and `GA_TabCycle` for Tab. Made with `STRINGA_LongVal` and no
//! text, it is a number field: it takes digits and a sign at the start,
//! and nothing else.
//!
//! It ends as strgclass does - Return, Tab, Help with `STRINGA_ExitHelp` -
//! and its window hears `IDCMP_GADGETUP` with strgclass's code; its target
//! hears `STRINGA_TextVal` and `STRINGA_LongVal` as the text changes, with
//! the gadget's `GA_ID`. It is a line of the font high inside its frame and
//! as wide as a layout makes it.
//!
//!   const name = ib.NewObjectTagList(null, st.STRING_CLASS, &.{
//!       .{ .tag = gc.GA_ID, .data = 1 },
//!       .{ .tag = gc.STRINGA_MaxChars, .data = 64 },
//!       .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr("PowerOS") },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const STRING_LIBRARY = "gadgets/string.gadget";
pub const STRING_CLASS = "string.gadget";

/// Its own attributes, when it has any: strgclass's are its own.
pub const STRING_Dummy = gadgets.GADGETS_Dummy + 3 * gadgets.GADGETS_Step;
