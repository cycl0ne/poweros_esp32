// SPDX-License-Identifier: MIT
//! LE's advertising: the controller seen over LE while it is visible -
//! connectable and scannable, undirected, every 100 to 150 ms on all
//! three channels, from its public address - so that a device that scans
//! finds it by its name and may make a link to it, the controller the
//! link's peripheral.
//!
//! **What it says** (eir.zig): its flags - LE General Discoverable, and
//! BR/EDR Not Supported for a controller without it - that it is a
//! computer, as its GATT server says, and its name: complete where it
//! fits, shortened otherwise and then in the scan response too, whole
//! where it fits there. A name changed goes out at once.
//!
//! **On** while the controller is up, on and visible and can advertise -
//! it has LE's advertising commands and buffers for LE's links, and the
//! state where it said its states; **off** while its link table is full -
//! a link a device made would be ended at once - and while it does what it
//! cannot do beside advertising, as LE Read Supported States answered at
//! the bring-up: a discovery's active scan, the background scan
//! (scan.zig), initiating a link, an LE link up with the controller its
//! central, or its peripheral. A controller that did not say does none of
//! them beside it. Each turns it off before it begins (`makeWay`);
//! `update` sets it as it is wanted after every packet and every tick,
//! and after each change of the settings (local.zig).
//!
//! **A link a device makes** ends it - the controller no longer
//! advertises once a device has linked to it - and `update` begins it
//! again where the controller can advertise beside the link.
//!
//! **Refused** - a command of it answered with an error, or not in its
//! time - it is turned off and tried again RETRY_MS later, as the
//! background scan is.
//!
//! Pure, as the rest of the layer.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const _hci = @import("_hci.zig");
const Hci = _hci.Hci;
const connections = @import("connections.zig");
const eir = @import("eir.zig");

/// Every 100 to 150 ms (units of 0.625 ms): a scan of a second hears it
/// several times, and it takes about one per cent of the air.
const INTERVAL_MIN: u16 = 0x00A0;
const INTERVAL_MAX: u16 = 0x00F0;
/// How long refused advertising waits before it is tried again.
pub const RETRY_MS: u32 = 10_000;

pub const Advertising = struct {
    /// The controller has been asked to advertise.
    on: bool = false,
    /// Refused: not tried again before then.
    retry_at: ?u64 = null,
};

/// Whether the controller can advertise at all: LE's advertising
/// commands, buffers for LE's links, and the state, where it said its
/// states.
pub fn can(layer: *const Hci) bool {
    if (!_hci.le(layer) or layer.le_packets == 0) return false;
    if (!_hci.supports(layer, hci.CMDBIT_LE_SET_ADVERTISING_PARAMETERS) or
        !_hci.supports(layer, hci.CMDBIT_LE_SET_ADVERTISING_DATA) or
        !_hci.supports(layer, hci.CMDBIT_LE_SET_SCAN_RESPONSE_DATA) or
        !_hci.supports(layer, hci.CMDBIT_LE_SET_ADVERTISING_ENABLE)) return false;
    return !layer.have_states or _hci.leState(layer, hci.LE_STATE_ADV);
}

/// Whether the controller advertises beside what `combination`
/// (hci.LE_STATE_ADV_*) pairs it with: never where it did not say.
pub fn beside(layer: *const Hci, combination: u8) bool {
    return layer.have_states and _hci.leState(layer, combination);
}

/// Whether it is wanted now.
fn wanted(layer: *Hci) bool {
    if (layer.state != bluetooth.BTCS_UP or !layer.powered or !layer.visible) return false;
    if (layer.advertising.retry_at != null or !can(layer) or connections.full(layer)) return false;
    if (layer.discovery.phase == .le and !beside(layer, hci.LE_STATE_ADV_ACTIVE_SCAN)) return false;
    if (layer.scan.on and !beside(layer, hci.LE_STATE_ADV_PASSIVE_SCAN)) return false;
    if (connections.makingLe(layer) and !beside(layer, hci.LE_STATE_ADV_INITIATING)) return false;
    if (connections.leRole(layer, true) and !beside(layer, hci.LE_STATE_ADV_CENTRAL)) return false;
    if (connections.leRole(layer, false) and !beside(layer, hci.LE_STATE_ADV_PERIPHERAL)) return false;
    return true;
}

/// Advertising begun, or stopped, as it is wanted now.
pub fn update(layer: *Hci) void {
    const want = wanted(layer);
    if (want == layer.advertising.on) return;
    if (want) begin(layer) else stop(layer);
}

