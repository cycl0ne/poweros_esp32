// SPDX-License-Identifier: MPL-2.0
//! What a composed layer looks like besides its pixels: round corners, a
//! shadow on what is behind it, and how much of what is behind it it
//! covers (`LATAG_Corners`, `LATAG_Shadow`, `LATAG_Opacity`).
//!
//! - **Corners** are geometry. A layer's shape is its rectangle less the
//!   rows of each corner `cornerCut` says, and the tiling works with the
//!   shape - what the layer can see, what it covers - so nothing else has
//!   to know of them.
//! - **A shadow** is what is behind darkened. The tiling works out where
//!   each layer's can be seen (`Layer.shade`): its rectangle, out by its
//!   size, less the layer and what covers it, and only over a layer
//!   behind it. Whatever is copied there is darkened as it lands, from a
//!   small picture made once a size (`Shadow`): the corners straight from
//!   it, the sides from a row of it, the rest in rows of one colour.
//!   Darkening is a multiplication, so the shadows on a pixel can be laid
//!   in any order and come to the same.
//! - **A layer seen through** is laid over what is behind it at its
//!   opacity, and does not cover it. Laying over is not something that can
//!   be done twice, so it is done only where everything under it is copied
//!   again first: when the layers are shown in order (`compose.show`),
//!   which whoever fades a layer does at every step. Until then what is
//!   drawn under it, or in it, waits.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const layers = sdk.layers;
const rtg = sdk.rtg;
const Rect = graphics.Rect;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;

const info_mod = @import("../layerinfo/_layerinfo.zig");
const LayerInfo = info_mod.LayerInfo;
const Layer = info_mod.Layer;
const LayersBase = @import("../layers.zig").LayersBase;

/// The largest shadow there is: its picture is four times as wide, square.
pub const most_shadow = 32;

/// How dark a shadow is where it is darkest, out of 255.
const strength: u32 = 0x60;

/// The radius a layer's corners are cut at: none when they are square.
///
/// INPUTS:
/// - `layer` - the layer, of a composed LayerInfo.
pub fn radiusOf(layer: *const Layer) u32 {
    if (layer.corners == 0) return 0;
    return layers.cornerRadius(layer.corners, @intCast(layer.bounds.width()), @intCast(layer.bounds.height()));
}

/// A layer's corners cut out of `region`, which holds its rectangle or
/// part of it. False without memory.
///
/// INPUTS:
/// - `gb` - graphics.library, for the region calls.
/// - `region` - in the display's coordinates.
/// - `layer` - the layer.
pub fn cutCorners(gb: *GraphicsBase, region: *graphics.Region, layer: *const Layer) bool {
    const radius = radiusOf(layer);
    const b = layer.bounds;
    var row: u32 = 0;
    while (row < radius) : (row += 1) {
        const cut: i32 = @intCast(layers.cornerCut(radius, row));
        if (cut == 0) break;
        const down: i32 = @intCast(row);
        for ([2]i32{ b.min_y + down, b.max_y - 1 - down }) |y| {
            const left = Rect{ .min_x = b.min_x, .min_y = y, .max_x = b.min_x + cut, .max_y = y + 1 };
            const right = Rect{ .min_x = b.max_x - cut, .min_y = y, .max_x = b.max_x, .max_y = y + 1 };
            if (!gb.ClearRectRegion(region, &left) or !gb.ClearRectRegion(region, &right)) return false;
        }
    }
    return true;
}

/// A layer's shape added to `region`: its rectangle, less its corners.
/// False without memory.
///
/// INPUTS:
/// - `gb` - graphics.library.
/// - `region` - in the display's coordinates.
/// - `layer` - the layer.
pub fn addShape(gb: *GraphicsBase, region: *graphics.Region, layer: *const Layer) bool {
    if (radiusOf(layer) == 0) return gb.OrRectRegion(region, &layer.bounds);
    const alone = gb.NewRegion() orelse return false;
    defer gb.DisposeRegion(alone);
    return gb.OrRectRegion(alone, &layer.bounds) and cutCorners(gb, alone, layer) and gb.OrRegionRegion(alone, region);
}

