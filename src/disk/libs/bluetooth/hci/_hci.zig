// SPDX-License-Identifier: MIT
//! The HCI as the library speaks it to one controller: the commands it
//! sends, within the controller's credits; the events it takes, each
//! answer matched to the command it answers; a time-out for each command;
//! what the controller said it is, which bringup.zig asks for; what it
//! shows others and whether it is on (local.zig); the devices it found
//! (discovery.zig, devices.zig); its links to devices (connections.zig)
//! and the data on them (acl.zig), which L2CAP's channels carry
//! (l2cap/); its pairings (pairing.zig; over LE the security manager,
//! smp.zig) and the bonds they leave (bonds.zig).
//!
//! **Pure.** Nothing here calls exec or waits: the task hands in each
//! packet that came (`received`), the time (`now`) and the time-outs
//! (`tick`), and the layer sends through its `Port`, a packet at a time;
//! the security manager's cipher, random bytes and curve come through
//! its `crypto` port (smpcrypto.zig).
//! So the host tests run it against a script, and the task runs it on
//! the controller's requests.
//!
//! **Credits.** The controller says, in every Command Complete and
//! Command Status, how many commands it takes now; the layer sends no
//! more than that, and keeps the rest in its queue, in order. A command
//! that is not answered in its time is given up, and the controller is
//! taken to have room for one again.
//!
//! **Under the controllers' lock.** The task changes a layer under the
//! base's lock and ObtainBTControllers reads it under the lock shared, so
//! a lister sees a controller between two packets, never inside one.
//!
//! **Its own times** - a discovery's phase, the end of being visible for
//! a time, a link being made or ended, a pairing and its agent's answer -
//! are deadlines like a command's:
//! `nextDeadline` answers the earliest of them all, and `tick` runs
//! whichever has passed.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const hcidev = sdk.devices.hci;
const acl = @import("acl.zig");
const bonds = @import("bonds.zig");
const bringup = @import("bringup.zig");
const connections = @import("connections.zig");
const devices = @import("devices.zig");
const discovery = @import("discovery.zig");
const local = @import("local.zig");
const pairing = @import("pairing.zig");
const smpcrypto = @import("smpcrypto.zig");

/// How many commands wait for their turn - room for every link's end
/// when the power goes off - and how many may be out at once.
pub const QUEUE = 16;
pub const PENDING = 4;

/// The longest a command is waited for, unless it says otherwise.
pub const COMMAND_TIMEOUT_MS: u32 = 2000;

/// How the layer reaches its controller.
pub const Port = struct {
    context: *anyopaque,
    /// A packet sent, from its header on: false if the transport cannot
    /// take one now - the layer tries again after `sent`.
    send: *const fn (context: *anyopaque, packet_type: u8, bytes: []const u8) bool,
};

/// A command waiting for its turn: its opcode, parameters and time.
const Queued = struct {
    opcode: u16 = 0,
    length: u8 = 0,
    timeout_ms: u32 = COMMAND_TIMEOUT_MS,
    params: [hci.HCI_MAX_PARAMS]u8 = undefined,
};

/// A command sent, waiting for its answer until `deadline`.
const Pending = struct {
    used: bool = false,
    opcode: u16 = 0,
    deadline: u64 = 0,
};

