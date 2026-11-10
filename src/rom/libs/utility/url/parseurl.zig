// SPDX-License-Identifier: MPL-2.0
//! ParseUrl: a URL taken apart where it lies.

const std = @import("std");
const sdk = @import("sdk");
const utility = sdk.utility;

const UtilityBase = @import("../utility.zig").UtilityBase;
const UrlParts = utility.url.UrlParts;
const UrlPart = utility.url.UrlPart;

/// Takes a URL apart in place: its scheme, user, password, host, port
/// and path, each where it lies in the text.
///
/// SYNOPSIS:
/// ```zig
/// fn ParseUrl(ub: *UtilityBase, text: [*]const u8, length: usize, parts: *utility.UrlParts, flags: u32) bool
/// ```
///
/// SINCE: 1.5. LVO -288.
///
/// INPUTS:
/// - `text`, `length` - the URL; no NUL is looked for.
/// - `parts` - filled in: each part's offset in `text` and its length,
///   the port, and what `flags` says of them.
/// - `flags` - URLF_SCP takes `[user@]host:path` too.
///
/// RESULT:
/// True when `text` is a URL - `parts` then holds it - false when it is
/// none, and `parts` holds nothing of use.
///
/// BEHAVIOR:
/// A URL is `scheme://[user[:password]@]host[:port][/path][?query]`
/// and a `#fragment` after it. The scheme is a letter and then letters,
/// digits, `+`, `-` and `.`; it is taken in any case and handed out as it
/// is written. The authority runs to the first `/`, `?` or `#`: what is
/// before its last `@` is the user, up to a first `:`, and the password
/// after it (URLF_USER, URLF_PASSWORD). The host is a name, an IPv4
/// address, or an IPv6 address in brackets (URLF_BRACKETS, the host
/// without them); a `:` after it gives the port, 1 to 65535. The path
/// runs from the authority's end to a `#` or the end, its query with it.
///
/// With URLF_SCP, a text with no scheme is read as `[user@]host:path`:
/// the first colon outside brackets ends the host, there is no `/` before
/// it and no `//` after it, and all after it is the path, which may be
/// empty. URLF_SCP is set in `parts.flags` when this form was read.
///
/// A text is none when its host is empty, its brackets are not closed,
/// its port is not one, or a byte in it is a control character or a
/// space - but for spaces in the scp form's path, which names a file.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads its input and writes `parts`.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated, copied or decoded: the parts are the text's
/// bytes as the URL writes them, escapes and all (`DecodeUrl`).
///
/// NOTES:
/// `UrlPart.of(text)` hands a part out as a slice. An authority the
/// caller sends on - a Host header - is the text from the host, with its
/// bracket, to `parts.path.offset`.
///
/// BUGS:
/// A text longer than 4 GiB is no URL.
///
/// SEE ALSO:
/// `DecodeUrl`, `EncodeUrl`
///
/// EXAMPLES:
/// ```zig
/// var parts: utility.UrlParts = .{};
/// if (!ub.ParseUrl(text.ptr, text.len, &parts, 0)) return error_url;
/// const host = parts.host.of(text);
/// const port: u32 = if (parts.port != 0) parts.port else 443;
///
/// // A copy's remote end, or a local name: `user@host:path`.
/// if (ub.ParseUrl(name.ptr, name.len, &parts, utility.URLF_SCP) and parts.flags & utility.URLF_SCP != 0) ...
/// ```
pub fn ParseUrl(_: *UtilityBase, text_ptr: [*]const u8, length: usize, parts: *UrlParts, flags: u32) bool {
    parts.* = .{};
    if (length > std.math.maxInt(u32)) return false;
    const text = text_ptr[0..length];
    if (schemeLength(text)) |scheme_length| {
        parts.scheme = part(0, scheme_length);
        return urlForm(text, scheme_length + 3, parts);
    }
    if (flags & utility.url.URLF_SCP == 0) return false;
    return scpForm(text, parts);
}

/// The scheme's length when `text` starts with one and `://`.
fn schemeLength(text: []const u8) ?usize {
    if (text.len == 0 or !isLetter(text[0])) return null;
    var at: usize = 1;
    while (at < text.len) : (at += 1) {
        const char = text[at];
        if (isLetter(char) or (char >= '0' and char <= '9') or char == '+' or char == '-' or char == '.') continue;
        if (char == ':' and at + 3 <= text.len and text[at + 1] == '/' and text[at + 2] == '/') return at;
        return null;
    }
    return null;
}

