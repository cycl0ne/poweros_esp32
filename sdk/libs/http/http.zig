// SPDX-License-Identifier: MIT
//! http.library's structures and constants: the client a program makes
//! its requests through, the tags a client and a request take, the
//! attributes a request answers, and the error codes. The calls are in
//! `sdk.interface.http`.
//!
//! **A client is the program's**: it holds the program's bsdsocket.library
//! base, its settings - whether servers' certificates are checked, how it
//! names itself, how long a quiet connection is waited for - and the
//! connections its requests left open. A request over the same scheme,
//! host and port as one before it goes over that connection again, so a
//! program asking one server several things pays for one connection and
//! one TLS handshake.
//!
//! **A request** is HTTP/1.1, `http://` or `https://`: OpenRequest sends
//! it and reads the head of the answer, following redirects; the body is
//! then read with ReadRequest, decoded from its chunks and, with
//! HTTP_Unzip, unpacked; CloseRequest gives the connection back to the
//! client. A request whose body is not at hand in one piece - a file
//! being sent - is written with WriteRequest before the answer is read.
//! A Shoutcast server's answer, `ICY 200 OK`, is read as HTTP/1.0's: its
//! body runs to the connection's end.
//!
//! A client and its requests are one task's at a time, as the socket
//! base they use is.

const utility = @import("../utility/utility.zig");

/// The library's name, for OpenLibrary.
pub const HTTPNAME = "http.library";

/// A client: what CreateClient makes. Only http.library knows what is in
/// it.
pub const Client = opaque {};

/// A request and its answer: what OpenRequest makes.
pub const Request = opaque {};

// --- tags ---------------------------------------------------------------------

pub const HTTP_Dummy = utility.TAG_USER + 0x60A00;

// CreateClient's tags.

/// Bool: the servers' certificates are checked (true). False only for a
/// test server of one's own, never for anything that matters.
pub const HTTP_Verify = HTTP_Dummy + 0x01;
/// `[*:0]const u8`: the User-Agent the requests send; the library's own
/// name and version unless given.
pub const HTTP_UserAgent = HTTP_Dummy + 0x02;
/// u32: how many seconds a connection may stay quiet - while connecting,
/// sending or waiting for the answer - before the request fails with
/// HTTPERR_IO (and bsdsocket's Errno EWOULDBLOCK). 0, the default, waits
/// for as long as it takes; Ctrl-C ends a wait either way.
pub const HTTP_Timeout = HTTP_Dummy + 0x03;

// OpenRequest's tags.

/// `[*:0]const u8`: a header line of the request's own, `Name: value`,
/// without its line end. Given as often as there are headers.
pub const HTTP_Header = HTTP_Dummy + 0x10;
/// `*const anyopaque`: the request's body, HTTP_BodyLength bytes, sent
/// with its head.
pub const HTTP_Body = HTTP_Dummy + 0x11;
/// u32: the body's length. Without HTTP_Body the body is the program's to
/// write with WriteRequest, this many bytes.
pub const HTTP_BodyLength = HTTP_Dummy + 0x12;
/// Bool: the body is written with WriteRequest, of a length not known in
/// advance, and sent in chunks.
pub const HTTP_Chunked = HTTP_Dummy + 0x13;
/// `[*:0]const u8`: a user name and its password, sent as Basic
/// authorization. A token goes as the password.
pub const HTTP_User = HTTP_Dummy + 0x14;
pub const HTTP_Password = HTTP_Dummy + 0x15;
/// u32: the most redirects followed; 5 unless given, 0 for none - the
/// redirect is then the answer.
pub const HTTP_Redirects = HTTP_Dummy + 0x16;
/// Bool: the server may send the body packed (gzip or deflate), and
/// ReadRequest unpacks it. Needs compression.library.
pub const HTTP_Unzip = HTTP_Dummy + 0x17;
/// `*i32`: where OpenRequest puts the TLSERR_* a failed TLS session
/// ended with, when it fails with HTTPERR_TLS.
pub const HTTP_GetTLSError = HTTP_Dummy + 0x18;
/// `*u32`: where OpenRequest puts the certificate check's TLSV_*.
pub const HTTP_GetVerdict = HTTP_Dummy + 0x19;
/// `*u32`: where OpenRequest puts the alert a server refused the session
/// with, or 0.
pub const HTTP_GetAlert = HTTP_Dummy + 0x1A;

