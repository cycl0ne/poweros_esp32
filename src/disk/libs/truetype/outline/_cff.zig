// SPDX-License-Identifier: MIT
//! A font's `CFF ` table as the library reads it: the glyphs of a font
//! whose outlines are lines and cubic curves. Since 1.6.
//!
//! The table is a header and four lists one after the other - the names,
//! the top dictionaries, the strings and the global subroutines - and,
//! where the first top dictionary says, the glyphs' programs
//! (`CharStrings`) and the private dictionary with its local
//! subroutines. A font keyed by a character collection (CID) has a list
//! of font dictionaries in place of the one private dictionary, each
//! with a private one and subroutines of its own, and a table saying
//! which of them a glyph belongs to (`FDSelect`). A list (`Index`) is a
//! count, the size of an offset, one offset more than it has entries,
//! and the entries' bytes; a dictionary is numbers, each run of them
//! followed by the operator it belongs to.
//!
//! A glyph's program is a Type 2 charstring: numbers pushed on a stack,
//! and operators that draw with them from the point before - a move, a
//! line, a cubic curve - or work on the stack, or call a subroutine, by
//! its number plus a bias the length of its list sets. The stem hints
//! are counted, because a hint mask is as many bits long as the glyph
//! has stems, and otherwise passed over. The first operator that takes
//! the stack whole may find one number more than it takes: the glyph's
//! width, which is dropped - a glyph's advance is `hmtx`'s.
//!
//! A contour comes out as the program draws it: the point moved to, then
//! one point a line and three a curve - two control points (`cubic`) and
//! the point on the curve it ends at. A move ends the contour before it,
//! and a point moved to that nothing is drawn from is no contour.
//!
//! The table names no largest glyph, so a glyph is read into what room
//! there is and counted whether it fits or not: one that does not fit
//! says how much it needs (`Contours.short`), and its caller reads it
//! again into that much. No glyph box is in the table either: a glyph's
//! box is that of its points, found by running its program.
//!
//! Nothing here is taken on trust. Every list is checked to lie in the
//! table before an entry is taken from it, a program is read to its own
//! end and no further, subroutines nest ten deep at most, and a glyph is
//! given up - read as damaged - once it has run through `most_steps`
//! numbers and operators, has more than `most_points` points, or puts a
//! point further out than `far` units.
//!
//! Passed over: the font matrix (a program's units are taken as `head`'s
//! units to the em), and the four numbers an `endchar` may have for a
//! glyph put together from two others, an accent on a letter, which draw
//! nothing here.

const _outline = @import("_outline.zig");
const Font = _outline.Font;
const Table = _outline.Table;
const Contours = _outline.Contours;

const byteIn = _outline.byteIn;
const wordIn = _outline.wordIn;
const tripleIn = _outline.tripleIn;
const longIn = _outline.longIn;

/// A list of entries in the table.
pub const Index = struct {
    count: u32 = 0,
    /// The size of an offset in bytes, 1 to 4.
    off_size: u32 = 0,
    /// Where the offsets start, into the table; for a list of no entries,
    /// where it ends.
    offsets: u32 = 0,
    /// What an entry's offset is counted from, into the table.
    base: u32 = 0,
};

/// What `open` finds of a `CFF ` table. `table` is of no length for a
/// font without one.
pub const Cff = struct {
    table: Table = .{},
    /// A program a glyph.
    charstrings: Index = .{},
    global_subrs: Index = .{},
    /// The subroutines of the font's one private dictionary; of no
    /// entries for a CID-keyed font, whose glyphs each look theirs up.
    local_subrs: Index = .{},
    /// Whether the font is CID-keyed: `fonts` and `select` are read.
    cid: bool = false,
    /// The font dictionaries.
    fonts: Index = .{},
    /// The table saying which font dictionary a glyph has, to the end of
    /// the `CFF ` table.
    select: Table = .{},
};

/// The most points a glyph has: as many as a glyph of quadratic curves
/// can say it has.
pub const most_points = 0xFFFF;

