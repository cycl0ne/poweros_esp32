// SPDX-License-Identifier: MIT
//! AbortAslRequest: a requester up on a process of its own taken down
//! before it is answered.

const sdk = @import("sdk");
const exec = sdk.exec;
const AslBase = @import("../asl_base.zig").AslBase;
const _request = @import("_request.zig");

/// A requester up on a process of its own taken down before it is
/// answered.
///
/// SYNOPSIS:
/// ```zig
/// fn AbortAslRequest(ab: *AslBase, requester: *anyopaque) void
/// ```
///
/// SINCE: 1.4. LVO -32.
///
/// INPUTS:
/// - `ab` - asl.library's base.
/// - `requester` - what `AllocAslRequest` made, put up with
///   `ASLFR_ReplyPort`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The requester's process is given Ctrl-C, which a requester takes as
/// being given up: its window closes and its message arrives on its port
/// as for any other end, with `answered` 0 - or 1, if the user answered
/// it just before. A file requester still reading a drawer stops at the
/// next piece of it.
///
/// A requester that is not up - never put up on a port, or ended
/// already - is left alone, so a program ending calls this for a
/// requester it may have asked with and then waits for the message only
/// if one is owed.
///
/// CONTEXT:
/// - Waits: only for the requester's semaphore, held briefly by its
///   process as it ends.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The requester stays the library's until its message has arrived.
///
/// NOTES:
/// It returns before the requester has gone: the message is what says it
/// has. A requester asked and waited for on the caller's own process is
/// ended the same way by Ctrl-C to that process.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AslRequest`, `FreeAslRequest`, exec's `AbortIO`
///
/// EXAMPLES:
/// ```zig
/// // Ending with a requester up: take it down and wait for its message.
/// if (asking) {
///     ab.AbortAslRequest(req);
///     _ = sys.WaitPort(port);
///     _ = sys.GetMsg(port);
/// }
/// ab.FreeAslRequest(req);
/// ```
pub fn AbortAslRequest(ab: *AslBase, requester: *anyopaque) void {
    const r = _request.requesterOf(requester);
    const sys = ab.sys_base;
    // Named only while its process lives: it lets the name go under the
    // same semaphore before it ends.
    sys.ObtainSemaphore(&r.asker_lock);
    defer sys.ReleaseSemaphore(&r.asker_lock);
    if (r.asker) |process| sys.Signal(process, exec.SIGBREAKF_CTRL_C);
}
