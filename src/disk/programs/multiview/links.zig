// SPDX-License-Identifier: MIT
//! Where a link leads from the page it is on.
//!
//! A page came from a file or from the web, and a link on it is read
//! against that: `#name` is a place on the page itself; an address with
//! `http:` or `https:` in front is a page on the web wherever the link
//! is; anything else is a page beside this one - on the web, read as a
//! browser reads it against the page's own address; on a disk, a file
//! named as a path is, from the drawer the page is in, `..` its parent
//! and a leading `/` the root of its volume. What follows a `#` names a
//! place on the page it leads to.
//!
//! A link to something that is neither - a mail address, a script, a
//! telephone number - leads nowhere this program can go.

const sdk = @import("sdk");
const utility = sdk.utility;
const UtilityBase = sdk.interface.utility.UtilityBase;

/// How long a file's name or an address may be.
pub const location_most = 1023;

/// Where a page came from: a file's name, or an address on the web.
pub const Location = struct {
    text: [location_most + 1]u8 = @splat(0),
    len: usize = 0,
    web: bool = false,

    pub fn slice(where: *const Location) []const u8 {
        return where.text[0..where.len];
    }

    /// The name, ending in a NUL.
    pub fn name(where: *const Location) [*:0]const u8 {
        return @ptrCast(&where.text);
    }

    /// `text` taken, and whether it is an address on the web. False, and
    /// nothing taken, when it is too long.
    pub fn take(where: *Location, text: []const u8) bool {
        if (text.len > location_most) return false;
        @memcpy(where.text[0..text.len], text);
        where.text[text.len] = 0;
        where.len = text.len;
        where.web = isWeb(text);
        return true;
    }

    pub fn same(a: *const Location, b: *const Location) bool {
        return a.web == b.web and equal(a.slice(), b.slice());
    }

    /// Bytes added at the end. False when there is no room for them.
    fn add(where: *Location, bytes: []const u8) bool {
        if (where.len + bytes.len > location_most) return false;
        @memcpy(where.text[where.len..][0..bytes.len], bytes);
        where.len += bytes.len;
        where.text[where.len] = 0;
        return true;
    }

    fn cut(where: *Location, length: usize) void {
        where.len = length;
        where.text[length] = 0;
    }
};

/// What a link comes to.
pub const Target = union(enum) {
    /// A place on the page shown, by its name; empty for its top.
    here: []const u8,
    /// Another page, written where the caller said, and the place on it
    /// to go to - empty for none.
    page: []const u8,
    /// Somewhere this program does not go.
    nowhere,
};

/// Where `link`, on the page that came from `from`, leads. A page it
/// leads to is written into `into`; a place's name is a part of `link`.
pub fn resolve(ub: *UtilityBase, from: *const Location, link: []const u8, into: *Location) Target {
    const trimmed = trim(link);
    const hash = indexOf(trimmed, '#') orelse trimmed.len;
    const reference = trimmed[0..hash];
    const place = if (hash < trimmed.len) trimmed[hash + 1 ..] else trimmed[trimmed.len..];
    if (reference.len == 0) return .{ .here = place };

    into.* = .{};
    if (schemeOf(reference)) |scheme| {
        if (sameCase(scheme, "http") or sameCase(scheme, "https")) {
            return if (into.take(reference)) .{ .page = place } else .nowhere;
        }
        // On the web anything else is not a page; on a disk a name with
        // a colon is a file on a volume, unless it is one of the kinds
        // of address no volume is called.
        if (from.web or isNotVolume(scheme)) return .nowhere;
        return if (fileName(ub, "", reference, into)) .{ .page = place } else .nowhere;
    }
    if (from.web) {
        return if (onTheWeb(from.slice(), reference, into)) .{ .page = place } else .nowhere;
    }
    return if (fileName(ub, from.slice(), reference, into)) .{ .page = place } else .nowhere;
}

