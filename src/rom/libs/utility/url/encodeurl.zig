// SPDX-License-Identifier: MPL-2.0
//! EncodeUrl: bytes made a part of a URL, `%XX` for what it cannot hold.

const std = @import("std");
const sdk = @import("sdk");
const utility = sdk.utility;

const UtilityBase = @import("../utility.zig").UtilityBase;
const _url = @import("_url.zig");

/// Writes bytes as a part of a URL can hold them: the characters that
/// need no escape as they are, every other byte as `%XX`.
///
/// SYNOPSIS:
/// ```zig
/// fn EncodeUrl(ub: *UtilityBase, from: [*]const u8, from_length: usize, into: [*]u8, into_length: usize, flags: u32) usize
/// ```
///
/// SINCE: 1.5. LVO -296.
///
/// INPUTS:
/// - `from`, `from_length` - the bytes: a user, a password, a query's
///   value, a path.
/// - `into`, `into_length` - where the part goes; not `from`.
/// - `flags` - URLF_SLASH keeps `/` as it is, for a whole path;
///   URLF_LATIN1 takes the bytes as Latin-1 and encodes each character
///   past ASCII as its UTF-8.
///
/// RESULT:
/// The bytes the whole part takes, written or not.
///
/// BEHAVIOR:
/// A letter, a digit, `-`, `.`, `_` and `~` stay as they are - what no
/// part of a URL needs escaped - and with URLF_SLASH a `/`; every other
/// byte is `%` and two upper-case hex digits, a space `%20`. As many
/// whole characters are written as `into` holds, no NUL after them: the
/// whole is there when the answer is no more than `into_length`. A
/// length of 0 for `into` only counts.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads its input and writes `into`.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. Everything given is the caller's.
///
/// NOTES:
/// The part grows to three times its bytes at most - six times a Latin-1
/// character's with URLF_LATIN1. What is escaped is what a part's own
/// separators would take for theirs (`:` and `@` in a user, `&` and `=`
/// in a query, `/` in a segment), and more besides, which a server takes
/// the same.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DecodeUrl`, `ParseUrl`, `Latin1ToUtf8`
///
/// EXAMPLES:
/// ```zig
/// // Words typed for a search, as a query's value.
/// const length = ub.EncodeUrl(words.ptr, words.len, address[at..].ptr, address.len - at, utility.URLF_LATIN1);
/// if (length > address.len - at) return null; // too long
/// ```
pub fn EncodeUrl(_: *UtilityBase, from: [*]const u8, from_length: usize, into: [*]u8, into_length: usize, flags: u32) usize {
    var needed: usize = 0;
    var full = false;
    for (from[0..from_length]) |char| {
        // The character's bytes: its UTF-8 for Latin-1 past ASCII.
        var bytes: [2]u8 = .{ char, 0 };
        var count: usize = 1;
        if (char >= 0x80 and flags & utility.url.URLF_LATIN1 != 0) {
            bytes = .{ 0xC0 | char >> 6, 0x80 | (char & 0x3F) };
            count = 2;
        }
        var length: usize = 0;
        for (bytes[0..count]) |byte| length += if (isKept(byte, flags)) 1 else 3;
        needed += length;
        if (full or needed > into_length) {
            full = true;
            continue;
        }
        var out = needed - length;
        for (bytes[0..count]) |byte| {
            if (isKept(byte, flags)) {
                into[out] = byte;
                out += 1;
            } else {
                into[out] = '%';
                into[out + 1] = _url.hex_digits[byte >> 4];
                into[out + 2] = _url.hex_digits[byte & 0x0F];
                out += 3;
            }
        }
    }
    return needed;
}

/// Whether `byte` stays as it is.
fn isKept(byte: u8, flags: u32) bool {
    return _url.isUnreserved(byte) or (byte == '/' and flags & utility.url.URLF_SLASH != 0);
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

fn encode(ub: *UtilityBase, from: []const u8, into: []u8, flags: u32) []const u8 {
    return into[0..EncodeUrl(ub, from.ptr, from.len, into.ptr, into.len, flags)];
}

test "EncodeUrl: what needs no escape as it is, the rest %XX, Latin-1 as UTF-8, counted" {
    const ub = try library.setUp();
    defer kexec.deinit();
    var into: [64]u8 = undefined;
    try testing.expectEqualStrings("t%40k%3An%20a-b.c_d~e", encode(ub, "t@k:n a-b.c_d~e", &into, 0));
    try testing.expectEqualStrings("%2Fa%2Fb", encode(ub, "/a/b", &into, 0));
    try testing.expectEqualStrings("/a%20b/c", encode(ub, "/a b/c", &into, utility.url.URLF_SLASH));
    try testing.expectEqualStrings("Bj%C3%B6rk%26co", encode(ub, "Bj\xF6rk&co", &into, utility.url.URLF_LATIN1));
    // Bytes as they are without URLF_LATIN1.
    try testing.expectEqualStrings("Bj%F6rk", encode(ub, "Bj\xF6rk", &into, 0));
    // Whole escapes while they fit; the whole length said.
    var small: [4]u8 = @splat('#');
    try testing.expectEqual(@as(usize, 9), EncodeUrl(ub, "a b c", 5, &small, small.len, 0));
    try testing.expectEqualStrings("a%20", &small);
    // A Latin-1 character's two escapes go together or not at all.
    var cut: [5]u8 = @splat('#');
    try testing.expectEqual(@as(usize, 7), EncodeUrl(ub, "a\xF6", 2, &cut, cut.len, utility.url.URLF_LATIN1));
    try testing.expectEqualStrings("a####", &cut);
    var smaller: [3]u8 = @splat('#');
    try testing.expectEqual(@as(usize, 5), EncodeUrl(ub, "a b", 3, &smaller, smaller.len, 0));
    try testing.expectEqualStrings("a##", &smaller);
    try testing.expectEqual(@as(usize, 0), EncodeUrl(ub, "", 0, &into, into.len, 0));
}
