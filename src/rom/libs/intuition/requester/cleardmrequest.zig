// SPDX-License-Identifier: MPL-2.0
//! ClearDMRequest: no double-click requester any more.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const _requester = @import("_requester.zig");

/// No double-click requester any more.
///
/// SYNOPSIS:
/// ```zig
/// fn ClearDMRequest(ib: *IntuitionBase, window: *Window) bool
/// ```
///
/// SINCE: 0.13. LVO -316.
///
/// INPUTS:
/// - `window` - the window.
///
/// RESULT:
/// True; false, and nothing changed, while the double-click requester is
/// up.
///
/// BEHAVIOR:
/// The window has no double-click requester afterwards: a double-click of
/// the menu button is two presses of it, as for any window.
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
/// `SetDMRequest`, `Request`, `sdk.intuition.windows.IDCMP_REQVERIFY`
///
/// EXAMPLES:
/// ```zig
/// _ = ib.ClearDMRequest(window);
/// ```
pub fn ClearDMRequest(ib: *IntuitionBase, window: *Window) bool {
    return _requester.setDM(ib, window, null);
}
