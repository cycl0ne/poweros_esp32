// SPDX-License-Identifier: MIT
//! Host tests of a record's data elements and the programs' records, on
//! the ROM's exec: NextBTDataElement reading integers - a signed one with
//! its sign - a boolean, UUIDs of 16 and 128 bits made 128, a text and a
//! sequence's elements in turn, and nothing that is not whole;
//! FindBTServiceAttribute finding an attribute's value, and none where
//! the record has not it or is no record; AddBTService giving each record
//! a handle of its own in place of the one it names, refusing bytes that
//! are not a record, ids that do not rise and a record too long; the
//! task's upcall copying them out in their order; RemBTService.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const sdp = bluetooth.sdp;
const kexec = @import("host_rom").exec;
const utility_library = @import("host_rom").utility;
const bluetooth_init = @import("../bluetooth_init.zig");
const _base = @import("../bluetooth_base.zig");
const _controller = @import("../controller/_controller.zig");
const _sdp = @import("../sdp/_sdp.zig");
const sdp_server = @import("../sdp/server.zig");
const taskrecords = @import("../task/records.zig");
const NextBTDataElement = @import("../service/nextbtdataelement.zig").NextBTDataElement;
const FindBTServiceAttribute = @import("../service/findbtserviceattribute.zig").FindBTServiceAttribute;
const AddBTService = @import("../service/addbtservice.zig").AddBTService;
const RemBTService = @import("../service/rembtservice.zig").RemBTService;

const testing = std.testing;

fn sendNothing(context: *anyopaque, packet_type: u8, bytes: []const u8) bool {
    _ = context;
    _ = packet_type;
    _ = bytes;
    return true;
}

/// A record: its class a HID device's, over L2CAP's PSM 17, a name, and
/// a list of two descriptors (a profile's own attribute).
const record = _sdp.sequence(&(_sdp.uint16(sdp.ATTR_SERVICE_CLASS_ID_LIST) ++ _sdp.sequence(&_sdp.uuid16(0x1124)) ++
    _sdp.uint16(sdp.ATTR_PROTOCOL_DESCRIPTOR_LIST) ++ _sdp.sequence(&(_sdp.sequence(&(_sdp.uuid16(sdp.UUID_L2CAP) ++ _sdp.uint16(0x0011))) ++
    _sdp.sequence(&_sdp.uuid16(0x0011)))) ++
    _sdp.uint16(sdp.ATTR_SERVICE_NAME) ++ [_]u8{ 0x25, 3, 'K', 'e', 'y' } ++
    _sdp.uint16(0x0206) ++ _sdp.sequence(&(_sdp.sequence(&([_]u8{ 0x08, 0x22, 0x25, 2, 0x05, 0x01 })) ++ [_]u8{ 0x28, 1 }))));