/// Whether the point (`x`, `y`), in the display's coordinates, is on the
/// layer's shape: in its rectangle, and not in a corner cut away.
pub fn holds(layer: *const Layer, x: i32, y: i32) bool {
    const b = layer.bounds;
    if (x < b.min_x or x >= b.max_x or y < b.min_y or y >= b.max_y) return false;
    const radius = radiusOf(layer);
    if (radius == 0) return true;
    const row: u32 = @intCast(@min(y - b.min_y, b.max_y - 1 - y));
    const cut: i32 = @intCast(layers.cornerCut(radius, row));
    return x - b.min_x >= cut and b.max_x - 1 - x >= cut;
}

/// The rectangle a shadow of `size` covers for a layer at `bounds`: out
/// by the size all round, and a third of it lower.
///
/// INPUTS:
/// - `bounds` - the layer's rectangle.
/// - `size` - the shadow's size.
pub fn shadowBox(bounds: Rect, size: u32) Rect {
    const out: i32 = @intCast(size);
    const down = @divTrunc(out, 3);
    return .{
        .min_x = bounds.min_x - out,
        .min_y = bounds.min_y - out + down,
        .max_x = bounds.max_x + out,
        .max_y = bounds.max_y + out + down,
    };
}

/// What a layer at `bounds` touches on the display, its shadow with it:
/// whatever showing it again, or what it leaves, has to show.
///
/// INPUTS:
/// - `layer` - the layer.
/// - `bounds` - where it is, or was.
pub fn reachAt(layer: *const Layer, bounds: Rect) Rect {
    if (layer.shadow == 0 or !layer.info.compose) return bounds;
    return Rect.unionWith(bounds, shadowBox(bounds, layer.shadow));
}

/// `reachAt` where the layer is now.
pub fn reach(layer: *const Layer) Rect {
    return reachAt(layer, layer.bounds);
}

// --- a shadow's picture --------------------------------------------------

/// The picture of a shadow of one size, kept on the LayerInfo for as long
/// as it lives: `4 * size` pixels square, the four corners of a shadow -
/// each a quarter of it - and one row more, its sides; then the same row
/// turned on its side, `strip` columns wide, for its top and bottom.
/// Black, in bgra32, its darkness in the top byte.
pub const Shadow = struct {
    next: ?*Shadow = null,
    size: u32,
    /// How many bytes, this with them.
    bytes: usize,

    /// The pixels, after this.
    fn pixels(shadow: *const Shadow) [*]const u32 {
        const at = @intFromPtr(shadow) + header;
        return @ptrFromInt(at);
    }
};

/// Where a Shadow's pixels start in its memory.
const header = (@sizeOf(Shadow) + 15) & ~@as(usize, 15);

/// How many columns of a shadow's top or bottom one call darkens: the
/// picture of it is this wide, and laid along the edge this far at a
/// time - not a call for every row of it.
const strip = 64;

/// How dark a shadow of `size` is `depth` pixels in from its edge: soft
/// over the first two sizes, a smooth step, then as dark as it gets.
fn falloff(size: u32, depth: u32) u32 {
    const wide = 2 * size;
    if (depth >= wide) return strength;
    // t = (depth + 1/2) / wide; t^2 (3 - 2t), in whole numbers.
    const num: u64 = 2 * @as(u64, depth) + 1;
    const den: u64 = 2 * @as(u64, wide);
    return @intCast(strength * num * num * (3 * den - 2 * num) / (den * den * den));
}

/// The shadow of `size` the LayerInfo keeps, or null.
pub fn shadowOf(info: *const LayerInfo, size: u32) ?*const Shadow {
    var at = info.shadows;
    while (at) |shadow| : (at = shadow.next) {
        if (shadow.size == size) return shadow;
    }
    return null;
}

/// The picture of a shadow of `size` made, unless the LayerInfo has it
/// already. False without memory. The caller holds every layer.
///
/// INPUTS:
/// - `lb` - the library.
/// - `info` - the LayerInfo.
/// - `size` - 1 to `most_shadow`.
pub fn makeShadow(lb: *LayersBase, info: *LayerInfo, size: u32) bool {
    if (shadowOf(info, size) != null) return true;
    const side = 4 * size;
    const bytes = header + @as(usize, side) * (side + 1 + strip) * 4;
    const sys = lb.sys_base;
    const memory = sys.AllocVec(bytes, exec.MEMF_ANY) orelse return false;
    _ = sys.SetMemOwner(memory, null);
    const shadow: *Shadow = @ptrCast(@alignCast(memory));
    shadow.* = .{ .next = info.shadows, .size = size, .bytes = bytes };
    const out: [*]u32 = @constCast(shadow.pixels());
    var y: u32 = 0;
    while (y < side) : (y += 1) {
        const down = falloff(size, @min(y, side - 1 - y));
        var x: u32 = 0;
        while (x < side) : (x += 1) {
            const across = falloff(size, @min(x, side - 1 - x));
            out[y * side + x] = (across * down / strength) << 24;
        }
    }
    var x: u32 = 0;
    while (x < side) : (x += 1) out[side * side + x] = falloff(size, @min(x, side - 1 - x)) << 24;
    const turned = out + side * (side + 1);
    y = 0;
    while (y < side) : (y += 1) @memset(turned[y * strip ..][0..strip], falloff(size, @min(y, side - 1 - y)) << 24);
    info.shadows = shadow;
    return true;
}