/// Whether `text` is an address on the web.
pub fn isWeb(text: []const u8) bool {
    const scheme = schemeOf(text) orelse return false;
    if (!sameCase(scheme, "http") and !sameCase(scheme, "https")) return false;
    return text.len > scheme.len + 3 and text[scheme.len + 1] == '/' and text[scheme.len + 2] == '/';
}

// --- on the web ---------------------------------------------------------------

/// `reference` read against the page at `base`, as a browser reads it.
fn onTheWeb(base: []const u8, reference: []const u8, into: *Location) bool {
    const scheme_end = indexOf(base, ':') orelse return false;
    const authority_start = scheme_end + 3;
    if (authority_start > base.len) return false;
    var authority_end = authority_start;
    while (authority_end < base.len and base[authority_end] != '/' and base[authority_end] != '?' and base[authority_end] != '#') authority_end += 1;
    var path_end = authority_end;
    while (path_end < base.len and base[path_end] != '?' and base[path_end] != '#') path_end += 1;

    into.web = true;
    if (startsWith(reference, "//")) {
        return into.add(base[0 .. scheme_end + 1]) and into.add(reference);
    }
    if (reference[0] == '?') {
        return into.add(base[0..path_end]) and into.add(reference);
    }
    const query = indexOf(reference, '?') orelse reference.len;
    if (!into.add(base[0..authority_end])) return false;
    const path_from = into.len;
    if (reference[0] == '/') {
        if (!into.add(reference[0..query])) return false;
    } else {
        // The base's drawer - its path up to its last `/` - and the
        // reference after it.
        const path = base[authority_end..path_end];
        const last = lastIndexOf(path, '/');
        if (last) |slash| {
            if (!into.add(path[0 .. slash + 1])) return false;
        } else if (!into.add("/")) return false;
        if (!into.add(reference[0..query])) return false;
    }
    removeDots(into, path_from);
    return into.add(reference[query..]);
}

/// `.` and `..` taken out of the path that starts at `from` in `into`,
/// as an address's path is read: `a/./b` is `a/b`, `a/b/../c` is `a/c`,
/// and `..` never goes above the top.
fn removeDots(into: *Location, from: usize) void {
    var read = from;
    var write = from;
    const end = into.len;
    const text = &into.text;
    while (read < end) {
        // One segment: its `/`, then up to the next.
        var stop = read + 1;
        while (stop < end and text[stop] != '/') stop += 1;
        const segment = text[read + 1 .. stop];
        const last = stop >= end;
        if (equal(segment, ".") or equal(segment, "..")) {
            if (equal(segment, "..")) {
                // Back over the segment before, and its `/`.
                while (write > from and text[write - 1] != '/') write -= 1;
                if (write > from) write -= 1;
            }
            // A path that ends in one ends in a drawer.
            if (last) {
                text[write] = '/';
                write += 1;
            }
        } else {
            text[write] = '/';
            write += 1;
            for (segment) |byte| {
                text[write] = byte;
                write += 1;
            }
        }
        read = stop;
    }
    if (write == from) {
        text[write] = '/';
        write += 1;
    }
    into.cut(write);
}

// --- on a disk -----------------------------------------------------------------

