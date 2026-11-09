// SPDX-License-Identifier: MIT
//! One frame of a Lottie animation drawn: its layers, their shapes, and
//! what fills and strokes them.
//!
//! A composition is a list of layers, the first on top: they are drawn
//! from the last. A layer is seen from its in point up to its out point;
//! its own time is the composition's less its start, over its stretch.
//! Its transform - anchor, position, scale, rotation - places it, after
//! that of the layer it names as its parent and that one's parent; its
//! opacity applies to it and what it holds. A shape layer holds shapes,
//! a solid layer a rectangle of one colour, a precomposition layer
//! another composition from the file's assets, drawn in its own time.
//!
//! **Shapes are painted by what follows them.** A layer's shapes are a
//! list - paths, groups, fills, strokes - the first on top. A fill or a
//! stroke paints every path before it in its list and inside the groups
//! before it, each through its group's transform; the paths are one
//! shape to it, so one inside another with the even-odd rule leaves a
//! hole. A group's transform carries its own opacity to what is inside.
//!
//! Drawn: shape, solid and precomposition layers; groups, rectangles
//! (rounded too), ellipses and paths; fills and strokes of one colour;
//! transforms and parents; keyframes with their easing. Passed over:
//! gradients, masks and mattes (a matte's source is not drawn, the layer
//! it is for is drawn without it), text and image layers, expressions,
//! trims, repeaters, stars, dashes, skew and 3D.
//!
//! **Drawn by vector.library.** The paths are built in pixels - every
//! point through its layers' and groups' transforms - and filled or
//! stroked on the frame with no matrix of the library's, a stroke's
//! width scaled to pixels as Lottie scales it.

const sdk = @import("sdk");
const vector = sdk.vector;
const VectorBase = sdk.interface.vector.VectorBase;
const json = @import("json.zig");
const property = @import("property.zig");
const Tape = json.Tape;
const Matrix = vector.Matrix;
const P = vector.Point;

/// The deepest nesting of precompositions, groups and parents followed.
const max_depth = 16;

