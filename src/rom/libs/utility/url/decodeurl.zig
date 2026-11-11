// SPDX-License-Identifier: MPL-2.0
//! DecodeUrl: a part of a URL with its `%XX` escapes undone.

const std = @import("std");
const sdk = @import("sdk");
const utility = sdk.utility;

const UtilityBase = @import("../utility.zig").UtilityBase;
const _url = @import("_url.zig");

/// Undoes the `%XX` escapes of a part of a URL: a user, a password, a
/// path's segment, a query's value.
///
/// SYNOPSIS:
/// ```zig
/// fn DecodeUrl(ub: *UtilityBase, from: [*]const u8, from_length: usize, into: [*]u8, into_length: usize) usize
/// ```
///
/// SINCE: 1.5. LVO -292.
///
/// INPUTS:
/// - `from`, `from_length` - the part as the URL writes it.
/// - `into`, `into_length` - where its bytes go; it may be `from`.
///
/// RESULT:
/// The bytes the whole part comes to, written or not; URL_BROKEN for a
/// `%` that is not followed by two hex digits.
///
/// BEHAVIOR:
/// Each `%` and the two hex digits after it, in either case, are the
/// byte they give; every other byte is itself, a `+` too. As many bytes
/// are written as `into` holds, no NUL after them: the whole is there
/// when the answer is no more than `into_length`. A length of 0 for
/// `into` only counts.
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
/// A part never grows as it is decoded: `into` as long as `from` holds
/// it. What the bytes are - UTF-8, mostly - is the caller's to say;
/// `Utf8Kind` tells, and `Latin1ToUtf8` makes Latin-1 the system's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ParseUrl`, `EncodeUrl`, `Utf8Kind`, `Latin1ToUtf8`
///
/// EXAMPLES:
/// ```zig
/// // The user a URL gives, for a login.
/// const user = parts.user.of(text);
/// const length = ub.DecodeUrl(user.ptr, user.len, &name, name.len - 1);
/// if (length == utility.URL_BROKEN or length > name.len - 1) return false;
/// name[length] = 0;
/// ```
pub fn DecodeUrl(_: *UtilityBase, from: [*]const u8, from_length: usize, into: [*]u8, into_length: usize) usize {
    var needed: usize = 0;
    var at: usize = 0;
    while (at < from_length) : (needed += 1) {
        var byte = from[at];
        if (byte == '%') {
            if (at + 3 > from_length) return utility.url.URL_BROKEN;
            const high = _url.hexValue(from[at + 1]) orelse return utility.url.URL_BROKEN;
            const low = _url.hexValue(from[at + 2]) orelse return utility.url.URL_BROKEN;
            byte = high << 4 | low;
            at += 3;
        } else {
            at += 1;
        }
        if (needed < into_length) into[needed] = byte;
    }
    return needed;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

test "DecodeUrl: escapes in either case, the rest as it is, in place, counted" {
    const ub = try library.setUp();
    defer kexec.deinit();
    var into: [32]u8 = undefined;
    const text = "t%40k%3an+x%C3%A4";
    const length = DecodeUrl(ub, text, text.len, &into, into.len);
    try testing.expectEqualStrings("t@k:n+x\xC3\xA4", into[0..length]);
    // In place.
    var place = "a%2Fb".*;
    try testing.expectEqualStrings("a/b", place[0..DecodeUrl(ub, &place, place.len, &place, place.len)]);
    // Counted when it does not fit; only counted into nothing.
    var small: [2]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), DecodeUrl(ub, "a%2Fb", 5, &small, small.len));
    try testing.expectEqualStrings("a/", &small);
    try testing.expectEqual(@as(usize, 3), DecodeUrl(ub, "a%2Fb", 5, &small, 0));
    // A `%` that is no escape.
    for ([_][]const u8{ "%", "a%2", "%G0", "%0x" }) |broken| {
        try testing.expectEqual(utility.url.URL_BROKEN, DecodeUrl(ub, broken.ptr, broken.len, &into, into.len));
    }
}
