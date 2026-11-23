// SPDX-License-Identifier: MIT
//! Host tests of a controller's pairings, against a controller the test
//! answers by hand, the test standing in for the task and its agent: the
//! library's pairing with a number compared, its link made first; a PIN's
//! pairing; a device's pairing with nothing to compare, its agent saying
//! no; a device's pairing without an agent; a bonded device's link made
//! secure, and one whose device lost the bond; too short a key; an agent
//! that does not answer, one that goes; a pairing that made its link and
//! no bond, and one on a link there before; the calls' refusals; a bond
//! ended; the bond file written and read again.

const std = @import("std");
const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const hcidev = sdk.devices.hci;
const Scanner = sdk.dos.keywords.Scanner;
const _hci = @import("../hci/_hci.zig");
const Hci = _hci.Hci;
const acl = @import("../hci/acl.zig");
const bonds = @import("../hci/bonds.zig");
const connections = @import("../hci/connections.zig");
const channels = @import("../l2cap/channels.zig");
const pairing = @import("../hci/pairing.zig");
const bondfiles = @import("../task/bondfiles.zig");

const testing = std.testing;

/// A controller that keeps the commands it is sent; the test answers
/// them.
const Recorder = struct {
    commands: [48]Command = undefined,
    command_count: usize = 0,

    const Command = struct {
        opcode: u16,
        length: usize,
        params: [hci.HCI_MAX_PARAMS]u8,

        fn bytes(command: *const Command) []const u8 {
            return command.params[0..command.length];
        }
    };

    fn send(context: *anyopaque, packet_type: u8, bytes: []const u8) bool {
        const recorder: *Recorder = @ptrCast(@alignCast(context));
        if (packet_type != hcidev.HCI_COMMAND_PKT) return true;
        const command = &recorder.commands[recorder.command_count];
        command.opcode = _hci.le16(bytes[0..2]);
        command.length = bytes[2];
        @memcpy(command.params[0..command.length], bytes[hci.HCI_COMMAND_HDR..]);
        recorder.command_count += 1;
        return true;
    }

    fn last(recorder: *const Recorder) *const Command {
        return &recorder.commands[recorder.command_count - 1];
    }
};

