// SPDX-License-Identifier: MIT
//! The entities a file's DOCTYPE declares, put in where the file names
//! them (since 1.7).
//!
//! A drawing program writes some of what it repeats once, in the
//! DOCTYPE's internal subset - `<!ENTITY st0 "fill:#FFF;">` - and names
//! it after (`style="&st0;"`, `xmlns="&ns_svg;"`); an entity may hold
//! elements too. The reader leaves those references as they are, so a
//! file that declares any is written out again first with each one
//! replaced by what it stands for: what an entity holds is read as the
//! file's own text from then on, elements and all.
//!
//! **Only general entities given as a literal** are put in: a parameter
//! entity (`%name;`) and an external one (`SYSTEM`, `PUBLIC`) are passed
//! over and their references left as written; so are the five XML names
//! and the numeric references, which the reader undoes itself. Nothing
//! is put in inside a comment, a CDATA section, a processing
//! instruction or the DOCTYPE. An entity may name another, `max_nesting`
//! deep - one that names itself, or deeper, is left as written.
//!
//! **Nothing here trusts the file**: a text whose entities would come to
//! more than `max_grown` times its size, or `max_bytes` in all, is not
//! expanded and is read as it is - entities that name entities can
//! otherwise grow without end from a few lines.

/// The most entities read from one DOCTYPE.
pub const max_entities = 64;
/// How deep entities are put in inside one another.
pub const max_nesting = 8;
/// The most an expanded text may grow, times the file's size.
pub const max_grown = 16;
/// The most bytes an expanded text may come to.
pub const max_bytes = 16 << 20;

/// One `<!ENTITY name "value">`: its name and its value, in the text.
pub const Entity = struct { name: []const u8, value: []const u8 };

/// A DOCTYPE's entities, and where it ends in the text.
pub const Declared = struct {
    list: [max_entities]Entity = undefined,
    count: usize = 0,
    /// Just past the DOCTYPE's `>`.
    end: usize = 0,

    fn find(entities: *const Declared, name: []const u8) ?[]const u8 {
        // The first declaration of a name is the one that counts.
        for (entities.list[0..entities.count]) |entity| if (eql(entity.name, name)) return entity.value;
        return null;
    }
};

/// The entities the text's DOCTYPE declares; null for a text with no
/// DOCTYPE before its first element, or one that declares none.
pub fn declared(text: []const u8) ?Declared {
    var i: usize = 0;
    if (text.len >= 3 and text[0] == 0xEF and text[1] == 0xBB and text[2] == 0xBF) i = 3;
    while (i < text.len) {
        if (isSpace(text[i])) {
            i += 1;
            continue;
        }
        if (startsWith(text[i..], "<?")) {
            i = after(text, i + 2, "?>") orelse return null;
        } else if (startsWith(text[i..], "<!--")) {
            i = after(text, i + 4, "-->") orelse return null;
        } else if (startsWith(text[i..], "<!DOCTYPE")) {
            return subset(text, i + 9);
        } else return null;
    }
    return null;
}

/// The DOCTYPE from `from`, past its name: the internal subset's
/// entities, if it has one.
fn subset(text: []const u8, from: usize) ?Declared {
    var entities = Declared{};
    var at = from;
    var quote: u8 = 0;
    // To the subset's `[`, past the name and any external id.
    while (at < text.len) : (at += 1) {
        const char = text[at];
        if (quote != 0) {
            if (char == quote) quote = 0;
            continue;
        }
        if (char == '"' or char == '\'') quote = char;
        if (char == '>') return null;
        if (char == '[') break;
    }
    if (at >= text.len) return null;
    at += 1;
    while (at < text.len) {
        const char = text[at];
        if (char == ']') {
            // Past the subset's end to the DOCTYPE's.
            at += 1;
            while (at < text.len and text[at] != '>') at += 1;
            if (at >= text.len) return null;
            entities.end = at + 1;
            return if (entities.count > 0) entities else null;
        }
        if (startsWith(text[at..], "<!--")) {
            at = after(text, at + 4, "-->") orelse return null;
        } else if (startsWith(text[at..], "<!ENTITY")) {
            at = entityAt(text, at + 8, &entities) orelse return null;
        } else if (startsWith(text[at..], "<")) {
            at = pastMarkup(text, at + 1) orelse return null;
        } else at += 1;
    }
    return null;
}

