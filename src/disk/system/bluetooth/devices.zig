// SPDX-License-Identifier: MIT
//! The devices the window lists, put together from what the library says
//! of one controller - its bonds, its links and what its last search
//! found - into one entry a device, found by its address. The bonds come
//! first, then the links to devices without a bond, then the devices a
//! search found alone, each in the order the library lists them.
//!
//! **One device, two kinds of address.** A device reached over BR/EDR
//! and over LE has one public address for both: a BR/EDR address and a
//! public LE address of the same bytes are one device. A random LE
//! address is a device of its own - save a link's from a private address
//! its bond's key resolves, which is the bond's device: the link says the
//! identity it resolved to. The entry keeps the address of its
//! bond, or else of its link - what pairing, linking and forgetting it
//! again go by - and a device a search heard both ways is listed by its
//! BR/EDR address, which its profiles for both, sound and input, use.
//!
//! **Its name** is the one known last: the bond's, as it was at the
//! pairing, then the link's, then the one a search heard - a name each
//! one has standing in for the one before, except that a shortened name
//! an advertisement carries leaves a whole one be.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;

/// As many as the library keeps: bonds, links and devices found.
pub const devices_most = 32 + 8 + 64;
pub const name_most = bluetooth.BT_BOND_NAME_MOST;
pub const drivers_most = bluetooth.BT_BOND_DRIVERS_MOST;

pub const Device = struct {
    address: bluetooth.BTAddress = .{},
    /// UTF-8, ended by a NUL; empty while none is known.
    name: [name_most + 1]u8 = @splat(0),
    /// Whether `name` is a shortened one.
    short_name: bool = false,
    /// What it said it is: its class of device (hci.COD_*), and over LE
    /// its appearance; 0 for none.
    class_of_device: u32 = 0,
    appearance: u16 = 0,
    /// The signal a search last heard it with, in dBm; BT_RSSI_NONE.
    rssi: i8 = bluetooth.BT_RSSI_NONE,
    /// What the library has of it, and the flags of each: the bond's
    /// (BTBF_*), the link's (BTLF_*), the device found's (BTDF_*).
    bonded: bool = false,
    linked: bool = false,
    found: bool = false,
    bond_flags: u32 = 0,
    link_flags: u32 = 0,
    found_flags: u32 = 0,
    /// The profile drivers that drive it, as the bond names them; empty
    /// for none.
    drivers: [drivers_most + 1]u8 = @splat(0),

    fn takeName(device: *Device, name: ?[*:0]const u8, short: bool) void {
        const text = name orelse return;
        if (text[0] == 0) return;
        if (short and device.name[0] != 0 and !device.short_name) return;
        var length: usize = 0;
        while (text[length] != 0 and length < name_most) length += 1;
        // A name cut short is cut before a character the cut would split.
        if (text[length] != 0) {
            while (length > 0 and text[length] & 0xC0 == 0x80) length -= 1;
        }
        @memcpy(device.name[0..length], text[0..length]);
        device.name[length] = 0;
        device.short_name = short;
    }
};

/// Whether two addresses are one device's.
pub fn sameDevice(one: *const bluetooth.BTAddress, other: *const bluetooth.BTAddress) bool {
    for (one.bytes, other.bytes) |mine, theirs| {
        if (mine != theirs) return false;
    }
    if (one.kind == other.kind) return true;
    return one.kind != bluetooth.BTADDR_LE_RANDOM and other.kind != bluetooth.BTADDR_LE_RANDOM;
}

