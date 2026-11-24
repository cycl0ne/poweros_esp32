// SPDX-License-Identifier: MIT
//! The background scan: LE's advertising listened to, passively, while a
//! GATT block waits for its device (att/client.zig, BTGO_WAIT) - and a
//! link made to the device as soon as an advertising report of its comes
//! that it may be connected by: one with the address the block names,
//! or with a resolvable private address that the identity resolving key
//! of the device's bond made (smpcrypto.zig). Such a link is made for
//! GATT, as a link for channels (connections.zig), and keeps the identity
//! it was found by beside the address it was reached at.
//!
//! **On** while a block waits for a device that has no link and the
//! controller is up and on and can both scan and initiate; **off** while
//! a discovery runs - its own scan takes the controller's - and while the
//! library makes an LE link: a controller initiates to one device at a
//! time, and one that scans may not initiate. `update` sets it after
//! every packet and every tick, and after each block that waits is
//! opened or closed. LE's advertising makes way for it where the
//! controller cannot do both (advertising.zig).
//!
//! **Each advertiser is reported once** while it is on - the controller
//! filters the duplicates - and again once it is turned on afresh, which
//! it is after each link made or not made and each discovery: so a
//! device that comes back is heard again. A scan the controller refuses,
//! or a device heard whose link cannot be begun, has it turned off and
//! tried again RETRY_MS later.
//!
//! Pure, as the rest of the layer.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const _hci = @import("_hci.zig");
const Hci = _hci.Hci;
const advertising = @import("advertising.zig");
const bonds = @import("bonds.zig");
const connections = @import("connections.zig");
const discovery = @import("discovery.zig");
const smpcrypto = @import("smpcrypto.zig");

/// Every 60 ms for 30 of them (units of 0.625 ms): half the radio's time,
/// so a device's advertising - every 20 ms to 10 s - is heard at its
/// first or second.
const INTERVAL: u16 = 0x0060;
const WINDOW: u16 = 0x0030;
/// How long a refused scan, or a link that could not be begun, waits
/// before it is tried again.
pub const RETRY_MS: u32 = 10_000;

pub const Scan = struct {
    /// The controller has been asked to scan for the blocks that wait.
    on: bool = false,
    /// Refused, or a device heard could not be reached: not tried again
    /// before then.
    retry_at: ?u64 = null,
};

/// Whether it is wanted now.
fn wanted(layer: *Hci) bool {
    if (layer.state != bluetooth.BTCS_UP or !layer.powered or layer.scan.retry_at != null) return false;
    if (!discovery.canScan(layer) or !connections.canInitiate(layer)) return false;
    if (discovery.running(layer) or connections.makingLe(layer)) return false;
    for (&layer.att_clients) |*one| {
        if (one.state == .waiting and connections.find(layer, one.address) == null) return true;
    }
    return false;
}

/// The scan turned on, or off, as it is wanted now.
pub fn update(layer: *Hci) void {
    const want = wanted(layer);
    if (want == layer.scan.on) return;
    if (want) begin(layer) else stop(layer);
}

/// The controller asked to scan, passively, reporting each advertiser
/// once - its advertising stopped first where it cannot do both - or,
/// with no room for the commands, the scan tried later.
fn begin(layer: *Hci) void {
    const params = [_]u8{
        hci.LE_SCAN_PASSIVE,
        @truncate(INTERVAL),
        @truncate(INTERVAL >> 8),
        @truncate(WINDOW),
        @truncate(WINDOW >> 8),
        hci.LE_ADDR_PUBLIC, // its own address: a passive scan sends nothing
        0, // every advertiser, and what is directed at this one
    };
    if (_hci.QUEUE - layer.queue_count < 3) return later(layer);
    advertising.makeWay(layer, hci.LE_STATE_ADV_PASSIVE_SCAN);
    if (!_hci.command(layer, hci.HCI_OP_LE_SET_SCAN_PARAMETERS, &params, _hci.COMMAND_TIMEOUT_MS) or
        !_hci.command(layer, hci.HCI_OP_LE_SET_SCAN_ENABLE, &.{ 1, 1 }, _hci.COMMAND_TIMEOUT_MS))
    {
        return later(layer);
    }
    layer.scan.on = true;
}

