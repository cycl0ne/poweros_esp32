// SPDX-License-Identifier: MIT
//! ReadSession: what the server sent, decrypted.

const sdk = @import("sdk");
const tls = sdk.tls;
const TLSBase = @import("../tls_base.zig").TLSBase;
const _session = @import("_session.zig");
const client_module = @import("../protocol/client.zig");

/// Reads what the server sent: up to `length` bytes of it, decrypted.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadSession(base: *TLSBase, session: *tls.Session, buffer: *anyopaque, length: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `session`: from OpenSession.
/// - `buffer`: room for `length` bytes.
/// - `length`: at most 2^31 - 1.
///
/// RESULT:
/// How many bytes went into `buffer`, at least one; 0 when the server
/// closed the session; below 0 a TLSERR_*: TLSERR_IO when the socket
/// failed or closed without the server saying goodbye (which may be an
/// attack cutting the data short), TLSERR_ALERT, TLSERR_HANDSHAKE for a
/// record that did not decrypt.
///
/// BEHAVIOR:
/// Bytes already decrypted are answered first, without reading the
/// socket. Otherwise records are read until one holds data: what the
/// server sends besides - a session ticket, a key update - is dealt with
/// on the way, and answered when it asks for an answer. A record holds
/// at most 16 KiB, so a short answer means only that this is what the
/// record had.
///
/// CONTEXT:
/// - Waits: yes, for the server, as long as the socket's timeouts allow.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: the task that opened the session.
///
/// OWNERSHIP:
/// Nothing changes hands.
///
/// NOTES:
/// WaitSelect on the socket does not see bytes already decrypted: ask
/// SessionPending before waiting.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `WriteSession`, `SessionPending`
///
/// EXAMPLES:
/// ```zig
/// var buffer: [1024]u8 = undefined;
/// while (true) {
///     const got = tb.ReadSession(session, &buffer, buffer.len);
///     if (got <= 0) break;
///     _ = dl.Write(output, &buffer, got);
/// }
/// ```
pub fn ReadSession(_: *TLSBase, session: *tls.Session, buffer: *anyopaque, length: u32) i32 {
    const own = _session.sessionOf(session);
    const out: [*]u8 = @ptrCast(buffer);
    const wanted: usize = @min(length, 0x7FFF_FFFF);
    while (true) {
        if (own.waiting.len > 0) {
            const take: usize = @min(own.waiting.len, wanted);
            @memcpy(out[0..take], own.waiting[0..take]);
            own.waiting = own.waiting[take..];
            return @intCast(take);
        }
        if (own.finished) return 0;
        if (own.last_error != tls.TLSERR_OK) return own.last_error;
        if (wanted == 0) return 0;

        const received = _session.readRecord(own) orelse {
            own.last_error = tls.TLSERR_IO;
            return own.last_error;
        };
        var output: client_module.Output = .{ .buffer = &own.outgoing };
        const event = own.client.receive(received, &output);
        _ = _session.flush(own, &output);
        switch (event) {
            .data => |data| own.waiting = data,
            .more, .connected => {},
            .closed => own.finished = true,
            .failed => own.last_error = _session.errorOf(&own.client),
        }
    }
}