/// A layer up, BR/EDR and LE, taking every command.
fn upLayer(recorder: *Recorder) Hci {
    var layer = Hci{ .port = .{ .context = recorder, .send = Recorder.send } };
    layer.state = bluetooth.BTCS_UP;
    layer.features[0] = .{ 0xBF, 0xFE, 0xCF, 0xFE, 0xDB, 0xFF, 0x7B, 0x87 };
    layer.credits = 4;
    layer.now = 100_000;
    layer.acl_mtu = 1021;
    layer.acl_packets = 6;
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

/// The command sent last answered as done: by Command Status where an
/// event answers it, by Command Complete otherwise.
fn done(layer: *Hci, recorder: *const Recorder) void {
    const opcode = recorder.last().opcode;
    switch (opcode) {
        hci.HCI_OP_CREATE_CONNECTION,
        hci.HCI_OP_AUTHENTICATION_REQUESTED,
        hci.HCI_OP_SET_CONNECTION_ENCRYPTION,
        hci.HCI_OP_REMOTE_NAME_REQUEST,
        hci.HCI_OP_DISCONNECT,
        => status(layer, opcode, 0),
        else => complete(layer, opcode, &.{0}),
    }
}

/// The command sent last: its opcode and parameters checked, then
/// answered as done.
fn expectSent(layer: *Hci, recorder: *const Recorder, opcode: u16, params: []const u8) !void {
    try testing.expectEqual(opcode, recorder.last().opcode);
    try testing.expectEqualSlices(u8, params, recorder.last().bytes());
    done(layer, recorder);
}

fn connectionComplete(layer: *Hci, handle: u16, address: [6]u8) void {
    var params: [11]u8 = undefined;
    params[0] = 0;
    params[1] = @truncate(handle);
    params[2] = @truncate(handle >> 8);
    params[3..9].* = address;
    params[9] = hci.LINK_ACL;
    params[10] = 0;
    event(layer, hci.HCI_EV_CONNECTION_COMPLETE, &params);
}

/// A BR/EDR link to `address` made by the library and up as `handle`.
fn linked(layer: *Hci, recorder: *Recorder, address: bluetooth.BTAddress, handle: u16) !void {
    const begun = connections.connect(layer, address);
    try testing.expect(begun == .waiting);
    done(layer, recorder);
    connectionComplete(layer, handle, address.bytes);
    try testing.expect(layer.waits[begun.waiting].done);
    connections.release(layer, begun.waiting);
    if (recorder.last().opcode == hci.HCI_OP_REMOTE_NAME_REQUEST) done(layer, recorder);
}

fn withAddress(address: bluetooth.BTAddress, rest: []const u8) [hci.HCI_MAX_PARAMS]u8 {
    var params: [hci.HCI_MAX_PARAMS]u8 = @splat(0);
    params[0..6].* = address.bytes;
    @memcpy(params[6..][0..rest.len], rest);
    return params;
}

fn addressed(layer: *Hci, code: u8, address: bluetooth.BTAddress, rest: []const u8) void {
    const params = withAddress(address, rest);
    event(layer, code, params[0 .. 6 + rest.len]);
}

fn handled(layer: *Hci, code: u8, code_status: u8, handle: u16, rest: []const u8) void {
    var params: [8]u8 = undefined;
    params[0] = code_status;
    params[1] = @truncate(handle);
    params[2] = @truncate(handle >> 8);
    @memcpy(params[3..][0..rest.len], rest);
    event(layer, code, params[0 .. 3 + rest.len]);
}

/// The task's part: the link's question sent to its agent in `message`.
fn sent(layer: *Hci, address: bluetooth.BTAddress, message: *anyopaque) *pairing.Question {
    const question = &connections.find(layer, address).?.pairing.question;
    question.sent = true;
    question.message = message;
    return question;
}

/// A link authenticated with its pairing done, encrypted, and the key's
/// size read as `size`.
fn secured(layer: *Hci, recorder: *Recorder, handle: u16, size: u8) !void {
    handled(layer, hci.HCI_EV_AUTHENTICATION_COMPLETE, 0, handle, &.{});
    try expectSent(layer, recorder, hci.HCI_OP_SET_CONNECTION_ENCRYPTION, &.{ @truncate(handle), @truncate(handle >> 8), 1 });
    handled(layer, hci.HCI_EV_ENCRYPTION_CHANGE, 0, handle, &.{1});
    try testing.expectEqual(hci.HCI_OP_READ_ENCRYPTION_KEY_SIZE, recorder.last().opcode);
    complete(layer, hci.HCI_OP_READ_ENCRYPTION_KEY_SIZE, &.{ 0, @truncate(handle), @truncate(handle >> 8), size });
}

const peer = bluetooth.BTAddress{ .bytes = .{ 0x01, 0x10, 0xEF, 0x5E, 0x00, 0x00 } };
const key = [hci.LINK_KEY_SIZE]u8{ 0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF };

fn expectNotice(layer: *const Hci, kind: pairing.NoticeKind, agent: u32, ours: bool, result: i32) !void {
    try testing.expectEqual(@as(u8, 1), layer.notice_count);
    const item = layer.notices[0];
    try testing.expectEqual(kind, item.kind);
    try testing.expectEqual(agent, item.agent);
    try testing.expectEqual(ours, item.ours);
    try testing.expectEqual(result, item.result);
}

test "the library's pairing: its link made, a number compared, the bond kept, the link encrypted" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try testing.expectEqual(@as(i32, 0), pairing.pair(&layer, peer, 7, bluetooth.BTIO_DISPLAYYESNO));
    try testing.expectEqual(hci.HCI_OP_CREATE_CONNECTION, recorder.last().opcode);
    done(&layer, &recorder);
    connectionComplete(&layer, 0x0B, peer.bytes);
    try authenticating(&layer, &recorder, 0x0B);
    const connection = connections.find(&layer, peer).?;
    try testing.expectEqual(pairing.Stage.authenticating, connection.pairing.stage);

    addressed(&layer, hci.HCI_EV_LINK_KEY_REQUEST, peer, &.{});
    try expectSent(&layer, &recorder, hci.HCI_OP_LINK_KEY_NEGATIVE_REPLY, &peer.bytes);
    addressed(&layer, hci.HCI_EV_IO_CAPABILITY_REQUEST, peer, &.{});
    try expectSent(&layer, &recorder, hci.HCI_OP_IO_CAPABILITY_REPLY, withAddress(peer, &.{ hci.IO_DISPLAY_YES_NO, 0, hci.AUTH_DEDICATED_BONDING | hci.AUTH_MITM })[0..9]);
    addressed(&layer, hci.HCI_EV_IO_CAPABILITY_RESPONSE, peer, &.{ hci.IO_DISPLAY_YES_NO, 0, hci.AUTH_GENERAL_BONDING | hci.AUTH_MITM });
    // 123456: the agent asked.
    const sent_before = recorder.command_count;
    addressed(&layer, hci.HCI_EV_USER_CONFIRMATION_REQUEST, peer, &.{ 0x40, 0xE2, 0x01, 0x00 });
    try testing.expectEqual(sent_before, recorder.command_count);
    try testing.expectEqual(bluetooth.BTAK_CONFIRM, connection.pairing.question.kind);
    try testing.expectEqual(@as(u32, 123456), connection.pairing.question.number);
    var message: u8 = 0;
    _ = sent(&layer, peer, &message);
    try testing.expect(pairing.agentAnswered(&layer, &message, true, 0, &.{}));
    try expectSent(&layer, &recorder, hci.HCI_OP_USER_CONFIRMATION_REPLY, &peer.bytes);
    // A second answer finds no question.
    try testing.expect(!pairing.agentAnswered(&layer, &message, true, 0, &.{}));

    event(&layer, hci.HCI_EV_SIMPLE_PAIRING_COMPLETE, &([_]u8{0} ++ peer.bytes));
    addressed(&layer, hci.HCI_EV_LINK_KEY_NOTIFICATION, peer, &(key ++ [_]u8{hci.LINK_KEY_AUTHENTICATED_P192}));
    const bond = bonds.find(&layer, peer).?;
    try testing.expectEqualSlices(u8, &key, &bond.key);
    try testing.expect(bond.dirty and layer.bonds_changed);
    try testing.expect(bonds.authenticated(bond));
    try testing.expectEqual(@as(u8, 0), layer.notice_count);

    try secured(&layer, &recorder, 0x0B, 16);
    try testing.expect(connection.authenticated and connection.encrypted);
    try testing.expectEqual(pairing.Stage.idle, connection.pairing.stage);
    try expectNotice(&layer, .done, 7, true, 0);
    try testing.expectEqual(connections.NoteKind.paired, layer.notes[layer.note_count - 1].kind);
}

