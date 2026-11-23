// SPDX-License-Identifier: MIT
//! Host tests of the attribute protocol over LE, the test playing the
//! device and the controller: the server's services, characteristics and
//! name, each answer cut to the MTU, its configuration kept and its
//! refusals; a block opened over a link made for it, the MTU exchanged
//! first; the services and a service's characteristics and descriptors
//! read in parts; a value read in parts, cut at the room's end; writes,
//! a Write Command, one too long and one refused; subscriptions two blocks
//! share, each value to both, an indication confirmed, one refused and
//! taken back, a close leaving the device told; procedures in their
//! order; a link down closing its blocks and answering its procedures; a
//! request not answered leaving the bearer dead; a link made for a block
//! ended two seconds after it closed. Blocks that wait: the background
//! scan on for them and off while a link is made or a discovery runs; a
//! device linked to when it advertises, at its address or at a private
//! one its bond's key made, the link made secure and found by the bond's
//! address; the block opened over the link and told so, a value before
//! its open its, waiting again when the link ends, what it subscribed to
//! written again at its next open; a link up taken at once; a controller
//! brought up again leaving it waiting, one gone closing it.

const std = @import("std");
const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const l2cap = bluetooth.l2cap;
const att = bluetooth.att;
const hcidev = sdk.devices.hci;
const _hci = @import("../hci/_hci.zig");
const Hci = _hci.Hci;
const acl = @import("../hci/acl.zig");
const connections = @import("../hci/connections.zig");
const bonds = @import("../hci/bonds.zig");
const discovery = @import("../hci/discovery.zig");
const _att = @import("../att/_att.zig");
const att_client = @import("../att/client.zig");
const Port = @import("_port.zig").Port;

const testing = std.testing;

/// A controller that keeps the commands and the frames it is sent - the
/// frames whole, put together from their packets - and what the task is
/// told of its GATT blocks.
const Recorder = struct {
    opcodes: [32]u16 = undefined,
    /// Each command's first two parameters, where it has them.
    firsts: [32][2]u8 = undefined,
    command_count: usize = 0,
    frames: [16]Frame = undefined,
    frame_count: usize = 0,
    told: [16]Told = undefined,
    told_count: usize = 0,

    const Frame = struct {
        handle: u16,
        cid: u16,
        length: usize,
        data: [acl.FRAME_MOST]u8,

        fn bytes(frame: *const Frame) []const u8 {
            return frame.data[0..frame.length];
        }
    };

    const Told = struct {
        kind: att_client.EventKind,
        client: u32,
        handle: u16,
        result: i32,
        length: usize,
        data: [32]u8,
    };

    fn send(context: *anyopaque, packet_type: u8, bytes: []const u8) bool {
        const recorder: *Recorder = @ptrCast(@alignCast(context));
        switch (packet_type) {
            hcidev.HCI_COMMAND_PKT => {
                const place = recorder.command_count % recorder.opcodes.len;
                recorder.opcodes[place] = _hci.le16(bytes[0..2]);
                recorder.firsts[place] = .{ if (bytes.len > 3) bytes[3] else 0, if (bytes.len > 4) bytes[4] else 0 };
                recorder.command_count += 1;
            },
            hcidev.HCI_ACLDATA_PKT => {
                const head = _hci.le16(bytes[0..2]);
                const data = bytes[hci.HCI_ACL_HDR..];
                if (head >> hci.ACL_BOUNDARY_SHIFT == hci.ACL_CONTINUING) {
                    const frame = &recorder.frames[(recorder.frame_count - 1) % recorder.frames.len];
                    @memcpy(frame.data[frame.length..][0..data.len], data);
                    frame.length += data.len;
                } else {
                    const frame = &recorder.frames[recorder.frame_count % recorder.frames.len];
                    frame.handle = head & hci.ACL_HANDLE_MASK;
                    frame.cid = _hci.le16(data[2..4]);
                    frame.length = data.len - l2cap.L2CAP_HDR;
                    @memcpy(frame.data[0..frame.length], data[l2cap.L2CAP_HDR..]);
                    recorder.frame_count += 1;
                }
            },
            else => unreachable,
        }
        return true;
    }

    fn gatt(context: *anyopaque, happened: *const att_client.Event) void {
        const recorder: *Recorder = @ptrCast(@alignCast(context));
        const kept = &recorder.told[recorder.told_count % recorder.told.len];
        recorder.told_count += 1;
        const length = @min(happened.data.len, kept.data.len);
        kept.* = .{ .kind = happened.kind, .client = happened.client.serial, .handle = happened.handle, .result = happened.result, .length = length, .data = undefined };
        @memcpy(kept.data[0..length], happened.data[0..length]);
    }

    fn lastCommand(recorder: *const Recorder) u16 {
        return recorder.opcodes[(recorder.command_count - 1) % recorder.opcodes.len];
    }

    const Sent = struct { opcode: u16, first: [2]u8 };

    /// The command sent `back` before the last.
    fn commandBack(recorder: *const Recorder, back: usize) Sent {
        const place = (recorder.command_count - 1 - back) % recorder.opcodes.len;
        return .{ .opcode = recorder.opcodes[place], .first = recorder.firsts[place] };
    }

    fn lastFrame(recorder: *const Recorder) *const Frame {
        return &recorder.frames[(recorder.frame_count - 1) % recorder.frames.len];
    }

    fn lastTold(recorder: *const Recorder, back: usize) *const Told {
        return &recorder.told[(recorder.told_count - 1 - back) % recorder.told.len];
    }
};

