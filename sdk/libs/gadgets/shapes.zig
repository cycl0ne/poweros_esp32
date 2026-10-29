// SPDX-License-Identifier: MIT
//! Shapes: what the drawn pictures - the docklets, the command images -
//! draw with. Every shape has smooth edges and is drawn in its own square,
//! 0 to `size` each way, so a picture is the same at every size.
//!
//! `Frame` draws in pixels and in the screen's pens; the docklets draw on
//! it. `Painter` draws in colour: a fixed palette of eleven hues, each in
//! three tones (`Hue`, `tones`), and shapes in design units - a grid of 100
//! by 100 over the square - built up in layers, as the command images are:
//!
//! - a soft shadow under the shapes, black at 22 %, put down once for all
//!   of them so that where two meet it is no darker;
//! - the shapes whole in the hue's dark tone, which is their rim;
//! - the shapes again, set in by the rim, shaded from the light tone at
//!   the top to the hue at the bottom;
//! - a gloss over the top half, white fading out.
//!
//! Under 20 pixels there is no shadow, gloss or shading, only the hue and
//! its rim, so that nothing blurs. What stands on the ground itself - a
//! letter, a line of text - is ink, the screen's text pen. Drawn disabled,
//! every colour is its grey, faded most of the way into the ground.
//!
//!   var p = shapes.Painter.begin(frame, .{});
//!   defer p.end();
//!   p.solid(&.{p.rr(8, 12, 74, 94, 7)}, .brown, .{});
//!   p.ink(&.{p.rr(22, 10, 42, 90, 0)});

const utility = @import("../utility/utility.zig");
const graphics = @import("../graphics/graphics.zig");
const rtg = @import("../rtg/rtg.zig");
const sc = @import("../intuition/screens.zig");
const support = @import("support.zig");
const GraphicsBase = @import("../../interface/graphics.zig").GraphicsBase;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;

// --- in pixels, in the screen's pens ------------------------------------------------

/// The pens a picture draws in: the screen's, and a track between its
/// text and its ground for what is empty.
pub const Pens = struct {
    text: Pen = 0xFF00_0000,
    shine: Pen = 0xFFFF_FFFF,
    shadow: Pen = 0xFF00_0000,
    fill: Pen = 0xFF66_88BB,
    ground: Pen = 0xFFAA_AAAA,
    track: Pen = 0xFF80_8080,
    /// What warns: a battery nearly empty.
    alarm: Pen = 0xFFD0_3030,

    pub fn of(dri: ?*const sc.DrawInfo) Pens {
        const info = dri orelse return .{};
        const p = info.pens;
        return .{
            .text = p[sc.TEXTPEN],
            .shine = p[sc.SHINEPEN],
            .shadow = p[sc.SHADOWPEN],
            .fill = p[sc.FILLPEN],
            .ground = p[sc.BACKGROUNDPEN],
            .track = support.mixPens(p[sc.TEXTPEN], p[sc.BACKGROUNDPEN], 5),
        };
    }
};

