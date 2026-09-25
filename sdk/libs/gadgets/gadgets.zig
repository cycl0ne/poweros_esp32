// SPDX-License-Identifier: MIT
//! The gadget classes on the disk: each a library of its own in
//! `SYS:classes/gadgets/`, reached through `LIBS:`.
//!
//! A program opens the class's library, which makes the class and puts it
//! on the public list, and then asks for the class by name. It closes the
//! library once its objects are disposed of:
//!
//!   const lib = sys.OpenLibrary("gadgets/checkbox.gadget", 0) orelse return;
//!   defer sys.CloseLibrary(lib);
//!   const box = ib.NewObjectTagList(null, "checkbox.gadget", &tags);
//!   defer ib.DisposeObject(box);
//!
//! Each class's tags are in a file of its own here, named after the class,
//! and start at a base of its own: `GADGETS_Dummy` and a step of
//! `GADGETS_Step` for each class, in the order the classes were made. The
//! range lies far above intuition's own classes (`TAG_USER + 0x20000` to
//! `0x50000`), so a disk class can be given to a layout or a window
//! object, whose tags are intuition's, without its tags being mistaken for
//! theirs.

const utility = @import("../utility/utility.zig");

/// Where the disk gadget classes' tags begin.
pub const GADGETS_Dummy = utility.TAG_USER + 0x0400_0000;
/// How many tags each class has room for.
pub const GADGETS_Step = 0x1_0000;

/// A class library's base, and what makes one (`classlibrary.zig`).
pub const classlibrary = @import("classlibrary.zig");
pub const ClassLibrary = classlibrary.ClassLibrary;
pub const Base = classlibrary.Base;
pub const baseOf = classlibrary.baseOf;
/// What every class draws, tells and measures the same way (`support.zig`).
pub const support = @import("support.zig");

/// The classes' tags and names, a file each.
pub const checkbox = @import("checkbox.zig");
pub const cycle = @import("cycle.zig");
pub const radiobutton = @import("radiobutton.zig");
pub const string = @import("string.zig");
pub const text = @import("text.zig");
pub const slider = @import("slider.zig");
