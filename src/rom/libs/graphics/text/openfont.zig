// SPDX-License-Identifier: MPL-2.0
//! OpenFont: a font by name and height.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _text = @import("_text.zig");
const TextFont = _text.TextFont;

/// A font by name and height.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenFont(gb: *GraphicsBase, name: [*:0]const u8, height: u32) ?*TextFont
/// ```
///
/// SINCE: 0.11. LVO -124.
///
/// INPUTS:
/// - `name` - the font's name. This ROM has `POSPAZNAME` and nothing else.
/// - `height` - how many rows tall. Pospaz is here at 8 and 16.
///
/// RESULT:
/// The font, or null if there is none of that name and height. A font is
/// not made to fit: asking for 12 finds nothing rather than a stretched 8.
///
/// BEHAVIOR:
/// Pospaz 16 has the same columns as Pospaz 8, each row drawn twice: text
/// laid out in one lines up in the other, only twice as tall.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the font list.
/// - Interrupts: no.
/// - Forbid: must not be held: it waits on the font list's semaphore.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// A font in the ROM lasts for ever and `CloseFont` only counts. Closing
/// it is still right: a font that is not in the ROM will want it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseFont`, `Text`, `RPTAG_Font`
///
/// EXAMPLES:
/// ```zig
/// const font = gb.OpenFont(sdk.graphics.POSPAZNAME, 8) orelse return;
/// defer gb.CloseFont(font);
/// const use = [_]TagItem{ .{ .tag = sdk.graphics.RPTAG_Font, .data = @intFromPtr(font) }, .{} };
/// gb.SetRPAttrs(rp, &use);
/// ```
pub fn OpenFont(gb: *GraphicsBase, name: [*:0]const u8, height: u32) ?*TextFont {
    const sys = gb.sys_base;
    // The font is found and counted as open in one step, so a RemFont
    // cannot take it off between the two.
    sys.ObtainSemaphore(&gb.font_lock);
    defer sys.ReleaseSemaphore(&gb.font_lock);
    var at = gb.fonts.first();
    while (at) |node| : (at = node.succ) {
        if (node.succ == null) break;
        const font: *TextFont = @fieldParentPtr("node", node);
        if (font.height != height) continue;
        if (gb.utility_base.Strcmp(font.name, name) != 0) continue;
        font.open_count +|= 1;
        return font;
    }
    return null;
}
