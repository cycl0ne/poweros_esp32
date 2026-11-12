// SPDX-License-Identifier: MPL-2.0
//! A text laid out by its fonts' `shape` hooks.
//!
//! A font whose builder knows more about its glyphs than a glyph for
//! each character (`TextFont.shape`) is asked which glyphs a text is
//! drawn with and where each goes: two letters moved together, a mark
//! set on its letter, several characters drawn as one glyph or one as
//! several. The text calls take this way when the RastPort's font or
//! one of its fallbacks has such a hook (`wanted`), and the way of a
//! glyph for each character otherwise.
//!
//! **Clusters.** The text is cut into its clusters, what a reader takes
//! for one character each (`unicode.clusterEnd`): a letter with its
//! marks, consonants a virama joins with their vowel sign, the two
//! characters of a flag, pictographs a joiner makes one. One font draws
//! a cluster, a glyph is of the cluster its first character is in, and
//! no text is cut inside one.
//!
//! **A font for each cluster.** The first font of the chain that has a
//! glyph for each of the cluster's characters draws it. Where none has,
//! and the cluster is one a shaper may have another form of - a letter
//! with marks, in one character or several, a space of a set width, a
//! character that is not shown - it is the first font whose hook shapes
//! the cluster by itself without the glyph of a character it lacks. A
//! cluster no font draws is drawn a character at a time as `glyphOf`
//! finds them: by the base letter, or with the default character.
//!
//! **Stretches.** The clusters one font draws, one after another, are
//! shaped together in one call of its hook, so what the font does
//! across them - kerning, ligatures - is done; a font with no hook
//! places a glyph for each character. Between two fonts nothing is
//! done.
//!
//! **The glyphs.** What comes of it is a list of placed glyphs
//! (`Placed`) in the order they are drawn: the glyph - one the font's
//! image holds or its `render` hook made, by character or by number -
//! its font, the byte its cluster starts at, its advance, and where it
//! is drawn from the point. The list lives in memory allocated for the
//! one call (`layOut`, `free`); with no memory for it, or a hook that
//! could not shape, the call takes the other way this once.
//!
//! **Places in a text** (`xOf`, `offsetAt`). A cluster's width is the
//! advances of its glyphs, and the place between two clusters is where
//! the first one ends. What several clusters are drawn as together - a
//! ligature - is divided evenly among them. A byte inside a cluster has
//! the place behind it.
//!
//! **What fits** (`fit`). A piece cut from a text is shaped without
//! what came after it, so it may be a little wider by itself than it
//! was in the text: the piece that fits is found in the whole, then
//! measured by itself and shortened a cluster at a time until it does.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const exec = sdk.exec;
const utf8 = sdk.utility.utf8;
const unicode = sdk.utility.unicode;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _text = @import("_text.zig");

const Glyph = graphics.fontimage.Glyph;
const TextFont = graphics.TextFont;
const PlacedGlyph = graphics.PlacedGlyph;
const Look = _text.Look;
const Measure = _text.Measure;

/// One glyph of a laid-out text.
pub const Placed = struct {
    /// The glyph, or null for one that could not be made this time: its
    /// advance is kept and nothing is drawn.
    glyph: ?*const Glyph,
    /// The font it is of.
    font: *const TextFont,
    /// The byte of the text its cluster starts at.
    cluster: u32,
    /// How far the point moves past it, before what a style adds.
    advance: i32,
    /// Where it is drawn from the point: columns to the right,
    x: i32,
    /// and rows up.
    y: i32,
};

/// A laid-out text.
pub const Line = struct {
    /// Its glyphs in the order they are drawn, from left to right.
    placed: []Placed,
    /// The memory they are in.
    block: *anyopaque,
};

/// The longest text that is laid out, in bytes, and the most glyphs one
/// may have. A longer one is drawn a character at a time.
const most_bytes = 1 << 20;
const most_glyphs = 1 << 21;

/// How many bytes `fit` lays out first; a text of which all of them fit
/// is tried with twice as many.
const first_take = 64;

/// Whether a text in `font` is laid out here: the font or one of its
/// fallbacks has a `shape` hook.
pub fn wanted(font: *const TextFont) bool {
    var at: ?*const TextFont = font;
    var left: u32 = graphics.FONT_FALLBACKS + 1;
    while (at) |one| : (at = one.fallback) {
        if (left == 0) break;
        left -= 1;
        if (one.shape != null) return true;
    }
    return false;
}

