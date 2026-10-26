// SPDX-License-Identifier: MIT
//! A remote's URL taken apart. `http://` and `https://host[:port]/path`
//! reach the server's smart HTTP; a user and a token in it
//! (`https://user:token@host/...`, `%XX` for the characters a URL cannot
//! hold) are taken out and sent as Basic credentials, and the URL kept
//! without them, its trailing slashes dropped.
//!
//! `ssh://[user@]host[:port]/path` and `[user@]host:path` - a colon
//! before any slash - reach the server over SSH. The path of the first
//! is the server's from its root, but for `/~user/...`, which is the
//! user's home's; the second's is from the home of the user logged in
//! as.

const _git = @import("_git.zig");

/// The longest URL, as http.library takes it.
pub const url_most = 2048;
/// The longest user name and token.
pub const secret_most = 255;

pub const Kind = enum { http, ssh };

/// The longest host name.
pub const host_most = 255;

pub const RemoteUrl = struct {
    kind: Kind,
    /// The URL without its user, NUL-terminated.
    url: [url_most + 1]u8 = undefined,
    url_length: usize = 0,
    /// How much of `url` is `scheme://host[:port]`: what credentials are
    /// kept under.
    origin_length: usize = 0,
    user: [secret_most + 1]u8 = undefined,
    user_length: usize = 0,
    has_user: bool = false,
    password: [secret_most + 1]u8 = undefined,
    password_length: usize = 0,
    has_password: bool = false,
    /// SSH: the host, NUL-terminated; the port, 0 for SSH's own; and
    /// where in `url` the path is.
    host: [host_most + 1]u8 = undefined,
    host_length: usize = 0,
    port: u16 = 0,
    path_start: usize = 0,
    path_length: usize = 0,

    pub fn text(remote: *const RemoteUrl) []const u8 {
        return remote.url[0..remote.url_length];
    }

    pub fn origin(remote: *const RemoteUrl) []const u8 {
        return remote.url[0..remote.origin_length];
    }

    pub fn userText(remote: *const RemoteUrl) ?[]const u8 {
        return if (remote.has_user) remote.user[0..remote.user_length] else null;
    }

    pub fn hostText(remote: *const RemoteUrl) []const u8 {
        return remote.host[0..remote.host_length];
    }

    pub fn pathText(remote: *const RemoteUrl) []const u8 {
        return remote.url[remote.path_start..][0..remote.path_length];
    }
};

/// `text` taken apart into `into`: false when it is no URL Git can reach.
pub fn parse(text: []const u8, into: *RemoteUrl) bool {
    into.has_user = false;
    into.has_password = false;
    into.port = 0;
    if (_git.startsWith(text, "ssh://")) return parseSsh(text, 6, into);
    const scheme_length: usize = if (_git.startsWith(text, "https://"))
        8
    else if (_git.startsWith(text, "http://"))
        7
    else if (isScpLike(text))
        return parseSsh(text, 0, into)
    else
        return false;
    into.kind = .http;
    var rest = text[scheme_length..];
    var authority_end: usize = 0;
    while (authority_end < rest.len and rest[authority_end] != '/') authority_end += 1;
    var authority = rest[0..authority_end];
    // The user is up to the last '@' of the authority.
    var at_sign: ?usize = null;
    for (authority, 0..) |char, index| {
        if (char == '@') at_sign = index;
    }
    if (at_sign) |sign| {
        const userinfo = authority[0..sign];
        var colon: usize = 0;
        while (colon < userinfo.len and userinfo[colon] != ':') colon += 1;
        into.user_length = decode(userinfo[0..colon], &into.user) orelse return false;
        into.user[into.user_length] = 0;
        into.has_user = true;
        if (colon < userinfo.len) {
            into.password_length = decode(userinfo[colon + 1 ..], &into.password) orelse return false;
            into.password[into.password_length] = 0;
            into.has_password = true;
        }
        authority = authority[sign + 1 ..];
    }
    if (authority.len == 0) return false;
    rest = rest[authority_end..];
    while (rest.len > 0 and rest[rest.len - 1] == '/') rest = rest[0 .. rest.len - 1];
    var out: _git.Out = .{ .into = into.url[0..url_most] };
    out.put(text[0..scheme_length]);
    out.put(authority);
    into.origin_length = out.at;
    out.put(rest);
    if (out.overflow) return false;
    into.url_length = out.at;
    into.url[out.at] = 0;
    return true;
}

