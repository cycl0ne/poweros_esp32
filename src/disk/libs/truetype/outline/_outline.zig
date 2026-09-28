// SPDX-License-Identifier: MIT
//! A TrueType file as the renderer reads it: its tables, the character
//! map, the horizontal metrics, and each glyph's contours.
//!
//! Everything is read in place from the caller's bytes, big-endian, every
//! offset checked against the table it is in before it is followed, so a
//! damaged file gives a missing glyph and never a read outside it.
//!
//! A glyph is a list of contours, each a closed loop of points, on the
//! curve or off it: two points on the curve are a line, one off it between
//! two on it the control point of a quadratic curve, and two off it in a
//! row have an implied point on the curve halfway between them. A
//! composite glyph is other glyphs, each moved and possibly scaled; they
//! are read into the same list, to a limited depth.

const sdk = @import("sdk");

/// A font file, opened: where its tables are and the measures rendering
/// needs. What `OpenOutline` answers, behind `truetype.Outline`.
pub const Font = struct {
    data: [*]const u8,
    size: u32,
    units_per_em: u32,
    /// Whether `loca` holds 32-bit offsets rather than halved 16-bit ones.
    loca_long: bool,
    glyph_count: u32,
    /// From `hhea`: above the baseline, below it (negative), in units.
    ascender: i32,
    descender: i32,
    hmetric_count: u32,
    loca: Table,
    glyf: Table,
    hmtx: Table,
    /// The character map's subtable used, and its format (4 or 12).
    cmap: Table,
    cmap_format: u32,
};

/// Where a table is in the file.
pub const Table = struct {
    at: u32 = 0,
    len: u32 = 0,
};

/// One point of a glyph, in font units.
pub const Point = struct {
    x: f32,
    y: f32,
    on: bool,
};

/// A glyph's contours: `points`, and the index after each contour's last
/// point in `ends`.
pub const Contours = struct {
    points: []Point,
    ends: []u32,
    /// Room for one simple glyph's flags while its points are read.
    flags: []u8,
    point_count: u32 = 0,
    end_count: u32 = 0,
};

pub fn u16At(font: *const Font, at: u32) u16 {
    if (at + 2 > font.size) return 0;
    return @as(u16, font.data[at]) << 8 | font.data[at + 1];
}

pub fn i16At(font: *const Font, at: u32) i16 {
    return @bitCast(u16At(font, at));
}

pub fn u32At(font: *const Font, at: u32) u32 {
    return @as(u32, u16At(font, at)) << 16 | u16At(font, at + 2);
}

/// The table of a four-letter tag, or null.
pub fn findTable(font: *const Font, tag: *const [4]u8) ?Table {
    const count = u16At(font, 4);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const record = 12 + i * 16;
        if (record + 16 > font.size) return null;
        const name = font.data[record..][0..4];
        if (name[0] != tag[0] or name[1] != tag[1] or name[2] != tag[2] or name[3] != tag[3]) continue;
        const at = u32At(font, record + 8);
        const len = u32At(font, record + 12);
        if (at > font.size or len > font.size - at) return null;
        return .{ .at = at, .len = len };
    }
    return null;
}

/// The font's tables read and checked; false if it lacks one it needs.
pub fn open(font: *Font, data: [*]const u8, size: u32) bool {
    font.* = undefined;
    font.data = data;
    font.size = size;
    if (size < 12 or !sdk.truetype.isTrueType(data[0..4])) return false;
    const head = findTable(font, "head") orelse return false;
    const hhea = findTable(font, "hhea") orelse return false;
    const maxp = findTable(font, "maxp") orelse return false;
    const cmap = findTable(font, "cmap") orelse return false;
    font.loca = findTable(font, "loca") orelse return false;
    font.glyf = findTable(font, "glyf") orelse return false;
    font.hmtx = findTable(font, "hmtx") orelse return false;
    if (head.len < 54 or hhea.len < 36 or maxp.len < 6) return false;
    font.units_per_em = u16At(font, head.at + 18);
    font.loca_long = i16At(font, head.at + 50) != 0;
    font.glyph_count = u16At(font, maxp.at + 4);
    font.ascender = i16At(font, hhea.at + 4);
    font.descender = i16At(font, hhea.at + 6);
    font.hmetric_count = u16At(font, hhea.at + 34);
    if (font.units_per_em == 0 or font.hmetric_count == 0 or font.ascender <= font.descender) return false;
    return pickCmap(font, cmap);
}

