// SPDX-License-Identifier: MIT
//! Host tests of L2CAP's dynamic channels and of SDP, the test playing
//! the device and the controller: a channel opened over a link that is
//! up, waited for while the device says it is pending, configured both
//! ways, carrying frames each way and closed; one over a link made for it,
//! which ends two seconds after it; the device's refusals, a Command
//! Reject, requests not answered in their time; a device's channel to a
//! listener, to a PSM nobody serves, with a CID it uses already, and one
//! the task does not take; what a configuration does not take answered
//! with what would do, and one in parts; a link down closing its
//! channels; the SDP server's searches, its attributes in parts and its
//! errors; the SDP client's query in parts, its failures, and the records
//! read; the data elements read whole or not at all.

const std = @import("std");
const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const l2cap = bluetooth.l2cap;
const sdp = bluetooth.sdp;
const hcidev = sdk.devices.hci;
const _hci = @import("../hci/_hci.zig");
const Hci = _hci.Hci;
const acl = @import("../hci/acl.zig");
const connections = @import("../hci/connections.zig");
const channels = @import("../l2cap/channels.zig");
const sdp_client = @import("../sdp/client.zig");
const _sdp = @import("../sdp/_sdp.zig");
const _service = @import("../service/_service.zig");

const testing = std.testing;

