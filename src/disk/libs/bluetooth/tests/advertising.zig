// SPDX-License-Identifier: MIT
//! Host tests of LE's advertising: begun while the controller is visible
//! - its parameters, what it says, BTCF_ADVERTISING - and stopped when it
//! is not, when the power goes off and when visible for a time is over; a
//! name too long for the advertisement, shortened there and whole in the
//! scan response, or cut at a whole character in both; a name changed
//! while it advertises; a controller without BR/EDR made visible by it
//! alone; making way for a discovery's scan, the background scan,
//! initiating and a link as central where the controller cannot do both,
//! and going on beside them where it can; ended by a link a device made
//! and begun again beside it or after it; the link table full; refused,
//! and not answered, and tried again later.

const std = @import("std");
const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const hcidev = sdk.devices.hci;
const _hci = @import("../hci/_hci.zig");
const Hci = _hci.Hci;
const acl = @import("../hci/acl.zig");
const advertising = @import("../hci/advertising.zig");
const connections = @import("../hci/connections.zig");
const discovery = @import("../hci/discovery.zig");
const eir = @import("../hci/eir.zig");
const local = @import("../hci/local.zig");
const scan = @import("../hci/scan.zig");
const _controller = @import("../controller/_controller.zig");

const testing = std.testing;

/// A controller that keeps the commands it is sent; `settle` answers them.
const Recorder = struct {
    sent: [64]Sent = undefined,
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

/// A layer up and on, BR/EDR and LE, taking every command, with LE's
/// own buffers; its LE states every one but those `without` names.
fn upLayer(recorder: *Recorder, without: []const u8) Hci {
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
    layer.le_states = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x03, 0, 0 };
    for (without) |n| layer.le_states[n / 8] &= ~(@as(u8, 1) << @intCast(n % 8));
    layer.have_states = true;
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

/// LE Connection Complete: a link with `handle` to the public address
/// `bytes`, the controller in `role`.
fn leLinked(layer: *Hci, handle: u16, role: u8, bytes: [6]u8) void {
    var params: [19]u8 = @splat(0);
    params[0] = hci.HCI_LE_EV_CONNECTION_COMPLETE;
    params[1] = hci.HCI_SUCCESS;
    params[2] = @truncate(handle);
    params[3] = @truncate(handle >> 8);
    params[4] = role;
    params[5] = hci.LE_ADDR_PUBLIC;
    @memcpy(params[6..12], &bytes);
    params[12] = 0x28; // every 50 ms
    params[16] = 0x2A; // supervised for 420 ms
    event(layer, hci.HCI_EV_LE_META, &params);
}

/// Disconnection Complete for `handle`.
fn down(layer: *Hci, handle: u16) void {
    event(layer, hci.HCI_EV_DISCONNECTION_COMPLETE, &.{ hci.HCI_SUCCESS, @truncate(handle), @truncate(handle >> 8), hci.HCI_ERR_REMOTE_USER_TERMINATED });
}

/// Advertising begun: its four commands.
const begun = [_]u16{
    hci.HCI_OP_LE_SET_ADVERTISING_PARAMETERS,
    hci.HCI_OP_LE_SET_ADVERTISING_DATA,
    hci.HCI_OP_LE_SET_SCAN_RESPONSE_DATA,
    hci.HCI_OP_LE_SET_ADVERTISING_ENABLE,
};

const all_flags = bluetooth.BTCF_POWERED | bluetooth.BTCF_CONNECTABLE | bluetooth.BTCF_VISIBLE | bluetooth.BTCF_ADVERTISING;

test "visible, the controller advertises - its parameters, what it says, BTCF_ADVERTISING - and not visible, it stops" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder, &.{});
    try testing.expectEqual(@as(i32, 0), local.setVisible(&layer, bluetooth.BT_VISIBLE_ALWAYS));
    settle(&layer, &recorder);
    var seen: [16]u16 = undefined;
    try testing.expectEqualSlices(u16, &([_]u16{hci.HCI_OP_WRITE_SCAN_ENABLE} ++ begun), recorder.opcodes(0, &seen));
    // Every 100 to 150 ms, connectable and scannable, undirected, from the
    // public address, on all three channels, to anyone.
    const params = recorder.lastOf(hci.HCI_OP_LE_SET_ADVERTISING_PARAMETERS).?;
    try testing.expectEqualSlices(u8, &.{ 0xA0, 0, 0xF0, 0, hci.LE_ADV_IND, hci.LE_ADDR_PUBLIC, 0, 0, 0, 0, 0, 0, 0, 7, 0 }, params.params[0..params.length]);
    // LE General Discoverable, a computer, the name complete - the 31
    // bytes sent whatever their length - and nothing in the scan response.
    const data = recorder.lastOf(hci.HCI_OP_LE_SET_ADVERTISING_DATA).?;
    try testing.expectEqual(@as(usize, 32), data.length);
    try testing.expectEqualSlices(u8, &.{ 12, 2, hci.AD_FLAGS, hci.AD_FLAG_GENERAL, 3, hci.AD_APPEARANCE, 0x80, 0x00, 4, hci.AD_NAME_COMPLETE, 'n', 'u', 'c', 0 }, data.params[0..14]);
    const response = recorder.lastOf(hci.HCI_OP_LE_SET_SCAN_RESPONSE_DATA).?;
    try testing.expectEqual(@as(usize, 32), response.length);
    try testing.expectEqual(@as(u8, 0), response.params[0]);
    try testing.expectEqual(@as(u8, 1), recorder.lastOf(hci.HCI_OP_LE_SET_ADVERTISING_ENABLE).?.params[0]);
    try testing.expectEqual(all_flags, _controller.flagsOf(&layer));

    const before = recorder.count;
    try testing.expectEqual(@as(i32, 0), local.setVisible(&layer, 0));
    settle(&layer, &recorder);
    try testing.expectEqualSlices(u16, &.{ hci.HCI_OP_WRITE_SCAN_ENABLE, hci.HCI_OP_LE_SET_ADVERTISING_ENABLE }, recorder.opcodes(before, &seen));
    try testing.expectEqual(@as(u8, 0), recorder.lastOf(hci.HCI_OP_LE_SET_ADVERTISING_ENABLE).?.params[0]);
    try testing.expectEqual(bluetooth.BTCF_POWERED | bluetooth.BTCF_CONNECTABLE, _controller.flagsOf(&layer));
    try testing.expectEqual(@as(?u64, null), _hci.nextDeadline(&layer));
}

