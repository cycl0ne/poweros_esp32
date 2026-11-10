// SPDX-License-Identifier: MIT
//! An SVG document drawn through vector.library.
//!
//! The tree is walked in the order of the file, each element's style
//! worked out from its parent's: the presentation attributes first, then
//! the rules of the file's `style` elements that are for it (`css.zig`,
//! since 1.2), then the `style` attribute's declarations over them, the
//! inherited properties carried down and the others - `opacity`,
//! `display`, `filter`, `clip-path`, `mask` - not. A shape is built into the one path, filled and then
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
//! **Clips and masks** (since 1.2) are vector.library's. A `clipPath`
//! of one shape is that shape's clip (`PushClip`); one of more, or whose
//! shapes are clipped themselves, is drawn as a mask of their coverage,
//! each filled white by its `clip-rule` (`BeginMask`, `EndMask`). A
//! `mask` is drawn as a group is, inside its region, and its luminance -
//! or its coverage, for `mask-type: alpha` - is the mask. Either is in
//! the units of the element it is on, or its box (`clipPathUnits`,
//! `maskUnits`, `maskContentUnits`): the box of what it draws, not of
//! its strokes. A group under a mask is drawn on a layer of its own, so
//! it goes through it whole. A nested `svg`, and a `symbol`, clip what
//! they draw to their viewport unless `overflow` says otherwise. A clip
//! or a mask that is not there clips nothing; one with nothing in it
//! lets nothing through.
//!
//! **`use`** (since 1.2) draws the element it names as a group's one
//! child, moved by its `x` and `y`, its style carried in from the `use`;
//! a `symbol` it names is drawn as a nested `svg` the `use`'s width and
//! height. A `use` that names one of the elements it is drawn inside is
//! not drawn, and no more than `max_uses` are drawn in all.
//!
//! **Not drawn**, nor anything in it: `defs` and what is in no `defs`
//! but is not drawn either - gradients, `symbol`, `clipPath`, `mask`,
//! `pattern`, `marker`, `style` - `image` and `text`, an element of
//! another namespace, and one with a `filter`, which this reader does
//! not have. In a `switch` the first element that can be drawn is.
//!
//! Elements nested deeper than `max_depth` are not drawn, and clips and
//! masks inside one another deeper than `max_references` clip nothing.
//!
//! `vb` is anything with vector.library's calls by their names: the
//! library itself on the machine, its module straight on the host.

const std = @import("std");
const sdk = @import("sdk");
const vector = sdk.vector;
pub const document = @import("document.zig");
const values = @import("values.zig");
const css = @import("css.zig");
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
/// Clips and masks being made inside one another: a mask's content
/// masked again, a clip's shapes clipped.
pub const max_references = 8;
/// The most `use` elements drawn in one picture, however they nest.
pub const max_uses = 16384;
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
    /// The rules of the file's `style` elements, in the order they apply.
    rules: [css.max_rules]css.Rule = undefined,
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
    /// A `use`: the element it names, its one child; `none` otherwise.
    use: u32 = none,
    /// Clips and masks pushed for it, to be popped when it ends.
    clips: u8 = 0,
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
    clip_rule: u32 = vector.RULE_NONZERO,
    // Not inherited.
    opacity: f32 = 1,
    shown: bool = true,
    filtered: bool = false,
    /// The `clip-path` and the `mask` it is drawn through, their
    /// `url(#...)`; empty for none.
    clip: []const u8 = "",
    mask: []const u8 = "",
    /// A `mask` by its coverage, not its luminance.
    mask_alpha: bool = false,
    /// What a viewport does with what is drawn outside it: null for what
    /// it does unless told, which for `svg` and `symbol` is to clip it.
    overflow_visible: ?bool = null,

    /// What a child starts from.
    fn inherited(parent: *const Style) Style {
        var s = parent.*;
        s.opacity = 1;
        s.shown = true;
        s.filtered = false;
        s.clip = "";
        s.mask = "";
        s.mask_alpha = false;
        s.overflow_visible = null;
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
    return wantedSize(size, 0, 0);
}

