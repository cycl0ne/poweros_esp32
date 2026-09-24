// SPDX-License-Identifier: MPL-2.0
//! What keyboard.device makes of a key - the parts that need no hardware,
//! so the host tests can hold them.
//!
//! A key arrives as some other system's code (the emulator's is Linux's)
//! and leaves as a **rawkey**: the key's place on the keyboard, 0x00 to
//! 0x77. The table below goes by position, so the key left of S is 0x20
//! whatever is printed on it, and a keymap above the device decides what it
//! means. PC keys with no place in that layout take codes the range leaves
//! free: Insert 0x47, Page Up 0x48, Page Down 0x49, F11 0x4B, F12 0x6F,
//! Home 0x70, End 0x71; the Windows keys are the Amiga keys, and there is
//! one Control.
//!
//! `Keys` keeps what a stream of keys adds up to - which modifiers are held
//! and which keys are down - and turns each key into its event. A modifier
//! sets its qualifier going down and clears it going up; Caps Lock toggles
//! its qualifier each time it goes down; a keypad key carries NUMERICPAD.

const sdk = @import("sdk");
const ie = sdk.devices.inputevent;
const kb = sdk.devices.keyboard;
const InputEvent = ie.InputEvent;

/// No rawkey for this code.
pub const none: u8 = 0xFF;

/// Linux keycodes (the KEY_ numbers) into rawkeys.
pub const from_linux: [256]u8 = blk: {
    var t: [256]u8 = @splat(none);
    const pairs = [_][2]u16{
        // The top row: ` 1-0 - = and backspace.
        .{ 41, 0x00 },  .{ 2, 0x01 },   .{ 3, 0x02 },   .{ 4, 0x03 },   .{ 5, 0x04 },
        .{ 6, 0x05 },   .{ 7, 0x06 },   .{ 8, 0x07 },   .{ 9, 0x08 },   .{ 10, 0x09 },
        .{ 11, 0x0A },  .{ 12, 0x0B },  .{ 13, 0x0C },  .{ 43, 0x0D },  .{ 14, 0x41 },
        // Q to P, [ ], return.
        .{ 15, 0x42 },  .{ 16, 0x10 },  .{ 17, 0x11 },  .{ 18, 0x12 },  .{ 19, 0x13 },
        .{ 20, 0x14 },  .{ 21, 0x15 },  .{ 22, 0x16 },  .{ 23, 0x17 },  .{ 24, 0x18 },
        .{ 25, 0x19 },  .{ 26, 0x1A },  .{ 27, 0x1B },  .{ 28, 0x44 },
        // A to L, ; '.
         .{ 30, 0x20 },
        .{ 31, 0x21 },  .{ 32, 0x22 },  .{ 33, 0x23 },  .{ 34, 0x24 },  .{ 35, 0x25 },
        .{ 36, 0x26 },  .{ 37, 0x27 },  .{ 38, 0x28 },  .{ 39, 0x29 },  .{ 40, 0x2A },
        // The key between left shift and Z, then Z to M , . /.
        .{ 86, 0x30 },  .{ 44, 0x31 },  .{ 45, 0x32 },  .{ 46, 0x33 },  .{ 47, 0x34 },
        .{ 48, 0x35 },  .{ 49, 0x36 },  .{ 50, 0x37 },  .{ 51, 0x38 },  .{ 52, 0x39 },
        .{ 53, 0x3A },
        // Space, escape, delete, help.
         .{ 57, 0x40 },  .{ 1, 0x45 },   .{ 111, 0x46 }, .{ 138, 0x5F },
        // The cursor keys.
        .{ 103, 0x4C }, .{ 108, 0x4D }, .{ 106, 0x4E }, .{ 105, 0x4F },
        // F1 to F10, and F11, F12.
        .{ 59, 0x50 },
        .{ 60, 0x51 },  .{ 61, 0x52 },  .{ 62, 0x53 },  .{ 63, 0x54 },  .{ 64, 0x55 },
        .{ 65, 0x56 },  .{ 66, 0x57 },  .{ 67, 0x58 },  .{ 68, 0x59 },  .{ 87, 0x4B },
        .{ 88, 0x6F },
        // The modifiers: shifts, caps lock, control (either), alts, and the
        // Windows keys as the Amiga keys.
         .{ 42, 0x60 },  .{ 54, 0x61 },  .{ 58, 0x62 },  .{ 29, 0x63 },
        .{ 97, 0x63 },  .{ 56, 0x64 },  .{ 100, 0x65 }, .{ 125, 0x66 }, .{ 126, 0x67 },
        // Insert, Page Up, Page Down, Home, End.
        .{ 110, 0x47 }, .{ 104, 0x48 }, .{ 109, 0x49 }, .{ 102, 0x70 }, .{ 107, 0x71 },
        // The keypad.
        .{ 82, 0x0F },  .{ 79, 0x1D },  .{ 80, 0x1E },  .{ 81, 0x1F },  .{ 75, 0x2D },
        .{ 76, 0x2E },  .{ 77, 0x2F },  .{ 83, 0x3C },  .{ 71, 0x3D },  .{ 72, 0x3E },
        .{ 73, 0x3F },  .{ 74, 0x4A },  .{ 96, 0x43 },  .{ 98, 0x5C },  .{ 55, 0x5D },
        .{ 78, 0x5E },
    };
    for (pairs) |p| t[p[0]] = @intCast(p[1]);
    break :blk t;
};

