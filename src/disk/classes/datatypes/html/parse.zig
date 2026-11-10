// SPDX-License-Identifier: MIT
//! An HTML document read into text, the runs it is drawn as and the
//! blocks they are in - the page as it reads, laid out by text.datatype.
//!
//! **Elements are kept open as a browser keeps them.** A `<p>` is closed
//! by the next block, an `<li>` by the next item, a cell by the next cell
//! and a row by the next row; an end tag closes what was opened after
//! its element too, and one with no element open is passed over. No tree
//! is built: what each open element changed - a list it is in, a style,
//! a link - is undone when it closes.
//!
//! **Blocks are what the elements say.** A heading is a heading, `<pre>`
//! a listing, `<hr>` a rule, an item of `<ul>` or `<ol>` an item behind
//! its disc or number, a `<blockquote>` a quote and a `<dd>` indented;
//! every other element that stands on its own - a `<div>`, a
//! `<section>`, a `<p>` - ends the paragraph before it, and text outside
//! all of them is a paragraph of its own. Runs of white space are one
//! space, and none at a block's start or end; `<br>` ends a line.
//!
//! **A table is drawn as one when it is one**: rows of cells, two or more
//! across, with no table inside. One that holds another table, or that
//! is a single column, lays a page out, and its cells are read as blocks
//! one under another. Inside a cell of a table drawn as one, what would
//! be blocks are lines. A cell's `colspan` is the columns it is drawn
//! across, and gives the next cell its column; a `rowspan` keeps its
//! column taken in the rows below.
//!
//! **What is not shown is left out**: scripts and styles, an element
//! marked `hidden`, `aria-hidden` or `display:none`, pictures drawn from
//! markup (`<svg>`, `<math>`), what a film or a sound would show, and of
//! a `<select>` every option but the chosen one. A picture is its `alt`
//! text, set back in italic; a field and a button are their label in
//! brackets; `<q>` is in quotes.
//!
//! **Text is Latin-1**, which is what graphics draws. The document is
//! made Latin-1 before it is read (`toLatin1`); a reference to a
//! character past it, and a byte of code page 1252 that Latin-1 has as a
//! control, is written as utility.library writes typesetting's
//! characters - plain quotes, dashes, `...` - or a `?`. A link's target
//! is written with its spaces and what is past ASCII as `%` and UTF-8's
//! bytes, which is how an address carries them.
//!
//! **It is read twice.** The first pass counts how much text, how many
//! runs and how many blocks there will be, the second writes them, and
//! both run the same code with the writing switched off. A link's target
//! is written past the end of the text, where nothing draws it.

const sdk = @import("sdk");
const utility = sdk.utility;
const tdc = sdk.datatypes.textclass;
const UtilityBase = sdk.interface.utility.UtilityBase;
const tokens = @import("tokens.zig");
const entities = @import("entities.zig");
const elements = @import("elements.zig");
const Tag = elements.Tag;
const attribute = tokens.attribute;

/// graphics.FSF_: the styles a run may be drawn with.
const bold: u16 = 1;
const italic: u16 = 2;
const underlined: u16 = 4;

/// The longest title kept, without its NUL.
pub const title_most = 127;

/// What is being written, or counted when nothing is being written.
pub const Build = struct {
    /// What a character past Latin-1 is written as.
    ub: *UtilityBase,
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
    /// The document's `<title>`, its white space made single spaces,
    /// NUL-terminated.
    title: [title_most + 1]u8 = @splat(0),
    title_len: usize = 0,

    fn put(out: *Build, byte: u8) void {
        if (out.text) |it| it[out.text_len] = byte;
        out.text_len += 1;
    }

    /// A run closed off. A run with nothing in it is not one.
    fn close(out: *Build) void {
        if (!out.open) return;
        out.open = false;
        const length = out.text_len - out.current.offset;
        if (length == 0) return;
        if (out.pieces) |it| {
            it[out.piece_count] = out.current;
            it[out.piece_count].length = length;
        }
        out.piece_count += 1;
    }

    /// A new run started, drawn the way `look` says.
    fn wear(out: *Build, look: tdc.Piece) void {
        out.close();
        out.current = look;
        out.current.offset = out.text_len;
        out.current.length = 0;
        out.open = true;
    }

    fn begin(out: *Build, block: tdc.Block) void {
        out.close();
        out.block = block;
        out.block.first = out.piece_count;
        out.inked = false;
    }

    /// The block ended by `terminator` - a newline, or a tab after a
    /// cell that is not the last of its row - in a run of its own.
    fn end(out: *Build, terminator: u8) void {
        out.wear(.{});
        out.put(terminator);
        out.close();
        out.block.count = out.piece_count - out.block.first;
        if (out.blocks) |it| it[out.block_count] = out.block;
        out.block_count += 1;
    }

    const Saved = struct { text_len: u32, piece_count: u32, block_count: u32 };

    fn save(out: *const Build) Saved {
        return .{ .text_len = out.text_len, .piece_count = out.piece_count, .block_count = out.block_count };
    }

    fn restore(out: *Build, saved: Saved) void {
        out.open = false;
        out.text_len = saved.text_len;
        out.piece_count = saved.piece_count;
        out.block_count = saved.block_count;
    }

    /// A byte of a link's target, past the end of the text.
    fn putTarget(out: *Build, byte: u8) void {
        if (out.text) |it| it[out.link_base + out.link_len] = byte;
        out.link_len += 1;
    }

    /// `flags` added to a block written already: a table's first row
    /// turned out to be its head.
    fn flag(out: *Build, index: u32, flags: u8) void {
        if (out.blocks) |it| it[index].flags |= flags;
    }
};

/// Whether the document says it is Latin-1 or code page 1252, which it
/// is then read as byte for byte; UTF-8 else. Only its first kilobyte is
/// looked at, where a `<meta charset>` has to be.
pub fn declaredLatin1(source: []const u8) bool {
    if (source.len >= 3 and source[0] == 0xEF and source[1] == 0xBB and source[2] == 0xBF) return false;
    const head = source[0..@min(source.len, 1024)];
    var at: usize = 0;
    while (at + 7 <= head.len) : (at += 1) {
        if (!elements.sameName(head[at..][0..7], "charset")) continue;
        var value = at + 7;
        while (value < head.len and (tokens.isSpace(head[value]) or head[value] == '=' or head[value] == '"' or head[value] == '\'')) value += 1;
        var value_end = value;
        while (value_end < head.len and isNameChar(head[value_end])) value_end += 1;
        const name = head[value..value_end];
        const latin = [_][]const u8{ "iso-8859-1", "iso8859-1", "iso-8859-15", "latin1", "latin-1", "l1", "windows-1252", "cp1252", "us-ascii", "ascii" };
        for (latin) |each| {
            if (elements.sameName(name, each)) return true;
        }
        return false;
    }
    return false;
}

fn isNameChar(char: u8) bool {
    return tokens.isLetter(char) or (char >= '0' and char <= '9') or char == '-' or char == '_';
}

/// The document made Latin-1 where it is: UTF-8 by utility.library,
/// typesetting's characters made plain and a byte that is no UTF-8 taken
/// as Latin-1; a document that says it is Latin-1 left as it is. Its
/// length afterwards, never more than before.
pub fn toLatin1(ub: *UtilityBase, document: []u8) usize {
    if (declaredLatin1(document)) return document.len;
    var conversion: utility.Utf8Conversion = .{ .flags = utility.UTF8F_TYPESET | utility.UTF8F_LATIN1 };
    return ub.Utf8ToLatin1(&conversion, document.ptr, document.len, document.ptr, document.len);
}

