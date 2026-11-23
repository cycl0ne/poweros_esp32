// SPDX-License-Identifier: MIT
//! Host tests of bluetooth.library's HCI layer: the bring-up's commands,
//! in order and with their parameters, against a controller that answers
//! from a script; what the answers say kept; the pause for the settings;
//! the steps a controller without LE or without a command is not given;
//! refusals, time-outs, credits, a transport that cannot take a packet,
//! and a hardware error.

const std = @import("std");
const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const hcidev = sdk.devices.hci;
const _hci = @import("../hci/_hci.zig");
const bringup = @import("../hci/bringup.zig");
const Hci = _hci.Hci;

const testing = std.testing;

/// A controller that keeps the commands it is sent, and how it answers
/// the bring-up's questions.
const Script = struct {
    sent: [96]Sent = undefined,
    count: usize = 0,
    /// How many of `sent` have been answered.
    answered: usize = 0,
    /// Whether the transport takes a packet now.
    taking: bool = true,
    /// What it is.
    features: [8]u8 = .{ 0xBF, 0xFE, 0xCF, 0xFE, 0xDB, 0xFF, 0x7B, 0x87 },
    commands: [64]u8 = @splat(0xFF),
    /// Opcodes it refuses, with this status.
    refuse: ?u16 = null,
    refuse_status: u8 = hci.HCI_ERR_UNKNOWN_COMMAND,
    /// Whether it refuses with a Command Status rather than a Command
    /// Complete.
    refuse_by_status: bool = false,

    const Sent = struct {
        opcode: u16,
        length: usize,
        params: [hci.HCI_MAX_PARAMS]u8,
    };

    fn send(context: *anyopaque, packet_type: u8, bytes: []const u8) bool {
        const script: *Script = @ptrCast(@alignCast(context));
        if (!script.taking) return false;
        if (packet_type != hcidev.HCI_COMMAND_PKT or bytes.len < hci.HCI_COMMAND_HDR) unreachable;
        const sent = &script.sent[script.count];
        sent.opcode = _hci.le16(bytes[0..2]);
        sent.length = bytes[2];
        if (sent.length != bytes.len - hci.HCI_COMMAND_HDR) unreachable;
        @memcpy(sent.params[0..sent.length], bytes[hci.HCI_COMMAND_HDR..]);
        script.count += 1;
        return true;
    }

    fn port(script: *Script) _hci.Port {
        return .{ .context = script, .send = send };
    }

    /// Every command sent and not yet answered, answered - and those the
    /// answers make it send, until it sends nothing more; the bring-up's
    /// pause for the settings let go, with the layer's as they are.
    fn run(script: *Script, layer: *Hci) void {
        while (true) {
            while (script.answered < script.count) {
                const sent = script.sent[script.answered];
                script.answered += 1;
                script.answer(layer, sent);
            }
            if (!layer.wants_settings) return;
            bringup.settled(layer);
        }
    }

    fn answer(script: *Script, layer: *Hci, sent: Sent) void {
        if (script.refuse) |opcode| {
            if (opcode == sent.opcode) {
                if (script.refuse_by_status) return status(layer, 1, sent.opcode, script.refuse_status);
                return complete(layer, 1, sent.opcode, &.{script.refuse_status});
            }
        }
        switch (sent.opcode) {
            hci.HCI_OP_READ_LOCAL_VERSION => complete(layer, 1, sent.opcode, &.{ 0, hci.BT_VERSION_5_3, 0x34, 0x12, hci.BT_VERSION_5_3, 70, 0, 0x78, 0x56 }),
            hci.HCI_OP_READ_LOCAL_COMMANDS => {
                var returned: [65]u8 = undefined;
                returned[0] = 0;
                @memcpy(returned[1..], &script.commands);
                complete(layer, 1, sent.opcode, &returned);
            },
            hci.HCI_OP_READ_LOCAL_FEATURES => {
                var returned: [9]u8 = undefined;
                returned[0] = 0;
                @memcpy(returned[1..], &script.features);
                complete(layer, 1, sent.opcode, &returned);
            },
            hci.HCI_OP_READ_LOCAL_EXT_FEATURES => {
                const page = sent.params[0];
                const bits: [8]u8 = if (page == 1) .{ 0x0B, 0, 0, 0, 0, 0, 0, 0 } else .{ 0x30, 0x0B, 0, 0, 0, 0, 0, 0 };
                var returned: [11]u8 = undefined;
                returned[0] = 0;
                returned[1] = page;
                returned[2] = 2;
                @memcpy(returned[3..], &bits);
                complete(layer, 1, sent.opcode, &returned);
            },
            hci.HCI_OP_READ_BUFFER_SIZE => complete(layer, 1, sent.opcode, &.{ 0, 0xFD, 0x03, 64, 6, 0, 0, 0 }),
            hci.HCI_OP_READ_BD_ADDR => complete(layer, 1, sent.opcode, &.{ 0, 0x13, 0x71, 0xDA, 0x7D, 0x1A, 0x00 }),
            hci.HCI_OP_LE_READ_BUFFER_SIZE => complete(layer, 1, sent.opcode, &.{ 0, 251, 0, 15 }),
            hci.HCI_OP_LE_READ_LOCAL_FEATURES => complete(layer, 1, sent.opcode, &.{ 0, 0xFF, 0x59, 0, 0, 0, 0, 0, 0 }),
            else => complete(layer, 1, sent.opcode, &.{0}),
        }
    }

    fn opcodes(script: *const Script, into: []u16) []u16 {
        for (script.sent[0..script.count], 0..) |sent, index| into[index] = sent.opcode;
        return into[0..script.count];
    }
};

