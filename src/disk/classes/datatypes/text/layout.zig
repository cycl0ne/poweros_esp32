// SPDX-License-Identifier: MIT
//! The text laid out for the room the object was given.
//!
//! A document's blocks stand one under another, each its runs broken
//! into lines that fit between its edges, with what is drawn round them
//! kept as decorations: an item's mark, a quote's bar, a listing's
//! ground, a rule, a table's lines. What comes out is a flat list of
//! fragments - a stretch of one run, with the place and the width it was
//! measured at - a list of lines that index into it, and the
//! decorations.
//!
//! **The spaces are GitHub's**, measured in the normal font's em: a
//! paragraph has one under it, a heading one and a half above, a list two
//! in front of each level, a quote a bar and one, a listing one round its
//! lines, a table's cells three eighths above and below and four fifths
//! beside; a list not inside another one stands a paragraph's space from
//! what is before it. Two spaces that meet between blocks are the larger
//! of the two, not both. A line in prose is a third as tall again as its
//! letters, and a little less in headings and listings.
//!
//! **A line is broken at a space, wherever the runs change.** A word is
//! everything between two spaces, however many runs it is drawn in - a
//! word half in bold is one word - and only a word longer than the whole
//! line is broken inside, where it reaches the edge.
//!
//! **A line is as tall as the tallest run in it.** A heading in a larger
//! font pushes its own line down and leaves the lines round it alone,
//! and the letters of runs of different heights stand on one baseline.
//!
//! **A table's columns are as wide as their widest cells**, narrowed in
//! proportion when the table would not fit, a column never narrower than
//! its longest word; a cell's lines are wrapped to its column, and a
//! row is as tall as its tallest cell.
//!
//! Text without blocks is lines as they stand, wrapped when the object
//! wraps, one step of indent for each of a line's first run's `indent`.
//!
//! Laying out happens on the layout process, so it may take as long as
//! it takes.

const std = @import("std");
const sdk = @import("sdk");
const gadgets = sdk.gadgets;
const datatypes = sdk.datatypes;
const tdc = datatypes.textclass;
const _text = @import("_text.zig");
const Data = _text.Data;
const Line = _text.Line;
const Fragment = _text.Fragment;
const Deco = _text.Deco;
const Base = gadgets.Base;

/// What every space on the page is measured in: an em of the normal
/// font, which is a little less than its height.
const Metrics = struct {
    em: i32,

    fn of(own: *const Data) Metrics {
        return .{ .em = @max(@divTrunc(_text.rowsOf(own) * 7 + 4, 8), 4) };
    }

    /// `num`/`den` of an em, at least one pixel when it is anything.
    fn part(m: Metrics, num: i32, den: i32) i32 {
        if (num == 0) return 0;
        return @max(@divTrunc(m.em * num + @divTrunc(den, 2), den), 1);
    }

    /// Round the page.
    fn page(m: Metrics) i32 {
        return m.part(3, 2);
    }
};

/// How tall a line is for how tall its letters are, in sixteenths.
const Tall = enum {
    /// Text without blocks: its letters and one row.
    plain,
    prose,
    heading,
    listing,

    fn of(t: Tall, letters: i32) i32 {
        return switch (t) {
            .plain => letters + 1,
            .prose => @divTrunc(letters * 21 + 8, 16),
            .heading => @divTrunc(letters * 18 + 8, 16),
            .listing => @divTrunc(letters * 20 + 8, 16),
        };
    }
};

/// A stretch of runs to be laid out between two edges.
const Flow = struct {
    first: u32,
    count: u32,
    left: i32,
    /// No edge when it is not past `left`.
    right: i32,
    wrap: bool,
    tall: Tall,
    alignment: u8 = tdc.TDALIGN_LEFT,
    /// Spaces stand as they are, at the start of a line too; a line
    /// starts as far in as its first run's indent says.
    plain: bool = false,
    /// Lines and fragments are only measured, not kept.
    dry: bool = false,
};

/// What a flow came to.
const Flowed = struct {
    /// How far down it ended.
    bottom: i32 = 0,
    /// Its widest line's right edge, and its widest word.
    right: i32 = 0,
    word: i32 = 0,
    /// Its first line, and how many it made.
    first_line: u32 = 0,
    lines: u32 = 0,
};

