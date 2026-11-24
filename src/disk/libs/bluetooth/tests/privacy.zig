// SPDX-License-Identifier: MIT
//! Host tests of the controller's private address, against a controller
//! the test answers by hand: made from the controller's key - resolved by
//! it, its top bits 01 - and given to the controller once it is up, the
//! advertising stopped before it and begun again behind it, the
//! controller's own once answered; a new one every 15 minutes and on
//! being made hidden; none while a discovery's LE scan runs or a link is
//! being made over LE, given once they are over; refused, and not
//! answered, tried again later with the address before kept; a
//! discovery's active scan from it; the links to devices given the
//! identity made from it - found by their address or by their key - and
//! those to the others, and a device's link to the advertising, from the
//! public one, each link keeping the address it was made from across a
//! change - its record saying it, and the identity a device's private
//! address resolved to, bonded so; none without crypto.library, the
//! identity, or the command.

const std = @import("std");
const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const hcidev = sdk.devices.hci;
const _hci = @import("../hci/_hci.zig");
const Hci = _hci.Hci;
const acl = @import("../hci/acl.zig");
const bonds = @import("../hci/bonds.zig");
const connections = @import("../hci/connections.zig");
const discovery = @import("../hci/discovery.zig");
const local = @import("../hci/local.zig");
const privacy = @import("../hci/privacy.zig");
const smpcrypto = @import("../hci/smpcrypto.zig");
const _connection = @import("../connection/_connection.zig");
const Port = @import("_port.zig").Port;

const testing = std.testing;

/// A controller that keeps the commands it is sent; `settle` answers them.
const Recorder = struct {
    sent: [128]Sent = undefined,
    count: usize = 0,
    answered: usize = 0,

    const Sent = struct {
        opcode: u16,
        length: usize,
        params: [hci.HCI_MAX_PARAMS]u8,
    };

    fn send(context: *anyopaque, packet_type: u8, bytes: []const u8) bool {
        const recorder: *Recorder = @ptrCast(@alignCast(context));
        if (packet_type != hcidev.HCI_COMMAND_PKT) return true;
        const sent = &recorder.sent[recorder.count];
        sent.opcode = _hci.le16(bytes[0..2]);
        sent.length = bytes[2];
        @memcpy(sent.params[0..sent.length], bytes[hci.HCI_COMMAND_HDR..]);
        recorder.count += 1;
        return true;
    }

    /// The opcodes sent from `from` on.
    fn opcodes(recorder: *const Recorder, from: usize, into: []u16) []u16 {
        for (recorder.sent[from..recorder.count], 0..) |sent, index| into[index] = sent.opcode;
        return into[0 .. recorder.count - from];
    }

    /// The last command sent with `opcode`.
    fn lastOf(recorder: *const Recorder, opcode: u16) ?*const Sent {
        var index = recorder.count;
        while (index > 0) {
            index -= 1;
            if (recorder.sent[index].opcode == opcode) return &recorder.sent[index];
        }
        return null;
    }

    /// How many commands with `opcode` were sent from `from` on.
    fn countOf(recorder: *const Recorder, from: usize, opcode: u16) usize {
        var found: usize = 0;
        for (recorder.sent[from..recorder.count]) |sent| {
            if (sent.opcode == opcode) found += 1;
        }
        return found;
    }
};

/// Every command sent and not yet answered, answered - and those the
/// answers make the layer send.
fn settle(layer: *Hci, recorder: *Recorder) void {
    while (recorder.answered < recorder.count) {
        const opcode = recorder.sent[recorder.answered].opcode;
        recorder.answered += 1;
        complete(layer, opcode, &.{hci.HCI_SUCCESS});
    }
}

/// The oldest command not yet answered, answered `status`.
fn answerNext(layer: *Hci, recorder: *Recorder, status: u8) void {
    const opcode = recorder.sent[recorder.answered].opcode;
    recorder.answered += 1;
    complete(layer, opcode, &.{status});
}

