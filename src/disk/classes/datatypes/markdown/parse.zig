// SPDX-License-Identifier: MIT
//! Markdown read into text and the runs it is drawn as.
//!
//! What comes out is the document without its marks - no `#`, no `*`,
//! no brackets - and a run for every stretch that is drawn differently:
//! a heading in a larger font, a word in bold or italic, a listing in
//! the fixed font, a link underlined. Nothing here draws or measures
//! anything; that is text.datatype's.
//!
//! **It is read twice.** The first pass counts how much text and how
//! many runs there will be, the second writes them, and both run the
//! same code with the writing switched off. That is how the two blocks
//! are allocated exactly once and exactly large enough.
//!
//! **A link's target is kept past the end of the text.** A run says
//! where in the buffer the name it leads to is, and the names are
//! written after the last character of the document, where nothing
//! draws them: the text is what the reader sees and the targets are not
//! part of it.
//!
//! A paragraph's own line ends are spaces, as the format has them; a
//! blank line is what separates one block from the next.

const datatypes = @import("sdk").datatypes;
const tdc = datatypes.textclass;

/// What is being written, or counted when nothing is being written.
pub const Build = struct {
    /// Where the text goes, and how much of it there is so far.
    text: ?[*]u8 = null,
    text_len: u32 = 0,
    /// Where the runs go, and how many there are so far.
    pieces: ?[*]tdc.Piece = null,
    piece_count: u32 = 0,
    /// Where the link targets go, which is past the end of the text.
    link_base: u32 = 0,
    link_len: u32 = 0,
    /// The run being written, and whether one is open.
    current: tdc.Piece = .{},
    open: bool = false,

    fn put(self: *Build, byte: u8) void {
        if (self.text) |it| it[self.text_len] = byte;
        self.text_len += 1;
    }

    fn putAll(self: *Build, bytes: []const u8) void {
        for (bytes) |byte| self.put(byte);
    }

    /// A run closed off. A run with nothing in it is not one.
    fn close(self: *Build) void {
        if (!self.open) return;
        self.open = false;
        const length = self.text_len - self.current.offset;
        if (length == 0) return;
        if (self.pieces) |it| {
            it[self.piece_count] = self.current;
            it[self.piece_count].length = length;
        }
        self.piece_count += 1;
    }

    /// A new run started, drawn the way `look` says.
    fn wear(self: *Build, look: tdc.Piece) void {
        self.close();
        self.current = look;
        self.current.offset = self.text_len;
        self.current.length = 0;
        self.open = true;
    }

    /// A link's target written past the end of the text. Where it went.
    fn putTarget(self: *Build, bytes: []const u8) struct { offset: u32, length: u32 } {
        const at = self.link_base + self.link_len;
        if (self.text) |it| {
            for (bytes, 0..) |byte, i| it[at + i] = byte;
        }
        self.link_len += @intCast(bytes.len);
        return .{ .offset = at, .length = @intCast(bytes.len) };
    }
};

/// How a block is drawn.
const Look = struct {
    font: u8 = tdc.TDFONT_NORMAL,
    style: u16 = 0,
    pen: u32 = tdc.TDPEN_TEXT,
    indent: u8 = 0,
};

/// graphics.FSF_: the styles a run may be drawn with.
const bold: u16 = 1;
const italic: u16 = 2;
const underlined: u16 = 4;

/// How wide a rule is drawn, in characters.
const rule_width = 48;

