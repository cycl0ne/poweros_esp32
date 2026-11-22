// SPDX-License-Identifier: MIT
//! A controller brought up: the commands it is given once its device is
//! open, one after the other, each when the one before is answered -
//!
//!   Reset; Read Local Version Information; Read Local Supported Commands
//!   (from HCI 1.2 on); Read Local Supported Features, and the extended
//!   pages 1 and 2 where it has them; Read Buffer Size (BR/EDR);
//!   Read BD_ADDR; LE Read Buffer Size and LE Read Local Supported
//!   Features (LE); Set Event Mask; LE Set Event Mask; Write Simple
//!   Pairing Mode; Write LE Host Supported; Write Class of Device and
//!   Write Local Name (BR/EDR); feature page 1 read again, now with what
//!   the host switched on.
//!
//! **A step is sent only where it belongs**: a step for LE only to a
//! controller that has LE, one for BR/EDR only to one that has BR/EDR,
//! and none the controller says it does not take (its supported-commands
//! mask, once it has answered with it). A step that is not required -
//! everything but the reset and what the stack cannot run without (the
//! version, the features, the buffers, the address) - is passed over
//! when the controller refuses it. A required one refused, an answer too
//! short to be one, or any step not answered in its time, and the
//! controller is given up on.
//!
//! **The events asked for** are those the stack takes now or will, and
//! that the controller can send at all: a feature it lacks leaves its
//! events out, which keeps controllers that refuse a mask with bits they
//! do not know working.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const _hci = @import("_hci.zig");
const Hci = _hci.Hci;

/// The reset can take a controller longer than another command.
const RESET_TIMEOUT_MS: u32 = 5000;

const Step = struct {
    opcode: u16,
    /// The command's bit in the supported-commands mask.
    bit: u16,
    /// Whether the step is a fault when it fails.
    required: bool = false,
    timeout_ms: u32 = _hci.COMMAND_TIMEOUT_MS,
    /// Whether the controller is given it at all; null: always.
    wanted: ?*const fn (*const Hci) bool = null,
    /// Its parameters, written into the room given: their length.
    params: ?*const fn (*const Hci, *[hci.HCI_MAX_PARAMS]u8) usize = null,
    /// What the answer's return parameters say, the status first and
    /// already looked at: false for an answer too short to be one.
    took: ?*const fn (*Hci, []const u8) bool = null,
};

