// SPDX-License-Identifier: MIT
//! Playlist files: M3U and M3U8, and PLS, read; M3U written.
//!
//! **M3U** is a line for each song, a file's name or a station's address,
//! in the order they play. A line `#EXTINF:<seconds>,<name>` before one
//! says how long it is (-1: not known) and what it is called; between the
//! length and the comma it may carry attributes, `key="value"`, of which
//! `tvg-logo` - a picture of the station, an address - is read. Every
//! other line that starts with `#` is a comment. The text is UTF-8 when
//! the whole of it is, Latin-1 otherwise (`utf8`); a mark of UTF-8 at
//! its start is passed over.
//!
//! **PLS** is the form a station's site hands out: a `[playlist]` line,
//! then numbered keys in any case and any order - `File1=` the address or
//! the file, `Title1=` its name, `Length1=` its seconds. A text whose
//! first line is `[playlist]` is read as PLS, whatever its name.
//!
//! **HLS** - a list of a stream's pieces, `#EXT-X-` lines among its
//! comments - is no list of songs: `isHls` tells it apart, and its
//! pieces are not played.
//!
//! `Reader` hands out each `Item` in turn as slices of the text as it
//! stands, not yet brought to Latin-1. `locate` joins a location to the
//! drawer of the list it came from, `relative` is the other way, and
//! `itemLines` writes an item as M3U, in UTF-8, after `header`.
//! `firstAddress` is the station a list a station's address answered with
//! names, and `namesList` whether an address ends as a list does. Nothing
//! here opens a file: the host tests hold all of it.

const icy = @import("icy.zig");

/// What every M3U the Player writes starts with.
pub const header = "#EXTM3U\n";

/// The kinds of list a file's name says it is.
pub const Kind = enum { m3u, pls };

/// The file requester's pattern for lists, and the one for saving.
pub const pattern = "#?.(m3u|m3u8|pls)";
pub const save_pattern = "#?.(m3u|m3u8)";

/// What `name` ends in says of it: a list, and which; null for any other
/// file.
pub fn kindOf(name: []const u8) ?Kind {
    if (endsWith(name, ".m3u") or endsWith(name, ".m3u8")) return .m3u;
    if (endsWith(name, ".pls")) return .pls;
    return null;
}

/// Whether the address `url` ends as a list's name does - its query
/// and its fragment left off: a station's site that names its list so
/// may still say it is plain text.
pub fn namesList(url: []const u8) bool {
    var end: usize = 0;
    while (end < url.len and url[end] != '?' and url[end] != '#') end += 1;
    return kindOf(url[0..end]) != null;
}

/// Whether `text` is HLS: a list of a stream's pieces, not of songs.
pub fn isHls(text: []const u8) bool {
    var at: usize = 0;
    while (at + 7 <= text.len) : (at += 1) {
        if (startsWith(text[at..], "#EXT-X-")) return true;
    }
    return false;
}

/// The first station's address the list `text` names: what a station's
/// address that answers with a list stands for. Null when it names none.
pub fn firstAddress(text: []const u8) ?[]const u8 {
    var reader = Reader.init(text);
    while (reader.next()) |item| {
        if (isUrl(item.location)) return item.location;
    }
    return null;
}

/// One song of a list.
pub const Item = struct {
    /// A file's name, as the list writes it, or a station's address.
    location: []const u8,
    /// Its name; empty when the list gives none.
    title: []const u8 = "",
    /// How long it is, in seconds; null when the list does not say.
    seconds: ?u32 = null,
    /// A picture of it, an address; empty when there is none.
    logo: []const u8 = "",
};

