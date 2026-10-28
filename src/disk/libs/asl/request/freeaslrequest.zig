// SPDX-License-Identifier: MIT
//! FreeAslRequest: a requester given back.

const sdk = @import("sdk");
const AslBase = @import("../asl_base.zig").AslBase;
const _request = @import("_request.zig");

/// A requester given back, with everything it was answered with.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeAslRequest(ab: *AslBase, requester: ?*anyopaque) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `ab` - asl.library's base.
/// - `requester` - what `AllocAslRequest` made; null does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The request structure goes with it: every pointer the program read out
/// of it - the file, the drawer, the pattern, the names of a multi-select
/// answer and the locks with them - is gone once this returns, so a
/// program that wants to keep an answer copies it first.
///
/// A requester still up on a process of its own (`ASLFR_ReplyPort`) is
/// left as it is, since its process is using it: the program takes it
/// down with `AbortAslRequest`, waits for its message and frees it then.
///
/// CONTEXT:
/// - Waits: for memory to be given back.
/// - Interrupts: no.
/// - Locks: takes asl's requester lock, a spinlock, while the requester is
///   taken off the list.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// What the tags handed the requester stays the caller's and is not
/// touched.
///
/// BUGS:
/// A requester whose message has been sent but not yet taken off the
/// port cannot be told from one that is the program's again: freed then,
/// the message on the port is gone with it.
///
/// SEE ALSO:
/// `AllocAslRequest`, `AslRequest`, `AbortAslRequest`
///
/// EXAMPLES:
/// ```zig
/// ab.FreeAslRequest(req);
/// ```
pub fn FreeAslRequest(ab: *AslBase, requester: ?*anyopaque) void {
    const handle = requester orelse return;
    const r = _request.requesterOf(handle);
    const sys = ab.sys_base;
    sys.ObtainSemaphore(&r.asker_lock);
    const busy = r.asker != null;
    sys.ReleaseSemaphore(&r.asker_lock);
    if (busy) return;
    _request.dropArgs(r);
    sys.AcquireLock(&ab.requester_lock);
    sys.Remove(@ptrCast(&r.node));
    sys.ReleaseLock(&ab.requester_lock);
    sys.FreeVec(@ptrCast(r));
}
