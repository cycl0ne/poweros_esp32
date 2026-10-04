// SPDX-License-Identifier: MIT
//! WriteSession: bytes to the server, encrypted.

const sdk = @import("sdk");
const tls = sdk.tls;
const TLSBase = @import("../tls_base.zig").TLSBase;
const _session = @import("_session.zig");
const client_module = @import("../protocol/client.zig");
const record = @import("../protocol/record.zig");

/// Writes bytes to the server, encrypted, in records of at most 16 KiB.
///
/// SYNOPSIS:
/// ```zig
/// fn WriteSession(base: *TLSBase, session: *tls.Session, data: *const anyopaque, length: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `session`: from OpenSession.
/// - `data`: `length` bytes.
/// - `length`: at most 2^31 - 1.
///
/// RESULT:
/// `length` when all of it was sent; below 0 a TLSERR_* - TLSERR_IO when
/// the socket failed, or the error the session failed with before.
///
/// BEHAVIOR:
/// The bytes go out record by record, each sent whole before the next is
/// made. A write cut short by the socket leaves the session unusable:
/// the server would see a record broken off.
///
/// CONTEXT:
/// - Waits: yes, while the socket sends.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: the task that opened the session.
///
/// OWNERSHIP:
/// Nothing changes hands; `data` is read and not kept.
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
/// const request = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n";
/// if (tb.WriteSession(session, request, request.len) < 0) return;
/// ```
pub fn WriteSession(_: *TLSBase, session: *tls.Session, data: *const anyopaque, length: u32) i32 {
    const own = _session.sessionOf(session);
    if (own.last_error != tls.TLSERR_OK) return own.last_error;
    if (own.finished) return tls.TLSERR_IO;
    const bytes: [*]const u8 = @ptrCast(data);
    const total: usize = @min(length, 0x7FFF_FFFF);
    var at: usize = 0;
    while (at < total) {
        const take: usize = @min(total - at, record.max_plaintext);
        var output: client_module.Output = .{ .buffer = &own.outgoing };
        own.client.send(bytes[at..][0..take], &output);
        if (!_session.flush(own, &output)) {
            own.last_error = tls.TLSERR_IO;
            return own.last_error;
        }
        at += take;
    }
    return @intCast(total);
}