/// The square a picture draws in, and what draws there: every shape with
/// smooth edges, in the frame's own coordinates - 0 to `size` each way -
/// so a picture draws the same at every size.
pub const Frame = struct {
    gb: *GraphicsBase,
    rp: *graphics.RastPort,
    /// The square's left and top in the RastPort, and how big it is.
    x: i32,
    y: i32,
    size: i32,
    pens: Pens,

    /// `n` of `d` parts of the size, rounded.
    pub fn part(f: *const Frame, n: i32, d: i32) i32 {
        return @divTrunc(f.size * n + @divTrunc(d, 2), d);
    }

    pub fn pen(f: *const Frame, colour: Pen) void {
        support.setPen(f.gb, f.rp, colour);
    }

    /// A box from (`x0`, `y0`) up to but not including (`x1`, `y1`).
    pub fn box(f: *const Frame, x0: i32, y0: i32, x1: i32, y1: i32, colour: Pen) void {
        if (x1 <= x0 or y1 <= y0) return;
        f.pen(colour);
        f.gb.RectFill(f.rp, &.{ .min_x = f.x + x0, .min_y = f.y + y0, .max_x = f.x + x1, .max_y = f.y + y1 });
    }

    /// The same with corners rounded by `radius`.
    pub fn roundBox(f: *const Frame, x0: i32, y0: i32, x1: i32, y1: i32, radius: i32, colour: Pen) void {
        if (x1 <= x0 or y1 <= y0) return;
        f.pen(colour);
        f.gb.FillRoundRect(f.rp, &.{ .min_x = f.x + x0, .min_y = f.y + y0, .max_x = f.x + x1, .max_y = f.y + y1 }, @intCast(@max(radius, 0)));
    }

    /// Its outline, `width` thick, growing inward.
    pub fn roundOutline(f: *const Frame, x0: i32, y0: i32, x1: i32, y1: i32, radius: i32, width: i32, colour: Pen) void {
        if (x1 <= x0 or y1 <= y0) return;
        f.pen(colour);
        f.gb.SetRPAttrs(f.rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_LineWidth, .data = @intCast(@max(width, 1)) }, .{} });
        defer f.gb.SetRPAttrs(f.rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_LineWidth, .data = 1 }, .{} });
        f.gb.DrawRoundRect(f.rp, &.{ .min_x = f.x + x0, .min_y = f.y + y0, .max_x = f.x + x1, .max_y = f.y + y1 }, @intCast(@max(radius, 0)));
    }

    /// A wedge of a circle round (`cx`, `cy`) from `from` to `to`
    /// degrees - 0 to the right, anticlockwise up - out to `radius` and
    /// in to `inner`: a disc, a pie, a ring or a part of one.
    pub fn arc(f: *const Frame, cx: i32, cy: i32, radius: i32, inner: i32, from: i32, to: i32, colour: Pen) void {
        if (radius <= 0) return;
        f.pen(colour);
        f.gb.FillArc(f.rp, &.{ .cx = f.x + cx, .cy = f.y + cy, .radius = radius, .inner = @max(inner, 0), .from = from, .to = to });
    }

    pub fn disc(f: *const Frame, cx: i32, cy: i32, radius: i32, colour: Pen) void {
        f.arc(cx, cy, radius, 0, 0, 360, colour);
    }

    /// A shape of straight edges through `points`, filled.
    pub fn polygon(f: *const Frame, points: []const [2]i32, colour: Pen) void {
        if (points.len < 3) return;
        if (!f.gb.InitArea(f.rp, @intCast(points.len + 1))) return;
        defer _ = f.gb.InitArea(f.rp, 0);
        f.pen(colour);
        _ = f.gb.AreaMove(f.rp, f.x + points[0][0], f.y + points[0][1]);
        for (points[1..]) |p| _ = f.gb.AreaDraw(f.rp, f.x + p[0], f.y + p[1]);
        _ = f.gb.AreaEnd(f.rp);
    }

    /// A line one pixel wide.
    pub fn line(f: *const Frame, x0: i32, y0: i32, x1: i32, y1: i32, colour: Pen) void {
        f.pen(colour);
        f.gb.Move(f.rp, f.x + x0, f.y + y0);
        f.gb.Draw(f.rp, f.x + x1, f.y + y1);
    }
};

// --- the palette ----------------------------------------------------------------------

/// The hues a picture is painted in.
pub const Hue = enum {
    /// A floppy disk, a lens, arrows, lines on paper.
    blue,
    /// A folder.
    yellow,
    /// New, paste, a sum, a lamp that is on.
    green,
    /// Delete, the handles of scissors, an underline.
    red,
    /// Wrap, replace.
    orange,
    /// Sort, a formula.
    violet,
    /// Settings, the network.
    teal,
    /// A clipboard.
    brown,
    /// Blades, a clip, a printer, a cog.
    metal,
    /// Handles, slots, screws.
    iron,
    /// Sheets of paper, labels.
    paper,
};

/// A hue in its three tones: light, the hue itself, dark.
pub const Tones = struct { light: Pen, base: Pen, dark: Pen };

pub fn tones(hue: Hue) Tones {
    return switch (hue) {
        .blue => .{ .light = 0xFFA6D0FF, .base = 0xFF3D8BEB, .dark = 0xFF1D58AC },
        .yellow => .{ .light = 0xFFFFE69A, .base = 0xFFF5BF3A, .dark = 0xFFB07F0C },
        .green => .{ .light = 0xFFA8E9A4, .base = 0xFF3DB85A, .dark = 0xFF1D7A34 },
        .red => .{ .light = 0xFFFFA59A, .base = 0xFFE5483B, .dark = 0xFFA3271F },
        .orange => .{ .light = 0xFFFFCA92, .base = 0xFFF28C28, .dark = 0xFFAE560C },
        .violet => .{ .light = 0xFFD4BBFF, .base = 0xFF8B5CF6, .dark = 0xFF5631B0 },
        .teal => .{ .light = 0xFF96EAE2, .base = 0xFF1FB0A6, .dark = 0xFF11756F },
        .brown => .{ .light = 0xFFE9C397, .base = 0xFFB9804A, .dark = 0xFF774A22 },
        .metal => .{ .light = 0xFFF4F6F9, .base = 0xFFB9C0CA, .dark = 0xFF666E7B },
        .iron => .{ .light = 0xFF9AA3B0, .base = 0xFF5A6371, .dark = 0xFF30353D },
        .paper => .{ .light = 0xFFFFFFFF, .base = 0xFFEEF1F5, .dark = 0xFF8F99A6 },
    };
}

