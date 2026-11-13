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
/// since 1.6, fonts of pictures since 1.7, variable fonts since 1.8,
/// those of cubic curves since 1.9, `TTA_Plain` since 1.10. LVO -20.
///
/// INPUTS:
/// - `file` - the whole file, as read.
/// - `size` - its size in bytes.
/// - `tags` - which font of the file is meant and at which place on
///   its axes, or null for its first at its default:
///   - `TTA_FontIndex` (u32) - the font's number in a collection, from 0;
///     `truetype.fontCount` says how many the file holds. Default 0.
///   - `TTA_Axes` ([*]const truetype.AxisValue) - where on a variable
///     font's axes: an axis by its tag and a value in the axis' own
///     units, as `FontAxes` gives its range. Default: every axis at
///     its default.
///   - `TTA_AxisCount` (u32) - how many values `TTA_Axes` points at.
///     Default 0.
///   - `TTA_Plain` (bool) - render the outline as it is drawn, no
///     height fitted to the rows. Default false.
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
/// `loca`), or of lines and cubic curves (`CFF `, or a variable font's
/// `CFF2`, in a file that starts 'OTTO'), a font keyed by character
/// collection among those. A font with both is read by `glyf`, and one
/// with both tables of cubic curves by `CFF `. Of such a table the
/// lists, the dictionaries and where they put the glyphs' programs, the
/// subroutines, each glyph's font dictionary and a `CFF2` table's store
/// of deltas are checked here, and a table that is not sound opens no
/// font; a glyph's program is run when the glyph is asked for.
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
/// A variable font (`fvar`) is opened at one place on its axes, its
/// instance, and reads as a font of that face. An axis `TTA_Axes` does
/// not name is at its default, a value outside an axis' range is cut to
/// it, a tag the font has no axis of is passed over, and of two values
/// for one axis the first counts. Each value becomes a coordinate - its
/// distance from the default as a part of the range on that side, bent
/// by the font's `avar` table, in 14 bits of fraction - and at those
/// coordinates the font is read from then on: a `glyf` glyph's points
/// with their deltas (`gvar`), a `CFF2` glyph's program with the deltas
/// that follow its numbers (each number and, for every region of the
/// table's store, its delta as far as the region counts at the
/// coordinates), the advances with theirs (`HVAR`, or `gvar`'s side
/// points in a font without it; a `CFF2` font without `HVAR` has the
/// same advances at every instance), and the x height, the cap height,
/// the underline and the strikeout with theirs (`MVAR`).
/// The ascender, the descender and the line gap are the same at every
/// instance. A font opened at its default, and one without axes, reads
/// none of these tables. A table of deltas that is not for the font's
/// number of axes is passed over, and the font read as at its default
/// in what that table holds. A font of more than 32 axes is opened at
/// its default whatever the tags say.
///
/// Three heights are kept for rendering, which fits them to the rows of
/// a size (`RenderFontImage`): the baseline, the x height and the cap
/// height. A font that does not say one of the two heights - an `OS/2`
/// table before version 2, or none - has the top of its `x` or of its
/// `H` taken for it, and a font without that letter has no such height
/// fitted. A variable font of quadratic curves opened away from its
/// default takes no letter's top: only what the font says is fitted.
/// `FontMetrics` answers what the font says, whatever is fitted. With
/// `TTA_Plain` nothing is fitted, and what is rendered is the outline
/// scaled and no more.
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
/// hints, and a font dictionary's own font matrix in a CID-keyed font:
/// only the top dictionary's is read. A `CFF2` table's hints are passed over the same way,
/// and with them the deltas its private dictionaries have for them. Of the Macintosh platform's character maps only the
/// Roman encoding's is read, and a map of format 2 only where its
/// characters are Unicode's or that encoding's: the two-byte encodings
/// of East Asia before Unicode have no table here.
///
/// Pictures in `sbix` are not read, nor are a picture's formats 3 and
/// 4, nor the measures of a
/// line set downwards.
///
/// SEE ALSO:
/// `RenderFontImage`, `GlyphIndex`, `FontName`, `FontTable`, `FontAxes`,
/// `FontInstance`, `CloseOutline`
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
///
/// // A variable font at a weight of 650.
/// const place = [_]sdk.truetype.AxisValue{.{ .tag = sdk.truetype.tableTag("wght"), .value = 650 }};
/// const at = [_]utility.TagItem{
///     .{ .tag = sdk.truetype.TTA_Axes, .data = @intFromPtr(&place) },
///     .{ .tag = sdk.truetype.TTA_AxisCount, .data = place.len },
///     .{ .tag = utility.TAG_DONE, .data = 0 },
/// };
/// const heavy = tb.OpenOutline(file, size, &at) orelse return error.NotTrueType;
/// defer tb.CloseOutline(heavy);
/// ```
pub fn OpenOutline(tb: *TrueTypeBase, file: [*]const u8, size: u32, tags: ?[*]const utility.TagItem) ?*truetype.Outline {
    const asked = tb.utility_base.GetTagData(truetype.TTA_FontIndex, 0, tags);
    // A number no collection holds, whatever the tag's width.
    const index: u32 = if (asked > 0xFFFF_FFFF) 0xFFFF_FFFF else @intCast(asked);
    const memory = tb.sys_base.AllocVec(@sizeOf(_outline.Font), exec.MEMF_ANY) orelse return null;
    const font: *_outline.Font = @ptrCast(@alignCast(memory));
    // Where on its axes: the values are read here and not kept. With
    // none stated the address is not looked at, whatever it is.
    const stated = tb.utility_base.GetTagData(truetype.TTA_AxisCount, 0, tags);
    const axes: ?[*]const truetype.AxisValue = if (stated == 0) null else @ptrFromInt(tb.utility_base.GetTagData(truetype.TTA_Axes, 0, tags));
    const axis_count: u32 = if (axes == null) 0 else if (stated > 0xFFFF) 0xFFFF else @intCast(stated);
    if (!_outline.open(font, file, size, index, axes, axis_count)) {
        tb.sys_base.FreeVec(memory);
        return null;
    }
    font.plain = tb.utility_base.GetTagData(truetype.TTA_Plain, 0, tags) != 0;
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
