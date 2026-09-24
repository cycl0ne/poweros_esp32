// SPDX-License-Identifier: MPL-2.0
//! What input.device does to an event before and while it goes down the
//! chain - the parts that need no task and no hardware, so the host tests
//! can hold them.
//!
//! - `Pointer` turns fingers into the pointer: the first finger down is the
//!   pointer until it lifts, and any finger that lands while it is down is
//!   a finger and nothing more. So a program that knows only the pointer
//!   works with the panel, and one that wants every finger still gets them.
//! - `repeats` says which keys a held key repeats for: every key but the
//!   modifiers.
//! - `keyQualifier` puts a key's qualifiers into the device's own, leaving
//!   the pointer's buttons alone.
//! - `dispatch` walks the handler chain.

const sdk = @import("sdk");
const exec = sdk.exec;
const ie = sdk.devices.inputevent;
const touch = sdk.devices.touch;
const InputEvent = ie.InputEvent;
const InputHandlerFn = sdk.devices.input.InputHandlerFn;

/// The qualifier bits a key sets: the modifiers and Caps Lock.
pub const key_qualifiers: u32 = 0x00FF;
/// The qualifier bits the pointer's buttons set.
pub const button_qualifiers: u32 = ie.IEQUALIFIER_LEFTBUTTON | ie.IEQUALIFIER_RBUTTON | ie.IEQUALIFIER_MIDBUTTON;

/// The device's qualifiers after a key whose event carried `from_key`.
pub fn keyQualifier(current: u32, from_key: u32) u32 {
    return (current & ~key_qualifiers) | (from_key & key_qualifiers);
}

/// Whether holding the key repeats it. The modifiers (0x60-0x67) never do.
pub fn repeats(rawkey: u32) bool {
    const code = rawkey & ie.IECODE_KEY_CODE_MASK;
    return code < 0x60 or code > 0x67;
}

/// A key down as the keys after it carry it in `x` and `y`: the rawkey and
/// the low byte of its qualifiers, marked as there.
pub fn prevKey(code: u32, qualifier: u32) i32 {
    return @bitCast(ie.IE_PREVKEY_VALID | (code & 0xFF) << 8 | (qualifier & 0xFF));
}

/// Which finger is the pointer.
pub const Pointer = extern struct {
    /// The pointer finger's contact id; meaningful while `down` is set.
    id: u32 = 0,
    down: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },

    /// One finger's event as the chain sees it: the finger itself, and when
    /// it is the pointer's, the pointer after it, linked. The qualifiers are
    /// brought up to date. Answers how many of `out` it filled.
    pub fn take(p: *Pointer, e: *const touch.TouchEvent, qualifier: *u32, out: *[2]InputEvent) usize {
        var code: u32 = ie.IECODE_NOBUTTON;
        var is_pointer = false;
        switch (e.kind) {
            touch.TOUCH_DOWN => if (p.down == 0) {
                p.down = 1;
                p.id = e.id;
                is_pointer = true;
                code = ie.IECODE_LBUTTON;
                qualifier.* |= ie.IEQUALIFIER_LEFTBUTTON;
            },
            touch.TOUCH_MOVE => is_pointer = p.down != 0 and p.id == e.id,
            touch.TOUCH_UP => if (p.down != 0 and p.id == e.id) {
                p.down = 0;
                is_pointer = true;
                code = ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX;
                qualifier.* &= ~ie.IEQUALIFIER_LEFTBUTTON;
            },
            else => return 0,
        }
        out[0] = .{
            .class = ie.IECLASS_TOUCH,
            .subclass = e.kind,
            .code = e.id,
            .qualifier = qualifier.*,
            .x = e.x,
            .y = e.y,
        };
        if (!is_pointer) return 1;
        out[1] = .{
            .class = ie.IECLASS_NEWPOINTERPOS,
            .code = code,
            .qualifier = qualifier.*,
            .x = e.x,
            .y = e.y,
        };
        out[0].next = &out[1];
        return 2;
    }
};

