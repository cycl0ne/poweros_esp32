// SPDX-License-Identifier: MIT
//! A controller's bonds: a table in its HCI layer, a record a device it
//! has paired with and kept the link key of - the device's address, the
//! key and its kind, the device's class and name as they were at the
//! pairing.
//!
//! **Read and written by the task.** The task fills the table from the
//! bond files once the controller's address is known (`loaded`), and
//! writes what changed: a bond made or replaced is marked `dirty`, one
//! ended `gone` as well, and `layer.bonds_changed` says there is
//! something to write. The task clears the marks as it writes, and frees
//! a gone bond's place once its file is deleted (`written`).
//!
//! **Full**, the table keeps no new bond: the pairing ends without one
//! (BTERR_NOMEM) until UnpairBTDevice has made room.
//!
//! Pure, as the rest of the layer.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const _hci = @import("_hci.zig");
const Hci = _hci.Hci;

/// How many bonds a controller keeps.
pub const BONDS = 32;

pub const Bond = struct {
    used: bool = false,
    address: bluetooth.BTAddress = .{},
    key: [hci.LINK_KEY_SIZE]u8 = @splat(0),
    key_type: u8 = 0,
    /// Made with a PIN.
    legacy: bool = false,
    class_of_device: u32 = 0,
    /// The device's name, UTF-8, ended by a NUL; empty when none was
    /// known.
    name: [bluetooth.BT_BOND_NAME_MOST + 1]u8 = @splat(0),
    /// To be written, and to be deleted.
    dirty: bool = false,
    gone: bool = false,
};

/// The bond with the device at `address`; null for none.
pub fn find(layer: *Hci, address: bluetooth.BTAddress) ?*Bond {
    for (&layer.bonds) |*bond| {
        if (bond.used and !bond.gone and sameDevice(bond.address, address)) return bond;
    }
    return null;
}

/// A device's two addresses the same one - over BR/EDR the bytes alone.
fn sameDevice(one: bluetooth.BTAddress, other: bluetooth.BTAddress) bool {
    if (one.kind != other.kind) return false;
    for (one.bytes, other.bytes) |mine, theirs| {
        if (mine != theirs) return false;
    }
    return true;
}

/// A bond kept - made, or a new key for one there is - and marked to be
/// written; null when the table is full.
pub fn keep(layer: *Hci, address: bluetooth.BTAddress, key: *const [hci.LINK_KEY_SIZE]u8, key_type: u8, legacy: bool, class_of_device: u32, name: []const u8) ?*Bond {
    const bond = find(layer, address) orelse freePlace(layer) orelse return null;
    bond.* = .{
        .used = true,
        .address = address,
        .key = key.*,
        .key_type = key_type,
        .legacy = legacy,
        .class_of_device = class_of_device,
        .dirty = true,
    };
    setName(bond, name);
    layer.bonds_changed = true;
    layer.changed = true;
    return bond;
}

/// A free place; a gone bond's is not free until its file is deleted.
fn freePlace(layer: *Hci) ?*Bond {
    for (&layer.bonds) |*bond| {
        if (!bond.used) return bond;
    }
    return null;
}

fn setName(bond: *Bond, name: []const u8) void {
    var length: usize = 0;
    while (length < name.len and length < bluetooth.BT_BOND_NAME_MOST and name[length] != 0) length += 1;
    // A whole character: a cut UTF-8 sequence is let go.
    while (length > 0 and length < name.len and name[length] & 0xC0 == 0x80) length -= 1;
    @memcpy(bond.name[0..length], name[0..length]);
    bond.name[length] = 0;
}

/// The bond with `address` ended: marked gone, its file to be deleted.
/// False when there is none.
pub fn forget(layer: *Hci, address: bluetooth.BTAddress) bool {
    const bond = find(layer, address) orelse return false;
    bond.gone = true;
    bond.dirty = true;
    layer.bonds_changed = true;
    layer.changed = true;
    return true;
}

/// A bond the task read from its file put into the table, as it is;
/// false when the table has no free place.
pub fn loaded(layer: *Hci, read: *const Bond) bool {
    for (&layer.bonds) |*bond| {
        if (bond.used and sameDevice(bond.address, read.address)) return false;
    }
    for (&layer.bonds) |*bond| {
        if (bond.used) continue;
        bond.* = read.*;
        bond.used = true;
        bond.dirty = false;
        bond.gone = false;
        return true;
    }
    return false;
}

/// The next bond to be written or deleted; null when there is none, and
/// `bonds_changed` cleared.
pub fn nextDirty(layer: *Hci) ?*Bond {
    for (&layer.bonds) |*bond| {
        if (bond.used and bond.dirty) return bond;
    }
    layer.bonds_changed = false;
    return null;
}

/// A bond the task has written - or whose file it has deleted, which
/// frees its place.
pub fn written(bond: *Bond) void {
    bond.dirty = false;
    if (bond.gone) bond.* = .{};
}

/// Whether a bond's key was made with its pairing confirmed.
pub fn authenticated(bond: *const Bond) bool {
    return switch (bond.key_type) {
        hci.LINK_KEY_AUTHENTICATED_P192, hci.LINK_KEY_AUTHENTICATED_P256 => true,
        hci.LINK_KEY_COMBINATION => bond.legacy,
        else => false,
    };
}

/// Whether it was made with Secure Connections (P-256).
pub fn secure(bond: *const Bond) bool {
    return bond.key_type == hci.LINK_KEY_UNAUTHENTICATED_P256 or bond.key_type == hci.LINK_KEY_AUTHENTICATED_P256;
}
