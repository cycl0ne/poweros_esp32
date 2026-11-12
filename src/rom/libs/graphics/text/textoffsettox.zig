// SPDX-License-Identifier: MPL-2.0
//! TextOffsetToX: where in a drawn text a byte's place is.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const _text = @import("_text.zig");
const shaped = @import("_shaped.zig");
const RastPort = rastport.RastPort;
const utf8 = sdk.utility.utf8;

/// Where in a drawn text the place before one of its bytes is.
///
/// SYNOPSIS:
/// ```zig
/// fn TextOffsetToX(gb: *GraphicsBase, rp: *RastPort, string: [*]const u8,
///     count: u32, offset: u32) i32
/// ```
///
/// SINCE: 0.42. LVO -352.
///
/// INPUTS:
/// - `rp` - the RastPort. Its font and text style decide the answer.
/// - `string` - the whole text as `Text` is given it, UTF-8.
/// - `count` - its length in bytes.
/// - `offset` - the byte the place is before: where a character starts.
///   At `count` or past it, the place after the text.
///
/// RESULT:
/// How many pixels right of the text's starting point the place is: 0
/// before the first character, what `TextLength` answers after the last.
/// With no font set the answer is 0 and the error is `GERR_NO_FONT`.
///
/// BEHAVIOR:
/// The text is laid out as `Text` draws it, the whole of it, and the
/// place is taken from that: a kerned pair, a ligature and a letter with
/// its marks are where they are drawn, which the lengths of the text's
/// pieces added up are not.
///
/// A place is between two clusters, as `Text` takes a text by them: a
/// letter with its marks, consonants a virama joins and their vowel
/// sign, pictographs a joiner makes one. An offset inside a cluster -
/// before a mark, before the second consonant of a conjunct - is the
/// place after the cluster. Clusters drawn as one glyph, or as several
/// that do not stand for one each - a ligature - have the width split
/// evenly among them, so there is a place before each.
///
/// In a font that does not shape its text every character is a cluster
/// of its own and the place is the advances before it added up.
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
/// - A cursor, a selection's edges and an underline under part of a text
///   are placed with this, and the text is drawn in one `Text` call. A
///   piece drawn by itself at the place answered here is shaped by
///   itself: its first letter is not kerned against the one before.
/// - The place is counted from the starting point, the direction
///   `RPTAG_TextDirection` names notwithstanding.
/// - Without memory for the glyphs the answer is the one of a font that
///   does not shape.
///
/// BUGS:
/// The places inside a ligature are an even split of its width, not the
/// ones its font may name.
///
/// SEE ALSO:
/// `TextXToOffset`, `TextLength`, `Text`
///
/// EXAMPLES:
/// ```zig
/// // A cursor before byte `cursor` of a line drawn at (left, baseline).
/// const x = left + gb.TextOffsetToX(rp, line.ptr, line.len, cursor);
/// gb.RectFill(rp, &.{ .min_x = x, .min_y = top, .max_x = x + 1, .max_y = bottom });
/// ```
pub fn TextOffsetToX(gb: *GraphicsBase, rp: *RastPort, string: [*]const u8, count: u32, offset: u32) i32 {
    rp.last_error = graphics.GERR_OK;
    const font = rp.font orelse {
        rp.last_error = graphics.GERR_NO_FONT;
        return 0;
    };
    const bytes = string[0..count];
    if (shaped.wanted(font)) {
        if (shaped.layOut(gb, font, string, count)) |line| {
            defer shaped.free(gb, line);
            return shaped.xOf(font, rp.text_style, line.placed, bytes, offset);
        }
    }
    // Each character by itself: the advances of the ones that start
    // before the byte.
    var look = _text.lookOf(font, font, rp.text_style);
    var pen: i32 = 0;
    var at: usize = 0;
    while (at < bytes.len and at < offset) {
        const found = _text.glyphOf(gb, font, utf8.next(bytes, &at));
        if (found.font != look.font) look = _text.lookOf(font, found.font, rp.text_style);
        pen += found.glyph.advance + look.extra;
    }
    return pen;
}