/// The glyphs the `count` bytes of `string` are drawn with in `font`.
/// Null when they are not to be had this time - no memory, a hook that
/// could not shape, a text of no bytes or of too many - and the caller
/// takes the way of a glyph for each character.
///
/// INPUTS:
/// - `gb` - the library.
/// - `font` - the font the text is in.
/// - `string` - the text, UTF-8.
/// - `count` - its length in bytes.
///
/// OWNERSHIP:
/// The caller hands the line to `free`.
pub fn layOut(gb: *GraphicsBase, font: *const TextFont, string: [*]const u8, count: u32) ?Line {
    if (count == 0 or count > most_bytes) return null;
    const sys = gb.sys_base;
    // A glyph for each byte is more than most texts have; one that has
    // more says how many.
    var room: u32 = count + 8;
    var asked: u32 = 0;
    while (asked < 3) : (asked += 1) {
        const each: usize = @sizeOf(Placed) + @sizeOf(PlacedGlyph);
        const block = sys.AllocVec(room * each, exec.MEMF_ANY) orelse return null;
        const placed: [*]Placed = @ptrCast(@alignCast(block));
        const scratch: [*]PlacedGlyph = @ptrFromInt(@intFromPtr(block) + room * @sizeOf(Placed));
        switch (fill(gb, font, string[0..count], placed[0..room], scratch[0..room])) {
            .done => |made| return .{ .placed = placed[0..made], .block = block },
            .room => |need| {
                sys.FreeVec(block);
                if (need <= room or need > most_glyphs) return null;
                room = need;
            },
            .failed => {
                sys.FreeVec(block);
                return null;
            },
        }
    }
    return null;
}

/// Gives back what `layOut` made.
pub fn free(gb: *GraphicsBase, line: Line) void {
    gb.sys_base.FreeVec(line.block);
}

/// What `fill` came to: the glyphs it made, how many it needs room for,
/// or nothing.
const Filled = union(enum) {
    done: u32,
    room: u32,
    failed,
};

/// Lays `bytes` out into `placed`, stretch by stretch. `scratch` is
/// where a hook writes its glyphs before they are looked up, as long as
/// `placed`.
fn fill(gb: *GraphicsBase, line: *const TextFont, bytes: []const u8, placed: []Placed, scratch: []PlacedGlyph) Filled {
    var made: u32 = 0;
    var start: usize = 0;
    var end = unicode.clusterEnd(bytes, 0);
    var font = fontFor(gb, line, bytes[0..end], scratch);
    while (start < bytes.len) {
        // The stretch grows for as long as the next cluster is the same
        // font's.
        var next_end = end;
        var next_font: ?*const TextFont = null;
        while (end < bytes.len) {
            next_end = unicode.clusterEnd(bytes, end);
            next_font = fontFor(gb, line, bytes[end..next_end], scratch);
            if (next_font != font) break;
            end = next_end;
        }
        const stretch = bytes[start..end];
        // What is left behind the stretch has a glyph a byte at most,
        // or says so in its turn.
        const rest: u32 = @intCast(bytes.len - end);
        const shaper = if (font) |one| one.shape else null;
        if (shaper) |hook| {
            const one = font.?;
            var request = graphics.ShapeRequest{
                .text = stretch.ptr,
                .length = @intCast(stretch.len),
                .glyphs = scratch.ptr,
                .room = @intCast(scratch.len),
            };
            switch (gb.utility_base.CallHookPkt(hook, @constCast(one), &request)) {
                graphics.SHAPE_OK => {},
                graphics.SHAPE_ROOM => {
                    // A text that fits and is said not to would be
                    // asked for without end.
                    if (request.count <= scratch.len) return .failed;
                    return .{ .room = made +| request.count +| rest +| 8 };
                },
                else => return .failed,
            }
            if (request.count > scratch.len) return .failed;
            if (request.count > placed.len - made) return .{ .room = made + request.count + rest + 8 };
            var cluster: u32 = 0;
            for (scratch[0..request.count]) |*from| {
                // A cluster lies in the stretch, starts where the text's
                // does - a mark named by its own byte is its letter's -
                // and never goes back.
                const named = @min(from.cluster, @as(u32, @intCast(stretch.len - 1)));
                cluster = @max(cluster, @as(u32, @intCast(boundaryUpTo(stretch, named))));
                placed[made] = .{
                    .glyph = if (from.flags & graphics.GLYPHREQ_NUMBER != 0)
                        _text.glyphByNumber(gb, one, from.which)
                    else
                        _text.glyphIn(gb, one, from.which),
                    .font = one,
                    .cluster = @as(u32, @intCast(start)) + cluster,
                    .advance = from.advance,
                    .x = from.x,
                    .y = from.y,
                };
                made += 1;
            }
        } else {
            var at: usize = 0;
            var cluster: usize = 0;
            var cluster_end: usize = 0;
            while (at < stretch.len) {
                const here = at;
                const code = utf8.next(stretch, &at);
                if (here >= cluster_end) {
                    cluster = here;
                    cluster_end = unicode.clusterEnd(stretch, here);
                }
                if (made == placed.len) return .{ .room = made + @as(u32, @intCast(stretch.len - here)) + rest + 8 };
                var entry = Placed{ .glyph = null, .font = line, .cluster = @intCast(start + cluster), .advance = 0, .x = 0, .y = 0 };
                if (font) |one| {
                    entry.font = one;
                    entry.glyph = _text.glyphIn(gb, one, code);
                } else {
                    const found = _text.glyphOf(gb, line, code);
                    entry.font = found.font;
                    entry.glyph = found.glyph;
                }
                if (entry.glyph) |glyph| entry.advance = glyph.advance;
                placed[made] = entry;
                made += 1;
            }
        }
        start = end;
        end = next_end;
        font = next_font;
    }
    return .{ .done = made };
}

