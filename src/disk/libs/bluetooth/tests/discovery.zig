// SPDX-License-Identifier: MIT
//! Host tests of what a controller finds and shows: an extended inquiry
//! response's and an advertisement's data taken apart, and the machine's
//! own made; a discovery's phases one after the other against a
//! controller the test answers by hand - LE's advertising reports, an
//! inquiry's results in their three forms, the names asked for, a name
//! that does not come, a refusal, a stop; a device heard both ways, a
//! full table; on, off and visible for a time; the settings file's
//! keywords, and the name file's line; what a device is, by its class
//! or its appearance.

const std = @import("std");
const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const hcidev = sdk.devices.hci;
const _hci = @import("../hci/_hci.zig");
const Hci = _hci.Hci;
const devices = @import("../hci/devices.zig");
const discovery = @import("../hci/discovery.zig");
const eir = @import("../hci/eir.zig");
const local = @import("../hci/local.zig");
const _controller = @import("../controller/_controller.zig");
const settings = @import("../task/settings.zig");
const BTDeviceKind = @import("../discovery/btdevicekind.zig").BTDeviceKind;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;

const testing = std.testing;

/// A controller that keeps the commands it is sent; the test answers them.
const Recorder = struct {
    sent: [32]Sent = undefined,
    count: usize = 0,

    const Sent = struct {
        opcode: u16,
        length: usize,
        params: [hci.HCI_MAX_PARAMS]u8,
    };

    fn send(context: *anyopaque, packet_type: u8, bytes: []const u8) bool {
        const recorder: *Recorder = @ptrCast(@alignCast(context));
        if (packet_type != hcidev.HCI_COMMAND_PKT) unreachable;
        const sent = &recorder.sent[recorder.count];
        sent.opcode = _hci.le16(bytes[0..2]);
        sent.length = bytes[2];
        @memcpy(sent.params[0..sent.length], bytes[hci.HCI_COMMAND_HDR..]);
        recorder.count += 1;
        return true;
    }

    fn last(recorder: *const Recorder) Sent {
        return recorder.sent[recorder.count - 1];
    }

    fn opcodes(recorder: *const Recorder, from: usize, into: []u16) []u16 {
        for (recorder.sent[from..recorder.count], 0..) |sent, index| into[index] = sent.opcode;
        return into[0 .. recorder.count - from];
    }
};

/// A layer up, BR/EDR and LE, taking every command.
fn upLayer(recorder: *Recorder) Hci {
    var layer = Hci{ .port = .{ .context = recorder, .send = Recorder.send } };
    layer.state = bluetooth.BTCS_UP;
    layer.features[0] = .{ 0xBF, 0xFE, 0xCF, 0xFE, 0xDB, 0xFF, 0x7B, 0x87 };
    layer.credits = 4;
    layer.now = 100_000;
    return layer;
}

fn complete(layer: *Hci, opcode: u16, returned: []const u8) void {
    var packet: [hci.HCI_MAX_EVENT]u8 = undefined;
    packet[0] = hci.HCI_EV_COMMAND_COMPLETE;
    packet[1] = @intCast(3 + returned.len);
    packet[2] = 4;
    packet[3] = @truncate(opcode);
    packet[4] = @truncate(opcode >> 8);
    @memcpy(packet[5..][0..returned.len], returned);
    _hci.received(layer, hcidev.HCI_EVENT_PKT, packet[0 .. 5 + returned.len]);
}

fn status(layer: *Hci, opcode: u16, code: u8) void {
    const packet = [_]u8{ hci.HCI_EV_COMMAND_STATUS, 4, code, 4, @truncate(opcode), @truncate(opcode >> 8) };
    _hci.received(layer, hcidev.HCI_EVENT_PKT, &packet);
}

fn event(layer: *Hci, code: u8, params: []const u8) void {
    var packet: [hci.HCI_MAX_EVENT]u8 = undefined;
    packet[0] = code;
    packet[1] = @intCast(params.len);
    @memcpy(packet[2..][0..params.len], params);
    _hci.received(layer, hcidev.HCI_EVENT_PKT, packet[0 .. 2 + params.len]);
}

