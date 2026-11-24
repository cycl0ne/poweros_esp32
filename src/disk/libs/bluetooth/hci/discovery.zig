// SPDX-License-Identifier: MIT
//! A discovery: the devices around a controller found, in three phases
//! one after the other -
//!
//!   LE's advertising listened to, actively - every advertiser asked for
//!   its scan response, which often carries its name, from the
//!   controller's private address where it has one (privacy.zig) - each
//!   advertiser reported once (the controller filters the duplicates);
//!   an inquiry, the general one, its results with RSSI and extended ones
//!   where the controller has them (the mode the bring-up set);
//!   the names not heard asked for (Remote Name Request), a BR/EDR device
//!   at a time, the strongest first, each given NAME_TIMEOUT_MS.
//!
//! **The time asked for** is shared by the first two: a third to LE,
//! whose advertisers are heard within a second or two, and two thirds to
//! the inquiry, which a device answers only once the inquiry's train has
//! come to the frequency it listens on. A controller without LE, or
//! without BR/EDR, gives all of it to the one it has. The names take what
//! they take: as long as the devices that answer take, NAME_TIMEOUT_MS
//! for one that does not.
//!
//! **A phase ends** at its time (LE's scan, then turned off), at its
//! controller's word (Inquiry Complete; a name's Remote Name Request
//! Complete), when a command of it is refused or not answered, and when
//! the discovery is stopped - an inquiry cancelled, a name request too,
//! LE's scan turned off. What was found stays in the table
//! (devices.zig); the next discovery begins without it.
//!
//! **The background scan** (scan.zig) is turned off before a discovery
//! begins - its scan is the discovery's own - and on again once it ends;
//! LE's advertising (advertising.zig) too where the controller cannot
//! advertise beside an active scan, until LE's phase is over.
//!
//! **What is heard** goes into the table as it comes: an inquiry's
//! results in all three forms, LE's advertising reports, and the names.
//! A result's layout is the one every controller sends - a result's
//! fields together, one result after the other - and Inquiry Result with
//! RSSI is taken in its longer form too (with the page scan mode a few
//! controllers put in).

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const _hci = @import("_hci.zig");
const Hci = _hci.Hci;
const advertising = @import("advertising.zig");
const devices = @import("devices.zig");
const eir = @import("eir.zig");
const privacy = @import("privacy.zig");
const scan = @import("scan.zig");

/// The shortest and longest a discovery may be asked to take, and what
/// it takes when asked for none.
pub const MIN_MS: u32 = 2000;
pub const MAX_MS: u32 = 60_000;
pub const DEFAULT_MS: u32 = 10_240;
/// How long a name is waited for: a device that does not answer its page
/// has the controller give up after its page timeout, 5.12 s from its
/// reset.
pub const NAME_TIMEOUT_MS: u32 = 10_000;
/// How long the answer to a cancelled name request is waited for, and
/// how long past its length an inquiry may run before it is cancelled.
const CANCEL_WAIT_MS: u32 = 2000;
const INQUIRY_SLACK_MS: u32 = 3000;
/// LE's scan: every 11.25 ms, for all of it (units of 0.625 ms).
const LE_SCAN_INTERVAL: u16 = 0x0012;
const LE_SCAN_WINDOW: u16 = 0x0012;

pub const Phase = enum(u8) { idle, le, inquiry, names };

pub const Discovery = struct {
    phase: Phase = .idle,
    /// When the phase ends, if nothing ends it first.
    deadline: ?u64 = null,
    /// LE's share of the time, and the inquiry's length (units of 1.28
    /// s); 0 for a phase not run.
    le_ms: u32 = 0,
    inquiry_length: u8 = 0,
    /// The names: the device asked, and whether its request is being
    /// cancelled.
    asking: [6]u8 = @splat(0),
    cancelling: bool = false,
};

/// Whether the controller can scan LE's advertising, and inquire.
pub fn canScan(layer: *const Hci) bool {
    return _hci.le(layer) and _hci.supports(layer, hci.CMDBIT_LE_SET_SCAN_PARAMETERS) and _hci.supports(layer, hci.CMDBIT_LE_SET_SCAN_ENABLE);
}

pub fn canInquire(layer: *const Hci) bool {
    return _hci.bredr(layer) and _hci.supports(layer, hci.CMDBIT_INQUIRY);
}

/// Whether a discovery runs.
pub fn running(layer: *const Hci) bool {
    return layer.discovery.phase != .idle;
}

