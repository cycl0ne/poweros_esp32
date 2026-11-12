// SPDX-License-Identifier: MIT
//! OpenOutline: a font of a TrueType or OpenType file, opened for
//! rendering.

const sdk = @import("sdk");
const exec = sdk.exec;
const truetype = sdk.truetype;
const utility = sdk.utility;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("_outline.zig");

/// A font of a TrueType or OpenType file, opened for rendering.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenOutline(tb: *TrueTypeBase, file: [*]const u8, size: u32, tags: ?[*]const utility.TagItem) ?*truetype.Outline
/// ```
///
/// SINCE: 1.0, the tags and collections since 1.4, fonts of cubic curves
/// since 1.6, fonts of pictures since 1.7. LVO -20.
///
/// INPUTS:
/// - `file` - the whole file, as read.
/// - `size` - its size in bytes.
/// - `tags` - which font of the file is meant, or null for its first:
///   - `TTA_FontIndex` (u32) - the font's number in a collection, from 0;
///     `truetype.fontCount` says how many the file holds. Default 0.
///
/// RESULT:
/// The outline, or null if the file has no font of that number, the
/// bytes are not a font this library reads - a table it needs missing,
/// outside the file or not sound, no character map it reads - there is
/// no memory, or the font's pictures are PNG files and
/// compression.library does not open.
///
/// BEHAVIOR:
/// The font's tables are found and checked once, and what the other
/// calls need of them kept: the units per em, the ascender and
/// descender, where the glyph index, the glyphs, the widths, the
/// character map and the variation sequences are. The glyphs themselves
/// are read only when one is asked for.
///
/// Of a font's character maps a Unicode one is read, the one that
/// reaches furthest: formats 12, 13, 10, 4, 6 and 0, in that order. A
/// symbol font, which has none, is read by its own map, with its
/// characters where the font puts them (U+F020 to U+F0FF mostly).
///
/// A font's glyphs are of lines and quadratic curves (`glyf` and
/// `loca`), or of lines and cubic curves (`CFF `, in a file that starts
/// 'OTTO'), a font keyed by character collection among those. A font
/// with both is read by `glyf`. Of a `CFF ` table the lists, the
/// dictionaries and where they put the glyphs' programs, the subroutines
/// and each glyph's font dictionary are checked here, and a table that
/// is not sound opens no font; a glyph's program is run when the glyph
/// is asked for.
///
/// A font need not have outlines. One without them whose glyphs are
/// pictures is rendered from those: colour pictures, PNG files in
/// strikes of 32 bits a pixel (`CBLC` and `CBDT`, a picture's formats
/// 17, 18 and 19), or pictures of coverage in strikes of 1, 2, 4 or 8
/// bits a pixel (`EBLC` and `EBDT`, formats 1, 2, 5, 6, 7, 8 and 9). A
/// font with both pairs of tables is read by the colour one; the first
/// 64 strikes of a list are read, and a list of another version than 2
/// or 3 is none. For a font of colour pictures compression.library is
/// opened, which unpacks them, and held until `CloseOutline`. Such a
/// font maps, measures and names as any other, and every glyph of it is
/// one of no outline (`GlyphSegments`). A font with outlines is drawn
/// from them at every size, and its pictures are not read.
///
/// The outline is not written after this call, and no other call keeps
/// anything in it: any number of tasks use one outline at once.
///
/// CONTEXT:
/// - Waits: for a font of colour pictures, while compression.library is
///   loaded, if it is not in memory yet; otherwise no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do, but for a font of colour pictures while
///   compression.library is still on the disk: loading it takes a
///   Process.
///
/// OWNERSHIP:
/// The outline is the caller's until `CloseOutline`. The file's bytes stay
/// the caller's too, and must be there, unchanged, until then: the
/// outline reads them in place. The tags are read during the call only.
///
/// BUGS:
/// Hinting instructions are passed over, and so are a `CFF ` table's
/// hints and its font matrix: its glyphs are taken as drawn in the
/// font's units. A font whose outlines are a `CFF2` table's is not
/// opened. A font whose only character map is in a Macintosh encoding
/// is not opened.
///
/// Pictures in `sbix`, and in the `bloc` and `bdat` tables, are not
/// read, nor are a picture's formats 3 and 4, nor the measures of a
/// line set downwards.
///
/// SEE ALSO:
/// `RenderFontImage`, `GlyphIndex`, `FontName`, `FontTable`, `CloseOutline`
///
/// EXAMPLES:
/// ```zig
/// const outline = tb.OpenOutline(file, size, null) orelse return error.NotTrueType;
/// defer tb.CloseOutline(outline);
///
/// // Every font of a collection.
/// var index: u32 = 0;
/// while (index < sdk.truetype.fontCount(file[0..size])) : (index += 1) {
///     const tags = [_]utility.TagItem{
///         .{ .tag = sdk.truetype.TTA_FontIndex, .data = index },
///         .{ .tag = utility.TAG_DONE, .data = 0 },
///     };
///     const font = tb.OpenOutline(file, size, &tags) orelse continue;
///     defer tb.CloseOutline(font);
/// }
/// ```
pub fn OpenOutline(tb: *TrueTypeBase, file: [*]const u8, size: u32, tags: ?[*]const utility.TagItem) ?*truetype.Outline {
    const asked = tb.utility_base.GetTagData(truetype.TTA_FontIndex, 0, tags);
    // A number no collection holds, whatever the tag's width.
    const index: u32 = if (asked > 0xFFFF_FFFF) 0xFFFF_FFFF else @intCast(asked);
    const memory = tb.sys_base.AllocVec(@sizeOf(_outline.Font), exec.MEMF_ANY) orelse return null;
    const font: *_outline.Font = @ptrCast(@alignCast(memory));
    if (!_outline.open(font, file, size, index)) {
        tb.sys_base.FreeVec(memory);
        return null;
    }
    // Pictures that are PNG files are unpacked by compression.library:
    // opened here, where a file may be read, and never while a glyph is
    // rendered.
    if (font.strikes.count != 0 and font.strikes.colour) {
        const cb = tb.sys_base.OpenLibrary(sdk.compression.COMPRESSIONNAME, 1) orelse {
            tb.sys_base.FreeVec(memory);
            return null;
        };
        font.compression = @ptrCast(@alignCast(cb));
    }
    return @ptrCast(font);
}