/// The whole document, Latin-1, read. Called once to count and once to
/// write.
pub fn build(from: []const u8, out: *Build) void {
    var p = Parser{ .out = out, .reader = .{ .source = from } };
    while (true) {
        const token = p.reader.next();
        switch (token.kind) {
            .done => break,
            .text => p.text(token),
            .start => p.start(token),
            .end => p.end(token),
            .other => p.raw_use = .none,
        }
    }
    p.popTo(0);
    if (p.cell_end_pending) p.finishCell('\n');
    p.boundary();
    out.close();
}

const most_open = 128;
const most_containers = 8;
const most_lists = 8;
const most_tables = 8;
const most_columns = 32;

/// What opening an element changed, to be undone when it closes.
const E_BLOCK: u32 = 1 << 0;
const E_BOLD: u32 = 1 << 1;
const E_ITALIC: u32 = 1 << 2;
const E_UNDERLINED: u32 = 1 << 3;
const E_STRUCK: u32 = 1 << 4;
const E_CODE: u32 = 1 << 5;
const E_FIXED: u32 = 1 << 6;
const E_BIG: u32 = 1 << 7;
const E_SMALL: u32 = 1 << 8;
const E_LINK: u32 = 1 << 9;
const E_HEADING: u32 = 1 << 10;
const E_PRE: u32 = 1 << 11;
const E_CONTAINER: u32 = 1 << 12;
const E_LIST: u32 = 1 << 13;
const E_TABLE: u32 = 1 << 14;
const E_ROW: u32 = 1 << 15;
const E_CELL: u32 = 1 << 16;
const E_UNSHOWN: u32 = 1 << 17;
const E_QUOTE: u32 = 1 << 18;
const E_BRACKETS: u32 = 1 << 19;
const E_PARAGRAPH: u32 = 1 << 20;
const E_CAPTION: u32 = 1 << 21;
const E_SELECT: u32 = 1 << 22;
const E_OPTION: u32 = 1 << 23;
const E_HEAD_ROWS: u32 = 1 << 24;
/// The element nothing of which is shown that the hiding started at.
const E_HIDES: u32 = 1 << 25;

/// An element that is open.
const Open = struct {
    tag: Tag,
    /// An element of no name of its own: its name's hash, so that its
    /// end tag finds it.
    hash: u32 = 0,
    effects: u32 = 0,
    /// What it put aside to undo: the heading or the link it replaced.
    saved: u32 = 0,
    saved_length: u32 = 0,
};

/// A list item, a quote or a `<dd>`: what a block inside it is indented
/// by, and the mark an item's first block stands behind.
const Container = struct {
    quote: bool,
    mark: u8 = tdc.TDMARK_NONE,
    number: u32 = 0,
    /// The first item of its list.
    start: bool = false,
    /// How many paragraphs were open round it: a `<p>` inside the item
    /// makes its blocks stand apart.
    paragraphs: u32 = 0,
};

const List = struct {
    mark: u8,
    next: u32 = 1,
    items: u32 = 0,
};

const Table = struct {
    /// Drawn as a table; else a page's layout.
    grid: bool,
    /// A row has begun, how many cells it has so far, and how many rows
    /// have ended.
    row_open: bool = false,
    cells_in_row: u32 = 0,
    rows: u32 = 0,
    /// The column the next cell goes in.
    column: u32 = 0,
    /// A cell of it has been written since it began, or since its
    /// caption.
    any_cell: bool = false,
    /// Inside `<thead>`.
    head: u32 = 0,
    /// The first row's first block, and whether its cells are all `<th>`:
    /// then it is the table's head.
    first_row_block: u32 = 0,
    first_row_heads: bool = true,
    head_marked: bool = false,
    /// How many rows below each column is still taken by a cell above,
    /// and which columns are taken in this row.
    spans: [most_columns]u16 = @splat(0),
    spanning: u32 = 0,
};

/// What the text that follows a raw element's start tag is for.
const RawUse = enum { none, drop, title, textarea, verbatim };