pub const Reader = struct {
    text: []const u8,
    form: Kind,
    /// The text is UTF-8: its names are brought to Latin-1 as such.
    utf8: bool,
    at: usize = 0,

    pub fn init(whole: []const u8) Reader {
        var text = whole;
        if (startsWith(text, "\xEF\xBB\xBF")) text = text[3..];
        var reader = Reader{ .text = text, .form = .m3u, .utf8 = icy.isUtf8(text) };
        var first = reader;
        while (first.nextLine()) |line| {
            const trimmed = trim(line);
            if (trimmed.len == 0) continue;
            if (sameWord(trimmed, "[playlist]")) reader.form = .pls;
            break;
        }
        return reader;
    }

    /// The next song; null after the last.
    pub fn next(reader: *Reader) ?Item {
        return switch (reader.form) {
            .m3u => reader.nextM3u(),
            .pls => reader.nextPls(),
        };
    }

    fn nextM3u(reader: *Reader) ?Item {
        var described: ?Item = null;
        while (reader.nextLine()) |line| {
            const trimmed = trim(line);
            if (trimmed.len == 0) continue;
            if (startsWith(trimmed, "#EXTINF:")) {
                described = extInf(trimmed["#EXTINF:".len..]);
                continue;
            }
            if (trimmed[0] == '#') continue;
            var item = described orelse Item{ .location = "" };
            item.location = trimmed;
            return item;
        }
        return null;
    }

    fn nextPls(reader: *Reader) ?Item {
        while (reader.nextLine()) |line| {
            const pair = keyed(trim(line)) orelse continue;
            if (!startsWith(pair.key, "file")) continue;
            const number = pair.key["file".len..];
            if (number.len == 0 or !allDigits(number)) continue;
            var item = Item{ .location = pair.value };
            if (reader.value("title", number)) |title| item.title = title;
            if (reader.value("length", number)) |length| item.seconds = seconds(length);
            return item;
        }
        return null;
    }

    /// The value of PLS's key `word` `number` - `Title3` - wherever it
    /// stands in the text.
    fn value(reader: *const Reader, word: []const u8, number: []const u8) ?[]const u8 {
        var all = Reader{ .text = reader.text, .form = .pls, .utf8 = reader.utf8 };
        while (all.nextLine()) |line| {
            const pair = keyed(trim(line)) orelse continue;
            if (pair.key.len != word.len + number.len) continue;
            if (!startsWith(pair.key, word)) continue;
            if (!same(pair.key[word.len..], number)) continue;
            return pair.value;
        }
        return null;
    }

    /// The next line, without its line end; null at the text's end.
    fn nextLine(reader: *Reader) ?[]const u8 {
        if (reader.at >= reader.text.len) return null;
        const start = reader.at;
        var end = start;
        while (end < reader.text.len and reader.text[end] != '\n') end += 1;
        reader.at = end + 1;
        return reader.text[start..end];
    }
};

/// What follows `#EXTINF:`: the length, attributes, then after the first
/// comma outside quotes the name.
fn extInf(text: []const u8) Item {
    var item = Item{ .location = "" };
    var at: usize = 0;
    while (at < text.len and text[at] == ' ') at += 1;
    const length_start = at;
    if (at < text.len and text[at] == '-') at += 1;
    while (at < text.len and (isDigit(text[at]) or text[at] == '.')) at += 1;
    item.seconds = seconds(text[length_start..at]);
    var quoted = false;
    var comma = text.len;
    var scan = at;
    while (scan < text.len) : (scan += 1) {
        if (text[scan] == '"') quoted = !quoted;
        if (text[scan] == ',' and !quoted) {
            comma = scan;
            break;
        }
    }
    item.logo = attribute(text[at..comma], "tvg-logo") orelse "";
    if (comma < text.len) item.title = trim(text[comma + 1 ..]);
    return item;
}

/// The value of attribute `name` - `name="value"` - among `text`'s.
fn attribute(text: []const u8, name: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (at + name.len + 2 <= text.len) : (at += 1) {
        if (!startsWith(text[at..], name)) continue;
        if (at > 0 and text[at - 1] != ' ') continue;
        var from = at + name.len;
        if (from + 1 >= text.len or text[from] != '=' or text[from + 1] != '"') continue;
        from += 2;
        var end = from;
        while (end < text.len and text[end] != '"') end += 1;
        return text[from..end];
    }
    return null;
}

/// A length in seconds, a fraction cut off: null for none, or one below
/// zero.
fn seconds(text: []const u8) ?u32 {
    const trimmed = trim(text);
    if (trimmed.len == 0 or !isDigit(trimmed[0])) return null;
    var result: u32 = 0;
    for (trimmed) |char| {
        if (!isDigit(char)) break;
        result = result *| 10 +| (char - '0');
    }
    return result;
}

const Pair = struct { key: []const u8, value: []const u8 };

/// A `key=value` line taken apart, both trimmed.
fn keyed(text: []const u8) ?Pair {
    for (text, 0..) |char, at| {
        if (char == '=') return .{ .key = trim(text[0..at]), .value = trim(text[at + 1 ..]) };
    }
    return null;
}

/// Where `location`, read from a list in `drawer`, is - into `into`: a
/// station's address and a name with a volume as they are; any other
/// taken from the drawer, `./` as the drawer itself, `../` as its
/// parent, a leading `/` as its volume's root. A backslash is taken as a
/// `/`: lists written on other machines part their drawers so. Null when
/// it does not fit.
pub fn locate(drawer: []const u8, location: []const u8, into: []u8) ?[]const u8 {
    if (isUrl(location)) return copied(location, into);
    var rest = location;
    var length: usize = 0;
    if (indexOfChar(location, ':') == null) {
        length = copiedLength(drawer, into) orelse return null;
        if (rest.len > 0 and isSlash(rest[0])) {
            length = if (indexOfChar(into[0..length], ':')) |colon| colon + 1 else 0;
            while (rest.len > 0 and isSlash(rest[0])) rest = rest[1..];
        }
        while (true) {
            if (rest.len >= 2 and rest[0] == '.' and isSlash(rest[1])) {
                rest = rest[2..];
            } else if (rest.len >= 3 and rest[0] == '.' and rest[1] == '.' and isSlash(rest[2])) {
                rest = rest[3..];
                length = parentOf(into[0..length]);
            } else break;
        }
        if (length > 0 and into[length - 1] != ':' and into[length - 1] != '/') {
            if (length == into.len) return null;
            into[length] = '/';
            length += 1;
        }
    }
    if (length + rest.len > into.len) return null;
    for (rest, 0..) |char, at| into[length + at] = if (char == '\\') '/' else char;
    return into[0 .. length + rest.len];
}

