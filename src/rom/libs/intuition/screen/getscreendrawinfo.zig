// SPDX-License-Identifier: MPL-2.0
//! GetScreenDrawInfo: the pens and font a screen's parts are drawn in.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const sc = intuition.screens;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;

/// The pens and font a screen's parts are drawn in.
///
/// SYNOPSIS:
/// ```zig
/// fn GetScreenDrawInfo(_: *IntuitionBase, screen: *Screen) *sc.DrawInfo
/// ```
///
/// SINCE: 0.4. LVO -116.
///
/// INPUTS:
/// - `screen` - the screen.
///
/// RESULT:
/// The screen's DrawInfo: `pens` indexed by `DETAILPEN`...`BARTRIMPEN`,
/// each an ARGB pen; `font`; `depth` in bits per pixel.
///
/// BEHAVIOR:
/// The screen's own, not a copy: every caller sees the same pens.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no. - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Read only, the screen's, and good until it closes. Hand it back with
/// `FreeScreenDrawInfo` when done.
///
/// NOTES:
/// - Check `version` against `DRI_VERSION` before reading a field added
///   after the first.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeScreenDrawInfo`, `DrawImageState`
///
/// EXAMPLES:
/// ```zig
/// const dri = ib.GetScreenDrawInfo(screen);
/// defer ib.FreeScreenDrawInfo(screen, dri);
/// const text = dri.pens[TEXTPEN];
/// ```
pub fn GetScreenDrawInfo(_: *IntuitionBase, screen: *Screen) *sc.DrawInfo {
    return &(screen).draw_info;
}