pub const Table = struct {
    devices: [devices_most]Device = undefined,
    count: usize = 0,

    pub fn clear(table: *Table) void {
        table.count = 0;
    }

    pub fn slice(table: *Table) []Device {
        return table.devices[0..table.count];
    }

    /// The entry of the device at `address`; null where there is none.
    pub fn find(table: *Table, address: *const bluetooth.BTAddress) ?*Device {
        for (table.devices[0..table.count]) |*device| {
            if (sameDevice(&device.address, address)) return device;
        }
        return null;
    }

    /// The entry of the device at `address`, made where there is none -
    /// null once the table is full.
    fn entry(table: *Table, address: *const bluetooth.BTAddress) ?*Device {
        if (table.find(address)) |device| return device;
        if (table.count == table.devices.len) return null;
        const device = &table.devices[table.count];
        table.count += 1;
        device.* = .{ .address = address.* };
        return device;
    }

    pub fn addBond(table: *Table, bond: *const bluetooth.BTBond) void {
        const device = table.entry(&bond.address) orelse return;
        device.bonded = true;
        device.bond_flags |= bond.flags;
        device.takeName(bond.node.name, false);
        if (device.class_of_device == 0) device.class_of_device = bond.class_of_device;
        if (device.drivers[0] == 0) {
            if (bond.drivers) |drivers| {
                var length: usize = 0;
                while (drivers[length] != 0 and length < drivers_most) length += 1;
                @memcpy(device.drivers[0..length], drivers[0..length]);
                device.drivers[length] = 0;
            }
        }
    }

    pub fn addLink(table: *Table, link: *const bluetooth.BTConnection) void {
        // From a private address its bond resolves: the bond's device.
        const address = if (link.identity.kind != bluetooth.BTADDR_BREDR) &link.identity else &link.address;
        const device = table.entry(address) orelse return;
        device.linked = true;
        device.link_flags |= link.flags;
        device.takeName(link.node.name, false);
        if (device.class_of_device == 0) device.class_of_device = link.class_of_device;
    }

    pub fn addFound(table: *Table, found: *const bluetooth.BTDevice) void {
        const device = table.entry(&found.address) orelse return;
        if (!device.bonded and !device.linked and found.address.kind == bluetooth.BTADDR_BREDR) {
            device.address = found.address;
        }
        device.found = true;
        device.found_flags |= found.flags;
        device.takeName(found.node.name, found.flags & bluetooth.BTDF_SHORT_NAME != 0);
        if (device.class_of_device == 0) device.class_of_device = found.class_of_device;
        if (device.appearance == 0) device.appearance = found.appearance;
        if (found.rssi != bluetooth.BT_RSSI_NONE) device.rssi = found.rssi;
    }
};

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

fn madeAddress(kind: u8, last: u8) bluetooth.BTAddress {
    return .{ .bytes = .{ last, 0x10, 0xEF, 0x5E, 0x00, 0x00 }, .kind = kind };
}

fn nameOf(device: *const Device) []const u8 {
    return std.mem.sliceTo(&device.name, 0);
}

test "a bond, a link and a device found at one address are one device, the bonds first" {
    var table: Table = .{};
    const found_alone: bluetooth.BTDevice = .{ .node = .{ .name = "Speaker" }, .address = madeAddress(bluetooth.BTADDR_BREDR, 0x01), .rssi = -60, .flags = bluetooth.BTDF_BREDR };
    const bond: bluetooth.BTBond = .{ .node = .{ .name = "Keyboard" }, .address = madeAddress(bluetooth.BTADDR_BREDR, 0x02), .class_of_device = 0x002540, .drivers = "bthid.device" };
    const link: bluetooth.BTConnection = .{ .node = .{ .name = "" }, .address = madeAddress(bluetooth.BTADDR_BREDR, 0x02), .flags = bluetooth.BTLF_ENCRYPTED };
    const found_bonded: bluetooth.BTDevice = .{ .node = .{ .name = "Keyboard K2" }, .address = madeAddress(bluetooth.BTADDR_BREDR, 0x02), .rssi = -48 };
    table.addBond(&bond);
    table.addLink(&link);
    table.addFound(&found_alone);
    table.addFound(&found_bonded);
    try testing.expectEqual(@as(usize, 2), table.count);
    const keyboard = &table.devices[0];
    try testing.expect(keyboard.bonded and keyboard.linked and keyboard.found);
    try testing.expectEqual(bluetooth.BTLF_ENCRYPTED, keyboard.link_flags);
    // The name heard last stands in for the bond's; the link said none.
    try testing.expectEqualStrings("Keyboard K2", nameOf(keyboard));
    try testing.expectEqualStrings("bthid.device", std.mem.sliceTo(&keyboard.drivers, 0));
    try testing.expectEqual(@as(u32, 0x002540), keyboard.class_of_device);
    try testing.expectEqual(@as(i8, -48), keyboard.rssi);
    const speaker = &table.devices[1];
    try testing.expect(!speaker.bonded and speaker.found);
    try testing.expectEqualStrings("Speaker", nameOf(speaker));
}

test "a link from a private address its bond resolves is the bond's device, listed by the identity" {
    var table: Table = .{};
    const bond: bluetooth.BTBond = .{ .node = .{ .name = "Sensor" }, .address = madeAddress(bluetooth.BTADDR_LE_PUBLIC, 0x07) };
    const link: bluetooth.BTConnection = .{ .node = .{ .name = "Sensor" }, .address = madeAddress(bluetooth.BTADDR_LE_RANDOM, 0x47), .identity = madeAddress(bluetooth.BTADDR_LE_PUBLIC, 0x07), .flags = bluetooth.BTLF_LE | bluetooth.BTLF_ENCRYPTED };
    table.addBond(&bond);
    table.addLink(&link);
    try testing.expectEqual(@as(usize, 1), table.count);
    const sensor = &table.devices[0];
    try testing.expect(sensor.bonded and sensor.linked);
    try testing.expectEqual(bluetooth.BTADDR_LE_PUBLIC, sensor.address.kind);
    try testing.expectEqual(bluetooth.BTLF_LE | bluetooth.BTLF_ENCRYPTED, sensor.link_flags);
}

