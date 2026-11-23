// SPDX-License-Identifier: MIT
//! The texts of the window that asks what a pairing needs: a device's
//! name and the number a pairing shows, in the markup the window's text
//! gadgets read, and the passkey typed into it.

/// How much of a device's name the window shows, in bytes.
pub const name_most = 64;
/// The room a name takes in markup: in bold, each `<` doubled, and an
/// ellipsis where it is cut.
pub const Name = [name_most * 2 + 16]u8;
/// The room a number takes in markup.
pub const Number = [32]u8;
/// How many digits a passkey has at the most.
pub const passkey_digits = 6;

/// `name` in the window's markup: in bold, a `<` written `<<` so that it
/// is read as itself, cut after `name_most` bytes - before a character
/// the cut would split - with an ellipsis after it.
pub fn nameMarkup(name: []const u8, into: *Name) [*:0]const u8 {
    var cut = name.len;
    if (cut > name_most) {
        cut = name_most;
        // A UTF-8 continuation byte is never a character's first.
        while (cut > 0 and name[cut] & 0xC0 == 0x80) cut -= 1;
    }
    var length: usize = 0;
    const open = "<b>";
    @memcpy(into[0..open.len], open);
    length += open.len;
    for (name[0..cut]) |byte| {
        if (byte == '<') {
            into[length] = '<';
            length += 1;
        }
        into[length] = byte;
        length += 1;
    }
    if (cut < name.len) {
        const ellipsis = "\xE2\x80\xA6";
        @memcpy(into[length..][0..ellipsis.len], ellipsis);
        length += ellipsis.len;
    }
    const close = "</>";
    @memcpy(into[length..][0..close.len], close);
    length += close.len;
    into[length] = 0;
    return @ptrCast(into);
}

/// A pairing's number as devices show it - six digits, zeros first - in
/// bold, in the window's font at `rows` pixels tall (up to 999).
pub fn numberMarkup(number: u32, rows: u32, into: *Number) [*:0]const u8 {
    var length: usize = 0;
    const size = "<s=";
    @memcpy(into[0..size.len], size);
    length += size.len;
    length += digitsInto(@min(rows, 999), 0, into[length..]);
    const bold = "><b>";
    @memcpy(into[length..][0..bold.len], bold);
    length += bold.len;
    length += digitsInto(number % 1_000_000, passkey_digits, into[length..]);
    const close = "</></>";
    @memcpy(into[length..][0..close.len], close);
    length += close.len;
    into[length] = 0;
    return @ptrCast(into);
}

/// `value` in decimal at the start of `into`, at least `least` digits -
/// zeros first: how many were written.
fn digitsInto(value: u32, least: usize, into: []u8) usize {
    var count: usize = 1;
    var rest = value / 10;
    while (rest != 0) : (rest /= 10) count += 1;
    count = @max(count, least);
    var left = value;
    var index = count;
    while (index > 0) {
        index -= 1;
        into[index] = '0' + @as(u8, @intCast(left % 10));
        left /= 10;
    }
    return count;
}

/// The passkey typed: one to six digits; null for anything else.
pub fn passkeyOf(typed: []const u8) ?u32 {
    if (typed.len == 0 or typed.len > passkey_digits) return null;
    var value: u32 = 0;
    for (typed) |char| {
        if (char < '0' or char > '9') return null;
        value = value * 10 + (char - '0');
    }
    return value;
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

test "a name in bold, a < doubled, a long one cut before a whole character with an ellipsis" {
    var into: Name = undefined;
    try testing.expectEqualStrings("<b>LE test</>", std.mem.span(nameMarkup("LE test", &into)));
    try testing.expectEqualStrings("<b>a<<b</>", std.mem.span(nameMarkup("a<b", &into)));
    // 63 bytes, then a two-byte character across the cut at 64.
    const long = "x" ** 63 ++ "\xC3\xA4" ++ "tail";
    const shown = std.mem.span(nameMarkup(long, &into));
    try testing.expectEqualStrings("<b>" ++ "x" ** 63 ++ "\xE2\x80\xA6</>", shown);
    // The worst a name can take still fits.
    const brackets = "<" ** 200;
    const most = std.mem.span(nameMarkup(brackets, &into));
    try testing.expectEqual(@as(usize, 3 + 2 * name_most + 3 + 3), most.len);
}

test "a number as six digits, zeros first; a passkey of one to six digits" {
    var into: Number = undefined;
    try testing.expectEqualStrings("<s=32><b>004217</></>", std.mem.span(numberMarkup(4217, 32, &into)));
    try testing.expectEqualStrings("<s=999><b>999999</></>", std.mem.span(numberMarkup(999999, 5000, &into)));
    try testing.expectEqualStrings("<s=8><b>000000</></>", std.mem.span(numberMarkup(0, 8, &into)));
    try testing.expectEqual(@as(?u32, 4217), passkeyOf("004217"));
    try testing.expectEqual(@as(?u32, 7), passkeyOf("7"));
    try testing.expectEqual(@as(?u32, null), passkeyOf(""));
    try testing.expectEqual(@as(?u32, null), passkeyOf("1234567"));
    try testing.expectEqual(@as(?u32, null), passkeyOf("-12"));
}
