// SPDX-License-Identifier: MIT
//! truetype.library's types and constants.
//!
//! truetype.library reads a TrueType font file and renders any size of it
//! into a font image (`graphics.fontimage`): each glyph's outline scaled
//! to the height asked, and its coverage of every pixel measured, in four
//! bits. The image is then a font like any other - diskfont.library puts
//! it on graphics' list and frees it when nobody holds it.
//!
//! Open it with OpenLibrary(TRUETYPENAME, 1); its functions are in
//! sdk/interface/truetype.zig.

/// The name to open it by.
pub const TRUETYPENAME = "truetype.library";
/// The version a caller of this SDK asks for.
pub const TRUETYPE_VERSION = 1;

/// A font file opened for rendering: its tables found and checked. What
/// it holds is the library's; the file's bytes stay the caller's, and must
/// last until `CloseOutline`.
pub const Outline = opaque {};

/// Whether `bytes` start as a TrueType file: version 1.0 or 'true'.
///
/// INPUTS:
/// - `bytes` - the file's first four bytes at least.
pub fn isTrueType(bytes: []const u8) bool {
    if (bytes.len < 4) return false;
    const tag = @as(u32, bytes[0]) << 24 | @as(u32, bytes[1]) << 16 | @as(u32, bytes[2]) << 8 | bytes[3];
    return tag == 0x0001_0000 or tag == 0x7472_7565;
}
