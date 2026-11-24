// SPDX-License-Identifier: MIT
//! Host tests of LE's pairing with this machine the responder: two layers
//! on one air - each its controller's commands answered, its packets
//! carried to the other, LE's encryption between them as two controllers
//! do it - the library's initiator against its own responder. The number
//! compared on both sides, each bond the same key, and the link encrypted
//! with it when it is made again; the central's name read from its GATT
//! server, the responder's link and bond named with it; the passkey shown
//! on either side and typed on the other, and one typed wrong; Just Works
//! allowed by the responder's agent - the central's DHKey check kept while
//! it is asked - and refused by it; the central's identity taken after the
//! encryption, the bond kept by it; each side's identity given to the
//! other where it has one - the responder's first - each bond marked, and
//! none to a central that does not ask; a link the central made from its
//! private address - a pairing on it taking the address in its checks, and
//! the link made again from a new one, resolved by the central's key and
//! encrypted with the bond; the responder hidden, advertising from its
//! private address for the central it gave its identity, heard there by
//! the central's link made again, resolved by the bond's key and linked to
//! from the central's own private address, encrypted with the bond;
//! PairBTDevice on a link the device
//! made asking the device to pair (Security Request). Refused: a legacy Pairing
//! Request, too short a key, a pairing with no agent there, and the
//! central's encryption by an EDIV and Rand once the pairing is through.

const std = @import("std");
const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const l2cap = bluetooth.l2cap;
const hcidev = sdk.devices.hci;
const _hci = @import("../hci/_hci.zig");
const Hci = _hci.Hci;
const acl = @import("../hci/acl.zig");
const bonds = @import("../hci/bonds.zig");
const connections = @import("../hci/connections.zig");
const pairing = @import("../hci/pairing.zig");
const privacy = @import("../hci/privacy.zig");
const smp = @import("../hci/smp.zig");
const Port = @import("_port.zig").Port;

const testing = std.testing;

/// The link's handle on both sides.
const handle: u16 = 0x0040;

/// The two machines: documentation addresses.
const central_bytes = [6]u8{ 0x60, 0x10, 0xEF, 0x5E, 0x00, 0x00 };
const peripheral_bytes = [6]u8{ 0x61, 0x10, 0xEF, 0x5E, 0x00, 0x00 };
const central_address = bluetooth.BTAddress{ .bytes = central_bytes, .kind = bluetooth.BTADDR_LE_PUBLIC };
const peripheral_address = bluetooth.BTAddress{ .bytes = peripheral_bytes, .kind = bluetooth.BTADDR_LE_PUBLIC };

