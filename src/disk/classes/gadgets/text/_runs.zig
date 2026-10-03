// SPDX-License-Identifier: MIT
//! Rich text: markup turned into runs, and runs laid out into lines.
//!
//! **Markup** is parsed once, into a block allocated for it: a header,
//! the runs, and the text of each run copied after them, NUL-terminated.
//! A stack of looks holds what the open tags said; text between tags is a
//! run in the look on top. `<s=N>` opens the gadget's font at that size -
//! through diskfont.library, which scales a font to a size it does not
//! come in, or graphics.library's nearest without it - and the block keeps
//! it, to close when the block goes.
//!
//! **A line** is found by walking the runs in pieces - a word, a space, or
//! a line break - measuring each in its run's font and style on the
//! RastPort: a word that would pass the width ends the line before it,
//! unless it is the line's first. Spaces at the start of a line are not
//! drawn. A line's height and baseline are its tallest run's; its pieces
//! are drawn on the one baseline.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const tx = sdk.gadgets.text;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const ExecBase = sdk.interface.exec.ExecBase;
const TextRun = tx.TextRun;

// --- markup ------------------------------------------------------------------------

/// The most runs, opened fonts and nested tags markup may have.
const max_runs = 64;
const max_fonts = 4;
const max_depth = 8;

/// What a parse made: freed with `free`.
pub const Parsed = extern struct {
    fonts: [max_fonts]?*graphics.TextFont = @splat(null),
    font_count: u32 = 0,
    runs: [max_runs + 1]TextRun = @splat(.{}),
};

const Look = struct { style: u32 = 0, colour: graphics.Pen = 0, font: ?*graphics.TextFont = null };

fn hexDigit(c: u8) ?u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// A font at `rows`: scaled by diskfont.library when it is there, the
/// nearest graphics.library has otherwise.
fn openSized(sys: *ExecBase, gb: *GraphicsBase, name: [*:0]const u8, rows: u16) ?*graphics.TextFont {
    const attr = graphics.TextAttr{ .name = name, .y_size = rows };
    if (sys.OpenLibrary(sdk.diskfont.DISKFONTNAME, 0)) |lib| {
        defer sys.CloseLibrary(lib);
        const df: *sdk.interface.diskfont.DiskfontBase = @ptrCast(lib);
        if (df.OpenDiskFont(&attr)) |font| return font;
    }
    return gb.OpenFont(&attr);
}

/// `text` as markup, into a block of its own; null without the memory.
/// `font_name` is the font `<s=N>` opens at another size.
pub fn parse(sys: *ExecBase, gb: *GraphicsBase, text: [*:0]const u8, font_name: [*:0]const u8) ?*Parsed {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    // The runs' texts are never longer than the markup, and each ends in
    // a NUL.
    const size = @sizeOf(Parsed) + length + max_runs + 1;
    const block: [*]u8 = @ptrCast(sys.AllocVec(@intCast(size), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null);
    const parsed: *Parsed = @ptrCast(@alignCast(block));
    parsed.* = .{};
    const chars = block[@sizeOf(Parsed)..size];
    var used: usize = 0;
    var run_count: usize = 0;
    var stack: [max_depth]Look = @splat(.{});
    var depth: usize = 0;
    var run_start: ?usize = null;

    const close = struct {
        fn run(p: *Parsed, cs: []u8, u: *usize, count: *usize, start: *?usize, look: Look) void {
            const from = start.* orelse return;
            start.* = null;
            if (count.* >= max_runs) return;
            cs[u.*] = 0;
            u.* += 1;
            p.runs[count.*] = .{ .text = @ptrCast(&cs[from]), .font = look.font, .style = look.style, .colour = look.colour };
            count.* += 1;
        }
    }.run;

    var i: usize = 0;
    while (i < length) {
        const c = text[i];
        if (c == '<' and i + 1 < length and text[i + 1] == '<') {
            if (run_start == null) run_start = used;
            chars[used] = '<';
            used += 1;
            i += 2;
            continue;
        }
        if (c != '<') {
            if (run_start == null) run_start = used;
            chars[used] = c;
            used += 1;
            i += 1;
            continue;
        }
        // A tag: up to its '>'.
        var end = i + 1;
        while (end < length and text[end] != '>') end += 1;
        if (end >= length) break;
        const tag = text[i + 1 .. end];
        i = end + 1;
        close(parsed, chars, &used, &run_count, &run_start, stack[depth]);
        if (tag.len >= 1 and tag[0] == '/') {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (tag.len == 2 and tag[0] == 'b' and tag[1] == 'r') {
            run_start = used;
            chars[used] = '\n';
            used += 1;
            close(parsed, chars, &used, &run_count, &run_start, stack[depth]);
            continue;
        }
        var look = stack[depth];
        if (tag.len == 1 and tag[0] == 'b') {
            look.style |= graphics.FSF_BOLD;
        } else if (tag.len == 1 and tag[0] == 'i') {
            look.style |= graphics.FSF_ITALIC;
        } else if (tag.len == 1 and tag[0] == 'u') {
            look.style |= graphics.FSF_UNDERLINED;
        } else if (tag.len == 9 and tag[0] == 'c' and tag[1] == '=' and tag[2] == '#') {
            var rgb: u32 = 0;
            for (tag[3..9]) |h| rgb = rgb << 4 | (hexDigit(h) orelse 0);
            look.colour = 0xFF00_0000 | rgb;
        } else if (tag.len >= 3 and tag[0] == 's' and tag[1] == '=') {
            var rows: u16 = 0;
            for (tag[2..]) |d| {
                if (d < '0' or d > '9') break;
                rows = rows *% 10 +% (d - '0');
            }
            if (parsed.font_count < max_fonts and rows > 0) {
                if (openSized(sys, gb, font_name, rows)) |font| {
                    parsed.fonts[parsed.font_count] = font;
                    parsed.font_count += 1;
                    look.font = font;
                }
            }
        } else continue;
        if (depth + 1 < max_depth) {
            depth += 1;
            stack[depth] = look;
        }
    }
    close(parsed, chars, &used, &run_count, &run_start, stack[depth]);
    parsed.runs[run_count] = .{};
    return parsed;
}

/// A parse's block and its fonts given back.
pub fn free(sys: *ExecBase, gb: *GraphicsBase, parsed: ?*Parsed) void {
    const p = parsed orelse return;
    for (p.fonts[0..p.font_count]) |font| gb.CloseFont(font);
    sys.FreeVec(p);
}

// --- layout ------------------------------------------------------------------------

/// Where a walk through the runs is: a run, and a character in it.
pub const Pos = struct { run: usize = 0, at: usize = 0 };

const Piece = struct { run: usize, from: usize, to: usize, kind: enum { word, space, newline } };

/// The piece at `pos`, or null at the end; `pos` moved past it.
fn next(runs: [*]const TextRun, pos: *Pos) ?Piece {
    while (true) {
        const text = runs[pos.run].text orelse return null;
        if (text[pos.at] == 0) {
            pos.run += 1;
            pos.at = 0;
            continue;
        }
        const from = pos.at;
        const c = text[from];
        if (c == '\n' or c == ' ') {
            pos.at += 1;
            return .{ .run = pos.run, .from = from, .to = from + 1, .kind = if (c == '\n') .newline else .space };
        }
        var to = from;
        while (text[to] != 0 and text[to] != ' ' and text[to] != '\n') to += 1;
        pos.at = to;
        return .{ .run = pos.run, .from = from, .to = to, .kind = .word };
    }
}

/// What a run is drawn in.
pub const Ink = struct {
    gb: *GraphicsBase,
    rp: *graphics.RastPort,
    font: *graphics.TextFont,
    front: graphics.Pen,

    /// The run's font and style on the RastPort, and its line's metrics.
    fn wear(ink: Ink, run: *const TextRun) [2]i32 {
        graphics.SetFont(ink.gb, ink.rp, run.font orelse ink.font);
        _ = ink.gb.SetSoftStyle(ink.rp, run.style, 0xFF);
        var height: u32 = 0;
        var baseline: u32 = 0;
        ink.gb.GetRPAttrs(ink.rp, &[_]TagItem{
            .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) },
            .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
            .{},
        });
        return .{ @intCast(height), @intCast(baseline) };
    }

    fn width(ink: Ink, runs: [*]const TextRun, piece: Piece) i32 {
        _ = ink.wear(&runs[piece.run]);
        return ink.gb.TextLength(ink.rp, runs[piece.run].text.? + piece.from, @intCast(piece.to - piece.from));
    }
};

