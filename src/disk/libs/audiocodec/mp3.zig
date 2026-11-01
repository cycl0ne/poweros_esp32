// SPDX-License-Identifier: MIT
//! mp3.acodec: a sound module in LIBS:codecs/ - MP3: MPEG audio, Layer III, opened by
//! audiocodec.library for a stream.
//!
//! The ROM tag is mp3/mp3_init.zig, the kind's code mp3/_mp3.zig, the base,
//! init, Expunge and jump table every module shares acodec_module.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const mp3_init = @import("mp3/mp3_init.zig");

comptime {
    _ = &mp3_init.mp3_acodec_tag;
}

/// A module is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a sound module, not a command\n", .{mp3_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [mp3_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = mp3_init.LIBRARY_VERSION_STRING.*;