/// A layer up, BR/EDR and LE, taking every command, with buffers for
/// every frame the tests send.
fn upLayer(recorder: *Recorder) Hci {
    var layer = Hci{ .port = .{ .context = recorder, .send = Recorder.send, .gatt = Recorder.gatt } };
    layer.state = bluetooth.BTCS_UP;
    layer.features[0] = .{ 0xBF, 0xFE, 0xCF, 0xFE, 0xDB, 0xFF, 0x7B, 0x87 };
    layer.credits = 4;
    layer.now = 100_000;
    layer.acl_mtu = 1021;
    layer.acl_packets = 1000;
    layer.le_mtu = 251;
    layer.le_packets = 1000;
    layer.le_own = true;
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

/// A command's Command Complete, its status alone.
fn complete(layer: *Hci, opcode: u16, code: u8) void {
    event(layer, hci.HCI_EV_COMMAND_COMPLETE, &.{ 4, @truncate(opcode), @truncate(opcode >> 8), code });
}

/// The device at `address` heard advertising, as `event_type`.
fn advertised(layer: *Hci, address: bluetooth.BTAddress, event_type: u8) void {
    var params: [12]u8 = undefined;
    params[0] = hci.HCI_LE_EV_ADVERTISING_REPORT;
    params[1] = 1;
    params[2] = event_type;
    params[3] = if (address.kind == bluetooth.BTADDR_LE_RANDOM) hci.LE_ADDR_RANDOM else hci.LE_ADDR_PUBLIC;
    params[4..10].* = address.bytes;
    params[10] = 0;
    params[11] = 0xC8;
    event(layer, hci.HCI_EV_LE_META, &params);
}

/// The background scan just asked for - passive, each advertiser
/// reported once - and the controller's answers.
fn expectScan(layer: *Hci, recorder: *const Recorder) !void {
    const parameters = recorder.commandBack(1);
    try testing.expectEqual(hci.HCI_OP_LE_SET_SCAN_PARAMETERS, parameters.opcode);
    try testing.expectEqual(hci.LE_SCAN_PASSIVE, parameters.first[0]);
    const enable = recorder.commandBack(0);
    try testing.expectEqual(hci.HCI_OP_LE_SET_SCAN_ENABLE, enable.opcode);
    try testing.expectEqualSlices(u8, &.{ 1, 1 }, &enable.first);
    complete(layer, hci.HCI_OP_LE_SET_SCAN_PARAMETERS, 0);
    complete(layer, hci.HCI_OP_LE_SET_SCAN_ENABLE, 0);
    try testing.expect(layer.scan.on);
}

/// The scan turned off: the command `back` before the last.
fn expectScanOff(recorder: *const Recorder, back: usize) !void {
    const off = recorder.commandBack(back);
    try testing.expectEqual(hci.HCI_OP_LE_SET_SCAN_ENABLE, off.opcode);
    try testing.expectEqual(@as(u8, 0), off.first[0]);
}

/// The LE link to `address` up as `handle` - initiated by the library,
/// asked for already - and heard: its features read.
fn leUp(layer: *Hci, address: bluetooth.BTAddress, handle: u16) void {
    status(layer, hci.HCI_OP_LE_CREATE_CONNECTION, 0);
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
    status(layer, hci.HCI_OP_LE_READ_REMOTE_FEATURES, 0);
    var features: [12]u8 = @splat(0);
    features[0] = hci.HCI_LE_EV_READ_REMOTE_FEATURES_COMPLETE;
    features[2] = @truncate(handle);
    features[3] = @truncate(handle >> 8);
    event(layer, hci.HCI_EV_LE_META, &features);
}

/// An LE link to `address` made by ConnectBTDevice and up as `handle`.
fn linked(layer: *Hci, address: bluetooth.BTAddress, handle: u16) !void {
    const begun = connections.connect(layer, address);
    try testing.expect(begun == .waiting);
    leUp(layer, address, handle);
    try testing.expectEqual(@as(i32, 0), layer.waits[begun.waiting].result);
    connections.release(layer, begun.waiting);
}

/// A PDU of the device's on the link's attribute channel, in one packet.
fn attIn(layer: *Hci, pdu: []const u8) void {
    var packet: [hci.HCI_ACL_HDR + acl.FRAME_ROOM]u8 = undefined;
    const head = handle_used | hci.ACL_START << hci.ACL_BOUNDARY_SHIFT;
    const length = l2cap.L2CAP_HDR + pdu.len;
    put16(packet[0..2], head);
    put16(packet[2..4], @intCast(length));
    put16(packet[4..6], @intCast(pdu.len));
    put16(packet[6..8], l2cap.CID_ATT);
    @memcpy(packet[8..][0..pdu.len], pdu);
    _hci.received(layer, hcidev.HCI_ACLDATA_PKT, packet[0 .. hci.HCI_ACL_HDR + length]);
}

/// The frame the layer sent last: `pdu`, on the attribute channel.
fn expectAtt(recorder: *const Recorder, pdu: []const u8) !void {
    const frame = recorder.lastFrame();
    try testing.expectEqual(handle_used, frame.handle);
    try testing.expectEqual(l2cap.CID_ATT, frame.cid);
    try testing.expectEqualSlices(u8, pdu, frame.bytes());
}

fn put16(into: *[2]u8, value: u16) void {
    into[0] = @truncate(value);
    into[1] = @truncate(value >> 8);
}

/// A wait done, with `result`.
fn expectDone(layer: *const Hci, begun: connections.Begun, result: i32) !void {
    try testing.expect(begun == .waiting);
    try testing.expect(layer.waits[begun.waiting].done);
    try testing.expectEqual(result, layer.waits[begun.waiting].result);
}

/// A procedure's end read and its wait given back, as the task does: how
/// much of its room it filled.
fn answered(layer: *Hci, begun: connections.Begun) usize {
    const serial = layer.waits[begun.waiting].serial;
    const have = if (att_client.procedureOf(layer, serial)) |procedure| procedure.have else 0;
    att_client.release(layer, serial);
    connections.release(layer, begun.waiting);
    return have;
}

/// A block opened over the link that is up, its MTU exchanged as `mtu`
/// where it is not yet.
fn opened(layer: *Hci, recorder: *const Recorder, mtu: ?u16) !*att_client.Client {
    const begun = att_client.open(layer, sensor, &block_owner, false);
    try testing.expect(begun == .waiting);
    if (mtu) |theirs| {
        try expectAtt(recorder, &.{ 0x02, 0x05, 0x02 });
        var answer: [3]u8 = .{ att.ATT_EXCHANGE_MTU_RSP, 0, 0 };
        put16(answer[1..3], theirs);
        attIn(layer, &answer);
    }
    try expectDone(layer, begun, 0);
    const block = att_client.bySerial(layer, layer.waits[begun.waiting].serial).?;
    _ = answered(layer, begun);
    return block;
}

/// What the blocks' records name as their owner: the task's BTGatt.
var block_owner: u8 = 0;
var other_owner: u8 = 0;

/// The link's handle in every test.
const handle_used: u16 = 0x0040;
const sensor = bluetooth.BTAddress{ .bytes = .{ 0x03, 0x10, 0xEF, 0x5E, 0x00, 0xC0 }, .kind = bluetooth.BTADDR_LE_RANDOM };
const other_device = bluetooth.BTAddress{ .bytes = .{ 0x05, 0x10, 0xEF, 0x5E, 0x00, 0xC0 }, .kind = bluetooth.BTADDR_LE_RANDOM };
const name = "A machine with a long name";

test "the server: its services, characteristics and name, each answer cut to the MTU" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    @memcpy(layer.name[0..name.len], name);
    try linked(&layer, sensor, handle_used);
    // At the default MTU the name is cut, its rest read from where it was.
    attIn(&layer, &.{ 0x0A, 0x03, 0x00 });
    try expectAtt(&recorder, "\x0B" ++ name[0..22]);
    attIn(&layer, &.{ 0x0C, 0x03, 0x00, 22, 0x00 });
    try expectAtt(&recorder, "\x0D" ++ name[22..]);
    // The device's MTU: this machine's said, the smaller kept.
    attIn(&layer, &.{ 0x02, 0xF7, 0x00 });
    try expectAtt(&recorder, &.{ 0x03, 0x05, 0x02 });
    try testing.expectEqual(@as(u16, 247), connections.find(&layer, sensor).?.att.mtu);
    // The primary services; none past them; a group type not served.
    attIn(&layer, &.{ 0x10, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28 });
    try expectAtt(&recorder, &.{ 0x11, 6, 0x01, 0x00, 0x05, 0x00, 0x00, 0x18, 0x06, 0x00, 0x09, 0x00, 0x01, 0x18 });
    attIn(&layer, &.{ 0x10, 0x0A, 0x00, 0xFF, 0xFF, 0x00, 0x28 });
    try expectAtt(&recorder, &.{ 0x01, 0x10, 0x0A, 0x00, 0x0A });
    attIn(&layer, &.{ 0x10, 0x01, 0x00, 0xFF, 0xFF, 0x03, 0x28 });
    try expectAtt(&recorder, &.{ 0x01, 0x10, 0x01, 0x00, 0x10 });
    // GATT's service found by its UUID.
    attIn(&layer, &.{ 0x06, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28, 0x01, 0x18 });
    try expectAtt(&recorder, &.{ 0x07, 0x06, 0x00, 0x09, 0x00 });
    // The characteristics' declarations.
    attIn(&layer, &.{ 0x08, 0x01, 0x00, 0xFF, 0xFF, 0x03, 0x28 });
    try expectAtt(&recorder, &.{ 0x09, 7, 0x02, 0x00, 0x02, 0x03, 0x00, 0x00, 0x2A, 0x04, 0x00, 0x02, 0x05, 0x00, 0x01, 0x2A, 0x07, 0x00, 0x20, 0x08, 0x00, 0x05, 0x2A });
    // The name by its type, of 128 bits on the base.
    const by_type = [_]u8{ 0x08, 0x01, 0x00, 0xFF, 0xFF } ++ [_]u8{ 0xFB, 0x34, 0x9B, 0x5F, 0x80, 0x00, 0x00, 0x80, 0x00, 0x10, 0x00, 0x00, 0x00, 0x2A, 0x00, 0x00 };
    attIn(&layer, &by_type);
    try expectAtt(&recorder, &([_]u8{ 0x09, 2 + name.len, 0x03, 0x00 } ++ name.*));
    // Each attribute's type.
    attIn(&layer, &.{ 0x04, 0x07, 0x00, 0xFF, 0xFF });
    try expectAtt(&recorder, &.{ 0x05, 0x01, 0x07, 0x00, 0x03, 0x28, 0x08, 0x00, 0x05, 0x2A, 0x09, 0x00, 0x02, 0x29 });
    // Service Changed not read; its configuration written and read back.
    attIn(&layer, &.{ 0x0A, 0x08, 0x00 });
    try expectAtt(&recorder, &.{ 0x01, 0x0A, 0x08, 0x00, 0x02 });
    attIn(&layer, &.{ 0x12, 0x09, 0x00, 0x02, 0x00 });
    try expectAtt(&recorder, &.{0x13});
    attIn(&layer, &.{ 0x0A, 0x09, 0x00 });
    try expectAtt(&recorder, &.{ 0x0B, 0x02, 0x00 });
    // Writes not taken; handles not there; a range that is none.
    attIn(&layer, &.{ 0x12, 0x03, 0x00, 0x41 });
    try expectAtt(&recorder, &.{ 0x01, 0x12, 0x03, 0x00, 0x03 });
    attIn(&layer, &.{ 0x12, 0x09, 0x00, 0x01 });
    try expectAtt(&recorder, &.{ 0x01, 0x12, 0x09, 0x00, 0x0D });
    attIn(&layer, &.{ 0x0A, 0x14, 0x00 });
    try expectAtt(&recorder, &.{ 0x01, 0x0A, 0x14, 0x00, 0x01 });
    attIn(&layer, &.{ 0x04, 0x05, 0x00, 0x01, 0x00 });
    try expectAtt(&recorder, &.{ 0x01, 0x04, 0x05, 0x00, 0x01 });
    attIn(&layer, &.{ 0x0A, 0x03 });
    try expectAtt(&recorder, &.{ 0x01, 0x0A, 0x00, 0x00, 0x04 });
    // Commands never answered: a Write Command where none is taken, a
    // signed one, one not known.
    const frames = recorder.frame_count;
    attIn(&layer, &.{ 0x52, 0x03, 0x00, 0x41 });
    attIn(&layer, &.{ 0xD2, 0x03, 0x00, 0x41 });
    attIn(&layer, &.{ 0x7F, 0x00 });
    try testing.expectEqual(frames, recorder.frame_count);
    // A Write Command to the configuration taken.
    attIn(&layer, &.{ 0x52, 0x09, 0x00, 0x00, 0x00 });
    try testing.expectEqual(@as(u16, 0), connections.find(&layer, sensor).?.att.service_changed);
}

