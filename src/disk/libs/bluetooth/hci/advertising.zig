// SPDX-License-Identifier: MIT
//! LE's advertising: the controller seen over LE. **Visible** -
//! connectable and scannable, undirected, every 100 to 150 ms on all
//! three channels, from its public address - so that a device that scans
//! finds it by its name and may make a link to it, the controller the
//! link's peripheral. **Hidden**, while a bond says a device was given
//! the machine's identity and the controller has a private address
//! (privacy.zig) - connectable, undirected, every 1 to 1.28 s, from the
//! private address, saying nothing - so that such a device, which
//! resolves the address, finds it within seconds and links to it, and
//! nobody else learns what it is: a link from a device that resolves to
//! no bond is ended at once (connections.zig).
//!
//! **What it says** (eir.zig): visible, its flags - LE General
//! Discoverable, and BR/EDR Not Supported for a controller without it -
//! that it is a computer, as its GATT server says, and its name: complete
//! where it fits, shortened otherwise and then in the scan response too,
//! whole where it fits there. A name changed goes out at once. Hidden,
//! nothing - the flags alone where a controller without BR/EDR needs
//! them - and an empty scan response.
//!
//! **On** while the controller is up and on, visible - or hidden with
//! such a bond and a private address - and can advertise: it has LE's
//! advertising commands and buffers for LE's links, and the state where
//! it said its states; **off** while its link table is full -
//! a link a device made would be ended at once - and while it does what it
//! cannot do beside advertising, as LE Read Supported States answered at
//! the bring-up: a discovery's active scan, the background scan
//! (scan.zig), initiating a link, an LE link up with the controller its
//! central, or its peripheral. A controller that did not say does none of
//! them beside it. Each turns it off before it begins (`makeWay`);
//! `update` sets it as it is wanted after every packet and every tick,
//! and after each change of the settings (local.zig).
//!
//! **One at a time.** A new advertising - the other kind, or the same one
//! begun again - begins only once the controller has answered the end of
//! the last, so that a link a device makes is known by the advertising it
//! was made to: from the private address to the hidden, from the public
//! one to the visible (`linkMade`).
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
const bonds = @import("bonds.zig");
const connections = @import("connections.zig");
const eir = @import("eir.zig");

/// Visible, every 100 to 150 ms (units of 0.625 ms): a scan of a second
/// hears it several times, and it takes about one per cent of the air.
const INTERVAL_MIN: u16 = 0x00A0;
const INTERVAL_MAX: u16 = 0x00F0;
/// Hidden, every 1 to 1.28 s: a device's background scan hears it within
/// seconds, at a tenth of the air.
const HIDDEN_INTERVAL_MIN: u16 = 0x0640;
const HIDDEN_INTERVAL_MAX: u16 = 0x0800;
/// How long refused advertising waits before it is tried again.
pub const RETRY_MS: u32 = 10_000;

/// Visible to every device, or hidden: for the devices that resolve the
/// private address.
pub const Kind = enum(u8) { visible, hidden };