/// The commands not yet answered, never to be: forgotten by the test.
fn forgetUnanswered(recorder: *Recorder) void {
    recorder.answered = recorder.count;
}

/// The controller's key and public address, and the devices it links to.
const irk = [16]u8{ 0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF };
const own_bytes = [6]u8{ 0x60, 0x10, 0xEF, 0x5E, 0x00, 0x00 };
const public_own = bluetooth.BTAddress{ .bytes = own_bytes, .kind = bluetooth.BTADDR_LE_PUBLIC };
const given_peer = bluetooth.BTAddress{ .bytes = .{ 0x61, 0x10, 0xEF, 0x5E, 0x00, 0x00 }, .kind = bluetooth.BTADDR_LE_PUBLIC };
const other_peer = bluetooth.BTAddress{ .bytes = .{ 0x62, 0x10, 0xEF, 0x5E, 0x00, 0x00 }, .kind = bluetooth.BTADDR_LE_PUBLIC };
const ltk: [16]u8 = @splat(0x5A);

/// A layer up and on, BR/EDR and LE, taking every command, with LE's own
/// buffers, `port` its cryptography and the identity its key.
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
    acl.buffersRead(&layer);
    layer.address = own_bytes;
    layer.crypto = port.of().*;
    layer.irk = irk;
    layer.has_identity = true;
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

fn complete(layer: *Hci, opcode: u16, returned: []const u8) void {
    var params: [hci.HCI_MAX_PARAMS]u8 = undefined;
    params[0] = 4;
    params[1] = @truncate(opcode);
    params[2] = @truncate(opcode >> 8);
    @memcpy(params[3..][0..returned.len], returned);
    event(layer, hci.HCI_EV_COMMAND_COMPLETE, params[0 .. 3 + returned.len]);
}

/// LE Connection Complete: a link with `handle` to `address`, the
/// controller in `role`.
fn leLinked(layer: *Hci, handle: u16, role: u8, address: bluetooth.BTAddress) void {
    var params: [19]u8 = @splat(0);
    params[0] = hci.HCI_LE_EV_CONNECTION_COMPLETE;
    params[1] = hci.HCI_SUCCESS;
    params[2] = @truncate(handle);
    params[3] = @truncate(handle >> 8);
    params[4] = role;
    params[5] = if (address.kind == bluetooth.BTADDR_LE_RANDOM) hci.LE_ADDR_RANDOM else hci.LE_ADDR_PUBLIC;
    @memcpy(params[6..12], &address.bytes);
    params[12] = 0x28; // every 50 ms
    params[16] = 0x2A; // supervised for 420 ms
    event(layer, hci.HCI_EV_LE_META, &params);
}

/// LE Read Remote Features Complete for `handle`: the device has
/// answered on the link.
fn featuresRead(layer: *Hci, handle: u16) void {
    var params: [12]u8 = @splat(0);
    params[0] = hci.HCI_LE_EV_READ_REMOTE_FEATURES_COMPLETE;
    params[2] = @truncate(handle);
    params[3] = @truncate(handle >> 8);
    params[4] = 0x01; // encryption
    event(layer, hci.HCI_EV_LE_META, &params);
}

/// The record ObtainBTConnections would give of the link to `address`.
fn recordOf(layer: *Hci, address: bluetooth.BTAddress) bluetooth.BTConnection {
    var entry = _connection.Entry{};
    _connection.describe(0, layer, connections.find(layer, address).?, &entry, layer.now);
    return entry.public;
}

/// The layer given its first private address: answered, and returned.
fn firstAddress(layer: *Hci, recorder: *Recorder) bluetooth.BTAddress {
    privacy.reset(layer);
    _hci.tick(layer);
    settle(layer, recorder);
    return .{ .bytes = layer.privacy.address, .kind = bluetooth.BTADDR_LE_RANDOM };
}

/// The address the last LE Set Random Address gave.
fn lastGiven(recorder: *const Recorder) [6]u8 {
    return recorder.lastOf(hci.HCI_OP_LE_SET_RANDOM_ADDRESS).?.params[0..6].*;
}