test "a block over a link made for it: the MTU exchanged first, the services and a service's characteristics read in parts" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    const opening = att_client.open(&layer, sensor, &block_owner, false);
    try testing.expect(opening == .waiting);
    try testing.expectEqual(hci.HCI_OP_LE_CREATE_CONNECTION, recorder.lastCommand());
    try testing.expect(connections.find(&layer, sensor).?.for_channels);
    leUp(&layer, sensor, handle_used);
    try expectAtt(&recorder, &.{ 0x02, 0x05, 0x02 });
    try testing.expect(!layer.waits[opening.waiting].done);
    attIn(&layer, &.{ 0x03, 0x40, 0x00 });
    try expectDone(&layer, opening, 0);
    try testing.expectEqual(@as(u16, 64), connections.find(&layer, sensor).?.att.mtu);
    const block = att_client.bySerial(&layer, layer.waits[opening.waiting].serial).?;
    try testing.expectEqual(att_client.ClientState.open, block.state);
    _ = answered(&layer, opening);

    // The services, in two answers - the second's of 128 bits, to the
    // last handle.
    var room: [256]u8 = undefined;
    const asking = att_client.services(&layer, sensor, &room);
    try expectAtt(&recorder, &.{ 0x10, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28 });
    attIn(&layer, &.{ 0x11, 6, 0x01, 0x00, 0x07, 0x00, 0x00, 0x18, 0x08, 0x00, 0x0B, 0x00, 0x0F, 0x18 });
    try expectAtt(&recorder, &.{ 0x10, 0x0C, 0x00, 0xFF, 0xFF, 0x00, 0x28 });
    attIn(&layer, &([_]u8{ 0x11, 20, 0x0C, 0x00, 0xFF, 0xFF } ++ vendor_le));
    try expectDone(&layer, asking, 0);
    try testing.expectEqual(@as(usize, 3 * @sizeOf(att_client.ServiceRecord)), answered(&layer, asking));
    const battery: *align(1) const att_client.ServiceRecord = @ptrCast(room[@sizeOf(att_client.ServiceRecord)..].ptr);
    try testing.expectEqual(@as(u16, 0x08), battery.start);
    try testing.expectEqual(@as(u16, 0x0B), battery.end);
    try testing.expectEqual(@as(u16, 0x180F), _att.short(battery.uuid));
    const vendor: *align(1) const att_client.ServiceRecord = @ptrCast(room[2 * @sizeOf(att_client.ServiceRecord) ..].ptr);
    try testing.expectEqual(@as(u16, 0xFFFF), vendor.end);
    try testing.expectEqualSlices(u8, &vendor_be, &vendor.uuid);

    // The battery service's characteristics: one declaration, the next
    // asked for past its value and not found, then its descriptor.
    const finding = att_client.characteristics(&layer, block, 0x08, 0x0B, &room);
    try expectAtt(&recorder, &.{ 0x08, 0x08, 0x00, 0x0B, 0x00, 0x03, 0x28 });
    attIn(&layer, &.{ 0x09, 7, 0x09, 0x00, 0x12, 0x0A, 0x00, 0x19, 0x2A });
    try expectAtt(&recorder, &.{ 0x08, 0x0B, 0x00, 0x0B, 0x00, 0x03, 0x28 });
    attIn(&layer, &.{ 0x01, 0x08, 0x0B, 0x00, 0x0A });
    try expectAtt(&recorder, &.{ 0x04, 0x0B, 0x00, 0x0B, 0x00 });
    attIn(&layer, &.{ 0x05, 0x01, 0x0B, 0x00, 0x02, 0x29 });
    try expectDone(&layer, finding, 0);
    const filled = answered(&layer, finding);
    try testing.expectEqual(att_client.CHARACTERISTICS_HEAD + @sizeOf(att_client.CharacteristicRecord) + @sizeOf(att_client.DescriptorRecord), filled);
    const count: *align(1) const u16 = @ptrCast(&room);
    try testing.expectEqual(@as(u16, 1), count.*);
    const level: *align(1) const att_client.CharacteristicRecord = @ptrCast(room[att_client.CHARACTERISTICS_HEAD..].ptr);
    try testing.expectEqual(@as(u16, 0x09), level.handle);
    try testing.expectEqual(@as(u16, 0x0A), level.value);
    try testing.expectEqual(@as(u16, 0x0B), level.end);
    try testing.expectEqual(@as(u8, 0x12), level.properties);
    try testing.expectEqual(@as(u16, 0), level.first_descriptor);
    try testing.expectEqual(@as(u16, 1), level.descriptor_count);
    try testing.expectEqual(@as(u16, 0x2A19), _att.short(level.uuid));
    const configuration: *align(1) const att_client.DescriptorRecord = @ptrCast(room[att_client.CHARACTERISTICS_HEAD + @sizeOf(att_client.CharacteristicRecord) ..].ptr);
    try testing.expectEqual(@as(u16, 0x0B), configuration.handle);
    try testing.expectEqual(att.GATT_CLIENT_CONFIGURATION, _att.short(configuration.uuid));

    // Two characteristics, the first's descriptors in two answers, the
    // last's none - its value the service's last handle, so that nothing
    // more is asked for.
    const two = att_client.characteristics(&layer, block, 0x01, 0x07, &room);
    try expectAtt(&recorder, &.{ 0x08, 0x01, 0x00, 0x07, 0x00, 0x03, 0x28 });
    attIn(&layer, &.{ 0x09, 7, 0x02, 0x00, 0x02, 0x03, 0x00, 0x00, 0x2A, 0x06, 0x00, 0x02, 0x07, 0x00, 0x01, 0x2A });
    try expectAtt(&recorder, &.{ 0x04, 0x04, 0x00, 0x05, 0x00 });
    attIn(&layer, &.{ 0x05, 0x01, 0x04, 0x00, 0x01, 0x29 });
    try expectAtt(&recorder, &.{ 0x04, 0x05, 0x00, 0x05, 0x00 });
    attIn(&layer, &.{ 0x05, 0x01, 0x05, 0x00, 0x04, 0x29 });
    try expectDone(&layer, two, 0);
    try testing.expectEqual(att_client.CHARACTERISTICS_HEAD + 2 * @sizeOf(att_client.CharacteristicRecord) + 2 * @sizeOf(att_client.DescriptorRecord), answered(&layer, two));
    const second: *align(1) const att_client.CharacteristicRecord = @ptrCast(room[att_client.CHARACTERISTICS_HEAD + @sizeOf(att_client.CharacteristicRecord) ..].ptr);
    try testing.expectEqual(@as(u16, 2), second.first_descriptor);
    try testing.expectEqual(@as(u16, 0), second.descriptor_count);
    try testing.expectEqual(@as(u16, 0x07), second.end);
}

