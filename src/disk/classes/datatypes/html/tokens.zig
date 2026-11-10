// SPDX-License-Identifier: MIT
//! HTML taken apart into what it is made of: text, a tag that opens an
//! element, one that closes it, and what is left out - a comment, the
//! doctype, a processing instruction.
//!
//! **Tags are read the way a browser reads them.** `<` and a letter
//! start a tag and `</` and a letter end one; `<!--` is a comment that
//! runs to `-->`, and `<!` or `<?` anything else up to the next `>`. Any
//! other `<` is a character. A tag that the document ends inside is
//! dropped.
//!
//! **A tag's attributes are kept as the bytes they are**, and read when
//! one is asked for (`attribute`): a quote opens a value only after an
//! `=`, so a stray quote elsewhere does not run on to the end of the
//! document.
//!
//! **Some elements hold text, not markup.** After `<script>`, `<style>`,
//! `<textarea>`, `<title>`, `<xmp>`, `<iframe>` and `<noembed>`
//! everything up to the tag that ends that element is one stretch of
//! text, and after `<plaintext>` the rest of the document is.
//!
//! The document is Latin-1 by the time it is read here. Nothing of the
//! markup is past ASCII, so a tag is found the same in either.

const elements = @import("elements.zig");

pub const Kind = enum { text, start, end, other, done };

pub const Token = struct {
    kind: Kind,
    /// The text, or the tag's name as it is written.
    text: []const u8 = "",
    /// What stands between a start tag's name and its `>`.
    attributes: []const u8 = "",
    /// Text that is an element's own (`<script>`'s, `<textarea>`'s):
    /// no tags in it, and for some no character references either.
    raw: bool = false,
};

pub const Reader = struct {
    source: []const u8,
    at: usize = 0,
    /// The element whose text runs to its end tag, while there is one.
    raw: []const u8 = "",
    /// After `<plaintext>`: the rest is text.
    to_end: bool = false,

    /// The next thing in the document.
    pub fn next(r: *Reader) Token {
        const source = r.source;
        if (r.at >= source.len) return .{ .kind = .done };
        if (r.to_end) {
            const text = source[r.at..];
            r.at = source.len;
            return .{ .kind = .text, .text = text, .raw = true };
        }
        if (r.raw.len > 0) {
            const until = rawEnd(source, r.at, r.raw);
            const text = source[r.at..until];
            r.at = until;
            r.raw = "";
            if (text.len > 0) return .{ .kind = .text, .text = text, .raw = true };
            if (r.at >= source.len) return .{ .kind = .done };
        }
        const at = r.at;
        if (source[at] != '<') {
            var end = at + 1;
            while (end < source.len and source[end] != '<') end += 1;
            r.at = end;
            return .{ .kind = .text, .text = source[at..end] };
        }
        const after: u8 = if (at + 1 < source.len) source[at + 1] else 0;
        if (after == '!') {
            if (startsWith(source[at..], "<!--")) {
                r.at = commentEnd(source, at + 4);
            } else {
                r.at = pastByte(source, at + 2, '>');
            }
            return .{ .kind = .other };
        }
        if (after == '?') {
            r.at = pastByte(source, at + 2, '>');
            return .{ .kind = .other };
        }
        if (after == '/') {
            const first: u8 = if (at + 2 < source.len) source[at + 2] else 0;
            if (isLetter(first)) {
                const name_end = nameEnd(source, at + 2);
                r.at = pastByte(source, name_end, '>');
                return .{ .kind = .end, .text = source[at + 2 .. name_end] };
            }
            // `</>` is nothing; `</` and anything else a comment.
            r.at = pastByte(source, at + 2, '>');
            return .{ .kind = .other };
        }
        if (!isLetter(after)) {
            r.at = at + 1;
            return .{ .kind = .text, .text = source[at .. at + 1] };
        }
        const name_end = nameEnd(source, at + 1);
        const close = tagEnd(source, name_end) orelse {
            r.at = source.len;
            return .{ .kind = .done };
        };
        r.at = close + 1;
        const name = source[at + 1 .. name_end];
        const token: Token = .{ .kind = .start, .text = name, .attributes = source[name_end..close] };
        switch (elements.tagOf(name)) {
            .script, .style, .textarea, .title, .xmp, .iframe, .noembed => r.raw = name,
            .plaintext => r.to_end = true,
            else => {},
        }
        return token;
    }
};

