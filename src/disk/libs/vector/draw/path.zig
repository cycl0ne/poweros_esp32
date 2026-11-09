// SPDX-License-Identifier: MIT
//! A path: contours of lines and curves in the caller's units, kept as
//! they were given - a verb for each segment and its points - so that it
//! is broken into lines only when it is drawn, and then at the size it
//! is drawn at.
//!
//! A contour starts with a move. A segment with no move before it has
//! nowhere to start and is passed over. After a close, a segment starts
//! a new contour where the closed one began, as SVG's path data does.
//!
//! **A path that ran out of memory** keeps what fitted and says so
//! (`failed`): it is drawn as far as it went. A segment is added whole
//! or not at all.

const sdk = @import("sdk");
const vector = sdk.vector;
const memory_ = @import("memory.zig");
const Memory = memory_.Memory;
const List = memory_.List;
const P = vector.Point;

pub const Verb = enum(u8) {
    /// One point: where a contour starts.
    move,
    /// One point: where the line ends.
    line,
    /// Two points: the control point, the end.
    quad,
    /// Three points: the two control points, the end.
    cubic,
    /// No point: the contour closed back to its start.
    close,

    pub fn points(verb: Verb) u32 {
        return switch (verb) {
            .move, .line => 1,
            .quad => 2,
            .cubic => 3,
            .close => 0,
        };
    }
};

pub const Path = struct {
    memory: Memory,
    verbs: List(Verb) = .{},
    points: List(P) = .{},
    /// Something did not fit: the path is drawn as far as it went.
    failed: bool = false,
    /// A move has come: there is a current point.
    begun: bool = false,
    /// The contour being built is not closed.
    open: bool = false,
    /// Where it started.
    start: P = .{},

    /// An empty path, in memory of its own; null without it.
    pub fn create(memory: Memory) ?*Path {
        const path = memory.create(Path) orelse return null;
        path.* = .{ .memory = memory };
        return path;
    }

    pub fn destroy(path: *Path) void {
        const memory = path.memory;
        path.verbs.deinit(memory);
        path.points.deinit(memory);
        memory.destroy(Path, path);
    }

    /// Empty again, the memory kept.
    pub fn clear(path: *Path) void {
        path.verbs.clear();
        path.points.clear();
        path.failed = false;
        path.begun = false;
        path.open = false;
    }

    pub fn moveTo(path: *Path, p: P) void {
        if (!path.add(.move, &.{p})) return;
        path.begun = true;
        path.open = true;
        path.start = p;
    }

    pub fn lineTo(path: *Path, p: P) void {
        if (!path.reopen()) return;
        _ = path.add(.line, &.{p});
    }

    pub fn quadTo(path: *Path, control: P, p: P) void {
        if (!path.reopen()) return;
        _ = path.add(.quad, &.{ control, p });
    }

    pub fn cubicTo(path: *Path, c1: P, c2: P, p: P) void {
        if (!path.reopen()) return;
        _ = path.add(.cubic, &.{ c1, c2, p });
    }

    pub fn close(path: *Path) void {
        if (!path.open) return;
        if (!path.add(.close, &.{})) return;
        path.open = false;
    }

    /// The current point: the end of the last segment, or after a close
    /// where the closed contour began. Null before the first move.
    pub fn current(path: *const Path) ?P {
        if (!path.begun) return null;
        if (!path.open) return path.start;
        const all = path.points.items();
        return all[all.len - 1];
    }

    /// Whether a segment may be added: after a close, a new contour
    /// started where the closed one began.
    fn reopen(path: *Path) bool {
        if (!path.begun) return false;
        if (!path.open) path.moveTo(path.start);
        return path.open;
    }

    fn add(path: *Path, verb: Verb, points: []const P) bool {
        const memory = path.memory;
        if (!path.verbs.reserve(memory, 1) or !path.points.reserve(memory, points.len)) {
            path.failed = true;
            return false;
        }
        _ = path.verbs.append(memory, verb);
        for (points) |p| _ = path.points.append(memory, p);
        return true;
    }

    /// The segments in order.
    pub fn walk(path: *const Path) Walk {
        return .{ .verbs = path.verbs.items(), .points = path.points.items() };
    }
};

/// A segment: its verb and its points.
pub const Segment = struct { verb: Verb, points: []const P };

pub const Walk = struct {
    verbs: []const Verb,
    points: []const P,
    verb_at: usize = 0,
    point_at: usize = 0,

    pub fn next(walk: *Walk) ?Segment {
        if (walk.verb_at == walk.verbs.len) return null;
        const verb = walk.verbs[walk.verb_at];
        const n = verb.points();
        const segment = Segment{ .verb = verb, .points = walk.points[walk.point_at .. walk.point_at + n] };
        walk.verb_at += 1;
        walk.point_at += n;
        return segment;
    }
};

// --- tests ---------------------------------------------------------------------

const testing = @import("std").testing;
const test_memory = memory_.test_memory;

test "segments before a move are passed over, and after a close start where it began" {
    const path = Path.create(test_memory).?;
    defer path.destroy();
    path.lineTo(.{ .x = 5, .y = 5 });
    try testing.expectEqual(@as(?P, null), path.current());
    path.moveTo(.{ .x = 1, .y = 2 });
    path.lineTo(.{ .x = 3, .y = 2 });
    path.close();
    try testing.expectEqual(P{ .x = 1, .y = 2 }, path.current().?);
    path.lineTo(.{ .x = 1, .y = 9 });
    var walk = path.walk();
    const want = [_]Verb{ .move, .line, .close, .move, .line };
    for (want) |verb| try testing.expectEqual(verb, walk.next().?.verb);
    try testing.expect(walk.next() == null);
    path.clear();
    try testing.expectEqual(@as(usize, 0), path.verbs.len);
    try testing.expect(!path.failed);
}
