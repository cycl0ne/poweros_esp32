// SPDX-License-Identifier: MPL-2.0
//! FreeSysRequest: closes a requester and gives back what was made for it.

const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const Window = @import("../window/_window.zig").Window;
const _request = @import("_request.zig");
const Request = _request.Request;

/// Closes a requester and gives back what was made for it.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeSysRequest(ib: *IntuitionBase, window: ?*Window) void
/// ```
///
/// SINCE: 0.11. LVO -260.
///
/// INPUTS:
/// - `window` - what `BuildEasyRequestArgs` answered, or null, which does
///   nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The window closes - with any message still waiting at it - and its
/// buttons and the words and lines they were made from are freed. A
/// window `BuildEasyRequestArgs` did not open is left alone.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore and the layers' locks.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The window and everything read from it are gone. Every message taken
/// from its port must have been replied first; `SysReqHandler` replies to
/// what it reads.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BuildEasyRequestArgs`, `SysReqHandler`
///
/// EXAMPLES:
/// ```zig
/// ib.FreeSysRequest(req);
/// ```
pub fn FreeSysRequest(ib: *IntuitionBase, window: ?*Window) void {
    const w = window orelse return;
    const request: *Request = @ptrCast(@alignCast(w.request orelse return));
    w.request = null;
    ib.iface().CloseWindow(@ptrCast(w));
    _request.free(ib, request);
}
