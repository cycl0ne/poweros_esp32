// SPDX-License-Identifier: MIT
//! Host tests of a controller's links, against a controller the test
//! answers by hand: a page by what the discovery heard, LE's initiating,
//! a page not answered, initiating taken back at its time, a second link
//! of a kind while one is made; a device's page taken on, a link for
//! sound refused; a name asked for over the link; the ACL data - a frame
//! put together from its packets, one cut into packets as long as the
//! controller takes, the buffers counted and given back; the signalling
//! channels' answers, an LE peripheral's parameters taken or refused, the
//! attribute protocol's and the security manager's refusals; a link
//! ended, one being made taken back, the power going off, a hardware
//! error; what happened to each noted for the log.

const std = @import("std");
const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const l2cap = bluetooth.l2cap;
const hcidev = sdk.devices.hci;
const _hci = @import("../hci/_hci.zig");
const Hci = _hci.Hci;
const acl = @import("../hci/acl.zig");
const connections = @import("../hci/connections.zig");
const devices = @import("../hci/devices.zig");
const local = @import("../hci/local.zig");

const testing = std.testing;

/// A controller that keeps the commands and the ACL packets it is sent;
/// the test answers them.
const Recorder = struct {
    commands: [48]Command = undefined,
    command_count: usize = 0,
    packets: [16]Packet = undefined,
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
        boundary: u16,
        length: usize,
        data: [acl.PACKET_MOST]u8,

        fn bytes(packet: *const Packet) []const u8 {
            return packet.data[0..packet.length];
        }
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
                const packet = &recorder.packets[recorder.packet_count];
                const head = _hci.le16(bytes[0..2]);
                packet.handle = head & hci.ACL_HANDLE_MASK;
                packet.boundary = head >> hci.ACL_BOUNDARY_SHIFT;
                packet.length = _hci.le16(bytes[2..4]);
                @memcpy(packet.data[0..packet.length], bytes[hci.HCI_ACL_HDR..]);
                recorder.packet_count += 1;
            },
            else => unreachable,
        }
        return true;
    }

    fn last(recorder: *const Recorder) *const Command {
        return &recorder.commands[recorder.command_count - 1];
    }

    fn lastPacket(recorder: *const Recorder) *const Packet {
        return &recorder.packets[recorder.packet_count - 1];
    }
};

