// SPDX-License-Identifier: MIT
//! Markdown read into text, the runs it is drawn as and the blocks they
//! are in - GitHub's Markdown, as far as a page of text can show it.
//!
//! What comes out is the document without its marks - no `#`, no `*`,
//! no brackets, no pipes - a run for every stretch that is drawn
//! differently, and a block for every paragraph, heading, listing, rule
//! and cell of a table, with the lists and quotes it is inside. How far
//! apart the blocks stand and what is drawn round them is
//! text.datatype's; nothing here draws or measures anything.
//!
//! **Blocks are read as CommonMark reads them**: a line at a time, the
//! quotes and items it goes on with first, then the ones it starts, then
//! what it is - a line of a paragraph, a heading, a fence, a rule, a row
//! of a table. An item's lines go on as long as they are indented as far
//! as its text, a quote's as long as they start with `>`, and a
//! paragraph's lazily, where neither does. A list whose items stand
//! apart - a blank line between two of them, or between two blocks of
//! one - is loose, and its items stand as far apart as paragraphs.
//!
//! **A paragraph is read whole**: its lines are put together first, so
//! that emphasis, code and links may run from one line into the next.
//! Its own line ends are spaces; two spaces or a backslash at the end of
//! a line break it there.
//!
//! **Text is Latin-1**, which is what graphics draws: UTF-8 is read into
//! it, a character it has not written as the nearest it has - quotes and
//! dashes as their plain forms, an arrow as `->` - and pictures of
//! faces and things left out. HTML's entities are read too, and of its
//! tags the ones that say how text looks; the rest are left out.
//!
//! **A picture is not fetched.** What its text says it is stands in its
//! place, set back in italic.
//!
//! **It is read twice.** The first pass counts how much text, how many
//! runs and how many blocks there will be, the second writes them, and
//! both run the same code with the writing switched off. That is how the
//! three blocks are allocated exactly once and exactly large enough.
//!
//! **A link's target is kept past the end of the text.** A run says
//! where in the buffer the name it leads to is, and the names are
//! written after the last character of the document, where nothing
//! draws them.

const datatypes = @import("sdk").datatypes;
const tdc = datatypes.textclass;

/// graphics.FSF_: the styles a run may be drawn with.
const bold: u16 = 1;
const italic: u16 = 2;
const underlined: u16 = 4;