/// The controller asked to advertise - its parameters, what it says, and
/// advertising on - or, with no room for the commands, it tried later.
fn begin(layer: *Hci) void {
    var params: [15]u8 = @splat(0);
    put16(params[0..2], INTERVAL_MIN);
    put16(params[2..4], INTERVAL_MAX);
    params[4] = hci.LE_ADV_IND;
    params[5] = hci.LE_ADDR_PUBLIC; // its own address
    // 6 to 12: the device directed advertising is for - none.
    params[13] = hci.LE_ADV_CHANNELS_ALL;
    params[14] = 0; // any device may scan it and link to it
    if (_hci.QUEUE - layer.queue_count < 4 or
        !_hci.command(layer, hci.HCI_OP_LE_SET_ADVERTISING_PARAMETERS, &params, _hci.COMMAND_TIMEOUT_MS) or
        !writeData(layer) or
        !_hci.command(layer, hci.HCI_OP_LE_SET_ADVERTISING_ENABLE, &.{1}, _hci.COMMAND_TIMEOUT_MS))
    {
        return later(layer);
    }
    layer.advertising.on = true;
    layer.changed = true;
}

/// What it says written, and its scan response: false when their
/// commands could not be queued.
fn writeData(layer: *Hci) bool {
    const flags: u8 = hci.AD_FLAG_GENERAL | @as(u8, if (_hci.bredr(layer)) 0 else hci.AD_FLAG_NO_BREDR);
    // Each its length and the 31 bytes, zeros past it.
    var data: [1 + hci.LE_ADV_DATA_SIZE]u8 = @splat(0);
    data[0] = @intCast(eir.advertisement(data[1..], flags, &layer.name));
    var response: [1 + hci.LE_ADV_DATA_SIZE]u8 = @splat(0);
    response[0] = @intCast(eir.scanResponse(response[1..], &layer.name));
    return _hci.command(layer, hci.HCI_OP_LE_SET_ADVERTISING_DATA, &data, _hci.COMMAND_TIMEOUT_MS) and
        _hci.command(layer, hci.HCI_OP_LE_SET_SCAN_RESPONSE_DATA, &response, _hci.COMMAND_TIMEOUT_MS);
}

/// The controller's advertising turned off, where this asked for it.
pub fn stop(layer: *Hci) void {
    if (!layer.advertising.on) return;
    layer.advertising.on = false;
    layer.changed = true;
    _ = _hci.command(layer, hci.HCI_OP_LE_SET_ADVERTISING_ENABLE, &.{0}, _hci.COMMAND_TIMEOUT_MS);
}

/// Turned off before the controller begins what it cannot do beside
/// advertising - `combination` (hci.LE_STATE_ADV_*) pairs the two: a
/// scan, initiating a link.
pub fn makeWay(layer: *Hci, combination: u8) void {
    if (!beside(layer, combination)) stop(layer);
}

/// A device has made a link to the controller, which no longer
/// advertises.
pub fn linkMade(layer: *Hci) void {
    if (!layer.advertising.on) return;
    layer.advertising.on = false;
    layer.changed = true;
}

/// The name changed: what it says written again while it advertises.
pub fn rename(layer: *Hci) void {
    if (!layer.advertising.on) return;
    if (_hci.QUEUE - layer.queue_count < 2 or !writeData(layer)) later(layer);
}

/// Off, and not tried again for RETRY_MS.
fn later(layer: *Hci) void {
    stop(layer);
    layer.advertising.retry_at = layer.now + RETRY_MS;
}

/// Forgotten without a word to the controller: it is being brought up
/// again, or has failed.
pub fn reset(layer: *Hci) void {
    layer.advertising = .{};
}

/// A command's answer, its status first - empty for one not answered in
/// its time: advertising refused tried again later.
pub fn answered(layer: *Hci, opcode: u16, returned: []const u8) void {
    if (!layer.advertising.on) return;
    switch (opcode) {
        hci.HCI_OP_LE_SET_ADVERTISING_PARAMETERS,
        hci.HCI_OP_LE_SET_ADVERTISING_DATA,
        hci.HCI_OP_LE_SET_SCAN_RESPONSE_DATA,
        hci.HCI_OP_LE_SET_ADVERTISING_ENABLE,
        => {},
        else => return,
    }
    if (returned.len != 0 and returned[0] == hci.HCI_SUCCESS) return;
    later(layer);
}

/// The time refused advertising waited passed: tried again.
pub fn tick(layer: *Hci) void {
    const due = layer.advertising.retry_at orelse return;
    if (layer.now >= due) layer.advertising.retry_at = null;
}

/// When it is tried again; null where it is not waiting to be.
pub fn deadline(layer: *const Hci) ?u64 {
    return layer.advertising.retry_at;
}

fn put16(into: *[2]u8, value: u16) void {
    into[0] = @truncate(value);
    into[1] = @truncate(value >> 8);
}