/// One line being built.
const Building = struct {
    first: u32,
    x: i32,
    /// Something is on it.
    used: bool = false,
    /// It began where the one before it was wrapped: spaces at its start
    /// are not drawn.
    wrapped: bool = false,
};

/// The page being laid out.
const Page = struct {
    base: *Base,
    own: *Data,
    m: Metrics,
    /// The room across; nothing limits a line when it is 0 or less.
    room: i32,
    /// Where the next block may start, and the space the last one wants
    /// under it.
    y: i32,
    below: i32 = 0,
    widest: i32 = 0,
    ok: bool = true,
    /// A quote's bar at each depth, while its blocks go on.
    bars: [8]Bar = @splat(.{}),
};

const Bar = struct {
    open: bool = false,
    x: i32 = 0,
    top: i32 = 0,
    bottom: i32 = 0,
};

/// The whole text laid out for a box `room` pixels wide. False when
/// there was no memory for it.
///
/// `room` of 0 or less lays every line out at its full length, which is
/// what a text that does not wrap gets and what says how wide the
/// widest line is.
pub fn layOut(base: *Base, own: *Data, room: i32) bool {
    own.line_count = 0;
    own.fragment_count = 0;
    own.deco_count = 0;
    own.widest = 0;
    own.total = 0;
    own.laid_for = room;
    if (own.pieces == null or own.buffer == null) return true;
    const m = Metrics.of(own);
    var page = Page{ .base = base, .own = own, .m = m, .room = room, .y = 0 };
    const blocks = own.blocks orelse {
        // Lines as they stand, a little way in from the edge.
        const edge = m.part(1, 2);
        page.y = edge;
        const got = flow(&page, .{
            .first = 0,
            .count = own.piece_count,
            .left = edge,
            .right = if (room > 0) room - edge else 0,
            .wrap = own.wrap != 0,
            .tall = .plain,
            .plain = true,
        });
        own.widest = got.right + edge;
        own.total = got.bottom + edge;
        return page.ok;
    };

    page.y = m.page();
    var first = true;
    var previous: ?*const tdc.Block = null;
    var b: u32 = 0;
    while (b < own.block_count and page.ok) {
        const block = &blocks[b];
        closeBars(&page, block);
        var gap = @max(page.below, spaceAbove(m, block));
        if (previous) |was| gap = @max(gap, spaceLeaving(m, was, block));
        if (first) gap = 0;
        first = false;
        page.y += gap;
        openBars(&page, block);
        var after = b + 1;
        if (block.kind == tdc.TDBLOCK_CELL) {
            after = table(&page, b);
            page.below = m.em;
        } else {
            layBlock(&page, block);
            page.below = spaceBelow(m, block);
        }
        extendBars(&page, block);
        previous = &blocks[after - 1];
        b = after;
    }
    closeBars(&page, null);
    own.widest = page.widest + m.page();
    own.total = page.y + m.page();
    return page.ok;
}

// --- where a block stands ----------------------------------------------------

fn isQuote(block: *const tdc.Block, level: u8) bool {
    return level < 8 and block.quotes & (@as(u8, 1) << @intCast(level)) != 0;
}

/// How many of a block's containers are lists.
fn listDepth(block: *const tdc.Block) u8 {
    var n: u8 = 0;
    var level: u8 = 0;
    while (level < block.depth) : (level += 1) {
        if (!isQuote(block, level)) n += 1;
    }
    return n;
}

fn quoteDepth(block: *const tdc.Block) u8 {
    return block.depth - listDepth(block);
}

/// Whether the innermost of a block's containers is a list.
fn inList(block: *const tdc.Block) bool {
    return block.depth > 0 and !isQuote(block, block.depth - 1);
}

/// Where a block's lines start across, `levels` of its containers in:
/// a quote is its bar and an em, a list two ems.
fn insetOf(page: *const Page, block: *const tdc.Block, levels: u8) i32 {
    var x = page.m.page();
    var level: u8 = 0;
    while (level < levels) : (level += 1) {
        x += if (isQuote(block, level)) page.m.part(1, 4) + page.m.em else 2 * page.m.em;
    }
    return x;
}