/// What a frame is drawn with: vector.library, the path every fill and
/// stroke is built in, and the canvas over the frame's pens.
pub const Renderer = struct {
    tape: Tape,
    vb: *VectorBase,
    path: *vector.Path,
    canvas: *vector.Canvas,
    /// The file's assets, where precompositions are.
    assets: ?u32,

    /// The animation at time `time`, in its frames, `scale` pixels a unit.
    pub fn frame(renderer: *Renderer, root: u32, time: f32, scale: f32) void {
        renderer.composition(renderer.tape.get(root, "layers"), time, Matrix.scale(scale, scale), 1, 0);
    }

    fn composition(renderer: *Renderer, layers: ?u32, time: f32, matrix: Matrix, opacity: f32, depth: u32) void {
        if (depth > max_depth) return;
        const tape = renderer.tape;
        var n = tape.count(layers);
        while (n > 0) {
            n -= 1;
            renderer.layer(layers.?, tape.item(layers, n).?, time, matrix, opacity, depth);
        }
    }

    fn layer(renderer: *Renderer, layers: u32, layer_index: u32, time: f32, outer: Matrix, outer_opacity: f32, depth: u32) void {
        const tape = renderer.tape;
        if (tape.flag(tape.get(layer_index, "hd"))) return;
        // A matte's source.
        if (tape.flag(tape.get(layer_index, "td"))) return;
        const in_point = tape.number(tape.get(layer_index, "ip")) orelse 0;
        const out_point = tape.number(tape.get(layer_index, "op")) orelse 1e9;
        if (time < in_point or time >= out_point) return;
        const local = localTime(tape, layer_index, time);
        const transform = tape.get(layer_index, "ks");
        const matrix = outer.then(renderer.layerMatrix(layers, layer_index, time, 0));
        const opacity = outer_opacity * property.scalar(tape, tape.get(transform, "o"), local, 100) / 100;
        if (opacity <= 0) return;
        const kind = tape.number(tape.get(layer_index, "ty")) orelse return;
        switch (@as(i32, @intFromFloat(kind))) {
            0 => {
                const id = tape.string(tape.get(layer_index, "refId")) orelse return;
                var walk = tape.items(renderer.assets);
                while (walk.next()) |asset| {
                    const asset_id = tape.string(tape.get(asset, "id")) orelse continue;
                    if (!same(asset_id, id)) continue;
                    renderer.composition(tape.get(asset, "layers"), local, matrix, opacity, depth + 1);
                    return;
                }
            },
            1 => renderer.solid(layer_index, matrix, opacity),
            4 => renderer.items(tape.get(layer_index, "shapes"), local, matrix, opacity, depth),
            else => {},
        }
    }

    /// A layer's transform after its parents'.
    fn layerMatrix(renderer: *Renderer, layers: u32, layer_index: u32, time: f32, depth: u32) Matrix {
        const tape = renderer.tape;
        const own = transformMatrix(tape, tape.get(layer_index, "ks"), localTime(tape, layer_index, time));
        if (depth > max_depth) return own;
        const parent_number = tape.number(tape.get(layer_index, "parent")) orelse return own;
        var walk = tape.items(layers);
        while (walk.next()) |other| {
            const number = tape.number(tape.get(other, "ind")) orelse continue;
            if (number != parent_number or other == layer_index) continue;
            return renderer.layerMatrix(layers, other, time, depth + 1).then(own);
        }
        return own;
    }

    fn solid(renderer: *Renderer, layer_index: u32, matrix: Matrix, opacity: f32) void {
        const tape = renderer.tape;
        const width = tape.number(tape.get(layer_index, "sw")) orelse return;
        const height = tape.number(tape.get(layer_index, "sh")) orelse return;
        const colour = hexColour(tape.string(tape.get(layer_index, "sc")) orelse return) orelse return;
        const vb = renderer.vb;
        const path = renderer.path;
        vb.ClearPath(path);
        for ([_]P{ .{ .x = 0, .y = 0 }, .{ .x = width, .y = 0 }, .{ .x = width, .y = height }, .{ .x = 0, .y = height } }, 0..) |corner, i| {
            const at = matrix.apply(corner);
            if (i == 0) vb.MoveTo(path, at.x, at.y) else vb.LineTo(path, at.x, at.y);
        }
        vb.ClosePath(path);
        const paint = vector.Paint{ .colour = colour, .opacity = opacity };
        _ = vb.FillPath(renderer.canvas, path, null, &paint, vector.RULE_NONZERO);
    }

    /// A list of shapes, from the last: each fill and stroke paints the
    /// paths before it, each group is drawn where it stands.
    fn items(renderer: *Renderer, list: ?u32, time: f32, matrix: Matrix, opacity: f32, depth: u32) void {
        if (depth > max_depth) return;
        const tape = renderer.tape;
        var n = tape.count(list);
        while (n > 0) {
            n -= 1;
            const item = tape.item(list, n).?;
            if (tape.flag(tape.get(item, "hd"))) continue;
            const kind = tape.string(tape.get(item, "ty")) orelse continue;
            if (same(kind, "gr")) {
                const inside = tape.get(item, "it");
                const transform = groupTransform(tape, inside);
                const group_opacity = property.scalar(tape, tape.get(transform, "o"), time, 100) / 100;
                renderer.items(inside, time, matrix.then(transformMatrix(tape, transform, time)), opacity * group_opacity, depth + 1);
            } else if (same(kind, "fl") or same(kind, "st")) {
                renderer.vb.ClearPath(renderer.path);
                renderer.paths(list.?, n, time, matrix, depth);
                renderer.style(item, kind[0] == 's', time, matrix, opacity);
            }
        }
    }

    /// The paths among the first `upto` items of a list, and inside its
    /// groups, onto the path.
    fn paths(renderer: *Renderer, list: u32, upto: u32, time: f32, matrix: Matrix, depth: u32) void {
        if (depth > max_depth) return;
        const tape = renderer.tape;
        var walk = tape.items(list);
        var n: u32 = 0;
        while (walk.next()) |item| : (n += 1) {
            if (n >= upto) break;
            if (tape.flag(tape.get(item, "hd"))) continue;
            const kind = tape.string(tape.get(item, "ty")) orelse continue;
            if (same(kind, "gr")) {
                const inside = tape.get(item, "it") orelse continue;
                const inner = matrix.then(transformMatrix(tape, groupTransform(tape, inside), time));
                renderer.paths(inside, tape.count(inside), time, inner, depth + 1);
            } else if (same(kind, "rc")) {
                renderer.rectangle(item, time, matrix);
            } else if (same(kind, "el")) {
                renderer.ellipse(item, time, matrix);
            } else if (same(kind, "sh")) {
                renderer.shape(item, time, matrix);
            }
        }
    }

    /// The path painted by a fill or a stroke. What did not fit in memory
    /// is left out: the frame is drawn as far as it went.
    fn style(renderer: *Renderer, item: u32, stroked: bool, time: f32, matrix: Matrix, opacity: f32) void {
        const tape = renderer.tape;
        const colour_value = property.value(tape, tape.get(item, "c"), time, property.Value.of(&.{ 0, 0, 0 }));
        var colour = vector.Colour{ .r = colour_value.at(0), .g = colour_value.at(1), .b = colour_value.at(2) };
        // Files of the oldest kind give colours to 255.
        if (colour.r > 1 or colour.g > 1 or colour.b > 1) colour = .{ .r = colour.r / 255, .g = colour.g / 255, .b = colour.b / 255 };
        const paint = vector.Paint{
            .colour = colour,
            .opacity = opacity * property.scalar(tape, tape.get(item, "o"), time, 100) / 100,
        };
        if (stroked) {
            const stroke = vector.Stroke{
                .width = property.scalar(tape, tape.get(item, "w"), time, 1) * matrix.size(),
                .join = switch (@as(i32, @intFromFloat(tape.number(tape.get(item, "lj")) orelse 1))) {
                    2 => vector.JOIN_ROUND,
                    3 => vector.JOIN_BEVEL,
                    else => vector.JOIN_MITER,
                },
                .cap = switch (@as(i32, @intFromFloat(tape.number(tape.get(item, "lc")) orelse 1))) {
                    2 => vector.CAP_ROUND,
                    3 => vector.CAP_SQUARE,
                    else => vector.CAP_BUTT,
                },
                .miter_limit = tape.number(tape.get(item, "ml")) orelse 4,
            };
            _ = renderer.vb.StrokePath(renderer.canvas, renderer.path, null, &paint, &stroke);
        } else {
            const rule: u32 = if ((tape.number(tape.get(item, "r")) orelse 1) == 2) vector.RULE_EVENODD else vector.RULE_NONZERO;
            _ = renderer.vb.FillPath(renderer.canvas, renderer.path, null, &paint, rule);
        }
    }

    fn rectangle(renderer: *Renderer, item: u32, time: f32, matrix: Matrix) void {
        const tape = renderer.tape;
        const centre = property.value(tape, tape.get(item, "p"), time, property.Value.of(&.{ 0, 0 }));
        const size = property.value(tape, tape.get(item, "s"), time, property.Value.of(&.{ 0, 0 }));
        const x = centre.at(0);
        const y = centre.at(1);
        const half_width = size.at(0) / 2;
        const half_height = size.at(1) / 2;
        const left = x - half_width;
        const right = x + half_width;
        const top = y - half_height;
        const bottom = y + half_height;
        const round = @min(property.scalar(tape, tape.get(item, "r"), time, 0), half_width, half_height);
        var corners = Vertices{};
        if (round <= 0) {
            corners.add(.{ .x = right, .y = top }, zero, zero);
            corners.add(.{ .x = right, .y = bottom }, zero, zero);
            corners.add(.{ .x = left, .y = bottom }, zero, zero);
            corners.add(.{ .x = left, .y = top }, zero, zero);
        } else {
            const c = round * kappa;
            corners.add(.{ .x = right, .y = top + round }, .{ .x = 0, .y = -c }, zero);
            corners.add(.{ .x = right, .y = bottom - round }, zero, .{ .x = 0, .y = c });
            corners.add(.{ .x = right - round, .y = bottom }, .{ .x = c, .y = 0 }, zero);
            corners.add(.{ .x = left + round, .y = bottom }, zero, .{ .x = -c, .y = 0 });
            corners.add(.{ .x = left, .y = bottom - round }, .{ .x = 0, .y = c }, zero);
            corners.add(.{ .x = left, .y = top + round }, zero, .{ .x = 0, .y = -c });
            corners.add(.{ .x = left + round, .y = top }, .{ .x = -c, .y = 0 }, zero);
            corners.add(.{ .x = right - round, .y = top }, zero, .{ .x = c, .y = 0 });
        }
        corners.write(renderer, matrix, reversed(tape, item));
    }

    fn ellipse(renderer: *Renderer, item: u32, time: f32, matrix: Matrix) void {
        const tape = renderer.tape;
        const centre = property.value(tape, tape.get(item, "p"), time, property.Value.of(&.{ 0, 0 }));
        const size = property.value(tape, tape.get(item, "s"), time, property.Value.of(&.{ 0, 0 }));
        const x = centre.at(0);
        const y = centre.at(1);
        const rx = size.at(0) / 2;
        const ry = size.at(1) / 2;
        const cx = rx * kappa;
        const cy = ry * kappa;
        var points = Vertices{};
        points.add(.{ .x = x, .y = y - ry }, .{ .x = -cx, .y = 0 }, .{ .x = cx, .y = 0 });
        points.add(.{ .x = x + rx, .y = y }, .{ .x = 0, .y = -cy }, .{ .x = 0, .y = cy });
        points.add(.{ .x = x, .y = y + ry }, .{ .x = cx, .y = 0 }, .{ .x = -cx, .y = 0 });
        points.add(.{ .x = x - rx, .y = y }, .{ .x = 0, .y = cy }, .{ .x = 0, .y = -cy });
        points.write(renderer, matrix, reversed(tape, item));
    }

    /// A path's vertices, between two keyframes' as far as it has come.
    fn shape(renderer: *Renderer, item: u32, time: f32, matrix: Matrix) void {
        const tape = renderer.tape;
        const at = property.shape(tape, tape.get(item, "ks"), time) orelse return;
        const closed = tape.flag(tape.get(at.from, "c"));
        var from = Cursor.of(tape, at.from);
        var to: ?Cursor = if (at.to) |other| Cursor.of(tape, other) else null;
        var writer = Writer.of(renderer, matrix);
        while (from.next()) |start| {
            var vertex = start;
            if (to) |*other| if (other.next()) |end| {
                vertex = .{
                    .v = mix(start.v, end.v, at.progress),
                    .in = mix(start.in, end.in, at.progress),
                    .out = mix(start.out, end.out, at.progress),
                };
            };
            writer.vertex(vertex);
        }
        writer.finish(closed);
    }
};