/// The numbers and operators a glyph's program runs through, its
/// subroutines' among them: four for every point the largest glyph has.
const most_steps = 1 << 18;

/// The numbers a program's stack holds, and how deep subroutines nest:
/// the format's own limits.
const most_stack = 48;
const most_calls = 10;

/// How many numbers a program can put aside.
const most_kept = 32;

/// The furthest a point lies from the origin, in units: as far as a
/// 32-bit float counts whole numbers.
const far: f32 = 16777216.0;

// The dictionary operators read; a two-byte one is 12 and its second.
const op_charstrings = 17;
const op_private = 18;
const op_subrs = 19;
const op_charstring_type = 0x0C06;
const op_ros = 0x0C1E;
const op_fd_array = 0x0C24;
const op_fd_select = 0x0C25;

// --- lists and dictionaries -----------------------------------------------------

/// The list that starts `at` into `table`; null when it does not lie
/// within it.
fn indexAt(font: *const Font, table: Table, at: u32) ?Index {
    if (at >= table.len or table.len - at < 2) return null;
    const count: u32 = wordIn(font, table, at);
    if (count == 0) return .{ .offsets = at + 2 };
    const off_size: u32 = byteIn(font, table, at + 2);
    if (off_size < 1 or off_size > 4) return null;
    const offsets = at + 3;
    const bytes = (count + 1) * off_size;
    if (offsets > table.len or bytes > table.len - offsets) return null;
    return .{ .count = count, .off_size = off_size, .offsets = offsets, .base = offsets + bytes - 1 };
}

/// Offset `number` of a list: where its entry of that number starts,
/// from the list's `base`.
fn offsetOf(font: *const Font, table: Table, index: Index, number: u32) u32 {
    const at = index.offsets + number * index.off_size;
    return switch (index.off_size) {
        1 => byteIn(font, table, at),
        2 => wordIn(font, table, at),
        3 => tripleIn(font, table, at),
        else => longIn(font, table, at),
    };
}

/// Where a list ends, into the table; null when its last offset is not
/// within the table.
fn endOf(font: *const Font, table: Table, index: Index) ?u32 {
    if (index.count == 0) return index.offsets;
    const last = offsetOf(font, table, index, index.count);
    if (last < 1 or last > table.len - index.base) return null;
    return index.base + last;
}

/// Entry `number` of a list, as a part of the file; null when the list
/// has none of that number or its offsets are not sound.
fn entryOf(font: *const Font, table: Table, index: Index, number: u32) ?Table {
    if (number >= index.count) return null;
    const from = offsetOf(font, table, index, number);
    const to = offsetOf(font, table, index, number + 1);
    if (from < 1 or to < from or to > table.len - index.base) return null;
    return .{ .at = table.at + index.base + from, .len = to - from };
}

/// The numbers before the operator `wanted` in a dictionary, the first
/// three of them, a real number as 0; false when the dictionary has no
/// such operator.
fn dictFind(font: *const Font, dict: Table, wanted: u32, numbers: *[3]i32) bool {
    var found = [3]i32{ 0, 0, 0 };
    var count: u32 = 0;
    var at: u32 = 0;
    while (at < dict.len) {
        const first: u32 = byteIn(font, dict, at);
        at += 1;
        var value: i32 = 0;
        switch (first) {
            0...21 => {
                var operator = first;
                if (first == 12) {
                    operator = 0x0C00 | @as(u32, byteIn(font, dict, at));
                    at += 1;
                }
                if (operator == wanted) {
                    numbers.* = found;
                    return true;
                }
                found = .{ 0, 0, 0 };
                count = 0;
                continue;
            },
            28 => {
                value = @as(i16, @bitCast(wordIn(font, dict, at)));
                at += 2;
            },
            29 => {
                value = @bitCast(longIn(font, dict, at));
                at += 4;
            },
            // A real number: digits four bits each, to the one that ends it.
            30 => while (at < dict.len) {
                const digits = byteIn(font, dict, at);
                at += 1;
                if (digits >> 4 == 0xF or digits & 0xF == 0xF) break;
            },
            32...246 => value = @as(i32, @intCast(first)) - 139,
            247...250 => {
                value = @as(i32, @intCast((first - 247) * 256 + byteIn(font, dict, at))) + 108;
                at += 1;
            },
            251...254 => {
                value = -@as(i32, @intCast((first - 251) * 256 + byteIn(font, dict, at))) - 108;
                at += 1;
            },
            else => return false,
        }
        if (count < 3) found[count] = value;
        count += 1;
    }
    return false;
}