fn complete(layer: *Hci, credits: u8, opcode: u16, returned: []const u8) void {
    var packet: [hci.HCI_MAX_EVENT]u8 = undefined;
    packet[0] = hci.HCI_EV_COMMAND_COMPLETE;
    packet[1] = @intCast(3 + returned.len);
    packet[2] = credits;
    packet[3] = @truncate(opcode);
    packet[4] = @truncate(opcode >> 8);
    @memcpy(packet[5..][0..returned.len], returned);
    _hci.received(layer, hcidev.HCI_EVENT_PKT, packet[0 .. 5 + returned.len]);
}

fn status(layer: *Hci, credits: u8, opcode: u16, code: u8) void {
    const packet = [_]u8{ hci.HCI_EV_COMMAND_STATUS, 4, code, credits, @truncate(opcode), @truncate(opcode >> 8) };
    _hci.received(layer, hcidev.HCI_EVENT_PKT, &packet);
}

fn makeLayer(script: *Script) Hci {
    var layer = Hci{ .port = script.port() };
    layer.class_of_device = hci.COD_MAJOR_COMPUTER << 8 | hci.COD_COMPUTER_DESKTOP << 2;
    @memcpy(layer.name[0..4], "nuc\x00");
    return layer;
}

/// The bring-up of a controller with BR/EDR, LE, Secure Simple Pairing,
/// Secure Connections and every command.
const dual_mode = [_]u16{
    hci.HCI_OP_RESET,
    hci.HCI_OP_READ_LOCAL_VERSION,
    hci.HCI_OP_READ_LOCAL_COMMANDS,
    hci.HCI_OP_READ_LOCAL_FEATURES,
    hci.HCI_OP_READ_LOCAL_EXT_FEATURES,
    hci.HCI_OP_READ_LOCAL_EXT_FEATURES,
    hci.HCI_OP_READ_BUFFER_SIZE,
    hci.HCI_OP_READ_BD_ADDR,
    hci.HCI_OP_LE_READ_BUFFER_SIZE,
    hci.HCI_OP_LE_READ_LOCAL_FEATURES,
    hci.HCI_OP_SET_EVENT_MASK,
    hci.HCI_OP_LE_SET_EVENT_MASK,
    hci.HCI_OP_WRITE_SIMPLE_PAIRING_MODE,
    hci.HCI_OP_WRITE_SECURE_CONNECTIONS_HOST_SUPPORT,
    hci.HCI_OP_WRITE_LE_HOST_SUPPORTED,
    hci.HCI_OP_WRITE_CLASS_OF_DEVICE,
    hci.HCI_OP_WRITE_LOCAL_NAME,
    hci.HCI_OP_WRITE_INQUIRY_MODE,
    hci.HCI_OP_WRITE_INQUIRY_SCAN_TYPE,
    hci.HCI_OP_WRITE_EXTENDED_INQUIRY_RESPONSE,
    hci.HCI_OP_WRITE_SCAN_ENABLE,
    hci.HCI_OP_READ_LOCAL_EXT_FEATURES,
};

fn sentWith(script: *const Script, opcode: u16) ?Script.Sent {
    for (script.sent[0..script.count]) |sent| {
        if (sent.opcode == opcode) return sent;
    }
    return null;
}

