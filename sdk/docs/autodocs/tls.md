# tls.library

tls.library's functions: TLS 1.3 (and 1.2) sessions over stream sockets a
program connected - the handshake, the server's certificates checked
against the trusted roots, then plain bytes read and written. Open it
with OpenLibrary("tls.library", 1); the structures are in sdk.tls.

Generated from the source by `./zig build autodoc`.

## Index

- [CloseSession](#closesession) - Ends a session: the server is told (close_notify), and the session is freed.
- [GetSessionAttr](#getsessionattr) - One of a session's attributes.
- [OpenSession](#opensession) - Opens a TLS session over a stream socket the program has connected: the handshake, the server's certificates checked, and keys agreed.
- [ReadSession](#readsession) - Reads what the server sent: up to `length` bytes of it, decrypted.
- [SessionPending](#sessionpending) - How many bytes a session has decrypted and not yet handed over.
- [WriteSession](#writesession) - Writes bytes to the server, encrypted, in records of at most 16 KiB.

## CloseSession

Ends a session: the server is told (close_notify), and the session is freed.

**SYNOPSIS**

```zig
fn CloseSession(base: *TLSBase, session: ?*tls.Session) void
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `session`: from OpenSession, or null.

**RESULT**

None.

**BEHAVIOR**

A session still connected sends close_notify; one the server closed,
or that failed, sends nothing. Whether the alert gets through is the
socket's affair - the session is freed either way. Null does nothing.

**CONTEXT**

- Waits: yes, while the alert is sent.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: the task that opened the session.

**OWNERSHIP**

The session's memory, keys included, is overwritten and freed. The
socket stays the program's, to close.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`OpenSession`

**EXAMPLES**

```zig
tb.CloseSession(session);
_ = sb.CloseSocket(socket);
```

## GetSessionAttr

One of a session's attributes.

**SYNOPSIS**

```zig
fn GetSessionAttr(base: *TLSBase, session: *tls.Session, attr: utility.Tag) usize
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `session`: from OpenSession.
- `attr`:
  - TLS_Version: 0x0304 for TLS 1.3, 0x0303 for TLS 1.2.
  - TLS_Suite: the cipher suite's number - 0x1301 AES-128-GCM-SHA256,
    0x1302 AES-256-GCM-SHA384; TLS 1.2's 0xC02B, 0xC02F (ECDHE with
    ECDSA or RSA, AES-128-GCM), 0xC02C, 0xC030 (AES-256-GCM).
  - TLS_Verdict: the certificate check's TLSV_*.
  - TLS_Alert: the alert the server ended with, 0 for none.
  - TLS_Error: the session's last TLSERR_*.
  - TLS_Protocol: the ALPN protocol the server chose, as a
    `[*:0]const u8` that lives as long as the session; empty for none.
  - TLS_Host: the host, as given.

**RESULT**

The attribute; 0 for one it does not know.

**BEHAVIOR**

Nothing is read from the server; a session that failed in
ReadSession or WriteSession still answers.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

A string answered is the session's.

**NOTES**

OpenSession's failures leave no session to ask: its `err` says what
went wrong.

**BUGS**

None known.

**SEE ALSO**

`OpenSession`

**EXAMPLES**

```zig
const suite: u32 = @intCast(tb.GetSessionAttr(session, tls.TLS_Suite));
```

## OpenSession

Opens a TLS session over a stream socket the program has connected: the handshake, the server's certificates checked, and keys agreed.

**SYNOPSIS**

```zig
fn OpenSession(base: *TLSBase, socket_base: *SocketBase, socket: i32, tags: ?[*]const utility.TagItem, err: ?*i32) ?*tls.Session
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `socket_base`: the program's own bsdsocket.library base.
- `socket`: a stream socket of it, connected to the server, blocking.
- `tags`:
  - TLS_Host (`[*:0]const u8`, required): the server's name, sent to
    it (SNI) and checked against its certificate. An address is
    checked against the addresses a certificate names, and not sent.
  - TLS_Verify (bool, true): false checks only the server's
    CertificateVerify and Finished, not its certificates - for tests.
  - TLS_Protocol (`[*:0]const u8`): an ALPN protocol to ask for.
  - TLS_GetVerdict (`*u32`): where the certificate check's TLSV_*
    goes, also when the session fails.
  - TLS_GetAlert (`*u32`): where the alert the server refused with
    goes, or 0.
- `err`: where the reason goes when the answer is null, or null.

**RESULT**

The session, ready to read and write; `err` is then TLSERR_OK. Null,
with `err`: TLSERR_HOST without a host; TLSERR_CLOCK while the clock
has not been set; TLSERR_CERTIFICATE when the certificates were not
trusted; TLSERR_ALERT when the server refused; TLSERR_HANDSHAKE for
anything else the handshake found wrong; TLSERR_IO when the socket
failed or closed; TLSERR_NOMEM, TLSERR_CRYPTO.

**BEHAVIOR**

TLS 1.3 with AES-128-GCM or AES-256-GCM, an X25519 key share (P-256
or P-384 when the server asks), and ECDSA, RSA-PSS or Ed25519 for
the server's signature. A server that speaks nothing newer gets TLS
1.2: ECDHE on the same curves with AES-GCM, signed with ECDSA or RSA,
the extended master secret when it agrees, and no renegotiation. A
server that could have spoken 1.3 and answers 1.2 is refused - the
version was taken away on the way. The certificates are checked against
`SYS:Certificates/Roots` and the PEM files in
`ENVARC:Sys/net/certificates/`, read once by the first session, for
the host and at the time now in UTC - the clock keeps local time by
`ENVARC:Sys/timezone`. A clock set before this library was built has
not been set, and nothing is checked against it.

On a failure the server is sent an alert, as far as the socket
allows; the socket is left as it is.

**CONTEXT**

- Waits: yes, for the server, as long as the socket's own timeouts
  allow.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: yes - the stores are files.

**OWNERSHIP**

The session is the caller's until CloseSession, and its task's: only
that task may use it, as only it may use its bsdsocket base. The
socket stays the caller's, to WaitSelect on and to close after
CloseSession.

**NOTES**

A session takes some 75 KiB, for the records each way and the
handshake's messages. Certificates are not checked for revocation.

**BUGS**

None known.

**SEE ALSO**

`ReadSession`, `WriteSession`, `CloseSession`, `GetSessionAttr`

**EXAMPLES**

```zig
var err: i32 = 0;
const session = tb.OpenSession(sb, socket, &[_]utility.TagItem{
    .{ .tag = tls.TLS_Host, .data = @intFromPtr(host) },
    .{},
}, &err) orelse return err;
defer tb.CloseSession(session);
```

## ReadSession

Reads what the server sent: up to `length` bytes of it, decrypted.

**SYNOPSIS**

```zig
fn ReadSession(base: *TLSBase, session: *tls.Session, buffer: *anyopaque, length: u32) i32
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `session`: from OpenSession.
- `buffer`: room for `length` bytes.
- `length`: at most 2^31 - 1.

**RESULT**

How many bytes went into `buffer`, at least one; 0 when the server
closed the session; below 0 a TLSERR_*: TLSERR_IO when the socket
failed or closed without the server saying goodbye (which may be an
attack cutting the data short), TLSERR_ALERT, TLSERR_HANDSHAKE for a
record that did not decrypt.

**BEHAVIOR**

Bytes already decrypted are answered first, without reading the
socket. Otherwise records are read until one holds data: what the
server sends besides - a session ticket, a key update - is dealt with
on the way, and answered when it asks for an answer. A record holds
at most 16 KiB, so a short answer means only that this is what the
record had.

**CONTEXT**

- Waits: yes, for the server, as long as the socket's timeouts allow.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: the task that opened the session.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

WaitSelect on the socket does not see bytes already decrypted: ask
SessionPending before waiting.

**BUGS**

None known.

**SEE ALSO**

`WriteSession`, `SessionPending`

**EXAMPLES**

```zig
var buffer: [1024]u8 = undefined;
while (true) {
    const got = tb.ReadSession(session, &buffer, buffer.len);
    if (got <= 0) break;
    _ = dl.Write(output, &buffer, got);
}
```

## SessionPending

How many bytes a session has decrypted and not yet handed over.

**SYNOPSIS**

```zig
fn SessionPending(base: *TLSBase, session: *tls.Session) u32
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `session`: from OpenSession.

**RESULT**

The bytes ReadSession answers without reading the socket.

**BEHAVIOR**

A record is decrypted whole, and what a read does not take waits in
the session. WaitSelect watches the socket only, so a program that
waits for the server asks this first: bytes waiting here would never
wake it.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: the task that opened the session.

**OWNERSHIP**

Nothing changes hands.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ReadSession`

**EXAMPLES**

```zig
if (tb.SessionPending(session) == 0) _ = sb.WaitSelect(socket + 1, &read_set, null, null, null, &signals);
```

## WriteSession

Writes bytes to the server, encrypted, in records of at most 16 KiB.

**SYNOPSIS**

```zig
fn WriteSession(base: *TLSBase, session: *tls.Session, data: *const anyopaque, length: u32) i32
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `session`: from OpenSession.
- `data`: `length` bytes.
- `length`: at most 2^31 - 1.

**RESULT**

`length` when all of it was sent; below 0 a TLSERR_* - TLSERR_IO when
the socket failed, or the error the session failed with before.

**BEHAVIOR**

The bytes go out record by record, each sent whole before the next is
made. A write cut short by the socket leaves the session unusable:
the server would see a record broken off.

**CONTEXT**

- Waits: yes, while the socket sends.
- Interrupts: no.
- Locks: no spinlock may be held.
- Process: the task that opened the session.

**OWNERSHIP**

Nothing changes hands; `data` is read and not kept.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ReadSession`

**EXAMPLES**

```zig
const request = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n";
if (tb.WriteSession(session, request, request.len) < 0) return;
```