test "a value read in parts, and cut at the room's end; a device that ends it by refusing the next part" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try linked(&layer, sensor, handle_used);
    // The device does not exchange MTUs: 23 it is.
    const opening = att_client.open(&layer, sensor, &block_owner, false);
    try expectAtt(&recorder, &.{ 0x02, 0x05, 0x02 });
    attIn(&layer, &.{ 0x01, 0x02, 0x00, 0x00, 0x06 });
    try expectDone(&layer, opening, 0);
    const block = att_client.bySerial(&layer, layer.waits[opening.waiting].serial).?;
    _ = answered(&layer, opening);
    const part: [22]u8 = @splat(0x41);
    var room: [60]u8 = undefined;
    const reading = att_client.read(&layer, block, 0x0010, &room);
    try expectAtt(&recorder, &.{ 0x0A, 0x10, 0x00 });
    attIn(&layer, &([_]u8{0x0B} ++ part));
    try expectAtt(&recorder, &.{ 0x0C, 0x10, 0x00, 22, 0x00 });
    attIn(&layer, &([_]u8{0x0D} ++ part));
    try expectAtt(&recorder, &.{ 0x0C, 0x10, 0x00, 44, 0x00 });
    attIn(&layer, &.{ 0x0D, 0x42, 0x43 });
    try expectDone(&layer, reading, 0);
    try testing.expectEqual(@as(usize, 46), answered(&layer, reading));
    try testing.expectEqualSlices(u8, &.{ 0x42, 0x43 }, room[44..46]);
    // A room of 30: the second part cut, nothing more asked.
    const short_room = att_client.read(&layer, block, 0x0010, room[0..30]);
    attIn(&layer, &([_]u8{0x0B} ++ part));
    attIn(&layer, &([_]u8{0x0D} ++ part));
    try expectDone(&layer, short_room, 0);
    try testing.expectEqual(@as(usize, 30), answered(&layer, short_room));
    // A value exactly a PDU long: its end the device's refusal.
    const exact = att_client.read(&layer, block, 0x0010, &room);
    attIn(&layer, &([_]u8{0x0B} ++ part));
    attIn(&layer, &.{ 0x01, 0x0C, 0x10, 0x00, 0x0B });
    try expectDone(&layer, exact, 0);
    try testing.expectEqual(@as(usize, 22), answered(&layer, exact));
    // A value it does not give.
    const refused = att_client.read(&layer, block, 0x0010, &room);
    attIn(&layer, &.{ 0x01, 0x0A, 0x10, 0x00, 0x0F });
    try expectDone(&layer, refused, bluetooth.BTERR_ATT - 0x0F);
    _ = answered(&layer, refused);
    // An answer to no request, and one to another, let go.
    attIn(&layer, &.{ 0x0B, 0x01 });
    const again = att_client.read(&layer, block, 0x0010, &room);
    attIn(&layer, &.{0x13});
    try testing.expect(!layer.waits[again.waiting].done);
    attIn(&layer, &.{ 0x0B, 0x07 });
    try expectDone(&layer, again, 0);
    try testing.expectEqual(@as(usize, 1), answered(&layer, again));
}