/// A layer up, BR/EDR and LE, taking every command; BR/EDR's buffers six
/// of 1021 bytes, LE's own eight of 251.
fn upLayer(recorder: *Recorder) Hci {
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

fn connectionComplete(layer: *Hci, code: u8, handle: u16, address: [6]u8) void {
    var params: [11]u8 = undefined;
    params[0] = code;
    params[1] = @truncate(handle);
    params[2] = @truncate(handle >> 8);
    params[3..9].* = address;
    params[9] = hci.LINK_ACL;
    params[10] = 0;
    event(layer, hci.HCI_EV_CONNECTION_COMPLETE, &params);
}

fn leConnectionComplete(layer: *Hci, code: u8, handle: u16, role: u8, address: bluetooth.BTAddress) void {
    var params: [19]u8 = @splat(0);
    params[0] = hci.HCI_LE_EV_CONNECTION_COMPLETE;
    params[1] = code;
    params[2] = @truncate(handle);
    params[3] = @truncate(handle >> 8);
    params[4] = role;
    params[5] = if (address.kind == bluetooth.BTADDR_LE_RANDOM) hci.LE_ADDR_RANDOM else hci.LE_ADDR_PUBLIC;
    params[6..12].* = address.bytes;
    params[12] = 0x18; // every 30 ms
    params[16] = 0x2A; // lost after 420 ms
    event(layer, hci.HCI_EV_LE_META, &params);
}

fn disconnectionComplete(layer: *Hci, handle: u16, reason: u8) void {
    event(layer, hci.HCI_EV_DISCONNECTION_COMPLETE, &.{ 0, @truncate(handle), @truncate(handle >> 8), reason });
}

/// An ACL packet of the link, its boundary flag and data.
fn packetIn(layer: *Hci, handle: u16, boundary: u16, data: []const u8) void {
    var packet: [hci.HCI_ACL_HDR + acl.FRAME_ROOM]u8 = undefined;
    const head = handle | boundary << hci.ACL_BOUNDARY_SHIFT;
    packet[0] = @truncate(head);
    packet[1] = @truncate(head >> 8);
    packet[2] = @truncate(data.len);
    packet[3] = @truncate(data.len >> 8);
    @memcpy(packet[hci.HCI_ACL_HDR..][0..data.len], data);
    _hci.received(layer, hcidev.HCI_ACLDATA_PKT, packet[0 .. hci.HCI_ACL_HDR + data.len]);
}

/// A whole frame of the link on channel `cid`, in one packet.
fn frameIn(layer: *Hci, handle: u16, cid: u16, payload: []const u8) void {
    var frame: [acl.FRAME_ROOM]u8 = undefined;
    frame[0] = @truncate(payload.len);
    frame[1] = @truncate(payload.len >> 8);
    frame[2] = @truncate(cid);
    frame[3] = @truncate(cid >> 8);
    @memcpy(frame[l2cap.L2CAP_HDR..][0..payload.len], payload);
    packetIn(layer, handle, hci.ACL_START, frame[0 .. l2cap.L2CAP_HDR + payload.len]);
}

/// The frame the link was sent last, as one packet: its channel and
/// payload checked.
fn expectFrame(recorder: *const Recorder, handle: u16, cid: u16, payload: []const u8) !void {
    const packet = recorder.lastPacket();
    try testing.expectEqual(handle, packet.handle);
    try testing.expectEqual(@as(usize, l2cap.L2CAP_HDR + payload.len), packet.length);
    try testing.expectEqual(@as(u16, @intCast(payload.len)), _hci.le16(packet.data[0..2]));
    try testing.expectEqual(cid, _hci.le16(packet.data[2..4]));
    try testing.expectEqualSlices(u8, payload, packet.bytes()[l2cap.L2CAP_HDR..]);
}

/// A BR/EDR link to `address` made by the library and up as `handle`, the
/// commands it took answered.
fn linked(layer: *Hci, recorder: *Recorder, address: bluetooth.BTAddress, handle: u16) !void {
    const begun = connections.connect(layer, address);
    try testing.expect(begun == .waiting);
    status(layer, hci.HCI_OP_CREATE_CONNECTION, 0);
    connectionComplete(layer, 0, handle, address.bytes);
    try testing.expect(layer.waits[begun.waiting].done);
    try testing.expectEqual(@as(i32, 0), layer.waits[begun.waiting].result);
    connections.release(layer, begun.waiting);
    if (recorder.last().opcode == hci.HCI_OP_REMOTE_NAME_REQUEST) status(layer, hci.HCI_OP_REMOTE_NAME_REQUEST, 0);
}

/// LE Read Remote Features Complete for `handle`, with `code`.
fn leFeaturesComplete(layer: *Hci, code: u8, handle: u16) void {
    var params: [12]u8 = @splat(0);
    params[0] = hci.HCI_LE_EV_READ_REMOTE_FEATURES_COMPLETE;
    params[1] = code;
    params[2] = @truncate(handle);
    params[3] = @truncate(handle >> 8);
    params[4] = 0x21; // encryption, extended reject indication
    event(layer, hci.HCI_EV_LE_META, &params);
}

/// An LE link to `address` made by the library and up as `handle`, the
/// device's features read over it.
fn leLinked(layer: *Hci, address: bluetooth.BTAddress, handle: u16) !void {
    const begun = connections.connect(layer, address);
    try testing.expect(begun == .waiting);
    status(layer, hci.HCI_OP_LE_CREATE_CONNECTION, 0);
    leConnectionComplete(layer, 0, handle, hci.ROLE_CENTRAL, address);
    status(layer, hci.HCI_OP_LE_READ_REMOTE_FEATURES, 0);
    leFeaturesComplete(layer, 0, handle);
    try testing.expectEqual(@as(i32, 0), layer.waits[begun.waiting].result);
    connections.release(layer, begun.waiting);
}

const peer = bluetooth.BTAddress{ .bytes = .{ 0x01, 0x10, 0xEF, 0x5E, 0x00, 0x00 } };
const caller = bluetooth.BTAddress{ .bytes = .{ 0x02, 0x10, 0xEF, 0x5E, 0x00, 0x00 } };
const sensor = bluetooth.BTAddress{ .bytes = .{ 0x03, 0x10, 0xEF, 0x5E, 0x00, 0xC0 }, .kind = bluetooth.BTADDR_LE_RANDOM };

test "a page by what the discovery heard: the link up, its name asked for over it" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    const device = devices.heard(&layer, peer.bytes, bluetooth.BTADDR_BREDR, -50).?;
    device.flags |= bluetooth.BTDF_BREDR;
    device.page_scan_repetition = hci.PAGE_SCAN_R1;
    device.clock_offset = 0x1234;
    device.class_of_device = 0x0C0104;

    const begun = connections.connect(&layer, peer);
    try testing.expect(begun == .waiting);
    const page = recorder.last();
    try testing.expectEqual(hci.HCI_OP_CREATE_CONNECTION, page.opcode);
    // The address, every ACL packet type, R1 and its clock offset, valid;
    // a role switch allowed.
    try testing.expectEqualSlices(u8, &(peer.bytes ++ [_]u8{ 0x18, 0xCC, 0x01, 0x00, 0x34, 0x92, 0x01 }), page.bytes());
    // One page at a time.
    try testing.expectEqual(connections.Begun{ .done = bluetooth.BTERR_BUSY }, connections.connect(&layer, caller));
    status(&layer, hci.HCI_OP_CREATE_CONNECTION, 0);
    try testing.expect(!layer.waits[begun.waiting].done);
    try testing.expectEqual(@as(usize, 0), connections.count(&layer));

    connectionComplete(&layer, 0, 0x0042, peer.bytes);
    try testing.expect(layer.waits[begun.waiting].done);
    try testing.expectEqual(@as(i32, 0), layer.waits[begun.waiting].result);
    const link = connections.find(&layer, peer).?;
    try testing.expectEqual(connections.State.up, link.state);
    try testing.expectEqual(@as(u16, 0x0042), link.handle);
    try testing.expect(link.central and !link.incoming and !link.le);
    try testing.expectEqual(@as(u32, 0x0C0104), link.class_of_device);
    // Its name was not heard: asked for over the link.
    const asked = recorder.last();
    try testing.expectEqual(hci.HCI_OP_REMOTE_NAME_REQUEST, asked.opcode);
    try testing.expectEqualSlices(u8, &peer.bytes, asked.bytes()[0..6]);
    var name: [255]u8 = @splat(0);
    @memcpy(name[1..7], &peer.bytes);
    @memcpy(name[7..14], "poweros");
    event(&layer, hci.HCI_EV_REMOTE_NAME_REQUEST_COMPLETE, &name);
    try testing.expectEqualStrings("poweros", std.mem.sliceTo(&link.name, 0));
    // Up already: answered at once.
    try testing.expectEqual(connections.Begun{ .done = 0 }, connections.connect(&layer, peer));
    // A role change makes the device the central.
    event(&layer, hci.HCI_EV_ROLE_CHANGE, &([_]u8{0} ++ peer.bytes ++ [_]u8{hci.ROLE_PERIPHERAL}));
    try testing.expect(!link.central);
}