/// One LE advertising report.
fn advertised(layer: *Hci, event_type: u8, address_type: u8, address: [6]u8, data: []const u8, rssi: i8) void {
    var params: [hci.HCI_MAX_PARAMS]u8 = undefined;
    params[0] = hci.HCI_LE_EV_ADVERTISING_REPORT;
    params[1] = 1;
    params[2] = event_type;
    params[3] = address_type;
    @memcpy(params[4..10], &address);
    params[10] = @intCast(data.len);
    @memcpy(params[11..][0..data.len], data);
    params[11 + data.len] = @bitCast(rssi);
    event(layer, hci.HCI_EV_LE_META, params[0 .. 12 + data.len]);
}

/// One Extended Inquiry Result.
fn extendedResult(layer: *Hci, address: [6]u8, class: u32, rssi: i8, response: []const u8) void {
    var params: [255]u8 = @splat(0);
    params[0] = 1;
    @memcpy(params[1..7], &address);
    params[7] = 1; // page scan repetition mode R1
    params[9] = @truncate(class);
    params[10] = @truncate(class >> 8);
    params[11] = @truncate(class >> 16);
    params[12] = 0x34;
    params[13] = 0x92; // bit 15 reserved: set, to be ignored
    params[14] = @bitCast(rssi);
    @memcpy(params[15..][0..response.len], response);
    event(layer, hci.HCI_EV_EXTENDED_INQUIRY_RESULT, &params);
}

/// One Inquiry Result with RSSI, in its usual form or its longer one.
fn rssiResult(layer: *Hci, address: [6]u8, class: u32, offset: u16, rssi: i8, longer: bool) void {
    var params: [16]u8 = @splat(0);
    params[0] = 1;
    @memcpy(params[1..7], &address);
    params[7] = 2; // R2
    const at: usize = if (longer) 10 else 9;
    params[at] = @truncate(class);
    params[at + 1] = @truncate(class >> 8);
    params[at + 2] = @truncate(class >> 16);
    params[at + 3] = @truncate(offset);
    params[at + 4] = @truncate(offset >> 8);
    params[at + 5] = @bitCast(rssi);
    event(layer, hci.HCI_EV_INQUIRY_RESULT_WITH_RSSI, params[0..if (longer) 16 else 15]);
}

fn nameComplete(layer: *Hci, code: u8, address: [6]u8, name: []const u8) void {
    var params: [255]u8 = @splat(0);
    params[0] = code;
    @memcpy(params[1..7], &address);
    @memcpy(params[7..][0..name.len], name);
    event(layer, hci.HCI_EV_REMOTE_NAME_REQUEST_COMPLETE, &params);
}

fn deviceAt(layer: *Hci, address: [6]u8, kind: u8) !*devices.Device {
    return devices.find(layer, address, kind) orelse error.NotFound;
}

const phone = [6]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 };
const headset = [6]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16 };
const laptop = [6]u8{ 0x21, 0x22, 0x23, 0x24, 0x25, 0x26 };
const beacon = [6]u8{ 0x31, 0x32, 0x33, 0x34, 0x35, 0xC6 };

test "what a device says of itself is taken apart, and adds up" {
    var device = devices.Device{ .used = true };
    const data = [_]u8{ 2, hci.AD_FLAGS, 0x06 } ++
        [_]u8{ 5, hci.AD_NAME_SHORT, 'K', 'e', 'y', 'b' } ++
        [_]u8{ 5, hci.AD_UUID16_ALL, 0x12, 0x18, 0x0F, 0x18 } ++ // HID, battery
        [_]u8{ 2, hci.AD_TX_POWER, 0xF8 } ++ // -8 dBm
        [_]u8{ 3, hci.AD_APPEARANCE, 0xC1, 0x03 } ++ // a keyboard
        [_]u8{ 5, hci.AD_MANUFACTURER_DATA, 0x06, 0x00, 0xAA, 0xBB } ++ // Microsoft
        [_]u8{ 5, hci.AD_UUID32_SOME, 0x78, 0x56, 0x34, 0x12 };
    eir.take(&device, &data);
    try testing.expectEqual(@as(u8, 0x06), device.ad_flags);
    try testing.expectEqualStrings("Keyb", std.mem.sliceTo(&device.name, 0));
    try testing.expect(device.flags & bluetooth.BTDF_SHORT_NAME != 0);
    try testing.expectEqualSlices(u16, &.{ 0x1812, 0x180F }, device.uuid16[0..device.uuid16_count]);
    try testing.expectEqual(@as(i8, -8), device.tx_power);
    try testing.expectEqual(@as(u16, 0x03C1), device.appearance);
    try testing.expectEqual(@as(u16, 6), device.company);
    // A 32-bit UUID as the 128-bit one it stands for.
    try testing.expectEqual(@as(u8, 1), device.uuid128_count);
    try testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12 }, device.uuid128[0][12..16]);
    try testing.expectEqualSlices(u8, hci.UUID_BASE[0..12], device.uuid128[0][0..12]);

    // The scan response: the complete name, a service again (kept once).
    const response = [_]u8{ 9, hci.AD_NAME_COMPLETE, 'K', 'e', 'y', 'b', 'o', 'a', 'r', 'd' } ++
        [_]u8{ 3, hci.AD_UUID16_SOME, 0x12, 0x18 };
    eir.take(&device, &response);
    try testing.expectEqualStrings("Keyboard", std.mem.sliceTo(&device.name, 0));
    try testing.expect(device.flags & bluetooth.BTDF_SHORT_NAME == 0);
    try testing.expectEqual(@as(u8, 2), device.uuid16_count);
    // A shortened one later does not take the complete one's place.
    eir.take(&device, &[_]u8{ 3, hci.AD_NAME_SHORT, 'K', 'e' });
    try testing.expectEqualStrings("Keyboard", std.mem.sliceTo(&device.name, 0));
}