test "a PIN's pairing: the agent's PIN given, the bond kept as a PIN's" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try linked(&layer, &recorder, peer, 0x0C);
    try testing.expectEqual(@as(i32, 0), pairing.pair(&layer, peer, 3, bluetooth.BTIO_KEYBOARDDISPLAY));
    try expectSent(&layer, &recorder, hci.HCI_OP_AUTHENTICATION_REQUESTED, &.{ 0x0C, 0 });
    addressed(&layer, hci.HCI_EV_LINK_KEY_REQUEST, peer, &.{});
    done(&layer, &recorder);
    addressed(&layer, hci.HCI_EV_PIN_CODE_REQUEST, peer, &.{});
    const connection = connections.find(&layer, peer).?;
    try testing.expectEqual(bluetooth.BTAK_PIN, connection.pairing.question.kind);
    var message: u8 = 0;
    _ = sent(&layer, peer, &message);
    try testing.expect(pairing.agentAnswered(&layer, &message, true, 0, "0000"));
    var pin: [17]u8 = @splat(0);
    pin[0] = 4;
    @memcpy(pin[1..5], "0000");
    try expectSent(&layer, &recorder, hci.HCI_OP_PIN_CODE_REPLY, withAddress(peer, &pin)[0..23]);
    addressed(&layer, hci.HCI_EV_LINK_KEY_NOTIFICATION, peer, &(key ++ [_]u8{hci.LINK_KEY_COMBINATION}));
    const bond = bonds.find(&layer, peer).?;
    try testing.expect(bond.legacy and bonds.authenticated(bond));
    try secured(&layer, &recorder, 0x0C, 16);
    try expectNotice(&layer, .done, 3, true, 0);
}