/// Two controllers on one air: each layer's commands answered as its
/// controller would, its packets carried to the other - all of it
/// delivered in turn by `run`.
const Air = struct {
    layers: [2]*Hci = undefined,
    sides: [2]Side = undefined,
    queue: [64]Item = undefined,
    first: usize = 0,
    count: usize = 0,
    /// The key the central's encryption goes by, until the peripheral
    /// answers.
    key: [16]u8 = @splat(0),
    /// The central's LE Enable Encryption answered, and the peripheral not
    /// asked: the test asks it.
    hold_encryption: bool = false,
    /// Where not 0, the keys the central's Pairing Request says it gives -
    /// the library's own gives its identity where it has one, and the test
    /// gives them by hand - and, where not null, those it asks of the
    /// responder.
    central_keys: u8 = 0,
    central_asks: ?u8 = null,
    /// The frame each side sent last on the security manager's channel;
    /// the Pairing Request and Response as the other side had them.
    smp_sent: [2][80]u8 = undefined,
    smp_length: [2]usize = .{ 0, 0 },
    request: [7]u8 = @splat(0),
    response: [7]u8 = @splat(0),
    /// Each side's random address, as LE Set Random Address gave it.
    random: [2][6]u8 = @splat(@splat(0)),

    const Side = struct { air: *Air, index: u1 };
    const Item = struct { to: u1, packet_type: u8, length: usize, bytes: [96]u8 };

    fn wire(air: *Air, central: *Hci, peripheral: *Hci) void {
        air.layers = .{ central, peripheral };
        air.sides = .{ .{ .air = air, .index = 0 }, .{ .air = air, .index = 1 } };
        central.port = .{ .context = &air.sides[0], .send = send };
        peripheral.port = .{ .context = &air.sides[1], .send = send };
    }

    fn put(air: *Air, to: u1, packet_type: u8, bytes: []const u8) void {
        std.debug.assert(air.count < air.queue.len);
        const item = &air.queue[(air.first + air.count) % air.queue.len];
        item.to = to;
        item.packet_type = packet_type;
        item.length = bytes.len;
        @memcpy(item.bytes[0..bytes.len], bytes);
        air.count += 1;
    }

    fn event(air: *Air, to: u1, code: u8, params: []const u8) void {
        var packet: [32]u8 = undefined;
        packet[0] = code;
        packet[1] = @intCast(params.len);
        @memcpy(packet[2..][0..params.len], params);
        air.put(to, hcidev.HCI_EVENT_PKT, packet[0 .. 2 + params.len]);
    }

    fn complete(air: *Air, to: u1, opcode: u16, returned: []const u8) void {
        var params: [16]u8 = undefined;
        params[0] = 4;
        params[1] = @truncate(opcode);
        params[2] = @truncate(opcode >> 8);
        @memcpy(params[3..][0..returned.len], returned);
        air.event(to, hci.HCI_EV_COMMAND_COMPLETE, params[0 .. 3 + returned.len]);
    }

    fn status(air: *Air, to: u1, opcode: u16) void {
        air.event(to, hci.HCI_EV_COMMAND_STATUS, &.{ 0, 4, @truncate(opcode), @truncate(opcode >> 8) });
    }

    fn send(context: *anyopaque, packet_type: u8, bytes: []const u8) bool {
        const side: *Side = @ptrCast(@alignCast(context));
        const air = side.air;
        switch (packet_type) {
            hcidev.HCI_COMMAND_PKT => air.command(side.index, _hci.le16(bytes[0..2]), bytes[hci.HCI_COMMAND_HDR..][0..bytes[2]]),
            hcidev.HCI_ACLDATA_PKT => {
                var packet: [96]u8 = undefined;
                @memcpy(packet[0..bytes.len], bytes);
                // What a host sends to start a frame, a controller gives
                // the other host as a start.
                const head = _hci.le16(bytes[0..2]);
                if (head >> hci.ACL_BOUNDARY_SHIFT & 3 != hci.ACL_CONTINUING) {
                    const start = (head & hci.ACL_HANDLE_MASK) | hci.ACL_START << hci.ACL_BOUNDARY_SHIFT;
                    packet[0] = @truncate(start);
                    packet[1] = @truncate(start >> 8);
                }
                if (_hci.le16(bytes[hci.HCI_ACL_HDR + 2 ..][0..2]) == l2cap.CID_SMP) {
                    const payload = bytes[hci.HCI_ACL_HDR + l2cap.L2CAP_HDR ..];
                    if (side.index == 0 and payload[0] == smp.PAIRING_REQUEST and air.central_keys != 0) packet[hci.HCI_ACL_HDR + l2cap.L2CAP_HDR + 5] = air.central_keys;
                    if (side.index == 0 and payload[0] == smp.PAIRING_REQUEST) {
                        if (air.central_asks) |asked| packet[hci.HCI_ACL_HDR + l2cap.L2CAP_HDR + 6] = asked;
                        air.request = packet[hci.HCI_ACL_HDR + l2cap.L2CAP_HDR ..][0..7].*;
                    }
                    if (payload[0] == smp.PAIRING_RESPONSE) air.response = payload[0..7].*;
                    @memcpy(air.smp_sent[side.index][0..payload.len], payload);
                    air.smp_length[side.index] = payload.len;
                }
                air.put(side.index ^ 1, hcidev.HCI_ACLDATA_PKT, packet[0..bytes.len]);
                air.event(side.index, hci.HCI_EV_NUMBER_OF_COMPLETED_PACKETS, &.{ 1, @truncate(handle), @truncate(handle >> 8), 1, 0 });
            },
            else => unreachable,
        }
        return true;
    }

    /// A command answered: the link made - the central seen by the address
    /// it made it from - and ended, the devices' features, LE's encryption
    /// between the two, a random address kept, a scan that hears the other
    /// advertise; the rest taken.
    fn command(air: *Air, from: u1, opcode: u16, params: []const u8) void {
        const to = from ^ 1;
        const ends = [2]u8{ @truncate(handle), @truncate(handle >> 8) };
        switch (opcode) {
            // The central linked to the address it initiated to, the
            // peripheral to the one the central made the link from.
            hci.HCI_OP_LE_CREATE_CONNECTION => {
                air.status(from, opcode);
                air.linked(from, hci.ROLE_CENTRAL, params[6..12].*, params[5]);
                if (params[12] == hci.LE_ADDR_RANDOM) {
                    air.linked(to, hci.ROLE_PERIPHERAL, air.random[from], hci.LE_ADDR_RANDOM);
                } else {
                    air.linked(to, hci.ROLE_PERIPHERAL, air.layers[from].address, hci.LE_ADDR_PUBLIC);
                }
            },
            hci.HCI_OP_LE_SET_RANDOM_ADDRESS => {
                air.random[from] = params[0..6].*;
                air.complete(from, opcode, &.{0});
            },
            // Scanning, it hears the other advertise.
            hci.HCI_OP_LE_SET_SCAN_ENABLE => {
                air.complete(from, opcode, &.{0});
                if (params[0] == 1) air.advertised(from, to);
            },
            hci.HCI_OP_LE_READ_REMOTE_FEATURES => {
                air.status(from, opcode);
                var features: [12]u8 = @splat(0);
                features[0] = hci.HCI_LE_EV_READ_REMOTE_FEATURES_COMPLETE;
                features[2] = ends[0];
                features[3] = ends[1];
                features[4] = 0x01; // encryption
                air.event(from, hci.HCI_EV_LE_META, &features);
            },
            hci.HCI_OP_LE_ENABLE_ENCRYPTION => {
                air.status(from, opcode);
                air.key = params[12..28].*;
                if (air.hold_encryption) return;
                // The peripheral's controller asks its host for the key by
                // what it goes by: Rand, then EDIV.
                var request: [13]u8 = undefined;
                request[0] = hci.HCI_LE_EV_LONG_TERM_KEY_REQUEST;
                request[1..3].* = ends;
                request[3..13].* = params[2..12].*;
                air.event(to, hci.HCI_EV_LE_META, &request);
            },
            hci.HCI_OP_LE_LONG_TERM_KEY_REPLY => {
                air.complete(from, opcode, &.{ 0, ends[0], ends[1] });
                const matched = std.mem.eql(u8, params[2..18], &air.key);
                const code: u8 = if (matched) 0 else hci.HCI_ERR_AUTHENTICATION_FAILURE;
                const on: u8 = if (matched) 1 else 0;
                air.event(to, hci.HCI_EV_ENCRYPTION_CHANGE, &.{ code, ends[0], ends[1], on });
                air.event(from, hci.HCI_EV_ENCRYPTION_CHANGE, &.{ code, ends[0], ends[1], on });
            },
            hci.HCI_OP_LE_LONG_TERM_KEY_NEGATIVE_REPLY => {
                air.complete(from, opcode, &.{ 0, ends[0], ends[1] });
                air.event(to, hci.HCI_EV_ENCRYPTION_CHANGE, &.{ hci.HCI_ERR_PIN_OR_KEY_MISSING, ends[0], ends[1], 0 });
            },
            hci.HCI_OP_DISCONNECT => {
                air.status(from, opcode);
                air.event(from, hci.HCI_EV_DISCONNECTION_COMPLETE, &.{ 0, ends[0], ends[1], hci.HCI_ERR_LOCAL_HOST_TERMINATED });
                air.event(to, hci.HCI_EV_DISCONNECTION_COMPLETE, &.{ 0, ends[0], ends[1], params[2] });
            },
            else => air.complete(from, opcode, &.{0}),
        }
    }

    /// LE Connection Complete to side `to`, its controller in `role`, the
    /// other's address of `kind` (hci.LE_ADDR_*).
    fn linked(air: *Air, to: u1, role: u8, bytes: [6]u8, kind: u8) void {
        var params: [19]u8 = @splat(0);
        params[0] = hci.HCI_LE_EV_CONNECTION_COMPLETE;
        params[2] = @truncate(handle);
        params[3] = @truncate(handle >> 8);
        params[4] = role;
        params[5] = kind;
        params[6..12].* = bytes;
        params[12] = 0x18; // every 30 ms
        params[16] = 0x2A; // supervised for 420 ms
        air.event(to, hci.HCI_EV_LE_META, &params);
    }

    /// LE Advertising Report to side `to`: side `other`, connectable - from
    /// its private address while its advertising is the hidden one, from
    /// its public one otherwise.
    fn advertised(air: *Air, to: u1, other: u1) void {
        const advertising = &air.layers[other].advertising;
        const hidden = advertising.on and advertising.kind == .hidden;
        var params: [12]u8 = @splat(0);
        params[0] = hci.HCI_LE_EV_ADVERTISING_REPORT;
        params[1] = 1;
        params[2] = hci.LE_ADV_IND;
        params[3] = if (hidden) hci.LE_ADDR_RANDOM else hci.LE_ADDR_PUBLIC;
        params[4..10].* = if (hidden) air.random[other] else air.layers[other].address;
        params[11] = 0xC4; // -60 dBm
        air.event(to, hci.HCI_EV_LE_META, &params);
    }

    /// A frame on the security manager's channel to side `to`, as if the
    /// other had sent it.
    fn smpTo(air: *Air, to: u1, payload: []const u8) void {
        var packet: [96]u8 = undefined;
        const head = handle | hci.ACL_START << hci.ACL_BOUNDARY_SHIFT;
        packet[0] = @truncate(head);
        packet[1] = @truncate(head >> 8);
        packet[2] = @intCast(l2cap.L2CAP_HDR + payload.len);
        packet[3] = 0;
        packet[4] = @intCast(payload.len);
        packet[5] = 0;
        packet[6] = @truncate(l2cap.CID_SMP);
        packet[7] = 0;
        @memcpy(packet[8..][0..payload.len], payload);
        air.put(to, hcidev.HCI_ACLDATA_PKT, packet[0 .. 8 + payload.len]);
    }

    /// Everything on the air delivered, and what that sends in turn.
    fn run(air: *Air) void {
        var steps: usize = 0;
        while (air.count > 0) : (steps += 1) {
            std.debug.assert(steps < 10_000);
            const item = air.queue[air.first];
            air.first = (air.first + 1) % air.queue.len;
            air.count -= 1;
            _hci.received(air.layers[item.to], item.packet_type, item.bytes[0..item.length]);
        }
    }

    /// The frame side `from` sent last on the security manager's channel.
    fn lastSmp(air: *const Air, from: u1) []const u8 {
        return air.smp_sent[from][0..air.smp_length[from]];
    }
};