/// The control point distance that makes four cubic curves a circle.
const kappa: f32 = 0.5522848;
const zero = P{ .x = 0, .y = 0 };

/// A vertex of a path: where it is, and its two control points, each
/// relative to it.
const Vertex = struct { v: P, in: P, out: P };

/// The few vertices of a rectangle or an ellipse.
const Vertices = struct {
    list: [8]Vertex = undefined,
    count: u32 = 0,

    fn add(vertices: *Vertices, v: P, in: P, out: P) void {
        vertices.list[vertices.count] = .{ .v = v, .in = in, .out = out };
        vertices.count += 1;
    }

    /// Onto the path, closed, the other way round when asked.
    fn write(vertices: *const Vertices, renderer: *Renderer, matrix: Matrix, backwards: bool) void {
        var writer = Writer.of(renderer, matrix);
        if (backwards) {
            var i = vertices.count;
            while (i > 0) {
                i -= 1;
                const vertex = vertices.list[i];
                writer.vertex(.{ .v = vertex.v, .in = vertex.out, .out = vertex.in });
            }
        } else {
            for (vertices.list[0..vertices.count]) |vertex| writer.vertex(vertex);
        }
        writer.finish(true);
    }
};

/// Whether a rectangle or an ellipse goes round the other way.
fn reversed(tape: Tape, item: u32) bool {
    return (tape.number(tape.get(item, "d")) orelse 1) == 3;
}

