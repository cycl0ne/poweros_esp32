// SPDX-License-Identifier: MIT
//! icon.library's structures and constants: an icon - the picture a file
//! is shown with, and the fields that go with it - as a program holds it.
//! The calls are in `sdk.interface.icon`.
//!
//! **An icon is a file beside the one it belongs to**: `Notes.info` is
//! `Notes`'s, `Work.info` the drawer `Work`'s, `Disk.info` in a volume's
//! root the volume's. It is a PNG, its fields as text in a chunk of its
//! own (`file.zig`), so any paint program draws one.
//!
//! **What an icon is**: its kind (`WBDISK` to `WBGARBAGE`), where it
//! sits in its drawer, the program that opens it (`default_tool`), the
//! words that program reads from it (`tool_types`, `NAME=value` each),
//! the stack the program gets, and for a disk or a drawer the window it
//! opens into (`DrawerData`). The picture is `image`, shared and read
//! only.
//!
//! **An icon the library made is the library's to free**:
//! `FreeDiskObject` frees what was made for it, whatever its fields point
//! at by then - so a program may point `tool_types` at an array of its
//! own to write the icon, and the array stays the program's.

/// The library's name, for OpenLibrary.
pub const ICONNAME = "icon.library";

/// What an icon stands for: a volume, a drawer, a program, a file a
/// program opens, the trash - and an icon a program put on the desktop
/// for itself, which is never a file.
pub const WBDISK: u32 = 1;
pub const WBDRAWER: u32 = 2;
pub const WBTOOL: u32 = 3;
pub const WBPROJECT: u32 = 4;
pub const WBGARBAGE: u32 = 5;
pub const WBAPPICON: u32 = 8;

/// `current_x`, `current_y`: no place of its own; whoever shows the icon
/// places it.
pub const NO_ICON_POSITION: i32 = -0x8000_0000;

/// The longest name an icon belongs to: with `.info` behind it, it is
/// still a name dos takes.
pub const ICON_NAME_MAX = 255 - 5;

/// `DrawerData.view_modes`: how the drawer is shown - as the one showing
/// it likes, as icons, or as a list by name, date or size.
pub const DDVM_BYDEFAULT: u32 = 0;
pub const DDVM_BYICON: u32 = 1;
pub const DDVM_BYNAME: u32 = 2;
pub const DDVM_BYDATE: u32 = 3;
pub const DDVM_BYSIZE: u32 = 4;

/// `DrawerData.flags`: which files it shows - as the one showing it
/// likes, only those with icons, or all.
pub const DDFLAGS_SHOWDEFAULT: u32 = 0;
pub const DDFLAGS_SHOWICONS: u32 = 1;
pub const DDFLAGS_SHOWALL: u32 = 2;

/// The window a disk or a drawer opens into, and how it shows what is in
/// it. A box of no width or height is no box: whoever opens it chooses.
pub const DrawerData = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    /// How far its view is scrolled.
    current_x: i32 = 0,
    current_y: i32 = 0,
    /// `DDFLAGS_*` and `DDVM_*`.
    flags: u32 = DDFLAGS_SHOWDEFAULT,
    view_modes: u32 = DDVM_BYDEFAULT,
};

/// An icon's picture: `width` by `height` pixels, four bytes each - red,
/// green, blue and coverage (`rtg.PixelFormat.rgba32`, what
/// `BlendPixelArray` draws), a row `width * 4` bytes. Shared by every
/// icon that shows it and read only; it goes with the last of them.
pub const IconImage = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    pixels: [*]const u8,
};

/// An icon as a program holds it.
pub const DiskObject = extern struct {
    /// `WBDISK` to `WBGARBAGE`, or `WBAPPICON`.
    kind: u32 = 0,
    /// Its place in its drawer, or `NO_ICON_POSITION`.
    current_x: i32 = NO_ICON_POSITION,
    current_y: i32 = NO_ICON_POSITION,
    /// The program that opens a project or a disk; null for none.
    default_tool: ?[*:0]const u8 = null,
    /// The tool types, `NAME=value` or `NAME` each, ended by a null.
    tool_types: ?[*]const ?[*:0]const u8 = null,
    /// The stack a program started from it gets; 0 for the usual.
    stack_size: u32 = 0,
    /// A disk's, a drawer's or the trash's window; null for other kinds.
    drawer_data: ?*DrawerData = null,
    /// The picture; null only in an icon made empty.
    image: ?*const IconImage = null,
};

/// The icon file: the fields as text in a PNG's `icOn` chunk, read and
/// written (sdk/libs/icon/file.zig).
pub const file = @import("file.zig");