/// A mouse event as the chain sees it: the event itself, with the device's
/// qualifiers brought up to date by the buttons it carries, and for a mouse
/// that says where it is the pointer after it, the same button, linked. A
/// mouse that says only how far it went (IEQUALIFIER_RELATIVEMOUSE) has no
/// pointer to give. Answers how many of `out` it filled.
pub fn mousePointer(e: *const InputEvent, qualifier: *u32, out: *[2]InputEvent) usize {
    qualifier.* = (qualifier.* & ~button_qualifiers) | (e.qualifier & button_qualifiers);
    const relative = e.qualifier & ie.IEQUALIFIER_RELATIVEMOUSE;
    out[0] = .{
        .class = ie.IECLASS_RAWMOUSE,
        .code = e.code,
        .qualifier = qualifier.* | relative,
        .x = e.x,
        .y = e.y,
    };
    if (relative != 0) return 1;
    out[1] = .{
        .class = ie.IECLASS_NEWPOINTERPOS,
        .code = e.code,
        .qualifier = qualifier.*,
        .x = e.x,
        .y = e.y,
    };
    out[0].next = &out[1];
    return 2;
}

/// The events down the chain on `handlers` (exec.Interrupts, highest
/// priority first): each handler gets what the one before returned, and
/// the walk ends at the last handler or at one that returns nothing.
pub fn dispatch(handlers: *exec.List, events: *InputEvent) void {
    var list: ?*InputEvent = events;
    var it = handlers.iterator();
    while (it.next()) |n| {
        const int: *exec.Interrupt = @ptrCast(n);
        const handler: InputHandlerFn = @ptrCast(@alignCast(int.code.?));
        list = handler(list, int.data);
        if (list == null) break;
    }
}

// --- tests ------------------------------------------------------------------------

const testing = @import("std").testing;

test "qualifiers: a key replaces the key bits and keeps the buttons" {
    const held = ie.IEQUALIFIER_LEFTBUTTON | ie.IEQUALIFIER_LSHIFT;
    const after = keyQualifier(held, ie.IEQUALIFIER_CONTROL | ie.IEQUALIFIER_NUMERICPAD);
    try testing.expectEqual(ie.IEQUALIFIER_LEFTBUTTON | ie.IEQUALIFIER_CONTROL, after);
}

test "prevKey: the rawkey and the low qualifiers, marked as there" {
    const w: u32 = @bitCast(prevKey(0x0C, ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_LEFTBUTTON));
    try testing.expect(w & ie.IE_PREVKEY_VALID != 0);
    try testing.expectEqual(@as(u32, 0x0C), (w >> 8) & 0xFF);
    try testing.expectEqual(ie.IEQUALIFIER_LSHIFT, w & 0xFF);
    // Rawkey 0 with nothing held is still a key, unlike 0.
    try testing.expect(prevKey(0, 0) != 0);
}

test "repeats: everything but the modifiers" {
    try testing.expect(repeats(0x20));
    try testing.expect(repeats(0x4C)); // cursor up
    try testing.expect(repeats(0x6F)); // F12
    try testing.expect(!repeats(0x60));
    try testing.expect(!repeats(0x67));
    try testing.expect(repeats(0x20 | ie.IECODE_UP_PREFIX));
}

test "pointer: the first finger is the pointer, a second is only a finger" {
    var p: Pointer = .{};
    var q: u32 = ie.IEQUALIFIER_LSHIFT;
    var out: [2]InputEvent = undefined;

    // The first finger lands: a touch, then the button going down there.
    try testing.expectEqual(@as(usize, 2), p.take(&.{ .kind = touch.TOUCH_DOWN, .id = 3, .x = 10, .y = 20 }, &q, &out));
    try testing.expectEqual(ie.IECLASS_TOUCH, out[0].class);
    try testing.expectEqual(touch.TOUCH_DOWN, out[0].subclass);
    try testing.expectEqual(@as(u32, 3), out[0].code);
    try testing.expectEqual(&out[1], out[0].next.?);
    try testing.expectEqual(ie.IECLASS_NEWPOINTERPOS, out[1].class);
    try testing.expectEqual(ie.IECODE_LBUTTON, out[1].code);
    try testing.expectEqual(@as(i32, 10), out[1].x);
    try testing.expectEqual(ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_LEFTBUTTON, out[1].qualifier);

    // A second finger lands and moves: fingers only.
    try testing.expectEqual(@as(usize, 1), p.take(&.{ .kind = touch.TOUCH_DOWN, .id = 4 }, &q, &out));
    try testing.expectEqual(@as(usize, 1), p.take(&.{ .kind = touch.TOUCH_MOVE, .id = 4 }, &q, &out));

    // The pointer finger moves: a position with no button change.
    try testing.expectEqual(@as(usize, 2), p.take(&.{ .kind = touch.TOUCH_MOVE, .id = 3, .x = 12, .y = 20 }, &q, &out));
    try testing.expectEqual(ie.IECODE_NOBUTTON, out[1].code);

    // It lifts: the button goes up, and the qualifier with it.
    try testing.expectEqual(@as(usize, 2), p.take(&.{ .kind = touch.TOUCH_UP, .id = 3, .x = 12, .y = 20 }, &q, &out));
    try testing.expectEqual(ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, out[1].code);
    try testing.expectEqual(ie.IEQUALIFIER_LSHIFT, q);

    // The second finger does not become the pointer by staying down.
    try testing.expectEqual(@as(usize, 1), p.take(&.{ .kind = touch.TOUCH_UP, .id = 4 }, &q, &out));
    // The next finger to land does.
    try testing.expectEqual(@as(usize, 2), p.take(&.{ .kind = touch.TOUCH_DOWN, .id = 4 }, &q, &out));
}