pub const Advertising = struct {
    /// The controller has been asked to advertise.
    on: bool = false,
    /// The kind it began last: the one it advertises while on, and the one
    /// a link a device makes was made to.
    kind: Kind = .visible,
    /// LE Set Advertising Enable commands out, not yet answered: a new
    /// advertising waits until there are none.
    enables_out: u8 = 0,
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

/// The advertising wanted now: visible while the controller is, hidden
/// while a bond says a device was given the machine's identity and there
/// is a private address; null for none.
fn wanted(layer: *Hci) ?Kind {
    if (layer.state != bluetooth.BTCS_UP or !layer.powered) return null;
    if (layer.advertising.retry_at != null or !can(layer) or connections.full(layer)) return null;
    if (layer.discovery.phase == .le and !beside(layer, hci.LE_STATE_ADV_ACTIVE_SCAN)) return null;
    if (layer.scan.on and !beside(layer, hci.LE_STATE_ADV_PASSIVE_SCAN)) return null;
    if (connections.makingLe(layer) and !beside(layer, hci.LE_STATE_ADV_INITIATING)) return null;
    if (connections.leRole(layer, true) and !beside(layer, hci.LE_STATE_ADV_CENTRAL)) return null;
    if (connections.leRole(layer, false) and !beside(layer, hci.LE_STATE_ADV_PERIPHERAL)) return null;
    if (layer.visible) return .visible;
    if (layer.privacy.has and bonds.identityGiven(layer)) return .hidden;
    return null;
}

/// Advertising begun, stopped, or changed for the other kind, as it is
/// wanted now - a new one once the controller has answered the end of the
/// last.
pub fn update(layer: *Hci) void {
    const want = wanted(layer);
    const advertising = &layer.advertising;
    if (advertising.on) {
        if (want) |kind| {
            if (kind == advertising.kind) return;
        }
        stop(layer);
    }
    const kind = want orelse return;
    if (advertising.enables_out != 0) return;
    begin(layer, kind);
}

/// The controller asked to advertise, as `kind` says - its parameters,
/// what it says, and advertising on - or, with no room for the commands,
/// it tried later.
fn begin(layer: *Hci, kind: Kind) void {
    const hidden = kind == .hidden;
    var params: [15]u8 = @splat(0);
    put16(params[0..2], if (hidden) HIDDEN_INTERVAL_MIN else INTERVAL_MIN);
    put16(params[2..4], if (hidden) HIDDEN_INTERVAL_MAX else INTERVAL_MAX);
    params[4] = hci.LE_ADV_IND;
    params[5] = if (hidden) hci.LE_ADDR_RANDOM else hci.LE_ADDR_PUBLIC; // its own address
    // 6 to 12: the device directed advertising is for - none.
    params[13] = hci.LE_ADV_CHANNELS_ALL;
    params[14] = 0; // any device may scan it and link to it
    if (_hci.QUEUE - layer.queue_count < 4 or
        !_hci.command(layer, hci.HCI_OP_LE_SET_ADVERTISING_PARAMETERS, &params, _hci.COMMAND_TIMEOUT_MS) or
        !writeData(layer, kind) or
        !enable(layer, 1))
    {
        return later(layer);
    }
    layer.advertising.on = true;
    layer.advertising.kind = kind;
    layer.changed = true;
}

/// What it says written, and its scan response - visible, its flags,
/// what it is and its name; hidden, nothing but the flags a controller
/// without BR/EDR needs: false when their commands could not be queued.
fn writeData(layer: *Hci, kind: Kind) bool {
    // Each its length and the 31 bytes, zeros past it.
    var data: [1 + hci.LE_ADV_DATA_SIZE]u8 = @splat(0);
    var response: [1 + hci.LE_ADV_DATA_SIZE]u8 = @splat(0);
    switch (kind) {
        .visible => {
            const flags: u8 = hci.AD_FLAG_GENERAL | @as(u8, if (_hci.bredr(layer)) 0 else hci.AD_FLAG_NO_BREDR);
            data[0] = @intCast(eir.advertisement(data[1..], flags, &layer.name));
            response[0] = @intCast(eir.scanResponse(response[1..], &layer.name));
        },
        .hidden => if (!_hci.bredr(layer)) {
            data[1..4].* = .{ 2, hci.AD_FLAGS, hci.AD_FLAG_NO_BREDR };
            data[0] = 3;
        },
    }
    return _hci.command(layer, hci.HCI_OP_LE_SET_ADVERTISING_DATA, &data, _hci.COMMAND_TIMEOUT_MS) and
        _hci.command(layer, hci.HCI_OP_LE_SET_SCAN_RESPONSE_DATA, &response, _hci.COMMAND_TIMEOUT_MS);
}

/// LE Set Advertising Enable - `on` 1 or 0 - counted until it is
/// answered: false when it could not be queued.
fn enable(layer: *Hci, on: u8) bool {
    if (!_hci.command(layer, hci.HCI_OP_LE_SET_ADVERTISING_ENABLE, &.{on}, _hci.COMMAND_TIMEOUT_MS)) return false;
    layer.advertising.enables_out += 1;
    return true;
}

/// The controller's advertising turned off, where this asked for it.
pub fn stop(layer: *Hci) void {
    if (!layer.advertising.on) return;
    layer.advertising.on = false;
    layer.changed = true;
    _ = enable(layer, 0);
}

/// Turned off before the controller begins what it cannot do beside
/// advertising - `combination` (hci.LE_STATE_ADV_*) pairs the two: a
/// scan, initiating a link.
pub fn makeWay(layer: *Hci, combination: u8) void {
    if (!beside(layer, combination)) stop(layer);
}

/// A device has made a link to the controller, which no longer
/// advertises: the kind of advertising the link was made to - the one
/// begun last, whether on or being ended, as no other begins before the
/// controller has answered its end.
pub fn linkMade(layer: *Hci) Kind {
    if (layer.advertising.on) {
        layer.advertising.on = false;
        layer.changed = true;
    }
    return layer.advertising.kind;
}

/// The name changed: what it says written again while it advertises
/// visibly - hidden, it says no name.
pub fn rename(layer: *Hci) void {
    if (!layer.advertising.on or layer.advertising.kind != .visible) return;
    if (_hci.QUEUE - layer.queue_count < 2 or !writeData(layer, .visible)) later(layer);
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
/// its time: an enable or its end counted off, advertising refused tried
/// again later.
pub fn answered(layer: *Hci, opcode: u16, returned: []const u8) void {
    const advertising = &layer.advertising;
    if (opcode == hci.HCI_OP_LE_SET_ADVERTISING_ENABLE and advertising.enables_out != 0) advertising.enables_out -= 1;
    if (!advertising.on) return;
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
