// SPDX-License-Identifier: MIT
//! Names and paths: what dos is given for a server's names, and the
//! share's path for a dos one.
//!
//! **A server's name is UTF-16; a dos name is UTF-8**, up to
//! `dos.name_max` bytes. A name that is whole UTF-16 - no surrogate
//! without its pair - and whose UTF-8 fits is given as it is. Any other
//! is given as a **stand-in**: its characters in UTF-8, a broken one or
//! a control `_`, the part before the extension cut where a character
//! starts to make room, and `=` and four hex digits of the name's hash
//! put before the extension, as fat-handler shows such a name on exFAT.
//! The hash is exFAT's NameHash over the name as the server spells it,
//! so the stand-in is the same each time the directory is listed. A
//! stand-in opens what it stands for: a path the server does not know
//! that has a name of a stand-in's shape in it is looked for again, each
//! such name compared with the stand-ins of the entries in its directory
//! (`fs.zig`). A name dos hands over is UTF-8, and one that is not is
//! refused before it reaches the server.
//!
//! **A path** is the share's: the names from the share's root, `\`
//! between them, in UTF-16LE. A dos path is taken from the lock it is
//! relative to as dos takes it: a device or volume in front is dropped, a
//! `/` with nothing before it goes up a directory, and a path that ends
//! in `/` names the directory it ends in. A name may not hold what the
//! server would read as more than a name - `\`, or the `:` that names a
//! stream.

const sdk = @import("sdk");
const dos = sdk.dos;
const utf8 = sdk.utility.utf8;

/// The longest name dos is given, and the longest path a lock holds, in
/// UTF-16 units.
pub const name_max: usize = dos.name_max;
pub const path_units: usize = dos.path_max;

/// The longest extension a stand-in keeps, its dot included.
const ext_max: usize = 16;
/// `tag_mark` and four hex digits.
const tag_len: usize = 5;
/// What starts the tag: a character a dos name may hold that is no
/// pattern character, so a stand-in typed back names the file.
const tag_mark = '=';

/// The `index`th UTF-16 unit of a name in UTF-16LE.
pub fn unitAt(name: []const u8, index: usize) u16 {
    return @as(u16, name[2 * index]) | @as(u16, name[2 * index + 1]) << 8;
}

/// A server's name (UTF-16LE) in UTF-8 onto `into` from `len`: a
/// character past U+FFFF from its surrogate pair, as many whole ones as
/// fit before `end`; the new length, or null for a surrogate without its
/// pair when `strict`, which a stand-in shows as `_` instead, as it does
/// a control.
fn written(name: []const u8, into: []u8, len: usize, end: usize, strict: bool) ?usize {
    const count = name.len / 2;
    var index: usize = 0;
    var at = len;
    while (index < count) {
        var char: u32 = unitAt(name, index);
        index += 1;
        if (char >= 0xD800 and char <= 0xDBFF and index < count and unitAt(name, index) >= 0xDC00 and unitAt(name, index) <= 0xDFFF) {
            char = 0x10000 + ((char - 0xD800) << 10) + (unitAt(name, index) - 0xDC00);
            index += 1;
        } else if (char >= 0xD800 and char <= 0xDFFF) {
            if (strict) return null;
            char = '_';
        } else if (char < 0x20 and !strict) {
            char = '_';
        }
        var bytes: [4]u8 = undefined;
        const taken = utf8.encode(char, &bytes);
        if (at + taken > end) {
            if (strict) return null;
            break;
        }
        @memcpy(into[at..][0..taken], bytes[0..taken]);
        at += taken;
    }
    return at;
}

/// Whether a server's name can be given to dos as it is.
pub fn fits(name: []const u8) bool {
    var buffer: [name_max]u8 = undefined;
    return name.len >= 2 and written(name, &buffer, 0, buffer.len, true) != null;
}

/// The hash a stand-in carries: exFAT's NameHash over the name's units.
pub fn hashOf(name: []const u8) u16 {
    var units: [2 * name_max]u16 = undefined;
    const count = @min(name.len / 2, units.len);
    for (units[0..count], 0..) |*unit, index| unit.* = unitAt(name, index);
    return dos.fat.exfatNameHash(units[0..count]);
}