test "a structure that runs past the end ends the run, and so does a zero length" {
    var device = devices.Device{ .used = true };
    eir.take(&device, &[_]u8{ 2, hci.AD_TX_POWER, 4, 0, 9, hci.AD_NAME_COMPLETE, 'x' });
    try testing.expectEqual(@as(i8, 4), device.tx_power);
    try testing.expectEqual(@as(u8, 0), device.name[0]);
    eir.take(&device, &[_]u8{ 9, hci.AD_NAME_COMPLETE, 'a', 'b' });
    try testing.expectEqual(@as(u8, 0), device.name[0]);
}

test "the machine's own response: its name, shortened at a whole character" {
    var response: [hci.EIR_SIZE]u8 = undefined;
    eir.response(&response, "nuc\x00garbage");
    try testing.expectEqualSlices(u8, &.{ 4, hci.AD_NAME_COMPLETE, 'n', 'u', 'c', 0 }, response[0..6]);
    // 237 bytes of 'a', then a two-byte character: 238 fit, the character
    // does not.
    var long: [240]u8 = @splat('a');
    long[237] = 0xC3;
    long[238] = 0xA4;
    long[239] = 0;
    eir.response(&response, &long);
    try testing.expectEqual(@as(u8, 1 + 237), response[0]);
    try testing.expectEqual(hci.AD_NAME_SHORT, response[1]);
    try testing.expectEqual(@as(u8, 'a'), response[2 + 236]);
    try testing.expectEqual(@as(u8, 0), response[2 + 237]);
}

