// SPDX-License-Identifier: MIT
//! The digests Hash makes and the lists it writes and reads: the
//! algorithms, CRC-32, and a list's lines.
//!
//! **A line** is sha256sum's: the digest in lower-case hex, two spaces,
//! the name. Reading, a `*` in place of the second space (a list made in
//! binary mode) is the same, and so are two other forms - BSD's tagged
//! `SHA256 (name) = digest` and an SFV file's `name CRC32`, which says
//! its algorithm by its place. A name with a backslash or a line's end in
//! it is written as sha256sum writes it: the line begins with a
//! backslash, and the two are `\\` and `\n` in the name.
//!
//! **Names in a list are UTF-8**, as every other system writes them and
//! as dos names are: a name goes out and comes in as it is. One that is
//! no UTF-8 - a list a system with another encoding wrote - is read as
//! Latin-1. `./` in front of a name, as `find` writes it, is dropped.

const sdk = @import("sdk");
const utf8 = sdk.utility.utf8;

pub const Algorithm = enum {
    crc32,
    md5,
    sha1,
    sha224,
    sha256,
    sha384,
    sha512,

    /// The name ALGO takes and BSD's tag carries.
    pub fn name(algorithm: Algorithm) [:0]const u8 {
        return switch (algorithm) {
            .crc32 => "CRC32",
            .md5 => "MD5",
            .sha1 => "SHA1",
            .sha224 => "SHA224",
            .sha256 => "SHA256",
            .sha384 => "SHA384",
            .sha512 => "SHA512",
        };
    }

    /// The digest's length in bytes.
    pub fn length(algorithm: Algorithm) usize {
        return switch (algorithm) {
            .crc32 => 4,
            .md5 => 16,
            .sha1 => 20,
            .sha224 => 28,
            .sha256 => 32,
            .sha384 => 48,
            .sha512 => 64,
        };
    }

    /// The algorithm a name says, case aside and a `-` after SHA allowed
    /// (`sha-256`).
    pub fn of(text: []const u8) ?Algorithm {
        var squeezed: [8]u8 = undefined;
        var count: usize = 0;
        for (text) |char| {
            if (char == '-') continue;
            if (count == squeezed.len) return null;
            squeezed[count] = upper(char);
            count += 1;
        }
        inline for (@typeInfo(Algorithm).@"enum".fields) |field| {
            const algorithm: Algorithm = @enumFromInt(field.value);
            if (same(squeezed[0..count], algorithm.name())) return algorithm;
        }
        return null;
    }

    /// The algorithm a digest of `digit_count` hex digits is made with, as
    /// a list without tags says it.
    pub fn ofDigits(digit_count: usize) ?Algorithm {
        inline for (@typeInfo(Algorithm).@"enum".fields) |field| {
            const algorithm: Algorithm = @enumFromInt(field.value);
            if (2 * algorithm.length() == digit_count) return algorithm;
        }
        return null;
    }
};

/// The longest digest, in bytes.
pub const digest_max = 64;

fn upper(char: u8) u8 {
    return if (char >= 'a' and char <= 'z') char - 32 else char;
}

fn same(text: []const u8, want: []const u8) bool {
    if (text.len != want.len) return false;
    for (text, want) |got, expected| if (upper(got) != expected) return false;
    return true;
}

// --- CRC-32 -----------------------------------------------------------------------

/// A CRC-32 as zip, PNG and SFV files have it (compression.library's
/// Crc32), as the four bytes a list shows, the highest first.
pub fn crcDigest(value: u32, into: *[4]u8) void {
    into.* = .{ @truncate(value >> 24), @truncate(value >> 16), @truncate(value >> 8), @truncate(value) };
}

// --- writing ----------------------------------------------------------------------

const hex_digits = "0123456789abcdef";

