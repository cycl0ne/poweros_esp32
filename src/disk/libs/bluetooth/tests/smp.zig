// SPDX-License-Identifier: MIT
//! Host tests of LE's pairings, the test playing the device - the
//! specification's responder, its confirms, nonces and checks made with
//! the same functions - and the controller, answered by hand: Secure
//! Connections with a number compared and the device's identity kept;
//! Passkey Entry's twenty rounds with the passkey shown; Just Works;
//! legacy pairing with a passkey typed, the keys the device gives, the
//! bond's file, and the link made secure with the bond again; a device's
//! Security Request asked of the agent and refused, and refused without
//! an agent; too short a key, a wrong confirm, the device's refusal; the
//! debug key; a private address resolved to its bond, and a device that
//! lost the bond; the method table.

const std = @import("std");
const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const l2cap = bluetooth.l2cap;
const hcidev = sdk.devices.hci;
const Scanner = sdk.dos.keywords.Scanner;
const _hci = @import("../hci/_hci.zig");
const Hci = _hci.Hci;
const acl = @import("../hci/acl.zig");
const bonds = @import("../hci/bonds.zig");
const connections = @import("../hci/connections.zig");
const pairing = @import("../hci/pairing.zig");
const smp = @import("../hci/smp.zig");
const smpcrypto = @import("../hci/smpcrypto.zig");
const bondfiles = @import("../task/bondfiles.zig");
const Port = @import("_port.zig").Port;

const testing = std.testing;