/// Where its lines end: an em short of the page's edge for each quote.
fn rightOf(page: *const Page, block: *const tdc.Block) i32 {
    if (page.room <= 0) return 0;
    const right = page.room - page.m.page() - @as(i32, quoteDepth(block)) * page.m.em;
    return @max(right, insetOf(page, block, block.depth) + page.m.em);
}

fn spaceAbove(m: Metrics, block: *const tdc.Block) i32 {
    if (block.flags & tdc.TDBF_START != 0 and listDepth(block) == 1) return m.em;
    if (block.mark != tdc.TDMARK_NONE) return m.part(1, 4);
    return switch (block.kind) {
        tdc.TDBLOCK_HEADING, tdc.TDBLOCK_RULE => m.part(3, 2),
        else => 0,
    };
}

fn spaceBelow(m: Metrics, block: *const tdc.Block) i32 {
    return switch (block.kind) {
        tdc.TDBLOCK_RULE => m.part(3, 2),
        // A paragraph of an item of a list whose items stand close has
        // none; the items' own space is between them.
        tdc.TDBLOCK_PARAGRAPH => if (inList(block) and block.flags & tdc.TDBF_LOOSE == 0) 0 else m.em,
        else => m.em,
    };
}

/// The space a list or a quote leaves under it as it ends.
fn spaceLeaving(m: Metrics, was: *const tdc.Block, now: *const tdc.Block) i32 {
    if (quoteDepth(now) < quoteDepth(was)) return m.em;
    if (listDepth(now) < listDepth(was) and listDepth(now) == 0) return m.em;
    return 0;
}

// --- quotes' bars ------------------------------------------------------------

/// The bars of quotes that do not go on into `block` drawn; null ends
/// them all.
fn closeBars(page: *Page, block: ?*const tdc.Block) void {
    for (&page.bars, 0..) |*bar, i| {
        if (!bar.open) continue;
        const level: u8 = @intCast(i);
        if (block) |b| {
            if (level < b.depth and isQuote(b, level)) continue;
        }
        bar.open = false;
        addDeco(page, .{ .kind = _text.DECO_FILL, .ink = _text.INK_BORDER, .x = bar.x, .y = bar.top, .width = page.m.part(1, 4), .height = bar.bottom - bar.top });
    }
}

/// A bar started for each quote `block` begins.
fn openBars(page: *Page, block: *const tdc.Block) void {
    var level: u8 = 0;
    while (level < block.depth and level < page.bars.len) : (level += 1) {
        if (!isQuote(block, level) or page.bars[level].open) continue;
        page.bars[level] = .{ .open = true, .x = insetOf(page, block, level), .top = page.y, .bottom = page.y };
    }
}

fn extendBars(page: *Page, block: *const tdc.Block) void {
    var level: u8 = 0;
    while (level < block.depth and level < page.bars.len) : (level += 1) {
        if (page.bars[level].open) page.bars[level].bottom = page.y;
    }
}

// --- blocks ------------------------------------------------------------------

fn layBlock(page: *Page, block: *const tdc.Block) void {
    const m = page.m;
    const left = insetOf(page, block, block.depth);
    const right = rightOf(page, block);
    switch (block.kind) {
        tdc.TDBLOCK_RULE => {
            const thick = @max(m.part(1, 4), 2);
            const width = if (right > left) right - left else 40 * m.em;
            addDeco(page, .{ .kind = _text.DECO_FILL, .ink = _text.INK_BORDER, .x = left, .y = page.y, .width = width, .height = thick });
            page.y += thick;
            page.widest = @max(page.widest, left + width);
        },
        tdc.TDBLOCK_LISTING => {
            // Its lines an em in from a ground of its own, never wrapped;
            // the ground as wide as the room or as the longest line.
            const top = page.y;
            const deco_at = page.own.deco_count;
            addDeco(page, .{ .kind = _text.DECO_ROUND, .ink = _text.INK_SUBTLE, .x = left, .y = top, .number = @intCast(m.part(3, 8)) });
            page.y += m.em;
            const got = flow(page, .{ .first = block.first, .count = block.count, .left = left + m.em, .right = 0, .wrap = false, .tall = .listing, .plain = true });
            page.y = got.bottom + m.em;
            const width = @max(if (right > left) right - left else 0, got.right + m.em - left);
            if (deco_at < page.own.deco_count) {
                const ground = &page.own.decos.?[deco_at];
                ground.width = width;
                ground.height = page.y - top;
            }
            page.widest = @max(page.widest, left + width);
        },
        tdc.TDBLOCK_HEADING => {
            const got = flow(page, .{ .first = block.first, .count = block.count, .left = left, .right = right, .wrap = page.own.wrap != 0, .tall = .heading });
            page.y = got.bottom;
            if (block.level <= 2) {
                // A line under it, three tenths of its own size below.
                const size = headingRows(page.own, block);
                page.y += @max(@divTrunc(size * 3 + 5, 10), 2);
                const width = if (right > left) right - left else got.right - left;
                addDeco(page, .{ .kind = _text.DECO_FILL, .ink = _text.INK_RULE, .x = left, .y = page.y, .width = width, .height = 1 });
                page.y += 1;
            }
        },
        else => {
            const got = flow(page, .{ .first = block.first, .count = block.count, .left = left, .right = right, .wrap = page.own.wrap != 0, .tall = .prose });
            if (block.mark != tdc.TDMARK_NONE and got.lines > 0) markItem(page, block, left, got.first_line);
            page.y = got.bottom;
        },
    }
}