/// A Linux keycode's rawkey, or null for a key with none.
pub fn fromLinux(code: u32) ?u8 {
    if (code >= from_linux.len) return null;
    const r = from_linux[code];
    return if (r == none) null else r;
}

fn isKeypad(rawkey: u8) bool {
    return switch (rawkey) {
        0x0F, 0x1D, 0x1E, 0x1F, 0x2D, 0x2E, 0x2F, 0x3C, 0x3D, 0x3E, 0x3F, 0x43, 0x4A, 0x5A...0x5E => true,
        else => false,
    };
}

/// A modifier's qualifier bit, or 0 for a key that is not one.
fn modifier(rawkey: u8) u32 {
    return switch (rawkey) {
        0x60 => ie.IEQUALIFIER_LSHIFT,
        0x61 => ie.IEQUALIFIER_RSHIFT,
        0x63 => ie.IEQUALIFIER_CONTROL,
        0x64 => ie.IEQUALIFIER_LALT,
        0x65 => ie.IEQUALIFIER_RALT,
        0x66 => ie.IEQUALIFIER_LCOMMAND,
        0x67 => ie.IEQUALIFIER_RCOMMAND,
        else => 0,
    };
}

/// What a stream of keys adds up to.
pub const Keys = extern struct {
    /// The held modifiers and Caps Lock.
    qualifier: u32 = 0,
    /// A bit per rawkey that is down.
    matrix: [kb.MATRIX_BYTES]u8 = @splat(0),

    /// A key going down or up: the state brought up to date, and the event
    /// that says so.
    pub fn press(k: *Keys, rawkey: u8, down: bool) InputEvent {
        const bit: u8 = @as(u8, 1) << @intCast(rawkey % 8);
        if (down) k.matrix[rawkey / 8] |= bit else k.matrix[rawkey / 8] &= ~bit;
        const m = modifier(rawkey);
        if (m != 0) {
            if (down) k.qualifier |= m else k.qualifier &= ~m;
        } else if (rawkey == kb.RAWKEY_CAPSLOCK and down) {
            k.qualifier ^= ie.IEQUALIFIER_CAPSLOCK;
        }
        var q = k.qualifier;
        if (isKeypad(rawkey)) q |= ie.IEQUALIFIER_NUMERICPAD;
        return .{
            .class = ie.IECLASS_RAWKEY,
            .code = rawkey | (if (down) 0 else ie.IECODE_UP_PREFIX),
            .qualifier = q,
        };
    }

    pub fn isDown(k: *const Keys, rawkey: u8) bool {
        return k.matrix[rawkey / 8] & (@as(u8, 1) << @intCast(rawkey % 8)) != 0;
    }
};

/// Events waiting for a read. When it is full the oldest goes, so a slow
/// reader still sees a key come up.
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

