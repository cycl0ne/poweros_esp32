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
//! (rounded too), ellipses and paths; fills and strokes of one colour
//! and, since 1.3, of a linear or a radial gradient (`gf`, `gs`), and
//! dashed strokes (`d`); transforms and parents; keyframes with their
//! easing; since 1.4, masks and track mattes. Passed over: text and
//! image layers, expressions, trims, repeaters, stars, skew, 3D, and a
//! mask's expansion.
//!
//! **Masks and mattes** (since 1.4) are vector.library's masks. A
//! layer's masks are made one, in order: each adds its shape to what
//! the ones before it made, takes it away (`s`), or keeps only what is
//! inside it (`i`), at its opacity, inverted when it says (`inv`); a
//! first that takes away or keeps starts from the whole frame. Lighten
//! adds and darken keeps; difference adds. A matte is the layer before
//! it - or the one `tp` names - drawn into a mask by its coverage (`tt`
//! 1, 2 the other way round) or its luminance (3, 4), and not drawn
//! itself. A layer with either is drawn on a layer of its own and put
//! down through them at its opacity. Under a vector.library older than
//! 1.3, which has no masks, they are passed over (`Renderer.masks`).
//!
//! **A gradient** is its stops - a flat array of colour stops (offset,
//! red, green, blue) and after them, when it has them, opacity stops
//! (offset, opacity) - with its start and end points in the units of the
//! shapes it paints. Colour and opacity stops are made one list: a stop
//! wherever either has one, its colour and its opacity each worked out
//! there. A radial gradient is round its start out to its end; its
//! highlight moves the focus that share of the radius from the centre,
//! at the highlight's angle from the line to the end, as lottie-web
//! places it. A dash's lengths and its offset are in those units too,
//! scaled to pixels as the width is.
//!
//! **Drawn by vector.library.** The paths are built in pixels - every
//! point through its layers' and groups' transforms - and filled or
//! stroked on the frame with no matrix of the library's, a stroke's
//! width scaled to pixels as Lottie scales it.

const std = @import("std");
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
/// The most colour stops and opacity stops a gradient is drawn with,
/// each; more are left off its end.
const max_gradient_stops = 32;
/// The most dash and gap lengths a stroke is cut by.
const max_dashes = 16;
/// The most masks of a layer made into its one; the rest are left out.
const max_masks = 8;

