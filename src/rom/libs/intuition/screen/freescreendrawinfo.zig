// SPDX-License-Identifier: MPL-2.0
//! FreeScreenDrawInfo: hands back a DrawInfo.

const sdk = @import("sdk");
const intuition = sdk.intuition;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;

/// Hands back a DrawInfo.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeScreenDrawInfo(_: *IntuitionBase, screen: *Screen,
///     draw_info: ?*intuition.DrawInfo) void
/// ```
///
/// SINCE: 0.4. LVO -120.
///
/// INPUTS:
/// - `screen` - the screen it came from.
/// - `draw_info` - what `GetScreenDrawInfo` answered, or null.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Nothing to free today: the DrawInfo is the screen's own. The pairing is
/// kept so a DrawInfo can become something built per caller without any
/// caller changing.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no. - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The DrawInfo may not be used after this.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetScreenDrawInfo`
///
/// EXAMPLES:
/// ```zig
/// ib.FreeScreenDrawInfo(screen, dri);
/// ```
pub fn FreeScreenDrawInfo(_: *IntuitionBase, screen: *Screen, draw_info: ?*intuition.DrawInfo) void {
    _ = screen;
    _ = draw_info;
}