test "the table: by position, the extended keys, nothing for the rest" {
    try testing.expectEqual(@as(?u8, kb.RAWKEY_A), fromLinux(30)); // KEY_A
    try testing.expectEqual(@as(?u8, kb.RAWKEY_Q), fromLinux(16)); // KEY_Q
    try testing.expectEqual(@as(?u8, kb.RAWKEY_Z), fromLinux(44)); // KEY_Z
    try testing.expectEqual(@as(?u8, 0x01), fromLinux(2)); // KEY_1
    try testing.expectEqual(@as(?u8, 0x0A), fromLinux(11)); // KEY_0
    try testing.expectEqual(@as(?u8, kb.RAWKEY_RETURN), fromLinux(28));
    try testing.expectEqual(@as(?u8, kb.RAWKEY_ESC), fromLinux(1));
    try testing.expectEqual(@as(?u8, kb.RAWKEY_UP), fromLinux(103));
    try testing.expectEqual(@as(?u8, kb.RAWKEY_F1), fromLinux(59));
    try testing.expectEqual(@as(?u8, kb.RAWKEY_F10), fromLinux(68));
    try testing.expectEqual(@as(?u8, kb.RAWKEY_F11), fromLinux(87));
    try testing.expectEqual(@as(?u8, kb.RAWKEY_F12), fromLinux(88));
    try testing.expectEqual(@as(?u8, kb.RAWKEY_HOME), fromLinux(102));
    try testing.expectEqual(@as(?u8, kb.RAWKEY_CONTROL), fromLinux(97)); // right control
    try testing.expectEqual(@as(?u8, kb.RAWKEY_LAMIGA), fromLinux(125)); // left Windows
    try testing.expect(fromLinux(99) == null); // SysRq
    try testing.expect(fromLinux(700) == null);
    // No two keys on one rawkey, but the two controls.
    var seen: [128]u8 = @splat(0);
    for (from_linux) |r| {
        if (r != none) seen[r] += 1;
    }
    for (seen, 0..) |n, r| {
        if (r == kb.RAWKEY_CONTROL) try testing.expectEqual(@as(u8, 2), n) else try testing.expect(n <= 1);
    }
}

test "keys: qualifiers held and toggled, the keypad marked, the matrix" {
    var k: Keys = .{};
    var e = k.press(kb.RAWKEY_LSHIFT, true);
    try testing.expectEqual(ie.IEQUALIFIER_LSHIFT, e.qualifier);
    e = k.press(kb.RAWKEY_A, true);
    try testing.expectEqual(ie.IECLASS_RAWKEY, e.class);
    try testing.expectEqual(kb.RAWKEY_A, e.code);
    try testing.expectEqual(ie.IEQUALIFIER_LSHIFT, e.qualifier);
    try testing.expect(k.isDown(kb.RAWKEY_A));
    e = k.press(kb.RAWKEY_A, false);
    try testing.expectEqual(kb.RAWKEY_A | ie.IECODE_UP_PREFIX, e.code);
    try testing.expect(!k.isDown(kb.RAWKEY_A));
    _ = k.press(kb.RAWKEY_LSHIFT, false);
    try testing.expectEqual(@as(u32, 0), k.qualifier);

    // Caps Lock toggles on each press, whatever its release does.
    _ = k.press(kb.RAWKEY_CAPSLOCK, true);
    _ = k.press(kb.RAWKEY_CAPSLOCK, false);
    try testing.expectEqual(ie.IEQUALIFIER_CAPSLOCK, k.qualifier);
    _ = k.press(kb.RAWKEY_CAPSLOCK, true);
    try testing.expectEqual(@as(u32, 0), k.qualifier);

    // A keypad key says so, without the qualifier staying.
    e = k.press(kb.RAWKEY_KP_ENTER, true);
    try testing.expect(e.qualifier & ie.IEQUALIFIER_NUMERICPAD != 0);
    try testing.expect(k.qualifier & ie.IEQUALIFIER_NUMERICPAD == 0);

    // Control and both alts at once.
    _ = k.press(kb.RAWKEY_CONTROL, true);
    _ = k.press(kb.RAWKEY_LALT, true);
    e = k.press(kb.RAWKEY_F12, true);
    try testing.expectEqual(ie.IEQUALIFIER_CONTROL | ie.IEQUALIFIER_LALT, e.qualifier);
}

test "queue: in order, linked, the oldest dropped when full" {
    var q: Queue = .{};
    for (0..3) |i| q.push(.{ .code = @intCast(i) });
    var got: [2]InputEvent = undefined;
    try testing.expectEqual(@as(usize, 2), q.take(&got));
    try testing.expectEqual(@as(u32, 0), got[0].code);
    try testing.expectEqual(&got[1], got[0].next.?);
    q.clear();
    for (0..Queue.capacity + 2) |i| q.push(.{ .code = @intCast(i) });
    var one: [1]InputEvent = undefined;
    _ = q.take(&one);
    try testing.expectEqual(@as(u32, 2), one[0].code);
}