pub const white: Pen = 0xFFFF_FFFF;

/// `c` with its alpha `alpha`.
pub fn withAlpha(c: Pen, alpha: u8) Pen {
    return (c & 0x00FF_FFFF) | @as(Pen, alpha) << 24;
}

/// `c`'s brightness as a grey, its alpha kept.
pub fn grey(c: Pen) Pen {
    const r = (c >> 16) & 0xFF;
    const g = (c >> 8) & 0xFF;
    const b = c & 0xFF;
    const y = (30 * r + 59 * g + 11 * b + 50) / 100;
    return (c & 0xFF00_0000) | y << 16 | y << 8 | y;
}

/// `c`'s colour `amount` of 256 of the way to `to`'s, rounded, its alpha
/// kept.
pub fn toward(c: Pen, to: Pen, amount: u32) Pen {
    var out: Pen = c & 0xFF00_0000;
    var shift: u5 = 0;
    while (shift < 24) : (shift += 8) {
        const a = (c >> shift) & 0xFF;
        const b = (to >> shift) & 0xFF;
        out |= ((a * (256 - amount) + b * amount + 128) >> 8) << shift;
    }
    return out;
}

/// `c` darkened to `k` of 256, its alpha kept.
pub fn darker(c: Pen, k: u32) Pen {
    return toward(c, c & 0xFF00_0000, 256 - k);
}

// --- shapes -----------------------------------------------------------------------------

/// The most corners a shape of straight edges may have.
pub const max_corners = 16;

/// A shape in pixels, in its square's coordinates, where a whole number
/// is a corner between pixels: a box from 2 to 6 covers four columns, and
/// a circle round 4 of radius 2 the same four. So a bar and a bow that
/// end on the same number meet without a seam, at every size.
pub const Shape = union(enum) {
    /// A box from (`x0`, `y0`) up to (`x1`, `y1`), its corners rounded.
    box: struct { x0: f32, y0: f32, x1: f32, y1: f32, radius: f32 },
    /// A disc, a pie, a ring or a part of one: round (`cx`, `cy`), out
    /// to `radius` and in to `inner`, from `from` to `to` degrees - 0 to
    /// the right, anticlockwise up.
    arc: struct { cx: f32, cy: f32, radius: f32, inner: f32, from: f32, to: f32 },
    /// Straight edges through its corners, even-odd.
    poly: struct { corners: [max_corners][2]f32, count: u8 },

    /// The shape set in by `d` pixels all round: a ring's band narrower
    /// and a part of one shorter at its ends, a straight edge moved in
    /// along its normal and the corners where the moved edges meet.
    pub fn inset(s: Shape, d: f32) Shape {
        var out = s;
        switch (out) {
            .box => |*b| {
                b.x0 += d;
                b.y0 += d;
                b.x1 -= d;
                b.y1 -= d;
                b.radius = @max(0, b.radius - d);
            },
            .arc => |*a| {
                a.radius -= d;
                if (a.inner > 0) a.inner += d;
                if (a.to - a.from < 360) {
                    // The ends come in by `d` along the middle of the band.
                    const middle = @max(1, (s.arc.radius + s.arc.inner) / 2);
                    const degrees = d / middle * (180.0 / pi);
                    a.from += degrees;
                    a.to -= degrees;
                }
            },
            .poly => |*p| insetCorners(p.corners[0..p.count], d),
        }
        return out;
    }

    /// The box round it: left, top, right, bottom.
    pub fn bounds(s: Shape) [4]f32 {
        return switch (s) {
            .box => |b| .{ b.x0, b.y0, b.x1, b.y1 },
            .arc => |a| .{ a.cx - a.radius, a.cy - a.radius, a.cx + a.radius, a.cy + a.radius },
            .poly => |p| blk: {
                var out = [4]f32{ p.corners[0][0], p.corners[0][1], p.corners[0][0], p.corners[0][1] };
                for (p.corners[1..p.count]) |c| {
                    out[0] = @min(out[0], c[0]);
                    out[1] = @min(out[1], c[1]);
                    out[2] = @max(out[2], c[0]);
                    out[3] = @max(out[3], c[1]);
                }
                break :blk out;
            },
        };
    }
};