test "off, it stops advertising; on again it goes on; visible for a time over, it stops" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder, &.{});
    try testing.expectEqual(@as(i32, 0), local.setVisible(&layer, 60));
    settle(&layer, &recorder);
    try testing.expect(layer.advertising.on);
    var seen: [16]u16 = undefined;

    var before = recorder.count;
    try testing.expectEqual(@as(i32, 0), local.setPowered(&layer, false));
    settle(&layer, &recorder);
    try testing.expectEqualSlices(u16, &.{ hci.HCI_OP_WRITE_SCAN_ENABLE, hci.HCI_OP_LE_SET_ADVERTISING_ENABLE }, recorder.opcodes(before, &seen));
    try testing.expect(!layer.advertising.on);

    before = recorder.count;
    try testing.expectEqual(@as(i32, 0), local.setPowered(&layer, true));
    settle(&layer, &recorder);
    try testing.expectEqualSlices(u16, &([_]u16{hci.HCI_OP_WRITE_SCAN_ENABLE} ++ begun), recorder.opcodes(before, &seen));

    before = recorder.count;
    layer.now += 60_000;
    _hci.tick(&layer);
    settle(&layer, &recorder);
    try testing.expectEqualSlices(u16, &.{ hci.HCI_OP_WRITE_SCAN_ENABLE, hci.HCI_OP_LE_SET_ADVERTISING_ENABLE }, recorder.opcodes(before, &seen));
    try testing.expect(!layer.visible and !layer.advertising.on);
}

