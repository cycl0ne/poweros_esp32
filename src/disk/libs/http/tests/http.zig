// SPDX-License-Identifier: MIT
//! Host tests of http.library: HTTP's text on its own - URLs, redirects'
//! Locations, an answer's head, chunks cut at every byte - and the
//! library as a whole, made from its ROM tag on the ROM's exec and
//! utility.library and spoken to through its jump table, its requests
//! going to a server the tests stand up behind a connection of their
//! own. That server gives one scripted answer for each request sent to
//! it, in pieces as small as a byte, and closes where the script ends;
//! what the requests sent is read back from it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const http = sdk.http;
const utility = sdk.utility;
const compression = sdk.compression;
const ExecBase = sdk.interface.exec.ExecBase;
const HttpBase = sdk.interface.http.HttpBase;
const CompressionBase = sdk.interface.compression.CompressionBase;
const http_init = @import("../http_init.zig");
const compression_init = @import("../../compression/compression_init.zig");
const _client = @import("../client/_client.zig");
const _connection = @import("../connection/_connection.zig");
const _protocol = @import("../protocol/_protocol.zig");
const host = @import("host_rom");
const kexec = host.exec;
const Url = _protocol.Url;
const Head = _protocol.Head;

const testing = std.testing;

test {
    _ = @import("../http_lvo.zig");
}

// --- HTTP's text ----------------------------------------------------------------

test "URLs taken apart" {
    const plain = _protocol.parseUrl("http://example.org").?;
    try testing.expectEqualStrings("example.org", plain.host);
    try testing.expectEqual(@as(u16, 80), plain.port);
    try testing.expectEqualStrings("/", plain.path);
    const full = _protocol.parseUrl("HTTP://10.0.2.2:8000/dir/file.txt?a=1#top").?;
    try testing.expectEqualStrings("10.0.2.2", full.host);
    try testing.expectEqual(@as(u16, 8000), full.port);
    try testing.expectEqualStrings("/dir/file.txt?a=1", full.path);
    try testing.expect(_protocol.parseUrl("https://example.org/").?.secure);
    try testing.expectEqual(@as(u16, 443), _protocol.parseUrl("https://example.org/").?.port);
    try testing.expectEqualStrings("?q=1", _protocol.parseUrl("http://h?q=1").?.path);
    const six = _protocol.parseUrl("http://[fec0::2]:8080/x").?;
    try testing.expectEqualStrings("[fec0::2]", six.host);
    try testing.expectEqualStrings("fec0::2", six.hostName());
    try testing.expectEqual(@as(u16, 8080), six.port);
    try testing.expectEqual(@as(u16, 80), _protocol.parseUrl("http://[::1]/").?.port);
    for ([_][]const u8{ "ftp://x/", "http://", "http://:80/", "http://h:0/", "http://h:65536/", "http://h:8a/", "example.org", "http://[::1/", "http://[]/", "http://h/a b", "http://h/a\r\nX: y", "http://user@h/", "http://h\x01/" }) |text| {
        try testing.expectEqual(@as(?Url, null), _protocol.parseUrl(text));
    }
}

test "a redirect's Location made into a URL" {
    const base = _protocol.parseUrl("http://h:8000/a/b/c.html?q=1").?;
    var into: [128]u8 = undefined;
    const cases = [_][2][]const u8{
        .{ "http://other/x", "http://other/x" },
        .{ "//other/y", "http://other/y" },
        .{ "/root", "http://h:8000/root" },
        .{ "d.html", "http://h:8000/a/b/d.html" },
        .{ "../d", "http://h:8000/a/d" },
        .{ "./e?x=../y", "http://h:8000/a/b/e?x=../y" },
        .{ "/x/../../y", "http://h:8000/y" },
        .{ ".", "http://h:8000/a/b/" },
        .{ "..", "http://h:8000/a/" },
        .{ "../../../..", "http://h:8000/" },
        .{ "http://o/a/./b/../c?d", "http://o/a/c?d" },
        .{ "http://o?q", "http://o?q" },
    };
    for (cases) |case| {
        const length = _protocol.resolve(base, case[0], &into).?;
        try testing.expectEqualStrings(case[1], into[0..length]);
    }
    const secure = _protocol.parseUrl("https://h/").?;
    const length = _protocol.resolve(secure, "//other/z", &into).?;
    try testing.expectEqualStrings("https://other/z", into[0..length]);
    var small: [8]u8 = undefined;
    try testing.expectEqual(@as(?usize, null), _protocol.resolve(base, "/a-long-way", &small));
    try testing.expectEqual(@as(?usize, null), _protocol.resolve(base, "", &into));
}

