// SPDX-License-Identifier: MIT
//! The runs broken into lines that fit the room the object was given.
//!
//! A run ends a line where its text holds a newline, and, when the
//! object wraps, wherever the line would otherwise run past the right
//! edge: at the last space before that, or, for a word longer than the
//! whole line, wherever it reaches the edge. What comes out is a flat
//! list of fragments - a stretch of one run, with the place and the
//! width it was measured at - and a list of lines that index into it.
//!
//! **A line is as tall as the tallest run in it.** A heading in a larger
//! font pushes its own line down and leaves the lines round it alone,
//! and the letters of runs of different heights stand on one baseline.
//!
//! Laying out happens on the layout process, so it may take as long as
//! it takes.

const sdk = @import("sdk");
const gadgets = sdk.gadgets;
const datatypes = sdk.datatypes;
const tdc = datatypes.textclass;
const _text = @import("_text.zig");
const Data = _text.Data;
const Line = _text.Line;
const Fragment = _text.Fragment;
const Base = gadgets.Base;

/// How many rows stand between one line and the next.
///
/// A font eight rows tall drawn every eight rows has its descenders
/// touching the next line's capitals, which is how a console looks and
/// not how anything meant to be read does.
const leading = 1;

/// What one line is being built out of.
const Building = struct {
    /// The first fragment of the line, and how far along it has got.
    first: u32,
    left: i32,
    height: i32,
    baseline: i32,
    /// The last place the line could be broken instead, and where that
    /// leaves it.
    break_fragment: u32,
    break_offset: u32,
    break_left: i32,
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
    own.widest = 0;
    own.laid_for = room;
    const pieces = own.pieces orelse return true;
    const buffer = own.buffer orelse return true;
    const wrapping = own.wrap != 0 and room > 0;

    var line = Building{
        .first = 0,
        .left = 0,
        .height = 0,
        .baseline = 0,
        .break_fragment = 0,
        .break_offset = 0,
        .break_left = 0,
    };
    var top: i32 = 0;
    var indent: i32 = 0;
    // Whether nothing has been put on the line yet, which is when the
    // run about to be added is the one that says how far in it starts.
    var fresh = true;

    var p: u32 = 0;
    while (p < own.piece_count) : (p += 1) {
        const piece = &pieces[p];
        const size = _text.heightOf(base, own, piece);
        line.height = @max(line.height, size.height);
        line.baseline = @max(line.baseline, size.baseline);

        var at: u32 = 0;
        while (at < piece.length) {
            // The run that starts a line says how far in the line
            // begins, so an item of a list is indented and everything
            // after it on that line goes with it.
            if (fresh) {
                indent = @as(i32, piece.indent) * own.indent_width;
                line.left = indent;
                fresh = false;
            }
            // As far as the next newline in this run.
            var end = at;
            while (end < piece.length and buffer[piece.offset + end] != '\n') end += 1;
            const stop = if (wrapping)
                fitting(base, own, piece, at, end, room - line.left)
            else
                end;

            if (!add(base, own, p, piece.offset + at, stop - at, &line)) return false;
            noteBreak(base, own, piece, at, stop, &line, buffer);
            at = stop;

            if (at < piece.length and buffer[piece.offset + at] == '\n') {
                if (!endLine(base, own, &line, &top, indent)) return false;
                at += 1;
                fresh = true;
                const again = _text.heightOf(base, own, piece);
                line.height = again.height;
                line.baseline = again.baseline;
                continue;
            }
            if (at < piece.length) {
                // The line filled up: break it at the last space, and
                // what came after that space starts the next line. A
                // wrapped line keeps the indent it already had.
                if (!wrapLine(base, own, &line, &top, indent, &at, piece)) return false;
            }
        }
    }
    if (own.fragment_count > line.first or own.line_count == 0) {
        if (!endLine(base, own, &line, &top, indent)) return false;
    }
    return true;
}

