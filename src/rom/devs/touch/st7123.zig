// SPDX-License-Identifier: MPL-2.0
//! The touch controller built into an ST77922 panel: its registers and
//! what it reports, the parts that need no hardware, so the host tests can
//! hold them. What is the same whatever controller a board has is
//! `_touch.zig`.
//!
//! Its registers have 16-bit addresses, sent high byte first. It says how
//! many fingers it can follow and how large its panel is, and reports all
//! of them at once: a block from `reg_touch_info` whose first four bytes
//! are the report's own, then a slot a finger, seven bytes each. A slot
//! with its top bit clear holds no finger; the rest is the position, six
//! bits of it in the high byte, and how hard the finger presses.
//!
//! The report is read from its first byte and in one transfer: the
//! controller makes it up as that read begins, so a read that starts at a
//! slot answers with what was there before.
//!
//! There is no id in a slot and nothing to write back: the slot a finger
//! is reported in is what tells one finger from another, so the slot is
//! the contact's id, and a slot that falls empty is a finger that lifted.

const sdk = @import("sdk");
const touch = sdk.devices.touch;
const TouchContact = touch.TouchContact;

// --- registers --------------------------------------------------------------------

/// The low four bits say what the controller is doing; `status_starting`
/// while it is still coming up.
pub const reg_status: u16 = 0x0001;
/// How large the panel is: the width and then the height, two bytes each,
/// high byte first.
pub const reg_range: u16 = 0x0005;
/// How many fingers this controller follows.
pub const reg_max_touches: u16 = 0x0009;
/// The report: four bytes of its own, then the slots.
pub const reg_touch_info: u16 = 0x0010;
/// Where the slots start, which is `slots_at` bytes into the report.
pub const reg_touch_data: u16 = 0x0014;
pub const slots_at: usize = reg_touch_data - reg_touch_info;
/// A slot, and the most any of these controllers has.
pub const slot_size: usize = 7;
pub const max_slots: usize = 10;

/// Still starting up, and not to be read yet.
pub const status_starting: u8 = 0x01;
pub const status_state_mask: u8 = 0x0F;
/// A slot holds a finger.
const slot_valid: u8 = 0x80;
/// What of the high byte of a coordinate is the coordinate.
const coord_high_mask: u8 = 0x3F;

/// How long the reset line is held down, and how long the controller
/// takes to come up after it is let go, in milliseconds. The line is
/// asserted low for at least 2 ms; the wait after is the controller's own
/// 20 ms and a little.
pub const reset_ms: u32 = 5;
pub const settle_ms: u32 = 30;

/// Whether the controller has finished starting up.
pub fn ready(status: u8) bool {
    return status & status_state_mask != status_starting;
}

/// The panel's size, from the four bytes at `reg_range`.
pub fn range(b: *const [4]u8) struct { width: u32, height: u32 } {
    return .{
        .width = @as(u32, b[0]) << 8 | b[1],
        .height = @as(u32, b[2]) << 8 | b[3],
    };
}

/// How many bytes to read for `max_touches` fingers, the report's own
/// four included.
pub fn reportBytes(max_touches: usize) usize {
    return slots_at + @min(max_touches, max_slots) * slot_size;
}

/// One slot: the finger in it, or null when it holds none. The slot is
/// the contact's id, so a finger keeps it for as long as it stays down.
pub fn contact(slot: usize, bytes: *const [slot_size]u8) ?TouchContact {
    if (bytes[0] & slot_valid == 0) return null;
    return .{
        .id = @intCast(slot),
        .x = @as(i32, bytes[0] & coord_high_mask) << 8 | bytes[1],
        .y = @as(i32, bytes[2] & coord_high_mask) << 8 | bytes[3],
        .size = bytes[5],
    };
}

/// The fingers in a report, into `into`. Answers how many there were.
pub fn decode(bytes: []const u8, into: []TouchContact) usize {
    if (bytes.len < slots_at) return 0;
    const count = (bytes.len - slots_at) / slot_size;
    var n: usize = 0;
    for (0..count) |slot| {
        if (n >= into.len) break;
        const at = bytes[slots_at + slot * slot_size ..][0..slot_size];
        if (contact(slot, at)) |c| {
            into[n] = c;
            n += 1;
        }
    }
    return n;
}

// --- tests --------------------------------------------------------------------------

const testing = @import("std").testing;

test "a report: the fingers in their slots, the empty ones passed over" {
    try testing.expect(!ready(0x01));
    try testing.expect(ready(0x00));
    try testing.expect(ready(0x82));

    try testing.expectEqual(@as(usize, 4 + 5 * 7), reportBytes(5));
    // More fingers than any of these controllers has are not read.
    try testing.expectEqual(@as(usize, 4 + 10 * 7), reportBytes(12));

    // A report of three slots: a finger in the first and the third.
    var report = [_]u8{0} ** (slots_at + 3 * slot_size);
    report[slots_at + 0] = 0x80 | 0x01;
    report[slots_at + 1] = 0x23;
    report[slots_at + 3] = 0x45;
    report[slots_at + 5] = 0x10;
    const third = slots_at + 2 * slot_size;
    report[third + 0] = 0x80 | (300 >> 8);
    report[third + 1] = 300 & 0xFF;
    report[third + 2] = 200 >> 8;
    report[third + 3] = 200 & 0xFF;
    report[third + 5] = 0x20;
    var seen: [5]TouchContact = undefined;
    try testing.expectEqual(@as(usize, 2), decode(&report, &seen));
    try testing.expectEqual(TouchContact{ .id = 0, .x = 0x123, .y = 0x45, .size = 0x10 }, seen[0]);
    try testing.expectEqual(TouchContact{ .id = 2, .x = 300, .y = 200, .size = 0x20 }, seen[1]);
    // A report cut short holds whole slots and no more.
    try testing.expectEqual(@as(usize, 1), decode(report[0 .. slots_at + slot_size], &seen));
    try testing.expectEqual(@as(usize, 0), decode(report[0..2], &seen));

    // A finger at (0x0123, 0x0045), pressed 0x10.
    const held = [slot_size]u8{ 0x80 | 0x01, 0x23, 0x00, 0x45, 0x00, 0x10, 0x00 };
    const one = contact(0, &held).?;
    try testing.expectEqual(TouchContact{ .id = 0, .x = 0x123, .y = 0x45, .size = 0x10 }, one);
    // The slot is the id, so the same bytes in another slot are another
    // finger.
    try testing.expectEqual(@as(u32, 2), contact(2, &held).?.id);
    // An empty slot holds nobody.
    const empty = [slot_size]u8{ 0x00, 0x23, 0x00, 0x45, 0x00, 0x10, 0x00 };
    try testing.expect(contact(0, &empty) == null);

    const size = [_]u8{ 0x01, 0x40, 0x01, 0xE0 };
    try testing.expectEqual(@as(u32, 320), range(&size).width);
    try testing.expectEqual(@as(u32, 480), range(&size).height);
}
