// SPDX-License-Identifier: MIT
//! A small XML reader: as much of XML as an SVG file uses.
//!
//! The text is walked a tag at a time. What it hands out is an element
//! opened - its name, its attributes, and whether it closed itself
//! (`<rect ... />`) - an element closed, or the characters between tags,
//! a CDATA section's as they are. A declaration (`<?xml ...?>`), a
//! processing instruction, a comment and the DOCTYPE, its internal
//! subset with it, are passed over.
//!
//! An attribute's value is handed out as the file has it, between its
//! quotes; `decode` undoes its references - the five named entities and
//! numeric ones, decimal and hexadecimal - in place, which is never
//! longer. An entity a DOCTYPE declares is left as written.
//!
//! **Nothing here trusts the file**: every look goes through the slice's
//! bounds, and a tag that does not end, or a name that is not one, is an
//! error rather than a guess.

pub const Error = error{Malformed};

/// What `Reader.next` found.
pub const Event = union(enum) {
    /// `<name attributes>`, or `<name attributes/>` when `empty`.
    open: struct { name: []const u8, attributes: []u8, empty: bool },
    /// `</name>`.
    close: []const u8,
    /// Characters between tags, references not undone; a CDATA section's.
    text: []u8,
};

pub const Reader = struct {
    text: []u8,
    at: usize = 0,

    pub fn next(r: *Reader) Error!?Event {
        while (r.at < r.text.len) {
            if (r.text[r.at] != '<') {
                const start = r.at;
                while (r.at < r.text.len and r.text[r.at] != '<') r.at += 1;
                return .{ .text = r.text[start..r.at] };
            }
            const rest = r.text[r.at..];
            if (startsWith(rest, "<!--")) {
                r.at = try r.past(r.at + 4, "-->");
            } else if (startsWith(rest, "<![CDATA[")) {
                const start = r.at + 9;
                const end = try r.past(start, "]]>");
                r.at = end;
                return .{ .text = r.text[start .. end - 3] };
            } else if (startsWith(rest, "<?")) {
                r.at = try r.past(r.at + 2, "?>");
            } else if (startsWith(rest, "<!")) {
                r.at = try r.pastDeclaration(r.at + 2);
            } else if (startsWith(rest, "</")) {
                var i = r.at + 2;
                const name = r.nameAt(&i) orelse return error.Malformed;
                i = r.skipSpace(i);
                if (i >= r.text.len or r.text[i] != '>') return error.Malformed;
                r.at = i + 1;
                return .{ .close = name };
            } else {
                var i = r.at + 1;
                const name = r.nameAt(&i) orelse return error.Malformed;
                const start = i;
                // To the tag's end, past any '>' inside a quoted value.
                var quote: u8 = 0;
                while (i < r.text.len) : (i += 1) {
                    const c = r.text[i];
                    if (quote != 0) {
                        if (c == quote) quote = 0;
                    } else if (c == '"' or c == '\'') {
                        quote = c;
                    } else if (c == '>') break;
                }
                if (i >= r.text.len) return error.Malformed;
                const empty = i > start and r.text[i - 1] == '/';
                const attributes = r.text[start..if (empty) i - 1 else i];
                r.at = i + 1;
                return .{ .open = .{ .name = name, .attributes = attributes, .empty = empty } };
            }
        }
        return null;
    }

    /// Where `end` ends, looking from `from`.
    fn past(r: *const Reader, from: usize, end: []const u8) Error!usize {
        var i = from;
        while (i + end.len <= r.text.len) : (i += 1) {
            if (startsWith(r.text[i..], end)) return i + end.len;
        }
        return error.Malformed;
    }

    /// Past a `<!...>` declaration: a DOCTYPE and its internal subset in
    /// brackets, quoted strings in either.
    fn pastDeclaration(r: *const Reader, from: usize) Error!usize {
        var i = from;
        var depth: u32 = 0;
        var quote: u8 = 0;
        while (i < r.text.len) : (i += 1) {
            const c = r.text[i];
            if (quote != 0) {
                if (c == quote) quote = 0;
                continue;
            }
            switch (c) {
                '"', '\'' => quote = c,
                '[' => depth += 1,
                ']' => depth -|= 1,
                '>' => if (depth == 0) return i + 1,
                '<' => if (depth > 0 and startsWith(r.text[i..], "<!--")) {
                    i = (try r.past(i + 4, "-->")) - 1;
                },
                else => {},
            }
        }
        return error.Malformed;
    }

    fn nameAt(r: *const Reader, i: *usize) ?[]const u8 {
        const start = i.*;
        while (i.* < r.text.len and isNameChar(r.text[i.*])) i.* += 1;
        if (i.* == start or !isNameStart(r.text[start])) return null;
        return r.text[start..i.*];
    }

    fn skipSpace(r: *const Reader, from: usize) usize {
        var i = from;
        while (i < r.text.len and isSpace(r.text[i])) i += 1;
        return i;
    }
};

