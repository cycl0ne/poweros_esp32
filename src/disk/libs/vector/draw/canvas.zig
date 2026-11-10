// SPDX-License-Identifier: MIT
//! A canvas: the caller's pens and the drawing's working memory for them -
//! the coverage of a band of rows, the points of the contour being drawn,
//! a gradient's colours, the dash being cut, and the layers pushed.
//!
//! **Bands.** The coverage is summed a band of rows at a time, not over the
//! whole canvas: a fill or a stroke is drawn once a band, each time from
//! its path, and laid down before the next. A band holds at most
//! `band_floats` floats (512 KiB), so a canvas of 360 by 360 - the
//! largest a Lottie frame is drawn - is one band, and one of 1024 by 1024
//! is nine of 113 rows rather than 4 MiB of coverage at once. Only the
//! bands the path can reach are drawn.
//!
//! **Laid down by coverage**: a pixel's share of the shape times the
//! paint's opacity is how much of the paint goes over what the pen held,
//! the pens being 0xAARRGGBB and not premultiplied. A gradient's colour
//! comes from a ramp of 256 made once a fill (`gradient.zig`).
//!
//! **Layers** (since 1.1). A layer is pens of its own, the canvas's size
//! and clear, that everything drawn goes onto until it is popped; then
//! what was drawn on it is put down on what is under it at the layer's
//! opacity, so shapes in it that overlap are not seen through each
//! other. Without the memory for one, its opacity goes into every paint
//! drawn until it is popped instead - wrong only where those overlap.
//!
//! **Clips and masks** (since 1.3). A clip is a byte a pixel, the
//! canvas's size: how much of what is drawn shows there. One made from a
//! path is the path's coverage (`pushClip`); a mask is a layer drawn on
//! and then turned into one - its coverage, or its colours' luminance
//! times it, or either the other way round (`beginMask`, `endMask`).
//! Either is made inside the clip under it, multiplied by it, and goes
//! with the layer it was pushed on: what is drawn on that layer shows
//! through it, and so does a layer put down on it, once. What is drawn
//! on a layer pushed after the clip is not clipped until that layer is
//! put down - so a group drawn on a layer of its own goes through a mask
//! as a whole, as SVG has it. A clip with no memory clips nothing more
//! than the one under it: drawn whole rather than not at all.

const sdk = @import("sdk");
const vector = sdk.vector;
const Pen = sdk.graphics.Pen;
const P = vector.Point;
const Matrix = vector.Matrix;
const memory_ = @import("memory.zig");
const Memory = memory_.Memory;
const List = memory_.List;
const Path = @import("path.zig").Path;
const flatten = @import("flatten.zig");
const coverage_ = @import("coverage.zig");
const Coverage = coverage_.Coverage;
const stroke_ = @import("stroke.zig");
const gradient = @import("gradient.zig");
const dash_ = @import("dash.zig");

/// The most floats a band of coverage holds.
pub const band_floats: usize = 128 * 1024;