test "the head of an answer, read in place" {
    var bytes = "HTTP/1.1 301 Moved Permanently\r\nContent-Length: 12\r\nLOCATION:  /there \r\nX: y\r\nContent-Encoding: gzip\r\n\r\nbody".*;
    try testing.expectEqual(@as(?usize, bytes.len - 4), _protocol.headEnd(&bytes));
    try testing.expectEqual(@as(?usize, null), _protocol.headEnd(bytes[0 .. bytes.len - 6]));
    const head = _protocol.parseHead(&bytes).?;
    try testing.expectEqual(@as(u16, 301), head.status);
    try testing.expectEqualStrings("HTTP/1.1 301 Moved Permanently", std.mem.span(head.status_line));
    try testing.expectEqual(@as(?u64, 12), head.content_length);
    try testing.expectEqualStrings("/there", std.mem.span(head.location.?));
    try testing.expectEqual(_protocol.Encoding.gzip, head.encoding);
    try testing.expect(!head.close);
    try testing.expectEqualStrings("body", bytes[head.body_at..]);
    const lines = bytes[0..head.body_at];
    try testing.expectEqualStrings("y", std.mem.span(_protocol.findHeader(lines, "x").?));
    try testing.expectEqualStrings("12", std.mem.span(_protocol.findHeader(lines, "CONTENT-length").?));
    try testing.expectEqualStrings("/there", std.mem.span(_protocol.findHeader(lines, "Location").?));
    try testing.expectEqual(@as(?[*:0]const u8, null), _protocol.findHeader(lines, "Set-Cookie"));

    var chunked_bytes = "HTTP/1.1 200 OK\nTransfer-Encoding: gzip, Chunked\nContent-Length: 5\nConnection: close\n\n".*;
    const chunked = _protocol.parseHead(&chunked_bytes).?;
    try testing.expect(chunked.chunked);
    try testing.expect(chunked.close);
    try testing.expectEqual(@as(?u64, null), chunked.content_length);

    var old_bytes = "HTTP/1.0 200 OK\r\n\r\n".*;
    try testing.expect(_protocol.parseHead(&old_bytes).?.close);
    var kept_bytes = "HTTP/1.0 200 OK\r\nConnection: Keep-Alive\r\n\r\n".*;
    try testing.expect(!_protocol.parseHead(&kept_bytes).?.close);

    for ([_][]const u8{ "SSH-2.0 x\r\n\r\n", "HTTP/1.1 2x0 OK\r\n\r\n", "HTTP/1.1 200OK\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n" }) |bad| {
        var copy: [64]u8 = undefined;
        @memcpy(copy[0..bad.len], bad);
        try testing.expectEqual(@as(?Head, null), _protocol.parseHead(copy[0..bad.len]));
    }
}

test "a chunked body decoded, cut at every byte" {
    const body = "4\r\nWiki\r\n6;name=x\r\npedia \r\nE\r\nin \r\n\r\nchunks.\r\n0\r\nTrailer: yes\r\n\r\nafter";
    const want = "Wikipedia in \r\n\r\nchunks.";
    var cut: usize = 0;
    while (cut <= body.len) : (cut += 1) {
        var copy: [body.len]u8 = body.*;
        var decoder: _protocol.Chunked = .{};
        var got: [64]u8 = undefined;
        var got_length: usize = 0;
        for ([_][]u8{ copy[0..cut], copy[cut..] }) |piece| {
            const count = decoder.feed(piece);
            @memcpy(got[got_length..][0..count], piece[0..count]);
            got_length += count;
        }
        try testing.expect(decoder.done);
        try testing.expect(!decoder.failed);
        try testing.expectEqualStrings(want, got[0..got_length]);
    }
    for ([_][]const u8{ "x\r\n", "4\r\nWikiX", "4\rX", "1234567890123456\r\n" }) |bad| {
        var copy: [32]u8 = undefined;
        @memcpy(copy[0..bad.len], bad);
        var decoder: _protocol.Chunked = .{};
        _ = decoder.feed(copy[0..bad.len]);
        try testing.expect(decoder.failed);
    }
}

test "base64 as Basic authorization sends it" {
    var into: [16]u8 = undefined;
    const cases = [_][2][]const u8{ .{ "u:p", "dTpw" }, .{ "ab", "YWI=" }, .{ "a", "YQ==" }, .{ "", "" }, .{ "user:pass", "dXNlcjpwYXNz" } };
    for (cases) |case| {
        const length = _protocol.base64Into(&into, case[0]);
        try testing.expectEqualStrings(case[1], into[0..length]);
        var writer: _protocol.Writer = .{ .into = &into };
        writer.base64(case[0]);
        try testing.expectEqualStrings(case[1], into[0..writer.at]);
    }
    var small: [7]u8 = undefined;
    var writer: _protocol.Writer = .{ .into = &small };
    writer.base64("user:pass");
    try testing.expect(writer.overflow);
}

// --- the server the tests stand up ------------------------------------------------

/// One connection of the server: the answers it gives, one for each
/// request sent over it, after which it closes.
const Script = struct {
    answers: []const []const u8 = &.{},
    /// The most bytes one receive hands over.
    piece: usize = 1 << 20,
    /// Connecting fails with this instead.
    refuse: i32 = http.HTTPERR_OK,
};

const Fake = struct {
    connection: _connection.Connection,
    script: Script,
    /// The answer being handed over, and how far into it.
    current: ?usize = null,
    next: usize = 0,
    at: usize = 0,
    /// Sends since the last answer was begun: an answer comes only once
    /// something has been asked.
    sends: usize = 0,
    sent: [32 * 1024]u8 = undefined,
    sent_length: usize = 0,
    closed: bool = false,

    fn of(connection: *_connection.Connection) *Fake {
        return @fieldParentPtr("connection", connection);
    }

    fn text(fake: *const Fake) []const u8 {
        return fake.sent[0..fake.sent_length];
    }
};

/// A script for each connection, in the order the connections are made.
const Server = struct {
    scripts: []const Script = &.{},
    made: usize = 0,
    fakes: [8]Fake = undefined,
};

var server: Server = .{};

const fake_ops: _connection.Ops = .{ .send = fakeSend, .receive = fakeReceive, .close = fakeClose };