test "a device's pairing with nothing to compare: the agent asked whether it may, and saying no" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try linked(&layer, &recorder, peer, 0x0D);
    layer.agent_current = 9;
    layer.agent_capability = bluetooth.BTIO_DISPLAYYESNO;
    // The device's capability comes first: it began.
    addressed(&layer, hci.HCI_EV_IO_CAPABILITY_RESPONSE, peer, &.{ hci.IO_NO_INPUT_OUTPUT, 0, hci.AUTH_GENERAL_BONDING });
    addressed(&layer, hci.HCI_EV_IO_CAPABILITY_REQUEST, peer, &.{});
    try expectSent(&layer, &recorder, hci.HCI_OP_IO_CAPABILITY_REPLY, withAddress(peer, &.{ hci.IO_DISPLAY_YES_NO, 0, hci.AUTH_GENERAL_BONDING })[0..9]);
    addressed(&layer, hci.HCI_EV_USER_CONFIRMATION_REQUEST, peer, &.{ 0xF1, 0xFB, 0x09, 0x00 });
    const connection = connections.find(&layer, peer).?;
    try testing.expectEqual(bluetooth.BTAK_CONFIRM, connection.pairing.question.kind);
    try testing.expectEqual(bluetooth.BT_NO_NUMBER, connection.pairing.question.number);
    try testing.expect(!connection.pairing.ours);
    var message: u8 = 0;
    _ = sent(&layer, peer, &message);
    try testing.expect(pairing.agentAnswered(&layer, &message, false, 0, &.{}));
    try expectSent(&layer, &recorder, hci.HCI_OP_USER_CONFIRMATION_NEGATIVE_REPLY, &peer.bytes);
    event(&layer, hci.HCI_EV_SIMPLE_PAIRING_COMPLETE, &([_]u8{hci.HCI_ERR_AUTHENTICATION_FAILURE} ++ peer.bytes));
    try expectNotice(&layer, .done, 9, false, bluetooth.BTERR_REFUSED);
    try testing.expect(bonds.find(&layer, peer) == null);
    try testing.expectEqual(connections.NoteKind.not_paired, layer.notes[layer.note_count - 1].kind);
}

test "a device's pairing without an agent, by Secure Simple Pairing or a PIN, refused" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try linked(&layer, &recorder, peer, 0x0E);
    addressed(&layer, hci.HCI_EV_IO_CAPABILITY_REQUEST, peer, &.{});
    try expectSent(&layer, &recorder, hci.HCI_OP_IO_CAPABILITY_NEGATIVE_REPLY, withAddress(peer, &.{hci.HCI_ERR_PAIRING_NOT_ALLOWED})[0..7]);
    addressed(&layer, hci.HCI_EV_PIN_CODE_REQUEST, peer, &.{});
    try expectSent(&layer, &recorder, hci.HCI_OP_PIN_CODE_NEGATIVE_REPLY, &peer.bytes);
    try testing.expectEqual(pairing.Stage.idle, connections.find(&layer, peer).?.pairing.stage);
}

test "a device's pairing that wants no bond: answered alike, its key not kept" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try linked(&layer, &recorder, peer, 0x0F);
    layer.agent_current = 2;
    layer.agent_capability = bluetooth.BTIO_NOINPUTNOOUTPUT;
    addressed(&layer, hci.HCI_EV_IO_CAPABILITY_RESPONSE, peer, &.{ hci.IO_DISPLAY_YES_NO, 0, hci.AUTH_NO_BONDING | hci.AUTH_MITM });
    addressed(&layer, hci.HCI_EV_IO_CAPABILITY_REQUEST, peer, &.{});
    try expectSent(&layer, &recorder, hci.HCI_OP_IO_CAPABILITY_REPLY, withAddress(peer, &.{ hci.IO_NO_INPUT_OUTPUT, 0, hci.AUTH_NO_BONDING })[0..9]);
    // The agent cannot answer: accepted at once.
    addressed(&layer, hci.HCI_EV_USER_CONFIRMATION_REQUEST, peer, &.{ 1, 0, 0, 0 });
    try expectSent(&layer, &recorder, hci.HCI_OP_USER_CONFIRMATION_REPLY, &peer.bytes);
    event(&layer, hci.HCI_EV_SIMPLE_PAIRING_COMPLETE, &([_]u8{0} ++ peer.bytes));
    addressed(&layer, hci.HCI_EV_LINK_KEY_NOTIFICATION, peer, &(key ++ [_]u8{hci.LINK_KEY_UNAUTHENTICATED_P192}));
    try testing.expect(bonds.find(&layer, peer) == null);
    try expectNotice(&layer, .done, 2, false, 0);
}