/// A line: where it starts and ends, how wide, how tall, and its baseline.
pub const Line = struct {
    start: Pos,
    end: Pos,
    width: i32 = 0,
    height: i32 = 0,
    baseline: i32 = 0,
};

/// The line starting at `start`, at most `room` wide when `wrap`; null
/// past the last.
pub fn lineAt(ink: Ink, runs: [*]const TextRun, start: Pos, room: i32, wrap: bool) ?Line {
    var pos = start;
    // Spaces at the line's start are not part of it.
    var peek = pos;
    while (next(runs, &peek)) |piece| {
        if (piece.kind != .space) break;
        pos = peek;
    }
    var line = Line{ .start = pos, .end = pos };
    var any = false;
    while (true) {
        const before = pos;
        const piece = next(runs, &pos) orelse break;
        any = true;
        const metrics = ink.wear(&runs[piece.run]);
        if (piece.kind == .newline) {
            line.height = @max(line.height, metrics[0]);
            line.baseline = @max(line.baseline, metrics[1]);
            line.end = pos;
            return line;
        }
        const w = ink.width(runs, piece);
        if (wrap and piece.kind == .word and line.width > 0 and line.width + w > room) {
            line.end = before;
            return line;
        }
        line.width += w;
        line.height = @max(line.height, metrics[0]);
        line.baseline = @max(line.baseline, metrics[1]);
        line.end = pos;
    }
    return if (any or line.width > 0) line else null;
}

/// A line drawn with its left edge at `left` and its top at `top`.
pub fn drawLine(ink: Ink, runs: [*]const TextRun, line: Line, left: i32, top: i32) void {
    var pos = line.start;
    var x = left;
    while (pos.run < line.end.run or (pos.run == line.end.run and pos.at < line.end.at)) {
        const piece = next(runs, &pos) orelse break;
        if (piece.kind == .newline) continue;
        const run = &runs[piece.run];
        const w = ink.width(runs, piece);
        if (piece.kind == .word) {
            ink.gb.SetRPAttrs(ink.rp, &[_]TagItem{
                .{ .tag = graphics.RPTAG_APen, .data = if (run.colour != 0) run.colour else ink.front },
                .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
                .{},
            });
            ink.gb.Move(ink.rp, x, top + line.baseline);
            ink.gb.Text(ink.rp, run.text.? + piece.from, @intCast(piece.to - piece.from));
        }
        x += w;
    }
}