/// What a frame is drawn with: vector.library, the path every fill and
/// stroke is built in, and the canvas over the frame's pens.
pub const Renderer = struct {
    tape: Tape,
    vb: *VectorBase,
    path: *vector.Path,
    canvas: *vector.Canvas,
    /// The file's assets, where precompositions are.
    assets: ?u32,
    /// The frame's size in pixels, for a mask that starts from all of it.
    width: f32 = 0,
    height: f32 = 0,
    /// Whether the library has masks (1.3): without them, masks and
    /// mattes are passed over.
    masks: bool = true,

    /// The animation at time `time`, in its frames, `scale` pixels a unit.
    pub fn frame(renderer: *Renderer, root: u32, time: f32, scale: f32) void {
        const tape = renderer.tape;
        renderer.width = (tape.number(tape.get(root, "w")) orelse 0) * scale;
        renderer.height = (tape.number(tape.get(root, "h")) orelse 0) * scale;
        renderer.composition(tape.get(root, "layers"), time, Matrix.scale(scale, scale), 1, 0);
    }

    fn composition(renderer: *Renderer, layers: ?u32, time: f32, matrix: Matrix, opacity: f32, depth: u32) void {
        if (depth > max_depth) return;
        const tape = renderer.tape;
        var n = tape.count(layers);
        while (n > 0) {
            n -= 1;
            renderer.layer(layers.?, tape.item(layers, n).?, time, matrix, opacity, depth, false);
        }
    }

    /// A layer, through its matte and its masks. A matte's source is
    /// drawn only `as_matte`, into the matte of the layer it is for.
    fn layer(renderer: *Renderer, layers: u32, layer_index: u32, time: f32, outer: Matrix, outer_opacity: f32, depth: u32, as_matte: bool) void {
        const tape = renderer.tape;
        if (depth > max_depth) return;
        if (tape.flag(tape.get(layer_index, "hd"))) return;
        if (!as_matte and tape.flag(tape.get(layer_index, "td"))) return;
        const in_point = tape.number(tape.get(layer_index, "ip")) orelse 0;
        const out_point = tape.number(tape.get(layer_index, "op")) orelse 1e9;
        if (time < in_point or time >= out_point) return;
        const local = localTime(tape, layer_index, time);
        const transform = tape.get(layer_index, "ks");
        const matrix = outer.then(renderer.layerMatrix(layers, layer_index, time, 0));
        const opacity = outer_opacity * property.scalar(tape, tape.get(transform, "o"), local, 100) / 100;
        if (opacity <= 0) return;
        const kind = tape.number(tape.get(layer_index, "ty")) orelse return;
        const vb = renderer.vb;
        const canvas = renderer.canvas;
        var clips: u32 = 0;
        defer for (0..clips) |_| vb.PopClip(canvas);
        if (!as_matte and renderer.masks) if (matteOf(tape, layers, layer_index)) |matte| {
            _ = vb.BeginMask(canvas);
            renderer.layer(layers, matte.source, time, outer, 1, depth + 1, true);
            _ = vb.EndMask(canvas, matte.kind);
            clips += 1;
        };
        if (renderer.masks and renderer.masked(layer_index, local, matrix, depth)) clips += 1;
        // Through them, the layer goes down whole at its opacity.
        const layered = clips > 0;
        const inner = if (layered) 1 else opacity;
        if (layered) _ = vb.PushLayer(canvas, opacity);
        defer if (layered) vb.PopLayer(canvas);
        switch (@as(i32, @intFromFloat(kind))) {
            0 => {
                const id = tape.string(tape.get(layer_index, "refId")) orelse return;
                var walk = tape.items(renderer.assets);
                while (walk.next()) |asset| {
                    const asset_id = tape.string(tape.get(asset, "id")) orelse continue;
                    if (!same(asset_id, id)) continue;
                    renderer.composition(tape.get(asset, "layers"), local, matrix, inner, depth + 1);
                    return;
                }
            },
            1 => renderer.solid(layer_index, matrix, inner),
            4 => renderer.items(tape.get(layer_index, "shapes"), local, matrix, inner, depth),
            else => {},
        }
    }

    /// A layer's masks made one and pushed as a mask; false when it has
    /// none that does anything.
    fn masked(renderer: *Renderer, layer_index: u32, time: f32, matrix: Matrix, depth: u32) bool {
        const tape = renderer.tape;
        const masks = tape.get(layer_index, "masksProperties") orelse return false;
        const count = @min(tape.count(masks), max_masks);
        var first: ?u8 = null;
        for (0..count) |i| {
            const mode = maskMode(tape, tape.item(masks, @intCast(i)).?);
            if (mode != 'n') {
                first = mode;
                break;
            }
        }
        const start = first orelse return false;
        _ = renderer.vb.BeginMask(renderer.canvas);
        renderer.maskOf(masks, count, start == 's' or start == 'i' or start == 'd', time, matrix, depth);
        _ = renderer.vb.EndMask(renderer.canvas, vector.MASK_ALPHA);
        return true;
    }

    /// What the first `n` masks make, drawn white by its coverage. One
    /// that takes away or keeps is a mask itself, what came before drawn
    /// through it on a layer; `whole` is what there is before the first.
    fn maskOf(renderer: *Renderer, masks: u32, n: u32, whole: bool, time: f32, matrix: Matrix, depth: u32) void {
        const vb = renderer.vb;
        const canvas = renderer.canvas;
        if (n == 0) {
            if (whole) {
                vb.ClearPath(renderer.path);
                renderer.frameRect();
                _ = vb.FillPath(canvas, renderer.path, null, &white, vector.RULE_NONZERO);
            }
            return;
        }
        const tape = renderer.tape;
        const mask = tape.item(masks, n - 1).?;
        const mode = maskMode(tape, mask);
        const inverted = tape.flag(tape.get(mask, "inv"));
        const opacity = property.scalar(tape, tape.get(mask, "o"), time, 100) / 100;
        switch (mode) {
            'n' => renderer.maskOf(masks, n - 1, whole, time, matrix, depth),
            's', 'i', 'd' => {
                _ = vb.BeginMask(canvas);
                renderer.maskShape(mask, time, matrix, opacity, false);
                const outside = (mode == 's') != inverted;
                _ = vb.EndMask(canvas, if (outside) vector.MASK_ALPHA | vector.MASK_INVERT else vector.MASK_ALPHA);
                _ = vb.PushLayer(canvas, 1);
                renderer.maskOf(masks, n - 1, whole, time, matrix, depth + 1);
                vb.PopLayer(canvas);
                vb.PopClip(canvas);
            },
            else => {
                renderer.maskOf(masks, n - 1, whole, time, matrix, depth);
                renderer.maskShape(mask, time, matrix, opacity, inverted);
            },
        }
    }

    /// A mask's shape filled white at its opacity; everything else in
    /// the frame instead when it is inverted.
    fn maskShape(renderer: *Renderer, mask: u32, time: f32, matrix: Matrix, opacity: f32, inverted: bool) void {
        const vb = renderer.vb;
        vb.ClearPath(renderer.path);
        if (inverted) renderer.frameRect();
        renderer.shapeOf(renderer.tape.get(mask, "pt"), time, matrix);
        const paint = vector.Paint{ .colour = .{ .r = 1, .g = 1, .b = 1 }, .opacity = opacity };
        _ = vb.FillPath(renderer.canvas, renderer.path, null, &paint, if (inverted) vector.RULE_EVENODD else vector.RULE_NONZERO);
    }

    /// The frame and a pixel round it, onto the path.
    fn frameRect(renderer: *Renderer) void {
        const vb = renderer.vb;
        const path = renderer.path;
        vb.MoveTo(path, -1, -1);
        vb.LineTo(path, renderer.width + 1, -1);
        vb.LineTo(path, renderer.width + 1, renderer.height + 1);
        vb.LineTo(path, -1, renderer.height + 1);
        vb.ClosePath(path);
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
            } else if (same(kind, "fl") or same(kind, "st") or same(kind, "gf") or same(kind, "gs")) {
                renderer.vb.ClearPath(renderer.path);
                renderer.paths(list.?, n, time, matrix, depth);
                renderer.style(item, kind[1] == 't' or kind[1] == 's', kind[0] == 'g', time, matrix, opacity);
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

    /// The path painted by a fill or a stroke, in a colour or a gradient.
    /// What did not fit in memory is left out: the frame is drawn as far
    /// as it went.
    fn style(renderer: *Renderer, item: u32, stroked: bool, gradient: bool, time: f32, matrix: Matrix, opacity: f32) void {
        const tape = renderer.tape;
        const paint_opacity = opacity * property.scalar(tape, tape.get(item, "o"), time, 100) / 100;
        var stops: [2 * max_gradient_stops]vector.Stop = undefined;
        const paint = if (gradient)
            gradientOf(tape, item, time, matrix, paint_opacity, &stops) orelse return
        else
            colourOf(tape, item, time, paint_opacity);
        if (stroked) {
            const scale = matrix.size();
            var dashes: [max_dashes]f32 = undefined;
            var stroke = vector.Stroke{
                .width = property.scalar(tape, tape.get(item, "w"), time, 1) * scale,
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
            dashesOf(tape, item, time, scale, &dashes, &stroke);
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
        renderer.shapeOf(renderer.tape.get(item, "ks"), time, matrix);
    }

    /// A shape property's vertices onto the path - a path's or a mask's.
    fn shapeOf(renderer: *Renderer, prop: ?u32, time: f32, matrix: Matrix) void {
        const tape = renderer.tape;
        const at = property.shape(tape, prop, time) orelse return;
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

const white = vector.Paint{ .colour = .{ .r = 1, .g = 1, .b = 1 } };

/// A mask's mode, its letter: `a` adds, `s` takes away, `i` keeps what
/// is inside, `n` does nothing; lighten, darken and difference are `l`,
/// `d` and `f`.
fn maskMode(tape: Tape, mask: u32) u8 {
    const mode = tape.string(tape.get(mask, "mode")) orelse return 'a';
    return if (mode.len == 1) mode[0] else 'a';
}

const Matte = struct { source: u32, kind: u32 };

/// The matte a layer is drawn through: `tt`'s kind, and the layer `tp`
/// names or else the one before it.
fn matteOf(tape: Tape, layers: u32, layer_index: u32) ?Matte {
    const tt = tape.number(tape.get(layer_index, "tt")) orelse return null;
    const kind: u32 = switch (@as(i32, @intFromFloat(tt))) {
        1 => vector.MASK_ALPHA,
        2 => vector.MASK_ALPHA | vector.MASK_INVERT,
        3 => vector.MASK_LUMINANCE,
        4 => vector.MASK_LUMINANCE | vector.MASK_INVERT,
        else => return null,
    };
    var walk = tape.items(layers);
    if (tape.number(tape.get(layer_index, "tp"))) |wanted| {
        while (walk.next()) |other| {
            if (other != layer_index and tape.number(tape.get(other, "ind")) == wanted) return .{ .source = other, .kind = kind };
        }
        return null;
    }
    var before: ?u32 = null;
    while (walk.next()) |other| {
        if (other == layer_index) return .{ .source = before orelse return null, .kind = kind };
        before = other;
    }
    return null;
}

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

/// A fill's or a stroke's one colour.
fn colourOf(tape: Tape, item: u32, time: f32, opacity: f32) vector.Paint {
    const colour_value = property.value(tape, tape.get(item, "c"), time, property.Value.of(&.{ 0, 0, 0 }));
    var colour = vector.Colour{ .r = colour_value.at(0), .g = colour_value.at(1), .b = colour_value.at(2) };
    // Files of the oldest kind give colours to 255.
    if (colour.r > 1 or colour.g > 1 or colour.b > 1) colour = .{ .r = colour.r / 255, .g = colour.g / 255, .b = colour.b / 255 };
    return .{ .colour = colour, .opacity = opacity };
}

/// A gradient fill's or stroke's paint, its points through `matrix`
/// into pixels; null where it has no stops.
fn gradientOf(tape: Tape, item: u32, time: f32, matrix: Matrix, opacity: f32, stops: *[2 * max_gradient_stops]vector.Stop) ?vector.Paint {
    const g = tape.get(item, "g");
    const colour_stops: u32 = @intFromFloat(@max(0, @min(tape.number(tape.get(g, "p")) orelse 0, 1e6)));
    var numbers: [6 * max_gradient_stops]f32 = undefined;
    const n = property.flat(tape, tape.get(g, "k"), time, &numbers);
    const colours = @min(colour_stops, n / 4, max_gradient_stops);
    if (colours == 0) return null;
    // Opacity stops follow all the colour stops, the ones not read too.
    const opacity_start = @min(colour_stops * 4, n);
    const alphas = @min((n - opacity_start) / 2, max_gradient_stops);
    const stop_count = mergeStops(numbers[0 .. colours * 4], numbers[opacity_start .. opacity_start + alphas * 2], stops);

    const start = property.value(tape, tape.get(item, "s"), time, property.Value.of(&.{ 0, 0 }));
    const end = property.value(tape, tape.get(item, "e"), time, property.Value.of(&.{ 0, 0 }));
    var paint = vector.Paint{
        .kind = vector.PAINT_LINEAR,
        .opacity = opacity,
        .stops = stops,
        .stop_count = stop_count,
        .matrix = matrix,
        .x1 = start.at(0),
        .y1 = start.at(1),
        .x2 = end.at(0),
        .y2 = end.at(1),
    };
    if ((tape.number(tape.get(item, "t")) orelse 1) == 2) {
        const dx = end.at(0) - start.at(0);
        const dy = end.at(1) - start.at(1);
        const radius = @sqrt(dx * dx + dy * dy);
        if (!(radius > 0)) return .{ .colour = stops[stop_count - 1].colour, .opacity = opacity };
        // The focus a share of the radius out, kept inside the circle.
        const share = @max(-0.99, @min(0.99, property.scalar(tape, tape.get(item, "h"), time, 0) / 100));
        const angle = std.math.atan2(dy, dx) + property.scalar(tape, tape.get(item, "a"), time, 0) * std.math.pi / 180;
        paint.kind = vector.PAINT_RADIAL;
        paint.cx = start.at(0);
        paint.cy = start.at(1);
        paint.r = radius;
        paint.fx = start.at(0) + @cos(angle) * radius * share;
        paint.fy = start.at(1) + @sin(angle) * radius * share;
    }
    return paint;
}

/// Colour stops (offset, red, green, blue) and opacity stops (offset,
/// opacity), both by offset rising, made one list onto `out`: a stop at
/// every offset either has, its colour and its opacity worked out there.
/// How many.
fn mergeStops(colours: []const f32, alphas: []const f32, out: *[2 * max_gradient_stops]vector.Stop) u32 {
    const colour_count = colours.len / 4;
    const alpha_count = alphas.len / 2;
    var i: usize = 0;
    var j: usize = 0;
    var n: u32 = 0;
    while (i < colour_count or j < alpha_count) {
        const colour_at = if (i < colour_count) colours[i * 4] else std.math.inf(f32);
        const alpha_at = if (j < alpha_count) alphas[j * 2] else std.math.inf(f32);
        const offset = @min(colour_at, alpha_at);
        if (colour_at <= offset) i += 1;
        if (alpha_at <= offset) j += 1;
        var colour = colourAt(colours, offset);
        colour.a = if (alpha_count == 0) 1 else alphaAt(alphas, offset);
        out[n] = .{ .offset = @max(0, @min(1, offset)), .colour = colour };
        n += 1;
    }
    return n;
}

/// The colour stops' colour at `offset`: the nearest end's beyond them.
fn colourAt(colours: []const f32, offset: f32) vector.Colour {
    const count = colours.len / 4;
    var k: usize = 0;
    while (k + 1 < count and colours[(k + 1) * 4] < offset) k += 1;
    const a = colours[k * 4 ..][0..4];
    if (k + 1 >= count or offset <= a[0]) return .{ .r = a[1], .g = a[2], .b = a[3] };
    const b = colours[(k + 1) * 4 ..][0..4];
    const t = if (b[0] > a[0]) @min(1, (offset - a[0]) / (b[0] - a[0])) else 1;
    return .{ .r = a[1] + (b[1] - a[1]) * t, .g = a[2] + (b[2] - a[2]) * t, .b = a[3] + (b[3] - a[3]) * t };
}

/// The opacity stops' opacity at `offset`.
fn alphaAt(alphas: []const f32, offset: f32) f32 {
    const count = alphas.len / 2;
    var k: usize = 0;
    while (k + 1 < count and alphas[(k + 1) * 2] < offset) k += 1;
    const a = alphas[k * 2 ..][0..2];
    if (k + 1 >= count or offset <= a[0]) return a[1];
    const b = alphas[(k + 1) * 2 ..][0..2];
    const t = if (b[0] > a[0]) @min(1, (offset - a[0]) / (b[0] - a[0])) else 1;
    return a[1] + (b[1] - a[1]) * t;
}

/// A stroke's dashes (`d`: dash `d`, gap `g` and offset `o` items, in
/// turn), `scale` pixels a unit, onto the stroke. None when they add up
/// to nothing.
fn dashesOf(tape: Tape, item: u32, time: f32, scale: f32, dashes: *[max_dashes]f32, stroke: *vector.Stroke) void {
    var walk = tape.items(tape.get(item, "d"));
    var n: u32 = 0;
    var total: f32 = 0;
    var offset: f32 = 0;
    while (walk.next()) |dash| {
        const name = tape.string(tape.get(dash, "n")) orelse continue;
        const length = property.scalar(tape, tape.get(dash, "v"), time, 0) * scale;
        if (same(name, "o")) {
            offset = length;
        } else if ((same(name, "d") or same(name, "g")) and n < max_dashes) {
            dashes[n] = @max(0, length);
            total += dashes[n];
            n += 1;
        }
    }
    if (n == 0 or !(total > 0)) return;
    stroke.dashes = dashes;
    stroke.dash_count = n;
    stroke.dash_offset = offset;
}

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
