// SPDX-License-Identifier: MIT
//! One glyph rendered: its contours scaled into pixels, its curves
//! flattened into lines, and the area each pixel has inside it measured.
//!
//! The measuring is by signed area. Every line of the outline adds to an
//! accumulation buffer, for each row it crosses, the share of each pixel
//! it passes that lies to its right, positive going down and negative
//! going up; summing a row from its left edge then gives, at every pixel,
//! how much of it the outline covers - exactly, for any shape, with
//! nothing to sort and no edge list. A curve, quadratic or cubic, is
//! lines enough that none strays from it by more than a third of a
//! pixel. The coverage is kept in four bits (0 to 15).
//!
//! What a font says is not taken on trust: a glyph whose outline lies
//! further from its origin than `Scale.reach` is rendered as one of no
//! outline, so that every number worked with afterwards has a known
//! size.
//!
//! A font without outlines whose glyphs are pictures is rendered by
//! `_picture.zig`: `renderGlyph` hands such a glyph over, and `kindOf`
//! says what its pixels are.

const sdk = @import("sdk");
const exec = sdk.exec;
const fontimage = sdk.graphics.fontimage;
const _picture = @import("_picture.zig");
const _outline = @import("../outline/_outline.zig");
const _variation = @import("../outline/_variation.zig");
const Font = _outline.Font;
const Point = _outline.Point;
const ExecBase = sdk.interface.exec.ExecBase;

/// A point in pixels.
const P = struct { x: f32, y: f32 };

/// A glyph as it came out: its box from the point and the top of the
/// line, its advance, and its pixels, which the caller frees: coverage,
/// a byte a pixel (0 to 15), or for a font of colour pictures four bytes
/// a pixel (red, green, blue, coverage).
pub const Rendered = struct {
    left: i32 = 0,
    top: i32 = 0,
    width: u32 = 0,
    rows: u32 = 0,
    advance: i32 = 0,
    pixels: ?[*]u8 = null,
};

/// The room one rendering works in: the points and contours of the glyph
/// being read. Made once per size, by the call that renders, and its
/// own.
pub const Work = struct {
    contours: _outline.Contours,
    memory: ?*anyopaque,

    /// Room for the largest glyph `font` says it has, and no less than a
    /// font that does not say is read with.
    pub fn init(sys: *ExecBase, font: *const Font) ?Work {
        // A font of pictures reads no contours.
        if (!_outline.hasOutlines(font)) return of(sys, 1, 1, false);
        const points: u32 = @max(font.max_points + 1, _outline.default_points);
        const contours: u32 = @max(font.max_contours + 1, _outline.default_contours);
        return of(sys, points, contours, _outline.isVaried(font));
    }

    /// Room for `points` points and `contours` contours, and for a font
    /// whose glyphs are `varied` the room their deltas are read in.
    fn of(sys: *ExecBase, points: u32, contours: u32, varied: bool) ?Work {
        const plain = points * @sizeOf(Point) + contours * 4 + points;
        const bytes = plain + (if (varied) _variation.Scratch.bytes(points) else 0);
        const memory = sys.AllocVec(bytes, exec.MEMF_ANY) orelse return null;
        const base: [*]u8 = @ptrCast(memory);
        const point_area: [*]Point = @ptrCast(@alignCast(base));
        const ends: [*]u32 = @ptrCast(@alignCast(base + points * @sizeOf(Point)));
        const flags = base + points * @sizeOf(Point) + contours * 4;
        return .{
            .contours = .{
                .points = point_area[0..points],
                .ends = ends[0..contours],
                .flags = flags[0..points],
                .vary = if (varied) _variation.Scratch.within(base + plain, points) else null,
            },
            .memory = memory,
        };
    }

    /// The room made as large as a glyph that did not fit says it needs;
    /// false without memory, the room then as it was.
    fn grow(work: *Work, sys: *ExecBase) bool {
        const larger = of(sys, work.contours.needed_points + 1, work.contours.needed_ends + 1, work.contours.vary != null) orelse return false;
        sys.FreeVec(work.memory);
        work.* = larger;
        return true;
    }

    pub fn deinit(work: *Work, sys: *ExecBase) void {
        sys.FreeVec(work.memory);
    }
};

