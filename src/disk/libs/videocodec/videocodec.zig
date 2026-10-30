// SPDX-License-Identifier: MIT
//! videocodec.library: films played - their pictures handed out as frames
//! in the order they are shown, their sound as 16-bit samples; on the
//! disk in LIBS:.
//!
//! A stream opens its film with media.library, which reads the container
//! and hands out each track's packets, and takes the first track of
//! pictures and the first of sound. The pictures go to a decoder by their
//! codec: H.264 and H.265 to the chip's, videodec.resource (`chip/`: the
//! container's packets turned into the Annex B form the chip is fed, the
//! parameter sets in front of each key picture), Motion JPEG to the
//! library's own (`mjpeg/`: jpeg.datatype's decoder, built in, unpacking
//! each picture into its planes). The sound is an audiocodec.library
//! stream on the same file (`ACA_Media`), so the two halves are read and
//! decoded apart - by two tasks, if the program likes; media.library takes
//! turns at the file.
//!
//! A stream is its opener's: everything about it is in the stream, which
//! opens media.library, audiocodec.library and the resource for itself;
//! the base, shared by every opener, holds only dos.library and
//! utility.library.
//!
//! The jump table is videocodec_lvo.zig, the ROM tag, init and expunge
//! videocodec_init.zig, the base videocodec_base.zig. Each call is a file
//! under its area: `stream/` (opening, the frames, the sound, seeking,
//! the tags, closing), `identify/`, `text/`.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const videocodec_init = @import("videocodec_init.zig");

comptime {
    _ = &videocodec_init.videocodec_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const videocodec_library_tag = videocodec_init.videocodec_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{videocodec_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [videocodec_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = videocodec_init.LIBRARY_VERSION_STRING.*;
