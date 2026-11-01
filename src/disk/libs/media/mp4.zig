// SPDX-License-Identifier: MIT
//! mp4.container: a container module in LIBS:codecs/ - MP4 and QuickTime files, their index read whole, opened by
//! media.library for a file.
//!
//! The ROM tag is mp4/mp4_init.zig, the kind's code mp4/_mp4.zig, the base,
//! init, Expunge and jump table every module shares mcontainer_module.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const mp4_init = @import("mp4/mp4_init.zig");

comptime {
    _ = &mp4_init.mp4_container_tag;
}

/// A module is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a container module, not a command\n", .{mp4_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [mp4_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = mp4_init.LIBRARY_VERSION_STRING.*;
