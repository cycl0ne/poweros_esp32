// SPDX-License-Identifier: MIT
//! Keyword files: the format C:Mount reads its mountlists in and
//! C:net/AddNetInterface its interface files - `Keyword = value` pairs in
//! any order and any case. A value is a number - decimal, or hexadecimal
//! after `0x`, with a sign either way - a word, or a string in quotes;
//! `;` and newlines separate, `/* */` comments nest.
//!
//! The Scanner hands out one token at a time and remembers the line and
//! column each began at, so a program can name the place of whatever it
//! does not like. It reads a file through dos.library, a character at a
//! time, or text already in memory.

const dosextens = @import("dosextens.zig");
const DosBase = @import("../../interface/dos.zig").DosBase;

/// The longest a value or a name may be; longer ones are cut there.
pub const max_token = 128;

pub const Kind = enum { word, string, number };

pub const Scanner = struct {
    /// Where the characters come from: a file through dos, or `text`.
    dl: ?*DosBase = null,
    file: ?*dosextens.FileHandle = null,
    text: []const u8 = &.{},
    at: usize = 0,

    last: u8 = ' ',
    line: u32 = 1,
    column: u32 = 0,
    /// The token, as text, and what it read as.
    token: [max_token:0]u8 = @splat(0),
    len: usize = 0,
    kind: Kind = .word,
    quoted: bool = false,
    /// Where the token began.
    token_line: u32 = 1,
    token_column: u32 = 0,
    /// The token's value, when it is a number.
    number: i32 = 0,

    /// A scanner over a file of `dl`'s.
    pub fn ofFile(dl: *DosBase, file: *dosextens.FileHandle) Scanner {
        return .{ .dl = dl, .file = file };
    }

    /// A scanner over text in memory.
    pub fn ofText(text: []const u8) Scanner {
        return .{ .text = text };
    }

    fn getCh(scanner: *Scanner) u8 {
        var char: u8 = 0;
        if (scanner.file) |file| {
            const got = scanner.dl.?.FGetC(file);
            char = if (got < 0) 0 else @intCast(got);
        } else if (scanner.at < scanner.text.len) {
            char = scanner.text[scanner.at];
            scanner.at += 1;
        }
        if (scanner.last == '\n') {
            scanner.line += 1;
            scanner.column = 0;
        }
        scanner.column += 1;
        scanner.last = char;
        return char;
    }

    fn put(scanner: *Scanner, char: u8) void {
        if (scanner.len < max_token) {
            scanner.token[scanner.len] = char;
            scanner.len += 1;
        }
    }

    /// The next token. False at the end.
    pub fn next(scanner: *Scanner) bool {
        scanner.len = 0;
        scanner.quoted = false;
        var char = scanner.last;
        while (char == '\t' or char == ' ' or char == '\n' or char == '\r' or char == ';') {
            while (char == '\t' or char == ' ' or char == '\n' or char == '\r' or char == ';') char = scanner.getCh();
            // /* a comment, which may hold comments */
            if (char == '/') {
                scanner.token_line = scanner.line;
                scanner.token_column = scanner.column;
                char = scanner.getCh();
                if (char == '*') {
                    var deep: u32 = 1;
                    var before: u8 = ' ';
                    while (deep != 0 and char != 0) {
                        char = scanner.getCh();
                        if (char == '/' and before == '*') {
                            deep -= 1;
                            before = ' ';
                        } else if (char == '*' and before == '/') {
                            deep += 1;
                            before = ' ';
                        } else before = char;
                    }
                    char = scanner.getCh();
                } else {
                    scanner.put('/');
                }
            }
        }
        if (scanner.len == 0) {
            scanner.token_line = scanner.line;
            scanner.token_column = scanner.column;
        }
        if (char == '"') {
            char = scanner.getCh();
            while (char != '"' and char != '\n' and char != 0) {
                scanner.put(char);
                char = scanner.getCh();
            }
            if (char == '"') {
                _ = scanner.getCh();
                scanner.quoted = true;
            }
            scanner.kind = .string;
        } else if (char == '=') {
            scanner.put('=');
            _ = scanner.getCh();
            scanner.kind = .string;
        } else {
            while (char != '\t' and char != ' ' and char != '\n' and char != '\r' and char != ';' and char != '=' and char != 0) {
                scanner.put(char);
                char = scanner.getCh();
            }
            scanner.kind = if (scanner.len > 0 and scanner.asNumber()) .number else .word;
        }
        scanner.token[scanner.len] = 0;
        return scanner.len > 0 or scanner.quoted;
    }

    /// Whether the token is a number, and what it is.
    fn asNumber(scanner: *Scanner) bool {
        if (scanner.quoted) return false;
        var at: usize = 0;
        var negate = false;
        if (scanner.token[0] == '-') {
            negate = true;
            at = 1;
        }
        var base: u32 = 10;
        if (scanner.token[at] == '0' and (scanner.token[at + 1] == 'x' or scanner.token[at + 1] == 'X')) {
            base = 16;
            at += 2;
        }
        var value: u32 = 0;
        var digits: usize = 0;
        while (at < scanner.len) : (at += 1) {
            const char = scanner.token[at];
            const digit: u32 = switch (char) {
                '0'...'9' => char - '0',
                'a'...'f' => if (base == 16) char - 'a' + 10 else return false,
                'A'...'F' => if (base == 16) char - 'A' + 10 else return false,
                else => return false,
            };
            value = value *% base +% digit;
            digits += 1;
        }
        if (digits == 0) return false;
        scanner.number = @bitCast(value);
        if (negate) scanner.number = -scanner.number;
        return true;
    }

    /// The token as a C string.
    pub fn text0(scanner: *const Scanner) [*:0]const u8 {
        return @ptrCast(&scanner.token);
    }
};
