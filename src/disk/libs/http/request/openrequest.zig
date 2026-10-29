// SPDX-License-Identifier: MIT
//! OpenRequest: a request sent and the head of its answer read.

const sdk = @import("sdk");
const http = sdk.http;
const utility = sdk.utility;
const HttpBase = @import("../http_base.zig").HttpBase;
const _client = @import("../client/_client.zig");
const _connection = @import("../connection/_connection.zig");
const _request = @import("_request.zig");

/// Sends a request to a URL and reads the head of its answer, following
/// redirects.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenRequest(base: *HttpBase, client: *http.Client, method: [*:0]const u8, url: [*:0]const u8, tags: ?[*]const utility.TagItem, err: ?*i32) ?*http.Request
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `client`: from CreateClient.
/// - `method`: `GET`, `POST`, `HEAD`, `PUT`, ... - at most 15 characters.
/// - `url`: `http://host[:port][/path][?query]` or `https://...`, the host
///   a name, an IPv4 address or an IPv6 one in brackets; at most 2048
///   characters. A `#fragment` is not sent.
/// - `tags`:
///   - HTTP_Header (`[*:0]const u8`, as often as needed): a header line
///     of the program's own, `Name: value`.
///   - HTTP_Body (`*const anyopaque`) and HTTP_BodyLength (u32): a body
///     in memory, sent with the head.
///   - HTTP_BodyLength alone: a body of that many bytes the program
///     writes with WriteRequest.
///   - HTTP_Chunked (bool, false): a body the program writes with
///     WriteRequest, of a length not known in advance.
///   - HTTP_User and HTTP_Password (`[*:0]const u8`): Basic
///     authorization, at most 2047 characters the two together; a token
///     goes as the password.
///   - HTTP_Redirects (u32, 5): the most redirects followed; 0 makes a
///     redirect the answer.
///   - HTTP_Unzip (bool, false): the server may pack the body, and
///     ReadRequest unpacks it.
///   - HTTP_GetTLSError (`*i32`), HTTP_GetVerdict (`*u32`), HTTP_GetAlert
///     (`*u32`): where the TLS session's TLSERR_*, its certificate
///     check's TLSV_* and the alert a server refused with go.
/// - `err`: where the outcome goes (HTTPERR_*), or null.
///
/// RESULT:
/// The request, its answer's head read - or, with a body the program
/// writes, its own head sent - and `err` HTTPERR_OK. Null, with `err`:
/// HTTPERR_URL for a URL that is none, HTTPERR_HOST for a host without
/// an address, HTTPERR_IO when no connection could be made or it failed,
/// HTTPERR_TLS when the TLS session could not be had, HTTPERR_CLOSED
/// when the server closed without answering, HTTPERR_PROTOCOL for an
/// answer that is not HTTP, HTTPERR_TRUNCATED for one cut short,
/// HTTPERR_REDIRECT for too many redirects or one to nowhere,
/// HTTPERR_STATE for a method or header that is none, credentials too
/// long, or a request head longer than 8 KiB, HTTPERR_LIBRARY without tls.library for
/// `https://` or compression.library for HTTP_Unzip, HTTPERR_DATA for a
/// packed answer that does not start as one, HTTPERR_NOMEM.
///
/// An answer is an answer whatever its status: a 404 or a 500 is a
/// request whose HTTP_Status says so.
///
/// BEHAVIOR:
/// The request goes as HTTP/1.1 over a connection the client kept to the
/// same scheme, host and port, or a new one - over TLS for `https://`,
/// asking for `http/1.1`. Its head carries Host, User-Agent, the Basic
/// authorization, `Accept-Encoding: gzip, deflate` with HTTP_Unzip, the
/// program's headers, and the body's Content-Length - or
/// `Transfer-Encoding: chunked` for HTTP_Chunked. A POST, PUT or PATCH
/// without a body says its length is 0.
///
/// A kept connection that fails before any of the answer has come is
/// given up and the request sent again on a new one: a server may close
/// a connection it has been idle on at any time. A body the program
/// writes always goes over a new connection.
///
/// The answer's status line is `HTTP/1.x`'s, or a Shoutcast server's
/// `ICY 200 OK`, which is read as HTTP/1.0's: the connection is not kept,
/// and the body - the stream - runs to its end.
///
/// Interim answers (100 Continue) are read past. A redirect - 301, 302,
/// 303, 307 or 308 with a Location - is followed when the request's body
/// is not the program's to write: its body read and dropped, and the
/// request sent to where it leads. 303 asks with GET, and 301 and 302
/// turn a POST into a GET, both without the body; 307 and 308 keep the
/// method and the body. A redirect to another scheme, host or port goes
/// without HTTP_User's authorization and without the program's
/// Authorization and Cookie headers.
///
/// CONTEXT:
/// - Waits: yes, for the server, as long as HTTP_Timeout allows; Ctrl-C
///   ends a wait with HTTPERR_IO.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: yes, the one that opened the client's socket base - the
///   host is looked up, and tls.library reads its certificate stores.
///
/// OWNERSHIP:
/// The request is the caller's until CloseRequest. The strings, the
/// header lines and an in-memory body need only last for the call.
///
/// NOTES:
/// A request takes some 14 KiB, and 8 KiB more with HTTP_Unzip; a TLS
/// connection some 75 KiB more. The answer's head is read into the
/// request's 8 KiB: one longer fails with HTTPERR_PROTOCOL.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadRequest`, `WriteRequest`, `GetRequestAttr`, `GetHeader`,
/// `CloseRequest`, `CreateClient`
///
/// EXAMPLES:
/// ```zig
/// var err: i32 = 0;
/// const request = hb.OpenRequest(client, "GET", "https://example.org/", &[_]utility.TagItem{
///     .{ .tag = http.HTTP_Header, .data = @intFromPtr("Accept: text/html") },
///     .{ .tag = http.HTTP_Unzip, .data = 1 },
///     .{},
/// }, &err) orelse return err;
/// defer hb.CloseRequest(request);
/// if (hb.GetRequestAttr(request, http.HTTP_Status) != 200) return;
/// ```
pub fn OpenRequest(base: *HttpBase, client: *http.Client, method: [*:0]const u8, url: [*:0]const u8, tags: ?[*]const utility.TagItem, err: ?*i32) ?*http.Request {
    const ub = base.utility_base;
    var failure: _connection.Failure = .{};
    defer if (err) |out| {
        out.* = failure.code;
    };
    const own = _client.of(client) orelse {
        failure.code = http.HTTPERR_STATE;
        return null;
    };
    var settings: _request.Settings = .{
        .tags = tags,
        .user = optionalText(ub.GetTagData(http.HTTP_User, 0, tags)),
        .password = optionalText(ub.GetTagData(http.HTTP_Password, 0, tags)),
        .redirects = @intCast(ub.GetTagData(http.HTTP_Redirects, _request.redirects_default, tags)),
        .unzip = ub.GetTagData(http.HTTP_Unzip, 0, tags) != 0,
    };
    const body_length = ub.GetTagData(http.HTTP_BodyLength, 0, tags);
    const body = ub.GetTagData(http.HTTP_Body, 0, tags);
    if (body != 0) {
        const bytes: [*]const u8 = @ptrFromInt(body);
        settings.body = bytes[0..body_length];
    } else if (ub.GetTagData(http.HTTP_Chunked, 0, tags) != 0) {
        settings.streamed = true;
        settings.chunked = true;
    } else if (ub.FindTagItem(http.HTTP_BodyLength, tags) != null) {
        settings.streamed = true;
        settings.streamed_length = body_length;
    }

    const request = _request.open(own, method, url, settings, &failure);
    if (request) |made| failure.verdict = made.verdict;
    tellFailure(base, tags, failure);
    const made = request orelse return null;
    return _request.handleOf(made);
}

fn optionalText(data: usize) ?[*:0]const u8 {
    return if (data == 0) null else @ptrFromInt(data);
}

/// HTTP_GetTLSError, HTTP_GetVerdict and HTTP_GetAlert filled in.
fn tellFailure(base: *HttpBase, tags: ?[*]const utility.TagItem, failure: _connection.Failure) void {
    const ub = base.utility_base;
    const tls_error = ub.GetTagData(http.HTTP_GetTLSError, 0, tags);
    if (tls_error != 0) @as(*i32, @ptrFromInt(tls_error)).* = failure.tls_error;
    const verdict = ub.GetTagData(http.HTTP_GetVerdict, 0, tags);
    if (verdict != 0) @as(*u32, @ptrFromInt(verdict)).* = failure.verdict;
    const alert = ub.GetTagData(http.HTTP_GetAlert, 0, tags);
    if (alert != 0) @as(*u32, @ptrFromInt(alert)).* = failure.alert;
}
