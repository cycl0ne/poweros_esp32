// SPDX-License-Identifier: MPL-2.0
//! EndRequest: takes a requester down.

const sdk = @import("sdk");
const Requester = sdk.intuition.Requester;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const _requester = @import("_requester.zig");

/// Takes a requester down.
///
/// SYNOPSIS:
/// ```zig
/// fn EndRequest(ib: *IntuitionBase, requester: *Requester, window: *Window) void
/// ```
///
/// SINCE: 0.13. LVO -308.
///
/// INPUTS:
/// - `requester` - a requester up in the window.
/// - `window` - the window.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The requester comes out of the window's stack wherever it is in it - the
/// newest, or one behind it. A gadget of it that had the input is told it
/// has lost it; its layer goes, and what it covered comes back - a
/// smart-refresh window's pixels, a simple one told to draw the part again.
/// The window gets `IDCMP_REQCLEAR` with the requester in `iaddress`, and
/// `WFLG_INREQUEST` is cleared when it was the last. A requester that is
/// not up in this window is left alone.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore and the layers' locks.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The requester and its gadgets are the caller's to change or free once
/// this returns.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Request`, `sdk.intuition.gadgetclass.GA_EndGadget`
///
/// EXAMPLES:
/// ```zig
/// ib.EndRequest(&box, window);
/// ```
pub fn EndRequest(ib: *IntuitionBase, requester: *Requester, window: *Window) void {
    _window.lock(ib);
    defer _window.unlock(ib);
    _ = _requester.take(ib, window, requester, true);
}