const Parser = struct {
    out: *Build,
    reader: tokens.Reader,

    stack: [most_open]Open = undefined,
    depth: usize = 0,

    containers: [most_containers]Container = undefined,
    container_count: usize = 0,
    containers_over: u32 = 0,
    quotes_open: u32 = 0,
    lists: [most_lists]List = undefined,
    list_count: usize = 0,
    lists_over: u32 = 0,
    tables: [most_tables]Table = undefined,
    table_count: usize = 0,

    /// How the text is drawn: how many of each are open.
    bolds: u32 = 0,
    italics: u32 = 0,
    underlines: u32 = 0,
    strikes: u32 = 0,
    codes: u32 = 0,
    fixeds: u32 = 0,
    bigs: u32 = 0,
    smalls: u32 = 0,
    muted: u32 = 0,
    heading: u8 = 0,
    pres: u32 = 0,
    paragraphs: u32 = 0,
    captions: u32 = 0,
    link: struct { offset: u32 = 0, length: u32 = 0 } = .{},
    /// The look worked out from all of that, and whether it has to be
    /// worked out again.
    look_now: tdc.Piece = .{},
    look_dirty: bool = true,

    /// Inside an element nothing of which is shown.
    hiding: bool = false,
    raw_use: RawUse = .none,
    textarea_open: bool = false,
    /// Inside a `<select>`: which option is shown, which one this is,
    /// and whether the text is the shown one's.
    selects: u32 = 0,
    shown_option: u32 = 0,
    option_index: u32 = 0,
    in_shown_option: bool = false,

    /// A block has been begun and not ended, and where everything stood
    /// before it, to go back to when nothing came of it.
    block_open: bool = false,
    block_saved: Build.Saved = undefined,
    /// A cell of a table drawn as one is being written; one has been
    /// written whose end waits to be known - a tab when the next cell
    /// is in its row, a newline when it is not; and a row has begun
    /// since.
    cell_open: bool = false,
    cell_end_pending: bool = false,
    new_row: bool = false,
    /// White space seen, to be one space before the next character, in
    /// the look it was seen in.
    space: bool = false,
    space_look: tdc.Piece = .{},
    /// Just after an opening bracket or quote: white space is not kept.
    glue: bool = false,
    /// Line ends waiting for the next character.
    breaks: u32 = 0,
    /// A listing's column, for its tabs; and whether nothing of it has
    /// been read yet, when a first line end is left off.
    column: usize = 0,
    pre_fresh: bool = false,

    // --- tokens --------------------------------------------------------------

    fn text(p: *Parser, token: tokens.Token) void {
        const use = p.raw_use;
        p.raw_use = .none;
        if (!token.raw) return p.characters(token.text, true);
        switch (use) {
            .title => p.takeTitle(token.text),
            .verbatim => p.characters(token.text, false),
            .textarea => p.characters(token.text, true),
            .drop, .none => {},
        }
    }

    fn start(p: *Parser, token: tokens.Token) void {
        p.raw_use = .none;
        const tag = elements.tagOf(token.text);
        const attributes = token.attributes;
        if (p.hiding) {
            if (p.endsHiding(tag)) |root| {
                p.popTo(root);
            } else {
                // Inside what is not shown only the nesting counts.
                switch (tag) {
                    .script, .style, .title, .textarea, .xmp, .iframe, .noembed, .plaintext => p.raw_use = .drop,
                    else => {},
                }
                if (!elements.isVoid(tag)) p.push(tag, token.text, E_UNSHOWN);
                return;
            }
        }
        switch (tag) {
            .html, .body, .head, .base, .meta, .link, .col, .colgroup, .param, .source, .track, .wbr, .frame, .area, .embed, .keygen => return,
            .script, .style, .iframe, .noembed => {
                p.raw_use = .drop;
                return;
            },
            .title => {
                p.raw_use = .title;
                return;
            },
            .textarea => {
                if (hidden(attributes)) {
                    p.raw_use = .drop;
                    return;
                }
                p.openBracket('[');
                p.textarea_open = true;
                p.raw_use = .textarea;
                return;
            },
            .br => return p.lineBreak(),
            .hr => return p.rule(),
            .img => return p.picture(attributes),
            .input => return p.field(attributes),
            else => {},
        }

        // What its start closes.
        if (elements.closesParagraph(tag)) {
            if (p.find(.p, .button)) |index| p.popTo(index);
        }
        switch (tag) {
            .li => p.closeItem(&.{.li}, &.{ .ul, .ol, .menu, .dir }),
            .dd, .dt => p.closeItem(&.{ .dd, .dt }, &.{.dl}),
            .h1, .h2, .h3, .h4, .h5, .h6 => {
                if (p.depth > 0 and elements.headingLevel(p.stack[p.depth - 1].tag) != 0) p.popTo(p.depth - 1);
            },
            .option => {
                if (p.depth > 0 and p.stack[p.depth - 1].tag == .option) p.popTo(p.depth - 1);
            },
            .optgroup => {
                if (p.depth > 0 and p.stack[p.depth - 1].tag == .option) p.popTo(p.depth - 1);
                if (p.depth > 0 and p.stack[p.depth - 1].tag == .optgroup) p.popTo(p.depth - 1);
            },
            .a, .button, .nobr => {
                if (p.find(tag, .normal)) |index| p.popTo(index);
            },
            .tr => p.closeInTable(&.{ .td, .th, .tr }),
            .td, .th => p.closeInTable(&.{ .td, .th }),
            .thead, .tbody, .tfoot, .caption => p.closeInTable(&.{ .td, .th, .tr, .thead, .tbody, .tfoot, .caption }),
            else => {},
        }
        if (p.depth >= most_open) {
            if (elements.isBlock(tag)) p.boundary();
            return;
        }

        // Nothing of it shown.
        if (hidden(attributes) or elements.isUnshown(tag) or (tag == .dialog and attribute(attributes, "open") == null)) {
            p.push(tag, token.text, E_UNSHOWN | E_HIDES);
            p.hiding = true;
            return;
        }

        // What it changes.
        var effects: u32 = 0;
        if (elements.isBlock(tag)) {
            p.boundary();
            effects |= E_BLOCK;
        }
        const index = p.depth;
        p.push(tag, token.text, effects);
        const open = &p.stack[index];
        switch (tag) {
            .b, .strong => p.style(open, E_BOLD),
            .i, .em, .cite, .dfn, .@"var", .address => p.style(open, E_ITALIC),
            .u, .ins => p.style(open, E_UNDERLINED),
            .s, .strike, .del => p.style(open, E_STRUCK),
            .code, .kbd, .samp => p.style(open, E_CODE),
            .tt => p.style(open, E_FIXED),
            .big => p.style(open, E_BIG),
            .small, .sub, .sup => p.style(open, E_SMALL),
            .q => {
                p.openBracket('"');
                open.effects |= E_QUOTE;
            },
            .button => {
                p.openBracket('[');
                open.effects |= E_BRACKETS;
            },
            .a => if (attribute(attributes, "href")) |href| p.openLink(open, href),
            .h1, .h2, .h3, .h4, .h5, .h6 => {
                open.effects |= E_HEADING;
                open.saved = p.heading;
                p.heading = elements.headingLevel(tag);
                p.look_dirty = true;
            },
            .pre, .listing, .xmp, .plaintext => {
                open.effects |= E_PRE;
                p.pres += 1;
                p.pre_fresh = true;
                p.column = 0;
                p.look_dirty = true;
                if (tag == .xmp or tag == .plaintext) p.raw_use = .verbatim;
            },
            .p => {
                open.effects |= E_PARAGRAPH;
                p.paragraphs += 1;
            },
            .blockquote => p.openContainer(open, .{ .quote = true }),
            .dd => p.openContainer(open, .{ .quote = false }),
            .ul, .menu, .dir => p.openList(open, false, attributes),
            .ol => p.openList(open, true, attributes),
            .li => p.openItem(open, attributes),
            .table => p.openTable(open),
            .thead => {
                if (p.gridTable()) |table| {
                    table.head += 1;
                    open.effects |= E_HEAD_ROWS;
                }
            },
            .tr => p.openRow(open),
            .td, .th => p.openCell(open, tag == .th, attributes),
            .caption => {
                open.effects |= E_CAPTION;
                p.captions += 1;
            },
            .select => p.openSelect(open),
            .option => p.openOption(open),
            else => {},
        }
    }

    fn end(p: *Parser, token: tokens.Token) void {
        p.raw_use = .none;
        const tag = elements.tagOf(token.text);
        if (p.hiding) {
            if (p.findNamed(tag, token.text)) |index| p.popTo(index);
            return;
        }
        switch (tag) {
            .html, .body, .head, .title, .script, .style, .iframe, .noembed => return,
            .textarea => {
                if (p.textarea_open) p.closeBracket(']');
                p.textarea_open = false;
                return;
            },
            .br => return p.lineBreak(),
            .p => {
                if (p.find(.p, .button)) |index| p.popTo(index) else p.boundary();
                return;
            },
            .li => {
                if (p.find(.li, .list_item)) |index| p.popTo(index);
                return;
            },
            .h1, .h2, .h3, .h4, .h5, .h6 => {
                // Any heading's end closes the heading that is open.
                var at = p.depth;
                while (at > 0) : (at -= 1) {
                    const open = p.stack[at - 1].tag;
                    if (elements.headingLevel(open) != 0) return p.popTo(at - 1);
                    if (elements.isScopeEdge(open)) return;
                }
                return;
            },
            .td, .th, .tr, .thead, .tbody, .tfoot, .table, .caption => {
                if (p.find(tag, .table)) |index| p.popTo(index);
                return;
            },
            else => {},
        }
        if (p.findNamed(tag, token.text)) |index| p.popTo(index);
    }

    // --- the open elements ---------------------------------------------------

    const Scope = enum { normal, button, list_item, table };

    /// The open `tag` nearest the top, as far as `scope` lets an end
    /// reach; null when there is none.
    fn find(p: *const Parser, tag: Tag, scope: Scope) ?usize {
        var at = p.depth;
        while (at > 0) : (at -= 1) {
            const open = p.stack[at - 1].tag;
            if (open == tag) return at - 1;
            switch (scope) {
                .table => if (open == .table or open == .html or open == .template) return null,
                .normal => if (elements.isScopeEdge(open)) return null,
                .button => if (elements.isScopeEdge(open) or open == .button) return null,
                .list_item => if (elements.isScopeEdge(open) or open == .ul or open == .ol) return null,
            }
        }
        return null;
    }

    /// `find` for an end tag; an element of no name of its own is found
    /// by its name.
    fn findNamed(p: *const Parser, tag: Tag, name: []const u8) ?usize {
        if (tag != .other) return p.find(tag, .normal);
        const hash = hashOf(name);
        var at = p.depth;
        while (at > 0) : (at -= 1) {
            const open = p.stack[at - 1];
            if (open.tag == .other and open.hash == hash) return at - 1;
            if (elements.isScopeEdge(open.tag)) return null;
        }
        return null;
    }

    /// An open item of `items` closed, unless one of `lists` is nearer.
    fn closeItem(p: *Parser, items: []const Tag, lists: []const Tag) void {
        var at = p.depth;
        while (at > 0) : (at -= 1) {
            const open = p.stack[at - 1].tag;
            for (items) |item| {
                if (open == item) return p.popTo(at - 1);
            }
            for (lists) |list| {
                if (open == list) return;
            }
            if (elements.isScopeEdge(open)) return;
            // Only what has no block of its own, a paragraph or a
            // `<div>` is passed over on the way down to the item.
            if (elements.isBlock(open) and open != .p and open != .div and open != .address) return;
        }
    }

    /// The open elements of `tags` inside the nearest table closed, and
    /// what is inside them.
    fn closeInTable(p: *Parser, tags: []const Tag) void {
        var at = p.depth;
        while (at > 0) : (at -= 1) {
            const open = p.stack[at - 1].tag;
            if (open == .table or open == .html or open == .template) return;
            for (tags) |tag| {
                if (open == tag) {
                    p.popTo(at - 1);
                    break;
                }
            }
        }
    }

    /// The element that started the hiding, when the start of `tag`
    /// closes it as the next of its kind: a hidden item ends at the next
    /// item of its list, a hidden cell at the next cell.
    fn endsHiding(p: *const Parser, tag: Tag) ?usize {
        var root: usize = 0;
        while (root < p.depth and p.stack[root].effects & E_HIDES == 0) root += 1;
        if (root == p.depth) return null;
        const hidden_tag = p.stack[root].tag;
        const closes = switch (tag) {
            .li => hidden_tag == .li,
            .dd, .dt => hidden_tag == .dd or hidden_tag == .dt,
            .option, .optgroup => hidden_tag == .option,
            .tr => hidden_tag == .tr or hidden_tag == .td or hidden_tag == .th,
            .td, .th => hidden_tag == .td or hidden_tag == .th,
            else => hidden_tag == .p and elements.closesParagraph(tag),
        };
        if (!closes) return null;
        // Not when it is inside a list, a table or a field of its own
        // within what is hidden.
        for (p.stack[root + 1 .. p.depth]) |inside| {
            switch (inside.tag) {
                .ul, .ol, .menu, .dir, .dl, .table, .select, .button => return null,
                else => {},
            }
        }
        return root;
    }

    fn push(p: *Parser, tag: Tag, name: []const u8, effects: u32) void {
        if (p.depth >= most_open) return;
        p.stack[p.depth] = .{ .tag = tag, .hash = if (tag == .other) hashOf(name) else 0, .effects = effects };
        p.depth += 1;
    }

    /// The elements from `index` on closed, the top first.
    fn popTo(p: *Parser, index: usize) void {
        while (p.depth > index) {
            p.depth -= 1;
            p.undo(p.stack[p.depth]);
        }
    }

    fn undo(p: *Parser, open: Open) void {
        const effects = open.effects;
        if (effects & E_UNSHOWN != 0) {
            if (effects & E_HIDES != 0) p.hiding = false;
            return;
        }
        if (effects & E_QUOTE != 0) p.closeBracket('"');
        if (effects & E_BRACKETS != 0) p.closeBracket(']');
        if (effects & E_OPTION != 0) p.in_shown_option = false;
        if (effects & E_SELECT != 0) {
            p.selects -= 1;
            p.closeBracket(']');
        }
        if (effects & E_CELL != 0) p.closeCell();
        if (effects & E_ROW != 0) p.closeRow();
        if (effects & E_HEAD_ROWS != 0) {
            if (p.gridTable()) |table| table.head -|= 1;
        }
        if (effects & E_TABLE != 0) p.closeTable();
        if (effects & E_CONTAINER != 0) p.closeContainer(open.tag);
        if (effects & E_LIST != 0) {
            if (p.lists_over > 0) p.lists_over -= 1 else p.list_count -= 1;
        }
        if (effects & (E_BLOCK | E_HEADING | E_PRE | E_PARAGRAPH) != 0) p.boundary();
        if (effects & E_HEADING != 0) p.heading = @intCast(open.saved);
        if (effects & E_PRE != 0) p.pres -= 1;
        if (effects & E_PARAGRAPH != 0) p.paragraphs -= 1;
        if (effects & E_CAPTION != 0) p.captions -= 1;
        if (effects & E_BOLD != 0) p.bolds -= 1;
        if (effects & E_ITALIC != 0) p.italics -= 1;
        if (effects & E_UNDERLINED != 0) p.underlines -= 1;
        if (effects & E_STRUCK != 0) p.strikes -= 1;
        if (effects & E_CODE != 0) p.codes -= 1;
        if (effects & E_FIXED != 0) p.fixeds -= 1;
        if (effects & E_BIG != 0) p.bigs -= 1;
        if (effects & E_SMALL != 0) p.smalls -= 1;
        if (effects & E_LINK != 0) p.link = .{ .offset = open.saved, .length = open.saved_length };
        p.look_dirty = true;
    }

    fn style(p: *Parser, open: *Open, effect: u32) void {
        open.effects |= effect;
        switch (effect) {
            E_BOLD => p.bolds += 1,
            E_ITALIC => p.italics += 1,
            E_UNDERLINED => p.underlines += 1,
            E_STRUCK => p.strikes += 1,
            E_CODE => p.codes += 1,
            E_FIXED => p.fixeds += 1,
            E_BIG => p.bigs += 1,
            E_SMALL => p.smalls += 1,
            else => {},
        }
        p.look_dirty = true;
    }

    fn openLink(p: *Parser, open: *Open, href: []const u8) void {
        open.effects |= E_LINK;
        open.saved = p.link.offset;
        open.saved_length = p.link.length;
        const out = p.out;
        const offset = out.link_base + out.link_len;
        var first: usize = 0;
        var last = href.len;
        while (first < last and tokens.isSpace(href[first])) first += 1;
        while (last > first and tokens.isSpace(href[last - 1])) last -= 1;
        const target = href[first..last];
        var at: usize = 0;
        while (at < target.len) {
            const char = target[at];
            if (char == '&') {
                if (entities.reference(target, at, true)) |found| {
                    p.targetCode(found.code);
                    at = found.end;
                    continue;
                }
            }
            at += 1;
            if (char == '\t' or char == '\n' or char == '\r') continue;
            p.targetCode(char);
        }
        p.link = .{ .offset = offset, .length = out.link_base + out.link_len - offset };
        p.look_dirty = true;
    }

    /// A character of a link's target: ASCII as it is, a space and what
    /// is past ASCII as UTF-8's bytes, each `%` and two hex digits.
    fn targetCode(p: *Parser, value: u32) void {
        if (value > ' ' and value < 0x7F) return p.out.putTarget(@intCast(value));
        const hex = "0123456789ABCDEF";
        var utf8: [4]u8 = undefined;
        for (utf8Of(value, &utf8)) |byte_of| {
            p.out.putTarget('%');
            p.out.putTarget(hex[byte_of >> 4]);
            p.out.putTarget(hex[byte_of & 15]);
        }
    }

    // --- lists and quotes ----------------------------------------------------

    fn openContainer(p: *Parser, open: *Open, container: Container) void {
        open.effects |= E_CONTAINER;
        if (container.quote) p.quotes_open += 1;
        if (p.inGridCell() or p.container_count >= most_containers) {
            p.containers_over += 1;
            return;
        }
        p.emptyItem();
        var made = container;
        made.paragraphs = p.paragraphs;
        p.containers[p.container_count] = made;
        p.container_count += 1;
    }

    fn closeContainer(p: *Parser, tag: Tag) void {
        if (tag == .blockquote) p.quotes_open -|= 1;
        p.boundary();
        if (p.containers_over > 0) {
            p.containers_over -= 1;
            return;
        }
        if (p.container_count == 0) return;
        p.emptyItem();
        p.container_count -= 1;
    }

    /// The item that is innermost, when nothing of it has been written:
    /// a block of nothing behind its mark, before a list, a quote or a
    /// table inside it begins, or before it ends.
    fn emptyItem(p: *Parser) void {
        if (p.container_count == 0) return;
        const top = p.containers[p.container_count - 1];
        if (top.quote or top.mark == tdc.TDMARK_NONE) return;
        if (!p.visible() or p.inGridCell()) return;
        if (p.cell_end_pending) p.finishCell('\n');
        p.out.begin(p.blockOf(tdc.TDBLOCK_PARAGRAPH));
        p.out.end('\n');
    }

    fn openList(p: *Parser, open: *Open, ordered: bool, attributes: []const u8) void {
        open.effects |= E_LIST;
        p.emptyItem();
        if (p.list_count >= most_lists) {
            p.lists_over += 1;
            return;
        }
        const outside = p.list_count;
        var list = List{
            .mark = if (ordered) tdc.TDMARK_NUMBER else if (outside == 0) tdc.TDMARK_DISC else if (outside == 1) tdc.TDMARK_CIRCLE else tdc.TDMARK_SQUARE,
        };
        if (attribute(attributes, "type")) |kind| {
            if (kind.len == 1) {
                list.mark = switch (kind[0]) {
                    'a', 'A' => tdc.TDMARK_LETTER,
                    'i', 'I' => tdc.TDMARK_ROMAN,
                    '1' => tdc.TDMARK_NUMBER,
                    else => list.mark,
                };
            } else if (elements.sameName(kind, "disc")) {
                list.mark = tdc.TDMARK_DISC;
            } else if (elements.sameName(kind, "circle")) {
                list.mark = tdc.TDMARK_CIRCLE;
            } else if (elements.sameName(kind, "square")) {
                list.mark = tdc.TDMARK_SQUARE;
            }
        }
        if (ordered) {
            if (attribute(attributes, "start")) |first| list.next = numberOf(first) orelse 1;
        }
        p.lists[p.list_count] = list;
        p.list_count += 1;
    }

    fn openItem(p: *Parser, open: *Open, attributes: []const u8) void {
        var mark: u8 = tdc.TDMARK_DISC;
        var number: u32 = 0;
        var first = true;
        if (p.list_count > 0 and p.lists_over == 0) {
            const list = &p.lists[p.list_count - 1];
            mark = list.mark;
            if (attribute(attributes, "value")) |value| {
                if (numberOf(value)) |given| list.next = given;
            }
            number = list.next;
            list.next +%= 1;
            first = list.items == 0;
            list.items += 1;
        }
        if (p.inGridCell()) {
            // Inside a cell an item is a line of its own behind its mark.
            p.boundary();
            if (mark == tdc.TDMARK_NUMBER or mark == tdc.TDMARK_LETTER or mark == tdc.TDMARK_ROMAN) {
                var digits: [10]u8 = undefined;
                for (decimal(number, &digits)) |digit| p.ink(digit);
                p.ink('.');
            } else {
                p.ink(0xB7);
            }
            p.whiteSpace();
            open.effects |= E_CONTAINER;
            p.containers_over += 1;
            return;
        }
        p.openContainer(open, .{ .quote = false, .mark = mark, .number = number, .start = first });
    }

    // --- tables --------------------------------------------------------------

    fn openTable(p: *Parser, open: *Open) void {
        if (p.table_count >= most_tables) return;
        open.effects |= E_TABLE;
        p.emptyItem();
        const grid = !p.inGridCell() and gridAhead(p.reader);
        p.tables[p.table_count] = .{ .grid = grid };
        p.table_count += 1;
    }

    fn closeTable(p: *Parser) void {
        if (p.table_count == 0) return;
        const table = &p.tables[p.table_count - 1];
        if (table.grid) {
            p.closeCell();
            p.endRow(table);
            p.finishTableHead(table);
            if (p.cell_end_pending) p.finishCell('\n');
        }
        p.table_count -= 1;
    }

    /// The innermost table, when it is drawn as one.
    fn gridTable(p: *Parser) ?*Table {
        if (p.table_count == 0) return null;
        const table = &p.tables[p.table_count - 1];
        return if (table.grid) table else null;
    }

    fn inGridCell(p: *Parser) bool {
        return p.cell_open and p.gridTable() != null;
    }

    fn openRow(p: *Parser, open: *Open) void {
        open.effects |= E_ROW;
        const table = p.gridTable() orelse return;
        p.startRow(table);
    }

    fn startRow(p: *Parser, table: *Table) void {
        p.closeCell();
        p.endRow(table);
        if (table.rows == 1) p.finishTableHead(table);
        table.row_open = true;
        table.cells_in_row = 0;
        table.column = 0;
        table.spanning = 0;
        for (table.spans, 0..) |left, column| {
            if (left > 0) table.spanning |= @as(u32, 1) << @intCast(column);
        }
        p.new_row = true;
    }

    fn endRow(_: *Parser, table: *Table) void {
        if (!table.row_open) return;
        table.row_open = false;
        table.rows += 1;
        for (&table.spans, 0..) |*left, column| {
            if (table.spanning & (@as(u32, 1) << @intCast(column)) != 0) left.* -|= 1;
        }
    }

    fn closeRow(p: *Parser) void {
        const table = p.gridTable() orelse return;
        p.closeCell();
        p.endRow(table);
    }

    /// The first row marked the table's head when its cells are all
    /// `<th>`; called once it has ended.
    fn finishTableHead(p: *Parser, table: *Table) void {
        if (table.rows != 1 or !table.first_row_heads or table.head_marked or !table.any_cell) return;
        table.head_marked = true;
        var index = table.first_row_block;
        while (index < p.out.block_count) : (index += 1) p.out.flag(index, tdc.TDBF_HEAD);
        // Its last cell, whose end is still to come.
        if (p.cell_end_pending) p.out.block.flags |= tdc.TDBF_HEAD;
    }

    fn openCell(p: *Parser, open: *Open, head: bool, attributes: []const u8) void {
        // A cell of a table that lays a page out is a block, as its
        // start made it.
        const table = p.gridTable() orelse return;
        open.effects |= E_CELL;
        if (!table.row_open) p.startRow(table);
        p.closeCell();
        // Its column: past those a cell above still takes.
        var column = table.column;
        while (column < most_columns - 1 and table.spanning & (@as(u32, 1) << @intCast(column)) != 0) column += 1;
        const across: u32 = @max(1, @min(numberOf(attribute(attributes, "colspan") orelse "1") orelse 1, most_columns));
        const down: u32 = @min(numberOf(attribute(attributes, "rowspan") orelse "1") orelse 1, 1000);
        if (down > 1) {
            var taken = column;
            while (taken < @min(column + across, most_columns)) : (taken += 1) table.spans[taken] = @intCast(down - 1);
        }
        table.column = @min(column + across, most_columns - 1);

        p.resolveCell();
        p.new_row = false;
        var block = p.blockOf(tdc.TDBLOCK_CELL);
        block.number = column;
        block.span = @intCast(@min(across, most_columns - column));
        if (table.cells_in_row == 0) block.flags |= tdc.TDBF_ROW;
        if (!table.any_cell) {
            block.flags |= tdc.TDBF_TABLE;
            table.first_row_block = p.out.block_count;
        }
        if (table.head > 0) block.flags |= tdc.TDBF_HEAD;
        if (table.rows == 0 and !head) table.first_row_heads = false;
        if (attribute(attributes, "align")) |alignment| {
            if (elements.sameName(alignment, "center") or elements.sameName(alignment, "middle")) block.alignment = tdc.TDALIGN_CENTRE;
            if (elements.sameName(alignment, "right")) block.alignment = tdc.TDALIGN_RIGHT;
        }
        table.any_cell = true;
        table.cells_in_row += 1;
        p.out.begin(block);
        p.block_open = true;
        p.cell_open = true;
        p.space = false;
        p.breaks = 0;
        p.glue = false;
        p.look_dirty = true;
        if (head) p.style(open, E_BOLD);
    }

    /// The cell being written left waiting for its end.
    fn closeCell(p: *Parser) void {
        if (!p.cell_open) return;
        p.cell_open = false;
        p.cell_end_pending = true;
        p.space = false;
        p.breaks = 0;
    }

    /// The cell that waits for its end ended: a tab when the next one is
    /// in its row, a newline when it is not.
    fn resolveCell(p: *Parser) void {
        if (!p.cell_end_pending) return;
        p.finishCell(if (p.new_row) '\n' else '\t');
    }

    fn finishCell(p: *Parser, terminator: u8) void {
        p.cell_end_pending = false;
        p.out.end(terminator);
        p.block_open = false;
    }

    // --- forms ---------------------------------------------------------------

    fn openSelect(p: *Parser, open: *Open) void {
        open.effects |= E_SELECT;
        p.openBracket('[');
        p.selects += 1;
        p.shown_option = shownAhead(p.reader);
        p.option_index = 0;
        p.in_shown_option = false;
    }

    fn openOption(p: *Parser, open: *Open) void {
        if (p.selects == 0) return;
        open.effects |= E_OPTION;
        p.in_shown_option = p.option_index == p.shown_option;
        p.option_index += 1;
    }

    /// An `<input>` as its label in brackets: a button's, a field's own
    /// value or what it asks for, a box ticked or not.
    fn field(p: *Parser, attributes: []const u8) void {
        if (hidden(attributes)) return;
        const kind = attribute(attributes, "type") orelse "text";
        const value = attribute(attributes, "value");
        if (elements.sameName(kind, "hidden")) return;
        if (elements.sameName(kind, "checkbox")) return p.inkAll(if (attribute(attributes, "checked") != null) "[x]" else "[ ]");
        if (elements.sameName(kind, "radio")) return p.inkAll(if (attribute(attributes, "checked") != null) "(*)" else "( )");
        p.openBracket('[');
        if (elements.sameName(kind, "submit") or elements.sameName(kind, "button") or elements.sameName(kind, "reset")) {
            const label = value orelse (if (elements.sameName(kind, "reset")) "Reset" else "Submit");
            p.characters(label, true);
        } else if (elements.sameName(kind, "image")) {
            p.characters(attribute(attributes, "alt") orelse "Submit", true);
        } else if (elements.sameName(kind, "password")) {
            const given = value orelse "";
            if (given.len == 0) p.inkAll("________") else for (given) |_| p.ink('*');
        } else if (value != null and value.?.len > 0) {
            p.characters(value.?, true);
        } else if (attribute(attributes, "placeholder")) |asks| {
            p.muted += 1;
            p.look_dirty = true;
            p.characters(asks, true);
            p.muted -= 1;
            p.look_dirty = true;
        } else {
            p.inkAll("________");
        }
        p.closeBracket(']');
    }

    // --- what a block is -----------------------------------------------------

    /// A block of `kind` where the lists and quotes are now: behind the
    /// mark of the item it is the first block of, if it is.
    fn blockOf(p: *Parser, kind: u8) tdc.Block {
        var block = tdc.Block{ .kind = kind, .depth = @intCast(p.container_count) };
        for (p.containers[0..p.container_count], 0..) |container, index| {
            if (container.quote) block.quotes |= @as(u8, 1) << @intCast(index);
        }
        if (p.container_count > 0 and !p.containers[p.container_count - 1].quote) {
            const item = &p.containers[p.container_count - 1];
            block.mark = item.mark;
            block.number = item.number;
            if (item.start and item.mark != tdc.TDMARK_NONE) block.flags |= tdc.TDBF_START;
            if (p.paragraphs > item.paragraphs) block.flags |= tdc.TDBF_LOOSE;
        }
        if (kind == tdc.TDBLOCK_HEADING) block.level = p.heading;
        // A mark stands in front of the first block of its item only.
        for (p.containers[0..p.container_count]) |*container| {
            container.mark = tdc.TDMARK_NONE;
            container.start = false;
        }
        return block;
    }

    /// The block that is open ended: kept when anything is in it, or
    /// when it shows an item's mark, and taken back when not.
    fn boundary(p: *Parser) void {
        if (p.hiding) return;
        p.space = false;
        p.glue = false;
        if (p.inGridCell()) {
            // Inside a cell drawn as a table a block is a line.
            if (p.out.inked) p.breaks = @max(p.breaks, 1);
            return;
        }
        p.breaks = 0;
        if (!p.block_open or p.cell_end_pending) return;
        p.block_open = false;
        if (!p.out.inked and p.out.block.mark == tdc.TDMARK_NONE) {
            p.out.restore(p.block_saved);
            return;
        }
        p.out.end('\n');
    }

    /// A block begun for what is about to be written, if none is.
    fn ensureBlock(p: *Parser) void {
        if (p.block_open and !p.cell_end_pending) return;
        if (p.cell_end_pending) p.finishCell('\n');
        // A table's caption: the cells after it are a table again.
        if (p.gridTable()) |table| table.any_cell = false;
        const kind = if (p.pres > 0) tdc.TDBLOCK_LISTING else if (p.heading > 0) tdc.TDBLOCK_HEADING else tdc.TDBLOCK_PARAGRAPH;
        p.block_saved = p.out.save();
        p.out.begin(p.blockOf(kind));
        p.block_open = true;
        p.column = 0;
    }

    /// How the text from here on is drawn.
    fn currentLook(p: *Parser) tdc.Piece {
        if (p.look_dirty) {
            p.look_now = p.lookOf();
            p.look_dirty = false;
        }
        return p.look_now;
    }

    fn lookOf(p: *const Parser) tdc.Piece {
        var piece = tdc.Piece{};
        if (p.heading > 0) {
            piece.font = switch (p.heading) {
                1 => tdc.TDFONT_LARGER,
                2 => tdc.TDFONT_LARGE,
                3 => tdc.TDFONT_BIG,
                4 => tdc.TDFONT_NORMAL,
                else => tdc.TDFONT_SMALL,
            };
            piece.style |= bold;
        } else if (p.bigs > 0) {
            piece.font = tdc.TDFONT_BIG;
        } else if (p.smalls > 0) {
            piece.font = tdc.TDFONT_SMALL;
        }
        if (p.pres > 0 or p.fixeds > 0) piece.font = tdc.TDFONT_FIXED;
        if (p.codes > 0) {
            piece.font = tdc.TDFONT_FIXED;
            if (p.pres == 0) piece.style |= tdc.TDSTYLE_CODE;
        }
        if (p.bolds > 0) piece.style |= bold;
        if (p.italics > 0) piece.style |= italic;
        if (p.underlines > 0) piece.style |= underlined;
        if (p.strikes > 0) piece.style |= tdc.TDSTYLE_STRUCK;
        if (p.muted > 0 or p.quotes_open > 0 or p.heading == 6) piece.pen = tdc.TDPEN_MUTED;
        if (p.link.length > 0) {
            piece.pen = tdc.TDPEN_LINK;
            piece.style |= underlined;
            piece.link_offset = p.link.offset;
            piece.link_length = p.link.length;
        }
        return piece;
    }

    /// A character in a run drawn as `look`: the open one when it is
    /// drawn so, a new one when not.
    fn putIn(p: *Parser, look: tdc.Piece, char: u8) void {
        const out = p.out;
        if (!out.open or !sameLook(out.current, look)) out.wear(look);
        out.put(char);
    }

    // --- characters ----------------------------------------------------------

    /// Whether what is read now is shown at all.
    fn visible(p: *Parser) bool {
        if (p.hiding) return false;
        if (p.selects > 0 and !p.in_shown_option) return false;
        if (p.gridTable() != null and !p.cell_open and p.captions == 0) return false;
        return true;
    }

    /// Text read: its white space made single spaces outside a listing,
    /// its character references read when `references`.
    fn characters(p: *Parser, bytes: []const u8, references: bool) void {
        var at: usize = 0;
        while (at < bytes.len) {
            const char = bytes[at];
            if (char == '&' and references) {
                if (entities.reference(bytes, at, false)) |found| {
                    p.code(found.code);
                    at = found.end;
                    continue;
                }
            }
            at += 1;
            if (p.pres > 0) {
                p.listingChar(char, if (at < bytes.len) bytes[at] else 0);
            } else if (tokens.isSpace(char)) {
                p.whiteSpace();
            } else {
                p.byte(char);
            }
        }
    }

    /// A character of a listing as it stands: its line ends kept, a tab
    /// to the next multiple of eight.
    fn listingChar(p: *Parser, char: u8, next: u8) void {
        switch (char) {
            '\r' => if (next != '\n') p.listingBreak(),
            '\n' => p.listingBreak(),
            '\t' => {
                const to = (p.column / 8 + 1) * 8;
                while (p.column < to) p.listingSpace();
            },
            ' ', 0x0C => p.listingSpace(),
            else => p.byte(char),
        }
    }

    fn listingBreak(p: *Parser) void {
        if (!p.visible()) return;
        if (p.pre_fresh) {
            p.pre_fresh = false;
            return;
        }
        p.ensureBlock();
        p.breaks += 1;
    }

    fn listingSpace(p: *Parser) void {
        if (!p.visible()) return;
        p.pre_fresh = false;
        p.ensureBlock();
        const look = p.currentLook();
        p.flushBreaks(look);
        p.putIn(look, ' ');
        p.column += 1;
    }

    /// A byte of the Latin-1 text: one of code page 1252's that Latin-1
    /// has as a control as what it stands for, any other control as
    /// nothing.
    fn byte(p: *Parser, char: u8) void {
        if (char >= 0x80 and char <= 0x9F) return p.code(entities.fromCp1252(char));
        if (char < 0x20 or char == 0x7F) return;
        p.ink(char);
    }

    /// A character by its number: Latin-1's as it is, any other as
    /// utility.library writes it.
    fn code(p: *Parser, value: u32) void {
        if (value == 0) return;
        var near: [8]u8 = undefined;
        for (p.nearest(value, &near)) |char| {
            if (char == ' ') {
                if (p.pres > 0) p.listingSpace() else p.whiteSpace();
            } else if (char >= 0x20 and !(char >= 0x7F and char < 0xA0)) {
                p.ink(char);
            }
        }
    }

    /// What a character is written as in Latin-1: itself, typesetting's
    /// plain characters for it, or `?`.
    fn nearest(p: *Parser, value: u32, into: *[8]u8) []const u8 {
        if (value < 0x100) {
            into[0] = @intCast(value);
            return into[0..1];
        }
        var utf8: [4]u8 = undefined;
        const bytes = utf8Of(value, &utf8);
        var conversion: utility.Utf8Conversion = .{ .flags = utility.UTF8F_TYPESET };
        const written = p.out.ub.Utf8ToLatin1(&conversion, bytes.ptr, bytes.len, into, into.len);
        return into[0..@min(written, into.len)];
    }

    /// White space outside a listing: one space before the next
    /// character, when one came before it in the block.
    fn whiteSpace(p: *Parser) void {
        if (!p.visible()) return;
        if (!p.block_open or p.cell_end_pending or !p.out.inked) return;
        if (p.breaks > 0 or p.space or p.glue) return;
        p.space = true;
        p.space_look = p.currentLook();
    }

    /// `<br>`: the line ended, before the next character.
    fn lineBreak(p: *Parser) void {
        if (!p.visible()) return;
        if (p.pres > 0) return p.listingBreak();
        if (!p.block_open or p.cell_end_pending or !p.out.inked) return;
        p.breaks += 1;
        p.space = false;
    }

    fn flushBreaks(p: *Parser, look: tdc.Piece) void {
        if (p.breaks == 0) return;
        while (p.breaks > 0) : (p.breaks -= 1) p.putIn(look, '\n');
        p.column = 0;
        p.space = false;
    }

    /// A character that shows.
    fn ink(p: *Parser, char: u8) void {
        if (!p.visible()) return;
        p.pre_fresh = false;
        p.ensureBlock();
        const look = p.currentLook();
        if (p.breaks > 0) {
            p.flushBreaks(look);
        } else if (p.space) {
            p.putIn(p.space_look, ' ');
            p.column += 1;
        }
        p.space = false;
        p.glue = false;
        p.putIn(look, char);
        p.out.inked = true;
        p.column += 1;
    }

    fn inkAll(p: *Parser, chars: []const u8) void {
        for (chars) |char| p.ink(char);
    }

    /// An opening bracket or quote, with no space kept after it.
    fn openBracket(p: *Parser, char: u8) void {
        p.ink(char);
        if (p.visible()) p.glue = true;
    }

    /// A closing one, with no space kept before it.
    fn closeBracket(p: *Parser, char: u8) void {
        p.space = false;
        p.ink(char);
    }

    // --- elements with nothing in them ---------------------------------------

    fn rule(p: *Parser) void {
        if (p.find(.p, .button)) |index| p.popTo(index);
        if (!p.visible()) return;
        p.boundary();
        // Inside a cell a rule is a line's end.
        if (p.inGridCell()) return;
        p.emptyItem();
        if (p.cell_end_pending) p.finishCell('\n');
        p.out.begin(p.blockOf(tdc.TDBLOCK_RULE));
        p.out.end('\n');
    }

    /// `<img>`: what its `alt` says it is, set back in italic.
    fn picture(p: *Parser, attributes: []const u8) void {
        const alt = attribute(attributes, "alt") orelse return;
        if (hidden(attributes)) return;
        p.muted += 1;
        p.italics += 1;
        p.look_dirty = true;
        p.characters(alt, true);
        p.muted -= 1;
        p.italics -= 1;
        p.look_dirty = true;
    }

    /// The `<title>`'s text kept, the first one's only.
    fn takeTitle(p: *Parser, bytes: []const u8) void {
        const out = p.out;
        if (out.title_len > 0) return;
        var space = false;
        var at: usize = 0;
        while (at < bytes.len) {
            var near: [8]u8 = undefined;
            var some: []const u8 = bytes[at .. at + 1];
            if (bytes[at] == '&') {
                if (entities.reference(bytes, at, false)) |found| {
                    some = p.nearest(found.code, &near);
                    at = found.end;
                } else at += 1;
            } else {
                if (bytes[at] >= 0x80 and bytes[at] <= 0x9F) some = p.nearest(entities.fromCp1252(bytes[at]), &near);
                at += 1;
            }
            for (some) |char| {
                if (tokens.isSpace(char)) {
                    space = out.title_len > 0;
                    continue;
                }
                if (char < 0x20 or (char >= 0x7F and char < 0xA0)) continue;
                const room: usize = if (space) 2 else 1;
                if (out.title_len + room > title_most) {
                    out.title[out.title_len] = 0;
                    return;
                }
                if (space) {
                    out.title[out.title_len] = ' ';
                    out.title_len += 1;
                    space = false;
                }
                out.title[out.title_len] = char;
                out.title_len += 1;
            }
        }
        out.title[out.title_len] = 0;
    }
};