/// A discovery begun for about `ms` (0: DEFAULT_MS), the devices found by
/// the one before forgotten: 0, or BTERR_*. One already running goes on
/// as it is.
pub fn start(layer: *Hci, ms: u32) i32 {
    if (layer.state != bluetooth.BTCS_UP) return bluetooth.BTERR_NOTUP;
    if (!layer.powered) return bluetooth.BTERR_OFF;
    if (running(layer)) return 0;
    const le_too = canScan(layer);
    const inquiry_too = canInquire(layer);
    if (!le_too and !inquiry_too) return bluetooth.BTERR_UNSUPPORTED;
    // Room for the background scan's end, the advertising's and the
    // first phase's commands, so that it surely begins.
    if (_hci.QUEUE - layer.queue_count < 4) return bluetooth.BTERR_NOMEM;
    const total = if (ms == 0) DEFAULT_MS else @min(@max(ms, MIN_MS), MAX_MS);
    const le_ms: u32 = if (!le_too) 0 else if (!inquiry_too) total else total / 3;
    devices.forget(layer);
    layer.discovery = .{
        .le_ms = le_ms,
        .inquiry_length = if (inquiry_too) lengthFor(total - le_ms) else 0,
    };
    layer.changed = true;
    scan.stop(layer);
    if (le_too) advertising.makeWay(layer, hci.LE_STATE_ADV_ACTIVE_SCAN);
    if (le_too) beginLe(layer) else beginInquiry(layer);
    return 0;
}

/// An inquiry's length for `ms`: its units of 1.28 s, rounded up, in the
/// range the command takes.
fn lengthFor(ms: u32) u8 {
    const units = (ms + hci.INQUIRY_UNIT_MS - 1) / hci.INQUIRY_UNIT_MS;
    return @intCast(@min(@max(units, 1), hci.INQUIRY_LENGTH_MAX));
}

/// The discovery stopped now: the phase's work taken back from the
/// controller. What was found stays.
pub fn stop(layer: *Hci) void {
    const discovery = &layer.discovery;
    switch (discovery.phase) {
        .idle => return,
        .le => scanOff(layer),
        .inquiry => _ = _hci.command(layer, hci.HCI_OP_INQUIRY_CANCEL, &.{}, _hci.COMMAND_TIMEOUT_MS),
        .names => if (!discovery.cancelling) cancelName(layer),
    }
    finish(layer);
}

/// The discovery forgotten without a word to the controller: it is being
/// brought up again, or has failed.
pub fn reset(layer: *Hci) void {
    layer.discovery = .{};
}

fn finish(layer: *Hci) void {
    layer.discovery.phase = .idle;
    layer.discovery.deadline = null;
    layer.changed = true;
}

// --- the phases -----------------------------------------------------------------

fn beginLe(layer: *Hci) void {
    const discovery = &layer.discovery;
    const params = [_]u8{
        hci.LE_SCAN_ACTIVE,
        @truncate(LE_SCAN_INTERVAL),
        @truncate(LE_SCAN_INTERVAL >> 8),
        @truncate(LE_SCAN_WINDOW),
        @truncate(LE_SCAN_WINDOW >> 8),
        privacy.scanning(layer), // its own address, as the scan requests carry it
        0, // every advertiser
    };
    if (_hci.QUEUE - layer.queue_count < 2 or
        !_hci.command(layer, hci.HCI_OP_LE_SET_SCAN_PARAMETERS, &params, _hci.COMMAND_TIMEOUT_MS) or
        !_hci.command(layer, hci.HCI_OP_LE_SET_SCAN_ENABLE, &.{ 1, 1 }, _hci.COMMAND_TIMEOUT_MS))
    {
        return afterLe(layer);
    }
    discovery.phase = .le;
    discovery.deadline = layer.now + discovery.le_ms;
}

fn scanOff(layer: *Hci) void {
    _ = _hci.command(layer, hci.HCI_OP_LE_SET_SCAN_ENABLE, &.{ 0, 0 }, _hci.COMMAND_TIMEOUT_MS);
}

/// LE's phase over: its scan turned off, and the inquiry begun.
fn endLe(layer: *Hci) void {
    scanOff(layer);
    afterLe(layer);
}

fn afterLe(layer: *Hci) void {
    if (layer.discovery.inquiry_length != 0) beginInquiry(layer) else beginNames(layer);
}

fn beginInquiry(layer: *Hci) void {
    const discovery = &layer.discovery;
    const lap = hci.LAP_GIAC;
    // Unlimited responses: the inquiry runs for its length.
    const params = [_]u8{ lap[0], lap[1], lap[2], discovery.inquiry_length, 0 };
    if (!_hci.command(layer, hci.HCI_OP_INQUIRY, &params, _hci.COMMAND_TIMEOUT_MS)) return beginNames(layer);
    discovery.phase = .inquiry;
    discovery.deadline = layer.now + @as(u64, discovery.inquiry_length) * hci.INQUIRY_UNIT_MS + INQUIRY_SLACK_MS;
}

