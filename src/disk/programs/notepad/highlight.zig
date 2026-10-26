// SPDX-License-Identifier: MIT
//! Zig's highlighting: the kind of each byte of a line, as textedit.gadget's
//! highlight hook gives it (`TEHL_*`).
//!
//! A line is enough. Zig has no comment or string that goes on past its
//! line's end: a comment runs from `//` to the end, a line of a multi-line
//! string from `\\` to the end, and every other string and character
//! closes on its own line. So each line is labelled from its own bytes,
//! left to right:
//!
//!   `//` to the end           a comment (`///` and `//!` too)
//!   `\\` to the end           a string
//!   `"..."`, `'...'`          a string, a backslash keeping the next byte
//!   `@name`                   a built-in function; `@"..."` is a name
//!   a digit and on            a number, with its `_`, `.`, base and
//!                             exponent
//!   a name                    a keyword, a type (`u8`, `bool`, `anyopaque`,
//!                             `i37`), a constant (`true`, `null`,
//!                             `undefined`) as a number, or plain text
//!
//! The keywords and the types are the compiler's own lists (its tokenizer's
//! keywords, its primitives).

const te = @import("sdk").gadgets.textedit;

const keywords = [_][]const u8{
    "addrspace",   "align",    "allowzero", "and",         "anyframe",    "anytype",
    "asm",         "break",    "callconv",  "catch",       "comptime",    "const",
    "continue",    "defer",    "else",      "enum",        "errdefer",    "error",
    "export",      "extern",   "fn",        "for",         "if",          "inline",
    "noalias",     "noinline", "nosuspend", "opaque",      "or",          "orelse",
    "packed",      "pub",      "resume",    "return",      "linksection", "struct",
    "suspend",     "switch",   "test",      "threadlocal", "try",         "union",
    "unreachable", "var",      "volatile",  "while",
};

/// The primitive types; an `i` or `u` with a number of bits is one too.
const types = [_][]const u8{
    "anyerror",     "anyframe",     "anyopaque",   "bool",     "c_int",
    "c_long",       "c_longdouble", "c_longlong",  "c_char",   "c_short",
    "c_uint",       "c_ulong",      "c_ulonglong", "c_ushort", "comptime_float",
    "comptime_int", "f128",         "f16",         "f32",      "f64",
    "f80",          "isize",        "noreturn",    "type",     "usize",
    "void",
};

/// The primitive values, drawn as numbers are.
const constants = [_][]const u8{ "true", "false", "null", "undefined" };

/// The kinds of `text`'s bytes written into `kinds`, as long as it; bytes
/// that are none of the kinds are left as they are (`TEHL_TEXT`).
pub fn label(text: []const u8, kinds: []u8) void {
    var at: usize = 0;
    while (at < text.len) {
        const byte = text[at];
        const next: u8 = if (at + 1 < text.len) text[at + 1] else 0;
        if (byte == '/' and next == '/') {
            mark(kinds, at, text.len, te.TEHL_COMMENT);
            return;
        }
        if (byte == '\\' and next == '\\') {
            mark(kinds, at, text.len, te.TEHL_STRING);
            return;
        }
        if (byte == '"' or byte == '\'') {
            const end = quoted(text, at);
            mark(kinds, at, end, te.TEHL_STRING);
            at = end;
            continue;
        }
        if (byte == '@') {
            if (next == '"') {
                at = quoted(text, at + 1);
                continue;
            }
            const end = nameEnd(text, at + 1);
            if (end > at + 1) mark(kinds, at, end, te.TEHL_BUILTIN);
            at = @max(end, at + 1);
            continue;
        }
        if (isDigit(byte)) {
            const end = numberEnd(text, at);
            mark(kinds, at, end, te.TEHL_NUMBER);
            at = end;
            continue;
        }
        if (isNameStart(byte)) {
            const end = nameEnd(text, at);
            mark(kinds, at, end, kindOfName(text[at..end]));
            at = end;
            continue;
        }
        at += 1;
    }
}

fn mark(kinds: []u8, from: usize, to: usize, kind: u8) void {
    for (kinds[from..to]) |*each| each.* = kind;
}