/// A controller that keeps the commands and the frames it is sent - the
/// frames whole, put together from their packets - and the task's side:
/// what it is told of its channels, and a listener.
const Recorder = struct {
    opcodes: [32]u16 = undefined,
    command_count: usize = 0,
    frames: [16]Frame = undefined,
    frame_count: usize = 0,
    events: [16]Told = undefined,
    event_count: usize = 0,
    /// The PSM the task's listener serves, and whether the task takes the
    /// channels it is told of.
    listening: u16 = 0,
    take: bool = true,

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
        kind: channels.EventKind,
        incoming: bool,
        listener: u32,
        result: i32,
        length: usize,
        data: [64]u8,
    };

    fn send(context: *anyopaque, packet_type: u8, bytes: []const u8) bool {
        const recorder: *Recorder = @ptrCast(@alignCast(context));
        switch (packet_type) {
            hcidev.HCI_COMMAND_PKT => {
                recorder.opcodes[recorder.command_count % recorder.opcodes.len] = _hci.le16(bytes[0..2]);
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

    fn told(context: *anyopaque, happened: *const channels.Event) bool {
        const recorder: *Recorder = @ptrCast(@alignCast(context));
        const kept = &recorder.events[recorder.event_count % recorder.events.len];
        recorder.event_count += 1;
        const length = @min(happened.data.len, kept.data.len);
        kept.* = .{ .kind = happened.kind, .incoming = happened.channel.incoming, .listener = happened.channel.listener, .result = happened.result, .length = length, .data = undefined };
        @memcpy(kept.data[0..length], happened.data[0..length]);
        return recorder.take;
    }

    fn listener(context: *anyopaque, psm: u16) u32 {
        const recorder: *Recorder = @ptrCast(@alignCast(context));
        return if (psm == recorder.listening) 7 else 0;
    }

    fn lastCommand(recorder: *const Recorder) u16 {
        return recorder.opcodes[(recorder.command_count - 1) % recorder.opcodes.len];
    }

    fn lastFrame(recorder: *const Recorder) *const Frame {
        return &recorder.frames[(recorder.frame_count - 1) % recorder.frames.len];
    }

    fn lastTold(recorder: *const Recorder) *const Told {
        return &recorder.events[(recorder.event_count - 1) % recorder.events.len];
    }
};

/// A signalling command the layer sent.
const Signal = struct {
    ident: u8,
    data: []const u8,
};

/// The last command with `code` the layer sent on BR/EDR's signalling
/// channel, among its last frames.
fn sent(recorder: *const Recorder, code: u8) !Signal {
    var back: usize = 0;
    while (back < @min(recorder.frame_count, recorder.frames.len)) : (back += 1) {
        const frame = &recorder.frames[(recorder.frame_count - 1 - back) % recorder.frames.len];
        if (frame.cid != l2cap.CID_SIGNALING or frame.length < l2cap.L2CAP_COMMAND_HDR or frame.data[0] != code) continue;
        const length = _hci.le16(frame.data[2..4]);
        return .{ .ident = frame.data[1], .data = frame.data[l2cap.L2CAP_COMMAND_HDR..][0..length] };
    }
    return error.NotSent;
}

/// A layer up and on, its port the recorder's, with buffers for every
/// frame the tests send.
fn upLayer(recorder: *Recorder) Hci {
    var layer = Hci{ .port = .{ .context = recorder, .send = Recorder.send, .channel = Recorder.told, .listener = Recorder.listener } };
    layer.state = bluetooth.BTCS_UP;
    layer.features[0] = .{ 0xBF, 0xFE, 0xCF, 0xFE, 0xDB, 0xFF, 0x7B, 0x87 };
    layer.credits = 4;
    layer.now = 100_000;
    layer.acl_mtu = 1021;
    layer.acl_packets = 1000;
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

/// A frame of the link on channel `cid`, in one packet.
fn frameIn(layer: *Hci, handle: u16, cid: u16, payload: []const u8) void {
    var packet: [hci.HCI_ACL_HDR + acl.FRAME_ROOM]u8 = undefined;
    const head = handle | hci.ACL_START << hci.ACL_BOUNDARY_SHIFT;
    const length = l2cap.L2CAP_HDR + payload.len;
    put16(packet[0..2], head);
    put16(packet[2..4], @intCast(length));
    put16(packet[4..6], @intCast(payload.len));
    put16(packet[6..8], cid);
    @memcpy(packet[8..][0..payload.len], payload);
    _hci.received(layer, hcidev.HCI_ACLDATA_PKT, packet[0 .. hci.HCI_ACL_HDR + length]);
}

/// A signalling command of the device's.
fn signalIn(layer: *Hci, handle: u16, code: u8, ident: u8, data: []const u8) void {
    var command: [64]u8 = undefined;
    command[0] = code;
    command[1] = ident;
    put16(command[2..4], @intCast(data.len));
    @memcpy(command[4..][0..data.len], data);
    frameIn(layer, handle, l2cap.CID_SIGNALING, command[0 .. 4 + data.len]);
}

/// A BR/EDR link to `address` up as `handle`, made by this machine - by
/// ConnectBTDevice's `connect`, or already asked for - its name asked for
/// and answered.
fn linkUp(layer: *Hci, recorder: *Recorder, address: bluetooth.BTAddress, handle: u16) void {
    if (connections.find(layer, address) == null) _ = connections.connect(layer, address);
    status(layer, hci.HCI_OP_CREATE_CONNECTION, 0);
    var params: [11]u8 = undefined;
    params[0] = 0;
    put16(params[1..3], handle);
    params[3..9].* = address.bytes;
    params[9] = hci.LINK_ACL;
    params[10] = 0;
    event(layer, hci.HCI_EV_CONNECTION_COMPLETE, &params);
    if (recorder.lastCommand() == hci.HCI_OP_REMOTE_NAME_REQUEST) {
        status(layer, hci.HCI_OP_REMOTE_NAME_REQUEST, 0);
        var name: [255]u8 = @splat(0);
        @memcpy(name[1..7], &address.bytes);
        @memcpy(name[7..13], "device");
        event(layer, hci.HCI_EV_REMOTE_NAME_REQUEST_COMPLETE, &name);
    }
    for (&layer.waits, 0..) |*wait, index| {
        if (wait.used and wait.done and wait.kind == .connect) connections.release(layer, @intCast(index));
    }
}

/// A channel's configuration agreed: ours - this machine's MTU, sent
/// last - answered success, theirs asked with an MTU of `mtu` and
/// answered success.
fn configured(layer: *Hci, recorder: *const Recorder, handle: u16, local_cid: u16, remote_cid: u16, mtu: u16) !void {
    const ours = try sent(recorder, l2cap.CONFIGURE_REQUEST);
    var expected: [8]u8 = undefined;
    put16(expected[0..2], remote_cid);
    expected[2..8].* = .{ 0, 0, l2cap.OPTION_MTU, 2, 0x00, 0x04 };
    try testing.expectEqualSlices(u8, &expected, ours.data);
    var answer: [6]u8 = @splat(0);
    put16(answer[0..2], local_cid);
    signalIn(layer, handle, l2cap.CONFIGURE_RESPONSE, ours.ident, &answer);
    var theirs: [8]u8 = undefined;
    put16(theirs[0..2], local_cid);
    theirs[2..6].* = .{ 0, 0, l2cap.OPTION_MTU, 2 };
    put16(theirs[6..8], mtu);
    signalIn(layer, handle, l2cap.CONFIGURE_REQUEST, 0x70, &theirs);
    const taken = try sent(recorder, l2cap.CONFIGURE_RESPONSE);
    try testing.expectEqual(@as(u8, 0x70), taken.ident);
    var success: [6]u8 = @splat(0);
    put16(success[0..2], remote_cid);
    try testing.expectEqualSlices(u8, &success, taken.data);
}

/// A channel this machine opens to `psm` over the link up as `handle`,
/// taken by the device as `remote_cid` and configured: the call's wait,
/// answered.
fn opened(layer: *Hci, recorder: *Recorder, handle: u16, psm: u16, remote_cid: u16) !*channels.Channel {
    const begun = channels.open(layer, peer, psm);
    try testing.expect(begun == .waiting);
    const record = channels.bySerial(layer, layer.waits[begun.waiting].serial).?;
    const asked = try sent(recorder, l2cap.CONNECTION_REQUEST);
    var answer: [8]u8 = @splat(0);
    put16(answer[0..2], remote_cid);
    put16(answer[2..4], record.local_cid);
    signalIn(layer, handle, l2cap.CONNECTION_RESPONSE, asked.ident, &answer);
    try configured(layer, recorder, handle, record.local_cid, remote_cid, 672);
    try testing.expect(layer.waits[begun.waiting].done);
    try testing.expectEqual(@as(i32, 0), layer.waits[begun.waiting].result);
    connections.release(layer, begun.waiting);
    return record;
}

fn expectFrame(recorder: *const Recorder, handle: u16, cid: u16, payload: []const u8) !void {
    const frame = recorder.lastFrame();
    try testing.expectEqual(handle, frame.handle);
    try testing.expectEqual(cid, frame.cid);
    try testing.expectEqualSlices(u8, payload, frame.bytes());
}

/// The channel whose end here is `cid`.
fn byLocalCid(layer: *Hci, cid: u16) ?*channels.Channel {
    for (&layer.channels) |*channel| {
        if (channel.state != .free and channel.local_cid == cid) return channel;
    }
    return null;
}

fn put16(into: *[2]u8, value: u16) void {
    into[0] = @truncate(value);
    into[1] = @truncate(value >> 8);
}

const peer = bluetooth.BTAddress{ .bytes = .{ 0x01, 0x10, 0xEF, 0x5E, 0x00, 0x00 } };

test "a channel opened over a link that is up: pending, configured both ways, frames each way, closed" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    linkUp(&layer, &recorder, peer, 0x0042);
    const begun = channels.open(&layer, peer, 0x1001);
    try testing.expect(begun == .waiting);
    const index = begun.waiting;
    const record = channels.bySerial(&layer, layer.waits[index].serial).?;
    // Connection Request: the PSM, this machine's CID.
    const asked = try sent(&recorder, l2cap.CONNECTION_REQUEST);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x10, 0x40, 0x00 }, asked.data);
    // Pending - authentication - waited for longer; then taken.
    signalIn(&layer, 0x0042, l2cap.CONNECTION_RESPONSE, asked.ident, &.{ 0x00, 0x00, 0x40, 0x00, 0x01, 0x00, 0x01, 0x00 });
    try testing.expectEqual(layer.now + channels.PENDING_WAIT_MS, record.deadline.?);
    signalIn(&layer, 0x0042, l2cap.CONNECTION_RESPONSE, asked.ident, &.{ 0x50, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00 });
    // Ours: this machine's MTU, answered.
    const ours = try sent(&recorder, l2cap.CONFIGURE_REQUEST);
    try testing.expectEqualSlices(u8, &.{ 0x50, 0x00, 0x00, 0x00, l2cap.OPTION_MTU, 2, 0x00, 0x04 }, ours.data);
    signalIn(&layer, 0x0042, l2cap.CONFIGURE_RESPONSE, ours.ident, &.{ 0x40, 0x00, 0x00, 0x00, 0x00, 0x00 });
    try testing.expect(!layer.waits[index].done);
    // Theirs: an MTU of 512, a flush timeout passed over, a hint not
    // known let go - taken.
    signalIn(&layer, 0x0042, l2cap.CONFIGURE_REQUEST, 9, &.{ 0x40, 0x00, 0x00, 0x00, l2cap.OPTION_MTU, 2, 0x00, 0x02, l2cap.OPTION_FLUSH_TIMEOUT, 2, 0xFF, 0xFF, 0xF0, 1, 0 });
    const taken = try sent(&recorder, l2cap.CONFIGURE_RESPONSE);
    try testing.expectEqual(@as(u8, 9), taken.ident);
    try testing.expectEqualSlices(u8, &.{ 0x50, 0x00, 0x00, 0x00, 0x00, 0x00 }, taken.data);
    // Open: the task told, the call answered.
    try testing.expect(layer.waits[index].done);
    try testing.expectEqual(@as(i32, 0), layer.waits[index].result);
    connections.release(&layer, index);
    try testing.expectEqual(channels.EventKind.opened, recorder.lastTold().kind);
    try testing.expect(!recorder.lastTold().incoming);
    try testing.expectEqual(@as(u16, 512), record.mtu_out);
    // A frame of the device's, told; one to it, sent.
    frameIn(&layer, 0x0042, 0x0040, "ping");
    try testing.expectEqual(channels.EventKind.data, recorder.lastTold().kind);
    try testing.expectEqualStrings("ping", recorder.lastTold().data[0..recorder.lastTold().length]);
    try testing.expectEqual(@as(i32, 0), channels.send(&layer, record, "pong"));
    try expectFrame(&recorder, 0x0042, 0x0050, "pong");
    // Longer than the device takes.
    var long: [513]u8 = @splat(0);
    try testing.expectEqual(bluetooth.BTERR_TOOLONG, channels.send(&layer, record, &long));
    // Closed: the call waits for the device's answer; a frame meanwhile
    // goes nowhere, and nothing is told.
    const told = recorder.event_count;
    const closing = channels.closeFor(&layer, record);
    try testing.expect(closing == .waiting);
    const ending = try sent(&recorder, l2cap.DISCONNECTION_REQUEST);
    try testing.expectEqualSlices(u8, &.{ 0x50, 0x00, 0x40, 0x00 }, ending.data);
    frameIn(&layer, 0x0042, 0x0040, "late");
    signalIn(&layer, 0x0042, l2cap.DISCONNECTION_RESPONSE, ending.ident, &.{ 0x50, 0x00, 0x40, 0x00 });
    try testing.expect(layer.waits[closing.waiting].done);
    connections.release(&layer, closing.waiting);
    try testing.expectEqual(told, recorder.event_count);
    try testing.expectEqual(@as(usize, 0), channels.count(&layer));
    // The link ConnectBTDevice made stays.
    try testing.expect(connections.find(&layer, peer).?.idle_until == null);
}

