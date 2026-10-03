// SPDX-License-Identifier: MIT
//! GetSessionAttr: what a session is.

const sdk = @import("sdk");
const tls = sdk.tls;
const utility = sdk.utility;
const TLSBase = @import("../tls_base.zig").TLSBase;
const _session = @import("_session.zig");

/// One of a session's attributes.
///
/// SYNOPSIS:
/// ```zig
/// fn GetSessionAttr(base: *TLSBase, session: *tls.Session, attr: utility.Tag) usize
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `session`: from OpenSession.
/// - `attr`:
///   - TLS_Version: 0x0304 for TLS 1.3, 0x0303 for TLS 1.2.
///   - TLS_Suite: the cipher suite's number - 0x1301 AES-128-GCM-SHA256,
///     0x1302 AES-256-GCM-SHA384; TLS 1.2's 0xC02B, 0xC02F (ECDHE with
///     ECDSA or RSA, AES-128-GCM), 0xC02C, 0xC030 (AES-256-GCM).
///   - TLS_Verdict: the certificate check's TLSV_*.
///   - TLS_Alert: the alert the server ended with, 0 for none.
///   - TLS_Error: the session's last TLSERR_*.
///   - TLS_Protocol: the ALPN protocol the server chose, as a
///     `[*:0]const u8` that lives as long as the session; empty for none.
///   - TLS_Host: the host, as given.
///
/// RESULT:
/// The attribute; 0 for one it does not know.
///
/// BEHAVIOR:
/// Nothing is read from the server; a session that failed in
/// ReadSession or WriteSession still answers.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// A string answered is the session's.
///
/// NOTES:
/// OpenSession's failures leave no session to ask: its `err` says what
/// went wrong.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenSession`
///
/// EXAMPLES:
/// ```zig
/// const suite: u32 = @intCast(tb.GetSessionAttr(session, tls.TLS_Suite));
/// ```
pub fn GetSessionAttr(_: *TLSBase, session: *tls.Session, attr: utility.Tag) usize {
    const own = _session.sessionOf(session);
    return switch (attr) {
        tls.TLS_Version => own.client.version,
        tls.TLS_Suite => own.client.suite.id,
        tls.TLS_Verdict => @intFromEnum(own.client.verdict),
        tls.TLS_Alert => own.client.peer_alert,
        tls.TLS_Error => @bitCast(@as(isize, own.last_error)),
        tls.TLS_Protocol => @intFromPtr(&own.chosen_protocol),
        tls.TLS_Host => @intFromPtr(&own.host),
        else => 0,
    };
}
