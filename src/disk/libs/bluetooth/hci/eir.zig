// SPDX-License-Identifier: MIT
//! What a device says of itself, as an extended inquiry response or an
//! advertisement carries it: a run of structures, each its length (one
//! byte, counting its type and its data), its type (hci.AD_*) and its
//! data. A length of 0 ends the run - an extended inquiry response is
//! padded with zeros to its 240 bytes - as does a structure that would
//! run past the end.
//!
//! **Taken into the device** (`take`): its name, complete or shortened -
//! a complete one is kept over a shortened one, never the other way -
//! its flags, the power it sends at, its class of device, its appearance,
//! the maker its own data names, and the services it lists, 16-bit UUIDs
//! as they are and 32- and 128-bit ones as 128-bit UUIDs, each once and
//! as many as the device's record has room for. What it does not say
//! leaves what the device said before: an advertisement and its scan
//! response add up.
//!
//! **Made**: the machine's own extended inquiry response - its name,
//! shortened to what fits (`response`) - and over LE its advertisement
//! and scan response (`advertisement`, `scanResponse`): its flags, that
//! it is a computer, and its name - in the scan response as well where
//! the advertisement has no room for all of it.
//!
//! Pure: the host tests run it on bytes alone.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const att = bluetooth.att;
const devices = @import("devices.zig");
const Device = devices.Device;

/// A structure of the run: its type and its data.
pub const Element = struct {
    kind: u8,
    data: []const u8,
};

/// The structures of `bytes`, one after the other.
pub const Elements = struct {
    bytes: []const u8,
    at: usize = 0,

    pub fn next(elements: *Elements) ?Element {
        const rest = elements.bytes[elements.at..];
        if (rest.len < 2 or rest[0] == 0) return null;
        const length: usize = rest[0];
        if (length + 1 > rest.len) return null;
        elements.at += length + 1;
        return .{ .kind = rest[1], .data = rest[2 .. length + 1] };
    }
};

/// What `bytes` says, taken into `device`.
pub fn take(device: *Device, bytes: []const u8) void {
    var elements = Elements{ .bytes = bytes };
    while (elements.next()) |element| {
        const data = element.data;
        switch (element.kind) {
            hci.AD_FLAGS => if (data.len >= 1) {
                device.ad_flags = data[0];
            },
            hci.AD_UUID16_SOME, hci.AD_UUID16_ALL => {
                var at: usize = 0;
                while (at + 2 <= data.len) : (at += 2) addUuid16(device, @as(u16, data[at]) | @as(u16, data[at + 1]) << 8);
            },
            hci.AD_UUID32_SOME, hci.AD_UUID32_ALL => {
                var at: usize = 0;
                while (at + 4 <= data.len) : (at += 4) {
                    var uuid = hci.UUID_BASE;
                    @memcpy(uuid[12..16], data[at..][0..4]);
                    addUuid128(device, uuid);
                }
            },
            hci.AD_UUID128_SOME, hci.AD_UUID128_ALL => {
                var at: usize = 0;
                while (at + 16 <= data.len) : (at += 16) addUuid128(device, data[at..][0..16].*);
            },
            hci.AD_NAME_SHORT => if (device.name[0] == 0 or device.flags & bluetooth.BTDF_SHORT_NAME != 0) {
                devices.setName(device, data);
                device.flags |= bluetooth.BTDF_SHORT_NAME;
            },
            hci.AD_NAME_COMPLETE => {
                devices.setName(device, data);
                device.flags &= ~bluetooth.BTDF_SHORT_NAME;
            },
            hci.AD_TX_POWER => if (data.len >= 1) {
                device.tx_power = @bitCast(data[0]);
            },
            hci.AD_CLASS_OF_DEVICE => if (data.len >= 3) {
                device.class_of_device = @as(u32, data[0]) | @as(u32, data[1]) << 8 | @as(u32, data[2]) << 16;
            },
            hci.AD_APPEARANCE => if (data.len >= 2) {
                device.appearance = @as(u16, data[0]) | @as(u16, data[1]) << 8;
            },
            hci.AD_MANUFACTURER_DATA => if (data.len >= 2) {
                device.company = @as(u16, data[0]) | @as(u16, data[1]) << 8;
            },
            else => {},
        }
    }
}

fn addUuid16(device: *Device, uuid: u16) void {
    for (device.uuid16[0..device.uuid16_count]) |known| {
        if (known == uuid) return;
    }
    if (device.uuid16_count == device.uuid16.len) return;
    device.uuid16[device.uuid16_count] = uuid;
    device.uuid16_count += 1;
}

fn addUuid128(device: *Device, uuid: [16]u8) void {
    for (device.uuid128[0..device.uuid128_count]) |known| {
        if (sameUuid(&known, &uuid)) return;
    }
    if (device.uuid128_count == device.uuid128.len) return;
    device.uuid128[device.uuid128_count] = uuid;
    device.uuid128_count += 1;
}

fn sameUuid(kept: *const [16]u8, heard: *const [16]u8) bool {
    for (kept, heard) |mine, theirs| {
        if (mine != theirs) return false;
    }
    return true;
}

/// The machine's own extended inquiry response into `into`, zeroed: the
/// name `text` (up to its NUL) complete, or as much of it as fits -
/// whole characters - shortened.
pub fn response(into: *[hci.EIR_SIZE]u8, text: []const u8) void {
    @memset(into, 0);
    _ = putName(into, text);
}

/// The advertisement's flags and appearance, before its name; the room
/// left for the name's structure.
const ADVERTISED_HEAD = 7;
const ADVERTISED_NAME_ROOM = hci.LE_ADV_DATA_SIZE - ADVERTISED_HEAD;

/// The machine's own advertisement into `into`: its flags (hci.AD_FLAG_*),
/// that it is a computer, and the name `text` (up to its NUL) complete, or
/// as much of it as fits - whole characters - shortened. Its length.
pub fn advertisement(into: *[hci.LE_ADV_DATA_SIZE]u8, flags: u8, text: []const u8) usize {
    const appearance = att.APPEARANCE_COMPUTER;
    into[0..ADVERTISED_HEAD].* = .{ 2, hci.AD_FLAGS, flags, 3, hci.AD_APPEARANCE, @truncate(appearance), @truncate(appearance >> 8) };
    return ADVERTISED_HEAD + putName(into[ADVERTISED_HEAD..], text);
}

/// Its scan response into `into`: the name `text` (up to its NUL) where
/// the advertisement had no room for all of it - complete, or as much as
/// fits shortened - and nothing where it had. Its length.
pub fn scanResponse(into: *[hci.LE_ADV_DATA_SIZE]u8, text: []const u8) usize {
    if (nameLength(text) + 2 <= ADVERTISED_NAME_ROOM) return 0;
    return putName(into, text);
}

fn nameLength(text: []const u8) usize {
    var length: usize = 0;
    while (length < text.len and text[length] != 0) length += 1;
    return length;
}

/// The name `text` (up to its NUL) as a structure at the start of
/// `into`: complete, or as much of it as fits - whole characters -
/// shortened. Its length.
fn putName(into: []u8, text: []const u8) usize {
    const length = nameLength(text);
    var kept = @min(length, into.len - 2);
    // Not inside a character: UTF-8's continuation bytes are 10xxxxxx.
    if (kept < length) {
        while (kept > 0 and text[kept] & 0xC0 == 0x80) kept -= 1;
    }
    into[0] = @intCast(kept + 1);
    into[1] = if (kept < length) hci.AD_NAME_SHORT else hci.AD_NAME_COMPLETE;
    @memcpy(into[2..][0..kept], text[0..kept]);
    return kept + 2;
}
