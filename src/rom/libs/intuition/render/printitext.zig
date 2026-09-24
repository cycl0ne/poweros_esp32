// SPDX-License-Identifier: MPL-2.0
//! PrintIText: draws a run of text and every run linked after it, each in
//! its own pens, draw mode and font, and gives the RastPort back with its
//! own.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const TagItem = utility.TagItem;
const IntuiText = sdk.intuition.IntuiText;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const printRuns = @import("_render.zig").printRuns;

/// Draws a run of text and the runs linked after it.
///
/// SYNOPSIS:
/// ```zig
/// fn PrintIText(ib: *IntuitionBase, rp: *graphics.RastPort,
///     itext: ?*const IntuiText, left: i32, top: i32) void
/// ```
///
/// SINCE: 0.9. LVO -208.
///
/// INPUTS:
/// - `rp` - where to draw.
/// - `itext` - the first run, or null, which draws nothing.
/// - `left`, `top` - added to each run's own `left` and `top`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Each run in turn: its front and back pen and its draw mode are set,
/// and its font when it names one - a run without one is drawn in the
/// RastPort's own. The text's top is at (`left + run.left`,
/// `top + run.top`), so a run's place is its top left corner, whatever its
/// font's baseline. A run with no text, or an empty one, is passed over.
///
/// CONTEXT:
/// - Waits: no, beyond what the RastPort's layer asks of a caller - hold
///   it, as for any drawing in a window.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands. The RastPort gets its pens, draw mode and font
/// back as they were; its current point is left at the end of the last
/// run drawn, as `Text` leaves it.
///
/// NOTES:
/// - itexticlass draws its `IA_Data` with the same loop, in the image's
///   one pen instead of each run's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `IntuiTextLength`, `DrawBorder`, `DrawImage`, graphics' `Text`
///
/// EXAMPLES:
/// ```zig
/// var label = intuition.IntuiText{
///     .front_pen = graphics.penRGB(0, 0, 0),
///     .text = "Name:",
/// };
/// ib.PrintIText(rp, &label, 10, 20);
/// ```
pub fn PrintIText(ib: *IntuitionBase, rp: *graphics.RastPort, itext: ?*const IntuiText, left: i32, top: i32) void {
    printRuns(ib, rp, itext, left, top, null);
}
