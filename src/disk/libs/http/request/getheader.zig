// SPDX-License-Identifier: MIT
//! GetHeader: a header of the answer, by its name.

const sdk = @import("sdk");
const http = sdk.http;
const HttpBase = @import("../http_base.zig").HttpBase;
const _request = @import("_request.zig");
const _protocol = @import("../protocol/_protocol.zig");

/// Finds a header of the answer by its name and answers its value.
///
/// SYNOPSIS:
/// ```zig
/// fn GetHeader(base: *HttpBase, request: *http.Request, name: [*:0]const u8) ?[*:0]const u8
/// ```
///
/// SINCE: 1.0. LVO -48.
///
/// INPUTS:
/// - `request`: from OpenRequest, its answer's head read.
/// - `name`: the header's name, without its colon; case does not matter.
///
/// RESULT:
/// The value, without the blanks round it; null when the answer has no
/// such header, while the body is still being written, or for a request
/// OpenRequest did not make.
///
/// BEHAVIOR:
/// Looks through the head of the answer as it came - the last answer,
/// after the redirects - for the first line of that name.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The value is the request's, there until CloseRequest.
///
/// NOTES:
/// Of a header given more than once (Set-Cookie) only the first is
/// answered.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetRequestAttr`, `OpenRequest`
///
/// EXAMPLES:
/// ```zig
/// const kind = hb.GetHeader(request, "Content-Type") orelse "application/octet-stream";
/// ```
pub fn GetHeader(_: *HttpBase, request: *http.Request, name: [*:0]const u8) ?[*:0]const u8 {
    const own = _request.of(request) orelse return null;
    if (own.phase == .writing) return null;
    var count: usize = 0;
    while (name[count] != 0) count += 1;
    return _protocol.findHeader(own.buffer[0..own.head.body_at], name[0..count]);
}
