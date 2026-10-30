// SPDX-License-Identifier: MIT
//! media.library: container files - MP4 and QuickTime's MOV - opened,
//! their tracks listed and each track's packets handed out as they are
//! coded, for a decoder; on the disk in LIBS:.
//!
//! A program opens a file (OpenMedia) by its name, a file it has open, or
//! a function of its own that hands the bytes over; the library finds out
//! what it is by its first bytes and reads its index - an MP4's `moov`,
//! whole, into memory (`mp4/`: the boxes, the tracks and their sample
//! tables, the tags). Each track then has a cursor of its own
//! (`mp4/cursor.zig`) that walks its sample tables, and ReadMediaPacket
//! reads the packet it points at, through a buffer the track keeps, which
//! holds the rest of the packet's chunk - the packets of one track lie
//! together in chunks, so a run of small packets of sound costs one read.
//!
//! A file is its opener's: everything about it is in the file, and the
//! base, shared by every opener, holds only the libraries it works
//! through. Its tracks may be read by two tasks at once; the file's
//! semaphore lets one at a time at the source.
//!
//! The jump table is media_lvo.zig, the ROM tag, init and expunge
//! media_init.zig, the base media_base.zig. Each call is a file under its
//! area: `file/` (opening, the tracks, the packets, seeking, the tags,
//! closing), `identify/`, `text/`.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const media_init = @import("media_init.zig");

comptime {
    _ = &media_init.media_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const media_library_tag = media_init.media_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{media_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [media_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = media_init.LIBRARY_VERSION_STRING.*;
