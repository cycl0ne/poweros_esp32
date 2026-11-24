// SPDX-License-Identifier: MIT
//! Host tests of the links devices make over LE, this machine their
//! peripheral: the attribute server answering over one, which stays
//! until the device ends it; a central's encryption answered with the
//! key of its bond made by Secure Connections, cut to the bond's size -
//! also for a private address the bond's identity resolving key made -
//! and refused, and noted, for a device without a bond, a key that goes
//! by an EDIV and Rand, a legacy bond's key, and a handle no link has.

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
const Port = @import("_port.zig").Port;

const testing = std.testing;

/// A controller that keeps the commands and packets it is sent.
const Recorder = struct {
    commands: [32]Command = undefined,
    command_count: usize = 0,
    packets: [8]Packet = undefined,
    packet_count: usize = 0,

    const Command = struct {
        opcode: u16,
        length: usize,
        params: [hci.HCI_MAX_PARAMS]u8,

        fn bytes(command: *const Command) []const u8 {
            return command.params[0..command.length];
        }
    };

    const Packet = struct {
        handle: u16,
        length: usize,
        data: [96]u8,

        fn bytes(packet: *const Packet) []const u8 {
            return packet.data[0..packet.length];
        }
    };

    fn send(context: *anyopaque, packet_type: u8, bytes: []const u8) bool {
        const recorder: *Recorder = @ptrCast(@alignCast(context));
        switch (packet_type) {
            hcidev.HCI_COMMAND_PKT => {
                const command = &recorder.commands[recorder.command_count % recorder.commands.len];
                command.opcode = _hci.le16(bytes[0..2]);
                command.length = bytes[2];
                @memcpy(command.params[0..command.length], bytes[hci.HCI_COMMAND_HDR..]);
                recorder.command_count += 1;
            },
            hcidev.HCI_ACLDATA_PKT => {
                const packet = &recorder.packets[recorder.packet_count % recorder.packets.len];
                packet.handle = _hci.le16(bytes[0..2]) & hci.ACL_HANDLE_MASK;
                packet.length = _hci.le16(bytes[2..4]);
                @memcpy(packet.data[0..packet.length], bytes[hci.HCI_ACL_HDR..][0..packet.length]);
                recorder.packet_count += 1;
            },
            else => unreachable,
        }
        return true;
    }

    fn last(recorder: *const Recorder) *const Command {
        return &recorder.commands[(recorder.command_count - 1) % recorder.commands.len];
    }

    fn lastPacket(recorder: *const Recorder) *const Packet {
        return &recorder.packets[(recorder.packet_count - 1) % recorder.packets.len];
    }
};

/// This machine's controller, and the devices: documentation addresses.
const ours = [6]u8{ 0x00, 0x10, 0xEF, 0x5E, 0x00, 0x00 };
const phone = bluetooth.BTAddress{ .bytes = .{ 0x50, 0x10, 0xEF, 0x5E, 0x00, 0x00 }, .kind = bluetooth.BTADDR_LE_PUBLIC };
const laptop = bluetooth.BTAddress{ .bytes = .{ 0x51, 0x10, 0xEF, 0x5E, 0x00, 0x00 }, .kind = bluetooth.BTADDR_LE_PUBLIC };
const ltk = [16]u8{ 0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF };
const zero8: [8]u8 = @splat(0);

/// A layer up, BR/EDR and LE - LE's buffers its own - named "nuc", its
/// address set and `port` its cryptography.
fn upLayer(recorder: *Recorder, port: *Port) Hci {
    var layer = Hci{ .port = .{ .context = recorder, .send = Recorder.send } };
    layer.state = bluetooth.BTCS_UP;
    layer.features[0] = .{ 0xBF, 0xFE, 0xCF, 0xFE, 0xDB, 0xFF, 0x7B, 0x87 };
    layer.credits = 4;
    layer.now = 100_000;
    layer.acl_mtu = 1021;
    layer.acl_packets = 6;
    layer.le_mtu = 251;
    layer.le_packets = 8;
    layer.le_own = true;
    layer.address = ours;
    layer.crypto = port.of().*;
    acl.buffersRead(&layer);
    @memcpy(layer.name[0..4], "nuc\x00");
    return layer;
}