test "made from the key - resolved by it, its top bits 01 - and given once the controller is up: the advertising stopped before it and begun again behind it, the address the controller's once answered" {
    var recorder = Recorder{};
    var port = Port{};
    var layer = upLayer(&recorder, &port);
    try testing.expectEqual(@as(i32, 0), local.setVisible(&layer, bluetooth.BT_VISIBLE_ALWAYS));
    settle(&layer, &recorder);
    try testing.expect(layer.advertising.on and !layer.privacy.has);
    const before = recorder.count;
    privacy.reset(&layer);
    _hci.tick(&layer);
    // Out, not yet answered: not the controller's yet.
    try testing.expect(layer.privacy.setting and !layer.privacy.has);
    try testing.expectEqual(hci.LE_ADDR_PUBLIC, privacy.scanning(&layer));
    settle(&layer, &recorder);
    var seen: [16]u16 = undefined;
    try testing.expectEqualSlices(u16, &.{
        hci.HCI_OP_LE_SET_ADVERTISING_ENABLE,
        hci.HCI_OP_LE_SET_RANDOM_ADDRESS,
        hci.HCI_OP_LE_SET_ADVERTISING_PARAMETERS,
        hci.HCI_OP_LE_SET_ADVERTISING_DATA,
        hci.HCI_OP_LE_SET_SCAN_RESPONSE_DATA,
        hci.HCI_OP_LE_SET_ADVERTISING_ENABLE,
    }, recorder.opcodes(before, &seen));
    try testing.expectEqual(@as(u8, 0), recorder.sent[before].params[0]);
    // The advertising while visible goes on from the public address.
    try testing.expectEqual(hci.LE_ADDR_PUBLIC, recorder.lastOf(hci.HCI_OP_LE_SET_ADVERTISING_PARAMETERS).?.params[5]);
    try testing.expect(layer.advertising.on);
    // Its top bits 01, the hash of the rest under the key below it.
    const given = lastGiven(&recorder);
    try testing.expectEqual(@as(u8, 0x40), given[5] & 0xC0);
    try testing.expect(smpcrypto.resolvable(&given));
    try testing.expect(smpcrypto.resolves(&layer.crypto.?, &irk, &given));
    var other_key = irk;
    other_key[0] ^= 1;
    try testing.expect(!smpcrypto.resolves(&layer.crypto.?, &other_key, &given));
    try testing.expect(layer.privacy.has and !layer.privacy.setting);
    try testing.expectEqualSlices(u8, &given, &layer.privacy.address);
    try testing.expectEqual(hci.LE_ADDR_RANDOM, privacy.scanning(&layer));
    try testing.expectEqual(@as(?u64, layer.now + privacy.ROTATE_MS), _hci.nextDeadline(&layer));
}