/// A layer up, BR/EDR and LE - LE's buffers its own - with the address
/// `bytes`, `port` its cryptography, and the agent `agent` of `capability`
/// there for the pairings devices begin.
fn upLayer(bytes: [6]u8, port: *Port, agent: u32, capability: u32) Hci {
    var layer = Hci{ .port = undefined };
    layer.state = bluetooth.BTCS_UP;
    layer.features[0] = .{ 0xBF, 0xFE, 0xCF, 0xFE, 0xDB, 0xFF, 0x7B, 0x87 };
    layer.credits = 4;
    layer.now = 100_000;
    layer.acl_mtu = 1021;
    layer.acl_packets = 6;
    layer.le_mtu = 251;
    layer.le_packets = 8;
    layer.le_own = true;
    layer.address = bytes;
    layer.crypto = port.of().*;
    layer.agent_current = agent;
    layer.agent_capability = capability;
    acl.buffersRead(&layer);
    return layer;
}

/// The question the link's pairing has for its agent, taken by the task
/// in `message`.
fn question(layer: *Hci, address: bluetooth.BTAddress, message: *anyopaque) !*pairing.Question {
    const link = connections.find(layer, address) orelse return error.TestUnexpectedResult;
    const asked = &link.pairing.question;
    try testing.expect(asked.kind != 0 and !asked.sent);
    asked.sent = true;
    asked.message = message;
    return asked;
}

/// The first notice of `kind` the layer has for its agent - taken, as the
/// task takes it.
fn notice(layer: *Hci, kind: pairing.NoticeKind) !pairing.Notice {
    for (layer.notices[0..layer.notice_count], 0..) |item, index| {
        if (item.kind != kind) continue;
        for (index + 1..layer.notice_count) |next| layer.notices[next - 1] = layer.notices[next];
        layer.notice_count -= 1;
        return item;
    }
    return error.TestUnexpectedResult;
}

/// Both pairings over: each side's bond with the other, the same key,
/// made by Secure Connections - `authenticated` by the method - and the
/// link encrypted on both sides.
fn expectBonded(central: *Hci, peripheral: *Hci, authenticated: bool) !void {
    const done_central = try notice(central, .done);
    const done_peripheral = try notice(peripheral, .done);
    try testing.expectEqual(@as(i32, 0), done_central.result);
    try testing.expectEqual(@as(i32, 0), done_peripheral.result);
    const theirs = bonds.find(central, peripheral_address).?;
    const ours = bonds.find(peripheral, central_address).?;
    try testing.expectEqualSlices(u8, &theirs.key, &ours.key);
    try testing.expect(bonds.secure(theirs) and bonds.secure(ours));
    try testing.expectEqual(authenticated, bonds.authenticated(theirs));
    try testing.expectEqual(authenticated, bonds.authenticated(ours));
    try testing.expectEqual(@as(u8, 16), ours.key_size);
    const link = connections.find(peripheral, central_address).?;
    try testing.expect(link.encrypted and link.pairing.stage == .idle and link.smp.phase == .idle);
    try testing.expect(connections.find(central, peripheral_address).?.encrypted);
}