test "writes: a Write Request answered, a Write Command sent, one too long, one refused" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try linked(&layer, sensor, handle_used);
    const block = try opened(&layer, &recorder, 23);
    const writing = att_client.write(&layer, block, 0x0020, "on", false);
    try expectAtt(&recorder, &.{ 0x12, 0x20, 0x00, 'o', 'n' });
    try testing.expect(!layer.waits[writing.waiting].done);
    attIn(&layer, &.{0x13});
    try expectDone(&layer, writing, 0);
    _ = answered(&layer, writing);
    // Sent, and over at once.
    const command = att_client.write(&layer, block, 0x0021, "off", true);
    try expectAtt(&recorder, &.{ 0x52, 0x21, 0x00, 'o', 'f', 'f' });
    try expectDone(&layer, command, 0);
    _ = answered(&layer, command);
    // Past the MTU less 3; past any value.
    const long: [21]u8 = @splat(1);
    const too_long = att_client.write(&layer, block, 0x0020, &long, false);
    try expectDone(&layer, too_long, bluetooth.BTERR_TOOLONG);
    _ = answered(&layer, too_long);
    const longest: [att.ATT_VALUE_MOST + 1]u8 = @splat(1);
    try testing.expectEqual(connections.Begun{ .done = bluetooth.BTERR_TOOLONG }, att_client.write(&layer, block, 0x0020, &longest, false));
    // Refused: its reason, less BTERR_ATT.
    const refused = att_client.write(&layer, block, 0x0020, "on", false);
    attIn(&layer, &.{ 0x01, 0x12, 0x20, 0x00, 0x03 });
    try expectDone(&layer, refused, bluetooth.BTERR_ATT - 0x03);
    _ = answered(&layer, refused);
}