test "a page not answered, and LE's initiating taken back at its time" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    const paged = connections.connect(&layer, peer);
    // No discovery heard it: R2, no clock offset.
    try testing.expectEqualSlices(u8, &(peer.bytes ++ [_]u8{ 0x18, 0xCC, 0x02, 0x00, 0x00, 0x00, 0x01 }), recorder.last().bytes());
    status(&layer, hci.HCI_OP_CREATE_CONNECTION, 0);
    connectionComplete(&layer, hci.HCI_ERR_PAGE_TIMEOUT, 0, peer.bytes);
    try testing.expect(layer.waits[paged.waiting].done);
    try testing.expectEqual(@as(i32, hci.HCI_ERR_PAGE_TIMEOUT), layer.waits[paged.waiting].result);
    try testing.expect(connections.find(&layer, peer) == null);
    connections.release(&layer, paged.waiting);

    const initiated = connections.connect(&layer, sensor);
    const initiate = recorder.last();
    try testing.expectEqual(hci.HCI_OP_LE_CREATE_CONNECTION, initiate.opcode);
    try testing.expectEqualSlices(u8, &([_]u8{ 0x60, 0x00, 0x60, 0x00, 0x00, hci.LE_ADDR_RANDOM } ++ sensor.bytes ++
        [_]u8{ hci.LE_ADDR_PUBLIC, 0x18, 0x00, 0x28, 0x00, 0x00, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x00, 0x00 }), initiate.bytes());
    status(&layer, hci.HCI_OP_LE_CREATE_CONNECTION, 0);
    try testing.expectEqual(@as(?u64, layer.now + connections.LE_CONNECT_TIMEOUT_MS), _hci.nextDeadline(&layer));
    layer.now += connections.LE_CONNECT_TIMEOUT_MS;
    _hci.tick(&layer);
    try testing.expectEqual(hci.HCI_OP_LE_CREATE_CONNECTION_CANCEL, recorder.last().opcode);
    complete(&layer, hci.HCI_OP_LE_CREATE_CONNECTION_CANCEL, &.{0});
    // Taken back: the controller answers so, with no address.
    leConnectionComplete(&layer, hci.HCI_ERR_UNKNOWN_CONNECTION, 0, 0, .{});
    try testing.expectEqual(@as(i32, bluetooth.BTERR_TIMEOUT), layer.waits[initiated.waiting].result);
    try testing.expect(connections.find(&layer, sensor) == null);
}

test "a page refused, and a controller that cannot page or is off" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    const paged = connections.connect(&layer, peer);
    status(&layer, hci.HCI_OP_CREATE_CONNECTION, hci.HCI_ERR_COMMAND_DISALLOWED);
    try testing.expectEqual(@as(i32, hci.HCI_ERR_COMMAND_DISALLOWED), layer.waits[paged.waiting].result);
    try testing.expect(connections.find(&layer, peer) == null);

    layer.le_packets = 0;
    try testing.expectEqual(connections.Begun{ .done = bluetooth.BTERR_UNSUPPORTED }, connections.connect(&layer, sensor));
    layer.powered = false;
    try testing.expectEqual(connections.Begun{ .done = bluetooth.BTERR_OFF }, connections.connect(&layer, peer));
    layer.state = bluetooth.BTCS_STARTING;
    try testing.expectEqual(connections.Begun{ .done = bluetooth.BTERR_NOTUP }, connections.connect(&layer, peer));
    try testing.expectEqual(connections.Begun{ .done = bluetooth.BTERR_NOTUP }, connections.disconnect(&layer, peer));
}

test "a device's page taken on, the controller its peripheral; a link for sound refused" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    event(&layer, hci.HCI_EV_CONNECTION_REQUEST, &(caller.bytes ++ [_]u8{ 0x04, 0x01, 0x0C, hci.LINK_ACL }));
    const accept = recorder.last();
    try testing.expectEqual(hci.HCI_OP_ACCEPT_CONNECTION, accept.opcode);
    try testing.expectEqualSlices(u8, &(caller.bytes ++ [_]u8{hci.ROLE_PERIPHERAL}), accept.bytes());
    status(&layer, hci.HCI_OP_ACCEPT_CONNECTION, 0);
    connectionComplete(&layer, 0, 0x0005, caller.bytes);
    const link = connections.find(&layer, caller).?;
    try testing.expectEqual(connections.State.up, link.state);
    try testing.expect(link.incoming and !link.central);
    try testing.expectEqual(@as(u32, 0x0C0104), link.class_of_device);

    event(&layer, hci.HCI_EV_CONNECTION_REQUEST, &(peer.bytes ++ [_]u8{ 0x04, 0x04, 0x24, hci.LINK_ESCO }));
    const refusal = recorder.last();
    try testing.expectEqual(hci.HCI_OP_REJECT_CONNECTION, refusal.opcode);
    try testing.expectEqualSlices(u8, &(peer.bytes ++ [_]u8{hci.HCI_ERR_REJECTED_LIMITED_RESOURCES}), refusal.bytes());
    // Off, nobody is taken on.
    layer.powered = false;
    event(&layer, hci.HCI_EV_CONNECTION_REQUEST, &(peer.bytes ++ [_]u8{ 0x04, 0x01, 0x0C, hci.LINK_ACL }));
    try testing.expectEqual(hci.HCI_OP_REJECT_CONNECTION, recorder.last().opcode);
}

