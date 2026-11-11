// SPDX-License-Identifier: MPL-2.0
//! TextXToOffset: which byte of a drawn text a place is nearest to.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const _text = @import("_text.zig");
const shaped = @import("_shaped.zig");
const RastPort = rastport.RastPort;
const utf8 = sdk.utility.utf8;

/// Which byte of a drawn text the place nearest a column is before.
///
/// SYNOPSIS:
/// ```zig
/// fn TextXToOffset(gb: *GraphicsBase, rp: *RastPort, string: [*]const u8,
///     count: u32, x: i32) u32
/// ```
///
/// SINCE: 0.42. LVO -356.
///
/// INPUTS:
/// - `rp` - the RastPort. Its font and text style decide the answer.
/// - `string` - the whole text as `Text` is given it, UTF-8.
/// - `count` - its length in bytes.
/// - `x` - the column, in pixels right of the text's starting point.
///
/// RESULT:
/// The byte a character starts at, or `count` for the place after the
/// text: the one whose place, as `TextOffsetToX` gives it, is nearest
/// `x`. Left of the text the answer is 0, right of it `count`. With no
/// font set the answer is 0 and the error is `GERR_NO_FONT`.
///
/// BEHAVIOR:
/// The text is laid out as `Text` draws it, and the places between its
/// clusters - a character, and the marks and other characters without a
/// width that follow it - are the ones to choose from, with the places
/// an even split puts inside a cluster of several characters with a
/// width. A column in the left half of what is between two places
/// answers the left one, a column in the right half the right one. The
/// byte of a mark is not answered: no place is between a letter and its
/// mark.
///
/// In a font that does not shape its text every character is a cluster
/// of its own, a mark too.
///
/// CONTEXT:
/// - Waits: only for a font that makes glyphs, while another task makes
///   one of the same font.
/// - Interrupts: no. It reads the caller's RastPort, which an interrupt
///   does not share, and may allocate.
/// - Locks: none needed; no spinlock may be held with a font that makes
///   glyphs or shapes its text.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing the caller has to free. For a font that shapes its text the
/// laid-out glyphs are allocated and freed within the call.
///
/// NOTES:
/// - A click in a line of text is turned into a cursor's place with
///   this: the column is the click's, less where the text starts.
/// - Without memory for the glyphs the answer is the one of a font that
///   does not shape.
///
/// BUGS:
/// The places inside a ligature are an even split of its width, not the
/// ones its font may name.
///
/// SEE ALSO:
/// `TextOffsetToX`, `TextFit`, `Text`
///
/// EXAMPLES:
/// ```zig
/// // The cursor goes where the line drawn at `left` was clicked.
/// cursor = gb.TextXToOffset(rp, line.ptr, line.len, mouse_x - left);
/// ```
pub fn TextXToOffset(gb: *GraphicsBase, rp: *RastPort, string: [*]const u8, count: u32, x: i32) u32 {
    rp.last_error = graphics.GERR_OK;
    const font = rp.font orelse {
        rp.last_error = graphics.GERR_NO_FONT;
        return 0;
    };
    const bytes = string[0..count];
    if (shaped.wanted(font)) {
        if (shaped.layOut(gb, font, string, count)) |line| {
            defer shaped.free(gb, line);
            return shaped.offsetAt(font, rp.text_style, line.placed, bytes, x);
        }
    }
    // Each character by itself: the first whose middle is right of the
    // column.
    var look = _text.lookOf(font, font, rp.text_style);
    var pen: i32 = 0;
    var at: usize = 0;
    while (at < bytes.len) {
        const here = at;
        const found = _text.glyphOf(gb, font, utf8.next(bytes, &at));
        if (found.font != look.font) look = _text.lookOf(font, found.font, rp.text_style);
        const step = found.glyph.advance + look.extra;
        if (2 * x < 2 * pen + step) return @intCast(here);
        pen += step;
    }
    return count;
}