pub const Canvas = struct {
    memory: Memory,
    width: u32,
    height: u32,
    pens: ?[*]Pen = null,
    bytes_per_row: u32 = 0,
    /// A band's coverage, cleared between draws.
    acc: []f32,
    band_rows: u32,
    /// The points of the contour being drawn, and whether each is inside
    /// a curve.
    points: List(P) = .{},
    smooth: List(bool) = .{},
    /// A gradient's colours, made for every fill or stroke it paints; the
    /// room for them taken the first time.
    ramp: ?*gradient.Ramp = null,
    /// The dash being cut, and a closed contour's first.
    dash: List(P) = .{},
    dash_smooth: List(bool) = .{},
    dash_first: List(P) = .{},
    dash_first_smooth: List(bool) = .{},
    /// The layers pushed, the innermost last, and the pushes past the
    /// most, which hold nothing.
    layers: [vector.MAX_LAYERS]Layer = undefined,
    depth: u32 = 0,
    beyond: u32 = 0,
    /// Masks begun past the most layers: what is drawn until they end is
    /// not seen.
    muted: u32 = 0,
    /// The clips pushed, the innermost last, and the pushes past the
    /// most.
    clips: [vector.MAX_CLIPS]Clip = undefined,
    clip_depth: u32 = 0,
    clip_beyond: u32 = 0,

    /// A canvas `width` by `height`, its band cleared; null without the
    /// memory, or for a size of nothing.
    pub fn create(memory: Memory, width: u32, height: u32) ?*Canvas {
        if (width == 0 or height == 0 or width > 1 << 20 or height > 1 << 20) return null;
        const stride: usize = @as(usize, width) + 2;
        const rows: u32 = @intCast(@min(@max(band_floats / stride, 1), height));
        const acc = memory.alloc(f32, stride * rows) orelse return null;
        @memset(acc, 0);
        const canvas = memory.create(Canvas) orelse {
            memory.free(f32, acc);
            return null;
        };
        canvas.* = .{ .memory = memory, .width = width, .height = height, .acc = acc, .band_rows = rows };
        return canvas;
    }

    pub fn destroy(canvas: *Canvas) void {
        const memory = canvas.memory;
        while (canvas.depth > 0) {
            canvas.depth -= 1;
            if (canvas.layers[canvas.depth].pens) |pens| memory.free(Pen, pens);
        }
        while (canvas.clip_depth > 0) {
            canvas.clip_depth -= 1;
            if (canvas.clips[canvas.clip_depth].cover) |cover| memory.free(u8, cover);
        }
        memory.free(f32, canvas.acc);
        canvas.points.deinit(memory);
        canvas.smooth.deinit(memory);
        canvas.dash.deinit(memory);
        canvas.dash_smooth.deinit(memory);
        canvas.dash_first.deinit(memory);
        canvas.dash_first_smooth.deinit(memory);
        if (canvas.ramp) |ramp| memory.destroy(gradient.Ramp, ramp);
        memory.destroy(Canvas, canvas);
    }

    pub fn setPens(canvas: *Canvas, pens: ?[*]Pen, bytes_per_row: u32) void {
        canvas.pens = pens;
        canvas.bytes_per_row = if (bytes_per_row == 0) canvas.width * 4 else bytes_per_row;
    }

    /// The path filled through `matrix` in `paint`, by `rule`.
    pub fn fill(canvas: *Canvas, path: *const Path, matrix: Matrix, paint: *const vector.Paint, rule: u32) i32 {
        var result: i32 = if (path.failed) vector.VECTORERR_NOMEM else vector.VECTOR_OK;
        const target = canvas.drawTarget();
        if (target.pens == null) return result;
        const look = canvas.lookOf(paint, matrix, target.fade, &result) orelse return result;
        const span = canvas.rowsOf(path, matrix, 0) orelse return result;
        var top = span.first;
        while (top < span.end) : (top += canvas.band_rows) {
            var coverage = canvas.band(top);
            if (!flatten.contours(path, flatten.Flatten.fill(matrix), &canvas.points, &canvas.smooth, canvas.memory, &coverage, filled)) result = vector.VECTORERR_NOMEM;
            canvas.lay(&coverage, &look, rule == vector.RULE_EVENODD, target);
        }
        return result;
    }

    /// The path stroked in its own units, dashed when the stroke says so,
    /// then through `matrix`, in `paint`.
    pub fn stroke(canvas: *Canvas, path: *const Path, matrix: Matrix, paint: *const vector.Paint, how: *const vector.Stroke) i32 {
        var result: i32 = if (path.failed) vector.VECTORERR_NOMEM else vector.VECTOR_OK;
        const target = canvas.drawTarget();
        if (target.pens == null) return result;
        const pieces = stroke_.How.of(how);
        if (pieces.half * matrix.size() <= 0.01) return result;
        const look = canvas.lookOf(paint, matrix, target.fade, &result) orelse return result;
        const pattern = dash_.Pattern.of(how);
        // As far as a piece reaches past the path: a miter at its longest,
        // a square cap's corner, through the matrix at its most stretching.
        const reach = pieces.half * stretch(matrix) * @max(pieces.miter_limit, 1.5) + 1;
        const span = canvas.rowsOf(path, matrix, reach) orelse return result;
        var top = span.first;
        while (top < span.end) : (top += canvas.band_rows) {
            var coverage = canvas.band(top);
            var stroker = Stroker{ .sink = stroke_.Sink.of(&coverage, matrix), .how = pieces };
            if (pattern) |dashes| stroker.dasher = .{
                .pattern = dashes,
                .memory = canvas.memory,
                .dash = &canvas.dash,
                .dash_smooth = &canvas.dash_smooth,
                .first = &canvas.dash_first,
                .first_smooth = &canvas.dash_first_smooth,
            };
            if (!flatten.contours(path, flatten.Flatten.stroke(matrix), &canvas.points, &canvas.smooth, canvas.memory, &stroker, Stroker.emit)) result = vector.VECTORERR_NOMEM;
            if (stroker.dasher) |d| if (d.failed) {
                result = vector.VECTORERR_NOMEM;
            };
            canvas.lay(&coverage, &look, false, target);
        }
        return result;
    }

    /// What is drawn from now on goes onto a layer of its own until
    /// `popLayer`, which puts it down at `opacity`.
    pub fn pushLayer(canvas: *Canvas, opacity: f32) i32 {
        if (canvas.depth == vector.MAX_LAYERS) {
            canvas.beyond += 1;
            return vector.VECTORERR_DEPTH;
        }
        const pens = canvas.memory.alloc(Pen, @as(usize, canvas.width) * canvas.height);
        if (pens) |all| @memset(all, 0);
        canvas.layers[canvas.depth] = .{ .pens = pens, .opacity = if (opacity > 0) @min(opacity, 1) else 0, .mask = false };
        canvas.depth += 1;
        return if (pens == null) vector.VECTORERR_NOMEM else vector.VECTOR_OK;
    }

    /// The last layer pushed put down on what is under it, and given back.
    pub fn popLayer(canvas: *Canvas) void {
        if (canvas.beyond > 0) {
            canvas.beyond -= 1;
            return;
        }
        if (canvas.depth == 0) return;
        canvas.depth -= 1;
        canvas.dropClipsAbove(canvas.depth);
        const layer = &canvas.layers[canvas.depth];
        const own = layer.pens orelse return;
        defer canvas.memory.free(Pen, own);
        layer.pens = null;
        // A mask ended by a pop rather than `endMask` is no mask.
        if (layer.mask) return;
        if (layer.top >= layer.bottom) return;
        const under = canvas.targetAt(canvas.depth);
        if (under.pens == null) return;
        const opacity = layer.opacity * under.fade;
        if (under.layer) |below| below.mark(layer.top, layer.bottom, layer.left, layer.right);
        var through: [vector.MAX_LAYERS + 1][]const u8 = undefined;
        const clip_count = canvas.clipsFor(under.level, canvas.depth, &through);
        var y = layer.top;
        while (y < layer.bottom) : (y += 1) {
            const from = own[@as(usize, y) * canvas.width ..];
            const to = rowOf(under, y);
            const at = @as(usize, y) * canvas.width;
            var x = layer.left;
            while (x < layer.right) : (x += 1) {
                const pen = from[x];
                var a = @as(f32, @floatFromInt(pen >> 24)) / 255 * opacity;
                for (through[0..clip_count]) |clip| a *= @as(f32, @floatFromInt(clip[at + x])) * (1.0 / 255.0);
                if (a < 1.0 / 512.0) continue;
                const r: f32 = @floatFromInt((pen >> 16) & 0xFF);
                const g: f32 = @floatFromInt((pen >> 8) & 0xFF);
                const b: f32 = @floatFromInt(pen & 0xFF);
                to[x] = over(to[x], r, g, b, a);
            }
        }
    }

    /// What is drawn from now on shows only inside the path through
    /// `matrix`, by `rule`, and inside the clip it is in, until `popClip`.
    pub fn pushClip(canvas: *Canvas, path: *const Path, matrix: Matrix, rule: u32) i32 {
        const all = switch (canvas.newClip()) {
            .made => |cover| cover,
            .failed => |result| return result,
        };
        var result: i32 = if (path.failed) vector.VECTORERR_NOMEM else vector.VECTOR_OK;
        if (canvas.rowsOf(path, matrix, 0)) |span| {
            var top = span.first;
            while (top < span.end) : (top += canvas.band_rows) {
                var coverage = canvas.band(top);
                if (!flatten.contours(path, flatten.Flatten.fill(matrix), &canvas.points, &canvas.smooth, canvas.memory, &coverage, filled)) result = vector.VECTORERR_NOMEM;
                canvas.layCover(&coverage, rule == vector.RULE_EVENODD, all);
            }
        }
        canvas.combineWithBelow(all);
        return result;
    }

    /// The last clip or mask pushed taken off.
    pub fn popClip(canvas: *Canvas) void {
        if (canvas.clip_beyond > 0) {
            canvas.clip_beyond -= 1;
            return;
        }
        if (canvas.clip_depth == 0) return;
        canvas.clip_depth -= 1;
        if (canvas.clips[canvas.clip_depth].cover) |cover| canvas.memory.free(u8, cover);
    }

    /// What is drawn from now on, until `endMask`, makes a mask rather
    /// than being seen: a layer of its own, clear and not clipped.
    pub fn beginMask(canvas: *Canvas) i32 {
        if (canvas.depth == vector.MAX_LAYERS) {
            canvas.beyond += 1;
            canvas.muted += 1;
            return vector.VECTORERR_DEPTH;
        }
        const result = canvas.pushLayer(1);
        canvas.layers[canvas.depth - 1].mask = true;
        return result;
    }

    /// The drawing since `beginMask` made a mask (`MASK_*`) and pushed as
    /// a clip is, inside the clip under it; `popClip` takes it off.
    pub fn endMask(canvas: *Canvas, kind: u32) i32 {
        if (canvas.muted > 0) {
            canvas.muted -= 1;
            canvas.beyond -= 1;
            _ = canvas.newClipOf(null);
            return vector.VECTORERR_DEPTH;
        }
        // The layers pushed inside it and not popped put down on it: those
        // past the most first, which hold nothing - none can be under a
        // mask that is not.
        var mask_at = canvas.depth;
        while (mask_at > 0 and !canvas.layers[mask_at - 1].mask) mask_at -= 1;
        if (mask_at == 0) return vector.VECTORERR_DEPTH;
        canvas.beyond = 0;
        while (canvas.depth > mask_at) canvas.popLayer();
        canvas.depth -= 1;
        canvas.dropClipsAbove(canvas.depth);
        const layer = &canvas.layers[canvas.depth];
        const own = layer.pens;
        layer.pens = null;
        defer if (own) |pens| canvas.memory.free(Pen, pens);
        // Without the layer nothing was drawn on it: no mask, drawn whole.
        if (own == null) {
            _ = canvas.newClipOf(null);
            return vector.VECTORERR_NOMEM;
        }
        const all = switch (canvas.newClip()) {
            .made => |cover| cover,
            .failed => |result| return result,
        };
        const luminance = kind & 0xF == vector.MASK_LUMINANCE;
        const invert: u8 = if (kind & vector.MASK_INVERT != 0) 0xFF else 0;
        if (invert != 0) @memset(all, 0xFF);
        var y = layer.top;
        while (y < layer.bottom) : (y += 1) {
            const at = @as(usize, y) * canvas.width;
            var x = layer.left;
            while (x < layer.right) : (x += 1) {
                const pen = own.?[at + x];
                var value: f32 = @floatFromInt(pen >> 24);
                if (luminance) {
                    const r: f32 = @floatFromInt((pen >> 16) & 0xFF);
                    const g: f32 = @floatFromInt((pen >> 8) & 0xFF);
                    const b: f32 = @floatFromInt(pen & 0xFF);
                    value *= (0.2125 * r + 0.7154 * g + 0.0721 * b) / 255;
                }
                all[at + x] = byte(value) ^ invert;
            }
        }
        canvas.combineWithBelow(all);
        return vector.VECTOR_OK;
    }

    const NewClip = union(enum) { made: []u8, failed: i32 };

    /// A clip pushed on the layer drawn on now, cleared; what to answer
    /// when it holds nothing.
    fn newClip(canvas: *Canvas) NewClip {
        if (canvas.clip_depth == vector.MAX_CLIPS) {
            canvas.clip_beyond += 1;
            return .{ .failed = vector.VECTORERR_DEPTH };
        }
        const cover = canvas.memory.alloc(u8, @as(usize, canvas.width) * canvas.height);
        if (cover) |all| @memset(all, 0);
        if (!canvas.newClipOf(cover)) return .{ .failed = vector.VECTORERR_DEPTH };
        return if (cover) |all| .{ .made = all } else .{ .failed = vector.VECTORERR_NOMEM };
    }

    fn newClipOf(canvas: *Canvas, cover: ?[]u8) bool {
        if (canvas.clip_depth == vector.MAX_CLIPS) {
            if (cover) |all| canvas.memory.free(u8, all);
            canvas.clip_beyond += 1;
            return false;
        }
        canvas.clips[canvas.clip_depth] = .{ .cover = cover, .level = canvas.depth };
        canvas.clip_depth += 1;
        return true;
    }

    /// The newest clip made inside the one under it on its layer.
    fn combineWithBelow(canvas: *Canvas, all: []u8) void {
        const newest = canvas.clip_depth - 1;
        const under = canvas.clipAt(newest, canvas.clips[newest].level) orelse return;
        for (all, under) |*c, u| c.* = @intCast((@as(u32, c.*) * u + 127) / 255);
    }

    /// The clips pushed on layers since given back: what was clipped is
    /// drawn and gone.
    fn dropClipsAbove(canvas: *Canvas, level: u32) void {
        while (canvas.clip_depth > 0 and canvas.clips[canvas.clip_depth - 1].level > level) {
            canvas.clip_depth -= 1;
            if (canvas.clips[canvas.clip_depth].cover) |cover| canvas.memory.free(u8, cover);
        }
    }

    /// The innermost clip among the first `below` that holds something,
    /// pushed on layer `level`; null for none.
    fn clipAt(canvas: *const Canvas, below: u32, level: u32) ?[]const u8 {
        var i = below;
        while (i > 0) {
            i -= 1;
            const clip = canvas.clips[i];
            if (clip.level < level) return null;
            if (clip.level == level) if (clip.cover) |cover| return cover;
        }
        return null;
    }

    /// The clips what is drawn on layer `from` goes through, when drawing
    /// is at `depth`: the one on each layer from there up - more than one
    /// only where layers had no memory and drawing fell to the one under.
    fn clipsFor(canvas: *const Canvas, from: u32, depth: u32, into: *[vector.MAX_LAYERS + 1][]const u8) usize {
        var n: usize = 0;
        var level = from;
        while (level <= depth) : (level += 1) {
            if (canvas.clipAt(canvas.clip_depth, level)) |cover| {
                into[n] = cover;
                n += 1;
            }
        }
        return n;
    }

    /// What the band holds put into a clip, a byte a pixel, and the band
    /// cleared where it was.
    fn layCover(canvas: *Canvas, coverage: *Coverage, even_odd: bool, cover: []u8) void {
        if (!coverage.touched()) return coverage.forget();
        const stride_width = coverage.stride();
        var y = coverage.top;
        while (y < coverage.bottom) : (y += 1) {
            const row = coverage.row(y);
            const at = @as(usize, y) * canvas.width;
            var sum: f32 = 0;
            var x = coverage.left;
            while (x < stride_width) : (x += 1) {
                sum += row[x];
                row[x] = 0;
                if (x >= canvas.width) continue;
                var c = @abs(sum);
                if (even_odd) {
                    c -= 2 * @floor(c / 2);
                    if (c > 1) c = 2 - c;
                } else if (c > 1) c = 1;
                cover[at + x] = byte(c * 255);
            }
        }
        coverage.forget();
    }

    fn band(canvas: *Canvas, top: u32) Coverage {
        return .{
            .acc = canvas.acc.ptr,
            .width = canvas.width,
            .height = canvas.height,
            .band_top = top,
            .band_end = @min(top + canvas.band_rows, canvas.height),
        };
    }

    const Span = struct { first: u32, end: u32 };

    /// The rows the path's points reach through `matrix`, `reach` pixels
    /// further each way, on the canvas; null for none. A curve keeps
    /// within its control points, so they are enough.
    fn rowsOf(canvas: *const Canvas, path: *const Path, matrix: Matrix, reach: f32) ?Span {
        var low: f32 = std.math.inf(f32);
        var high: f32 = -std.math.inf(f32);
        for (path.points.items()) |p| {
            const y = matrix.apply(p).y;
            if (y != y) continue;
            low = @min(low, y);
            high = @max(high, y);
        }
        if (!(low <= high)) return null;
        const rows: f32 = @floatFromInt(canvas.height);
        const first = @floor(@min(@max(low - reach, 0), rows));
        const end = @ceil(@min(@max(high + reach + 1, 0), rows));
        if (first >= end) return null;
        return .{ .first = @intFromFloat(first), .end = @intFromFloat(end) };
    }

    /// What a paint comes to, a gradient's ramp made; null when it paints
    /// nothing, or there was not the memory for the ramp.
    fn lookOf(canvas: *Canvas, paint: *const vector.Paint, matrix: Matrix, fade: f32, result: *i32) ?Look {
        const kind = gradient.kindOf(paint, matrix);
        switch (kind) {
            .none => return null,
            .solid => {},
            .gradient => {
                const ramp = canvas.ramp orelse made: {
                    const made = canvas.memory.create(gradient.Ramp) orelse {
                        result.* = vector.VECTORERR_NOMEM;
                        return null;
                    };
                    canvas.ramp = made;
                    break :made made;
                };
                gradient.fillRamp(ramp, paint.stops.?[0..paint.stop_count]);
            },
        }
        return .{ .kind = kind, .opacity = paint.opacity * fade };
    }

    /// What the band holds laid onto the pens, and the band cleared where
    /// it was.
    fn lay(canvas: *Canvas, coverage: *Coverage, look: *const Look, even_odd: bool, target: Target) void {
        if (!coverage.touched()) return coverage.forget();
        if (target.layer) |layer| layer.mark(coverage.top, coverage.bottom, coverage.left, canvas.width);
        const stride_width = coverage.stride();
        var red: f32 = 0;
        var green: f32 = 0;
        var blue: f32 = 0;
        var opacity: f32 = undefined;
        var sampler: ?*const gradient.Sampler = null;
        switch (look.kind) {
            .solid => |colour| {
                red = colour.r * 255;
                green = colour.g * 255;
                blue = colour.b * 255;
                opacity = @min(@max(look.opacity * colour.a, 0), 1);
            },
            .gradient => |*s| {
                sampler = s;
                opacity = @min(@max(look.opacity, 0), 1);
            },
            .none => unreachable,
        }
        const ramp = canvas.ramp;
        var through: [vector.MAX_LAYERS + 1][]const u8 = undefined;
        const clip_count = canvas.clipsFor(target.level, canvas.depth, &through);
        var y = coverage.top;
        while (y < coverage.bottom) : (y += 1) {
            const row = coverage.row(y);
            const pens = rowOf(target, y);
            const at = @as(usize, y) * canvas.width;
            var sum: f32 = 0;
            var x = coverage.left;
            while (x < stride_width) : (x += 1) {
                sum += row[x];
                row[x] = 0;
                if (x >= canvas.width) continue;
                var cover = @abs(sum);
                if (even_odd) {
                    cover -= 2 * @floor(cover / 2);
                    if (cover > 1) cover = 2 - cover;
                } else if (cover > 1) cover = 1;
                var a = cover * opacity;
                for (through[0..clip_count]) |clip| a *= @as(f32, @floatFromInt(clip[at + x])) * (1.0 / 255.0);
                if (a < 1.0 / 512.0) continue;
                if (sampler) |s| {
                    const entry = ramp.?[s.index(x, y) orelse continue];
                    const shown = a * entry.a;
                    if (shown < 1.0 / 512.0) continue;
                    pens[x] = over(pens[x], entry.r, entry.g, entry.b, shown);
                } else pens[x] = over(pens[x], red, green, blue, a);
            }
        }
        coverage.forget();
    }

    /// Where drawing goes now.
    fn drawTarget(canvas: *Canvas) Target {
        return canvas.targetAt(canvas.depth);
    }

    /// Where drawing went with `depth` layers pushed: the innermost of
    /// them that has pens, the opacities of those inside it that have
    /// none going into the paint; or the caller's pens.
    /// A mask with no memory, or one begun past the most layers, is
    /// drawn on nowhere: what makes it is not to be seen.
    fn targetAt(canvas: *Canvas, depth: u32) Target {
        if (canvas.muted > 0) return .{ .pens = null, .bytes_per_row = 0, .fade = 0, .layer = null, .level = depth };
        var fade: f32 = 1;
        var i = depth;
        while (i > 0) {
            i -= 1;
            const layer = &canvas.layers[i];
            if (layer.pens) |pens| return .{ .pens = pens.ptr, .bytes_per_row = canvas.width * 4, .fade = fade, .layer = layer, .level = i + 1 };
            if (layer.mask) return .{ .pens = null, .bytes_per_row = 0, .fade = 0, .layer = null, .level = i + 1 };
            fade *= layer.opacity;
        }
        return .{ .pens = canvas.pens, .bytes_per_row = canvas.bytes_per_row, .fade = fade, .layer = null, .level = 0 };
    }
};