const steps = [_]Step{
    .{ .opcode = hci.HCI_OP_RESET, .bit = hci.CMDBIT_RESET, .required = true, .timeout_ms = RESET_TIMEOUT_MS },
    .{ .opcode = hci.HCI_OP_READ_LOCAL_VERSION, .bit = hci.CMDBIT_READ_LOCAL_VERSION, .required = true, .took = tookVersion },
    .{ .opcode = hci.HCI_OP_READ_LOCAL_COMMANDS, .bit = hci.CMDBIT_READ_LOCAL_COMMANDS, .wanted = hasCommandMask, .took = tookCommands },
    .{ .opcode = hci.HCI_OP_READ_LOCAL_FEATURES, .bit = hci.CMDBIT_READ_LOCAL_FEATURES, .required = true, .took = tookFeatures },
    .{ .opcode = hci.HCI_OP_READ_LOCAL_EXT_FEATURES, .bit = hci.CMDBIT_READ_LOCAL_EXT_FEATURES, .wanted = hasPages, .params = pageOne, .took = tookPage },
    .{ .opcode = hci.HCI_OP_READ_LOCAL_EXT_FEATURES, .bit = hci.CMDBIT_READ_LOCAL_EXT_FEATURES, .wanted = hasPageTwo, .params = pageTwo, .took = tookPage },
    .{ .opcode = hci.HCI_OP_READ_BUFFER_SIZE, .bit = hci.CMDBIT_READ_BUFFER_SIZE, .required = true, .wanted = _hci.bredr, .took = tookBufferSize },
    .{ .opcode = hci.HCI_OP_READ_BD_ADDR, .bit = hci.CMDBIT_READ_BD_ADDR, .required = true, .took = tookAddress },
    .{ .opcode = hci.HCI_OP_LE_READ_BUFFER_SIZE, .bit = hci.CMDBIT_LE_READ_BUFFER_SIZE, .wanted = _hci.le, .took = tookLeBufferSize },
    .{ .opcode = hci.HCI_OP_LE_READ_LOCAL_FEATURES, .bit = hci.CMDBIT_LE_READ_LOCAL_FEATURES, .wanted = _hci.le, .took = tookLeFeatures },
    .{ .opcode = hci.HCI_OP_SET_EVENT_MASK, .bit = hci.CMDBIT_SET_EVENT_MASK, .wanted = hasEventMask, .params = eventMask },
    .{ .opcode = hci.HCI_OP_LE_SET_EVENT_MASK, .bit = hci.CMDBIT_LE_SET_EVENT_MASK, .wanted = _hci.le, .params = leEventMask },
    .{ .opcode = hci.HCI_OP_WRITE_SIMPLE_PAIRING_MODE, .bit = hci.CMDBIT_WRITE_SIMPLE_PAIRING_MODE, .wanted = hasSimplePairing, .params = switchedOn },
    .{ .opcode = hci.HCI_OP_WRITE_LE_HOST_SUPPORTED, .bit = hci.CMDBIT_WRITE_LE_HOST_SUPPORTED, .wanted = isDualMode, .params = leHost },
    .{ .opcode = hci.HCI_OP_WRITE_CLASS_OF_DEVICE, .bit = hci.CMDBIT_WRITE_CLASS_OF_DEVICE, .wanted = _hci.bredr, .params = classOfDevice },
    .{ .opcode = hci.HCI_OP_WRITE_LOCAL_NAME, .bit = hci.CMDBIT_WRITE_LOCAL_NAME, .wanted = _hci.bredr, .params = localName },
    .{ .opcode = hci.HCI_OP_READ_LOCAL_EXT_FEATURES, .bit = hci.CMDBIT_READ_LOCAL_EXT_FEATURES, .wanted = hasPages, .params = pageOne, .took = tookPage },
};

/// The next step the controller is to be given, from `layer.step` on,
/// sent; past the last, the controller is up.
pub fn next(layer: *Hci) void {
    while (layer.step < steps.len) : (layer.step += 1) {
        const step = steps[layer.step];
        if (step.wanted) |wanted| {
            if (!wanted(layer)) continue;
        }
        if (!_hci.supports(layer, step.bit)) {
            if (step.required) return _hci.fail(layer, hci.HCI_ERR_UNKNOWN_COMMAND);
            continue;
        }
        var params: [hci.HCI_MAX_PARAMS]u8 = undefined;
        const length = if (step.params) |make| make(layer, &params) else 0;
        if (!_hci.command(layer, step.opcode, params[0..length], step.timeout_ms)) return _hci.fail(layer, bluetooth.BTERR_NOMEM);
        return;
    }
    layer.state = bluetooth.BTCS_UP;
    layer.changed = true;
}

/// The step being run answered: what it says taken, and the next sent.
/// An answer to anything else is not the bring-up's.
pub fn answered(layer: *Hci, opcode: u16, returned: []const u8) void {
    if (layer.step >= steps.len) return;
    const step = steps[layer.step];
    if (step.opcode != opcode) return;
    if (returned.len == 0) {
        if (step.required) return _hci.fail(layer, bluetooth.BTERR_PROTOCOL);
    } else if (returned[0] != hci.HCI_SUCCESS) {
        if (step.required) return _hci.fail(layer, returned[0]);
    } else if (step.took) |took| {
        if (!took(layer, returned) and step.required) return _hci.fail(layer, bluetooth.BTERR_PROTOCOL);
    }
    layer.step += 1;
    next(layer);
}

/// A step not answered in its time: the controller is given up on.
pub fn timedOut(layer: *Hci, opcode: u16) void {
    if (layer.step >= steps.len or steps[layer.step].opcode != opcode) return;
    _hci.fail(layer, bluetooth.BTERR_TIMEOUT);
}

// --- whether a step is wanted -------------------------------------------------

fn hasCommandMask(layer: *const Hci) bool {
    return layer.hci_version > hci.BT_VERSION_1_1;
}

