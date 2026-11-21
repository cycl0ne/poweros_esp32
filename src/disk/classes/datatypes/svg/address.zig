// SPDX-License-Identifier: MIT
//! An `image`'s address as the place of a file (since 1.7): what an
//! `href` that is not a `data:` address names, read against the place
//! of the document that names it.
//!
//! An address is a URL reference (RFC 3986). Its query and fragment are
//! cut off - a picture is the whole file - and its percent escapes
//! decoded. What is left is one of:
//!
//! - **a relative reference**, `pictures/sun.png` or `../sun.png`: its
//!   segments from the directory of the document, `.` passed over and
//!   `..` the directory above;
//! - **a path from the root**, `/pictures/sun.png`: from the root of the
//!   document's volume;
//! - **a `file:` URL**, `file:///Work/pictures/sun.png`: its path's
//!   first segment the volume, the rest a path in it;
//! - **a dos path**, `Work:pictures/sun.png`: a volume's name before a
//!   colon, before any slash - itself.
//!
//! An address of any other scheme (`http:`, `https:`) names no file and
//! is not read.
//!
//! `dosPath` writes the place as dos takes a path: segments between
//! slashes, a slash alone for the directory above (`/sun.png`, `//sun.png`
//! two up), a colon before the first for the root of the volume the
//! current directory is on (`:pictures/sun.png`). `hostPath` writes it as
//! a host's file system takes one, for the tools that draw on the host.

const std = @import("std");

/// What an address names.
pub const Kind = enum {
    /// From the directory of the document that names it.
    relative,
    /// From the root of that document's volume.
    root,
    /// A volume's name, and a path in it.
    volume,
};

/// The place an address names, its escapes still in it.
pub const Place = struct {
    kind: Kind,
    /// The volume, for `.volume`.
    volume: []const u8 = "",
    /// The path, its segments between slashes.
    path: []const u8,
};

/// The place `href_in` names; null for an empty address, a `data:`
/// address, one of only a fragment - an element of the same document -
/// or one of a scheme that names no file.
pub fn placeOf(href_in: []const u8) ?Place {
    var href = std.mem.trim(u8, href_in, " \t\r\n");
    if (std.mem.indexOfAny(u8, href, "?#")) |cut| href = href[0..cut];
    if (href.len == 0) return null;
    if (schemeOf(href)) |scheme| {
        if (!std.ascii.eqlIgnoreCase(scheme, "file")) return null;
        var rest = href[scheme.len + 1 ..];
        // `file://host/path`: the host is this machine whatever it says.
        if (std.mem.startsWith(u8, rest, "//")) {
            const after = rest[2..];
            rest = after[(std.mem.indexOfScalar(u8, after, '/') orelse after.len)..];
        }
        const path = std.mem.trimStart(u8, rest, "/");
        if (path.len == 0) return null;
        const slash = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
        return .{ .kind = .volume, .volume = path[0..slash], .path = if (slash < path.len) path[slash + 1 ..] else "" };
    }
    // `Work:pictures/sun.png`: a colon before any slash.
    if (std.mem.indexOfScalar(u8, href, ':')) |colon| {
        const slash = std.mem.indexOfScalar(u8, href, '/') orelse href.len;
        if (colon < slash) return .{ .kind = .volume, .volume = href[0..colon], .path = href[colon + 1 ..] };
    }
    if (href[0] == '/') return .{ .kind = .root, .path = std.mem.trimStart(u8, href, "/") };
    return .{ .kind = .relative, .path = href };
}

/// The scheme of an absolute URL - letters, then letters, digits, `+`,
/// `-` or `.`, then a colon and two slashes, or the colon alone for
/// `data:`; null for none. A dos volume's name before its colon is no
/// scheme: one is a URL's only with the slashes, or when it is
/// `file:` or `data:`.
fn schemeOf(href: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, href, ':') orelse return null;
    const scheme = href[0..colon];
    if (scheme.len == 0 or !std.ascii.isAlphabetic(scheme[0])) return null;
    for (scheme) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return null;
    }
    if (std.mem.startsWith(u8, href[colon + 1 ..], "//")) return scheme;
    if (std.ascii.eqlIgnoreCase(scheme, "file") or std.ascii.eqlIgnoreCase(scheme, "data")) return scheme;
    return null;
}

/// `text` with its percent escapes decoded into `into`, which is at
/// least as long; a `%` not before two hexadecimal digits is itself.
pub fn unescape(text: []const u8, into: []u8) []u8 {
    var n: usize = 0;
    var at: usize = 0;
    while (at < text.len) : (n += 1) {
        if (text[at] == '%' and at + 2 < text.len) {
            const high = std.fmt.charToDigit(text[at + 1], 16) catch null;
            const low = std.fmt.charToDigit(text[at + 2], 16) catch null;
            if (high != null and low != null) {
                into[n] = high.? << 4 | low.?;
                at += 3;
                continue;
            }
        }
        into[n] = text[at];
        at += 1;
    }
    return into[0..n];
}