/// Neither side paired: each told why, no bond kept.
fn expectNotPaired(central: *Hci, peripheral: *Hci, central_result: i32, peripheral_result: i32) !void {
    try testing.expectEqual(central_result, (try notice(central, .done)).result);
    try testing.expectEqual(peripheral_result, (try notice(peripheral, .done)).result);
    try testing.expect(bonds.find(central, peripheral_address) == null);
    try testing.expect(bonds.find(peripheral, central_address) == null);
}

test "the library's initiator against its own responder: the number compared on both sides, each bond the same key, the link encrypted with it when made again; the central's name read" {
    var central_port = Port{};
    var peripheral_port = Port{ .counter = 129 };
    var central = upLayer(central_bytes, &central_port, 7, bluetooth.BTIO_KEYBOARDDISPLAY);
    var peripheral = upLayer(peripheral_bytes, &peripheral_port, 9, bluetooth.BTIO_DISPLAYYESNO);
    @memcpy(central.name[0..8], "poweros\x00");
    var air = Air{};
    air.wire(&central, &peripheral);
    try testing.expectEqual(@as(i32, 0), pairing.pair(&central, peripheral_address, 7, bluetooth.BTIO_KEYBOARDDISPLAY));
    air.run();
    // The responder's answer: its agent's capability, a bond, protection
    // from a man in the middle, Secure Connections, the central's identity
    // asked for and nothing given.
    try testing.expectEqualSlices(u8, &.{ smp.PAIRING_RESPONSE, smp.IO_DISPLAY_YES_NO, 0, smp.AUTH_BONDING | smp.AUTH_MITM | smp.AUTH_SC, 16, 0, 0 }, &connections.find(&central, peripheral_address).?.smp.response);
    // Both agents asked about the same six digits.
    var central_message: u8 = 0;
    var peripheral_message: u8 = 0;
    const central_asked = try question(&central, peripheral_address, &central_message);
    const peripheral_asked = try question(&peripheral, central_address, &peripheral_message);
    try testing.expectEqual(bluetooth.BTAK_CONFIRM, central_asked.kind);
    try testing.expectEqual(bluetooth.BTAK_CONFIRM, peripheral_asked.kind);
    try testing.expect(central_asked.number <= 999_999);
    try testing.expectEqual(central_asked.number, peripheral_asked.number);
    // The responder's yes first: it waits for the central's check.
    try testing.expect(pairing.agentAnswered(&peripheral, &peripheral_message, true, 0, &.{}));
    air.run();
    try testing.expectEqual(smp.Phase.check, connections.find(&peripheral, central_address).?.smp.phase);
    try testing.expect(pairing.agentAnswered(&central, &central_message, true, 0, &.{}));
    air.run();
    try expectBonded(&central, &peripheral, true);
    try testing.expectEqual(connections.NoteKind.paired, peripheral.notes[peripheral.note_count - 1].kind);
    // The central's name, from its GATT server: the link's and the bond's.
    try testing.expectEqualStrings("poweros", std.mem.sliceTo(&connections.find(&peripheral, central_address).?.name, 0));
    try testing.expectEqualStrings("poweros", std.mem.sliceTo(&bonds.find(&peripheral, central_address).?.name, 0));

    // The link made again: encrypted with the bond's key, given by the
    // responder from its own bond.
    const ended = connections.disconnect(&central, peripheral_address);
    air.run();
    connections.release(&central, ended.waiting);
    try testing.expect(connections.find(&peripheral, central_address) == null);
    const again = connections.connect(&central, peripheral_address);
    air.run();
    try testing.expectEqual(@as(i32, 0), central.waits[again.waiting].result);
    connections.release(&central, again.waiting);
    try testing.expect(connections.find(&central, peripheral_address).?.encrypted);
    try testing.expect(connections.find(&peripheral, central_address).?.encrypted);
}

test "the passkey shown by the responder and typed at the central, and the other way round: Passkey Entry's twenty rounds" {
    for ([_]bool{ true, false }) |responder_shows| {
        var central_port = Port{};
        var peripheral_port = Port{ .counter = 129 };
        const central_io: u32 = if (responder_shows) bluetooth.BTIO_KEYBOARDONLY else bluetooth.BTIO_DISPLAYONLY;
        const peripheral_io: u32 = if (responder_shows) bluetooth.BTIO_DISPLAYONLY else bluetooth.BTIO_KEYBOARDONLY;
        var central = upLayer(central_bytes, &central_port, 7, central_io);
        var peripheral = upLayer(peripheral_bytes, &peripheral_port, 9, peripheral_io);
        var air = Air{};
        air.wire(&central, &peripheral);
        try testing.expectEqual(@as(i32, 0), pairing.pair(&central, peripheral_address, 7, central_io));
        air.run();
        var message: u8 = 0;
        if (responder_shows) {
            const shown = try notice(&peripheral, .show);
            try testing.expectEqual(@as(u32, 9), shown.agent);
            const asked = try question(&central, peripheral_address, &message);
            try testing.expectEqual(bluetooth.BTAK_PASSKEY, asked.kind);
            try testing.expect(pairing.agentAnswered(&central, &message, true, shown.number, &.{}));
        } else {
            // The central's first confirm comes while the responder's agent
            // is asked: kept for the passkey.
            const shown = try notice(&central, .show);
            const asked = try question(&peripheral, central_address, &message);
            try testing.expectEqual(bluetooth.BTAK_PASSKEY, asked.kind);
            try testing.expect(connections.find(&peripheral, central_address).?.smp.confirm_in);
            try testing.expect(pairing.agentAnswered(&peripheral, &message, true, shown.number, &.{}));
        }
        air.run();
        try expectBonded(&central, &peripheral, true);
    }
}