test "a bonded device's link made secure before its call is answered, and one whose device lost the bond" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    _ = bonds.keep(&layer, peer, &key, hci.LINK_KEY_AUTHENTICATED_P192, false, 0, "Phone").?;
    const begun = connections.connect(&layer, peer);
    done(&layer, &recorder);
    connectionComplete(&layer, 0x10, peer.bytes);
    try testing.expect(!layer.waits[begun.waiting].done);
    try authenticating(&layer, &recorder, 0x10);
    // A second call waits as well.
    const second = connections.connect(&layer, peer);
    try testing.expect(second == .waiting);
    addressed(&layer, hci.HCI_EV_LINK_KEY_REQUEST, peer, &.{});
    var reply: [22]u8 = undefined;
    reply[0..6].* = peer.bytes;
    reply[6..22].* = key;
    try expectSent(&layer, &recorder, hci.HCI_OP_LINK_KEY_REPLY, &reply);
    try secured(&layer, &recorder, 0x10, 16);
    try testing.expect(layer.waits[begun.waiting].done and layer.waits[second.waiting].done);
    try testing.expectEqual(@as(i32, 0), layer.waits[begun.waiting].result);
    try testing.expectEqual(@as(u8, 0), layer.notice_count);
    connections.release(&layer, begun.waiting);
    connections.release(&layer, second.waiting);

    // Again, the device without the bond now.
    disconnect(&layer, &recorder, 0x10);
    const again = connections.connect(&layer, peer);
    done(&layer, &recorder);
    connectionComplete(&layer, 0x11, peer.bytes);
    try authenticating(&layer, &recorder, 0x11);
    addressed(&layer, hci.HCI_EV_LINK_KEY_REQUEST, peer, &.{});
    done(&layer, &recorder);
    handled(&layer, hci.HCI_EV_AUTHENTICATION_COMPLETE, hci.HCI_ERR_PIN_OR_KEY_MISSING, 0x11, &.{});
    try testing.expect(layer.waits[again.waiting].done);
    try testing.expectEqual(@as(i32, hci.HCI_ERR_PIN_OR_KEY_MISSING), layer.waits[again.waiting].result);
    try testing.expectEqual(connections.State.up, connections.find(&layer, peer).?.state);
    try testing.expectEqual(connections.NoteKind.not_secured, layer.notes[layer.note_count - 1].kind);
}

/// A link just up being authenticated: Authentication Requested sent,
/// then the device's name asked for - both answered.
fn authenticating(layer: *Hci, recorder: *Recorder, handle: u16) !void {
    try testing.expectEqual(hci.HCI_OP_REMOTE_NAME_REQUEST, recorder.last().opcode);
    done(layer, recorder);
    const asked = &recorder.commands[recorder.command_count - 2];
    try testing.expectEqual(hci.HCI_OP_AUTHENTICATION_REQUESTED, asked.opcode);
    try testing.expectEqualSlices(u8, &.{ @truncate(handle), @truncate(handle >> 8) }, asked.bytes());
    status(layer, hci.HCI_OP_AUTHENTICATION_REQUESTED, 0);
}

fn disconnect(layer: *Hci, recorder: *Recorder, handle: u16) void {
    _ = connections.disconnect(layer, peer);
    done(layer, recorder);
    event(layer, hci.HCI_EV_DISCONNECTION_COMPLETE, &.{ 0, @truncate(handle), @truncate(handle >> 8), hci.HCI_ERR_LOCAL_HOST_TERMINATED });
    for (&layer.waits) |*wait| wait.* = .{};
}

test "a channel to a bonded device asked for once its link is made secure" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    _ = bonds.keep(&layer, peer, &key, hci.LINK_KEY_AUTHENTICATED_P192, false, 0, "Phone").?;
    const begun = channels.open(&layer, peer, 0x1001);
    try testing.expect(begun == .waiting);
    const record = channels.bySerial(&layer, layer.waits[begun.waiting].serial).?;
    done(&layer, &recorder);
    connectionComplete(&layer, 0x10, peer.bytes);
    try authenticating(&layer, &recorder, 0x10);
    // Not asked for while the link is authenticated and encrypted.
    try testing.expectEqual(channels.State.linking, record.state);
    addressed(&layer, hci.HCI_EV_LINK_KEY_REQUEST, peer, &.{});
    var reply: [22]u8 = undefined;
    reply[0..6].* = peer.bytes;
    reply[6..22].* = key;
    try expectSent(&layer, &recorder, hci.HCI_OP_LINK_KEY_REPLY, &reply);
    try testing.expectEqual(channels.State.linking, record.state);
    try secured(&layer, &recorder, 0x10, 16);
    try testing.expectEqual(channels.State.connecting, record.state);
    try testing.expectEqual(@as(u16, 0x10), record.handle);
}

