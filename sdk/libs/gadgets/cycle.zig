// SPDX-License-Identifier: MIT
//! cycle.gadget: a button that shows one of a list of choices and steps
//! to the next each time it is pressed and let go over - to the one
//! before with Shift held - wrapping round at either end. Its window hears
//! `IDCMP_GADGETUP` with the new choice's number as the code, and its
//! target `CYCLE_Active`.
//!
//! It is drawn as a button frame with the cycle glyph at its left, a
//! divider, and the choice centred in the rest; it is as wide as its
//! widest choice needs, and a layout may make it wider.
//!
//!   const labels = [_:null]?[*:0]const u8{ "Low", "Medium", "High" };
//!   const cycle = ib.NewObjectTagList(null, cy.CYCLE_CLASS, &.{
//!       .{ .tag = gc.GA_ID, .data = 2 },
//!       .{ .tag = cy.CYCLE_Labels, .data = @intFromPtr(&labels) },
//!       .{ .tag = cy.CYCLE_Active, .data = 1 },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const CYCLE_LIBRARY = "gadgets/cycle.gadget";
pub const CYCLE_CLASS = "cycle.gadget";

pub const CYCLE_Dummy = gadgets.GADGETS_Dummy + 1 * gadgets.GADGETS_Step;
/// The choices: a `[*:null]const ?[*:0]const u8`, not copied, with at
/// least one. Made and set; a gadget made without it is not made.
pub const CYCLE_Labels = CYCLE_Dummy + 0x01;
/// The number of the choice shown, from 0. Made, set and read; told to the
/// target when a press changes it. Past the last choice is the last.
pub const CYCLE_Active = CYCLE_Dummy + 0x02;