/// A paint as it is laid down: what it is, and its opacity with the
/// layers' that go into it.
const Look = struct {
    kind: gradient.Kind,
    opacity: f32,
};

const Layer = struct {
    /// Its pens, the canvas's size; null when there was not the memory.
    pens: ?[]Pen,
    opacity: f32,
    /// Drawn on to make a mask (`beginMask`), never put down.
    mask: bool = false,
    /// The rows and columns drawn on.
    top: u32 = 0xFFFF_FFFF,
    bottom: u32 = 0,
    left: u32 = 0xFFFF_FFFF,
    right: u32 = 0,

    fn mark(layer: *Layer, top: u32, bottom: u32, left: u32, right: u32) void {
        layer.top = @min(layer.top, top);
        layer.bottom = @max(layer.bottom, bottom);
        layer.left = @min(layer.left, left);
        layer.right = @max(layer.right, right);
    }
};

/// Pens drawn on, and how much of a paint goes onto them.
const Target = struct {
    pens: ?[*]Pen,
    bytes_per_row: u32,
    fade: f32,
    /// The layer they are, to mark what is drawn on it.
    layer: ?*Layer,
    /// How many layers down they are: 0 for the caller's pens, 1 for the
    /// first layer's - which clips they are drawn through.
    level: u32,
};

