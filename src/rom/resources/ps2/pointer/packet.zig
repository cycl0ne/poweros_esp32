// SPDX-License-Identifier: MPL-2.0
//! A PS/2 pointing device's bytes read as what it did: a mouse, a
//! TrackPoint or a touchpad in the mode they all start in, which sends a
//! packet for every move and every button. Nothing here touches hardware,
//! so the host tests hold it.
//!
//! A packet is three bytes: the buttons and the signs in the first - its
//! bit 3 always set, which is how a reader that lost its place finds a
//! packet's start again - then how far it went across and up, each nine
//! bits with its sign in the first byte. A device that said it has a
//! wheel sends a fourth byte, the wheel's notches. A move that overflowed
//! its nine bits is dropped: what it says is not how far the device went.
//!
//! What a packet did becomes the events mouse.device takes from a source
//! (`MOUSE_ADDEVENT`): a move, how far it went with down counted up; each
//! button that changed, pressed or let go; the wheel's notches.

const sdk = @import("sdk");
const ie = sdk.devices.inputevent;

/// The most events one packet makes: a move, three buttons, the wheel.
pub const events_most = 5;

/// The first byte's bits.
const LEFT: u8 = 1 << 0;
const RIGHT: u8 = 1 << 1;
const MIDDLE: u8 = 1 << 2;
const ALWAYS: u8 = 1 << 3;
const X_SIGN: u8 = 1 << 4;
const Y_SIGN: u8 = 1 << 5;
const OVERFLOW: u8 = 0xC0;

const button_bits = [3]u8{ LEFT, RIGHT, MIDDLE };
const button_codes = [3]u32{ ie.IECODE_LBUTTON, ie.IECODE_RBUTTON, ie.IECODE_MBUTTON };

/// The device's bytes as they come, one at a time.
pub const Decoder = struct {
    /// Whether packets are four bytes, the last the wheel.
    wheel: bool = false,
    bytes: [4]u8 = @splat(0),
    count: u8 = 0,
    /// The buttons the last packet had down.
    buttons: u8 = 0,

    /// `byte` taken; when it completes a packet, what the packet did
    /// written to `events` and how many of them there are, else 0.
    pub fn feed(decoder: *Decoder, byte: u8, events: *[events_most]ie.InputEvent) usize {
        // A first byte without the bit every first byte has is not one:
        // the reader lost its place, and finds it again here.
        if (decoder.count == 0 and byte & ALWAYS == 0) return 0;
        decoder.bytes[decoder.count] = byte;
        decoder.count += 1;
        const length: u8 = if (decoder.wheel) 4 else 3;
        if (decoder.count < length) return 0;
        decoder.count = 0;

        const first = decoder.bytes[0];
        var count: usize = 0;
        if (first & OVERFLOW == 0) {
            const across: i32 = @as(i32, decoder.bytes[1]) - (if (first & X_SIGN != 0) @as(i32, 256) else 0);
            const up: i32 = @as(i32, decoder.bytes[2]) - (if (first & Y_SIGN != 0) @as(i32, 256) else 0);
            if (across != 0 or up != 0) {
                events[count] = .{
                    .class = ie.IECLASS_RAWMOUSE,
                    .code = ie.IECODE_NOBUTTON,
                    .qualifier = ie.IEQUALIFIER_RELATIVEMOUSE,
                    .x = across,
                    .y = -up,
                };
                count += 1;
            }
        }
        const now = first & (LEFT | RIGHT | MIDDLE);
        const changed = now ^ decoder.buttons;
        for (button_bits, button_codes) |bit, code| {
            if (changed & bit == 0) continue;
            events[count] = .{
                .class = ie.IECLASS_RAWMOUSE,
                .code = if (now & bit != 0) code else code | ie.IECODE_UP_PREFIX,
                .qualifier = ie.IEQUALIFIER_RELATIVEMOUSE,
            };
            count += 1;
        }
        decoder.buttons = now;
        if (decoder.wheel) {
            const notches: i32 = @as(i8, @bitCast(decoder.bytes[3]));
            if (notches != 0) {
                events[count] = .{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_WHEEL, .y = notches };
                count += 1;
            }
        }
        return count;
    }
};

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

test "a move, with down counted up, and a button pressed and let go" {
    var decoder = Decoder{};
    var events: [events_most]ie.InputEvent = undefined;
    try testing.expectEqual(@as(usize, 0), decoder.feed(ALWAYS | LEFT | Y_SIGN, &events));
    try testing.expectEqual(@as(usize, 0), decoder.feed(3, &events));
    // Three across, and 0xFE with its sign set: two down.
    try testing.expectEqual(@as(usize, 2), decoder.feed(0xFE, &events));
    try testing.expectEqual(@as(i32, 3), events[0].x);
    try testing.expectEqual(@as(i32, 2), events[0].y);
    try testing.expectEqual(ie.IEQUALIFIER_RELATIVEMOUSE, events[0].qualifier);
    try testing.expectEqual(ie.IECODE_LBUTTON, events[1].code);
    // Let go, without a move.
    _ = decoder.feed(ALWAYS, &events);
    _ = decoder.feed(0, &events);
    try testing.expectEqual(@as(usize, 1), decoder.feed(0, &events));
    try testing.expectEqual(ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, events[0].code);
}

test "a byte that cannot start a packet is passed over, and a wheel is the fourth byte" {
    var decoder = Decoder{ .wheel = true };
    var events: [events_most]ie.InputEvent = undefined;
    try testing.expectEqual(@as(usize, 0), decoder.feed(0x01, &events));
    try testing.expectEqual(@as(u8, 0), decoder.count);
    _ = decoder.feed(ALWAYS, &events);
    _ = decoder.feed(0, &events);
    _ = decoder.feed(0, &events);
    try testing.expectEqual(@as(usize, 1), decoder.feed(0xFF, &events));
    try testing.expectEqual(ie.IECODE_WHEEL, events[0].code);
    try testing.expectEqual(@as(i32, -1), events[0].y);
}