/// The local subroutines of the private dictionary `size` bytes long
/// `offset` into the table; a list of no entries when it names none.
fn localSubrs(font: *const Font, table: Table, size: i32, offset: i32) Index {
    if (size <= 0 or offset < 0) return .{};
    const start: u32 = @intCast(offset);
    const length: u32 = @intCast(size);
    if (start > table.len or length > table.len - start) return .{};
    var numbers: [3]i32 = undefined;
    if (!dictFind(font, .{ .at = table.at + start, .len = length }, op_subrs, &numbers)) return .{};
    // Counted from where the private dictionary starts.
    if (numbers[0] < 0 or @as(u32, @intCast(numbers[0])) > table.len - start) return .{};
    return indexAt(font, table, start + @as(u32, @intCast(numbers[0]))) orelse .{};
}

/// The `CFF ` table read: its lists found and checked. Null for a table
/// that is not sound, of another version than 1, or whose programs are
/// not Type 2 charstrings. `font` needs only its bytes set.
pub fn open(font: *const Font, table: Table) ?Cff {
    var cff = Cff{ .table = table };
    if (table.len < 4 or byteIn(font, table, 0) != 1) return null;
    const names = indexAt(font, table, byteIn(font, table, 2)) orelse return null;
    const tops = indexAt(font, table, endOf(font, table, names) orelse return null) orelse return null;
    const strings = indexAt(font, table, endOf(font, table, tops) orelse return null) orelse return null;
    cff.global_subrs = indexAt(font, table, endOf(font, table, strings) orelse return null) orelse return null;
    const top = entryOf(font, table, tops, 0) orelse return null;

    var numbers: [3]i32 = undefined;
    if (dictFind(font, top, op_charstring_type, &numbers) and numbers[0] != 2) return null;
    if (!dictFind(font, top, op_charstrings, &numbers) or numbers[0] < 0) return null;
    cff.charstrings = indexAt(font, table, @intCast(numbers[0])) orelse return null;

    if (dictFind(font, top, op_ros, &numbers)) {
        cff.cid = true;
        if (!dictFind(font, top, op_fd_array, &numbers) or numbers[0] < 0) return null;
        cff.fonts = indexAt(font, table, @intCast(numbers[0])) orelse return null;
        if (!dictFind(font, top, op_fd_select, &numbers) or numbers[0] < 0) return null;
        const select: u32 = @intCast(numbers[0]);
        if (select >= table.len) return null;
        cff.select = .{ .at = table.at + select, .len = table.len - select };
    } else if (dictFind(font, top, op_private, &numbers)) {
        cff.local_subrs = localSubrs(font, table, numbers[0], numbers[1]);
    }
    return cff;
}

/// The font dictionary a glyph of a CID-keyed font belongs to; a number
/// no list has when the table names none.
fn selected(font: *const Font, glyph: u32) u32 {
    const select = font.cff.select;
    switch (byteIn(font, select, 0)) {
        // A byte a glyph.
        0 => return byteIn(font, select, 1 +| glyph),
        // Ranges of glyphs, sorted: the last that starts at or before it.
        3 => {
            const count: u32 = @min(wordIn(font, select, 1), (select.len -| 5) / 3);
            var low: u32 = 0;
            var high: u32 = count;
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (wordIn(font, select, 3 + mid * 3) <= glyph) low = mid + 1 else high = mid;
            }
            if (low == 0) return ~@as(u32, 0);
            return byteIn(font, select, 3 + (low - 1) * 3 + 2);
        },
        else => return ~@as(u32, 0),
    }
}

