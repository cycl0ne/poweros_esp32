// SPDX-License-Identifier: MIT
//! The controller's private address over LE: a resolvable private
//! address made from its identity resolving key (`layer.irk`, which the
//! task keeps) - 22 random bits under the two bits 01, and their hash
//! under the key below them (smpcrypto.ah) - which a device given the
//! machine's identity in a pairing (smp.zig) resolves to the public
//! address, and which nobody else ties to it, or to the address before.
//!
//! **Where it goes**: a discovery's active scan, whose scan requests
//! carry it (discovery.zig), and the links the library makes to devices
//! whose bonds say they were given the machine's identity
//! (connections.zig): such a device knows the machine by it and finds its
//! bond. The advertising while visible, a passive scan - which sends
//! nothing - and a link to a device without the identity go from the
//! public address, which such a device knows the machine by.
//!
//! **A new one** at every bring-up, every ROTATE_MS, and when the
//! controller is made hidden. LE Set Random Address is taken only while
//! the controller advertises, scans and initiates nothing: the change
//! waits for a discovery's LE scan and for a link being made over LE to
//! end, stops the background scan and the advertising, and sets the
//! address - and both begin again behind it in the queue, so that the
//! controller has the new address before either. One refused, or not
//! answered, is tried again RETRY_MS later.
//!
//! **The address the controller has** is the one it last took: a scan or
//! a link goes from a private address only once there is one, and a link
//! takes the address it was made from when it is up (`own`) - the
//! controller's at that moment, as no change is sent while it initiates,
//! and a link asked for behind a change is made from the new address,
//! whose answer comes before the link's.
//!
//! None without crypto.library, the identity - a public address and its
//! key - LE, or the command: the public address everywhere then.
//!
//! Pure, as the rest of the layer.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const _hci = @import("_hci.zig");
const Hci = _hci.Hci;
const advertising = @import("advertising.zig");
const connections = @import("connections.zig");
const scan = @import("scan.zig");
const smp = @import("smp.zig");
const smpcrypto = @import("smpcrypto.zig");

/// How long an address is used: the time the specification recommends.
pub const ROTATE_MS: u64 = 15 * 60 * 1000;
/// How long a refused change waits before it is tried again.
pub const RETRY_MS: u32 = 10_000;
/// Room in the queue for the background scan's end and the advertising's,
/// the address, and both begun again behind it.
const ROOM = 10;
/// The random part of a resolvable private address: the 22 bits under its
/// two top ones.
const RANDOM_BITS: u32 = 0x3FFFFF;

pub const Privacy = struct {
    /// The private address the controller has, HCI's order; `has` once
    /// it has taken one.
    address: [6]u8 = @splat(0),
    has: bool = false,
    /// A new one is wanted.
    wanted: bool = false,
    /// LE Set Random Address is out, with `giving`.
    setting: bool = false,
    giving: [6]u8 = @splat(0),
    /// When a new one is wanted: the address's time over, or a refused
    /// change tried again.
    due: ?u64 = null,
};

/// Whether the controller can have a private address: the identity,
/// crypto.library, LE, and the command.
pub fn can(layer: *const Hci) bool {
    return layer.crypto != null and smp.hasIdentity(layer) and _hci.le(layer) and
        _hci.supports(layer, hci.CMDBIT_LE_SET_RANDOM_ADDRESS);
}

/// A new address wanted - the controller made hidden - and given to it as
/// soon as it can take one.
pub fn renew(layer: *Hci) void {
    layer.privacy.wanted = true;
    update(layer);
}

/// A new address given to the controller where one is wanted and it can
/// take it now: up, no discovery's LE scan, no link being made over LE,
/// none being given already, and room in the queue. The background scan
/// and the advertising are stopped before it; their `update`s begin them
/// again behind it.
pub fn update(layer: *Hci) void {
    const privacy = &layer.privacy;
    if (!privacy.wanted or privacy.setting) return;
    if (layer.state != bluetooth.BTCS_UP or !can(layer)) return;
    if (layer.discovery.phase == .le or connections.makingLe(layer)) return;
    if (_hci.QUEUE - layer.queue_count < ROOM) return;
    const address = fresh(layer);
    scan.stop(layer);
    advertising.stop(layer);
    if (!_hci.command(layer, hci.HCI_OP_LE_SET_RANDOM_ADDRESS, &address, _hci.COMMAND_TIMEOUT_MS)) return;
    privacy.wanted = false;
    privacy.setting = true;
    privacy.giving = address;
}

/// A resolvable private address of the controller's key: three random
/// bytes on top - their 22 random bits neither all 0 nor all 1, the two
/// above them 01 - and their hash under the key below them.
pub fn fresh(layer: *Hci) [6]u8 {
    const port = &layer.crypto.?;
    var address: [6]u8 = undefined;
    while (true) {
        port.random(port.context, address[3..6]);
        address[5] = address[5] & 0x3F | 0x40;
        const random_part = @as(u32, address[3]) | @as(u32, address[4]) << 8 | @as(u32, address[5] & 0x3F) << 16;
        if (random_part != 0 and random_part != RANDOM_BITS) break;
    }
    address[0..3].* = smpcrypto.ah(port, &layer.irk, address[3..6]);
    return address;
}

/// The address a link is made from: the private one the controller has
/// where `private`, its public one otherwise.
pub fn own(layer: *const Hci, private: bool) bluetooth.BTAddress {
    if (private and layer.privacy.has) return .{ .bytes = layer.privacy.address, .kind = bluetooth.BTADDR_LE_RANDOM };
    return .{ .bytes = layer.address, .kind = bluetooth.BTADDR_LE_PUBLIC };
}

/// Whether a link to `address` goes from the private address: the
/// controller has one, and the device's bond - found by the address, or
/// by the key that made it - says the device was given the machine's
/// identity.
pub fn towards(layer: *Hci, address: bluetooth.BTAddress) bool {
    if (!layer.privacy.has) return false;
    const bond = smp.bondAt(layer, address) orelse return false;
    return bond.identity_given;
}

/// The own address type of an active scan: the private address where the
/// controller has one.
pub fn scanning(layer: *const Hci) u8 {
    return if (layer.privacy.has) hci.LE_ADDR_RANDOM else hci.LE_ADDR_PUBLIC;
}

/// Forgotten without a word to the controller - it is being brought up
/// again, or has failed - and a new one wanted once it is up.
pub fn reset(layer: *Hci) void {
    layer.privacy = .{ .wanted = true };
}

/// A command's answer, its status first - empty for one not answered in
/// its time: the address taken, or tried again later.
pub fn answered(layer: *Hci, opcode: u16, returned: []const u8) void {
    const privacy = &layer.privacy;
    if (opcode != hci.HCI_OP_LE_SET_RANDOM_ADDRESS or !privacy.setting) return;
    privacy.setting = false;
    if (returned.len == 0 or returned[0] != hci.HCI_SUCCESS) {
        privacy.due = layer.now + RETRY_MS;
        return;
    }
    privacy.address = privacy.giving;
    privacy.has = true;
    privacy.due = layer.now + ROTATE_MS;
    layer.changed = true;
}

/// The address's time over, or a refused change's wait: a new one wanted.
pub fn tick(layer: *Hci) void {
    const due = layer.privacy.due orelse return;
    if (layer.now < due) return;
    layer.privacy.due = null;
    layer.privacy.wanted = true;
}

/// When a new one is wanted; null where none is waited for.
pub fn deadline(layer: *const Hci) ?u64 {
    return layer.privacy.due;
}
