// SPDX-License-Identifier: MPL-2.0
//! What of the display changed since a picture was last made, as a few
//! rectangles: a rectangle that overlaps or touches another is merged
//! with it, and once there are `max_boxes` the next goes into the one it
//! grows least. So a drawing scattered over the display costs a copy of
//! what was drawn, not of the rows from its top to its bottom, and a
//! thousand small ones cost no more bookkeeping than sixteen.
//!
//! Bands shown in place of others change only the rows that come from
//! another buffer, or from another row of it, than before (`rebanded`):
//! a screen pulled further down leaves the rows of the one behind it
//! above it as they were.

const std = @import("std");
const rtg = @import("sdk").rtg;
const RtgBand = rtg.RtgBand;

/// A rectangle of the display: columns `left` up to `right`, rows `top`
/// up to `end`.
pub const Box = struct {
    left: u32,
    top: u32,
    right: u32,
    end: u32,

    pub fn isEmpty(box: Box) bool {
        return box.left >= box.right or box.top >= box.end;
    }

    /// The smallest rectangle holding both.
    pub fn unionOf(a: Box, b: Box) Box {
        return .{ .left = @min(a.left, b.left), .top = @min(a.top, b.top), .right = @max(a.right, b.right), .end = @max(a.end, b.end) };
    }

    /// Whether the two overlap or share an edge.
    pub fn touches(a: Box, b: Box) bool {
        return a.left <= b.right and b.left <= a.right and a.top <= b.end and b.top <= a.end;
    }

    pub fn area(box: Box) u64 {
        return @as(u64, box.right - box.left) * (box.end - box.top);
    }
};

/// How many rectangles are kept apart.
pub const max_boxes = 16;

pub const Damage = struct {
    boxes: [max_boxes]Box = undefined,
    count: u32 = 0,

    /// `box` added: merged with every rectangle it overlaps or touches,
    /// and with what that makes touch, until it touches none; with no
    /// room left for it, merged into the one that grows least.
    pub fn add(damage: *Damage, box: Box) void {
        if (box.isEmpty()) return;
        var grown = box;
        var i: u32 = 0;
        while (i < damage.count) {
            if (!damage.boxes[i].touches(grown)) {
                i += 1;
                continue;
            }
            grown = grown.unionOf(damage.boxes[i]);
            damage.count -= 1;
            damage.boxes[i] = damage.boxes[damage.count];
            i = 0;
        }
        if (damage.count < max_boxes) {
            damage.boxes[damage.count] = grown;
            damage.count += 1;
            return;
        }
        var best: u32 = 0;
        var least: u64 = std.math.maxInt(u64);
        for (damage.boxes[0..damage.count], 0..) |kept, j| {
            const growth = kept.unionOf(grown).area() - kept.area();
            if (growth >= least) continue;
            least = growth;
            best = @intCast(j);
        }
        const merged = damage.boxes[best].unionOf(grown);
        damage.count -= 1;
        damage.boxes[best] = damage.boxes[damage.count];
        damage.add(merged);
    }

    /// Every rectangle of `other` added.
    pub fn addAll(damage: *Damage, other: *const Damage) void {
        for (other.boxes[0..other.count]) |box| damage.add(box);
    }

    pub fn isEmpty(damage: *const Damage) bool {
        return damage.count == 0;
    }

    pub fn list(damage: *const Damage) []const Box {
        return damage.boxes[0..damage.count];
    }

    /// The rows of a display `width` by `height` that show something else
    /// once it is shown `new` in place of `old` - bands in the order of
    /// their lines, as a board is given them - added, each the width of
    /// the display. A row shows the same when it comes from the same row
    /// of the same buffer, or from no band in either.
    pub fn rebanded(damage: *Damage, old: []const RtgBand, new: []const RtgBand, width: u32, height: u32) void {
        var y: u32 = 0;
        while (y < height) {
            const end = @min(nextLine(old, y), nextLine(new, y), height);
            if (!sameRows(bandAt(old, y), bandAt(new, y))) damage.add(.{ .left = 0, .top = y, .right = width, .end = end });
            y = end;
        }
    }
};

/// The band display line `y` is in: the last that starts at or above it.
fn bandAt(bands: []const RtgBand, y: u32) ?RtgBand {
    var i = bands.len;
    while (i > 0) {
        i -= 1;
        if (bands[i].line <= y) return bands[i];
    }
    return null;
}

/// The first line below `y` that a band starts at.
fn nextLine(bands: []const RtgBand, y: u32) u32 {
    for (bands) |band| {
        if (band.line > y) return band.line;
    }
    return std.math.maxInt(u32);
}

/// Whether two bands show every line they share from the same row of the
/// same buffer.
fn sameRows(a: ?RtgBand, b: ?RtgBand) bool {
    const one = a orelse return b == null;
    const other = b orelse return false;
    if (one.bitmap != other.bitmap) return false;
    const one_repeats = one.flags & rtg.RTGBANDF_REPEAT != 0;
    if (one_repeats != (other.flags & rtg.RTGBANDF_REPEAT != 0)) return false;
    return one_repeats or one.origin == other.origin;
}

const testing = std.testing;

