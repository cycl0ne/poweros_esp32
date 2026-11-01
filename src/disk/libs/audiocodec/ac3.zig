// SPDX-License-Identifier: MIT
//! ac3.acodec: a sound module in LIBS:codecs/ - AC-3 and E-AC-3, opened by
//! audiocodec.library for a stream.
//!
//! The ROM tag is ac3/ac3_init.zig, the kind's code ac3/_ac3.zig, the base,
//! init, Expunge and jump table every module shares acodec_module.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const ac3_init = @import("ac3/ac3_init.zig");

comptime {
    _ = &ac3_init.ac3_acodec_tag;
}

/// A module is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a sound module, not a command\n", .{ac3_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [ac3_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = ac3_init.LIBRARY_VERSION_STRING.*;
