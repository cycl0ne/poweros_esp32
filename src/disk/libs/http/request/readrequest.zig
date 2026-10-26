// SPDX-License-Identifier: MIT
//! ReadRequest: the answer's body, a piece at a time.

const sdk = @import("sdk");
const http = sdk.http;
const HttpBase = @import("../http_base.zig").HttpBase;
const _request = @import("_request.zig");

/// Reads the next bytes of the answer's body.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadRequest(base: *HttpBase, request: *http.Request, buffer: *anyopaque, length: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -36.
///
/// INPUTS:
/// - `request`: from OpenRequest, its answer's head read.
/// - `buffer`: room for `length` bytes.
/// - `length`: how many bytes at most.
///
/// RESULT:
/// How many bytes were read, at least 1; 0 at the body's end; below 0
/// an HTTPERR_*: HTTPERR_IO when the connection failed, HTTPERR_TLS when
/// its session did, HTTPERR_TRUNCATED when it ended before the body,
/// HTTPERR_PROTOCOL for chunks that make no sense, HTTPERR_DATA for a
/// packed body that does not unpack, HTTPERR_STATE while the program's
/// own body has not been ended.
///
/// BEHAVIOR:
/// Hands over first what came with the head, then what the connection
/// brings, as soon as it brings any: a read may answer fewer bytes than
/// asked for long before the end. The body is decoded from its chunks; a
/// body packed with gzip or deflate is unpacked when the request asked
/// for HTTP_Unzip, and its end is the packed stream's. A body ends where
/// its Content-Length says, at its last chunk, or where the server closes
/// the connection; the answer to HEAD, a 204 and a 304 have none.
///
/// An error breaks the request: every read after it answers the same
/// error, and the connection is not kept.
///
/// CONTEXT:
/// - Waits: yes, for the server, as long as HTTP_Timeout allows; Ctrl-C
///   ends a wait with HTTPERR_IO.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: the task that opened the client's socket base.
///
/// OWNERSHIP:
/// The bytes are the caller's.
///
/// NOTES:
/// One read takes at most 2 GiB less 64 KiB, whatever `length` says.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenRequest`, `GetRequestAttr`, `CloseRequest`
///
/// EXAMPLES:
/// ```zig
/// var buffer: [4096]u8 = undefined;
/// while (true) {
///     const got = hb.ReadRequest(request, &buffer, buffer.len);
///     if (got < 0) return got;
///     if (got == 0) break;
///     _ = dos.Write(file, &buffer, got);
/// }
/// ```
pub fn ReadRequest(_: *HttpBase, request: *http.Request, buffer: *anyopaque, length: u32) i32 {
    const own = _request.of(request) orelse return http.HTTPERR_STATE;
    const bytes: [*]u8 = @ptrCast(buffer);
    const most: u32 = @min(length, 0x7FFF_0000);
    return _request.read(own, bytes[0..most]);
}