test "a name too long for the advertisement: shortened there, whole in the scan response; longer still, cut at a whole character in both" {
    var data: [hci.LE_ADV_DATA_SIZE]u8 = undefined;
    var response: [hci.LE_ADV_DATA_SIZE]u8 = undefined;
    // 22 bytes: the most the advertisement holds whole.
    const fits = "Workbench in the attic";
    try testing.expectEqual(@as(usize, 22), fits.len);
    try testing.expectEqual(@as(usize, 31), eir.advertisement(&data, hci.AD_FLAG_GENERAL, fits));
    try testing.expectEqualSlices(u8, &.{ 23, hci.AD_NAME_COMPLETE }, data[7..9]);
    try testing.expectEqual(@as(usize, 0), eir.scanResponse(&response, fits));

    // 28: shortened to the 22, whole in the scan response.
    const longer = "Workbench in the attic, left";
    try testing.expectEqual(@as(usize, 28), longer.len);
    try testing.expectEqual(@as(usize, 31), eir.advertisement(&data, hci.AD_FLAG_GENERAL, longer));
    try testing.expectEqualSlices(u8, &.{ 23, hci.AD_NAME_SHORT }, data[7..9]);
    try testing.expectEqualStrings(fits, data[9..31]);
    try testing.expectEqual(@as(usize, 30), eir.scanResponse(&response, longer));
    try testing.expectEqualSlices(u8, &.{ 29, hci.AD_NAME_COMPLETE }, response[0..2]);
    try testing.expectEqualStrings(longer, response[2..30]);

    // 30, its last character two bytes: the scan response keeps the 28
    // before it, shortened.
    const longest = longer ++ "\u{FC}";
    try testing.expectEqual(@as(usize, 30), longest.len);
    try testing.expectEqual(@as(usize, 30), eir.scanResponse(&response, longest));
    try testing.expectEqualSlices(u8, &.{ 29, hci.AD_NAME_SHORT }, response[0..2]);
    try testing.expectEqualStrings(longer, response[2..30]);

    // A character across the advertisement's 22nd byte is left out whole.
    const across = "Workbench in the atti\u{FC}c";
    try testing.expectEqual(@as(usize, 24), across.len);
    try testing.expectEqual(@as(usize, 30), eir.advertisement(&data, hci.AD_FLAG_GENERAL, across));
    try testing.expectEqualSlices(u8, &.{ 22, hci.AD_NAME_SHORT }, data[7..9]);
    try testing.expectEqualStrings("Workbench in the atti", data[9..30]);
    try testing.expectEqual(@as(usize, 26), eir.scanResponse(&response, across));
    try testing.expectEqualSlices(u8, &.{ 25, hci.AD_NAME_COMPLETE }, response[0..2]);

    // The name ends at its NUL.
    try testing.expectEqual(@as(usize, 12), eir.advertisement(&data, hci.AD_FLAG_GENERAL, "nuc\x00old"));
}

test "a name changed while it advertises is advertised at once; while it does not, only the name is written" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder, &.{});
    _ = local.setVisible(&layer, bluetooth.BT_VISIBLE_ALWAYS);
    settle(&layer, &recorder);
    var seen: [16]u16 = undefined;
    var before = recorder.count;
    try testing.expectEqual(@as(i32, 0), local.setName(&layer, "Workbench in the attic, left"));
    settle(&layer, &recorder);
    try testing.expectEqualSlices(u16, &.{
        hci.HCI_OP_WRITE_LOCAL_NAME,
        hci.HCI_OP_WRITE_EXTENDED_INQUIRY_RESPONSE,
        hci.HCI_OP_LE_SET_ADVERTISING_DATA,
        hci.HCI_OP_LE_SET_SCAN_RESPONSE_DATA,
    }, recorder.opcodes(before, &seen));
    const data = recorder.lastOf(hci.HCI_OP_LE_SET_ADVERTISING_DATA).?;
    try testing.expectEqual(@as(u8, 31), data.params[0]);
    try testing.expectEqualSlices(u8, &.{ 23, hci.AD_NAME_SHORT }, data.params[8..10]);
    const response = recorder.lastOf(hci.HCI_OP_LE_SET_SCAN_RESPONSE_DATA).?;
    try testing.expectEqualSlices(u8, &.{ 30, 29, hci.AD_NAME_COMPLETE }, response.params[0..3]);
    try testing.expectEqualStrings("Workbench in the attic, left", response.params[3..31]);

    _ = local.setVisible(&layer, 0);
    settle(&layer, &recorder);
    before = recorder.count;
    try testing.expectEqual(@as(i32, 0), local.setName(&layer, "nuc"));
    settle(&layer, &recorder);
    try testing.expectEqualSlices(u16, &.{ hci.HCI_OP_WRITE_LOCAL_NAME, hci.HCI_OP_WRITE_EXTENDED_INQUIRY_RESPONSE }, recorder.opcodes(before, &seen));
}

