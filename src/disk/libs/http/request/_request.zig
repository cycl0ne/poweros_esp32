// SPDX-License-Identifier: MIT
//! A request and its answer as they go back and forth: the request's head
//! written and sent with its body, the answer's head read, redirects
//! followed, and the body handed over as it comes.
//!
//! **One buffer** carries the request's head out and then the answer's
//! head in, read in place (`_protocol.parseHead`), so the status line and
//! the headers' values stay there as strings for as long as the request
//! lives. Bytes of the body that came with the head wait behind it and are
//! handed over first; the rest goes from the connection straight into the
//! program's buffer, decoded from its chunks there.
//!
//! **A body ends** where its length says, at its last chunk, or where the
//! server closes; an answer to HEAD, a 204 and a 304 have none. Only an
//! answer read to its end, whose server keeps the connection, gives the
//! connection back to the client.
//!
//! **A redirect** to another server - another scheme, host or port - goes
//! there without the request's credentials: neither HTTP_User's Basic
//! authorization nor a header of the program's that names Authorization
//! or Cookie. A body the program writes goes over a fresh connection: a
//! kept one the server has let go of is found out only by writing to it,
//! and that body cannot be sent again.
//!
//! **Unpacking** (HTTP_Unzip) puts compression.library between the two:
//! the body's bytes go into a buffer of their own and Inflate writes into
//! the program's.
//!
//! The request is far larger than a stack: it is filled in place on
//! cleared memory, field by field.

const sdk = @import("sdk");
const exec = sdk.exec;
const http = sdk.http;
const tls = sdk.tls;
const compression = sdk.compression;
const utility = sdk.utility;
const CompressionBase = sdk.interface.compression.CompressionBase;
const _base = @import("../http_base.zig");
const _client = @import("../client/_client.zig");
const _connection = @import("../connection/_connection.zig");
const _protocol = @import("../protocol/_protocol.zig");
const Client = _client.Client;
const Connection = _connection.Connection;
const Failure = _connection.Failure;
const Url = _protocol.Url;
const Head = _protocol.Head;
const Writer = _protocol.Writer;

/// What a request is checked by when a program hands one back.
const MAGIC: u32 = 0x48545452;

/// The request's head out, then the answer's head in.
pub const buffer_bytes = 8192;
/// The longest URL, redirects' included.
pub const url_most = 2048;
/// The longest method.
pub const method_most = 15;
/// The most redirects followed unless HTTP_Redirects says.
pub const redirects_default = 5;
/// The packed body's bytes, waiting to be unpacked.
const raw_bytes = 8192;
/// How much of a redirect's body is read and dropped to keep its
/// connection; one longer is closed instead.
const discard_most = 64 * 1024;

pub const Phase = enum(u8) {
    /// The program is writing the body: the answer is not read yet.
    writing,
    /// The answer's head is read; its body is being read.
    reading,
    /// Something failed: the connection is not used again.
    broken,
};

/// How the answer's body ends.
const Framing = enum(u8) { none, length, chunked, close };

/// What a request is asked to do, from OpenRequest's tags.
pub const Settings = struct {
    /// Every tag, for the HTTP_Header ones.
    tags: ?[*]const utility.TagItem = null,
    /// The body in memory, sent with the head.
    body: ?[]const u8 = null,
    /// The body is the program's to write: this many bytes, or in chunks.
    streamed: bool = false,
    chunked: bool = false,
    streamed_length: u64 = 0,
    user: ?[*:0]const u8 = null,
    password: ?[*:0]const u8 = null,
    redirects: u32 = redirects_default,
    unzip: bool = false,
};

/// The unpacking of a packed answer.
pub const Unzip = struct {
    cb: *CompressionBase,
    stream: compression.Stream,
    started: bool,
    /// The packed stream has ended, and with it what the program reads.
    ended: bool,
    /// The connection has no more of the body.
    raw_ended: bool,
    raw: [raw_bytes]u8,
};

