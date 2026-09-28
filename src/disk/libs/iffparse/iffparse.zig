// SPDX-License-Identifier: MIT
//! iffparse.library: reading and writing IFF, on the disk in LIBS:.
//!
//! An IFF file is chunks inside chunks, each named by four characters.
//! The library walks a file one chunk at a time and keeps, for each
//! chunk it is inside, the things a program asked it to keep: the
//! properties, the collections, the handlers. That stack of contexts is
//! what makes IFF's rules work - a property found inside a form is that
//! form's, and goes when the walk leaves it.
//!
//! The areas: `handle/` makes a handle and says where its bytes come
//! from, `parse/` walks and pushes and pops chunks, `chunk/` reads and
//! writes what is in them, `handler/` is what the walk runs on the way
//! in and out, `context/` and `item/` are what is kept with each chunk,
//! `clip/` opens the clipboard as a stream and `id/` is the four
//! characters themselves.
//!
//! The jump table is iffparse_lvo.zig, the ROM tag, init, open and
//! expunge iffparse_init.zig, the base and the private shapes
//! iffparse_base.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const iffparse_init = @import("iffparse_init.zig");

comptime {
    _ = &iffparse_init.iffparse_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const iffparse_library_tag = iffparse_init.iffparse_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{iffparse_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [iffparse_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = iffparse_init.LIBRARY_VERSION_STRING.*;