/// Every shadow's picture given back, as the LayerInfo goes.
pub fn freeShadows(lb: *LayersBase, info: *LayerInfo) void {
    var at = info.shadows;
    info.shadows = null;
    while (at) |shadow| {
        at = shadow.next;
        lb.sys_base.FreeVec(shadow);
    }
}

// --- where a shadow can be seen -----------------------------------------------

/// A layer's shade worked out afresh, as the tiling reaches it front to
/// back: its shadow's rectangle on the display, less the layer and what
/// is in front of it (`covered`). The tiling cuts it to what is behind
/// afterwards (`keepOver`). False without memory; the layer then has none.
///
/// INPUTS:
/// - `lb` - the library.
/// - `layer` - the layer, of a composed LayerInfo.
/// - `covered` - what the layers in front of it cover.
pub fn castShade(lb: *LayersBase, layer: *Layer, covered: *graphics.Region) bool {
    const gb = lb.graphics_base;
    dropShade(gb, layer);
    if (layer.shadow == 0 or shadowOf(layer.info, layer.shadow) == null) return true;
    const box = Rect.intersect(shadowBox(layer.bounds, layer.shadow), layer.info.bounds);
    if (box.isEmpty()) return true;
    const shade = lb.newRegion() orelse return false;
    const self = lb.newRegion() orelse {
        gb.DisposeRegion(shade);
        return false;
    };
    defer gb.DisposeRegion(self);
    if (!gb.OrRectRegion(shade, &box) or !addShape(gb, self, layer) or
        !gb.SubRegionRegion(self, shade) or !gb.SubRegionRegion(covered, shade))
    {
        gb.DisposeRegion(shade);
        return false;
    }
    layer.shade = shade;
    layer.shade_box = box;
    return true;
}

/// A layer's shade cut to `behind`, what the layers behind it cover; none
/// at all when nothing is left. False without memory, with none.
pub fn keepOver(lb: *LayersBase, layer: *Layer, behind: *graphics.Region) bool {
    const gb = lb.graphics_base;
    const shade = layer.shade orelse return true;
    if (!gb.AndRegionRegion(behind, shade)) {
        dropShade(gb, layer);
        return false;
    }
    if (info_mod.isEmpty(gb, shade)) dropShade(gb, layer);
    return true;
}

/// A layer's shade given back.
pub fn dropShade(gb: *GraphicsBase, layer: *Layer) void {
    const shade = layer.shade orelse return;
    layer.shade = null;
    layer.shade_box = .{};
    gb.DisposeRegion(shade);
}

// --- darkening -----------------------------------------------------------------

/// One of the three spans a shadow's rectangle is cut into across, or
/// down: the soft edge at its start, the middle, the soft edge at its end.
const Span = struct {
    lo: i32,
    hi: i32,
    edge: enum { start, middle, end },
};

/// The spans of `lo` to `hi` with soft edges `wide` deep. A shadow
/// narrower than both edges is all edge, met in the middle.
fn spans(lo: i32, hi: i32, wide: i32) [3]Span {
    const half = lo + @divTrunc(hi - lo, 2);
    return .{
        .{ .lo = lo, .hi = @min(lo + wide, half), .edge = .start },
        .{ .lo = lo + wide, .hi = hi - wide, .edge = .middle },
        .{ .lo = @max(hi - wide, half), .hi = hi, .edge = .end },
    };
}

/// The picture's column (or row) for `at` in an edge span of `lo` to
/// `hi`: the start counts from the picture's start, the end ends at its
/// end.
fn indexIn(span: Span, lo: i32, hi: i32, side: i32, at: i32) i32 {
    return if (span.edge == .start) at - lo else side - (hi - at);
}