fn beginNames(layer: *Hci) void {
    layer.discovery.phase = .names;
    askNext(layer);
}

/// The next name asked for; the discovery over when none is left.
fn askNext(layer: *Hci) void {
    const discovery = &layer.discovery;
    discovery.cancelling = false;
    while (devices.nameWanted(layer)) |device| {
        device.name_asked = true;
        const address = device.address.bytes;
        const offset = device.clock_offset | hci.CLOCK_OFFSET_VALID;
        // Its address, its page scan repetition mode, a reserved byte, and
        // its clock offset, valid.
        var params: [10]u8 = undefined;
        params[0..6].* = address;
        params[6] = device.page_scan_repetition;
        params[7] = 0;
        params[8] = @truncate(offset);
        params[9] = @truncate(offset >> 8);
        if (!_hci.command(layer, hci.HCI_OP_REMOTE_NAME_REQUEST, &params, _hci.COMMAND_TIMEOUT_MS)) {
            device.flags |= bluetooth.BTDF_NO_NAME;
            continue;
        }
        discovery.asking = address;
        discovery.deadline = layer.now + NAME_TIMEOUT_MS;
        return;
    }
    finish(layer);
}

/// The name request out taken back; its answer, which the controller
/// still sends, waited for a while.
fn cancelName(layer: *Hci) void {
    const discovery = &layer.discovery;
    const address = discovery.asking;
    if (devices.find(layer, address, bluetooth.BTADDR_BREDR)) |device| noName(layer, device);
    if (!_hci.supports(layer, hci.CMDBIT_REMOTE_NAME_REQUEST_CANCEL) or
        !_hci.command(layer, hci.HCI_OP_REMOTE_NAME_REQUEST_CANCEL, &address, _hci.COMMAND_TIMEOUT_MS))
    {
        return askNext(layer);
    }
    discovery.cancelling = true;
    discovery.deadline = layer.now + CANCEL_WAIT_MS;
}

/// A device that did not say its name: so marked, unless it has said a
/// shortened one.
fn noName(layer: *Hci, device: *devices.Device) void {
    if (device.name[0] == 0) device.flags |= bluetooth.BTDF_NO_NAME;
    layer.changed = true;
}

/// The phase's time passed, at `layer.now`.
pub fn tick(layer: *Hci) void {
    const discovery = &layer.discovery;
    const due = discovery.deadline orelse return;
    if (layer.now < due) return;
    discovery.deadline = null;
    switch (discovery.phase) {
        .idle => {},
        .le => endLe(layer),
        .inquiry => {
            _ = _hci.command(layer, hci.HCI_OP_INQUIRY_CANCEL, &.{}, _hci.COMMAND_TIMEOUT_MS);
            beginNames(layer);
        },
        .names => if (discovery.cancelling) askNext(layer) else cancelName(layer),
    }
}

/// When the phase ends, if nothing ends it first; null for none.
pub fn deadline(layer: *const Hci) ?u64 {
    if (!running(layer)) return null;
    return layer.discovery.deadline;
}

// --- the controller's answers ---------------------------------------------------

/// A command's answer, its return parameters with the status first - for
/// a command answered by a later event, its status alone when it was
/// refused. A phase whose command was refused is over.
pub fn answered(layer: *Hci, opcode: u16, returned: []const u8) void {
    const refused = returned.len == 0 or returned[0] != hci.HCI_SUCCESS;
    if (!refused) return;
    switch (layer.discovery.phase) {
        .le => if (opcode == hci.HCI_OP_LE_SET_SCAN_PARAMETERS or opcode == hci.HCI_OP_LE_SET_SCAN_ENABLE) endLe(layer),
        .inquiry => if (opcode == hci.HCI_OP_INQUIRY) beginNames(layer),
        .names => if (opcode == hci.HCI_OP_REMOTE_NAME_REQUEST) nameRefused(layer),
        .idle => {},
    }
}

/// A command not answered in its time: as refused.
pub fn timedOut(layer: *Hci, opcode: u16) void {
    answered(layer, opcode, &.{});
}

fn nameRefused(layer: *Hci) void {
    const discovery = &layer.discovery;
    if (discovery.cancelling) return;
    if (devices.find(layer, discovery.asking, bluetooth.BTADDR_BREDR)) |device| noName(layer, device);
    askNext(layer);
}

