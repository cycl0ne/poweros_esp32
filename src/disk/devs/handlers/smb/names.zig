// SPDX-License-Identifier: MIT
//! Names and paths: what dos is given for a server's names, and the
//! share's path for a dos one.
//!
//! **A server's name is UTF-16; a dos name is Latin-1**, up to
//! `dos.name_max` bytes. A name of Latin-1 characters that fits is given
//! as it is. Any other is given as a **stand-in**: its Latin-1 characters
//! kept, every other made `_`, the part before the extension cut to make
//! room, and `=` and four hex digits of the name's hash put before the
//! extension - `日本.txt` is `__=4F2A.txt`, as fat-handler shows a name on
//! exFAT. The hash is exFAT's NameHash over the name as the server spells
//! it, so the stand-in is the same each time the directory is listed. A
//! stand-in opens what it stands for: a path the server does not know
//! that has a name of a stand-in's shape in it is looked for again, each
//! such name compared with the stand-ins of the entries in its directory
//! (`fs.zig`).
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

/// Whether a server's name can be given to dos as it is.
pub fn fits(name: []const u8) bool {
    const count = name.len / 2;
    if (count == 0 or count > name_max) return false;
    for (0..count) |index| if (unitAt(name, index) > 0xFF) return false;
    return true;
}

/// The hash a stand-in carries: exFAT's NameHash over the name's units.
pub fn hashOf(name: []const u8) u16 {
    var units: [2 * name_max]u16 = undefined;
    const count = @min(name.len / 2, units.len);
    for (units[0..count], 0..) |*unit, index| unit.* = unitAt(name, index);
    return dos.fat.exfatNameHash(units[0..count]);
}

/// The name dos is given for a server's name (UTF-16LE): the name if it
/// fits, else its stand-in.
pub fn toDos(name: []const u8, into: *[name_max]u8) []const u8 {
    const count = name.len / 2;
    if (fits(name)) {
        for (0..count) |index| into[index] = @intCast(unitAt(name, index));
        return into[0..count];
    }
    return standIn(name, into);
}

/// A character as dos sees it in a stand-in.
fn shown(unit: u16) u8 {
    return if (unit <= 0xFF and unit >= 0x20) @intCast(unit) else '_';
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
    const ext_count = count - ext_start;
    const room = name_max - tag_len - ext_count;
    const base_count = @min(ext_start, room);

    var len: usize = 0;
    for (0..base_count) |index| {
        into[len] = shown(unitAt(name, index));
        len += 1;
    }
    const hash = hashOf(name);
    const digits = "0123456789ABCDEF";
    into[len] = tag_mark;
    for (0..4) |digit| into[len + 1 + digit] = digits[(hash >> @intCast(12 - digit * 4)) & 0xF];
    len += tag_len;
    for (ext_start..count) |index| {
        into[len] = shown(unitAt(name, index));
        len += 1;
    }
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

/// A Latin-1 character in capitals, as dos compares names.
pub fn upper(char: u8) u8 {
    return switch (char) {
        'a'...'z' => char - 0x20,
        0xE0...0xF6, 0xF8...0xFE => char - 0x20,
        else => char,
    };
}

/// Whether two dos names are the same name, case aside.
pub fn same(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |mine, theirs| if (upper(mine) != upper(theirs)) return false;
    return true;
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

    /// A name added at the end, Latin-1 widened.
    pub fn push(path: *Path, name: []const u8) Error!void {
        const separator: usize = if (path.len > 0) 2 else 0;
        if (path.len + separator + 2 * name.len > path.bytes.len) return error.InvalidName;
        if (separator != 0) {
            path.bytes[path.len] = '\\';
            path.bytes[path.len + 1] = 0;
            path.len += 2;
        }
        for (name) |char| {
            path.bytes[path.len] = char;
            path.bytes[path.len + 1] = 0;
            path.len += 2;
        }
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

/// Whether two share paths are the same, case aside over Latin-1.
pub fn samePath(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    var at: usize = 0;
    while (at + 1 < one.len) : (at += 2) {
        if (one[at + 1] != other[at + 1]) return false;
        if (one[at + 1] == 0) {
            if (upper(one[at]) != upper(other[at])) return false;
        } else if (one[at] != other[at]) return false;
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

test "a name that fits is given as it is, another as its stand-in" {
    var into: [name_max]u8 = undefined;
    try testing.expectEqualStrings("Caf\xe9.txt", toDos(utf16("Café.txt"), &into));
    const shown_name = toDos(utf16("日本.txt"), &into);
    try testing.expectEqual(@as(usize, 2 + tag_len + 4), shown_name.len);
    try testing.expect(std.mem.startsWith(u8, shown_name, "__="));
    try testing.expect(std.mem.endsWith(u8, shown_name, ".txt"));
    try testing.expect(looksStandIn(shown_name));
    try testing.expect(standsFor(utf16("日本.txt"), shown_name));
    try testing.expect(!standsFor(utf16("日本.doc"), shown_name));
    // The hash is exFAT's over the units as they are.
    const units = comptime std.unicode.utf8ToUtf16LeStringLiteral("日本.txt");
    var expected: [name_max]u8 = undefined;
    const hash = dos.fat.exfatNameHash(units);
    _ = std.fmt.bufPrint(&expected, "__={X:0>4}.txt", .{hash}) catch unreachable;
    try testing.expectEqualStrings(expected[0..shown_name.len], shown_name);
}

test "stand-ins: no extension, and a name too long for dos" {
    var into: [name_max]u8 = undefined;
    const plain = toDos(utf16("日本語"), &into);
    try testing.expectEqual(@as(usize, 3 + tag_len), plain.len);
    try testing.expect(looksStandIn(plain));
    var long: [2 * 300]u8 = undefined;
    for (0..300) |index| {
        long[2 * index] = 'L';
        long[2 * index + 1] = 0;
    }
    const given = toDos(&long, &into);
    try testing.expectEqual(name_max, given.len);
    try testing.expect(looksStandIn(given));
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
    try testing.expect(!samePath(utf16("ab"), utf16("abc")));
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