/// What is being written, or counted when nothing is being written.
pub const Build = struct {
    /// Room the size of the document, for a paragraph's lines put
    /// together; the class gives it, and the counting pass needs it too.
    scratch: []u8 = &.{},
    /// Where the text goes, and how much of it there is so far.
    text: ?[*]u8 = null,
    text_len: u32 = 0,
    /// Where the runs go, and how many there are so far.
    pieces: ?[*]tdc.Piece = null,
    piece_count: u32 = 0,
    /// Where the blocks go, and how many there are so far.
    blocks: ?[*]tdc.Block = null,
    block_count: u32 = 0,
    /// Where the link targets go, which is past the end of the text.
    link_base: u32 = 0,
    link_len: u32 = 0,
    /// The run being written, and whether one is open.
    current: tdc.Piece = .{},
    open: bool = false,
    /// The block being written, and whether anything but spaces is in
    /// it yet.
    block: tdc.Block = .{},
    inked: bool = false,

    fn put(self: *Build, byte: u8) void {
        if (self.text) |it| it[self.text_len] = byte;
        self.text_len += 1;
    }

    /// One character, as Latin-1 has it or its nearest.
    fn putCode(self: *Build, code: u32) void {
        if (code == '\n') return self.put('\n');
        if (code < 0x20 or (code >= 0x7F and code < 0xA0)) return;
        if (code < 0x100) {
            if (code != ' ') self.inked = true;
            return self.put(@intCast(code));
        }
        const near: []const u8 = switch (code) {
            0x2010...0x2015, 0x2212 => "-",
            0x2018, 0x2019, 0x201A, 0x2032 => "'",
            0x201C, 0x201D, 0x201E, 0x2033 => "\"",
            0x2026 => "...",
            0x2022, 0x2023, 0x2043, 0x25CF, 0x25E6, 0x2219 => "\xB7",
            0x2190 => "<-",
            0x2192 => "->",
            0x2194 => "<->",
            0x21D2 => "=>",
            0x2191 => "^",
            0x2193 => "v",
            0x2264 => "<=",
            0x2265 => ">=",
            0x2260 => "!=",
            0x2248 => "~",
            0x20AC => "EUR",
            0x2122 => "TM",
            0x2713, 0x2714, 0x2705, 0x2611 => "v",
            0x2717, 0x2718, 0x274C, 0x2612 => "x",
            // Joiners, selectors and the byte-order mark: nothing.
            0x200B...0x200F, 0x2060, 0xFE00...0xFE0F, 0xFEFF => "",
            // Pictures of faces and things.
            0x2600...0x2610, 0x2613...0x2704, 0x2706...0x2712, 0x2715...0x2716, 0x2719...0x274B, 0x274D...0x27BF, 0x1F000...0x1FAFF => "",
            else => "?",
        };
        for (near) |byte| {
            if (byte != ' ') self.inked = true;
            self.put(byte);
        }
    }

    /// UTF-8 put as Latin-1.
    fn putText(self: *Build, bytes: []const u8) void {
        var at: usize = 0;
        while (at < bytes.len) {
            const decoded = decode(bytes, at);
            self.putCode(decoded.code);
            at += decoded.length;
        }
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

    /// A block started.
    fn begin(self: *Build, block: tdc.Block) void {
        self.close();
        self.block = block;
        self.block.first = self.piece_count;
        self.inked = false;
    }

    /// The block ended by `terminator` - a newline, or a tab after a
    /// cell that is not the last of its row - in a run of its own.
    fn end(self: *Build, terminator: u8) void {
        self.wear(.{});
        self.put(terminator);
        self.close();
        self.block.count = self.piece_count - self.block.first;
        if (self.blocks) |it| it[self.block_count] = self.block;
        self.block_count += 1;
    }

    /// Where everything stands, to go back to when a block came to
    /// nothing.
    const Saved = struct { text_len: u32, piece_count: u32, block_count: u32, link_len: u32 };

    fn save(self: *const Build) Saved {
        return .{ .text_len = self.text_len, .piece_count = self.piece_count, .block_count = self.block_count, .link_len = self.link_len };
    }

    fn restore(self: *Build, saved: Saved) void {
        self.open = false;
        self.text_len = saved.text_len;
        self.piece_count = saved.piece_count;
        self.block_count = saved.block_count;
        self.link_len = saved.link_len;
    }

    /// The blocks of a list's items from `from` on, at `depth`, made
    /// loose.
    fn loosen(self: *Build, from: u32, depth: u8) void {
        const blocks = self.blocks orelse return;
        var b = from;
        while (b < self.block_count) : (b += 1) {
            if (blocks[b].depth == depth) blocks[b].flags |= tdc.TDBF_LOOSE;
        }
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

/// One character of UTF-8, and how many bytes it took; a byte that is
/// not UTF-8 is taken for Latin-1.
fn decode(bytes: []const u8, at: usize) struct { code: u32, length: usize } {
    const first = bytes[at];
    if (first < 0x80) return .{ .code = first, .length = 1 };
    const length: usize = if (first >= 0xF0 and first < 0xF8) 4 else if (first >= 0xE0) 3 else if (first >= 0xC0) 2 else 0;
    if (length == 0 or at + length > bytes.len) return .{ .code = first, .length = 1 };
    var code: u32 = first & (@as(u32, 0x7F) >> @intCast(length));
    for (bytes[at + 1 .. at + length]) |byte| {
        if (byte & 0xC0 != 0x80) return .{ .code = first, .length = 1 };
        code = code << 6 | (byte & 0x3F);
    }
    return .{ .code = code, .length = length };
}

/// The whole document read. Called once to count and once to write,
/// with `out.scratch` at least as long as `from`.
pub fn build(from: []const u8, out: *Build) void {
    var p = Parser{ .out = out, .source = from };
    var at: usize = 0;
    while (at < from.len) {
        const line = lineAt(from, at);
        at = line.next;
        if (p.skip_next) {
            p.skip_next = false;
            continue;
        }
        p.line(from[line.start..line.end], at);
    }
    p.finish();
    out.close();
}

/// Where a line starts, where it ends - a carriage return before its
/// newline left off - and where the next one begins.
const Span = struct { start: usize, end: usize, next: usize };

fn lineAt(from: []const u8, at: usize) Span {
    var end = at;
    while (end < from.len and from[end] != '\n') end += 1;
    const next = @min(end + 1, from.len);
    if (end > at and from[end - 1] == '\r') end -= 1;
    return .{ .start = at, .end = end, .next = next };
}

// --- reading a line ----------------------------------------------------------

/// A line being read from the left: where, and in which column, a tab
/// counting to the next multiple of four.
const Scan = struct {
    text: []const u8,
    at: usize = 0,
    col: usize = 0,

    /// How many columns of spaces stand from here.
    fn indent(s: Scan) usize {
        var col = s.col;
        var i = s.at;
        while (i < s.text.len) : (i += 1) {
            if (s.text[i] == ' ') col += 1 else if (s.text[i] == '\t') col = (col / 4 + 1) * 4 else break;
        }
        return col - s.col;
    }

    /// Up to `most` columns of spaces passed over; a tab that reaches
    /// past them is passed over whole.
    fn skipIndent(s: *Scan, most: usize) void {
        const from = s.col;
        while (s.at < s.text.len and s.col - from < most) : (s.at += 1) {
            if (s.text[s.at] == ' ') s.col += 1 else if (s.text[s.at] == '\t') s.col = (s.col / 4 + 1) * 4 else break;
        }
    }

    fn peek(s: Scan) u8 {
        return if (s.at < s.text.len) s.text[s.at] else 0;
    }

    fn advance(s: *Scan, n: usize) void {
        s.at += n;
        s.col += n;
    }

    fn rest(s: Scan) []const u8 {
        return s.text[s.at..];
    }

    fn blank(s: Scan) bool {
        return isBlank(s.rest());
    }
};

fn isBlank(text: []const u8) bool {
    for (text) |byte| {
        if (byte != ' ' and byte != '\t') return false;
    }
    return true;
}

/// How many lists and quotes a document may be inside, at most.
const most_depth = 8;

/// A quote or an item that a line may go on with.
const Container = struct {
    quote: bool,
    /// An item's: how far in from where it began its text is.
    indent: usize = 0,
    /// Its mark, waiting for its first block, and its number.
    mark: u8 = tdc.TDMARK_NONE,
    number: u32 = 0,
    /// The first item of its list.
    start: bool = false,
};

/// The list the items at a depth are in.
const List = struct {
    active: bool = false,
    ordered: bool = false,
    /// `-`, `*` or `+`; `.` or `)` after a number.
    delimiter: u8 = 0,
    next: u32 = 1,
    /// Its first block, from which it is made loose.
    first_block: u32 = 0,
    loose: bool = false,
};

/// What the lines are being read into.
const Leaf = enum { none, paragraph, fenced, indented, table, comment };

const most_columns = 32;

const Parser = struct {
    out: *Build,
    source: []const u8,
    stack: [most_depth]Container = undefined,
    depth: usize = 0,
    lists: [most_depth]List = @splat(.{}),
    leaf: Leaf = .none,
    /// The paragraph's lines put together so far, in `out.scratch`.
    para_len: usize = 0,
    /// A fenced listing's fence and how far in it stood; how many lines
    /// a listing has, and the blank ones held back inside an indented
    /// one.
    fence: Fence = .{ .mark = 0, .count = 0 },
    fence_indent: usize = 0,
    listing_lines: u32 = 0,
    held_blanks: u32 = 0,
    /// A table's columns and how each stands.
    columns: usize = 0,
    aligns: [most_columns]u8 = @splat(tdc.TDALIGN_LEFT),
    /// The line before was blank.
    blank: bool = false,
    /// The next line was read already: a table's delimiter row.
    skip_next: bool = false,

    fn line(p: *Parser, text: []const u8, next_at: usize) void {
        var scan = Scan{ .text = text };
        const matched = matchContainers(p.stack[0..p.depth], &scan);

        if (p.leaf == .fenced) {
            if (matched == p.depth) {
                var probe = scan;
                const ind = probe.indent();
                probe.skipIndent(ind);
                if (ind < 4 and closesFence(probe.rest(), p.fence)) {
                    p.closeLeaf();
                    return;
                }
                p.listingLine(scan, p.fence_indent);
                return;
            }
            p.closeLeaf();
        }
        if (p.leaf == .comment) {
            if (contains(text, "-->")) p.leaf = .none;
            return;
        }

        if (scan.blank()) {
            if (p.leaf == .indented and matched == p.depth) {
                p.held_blanks += 1;
                return;
            }
            p.closeLeaf();
            if (matched < p.depth) p.closeContainers(matched);
            p.blank = true;
            return;
        }

        if (matched < p.depth) {
            // A paragraph goes on where its containers do not, if the
            // line starts nothing of its own.
            if (p.leaf == .paragraph and !startsBlock(scan)) {
                p.paragraphLine(scan);
                return;
            }
            p.closeLeaf();
            p.closeContainers(matched);
        }

        // The line under a paragraph that makes it a heading.
        if (p.leaf == .paragraph) {
            var probe = scan;
            const ind = probe.indent();
            probe.skipIndent(ind);
            if (ind < 4) {
                if (setextOf(probe.rest())) |level| {
                    p.closeParagraph(level);
                    p.blank = false;
                    return;
                }
            }
        }
        if (p.leaf == .indented) {
            if (scan.indent() >= 4) {
                p.blank = false;
                p.listingLine(scan, 4);
                return;
            }
            p.closeLeaf();
        }
        if (p.leaf == .table and !startsBlock(scan)) {
            p.row(scan.rest(), false);
            return;
        }

        // A blank line before something new inside an item that was
        // already there: its list is loose.
        if (p.blank) {
            var d = matched;
            while (d > 0) {
                d -= 1;
                if (!p.stack[d].quote) {
                    p.loosen(d);
                    break;
                }
            }
        }

        // The quotes and items the line starts.
        while (p.depth < most_depth) {
            const ind = scan.indent();
            if (ind >= 4) break;
            var probe = scan;
            probe.skipIndent(ind);
            if (probe.peek() == '>') {
                p.closeLeaf();
                probe.advance(1);
                if (probe.peek() == ' ') probe.advance(1) else if (probe.peek() == '\t') probe.skipIndent(1);
                scan = probe;
                p.stack[p.depth] = .{ .quote = true };
                p.depth += 1;
                continue;
            }
            const item = itemOf(probe) orelse break;
            if (isRule(probe.rest())) break;
            // An item that is empty, or numbered from other than one,
            // does not break into a paragraph.
            if (p.leaf == .paragraph and (item.empty or (item.ordered and item.number != 1))) break;
            p.closeLeaf();
            p.openItem(item, scan.col);
            scan = item.after;
            continue;
        }
        p.blank = false;
        // A list that no item of goes on with any more has ended.
        for (p.lists[p.depth..]) |*list| list.active = false;

        if (scan.blank()) {
            // An item or a quote with nothing after its mark yet.
            p.closeLeaf();
            return;
        }
        const ind = scan.indent();
        if (ind >= 4) {
            if (p.leaf == .paragraph) {
                p.paragraphLine(scan);
                return;
            }
            p.closeLeaf();
            p.openListing(.indented);
            p.listingLine(scan, 4);
            return;
        }
        scan.skipIndent(ind);
        const rest = scan.rest();
        if (fenceOf(rest)) |fence| {
            p.closeLeaf();
            p.openListing(.fenced);
            p.fence = fence;
            p.fence_indent = ind;
            return;
        }
        if (headingOf(rest)) |found| {
            p.closeLeaf();
            p.heading(found.level, found.text);
            return;
        }
        if (isRule(rest)) {
            p.closeLeaf();
            p.out.begin(p.blockOf(tdc.TDBLOCK_RULE));
            p.out.end('\n');
            return;
        }
        if (startsWith(rest, "<!--")) {
            p.closeLeaf();
            if (!contains(rest, "-->")) p.leaf = .comment;
            return;
        }
        if (p.leaf == .paragraph) {
            p.paragraphLine(scan);
            return;
        }
        p.closeLeaf();
        // A link's definition says where a name leads, and is not shown.
        if (definitionOf(rest) != null) return;
        if (p.tableAhead(rest, next_at)) return;
        p.leaf = .paragraph;
        p.para_len = 0;
        p.paragraphLine(scan);
    }

    fn finish(p: *Parser) void {
        p.closeLeaf();
        p.closeContainers(0);
    }

    /// The block a block of this kind is, where the containers are now:
    /// the mark of the item it is the first block of, if it is.
    fn blockOf(p: *Parser, kind: u8) tdc.Block {
        var block = tdc.Block{ .kind = kind, .depth = @intCast(p.depth) };
        for (p.stack[0..p.depth], 0..) |c, i| {
            if (c.quote) block.quotes |= @as(u8, 1) << @intCast(i);
        }
        if (p.depth > 0 and !p.stack[p.depth - 1].quote) {
            const item = &p.stack[p.depth - 1];
            block.mark = item.mark;
            block.number = item.number;
            if (item.start and item.mark != tdc.TDMARK_NONE) block.flags |= tdc.TDBF_START;
            if (p.lists[p.depth - 1].loose) block.flags |= tdc.TDBF_LOOSE;
        }
        // An item that began with a quote or a list of its own has its
        // mark there, and nowhere.
        for (p.stack[0..p.depth]) |*c| {
            c.mark = tdc.TDMARK_NONE;
            c.start = false;
        }
        return block;
    }

    /// The containers from `to` in closed: an item that had nothing in
    /// it still shows its mark.
    fn closeContainers(p: *Parser, to: usize) void {
        while (p.depth > to) {
            p.closeLeaf();
            const c = p.stack[p.depth - 1];
            if (!c.quote and c.mark != tdc.TDMARK_NONE) {
                p.out.begin(p.blockOf(tdc.TDBLOCK_PARAGRAPH));
                p.out.end('\n');
            }
            p.depth -= 1;
        }
    }

    fn closeLeaf(p: *Parser) void {
        switch (p.leaf) {
            .paragraph => p.closeParagraph(0),
            .fenced, .indented => p.out.end('\n'),
            else => {},
        }
        p.leaf = .none;
    }

    /// The list at `level` made loose, and every block of its items so
    /// far.
    fn loosen(p: *Parser, level: usize) void {
        const list = &p.lists[level];
        if (list.loose) return;
        list.loose = true;
        p.out.loosen(list.first_block, @intCast(level + 1));
    }

    fn openItem(p: *Parser, item: Item, start_col: usize) void {
        const level = p.depth;
        const list = &p.lists[level];
        const same = list.active and list.ordered == item.ordered and list.delimiter == item.delimiter;
        if (!same) {
            list.* = .{ .active = true, .ordered = item.ordered, .delimiter = item.delimiter, .next = item.number, .first_block = p.out.block_count };
        } else if (p.blank) {
            p.loosen(level);
        }
        // How deep in lists it is says how it is marked, as GitHub does.
        var lists_out: usize = 0;
        for (p.stack[0..level]) |c| {
            if (!c.quote) lists_out += 1;
        }
        const mark: u8 = if (item.ordered)
            (if (lists_out == 0) tdc.TDMARK_NUMBER else if (lists_out == 1) tdc.TDMARK_ROMAN else tdc.TDMARK_LETTER)
        else
            (if (lists_out == 0) tdc.TDMARK_DISC else if (lists_out == 1) tdc.TDMARK_CIRCLE else tdc.TDMARK_SQUARE);
        p.stack[level] = .{ .quote = false, .indent = item.after.col - start_col, .mark = mark, .number = list.next, .start = !same };
        list.next += 1;
        p.depth += 1;
    }

    // --- paragraphs ----------------------------------------------------------

    /// A line of the paragraph added: its indent left off, joined to the
    /// line before by its line end.
    fn paragraphLine(p: *Parser, scan: Scan) void {
        var s = scan;
        s.skipIndent(s.indent());
        const text = s.rest();
        const room = p.out.scratch;
        if (p.para_len > 0 and p.para_len < room.len) {
            room[p.para_len] = '\n';
            p.para_len += 1;
        }
        const n = @min(text.len, room.len - p.para_len);
        @memcpy(room[p.para_len..][0..n], text[0..n]);
        p.para_len += n;
    }

    /// The paragraph written: as a heading of `level` when the line
    /// under it made it one, else as a paragraph - or as nothing, when
    /// nothing of it is left to show.
    fn closeParagraph(p: *Parser, level: u8) void {
        p.leaf = .none;
        var text = p.out.scratch[0..p.para_len];
        while (text.len > 0 and (text[text.len - 1] == ' ' or text[text.len - 1] == '\t')) text.len -= 1;
        if (level != 0) return p.heading(level, text);
        const saved = p.out.save();
        var block = p.blockOf(tdc.TDBLOCK_PARAGRAPH);
        // An item of a list of tasks: its box in place of its mark.
        if (block.mark != tdc.TDMARK_NONE and text.len >= 3 and text[0] == '[' and text[2] == ']' and
            (text.len == 3 or text[3] == ' '))
        {
            if (text[1] == ' ' or text[1] == 'x' or text[1] == 'X') {
                block.mark = if (text[1] == ' ') tdc.TDMARK_TASK else tdc.TDMARK_DONE;
                text = text[@min(4, text.len)..];
            }
        }
        p.out.begin(block);
        p.inlines(text, .{});
        if (!p.out.inked and block.mark == tdc.TDMARK_NONE) {
            p.out.restore(saved);
            return;
        }
        p.out.end('\n');
    }

    fn heading(p: *Parser, level: u8, text: []const u8) void {
        var block = p.blockOf(tdc.TDBLOCK_HEADING);
        block.level = level;
        p.out.begin(block);
        p.inlines(text, .{
            .font = switch (level) {
                1 => tdc.TDFONT_LARGER,
                2 => tdc.TDFONT_LARGE,
                3 => tdc.TDFONT_BIG,
                4 => tdc.TDFONT_NORMAL,
                else => tdc.TDFONT_SMALL,
            },
            .style = bold,
            .pen = if (level == 6) tdc.TDPEN_MUTED else tdc.TDPEN_TEXT,
        });
        p.out.end('\n');
    }

    // --- listings ------------------------------------------------------------

    fn openListing(p: *Parser, leaf: Leaf) void {
        p.leaf = leaf;
        p.listing_lines = 0;
        p.held_blanks = 0;
        p.out.begin(p.blockOf(tdc.TDBLOCK_LISTING));
        p.out.wear(.{ .font = tdc.TDFONT_FIXED });
    }

    /// A line of a listing as it stands, `strip` columns of its indent
    /// left off, its tabs spread to the next multiple of four.
    fn listingLine(p: *Parser, scan: Scan, strip: usize) void {
        var s = scan;
        s.skipIndent(strip);
        const out = p.out;
        if (p.listing_lines > 0) out.put('\n');
        while (p.held_blanks > 0) : (p.held_blanks -= 1) out.put('\n');
        p.listing_lines += 1;
        var col: usize = 0;
        var at = s.at;
        // Indent the strip did not take is the listing's own.
        col = s.col - scan.col - @min(strip, s.col - scan.col);
        for (0..col) |_| out.put(' ');
        col = 0;
        while (at < s.text.len) {
            if (s.text[at] == '\t') {
                const to = (col / 4 + 1) * 4;
                while (col < to) : (col += 1) out.put(' ');
                at += 1;
                continue;
            }
            const decoded = decode(s.text, at);
            out.putCode(decoded.code);
            at += decoded.length;
            col += 1;
        }
    }

    // --- tables --------------------------------------------------------------

    /// Whether the line is a table's head - the next line its delimiter
    /// row, as many cells long - and if it is, the head written.
    fn tableAhead(p: *Parser, head: []const u8, next_at: usize) bool {
        if (next_at >= p.source.len) return false;
        if (indexOf(head, '|') == null) return false;
        const next = lineAt(p.source, next_at);
        var scan = Scan{ .text = p.source[next.start..next.end] };
        if (matchContainers(p.stack[0..p.depth], &scan) != p.depth) return false;
        var cells: [most_columns][]const u8 = undefined;
        const count = splitCells(scan.rest(), &cells);
        var head_cells: [most_columns][]const u8 = undefined;
        if (splitCells(head, &head_cells) != count or count == 0) return false;
        var aligns: [most_columns]u8 = undefined;
        for (cells[0..count], 0..) |cell, c| aligns[c] = delimiterOf(cell) orelse return false;
        p.columns = count;
        p.aligns = aligns;
        p.leaf = .table;
        p.skip_next = true;
        p.row(head, true);
        return true;
    }

    /// A row of the table, a block a cell: as many cells as the head
    /// had, empty ones where the row has fewer.
    fn row(p: *Parser, text: []const u8, head: bool) void {
        var cells: [most_columns][]const u8 = undefined;
        const count = splitCells(text, &cells);
        for (0..p.columns) |c| {
            var block = p.blockOf(tdc.TDBLOCK_CELL);
            block.number = @intCast(c);
            block.alignment = p.aligns[c];
            if (c == 0) block.flags |= tdc.TDBF_ROW;
            if (c == 0 and head) block.flags |= tdc.TDBF_TABLE;
            if (head) block.flags |= tdc.TDBF_HEAD;
            p.out.begin(block);
            if (c < count) p.inlines(cells[c], .{ .style = if (head) bold else 0 });
            p.out.end(if (c + 1 < p.columns) '\t' else '\n');
        }
    }

    // --- what is inside a block ----------------------------------------------

    /// A stretch of a block read; inside a quote, set back in the paler
    /// ink, as GitHub sets a quote.
    fn inlines(p: *Parser, text: []const u8, look: Look) void {
        var it = Inline{ .out = p.out, .source = p.source, .look = look };
        for (p.stack[0..p.depth]) |c| {
            if (c.quote and it.look.pen == tdc.TDPEN_TEXT) it.look.pen = tdc.TDPEN_MUTED;
        }
        it.run(text);
    }
};

/// How many of `stack` a line goes on with; the scan is left after
/// their marks and indents.
fn matchContainers(stack: []const Container, scan: *Scan) usize {
    var matched: usize = 0;
    for (stack) |c| {
        if (c.quote) {
            var probe = scan.*;
            const ind = probe.indent();
            if (ind > 3) break;
            probe.skipIndent(ind);
            if (probe.peek() != '>') break;
            probe.advance(1);
            if (probe.peek() == ' ') probe.advance(1) else if (probe.peek() == '\t') probe.skipIndent(1);
            scan.* = probe;
        } else {
            if (!scan.blank()) {
                if (scan.indent() < c.indent) break;
                scan.skipIndent(c.indent);
            }
        }
        matched += 1;
    }
    return matched;
}

/// Whether what is left of a line starts a block of its own, and so
/// does not go on with a paragraph or a table.
fn startsBlock(scan: Scan) bool {
    var probe = scan;
    const ind = probe.indent();
    if (ind >= 4) return false;
    probe.skipIndent(ind);
    const rest = probe.rest();
    if (probe.peek() == '>') return true;
    if (fenceOf(rest) != null or headingOf(rest) != null or isRule(rest)) return true;
    if (itemOf(probe)) |item| return !item.empty;
    return false;
}

/// An item's mark at the start of what is left of a line.
const Item = struct {
    ordered: bool,
    delimiter: u8,
    number: u32,
    /// Nothing after the mark.
    empty: bool,
    /// The line from where the item's text starts.
    after: Scan,
};

fn itemOf(scan: Scan) ?Item {
    var s = scan;
    const c = s.peek();
    var item = Item{ .ordered = false, .delimiter = c, .number = 1, .empty = false, .after = s };
    if (c == '-' or c == '*' or c == '+') {
        s.advance(1);
    } else if (c >= '0' and c <= '9') {
        var number: u32 = 0;
        var digits: usize = 0;
        while (s.peek() >= '0' and s.peek() <= '9' and digits < 9) : (digits += 1) {
            number = number * 10 + (s.peek() - '0');
            s.advance(1);
        }
        if (s.peek() != '.' and s.peek() != ')') return null;
        item.ordered = true;
        item.delimiter = s.peek();
        item.number = number;
        s.advance(1);
    } else return null;
    if (s.blank()) {
        item.empty = true;
        s.skipIndent(s.indent());
        item.after = s;
        item.after.col = s.col;
        // Its text, when it comes, one column after the mark.
        item.after = s;
        item.after.col = scan.col + (s.at - scan.at) - (s.at - scan.at) + markWidth(scan, s) + 1;
        return item;
    }
    const spaces = s.indent();
    if (spaces == 0) return null;
    // Five or more spaces after the mark: the text starts one after it,
    // and the rest is a listing inside the item.
    if (spaces >= 5) s.skipIndent(1) else s.skipIndent(spaces);
    item.after = s;
    return item;
}

/// How many columns a mark took.
fn markWidth(from: Scan, to: Scan) usize {
    _ = to.col;
    var width: usize = 0;
    var i = from.at;
    while (i < from.text.len and from.text[i] != ' ' and from.text[i] != '\t') : (i += 1) width += 1;
    return width;
}

/// A line of three or more of the same mark and spaces, and nothing
/// else.
fn isRule(text: []const u8) bool {
    var seen: usize = 0;
    var mark: u8 = 0;
    for (text) |byte| {
        if (byte == ' ' or byte == '\t') continue;
        if (byte != '-' and byte != '*' and byte != '_') return false;
        if (mark != 0 and byte != mark) return false;
        mark = byte;
        seen += 1;
    }
    return seen >= 3;
}

/// The line under a paragraph that makes it a heading: `=` for the
/// first level, `-` for the second.
fn setextOf(text: []const u8) ?u8 {
    if (text.len == 0 or (text[0] != '=' and text[0] != '-')) return null;
    var at: usize = 0;
    while (at < text.len and text[at] == text[0]) at += 1;
    if (!isBlank(text[at..])) return null;
    return if (text[0] == '=') 1 else 2;
}

/// A heading's level and its text, without its marks.
const Heading = struct { level: u8, text: []const u8 };

fn headingOf(text: []const u8) ?Heading {
    var level: usize = 0;
    while (level < text.len and text[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    if (level < text.len and text[level] != ' ' and text[level] != '\t') return null;
    var from = level;
    while (from < text.len and (text[from] == ' ' or text[from] == '\t')) from += 1;
    var to = text.len;
    while (to > from and (text[to - 1] == ' ' or text[to - 1] == '\t')) to -= 1;
    // A closing run of marks goes, where a space stands before it.
    var marks = to;
    while (marks > from and text[marks - 1] == '#') marks -= 1;
    if (marks == from or text[marks - 1] == ' ' or text[marks - 1] == '\t') {
        to = marks;
        while (to > from and (text[to - 1] == ' ' or text[to - 1] == '\t')) to -= 1;
    }
    return .{ .level = @intCast(level), .text = text[from..to] };
}

/// A fence: how many marks, and which.
const Fence = struct { mark: u8, count: usize };

fn fenceOf(text: []const u8) ?Fence {
    if (text.len < 3) return null;
    const mark = text[0];
    if (mark != '`' and mark != '~') return null;
    var count: usize = 0;
    while (count < text.len and text[count] == mark) count += 1;
    if (count < 3) return null;
    // A backtick fence's words may hold no backtick.
    if (mark == '`' and indexOf(text[count..], '`') != null) return null;
    return .{ .mark = mark, .count = count };
}

fn closesFence(text: []const u8, fence: Fence) bool {
    var count: usize = 0;
    while (count < text.len and text[count] == fence.mark) count += 1;
    return count >= fence.count and isBlank(text[count..]);
}

/// `[name]: target` - a link's definition: its target.
fn definitionOf(text: []const u8) ?[]const u8 {
    if (text.len < 4 or text[0] != '[') return null;
    const close = indexOf(text, ']') orelse return null;
    if (close < 2 or close + 1 >= text.len or text[close + 1] != ':') return null;
    var at = close + 2;
    while (at < text.len and (text[at] == ' ' or text[at] == '\t')) at += 1;
    var end = at;
    while (end < text.len and text[end] != ' ' and text[end] != '\t') end += 1;
    if (end == at) return null;
    var target = text[at..end];
    if (target.len >= 2 and target[0] == '<' and target[target.len - 1] == '>') target = target[1 .. target.len - 1];
    return target;
}

/// Where a name the document defines leads.
fn findDefinition(source: []const u8, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    var at: usize = 0;
    while (at < source.len) {
        const line = lineAt(source, at);
        at = line.next;
        var text = source[line.start..line.end];
        var skip: usize = 0;
        while (skip < 3 and skip < text.len and text[skip] == ' ') skip += 1;
        text = text[skip..];
        if (text.len < name.len + 3 or text[0] != '[') continue;
        if (!sameLabel(text[1 .. 1 + name.len], name) or text[1 + name.len] != ']') continue;
        if (definitionOf(text)) |target| return target;
    }
    return null;
}

fn sameLabel(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const lx = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const ly = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (lx != ly) return false;
    }
    return true;
}

/// A row's cells: its pipes are where they part, one at either end
/// standing for nothing; a pipe after a backslash is the cell's own.
fn splitCells(line: []const u8, into: *[most_columns][]const u8) usize {
    var text = trim(line);
    if (text.len > 0 and text[0] == '|') text = text[1..];
    if (text.len > 0 and text[text.len - 1] == '|' and !(text.len >= 2 and text[text.len - 2] == '\\')) text = text[0 .. text.len - 1];
    var count: usize = 0;
    var start: usize = 0;
    var at: usize = 0;
    while (at <= text.len and count < into.len) : (at += 1) {
        if (at < text.len and text[at] == '\\') {
            at += 1;
            continue;
        }
        if (at == text.len or text[at] == '|') {
            into[count] = trim(text[start..@min(at, text.len)]);
            count += 1;
            start = at + 1;
        }
    }
    return count;
}

/// A cell of a delimiter row: how its column stands, or null for one
/// that is not `---`, `:--`, `--:` or `:-:`.
fn delimiterOf(cell: []const u8) ?u8 {
    if (cell.len == 0) return null;
    const left = cell[0] == ':';
    const right = cell[cell.len - 1] == ':';
    const from: usize = if (left) 1 else 0;
    const to: usize = if (right and cell.len > from) cell.len - 1 else cell.len;
    if (to <= from) return null;
    for (cell[from..to]) |byte| {
        if (byte != '-') return null;
    }
    if (left and right) return tdc.TDALIGN_CENTRE;
    if (right) return tdc.TDALIGN_RIGHT;
    return tdc.TDALIGN_LEFT;
}

fn trim(text: []const u8) []const u8 {
    var from: usize = 0;
    var to = text.len;
    while (from < to and (text[from] == ' ' or text[from] == '\t')) from += 1;
    while (to > from and (text[to - 1] == ' ' or text[to - 1] == '\t')) to -= 1;
    return text[from..to];
}

fn indexOf(text: []const u8, byte: u8) ?usize {
    for (text, 0..) |b, i| {
        if (b == byte) return i;
    }
    return null;
}

fn startsWith(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and sameLabel(text[0..prefix.len], prefix);
}

fn contains(text: []const u8, part: []const u8) bool {
    if (part.len > text.len) return false;
    var at: usize = 0;
    while (at + part.len <= text.len) : (at += 1) {
        if (std.mem.eql(u8, text[at..][0..part.len], part)) return true;
    }
    return false;
}

// --- what is inside a block --------------------------------------------------

/// How a stretch of text is drawn before emphasis is added: its block's
/// font, style and pen, and the link it is inside.
const Look = struct {
    font: u8 = tdc.TDFONT_NORMAL,
    style: u16 = 0,
    pen: u32 = tdc.TDPEN_TEXT,
    link_offset: u32 = 0,
    link_length: u32 = 0,
    /// Inside a link: a link inside is not one.
    in_link: bool = false,
};

/// A stretch of a block read: emphasis, code, links, pictures, tags and
/// entities.
const Inline = struct {
    out: *Build,
    source: []const u8,
    look: Look,
    /// The emphasis that is on, and which mark opened it, so that the
    /// same mark closes it.
    italic_mark: u8 = 0,
    bold_mark: u8 = 0,
    struck: usize = 0,
    /// Tags that are on: bold, italic, struck through, code.
    tag_bold: u8 = 0,
    tag_italic: u8 = 0,
    tag_struck: u8 = 0,
    tag_code: u8 = 0,
    /// An `<a href>` that is open: where its target was put.
    anchor: ?Target = null,

    const Target = struct { offset: u32, length: u32 };

    /// The run from here on started, as everything that is on says.
    fn wearNow(it: *Inline) void {
        var style = it.look.style;
        if (it.bold_mark != 0 or it.tag_bold != 0) style |= bold;
        if (it.italic_mark != 0 or it.tag_italic != 0) style |= italic;
        if (it.struck != 0 or it.tag_struck != 0) style |= tdc.TDSTYLE_STRUCK;
        var piece = tdc.Piece{ .font = it.look.font, .style = style, .pen = it.look.pen, .link_offset = it.look.link_offset, .link_length = it.look.link_length };
        if (it.tag_code != 0) {
            piece.font = tdc.TDFONT_FIXED;
            piece.style |= tdc.TDSTYLE_CODE;
        }
        if (it.anchor) |a| {
            piece.pen = tdc.TDPEN_LINK;
            piece.style |= underlined;
            piece.link_offset = a.offset;
            piece.link_length = a.length;
        }
        it.out.wear(piece);
    }

    fn run(it: *Inline, text: []const u8) void {
        it.wearNow();
        var at: usize = 0;
        while (at < text.len) {
            const c = text[at];
            switch (c) {
                '\\' => {
                    if (at + 1 < text.len and text[at + 1] == '\n') {
                        it.out.put('\n');
                        at = skipSpaces(text, at + 2);
                        continue;
                    }
                    if (at + 1 < text.len and isPunct(text[at + 1])) {
                        it.out.putCode(text[at + 1]);
                        at += 2;
                        continue;
                    }
                },
                ' ', '\t' => {
                    // Spaces are one space; before a line end, two of
                    // them break the line there.
                    var end = at;
                    while (end < text.len and (text[end] == ' ' or text[end] == '\t')) end += 1;
                    if (end < text.len and text[end] == '\n') {
                        it.out.put(if (end - at >= 2) '\n' else ' ');
                        at = skipSpaces(text, end + 1);
                        continue;
                    }
                    if (end < text.len) it.out.put(' ');
                    at = end;
                    continue;
                },
                '\n' => {
                    it.out.put(' ');
                    at = skipSpaces(text, at + 1);
                    continue;
                },
                '`' => if (codeSpan(text, at)) |span| {
                    it.tag_code += 1;
                    it.wearNow();
                    for (span.content) |byte| it.out.putCode(if (byte == '\n') ' ' else byte);
                    it.tag_code -= 1;
                    it.wearNow();
                    at = span.end;
                    continue;
                },
                '[' => if (it.link(text, at, false)) |after| {
                    at = after;
                    continue;
                },
                '!' => if (at + 1 < text.len and text[at + 1] == '[') {
                    if (it.link(text, at + 1, true)) |after| {
                        at = after;
                        continue;
                    }
                },
                '<' => if (it.angle(text, at)) |after| {
                    at = after;
                    continue;
                },
                '*', '_' => {
                    at = it.emphasis(text, at);
                    continue;
                },
                '~' => {
                    at = it.strike(text, at);
                    continue;
                },
                '&' => if (entity(text, at)) |found| {
                    if (found.text.len > 0) it.out.putText(found.text) else it.out.putCode(found.code);
                    at = found.end;
                    continue;
                },
                'h', 'w', 'H', 'W' => if (!it.look.in_link and it.anchor == null) {
                    if (bareLink(text, at)) |end| {
                        it.linkTo(text[at..end], text[at..end]);
                        at = end;
                        continue;
                    }
                },
                else => {},
            }
            const decoded = decode(text, at);
            it.out.putCode(decoded.code);
            at += decoded.length;
        }
    }

    /// `*` and `_`: one for italic, two for bold, three for both - where
    /// they open, a closing run of the same mark coming later; where
    /// they close, the same mark having opened.
    fn emphasis(it: *Inline, text: []const u8, at: usize) usize {
        const c = text[at];
        var run_len: usize = 0;
        while (at + run_len < text.len and text[at + run_len] == c) run_len += 1;
        const before: u8 = if (at > 0) text[at - 1] else ' ';
        const after: u8 = if (at + run_len < text.len) text[at + run_len] else ' ';
        const left = !isSpace(after) and (!isPunct(after) or isSpace(before) or isPunct(before));
        const right = !isSpace(before) and (!isPunct(before) or isSpace(after) or isPunct(after));
        // An underscore inside a word is a letter of it.
        const can_open = if (c == '_') left and (!right or isPunct(before)) else left;
        const can_close = if (c == '_') right and (!left or isPunct(after)) else right;
        if (run_len <= 3) {
            var used: usize = 0;
            if (can_close) {
                if (run_len == 3 and it.bold_mark == c and it.italic_mark == c) {
                    it.bold_mark = 0;
                    it.italic_mark = 0;
                    used = 3;
                } else if (run_len >= 2 and it.bold_mark == c) {
                    it.bold_mark = 0;
                    used = 2;
                } else if (it.italic_mark == c) {
                    it.italic_mark = 0;
                    used = 1;
                }
            }
            if (used == 0 and can_open) {
                if (run_len == 3 and it.bold_mark == 0 and it.italic_mark == 0 and closesLater(text, at + 3, c, 3)) {
                    it.bold_mark = c;
                    it.italic_mark = c;
                    used = 3;
                } else if (run_len >= 2 and it.bold_mark == 0 and closesLater(text, at + run_len, c, 2)) {
                    it.bold_mark = c;
                    used = 2;
                } else if (run_len != 2 and it.italic_mark == 0 and closesLater(text, at + run_len, c, 1)) {
                    it.italic_mark = c;
                    used = 1;
                }
            }
            if (used != 0) {
                // What is left of the run is a mark as written.
                it.wearNow();
                if (used < run_len) {
                    for (0..run_len - used) |_| it.out.put(c);
                    it.out.inked = true;
                }
                return at + run_len;
            }
        }
        for (0..run_len) |_| it.out.put(c);
        it.out.inked = true;
        return at + run_len;
    }

    /// `~~` and `~`: struck through, between two of the same.
    fn strike(it: *Inline, text: []const u8, at: usize) usize {
        var run_len: usize = 0;
        while (at + run_len < text.len and text[at + run_len] == '~') run_len += 1;
        const before: u8 = if (at > 0) text[at - 1] else ' ';
        const after: u8 = if (at + run_len < text.len) text[at + run_len] else ' ';
        if (run_len <= 2) {
            if (it.struck == run_len and !isSpace(before)) {
                it.struck = 0;
                it.wearNow();
                return at + run_len;
            }
            if (it.struck == 0 and !isSpace(after) and closesLater(text, at + run_len, '~', run_len)) {
                it.struck = run_len;
                it.wearNow();
                return at + run_len;
            }
        }
        for (0..run_len) |_| it.out.put('~');
        it.out.inked = true;
        return at + run_len;
    }

    /// `[text](target)`, `[text][name]`, `[name]` where the document
    /// defines it, and the same after `!` for a picture: its text drawn,
    /// a link's in the link's colour, underlined, leading where it says.
    /// Where it ends, or null when it is not one after all.
    fn link(it: *Inline, text: []const u8, open: usize, picture: bool) ?usize {
        const close = closingBracket(text, open) orelse return null;
        const shown = text[open + 1 .. close];
        var target: []const u8 = "";
        var end = close + 1;
        if (end < text.len and text[end] == '(') {
            const dest = destination(text, end + 1) orelse return null;
            target = dest.target;
            end = dest.end;
        } else if (end < text.len and text[end] == '[') {
            const name_end = indexOf(text[end + 1 ..], ']') orelse return null;
            const name = text[end + 1 .. end + 1 + name_end];
            target = findDefinition(it.source, if (name.len == 0) shown else name) orelse return null;
            end = end + 2 + name_end;
        } else {
            target = findDefinition(it.source, shown) orelse return null;
        }
        if (picture) {
            // A picture is not drawn: what it says it is stands in its
            // place - inside a link, as the link.
            var inner = Inline{ .out = it.out, .source = it.source, .look = it.look };
            if (!it.look.in_link and it.anchor == null) {
                inner.look.pen = tdc.TDPEN_MUTED;
                inner.look.style |= italic;
            }
            inner.run(shown);
            it.wearNow();
            return end;
        }
        if (it.look.in_link or it.anchor != null) {
            var inner = Inline{ .out = it.out, .source = it.source, .look = it.look };
            inner.run(shown);
            it.wearNow();
            return end;
        }
        it.linkTo(shown, target);
        return end;
    }

    /// `shown` drawn as a link to `target`.
    fn linkTo(it: *Inline, shown: []const u8, target: []const u8) void {
        const where = it.out.putTarget(target);
        var inner = Inline{ .out = it.out, .source = it.source, .look = it.look };
        inner.look.pen = tdc.TDPEN_LINK;
        inner.look.style |= underlined;
        inner.look.link_offset = where.offset;
        inner.look.link_length = where.length;
        inner.look.in_link = true;
        inner.run(shown);
        it.wearNow();
    }

    /// `<` - an autolink, a comment, or a tag. Where it ends, or null
    /// for a `<` that is a character.
    fn angle(it: *Inline, text: []const u8, at: usize) ?usize {
        const close = indexOf(text[at..], '>') orelse return null;
        const inside = text[at + 1 .. at + close];
        const end = at + close + 1;
        if (startsWith(inside, "!--")) {
            const stop = findText(text, at, "-->") orelse return null;
            return stop + 3;
        }
        if (inside.len == 0) return null;
        // <https://...> and <someone@somewhere>.
        if (indexOf(inside, ' ') == null and (indexOf(inside, ':') != null or indexOf(inside, '@') != null) and isLetter(inside[0])) {
            if (it.look.in_link or it.anchor != null) {
                it.out.putText(inside);
                return end;
            }
            it.linkTo(inside, inside);
            return end;
        }
        const closing = inside[0] == '/';
        const name_from: usize = if (closing) 1 else 0;
        var name_to = name_from;
        while (name_to < inside.len and isLetter(inside[name_to])) name_to += 1;
        while (name_to < inside.len and inside[name_to] >= '0' and inside[name_to] <= '9') name_to += 1;
        if (name_to == name_from) return null;
        const name = inside[name_from..name_to];
        const on: i16 = if (closing) -1 else 1;
        if (sameLabel(name, "br")) {
            it.out.put('\n');
        } else if (sameLabel(name, "b") or sameLabel(name, "strong")) {
            it.tag_bold = step(it.tag_bold, on);
        } else if (sameLabel(name, "i") or sameLabel(name, "em")) {
            it.tag_italic = step(it.tag_italic, on);
        } else if (sameLabel(name, "s") or sameLabel(name, "del") or sameLabel(name, "strike")) {
            it.tag_struck = step(it.tag_struck, on);
        } else if (sameLabel(name, "code") or sameLabel(name, "kbd") or sameLabel(name, "tt") or sameLabel(name, "samp")) {
            it.tag_code = step(it.tag_code, on);
        } else if (sameLabel(name, "a") and !it.look.in_link) {
            if (closing) {
                it.anchor = null;
            } else if (attribute(inside, "href")) |href| {
                const where = it.out.putTarget(href);
                it.anchor = .{ .offset = where.offset, .length = where.length };
            }
        } else if (sameLabel(name, "img") and !closing) {
            if (attribute(inside, "alt")) |alt| {
                var inner = Inline{ .out = it.out, .source = it.source, .look = it.look };
                if (!it.look.in_link and it.anchor == null) {
                    inner.look.pen = tdc.TDPEN_MUTED;
                    inner.look.style |= italic;
                }
                inner.anchor = it.anchor;
                inner.run(alt);
            }
        }
        it.wearNow();
        return end;
    }
};

fn step(count: u8, by: i16) u8 {
    if (by < 0) return if (count > 0) count - 1 else 0;
    return count +| 1;
}

/// An attribute's value in a tag: `name="value"`.
fn attribute(tag: []const u8, name: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (at + name.len < tag.len) : (at += 1) {
        if (!sameLabel(tag[at..][0..name.len], name)) continue;
        if (at > 0 and isLetter(tag[at - 1])) continue;
        var i = at + name.len;
        while (i < tag.len and tag[i] == ' ') i += 1;
        if (i >= tag.len or tag[i] != '=') continue;
        i += 1;
        while (i < tag.len and tag[i] == ' ') i += 1;
        if (i >= tag.len) return null;
        const quote = tag[i];
        if (quote == '"' or quote == '\'') {
            const close = indexOf(tag[i + 1 ..], quote) orelse return null;
            return tag[i + 1 .. i + 1 + close];
        }
        var end = i;
        while (end < tag.len and tag[end] != ' ' and tag[end] != '/') end += 1;
        return tag[i..end];
    }
    return null;
}

fn findText(text: []const u8, from: usize, part: []const u8) ?usize {
    var at = from;
    while (at + part.len <= text.len) : (at += 1) {
        if (std.mem.eql(u8, text[at..][0..part.len], part)) return at;
    }
    return null;
}

fn skipSpaces(text: []const u8, from: usize) usize {
    var at = from;
    while (at < text.len and (text[at] == ' ' or text[at] == '\t')) at += 1;
    return at;
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n';
}

fn isLetter(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
}

/// ASCII's punctuation, which a backslash makes a character.
fn isPunct(byte: u8) bool {
    return (byte >= '!' and byte <= '/') or (byte >= ':' and byte <= '@') or (byte >= '[' and byte <= '`') or (byte >= '{' and byte <= '~');
}

/// Whether a run of `mark` at least `need` long, that can close, comes
/// later in the text.
fn closesLater(text: []const u8, from: usize, mark: u8, need: usize) bool {
    var at = from;
    while (at < text.len) {
        if (text[at] != mark) {
            at += 1;
            continue;
        }
        var run_len: usize = 0;
        while (at + run_len < text.len and text[at + run_len] == mark) run_len += 1;
        const before: u8 = if (at > 0) text[at - 1] else ' ';
        if (run_len >= need and !isSpace(before)) return true;
        at += run_len;
    }
    return false;
}

/// `` `code` ``: what is between two runs of as many backticks, one
/// space at either end taken off where both have one.
const Code = struct { content: []const u8, end: usize };

fn codeSpan(text: []const u8, at: usize) ?Code {
    var marks: usize = 0;
    while (at + marks < text.len and text[at + marks] == '`') marks += 1;
    var walk = at + marks;
    while (walk < text.len) {
        if (text[walk] != '`') {
            walk += 1;
            continue;
        }
        var run_len: usize = 0;
        while (walk + run_len < text.len and text[walk + run_len] == '`') run_len += 1;
        if (run_len == marks) {
            var content = text[at + marks .. walk];
            if (content.len >= 2 and (content[0] == ' ' or content[0] == '\n') and (content[content.len - 1] == ' ' or content[content.len - 1] == '\n') and !isBlank(content)) {
                content = content[1 .. content.len - 1];
            }
            return .{ .content = content, .end = walk + run_len };
        }
        walk += run_len;
    }
    return null;
}

/// The `]` that closes the `[` at `open`, brackets inside counted.
fn closingBracket(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var at = open;
    while (at < text.len) : (at += 1) {
        switch (text[at]) {
            '\\' => at += 1,
            '`' => if (codeSpan(text, at)) |span| {
                at = span.end - 1;
            },
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return at;
            },
            else => {},
        }
    }
    return null;
}

/// A link's destination after its `(`, and a title after it, which is
/// passed over: the target, and where the `)` ends it.
fn destination(text: []const u8, from: usize) ?struct { target: []const u8, end: usize } {
    var at = skipSpaces(text, from);
    var target: []const u8 = "";
    if (at < text.len and text[at] == '<') {
        const close = indexOf(text[at..], '>') orelse return null;
        target = text[at + 1 .. at + close];
        at += close + 1;
    } else {
        const start = at;
        var depth: usize = 0;
        while (at < text.len and !isSpace(text[at])) : (at += 1) {
            if (text[at] == '(') depth += 1;
            if (text[at] == ')') {
                if (depth == 0) break;
                depth -= 1;
            }
        }
        target = text[start..at];
    }
    at = skipSpaces(text, at);
    if (at < text.len and (text[at] == '"' or text[at] == '\'' or text[at] == '(')) {
        const quote: u8 = if (text[at] == '(') ')' else text[at];
        const close = indexOf(text[at + 1 ..], quote) orelse return null;
        at = skipSpaces(text, at + 2 + close);
    }
    if (at >= text.len or text[at] != ')') return null;
    return .{ .target = target, .end = at + 1 };
}

/// `http://`, `https://` or `www.` at the start of a word: where the
/// address ends, the punctuation after it not part of it.
fn bareLink(text: []const u8, at: usize) ?usize {
    if (at > 0 and !isSpace(text[at - 1]) and text[at - 1] != '(' and text[at - 1] != '*' and text[at - 1] != '_') return null;
    const rest = text[at..];
    if (!startsWith(rest, "http://") and !startsWith(rest, "https://") and !startsWith(rest, "www.")) return null;
    var end = at;
    while (end < text.len and !isSpace(text[end]) and text[end] != '<') end += 1;
    var depth: i32 = 0;
    for (text[at..end]) |byte| {
        if (byte == '(') depth += 1;
        if (byte == ')') depth -= 1;
    }
    while (end > at) {
        const last = text[end - 1];
        if (last == ')' and depth < 0) {
            depth += 1;
            end -= 1;
            continue;
        }
        switch (last) {
            '.', ',', ':', ';', '!', '?', '"', '\'', '*', '_', '~' => end -= 1,
            else => break,
        }
    }
    const shortest: usize = if (startsWith(rest, "www.")) 5 else 9;
    if (end - at < shortest) return null;
    return end;
}

/// `&name;`, `&#number;` and `&#xhex;`: the character, or text for one
/// Latin-1 has not; and where it ends.
const Entity = struct { code: u32 = 0, text: []const u8 = "", end: usize };

fn entity(text: []const u8, at: usize) ?Entity {
    var end = at + 1;
    while (end < text.len and end - at < 12 and text[end] != ';' and !isSpace(text[end])) end += 1;
    if (end >= text.len or text[end] != ';' or end == at + 1) return null;
    const name = text[at + 1 .. end];
    if (name[0] == '#') {
        var code: u32 = 0;
        const hex = name.len > 1 and (name[1] == 'x' or name[1] == 'X');
        const digits = name[if (hex) 2 else 1..];
        if (digits.len == 0) return null;
        for (digits) |d| {
            const value: u32 = switch (d) {
                '0'...'9' => d - '0',
                'a'...'f' => if (hex) d - 'a' + 10 else return null,
                'A'...'F' => if (hex) d - 'A' + 10 else return null,
                else => return null,
            };
            code = (code *| (if (hex) @as(u32, 16) else 10)) +| value;
        }
        return .{ .code = code, .end = end + 1 };
    }
    const Named = struct { name: []const u8, code: u32 = 0, text: []const u8 = "" };
    const names = [_]Named{
        .{ .name = "amp", .code = '&' },       .{ .name = "lt", .code = '<' },        .{ .name = "gt", .code = '>' },
        .{ .name = "quot", .code = '"' },      .{ .name = "apos", .code = '\'' },     .{ .name = "nbsp", .code = 0xA0 },
        .{ .name = "copy", .code = 0xA9 },     .{ .name = "reg", .code = 0xAE },      .{ .name = "deg", .code = 0xB0 },
        .{ .name = "middot", .code = 0xB7 },   .{ .name = "times", .code = 0xD7 },    .{ .name = "divide", .code = 0xF7 },
        .{ .name = "plusmn", .code = 0xB1 },   .{ .name = "sect", .code = 0xA7 },     .{ .name = "para", .code = 0xB6 },
        .{ .name = "laquo", .code = 0xAB },    .{ .name = "raquo", .code = 0xBB },    .{ .name = "pound", .code = 0xA3 },
        .{ .name = "yen", .code = 0xA5 },      .{ .name = "cent", .code = 0xA2 },     .{ .name = "frac12", .code = 0xBD },
        .{ .name = "frac14", .code = 0xBC },   .{ .name = "frac34", .code = 0xBE },   .{ .name = "auml", .code = 0xE4 },
        .{ .name = "ouml", .code = 0xF6 },     .{ .name = "uuml", .code = 0xFC },     .{ .name = "Auml", .code = 0xC4 },
        .{ .name = "Ouml", .code = 0xD6 },     .{ .name = "Uuml", .code = 0xDC },     .{ .name = "szlig", .code = 0xDF },
        .{ .name = "eacute", .code = 0xE9 },   .{ .name = "egrave", .code = 0xE8 },   .{ .name = "agrave", .code = 0xE0 },
        .{ .name = "ccedil", .code = 0xE7 },   .{ .name = "mdash", .text = "-" },     .{ .name = "ndash", .text = "-" },
        .{ .name = "hellip", .text = "..." },  .{ .name = "lsquo", .text = "'" },     .{ .name = "rsquo", .text = "'" },
        .{ .name = "ldquo", .text = "\"" },    .{ .name = "rdquo", .text = "\"" },    .{ .name = "trade", .text = "TM" },
        .{ .name = "euro", .text = "EUR" },    .{ .name = "larr", .text = "<-" },     .{ .name = "rarr", .text = "->" },
        .{ .name = "bull", .code = 0xB7 },     .{ .name = "ensp", .code = ' ' },      .{ .name = "emsp", .code = ' ' },
    };
    for (names) |n| {
        if (std.mem.eql(u8, n.name, name)) return .{ .code = n.code, .text = n.text, .end = end + 1 };
    }
    return null;
}

const std = @import("std");
const testing = std.testing;

/// The document built twice, as the class does it, and what came out.
const Read = struct { text: []u8, pieces: []tdc.Piece, blocks: []tdc.Block };

fn readTwice(from: []const u8, text: []u8, pieces: []tdc.Piece, blocks: []tdc.Block) Read {
    var scratch: [1024]u8 = undefined;
    var counting = Build{ .scratch = scratch[0..from.len] };
    build(from, &counting);
    var writing = Build{
        .scratch = scratch[0..from.len],
        .text = text.ptr,
        .pieces = pieces.ptr,
        .blocks = blocks.ptr,
        .link_base = counting.text_len,
    };
    build(from, &writing);
    std.debug.assert(writing.text_len == counting.text_len);
    std.debug.assert(writing.piece_count == counting.piece_count);
    std.debug.assert(writing.block_count == counting.block_count);
    return .{ .text = text[0..writing.text_len], .pieces = pieces[0..writing.piece_count], .blocks = blocks[0..writing.block_count] };
}

/// The text of a block, without the character that ends it.
fn textOf(read: Read, block: tdc.Block) []const u8 {
    if (block.count == 0) return "";
    const first = read.pieces[block.first];
    const last = read.pieces[block.first + block.count - 1];
    return read.text[first.offset .. last.offset + last.length - 1];
}

test "both passes agree on how much there is" {
    const source = "# Title\n\nSome *words* and `code`.\n\n- one\n- two\n\n| a | b |\n|---|--:|\n| 1 | 2 |\n";
    var text: [256]u8 = undefined;
    var pieces: [64]tdc.Piece = undefined;
    var blocks: [32]tdc.Block = undefined;
    _ = readTwice(source, &text, &pieces, &blocks);
}

test "the marks are gone and the runs say what they meant" {
    const source = "# Title\n\nSome *words* here.\n";
    var text: [256]u8 = undefined;
    var pieces: [64]tdc.Piece = undefined;
    var blocks: [8]tdc.Block = undefined;
    const got = readTwice(source, &text, &pieces, &blocks);
    try testing.expectEqualStrings("Title\nSome words here.\n", got.text);
    try testing.expectEqual(@as(usize, 2), got.blocks.len);
    try testing.expectEqual(tdc.TDBLOCK_HEADING, got.blocks[0].kind);
    try testing.expectEqual(@as(u8, 1), got.blocks[0].level);
    try testing.expectEqual(tdc.TDFONT_LARGER, got.pieces[got.blocks[0].first].font);
    try testing.expectEqual(bold, got.pieces[got.blocks[0].first].style);
    var emphasised: u32 = 0;
    for (got.pieces) |piece| {
        if (piece.style & italic != 0) emphasised += piece.length;
    }
    try testing.expectEqual(@as(u32, 5), emphasised); // "words"
}

test "a paragraph's own line ends are spaces, and emphasis runs on across them" {
    const source = "one **two\nthree** four  \nfive\n\nsix\n";
    var text: [64]u8 = undefined;
    var pieces: [16]tdc.Piece = undefined;
    var blocks: [8]tdc.Block = undefined;
    const got = readTwice(source, &text, &pieces, &blocks);
    try testing.expectEqualStrings("one two three four\nfive\nsix\n", got.text);
    var strong: u32 = 0;
    for (got.pieces) |piece| {
        if (piece.style & bold != 0) strong += piece.length;
    }
    try testing.expectEqual(@as(u32, 9), strong); // "two three"
}

test "a listing is kept as it stands" {
    const source = "```zig\n  a  b\n*not* emphasis\n```\n";
    var text: [64]u8 = undefined;
    var pieces: [16]tdc.Piece = undefined;
    var blocks: [8]tdc.Block = undefined;
    const got = readTwice(source, &text, &pieces, &blocks);
    try testing.expectEqualStrings("  a  b\n*not* emphasis\n", got.text);
    try testing.expectEqual(tdc.TDBLOCK_LISTING, got.blocks[0].kind);
    try testing.expectEqual(tdc.TDFONT_FIXED, got.pieces[0].font);
}

test "a link shows its name and remembers where it leads" {
    const source = "See [the guide](docs/guide.md \"Guide\") and <https://x.org>.\n";
    var text: [128]u8 = undefined;
    var pieces: [16]tdc.Piece = undefined;
    var blocks: [8]tdc.Block = undefined;
    const got = readTwice(source, &text, &pieces, &blocks);
    try testing.expectEqualStrings("See the guide and https://x.org.\n", got.text);
    var found: u32 = 0;
    for (got.pieces) |piece| {
        if (piece.link_length == 0) continue;
        found += 1;
        // The target is past the end of the text, where nothing draws it.
        try testing.expect(piece.link_offset >= got.text.len);
        try testing.expectEqual(tdc.TDPEN_LINK, piece.pen);
    }
    try testing.expectEqual(@as(u32, 2), found);
    try testing.expectEqualStrings("docs/guide.md", text[got.pieces[1].link_offset..][0..got.pieces[1].link_length]);
}

test "lists keep their marks, numbers and depth, and a blank line between items loosens them" {
    const source = "- one\n- two\n  - deeper\n\n3. third\n4. fourth\n\n   more of it\n";
    var text: [128]u8 = undefined;
    var pieces: [32]tdc.Piece = undefined;
    var blocks: [16]tdc.Block = undefined;
    const got = readTwice(source, &text, &pieces, &blocks);
    try testing.expectEqualStrings("one\ntwo\ndeeper\nthird\nfourth\nmore of it\n", got.text);
    try testing.expectEqual(tdc.TDMARK_DISC, got.blocks[0].mark);
    try testing.expectEqual(tdc.TDMARK_CIRCLE, got.blocks[2].mark);
    try testing.expectEqual(@as(u8, 2), got.blocks[2].depth);
    try testing.expectEqual(tdc.TDMARK_NUMBER, got.blocks[3].mark);
    try testing.expectEqual(@as(u32, 3), got.blocks[3].number);
    try testing.expectEqual(@as(u32, 4), got.blocks[4].number);
    try testing.expectEqual(tdc.TDMARK_NONE, got.blocks[5].mark);
    // Each list's first item says it starts one.
    try testing.expect(got.blocks[0].flags & tdc.TDBF_START != 0);
    try testing.expect(got.blocks[1].flags & tdc.TDBF_START == 0);
    try testing.expect(got.blocks[2].flags & tdc.TDBF_START != 0);
    try testing.expect(got.blocks[3].flags & tdc.TDBF_START != 0);
    // The first list is tight; the second loose, its paragraph after a
    // blank line inside an item.
    try testing.expect(got.blocks[0].flags & tdc.TDBF_LOOSE == 0);
    try testing.expect(got.blocks[3].flags & tdc.TDBF_LOOSE != 0);
    try testing.expect(got.blocks[5].flags & tdc.TDBF_LOOSE != 0);
}

test "a task's box, a quote's depth and a rule" {
    const source = "- [ ] open\n- [x] done\n\n> quoted\n> - in a list\n\n---\n";
    var text: [128]u8 = undefined;
    var pieces: [32]tdc.Piece = undefined;
    var blocks: [16]tdc.Block = undefined;
    const got = readTwice(source, &text, &pieces, &blocks);
    try testing.expectEqualStrings("open\ndone\nquoted\nin a list\n\n", got.text);
    try testing.expectEqual(tdc.TDMARK_TASK, got.blocks[0].mark);
    try testing.expectEqual(tdc.TDMARK_DONE, got.blocks[1].mark);
    try testing.expectEqual(@as(u8, 1), got.blocks[2].quotes);
    try testing.expectEqual(tdc.TDPEN_MUTED, got.pieces[got.blocks[2].first].pen);
    try testing.expectEqual(@as(u8, 2), got.blocks[3].depth);
    try testing.expectEqual(@as(u8, 1), got.blocks[3].quotes);
    try testing.expectEqual(tdc.TDBLOCK_RULE, got.blocks[4].kind);
}

test "a table is a block a cell, with its head and its columns' alignment" {
    const source = "| Name | Size |\n|:-----|-----:|\n| a | 1 |\n| b \\| c |\n";
    var text: [128]u8 = undefined;
    var pieces: [32]tdc.Piece = undefined;
    var blocks: [16]tdc.Block = undefined;
    const got = readTwice(source, &text, &pieces, &blocks);
    try testing.expectEqualStrings("Name\tSize\na\t1\nb | c\t\n", got.text);
    try testing.expectEqual(@as(usize, 6), got.blocks.len);
    try testing.expect(got.blocks[0].flags & (tdc.TDBF_TABLE | tdc.TDBF_ROW | tdc.TDBF_HEAD) == tdc.TDBF_TABLE | tdc.TDBF_ROW | tdc.TDBF_HEAD);
    try testing.expectEqual(tdc.TDALIGN_RIGHT, got.blocks[1].alignment);
    try testing.expectEqual(@as(u32, 1), got.blocks[3].number);
    try testing.expect(got.blocks[2].flags & tdc.TDBF_HEAD == 0);
    try testing.expectEqualStrings("b | c", textOf(got, got.blocks[4]));
}

test "UTF-8, entities and tags come out as Latin-1" {
    const source = "Gr\xc3\xbc\xc3\x9fe \xe2\x80\x9cso\xe2\x80\x9d \xe2\x80\x94 &amp; &copy; <b>fett</b>\xf0\x9f\x9a\x80<br>~~weg~~\n";
    var text: [128]u8 = undefined;
    var pieces: [32]tdc.Piece = undefined;
    var blocks: [8]tdc.Block = undefined;
    const got = readTwice(source, &text, &pieces, &blocks);
    try testing.expectEqualStrings("Gr\xfc\xdfe \"so\" - & \xa9 fett\nweg\n", got.text);
    var found_bold = false;
    var found_struck = false;
    for (got.pieces) |piece| {
        if (piece.style & bold != 0) found_bold = true;
        if (piece.style & tdc.TDSTYLE_STRUCK != 0) found_struck = true;
    }
    try testing.expect(found_bold and found_struck);
}

test "a heading underlined, and a paragraph that comes to nothing" {
    const source = "Title\n=====\n\n<p align=\"center\">\n\nSub\n---\n";
    var text: [64]u8 = undefined;
    var pieces: [16]tdc.Piece = undefined;
    var blocks: [8]tdc.Block = undefined;
    const got = readTwice(source, &text, &pieces, &blocks);
    try testing.expectEqualStrings("Title\nSub\n", got.text);
    try testing.expectEqual(@as(u8, 1), got.blocks[0].level);
    try testing.expectEqual(@as(u8, 2), got.blocks[1].level);
}

test "code inside a line is fixed-width on its own ground" {
    const source = "a `b c` d\n";
    var text: [32]u8 = undefined;
    var pieces: [8]tdc.Piece = undefined;
    var blocks: [4]tdc.Block = undefined;
    const got = readTwice(source, &text, &pieces, &blocks);
    try testing.expectEqualStrings("a b c d\n", got.text);
    try testing.expectEqual(tdc.TDFONT_FIXED, got.pieces[1].font);
    try testing.expect(got.pieces[1].style & tdc.TDSTYLE_CODE != 0);
    try testing.expectEqual(@as(u32, 3), got.pieces[1].length);
}
