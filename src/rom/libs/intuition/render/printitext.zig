// SPDX-License-Identifier: MPL-2.0
//! PrintIText: draws an IntuiText - a run of text as `IT_` tags - and
//! every run linked after it, each in what it names and the RastPort's
//! own for the rest, and gives the RastPort back as it was.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const printRuns = @import("_render.zig").printRuns;

/// Draws an IntuiText and the runs linked after it.
///
/// SYNOPSIS:
/// ```zig
/// fn PrintIText(ib: *IntuitionBase, rp: *graphics.RastPort,
///     itext: ?[*]const TagItem, left: i32, top: i32) void
/// ```
///
/// SINCE: 0.9. LVO -208.
///
/// INPUTS:
/// - `rp` - where to draw.
/// - `itext` - the first run, a tag list: `IT_Text`, the words;
///   `IT_FrontPen`, `IT_BackPen` and `IT_DrawMode`, how they are drawn;
///   `IT_Left` and `IT_Top`, where; `IT_Font` and `IT_Style`, in what;
///   `IT_Next`, the next run. Null draws nothing.
/// - `left`, `top` - added to each run's own `IT_Left` and `IT_Top`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Each run in turn starts from the RastPort as it was given and takes
/// what it names: its pens, its draw mode, its font, its style. What it
/// does not name is the RastPort's own, so a run without `IT_FrontPen` is
/// drawn in the caller's pen and one without `IT_Font` in the RastPort's
/// font; nothing one run names carries over to the next. The text's top
/// is at (`left` + `IT_Left`, `top` + `IT_Top`), so a run's place is its
/// top left corner, whatever its font's baseline. A run with no text, or
/// an empty one, is passed over and the runs after it are drawn.
///
/// CONTEXT:
/// - Waits: no, beyond what the RastPort's layer asks of a caller - hold
///   it, as for any drawing in a window.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing changes hands. The RastPort gets its pens, draw mode, font and
/// style back as they were; its current point is left at the end of the
/// last run drawn, as `Text` leaves it.
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
/// const label = [_]TagItem{
///     .{ .tag = intuition.IT_Text, .data = @intFromPtr("Name:") },
///     .{ .tag = intuition.IT_FrontPen, .data = graphics.penRGB(0, 0, 0) },
///     .{ .tag = intuition.IT_Style, .data = graphics.FSF_BOLD },
///     .{},
/// };
/// ib.PrintIText(rp, &label, 10, 20);
/// ```
pub fn PrintIText(ib: *IntuitionBase, rp: *graphics.RastPort, itext: ?[*]const TagItem, left: i32, top: i32) void {
    printRuns(ib, rp, itext, left, top, null);
}