/// A list's line for `digest` and the dos name `name`, with its line's
/// end, into `into`: its length, or null when it does not fit.
pub fn formatLine(digest: []const u8, name: []const u8, into: []u8) ?usize {
    var at: usize = 0;
    const escaped = needsEscape(name);
    if (escaped) {
        if (into.len < 1) return null;
        into[0] = '\\';
        at = 1;
    }
    if (into.len < at + 2 * digest.len + 2) return null;
    for (digest) |byte| {
        into[at] = hex_digits[byte >> 4];
        into[at + 1] = hex_digits[byte & 0xF];
        at += 2;
    }
    into[at] = ' ';
    into[at + 1] = ' ';
    at += 2;
    // The name between its escapes.
    var start: usize = 0;
    for (name, 0..) |char, index| {
        if (!escaped or (char != '\\' and char != '\n')) continue;
        at = put(into, at, name[start..index]) orelse return null;
        if (at + 2 > into.len) return null;
        @memcpy(into[at..][0..2], if (char == '\\') "\\\\" else "\\n");
        at += 2;
        start = index + 1;
    }
    at = put(into, at, name[start..]) orelse return null;
    if (at >= into.len) return null;
    into[at] = '\n';
    return at + 1;
}

/// `text` into `into` from `at`: where it ends, or null when it does not
/// fit.
fn put(into: []u8, at: usize, text: []const u8) ?usize {
    if (text.len > into.len - at) return null;
    @memcpy(into[at..][0..text.len], text);
    return at + text.len;
}

fn needsEscape(name: []const u8) bool {
    for (name) |char| if (char == '\\' or char == '\n') return true;
    return false;
}

// --- reading ----------------------------------------------------------------------

/// One line of a list, read.
pub const Entry = struct {
    /// The algorithm a tag or the place says; null when only the digest's
    /// length can.
    algorithm: ?Algorithm = null,
    digest: [digest_max]u8 = undefined,
    digest_len: usize = 0,
    /// The dos name, in the caller's buffer.
    name: []const u8 = &.{},
};

pub const LineKind = enum {
    entry,
    /// Empty, or a comment (`#`, and `;` as SFV files have them).
    nothing,
    /// Not a line of any list this reads.
    malformed,
};

/// A line of a list, without its line's end, read into `entry`, the name
/// made a dos name in `name_buffer`.
pub fn parseLine(raw: []const u8, entry: *Entry, name_buffer: []u8) LineKind {
    var line = raw;
    while (line.len > 0 and (line[line.len - 1] == '\r' or line[line.len - 1] == '\n')) line = line[0 .. line.len - 1];
    if (line.len == 0 or line[0] == '#' or line[0] == ';') return .nothing;
    var escaped = false;
    if (line[0] == '\\') {
        escaped = true;
        line = line[1..];
    }
    entry.* = .{};
    var name_part: []const u8 = undefined;
    if (gnuLine(line, entry)) |rest| {
        name_part = rest;
    } else if (bsdLine(line, entry)) |rest| {
        name_part = rest;
    } else if (if (escaped) null else sfvLine(line, entry)) |rest| {
        name_part = rest;
    } else return .malformed;
    entry.name = dosName(name_part, escaped, name_buffer) orelse return .malformed;
    if (entry.name.len == 0) return .malformed;
    return .entry;
}

/// `digest  name` or `digest *name`: the name, or null.
fn gnuLine(line: []const u8, entry: *Entry) ?[]const u8 {
    var end: usize = 0;
    while (end < line.len and hexValue(line[end]) != null) end += 1;
    if (end == 0 or end + 2 > line.len or line[end] != ' ' or (line[end + 1] != ' ' and line[end + 1] != '*')) return null;
    if (Algorithm.ofDigits(end) == null) return null;
    if (!readHex(line[0..end], entry)) return null;
    return line[end + 2 ..];
}

