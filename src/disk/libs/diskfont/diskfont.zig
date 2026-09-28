// SPDX-License-Identifier: MIT
//! diskfont.library: fonts from FONTS:, at any size, on the disk in LIBS:.
//!
//! A font family on the disk is a contents file and a directory of size
//! files (`sdk.diskfont`); a size file is a font image, read with one
//! Read into one allocation with the font's record in front of it, and
//! handed to graphics.library's list. OpenDiskFont finds the nearest
//! size, loading or scaling it; AvailFonts lists what there is;
//! NewFontContents makes a contents file from a family's directory;
//! NewScaledDiskFont makes a new size from any font.
//!
//! Fonts nobody holds stay loaded until memory runs short, when the
//! library's own low-memory handler frees them one at a time.
//!
//! The jump table is diskfont_lvo.zig, the ROM tag, init and expunge
//! diskfont_init.zig, the base diskfont_base.zig. Each call is a file
//! under its area: `font/`, `contents/`.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const diskfont_init = @import("diskfont_init.zig");

comptime {
    _ = &diskfont_init.diskfont_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const diskfont_library_tag = diskfont_init.diskfont_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{diskfont_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [diskfont_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = diskfont_init.LIBRARY_VERSION_STRING.*;
