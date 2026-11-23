// SPDX-License-Identifier: MIT
//! hid.library: what a keyboard's or a mouse's reports mean, for the
//! drivers that carry them - usb/hid.device, bluetooth/bthid.device - so a
//! report becomes keys, moves and buttons in one place, whatever brought
//! it. It lives in LIBS:.
//!
//! A function (`function/_function.zig`) is one device read by its report
//! descriptor: `report/layout.zig` reads the descriptor into where each
//! report keeps its keys, its buttons and its move, and
//! `report/report.zig` makes a report into the events keyboard.device and
//! mouse.device take - neither knowing any hardware or the system, so the
//! host tests hold them. The function opens the sources its descriptor
//! calls for, hands each report's events to them, and sends the keyboard's
//! LEDs back through its driver's hook.
//!
//! The jump table is hid_lvo.zig, the ROM tag, init and expunge
//! hid_init.zig, the base hid_base.zig. Each call is a file under
//! `function/`.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const hid_init = @import("hid_init.zig");

comptime {
    _ = &hid_init.hid_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const hid_library_tag = hid_init.hid_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{hid_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [hid_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = hid_init.LIBRARY_VERSION_STRING.*;
