// SPDX-License-Identifier: MIT
//! CloseRequest: a request ended, its connection kept when it can be.

const sdk = @import("sdk");
const http = sdk.http;
const HttpBase = @import("../http_base.zig").HttpBase;
const _request = @import("_request.zig");

/// Ends a request: its connection goes back to the client for the next
/// request when it can, and the request is freed.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseRequest(base: *HttpBase, request: ?*http.Request) void
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `request`: from OpenRequest, or null.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A request whose answer was read to its end, from a server that keeps
/// the connection, gives the connection back to its client, which keeps
/// up to four idle and closes the one idle longest to make room. Any
/// other request closes its connection: one whose body was not read to
/// the end, one that failed, one whose server said `Connection: close`
/// or whose body ended with the connection. Null, or a pointer
/// OpenRequest did not make, does nothing.
///
/// CONTEXT:
/// - Waits: yes, while a TLS session says goodbye.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: the task that opened the client's socket base.
///
/// OWNERSHIP:
/// The request is gone, and with it the strings GetRequestAttr and
/// GetHeader handed out.
///
/// NOTES:
/// To keep the connection of an answer whose body is of no interest, read
/// the body to its end first.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenRequest`, `ReadRequest`, `DeleteClient`
///
/// EXAMPLES:
/// ```zig
/// hb.CloseRequest(request);
/// ```
pub fn CloseRequest(_: *HttpBase, request: ?*http.Request) void {
    const handle = request orelse return;
    const own = _request.of(handle) orelse return;
    _request.close(own);
}