test "a channel over a link made for it, which ends two seconds after it" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    const begun = channels.open(&layer, peer, 0x1001);
    try testing.expect(begun == .waiting);
    try testing.expectEqual(hci.HCI_OP_CREATE_CONNECTION, recorder.lastCommand());
    try testing.expectEqual(@as(usize, 0), recorder.frame_count);
    // Asked for once the link is up.
    linkUp(&layer, &recorder, peer, 0x0042);
    const asked = try sent(&recorder, l2cap.CONNECTION_REQUEST);
    signalIn(&layer, 0x0042, l2cap.CONNECTION_RESPONSE, asked.ident, &.{ 0x50, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00 });
    try configured(&layer, &recorder, 0x0042, 0x0040, 0x0050, 672);
    try testing.expectEqual(@as(i32, 0), layer.waits[begun.waiting].result);
    connections.release(&layer, begun.waiting);
    // The device closes it: answered, and the task told.
    signalIn(&layer, 0x0042, l2cap.DISCONNECTION_REQUEST, 3, &.{ 0x40, 0x00, 0x50, 0x00 });
    const answer = try sent(&recorder, l2cap.DISCONNECTION_RESPONSE);
    try testing.expectEqual(@as(u8, 3), answer.ident);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x00, 0x50, 0x00 }, answer.data);
    try testing.expectEqual(channels.EventKind.closed, recorder.lastTold().kind);
    try testing.expectEqual(@as(i32, 0), recorder.lastTold().result);
    // Two seconds on, its link is ended.
    const link = connections.find(&layer, peer).?;
    try testing.expectEqual(layer.now + connections.IDLE_MS, link.idle_until.?);
    try testing.expectEqual(link.idle_until, _hci.nextDeadline(&layer));
    layer.now += connections.IDLE_MS - 1;
    _hci.tick(&layer);
    try testing.expect(recorder.lastCommand() != hci.HCI_OP_DISCONNECT);
    layer.now += 1;
    _hci.tick(&layer);
    try testing.expectEqual(hci.HCI_OP_DISCONNECT, recorder.lastCommand());
}

test "a link made for channels and asked for by ConnectBTDevice meanwhile stays" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    const begun = channels.open(&layer, peer, 0x1001);
    try testing.expect(begun == .waiting);
    // ConnectBTDevice while it is being made.
    try testing.expect(connections.connect(&layer, peer) == .waiting);
    linkUp(&layer, &recorder, peer, 0x0042);
    const asked = try sent(&recorder, l2cap.CONNECTION_REQUEST);
    // Refused: the call answered, the link kept.
    signalIn(&layer, 0x0042, l2cap.CONNECTION_RESPONSE, asked.ident, &.{ 0x00, 0x00, 0x40, 0x00, 0x02, 0x00, 0x00, 0x00 });
    try testing.expectEqual(bluetooth.BTERR_UNSUPPORTED, layer.waits[begun.waiting].result);
    try testing.expect(connections.find(&layer, peer).?.idle_until == null);
}

