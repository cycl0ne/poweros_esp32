// SPDX-License-Identifier: MIT
//! getfile.gadget: the name of a file, typed or asked for.
//!
//! A field with a button beside it. The field is a `string.gadget` and
//! holds the whole path; the button opens asl.library's file requester,
//! and what is picked goes into the field. A program reads
//! `GETFILE_Drawer` and `GETFILE_File`, or `GETFILE_FullFile` for the
//! two joined.
//!
//! The requester is opened on a process of its own, because the press
//! that asks for it arrives on the input handler, which may neither draw
//! nor wait. A program hears the answer through the gadget's
//! `ICA_TARGET`, so an `ICTARGET_IDCMP` gadget tells its window.
//!
//!   const field = ib.NewObjectTagList(null, gf.GETFILE_CLASS, &.{
//!       .{ .tag = gf.GETFILE_TitleText, .data = @intFromPtr("Which file?") },
//!       .{ .tag = gf.GETFILE_Drawer, .data = @intFromPtr("SYS:") },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const GETFILE_LIBRARY = "gadgets/getfile.gadget";
pub const GETFILE_CLASS = "getfile.gadget";

pub const GETFILE_Dummy = gadgets.GADGETS_Dummy + 17 * gadgets.GADGETS_Step;

/// What the requester is called. Made and set.
pub const GETFILE_TitleText = GETFILE_Dummy + 0x01;
/// Bool: the field cannot be typed in, only the button used. Made and
/// set.
pub const GETFILE_ReadOnly = GETFILE_Dummy + 0x02;
/// The drawer the file is in, copied. Made, set and read.
pub const GETFILE_Drawer = GETFILE_Dummy + 0x03;
/// The file's own name, copied. Made, set and read.
pub const GETFILE_File = GETFILE_Dummy + 0x04;
/// The two joined, which is what the field shows. Read only, and only
/// good until the gadget changes.
pub const GETFILE_FullFile = GETFILE_Dummy + 0x05;
/// The pattern the requester shows, copied. Made and set.
pub const GETFILE_Pattern = GETFILE_Dummy + 0x06;
/// Bool: the requester asks where to save rather than what to open.
pub const GETFILE_DoSaveMode = GETFILE_Dummy + 0x07;
/// Bool: only drawers are shown, and a drawer is what is picked.
pub const GETFILE_DrawersOnly = GETFILE_Dummy + 0x08;
