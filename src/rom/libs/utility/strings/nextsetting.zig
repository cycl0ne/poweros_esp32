// SPDX-License-Identifier: MPL-2.0
//! NextSetting: the next `KEY=value` pair of a line of settings.

const std = @import("std");
const sdk = @import("sdk");

const UtilityBase = @import("../utility.zig").UtilityBase;
const SettingScan = sdk.utility.SettingScan;

/// Reads the next `KEY=value` pair of a line of settings.
///
/// SYNOPSIS:
/// ```zig
/// fn NextSetting(_: *UtilityBase, scan: *SettingScan) i32
/// ```
///
/// SINCE: 1.2. LVO -260.
///
/// INPUTS:
/// - `scan` - the text and its length, and where to go on from: `at`,
///   0 for the first pair.
///
/// RESULT:
/// 1 with the pair in `scan.key` and `scan.value`, which point into the
/// text, and their lengths. 0 at the text's end, with `key` and `value`
/// null. -1 for a value whose opening quote has no closing one; `key`
/// is that value's key, `value` is null.
///
/// BEHAVIOR:
/// Blanks - spaces, tabs, carriage returns and line feeds - part the
/// pairs. A pair is `KEY=value`, or `KEY value` with spaces or tabs
/// between the two. The key ends at a blank or an '='. A value that
/// starts with a double quote runs to the next one, blanks and '=' in it,
/// and is handed out without them; there are no escapes. Any other value
/// runs to the next blank. `KEY=` before a blank, and a key alone at the
/// end, have an empty value.
///
/// `at` is left after the pair, so the next call reads the one after
/// it; at the text's end, and after a quote that is not closed, it is
/// `length`, and every call after answers 0.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads only the text and writes only `scan`.
/// - Locks: none taken, none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated or copied: `key` and `value` point into the
/// caller's text, and are good as long as it is.
///
/// NOTES:
/// It knows no keys: which there are, and what their values may be, is
/// the caller's. The settings files in ENV:Sys are lines of these pairs,
/// and SDK's `prefs.Pairs` reads them through this call.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// dos.library `ReadArgs`, `ReadItem` (a command line, with the shell's
/// escapes); `Strnicmp`
///
/// EXAMPLES:
/// ```zig
/// var scan: utility.SettingScan = .{ .text = line.ptr, .length = line.len };
/// while (true) {
///     const got = ub.NextSetting(&scan);
///     if (got <= 0) break; // -1: a quote not closed
///     use(scan.keyText(), scan.valueText());
/// }
/// ```
pub fn NextSetting(_: *UtilityBase, scan: *SettingScan) i32 {
    const text = scan.text[0..scan.length];
    scan.key = null;
    scan.key_length = 0;
    scan.value = null;
    scan.value_length = 0;
    var i = @min(scan.at, text.len);
    while (i < text.len and blank(text[i])) i += 1;
    if (i >= text.len) {
        scan.at = text.len;
        return 0;
    }
    var end = i;
    while (end < text.len and !blank(text[end]) and text[end] != '=') end += 1;
    scan.key = text.ptr + i;
    scan.key_length = end - i;
    i = end;
    if (i < text.len and text[i] == '=') {
        i += 1;
    } else {
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    }
    if (i < text.len and text[i] == '"') {
        const from = i + 1;
        var close = from;
        while (close < text.len and text[close] != '"') close += 1;
        if (close >= text.len) {
            scan.at = text.len;
            return -1;
        }
        scan.value = text.ptr + from;
        scan.value_length = close - from;
        scan.at = close + 1;
        return 1;
    }
    var value_end = i;
    while (value_end < text.len and !blank(text[value_end])) value_end += 1;
    scan.value = text.ptr + i;
    scan.value_length = value_end - i;
    scan.at = value_end;
    return 1;
}

fn blank(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\r' or char == '\n';
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

/// The pairs of `line`, as "KEY|value" each, into `into`; how many, or
/// null when a quote is not closed.
fn pairsOf(line: []const u8, into: [][]const u8, store: [][64]u8) ?usize {
    const ub: *UtilityBase = undefined; // NextSetting never reads it
    var scan: SettingScan = .{ .text = line.ptr, .length = line.len };
    var n: usize = 0;
    while (true) {
        const got = NextSetting(ub, &scan);
        if (got < 0) return null;
        if (got == 0) return n;
        const joined = std.fmt.bufPrint(&store[n], "{s}|{s}", .{ scan.keyText(), scan.valueText() }) catch unreachable;
        into[n] = joined;
        n += 1;
    }
}

test "NextSetting: KEY=value and KEY value, quotes, blanks of every kind" {
    var pairs: [8][]const u8 = undefined;
    var store: [8][64]u8 = undefined;
    const n = pairsOf(" ICONSIZE=48\tVIEW name\r\nPICTURE=\"SYS:Prefs/Sea Side.png\" SNAP=\n", &pairs, &store).?;
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualStrings("ICONSIZE|48", pairs[0]);
    try testing.expectEqualStrings("VIEW|name", pairs[1]);
    try testing.expectEqualStrings("PICTURE|SYS:Prefs/Sea Side.png", pairs[2]);
    try testing.expectEqualStrings("SNAP|", pairs[3]);
}

test "NextSetting: a key alone, '=' in a value, an empty quoted value" {
    var pairs: [8][]const u8 = undefined;
    var store: [8][64]u8 = undefined;
    const n = pairsOf("A=b=c NAME=\"x=y z\" EMPTY=\"\" LAST", &pairs, &store).?;
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualStrings("A|b=c", pairs[0]);
    try testing.expectEqualStrings("NAME|x=y z", pairs[1]);
    try testing.expectEqualStrings("EMPTY|", pairs[2]);
    try testing.expectEqualStrings("LAST|", pairs[3]);
}

test "NextSetting: nothing, blanks only, and a quote not closed" {
    var pairs: [8][]const u8 = undefined;
    var store: [8][64]u8 = undefined;
    try testing.expectEqual(@as(?usize, 0), pairsOf("", &pairs, &store));
    try testing.expectEqual(@as(?usize, 0), pairsOf(" \t\r\n", &pairs, &store));
    try testing.expectEqual(@as(?usize, null), pairsOf("OK=1 NAME=\"open", &pairs, &store));

    const ub: *UtilityBase = undefined;
    const line = "NAME=\"open";
    var scan: SettingScan = .{ .text = line.ptr, .length = line.len };
    try testing.expectEqual(@as(i32, -1), NextSetting(ub, &scan));
    try testing.expectEqualStrings("NAME", scan.keyText());
    try testing.expectEqual(@as(?[*]const u8, null), scan.value);
    try testing.expectEqual(line.len, scan.at);
    try testing.expectEqual(@as(i32, 0), NextSetting(ub, &scan));
}
