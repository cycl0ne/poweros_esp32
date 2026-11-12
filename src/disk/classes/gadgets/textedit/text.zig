// SPDX-License-Identifier: MIT
//! The text a textedit.gadget holds and the rows it makes on the screen:
//! nothing here draws or asks a library, so the host tests hold all of it.
//!
//! **The bytes** are in a gap buffer: one allocation with a hole at the
//! place last edited, so typing at one place moves nothing but the hole.
//! A position is a byte's index in the text as it reads, the hole left
//! out; `length` is the text's size.
//!
//! **The text is UTF-8**, and a position the gadget keeps is always where
//! a character starts: everything that walks the text - widths, rows,
//! words, finding - goes a character at a time (`charAt`, `charBefore`).
//! A byte that is no UTF-8 is a character of its own, read as `utf8.read`
//! reads it.
//!
//! **Lines** are kept as the position each one starts at: line 0 at 0,
//! and one after every line feed. An edit moves the starts after it and
//! adds or takes away the ones its line feeds make.
//!
//! **Rows** are what the screen shows: a line is one row, or with wrap
//! several, each as much of it as fits the width - broken after the last
//! space that fits, or where it stops fitting when there is none. Rows
//! are kept as their starts too, so a line's first row starts at the
//! line's start and the row a position is in is found by a binary search.
//! An edit makes the rows of the lines it touched again and moves the
//! rest; a new width, a font or wrap turned on or off makes all of them.
//!
//! Widths come from a table of the first 256 characters' widths in the
//! font (`Layout.widths`) and the tab stop, so laying out such text costs
//! no calls; a character past them is asked of `Layout.measure`, which
//! the gadget gives and keeps the answers of. The gadget measures what
//! it draws with the font itself.
//!
//! **A row is laid out in pieces** (`pieces`): the text between two tabs
//! or control characters, `piece_room` bytes of it at the most, and each
//! tab or control character by itself. A piece is what the gadget draws
//! in one go. With a font that shapes its text - one that kerns, joins
//! letters or puts a mark on its letter - the gadget gives `Layout.place`
//! and `Layout.nearest`, and where a position is in its row (`xOf`,
//! `xInRow`) and the position at a place (`posAt`) are asked of the font
//! for the piece as a whole, so they are where the letters are drawn and
//! not where the widths added up would put them. Rows are broken, and
//! the widest one is found, by the table's widths either way: a wrapped
//! row of shaped text may end a few pixels before or after the width.

const std = @import("std");
const sdk = @import("sdk");
const utf8 = sdk.utility.utf8;
const unicode = sdk.utility.unicode;

/// Where the text's memory comes from: exec's AllocVec and FreeVec in the
/// gadget, the testing allocator in the tests.
pub const Memory = struct {
    context: ?*anyopaque = null,
    alloc: *const fn (context: ?*anyopaque, size: u32) ?[*]u8,
    free: *const fn (context: ?*anyopaque, memory: [*]u8) void,
};

/// A stretch of the text, from `from` up to `to`.
pub const Span = struct { from: u32, to: u32 };

/// How the text is laid out: each character's width, where tabs stop,
/// and the width rows wrap at (0: they do not).
pub const Layout = struct {
    /// The widths of the characters U+0000 to U+00FF.
    widths: [256]u16 = @splat(1),
    /// The width of a character past U+00FF, with `context`; without it,
    /// a `?`'s.
    measure: ?*const fn (context: ?*anyopaque, char: u32) u16 = null,
    context: ?*anyopaque = null,
    /// With a font that shapes its text: how many pixels into the piece
    /// `bytes`, drawn as one, the place before its byte `offset` is - the
    /// piece's width for its length - and the byte of the place nearest
    /// `x`. Both or neither; without them the widths are added up.
    place: ?*const fn (context: ?*anyopaque, bytes: []const u8, offset: u32) u32 = null,
    nearest: ?*const fn (context: ?*anyopaque, bytes: []const u8, x: i32) u32 = null,
    /// Pixels between tab stops: eight spaces.
    tab_stop: u32 = 8,
    wrap_width: u32 = 0,

    /// A character's width, a tab's aside.
    pub fn widthOf(layout: *const Layout, char: u32) u32 {
        if (char < 0x100) return layout.widths[char];
        const measure = layout.measure orelse return layout.widths['?'];
        return measure(layout.context, char);
    }
};

/// The most bytes of a piece.
pub const piece_room = 256;
/// A piece of this many bytes ends before the next word.
const piece_full = piece_room - 64;
/// The bytes a cluster is looked for in, from where it starts or back
/// from where it ends: one that is longer is taken in parts.
const cluster_room = 64;

/// Whether a character is drawn: not a tab or another control character,
/// which only take room.
pub fn isDrawn(char: u32) bool {
    return char >= 0x20 and !(char >= 0x7F and char < 0xA0);
}

/// A stretch of a row that is laid out and drawn as one.
pub const Piece = struct {
    from: u32,
    to: u32,
    /// How far into the row it starts.
    x: u32,
    /// Text; else one tab or control character.
    drawn: bool,
};

/// A row's pieces from its start, each placed after the ones before.
pub const Pieces = struct {
    text: *const Text,
    end: u32,
    /// The piece `next` gave last; before the first, an empty one at the
    /// row's start.
    piece: Piece,
    /// Its width, once it was asked for.
    width: ?u32 = 0,

    /// The next piece; null after the last, when `piece` and `widthOf`
    /// are still the last one's.
    pub fn next(pieces: *Pieces) ?Piece {
        const text = pieces.text;
        const at = pieces.piece.to;
        if (at >= pieces.end) return null;
        const x = pieces.piece.x + pieces.widthOf();
        const first = text.charAt(at);
        const drawn = isDrawn(first.char);
        const to = if (drawn) text.pieceEnd(at, pieces.end) else at + @as(u32, @intCast(first.length));
        pieces.piece = .{ .from = at, .to = to, .x = x, .drawn = drawn };
        pieces.width = null;
        return pieces.piece;
    }

    /// The width of the piece `next` gave last.
    pub fn widthOf(pieces: *Pieces) u32 {
        if (pieces.width) |known| return known;
        const text = pieces.text;
        const piece = pieces.piece;
        const width = if (piece.drawn) text.placeIn(piece, piece.to) else text.widthAt(text.charAt(piece.from).char, piece.x);
        pieces.width = width;
        return width;
    }

    /// How far into the row the text given so far reaches.
    pub fn reach(pieces: *Pieces) u32 {
        return pieces.piece.x + pieces.widthOf();
    }
};