fn fakeConnect(client: *_client.Client, url: Url, failure: *_connection.Failure) ?*_connection.Connection {
    if (server.made == server.scripts.len) {
        failure.code = http.HTTPERR_IO;
        return null;
    }
    const script = server.scripts[server.made];
    const fake = &server.fakes[server.made];
    server.made += 1;
    if (script.refuse != http.HTTPERR_OK) {
        failure.code = script.refuse;
        return null;
    }
    fake.* = .{
        .connection = .{
            .ops = &fake_ops,
            .client = client,
            .secure = url.secure,
            .port = url.port,
            .host_length = @intCast(url.host.len),
        },
        .script = script,
    };
    @memcpy(fake.connection.host[0..url.host.len], url.host);
    return &fake.connection;
}

fn fakeSend(connection: *_connection.Connection, data: []const u8) i32 {
    const fake = Fake.of(connection);
    if (fake.closed or fake.sent_length + data.len > fake.sent.len) return http.HTTPERR_IO;
    @memcpy(fake.sent[fake.sent_length..][0..data.len], data);
    fake.sent_length += data.len;
    fake.sends += 1;
    return http.HTTPERR_OK;
}

fn fakeReceive(connection: *_connection.Connection, into: []u8) i32 {
    const fake = Fake.of(connection);
    const answers = fake.script.answers;
    const finished = if (fake.current) |index| fake.at == answers[index].len else true;
    if (finished) {
        // The next answer, once a request has been sent for it; past the
        // last, the server has closed.
        if (fake.sends == 0 or fake.next == answers.len) return 0;
        fake.current = fake.next;
        fake.next += 1;
        fake.at = 0;
        fake.sends = 0;
    }
    const answer = answers[fake.current.?];
    const count = @min(into.len, answer.len - fake.at, fake.script.piece);
    @memcpy(into[0..count], answer[fake.at..][0..count]);
    fake.at += count;
    return @intCast(count);
}

fn fakeClose(connection: *_connection.Connection) void {
    Fake.of(connection).closed = true;
}

// --- the library ---------------------------------------------------------------

/// Memory lent to exec: requests, and the unpacking's state and window,
/// are more than the test RAM exec starts with.
var lent: [1024 * 1024]u8 align(16) = undefined;

/// What CreateClient is given for a socket base; the server stands in
/// for every connection, so nothing ever calls through it.
var socket_stand_in: usize = 0;

/// exec with memory lent, utility.library and compression.library, and
/// http.library made and opened, with a client whose connections go to
/// the server; compression.library opened too, to pack answers with.
const Rig = struct {
    ub: *host.utility.UtilityBase,
    sys: *ExecBase,
    region: *exec.MemHeader,
    packer: *exec.Library,
    library: *exec.Library,
    hb: *HttpBase,
    cb: *CompressionBase,
    client: *http.Client,

    fn init(scripts: []const Script, tags: ?[*]const utility.TagItem) !Rig {
        server = .{ .scripts = scripts };
        const ub = try host.utility.setUp();
        const sys = kexec.SysBase.iface();
        const region = sys.AddMemList(lent.len, exec.MEMF_ANY, 0, &lent, "lent").?;
        const packer = kexec.InitResident(kexec.SysBase, &compression_init.compression_library_tag, null) orelse return error.NoCompression;
        const made = kexec.InitResident(kexec.SysBase, &http_init.http_library_tag, null) orelse return error.NoLibrary;
        const opened = sys.OpenLibrary(http.HTTPNAME, 1) orelse return error.NoBase;
        const packing = sys.OpenLibrary(compression.COMPRESSIONNAME, 1) orelse return error.NoBase;
        const hb: *HttpBase = @ptrCast(opened);
        const client = hb.CreateClient(@ptrCast(&socket_stand_in), tags) orelse return error.NoClient;
        _client.of(client).?.connect = fakeConnect;
        return .{
            .ub = ub,
            .sys = sys,
            .region = region,
            .packer = @ptrCast(@alignCast(packer)),
            .library = @ptrCast(@alignCast(made)),
            .hb = hb,
            .cb = @ptrCast(packing),
            .client = client,
        };
    }

    /// The client deleted, the libraries closed and expunged, and
    /// nothing left behind.
    fn deinit(rig: *Rig) !void {
        rig.hb.DeleteClient(rig.client);
        rig.sys.CloseLibrary(rig.cb.lib());
        rig.sys.CloseLibrary(rig.hb.lib());
        _ = rig.sys.RemLibrary(rig.library);
        _ = rig.sys.RemLibrary(rig.packer);
        try host.utility.tearDown(rig.ub);
        try testing.expectEqual(@intFromPtr(rig.region.upper) - @intFromPtr(rig.region.lower), rig.region.free);
        rig.sys.Remove(&rig.region.node);
        kexec.deinit();
    }

    fn open(rig: *Rig, method: [*:0]const u8, url: [*:0]const u8, tags: ?[*]const utility.TagItem) !*http.Request {
        var err: i32 = 99;
        const request = rig.hb.OpenRequest(rig.client, method, url, tags, &err) orelse {
            std.debug.print("OpenRequest failed: {d}\n", .{err});
            return error.NoRequest;
        };
        try testing.expectEqual(http.HTTPERR_OK, err);
        return request;
    }

    /// What OpenRequest answers for a request that fails.
    fn refused(rig: *Rig, method: [*:0]const u8, url: [*:0]const u8, tags: ?[*]const utility.TagItem) i32 {
        var err: i32 = 99;
        if (rig.hb.OpenRequest(rig.client, method, url, tags, &err)) |request| {
            rig.hb.CloseRequest(request);
            return 99;
        }
        return err;
    }

    /// The body, read `step` bytes at a time, into `into`.
    fn readAll(rig: *Rig, request: *http.Request, into: []u8, step: u32) ![]u8 {
        var length: usize = 0;
        while (true) {
            const room: u32 = @intCast(@min(step, into.len - length));
            const got = rig.hb.ReadRequest(request, into.ptr + length, room);
            if (got < 0) {
                std.debug.print("ReadRequest failed: {d}\n", .{got});
                return error.ReadFailed;
            }
            if (got == 0) return into[0..length];
            try testing.expect(got <= room);
            length += @intCast(got);
        }
    }

    fn attr(rig: *Rig, request: *http.Request, which: utility.Tag) usize {
        return rig.hb.GetRequestAttr(request, which);
    }

    fn attrText(rig: *Rig, request: *http.Request, which: utility.Tag) []const u8 {
        const pointer: [*:0]const u8 = @ptrFromInt(rig.hb.GetRequestAttr(request, which));
        return std.mem.span(pointer);
    }
};