/// The authority from `start`, and the path after it.
fn urlForm(text: []const u8, start: usize, parts: *UrlParts) bool {
    for (text) |char| if (!isPlain(char)) return false;
    var end = start;
    while (end < text.len and text[end] != '/' and text[end] != '?' and text[end] != '#') end += 1;
    var path_end = end;
    while (path_end < text.len and text[path_end] != '#') path_end += 1;
    parts.path = part(end, path_end - end);
    var host_start = start;
    if (lastIndex(text[start..end], '@')) |at_sign| {
        userInfo(text, start, start + at_sign, parts);
        host_start = start + at_sign + 1;
    }
    return hostPort(text, host_start, end, true, parts);
}

/// `[user@]host:path`.
fn scpForm(text: []const u8, parts: *UrlParts) bool {
    var colon: ?usize = null;
    var bracket = false;
    for (text, 0..) |char, at| {
        if (char == '[') bracket = true;
        if (char == ']') bracket = false;
        if (bracket) continue;
        if (char == '/') return false;
        if (char == ':') {
            colon = at;
            break;
        }
    }
    const end = colon orelse return false;
    if (end + 2 < text.len and text[end + 1] == '/' and text[end + 2] == '/') return false;
    for (text[0..end]) |char| if (!isPlain(char)) return false;
    for (text[end + 1 ..]) |char| if (char < 0x20 or char == 0x7F) return false;
    parts.path = part(end + 1, text.len - end - 1);
    var host_start: usize = 0;
    if (lastIndex(text[0..end], '@')) |at_sign| {
        parts.user = part(0, at_sign);
        parts.flags |= utility.url.URLF_USER;
        host_start = at_sign + 1;
    }
    parts.flags |= utility.url.URLF_SCP;
    return hostPort(text, host_start, end, false, parts);
}

/// The user and the password between `start` and the `@` at `at_sign`.
fn userInfo(text: []const u8, start: usize, at_sign: usize, parts: *UrlParts) void {
    parts.flags |= utility.url.URLF_USER;
    const colon = firstIndex(text[start..at_sign], ':') orelse {
        parts.user = part(start, at_sign - start);
        return;
    };
    parts.user = part(start, colon);
    parts.password = part(start + colon + 1, at_sign - start - colon - 1);
    parts.flags |= utility.url.URLF_PASSWORD;
}

/// The host from `start` to `end`, and a port after it when `ported`.
fn hostPort(text: []const u8, start: usize, end: usize, ported: bool, parts: *UrlParts) bool {
    const authority = text[start..end];
    var host_end = authority.len;
    if (authority.len > 0 and authority[0] == '[') {
        const close = firstIndex(authority, ']') orelse return false;
        if (close == 1) return false;
        parts.host = part(start + 1, close - 1);
        parts.flags |= utility.url.URLF_BRACKETS;
        host_end = close + 1;
        if (host_end < authority.len and authority[host_end] != ':') return false;
    } else {
        if (firstIndex(authority, ':')) |colon| host_end = colon;
        if (host_end == 0) return false;
        for (authority[0..host_end]) |char| if (char == '[' or char == ']') return false;
        parts.host = part(start, host_end);
    }
    if (host_end == authority.len) return true;
    // `:` and the port's digits.
    if (!ported) return false;
    const digits = authority[host_end + 1 ..];
    if (digits.len == 0 or digits.len > 5) return false;
    var port: u32 = 0;
    for (digits) |digit| {
        if (digit < '0' or digit > '9') return false;
        port = port * 10 + (digit - '0');
    }
    if (port == 0 or port > 65535) return false;
    parts.port = port;
    return true;
}

fn part(offset: usize, length: usize) UrlPart {
    return .{ .offset = @intCast(offset), .length = @intCast(length) };
}

fn firstIndex(text: []const u8, wanted: u8) ?usize {
    for (text, 0..) |char, at| if (char == wanted) return at;
    return null;
}

fn lastIndex(text: []const u8, wanted: u8) ?usize {
    var at = text.len;
    while (at > 0) {
        at -= 1;
        if (text[at] == wanted) return at;
    }
    return null;
}