/// Vertices onto the path as cubic curves, each from the last, in
/// pixels.
const Writer = struct {
    vb: *VectorBase,
    path: *vector.Path,
    matrix: Matrix,
    first: ?Vertex = null,
    last: Vertex = undefined,

    fn of(renderer: *const Renderer, matrix: Matrix) Writer {
        return .{ .vb = renderer.vb, .path = renderer.path, .matrix = matrix };
    }

    fn vertex(writer: *Writer, next: Vertex) void {
        if (writer.first == null) {
            writer.first = next;
            const at = writer.matrix.apply(next.v);
            writer.vb.MoveTo(writer.path, at.x, at.y);
        } else writer.curve(writer.last, next);
        writer.last = next;
    }

    fn curve(writer: *Writer, from: Vertex, to: Vertex) void {
        const m = writer.matrix;
        const end = m.apply(to.v);
        if (from.out.x == 0 and from.out.y == 0 and to.in.x == 0 and to.in.y == 0) {
            writer.vb.LineTo(writer.path, end.x, end.y);
        } else {
            const c1 = m.apply(.{ .x = from.v.x + from.out.x, .y = from.v.y + from.out.y });
            const c2 = m.apply(.{ .x = to.v.x + to.in.x, .y = to.v.y + to.in.y });
            writer.vb.CubicTo(writer.path, c1.x, c1.y, c2.x, c2.y, end.x, end.y);
        }
    }

    /// The contour ended; an open one is left open, and the next move
    /// starts another.
    fn finish(writer: *Writer, closed: bool) void {
        const first = writer.first orelse return;
        if (!closed) return;
        writer.curve(writer.last, first);
        writer.vb.ClosePath(writer.path);
    }
};

