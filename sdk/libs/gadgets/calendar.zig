// SPDX-License-Identifier: MIT
//! calendar.gadget: a month as a grid of days, to pick a day from.
//!
//! A line with the month and the year between two arrows, the names of the
//! weekdays, and six weeks of days - the month's, and the ends of the
//! months either side faded. The chosen day (`CALENDAR_Day`) is filled in
//! the style's selection colours (`PART_SELECTION`), today
//! (`CALENDAR_Today`) has a ring round it in the indicator's, and a day
//! the program's `CALENDAR_MarkHook` answers true for has a dot under it.
//! The arrows turn to the month before and after; a press on a day
//! chooses it - and turns to its month - and its target hears
//! `CALENDAR_Day` and the program a `GADGETUP` with the day as its code.
//! The key in its label moves to the next day, and back with Shift.
//!
//! A day is a day number, days since 1 January 1978: what a dos
//! `DateStamp` counts in `days`, and what utility.library's `DateSplit`
//! and `DateJoin` turn into a date and back.
//!
//!   const picker = ib.NewObjectTagList(null, ca.CALENDAR_CLASS, &.{
//!       .{ .tag = gc.GA_ID, .data = 4 },
//!       .{ .tag = gc.GA_RelVerify, .data = 1 },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const CALENDAR_LIBRARY = "gadgets/calendar.gadget";
pub const CALENDAR_CLASS = "calendar.gadget";

pub const CALENDAR_Dummy = gadgets.GADGETS_Dummy + 23 * gadgets.GADGETS_Step;
/// The chosen day, a day number (today unless given). Made, set, read and
/// told; set, the calendar turns to its month.
pub const CALENDAR_Day = CALENDAR_Dummy + 0x01;
/// Today, a day number, ringed (dos.library's date unless given). Made
/// and set.
pub const CALENDAR_Today = CALENDAR_Dummy + 0x02;
/// The weekday a week starts on, 0 Sunday to 6 Saturday (1, Monday).
/// Made and set.
pub const CALENDAR_FirstWeekday = CALENDAR_Dummy + 0x03;
/// A `*utility.Hook` asked for each day shown, the gadget as the object
/// and a `*const u32` day number as the message: true puts a dot under
/// the day. Called while the gadget draws: it may not draw or wait. Made
/// and set.
pub const CALENDAR_MarkHook = CALENDAR_Dummy + 0x04;