fn addTail(list: *exec.List, node: *exec.Node) void {
    const pred = list.tail_pred.?;
    node.succ = list.tailNode();
    node.pred = pred;
    pred.succ = node;
    list.tail_pred = node;
}

fn remove(node: *exec.Node) void {
    node.pred.?.succ = node.succ;
    node.succ.?.pred = node.pred;
}

const Seen = struct { calls: u32 = 0, swallow: bool = false };

fn counting(events: ?*InputEvent, data: ?*anyopaque) callconv(.c) ?*InputEvent {
    const seen: *Seen = @ptrCast(@alignCast(data.?));
    seen.calls += 1;
    if (seen.swallow) return null;
    events.?.code += 1;
    return events;
}

test "dispatch: by priority, each seeing the last one's output, a null ends it" {
    var handlers: exec.List = .{};
    handlers.init(.interrupt);
    var a: Seen = .{};
    var b: Seen = .{ .swallow = true };
    var c: Seen = .{};
    var ia: exec.Interrupt = .{ .node = .{ .type = .interrupt, .pri = 50 }, .data = &a, .code = &counting };
    var ib: exec.Interrupt = .{ .node = .{ .type = .interrupt, .pri = 20 }, .data = &b, .code = &counting };
    var ic: exec.Interrupt = .{ .node = .{ .type = .interrupt, .pri = 10 }, .data = &c, .code = &counting };
    // In order, highest first, as Enqueue leaves them.
    addTail(&handlers, &ia.node);
    addTail(&handlers, &ib.node);
    addTail(&handlers, &ic.node);

    var e: InputEvent = .{ .code = 0 };
    dispatch(&handlers, &e);
    try testing.expectEqual(@as(u32, 1), a.calls);
    try testing.expectEqual(@as(u32, 1), b.calls);
    try testing.expectEqual(@as(u32, 0), c.calls);
    try testing.expectEqual(@as(u32, 1), e.code);

    // With the middle one gone, the last sees what the first changed.
    b.swallow = false;
    remove(&ib.node);
    dispatch(&handlers, &e);
    try testing.expectEqual(@as(u32, 1), c.calls);
    try testing.expectEqual(@as(u32, 3), e.code);
}

test "mousePointer: the raw event, the qualifiers kept, and the pointer after it" {
    var qualifier: u32 = ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_LEFTBUTTON;
    var out: [2]InputEvent = undefined;
    const right = InputEvent{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_RBUTTON, .qualifier = ie.IEQUALIFIER_RBUTTON, .x = 7, .y = 9 };
    try testing.expectEqual(@as(usize, 2), mousePointer(&right, &qualifier, &out));
    // The keys' qualifiers stay; the buttons are the mouse's now.
    try testing.expectEqual(ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RBUTTON, qualifier);
    try testing.expectEqual(ie.IECLASS_RAWMOUSE, out[0].class);
    try testing.expectEqual(&out[1], out[0].next.?);
    try testing.expectEqual(ie.IECLASS_NEWPOINTERPOS, out[1].class);
    try testing.expectEqual(ie.IECODE_RBUTTON, out[1].code);
    try testing.expectEqual(@as(i32, 7), out[1].x);
    try testing.expectEqual(qualifier, out[1].qualifier);

    // A mouse that says how far it went: the raw event alone.
    const nudge = InputEvent{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_NOBUTTON, .qualifier = ie.IEQUALIFIER_RELATIVEMOUSE, .x = 3, .y = -1 };
    try testing.expectEqual(@as(usize, 1), mousePointer(&nudge, &qualifier, &out));
    try testing.expect(out[0].next == null);
    try testing.expectEqual(ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RELATIVEMOUSE, out[0].qualifier);
}
