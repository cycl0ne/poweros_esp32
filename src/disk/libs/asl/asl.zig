// SPDX-License-Identifier: MIT
//! asl.library: the requesters a program asks a question with, on the
//! disk in LIBS:.
//!
//! A requester is made once (`request/`), put up as often as wanted, and
//! given back. What it is made of is intuition's classes: a windowclass
//! object holding a layout of gadget objects, which places and sizes
//! everything, so a requester has no geometry of its own and follows the
//! window as it is resized.
//!
//! The file requester is `file/`: the window, the list of entries read a
//! piece at a time between rounds of input, and what the program is
//! answered with. The font and the screen mode requesters are not built
//! yet.
//!
//! The jump table is asl_lvo.zig, the ROM tag, init, open and expunge
//! asl_init.zig, the base asl_base.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const asl_init = @import("asl_init.zig");

comptime {
    _ = &asl_init.asl_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const asl_library_tag = asl_init.asl_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{asl_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [asl_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = asl_init.LIBRARY_VERSION_STRING.*;
