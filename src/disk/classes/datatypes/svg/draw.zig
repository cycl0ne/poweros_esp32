// SPDX-License-Identifier: MIT
//! An SVG document drawn through vector.library.
//!
//! The tree is walked in the order of the file, each element's style
//! worked out from its parent's: the presentation attributes first, then
//! the `style` attribute's declarations over them, the inherited
//! properties carried down and the others - `opacity`, `display`,
//! `filter` - not. A shape is built into the one path, filled and then
//! stroked through its matrix: the parents' transforms, the `viewBox`'s
//! and the size the picture is drawn at, so a stroke is made in the
//! shape's own units and comes out stretched where they are.
//!
//! **Opacity**: a group's, and a shape's that is both filled and stroked,
//! goes onto a layer of its own put down at it; a shape painted only one
//! way has it in its paint, which comes to the same.
//!
//! **Gradients** are found by id, and an `href` chain followed for what
//! a gradient leaves out - its stops, its units, its transform, its
//! coordinates - as far as `max_hops`. Their units are the shape's box
//! (`objectBoundingBox`, the default) or the user's. A radial one's focus
//! outside its circle is moved onto it, as SVG 1.1 has it.
//!
//! **Not drawn**, nor anything in it: `defs` and what is in no `defs`
//! but is not drawn either - gradients, `symbol`, `clipPath`, `mask`,
//! `pattern`, `marker`, `style` - `use`, `image` and `text`, an element
//! of another namespace, and one with a `filter`, which this reader does
//! not have. `clip-path` and `mask` are passed over: what they would cut
//! is drawn whole. In a `switch` the first element that can be drawn is.
//!
//! Elements nested deeper than `max_depth` are not drawn.
//!
//! `vb` is anything with vector.library's calls by their names: the
//! library itself on the machine, its module straight on the host.

const std = @import("std");
const sdk = @import("sdk");
const vector = sdk.vector;
pub const document = @import("document.zig");
const values = @import("values.zig");
const Document = document.Document;
const Name = document.Name;
const Tag = document.Tag;
const none = document.none;
const Matrix = vector.Matrix;
const Colour = vector.Colour;
const Length = values.Length;

pub const max_depth = 48;
pub const max_stops = 64;
pub const max_dashes = 32;
pub const max_hops = 16;
/// Points of a `polyline` or a `polygon` handed over at a time.
const chunk = 128;

/// What drawing needs besides the document, in one block of the
/// caller's: it is too much for a stack.
pub const Work = struct {
    frames: [max_depth]Frame = undefined,
    stops: [max_stops]vector.Stop = undefined,
    dashes: [max_dashes]f32 = undefined,
    points: [chunk]vector.Point = undefined,
    verbs: [chunk]u8 = undefined,
};

/// A group being drawn: its element, its style, its matrix.
const Frame = struct {
    node: u32,
    style: Style,
    matrix: Matrix,
    /// The width and height percentages are of.
    viewport: [2]f32,
    /// A layer pushed for its opacity, to be put down when it ends.
    layered: bool = false,
    /// A `switch`, and whether it has drawn its one.
    choosing: bool = false,
    chosen: bool = false,
};

const Style = struct {
    // Inherited.
    fill: values.Paint = .{ .colour = .{} },
    fill_opacity: f32 = 1,
    fill_rule: u32 = vector.RULE_NONZERO,
    stroke: values.Paint = .none,
    stroke_opacity: f32 = 1,
    stroke_width: Length = .{ .value = 1 },
    cap: u32 = vector.CAP_BUTT,
    join: u32 = vector.JOIN_MITER,
    miter_limit: f32 = 4,
    /// The dash lengths' text, empty for none.
    dashes: []const u8 = "",
    dash_offset: Length = .{ .value = 0 },
    colour: Colour = .{},
    visible: bool = true,
    // Not inherited.
    opacity: f32 = 1,
    shown: bool = true,
    filtered: bool = false,

    /// What a child starts from.
    fn inherited(parent: *const Style) Style {
        var s = parent.*;
        s.opacity = 1;
        s.shown = true;
        s.filtered = false;
        return s;
    }
};