/// The local subroutines a glyph's program calls.
fn localsOf(font: *const Font, glyph: u32) Index {
    const cff = &font.cff;
    if (!cff.cid) return cff.local_subrs;
    const dict = entryOf(font, cff.table, cff.fonts, selected(font, glyph)) orelse return .{};
    var numbers: [3]i32 = undefined;
    if (!dictFind(font, dict, op_private, &numbers)) return .{};
    return localSubrs(font, cff.table, numbers[0], numbers[1]);
}

// --- a glyph's program ------------------------------------------------------------

/// What a subroutine's number is counted from, by the length of its
/// list.
fn biasOf(count: u32) i32 {
    if (count < 1240) return 107;
    if (count < 33900) return 1131;
    return 32768;
}

/// A number of a program as a whole one, null for one that is none a
/// list or a stack could be asked for.
fn whole(value: f32) ?i32 {
    if (!(value >= -65536 and value <= 65536)) return null;
    return @intFromFloat(value);
}

/// Where a program is left for a subroutine, to come back to.
const Frame = struct { at: u32, end: u32 };

/// One glyph's program being run: the point it is at, the contour it is
/// drawing, and what it has drawn - into `into` while that has room,
/// counted and measured either way.
const Run = struct {
    font: *const Font,
    /// Where the points go; null when only the box is asked for.
    into: ?*Contours,
    /// a, b, c, d, dx, dy, as `_outline.contours` takes it.
    m: [6]f32,
    x: f32 = 0,
    y: f32 = 0,
    /// Whether a contour is begun.
    drawing: bool = false,
    /// The points and contours of the glyph so far.
    points: u32 = 0,
    ends: u32 = 0,
    /// `points`, and `into`'s count, when the contour being drawn began.
    first: u32 = 0,
    kept: u32 = 0,
    /// False once something did not fit `into`.
    fits: bool = true,
    /// False once the program turned out damaged.
    sound: bool = true,
    /// The box of the contours ended, and of the one being drawn: x min,
    /// y min, x max, y max.
    box: [4]f32 = .{ far, far, -far, -far },
    own: [4]f32 = .{ far, far, -far, -far },

    /// The point the program is at added to the contour.
    fn add(run: *Run, on: bool, cubic: bool) void {
        const m = run.m;
        const x = m[0] * run.x + m[2] * run.y + m[4];
        const y = m[1] * run.x + m[3] * run.y + m[5];
        // Too far out, or not a number at all: asked the other way round,
        // so that neither passes.
        if (!(x >= -far and x <= far and y >= -far and y <= far) or run.points == most_points) {
            run.sound = false;
            return;
        }
        run.own = .{ @min(run.own[0], x), @min(run.own[1], y), @max(run.own[2], x), @max(run.own[3], y) };
        run.points += 1;
        const into = run.into orelse return;
        if (run.fits and into.point_count < into.points.len) {
            into.points[into.point_count] = .{ .x = x, .y = y, .on = on, .cubic = cubic };
            into.point_count += 1;
        } else run.fits = false;
    }

    /// A contour begun at the point the program is at.
    fn begin(run: *Run) void {
        run.drawing = true;
        run.first = run.points;
        if (run.into) |into| run.kept = into.point_count;
        run.own = .{ far, far, -far, -far };
        run.add(true, false);
    }

    /// The contour being drawn ended. One of a single point - a move
    /// nothing was drawn from - is taken out again.
    fn finish(run: *Run) void {
        if (!run.drawing) return;
        run.drawing = false;
        if (run.points - run.first < 2) {
            run.points = run.first;
            if (run.into) |into| {
                if (run.fits) into.point_count = run.kept;
            }
            return;
        }
        run.box = .{ @min(run.box[0], run.own[0]), @min(run.box[1], run.own[1]), @max(run.box[2], run.own[2]), @max(run.box[3], run.own[3]) };
        run.ends += 1;
        const into = run.into orelse return;
        if (run.fits and into.end_count < into.ends.len) {
            into.ends[into.end_count] = into.point_count;
            into.end_count += 1;
        } else run.fits = false;
    }

    fn move(run: *Run, dx: f32, dy: f32) void {
        run.finish();
        run.x += dx;
        run.y += dy;
        run.begin();
    }

    /// A line from the point the program is at; one drawn before any move
    /// begins a contour there.
    fn line(run: *Run, dx: f32, dy: f32) void {
        if (!run.drawing) run.begin();
        run.x += dx;
        run.y += dy;
        run.add(true, false);
    }

    /// A curve: each of its three points given from the one before.
    fn curve(run: *Run, dx1: f32, dy1: f32, dx2: f32, dy2: f32, dx3: f32, dy3: f32) void {
        if (!run.drawing) run.begin();
        run.x += dx1;
        run.y += dy1;
        run.add(false, true);
        run.x += dx2;
        run.y += dy2;
        run.add(false, true);
        run.x += dx3;
        run.y += dy3;
        run.add(true, false);
    }

    /// `program` run to its end, calling `locals` and the font's global
    /// subroutines. `sound` is false afterwards if it was damaged.
    fn interpret(run: *Run, program: Table, locals: Index) void {
        const font = run.font;
        const cff = &font.cff;
        var stack: [most_stack]f32 = undefined;
        var depth: u32 = 0;
        var aside: [most_kept]f32 = @splat(0);
        var calls: [most_calls]Frame = undefined;
        var nesting: u32 = 0;
        var at = program.at;
        var end = program.at + program.len;
        var stems: u32 = 0;
        var steps: u32 = 0;
        var ended = false;
        while (run.sound) {
            if (at >= end) {
                // A subroutine that ends without saying so returns, and the
                // program's own end is the glyph's.
                if (nesting == 0) {
                    ended = true;
                    break;
                }
                nesting -= 1;
                at = calls[nesting].at;
                end = calls[nesting].end;
                continue;
            }
            steps += 1;
            if (steps > most_steps) break;
            const first: u32 = font.data[at];
            at += 1;

            // A number.
            if (first >= 32 or first == 28) {
                var value: f32 = undefined;
                if (first == 28) {
                    if (end - at < 2) break;
                    const bits = @as(u16, font.data[at]) << 8 | font.data[at + 1];
                    value = @floatFromInt(@as(i16, @bitCast(bits)));
                    at += 2;
                } else if (first < 247) {
                    value = @floatFromInt(@as(i32, @intCast(first)) - 139);
                } else if (first < 255) {
                    if (end - at < 1) break;
                    const low: u32 = font.data[at];
                    at += 1;
                    const size: i32 = @intCast(((first - 247) & 3) * 256 + low + 108);
                    value = @floatFromInt(if (first < 251) size else -size);
                } else {
                    // Sixteen bits of whole number and sixteen of fraction.
                    if (end - at < 4) break;
                    const bits = @as(u32, font.data[at]) << 24 | @as(u32, font.data[at + 1]) << 16 | @as(u32, font.data[at + 2]) << 8 | font.data[at + 3];
                    value = @as(f32, @floatFromInt(@as(i32, @bitCast(bits)))) / 65536.0;
                    at += 4;
                }
                if (depth == most_stack) break;
                stack[depth] = value;
                depth += 1;
                continue;
            }

            switch (first) {
                // Stem hints: two numbers a stem.
                1, 3, 18, 23 => {
                    stems += depth / 2;
                    depth = 0;
                },
                // A hint mask, a bit a stem; numbers before it are stems
                // more.
                19, 20 => {
                    stems += depth / 2;
                    depth = 0;
                    const bytes = (stems + 7) / 8;
                    if (end - at < bytes) break;
                    at += bytes;
                },
                // Moves, the numbers they take the last on the stack: one
                // before them is the width.
                21 => {
                    if (depth < 2) break;
                    run.move(stack[depth - 2], stack[depth - 1]);
                    depth = 0;
                },
                22 => {
                    if (depth < 1) break;
                    run.move(stack[depth - 1], 0);
                    depth = 0;
                },
                4 => {
                    if (depth < 1) break;
                    run.move(0, stack[depth - 1]);
                    depth = 0;
                },
                // Lines: each to a point, or along one axis and the other
                // in turn.
                5 => {
                    var i: u32 = 0;
                    while (i + 2 <= depth) : (i += 2) run.line(stack[i], stack[i + 1]);
                    depth = 0;
                },
                6, 7 => {
                    var level = first == 6;
                    for (stack[0..depth]) |by| {
                        if (level) run.line(by, 0) else run.line(0, by);
                        level = !level;
                    }
                    depth = 0;
                },
                // Curves, six numbers each.
                8 => {
                    var i: u32 = 0;
                    while (i + 6 <= depth) : (i += 6) run.curve(stack[i], stack[i + 1], stack[i + 2], stack[i + 3], stack[i + 4], stack[i + 5]);
                    depth = 0;
                },
                // Curves and a line after them; lines and a curve.
                24 => {
                    var i: u32 = 0;
                    while (i + 8 <= depth) : (i += 6) run.curve(stack[i], stack[i + 1], stack[i + 2], stack[i + 3], stack[i + 4], stack[i + 5]);
                    if (i + 2 <= depth) run.line(stack[i], stack[i + 1]);
                    depth = 0;
                },
                25 => {
                    var i: u32 = 0;
                    while (i + 8 <= depth) : (i += 2) run.line(stack[i], stack[i + 1]);
                    if (i + 6 <= depth) run.curve(stack[i], stack[i + 1], stack[i + 2], stack[i + 3], stack[i + 4], stack[i + 5]);
                    depth = 0;
                },
                // Curves that start and end upright, four numbers each; an
                // odd one before them moves the first sideways. And the
                // same lying down.
                26, 27 => {
                    var i: u32 = depth % 2;
                    var across: f32 = if (i == 1) stack[0] else 0;
                    while (i + 4 <= depth) : (i += 4) {
                        if (first == 26)
                            run.curve(across, stack[i], stack[i + 1], stack[i + 2], 0, stack[i + 3])
                        else
                            run.curve(stack[i], across, stack[i + 1], stack[i + 2], stack[i + 3], 0);
                        across = 0;
                    }
                    depth = 0;
                },
                // Curves that start along one axis and end along the
                // other, in turn; the last may end off its axis by one
                // number more.
                30, 31 => {
                    var level = first == 31;
                    var i: u32 = 0;
                    while (i + 4 <= depth) : (i += 4) {
                        const off: f32 = if (depth - i == 5) stack[i + 4] else 0;
                        if (level)
                            run.curve(stack[i], 0, stack[i + 1], stack[i + 2], off, stack[i + 3])
                        else
                            run.curve(0, stack[i], stack[i + 1], stack[i + 2], stack[i + 3], off);
                        level = !level;
                    }
                    depth = 0;
                },
                // A subroutine, local or global.
                10, 29 => {
                    if (depth < 1 or nesting == most_calls) break;
                    depth -= 1;
                    const list = if (first == 10) locals else cff.global_subrs;
                    const number = (whole(stack[depth]) orelse break) + biasOf(list.count);
                    if (number < 0) break;
                    const called = entryOf(font, cff.table, list, @intCast(number)) orelse break;
                    calls[nesting] = .{ .at = at, .end = end };
                    nesting += 1;
                    at = called.at;
                    end = called.at + called.len;
                },
                11 => {
                    if (nesting == 0) break;
                    nesting -= 1;
                    at = calls[nesting].at;
                    end = calls[nesting].end;
                },
                // The glyph's end.
                14 => {
                    run.finish();
                    return;
                },
                12 => {
                    if (end - at < 1) break;
                    const second = font.data[at];
                    at += 1;
                    switch (second) {
                        // and, or, not: 0 is false.
                        3, 4 => {
                            if (depth < 2) break;
                            const left = stack[depth - 2] != 0;
                            const right = stack[depth - 1] != 0;
                            depth -= 1;
                            stack[depth - 1] = if (if (second == 3) left and right else left or right) 1 else 0;
                        },
                        5 => {
                            if (depth < 1) break;
                            stack[depth - 1] = if (stack[depth - 1] == 0) 1 else 0;
                        },
                        9 => {
                            if (depth < 1) break;
                            stack[depth - 1] = @abs(stack[depth - 1]);
                        },
                        // add, sub, div, mul, eq.
                        10, 11, 12, 24, 15 => {
                            if (depth < 2) break;
                            const left = stack[depth - 2];
                            const right = stack[depth - 1];
                            if (second == 12 and right == 0) break;
                            depth -= 1;
                            stack[depth - 1] = switch (second) {
                                10 => left + right,
                                11 => left - right,
                                12 => left / right,
                                24 => left * right,
                                else => if (left == right) 1 else 0,
                            };
                        },
                        14 => {
                            if (depth < 1) break;
                            stack[depth - 1] = -stack[depth - 1];
                        },
                        // drop.
                        18 => {
                            if (depth < 1) break;
                            depth -= 1;
                        },
                        // put and get: a number set aside by its place.
                        20 => {
                            if (depth < 2) break;
                            const place = whole(stack[depth - 1]) orelse break;
                            if (place < 0 or place >= most_kept) break;
                            aside[@intCast(place)] = stack[depth - 2];
                            depth -= 2;
                        },
                        21 => {
                            if (depth < 1) break;
                            const place = whole(stack[depth - 1]) orelse break;
                            if (place < 0 or place >= most_kept) break;
                            stack[depth - 1] = aside[@intCast(place)];
                        },
                        // ifelse: the first of four if the third is no
                        // more than the fourth, else the second.
                        22 => {
                            if (depth < 4) break;
                            if (stack[depth - 2] > stack[depth - 1]) stack[depth - 4] = stack[depth - 3];
                            depth -= 3;
                        },
                        // random: above 0 and no more than 1. The same
                        // number every time, so a glyph is the same glyph
                        // every time.
                        23 => {
                            if (depth == most_stack) break;
                            stack[depth] = 1;
                            depth += 1;
                        },
                        26 => {
                            if (depth < 1 or stack[depth - 1] < 0) break;
                            stack[depth - 1] = @sqrt(stack[depth - 1]);
                        },
                        // dup, exch.
                        27 => {
                            if (depth < 1 or depth == most_stack) break;
                            stack[depth] = stack[depth - 1];
                            depth += 1;
                        },
                        28 => {
                            if (depth < 2) break;
                            const top = stack[depth - 1];
                            stack[depth - 1] = stack[depth - 2];
                            stack[depth - 2] = top;
                        },
                        // index: a copy of the number so many below the
                        // top; the top itself for less than none.
                        29 => {
                            if (depth < 2) break;
                            const below = @max(whole(stack[depth - 1]) orelse break, 0);
                            if (below > depth - 2) break;
                            stack[depth - 1] = stack[depth - 2 - @as(u32, @intCast(below))];
                        },
                        // roll: the top numbers, so many of them, turned
                        // round by so many places.
                        30 => {
                            if (depth < 2) break;
                            const size = whole(stack[depth - 2]) orelse break;
                            const by = whole(stack[depth - 1]) orelse break;
                            depth -= 2;
                            if (size < 0 or size > depth) break;
                            if (size == 0) continue;
                            const count: u32 = @intCast(size);
                            const turn: u32 = @intCast(@mod(by, size));
                            var turned: [most_stack]f32 = undefined;
                            const group = stack[depth - count .. depth];
                            for (group, 0..) |value, place| turned[(place + turn) % count] = value;
                            @memcpy(group, turned[0..count]);
                        },
                        // Two curves with a joint that may be drawn as a
                        // line when shallow, in four forms.
                        34 => {
                            if (depth < 7) break;
                            const s = &stack;
                            run.curve(s[0], 0, s[1], s[2], s[3], 0);
                            run.curve(s[4], 0, s[5], -s[2], s[6], 0);
                            depth = 0;
                        },
                        35 => {
                            if (depth < 12) break;
                            const s = &stack;
                            run.curve(s[0], s[1], s[2], s[3], s[4], s[5]);
                            run.curve(s[6], s[7], s[8], s[9], s[10], s[11]);
                            depth = 0;
                        },
                        36 => {
                            if (depth < 9) break;
                            const s = &stack;
                            run.curve(s[0], s[1], s[2], s[3], s[4], 0);
                            run.curve(s[5], 0, s[6], s[7], s[8], -(s[1] + s[3] + s[7]));
                            depth = 0;
                        },
                        // The last number goes along the axis the ten
                        // before it went further on; the other comes back
                        // to where it started.
                        37 => {
                            if (depth < 11) break;
                            const s = &stack;
                            const dx = s[0] + s[2] + s[4] + s[6] + s[8];
                            const dy = s[1] + s[3] + s[5] + s[7] + s[9];
                            run.curve(s[0], s[1], s[2], s[3], s[4], s[5]);
                            if (@abs(dx) > @abs(dy))
                                run.curve(s[6], s[7], s[8], s[9], s[10], -dy)
                            else
                                run.curve(s[6], s[7], s[8], s[9], -dx, s[10]);
                            depth = 0;
                        },
                        else => break,
                    }
                },
                else => break,
            }
        } else return;
        // Left by a break: at the program's own end, which is the glyph's,
        // or on something damaged.
        if (ended) run.finish() else run.sound = false;
    }
};

