// SPDX-License-Identifier: MIT
//! Names on a posfs volume: UTF-8, compared without regard to case, and
//! the names dos is given for them.
//!
//! **A name is the bytes it was given**, always valid UTF-8, 1 to 255 of
//! them, never `/`, `:` or NUL. Two names are the same when their code
//! points are the same after simple case folding (`fold1.zig`); nothing
//! is normalized, so the two ways of writing é are two names. A name's
//! place in its directory is the top 24 bits of the crc32 of its folded
//! form, so a lookup reads one bucket of the directory.
//!
//! **Which fold** is part of the format: each directory says which table
//! its names were hashed with, and a volume's new directories get the
//! label's. There is one table so far.
//!
//! **dos's names are Latin-1.** A name from dos that is valid UTF-8 is
//! taken as it is; any other is read as Latin-1 and stored converted. A
//! stored name whose every character is in Latin-1 goes to dos converted
//! back. Any other goes as a **stand-in**: its Latin-1 characters kept,
//! the others `_`, and `=` with four hex digits of the name's hash before
//! the extension - `日本.txt` is `__=4F2A.txt`. The stand-in is the same
//! every time, and a lookup by it finds the name it stands for.

const layout = @import("layout.zig");
const fold1 = @import("fold1.zig");
const posfs = @import("posfs.zig");
const utf8 = @import("../../utility/utf8.zig");
const unicode = @import("../../utility/unicode.zig");

// --- UTF-8 ------------------------------------------------------------------------

/// The code point at `bytes[at.*]`, `at` moved past it; null for bytes
/// that are not UTF-8 there: a stray continuation byte, a sequence cut
/// short, an overlong form, a surrogate, or past U+10FFFF.
pub fn decode(bytes: []const u8, at: *usize) ?u21 {
    const step = utf8.decode(bytes[at.*..]);
    if (step.kind != .char) return null;
    at.* += step.length;
    return @intCast(step.char);
}

/// Whether `bytes` are UTF-8 from first to last.
pub fn valid(bytes: []const u8) bool {
    return utf8.valid(bytes);
}

/// A code point as UTF-8 into `into`, which has room for it; the bytes
/// it took.
pub fn encode(code: u21, into: []u8) usize {
    var bytes: [4]u8 = undefined;
    const length = utf8.encode(code, &bytes);
    @memcpy(into[0..length], bytes[0..length]);
    return length;
}

// --- folding ------------------------------------------------------------------------

/// Whether a directory's fold is one this code knows.
pub fn known(table: u32) bool {
    return table == layout.fold_1;
}

/// A code point folded by table 1.
pub fn foldCode(code: u21) u21 {
    if (code < 0x41) return code;
    if (code <= 0x5A) return code + 32;
    if (code < 0xB5) return code;
    return @intCast(unicode.mapped(&fold1.runs, code));
}

/// The hash of a UTF-8 name: the crc32 of its folded form's UTF-8.
pub fn hash(name: []const u8) u32 {
    var crc = layout.crcStart();
    var at: usize = 0;
    var buffer: [4]u8 = undefined;
    while (at < name.len) {
        const code = decode(name, &at) orelse {
            // Not UTF-8: a name on the volume always is, so this is only
            // reached for one that never gets stored; hash the byte.
            crc = layout.crcAdd(crc, name[at .. at + 1]);
            at += 1;
            continue;
        };
        const used = encode(foldCode(code), &buffer);
        crc = layout.crcAdd(crc, buffer[0..used]);
    }
    return layout.crcEnd(crc);
}

/// Whether two UTF-8 names are the same name.
pub fn same(a: []const u8, b: []const u8) bool {
    var at_a: usize = 0;
    var at_b: usize = 0;
    while (at_a < a.len and at_b < b.len) {
        const code_a = decode(a, &at_a) orelse return false;
        const code_b = decode(b, &at_b) orelse return false;
        if (foldCode(code_a) != foldCode(code_b)) return false;
    }
    return at_a == a.len and at_b == b.len;
}

/// A name's hash bucket, and the directory position of the `slot`th name
/// in it (0 to 254). A bucket's positions are one run of keys.
pub fn bucketOf(name_hash: u32) u32 {
    return name_hash >> 8;
}

pub fn position(bucket: u32, slot: u32) u64 {
    return (@as(u64, bucket) << 8) | slot;
}

/// The names a bucket holds at most.
pub const bucket_slots: u32 = 255;

// --- names from and to dos ------------------------------------------------------------