/// The size an SVG file gives its picture, in pixels, and what takes its
/// units into them.
pub const Intrinsic = struct {
    width: f32,
    height: f32,
    /// The `viewBox` into the picture's width and height.
    view: Matrix,
    /// What the outermost element's percentages are of.
    viewport: [2]f32,
};

/// The root's `width` and `height`; what one leaves out comes from the
/// `viewBox`'s shape, and without one from CSS's 300 by 150.
pub fn intrinsic(doc: *const Document) Intrinsic {
    const box = viewBox(doc.get(0, .viewBox));
    var width = absolute(doc.get(0, .width));
    var height = absolute(doc.get(0, .height));
    if (box) |b| {
        if (width == null and height == null) {
            width = b.width;
            height = b.height;
        } else if (width == null) {
            width = height.? * b.width / b.height;
        } else if (height == null) {
            height = width.? * b.height / b.width;
        }
    }
    const w = width orelse 300;
    const h = height orelse 150;
    return .{
        .width = w,
        .height = h,
        .view = if (box) |b| viewBoxMatrix(b, doc.get(0, .preserveAspectRatio) orelse "", w, h) else .{},
        .viewport = if (box) |b| .{ b.width, b.height } else .{ w, h },
    };
}

fn absolute(text: ?[]const u8) ?f32 {
    const l = values.length(text orelse return null) orelse return null;
    if (l.percent or !(l.value > 0)) return null;
    return l.value;
}

/// A `viewBox`: four numbers, its width and height more than 0.
fn viewBox(text: ?[]const u8) ?vector.Rect {
    var s = values.Scanner{ .text = text orelse return null };
    var v: [4]f32 = undefined;
    for (&v, 0..) |*n, i| {
        if (i > 0) s.skipSeparator();
        n.* = s.number() orelse return null;
    }
    if (!s.done() or !(v[2] > 0) or !(v[3] > 0)) return null;
    return .{ .x = v[0], .y = v[1], .width = v[2], .height = v[3] };
}

/// The `viewBox` fitted into `width` by `height` as `preserveAspectRatio`
/// says: stretched, or scaled the same both ways to fit inside (`meet`,
/// the default) or to cover (`slice`), and moved to one side, the middle
/// or the other.
fn viewBoxMatrix(box: vector.Rect, aspect: []const u8, width: f32, height: f32) Matrix {
    var s = values.Scanner{ .text = aspect };
    var align_word = s.word();
    if (values.eqlLower(align_word, "defer")) align_word = s.word();
    const slice = values.eqlLower(s.word(), "slice");
    var sx = width / box.width;
    var sy = height / box.height;
    if (align_word.len != 0 and values.eqlLower(align_word, "none")) {
        return Matrix.scale(sx, sy).then(Matrix.translate(-box.x, -box.y));
    }
    const scale = if (slice) @max(sx, sy) else @min(sx, sy);
    sx = scale;
    sy = scale;
    // xMinYMin ... xMaxYMax; anything else is xMidYMid.
    var ax: f32 = 0.5;
    var ay: f32 = 0.5;
    if (align_word.len == 8) {
        ax = position(align_word[1..4]) orelse 0.5;
        ay = position(align_word[5..8]) orelse 0.5;
    }
    const tx = (width - box.width * sx) * ax;
    const ty = (height - box.height * sy) * ay;
    return Matrix.translate(tx, ty).then(Matrix.scale(sx, sy)).then(Matrix.translate(-box.x, -box.y));
}

fn position(word: []const u8) ?f32 {
    if (std.mem.eql(u8, word, "Min")) return 0;
    if (std.mem.eql(u8, word, "Mid")) return 0.5;
    if (std.mem.eql(u8, word, "Max")) return 1;
    return null;
}

/// The largest a picture is drawn, either way, in pixels.
pub const max_side = 16384;