test "a discovery: LE's scan, the inquiry, then the names, each when the one before is over" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try testing.expectEqual(@as(i32, 0), discovery.start(&layer, 10_000));
    try testing.expect(discovery.running(&layer));
    try testing.expect(_controller.flagsOf(&layer) & bluetooth.BTCF_DISCOVERING != 0);
    // LE first: active, every 11.25 ms for all of it, duplicates filtered.
    try testing.expectEqual(@as(usize, 2), recorder.count);
    try testing.expectEqual(hci.HCI_OP_LE_SET_SCAN_PARAMETERS, recorder.sent[0].opcode);
    try testing.expectEqualSlices(u8, &.{ 1, 0x12, 0, 0x12, 0, 0, 0 }, recorder.sent[0].params[0..7]);
    try testing.expectEqual(hci.HCI_OP_LE_SET_SCAN_ENABLE, recorder.sent[1].opcode);
    try testing.expectEqualSlices(u8, &.{ 1, 1 }, recorder.sent[1].params[0..2]);
    complete(&layer, hci.HCI_OP_LE_SET_SCAN_PARAMETERS, &.{0});
    complete(&layer, hci.HCI_OP_LE_SET_SCAN_ENABLE, &.{0});
    // A third of the time.
    try testing.expectEqual(@as(?u64, 100_000 + 3333), _hci.nextDeadline(&layer));

    // A beacon at a random address, its name in its scan response.
    advertised(&layer, hci.LE_ADV_NONCONN_IND, hci.LE_ADDR_RANDOM, beacon, &.{ 2, hci.AD_FLAGS, 0x04 }, -80);
    advertised(&layer, hci.LE_SCAN_RSP, hci.LE_ADDR_RANDOM, beacon, &.{ 4, hci.AD_NAME_COMPLETE, 'T', 'a', 'g' }, -78);
    // The phone advertises from its public address, connectable.
    advertised(&layer, hci.LE_ADV_IND, hci.LE_ADDR_PUBLIC, phone, &.{ 2, hci.AD_FLAGS, 0x1A }, -60);
    const tag = try deviceAt(&layer, beacon, bluetooth.BTADDR_LE_RANDOM);
    try testing.expectEqualStrings("Tag", std.mem.sliceTo(&tag.name, 0));
    try testing.expectEqual(@as(i8, -78), tag.rssi);
    try testing.expectEqual(bluetooth.BTDF_LE, tag.flags);
    try testing.expect((try deviceAt(&layer, phone, bluetooth.BTADDR_LE_PUBLIC)).flags & bluetooth.BTDF_CONNECTABLE != 0);

    // Its time up: the scan off, the inquiry for the rest - 6.67 s, six
    // units.
    const before = recorder.count;
    layer.now = 103_333;
    _hci.tick(&layer);
    var seen: [8]u16 = undefined;
    try testing.expectEqualSlices(u16, &.{ hci.HCI_OP_LE_SET_SCAN_ENABLE, hci.HCI_OP_INQUIRY }, recorder.opcodes(before, &seen));
    try testing.expectEqualSlices(u8, &.{ 0, 0 }, recorder.sent[before].params[0..2]);
    try testing.expectEqualSlices(u8, &.{ 0x33, 0x8B, 0x9E, 6, 0 }, recorder.last().params[0..5]);
    complete(&layer, hci.HCI_OP_LE_SET_SCAN_ENABLE, &.{0});
    status(&layer, hci.HCI_OP_INQUIRY, 0);

    // The phone answers with its name in its response: the same device,
    // BR/EDR now; the headset with RSSI only; the laptop in the longer
    // form.
    extendedResult(&layer, phone, 0x5A020C, -55, &.{ 6, hci.AD_NAME_COMPLETE, 'P', 'h', 'o', 'n', 'e' });
    rssiResult(&layer, headset, 0x240404, 0x1234, -70, false);
    rssiResult(&layer, laptop, 0x3E010C, 0x0100, -50, true);
    try testing.expectEqual(@as(usize, 4), devices.count(&layer));
    const phone_device = try deviceAt(&layer, phone, bluetooth.BTADDR_BREDR);
    try testing.expectEqual(bluetooth.BTADDR_BREDR, phone_device.address.kind);
    try testing.expectEqual(bluetooth.BTDF_LE | bluetooth.BTDF_CONNECTABLE | bluetooth.BTDF_BREDR, phone_device.flags);
    try testing.expectEqualStrings("Phone", std.mem.sliceTo(&phone_device.name, 0));
    try testing.expectEqual(@as(u32, 0x5A020C), phone_device.class_of_device);
    try testing.expectEqual(@as(u16, 0x1234), phone_device.clock_offset);
    const laptop_device = try deviceAt(&layer, laptop, bluetooth.BTADDR_BREDR);
    try testing.expectEqual(@as(u32, 0x3E010C), laptop_device.class_of_device);
    try testing.expectEqual(@as(i8, -50), laptop_device.rssi);
    try testing.expectEqual(@as(u8, 2), laptop_device.page_scan_repetition);

    // The inquiry over: the names not heard, the strongest first - the
    // laptop, its clock offset given as valid.
    event(&layer, hci.HCI_EV_INQUIRY_COMPLETE, &.{0});
    const asked = recorder.last();
    try testing.expectEqual(hci.HCI_OP_REMOTE_NAME_REQUEST, asked.opcode);
    try testing.expectEqualSlices(u8, &(laptop ++ [_]u8{ 2, 0, 0x00, 0x81 }), asked.params[0..10]);
    status(&layer, hci.HCI_OP_REMOTE_NAME_REQUEST, 0);
    nameComplete(&layer, 0, laptop, "Laptop");
    try testing.expectEqualStrings("Laptop", std.mem.sliceTo(&laptop_device.name, 0));
    // Then the headset, which does not answer its page.
    try testing.expectEqual(hci.HCI_OP_REMOTE_NAME_REQUEST, recorder.last().opcode);
    try testing.expectEqualSlices(u8, &headset, recorder.last().params[0..6]);
    status(&layer, hci.HCI_OP_REMOTE_NAME_REQUEST, 0);
    nameComplete(&layer, hci.HCI_ERR_PAGE_TIMEOUT, headset, "");
    const headset_device = try deviceAt(&layer, headset, bluetooth.BTADDR_BREDR);
    try testing.expect(headset_device.flags & bluetooth.BTDF_NO_NAME != 0);
    // Nobody is left to ask: the discovery is over.
    try testing.expect(!discovery.running(&layer));
    try testing.expect(_controller.flagsOf(&layer) & bluetooth.BTCF_DISCOVERING == 0);
    try testing.expectEqual(@as(?u64, null), _hci.nextDeadline(&layer));
}

