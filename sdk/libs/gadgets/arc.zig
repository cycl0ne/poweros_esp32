// SPDX-License-Identifier: MIT
//! arc.gadget: a ring filled round to a level - a progress ring, or a
//! round slider a finger turns.
//!
//! The ring runs clockwise from `ARC_Start` over `ARC_Sweep` degrees (the
//! lower left round to the lower right unless given), `ARC_Width` thick:
//! the whole of it in the style's track colour (`PART_TRACK`), as much of
//! it as the level has come in the indicator's (`PART_INDICATOR`). With
//! `ARC_Turn` it carries a knob at the level (`PART_KNOB`), and a press
//! on it and a drag round it set the level: its target hears `ARC_Level`
//! as it moves (interim) and when it is let go, and the program a
//! `GADGETUP` with the level as its code. A level set by a program fills
//! towards it on motion.library's clock. Given an `ARC_Format`, the level
//! is written in the middle.
//!
//! Degrees are graphics.library's: 0 to the right, anticlockwise up.
//!
//!   const volume = ib.NewObjectTagList(null, ar.ARC_CLASS, &.{
//!       .{ .tag = gc.GA_ID, .data = 7 },
//!       .{ .tag = gc.GA_RelVerify, .data = 1 },
//!       .{ .tag = ar.ARC_Turn, .data = 1 },
//!       .{ .tag = ar.ARC_Format, .data = @intFromPtr("%ld%%") },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const ARC_LIBRARY = "gadgets/arc.gadget";
pub const ARC_CLASS = "arc.gadget";

pub const ARC_Dummy = gadgets.GADGETS_Dummy + 21 * gadgets.GADGETS_Step;
/// Where the ring starts and ends (0 and 100 unless given). Made, set and
/// read; a level outside them is held at the nearer end.
pub const ARC_Min = ARC_Dummy + 0x01;
pub const ARC_Max = ARC_Dummy + 0x02;
/// How far round it is filled. Made, set, read and told.
pub const ARC_Level = ARC_Dummy + 0x03;
/// The angle of the ring's start, in degrees (225). Made and set.
pub const ARC_Start = ARC_Dummy + 0x04;
/// How many degrees the ring covers, clockwise from its start (270).
/// Made and set.
pub const ARC_Sweep = ARC_Dummy + 0x05;
/// How thick the ring is, in pixels (an eighth of its size unless given).
/// Made and set.
pub const ARC_Width = ARC_Dummy + 0x06;
/// Bool: it has a knob and is turned by the pointer (false). Made only.
pub const ARC_Turn = ARC_Dummy + 0x07;
/// The RawDoFmt format the level is written in the middle through: one
/// number, `%ld` or `%d`. None unless given. Not copied.
pub const ARC_Format = ARC_Dummy + 0x08;