/// Where the last cluster of `bytes`, which is not empty, starts.
fn lastCluster(bytes: []const u8) usize {
    return unicode.clusterStart(bytes, bytes.len - 1);
}

/// The first place at or behind `at` where a cluster starts.
fn boundaryFrom(bytes: []const u8, at: usize) usize {
    const start = unicode.clusterStart(bytes, at);
    return if (start == at) at else unicode.clusterEnd(bytes, start);
}

/// The last place at or before `at` where a cluster starts.
fn boundaryUpTo(bytes: []const u8, at: usize) usize {
    return unicode.clusterStart(bytes, at);
}

/// The font that draws one cluster, or null for a cluster none of the
/// chain draws whole.
fn fontFor(gb: *GraphicsBase, line: *const TextFont, cluster: []const u8, scratch: []PlacedGlyph) ?*const TextFont {
    var at: ?*const TextFont = line;
    var left: u32 = graphics.FONT_FALLBACKS + 1;
    while (at) |one| : (at = one.fallback) {
        if (left == 0) break;
        left -= 1;
        if (hasEach(gb, one, cluster)) return one;
    }
    if (!otherForms(cluster)) return null;
    at = line;
    left = graphics.FONT_FALLBACKS + 1;
    while (at) |one| : (at = one.fallback) {
        if (left == 0) break;
        left -= 1;
        if (shapesAlone(gb, one, cluster, scratch)) return one;
    }
    return null;
}

/// Whether `font` has a glyph for each character of the cluster: its
/// image's, or one its hook makes.
fn hasEach(gb: *GraphicsBase, font: *const TextFont, cluster: []const u8) bool {
    var at: usize = 0;
    while (at < cluster.len) {
        if (_text.glyphIn(gb, font, utf8.next(cluster, &at)) == null) return false;
    }
    return true;
}

/// Whether a font that lacks one of the cluster's characters may draw
/// it all the same: a letter and its marks can be one character or
/// several, a space of a set width is the space moved, and a character
/// that is not shown needs no glyph.
fn otherForms(cluster: []const u8) bool {
    const first = utf8.read(cluster);
    if (first.length < cluster.len) return true;
    if (unicode.base(first.char) != null) return true;
    return switch (unicode.class(first.char)) {
        .space, .format => true,
        // The non-breaking hyphen is drawn with the hyphen.
        else => first.char == 0x2011,
    };
}

/// Whether `font`'s hook shapes the cluster by itself into glyphs the
/// font has: none of them number 0, the glyph of a character it lacks.
fn shapesAlone(gb: *GraphicsBase, font: *const TextFont, cluster: []const u8, scratch: []PlacedGlyph) bool {
    const hook = font.shape orelse return false;
    var request = graphics.ShapeRequest{
        .text = cluster.ptr,
        .length = @intCast(cluster.len),
        .glyphs = scratch.ptr,
        .room = @intCast(scratch.len),
    };
    if (gb.utility_base.CallHookPkt(hook, @constCast(font), &request) != graphics.SHAPE_OK) return false;
    if (request.count > scratch.len) return false;
    for (scratch[0..request.count]) |*glyph| {
        if (glyph.flags & graphics.GLYPHREQ_NUMBER != 0 and glyph.which == 0) return false;
    }
    return true;
}

