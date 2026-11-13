// SPDX-License-Identifier: MIT
//! LigatureCarets: where a font says the cursor stands inside a ligature.
//!
//! A font's `GDEF` may list, for a glyph that stands for several
//! characters, the places between them (its LigCaretList): one place
//! fewer than the glyph has characters, each a distance along the line
//! from the glyph's point. A place given as a number of the font's units
//! is read, with or without a table that adjusts it for a size; one
//! given as a point of the glyph's outline is not, and such a glyph has
//! no places here.

const sdk = @import("sdk");
const truetype = sdk.truetype;
const TrueTypeShapingBase = @import("../truetypeshaping_base.zig").TrueTypeShapingBase;
const _tables = @import("_tables.zig");
const Table = _tables.Table;

/// The places inside a ligature where the cursor may stand.
///
/// SYNOPSIS:
/// ```zig
/// fn LigatureCarets(sb: *TrueTypeShapingBase, outline: *truetype.Outline, glyph: u32, carets: [*]i32, room: u32) u32
/// ```
///
/// SINCE: 1.10. LVO -28.
///
/// INPUTS:
/// - `outline` - the font, opened with truetype.library's OpenOutline.
/// - `glyph` - the glyph's number in the font.
/// - `carets` - where the places go.
/// - `room` - how many `carets` holds.
///
/// RESULT:
/// How many places the font names for the glyph; 0 for a glyph it names
/// none for, for a font without the list, and for a glyph one of whose
/// places is given as a point of its outline.
///
/// BEHAVIOR:
/// The first `room` of the places are written, in the font's order -
/// along the line - each in the font's units from the glyph's point. A
/// ligature of n characters has n - 1 of them: the first is where the
/// first character ends. A result above `room` says how many there are.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not callable.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is kept; the outline stays the caller's.
///
/// NOTES:
/// The places are those of the font's default: a variable font's are not
/// moved with its place on its axes, and no size's own adjustment is
/// added.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ShapeText`, truetype.library `FontTable`
///
/// EXAMPLES:
/// ```zig
/// var carets: [4]i32 = undefined;
/// const count = sb.LigatureCarets(outline, shaped.glyph, &carets, carets.len);
/// ```
pub fn LigatureCarets(sb: *TrueTypeShapingBase, outline: *truetype.Outline, glyph: u32, carets: [*]i32, room: u32) u32 {
    var length: u32 = 0;
    const start = sb.truetype_base.FontTable(outline, truetype.tableTag("GDEF"), &length) orelse return 0;
    const gdef: Table = .{ .bytes = start[0..length] };
    return caretsIn(gdef, glyph, carets[0..room]);
}

/// The same of a `GDEF` table.
pub fn caretsIn(gdef: Table, glyph: u32, carets: []i32) u32 {
    if (gdef.word(0) != 1) return 0;
    const list = gdef.partAt(8);
    if (list.empty()) return 0;
    const place = _tables.coverage(list.partAt(0), glyph) orelse return 0;
    if (place >= list.count(2, 4, 2)) return 0;
    const ligature = list.partAt(4 + place * 2);
    const count = ligature.count(0, 2, 2);
    for (0..count) |index| {
        const caret = ligature.partAt(2 + @as(u32, @intCast(index)) * 2);
        switch (caret.word(0)) {
            1, 3 => if (index < carets.len) {
                carets[index] = caret.signed(2);
            },
            else => return 0,
        }
    }
    return count;
}