const pi: f32 = 3.14159265;

/// Each corner moved in by `d` along the two edges' normals, so far that
/// the edges stay `d` from where they were; a very sharp corner is held
/// to four times that.
fn insetCorners(corners: [][2]f32, d: f32) void {
    const n = corners.len;
    if (n < 3) return;
    var area: f32 = 0;
    for (0..n) |i| {
        const a = corners[i];
        const b = corners[(i + 1) % n];
        area += a[0] * b[1] - b[0] * a[1];
    }
    const sign: f32 = if (area > 0) 1 else -1;
    var was: [max_corners][2]f32 = undefined;
    @memcpy(was[0..n], corners);
    for (0..n) |i| {
        const before = normal(was[(i + n - 1) % n], was[i], sign);
        const after = normal(was[i], was[(i + 1) % n], sign);
        const k = @max(0.25, 1 + before[0] * after[0] + before[1] * after[1]);
        corners[i][0] = was[i][0] + d * (before[0] + after[0]) / k;
        corners[i][1] = was[i][1] + d * (before[1] + after[1]) / k;
    }
}

/// The inward normal of the edge from `a` to `b`, one long.
fn normal(a: [2]f32, b: [2]f32, sign: f32) [2]f32 {
    const ex = b[0] - a[0];
    const ey = b[1] - a[1];
    const length = @sqrt(ex * ex + ey * ey);
    if (length == 0) return .{ 0, 0 };
    return .{ -sign * ey / length, sign * ex / length };
}

/// An arc's sweep worked out once, to be asked of many points: all the
/// way round, more than half of it, and the directions of its ends, with y
/// upward. Every other shape needs nothing worked out.
const Turn = struct {
    whole: bool = true,
    wide: bool = false,
    start: [2]f32 = .{ 0, 0 },
    end: [2]f32 = .{ 0, 0 },

    fn of(s: *const Shape) Turn {
        var t = Turn{};
        if (s.* == .arc) {
            const sweep = s.arc.to - s.arc.from;
            if (sweep < 360) {
                const from = s.arc.from * (pi / 180.0);
                const to = s.arc.to * (pi / 180.0);
                t.whole = false;
                t.wide = sweep > 180;
                t.start = .{ @cos(from), @sin(from) };
                t.end = .{ @cos(to), @sin(to) };
            }
        }
        return t;
    }
};

/// Whether the point (`x`, `y`) is inside `s`, whose arc's sweep is `t`.
fn contains(s: *const Shape, t: *const Turn, x: f32, y: f32) bool {
    switch (s.*) {
        .box => |*b| {
            if (x < b.x0 or x >= b.x1 or y < b.y0 or y >= b.y1) return false;
            const radius = @min(b.radius, @min(b.x1 - b.x0, b.y1 - b.y0) / 2);
            if (radius <= 0) return true;
            // Nearer a corner than its radius, inside its quarter circle.
            const dx = x - @min(@max(x, b.x0 + radius), b.x1 - radius);
            const dy = y - @min(@max(y, b.y0 + radius), b.y1 - radius);
            return dx * dx + dy * dy <= radius * radius;
        },
        .arc => |*a| {
            if (a.to <= a.from) return false;
            const dx = x - a.cx;
            const dy = a.cy - y;
            const d2 = dx * dx + dy * dy;
            if (d2 > a.radius * a.radius or d2 < a.inner * a.inner) return false;
            if (t.whole) return true;
            const after_start = t.start[0] * dy - t.start[1] * dx;
            const before_end = dx * t.end[1] - dy * t.end[0];
            if (!t.wide) return after_start >= 0 and before_end >= 0;
            // More than half way round: outside only what lies between
            // the end and the start, the short way.
            return !(after_start < 0 and before_end < 0);
        },
        .poly => |*p| {
            if (p.count < 3) return false;
            var inside = false;
            var j: usize = p.count - 1;
            for (p.corners[0..p.count], 0..) |a, i| {
                const b = p.corners[j];
                if ((a[1] > y) != (b[1] > y)) {
                    const cross = a[0] + (y - a[1]) * (b[0] - a[0]) / (b[1] - a[1]);
                    if (x < cross) inside = !inside;
                }
                j = i;
            }
            return inside;
        },
    }
}