fn hasPages(layer: *const Hci) bool {
    return _hci.feature(layer, 0, hci.LMP_EXTENDED_FEATURES);
}

fn hasPageTwo(layer: *const Hci) bool {
    return hasPages(layer) and layer.max_page >= 2;
}

fn hasEventMask(layer: *const Hci) bool {
    return layer.hci_version >= hci.BT_VERSION_1_2;
}

fn hasSimplePairing(layer: *const Hci) bool {
    return _hci.bredr(layer) and _hci.feature(layer, 0, hci.LMP_SIMPLE_PAIRING);
}

fn isDualMode(layer: *const Hci) bool {
    return _hci.bredr(layer) and _hci.le(layer);
}

// --- the parameters -----------------------------------------------------------

fn pageOne(_: *const Hci, into: *[hci.HCI_MAX_PARAMS]u8) usize {
    into[0] = 1;
    return 1;
}

fn pageTwo(_: *const Hci, into: *[hci.HCI_MAX_PARAMS]u8) usize {
    into[0] = 2;
    return 1;
}

fn switchedOn(_: *const Hci, into: *[hci.HCI_MAX_PARAMS]u8) usize {
    into[0] = 1;
    return 1;
}

/// LE on for the host; simultaneous LE and BR/EDR to the same device, a
/// deprecated mode, off.
fn leHost(_: *const Hci, into: *[hci.HCI_MAX_PARAMS]u8) usize {
    into[0] = 1;
    into[1] = 0;
    return 2;
}

fn classOfDevice(layer: *const Hci, into: *[hci.HCI_MAX_PARAMS]u8) usize {
    into[0] = @truncate(layer.class_of_device);
    into[1] = @truncate(layer.class_of_device >> 8);
    into[2] = @truncate(layer.class_of_device >> 16);
    return 3;
}

/// The name, up to its NUL, the rest of the 248 bytes zeros.
fn localName(layer: *const Hci, into: *[hci.HCI_MAX_PARAMS]u8) usize {
    var ended = false;
    for (0..hci.HCI_MAX_NAME) |index| {
        if (layer.name[index] == 0) ended = true;
        into[index] = if (ended) 0 else layer.name[index];
    }
    return hci.HCI_MAX_NAME;
}

fn bit(n: u6) u64 {
    return @as(u64, 1) << n;
}

/// Set Event Mask's mask: every event of the first 32 but the one bit
/// the specification reserves among them (18), and of the rest those of
/// the features the controller has.
fn eventMask(layer: *const Hci, into: *[hci.HCI_MAX_PARAMS]u8) usize {
    var mask: u64 = 0;
    if (_hci.bredr(layer)) {
        mask = 0xFFFB_FFFF;
        mask |= bit(32); // Flow Specification Complete
        if (_hci.feature(layer, 0, hci.LMP_RSSI_INQUIRY)) mask |= bit(33); // Inquiry Result with RSSI
        if (_hci.feature(layer, 0, hci.LMP_EXTENDED_FEATURES)) mask |= bit(34); // Read Remote Extended Features Complete
        if (_hci.feature(layer, 0, hci.LMP_ESCO)) mask |= bit(43) | bit(44); // Synchronous Connection Complete, Changed
        if (_hci.feature(layer, 0, hci.LMP_SNIFF_SUBRATING)) mask |= bit(45);
        if (_hci.feature(layer, 0, hci.LMP_EXTENDED_INQUIRY)) mask |= bit(46); // Extended Inquiry Result
        if (_hci.feature(layer, 0, hci.LMP_PAUSE_ENCRYPTION)) mask |= bit(47); // Encryption Key Refresh Complete
        if (_hci.feature(layer, 0, hci.LMP_SIMPLE_PAIRING)) {
            // IO Capability Request and Response, User Confirmation and
            // Passkey Requests, Remote OOB Data Request, Simple Pairing
            // Complete; User Passkey and Keypress Notifications, Remote
            // Host Supported Features Notification.
            mask |= bit(48) | bit(49) | bit(50) | bit(51) | bit(52) | bit(53);
            mask |= bit(58) | bit(59) | bit(60);
        }
        if (_hci.feature(layer, 0, hci.LMP_SUPERVISION_TIMEOUT_EVENT)) mask |= bit(55);
        if (_hci.feature(layer, 0, hci.LMP_NON_FLUSHABLE)) mask |= bit(56); // Enhanced Flush Complete
    } else {
        // Disconnection Complete, Read Remote Version Information
        // Complete, Hardware Error, Data Buffer Overflow.
        mask = bit(4) | bit(11) | bit(15) | bit(25);
        if (_hci.leFeature(layer, hci.LE_FEATURE_ENCRYPTION)) mask |= bit(7) | bit(47);
    }
    if (_hci.le(layer)) mask |= bit(61); // LE Meta
    for (0..8) |index| into[index] = @truncate(mask >> @intCast(index * 8));
    return 8;
}

