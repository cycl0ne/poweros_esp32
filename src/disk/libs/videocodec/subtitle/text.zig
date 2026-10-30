// SPDX-License-Identifier: MIT
//! Subtitles as text: SubRip's lines and SubStation Alpha's events made
//! the plain lines GetVideoSubtitle hands out - UTF-8 as they came, their
//! lines apart by `\n`.
//!
//! **SubRip** (Matroska's S_TEXT/UTF8) is the text as it is shown, with a
//! few of HTML's tags - `<i>`, `<b>`, `<u>`, `<font ...>` - which are taken
//! out, a text in `<i>` throughout marked italic; SubStation's codes in
//! braces, which some files carry too (`{\an8}`), go the same way.
//!
//! **SubStation Alpha** (ASS and SSA) is each event as Matroska keeps it:
//! ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, and
//! the text, which carries codes in braces - `{\i1}`, `{\pos(x,y)}` - and
//! escapes: `\N` a new line, `\n` and `\h` a space. Only dialogue is kept:
//! an event placed on the picture (`\pos`, `\move`) - a sign - or a drawing
//! (`\p1` and on) is left out. The script's header, the track's setup,
//! says which styles are italic (`readStyles`); `\i1` and `\i0` turn it
//! on and off within an event, `\r` back to the style's.

/// What became of a text: how many bytes it made, and whether all it
/// shows is in italics.
pub const Cleaned = struct {
    length: usize,
    italic: bool,
};

/// The styles a script names, and which are italic.
pub const max_styles = 32;
const style_name_bytes = 32;

pub const Styles = struct {
    names: [max_styles][style_name_bytes]u8 = undefined,
    lengths: [max_styles]u8 = @splat(0),
    italic: [max_styles]bool = @splat(false),
    count: usize = 0,

    /// Whether the style named `name` is italic: false for one the script
    /// does not name.
    pub fn isItalic(styles: *const Styles, name: []const u8) bool {
        const wanted = if (name.len > 0 and name[0] == '*') name[1..] else name;
        for (0..styles.count) |n| {
            if (same(styles.names[n][0..styles.lengths[n]], wanted)) return styles.italic[n];
        }
        return false;
    }
};

/// The styles of a script's header - its `[V4+ Styles]` or `[V4 Styles]`
/// section: the `Format:` line says which field is Italic, each `Style:`
/// line names one.
pub fn readStyles(header: []const u8, styles: *Styles) void {
    styles.count = 0;
    var italic_field: ?usize = null;
    var name_field: usize = 0;
    var in_styles = false;
    var lines = Lines{ .rest = header };
    while (lines.next()) |raw| {
        const line = trim(raw);
        if (line.len == 0) continue;
        if (line[0] == '[') {
            in_styles = startsWithNoCase(line, "[v4+ styles]") or startsWithNoCase(line, "[v4 styles]");
            continue;
        }
        if (!in_styles) continue;
        if (startsWithNoCase(line, "format:")) {
            var fields = Fields{ .rest = line["format:".len..] };
            var n: usize = 0;
            while (fields.next()) |field| : (n += 1) {
                const word = trim(field);
                if (sameNoCase(word, "italic")) italic_field = n;
                if (sameNoCase(word, "name")) name_field = n;
            }
            continue;
        }
        if (!startsWithNoCase(line, "style:") or styles.count == max_styles) continue;
        var fields = Fields{ .rest = line["style:".len..] };
        var n: usize = 0;
        var name: []const u8 = "";
        var italic = false;
        while (fields.next()) |field| : (n += 1) {
            const value = trim(field);
            if (n == name_field) name = value;
            // SubStation's -1 is true; some writers put 1.
            if (italic_field != null and n == italic_field.?) italic = value.len > 0 and value[0] != '0';
        }
        const length = @min(name.len, style_name_bytes);
        @memcpy(styles.names[styles.count][0..length], name[0..length]);
        styles.lengths[styles.count] = @intCast(length);
        styles.italic[styles.count] = italic;
        styles.count += 1;
    }
}

/// A SubStation Alpha event, as Matroska keeps it, made lines into
/// `out`: null when it is left out - a sign, a drawing, or nothing to
/// show.
pub fn ass(event: []const u8, styles: *const Styles, out: []u8) ?Cleaned {
    // The text comes after the eighth comma; the style is the third field.
    var fields = Fields{ .rest = event };
    var style: []const u8 = "";
    for (0..8) |n| {
        const field = fields.next() orelse return null;
        if (n == 2) style = trim(field);
    }
    const text = fields.rest orelse return null;
    const style_italic = styles.isItalic(style);
    var made = Made{ .out = out, .italic_now = style_italic };
    var at: usize = 0;
    while (at < text.len) {
        const char = text[at];
        if (char == '{') {
            const close = indexOf(text, at + 1, '}') orelse {
                made.put(char);
                at += 1;
                continue;
            };
            if (!overrides(text[at + 1 .. close], style_italic, &made.italic_now)) return null;
            at = close + 1;
            continue;
        }
        if (char == '\\' and at + 1 < text.len) {
            switch (text[at + 1]) {
                'N' => {
                    made.newline();
                    at += 2;
                    continue;
                },
                'n', 'h' => {
                    made.put(' ');
                    at += 2;
                    continue;
                },
                else => {},
            }
        }
        made.put(char);
        at += 1;
    }
    return made.finish();
}