/// How much of `path` is its drawer's parent: up to its last `/`, or its
/// volume when it has none; a volume's root is its own.
fn parentOf(path: []const u8) usize {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    while (end > 0 and path[end - 1] != '/' and path[end - 1] != ':') end -= 1;
    if (end > 0 and path[end - 1] == '/') end -= 1;
    return end;
}

/// `path` as a list in `drawer` writes it: what follows the drawer when
/// it lies within it, in any case; null when it does not, and the whole
/// name is written.
pub fn relative(drawer: []const u8, path: []const u8) ?[]const u8 {
    if (drawer.len == 0 or path.len <= drawer.len) return null;
    if (!startsWith(path, drawer)) return null;
    const last = drawer[drawer.len - 1];
    if (last == ':' or last == '/') return path[drawer.len..];
    if (path[drawer.len] != '/' or path.len == drawer.len + 1) return null;
    return path[drawer.len + 1 ..];
}

/// The bytes `itemLines` writes for `item` at most.
pub fn itemLength(item: Item) usize {
    return "#EXTINF:4294967295 tvg-logo=\"\",\n\n".len + 2 * (item.title.len + item.logo.len + item.location.len);
}

/// `item` as M3U into `into` (`itemLength` bytes will do), its Latin-1
/// in UTF-8: an `#EXTINF` line when it has a name, a length or a
/// picture, then its location. How many bytes.
pub fn itemLines(item: Item, into: []u8) usize {
    var at: usize = 0;
    if (item.title.len > 0 or item.seconds != null or item.logo.len > 0) {
        at = put(into, at, "#EXTINF:");
        if (item.seconds) |count| at = putNumber(into, at, count) else at = put(into, at, "-1");
        if (item.logo.len > 0) {
            at = put(into, at, " tvg-logo=\"");
            at = putUtf8(into, at, item.logo);
            at = put(into, at, "\"");
        }
        at = put(into, at, ",");
        at = putUtf8(into, at, item.title);
        at = put(into, at, "\n");
    }
    at = putUtf8(into, at, item.location);
    return put(into, at, "\n");
}

fn put(into: []u8, at: usize, text: []const u8) usize {
    @memcpy(into[at..][0..text.len], text);
    return at + text.len;
}

/// Latin-1 `text` as UTF-8: a byte past ASCII as two.
fn putUtf8(into: []u8, at: usize, text: []const u8) usize {
    var out = at;
    for (text) |char| {
        if (char < 0x80) {
            into[out] = char;
            out += 1;
        } else {
            into[out] = 0xC0 | (char >> 6);
            into[out + 1] = 0x80 | (char & 0x3F);
            out += 2;
        }
    }
    return out;
}

fn putNumber(into: []u8, at: usize, number: u32) usize {
    var digits: [10]u8 = undefined;
    var count: usize = 0;
    var left = number;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    for (0..count) |i| into[at + i] = digits[count - 1 - i];
    return at + count;
}

/// Whether `text` is a station's address, `http://` or `https://` in any
/// case.
fn isUrl(text: []const u8) bool {
    return startsWith(text, "http://") or startsWith(text, "https://");
}

fn copied(text: []const u8, into: []u8) ?[]const u8 {
    const length = copiedLength(text, into) orelse return null;
    return into[0..length];
}

fn copiedLength(text: []const u8, into: []u8) ?usize {
    if (text.len > into.len) return null;
    @memcpy(into[0..text.len], text);
    return text.len;
}

fn isSlash(char: u8) bool {
    return char == '/' or char == '\\';
}

fn isDigit(char: u8) bool {
    return char >= '0' and char <= '9';
}

fn allDigits(text: []const u8) bool {
    for (text) |char| if (!isDigit(char)) return false;
    return true;
}

fn indexOfChar(text: []const u8, wanted: u8) ?usize {
    for (text, 0..) |char, at| if (char == wanted) return at;
    return null;
}

/// `text` without spaces, tabs and a carriage return at either end.
fn trim(text: []const u8) []const u8 {
    var start: usize = 0;
    var end = text.len;
    while (start < end and isBlank(text[start])) start += 1;
    while (end > start and isBlank(text[end - 1])) end -= 1;
    return text[start..end];
}

fn isBlank(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\r';
}

fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + 32 else char;
}

/// Whether `text` starts with `prefix`, in any case.
fn startsWith(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    for (text[0..prefix.len], prefix) |got, want| {
        if (lower(got) != lower(want)) return false;
    }
    return true;
}

fn endsWith(text: []const u8, suffix: []const u8) bool {
    if (text.len < suffix.len) return false;
    return startsWith(text[text.len - suffix.len ..], suffix);
}

fn sameWord(text: []const u8, word: []const u8) bool {
    return text.len == word.len and startsWith(text, word);
}

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