test "a frame put together from its packets; BR/EDR's signalling answered" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try linked(&layer, &recorder, peer, 0x0042);
    // Buffers for every answer: none is given back here.
    layer.acl_packets = 16;
    acl.buffersRead(&layer);
    const cid = l2cap.CID_SIGNALING;

    // Information Request for the extended features, in two packets.
    const frame = [_]u8{ 6, 0, 1, 0, l2cap.INFORMATION_REQUEST, 3, 2, 0, 0x02, 0x00 };
    packetIn(&layer, 0x0042, hci.ACL_START, frame[0..5]);
    try testing.expectEqual(@as(usize, 0), recorder.packet_count);
    packetIn(&layer, 0x0042, hci.ACL_CONTINUING, frame[5..]);
    try expectFrame(&recorder, 0x0042, cid, &.{ l2cap.INFORMATION_RESPONSE, 3, 8, 0, 0x02, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00 });
    try testing.expectEqual(hci.ACL_START, recorder.lastPacket().boundary);
    // The fixed channels: signalling's alone; the connectionless MTU not
    // supported.
    frameIn(&layer, 0x0042, cid, &.{ l2cap.INFORMATION_REQUEST, 4, 2, 0, 0x03, 0x00 });
    try expectFrame(&recorder, 0x0042, cid, &.{ l2cap.INFORMATION_RESPONSE, 4, 12, 0, 0x03, 0x00, 0x00, 0x00, 0x02, 0, 0, 0, 0, 0, 0, 0 });
    frameIn(&layer, 0x0042, cid, &.{ l2cap.INFORMATION_REQUEST, 5, 2, 0, 0x01, 0x00 });
    try expectFrame(&recorder, 0x0042, cid, &.{ l2cap.INFORMATION_RESPONSE, 5, 4, 0, 0x01, 0x00, 0x01, 0x00 });
    // An echo; a channel to a protocol there is not, and one that is not
    // there to end.
    frameIn(&layer, 0x0042, cid, &.{ l2cap.ECHO_REQUEST, 6, 3, 0, 'a', 'b', 'c' });
    try expectFrame(&recorder, 0x0042, cid, &.{ l2cap.ECHO_RESPONSE, 6, 3, 0, 'a', 'b', 'c' });
    frameIn(&layer, 0x0042, cid, &.{ l2cap.CONNECTION_REQUEST, 7, 4, 0, 0x03, 0x00, 0x40, 0x00 });
    try expectFrame(&recorder, 0x0042, cid, &.{ l2cap.CONNECTION_RESPONSE, 7, 8, 0, 0x00, 0x00, 0x40, 0x00, 0x02, 0x00, 0x00, 0x00 });
    frameIn(&layer, 0x0042, cid, &.{ l2cap.DISCONNECTION_REQUEST, 8, 4, 0, 0x41, 0x00, 0x40, 0x00 });
    try expectFrame(&recorder, 0x0042, cid, &.{ l2cap.COMMAND_REJECT, 8, 6, 0, 0x02, 0x00, 0x41, 0x00, 0x40, 0x00 });
    // A request not known, rejected; an answer to nothing asked, and a
    // command identified as 0, let go.
    frameIn(&layer, 0x0042, cid, &.{ 0x0C, 9, 0, 0 });
    try expectFrame(&recorder, 0x0042, cid, &.{ l2cap.COMMAND_REJECT, 9, 2, 0, 0x00, 0x00 });
    const before = recorder.packet_count;
    frameIn(&layer, 0x0042, cid, &.{ l2cap.INFORMATION_RESPONSE, 10, 4, 0, 0x02, 0x00, 0x01, 0x00 });
    frameIn(&layer, 0x0042, cid, &.{ l2cap.ECHO_REQUEST, 0, 0, 0 });
    // A packet that goes on a frame not begun; a channel that is not
    // there.
    packetIn(&layer, 0x0042, hci.ACL_CONTINUING, &.{ 1, 2, 3 });
    frameIn(&layer, 0x0042, 0x0040, &.{ 1, 2, 3 });
    try testing.expectEqual(before, recorder.packet_count);
    // Two commands in one frame: both answered.
    frameIn(&layer, 0x0042, cid, &.{ l2cap.ECHO_REQUEST, 11, 0, 0, l2cap.ECHO_REQUEST, 12, 1, 0, 'x' });
    try testing.expectEqual(before + 2, recorder.packet_count);
    try expectFrame(&recorder, 0x0042, cid, &.{ l2cap.ECHO_RESPONSE, 12, 1, 0, 'x' });
}