pub const Request = struct {
    magic: u32,
    client: *Client,
    connection: ?*Connection,
    phase: Phase,
    /// The connection was kept from an earlier request.
    reused: bool,
    secure: bool,
    /// The program asked for HTTP_Unzip.
    want_unzip: bool,
    /// Some of the answer has come.
    answered: bool,
    /// A redirect has led to another server than the one first asked.
    foreign: bool,
    last_error: i32,
    verdict: u32,
    method_length: u8,
    /// NUL-terminated.
    method: [method_most + 1]u8,
    url_length: u16,
    /// The URL being asked, NUL-terminated: HTTP_URL.
    url: [url_most + 1]u8,
    /// Where a redirect leads, worked out before `url` is let go of.
    next_url: [url_most + 1]u8,
    /// The body the program writes: whether in chunks, and what of its
    /// length is still to come.
    write_chunked: bool,
    write_left: u64,
    head: Head,
    framing: Framing,
    /// What of the body's length is still to come.
    body_left: u64,
    chunked: _protocol.Chunked,
    body_ended: bool,
    /// The body's bytes that came with the head: `buffer[taken..filled]`.
    filled: usize,
    taken: usize,
    unzip: ?*Unzip,
    buffer: [buffer_bytes]u8,

    fn sys(request: *Request) *sdk.interface.exec.ExecBase {
        return request.client.base.sys_base;
    }

    fn methodText(request: *const Request) []const u8 {
        return request.method[0..request.method_length];
    }

    /// Whether ReadRequest unpacks the body.
    pub fn unzipping(request: *const Request) bool {
        const unzip = request.unzip orelse return false;
        return unzip.started;
    }
};

/// The request behind a program's handle; null for one not made here.
pub fn of(handle: *http.Request) ?*Request {
    const request: *Request = @ptrCast(@alignCast(handle));
    return if (request.magic == MAGIC) request else null;
}

pub fn handleOf(request: *Request) *http.Request {
    return @ptrCast(request);
}

fn length(text: [*:0]const u8) usize {
    var count: usize = 0;
    while (text[count] != 0) count += 1;
    return count;
}

/// `text` is fit for a request's head: no line ends, nothing below a
/// blank but a tab.
fn clean(text: []const u8) bool {
    for (text) |char| {
        if (char < ' ' and char != '\t') return false;
        if (char == 0x7F) return false;
    }
    return true;
}

/// `method` sent to `url_text` as `settings` say and its answer's head
/// read, redirects followed; null, with why in `failure`, when it failed.
pub fn open(client: *Client, method: [*:0]const u8, url_text: [*:0]const u8, settings: Settings, failure: *Failure) ?*Request {
    const base = client.base;
    const sys = base.sys_base;
    const method_length = length(method);
    if (method_length == 0 or method_length > method_most) {
        failure.code = http.HTTPERR_STATE;
        return null;
    }
    for (method[0..method_length]) |char| {
        if (char <= ' ' or char >= 0x7F) {
            failure.code = http.HTTPERR_STATE;
            return null;
        }
    }
    const url_length = length(url_text);
    if (url_length > url_most) {
        failure.code = http.HTTPERR_URL;
        return null;
    }
    if (settings.user) |user| {
        if (length(user) + 1 + length(settings.password orelse "") > url_most) {
            failure.code = http.HTTPERR_STATE;
            return null;
        }
    }
    // A header line with a line end in it would be two; refused before
    // anything is sent.
    var walk = settings.tags;
    while (base.utility_base.NextTagItem(&walk)) |item| {
        if (item.tag != http.HTTP_Header) continue;
        const line: [*:0]const u8 = @ptrFromInt(item.data);
        if (!clean(line[0..length(line)])) {
            failure.code = http.HTTPERR_STATE;
            return null;
        }
    }
    var cb: ?*CompressionBase = null;
    if (settings.unzip) {
        cb = _base.compressionOf(base) orelse {
            failure.code = http.HTTPERR_LIBRARY;
            return null;
        };
    }

    const memory = sys.AllocVec(@sizeOf(Request), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        failure.code = http.HTTPERR_NOMEM;
        return null;
    };
    const request: *Request = @ptrCast(@alignCast(memory));
    request.magic = MAGIC;
    request.client = client;
    request.phase = .reading;
    request.want_unzip = settings.unzip;
    request.verdict = tls.TLSV_TRUSTED;
    request.head = .{};
    request.chunked = .{};
    request.method_length = @intCast(method_length);
    @memcpy(request.method[0..method_length], method[0..method_length]);
    request.url_length = @intCast(url_length);
    @memcpy(request.url[0..url_length], url_text[0..url_length]);
    if (cb) |library| {
        const unzip_memory = sys.AllocVec(@sizeOf(Unzip), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
            sys.FreeVec(memory);
            failure.code = http.HTTPERR_NOMEM;
            return null;
        };
        const unzip: *Unzip = @ptrCast(@alignCast(unzip_memory));
        unzip.cb = library;
        unzip.stream.size = @sizeOf(compression.Stream);
        request.unzip = unzip;
    }

    const code = run(request, settings, failure);
    if (code != http.HTTPERR_OK) {
        failure.code = code;
        close(request);
        return null;
    }
    return request;
}

