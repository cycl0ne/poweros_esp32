// SPDX-License-Identifier: MIT
//! Fault: what an HTTPERR_* means, in words - with the details of the
//! client's last failure when it was that one.
//!
//! The words are `http.cd`'s, read through `sdk.locale.Strings` from the
//! catalog `sys/http.catalog` in the language the user prefers, opened
//! for the call and closed after it: a failure is said once, and the
//! language may have changed since the last.

const sdk = @import("sdk");
const http = sdk.http;
const tls = sdk.tls;
const bsd = sdk.bsdsocket;
const HttpBase = @import("../http_base.zig").HttpBase;
const _client = @import("_client.zig");
const Failure = @import("../connection/_connection.zig").Failure;
const strings = @import("http_strings");
const Text = sdk.locale.Strings(strings);
const Id = strings.Id;

/// Puts what an http.library error means into a buffer, in the user's
/// language: for the client's last failure, with what it knows of it.
///
/// SYNOPSIS:
/// ```zig
/// fn Fault(base: *HttpBase, client: ?*http.Client, code: i32, header: ?[*:0]const u8, buffer: [*]u8, length: u32) i32
/// ```
///
/// SINCE: 1.4. LVO -52.
///
/// INPUTS:
/// - `client`: the client the request was made through, or null for
///   the code's words alone.
/// - `code`: an HTTPERR_*, as OpenRequest put it into `err` or
///   ReadRequest or WriteRequest answered it.
/// - `header`: put before the words with ": " after it, such as the
///   program's name; null for none.
/// - `buffer`: where the words go.
/// - `length`: the buffer's size in bytes, the NUL included.
///
/// RESULT:
/// The length of what was put into the buffer, the NUL not counted. 0
/// for HTTPERR_OK or a `length` of 0.
///
/// BEHAVIOR:
/// The words are a clause without its full stop, in lower case:
/// `the host has no address`, or `HttpGet: the host has no address`
/// with a header. When `code` is the client's last failure - the last
/// OpenRequest, ReadRequest or WriteRequest of the client's that failed
/// - they say what the client kept of it:
///
/// - HTTPERR_IO: bsdsocket's words for its Errno (`the connection
///   failed: Connection refused`); `stopped` when Ctrl-C ended the wait,
///   and `the server did not answer in time` when HTTP_Timeout did.
/// - HTTPERR_HOST: the host's name (`example.org has no address`).
/// - HTTPERR_TLS: why the certificate was not trusted (`the server's
///   certificate is not trusted: it has expired`), that the clock is not
///   set, the alert the server refused with, or that the handshake failed.
/// - HTTPERR_LIBRARY: the library's name (`tls.library is not there`).
///
/// For another client's code, or a code the client did not fail with
/// last, they are the code's alone. A code that is no HTTPERR_* gives
/// `the request failed (<code>)`. The whole is cut to `length - 1` bytes
/// and ended with a NUL.
///
/// The words are those of `sys/http.catalog` in the language the locale
/// prefers, where locale.library and a catalog are there, and English
/// otherwise; bsdsocket's words for an Errno are its own.
///
/// CONTEXT:
/// - Waits: yes, while locale.library and the catalog are opened.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: yes, the one that opened the client's socket base: the
///   catalog is a file, and an Errno's words come from that base.
///
/// OWNERSHIP:
/// The buffer is the caller's. Nothing is kept.
///
/// NOTES:
/// A request that fails tells the client at once; any of its calls after
/// that, failing too, puts its own failure there instead. Ask for the
/// words before the next request.
///
/// A program that answers Ctrl-C with a return code of its own still
/// checks bsdsocket's Errno for EINTR itself: Fault only says it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenRequest`, `ReadRequest`, `WriteRequest`, dos.library `Fault`
///
/// EXAMPLES:
/// ```zig
/// var err: i32 = 0;
/// const request = hb.OpenRequest(client, "GET", url, null, &err) orelse {
///     var why: [256]u8 = undefined;
///     _ = hb.Fault(client, err, "HttpGet", &why, why.len);
///     _ = dos.Printf(dl, "%s\n", .{@as([*:0]const u8, @ptrCast(&why))});
///     return dos.RETURN_ERROR;
/// };
/// ```
pub fn Fault(base: *HttpBase, client: ?*http.Client, code: i32, header: ?[*:0]const u8, buffer: [*]u8, length: u32) i32 {
    if (length == 0) return 0;
    const into = buffer[0..length];
    into[0] = 0;
    if (code == http.HTTPERR_OK) return 0;

    // The header and its ": ", as much of them as leaves room for the NUL.
    var at: usize = 0;
    if (header) |name| {
        var index: usize = 0;
        while (name[index] != 0 and at + 1 < into.len) : (index += 1) {
            into[at] = name[index];
            at += 1;
        }
        for (": ") |char| {
            if (at + 1 == into.len) break;
            into[at] = char;
            at += 1;
        }
        into[at] = 0;
    }

    var known: ?*const Failure = null;
    var own: ?*_client.Client = null;
    if (client) |handle| {
        own = _client.of(handle);
        if (own) |kept| {
            if (kept.last.code == code) known = &kept.last;
        }
    }

    var text = Text.open(base.sys_base);
    defer text.close();
    const words = say(&text, into[at..], code, known, own);
    return @intCast(at + words.len);
}

