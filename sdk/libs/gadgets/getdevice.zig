// SPDX-License-Identifier: MIT
//! getdevice.gadget: a unit of a device, named or asked for.
//!
//! A field with a button beside it. The field is a `string.gadget` and
//! shows the device's name and the unit (`serial.device 1`); the button
//! opens asl.library's device requester, which lists the units of the
//! devices that speak `GETDEVICE_Speaks`, and what is picked goes into
//! the field. A program reads `GETDEVICE_Device` and `GETDEVICE_Unit`,
//! which are what `OpenDevice` takes.
//!
//! The requester is opened on a process of its own, because the press
//! that asks for it arrives on the input handler, which may neither draw
//! nor wait. A program hears the answer through the gadget's
//! `ICA_TARGET`, so an `ICTARGET_IDCMP` gadget tells its window.
//!
//!   const field = ib.NewObjectTagList(null, gd.GETDEVICE_CLASS, &.{
//!       .{ .tag = gd.GETDEVICE_TitleText, .data = @intFromPtr("Which serial line?") },
//!       .{ .tag = gd.GETDEVICE_Speaks, .data = devices.DEVIF_SERIAL },
//!       .{ .tag = gd.GETDEVICE_Device, .data = @intFromPtr("serial.device") },
//!       .{ .tag = gd.GETDEVICE_Unit, .data = 1 },
//!       .{},
//!   });

const gadgets = @import("gadgets.zig");

/// What a program opens, and the class it then asks for.
pub const GETDEVICE_LIBRARY = "gadgets/getdevice.gadget";
pub const GETDEVICE_CLASS = "getdevice.gadget";

pub const GETDEVICE_Dummy = gadgets.GADGETS_Dummy + 32 * gadgets.GADGETS_Step;

/// What the requester is called. Made and set.
pub const GETDEVICE_TitleText = GETDEVICE_Dummy + 0x01;
/// Bool: the field cannot be typed in, only the button used.
pub const GETDEVICE_ReadOnly = GETDEVICE_Dummy + 0x02;
/// The device's name, as `OpenDevice` takes it, copied. Made, set and
/// read.
pub const GETDEVICE_Device = GETDEVICE_Dummy + 0x03;
/// The unit. Made, set and read.
pub const GETDEVICE_Unit = GETDEVICE_Dummy + 0x04;
/// What the board calls the unit picked in the requester; empty for a
/// unit typed or set. Read only, and only good until the gadget changes.
pub const GETDEVICE_Label = GETDEVICE_Dummy + 0x05;
/// The command set the requester lists the units of: a `DEVIF_*` of
/// sdk/libs/expansion/devices.zig, 0 for every device. Made and set.
pub const GETDEVICE_Speaks = GETDEVICE_Dummy + 0x06;