/// A glyph's contours added to `into`, transformed by `m`. False when
/// its program is damaged, and when the contours do not fit: then
/// `into.short` is set and `into.needed_points` and `needed_ends` say
/// what the glyph has, of which one more each is room enough.
pub fn contours(font: *const Font, glyph: u32, into: *Contours, m: [6]f32) bool {
    const cff = &font.cff;
    into.short = false;
    const program = entryOf(font, cff.table, cff.charstrings, glyph) orelse return true;
    const points = into.point_count;
    const ends = into.end_count;
    var run = Run{ .font = font, .into = into, .m = m, .points = points, .ends = ends };
    run.interpret(program, localsOf(font, glyph));
    if (run.sound and run.fits) return true;
    into.point_count = points;
    into.end_count = ends;
    if (run.sound) {
        into.short = true;
        into.needed_points = run.points;
        into.needed_ends = run.ends;
    }
    return false;
}

/// A glyph's box, that of its points - a curve's control points among
/// them - rounded outwards: x min, y min, x max, y max; all 0 for a
/// glyph of no outline or a damaged one.
pub fn boxOf(font: *const Font, glyph: u32) [4]i32 {
    const cff = &font.cff;
    const program = entryOf(font, cff.table, cff.charstrings, glyph) orelse return .{ 0, 0, 0, 0 };
    var run = Run{ .font = font, .into = null, .m = .{ 1, 0, 0, 1, 0, 0 } };
    run.interpret(program, localsOf(font, glyph));
    if (!run.sound or run.ends == 0) return .{ 0, 0, 0, 0 };
    return .{
        @intFromFloat(@floor(run.box[0])),
        @intFromFloat(@floor(run.box[1])),
        @intFromFloat(@ceil(run.box[2])),
        @intFromFloat(@ceil(run.box[3])),
    };
}

// --- tests ---------------------------------------------------------------------

const testing = @import("std").testing;

test "cubic outlines: what a subroutine's number is counted from, by how many there are" {
    try testing.expectEqual(@as(i32, 107), biasOf(0));
    try testing.expectEqual(@as(i32, 107), biasOf(1239));
    try testing.expectEqual(@as(i32, 1131), biasOf(1240));
    try testing.expectEqual(@as(i32, 1131), biasOf(33899));
    try testing.expectEqual(@as(i32, 32768), biasOf(33900));
    try testing.expectEqual(@as(i32, 32768), biasOf(65535));
}