/// `place` as a dos path, NUL-terminated, into `into`; null when it
/// does not fit or names no file - a path that ends in a directory.
pub fn dosPath(place: Place, into: []u8) ?[:0]const u8 {
    if (std.mem.endsWith(u8, place.path, "/")) return null;
    var out = Out{ .into = into };
    switch (place.kind) {
        .relative => {},
        .root => out.add(":") orelse return null,
        .volume => {
            out.addUnescaped(place.volume) orelse return null;
            out.add(":") orelse return null;
        },
    }
    var named = false;
    var segments = std.mem.splitScalar(u8, place.path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            // A slash for the directory above: after a name, one to end
            // it and one more.
            if (named) out.add("/") orelse return null;
            out.add("/") orelse return null;
            named = false;
            continue;
        }
        if (named) out.add("/") orelse return null;
        out.addUnescaped(segment) orelse return null;
        named = true;
    }
    if (!named) return null;
    return out.end();
}

/// `place` as a host's path, NUL-terminated, into `into`, a relative one
/// from `directory` and one from the root from `/`; a volume is the
/// host's root's directory of that name. Null when it does not fit or
/// names no file.
pub fn hostPath(place: Place, directory: []const u8, into: []u8) ?[:0]const u8 {
    var out = Out{ .into = into };
    switch (place.kind) {
        .relative => {
            out.add(directory) orelse return null;
            out.add("/") orelse return null;
        },
        .root => out.add("/") orelse return null,
        .volume => {
            out.add("/") orelse return null;
            out.addUnescaped(place.volume) orelse return null;
            out.add("/") orelse return null;
        },
    }
    if (place.path.len == 0 or std.mem.endsWith(u8, place.path, "/")) return null;
    out.addUnescaped(place.path) orelse return null;
    return out.end();
}

/// Bytes written one piece after another, room kept for a NUL.
const Out = struct {
    into: []u8,
    length: usize = 0,

    fn add(out: *Out, text: []const u8) ?void {
        if (out.length + text.len + 1 > out.into.len) return null;
        @memcpy(out.into[out.length..][0..text.len], text);
        out.length += text.len;
    }

    fn addUnescaped(out: *Out, text: []const u8) ?void {
        if (out.length + text.len + 1 > out.into.len) return null;
        out.length += unescape(text, out.into[out.length..]).len;
    }

    fn end(out: *Out) [:0]const u8 {
        out.into[out.length] = 0;
        return out.into[0..out.length :0];
    }
};

// --- tests ---------------------------------------------------------------------

const testing = std.testing;

fn expectDos(expected: ?[]const u8, href: []const u8) !void {
    var room: [128]u8 = undefined;
    const place = placeOf(href);
    const got: ?[]const u8 = if (place) |found| dosPath(found, &room) else null;
    if (expected) |text| {
        try testing.expectEqualStrings(text, got orelse return error.TestExpectedEqual);
    } else try testing.expect(got == null);
}

test "an image's address as a dos path: relative, from the root, a volume's, a file URL's" {
    try expectDos("sun.png", "sun.png");
    try expectDos("pictures/sun.png", "./pictures/sun.png");
    try expectDos("/sun.png", "../sun.png");
    try expectDos("//sun.png", "../../sun.png");
    try expectDos("pictures//sun.png", "pictures/../sun.png");
    try expectDos(":pictures/sun.png", "/pictures/sun.png");
    try expectDos("Work:pictures/sun.png", "Work:pictures/sun.png");
    try expectDos("Work:pictures/sun.png", "file:///Work/pictures/sun.png");
    try expectDos("Work:sun.png", "file://localhost/Work/sun.png");
    try expectDos("my sun.png", "my%20sun.png");
    try expectDos("sun.svg", "sun.svg#layer?x");
    try expectDos(null, "https://example.com/sun.png");
    try expectDos(null, "data:image/png;base64,AAAA");
    try expectDos(null, "#element");
    try expectDos(null, "pictures/");
    try expectDos(null, "");
}

test "an image's address as a host's path" {
    var room: [128]u8 = undefined;
    try testing.expectEqualStrings("/tests/image/image.png", hostPath(placeOf("image.png").?, "/tests/image", &room).?);
    try testing.expectEqualStrings("/tests/image/../a b.png", hostPath(placeOf("../a%20b.png").?, "/tests/image", &room).?);
    try testing.expectEqualStrings("/srv/x.png", hostPath(placeOf("/srv/x.png").?, "/tests", &room).?);
    try testing.expect(hostPath(placeOf("pictures/").?, "/tests", &room) == null);
    try testing.expect(hostPath(placeOf("image.png").?, "/a/very/long/directory/name/that/does/not/fit/in/the/room/we/gave/it/at/all/or/does/it", room[0..32]) == null);
}

test "percent escapes decoded; a lone percent is itself" {
    var room: [32]u8 = undefined;
    try testing.expectEqualStrings("a b%", unescape("a%20b%", &room));
    try testing.expectEqualStrings("%zz<", unescape("%zz%3C", &room));
    try testing.expectEqualStrings("%4", unescape("%4", &room));
}