fn isLetter(char: u8) bool {
    return (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z');
}

/// A byte a URL may hold as it is written: no control character, no
/// space.
fn isPlain(char: u8) bool {
    return char > 0x20 and char != 0x7F;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

fn parse(ub: *UtilityBase, text: []const u8, flags: u32) ?UrlParts {
    var parts: UrlParts = .{};
    if (!ParseUrl(ub, text.ptr, text.len, &parts, flags)) return null;
    return parts;
}

test "ParseUrl: every part, where it lies" {
    const ub = try library.setUp();
    defer kexec.deinit();
    const text = "HTTPS://me:t%40k@[fe80::1]:8443/a/b?q=1#top";
    const parts = parse(ub, text, 0).?;
    try testing.expectEqualStrings("HTTPS", parts.scheme.of(text));
    try testing.expectEqualStrings("me", parts.user.of(text));
    try testing.expectEqualStrings("t%40k", parts.password.of(text));
    try testing.expectEqualStrings("fe80::1", parts.host.of(text));
    try testing.expectEqual(@as(u32, 8443), parts.port);
    try testing.expectEqualStrings("/a/b?q=1", parts.path.of(text));
    try testing.expectEqual(utility.url.URLF_USER | utility.url.URLF_PASSWORD | utility.url.URLF_BRACKETS, parts.flags);
    // The authority as sent on: from the host's bracket to the path.
    try testing.expectEqualStrings("[fe80::1]:8443", text[parts.host.offset - 1 .. parts.path.offset]);

    const plain = "http://example.org";
    const bare = parse(ub, plain, 0).?;
    try testing.expectEqualStrings("example.org", bare.host.of(plain));
    try testing.expectEqual(@as(u32, 0), bare.port);
    try testing.expectEqual(@as(u32, 0), bare.path.length);
    try testing.expectEqual(@as(u32, plain.len), bare.path.offset);
    try testing.expectEqual(@as(u32, 0), bare.flags);

    const query = "http://h?q=1";
    try testing.expectEqualStrings("?q=1", parse(ub, query, 0).?.path.of(query));
    // The last `@` ends the user; an empty password is given.
    const odd = "ssh://a@b:@host/x";
    const odd_parts = parse(ub, odd, 0).?;
    try testing.expectEqualStrings("a@b", odd_parts.user.of(odd));
    try testing.expectEqual(@as(u32, 0), odd_parts.password.length);
    try testing.expect(odd_parts.flags & utility.url.URLF_PASSWORD != 0);
    try testing.expectEqualStrings("host", odd_parts.host.of(odd));
}

test "ParseUrl: the scp form, and what is no URL" {
    const ub = try library.setUp();
    defer kexec.deinit();
    const scp = "git@github.com:me/My Repo.git";
    const parts = parse(ub, scp, utility.url.URLF_SCP).?;
    try testing.expectEqual(utility.url.URLF_SCP | utility.url.URLF_USER, parts.flags);
    try testing.expectEqualStrings("git", parts.user.of(scp));
    try testing.expectEqualStrings("github.com", parts.host.of(scp));
    try testing.expectEqualStrings("me/My Repo.git", parts.path.of(scp));
    try testing.expectEqual(@as(u32, 0), parts.scheme.length);
    const six = "[::1]:";
    const six_parts = parse(ub, six, utility.url.URLF_SCP).?;
    try testing.expectEqualStrings("::1", six_parts.host.of(six));
    try testing.expectEqual(@as(u32, 0), six_parts.path.length);
    // Not without the flag; a scheme's URL is read as one even with it.
    try testing.expect(parse(ub, scp, 0) == null);
    try testing.expect(parse(ub, "ssh://h/x", utility.url.URLF_SCP).?.flags & utility.url.URLF_SCP == 0);
    for ([_][]const u8{ "dir/file:x", ":path", "a b:x", "[::1:x", "h:1:x\x01", "h://x y" }) |text| {
        try testing.expect(parse(ub, text, utility.url.URLF_SCP) == null);
    }
    for ([_][]const u8{
        "",          "example.org",  "http://",        "http://:80/",  "http://h:0/",  "http://h:65536/",
        "http://h:", "http://h:8a",  "http://[::1/",   "http://[]/",   "http://h/a b", "http://h/a\r\nX: y",
        "1http://h", "http://h\x01", "http://[::1]x/", "http://h[1]/", "ht tp://h",
    }) |text| {
        try testing.expect(parse(ub, text, 0) == null);
    }
}