test "too short an encryption key: the link ended, the pairing failed" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try linked(&layer, &recorder, peer, 0x12);
    try testing.expectEqual(@as(i32, 0), pairing.pair(&layer, peer, 4, null));
    done(&layer, &recorder);
    addressed(&layer, hci.HCI_EV_IO_CAPABILITY_REQUEST, peer, &.{});
    // No agent: nothing shown, nothing asked.
    try expectSent(&layer, &recorder, hci.HCI_OP_IO_CAPABILITY_REPLY, withAddress(peer, &.{ hci.IO_NO_INPUT_OUTPUT, 0, hci.AUTH_DEDICATED_BONDING })[0..9]);
    addressed(&layer, hci.HCI_EV_IO_CAPABILITY_RESPONSE, peer, &.{ hci.IO_DISPLAY_YES_NO, 0, hci.AUTH_DEDICATED_BONDING });
    addressed(&layer, hci.HCI_EV_USER_CONFIRMATION_REQUEST, peer, &.{ 5, 0, 0, 0 });
    try expectSent(&layer, &recorder, hci.HCI_OP_USER_CONFIRMATION_REPLY, &peer.bytes);
    addressed(&layer, hci.HCI_EV_LINK_KEY_NOTIFICATION, peer, &(key ++ [_]u8{hci.LINK_KEY_UNAUTHENTICATED_P192}));
    try testing.expect(bonds.find(&layer, peer) != null);
    try secured(&layer, &recorder, 0x12, 5);
    try testing.expectEqual(hci.HCI_OP_DISCONNECT, recorder.last().opcode);
    try testing.expectEqualSlices(u8, &.{ 0x12, 0, hci.HCI_ERR_AUTHENTICATION_FAILURE }, recorder.last().bytes());
    try expectNotice(&layer, .done, 4, true, hci.HCI_ERR_INSUFFICIENT_SECURITY);
}

test "an agent that does not answer, and one that goes: refused" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try linked(&layer, &recorder, peer, 0x13);
    try testing.expectEqual(@as(i32, 0), pairing.pair(&layer, peer, 5, bluetooth.BTIO_DISPLAYYESNO));
    done(&layer, &recorder);
    addressed(&layer, hci.HCI_EV_IO_CAPABILITY_REQUEST, peer, &.{});
    done(&layer, &recorder);
    addressed(&layer, hci.HCI_EV_IO_CAPABILITY_RESPONSE, peer, &.{ hci.IO_DISPLAY_YES_NO, 0, hci.AUTH_DEDICATED_BONDING | hci.AUTH_MITM });
    addressed(&layer, hci.HCI_EV_USER_CONFIRMATION_REQUEST, peer, &.{ 7, 0, 0, 0 });
    var message: u8 = 0;
    _ = sent(&layer, peer, &message);
    try testing.expectEqual(@as(?u64, layer.now + pairing.QUESTION_WAIT_MS), pairing.deadline(&layer));
    layer.now += pairing.QUESTION_WAIT_MS;
    _hci.tick(&layer);
    try expectSent(&layer, &recorder, hci.HCI_OP_USER_CONFIRMATION_NEGATIVE_REPLY, &peer.bytes);
    // Its answer, late, let go.
    try testing.expect(!pairing.agentAnswered(&layer, &message, true, 0, &.{}));
    handled(&layer, hci.HCI_EV_AUTHENTICATION_COMPLETE, hci.HCI_ERR_AUTHENTICATION_FAILURE, 0x13, &.{});
    try expectNotice(&layer, .done, 5, true, bluetooth.BTERR_REFUSED);

    // The agent goes while it is asked: refused at once, and told nothing.
    layer.notice_count = 0;
    try testing.expectEqual(@as(i32, 0), pairing.pair(&layer, peer, 6, bluetooth.BTIO_DISPLAYYESNO));
    done(&layer, &recorder);
    addressed(&layer, hci.HCI_EV_IO_CAPABILITY_REQUEST, peer, &.{});
    done(&layer, &recorder);
    addressed(&layer, hci.HCI_EV_IO_CAPABILITY_RESPONSE, peer, &.{ hci.IO_DISPLAY_YES_NO, 0, hci.AUTH_DEDICATED_BONDING | hci.AUTH_MITM });
    addressed(&layer, hci.HCI_EV_USER_CONFIRMATION_REQUEST, peer, &.{ 8, 0, 0, 0 });
    pairing.agentGone(&layer, 6);
    try expectSent(&layer, &recorder, hci.HCI_OP_USER_CONFIRMATION_NEGATIVE_REPLY, &peer.bytes);
    handled(&layer, hci.HCI_EV_AUTHENTICATION_COMPLETE, hci.HCI_ERR_AUTHENTICATION_FAILURE, 0x13, &.{});
    try testing.expectEqual(@as(u8, 0), layer.notice_count);
}