/// How tall a heading's letters are: its first run's font.
fn headingRows(own: *const Data, block: *const tdc.Block) i32 {
    const pieces = own.pieces orelse return _text.rowsOf(own);
    if (block.count == 0) return _text.rowsOf(own);
    return _text.heightOf(own, &pieces[block.first]).height;
}

/// An item's mark, in the room in front of its first line.
fn markItem(page: *Page, block: *const tdc.Block, left: i32, line_index: u32) void {
    const m = page.m;
    const line = page.own.lines.?[line_index];
    const baseline = line.top + line.baseline;
    // Where the middle of a small letter is.
    const middle = baseline - m.part(5, 16);
    switch (block.mark) {
        tdc.TDMARK_DISC, tdc.TDMARK_CIRCLE => addDeco(page, .{
            .kind = if (block.mark == tdc.TDMARK_DISC) _text.DECO_DISC else _text.DECO_CIRCLE,
            .ink = _text.INK_TEXT,
            .x = left - m.em,
            .y = middle,
            .width = @max(m.part(3, 16), 2),
        }),
        tdc.TDMARK_SQUARE => {
            const side = @max(m.part(5, 16), 3);
            addDeco(page, .{ .kind = _text.DECO_SQUARE, .ink = _text.INK_TEXT, .x = left - m.em - @divTrunc(side, 2), .y = middle - @divTrunc(side, 2), .width = side, .height = side });
        },
        tdc.TDMARK_TASK, tdc.TDMARK_DONE => {
            const side = @max(m.part(13, 16), 6);
            addDeco(page, .{
                .kind = if (block.mark == tdc.TDMARK_DONE) _text.DECO_DONE else _text.DECO_TASK,
                .ink = if (block.mark == tdc.TDMARK_DONE) _text.INK_LINK else _text.INK_MUTED,
                .x = left - m.part(23, 16),
                .y = middle - @divTrunc(side, 2),
                .width = side,
                .height = side,
                .number = @intCast(@max(m.part(3, 16), 2)),
            });
        },
        else => addDeco(page, .{
            .kind = switch (block.mark) {
                tdc.TDMARK_ROMAN => _text.DECO_ROMAN,
                tdc.TDMARK_LETTER => _text.DECO_LETTER,
                else => _text.DECO_NUMBER,
            },
            .ink = _text.INK_TEXT,
            .x = left - m.part(3, 8),
            .y = baseline,
            .number = block.number,
        }),
    }
}

// --- tables ------------------------------------------------------------------

const most_columns = 32;