/// How far the point moves past a glyph: its advance and what the style
/// adds to one. A glyph with no advance - a mark on its letter - gets
/// none from the style either.
pub fn stepOf(entry: *const Placed, look: Look) i32 {
    return if (entry.advance != 0) entry.advance + look.extra else 0;
}

/// The room one more glyph takes after `m`: `m` grown by it, as
/// `_text.grow` grows it by a character's glyph.
///
/// INPUTS:
/// - `m` - what the text so far takes.
/// - `entry` - the next glyph.
/// - `look` - how its font's glyphs are put on the line.
pub fn grow(m: Measure, entry: *const Placed, look: Look) Measure {
    var next = m;
    const at = m.width;
    next.width = at + stepOf(entry, look);
    next.max_x = @max(next.max_x, next.width + look.lean);
    if (entry.glyph) |glyph| {
        if (glyph.width != 0 and glyph.rows != 0) {
            const ink_left = at + entry.x + glyph.left;
            next.min_x = @min(next.min_x, ink_left);
            next.max_x = @max(next.max_x, ink_left + @as(i32, glyph.width) + look.smear + look.lean);
        }
    }
    return next;
}

/// What a laid-out text takes on the line of `line` with `style`.
pub fn measure(line: *const TextFont, style: graphics.FontStyle, placed: []const Placed) Measure {
    var look = _text.lookOf(line, line, style);
    var m = Measure{};
    for (placed) |*entry| {
        if (entry.font != look.font) look = _text.lookOf(line, entry.font, style);
        m = grow(m, entry, look);
    }
    return m;
}

/// One cluster of a laid-out text: the bytes it is and how wide its
/// glyphs are together.
const Cluster = struct {
    from: u32,
    to: u32,
    width: i32,
};

/// The clusters of a laid-out text, from left to right.
const Clusters = struct {
    line: *const TextFont,
    style: graphics.FontStyle,
    placed: []const Placed,
    /// The text's length in bytes.
    length: u32,
    look: Look,
    at: usize = 0,

    fn of(line: *const TextFont, style: graphics.FontStyle, placed: []const Placed, length: u32) Clusters {
        return .{ .line = line, .style = style, .placed = placed, .length = length, .look = _text.lookOf(line, line, style) };
    }

    fn next(self: *Clusters) ?Cluster {
        if (self.at >= self.placed.len) return null;
        const mark = self.placed[self.at].cluster;
        // Bytes before the first glyph's - characters that are not
        // shown - are the first cluster's.
        const from = if (self.at == 0) 0 else mark;
        var width: i32 = 0;
        while (self.at < self.placed.len and self.placed[self.at].cluster <= mark) : (self.at += 1) {
            const entry = &self.placed[self.at];
            if (entry.font != self.look.font) self.look = _text.lookOf(self.line, entry.font, self.style);
            width += stepOf(entry, self.look);
        }
        const to = if (self.at < self.placed.len) self.placed[self.at].cluster else self.length;
        return .{ .from = from, .to = @min(@max(to, from), self.length), .width = width };
    }
};

/// How many of the clusters in `text` - what some glyphs are drawn
/// for together - start before byte `limit`.
fn partsBefore(text: []const u8, limit: usize) u32 {
    var parts: u32 = 0;
    var at: usize = 0;
    while (at < text.len and at < limit) : (at = unicode.clusterEnd(text, at)) parts += 1;
    return parts;
}

/// The byte in `text` at which its cluster `which` starts.
fn partStart(text: []const u8, which: u32) u32 {
    var parts: u32 = 0;
    var at: usize = 0;
    while (at < text.len) : (at = unicode.clusterEnd(text, at)) {
        if (parts == which) return @intCast(at);
        parts += 1;
    }
    return @intCast(text.len);
}

/// How far from the text's start the place before byte `offset` is, in
/// columns: the width of the whole for an offset at or past its end.
///
/// INPUTS:
/// - `line` - the font the text is in.
/// - `style` - the RastPort's style.
/// - `placed` - the text laid out.
/// - `bytes` - the text.
/// - `offset` - the byte.
pub fn xOf(line: *const TextFont, style: graphics.FontStyle, placed: []const Placed, bytes: []const u8, offset: u32) i32 {
    var clusters = Clusters.of(line, style, placed, @intCast(bytes.len));
    var pen: i32 = 0;
    while (clusters.next()) |cluster| {
        if (offset <= cluster.from) return pen;
        if (offset < cluster.to) {
            const text = bytes[cluster.from..cluster.to];
            const parts: i32 = @intCast(partsBefore(text, text.len));
            const before: i32 = @intCast(partsBefore(text, offset - cluster.from));
            return pen + @divTrunc(cluster.width * before, @max(parts, 1));
        }
        pen += cluster.width;
    }
    return pen;
}