/// LE Set Event Mask's: the five a controller sends after its reset
/// (connections, advertising reports, connection updates, remote
/// features, long-term key requests), and the requests to change a
/// connection's parameters and its data length where it has them.
fn leEventMask(layer: *const Hci, into: *[hci.HCI_MAX_PARAMS]u8) usize {
    var mask: u64 = 0x1F;
    if (_hci.leFeature(layer, hci.LE_FEATURE_CONNECTION_PARAMETERS_REQUEST)) mask |= bit(5);
    if (_hci.leFeature(layer, hci.LE_FEATURE_DATA_LENGTH)) mask |= bit(6);
    for (0..8) |index| into[index] = @truncate(mask >> @intCast(index * 8));
    return 8;
}

// --- what the answers say -----------------------------------------------------

fn tookVersion(layer: *Hci, returned: []const u8) bool {
    if (returned.len < 9) return false;
    layer.hci_version = returned[1];
    layer.hci_revision = _hci.le16(returned[2..4]);
    layer.lmp_version = returned[4];
    layer.manufacturer = _hci.le16(returned[5..7]);
    layer.lmp_subversion = _hci.le16(returned[7..9]);
    return true;
}

fn tookCommands(layer: *Hci, returned: []const u8) bool {
    if (returned.len < 1 + 64) return false;
    for (returned[1..65], 0..) |byte, index| layer.commands[index] = byte;
    layer.have_commands = true;
    return true;
}

fn tookFeatures(layer: *Hci, returned: []const u8) bool {
    if (returned.len < 1 + 8) return false;
    for (returned[1..9], 0..) |byte, index| layer.features[0][index] = byte;
    return true;
}

fn tookPage(layer: *Hci, returned: []const u8) bool {
    if (returned.len < 3 + 8) return false;
    const page = returned[1];
    layer.max_page = returned[2];
    if (page >= 1 and page <= 2) {
        for (returned[3..11], 0..) |byte, index| layer.features[page][index] = byte;
    }
    return true;
}

fn tookBufferSize(layer: *Hci, returned: []const u8) bool {
    if (returned.len < 8) return false;
    layer.acl_mtu = _hci.le16(returned[1..3]);
    layer.sco_mtu = returned[3];
    layer.acl_packets = _hci.le16(returned[4..6]);
    layer.sco_packets = _hci.le16(returned[6..8]);
    return true;
}

fn tookAddress(layer: *Hci, returned: []const u8) bool {
    if (returned.len < 7) return false;
    for (returned[1..7], 0..) |byte, index| layer.address[index] = byte;
    return true;
}

/// LE's buffers; none of its own (a length of 0) shares BR/EDR's.
fn tookLeBufferSize(layer: *Hci, returned: []const u8) bool {
    if (returned.len < 4) return false;
    const mtu = _hci.le16(returned[1..3]);
    if (mtu == 0) {
        layer.le_mtu = layer.acl_mtu;
        layer.le_packets = layer.acl_packets;
    } else {
        layer.le_mtu = mtu;
        layer.le_packets = returned[3];
    }
    return true;
}

fn tookLeFeatures(layer: *Hci, returned: []const u8) bool {
    if (returned.len < 1 + 8) return false;
    for (returned[1..9], 0..) |byte, index| layer.le_features[index] = byte;
    return true;
}
