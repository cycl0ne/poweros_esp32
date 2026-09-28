// SPDX-License-Identifier: MIT
//! radiobutton.gadget: a column of choices of which one is on, each a
//! round mark with its text to the right. A press on a choice that is not
//! the one on makes it the one, and its window hears `IDCMP_GADGETUP` at
//! once with the choice's number as the code, and its target
//! `RADIO_Active`; a press on the one already on says nothing.
//!
//! The whole column is one gadget. The marks are sized to the font, one
//! line of the font apart and `RADIO_Spacing` more.
//!
//!   const labels = [_:null]?[*:0]const u8{ "Serial", "USB", "None" };
//!   const radio = ib.NewObjectTagList(null, rb.RADIO_CLASS, &.{
//!       .{ .tag = gc.GA_ID, .data = 3 },
//!       .{ .tag = rb.RADIO_Labels, .data = @intFromPtr(&labels) },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const RADIO_LIBRARY = "gadgets/radiobutton.gadget";
pub const RADIO_CLASS = "radiobutton.gadget";

pub const RADIO_Dummy = gadgets.GADGETS_Dummy + 2 * gadgets.GADGETS_Step;
/// The choices: a `[*:null]const ?[*:0]const u8`, not copied, with at
/// least one. Made only; a gadget made without it is not made.
pub const RADIO_Labels = RADIO_Dummy + 0x01;
/// The number of the choice that is on, from 0. Made, set and read; told
/// to the target when a press changes it. Past the last choice is the
/// last.
pub const RADIO_Active = RADIO_Dummy + 0x02;
/// Pixels between one line of choices and the next, beyond the line
/// itself. Made only; 1 unless given.
pub const RADIO_Spacing = RADIO_Dummy + 0x03;
/// Bool, made only: the marks are as big as the room a layout gives the
/// group, rather than a line of the font - the lines are spread over the
/// height and each mark grown to its line. For a touch screen, where a
/// mark a line of text high is smaller than a fingertip.
pub const RADIO_Scaled = RADIO_Dummy + 0x04;
