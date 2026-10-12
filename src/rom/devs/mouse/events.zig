// SPDX-License-Identifier: MPL-2.0
//! What mouse.device makes of its mice: where the pointer is and which
//! buttons are down, turned into the events that got it there, and the
//! queue they wait in until a read takes them.
//!
//! Several mice - sources - feed one `Mouse`, each keeping the buttons it
//! holds down as qualifier bits of its own. A button goes down for the
//! readers when the first source presses it and up when the last one lets
//! go (`Mouse.button` counts the holders), and a source saying again what
//! it already said changes nothing. A move is either a place
//! (`Mouse.moveTo`) or a distance (`Mouse.moveBy`, marked
//! IEQUALIFIER_RELATIVEMOUSE); the device passes a distance on as one, for
//! whoever follows the pointer to add up.
//!
//! `Mouse.change` is handed the emulator's mouse as it is now and answers
//! with a move if the pointer went somewhere, and then an event for each
//! button that went down or up - left, right, middle - each with the
//! qualifiers as they are after it. `Mouse.take` does the same for an
//! event a source handed over, `Mouse.letGo` for a source that goes away,
//! and `Mouse.wheel` makes the event for the wheel's notches. It is plain
//! arithmetic, so the host tests drive it.

const sdk = @import("sdk");
const ie = sdk.devices.inputevent;
const InputEvent = ie.InputEvent;
const TimeVal = sdk.devices.timer.TimeVal;

/// The qualifier bits the buttons set.
pub const button_qualifiers: u32 = ie.IEQUALIFIER_LEFTBUTTON | ie.IEQUALIFIER_RBUTTON | ie.IEQUALIFIER_MIDBUTTON;

/// A mouse as it is at one moment: an absolute pointer and its buttons.
pub const Now = struct { x: i32, y: i32, left: bool, right: bool, middle: bool };

/// The three buttons: each one's code and qualifier bit.
const buttons = [_]struct { code: u32, bit: u32 }{
    .{ .code = ie.IECODE_LBUTTON, .bit = ie.IEQUALIFIER_LEFTBUTTON },
    .{ .code = ie.IECODE_RBUTTON, .bit = ie.IEQUALIFIER_RBUTTON },
    .{ .code = ie.IECODE_MBUTTON, .bit = ie.IEQUALIFIER_MIDBUTTON },
};