/// The character map's subtable to read: Unicode, full (format 12) before
/// the basic plane (format 4).
fn pickCmap(font: *Font, cmap: Table) bool {
    const count = u16At(font, cmap.at + 2);
    var best: ?Table = null;
    var best_format: u32 = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const record = cmap.at + 4 + i * 8;
        if (record + 8 > cmap.at + cmap.len) break;
        const platform = u16At(font, record);
        const encoding = u16At(font, record + 2);
        const unicode = platform == 0 or (platform == 3 and (encoding == 1 or encoding == 10));
        if (!unicode) continue;
        const at = cmap.at + u32At(font, record + 4);
        const format = u16At(font, at);
        if (format != 4 and format != 12) continue;
        if (best == null or format > best_format) {
            best = .{ .at = at, .len = cmap.at + cmap.len - at };
            best_format = format;
        }
    }
    font.cmap = best orelse return false;
    font.cmap_format = best_format;
    return true;
}

/// The glyph a character is, 0 (the missing glyph) when it has none.
pub fn glyphIndex(font: *const Font, code: u32) u32 {
    const at = font.cmap.at;
    if (font.cmap_format == 12) {
        const groups = u32At(font, at + 12);
        var i: u32 = 0;
        while (i < groups) : (i += 1) {
            const group = at + 16 + i * 12;
            if (group + 12 > font.size) return 0;
            const first = u32At(font, group);
            const last = u32At(font, group + 4);
            if (code >= first and code <= last) return u32At(font, group + 8) + (code - first);
        }
        return 0;
    }
    if (code > 0xFFFF) return 0;
    const seg_count = u16At(font, at + 6) / 2;
    const ends = at + 14;
    const starts = ends + seg_count * 2 + 2;
    const deltas = starts + seg_count * 2;
    const offsets = deltas + seg_count * 2;
    var i: u32 = 0;
    while (i < seg_count) : (i += 1) {
        if (u16At(font, ends + i * 2) < code) continue;
        const start = u16At(font, starts + i * 2);
        if (start > code) return 0;
        const delta = u16At(font, deltas + i * 2);
        const offset = u16At(font, offsets + i * 2);
        if (offset == 0) return (code +% delta) & 0xFFFF;
        const glyph = u16At(font, offsets + i * 2 + offset + (code - start) * 2);
        if (glyph == 0) return 0;
        return (glyph +% delta) & 0xFFFF;
    }
    return 0;
}

/// How far a glyph moves the point, in units.
pub fn advanceOf(font: *const Font, glyph: u32) i32 {
    const index = @min(glyph, font.hmetric_count - 1);
    return u16At(font, font.hmtx.at + index * 4);
}

/// Where a glyph's data is in `glyf`, and how long; empty for a glyph of
/// no outline.
fn glyphData(font: *const Font, glyph: u32) ?Table {
    if (glyph >= font.glyph_count) return null;
    const start, const end = if (font.loca_long)
        .{ u32At(font, font.loca.at + glyph * 4), u32At(font, font.loca.at + glyph * 4 + 4) }
    else
        .{ @as(u32, u16At(font, font.loca.at + glyph * 2)) * 2, @as(u32, u16At(font, font.loca.at + glyph * 2 + 2)) * 2 };
    if (end <= start or end > font.glyf.len) return null;
    return .{ .at = font.glyf.at + start, .len = end - start };
}

/// How deep composite glyphs may nest.
const max_depth = 4;

/// A glyph's contours added to `into`, transformed by `m` (a, b, c, d,
/// dx, dy: x' = a x + c y + dx, y' = b x + d y + dy). False when they do
/// not fit or the data is damaged.
pub fn contours(font: *const Font, glyph: u32, into: *Contours, m: [6]f32, depth: u32) bool {
    const data = glyphData(font, glyph) orelse return true;
    const count = i16At(font, data.at);
    if (count >= 0) return simple(font, data, @intCast(count), into, m);
    if (depth >= max_depth) return false;
    return composite(font, data, into, m, depth);
}

