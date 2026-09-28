// SPDX-License-Identifier: MIT
//! Names on an exFAT volume, and the names dos is given for them.
//!
//! **An exFAT name is UTF-16, up to 255 characters; a dos name is Latin-1,
//! up to 107** (what a FileInfoBlock holds). A name that fits both - every
//! character in Latin-1, no longer than 107 - is given to dos as it is.
//! Any other name is given as a **stand-in**: its Latin-1 characters kept,
//! every other one made `_`, the part before the extension cut to make
//! room, and `=` and the stream's name hash in four hex digits put before
//! the extension - `日本.txt` is `__=4F2A.txt`. The hash is the one the
//! volume already keeps for the name, so the stand-in is the same every
//! time the directory is listed, and two names in one directory give the
//! same stand-in only if their hashes are the same as well as every
//! character dos can see. A stand-in opens the file it came from: a
//! lookup compares a dos name against each entry's stand-in when the
//! entry's own name does not fit.
//!
//! **A name from dos becomes UTF-16 one character for one**: Latin-1 is
//! the first 256 characters of UTF-16. Such a name is compared against an
//! entry's through the volume's up-case table (`upcase.zig`), which is what
//! makes two names the same on exFAT.

const std = @import("std");
const sdk = @import("sdk");
const fat = sdk.dos.fat;
const _fat = @import("../_fat.zig");
const Upcase = @import("upcase.zig").Upcase;
const UtilityBase = sdk.interface.utility.UtilityBase;

/// The longest extension a stand-in keeps, its dot included. A name with
/// a longer one is cut like any other.
const ext_max: usize = 16;
/// `tag_mark` and four hex digits.
const tag_len: usize = 5;
/// What starts the tag: a character a dos name may hold that is no
/// pattern character, so a stand-in typed back as an argument names the
/// file and is not read as a pattern.
const tag_mark = '=';

/// Whether a name can be given to dos as it is.
pub fn fits(name: []const u16) bool {
    if (name.len == 0 or name.len > _fat.fib_name_max) return false;
    for (name) |unit| if (unit > 0xFF) return false;
    return true;
}

/// The name dos is given for an entry named `name`, whose stream carries
/// `hash`: the name itself if it fits, else its stand-in.
pub fn toDos(name: []const u16, hash: u16, into: *[_fat.fib_name_max]u8) []const u8 {
    if (fits(name)) {
        for (name, 0..) |unit, at| into[at] = @intCast(unit);
        return into[0..name.len];
    }
    return standIn(name, hash, into);
}

/// A character as dos sees it in a stand-in.
fn shown(unit: u16) u8 {
    return if (unit <= 0xFF) @intCast(unit) else '_';
}

/// The stand-in for a name: see the file's header.
pub fn standIn(name: []const u16, hash: u16, into: *[_fat.fib_name_max]u8) []const u8 {
    // The extension: from the last dot on, if the dot is not the name's
    // first character and what follows it is short.
    var ext_start = name.len;
    var at = name.len;
    while (at > 1) {
        at -= 1;
        if (name[at] == '.') {
            if (name.len - at <= ext_max and name.len - at > 1) ext_start = at;
            break;
        }
    }
    const ext = name[ext_start..];
    const room = _fat.fib_name_max - tag_len - ext.len;
    const base = name[0..@min(ext_start, room)];

    var len: usize = 0;
    for (base) |unit| {
        into[len] = shown(unit);
        len += 1;
    }
    const digits = "0123456789ABCDEF";
    into[len] = tag_mark;
    for (0..4) |digit| into[len + 1 + digit] = digits[(hash >> @intCast(12 - digit * 4)) & 0xF];
    len += tag_len;
    for (ext) |unit| {
        into[len] = shown(unit);
        len += 1;
    }
    return into[0..len];
}

/// A dos name as UTF-16, one character for one.
pub fn fromDos(name: []const u8, into: *[fat.name_max]u16) []const u16 {
    for (name, 0..) |char, at| into[at] = char;
    return into[0..name.len];
}

/// The hash a stand-in carries, if `name` has the shape of one: `=` and
/// four hex digits before the extension, or at its end.
pub fn tagOf(name: []const u8) ?u16 {
    var end = name.len;
    var at = name.len;
    while (at > 0) {
        at -= 1;
        if (name[at] == '.') {
            end = at;
            break;
        }
    }
    // With no dot, or none that leaves a tag before it, the tag is at the
    // end of the name.
    if (end < tag_len or name[end - tag_len] != tag_mark) {
        end = name.len;
        if (end < tag_len or name[end - tag_len] != tag_mark) return null;
    }
    var hash: u16 = 0;
    for (name[end - 4 .. end]) |char| {
        const value: u16 = switch (char) {
            '0'...'9' => char - '0',
            'A'...'F' => char - 'A' + 10,
            'a'...'f' => char - 'a' + 10,
            else => return null,
        };
        hash = (hash << 4) | value;
    }
    return hash;
}

