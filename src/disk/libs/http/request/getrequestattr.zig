// SPDX-License-Identifier: MIT
//! GetRequestAttr: what a request knows of itself and its answer.

const sdk = @import("sdk");
const http = sdk.http;
const utility = sdk.utility;
const HttpBase = @import("../http_base.zig").HttpBase;
const _request = @import("_request.zig");

/// Answers one of a request's attributes.
///
/// SYNOPSIS:
/// ```zig
/// fn GetRequestAttr(base: *HttpBase, request: *http.Request, attr: utility.Tag) usize
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `request`: from OpenRequest.
/// - `attr`:
///   - HTTP_Status: the answer's status, 200 for OK; 0 while the body is
///     being written.
///   - HTTP_StatusLine (`[*:0]const u8`): `HTTP/1.1 404 Not Found`, or a
///     Shoutcast server's `ICY 200 OK`; empty while the body is being
///     written.
///   - HTTP_ContentLength: the body's length as the answer gives it, or
///     HTTP_LENGTH_UNKNOWN for one in chunks, one that ends with the
///     connection, or one being unpacked.
///   - HTTP_URL (`[*:0]const u8`): the URL that answered, after the
///     redirects.
///   - HTTP_Reused (bool): the request went over a connection an earlier
///     one had made.
///   - HTTP_Secure (bool): it went over TLS.
///   - HTTP_Error: the HTTPERR_* that broke it, or HTTPERR_OK.
///   - HTTP_Verdict: the certificate check's TLSV_*, over TLS.
///   - HTTP_Unzipping (bool): ReadRequest unpacks the body.
///
/// RESULT:
/// The attribute's value; 0 for an attribute there is not, or a request
/// OpenRequest did not make.
///
/// BEHAVIOR:
/// Reads the request; nothing goes over the connection.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// A string is the request's, there until CloseRequest.
///
/// NOTES:
/// On a 32-bit chip a length of 4 GiB or more reads as
/// HTTP_LENGTH_UNKNOWN; the Content-Length header has it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetHeader`, `OpenRequest`
///
/// EXAMPLES:
/// ```zig
/// const status = hb.GetRequestAttr(request, http.HTTP_Status);
/// const line: [*:0]const u8 = @ptrFromInt(hb.GetRequestAttr(request, http.HTTP_StatusLine));
/// ```
pub fn GetRequestAttr(_: *HttpBase, request: *http.Request, attr: utility.Tag) usize {
    const own = _request.of(request) orelse return 0;
    const answered = own.phase != .writing;
    return switch (attr) {
        http.HTTP_Status => if (answered) own.head.status else 0,
        http.HTTP_StatusLine => @intFromPtr(if (answered) own.head.status_line else ""),
        http.HTTP_ContentLength => length: {
            if (!answered or own.unzipping()) break :length http.HTTP_LENGTH_UNKNOWN;
            const count = own.head.content_length orelse break :length http.HTTP_LENGTH_UNKNOWN;
            if (count >= http.HTTP_LENGTH_UNKNOWN) break :length http.HTTP_LENGTH_UNKNOWN;
            break :length @intCast(count);
        },
        http.HTTP_URL => @intFromPtr(&own.url),
        http.HTTP_Reused => @intFromBool(own.reused),
        http.HTTP_Secure => @intFromBool(own.secure),
        http.HTTP_Error => @bitCast(@as(isize, own.last_error)),
        http.HTTP_Verdict => own.verdict,
        http.HTTP_Unzipping => @intFromBool(own.unzipping()),
        else => 0,
    };
}