pub const Hci = struct {
    port: Port,
    /// The security manager's cryptography; null where there is none, and
    /// LE pairs with nobody.
    crypto: ?smpcrypto.Crypto = null,
    /// The time in milliseconds, as the task last read it.
    now: u64 = 0,
    /// BTCS_*, and BTController.failure.
    state: u32 = bluetooth.BTCS_OPENING,
    failure: i32 = 0,
    /// Set by whatever a lister would see differently; the task clears
    /// it after telling whoever asked.
    changed: bool = false,
    /// Commands the controller takes now.
    credits: u8 = 1,
    /// The bring-up's step (bringup.zig), and how often it started over.
    step: u8 = 0,
    restarts: u8 = 0,
    queue: [QUEUE]Queued = @splat(.{}),
    queue_head: u8 = 0,
    queue_count: u8 = 0,
    pending: [PENDING]Pending = @splat(.{}),

    // What the controller said it is; BTController's fields.
    address: [6]u8 = @splat(0),
    hci_version: u8 = 0,
    lmp_version: u8 = 0,
    hci_revision: u16 = 0,
    lmp_subversion: u16 = 0,
    manufacturer: u16 = 0,
    features: [3][8]u8 = @splat(@splat(0)),
    /// The highest feature page it has.
    max_page: u8 = 0,
    le_features: [8]u8 = @splat(0),
    commands: [64]u8 = @splat(0),
    /// Whether it answered Read Local Supported Commands: until it has,
    /// every command is taken to be there.
    have_commands: bool = false,
    acl_mtu: u16 = 0,
    acl_packets: u16 = 0,
    le_mtu: u16 = 0,
    le_packets: u16 = 0,
    sco_mtu: u16 = 0,
    sco_packets: u16 = 0,
    /// What it shows others: its class of device, and its name, ended by
    /// a NUL - set by the task before the bring-up writes them.
    class_of_device: u32 = 0,
    name: [hci.HCI_MAX_NAME + 1]u8 = @splat(0),

    // Its settings (local.zig): on, visible and until when - null for no
    // end. The bring-up stops once the address is known and asks for
    // them (`wants_settings`); the task puts them here and lets it go on
    // (bringup.settled), and a bring-up after that one has them.
    powered: bool = true,
    visible: bool = false,
    visible_until: ?u64 = null,
    wants_settings: bool = false,
    settled: bool = false,

    /// Its discovery, and what it found.
    discovery: discovery.Discovery = .{},
    devices: [devices.DEVICES]devices.Device = @splat(.{}),

    /// Its links (connections.zig) and the calls waiting on them; the
    /// ACL data's (acl.zig): the frames waiting to be sent, the buffers
    /// the controller has free - BR/EDR's, and LE's where it has its own
    /// - and the room a packet is put together in.
    connections: [connections.CONNECTIONS]connections.Connection = @splat(.{}),
    waits: [connections.WAITS]connections.Wait = @splat(.{}),
    out: [acl.OUT]acl.Out = @splat(.{}),
    out_head: u8 = 0,
    out_count: u8 = 0,
    acl_credits: u16 = 0,
    le_credits: u16 = 0,
    le_own: bool = false,
    acl_packet: [hci.HCI_ACL_HDR + acl.PACKET_MOST]u8 = undefined,
    /// What happened to its links since the task last said it in the log.
    notes: [connections.NOTES]connections.Note = @splat(.{}),
    note_count: u8 = 0,
    /// The agent that answers the pairings a device begins - the one
    /// added last, by its number, 0 for none - and what its user can do
    /// (BTIO_*). What agents are to be told, which the task sends.
    agent_current: u32 = 0,
    agent_capability: u32 = 0,
    notices: [pairing.NOTICES]pairing.Notice = @splat(.{}),
    notice_count: u8 = 0,
    /// Its bonds (bonds.zig), and whether one is to be written.
    bonds: [bonds.BONDS]bonds.Bond = @splat(.{}),
    bonds_changed: bool = false,
};

/// Whether feature `n` of page `page` is set.
pub fn feature(layer: *const Hci, page: u8, n: u8) bool {
    if (page > 2) return false;
    return layer.features[page][n / 8] & (@as(u8, 1) << @intCast(n % 8)) != 0;
}

/// Whether LE feature `n` is set.
pub fn leFeature(layer: *const Hci, n: u8) bool {
    return layer.le_features[n / 8] & (@as(u8, 1) << @intCast(n % 8)) != 0;
}

/// Whether the controller takes the command at bit `n` of its mask (any,
/// while it has not said).
pub fn supports(layer: *const Hci, n: u16) bool {
    if (!layer.have_commands) return true;
    return layer.commands[n / 8] & (@as(u8, 1) << @intCast(n % 8)) != 0;
}

