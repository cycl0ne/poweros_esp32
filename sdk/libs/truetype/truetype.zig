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

const graphics = @import("../graphics/graphics.zig");

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

/// The styles a TrueType file says it is drawn in: `FSF_BOLD` and
/// `FSF_ITALIC`, from the style bits of its `head` table - a bold face of
/// a family says it is bold. None when the file has no `head` table, or
/// `bytes` end before it.
///
/// INPUTS:
/// - `bytes` - the file from its start, through its `head` table at least.
pub fn styleOf(bytes: []const u8) graphics.FontStyle {
    if (bytes.len < 12 or !isTrueType(bytes)) return graphics.FS_NORMAL;
    const tables = @as(usize, bytes[4]) << 8 | bytes[5];
    for (0..tables) |i| {
        const record = 12 + 16 * i;
        if (record + 16 > bytes.len) break;
        if (bytes[record] != 'h' or bytes[record + 1] != 'e' or bytes[record + 2] != 'a' or bytes[record + 3] != 'd') continue;
        const head = @as(usize, bytes[record + 8]) << 24 | @as(usize, bytes[record + 9]) << 16 |
            @as(usize, bytes[record + 10]) << 8 | bytes[record + 11];
        // macStyle, at 44 into the table: bit 0 bold, bit 1 italic.
        if (head + 46 > bytes.len) break;
        const bits = bytes[head + 45];
        var style: graphics.FontStyle = graphics.FS_NORMAL;
        if (bits & 1 != 0) style |= graphics.FSF_BOLD;
        if (bits & 2 != 0) style |= graphics.FSF_ITALIC;
        return style;
    }
    return graphics.FS_NORMAL;
}