test "a frame cut into packets as long as the controller takes, sent within its buffers" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try linked(&layer, &recorder, peer, 0x0042);
    layer.acl_mtu = 8;
    var request: [24]u8 = undefined;
    request[0..4].* = .{ l2cap.ECHO_REQUEST, 1, 20, 0 };
    for (request[4..], 0..) |*byte, index| byte.* = @intCast(index);
    frameIn(&layer, 0x0042, l2cap.CID_SIGNALING, &request);
    // 28 bytes: 8, 8, 8 and 4, the first a frame's start.
    try testing.expectEqual(@as(usize, 4), recorder.packet_count);
    var whole: [28]u8 = undefined;
    var at: usize = 0;
    for (recorder.packets[0..4], 0..) |*packet, index| {
        try testing.expectEqual(@as(u16, if (index == 0) hci.ACL_START else hci.ACL_CONTINUING), packet.boundary);
        @memcpy(whole[at..][0..packet.length], packet.bytes());
        at += packet.length;
    }
    try testing.expectEqual(@as(usize, 28), at);
    try testing.expectEqualSlices(u8, request[4..], whole[8..]);
    try testing.expectEqual(@as(u16, 2), layer.acl_credits);
    try testing.expectEqual(@as(u16, 4), connections.find(&layer, peer).?.outstanding);

    // Two buffers left: a third and fourth frame go, a fifth waits for
    // Number Of Completed Packets.
    layer.acl_mtu = 1021;
    frameIn(&layer, 0x0042, l2cap.CID_SIGNALING, &.{ l2cap.ECHO_REQUEST, 2, 0, 0, l2cap.ECHO_REQUEST, 3, 0, 0, l2cap.ECHO_REQUEST, 4, 0, 0 });
    try testing.expectEqual(@as(usize, 6), recorder.packet_count);
    try testing.expectEqual(@as(u16, 0), layer.acl_credits);
    event(&layer, hci.HCI_EV_NUMBER_OF_COMPLETED_PACKETS, &.{ 1, 0x42, 0x00, 0x02, 0x00 });
    try testing.expectEqual(@as(usize, 7), recorder.packet_count);
    try expectFrame(&recorder, 0x0042, l2cap.CID_SIGNALING, &.{ l2cap.ECHO_RESPONSE, 4, 0, 0 });
    try testing.expectEqual(@as(u16, 1), layer.acl_credits);
    // Down: every buffer its packets held is free again.
    disconnectionComplete(&layer, 0x0042, hci.HCI_ERR_REMOTE_USER_TERMINATED);
    try testing.expectEqual(@as(u16, 6), layer.acl_credits);
    try testing.expectEqual(@as(usize, 0), connections.count(&layer));
    // A count for a link that is gone is let go.
    event(&layer, hci.HCI_EV_NUMBER_OF_COMPLETED_PACKETS, &.{ 1, 0x42, 0x00, 0x02, 0x00 });
    try testing.expectEqual(@as(u16, 6), layer.acl_credits);
}

test "LE: the peripheral's parameters taken within the bounds; a request the attribute server does not take and pairing refused" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try leLinked(&layer, sensor, 0x0040);
    const link = connections.find(&layer, sensor).?;
    try testing.expect(link.le and link.central);
    try testing.expectEqual(@as(u16, 0x18), link.interval);
    try testing.expectEqual(@as(u16, 0x2A), link.supervision);
    const cid = l2cap.CID_LE_SIGNALING;

    // 7.5 to 11.25 ms, no latency, a second: taken, and the controller
    // told.
    frameIn(&layer, 0x0040, cid, &.{ l2cap.CONNECTION_PARAMETER_UPDATE_REQUEST, 9, 8, 0, 6, 0, 9, 0, 0, 0, 100, 0 });
    try expectFrame(&recorder, 0x0040, cid, &.{ l2cap.CONNECTION_PARAMETER_UPDATE_RESPONSE, 9, 2, 0, 0, 0 });
    try testing.expectEqual(hci.ACL_START_NO_FLUSH, recorder.lastPacket().boundary);
    const update = recorder.last();
    try testing.expectEqual(hci.HCI_OP_LE_CONNECTION_UPDATE, update.opcode);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x00, 6, 0, 9, 0, 0, 0, 100, 0, 0, 0, 0, 0 }, update.bytes());
    status(&layer, hci.HCI_OP_LE_CONNECTION_UPDATE, 0);
    event(&layer, hci.HCI_EV_LE_META, &.{ hci.HCI_LE_EV_CONNECTION_UPDATE_COMPLETE, 0, 0x40, 0x00, 9, 0, 0, 0, 100, 0 });
    try testing.expectEqual(@as(u16, 9), link.interval);
    try testing.expectEqual(@as(u16, 100), link.supervision);
    // An interval too short is refused, nothing asked of the controller.
    const commands = recorder.command_count;
    frameIn(&layer, 0x0040, cid, &.{ l2cap.CONNECTION_PARAMETER_UPDATE_REQUEST, 10, 8, 0, 4, 0, 9, 0, 0, 0, 100, 0 });
    try expectFrame(&recorder, 0x0040, cid, &.{ l2cap.CONNECTION_PARAMETER_UPDATE_RESPONSE, 10, 2, 0, 1, 0 });
    try testing.expectEqual(commands, recorder.command_count);
    // A channel to a protocol there is not.
    frameIn(&layer, 0x0040, cid, &.{ l2cap.LE_CREDIT_CONNECTION_REQUEST, 11, 10, 0, 0x80, 0, 0x40, 0, 23, 0, 23, 0, 1, 0 });
    try expectFrame(&recorder, 0x0040, cid, &.{ l2cap.LE_CREDIT_CONNECTION_RESPONSE, 11, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02, 0x00 });

    // The device's controller asks: within the bounds, taken; else refused.
    event(&layer, hci.HCI_EV_LE_META, &.{ hci.HCI_LE_EV_REMOTE_PARAMETERS_REQUEST, 0x40, 0x00, 12, 0, 24, 0, 2, 0, 200, 0 });
    try testing.expectEqual(hci.HCI_OP_LE_REMOTE_PARAMETERS_REPLY, recorder.last().opcode);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x00, 12, 0, 24, 0, 2, 0, 200, 0, 0, 0, 0, 0 }, recorder.last().bytes());
    event(&layer, hci.HCI_EV_LE_META, &.{ hci.HCI_LE_EV_REMOTE_PARAMETERS_REQUEST, 0x40, 0x00, 12, 0, 24, 0, 2, 0, 10, 0 });
    try testing.expectEqual(hci.HCI_OP_LE_REMOTE_PARAMETERS_NEGATIVE_REPLY, recorder.last().opcode);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x00, hci.HCI_ERR_UNACCEPTABLE_PARAMETERS }, recorder.last().bytes());

    // A request the attribute server does not take: not supported; an
    // indication confirmed; a notification let go. A Pairing Request - the
    // central's to send - not supported, and a Security Request refused,
    // there being no agent.
    frameIn(&layer, 0x0040, l2cap.CID_ATT, &.{ 0x16, 0x03, 0x00, 0x00, 0x00, 0x01 });
    try expectFrame(&recorder, 0x0040, l2cap.CID_ATT, &.{ 0x01, 0x16, 0x00, 0x00, 0x06 });
    frameIn(&layer, 0x0040, l2cap.CID_ATT, &.{ 0x1D, 0x03, 0x00, 0x01 });
    try expectFrame(&recorder, 0x0040, l2cap.CID_ATT, &.{0x1E});
    const packets = recorder.packet_count;
    frameIn(&layer, 0x0040, l2cap.CID_ATT, &.{ 0x1B, 0x03, 0x00, 0x01 });
    try testing.expectEqual(packets, recorder.packet_count);
    frameIn(&layer, 0x0040, l2cap.CID_SMP, &.{ 0x01, 0x03, 0x00, 0x01, 0x10, 0x07, 0x07 });
    try expectFrame(&recorder, 0x0040, l2cap.CID_SMP, &.{ 0x05, 0x07 });
    frameIn(&layer, 0x0040, l2cap.CID_SMP, &.{ 0x0B, 0x05 });
    try expectFrame(&recorder, 0x0040, l2cap.CID_SMP, &.{ 0x05, 0x05 });
    // LE's packets take LE's buffers.
    try testing.expectEqual(@as(u16, 6), layer.acl_credits);
    try testing.expectEqual(@as(u16, 8 - 7), layer.le_credits);
}