const agent = "User-Agent: " ++ http_init.USER_AGENT ++ "\r\n";

fn tag(which: utility.Tag, data: anytype) utility.TagItem {
    const value: usize = switch (@typeInfo(@TypeOf(data))) {
        .pointer => @intFromPtr(data),
        .bool => @intFromBool(data),
        else => data,
    };
    return .{ .tag = which, .data = value };
}

test "answers by their length, over one connection kept between them" {
    var rig = try Rig.init(&.{.{ .answers = &.{
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/plain \r\n\r\nhello",
        "HTTP/1.1 404 Not Found\r\nContent-Length: 3\r\n\r\nabc",
    }, .piece = 3 }}, null);
    var buffer: [64]u8 = undefined;

    const first = try rig.open("GET", "http://example.org/a", &[_]utility.TagItem{ tag(http.HTTP_Header, "Accept: */*"), .{} });
    try testing.expectEqual(@as(usize, 200), rig.attr(first, http.HTTP_Status));
    try testing.expectEqualStrings("HTTP/1.1 200 OK", rig.attrText(first, http.HTTP_StatusLine));
    try testing.expectEqual(@as(usize, 5), rig.attr(first, http.HTTP_ContentLength));
    try testing.expectEqualStrings("http://example.org/a", rig.attrText(first, http.HTTP_URL));
    try testing.expectEqualStrings("text/plain", std.mem.span(rig.hb.GetHeader(first, "content-TYPE").?));
    try testing.expectEqual(@as(?[*:0]const u8, null), rig.hb.GetHeader(first, "Location"));
    try testing.expectEqual(@as(usize, 0), rig.attr(first, http.HTTP_Reused));
    try testing.expectEqual(@as(usize, 0), rig.attr(first, http.HTTP_Secure));
    try testing.expectEqual(@as(usize, 0), rig.attr(first, http.HTTP_Unzipping));
    try testing.expectEqual(@as(usize, 0), rig.attr(first, 0x1234));
    try testing.expectEqualStrings("hello", try rig.readAll(first, &buffer, 2));
    try testing.expectEqual(@as(i32, 0), rig.hb.ReadRequest(first, &buffer, buffer.len));
    rig.hb.CloseRequest(first);
    try testing.expectEqualStrings("GET /a HTTP/1.1\r\nHost: example.org\r\n" ++ agent ++ "Accept: */*\r\n\r\n", server.fakes[0].text());
    try testing.expect(!server.fakes[0].closed);

    const second = try rig.open("GET", "http://EXAMPLE.org:80/b?x=1#top", null);
    try testing.expectEqual(@as(usize, 1), rig.attr(second, http.HTTP_Reused));
    try testing.expectEqual(@as(usize, 404), rig.attr(second, http.HTTP_Status));
    try testing.expectEqualStrings("abc", try rig.readAll(second, &buffer, 64));
    rig.hb.CloseRequest(second);
    try testing.expectEqual(@as(usize, 1), server.made);
    try testing.expect(std.mem.endsWith(u8, server.fakes[0].text(), "GET /b?x=1 HTTP/1.1\r\nHost: EXAMPLE.org\r\n" ++ agent ++ "\r\n"));

    try rig.deinit();
    try testing.expect(server.fakes[0].closed);
}

test "a body in chunks, a byte at a time, and a server that closes after it" {
    var rig = try Rig.init(&.{
        .{ .answers = &.{"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n4\r\nWiki\r\n5;x=y\r\npedia\r\n0\r\nTrailer: t\r\n\r\n"}, .piece = 1 },
        .{ .answers = &.{"HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nall of it, up to the close"}, .piece = 7 },
        .{ .answers = &.{"HTTP/1.1 204 No Content\r\n\r\n"} },
    }, null);
    var buffer: [64]u8 = undefined;

    const chunked = try rig.open("GET", "http://h/", null);
    try testing.expectEqual(http.HTTP_LENGTH_UNKNOWN, rig.attr(chunked, http.HTTP_ContentLength));
    try testing.expectEqualStrings("Wikipedia", try rig.readAll(chunked, &buffer, 64));
    rig.hb.CloseRequest(chunked);
    try testing.expect(server.fakes[0].closed);

    const old = try rig.open("GET", "http://h/", null);
    try testing.expectEqual(http.HTTP_LENGTH_UNKNOWN, rig.attr(old, http.HTTP_ContentLength));
    try testing.expectEqualStrings("all of it, up to the close", try rig.readAll(old, &buffer, 5));
    rig.hb.CloseRequest(old);
    try testing.expect(server.fakes[1].closed);

    const empty = try rig.open("DELETE", "http://h/x", null);
    try testing.expectEqual(@as(usize, 204), rig.attr(empty, http.HTTP_Status));
    try testing.expectEqual(@as(i32, 0), rig.hb.ReadRequest(empty, &buffer, buffer.len));
    rig.hb.CloseRequest(empty);
    try testing.expect(!server.fakes[2].closed);
    try testing.expectEqual(@as(usize, 3), server.made);
    try rig.deinit();
}

