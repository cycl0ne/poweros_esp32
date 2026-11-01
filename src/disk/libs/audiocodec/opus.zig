// SPDX-License-Identifier: MIT
//! opus.acodec: a sound module in LIBS:codecs/ - Opus in Ogg, opened by
//! audiocodec.library for a stream.
//!
//! The ROM tag is opus/opus_init.zig, the kind's code opus/_opus.zig, the base,
//! init, Expunge and jump table every module shares acodec_module.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const opus_init = @import("opus/opus_init.zig");

comptime {
    _ = &opus_init.opus_acodec_tag;
}

/// A module is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a sound module, not a command\n", .{opus_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [opus_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = opus_init.LIBRARY_VERSION_STRING.*;