test "refusals: no such protocol, no resources, security, a Command Reject, no answer; what no channel can name" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    linkUp(&layer, &recorder, peer, 0x0042);
    const Case = struct { result: u16, answered: i32 };
    for ([_]Case{
        .{ .result = l2cap.CONNECTION_PSM_NOT_SUPPORTED, .answered = bluetooth.BTERR_UNSUPPORTED },
        .{ .result = l2cap.CONNECTION_NO_RESOURCES, .answered = bluetooth.BTERR_BUSY },
        .{ .result = l2cap.CONNECTION_SECURITY_BLOCK, .answered = bluetooth.BTERR_REFUSED },
    }) |case| {
        const begun = channels.open(&layer, peer, 0x1001);
        const record = channels.bySerial(&layer, layer.waits[begun.waiting].serial).?;
        const asked = try sent(&recorder, l2cap.CONNECTION_REQUEST);
        var answer: [8]u8 = @splat(0);
        put16(answer[2..4], record.local_cid);
        put16(answer[4..6], case.result);
        signalIn(&layer, 0x0042, l2cap.CONNECTION_RESPONSE, asked.ident, &answer);
        try testing.expectEqual(case.answered, layer.waits[begun.waiting].result);
        connections.release(&layer, begun.waiting);
    }
    // A refusal that does not name this machine's CID: the identifier says
    // which request it answers.
    const unnamed = channels.open(&layer, peer, 0x1001);
    const asked = try sent(&recorder, l2cap.CONNECTION_REQUEST);
    signalIn(&layer, 0x0042, l2cap.CONNECTION_RESPONSE, asked.ident, &.{ 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00 });
    try testing.expectEqual(bluetooth.BTERR_BUSY, layer.waits[unnamed.waiting].result);
    connections.release(&layer, unnamed.waiting);
    // A Command Reject of the request.
    const rejected = channels.open(&layer, peer, 0x1001);
    const rejected_request = try sent(&recorder, l2cap.CONNECTION_REQUEST);
    signalIn(&layer, 0x0042, l2cap.COMMAND_REJECT, rejected_request.ident, &.{ 0x00, 0x00 });
    try testing.expectEqual(bluetooth.BTERR_REFUSED, layer.waits[rejected.waiting].result);
    connections.release(&layer, rejected.waiting);
    // No answer in ten seconds.
    const unanswered = channels.open(&layer, peer, 0x1001);
    layer.now += channels.REQUEST_WAIT_MS;
    _hci.tick(&layer);
    try testing.expectEqual(bluetooth.BTERR_TIMEOUT, layer.waits[unanswered.waiting].result);
    connections.release(&layer, unanswered.waiting);
    // What no channel can name, and an LE address.
    try testing.expectEqual(connections.Begun{ .done = bluetooth.BTERR_UNSUPPORTED }, channels.open(&layer, peer, 0x1000));
    try testing.expectEqual(connections.Begun{ .done = bluetooth.BTERR_UNSUPPORTED }, channels.open(&layer, peer, 0x0101));
    const sensor = bluetooth.BTAddress{ .bytes = peer.bytes, .kind = bluetooth.BTADDR_LE_PUBLIC };
    try testing.expectEqual(connections.Begun{ .done = bluetooth.BTERR_UNSUPPORTED }, channels.open(&layer, sensor, 0x1001));
    try testing.expectEqual(@as(usize, 0), channels.count(&layer));
}

test "a configuration not answered in its time closed; a close not answered in its time taken as done" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    linkUp(&layer, &recorder, peer, 0x0042);
    const begun = channels.open(&layer, peer, 0x1001);
    const asked = try sent(&recorder, l2cap.CONNECTION_REQUEST);
    signalIn(&layer, 0x0042, l2cap.CONNECTION_RESPONSE, asked.ident, &.{ 0x50, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00 });
    // Our configuration never answered: closed, the call answered once
    // the close is.
    layer.now += channels.REQUEST_WAIT_MS;
    _hci.tick(&layer);
    _ = try sent(&recorder, l2cap.DISCONNECTION_REQUEST);
    try testing.expect(!layer.waits[begun.waiting].done);
    layer.now += channels.CLOSE_WAIT_MS;
    _hci.tick(&layer);
    try testing.expectEqual(bluetooth.BTERR_TIMEOUT, layer.waits[begun.waiting].result);
    try testing.expectEqual(@as(usize, 0), channels.count(&layer));
}

test "a device's channel to a listener taken; to a PSM nobody serves, with a CID in use, and one not taken" {
    var recorder = Recorder{ .listening = 0x1001 };
    var layer = upLayer(&recorder);
    linkUp(&layer, &recorder, peer, 0x0042);
    signalIn(&layer, 0x0042, l2cap.CONNECTION_REQUEST, 5, &.{ 0x01, 0x10, 0x60, 0x00 });
    const taken = try sent(&recorder, l2cap.CONNECTION_RESPONSE);
    try testing.expectEqual(@as(u8, 5), taken.ident);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x00, 0x60, 0x00, 0x00, 0x00, 0x00, 0x00 }, taken.data);
    try configured(&layer, &recorder, 0x0042, 0x0040, 0x0060, 100);
    // The task told: the device's, its listener's.
    const told = recorder.lastTold();
    try testing.expectEqual(channels.EventKind.opened, told.kind);
    try testing.expect(told.incoming);
    try testing.expectEqual(@as(u32, 7), told.listener);
    try testing.expectEqual(@as(u16, 100), byLocalCid(&layer, 0x0040).?.mtu_out);
    // To a PSM nobody serves: no such protocol.
    signalIn(&layer, 0x0042, l2cap.CONNECTION_REQUEST, 6, &.{ 0x03, 0x10, 0x61, 0x00 });
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x61, 0x00, 0x02, 0x00, 0x00, 0x00 }, (try sent(&recorder, l2cap.CONNECTION_RESPONSE)).data);
    // Its CID one of its channels has, or one no channel can be.
    signalIn(&layer, 0x0042, l2cap.CONNECTION_REQUEST, 7, &.{ 0x01, 0x10, 0x60, 0x00 });
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x60, 0x00, 0x07, 0x00, 0x00, 0x00 }, (try sent(&recorder, l2cap.CONNECTION_RESPONSE)).data);
    signalIn(&layer, 0x0042, l2cap.CONNECTION_REQUEST, 8, &.{ 0x01, 0x10, 0x01, 0x00 });
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x01, 0x00, 0x06, 0x00, 0x00, 0x00 }, (try sent(&recorder, l2cap.CONNECTION_RESPONSE)).data);
    // One the task does not take - its listener gone meanwhile: closed.
    recorder.take = false;
    signalIn(&layer, 0x0042, l2cap.CONNECTION_REQUEST, 9, &.{ 0x01, 0x10, 0x62, 0x00 });
    try configured(&layer, &recorder, 0x0042, 0x0041, 0x0062, 672);
    try testing.expectEqualSlices(u8, &.{ 0x62, 0x00, 0x41, 0x00 }, (try sent(&recorder, l2cap.DISCONNECTION_REQUEST)).data);
}