/// `reference` - a path as a link writes it, `%` escapes and all - as a
/// file's name, read from the drawer the file `base` is in.
fn fileName(ub: *UtilityBase, base: []const u8, reference: []const u8, into: *Location) bool {
    // Its query is nothing to a file, and its escapes are UTF-8's bytes,
    // which a name on the disk has as Latin-1.
    const path_only = reference[0 .. indexOf(reference, '?') orelse reference.len];
    var decoded: [location_most + 1]u8 = undefined;
    const length = ub.DecodeUrl(path_only.ptr, path_only.len, &decoded, decoded.len);
    if (length == utility.URL_BROKEN or length > decoded.len) return false;
    const latin = ub.Utf8ToLatin1(null, &decoded, length, &decoded, decoded.len);
    const path = decoded[0..latin];

    into.web = false;
    if (indexOf(path, ':') != null) return into.add(path);
    var rest = path;
    if (rest.len > 0 and rest[0] == '/') {
        // The root of the base's volume, or of the one the program is on.
        const colon = indexOf(base, ':');
        if (!into.add(if (colon) |at| base[0 .. at + 1] else ":")) return false;
        while (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    } else {
        // The drawer the base is in: up to its last `/` or `:`.
        var drawer = base.len;
        while (drawer > 0 and base[drawer - 1] != '/' and base[drawer - 1] != ':') drawer -= 1;
        if (!into.add(base[0..drawer])) return false;
    }
    while (rest.len > 0) {
        const slash = indexOf(rest, '/');
        const segment = rest[0 .. slash orelse rest.len];
        rest = if (slash) |at| rest[at + 1 ..] else rest[rest.len..];
        if (segment.len == 0 or equal(segment, ".")) continue;
        if (equal(segment, "..")) {
            if (!up(into)) return false;
            continue;
        }
        if (!into.add(segment)) return false;
        if (slash != null and !into.add("/")) return false;
    }
    return into.len > 0;
}

/// The drawer above the one `into` names. A volume's root has none; from
/// the current drawer, or from above it, it is one more `/` in front.
fn up(into: *Location) bool {
    const text = into.slice();
    if (text.len == 0 or (text[text.len - 1] == '/' and (text.len == 1 or text[text.len - 2] == '/'))) return into.add("/");
    if (text[text.len - 1] == ':') return true;
    var at = text.len;
    if (text[at - 1] == '/') at -= 1;
    while (at > 0 and text[at - 1] != '/' and text[at - 1] != ':') at -= 1;
    into.cut(at);
    return true;
}

// --- reading a link ------------------------------------------------------------

/// The scheme in front of an address - `http` of `http://...` - or null
/// when it has none: a name, then `:`, before any `/`, `?` or `#`.
fn schemeOf(text: []const u8) ?[]const u8 {
    if (text.len == 0 or !isLetter(text[0])) return null;
    for (text, 0..) |char, at| {
        if (char == ':') return if (at > 0) text[0..at] else null;
        if (isLetter(char) or (char >= '0' and char <= '9') or char == '+' or char == '-' or char == '.') continue;
        return null;
    }
    return null;
}

/// The kinds of address no volume is called: they lead nowhere this
/// program goes, from a page on a disk too.
fn isNotVolume(scheme: []const u8) bool {
    const kinds = [_][]const u8{ "mailto", "javascript", "tel", "sms", "data", "ftp", "file", "news", "irc", "about", "ssh", "git" };
    for (kinds) |kind| {
        if (sameCase(scheme, kind)) return true;
    }
    return false;
}

fn trim(text: []const u8) []const u8 {
    var first: usize = 0;
    var last = text.len;
    while (first < last and text[first] <= ' ') first += 1;
    while (last > first and text[last - 1] <= ' ') last -= 1;
    return text[first..last];
}

fn isLetter(char: u8) bool {
    return (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z');
}

fn indexOf(text: []const u8, wanted: u8) ?usize {
    for (text, 0..) |char, at| {
        if (char == wanted) return at;
    }
    return null;
}

fn lastIndexOf(text: []const u8, wanted: u8) ?usize {
    var at = text.len;
    while (at > 0) {
        at -= 1;
        if (text[at] == wanted) return at;
    }
    return null;
}

fn startsWith(text: []const u8, start: []const u8) bool {
    return text.len >= start.len and equal(text[0..start.len], start);
}

fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// Whether `text` is `lower`, its letters' case aside.
fn sameCase(text: []const u8, lower: []const u8) bool {
    if (text.len != lower.len) return false;
    for (text, lower) |char, want| {
        const folded = if (char >= 'A' and char <= 'Z') char + 32 else char;
        if (folded != want) return false;
    }
    return true;
}
