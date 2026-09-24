// SPDX-License-Identifier: MPL-2.0
//! What mouse.device makes of a mouse: where it is and which buttons are
//! down, turned into the events that got it there, and the queue they wait
//! in until a read takes them.
//!
//! `Mouse.change` is handed the mouse as it is now and answers with a move
//! if the pointer went somewhere, and then an event for each button that
//! went down or up - left, right, middle - each with the qualifiers as they
//! are after it. It is plain arithmetic, so the host tests drive it.

const sdk = @import("sdk");
const ie = sdk.devices.inputevent;
const InputEvent = ie.InputEvent;

/// The qualifier bits the buttons set.
pub const button_qualifiers: u32 = ie.IEQUALIFIER_LEFTBUTTON | ie.IEQUALIFIER_RBUTTON | ie.IEQUALIFIER_MIDBUTTON;

/// A mouse as it is at one moment: an absolute pointer and its buttons.
pub const Now = struct { x: i32, y: i32, left: bool, right: bool, middle: bool };

/// What the mouse was, to tell what changed.
pub const Mouse = extern struct {
    x: i32 = 0,
    y: i32 = 0,
    /// The buttons down, as their qualifier bits.
    qualifier: u32 = 0,

    /// The events from what it was to `now`, into `out`: a move first when
    /// the pointer moved, then a button each. Answers how many.
    pub fn change(m: *Mouse, now: Now, out: *[4]InputEvent) usize {
        var n: usize = 0;
        if (now.x != m.x or now.y != m.y) {
            m.x = now.x;
            m.y = now.y;
            out[n] = m.event(ie.IECODE_NOBUTTON);
            n += 1;
        }
        const buttons = [_]struct { down: bool, code: u32, bit: u32 }{
            .{ .down = now.left, .code = ie.IECODE_LBUTTON, .bit = ie.IEQUALIFIER_LEFTBUTTON },
            .{ .down = now.right, .code = ie.IECODE_RBUTTON, .bit = ie.IEQUALIFIER_RBUTTON },
            .{ .down = now.middle, .code = ie.IECODE_MBUTTON, .bit = ie.IEQUALIFIER_MIDBUTTON },
        };
        for (buttons) |b| {
            const was = m.qualifier & b.bit != 0;
            if (was == b.down) continue;
            if (b.down) m.qualifier |= b.bit else m.qualifier &= ~b.bit;
            out[n] = m.event(if (b.down) b.code else b.code | ie.IECODE_UP_PREFIX);
            n += 1;
        }
        return n;
    }

    fn event(m: *const Mouse, code: u32) InputEvent {
        return .{ .class = ie.IECLASS_RAWMOUSE, .code = code, .qualifier = m.qualifier, .x = m.x, .y = m.y };
    }
};

/// The events not yet read, oldest first. Full, the oldest goes: what a
/// mouse did last matters more than what it did long ago.
pub const Queue = extern struct {
    pub const capacity = 64;
    events: [capacity]InputEvent = undefined,
    head: usize = 0,
    count: usize = 0,

    pub fn push(q: *Queue, e: InputEvent) void {
        if (q.count == capacity) {
            q.head = (q.head + 1) % capacity;
            q.count -= 1;
        }
        q.events[(q.head + q.count) % capacity] = e;
        q.count += 1;
    }

    /// Up to `into.len` of the oldest, taken off and linked through `next`.
    pub fn take(q: *Queue, into: []InputEvent) usize {
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

// --- tests ----------------------------------------------------------------------

const testing = @import("std").testing;

test "a move, then each button that changed, with the qualifiers after it" {
    var m: Mouse = .{};
    var out: [4]InputEvent = undefined;

    // Moved and the right button went down: the move, then the button.
    try testing.expectEqual(@as(usize, 2), m.change(.{ .x = 10, .y = 20, .left = false, .right = true, .middle = false }, &out));
    try testing.expectEqual(ie.IECLASS_RAWMOUSE, out[0].class);
    try testing.expectEqual(ie.IECODE_NOBUTTON, out[0].code);
    try testing.expectEqual(@as(i32, 10), out[0].x);
    try testing.expectEqual(@as(u32, 0), out[0].qualifier);
    try testing.expectEqual(ie.IECODE_RBUTTON, out[1].code);
    try testing.expectEqual(ie.IEQUALIFIER_RBUTTON, out[1].qualifier);
    try testing.expectEqual(@as(i32, 20), out[1].y);

    // Nothing changed: nothing.
    try testing.expectEqual(@as(usize, 0), m.change(.{ .x = 10, .y = 20, .left = false, .right = true, .middle = false }, &out));

    // Left and middle down together, right up: left, right, middle in turn.
    try testing.expectEqual(@as(usize, 3), m.change(.{ .x = 10, .y = 20, .left = true, .right = false, .middle = true }, &out));
    try testing.expectEqual(ie.IECODE_LBUTTON, out[0].code);
    try testing.expectEqual(ie.IEQUALIFIER_LEFTBUTTON | ie.IEQUALIFIER_RBUTTON, out[0].qualifier);
    try testing.expectEqual(ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, out[1].code);
    try testing.expectEqual(ie.IEQUALIFIER_LEFTBUTTON, out[1].qualifier);
    try testing.expectEqual(ie.IECODE_MBUTTON, out[2].code);
    try testing.expectEqual(ie.IEQUALIFIER_LEFTBUTTON | ie.IEQUALIFIER_MIDBUTTON, out[2].qualifier);
}

test "the queue: oldest first, linked, and full it drops the oldest" {
    var q: Queue = .{};
    for (0..Queue.capacity + 2) |i| q.push(.{ .class = ie.IECLASS_RAWMOUSE, .x = @intCast(i) });
    try testing.expectEqual(@as(usize, Queue.capacity), q.count);
    var into: [3]InputEvent = undefined;
    try testing.expectEqual(@as(usize, 3), q.take(&into));
    try testing.expectEqual(@as(i32, 2), into[0].x);
    try testing.expectEqual(&into[1], into[0].next.?);
    try testing.expect(into[2].next == null);
    q.clear();
    try testing.expectEqual(@as(usize, 0), q.take(&into));
}
