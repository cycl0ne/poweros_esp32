// SPDX-License-Identifier: MIT
//! The text a textedit.gadget holds and the rows it makes on the screen:
//! nothing here draws or asks a library, so the host tests hold all of it.
//!
//! **The bytes** are in a gap buffer: one allocation with a hole at the
//! place last edited, so typing at one place moves nothing but the hole.
//! A position is a byte's index in the text as it reads, the hole left
//! out; `length` is the text's size.
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
//! Widths come from a table of each byte's width in the font
//! (`Layout.widths`) and the tab stop, so laying text out costs no calls;
//! the gadget measures what it draws with the font itself.

const std = @import("std");

/// Where the text's memory comes from: exec's AllocVec and FreeVec in the
/// gadget, the testing allocator in the tests.
pub const Memory = struct {
    context: ?*anyopaque = null,
    alloc: *const fn (context: ?*anyopaque, size: u32) ?[*]u8,
    free: *const fn (context: ?*anyopaque, memory: [*]u8) void,
};

/// A stretch of the text, from `from` up to `to`.
pub const Span = struct { from: u32, to: u32 };

/// How the text is laid out: each byte's width, where tabs stop, and the
/// width rows wrap at (0: they do not).
pub const Layout = struct {
    widths: [256]u16 = @splat(1),
    /// Pixels between tab stops: eight spaces.
    tab_stop: u32 = 8,
    wrap_width: u32 = 0,
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

    /// The width of a byte at `x` from its row's start.
    pub fn widthAt(text: *const Text, byte: u8, x: u32) u32 {
        if (byte == '\t') {
            const stop = @max(text.layout.tab_stop, 1);
            return (x / stop + 1) * stop - x;
        }
        return text.layout.widths[byte];
    }

    /// How far into its row `pos` is: the width of the row's text before it.
    pub fn xOf(text: *const Text, pos: u32) u32 {
        const row = text.rowOf(pos);
        var x: u32 = 0;
        var at = text.rowStart(row);
        while (at < pos) : (at += 1) x += text.widthAt(text.byteAt(at), x);
        return x;
    }

    /// The position in `row` nearest `x`: before a byte whose left half
    /// `x` is in, after it from its right half on.
    pub fn posAt(text: *const Text, row: u32, x: i64) u32 {
        const end = text.rowEnd(row);
        var at = text.rowStart(row);
        var left: u32 = 0;
        while (at < end) : (at += 1) {
            const width = text.widthAt(text.byteAt(at), left);
            if (x < @as(i64, left) + width / 2 + (width & 1)) return at;
            left += width;
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
        var at = start;
        while (at < end) {
            const byte = text.byteAt(at);
            const step = text.widthAt(byte, x);
            if (x + step > width and at > row_start) {
                // Broken after the last space in the row, or where it
                // stops fitting.
                const next = if (after_space > row_start) after_space else at;
                if (!into.append(text.memory, next)) return false;
                row_start = next;
                after_space = next;
                x = 0;
                at = next;
                continue;
            }
            x += step;
            at += 1;
            if (byte == ' ') after_space = at;
        }
        return true;
    }

    /// The width of the line from `start` to `end`, unwrapped.
    fn lineWidth(text: *const Text, start: u32, end: u32) u32 {
        var x: u32 = 0;
        var at = start;
        while (at < end) : (at += 1) x += text.widthAt(text.byteAt(at), x);
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

    /// A letter, a digit or an underscore, Latin-1's letters among them.
    pub fn isWordByte(byte: u8) bool {
        return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or
            (byte >= '0' and byte <= '9') or byte == '_' or (byte >= 0xC0 and byte != 0xD7 and byte != 0xF7);
    }

    /// The start of the word `pos` is in or after; past spaces and
    /// punctuation going back.
    pub fn wordBefore(text: *const Text, pos: u32) u32 {
        var at = pos;
        while (at > 0 and !isWordByte(text.byteAt(at - 1))) at -= 1;
        while (at > 0 and isWordByte(text.byteAt(at - 1))) at -= 1;
        return at;
    }

    /// The end of the word at or after `pos`.
    pub fn wordAfter(text: *const Text, pos: u32) u32 {
        const len = text.length();
        var at = pos;
        while (at < len and !isWordByte(text.byteAt(at))) at += 1;
        while (at < len and isWordByte(text.byteAt(at))) at += 1;
        return at;
    }

    /// The word around `pos`, for a double press.
    pub fn wordAround(text: *const Text, pos: u32) Span {
        const len = text.length();
        var from = pos;
        var to = pos;
        if (pos < len and isWordByte(text.byteAt(pos))) {
            while (from > 0 and isWordByte(text.byteAt(from - 1))) from -= 1;
            while (to < len and isWordByte(text.byteAt(to))) to += 1;
        } else if (pos < len and text.byteAt(pos) != '\n') {
            to = pos + 1;
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

    fn lower(byte: u8) u8 {
        if (byte >= 'A' and byte <= 'Z') return byte + ('a' - 'A');
        if (byte >= 0xC0 and byte <= 0xDE and byte != 0xD7) return byte + 0x20;
        return byte;
    }

    /// Whether `needle` is at `pos`.
    pub fn matchAt(text: *const Text, pos: u32, needle: []const u8, any_case: bool) bool {
        if (pos + needle.len > text.length()) return false;
        for (needle, 0..) |want, offset| {
            var have = text.byteAt(pos + @as(u32, @intCast(offset)));
            var wanted = want;
            if (any_case) {
                have = lower(have);
                wanted = lower(wanted);
            }
            if (have != wanted) return false;
        }
        return true;
    }

    /// Where `needle` is next from `from` on - or, `backwards`, last
    /// before `from` - going round past the end; null when it is nowhere.
    pub fn find(text: *const Text, from: u32, needle: []const u8, backwards: bool, any_case: bool) ?u32 {
        const len = text.length();
        if (needle.len == 0 or needle.len > len) return null;
        const last: u32 = len - @as(u32, @intCast(needle.len));
        var tried: u32 = 0;
        var at: u32 = if (backwards) (if (from == 0) last else @min(from - 1, last)) else (if (from > last) 0 else from);
        while (tried <= last) : (tried += 1) {
            if (text.matchAt(at, needle, any_case)) return at;
            if (backwards) {
                at = if (at == 0) last else at - 1;
            } else {
                at = if (at == last) 0 else at + 1;
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

test "words, and finding text forwards, backwards, in any case and round the end" {
    var text = Text.init(test_memory).?;
    defer text.deinit();
    try testing.expect(text.setAll("Hello, wide world. Hello again"));
    try testing.expectEqual(@as(u32, 7), text.wordBefore(10));
    try testing.expectEqual(@as(u32, 11), text.wordAfter(7));
    const word = text.wordAround(13);
    try testing.expectEqual(@as(u32, 12), word.from);
    try testing.expectEqual(@as(u32, 17), word.to);
    try testing.expectEqual(@as(?u32, 19), text.find(1, "Hello", false, false));
    try testing.expectEqual(@as(?u32, 0), text.find(20, "Hello", false, false));
    try testing.expectEqual(@as(?u32, 0), text.find(19, "Hello", true, false));
    try testing.expectEqual(@as(?u32, 12), text.find(0, "WORLD", false, true));
    try testing.expectEqual(@as(?u32, null), text.find(0, "WORLD", false, false));
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
