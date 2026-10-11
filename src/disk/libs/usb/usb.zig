// SPDX-License-Identifier: MIT
//! usb.library: the USB buses, the devices on them, their descriptors,
//! and pipes to their endpoints; on the disk in LIBS:.
//!
//! A bus is a unit of a USB host controller device. StartUSB starts one:
//! a process of its own opens the controller, finds its root hub, and
//! from then on keeps what is plugged in - each device given an address
//! and a configuration as it comes, each hub driven by the library's own
//! hub code (`bus/hub.zig`), each other interface offered to the class
//! drivers in `DEVS:usb/` (`bind/`), and everything let go as it goes.
//! The process owns its bus's devices: nothing else changes them, and a
//! program reads them under the list's lock.
//!
//! The jump table is usb_lvo.zig, the ROM tag, init and expunge
//! usb_init.zig, the base usb_base.zig. Each call is a file under its
//! area: `bus/` (starting and stopping a bus, and the process),
//! `list/` (the devices), `descriptor/` (walking what a device said),
//! `pipe/` (transfers), `claim/` (a program's own interfaces),
//! `notify/` (being told of a change); `bind/` is the class drivers.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const usb_init = @import("usb_init.zig");

comptime {
    _ = &usb_init.usb_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const usb_library_tag = usb_init.usb_library_tag;

/// A library is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{usb_init.LIBRARY_NAME});
    return 20;
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [usb_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = usb_init.LIBRARY_VERSION_STRING.*;