/// Inquiry Complete: the inquiry over, the names next.
pub fn inquiryComplete(layer: *Hci) void {
    if (layer.discovery.phase != .inquiry) return;
    beginNames(layer);
}

/// The three forms of an inquiry's results.
pub const ResultForm = enum { plain, rssi, extended };

/// Inquiry Result, Inquiry Result with RSSI, Extended Inquiry Result:
/// every device in it into the table.
pub fn inquiryResult(layer: *Hci, params: []const u8, form: ResultForm) void {
    if (!running(layer) or params.len < 1) return;
    const responses: usize = params[0];
    if (responses == 0) return;
    const body = params[1..];
    const size: usize = switch (form) {
        .plain => 14,
        .rssi => if (body.len == responses * 15) 15 else 14,
        .extended => 14 + hci.EIR_SIZE,
    };
    for (0..responses) |index| {
        if ((index + 1) * size > body.len) return;
        takeResult(layer, body[index * size ..][0..size], form);
    }
}

fn takeResult(layer: *Hci, result: []const u8, form: ResultForm) void {
    // Fields after the address: Inquiry Result has the page scan period
    // and mode, the others one reserved byte, the longer RSSI form both.
    const after: usize = if (form == .plain or result.len == 15) 9 else 8;
    const rssi: i8 = switch (form) {
        .plain => bluetooth.BT_RSSI_NONE,
        .rssi, .extended => @bitCast(result[after + 5]),
    };
    const device = devices.heard(layer, result[0..6].*, bluetooth.BTADDR_BREDR, rssi) orelse return;
    device.flags |= bluetooth.BTDF_BREDR;
    device.page_scan_repetition = result[6];
    device.class_of_device = @as(u32, result[after]) | @as(u32, result[after + 1]) << 8 | @as(u32, result[after + 2]) << 16;
    device.clock_offset = _hci.le16(result[after + 3 ..][0..2]) & ~hci.CLOCK_OFFSET_VALID;
    if (rssi != bluetooth.BT_RSSI_NONE) device.rssi = rssi;
    if (form == .extended) eir.take(device, result[14..]);
    layer.changed = true;
}

/// Remote Name Request Complete: the device's name, or that it said
/// none; the next name asked for when it was the one being asked.
pub fn nameComplete(layer: *Hci, params: []const u8) void {
    if (params.len < 7) return;
    const status = params[0];
    const address = params[1..7].*;
    if (devices.find(layer, address, bluetooth.BTADDR_BREDR)) |device| {
        if (status == hci.HCI_SUCCESS) {
            devices.setName(device, params[7..]);
            device.flags &= ~(bluetooth.BTDF_SHORT_NAME | bluetooth.BTDF_NO_NAME);
            layer.changed = true;
        } else noName(layer, device);
    }
    const discovery = &layer.discovery;
    if (discovery.phase == .names and sameAddress(&discovery.asking, &address)) askNext(layer);
}

fn sameAddress(asked: *const [6]u8, answered_for: *const [6]u8) bool {
    for (asked, answered_for) |mine, theirs| {
        if (mine != theirs) return false;
    }
    return true;
}

/// LE Advertising Report, past its subevent: every advertiser in it into
/// the table - a report's fields together, one report after the other.
pub fn advertisingReport(layer: *Hci, params: []const u8) void {
    if (!running(layer) or params.len < 1) return;
    const reports: usize = params[0];
    var at: usize = 1;
    for (0..reports) |_| {
        if (at + 9 > params.len) return;
        const event_type = params[at];
        const address_type = params[at + 1];
        const address = params[at + 2 ..][0..6].*;
        const length: usize = params[at + 8];
        if (at + 9 + length + 1 > params.len) return;
        const data = params[at + 9 ..][0..length];
        const rssi: i8 = @bitCast(params[at + 9 + length]);
        at += 9 + length + 1;
        const kind = switch (address_type) {
            hci.LE_ADDR_PUBLIC, hci.LE_ADDR_PUBLIC_IDENTITY => bluetooth.BTADDR_LE_PUBLIC,
            else => bluetooth.BTADDR_LE_RANDOM,
        };
        const device = devices.heard(layer, address, kind, rssi) orelse continue;
        device.flags |= bluetooth.BTDF_LE;
        if (event_type == hci.LE_ADV_IND or event_type == hci.LE_ADV_DIRECT_IND) device.flags |= bluetooth.BTDF_CONNECTABLE;
        if (rssi != hci.LE_RSSI_NONE) device.rssi = rssi;
        eir.take(device, data);
        layer.changed = true;
    }
}