/// One `<!ENTITY ...>` from past its keyword: kept when it is a general
/// entity of a literal value. Just past its `>`, or null for one that
/// does not end.
fn entityAt(text: []const u8, from: usize, entities: *Declared) ?usize {
    var at = skipSpace(text, from);
    const parameter = at < text.len and text[at] == '%';
    if (parameter) at = skipSpace(text, at + 1);
    const start = at;
    while (at < text.len and isNameChar(text[at])) at += 1;
    const name = text[start..at];
    at = skipSpace(text, at);
    if (at < text.len and (text[at] == '"' or text[at] == '\'')) {
        const quote = text[at];
        const value_start = at + 1;
        const value_end = indexOf(text, value_start, quote) orelse return null;
        if (!parameter and name.len > 0 and entities.count < max_entities) {
            entities.list[entities.count] = .{ .name = name, .value = text[value_start..value_end] };
            entities.count += 1;
        }
        at = value_end + 1;
    }
    return pastMarkup(text, at);
}

/// Just past the `>` of a declaration, quoted strings passed over.
fn pastMarkup(text: []const u8, from: usize) ?usize {
    var at = from;
    var quote: u8 = 0;
    while (at < text.len) : (at += 1) {
        const char = text[at];
        if (quote != 0) {
            if (char == quote) quote = 0;
        } else if (char == '"' or char == '\'') {
            quote = char;
        } else if (char == '>') return at + 1;
    }
    return null;
}

/// How many bytes the text comes to with its entities put in; null when
/// that is more than may be.
pub fn expandedSize(text: []const u8, entities: *const Declared) ?usize {
    const most = @min(max_bytes, text.len *| max_grown);
    var sink = Sink{ .out = null, .most = most };
    if (!walk(text, entities, &sink)) return null;
    return sink.at;
}

/// The text with its entities put in, written into `into`, which holds
/// `expandedSize`.
pub fn expand(text: []const u8, entities: *const Declared, into: []u8) []u8 {
    var sink = Sink{ .out = into, .most = into.len };
    _ = walk(text, entities, &sink);
    return into[0..sink.at];
}

/// Where the expanded text goes: counted only, without `out`.
const Sink = struct {
    out: ?[]u8,
    at: usize = 0,
    most: usize,

    fn put(sink: *Sink, bytes: []const u8) bool {
        if (bytes.len > sink.most - sink.at) return false;
        if (sink.out) |out| @memcpy(out[sink.at..][0..bytes.len], bytes);
        sink.at += bytes.len;
        return true;
    }
};

/// The text copied into `sink` as it is up to the DOCTYPE's end, and
/// after it with each reference to an entity put in - outside comments,
/// CDATA sections and processing instructions. False when it grew past
/// what may be.
fn walk(text: []const u8, entities: *const Declared, sink: *Sink) bool {
    if (!sink.put(text[0..entities.end])) return false;
    var at = entities.end;
    var copied = at;
    while (at < text.len) {
        const char = text[at];
        if (char == '<') {
            const skip: ?[]const u8 = if (startsWith(text[at..], "<!--"))
                "-->"
            else if (startsWith(text[at..], "<![CDATA["))
                "]]>"
            else if (startsWith(text[at..], "<?"))
                "?>"
            else
                null;
            if (skip) |end| {
                at = after(text, at + 2, end) orelse text.len;
                continue;
            }
        } else if (char == '&') {
            if (referenceAt(text, at)) |ref| {
                if (entities.find(ref.name)) |value| {
                    if (!sink.put(text[copied..at])) return false;
                    if (!putValue(value, entities, sink, 1)) return false;
                    at = ref.end;
                    copied = at;
                    continue;
                }
            }
        }
        at += 1;
    }
    return sink.put(text[copied..]);
}

/// An entity's value put in, the entities it names in turn as deep as
/// may be.
fn putValue(value: []const u8, entities: *const Declared, sink: *Sink, depth: u32) bool {
    var i: usize = 0;
    var copied: usize = 0;
    while (i < value.len) {
        if (value[i] == '&' and depth < max_nesting) {
            if (referenceAt(value, i)) |ref| {
                if (entities.find(ref.name)) |inner| {
                    if (!sink.put(value[copied..i])) return false;
                    if (!putValue(inner, entities, sink, depth + 1)) return false;
                    i = ref.end;
                    copied = i;
                    continue;
                }
            }
        }
        i += 1;
    }
    return sink.put(value[copied..]);
}