fn event(layer: *Hci, code: u8, params: []const u8) void {
    var packet: [hci.HCI_MAX_EVENT]u8 = undefined;
    packet[0] = code;
    packet[1] = @intCast(params.len);
    @memcpy(packet[2..][0..params.len], params);
    _hci.received(layer, hcidev.HCI_EVENT_PKT, packet[0 .. 2 + params.len]);
}

fn status(layer: *Hci, opcode: u16, code: u8) void {
    event(layer, hci.HCI_EV_COMMAND_STATUS, &.{ code, 4, @truncate(opcode), @truncate(opcode >> 8) });
}

fn complete(layer: *Hci, opcode: u16, returned: []const u8) void {
    var params: [hci.HCI_MAX_PARAMS]u8 = undefined;
    params[0] = 4;
    params[1] = @truncate(opcode);
    params[2] = @truncate(opcode >> 8);
    @memcpy(params[3..][0..returned.len], returned);
    event(layer, hci.HCI_EV_COMMAND_COMPLETE, params[0 .. 3 + returned.len]);
}

/// A link `address` makes to this machine, its peripheral, up as
/// `handle`: the device's features read over it.
fn linkedBy(layer: *Hci, recorder: *const Recorder, address: bluetooth.BTAddress, handle: u16) !*connections.Connection {
    var params: [19]u8 = @splat(0);
    params[0] = hci.HCI_LE_EV_CONNECTION_COMPLETE;
    params[2] = @truncate(handle);
    params[3] = @truncate(handle >> 8);
    params[4] = hci.ROLE_PERIPHERAL;
    params[5] = if (address.kind == bluetooth.BTADDR_LE_RANDOM) hci.LE_ADDR_RANDOM else hci.LE_ADDR_PUBLIC;
    params[6..12].* = address.bytes;
    params[12] = 0x18; // every 30 ms
    params[16] = 0x2A; // supervised for 420 ms
    event(layer, hci.HCI_EV_LE_META, &params);
    try testing.expectEqual(hci.HCI_OP_LE_READ_REMOTE_FEATURES, recorder.last().opcode);
    status(layer, hci.HCI_OP_LE_READ_REMOTE_FEATURES, 0);
    var features: [12]u8 = @splat(0);
    features[0] = hci.HCI_LE_EV_READ_REMOTE_FEATURES_COMPLETE;
    features[2] = @truncate(handle);
    features[3] = @truncate(handle >> 8);
    features[4] = 0x01; // encryption
    event(layer, hci.HCI_EV_LE_META, &features);
    const link = connections.byHandle(layer, handle).?;
    try testing.expect(link.le and link.incoming and !link.central and link.heard);
    return link;
}

/// The device's controller asks for the key of the link `handle`, by what
/// it goes by.
fn keyAsked(layer: *Hci, handle: u16, rand: [8]u8, ediv: u16) void {
    var params: [13]u8 = undefined;
    params[0] = hci.HCI_LE_EV_LONG_TERM_KEY_REQUEST;
    params[1] = @truncate(handle);
    params[2] = @truncate(handle >> 8);
    params[3..11].* = rand;
    params[11] = @truncate(ediv);
    params[12] = @truncate(ediv >> 8);
    event(layer, hci.HCI_EV_LE_META, &params);
}

/// LE Long Term Key Request Reply sent last, with `key`; answered.
fn expectKeyGiven(layer: *Hci, recorder: *const Recorder, handle: u16, key: *const [16]u8) !void {
    const command = recorder.last();
    try testing.expectEqual(hci.HCI_OP_LE_LONG_TERM_KEY_REPLY, command.opcode);
    var expected: [18]u8 = undefined;
    expected[0] = @truncate(handle);
    expected[1] = @truncate(handle >> 8);
    expected[2..18].* = key.*;
    try testing.expectEqualSlices(u8, &expected, command.bytes());
    complete(layer, command.opcode, &.{ 0, @truncate(handle), @truncate(handle >> 8) });
}

/// LE Long Term Key Request Negative Reply sent last; answered.
fn expectKeyRefused(layer: *Hci, recorder: *const Recorder, handle: u16) !void {
    const command = recorder.last();
    try testing.expectEqual(hci.HCI_OP_LE_LONG_TERM_KEY_NEGATIVE_REPLY, command.opcode);
    try testing.expectEqualSlices(u8, &.{ @truncate(handle), @truncate(handle >> 8) }, command.bytes());
    complete(layer, command.opcode, &.{ 0, @truncate(handle), @truncate(handle >> 8) });
}

