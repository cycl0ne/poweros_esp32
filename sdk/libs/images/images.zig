// SPDX-License-Identifier: MIT
//! The image classes on the disk: each a library of its own in
//! `SYS:classes/images/`, reached through `LIBS:` as `images/<name>`,
//! its class called by the file's name.
//!
//! An image class is an imageclass subclass: it takes no input and draws
//! itself in its own box (`IM_DRAW`) or fitted to the box it is given
//! (`IM_DRAWFRAME`) - a picture on a button, in a menu, on a tab. A
//! program opens the class's library, makes its images, and closes the
//! library once they are disposed of:
//!
//!   const lib = sys.OpenLibrary(command.COMMAND_LIBRARY, 0) orelse return;
//!   defer sys.CloseLibrary(lib);
//!   const save = ib.NewObjectTagList(null, command.COMMAND_CLASS, &.{
//!       .{ .tag = command.COMMAND_Glyph, .data = command.CMD_SAVE },
//!       .{},
//!   });
//!   defer ib.DisposeObject(save);
//!
//! Each class's tags are in a file of its own here, named after the class,
//! and start at a base of its own: `IMAGES_Dummy` and a step of
//! `IMAGES_Step` for each class, in the order the classes were made - the
//! same plan as the gadget classes', in a range of its own above theirs
//! and the docklets'.

const utility = @import("../utility/utility.zig");

/// Where the disk image classes' tags begin.
pub const IMAGES_Dummy = utility.TAG_USER + 0x0600_0000;
/// How many tags each class has room for.
pub const IMAGES_Step = 0x1_0000;

/// The classes' tags and names, a file each.
pub const command = @import("command.zig");
pub const media = @import("media.zig");