/// The table that starts at block `start` laid out; the block after it.
fn table(page: *Page, start: u32) u32 {
    const own = page.own;
    const blocks = own.blocks.?;
    const m = page.m;
    var end = start + 1;
    while (end < own.block_count and blocks[end].kind == tdc.TDBLOCK_CELL and blocks[end].flags & tdc.TDBF_TABLE == 0) end += 1;
    const first = &blocks[start];
    const left = insetOf(page, first, first.depth);
    const right = rightOf(page, first);
    const pad_x = m.part(13, 16);
    const pad_y = m.part(6, 16);

    // Each column's widest cell, and its longest word.
    var natural: [most_columns]i32 = @splat(0);
    var least: [most_columns]i32 = @splat(0);
    var columns: u32 = 1;
    for (blocks[start..end]) |*cell| {
        const c = @min(cell.number, most_columns - 1);
        columns = @max(columns, c + 1);
        const got = flow(page, .{ .first = cell.first, .count = cell.count, .left = 0, .right = 0, .wrap = false, .tall = .prose, .dry = true });
        natural[c] = @max(natural[c], got.right);
        least[c] = @max(least[c], got.word);
    }
    var widths = natural;
    if (right > left) {
        const room = right - left - @as(i32, @intCast(columns)) * (2 * pad_x + 1) - 1;
        var total: i32 = 0;
        for (natural[0..columns]) |w| total += w;
        if (total > room and room > 0) {
            for (widths[0..columns], natural[0..columns], least[0..columns]) |*w, n, l| {
                w.* = @max(l, @divTrunc(n * room, @max(total, 1)));
            }
        }
    }
    var at: [most_columns + 1]i32 = undefined;
    at[0] = left;
    for (0..columns) |c| at[c + 1] = at[c] + widths[c] + 2 * pad_x + 1;
    const table_width = at[columns] - left + 1;

    // The rows, a cell at a time: each row's line over it, then its
    // cells, then - every other row of the body - its ground, which
    // stops short of the lines round it.
    const top = page.y;
    var body_row: u32 = 0;
    var cell_index = start;
    while (cell_index < end and page.ok) {
        const row_top = page.y;
        const head = blocks[cell_index].flags & tdc.TDBF_HEAD != 0;
        const shaded = !head and body_row % 2 == 1;
        if (!head) body_row += 1;
        addDeco(page, .{ .kind = _text.DECO_FILL, .ink = _text.INK_BORDER, .x = left, .y = row_top, .width = table_width, .height = 1 });
        const ground_at = page.own.deco_count;
        if (shaded) addDeco(page, .{ .kind = _text.DECO_FILL, .ink = _text.INK_SUBTLE, .x = left + 1, .y = row_top + 1, .width = table_width - 2 });
        // The row's cells, each laid out from the row's top; then each
        // stood in the middle of the row's height.
        var row_end = cell_index + 1;
        while (row_end < end and blocks[row_end].flags & tdc.TDBF_ROW == 0) row_end += 1;
        var cell_lines: [most_columns]struct { first: u32, count: u32, height: i32 } = undefined;
        var tallest: i32 = 0;
        for (blocks[cell_index..row_end], 0..) |*cell, k| {
            const c = @min(cell.number, most_columns - 1);
            page.y = row_top + 1 + pad_y;
            const got = flow(page, .{
                .first = cell.first,
                .count = cell.count,
                .left = at[c] + 1 + pad_x,
                .right = at[c] + 1 + pad_x + widths[c],
                .wrap = true,
                .tall = .prose,
                .alignment = cell.alignment,
            });
            const height = got.bottom - (row_top + 1 + pad_y);
            if (k < most_columns) cell_lines[k] = .{ .first = got.first_line, .count = got.lines, .height = height };
            tallest = @max(tallest, height);
        }
        for (cell_lines[0..@min(row_end - cell_index, most_columns)]) |cell| {
            const down = @divTrunc(tallest - cell.height, 2);
            if (down == 0 or own.lines == null) continue;
            for (own.lines.?[cell.first..][0..cell.count]) |*line| line.top += down;
        }
        page.y = row_top + 1 + pad_y + tallest + pad_y;
        if (shaded and ground_at < page.own.deco_count) page.own.decos.?[ground_at].height = page.y - row_top - 1;
        cell_index = row_end;
    }
    const bottom = page.y;
    page.y += 1;
    addDeco(page, .{ .kind = _text.DECO_FILL, .ink = _text.INK_BORDER, .x = left, .y = bottom, .width = table_width, .height = 1 });
    for (0..columns + 1) |c| {
        addDeco(page, .{ .kind = _text.DECO_FILL, .ink = _text.INK_BORDER, .x = at[c], .y = top, .width = 1, .height = bottom - top + 1 });
    }
    page.widest = @max(page.widest, left + table_width);
    return end;
}