test "a name not answered in its time is cancelled, and the next asked" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    layer.features[0][4] &= ~@as(u8, 1 << 6); // no LE: the inquiry first
    try testing.expectEqual(@as(i32, 0), discovery.start(&layer, 4000));
    try testing.expectEqual(hci.HCI_OP_INQUIRY, recorder.last().opcode);
    // All the time the inquiry's: 4 s are 4 units.
    try testing.expectEqual(@as(u8, 4), recorder.last().params[3]);
    status(&layer, hci.HCI_OP_INQUIRY, 0);
    rssiResult(&layer, headset, 0x240404, 0, -40, false);
    rssiResult(&layer, laptop, 0x3E010C, 0, -60, false);
    event(&layer, hci.HCI_EV_INQUIRY_COMPLETE, &.{0});
    try testing.expectEqualSlices(u8, &headset, recorder.last().params[0..6]);
    status(&layer, hci.HCI_OP_REMOTE_NAME_REQUEST, 0);
    // Its time up: cancelled, and its answer waited for.
    layer.now += discovery.NAME_TIMEOUT_MS;
    _hci.tick(&layer);
    try testing.expectEqual(hci.HCI_OP_REMOTE_NAME_REQUEST_CANCEL, recorder.last().opcode);
    try testing.expectEqualSlices(u8, &headset, recorder.last().params[0..6]);
    complete(&layer, hci.HCI_OP_REMOTE_NAME_REQUEST_CANCEL, &([_]u8{0} ++ headset));
    nameComplete(&layer, hci.HCI_ERR_UNKNOWN_CONNECTION, headset, "");
    try testing.expect((try deviceAt(&layer, headset, bluetooth.BTADDR_BREDR)).flags & bluetooth.BTDF_NO_NAME != 0);
    // The laptop next.
    try testing.expectEqual(hci.HCI_OP_REMOTE_NAME_REQUEST, recorder.last().opcode);
    try testing.expectEqualSlices(u8, &laptop, recorder.last().params[0..6]);
}

test "a phase whose command is refused is over, and the next begins" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try testing.expectEqual(@as(i32, 0), discovery.start(&layer, 10_000));
    complete(&layer, hci.HCI_OP_LE_SET_SCAN_PARAMETERS, &.{0});
    // LE's scan refused: turned off again, and the inquiry at once.
    const before = recorder.count;
    complete(&layer, hci.HCI_OP_LE_SET_SCAN_ENABLE, &.{hci.HCI_ERR_COMMAND_DISALLOWED});
    var seen: [8]u16 = undefined;
    try testing.expectEqualSlices(u16, &.{ hci.HCI_OP_LE_SET_SCAN_ENABLE, hci.HCI_OP_INQUIRY }, recorder.opcodes(before, &seen));
    // The inquiry refused: nothing to name, the discovery over.
    complete(&layer, hci.HCI_OP_LE_SET_SCAN_ENABLE, &.{0});
    status(&layer, hci.HCI_OP_INQUIRY, hci.HCI_ERR_COMMAND_DISALLOWED);
    try testing.expect(!discovery.running(&layer));
}