/// Units to pixels, and where the top of the line is in units.
pub const Scale = struct {
    factor: f32,
    ascender: f32,
    /// The line's height in pixels.
    rows: u32,
    /// How far a glyph's outline may lie from its origin and from the top
    /// of its line, in pixels, any way: `reachOf` the line's height.
    reach: f32,

    fn of(scale: Scale, p: Point) P {
        return .{ .x = p.x * scale.factor, .y = (scale.ascender - p.y) * scale.factor };
    }
};

/// The tallest line rendered, in pixels.
pub const most_rows = 4096;

/// The furthest a glyph moves the point, in pixels: what a font image's
/// glyph has a number for.
const most_advance = 32767;

/// How far a glyph of a line `rows` tall may reach: sixteen lines, which
/// is past the widest glyph a font has, and no more than a font image's
/// glyph has numbers for.
pub fn reachOf(rows: u32) f32 {
    const line: u32 = @min(rows, most_rows);
    const reach: u32 = @min(line * 16, 16000);
    return @floatFromInt(reach);
}

/// The scale of a line `rows` tall: the font's ascender to its descender
/// made that many pixels.
pub fn scaleOf(font: *const Font, rows: u32) Scale {
    const units: f32 = @floatFromInt(font.ascender - font.descender);
    return .{
        .factor = @as(f32, @floatFromInt(rows)) / units,
        .ascender = @floatFromInt(font.ascender),
        .rows = rows,
        .reach = reachOf(rows),
    };
}

/// What the pixels of the font's glyphs are: colour for a font of colour
/// pictures, coverage for every other.
pub fn kindOf(font: *const Font) fontimage.Kind {
    return if (font.strikes.count != 0 and font.strikes.colour) .rgba32 else .alpha4;
}

/// A glyph's pixels as a font image of `kind` keeps them, each row
/// `pitch` bytes: coverage two pixels a byte, the left one in the high
/// four bits; colour as it is. Every byte of the glyph's rows at `out`
/// is written.
pub fn pack(kind: fontimage.Kind, glyph: *const Rendered, out: [*]u8, pitch: u32) void {
    const pixels = glyph.pixels orelse return;
    if (kind == .rgba32) {
        for (0..glyph.rows) |y| {
            @memcpy(out[y * pitch ..][0 .. glyph.width * 4], pixels[y * glyph.width * 4 ..][0 .. glyph.width * 4]);
        }
        return;
    }
    for (0..glyph.rows) |y| {
        const row = pixels + y * glyph.width;
        const packed_row = out + y * pitch;
        var x: u32 = 0;
        while (x < glyph.width) : (x += 2) {
            const right: u8 = if (x + 1 < glyph.width) row[x + 1] else 0;
            packed_row[x / 2] = row[x] << 4 | right;
        }
    }
}

/// How far `glyph` moves the point at `scale`, in whole pixels.
pub fn advanceOf(font: *const Font, glyph: u32, scale: Scale) i32 {
    return @min(roundOf(@as(f32, @floatFromInt(_outline.advanceOf(font, glyph))) * scale.factor), most_advance);
}