test "a dual-mode controller is brought up command by command, and what it says is kept" {
    var script = Script{};
    var layer = makeLayer(&script);
    _hci.start(&layer);
    try testing.expectEqual(bluetooth.BTCS_STARTING, layer.state);
    try testing.expectEqual(@as(usize, 1), script.count);
    script.run(&layer);

    var seen: [64]u16 = undefined;
    try testing.expectEqualSlices(u16, &dual_mode, script.opcodes(&seen));
    try testing.expectEqual(bluetooth.BTCS_UP, layer.state);
    try testing.expectEqual(@as(i32, 0), layer.failure);

    try testing.expectEqual(hci.BT_VERSION_5_3, layer.hci_version);
    try testing.expectEqual(@as(u16, 0x1234), layer.hci_revision);
    try testing.expectEqual(@as(u16, 70), layer.manufacturer);
    try testing.expectEqual(@as(u16, 0x5678), layer.lmp_subversion);
    try testing.expectEqualSlices(u8, &.{ 0x13, 0x71, 0xDA, 0x7D, 0x1A, 0x00 }, &layer.address);
    try testing.expectEqual(@as(u16, 1021), layer.acl_mtu);
    try testing.expectEqual(@as(u16, 6), layer.acl_packets);
    try testing.expectEqual(@as(u16, 64), layer.sco_mtu);
    try testing.expectEqual(@as(u16, 251), layer.le_mtu);
    try testing.expectEqual(@as(u16, 15), layer.le_packets);
    try testing.expectEqual(@as(u8, 2), layer.max_page);
    try testing.expect(_hci.feature(&layer, 2, hci.LMP_SECURE_CONNECTIONS));
    try testing.expect(_hci.feature(&layer, 1, hci.LMP_HOST_SIMPLE_PAIRING));
    try testing.expect(_hci.leFeature(&layer, hci.LE_FEATURE_DATA_LENGTH));

    // The events: everything this controller can send that the stack
    // takes, and LE's.
    const mask = sentWith(&script, hci.HCI_OP_SET_EVENT_MASK).?;
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xFF, 0xFB, 0xFF, 0x07, 0xF8, 0xBF, 0x3D }, mask.params[0..mask.length]);
    const le_mask = sentWith(&script, hci.HCI_OP_LE_SET_EVENT_MASK).?;
    try testing.expectEqualSlices(u8, &.{ 0x7F, 0, 0, 0, 0, 0, 0, 0 }, le_mask.params[0..le_mask.length]);
    // What it shows: a desktop computer, and its name in 248 bytes.
    const class = sentWith(&script, hci.HCI_OP_WRITE_CLASS_OF_DEVICE).?;
    try testing.expectEqualSlices(u8, &.{ 0x04, 0x01, 0x00 }, class.params[0..class.length]);
    const name = sentWith(&script, hci.HCI_OP_WRITE_LOCAL_NAME).?;
    try testing.expectEqual(@as(usize, hci.HCI_MAX_NAME), name.length);
    try testing.expectEqualSlices(u8, "nuc", name.params[0..3]);
    try testing.expectEqual(@as(u8, 0), name.params[3]);
    try testing.expectEqual(@as(u8, 0), name.params[hci.HCI_MAX_NAME - 1]);
    const host = sentWith(&script, hci.HCI_OP_WRITE_LE_HOST_SUPPORTED).?;
    try testing.expectEqualSlices(u8, &.{ 1, 0 }, host.params[0..host.length]);
    // Extended results, its name in its response, and pages answered: on,
    // not visible.
    const mode = sentWith(&script, hci.HCI_OP_WRITE_INQUIRY_MODE).?;
    try testing.expectEqualSlices(u8, &.{hci.INQUIRY_MODE_EXTENDED}, mode.params[0..mode.length]);
    const response = sentWith(&script, hci.HCI_OP_WRITE_EXTENDED_INQUIRY_RESPONSE).?;
    try testing.expectEqual(@as(usize, 1 + hci.EIR_SIZE), response.length);
    try testing.expectEqualSlices(u8, &.{ 0, 4, hci.AD_NAME_COMPLETE, 'n', 'u', 'c', 0 }, response.params[0..7]);
    const scan = sentWith(&script, hci.HCI_OP_WRITE_SCAN_ENABLE).?;
    try testing.expectEqualSlices(u8, &.{hci.SCAN_PAGE}, scan.params[0..scan.length]);
}