/// The whole document read. Called once to count and once to write.
pub fn build(from: []const u8, out: *Build) void {
    var at: usize = 0;
    var last: Kind = .none;
    while (at < from.len) {
        const line = lineAt(from, at);
        at = line.next;
        const text = from[line.start..line.end];
        if (isBlank(text)) continue;
        const kind = kindOf(text);

        // A blank line between blocks, except between one item of a
        // list and the next: a list written with blank lines between
        // its items and one written without are the same list.
        if (last != .none and !(last == kind and (kind == .item or kind == .quote))) {
            out.wear(.{});
            out.put('\n');
        }
        last = kind;

        if (fenceOf(text)) |fence| {
            at = listing(from, at, fence, out);
            continue;
        }
        if (isRule(text)) {
            out.wear(.{ .pen = tdc.TDPEN_SHADOW });
            var n: u32 = 0;
            while (n < rule_width) : (n += 1) out.put('-');
            out.put('\n');
            continue;
        }
        if (headingOf(text)) |heading| {
            out.wear(.{ .font = heading.font, .style = heading.style });
            inlines(from, heading.from + line.start, line.end, out, .{ .font = heading.font, .style = heading.style });
            out.wear(.{ .font = heading.font, .style = heading.style });
            out.put('\n');
            continue;
        }
        if (indentedCode(text)) {
            at = plainBlock(from, line.start, out);
            continue;
        }
        if (bulletOf(text)) |bullet| {
            out.wear(.{ .indent = bullet.indent });
            out.putAll(bullet.mark);
            out.put(' ');
            at = paragraph(from, line.start + bullet.from, line.end, at, out, .{ .indent = bullet.indent });
            continue;
        }
        if (quoteOf(text)) |quote| {
            at = paragraph(from, line.start + quote, line.end, at, out, .{
                .indent = 1,
                .style = italic,
                .pen = tdc.TDPEN_SHADOW,
            });
            continue;
        }
        at = paragraph(from, line.start, line.end, at, out, .{});
    }
    out.close();
}

/// What kind of block a line begins.
const Kind = enum { none, listing, rule, heading, code, item, quote, paragraph };

fn kindOf(text: []const u8) Kind {
    if (fenceOf(text) != null) return .listing;
    if (isRule(text)) return .rule;
    if (headingOf(text) != null) return .heading;
    if (indentedCode(text)) return .code;
    if (bulletOf(text) != null) return .item;
    if (quoteOf(text) != null) return .quote;
    return .paragraph;
}

/// Where a line starts, where it ends and where the next one begins.
const Span = struct { start: usize, end: usize, next: usize };

fn lineAt(from: []const u8, at: usize) Span {
    var end = at;
    while (end < from.len and from[end] != '\n') end += 1;
    return .{ .start = at, .end = end, .next = @min(end + 1, from.len) };
}

fn isBlank(text: []const u8) bool {
    for (text) |byte| {
        if (byte != ' ' and byte != '\t' and byte != '\r') return false;
    }
    return true;
}

/// A line of three or more of the same mark and nothing else.
fn isRule(text: []const u8) bool {
    var seen: usize = 0;
    var mark: u8 = 0;
    for (text) |byte| {
        if (byte == ' ' or byte == '\r') continue;
        if (byte != '-' and byte != '*' and byte != '_') return false;
        if (mark != 0 and byte != mark) return false;
        mark = byte;
        seen += 1;
    }
    return seen >= 3;
}

/// A heading's marks: how far in its text starts and how it is drawn.
const Heading = struct { from: usize, font: u8, style: u16 };

