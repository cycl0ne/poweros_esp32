// SPDX-License-Identifier: MPL-2.0
//! What touch.device makes of any controller's report, and what every
//! controller has in common: a register address on the wire, the change
//! from one report to the next, and the queue the events wait in.
//!
//! A report is where every finger is; a program wants what changed.
//! `diff` compares two reports by contact id and says so: a new id is a
//! finger that landed, a missing one a finger that lifted, one that moved
//! or pressed differently a move. The events go into a `Queue` until a
//! read takes them.
//!
//! None of it touches hardware, so the host tests hold all of it.

const sdk = @import("sdk");
const touch = sdk.devices.touch;
const TouchEvent = touch.TouchEvent;
const TouchContact = touch.TouchContact;

/// A register address as a controller with 16-bit registers wants it on
/// the wire: high byte first.
pub fn address(register: u16) [2]u8 {
    return .{ @truncate(register >> 8), @truncate(register) };
}

/// How the screen is turned from the panel the fingers are on: the glass
/// is mounted one way and the picture may be drawn another, and a program
/// is told where the finger is on the screen, not on the glass.
pub const Turn = enum(u8) {
    none,
    /// The screen's left edge lies along the panel's top edge.
    clockwise,
    /// Its right edge does.
    counter_clockwise,
};

/// The turn `degrees` names: 0, 90 or 270. Anything else is none.
pub fn turnOf(degrees: u32) Turn {
    return switch (degrees) {
        90 => .clockwise,
        270 => .counter_clockwise,
        else => .none,
    };
}

/// A contact the panel reported, where it is on a screen turned that way.
/// `width` and `height` are the panel's own, as the controller counts.
pub fn turned(c: TouchContact, turn: Turn, width: u32, height: u32) TouchContact {
    var out = c;
    switch (turn) {
        .none => {},
        .clockwise => {
            out.x = c.y;
            out.y = @as(i32, @intCast(width)) - 1 - c.x;
        },
        .counter_clockwise => {
            out.x = @as(i32, @intCast(height)) - 1 - c.y;
            out.y = c.x;
        },
    }
    return out;
}

fn find(in: []const TouchContact, id: u32) ?TouchContact {
    for (in) |c| {
        if (c.id == id) return c;
    }
    return null;
}

fn event(kind: u32, c: TouchContact) TouchEvent {
    return .{ .kind = kind, .id = c.id, .x = c.x, .y = c.y, .size = c.size };
}

/// What changed from `old` to `new`, into `out`: lifts first, then lands
/// and moves in the order the controller listed them. Answers how many.
pub fn diff(old: []const TouchContact, new: []const TouchContact, out: []TouchEvent) usize {
    var n: usize = 0;
    for (old) |o| {
        if (find(new, o.id) == null and n < out.len) {
            out[n] = event(touch.TOUCH_UP, o);
            n += 1;
        }
    }
    for (new) |c| {
        if (n >= out.len) break;
        if (find(old, c.id)) |o| {
            if (o.x != c.x or o.y != c.y or o.size != c.size) {
                out[n] = event(touch.TOUCH_MOVE, c);
                n += 1;
            }
        } else {
            out[n] = event(touch.TOUCH_DOWN, c);
            n += 1;
        }
    }
    return n;
}

// --- the queue ---------------------------------------------------------------------

/// Events waiting for a read. When it is full the oldest goes, not the
/// newest: a program that falls behind should still see the finger lift.
pub const Queue = extern struct {
    pub const capacity = 64;
    events: [capacity]TouchEvent = undefined,
    head: usize = 0,
    count: usize = 0,

    pub fn push(q: *Queue, e: TouchEvent) void {
        if (q.count == capacity) {
            q.head = (q.head + 1) % capacity;
            q.count -= 1;
        }
        q.events[(q.head + q.count) % capacity] = e;
        q.count += 1;
    }

    /// Up to `into.len` of the oldest, taken off the queue and linked
    /// through `next`. Answers how many.
    pub fn take(q: *Queue, into: []TouchEvent) usize {
        const n = @min(q.count, into.len);
        for (0..n) |i| {
            into[i] = q.events[q.head];
            into[i].next = null;
            if (i > 0) into[i - 1].next = &into[i];
            q.head = (q.head + 1) % capacity;
        }
        q.count -= n;
        return n;
    }

    pub fn clear(q: *Queue) void {
        q.head = 0;
        q.count = 0;
    }
};

