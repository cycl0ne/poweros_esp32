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
//! **Names in a list are UTF-8**, as every other system writes them; dos
//! names are Latin-1. A name goes out with each character above 0x7F as
//! its two UTF-8 bytes, and comes in the other way when it is UTF-8 whose
//! characters Latin-1 has - a name that is not, or that has characters
//! outside Latin-1, is taken byte for byte. `./` in front of a name, as
//! `find` writes it, is dropped.

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

/// CRC-32 as zip, PNG and SFV files have it: the reflected polynomial
/// 0xEDB88320, started at and finished with all ones.
const crc_table = blk: {
    @setEvalBranchQuota(4000);
    var table: [256]u32 = undefined;
    for (&table, 0..) |*entry, index| {
        var crc: u32 = index;
        for (0..8) |_| crc = if (crc & 1 != 0) 0xEDB8_8320 ^ (crc >> 1) else crc >> 1;
        entry.* = crc;
    }
    break :blk table;
};

pub const crc_start: u32 = 0xFFFF_FFFF;

/// More bytes into a running CRC.
pub fn crcAdd(crc_in: u32, bytes: []const u8) u32 {
    var crc = crc_in;
    for (bytes) |byte| crc = crc_table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    return crc;
}

/// A running CRC finished, as the four bytes a list shows, the highest
/// first.
pub fn crcDigest(crc: u32, into: *[4]u8) void {
    const value = ~crc;
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
    for (name) |char| {
        var part: [2]u8 = undefined;
        const piece: []const u8 = if (escaped and char == '\\')
            "\\\\"
        else if (escaped and char == '\n')
            "\\n"
        else if (char < 0x80) blk: {
            part[0] = char;
            break :blk part[0..1];
        } else blk: {
            part = .{ 0xC0 | char >> 6, 0x80 | (char & 0x3F) };
            break :blk &part;
        };
        if (at + piece.len > into.len) return null;
        @memcpy(into[at..][0..piece.len], piece);
        at += piece.len;
    }
    if (at >= into.len) return null;
    into[at] = '\n';
    return at + 1;
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
/// UTF-8 made Latin-1 where it can be. Null when it does not fit.
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
    return latin1(into[0..plain_len]);
}

/// UTF-8 whose characters all fit Latin-1 made Latin-1 in place; anything
/// else left as it is.
fn latin1(name: []u8) []u8 {
    var at: usize = 0;
    while (at < name.len) : (at += 1) {
        const char = name[at];
        if (char < 0x80) continue;
        if (char != 0xC2 and char != 0xC3) return name;
        if (at + 1 >= name.len or name[at + 1] & 0xC0 != 0x80) return name;
        at += 1;
    }
    var out: usize = 0;
    at = 0;
    while (at < name.len) : (at += 1) {
        const char = name[at];
        if (char < 0x80) {
            name[out] = char;
        } else {
            name[out] = (char & 0x03) << 6 | (name[at + 1] & 0x3F);
            at += 1;
        }
        out += 1;
    }
    return name[0..out];
}

// --- tests (host) ------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "CRC-32 of the check string, and in pieces" {
    var digest: [4]u8 = undefined;
    crcDigest(crcAdd(crc_start, "123456789"), &digest);
    try testing.expectEqualSlices(u8, &.{ 0xCB, 0xF4, 0x39, 0x26 }, &digest);
    crcDigest(crcAdd(crcAdd(crc_start, "1234"), "56789"), &digest);
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

test "a line written as sha256sum writes it, Latin-1 as UTF-8" {
    var line: [128]u8 = undefined;
    const length = formatLine(&.{ 0xAB, 0x01 }, "Caf\xe9.txt", &line).?;
    try testing.expectEqualStrings("ab01  Caf\xc3\xa9.txt\n", line[0..length]);
    const odd = formatLine(&.{0xFF}, "a\\b", &line).?;
    try testing.expectEqualStrings("\\ff  a\\\\b\n", line[0..odd]);
    try testing.expect(formatLine(&.{0xFF}, "long name", line[0..6]) == null);
}

test "lines read back: GNU, binary, BSD, SFV, escaped, comments" {
    var entry: Entry = .{};
    var name: [64]u8 = undefined;
    try testing.expectEqual(LineKind.entry, parseLine("ab01cd02  Caf\xc3\xa9.txt\r\n", &entry, &name));
    try testing.expectEqualStrings("Caf\xe9.txt", entry.name);
    try testing.expectEqualSlices(u8, &.{ 0xAB, 0x01, 0xCD, 0x02 }, entry.digest[0..entry.digest_len]);
    try testing.expect(entry.algorithm == null);

    const md5 = "d41d8cd98f00b204e9800998ecf8427e";
    try testing.expectEqual(LineKind.entry, parseLine(md5 ++ " *./dir/empty", &entry, &name));
    try testing.expectEqualStrings("dir/empty", entry.name);
    try testing.expectEqual(@as(usize, 16), entry.digest_len);

    try testing.expectEqual(LineKind.entry, parseLine("MD5 (a (b).txt) = " ++ md5, &entry, &name));
    try testing.expectEqualStrings("a (b).txt", entry.name);
    try testing.expectEqual(Algorithm.md5, entry.algorithm.?);

    try testing.expectEqual(LineKind.entry, parseLine("My File.lha CBF43926", &entry, &name));
    try testing.expectEqualStrings("My File.lha", entry.name);
    try testing.expectEqual(Algorithm.crc32, entry.algorithm.?);
    try testing.expectEqualSlices(u8, &.{ 0xCB, 0xF4, 0x39, 0x26 }, entry.digest[0..4]);

    try testing.expectEqual(LineKind.entry, parseLine("\\ff00ff00  a\\\\b\\nc", &entry, &name));
    try testing.expectEqualStrings("a\\b\nc", entry.name);

    // UTF-8 outside Latin-1 stays as it is.
    try testing.expectEqual(LineKind.entry, parseLine("ff00ff00  \xe6\x97\xa5.txt", &entry, &name));
    try testing.expectEqualStrings("\xe6\x97\xa5.txt", entry.name);

    try testing.expectEqual(LineKind.nothing, parseLine("; made by an SFV tool", &entry, &name));
    try testing.expectEqual(LineKind.nothing, parseLine("", &entry, &name));
    try testing.expectEqual(LineKind.malformed, parseLine("hello world", &entry, &name));
    try testing.expectEqual(LineKind.malformed, parseLine("abc  name", &entry, &name));
}
