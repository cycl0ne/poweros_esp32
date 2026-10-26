// SPDX-License-Identifier: MIT
//! DeleteClient: a client and its kept connections gone.

const sdk = @import("sdk");
const http = sdk.http;
const HttpBase = @import("../http_base.zig").HttpBase;
const _client = @import("_client.zig");

/// Closes the connections a client keeps and frees the client.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteClient(base: *HttpBase, client: ?*http.Client) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `client`: from CreateClient, or null.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Closes every idle connection - a TLS session's goodbye sent first -
/// and frees the client. Null, or a pointer CreateClient did not make,
/// does nothing.
///
/// CONTEXT:
/// - Waits: yes, while a TLS session says goodbye.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: the task that opened the client's socket base.
///
/// OWNERSHIP:
/// The client is gone; its socket base stays the caller's.
///
/// NOTES:
/// Every request made through the client must have been closed first.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateClient`, `CloseRequest`
///
/// EXAMPLES:
/// ```zig
/// hb.DeleteClient(client);
/// ```
pub fn DeleteClient(_: *HttpBase, client: ?*http.Client) void {
    const handle = client orelse return;
    const own = _client.of(handle) orelse return;
    const sys = own.base.sys_base;
    _client.closeAll(own);
    own.magic = 0;
    sys.FreeVec(own);
}