test "an answer to HEAD has no body, whatever its length says" {
    var rig = try Rig.init(&.{.{ .answers = &.{
        "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n",
        "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 102 Processing\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nz",
    } }}, null);
    var buffer: [64]u8 = undefined;
    const head = try rig.open("HEAD", "http://h/big", null);
    try testing.expectEqual(@as(usize, 1000), rig.attr(head, http.HTTP_ContentLength));
    try testing.expectEqual(@as(i32, 0), rig.hb.ReadRequest(head, &buffer, buffer.len));
    rig.hb.CloseRequest(head);
    try testing.expect(!server.fakes[0].closed);

    // Interim answers are read past.
    const after = try rig.open("GET", "http://h/", null);
    try testing.expectEqual(@as(usize, 200), rig.attr(after, http.HTTP_Status));
    try testing.expectEqualStrings("z", try rig.readAll(after, &buffer, 64));
    rig.hb.CloseRequest(after);
    try rig.deinit();
}

test "redirects: kept on one server, credentials left behind for another, POST to GET on 303" {
    var rig = try Rig.init(&.{
        .{ .answers = &.{
            "HTTP/1.1 307 Temporary Redirect\r\nLocation: again\r\nContent-Length: 4\r\n\r\nmove",
            "HTTP/1.1 303 See Other\r\nLocation: http://other:8080/done\r\nContent-Length: 0\r\n\r\n",
        }, .piece = 5 },
        .{ .answers = &.{"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"} },
    }, null);
    var buffer: [64]u8 = undefined;
    const request = try rig.open("POST", "http://a/forms/send", &[_]utility.TagItem{
        tag(http.HTTP_Body, "x=1"),
        tag(http.HTTP_BodyLength, 3),
        tag(http.HTTP_User, "u"),
        tag(http.HTTP_Password, "p"),
        tag(http.HTTP_Header, "Cookie: c=1"),
        tag(http.HTTP_Header, "Content-Type: application/x-www-form-urlencoded"),
        .{},
    });
    try testing.expectEqual(@as(usize, 200), rig.attr(request, http.HTTP_Status));
    try testing.expectEqualStrings("http://other:8080/done", rig.attrText(request, http.HTTP_URL));
    try testing.expectEqualStrings("ok", try rig.readAll(request, &buffer, 64));
    rig.hb.CloseRequest(request);

    const asked = "Host: a\r\n" ++ agent ++ "Authorization: Basic dTpw\r\nCookie: c=1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 3\r\n\r\nx=1";
    try testing.expectEqualStrings("POST /forms/send HTTP/1.1\r\n" ++ asked ++ "POST /forms/again HTTP/1.1\r\n" ++ asked, server.fakes[0].text());
    try testing.expectEqualStrings("GET /done HTTP/1.1\r\nHost: other:8080\r\n" ++ agent ++ "Content-Type: application/x-www-form-urlencoded\r\n\r\n", server.fakes[1].text());
    // The 307's body was read to its end, so its connection was kept.
    try testing.expect(!server.fakes[0].closed);
    try rig.deinit();
}

test "a token far longer than a password goes whole" {
    var rig = try Rig.init(&.{.{ .answers = &.{"HTTP/1.1 204 No Content\r\n\r\n"} }}, null);
    var token: [1500:0]u8 = @splat('k');
    const request = try rig.open("GET", "http://h/", &[_]utility.TagItem{ tag(http.HTTP_User, "git"), tag(http.HTTP_Password, &token), .{} });
    rig.hb.CloseRequest(request);
    var joined: [1504]u8 = undefined;
    @memcpy(joined[0..4], "git:");
    @memcpy(joined[4..], &token);
    var encoded: [2008]u8 = undefined;
    const encoded_length = _protocol.base64Into(&encoded, &joined);
    const sent = server.fakes[0].text();
    const at = std.mem.indexOf(u8, sent, "Authorization: Basic ").? + 21;
    try testing.expectEqualStrings(encoded[0..encoded_length], sent[at..][0..encoded_length]);
    try testing.expectEqualStrings("\r\n", sent[at + encoded_length ..][0..2]);
    try rig.deinit();
}

test "redirects counted, refused, or taken as the answer" {
    const moved = "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\n\r\n";
    var rig = try Rig.init(&.{
        .{ .answers = &.{ moved, moved, moved } },
        .{ .answers = &.{"HTTP/1.1 301 Moved\r\nContent-Length: 0\r\n\r\n"} },
    }, null);
    try testing.expectEqual(http.HTTPERR_REDIRECT, rig.refused("GET", "http://h/", &[_]utility.TagItem{ tag(http.HTTP_Redirects, 1), .{} }));
    const answer = try rig.open("GET", "http://h/", &[_]utility.TagItem{ tag(http.HTTP_Redirects, 0), .{} });
    try testing.expectEqual(@as(usize, 302), rig.attr(answer, http.HTTP_Status));
    try testing.expectEqualStrings("/next", std.mem.span(rig.hb.GetHeader(answer, "location").?));
    rig.hb.CloseRequest(answer);
    // A redirect without a Location is the answer.
    const nowhere = try rig.open("GET", "http://elsewhere/", null);
    try testing.expectEqual(@as(usize, 301), rig.attr(nowhere, http.HTTP_Status));
    rig.hb.CloseRequest(nowhere);
    try rig.deinit();
}