/// The name dos is given for a server's name (UTF-16LE): the name in
/// UTF-8 if it fits, else its stand-in.
pub fn toDos(name: []const u8, into: *[name_max]u8) []const u8 {
    if (name.len >= 2) {
        if (written(name, into, 0, into.len, true)) |len| return into[0..len];
    }
    return standIn(name, into);
}

/// The stand-in for a name: see the file's header.
pub fn standIn(name: []const u8, into: *[name_max]u8) []const u8 {
    const count = name.len / 2;
    // The extension: from the last dot on, if the dot is not the name's
    // first character and what follows it is short.
    var ext_start = count;
    var at = count;
    while (at > 1) {
        at -= 1;
        if (unitAt(name, at) == '.') {
            if (count - at <= ext_max and count - at > 1) ext_start = at;
            break;
        }
    }
    // The extension's bytes first, to know the room the rest has: at
    // most four a unit.
    var ext_bytes: [ext_max * 4]u8 = undefined;
    const ext_len = written(name[2 * ext_start ..], &ext_bytes, 0, ext_bytes.len, false).?;
    var len = written(name[0 .. 2 * ext_start], into, 0, name_max - tag_len - ext_len, false).?;
    const hash = hashOf(name);
    const digits = "0123456789ABCDEF";
    into[len] = tag_mark;
    for (0..4) |digit| into[len + 1 + digit] = digits[(hash >> @intCast(12 - digit * 4)) & 0xF];
    len += tag_len;
    @memcpy(into[len..][0..ext_len], ext_bytes[0..ext_len]);
    return into[0 .. len + ext_len];
}

/// A server's text (UTF-16LE) - a share's comment - in UTF-8 to be
/// shown, a NUL after it: as many whole characters as fit, a control or
/// a broken surrogate `_`.
pub fn shown(text: []const u8, into: []u8) []const u8 {
    if (into.len == 0) return into[0..0];
    const length = written(text, into, 0, into.len - 1, false).?;
    into[length] = 0;
    return into[0..length];
}

/// A name of a share's path (UTF-16LE) in UTF-8, as dos would be given
/// it, or null when it is no whole UTF-16 or does not fit.
pub fn textOf(name: []const u8, into: *[name_max]u8) ?[]const u8 {
    const len = written(name, into, 0, into.len, true) orelse return null;
    return into[0..len];
}

/// Whether a dos name has the shape of a stand-in: `=` and four hex
/// digits before the extension, or at its end.
pub fn looksStandIn(name: []const u8) bool {
    var end = name.len;
    var at = name.len;
    while (at > 0) {
        at -= 1;
        if (name[at] == '.') {
            end = at;
            break;
        }
    }
    if (!tagAt(name, end)) return tagAt(name, name.len);
    return true;
}