test "a new one every 15 minutes and on being made hidden; none while a discovery's LE scan runs or a link is being made over LE, given once they are over" {
    var recorder = Recorder{};
    var port = Port{};
    var layer = upLayer(&recorder, &port);
    const first = firstAddress(&layer, &recorder);
    try testing.expect(layer.privacy.has);

    // Its time over: a new one.
    layer.now += privacy.ROTATE_MS - 1;
    var before = recorder.count;
    _hci.tick(&layer);
    try testing.expectEqual(@as(usize, 0), recorder.countOf(before, hci.HCI_OP_LE_SET_RANDOM_ADDRESS));
    layer.now += 1;
    _hci.tick(&layer);
    settle(&layer, &recorder);
    try testing.expectEqual(@as(usize, 1), recorder.countOf(before, hci.HCI_OP_LE_SET_RANDOM_ADDRESS));
    const second = layer.privacy.address;
    try testing.expect(!std.mem.eql(u8, &first.bytes, &second));

    // Made hidden: a new one at once, the advertising stopped first.
    try testing.expectEqual(@as(i32, 0), local.setVisible(&layer, bluetooth.BT_VISIBLE_ALWAYS));
    settle(&layer, &recorder);
    before = recorder.count;
    try testing.expectEqual(@as(i32, 0), local.setVisible(&layer, 0));
    settle(&layer, &recorder);
    var seen: [16]u16 = undefined;
    try testing.expectEqualSlices(u16, &.{ hci.HCI_OP_WRITE_SCAN_ENABLE, hci.HCI_OP_LE_SET_ADVERTISING_ENABLE, hci.HCI_OP_LE_SET_RANDOM_ADDRESS }, recorder.opcodes(before, &seen));
    const third = layer.privacy.address;
    try testing.expect(!std.mem.eql(u8, &second, &third));
    // Hidden already: none.
    before = recorder.count;
    try testing.expectEqual(@as(i32, 0), local.setVisible(&layer, 0));
    settle(&layer, &recorder);
    try testing.expectEqual(@as(usize, 0), recorder.countOf(before, hci.HCI_OP_LE_SET_RANDOM_ADDRESS));

    // A discovery's LE scan, from the private address: none while it runs,
    // one once its LE phase is over.
    try testing.expectEqual(@as(i32, 0), discovery.start(&layer, 6000));
    settle(&layer, &recorder);
    try testing.expectEqual(hci.LE_ADDR_RANDOM, recorder.lastOf(hci.HCI_OP_LE_SET_SCAN_PARAMETERS).?.params[5]);
    layer.privacy.wanted = true;
    before = recorder.count;
    _hci.tick(&layer);
    settle(&layer, &recorder);
    try testing.expectEqual(@as(usize, 0), recorder.countOf(before, hci.HCI_OP_LE_SET_RANDOM_ADDRESS));
    layer.now += 2000;
    _hci.tick(&layer);
    settle(&layer, &recorder);
    try testing.expectEqualSlices(u16, &.{ hci.HCI_OP_LE_SET_SCAN_ENABLE, hci.HCI_OP_INQUIRY, hci.HCI_OP_LE_SET_RANDOM_ADDRESS }, recorder.opcodes(before, &seen));
    discovery.stop(&layer);
    settle(&layer, &recorder);

    // A link being made over LE: none until it is up.
    _ = connections.connect(&layer, other_peer);
    settle(&layer, &recorder);
    layer.privacy.wanted = true;
    before = recorder.count;
    _hci.tick(&layer);
    settle(&layer, &recorder);
    try testing.expectEqual(@as(usize, 0), recorder.countOf(before, hci.HCI_OP_LE_SET_RANDOM_ADDRESS));
    leLinked(&layer, 0x0040, hci.ROLE_CENTRAL, other_peer);
    settle(&layer, &recorder);
    try testing.expectEqual(@as(usize, 1), recorder.countOf(before, hci.HCI_OP_LE_SET_RANDOM_ADDRESS));
}

test "refused, and not answered: tried again 10 s later, the address before kept until one is taken" {
    var recorder = Recorder{};
    var port = Port{};
    var layer = upLayer(&recorder, &port);
    const first = firstAddress(&layer, &recorder);
    layer.now += privacy.ROTATE_MS;
    _hci.tick(&layer);
    // Command Disallowed: the address before stays.
    answerNext(&layer, &recorder, hci.HCI_ERR_COMMAND_DISALLOWED);
    try testing.expect(layer.privacy.has and !layer.privacy.setting);
    try testing.expectEqualSlices(u8, &first.bytes, &layer.privacy.address);
    try testing.expectEqual(@as(?u64, layer.now + privacy.RETRY_MS), _hci.nextDeadline(&layer));
    layer.now += privacy.RETRY_MS;
    var before = recorder.count;
    _hci.tick(&layer);
    try testing.expectEqual(@as(usize, 1), recorder.countOf(before, hci.HCI_OP_LE_SET_RANDOM_ADDRESS));
    // Not answered in its time: tried again too.
    forgetUnanswered(&recorder);
    layer.now += _hci.COMMAND_TIMEOUT_MS;
    _hci.tick(&layer);
    try testing.expect(!layer.privacy.setting);
    try testing.expectEqualSlices(u8, &first.bytes, &layer.privacy.address);
    layer.now += privacy.RETRY_MS;
    before = recorder.count;
    _hci.tick(&layer);
    settle(&layer, &recorder);
    try testing.expectEqual(@as(usize, 1), recorder.countOf(before, hci.HCI_OP_LE_SET_RANDOM_ADDRESS));
    try testing.expectEqualSlices(u8, &lastGiven(&recorder), &layer.privacy.address);
    try testing.expect(!std.mem.eql(u8, &first.bytes, &layer.privacy.address));
}