/// A controller that keeps the commands and packets it is sent.
const Recorder = struct {
    commands: [64]Command = undefined,
    command_count: usize = 0,
    /// The packets, the last `packets.len` of them, and how many the test
    /// has read.
    packets: [16]Packet = undefined,
    packet_count: usize = 0,
    packets_read: usize = 0,

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
    };

    fn send(context: *anyopaque, packet_type: u8, bytes: []const u8) bool {
        const recorder: *Recorder = @ptrCast(@alignCast(context));
        switch (packet_type) {
            hcidev.HCI_COMMAND_PKT => {
                const command = &recorder.commands[recorder.command_count];
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
        return &recorder.commands[recorder.command_count - 1];
    }
};

const handle: u16 = 0x0040;
/// This machine's controller, and the device: documentation addresses.
const central_bytes = [6]u8{ 0x00, 0x10, 0xEF, 0x5E, 0x00, 0x00 };
const device_address = bluetooth.BTAddress{ .bytes = .{ 0x42, 0x10, 0xEF, 0x5E, 0x00, 0x00 }, .kind = bluetooth.BTADDR_LE_PUBLIC };
const zero16: [16]u8 = @splat(0);
const zero8: [8]u8 = @splat(0);

/// A layer up, BR/EDR and LE - LE's buffers its own, eight of 251 - its
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
    layer.address = central_bytes;
    layer.crypto = port.of().*;
    acl.buffersRead(&layer);
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

fn leConnectionComplete(layer: *Hci, address: bluetooth.BTAddress) void {
    var params: [19]u8 = @splat(0);
    params[0] = hci.HCI_LE_EV_CONNECTION_COMPLETE;
    params[2] = @truncate(handle);
    params[3] = @truncate(handle >> 8);
    params[4] = hci.ROLE_CENTRAL;
    params[5] = if (address.kind == bluetooth.BTADDR_LE_RANDOM) hci.LE_ADDR_RANDOM else hci.LE_ADDR_PUBLIC;
    params[6..12].* = address.bytes;
    params[12] = 0x18;
    params[16] = 0x2A;
    event(layer, hci.HCI_EV_LE_META, &params);
}

/// The LE link the library is making to `address` up.
fn linkedUp(layer: *Hci, recorder: *const Recorder, address: bluetooth.BTAddress) !void {
    try testing.expectEqual(hci.HCI_OP_LE_CREATE_CONNECTION, recorder.last().opcode);
    status(layer, hci.HCI_OP_LE_CREATE_CONNECTION, 0);
    leConnectionComplete(layer, address);
}

/// A frame of the security manager's from the device: its code, then
/// `body`.
fn smpIn(layer: *Hci, code: u8, body: []const u8) void {
    var frame: [l2cap.L2CAP_HDR + 80]u8 = undefined;
    const length = 1 + body.len;
    frame[0] = @truncate(length);
    frame[1] = 0;
    frame[2] = @truncate(l2cap.CID_SMP);
    frame[3] = 0;
    frame[4] = code;
    @memcpy(frame[5..][0..body.len], body);
    var packet: [hci.HCI_ACL_HDR + l2cap.L2CAP_HDR + 80]u8 = undefined;
    const head = handle | hci.ACL_START << hci.ACL_BOUNDARY_SHIFT;
    packet[0] = @truncate(head);
    packet[1] = @truncate(head >> 8);
    packet[2] = @truncate(l2cap.L2CAP_HDR + length);
    packet[3] = 0;
    @memcpy(packet[hci.HCI_ACL_HDR..][0 .. l2cap.L2CAP_HDR + length], frame[0 .. l2cap.L2CAP_HDR + length]);
    _hci.received(layer, hcidev.HCI_ACLDATA_PKT, packet[0 .. hci.HCI_ACL_HDR + l2cap.L2CAP_HDR + length]);
}

/// The next frame the library sent, on the security manager's channel of
/// the link - its packet given back - copied into `into`.
fn smpOut(layer: *Hci, recorder: *Recorder, into: *[80]u8) ![]const u8 {
    try testing.expect(recorder.packets_read < recorder.packet_count);
    const packet = &recorder.packets[recorder.packets_read % recorder.packets.len];
    recorder.packets_read += 1;
    try testing.expectEqual(handle, packet.handle);
    try testing.expectEqual(l2cap.CID_SMP, _hci.le16(packet.data[2..4]));
    const length = _hci.le16(packet.data[0..2]);
    @memcpy(into[0..length], packet.data[l2cap.L2CAP_HDR..][0..length]);
    event(layer, hci.HCI_EV_NUMBER_OF_COMPLETED_PACKETS, &.{ 1, @truncate(handle), @truncate(handle >> 8), 1, 0 });
    return into[0..length];
}

/// The next frame sent: `code` and its body's length checked; the body.
fn expectSmp(layer: *Hci, recorder: *Recorder, into: *[80]u8, code: u8, body_length: usize) ![]const u8 {
    const frame = try smpOut(layer, recorder, into);
    try testing.expectEqual(code, frame[0]);
    try testing.expectEqual(body_length, frame.len - 1);
    return frame[1..];
}

/// Nothing more sent on the link.
fn expectQuiet(recorder: *const Recorder) !void {
    try testing.expectEqual(recorder.packet_count, recorder.packets_read);
}

/// LE Enable Encryption sent last, with `key` and what it goes by; its
/// status answered, and the link's Encryption Change with `code`.
fn expectEncryption(layer: *Hci, recorder: *const Recorder, key: *const [16]u8, ediv: u16, rand: *const [8]u8, code: u8) !void {
    const command = recorder.last();
    try testing.expectEqual(hci.HCI_OP_LE_ENABLE_ENCRYPTION, command.opcode);
    var expected: [28]u8 = undefined;
    expected[0] = @truncate(handle);
    expected[1] = @truncate(handle >> 8);
    expected[2..10].* = rand.*;
    expected[10] = @truncate(ediv);
    expected[11] = @truncate(ediv >> 8);
    expected[12..28].* = key.*;
    try testing.expectEqualSlices(u8, &expected, command.bytes());
    status(layer, hci.HCI_OP_LE_ENABLE_ENCRYPTION, 0);
    event(layer, hci.HCI_EV_ENCRYPTION_CHANGE, &.{ code, @truncate(handle), @truncate(handle >> 8), if (code == 0) 1 else 0 });
}

/// The task's part: the link's question sent to its agent in `message`.
fn sent(layer: *Hci, address: bluetooth.BTAddress, message: *anyopaque) *pairing.Question {
    const question = &connections.find(layer, address).?.pairing.question;
    question.sent = true;
    question.message = message;
    return question;
}

fn expectNotice(layer: *Hci, kind: pairing.NoticeKind, agent: u32, ours: bool, result: i32) !pairing.Notice {
    try testing.expect(layer.notice_count >= 1);
    const item = layer.notices[0];
    try testing.expectEqual(kind, item.kind);
    try testing.expectEqual(agent, item.agent);
    try testing.expectEqual(ours, item.ours);
    try testing.expectEqual(result, item.result);
    // Taken by the task.
    for (1..layer.notice_count) |index| layer.notices[index - 1] = layer.notices[index];
    layer.notice_count -= 1;
    return item;
}

/// A public key's two halves the other way round: SMP's order from the
/// most significant byte first, and back.
fn flipped(key: *const [64]u8) [64]u8 {
    var out: [64]u8 = undefined;
    out[0..32].* = smpcrypto.reversed(32, key[0..32]);
    out[32..64].* = smpcrypto.reversed(32, key[32..64]);
    return out;
}

fn withType(bytes: *const [6]u8, kind: u8) [7]u8 {
    var out: [7]u8 = undefined;
    out[0..6].* = bytes.*;
    out[6] = kind;
    return out;
}

fn passkeyValue(passkey: u32) [16]u8 {
    var value: [16]u8 = @splat(0);
    std.mem.writeInt(u32, value[0..4], passkey, .little);
    return value;
}

/// The device: the specification's responder, as the test plays it.
const Device = struct {
    port: Port = .{ .counter = 129 },
    address: bluetooth.BTAddress = device_address,
    private_key: [32]u8 = undefined,
    /// In SMP's order.
    public_key: [64]u8 = undefined,

    fn crypto(device: *Device) *const smpcrypto.Crypto {
        return device.port.of();
    }

    fn random(device: *Device) [16]u8 {
        var out: [16]u8 = undefined;
        const port = device.crypto();
        port.random(port.context, &out);
        return out;
    }

    fn makeKeys(device: *Device) !void {
        const port = device.crypto();
        var public_key: [64]u8 = undefined;
        try testing.expect(port.keyPair(port.context, &device.private_key, &public_key));
        device.public_key = flipped(&public_key);
    }

    /// The secret shared with the central's public key, in SMP's order.
    fn shared(device: *Device, central_key: *const [64]u8) ![32]u8 {
        const port = device.crypto();
        const peer = flipped(central_key);
        var secret: [32]u8 = undefined;
        try testing.expect(port.shared(port.context, &device.private_key, &peer, &secret));
        return smpcrypto.reversed(32, &secret);
    }

    /// The A and B f5 and f6 take: the central's address, the device's.
    fn a() [7]u8 {
        return withType(&central_bytes, 0);
    }
    fn b(device: *const Device) [7]u8 {
        return withType(&device.address.bytes, if (device.address.kind == bluetooth.BTADDR_LE_RANDOM) 1 else 0);
    }
};

/// Secure Connections from the Pairing Response on, as the device plays
/// it: the public keys, then the device's confirm and the nonces - the
/// library's nonce and the shared secret returned.
const Exchanged = struct { central_key: [64]u8, dhkey: [32]u8, na: [16]u8, nb: [16]u8 };

fn exchangeKeys(layer: *Hci, recorder: *Recorder, device: *Device, response: *const [7]u8) !Exchanged {
    var buffer: [80]u8 = undefined;
    smpIn(layer, smp.PAIRING_RESPONSE, response[1..]);
    const central_key = (try expectSmp(layer, recorder, &buffer, smp.PAIRING_PUBLIC_KEY, 64))[0..64].*;
    try device.makeKeys();
    const dhkey = try device.shared(&central_key);
    smpIn(layer, smp.PAIRING_PUBLIC_KEY, &device.public_key);
    return .{ .central_key = central_key, .dhkey = dhkey, .na = undefined, .nb = undefined };
}

fn nonces(layer: *Hci, recorder: *Recorder, device: *Device, exchanged: *Exchanged) !void {
    var buffer: [80]u8 = undefined;
    exchanged.nb = device.random();
    const cb = smpcrypto.f4(device.crypto(), device.public_key[0..32], exchanged.central_key[0..32], &exchanged.nb, 0);
    smpIn(layer, smp.PAIRING_CONFIRM, &cb);
    exchanged.na = (try expectSmp(layer, recorder, &buffer, smp.PAIRING_RANDOM, 16))[0..16].*;
    smpIn(layer, smp.PAIRING_RANDOM, &exchanged.nb);
}

/// The DHKey checks: the library's checked, the device's sent - the long
/// term key f5 makes returned.
fn checks(layer: *Hci, recorder: *Recorder, device: *Device, exchanged: *const Exchanged, request: *const [7]u8, response: *const [7]u8, r: *const [16]u8) ![16]u8 {
    var buffer: [80]u8 = undefined;
    const port = device.crypto();
    const keys = smpcrypto.f5(port, &exchanged.dhkey, &exchanged.na, &exchanged.nb, &Device.a(), &device.b());
    const ea = smpcrypto.f6(port, &keys.mac_key, &exchanged.na, &exchanged.nb, r, &.{ request[1], request[2], request[3] }, &Device.a(), &device.b());
    try testing.expectEqualSlices(u8, &ea, try expectSmp(layer, recorder, &buffer, smp.PAIRING_DHKEY_CHECK, 16));
    const eb = smpcrypto.f6(port, &keys.mac_key, &exchanged.nb, &exchanged.na, r, &.{ response[1], response[2], response[3] }, &device.b(), &Device.a());
    smpIn(layer, smp.PAIRING_DHKEY_CHECK, &eb);
    return keys.ltk;
}

/// The library's pairing begun with the device, its link made, and its
/// Pairing Request checked: the request.
fn begun(layer: *Hci, recorder: *Recorder, device: *const Device, capability: u32, auth: u8) ![7]u8 {
    try testing.expectEqual(@as(i32, 0), pairing.pair(layer, device.address, 7, capability));
    try linkedUp(layer, recorder, device.address);
    var buffer: [80]u8 = undefined;
    const request = (try smpOut(layer, recorder, &buffer))[0..7].*;
    try testing.expectEqualSlices(u8, &.{ smp.PAIRING_REQUEST, @as(u8, @intCast(capability)), 0, auth, 16, 0, smp.KEYDIST_ENC | smp.KEYDIST_ID }, &request);
    return request;
}

test "LE Secure Connections: the library's pairing, a number compared, the device's identity kept" {
    var recorder = Recorder{};
    var ours = Port{};
    var layer = upLayer(&recorder, &ours);
    var device = Device{};
    const request = try begun(&layer, &recorder, &device, bluetooth.BTIO_KEYBOARDDISPLAY, smp.AUTH_BONDING | smp.AUTH_MITM | smp.AUTH_SC);
    const response = [7]u8{ smp.PAIRING_RESPONSE, smp.IO_DISPLAY_YES_NO, 0, smp.AUTH_BONDING | smp.AUTH_MITM | smp.AUTH_SC, 16, 0, smp.KEYDIST_ID };
    var exchanged = try exchangeKeys(&layer, &recorder, &device, &response);
    try nonces(&layer, &recorder, &device, &exchanged);

    // The six digits both show, for the agent to compare.
    const number = smpcrypto.g2(device.crypto(), exchanged.central_key[0..32], device.public_key[0..32], &exchanged.na, &exchanged.nb);
    var message: u8 = 0;
    const question = sent(&layer, device.address, &message);
    try testing.expectEqual(bluetooth.BTAK_CONFIRM, question.kind);
    try testing.expectEqual(number, question.number);
    try expectQuiet(&recorder);
    try testing.expect(pairing.agentAnswered(&layer, &message, true, 0, &.{}));

    const ltk = try checks(&layer, &recorder, &device, &exchanged, &request, &response, &zero16);
    try expectEncryption(&layer, &recorder, &ltk, 0, &zero8, 0);
    try testing.expectEqual(@as(u8, 0), layer.notice_count);

    // Its identity: a static random address, and the key that resolves
    // the private ones it makes.
    const irk = [16]u8{ 0x9B, 0x7D, 0x39, 0x0A, 0xA6, 0x10, 0x10, 0x34, 0x05, 0xAD, 0xC8, 0x57, 0xA3, 0x34, 0x02, 0xEC };
    const identity = bluetooth.BTAddress{ .bytes = .{ 0x43, 0x10, 0xEF, 0x5E, 0x00, 0xC0 }, .kind = bluetooth.BTADDR_LE_RANDOM };
    smpIn(&layer, smp.IDENTITY_INFORMATION, &irk);
    try testing.expectEqual(@as(u8, 0), layer.notice_count);
    smpIn(&layer, smp.IDENTITY_ADDRESS_INFORMATION, &([1]u8{hci.LE_ADDR_RANDOM} ++ identity.bytes));
    _ = try expectNotice(&layer, .done, 7, true, 0);

    const bond = bonds.find(&layer, identity).?;
    try testing.expectEqualSlices(u8, &ltk, &bond.key);
    try testing.expect(bond.has_irk);
    try testing.expectEqualSlices(u8, &irk, &bond.irk);
    try testing.expect(bonds.authenticated(bond) and bonds.secure(bond));
    try testing.expectEqual(@as(u8, 16), bond.key_size);
    try testing.expectEqual(@as(u16, 0), bond.ediv);
    try testing.expect(bond.dirty and layer.bonds_changed);
    try testing.expect(bonds.find(&layer, device.address) == null);
    const link = connections.find(&layer, device.address).?;
    try testing.expect(link.encrypted and link.pairing.stage == .idle and link.smp.phase == .idle);
    try expectQuiet(&recorder);
}

test "LE Secure Connections: Passkey Entry's twenty rounds, the passkey shown" {
    var recorder = Recorder{};
    var ours = Port{};
    var layer = upLayer(&recorder, &ours);
    var device = Device{};
    const request = try begun(&layer, &recorder, &device, bluetooth.BTIO_KEYBOARDDISPLAY, smp.AUTH_BONDING | smp.AUTH_MITM | smp.AUTH_SC);
    const response = [7]u8{ smp.PAIRING_RESPONSE, smp.IO_KEYBOARD_ONLY, 0, smp.AUTH_BONDING | smp.AUTH_MITM | smp.AUTH_SC, 16, 0, 0 };
    var exchanged = try exchangeKeys(&layer, &recorder, &device, &response);

    // The passkey shown, for the device's user to type.
    const shown = try expectNotice(&layer, .show, 7, true, 0);
    try testing.expect(shown.number <= 999_999);
    const passkey = shown.number;
    var buffer: [80]u8 = undefined;
    const port = device.crypto();
    for (0..20) |round| {
        const z = 0x80 | @as(u8, @intCast(passkey >> @intCast(round) & 1));
        const cai = (try expectSmp(&layer, &recorder, &buffer, smp.PAIRING_CONFIRM, 16))[0..16].*;
        const nbi = device.random();
        const cbi = smpcrypto.f4(port, device.public_key[0..32], exchanged.central_key[0..32], &nbi, z);
        smpIn(&layer, smp.PAIRING_CONFIRM, &cbi);
        const nai = (try expectSmp(&layer, &recorder, &buffer, smp.PAIRING_RANDOM, 16))[0..16].*;
        try testing.expectEqualSlices(u8, &cai, &smpcrypto.f4(port, exchanged.central_key[0..32], device.public_key[0..32], &nai, z));
        smpIn(&layer, smp.PAIRING_RANDOM, &nbi);
        exchanged.na = nai;
        exchanged.nb = nbi;
    }
    const ltk = try checks(&layer, &recorder, &device, &exchanged, &request, &response, &passkeyValue(passkey));
    try expectEncryption(&layer, &recorder, &ltk, 0, &zero8, 0);
    // No keys to give: over.
    _ = try expectNotice(&layer, .done, 7, true, 0);
    const bond = bonds.find(&layer, device.address).?;
    try testing.expect(bonds.authenticated(bond) and bonds.secure(bond) and !bond.has_irk);
}

test "LE Secure Connections: Just Works, the library's own pairing asking nothing" {
    var recorder = Recorder{};
    var ours = Port{};
    var layer = upLayer(&recorder, &ours);
    var device = Device{};
    const request = try begun(&layer, &recorder, &device, bluetooth.BTIO_DISPLAYYESNO, smp.AUTH_BONDING | smp.AUTH_MITM | smp.AUTH_SC);
    const response = [7]u8{ smp.PAIRING_RESPONSE, smp.IO_NO_INPUT_OUTPUT, 0, smp.AUTH_BONDING | smp.AUTH_SC, 16, 0, 0 };
    var exchanged = try exchangeKeys(&layer, &recorder, &device, &response);
    try nonces(&layer, &recorder, &device, &exchanged);
    try testing.expectEqual(@as(u32, 0), connections.find(&layer, device.address).?.pairing.question.kind);
    const ltk = try checks(&layer, &recorder, &device, &exchanged, &request, &response, &zero16);
    try expectEncryption(&layer, &recorder, &ltk, 0, &zero8, 0);
    _ = try expectNotice(&layer, .done, 7, true, 0);
    const bond = bonds.find(&layer, device.address).?;
    try testing.expect(!bonds.authenticated(bond) and bonds.secure(bond));
}

test "LE legacy pairing: a passkey typed, the device's keys kept, its file, and the link made secure again" {
    var recorder = Recorder{};
    var ours = Port{};
    var layer = upLayer(&recorder, &ours);
    var device = Device{};
    const request = try begun(&layer, &recorder, &device, bluetooth.BTIO_KEYBOARDDISPLAY, smp.AUTH_BONDING | smp.AUTH_MITM | smp.AUTH_SC);
    // No Secure Connections, a key of 12 bytes, both keys given.
    const response = [7]u8{ smp.PAIRING_RESPONSE, smp.IO_DISPLAY_ONLY, 0, smp.AUTH_BONDING | smp.AUTH_MITM, 12, 0, smp.KEYDIST_ENC | smp.KEYDIST_ID };
    smpIn(&layer, smp.PAIRING_RESPONSE, response[1..]);

    // The passkey the device shows, typed.
    var message: u8 = 0;
    const question = sent(&layer, device.address, &message);
    try testing.expectEqual(bluetooth.BTAK_PASSKEY, question.kind);
    try expectQuiet(&recorder);
    try testing.expect(pairing.agentAnswered(&layer, &message, true, 123456, &.{}));

    const port = device.crypto();
    const tk = passkeyValue(123456);
    var buffer: [80]u8 = undefined;
    const mconfirm = (try expectSmp(&layer, &recorder, &buffer, smp.PAIRING_CONFIRM, 16))[0..16].*;
    const srand = device.random();
    const sconfirm = smpcrypto.c1(port, &tk, &srand, &request, &response, 0, &central_bytes, 0, &device.address.bytes);
    smpIn(&layer, smp.PAIRING_CONFIRM, &sconfirm);
    const mrand = (try expectSmp(&layer, &recorder, &buffer, smp.PAIRING_RANDOM, 16))[0..16].*;
    try testing.expectEqualSlices(u8, &mconfirm, &smpcrypto.c1(port, &tk, &mrand, &request, &response, 0, &central_bytes, 0, &device.address.bytes));
    smpIn(&layer, smp.PAIRING_RANDOM, &srand);

    // Encrypted with the short-term key, cut to 12 bytes.
    var stk = smpcrypto.s1(port, &tk, &srand, &mrand);
    @memset(stk[12..], 0);
    try expectEncryption(&layer, &recorder, &stk, 0, &zero8, 0);

    // Its keys: the long term key and what it goes by, its identity.
    var ltk = device.random();
    @memset(ltk[12..], 0);
    const rand = [8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const irk = device.random();
    smpIn(&layer, smp.ENCRYPTION_INFORMATION, &ltk);
    smpIn(&layer, smp.CENTRAL_IDENTIFICATION, &([2]u8{ 0x34, 0x12 } ++ rand));
    try testing.expectEqual(@as(u8, 0), layer.notice_count);
    smpIn(&layer, smp.IDENTITY_INFORMATION, &irk);
    smpIn(&layer, smp.IDENTITY_ADDRESS_INFORMATION, &([1]u8{hci.LE_ADDR_PUBLIC} ++ device.address.bytes));
    _ = try expectNotice(&layer, .done, 7, true, 0);
    const bond = bonds.find(&layer, device.address).?;
    try testing.expectEqualSlices(u8, &ltk, &bond.key);
    try testing.expectEqual(@as(u16, 0x1234), bond.ediv);
    try testing.expectEqualSlices(u8, &rand, &bond.rand);
    try testing.expectEqual(@as(u8, 12), bond.key_size);
    try testing.expect(bonds.authenticated(bond) and !bonds.secure(bond) and bond.has_irk);

    // Its file, and read back the same.
    var text: [bondfiles.TEXT_MOST]u8 = undefined;
    const length = bondfiles.format(bond, &text);
    var scanner = Scanner.ofText(text[0..length]);
    var read = bonds.Bond{ .address = device.address };
    try testing.expect(bondfiles.parse(&scanner, &read));
    try testing.expectEqualSlices(u8, &bond.key, &read.key);
    try testing.expectEqual(bond.ediv, read.ediv);
    try testing.expectEqualSlices(u8, &bond.rand, &read.rand);
    try testing.expectEqual(bond.key_size, read.key_size);
    try testing.expect(read.le_authenticated and !read.le_secure and read.has_irk);
    try testing.expectEqualSlices(u8, &bond.irk, &read.irk);
    // A BR/EDR bond's keywords make no LE bond.
    var other = Scanner.ofText("LinkKey = 00112233445566778899AABBCCDDEEFF\nKeyType = 4\n");
    var not_le = bonds.Bond{ .address = device.address };
    try testing.expect(!bondfiles.parse(&other, &not_le));

    // The link down, and made again: made secure with the bond before
    // ConnectBTDevice is answered.
    event(&layer, hci.HCI_EV_DISCONNECTION_COMPLETE, &.{ 0, @truncate(handle), @truncate(handle >> 8), hci.HCI_ERR_REMOTE_USER_TERMINATED });
    const waiting = connections.connect(&layer, device.address);
    try testing.expect(waiting == .waiting);
    try linkedUp(&layer, &recorder, device.address);
    try testing.expect(!layer.waits[waiting.waiting].done);
    try expectEncryption(&layer, &recorder, &ltk, 0x1234, &rand, 0);
    try testing.expect(layer.waits[waiting.waiting].done);
    try testing.expectEqual(@as(i32, 0), layer.waits[waiting.waiting].result);
    connections.release(&layer, waiting.waiting);
}

test "LE: a device's Security Request - asked of the agent, refused; refused without an agent" {
    var recorder = Recorder{};
    var ours = Port{};
    var layer = upLayer(&recorder, &ours);
    var device = Device{};
    const waiting = connections.connect(&layer, device.address);
    try linkedUp(&layer, &recorder, device.address);
    connections.release(&layer, waiting.waiting);

    // Without an agent: refused.
    var buffer: [80]u8 = undefined;
    smpIn(&layer, smp.SECURITY_REQUEST, &.{smp.AUTH_BONDING});
    try testing.expectEqualSlices(u8, &.{smp.REASON_PAIRING_NOT_SUPPORTED}, try expectSmp(&layer, &recorder, &buffer, smp.PAIRING_FAILED, 1));

    // With one: the pairing begun, the library the initiator still.
    layer.agent_current = 9;
    layer.agent_capability = bluetooth.BTIO_DISPLAYYESNO;
    smpIn(&layer, smp.SECURITY_REQUEST, &.{smp.AUTH_BONDING});
    const request = (try expectSmp(&layer, &recorder, &buffer, smp.PAIRING_REQUEST, 6))[0..6].*;
    try testing.expectEqualSlices(u8, &.{ smp.IO_DISPLAY_YES_NO, 0, smp.AUTH_BONDING | smp.AUTH_MITM | smp.AUTH_SC, 16, 0, smp.KEYDIST_ENC | smp.KEYDIST_ID }, &request);
    const response = [7]u8{ smp.PAIRING_RESPONSE, smp.IO_NO_INPUT_OUTPUT, 0, smp.AUTH_BONDING | smp.AUTH_SC, 16, 0, 0 };
    var exchanged = try exchangeKeys(&layer, &recorder, &device, &response);
    try nonces(&layer, &recorder, &device, &exchanged);
    // Nothing to compare: the agent asked whether the device may pair.
    var message: u8 = 0;
    const question = sent(&layer, device.address, &message);
    try testing.expectEqual(bluetooth.BTAK_CONFIRM, question.kind);
    try testing.expectEqual(bluetooth.BT_NO_NUMBER, question.number);
    try testing.expect(pairing.agentAnswered(&layer, &message, false, 0, &.{}));
    try testing.expectEqualSlices(u8, &.{smp.REASON_PAIRING_NOT_SUPPORTED}, try expectSmp(&layer, &recorder, &buffer, smp.PAIRING_FAILED, 1));
    _ = try expectNotice(&layer, .done, 9, false, bluetooth.BTERR_REFUSED);
    try testing.expect(bonds.find(&layer, device.address) == null);
}

test "LE: too short a key, a wrong confirm, and the device's refusal end the pairing" {
    var recorder = Recorder{};
    var ours = Port{};
    var layer = upLayer(&recorder, &ours);
    var device = Device{};
    var buffer: [80]u8 = undefined;
    const auth = smp.AUTH_BONDING | smp.AUTH_MITM | smp.AUTH_SC;
    _ = try begun(&layer, &recorder, &device, bluetooth.BTIO_DISPLAYYESNO, auth);
    smpIn(&layer, smp.PAIRING_RESPONSE, &.{ smp.IO_NO_INPUT_OUTPUT, 0, smp.AUTH_BONDING | smp.AUTH_SC, 6, 0, 0 });
    try testing.expectEqualSlices(u8, &.{smp.REASON_ENCRYPTION_KEY_SIZE}, try expectSmp(&layer, &recorder, &buffer, smp.PAIRING_FAILED, 1));
    _ = try expectNotice(&layer, .done, 7, true, hci.HCI_ERR_INSUFFICIENT_SECURITY);

    // A confirm that is not the device's nonce's.
    try testing.expectEqual(@as(i32, 0), pairing.pair(&layer, device.address, 7, bluetooth.BTIO_DISPLAYYESNO));
    _ = try expectSmp(&layer, &recorder, &buffer, smp.PAIRING_REQUEST, 6);
    const response = [7]u8{ smp.PAIRING_RESPONSE, smp.IO_NO_INPUT_OUTPUT, 0, smp.AUTH_BONDING | smp.AUTH_SC, 16, 0, 0 };
    const exchanged = try exchangeKeys(&layer, &recorder, &device, &response);
    smpIn(&layer, smp.PAIRING_CONFIRM, &device.random());
    _ = try expectSmp(&layer, &recorder, &buffer, smp.PAIRING_RANDOM, 16);
    smpIn(&layer, smp.PAIRING_RANDOM, &device.random());
    try testing.expectEqualSlices(u8, &.{smp.REASON_CONFIRM_VALUE_FAILED}, try expectSmp(&layer, &recorder, &buffer, smp.PAIRING_FAILED, 1));
    _ = try expectNotice(&layer, .done, 7, true, hci.HCI_ERR_AUTHENTICATION_FAILURE);
    _ = exchanged;

    // The device's own Pairing Failed.
    try testing.expectEqual(@as(i32, 0), pairing.pair(&layer, device.address, 7, bluetooth.BTIO_DISPLAYYESNO));
    _ = try expectSmp(&layer, &recorder, &buffer, smp.PAIRING_REQUEST, 6);
    smpIn(&layer, smp.PAIRING_FAILED, &.{smp.REASON_AUTHENTICATION_REQUIREMENTS});
    _ = try expectNotice(&layer, .done, 7, true, hci.HCI_ERR_PAIRING_NOT_ALLOWED);
    try expectQuiet(&recorder);
    try testing.expect(connections.find(&layer, device.address).?.pairing.stage == .idle);
}

test "LE: a pairing with the specification's debug key keeps no bond" {
    var recorder = Recorder{};
    var ours = Port{};
    var layer = upLayer(&recorder, &ours);
    var device = Device{};
    const request = try begun(&layer, &recorder, &device, bluetooth.BTIO_DISPLAYYESNO, smp.AUTH_BONDING | smp.AUTH_MITM | smp.AUTH_SC);
    const response = [7]u8{ smp.PAIRING_RESPONSE, smp.IO_NO_INPUT_OUTPUT, 0, smp.AUTH_BONDING | smp.AUTH_SC, 16, 0, 0 };
    var buffer: [80]u8 = undefined;
    smpIn(&layer, smp.PAIRING_RESPONSE, response[1..]);
    const central_key = (try expectSmp(&layer, &recorder, &buffer, smp.PAIRING_PUBLIC_KEY, 64))[0..64].*;
    // The debug private key, most significant byte first.
    device.private_key = .{ 0x3F, 0x49, 0xF6, 0xD4, 0xA3, 0xC5, 0x5F, 0x38, 0x74, 0xC9, 0xB3, 0xE3, 0xD2, 0x10, 0x3F, 0x50, 0x4A, 0xFF, 0x60, 0x7B, 0xEB, 0x40, 0xB7, 0x99, 0x58, 0x99, 0xB8, 0xA6, 0xCD, 0x3C, 0x1A, 0xBD };
    device.public_key = smpcrypto.DEBUG_PUBLIC_KEY;
    var exchanged = Exchanged{ .central_key = central_key, .dhkey = try device.shared(&central_key), .na = undefined, .nb = undefined };
    smpIn(&layer, smp.PAIRING_PUBLIC_KEY, &device.public_key);
    try nonces(&layer, &recorder, &device, &exchanged);
    const ltk = try checks(&layer, &recorder, &device, &exchanged, &request, &response, &zero16);
    try expectEncryption(&layer, &recorder, &ltk, 0, &zero8, 0);
    _ = try expectNotice(&layer, .done, 7, true, 0);
    try testing.expect(bonds.find(&layer, device.address) == null);
}

test "LE: a private address resolved to its bond and made secure; a device that lost the bond" {
    var recorder = Recorder{};
    var ours = Port{};
    var layer = upLayer(&recorder, &ours);
    const irk = [16]u8{ 0x9B, 0x7D, 0x39, 0x0A, 0xA6, 0x10, 0x10, 0x34, 0x05, 0xAD, 0xC8, 0x57, 0xA3, 0x34, 0x02, 0xEC };
    const identity = bluetooth.BTAddress{ .bytes = .{ 0x44, 0x10, 0xEF, 0x5E, 0x00, 0x00 }, .kind = bluetooth.BTADDR_LE_PUBLIC };
    const ltk = [16]u8{ 0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF };
    _ = bonds.keepLe(&layer, identity, &.{ .ltk = ltk, .key_size = 16, .authenticated = true, .secure = true, .irk = irk }, "Sensor").?;
    // An address its key made: the hash of the random part 0x708194 (its
    // top bits 01), then that part.
    const private = bluetooth.BTAddress{ .bytes = .{ 0xAA, 0xFB, 0x0D, 0x94, 0x81, 0x70 }, .kind = bluetooth.BTADDR_LE_RANDOM };
    try testing.expect(smp.bondOf(&layer, &connections.Connection{ .address = private }) != null);
    const waiting = connections.connect(&layer, private);
    try linkedUp(&layer, &recorder, private);
    try expectEncryption(&layer, &recorder, &ltk, 0, &zero8, 0);
    try testing.expectEqual(@as(i32, 0), layer.waits[waiting.waiting].result);
    connections.release(&layer, waiting.waiting);
    event(&layer, hci.HCI_EV_DISCONNECTION_COMPLETE, &.{ 0, @truncate(handle), @truncate(handle >> 8), hci.HCI_ERR_REMOTE_USER_TERMINATED });

    // The device no longer has the key: the link is up, not made secure.
    const again = connections.connect(&layer, identity);
    try linkedUp(&layer, &recorder, identity);
    try expectEncryption(&layer, &recorder, &ltk, 0, &zero8, hci.HCI_ERR_PIN_OR_KEY_MISSING);
    try testing.expectEqual(@as(i32, hci.HCI_ERR_PIN_OR_KEY_MISSING), layer.waits[again.waiting].result);
    connections.release(&layer, again.waiting);
    const link = connections.find(&layer, identity).?;
    try testing.expect(link.state == .up and !link.encrypted);
    try testing.expectEqual(connections.NoteKind.not_secured, layer.notes[layer.note_count - 1].kind);

    // A Security Request from it: the bond's key tried again.
    smpIn(&layer, smp.SECURITY_REQUEST, &.{smp.AUTH_BONDING});
    try expectEncryption(&layer, &recorder, &ltk, 0, &zero8, 0);
    try testing.expect(connections.find(&layer, identity).?.encrypted);
    try expectQuiet(&recorder);
}

test "LE: the method by the two IO capabilities, and Pairing Failed's reasons" {
    try testing.expectEqual(smp.Method.compare, smp.methodOf(smp.IO_KEYBOARD_DISPLAY, smp.IO_DISPLAY_YES_NO, true));
    try testing.expectEqual(smp.Method.type_passkey, smp.methodOf(smp.IO_KEYBOARD_DISPLAY, smp.IO_DISPLAY_YES_NO, false));
    try testing.expectEqual(smp.Method.show_passkey, smp.methodOf(smp.IO_DISPLAY_YES_NO, smp.IO_KEYBOARD_ONLY, true));
    try testing.expectEqual(smp.Method.type_passkey, smp.methodOf(smp.IO_KEYBOARD_ONLY, smp.IO_KEYBOARD_ONLY, true));
    try testing.expectEqual(smp.Method.show_passkey, smp.methodOf(smp.IO_KEYBOARD_DISPLAY, smp.IO_KEYBOARD_DISPLAY, false));
    try testing.expectEqual(smp.Method.just_works, smp.methodOf(smp.IO_KEYBOARD_DISPLAY, smp.IO_NO_INPUT_OUTPUT, true));
    try testing.expectEqual(smp.Method.just_works, smp.methodOf(smp.IO_DISPLAY_ONLY, smp.IO_DISPLAY_ONLY, true));
    try testing.expectEqual(smp.Method.just_works, smp.methodOf(7, smp.IO_DISPLAY_ONLY, true));
    try testing.expectEqual(@as(i32, hci.HCI_ERR_AUTHENTICATION_FAILURE), smp.resultOf(smp.REASON_DHKEY_CHECK_FAILED));
    try testing.expectEqual(@as(i32, hci.HCI_ERR_PAIRING_NOT_ALLOWED), smp.resultOf(smp.REASON_PAIRING_NOT_SUPPORTED));
    try testing.expectEqual(@as(i32, hci.HCI_ERR_INSUFFICIENT_SECURITY), smp.resultOf(smp.REASON_ENCRYPTION_KEY_SIZE));
    try testing.expectEqual(@as(i32, hci.HCI_ERR_REPEATED_ATTEMPTS), smp.resultOf(smp.REASON_REPEATED_ATTEMPTS));
}
