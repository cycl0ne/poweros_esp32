// SPDX-License-Identifier: MIT
//! SessionPending: the bytes ReadSession has waiting.

const sdk = @import("sdk");
const tls = sdk.tls;
const TLSBase = @import("../tls_base.zig").TLSBase;
const _session = @import("_session.zig");

/// How many bytes a session has decrypted and not yet handed over.
///
/// SYNOPSIS:
/// ```zig
/// fn SessionPending(base: *TLSBase, session: *tls.Session) u32
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `session`: from OpenSession.
///
/// RESULT:
/// The bytes ReadSession answers without reading the socket.
///
/// BEHAVIOR:
/// A record is decrypted whole, and what a read does not take waits in
/// the session. WaitSelect watches the socket only, so a program that
/// waits for the server asks this first: bytes waiting here would never
/// wake it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: the task that opened the session.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadSession`
///
/// EXAMPLES:
/// ```zig
/// if (tb.SessionPending(session) == 0) _ = sb.WaitSelect(socket + 1, &read_set, null, null, null, &signals);
/// ```
pub fn SessionPending(_: *TLSBase, session: *tls.Session) u32 {
    return @intCast(_session.sessionOf(session).waiting.len);
}
