// SPDX-License-Identifier: MIT
//! JSON text read into a document, once through and without recursion.
//!
//! The reader keeps the array or object it is inside - `open` - and what
//! it expects next (`Expect`): a value, the first item or member or the
//! end, a name, a colon, or a comma or the end after a value. A value that
//! starts an array or object is placed and becomes the one open; its end
//! makes its parent the one open again. So the text may nest as deep as
//! memory lets it, at no cost of stack.
//!
//! A string's escapes are undone as it is copied into the document - the
//! copy never longer than the text - and its bytes checked as UTF-8 on the
//! way. A `\u` escape of half a surrogate pair without its other half is
//! read as U+FFFD. A number's grammar is checked here and its value made
//! by `number/_number.zig`, with room for its slow way asked for only when
//! a number needs it.
//!
//! Where reading stops, the byte is kept, and the line and the column are
//! counted to it only then.

const sdk = @import("sdk");
const exec = sdk.exec;
const json = sdk.json;
const JSONBase = @import("../json_base.zig").JSONBase;
const _document = @import("../document/_document.zig");
const _number = @import("../number/_number.zig");
const _utf8 = @import("../utf8/_utf8.zig");
const Value = json.Value;
const Document = json.Document;

/// `length` bytes of text read into a new document: the document, or null
/// with `report` saying why.
pub fn read(base: *JSONBase, text: [*]const u8, length: usize, flags: u32, report: ?*json.Error) ?*Document {
    // About the room the values of that much text take.
    const document = _document.make(base, length * 2) orelse {
        tell(report, json.JSONERR_NOMEM, text, 0);
        return null;
    };
    var reader = Reader{ .base = base, .text = text, .length = length, .flags = flags, .document = document };
    const root = reader.run();
    if (reader.decimal) |room| base.sys_base.FreeVec(room);
    const top = root orelse {
        tell(report, reader.code, text, reader.stopped);
        _document.free(base, document);
        return null;
    };
    document.root = top;
    if (report) |into| into.* = .{};
    return document;
}

/// `report` filled in for `code` at byte `offset` of `text`.
pub fn tell(report: ?*json.Error, code: i32, text: [*]const u8, offset: usize) void {
    const into = report orelse return;
    var line: u32 = 1;
    var column: u32 = 1;
    for (0..offset) |at| {
        const byte = text[at];
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else if (byte & 0xC0 != 0x80) {
            // A continuation byte is part of the character before it.
            column += 1;
        }
    }
    into.* = .{ .code = code, .offset = @intCast(@min(offset, 0xFFFF_FFFF)), .line = line, .column = column };
}

/// What the reader looks for next.
const Expect = enum {
    /// A value: the whole text's, an item's or a member's.
    value,
    /// The first item of an array, or its end.
    first_item,
    /// An item after a comma - or, with comments, the end.
    item,
    /// The first member of an object, or its end.
    first_member,
    /// A member after a comma - or, with comments, the end.
    member,
    /// The colon after a member's name.
    colon,
    /// After a value inside an array or object: a comma or its end.
    after,
};

