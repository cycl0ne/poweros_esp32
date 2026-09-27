// SPDX-License-Identifier: MIT
//! HTTP/1.1 as HTTPGet needs it, apart from the network so it can be
//! tested: a URL taken apart, a redirect's Location made into a URL, the
//! head of an answer read, and a chunked body decoded in place as it
//! comes in pieces.

pub const Url = struct {
    /// As the URL writes it, and the Host header sends it: an IPv6
    /// address in its brackets.
    host: []const u8,
    port: u16,
    /// From its `/`, query included; "/" when the URL has none, and just
    /// the query (`?a=1`) when it has only that - the request puts a `/`
    /// before it.
    path: []const u8,
    secure: bool,

    /// The host as a name or address to look up: an IPv6 one without its
    /// brackets.
    pub fn hostName(url: Url) []const u8 {
        if (url.host.len >= 2 and url.host[0] == '[') return url.host[1 .. url.host.len - 1];
        return url.host;
    }
};

fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + 32 else char;
}

/// Whether `text` starts with `prefix`, case aside.
pub fn startsWith(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    for (text[0..prefix.len], prefix) |got, want| {
        if (lower(got) != lower(want)) return false;
    }
    return true;
}

fn same(text: []const u8, other: []const u8) bool {
    return text.len == other.len and startsWith(text, other);
}

/// `http://host[:port][/path]` or `https://...` taken apart - the host a
/// name, an IPv4 address or an IPv6 one in brackets (RFC 3986, 3.2.2);
/// null when it is not one.
pub fn parseUrl(text: []const u8) ?Url {
    var rest = text;
    var secure = false;
    if (startsWith(rest, "http://")) {
        rest = rest[7..];
    } else if (startsWith(rest, "https://")) {
        rest = rest[8..];
        secure = true;
    } else return null;
    var host_end: usize = 0;
    while (host_end < rest.len and rest[host_end] != '/' and rest[host_end] != '?' and rest[host_end] != '#') host_end += 1;
    var host = rest[0..host_end];
    var path: []const u8 = rest[host_end..];
    // A fragment is the reader's, never sent.
    for (path, 0..) |char, index| {
        if (char == '#') {
            path = path[0..index];
            break;
        }
    }
    if (path.len == 0) path = "/";
    var port: u16 = if (secure) 443 else 80;
    // The port's colon is the one past an IPv6 address's bracket.
    var from: usize = 0;
    if (host.len > 0 and host[0] == '[') {
        from = (for (host, 0..) |char, index| {
            if (char == ']') break index;
        } else return null) + 1;
        if (from == 2) return null;
    }
    for (host[from..], from..) |char, index| {
        if (char != ':') continue;
        const digits = host[index + 1 ..];
        if (digits.len == 0 or digits.len > 5) return null;
        var value: u32 = 0;
        for (digits) |digit| {
            if (digit < '0' or digit > '9') return null;
            value = value * 10 + (digit - '0');
        }
        if (value == 0 or value > 65535) return null;
        port = @intCast(value);
        host = host[0..index];
        break;
    }
    if (host.len == 0) return null;
    return .{ .host = host, .port = port, .path = path, .secure = secure };
}