fn sameLook(a: tdc.Piece, b: tdc.Piece) bool {
    return a.font == b.font and a.indent == b.indent and a.style == b.style and a.pen == b.pen and
        a.link_offset == b.link_offset and a.link_length == b.link_length;
}

/// A character's UTF-8, into `into`.
fn utf8Of(value: u32, into: *[4]u8) []const u8 {
    if (value < 0x80) {
        into[0] = @intCast(value);
        return into[0..1];
    }
    if (value < 0x800) {
        into[0] = @intCast(0xC0 | value >> 6);
        into[1] = @intCast(0x80 | (value & 0x3F));
        return into[0..2];
    }
    if (value < 0x1_0000) {
        into[0] = @intCast(0xE0 | value >> 12);
        into[1] = @intCast(0x80 | (value >> 6 & 0x3F));
        into[2] = @intCast(0x80 | (value & 0x3F));
        return into[0..3];
    }
    into[0] = @intCast(0xF0 | value >> 18);
    into[1] = @intCast(0x80 | (value >> 12 & 0x3F));
    into[2] = @intCast(0x80 | (value >> 6 & 0x3F));
    into[3] = @intCast(0x80 | (value & 0x3F));
    return into[0..4];
}

/// Whether an element is marked as not shown: `hidden`, `aria-hidden`,
/// or a style that hides it.
fn hidden(attributes: []const u8) bool {
    if (attributes.len == 0) return false;
    if (attribute(attributes, "hidden") != null) return true;
    if (attribute(attributes, "aria-hidden")) |value| {
        if (elements.sameName(value, "true")) return true;
    }
    const style_text = attribute(attributes, "style") orelse return false;
    return hasProperty(style_text, "display", "none") or hasProperty(style_text, "visibility", "hidden");
}