/// `area` of the display darkened by `caster`'s shadow, at its opacity -
/// on the display's buffer as it is, nothing handed on: the caller does
/// that. `area` is inside the shadow's rectangle.
fn darkenRect(lb: *LayersBase, caster: *const Layer, shadow: *const Shadow, area: Rect) void {
    const rb = lb.rtg_base;
    const display = caster.info.bitmap orelse return;
    const size = shadow.size;
    const box = shadowBox(caster.bounds, size);
    const wide: i32 = @intCast(2 * size);
    const side: i32 = 2 * wide;
    const opacity: u32 = caster.opacity;
    const pixels = shadow.pixels();
    for (spans(box.min_y, box.max_y, wide)) |down| {
        for (spans(box.min_x, box.max_x, wide)) |across| {
            const part = Rect.intersect(area, .{ .min_x = across.lo, .min_y = down.lo, .max_x = across.hi, .max_y = down.hi });
            if (part.isEmpty()) continue;
            const rect = rtg.RtgRect{ .x = part.min_x, .y = part.min_y, .width = part.width(), .height = part.height() };
            if (across.edge != .middle and down.edge != .middle) {
                // A corner: straight from the picture's.
                const picture = rtg.RtgPixels{
                    .pixels = @ptrCast(pixels),
                    .pitch = @intCast(side * 4),
                    .format = .bgra32,
                    .x = indexIn(across, box.min_x, box.max_x, side, part.min_x),
                    .y = indexIn(down, box.min_y, box.max_y, side, part.min_y),
                };
                _ = rb.BlendPixels(display, &rect, &picture, opacity);
            } else if (across.edge != .middle) {
                // A side: the picture's last row, again and again.
                const picture = rtg.RtgPixels{
                    .pixels = @ptrCast(pixels + @as(usize, @intCast(side * side))),
                    .pitch = 0,
                    .format = .bgra32,
                    .x = indexIn(across, box.min_x, box.max_x, side, part.min_x),
                };
                _ = rb.BlendPixels(display, &rect, &picture, opacity);
            } else if (down.edge != .middle) {
                // The top or the bottom: the sides' row turned on its
                // side, laid a strip at a time.
                const turned = pixels + @as(usize, @intCast(side * (side + 1)));
                var x = part.min_x;
                while (x < part.max_x) : (x += strip) {
                    const run = rtg.RtgRect{ .x = x, .y = part.min_y, .width = @min(strip, part.max_x - x), .height = part.height() };
                    const picture = rtg.RtgPixels{
                        .pixels = @ptrCast(turned),
                        .pitch = strip * 4,
                        .format = .bgra32,
                        .y = indexIn(down, box.min_y, box.max_y, side, part.min_y),
                    };
                    _ = rb.BlendPixels(display, &run, &picture, opacity);
                }
            } else {
                const dark = strength * opacity / 255;
                if (dark != 0) _ = rb.BlendRect(display, &rect, dark << 24);
            }
        }
    }
}

/// How many pieces of a shade are read without asking exec for room.
const pieces_at_hand = 32;

/// What of `area` a layer's shadow falls on, darkened: on the display's
/// buffer, nothing handed on.
///
/// INPUTS:
/// - `lb` - the library.
/// - `caster` - the layer whose shadow it is.
/// - `area` - where, in the display's coordinates.
pub fn darken(lb: *LayersBase, caster: *const Layer, area: Rect) void {
    const shade = caster.shade orelse return;
    if (Rect.intersect(area, caster.shade_box).isEmpty()) return;
    const shadow = shadowOf(caster.info, caster.shadow) orelse return;
    const gb = lb.graphics_base;
    var at_hand: [pieces_at_hand]Rect = undefined;
    const n = gb.RegionRectangles(shade, &at_hand, pieces_at_hand);
    var pieces: []const Rect = at_hand[0..@min(n, pieces_at_hand)];
    var room: ?*anyopaque = null;
    defer if (room) |memory| lb.sys_base.FreeVec(memory);
    if (n > pieces_at_hand) {
        room = lb.sys_base.AllocVec(n * @sizeOf(Rect), exec.MEMF_ANY);
        if (room) |memory| {
            const all: [*]Rect = @ptrCast(@alignCast(memory));
            _ = gb.RegionRectangles(shade, all, n);
            pieces = all[0..n];
        }
    }
    for (pieces) |r| {
        const part = Rect.intersect(r, area);
        if (!part.isEmpty()) darkenRect(lb, caster, shadow, part);
    }
}

