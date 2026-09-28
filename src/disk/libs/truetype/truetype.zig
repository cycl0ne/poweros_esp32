// SPDX-License-Identifier: MIT
//! truetype.library: TrueType fonts rendered into font images, on the
//! disk in LIBS:.
//!
//! A file is opened once (`outline/`): its tables are found and checked,
//! and what the rendering needs of them - the scale, the vertical
//! metrics, where the character map, the glyph index and the glyphs are -
//! kept in an outline the caller holds. A size is then rendered at a time
//! (`render/`): each glyph's contours read from the file, its curves
//! flattened into lines, and the lines' coverage of every pixel summed,
//! kept in four bits. No hinting: at the panels' 165 DPI and more the
//! coverage alone draws a clean letter.
//!
//! The jump table is truetype_lvo.zig, the ROM tag, init and expunge
//! truetype_init.zig, the base truetype_base.zig.

const sdk = @import("sdk");
const ExecBase = sdk.interface.exec.ExecBase;
const truetype_init = @import("truetype_init.zig");

comptime {
    _ = &truetype_init.truetype_library_tag;
}

/// The ROM tag, for the host tests that make the library from it.
pub const truetype_library_tag = truetype_init.truetype_library_tag;

/// A library is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a library, not a command\n", .{truetype_init.LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [truetype_init.LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = truetype_init.LIBRARY_VERSION_STRING.*;