test "an LE link made once the device has answered on it; one it never answers on not made" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    const begun = connections.connect(&layer, sensor);
    status(&layer, hci.HCI_OP_LE_CREATE_CONNECTION, 0);
    leConnectionComplete(&layer, 0, 0x0040, hci.ROLE_CENTRAL, sensor);
    // The controller has sent its request: the device asked for its
    // features, the call still waiting - and a second one with it.
    const asked = recorder.last();
    try testing.expectEqual(hci.HCI_OP_LE_READ_REMOTE_FEATURES, asked.opcode);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x00 }, asked.bytes());
    try testing.expect(!layer.waits[begun.waiting].done);
    const again = connections.connect(&layer, sensor);
    try testing.expect(again == .waiting);
    const link = connections.find(&layer, sensor).?;
    try testing.expect(!link.heard);
    try testing.expectEqual(@as(u8, 0), layer.note_count);
    status(&layer, hci.HCI_OP_LE_READ_REMOTE_FEATURES, 0);
    leFeaturesComplete(&layer, 0, 0x0040);
    try testing.expect(layer.waits[begun.waiting].done and layer.waits[again.waiting].done);
    try testing.expectEqual(@as(i32, 0), layer.waits[begun.waiting].result);
    try testing.expect(link.heard);
    try testing.expectEqual(@as(u8, 0x21), link.le_features[0]);
    try testing.expectEqual(connections.NoteKind.up, layer.notes[0].kind);
    connections.release(&layer, begun.waiting);
    connections.release(&layer, again.waiting);
    // Made: answered at once.
    try testing.expectEqual(connections.Begun{ .done = 0 }, connections.connect(&layer, sensor));

    // Never answered on: given up after six connection events, the call
    // answered with why, the link not made.
    const beacon = bluetooth.BTAddress{ .bytes = .{ 0x04, 0x10, 0xEF, 0x5E, 0x00, 0x00 }, .kind = bluetooth.BTADDR_LE_PUBLIC };
    const lost = connections.connect(&layer, beacon);
    status(&layer, hci.HCI_OP_LE_CREATE_CONNECTION, 0);
    leConnectionComplete(&layer, 0, 0x0041, hci.ROLE_CENTRAL, beacon);
    status(&layer, hci.HCI_OP_LE_READ_REMOTE_FEATURES, 0);
    // The procedure's own failure waits for the link's end.
    leFeaturesComplete(&layer, hci.HCI_ERR_FAILED_TO_ESTABLISH, 0x0041);
    try testing.expect(!layer.waits[lost.waiting].done);
    disconnectionComplete(&layer, 0x0041, hci.HCI_ERR_FAILED_TO_ESTABLISH);
    try testing.expect(layer.waits[lost.waiting].done);
    try testing.expectEqual(@as(i32, hci.HCI_ERR_FAILED_TO_ESTABLISH), layer.waits[lost.waiting].result);
    try testing.expect(connections.find(&layer, beacon) == null);
    const noted = layer.notes[layer.note_count - 1];
    try testing.expectEqual(connections.NoteKind.not_made, noted.kind);
    try testing.expectEqual(@as(i32, hci.HCI_ERR_FAILED_TO_ESTABLISH), noted.reason);
    connections.release(&layer, lost.waiting);

    // Ended before the device answered: its making taken back.
    const ended = connections.connect(&layer, beacon);
    status(&layer, hci.HCI_OP_LE_CREATE_CONNECTION, 0);
    leConnectionComplete(&layer, 0, 0x0042, hci.ROLE_CENTRAL, beacon);
    const gone = connections.disconnect(&layer, beacon);
    try testing.expectEqual(hci.HCI_OP_DISCONNECT, recorder.last().opcode);
    status(&layer, hci.HCI_OP_DISCONNECT, 0);
    // The device heard while the link is ended makes nothing of it.
    const notes = layer.note_count;
    status(&layer, hci.HCI_OP_LE_READ_REMOTE_FEATURES, 0);
    frameIn(&layer, 0x0042, l2cap.CID_ATT, &.{ 0x1B, 0x03, 0x00, 0x01 });
    leFeaturesComplete(&layer, 0, 0x0042);
    try testing.expect(!layer.waits[ended.waiting].done);
    try testing.expectEqual(notes, layer.note_count);
    try testing.expectEqual(@as(?u64, layer.now + 10_000), connections.find(&layer, beacon).?.deadline);
    disconnectionComplete(&layer, 0x0042, hci.HCI_ERR_LOCAL_HOST_TERMINATED);
    try testing.expectEqual(@as(i32, hci.HCI_ERR_LOCAL_HOST_TERMINATED), layer.waits[ended.waiting].result);
    try testing.expectEqual(@as(i32, 0), layer.waits[gone.waiting].result);
    try testing.expect(connections.find(&layer, beacon) == null);
}

