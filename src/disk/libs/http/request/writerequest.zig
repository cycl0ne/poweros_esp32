// SPDX-License-Identifier: MIT
//! WriteRequest: the request's body, a piece at a time, and its end.

const sdk = @import("sdk");
const http = sdk.http;
const HttpBase = @import("../http_base.zig").HttpBase;
const _request = @import("_request.zig");

/// Sends the next bytes of a request's body the program writes, or ends
/// the body and reads the head of the answer.
///
/// SYNOPSIS:
/// ```zig
/// fn WriteRequest(base: *HttpBase, request: *http.Request, data: ?*const anyopaque, length: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -40.
///
/// INPUTS:
/// - `request`: from OpenRequest with HTTP_Chunked, or with
///   HTTP_BodyLength and no HTTP_Body.
/// - `data`: the bytes; null with a `length` of 0.
/// - `length`: how many; 0 ends the body.
///
/// RESULT:
/// For bytes: `length` once they are all sent. For the end: the answer's
/// status, once its head is read. Below 0 an HTTPERR_*: HTTPERR_STATE
/// for a request whose body is not the program's, for bytes past the
/// length it gave, for an end before all of them came, or for a
/// `length` past 2 GiB; HTTPERR_IO, HTTPERR_TLS, HTTPERR_PROTOCOL,
/// HTTPERR_TRUNCATED and HTTPERR_DATA as OpenRequest answers them.
///
/// BEHAVIOR:
/// A body with HTTP_BodyLength goes as it is, and is ended once all of
/// its bytes have been written; one with HTTP_Chunked goes as a chunk
/// per call, of up to 8 KiB each, and its end is the last chunk. The
/// answer to it is read as OpenRequest reads one, interim answers aside,
/// but a redirect is not followed: it is the answer. After the end, the
/// body of the answer is read with ReadRequest.
///
/// A failure breaks the request: every call after it answers the same
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
/// The bytes stay the caller's; they are sent before the call returns.
///
/// NOTES:
/// A server may answer before it has the whole body - to refuse it, say
/// - and close; the next WriteRequest then fails with HTTPERR_IO.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenRequest`, `ReadRequest`, `CloseRequest`
///
/// EXAMPLES:
/// ```zig
/// const request = hb.OpenRequest(client, "POST", url, &[_]utility.TagItem{
///     .{ .tag = http.HTTP_Chunked, .data = 1 },
///     .{ .tag = http.HTTP_Header, .data = @intFromPtr("Content-Type: application/octet-stream") },
///     .{},
/// }, &err) orelse return err;
/// defer hb.CloseRequest(request);
/// while (more(&piece)) {
///     if (hb.WriteRequest(request, piece.ptr, @intCast(piece.len)) < 0) return;
/// }
/// const status = hb.WriteRequest(request, null, 0);
/// ```
pub fn WriteRequest(_: *HttpBase, request: *http.Request, data: ?*const anyopaque, length: u32) i32 {
    const own = _request.of(request) orelse return http.HTTPERR_STATE;
    if (length == 0) return _request.write(own, null);
    if (length > 0x7FFF_FFFF) return http.HTTPERR_STATE;
    const bytes: [*]const u8 = @ptrCast(data orelse return http.HTTPERR_STATE);
    return _request.write(own, bytes[0..length]);
}