test "data elements: integers, a signed one's sign, a boolean, UUIDs made 128 bits, a text, a sequence in turn, none not whole" {
    const kub = try utility_library.setUp();
    const made = kexec.InitResident(kexec.SysBase, &bluetooth_init.bluetooth_library_tag, null) orelse return error.NoLibrary;
    const lib: *exec.Library = @ptrCast(@alignCast(made));
    const base = _base.bluetoothBase(lib);

    var element: bluetooth.BTDataElement = .{};
    // An unsigned integer of 1 byte, and one of 8.
    try testing.expect(NextBTDataElement(base, &[_]u8{ 0x08, 42, 0xFF }, 3, &element));
    try testing.expectEqual(@as(u32, sdp.DE_UINT), element.kind);
    try testing.expectEqual(@as(u32, 2), element.whole);
    try testing.expectEqual(@as(u64, 42), element.value);
    try testing.expect(NextBTDataElement(base, &[_]u8{ 0x0B, 1, 2, 3, 4, 5, 6, 7, 8 }, 9, &element));
    try testing.expectEqual(@as(u64, 0x0102030405060708), element.value);
    // A signed one of 2 bytes, -2; a boolean.
    try testing.expect(NextBTDataElement(base, &[_]u8{ 0x11, 0xFF, 0xFE }, 3, &element));
    try testing.expectEqual(@as(i64, -2), @as(i64, @bitCast(element.value)));
    try testing.expect(NextBTDataElement(base, &[_]u8{ 0x28, 1 }, 2, &element));
    try testing.expectEqual(@as(u32, sdp.DE_BOOL), element.kind);
    try testing.expectEqual(@as(u64, 1), element.value);
    // UUIDs: 16 bits on the base, and 128 as they are.
    try testing.expect(NextBTDataElement(base, &[_]u8{ 0x19, 0x11, 0x24 }, 3, &element));
    var expected = sdp.BASE_UUID;
    expected[2] = 0x11;
    expected[3] = 0x24;
    try testing.expectEqualSlices(u8, &expected, &element.uuid.bytes);
    try testing.expectEqual(@as(u64, 0), element.value);
    const long = [_]u8{0x1C} ++ [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF };
    try testing.expect(NextBTDataElement(base, &long, long.len, &element));
    try testing.expectEqualSlices(u8, long[1..], &element.uuid.bytes);
    // A text: its bytes where they are.
    const text = [_]u8{ 0x25, 3, 'a', 'b', 'c' };
    try testing.expect(NextBTDataElement(base, &text, text.len, &element));
    try testing.expectEqual(@as(u32, sdp.DE_TEXT), element.kind);
    try testing.expectEqualStrings("abc", element.data.?[0..element.length]);
    try testing.expectEqual(@as(?[*]const u8, text[2..].ptr), element.data);
    // A sequence's elements, one after the other.
    const list = [_]u8{ 0x35, 0x06, 0x09, 0x01, 0x00, 0x19, 0x00, 0x11 };
    try testing.expect(NextBTDataElement(base, &list, list.len, &element));
    try testing.expectEqual(@as(u32, sdp.DE_SEQUENCE), element.kind);
    try testing.expectEqual(@as(u32, 6), element.length);
    var item: bluetooth.BTDataElement = .{};
    var at: u32 = 0;
    var kinds: [2]u32 = undefined;
    var count: usize = 0;
    while (at < element.length and NextBTDataElement(base, element.data.? + at, element.length - at, &item)) : (at += item.whole) {
        kinds[count] = item.kind;
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualSlices(u32, &.{ sdp.DE_UINT, sdp.DE_UUID }, &kinds);
    // Not whole: nothing read, the element as it was.
    element = .{ .kind = 99 };
    try testing.expect(!NextBTDataElement(base, &list, 5, &element));
    try testing.expect(!NextBTDataElement(base, &[_]u8{0x09}, 1, &element));
    try testing.expect(!NextBTDataElement(base, &list, 0, &element));
    try testing.expectEqual(@as(u32, 99), element.kind);

    // An attribute's value found in a record; none it has not; no record.
    try testing.expect(FindBTServiceAttribute(base, &record, record.len, sdp.ATTR_SERVICE_NAME, &element));
    try testing.expectEqualStrings("Key", element.data.?[0..element.length]);
    try testing.expect(FindBTServiceAttribute(base, &record, record.len, 0x0206, &element));
    try testing.expectEqual(@as(u32, sdp.DE_SEQUENCE), element.kind);
    try testing.expect(NextBTDataElement(base, element.data.?, element.length, &item));
    try testing.expectEqual(@as(u32, sdp.DE_SEQUENCE), item.kind);
    try testing.expect(!FindBTServiceAttribute(base, &record, record.len, sdp.ATTR_PROFILE_DESCRIPTOR_LIST, &element));
    try testing.expect(!FindBTServiceAttribute(base, &text, text.len, sdp.ATTR_SERVICE_NAME, &element));
    try testing.expect(!FindBTServiceAttribute(base, &record, 10, sdp.ATTR_SERVICE_NAME, &element));

    _ = base.sys_base.RemLibrary(lib);
    try utility_library.tearDown(kub);
    kexec.deinit();
}

test "the programs' records: each given a handle of its own, refused where it is no record, copied out in order, given back" {
    const kub = try utility_library.setUp();
    const made = kexec.InitResident(kexec.SysBase, &bluetooth_init.bluetooth_library_tag, null) orelse return error.NoLibrary;
    const lib: *exec.Library = @ptrCast(@alignCast(made));
    const base = _base.bluetoothBase(lib);
    var controller = _controller.Controller{ .base = base, .id = 3, .layer = .{ .port = .{ .context = undefined, .send = sendNothing } } };
    var into: [sdp_server.RECORD_MOST]u8 = undefined;

    // The first: its handle first among its attributes, the rest as given.
    const first = AddBTService(base, &record, record.len) orelse return error.NotAdded;
    const served = taskrecords.record(&controller, 0, &into) orelse return error.NotServed;
    try testing.expectEqual(sdp.SDP_HANDLE_FIRST, served.handle);
    const head = [_]u8{ 0x36, 0x00, @intCast(record.len - 2 + 8), 0x09, 0x00, 0x00, 0x0A, 0x00, 0x01, 0x00, 0x00 };
    try testing.expectEqualSlices(u8, &head, served.bytes[0..head.len]);
    try testing.expectEqualSlices(u8, record[2..], served.bytes[head.len..]);
    // A second, naming a handle of its own: given the next one instead.
    const named = _sdp.sequence(&(_sdp.uint16(sdp.ATTR_SERVICE_RECORD_HANDLE) ++ _sdp.uint32(0x12345678) ++
        _sdp.uint16(sdp.ATTR_SERVICE_CLASS_ID_LIST) ++ _sdp.sequence(&_sdp.uuid16(0x1101))));
    const second = AddBTService(base, &named, named.len) orelse return error.NotAdded;
    const next = taskrecords.record(&controller, 1, &into) orelse return error.NotServed;
    try testing.expectEqual(sdp.SDP_HANDLE_FIRST + 1, next.handle);
    try testing.expectEqualSlices(u8, &([_]u8{ 0x36, 0x00, 16, 0x09, 0x00, 0x00, 0x0A, 0x00, 0x01, 0x00, 0x01 } ++ named[10..].*), next.bytes);
    try testing.expect(taskrecords.record(&controller, 2, &into) == null);

    // Not a record: no sequence, not whole, an id not of 16 bits, ids not
    // rising, an id without a value; and one too long.
    try testing.expect(AddBTService(base, &[_]u8{ 0x09, 0x00, 0x01 }, 3) == null);
    try testing.expect(AddBTService(base, &record, record.len - 1) == null);
    try testing.expect(AddBTService(base, &[_]u8{ 0x35, 0x07, 0x0A, 0x00, 0x00, 0x00, 0x01, 0x08, 0x01 }, 9) == null);
    const falling = _sdp.sequence(&(_sdp.uint16(sdp.ATTR_PROTOCOL_DESCRIPTOR_LIST) ++ [_]u8{ 0x08, 1 } ++ _sdp.uint16(sdp.ATTR_SERVICE_CLASS_ID_LIST) ++ [_]u8{ 0x08, 1 }));
    try testing.expect(AddBTService(base, &falling, falling.len) == null);
    try testing.expect(AddBTService(base, &[_]u8{ 0x35, 0x03, 0x09, 0x00, 0x01 }, 5) == null);
    const too_long = try testing.allocator.alloc(u8, 5 + sdp_server.RECORD_MOST);
    defer testing.allocator.free(too_long);
    const text_length = too_long.len - 5 - 3 - 3;
    too_long[0..8].* = .{ 0x37, 0, 0, @truncate((too_long.len - 5) >> 8), @truncate(too_long.len - 5), 0x09, 0x01, 0x00 };
    too_long[8..11].* = .{ 0x26, @truncate(text_length >> 8), @truncate(text_length) };
    @memset(too_long[11..], 'x');
    try testing.expect(AddBTService(base, too_long.ptr, @intCast(too_long.len)) == null);
    try testing.expect(taskrecords.record(&controller, 2, &into) == null);

    // The first given back: the second is the first now; nothing after.
    RemBTService(base, first);
    try testing.expectEqual(sdp.SDP_HANDLE_FIRST + 1, (taskrecords.record(&controller, 0, &into) orelse return error.NotServed).handle);
    try testing.expect(taskrecords.record(&controller, 1, &into) == null);
    RemBTService(base, second);
    RemBTService(base, null);
    try testing.expect(taskrecords.record(&controller, 0, &into) == null);
    try testing.expect(base.records.isEmpty());

    _ = base.sys_base.RemLibrary(lib);
    try utility_library.tearDown(kub);
    kexec.deinit();
}
