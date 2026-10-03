// SPDX-License-Identifier: MIT
//! OpenSession: TLS over a connected socket - the handshake, and the
//! server checked.

const sdk = @import("sdk");
const exec = sdk.exec;
const tls = sdk.tls;
const utility = sdk.utility;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const TLSBase = @import("../tls_base.zig").TLSBase;
const tls_init = @import("../tls_init.zig");
const _session = @import("_session.zig");
const Session = _session.Session;
const client_module = @import("../protocol/client.zig");

/// Opens a TLS session over a stream socket the program has connected:
/// the handshake, the server's certificates checked, and keys agreed.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenSession(base: *TLSBase, socket_base: *SocketBase, socket: i32, tags: ?[*]const utility.TagItem, err: ?*i32) ?*tls.Session
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `socket_base`: the program's own bsdsocket.library base.
/// - `socket`: a stream socket of it, connected to the server, blocking.
/// - `tags`:
///   - TLS_Host (`[*:0]const u8`, required): the server's name, sent to
///     it (SNI) and checked against its certificate. An address is
///     checked against the addresses a certificate names, and not sent.
///   - TLS_Verify (bool, true): false checks only the server's
///     CertificateVerify and Finished, not its certificates - for tests.
///   - TLS_Protocol (`[*:0]const u8`): an ALPN protocol to ask for.
///   - TLS_GetVerdict (`*u32`): where the certificate check's TLSV_*
///     goes, also when the session fails.
///   - TLS_GetAlert (`*u32`): where the alert the server refused with
///     goes, or 0.
/// - `err`: where the reason goes when the answer is null, or null.
///
/// RESULT:
/// The session, ready to read and write; `err` is then TLSERR_OK. Null,
/// with `err`: TLSERR_HOST without a host; TLSERR_CLOCK while the clock
/// has not been set; TLSERR_CERTIFICATE when the certificates were not
/// trusted; TLSERR_ALERT when the server refused; TLSERR_HANDSHAKE for
/// anything else the handshake found wrong; TLSERR_IO when the socket
/// failed or closed; TLSERR_NOMEM, TLSERR_CRYPTO.
///
/// BEHAVIOR:
/// TLS 1.3 with AES-128-GCM or AES-256-GCM, an X25519 key share (P-256
/// or P-384 when the server asks), and ECDSA, RSA-PSS or Ed25519 for
/// the server's signature. A server that speaks nothing newer gets TLS
/// 1.2: ECDHE on the same curves with AES-GCM, signed with ECDSA or RSA,
/// the extended master secret when it agrees, and no renegotiation. A
/// server that could have spoken 1.3 and answers 1.2 is refused - the
/// version was taken away on the way. The certificates are checked against
/// `SYS:Certificates/Roots` and the PEM files in
/// `ENVARC:Sys/net/certificates/`, read once by the first session, for
/// the host and at the time now in UTC - the clock keeps local time by
/// `ENVARC:Sys/timezone`. A clock set before this library was built has
/// not been set, and nothing is checked against it.
///
/// On a failure the server is sent an alert, as far as the socket
/// allows; the socket is left as it is.
///
/// CONTEXT:
/// - Waits: yes, for the server, as long as the socket's own timeouts
///   allow.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: yes - the stores are files.
///
/// OWNERSHIP:
/// The session is the caller's until CloseSession, and its task's: only
/// that task may use it, as only it may use its bsdsocket base. The
/// socket stays the caller's, to WaitSelect on and to close after
/// CloseSession.
///
/// NOTES:
/// A session takes some 75 KiB, for the records each way and the
/// handshake's messages. Certificates are not checked for revocation.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadSession`, `WriteSession`, `CloseSession`, `GetSessionAttr`
///
/// EXAMPLES:
/// ```zig
/// var err: i32 = 0;
/// const session = tb.OpenSession(sb, socket, &[_]utility.TagItem{
///     .{ .tag = tls.TLS_Host, .data = @intFromPtr(host) },
///     .{},
/// }, &err) orelse return err;
/// defer tb.CloseSession(session);
/// ```
pub fn OpenSession(base: *TLSBase, socket_base: *SocketBase, socket: i32, tags: ?[*]const utility.TagItem, err: ?*i32) ?*tls.Session {
    var reason: i32 = tls.TLSERR_OK;
    const session = open(base, socket_base, socket, tags, &reason);
    if (err) |into| into.* = reason;
    return session;
}