/// The link not made secure noted last, the key missing.
fn expectNoted(layer: *const Hci, address: bluetooth.BTAddress) !void {
    const note = layer.notes[layer.note_count - 1];
    try testing.expectEqual(connections.NoteKind.not_secured, note.kind);
    try testing.expectEqualSlices(u8, &address.bytes, &note.address.bytes);
    try testing.expectEqual(@as(i32, hci.HCI_ERR_PIN_OR_KEY_MISSING), note.reason);
}

/// A PDU of the device's on the link's attribute channel, in one packet.
fn attIn(layer: *Hci, handle: u16, pdu: []const u8) void {
    var packet: [hci.HCI_ACL_HDR + l2cap.L2CAP_HDR + 32]u8 = undefined;
    const head = handle | hci.ACL_START << hci.ACL_BOUNDARY_SHIFT;
    const length = l2cap.L2CAP_HDR + pdu.len;
    packet[0] = @truncate(head);
    packet[1] = @truncate(head >> 8);
    packet[2] = @truncate(length);
    packet[3] = 0;
    packet[4] = @truncate(pdu.len);
    packet[5] = 0;
    packet[6] = @truncate(l2cap.CID_ATT);
    packet[7] = 0;
    @memcpy(packet[8..][0..pdu.len], pdu);
    _hci.received(layer, hcidev.HCI_ACLDATA_PKT, packet[0 .. hci.HCI_ACL_HDR + length]);
}

/// The frame the link was sent last: `pdu`, on the attribute channel.
fn expectAtt(recorder: *const Recorder, handle: u16, pdu: []const u8) !void {
    const packet = recorder.lastPacket();
    try testing.expectEqual(handle, packet.handle);
    try testing.expectEqual(l2cap.CID_ATT, _hci.le16(packet.data[2..4]));
    try testing.expectEqualSlices(u8, pdu, packet.bytes()[l2cap.L2CAP_HDR..]);
}

test "a link a device makes, this machine its peripheral: the attribute server answers over it, and it stays until the device ends it" {
    var recorder = Recorder{};
    var port = Port{};
    var layer = upLayer(&recorder, &port);
    const link = try linkedBy(&layer, &recorder, phone, 0x0041);
    try testing.expect(!link.for_channels);
    try testing.expectEqual(connections.NoteKind.up, layer.notes[layer.note_count - 1].kind);
    try testing.expect(layer.notes[layer.note_count - 1].incoming);
    // The device's MTU, this machine's said; the name; the services.
    attIn(&layer, 0x0041, &.{ 0x02, 0xF7, 0x00 });
    try expectAtt(&recorder, 0x0041, &.{ 0x03, 0x05, 0x02 });
    attIn(&layer, 0x0041, &.{ 0x0A, 0x03, 0x00 });
    try expectAtt(&recorder, 0x0041, "\x0Bnuc");
    attIn(&layer, 0x0041, &.{ 0x10, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28 });
    try expectAtt(&recorder, 0x0041, &.{ 0x11, 6, 0x01, 0x00, 0x05, 0x00, 0x00, 0x18, 0x06, 0x00, 0x09, 0x00, 0x01, 0x18 });
    // Nothing of this side's ends it.
    layer.now += 60_000;
    _hci.tick(&layer);
    try testing.expect(connections.find(&layer, phone) == link);
    event(&layer, hci.HCI_EV_DISCONNECTION_COMPLETE, &.{ 0, 0x41, 0x00, hci.HCI_ERR_REMOTE_USER_TERMINATED });
    try testing.expect(connections.find(&layer, phone) == null);
}