test "a passkey typed wrong at the responder: the central's confirm does not match, neither side paired" {
    var central_port = Port{};
    var peripheral_port = Port{ .counter = 129 };
    var central = upLayer(central_bytes, &central_port, 7, bluetooth.BTIO_DISPLAYONLY);
    var peripheral = upLayer(peripheral_bytes, &peripheral_port, 9, bluetooth.BTIO_KEYBOARDONLY);
    var air = Air{};
    air.wire(&central, &peripheral);
    _ = pairing.pair(&central, peripheral_address, 7, bluetooth.BTIO_DISPLAYONLY);
    air.run();
    const shown = try notice(&central, .show);
    var message: u8 = 0;
    _ = try question(&peripheral, central_address, &message);
    // Its lowest bit, the first round's, wrong.
    try testing.expect(pairing.agentAnswered(&peripheral, &message, true, shown.number ^ 1, &.{}));
    air.run();
    try testing.expectEqualSlices(u8, &.{ smp.PAIRING_FAILED, smp.REASON_CONFIRM_VALUE_FAILED }, air.lastSmp(1));
    try expectNotPaired(&central, &peripheral, hci.HCI_ERR_AUTHENTICATION_FAILURE, hci.HCI_ERR_AUTHENTICATION_FAILURE);
}

test "Just Works: allowed by the responder's agent, the central's DHKey check kept while it is asked; refused by it" {
    for ([_]bool{ true, false }) |allowed| {
        var central_port = Port{};
        var peripheral_port = Port{ .counter = 129 };
        var central = upLayer(central_bytes, &central_port, 7, bluetooth.BTIO_NOINPUTNOOUTPUT);
        var peripheral = upLayer(peripheral_bytes, &peripheral_port, 9, bluetooth.BTIO_DISPLAYYESNO);
        var air = Air{};
        air.wire(&central, &peripheral);
        _ = pairing.pair(&central, peripheral_address, 7, bluetooth.BTIO_NOINPUTNOOUTPUT);
        air.run();
        // The central asks nobody and has sent its check; the responder's
        // agent is asked whether the device may pair.
        try testing.expectEqual(@as(u32, 0), connections.find(&central, peripheral_address).?.pairing.question.kind);
        try testing.expectEqual(smp.PAIRING_DHKEY_CHECK, air.lastSmp(0)[0]);
        try testing.expect(connections.find(&peripheral, central_address).?.smp.check_in);
        var message: u8 = 0;
        const asked = try question(&peripheral, central_address, &message);
        try testing.expectEqual(bluetooth.BTAK_CONFIRM, asked.kind);
        try testing.expectEqual(bluetooth.BT_NO_NUMBER, asked.number);
        try testing.expect(pairing.agentAnswered(&peripheral, &message, allowed, 0, &.{}));
        air.run();
        if (allowed) {
            try expectBonded(&central, &peripheral, false);
        } else {
            try testing.expectEqualSlices(u8, &.{ smp.PAIRING_FAILED, smp.REASON_PAIRING_NOT_SUPPORTED }, air.lastSmp(1));
            try expectNotPaired(&central, &peripheral, hci.HCI_ERR_PAIRING_NOT_ALLOWED, bluetooth.BTERR_REFUSED);
        }
    }
}

test "the central's identity taken: its identity resolving key and static address given after the encryption, the bond kept by them, the link found by them" {
    var central_port = Port{};
    var peripheral_port = Port{ .counter = 129 };
    var central = upLayer(central_bytes, &central_port, 7, bluetooth.BTIO_NOINPUTNOOUTPUT);
    var peripheral = upLayer(peripheral_bytes, &peripheral_port, 9, bluetooth.BTIO_NOINPUTNOOUTPUT);
    var air = Air{ .central_keys = smp.KEYDIST_ID | smp.KEYDIST_SIGN };
    air.wire(&central, &peripheral);
    // Just Works, and neither agent can be asked.
    _ = pairing.pair(&central, peripheral_address, 7, bluetooth.BTIO_NOINPUTNOOUTPUT);
    air.run();
    try testing.expectEqual(@as(i32, 0), (try notice(&central, .done)).result);
    // The identity asked for, the signing key not; the link encrypted and
    // the responder waiting for the keys.
    const link = connections.find(&peripheral, central_address).?;
    try testing.expectEqual(smp.KEYDIST_ID, link.smp.response[5]);
    try testing.expectEqual(@as(u8, 0), link.smp.response[6]);
    try testing.expectEqual(smp.Phase.keys, link.smp.phase);
    try testing.expect(link.encrypted and peripheral.notice_count == 0);
    const irk = [16]u8{ 0x9B, 0x7D, 0x39, 0x0A, 0xA6, 0x10, 0x10, 0x34, 0x05, 0xAD, 0xC8, 0x57, 0xA3, 0x34, 0x02, 0xEC };
    const identity_bytes = [6]u8{ 0x62, 0x10, 0xEF, 0x5E, 0x00, 0xC0 };
    air.smpTo(1, &(.{smp.IDENTITY_INFORMATION} ++ irk));
    air.smpTo(1, &(.{ smp.IDENTITY_ADDRESS_INFORMATION, hci.LE_ADDR_RANDOM } ++ identity_bytes));
    air.run();
    try testing.expectEqual(@as(i32, 0), (try notice(&peripheral, .done)).result);
    const identity = bluetooth.BTAddress{ .bytes = identity_bytes, .kind = bluetooth.BTADDR_LE_RANDOM };
    const bond = bonds.find(&peripheral, identity).?;
    try testing.expect(bond.has_irk and bonds.secure(bond) and !bonds.authenticated(bond));
    try testing.expectEqualSlices(u8, &irk, &bond.irk);
    try testing.expectEqualSlices(u8, &bonds.find(&central, peripheral_address).?.key, &bond.key);
    try testing.expect(bonds.find(&peripheral, central_address) == null);
    try testing.expect(connections.find(&peripheral, identity) == link);
}