test "a controller without BR/EDR is made visible by its advertising alone; one whose states have no advertising is not" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder, &.{});
    layer.features[0][4] |= 1 << 5; // BR/EDR not supported
    try testing.expectEqual(@as(i32, 0), local.setVisible(&layer, 60));
    settle(&layer, &recorder);
    var seen: [16]u16 = undefined;
    try testing.expectEqualSlices(u16, &begun, recorder.opcodes(0, &seen));
    const data = recorder.lastOf(hci.HCI_OP_LE_SET_ADVERTISING_DATA).?;
    try testing.expectEqual(hci.AD_FLAG_GENERAL | hci.AD_FLAG_NO_BREDR, data.params[3]);
    try testing.expectEqual(all_flags, _controller.flagsOf(&layer));

    var other_recorder = Recorder{};
    var other = upLayer(&other_recorder, &.{hci.LE_STATE_ADV});
    other.features[0][4] |= 1 << 5;
    try testing.expectEqual(bluetooth.BTERR_UNSUPPORTED, local.setVisible(&other, 60));
    try testing.expectEqual(@as(usize, 0), other_recorder.count);
}

test "it makes way for a discovery's active scan where the controller cannot do both, and goes on once LE's phase is over" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder, &.{hci.LE_STATE_ADV_ACTIVE_SCAN});
    _ = local.setVisible(&layer, bluetooth.BT_VISIBLE_ALWAYS);
    settle(&layer, &recorder);
    var seen: [16]u16 = undefined;
    var before = recorder.count;
    try testing.expectEqual(@as(i32, 0), discovery.start(&layer, 3000));
    settle(&layer, &recorder);
    try testing.expectEqualSlices(u16, &.{ hci.HCI_OP_LE_SET_ADVERTISING_ENABLE, hci.HCI_OP_LE_SET_SCAN_PARAMETERS, hci.HCI_OP_LE_SET_SCAN_ENABLE }, recorder.opcodes(before, &seen));
    try testing.expectEqual(@as(u8, 0), recorder.sent[before].params[0]);
    try testing.expectEqual(bluetooth.BTCF_POWERED | bluetooth.BTCF_CONNECTABLE | bluetooth.BTCF_VISIBLE | bluetooth.BTCF_DISCOVERING, _controller.flagsOf(&layer));

    // LE's third over: the inquiry, beside which it advertises again.
    before = recorder.count;
    layer.now += 1000;
    _hci.tick(&layer);
    settle(&layer, &recorder);
    try testing.expectEqualSlices(u16, &([_]u16{ hci.HCI_OP_LE_SET_SCAN_ENABLE, hci.HCI_OP_INQUIRY } ++ begun), recorder.opcodes(before, &seen));
    try testing.expect(layer.advertising.on);
}

test "beside a scan the controller can do with it, it goes on advertising" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder, &.{});
    _ = local.setVisible(&layer, bluetooth.BT_VISIBLE_ALWAYS);
    settle(&layer, &recorder);
    var seen: [16]u16 = undefined;
    const before = recorder.count;
    try testing.expectEqual(@as(i32, 0), discovery.start(&layer, 3000));
    settle(&layer, &recorder);
    try testing.expectEqualSlices(u16, &.{ hci.HCI_OP_LE_SET_SCAN_PARAMETERS, hci.HCI_OP_LE_SET_SCAN_ENABLE }, recorder.opcodes(before, &seen));
    try testing.expect(layer.advertising.on);
}