/// A clip or a mask: how much shows of what is drawn, a byte a pixel of
/// the canvas, and the layer it goes with.
const Clip = struct {
    /// Null when there was not the memory: it clips nothing.
    cover: ?[]u8,
    /// How many layers were pushed when it was.
    level: u32,
};

fn rowOf(target: Target, y: u32) [*]Pen {
    return @ptrCast(@alignCast(@as([*]u8, @ptrCast(target.pens.?)) + @as(usize, y) * target.bytes_per_row));
}

/// How far the matrix stretches a length at most - its largest singular
/// value, or a little over: the root of its four scales' squares.
fn stretch(m: Matrix) f32 {
    return @sqrt(m.a * m.a + m.b * m.b + m.c * m.c + m.d * m.d);
}

fn filled(coverage: *Coverage, points: []const P, smooth: []const bool, closed: bool) void {
    _ = smooth;
    _ = closed;
    coverage.polygon(points);
}

const Stroker = struct {
    sink: stroke_.Sink,
    how: stroke_.How,
    dasher: ?dash_.Dasher = null,

    fn emit(stroker: *Stroker, points: []const P, smooth: []const bool, closed: bool) void {
        if (stroker.dasher) |*dasher| return dasher.contour(points, smooth, closed, stroker, piece);
        piece(stroker, points, smooth, closed);
    }

    fn piece(stroker: *Stroker, points: []const P, smooth: []const bool, closed: bool) void {
        stroke_.contour(&stroker.sink, points, smooth, closed, stroker.how);
    }
};