test "a link to a device given the identity - found by its address or by its key - goes from the private address and keeps it across a change; a link to one without it, and a device's link to the advertising, from the public one" {
    var recorder = Recorder{};
    var port = Port{};
    var layer = upLayer(&recorder, &port);
    // Before there is a private address: the public one.
    _ = bonds.keepLe(&layer, given_peer, &.{ .ltk = ltk, .key_size = 16, .authenticated = true, .secure = true, .given = true }, "given").?;
    _ = connections.connect(&layer, given_peer);
    settle(&layer, &recorder);
    try testing.expectEqual(hci.LE_ADDR_PUBLIC, recorder.lastOf(hci.HCI_OP_LE_CREATE_CONNECTION).?.params[12]);
    leLinked(&layer, 0x0040, hci.ROLE_CENTRAL, given_peer);
    settle(&layer, &recorder);
    try testing.expect(connections.sameAddress(public_own, connections.find(&layer, given_peer).?.own));
    event(&layer, hci.HCI_EV_DISCONNECTION_COMPLETE, &.{ 0, 0x40, 0x00, hci.HCI_ERR_REMOTE_USER_TERMINATED });

    // With one: the device given the identity linked from it.
    const first = firstAddress(&layer, &recorder);
    _ = connections.connect(&layer, given_peer);
    settle(&layer, &recorder);
    try testing.expectEqual(hci.LE_ADDR_RANDOM, recorder.lastOf(hci.HCI_OP_LE_CREATE_CONNECTION).?.params[12]);
    leLinked(&layer, 0x0041, hci.ROLE_CENTRAL, given_peer);
    settle(&layer, &recorder);
    const link = connections.find(&layer, given_peer).?;
    try testing.expect(connections.sameAddress(first, link.own));
    // A change while it is up: the link keeps the address it was made from.
    layer.now += privacy.ROTATE_MS;
    _hci.tick(&layer);
    settle(&layer, &recorder);
    try testing.expect(!std.mem.eql(u8, &first.bytes, &layer.privacy.address));
    try testing.expect(connections.sameAddress(first, link.own));

    // A bonded device not given it: from the public address.
    _ = bonds.keepLe(&layer, other_peer, &.{ .ltk = ltk, .key_size = 16, .authenticated = true, .secure = true }, "other").?;
    _ = connections.connect(&layer, other_peer);
    settle(&layer, &recorder);
    try testing.expectEqual(hci.LE_ADDR_PUBLIC, recorder.lastOf(hci.HCI_OP_LE_CREATE_CONNECTION).?.params[12]);
    leLinked(&layer, 0x0042, hci.ROLE_CENTRAL, other_peer);
    settle(&layer, &recorder);
    try testing.expect(connections.sameAddress(public_own, connections.find(&layer, other_peer).?.own));

    // A device at a private address its key made, its bond given the
    // identity: from the private address.
    const device_irk = [16]u8{ 0x9B, 0x7D, 0x39, 0x0A, 0xA6, 0x10, 0x10, 0x34, 0x05, 0xAD, 0xC8, 0x57, 0xA3, 0x34, 0x02, 0xEC };
    const identity = bluetooth.BTAddress{ .bytes = .{ 0x44, 0x10, 0xEF, 0x5E, 0x00, 0x00 }, .kind = bluetooth.BTADDR_LE_PUBLIC };
    const private = bluetooth.BTAddress{ .bytes = .{ 0xAA, 0xFB, 0x0D, 0x94, 0x81, 0x70 }, .kind = bluetooth.BTADDR_LE_RANDOM };
    _ = bonds.keepLe(&layer, identity, &.{ .ltk = ltk, .key_size = 16, .authenticated = true, .secure = true, .irk = device_irk, .given = true }, "sensor").?;
    try testing.expect(privacy.towards(&layer, private));
    _ = connections.connect(&layer, private);
    settle(&layer, &recorder);
    try testing.expectEqual(hci.LE_ADDR_RANDOM, recorder.lastOf(hci.HCI_OP_LE_CREATE_CONNECTION).?.params[12]);
    leLinked(&layer, 0x0043, hci.ROLE_CENTRAL, private);
    featuresRead(&layer, 0x0043);
    settle(&layer, &recorder);
    const now_private = bluetooth.BTAddress{ .bytes = layer.privacy.address, .kind = bluetooth.BTADDR_LE_RANDOM };
    try testing.expect(connections.sameAddress(now_private, connections.find(&layer, private).?.own));
    // Its record: the address it was made from, the device's identity,
    // bonded.
    const record = recordOf(&layer, private);
    try testing.expect(connections.sameAddress(now_private, record.own_address));
    try testing.expect(connections.sameAddress(identity, record.identity));
    try testing.expect(connections.sameAddress(private, record.address));
    try testing.expect(record.flags & bluetooth.BTLF_BONDED != 0);
    // One made from the public address, to a device at its own: the
    // public address, no identity of its own.
    featuresRead(&layer, 0x0042);
    settle(&layer, &recorder);
    const plain = recordOf(&layer, other_peer);
    try testing.expect(connections.sameAddress(public_own, plain.own_address));
    try testing.expectEqual(bluetooth.BTADDR_BREDR, plain.identity.kind);
    try testing.expect(plain.flags & bluetooth.BTLF_BONDED != 0);

    // A device's link to the advertising: the public address.
    try testing.expectEqual(@as(i32, 0), local.setVisible(&layer, bluetooth.BT_VISIBLE_ALWAYS));
    settle(&layer, &recorder);
    const visitor = bluetooth.BTAddress{ .bytes = .{ 0x45, 0x10, 0xEF, 0x5E, 0x00, 0x00 }, .kind = bluetooth.BTADDR_LE_PUBLIC };
    leLinked(&layer, 0x0044, hci.ROLE_PERIPHERAL, visitor);
    settle(&layer, &recorder);
    try testing.expect(connections.sameAddress(public_own, connections.find(&layer, visitor).?.own));
}