/// Whether `name` (UTF-8) may be a name: 1 to 255 bytes with no `/`, `:`
/// or NUL in them.
pub fn acceptable(name: []const u8) bool {
    if (name.len == 0 or name.len > posfs.max_name) return false;
    for (name) |byte| {
        if (byte == '/' or byte == ':' or byte == 0) return false;
    }
    return valid(name);
}

/// A name from dos as UTF-8: as it is when it is UTF-8, else read as
/// Latin-1. Null when the result would be longer than `into`.
pub fn fromDos(name: []const u8, into: []u8) ?[]const u8 {
    if (valid(name)) {
        if (name.len > into.len) return null;
        @memcpy(into[0..name.len], name);
        return into[0..name.len];
    }
    var len: usize = 0;
    for (name) |byte| {
        if (len + 2 > into.len) return null;
        len += encode(byte, into[len..]);
    }
    return into[0..len];
}

/// Whether every character of a UTF-8 name is in Latin-1.
pub fn latin1(name: []const u8) bool {
    var at: usize = 0;
    while (at < name.len) {
        const code = decode(name, &at) orelse return false;
        if (code > 0xFF) return false;
    }
    return true;
}

/// The longest extension a stand-in keeps, its dot included.
const ext_max: usize = 16;
/// `tag_mark` and four hex digits.
const tag_len: usize = 5;
/// What starts a stand-in's tag: no pattern character, so the stand-in
/// typed back names the file.
const tag_mark = '=';

/// The name dos is given for a UTF-8 name: Latin-1 when it can be,
/// else its stand-in.
pub fn toDos(name: []const u8, into: *[posfs.max_name]u8) []const u8 {
    if (latin1(name)) {
        var len: usize = 0;
        var at: usize = 0;
        while (at < name.len) : (len += 1) {
            into[len] = @intCast(decode(name, &at).?);
        }
        return into[0..len];
    }
    return standIn(name, @intCast(hash(name) >> 16), into);
}

/// The stand-in for a UTF-8 name whose hash's top 16 bits are `tag`.
pub fn standIn(name: []const u8, tag: u16, into: *[posfs.max_name]u8) []const u8 {
    // Its characters as dos sees them.
    var shown: [posfs.max_name]u8 = undefined;
    var count: usize = 0;
    var at: usize = 0;
    while (at < name.len) : (count += 1) {
        const code = decode(name, &at) orelse '_';
        shown[count] = if (code <= 0xFF) @intCast(code) else '_';
    }
    // The extension: from the last dot on, if it is not the first
    // character and what follows it is short.
    var ext_start = count;
    var back = count;
    while (back > 1) {
        back -= 1;
        if (shown[back] == '.') {
            if (count - back <= ext_max and count - back > 1) ext_start = back;
            break;
        }
    }
    const ext = shown[ext_start..count];
    const room = posfs.max_name - tag_len - ext.len;
    const base_len = if (ext_start < room) ext_start else room;
    var len: usize = 0;
    for (shown[0..base_len]) |char| {
        into[len] = char;
        len += 1;
    }
    const digits = "0123456789ABCDEF";
    into[len] = tag_mark;
    for (0..4) |digit| into[len + 1 + digit] = digits[(tag >> @intCast(12 - digit * 4)) & 0xF];
    len += tag_len;
    for (ext) |char| {
        into[len] = char;
        len += 1;
    }
    return into[0..len];
}

/// The tag a dos name carries, if it has the shape of a stand-in: `=`
/// and four hex digits before the extension, or at its end.
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
    if (end < tag_len or name[end - tag_len] != tag_mark) {
        end = name.len;
        if (end < tag_len or name[end - tag_len] != tag_mark) return null;
    }
    var tag: u16 = 0;
    for (name[end - 4 .. end]) |char| {
        const value: u16 = switch (char) {
            '0'...'9' => char - '0',
            'A'...'F' => char - 'A' + 10,
            'a'...'f' => char - 'a' + 10,
            else => return null,
        };
        tag = (tag << 4) | value;
    }
    return tag;
}

/// The directory positions a stand-in's tag can be at: the buckets whose
/// top 16 bits are the tag, one run of keys.
pub fn tagRange(tag: u16) struct { first: u64, last: u64 } {
    const first: u64 = @as(u64, tag) << 16;
    return .{ .first = first, .last = first | 0xFFFF };
}

/// Whether a dos name is the same as another, Latin-1 against Latin-1,
/// without regard to case.
pub fn sameLatin1(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |char_a, char_b| {
        if (foldCode(char_a) != foldCode(char_b)) return false;
    }
    return true;
}