test "a pairing that made its link and no bond: the link ended IDLE_MS after; one there before stays" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try testing.expectEqual(@as(i32, 0), pairing.pair(&layer, peer, 7, bluetooth.BTIO_DISPLAYYESNO));
    try testing.expectEqual(hci.HCI_OP_CREATE_CONNECTION, recorder.last().opcode);
    done(&layer, &recorder);
    connectionComplete(&layer, 0x0B, peer.bytes);
    try authenticating(&layer, &recorder, 0x0B);
    // The device does not pair now.
    handled(&layer, hci.HCI_EV_AUTHENTICATION_COMPLETE, hci.HCI_ERR_PAIRING_NOT_ALLOWED, 0x0B, &.{});
    try expectNotice(&layer, .done, 7, true, hci.HCI_ERR_PAIRING_NOT_ALLOWED);
    try testing.expectEqual(@as(?u64, layer.now + connections.IDLE_MS), connections.find(&layer, peer).?.idle_until);
    layer.now += connections.IDLE_MS;
    _hci.tick(&layer);
    try testing.expectEqual(hci.HCI_OP_DISCONNECT, recorder.last().opcode);
    try testing.expectEqualSlices(u8, &.{ 0x0B, 0, hci.HCI_ERR_REMOTE_USER_TERMINATED }, recorder.last().bytes());
    done(&layer, &recorder);
    event(&layer, hci.HCI_EV_DISCONNECTION_COMPLETE, &.{ 0, 0x0B, 0, hci.HCI_ERR_LOCAL_HOST_TERMINATED });

    // A link there before the pairing stays after it.
    layer.notice_count = 0;
    try linked(&layer, &recorder, peer, 0x0C);
    try testing.expectEqual(@as(i32, 0), pairing.pair(&layer, peer, 7, bluetooth.BTIO_DISPLAYYESNO));
    try testing.expectEqual(hci.HCI_OP_AUTHENTICATION_REQUESTED, recorder.last().opcode);
    done(&layer, &recorder);
    handled(&layer, hci.HCI_EV_AUTHENTICATION_COMPLETE, hci.HCI_ERR_PAIRING_NOT_ALLOWED, 0x0C, &.{});
    try expectNotice(&layer, .done, 7, true, hci.HCI_ERR_PAIRING_NOT_ALLOWED);
    try testing.expectEqual(@as(?u64, null), connections.find(&layer, peer).?.idle_until);
}

test "a pairing refused: not up, off, LE, bonded already, being paired" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    const le_device = bluetooth.BTAddress{ .bytes = peer.bytes, .kind = bluetooth.BTADDR_LE_PUBLIC };
    try testing.expectEqual(bluetooth.BTERR_UNSUPPORTED, pairing.pair(&layer, le_device, 1, null));
    try testing.expectEqual(@as(i32, 0), pairing.pair(&layer, peer, 1, null));
    try testing.expectEqual(bluetooth.BTERR_BUSY, pairing.pair(&layer, peer, 1, null));
    const other = bluetooth.BTAddress{ .bytes = .{ 0x02, 0x10, 0xEF, 0x5E, 0x00, 0x00 } };
    _ = bonds.keep(&layer, other, &key, hci.LINK_KEY_UNAUTHENTICATED_P256, false, 0, "").?;
    try testing.expectEqual(bluetooth.BTERR_BONDED, pairing.pair(&layer, other, 1, null));
    layer.powered = false;
    try testing.expectEqual(bluetooth.BTERR_OFF, pairing.pair(&layer, other, 1, null));
    layer.state = bluetooth.BTCS_STARTING;
    try testing.expectEqual(bluetooth.BTERR_NOTUP, pairing.pair(&layer, other, 1, null));
}