/// A colour at `a` laid over a pen.
pub fn over(pen: Pen, red: f32, green: f32, blue: f32, a: f32) Pen {
    const below_alpha = @as(f32, @floatFromInt(pen >> 24)) / 255;
    const out_alpha = a + below_alpha * (1 - a);
    if (out_alpha <= 0) return 0;
    const below = below_alpha * (1 - a);
    const r = (red * a + @as(f32, @floatFromInt((pen >> 16) & 0xFF)) * below) / out_alpha;
    const g = (green * a + @as(f32, @floatFromInt((pen >> 8) & 0xFF)) * below) / out_alpha;
    const b = (blue * a + @as(f32, @floatFromInt(pen & 0xFF)) * below) / out_alpha;
    return @as(Pen, byte(out_alpha * 255)) << 24 | @as(Pen, byte(r)) << 16 | @as(Pen, byte(g)) << 8 | byte(b);
}

fn byte(value: f32) u8 {
    return @intFromFloat(@min(@max(value + 0.5, 0), 255));
}

const std = @import("std");

// --- tests: lottie.datatype's, moved with the code --------------------------

const testing = std.testing;
const test_memory = memory_.test_memory;

fn solid(r: f32, g: f32, b: f32) vector.Paint {
    return .{ .colour = .{ .r = r, .g = g, .b = b } };
}

test "a square half off the canvas is filled where it is on it" {
    const canvas = Canvas.create(test_memory, 8, 8).?;
    defer canvas.destroy();
    var pens: [64]Pen = @splat(0);
    canvas.setPens(&pens, 32);
    const path = Path.create(test_memory).?;
    defer path.destroy();
    path.moveTo(.{ .x = -4, .y = 2 });
    path.lineTo(.{ .x = 4, .y = 2 });
    path.lineTo(.{ .x = 4, .y = 6 });
    path.lineTo(.{ .x = -4, .y = 6 });
    path.close();
    try testing.expectEqual(vector.VECTOR_OK, canvas.fill(path, .{}, &solid(1, 0, 0), vector.RULE_NONZERO));
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[3 * 8 + 0]);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[5 * 8 + 3]);
    try testing.expectEqual(@as(Pen, 0), pens[3 * 8 + 4]);
    try testing.expectEqual(@as(Pen, 0), pens[1 * 8 + 0]);
    for (canvas.acc) |left| try testing.expectEqual(@as(f32, 0), left);
}

test "a hole by the even-odd rule, none by non-zero" {
    const canvas = Canvas.create(test_memory, 10, 10).?;
    defer canvas.destroy();
    var pens: [100]Pen = @splat(0);
    canvas.setPens(&pens, 40);
    const path = Path.create(test_memory).?;
    defer path.destroy();
    for ([_][4]P{
        .{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 } },
        .{ .{ .x = 3, .y = 3 }, .{ .x = 7, .y = 3 }, .{ .x = 7, .y = 7 }, .{ .x = 3, .y = 7 } },
    }) |square| {
        path.moveTo(square[0]);
        for (square[1..]) |p| path.lineTo(p);
        path.close();
    }
    _ = canvas.fill(path, .{}, &solid(0, 0, 1), vector.RULE_EVENODD);
    try testing.expectEqual(@as(Pen, 0), pens[5 * 10 + 5]);
    try testing.expectEqual(@as(Pen, 0xFF0000FF), pens[1 * 10 + 1]);
    _ = canvas.fill(path, .{}, &solid(0, 1, 0), vector.RULE_NONZERO);
    try testing.expectEqual(@as(Pen, 0xFF00FF00), pens[5 * 10 + 5]);
}

test "a stroke covers its width" {
    const canvas = Canvas.create(test_memory, 20, 20).?;
    defer canvas.destroy();
    var pens: [400]Pen = @splat(0);
    canvas.setPens(&pens, 80);
    const path = Path.create(test_memory).?;
    defer path.destroy();
    path.moveTo(.{ .x = 2, .y = 10 });
    path.lineTo(.{ .x = 10, .y = 10 });
    path.lineTo(.{ .x = 10, .y = 18 });
    const how = vector.Stroke{ .width = 4, .join = vector.JOIN_MITER, .cap = vector.CAP_SQUARE };
    _ = canvas.stroke(path, .{}, &solid(1, 1, 1), &how);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[9 * 20 + 5]);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[10 * 20 + 1]);
    // The miter's outer corner.
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[8 * 20 + 11]);
    try testing.expectEqual(@as(Pen, 0), pens[5 * 20 + 5]);
    try testing.expectEqual(@as(Pen, 0), pens[14 * 20 + 5]);
}

// --- tests: what the library adds ----------------------------------------------

test "a canvas taller than a band draws what one band would" {
    // 4094 pixels wide: a band of 32 rows; 100 rows are four bands.
    const wide: u32 = band_floats / 32 - 2;
    const canvas = Canvas.create(test_memory, wide, 100).?;
    defer canvas.destroy();
    try testing.expectEqual(@as(u32, 32), canvas.band_rows);
    const pens = test_memory.alloc(Pen, @as(usize, wide) * 100).?;
    defer test_memory.free(Pen, pens);
    @memset(pens, 0);
    canvas.setPens(pens.ptr, wide * 4);
    const path = Path.create(test_memory).?;
    defer path.destroy();
    path.moveTo(.{ .x = 3.25, .y = 1.5 });
    path.cubicTo(.{ .x = 90, .y = 10 }, .{ .x = 10, .y = 90 }, .{ .x = 80.5, .y = 97.25 });
    path.lineTo(.{ .x = 1, .y = 60 });
    path.close();
    _ = canvas.fill(path, .{}, &solid(0, 0.5, 1), vector.RULE_NONZERO);
    // The same on a canvas of one band, 90 wide.
    const small = Canvas.create(test_memory, 90, 100).?;
    defer small.destroy();
    try testing.expectEqual(@as(u32, 100), small.band_rows);
    var own: [90 * 100]Pen = @splat(0);
    small.setPens(&own, 90 * 4);
    _ = small.fill(path, .{}, &solid(0, 0.5, 1), vector.RULE_NONZERO);
    var painted: u32 = 0;
    for (0..100) |y| for (0..90) |x| {
        try testing.expectEqual(own[y * 90 + x], pens[y * wide + x]);
        if (own[y * 90 + x] != 0) painted += 1;
    };
    try testing.expect(painted > 2000);
    for (canvas.acc) |left| try testing.expectEqual(@as(f32, 0), left);
}

