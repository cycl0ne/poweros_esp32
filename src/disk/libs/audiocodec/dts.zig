// SPDX-License-Identifier: MIT
//! dts.acodec: a sound module in LIBS:codecs/ - the core of DTS, and of
//! DTS-HD's tracks, opened by audiocodec.library for a stream.
//!
//! The ROM tag is dts/dts_init.zig, the kind's code dts/_dts.zig, the base,
//! init, Expunge and jump table every module shares acodec_module.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const dts_init = @import("dts/dts_init.zig");

comptime {
    _ = &dts_init.dts_acodec_tag;
}

/// A module is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a sound module, not a command\n", .{dts_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [dts_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = dts_init.LIBRARY_VERSION_STRING.*;
