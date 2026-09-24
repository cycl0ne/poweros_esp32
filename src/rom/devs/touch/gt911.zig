// SPDX-License-Identifier: MPL-2.0
//! The GT911 touch controller: its registers and what it reports, the
//! parts that need no hardware, so the host tests can hold them. What is
//! the same whatever controller a board has - the register address on the
//! wire, a report turned into events, the queue they wait in - is
//! `_touch.zig`.
//!
//! The controller keeps everything in registers with 16-bit addresses, sent
//! high byte first. When it has something to say it sets the top bit of the
//! status register, with the number of contacts in the low four; the
//! contacts follow, eight bytes each (a track id, x, y and size, the numbers
//! low byte first). Reading them is not enough - the status has to be
//! written back to 0, or the controller stops reporting.
//!

const sdk = @import("sdk");
const touch = sdk.devices.touch;
const TouchContact = touch.TouchContact;
const address = @import("_touch.zig").address;

// --- registers --------------------------------------------------------------------

/// Byte 6 of the configuration: bits 0-1 say how the interrupt line
/// signals, 0 rising, 1 falling, 2 low, 3 high.
pub const reg_module_switch1: u16 = 0x804D;
/// "911" and a NUL, then the firmware (2 bytes), then the X and Y range
/// (2 bytes each), all low byte first.
pub const reg_product_id: u16 = 0x8140;
/// Bit 7: a report is ready. Bits 0-3: how many contacts it has.
pub const reg_status: u16 = 0x814E;
/// The first contact; the rest follow at `point_size` apart.
pub const reg_points: u16 = 0x814F;
pub const point_size = 8;
pub const status_ready: u8 = 0x80;
pub const status_count_mask: u8 = 0x0F;

fn le16(b: []const u8) u16 {
    return @as(u16, b[0]) | @as(u16, b[1]) << 8;
}

/// The eleven bytes from `reg_product_id`: what the panel is.
pub const Identity = struct {
    product: [4]u8,
    firmware: u32,
    width: u32,
    height: u32,
};

pub fn identity(b: *const [10]u8) Identity {
    return .{
        .product = b[0..4].*,
        .firmware = le16(b[4..6]),
        .width = le16(b[6..8]),
        .height = le16(b[8..10]),
    };
}

/// How many contacts a status byte announces, or null if it announces no
/// report at all. More than the controller can hold is read as its most.
pub fn reported(status: u8) ?usize {
    if (status & status_ready == 0) return null;
    return @min(status & status_count_mask, touch.TOUCH_MAX_CONTACTS);
}

/// `count` contacts from their bytes.
pub fn decode(bytes: []const u8, count: usize, into: []TouchContact) usize {
    const n = @min(count, into.len, bytes.len / point_size);
    for (0..n) |i| {
        const p = bytes[i * point_size ..][0..point_size];
        into[i] = .{
            .id = p[0],
            .x = le16(p[1..3]),
            .y = le16(p[3..5]),
            .size = le16(p[5..7]),
        };
    }
    return n;
}

// --- reports into events ---------------------------------------------------------

// --- tests --------------------------------------------------------------------------

const testing = @import("std").testing;

test "a report: status, contacts, identity" {
    try testing.expect(reported(0x00) == null);
    try testing.expect(reported(0x05) == null);
    try testing.expectEqual(@as(?usize, 2), reported(0x82));
    try testing.expectEqual(@as(?usize, 5), reported(0x8F));

    // Two contacts: id 3 at (0x0123, 0x0045) size 0x10, id 7 at (1000, 599).
    const bytes = [_]u8{
        3, 0x23, 0x01, 0x45, 0x00, 0x10, 0x00, 0,
        7, 0xE8, 0x03, 0x57, 0x02, 0x20, 0x00, 0,
    };
    var got: [5]TouchContact = undefined;
    try testing.expectEqual(@as(usize, 2), decode(&bytes, 2, &got));
    try testing.expectEqual(TouchContact{ .id = 3, .x = 0x123, .y = 0x45, .size = 0x10 }, got[0]);
    try testing.expectEqual(TouchContact{ .id = 7, .x = 1000, .y = 599, .size = 0x20 }, got[1]);
    // Fewer bytes than announced: only whole contacts.
    try testing.expectEqual(@as(usize, 1), decode(bytes[0..12], 2, &got));

    const id = [_]u8{ '9', '1', '1', 0, 0x60, 0x10, 0x00, 0x04, 0x58, 0x02 };
    const who = identity(&id);
    try testing.expectEqualStrings("911", who.product[0..3]);
    try testing.expectEqual(@as(u32, 0x1060), who.firmware);
    try testing.expectEqual(@as(u32, 1024), who.width);
    try testing.expectEqual(@as(u32, 600), who.height);
    try testing.expectEqual([2]u8{ 0x81, 0x4E }, address(reg_status));
}