test "subscriptions two blocks share: each value to both, an indication confirmed, one refused and taken back, a close leaving the device told" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try linked(&layer, sensor, handle_used);
    const first = try opened(&layer, &recorder, 23);
    const second = try opened(&layer, &recorder, null);
    // The first notified, the second indicated: the configuration both.
    const notified = att_client.subscribe(&layer, first, 0x0A, 0x0B, false);
    try expectAtt(&recorder, &.{ 0x12, 0x0B, 0x00, 0x01, 0x00 });
    attIn(&layer, &.{0x13});
    try expectDone(&layer, notified, 0);
    _ = answered(&layer, notified);
    const indicated = att_client.subscribe(&layer, second, 0x0A, 0x0B, true);
    try expectAtt(&recorder, &.{ 0x12, 0x0B, 0x00, 0x03, 0x00 });
    attIn(&layer, &.{0x13});
    try expectDone(&layer, indicated, 0);
    _ = answered(&layer, indicated);
    // A value notified: to both.
    attIn(&layer, &.{ 0x1B, 0x0A, 0x00, 0x55 });
    try testing.expectEqual(@as(usize, 2), recorder.told_count);
    for (0..2) |back| {
        const told = recorder.lastTold(back);
        try testing.expectEqual(att_client.EventKind.value, told.kind);
        try testing.expectEqual(@as(u16, 0x0A), told.handle);
        try testing.expectEqualSlices(u8, &.{0x55}, told.data[0..told.length]);
    }
    // Indicated: confirmed, to both.
    attIn(&layer, &.{ 0x1D, 0x0A, 0x00, 0x56 });
    try expectAtt(&recorder, &.{0x1E});
    try testing.expectEqual(@as(usize, 4), recorder.told_count);
    // One nobody wants: let go.
    attIn(&layer, &.{ 0x1B, 0x20, 0x00, 0x01 });
    try testing.expectEqual(@as(usize, 4), recorder.told_count);
    // The first ends its: the configuration what the second wants.
    const ending = att_client.unsubscribe(&layer, first, 0x0A);
    try expectAtt(&recorder, &.{ 0x12, 0x0B, 0x00, 0x02, 0x00 });
    attIn(&layer, &.{0x13});
    try expectDone(&layer, ending, 0);
    _ = answered(&layer, ending);
    attIn(&layer, &.{ 0x1B, 0x0A, 0x00, 0x57 });
    try testing.expectEqual(@as(usize, 5), recorder.told_count);
    try testing.expectEqual(second.serial, recorder.lastTold(0).client);
    // Refused: the subscription taken back.
    const refused = att_client.subscribe(&layer, first, 0x0C, 0x0D, false);
    attIn(&layer, &.{ 0x01, 0x12, 0x0D, 0x00, 0x05 });
    try expectDone(&layer, refused, bluetooth.BTERR_ATT - 0x05);
    _ = answered(&layer, refused);
    attIn(&layer, &.{ 0x1B, 0x0C, 0x00, 0x01 });
    try testing.expectEqual(@as(usize, 5), recorder.told_count);
    // The second closed: the device told, no call waiting for it.
    att_client.close(&layer, second);
    try expectAtt(&recorder, &.{ 0x12, 0x0B, 0x00, 0x00, 0x00 });
    attIn(&layer, &.{0x13});
    try testing.expect(!att_client.uses(&layer, connections.find(&layer, sensor).?) or first.state == .open);
    for (&layer.att_procedures) |*procedure| try testing.expectEqual(att_client.Stage.free, procedure.stage);
}

test "procedures in their order; a link down closing its blocks and answering what waits" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try linked(&layer, sensor, handle_used);
    const block = try opened(&layer, &recorder, 23);
    var room: [64]u8 = undefined;
    const services = att_client.services(&layer, sensor, &room);
    const reading = att_client.read(&layer, block, 0x0003, &room);
    // The read waits for the services.
    try expectAtt(&recorder, &.{ 0x10, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28 });
    attIn(&layer, &.{ 0x01, 0x10, 0x01, 0x00, 0x0A });
    try expectDone(&layer, services, 0);
    try expectAtt(&recorder, &.{ 0x0A, 0x03, 0x00 });
    _ = answered(&layer, services);
    // Down before the device answers: the read answered why, the block
    // closed and told so.
    const writing = att_client.write(&layer, block, 0x0003, "x", false);
    event(&layer, hci.HCI_EV_DISCONNECTION_COMPLETE, &.{ 0, @truncate(handle_used), @truncate(handle_used >> 8), hci.HCI_ERR_CONNECTION_TIMEOUT });
    try expectDone(&layer, reading, hci.HCI_ERR_CONNECTION_TIMEOUT);
    try expectDone(&layer, writing, hci.HCI_ERR_CONNECTION_TIMEOUT);
    _ = answered(&layer, reading);
    _ = answered(&layer, writing);
    try testing.expectEqual(att_client.ClientState.closed, block.state);
    const told = recorder.lastTold(0);
    try testing.expectEqual(att_client.EventKind.closed, told.kind);
    try testing.expectEqual(@as(i32, hci.HCI_ERR_CONNECTION_TIMEOUT), told.result);
    // A closed block asks nothing; freed, it is gone.
    try testing.expectEqual(connections.Begun{ .done = bluetooth.BTERR_NOTCONNECTED }, att_client.read(&layer, block, 0x0003, &room));
    att_client.close(&layer, block);
    for (&layer.att_clients) |*one| try testing.expectEqual(att_client.ClientState.free, one.state);
    // Not over BR/EDR.
    const bredr = bluetooth.BTAddress{ .bytes = .{ 0x01, 0x10, 0xEF, 0x5E, 0x00, 0x00 } };
    try testing.expectEqual(connections.Begun{ .done = bluetooth.BTERR_UNSUPPORTED }, att_client.open(&layer, bredr, &block_owner, false));
}