test "a configuration: an MTU under 48 and another mode answered with what would do, options not known named, one in parts" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    linkUp(&layer, &recorder, peer, 0x0042);
    const begun = channels.open(&layer, peer, 0x1001);
    const record = channels.bySerial(&layer, layer.waits[begun.waiting].serial).?;
    const asked = try sent(&recorder, l2cap.CONNECTION_REQUEST);
    signalIn(&layer, 0x0042, l2cap.CONNECTION_RESPONSE, asked.ident, &.{ 0x50, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00 });
    signalIn(&layer, 0x0042, l2cap.CONFIGURE_REQUEST, 20, &.{ 0x40, 0x00, 0x00, 0x00, l2cap.OPTION_MTU, 2, 30, 0 });
    try testing.expectEqualSlices(u8, &.{ 0x50, 0x00, 0x00, 0x00, 0x01, 0x00, l2cap.OPTION_MTU, 2, 48, 0 }, (try sent(&recorder, l2cap.CONFIGURE_RESPONSE)).data);
    signalIn(&layer, 0x0042, l2cap.CONFIGURE_REQUEST, 21, &.{ 0x40, 0x00, 0x00, 0x00, l2cap.OPTION_RETRANSMISSION, 9, 3, 1, 2, 3, 4, 5, 6, 7, 8 });
    try testing.expectEqualSlices(u8, &.{ 0x50, 0x00, 0x00, 0x00, 0x01, 0x00, l2cap.OPTION_RETRANSMISSION, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, (try sent(&recorder, l2cap.CONFIGURE_RESPONSE)).data);
    signalIn(&layer, 0x0042, l2cap.CONFIGURE_REQUEST, 22, &.{ 0x40, 0x00, 0x00, 0x00, l2cap.OPTION_MTU, 2, 0, 1, 0x42, 1, 0 });
    try testing.expectEqualSlices(u8, &.{ 0x50, 0x00, 0x00, 0x00, 0x03, 0x00, 0x42, 0 }, (try sent(&recorder, l2cap.CONFIGURE_RESPONSE)).data);
    // None of them taken.
    try testing.expectEqual(l2cap.MTU_DEFAULT, record.mtu_out);
    try testing.expect(!record.theirs_done);
    // In two parts, each answered: the first's MTU kept.
    signalIn(&layer, 0x0042, l2cap.CONFIGURE_REQUEST, 23, &.{ 0x40, 0x00, 0x01, 0x00, l2cap.OPTION_MTU, 2, 0x00, 0x01 });
    try testing.expectEqualSlices(u8, &.{ 0x50, 0x00, 0x01, 0x00, 0x00, 0x00 }, (try sent(&recorder, l2cap.CONFIGURE_RESPONSE)).data);
    try testing.expect(!record.theirs_done);
    signalIn(&layer, 0x0042, l2cap.CONFIGURE_REQUEST, 24, &.{ 0x40, 0x00, 0x00, 0x00 });
    try testing.expectEqualSlices(u8, &.{ 0x50, 0x00, 0x00, 0x00, 0x00, 0x00 }, (try sent(&recorder, l2cap.CONFIGURE_RESPONSE)).data);
    try testing.expect(record.theirs_done);
    try testing.expectEqual(@as(u16, 256), record.mtu_out);
    // For a channel there is not: rejected, naming it.
    signalIn(&layer, 0x0042, l2cap.CONFIGURE_REQUEST, 25, &.{ 0x99, 0x00, 0x00, 0x00 });
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x00, 0x99, 0x00, 0x00, 0x00 }, (try sent(&recorder, l2cap.COMMAND_REJECT)).data);
    // Ours answered: open.
    const ours = try sent(&recorder, l2cap.CONFIGURE_REQUEST);
    signalIn(&layer, 0x0042, l2cap.CONFIGURE_RESPONSE, ours.ident, &.{ 0x40, 0x00, 0x00, 0x00, 0x00, 0x00 });
    try testing.expectEqual(@as(i32, 0), layer.waits[begun.waiting].result);
}

test "a link down closes its channels, each told why, and answers the calls opening one" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    linkUp(&layer, &recorder, peer, 0x0042);
    _ = try opened(&layer, &recorder, 0x0042, 0x1001, 0x0050);
    const begun = channels.open(&layer, peer, 0x1003);
    event(&layer, hci.HCI_EV_DISCONNECTION_COMPLETE, &.{ 0, 0x42, 0x00, hci.HCI_ERR_CONNECTION_TIMEOUT });
    try testing.expectEqual(channels.EventKind.closed, recorder.lastTold().kind);
    try testing.expectEqual(@as(i32, hci.HCI_ERR_CONNECTION_TIMEOUT), recorder.lastTold().result);
    try testing.expectEqual(@as(i32, hci.HCI_ERR_CONNECTION_TIMEOUT), layer.waits[begun.waiting].result);
    try testing.expectEqual(@as(usize, 0), channels.count(&layer));
}

// --- SDP ----------------------------------------------------------------------------

/// A channel the device opens to the SDP server, as `remote_cid`, its
/// MTU `mtu`: configured.
fn sdpChannel(layer: *Hci, recorder: *Recorder, remote_cid: u16, mtu: u16) !u16 {
    var request: [4]u8 = .{ 0x01, 0x00, 0, 0 };
    put16(request[2..4], remote_cid);
    signalIn(layer, 0x0042, l2cap.CONNECTION_REQUEST, 1, &request);
    const taken = try sent(recorder, l2cap.CONNECTION_RESPONSE);
    try testing.expectEqual(@as(u16, l2cap.CONNECTION_SUCCESS), _hci.le16(taken.data[4..6]));
    const local_cid = _hci.le16(taken.data[0..2]);
    try configured(layer, recorder, 0x0042, local_cid, remote_cid, mtu);
    return local_cid;
}

/// A PDU of the device's to the SDP server, its header made.
fn sdpIn(layer: *Hci, cid: u16, id: u8, transaction: u16, params: []const u8) void {
    var pdu: [256]u8 = undefined;
    pdu[0] = id;
    _sdp.put16(pdu[1..3], transaction);
    _sdp.put16(pdu[3..5], @intCast(params.len));
    @memcpy(pdu[5..][0..params.len], params);
    frameIn(layer, 0x0042, cid, pdu[0 .. 5 + params.len]);
}

/// The server's answer, sent last: its id and transaction checked, its
/// parameters.
fn sdpOut(recorder: *const Recorder, id: u8, transaction: u16) ![]const u8 {
    const pdu = recorder.lastFrame().bytes();
    try testing.expectEqual(id, pdu[0]);
    try testing.expectEqual(transaction, _sdp.be16(pdu[1..3]));
    try testing.expectEqual(pdu.len - 5, _sdp.be16(pdu[3..5]));
    return pdu[5..];
}

