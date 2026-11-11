// SPDX-License-Identifier: MIT
//! Names on an exFAT volume, and the names dos is given for them.
//!
//! **An exFAT name is UTF-16, up to 255 units; a dos name is UTF-8, up to
//! 255 bytes** (what a FileInfoBlock holds). A name whose UTF-8 fits - and
//! that is whole UTF-16, no surrogate without its pair - is given to dos
//! as it is. Any other is given as a **stand-in**: its characters in
//! UTF-8, a broken one `_`, the part before the extension cut where a
//! character starts to make room, and `=` and the stream's name hash in
//! four hex digits put before the extension - a name of 251 `日` and
//! `.txt` is given as 82 of them and `=4F2A.txt`. The hash is the one the
//! volume already keeps for the name, so the stand-in is the same every
//! time the directory is listed, and two names in one directory give the
//! same stand-in only if their hashes are the same as well as every
//! character dos can see. A stand-in opens the file it came from: a lookup compares
//! a dos name against each entry's stand-in when the entry's own name
//! does not fit.
//!
//! **A name from dos becomes UTF-16 a character at a time**
//! (`_fat.unitsOf`), read as text is read. Such a name is compared against an entry's
//! through the volume's up-case table (`upcase.zig`), which is what makes
//! two names the same on exFAT.

const std = @import("std");
const sdk = @import("sdk");
const fat = sdk.dos.fat;
const _fat = @import("../_fat.zig");
const Upcase = @import("upcase.zig").Upcase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const utf8 = sdk.utility.utf8;

/// The longest extension a stand-in keeps, its dot included, in units.
/// A name with a longer one is cut like any other.
const ext_max: usize = 16;
/// `tag_mark` and four hex digits.
const tag_len: usize = 5;
/// What starts the tag: a character a dos name may hold that is no
/// pattern character, so a stand-in typed back as an argument names the
/// file and is not read as a pattern.
const tag_mark = '=';

/// Whether a name can be given to dos as it is.
pub fn fits(name: []const u16) bool {
    var buffer: [_fat.fib_name_max]u8 = undefined;
    return name.len != 0 and _fat.utf8Of(name, &buffer) != null;
}

/// The name dos is given for an entry named `name`, whose stream carries
/// `hash`: the name itself in UTF-8 if it fits, else its stand-in.
pub fn toDos(name: []const u16, hash: u16, into: *[_fat.fib_name_max]u8) []const u8 {
    if (name.len != 0) {
        if (_fat.utf8Of(name, into)) |text| return text;
    }
    return standIn(name, hash, into);
}