/// Whether it does BR/EDR, and LE.
pub fn bredr(layer: *const Hci) bool {
    return !feature(layer, 0, hci.LMP_BREDR_NOT_SUPPORTED);
}
pub fn le(layer: *const Hci) bool {
    return feature(layer, 0, hci.LMP_LE);
}

/// The bring-up started from the beginning: the queue, what was out and
/// the links forgotten - a call waiting on one answered that the
/// hardware failed - the controller reset.
pub fn start(layer: *Hci) void {
    layer.state = bluetooth.BTCS_STARTING;
    layer.failure = 0;
    layer.changed = true;
    layer.credits = 1;
    layer.queue_count = 0;
    layer.queue_head = 0;
    for (&layer.pending) |*pending| pending.used = false;
    layer.step = 0;
    layer.wants_settings = false;
    discovery.reset(layer);
    connections.reset(layer, hci.HCI_ERR_HARDWARE_FAILURE);
    bringup.next(layer);
}

/// The controller given up on: BTCS_FAILED with `failure`, nothing more
/// sent, a call waiting on a link answered `failure`.
pub fn fail(layer: *Hci, failure: i32) void {
    layer.state = bluetooth.BTCS_FAILED;
    layer.failure = failure;
    layer.changed = true;
    layer.queue_count = 0;
    for (&layer.pending) |*pending| pending.used = false;
    layer.wants_settings = false;
    discovery.reset(layer);
    connections.reset(layer, failure);
}

/// A command queued, and sent if the controller takes it now: false when
/// the queue is full or its parameters are too long.
pub fn command(layer: *Hci, opcode: u16, params: []const u8, timeout_ms: u32) bool {
    if (layer.state == bluetooth.BTCS_FAILED) return false;
    if (layer.queue_count == QUEUE or params.len > hci.HCI_MAX_PARAMS) return false;
    const slot = &layer.queue[(layer.queue_head + layer.queue_count) % QUEUE];
    slot.opcode = opcode;
    slot.length = @intCast(params.len);
    slot.timeout_ms = timeout_ms;
    for (params, 0..) |byte, index| slot.params[index] = byte;
    layer.queue_count += 1;
    pump(layer);
    return true;
}

/// The queue's commands sent while the controller has credits and a
/// pending slot is free - on a new command, an answer, and once the
/// transport takes packets again - and then the ACL data waiting.
pub fn pump(layer: *Hci) void {
    sendCommands(layer);
    if (layer.state == bluetooth.BTCS_UP) acl.pump(layer);
}

fn sendCommands(layer: *Hci) void {
    while (layer.queue_count > 0 and layer.credits > 0) {
        const pending = freePending(layer) orelse return;
        const slot = &layer.queue[layer.queue_head];
        var packet: [hci.HCI_COMMAND_HDR + hci.HCI_MAX_PARAMS]u8 = undefined;
        packet[0] = @truncate(slot.opcode);
        packet[1] = @truncate(slot.opcode >> 8);
        packet[2] = slot.length;
        for (slot.params[0..slot.length], 0..) |byte, index| packet[hci.HCI_COMMAND_HDR + index] = byte;
        if (!layer.port.send(layer.port.context, hcidev.HCI_COMMAND_PKT, packet[0 .. hci.HCI_COMMAND_HDR + slot.length])) return;
        pending.* = .{ .used = true, .opcode = slot.opcode, .deadline = layer.now + slot.timeout_ms };
        layer.credits -= 1;
        layer.queue_head = (layer.queue_head + 1) % QUEUE;
        layer.queue_count -= 1;
    }
}

fn freePending(layer: *Hci) ?*Pending {
    for (&layer.pending) |*pending| {
        if (!pending.used) return pending;
    }
    return null;
}

/// The command out with this opcode taken off as answered: whether there
/// was one - false for an answer to nothing the layer sent.
fn takePending(layer: *Hci, opcode: u16) bool {
    var oldest: ?*Pending = null;
    for (&layer.pending) |*pending| {
        if (!pending.used or pending.opcode != opcode) continue;
        if (oldest == null or pending.deadline < oldest.?.deadline) oldest = pending;
    }
    const found = oldest orelse return false;
    found.used = false;
    return true;
}