test "a kept connection the server has let go of: the request sent again on a new one" {
    var rig = try Rig.init(&.{
        .{ .answers = &.{"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\na"} },
        .{ .answers = &.{"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nb"} },
    }, null);
    var buffer: [8]u8 = undefined;
    const first = try rig.open("GET", "http://h/1", null);
    try testing.expectEqualStrings("a", try rig.readAll(first, &buffer, 8));
    rig.hb.CloseRequest(first);
    const second = try rig.open("PUT", "http://h/2", &[_]utility.TagItem{ tag(http.HTTP_Body, "body"), tag(http.HTTP_BodyLength, 4), .{} });
    try testing.expectEqual(@as(usize, 0), rig.attr(second, http.HTTP_Reused));
    try testing.expectEqualStrings("b", try rig.readAll(second, &buffer, 8));
    rig.hb.CloseRequest(second);
    try testing.expect(server.fakes[0].closed);
    try testing.expectEqualStrings("PUT /2 HTTP/1.1\r\nHost: h\r\n" ++ agent ++ "Content-Length: 4\r\n\r\nbody", server.fakes[1].text());
    try rig.deinit();
}

test "a body the program writes: in chunks, and of a length given" {
    var rig = try Rig.init(&.{
        .{ .answers = &.{ "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" } },
        .{ .answers = &.{"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 4\r\n\r\ndone"} },
        .{ .answers = &.{"HTTP/1.1 302 Found\r\nLocation: /x\r\nContent-Length: 0\r\n\r\n"} },
    }, null);
    var buffer: [16]u8 = undefined;
    const before = try rig.open("GET", "http://h/", null);
    rig.hb.CloseRequest(before);

    // Not over the kept connection: a body the program writes is sent
    // only once.
    const chunked = try rig.open("PUT", "http://h/file", &[_]utility.TagItem{ tag(http.HTTP_Chunked, true), .{} });
    try testing.expectEqual(@as(usize, 0), rig.attr(chunked, http.HTTP_Status));
    try testing.expectEqualStrings("", rig.attrText(chunked, http.HTTP_StatusLine));
    try testing.expectEqual(@as(?[*:0]const u8, null), rig.hb.GetHeader(chunked, "Content-Length"));
    try testing.expectEqual(http.HTTPERR_STATE, rig.hb.ReadRequest(chunked, &buffer, buffer.len));
    var large: [10000]u8 = undefined;
    for (&large, 0..) |*byte, index| byte.* = @intCast(index % 251);
    try testing.expectEqual(@as(i32, 3), rig.hb.WriteRequest(chunked, "abc", 3));
    try testing.expectEqual(@as(i32, large.len), rig.hb.WriteRequest(chunked, &large, large.len));
    try testing.expectEqual(@as(i32, 201), rig.hb.WriteRequest(chunked, null, 0));
    try testing.expectEqual(http.HTTPERR_STATE, rig.hb.WriteRequest(chunked, "more", 4));
    try testing.expectEqualStrings("done", try rig.readAll(chunked, &buffer, 16));
    rig.hb.CloseRequest(chunked);
    try testing.expect(!server.fakes[0].closed);
    try testing.expectEqual(@as(usize, 2), server.made);

    // What went: the head, then the chunks, read back.
    const sent = server.fakes[1].text();
    const head_text = "PUT /file HTTP/1.1\r\nHost: h\r\n" ++ agent ++ "Transfer-Encoding: chunked\r\n\r\n";
    try testing.expect(std.mem.startsWith(u8, sent, head_text));
    var body: [12000]u8 = undefined;
    @memcpy(body[0 .. sent.len - head_text.len], sent[head_text.len..]);
    var decoder: _protocol.Chunked = .{};
    const decoded = decoder.feed(body[0 .. sent.len - head_text.len]);
    try testing.expect(decoder.done);
    try testing.expectEqual(@as(usize, 3 + large.len), decoded);
    try testing.expectEqualStrings("abc", body[0..3]);
    try testing.expectEqualSlices(u8, &large, body[3..decoded]);

    // A length given: neither more nor less; and a redirect to it is the
    // answer.
    const sized = try rig.open("POST", "http://h/up", &[_]utility.TagItem{ tag(http.HTTP_BodyLength, 5), .{} });
    try testing.expectEqual(@as(i32, 3), rig.hb.WriteRequest(sized, "abc", 3));
    try testing.expectEqual(http.HTTPERR_STATE, rig.hb.WriteRequest(sized, null, 0));
    try testing.expectEqual(http.HTTPERR_STATE, rig.hb.WriteRequest(sized, "def", 3));
    try testing.expectEqual(@as(i32, 2), rig.hb.WriteRequest(sized, "de", 2));
    try testing.expectEqual(@as(i32, 302), rig.hb.WriteRequest(sized, null, 0));
    rig.hb.CloseRequest(sized);
    try testing.expectEqualStrings("POST /up HTTP/1.1\r\nHost: h\r\n" ++ agent ++ "Content-Length: 5\r\n\r\nabcde", server.fakes[2].text());

    // A request whose body went with its head has none to write.
    const plain = try rig.open("GET", "http://h/", null);
    try testing.expectEqual(http.HTTPERR_STATE, rig.hb.WriteRequest(plain, "x", 1));
    rig.hb.CloseRequest(plain);
    try rig.deinit();
}