/// The size the file gives, in whole pixels, made smaller to fit in
/// `max_side` either way.
pub fn fullSize(size: Intrinsic) [2]u32 {
    var w = size.width;
    var h = size.height;
    const side = @max(w, h);
    if (side > max_side) {
        w = w * max_side / side;
        h = h * max_side / side;
    }
    return .{ @max(1, @as(u32, @intFromFloat(@round(@min(w, max_side))))), @max(1, @as(u32, @intFromFloat(@round(@min(h, max_side))))) };
}

/// What the document is drawn through to come out `width` by `height`
/// pixels: the root's units into its size, and that stretched to them.
pub fn baseMatrix(size: Intrinsic, width: u32, height: u32) Matrix {
    const sx = @as(f32, @floatFromInt(width)) / size.width;
    const sy = @as(f32, @floatFromInt(height)) / size.height;
    return Matrix.scale(sx, sy).then(size.view);
}

/// The document drawn onto `canvas`, `path` the one every shape is built
/// in. `base` takes the root's units to pixels: the picture's size over
/// its intrinsic one, then `Intrinsic.view`.
pub fn draw(vb: anytype, doc: *const Document, canvas: *vector.Canvas, path: *vector.Path, work: *Work, base: Matrix, viewport: [2]f32) void {
    var p = Painter(@TypeOf(vb)){ .vb = vb, .doc = doc, .canvas = canvas, .path = path, .work = work };
    p.walk(base, viewport);
}

