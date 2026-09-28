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
/// CONTEXT:
/// - Waits: for memory to be given back.
/// - Interrupts: no.
/// - Forbid: held for as long as the requester is taken off the list.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// What the tags handed the requester stays the caller's and is not
/// touched.
///
/// SEE ALSO:
/// `AllocAslRequest`, `AslRequest`
///
/// EXAMPLES:
/// ```zig
/// ab.FreeAslRequest(req);
/// ```
pub fn FreeAslRequest(ab: *AslBase, requester: ?*anyopaque) void {
    const handle = requester orelse return;
    const r = _request.requesterOf(handle);
    const sys = ab.sys_base;
    _request.dropArgs(r);
    sys.Forbid();
    sys.Remove(@ptrCast(&r.node));
    sys.Permit();
    sys.FreeVec(@ptrCast(r));
}