test "the SDP server: searches, its record's attributes whole and in parts, its errors" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    linkUp(&layer, &recorder, peer, 0x0042);
    const cid = try sdpChannel(&layer, &recorder, 0x0070, 672);
    // A search for the server's class: its record, handle 0.
    sdpIn(&layer, cid, sdp.SDP_SERVICE_SEARCH_REQUEST, 1, &.{ 0x35, 0x03, 0x19, 0x10, 0x00, 0x00, 0x0A, 0x00 });
    try testing.expectEqualSlices(u8, &.{ 0, 1, 0, 1, 0, 0, 0, 0, 0 }, try sdpOut(&recorder, sdp.SDP_SERVICE_SEARCH_RESPONSE, 1));
    // L2CAP as 128 bits; and a class it does not have.
    sdpIn(&layer, cid, sdp.SDP_SERVICE_SEARCH_REQUEST, 2, &([_]u8{ 0x35, 0x11, 0x1C } ++ [_]u8{ 0, 0, 0x01, 0x00 } ++ sdp.BASE_UUID[4..].* ++ [_]u8{ 0x00, 0x0A, 0x00 }));
    try testing.expectEqualSlices(u8, &.{ 0, 1, 0, 1, 0, 0, 0, 0, 0 }, try sdpOut(&recorder, sdp.SDP_SERVICE_SEARCH_RESPONSE, 2));
    sdpIn(&layer, cid, sdp.SDP_SERVICE_SEARCH_REQUEST, 3, &.{ 0x35, 0x06, 0x19, 0x10, 0x00, 0x19, 0x11, 0x01, 0x00, 0x0A, 0x00 });
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0 }, try sdpOut(&recorder, sdp.SDP_SERVICE_SEARCH_RESPONSE, 3));

    // Every attribute of record 0: what a client reads of it.
    const all_ids = [_]u8{ 0x35, 0x05, 0x0A, 0x00, 0x00, 0xFF, 0xFF };
    sdpIn(&layer, cid, sdp.SDP_SERVICE_ATTRIBUTE_REQUEST, 4, &([_]u8{ 0, 0, 0, 0, 0xFF, 0xFF } ++ all_ids ++ [_]u8{0}));
    const whole_answer = try sdpOut(&recorder, sdp.SDP_SERVICE_ATTRIBUTE_RESPONSE, 4);
    const count = _sdp.be16(whole_answer[0..2]);
    try testing.expectEqual(@as(u8, 0), whole_answer[2 + count]);
    var whole: [128]u8 = undefined;
    @memcpy(whole[0..count], whole_answer[2..][0..count]);
    const list = _sdp.element(whole[0..count]).?;
    try testing.expectEqual(@as(usize, count), list.whole);
    var found: _service.Read = .{};
    _service.read(list, &found);
    try testing.expectEqual(@as(u32, 0), found.service.handle);
    try testing.expectEqual(@as(u16, sdp.UUID_SERVICE_DISCOVERY_SERVER), found.service.class16);
    try testing.expectEqual(@as(u16, l2cap.PSM_SDP), found.service.psm);
    try testing.expect(_sdp.holds(list.data, _sdp.uuid(.{ .kind = sdp.DE_UUID, .data = &.{ 0x10, 0x02 }, .whole = 3 }).?));
    // One attribute alone.
    sdpIn(&layer, cid, sdp.SDP_SERVICE_ATTRIBUTE_REQUEST, 5, &.{ 0, 0, 0, 0, 0xFF, 0xFF, 0x35, 0x03, 0x09, 0x00, 0x01, 0x00 });
    try testing.expectEqualSlices(u8, &.{ 0, 11, 0x36, 0, 8, 0x09, 0x00, 0x01, 0x35, 0x03, 0x19, 0x10, 0x00, 0 }, try sdpOut(&recorder, sdp.SDP_SERVICE_ATTRIBUTE_RESPONSE, 5));
    // In parts of 20 bytes, each ending with where the next begins.
    var gathered: [128]u8 = undefined;
    var have: usize = 0;
    var state: [3]u8 = .{ 0, 0, 0 };
    var transaction: u16 = 6;
    while (true) : (transaction += 1) {
        const state_length: usize = if (state[0] == 0) 1 else 3;
        var params: [16]u8 = undefined;
        params[0..6].* = .{ 0, 0, 0, 0, 0, 20 };
        params[6..13].* = all_ids;
        @memcpy(params[13..][0..state_length], state[0..state_length]);
        sdpIn(&layer, cid, sdp.SDP_SERVICE_ATTRIBUTE_REQUEST, transaction, params[0 .. 13 + state_length]);
        const answer = try sdpOut(&recorder, sdp.SDP_SERVICE_ATTRIBUTE_RESPONSE, transaction);
        const part = _sdp.be16(answer[0..2]);
        try testing.expect(part <= 20);
        @memcpy(gathered[have..][0..part], answer[2..][0..part]);
        have += part;
        const rest = answer[2 + part ..];
        if (rest[0] == 0) break;
        try testing.expectEqual(@as(usize, 3), rest.len);
        state = rest[0..3].*;
    }
    try testing.expectEqualSlices(u8, whole[0..count], gathered[0..have]);
    // Search and attributes at once: one list a record.
    sdpIn(&layer, cid, sdp.SDP_SERVICE_SEARCH_ATTRIBUTE_REQUEST, 20, &([_]u8{ 0x35, 0x03, 0x19, 0x01, 0x00, 0xFF, 0xFF } ++ all_ids ++ [_]u8{0}));
    const both = try sdpOut(&recorder, sdp.SDP_SERVICE_SEARCH_ATTRIBUTE_RESPONSE, 20);
    try testing.expectEqual(@as(u16, count + 3), _sdp.be16(both[0..2]));
    try testing.expectEqualSlices(u8, whole[0..count], both[5..][0..count]);

    // A handle there is not, a continuation state not given, a request
    // that is none, a PDU whose length is wrong.
    sdpIn(&layer, cid, sdp.SDP_SERVICE_ATTRIBUTE_REQUEST, 30, &([_]u8{ 0, 0, 0, 5, 0xFF, 0xFF } ++ all_ids ++ [_]u8{0}));
    try testing.expectEqualSlices(u8, &.{ 0, sdp.SDP_ERR_INVALID_HANDLE }, try sdpOut(&recorder, sdp.SDP_ERROR_RESPONSE, 30));
    sdpIn(&layer, cid, sdp.SDP_SERVICE_ATTRIBUTE_REQUEST, 31, &([_]u8{ 0, 0, 0, 0, 0xFF, 0xFF } ++ all_ids ++ [_]u8{ 2, 0x07, 0x77 }));
    try testing.expectEqualSlices(u8, &.{ 0, sdp.SDP_ERR_INVALID_CONTINUATION }, try sdpOut(&recorder, sdp.SDP_ERROR_RESPONSE, 31));
    sdpIn(&layer, cid, 0x08, 32, &.{0});
    try testing.expectEqualSlices(u8, &.{ 0, sdp.SDP_ERR_INVALID_SYNTAX }, try sdpOut(&recorder, sdp.SDP_ERROR_RESPONSE, 32));
    frameIn(&layer, 0x0042, cid, &.{ sdp.SDP_SERVICE_SEARCH_REQUEST, 0, 33, 0, 9, 0x35, 0x03 });
    try testing.expectEqualSlices(u8, &.{ 0, sdp.SDP_ERR_INVALID_PDU_SIZE }, try sdpOut(&recorder, sdp.SDP_ERROR_RESPONSE, 33));
}