test "a path through a matrix: scaled, moved, a stroke stretched with it" {
    const canvas = Canvas.create(test_memory, 40, 40).?;
    defer canvas.destroy();
    var pens: [1600]Pen = @splat(0);
    canvas.setPens(&pens, 160);
    const path = Path.create(test_memory).?;
    defer path.destroy();
    // A unit square, four times as large, moved 10 right and 10 down.
    path.moveTo(.{ .x = 0, .y = 0 });
    path.lineTo(.{ .x = 1, .y = 0 });
    path.lineTo(.{ .x = 1, .y = 1 });
    path.lineTo(.{ .x = 0, .y = 1 });
    path.close();
    const m = Matrix.translate(10, 10).then(Matrix.scale(4, 4));
    _ = canvas.fill(path, m, &solid(1, 0, 0), vector.RULE_NONZERO);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[11 * 40 + 11]);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[13 * 40 + 13]);
    try testing.expectEqual(@as(Pen, 0), pens[14 * 40 + 14]);
    // A line down, stroked half a unit wide and drawn eight times as wide
    // as it is tall: the stroke is 4 pixels from side to side.
    @memset(&pens, 0);
    path.clear();
    path.moveTo(.{ .x = 1, .y = 2 });
    path.lineTo(.{ .x = 1, .y = 4 });
    _ = canvas.stroke(path, Matrix.scale(8, 1), &solid(1, 1, 1), &.{ .width = 0.5 });
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[3 * 40 + 6]);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[3 * 40 + 9]);
    try testing.expectEqual(@as(Pen, 0), pens[3 * 40 + 11]);
    try testing.expectEqual(@as(Pen, 0), pens[3 * 40 + 4]);
}

// --- tests: since 1.1 ------------------------------------------------------------

fn addSquare(path: *Path, x: f32, y: f32, size: f32) void {
    path.moveTo(.{ .x = x, .y = y });
    path.lineTo(.{ .x = x + size, .y = y });
    path.lineTo(.{ .x = x + size, .y = y + size });
    path.lineTo(.{ .x = x, .y = y + size });
    path.close();
}

test "a linear gradient from red at its start to blue at its end, through the matrix" {
    const canvas = Canvas.create(test_memory, 20, 10).?;
    defer canvas.destroy();
    var pens: [200]Pen = @splat(0);
    canvas.setPens(&pens, 0);
    const path = Path.create(test_memory).?;
    defer path.destroy();
    addSquare(path, 0, 0, 1);
    const stops = [_]vector.Stop{ .{ .colour = .{ .r = 1 } }, .{ .offset = 1, .colour = .{ .b = 1 } } };
    const paint = vector.Paint{ .kind = vector.PAINT_LINEAR, .stops = &stops, .stop_count = 2, .x1 = 0, .x2 = 1 };
    // The unit square drawn 20 by 10: the gradient goes across with it.
    try testing.expectEqual(vector.VECTOR_OK, canvas.fill(path, Matrix.scale(20, 10), &paint, vector.RULE_NONZERO));
    const left = pens[5 * 20 + 0];
    const right = pens[5 * 20 + 19];
    try testing.expect((left >> 16 & 0xFF) > 240 and (left & 0xFF) < 15);
    try testing.expect((right & 0xFF) > 240 and (right >> 16 & 0xFF) < 15);
    try testing.expectEqual(@as(Pen, 0xFF), pens[5 * 20 + 10] >> 24);
    for (canvas.acc) |rest| try testing.expectEqual(@as(f32, 0), rest);
}

test "a dashed stroke leaves its gaps" {
    const canvas = Canvas.create(test_memory, 20, 10).?;
    defer canvas.destroy();
    var pens: [200]Pen = @splat(0);
    canvas.setPens(&pens, 0);
    const path = Path.create(test_memory).?;
    defer path.destroy();
    path.moveTo(.{ .x = 0, .y = 5 });
    path.lineTo(.{ .x = 20, .y = 5 });
    const dashes = [_]f32{ 4, 4 };
    try testing.expectEqual(vector.VECTOR_OK, canvas.stroke(path, .{}, &solid(1, 1, 1), &.{ .width = 2, .dashes = &dashes, .dash_count = 2 }));
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[4 * 20 + 2]);
    try testing.expectEqual(@as(Pen, 0), pens[4 * 20 + 6]);
    try testing.expectEqual(@as(Pen, 0xFFFFFFFF), pens[5 * 20 + 9]);
    try testing.expectEqual(@as(Pen, 0), pens[5 * 20 + 13]);
}

/// Test memory that refuses blocks of one size: a layer's.
var refused_size: usize = 0;

fn refusingAlloc(context: ?*anyopaque, bytes: usize) ?[*]align(8) u8 {
    if (bytes == refused_size) return null;
    return test_memory.allocFn(context, bytes);
}

const refusing = Memory{ .allocFn = refusingAlloc, .freeFn = test_memory.freeFn };

test "shapes on a layer overlap at its opacity once; without the memory for it, each at it" {
    for ([_]bool{ true, false }) |room| {
        refused_size = if (room) 0 else 10 * 10 * @sizeOf(Pen);
        const canvas = Canvas.create(refusing, 10, 10).?;
        defer canvas.destroy();
        var pens: [100]Pen = @splat(0);
        canvas.setPens(&pens, 0);
        const pushed = canvas.pushLayer(0.5);
        try testing.expectEqual(if (room) vector.VECTOR_OK else vector.VECTORERR_NOMEM, pushed);
        // The squares as two fills, so they overlap as two shapes.
        const first = Path.create(refusing).?;
        defer first.destroy();
        addSquare(first, 0, 0, 6);
        const second = Path.create(refusing).?;
        defer second.destroy();
        addSquare(second, 4, 4, 6);
        _ = canvas.fill(first, .{}, &solid(1, 0, 0), vector.RULE_NONZERO);
        _ = canvas.fill(second, .{}, &solid(1, 0, 0), vector.RULE_NONZERO);
        canvas.popLayer();
        try testing.expectEqual(@as(Pen, 0x80FF0000), pens[1 * 10 + 1]);
        const overlap = pens[5 * 10 + 5];
        // Without the layer the second half covers the first: three quarters.
        if (room) try testing.expectEqual(@as(Pen, 0x80FF0000), overlap) else try testing.expect(overlap >> 24 >= 0xBF and overlap & 0xFFFFFF == 0xFF0000);
        try testing.expectEqual(@as(Pen, 0), pens[1 * 10 + 8]);
    }
    refused_size = 0;
}