test "it makes way for the background scan where the controller cannot do both, and goes on once the scan ends" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder, &.{hci.LE_STATE_ADV_PASSIVE_SCAN});
    _ = local.setVisible(&layer, bluetooth.BT_VISIBLE_ALWAYS);
    settle(&layer, &recorder);
    var seen: [16]u16 = undefined;
    // A GATT block waits for its device.
    layer.att_clients[0] = .{ .state = .waiting, .waits = true, .serial = 1, .address = .{ .bytes = .{ 0x47, 0x10, 0xEF, 0x5E, 0, 0 }, .kind = bluetooth.BTADDR_LE_PUBLIC } };
    var before = recorder.count;
    scan.update(&layer);
    settle(&layer, &recorder);
    try testing.expectEqualSlices(u16, &.{ hci.HCI_OP_LE_SET_ADVERTISING_ENABLE, hci.HCI_OP_LE_SET_SCAN_PARAMETERS, hci.HCI_OP_LE_SET_SCAN_ENABLE }, recorder.opcodes(before, &seen));
    try testing.expect(layer.scan.on and !layer.advertising.on);

    layer.att_clients[0] = .{};
    before = recorder.count;
    scan.update(&layer);
    settle(&layer, &recorder);
    try testing.expectEqualSlices(u16, &([_]u16{hci.HCI_OP_LE_SET_SCAN_ENABLE} ++ begun), recorder.opcodes(before, &seen));
}

test "it makes way for initiating, and a link as central, where the controller cannot do both, and goes on once the link is down" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder, &.{ hci.LE_STATE_ADV_INITIATING, hci.LE_STATE_ADV_CENTRAL });
    _ = local.setVisible(&layer, bluetooth.BT_VISIBLE_ALWAYS);
    settle(&layer, &recorder);
    var seen: [16]u16 = undefined;
    const device = bluetooth.BTAddress{ .bytes = .{ 0x47, 0x10, 0xEF, 0x5E, 0, 0 }, .kind = bluetooth.BTADDR_LE_PUBLIC };
    var before = recorder.count;
    _ = connections.connect(&layer, device);
    settle(&layer, &recorder);
    try testing.expectEqualSlices(u16, &.{ hci.HCI_OP_LE_SET_ADVERTISING_ENABLE, hci.HCI_OP_LE_CREATE_CONNECTION }, recorder.opcodes(before, &seen));
    try testing.expect(!layer.advertising.on);

    before = recorder.count;
    leLinked(&layer, 0x0040, hci.ROLE_CENTRAL, device.bytes);
    settle(&layer, &recorder);
    try testing.expectEqualSlices(u16, &.{hci.HCI_OP_LE_READ_REMOTE_FEATURES}, recorder.opcodes(before, &seen));
    try testing.expect(!layer.advertising.on);

    before = recorder.count;
    down(&layer, 0x0040);
    settle(&layer, &recorder);
    try testing.expectEqualSlices(u16, &begun, recorder.opcodes(before, &seen));
}

test "a link a device makes ends it; it goes on beside the link where the controller can, after it where it cannot" {
    const bytes = [6]u8{ 0x48, 0x10, 0xEF, 0x5E, 0, 0 };
    for ([_]bool{ true, false }) |can_beside| {
        var recorder = Recorder{};
        var layer = upLayer(&recorder, if (can_beside) &.{} else &.{hci.LE_STATE_ADV_PERIPHERAL});
        _ = local.setVisible(&layer, bluetooth.BT_VISIBLE_ALWAYS);
        settle(&layer, &recorder);
        var seen: [16]u16 = undefined;
        var before = recorder.count;
        leLinked(&layer, 0x0041, hci.ROLE_PERIPHERAL, bytes);
        settle(&layer, &recorder);
        const link = connections.find(&layer, .{ .bytes = bytes, .kind = bluetooth.BTADDR_LE_PUBLIC }).?;
        try testing.expect(link.incoming and !link.central and link.le);
        // The controller stopped by itself: nothing asked to stop it.
        if (can_beside) {
            try testing.expectEqualSlices(u16, &([_]u16{hci.HCI_OP_LE_READ_REMOTE_FEATURES} ++ begun), recorder.opcodes(before, &seen));
            try testing.expect(layer.advertising.on);
            continue;
        }
        try testing.expectEqualSlices(u16, &.{hci.HCI_OP_LE_READ_REMOTE_FEATURES}, recorder.opcodes(before, &seen));
        try testing.expect(!layer.advertising.on);
        try testing.expectEqual(bluetooth.BTCF_POWERED | bluetooth.BTCF_CONNECTABLE | bluetooth.BTCF_VISIBLE, _controller.flagsOf(&layer));
        before = recorder.count;
        down(&layer, 0x0041);
        settle(&layer, &recorder);
        try testing.expectEqualSlices(u16, &begun, recorder.opcodes(before, &seen));
    }
}

