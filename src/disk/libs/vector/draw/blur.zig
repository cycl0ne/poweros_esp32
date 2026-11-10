// SPDX-License-Identifier: MIT
//! A layer's pens blurred: SVG's `feGaussianBlur`, as SVG says it may be
//! made - three box blurs one after another each way, which come to
//! within a few per cent of a Gaussian. Since 1.4.
//!
//! A box of d pixels, d = floor(s * 3 * sqrt(2 pi) / 4 + 0.5) for a
//! deviation of s: odd, three boxes centred on the pixel; even, two of d
//! - one a half pixel to the left, one a half to the right - and one of
//! d + 1 centred. Each is a running sum along the row or the column, so
//! a blur costs the same whatever its size.
//!
//! The pens are blurred premultiplied - a channel times its coverage -
//! so a clear pixel's colour goes nowhere, and turned back after. What
//! is past the canvas's edge is clear. The blur spreads what was drawn by
//! its reach each way: the region it returns holds all of it.

const sdk = @import("sdk");
const Pen = sdk.graphics.Pen;
const memory_ = @import("memory.zig");
const Memory = memory_.Memory;

/// The pixels a layer has been drawn on, from `left` and `top` to before
/// `right` and `bottom`.
pub const Region = struct {
    left: u32,
    top: u32,
    right: u32,
    bottom: u32,
};

/// One box: how far it reaches back and forward from the pixel.
const Box = struct { back: u32, forward: u32 };

/// The three boxes of a deviation of `s` pixels; none for a blur of
/// nothing.
fn boxesOf(s: f32) ?[3]Box {
    if (!(s > 0)) return null;
    const most: f32 = 1 << 20;
    const d: u32 = @intFromFloat(@floor(@min(s, most) * 1.879971 + 0.5));
    if (d <= 1) return null;
    if (d % 2 == 1) {
        const r = (d - 1) / 2;
        return .{ .{ .back = r, .forward = r }, .{ .back = r, .forward = r }, .{ .back = r, .forward = r } };
    }
    const h = d / 2;
    return .{ .{ .back = h, .forward = h - 1 }, .{ .back = h - 1, .forward = h }, .{ .back = h, .forward = h } };
}

/// How far three boxes spread what is drawn, back and forward.
fn reachOf(boxes: ?[3]Box) Box {
    const b = boxes orelse return .{ .back = 0, .forward = 0 };
    return .{ .back = b[0].back + b[1].back + b[2].back, .forward = b[0].forward + b[1].forward + b[2].forward };
}

/// The pens of a `width` by `height` layer, drawn on in `region`, blurred
/// by `deviation_x` across and `deviation_y` down, in pixels. The region
/// they now cover, or null without the memory for a row's work - and
/// then they are as they were.
pub fn blur(pens: []Pen, width: u32, height: u32, region: Region, deviation_x: f32, deviation_y: f32, memory: Memory) ?Region {
    const across = boxesOf(deviation_x);
    const down = boxesOf(deviation_y);
    const rx = reachOf(across);
    const ry = reachOf(down);
    const out = Region{
        .left = region.left -| rx.back,
        .top = region.top -| ry.back,
        .right = @min(region.right +| rx.forward, width),
        .bottom = @min(region.bottom +| ry.forward, height),
    };
    if (across == null and down == null) return region;
    const longest = @max(out.right - out.left, out.bottom - out.top);
    const work = memory.alloc(u32, @as(usize, longest) * 8) orelse return null;
    defer memory.free(u32, work);
    const a = work[0 .. @as(usize, longest) * 4];
    const b = work[@as(usize, longest) * 4 ..];

    // Premultiplied, where anything was drawn; clear everywhere else.
    var y = region.top;
    while (y < region.bottom) : (y += 1) {
        for (pens[@as(usize, y) * width ..][region.left..region.right]) |*pen| pen.* = premultiply(pen.*);
    }
    // Across, the rows drawn on; down, every column the rows now reach.
    if (across) |boxes| {
        const n = out.right - out.left;
        y = region.top;
        while (y < region.bottom) : (y += 1) {
            const row = pens[@as(usize, y) * width + out.left ..][0..n];
            load(a, row, 1);
            run(boxes, a, b, n);
            store(b, row, 1);
        }
    }
    if (down) |boxes| {
        const n = out.bottom - out.top;
        var x = out.left;
        while (x < out.right) : (x += 1) {
            const column = pens[@as(usize, out.top) * width + x ..];
            load(a, column, width);
            run(boxes, a, b, n);
            store(b, column[0 .. (@as(usize, n) - 1) * width + 1], width);
        }
    }
    y = out.top;
    while (y < out.bottom) : (y += 1) {
        for (pens[@as(usize, y) * width ..][out.left..out.right]) |*pen| pen.* = unpremultiply(pen.*);
    }
    return out;
}

/// `n` pens `stride` apart into four channels each in `into`, or as many
/// as the work holds.
fn load(into: []u32, from: []const Pen, stride: usize) void {
    const n = into.len / 4;
    var i: usize = 0;
    while (i < n and i * stride < from.len) : (i += 1) {
        const pen = from[i * stride];
        into[i * 4 + 0] = pen >> 24;
        into[i * 4 + 1] = (pen >> 16) & 0xFF;
        into[i * 4 + 2] = (pen >> 8) & 0xFF;
        into[i * 4 + 3] = pen & 0xFF;
    }
    while (i < n) : (i += 1) @memset(into[i * 4 ..][0..4], 0);
}

