// SPDX-License-Identifier: MIT
//! The devices a controller found: a table in its HCI layer, a record a
//! device - its address, how it was heard, what it said of itself, and
//! what a page to it needs - kept until the controller's next discovery
//! begins.
//!
//! **A record a device.** A device is known by its address and the kind
//! of address: a BR/EDR address and an LE public one with the same bytes
//! are one device that speaks both, kept as BR/EDR; an LE random address
//! is a device of its own.
//!
//! **A full table keeps the strongest**: a device heard while every
//! record is taken replaces the one heard weakest, if it is heard
//! stronger than that one; otherwise it is not kept. Those nearest are
//! the ones looked for.
//!
//! Pure, as the rest of the layer.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const _hci = @import("_hci.zig");
const Hci = _hci.Hci;

/// How many devices a controller keeps.
pub const DEVICES = 64;

pub const Device = struct {
    used: bool = false,
    address: bluetooth.BTAddress = .{},
    /// BTDF_*.
    flags: u32 = 0,
    class_of_device: u32 = 0,
    /// When it was last heard, in the layer's milliseconds.
    seen: u64 = 0,
    rssi: i8 = bluetooth.BT_RSSI_NONE,
    tx_power: i8 = bluetooth.BT_TX_POWER_NONE,
    ad_flags: u8 = 0,
    appearance: u16 = 0,
    company: u16 = bluetooth.BT_COMPANY_NONE,
    uuid16: [8]u16 = @splat(0),
    uuid16_count: u8 = 0,
    uuid128: [2][16]u8 = @splat(@splat(0)),
    uuid128_count: u8 = 0,
    /// BR/EDR: what a page to it needs, as its answer to the inquiry gave
    /// it - its page scan repetition mode, and its clock offset.
    page_scan_repetition: u8 = 0,
    clock_offset: u16 = 0,
    /// Whether its name has been asked for in this discovery.
    name_asked: bool = false,
    /// Its name, UTF-8, ended by a NUL; empty while it has said none.
    name: [hci.HCI_MAX_NAME + 1]u8 = @splat(0),
};

/// The record for the device at this address, made if there is none,
/// and its time heard set: null when the table is full of devices heard
/// stronger than `rssi`.
pub fn heard(layer: *Hci, bytes: [6]u8, kind: u8, rssi: i8) ?*Device {
    if (find(layer, bytes, kind)) |device| {
        // An LE device that answers an inquiry too is BR/EDR from then on.
        if (kind == bluetooth.BTADDR_BREDR) device.address.kind = bluetooth.BTADDR_BREDR;
        device.seen = layer.now;
        return device;
    }
    const slot = free(layer) orelse weakest(layer, rssi) orelse return null;
    slot.* = .{ .used = true, .address = .{ .bytes = bytes, .kind = kind }, .seen = layer.now };
    return slot;
}

/// The record for this address; null for none. A BR/EDR address and an
/// LE public one with the same bytes find each other.
pub fn find(layer: *Hci, bytes: [6]u8, kind: u8) ?*Device {
    for (&layer.devices) |*device| {
        if (!device.used or !sameBytes(&device.address.bytes, &bytes)) continue;
        if (device.address.kind == kind) return device;
        if (kind != bluetooth.BTADDR_LE_RANDOM and device.address.kind != bluetooth.BTADDR_LE_RANDOM) return device;
    }
    return null;
}

fn free(layer: *Hci) ?*Device {
    for (&layer.devices) |*device| {
        if (!device.used) return device;
    }
    return null;
}

/// The record heard weakest, if a device heard with `rssi` is stronger.
fn weakest(layer: *Hci, rssi: i8) ?*Device {
    var found: ?*Device = null;
    for (&layer.devices) |*device| {
        if (found == null or strength(device.rssi) < strength(found.?.rssi)) found = device;
    }
    const candidate = found orelse return null;
    return if (strength(rssi) > strength(candidate.rssi)) candidate else null;
}

/// A signal for comparing: none is weaker than any.
fn strength(rssi: i8) i16 {
    return if (rssi == bluetooth.BT_RSSI_NONE) -1000 else rssi;
}

fn sameBytes(kept: *const [6]u8, heard_bytes: *const [6]u8) bool {
    for (kept, heard_bytes) |mine, theirs| {
        if (mine != theirs) return false;
    }
    return true;
}

/// Every record let go: a new discovery begins with none.
pub fn forget(layer: *Hci) void {
    for (&layer.devices) |*device| device.used = false;
}

/// How many devices are kept.
pub fn count(layer: *const Hci) usize {
    var kept: usize = 0;
    for (&layer.devices) |*device| {
        if (device.used) kept += 1;
    }
    return kept;
}

/// The name `bytes` says - up to its first NUL, or all of it - as the
/// device's, cut to the longest a name may be.
pub fn setName(device: *Device, bytes: []const u8) void {
    var length: usize = 0;
    while (length < bytes.len and length < hci.HCI_MAX_NAME and bytes[length] != 0) length += 1;
    @memcpy(device.name[0..length], bytes[0..length]);
    device.name[length] = 0;
}

/// The device whose name is to be asked for next: a BR/EDR one that has
/// said no complete name and has not been asked in this discovery, the
/// strongest first; null when none is left.
pub fn nameWanted(layer: *Hci) ?*Device {
    var found: ?*Device = null;
    for (&layer.devices) |*device| {
        if (!device.used or device.name_asked) continue;
        if (device.flags & bluetooth.BTDF_BREDR == 0) continue;
        if (device.name[0] != 0 and device.flags & bluetooth.BTDF_SHORT_NAME == 0) continue;
        if (found == null or strength(device.rssi) > strength(found.?.rssi)) found = device;
    }
    return found;
}