test "a request not answered in its time: the bearer dead, its blocks closed, nothing more taken" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try linked(&layer, sensor, handle_used);
    const block = try opened(&layer, &recorder, 23);
    var room: [8]u8 = undefined;
    const reading = att_client.read(&layer, block, 0x0003, &room);
    layer.now += _att.TRANSACTION_MS - 1;
    _hci.tick(&layer);
    try testing.expect(!layer.waits[reading.waiting].done);
    layer.now += 1;
    try testing.expectEqual(layer.now, _hci.nextDeadline(&layer).?);
    _hci.tick(&layer);
    try expectDone(&layer, reading, bluetooth.BTERR_TIMEOUT);
    _ = answered(&layer, reading);
    try testing.expectEqual(att_client.ClientState.closed, block.state);
    try testing.expectEqual(@as(i32, bluetooth.BTERR_TIMEOUT), recorder.lastTold(0).result);
    // The device's server is asked nothing, its client answered nothing.
    const frames = recorder.frame_count;
    attIn(&layer, &.{ 0x0A, 0x03, 0x00 });
    try testing.expectEqual(frames, recorder.frame_count);
    try testing.expectEqual(connections.Begun{ .done = bluetooth.BTERR_TIMEOUT }, att_client.open(&layer, sensor, &block_owner, false));
    att_client.close(&layer, block);
}

test "a link made for a block ended two seconds after the block closed" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    const opening = att_client.open(&layer, sensor, &block_owner, false);
    leUp(&layer, sensor, handle_used);
    attIn(&layer, &.{ 0x03, 0x17, 0x00 });
    try expectDone(&layer, opening, 0);
    const block = att_client.bySerial(&layer, layer.waits[opening.waiting].serial).?;
    _ = answered(&layer, opening);
    att_client.close(&layer, block);
    const link = connections.find(&layer, sensor).?;
    try testing.expectEqual(layer.now + connections.IDLE_MS, link.idle_until.?);
    const commands = recorder.command_count;
    layer.now += connections.IDLE_MS;
    _hci.tick(&layer);
    try testing.expect(recorder.command_count > commands);
    try testing.expectEqual(hci.HCI_OP_DISCONNECT, recorder.lastCommand());
}

test "a block that waits: the scan on for it, its device linked to when it advertises so, the block opened and told so; the link down, waiting again, the scan on again; a value before the next open its, what it subscribed to written again; closed, the link ended in a while" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    // Answered at once, waiting; the scan on - passive, each advertiser
    // once.
    try testing.expectEqual(connections.Begun{ .done = 0 }, att_client.open(&layer, sensor, &block_owner, true));
    const block = att_client.byOwner(&layer, &block_owner).?;
    try testing.expectEqual(att_client.ClientState.waiting, block.state);
    try expectScan(&layer, &recorder);
    // Another device, and the sensor advertising so that it may not be
    // connected: nothing.
    const commands = recorder.command_count;
    advertised(&layer, other_device, hci.LE_ADV_IND);
    advertised(&layer, sensor, hci.LE_ADV_NONCONN_IND);
    try testing.expectEqual(commands, recorder.command_count);
    // The sensor connectable: the scan off, then the link initiated.
    advertised(&layer, sensor, hci.LE_ADV_IND);
    try testing.expectEqual(hci.HCI_OP_LE_CREATE_CONNECTION, recorder.lastCommand());
    try expectScanOff(&recorder, 1);
    try testing.expect(!layer.scan.on);
    complete(&layer, hci.HCI_OP_LE_SET_SCAN_ENABLE, 0);
    leUp(&layer, sensor, handle_used);
    // Taken by the link: opening, the MTU exchanged first.
    try testing.expectEqual(att_client.ClientState.opening, block.state);
    try expectAtt(&recorder, &.{ 0x02, 0x05, 0x02 });
    attIn(&layer, &.{ 0x03, 0x17, 0x00 });
    try testing.expectEqual(att_client.ClientState.open, block.state);
    try testing.expectEqual(att_client.EventKind.opened, recorder.lastTold(0).kind);
    try testing.expect(!layer.scan.on);
    // A value subscribed to.
    const subscribing = att_client.subscribe(&layer, block, 0x0C, 0x0D, false);
    try expectAtt(&recorder, &.{ 0x12, 0x0D, 0x00, 0x01, 0x00 });
    attIn(&layer, &.{0x13});
    try expectDone(&layer, subscribing, 0);
    _ = answered(&layer, subscribing);

    // Down: waiting again, told why; the scan on again; its calls answer
    // that it is not connected.
    event(&layer, hci.HCI_EV_DISCONNECTION_COMPLETE, &.{ 0, @truncate(handle_used), @truncate(handle_used >> 8), hci.HCI_ERR_CONNECTION_TIMEOUT });
    try testing.expectEqual(att_client.ClientState.waiting, block.state);
    try testing.expectEqual(att_client.EventKind.waiting, recorder.lastTold(0).kind);
    try testing.expectEqual(@as(i32, hci.HCI_ERR_CONNECTION_TIMEOUT), recorder.lastTold(0).result);
    try expectScan(&layer, &recorder);
    var room: [8]u8 = undefined;
    try testing.expectEqual(connections.Begun{ .done = bluetooth.BTERR_NOTCONNECTED }, att_client.read(&layer, block, 0x0C, &room));

    // Back, advertising to this machine: its value notified while it is
    // opened is its; once open, its configuration written again before
    // the task is told.
    advertised(&layer, sensor, hci.LE_ADV_DIRECT_IND);
    try testing.expectEqual(hci.HCI_OP_LE_CREATE_CONNECTION, recorder.lastCommand());
    complete(&layer, hci.HCI_OP_LE_SET_SCAN_ENABLE, 0);
    leUp(&layer, sensor, handle_used);
    try expectAtt(&recorder, &.{ 0x02, 0x05, 0x02 });
    attIn(&layer, &.{ 0x1B, 0x0C, 0x00, 0x2A });
    try testing.expectEqual(att_client.EventKind.value, recorder.lastTold(0).kind);
    try testing.expectEqual(@as(u8, 0x2A), recorder.lastTold(0).data[0]);
    attIn(&layer, &.{ 0x03, 0x17, 0x00 });
    try expectAtt(&recorder, &.{ 0x12, 0x0D, 0x00, 0x01, 0x00 });
    try testing.expectEqual(att_client.EventKind.opened, recorder.lastTold(0).kind);
    attIn(&layer, &.{0x13});

    // Closed: the device told, and the link - made for it - ended in a
    // while; the scan stays off.
    att_client.close(&layer, block);
    try expectAtt(&recorder, &.{ 0x12, 0x0D, 0x00, 0x00, 0x00 });
    attIn(&layer, &.{0x13});
    try testing.expectEqual(layer.now + connections.IDLE_MS, connections.find(&layer, sensor).?.idle_until.?);
    try testing.expect(!layer.scan.on);
    for (&layer.att_procedures) |*procedure| try testing.expectEqual(att_client.Stage.free, procedure.stage);
}

