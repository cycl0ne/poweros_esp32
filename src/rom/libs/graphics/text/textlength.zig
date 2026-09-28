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
/// SINCE: 0.11. LVO -136.
///
/// INPUTS:
/// - `rp` - the RastPort. Its font and text style decide the answer.
/// - `string` - the characters.
/// - `count` - how many.
///
/// RESULT:
/// The pixels `Text` would move the point along. The style counts: bold
/// and extended each widen a character. With no font set the answer is 0
/// and the error is `GERR_NO_FONT`.
///
/// BEHAVIOR:
/// The characters' advances added up, each as its glyph gives it, so a
/// proportional font measures as it draws. A character the font has no
/// glyph for counts as the default character it is drawn as. Ink a kern
/// or a lean puts outside that is not counted: `TextExtent` says where
/// the ink goes.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It reads the caller's RastPort, which an interrupt does
///   not share.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
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
pub fn TextLength(_: *GraphicsBase, rp: *RastPort, string: [*]const u8, count: u32) i32 {
    rp.last_error = graphics.GERR_OK;
    const font = rp.font orelse {
        rp.last_error = graphics.GERR_NO_FONT;
        return 0;
    };
    return _text.measure(font, rp.text_style, string, count).width;
}
