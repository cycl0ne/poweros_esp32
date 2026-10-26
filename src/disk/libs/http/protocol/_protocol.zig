// SPDX-License-Identifier: MIT
//! HTTP/1.1's text, apart from the network so it can be tested: a URL
//! taken apart, a redirect's Location made into a URL, the head of an
//! answer read, a chunked body decoded in place as it comes in pieces,
//! and the base64 Basic authorization is sent in.
//!
//! **An answer's head is read in place**: each of its lines is ended with
//! a NUL where its line end was, and a value's trailing blanks are cut
//! off the same way, so the status line and every header's value are
//! strings in the bytes the head came in, handed out as they are.

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

    /// The port the scheme has when the URL names none.
    pub fn defaultPort(url: Url) u16 {
        return if (url.secure) 443 else 80;
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

/// Whether `text` and `other` are the same, case aside.
pub fn same(text: []const u8, other: []const u8) bool {
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
    for (path) |char| {
        if (char <= ' ' or char == 0x7F) return null;
    }
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
    for (host) |char| {
        if (char <= ' ' or char == 0x7F or char == '@') return null;
    }
    return .{ .host = host, .port = port, .path = path, .secure = secure };
}

/// Where a redirect's `location` leads from `base`, written into `into`:
/// its length, or null when it does not fit or leads nowhere. It may be
/// a whole URL, one without a scheme (`//host/...`), a path from the
/// root, or a path beside the base's; the `.` and `..` segments of the
/// path it comes to are worked out (RFC 3986, 5.2.4).
pub fn resolve(base: Url, location: []const u8, into: []u8) ?usize {
    if (location.len == 0) return null;
    var writer: Writer = .{ .into = into };
    if (startsWith(location, "http://") or startsWith(location, "https://")) {
        writer.put(location);
    } else if (location.len >= 2 and location[0] == '/' and location[1] == '/') {
        writer.put(if (base.secure) "https:" else "http:");
        writer.put(location);
    } else {
        writer.put(if (base.secure) "https://" else "http://");
        writer.put(base.host);
        if (base.port != base.defaultPort()) {
            var digits: [8]u8 = undefined;
            writer.put(portText(base.port, &digits));
        }
        if (location[0] == '/') {
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
    return withoutDots(into[0..writer.at]);
}

/// The URL in `url` with its path's dot segments worked out, in place:
/// its new length. The query is left as it is.
fn withoutDots(url: []u8) usize {
    var path_start: usize = 0;
    for (url, 0..) |char, index| {
        if (char == ':' and index + 2 < url.len and url[index + 1] == '/' and url[index + 2] == '/') {
            path_start = index + 3;
            break;
        }
    }
    while (path_start < url.len and url[path_start] != '/' and url[path_start] != '?') path_start += 1;
    var path_end = path_start;
    while (path_end < url.len and url[path_end] != '?') path_end += 1;
    if (path_start == path_end) return url.len;
    const kept = removeDots(url[path_start..path_end]);
    const query = url.len - path_end;
    var index: usize = 0;
    while (index < query) : (index += 1) url[path_start + kept + index] = url[path_end + index];
    return path_start + kept + query;
}

/// A path from its `/` with its `.` and `..` segments worked out, in
/// place: its new length. What is written never passes what is read.
fn removeDots(path: []u8) usize {
    var out: usize = 0;
    var at: usize = 0;
    while (at < path.len) {
        var end = at + 1;
        while (end < path.len and path[end] != '/') end += 1;
        const segment = path[at + 1 .. end];
        const last = end == path.len;
        if (segment.len == 1 and segment[0] == '.') {
            if (last) {
                path[out] = '/';
                out += 1;
            }
        } else if (segment.len == 2 and segment[0] == '.' and segment[1] == '.') {
            // The segment before it goes, up to its slash.
            while (out > 0) {
                out -= 1;
                if (path[out] == '/') break;
            }
            if (last) {
                path[out] = '/';
                out += 1;
            }
        } else {
            var index = at;
            while (index < end) : (index += 1) {
                path[out] = path[index];
                out += 1;
            }
        }
        at = end;
    }
    if (out == 0) {
        path[0] = '/';
        out = 1;
    }
    return out;
}

/// `:port` in decimal, in `into`.
pub fn portText(port: u16, into: *[8]u8) []const u8 {
    var digits: [5]u8 = undefined;
    var count: usize = 0;
    var rest = port;
    while (rest != 0) : (rest /= 10) {
        digits[count] = '0' + @as(u8, @intCast(rest % 10));
        count += 1;
    }
    into[0] = ':';
    var at: usize = 1;
    while (count > 0) {
        count -= 1;
        into[at] = digits[count];
        at += 1;
    }
    return into[0..at];
}

/// Text put one piece after another into a buffer, remembering whether
/// any did not fit.
pub const Writer = struct {
    into: []u8,
    at: usize = 0,
    overflow: bool = false,

    pub fn put(writer: *Writer, text: []const u8) void {
        if (writer.at + text.len > writer.into.len) {
            writer.overflow = true;
            return;
        }
        @memcpy(writer.into[writer.at..][0..text.len], text);
        writer.at += text.len;
    }

    /// A number in hexadecimal, as a chunk's size is written.
    pub fn hex(writer: *Writer, value: u32) void {
        var digits: [8]u8 = undefined;
        var count: usize = 0;
        var rest = value;
        while (true) {
            digits[digits.len - 1 - count] = "0123456789abcdef"[rest & 15];
            count += 1;
            rest >>= 4;
            if (rest == 0) break;
        }
        writer.put(digits[digits.len - count ..]);
    }

    /// `data` in base64.
    pub fn base64(writer: *Writer, data: []const u8) void {
        const count = (data.len + 2) / 3 * 4;
        if (writer.at + count > writer.into.len) {
            writer.overflow = true;
            return;
        }
        writer.at += base64Into(writer.into[writer.at..], data);
    }

    /// A number in decimal.
    pub fn decimal(writer: *Writer, value: u64) void {
        var digits: [20]u8 = undefined;
        var count: usize = 0;
        var rest = value;
        while (true) {
            digits[digits.len - 1 - count] = '0' + @as(u8, @intCast(rest % 10));
            count += 1;
            rest /= 10;
            if (rest == 0) break;
        }
        writer.put(digits[digits.len - count ..]);
    }
};

/// How an answer's body was packed (Content-Encoding).
pub const Encoding = enum { identity, gzip, deflate, other };

/// The head of an answer: its status, and the headers that decide how
/// its body is read.
pub const Head = struct {
    status: u16 = 0,
    /// The status line, ended with a NUL in the head's bytes.
    status_line: [*:0]const u8 = "",
    /// The body's length, if the answer says.
    content_length: ?u64 = null,
    chunked: bool = false,
    /// The connection ends with this answer: `Connection: close`, or an
    /// HTTP/1.0 answer that does not ask to keep it.
    close: bool = false,
    encoding: Encoding = .identity,
    location: ?[*:0]const u8 = null,
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

/// The head in `bytes`, which holds it whole (headEnd), its lines ended
/// with NULs in place; null when it is not an HTTP answer.
pub fn parseHead(bytes: []u8) ?Head {
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
    head.status_line = @ptrCast(status_line.ptr);
    const old = status_line[7] == '0';
    var keep_alive = false;
    while (lines.next()) |line| {
        const field = split(line) orelse continue;
        const value = field.value;
        if (same(field.name, "content-length")) {
            var length: u64 = 0;
            if (value.len == 0 or value.len > 18) return null;
            for (value) |digit| {
                if (digit < '0' or digit > '9') return null;
                length = length * 10 + (digit - '0');
            }
            head.content_length = length;
        } else if (same(field.name, "transfer-encoding")) {
            head.chunked = contains(value, "chunked");
        } else if (same(field.name, "content-encoding")) {
            head.encoding = if (same(value, "gzip") or same(value, "x-gzip"))
                .gzip
            else if (same(value, "deflate"))
                .deflate
            else if (value.len == 0 or same(value, "identity"))
                .identity
            else
                .other;
        } else if (same(field.name, "connection")) {
            if (contains(value, "close")) head.close = true;
            if (contains(value, "keep-alive")) keep_alive = true;
        } else if (same(field.name, "location")) {
            head.location = @ptrCast(value.ptr);
        }
    }
    if (old and !keep_alive) head.close = true;
    // A chunked body's length is its chunks', whatever else is said.
    if (head.chunked) head.content_length = null;
    return head;
}

/// A header line's name and value, the value without the blanks round
/// it; null for a line with no colon.
const Field = struct { name: []const u8, value: []const u8 };

fn split(line: []const u8) ?Field {
    var colon: usize = 0;
    while (colon < line.len and line[colon] != ':') colon += 1;
    if (colon == line.len) return null;
    var value = line[colon + 1 ..];
    while (value.len > 0 and (value[0] == ' ' or value[0] == '\t')) value = value[1..];
    return .{ .name = line[0..colon], .value = value };
}

/// The value of the header `name` in a head parseHead has read; null
/// when there is none. The first of several.
pub fn findHeader(head: []const u8, name: []const u8) ?[*:0]const u8 {
    var at: usize = 0;
    // Past the status line.
    at = lineAfter(head, at) orelse return null;
    while (at < head.len and head[at] != 0) {
        const start = at;
        var stop = at;
        while (stop < head.len and head[stop] != 0) stop += 1;
        if (split(head[start..stop])) |field| {
            if (same(field.name, name)) return @ptrCast(field.value.ptr);
        }
        at = lineAfter(head, start) orelse return null;
    }
    return null;
}

/// Where the line after the one at `start` starts, in a head read in
/// place: past its NUL, the blanks and carriage return cut from its end,
/// and its line feed.
fn lineAfter(head: []const u8, start: usize) ?usize {
    var at = start;
    while (at < head.len and head[at] != 0) at += 1;
    if (at == head.len) return null;
    while (at < head.len and (head[at] == 0 or head[at] == ' ' or head[at] == '\t' or head[at] == '\r')) at += 1;
    if (at < head.len and head[at] == '\n') at += 1;
    return at;
}

fn contains(text: []const u8, word: []const u8) bool {
    var at: usize = 0;
    while (at + word.len <= text.len) : (at += 1) {
        if (startsWith(text[at..], word)) return true;
    }
    return false;
}

/// The lines of a head, each ended with a NUL in place of its line end
/// and of the blanks before it.
const Lines = struct {
    text: []u8,
    at: usize = 0,

    fn next(lines: *Lines) ?[]u8 {
        if (lines.at >= lines.text.len) return null;
        const start = lines.at;
        while (lines.at < lines.text.len and lines.text[lines.at] != '\n') lines.at += 1;
        var stop = lines.at;
        if (stop > start and lines.text[stop - 1] == '\r') stop -= 1;
        while (stop > start and (lines.text[stop - 1] == ' ' or lines.text[stop - 1] == '\t')) stop -= 1;
        if (stop < lines.text.len) lines.text[stop] = 0;
        lines.at += 1;
        if (stop == start) return null;
        return lines.text[start..stop];
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

/// `data` in base64 (RFC 4648) into `into`, which holds at least
/// `(data.len + 2) / 3 * 4` bytes: how many it wrote.
pub fn base64Into(into: []u8, data: []const u8) usize {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var at: usize = 0;
    var index: usize = 0;
    while (index < data.len) : (index += 3) {
        const left = data.len - index;
        const a: u32 = data[index];
        const b: u32 = if (left > 1) data[index + 1] else 0;
        const c: u32 = if (left > 2) data[index + 2] else 0;
        const group = a << 16 | b << 8 | c;
        into[at] = alphabet[group >> 18];
        into[at + 1] = alphabet[group >> 12 & 63];
        into[at + 2] = if (left > 1) alphabet[group >> 6 & 63] else '=';
        into[at + 3] = if (left > 2) alphabet[group & 63] else '=';
        at += 4;
    }
    return at;
}
