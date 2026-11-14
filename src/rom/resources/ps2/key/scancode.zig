// SPDX-License-Identifier: MPL-2.0
//! A PC keyboard's bytes read as keys: the scan codes the keyboard
//! controller hands over, in its first set - the one a controller
//! translates every keyboard's codes to - as rawkeys going down and up.
//! Nothing here touches hardware, so the host tests hold it.
//!
//! A key is one byte, its place on the keyboard: the same byte with the
//! top bit set when the key goes up. The keys a PC keyboard gained later
//! - the cursor block, the right Control and Alt, the keypad's Enter and
//! slash, the two system keys - send 0xE0 first and then a byte that is
//! another key's without it. Pause sends 0xE1 and two bytes more, and is
//! no key here. Print Screen and the cursor block with Num Lock on wrap
//! their byte in a Shift that nobody pressed (0xE0 0x2A, 0xE0 0x36): those
//! are dropped, since the real Shift keys say what they do themselves.
//!
//! The rawkeys are the places keyboard.device counts in, the same a USB
//! keyboard's keys are turned into: both Control keys are the one
//! Control, the two system keys the two Amiga keys. The byte 0x2B is the
//! key left of Return on a keyboard that has one there and the key above
//! Return on one that has it there; the controller does not say which,
//! and it is given the first's place, which a keymap for either kind of
//! keyboard has a character on.

/// No rawkey for this byte.
const none: u8 = 0xFF;

/// A key that went down or up.
pub const Key = struct {
    rawkey: u8,
    up: bool,
};

/// The bytes that are keys by themselves, as rawkeys.
const plain: [128]u8 = made: {
    var table: [128]u8 = @splat(none);
    const pairs = [_][2]u8{
        .{ 0x01, 0x45 }, // Esc
        .{ 0x0C, 0x0B },
        .{ 0x0D, 0x0C },
        .{ 0x0E, 0x41 },
        .{ 0x0F, 0x42 },
        .{ 0x1A, 0x1A },
        .{ 0x1B, 0x1B },
        .{ 0x1C, 0x44 },
        .{ 0x1D, 0x63 },
        .{ 0x27, 0x29 },
        .{ 0x28, 0x2A },
        .{ 0x29, 0x00 },
        .{ 0x2A, 0x60 },
        .{ 0x2B, 0x2B },
        .{ 0x33, 0x38 },
        .{ 0x34, 0x39 },
        .{ 0x35, 0x3A },
        .{ 0x36, 0x61 },
        .{ 0x37, 0x5D },
        .{ 0x38, 0x64 },
        .{ 0x39, 0x40 },
        .{ 0x3A, 0x62 },
        // The keypad: 7 8 9 - 4 5 6 + 1 2 3 0 .
        .{ 0x47, 0x3D },
        .{ 0x48, 0x3E },
        .{ 0x49, 0x3F },
        .{ 0x4A, 0x4A },
        .{ 0x4B, 0x2D },
        .{ 0x4C, 0x2E },
        .{ 0x4D, 0x2F },
        .{ 0x4E, 0x5E },
        .{ 0x4F, 0x1D },
        .{ 0x50, 0x1E },
        .{ 0x51, 0x1F },
        .{ 0x52, 0x0F },
        .{ 0x53, 0x3C },
        // The key right of the left Shift, F11, F12.
        .{ 0x56, 0x30 },
        .{ 0x57, 0x4B },
        .{ 0x58, 0x6F },
    };
    for (pairs) |pair| table[pair[0]] = pair[1];
    // 1 to 9 and 0; Q to P; A to L; Z to M; F1 to F10.
    for (0..10) |i| table[0x02 + i] = 0x01 + i;
    for (0..10) |i| table[0x10 + i] = 0x10 + i;
    for (0..9) |i| table[0x1E + i] = 0x20 + i;
    for (0..7) |i| table[0x2C + i] = 0x31 + i;
    for (0..10) |i| table[0x3B + i] = 0x50 + i;
    break :made table;
};