/// What a shape is filled with: a colour, or a gradient laid in the
/// shape's own box, as `graphics.FillStyle` lays one. Either may be
/// translucent.
pub const Paint = union(enum) {
    colour: Pen,
    fill: graphics.FillStyle,

    /// The colour at (`x`, `y`) of a shape whose box is `box`.
    fn at(paint: *const Paint, box: [4]f32, x: f32, y: f32) Pen {
        const f = switch (paint.*) {
            .colour => |c| return c,
            .fill => |*f| f,
        };
        const one: f32 = @floatFromInt(graphics.FILL_ONE);
        const w = box[2] - box[0];
        const h = box[3] - box[1];
        const fx = box[0] + @as(f32, @floatFromInt(f.from_x)) / one * w;
        const fy = box[1] + @as(f32, @floatFromInt(f.from_y)) / one * h;
        const vx = box[0] + @as(f32, @floatFromInt(f.to_x)) / one * w - fx;
        const vy = box[1] + @as(f32, @floatFromInt(f.to_y)) / one * h - fy;
        const length2 = vx * vx + vy * vy;
        const t: f32 = if (length2 == 0)
            1
        else if (f.kind == graphics.FILL_RADIAL)
            @sqrt(((x - fx) * (x - fx) + (y - fy) * (y - fy)) / length2)
        else
            ((x - fx) * vx + (y - fy) * vy) / length2;
        return stopAt(f, t * one);
    }
};

/// A gradient's colour at `at`, its stops mixed in proportion, alpha too.
fn stopAt(f: *const graphics.FillStyle, at: f32) Pen {
    const stops = f.stops[0..@max(1, @min(f.count, f.stops.len))];
    if (at <= @as(f32, @floatFromInt(stops[0].at))) return stops[0].pen;
    for (stops[1..], 1..) |stop, i| {
        const here: f32 = @floatFromInt(stop.at);
        if (at > here) continue;
        const before = stops[i - 1];
        const there: f32 = @floatFromInt(before.at);
        const t = if (here > there) (at - there) / (here - there) else 1;
        return mixed(before.pen, stop.pen, t);
    }
    return stops[stops.len - 1].pen;
}

/// `a` `t` of the way to `b`, every channel and the alpha.
fn mixed(a: Pen, b: Pen, t: f32) Pen {
    var out: Pen = 0;
    var shift: u5 = 0;
    while (true) : (shift += 8) {
        const from: f32 = @floatFromInt((a >> shift) & 0xFF);
        const to: f32 = @floatFromInt((b >> shift) & 0xFF);
        out |= @as(Pen, @intFromFloat(@round(from + (to - from) * t))) << shift;
        if (shift == 24) break;
    }
    return out;
}

/// A paint from the top of a shape to its bottom, `top` to `bottom`.
pub fn downward(top: Pen, bottom: Pen) Paint {
    return .{ .fill = .{
        .kind = graphics.FILL_LINEAR,
        .from_y = 0,
        .to_y = graphics.FILL_ONE,
        .count = 2,
        .stops = .{ .{ .at = 0, .pen = top }, .{ .at = graphics.FILL_ONE, .pen = bottom }, .{}, .{} },
    } };
}

/// The gloss over the top half of a shape: white at 55 %, fading out by
/// the middle.
pub const gloss = Paint{ .fill = .{
    .kind = graphics.FILL_LINEAR,
    .from_y = 0,
    .to_y = graphics.FILL_ONE,
    .count = 3,
    .stops = .{
        .{ .at = 0, .pen = 0x8CFF_FFFF },
        .{ .at = graphics.FILL_ONE / 2, .pen = 0x00FF_FFFF },
        .{ .at = graphics.FILL_ONE, .pen = 0x00FF_FFFF },
        .{},
    },
} };

/// How `Painter.solid` paints its shapes.
pub const Solid = struct {
    /// The back of something, a folder's: the hue going darker downward,
    /// and a darker rim.
    shade: bool = false,
    /// One colour inside the rim, no gradient and no gloss.
    flat: bool = false,
    no_shadow: bool = false,
    no_gloss: bool = false,
};

