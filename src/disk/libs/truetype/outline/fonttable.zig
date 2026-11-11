// SPDX-License-Identifier: MIT
//! FontTable: one of a font's tables, as the file has it.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const _base = @import("../truetype_base.zig");
const TrueTypeBase = _base.TrueTypeBase;
const _outline = @import("_outline.zig");

/// One of a font's tables, as the file has it.
///
/// SYNOPSIS:
/// ```zig
/// fn FontTable(tb: *TrueTypeBase, outline: *truetype.Outline, tag: u32, length: *u32) ?[*]const u8
/// ```
///
/// SINCE: 1.4. LVO -60.
///
/// INPUTS:
/// - `outline` - what `OpenOutline` answered.
/// - `tag` - the table's four letters, as `truetype.tableTag` makes
///   them: `tableTag("GSUB")`.
/// - `length` - where the table's size in bytes goes.
///
/// RESULT:
/// The table's first byte, and its size in `length`. Null, and a size of
/// 0, when the font has no table of that tag or the file ends before the
/// table does.
///
/// BEHAVIOR:
/// The font's directory is searched for the tag - in a collection, the
/// directory of the font `OpenOutline` was asked for - and the table's
/// place and size are checked against the file. Nothing within the table
/// is: what it says is its reader's to check against `length`. Its
/// numbers are stored with the highest byte first.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bytes are the file's, which is the caller's: they are there as
/// long as the file is, and are not to be written.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenOutline`, `FontName`
///
/// EXAMPLES:
/// ```zig
/// var length: u32 = 0;
/// const start = tb.FontTable(outline, sdk.truetype.tableTag("GSUB"), &length) orelse return;
/// const substitutions = start[0..length];
/// ```
pub fn FontTable(tb: *TrueTypeBase, outline: *truetype.Outline, tag: u32, length: *u32) ?[*]const u8 {
    _ = tb;
    const font: *const _outline.Font = @ptrCast(@alignCast(outline));
    length.* = 0;
    const table = _outline.findTableByTag(font, tag) orelse return null;
    length.* = table.len;
    return font.data + table.at;
}
