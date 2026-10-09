// SPDX-License-Identifier: MIT
//! anvil.library: the desktop, on the disk in LIBS:. It holds the calls
//! programs take part in the desktop with, and the desktop itself, which
//! runs on a process of its own that the library starts.
//!
//! **The desktop** (`desktop/`) is the Workbench screen's ground - a
//! colour, a gradient or a picture, as `ENV:Sys/anvil.prefs` says - with
//! an icon for each disk on it (`icons/`), and the screen's title saying
//! how much memory is free. It runs until it is told to quit, holding the
//! library open the while: dos closes that count only once its code has
//! returned, so the library cannot go under it.
//!
//! The jump table is anvil_lvo.zig, the ROM tag, init and expunge
//! anvil_init.zig, the base anvil_base.zig. The calls are under `start/`.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const anvil_init = @import("anvil_init.zig");

comptime {
    _ = &anvil_init.anvil_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const anvil_library_tag = anvil_init.anvil_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{anvil_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [anvil_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = anvil_init.LIBRARY_VERSION_STRING.*;