/// Whether a shadow of a layer in front of `layer` may fall on `area`.
pub fn shadedFront(layer: *const Layer, area: Rect) bool {
    var it = layer.info.layers.iterator();
    while (it.next()) |node| {
        const front: *const Layer = @fieldParentPtr("node", node);
        if (front == layer) return false;
        if (front.shade != null and !Rect.intersect(area, front.shade_box).isEmpty()) return true;
    }
    return false;
}

/// `area`, just copied from `layer`, darkened by the shadows of the
/// layers in front of it.
pub fn darkenFront(lb: *LayersBase, layer: *const Layer, area: Rect) void {
    var it = layer.info.layers.iterator();
    while (it.next()) |node| {
        const front: *const Layer = @fieldParentPtr("node", node);
        if (front == layer) return;
        darken(lb, front, area);
    }
}

// --- seen through -----------------------------------------------------------

/// The most pieces a piece is cut into around the layers in front that
/// are seen through; past it, none of it is shown until they are.
pub const most_unveiled = 32;

/// What of `piece` of `layer` no layer in front of it that is seen
/// through lies over - which is what may be copied at once - into `out`.
/// How many.
pub fn unveiled(layer: *const Layer, piece: Rect, out: *[most_unveiled]Rect) usize {
    out[0] = piece;
    var n: usize = 1;
    var it = layer.info.layers.iterator();
    while (it.next()) |node| {
        const front: *const Layer = @fieldParentPtr("node", node);
        if (front == layer) break;
        if (front.opacity == 255) continue;
        var cut: [most_unveiled]Rect = undefined;
        var m: usize = 0;
        for (out[0..n]) |r| {
            const hole = Rect.intersect(r, front.bounds);
            if (hole.isEmpty()) {
                if (m == most_unveiled) return 0;
                cut[m] = r;
                m += 1;
                continue;
            }
            const around = [4]Rect{
                .{ .min_x = r.min_x, .min_y = r.min_y, .max_x = r.max_x, .max_y = hole.min_y },
                .{ .min_x = r.min_x, .min_y = hole.max_y, .max_x = r.max_x, .max_y = r.max_y },
                .{ .min_x = r.min_x, .min_y = hole.min_y, .max_x = hole.min_x, .max_y = hole.max_y },
                .{ .min_x = hole.max_x, .min_y = hole.min_y, .max_x = r.max_x, .max_y = hole.max_y },
            };
            for (around) |rest| {
                if (rest.isEmpty()) continue;
                if (m == most_unveiled) return 0;
                cut[m] = rest;
                m += 1;
            }
        }
        @memcpy(out[0..m], cut[0..m]);
        n = m;
        if (n == 0) return 0;
    }
    return n;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

test "a shadow is soft over two sizes, then as dark as it gets" {
    try testing.expect(falloff(8, 0) < falloff(8, 4));
    try testing.expect(falloff(8, 4) < falloff(8, 12));
    try testing.expectEqual(strength, falloff(8, 16));
    try testing.expectEqual(strength, falloff(8, 100));
    try testing.expect(falloff(8, 0) <= 1);
}

test "a shadow's spans: edges, a middle, and edges that meet" {
    const wide = spans(0, 100, 20);
    try testing.expectEqual(@as(i32, 20), wide[0].hi);
    try testing.expectEqual(@as(i32, 20), wide[1].lo);
    try testing.expectEqual(@as(i32, 80), wide[1].hi);
    try testing.expectEqual(@as(i32, 80), wide[2].lo);
    const narrow = spans(0, 30, 20);
    try testing.expectEqual(@as(i32, 15), narrow[0].hi);
    try testing.expect(narrow[1].hi <= narrow[1].lo);
    try testing.expectEqual(@as(i32, 15), narrow[2].lo);
    // The end's first column is as far in from the end as the start's
    // last is from the start: the picture's column as far from its end.
    try testing.expectEqual(@as(i32, 14), indexIn(narrow[0], 0, 30, 80, 14));
    try testing.expectEqual(@as(i32, 80 - 14 - 1), indexIn(narrow[2], 0, 30, 80, 15));
}
