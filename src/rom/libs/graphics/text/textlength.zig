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
const advance = _text.advance;

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
/// Every character of these fonts is the same width, so this is a
/// multiplication. It is a call rather than a sum the caller does because
/// a font that is not fixed-width will want it to be, and callers should
/// not have to change when one arrives.
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
    _ = string;
    rp.last_error = graphics.GERR_OK;
    const font = rp.font orelse {
        rp.last_error = graphics.GERR_NO_FONT;
        return 0;
    };
    return advance(font, rp.text_style) * @as(i32, @intCast(count));
}