/// Where a redirect's `location` leads from `base`, written into `into`:
/// its length, or null when it does not fit or leads nowhere. It may be
/// a whole URL, one without a scheme (`//host/...`), a path from the
/// root, or a path beside the base's.
pub fn resolve(base: Url, location: []const u8, into: []u8) ?usize {
    var writer: Writer = .{ .into = into };
    if (startsWith(location, "http://") or startsWith(location, "https://")) {
        writer.put(location);
    } else if (location.len >= 2 and location[0] == '/' and location[1] == '/') {
        writer.put(if (base.secure) "https:" else "http:");
        writer.put(location);
    } else {
        writer.put(if (base.secure) "https://" else "http://");
        writer.put(base.host);
        if (base.port != (if (base.secure) @as(u16, 443) else 80)) {
            writer.put(":");
            var digits: [5]u8 = undefined;
            var count: usize = 0;
            var rest = base.port;
            while (rest != 0) : (rest /= 10) {
                digits[count] = '0' + @as(u8, @intCast(rest % 10));
                count += 1;
            }
            while (count > 0) {
                count -= 1;
                writer.put(digits[count .. count + 1]);
            }
        }
        if (location.len > 0 and location[0] == '/') {
            writer.put(location);
        } else {
            // Beside the base: its path up to the last slash, the query
            // left out.
            var directory = base.path;
            for (directory, 0..) |char, index| {
                if (char == '?') {
                    directory = directory[0..index];
                    break;
                }
            }
            var slash: usize = 0;
            for (directory, 0..) |char, index| {
                if (char == '/') slash = index;
            }
            if (directory.len == 0 or directory[0] != '/') writer.put("/") else writer.put(directory[0 .. slash + 1]);
            writer.put(location);
        }
    }
    if (writer.overflow) return null;
    return writer.at;
}

const Writer = struct {
    into: []u8,
    at: usize = 0,
    overflow: bool = false,

    fn put(writer: *Writer, text: []const u8) void {
        if (writer.at + text.len > writer.into.len) {
            writer.overflow = true;
            return;
        }
        @memcpy(writer.into[writer.at..][0..text.len], text);
        writer.at += text.len;
    }
};

/// The head of an answer: its status, and the headers that matter here.
pub const Head = struct {
    status: u16 = 0,
    /// The status line, without its line end.
    status_line: []const u8 = &.{},
    /// The body's length, if the answer says.
    content_length: ?u64 = null,
    chunked: bool = false,
    location: ?[]const u8 = null,
    /// Where the body starts in the bytes the head came in.
    body_at: usize = 0,
};

/// Where the head in `bytes` ends - past its empty line - or null when it
/// has not all come yet.
pub fn headEnd(bytes: []const u8) ?usize {
    var index: usize = 0;
    while (index + 1 < bytes.len) : (index += 1) {
        if (bytes[index] != '\n') continue;
        if (bytes[index + 1] == '\n') return index + 2;
        if (index + 2 < bytes.len and bytes[index + 1] == '\r' and bytes[index + 2] == '\n') return index + 3;
    }
    return null;
}

/// The head in `bytes`, which holds it whole (headEnd); null when it is
/// not an HTTP answer.
pub fn parseHead(bytes: []const u8) ?Head {
    const end = headEnd(bytes) orelse return null;
    var head: Head = .{ .body_at = end };
    var lines = Lines{ .text = bytes[0..end] };
    const status_line = lines.next() orelse return null;
    if (!startsWith(status_line, "HTTP/1.") or status_line.len < 12 or status_line[8] != ' ') return null;
    var status: u16 = 0;
    for (status_line[9..12]) |digit| {
        if (digit < '0' or digit > '9') return null;
        status = status * 10 + (digit - '0');
    }
    if (status_line.len > 12 and status_line[12] != ' ') return null;
    head.status = status;
    head.status_line = status_line;
    while (lines.next()) |line| {
        var colon: usize = 0;
        while (colon < line.len and line[colon] != ':') colon += 1;
        if (colon == line.len) continue;
        const name = line[0..colon];
        var value = line[colon + 1 ..];
        while (value.len > 0 and (value[0] == ' ' or value[0] == '\t')) value = value[1..];
        while (value.len > 0 and (value[value.len - 1] == ' ' or value[value.len - 1] == '\t')) value = value[0 .. value.len - 1];
        if (same(name, "content-length")) {
            var length: u64 = 0;
            if (value.len == 0 or value.len > 18) return null;
            for (value) |digit| {
                if (digit < '0' or digit > '9') return null;
                length = length * 10 + (digit - '0');
            }
            head.content_length = length;
        } else if (same(name, "transfer-encoding")) {
            head.chunked = contains(value, "chunked");
        } else if (same(name, "location")) {
            head.location = value;
        }
    }
    // A chunked body's length is its chunks', whatever else is said.
    if (head.chunked) head.content_length = null;
    return head;
}