/// Whether a style says `name: value`, its spaces and case aside.
fn hasProperty(style_text: []const u8, name: []const u8, value: []const u8) bool {
    var at: usize = 0;
    while (at + name.len <= style_text.len) : (at += 1) {
        if (!elements.sameName(style_text[at..][0..name.len], name)) continue;
        if (at > 0 and (tokens.isLetter(style_text[at - 1]) or style_text[at - 1] == '-')) continue;
        var after = at + name.len;
        while (after < style_text.len and tokens.isSpace(style_text[after])) after += 1;
        if (after >= style_text.len or style_text[after] != ':') continue;
        after += 1;
        while (after < style_text.len and tokens.isSpace(style_text[after])) after += 1;
        if (after + value.len > style_text.len) continue;
        if (!elements.sameName(style_text[after..][0..value.len], value)) continue;
        const past = after + value.len;
        if (past == style_text.len or !tokens.isLetter(style_text[past])) return true;
    }
    return false;
}

/// Whether the table whose start tag was just read is drawn as one: a
/// row of it with two cells or more, and no table inside it.
fn gridAhead(from: tokens.Reader) bool {
    var reader = from;
    var cells: u32 = 0;
    var columns = false;
    while (true) {
        const token = reader.next();
        switch (token.kind) {
            .done => return columns,
            .start => switch (elements.tagOf(token.text)) {
                .table => return false,
                .tr => cells = 0,
                .td, .th => {
                    cells += 1;
                    if (cells >= 2) columns = true;
                },
                else => {},
            },
            .end => if (elements.tagOf(token.text) == .table) return columns,
            else => {},
        }
    }
}

