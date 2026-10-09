// SPDX-License-Identifier: MIT
//! anvil.library's structures and constants: the desktop, as programs
//! take part in it. The calls are in `sdk.interface.anvil`.
//!
//! **The desktop** is the Workbench screen's ground with an icon for each
//! disk on it, drawers opened into windows of icons, and the programs
//! started from them. It runs on a process of its own, which the library
//! starts (`StartAnvil`, what `C:LoadAnvil` calls) and which ends when it
//! is told to quit.
//!
//! **Programs take part** through three kinds of things they add while the
//! desktop runs: a window files can be dropped on (`AddAppWindow`), an
//! icon on the desktop's ground (`AddAppIcon`), and an item in its Tools
//! menu (`AddAppMenuItem`). Each tells the program through a port of its
//! own with an `AppMessage`: the files concerned as lock-and-name pairs,
//! and for a drop where it was let go. The program replies each one; the
//! desktop frees it then. A program removes what it added before it
//! deletes the port, then replies whatever came meanwhile.

const exec = @import("../exec/exec.zig");
const dos = @import("../dos/dos.zig");
const utility = @import("../utility/utility.zig");

/// The library's name, for OpenLibrary.
pub const ANVILNAME = "anvil.library";

/// `StartAnvil`'s tags.
pub const ANVA_Dummy = utility.TAG_USER + 0x70000;
/// Bool: the disks' icons placed anew down the desktop's edge, their
/// saved places left aside.
pub const ANVA_CleanUp = ANVA_Dummy + 1;

/// What `AddAppWindow`, `AddAppIcon` and `AddAppMenuItem` give back, to
/// hand to their `Remove...`: the desktop's, never read by the program.
pub const AppWindow = opaque {};
pub const AppIcon = opaque {};
pub const AppMenuItem = opaque {};

/// What the desktop sends a program's port when its window, icon or menu
/// item is used. The program reads it and replies it; the files' locks
/// and names are the desktop's, and go when it is replied.
pub const AppMessage = extern struct {
    message: exec.Message = .{},
    /// `AMTYPE_APPWINDOW`, `AMTYPE_APPICON` or `AMTYPE_APPMENUITEM`.
    kind: u32 = 0,
    /// What the program gave when it added the window, icon or item.
    id: u32 = 0,
    user_data: usize = 0,
    /// The files: those dropped, or the icons picked when a menu item was
    /// chosen; none for an icon double-clicked.
    num_args: u32 = 0,
    arg_list: ?[*]dos.WBArg = null,
    /// `AM_VERSION`.
    version: u32 = AM_VERSION,
    /// Where they were let go on an AppWindow, in the window's own
    /// coordinates; 0 for anything else.
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    /// When, as the input event said.
    seconds: u32 = 0,
    micros: u32 = 0,
};

/// `AppMessage.kind`.
pub const AMTYPE_APPWINDOW: u32 = 1;
pub const AMTYPE_APPICON: u32 = 2;
pub const AMTYPE_APPMENUITEM: u32 = 3;

/// `AppMessage.version` as this SDK makes it.
pub const AM_VERSION: u32 = 1;

/// A window files can be dropped on, without a program dealing with the
/// desktop's calls itself (`drop.zig`).
pub const drop = @import("drop.zig");
pub const DropTarget = drop.DropTarget;
pub const Dropped = drop.Dropped;