/// A growing list of positions.
pub const Positions = struct {
    items: ?[*]u32 = null,
    len: u32 = 0,
    cap: u32 = 0,

    pub fn free(list: *Positions, memory: Memory) void {
        if (list.items) |items| memory.free(memory.context, @ptrCast(items));
        list.* = .{};
    }

    pub fn get(list: *const Positions, index: u32) u32 {
        return list.items.?[index];
    }

    /// Room for `extra` more, the list's memory doubled as often as that
    /// takes.
    fn reserve(list: *Positions, memory: Memory, extra: u32) bool {
        if (list.len + extra <= list.cap) return true;
        var cap: u32 = if (list.cap == 0) 256 else list.cap;
        while (cap < list.len + extra) cap *= 2;
        const fresh: [*]u32 = @ptrCast(@alignCast(memory.alloc(memory.context, cap * 4) orelse return false));
        if (list.items) |old| {
            @memcpy(fresh[0..list.len], old[0..list.len]);
            memory.free(memory.context, @ptrCast(old));
        }
        list.items = fresh;
        list.cap = cap;
        return true;
    }

    pub fn append(list: *Positions, memory: Memory, value: u32) bool {
        if (!list.reserve(memory, 1)) return false;
        list.items.?[list.len] = value;
        list.len += 1;
        return true;
    }

    /// `values` in place of the items from `from` up to `to`.
    fn replace(list: *Positions, memory: Memory, from: u32, to: u32, values: []const u32) bool {
        const count: u32 = @intCast(values.len);
        if (count > to - from and !list.reserve(memory, count - (to - from))) return false;
        const items = list.items orelse {
            if (count == 0) return true;
            unreachable;
        };
        const tail = list.len - to;
        const new_to = from + count;
        if (new_to != to) @memmove(items[new_to..][0..tail], items[to..][0..tail]);
        @memcpy(items[from..new_to], values);
        list.len = new_to + tail;
        return true;
    }

    /// The last index whose value is at most `value`; 0 when none is.
    pub fn floor(list: *const Positions, value: u32) u32 {
        var low: u32 = 0;
        var high: u32 = list.len;
        while (high - low > 1) {
            const middle = low + (high - low) / 2;
            if (list.items.?[middle] <= value) low = middle else high = middle;
        }
        return low;
    }

    /// `delta` added to every item from `from` on.
    fn shift(list: *Positions, from: u32, delta: i64) void {
        const items = list.items orelse return;
        var index = from;
        while (index < list.len) : (index += 1) items[index] = @intCast(@as(i64, items[index]) + delta);
    }
};

