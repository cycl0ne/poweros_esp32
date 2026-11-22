// SPDX-License-Identifier: MIT
//! bluetooth.library: the Bluetooth stack - on the disk in LIBS:.
//!
//! The controllers are units of devices that speak DEVIF_HCI
//! (sdk/devices/hci.zig), offered by their drivers (`controller/`). The
//! library's task (`task/`) owns them all: it keeps reads queued on each,
//! runs the HCI (`hci/`) - the commands within the controller's credits,
//! each answer matched to its command, a time-out for each - and brings
//! each controller up. Whoever asked is told when the controllers change
//! (`notify/`).
//!
//! The jump table is bluetooth_lvo.zig, the ROM tag, init and expunge
//! bluetooth_init.zig, the base bluetooth_base.zig. Each call is a file
//! in its area's folder.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const bluetooth_init = @import("bluetooth_init.zig");

comptime {
    _ = &bluetooth_init.bluetooth_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const bluetooth_library_tag = bluetooth_init.bluetooth_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{bluetooth_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [bluetooth_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = bluetooth_init.LIBRARY_VERSION_STRING.*;
