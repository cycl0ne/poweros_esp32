// SPDX-License-Identifier: MPL-2.0
//! StylePens: the screen's pens, with a part's look taken from the style.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const style = sdk.intuition.style;
const sc = sdk.intuition.screens;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _style = @import("_style.zig");
const d = @import("../classes/draw.zig");

/// The screen's pens, with the ones that stand for a gadget's look taken
/// from a part of the style.
///
/// SYNOPSIS:
/// ```zig
/// fn StylePens(ib: *IntuitionBase, draw_info: ?*const DrawInfo,
///     own: ?*const Style, part: u32, pens: [*]graphics.Pen) void
/// ```
///
/// SINCE: 0.22. LVO -484.
///
/// INPUTS:
/// - `draw_info` - the screen's, for its pens and its style; null for the
///   default pens and the system's default style alone.
/// - `own` - a gadget's own style (`GA_Style`, read back), or null.
/// - `part` - a `style.PART_` number, or a class's own.
/// - `pens` - room for `NUMDRIPENS` pens, written.
///
/// RESULT:
/// Nothing; the pens are in `pens`, as 0xAARRGGBB.
///
/// BEHAVIOR:
/// Every pen is the screen's, except six:
///
/// | pen | from the part |
/// |---|---|
/// | `BACKGROUNDPEN` | its background, at rest |
/// | `TEXTPEN` | its text, at rest |
/// | `FILLPEN` | its background, pressed |
/// | `FILLTEXTPEN` | its text, pressed |
/// | `SHINEPEN` | its bevel's light side |
/// | `SHADOWPEN` | its bevel's dark side |
///
/// Each is found as `DrawPart` finds a property. With the system's default
/// style and `style.PART_MAIN`, all six are the screen's own pens again,
/// so a class that draws with these instead of the screen's draws exactly
/// as it did - and follows whatever style its screen or the gadget has.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not wanted.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `pens` is the caller's; nothing is kept.
///
/// NOTES:
/// A class that also shows a selection or a level takes `FILLPEN` and
/// `FILLTEXTPEN` from `style.PART_SELECTION` or `style.PART_INDICATOR`
/// with `GetStyleAttr` afterwards.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetStyleAttr`, `DrawPart`
///
/// EXAMPLES:
/// ```zig
/// var pens: [sc.NUMDRIPENS]graphics.Pen = undefined;
/// ib.StylePens(info.draw_info, gadget.style, style.PART_MAIN, &pens);
/// // ... draw as before, with `pens` for `info.draw_info.pens`.
/// ```
pub fn StylePens(ib: *IntuitionBase, draw_info: ?*const sc.DrawInfo, own: ?*const style.Style, part: u32, pens: [*]graphics.Pen) void {
    const base = d.pensOf(draw_info);
    const num_pens: u32 = if (draw_info) |dri| dri.num_pens else sc.NUMDRIPENS;
    for (0..sc.NUMDRIPENS) |i| pens[i] = base[i];
    const rest = _style.look(ib, own, draw_info, part, style.STATE_NORMAL);
    const pressed = _style.look(ib, own, draw_info, part, style.STATE_PRESSED);
    pens[sc.BACKGROUNDPEN] = if (rest.backgroundFill()) |f| f.stops[0].pen else rest.colour(.background, base, num_pens);
    pens[sc.TEXTPEN] = rest.colour(.text, base, num_pens);
    pens[sc.FILLPEN] = if (pressed.backgroundFill()) |f| f.stops[0].pen else pressed.colour(.background, base, num_pens);
    pens[sc.FILLTEXTPEN] = pressed.colour(.text, base, num_pens);
    pens[sc.SHINEPEN] = rest.colour(.shine, base, num_pens);
    pens[sc.SHADOWPEN] = rest.colour(.shadow, base, num_pens);
}