test "a central's encryption answered with the key of its bond made by Secure Connections, cut to the bond's size: the link encrypted" {
    var recorder = Recorder{};
    var port = Port{};
    var layer = upLayer(&recorder, &port);
    _ = bonds.keepLe(&layer, phone, &.{ .ltk = ltk, .key_size = 16, .authenticated = true, .secure = true }, "Phone").?;
    const link = try linkedBy(&layer, &recorder, phone, 0x0041);
    keyAsked(&layer, 0x0041, zero8, 0);
    try expectKeyGiven(&layer, &recorder, 0x0041, &ltk);
    event(&layer, hci.HCI_EV_ENCRYPTION_CHANGE, &.{ 0, 0x41, 0x00, 1 });
    try testing.expect(link.encrypted and link.authenticated);
    try testing.expectEqual(connections.NoteKind.up, layer.notes[layer.note_count - 1].kind);

    // A bond of ten bytes: the rest of the key zeros.
    _ = bonds.keepLe(&layer, laptop, &.{ .ltk = ltk, .key_size = 10, .authenticated = false, .secure = true }, "Laptop").?;
    _ = try linkedBy(&layer, &recorder, laptop, 0x0042);
    keyAsked(&layer, 0x0042, zero8, 0);
    var cut = ltk;
    @memset(cut[10..], 0);
    try expectKeyGiven(&layer, &recorder, 0x0042, &cut);
}

test "refused, and noted: a device without a bond, a key that goes by an EDIV and Rand, a legacy bond's key, a handle no link has" {
    var recorder = Recorder{};
    var port = Port{};
    var layer = upLayer(&recorder, &port);
    const link = try linkedBy(&layer, &recorder, phone, 0x0041);
    keyAsked(&layer, 0x0041, zero8, 0);
    try expectKeyRefused(&layer, &recorder, 0x0041);
    try expectNoted(&layer, phone);
    try testing.expect(!link.encrypted);

    // Its bond made by Secure Connections, asked for by an EDIV and Rand.
    _ = bonds.keepLe(&layer, phone, &.{ .ltk = ltk, .key_size = 16, .authenticated = true, .secure = true }, "Phone").?;
    keyAsked(&layer, 0x0041, .{ 1, 2, 3, 4, 5, 6, 7, 8 }, 0x2F1A);
    try expectKeyRefused(&layer, &recorder, 0x0041);

    // A legacy bond: its key the device's own, given for this side's links
    // to it as their central - asked for by what it goes by, or by none.
    const rand = [8]u8{ 0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18 };
    _ = bonds.keepLe(&layer, laptop, &.{ .ltk = ltk, .ediv = 0x2F1A, .rand = rand, .key_size = 16, .authenticated = false, .secure = false }, "Laptop").?;
    _ = try linkedBy(&layer, &recorder, laptop, 0x0042);
    keyAsked(&layer, 0x0042, rand, 0x2F1A);
    try expectKeyRefused(&layer, &recorder, 0x0042);
    try expectNoted(&layer, laptop);
    keyAsked(&layer, 0x0042, zero8, 0);
    try expectKeyRefused(&layer, &recorder, 0x0042);

    // A handle no link has.
    const notes = layer.note_count;
    keyAsked(&layer, 0x0077, zero8, 0);
    try expectKeyRefused(&layer, &recorder, 0x0077);
    try testing.expectEqual(notes, layer.note_count);
}

test "a central at a private address its bond's identity resolving key made: the bond's key given, the link found by the bond's address" {
    var recorder = Recorder{};
    var port = Port{};
    var layer = upLayer(&recorder, &port);
    const irk = [16]u8{ 0x9B, 0x7D, 0x39, 0x0A, 0xA6, 0x10, 0x10, 0x34, 0x05, 0xAD, 0xC8, 0x57, 0xA3, 0x34, 0x02, 0xEC };
    _ = bonds.keepLe(&layer, phone, &.{ .ltk = ltk, .key_size = 16, .authenticated = true, .secure = true, .irk = irk }, "Phone").?;
    // An address its key made: the hash of the random part 0x708194 (its
    // top bits 01), then that part.
    const private = bluetooth.BTAddress{ .bytes = .{ 0xAA, 0xFB, 0x0D, 0x94, 0x81, 0x70 }, .kind = bluetooth.BTADDR_LE_RANDOM };
    const link = try linkedBy(&layer, &recorder, private, 0x0041);
    try testing.expect(connections.find(&layer, phone).? == link);
    keyAsked(&layer, 0x0041, zero8, 0);
    try expectKeyGiven(&layer, &recorder, 0x0041, &ltk);
}