/// The earliest time something is due: a command out to be answered, a
/// discovery's phase to end, being visible to end, a link being made or
/// ended; null for none.
pub fn nextDeadline(layer: *const Hci) ?u64 {
    var earliest: ?u64 = null;
    for (&layer.pending) |*pending| {
        if (!pending.used) continue;
        if (earliest == null or pending.deadline < earliest.?) earliest = pending.deadline;
    }
    if (layer.state != bluetooth.BTCS_UP) return earliest;
    for ([_]?u64{ discovery.deadline(layer), local.deadline(layer), connections.deadline(layer), pairing.deadline(layer) }) |due| {
        const time = due orelse continue;
        if (earliest == null or time < earliest.?) earliest = time;
    }
    return earliest;
}

/// Whatever is due at `layer.now` done: the commands whose time has
/// passed given up on, a discovery's phase ended, being visible ended, a
/// link's making taken back or given up on.
pub fn tick(layer: *Hci) void {
    for (&layer.pending) |*pending| {
        if (!pending.used or pending.deadline > layer.now) continue;
        pending.used = false;
        // The controller lost it, or its answer: it is taken to have room
        // for one command again.
        if (layer.credits == 0) layer.credits = 1;
        timedOut(layer, pending.opcode);
    }
    if (layer.state == bluetooth.BTCS_UP) {
        discovery.tick(layer);
        local.tick(layer);
        connections.tick(layer);
        pairing.tick(layer);
    }
    pump(layer);
}

fn timedOut(layer: *Hci, opcode: u16) void {
    switch (layer.state) {
        bluetooth.BTCS_STARTING => bringup.timedOut(layer, opcode),
        bluetooth.BTCS_UP => {
            discovery.timedOut(layer, opcode);
            connections.answered(layer, opcode, &.{});
            pairing.answered(layer, opcode, &.{});
        },
        else => {},
    }
}

/// A packet the controller sent, from its header on: an event, or a
/// link's data.
pub fn received(layer: *Hci, packet_type: u8, bytes: []const u8) void {
    switch (packet_type) {
        hcidev.HCI_EVENT_PKT => {
            if (bytes.len < hci.HCI_EVENT_HDR) return;
            const length = @min(bytes[1], bytes.len - hci.HCI_EVENT_HDR);
            event(layer, bytes[0], bytes[hci.HCI_EVENT_HDR..][0..length]);
        },
        hcidev.HCI_ACLDATA_PKT => if (layer.state == bluetooth.BTCS_UP) acl.received(layer, bytes),
        else => {},
    }
}

fn event(layer: *Hci, code: u8, params: []const u8) void {
    switch (code) {
        hci.HCI_EV_COMMAND_COMPLETE => {
            if (params.len < 3) return;
            layer.credits = params[0];
            const opcode = @as(u16, params[1]) | @as(u16, params[2]) << 8;
            // Opcode 0 only gives credits.
            if (opcode != 0 and takePending(layer, opcode)) completed(layer, opcode, params[3..]);
            pump(layer);
        },
        hci.HCI_EV_COMMAND_STATUS => {
            if (params.len < 4) return;
            const status = params[0];
            layer.credits = params[1];
            const opcode = @as(u16, params[2]) | @as(u16, params[3]) << 8;
            if (opcode != 0 and takePending(layer, opcode)) {
                // A command answered by a later event has started; one
                // refused, or one the controller does not know, is
                // answered here with its status alone.
                if (status != hci.HCI_SUCCESS) completed(layer, opcode, params[0..1]);
            }
            pump(layer);
        },
        hci.HCI_EV_HARDWARE_ERROR => hardwareError(layer),
        else => if (layer.state == bluetooth.BTCS_UP) upEvent(layer, code, params),
    }
}