test "none without crypto.library, the identity, or the command: the public address everywhere" {
    for (0..3) |lacking| {
        var recorder = Recorder{};
        var port = Port{};
        var layer = upLayer(&recorder, &port);
        switch (lacking) {
            0 => layer.crypto = null,
            1 => layer.has_identity = false,
            else => {
                layer.commands = @splat(0xFF);
                layer.commands[hci.CMDBIT_LE_SET_RANDOM_ADDRESS / 8] &= ~(@as(u8, 1) << @intCast(hci.CMDBIT_LE_SET_RANDOM_ADDRESS % 8));
                layer.have_commands = true;
            },
        }
        try testing.expect(!privacy.can(&layer));
        privacy.reset(&layer);
        _hci.tick(&layer);
        settle(&layer, &recorder);
        try testing.expectEqual(@as(usize, 0), recorder.countOf(0, hci.HCI_OP_LE_SET_RANDOM_ADDRESS));
        try testing.expect(!layer.privacy.has);
        try testing.expectEqual(@as(i32, 0), discovery.start(&layer, 6000));
        settle(&layer, &recorder);
        try testing.expectEqual(hci.LE_ADDR_PUBLIC, recorder.lastOf(hci.HCI_OP_LE_SET_SCAN_PARAMETERS).?.params[5]);
    }
}
