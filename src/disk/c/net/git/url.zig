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
//!
//! utility.library takes the URL apart (ParseUrl) and undoes and makes
//! its escapes (DecodeUrl, EncodeUrl).

const sdk = @import("sdk");
const utility = sdk.utility;
const UtilityBase = sdk.interface.utility.UtilityBase;
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

/// `text` taken apart into `into` by utility.library's ParseUrl: false
/// when it is no URL Git can reach.
pub fn parse(ub: *UtilityBase, text: []const u8, into: *RemoteUrl) bool {
    into.has_user = false;
    into.has_password = false;
    into.port = 0;
    var parts: utility.UrlParts = .{};
    if (!ub.ParseUrl(text.ptr, text.len, &parts, utility.URLF_SCP)) return false;
    const scheme = parts.scheme.of(text);
    if (parts.flags & utility.URLF_SCP != 0 or sameScheme(scheme, "ssh")) return parseSsh(ub, text, &parts, into);
    if (!sameScheme(scheme, "https") and !sameScheme(scheme, "http")) return false;
    into.kind = .http;
    if (parts.flags & utility.URLF_USER != 0) {
        into.user_length = decode(ub, parts.user.of(text), &into.user) orelse return false;
        into.has_user = true;
        if (parts.flags & utility.URLF_PASSWORD != 0) {
            into.password_length = decode(ub, parts.password.of(text), &into.password) orelse return false;
            into.has_password = true;
        }
    }
    var path = parts.path.of(text);
    while (path.len > 0 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    // The URL without its user: the scheme, then the host - an IPv6
    // address's bracket with it - and the port.
    const bracket: u32 = @intFromBool(parts.flags & utility.URLF_BRACKETS != 0);
    var out: _git.Out = .{ .into = into.url[0..url_most] };
    out.put(text[0 .. scheme.len + 3]);
    out.put(text[parts.host.offset - bracket .. parts.path.offset]);
    into.origin_length = out.at;
    out.put(path);
    if (out.overflow) return false;
    into.url_length = out.at;
    into.url[out.at] = 0;
    return true;
}

/// `ssh://[user@]host[:port]/path`, or `[user@]host:path` (URLF_SCP), as
/// ParseUrl found its `parts`.
fn parseSsh(ub: *UtilityBase, text: []const u8, parts: *const utility.UrlParts, into: *RemoteUrl) bool {
    into.kind = .ssh;
    const scp = parts.flags & utility.URLF_SCP != 0;
    const scheme_length: usize = if (scp) 0 else parts.scheme.length + 3;
    var trimmed = text;
    while (trimmed.len > scheme_length + 1 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
    if (trimmed.len > url_most) return false;
    @memcpy(into.url[0..trimmed.len], trimmed);
    into.url[trimmed.len] = 0;
    into.url_length = trimmed.len;
    // The path is the server's from its root - but for `/~user/...`, the
    // user's home's - and the scp form's from the home.
    var path_start: usize = parts.path.offset;
    if (!scp and _git.startsWith(trimmed[path_start..], "/~")) path_start += 1;
    if (path_start >= trimmed.len) return false;
    into.path_start = path_start;
    into.path_length = trimmed.len - path_start;
    if (parts.flags & utility.URLF_USER != 0) {
        into.user_length = decode(ub, parts.user.of(text), &into.user) orelse return false;
        into.has_user = into.user_length != 0;
    }
    into.port = @intCast(parts.port);
    const host = parts.host.of(text);
    if (host.len > host_most) return false;
    @memcpy(into.host[0..host.len], host);
    into.host[host.len] = 0;
    into.host_length = host.len;
    into.origin_length = 0;
    return true;
}

/// Whether a URL's scheme is `wanted`, in any case.
fn sameScheme(scheme: []const u8, wanted: []const u8) bool {
    if (scheme.len != wanted.len) return false;
    for (scheme, wanted) |char, want| {
        const lower = if (char >= 'A' and char <= 'Z') char + 32 else char;
        if (lower != want) return false;
    }
    return true;
}

/// `%XX` decoded from `text` into `into` by utility.library, a NUL after
/// it: how many bytes, or null when they do not fit or a `%` is no
/// escape.
fn decode(ub: *UtilityBase, text: []const u8, into: []u8) ?usize {
    const room = into.len - 1;
    const length = ub.DecodeUrl(text.ptr, text.len, into.ptr, room);
    if (length == utility.URL_BROKEN or length > room) return null;
    into[length] = 0;
    return length;
}

/// `bytes` with every character a URL's user part cannot hold as `%XX`,
/// by utility.library.
pub fn encode(ub: *UtilityBase, out: *_git.Out, bytes: []const u8) void {
    const room = out.into.len - out.at;
    const length = ub.EncodeUrl(bytes.ptr, bytes.len, out.into[out.at..].ptr, room, 0);
    if (length > room) {
        out.overflow = true;
        return;
    }
    out.at += length;
}