fn contains(text: []const u8, word: []const u8) bool {
    var at: usize = 0;
    while (at + word.len <= text.len) : (at += 1) {
        if (startsWith(text[at..], word)) return true;
    }
    return false;
}

const Lines = struct {
    text: []const u8,
    at: usize = 0,

    fn next(lines: *Lines) ?[]const u8 {
        if (lines.at >= lines.text.len) return null;
        const start = lines.at;
        while (lines.at < lines.text.len and lines.text[lines.at] != '\n') lines.at += 1;
        var line = lines.text[start..lines.at];
        lines.at += 1;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len == 0) return null;
        return line;
    }
};

/// A chunked body, decoded in place: each piece handed to `feed` comes
/// back with the chunks' data moved to its front. The sizes, their
/// extensions and the line ends between may be cut anywhere.
pub const Chunked = struct {
    state: State = .size,
    /// What is left of the chunk being read.
    left: u64 = 0,
    digits: u8 = 0,
    failed: bool = false,
    done: bool = false,

    const State = enum { size, extension, size_end, data, data_cr, data_lf, trailer_start, trailer, trailer_end };

    /// The data in `piece`, moved to its front: how many bytes.
    pub fn feed(chunked: *Chunked, piece: []u8) usize {
        var out: usize = 0;
        var at: usize = 0;
        while (at < piece.len and !chunked.done and !chunked.failed) {
            const char = piece[at];
            switch (chunked.state) {
                .size => {
                    const value: ?u8 = switch (char) {
                        '0'...'9' => char - '0',
                        'a'...'f' => char - 'a' + 10,
                        'A'...'F' => char - 'A' + 10,
                        else => null,
                    };
                    if (value) |digit| {
                        chunked.digits += 1;
                        if (chunked.digits > 15) chunked.failed = true;
                        chunked.left = chunked.left * 16 + digit;
                    } else if (chunked.digits == 0) {
                        chunked.failed = true;
                    } else if (char == ';' or char == ' ' or char == '\t') {
                        chunked.state = .extension;
                    } else if (char == '\r') {
                        chunked.state = .size_end;
                    } else if (char == '\n') {
                        chunked.sized();
                    } else chunked.failed = true;
                    at += 1;
                },
                .extension => {
                    if (char == '\r') chunked.state = .size_end;
                    if (char == '\n') chunked.sized();
                    at += 1;
                },
                .size_end => {
                    if (char != '\n') chunked.failed = true else chunked.sized();
                    at += 1;
                },
                .data => {
                    const take: usize = @intCast(@min(chunked.left, piece.len - at));
                    if (out != at) @memmove(piece[out..][0..take], piece[at..][0..take]);
                    out += take;
                    at += take;
                    chunked.left -= take;
                    if (chunked.left == 0) chunked.state = .data_cr;
                },
                .data_cr => {
                    if (char == '\r') {
                        chunked.state = .data_lf;
                    } else if (char == '\n') {
                        chunked.state = .size;
                    } else chunked.failed = true;
                    at += 1;
                },
                .data_lf => {
                    if (char != '\n') chunked.failed = true else chunked.state = .size;
                    at += 1;
                },
                // After the last chunk: trailer lines, up to an empty one.
                .trailer_start => {
                    if (char == '\r') {
                        chunked.state = .trailer_end;
                    } else if (char == '\n') {
                        chunked.done = true;
                    } else chunked.state = .trailer;
                    at += 1;
                },
                .trailer => {
                    if (char == '\n') chunked.state = .trailer_start;
                    at += 1;
                },
                .trailer_end => {
                    if (char != '\n') chunked.failed = true else chunked.done = true;
                    at += 1;
                },
            }
        }
        return out;
    }

    fn sized(chunked: *Chunked) void {
        chunked.digits = 0;
        chunked.state = if (chunked.left == 0) .trailer_start else .data;
    }
};

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