/// `&name;` at `at`: the name, and just past the `;`. Null for anything
/// else - a numeric reference among them.
fn referenceAt(text: []const u8, at: usize) ?struct { name: []const u8, end: usize } {
    var index = at + 1;
    if (index >= text.len or !isNameStart(text[index])) return null;
    while (index < text.len and isNameChar(text[index])) index += 1;
    if (index >= text.len or text[index] != ';') return null;
    return .{ .name = text[at + 1 .. index], .end = index + 1 };
}

fn after(text: []const u8, from: usize, end: []const u8) ?usize {
    var at = from;
    while (at + end.len <= text.len) : (at += 1) {
        if (startsWith(text[at..], end)) return at + end.len;
    }
    return null;
}

fn indexOf(text: []const u8, from: usize, wanted: u8) ?usize {
    var at = from;
    while (at < text.len) : (at += 1) if (text[at] == wanted) return at;
    return null;
}

fn skipSpace(text: []const u8, from: usize) usize {
    var at = from;
    while (at < text.len and isSpace(text[at])) at += 1;
    return at;
}

fn startsWith(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and eql(text[0..prefix.len], prefix);
}

fn eql(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |x, y| if (x != y) return false;
    return true;
}

fn isSpace(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\r' or char == '\n';
}

fn isNameStart(char: u8) bool {
    return (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or char == '_' or char == ':' or char >= 0x80;
}

fn isNameChar(char: u8) bool {
    return isNameStart(char) or (char >= '0' and char <= '9') or char == '-' or char == '.';
}

// --- tests ---------------------------------------------------------------------

const testing = @import("std").testing;

fn expanded(text: []const u8, buffer: []u8) ?[]u8 {
    const entities = declared(text) orelse return null;
    const size = expandedSize(text, &entities) orelse return null;
    return expand(text, &entities, buffer[0..size]);
}

test "entities put in: in attributes and between tags, elements too, one inside another" {
    const text =
        \\<?xml version="1.0"?>
        \\<!DOCTYPE svg [
        \\  <!ENTITY ns "http://www.w3.org/2000/svg">
        \\  <!ENTITY % p "ignored">
        \\  <!ENTITY ext SYSTEM "x.dtd">
        \\  <!-- <!ENTITY no "x"> -->
        \\  <!ENTITY Rect '<rect fill="&c;"/>'>
        \\  <!ENTITY c "green">
        \\]>
        \\<svg xmlns="&ns;"><g>&Rect;&amp;&#65;&ext;&no;</g><!-- &c; --><![CDATA[&c;]]></svg>
    ;
    var buffer: [1024]u8 = undefined;
    const out = expanded(text, &buffer).?;
    const body = out[std.mem.indexOf(u8, out, "<svg").?..];
    try testing.expectEqualStrings(
        \\<svg xmlns="http://www.w3.org/2000/svg"><g><rect fill="green"/>&amp;&#65;&ext;&no;</g><!-- &c; --><![CDATA[&c;]]></svg>
    , body);
}

test "no DOCTYPE, none declared, one after the first element: nothing to put in" {
    try testing.expect(declared("<svg/>") == null);
    try testing.expect(declared("<!DOCTYPE svg PUBLIC \"a\" \"b\"><svg/>") == null);
    try testing.expect(declared("<svg/><!DOCTYPE svg [<!ENTITY a \"b\">]>") == null);
    try testing.expect(declared("<!DOCTYPE svg [<!ENTITY a \"b\">") == null);
}

test "an entity naming itself is left as written; one that grows too much is not expanded" {
    var buffer: [256]u8 = undefined;
    const loop = expanded("<!DOCTYPE s [<!ENTITY a \"x&a;\">]><s>&a;</s>", &buffer).?;
    try testing.expect(std.mem.endsWith(u8, loop, "<s>xxxxxxxx&a;</s>"));
    const bomb = "<!DOCTYPE s [<!ENTITY a \"aaaaaaaaaa\"><!ENTITY b \"&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;\"><!ENTITY c \"&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;\">]><s>&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;</s>";
    const entities = declared(bomb).?;
    try testing.expect(expandedSize(bomb, &entities) == null);
}

const std = @import("std");