/// `ALGO (name) = digest`: the name, or null.
fn bsdLine(line: []const u8, entry: *Entry) ?[]const u8 {
    var open: usize = 0;
    while (open < line.len and line[open] != ' ') open += 1;
    if (open + 2 > line.len or line[open + 1] != '(') return null;
    const algorithm = Algorithm.of(line[0..open]) orelse return null;
    var close = line.len;
    while (close > open + 2) {
        close -= 1;
        if (line[close] == ')') break;
    } else return null;
    const tail = line[close..];
    if (tail.len < 4 or tail[1] != ' ' or tail[2] != '=' or tail[3] != ' ') return null;
    const hex = tail[4..];
    if (hex.len != 2 * algorithm.length() or !readHex(hex, entry)) return null;
    entry.algorithm = algorithm;
    return line[open + 2 .. close];
}

/// `name CRC32`, eight hex digits after the last space: the name, or null.
fn sfvLine(line: []const u8, entry: *Entry) ?[]const u8 {
    if (line.len < 10 or line[line.len - 9] != ' ') return null;
    if (!readHex(line[line.len - 8 ..], entry)) return null;
    entry.algorithm = .crc32;
    var end = line.len - 9;
    while (end > 0 and line[end - 1] == ' ') end -= 1;
    return line[0..end];
}

fn hexValue(char: u8) ?u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

fn readHex(hex: []const u8, entry: *Entry) bool {
    if (hex.len % 2 != 0 or hex.len / 2 > digest_max) return false;
    for (0..hex.len / 2) |index| {
        const high = hexValue(hex[2 * index]) orelse return false;
        const low = hexValue(hex[2 * index + 1]) orelse return false;
        entry.digest[index] = high << 4 | low;
    }
    entry.digest_len = hex.len / 2;
    return true;
}

/// A list's name as a dos name in `into`: escapes undone, `./` dropped,
/// a name that is no UTF-8 read as Latin-1. Null when it does not fit.
fn dosName(raw: []const u8, escaped: bool, into: []u8) ?[]const u8 {
    var name = raw;
    while (name.len > 2 and name[0] == '.' and name[1] == '/') name = name[2..];
    var plain_len: usize = 0;
    var at: usize = 0;
    while (at < name.len) : (at += 1) {
        var char = name[at];
        if (escaped and char == '\\' and at + 1 < name.len) {
            at += 1;
            char = switch (name[at]) {
                'n' => '\n',
                else => name[at],
            };
        }
        if (plain_len == into.len) return null;
        into[plain_len] = char;
        plain_len += 1;
    }
    if (utf8.valid(into[0..plain_len])) return into[0..plain_len];
    return fromLatin1InPlace(into, plain_len);
}

/// The first `length` bytes of `into`, Latin-1, made UTF-8 where they
/// are, from the end back so that nothing is read after it is written;
/// null when the UTF-8 does not fit.
fn fromLatin1InPlace(into: []u8, length: usize) ?[]const u8 {
    var needed = length;
    for (into[0..length]) |char| needed += char >> 7;
    if (needed > into.len) return null;
    var from = length;
    var to = needed;
    while (from > 0) {
        from -= 1;
        const char = into[from];
        if (char < 0x80) {
            to -= 1;
            into[to] = char;
        } else {
            to -= 2;
            into[to] = 0xC0 | char >> 6;
            into[to + 1] = 0x80 | (char & 0x3F);
        }
    }
    return into[0..needed];
}

// --- tests (host) ------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "a CRC-32 is shown highest byte first" {
    var digest: [4]u8 = undefined;
    crcDigest(0xCBF4_3926, &digest);
    try testing.expectEqualSlices(u8, &.{ 0xCB, 0xF4, 0x39, 0x26 }, &digest);
}

test "algorithms by name and by a digest's length" {
    try testing.expectEqual(Algorithm.sha256, Algorithm.of("sha-256").?);
    try testing.expectEqual(Algorithm.crc32, Algorithm.of("crc32").?);
    try testing.expect(Algorithm.of("sha3") == null);
    try testing.expectEqual(Algorithm.md5, Algorithm.ofDigits(32).?);
    try testing.expectEqual(Algorithm.sha512, Algorithm.ofDigits(128).?);
    try testing.expect(Algorithm.ofDigits(30) == null);
}