// --- lines -------------------------------------------------------------------

/// Where a run's character is.
const Cursor = struct {
    p: u32,
    at: u32,
};

/// A stretch of runs broken into lines from `page.y` down; `page.y` is
/// left where it ended.
fn flow(page: *Page, f: Flow) Flowed {
    const own = page.own;
    const pieces = own.pieces.?;
    const buffer = own.buffer.?;
    var got = Flowed{ .first_line = own.line_count };
    const start_y = page.y;
    defer {
        if (f.dry) page.y = start_y;
    }

    // Where the stretch ends: its last run's end, or in a block before
    // the character that ends the block, which is not drawn.
    const after = f.first + f.count;
    const last: u32 = if (f.count > 0) after - 1 else f.first;
    var last_at: u32 = if (f.count > 0) pieces[last].length else 0;
    if (own.blocks != null and last_at > 0) {
        const end_char = buffer[pieces[last].offset + last_at - 1];
        if (end_char == '\n' or end_char == '\t') last_at -= 1;
    }

    var cur = Cursor{ .p = f.first, .at = 0 };
    var line = Building{ .first = own.fragment_count, .x = f.left };
    startLine(page, f, &line, cur);
    // The run an empty line takes its height from.
    var last_piece: u32 = f.first;

    while (before(cur, last, last_at, after) and page.ok) {
        if (cur.at >= pieces[cur.p].length) {
            cur.p += 1;
            cur.at = 0;
            continue;
        }
        const piece = &pieces[cur.p];
        last_piece = cur.p;
        const c = buffer[piece.offset + cur.at];
        if (c == '\n') {
            endLine(page, f, &line, &got, last_piece, false);
            cur.at += 1;
            startLine(page, f, &line, next(cur, pieces));
            continue;
        }
        if (c == ' ' or (c == '\t' and !f.plain)) {
            // Spaces, as far as this run has them.
            var stop = cur.at;
            const limit = if (cur.p == last) last_at else piece.length;
            while (stop < limit and (buffer[piece.offset + stop] == ' ' or buffer[piece.offset + stop] == '\t')) stop += 1;
            if (!(line.wrapped and !line.used and !f.plain)) {
                place(page, f, &line, cur.p, cur.at, stop - cur.at, false);
            }
            cur.at = stop;
            continue;
        }
        // A word: as far as the next space or line end, through as many
        // runs as it is drawn in.
        var word_end = cur;
        var width: i32 = 0;
        while (before(word_end, last, last_at, after)) {
            if (word_end.at >= pieces[word_end.p].length) {
                word_end.p += 1;
                word_end.at = 0;
                continue;
            }
            const wp = &pieces[word_end.p];
            const limit = if (word_end.p == last) last_at else wp.length;
            var stop = word_end.at;
            while (stop < limit) : (stop += 1) {
                const b = buffer[wp.offset + stop];
                if (b == ' ' or b == '\n' or (b == '\t' and !f.plain)) break;
            }
            width += segmentWidth(page, wp, word_end.at, stop - word_end.at);
            word_end.at = stop;
            if (stop < limit) break;
            if (word_end.p + 1 >= after) break;
            word_end.p += 1;
            word_end.at = 0;
        }
        got.word = @max(got.word, width);
        if (f.wrap and f.right > f.left and line.used and line.x + width > f.right) {
            endLine(page, f, &line, &got, last_piece, true);
            startLine(page, f, &line, cur);
            line.wrapped = true;
        }
        // The word placed, a run at a time; one longer than the whole
        // line broken where it reaches the edge.
        while (before(cur, word_end.p, word_end.at, after) and page.ok) {
            if (cur.at >= pieces[cur.p].length) {
                cur.p += 1;
                cur.at = 0;
                continue;
            }
            const wp = &pieces[cur.p];
            const stop = if (cur.p == word_end.p) word_end.at else wp.length;
            var length = stop - cur.at;
            if (f.wrap and f.right > f.left and width > f.right - f.left) {
                const fits = fitting(page, wp, cur.at, stop, f.right - line.x);
                if (fits == cur.at and line.used) {
                    endLine(page, f, &line, &got, last_piece, true);
                    startLine(page, f, &line, cur);
                    line.wrapped = true;
                    continue;
                }
                length = @max(fits, cur.at + 1) - cur.at;
            }
            place(page, f, &line, cur.p, cur.at, length, true);
            cur.at += length;
            if (cur.at < stop) {
                endLine(page, f, &line, &got, last_piece, true);
                startLine(page, f, &line, cur);
                line.wrapped = true;
            }
        }
    }
    endLine(page, f, &line, &got, last_piece, false);
    got.bottom = page.y;
    return got;
}