/// Where a string or a character that opens at `from` ends: after its
/// closing quote, or at the line's end when it has none.
fn quoted(text: []const u8, from: usize) usize {
    const quote = text[from];
    var at = from + 1;
    while (at < text.len) : (at += 1) {
        if (text[at] == '\\') {
            at += 1;
            continue;
        }
        if (text[at] == quote) return at + 1;
    }
    return text.len;
}

/// Where a number that starts at `from` ends: its digits, letters and
/// `_`, a `.` with a digit after it, and the sign after an exponent's
/// letter (`e` in a decimal, `p` in a hexadecimal one).
fn numberEnd(text: []const u8, from: usize) usize {
    const hex = from + 1 < text.len and text[from] == '0' and (text[from + 1] == 'x' or text[from + 1] == 'X');
    var at = from;
    while (at < text.len) : (at += 1) {
        const byte = text[at];
        if (isNameByte(byte)) continue;
        if (byte == '.' and at + 1 < text.len and isNameByte(text[at + 1]) and text[at + 1] != '_') continue;
        if ((byte == '+' or byte == '-') and at > from) {
            const before = text[at - 1];
            const exponent = if (hex) before == 'p' or before == 'P' else before == 'e' or before == 'E';
            if (exponent) continue;
        }
        break;
    }
    return at;
}

fn nameEnd(text: []const u8, from: usize) usize {
    var at = from;
    if (at < text.len and !isNameStart(text[at])) return at;
    while (at < text.len and isNameByte(text[at])) at += 1;
    return at;
}

fn kindOfName(name: []const u8) u8 {
    if (isOneOf(name, &keywords)) return te.TEHL_KEYWORD;
    if (isOneOf(name, &types) or isIntegerType(name)) return te.TEHL_TYPE;
    if (isOneOf(name, &constants)) return te.TEHL_NUMBER;
    return te.TEHL_TEXT;
}

/// `i` or `u` and a number of bits: `u8`, `i37`, `u0`.
fn isIntegerType(name: []const u8) bool {
    if (name.len < 2 or (name[0] != 'i' and name[0] != 'u')) return false;
    for (name[1..]) |byte| if (!isDigit(byte)) return false;
    return true;
}

fn isOneOf(name: []const u8, list: []const []const u8) bool {
    for (list) |each| {
        if (each.len != name.len) continue;
        for (each, name) |a, b| {
            if (a != b) break;
        } else return true;
    }
    return false;
}

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn isNameStart(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or byte == '_';
}

fn isNameByte(byte: u8) bool {
    return isNameStart(byte) or isDigit(byte);
}

// --- tests (host) ------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// The kinds of `text` as letters, one a byte: . text, k keyword, t type,
/// b built-in, s string, n number, c comment.
fn kindsOf(text: []const u8) [80]u8 {
    var kinds: [80]u8 = @splat(te.TEHL_TEXT);
    label(text, kinds[0..text.len]);
    var letters: [80]u8 = @splat(' ');
    for (kinds[0..text.len], letters[0..text.len]) |kind, *letter| letter.* = ".ktbsnc"[kind];
    return letters;
}

fn expectKinds(text: []const u8, expected: []const u8) !void {
    const letters = kindsOf(text);
    try testing.expectEqualStrings(expected, letters[0..text.len]);
}

test "keywords, types, built-ins and constants" {
    try expectKinds("pub fn main() void {", "kkk.kk........tttt..");
    try expectKinds("const x: u8 = @intCast(y);", "kkkkk....tt...bbbbbbbb....");
    try expectKinds("var ok = true orelse null;", "kkk......nnnn.kkkkkk.nnnn.");
    try expectKinds("i37 u0 x8 usize ux", "ttt.tt....ttttt...");
}

test "strings, characters and escapes" {
    try expectKinds("a = \"x\\\"y\" + 'c';", "....ssssss...sss.");
    try expectKinds("\"open to the end", "ssssssssssssssss");
    try expectKinds("    \\\\ fn \"x\"", "....sssssssss");
    try expectKinds("@\"fn\" = 1;", "........n.");
}

test "numbers and ranges" {
    try expectKinds("0x1F_FF 1.5e-3 0..10", "nnnnnnn.nnnnnn.n..nn");
    try expectKinds("0x1p+3 x[1..]", "nnnnnn...n...");
}

test "comments" {
    try expectKinds("x = 1; // fn u8", "....n..cccccccc");
    try expectKinds("/// doc", "ccccccc");
    try expectKinds("a / b", ".....");
}