/// The request sent, again for each redirect, and the answer's head read.
fn run(request: *Request, settings: Settings, failure: *Failure) i32 {
    var body = settings.body;
    var redirects_left = settings.redirects;
    while (true) {
        const url = _protocol.parseUrl(request.url[0..request.url_length]) orelse return http.HTTPERR_URL;
        request.secure = url.secure;
        const code = exchange(request, url, settings, body, failure);
        if (code != http.HTTPERR_OK) return code;
        if (settings.streamed) {
            request.phase = .writing;
            return http.HTTPERR_OK;
        }
        const status = request.head.status;
        const redirect = switch (status) {
            301, 302, 303, 307, 308 => true,
            else => false,
        };
        if (!redirect or settings.redirects == 0 or request.head.location == null) break;
        if (redirects_left == 0) return http.HTTPERR_REDIRECT;
        redirects_left -= 1;

        const location = request.head.location.?;
        const next_length = _protocol.resolve(url, location[0..length(location)], request.next_url[0..url_most]) orelse
            return http.HTTPERR_REDIRECT;
        // 303 asks for the answer with GET; 301 and 302 make a POST one
        // too, which is what servers mean by them. 307 and 308 keep the
        // method and the body.
        const method = request.methodText();
        const head_method = _protocol.same(method, "HEAD");
        if ((status == 303 and !head_method) or ((status == 301 or status == 302) and _protocol.same(method, "POST"))) {
            @memcpy(request.method[0..4], "GET\x00");
            request.method_length = 3;
            body = null;
        }
        discard(request);
        const next = _protocol.parseUrl(request.next_url[0..next_length]) orelse return http.HTTPERR_REDIRECT;
        if (next.secure != url.secure or next.port != url.port or !_protocol.same(next.host, url.host)) request.foreign = true;
        @memcpy(request.url[0..next_length], request.next_url[0..next_length]);
        request.url[next_length] = 0;
        request.url_length = @intCast(next_length);
    }
    return startUnzip(request);
}

/// The request over a kept connection to `url`'s server, or a fresh one,
/// its head and in-memory body sent, and - unless the program writes the
/// body - the answer's head read. A kept connection that fails before
/// any of the answer has come is given up and the request sent again on
/// a fresh one.
fn exchange(request: *Request, url: Url, settings: Settings, body: ?[]const u8, failure: *Failure) i32 {
    const client = request.client;
    var fresh_only = false;
    while (true) {
        var connection: *Connection = undefined;
        var reused = false;
        if (!fresh_only and !settings.streamed) {
            if (_client.take(client, url)) |kept| {
                connection = kept;
                reused = true;
            }
        }
        if (!reused) connection = client.connect(client, url, failure) orelse return failure.code;
        request.verdict = connection.verdict;
        request.connection = connection;
        request.reused = reused;
        request.answered = false;

        var code = sendHead(request, url, settings, body);
        if (code == http.HTTPERR_OK and settings.streamed) return http.HTTPERR_OK;
        if (code == http.HTTPERR_OK) code = readHead(request);
        if (code == http.HTTPERR_OK) return http.HTTPERR_OK;
        connection.close();
        request.connection = null;
        if (reused and !request.answered and code != http.HTTPERR_STATE) {
            fresh_only = true;
            continue;
        }
        return code;
    }
}