fn tagAt(name: []const u8, end: usize) bool {
    if (end < tag_len or name[end - tag_len] != tag_mark) return false;
    for (name[end - 4 .. end]) |char| switch (char) {
        '0'...'9', 'A'...'F', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// Whether two dos names are the same name, case aside: by Unicode's
/// simple case folding, as every name is compared.
pub fn same(one: []const u8, other: []const u8) bool {
    return sdk.utility.unicode.equalFolded(one, other);
}

/// Whether a server's name (UTF-16LE) is a stand-in's original: one that
/// does not fit and whose stand-in is `wanted`.
pub fn standsFor(name: []const u8, wanted: []const u8) bool {
    if (fits(name)) return false;
    var buffer: [name_max]u8 = undefined;
    return same(standIn(name, &buffer), wanted);
}

// --- paths ------------------------------------------------------------------------

pub const Error = error{
    /// Up past the share's root.
    NotFound,
    /// A name the server would read as more than a name, or a path too
    /// long.
    InvalidName,
};

/// A share's path being made: UTF-16LE.
pub const Path = struct {
    bytes: [2 * path_units]u8 = undefined,
    len: usize = 0,

    pub fn slice(path: *const Path) []const u8 {
        return path.bytes[0..path.len];
    }

    pub fn set(path: *Path, from: []const u8) Error!void {
        if (from.len > path.bytes.len) return error.InvalidName;
        @memcpy(path.bytes[0..from.len], from);
        path.len = from.len;
    }

    /// A name added at the end, in UTF-16LE: its UTF-8 characters, one
    /// past U+FFFF as its surrogate pair. Never more than two bytes for
    /// each of the name's. InvalidName for a name that is no UTF-8.
    pub fn push(path: *Path, name: []const u8) Error!void {
        if (!utf8.valid(name)) return error.InvalidName;
        const separator: usize = if (path.len > 0) 2 else 0;
        if (path.len + separator + 2 * name.len > path.bytes.len) return error.InvalidName;
        if (separator != 0) {
            path.bytes[path.len] = '\\';
            path.bytes[path.len + 1] = 0;
            path.len += 2;
        }
        var at: usize = 0;
        while (at < name.len) {
            const char = utf8.next(name, &at);
            if (char > 0xFFFF) {
                const above = char - 0x10000;
                path.putUnit(@intCast(0xD800 + (above >> 10)));
                path.putUnit(@intCast(0xDC00 + (above & 0x3FF)));
            } else path.putUnit(@intCast(char));
        }
    }

    fn putUnit(path: *Path, unit: u16) void {
        path.bytes[path.len] = @truncate(unit);
        path.bytes[path.len + 1] = @intCast(unit >> 8);
        path.len += 2;
    }

    /// UTF-16LE bytes added at the end, as they are.
    pub fn append(path: *Path, bytes: []const u8) Error!void {
        if (path.len + bytes.len > path.bytes.len) return error.InvalidName;
        @memcpy(path.bytes[path.len..][0..bytes.len], bytes);
        path.len += bytes.len;
    }

    /// The last name taken off; up from the root is an error.
    pub fn pop(path: *Path) Error!void {
        if (path.len == 0) return error.NotFound;
        path.len = parentLength(path.slice());
    }

    /// The name at `start` (a byte offset, the first of a name) put in
    /// place of what is there up to the next `\`: a stand-in replaced
    /// by the name it stands for (UTF-16LE).
    pub fn replace(path: *Path, start: usize, name: []const u8) Error!void {
        const end = nameEnd(path.slice(), start);
        const after = path.len - end;
        if (start + name.len + after > path.bytes.len) return error.InvalidName;
        const moved_to = start + name.len;
        if (moved_to > end) {
            var at = after;
            while (at > 0) {
                at -= 1;
                path.bytes[moved_to + at] = path.bytes[end + at];
            }
        } else {
            for (0..after) |at| path.bytes[moved_to + at] = path.bytes[end + at];
        }
        @memcpy(path.bytes[start..][0..name.len], name);
        path.len = moved_to + after;
    }
};

/// Where a path's parent ends: before its last `\`, or 0.
pub fn parentLength(path: []const u8) usize {
    var at = path.len;
    while (at >= 2) {
        at -= 2;
        if (path[at] == '\\' and path[at + 1] == 0) return at;
    }
    return 0;
}

/// Where the name that begins at `start` ends.
pub fn nameEnd(path: []const u8, start: usize) usize {
    var at = start;
    while (at + 1 < path.len) : (at += 2) {
        if (path[at] == '\\' and path[at + 1] == 0) return at;
    }
    return path.len;
}

/// The last name of a path (UTF-16LE).
pub fn lastName(path: []const u8) []const u8 {
    const parent = parentLength(path);
    return if (parent == 0) path else path[parent + 2 ..];
}

/// `name` (a dos path) from the directory `base` (a share's path) into
/// `into`, as the file's header says.
pub fn resolve(base: []const u8, name: []const u8, into: *Path) Error!void {
    try into.set(base);
    var rest = name;
    for (rest, 0..) |char, at| if (char == ':') {
        rest = rest[at + 1 ..];
        break;
    };
    while (true) {
        var slash: ?usize = null;
        for (rest, 0..) |char, at| if (char == '/') {
            slash = at;
            break;
        };
        const cut = slash orelse {
            if (rest.len > 0) try pushName(into, rest);
            return;
        };
        const part = rest[0..cut];
        rest = rest[cut + 1 ..];
        if (part.len == 0) {
            try into.pop();
        } else {
            try pushName(into, part);
        }
    }
}

fn pushName(path: *Path, name: []const u8) Error!void {
    if (name.len > name_max) return error.InvalidName;
    for (name) |char| switch (char) {
        0...0x1F, '\\', ':' => return error.InvalidName,
        else => {},
    };
    try path.push(name);
}

/// Whether two share paths are the same, case aside: unit by unit
/// through Unicode's simple folding, a surrogate as it is.
pub fn samePath(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (0..one.len / 2) |index| {
        const unit_one = unitAt(one, index);
        const unit_other = unitAt(other, index);
        if (unit_one == unit_other) continue;
        if (unit_one >= 0xD800 and unit_one <= 0xDFFF) return false;
        if (sdk.utility.unicode.fold(unit_one) != sdk.utility.unicode.fold(unit_other)) return false;
    }
    return true;
}

/// Whether `path` is `dir` or below it, case aside; everything is below
/// the root.
pub fn within(path: []const u8, dir: []const u8) bool {
    if (dir.len == 0) return true;
    if (path.len < dir.len or !samePath(path[0..dir.len], dir)) return false;
    return path.len == dir.len or (path[dir.len] == '\\' and path[dir.len + 1] == 0);
}

// --- tests ------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

fn utf16(comptime text: []const u8) []const u8 {
    const units = comptime std.unicode.utf8ToUtf16LeStringLiteral(text);
    return std.mem.sliceAsBytes(units);
}

test "a name is given in UTF-8, one that is no whole UTF-16 as its stand-in" {
    var into: [name_max]u8 = undefined;
    try testing.expectEqualStrings("Café.txt", toDos(utf16("Café.txt"), &into));
    try testing.expectEqualStrings("日本.txt", toDos(utf16("日本.txt"), &into));
    try testing.expectEqualStrings("\u{1F600}x", toDos(utf16("\u{1F600}x"), &into));
    const broken = [_]u8{ 'a', 0, 0x00, 0xD8, '.', 0, 't', 0, 'x', 0, 't', 0 };
    try testing.expect(!fits(&broken));
    const shown_name = toDos(&broken, &into);
    try testing.expect(std.mem.startsWith(u8, shown_name, "a_="));
    try testing.expect(std.mem.endsWith(u8, shown_name, ".txt"));
    try testing.expect(looksStandIn(shown_name));
    try testing.expect(standsFor(&broken, shown_name));
    try testing.expect(!standsFor(utf16("a.txt"), shown_name));
    // The hash is exFAT's over the units as they are.
    const units = [_]u16{ 'a', 0xD800, '.', 't', 'x', 't' };
    var expected: [name_max]u8 = undefined;
    const hash = dos.fat.exfatNameHash(&units);
    _ = std.fmt.bufPrint(&expected, "a_={X:0>4}.txt", .{hash}) catch unreachable;
    try testing.expectEqualStrings(expected[0..shown_name.len], shown_name);
}

test "a server's text shown: UTF-8, cut where a character starts, controls as _" {
    var into: [8]u8 = undefined;
    try testing.expectEqualStrings("Prüf_x", shown(utf16("Prüf\tx"), &into));
    try testing.expectEqualStrings("日本", shown(utf16("日本語"), &into));
    try testing.expectEqual(@as(u8, 0), into[6]);
}

test "stand-ins: a name too long for dos, cut where a character starts" {
    var into: [name_max]u8 = undefined;
    var long: [2 * 300]u8 = undefined;
    for (0..300) |index| {
        long[2 * index] = 'L';
        long[2 * index + 1] = 0;
    }
    const given = toDos(&long, &into);
    try testing.expectEqual(name_max, given.len);
    try testing.expect(looksStandIn(given));
    // 100 characters of three bytes: 83 fit before the tag.
    var wide: [2 * 100]u8 = undefined;
    for (0..100) |index| {
        wide[2 * index] = 0xE5;
        wide[2 * index + 1] = 0x65;
    }
    const cut = toDos(&wide, &into);
    try testing.expect(utf8.valid(cut));
    try testing.expectEqual(@as(usize, 83 * 3 + tag_len), cut.len);
    try testing.expect(looksStandIn(cut));
    try testing.expect(!looksStandIn("plain.txt"));
    try testing.expect(!looksStandIn("x=12G4.txt"));
}

test "a dos path from a lock's: devices dropped, / goes up, a trailing / is the directory" {
    var path: Path = .{};
    try resolve(utf16("a\\b"), "c", &path);
    try testing.expectEqualSlices(u8, utf16("a\\b\\c"), path.slice());
    try resolve(utf16("a\\b"), "/c", &path);
    try testing.expectEqualSlices(u8, utf16("a\\c"), path.slice());
    try resolve(utf16("a\\b"), "//", &path);
    try testing.expectEqualSlices(u8, utf16(""), path.slice());
    try resolve(utf16(""), "NAS:x/y/", &path);
    try testing.expectEqualSlices(u8, utf16("x\\y"), path.slice());
    try resolve(utf16("a"), "", &path);
    try testing.expectEqualSlices(u8, utf16("a"), path.slice());
    try testing.expectError(error.NotFound, resolve(utf16(""), "/", &path));
    try testing.expectError(error.InvalidName, resolve(utf16(""), "a\\b", &path));
    // The first colon ends a device's name; one after it would name a
    // stream.
    try testing.expectError(error.InvalidName, resolve(utf16(""), "NAS:file:stream", &path));
}

test "a name in a path replaced, longer and shorter; parents and last names" {
    var path: Path = .{};
    try path.set(utf16("one\\t=1234\\three"));
    try path.replace(8, utf16("twotwotwo"));
    try testing.expectEqualSlices(u8, utf16("one\\twotwotwo\\three"), path.slice());
    try path.replace(8, utf16("2"));
    try testing.expectEqualSlices(u8, utf16("one\\2\\three"), path.slice());
    try testing.expectEqual(@as(usize, 10), parentLength(path.slice()));
    try testing.expectEqualSlices(u8, utf16("three"), lastName(path.slice()));
    try testing.expectEqualSlices(u8, utf16("x"), lastName(utf16("x")));
    try testing.expect(samePath(utf16("Ab\\ä"), utf16("aB\\Ä")));
    try testing.expect(samePath(utf16("Ωμέγα"), utf16("ΩΜΈΓΑ")));
    try testing.expect(!samePath(utf16("ab"), utf16("abc")));
}

test "a dos name pushed: past U+FFFF as a pair, one that is no UTF-8 refused" {
    var path: Path = .{};
    try testing.expectError(error.InvalidName, path.push("Gr\xFCn"));
    try testing.expectEqual(@as(usize, 0), path.len);
    try path.push("Grün");
    try testing.expectEqualSlices(u8, utf16("Grün"), path.slice());
    try path.push("\u{1F600}€");
    try testing.expectEqualSlices(u8, utf16("Grün\\\u{1F600}€"), path.slice());
    try testing.expect(same("Grün", "GRÜN"));
    try testing.expect(!same("Gr\xFCn", "GRÜN"));
    try testing.expect(!same("Grün", "Grun"));
}

test "a path within a directory, and one added to" {
    try testing.expect(within(utf16("a\\b\\c"), utf16("A\\b")));
    try testing.expect(within(utf16("a\\b"), utf16("a\\B")));
    try testing.expect(within(utf16("a"), utf16("")));
    try testing.expect(!within(utf16("a\\bc"), utf16("a\\b")));
    try testing.expect(!within(utf16("a"), utf16("a\\b")));
    var path: Path = .{};
    try path.set(utf16("x"));
    try path.append(utf16("\\y"));
    try testing.expectEqualSlices(u8, utf16("x\\y"), path.slice());
}