const Reader = struct {
    base: *JSONBase,
    text: [*]const u8,
    length: usize,
    flags: u32,
    document: *Document,
    at: usize = 0,
    /// Why and where reading stopped.
    code: i32 = json.JSONERR_OK,
    stopped: usize = 0,
    /// A number's slow way's room, made the first time it is wanted.
    decimal: ?*_number.Decimal = null,

    /// Null, `code` kept at `where`.
    fn fail(reader: *Reader, code: i32, where: usize) ?*Value {
        reader.code = code;
        reader.stopped = where;
        return null;
    }

    fn comments(reader: *const Reader) bool {
        return reader.flags & json.JSONF_COMMENTS != 0;
    }

    /// The whole text read: its value, or null with the reason kept.
    fn run(reader: *Reader) ?*Value {
        // A byte order mark is no part of the text.
        if (reader.length >= 3 and reader.text[0] == 0xEF and reader.text[1] == 0xBB and reader.text[2] == 0xBF) reader.at = 3;
        var root: ?*Value = null;
        var open: ?*Value = null;
        var name: ?[*:0]u8 = null;
        var name_length: u32 = 0;
        var expect: Expect = .value;
        while (true) {
            if (!reader.skipBlanks()) return null;
            if (reader.at >= reader.length) {
                if (root == null) return reader.fail(json.JSONERR_EMPTY, reader.at);
                return reader.fail(json.JSONERR_END, reader.at);
            }
            const char = reader.text[reader.at];
            switch (expect) {
                .value => {
                    const made = reader.value(char) orelse return null;
                    if (open) |container| {
                        _document.link(container, made, null);
                        made.name = name;
                        made.name_length = name_length;
                        name = null;
                    } else {
                        root = made;
                    }
                    if (made.kind == json.JSON_ARRAY or made.kind == json.JSON_OBJECT) {
                        open = made;
                        expect = if (made.kind == json.JSON_ARRAY) .first_item else .first_member;
                        continue;
                    }
                    expect = .after;
                },
                .first_item, .item => {
                    if (char == ']' and (expect == .first_item or reader.comments())) {
                        reader.at += 1;
                        open = open.?.parent;
                        expect = .after;
                    } else {
                        expect = .value;
                        continue;
                    }
                },
                .first_member, .member => {
                    if (char == '}' and (expect == .first_member or reader.comments())) {
                        reader.at += 1;
                        open = open.?.parent;
                        expect = .after;
                    } else if (char == '"') {
                        const got = reader.string() orelse return null;
                        name = got.text;
                        name_length = got.length;
                        expect = .colon;
                        continue;
                    } else {
                        return reader.fail(json.JSONERR_UNEXPECTED, reader.at);
                    }
                },
                .colon => {
                    if (char != ':') return reader.fail(json.JSONERR_UNEXPECTED, reader.at);
                    reader.at += 1;
                    expect = .value;
                    continue;
                },
                .after => {
                    const container = open.?;
                    if (char == ',') {
                        reader.at += 1;
                        expect = if (container.kind == json.JSON_ARRAY) .item else .member;
                        continue;
                    }
                    const closing: u8 = if (container.kind == json.JSON_ARRAY) ']' else '}';
                    if (char != closing) return reader.fail(json.JSONERR_UNEXPECTED, reader.at);
                    reader.at += 1;
                    open = container.parent;
                },
            }
            // A value is whole: the root's, when nothing is open.
            if (open == null) {
                if (!reader.skipBlanks()) return null;
                if (reader.at < reader.length) return reader.fail(json.JSONERR_TRAILING, reader.at);
                return root;
            }
        }
    }

    /// Blanks gone past - and comments, with JSONF_COMMENTS. False for a
    /// comment that does not end.
    fn skipBlanks(reader: *Reader) bool {
        while (reader.at < reader.length) {
            const char = reader.text[reader.at];
            if (char == ' ' or char == '\t' or char == '\n' or char == '\r') {
                reader.at += 1;
                continue;
            }
            if (char != '/' or !reader.comments() or reader.at + 1 >= reader.length) return true;
            const second = reader.text[reader.at + 1];
            if (second == '/') {
                reader.at += 2;
                while (reader.at < reader.length and reader.text[reader.at] != '\n') reader.at += 1;
            } else if (second == '*') {
                const start = reader.at;
                reader.at += 2;
                while (true) {
                    if (reader.at + 1 >= reader.length) {
                        _ = reader.fail(json.JSONERR_END, start);
                        return false;
                    }
                    if (reader.text[reader.at] == '*' and reader.text[reader.at + 1] == '/') break;
                    reader.at += 1;
                }
                reader.at += 2;
            } else {
                return true;
            }
        }
        return true;
    }

    /// The value starting with `char` at the reader's place, made and gone
    /// past; an array or object only begun.
    fn value(reader: *Reader, char: u8) ?*Value {
        const base = reader.base;
        switch (char) {
            '{', '[' => {
                const made = _document.value(base, reader.document, if (char == '[') json.JSON_ARRAY else json.JSON_OBJECT) orelse return reader.fail(json.JSONERR_NOMEM, reader.at);
                reader.at += 1;
                return made;
            },
            '"' => {
                const got = reader.string() orelse return null;
                const made = _document.value(base, reader.document, json.JSON_STRING) orelse return reader.fail(json.JSONERR_NOMEM, reader.at);
                made.string = got.text;
                made.length = got.length;
                return made;
            },
            't' => return reader.word("true", json.JSON_BOOLEAN, true),
            'f' => return reader.word("false", json.JSON_BOOLEAN, false),
            'n' => return reader.word("null", json.JSON_NULL, false),
            '-', '0'...'9' => return reader.number(),
            else => return reader.fail(json.JSONERR_UNEXPECTED, reader.at),
        }
    }

    /// `true`, `false` or `null`, spelt out whole.
    fn word(reader: *Reader, comptime spelt: []const u8, kind: u32, truth: bool) ?*Value {
        for (spelt, 0..) |letter, offset| {
            const at = reader.at + offset;
            if (at >= reader.length) return reader.fail(json.JSONERR_END, at);
            if (reader.text[at] != letter) return reader.fail(json.JSONERR_UNEXPECTED, at);
        }
        const made = _document.value(reader.base, reader.document, kind) orelse return reader.fail(json.JSONERR_NOMEM, reader.at);
        made.truth = truth;
        reader.at += spelt.len;
        return made;
    }

    fn isDigit(reader: *const Reader, at: usize) bool {
        return at < reader.length and reader.text[at] >= '0' and reader.text[at] <= '9';
    }

    /// A number: `-`, then 0 or digits not starting with 0, then perhaps
    /// a point and digits, then perhaps an exponent.
    fn number(reader: *Reader) ?*Value {
        const start = reader.at;
        var at = start;
        if (reader.text[at] == '-') at += 1;
        if (!reader.isDigit(at)) return reader.fail(if (at >= reader.length) json.JSONERR_END else json.JSONERR_NUMBER, at);
        if (reader.text[at] == '0') {
            at += 1;
            if (reader.isDigit(at)) return reader.fail(json.JSONERR_NUMBER, at);
        } else {
            while (reader.isDigit(at)) at += 1;
        }
        var whole = true;
        if (at < reader.length and reader.text[at] == '.') {
            at += 1;
            if (!reader.isDigit(at)) return reader.fail(if (at >= reader.length) json.JSONERR_END else json.JSONERR_NUMBER, at);
            while (reader.isDigit(at)) at += 1;
            whole = false;
        }
        if (at < reader.length and (reader.text[at] == 'e' or reader.text[at] == 'E')) {
            at += 1;
            if (at < reader.length and (reader.text[at] == '+' or reader.text[at] == '-')) at += 1;
            if (!reader.isDigit(at)) return reader.fail(if (at >= reader.length) json.JSONERR_END else json.JSONERR_NUMBER, at);
            while (reader.isDigit(at)) at += 1;
            whole = false;
        }
        const got = _number.toDouble(reader.text[start..at], reader, decimalRoom) orelse return reader.fail(json.JSONERR_NOMEM, start);
        const made = _document.value(reader.base, reader.document, json.JSON_NUMBER) orelse return reader.fail(json.JSONERR_NOMEM, start);
        made.number = got.number;
        if (whole) {
            if (got.integer) |integer| {
                made.integer = integer;
                made.flags |= json.JSONVF_INTEGER;
            }
        }
        reader.at = at;
        return made;
    }

    fn decimalRoom(reader: *Reader) ?*_number.Decimal {
        if (reader.decimal == null) {
            const memory = reader.base.sys_base.AllocVec(@sizeOf(_number.Decimal), exec.MEMF_ANY) orelse return null;
            reader.decimal = @ptrCast(@alignCast(memory));
        }
        return reader.decimal;
    }

    const Got = struct { text: [*:0]u8, length: u32 };

    /// The string whose quote is at the reader's place, its escapes undone,
    /// copied into the document, and gone past.
    fn string(reader: *Reader) ?Got {
        const text = reader.text;
        const start = reader.at + 1;
        // Its end: the first quote no backslash stands before.
        var end = start;
        while (true) {
            if (end >= reader.length) {
                _ = reader.fail(json.JSONERR_END, reader.length);
                return null;
            }
            const char = text[end];
            if (char == '"') break;
            end += if (char == '\\') 2 else 1;
        }
        const into = _document.room(reader.base, reader.document, end - start) orelse {
            _ = reader.fail(json.JSONERR_NOMEM, reader.at);
            return null;
        };
        var at = start;
        var length: usize = 0;
        while (at < end) {
            const char = text[at];
            if (char == '\\') {
                const escape = text[at + 1];
                const plain: ?u8 = switch (escape) {
                    '"', '\\', '/' => escape,
                    'b' => 0x08,
                    'f' => 0x0C,
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => null,
                };
                if (plain) |byte| {
                    into[length] = byte;
                    length += 1;
                    at += 2;
                    continue;
                }
                if (escape != 'u') {
                    _ = reader.fail(json.JSONERR_ESCAPE, at);
                    return null;
                }
                var point: u21 = hexAt(text, at + 2, end) orelse {
                    _ = reader.fail(json.JSONERR_ESCAPE, at);
                    return null;
                };
                at += 6;
                if (point >= 0xD800 and point <= 0xDBFF) {
                    // The high half of a pair: the low half must follow.
                    const low: ?u21 = if (at + 1 < end and text[at] == '\\' and text[at + 1] == 'u') hexAt(text, at + 2, end) else null;
                    if (low != null and low.? >= 0xDC00 and low.? <= 0xDFFF) {
                        point = 0x10000 + ((point - 0xD800) << 10) + (low.? - 0xDC00);
                        at += 6;
                    } else {
                        point = _utf8.replacement;
                    }
                } else if (point >= 0xDC00 and point <= 0xDFFF) {
                    point = _utf8.replacement;
                }
                length += _utf8.encode(point, into + length);
                continue;
            }
            if (char < 0x20) {
                _ = reader.fail(json.JSONERR_CONTROL, at);
                return null;
            }
            const bytes = _utf8.lengthAt(text, at, end);
            if (bytes == 0) {
                _ = reader.fail(json.JSONERR_UTF8, at);
                return null;
            }
            for (0..bytes) |offset| into[length + offset] = text[at + offset];
            length += bytes;
            at += bytes;
        }
        into[length] = 0;
        reader.at = end + 1;
        return .{ .text = into, .length = @intCast(length) };
    }
};

/// The four hexadecimal digits at `text[at]`, all before `end`; null
/// when they are not.
fn hexAt(text: [*]const u8, at: usize, end: usize) ?u21 {
    if (at + 4 > end) return null;
    var point: u21 = 0;
    for (0..4) |offset| {
        const char = text[at + offset];
        const digit: u21 = switch (char) {
            '0'...'9' => char - '0',
            'a'...'f' => char - 'a' + 10,
            'A'...'F' => char - 'A' + 10,
            else => return null,
        };
        point = point * 16 + digit;
    }
    return point;
}