fn store(from: []const u32, into: []Pen, stride: usize) void {
    var i: usize = 0;
    while (i * stride < into.len and i * 4 < from.len) : (i += 1) {
        const c = from[i * 4 ..][0..4];
        into[i * stride] = channel(c[0]) << 24 | channel(c[1]) << 16 | channel(c[2]) << 8 | channel(c[3]);
    }
}

fn channel(v: u32) u32 {
    return @min(v, 255);
}

/// The three boxes, from `a` through `b` and back to end in `b`.
fn run(boxes: [3]Box, a: []u32, b: []u32, n: u32) void {
    pass(a, b, n, boxes[0]);
    pass(b, a, n, boxes[1]);
    pass(a, b, n, boxes[2]);
}

/// One box along `n` pixels of four channels, `from` into `into`; what is
/// past either end is clear.
fn pass(from: []const u32, into: []u32, n: u32, box: Box) void {
    const d = box.back + box.forward + 1;
    const half = d / 2;
    var sum: [4]u32 = .{ 0, 0, 0, 0 };
    var k: u32 = 0;
    while (k <= box.forward and k < n) : (k += 1) {
        for (0..4) |c| sum[c] += from[k * 4 + c];
    }
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        for (0..4) |c| into[i * 4 + c] = (sum[c] + half) / d;
        const entering = i + 1 + box.forward;
        if (entering < n) {
            for (0..4) |c| sum[c] += from[entering * 4 + c];
        }
        if (i >= box.back) {
            const leaving = i - box.back;
            for (0..4) |c| sum[c] -= from[leaving * 4 + c];
        }
    }
}

fn premultiply(pen: Pen) Pen {
    const a = pen >> 24;
    if (a == 255) return pen;
    const r = ((pen >> 16) & 0xFF) * a / 255;
    const g = ((pen >> 8) & 0xFF) * a / 255;
    const b = (pen & 0xFF) * a / 255;
    return a << 24 | r << 16 | g << 8 | b;
}

fn unpremultiply(pen: Pen) Pen {
    const a = pen >> 24;
    if (a == 255) return pen;
    if (a == 0) return 0;
    const r = channel(((pen >> 16) & 0xFF) * 255 / a);
    const g = channel(((pen >> 8) & 0xFF) * 255 / a);
    const b = channel((pen & 0xFF) * 255 / a);
    return a << 24 | r << 16 | g << 8 | b;
}

// --- tests ---------------------------------------------------------------------

const testing = @import("std").testing;
const test_memory = memory_.test_memory;

test "box sizes: odd three alike, even two off centre and one larger, none for a deviation too small" {
    try testing.expect(boxesOf(0) == null);
    try testing.expect(boxesOf(-3) == null);
    try testing.expect(boxesOf(0.5) == null);
    // 2 pixels: d = 4, even.
    const even = boxesOf(2).?;
    try testing.expectEqual(Box{ .back = 2, .forward = 1 }, even[0]);
    try testing.expectEqual(Box{ .back = 1, .forward = 2 }, even[1]);
    try testing.expectEqual(Box{ .back = 2, .forward = 2 }, even[2]);
    // 3 pixels: d = 6; 2.5: d = 5, odd.
    try testing.expectEqual(Box{ .back = 2, .forward = 2 }, boxesOf(2.5).?[1]);
    try testing.expectEqual(Box{ .back = 6, .forward = 6 }, reachOf(boxesOf(2.5)));
}

test "a blurred dot: spread, kept whole, symmetrical, its colour kept; the region grown and held to the layer" {
    const w = 21;
    const h = 21;
    var pens: [w * h]Pen = @splat(0);
    // A red dot, three by three in the middle.
    for (9..12) |y| for (9..12) |x| {
        pens[y * w + x] = 0xFFFF0000;
    };
    const region = blur(&pens, w, h, .{ .left = 9, .top = 9, .right = 12, .bottom = 12 }, 2, 2, test_memory).?;
    try testing.expectEqual(Region{ .left = 4, .top = 4, .right = 17, .bottom = 17 }, region);
    // Spread: the middle no longer whole, a pixel four away touched.
    try testing.expect(pens[10 * w + 10] >> 24 < 255);
    try testing.expect(pens[10 * w + 14] >> 24 > 0);
    // Symmetrical within a step of rounding.
    const left = pens[10 * w + 7] >> 24;
    const right = pens[10 * w + 13] >> 24;
    try testing.expect(@max(left, right) - @min(left, right) <= 2);
    // Kept whole: the coverage summed is about the nine it was.
    var sum: u32 = 0;
    for (pens) |pen| sum += pen >> 24;
    try testing.expect(sum > 9 * 255 - 60 and sum < 9 * 255 + 60);
    // Every pixel touched red, none of another colour.
    for (pens) |pen| if (pen >> 24 != 0) try testing.expectEqual(@as(u32, 0xFF0000), pen & 0xFFFFFF);

    // At the corner: held to the layer, and across only.
    var corner: [w * h]Pen = @splat(0);
    corner[0] = 0xFF00FF00;
    const held = blur(&corner, w, h, .{ .left = 0, .top = 0, .right = 1, .bottom = 1 }, 2, 0, test_memory).?;
    try testing.expectEqual(Region{ .left = 0, .top = 0, .right = 6, .bottom = 1 }, held);
    try testing.expect(corner[2] >> 24 > 0);
    try testing.expectEqual(@as(Pen, 0), corner[w]);
}