test "a discovery stopped: its part taken back, what it found kept" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try testing.expectEqual(@as(i32, 0), discovery.start(&layer, 10_000));
    complete(&layer, hci.HCI_OP_LE_SET_SCAN_PARAMETERS, &.{0});
    complete(&layer, hci.HCI_OP_LE_SET_SCAN_ENABLE, &.{0});
    layer.now += 5000;
    _hci.tick(&layer);
    complete(&layer, hci.HCI_OP_LE_SET_SCAN_ENABLE, &.{0});
    status(&layer, hci.HCI_OP_INQUIRY, 0);
    rssiResult(&layer, headset, 0x240404, 0, -40, false);
    discovery.stop(&layer);
    try testing.expectEqual(hci.HCI_OP_INQUIRY_CANCEL, recorder.last().opcode);
    try testing.expect(!discovery.running(&layer));
    try testing.expectEqual(@as(usize, 1), devices.count(&layer));
    // An Inquiry Complete that crossed the cancel changes nothing.
    const before = recorder.count;
    event(&layer, hci.HCI_EV_INQUIRY_COMPLETE, &.{0});
    try testing.expectEqual(before, recorder.count);
    // The next discovery begins without what this one found.
    try testing.expectEqual(@as(i32, 0), discovery.start(&layer, 10_000));
    try testing.expectEqual(@as(usize, 0), devices.count(&layer));
}

test "a controller that is off, not up, or looking already" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    layer.powered = false;
    try testing.expectEqual(bluetooth.BTERR_OFF, discovery.start(&layer, 0));
    layer.powered = true;
    layer.state = bluetooth.BTCS_STARTING;
    try testing.expectEqual(bluetooth.BTERR_NOTUP, discovery.start(&layer, 0));
    layer.state = bluetooth.BTCS_UP;
    try testing.expectEqual(@as(i32, 0), discovery.start(&layer, 0));
    const before = recorder.count;
    try testing.expectEqual(@as(i32, 0), discovery.start(&layer, 0));
    try testing.expectEqual(before, recorder.count);
    // Turned off while it looks: the discovery ends, the radio is silent.
    try testing.expectEqual(@as(i32, 0), local.setPowered(&layer, false));
    try testing.expect(!discovery.running(&layer));
    try testing.expectEqual(hci.HCI_OP_WRITE_SCAN_ENABLE, recorder.last().opcode);
    try testing.expectEqual(@as(u8, 0), recorder.last().params[0]);
    try testing.expectEqual(@as(u32, 0), _controller.flagsOf(&layer));
}

test "a full table keeps those heard strongest" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try testing.expectEqual(@as(i32, 0), discovery.start(&layer, 10_000));
    for (0..devices.DEVICES) |index| {
        const address = [6]u8{ @intCast(index), 0, 0, 0, 0, 0xC0 };
        advertised(&layer, hci.LE_ADV_NONCONN_IND, hci.LE_ADDR_RANDOM, address, &.{}, @intCast(-90 + @as(i32, @intCast(index % 20))));
    }
    try testing.expectEqual(@as(usize, devices.DEVICES), devices.count(&layer));
    // Weaker than every one: not kept. Stronger: in the weakest's place.
    advertised(&layer, hci.LE_ADV_NONCONN_IND, hci.LE_ADDR_RANDOM, .{ 0xEE, 0, 0, 0, 0, 0xC0 }, &.{}, -95);
    try testing.expect(devices.find(&layer, .{ 0xEE, 0, 0, 0, 0, 0xC0 }, bluetooth.BTADDR_LE_RANDOM) == null);
    advertised(&layer, hci.LE_ADV_NONCONN_IND, hci.LE_ADDR_RANDOM, .{ 0xEF, 0, 0, 0, 0, 0xC0 }, &.{}, -30);
    try testing.expect(devices.find(&layer, .{ 0xEF, 0, 0, 0, 0, 0xC0 }, bluetooth.BTADDR_LE_RANDOM) != null);
    try testing.expect(devices.find(&layer, .{ 0, 0, 0, 0, 0, 0xC0 }, bluetooth.BTADDR_LE_RANDOM) == null);
    try testing.expectEqual(@as(usize, devices.DEVICES), devices.count(&layer));
}