/// The size a program wants (`PDTA_WantedWidth`, `PDTA_WantedHeight`; 0
/// for not given): the file's shape fitted inside both, or scaled to the
/// one given, or the file's own size without either - in whole pixels,
/// and made smaller to fit in `max_side` either way.
pub fn wantedSize(size: Intrinsic, wanted_width: u32, wanted_height: u32) [2]u32 {
    const ww: f32 = @floatFromInt(@min(wanted_width, max_side));
    const wh: f32 = @floatFromInt(@min(wanted_height, max_side));
    const by: f32 = if (wanted_width != 0 and wanted_height != 0)
        @min(ww / size.width, wh / size.height)
    else if (wanted_width != 0)
        ww / size.width
    else if (wanted_height != 0)
        wh / size.height
    else
        1;
    var w = size.width * by;
    var h = size.height * by;
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
        /// How many of the work's rules there are.
        rule_count: u32 = 0,
        /// The frame drawn in now.
        depth: usize = 0,
        /// Clips and masks being made, one inside another.
        references: u32 = 0,
        /// `use` elements drawn so far.
        uses: u32 = 0,

        fn walk(p: *P, base: Matrix, viewport: [2]f32) void {
            p.readRules();
            const frames = &p.work.frames;
            const root_default = Style{};
            const root_style = p.styleOf(0, &root_default);
            if (!root_style.shown or root_style.filtered) return;
            frames[0] = .{ .node = 0, .style = root_style, .matrix = base, .viewport = viewport };
            p.depth = 0;
            p.enter(&frames[0], base, viewport, null);
            p.run(0);
        }

        /// The children of the frame at `base` drawn, and it ended. A
        /// mask's content is drawn the same way, in the frames above the
        /// one it is for.
        fn run(p: *P, base: usize) void {
            const frames = &p.work.frames;
            var depth = base;
            p.depth = depth;
            var child = p.doc.nodes[frames[base].node].first_child;
            while (true) {
                if (child == none) {
                    const ending = &frames[depth];
                    p.leave(ending);
                    if (depth == base) return;
                    depth -= 1;
                    p.depth = depth;
                    child = if (frames[depth].use != none) none else p.doc.nodes[ending.node].next;
                    continue;
                }
                const node = child;
                const top = &frames[depth];
                child = if (top.use != none) none else p.doc.nodes[node].next;
                const tag = p.doc.nodes[node].tag;
                if (top.choosing) {
                    if (top.chosen or !drawable(tag)) continue;
                    top.chosen = true;
                }
                switch (tag) {
                    .g, .a, .@"switch", .svg, .symbol, .use => {
                        if (depth + 1 == max_depth) continue;
                        // A symbol only as what a `use` names.
                        if (tag == .symbol and top.use != node) continue;
                        var target: u32 = none;
                        if (tag == .use) {
                            if (p.uses >= max_uses) continue;
                            target = p.useTarget(node, depth) orelse continue;
                        }
                        const style = p.styleOf(node, &top.style);
                        if (!style.shown or style.filtered) continue;
                        const space = top.matrix.then(p.ownTransform(node, top.viewport));
                        var matrix = space;
                        var inner = top.viewport;
                        var overflow: ?vector.Rect = null;
                        if (tag == .svg or tag == .symbol) {
                            const sized_by = if (top.use == node) top.node else none;
                            const view = p.viewportOf(node, sized_by, top.viewport) orelse continue;
                            matrix = view.matrix(space);
                            inner = view.inner;
                            if (!(style.overflow_visible orelse false)) overflow = view.rect;
                        }
                        if (tag == .use) p.uses += 1;
                        depth += 1;
                        p.depth = depth;
                        frames[depth] = .{ .node = node, .style = style, .matrix = matrix, .viewport = inner, .choosing = tag == .@"switch", .use = target };
                        p.enter(&frames[depth], space, top.viewport, overflow);
                        child = if (target != none) target else p.doc.nodes[node].first_child;
                    },
                    .path, .rect, .circle, .ellipse, .line, .polyline, .polygon => p.shape(node, top),
                    else => {},
                }
            }
        }

        /// What a group needs before its children: its clip and its mask,
        /// in `space` - its own units into pixels - its viewport's clip,
        /// and a layer for its opacity. One under a mask always has a
        /// layer, so it goes through the mask whole.
        fn enter(p: *P, frame: *Frame, space: Matrix, viewport: [2]f32, overflow: ?vector.Rect) void {
            const style = &frame.style;
            if (style.clip.len != 0) frame.clips += p.clipBy(style.clip, frame.node, space, viewport);
            var masked = false;
            if (style.mask.len != 0) {
                const owed = p.maskBy(style.mask, frame.node, space, viewport);
                frame.clips += owed;
                masked = owed != 0;
            }
            if (overflow) |rect| {
                p.vb.ClearPath(p.path);
                p.vb.AddRect(p.path, &rect, 0, 0);
                _ = p.vb.PushClip(p.canvas, p.path, &space, vector.RULE_NONZERO);
                frame.clips += 1;
            }
            // One the canvas had no room for is still pushed, its opacity
            // going into every paint, and is put down the same.
            frame.layered = masked or style.opacity < 1;
            if (frame.layered) _ = p.vb.PushLayer(p.canvas, style.opacity);
        }

        fn leave(p: *P, frame: *const Frame) void {
            if (frame.layered) p.vb.PopLayer(p.canvas);
            for (0..frame.clips) |_| p.vb.PopClip(p.canvas);
        }

        /// The element a `use` names, unless it is one it is drawn inside.
        fn useTarget(p: *P, node: u32, depth: usize) ?u32 {
            const target = p.doc.byHref(p.doc.get(node, .href) orelse return null) orelse return null;
            var up = node;
            while (up != none) : (up = p.doc.nodes[up].parent) if (up == target) return null;
            for (p.work.frames[0 .. depth + 1]) |frame| {
                if (frame.node == target or frame.use == target) return null;
            }
            return target;
        }

        /// What an element's own units are in its parent's: its
        /// `transform`, and a `use`'s `x` and `y` after it.
        fn ownTransform(p: *P, node: u32, viewport: [2]f32) Matrix {
            const m = p.transformOf(node, .transform);
            if (p.doc.nodes[node].tag != .use) return m;
            return m.then(Matrix.translate(p.lengthOf(node, .x, .x, viewport, 0), p.lengthOf(node, .y, .y, viewport, 0)));
        }

        const View = struct {
            /// The viewport in its element's units.
            rect: vector.Rect,
            /// Its `viewBox` into it, or null for none.
            box: ?Matrix,
            /// What percentages are of inside it.
            inner: [2]f32,

            fn matrix(view: View, space: Matrix) Matrix {
                const at = space.then(Matrix.translate(view.rect.x, view.rect.y));
                return if (view.box) |box| at.then(box) else at;
            }
        };

        /// A nested `svg`'s or a `symbol`'s viewport: its place, its size -
        /// the `use`'s that names it when one does, `sized_by`, else its
        /// own, 100% unless given - and its `viewBox` into that. Null for
        /// one of no size, which is not drawn.
        fn viewportOf(p: *P, node: u32, sized_by: u32, outer: [2]f32) ?View {
            const full = Length{ .value = 100, .percent = true };
            const sizer = if (sized_by != none and p.doc.get(sized_by, .width) != null) sized_by else node;
            const w = (if (p.doc.get(sizer, .width)) |t| values.length(t) else null) orelse full;
            const sizer_h = if (sized_by != none and p.doc.get(sized_by, .height) != null) sized_by else node;
            const h = (if (p.doc.get(sizer_h, .height)) |t| values.length(t) else null) orelse full;
            const width = w.resolve(.x, outer);
            const height = h.resolve(.y, outer);
            if (!(width > 0) or !(height > 0)) return null;
            const is_symbol = p.doc.nodes[node].tag == .symbol;
            var view = View{
                .rect = .{
                    .x = if (is_symbol) 0 else p.lengthOf(node, .x, .x, outer, 0),
                    .y = if (is_symbol) 0 else p.lengthOf(node, .y, .y, outer, 0),
                    .width = width,
                    .height = height,
                },
                .box = null,
                .inner = .{ width, height },
            };
            if (viewBox(p.doc.get(node, .viewBox))) |box| {
                view.box = viewBoxMatrix(box, p.doc.get(node, .preserveAspectRatio) orelse "", width, height);
                view.inner = .{ box.width, box.height };
            }
            return view;
        }

        fn shape(p: *P, node: u32, top: *const Frame) void {
            const style = p.styleOf(node, &top.style);
            if (!style.shown or style.filtered or !style.visible) return;
            const vb = p.vb;
            const viewport = top.viewport;
            const matrix = top.matrix.then(p.transformOf(node, .transform));
            var clips: u8 = 0;
            defer for (0..clips) |_| vb.PopClip(p.canvas);
            var masked = false;
            if (style.clip.len != 0) clips += p.clipBy(style.clip, node, matrix, viewport);
            if (style.mask.len != 0) {
                const owed = p.maskBy(style.mask, node, matrix, viewport);
                clips += owed;
                masked = owed != 0;
            }
            if (!p.buildShape(node, viewport)) return;
            const path = p.path;
            const filled = p.doc.nodes[node].tag != .line and style.fill != .none;
            const stroked = style.stroke != .none and style.stroke_width.resolve(.other, viewport) > 0;
            // Both ways at once, the opacity - and a mask - on a layer over
            // them both; one way, in the paint.
            const layered = filled and stroked and (style.opacity < 1 or masked);
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

        /// A shape element's outline built into the path, in its own
        /// units; false for one that has none.
        fn buildShape(p: *P, node: u32, viewport: [2]f32) bool {
            const vb = p.vb;
            const path = p.path;
            vb.ClearPath(path);
            switch (p.doc.nodes[node].tag) {
                .path => {
                    const d = p.doc.get(node, .d) orelse return false;
                    _ = vb.AddPathData(path, d.ptr, @intCast(d.len));
                },
                .rect => {
                    const w = p.lengthOf(node, .width, .x, viewport, 0);
                    const h = p.lengthOf(node, .height, .y, viewport, 0);
                    if (!(w > 0) or !(h > 0)) return false;
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
                    if (!p.points(node)) return false;
                    if (p.doc.nodes[node].tag == .polygon) vb.ClosePath(path);
                },
                else => return false,
            }
            return true;
        }

        // --- clips and masks ------------------------------------------------------

        /// The element a `clip-path` or a `mask` names, if it is one of
        /// `tag`.
        fn referenced(p: *P, text: []const u8, tag: Tag) ?u32 {
            const named = values.paint(text) orelse return null;
            if (named != .url) return null;
            const node = p.doc.byId(named.url.id) orelse return null;
            return if (p.doc.nodes[node].tag == tag) node else null;
        }

        /// Whether a `clipPathUnits`, `maskUnits` or `maskContentUnits` says
        /// the box's units.
        fn boxUnits(p: *P, node: u32, name: Name, default: bool) bool {
            const text = values.trim(p.doc.get(node, name) orelse return default);
            if (std.mem.eql(u8, text, "objectBoundingBox")) return true;
            if (std.mem.eql(u8, text, "userSpaceOnUse")) return false;
            return default;
        }

        /// A clip that lets nothing through, pushed.
        fn clipAll(p: *P) u8 {
            p.vb.ClearPath(p.path);
            _ = p.vb.PushClip(p.canvas, p.path, null, vector.RULE_NONZERO);
            return 1;
        }

        /// The `clipPath` `text` names pushed for `node`, drawn through
        /// `space`; how many pops that owes. None for one that is not
        /// there.
        fn clipBy(p: *P, text: []const u8, node: u32, space: Matrix, viewport: [2]f32) u8 {
            const clip = p.referenced(text, .clipPath) orelse return 0;
            if (p.references >= max_references) return 0;
            p.references += 1;
            defer p.references -= 1;
            const style = p.styleChain(clip);
            var owed: u8 = 0;
            // A clipPath clipped itself.
            if (style.clip.len != 0) owed += p.clipBy(style.clip, node, space, viewport);
            var m = space.then(p.transformOf(clip, .transform));
            if (p.boxUnits(clip, .clipPathUnits, false)) {
                const box = p.boundsOf(node, viewport) orelse return owed + p.clipAll();
                m = m.then(boxMatrix(box));
            }
            var count: u32 = 0;
            var only: Piece = undefined;
            var child = p.doc.nodes[clip].first_child;
            while (child != none) : (child = p.doc.nodes[child].next) {
                const piece = p.pieceOf(child, &style, viewport) orelse continue;
                count += 1;
                only = piece;
            }
            if (count == 0) return owed + p.clipAll();
            if (count == 1 and only.style.clip.len == 0) {
                if (!p.buildShape(only.node, viewport)) return owed + p.clipAll();
                const at = m.then(only.matrix);
                _ = p.vb.PushClip(p.canvas, p.path, &at, only.style.clip_rule);
                return owed + 1;
            }
            // More than one, or one clipped itself: their coverage.
            _ = p.vb.BeginMask(p.canvas);
            child = p.doc.nodes[clip].first_child;
            const white = vector.Paint{ .colour = .{ .r = 1, .g = 1, .b = 1 } };
            while (child != none) : (child = p.doc.nodes[child].next) {
                const piece = p.pieceOf(child, &style, viewport) orelse continue;
                const at = m.then(piece.matrix);
                const own = if (piece.style.clip.len != 0) p.clipBy(piece.style.clip, piece.node, at, viewport) else 0;
                if (p.buildShape(piece.node, viewport)) _ = p.vb.FillPath(p.canvas, p.path, &at, &white, piece.style.clip_rule);
                for (0..own) |_| p.vb.PopClip(p.canvas);
            }
            _ = p.vb.EndMask(p.canvas, vector.MASK_ALPHA);
            return owed + 1;
        }

        /// A shape a `clipPath` is made of: the shape, its style, and its
        /// units in the clip's.
        const Piece = struct { node: u32, style: Style, matrix: Matrix };

        /// A child of a `clipPath` as a piece of it - a shape, or a `use`
        /// of one - or null for what is no part of it.
        fn pieceOf(p: *P, child: u32, clip_style: *const Style, viewport: [2]f32) ?Piece {
            const tag = p.doc.nodes[child].tag;
            var style = p.styleOf(child, clip_style);
            if (!style.shown or !style.visible) return null;
            var matrix = p.ownTransform(child, viewport);
            var node = child;
            if (tag == .use) {
                const target = p.doc.byHref(p.doc.get(child, .href) orelse return null) orelse return null;
                if (!isShape(p.doc.nodes[target].tag)) return null;
                const own_clip = style.clip;
                style = p.styleOf(target, &style);
                if (!style.shown or !style.visible) return null;
                if (style.clip.len == 0) style.clip = own_clip;
                matrix = matrix.then(p.transformOf(target, .transform));
                node = target;
            } else if (!isShape(tag)) return null;
            return .{ .node = node, .style = style, .matrix = matrix };
        }

        /// The `mask` `text` names pushed for `node`, drawn through
        /// `space`; how many pops that owes. None for one that is not
        /// there.
        fn maskBy(p: *P, text: []const u8, node: u32, space: Matrix, viewport: [2]f32) u8 {
            const mask = p.referenced(text, .mask) orelse return 0;
            if (p.references >= max_references or p.depth + 1 >= max_depth) return 0;
            p.references += 1;
            defer p.references -= 1;
            var style = p.styleChain(mask);
            const box_units = p.boxUnits(mask, .maskUnits, true);
            const content_box = p.boxUnits(mask, .maskContentUnits, false);
            var box: vector.Rect = .{};
            if (box_units or content_box) {
                box = p.boundsOf(node, viewport) orelse return p.clipAll();
            }
            // Its region: by default a tenth of the box more each way.
            var region: vector.Rect = undefined;
            if (box_units) {
                region = .{
                    .x = box.x + boxFraction(p.doc.get(mask, .x), -0.1) * box.width,
                    .y = box.y + boxFraction(p.doc.get(mask, .y), -0.1) * box.height,
                    .width = boxFraction(p.doc.get(mask, .width), 1.2) * box.width,
                    .height = boxFraction(p.doc.get(mask, .height), 1.2) * box.height,
                };
            } else {
                const tenth = Length{ .value = -10, .percent = true };
                const more = Length{ .value = 120, .percent = true };
                region = .{
                    .x = p.lengthOr(mask, .x, .x, viewport, tenth),
                    .y = p.lengthOr(mask, .y, .y, viewport, tenth),
                    .width = p.lengthOr(mask, .width, .x, viewport, more),
                    .height = p.lengthOr(mask, .height, .y, viewport, more),
                };
            }
            if (!(region.width > 0) or !(region.height > 0)) return p.clipAll();
            _ = p.vb.BeginMask(p.canvas);
            p.vb.ClearPath(p.path);
            p.vb.AddRect(p.path, &region, 0, 0);
            _ = p.vb.PushClip(p.canvas, p.path, &space, vector.RULE_NONZERO);
            // A mask masked itself, as SVG 2 has it.
            const inner: u8 = if (style.mask.len != 0) p.maskBy(style.mask, node, space, viewport) else 0;
            const alpha = style.mask_alpha;
            style.opacity = 1;
            style.shown = true;
            style.filtered = false;
            style.clip = "";
            style.mask = "";
            const content = if (content_box) space.then(boxMatrix(box)) else space;
            const saved = p.depth;
            const frames = &p.work.frames;
            frames[saved + 1] = .{ .node = mask, .style = style, .matrix = content, .viewport = viewport };
            p.run(saved + 1);
            p.depth = saved;
            for (0..inner) |_| p.vb.PopClip(p.canvas);
            p.vb.PopClip(p.canvas);
            _ = p.vb.EndMask(p.canvas, if (alpha) vector.MASK_ALPHA else vector.MASK_LUMINANCE);
            return 1;
        }

        // --- the box of what an element draws ---------------------------------------

        /// The box of what `node` draws - its shapes' geometry, not their
        /// strokes - in its own units; null for nothing. The path is
        /// built in for it.
        fn boundsOf(p: *P, node: u32, viewport: [2]f32) ?vector.Rect {
            const style = p.styleChain(node);
            const box = p.boundsIn(node, .{}, &style, viewport, 0) orelse return null;
            if (!(box.width > 0) or !(box.height > 0)) return null;
            return box;
        }

        /// The box of what `node` draws through `m`, its style `style`.
        fn boundsIn(p: *P, node: u32, m: Matrix, style: *const Style, viewport: [2]f32, depth: u32) ?vector.Rect {
            if (depth >= max_depth) return null;
            const tag = p.doc.nodes[node].tag;
            if (isShape(tag)) {
                if (!p.buildShape(node, viewport)) return null;
                var box: vector.Rect = undefined;
                return if (p.vb.PathBounds(p.path, &m, &box)) box else null;
            }
            var content = m;
            var inner = viewport;
            var first = p.doc.nodes[node].first_child;
            var single = false;
            switch (tag) {
                .g, .a, .@"switch", .mask, .clipPath => {},
                .svg => if (node != 0) {
                    const view = p.viewportOf(node, none, viewport) orelse return null;
                    content = view.matrix(m);
                    inner = view.inner;
                },
                .use => {
                    const target = p.doc.byHref(p.doc.get(node, .href) orelse return null) orelse return null;
                    if (target == node) return null;
                    first = target;
                    single = true;
                },
                else => return null,
            }
            var all: ?vector.Rect = null;
            var child = first;
            while (child != none) : (child = if (single) none else p.doc.nodes[child].next) {
                const child_style = p.styleOf(child, style);
                if (!child_style.shown) continue;
                var at = content.then(p.ownTransform(child, inner));
                var child_inner = inner;
                const child_tag = p.doc.nodes[child].tag;
                if (child_tag == .symbol) {
                    if (!single) continue;
                    const view = p.viewportOf(child, node, inner) orelse continue;
                    at = view.matrix(at);
                    child_inner = view.inner;
                    var grandchild = p.doc.nodes[child].first_child;
                    while (grandchild != none) : (grandchild = p.doc.nodes[grandchild].next) {
                        const grand_style = p.styleOf(grandchild, &child_style);
                        if (!grand_style.shown) continue;
                        const each = p.boundsIn(grandchild, at.then(p.ownTransform(grandchild, child_inner)), &grand_style, child_inner, depth + 2);
                        all = unite(all, each);
                    }
                    continue;
                }
                all = unite(all, p.boundsIn(child, at, &child_style, child_inner, depth + 1));
                if (tag == .@"switch" and drawable(child_tag)) break;
            }
            return all;
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
                var c = p.cascade(child);
                while (c.next()) |one| stopProperty(one.name, one.value, &colour, &stop_opacity, &current, &use_current);
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

        /// An element's style: its parent's, then its properties as they
        /// cascade.
        fn styleOf(p: *P, node: u32, parent: *const Style) Style {
            var s = Style.inherited(parent);
            var c = p.cascade(node);
            while (c.next()) |one| property(&s, parent, one.name, one.value);
            return s;
        }

        /// An element's style where it is in the tree: its ancestors',
        /// from the root down, and then its own - what a `clipPath` or a
        /// `mask` has, wherever it is drawn from.
        fn styleChain(p: *P, node: u32) Style {
            var chain: [max_depth]u32 = undefined;
            var n: usize = 0;
            var at = node;
            while (at != none and n < max_depth) : (at = p.doc.nodes[at].parent) {
                chain[n] = at;
                n += 1;
            }
            var style = Style{};
            while (n > 0) {
                n -= 1;
                const parent = style;
                style = p.styleOf(chain[n], &parent);
            }
            return style;
        }

        fn cascade(p: *P, node: u32) Cascade {
            return .{
                .doc = p.doc,
                .rules = p.work.rules[0..p.rule_count],
                .node = node,
                .id = p.doc.get(node, .id),
                .class = p.doc.get(node, .class),
            };
        }

        /// The rules of every `style` element into the work, in the order
        /// they apply. One whose `type` is not CSS's is passed over.
        fn readRules(p: *P) void {
            var n: u32 = 0;
            for (p.doc.nodes, 0..) |node, i| {
                if (node.tag != .style) continue;
                for (p.doc.attributesOf(@intCast(i))) |a| {
                    if (a.name == .@"#text") css.parse(a.value, &p.work.rules, &n);
                }
            }
            p.rule_count = n;
            css.sort(p.work.rules[0..n]);
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

        fn lengthOr(p: *P, node: u32, name: Name, axis: values.Axis, viewport: [2]f32, default: Length) f32 {
            const text = p.doc.get(node, name);
            const l = (if (text) |t| values.length(t) else null) orelse default;
            return l.resolve(axis, viewport);
        }
    };
}

/// An element's properties in the order they cascade: its presentation
/// attributes, the rules for it, its `style` attribute.
const Cascade = struct {
    doc: *const Document,
    rules: []const css.Rule,
    node: u32,
    id: ?[]const u8,
    class: ?[]const u8,
    phase: enum { attributes, rules, style, done } = .attributes,
    index: usize = 0,
    declarations: values.Declarations = .{ .text = "" },

    const One = struct { name: Name, value: []const u8 };

    fn next(c: *Cascade) ?One {
        while (true) switch (c.phase) {
            .attributes => {
                const all = c.doc.attributesOf(c.node);
                if (c.index < all.len) {
                    const a = all[c.index];
                    c.index += 1;
                    if (a.name == .style or a.name == .@"#text") continue;
                    return .{ .name = a.name, .value = a.value };
                }
                c.phase = .rules;
                c.index = 0;
            },
            .rules => {
                if (c.declarations.next()) |d| return .{ .name = document.nameOf(d.name), .value = d.value };
                const tag = c.doc.nodes[c.node].tag;
                while (c.index < c.rules.len) {
                    const rule = &c.rules[c.index];
                    c.index += 1;
                    if (rule.matches(tag, c.id, c.class)) {
                        c.declarations = .{ .text = rule.declarations };
                        break;
                    }
                } else {
                    c.phase = .style;
                    c.declarations = .{ .text = c.doc.get(c.node, .style) orelse "" };
                }
            },
            .style => {
                if (c.declarations.next()) |d| return .{ .name = document.nameOf(d.name), .value = d.value };
                c.phase = .done;
            },
            .done => return null,
        };
    }
};

fn isShape(tag: Tag) bool {
    return switch (tag) {
        .path, .rect, .circle, .ellipse, .line, .polyline, .polygon => true,
        else => false,
    };
}

/// A box's units into the user's.
fn boxMatrix(box: vector.Rect) Matrix {
    return .{ .a = box.width, .d = box.height, .e = box.x, .f = box.y };
}

/// A number of the box's units, a percentage of it, or `default`.
fn boxFraction(text: ?[]const u8, default: f32) f32 {
    const l = values.length(text orelse return default) orelse return default;
    return if (l.percent) l.value / 100 else l.value;
}

fn unite(a: ?vector.Rect, b: ?vector.Rect) ?vector.Rect {
    const x = a orelse return b;
    const y = b orelse return a;
    const left = @min(x.x, y.x);
    const top = @min(x.y, y.y);
    const right = @max(x.x + x.width, y.x + y.width);
    const bottom = @max(x.y + x.height, y.y + y.height);
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
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
            .@"clip-rule" => s.clip_rule = parent.clip_rule,
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
        .@"clip-path" => s.clip = if (std.mem.eql(u8, text, "none")) "" else text,
        .mask => s.mask = if (std.mem.eql(u8, text, "none")) "" else text,
        .@"clip-rule" => {
            if (std.mem.eql(u8, text, "evenodd")) s.clip_rule = vector.RULE_EVENODD;
            if (std.mem.eql(u8, text, "nonzero")) s.clip_rule = vector.RULE_NONZERO;
        },
        .@"mask-type" => {
            if (std.mem.eql(u8, text, "alpha")) s.mask_alpha = true;
            if (std.mem.eql(u8, text, "luminance")) s.mask_alpha = false;
        },
        .overflow => {
            if (std.mem.eql(u8, text, "visible") or std.mem.eql(u8, text, "auto")) s.overflow_visible = true;
            if (std.mem.eql(u8, text, "hidden") or std.mem.eql(u8, text, "scroll")) s.overflow_visible = false;
        },
        else => {},
    }
}