/// The codes in one pair of braces: false when they make the event a
/// sign or a drawing; italics followed.
fn overrides(block: []const u8, style_italic: bool, italic: *bool) bool {
    var at: usize = 0;
    while (indexOf(block, at, '\\')) |slash| {
        const tag = block[slash + 1 ..];
        at = slash + 1;
        if (startsWith(tag, "pos(") or startsWith(tag, "move(")) return false;
        if (tag.len >= 2 and tag[0] == 'p' and isDigit(tag[1])) {
            if (number(tag[1..]) != 0) return false;
            continue;
        }
        if (tag.len >= 2 and tag[0] == 'i' and isDigit(tag[1])) {
            italic.* = number(tag[1..]) != 0;
            continue;
        }
        if (tag.len >= 1 and tag[0] == 'r' and (tag.len == 1 or !isLower(tag[1]))) italic.* = style_italic;
    }
    return true;
}

/// A SubRip text made lines into `out`, its tags taken out: null when
/// nothing is left to show.
pub fn srt(text: []const u8, out: []u8) ?Cleaned {
    var made = Made{ .out = out, .italic_now = false };
    var at: usize = 0;
    while (at < text.len) {
        const char = text[at];
        if (char == '<') {
            if (indexOf(text, at + 1, '>')) |close| {
                const tag = text[at + 1 .. close];
                if (htmlTag(tag)) |italic| {
                    if (italic) |on| made.italic_now = on;
                    at = close + 1;
                    continue;
                }
            }
        }
        if (char == '{' and at + 1 < text.len and text[at + 1] == '\\') {
            if (indexOf(text, at + 1, '}')) |close| {
                at = close + 1;
                continue;
            }
        }
        if (char == '\r') {
            at += 1;
            continue;
        }
        if (char == '\n') made.newline() else made.put(char);
        at += 1;
    }
    return made.finish();
}

/// Whether `tag` - what lies between `<` and `>` - is one of SubRip's: null
/// for none, else what it does to italics (null for nothing).
fn htmlTag(tag: []const u8) ??bool {
    const closing = tag.len > 0 and tag[0] == '/';
    const name = if (closing) tag[1..] else tag;
    if (sameNoCase(name, "i")) return !closing;
    if (sameNoCase(name, "b") or sameNoCase(name, "u") or sameNoCase(name, "s")) return @as(?bool, null);
    if (sameNoCase(name, "font") or startsWithNoCase(name, "font ")) return @as(?bool, null);
    return null;
}

/// The lines being made: spaces at the ends of each left out, and empty
/// lines; what shows noted as italic or not.
const Made = struct {
    out: []u8,
    length: usize = 0,
    italic_now: bool,
    /// Something has shown in italics, and something not.
    slanted: bool = false,
    upright: bool = false,
    /// A space or a line end waits for what follows it.
    space: bool = false,
    line_end: bool = false,

    fn put(made: *Made, char: u8) void {
        if (char == ' ' or char == '\t') {
            if (made.length != 0 and !made.line_end) made.space = true;
            return;
        }
        if (made.line_end) {
            made.byte('\n');
            made.line_end = false;
        } else if (made.space) {
            made.byte(' ');
        }
        made.space = false;
        made.byte(char);
        if (made.italic_now) made.slanted = true else made.upright = true;
    }

    fn newline(made: *Made) void {
        if (made.length != 0) made.line_end = true;
        made.space = false;
    }

    fn byte(made: *Made, char: u8) void {
        if (made.length + 1 < made.out.len) {
            made.out[made.length] = char;
            made.length += 1;
        }
    }

    fn finish(made: *Made) ?Cleaned {
        if (made.length == 0) return null;
        made.out[made.length] = 0;
        return .{ .length = made.length, .italic = made.slanted and !made.upright };
    }
};

/// The lines of a text, its line ends CR LF or LF.
const Lines = struct {
    rest: ?[]const u8,

    fn next(lines: *Lines) ?[]const u8 {
        const rest = lines.rest orelse return null;
        if (indexOf(rest, 0, '\n')) |end| {
            lines.rest = rest[end + 1 ..];
            return if (end > 0 and rest[end - 1] == '\r') rest[0 .. end - 1] else rest[0..end];
        }
        lines.rest = null;
        return rest;
    }
};

/// The fields of a line, apart by commas.
const Fields = struct {
    rest: ?[]const u8,

    fn next(fields: *Fields) ?[]const u8 {
        const rest = fields.rest orelse return null;
        if (indexOf(rest, 0, ',')) |comma| {
            fields.rest = rest[comma + 1 ..];
            return rest[0..comma];
        }
        fields.rest = null;
        return rest;
    }
};

fn indexOf(text: []const u8, from: usize, char: u8) ?usize {
    var at = from;
    while (at < text.len) : (at += 1) {
        if (text[at] == char) return at;
    }
    return null;
}