/// How a picture is drawn: its ink and its ground, and whether it is
/// disabled.
pub const Look = struct {
    /// What stands on the ground: the screen's text pen.
    ink: Pen = 0xFF00_0000,
    /// The ground under the picture: the screen's background pen.
    ground: Pen = 0xFFAA_AAAA,
    disabled: bool = false,

    pub fn of(dri: ?*const sc.DrawInfo, disabled: bool) Look {
        const info = dri orelse return .{ .disabled = disabled };
        return .{ .ink = info.pens[sc.TEXTPEN], .ground = info.pens[sc.BACKGROUNDPEN], .disabled = disabled };
    }
};

/// The shadow under a picture: black at 22 %.
const shadow_colour: Pen = 0x3800_0000;

/// Paints a picture in a frame, in layers and in colour, in design units:
/// 0 to 100 across and down the frame's square, rounded to whole pixels
/// as they are made.
///
/// It works every pixel out itself, at sixteen points in it, and lays the
/// colour down by how many are inside (`BlendPixelArray`), so its shapes
/// meet exactly where their numbers say - which graphics' own fills, a
/// circle round the middle of a pixel and a polygon reaching the column of
/// its right edge, would not quite do. The pixels are worked out in a
/// buffer the size of the square, made at the first shape and given back
/// by `end`; without the memory for it nothing is drawn.
///
/// With `into` the layers are laid into that picture instead, one over
/// another (`over`), and nothing reaches the frame's RastPort: the caller
/// puts the picture down in one `BlendPixelArray`, which comes to what the
/// layers laid one by one would, and may keep it to put down again - a
/// picture is worked out once, not at every drawing.
pub const Painter = struct {
    frame: Frame,
    look: Look,
    /// Shadows, shading and gloss, from 20 pixels up.
    detail: bool,
    /// How thick a rim is.
    rim: i32,
    /// Drawn the other way round, left for right: the redo arrow is the
    /// undo arrow mirrored.
    mirror: bool = false,
    buffer: ?*rtg.Surface = null,
    /// A `bgra32` picture of the square, cleared by the caller, that the
    /// layers are laid into rather than on the RastPort; null for none.
    into: ?*rtg.Surface = null,

    pub fn begin(frame: Frame, look: Look) Painter {
        return .{ .frame = frame, .look = look, .detail = frame.size >= 20, .rim = @max(1, @divTrunc(frame.size, 32)) };
    }

    /// The buffer given back.
    pub fn end(p: *Painter) void {
        p.frame.gb.FreeBitMap(p.buffer);
        p.buffer = null;
    }

    /// Design units in pixels.
    pub fn u(p: *const Painter, v: f32) i32 {
        return @intFromFloat(@round(v * @as(f32, @floatFromInt(p.frame.size)) / 100));
    }

    fn at(p: *const Painter, v: f32) f32 {
        return @floatFromInt(p.u(v));
    }

    fn across(p: *const Painter, v: f32) f32 {
        return if (p.mirror) 100 - v else v;
    }

    /// A box, its corners rounded by `r`.
    pub fn rr(p: *const Painter, x0: f32, y0: f32, x1: f32, y1: f32, r: f32) Shape {
        const left = if (p.mirror) 100 - x1 else x0;
        const right = if (p.mirror) 100 - x0 else x1;
        return .{ .box = .{ .x0 = p.at(left), .y0 = p.at(y0), .x1 = p.at(right), .y1 = p.at(y1), .radius = p.at(r) } };
    }

    /// A ring round (`cx`, `cy`) out to `r` and in to `inner`, from `from`
    /// to `to` degrees.
    pub fn ring(p: *const Painter, cx: f32, cy: f32, r: f32, inner: f32, from: f32, to: f32) Shape {
        return .{ .arc = .{
            .cx = p.at(p.across(cx)),
            .cy = p.at(cy),
            .radius = p.at(r),
            .inner = if (inner > 0) p.at(inner) else 0,
            .from = if (p.mirror) 180 - to else from,
            .to = if (p.mirror) 180 - from else to,
        } };
    }

    pub fn disc(p: *const Painter, cx: f32, cy: f32, r: f32) Shape {
        return p.ring(cx, cy, r, 0, 0, 360);
    }

    /// Straight edges through `corners`, at most `max_corners` of them.
    pub fn poly(p: *const Painter, corners: []const [2]f32) Shape {
        var shape = Shape{ .poly = .{ .corners = undefined, .count = @intCast(@min(corners.len, max_corners)) } };
        for (corners[0..shape.poly.count], 0..) |c, i| {
            shape.poly.corners[i] = .{ p.at(p.across(c[0])), p.at(c[1]) };
        }
        return shape;
    }

    /// A colour as it is put down: its grey faded into the ground when
    /// the picture is disabled.
    fn colour(p: *const Painter, c: Pen) Pen {
        if (!p.look.disabled) return c;
        return toward(grey(c), p.look.ground | 0xFF00_0000, 140);
    }

    /// A shape put down in `paint`.
    pub fn fill(p: *Painter, s: Shape, paint: Paint) void {
        p.lay(&.{s}, paint, 0, 0);
    }

    /// Shapes in the ink: what stands on the ground.
    pub fn ink(p: *Painter, list: []const Shape) void {
        p.lay(list, .{ .colour = p.look.ink }, 0, 0);
    }

    /// A line of text on paper, or a stroke: a bar from `x0` to `x1` at
    /// `y`, `thick` high and never less than a pixel.
    pub fn stroke(p: *Painter, x0: f32, x1: f32, y: f32, thick: f32, c: Pen) void {
        var s = p.rr(x0, y, x1, y + thick, 0);
        if (s.box.y1 <= s.box.y0) s.box.y1 = s.box.y0 + 1;
        p.fill(s, .{ .colour = c });
    }

    /// Shapes in one hue, in layers: the shadow under them all, then their
    /// rim, then each set in by the rim and shaded, then the gloss.
    pub fn solid(p: *Painter, list: []const Shape, hue: Hue, how: Solid) void {
        const t = tones(hue);
        const rim_colour = if (how.shade) darker(t.dark, 200) else t.dark;
        const body: Paint = if (how.flat or !p.detail)
            .{ .colour = if (how.shade) toward(t.base, t.dark, 128) else t.base }
        else if (how.shade)
            downward(t.base, t.dark)
        else
            downward(t.light, t.base);
        const rim: f32 = @floatFromInt(p.rim);
        if (p.detail and !how.no_shadow and !p.look.disabled) {
            const n = p.frame.size;
            const dx = @divTrunc(n + 24, 48);
            const dy = @max(1, @divTrunc(n + 12, 24));
            p.lay(list, .{ .colour = shadow_colour }, dx, dy);
        }
        p.lay(list, .{ .colour = rim_colour }, 0, 0);
        for (list) |*s| p.lay(&.{s.inset(rim)}, body, 0, 0);
        if (p.detail and !how.no_gloss and !how.flat and !p.look.disabled) {
            for (list) |*s| p.lay(&.{s.inset(rim)}, gloss, 0, 0);
        }
    }

    /// The most shapes laid down together.
    pub const max_shapes = 16;

    /// `list` laid down in `paint` as one, moved by (`dx`, `dy`) pixels: a
    /// pixel is covered by the share of its sixteen points inside any of
    /// the shapes, so where two meet nothing is laid twice, and a gradient
    /// runs over the box round all of them.
    ///
    /// The shapes are read where they are, not copied: the painter draws
    /// in a gadget's GM_RENDER, deep in intuition's input task.
    fn lay(p: *Painter, list: []const Shape, paint: Paint, dx: i32, dy: i32) void {
        if (list.len == 0) return;
        const buffer = p.into orelse p.bufferOf() orelse return;
        const n = p.frame.size;
        const shift_x: f32 = @floatFromInt(dx);
        const shift_y: f32 = @floatFromInt(dy);
        var turns: [max_shapes]Turn = undefined;
        const count = @min(list.len, max_shapes);
        var box = list[0].bounds();
        for (list[0..count], turns[0..count]) |*s, *t| {
            t.* = Turn.of(s);
            const b = s.bounds();
            box = .{ @min(box[0], b[0]), @min(box[1], b[1]), @max(box[2], b[2]), @max(box[3], b[3]) };
        }
        box = .{ box[0] + shift_x, box[1] + shift_y, box[2] + shift_x, box[3] + shift_y };
        // The pixels the box touches, within the square.
        const left: i32 = @max(0, @as(i32, @intFromFloat(@floor(box[0]))));
        const top: i32 = @max(0, @as(i32, @intFromFloat(@floor(box[1]))));
        const right: i32 = @min(n, @as(i32, @intFromFloat(@ceil(box[2]))));
        const bottom: i32 = @min(n, @as(i32, @intFromFloat(@ceil(box[3]))));
        if (right <= left or bottom <= top) return;

        const pitch = buffer.pitch / 4;
        const pixels: [*]Pen = @ptrCast(@alignCast(buffer.pixels.?));
        var y = top;
        while (y < bottom) : (y += 1) {
            var x = left;
            while (x < right) : (x += 1) {
                var inside: u32 = 0;
                for (0..4) |j| for (0..4) |i| {
                    const sx = @as(f32, @floatFromInt(x - dx)) + @as(f32, @floatFromInt(2 * i + 1)) / 8;
                    const sy = @as(f32, @floatFromInt(y - dy)) + @as(f32, @floatFromInt(2 * j + 1)) / 8;
                    for (list[0..count], turns[0..count]) |*s, *t| if (contains(s, t, sx, sy)) {
                        inside += 1;
                        break;
                    };
                };
                const at_pixel = &pixels[@as(usize, @intCast(y)) * pitch + @as(usize, @intCast(x))];
                if (inside == 0) {
                    if (p.into == null) at_pixel.* = 0;
                    continue;
                }
                const c = p.colour(paint.at(box, @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5));
                const alpha = ((c >> 24) * inside + 8) / 16;
                const laid = (c & 0x00FF_FFFF) | alpha << 24;
                at_pixel.* = if (p.into != null) over(at_pixel.*, laid) else laid;
            }
        }
        if (p.into != null) return;
        p.frame.gb.BlendPixelArray(p.frame.rp, buffer.pixels.?, buffer.pitch, @intFromEnum(rtg.PixelFormat.bgra32), left, top, &.{
            .min_x = p.frame.x + left,
            .min_y = p.frame.y + top,
            .max_x = p.frame.x + right,
            .max_y = p.frame.y + bottom,
        });
    }

    /// The buffer the pixels are worked out in, a word each as a `Pen` is
    /// - `bgra32` - made the first time it is wanted.
    fn bufferOf(p: *Painter) ?*rtg.Surface {
        if (p.buffer) |b| return b;
        const n: usize = @intCast(p.frame.size);
        p.buffer = p.frame.gb.AllocBitMapTagList(&[_]TagItem{
            .{ .tag = graphics.BMTAG_Width, .data = n },
            .{ .tag = graphics.BMTAG_Height, .data = n },
            .{ .tag = graphics.BMTAG_Format, .data = @intFromEnum(rtg.PixelFormat.bgra32) },
            .{},
        });
        return p.buffer;
    }
};