test "a bond ended: its link ended, its place freed once its file is deleted" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try linked(&layer, &recorder, peer, 0x14);
    _ = bonds.keep(&layer, peer, &key, hci.LINK_KEY_AUTHENTICATED_P256, false, 0x5A020C, "Phone").?;
    while (bonds.nextDirty(&layer)) |bond| bonds.written(bond);
    try testing.expect(!layer.bonds_changed);
    try testing.expectEqual(@as(i32, 0), pairing.unpair(&layer, peer));
    try testing.expectEqual(bluetooth.BTERR_NOTBONDED, pairing.unpair(&layer, peer));
    try testing.expectEqual(hci.HCI_OP_DISCONNECT, recorder.last().opcode);
    try testing.expect(bonds.find(&layer, peer) == null);
    const gone = bonds.nextDirty(&layer).?;
    try testing.expect(gone.gone);
    bonds.written(gone);
    try testing.expect(!gone.used);
    try testing.expect(bonds.nextDirty(&layer) == null);
    try testing.expect(!layer.bonds_changed);
}

test "a full table keeps no new bond" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    for (0..bonds.BONDS) |index| {
        const device = bluetooth.BTAddress{ .bytes = .{ @intCast(index), 0x20, 0xEF, 0x5E, 0x00, 0x00 } };
        try testing.expect(bonds.keep(&layer, device, &key, hci.LINK_KEY_COMBINATION, true, 0, "") != null);
    }
    try testing.expect(bonds.keep(&layer, peer, &key, hci.LINK_KEY_COMBINATION, true, 0, "") == null);
    // A new key for one there is still kept.
    const first = bluetooth.BTAddress{ .bytes = .{ 0, 0x20, 0xEF, 0x5E, 0x00, 0x00 } };
    try testing.expect(bonds.keep(&layer, first, &key, hci.LINK_KEY_AUTHENTICATED_P256, false, 0, "") != null);
}

test "a bond's file: written, and read back the same" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    const bond = bonds.keep(&layer, peer, &key, hci.LINK_KEY_AUTHENTICATED_P192, false, 0x5A020C, "Ph\"one\x01").?;
    var text: [bondfiles.TEXT_MOST]u8 = undefined;
    const length = bondfiles.format(bond, &text);
    try testing.expectEqualStrings(
        "/* bluetooth.library's bond with the device of this name */\n" ++
            "Name = \"Ph'one \"\nClass = 0x5A020C\nLinkKey = 1032547698BADCFE0123456789ABCDEF\nKeyType = 5\nLegacy = NO\n",
        text[0..length],
    );
    var scanner = Scanner.ofText(text[0..length]);
    var read = bonds.Bond{};
    try testing.expect(bondfiles.parse(&scanner, &read));
    try testing.expectEqualSlices(u8, &key, &read.key);
    try testing.expectEqual(@as(u8, hci.LINK_KEY_AUTHENTICATED_P192), read.key_type);
    try testing.expectEqual(@as(u32, 0x5A020C), read.class_of_device);
    try testing.expect(!read.legacy);
    try testing.expectEqualStrings("Ph'one ", std.mem.sliceTo(&read.name, 0));
    // Without a whole key, no bond.
    var short = Scanner.ofText("LinkKey = 0011\nKeyType = 4\n");
    try testing.expect(!bondfiles.parse(&short, &read));
    try testing.expectEqual(@as(?bluetooth.BTAddress, peer), bondfiles.addressOf("00005EEF1001"));
    try testing.expectEqual(@as(?bluetooth.BTAddress, null), bondfiles.addressOf("settings"));
    try testing.expectEqual(@as(?bluetooth.BTAddress, null), bondfiles.addressOf("00005EEF100G"));
    try testing.expectEqual(@as(?bluetooth.BTAddress, null), bondfiles.addressOf("00005EEF1001.lee"));
    const le_peer = bluetooth.BTAddress{ .bytes = peer.bytes, .kind = bluetooth.BTADDR_LE_PUBLIC };
    try testing.expectEqual(@as(?bluetooth.BTAddress, le_peer), bondfiles.addressOf("00005EEF1001.le"));
    const random_peer = bluetooth.BTAddress{ .bytes = peer.bytes, .kind = bluetooth.BTADDR_LE_RANDOM };
    try testing.expectEqual(@as(?bluetooth.BTAddress, random_peer), bondfiles.addressOf("00005EEF1001.random"));
}
