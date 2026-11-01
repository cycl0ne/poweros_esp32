// SPDX-License-Identifier: MIT
//! wav.acodec: a sound module in LIBS:codecs/ - WAV: PCM of 8 to 32 bits, A-law, mu-law and float, opened by
//! audiocodec.library for a stream.
//!
//! The ROM tag is wav/wav_init.zig, the kind's code wav/_wav.zig, the base,
//! init, Expunge and jump table every module shares acodec_module.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const wav_init = @import("wav/wav_init.zig");

comptime {
    _ = &wav_init.wav_acodec_tag;
}

/// A module is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a sound module, not a command\n", .{wav_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [wav_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = wav_init.LIBRARY_VERSION_STRING.*;
