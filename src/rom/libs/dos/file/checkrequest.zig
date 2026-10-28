// SPDX-License-Identifier: MPL-2.0
//! CheckRequest: whether a request has come back, without waiting.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _request = @import("_request.zig");
const DosRequest = dos.DosRequest;

/// Says whether a read or write started with StartRead or StartWrite is
/// back.
///
/// SYNOPSIS:
/// ```zig
/// fn CheckRequest(db: *DosBase, request: ?*DosRequest) bool
/// ```
///
/// SINCE: 1.14. LVO -620.
///
/// INPUTS:
/// - `request` - the request.
///
/// RESULT:
/// True when it is back - or was never out - so WaitRequest answers at
/// once; false while the handler still has it, and for a null request.
///
/// BEHAVIOR:
/// A request that is back is taken off its port: only its own message,
/// what came before it on a shared port put back as it was, the port's
/// signal set again. Its answer stays in it for WaitRequest.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none taken.
/// - Process: the task that allocated the request.
///
/// OWNERSHIP:
/// Nothing changes hands; the request is free to start again only after
/// WaitRequest.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WaitRequest`, `StartRead`, `StartWrite`
///
/// EXAMPLES:
/// ```zig
/// while (!dos_lib.CheckRequest(request)) drawProgress();
/// const got = dos_lib.WaitRequest(request);
/// ```
pub fn CheckRequest(db: *DosBase, request: ?*DosRequest) bool {
    const req = request orelse return false;
    return _request.take(db, req, false);
}