test "the bring-up waits for the settings once the address is known, and writes them" {
    var script = Script{};
    var layer = makeLayer(&script);
    _hci.start(&layer);
    while (script.answered < script.count) {
        const sent = script.sent[script.answered];
        script.answered += 1;
        script.answer(&layer, sent);
    }
    // Stopped after Read BD_ADDR, nothing more out.
    try testing.expect(layer.wants_settings);
    try testing.expectEqual(bluetooth.BTCS_STARTING, layer.state);
    try testing.expectEqual(hci.HCI_OP_READ_BD_ADDR, script.sent[script.count - 1].opcode);
    try testing.expectEqualSlices(u8, &.{ 0x13, 0x71, 0xDA, 0x7D, 0x1A, 0x00 }, &layer.address);
    // The task's: visible, and a name of its own.
    layer.visible = true;
    @memcpy(layer.name[0..6], "Desk\x00\x00");
    bringup.settled(&layer);
    script.run(&layer);
    try testing.expectEqual(bluetooth.BTCS_UP, layer.state);
    const scan = sentWith(&script, hci.HCI_OP_WRITE_SCAN_ENABLE).?;
    try testing.expectEqualSlices(u8, &.{hci.SCAN_PAGE | hci.SCAN_INQUIRY}, scan.params[0..scan.length]);
    const name = sentWith(&script, hci.HCI_OP_WRITE_LOCAL_NAME).?;
    try testing.expectEqualSlices(u8, "Desk\x00", name.params[0..5]);

    // Brought up again after a hardware error, it has them: no pause.
    const before = script.count;
    _hci.received(&layer, hcidev.HCI_EVENT_PKT, &.{ hci.HCI_EV_HARDWARE_ERROR, 1, 0 });
    while (script.answered < script.count) {
        const sent = script.sent[script.answered];
        script.answered += 1;
        script.answer(&layer, sent);
    }
    try testing.expect(!layer.wants_settings);
    try testing.expectEqual(bluetooth.BTCS_UP, layer.state);
    try testing.expect(script.count > before);
}

test "a controller that is off answers nothing" {
    var script = Script{};
    var layer = makeLayer(&script);
    _hci.start(&layer);
    while (script.answered < script.count) {
        const sent = script.sent[script.answered];
        script.answered += 1;
        script.answer(&layer, sent);
    }
    layer.powered = false;
    layer.visible = true;
    bringup.settled(&layer);
    script.run(&layer);
    const scan = sentWith(&script, hci.HCI_OP_WRITE_SCAN_ENABLE).?;
    try testing.expectEqualSlices(u8, &.{0}, scan.params[0..scan.length]);
}

test "a controller without LE is not given LE's steps" {
    var script = Script{};
    script.features[4] &= ~@as(u8, 1 << 6);
    var layer = makeLayer(&script);
    _hci.start(&layer);
    script.run(&layer);
    try testing.expectEqual(bluetooth.BTCS_UP, layer.state);
    try testing.expect(sentWith(&script, hci.HCI_OP_WRITE_SCAN_ENABLE) != null);
    try testing.expect(sentWith(&script, hci.HCI_OP_LE_READ_BUFFER_SIZE) == null);
    try testing.expect(sentWith(&script, hci.HCI_OP_LE_SET_EVENT_MASK) == null);
    try testing.expect(sentWith(&script, hci.HCI_OP_WRITE_LE_HOST_SUPPORTED) == null);
    const mask = sentWith(&script, hci.HCI_OP_SET_EVENT_MASK).?;
    // No LE Meta.
    try testing.expectEqual(@as(u8, 0x1D), mask.params[7]);
}

test "a command the controller says it does not take is not sent" {
    var script = Script{};
    // Write LE Host Supported, bit 198: byte 24, bit 6.
    script.commands[24] &= ~@as(u8, 1 << 6);
    var layer = makeLayer(&script);
    _hci.start(&layer);
    script.run(&layer);
    try testing.expectEqual(bluetooth.BTCS_UP, layer.state);
    try testing.expect(sentWith(&script, hci.HCI_OP_WRITE_LE_HOST_SUPPORTED) == null);
    try testing.expect(sentWith(&script, hci.HCI_OP_WRITE_CLASS_OF_DEVICE) != null);
}

test "an optional step refused is passed over, by Command Complete or Command Status" {
    for ([_]bool{ false, true }) |by_status| {
        var script = Script{ .refuse = hci.HCI_OP_WRITE_SIMPLE_PAIRING_MODE, .refuse_by_status = by_status };
        var layer = makeLayer(&script);
        _hci.start(&layer);
        script.run(&layer);
        try testing.expectEqual(bluetooth.BTCS_UP, layer.state);
        try testing.expect(sentWith(&script, hci.HCI_OP_WRITE_LOCAL_NAME) != null);
    }
}