test "a BR/EDR address and a public LE one of the same bytes are one device; a random one is not" {
    var table: Table = .{};
    const bredr: bluetooth.BTBond = .{ .address = madeAddress(bluetooth.BTADDR_BREDR, 0x05) };
    const le: bluetooth.BTDevice = .{ .address = madeAddress(bluetooth.BTADDR_LE_PUBLIC, 0x05), .appearance = 0x03C1 };
    const random: bluetooth.BTDevice = .{ .address = madeAddress(bluetooth.BTADDR_LE_RANDOM, 0x05) };
    table.addBond(&bredr);
    table.addFound(&le);
    table.addFound(&random);
    try testing.expectEqual(@as(usize, 2), table.count);
    try testing.expectEqual(@as(u16, 0x03C1), table.devices[0].appearance);
    try testing.expect(table.devices[0].bonded and table.devices[0].found);
    try testing.expectEqual(bluetooth.BTADDR_LE_RANDOM, table.devices[1].address.kind);
    const public = madeAddress(bluetooth.BTADDR_LE_PUBLIC, 0x05);
    const other = madeAddress(bluetooth.BTADDR_BREDR, 0x06);
    try testing.expect(table.find(&public) == &table.devices[0]);
    try testing.expect(table.find(&other) == null);
}

test "a device a search heard both ways is listed by its BR/EDR address, one with a bond by its bond's" {
    var table: Table = .{};
    const heard_le: bluetooth.BTDevice = .{ .address = madeAddress(bluetooth.BTADDR_LE_PUBLIC, 0x08) };
    const heard_bredr: bluetooth.BTDevice = .{ .address = madeAddress(bluetooth.BTADDR_BREDR, 0x08) };
    const bond_le: bluetooth.BTBond = .{ .address = madeAddress(bluetooth.BTADDR_LE_PUBLIC, 0x09) };
    const heard_bonded: bluetooth.BTDevice = .{ .address = madeAddress(bluetooth.BTADDR_BREDR, 0x09) };
    table.addBond(&bond_le);
    table.addFound(&heard_le);
    table.addFound(&heard_bredr);
    table.addFound(&heard_bonded);
    try testing.expectEqual(@as(usize, 2), table.count);
    try testing.expectEqual(bluetooth.BTADDR_LE_PUBLIC, table.devices[0].address.kind);
    try testing.expect(table.devices[0].bonded and table.devices[0].found);
    try testing.expectEqual(bluetooth.BTADDR_BREDR, table.devices[1].address.kind);
    try testing.expectEqual(@as(u8, 0x08), table.devices[1].address.bytes[0]);
}

test "a shortened name leaves a whole one be, and stands in for another shortened one" {
    var table: Table = .{};
    const bond: bluetooth.BTBond = .{ .node = .{ .name = "Living room speaker" }, .address = madeAddress(bluetooth.BTADDR_LE_PUBLIC, 0x07) };
    const short: bluetooth.BTDevice = .{ .node = .{ .name = "Living" }, .address = madeAddress(bluetooth.BTADDR_LE_PUBLIC, 0x07), .flags = bluetooth.BTDF_SHORT_NAME };
    table.addBond(&bond);
    table.addFound(&short);
    try testing.expectEqualStrings("Living room speaker", nameOf(&table.devices[0]));
    try testing.expect(!table.devices[0].short_name);

    const first: bluetooth.BTDevice = .{ .node = .{ .name = "Liv" }, .address = madeAddress(bluetooth.BTADDR_LE_RANDOM, 0x08), .flags = bluetooth.BTDF_SHORT_NAME };
    const second: bluetooth.BTDevice = .{ .node = .{ .name = "Living" }, .address = madeAddress(bluetooth.BTADDR_LE_RANDOM, 0x09), .flags = bluetooth.BTDF_SHORT_NAME };
    table.addFound(&first);
    table.addFound(&second);
    try testing.expectEqualStrings("Liv", nameOf(&table.devices[1]));
    try testing.expect(table.devices[1].short_name);
}

test "a name longer than the room is cut before a character the cut would split; a full table takes no more" {
    var table: Table = .{};
    const long = ([_]u8{'a'} ** (name_most - 1)) ++ "\xC3\xA4bc";
    const named: bluetooth.BTDevice = .{ .node = .{ .name = long }, .address = madeAddress(bluetooth.BTADDR_BREDR, 0x01) };
    table.addFound(&named);
    try testing.expectEqual(name_most - 1, nameOf(&table.devices[0]).len);

    table.clear();
    for (0..devices_most + 3) |index| {
        const found: bluetooth.BTDevice = .{ .address = madeAddress(bluetooth.BTADDR_LE_RANDOM, @intCast(index)) };
        table.addFound(&found);
    }
    try testing.expectEqual(@as(usize, devices_most), table.count);
}