/// The request's head - and its body when that is in memory and fits
/// beside it - sent.
fn sendHead(request: *Request, url: Url, settings: Settings, body: ?[]const u8) i32 {
    const client = request.client;
    const ub = client.base.utility_base;
    const connection = request.connection.?;
    var writer: Writer = .{ .into = &request.buffer };
    writer.put(request.methodText());
    writer.put(" ");
    if (url.path[0] == '?') writer.put("/");
    writer.put(url.path);
    writer.put(" HTTP/1.1\r\nHost: ");
    writer.put(url.host);
    if (url.port != url.defaultPort()) {
        var digits: [8]u8 = undefined;
        writer.put(_protocol.portText(url.port, &digits));
    }
    writer.put("\r\nUser-Agent: ");
    writer.put(client.userAgent());
    writer.put("\r\n");
    if (if (request.foreign) null else settings.user) |user| {
        // `user:password`, joined where a redirect's URL is worked out:
        // free while a head is sent. open has seen that it fits.
        const password = settings.password orelse "";
        const user_length = length(user);
        const password_length = length(password);
        const credentials = request.next_url[0 .. user_length + 1 + password_length];
        @memcpy(credentials[0..user_length], user[0..user_length]);
        credentials[user_length] = ':';
        @memcpy(credentials[user_length + 1 ..], password[0..password_length]);
        writer.put("Authorization: Basic ");
        writer.base64(credentials);
        writer.put("\r\n");
    }
    if (request.want_unzip) writer.put("Accept-Encoding: gzip, deflate\r\n");
    var walk = settings.tags;
    while (ub.NextTagItem(&walk)) |item| {
        if (item.tag != http.HTTP_Header) continue;
        const line: [*:0]const u8 = @ptrFromInt(item.data);
        const text = line[0..length(line)];
        if (request.foreign and (_protocol.startsWith(text, "authorization:") or _protocol.startsWith(text, "cookie:"))) continue;
        writer.put(text);
        writer.put("\r\n");
    }
    if (body) |bytes| {
        writer.put("Content-Length: ");
        writer.decimal(bytes.len);
        writer.put("\r\n");
    } else if (settings.chunked) {
        writer.put("Transfer-Encoding: chunked\r\n");
    } else if (settings.streamed) {
        writer.put("Content-Length: ");
        writer.decimal(settings.streamed_length);
        writer.put("\r\n");
    } else if (_protocol.same(request.methodText(), "POST") or _protocol.same(request.methodText(), "PUT") or _protocol.same(request.methodText(), "PATCH")) {
        writer.put("Content-Length: 0\r\n");
    }
    writer.put("\r\n");
    if (writer.overflow) return http.HTTPERR_STATE;
    request.write_chunked = settings.chunked;
    request.write_left = settings.streamed_length;

    // A body that fits goes in the same send, so it does not wait behind
    // the head for an acknowledgement.
    const bytes = body orelse &.{};
    if (bytes.len <= request.buffer.len - writer.at) {
        writer.put(bytes);
        return connection.send(request.buffer[0..writer.at]);
    }
    const code = connection.send(request.buffer[0..writer.at]);
    if (code != http.HTTPERR_OK) return code;
    return connection.send(bytes);
}

/// The answer's head read into the buffer, past any 1xx answers before
/// it, and how its body ends worked out; the body's first bytes behind
/// it.
fn readHead(request: *Request) i32 {
    const connection = request.connection.?;
    request.filled = 0;
    request.taken = 0;
    while (true) {
        while (_protocol.headEnd(request.buffer[0..request.filled]) == null) {
            if (request.filled == request.buffer.len) return http.HTTPERR_PROTOCOL;
            const got = connection.receive(request.buffer[request.filled..]);
            if (got < 0) return got;
            if (got == 0) return if (request.filled == 0) http.HTTPERR_IO else http.HTTPERR_TRUNCATED;
            request.filled += @intCast(got);
            request.answered = true;
        }
        const head = _protocol.parseHead(request.buffer[0..request.filled]) orelse return http.HTTPERR_PROTOCOL;
        // An interim answer (100 Continue) says nothing of the request's
        // outcome: dropped, and the next read.
        if (head.status >= 100 and head.status < 200 and head.status != 101) {
            const rest = request.filled - head.body_at;
            var index: usize = 0;
            while (index < rest) : (index += 1) request.buffer[index] = request.buffer[head.body_at + index];
            request.filled = rest;
            continue;
        }
        request.head = head;
        request.taken = head.body_at;
        prepareBody(request);
        return http.HTTPERR_OK;
    }
}