/// `text` packed by compression.library in `format`, into `into`.
fn pack(cb: *CompressionBase, format: u32, text: []const u8, into: []u8) ![]u8 {
    var stream: compression.Stream = .{};
    stream.next_in = text.ptr;
    stream.avail_in = @intCast(text.len);
    stream.next_out = into.ptr;
    stream.avail_out = @intCast(into.len);
    try testing.expectEqual(compression.COMPRESS_OK, cb.Compress(&stream, format, compression.LEVEL_DEFAULT));
    return into[0..@intCast(stream.total_out)];
}

/// `data` as a chunked body, in chunks of up to `most` bytes.
fn chunk(data: []const u8, most: usize, into: []u8) []u8 {
    var writer: _protocol.Writer = .{ .into = into };
    var at: usize = 0;
    while (at < data.len) {
        const piece = @min(most, data.len - at);
        writer.hex(@intCast(piece));
        writer.put("\r\n");
        writer.put(data[at..][0..piece]);
        writer.put("\r\n");
        at += piece;
    }
    writer.put("0\r\n\r\n");
    return into[0..writer.at];
}

/// Text that packs, and bytes that do not, after one another.
fn sample(into: []u8) []u8 {
    var seed: u32 = 7;
    var length: usize = 0;
    const words = [_][]const u8{ "pack", "object", "tree", "blob", "commit", "PowerOS", "request", "answer" };
    while (length < 30000) {
        seed = (seed *% 1103515245 +% 12345) & 0x7FFF_FFFF;
        const word = words[(seed >> 16) % words.len];
        @memcpy(into[length..][0..word.len], word);
        length += word.len;
        into[length] = ' ';
        length += 1;
    }
    while (length < 40000) : (length += 1) {
        seed = (seed *% 1103515245 +% 12345) & 0x7FFF_FFFF;
        into[length] = @intCast(seed >> 23);
    }
    return into[0..length];
}

var text_store: [40100]u8 = undefined;
var packed_store: [48 * 1024]u8 = undefined;
var answer_store: [3][56 * 1024]u8 = undefined;
var read_store: [48 * 1024]u8 = undefined;

test "a packed answer unpacked: gzip in chunks, deflate by length, and one that does not unpack" {
    const text = sample(&text_store);
    // The answers are made with the library itself, so the rig comes up
    // with a stand-in script first and is set its real one after.
    var rig = try Rig.init(&.{}, null);
    const gzip = try pack(rig.cb, compression.FORMAT_GZIP, text, &packed_store);
    var gzip_body: [52 * 1024]u8 = undefined;
    const gzip_chunked = chunk(gzip, 1000, &gzip_body);
    const gzip_head = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n";
    @memcpy(answer_store[0][0..gzip_head.len], gzip_head);
    @memcpy(answer_store[0][gzip_head.len..][0..gzip_chunked.len], gzip_chunked);
    const first = answer_store[0][0 .. gzip_head.len + gzip_chunked.len];

    var zlib_store: [48 * 1024]u8 = undefined;
    const zlib = try pack(rig.cb, compression.FORMAT_ZLIB, text, &zlib_store);
    var writer: _protocol.Writer = .{ .into = &answer_store[1] };
    writer.put("HTTP/1.1 200 OK\r\nContent-Encoding: deflate\r\nContent-Length: ");
    writer.decimal(zlib.len);
    writer.put("\r\n\r\n");
    writer.put(zlib);
    const second = answer_store[1][0..writer.at];

    // The same gzip, its bytes as they are for a program that did not ask.
    const third = first;

    var broken: [96]u8 = undefined;
    const broken_head = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 12\r\n\r\n";
    @memcpy(broken[0..broken_head.len], broken_head);
    // A gzip header, then a block of the type there is not.
    @memcpy(broken[broken_head.len..][0..12], "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x07\x00");
    const fourth = broken[0 .. broken_head.len + 12];

    const answers = [_][]const u8{ first, second, third, fourth };
    const scripts = [_]Script{.{ .answers = &answers, .piece = 1500 }};
    server = .{ .scripts = &scripts };

    const unzip = [_]utility.TagItem{ tag(http.HTTP_Unzip, true), .{} };
    const gzipped = try rig.open("GET", "http://h/a", &unzip);
    try testing.expectEqual(@as(usize, 1), rig.attr(gzipped, http.HTTP_Unzipping));
    try testing.expectEqual(http.HTTP_LENGTH_UNKNOWN, rig.attr(gzipped, http.HTTP_ContentLength));
    try testing.expectEqualSlices(u8, text, try rig.readAll(gzipped, &read_store, 3000));
    rig.hb.CloseRequest(gzipped);
    try testing.expect(std.mem.indexOf(u8, server.fakes[0].text(), "Accept-Encoding: gzip, deflate\r\n") != null);

    const deflated = try rig.open("GET", "http://h/b", &unzip);
    try testing.expectEqual(@as(usize, 1), rig.attr(deflated, http.HTTP_Reused));
    try testing.expectEqualSlices(u8, text, try rig.readAll(deflated, &read_store, 100000));
    rig.hb.CloseRequest(deflated);

    const as_sent = try rig.open("GET", "http://h/c", null);
    try testing.expectEqual(@as(usize, 0), rig.attr(as_sent, http.HTTP_Unzipping));
    try testing.expectEqualSlices(u8, gzip, try rig.readAll(as_sent, &read_store, 4096));
    rig.hb.CloseRequest(as_sent);

    const bad = try rig.open("GET", "http://h/d", &unzip);
    var buffer: [64]u8 = undefined;
    try testing.expectEqual(http.HTTPERR_DATA, rig.hb.ReadRequest(bad, &buffer, buffer.len));
    try testing.expectEqual(http.HTTPERR_DATA, rig.hb.ReadRequest(bad, &buffer, buffer.len));
    try testing.expectEqual(@as(usize, @bitCast(@as(isize, http.HTTPERR_DATA))), rig.attr(bad, http.HTTP_Error));
    rig.hb.CloseRequest(bad);
    try testing.expect(server.fakes[0].closed);
    try testing.expectEqual(@as(usize, 1), server.made);
    try rig.deinit();
}

