// SPDX-License-Identifier: MIT
//! vorbis.acodec: a sound module in LIBS:codecs/ - Vorbis in Ogg, opened by
//! audiocodec.library for a stream.
//!
//! The ROM tag is vorbis/vorbis_init.zig, the kind's code vorbis/_vorbis.zig, the base,
//! init, Expunge and jump table every module shares acodec_module.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const vorbis_init = @import("vorbis/vorbis_init.zig");

comptime {
    _ = &vorbis_init.vorbis_acodec_tag;
}

/// A module is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a sound module, not a command\n", .{vorbis_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [vorbis_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = vorbis_init.LIBRARY_VERSION_STRING.*;