/// How the body the head announces ends.
fn prepareBody(request: *Request) void {
    const head = request.head;
    request.chunked = .{};
    request.body_ended = false;
    request.body_left = 0;
    const status = head.status;
    if (_protocol.same(request.methodText(), "HEAD") or status == 204 or status == 304 or (status >= 100 and status < 200 and status != 101)) {
        request.framing = .none;
        request.body_ended = true;
    } else if (head.chunked) {
        request.framing = .chunked;
    } else if (head.content_length) |count| {
        request.framing = .length;
        request.body_left = count;
        request.body_ended = count == 0;
    } else {
        request.framing = .close;
    }
}

/// A redirect's body read and dropped, when it is short, so its
/// connection can be kept; the connection given back or closed.
fn discard(request: *Request) void {
    var dropped: usize = 0;
    var bin: [512]u8 = undefined;
    while (!request.body_ended and request.framing != .close and dropped < discard_most) {
        const got = readBody(request, &bin);
        if (got <= 0) break;
        dropped += @intCast(got);
    }
    release(request);
}

/// Inflate set up for a packed answer the program asked to have unpacked.
fn startUnzip(request: *Request) i32 {
    const unzip = request.unzip orelse return http.HTTPERR_OK;
    if (request.body_ended) return http.HTTPERR_OK;
    const format = switch (request.head.encoding) {
        .gzip => compression.FORMAT_GZIP,
        .deflate => compression.FORMAT_ZLIB,
        else => return http.HTTPERR_OK,
    };
    unzip.stream = .{};
    const result = unzip.cb.InitInflate(&unzip.stream, format);
    if (result == compression.COMPRESSERR_MEMORY) return http.HTTPERR_NOMEM;
    if (result != compression.COMPRESS_OK) return http.HTTPERR_DATA;
    unzip.started = true;
    unzip.ended = false;
    unzip.raw_ended = false;
    return http.HTTPERR_OK;
}

/// Bytes of the body as the connection carries it, its chunks undone,
/// into `into`: how many, 0 at its end, an HTTPERR_* below 0.
pub fn readBody(request: *Request, into: []u8) i32 {
    while (true) {
        if (request.framing == .chunked and request.chunked.failed) return http.HTTPERR_PROTOCOL;
        if (request.body_ended or into.len == 0) return 0;
        var room = into;
        if (request.framing == .length and room.len > request.body_left) room = room[0..@intCast(request.body_left)];
        var count: usize = 0;
        if (request.taken < request.filled) {
            count = @min(room.len, request.filled - request.taken);
            @memcpy(room[0..count], request.buffer[request.taken..][0..count]);
            request.taken += count;
        } else {
            const got = request.connection.?.receive(room);
            if (got < 0) return got;
            if (got == 0) {
                if (request.framing != .close) return http.HTTPERR_TRUNCATED;
                request.body_ended = true;
                return 0;
            }
            count = @intCast(got);
        }
        switch (request.framing) {
            .chunked => {
                // The data before a chunk that makes no sense is handed
                // over; the next read fails.
                const data = request.chunked.feed(room[0..count]);
                if (request.chunked.done) request.body_ended = true;
                if (data == 0) continue;
                return @intCast(data);
            },
            .length => {
                request.body_left -= count;
                if (request.body_left == 0) request.body_ended = true;
                return @intCast(count);
            },
            .close => return @intCast(count),
            .none => {
                request.body_ended = true;
                return 0;
            },
        }
    }
}

/// Bytes of the body as the program reads it: unpacked when it was
/// packed and the program asked. An error breaks the request.
pub fn read(request: *Request, into: []u8) i32 {
    if (request.phase == .broken) return request.last_error;
    if (request.phase != .reading) return http.HTTPERR_STATE;
    const got = readUnpacked(request, into);
    if (got < 0) return fail(request, got);
    return got;
}

