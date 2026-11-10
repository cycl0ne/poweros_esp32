// SPDX-License-Identifier: MPL-2.0
//! Utf8Kind: whether a text is UTF-8, and whether Latin-1 holds it.

const std = @import("std");
const sdk = @import("sdk");
const utility = sdk.utility;

const UtilityBase = @import("../utility.zig").UtilityBase;

/// Says whether a text is UTF-8, and whether every character of it is
/// one Latin-1 has.
///
/// SYNOPSIS:
/// ```zig
/// fn Utf8Kind(ub: *UtilityBase, bytes: [*]const u8, length: usize) u32
/// ```
///
/// SINCE: 1.4. LVO -284.
///
/// INPUTS:
/// - `bytes`, `length` - the text.
///
/// RESULT:
/// - UTF8KIND_ASCII: ASCII alone, UTF-8 and Latin-1 alike - and an empty
///   text.
/// - UTF8KIND_LATIN1: UTF-8 with characters past ASCII, all of them
///   Latin-1's.
/// - UTF8KIND_WIDE: UTF-8 with a character Latin-1 has not.
/// - UTF8KIND_NONE: bytes that are no UTF-8 - Latin-1, most likely.
///
/// BEHAVIOR:
/// UTF-8 is read as `Utf8ToLatin1` reads it: an overlong form, a
/// surrogate, a character past U+10FFFF, a byte that starts no character
/// and a sequence broken off make the text none. A byte order mark at the
/// start is passed over.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It only reads its input.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The text is the caller's.
///
/// NOTES:
/// Latin-1 that is not ASCII is almost never UTF-8 by chance: a letter
/// past 0x7F followed by one that is not a continuation byte breaks it.
/// A file is told by the whole of it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Utf8ToLatin1`, `Latin1ToUtf8`
///
/// EXAMPLES:
/// ```zig
/// // A file another system wrote: UTF-8 when the whole of it is.
/// const kind = ub.Utf8Kind(text.ptr, text.len);
/// const flags: u32 = if (kind == utility.UTF8KIND_NONE) ... else 0;
/// ```
pub fn Utf8Kind(_: *UtilityBase, bytes: [*]const u8, length: usize) u32 {
    const text = bytes[0..length];
    var at: usize = 0;
    if (text.len >= 3 and text[0] == 0xEF and text[1] == 0xBB and text[2] == 0xBF) at = 3;
    var kind = utility.text.UTF8KIND_ASCII;
    while (at < text.len) {
        const step = utility.utf8.decode(text[at..]);
        if (step.kind != .char) return utility.text.UTF8KIND_NONE;
        if (step.char > 0xFF) {
            kind = utility.text.UTF8KIND_WIDE;
        } else if (step.char > 0x7F and kind == utility.text.UTF8KIND_ASCII) {
            kind = utility.text.UTF8KIND_LATIN1;
        }
        at += step.length;
    }
    return kind;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;
const library = @import("../utility.zig");
const kexec = @import("../../exec/exec.zig");

test "Utf8Kind: ASCII, Latin-1's characters, wider ones, and none" {
    const ub = try library.setUp();
    defer kexec.deinit();
    const cases = [_]struct { []const u8, u32 }{
        .{ "", utility.text.UTF8KIND_ASCII },
        .{ "plain", utility.text.UTF8KIND_ASCII },
        .{ "\xEF\xBB\xBFplain", utility.text.UTF8KIND_ASCII },
        .{ "M\xC3\xBCller", utility.text.UTF8KIND_LATIN1 },
        .{ "\xE2\x82\xAC und \xC3\xA4", utility.text.UTF8KIND_WIDE },
        .{ "M\xFCller", utility.text.UTF8KIND_NONE },
        .{ "\xC3\xA4\xE2\x82", utility.text.UTF8KIND_NONE },
        .{ "\xED\xA0\x80", utility.text.UTF8KIND_NONE },
    };
    for (cases) |case| try testing.expectEqual(case[1], Utf8Kind(ub, case[0].ptr, case[0].len));
}
