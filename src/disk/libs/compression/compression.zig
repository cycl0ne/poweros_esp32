// SPDX-License-Identifier: MIT
//! compression.library: DEFLATE (RFC 1951) packing and unpacking, bare or
//! wrapped as zlib (RFC 1950) or gzip (RFC 1952), on the disk in LIBS:.
//!
//! A stream is the caller's `compression.Stream`: where the input is and
//! where the output goes, moved on by each call, with the library's state
//! for it behind a pointer the Init call fills in and the End call
//! frees. So a stream goes a buffer at a time - a file through a small
//! buffer, a download as it arrives - or in one go, and the one base is
//! shared by every opener.
//!
//! The jump table is compression_lvo.zig, the ROM tag, init and expunge
//! compression_init.zig, the base compression_base.zig. Each call is a
//! file under its area: `inflate/` (on the engine `_inflate.zig` and the
//! codes of `_table.zig`), `deflate/` (on `_deflate.zig`), and
//! `checksum/`.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const compression_init = @import("compression_init.zig");

comptime {
    _ = &compression_init.compression_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const compression_library_tag = compression_init.compression_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{compression_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [compression_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = compression_init.LIBRARY_VERSION_STRING.*;
