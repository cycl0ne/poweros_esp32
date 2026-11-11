// SPDX-License-Identifier: MPL-2.0
//! TextLength: how wide some text would be, without drawing it.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const rastport = @import("../rastport/_rastport.zig");
const _text = @import("_text.zig");
const RastPort = rastport.RastPort;
const softStyles = _text.softStyles;

/// How wide some text would be, without drawing it.
///
/// SYNOPSIS:
/// ```zig
/// fn TextLength(_: *GraphicsBase, rp: *RastPort, string: [*]const u8, count: u32) i32
/// ```
///
/// SINCE: 0.11, UTF-8 since 0.38, fallback fonts since 0.40, glyphs made
/// when wanted since 0.41. LVO -136.
///
/// INPUTS:
/// - `rp` - the RastPort. Its font and text style decide the answer.
/// - `string` - the text, UTF-8, as `Text` takes it.
/// - `count` - its length in bytes.
///
/// RESULT:
/// The pixels `Text` would move the point along. The style counts: bold
/// and extended each widen a character. With no font set the answer is 0
/// and the error is `GERR_NO_FONT`.
///
/// BEHAVIOR:
/// The characters' advances added up, each as its glyph gives it, so a
/// proportional font measures as it draws. A character the font has no
/// glyph for counts as the glyph it is drawn as: a fallback font's, with
/// that font's advance and the line's styles, its base letter's or the
/// default character's. Ink a kern
/// or a lean puts outside that is not counted: `TextExtent` says where
/// the ink goes.
///
/// A glyph the font's hook makes (`TextFont.render`) is made here, the
/// first time a character is measured, as `Text` makes it when it is
/// the first to want it: the text is measured as it will be drawn.
///
/// CONTEXT:
/// - Waits: only for a font that makes glyphs, while another task makes
///   one of the same font.
/// - Interrupts: no. It reads the caller's RastPort, which an interrupt does
///   not share.
/// - Locks: none needed; no spinlock may be held with a font that makes
///   glyphs.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing the caller has to free. A glyph made for the measuring is
/// the library's, kept with the font.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `TextExtent`, `TextFit`, `Text`
///
/// EXAMPLES:
/// ```zig
/// const w = gb.TextLength(rp, label.ptr, label.len);
/// ```
pub fn TextLength(gb: *GraphicsBase, rp: *RastPort, string: [*]const u8, count: u32) i32 {
    rp.last_error = graphics.GERR_OK;
    const font = rp.font orelse {
        rp.last_error = graphics.GERR_NO_FONT;
        return 0;
    };
    return _text.measure(gb, font, rp.text_style, string, count).width;
}
