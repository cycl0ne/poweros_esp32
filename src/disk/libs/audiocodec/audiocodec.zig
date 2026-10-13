// SPDX-License-Identifier: MIT
//! audiocodec.library: sound decoded from what it is coded in into 16-bit
//! samples, on the disk in LIBS:.
//!
//! A program opens a stream (OpenAudioStream) on a file, a file it has
//! open, or a function of its own that hands the bytes over; the library
//! finds out what the sound is by its first bytes, reads ahead of the
//! decoder in its own buffer, and hands the samples out as the program
//! asks for them (DecodeAudio) - a piece at a time, so a song is never
//! decoded whole. The kinds are WAV (`wav/`) and MP3 (`mp3/`: the Layer III
//! decoder, `layer3.zig`, and the stream around it, `_mp3.zig`).
//!
//! A stream is its opener's: everything about it is in the stream, and the
//! base, shared by every opener, holds only the libraries it works through.
//!
//! The jump table is audiocodec_lvo.zig, the ROM tag, init and expunge
//! audiocodec_init.zig, the base audiocodec_base.zig. Each call is a file
//! under its area: `stream/` (opening, decoding, seeking, closing),
//! `identify/`, `text/`.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const audiocodec_init = @import("audiocodec_init.zig");

comptime {
    _ = &audiocodec_init.audiocodec_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const audiocodec_library_tag = audiocodec_init.audiocodec_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{audiocodec_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [audiocodec_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = audiocodec_init.LIBRARY_VERSION_STRING.*;