/// Whether a cursor is before the stretch's end.
fn before(cur: Cursor, last: u32, last_at: u32, after: u32) bool {
    if (cur.p >= after) return false;
    if (cur.p < last) return true;
    return cur.p == last and cur.at < last_at;
}

fn next(cur: Cursor, pieces: [*]const tdc.Piece) Cursor {
    if (cur.at >= pieces[cur.p].length) return .{ .p = cur.p + 1, .at = 0 };
    return cur;
}

/// How far in from the edge code inside a line has its ground.
fn codePad(page: *const Page) i32 {
    return page.m.part(3, 10);
}

/// How wide a stretch of a run is, with the ground round code where the
/// stretch starts or ends the run.
fn segmentWidth(page: *const Page, piece: *const tdc.Piece, from: u32, length: u32) i32 {
    var width = _text.widthOf(page.base, page.own, piece, piece.offset + from, length);
    if (piece.style & tdc.TDSTYLE_CODE != 0) {
        if (from == 0) width += codePad(page);
        if (from + length >= piece.length) width += codePad(page);
    }
    return width;
}

/// How much of a run from `from` fits in `room` pixels.
fn fitting(page: *const Page, piece: *const tdc.Piece, from: u32, to: u32, room: i32) u32 {
    if (room <= 0) return from;
    var low = from;
    var high = to;
    while (low < high) {
        const middle = low + (high - low + 1) / 2;
        if (segmentWidth(page, piece, from, middle - from) <= room) low = middle else high = middle - 1;
    }
    return low;
}

/// A line started where `cur` is: as far in as its first run's indent,
/// in text without blocks.
fn startLine(page: *Page, f: Flow, line: *Building, cur: Cursor) void {
    line.* = .{ .first = page.own.fragment_count, .x = f.left };
    if (f.plain and page.own.blocks == null and cur.p < f.first + f.count) {
        line.x += @as(i32, page.own.pieces.?[cur.p].indent) * page.own.indent_width;
    }
}

/// A stretch of a run put on the line, joined to the fragment before it
/// where it goes on from it.
fn place(page: *Page, f: Flow, line: *Building, p: u32, at: u32, length: u32, word: bool) void {
    if (length == 0) return;
    const own = page.own;
    const piece = &own.pieces.?[p];
    const width = segmentWidth(page, piece, at, length);
    const inset: i32 = if (piece.style & tdc.TDSTYLE_CODE != 0 and at == 0) codePad(page) else 0;
    if (word) line.used = true;
    defer line.x += width;
    if (f.dry) return;
    if (own.fragment_count > line.first) {
        const before_it = &own.fragments.?[own.fragment_count - 1];
        if (before_it.piece == p and before_it.offset + before_it.length == piece.offset + at) {
            before_it.length += length;
            before_it.width += width;
            return;
        }
    }
    if (!_text.makeRoom(page.base, Fragment, &own.fragments, &own.fragment_room, own.fragment_count + 1)) {
        page.ok = false;
        return;
    }
    own.fragments.?[own.fragment_count] = .{
        .piece = p,
        .offset = piece.offset + at,
        .length = length,
        .left = line.x,
        .width = width,
        .inset = inset,
    };
    own.fragment_count += 1;
}