/// Where the text of a raw element `name` ends: at `</name` and a space,
/// a `/` or a `>`, or at the end of the document.
fn rawEnd(source: []const u8, from: usize, name: []const u8) usize {
    var at = from;
    while (at + 2 + name.len <= source.len) : (at += 1) {
        if (source[at] != '<' or source[at + 1] != '/') continue;
        if (!elements.sameName(source[at + 2 ..][0..name.len], lowerOf(name))) continue;
        const after: u8 = if (at + 2 + name.len < source.len) source[at + 2 + name.len] else '>';
        if (after == '>' or after == '/' or isSpace(after)) return at;
    }
    return source.len;
}

/// `name` in lower case, for `sameName`; a raw element's name is never
/// longer than ten letters.
fn lowerOf(name: []const u8) []const u8 {
    const known = [_][]const u8{ "script", "style", "textarea", "title", "xmp", "iframe", "noembed" };
    for (known) |each| {
        if (elements.sameName(name, each)) return each;
    }
    return "";
}

/// Past a comment that started before `from`: after its `-->`, or at
/// the end. `<!-->` and `<!--->` are comments with nothing in them.
fn commentEnd(source: []const u8, from: usize) usize {
    if (from < source.len and source[from] == '>') return from + 1;
    if (from + 1 < source.len and source[from] == '-' and source[from + 1] == '>') return from + 2;
    var at = from;
    while (at + 2 < source.len) : (at += 1) {
        if (source[at] == '-' and source[at + 1] == '-' and source[at + 2] == '>') return at + 3;
    }
    return source.len;
}

/// Past the next `byte` from `from`, or the end.
fn pastByte(source: []const u8, from: usize, byte: u8) usize {
    var at = from;
    while (at < source.len) : (at += 1) {
        if (source[at] == byte) return at + 1;
    }
    return source.len;
}

/// Where a tag's name that starts at `from` ends.
fn nameEnd(source: []const u8, from: usize) usize {
    var at = from;
    while (at < source.len) : (at += 1) {
        const char = source[at];
        if (isSpace(char) or char == '/' or char == '>') break;
    }
    return at;
}

/// The `>` that ends a tag whose attributes start at `from`: a quote
/// after an `=` runs to the next of its kind. Null when the document ends
/// first.
fn tagEnd(source: []const u8, from: usize) ?usize {
    var at = from;
    var after_equals = false;
    while (at < source.len) : (at += 1) {
        const char = source[at];
        if (char == '>') return at;
        if (char == '=') {
            after_equals = true;
            continue;
        }
        if (isSpace(char)) continue;
        if (after_equals and (char == '"' or char == '\'')) {
            at += 1;
            while (at < source.len and source[at] != char) at += 1;
            if (at >= source.len) return null;
        }
        after_equals = false;
    }
    return null;
}