/// The bytes that follow 0xE0, as rawkeys.
const extended: [128]u8 = made: {
    var table: [128]u8 = @splat(none);
    const pairs = [_][2]u8{
        .{ 0x1C, 0x43 }, .{ 0x1D, 0x63 }, .{ 0x35, 0x5C }, .{ 0x38, 0x65 },
        // Home, Up, Page Up, Left, Right, End, Down, Page Down, Insert,
        // Delete.
        .{ 0x47, 0x70 }, .{ 0x48, 0x4C }, .{ 0x49, 0x48 }, .{ 0x4B, 0x4F },
        .{ 0x4D, 0x4E }, .{ 0x4F, 0x71 }, .{ 0x50, 0x4D }, .{ 0x51, 0x49 },
        .{ 0x52, 0x47 }, .{ 0x53, 0x46 },
        // The two system keys.
        .{ 0x5B, 0x66 }, .{ 0x5C, 0x67 },
    };
    for (pairs) |pair| table[pair[0]] = pair[1];
    break :made table;
};

/// The keyboard's bytes as they come, one at a time.
pub const Decoder = struct {
    /// The last byte was 0xE0.
    after_e0: bool = false,
    /// How many bytes of a Pause are still to come.
    skip: u8 = 0,

    /// The key `byte` completes, or null when it is part of one still
    /// coming, an answer of the keyboard's, or no key this knows.
    pub fn feed(decoder: *Decoder, byte: u8) ?Key {
        if (decoder.skip != 0) {
            decoder.skip -= 1;
            return null;
        }
        if (byte == 0xE0) {
            decoder.after_e0 = true;
            return null;
        }
        if (byte == 0xE1) {
            decoder.after_e0 = false;
            decoder.skip = 2;
            return null;
        }
        const table = if (decoder.after_e0) &extended else &plain;
        decoder.after_e0 = false;
        const rawkey = table[byte & 0x7F];
        if (rawkey == none) return null;
        return .{ .rawkey = rawkey, .up = byte & 0x80 != 0 };
    }
};

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

test "a key down and up, and the keys behind 0xE0" {
    var decoder = Decoder{};
    try testing.expectEqual(Key{ .rawkey = 0x20, .up = false }, decoder.feed(0x1E).?);
    try testing.expectEqual(Key{ .rawkey = 0x20, .up = true }, decoder.feed(0x9E).?);
    // The cursor's Up is the keypad's 8 behind 0xE0.
    try testing.expectEqual(@as(?Key, null), decoder.feed(0xE0));
    try testing.expectEqual(Key{ .rawkey = 0x4C, .up = false }, decoder.feed(0x48).?);
    try testing.expectEqual(Key{ .rawkey = 0x3E, .up = false }, decoder.feed(0x48).?);
    // Both Control keys are the one Control.
    try testing.expectEqual(Key{ .rawkey = 0x63, .up = false }, decoder.feed(0x1D).?);
    _ = decoder.feed(0xE0);
    try testing.expectEqual(Key{ .rawkey = 0x63, .up = true }, decoder.feed(0x9D).?);
}

test "a Shift nobody pressed, a Pause and the keyboard's answers are no keys" {
    var decoder = Decoder{};
    _ = decoder.feed(0xE0);
    try testing.expectEqual(@as(?Key, null), decoder.feed(0x2A));
    // Pause: 0xE1 and two bytes, then keys again.
    try testing.expectEqual(@as(?Key, null), decoder.feed(0xE1));
    try testing.expectEqual(@as(?Key, null), decoder.feed(0x1D));
    try testing.expectEqual(@as(?Key, null), decoder.feed(0x45));
    try testing.expectEqual(Key{ .rawkey = 0x40, .up = false }, decoder.feed(0x39).?);
    // An acknowledge.
    try testing.expectEqual(@as(?Key, null), decoder.feed(0xFA));
}

test "the rows of letters and digits lie where keyboard.device counts them" {
    var decoder = Decoder{};
    try testing.expectEqual(@as(u8, 0x01), decoder.feed(0x02).?.rawkey); // 1
    try testing.expectEqual(@as(u8, 0x0A), decoder.feed(0x0B).?.rawkey); // 0
    try testing.expectEqual(@as(u8, 0x10), decoder.feed(0x10).?.rawkey); // Q
    try testing.expectEqual(@as(u8, 0x28), decoder.feed(0x26).?.rawkey); // L
    try testing.expectEqual(@as(u8, 0x31), decoder.feed(0x2C).?.rawkey); // Z
    try testing.expectEqual(@as(u8, 0x37), decoder.feed(0x32).?.rawkey); // M
    try testing.expectEqual(@as(u8, 0x59), decoder.feed(0x44).?.rawkey); // F10
}
