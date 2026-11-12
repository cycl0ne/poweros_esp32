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
//! Since 1.2 the glyphs are given as outlines too (`glyph/`): a
//! character's glyph, its contours as the segments vector.library takes,
//! its measures and the font's, and the `kern` table's pairs - for a
//! program that draws text at any size and angle itself.
//!
//! Since 1.6 a font's glyphs may be a `CFF ` table's, of lines and cubic
//! curves (`outline/_cff.zig`): each glyph a program that draws it, run
//! when the glyph is asked for, into the same contours the rest reads.
//!
//! Since 1.7 a font without outlines is rendered from its pictures: the
//! strikes are found and a glyph's picture located and measured in
//! `outline/_strike.zig`, and the picture read - packed rows, parts that
//! are other glyphs, or a PNG file unpacked through compression.library -
//! and scaled to the line in `render/_picture.zig`, into coverage or
//! into 32-bit colour.
//!
//! Since 1.8 a variable font is opened at a place on its axes
//! (`outline/_variation.zig`): the place becomes a coordinate an axis,
//! and the tables of deltas are read at those whenever a glyph, an
//! advance or a measure is asked for. Since 1.9 that holds for a font
//! of cubic curves too, whose `CFF2` table has the deltas in the
//! glyphs' programs.
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