fn simple(font: *const Font, data: Table, contour_count: u32, into: *Contours, m: [6]f32) bool {
    const ends_at = data.at + 10;
    if (contour_count == 0) return true;
    const point_count: u32 = @as(u32, u16At(font, ends_at + (contour_count - 1) * 2)) + 1;
    if (into.point_count + point_count > into.points.len) return false;
    if (into.end_count + contour_count > into.ends.len) return false;
    const base = into.point_count;
    var i: u32 = 0;
    while (i < contour_count) : (i += 1) {
        into.ends[into.end_count + i] = base + @as(u32, u16At(font, ends_at + i * 2)) + 1;
    }
    const instructions = u16At(font, ends_at + contour_count * 2);
    var at = ends_at + contour_count * 2 + 2 + instructions;
    const limit = data.at + data.len;

    // The flags, a byte a point unless one says it repeats.
    const points = into.points[base..][0..point_count];
    const flags_of = into.flags;
    if (point_count > flags_of.len) return false;
    var n: u32 = 0;
    while (n < point_count) {
        if (at >= limit) return false;
        const flag = font.data[at];
        at += 1;
        flags_of[n] = flag;
        n += 1;
        if (flag & 8 != 0) {
            if (at >= limit) return false;
            var repeat = font.data[at];
            at += 1;
            while (repeat > 0 and n < point_count) : (repeat -= 1) {
                flags_of[n] = flag;
                n += 1;
            }
        }
    }
    // x, then y: a byte with the flag's sign, the same as before, or a word.
    var x: i32 = 0;
    for (0..point_count) |p| {
        const flag = flags_of[p];
        if (flag & 2 != 0) {
            if (at >= limit) return false;
            const step: i32 = font.data[at];
            at += 1;
            x += if (flag & 16 != 0) step else -step;
        } else if (flag & 16 == 0) {
            x += i16At(font, at);
            at += 2;
        }
        points[p].x = @floatFromInt(x);
        points[p].on = flag & 1 != 0;
    }
    var y: i32 = 0;
    for (0..point_count) |p| {
        const flag = flags_of[p];
        if (flag & 4 != 0) {
            if (at >= limit) return false;
            const step: i32 = font.data[at];
            at += 1;
            y += if (flag & 32 != 0) step else -step;
        } else if (flag & 32 == 0) {
            y += i16At(font, at);
            at += 2;
        }
        points[p].y = @floatFromInt(y);
    }
    if (at > limit) return false;
    for (points) |*p| {
        const px = p.x;
        const py = p.y;
        p.x = m[0] * px + m[2] * py + m[4];
        p.y = m[1] * px + m[3] * py + m[5];
    }
    into.point_count += point_count;
    into.end_count += contour_count;
    return true;
}

fn composite(font: *const Font, data: Table, into: *Contours, m: [6]f32, depth: u32) bool {
    var at = data.at + 10;
    const limit = data.at + data.len;
    while (at + 4 <= limit) {
        const flags = u16At(font, at);
        const part = u16At(font, at + 2);
        at += 4;
        var dx: f32 = 0;
        var dy: f32 = 0;
        if (flags & 1 != 0) {
            dx = @floatFromInt(i16At(font, at));
            dy = @floatFromInt(i16At(font, at + 2));
            at += 4;
        } else {
            dx = @floatFromInt(@as(i8, @bitCast(font.data[at])));
            dy = @floatFromInt(@as(i8, @bitCast(font.data[at + 1])));
            at += 2;
        }
        // Offsets that name points to match are not followed: the part
        // stays where it was drawn.
        if (flags & 2 == 0) {
            dx = 0;
            dy = 0;
        }
        var a: f32 = 1;
        var b: f32 = 0;
        var c: f32 = 0;
        var d: f32 = 1;
        if (flags & 8 != 0) {
            a = f2dot14(font, at);
            d = a;
            at += 2;
        } else if (flags & 0x40 != 0) {
            a = f2dot14(font, at);
            d = f2dot14(font, at + 2);
            at += 4;
        } else if (flags & 0x80 != 0) {
            a = f2dot14(font, at);
            b = f2dot14(font, at + 2);
            c = f2dot14(font, at + 4);
            d = f2dot14(font, at + 6);
            at += 8;
        }
        // The part's own transform, then the whole glyph's.
        const own = [6]f32{
            m[0] * a + m[2] * b,
            m[1] * a + m[3] * b,
            m[0] * c + m[2] * d,
            m[1] * c + m[3] * d,
            m[0] * dx + m[2] * dy + m[4],
            m[1] * dx + m[3] * dy + m[5],
        };
        if (!contours(font, part, into, own, depth + 1)) return false;
        if (flags & 0x20 == 0) break;
    }
    return true;
}

fn f2dot14(font: *const Font, at: u32) f32 {
    return @as(f32, @floatFromInt(i16At(font, at))) / 16384.0;
}