pub const Text = struct {
    memory: Memory,
    bytes: ?[*]u8 = null,
    cap: u32 = 0,
    gap_start: u32 = 0,
    gap_end: u32 = 0,
    lines: Positions = .{},
    rows: Positions = .{},
    layout: Layout = .{},
    /// The widest row, for the sideways scroller when rows do not wrap.
    widest: u32 = 0,

    /// An empty text, with its one line and its one row.
    pub fn init(memory: Memory) ?Text {
        var text = Text{ .memory = memory };
        if (!text.lines.append(memory, 0) or !text.rows.append(memory, 0)) {
            text.deinit();
            return null;
        }
        return text;
    }

    pub fn deinit(text: *Text) void {
        if (text.bytes) |bytes| text.memory.free(text.memory.context, bytes);
        text.lines.free(text.memory);
        text.rows.free(text.memory);
        text.bytes = null;
    }

    pub fn length(text: *const Text) u32 {
        return text.cap - (text.gap_end - text.gap_start);
    }

    pub fn byteAt(text: *const Text, pos: u32) u8 {
        const at = if (pos < text.gap_start) pos else pos + (text.gap_end - text.gap_start);
        return text.bytes.?[at];
    }

    /// The character at `pos`, before the text's end, and the bytes it
    /// takes.
    pub fn charAt(text: *const Text, pos: u32) utf8.Read {
        var bytes: [4]u8 = undefined;
        const count = @min(4, text.length() - pos);
        for (bytes[0..count], 0..) |*byte, offset| byte.* = text.byteAt(pos + @as(u32, @intCast(offset)));
        return utf8.read(bytes[0..count]);
    }

    /// Where the character before `pos`, above 0, starts.
    pub fn charBefore(text: *const Text, pos: u32) u32 {
        var bytes: [4]u8 = undefined;
        const count = @min(4, pos);
        for (bytes[0..count], 0..) |*byte, offset| byte.* = text.byteAt(pos - count + @as(u32, @intCast(offset)));
        return pos - @as(u32, @intCast(utf8.readLast(bytes[0..count]).length));
    }

    /// Where the character after the one at `pos` starts; the text's end
    /// from there.
    pub fn charAfter(text: *const Text, pos: u32) u32 {
        if (pos >= text.length()) return text.length();
        return pos + @as(u32, @intCast(text.charAt(pos).length));
    }

    /// Where the character `pos` falls in starts: `pos` itself where one
    /// starts, and at the text's end.
    pub fn charStartOf(text: *const Text, pos: u32) u32 {
        if (pos >= text.length()) return pos;
        var start = pos;
        var back: u32 = 0;
        while (start > 0 and back < 3 and text.byteAt(start) & 0xC0 == 0x80) : (back += 1) start -= 1;
        if (start == pos) return pos;
        return if (start + text.charAt(start).length > pos) start else pos;
    }

    /// How many characters there are from `from` up to `to`.
    pub fn charsBetween(text: *const Text, from: u32, to: u32) u32 {
        var count: u32 = 0;
        var at = from;
        while (at < to) : (count += 1) at = text.charAfter(at);
        return count;
    }

    /// The bytes from `from` up to `to` into `into`.
    pub fn copyOut(text: *const Text, from: u32, to: u32, into: [*]u8) void {
        if (from >= to) return;
        const bytes = text.bytes.?;
        const gap = text.gap_end - text.gap_start;
        var done: u32 = 0;
        if (from < text.gap_start) {
            const before = @min(to, text.gap_start) - from;
            @memcpy(into[0..before], bytes[from..][0..before]);
            done = before;
        }
        if (to > text.gap_start) {
            const start = @max(from, text.gap_start);
            const after = to - start;
            @memcpy(into[done..][0..after], bytes[start + gap ..][0..after]);
        }
    }

    /// The text from `from` up to `to` as one piece, when it does not
    /// span the gap; null when it does.
    pub fn slice(text: *const Text, from: u32, to: u32) ?[]const u8 {
        if (from == to) return &.{};
        const bytes = text.bytes.?;
        if (to <= text.gap_start) return bytes[from..to];
        const gap = text.gap_end - text.gap_start;
        if (from >= text.gap_start) return bytes[from + gap .. to + gap];
        return null;
    }

    /// The gap moved to `pos`, and at least `room` bytes wide.
    fn gapAt(text: *Text, pos: u32, room: u32) bool {
        if (text.gap_end - text.gap_start < room) {
            const len = text.length();
            var cap: u32 = if (text.cap == 0) 4096 else text.cap;
            while (cap - len < room + 256) cap *= 2;
            const fresh = text.memory.alloc(text.memory.context, cap) orelse return false;
            if (text.bytes) |old| {
                text.copyOut(0, len, fresh);
                text.memory.free(text.memory.context, old);
            }
            text.bytes = fresh;
            text.cap = cap;
            text.gap_start = len;
            text.gap_end = cap;
        }
        const bytes = text.bytes.?;
        const gap = text.gap_end - text.gap_start;
        if (pos < text.gap_start) {
            const count = text.gap_start - pos;
            @memmove(bytes[pos + gap ..][0..count], bytes[pos..][0..count]);
        } else if (pos > text.gap_start) {
            const count = pos - text.gap_start;
            @memmove(bytes[text.gap_start..][0..count], bytes[text.gap_end..][0..count]);
        }
        text.gap_start = pos;
        text.gap_end = pos + gap;
        return true;
    }

    /// The whole text replaced with `bytes`. False with nothing changed
    /// when there is no memory for it.
    pub fn setAll(text: *Text, bytes: []const u8) bool {
        var fresh = Text.init(text.memory) orelse return false;
        fresh.layout = text.layout;
        if (bytes.len != 0) {
            if (!fresh.gapAt(0, @intCast(bytes.len))) {
                fresh.deinit();
                return false;
            }
            @memcpy(fresh.bytes.?[0..bytes.len], bytes);
            fresh.gap_start = @intCast(bytes.len);
            for (bytes, 0..) |byte, at| {
                if (byte == '\n' and !fresh.lines.append(fresh.memory, @intCast(at + 1))) {
                    fresh.deinit();
                    return false;
                }
            }
        }
        if (!fresh.relayout()) {
            fresh.deinit();
            return false;
        }
        text.deinit();
        text.* = fresh;
        return true;
    }

    // --- lines --------------------------------------------------------------

    pub fn lineCount(text: *const Text) u32 {
        return text.lines.len;
    }

    pub fn lineOf(text: *const Text, pos: u32) u32 {
        return text.lines.floor(pos);
    }

    pub fn lineStart(text: *const Text, line: u32) u32 {
        return text.lines.get(line);
    }

    /// Where a line ends: at its line feed, or at the text's end.
    pub fn lineEnd(text: *const Text, line: u32) u32 {
        return if (line + 1 < text.lines.len) text.lines.get(line + 1) - 1 else text.length();
    }

    /// The spaces and tabs the line `pos` is in starts with, as far as
    /// `pos`: what Return starts the next line with.
    pub fn indentOf(text: *const Text, pos: u32) Span {
        const from = text.lineStart(text.lineOf(pos));
        var to = from;
        while (to < pos and (text.byteAt(to) == ' ' or text.byteAt(to) == '\t')) to += 1;
        return .{ .from = from, .to = to };
    }

    // --- rows ---------------------------------------------------------------

    pub fn rowCount(text: *const Text) u32 {
        return text.rows.len;
    }

    pub fn rowOf(text: *const Text, pos: u32) u32 {
        return text.rows.floor(pos);
    }

    pub fn rowStart(text: *const Text, row: u32) u32 {
        return text.rows.get(row);
    }

    /// Where a row's text ends: where the next row of its line starts, or
    /// at the line's end.
    pub fn rowEnd(text: *const Text, row: u32) u32 {
        const end = text.lineEnd(text.lineOf(text.rows.get(row)));
        if (row + 1 < text.rows.len) return @min(text.rows.get(row + 1), end);
        return end;
    }

    /// The first row of a line.
    fn firstRow(text: *const Text, line: u32) u32 {
        return text.rows.floor(text.lines.get(line));
    }

    /// The width of a character at `x` from its row's start.
    pub fn widthAt(text: *const Text, char: u32, x: u32) u32 {
        if (char == '\t') {
            const stop = @max(text.layout.tab_stop, 1);
            return (x / stop + 1) * stop - x;
        }
        return text.layout.widthOf(char);
    }

    /// The pieces of `row`.
    pub fn pieces(text: *const Text, row: u32) Pieces {
        const start = text.rowStart(row);
        return .{ .text = text, .end = text.rowEnd(row), .piece = .{ .from = start, .to = start, .x = 0, .drawn = false } };
    }

    /// Where the piece of text that starts at `from` ends: before the
    /// next tab or control character or at `end`; a long one before the
    /// first word that starts `piece_full` bytes in, and at `piece_room`
    /// bytes at the latest - there where a cluster starts, not between a
    /// letter and its marks or inside a syllable.
    fn pieceEnd(text: *const Text, from: u32, end: u32) u32 {
        var at = from;
        // The last cluster's start in the piece: where a cut for room
        // goes.
        var letter = from;
        var cluster_end = from;
        var after_space = false;
        while (at < end) {
            const found = text.charAt(at);
            if (!isDrawn(found.char)) break;
            const size: u32 = @intCast(found.length);
            const starts = at >= cluster_end;
            if (starts) cluster_end = text.clusterEnd(at, end);
            if (starts and after_space and at - from >= piece_full) break;
            if (at + size - from > piece_room) return if (starts or letter == from) at else letter;
            if (starts) letter = at;
            at += size;
            after_space = found.char == ' ';
        }
        return at;
    }

    /// A piece's bytes: the text's own where the gap is not in them, else
    /// copied to `copy`.
    pub fn bytesOf(text: *const Text, piece: Piece, copy: *[piece_room]u8) []const u8 {
        if (text.slice(piece.from, piece.to)) |bytes| return bytes;
        text.copyOut(piece.from, piece.to, copy);
        return copy[0 .. piece.to - piece.from];
    }

    /// How far into a piece of text the place before `pos` is; the
    /// piece's width from its end on.
    pub fn placeIn(text: *const Text, piece: Piece, pos: u32) u32 {
        if (pos <= piece.from) return 0;
        const upto = @min(pos, piece.to);
        if (text.layout.place) |place| {
            var copy: [piece_room]u8 = undefined;
            return place(text.layout.context, text.bytesOf(piece, &copy), upto - piece.from);
        }
        var x: u32 = 0;
        var at = piece.from;
        while (at < upto) {
            const found = text.charAt(at);
            x += text.layout.widthOf(found.char);
            at += @intCast(found.length);
        }
        return x;
    }

    /// The position in a piece of text whose place is nearest `x`, counted
    /// from the piece's start: before a character whose left half `x` is
    /// in, after it from its right half on.
    pub fn nearIn(text: *const Text, piece: Piece, x: i64) u32 {
        if (x <= 0) return piece.from;
        if (text.layout.nearest) |nearest| {
            var copy: [piece_room]u8 = undefined;
            const column: i32 = @intCast(@min(x, 0x7FFF_FFFF));
            return piece.from + @min(nearest(text.layout.context, text.bytesOf(piece, &copy), column), piece.to - piece.from);
        }
        var at = piece.from;
        var left: u32 = 0;
        while (at < piece.to) {
            const found = text.charAt(at);
            const width = text.layout.widthOf(found.char);
            if (x < @as(i64, left) + width / 2 + (width & 1)) return at;
            left += width;
            at += @intCast(found.length);
        }
        return piece.to;
    }

    /// The text from `from` up to `to`: its own bytes where the gap is
    /// not among them, else `copy`'s, which they fit in.
    fn stretch(text: *const Text, from: u32, to: u32, copy: []u8) []const u8 {
        if (text.slice(from, to)) |own| return own;
        text.copyOut(from, to, copy.ptr);
        return copy[0 .. to - from];
    }

    /// Where the cluster that starts at `pos` ends: the character there
    /// with what Unicode keeps with it (`unicode.clusterEnd`) - its
    /// marks, the consonants a virama joins to it, what a joiner holds
    /// together - `end` at the most. A tab, a line feed or another
    /// control character is one by itself.
    pub fn clusterEnd(text: *const Text, pos: u32, end: u32) u32 {
        if (pos >= end) return end;
        const first = text.charAt(pos);
        const next = pos + @as(u32, @intCast(first.length));
        if (!isDrawn(first.char) or next >= end) return @min(next, end);
        // Nothing joins two characters of ASCII.
        if (first.char < 0x80 and text.byteAt(next) < 0x80) return next;
        var upto = @min(end, pos + cluster_room);
        if (upto < end) upto = text.charStartOf(upto);
        var copy: [cluster_room]u8 = undefined;
        return pos + @as(u32, @intCast(unicode.clusterEnd(text.stretch(pos, upto, &copy), 0)));
    }

    /// Where the cluster before `pos` starts, the one the character
    /// before `pos` is in: `floor` at the least. A control character is
    /// one by itself, and marks after one have no letter: the first of
    /// them is where they start.
    pub fn clusterBefore(text: *const Text, pos: u32, floor: u32) u32 {
        if (pos <= floor) return floor;
        const before = text.charBefore(pos);
        if (before <= floor) return floor;
        const last = text.charAt(before).char;
        if (!isDrawn(last)) return before;
        // Nothing joins two characters of ASCII.
        if (last < 0x80 and text.byteAt(before - 1) < 0x80) return before;
        var from = floor;
        if (pos - floor > cluster_room) {
            from = text.charStartOf(pos - cluster_room);
            if (from < pos - cluster_room) from = text.charAfter(from);
        }
        var copy: [cluster_room]u8 = undefined;
        const bytes = text.stretch(from, pos, &copy);
        return from + @as(u32, @intCast(unicode.clusterStart(bytes, bytes.len - 1)));
    }

    /// The part of a piece of text, `width` wide, that is wholly between
    /// `left` and `right` in its row: from the first letter that starts at
    /// `left` or after it to the last that ends at `right` or before.
    pub fn within(text: *const Text, piece: Piece, width: u32, left: i64, right: i64) Span {
        const x: i64 = piece.x;
        var span = Span{ .from = piece.from, .to = piece.to };
        if (x >= left and x + width <= right) return span;
        if (x + width <= left or x >= right) return .{ .from = piece.from, .to = piece.from };
        if (x < left) {
            span.from = text.nearIn(piece, left - x);
            if (text.placeIn(piece, span.from) < left - x) span.from = text.clusterEnd(span.from, piece.to);
        }
        if (x + width > right) {
            span.to = text.nearIn(piece, right - x);
            if (text.placeIn(piece, span.to) > right - x) span.to = text.clusterBefore(span.to, piece.from);
        }
        if (span.to < span.from) span.to = span.from;
        return span;
    }

    /// How far into `row` the place before `pos` is; `pos` is in the row
    /// or at its end.
    pub fn xInRow(text: *const Text, row: u32, pos: u32) u32 {
        if (text.layout.place == null) {
            var x: u32 = 0;
            var at = text.rowStart(row);
            while (at < pos) {
                const found = text.charAt(at);
                x += text.widthAt(found.char, x);
                at += @intCast(found.length);
            }
            return x;
        }
        var row_pieces = text.pieces(row);
        while (row_pieces.next()) |piece| {
            if (pos <= piece.from) return piece.x;
            if (pos < piece.to) return piece.x + text.placeIn(piece, pos);
        }
        return row_pieces.reach();
    }

    /// How far into its row `pos` is: the width of the row's text before it.
    pub fn xOf(text: *const Text, pos: u32) u32 {
        return text.xInRow(text.rowOf(pos), pos);
    }

    /// The position in `row` nearest `x`: before a character whose left
    /// half `x` is in, after it from its right half on.
    pub fn posAt(text: *const Text, row: u32, x: i64) u32 {
        const end = text.rowEnd(row);
        if (text.layout.nearest != null) {
            var row_pieces = text.pieces(row);
            while (row_pieces.next()) |piece| {
                const width = row_pieces.widthOf();
                const left: i64 = piece.x;
                if (x >= left + width) continue;
                if (piece.drawn) return text.nearIn(piece, x - left);
                return if (x < left + width / 2 + (width & 1)) piece.from else piece.to;
            }
            return end;
        }
        const start = text.rowStart(row);
        var at = start;
        var left: u32 = 0;
        while (at < end) {
            const found = text.charAt(at);
            const width = text.widthAt(found.char, left);
            // Where the cluster starts that the character is in: never
            // inside a syllable.
            if (x < @as(i64, left) + width / 2 + (width & 1)) return text.clusterBefore(at + @as(u32, @intCast(found.length)), start);
            left += width;
            at += @intCast(found.length);
        }
        return end;
    }

    /// The rows of the line from `start` to `end` (its line feed, or the
    /// text's end) appended to `into`.
    fn rowsOf(text: *const Text, start: u32, end: u32, into: *Positions) bool {
        if (!into.append(text.memory, start)) return false;
        const width = text.layout.wrap_width;
        if (width == 0) return true;
        var row_start = start;
        var x: u32 = 0;
        var after_space: u32 = start;
        // The cluster `at` is in: a row is not broken inside one.
        var cluster_start = start;
        var cluster_end = start;
        var at = start;
        while (at < end) {
            if (at >= cluster_end) {
                cluster_start = at;
                cluster_end = text.clusterEnd(at, end);
            }
            const found = text.charAt(at);
            const step = text.widthAt(found.char, x);
            if (x + step > width and at > row_start) {
                // Broken after the last space in the row, or before the
                // cluster that stops fitting - inside it only when it is
                // all the row holds.
                const uncut = if (cluster_start > row_start) cluster_start else at;
                const next = if (after_space > row_start) after_space else uncut;
                if (!into.append(text.memory, next)) return false;
                row_start = next;
                after_space = next;
                x = 0;
                at = next;
                cluster_end = next;
                continue;
            }
            x += step;
            at += @intCast(found.length);
            if (found.char == ' ') after_space = at;
        }
        return true;
    }

    /// The width of the line from `start` to `end`, unwrapped.
    fn lineWidth(text: *const Text, start: u32, end: u32) u32 {
        var x: u32 = 0;
        var at = start;
        while (at < end) {
            const found = text.charAt(at);
            x += text.widthAt(found.char, x);
            at += @intCast(found.length);
        }
        return x;
    }

    /// Every row made again: for a new width, a new font, wrap turned on
    /// or off, or a text set.
    pub fn relayout(text: *Text) bool {
        var rows = Positions{};
        var widest: u32 = 0;
        var line: u32 = 0;
        while (line < text.lines.len) : (line += 1) {
            const start = text.lines.get(line);
            const end = text.lineEnd(line);
            if (!text.rowsOf(start, end, &rows)) {
                rows.free(text.memory);
                return false;
            }
            if (text.layout.wrap_width == 0) widest = @max(widest, text.lineWidth(start, end));
        }
        text.rows.free(text.memory);
        text.rows = rows;
        text.widest = widest;
        return true;
    }

    /// The rows of the lines from `first` up to `end_line` made again, in
    /// place of the rows from `old_first` up to `old_end`.
    fn remakeRows(text: *Text, first: u32, end_line: u32, old_first: u32, old_end: u32) bool {
        var made = Positions{};
        defer made.free(text.memory);
        var line = first;
        while (line < end_line) : (line += 1) {
            const start = text.lines.get(line);
            const end = text.lineEnd(line);
            if (!text.rowsOf(start, end, &made)) return false;
            if (text.layout.wrap_width == 0) text.widest = @max(text.widest, text.lineWidth(start, end));
        }
        const values: []const u32 = if (made.items) |items| items[0..made.len] else &.{};
        return text.rows.replace(text.memory, old_first, old_end, values);
    }

    // --- editing ------------------------------------------------------------

    /// `bytes` put in at `pos`. False with nothing changed when there is
    /// no memory for it.
    pub fn insert(text: *Text, pos: u32, bytes: []const u8) bool {
        if (bytes.len == 0) return true;
        const count: u32 = @intCast(bytes.len);
        var feeds: u32 = 0;
        for (bytes) |byte| feeds += @intFromBool(byte == '\n');
        // Room for the line starts and their rows first, so that nothing
        // fails once the text has changed.
        if (!text.lines.reserve(text.memory, feeds)) return false;
        const line = text.lineOf(pos);
        const old_first = text.firstRow(line);
        const old_end = if (line + 1 < text.lines.len) text.firstRow(line + 1) else text.rows.len;
        if (!text.gapAt(pos, count)) return false;
        @memcpy(text.bytes.?[pos..][0..count], bytes);
        text.gap_start += count;

        text.lines.shift(line + 1, count);
        var starts: [64]u32 = undefined;
        var at: u32 = line + 1;
        var held: usize = 0;
        for (bytes, 0..) |byte, offset| {
            if (byte != '\n') continue;
            starts[held] = pos + @as(u32, @intCast(offset)) + 1;
            held += 1;
            if (held == starts.len) {
                _ = text.lines.replace(text.memory, at, at, starts[0..held]);
                at += @intCast(held);
                held = 0;
            }
        }
        if (held != 0) _ = text.lines.replace(text.memory, at, at, starts[0..held]);
        text.rows.shift(old_end, count);
        if (!text.remakeRows(line, line + 1 + feeds, old_first, old_end)) return text.relayout();
        return true;
    }

    /// The bytes from `from` up to `to` taken out.
    pub fn remove(text: *Text, from: u32, to: u32) void {
        if (from >= to) return;
        const count = to - from;
        const first_line = text.lineOf(from);
        const last_line = text.lineOf(to);
        const old_first = text.firstRow(first_line);
        const old_end = if (last_line + 1 < text.lines.len) text.firstRow(last_line + 1) else text.rows.len;
        // A line that was the widest may be gone or shorter.
        var was_widest = false;
        if (text.layout.wrap_width == 0) {
            var line = first_line;
            while (line <= last_line) : (line += 1) {
                if (text.lineWidth(text.lines.get(line), text.lineEnd(line)) >= text.widest) was_widest = true;
            }
        }
        _ = text.gapAt(from, 0);
        text.gap_end += count;

        _ = text.lines.replace(text.memory, first_line + 1, last_line + 1, &.{});
        text.lines.shift(first_line + 1, -@as(i64, count));
        text.rows.shift(old_end, -@as(i64, count));
        if (!text.remakeRows(first_line, first_line + 1, old_first, old_end) or was_widest) _ = text.relayout();
    }

    // --- words and searching ------------------------------------------------

    /// A letter, a digit or an underscore: ASCII's, and every character
    /// from U+00C0 on but the signs and punctuation - × and ÷, the
    /// punctuation and symbol blocks from U+2000 to U+2BFF, the CJK
    /// punctuation and the pictographs.
    pub fn isWordChar(char: u32) bool {
        if (char < 0x80) return (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or
            (char >= '0' and char <= '9') or char == '_';
        if (char < 0xC0 or char == 0xD7 or char == 0xF7) return false;
        if (char >= 0x2000 and char <= 0x2BFF) return false;
        if (char >= 0x3000 and char <= 0x303F) return false;
        return !(char >= 0x1F000 and char <= 0x1FAFF);
    }

    /// Whether the character before `pos`, above 0, is a word's.
    fn wordBehind(text: *const Text, pos: u32) bool {
        return isWordChar(text.charAt(text.charBefore(pos)).char);
    }

    /// The start of the word `pos` is in or after; past spaces and
    /// punctuation going back.
    pub fn wordBefore(text: *const Text, pos: u32) u32 {
        var at = pos;
        while (at > 0 and !text.wordBehind(at)) at = text.charBefore(at);
        while (at > 0 and text.wordBehind(at)) at = text.charBefore(at);
        return at;
    }

    /// The end of the word at or after `pos`.
    pub fn wordAfter(text: *const Text, pos: u32) u32 {
        const len = text.length();
        var at = pos;
        while (at < len and !isWordChar(text.charAt(at).char)) at = text.charAfter(at);
        while (at < len and isWordChar(text.charAt(at).char)) at = text.charAfter(at);
        return at;
    }

    /// The word around `pos`, for a double press.
    pub fn wordAround(text: *const Text, pos: u32) Span {
        const len = text.length();
        var from = pos;
        var to = pos;
        if (pos < len and isWordChar(text.charAt(pos).char)) {
            while (from > 0 and text.wordBehind(from)) from = text.charBefore(from);
            while (to < len and isWordChar(text.charAt(to).char)) to = text.charAfter(to);
        } else if (pos < len and text.byteAt(pos) != '\n') {
            to = text.charAfter(pos);
        }
        return .{ .from = from, .to = to };
    }

    /// The line around `pos`, for a third press: from its start to the
    /// next one's, its line feed with it, so that cutting it leaves no
    /// empty line behind.
    pub fn lineAround(text: *const Text, pos: u32) Span {
        const line = text.lineOf(pos);
        const to = if (line + 1 < text.lines.len) text.lines.get(line + 1) else text.length();
        return .{ .from = text.lineStart(line), .to = to };
    }

    /// Where `needle`, UTF-8, ends when it is at `pos`, compared a
    /// character at a time - by simple case folding with `any_case` -
    /// so the match may be longer or shorter than the needle; null when
    /// it is not there.
    pub fn matchAt(text: *const Text, pos: u32, needle: []const u8, any_case: bool) ?u32 {
        const len = text.length();
        var at = pos;
        var offset: usize = 0;
        while (offset < needle.len) {
            if (at >= len) return null;
            const want = utf8.read(needle[offset..]);
            const have = text.charAt(at);
            const same = if (any_case) unicode.fold(want.char) == unicode.fold(have.char) else want.char == have.char;
            if (!same) return null;
            offset += want.length;
            at += @intCast(have.length);
        }
        return at;
    }

    /// Where `needle` is next from `from` on - or, `backwards`, last
    /// before `from` - going round past the end, a character at a time
    /// from `from`, which is where one starts; null when it is nowhere.
    pub fn find(text: *const Text, from: u32, needle: []const u8, backwards: bool, any_case: bool) ?Span {
        const len = text.length();
        if (needle.len == 0 or len == 0) return null;
        var at: u32 = if (backwards) (if (from == 0) len else from) else (if (from >= len) 0 else from);
        var tried: u32 = 0;
        while (tried <= len) : (tried += 1) {
            if (backwards) at = text.charBefore(if (at == 0) len else at);
            if (text.matchAt(at, needle, any_case)) |end| return .{ .from = at, .to = end };
            if (!backwards) {
                at = text.charAfter(at);
                if (at >= len) at = 0;
            }
        }
        return null;
    }
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

/// The testing allocator, with each block's size kept in front of it.
const test_memory = Memory{ .alloc = testAlloc, .free = testFree };

fn testAlloc(_: ?*anyopaque, size: u32) ?[*]u8 {
    const block = testing.allocator.alignedAlloc(u8, .@"8", size + 8) catch return null;
    std.mem.writeInt(u64, block[0..8], size, .little);
    return block.ptr + 8;
}

fn testFree(_: ?*anyopaque, memory: [*]u8) void {
    const start = memory - 8;
    const size = std.mem.readInt(u64, start[0..8], .little);
    testing.allocator.free(@as([*]align(8) u8, @alignCast(start))[0 .. size + 8]);
}

fn whole(text: *const Text, into: []u8) []u8 {
    const len = text.length();
    text.copyOut(0, len, into.ptr);
    return into[0..len];
}

fn rowText(text: *const Text, row: u32, into: []u8) []u8 {
    const from = text.rowStart(row);
    const to = text.rowEnd(row);
    text.copyOut(from, to, into.ptr);
    return into[0 .. to - from];
}

test "the gap buffer: text put in and taken out anywhere reads back whole" {
    var text = Text.init(test_memory).?;
    defer text.deinit();
    var buffer: [64]u8 = undefined;
    try testing.expect(text.insert(0, "world"));
    try testing.expect(text.insert(0, "hello "));
    try testing.expect(text.insert(text.length(), "!"));
    try testing.expectEqualStrings("hello world!", whole(&text, &buffer));
    text.remove(5, 11);
    try testing.expectEqualStrings("hello!", whole(&text, &buffer));
    try testing.expect(text.insert(5, ", you"));
    try testing.expectEqualStrings("hello, you!", whole(&text, &buffer));
    try testing.expectEqual(@as(u8, 'y'), text.byteAt(7));
    // A piece on one side of the gap comes as a slice; across it, not.
    try testing.expectEqualStrings("hello", text.slice(0, 5).?);
}

test "lines follow every edit: line feeds put in, taken out, and the starts after them" {
    var text = Text.init(test_memory).?;
    defer text.deinit();
    try testing.expect(text.setAll("one\ntwo\nthree"));
    try testing.expectEqual(@as(u32, 3), text.lineCount());
    try testing.expectEqual(@as(u32, 4), text.lineStart(1));
    try testing.expectEqual(@as(u32, 7), text.lineEnd(1));
    try testing.expectEqual(@as(u32, 2), text.lineOf(9));
    // A line feed in the middle of "two" makes a fourth line.
    try testing.expect(text.insert(5, "\n"));
    try testing.expectEqual(@as(u32, 4), text.lineCount());
    try testing.expectEqual(@as(u32, 6), text.lineStart(2));
    try testing.expectEqual(@as(u32, 9), text.lineStart(3));
    // Taking out "o\ntw" (positions 2..6) joins the first lines again.
    text.remove(2, 6);
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("onwo\nthree", whole(&text, &buffer));
    try testing.expectEqual(@as(u32, 2), text.lineCount());
    try testing.expectEqual(@as(u32, 5), text.lineStart(1));
    // Rows without wrap are the lines.
    try testing.expectEqual(@as(u32, 2), text.rowCount());
    try testing.expectEqual(@as(u32, 5), text.rowStart(1));
    try testing.expectEqual(@as(u32, 5), text.widest);
}

test "wrap: rows broken after the last space that fits, or where a word stops fitting" {
    var text = Text.init(test_memory).?;
    defer text.deinit();
    text.layout.wrap_width = 10;
    try testing.expect(text.setAll("the quick brown fox\nabcdefghijklmnopqrstuvwxyz\n"));
    var buffer: [64]u8 = undefined;
    try testing.expectEqual(@as(u32, 6), text.rowCount());
    try testing.expectEqualStrings("the quick ", rowText(&text, 0, &buffer));
    try testing.expectEqualStrings("brown fox", rowText(&text, 1, &buffer));
    try testing.expectEqualStrings("abcdefghij", rowText(&text, 2, &buffer));
    try testing.expectEqualStrings("klmnopqrst", rowText(&text, 3, &buffer));
    try testing.expectEqualStrings("uvwxyz", rowText(&text, 4, &buffer));
    // The empty line after the last line feed is a row of its own.
    try testing.expectEqualStrings("", rowText(&text, 5, &buffer));
    // An edit in the first line makes its rows again and moves the rest.
    try testing.expect(text.insert(4, "very "));
    try testing.expectEqualStrings("the very ", rowText(&text, 0, &buffer));
    try testing.expectEqualStrings("quick ", rowText(&text, 1, &buffer));
    try testing.expectEqualStrings("brown fox", rowText(&text, 2, &buffer));
    try testing.expectEqualStrings("abcdefghij", rowText(&text, 3, &buffer));
    try testing.expectEqual(@as(u32, 7), text.rowCount());
    // Wrap off: a row per line again.
    text.layout.wrap_width = 0;
    try testing.expect(text.relayout());
    try testing.expectEqual(@as(u32, 3), text.rowCount());
    try testing.expectEqual(@as(u32, 26), text.widest);
}

test "positions and widths: tabs to the next stop, a press nearest a byte's edge" {
    var text = Text.init(test_memory).?;
    defer text.deinit();
    try testing.expect(text.setAll("ab\tc\nxy"));
    try testing.expectEqual(@as(u32, 2), text.xOf(2));
    // The tab goes from 2 to the stop at 8.
    try testing.expectEqual(@as(u32, 8), text.xOf(3));
    try testing.expectEqual(@as(u32, 9), text.xOf(4));
    try testing.expectEqual(@as(u32, 0), text.posAt(0, 0));
    try testing.expectEqual(@as(u32, 1), text.posAt(0, 1));
    try testing.expectEqual(@as(u32, 2), text.posAt(0, 3));
    try testing.expectEqual(@as(u32, 3), text.posAt(0, 6));
    try testing.expectEqual(@as(u32, 4), text.posAt(0, 50));
    try testing.expectEqual(@as(u32, 7), text.posAt(1, 50));
}

/// A font for the tests that shapes its text: every letter 4 wide, an
/// `A` before a `V` 2 narrower, and a mark that takes no room and has no
/// place before it.
fn shapedPlace(_: ?*anyopaque, bytes: []const u8, offset: u32) u32 {
    var upto: usize = @min(offset, bytes.len);
    while (upto < bytes.len and unicode.width(utf8.read(bytes[upto..]).char) == 0) upto += utf8.read(bytes[upto..]).length;
    var x: u32 = 0;
    var at: usize = 0;
    while (at < upto) {
        const found = utf8.read(bytes[at..]);
        at += found.length;
        if (unicode.width(found.char) != 0) x += 4;
        if (found.char == 'A' and at < bytes.len and bytes[at] == 'V') x -= 2;
    }
    return x;
}

fn shapedNearest(context: ?*anyopaque, bytes: []const u8, x: i32) u32 {
    var at: usize = 0;
    while (at < bytes.len) {
        var next = at + utf8.read(bytes[at..]).length;
        while (next < bytes.len and unicode.width(utf8.read(bytes[next..]).char) == 0) next += utf8.read(bytes[next..]).length;
        const here = shapedPlace(context, bytes, @intCast(at));
        const there = shapedPlace(context, bytes, @intCast(next));
        if (2 * @as(i64, x) < here + there) return @intCast(at);
        at = next;
    }
    return @intCast(bytes.len);
}

test "a font that shapes: a position is where its piece is drawn, a press the nearest place" {
    var text = Text.init(test_memory).?;
    defer text.deinit();
    text.layout.place = shapedPlace;
    text.layout.nearest = shapedNearest;
    text.layout.tab_stop = 16;
    try testing.expect(text.setAll("AVA\tAV"));
    // The first `A` is 2 wide before its `V`; the tab goes from 10 to 16.
    const places = [_]u32{ 0, 2, 6, 10, 16, 18, 22 };
    for (places, 0..) |place, pos| try testing.expectEqual(place, text.xOf(@intCast(pos)));
    try testing.expectEqual(@as(u32, 0), text.posAt(0, -5));
    try testing.expectEqual(@as(u32, 0), text.posAt(0, 0));
    try testing.expectEqual(@as(u32, 1), text.posAt(0, 1));
    try testing.expectEqual(@as(u32, 1), text.posAt(0, 3));
    try testing.expectEqual(@as(u32, 2), text.posAt(0, 4));
    // Either half of the tab.
    try testing.expectEqual(@as(u32, 3), text.posAt(0, 12));
    try testing.expectEqual(@as(u32, 4), text.posAt(0, 13));
    try testing.expectEqual(@as(u32, 5), text.posAt(0, 17));
    try testing.expectEqual(@as(u32, 6), text.posAt(0, 100));

    // A letter and its mark are one place: no press lands between them,
    // and the cursor on the letter covers both.
    try testing.expect(text.setAll("e\u{301}x"));
    try testing.expectEqual(@as(u32, 3), text.clusterEnd(0, text.length()));
    try testing.expectEqual(@as(u32, 0), text.clusterBefore(3, 0));
    try testing.expectEqual(@as(u32, 3), text.clusterBefore(4, 0));
    try testing.expectEqual(@as(u32, 4), text.xOf(3));
    try testing.expectEqual(@as(u32, 8), text.xOf(4));
    try testing.expectEqual(@as(u32, 0), text.posAt(0, 1));
    try testing.expectEqual(@as(u32, 3), text.posAt(0, 3));
    try testing.expectEqual(@as(u32, 4), text.posAt(0, 7));
    // A mark at a line's start has no letter: the line feed before it
    // is stepped over by itself, either way.
    try testing.expect(text.setAll("a\n\u{301}b"));
    try testing.expectEqual(@as(u32, 2), text.clusterEnd(1, text.length()));
    try testing.expectEqual(@as(u32, 2), text.clusterBefore(4, 0));
    try testing.expectEqual(@as(u32, 1), text.clusterBefore(2, 0));
}

test "pieces: text between tabs, a long stretch cut before a word or a letter, and what of one is in view" {
    var text = Text.init(test_memory).?;
    defer text.deinit();
    text.layout.place = shapedPlace;
    text.layout.nearest = shapedNearest;
    text.layout.tab_stop = 16;
    var long: [600]u8 = undefined;

    // No space to cut at: `piece_room` bytes each.
    @memset(&long, 'a');
    try testing.expect(text.setAll(&long));
    var solid = text.pieces(0);
    try testing.expectEqual(Piece{ .from = 0, .to = 256, .x = 0, .drawn = true }, solid.next().?);
    try testing.expectEqual(Piece{ .from = 256, .to = 512, .x = 1024, .drawn = true }, solid.next().?);
    try testing.expectEqual(Piece{ .from = 512, .to = 600, .x = 2048, .drawn = true }, solid.next().?);
    try testing.expectEqual(@as(?Piece, null), solid.next());
    try testing.expectEqual(@as(u32, 2400), solid.reach());
    try testing.expectEqual(@as(u32, 2400), text.xOf(600));
    try testing.expectEqual(@as(u32, 300), text.posAt(0, 1201));

    // Words: cut before the first that starts 192 bytes in.
    for (&long, 0..) |*byte, index| byte.* = if (index % 5 == 4) ' ' else 'w';
    try testing.expect(text.setAll(long[0..500]));
    var words = text.pieces(0);
    try testing.expectEqual(@as(u32, 195), words.next().?.to);
    try testing.expectEqual(@as(u32, 390), words.next().?.to);
    try testing.expectEqual(@as(u32, 500), words.next().?.to);

    // A letter is not parted from its mark where the room ends.
    @memset(long[0..255], 'a');
    @memcpy(long[255..258], "e\u{301}");
    try testing.expect(text.setAll(long[0..258]));
    var marked = text.pieces(0);
    try testing.expectEqual(@as(u32, 255), marked.next().?.to);
    try testing.expectEqual(@as(u32, 258), marked.next().?.to);

    // A tab and a control character are pieces of their own.
    try testing.expect(text.setAll("ab\tc\x01d"));
    var mixed = text.pieces(0);
    try testing.expectEqual(Piece{ .from = 0, .to = 2, .x = 0, .drawn = true }, mixed.next().?);
    try testing.expectEqual(Piece{ .from = 2, .to = 3, .x = 8, .drawn = false }, mixed.next().?);
    try testing.expectEqual(Piece{ .from = 3, .to = 4, .x = 16, .drawn = true }, mixed.next().?);
    try testing.expectEqual(Piece{ .from = 4, .to = 5, .x = 20, .drawn = false }, mixed.next().?);

    // What of a piece is wholly inside a view: letters cut by either
    // edge are left out.
    try testing.expect(text.setAll("aaaaaaaa"));
    var one = text.pieces(0);
    const piece = one.next().?;
    try testing.expectEqual(Span{ .from = 0, .to = 8 }, text.within(piece, 32, 0, 32));
    try testing.expectEqual(Span{ .from = 2, .to = 6 }, text.within(piece, 32, 5, 27));
    try testing.expectEqual(Span{ .from = 1, .to = 7 }, text.within(piece, 32, 4, 28));
    try testing.expectEqual(Span{ .from = 0, .to = 0 }, text.within(piece, 32, 40, 50));
}

test "words, and finding text forwards, backwards, in any case and round the end" {
    var text = Text.init(test_memory).?;
    defer text.deinit();
    try testing.expect(text.setAll("Hello, wide world. Hello again"));
    try testing.expectEqual(@as(u32, 7), text.wordBefore(10));
    try testing.expectEqual(@as(u32, 11), text.wordAfter(7));
    const word = text.wordAround(13);
    try testing.expectEqual(@as(u32, 12), word.from);
    try testing.expectEqual(@as(u32, 17), word.to);
    try testing.expectEqual(@as(u32, 19), text.find(1, "Hello", false, false).?.from);
    try testing.expectEqual(@as(u32, 0), text.find(20, "Hello", false, false).?.from);
    try testing.expectEqual(@as(u32, 0), text.find(19, "Hello", true, false).?.from);
    const world = text.find(0, "WORLD", false, true).?;
    try testing.expectEqual(@as(u32, 12), world.from);
    try testing.expectEqual(@as(u32, 17), world.to);
    try testing.expectEqual(@as(?Span, null), text.find(0, "WORLD", false, false));
}

test "UTF-8: characters stepped over whole, measured, wrapped, words and finding by folded case" {
    var text = Text.init(test_memory).?;
    defer text.deinit();
    // € past U+00FF is measured: three wide here.
    text.layout.measure = &struct {
        fn three(_: ?*anyopaque, _: u32) u16 {
            return 3;
        }
    }.three;
    try testing.expect(text.setAll("Grüße €5\nÄpfel"));
    // G r ü ß e: ü and ß two bytes each.
    try testing.expectEqual(@as(u32, 2), text.charAfter(2) - 2);
    try testing.expectEqual(@as(u32, 2), text.charBefore(4));
    try testing.expectEqual(@as(u32, 0xDF), text.charAt(4).char);
    try testing.expectEqual(@as(u32, 5), text.charsBetween(0, 7));
    try testing.expectEqual(@as(u32, 8), text.charStartOf(10));
    try testing.expectEqual(@as(u32, 11), text.charStartOf(11));
    // Each character one wide, the € three: the 5 after it at 6 + 3.
    try testing.expectEqual(@as(u32, 9), text.xOf(11));
    try testing.expectEqual(@as(u32, 8), text.posAt(0, 7));
    try testing.expectEqual(@as(u32, 11), text.posAt(0, 9));
    // Words take letters past ASCII; the euro sign is none.
    try testing.expectEqual(@as(u32, 0), text.wordBefore(7));
    try testing.expectEqual(@as(u32, 7), text.wordAfter(0));
    try testing.expectEqual(@as(u32, 11), text.wordAround(8).to);
    // Found by folded case, across characters of other lengths.
    const apples = text.find(0, "äpfel", false, true).?;
    try testing.expectEqual(@as(u32, 13), apples.from);
    try testing.expectEqual(@as(u32, 19), apples.to);
    try testing.expectEqual(@as(?Span, null), text.find(0, "äpfel", false, false));
    try testing.expectEqual(@as(u32, 1), text.find(13, "RÜ", true, true).?.from);
    // Wrapped at five: never inside a character.
    text.layout.wrap_width = 5;
    try testing.expect(text.relayout());
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("Grüße", rowText(&text, 0, &buffer));
    try testing.expectEqualStrings(" €5", rowText(&text, 1, &buffer));
}

test "clusters: a syllable and a joined sequence are one step, one piece and never broken across rows" {
    var text = Text.init(test_memory).?;
    defer text.deinit();
    // क्ष is three characters of three bytes, one cluster; ति is two.
    try testing.expect(text.setAll("aक्षति b"));
    try testing.expectEqual(@as(u32, 1), text.clusterEnd(0, text.length()));
    try testing.expectEqual(@as(u32, 10), text.clusterEnd(1, text.length()));
    try testing.expectEqual(@as(u32, 16), text.clusterEnd(10, text.length()));
    try testing.expectEqual(@as(u32, 17), text.clusterEnd(16, text.length()));
    try testing.expectEqual(@as(u32, 10), text.clusterBefore(16, 0));
    try testing.expectEqual(@as(u32, 1), text.clusterBefore(10, 0));
    try testing.expectEqual(@as(u32, 0), text.clusterBefore(1, 0));
    try testing.expectEqual(@as(u32, 17), text.clusterBefore(18, 0));
    // Never past the bounds asked for, and what is between them is
    // taken by itself: a consonant behind a virama that joins nothing.
    try testing.expectEqual(@as(u32, 7), text.clusterEnd(1, 7));
    try testing.expectEqual(@as(u32, 7), text.clusterBefore(10, 4));
    try testing.expectEqual(@as(u32, 4), text.clusterBefore(7, 4));

    // The same with the gap inside the syllable: an edit there and one
    // taken back leaves it.
    try testing.expect(text.insert(4, "x"));
    text.remove(4, 5);
    try testing.expectEqual(@as(u32, 10), text.clusterEnd(1, text.length()));
    try testing.expectEqual(@as(u32, 1), text.clusterBefore(10, 0));

    // A line feed and a tab are steps of their own, marks behind one too.
    try testing.expect(text.setAll("a\n\u{301}\u{302}b\tc"));
    try testing.expectEqual(@as(u32, 2), text.clusterEnd(1, text.length()));
    try testing.expectEqual(@as(u32, 6), text.clusterEnd(2, text.length()));
    try testing.expectEqual(@as(u32, 2), text.clusterBefore(6, 0));
    try testing.expectEqual(@as(u32, 1), text.clusterBefore(2, 0));
    try testing.expectEqual(@as(u32, 7), text.clusterBefore(8, 0));

    // Two people a joiner holds together, and a flag: one step each.
    try testing.expect(text.setAll("\u{1F468}\u{200D}\u{1F469}\u{1F1E9}\u{1F1EA}!"));
    try testing.expectEqual(@as(u32, 11), text.clusterEnd(0, text.length()));
    try testing.expectEqual(@as(u32, 19), text.clusterEnd(11, text.length()));
    try testing.expectEqual(@as(u32, 11), text.clusterBefore(19, 0));
    try testing.expectEqual(@as(u32, 0), text.clusterBefore(11, 0));

    // Rows: every character one wide, three to a row. The syllable's
    // three characters stay in one row, where a letter at a time would
    // have put the first of them beside the a.
    try testing.expect(text.setAll("abक्षक्षc"));
    text.layout.wrap_width = 3;
    text.layout.measure = &struct {
        fn one(_: ?*anyopaque, _: u32) u16 {
            return 1;
        }
    }.one;
    try testing.expect(text.relayout());
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("ab", rowText(&text, 0, &buffer));
    try testing.expectEqualStrings("क्ष", rowText(&text, 1, &buffer));
    try testing.expectEqualStrings("क्ष", rowText(&text, 2, &buffer));
    try testing.expectEqualStrings("c", rowText(&text, 3, &buffer));
    // A press on the syllable's second consonant is a press on the
    // syllable: the cursor goes before it.
    try testing.expectEqual(@as(u32, 2), text.posAt(1, 2));
    try testing.expectEqual(@as(u32, 11), text.posAt(1, 3));
    // A cluster wider than the row is broken where it stops fitting.
    text.layout.wrap_width = 2;
    try testing.expect(text.relayout());
    try testing.expectEqualStrings("ab", rowText(&text, 0, &buffer));
    try testing.expectEqualStrings("क्", rowText(&text, 1, &buffer));

    // Pieces: 254 bytes and then syllables of nine - the cut for room
    // goes before the syllable that does not fit whole, not into it.
    text.layout.wrap_width = 0;
    var long: [300]u8 = undefined;
    @memset(long[0..250], 'a');
    var at: usize = 250;
    while (at + 9 <= long.len) : (at += 9) @memcpy(long[at..][0..9], "क्ष");
    try testing.expect(text.setAll(long[0..at]));
    var row = text.pieces(0);
    try testing.expectEqual(@as(u32, 250), row.next().?.to);
}

test "a line for a third press, and the indentation Return carries on" {
    var text = Text.init(test_memory).?;
    defer text.deinit();
    try testing.expect(text.setAll("top\n  \tin it\n    \nend"));
    const second = text.lineAround(7);
    try testing.expectEqual(@as(u32, 4), second.from);
    try testing.expectEqual(@as(u32, 13), second.to);
    const last = text.lineAround(19);
    try testing.expectEqual(@as(u32, 18), last.from);
    try testing.expectEqual(@as(u32, 21), last.to);
    // The whole indentation from inside the line, and only what is
    // before the cursor from inside the indentation.
    const indented = text.indentOf(10);
    try testing.expectEqual(@as(u32, 4), indented.from);
    try testing.expectEqual(@as(u32, 7), indented.to);
    try testing.expectEqual(@as(u32, 6), text.indentOf(6).to);
    try testing.expectEqual(@as(u32, 17), text.indentOf(17).to);
    const none = text.indentOf(2);
    try testing.expectEqual(none.from, none.to);
}

test "a long text set at once, and many lines put in one edit" {
    var text = Text.init(test_memory).?;
    defer text.deinit();
    var big: [6000]u8 = undefined;
    for (&big, 0..) |*byte, at| byte.* = if (at % 10 == 9) '\n' else 'a' + @as(u8, @intCast(at % 10));
    try testing.expect(text.setAll(&big));
    try testing.expectEqual(@as(u32, 601), text.lineCount());
    try testing.expect(text.insert(0, &big));
    try testing.expectEqual(@as(u32, 1201), text.lineCount());
    try testing.expectEqual(@as(u32, 1201), text.rowCount());
    try testing.expectEqual(@as(u32, 6010), text.lineStart(601));
    text.remove(0, 6000);
    try testing.expectEqual(@as(u32, 601), text.lineCount());
    try testing.expectEqual(@as(u32, 10), text.lineStart(1));
}