test "layers nested past the most hold nothing, and pops still match pushes" {
    const canvas = Canvas.create(test_memory, 4, 4).?;
    defer canvas.destroy();
    var pens: [16]Pen = @splat(0);
    canvas.setPens(&pens, 0);
    for (0..vector.MAX_LAYERS) |_| try testing.expectEqual(vector.VECTOR_OK, canvas.pushLayer(1));
    try testing.expectEqual(vector.VECTORERR_DEPTH, canvas.pushLayer(0.5));
    const path = Path.create(test_memory).?;
    defer path.destroy();
    addSquare(path, 0, 0, 4);
    _ = canvas.fill(path, .{}, &solid(0, 1, 0), vector.RULE_NONZERO);
    try testing.expectEqual(@as(Pen, 0), pens[5]);
    // The one past the most, then all the rest: down on the pens.
    canvas.popLayer();
    try testing.expectEqual(@as(u32, vector.MAX_LAYERS), canvas.depth);
    for (0..vector.MAX_LAYERS) |_| canvas.popLayer();
    try testing.expectEqual(@as(Pen, 0xFF00FF00), pens[5]);
    // One more pop than pushes does nothing; one left pushed is given
    // back with the canvas.
    canvas.popLayer();
    _ = canvas.pushLayer(0.3);
}

// --- tests: since 1.3 ------------------------------------------------------------

test "a clip: what is drawn shows inside it, inside the one it is in, and not after it is popped" {
    const canvas = Canvas.create(test_memory, 10, 10).?;
    defer canvas.destroy();
    var pens: [100]Pen = @splat(0);
    canvas.setPens(&pens, 0);
    const all = Path.create(test_memory).?;
    defer all.destroy();
    addSquare(all, 0, 0, 10);
    const left = Path.create(test_memory).?;
    defer left.destroy();
    addSquare(left, 0, 0, 6);
    const lower = Path.create(test_memory).?;
    defer lower.destroy();
    addSquare(lower, 4, 4, 6);
    try testing.expectEqual(vector.VECTOR_OK, canvas.pushClip(left, .{}, vector.RULE_NONZERO));
    try testing.expectEqual(vector.VECTOR_OK, canvas.pushClip(lower, .{}, vector.RULE_NONZERO));
    _ = canvas.fill(all, .{}, &solid(1, 0, 0), vector.RULE_NONZERO);
    // Only where the two meet.
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[5 * 10 + 5]);
    try testing.expectEqual(@as(Pen, 0), pens[1 * 10 + 1]);
    try testing.expectEqual(@as(Pen, 0), pens[8 * 10 + 8]);
    canvas.popClip();
    _ = canvas.fill(all, .{}, &solid(0, 0, 1), vector.RULE_NONZERO);
    try testing.expectEqual(@as(Pen, 0xFF0000FF), pens[1 * 10 + 1]);
    try testing.expectEqual(@as(Pen, 0), pens[8 * 10 + 8]);
    canvas.popClip();
    try testing.expectEqual(@as(u32, 0), canvas.clip_depth);
    // Even-odd: a square inside a square is a hole in the clip.
    @memset(&pens, 0);
    const ring = Path.create(test_memory).?;
    defer ring.destroy();
    addSquare(ring, 0, 0, 10);
    addSquare(ring, 3, 3, 4);
    _ = canvas.pushClip(ring, .{}, vector.RULE_EVENODD);
    _ = canvas.fill(all, .{}, &solid(0, 1, 0), vector.RULE_NONZERO);
    canvas.popClip();
    try testing.expectEqual(@as(Pen, 0xFF00FF00), pens[1 * 10 + 1]);
    try testing.expectEqual(@as(Pen, 0), pens[5 * 10 + 5]);
}

test "a clip under a layer: the layer's shapes go through it once, at its opacity; one pushed on a layer goes with it" {
    const canvas = Canvas.create(test_memory, 10, 10).?;
    defer canvas.destroy();
    var pens: [100]Pen = @splat(0);
    canvas.setPens(&pens, 0);
    const left = Path.create(test_memory).?;
    defer left.destroy();
    addSquare(left, 0, 0, 5);
    const first = Path.create(test_memory).?;
    defer first.destroy();
    addSquare(first, 0, 0, 7);
    const second = Path.create(test_memory).?;
    defer second.destroy();
    addSquare(second, 3, 3, 7);
    _ = canvas.pushClip(left, Matrix.scale(1, 2), vector.RULE_NONZERO);
    _ = canvas.pushLayer(0.5);
    _ = canvas.fill(first, .{}, &solid(1, 0, 0), vector.RULE_NONZERO);
    _ = canvas.fill(second, .{}, &solid(1, 0, 0), vector.RULE_NONZERO);
    canvas.popLayer();
    canvas.popClip();
    try testing.expectEqual(@as(Pen, 0x80FF0000), pens[4 * 10 + 4]);
    try testing.expectEqual(@as(Pen, 0x80FF0000), pens[8 * 10 + 4]);
    try testing.expectEqual(@as(Pen, 0), pens[4 * 10 + 6]);
    // A clip pushed on a layer and not popped: popped with the layer.
    @memset(&pens, 0);
    _ = canvas.pushLayer(1);
    _ = canvas.pushClip(left, .{}, vector.RULE_NONZERO);
    canvas.popLayer();
    try testing.expectEqual(@as(u32, 0), canvas.clip_depth);
    _ = canvas.fill(first, .{}, &solid(1, 0, 0), vector.RULE_NONZERO);
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[6 * 10 + 6]);
}

