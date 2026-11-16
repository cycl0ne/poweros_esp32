// SPDX-License-Identifier: MPL-2.0
//! RemRtgNotify: Give a notification back.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _board = @import("_board.zig");

/// Gives back a notification `AddRtgNotify` answered.
///
/// SYNOPSIS:
/// ```zig
/// fn RemRtgNotify(rb: *RtgBase, notify: ?*rtg.RtgNotify) void
/// ```
///
/// SINCE: 1.20. LVO -324.
///
/// INPUTS:
/// - `notify` - the notification. Null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The task is signalled no more for it: once this returns, no change is
/// told through this notification. A signal sent before stays set on the
/// task until it is waited for or cleared.
///
/// CONTEXT:
/// - Waits: while another task holds the notifications' lock - while the
///   tasks are being told of a change.
/// - Interrupts: no.
/// - Locks: takes the notifications' lock. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The notification's memory is freed.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddRtgNotify`
///
/// EXAMPLES:
/// ```zig
/// rb.RemRtgNotify(notify);
/// ```
pub fn RemRtgNotify(rb: *RtgBase, notify: ?*rtg.RtgNotify) void {
    const sys = rb.sys_base;
    const gone: *_board.Notify = @ptrCast(@alignCast(notify orelse return));
    sys.ObtainSemaphore(&rb.notify_lock);
    sys.Remove(&gone.node);
    sys.ReleaseSemaphore(&rb.notify_lock);
    sys.FreeVec(gone);
}