/// The characters of `units` in UTF-8 onto `into` from `len`, a broken
/// one as `_`, as many whole ones as fit before `end`; the new length.
pub fn shown(units: []const u16, into: []u8, len: usize, end: usize) usize {
    var at: usize = 0;
    var written = len;
    while (at < units.len) {
        var char: u32 = units[at];
        at += 1;
        if (char >= 0xD800 and char <= 0xDBFF and at < units.len and units[at] >= 0xDC00 and units[at] <= 0xDFFF) {
            char = 0x10000 + ((char - 0xD800) << 10) + (units[at] - 0xDC00);
            at += 1;
        } else if (char >= 0xD800 and char <= 0xDFFF) {
            char = '_';
        }
        var bytes: [4]u8 = undefined;
        const taken = utf8.encode(char, &bytes);
        if (written + taken > end) break;
        @memcpy(into[written..][0..taken], bytes[0..taken]);
        written += taken;
    }
    return written;
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
    // The extension's bytes first, at the end, to know the room the base
    // has; at most four bytes a unit, which the buffer holds.
    var ext_bytes: [ext_max * 4]u8 = undefined;
    const ext_len = shown(name[ext_start..], &ext_bytes, 0, ext_bytes.len);
    const room = _fat.fib_name_max - tag_len - ext_len;
    var len = shown(name[0..ext_start], into, 0, room);
    const digits = "0123456789ABCDEF";
    into[len] = tag_mark;
    for (0..4) |digit| into[len + 1 + digit] = digits[(hash >> @intCast(12 - digit * 4)) & 0xF];
    len += tag_len;
    @memcpy(into[len..][0..ext_len], ext_bytes[0..ext_len]);
    return into[0 .. len + ext_len];
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
        const units = _fat.unitsOf(name, &wanted.units);
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

test "a dos name as UTF-16: past U+FFFF as a pair, a byte that is no UTF-8 as U+FFFD" {
    var units: [fat.name_max]u16 = undefined;
    try testing.expectEqualSlices(u16, utf16("Gr\u{FFFD}n"), _fat.unitsOf("Gr\xFCn", &units));
    try testing.expectEqualSlices(u16, utf16("Grün"), _fat.unitsOf("Grün", &units));
    try testing.expectEqualSlices(u16, utf16("\u{1F600}.Ω"), _fat.unitsOf("\u{1F600}.Ω", &units));
}

test "a name that fits is given as it is, in UTF-8" {
    var into: [_fat.fib_name_max]u8 = undefined;
    try testing.expectEqualStrings("Café.txt", toDos(utf16("Café.txt"), 0x1234, &into));
    try testing.expectEqualStrings("日本.txt", toDos(utf16("日本.txt"), 0x4F2A, &into));
    try testing.expectEqualStrings("\u{1F600} smile", toDos(utf16("\u{1F600} smile"), 0x0001, &into));
    try testing.expect(fits(utf16("hello.txt")));
}

test "a name that is no whole UTF-16 is given a stand-in with its hash" {
    var into: [_fat.fib_name_max]u8 = undefined;
    // A surrogate without its pair is `_`; the rest as it is.
    try testing.expect(!fits(&[_]u16{ 'a', 0xD800, 'b' }));
    try testing.expectEqualStrings("a_b=4F2A", toDos(&[_]u16{ 'a', 0xD800, 'b' }, 0x4F2A, &into));
    try testing.expectEqualStrings("€_=91C3.pdf", toDos(&[_]u16{ 0x20AC, 0xDC00, '.', 'p', 'd', 'f' }, 0x91C3, &into));
    // A dot at the start is not an extension.
    try testing.expectEqualStrings("._=00AB", toDos(&[_]u16{ '.', 0xDBFF }, 0x00AB, &into));
}

test "a name too long for dos is cut where a character starts, its extension and tag kept" {
    // exFAT holds 255 units and dos 255 bytes, and a character past ASCII
    // takes more than one byte in UTF-8, so the longest names need cutting.
    var long: [_fat.fib_name_max]u16 = undefined;
    for (long[0 .. long.len - 5]) |*unit| unit.* = 'L';
    long[long.len - 5] = 0x65E5;
    @memcpy(long[long.len - 4 ..], utf16(".mkv"));
    var into: [_fat.fib_name_max]u8 = undefined;
    const given = toDos(&long, 0x7E10, &into);
    try testing.expectEqual(_fat.fib_name_max, given.len);
    try testing.expect(std.mem.endsWith(u8, given, "=7E10.mkv"));
    try testing.expectEqual(@as(u8, 'L'), given[0]);
    // 255 characters of three bytes each: 82 fit before the tag and the
    // extension (4 + 5 + 82 * 3 = 255), never part of one.
    var wide: [_fat.fib_name_max]u16 = @splat(0x65E5);
    @memcpy(wide[wide.len - 4 ..], utf16(".txt"));
    const cut = toDos(&wide, 0x4F2A, &into);
    try testing.expect(utf8.valid(cut));
    try testing.expectEqual(@as(usize, 82 * 3 + 5 + 4), cut.len);
    try testing.expect(std.mem.endsWith(u8, cut, "日=4F2A.txt"));
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