/// `[user@]host:path`: a colon, and no slash before it - but not a
/// URL of another scheme's, `ftp://`.
fn isScpLike(text: []const u8) bool {
    for (text, 0..) |char, at| {
        if (char == '/') return false;
        if (char == ':') return !_git.startsWith(text[at..], "://");
    }
    return false;
}

/// `ssh://[user@]host[:port]/path` after its scheme's `scheme_length`
/// bytes, or `[user@]host:path` with none.
fn parseSsh(text: []const u8, scheme_length: usize, into: *RemoteUrl) bool {
    into.kind = .ssh;
    var trimmed = text;
    while (trimmed.len > scheme_length + 1 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
    if (trimmed.len > url_most) return false;
    @memcpy(into.url[0..trimmed.len], trimmed);
    into.url[trimmed.len] = 0;
    into.url_length = trimmed.len;
    const scp = scheme_length == 0;
    const rest = trimmed[scheme_length..];
    // The authority ends at the path's slash, or the scp form's colon -
    // the first outside an address in brackets.
    var end: usize = 0;
    var bracket = false;
    while (end < rest.len) : (end += 1) {
        const char = rest[end];
        if (char == '[') bracket = true;
        if (char == ']') bracket = false;
        if (bracket) continue;
        if (if (scp) char == ':' else char == '/') break;
    }
    if (end == rest.len) return false;
    var authority = rest[0..end];
    var path_start = scheme_length + end;
    if (scp) path_start += 1;
    if (!scp and _git.startsWith(trimmed[path_start..], "/~")) path_start += 1;
    if (path_start >= trimmed.len) return false;
    into.path_start = path_start;
    into.path_length = trimmed.len - path_start;
    var at_sign: ?usize = null;
    for (authority, 0..) |char, index| {
        if (char == '@') at_sign = index;
    }
    if (at_sign) |sign| {
        into.user_length = decode(authority[0..sign], &into.user) orelse return false;
        into.user[into.user_length] = 0;
        into.has_user = into.user_length != 0;
        authority = authority[sign + 1 ..];
    }
    // The port, after the last colon outside brackets (ssh:// only).
    if (!scp) {
        var colon: ?usize = null;
        for (authority, 0..) |char, index| {
            if (char == ':') colon = index;
            if (char == ']') colon = null;
        }
        if (colon) |place| {
            var port: u32 = 0;
            for (authority[place + 1 ..]) |char| {
                if (char < '0' or char > '9') return false;
                port = port * 10 + (char - '0');
                if (port > 65535) return false;
            }
            if (port == 0) return false;
            into.port = @intCast(port);
            authority = authority[0..place];
        }
    }
    if (authority.len >= 2 and authority[0] == '[' and authority[authority.len - 1] == ']') authority = authority[1 .. authority.len - 1];
    if (authority.len == 0 or authority.len > host_most) return false;
    @memcpy(into.host[0..authority.len], authority);
    into.host[authority.len] = 0;
    into.host_length = authority.len;
    into.origin_length = 0;
    return true;
}

/// `%XX` decoded from `text` into `into`, leaving room for a NUL: how
/// many bytes, or null when they do not fit or a `%` is no escape.
pub fn decode(text: []const u8, into: []u8) ?usize {
    var length: usize = 0;
    var at: usize = 0;
    while (at < text.len) {
        if (length + 1 >= into.len) return null;
        if (text[at] == '%') {
            if (at + 3 > text.len) return null;
            const high = hexDigit(text[at + 1]) orelse return null;
            const low = hexDigit(text[at + 2]) orelse return null;
            into[length] = high << 4 | low;
            at += 3;
        } else {
            into[length] = text[at];
            at += 1;
        }
        length += 1;
    }
    return length;
}

/// `bytes` with every character a URL's user part cannot hold as `%XX`.
pub fn encode(out: *_git.Out, bytes: []const u8) void {
    const digits = "0123456789ABCDEF";
    for (bytes) |char| {
        const plain = (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or (char >= '0' and char <= '9') or char == '-' or char == '.' or char == '_' or char == '~';
        if (plain) {
            out.byte(char);
        } else {
            out.put(&.{ '%', digits[char >> 4], digits[char & 15] });
        }
    }
}

fn hexDigit(char: u8) ?u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}