/// How much of a run fits in `room` pixels.
fn fitting(base: *Base, own: *Data, piece: *const tdc.Piece, from: u32, to: u32, room: i32) u32 {
    if (room <= 0) return if (to > from) from + 1 else to;
    if (_text.widthOf(base, own, piece, piece.offset + from, to - from) <= room) return to;
    // Narrow it down: the widest count that still fits.
    var low = from;
    var high = to;
    while (low + 1 < high) {
        const middle = low + (high - low) / 2;
        if (_text.widthOf(base, own, piece, piece.offset + from, middle - from) <= room) {
            low = middle;
        } else {
            high = middle;
        }
    }
    return @max(low, from + 1);
}

/// One fragment added to the line being built.
fn add(base: *Base, own: *Data, piece_index: u32, offset: u32, length: u32, line: *Building) bool {
    if (length == 0) return true;
    if (!_text.makeRoom(base, Fragment, &own.fragments, &own.fragment_room, own.fragment_count + 1)) return false;
    const piece = &own.pieces.?[piece_index];
    const width = _text.widthOf(base, own, piece, offset, length);
    own.fragments.?[own.fragment_count] = .{
        .piece = piece_index,
        .offset = offset,
        .length = length,
        .left = line.left,
        .width = width,
    };
    own.fragment_count += 1;
    line.left += width;
    return true;
}

/// The last space of what was just added remembered, so that a line
/// that fills up can be broken there instead.
fn noteBreak(base: *Base, own: *Data, piece: *const tdc.Piece, from: u32, to: u32, line: *Building, buffer: [*]const u8) void {
    var at = to;
    while (at > from) {
        at -= 1;
        if (buffer[piece.offset + at] != ' ') continue;
        // Where the line would end if it were broken after this space.
        line.break_fragment = own.fragment_count - 1;
        line.break_offset = piece.offset + at + 1;
        line.break_left = line.left;
        _ = base;
        return;
    }
}

/// A line that filled up, broken at the last space in it.
fn wrapLine(base: *Base, own: *Data, line: *Building, top: *i32, indent: i32, at: *u32, piece: *const tdc.Piece) bool {
    const fragments = own.fragments.?;
    // A word longer than the whole line has no space to break at, so it
    // is broken where it reached the edge.
    if (line.break_fragment >= line.first and line.break_offset > piece.offset and
        line.break_offset <= piece.offset + piece.length and own.fragment_count > line.first)
    {
        const last = &fragments[line.break_fragment];
        const kept = line.break_offset - last.offset;
        if (kept <= last.length) {
            // Everything after the space starts the next line.
            own.fragment_count = line.break_fragment + 1;
            last.length = kept;
            last.width = _text.widthOf(base, own, piece, last.offset, last.length);
            at.* = line.break_offset - piece.offset;
        }
    }
    line.break_fragment = own.fragment_count;
    line.break_offset = 0;
    if (!endLine(base, own, line, top, indent)) return false;
    line.left = indent;
    return true;
}

/// The line being built closed off and the next one started.
fn endLine(base: *Base, own: *Data, line: *Building, top: *i32, indent: i32) bool {
    if (!_text.makeRoom(base, Line, &own.lines, &own.line_room, own.line_count + 1)) return false;
    // A line with nothing in it is still a line, as tall as the font.
    if (line.height == 0) {
        const size = _text.heightOf(base, own, &.{});
        line.height = size.height;
        line.baseline = size.baseline;
    }
    own.lines.?[own.line_count] = .{
        .first = line.first,
        .count = own.fragment_count - line.first,
        .top = top.*,
        .height = line.height + leading,
        .baseline = line.baseline,
        .width = line.left,
    };
    own.line_count += 1;
    own.widest = @max(own.widest, line.left);
    top.* += line.height;
    line.first = own.fragment_count;
    line.left = indent;
    line.break_fragment = own.fragment_count;
    line.break_offset = 0;
    line.height = 0;
    line.baseline = 0;
    return true;
}

/// How tall the whole text came out.
pub fn totalHeight(own: *const Data) i32 {
    if (own.line_count == 0) return 0;
    const last = own.lines.?[own.line_count - 1];
    return last.top + last.height;
}

/// Which line a place `y` pixels down the text is in.
pub fn lineAt(own: *const Data, y: i32) u32 {
    if (own.line_count == 0) return 0;
    const lines = own.lines.?;
    var n: u32 = 0;
    while (n < own.line_count) : (n += 1) {
        if (y < lines[n].top + lines[n].height) return n;
    }
    return own.line_count - 1;
}