/// `glyph` of `font` rendered at `scale`; null only without memory.
pub fn renderGlyph(sys: *ExecBase, font: *const Font, glyph: u32, scale: Scale, work: *Work) ?Rendered {
    var out = Rendered{ .advance = advanceOf(font, glyph, scale) };
    if (_outline.hasPictures(font)) return _picture.render(sys, font, glyph, scale, out);
    const c = &work.contours;
    c.point_count = 0;
    c.end_count = 0;
    c.part_count = 0;
    const identity = [6]f32{ 1, 0, 0, 1, 0, 0 };
    if (!_outline.contours(font, glyph, c, identity, 0)) {
        // A glyph of cubic curves larger than the room: read once more
        // into as much as it says it has.
        if (!c.short) return out;
        if (!work.grow(sys)) return null;
        if (!_outline.contours(font, glyph, c, identity, 0)) return out;
    }
    if (c.point_count == 0) return out;

    var min_x: f32 = 1e30;
    var min_y: f32 = 1e30;
    var max_x: f32 = -1e30;
    var max_y: f32 = -1e30;
    const reach = scale.reach;
    for (c.points[0..c.point_count]) |p| {
        const q = scale.of(p);
        // Out of reach, or not a number at all: asked the other way round,
        // so that neither passes.
        if (!(q.x >= -reach and q.x <= reach and q.y >= -reach and q.y <= reach)) return out;
        min_x = @min(min_x, q.x);
        min_y = @min(min_y, q.y);
        max_x = @max(max_x, q.x);
        max_y = @max(max_y, q.y);
    }
    // An edge a rounding error off a pixel's border is on it: no row or
    // column of nothing but that error.
    const snap: f32 = 1.0 / 1024.0;
    const left: i32 = @intFromFloat(@floor(min_x + snap));
    const top: i32 = @intFromFloat(@floor(min_y + snap));
    const width: u32 = @intCast(@max(@as(i32, @intFromFloat(@ceil(max_x - snap))) - left, 1));
    const rows: u32 = @intCast(@max(@as(i32, @intFromFloat(@ceil(max_y - snap))) - top, 1));
    const stride = width + 2;

    // More than the machine has addresses for is no memory.
    const bytes = @as(u64, stride) * rows * @sizeOf(f32);
    if (bytes > ~@as(usize, 0)) return null;
    const acc_memory = sys.AllocVec(@intCast(bytes), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    defer sys.FreeVec(acc_memory);
    const acc: [*]f32 = @ptrCast(@alignCast(acc_memory));
    var area = Area{ .acc = acc[0 .. stride * rows], .stride = stride, .rows = rows };
    const origin = P{ .x = @floatFromInt(left), .y = @floatFromInt(top) };

    var start: u32 = 0;
    for (c.ends[0..c.end_count]) |end| {
        contour(&area, c.points[start..end], scale, origin);
        start = end;
    }

    // The coverage, summed along each row in place of what was added.
    var ink_left: u32 = width;
    var ink_right: u32 = 0;
    var ink_top: u32 = rows;
    var ink_bottom: u32 = 0;
    for (0..rows) |y| {
        var sum: f32 = 0;
        for (0..width) |x| {
            sum += area.acc[y * stride + x];
            const cover: f32 = @floatFromInt(@as(u8, @intFromFloat(@min(@abs(sum), 1.0) * 15.0 + 0.5)));
            area.acc[y * stride + x] = cover;
            if (cover == 0) continue;
            ink_left = @min(ink_left, @as(u32, @intCast(x)));
            ink_right = @max(ink_right, @as(u32, @intCast(x)) + 1);
            ink_top = @min(ink_top, @as(u32, @intCast(y)));
            ink_bottom = @max(ink_bottom, @as(u32, @intCast(y)) + 1);
        }
    }
    // The box cut to the ink: a control point off the curve widens the
    // outline's bounds past where anything is drawn.
    if (ink_right == 0) return out;
    const ink_width = ink_right - ink_left;
    const ink_rows = ink_bottom - ink_top;
    const pixels: [*]u8 = @ptrCast(sys.AllocVec(ink_width * ink_rows, exec.MEMF_ANY) orelse return null);
    for (0..ink_rows) |y| for (0..ink_width) |x| {
        pixels[y * ink_width + x] = @intFromFloat(area.acc[(ink_top + y) * stride + ink_left + x]);
    };
    out.left = left + @as(i32, @intCast(ink_left));
    out.top = top + @as(i32, @intCast(ink_top));
    out.width = ink_width;
    out.rows = ink_rows;
    out.pixels = pixels;
    return out;
}

fn roundOf(value: f32) i32 {
    return @intFromFloat(@floor(value + 0.5));
}

/// One closed contour: lines between points on the curve, a quadratic
/// curve round each point off it, and between two off it the point on
/// the curve halfway, which the format leaves out; a cubic curve through
/// two control points to the point after them.
fn contour(area: *Area, points: []const Point, scale: Scale, origin: P) void {
    const n = points.len;
    if (n < 2) return;
    const at = struct {
        fn f(s: Scale, o: P, p: Point) P {
            const q = s.of(p);
            return .{ .x = q.x - o.x, .y = q.y - o.y };
        }
    }.f;
    // Where to begin: a point on the curve, or halfway between the first
    // and last when neither is.
    var begin: P = undefined;
    var from: usize = 0;
    var count: usize = n;
    if (points[0].on) {
        begin = at(scale, origin, points[0]);
        from = 1;
        count = n - 1;
    } else if (points[n - 1].on) {
        begin = at(scale, origin, points[n - 1]);
        from = 0;
        count = n - 1;
    } else {
        const a = at(scale, origin, points[0]);
        const b = at(scale, origin, points[n - 1]);
        begin = .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
    }
    var current = begin;
    var control: ?P = null;
    var k: usize = 0;
    while (k < count) : (k += 1) {
        const p = points[from + k];
        const q = at(scale, origin, p);
        if (p.cubic) {
            if (k + 2 >= count) break;
            const second = at(scale, origin, points[from + k + 1]);
            const last = at(scale, origin, points[from + k + 2]);
            area.cubic(current, q, second, last);
            current = last;
            k += 2;
        } else if (p.on) {
            if (control) |ctl| area.quad(current, ctl, q) else area.line(current, q);
            current = q;
            control = null;
        } else if (control) |ctl| {
            const mid = P{ .x = (ctl.x + q.x) / 2, .y = (ctl.y + q.y) / 2 };
            area.quad(current, ctl, mid);
            current = mid;
            control = q;
        } else {
            control = q;
        }
    }
    if (control) |ctl| area.quad(current, ctl, begin) else area.line(current, begin);
}

/// The accumulation buffer: a row of `stride` a pixel wide, two more than
/// the glyph, so a line on its right edge still has somewhere to put what
/// lies right of it.
const Area = struct {
    acc: []f32,
    stride: u32,
    rows: u32,

    fn add(area: *Area, row_start: usize, x: i32, value: f32) void {
        if (x < 0 or x >= area.stride) return;
        area.acc[row_start + @as(usize, @intCast(x))] += value;
    }

    /// A curve as lines, as many as keep them within a third of a pixel.
    fn quad(area: *Area, p0: P, p1: P, p2: P) void {
        const dx = p0.x - 2 * p1.x + p2.x;
        const dy = p0.y - 2 * p1.y + p2.y;
        const dev = dx * dx + dy * dy;
        if (dev < 0.333) return area.line(p0, p2);
        const steps: u32 = @min(1 + @as(u32, @intFromFloat(@floor(@sqrt(@sqrt(3.0 * dev))))), 32);
        var last = p0;
        var i: u32 = 1;
        while (i <= steps) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            const u = 1 - t;
            const next = P{
                .x = u * u * p0.x + 2 * t * u * p1.x + t * t * p2.x,
                .y = u * u * p0.y + 2 * t * u * p1.y + t * t * p2.y,
            };
            area.line(last, next);
            last = next;
        }
    }

    /// A cubic curve as lines, held as close to it as a quadratic's: its
    /// bend is no more than the larger of its two halves' control
    /// points say.
    fn cubic(area: *Area, p0: P, p1: P, p2: P, p3: P) void {
        const ax = p0.x - 2 * p1.x + p2.x;
        const ay = p0.y - 2 * p1.y + p2.y;
        const bx = p1.x - 2 * p2.x + p3.x;
        const by = p1.y - 2 * p2.y + p3.y;
        const dev = @max(ax * ax + ay * ay, bx * bx + by * by);
        if (dev < 0.037) return area.line(p0, p3);
        const steps: u32 = @min(1 + @as(u32, @intFromFloat(@floor(@sqrt(@sqrt(27.0 * dev))))), 64);
        var last = p0;
        var i: u32 = 1;
        while (i <= steps) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            const u = 1 - t;
            const b0 = u * u * u;
            const b1 = 3 * u * u * t;
            const b2 = 3 * u * t * t;
            const b3 = t * t * t;
            const next = P{
                .x = b0 * p0.x + b1 * p1.x + b2 * p2.x + b3 * p3.x,
                .y = b0 * p0.y + b1 * p1.y + b2 * p2.y + b3 * p3.y,
            };
            area.line(last, next);
            last = next;
        }
    }

    /// A line's share of each pixel of each row it crosses.
    fn line(area: *Area, p0: P, p1: P) void {
        if (p0.y == p1.y) return;
        const dir: f32 = if (p0.y < p1.y) 1 else -1;
        const a = if (p0.y < p1.y) p0 else p1;
        const b = if (p0.y < p1.y) p1 else p0;
        const dxdy = (b.x - a.x) / (b.y - a.y);
        const rows: f32 = @floatFromInt(area.rows);
        // The columns there are, one to each side: where a line stays
        // whatever its slope comes to when it is next to level.
        const edge: f32 = @floatFromInt(area.stride);
        var x = a.x;
        var y_top = a.y;
        if (y_top < 0) {
            x -= y_top * dxdy;
            y_top = 0;
        }
        x = @min(@max(x, -1), edge);
        const y_bottom = @min(b.y, rows);
        if (y_top >= y_bottom) return;
        var y: usize = @intFromFloat(@floor(y_top));
        const y_end: usize = @intFromFloat(@ceil(y_bottom));
        while (y < y_end) : (y += 1) {
            const row_start = y * area.stride;
            const yf: f32 = @floatFromInt(y);
            const dy = @min(yf + 1, y_bottom) - @max(yf, y_top);
            const x_next = @min(@max(x + dxdy * dy, -1), edge);
            const d = dy * dir;
            const x0 = @min(x, x_next);
            const x1 = @max(x, x_next);
            const x0_floor = @floor(x0);
            const x0i: i32 = @intFromFloat(x0_floor);
            const x1_ceil = @ceil(x1);
            const x1i: i32 = @intFromFloat(x1_ceil);
            if (x1i <= x0i + 1) {
                const xmf = 0.5 * (x + x_next) - x0_floor;
                area.add(row_start, x0i, d - d * xmf);
                area.add(row_start, x0i + 1, d * xmf);
            } else {
                const s = 1 / (x1 - x0);
                const x0f = x0 - x0_floor;
                const a0 = 0.5 * s * (1 - x0f) * (1 - x0f);
                const x1f = x1 - x1_ceil + 1;
                const am = 0.5 * s * x1f * x1f;
                area.add(row_start, x0i, d * a0);
                if (x1i == x0i + 2) {
                    area.add(row_start, x0i + 1, d * (1 - a0 - am));
                } else {
                    const a1 = s * (1.5 - x0f);
                    area.add(row_start, x0i + 1, d * (a1 - a0));
                    var xi = x0i + 2;
                    while (xi < x1i - 1) : (xi += 1) area.add(row_start, xi, d * s);
                    const a2 = a1 + @as(f32, @floatFromInt(x1i - x0i - 3)) * s;
                    area.add(row_start, x1i - 1, d * (1 - a2 - am));
                }
                area.add(row_start, x1i, d * am);
            }
            x = x_next;
        }
    }
};