test "with its link table full it does not advertise; a link down, it goes on" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder, &.{});
    _ = local.setVisible(&layer, bluetooth.BT_VISIBLE_ALWAYS);
    settle(&layer, &recorder);
    var seen: [16]u16 = undefined;
    // Seven links over BR/EDR, and a device's over LE the eighth.
    for (layer.connections[0 .. connections.CONNECTIONS - 1], 0..) |*connection, index| {
        connection.* = .{ .state = .up, .handle = @intCast(index + 1), .address = .{ .bytes = .{ @intCast(index), 0x10, 0xEF, 0x5E, 0, 0 }, .kind = bluetooth.BTADDR_BREDR } };
    }
    var before = recorder.count;
    leLinked(&layer, 0x0041, hci.ROLE_PERIPHERAL, .{ 0x48, 0x10, 0xEF, 0x5E, 0, 0 });
    settle(&layer, &recorder);
    try testing.expectEqualSlices(u16, &.{hci.HCI_OP_LE_READ_REMOTE_FEATURES}, recorder.opcodes(before, &seen));
    try testing.expect(!layer.advertising.on);

    before = recorder.count;
    down(&layer, 1);
    settle(&layer, &recorder);
    try testing.expectEqualSlices(u16, &begun, recorder.opcodes(before, &seen));
}

test "refused, it is turned off and tried again ten seconds later; a command not answered in its time is as refused" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder, &.{});
    _ = local.setVisible(&layer, bluetooth.BT_VISIBLE_ALWAYS);
    // The scan's answered, the parameters refused.
    recorder.answered = 2;
    complete(&layer, hci.HCI_OP_WRITE_SCAN_ENABLE, &.{hci.HCI_SUCCESS});
    complete(&layer, hci.HCI_OP_LE_SET_ADVERTISING_PARAMETERS, &.{hci.HCI_ERR_INVALID_PARAMETERS});
    settle(&layer, &recorder);
    try testing.expect(!layer.advertising.on);
    try testing.expectEqual(@as(u8, 0), recorder.lastOf(hci.HCI_OP_LE_SET_ADVERTISING_ENABLE).?.params[0]);
    try testing.expectEqual(@as(?u64, layer.now + advertising.RETRY_MS), _hci.nextDeadline(&layer));
    try testing.expectEqual(bluetooth.BTCF_POWERED | bluetooth.BTCF_CONNECTABLE | bluetooth.BTCF_VISIBLE, _controller.flagsOf(&layer));
    var seen: [16]u16 = undefined;
    var before = recorder.count;
    layer.now += advertising.RETRY_MS - 1;
    _hci.tick(&layer);
    try testing.expectEqual(before, recorder.count);
    layer.now += 1;
    _hci.tick(&layer);
    settle(&layer, &recorder);
    try testing.expectEqualSlices(u16, &begun, recorder.opcodes(before, &seen));
    try testing.expect(layer.advertising.on);

    // Not answered: given up on in its time, and tried again later.
    var silent_recorder = Recorder{};
    var silent = upLayer(&silent_recorder, &.{});
    _ = local.setVisible(&silent, bluetooth.BT_VISIBLE_ALWAYS);
    silent.now += _hci.COMMAND_TIMEOUT_MS;
    _hci.tick(&silent);
    // The four out given up on; what was sent after them answered.
    silent_recorder.answered = 4;
    settle(&silent, &silent_recorder);
    try testing.expect(!silent.advertising.on);
    try testing.expectEqual(@as(u8, 0), silent_recorder.lastOf(hci.HCI_OP_LE_SET_ADVERTISING_ENABLE).?.params[0]);
    try testing.expectEqual(@as(?u64, silent.now + advertising.RETRY_MS), _hci.nextDeadline(&silent));
    before = silent_recorder.count;
    silent.now += advertising.RETRY_MS;
    _hci.tick(&silent);
    settle(&silent, &silent_recorder);
    try testing.expectEqualSlices(u16, &begun, silent_recorder.opcodes(before, &seen));
}