/// `top` laid over `under`, both colours with their own opacity in the
/// top byte, as one colour: what `BlendPixelArray` makes of the two put
/// down one after the other is what it makes of this put down alone.
pub fn over(under: Pen, top: Pen) Pen {
    const ta = top >> 24;
    const ua = under >> 24;
    if (ta == 0) return under;
    if (ta == 255 or ua == 0) return top;
    // In 255ths of 255ths: the top's share of the colour, and what of the
    // one under it shows through.
    const through = ua * (255 - ta);
    const whole = ta * 255 + through;
    var out: Pen = ((whole + 127) / 255) << 24;
    var shift: u5 = 0;
    while (shift <= 16) : (shift += 8) {
        const tc = (top >> shift) & 0xFF;
        const uc = (under >> shift) & 0xFF;
        out |= ((tc * ta * 255 + uc * through + whole / 2) / whole) << shift;
    }
    return out;
}

/// The four corners of a bar `w` wide from (`x0`, `y0`) to (`x1`, `y1`),
/// in design units.
pub fn bar(x0: f32, y0: f32, x1: f32, y1: f32, w: f32) [4][2]f32 {
    return taper(x0, y0, x1, y1, w, w);
}

/// The same, `w0` wide at its start and `w1` at its end: a blade.
pub fn taper(x0: f32, y0: f32, x1: f32, y1: f32, w0: f32, w1: f32) [4][2]f32 {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const length = @max(@sqrt(dx * dx + dy * dy), 1);
    const ux = -dy / length;
    const uy = dx / length;
    return .{
        .{ x0 + ux * w0 / 2, y0 + uy * w0 / 2 },
        .{ x1 + ux * w1 / 2, y1 + uy * w1 / 2 },
        .{ x1 - ux * w1 / 2, y1 - uy * w1 / 2 },
        .{ x0 - ux * w0 / 2, y0 - uy * w0 / 2 },
    };
}