/// The line being built closed off: as tall as its tallest run asks,
/// its letters on one baseline, moved across as its alignment says.
/// `wrapped` lines lose the spaces they end in.
fn endLine(page: *Page, f: Flow, line: *Building, got: *Flowed, empty_piece: u32, wrapped: bool) void {
    const own = page.own;
    if (wrapped and !f.plain and !f.dry) trimSpaces(page, line);
    var ascent: i32 = 0;
    var descent: i32 = 0;
    var tallest: i32 = 0;
    var right = line.x;
    if (!f.dry and own.fragment_count > line.first) {
        right = f.left;
        for (own.fragments.?[line.first..own.fragment_count]) |fragment| {
            const size = _text.heightOf(own, &own.pieces.?[fragment.piece]);
            ascent = @max(ascent, size.baseline);
            descent = @max(descent, size.height - size.baseline);
            tallest = @max(tallest, size.height);
            right = @max(right, fragment.left + fragment.width);
        }
    } else {
        const size = if (own.piece_count > empty_piece) _text.heightOf(own, &own.pieces.?[empty_piece]) else Height0;
        ascent = size.baseline;
        descent = size.height - size.baseline;
        tallest = size.height;
    }
    const letters = ascent + descent;
    const height = @max(f.tall.of(tallest), letters);
    const baseline = @divTrunc(height - letters, 2) + ascent;
    got.right = @max(got.right, right);
    page.widest = @max(page.widest, right);
    got.lines += 1;
    defer page.y += height;
    if (f.dry) return;

    // Moved across within its edges.
    var shift: i32 = 0;
    if (f.right > f.left and f.alignment != tdc.TDALIGN_LEFT) {
        const spare = f.right - right;
        shift = if (f.alignment == tdc.TDALIGN_RIGHT) spare else @divTrunc(spare, 2);
        if (shift > 0) {
            for (own.fragments.?[line.first..own.fragment_count]) |*fragment| fragment.left += shift;
        } else shift = 0;
    }
    if (!_text.makeRoom(page.base, Line, &own.lines, &own.line_room, own.line_count + 1)) {
        page.ok = false;
        return;
    }
    own.lines.?[own.line_count] = .{
        .first = line.first,
        .count = own.fragment_count - line.first,
        .top = page.y,
        .height = height,
        .baseline = baseline,
        .left = f.left + shift,
        .right = right + shift,
    };
    own.line_count += 1;
}

const Height0 = _text.Height{ .height = 8, .baseline = 6 };

/// The spaces a wrapped line ends in taken off it.
fn trimSpaces(page: *Page, line: *Building) void {
    const own = page.own;
    const buffer = own.buffer.?;
    while (own.fragment_count > line.first) {
        const fragment = &own.fragments.?[own.fragment_count - 1];
        var length = fragment.length;
        while (length > 0 and buffer[fragment.offset + length - 1] == ' ') length -= 1;
        if (length == fragment.length) return;
        if (length == 0) {
            own.fragment_count -= 1;
            continue;
        }
        const piece = &own.pieces.?[fragment.piece];
        const at = fragment.offset - piece.offset;
        fragment.length = length;
        fragment.width = segmentWidth(page, piece, at, length);
        return;
    }
}

fn addDeco(page: *Page, deco: Deco) void {
    const own = page.own;
    if (!_text.makeRoom(page.base, Deco, &own.decos, &own.deco_room, own.deco_count + 1)) {
        page.ok = false;
        return;
    }
    own.decos.?[own.deco_count] = deco;
    own.deco_count += 1;
}

/// How tall the whole text came out.
pub fn totalHeight(own: *const Data) i32 {
    return own.total;
}

/// Which line a place `x` across and `y` down the text is in: of the
/// lines across `y` - a table's row has one a cell - the one `x` is in,
/// or the nearest.
pub fn lineAt(own: *const Data, x: i32, y: i32) u32 {
    if (own.line_count == 0) return 0;
    const lines = own.lines.?;
    var best: ?u32 = null;
    var best_distance: i32 = std.math.maxInt(i32);
    var below: ?u32 = null;
    var n: u32 = 0;
    while (n < own.line_count) : (n += 1) {
        const line = lines[n];
        if (y >= line.top and y < line.top + line.height) {
            const distance: i32 = if (x < line.left) line.left - x else if (x > line.right) x - line.right else 0;
            if (distance < best_distance) {
                best = n;
                best_distance = distance;
            }
        } else if (line.top > y) {
            if (below == null or line.top < lines[below.?].top) below = n;
        }
    }
    // Between lines: the next one down, or the last of all.
    return best orelse below orelse own.line_count - 1;
}