test "a block that waits for a bonded device: a discovery turns the scan off and on again; its private address resolved by the bond's key, the link made secure and found by the bond's address; a link up taken at once; the controller brought up again leaving it waiting, gone closing it" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    var ours = Port{};
    layer.crypto = ours.of().*;
    // A bond with an identity resolving key, and an address it made: the
    // hash of the random part 0x708194 (its top bits 01), then that part.
    const irk = [16]u8{ 0x9B, 0x7D, 0x39, 0x0A, 0xA6, 0x10, 0x10, 0x34, 0x05, 0xAD, 0xC8, 0x57, 0xA3, 0x34, 0x02, 0xEC };
    const identity = bluetooth.BTAddress{ .bytes = .{ 0x44, 0x10, 0xEF, 0x5E, 0x00, 0x00 }, .kind = bluetooth.BTADDR_LE_PUBLIC };
    const private = bluetooth.BTAddress{ .bytes = .{ 0xAA, 0xFB, 0x0D, 0x94, 0x81, 0x70 }, .kind = bluetooth.BTADDR_LE_RANDOM };
    const ltk = [16]u8{ 0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF };
    _ = bonds.keepLe(&layer, identity, &.{ .ltk = ltk, .key_size = 16, .authenticated = true, .secure = true, .irk = irk }, "Keyboard").?;
    try testing.expectEqual(connections.Begun{ .done = 0 }, att_client.open(&layer, identity, &block_owner, true));
    const block = att_client.byOwner(&layer, &block_owner).?;
    try expectScan(&layer, &recorder);

    // A discovery: the scan off before the discovery's own; on again
    // once the discovery is over.
    try testing.expectEqual(@as(i32, 0), discovery.start(&layer, 0));
    try expectScanOff(&recorder, 2);
    try testing.expectEqual(hci.LE_SCAN_ACTIVE, recorder.commandBack(1).first[0]);
    complete(&layer, hci.HCI_OP_LE_SET_SCAN_ENABLE, 0);
    complete(&layer, hci.HCI_OP_LE_SET_SCAN_PARAMETERS, 0);
    complete(&layer, hci.HCI_OP_LE_SET_SCAN_ENABLE, 0);
    try testing.expect(!layer.scan.on);
    discovery.stop(&layer);
    complete(&layer, hci.HCI_OP_LE_SET_SCAN_ENABLE, 0);
    try expectScan(&layer, &recorder);

    // Heard at a private address the bond's key made: the link initiated
    // to it, and found by the bond's address too.
    advertised(&layer, private, hci.LE_ADV_IND);
    try testing.expectEqual(hci.HCI_OP_LE_CREATE_CONNECTION, recorder.lastCommand());
    complete(&layer, hci.HCI_OP_LE_SET_SCAN_ENABLE, 0);
    const link = connections.find(&layer, identity).?;
    try testing.expectEqualSlices(u8, &private.bytes, &link.address.bytes);
    try testing.expectEqualSlices(u8, &identity.bytes, &link.identity.?.bytes);
    // Up, and encrypted with the bond's key before the block is opened.
    leUp(&layer, private, handle_used);
    try testing.expectEqual(hci.HCI_OP_LE_ENABLE_ENCRYPTION, recorder.lastCommand());
    try testing.expectEqual(att_client.ClientState.waiting, block.state);
    try testing.expect(!layer.scan.on);
    status(&layer, hci.HCI_OP_LE_ENABLE_ENCRYPTION, 0);
    event(&layer, hci.HCI_EV_ENCRYPTION_CHANGE, &.{ 0, @truncate(handle_used), @truncate(handle_used >> 8), 1 });
    try testing.expectEqual(att_client.ClientState.opening, block.state);
    try expectAtt(&recorder, &.{ 0x02, 0x05, 0x02 });
    attIn(&layer, &.{ 0x03, 0x17, 0x00 });
    try testing.expectEqual(att_client.ClientState.open, block.state);
    try testing.expectEqual(att_client.EventKind.opened, recorder.lastTold(0).kind);

    // A second block that waits, the link up: open before the call
    // returns.
    try testing.expectEqual(connections.Begun{ .done = 0 }, att_client.open(&layer, identity, &other_owner, true));
    const second = att_client.byOwner(&layer, &other_owner).?;
    try testing.expectEqual(att_client.ClientState.open, second.state);
    try testing.expectEqual(second.serial, recorder.lastTold(0).client);
    att_client.close(&layer, second);

    // The controller brought up again: waiting, told so. Gone: closed.
    connections.reset(&layer, hci.HCI_ERR_HARDWARE_FAILURE);
    try testing.expectEqual(att_client.ClientState.waiting, block.state);
    try testing.expectEqual(att_client.EventKind.waiting, recorder.lastTold(0).kind);
    att_client.reset(&layer, bluetooth.BTERR_DETACHED);
    try testing.expectEqual(att_client.ClientState.closed, block.state);
    try testing.expectEqual(att_client.EventKind.closed, recorder.lastTold(0).kind);
    try testing.expectEqual(bluetooth.BTERR_DETACHED, recorder.lastTold(0).result);
    att_client.close(&layer, block);
}

/// A UUID of 128 bits, as written and as a PDU carries it.
const vendor_be = [16]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
const vendor_le = reversed(vendor_be);

fn reversed(comptime bytes: [16]u8) [16]u8 {
    var out: [16]u8 = undefined;
    for (0..16) |index| out[index] = bytes[15 - index];
    return out;
}