fn readUnpacked(request: *Request, into: []u8) i32 {
    const unzip = request.unzip orelse return readBody(request, into);
    if (!unzip.started) return readBody(request, into);
    while (true) {
        if (unzip.ended or into.len == 0) return 0;
        if (unzip.stream.avail_in == 0 and !unzip.raw_ended) {
            const got = readBody(request, &unzip.raw);
            if (got < 0) return got;
            if (got == 0) {
                unzip.raw_ended = true;
            } else {
                unzip.stream.next_in = &unzip.raw;
                unzip.stream.avail_in = @intCast(got);
            }
        }
        const room: u32 = @intCast(@min(into.len, 0x7FFF_0000));
        unzip.stream.next_out = into.ptr;
        unzip.stream.avail_out = room;
        const result = unzip.cb.Inflate(&unzip.stream, if (unzip.raw_ended) compression.FLUSH_FINISH else compression.FLUSH_NONE);
        const made: i32 = @intCast(room - unzip.stream.avail_out);
        switch (result) {
            compression.COMPRESS_END => {
                unzip.ended = true;
                // What follows the packed stream in the body is nothing
                // the program asked for; read to the body's end so the
                // connection can be kept.
                var bin: [256]u8 = undefined;
                var dropped: usize = 0;
                while (!request.body_ended and dropped < discard_most) {
                    const got = readBody(request, &bin);
                    if (got <= 0) break;
                    dropped += @intCast(got);
                }
                return made;
            },
            compression.COMPRESS_OK => if (made > 0) return made,
            compression.COMPRESSERR_MEMORY => return http.HTTPERR_NOMEM,
            compression.COMPRESSERR_TRUNCATED => return http.HTTPERR_TRUNCATED,
            else => return http.HTTPERR_DATA,
        }
    }
}

/// `data` of the body the program writes sent, or with none the body
/// ended and the answer's head read: the status, `data.len`, or an
/// HTTPERR_*.
pub fn write(request: *Request, data: ?[]const u8) i32 {
    if (request.phase == .broken) return request.last_error;
    if (request.phase != .writing) return http.HTTPERR_STATE;
    const connection = request.connection.?;
    if (data) |bytes| {
        if (request.write_chunked) {
            // A chunk at a time through the buffer: its size, its bytes
            // and its line end in one send.
            var at: usize = 0;
            while (at < bytes.len) {
                const piece = @min(bytes.len - at, request.buffer.len - 16);
                var writer: Writer = .{ .into = &request.buffer };
                writer.hex(@intCast(piece));
                writer.put("\r\n");
                writer.put(bytes[at..][0..piece]);
                writer.put("\r\n");
                const code = connection.send(request.buffer[0..writer.at]);
                if (code != http.HTTPERR_OK) return fail(request, code);
                at += piece;
            }
        } else {
            if (bytes.len > request.write_left) return http.HTTPERR_STATE;
            const code = connection.send(bytes);
            if (code != http.HTTPERR_OK) return fail(request, code);
            request.write_left -= bytes.len;
        }
        return @intCast(bytes.len);
    }
    if (request.write_chunked) {
        const code = connection.send("0\r\n\r\n");
        if (code != http.HTTPERR_OK) return fail(request, code);
    } else if (request.write_left != 0) {
        return http.HTTPERR_STATE;
    }
    const code = readHead(request);
    if (code != http.HTTPERR_OK) return fail(request, code);
    request.phase = .reading;
    const unzip_code = startUnzip(request);
    if (unzip_code != http.HTTPERR_OK) return fail(request, unzip_code);
    return request.head.status;
}

/// `code` kept as the request's error, and the request broken.
pub fn fail(request: *Request, code: i32) i32 {
    request.last_error = code;
    request.phase = .broken;
    return code;
}

/// The connection given back to the client when the answer has been read
/// to its end and the server keeps it, else closed.
fn release(request: *Request) void {
    const connection = request.connection orelse return;
    request.connection = null;
    const keepable = request.phase == .reading and request.body_ended and !request.head.close and
        request.framing != .close and request.last_error == http.HTTPERR_OK;
    if (keepable) {
        _client.keep(request.client, connection);
    } else {
        connection.close();
    }
}

/// The request ended: its connection given back or closed, and its
/// memory freed.
pub fn close(request: *Request) void {
    const sys = request.sys();
    release(request);
    if (request.unzip) |unzip| {
        if (unzip.started) unzip.cb.EndInflate(&unzip.stream);
        sys.FreeVec(unzip);
    }
    request.magic = 0;
    sys.FreeVec(request);
}