/// The controller's scan turned off, where this asked for it: before a
/// discovery's, and before an LE link is initiated.
pub fn stop(layer: *Hci) void {
    if (!layer.scan.on) return;
    layer.scan.on = false;
    _ = _hci.command(layer, hci.HCI_OP_LE_SET_SCAN_ENABLE, &.{ 0, 0 }, _hci.COMMAND_TIMEOUT_MS);
}

/// The scan off, and not tried again for RETRY_MS.
fn later(layer: *Hci) void {
    stop(layer);
    layer.scan.retry_at = layer.now + RETRY_MS;
}

/// Forgotten without a word to the controller: it is being brought up
/// again, or has failed.
pub fn reset(layer: *Hci) void {
    layer.scan = .{};
}

/// A command's answer, its status first - empty for one not answered in
/// its time: a scan refused tried again later.
pub fn answered(layer: *Hci, opcode: u16, returned: []const u8) void {
    if (!layer.scan.on) return;
    if (opcode != hci.HCI_OP_LE_SET_SCAN_PARAMETERS and opcode != hci.HCI_OP_LE_SET_SCAN_ENABLE) return;
    if (returned.len != 0 and returned[0] == hci.HCI_SUCCESS) return;
    later(layer);
}

/// LE Advertising Report, past its subevent: a device a block waits for,
/// advertising so that it may be connected, linked to - the first such
/// of the reports.
pub fn advertisingReport(layer: *Hci, params: []const u8) void {
    if (!layer.scan.on or params.len < 1) return;
    const reports: usize = params[0];
    var at: usize = 1;
    for (0..reports) |_| {
        if (at + 9 > params.len) return;
        const event_type = params[at];
        const address_type = params[at + 1];
        const bytes = params[at + 2 ..][0..6].*;
        const length: usize = params[at + 8];
        if (at + 9 + length + 1 > params.len) return;
        at += 9 + length + 1;
        if (event_type != hci.LE_ADV_IND and event_type != hci.LE_ADV_DIRECT_IND) continue;
        const heard = bluetooth.BTAddress{ .bytes = bytes, .kind = switch (address_type) {
            hci.LE_ADDR_PUBLIC, hci.LE_ADDR_PUBLIC_IDENTITY => bluetooth.BTADDR_LE_PUBLIC,
            else => bluetooth.BTADDR_LE_RANDOM,
        } };
        if (connections.find(layer, heard) != null) continue;
        const identity = awaited(layer, heard) orelse continue;
        return reach(layer, heard, identity);
    }
}

/// The address of the block that waits for the device heard at `heard`:
/// the same, or the bond's whose identity resolving key made it. Null
/// where no block waits for it.
fn awaited(layer: *Hci, heard: bluetooth.BTAddress) ?bluetooth.BTAddress {
    const private = heard.kind == bluetooth.BTADDR_LE_RANDOM and smpcrypto.resolvable(&heard.bytes);
    for (&layer.att_clients) |*one| {
        if (one.state != .waiting) continue;
        if (connections.sameAddress(one.address, heard)) return one.address;
        if (!private or connections.find(layer, one.address) != null) continue;
        const port = if (layer.crypto) |*crypto| crypto else continue;
        const bond = bonds.find(layer, one.address) orelse continue;
        if (bond.has_irk and smpcrypto.resolves(port, &bond.irk, &heard.bytes)) return one.address;
    }
    return null;
}

/// The link to the device heard at `heard` begun, for the blocks that
/// wait for `identity` - kept with it where the two differ. One that
/// cannot be begun has the scan tried again later.
fn reach(layer: *Hci, heard: bluetooth.BTAddress, identity: bluetooth.BTAddress) void {
    if (connections.make(layer, heard) != 0) return later(layer);
    const connection = connections.find(layer, heard).?;
    connection.for_channels = true;
    if (!connections.sameAddress(heard, identity)) connection.identity = identity;
}

/// The time a refused scan waited for passed: tried again.
pub fn tick(layer: *Hci) void {
    const due = layer.scan.retry_at orelse return;
    if (layer.now >= due) layer.scan.retry_at = null;
}

/// When the scan is tried again; null where it is not waiting to be.
pub fn deadline(layer: *const Hci) ?u64 {
    return layer.scan.retry_at;
}