/// Which option of the `<select>` whose start tag was just read is
/// shown: the one marked `selected`, or the first.
fn shownAhead(from: tokens.Reader) u32 {
    var reader = from;
    var index: u32 = 0;
    while (true) {
        const token = reader.next();
        switch (token.kind) {
            .done => return 0,
            .start => switch (elements.tagOf(token.text)) {
                .option => {
                    if (attribute(token.attributes, "selected") != null) return index;
                    index += 1;
                },
                .select => return 0,
                else => {},
            },
            .end => if (elements.tagOf(token.text) == .select) return 0,
            else => {},
        }
    }
}

/// A whole number written in decimal, spaces before it allowed.
fn numberOf(text: []const u8) ?u32 {
    var at: usize = 0;
    while (at < text.len and tokens.isSpace(text[at])) at += 1;
    const digits_at = at;
    var value: u32 = 0;
    while (at < text.len and text[at] >= '0' and text[at] <= '9') : (at += 1) {
        value = value *| 10 +| (text[at] - '0');
    }
    if (at == digits_at) return null;
    return value;
}

fn decimal(value: u32, into: *[10]u8) []const u8 {
    var left = value;
    var at: usize = into.len;
    while (true) {
        at -= 1;
        into[at] = @intCast('0' + left % 10);
        left /= 10;
        if (left == 0) break;
    }
    return into[at..];
}

/// An element's name, its case aside, as a number to tell it by.
fn hashOf(name: []const u8) u32 {
    var hash: u32 = 0x811C_9DC5;
    for (name) |char| {
        const folded = if (char >= 'A' and char <= 'Z') char + 32 else char;
        hash = (hash ^ folded) *% 0x0100_0193;
    }
    return hash;
}