/// The identity resolving keys of the two machines.
const central_irk = [16]u8{ 0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF };
const peripheral_irk = [16]u8{ 0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01, 0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10 };

test "each machine's identity given to the other: offered and asked for, the responder's first, each bond keeping the other's and marked given" {
    var central_port = Port{};
    var peripheral_port = Port{ .counter = 129 };
    var central = upLayer(central_bytes, &central_port, 7, bluetooth.BTIO_NOINPUTNOOUTPUT);
    var peripheral = upLayer(peripheral_bytes, &peripheral_port, 9, bluetooth.BTIO_NOINPUTNOOUTPUT);
    central.irk = central_irk;
    central.has_identity = true;
    peripheral.irk = peripheral_irk;
    peripheral.has_identity = true;
    var air = Air{};
    air.wire(&central, &peripheral);
    _ = pairing.pair(&central, peripheral_address, 7, bluetooth.BTIO_NOINPUTNOOUTPUT);
    air.run();
    // The central's identity offered, the responder's asked for; the
    // responder wants the one and gives the other.
    try testing.expectEqual(smp.KEYDIST_ID, air.request[5]);
    try testing.expectEqual(smp.KEYDIST_ENC | smp.KEYDIST_ID, air.request[6]);
    try testing.expectEqual(smp.KEYDIST_ID, air.response[5]);
    try testing.expectEqual(smp.KEYDIST_ID, air.response[6]);
    try testing.expectEqual(@as(i32, 0), (try notice(&central, .done)).result);
    try testing.expectEqual(@as(i32, 0), (try notice(&peripheral, .done)).result);
    // The central's identity went last: its address, after its key.
    try testing.expectEqualSlices(u8, &(.{ smp.IDENTITY_ADDRESS_INFORMATION, hci.LE_ADDR_PUBLIC } ++ central_bytes), air.lastSmp(0));
    try testing.expectEqualSlices(u8, &(.{ smp.IDENTITY_ADDRESS_INFORMATION, hci.LE_ADDR_PUBLIC } ++ peripheral_bytes), air.lastSmp(1));
    const theirs = bonds.find(&central, peripheral_address).?;
    const ours = bonds.find(&peripheral, central_address).?;
    try testing.expect(theirs.has_irk and ours.has_irk);
    try testing.expectEqualSlices(u8, &peripheral_irk, &theirs.irk);
    try testing.expectEqualSlices(u8, &central_irk, &ours.irk);
    try testing.expect(theirs.identity_given and ours.identity_given);
    try testing.expectEqualSlices(u8, &theirs.key, &ours.key);
    try testing.expect(connections.find(&peripheral, central_address).?.encrypted);
}

test "a central that does not ask for the responder's identity is given none, its own taken; neither side without a key of its own offers one" {
    var central_port = Port{};
    var peripheral_port = Port{ .counter = 129 };
    var central = upLayer(central_bytes, &central_port, 7, bluetooth.BTIO_NOINPUTNOOUTPUT);
    var peripheral = upLayer(peripheral_bytes, &peripheral_port, 9, bluetooth.BTIO_NOINPUTNOOUTPUT);
    central.irk = central_irk;
    central.has_identity = true;
    peripheral.irk = peripheral_irk;
    peripheral.has_identity = true;
    var air = Air{ .central_asks = smp.KEYDIST_ENC };
    air.wire(&central, &peripheral);
    _ = pairing.pair(&central, peripheral_address, 7, bluetooth.BTIO_NOINPUTNOOUTPUT);
    air.run();
    try testing.expectEqual(@as(i32, 0), (try notice(&central, .done)).result);
    try testing.expectEqual(@as(i32, 0), (try notice(&peripheral, .done)).result);
    try testing.expectEqual(smp.KEYDIST_ENC, air.request[6]);
    try testing.expectEqual(smp.KEYDIST_ID, air.response[5]);
    try testing.expectEqual(@as(u8, 0), air.response[6]);
    const theirs = bonds.find(&central, peripheral_address).?;
    const ours = bonds.find(&peripheral, central_address).?;
    // The responder gave nothing; the central gave its identity.
    try testing.expect(!theirs.has_irk and theirs.identity_given);
    try testing.expect(ours.has_irk and !ours.identity_given);
    try testing.expectEqualSlices(u8, &central_irk, &ours.irk);

    // Without a key of its own, or without a public address, a side
    // offers none.
    central.has_identity = false;
    try testing.expect(!smp.hasIdentity(&central));
    peripheral.address = @splat(0);
    try testing.expect(!smp.hasIdentity(&peripheral));
}