fn Painter(comptime VB: type) type {
    return struct {
        const P = @This();

        vb: VB,
        doc: *const Document,
        canvas: *vector.Canvas,
        path: *vector.Path,
        work: *Work,

        fn walk(p: *P, base: Matrix, viewport: [2]f32) void {
            const frames = &p.work.frames;
            const root_default = Style{};
            const root_style = p.styleOf(0, &root_default, viewport);
            if (!root_style.shown or root_style.filtered) return;
            frames[0] = .{ .node = 0, .style = root_style, .matrix = base, .viewport = viewport };
            frames[0].layered = p.layer(root_style.opacity);
            var depth: usize = 0;
            var child = p.doc.nodes[0].first_child;
            while (true) {
                if (child == none) {
                    const ending = &frames[depth];
                    if (ending.layered) p.vb.PopLayer(p.canvas);
                    if (depth == 0) return;
                    child = p.doc.nodes[ending.node].next;
                    depth -= 1;
                    continue;
                }
                const node = child;
                child = p.doc.nodes[node].next;
                const top = &frames[depth];
                const tag = p.doc.nodes[node].tag;
                if (top.choosing) {
                    if (top.chosen or !drawable(tag)) continue;
                    top.chosen = true;
                }
                switch (tag) {
                    .g, .a, .@"switch", .svg => {
                        if (depth + 1 == max_depth) continue;
                        const style = p.styleOf(node, &top.style, top.viewport);
                        if (!style.shown or style.filtered) continue;
                        var matrix = top.matrix.then(p.transformOf(node, .transform));
                        var inner = top.viewport;
                        if (tag == .svg) matrix = p.nested(node, matrix, &inner);
                        depth += 1;
                        frames[depth] = .{ .node = node, .style = style, .matrix = matrix, .viewport = inner, .choosing = tag == .@"switch" };
                        frames[depth].layered = p.layer(style.opacity);
                        child = p.doc.nodes[node].first_child;
                    },
                    .path, .rect, .circle, .ellipse, .line, .polyline, .polygon => p.shape(node, top),
                    else => {},
                }
            }
        }

        /// A layer for an opacity under 1; whether one was pushed. One the
        /// canvas had no room for is still pushed, its opacity going into
        /// every paint, and is put down the same.
        fn layer(p: *P, opacity: f32) bool {
            if (opacity >= 1) return false;
            _ = p.vb.PushLayer(p.canvas, opacity);
            return true;
        }

        /// A nested `svg`: its place, and its `viewBox` into its size.
        fn nested(p: *P, node: u32, matrix: Matrix, viewport: *[2]f32) Matrix {
            const outer = viewport.*;
            const x = p.lengthOf(node, .x, .x, outer, 0);
            const y = p.lengthOf(node, .y, .y, outer, 0);
            const w = p.lengthOf(node, .width, .x, outer, outer[0]);
            const h = p.lengthOf(node, .height, .y, outer, outer[1]);
            var m = matrix.then(Matrix.translate(x, y));
            if (viewBox(p.doc.get(node, .viewBox))) |box| {
                m = m.then(viewBoxMatrix(box, p.doc.get(node, .preserveAspectRatio) orelse "", w, h));
                viewport.* = .{ box.width, box.height };
            } else viewport.* = .{ w, h };
            return m;
        }

        fn shape(p: *P, node: u32, top: *const Frame) void {
            const style = p.styleOf(node, &top.style, top.viewport);
            if (!style.shown or style.filtered or !style.visible) return;
            const vb = p.vb;
            const path = p.path;
            const viewport = top.viewport;
            vb.ClearPath(path);
            switch (p.doc.nodes[node].tag) {
                .path => {
                    const d = p.doc.get(node, .d) orelse return;
                    _ = vb.AddPathData(path, d.ptr, @intCast(d.len));
                },
                .rect => {
                    const w = p.lengthOf(node, .width, .x, viewport, 0);
                    const h = p.lengthOf(node, .height, .y, viewport, 0);
                    if (!(w > 0) or !(h > 0)) return;
                    var rx = p.optionalLength(node, .rx, .x, viewport);
                    var ry = p.optionalLength(node, .ry, .y, viewport);
                    if (rx == null) rx = ry;
                    if (ry == null) ry = rx;
                    const rect = vector.Rect{ .x = p.lengthOf(node, .x, .x, viewport, 0), .y = p.lengthOf(node, .y, .y, viewport, 0), .width = w, .height = h };
                    vb.AddRect(path, &rect, rx orelse 0, ry orelse 0);
                },
                .circle => {
                    const r = p.lengthOf(node, .r, .other, viewport, 0);
                    vb.AddEllipse(path, p.lengthOf(node, .cx, .x, viewport, 0), p.lengthOf(node, .cy, .y, viewport, 0), r, r);
                },
                .ellipse => {
                    var rx = p.optionalLength(node, .rx, .x, viewport);
                    var ry = p.optionalLength(node, .ry, .y, viewport);
                    if (rx == null) rx = ry;
                    if (ry == null) ry = rx;
                    vb.AddEllipse(path, p.lengthOf(node, .cx, .x, viewport, 0), p.lengthOf(node, .cy, .y, viewport, 0), rx orelse 0, ry orelse 0);
                },
                .line => {
                    vb.MoveTo(path, p.lengthOf(node, .x1, .x, viewport, 0), p.lengthOf(node, .y1, .y, viewport, 0));
                    vb.LineTo(path, p.lengthOf(node, .x2, .x, viewport, 0), p.lengthOf(node, .y2, .y, viewport, 0));
                },
                .polyline, .polygon => {
                    if (!p.points(node)) return;
                    if (p.doc.nodes[node].tag == .polygon) vb.ClosePath(path);
                },
                else => return,
            }
            const matrix = top.matrix.then(p.transformOf(node, .transform));
            const filled = p.doc.nodes[node].tag != .line and style.fill != .none;
            const stroked = style.stroke != .none and style.stroke_width.resolve(.other, viewport) > 0;
            // Both ways at once, the opacity on a layer over them both;
            // one way, in the paint.
            const layered = filled and stroked and style.opacity < 1;
            const paint_opacity: f32 = if (layered) 1 else style.opacity;
            if (layered) _ = vb.PushLayer(p.canvas, style.opacity);
            if (filled) {
                if (p.paintOf(style.fill, style.fill_opacity * paint_opacity, &style, viewport)) |paint| {
                    _ = vb.FillPath(p.canvas, path, &matrix, &paint, style.fill_rule);
                }
            }
            if (stroked) {
                if (p.paintOf(style.stroke, style.stroke_opacity * paint_opacity, &style, viewport)) |paint| {
                    const stroke = p.strokeOf(&style, viewport);
                    _ = vb.StrokePath(p.canvas, path, &matrix, &paint, &stroke);
                }
            }
            if (layered) vb.PopLayer(p.canvas);
        }

        /// A `polyline`'s or a `polygon`'s points onto the path, a chunk
        /// at a time; false for none. A number without its pair ends it.
        fn points(p: *P, node: u32) bool {
            var s = values.Scanner{ .text = p.doc.get(node, .points) orelse return false };
            const work = p.work;
            var any = false;
            while (true) {
                var n: u32 = 0;
                while (n < chunk) : (n += 1) {
                    s.skipSeparator();
                    const x = s.number() orelse break;
                    s.skipSeparator();
                    const y = s.number() orelse break;
                    work.points[n] = .{ .x = x, .y = y };
                    work.verbs[n] = if (!any and n == 0) vector.SEG_MOVE else vector.SEG_LINE;
                }
                if (n == 0) return any;
                _ = p.vb.AddSegments(p.path, &work.verbs, n, &work.points, n);
                any = true;
                if (n < chunk) return true;
            }
        }

        fn strokeOf(p: *P, style: *const Style, viewport: [2]f32) vector.Stroke {
            var stroke = vector.Stroke{
                .width = style.stroke_width.resolve(.other, viewport),
                .join = style.join,
                .cap = style.cap,
                .miter_limit = style.miter_limit,
            };
            if (style.dashes.len == 0) return stroke;
            var s = values.Scanner{ .text = style.dashes };
            var n: u32 = 0;
            while (n < max_dashes) {
                s.skipSeparator();
                if (s.at >= s.text.len) break;
                const l = values.lengthAt(&s) orelse return stroke;
                p.work.dashes[n] = l.resolve(.other, viewport);
                n += 1;
            }
            if (n == 0) return stroke;
            stroke.dashes = &p.work.dashes;
            stroke.dash_count = n;
            stroke.dash_offset = style.dash_offset.resolve(.other, viewport);
            return stroke;
        }

        // --- paints ---------------------------------------------------------------

        /// The paint for `which`, or null for none.
        fn paintOf(p: *P, which: values.Paint, opacity: f32, style: *const Style, viewport: [2]f32) ?vector.Paint {
            return switch (which) {
                .none => null,
                .colour => |c| .{ .colour = c, .opacity = opacity },
                .current => .{ .colour = style.colour, .opacity = opacity },
                .url => |url| {
                    if (p.doc.byId(url.id)) |node| {
                        const tag = p.doc.nodes[node].tag;
                        if (tag == .linearGradient or tag == .radialGradient) return p.gradientOf(node, opacity, style, viewport);
                    }
                    return switch (url.fallback) {
                        .colour => |c| .{ .colour = c, .opacity = opacity },
                        .current => .{ .colour = style.colour, .opacity = opacity },
                        .none, .absent => null,
                    };
                },
            };
        }

        /// A gradient, what it leaves out taken from the ones its `href`
        /// names; null where it paints nothing.
        fn gradientOf(p: *P, start: u32, opacity: f32, style: *const Style, viewport: [2]f32) ?vector.Paint {
            const doc = p.doc;
            const radial = doc.nodes[start].tag == .radialGradient;
            var found: [@typeInfo(Name).@"enum".fields.len]?[]const u8 = @splat(null);
            var stops_from: u32 = none;
            var node = start;
            var hops: u32 = 0;
            while (true) {
                const tag = doc.nodes[node].tag;
                for (doc.attributesOf(node)) |a| {
                    const own = switch (a.name) {
                        .gradientUnits, .gradientTransform, .spreadMethod => true,
                        .x1, .y1, .x2, .y2 => tag == .linearGradient and !radial,
                        .cx, .cy, .r, .fx, .fy, .fr => tag == .radialGradient and radial,
                        else => false,
                    };
                    if (own and found[@intFromEnum(a.name)] == null) found[@intFromEnum(a.name)] = a.value;
                }
                if (stops_from == none and p.hasStops(node)) stops_from = node;
                hops += 1;
                if (hops > max_hops) break;
                const next = doc.byHref(doc.get(node, .href) orelse break) orelse break;
                const next_tag = doc.nodes[next].tag;
                if (next_tag != .linearGradient and next_tag != .radialGradient) break;
                node = next;
            }
            const stop_count = p.stopsOf(stops_from, style);
            if (stop_count == 0) return null;
            const get = struct {
                fn get(f: *const [@typeInfo(Name).@"enum".fields.len]?[]const u8, name: Name) ?[]const u8 {
                    return f[@intFromEnum(name)];
                }
            }.get;

            const box_units = if (get(&found, .gradientUnits)) |u| !std.mem.eql(u8, values.trim(u), "userSpaceOnUse") else true;
            var matrix = if (get(&found, .gradientTransform)) |t| values.transform(t) orelse Matrix{} else Matrix{};
            if (box_units) {
                var box: vector.Rect = undefined;
                if (!p.vb.PathBounds(p.path, null, &box) or !(box.width > 0) or !(box.height > 0)) return null;
                matrix = (Matrix{ .a = box.width, .d = box.height, .e = box.x, .f = box.y }).then(matrix);
            }
            var paint = vector.Paint{
                .kind = if (radial) vector.PAINT_RADIAL else vector.PAINT_LINEAR,
                .opacity = opacity,
                .stops = &p.work.stops,
                .stop_count = stop_count,
                .matrix = matrix,
            };
            if (get(&found, .spreadMethod)) |spread| {
                const word = values.trim(spread);
                if (std.mem.eql(u8, word, "reflect")) paint.spread = vector.SPREAD_REFLECT;
                if (std.mem.eql(u8, word, "repeat")) paint.spread = vector.SPREAD_REPEAT;
            }
            const coordinate = struct {
                fn of(text: ?[]const u8, box: bool, axis: values.Axis, vp: [2]f32, default: Length) f32 {
                    const l = (if (text) |t| values.length(t) else null) orelse default;
                    if (box) return if (l.percent) l.value / 100 else l.value;
                    return l.resolve(axis, vp);
                }
            }.of;
            if (!radial) {
                paint.x1 = coordinate(get(&found, .x1), box_units, .x, viewport, .{ .value = 0 });
                paint.y1 = coordinate(get(&found, .y1), box_units, .y, viewport, .{ .value = 0 });
                paint.x2 = coordinate(get(&found, .x2), box_units, .x, viewport, .{ .value = 100, .percent = true });
                paint.y2 = coordinate(get(&found, .y2), box_units, .y, viewport, .{ .value = 0 });
            } else {
                const half = Length{ .value = 50, .percent = true };
                paint.cx = coordinate(get(&found, .cx), box_units, .x, viewport, half);
                paint.cy = coordinate(get(&found, .cy), box_units, .y, viewport, half);
                paint.r = coordinate(get(&found, .r), box_units, .other, viewport, half);
                paint.fx = if (get(&found, .fx)) |t| coordinate(t, box_units, .x, viewport, half) else paint.cx;
                paint.fy = if (get(&found, .fy)) |t| coordinate(t, box_units, .y, viewport, half) else paint.cy;
                paint.fr = coordinate(get(&found, .fr), box_units, .other, viewport, .{ .value = 0 });
                if (!(paint.r > 0)) return lastStop(&paint);
                // The focus inside the circle, as SVG 1.1 moves it.
                const dx = paint.fx - paint.cx;
                const dy = paint.fy - paint.cy;
                const distance = @sqrt(dx * dx + dy * dy);
                const most = paint.r * 0.999;
                if (distance > most) {
                    paint.fx = paint.cx + dx * most / distance;
                    paint.fy = paint.cy + dy * most / distance;
                }
            }
            return paint;
        }

        /// A gradient of no size: its last stop's colour.
        fn lastStop(paint: *const vector.Paint) vector.Paint {
            const last = paint.stops.?[paint.stop_count - 1].colour;
            return .{ .colour = last, .opacity = paint.opacity };
        }

        fn hasStops(p: *P, node: u32) bool {
            var child = p.doc.nodes[node].first_child;
            while (child != none) : (child = p.doc.nodes[child].next) {
                if (p.doc.nodes[child].tag == .stop) return true;
            }
            return false;
        }

        /// The stops of the gradient `node` into the work's; how many.
        fn stopsOf(p: *P, node: u32, style: *const Style) u32 {
            if (node == none) return 0;
            var n: u32 = 0;
            var child = p.doc.nodes[node].first_child;
            while (child != none and n < max_stops) : (child = p.doc.nodes[child].next) {
                if (p.doc.nodes[child].tag != .stop) continue;
                var colour = Colour{};
                var stop_opacity: f32 = 1;
                var current = style.colour;
                const offset = if (p.doc.get(child, .offset)) |t| values.fraction(t) orelse 0 else 0;
                var use_current = false;
                for (p.doc.attributesOf(child)) |a| {
                    stopProperty(a.name, a.value, &colour, &stop_opacity, &current, &use_current);
                }
                if (p.doc.get(child, .style)) |text| {
                    var d = values.Declarations{ .text = text };
                    while (d.next()) |one| stopProperty(document.nameOf(one.name), one.value, &colour, &stop_opacity, &current, &use_current);
                }
                if (use_current) colour = current;
                colour.a *= stop_opacity;
                p.work.stops[n] = .{ .offset = offset, .colour = colour };
                n += 1;
            }
            return n;
        }

        fn stopProperty(name: Name, text: []const u8, colour: *Colour, opacity: *f32, current: *Colour, use_current: *bool) void {
            switch (name) {
                .@"stop-color" => {
                    if (values.eqlLower(values.trim(text), "currentcolor")) {
                        use_current.* = true;
                    } else if (values.colour(text)) |c| {
                        colour.* = c;
                        use_current.* = false;
                    }
                },
                .@"stop-opacity" => if (values.fraction(text)) |f| {
                    opacity.* = f;
                },
                .color => if (values.colour(text)) |c| {
                    current.* = c;
                },
                else => {},
            }
        }

        // --- styles ---------------------------------------------------------------

        /// An element's style: its parent's, then its presentation
        /// attributes, then its `style` attribute.
        fn styleOf(p: *P, node: u32, parent: *const Style, viewport: [2]f32) Style {
            _ = viewport;
            var s = Style.inherited(parent);
            for (p.doc.attributesOf(node)) |a| property(&s, parent, a.name, a.value);
            if (p.doc.get(node, .style)) |text| {
                var d = values.Declarations{ .text = text };
                while (d.next()) |one| property(&s, parent, document.nameOf(one.name), one.value);
            }
            return s;
        }

        fn transformOf(p: *P, node: u32, name: Name) Matrix {
            const text = p.doc.get(node, name) orelse return .{};
            return values.transform(text) orelse .{};
        }

        /// A length attribute in units, `default` when it is not there or
        /// not one.
        fn lengthOf(p: *P, node: u32, name: Name, axis: values.Axis, viewport: [2]f32, default: f32) f32 {
            return p.optionalLength(node, name, axis, viewport) orelse default;
        }

        fn optionalLength(p: *P, node: u32, name: Name, axis: values.Axis, viewport: [2]f32) ?f32 {
            const text = p.doc.get(node, name) orelse return null;
            const l = values.length(text) orelse return null;
            const v = l.resolve(axis, viewport);
            if (name == .rx or name == .ry) {
                if (!(v >= 0)) return null;
            }
            return v;
        }
    };
}