fn rect(left: u32, top: u32, right: u32, end: u32) Box {
    return .{ .left = left, .top = top, .right = right, .end = end };
}

test "rectangles apart are kept apart, empty ones are not kept" {
    var damage: Damage = .{};
    damage.add(rect(0, 0, 10, 10));
    damage.add(rect(100, 100, 110, 110));
    damage.add(rect(5, 5, 5, 20));
    try testing.expectEqual(@as(u32, 2), damage.count);
    try testing.expectEqual(rect(0, 0, 10, 10), damage.boxes[0]);
    try testing.expectEqual(rect(100, 100, 110, 110), damage.boxes[1]);
}

test "overlapping and touching rectangles are one" {
    var damage: Damage = .{};
    damage.add(rect(0, 0, 10, 10));
    damage.add(rect(5, 5, 20, 20));
    damage.add(rect(20, 0, 30, 5));
    try testing.expectEqual(@as(u32, 1), damage.count);
    try testing.expectEqual(rect(0, 0, 30, 20), damage.boxes[0]);
}

test "a rectangle between two takes both in" {
    var damage: Damage = .{};
    damage.add(rect(0, 0, 10, 10));
    damage.add(rect(50, 0, 60, 10));
    damage.add(rect(200, 200, 210, 210));
    damage.add(rect(8, 2, 52, 4));
    try testing.expectEqual(@as(u32, 2), damage.count);
    var found = false;
    for (damage.list()) |kept| found = found or std.meta.eql(kept, rect(0, 0, 60, 10));
    try testing.expect(found);
}

test "with no room left, the next goes into the one it grows least" {
    var damage: Damage = .{};
    for (0..max_boxes) |i| {
        const at: u32 = @intCast(i * 100);
        damage.add(rect(at, 0, at + 10, 10));
    }
    try testing.expectEqual(@as(u32, max_boxes), damage.count);
    damage.add(rect(312, 0, 320, 10));
    try testing.expectEqual(@as(u32, max_boxes), damage.count);
    var found = false;
    for (damage.list()) |kept| found = found or std.meta.eql(kept, rect(300, 0, 320, 10));
    try testing.expect(found);
}

/// Three buffers for the bands of the tests to show.
const t = struct {
    var a: rtg.RtgBitMap = .{};
    var b: rtg.RtgBitMap = .{};
    var c: rtg.RtgBitMap = .{};
};

test "the same bands change nothing" {
    const bands = [_]RtgBand{ .{ .bitmap = &t.a }, .{ .bitmap = &t.b, .line = 100, .origin = 100 } };
    var damage: Damage = .{};
    damage.rebanded(&bands, &bands, 640, 480);
    try testing.expect(damage.isEmpty());
}

test "a screen pulled further down leaves the rows above it" {
    const old = [_]RtgBand{ .{ .bitmap = &t.a }, .{ .bitmap = &t.b, .line = 100, .origin = 100 } };
    const new = [_]RtgBand{ .{ .bitmap = &t.a }, .{ .bitmap = &t.b, .line = 110, .origin = 110 } };
    var damage: Damage = .{};
    damage.rebanded(&old, &new, 640, 480);
    try testing.expectEqual(@as(u32, 1), damage.count);
    try testing.expectEqual(rect(0, 100, 640, 480), damage.boxes[0]);
}

test "another buffer behind changes its rows alone" {
    const old = [_]RtgBand{ .{ .bitmap = &t.a }, .{ .bitmap = &t.b, .line = 100, .origin = 100 } };
    const new = [_]RtgBand{ .{ .bitmap = &t.c }, .{ .bitmap = &t.b, .line = 100, .origin = 100 } };
    var damage: Damage = .{};
    damage.rebanded(&old, &new, 640, 480);
    try testing.expectEqual(@as(u32, 1), damage.count);
    try testing.expectEqual(rect(0, 0, 640, 100), damage.boxes[0]);
}

test "a line repeated stays, from nothing everything changes" {
    const old = [_]RtgBand{ .{ .bitmap = &t.a }, .{ .bitmap = &t.c, .line = 99, .flags = rtg.RTGBANDF_REPEAT }, .{ .bitmap = &t.b, .line = 100, .origin = 100 } };
    const new = [_]RtgBand{ .{ .bitmap = &t.a }, .{ .bitmap = &t.c, .line = 99, .flags = rtg.RTGBANDF_REPEAT }, .{ .bitmap = &t.b, .line = 100, .origin = 50 } };
    var damage: Damage = .{};
    damage.rebanded(&old, &new, 640, 480);
    try testing.expectEqual(@as(u32, 1), damage.count);
    try testing.expectEqual(rect(0, 100, 640, 480), damage.boxes[0]);
    var all: Damage = .{};
    all.rebanded(&.{}, &new, 640, 480);
    try testing.expectEqual(@as(u32, 1), all.count);
    try testing.expectEqual(rect(0, 0, 640, 480), all.boxes[0]);
}

test "two lists in one" {
    var first: Damage = .{};
    var second: Damage = .{};
    first.add(rect(0, 0, 10, 10));
    second.add(rect(10, 0, 20, 10));
    second.add(rect(500, 500, 510, 510));
    first.addAll(&second);
    try testing.expectEqual(@as(u32, 2), first.count);
}