test "URLs taken apart" {
    const plain = parseUrl("http://example.org").?;
    try testing.expectEqualStrings("example.org", plain.host);
    try testing.expectEqual(@as(u16, 80), plain.port);
    try testing.expectEqualStrings("/", plain.path);
    const full = parseUrl("HTTP://10.0.2.2:8000/dir/file.txt?a=1#top").?;
    try testing.expectEqualStrings("10.0.2.2", full.host);
    try testing.expectEqual(@as(u16, 8000), full.port);
    try testing.expectEqualStrings("/dir/file.txt?a=1", full.path);
    try testing.expect(parseUrl("https://example.org/").?.secure);
    try testing.expectEqualStrings("?q=1", parseUrl("http://h?q=1").?.path);
    const six = parseUrl("http://[fec0::2]:8080/x").?;
    try testing.expectEqualStrings("[fec0::2]", six.host);
    try testing.expectEqualStrings("fec0::2", six.hostName());
    try testing.expectEqual(@as(u16, 8080), six.port);
    try testing.expectEqual(@as(u16, 80), parseUrl("http://[::1]/").?.port);
    for ([_][]const u8{ "ftp://x/", "http://", "http://:80/", "http://h:0/", "http://h:65536/", "http://h:8a/", "example.org", "http://[::1/", "http://[]/" }) |text| {
        try testing.expectEqual(@as(?Url, null), parseUrl(text));
    }
}

test "a redirect's Location made into a URL" {
    const base = parseUrl("http://h:8000/a/b/c.html?q=1").?;
    var into: [128]u8 = undefined;
    const cases = [_][2][]const u8{
        .{ "http://other/x", "http://other/x" },
        .{ "//other/y", "http://other/y" },
        .{ "/root", "http://h:8000/root" },
        .{ "d.html", "http://h:8000/a/b/d.html" },
    };
    for (cases) |case| {
        const length = resolve(base, case[0], &into).?;
        try testing.expectEqualStrings(case[1], into[0..length]);
    }
    const default_port = parseUrl("http://h/").?;
    const length = resolve(default_port, "/z", &into).?;
    try testing.expectEqualStrings("http://h/z", into[0..length]);
    var small: [8]u8 = undefined;
    try testing.expectEqual(@as(?usize, null), resolve(base, "/a-long-way", &small));
}

test "the head of an answer" {
    const text = "HTTP/1.1 301 Moved Permanently\r\nContent-Length: 12\r\nLOCATION:  /there \r\nX: y\r\n\r\nbody";
    try testing.expectEqual(@as(?usize, text.len - 4), headEnd(text));
    try testing.expectEqual(@as(?usize, null), headEnd(text[0 .. text.len - 6]));
    const head = parseHead(text).?;
    try testing.expectEqual(@as(u16, 301), head.status);
    try testing.expectEqualStrings("HTTP/1.1 301 Moved Permanently", head.status_line);
    try testing.expectEqual(@as(?u64, 12), head.content_length);
    try testing.expectEqualStrings("/there", head.location.?);
    try testing.expectEqualStrings("body", text[head.body_at..]);
    const chunked = parseHead("HTTP/1.1 200 OK\nTransfer-Encoding: gzip, Chunked\nContent-Length: 5\n\n").?;
    try testing.expect(chunked.chunked);
    try testing.expectEqual(@as(?u64, null), chunked.content_length);
    for ([_][]const u8{ "SSH-2.0 x\r\n\r\n", "HTTP/1.1 2x0 OK\r\n\r\n", "HTTP/1.1 200OK\r\n\r\n", "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n" }) |bad| {
        try testing.expectEqual(@as(?Head, null), parseHead(bad));
    }
}

test "a chunked body decoded, cut at every byte" {
    const body = "4\r\nWiki\r\n6;name=x\r\npedia \r\nE\r\nin \r\n\r\nchunks.\r\n0\r\nTrailer: yes\r\n\r\nafter";
    const want = "Wikipedia in \r\n\r\nchunks.";
    var cut: usize = 0;
    while (cut <= body.len) : (cut += 1) {
        var copy: [body.len]u8 = body.*;
        var decoder: Chunked = .{};
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
        var decoder: Chunked = .{};
        _ = decoder.feed(copy[0..bad.len]);
        try testing.expect(decoder.failed);
    }
}
