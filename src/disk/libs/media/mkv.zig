// SPDX-License-Identifier: MIT
//! mkv.container: a container module in LIBS:codecs/ - Matroska and WebM files, their clusters walked, opened by
//! media.library for a file.
//!
//! The ROM tag is mkv/mkv_init.zig, the kind's code mkv/_mkv.zig, the base,
//! init, Expunge and jump table every module shares mcontainer_module.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const mkv_init = @import("mkv/mkv_init.zig");

comptime {
    _ = &mkv_init.mkv_container_tag;
}

/// A module is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a container module, not a command\n", .{mkv_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [mkv_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = mkv_init.LIBRARY_VERSION_STRING.*;