test "a link the central made from its private address: a pairing on it takes the address in its checks, the peripheral's bond kept by the central's identity; made again from a new one, resolved by the central's key and encrypted with the bond" {
    var central_port = Port{};
    var peripheral_port = Port{ .counter = 129 };
    var central = upLayer(central_bytes, &central_port, 7, bluetooth.BTIO_NOINPUTNOOUTPUT);
    var peripheral = upLayer(peripheral_bytes, &peripheral_port, 9, bluetooth.BTIO_NOINPUTNOOUTPUT);
    central.irk = central_irk;
    central.has_identity = true;
    peripheral.irk = peripheral_irk;
    peripheral.has_identity = true;
    var air = Air{};
    air.wire(&central, &peripheral);
    // The central's private address; a bond of its with the peripheral,
    // given its identity, whose key the peripheral does not have.
    privacy.reset(&central);
    _hci.tick(&central);
    air.run();
    try testing.expect(central.privacy.has);
    const first = bluetooth.BTAddress{ .bytes = central.privacy.address, .kind = bluetooth.BTADDR_LE_RANDOM };
    const stale: [16]u8 = @splat(0xA5);
    _ = bonds.keepLe(&central, peripheral_address, &.{ .ltk = stale, .key_size = 16, .authenticated = false, .secure = true, .given = true }, "peripheral").?;
    // The link made from it: the peripheral sees the central there, and
    // has no key for it.
    const linked = connections.connect(&central, peripheral_address);
    air.run();
    try testing.expectEqual(@as(i32, hci.HCI_ERR_PIN_OR_KEY_MISSING), central.waits[linked.waiting].result);
    connections.release(&central, linked.waiting);
    const link = connections.find(&central, peripheral_address).?;
    try testing.expect(connections.sameAddress(first, link.own));
    const seen = connections.find(&peripheral, first).?;
    try testing.expect(!seen.encrypted and seen.identity == null);
    try testing.expect(connections.sameAddress(peripheral_address, seen.own));

    // The bond ended, and a pairing on the link: both sides' checks over
    // the private address.
    try testing.expect(bonds.forget(&central, peripheral_address));
    try testing.expectEqual(@as(i32, 0), pairing.pair(&central, peripheral_address, 7, bluetooth.BTIO_NOINPUTNOOUTPUT));
    air.run();
    try testing.expectEqual(@as(i32, 0), (try notice(&central, .done)).result);
    try testing.expectEqual(@as(i32, 0), (try notice(&peripheral, .done)).result);
    const theirs = bonds.find(&central, peripheral_address).?;
    const ours = bonds.find(&peripheral, central_address).?;
    try testing.expectEqualSlices(u8, &theirs.key, &ours.key);
    try testing.expectEqualSlices(u8, &central_irk, &ours.irk);
    try testing.expect(theirs.identity_given and ours.identity_given);
    try testing.expect(seen.encrypted and link.encrypted);
    try testing.expect(connections.find(&peripheral, central_address) == seen);

    // Made again from a new private address: the peripheral resolves it
    // by the central's key, and the link is encrypted with the bond.
    const ended = connections.disconnect(&central, peripheral_address);
    air.run();
    connections.release(&central, ended.waiting);
    central.now += privacy.ROTATE_MS;
    _hci.tick(&central);
    air.run();
    try testing.expect(!std.mem.eql(u8, &first.bytes, &central.privacy.address));
    const again = connections.connect(&central, peripheral_address);
    air.run();
    try testing.expectEqual(@as(i32, 0), central.waits[again.waiting].result);
    connections.release(&central, again.waiting);
    const resolved = connections.find(&peripheral, central_address).?;
    try testing.expect(resolved.encrypted and connections.find(&central, peripheral_address).?.encrypted);
    try testing.expectEqual(bluetooth.BTADDR_LE_RANDOM, resolved.address.kind);
    try testing.expectEqualSlices(u8, &central.privacy.address, &resolved.address.bytes);
}

test "the responder hidden, advertising from its private address for the central it gave its identity: the central's link made again hears it there, resolves it by the bond's key and links to it from its own private address, encrypted with the bond" {
    var central_port = Port{};
    var peripheral_port = Port{ .counter = 129 };
    var central = upLayer(central_bytes, &central_port, 7, bluetooth.BTIO_NOINPUTNOOUTPUT);
    var peripheral = upLayer(peripheral_bytes, &peripheral_port, 9, bluetooth.BTIO_NOINPUTNOOUTPUT);
    central.irk = central_irk;
    central.has_identity = true;
    peripheral.irk = peripheral_irk;
    peripheral.has_identity = true;
    var air = Air{};
    air.wire(&central, &peripheral);
    // Each side's private address; no bond given the identity yet, so the
    // peripheral, hidden, does not advertise.
    for ([_]*Hci{ &central, &peripheral }) |layer| {
        privacy.reset(layer);
        _hci.tick(layer);
    }
    air.run();
    try testing.expect(central.privacy.has and peripheral.privacy.has);
    try testing.expect(!peripheral.advertising.on);
    // Paired, each given the other's identity.
    _ = pairing.pair(&central, peripheral_address, 7, bluetooth.BTIO_NOINPUTNOOUTPUT);
    air.run();
    try testing.expectEqual(@as(i32, 0), (try notice(&central, .done)).result);
    try testing.expectEqual(@as(i32, 0), (try notice(&peripheral, .done)).result);
    try testing.expect(bonds.find(&central, peripheral_address).?.identity_given);
    try testing.expect(bonds.find(&peripheral, central_address).?.identity_given);
    // The link ended: the peripheral advertises for the central, from its
    // private address.
    const ended = connections.disconnect(&central, peripheral_address);
    air.run();
    connections.release(&central, ended.waiting);
    try testing.expect(peripheral.advertising.on and peripheral.advertising.kind == .hidden);

    // Made again: heard at the private address, resolved by the bond's
    // key, linked to there from the central's own private address, and
    // encrypted with the bond.
    const again = connections.connect(&central, peripheral_address);
    air.run();
    try testing.expectEqual(@as(i32, 0), central.waits[again.waiting].result);
    connections.release(&central, again.waiting);
    const link = connections.find(&central, peripheral_address).?;
    try testing.expectEqual(bluetooth.BTADDR_LE_RANDOM, link.address.kind);
    try testing.expectEqualSlices(u8, &peripheral.privacy.address, &link.address.bytes);
    try testing.expect(connections.sameAddress(peripheral_address, link.identity.?));
    try testing.expectEqual(bluetooth.BTADDR_LE_RANDOM, link.own.kind);
    try testing.expect(link.encrypted);
    const seen = connections.find(&peripheral, central_address).?;
    try testing.expect(seen.encrypted and !seen.refused);
    try testing.expectEqualSlices(u8, &central.privacy.address, &seen.address.bytes);
    try testing.expectEqual(bluetooth.BTADDR_LE_RANDOM, seen.own.kind);
    try testing.expectEqualSlices(u8, &peripheral.privacy.address, &seen.own.bytes);
}