/// Walks the vertices of a path object `{"v": [...], "i": [...], "o": [...]}`.
const Cursor = struct {
    tape: Tape,
    v: json.Items,
    in: json.Items,
    out: json.Items,

    fn of(tape: Tape, shape: u32) Cursor {
        return .{
            .tape = tape,
            .v = tape.items(tape.get(shape, "v")),
            .in = tape.items(tape.get(shape, "i")),
            .out = tape.items(tape.get(shape, "o")),
        };
    }

    fn next(cursor: *Cursor) ?Vertex {
        const v = cursor.v.next() orelse return null;
        return .{
            .v = point(cursor.tape, v),
            .in = if (cursor.in.next()) |at| point(cursor.tape, at) else zero,
            .out = if (cursor.out.next()) |at| point(cursor.tape, at) else zero,
        };
    }
};

fn point(tape: Tape, index: u32) P {
    const value = property.vector(tape, index);
    return .{ .x = value.at(0), .y = value.at(1) };
}

fn mix(a: P, b: P, t: f32) P {
    return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
}

/// A layer's own time at the composition's `time`.
fn localTime(tape: Tape, layer: u32, time: f32) f32 {
    const start = tape.number(tape.get(layer, "st")) orelse 0;
    const stretch = tape.number(tape.get(layer, "sr")) orelse 1;
    return (time - start) / (if (stretch == 0) 1 else stretch);
}

/// A group's transform: the last of its items, of type `tr`.
fn groupTransform(tape: Tape, inside: ?u32) ?u32 {
    const n = tape.count(inside);
    if (n == 0) return null;
    const last = tape.item(inside, n - 1).?;
    const kind = tape.string(tape.get(last, "ty")) orelse return null;
    return if (same(kind, "tr")) last else null;
}

/// A transform object's matrix at `time`: from its anchor, scaled,
/// rotated, then moved to its position.
pub fn transformMatrix(tape: Tape, transform: ?u32, time: f32) Matrix {
    const object = transform orelse return .{};
    const anchor = property.value(tape, tape.get(object, "a"), time, property.Value.of(&.{ 0, 0 }));
    const position = positionOf(tape, tape.get(object, "p"), time);
    const scale = property.value(tape, tape.get(object, "s"), time, property.Value.of(&.{ 100, 100 }));
    const rotation_prop = tape.get(object, "r") orelse tape.get(object, "rz");
    const rotation = property.scalar(tape, rotation_prop, time, 0);
    return Matrix.translate(position.x, position.y)
        .then(Matrix.rotate(rotation))
        .then(Matrix.scale(scale.at(0) / 100, scale.at(1) / 100))
        .then(Matrix.translate(-anchor.at(0), -anchor.at(1)));
}

/// A position, whole or split into its x and y.
fn positionOf(tape: Tape, prop: ?u32, time: f32) P {
    const object = prop orelse return zero;
    if (tape.flag(tape.get(object, "s"))) {
        return .{
            .x = property.scalar(tape, tape.get(object, "x"), time, 0),
            .y = property.scalar(tape, tape.get(object, "y"), time, 0),
        };
    }
    const value = property.value(tape, object, time, property.Value.of(&.{ 0, 0 }));
    return .{ .x = value.at(0), .y = value.at(1) };
}

/// `#rrggbb` as a colour.
fn hexColour(text: []const u8) ?vector.Colour {
    const digits = if (text.len > 0 and text[0] == '#') text[1..] else text;
    if (digits.len < 6) return null;
    var value: u32 = 0;
    for (digits[0..6]) |c| {
        const d: u32 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        value = value << 4 | d;
    }
    return .{
        .r = @as(f32, @floatFromInt(value >> 16)) / 255,
        .g = @as(f32, @floatFromInt((value >> 8) & 0xFF)) / 255,
        .b = @as(f32, @floatFromInt(value & 0xFF)) / 255,
    };
}

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