/// An element's attributes, one at a time.
pub const Attributes = struct {
    text: []u8,
    at: usize = 0,

    pub const Attribute = struct { name: []const u8, value: []u8 };

    /// The next, or null at the end; `error.Malformed` for what is not
    /// `name="value"` or `name='value'`.
    pub fn next(a: *Attributes) Error!?Attribute {
        var i = a.at;
        while (i < a.text.len and isSpace(a.text[i])) i += 1;
        if (i == a.text.len) {
            a.at = i;
            return null;
        }
        const start = i;
        while (i < a.text.len and isNameChar(a.text[i])) i += 1;
        if (i == start or !isNameStart(a.text[start])) return error.Malformed;
        const name = a.text[start..i];
        while (i < a.text.len and isSpace(a.text[i])) i += 1;
        if (i == a.text.len or a.text[i] != '=') return error.Malformed;
        i += 1;
        while (i < a.text.len and isSpace(a.text[i])) i += 1;
        if (i == a.text.len or (a.text[i] != '"' and a.text[i] != '\'')) return error.Malformed;
        const quote = a.text[i];
        i += 1;
        const value_start = i;
        while (i < a.text.len and a.text[i] != quote) i += 1;
        if (i == a.text.len) return error.Malformed;
        a.at = i + 1;
        return .{ .name = name, .value = a.text[value_start..i] };
    }
};

/// The value's references undone in place: `&lt;` `&gt;` `&amp;`
/// `&quot;` `&apos;`, `&#NN;` and `&#xNN;` as UTF-8. One that is none of
/// these is left as it is.
pub fn decode(value: []u8) []u8 {
    var in: usize = 0;
    var out: usize = 0;
    while (in < value.len) {
        if (value[in] == '&') {
            if (reference(value[in..])) |found| {
                var bytes: [4]u8 = undefined;
                const n = utf8(found.code, &bytes);
                @memcpy(value[out..][0..n], bytes[0..n]);
                out += n;
                in += found.length;
                continue;
            }
        }
        value[out] = value[in];
        out += 1;
        in += 1;
    }
    return value[0..out];
}

const Reference = struct { code: u21, length: usize };