/// What a lookup is for: a dos name, with what comparing it needs worked
/// out once rather than for every entry of the directory.
pub const Wanted = struct {
    name: []const u8,
    /// The name as UTF-16, and the hash the volume would keep for it.
    units: [fat.name_max]u16 = undefined,
    len: usize = 0,
    hash: u16 = 0,
    /// The hash in the name, if it has the shape of a stand-in.
    tag: ?u16 = null,

    pub fn init(wanted: *Wanted, name: []const u8, upcase: *const Upcase) void {
        wanted.* = .{ .name = name };
        const units = fromDos(name, &wanted.units);
        wanted.len = units.len;
        wanted.hash = upcase.hash(units);
        wanted.tag = tagOf(name);
    }

    /// Whether an entry named `name`, whose stream carries `hash`, is the
    /// one wanted: the same name through the up-case table, or - for a
    /// name dos is given a stand-in for - the same stand-in.
    pub fn matches(wanted: *const Wanted, ub: *UtilityBase, upcase: *const Upcase, name: []const u16, hash: u16) bool {
        if (fits(name)) {
            if (hash != wanted.hash) return false;
            return upcase.same(wanted.units[0..wanted.len], name);
        }
        const tag = wanted.tag orelse return false;
        if (tag != hash) return false;
        var buffer: [_fat.fib_name_max]u8 = undefined;
        return _fat.same(ub, standIn(name, hash, &buffer), wanted.name);
    }
};

// --- tests -------------------------------------------------------------------

const testing = std.testing;

fn utf16(comptime text: []const u8) []const u16 {
    return comptime std.unicode.utf8ToUtf16LeStringLiteral(text);
}

test "a name that fits is given as it is" {
    var into: [_fat.fib_name_max]u8 = undefined;
    try testing.expectEqualStrings("Caf\xe9.txt", toDos(utf16("Café.txt"), 0x1234, &into));
    try testing.expect(fits(utf16("hello.txt")));
}

test "a name outside Latin-1 is given a stand-in with its hash" {
    var into: [_fat.fib_name_max]u8 = undefined;
    try testing.expectEqualStrings("__=4F2A.txt", toDos(utf16("日本.txt"), 0x4F2A, &into));
    try testing.expectEqualStrings("_ Rechnung=91C3.pdf", toDos(utf16("€ Rechnung.pdf"), 0x91C3, &into));
    // No extension: the tag goes at the end.
    try testing.expectEqualStrings("___=0007", toDos(utf16("日本語"), 0x0007, &into));
    // A dot at the start is not an extension.
    try testing.expectEqualStrings("._=00AB", toDos(utf16(".日"), 0x00AB, &into));
}

test "a name too long for dos is cut, its extension and tag kept" {
    // exFAT holds 255 characters and so does dos, but a name outside
    // Latin-1 takes more than one byte a character once it is written
    // out, so the longest names still need cutting.
    // dos holds as many characters as exFAT does, so a name is only too
    // long once it needs a stand-in: the tag has to go in somewhere.
    var long: [_fat.fib_name_max]u16 = undefined;
    for (long[0 .. long.len - 5]) |*unit| unit.* = 'L';
    long[long.len - 5] = 0x65E5;
    @memcpy(long[long.len - 4 ..], utf16(".mkv"));
    var into: [_fat.fib_name_max]u8 = undefined;
    const given = toDos(&long, 0x7E10, &into);
    try testing.expectEqual(_fat.fib_name_max, given.len);
    try testing.expect(std.mem.endsWith(u8, given, "=7E10.mkv"));
    try testing.expectEqual(@as(u8, 'L'), given[0]);
}

test "the hash in a stand-in is read back" {
    try testing.expectEqual(@as(?u16, 0x4F2A), tagOf("__=4F2A.txt"));
    try testing.expectEqual(@as(?u16, 0x0007), tagOf("___=0007"));
    try testing.expectEqual(@as(?u16, 0xABCD), tagOf("x=abcd.tar"));
    try testing.expectEqual(@as(?u16, null), tagOf("plain.txt"));
    try testing.expectEqual(@as(?u16, null), tagOf("=12G4.txt"));
    // `~` is a pattern character and starts no tag.
    try testing.expectEqual(@as(?u16, null), tagOf("__~4F2A.txt"));
}