fn trim(text: []const u8) []const u8 {
    var start: usize = 0;
    var end = text.len;
    while (start < end and (text[start] == ' ' or text[start] == '\t')) start += 1;
    while (end > start and (text[end - 1] == ' ' or text[end - 1] == '\t' or text[end - 1] == '\r')) end -= 1;
    return text[start..end];
}

fn number(text: []const u8) u32 {
    var value: u32 = 0;
    for (text) |char| {
        if (!isDigit(char)) break;
        value = value *| 10 +| (char - '0');
    }
    return value;
}

fn isDigit(char: u8) bool {
    return char >= '0' and char <= '9';
}

fn isLower(char: u8) bool {
    return char >= 'a' and char <= 'z';
}

fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + 32 else char;
}

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn sameNoCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (lower(x) != lower(y)) return false;
    }
    return true;
}

fn startsWith(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and same(text[0..prefix.len], prefix);
}

fn startsWithNoCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and sameNoCase(text[0..prefix.len], prefix);
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

fn cleanedAss(event: []const u8, styles: *const Styles, buffer: []u8) ?[]const u8 {
    const made = ass(event, styles, buffer) orelse return null;
    return buffer[0..made.length];
}

test "SubStation Alpha: the dialogue's lines, its codes out; signs and drawings left out; italics by style and code" {
    var styles: Styles = .{};
    readStyles(
        "[Script Info]\r\nTitle: x\r\n\r\n[V4+ Styles]\r\n" ++
            "Format: Name, Fontname, Fontsize, PrimaryColour, Bold, Italic, Alignment\r\n" ++
            "Style: Default,Arial,48,&H00FFFFFF,0,0,2\r\n" ++
            "Style: Thoughts,Arial,48,&H00FFFFFF,0,-1,2\r\n\r\n[Events]\r\nFormat: Layer, Start\r\n",
        &styles,
    );
    try testing.expectEqual(@as(usize, 2), styles.count);
    try testing.expect(!styles.isItalic("Default"));
    try testing.expect(styles.isItalic("Thoughts"));
    try testing.expect(styles.isItalic("*Thoughts"));

    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("Hallo Welt\nzweite Zeile", cleanedAss("0,0,Default,,0,0,0,,{\\b1}Hallo{\\b0}  Welt\\N zweite\\hZeile", &styles, &buffer).?);
    // A comma in the text is the text's.
    try testing.expectEqualStrings("Ja, nein", cleanedAss("1,0,Default,Name,0,0,0,,Ja, nein", &styles, &buffer).?);
    try testing.expectEqual(@as(?[]const u8, null), cleanedAss("2,0,Default,,0,0,0,,{\\an8\\pos(320,40)}Schild", &styles, &buffer));
    try testing.expectEqual(@as(?[]const u8, null), cleanedAss("3,0,Default,,0,0,0,,{\\move(1,2,3,4)}Schild", &styles, &buffer));
    try testing.expectEqual(@as(?[]const u8, null), cleanedAss("4,0,Default,,0,0,0,,{\\p1}m 0 0 l 10 0{\\p0}", &styles, &buffer));
    try testing.expectEqual(@as(?[]const u8, null), cleanedAss("5,0,Default,,0,0,0,,{\\fad(100,100)}", &styles, &buffer));
    // \pbo is no drawing; \p0 ends one.
    try testing.expectEqualStrings("Text", cleanedAss("6,0,Default,,0,0,0,,{\\pbo2\\p0}Text", &styles, &buffer).?);

    try testing.expect(ass("7,0,Thoughts,,0,0,0,,Gedacht", &styles, &buffer).?.italic);
    try testing.expect(ass("8,0,Default,,0,0,0,,{\\i1}Ganz schräg", &styles, &buffer).?.italic);
    try testing.expect(!ass("9,0,Default,,0,0,0,,{\\i1}Halb{\\i0} gerade", &styles, &buffer).?.italic);
    try testing.expect(ass("10,0,Thoughts,,0,0,0,,{\\i0}Gerade{\\r} schräg", &styles, &buffer) != null);
    try testing.expect(ass("10,0,Thoughts,,0,0,0,,{\\i0}{\\r}Zurück", &styles, &buffer).?.italic);
    try testing.expect(!ass("11,0,Thoughts,,0,0,0,,{\\i0}Gerade", &styles, &buffer).?.italic);
}

test "SubRip: its tags and braces out, italics when the whole is, line ends kept" {
    var buffer: [128]u8 = undefined;
    var made = srt("<i>Ganz</i>\r\n<i>schräg</i>", &buffer).?;
    try testing.expectEqualStrings("Ganz\nschräg", buffer[0..made.length]);
    try testing.expect(made.italic);
    made = srt("{\\an8}<b>Oben</b> und <font color=\"#ff0000\">rot</font>", &buffer).?;
    try testing.expectEqualStrings("Oben und rot", buffer[0..made.length]);
    try testing.expect(!made.italic);
    made = srt("a < b > c\n\n", &buffer).?;
    try testing.expectEqualStrings("a < b > c", buffer[0..made.length]);
    try testing.expectEqual(@as(?Cleaned, null), srt("<i></i>\n", &buffer));
}