test "an LE link made by a frame of the device's, a controller that refuses the question, and a device that does not answer it" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    // A frame of the device's before its features: it has answered.
    const framed = connections.connect(&layer, sensor);
    status(&layer, hci.HCI_OP_LE_CREATE_CONNECTION, 0);
    leConnectionComplete(&layer, 0, 0x0040, hci.ROLE_CENTRAL, sensor);
    status(&layer, hci.HCI_OP_LE_READ_REMOTE_FEATURES, 0);
    frameIn(&layer, 0x0040, l2cap.CID_LE_SIGNALING, &.{ l2cap.CONNECTION_PARAMETER_UPDATE_REQUEST, 9, 8, 0, 24, 0, 40, 0, 0, 0, 42, 0 });
    status(&layer, hci.HCI_OP_LE_CONNECTION_UPDATE, 0);
    try testing.expectEqual(@as(i32, 0), layer.waits[framed.waiting].result);
    try testing.expect(layer.waits[framed.waiting].done);
    connections.release(&layer, framed.waiting);
    // The features after it change nothing.
    leFeaturesComplete(&layer, 0, 0x0040);
    try testing.expectEqual(@as(u8, 1), layer.note_count);

    // The controller refuses LE Read Remote Features: made without them.
    const beacon = bluetooth.BTAddress{ .bytes = .{ 0x04, 0x10, 0xEF, 0x5E, 0x00, 0x00 }, .kind = bluetooth.BTADDR_LE_PUBLIC };
    const refused = connections.connect(&layer, beacon);
    status(&layer, hci.HCI_OP_LE_CREATE_CONNECTION, 0);
    leConnectionComplete(&layer, 0, 0x0041, hci.ROLE_CENTRAL, beacon);
    status(&layer, hci.HCI_OP_LE_READ_REMOTE_FEATURES, hci.HCI_ERR_COMMAND_DISALLOWED);
    try testing.expect(layer.waits[refused.waiting].done);
    try testing.expectEqual(@as(i32, 0), layer.waits[refused.waiting].result);
    connections.release(&layer, refused.waiting);

    // A device that does not answer the question in its time: made
    // without its features.
    const watch = bluetooth.BTAddress{ .bytes = .{ 0x05, 0x10, 0xEF, 0x5E, 0x00, 0x00 }, .kind = bluetooth.BTADDR_LE_PUBLIC };
    const quiet = connections.connect(&layer, watch);
    status(&layer, hci.HCI_OP_LE_CREATE_CONNECTION, 0);
    leConnectionComplete(&layer, 0, 0x0042, hci.ROLE_CENTRAL, watch);
    status(&layer, hci.HCI_OP_LE_READ_REMOTE_FEATURES, 0);
    try testing.expectEqual(@as(?u64, layer.now + connections.FEATURES_WAIT_MS), _hci.nextDeadline(&layer));
    layer.now += connections.FEATURES_WAIT_MS;
    _hci.tick(&layer);
    try testing.expect(layer.waits[quiet.waiting].done);
    try testing.expectEqual(@as(i32, 0), layer.waits[quiet.waiting].result);
    try testing.expect(connections.find(&layer, watch).?.heard);
}