test "PairBTDevice on a link the device made: the device asked to pair (Security Request), its pairing answered as the library's own" {
    var central_port = Port{};
    var peripheral_port = Port{ .counter = 129 };
    var central = upLayer(central_bytes, &central_port, 7, bluetooth.BTIO_DISPLAYYESNO);
    var peripheral = upLayer(peripheral_bytes, &peripheral_port, 0, 0);
    var air = Air{};
    air.wire(&central, &peripheral);
    const linked = connections.connect(&central, peripheral_address);
    air.run();
    connections.release(&central, linked.waiting);
    try testing.expectEqual(@as(i32, 0), pairing.pair(&peripheral, central_address, 9, bluetooth.BTIO_DISPLAYYESNO));
    try testing.expectEqualSlices(u8, &.{ smp.SECURITY_REQUEST, smp.AUTH_BONDING | smp.AUTH_MITM | smp.AUTH_SC }, air.lastSmp(1));
    air.run();
    var central_message: u8 = 0;
    var peripheral_message: u8 = 0;
    const central_asked = try question(&central, peripheral_address, &central_message);
    const peripheral_asked = try question(&peripheral, central_address, &peripheral_message);
    try testing.expectEqual(central_asked.number, peripheral_asked.number);
    try testing.expect(pairing.agentAnswered(&central, &central_message, true, 0, &.{}));
    try testing.expect(pairing.agentAnswered(&peripheral, &peripheral_message, true, 0, &.{}));
    air.run();
    // Each its own end: the responder's for PairBTDevice's agent, the
    // central's for the agent there when the device asked.
    try testing.expect(peripheral.notices[0].ours and peripheral.notices[0].agent == 9);
    try testing.expect(!central.notices[0].ours and central.notices[0].agent == 7);
    try expectBonded(&central, &peripheral, true);
}

test "refused: a legacy Pairing Request, too short a key, a pairing with no agent there; the central's encryption by an EDIV and Rand once the pairing is through" {
    var central_port = Port{};
    var peripheral_port = Port{ .counter = 129 };
    var central = upLayer(central_bytes, &central_port, 0, 0);
    var peripheral = upLayer(peripheral_bytes, &peripheral_port, 9, bluetooth.BTIO_DISPLAYYESNO);
    var air = Air{};
    air.wire(&central, &peripheral);
    const linked = connections.connect(&central, peripheral_address);
    air.run();
    connections.release(&central, linked.waiting);

    // Without Secure Connections: Authentication Requirements.
    air.smpTo(1, &.{ smp.PAIRING_REQUEST, smp.IO_KEYBOARD_DISPLAY, 0, smp.AUTH_BONDING | smp.AUTH_MITM, 16, 0, smp.KEYDIST_ENC | smp.KEYDIST_ID });
    air.run();
    try testing.expectEqualSlices(u8, &.{ smp.PAIRING_FAILED, smp.REASON_AUTHENTICATION_REQUIREMENTS }, air.lastSmp(1));
    const refused = try notice(&peripheral, .done);
    try testing.expectEqual(@as(i32, hci.HCI_ERR_PAIRING_NOT_ALLOWED), refused.result);
    try testing.expect(!refused.ours and refused.agent == 9);
    // A key of six bytes at most.
    air.smpTo(1, &.{ smp.PAIRING_REQUEST, smp.IO_KEYBOARD_DISPLAY, 0, smp.AUTH_BONDING | smp.AUTH_SC, 6, 0, 0 });
    air.run();
    try testing.expectEqualSlices(u8, &.{ smp.PAIRING_FAILED, smp.REASON_ENCRYPTION_KEY_SIZE }, air.lastSmp(1));
    try testing.expectEqual(@as(i32, hci.HCI_ERR_INSUFFICIENT_SECURITY), (try notice(&peripheral, .done)).result);
    // No agent: Pairing Not Supported, nobody told.
    peripheral.agent_current = 0;
    air.smpTo(1, &.{ smp.PAIRING_REQUEST, smp.IO_KEYBOARD_DISPLAY, 0, smp.AUTH_BONDING | smp.AUTH_SC, 16, 0, 0 });
    air.run();
    try testing.expectEqualSlices(u8, &.{ smp.PAIRING_FAILED, smp.REASON_PAIRING_NOT_SUPPORTED }, air.lastSmp(1));
    try testing.expectEqual(@as(u8, 0), peripheral.notice_count);

    // A pairing through to its encryption, which the central's controller
    // asks for by an EDIV and Rand: refused, the pairing given up.
    peripheral.agent_current = 9;
    peripheral.agent_capability = bluetooth.BTIO_NOINPUTNOOUTPUT;
    air.hold_encryption = true;
    _ = pairing.pair(&central, peripheral_address, 0, bluetooth.BTIO_NOINPUTNOOUTPUT);
    air.run();
    try testing.expectEqual(smp.Phase.encryption, connections.find(&peripheral, central_address).?.smp.phase);
    const request = [13]u8{ hci.HCI_LE_EV_LONG_TERM_KEY_REQUEST, @truncate(handle), @truncate(handle >> 8), 1, 2, 3, 4, 5, 6, 7, 8, 0x1A, 0x2F };
    air.event(1, hci.HCI_EV_LE_META, &request);
    air.run();
    try testing.expectEqualSlices(u8, &.{ smp.PAIRING_FAILED, smp.REASON_UNSPECIFIED }, air.lastSmp(1));
    try testing.expectEqual(@as(i32, hci.HCI_ERR_PIN_OR_KEY_MISSING), (try notice(&peripheral, .done)).result);
    try testing.expect(bonds.find(&peripheral, central_address) == null);
    try testing.expect(!connections.find(&peripheral, central_address).?.encrypted);
}