/// The words for `code` into `into`, with what `known` kept of it.
fn say(text: *const Text, into: []u8, code: i32, known: ?*const Failure, client: ?*_client.Client) [:0]const u8 {
    return switch (code) {
        http.HTTPERR_NOMEM => text.format(into, .MSG_NOMEM, .{}),
        http.HTTPERR_IO => io(text, into, known, client),
        http.HTTPERR_URL => text.format(into, .MSG_URL, .{}),
        http.HTTPERR_HOST => if (known) |failure| (if (failure.host_length != 0)
            text.format(into, .MSG_HOST_NAMED, .{@as([*:0]const u8, @ptrCast(&failure.host))})
        else
            text.format(into, .MSG_HOST, .{})) else text.format(into, .MSG_HOST, .{}),
        http.HTTPERR_TLS => secure(text, into, known),
        http.HTTPERR_PROTOCOL => text.format(into, .MSG_PROTOCOL, .{}),
        http.HTTPERR_REDIRECT => text.format(into, .MSG_REDIRECT, .{}),
        http.HTTPERR_TRUNCATED => text.format(into, .MSG_TRUNCATED, .{}),
        http.HTTPERR_STATE => text.format(into, .MSG_STATE, .{}),
        http.HTTPERR_LIBRARY => if (known) |failure| (if (failure.library) |name|
            text.format(into, .MSG_LIBRARY_NAMED, .{name})
        else
            text.format(into, .MSG_LIBRARY, .{})) else text.format(into, .MSG_LIBRARY, .{}),
        http.HTTPERR_DATA => text.format(into, .MSG_DATA, .{}),
        http.HTTPERR_CLOSED => text.format(into, .MSG_CLOSED, .{}),
        else => text.format(into, .MSG_UNKNOWN, .{code}),
    };
}

/// HTTPERR_IO, by the Errno the socket call left.
fn io(text: *const Text, into: []u8, known: ?*const Failure, client: ?*_client.Client) [:0]const u8 {
    const failure = known orelse return text.format(into, .MSG_IO, .{});
    return switch (failure.errno) {
        0 => text.format(into, .MSG_IO, .{}),
        bsd.EINTR => text.format(into, .MSG_STOPPED, .{}),
        bsd.EWOULDBLOCK => text.format(into, .MSG_TIMEOUT, .{}),
        else => text.format(into, .MSG_IO_BECAUSE, .{bsd.errnoText(client.?.socket_base, failure.errno)}),
    };
}

/// HTTPERR_TLS, by the session's TLSERR_*.
fn secure(text: *const Text, into: []u8, known: ?*const Failure) [:0]const u8 {
    const failure = known orelse return text.format(into, .MSG_TLS, .{});
    return switch (failure.tls_error) {
        tls.TLSERR_CERTIFICATE => text.format(into, .MSG_TLS_CERTIFICATE, .{text.get(verdictOf(failure.verdict))}),
        tls.TLSERR_CLOCK => text.format(into, .MSG_TLS_CLOCK, .{}),
        tls.TLSERR_ALERT => text.format(into, .MSG_TLS_ALERT, .{failure.alert}),
        tls.TLSERR_HANDSHAKE => text.format(into, .MSG_TLS_HANDSHAKE, .{}),
        tls.TLSERR_NOMEM => text.format(into, .MSG_NOMEM, .{}),
        else => text.format(into, .MSG_TLS, .{}),
    };
}

/// The words for a certificate check's TLSV_*.
fn verdictOf(verdict: u32) Id {
    return switch (verdict) {
        tls.TLSV_MALFORMED => .MSG_VERDICT_MALFORMED,
        tls.TLSV_UNKNOWN_ISSUER => .MSG_VERDICT_UNKNOWN_ISSUER,
        tls.TLSV_BAD_SIGNATURE => .MSG_VERDICT_BAD_SIGNATURE,
        tls.TLSV_UNSUPPORTED => .MSG_VERDICT_UNSUPPORTED,
        tls.TLSV_EXPIRED => .MSG_VERDICT_EXPIRED,
        tls.TLSV_NOT_YET_VALID => .MSG_VERDICT_NOT_YET_VALID,
        tls.TLSV_NOT_CA => .MSG_VERDICT_NOT_CA,
        tls.TLSV_PATH_LENGTH => .MSG_VERDICT_PATH_LENGTH,
        tls.TLSV_NAME_CONSTRAINTS => .MSG_VERDICT_NAME_CONSTRAINTS,
        tls.TLSV_WRONG_USAGE => .MSG_VERDICT_WRONG_USAGE,
        tls.TLSV_WRONG_NAME => .MSG_VERDICT_WRONG_NAME,
        tls.TLSV_TOO_LONG => .MSG_VERDICT_TOO_LONG,
        else => .MSG_VERDICT_OTHER,
    };
}