test "a required step refused gives the controller up, with its status" {
    var script = Script{ .refuse = hci.HCI_OP_READ_BD_ADDR, .refuse_status = hci.HCI_ERR_HARDWARE_FAILURE };
    var layer = makeLayer(&script);
    _hci.start(&layer);
    script.run(&layer);
    try testing.expectEqual(bluetooth.BTCS_FAILED, layer.state);
    try testing.expectEqual(@as(i32, hci.HCI_ERR_HARDWARE_FAILURE), layer.failure);
    try testing.expect(sentWith(&script, hci.HCI_OP_LE_READ_BUFFER_SIZE) == null);
}

test "a command not answered in its time gives the controller up" {
    var script = Script{};
    var layer = makeLayer(&script);
    layer.now = 1000;
    _hci.start(&layer);
    // The reset is not answered.
    try testing.expectEqual(@as(?u64, 1000 + 5000), _hci.nextDeadline(&layer));
    layer.now = 5999;
    _hci.tick(&layer);
    try testing.expectEqual(bluetooth.BTCS_STARTING, layer.state);
    layer.now = 6000;
    _hci.tick(&layer);
    try testing.expectEqual(bluetooth.BTCS_FAILED, layer.state);
    try testing.expectEqual(bluetooth.BTERR_TIMEOUT, layer.failure);
    try testing.expect(_hci.nextDeadline(&layer) == null);
}

test "nothing is sent while the controller has no credits; a no-op gives them back" {
    var script = Script{};
    var layer = makeLayer(&script);
    _hci.start(&layer);
    // The reset answered with no room for another command.
    script.answered = 1;
    complete(&layer, 0, hci.HCI_OP_RESET, &.{0});
    try testing.expectEqual(@as(usize, 1), script.count);
    try testing.expectEqual(@as(u8, 0), layer.credits);
    // A Command Complete for opcode 0 only gives credits.
    complete(&layer, 1, 0, &.{});
    try testing.expectEqual(@as(usize, 2), script.count);
    try testing.expectEqual(hci.HCI_OP_READ_LOCAL_VERSION, script.sent[1].opcode);
}

test "a command the transport cannot take now waits, and goes when it can" {
    var script = Script{ .taking = false };
    var layer = makeLayer(&script);
    _hci.start(&layer);
    try testing.expectEqual(@as(usize, 0), script.count);
    try testing.expectEqual(@as(u8, 1), layer.queue_count);
    script.taking = true;
    _hci.pump(&layer);
    try testing.expectEqual(@as(usize, 1), script.count);
    try testing.expectEqual(hci.HCI_OP_RESET, script.sent[0].opcode);
    try testing.expectEqual(@as(u8, 0), layer.queue_count);
}

test "a hardware error brings the controller up again from its reset, twice at most" {
    var script = Script{};
    var layer = makeLayer(&script);
    _hci.start(&layer);
    script.run(&layer);
    try testing.expectEqual(bluetooth.BTCS_UP, layer.state);
    const error_event = [_]u8{ hci.HCI_EV_HARDWARE_ERROR, 1, 0 };
    for (0..2) |_| {
        const before = script.count;
        _hci.received(&layer, hcidev.HCI_EVENT_PKT, &error_event);
        try testing.expectEqual(bluetooth.BTCS_STARTING, layer.state);
        try testing.expectEqual(hci.HCI_OP_RESET, script.sent[before].opcode);
        script.run(&layer);
        try testing.expectEqual(bluetooth.BTCS_UP, layer.state);
    }
    _hci.received(&layer, hcidev.HCI_EVENT_PKT, &error_event);
    try testing.expectEqual(bluetooth.BTCS_FAILED, layer.state);
}

test "an answer to nothing sent, and a packet too short to be one, change nothing" {
    var script = Script{};
    var layer = makeLayer(&script);
    _hci.start(&layer);
    complete(&layer, 1, hci.HCI_OP_READ_BD_ADDR, &.{ 0, 1, 2, 3, 4, 5, 6 });
    _hci.received(&layer, hcidev.HCI_EVENT_PKT, &.{hci.HCI_EV_COMMAND_COMPLETE});
    _hci.received(&layer, hcidev.HCI_EVENT_PKT, &.{ hci.HCI_EV_COMMAND_COMPLETE, 2, 1, 0 });
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0 }, &layer.address);
    try testing.expectEqual(@as(u8, 0), layer.step);
    try testing.expectEqual(bluetooth.BTCS_STARTING, layer.state);
}
