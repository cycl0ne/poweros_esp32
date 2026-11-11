// SPDX-License-Identifier: MIT
//! OpenOutline: a font of a TrueType file, opened for rendering.

const sdk = @import("sdk");
const exec = sdk.exec;
const truetype = sdk.truetype;
const utility = sdk.utility;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("_outline.zig");

/// A font of a TrueType file, opened for rendering.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenOutline(tb: *TrueTypeBase, file: [*]const u8, size: u32, tags: ?[*]const utility.TagItem) ?*truetype.Outline
/// ```
///
/// SINCE: 1.0, the tags and collections since 1.4. LVO -20.
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
/// bytes are not a TrueType font this library reads - a table it needs
/// missing or outside the file, no character map it reads - or there is
/// no memory.
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
/// A font need not have outlines: one whose glyphs are pictures opens,
/// maps, measures and names, and every glyph of it is one of no outline.
///
/// The outline is not written after this call, and no other call keeps
/// anything in it: any number of tasks use one outline at once.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The outline is the caller's until `CloseOutline`. The file's bytes stay
/// the caller's too, and must be there, unchanged, until then: the
/// outline reads them in place. The tags are read during the call only.
///
/// BUGS:
/// Hinting instructions are passed over, and fonts of CFF outlines
/// (OpenType 'OTTO') are not read. A font whose only character map is in
/// a Macintosh encoding is not opened.
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
    return @ptrCast(font);
}