test "visible for a time ends at it; visible always does not" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    try testing.expectEqual(@as(i32, 0), local.setVisible(&layer, 120));
    try testing.expectEqual(hci.SCAN_PAGE | hci.SCAN_INQUIRY, recorder.last().params[0]);
    complete(&layer, hci.HCI_OP_WRITE_SCAN_ENABLE, &.{0});
    try testing.expectEqual(@as(u32, 120), local.visibleLeft(&layer, layer.now));
    try testing.expectEqual(@as(u32, 60), local.visibleLeft(&layer, layer.now + 60_000));
    try testing.expectEqual(@as(?u64, layer.now + 120_000), _hci.nextDeadline(&layer));
    const flags = _controller.flagsOf(&layer);
    try testing.expectEqual(bluetooth.BTCF_POWERED | bluetooth.BTCF_CONNECTABLE | bluetooth.BTCF_VISIBLE, flags);
    layer.now += 120_000;
    _hci.tick(&layer);
    try testing.expect(!layer.visible);
    try testing.expectEqual(hci.SCAN_PAGE, recorder.last().params[0]);
    complete(&layer, hci.HCI_OP_WRITE_SCAN_ENABLE, &.{0});
    try testing.expectEqual(@as(u32, 0), local.visibleLeft(&layer, layer.now));

    try testing.expectEqual(@as(i32, 0), local.setVisible(&layer, bluetooth.BT_VISIBLE_ALWAYS));
    complete(&layer, hci.HCI_OP_WRITE_SCAN_ENABLE, &.{0});
    try testing.expectEqual(bluetooth.BT_VISIBLE_ALWAYS, local.visibleLeft(&layer, layer.now));
    try testing.expectEqual(@as(?u64, null), _hci.nextDeadline(&layer));
    try testing.expectEqual(@as(i32, 0), local.setVisible(&layer, 0));
    try testing.expectEqual(hci.SCAN_PAGE, recorder.last().params[0]);

    // A name: Write Local Name and the response.
    const before = recorder.count;
    try testing.expectEqual(@as(i32, 0), local.setName(&layer, "Workbench"));
    var seen: [8]u16 = undefined;
    try testing.expectEqualSlices(u16, &.{ hci.HCI_OP_WRITE_LOCAL_NAME, hci.HCI_OP_WRITE_EXTENDED_INQUIRY_RESPONSE }, recorder.opcodes(before, &seen));
    try testing.expectEqualStrings("Workbench", std.mem.sliceTo(&layer.name, 0));
}

test "a controller that can neither answer inquiries nor advertise is not made visible" {
    var recorder = Recorder{};
    var layer = upLayer(&recorder);
    // BR/EDR not supported; LE, but no buffers for its links.
    layer.features[0][4] |= 1 << 5;
    try testing.expectEqual(bluetooth.BTERR_UNSUPPORTED, local.setVisible(&layer, 60));
    try testing.expectEqual(@as(i32, 0), local.setVisible(&layer, 0));
    try testing.expectEqual(@as(usize, 0), recorder.count);
    try testing.expectEqual(bluetooth.BTCF_POWERED, _controller.flagsOf(&layer));
}

test "the settings file's keywords, in any case; what it does not know passed over" {
    var kept: settings.Kept = .{};
    var scanner = sdk.dos.keywords.Scanner.ofText("/* kept */\npowered = no\nColour = 3\nVISIBLE = Yes\n");
    settings.readKeywords(&scanner, &kept);
    try testing.expect(!kept.powered);
    try testing.expect(kept.visible);
    kept = .{};
    scanner = sdk.dos.keywords.Scanner.ofText("Powered = 1\nVisible = 0\n");
    settings.readKeywords(&scanner, &kept);
    try testing.expect(kept.powered);
    try testing.expect(!kept.visible);
}

test "the machine's name: the hostname file's first line that is neither blank nor a comment" {
    const file = "# ENVARC:Sys/net/hostname - the machine's name\n# on the network.\n\n  desk\t \r\nother\n";
    try testing.expectEqualStrings("desk", settings.hostNameIn(file).?);
    try testing.expectEqual(@as(?[]const u8, null), settings.hostNameIn("# a comment alone\n\n"));
    try testing.expectEqual(@as(?[]const u8, null), settings.hostNameIn(""));
}

