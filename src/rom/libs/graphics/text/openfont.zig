// SPDX-License-Identifier: MPL-2.0
//! OpenFont: the nearest font of a name to what is asked for.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _text = @import("_text.zig");
const TextFont = _text.TextFont;

/// The nearest font of a name to what is asked for.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenFont(gb: *GraphicsBase, text_attr: *const graphics.TextAttr) ?*TextFont
/// ```
///
/// SINCE: 0.11. LVO -124.
///
/// INPUTS:
/// - `text_attr` - the name, the height - in rows, or in points with
///   `FPF_POINTS` - the styles and the flags asked for. This ROM has
///   `POSPAZNAME` at 8 and 16 rows.
///
/// RESULT:
/// The font, opened, or null if no font on the list has the name, the
/// height asked for is 0, or every font of the name weighs 0 against the
/// request (`FPF_DESIGNED` asked for and all of them scaled).
///
/// BEHAVIOR:
/// Every font of the name is weighed with `WeighTAMatch`, and the
/// heaviest is opened; a perfect match ends the search. So a height that
/// is not there gets the nearest that is - a smaller one before a larger
/// one the same distance off, since text short of its box reads better
/// than text spilling out of it - and a style asked for is found drawn if
/// a font of that style exists, or left for the soft styles to make.
///
/// A font is not made here: asking for 12 rows of pospaz answers pospaz
/// 8. diskfont.library, asked the same, can load or scale one.
///
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
/// The font is open until `CloseFont`. A font in the ROM lasts for ever
/// and `CloseFont` only counts; closing it is still right, since the font
/// found may be one that is not in the ROM.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseFont`, `WeighTAMatch`, `AskFont`, `Text`, `RPTAG_Font`
///
/// EXAMPLES:
/// ```zig
/// const want = sdk.graphics.TextAttr{ .name = sdk.graphics.POSPAZNAME, .y_size = 8 };
/// const font = gb.OpenFont(&want) orelse return;
/// defer gb.CloseFont(font);
/// const use = [_]TagItem{ .{ .tag = sdk.graphics.RPTAG_Font, .data = @intFromPtr(font) }, .{} };
/// gb.SetRPAttrs(rp, &use);
/// ```
pub fn OpenFont(gb: *GraphicsBase, text_attr: *const graphics.TextAttr) ?*TextFont {
    const sys = gb.sys_base;
    const graphics_lib = gb.iface();
    // The font is found and counted as open in one step, so a RemFont
    // cannot take it off between the two.
    sys.ObtainSemaphore(&gb.font_lock);
    defer sys.ReleaseSemaphore(&gb.font_lock);
    const want = _text.inRows(gb, text_attr);
    var best: ?*TextFont = null;
    var best_weight: i32 = 0;
    var at = gb.fonts.first();
    while (at) |node| : (at = node.succ) {
        if (node.succ == null) break;
        const font: *TextFont = @fieldParentPtr("node", node);
        const name = node.name orelse continue;
        if (gb.utility_base.Strcmp(name, want.name) != 0) continue;
        const target = _text.attrOf(font);
        const weight = graphics_lib.WeighTAMatch(&want, &target, null);
        if (weight <= best_weight) continue;
        best = font;
        best_weight = weight;
        if (weight == graphics.MAXFONTMATCHWEIGHT) break;
    }
    const found = best orelse return null;
    found.open_count +|= 1;
    return found;
}
