// SPDX-License-Identifier: MIT
//! What a controller shows others, and whether it is on.
//!
//! **Its name** goes out in Write Local Name - what a device that asks
//! for it is told - and in its extended inquiry response, where it has
//! one, so that a device that finds it has it at once.
//!
//! **What it answers** is Write Scan Enable's: pages while it is on - it
//! can be connected to - and inquiries too while it is visible - it is
//! found. Over LE it is found by its advertising while it is visible
//! (advertising.zig). Off, it answers nothing and looks for nothing: its
//! discovery is stopped and its links are ended. Visible for a time ends
//! at that time (`tick`); visible until told otherwise has no end;
//! visible while off counts down all the same, and shows again once it
//! is on.
//!
//! **Its name is 247 bytes at most**, one fewer than Write Local Name
//! carries, so that a NUL always ends it there: a controller that reads
//! its name to a NUL - the CYW43455 does - tells a device that asks for
//! one filling all 248 bytes a wrong length, and the device takes a few
//! bytes of it for the whole.
//!
//! The bring-up writes all of it once the controller's settings are in
//! the layer (bringup.zig); each change writes again what it changes.
//! A controller without BR/EDR has neither a name to write nor scans to
//! set: its changes are kept, and say so, and it is visible by its
//! advertising alone - one that cannot advertise either is not made
//! visible.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const _hci = @import("_hci.zig");
const Hci = _hci.Hci;
const advertising = @import("advertising.zig");
const connections = @import("connections.zig");
const discovery = @import("discovery.zig");
const eir = @import("eir.zig");

/// The most bytes the controller's own name has.
pub const NAME_MOST: usize = hci.HCI_MAX_NAME - 1;

/// How much of `text` the controller's name takes: all of it, or what
/// NAME_MOST bytes hold of it - whole characters.
pub fn fitName(text: []const u8) usize {
    if (text.len <= NAME_MOST) return text.len;
    var length = NAME_MOST;
    while (length > 0 and text[length] & 0xC0 == 0x80) length -= 1;
    return length;
}

/// Write Scan Enable's value for the layer as it is set.
pub fn scanEnable(layer: *const Hci) u8 {
    if (!layer.powered) return 0;
    return if (layer.visible) hci.SCAN_PAGE | hci.SCAN_INQUIRY else hci.SCAN_PAGE;
}

/// Whether the controller has an extended inquiry response to write.
pub fn hasResponse(layer: *const Hci) bool {
    return _hci.bredr(layer) and _hci.feature(layer, 0, hci.LMP_EXTENDED_INQUIRY);
}

// --- the commands' parameters, the bring-up's too ----------------------------------

/// Write Scan Enable's.
pub fn scanParams(layer: *const Hci, into: *[hci.HCI_MAX_PARAMS]u8) usize {
    into[0] = scanEnable(layer);
    return 1;
}

/// Write Local Name's: the name up to its NUL, the rest of the 248 bytes
/// zeros.
pub fn nameParams(layer: *const Hci, into: *[hci.HCI_MAX_PARAMS]u8) usize {
    var ended = false;
    for (0..hci.HCI_MAX_NAME) |index| {
        if (layer.name[index] == 0) ended = true;
        into[index] = if (ended) 0 else layer.name[index];
    }
    return hci.HCI_MAX_NAME;
}

/// Write Extended Inquiry Response's: no FEC asked for - the packets
/// without it carry a long name whole - and the response, the name.
pub fn responseParams(layer: *const Hci, into: *[hci.HCI_MAX_PARAMS]u8) usize {
    into[0] = 0;
    eir.response(into[1..][0..hci.EIR_SIZE], &layer.name);
    return 1 + hci.EIR_SIZE;
}

// --- the changes ---------------------------------------------------------------------

/// On or off: 0, or BTERR_NOMEM when its command could not be queued.
pub fn setPowered(layer: *Hci, on: bool) i32 {
    if (layer.powered == on) return 0;
    layer.powered = on;
    layer.changed = true;
    if (!on) {
        discovery.stop(layer);
        connections.dropAll(layer);
    }
    const result = writeScan(layer);
    advertising.update(layer);
    return result;
}