/// A device's record, the one its answers carry: a serial port on RFCOMM
/// channel 3, in English, a profile of version 1.2, named "COM".
const serial_record = _sdp.sequence(&(_sdp.uint16(sdp.ATTR_SERVICE_RECORD_HANDLE) ++ _sdp.uint32(0x10001) ++
    _sdp.uint16(sdp.ATTR_SERVICE_CLASS_ID_LIST) ++ _sdp.sequence(&_sdp.uuid16(0x1101)) ++
    _sdp.uint16(sdp.ATTR_PROTOCOL_DESCRIPTOR_LIST) ++ _sdp.sequence(&(_sdp.sequence(&_sdp.uuid16(sdp.UUID_L2CAP)) ++
    _sdp.sequence(&(_sdp.uuid16(sdp.UUID_RFCOMM) ++ [_]u8{ 0x08, 3 })))) ++
    _sdp.uint16(sdp.ATTR_LANGUAGE_BASE_LIST) ++ _sdp.sequence(&(_sdp.uint16(0x656E) ++ _sdp.uint16(0x006A) ++ _sdp.uint16(0x0100))) ++
    _sdp.uint16(sdp.ATTR_PROFILE_DESCRIPTOR_LIST) ++ _sdp.sequence(&_sdp.sequence(&(_sdp.uuid16(0x1101) ++ _sdp.uint16(0x0102)))) ++
    _sdp.uint16(sdp.ATTR_SERVICE_NAME) ++ [_]u8{ 0x25, 4, 'C', 'O', 'M', 0 }));
const serial_records = _sdp.sequence(&serial_record);

/// The SDP client's query over a link made for it: its channel open, its
/// first request checked - the local CID 0x0040, the device's 0x0050.
fn queried(layer: *Hci, recorder: *Recorder, room: []u8) !u8 {
    const begun = sdp_client.query(layer, peer, room);
    try testing.expect(begun == .waiting);
    linkUp(layer, recorder, peer, 0x0042);
    const asked = try sent(recorder, l2cap.CONNECTION_REQUEST);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x40, 0x00 }, asked.data);
    signalIn(layer, 0x0042, l2cap.CONNECTION_RESPONSE, asked.ident, &.{ 0x50, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00 });
    try configured(layer, recorder, 0x0042, 0x0040, 0x0050, 672);
    // L2CAP's records, all their attributes, as much as a frame holds.
    try expectFrame(recorder, 0x0042, 0x0050, &.{ sdp.SDP_SERVICE_SEARCH_ATTRIBUTE_REQUEST, 0, 1, 0, 15, 0x35, 0x03, 0x19, 0x01, 0x00, 0x03, 0xE8, 0x35, 0x05, 0x0A, 0x00, 0x00, 0xFF, 0xFF, 0x00 });
    return begun.waiting;
}

/// An answer of the device's to the client: a part of the records, and
/// the continuation state that follows it.
fn answerIn(layer: *Hci, transaction: u16, part: []const u8, state: []const u8) void {
    var params: [128]u8 = undefined;
    _sdp.put16(params[0..2], @intCast(part.len));
    @memcpy(params[2..][0..part.len], part);
    @memcpy(params[2 + part.len ..][0..state.len], state);
    sdpIn(layer, 0x0040, sdp.SDP_SERVICE_SEARCH_ATTRIBUTE_RESPONSE, transaction, params[0 .. 2 + part.len + state.len]);
}

test "the SDP client: a query in two parts, gathered and read; its channel closed and its link ended" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    var room: [256]u8 = undefined;
    const index = try queried(&layer, &recorder, &room);
    // One at a time.
    try testing.expectEqual(connections.Begun{ .done = bluetooth.BTERR_BUSY }, sdp_client.query(&layer, peer, &room));
    // Part one, then the next asked for with its continuation state.
    answerIn(&layer, 1, serial_records[0..40], &.{ 2, 0xAB, 0xCD });
    try expectFrame(&recorder, 0x0042, 0x0050, &.{ sdp.SDP_SERVICE_SEARCH_ATTRIBUTE_REQUEST, 0, 2, 0, 17, 0x35, 0x03, 0x19, 0x01, 0x00, 0x03, 0xE8, 0x35, 0x05, 0x0A, 0x00, 0x00, 0xFF, 0xFF, 2, 0xAB, 0xCD });
    // An answer to the one before let go.
    answerIn(&layer, 1, serial_records[0..40], &.{0});
    try testing.expect(!layer.waits[index].done);
    answerIn(&layer, 2, serial_records[40..], &.{0});
    try testing.expect(layer.waits[index].done);
    try testing.expectEqual(@as(i32, 0), layer.waits[index].result);
    try testing.expectEqualSlices(u8, &serial_records, room[0..layer.sdp_query.have]);
    connections.release(&layer, index);
    sdp_client.release(&layer);
    // Its channel closed, its link ended two seconds later.
    const ending = try sent(&recorder, l2cap.DISCONNECTION_REQUEST);
    signalIn(&layer, 0x0042, l2cap.DISCONNECTION_RESPONSE, ending.ident, &.{ 0x50, 0x00, 0x40, 0x00 });
    layer.now += connections.IDLE_MS;
    _hci.tick(&layer);
    try testing.expectEqual(hci.HCI_OP_DISCONNECT, recorder.lastCommand());

    // The records read.
    const Collect = struct {
        count: usize = 0,
        found: _service.Read = .{},

        fn add(collect: *@This(), record: []const u8, found: *const _service.Read) void {
            std.debug.assert(record.len == serial_record.len);
            collect.count += 1;
            collect.found = found.*;
        }
    };
    var collect: Collect = .{};
    try testing.expect(_service.walk(&serial_records, &collect, Collect.add));
    try testing.expectEqual(@as(usize, 1), collect.count);
    const service = &collect.found.service;
    try testing.expectEqual(@as(u32, 0x10001), service.handle);
    try testing.expectEqual(@as(u16, 0x1101), service.class16);
    try testing.expectEqual(@as(u16, l2cap.PSM_RFCOMM), service.psm);
    try testing.expectEqual(@as(u8, 3), service.rfcomm_channel);
    try testing.expectEqual(@as(u16, 0x1101), service.profile16);
    try testing.expectEqual(@as(u16, 0x0102), service.profile_version);
    try testing.expectEqualStrings("COM", collect.found.name);
    // Not records: refused; none: none.
    try testing.expect(!_service.walk(serial_records[0..20], &collect, Collect.add));
    try testing.expect(_service.walk(&.{ 0x35, 0x00 }, &collect, Collect.add));
}