// GetRequestAttr's attributes.

/// The answer's status, 200 for OK; 0 while the body is being written.
pub const HTTP_Status = HTTP_Dummy + 0x20;
/// `[*:0]const u8`: the answer's status line, `HTTP/1.1 404 Not Found`,
/// or a Shoutcast server's `ICY 200 OK`.
pub const HTTP_StatusLine = HTTP_Dummy + 0x21;
/// The body's length as the answer gives it, or HTTP_LENGTH_UNKNOWN: an
/// answer in chunks, one that ends where the connection does, or one
/// being unpacked.
pub const HTTP_ContentLength = HTTP_Dummy + 0x22;
/// `[*:0]const u8`: the URL that answered, after the redirects.
pub const HTTP_URL = HTTP_Dummy + 0x23;
/// Bool: the request went over a connection an earlier request had made.
pub const HTTP_Reused = HTTP_Dummy + 0x24;
/// Bool: the request went over TLS.
pub const HTTP_Secure = HTTP_Dummy + 0x25;
/// The request's last HTTPERR_*.
pub const HTTP_Error = HTTP_Dummy + 0x26;
/// The certificate check's TLSV_*, over TLS.
pub const HTTP_Verdict = HTTP_Dummy + 0x27;
/// Bool: the body is being unpacked.
pub const HTTP_Unzipping = HTTP_Dummy + 0x28;

/// HTTP_ContentLength when the answer does not say.
pub const HTTP_LENGTH_UNKNOWN: usize = ~@as(usize, 0);

// --- errors -------------------------------------------------------------------

/// What OpenRequest puts where `err` points, and what ReadRequest and
/// WriteRequest answer below zero.
pub const HTTPERR_OK: i32 = 0;
/// No memory for the client, the request or a connection.
pub const HTTPERR_NOMEM: i32 = -1;
/// The connection failed, or could not be made: bsdsocket's Errno says
/// how - EINTR when Ctrl-C ended a wait.
pub const HTTPERR_IO: i32 = -2;
/// Not an `http://` or `https://` URL, or one too long.
pub const HTTPERR_URL: i32 = -3;
/// The host's name has no address.
pub const HTTPERR_HOST: i32 = -4;
/// The TLS session failed: HTTP_GetTLSError's TLSERR_* says how,
/// HTTP_GetVerdict and HTTP_GetAlert why.
pub const HTTPERR_TLS: i32 = -5;
/// The answer is not HTTP: no status line - `HTTP/1.x` or `ICY` - a head
/// too long, chunks that make no sense.
pub const HTTPERR_PROTOCOL: i32 = -6;
/// More redirects than HTTP_Redirects allows, or one to nowhere.
pub const HTTPERR_REDIRECT: i32 = -7;
/// The connection ended before the body did.
pub const HTTPERR_TRUNCATED: i32 = -8;
/// A call out of its turn or that cannot be made: WriteRequest with no
/// body to write or past its length, ReadRequest before the body has
/// been ended, a method or header with a line end in it, a request's
/// head longer than 8 KiB, a client or request the library did not make.
pub const HTTPERR_STATE: i32 = -9;
/// tls.library or compression.library, needed for the request, is not
/// there.
pub const HTTPERR_LIBRARY: i32 = -10;
/// A body the server packed that does not unpack.
pub const HTTPERR_DATA: i32 = -11;
/// The server ended the connection without answering (SINCE 1.3): it
/// took the request and closed before the first byte of an answer.
pub const HTTPERR_CLOSED: i32 = -12;