/// What the mice add up to, to tell what changed.
pub const Mouse = extern struct {
    /// Where a mouse that says where it is last put the pointer.
    x: i32 = 0,
    y: i32 = 0,
    /// The buttons down, on any of the mice, as their qualifier bits.
    qualifier: u32 = 0,
    /// IEQUALIFIER_RELATIVEMOUSE when the last move was a distance.
    relative: u32 = 0,
    /// IESUBCLASS_TABLET when the last place was across a tablet, 0 when
    /// it was a pixel.
    subclass: u32 = 0,
    /// How many sources hold each button down, in `buttons`' order.
    holders: [buttons.len]u16 = @splat(0),
    pad: u16 = 0,

    /// The events from what the emulator's mouse was to `now`, into
    /// `out`, `own` the buttons it holds: a move first when the pointer
    /// moved, then a button each. Answers how many.
    pub fn change(m: *Mouse, own: *u32, now: Now, out: *[4]InputEvent) usize {
        var n: usize = 0;
        if (m.moveTo(now.x, now.y, 0)) |e| {
            out[n] = e;
            n += 1;
        }
        const down = [buttons.len]bool{ now.left, now.right, now.middle };
        for (buttons, down) |b, is_down| {
            const code = if (is_down) b.code else b.code | ie.IECODE_UP_PREFIX;
            if (m.button(own, code, false)) |e| {
                out[n] = e;
                n += 1;
            }
        }
        return n;
    }

    /// The pointer put at `x`, `y` - pixels, or a tablet's place with
    /// `subclass` IESUBCLASS_TABLET: the move, or null when it is there.
    pub fn moveTo(m: *Mouse, x: i32, y: i32, subclass: u32) ?InputEvent {
        if (x == m.x and y == m.y and m.relative == 0 and m.subclass == subclass) return null;
        m.x = x;
        m.y = y;
        m.relative = 0;
        m.subclass = subclass;
        return m.event(ie.IECODE_NOBUTTON, false);
    }

    /// The pointer moved by `dx`, `dy`: the move, marked as a distance, or
    /// null when it is no distance.
    pub fn moveBy(m: *Mouse, dx: i32, dy: i32) ?InputEvent {
        if (dx == 0 and dy == 0) return null;
        m.relative = ie.IEQUALIFIER_RELATIVEMOUSE;
        return .{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_NOBUTTON, .qualifier = m.qualifier | m.relative, .x = dx, .y = dy };
    }

    /// A button down or up (`code` with IECODE_UP_PREFIX) on one source,
    /// `own` the buttons it holds: the event the readers see, or null when
    /// the button does not change for them, or `code` is no button. A
    /// source that moves by distances (`relative`) has no place to give,
    /// so its event says no distance; any other's is where the pointer is.
    pub fn button(m: *Mouse, own: *u32, code: u32, relative: bool) ?InputEvent {
        const down = code & ie.IECODE_UP_PREFIX == 0;
        const plain = code & ~ie.IECODE_UP_PREFIX;
        for (buttons, 0..) |b, i| {
            if (b.code != plain) continue;
            const holds = own.* & b.bit != 0;
            if (holds == down) return null;
            if (down) {
                own.* |= b.bit;
                m.holders[i] += 1;
                if (m.holders[i] > 1) return null;
                m.qualifier |= b.bit;
            } else {
                own.* &= ~b.bit;
                m.holders[i] -= 1;
                if (m.holders[i] > 0) return null;
                m.qualifier &= ~b.bit;
            }
            return m.event(code, relative);
        }
        return null;
    }

    /// An event a source handed over, into `out`: its move first, then
    /// its button, or its wheel. Answers how many; 0 for an event that is
    /// not a mouse's, or changes nothing.
    pub fn take(m: *Mouse, own: *u32, e: *const InputEvent, out: *[2]InputEvent) usize {
        if (e.class != ie.IECLASS_RAWMOUSE) return 0;
        if (e.code == ie.IECODE_WHEEL) {
            if (e.x == 0 and e.y == 0) return 0;
            out[0] = m.wheel(e.x, e.y);
            return 1;
        }
        const relative = e.qualifier & ie.IEQUALIFIER_RELATIVEMOUSE != 0;
        var n: usize = 0;
        const subclass: u32 = if (e.subclass == ie.IESUBCLASS_TABLET) ie.IESUBCLASS_TABLET else 0;
        const moved = if (relative) m.moveBy(e.x, e.y) else m.moveTo(e.x, e.y, subclass);
        if (moved) |move| {
            out[n] = move;
            n += 1;
        }
        if (m.button(own, e.code, relative)) |pressed| {
            out[n] = pressed;
            n += 1;
        }
        return n;
    }

    /// Every button `own` holds let go, as a source that goes away does:
    /// the events of those that go up for the readers into `queue`, each
    /// at `time`.
    pub fn letGo(m: *Mouse, own: *u32, queue: *Queue, time: TimeVal) void {
        for (buttons) |b| {
            if (own.* & b.bit == 0) continue;
            var e = m.button(own, b.code | ie.IECODE_UP_PREFIX, m.relative != 0) orelse continue;
            e.time = time;
            queue.push(e);
        }
    }

    /// The wheel turned by `across` notches right and `down` notches down
    /// (left and up negative): an IECODE_WHEEL event, its counts in `x`
    /// and `y`, with the buttons down as its qualifiers.
    pub fn wheel(m: *const Mouse, across: i32, down: i32) InputEvent {
        return .{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_WHEEL, .qualifier = m.qualifier, .x = across, .y = down };
    }

    fn event(m: *const Mouse, code: u32, relative: bool) InputEvent {
        if (relative) return .{ .class = ie.IECLASS_RAWMOUSE, .code = code, .qualifier = m.qualifier | ie.IEQUALIFIER_RELATIVEMOUSE };
        return .{ .class = ie.IECLASS_RAWMOUSE, .subclass = m.subclass, .code = code, .qualifier = m.qualifier, .x = m.x, .y = m.y };
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
    var own: u32 = 0;
    var out: [4]InputEvent = undefined;

    // Moved and the right button went down: the move, then the button.
    try testing.expectEqual(@as(usize, 2), m.change(&own, .{ .x = 10, .y = 20, .left = false, .right = true, .middle = false }, &out));
    try testing.expectEqual(ie.IECLASS_RAWMOUSE, out[0].class);
    try testing.expectEqual(ie.IECODE_NOBUTTON, out[0].code);
    try testing.expectEqual(@as(i32, 10), out[0].x);
    try testing.expectEqual(@as(u32, 0), out[0].qualifier);
    try testing.expectEqual(ie.IECODE_RBUTTON, out[1].code);
    try testing.expectEqual(ie.IEQUALIFIER_RBUTTON, out[1].qualifier);
    try testing.expectEqual(@as(i32, 20), out[1].y);

    // Nothing changed: nothing.
    try testing.expectEqual(@as(usize, 0), m.change(&own, .{ .x = 10, .y = 20, .left = false, .right = true, .middle = false }, &out));

    // Left and middle down together, right up: left, right, middle in turn.
    try testing.expectEqual(@as(usize, 3), m.change(&own, .{ .x = 10, .y = 20, .left = true, .right = false, .middle = true }, &out));
    try testing.expectEqual(ie.IECODE_LBUTTON, out[0].code);
    try testing.expectEqual(ie.IEQUALIFIER_LEFTBUTTON | ie.IEQUALIFIER_RBUTTON, out[0].qualifier);
    try testing.expectEqual(ie.IECODE_RBUTTON | ie.IECODE_UP_PREFIX, out[1].code);
    try testing.expectEqual(ie.IEQUALIFIER_LEFTBUTTON, out[1].qualifier);
    try testing.expectEqual(ie.IECODE_MBUTTON, out[2].code);
    try testing.expectEqual(ie.IEQUALIFIER_LEFTBUTTON | ie.IEQUALIFIER_MIDBUTTON, out[2].qualifier);
}

test "the wheel: its notches in x and y, the buttons down as its qualifiers" {
    var m = Mouse{};
    var own: u32 = 0;
    var out: [4]InputEvent = undefined;
    _ = m.change(&own, .{ .x = 5, .y = 6, .left = true, .right = false, .middle = false }, &out);
    const turned = m.wheel(0, -2);
    try testing.expectEqual(ie.IECLASS_RAWMOUSE, turned.class);
    try testing.expectEqual(ie.IECODE_WHEEL, turned.code);
    try testing.expectEqual(@as(i32, 0), turned.x);
    try testing.expectEqual(@as(i32, -2), turned.y);
    try testing.expectEqual(ie.IEQUALIFIER_LEFTBUTTON, turned.qualifier);
}

test "sources: a button held on two is down once, up when the last lets go" {
    var m = Mouse{};
    var one: u32 = 0;
    var two: u32 = 0;
    var out: [2]InputEvent = undefined;
    const press = InputEvent{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_LBUTTON, .qualifier = ie.IEQUALIFIER_RELATIVEMOUSE };
    const release = InputEvent{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, .qualifier = ie.IEQUALIFIER_RELATIVEMOUSE };
    try testing.expectEqual(@as(usize, 1), m.take(&one, &press, &out));
    try testing.expectEqual(ie.IECODE_LBUTTON, out[0].code);
    try testing.expectEqual(ie.IEQUALIFIER_LEFTBUTTON | ie.IEQUALIFIER_RELATIVEMOUSE, out[0].qualifier);
    try testing.expectEqual(@as(usize, 0), m.take(&two, &press, &out));
    try testing.expectEqual(@as(usize, 0), m.take(&one, &release, &out));
    try testing.expectEqual(ie.IEQUALIFIER_LEFTBUTTON, m.qualifier);
    try testing.expectEqual(@as(usize, 1), m.take(&two, &release, &out));
    try testing.expectEqual(ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, out[0].code);
    try testing.expectEqual(@as(u32, 0), m.qualifier);
}

test "sources: a distance is passed on as one, a place moves the pointer" {
    var m = Mouse{};
    var own: u32 = 0;
    var out: [2]InputEvent = undefined;
    const nudge = InputEvent{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_NOBUTTON, .qualifier = ie.IEQUALIFIER_RELATIVEMOUSE, .x = 3, .y = -2 };
    try testing.expectEqual(@as(usize, 1), m.take(&own, &nudge, &out));
    try testing.expectEqual(@as(i32, 3), out[0].x);
    try testing.expectEqual(@as(i32, -2), out[0].y);
    try testing.expect(out[0].qualifier & ie.IEQUALIFIER_RELATIVEMOUSE != 0);
    try testing.expectEqual(ie.IEQUALIFIER_RELATIVEMOUSE, m.relative);
    // No distance and no button: nothing.
    const still = InputEvent{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_NOBUTTON, .qualifier = ie.IEQUALIFIER_RELATIVEMOUSE };
    try testing.expectEqual(@as(usize, 0), m.take(&own, &still, &out));
    // A place and a click there: the move to it, then the button at it.
    const click = InputEvent{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_RBUTTON, .x = 40, .y = 50 };
    try testing.expectEqual(@as(usize, 2), m.take(&own, &click, &out));
    try testing.expectEqual(ie.IECODE_NOBUTTON, out[0].code);
    try testing.expectEqual(@as(i32, 40), out[0].x);
    try testing.expectEqual(@as(u32, 0), out[0].qualifier);
    try testing.expectEqual(ie.IECODE_RBUTTON, out[1].code);
    try testing.expectEqual(@as(i32, 50), out[1].y);
    try testing.expectEqual(@as(u32, 0), m.relative);
    // Not a mouse's event: nothing.
    const key = InputEvent{ .class = ie.IECLASS_RAWKEY, .code = 0x20 };
    try testing.expectEqual(@as(usize, 0), m.take(&own, &key, &out));
}

test "sources: a tablet's place, and a button there, keep the tablet's subclass" {
    var m = Mouse{};
    var own: u32 = 0;
    var out: [2]InputEvent = undefined;
    const press = InputEvent{ .class = ie.IECLASS_RAWMOUSE, .subclass = ie.IESUBCLASS_TABLET, .code = ie.IECODE_LBUTTON, .x = 0x8000, .y = 0x4000 };
    try testing.expectEqual(@as(usize, 2), m.take(&own, &press, &out));
    try testing.expectEqual(ie.IESUBCLASS_TABLET, out[0].subclass);
    try testing.expectEqual(@as(i32, 0x8000), out[0].x);
    try testing.expectEqual(ie.IESUBCLASS_TABLET, out[1].subclass);
    // The same numbers as pixels are another place.
    const pixel = InputEvent{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_NOBUTTON, .x = 0x8000, .y = 0x4000 };
    try testing.expectEqual(@as(usize, 1), m.take(&own, &pixel, &out));
    try testing.expectEqual(@as(u32, 0), out[0].subclass);
}

test "sources: one that goes away lets go of its buttons, not of the others'" {
    var m = Mouse{};
    var gone: u32 = 0;
    var stays: u32 = 0;
    _ = m.button(&gone, ie.IECODE_LBUTTON, true);
    _ = m.button(&gone, ie.IECODE_MBUTTON, true);
    _ = m.button(&stays, ie.IECODE_LBUTTON, true);
    var q: Queue = .{};
    m.letGo(&gone, &q, .{ .secs = 3 });
    try testing.expectEqual(@as(usize, 1), q.count);
    var got: [1]InputEvent = undefined;
    _ = q.take(&got);
    try testing.expectEqual(ie.IECODE_MBUTTON | ie.IECODE_UP_PREFIX, got[0].code);
    try testing.expectEqual(@as(u32, 3), got[0].time.secs);
    try testing.expectEqual(ie.IEQUALIFIER_LEFTBUTTON, m.qualifier);
    try testing.expectEqual(@as(u32, 0), gone);
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