test "the SDP client's failures: the device's error, more than the room, no answer, a closed channel, a refused one" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    var room: [256]u8 = undefined;
    // The device's error: the channel closed, the call answered.
    var index = try queried(&layer, &recorder, &room);
    sdpIn(&layer, 0x0040, sdp.SDP_ERROR_RESPONSE, 1, &.{ 0, sdp.SDP_ERR_INSUFFICIENT_RESOURCES });
    try testing.expectEqual(bluetooth.BTERR_PROTOCOL, layer.waits[index].result);
    var ending = try sent(&recorder, l2cap.DISCONNECTION_REQUEST);
    signalIn(&layer, 0x0042, l2cap.DISCONNECTION_RESPONSE, ending.ident, &.{ 0x50, 0x00, 0x40, 0x00 });
    connections.release(&layer, index);
    sdp_client.release(&layer);
    // More than the room holds.
    const begun = sdp_client.query(&layer, peer, room[0..16]);
    const asked = try sent(&recorder, l2cap.CONNECTION_REQUEST);
    signalIn(&layer, 0x0042, l2cap.CONNECTION_RESPONSE, asked.ident, &.{ 0x51, 0x00, 0x41, 0x00, 0x00, 0x00, 0x00, 0x00 });
    try configured(&layer, &recorder, 0x0042, 0x0041, 0x0051, 672);
    // Each query's transactions begin at 1.
    sdpIn(&layer, 0x0041, sdp.SDP_SERVICE_SEARCH_ATTRIBUTE_RESPONSE, 1, &([_]u8{ 0, serial_records.len } ++ serial_records ++ [_]u8{0}));
    try testing.expectEqual(bluetooth.BTERR_NOMEM, layer.waits[begun.waiting].result);
    ending = try sent(&recorder, l2cap.DISCONNECTION_REQUEST);
    signalIn(&layer, 0x0042, l2cap.DISCONNECTION_RESPONSE, ending.ident, &.{ 0x51, 0x00, 0x41, 0x00 });
    connections.release(&layer, begun.waiting);
    sdp_client.release(&layer);
    // No answer in ten seconds.
    index = (sdp_client.query(&layer, peer, &room)).waiting;
    const again = try sent(&recorder, l2cap.CONNECTION_REQUEST);
    signalIn(&layer, 0x0042, l2cap.CONNECTION_RESPONSE, again.ident, &.{ 0x52, 0x00, 0x42, 0x00, 0x00, 0x00, 0x00, 0x00 });
    try configured(&layer, &recorder, 0x0042, 0x0042, 0x0052, 672);
    layer.now += sdp_client.ANSWER_WAIT_MS;
    _hci.tick(&layer);
    try testing.expectEqual(bluetooth.BTERR_TIMEOUT, layer.waits[index].result);
    connections.release(&layer, index);
    sdp_client.release(&layer);
    // Its channel closed by the device before the answer is whole.
    ending = try sent(&recorder, l2cap.DISCONNECTION_REQUEST);
    signalIn(&layer, 0x0042, l2cap.DISCONNECTION_RESPONSE, ending.ident, &.{ 0x52, 0x00, 0x42, 0x00 });
    index = (sdp_client.query(&layer, peer, &room)).waiting;
    const closed = try sent(&recorder, l2cap.CONNECTION_REQUEST);
    signalIn(&layer, 0x0042, l2cap.CONNECTION_RESPONSE, closed.ident, &.{ 0x53, 0x00, 0x43, 0x00, 0x00, 0x00, 0x00, 0x00 });
    try configured(&layer, &recorder, 0x0042, 0x0043, 0x0053, 672);
    signalIn(&layer, 0x0042, l2cap.DISCONNECTION_REQUEST, 40, &.{ 0x43, 0x00, 0x53, 0x00 });
    try testing.expectEqual(bluetooth.BTERR_REFUSED, layer.waits[index].result);
    connections.release(&layer, index);
    sdp_client.release(&layer);
    // A device without an SDP server.
    index = (sdp_client.query(&layer, peer, &room)).waiting;
    const refused = try sent(&recorder, l2cap.CONNECTION_REQUEST);
    signalIn(&layer, 0x0042, l2cap.CONNECTION_RESPONSE, refused.ident, &.{ 0x00, 0x00, 0x44, 0x00, 0x02, 0x00, 0x00, 0x00 });
    try testing.expectEqual(bluetooth.BTERR_UNSUPPORTED, layer.waits[index].result);
    connections.release(&layer, index);
    sdp_client.release(&layer);
    try testing.expectEqual(@as(usize, 0), channels.count(&layer));
}

test "data elements: read whole or not at all; UUIDs of 16, 32 and 128 bits; held deep in sequences" {
    try testing.expect(_sdp.element(&.{ 0x35, 0x05, 1, 2 }) == null);
    try testing.expect(_sdp.element(&.{ 0x19, 0x11 }) == null);
    try testing.expect(_sdp.element(&.{ 0x36, 0x00 }) == null);
    try testing.expect(_sdp.element(&.{}) == null);
    const nil = _sdp.element(&.{0x00}).?;
    try testing.expectEqual(@as(usize, 1), nil.whole);
    const long = _sdp.element(&.{ 0x37, 0, 0, 0, 3, 0x08, 0x01, 0x00 }).?;
    try testing.expectEqual(@as(usize, 8), long.whole);
    try testing.expectEqual(@as(usize, 3), long.data.len);
    const four = _sdp.element(&.{ 0x1A, 0x00, 0x00, 0x11, 0x01 }).?;
    try testing.expectEqual(@as(u16, 0x1101), _sdp.short(_sdp.uuid(four).?));
    var own: [17]u8 = @splat(0x42);
    own[0] = 0x1C;
    try testing.expectEqual(@as(u16, 0), _sdp.short(_sdp.uuid(_sdp.element(&own).?).?));
    try testing.expect(_sdp.uuid(_sdp.element(&.{ 0x09, 0x11, 0x01 }).?) == null);
    try testing.expectEqual(@as(?u32, 0x0102), _sdp.unsigned(_sdp.element(&.{ 0x09, 0x01, 0x02 }).?));
    // RFCOMM is in the record's protocol list, two sequences down; BNEP
    // is not.
    const body = _sdp.element(&serial_record).?.data;
    try testing.expect(_sdp.holds(body, _sdp.uuid(_sdp.element(&_sdp.uuid16(sdp.UUID_RFCOMM)).?).?));
    try testing.expect(!_sdp.holds(body, _sdp.uuid(_sdp.element(&_sdp.uuid16(0x000F)).?).?));
}