// --- tests ---------------------------------------------------------------------------

const testing = @import("std").testing;

test "diff: a finger lands, moves, a second lands, the first lifts" {
    var out: [8]TouchEvent = undefined;
    const none = [_]TouchContact{};
    const one = [_]TouchContact{.{ .id = 1, .x = 10, .y = 20, .size = 5 }};
    try testing.expectEqual(@as(usize, 1), diff(&none, &one, &out));
    try testing.expectEqual(touch.TOUCH_DOWN, out[0].kind);

    // The same report again says nothing.
    try testing.expectEqual(@as(usize, 0), diff(&one, &one, &out));

    const moved = [_]TouchContact{.{ .id = 1, .x = 12, .y = 20, .size = 5 }};
    try testing.expectEqual(@as(usize, 1), diff(&one, &moved, &out));
    try testing.expectEqual(touch.TOUCH_MOVE, out[0].kind);
    try testing.expectEqual(@as(i32, 12), out[0].x);

    const two = [_]TouchContact{ moved[0], .{ .id = 2, .x = 300, .y = 400, .size = 7 } };
    try testing.expectEqual(@as(usize, 1), diff(&moved, &two, &out));
    try testing.expectEqual(touch.TOUCH_DOWN, out[0].kind);
    try testing.expectEqual(@as(u32, 2), out[0].id);

    // The first lifts: an UP where it was last, before anything else.
    const second = [_]TouchContact{.{ .id = 2, .x = 305, .y = 400, .size = 7 }};
    try testing.expectEqual(@as(usize, 2), diff(&two, &second, &out));
    try testing.expectEqual(touch.TOUCH_UP, out[0].kind);
    try testing.expectEqual(@as(u32, 1), out[0].id);
    try testing.expectEqual(@as(i32, 12), out[0].x);
    try testing.expectEqual(touch.TOUCH_MOVE, out[1].kind);
}

test "queue: taken in order and linked, the oldest dropped when full" {
    var q: Queue = .{};
    for (0..3) |i| q.push(.{ .kind = touch.TOUCH_MOVE, .x = @intCast(i) });
    var got: [2]TouchEvent = undefined;
    try testing.expectEqual(@as(usize, 2), q.take(&got));
    try testing.expectEqual(@as(i32, 0), got[0].x);
    try testing.expectEqual(&got[1], got[0].next.?);
    try testing.expect(got[1].next == null);
    try testing.expectEqual(@as(usize, 1), q.count);

    q.clear();
    for (0..Queue.capacity + 3) |i| q.push(.{ .x = @intCast(i) });
    try testing.expectEqual(@as(usize, Queue.capacity), q.count);
    var one: [1]TouchEvent = undefined;
    _ = q.take(&one);
    // The first three went to make room.
    try testing.expectEqual(@as(i32, 3), one[0].x);
}

test "turned: a finger on the glass, where it is on the screen" {
    // A panel 320 wide and 480 tall under a 480x320 screen.
    const c: TouchContact = .{ .id = 0, .x = 10, .y = 400, .size = 3 };
    const cw = turned(c, .clockwise, 320, 480);
    try testing.expectEqual(@as(i32, 400), cw.x);
    try testing.expectEqual(@as(i32, 309), cw.y);
    const ccw = turned(c, .counter_clockwise, 320, 480);
    try testing.expectEqual(@as(i32, 79), ccw.x);
    try testing.expectEqual(@as(i32, 10), ccw.y);
    // The panel's corners land on the screen's.
    const origin = turned(.{ .x = 0, .y = 0 }, .clockwise, 320, 480);
    try testing.expectEqual(@as(i32, 0), origin.x);
    try testing.expectEqual(@as(i32, 319), origin.y);
    try testing.expectEqual(c, turned(c, .none, 320, 480));
    try testing.expectEqual(Turn.clockwise, turnOf(90));
    try testing.expectEqual(Turn.none, turnOf(0));
}