/// An attribute's value as it is written, quotes taken off, character
/// references left in; "" for one given without a value, null for one
/// not given.
pub fn attribute(attributes: []const u8, name: []const u8) ?[]const u8 {
    var at: usize = 0;
    const text = attributes;
    while (at < text.len) {
        while (at < text.len and (isSpace(text[at]) or text[at] == '/')) at += 1;
        if (at >= text.len) return null;
        const name_start = at;
        // A name may start with `=`; it ends at a space, `/`, `>` or `=`.
        at += 1;
        while (at < text.len and !isSpace(text[at]) and text[at] != '/' and text[at] != '=') at += 1;
        const found = text[name_start..at];
        while (at < text.len and isSpace(text[at])) at += 1;
        var value: []const u8 = "";
        if (at < text.len and text[at] == '=') {
            at += 1;
            while (at < text.len and isSpace(text[at])) at += 1;
            if (at < text.len and (text[at] == '"' or text[at] == '\'')) {
                const quote = text[at];
                const value_start = at + 1;
                at = value_start;
                while (at < text.len and text[at] != quote) at += 1;
                value = text[value_start..at];
                if (at < text.len) at += 1;
            } else {
                const value_start = at;
                while (at < text.len and !isSpace(text[at])) at += 1;
                value = text[value_start..at];
            }
        }
        if (elements.sameName(found, name)) return value;
    }
    return null;
}

pub fn isSpace(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\n' or char == '\r' or char == 0x0C;
}

pub fn isLetter(char: u8) bool {
    return (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z');
}

fn startsWith(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    for (text[0..prefix.len], prefix) |char, want| {
        if (char != want) return false;
    }
    return true;
}

const std = @import("std");
const testing = std.testing;

fn expectToken(reader: *Reader, kind: Kind, text: []const u8) !Token {
    const token = reader.next();
    try testing.expectEqual(kind, token.kind);
    try testing.expectEqualStrings(text, token.text);
    return token;
}

test "text, tags, comments and a lone < come apart" {
    var reader = Reader{ .source = "a <B class=\"x>y\">b</b><!-- c -->d < e<!DOCTYPE html><?x?></ >" };
    _ = try expectToken(&reader, .text, "a ");
    const bold = try expectToken(&reader, .start, "B");
    try testing.expectEqualStrings("x>y", attribute(bold.attributes, "class").?);
    _ = try expectToken(&reader, .text, "b");
    _ = try expectToken(&reader, .end, "b");
    _ = try expectToken(&reader, .other, "");
    _ = try expectToken(&reader, .text, "d ");
    _ = try expectToken(&reader, .text, "<");
    _ = try expectToken(&reader, .text, " e");
    _ = try expectToken(&reader, .other, "");
    _ = try expectToken(&reader, .other, "");
    _ = try expectToken(&reader, .other, "");
    try testing.expectEqual(Kind.done, reader.next().kind);
}

test "a script's text is text up to its end tag, whatever is in it" {
    var reader = Reader{ .source = "<script>if (a < b) x = '</p>';</SCRIPT >after<plaintext><b>all" };
    _ = try expectToken(&reader, .start, "script");
    const inside = try expectToken(&reader, .text, "if (a < b) x = '</p>';");
    try testing.expect(inside.raw);
    _ = try expectToken(&reader, .end, "SCRIPT");
    _ = try expectToken(&reader, .text, "after");
    _ = try expectToken(&reader, .start, "plaintext");
    _ = try expectToken(&reader, .text, "<b>all");
    try testing.expectEqual(Kind.done, reader.next().kind);
}

test "attributes: quoted, bare, without a value, and not there" {
    const attributes = " href = 'a b' checked data-x=1 title=\"q\" /";
    try testing.expectEqualStrings("a b", attribute(attributes, "href").?);
    try testing.expectEqualStrings("", attribute(attributes, "checked").?);
    try testing.expectEqualStrings("1", attribute(attributes, "data-x").?);
    try testing.expectEqualStrings("q", attribute(attributes, "title").?);
    try testing.expect(attribute(attributes, "alt") == null);
}

test "a tag or a comment the document ends inside" {
    var open_tag = Reader{ .source = "x<a href=\"y" };
    _ = try expectToken(&open_tag, .text, "x");
    try testing.expectEqual(Kind.done, open_tag.next().kind);
    var open_comment = Reader{ .source = "<!-- never" };
    try testing.expectEqual(Kind.other, open_comment.next().kind);
    try testing.expectEqual(Kind.done, open_comment.next().kind);
}
