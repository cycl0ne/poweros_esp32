// SPDX-License-Identifier: MIT
//! CloseSession: a session ended and freed.

const sdk = @import("sdk");
const tls = sdk.tls;
const TLSBase = @import("../tls_base.zig").TLSBase;
const _session = @import("_session.zig");
const client_module = @import("../protocol/client.zig");

/// Ends a session: the server is told (close_notify), and the session is
/// freed.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseSession(base: *TLSBase, session: ?*tls.Session) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `session`: from OpenSession, or null.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A session still connected sends close_notify; one the server closed,
/// or that failed, sends nothing. Whether the alert gets through is the
/// socket's affair - the session is freed either way. Null does nothing.
///
/// CONTEXT:
/// - Waits: yes, while the alert is sent.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: the task that opened the session.
///
/// OWNERSHIP:
/// The session's memory, keys included, is overwritten and freed. The
/// socket stays the program's, to close.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenSession`
///
/// EXAMPLES:
/// ```zig
/// tb.CloseSession(session);
/// _ = sb.CloseSocket(socket);
/// ```
pub fn CloseSession(base: *TLSBase, session: ?*tls.Session) void {
    const handle = session orelse return;
    const own = _session.sessionOf(handle);
    var output: client_module.Output = .{ .buffer = &own.outgoing };
    own.client.close(&output);
    _ = _session.flush(own, &output);
    const bytes: [*]volatile u8 = @ptrCast(own);
    for (0..@sizeOf(_session.Session)) |index| bytes[index] = 0;
    base.sys_base.FreeVec(own);
}