/// The events of a controller that is up: what its discovery hears, its
/// links, and their pairings.
fn upEvent(layer: *Hci, code: u8, params: []const u8) void {
    switch (code) {
        hci.HCI_EV_INQUIRY_COMPLETE => discovery.inquiryComplete(layer),
        hci.HCI_EV_INQUIRY_RESULT => discovery.inquiryResult(layer, params, .plain),
        hci.HCI_EV_INQUIRY_RESULT_WITH_RSSI => discovery.inquiryResult(layer, params, .rssi),
        hci.HCI_EV_EXTENDED_INQUIRY_RESULT => discovery.inquiryResult(layer, params, .extended),
        hci.HCI_EV_REMOTE_NAME_REQUEST_COMPLETE => {
            discovery.nameComplete(layer, params);
            connections.nameComplete(layer, params);
        },
        hci.HCI_EV_CONNECTION_REQUEST => connections.request(layer, params),
        hci.HCI_EV_CONNECTION_COMPLETE => connections.complete(layer, params),
        hci.HCI_EV_DISCONNECTION_COMPLETE => connections.disconnectionComplete(layer, params),
        hci.HCI_EV_ROLE_CHANGE => connections.roleChange(layer, params),
        hci.HCI_EV_ENCRYPTION_CHANGE => connections.encryptionChange(layer, params),
        hci.HCI_EV_AUTHENTICATION_COMPLETE => pairing.authenticationComplete(layer, params),
        hci.HCI_EV_LINK_KEY_REQUEST => pairing.linkKeyRequest(layer, params),
        hci.HCI_EV_LINK_KEY_NOTIFICATION => pairing.linkKeyNotification(layer, params),
        hci.HCI_EV_PIN_CODE_REQUEST => pairing.pinCodeRequest(layer, params),
        hci.HCI_EV_IO_CAPABILITY_REQUEST => pairing.ioCapabilityRequest(layer, params),
        hci.HCI_EV_IO_CAPABILITY_RESPONSE => pairing.ioCapabilityResponse(layer, params),
        hci.HCI_EV_USER_CONFIRMATION_REQUEST => pairing.userConfirmationRequest(layer, params),
        hci.HCI_EV_USER_PASSKEY_REQUEST => pairing.userPasskeyRequest(layer, params),
        hci.HCI_EV_USER_PASSKEY_NOTIFICATION => pairing.userPasskeyNotification(layer, params),
        hci.HCI_EV_SIMPLE_PAIRING_COMPLETE => pairing.simplePairingComplete(layer, params),
        hci.HCI_EV_NUMBER_OF_COMPLETED_PACKETS => acl.completedPackets(layer, params),
        hci.HCI_EV_LE_META => leEvent(layer, params),
        else => {},
    }
}

/// LE Meta's subevents, each past its code.
fn leEvent(layer: *Hci, params: []const u8) void {
    if (params.len < 1) return;
    const rest = params[1..];
    switch (params[0]) {
        hci.HCI_LE_EV_ADVERTISING_REPORT => discovery.advertisingReport(layer, rest),
        hci.HCI_LE_EV_CONNECTION_COMPLETE => connections.leComplete(layer, rest),
        hci.HCI_LE_EV_CONNECTION_UPDATE_COMPLETE => connections.leUpdateComplete(layer, rest),
        hci.HCI_LE_EV_REMOTE_PARAMETERS_REQUEST => connections.leParametersRequest(layer, rest),
        else => {},
    }
}

/// A command's answer: its return parameters, the status first.
fn completed(layer: *Hci, opcode: u16, returned: []const u8) void {
    switch (layer.state) {
        bluetooth.BTCS_STARTING => bringup.answered(layer, opcode, returned),
        bluetooth.BTCS_UP => {
            discovery.answered(layer, opcode, returned);
            connections.answered(layer, opcode, returned);
            pairing.answered(layer, opcode, returned);
        },
        else => {},
    }
}

/// The controller's own trouble: it is brought up again from its reset,
/// twice at most; then it is given up on.
fn hardwareError(layer: *Hci) void {
    if (layer.state == bluetooth.BTCS_FAILED) return;
    if (layer.restarts >= 2) return fail(layer, hci.HCI_ERR_HARDWARE_FAILURE);
    layer.restarts += 1;
    start(layer);
}

/// A little-endian 16-bit field.
pub fn le16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | @as(u16, bytes[1]) << 8;
}