test "the specification's bounds for an LE link's parameters" {
    try testing.expect(connections.validParameters(6, 3200, 0, 3200));
    try testing.expect(!connections.validParameters(5, 10, 0, 100));
    try testing.expect(!connections.validParameters(12, 10, 0, 100));
    try testing.expect(!connections.validParameters(6, 3201, 0, 3200));
    try testing.expect(!connections.validParameters(6, 10, 0, 9));
    try testing.expect(!connections.validParameters(6, 10, 500, 3200));
    // The time-out must outlast (1 + latency) of the longest intervals,
    // twice: 40 ms * 2 * 5 = 400 ms.
    try testing.expect(!connections.validParameters(32, 32, 4, 40));
    try testing.expect(connections.validParameters(32, 32, 4, 41));
}

test "a link ended; one being made taken back; the power going off ends them all" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try testing.expectEqual(connections.Begun{ .done = bluetooth.BTERR_NOTCONNECTED }, connections.disconnect(&layer, peer));
    try linked(&layer, &recorder, peer, 0x0042);
    const ended = connections.disconnect(&layer, peer);
    try testing.expectEqual(hci.HCI_OP_DISCONNECT, recorder.last().opcode);
    try testing.expectEqualSlices(u8, &.{ 0x42, 0x00, hci.HCI_ERR_REMOTE_USER_TERMINATED }, recorder.last().bytes());
    status(&layer, hci.HCI_OP_DISCONNECT, 0);
    try testing.expectEqual(connections.State.disconnecting, connections.find(&layer, peer).?.state);
    // Ending: listed until it is down, and not made again meanwhile.
    try testing.expectEqual(@as(usize, 1), connections.count(&layer));
    try testing.expectEqual(connections.Begun{ .done = bluetooth.BTERR_BUSY }, connections.connect(&layer, peer));
    disconnectionComplete(&layer, 0x0042, hci.HCI_ERR_LOCAL_HOST_TERMINATED);
    try testing.expect(layer.waits[ended.waiting].done);
    try testing.expectEqual(@as(i32, 0), layer.waits[ended.waiting].result);
    try testing.expect(connections.find(&layer, peer) == null);
    connections.release(&layer, ended.waiting);
    // Noted for the log: up, then down and why.
    try testing.expectEqual(@as(u8, 2), layer.note_count);
    try testing.expectEqual(connections.NoteKind.up, layer.notes[0].kind);
    try testing.expectEqual(@as(u16, 0x0042), layer.notes[0].handle);
    try testing.expectEqual(connections.NoteKind.down, layer.notes[1].kind);
    try testing.expectEqual(@as(i32, hci.HCI_ERR_LOCAL_HOST_TERMINATED), layer.notes[1].reason);
    layer.note_count = 0;

    // Taken back while it is being made: its caller is told.
    const made = connections.connect(&layer, peer);
    status(&layer, hci.HCI_OP_CREATE_CONNECTION, 0);
    const dropped = connections.disconnect(&layer, peer);
    try testing.expectEqual(hci.HCI_OP_CREATE_CONNECTION_CANCEL, recorder.last().opcode);
    try testing.expectEqualSlices(u8, &peer.bytes, recorder.last().bytes());
    complete(&layer, hci.HCI_OP_CREATE_CONNECTION_CANCEL, &([_]u8{0} ++ peer.bytes));
    connectionComplete(&layer, hci.HCI_ERR_UNKNOWN_CONNECTION, 0, peer.bytes);
    try testing.expectEqual(@as(i32, hci.HCI_ERR_LOCAL_HOST_TERMINATED), layer.waits[made.waiting].result);
    try testing.expectEqual(connections.NoteKind.not_made, layer.notes[0].kind);
    try testing.expectEqual(@as(i32, hci.HCI_ERR_LOCAL_HOST_TERMINATED), layer.notes[0].reason);
    try testing.expectEqual(@as(i32, 0), layer.waits[dropped.waiting].result);
    connections.release(&layer, made.waiting);
    connections.release(&layer, dropped.waiting);

    // The power off: every link ended, the device told so.
    try linked(&layer, &recorder, caller, 0x0043);
    try testing.expectEqual(@as(i32, 0), local.setPowered(&layer, false));
    var told = false;
    for (recorder.commands[0..recorder.command_count]) |*command| {
        if (command.opcode == hci.HCI_OP_DISCONNECT and command.bytes()[2] == hci.HCI_ERR_REMOTE_POWER_OFF) told = true;
    }
    try testing.expect(told);
}

test "a link that is not answered as ended is taken to be down at its time" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try linked(&layer, &recorder, peer, 0x0042);
    const ended = connections.disconnect(&layer, peer);
    status(&layer, hci.HCI_OP_DISCONNECT, 0);
    layer.now = _hci.nextDeadline(&layer).?;
    _hci.tick(&layer);
    try testing.expectEqual(@as(i32, bluetooth.BTERR_TIMEOUT), layer.waits[ended.waiting].result);
    try testing.expect(connections.find(&layer, peer) == null);
    try testing.expectEqual(@as(u16, 6), layer.acl_credits);
}

test "a hardware error forgets the links and answers whoever waits" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try linked(&layer, &recorder, peer, 0x0042);
    const waiting = connections.connect(&layer, sensor);
    try testing.expect(waiting == .waiting);
    event(&layer, hci.HCI_EV_HARDWARE_ERROR, &.{0});
    try testing.expectEqual(bluetooth.BTCS_STARTING, layer.state);
    try testing.expect(layer.waits[waiting.waiting].done);
    try testing.expectEqual(@as(i32, hci.HCI_ERR_HARDWARE_FAILURE), layer.waits[waiting.waiting].result);
    try testing.expectEqual(@as(usize, 0), connections.count(&layer));
    try testing.expectEqual(@as(u16, 0), layer.acl_credits);
}
