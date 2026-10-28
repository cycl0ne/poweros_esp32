// SPDX-License-Identifier: MPL-2.0
//! WaitRequest: a request's answer, waited for.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _request = @import("_request.zig");
const DosRequest = dos.DosRequest;

/// Waits for a read or write started with StartRead or StartWrite, and
/// gives its answer.
///
/// SYNOPSIS:
/// ```zig
/// fn WaitRequest(db: *DosBase, request: ?*DosRequest) isize
/// ```
///
/// SINCE: 1.14. LVO -624.
///
/// INPUTS:
/// - `request` - the request.
///
/// RESULT:
/// What Read or Write would have answered: the count (0 at a read's
/// end), or -1 with `IoErr()` set. A request not out answers what it
/// answered last, 0 for one never started; null answers -1 with
/// `ERROR_REQUIRED_ARG_MISSING`.
///
/// BEHAVIOR:
/// Waits for the request's message at its port and takes only that one
/// off: what came before it on a shared port goes back as it was, the
/// port's signal set again. A port that is the process's msg_port is
/// waited at through pr_PktWait when the process has one. The request is
/// then free to start again.
///
/// CONTEXT:
/// - Waits: yes, until the handler has served the request.
/// - Interrupts: no. It waits.
/// - Locks: none taken; no spinlock may be held around it.
/// - Process: the task that allocated the request, whose signal its port
///   has.
///
/// OWNERSHIP:
/// The request's buffer is the caller's again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CheckRequest`, `StartRead`, `StartWrite`
///
/// EXAMPLES:
/// ```zig
/// const got = dos_lib.WaitRequest(request);
/// if (got < 0) return dos_lib.IoErr();
/// ```
pub fn WaitRequest(db: *DosBase, request: ?*DosRequest) isize {
    const req = request orelse {
        _ = db.iface().SetIoErr(dos.ERROR_REQUIRED_ARG_MISSING);
        return -1;
    };
    _ = _request.take(db, req, true);
    req.state = .idle;
    if (req.result < 0) _ = db.iface().SetIoErr(req.code);
    return req.result;
}