fn reference(text: []const u8) ?Reference {
    const semicolon = for (text, 0..) |c, i| {
        if (c == ';') break i;
        if (i > 10) return null;
    } else return null;
    const body = text[1..semicolon];
    const length = semicolon + 1;
    const named = [_]struct { []const u8, u8 }{
        .{ "lt", '<' }, .{ "gt", '>' }, .{ "amp", '&' }, .{ "quot", '"' }, .{ "apos", '\'' },
    };
    for (named) |entry| {
        if (eql(body, entry[0])) return .{ .code = entry[1], .length = length };
    }
    if (body.len < 2 or body[0] != '#') return null;
    var code: u32 = 0;
    const hex = body[1] == 'x' or body[1] == 'X';
    const digits = if (hex) body[2..] else body[1..];
    if (digits.len == 0) return null;
    for (digits) |c| {
        const d: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => if (hex) c - 'a' + 10 else return null,
            'A'...'F' => if (hex) c - 'A' + 10 else return null,
            else => return null,
        };
        code = code * (if (hex) @as(u32, 16) else 10) + d;
        if (code > 0x10FFFF) return null;
    }
    // A reference must not make itself longer than it is.
    var bytes: [4]u8 = undefined;
    if (code == 0 or utf8(@intCast(code), &bytes) > length) return null;
    return .{ .code = @intCast(code), .length = length };
}

fn utf8(code: u21, out: *[4]u8) usize {
    if (code < 0x80) {
        out[0] = @intCast(code);
        return 1;
    }
    if (code < 0x800) {
        out[0] = @intCast(0xC0 | (code >> 6));
        out[1] = @intCast(0x80 | (code & 0x3F));
        return 2;
    }
    if (code < 0x10000) {
        out[0] = @intCast(0xE0 | (code >> 12));
        out[1] = @intCast(0x80 | ((code >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (code & 0x3F));
        return 3;
    }
    out[0] = @intCast(0xF0 | (code >> 18));
    out[1] = @intCast(0x80 | ((code >> 12) & 0x3F));
    out[2] = @intCast(0x80 | ((code >> 6) & 0x3F));
    out[3] = @intCast(0x80 | (code & 0x3F));
    return 4;
}

pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isNameStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == ':' or c >= 0x80;
}

fn isNameChar(c: u8) bool {
    return isNameStart(c) or (c >= '0' and c <= '9') or c == '-' or c == '.';
}

fn startsWith(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and eql(text[0..prefix.len], prefix);
}

pub fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

// --- tests ---------------------------------------------------------------------

const testing = @import("std").testing;

test "elements, attributes and text; declarations, comments and a DOCTYPE passed over" {
    var text = ("<?xml version=\"1.0\"?>\n<!DOCTYPE svg [ <!ENTITY a \"<b>\"> ]><!-- x > y -->" ++
        "<svg a='1' b = \"x>y\"><g/>hi<![CDATA[<raw>]]></svg >").*;
    var r = Reader{ .text = &text };
    _ = (try r.next()).?.text; // the newline after the declaration
    const svg = (try r.next()).?.open;
    try testing.expectEqualStrings("svg", svg.name);
    try testing.expect(!svg.empty);
    var attrs = Attributes{ .text = svg.attributes };
    const a = (try attrs.next()).?;
    try testing.expectEqualStrings("a", a.name);
    try testing.expectEqualStrings("1", a.value);
    try testing.expectEqualStrings("x>y", (try attrs.next()).?.value);
    try testing.expect((try attrs.next()) == null);
    const g = (try r.next()).?.open;
    try testing.expectEqualStrings("g", g.name);
    try testing.expect(g.empty);
    try testing.expectEqualStrings("hi", (try r.next()).?.text);
    try testing.expectEqualStrings("<raw>", (try r.next()).?.text);
    try testing.expectEqualStrings("svg", (try r.next()).?.close);
    try testing.expect((try r.next()) == null);
}

test "references undone in place; a tag that does not end is an error" {
    var value = "a&amp;b &lt;&#65;&#x42;&#x20AC; &nbsp; &#0; &".*;
    try testing.expectEqualStrings("a&b <AB\u{20AC} &nbsp; &#0; &", decode(&value));
    var broken = "<svg a='1".*;
    var r = Reader{ .text = &broken };
    try testing.expectError(error.Malformed, r.next());
    var bad = "x='1' 2='3'".*;
    var attrs = Attributes{ .text = &bad };
    _ = try attrs.next();
    try testing.expectError(error.Malformed, attrs.next());
}