/// What can be drawn: what a `switch` chooses among.
fn drawable(tag: Tag) bool {
    return switch (tag) {
        .g, .a, .@"switch", .svg, .path, .rect, .circle, .ellipse, .line, .polyline, .polygon, .use, .image, .text => true,
        else => false,
    };
}

/// One property set from its text; one that does not read leaves it as
/// it was, and `inherit` takes the parent's.
fn property(s: *Style, parent: *const Style, name: Name, text_in: []const u8) void {
    const text = values.trim(text_in);
    if (std.mem.eql(u8, text, "inherit")) {
        switch (name) {
            .fill => s.fill = parent.fill,
            .@"fill-opacity" => s.fill_opacity = parent.fill_opacity,
            .@"fill-rule" => s.fill_rule = parent.fill_rule,
            .stroke => s.stroke = parent.stroke,
            .@"stroke-opacity" => s.stroke_opacity = parent.stroke_opacity,
            .@"stroke-width" => s.stroke_width = parent.stroke_width,
            .@"stroke-linecap" => s.cap = parent.cap,
            .@"stroke-linejoin" => s.join = parent.join,
            .@"stroke-miterlimit" => s.miter_limit = parent.miter_limit,
            .@"stroke-dasharray" => s.dashes = parent.dashes,
            .@"stroke-dashoffset" => s.dash_offset = parent.dash_offset,
            .color => s.colour = parent.colour,
            .visibility => s.visible = parent.visible,
            .opacity => s.opacity = parent.opacity,
            else => {},
        }
        return;
    }
    switch (name) {
        .fill => if (values.paint(text)) |paint| {
            s.fill = paint;
        },
        .stroke => if (values.paint(text)) |paint| {
            s.stroke = paint;
        },
        .@"fill-opacity" => if (values.fraction(text)) |f| {
            s.fill_opacity = f;
        },
        .@"stroke-opacity" => if (values.fraction(text)) |f| {
            s.stroke_opacity = f;
        },
        .opacity => if (values.fraction(text)) |f| {
            s.opacity = f;
        },
        .@"fill-rule" => {
            if (std.mem.eql(u8, text, "evenodd")) s.fill_rule = vector.RULE_EVENODD;
            if (std.mem.eql(u8, text, "nonzero")) s.fill_rule = vector.RULE_NONZERO;
        },
        .@"stroke-width" => if (values.length(text)) |l| {
            if (l.value >= 0) s.stroke_width = l;
        },
        .@"stroke-linecap" => {
            if (std.mem.eql(u8, text, "butt")) s.cap = vector.CAP_BUTT;
            if (std.mem.eql(u8, text, "round")) s.cap = vector.CAP_ROUND;
            if (std.mem.eql(u8, text, "square")) s.cap = vector.CAP_SQUARE;
        },
        .@"stroke-linejoin" => {
            if (std.mem.eql(u8, text, "miter") or std.mem.eql(u8, text, "miter-clip") or std.mem.eql(u8, text, "arcs")) s.join = vector.JOIN_MITER;
            if (std.mem.eql(u8, text, "round")) s.join = vector.JOIN_ROUND;
            if (std.mem.eql(u8, text, "bevel")) s.join = vector.JOIN_BEVEL;
        },
        .@"stroke-miterlimit" => if (values.number(text)) |n| {
            if (n >= 1) s.miter_limit = n;
        },
        .@"stroke-dasharray" => s.dashes = if (std.mem.eql(u8, text, "none")) "" else text,
        .@"stroke-dashoffset" => if (values.length(text)) |l| {
            s.dash_offset = l;
        },
        .color => if (values.colour(text)) |c| {
            s.colour = c;
        },
        .display => s.shown = !std.mem.eql(u8, text, "none"),
        .visibility => s.visible = std.mem.eql(u8, text, "visible"),
        .filter => s.filtered = text.len != 0 and !std.mem.eql(u8, text, "none"),
        else => {},
    }
}