fn headingOf(text: []const u8) ?Heading {
    var level: usize = 0;
    while (level < text.len and text[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    if (level < text.len and text[level] != ' ') return null;
    var from = level;
    while (from < text.len and text[from] == ' ') from += 1;
    // The first two levels get a larger font where the family has one;
    // the rest are the reading font in bold, because a document with
    // six sizes of heading has none.
    return .{
        .from = from,
        .font = switch (level) {
            1 => tdc.TDFONT_LARGER,
            2 => tdc.TDFONT_LARGE,
            else => tdc.TDFONT_NORMAL,
        },
        .style = bold,
    };
}

/// A line of a fenced listing: how many marks the fence is, and which.
const Fence = struct { mark: u8, count: usize };

fn fenceOf(text: []const u8) ?Fence {
    if (text.len < 3) return null;
    const mark = text[0];
    if (mark != '`' and mark != '~') return null;
    var count: usize = 0;
    while (count < text.len and text[count] == mark) count += 1;
    if (count < 3) return null;
    return .{ .mark = mark, .count = count };
}

/// Four spaces or a tab in front of a line, which is a listing too.
fn indentedCode(text: []const u8) bool {
    if (text.len > 0 and text[0] == '\t') return true;
    if (text.len < 4) return false;
    return text[0] == ' ' and text[1] == ' ' and text[2] == ' ' and text[3] == ' ';
}

/// A list item's mark: how far in its text starts, what is drawn in
/// front of it and how far the item is indented.
const Bullet = struct { from: usize, mark: []const u8, indent: u8 };

fn bulletOf(text: []const u8) ?Bullet {
    var at: usize = 0;
    while (at < text.len and text[at] == ' ') at += 1;
    // Two spaces of the writer's indent are one level of this one.
    const level: u8 = @intCast(@min(at / 2, 3) + 1);
    if (at < text.len and (text[at] == '-' or text[at] == '*' or text[at] == '+')) {
        if (at + 1 >= text.len or text[at + 1] != ' ') return null;
        var from = at + 1;
        while (from < text.len and text[from] == ' ') from += 1;
        return .{ .from = from, .mark = "*", .indent = level };
    }
    // A numbered item keeps its number, because the numbers are what it
    // is for.
    var digits = at;
    while (digits < text.len and text[digits] >= '0' and text[digits] <= '9') digits += 1;
    if (digits == at or digits + 1 >= text.len) return null;
    if (text[digits] != '.' and text[digits] != ')') return null;
    if (text[digits + 1] != ' ') return null;
    var from = digits + 1;
    while (from < text.len and text[from] == ' ') from += 1;
    return .{ .from = from, .mark = text[at .. digits + 1], .indent = level };
}

/// A quoted line's mark: how far in its text starts.
fn quoteOf(text: []const u8) ?usize {
    var at: usize = 0;
    while (at < text.len and text[at] == ' ') at += 1;
    if (at >= text.len or text[at] != '>') return null;
    at += 1;
    while (at < text.len and text[at] == ' ') at += 1;
    return at;
}

/// A paragraph: this line and every line after it that is not blank and
/// does not begin a block of its own. Where the next block starts.
fn paragraph(from: []const u8, text_start: usize, text_end: usize, next: usize, out: *Build, look: Look) usize {
    inlines(from, text_start, text_end, out, look);
    var at = next;
    while (at < from.len) {
        const line = lineAt(from, at);
        const text = from[line.start..line.end];
        if (isBlank(text)) break;
        if (headingOf(text) != null or fenceOf(text) != null or isRule(text)) break;
        if (bulletOf(text) != null or quoteOf(text) != null or indentedCode(text)) break;
        // A line end inside a paragraph is a space, as the format has
        // it: the text is wrapped to the window, not to the file.
        out.wear(.{ .font = look.font, .style = look.style, .pen = look.pen, .indent = look.indent });
        out.put(' ');
        inlines(from, line.start, line.end, out, look);
        at = line.next;
    }
    out.wear(.{ .font = look.font, .style = look.style, .pen = look.pen, .indent = look.indent });
    out.put('\n');
    return at;
}

/// A fenced listing: every line up to the closing fence, as it stands.
fn listing(from: []const u8, next: usize, fence: Fence, out: *Build) usize {
    var at = next;
    out.wear(.{ .font = tdc.TDFONT_FIXED, .indent = 1 });
    while (at < from.len) {
        const line = lineAt(from, at);
        const text = from[line.start..line.end];
        if (fenceOf(text)) |closing| {
            if (closing.mark == fence.mark and closing.count >= fence.count) return line.next;
        }
        for (text) |byte| {
            if (byte != '\r') out.put(byte);
        }
        out.put('\n');
        at = line.next;
    }
    return at;
}

/// A block of lines each indented far enough to be a listing.
fn plainBlock(from: []const u8, start: usize, out: *Build) usize {
    var at = start;
    out.wear(.{ .font = tdc.TDFONT_FIXED, .indent = 1 });
    while (at < from.len) {
        const line = lineAt(from, at);
        const text = from[line.start..line.end];
        if (!indentedCode(text) and !isBlank(text)) break;
        if (isBlank(text) and !moreCode(from, line.next)) break;
        const skip: usize = if (text.len > 0 and text[0] == '\t') 1 else @min(text.len, 4);
        for (text[@min(skip, text.len)..]) |byte| {
            if (byte != '\r') out.put(byte);
        }
        out.put('\n');
        at = line.next;
    }
    return at;
}

/// Whether a listing goes on after a blank line in the middle of it.
fn moreCode(from: []const u8, at: usize) bool {
    var walk = at;
    while (walk < from.len) {
        const line = lineAt(from, walk);
        const text = from[line.start..line.end];
        if (isBlank(text)) {
            walk = line.next;
            continue;
        }
        return indentedCode(text);
    }
    return false;
}

// --- what is inside a line --------------------------------------------------

/// The marks inside a stretch of a line read: emphasis, code and links.
fn inlines(from: []const u8, start: usize, end: usize, out: *Build, look: Look) void {
    var style = look.style;
    // Which mark opened the emphasis that is on, so that the same mark
    // closes it: a closing mark has nothing after it to match, which is
    // what tells it from an opening one.
    var italic_mark: u8 = 0;
    var bold_mark: u8 = 0;
    var at = start;
    out.wear(.{ .font = look.font, .style = style, .pen = look.pen, .indent = look.indent });
    while (at < end) {
        const byte = from[at];
        // A mark written as text: the backslash goes, the mark stays.
        if (byte == '\\' and at + 1 < end and isMark(from[at + 1])) {
            out.put(from[at + 1]);
            at += 2;
            continue;
        }
        if (byte == '\r') {
            at += 1;
            continue;
        }
        if (byte == '`') {
            if (codeSpan(from, at, end, out, look)) |after| {
                at = after;
                out.wear(.{ .font = look.font, .style = style, .pen = look.pen, .indent = look.indent });
                continue;
            }
        }
        if (byte == '[' or (byte == '!' and at + 1 < end and from[at + 1] == '[')) {
            if (link(from, at, end, out, look)) |after| {
                at = after;
                out.wear(.{ .font = look.font, .style = style, .pen = look.pen, .indent = look.indent });
                continue;
            }
        }
        if (byte == '*' or byte == '_') {
            const run = markRun(from, at, end, byte);
            const which: u16 = if (run >= 2) bold else italic;
            const opened = if (run >= 2) &bold_mark else &italic_mark;
            if (run > 0 and (opened.* == byte or
                (opened.* == 0 and closesLater(from, at + run, end, byte, run))))
            {
                if (opened.* == byte) {
                    style &= ~which;
                    opened.* = 0;
                } else {
                    style |= which;
                    opened.* = byte;
                }
                at += run;
                out.wear(.{ .font = look.font, .style = style, .pen = look.pen, .indent = look.indent });
                continue;
            }
        }
        out.put(byte);
        at += 1;
    }
}

fn isMark(byte: u8) bool {
    return switch (byte) {
        '\\', '`', '*', '_', '[', ']', '(', ')', '#', '+', '-', '.', '!', '>' => true,
        else => false,
    };
}

/// How many of the same mark stand together, at most two.
fn markRun(from: []const u8, at: usize, end: usize, mark: u8) usize {
    var count: usize = 0;
    while (at + count < end and from[at + count] == mark and count < 2) count += 1;
    return count;
}

/// Whether the same mark comes again later in the line, which is what
/// makes the first one a mark rather than a character.
fn closesLater(from: []const u8, at: usize, end: usize, mark: u8, run: usize) bool {
    var walk = at;
    while (walk < end) : (walk += 1) {
        if (from[walk] != mark) continue;
        if (markRun(from, walk, end, mark) >= run) return true;
    }
    return false;
}

/// `` `code` ``: what is between the marks, in the fixed font. Where it
/// ends, or null when it never closes.
fn codeSpan(from: []const u8, at: usize, end: usize, out: *Build, look: Look) ?usize {
    const marks = markRun(from, at, end, '`');
    var walk = at + marks;
    while (walk < end) : (walk += 1) {
        if (from[walk] != '`') continue;
        if (markRun(from, walk, end, '`') < marks) continue;
        out.wear(.{ .font = tdc.TDFONT_FIXED, .pen = look.pen, .indent = look.indent });
        for (from[at + marks .. walk]) |byte| out.put(byte);
        return walk + marks;
    }
    return null;
}

/// `[text](target)`, and `![text](target)` for a picture. Where it ends,
/// or null when it is not one after all.
fn link(from: []const u8, at: usize, end: usize, out: *Build, look: Look) ?usize {
    const picture = from[at] == '!';
    const open = if (picture) at + 1 else at;
    if (open >= end or from[open] != '[') return null;
    var close = open + 1;
    while (close < end and from[close] != ']') close += 1;
    if (close >= end or close + 1 >= end or from[close + 1] != '(') return null;
    var target = close + 2;
    while (target < end and from[target] != ')') target += 1;
    if (target >= end) return null;

    const name = from[close + 2 .. target];
    const shown = from[open + 1 .. close];
    const where = out.putTarget(name);
    // A picture is not drawn; what it says it is stands in its place.
    out.wear(.{
        .font = look.font,
        .style = look.style | if (picture) italic else underlined,
        .pen = if (picture) tdc.TDPEN_SHADOW else tdc.TDPEN_FILL,
        .indent = look.indent,
        .link_offset = where.offset,
        .link_length = if (picture) 0 else where.length,
    });
    for (shown) |byte| out.put(byte);
    return target + 1;
}

const std = @import("std");
const testing = std.testing;

/// The document built twice, as the class does it, and what came out.
fn readTwice(from: []const u8, text: []u8, pieces: []tdc.Piece) struct { text: []u8, pieces: []tdc.Piece } {
    var counting = Build{};
    build(from, &counting);
    var writing = Build{
        .text = text.ptr,
        .pieces = pieces.ptr,
        .link_base = counting.text_len,
    };
    build(from, &writing);
    return .{ .text = text[0..writing.text_len], .pieces = pieces[0..writing.piece_count] };
}

test "both passes agree on how much there is" {
    const source = "# Title\n\nSome *words* and `code`.\n\n- one\n- two\n";
    var counting = Build{};
    build(source, &counting);
    var text: [256]u8 = undefined;
    var pieces: [64]tdc.Piece = undefined;
    const got = readTwice(source, &text, &pieces);
    try testing.expectEqual(counting.text_len, @as(u32, @intCast(got.text.len)));
    try testing.expectEqual(counting.piece_count, @as(u32, @intCast(got.pieces.len)));
}

test "the marks are gone and the runs say what they meant" {
    const source = "# Title\n\nSome *words* here.\n";
    var text: [256]u8 = undefined;
    var pieces: [64]tdc.Piece = undefined;
    const got = readTwice(source, &text, &pieces);
    try testing.expectEqualStrings("Title\n\nSome words here.\n", got.text);
    // The heading, then the paragraph in three runs: before, the
    // emphasis, and after.
    try testing.expectEqual(tdc.TDFONT_LARGER, got.pieces[0].font);
    try testing.expectEqual(@as(u16, bold), got.pieces[0].style);
    var emphasised: u32 = 0;
    for (got.pieces) |piece| {
        if (piece.style & italic != 0) emphasised += piece.length;
    }
    try testing.expectEqual(@as(u32, 5), emphasised); // "words"
}

test "a paragraph's own line ends are spaces" {
    const source = "one\ntwo\n\nthree\n";
    var text: [64]u8 = undefined;
    var pieces: [16]tdc.Piece = undefined;
    const got = readTwice(source, &text, &pieces);
    try testing.expectEqualStrings("one two\n\nthree\n", got.text);
}

test "a listing is kept as it stands" {
    const source = "```\n  a  b\n*not* emphasis\n```\n";
    var text: [64]u8 = undefined;
    var pieces: [16]tdc.Piece = undefined;
    const got = readTwice(source, &text, &pieces);
    try testing.expectEqualStrings("  a  b\n*not* emphasis\n", got.text);
    try testing.expectEqual(tdc.TDFONT_FIXED, got.pieces[0].font);
}

test "a link shows its name and remembers where it leads" {
    const source = "See [the guide](docs/guide.md) for more.\n";
    var text: [128]u8 = undefined;
    var pieces: [16]tdc.Piece = undefined;
    const got = readTwice(source, &text, &pieces);
    try testing.expectEqualStrings("See the guide for more.\n", got.text);
    var found = false;
    for (got.pieces) |piece| {
        if (piece.link_length == 0) continue;
        found = true;
        // The target is past the end of the text, where nothing draws it.
        try testing.expect(piece.link_offset >= got.text.len);
        try testing.expectEqualStrings("docs/guide.md", text[piece.link_offset..][0..piece.link_length]);
    }
    try testing.expect(found);
}

test "a list keeps its marks and its indent" {
    const source = "- one\n- two\n  - deeper\n1. first\n";
    var text: [128]u8 = undefined;
    var pieces: [32]tdc.Piece = undefined;
    const got = readTwice(source, &text, &pieces);
    try testing.expectEqualStrings("* one\n* two\n* deeper\n1. first\n", got.text);
    var deepest: u8 = 0;
    for (got.pieces) |piece| deepest = @max(deepest, piece.indent);
    try testing.expectEqual(@as(u8, 2), deepest);
}
