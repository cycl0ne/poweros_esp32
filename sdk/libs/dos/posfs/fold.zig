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

// --- UTF-8 ------------------------------------------------------------------------

/// The code point at `bytes[at.*]`, `at` moved past it; null for bytes
/// that are not UTF-8 there: a stray continuation byte, a sequence cut
/// short, an overlong form, a surrogate, or past U+10FFFF.
pub fn decode(bytes: []const u8, at: *usize) ?u21 {
    const first = bytes[at.*];
    if (first < 0x80) {
        at.* += 1;
        return first;
    }
    var need: usize = 0;
    var value: u21 = 0;
    var least: u21 = 0;
    if (first & 0xE0 == 0xC0) {
        need = 1;
        value = first & 0x1F;
        least = 0x80;
    } else if (first & 0xF0 == 0xE0) {
        need = 2;
        value = first & 0x0F;
        least = 0x800;
    } else if (first & 0xF8 == 0xF0) {
        need = 3;
        value = first & 0x07;
        least = 0x10000;
    } else return null;
    if (bytes.len - at.* <= need) return null;
    for (bytes[at.* + 1 .. at.* + 1 + need]) |byte| {
        if (byte & 0xC0 != 0x80) return null;
        value = (value << 6) | (byte & 0x3F);
    }
    if (value < least or value > 0x10FFFF) return null;
    if (value >= 0xD800 and value <= 0xDFFF) return null;
    at.* += 1 + need;
    return value;
}

/// Whether `bytes` are UTF-8 from first to last.
pub fn valid(bytes: []const u8) bool {
    var at: usize = 0;
    while (at < bytes.len) {
        _ = decode(bytes, &at) orelse return false;
    }
    return true;
}

/// A code point as UTF-8 into `into`; the bytes it took.
pub fn encode(code: u21, into: []u8) usize {
    if (code < 0x80) {
        into[0] = @intCast(code);
        return 1;
    }
    if (code < 0x800) {
        into[0] = @intCast(0xC0 | (code >> 6));
        into[1] = @intCast(0x80 | (code & 0x3F));
        return 2;
    }
    if (code < 0x10000) {
        into[0] = @intCast(0xE0 | (code >> 12));
        into[1] = @intCast(0x80 | ((code >> 6) & 0x3F));
        into[2] = @intCast(0x80 | (code & 0x3F));
        return 3;
    }
    into[0] = @intCast(0xF0 | (code >> 18));
    into[1] = @intCast(0x80 | ((code >> 12) & 0x3F));
    into[2] = @intCast(0x80 | ((code >> 6) & 0x3F));
    into[3] = @intCast(0x80 | (code & 0x3F));
    return 4;
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
    const runs = &fold1.runs;
    // The last run that starts at or before the code point.
    var low: usize = 0;
    var high: usize = runs.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (runs[middle].first <= code) low = middle + 1 else high = middle;
    }
    if (low == 0) return code;
    const run = runs[low - 1];
    const distance: u32 = code - run.first;
    const stride: u32 = run.stride;
    if (distance % stride != 0 or distance / stride >= run.count) return code;
    const folded: i32 = @as(i32, code) + run.delta;
    return @intCast(folded);
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
