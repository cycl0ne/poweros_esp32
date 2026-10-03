// SPDX-License-Identifier: MIT
//! roller.gadget: a wheel of choices, the chosen one in the middle.
//!
//! `ROLLER_Rows` rows of `ROLLER_Labels` are shown, the chosen one in a
//! band across the middle in the style's selection colours
//! (`PART_SELECTION`) and the ones above and below fading towards the
//! background the further they are from it. A drag up or down turns the
//! wheel under the pointer; letting go, it settles on the row nearest the
//! band over a moment on motion.library's clock, and a press that does
//! not move turns to the row it landed on. Its target hears
//! `ROLLER_Selected` and the program a `GADGETUP` with the chosen row as
//! its code. `ROLLER_Wrap` joins the last row to the first. The key in
//! its label turns it down a row, and up with Shift held.
//!
//!   const hours = [_:null]?[*:0]const u8{ "00", "01", ... "23" };
//!   const roller = ib.NewObjectTagList(null, ro.ROLLER_CLASS, &.{
//!       .{ .tag = gc.GA_ID, .data = 3 },
//!       .{ .tag = gc.GA_RelVerify, .data = 1 },
//!       .{ .tag = ro.ROLLER_Labels, .data = @intFromPtr(&hours) },
//!       .{ .tag = ro.ROLLER_Wrap, .data = 1 },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const ROLLER_LIBRARY = "gadgets/roller.gadget";
pub const ROLLER_CLASS = "roller.gadget";

pub const ROLLER_Dummy = gadgets.GADGETS_Dummy + 22 * gadgets.GADGETS_Step;
/// The choices: a `[*:null]const ?[*:0]const u8`, not copied, which the
/// program keeps while the gadget has it. Made and set.
pub const ROLLER_Labels = ROLLER_Dummy + 0x01;
/// The chosen row, from 0. Made, set, read and told; set by a program,
/// the wheel turns there.
pub const ROLLER_Selected = ROLLER_Dummy + 0x02;
/// How many rows are shown, an odd number (5). Made only.
pub const ROLLER_Rows = ROLLER_Dummy + 0x03;
/// Bool: the last row is followed by the first (false). Made and set.
pub const ROLLER_Wrap = ROLLER_Dummy + 0x04;
