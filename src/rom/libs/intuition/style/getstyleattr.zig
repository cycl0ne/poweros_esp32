// SPDX-License-Identifier: MPL-2.0
//! GetStyleAttr: one property of a part in a state.

const sdk = @import("sdk");
const utility = sdk.utility;
const style = sdk.intuition.style;
const sc = sdk.intuition.screens;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _style = @import("_style.zig");
const d = @import("../classes/draw.zig");

/// One property of a part in a state, found as `DrawPart` finds it.
///
/// SYNOPSIS:
/// ```zig
/// fn GetStyleAttr(ib: *IntuitionBase, draw_info: ?*const DrawInfo,
///     own: ?*const Style, part: u32, state: u32, attr: Tag) usize
/// ```
///
/// SINCE: 0.20. LVO -480.
///
/// INPUTS:
/// - `draw_info` - the screen's, for its pens and its style; null for the
///   default pens and the system's default style alone.
/// - `own` - a gadget's own style (`GA_Style`, read back), or null.
/// - `part` - a `style.PART_` number, or a class's own.
/// - `state` - `style.STATE_` bits, or a mixed state (`style.mixState`):
///   the look part of the way from one state to another, every colour
///   mixed channel by channel and every number rounded.
/// - `attr` - a `style.STYLE_` tag.
///
/// RESULT:
/// A colour as 0xAARRGGBB, whichever of its two tags `attr` is - a pen
/// index in the style is looked up in the screen's pens, so the answer can
/// go straight into `RPTAG_APen`. `STYLE_BackgroundFill` answers a
/// `*const graphics.FillStyle`, the style's own copy - good until that
/// style is replaced (`SetStyle`) - or 0 when the background is a colour; asked for the background colour of one that is
/// a fill style, the colour of its first stop. Any other property as its number:
/// `STYLE_BorderWidth` answers `STYLE_BorderX` and `STYLE_Padding`
/// `STYLE_PaddingX`. 0 for a tag that is not a property.
///
/// BEHAVIOR:
/// The property is found by the same order `DrawPart` uses: the most
/// particular state first, then the gadget's own style before the screen's
/// before the default, then the exact part before the one it falls back
/// to. A colour is answered as it is in the style; the part's opacity is
/// not laid on it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not wanted.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// What a class asks when it draws something of its own in the style's
/// colours - its label, a mark - rather than having `DrawPart` draw it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DrawPart`, `SA_Style`, `GA_Style`
///
/// EXAMPLES:
/// ```zig
/// // A button's label in the colour its style gives pressed text.
/// const ink = ib.GetStyleAttr(draw_info, own, style.PART_MAIN,
///     style.STATE_PRESSED, style.STYLE_TextPen);
/// gb.SetRPAttrs(rp, &.{ .{ .tag = graphics.RPTAG_APen, .data = ink }, .{} });
/// ```
pub fn GetStyleAttr(ib: *IntuitionBase, draw_info: ?*const sc.DrawInfo, own: ?*const style.Style, part: u32, state: u32, attr: utility.Tag) usize {
    const pens = d.pensOf(draw_info);
    const num_pens: u32 = if (draw_info) |dri| dri.num_pens else sc.NUMDRIPENS;
    const look = _style.lookFor(ib, own, draw_info, part, state, pens, num_pens);
    return switch (attr) {
        style.STYLE_Background, style.STYLE_BackgroundRGB => if (look.backgroundFill()) |f| f.stops[0].pen else look.colour(.background, pens, num_pens),
        style.STYLE_BackgroundFill => @intFromPtr(look.fill_source),
        style.STYLE_BorderPen, style.STYLE_BorderRGB => look.colour(.border_colour, pens, num_pens),
        style.STYLE_ShinePen, style.STYLE_ShineRGB => look.colour(.shine, pens, num_pens),
        style.STYLE_ShadowPen, style.STYLE_ShadowRGB => look.colour(.shadow, pens, num_pens),
        style.STYLE_TextPen, style.STYLE_TextRGB => look.colour(.text, pens, num_pens),
        style.STYLE_Border => look.get(.border),
        style.STYLE_BorderWidth, style.STYLE_BorderX => look.get(.border_x),
        style.STYLE_BorderY => look.get(.border_y),
        style.STYLE_Joins => look.get(.joins),
        style.STYLE_Radius => look.get(.radius),
        style.STYLE_Padding, style.STYLE_PaddingX => look.get(.padding_x),
        style.STYLE_PaddingY => look.get(.padding_y),
        style.STYLE_Opacity => look.get(.opacity),
        style.STYLE_Transition => look.get(.transition),
        else => 0,
    };
}
