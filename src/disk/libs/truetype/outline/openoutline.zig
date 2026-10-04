// SPDX-License-Identifier: MIT
//! OpenOutline: a TrueType file, opened for rendering.

const sdk = @import("sdk");
const exec = sdk.exec;
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("_outline.zig");

/// A TrueType file, opened for rendering.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenOutline(tb: *TrueTypeBase, file: [*]const u8, size: u32) ?*truetype.Outline
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `file` - the whole file, as read.
/// - `size` - its size in bytes.
///
/// RESULT:
/// The outline, or null if the bytes are not a TrueType font this library
/// reads - a table it needs missing or outside the file, no Unicode
/// character map of format 4 or 12 - or there is no memory.
///
/// BEHAVIOR:
/// The tables are found and checked once, and what rendering needs of
/// them kept: the units per em, the ascender and descender, where the
/// glyph index, the glyphs, the widths and the character map are. The
/// glyphs themselves are read only when a size is rendered.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The outline is the caller's until `CloseOutline`. The file's bytes stay
/// the caller's too, and must be there until then: the outline reads them
/// in place.
///
/// BUGS:
/// Hinting instructions are passed over, and fonts of CFF outlines
/// (OpenType 'OTTO') are not read.
///
/// SEE ALSO:
/// `RenderFontImage`, `CloseOutline`
///
/// EXAMPLES:
/// ```zig
/// const outline = tb.OpenOutline(file, size) orelse return error.NotTrueType;
/// defer tb.CloseOutline(outline);
/// ```
pub fn OpenOutline(tb: *TrueTypeBase, file: [*]const u8, size: u32) ?*truetype.Outline {
    const memory = tb.sys_base.AllocVec(@sizeOf(_outline.Font), exec.MEMF_ANY) orelse return null;
    const font: *_outline.Font = @ptrCast(@alignCast(memory));
    if (!_outline.open(font, file, size)) {
        tb.sys_base.FreeVec(memory);
        return null;
    }
    return @ptrCast(font);
}