/// Visible for `seconds`, not at all (0), or until told otherwise
/// (BT_VISIBLE_ALWAYS): 0, or BTERR_*.
pub fn setVisible(layer: *Hci, seconds: u32) i32 {
    if (seconds != 0 and !_hci.bredr(layer) and !advertising.can(layer)) return bluetooth.BTERR_UNSUPPORTED;
    layer.visible = seconds != 0;
    layer.visible_until = if (seconds == 0 or seconds == bluetooth.BT_VISIBLE_ALWAYS) null else layer.now + @as(u64, seconds) * 1000;
    layer.changed = true;
    const result = writeScan(layer);
    advertising.update(layer);
    return result;
}

/// The name `text` (up to its NUL) as the controller's, cut to NAME_MOST
/// bytes - whole characters: 0, or BTERR_NOMEM.
pub fn setName(layer: *Hci, text: [*:0]const u8) i32 {
    // A byte past the most, so that a cut sees the character it falls in.
    var given: usize = 0;
    while (given <= NAME_MOST and text[given] != 0) given += 1;
    const length = fitName(text[0..given]);
    for (0..length) |index| layer.name[index] = text[index];
    layer.name[length] = 0;
    layer.changed = true;
    const result = writeName(layer);
    advertising.rename(layer);
    return result;
}

fn writeScan(layer: *Hci) i32 {
    if (!_hci.bredr(layer) or !_hci.supports(layer, hci.CMDBIT_WRITE_SCAN_ENABLE)) return 0;
    var params: [hci.HCI_MAX_PARAMS]u8 = undefined;
    const length = scanParams(layer, &params);
    if (!_hci.command(layer, hci.HCI_OP_WRITE_SCAN_ENABLE, params[0..length], _hci.COMMAND_TIMEOUT_MS)) return bluetooth.BTERR_NOMEM;
    return 0;
}

fn writeName(layer: *Hci) i32 {
    if (!_hci.bredr(layer)) return 0;
    if (_hci.QUEUE - layer.queue_count < 2) return bluetooth.BTERR_NOMEM;
    var params: [hci.HCI_MAX_PARAMS]u8 = undefined;
    if (_hci.supports(layer, hci.CMDBIT_WRITE_LOCAL_NAME)) {
        const length = nameParams(layer, &params);
        _ = _hci.command(layer, hci.HCI_OP_WRITE_LOCAL_NAME, params[0..length], _hci.COMMAND_TIMEOUT_MS);
    }
    if (hasResponse(layer) and _hci.supports(layer, hci.CMDBIT_WRITE_EXTENDED_INQUIRY_RESPONSE)) {
        const length = responseParams(layer, &params);
        _ = _hci.command(layer, hci.HCI_OP_WRITE_EXTENDED_INQUIRY_RESPONSE, params[0..length], _hci.COMMAND_TIMEOUT_MS);
    }
    return 0;
}

// --- the time ---------------------------------------------------------------------

/// Visible for a time ended, once it is up.
pub fn tick(layer: *Hci) void {
    const until = layer.visible_until orelse return;
    if (layer.now < until) return;
    layer.visible = false;
    layer.visible_until = null;
    layer.changed = true;
    _ = writeScan(layer);
    advertising.update(layer);
}

/// When visible for a time ends; null for no end.
pub fn deadline(layer: *const Hci) ?u64 {
    return layer.visible_until;
}

/// How many seconds more it is visible: BT_VISIBLE_ALWAYS for no end, 0
/// while it is not.
pub fn visibleLeft(layer: *const Hci, now: u64) u32 {
    if (!layer.visible) return 0;
    const until = layer.visible_until orelse return bluetooth.BT_VISIBLE_ALWAYS;
    if (until <= now) return 0;
    return @intCast(@min((until - now + 999) / 1000, bluetooth.BT_VISIBLE_ALWAYS - 1));
}