test "what is refused, and why" {
    var long_head: [9000]u8 = undefined;
    @memcpy(long_head[0..17], "HTTP/1.1 200 OK\r\n");
    @memset(long_head[17..], 'x');
    var rig = try Rig.init(&.{
        .{ .answers = &.{"SSH-2.0-OpenSSH\r\n\r\n"} },
        .{ .answers = &.{"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc"} },
        .{ .refuse = http.HTTPERR_HOST },
        .{ .answers = &.{"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nabcdeX"} },
        .{ .answers = &.{"HTTP/1.1 200 OK\r\nContent-"} },
        .{ .answers = &.{&long_head} },
    }, null);
    try testing.expectEqual(http.HTTPERR_URL, rig.refused("GET", "ftp://h/", null));
    try testing.expectEqual(http.HTTPERR_URL, rig.refused("GET", "http://h/a b", null));
    try testing.expectEqual(http.HTTPERR_STATE, rig.refused("GE T", "http://h/", null));
    try testing.expectEqual(http.HTTPERR_STATE, rig.refused("", "http://h/", null));
    try testing.expectEqual(http.HTTPERR_STATE, rig.refused("GET", "http://h/", &[_]utility.TagItem{ tag(http.HTTP_Header, "X: a\r\nY: b"), .{} }));
    var token: [2048:0]u8 = @splat('t');
    try testing.expectEqual(http.HTTPERR_STATE, rig.refused("GET", "http://h/", &[_]utility.TagItem{ tag(http.HTTP_User, "u"), tag(http.HTTP_Password, &token), .{} }));
    try testing.expectEqual(@as(usize, 0), server.made);

    try testing.expectEqual(http.HTTPERR_PROTOCOL, rig.refused("GET", "http://h/", null));
    var buffer: [64]u8 = undefined;
    const short = try rig.open("GET", "http://h/", null);
    try testing.expectEqual(@as(i32, 3), rig.hb.ReadRequest(short, &buffer, buffer.len));
    try testing.expectEqual(http.HTTPERR_TRUNCATED, rig.hb.ReadRequest(short, &buffer, buffer.len));
    rig.hb.CloseRequest(short);
    try testing.expect(server.fakes[1].closed);
    try testing.expectEqual(http.HTTPERR_HOST, rig.refused("GET", "http://nowhere/", null));
    const nonsense = try rig.open("GET", "http://h/", null);
    try testing.expectEqual(@as(i32, 5), rig.hb.ReadRequest(nonsense, &buffer, buffer.len));
    try testing.expectEqual(http.HTTPERR_PROTOCOL, rig.hb.ReadRequest(nonsense, &buffer, buffer.len));
    rig.hb.CloseRequest(nonsense);
    try testing.expectEqual(http.HTTPERR_TRUNCATED, rig.refused("GET", "http://h/", null));
    try testing.expectEqual(http.HTTPERR_PROTOCOL, rig.refused("GET", "http://h/", null));
    // No more connections to be had.
    try testing.expectEqual(http.HTTPERR_IO, rig.refused("GET", "http://h/", null));

    // Handles the library did not make.
    var stranger: [64]u64 align(16) = @splat(0);
    try testing.expectEqual(http.HTTPERR_STATE, rig.hb.ReadRequest(@ptrCast(&stranger), &buffer, buffer.len));
    rig.hb.CloseRequest(@ptrCast(&stranger));
    rig.hb.CloseRequest(null);
    rig.hb.DeleteClient(null);
    var err: i32 = 0;
    try testing.expectEqual(@as(?*http.Request, null), rig.hb.OpenRequest(@ptrCast(&stranger), "GET", "http://h/", null, &err));
    try testing.expectEqual(http.HTTPERR_STATE, err);
    try rig.deinit();
}

test "the pool keeps four connections, the one idle longest closed for a fifth" {
    const ok = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
    var rig = try Rig.init(&.{
        .{ .answers = &.{ok} },
        .{ .answers = &.{ok} },
        .{ .answers = &.{ok} },
        .{ .answers = &.{ok} },
        .{ .answers = &.{ ok, ok } },
    }, &[_]utility.TagItem{ tag(http.HTTP_UserAgent, "Tester/2\r\nX: y"), tag(http.HTTP_Timeout, 5), .{} });
    const urls = [_][*:0]const u8{ "http://a/", "http://b/", "https://a/", "http://a:81/", "http://c/" };
    for (urls) |url| {
        const request = try rig.open("GET", url, null);
        rig.hb.CloseRequest(request);
    }
    try testing.expect(server.fakes[0].closed);
    for (server.fakes[1..5]) |*fake| try testing.expect(!fake.closed);
    try testing.expect(server.fakes[2].connection.secure);
    try testing.expectEqualStrings("GET / HTTP/1.1\r\nHost: a:81\r\nUser-Agent: Tester/2\r\n\r\n", server.fakes[3].text());
    try testing.expectEqual(@as(u32, 5), _client.of(rig.client).?.timeout);
    const again = try rig.open("GET", "http://c/", null);
    try testing.expectEqual(@as(usize, 1), rig.attr(again, http.HTTP_Reused));
    rig.hb.CloseRequest(again);
    try rig.deinit();
    for (server.fakes[0..5]) |*fake| try testing.expect(fake.closed);
}