fn open(base: *TLSBase, socket_base: *SocketBase, socket: i32, tags: ?[*]const utility.TagItem, reason: *i32) ?*tls.Session {
    const sys = base.sys_base;
    const prepared = _session.ready(base);
    if (prepared != tls.TLSERR_OK) {
        reason.* = prepared;
        return null;
    }
    const ub = base.utility_base.?;
    const host_pointer: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(tls.TLS_Host, 0, tags));
    const host = host_pointer orelse {
        reason.* = tls.TLSERR_HOST;
        return null;
    };
    const verify = ub.GetTagData(tls.TLS_Verify, 1, tags) != 0;
    const protocol_pointer: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(tls.TLS_Protocol, 0, tags));
    const verdict_out: ?*u32 = @ptrFromInt(ub.GetTagData(tls.TLS_GetVerdict, 0, tags));
    const alert_out: ?*u32 = @ptrFromInt(ub.GetTagData(tls.TLS_GetAlert, 0, tags));
    if (verdict_out) |out| out.* = tls.TLSV_TRUSTED;
    if (alert_out) |out| out.* = 0;
    const time = _session.now(base);
    if (verify and time < tls_init.BUILD_TIME) {
        reason.* = tls.TLSERR_CLOCK;
        return null;
    }

    const memory = sys.AllocVec(@sizeOf(Session), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        reason.* = tls.TLSERR_NOMEM;
        return null;
    };
    // Filled in place on cleared memory: the session is far larger than a
    // program's stack, which a whole value would be built on first.
    const session: *Session = @ptrCast(@alignCast(memory));
    session.base = base;
    session.sockets = socket_base;
    session.socket = socket;
    session.stores = .{ &.{}, &.{} };
    session.waiting = &.{};
    const host_length = copy(&session.host, host);
    if (host_length == 0) {
        sys.FreeVec(memory);
        reason.* = tls.TLSERR_HOST;
        return null;
    }
    var protocol_length: usize = 0;
    if (protocol_pointer) |protocol| protocol_length = copy(&session.asked_protocol, protocol);
    _session.storesOf(base, session);
    var store_count: usize = 0;
    for (session.stores) |store| {
        if (store.len != 0) store_count += 1;
    }

    const client = &session.client;
    client.init(base.crypto_base.?, .{
        .host = session.host[0..host_length],
        .now = time,
        .verify = verify,
        .stores = session.stores[0..store_count],
        .alpn = session.asked_protocol[0..protocol_length],
    });
    var output: client_module.Output = .{ .buffer = &session.outgoing };
    client.start(&output);
    var failed = !_session.flush(session, &output);
    while (!failed) {
        const received = _session.readRecord(session) orelse {
            failed = true;
            break;
        };
        const event = client.receive(received, &output);
        const sent = _session.flush(session, &output);
        switch (event) {
            .connected => {
                if (!sent) break;
                const chosen = client.protocol();
                @memcpy(session.chosen_protocol[0..chosen.len], chosen);
                return _session.handleOf(session);
            },
            .more => if (!sent) {
                failed = true;
            },
            else => {
                reason.* = _session.errorOf(client);
                if (verdict_out) |out| out.* = @intFromEnum(client.verdict);
                if (alert_out) |out| out.* = client.peer_alert;
                sys.FreeVec(memory);
                return null;
            },
        }
    }
    reason.* = tls.TLSERR_IO;
    sys.FreeVec(memory);
    return null;
}

/// A C string into a buffer, NUL after it; its length, or 0 for one that
/// does not fit.
fn copy(into: []u8, text: [*:0]const u8) usize {
    var length: usize = 0;
    while (text[length] != 0) : (length += 1) {
        if (length + 1 >= into.len) return 0;
        into[length] = text[length];
    }
    into[length] = 0;
    return length;
}