test "masks: by luminance, by coverage, the other way round, inside a clip, and one with nothing drawn" {
    const canvas = Canvas.create(test_memory, 10, 10).?;
    defer canvas.destroy();
    var pens: [100]Pen = @splat(0);
    canvas.setPens(&pens, 0);
    const all = Path.create(test_memory).?;
    defer all.destroy();
    addSquare(all, 0, 0, 10);
    const left = Path.create(test_memory).?;
    defer left.destroy();
    addSquare(left, 0, 0, 5);
    const right = Path.create(test_memory).?;
    defer right.destroy();
    addSquare(right, 5, 0, 5);
    // White on the left, grey on the right: all of it, half of it.
    try testing.expectEqual(vector.VECTOR_OK, canvas.beginMask());
    _ = canvas.fill(left, Matrix.scale(1, 2), &solid(1, 1, 1), vector.RULE_NONZERO);
    _ = canvas.fill(right, Matrix.scale(1, 2), &solid(128.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0), vector.RULE_NONZERO);
    // Nothing of the mask is seen.
    try testing.expectEqual(@as(Pen, 0), pens[5 * 10 + 2]);
    try testing.expectEqual(vector.VECTOR_OK, canvas.endMask(vector.MASK_LUMINANCE));
    _ = canvas.fill(all, .{}, &solid(0, 0, 1), vector.RULE_NONZERO);
    canvas.popClip();
    try testing.expectEqual(@as(Pen, 0xFF0000FF), pens[5 * 10 + 2]);
    try testing.expectEqual(@as(Pen, 0x800000FF), pens[5 * 10 + 7]);
    // By coverage, the grey is all of it; the other way round, none, and
    // the rest of the canvas all.
    for ([_]u32{ vector.MASK_ALPHA, vector.MASK_ALPHA | vector.MASK_INVERT }) |kind| {
        @memset(&pens, 0);
        _ = canvas.beginMask();
        _ = canvas.fill(right, .{}, &solid(0.5, 0.5, 0.5), vector.RULE_NONZERO);
        try testing.expectEqual(vector.VECTOR_OK, canvas.endMask(kind));
        _ = canvas.fill(all, .{}, &solid(0, 1, 0), vector.RULE_NONZERO);
        canvas.popClip();
        const inverted = kind & vector.MASK_INVERT != 0;
        try testing.expectEqual(@as(Pen, if (inverted) 0 else 0xFF00FF00), pens[2 * 10 + 7]);
        try testing.expectEqual(@as(Pen, if (inverted) 0xFF00FF00 else 0), pens[2 * 10 + 2]);
        try testing.expectEqual(@as(Pen, if (inverted) 0xFF00FF00 else 0), pens[7 * 10 + 7]);
    }
    // A mask inside a clip, drawn without it, made inside it.
    @memset(&pens, 0);
    _ = canvas.pushClip(left, Matrix.scale(2, 1), vector.RULE_NONZERO);
    _ = canvas.beginMask();
    _ = canvas.fill(all, .{}, &solid(1, 1, 1), vector.RULE_NONZERO);
    try testing.expectEqual(vector.VECTOR_OK, canvas.endMask(vector.MASK_LUMINANCE));
    _ = canvas.fill(all, .{}, &solid(1, 0, 0), vector.RULE_NONZERO);
    canvas.popClip();
    canvas.popClip();
    try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[2 * 10 + 2]);
    try testing.expectEqual(@as(Pen, 0), pens[7 * 10 + 2]);
    // Nothing drawn on a mask: nothing shows through it.
    @memset(&pens, 0);
    _ = canvas.beginMask();
    _ = canvas.endMask(vector.MASK_LUMINANCE);
    _ = canvas.fill(all, .{}, &solid(1, 0, 0), vector.RULE_NONZERO);
    canvas.popClip();
    try testing.expectEqual(@as(Pen, 0), pens[5 * 10 + 5]);
    // No mask begun.
    try testing.expectEqual(vector.VECTORERR_DEPTH, canvas.endMask(vector.MASK_ALPHA));
    try testing.expectEqual(@as(u32, 0), canvas.clip_depth);
    try testing.expectEqual(@as(u32, 0), canvas.depth);
}

test "a group on a layer goes through a mask whole; a layer left pushed in a mask is put down on it" {
    const canvas = Canvas.create(test_memory, 10, 10).?;
    defer canvas.destroy();
    var pens: [100]Pen = @splat(0);
    canvas.setPens(&pens, 0);
    const all = Path.create(test_memory).?;
    defer all.destroy();
    addSquare(all, 0, 0, 10);
    const left = Path.create(test_memory).?;
    defer left.destroy();
    addSquare(left, 0, 0, 5);
    _ = canvas.beginMask();
    _ = canvas.pushLayer(1);
    _ = canvas.fill(left, Matrix.scale(1, 2), &solid(1, 1, 1), vector.RULE_NONZERO);
    try testing.expectEqual(vector.VECTOR_OK, canvas.endMask(vector.MASK_LUMINANCE));
    try testing.expectEqual(@as(u32, 0), canvas.depth);
    _ = canvas.pushLayer(0.5);
    _ = canvas.fill(all, .{}, &solid(1, 0, 0), vector.RULE_NONZERO);
    _ = canvas.fill(all, .{}, &solid(1, 0, 0), vector.RULE_NONZERO);
    canvas.popLayer();
    canvas.popClip();
    try testing.expectEqual(@as(Pen, 0x80FF0000), pens[5 * 10 + 2]);
    try testing.expectEqual(@as(Pen, 0), pens[5 * 10 + 7]);
}

test "a clip or a mask without the memory: drawn as if it were not there, pops still matching" {
    for ([_]usize{ 10 * 10, 10 * 10 * @sizeOf(Pen) }) |size| {
        refused_size = size;
        const canvas = Canvas.create(refusing, 10, 10).?;
        defer canvas.destroy();
        var pens: [100]Pen = @splat(0);
        canvas.setPens(&pens, 0);
        const all = Path.create(test_memory).?;
        defer all.destroy();
        addSquare(all, 0, 0, 10);
        const left = Path.create(test_memory).?;
        defer left.destroy();
        addSquare(left, 0, 0, 5);
        if (size == 10 * 10) {
            try testing.expectEqual(vector.VECTORERR_NOMEM, canvas.pushClip(left, .{}, vector.RULE_NONZERO));
        } else {
            // No layer for the mask: what is drawn on it is not seen.
            try testing.expectEqual(vector.VECTORERR_NOMEM, canvas.beginMask());
            _ = canvas.fill(left, .{}, &solid(1, 1, 1), vector.RULE_NONZERO);
            try testing.expectEqual(@as(Pen, 0), pens[1 * 10 + 1]);
            try testing.expectEqual(vector.VECTORERR_NOMEM, canvas.endMask(vector.MASK_LUMINANCE));
        }
        try testing.expectEqual(@as(u32, 1), canvas.clip_depth);
        _ = canvas.fill(all, .{}, &solid(1, 0, 0), vector.RULE_NONZERO);
        canvas.popClip();
        try testing.expectEqual(@as(Pen, 0xFFFF0000), pens[8 * 10 + 8]);
        try testing.expectEqual(@as(u32, 0), canvas.clip_depth);
    }
    refused_size = 0;
    // Past the most clips: nothing more is clipped; pops still match.
    const canvas = Canvas.create(test_memory, 4, 4).?;
    defer canvas.destroy();
    const path = Path.create(test_memory).?;
    defer path.destroy();
    addSquare(path, 0, 0, 4);
    for (0..vector.MAX_CLIPS) |_| try testing.expectEqual(vector.VECTOR_OK, canvas.pushClip(path, .{}, vector.RULE_NONZERO));
    try testing.expectEqual(vector.VECTORERR_DEPTH, canvas.pushClip(path, .{}, vector.RULE_NONZERO));
    _ = canvas.beginMask();
    try testing.expectEqual(vector.VECTORERR_DEPTH, canvas.endMask(vector.MASK_ALPHA));
    canvas.popClip();
    canvas.popClip();
    try testing.expectEqual(@as(u32, vector.MAX_CLIPS), canvas.clip_depth);
    // The rest left pushed, given back with the canvas.
}
