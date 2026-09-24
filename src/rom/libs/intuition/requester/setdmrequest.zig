// SPDX-License-Identifier: MPL-2.0
//! SetDMRequest: the requester a double-click of the menu button puts up.

const sdk = @import("sdk");
const Requester = sdk.intuition.Requester;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const _requester = @import("_requester.zig");

/// The requester a double-click of the menu button puts up.
///
/// SYNOPSIS:
/// ```zig
/// fn SetDMRequest(ib: *IntuitionBase, window: *Window, requester: *Requester) bool
/// ```
///
/// SINCE: 0.13. LVO -312.
///
/// INPUTS:
/// - `window` - the window.
/// - `requester` - what a double-click of the menu button puts up.
///
/// RESULT:
/// True; false, and nothing changed, while the double-click requester the
/// window has is up.
///
/// BEHAVIOR:
/// The requester becomes the window's double-click requester, in place of
/// any it had. While the window is active and has no requester up, the
/// menu button pressed twice within the double-click time, the pointer
/// hardly moved, puts it up: the menu bar shows after the first press, the
/// window is sent `IDCMP_REQVERIFY` and its reply waited for, and then the
/// requester goes up as `Request` puts one - with `POINTREL` under the
/// pointer, moved by `rel_left` and `rel_top`. A first press held past
/// the double-click time, or moved away, is the menus as usual.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The requester stays the caller's, and must stay where it is until it is
/// cleared again - which must happen before the window closes.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ClearDMRequest`, `Request`, `sdk.intuition.windows.IDCMP_REQVERIFY`
///
/// EXAMPLES:
/// ```zig
/// _ = ib.SetDMRequest(window, &quick);
/// ```
pub fn SetDMRequest(ib: *IntuitionBase, window: *Window, requester: *Requester) bool {
    return _requester.setDM(ib, window, requester);
}