/// The byte whose place is nearest column `x` from the text's start:
/// one a cluster starts at, or the text's length.
///
/// INPUTS:
/// - as `xOf`, with `x` for the offset.
pub fn offsetAt(line: *const TextFont, style: graphics.FontStyle, placed: []const Placed, bytes: []const u8, x: i32) u32 {
    var clusters = Clusters.of(line, style, placed, @intCast(bytes.len));
    var pen: i32 = 0;
    while (clusters.next()) |cluster| {
        const text = bytes[cluster.from..cluster.to];
        const parts: i32 = @intCast(partsBefore(text, text.len));
        var part: i32 = 0;
        while (part < parts) : (part += 1) {
            const left = pen + @divTrunc(cluster.width * part, parts);
            const right = pen + @divTrunc(cluster.width * (part + 1), parts);
            // Nearer the part's left edge than its right one.
            if (2 * x < left + right) return cluster.from + partStart(text, @intCast(part));
        }
        pen += cluster.width;
    }
    return @intCast(bytes.len);
}

/// How many bytes of `bytes` - whole clusters from its start, or with
/// `backward` from its end - take no more than `room_w` columns drawn
/// by themselves, and in `room` what they take. Null when the text
/// could not be laid out.
///
/// INPUTS:
/// - `gb` - the library.
/// - `line` - the font the text is in.
/// - `style` - the RastPort's style.
/// - `bytes` - the text, not empty.
/// - `backward` - the piece is taken from the end.
/// - `room_w` - the columns there are; below 0 for any number.
/// - `room` - where the piece's measure goes.
pub fn fit(gb: *GraphicsBase, line: *const TextFont, style: graphics.FontStyle, bytes: []const u8, backward: bool, room_w: i32, room: *Measure) ?u32 {
    var take: usize = if (room_w < 0) bytes.len else @min(bytes.len, first_take);
    while (true) {
        // A piece of the text that is more than fits, or all of it.
        take = if (backward) bytes.len - boundaryUpTo(bytes, bytes.len - take) else boundaryFrom(bytes, take);
        const piece = if (backward) bytes[bytes.len - take ..] else bytes[0..take];
        const laid = layOut(gb, line, piece.ptr, @intCast(piece.len)) orelse return null;
        const whole = measure(line, style, laid.placed);
        if (room_w < 0 or whole.max_x - whole.min_x <= room_w) {
            free(gb, laid);
            if (take == bytes.len) {
                room.* = whole;
                return @intCast(take);
            }
            take = @min(bytes.len, take * 2);
            continue;
        }
        var fits = fitting(line, style, laid.placed, @intCast(piece.len), backward, room_w);
        free(gb, laid);
        room.* = .{};
        while (fits != 0) {
            const part = if (backward) piece[piece.len - fits ..] else piece[0..fits];
            const alone = layOut(gb, line, part.ptr, @intCast(part.len)) orelse return null;
            const taken = measure(line, style, alone.placed);
            free(gb, alone);
            if (taken.max_x - taken.min_x <= room_w) {
                room.* = taken;
                break;
            }
            fits = if (backward) fits - @as(u32, @intCast(unicode.clusterEnd(part, 0))) else @intCast(lastCluster(part));
        }
        return fits;
    }
}

/// How many bytes of a laid-out text, whole clusters from its start or
/// its end, have advances of no more than `room_w` columns together.
fn fitting(line: *const TextFont, style: graphics.FontStyle, placed: []const Placed, length: u32, backward: bool, room_w: i32) u32 {
    const total = measure(line, style, placed).width;
    var clusters = Clusters.of(line, style, placed, length);
    var pen: i32 = 0;
    var fits: u32 = 0;
    while (clusters.next()) |cluster| {
        if (backward) {
            if (total - pen <= room_w) return length - cluster.from;
            pen += cluster.width;
            continue;
        }
        pen += cluster.width;
        if (pen > room_w) break;
        fits = cluster.to;
    }
    return fits;
}