test "the controller's name: 247 bytes at most, cut at a whole character, a name file's first line" {
    try testing.expectEqual(@as(usize, 4), settings.nameLength("Desk\n"));
    try testing.expectEqual(@as(usize, 4), settings.nameLength("Desk\r\nmore"));
    try testing.expectEqual(@as(usize, 0), settings.nameLength(""));
    // A name of the most bytes, as the library writes it: its line's end
    // a byte past them.
    const longest = [_]u8{'a'} ** 247 ++ "\n";
    try testing.expectEqual(@as(usize, 247), settings.nameLength(longest));
    // A line longer than a name: cut, before a character the cut would
    // split.
    try testing.expectEqual(@as(usize, 247), settings.nameLength(&([_]u8{'a'} ** 249)));
    const split = [_]u8{'a'} ** 246 ++ "\xC3\xA4";
    try testing.expectEqual(@as(usize, 246), settings.nameLength(split));

    // Set: the same cut, and Write Local Name's 248 bytes end in a NUL.
    var recorder: Recorder = .{};
    var layer = upLayer(&recorder);
    try testing.expectEqual(@as(i32, 0), local.setName(&layer, &([_:0]u8{'n'} ** 300)));
    var length: usize = 0;
    while (layer.name[length] != 0) length += 1;
    try testing.expectEqual(local.NAME_MOST, length);
    var params: [hci.HCI_MAX_PARAMS]u8 = undefined;
    try testing.expectEqual(hci.HCI_MAX_NAME, local.nameParams(&layer, &params));
    try testing.expectEqual(@as(u8, 0), params[hci.HCI_MAX_NAME - 1]);
}

test "what a device is: its class's major and minor class, else its appearance" {
    // Nothing is read from the base.
    var base: BluetoothBase = undefined;
    try testing.expectEqual(bluetooth.BTDK_NONE, BTDeviceKind(&base, 0, 0));
    // A laptop (major 1, minor 3) with its service bits, a desktop.
    try testing.expectEqual(bluetooth.BTDK_LAPTOP, BTDeviceKind(&base, 0x7A010C, 0));
    try testing.expectEqual(bluetooth.BTDK_COMPUTER, BTDeviceKind(&base, 0x000104, 0));
    try testing.expectEqual(bluetooth.BTDK_PHONE, BTDeviceKind(&base, 0x5A020C, 0));
    // Headphones (audio/video, minor 6), a headset (1), and a set-top box
    // (9), which is audio/video that names no kind here.
    try testing.expectEqual(bluetooth.BTDK_HEADPHONES, BTDeviceKind(&base, 0x240418, 0));
    try testing.expectEqual(bluetooth.BTDK_HEADSET, BTDeviceKind(&base, 0x200404, 0));
    try testing.expectEqual(bluetooth.BTDK_AUDIO_VIDEO, BTDeviceKind(&base, 0x000424, 0));
    // Peripherals: the minor class's top bits, then its low four.
    try testing.expectEqual(bluetooth.BTDK_KEYBOARD, BTDeviceKind(&base, 0x002540, 0));
    try testing.expectEqual(bluetooth.BTDK_MOUSE, BTDeviceKind(&base, 0x002580, 0));
    try testing.expectEqual(bluetooth.BTDK_KEYBOARD_MOUSE, BTDeviceKind(&base, 0x0025C0, 0));
    try testing.expectEqual(bluetooth.BTDK_GAMEPAD, BTDeviceKind(&base, 0x002508, 0));
    try testing.expectEqual(bluetooth.BTDK_PERIPHERAL, BTDeviceKind(&base, 0x002500, 0));
    // A class that names no kind leaves it to the appearance, and the
    // class wins over an appearance.
    try testing.expectEqual(bluetooth.BTDK_KEYBOARD, BTDeviceKind(&base, 0x001F00, 0x03C1));
    try testing.expectEqual(bluetooth.BTDK_PHONE, BTDeviceKind(&base, 0x5A020C, 0x03C2));
    // Appearances: a subcategory that names a kind, else the category;
    // one not known.
    try testing.expectEqual(bluetooth.BTDK_MOUSE, BTDeviceKind(&base, 0, 0x03C2));
    try testing.expectEqual(bluetooth.BTDK_EARBUDS, BTDeviceKind(&base, 0, 0x0941));
    try testing.expectEqual(bluetooth.BTDK_LAPTOP, BTDeviceKind(&base, 0, 0x0083));
    try testing.expectEqual(bluetooth.BTDK_COMPUTER, BTDeviceKind(&base, 0, 0x0080));
    try testing.expectEqual(bluetooth.BTDK_WATCH, BTDeviceKind(&base, 0, 0x00C1));
    try testing.expectEqual(bluetooth.BTDK_PERIPHERAL, BTDeviceKind(&base, 0, 0x03C0));
    try testing.expectEqual(bluetooth.BTDK_NONE, BTDeviceKind(&base, 0, 0x0FC0));
}
