// SPDX-License-Identifier: MIT
//! Host tests of the profile drivers' binder, on the ROM's exec: a
//! service offered to the drivers that match it, the higher priority
//! first, one that declines closed again; the bindings on the base's
//! list, the drivers named with the bond by ObtainBTBonds, and their end -
//! with BTPU_FORGET where the bond is forgotten - closing a driver once it
//! drives nothing; the matches by kind of link and by class; a service
//! made from a kept record and copied; the kept services' file beside the
//! bond's, written and read again; and the binder's messages kept for the
//! start the task makes, tried again while the library's lock is taken
//! and done with where it cannot start.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const btprofile = sdk.devices.btprofile;
const kexec = @import("host_rom").exec;
const utility_library = @import("host_rom").utility;
const bluetooth_init = @import("../bluetooth_init.zig");
const _base = @import("../bluetooth_base.zig");
const _controller = @import("../controller/_controller.zig");
const _service = @import("../service/_service.zig");
const _profile = @import("../profile/_profile.zig");
const binder = @import("../profile/binder.zig");
const drivers = @import("../profile/drivers.zig");
const kept = @import("../profile/kept.zig");
const att_client = @import("../att/client.zig");
const standin = @import("profile_driver.zig");

const testing = std.testing;

const Declining = standin.Standin("bluetooth/declining.device");
const Taking = standin.Standin("bluetooth/taking.device");

const controller_address = [6]u8{ 0x01, 0x10, 0xEF, 0x5E, 0x00, 0x00 };
const device: bluetooth.BTAddress = .{ .bytes = .{ 0x02, 0x10, 0xEF, 0x5E, 0x00, 0x00 }, .kind = bluetooth.BTADDR_BREDR };

/// A HID device's record: its handle (0x000100xx), its class (0x1124) and
/// its PSM (0x11).
fn hidRecord(comptime handle_low: u8) [36]u8 {
    const handle_attribute = [_]u8{ 0x09, 0x00, 0x00, 0x0A, 0x00, 0x01, 0x00, handle_low };
    const class_attribute = [_]u8{ 0x09, 0x00, 0x01, 0x35, 0x03, 0x19, 0x11, 0x24 };
    const protocol_attribute = [_]u8{ 0x09, 0x00, 0x04, 0x35, 0x0D, 0x35, 0x06, 0x19, 0x01, 0x00, 0x09, 0x00, 0x11, 0x35, 0x03, 0x19, 0x00, 0x11 };
    return [_]u8{ 0x35, 0x22 } ++ handle_attribute ++ class_attribute ++ protocol_attribute;
}

fn sendNothing(context: *anyopaque, packet_type: u8, bytes: []const u8) bool {
    _ = context;
    _ = packet_type;
    _ = bytes;
    return true;
}

/// One driver of the table, by the name it is opened by, with one entry.
fn setDriver(driver: *drivers.Driver, comptime name: []const u8, entry: btprofile.BTMatch) void {
    driver.* = .{};
    @memcpy(driver.name[0..name.len], name);
    driver.matches[0] = entry;
    driver.match_count = 1;
}

/// The drivers ObtainBTBonds names with the controller's first bond.
fn driversNamed(base: *_base.BluetoothBase, into: []u8) ![]const u8 {
    const bt = _base.interface(base);
    const list = bt.ObtainBTBonds(3) orelse return error.NoMemory;
    defer bt.ReleaseBTBonds(list);
    const bond: *const bluetooth.BTBond = @ptrCast(@alignCast(list.first() orelse return error.NoBond));
    const named = std.mem.span(bond.drivers orelse return error.NoDrivers);
    @memcpy(into[0..named.len], named);
    return into[0..named.len];
}

/// A service made from a HID record, bound.
fn bindHid(base: *_base.BluetoothBase, comptime handle_low: u8) !bool {
    const record = hidRecord(handle_low);
    var made: ?*exec.List = null;
    try testing.expectEqual(@as(i32, 0), _service.makeOne(base, 3, device, &record, &made));
    return binder.bind(base, 3, device, made.?);
}

test "a service offered to the drivers that match it, the higher priority first: one that declines closed again, the one that takes it named with the bond and let go, with BTPU_FORGET where the bond is forgotten" {
    const kub = try utility_library.setUp();
    const made = kexec.InitResident(kexec.SysBase, &bluetooth_init.bluetooth_library_tag, null) orelse return error.NoLibrary;
    const lib: *exec.Library = @ptrCast(@alignCast(made));
    const base = _base.bluetoothBase(lib);
    const sys = base.sys_base;
    const declining_made = kexec.InitResident(kexec.SysBase, &Declining.tag, null) orelse return error.NoDevice;
    const declining = standin.driverOf(@ptrCast(@alignCast(declining_made)));
    declining.takes = false;
    const taking_made = kexec.InitResident(kexec.SysBase, &Taking.tag, null) orelse return error.NoDevice;
    const taking = standin.driverOf(@ptrCast(@alignCast(taking_made)));

    // The table as DEVS:bluetooth/ would have given it, freed with the
    // library: the declining driver asked first by its priority, one that
    // takes the class over LE never.
    const memory = sys.AllocMem(@sizeOf(drivers.Drivers), exec.MEMF_CLEAR) orelse return error.NoMemory;
    const table: *drivers.Drivers = @ptrCast(@alignCast(memory));
    table.* = .{ .disk_read = true, .count = 3 };
    setDriver(&table.list[0], Taking.NAME, .{ .over = btprofile.BTMATCH_BREDR, .class16 = 0x1124 });
    setDriver(&table.list[1], Declining.NAME, .{ .over = btprofile.BTMATCH_BREDR, .priority = 5, .class16 = 0x1124 });
    setDriver(&table.list[2], "bluetooth/le.device", .{ .over = btprofile.BTMATCH_LE, .priority = 9, .class16 = 0x1124 });
    base.profile_drivers = table;

    var controller = _controller.Controller{ .base = base, .id = 3, .layer = .{ .port = .{ .context = undefined, .send = sendNothing } } };
    sys.AddTail(&base.controllers, &controller.node);
    controller.layer.bonds[0] = .{ .used = true, .address = device };
    var names: [bluetooth.BT_BOND_DRIVERS_MOST + 1]u8 = undefined;
    try testing.expectEqualStrings("", try driversNamed(base, &names));

    // The first service: the declining driver asked and closed again, the
    // other taking it and kept open.
    try testing.expect(try bindHid(base, 0x00));
    try testing.expectEqual(@as(u32, 1), declining.offers);
    try testing.expectEqual(@as(u32, 0), declining.binds);
    try testing.expectEqual(@as(u16, 0x1124), declining.last_class);
    try testing.expectEqual(0, declining.dev.open_cnt);
    try testing.expectEqual(@as(u32, 1), taking.binds);
    try testing.expectEqual(@as(u32, 0x0001_0000), taking.last_handle);
    try testing.expectEqual(1, taking.dev.open_cnt);
    try testing.expectEqual(@as(u32, 1), table.list[0].binds);
    const bound = _profile.boundOf(base.bindings.first().?);
    try testing.expectEqual(@as(u32, 1), bound.public.unit);
    try testing.expectEqual(@as(u16, 0x11), bound.public.service.?.psm);
    try testing.expect(_profile.isBound(base, 3, device, null));
    try testing.expect(_profile.isBound(base, 3, device, 0x0001_0000));
    try testing.expect(!_profile.isBound(base, 3, device, 0x0001_0001));
    try testing.expect(!_profile.isBound(base, 4, device, null));
    try testing.expectEqualStrings("taking.device", try driversNamed(base, &names));

    // A second service of the device's to the same driver: named once.
    try testing.expect(try bindHid(base, 0x01));
    try testing.expectEqual(@as(u32, 2), declining.offers);
    try testing.expectEqual(@as(u32, 2), taking.binds);
    try testing.expectEqual(1, taking.dev.open_cnt);
    try testing.expectEqualStrings("taking.device", try driversNamed(base, &names));

    // A service no driver takes: its list freed, nothing bound.
    taking.takes = false;
    try testing.expect(!try bindHid(base, 0x02));
    taking.takes = true;
    try testing.expectEqual(@as(u32, 2), table.list[0].binds);

    // The bond forgotten: both let go with BTPU_FORGET, the driver closed.
    binder.endAll(base, 3, device, bluetooth.BTPU_FORGET);
    try testing.expectEqual(@as(u32, 2), taking.unbinds);
    try testing.expectEqual(@as(u32, 0), taking.holding);
    try testing.expectEqual(bluetooth.BTPU_FORGET, taking.last_flags);
    try testing.expectEqual(0, taking.dev.open_cnt);
    try testing.expect(base.bindings.isEmpty());
    try testing.expectEqualStrings("", try driversNamed(base, &names));

    // Bound again, then another controller gone - nothing - and its own.
    try testing.expect(try bindHid(base, 0x00));
    binder.endAll(base, 4, null, 0);
    try testing.expectEqual(@as(u32, 1), taking.holding);
    binder.endAll(base, 3, null, 0);
    try testing.expectEqual(@as(u32, 0), taking.holding);
    try testing.expectEqual(@as(u32, 0), taking.last_flags);
    try testing.expectEqual(0, taking.dev.open_cnt);
    try testing.expect(base.bindings.isEmpty());

    sys.Remove(&controller.node);
    _ = sys.RemDevice(&declining.dev);
    _ = sys.RemDevice(&taking.dev);
    _ = sys.RemLibrary(lib);
    try utility_library.tearDown(kub);
    kexec.deinit();
}

test "the matches: a service by the kind of link it is reached over, and by its class in 16 bits or in 128" {
    const vendor: bluetooth.BTUUID = .{ .bytes = .{ 0x6E, 0x40, 0x00, 0x01, 0xB5, 0xA3, 0xF3, 0x93, 0xE0, 0xA9, 0xE5, 0x0E, 0x24, 0xDC, 0xCA, 0x9E } };
    var other = vendor;
    other.bytes[3] = 0x02;
    const sdp_hid = bluetooth.BTService{ .flags = bluetooth.BTSF_SDP, .class16 = 0x1124 };
    const gatt_hid = bluetooth.BTService{ .flags = bluetooth.BTSF_GATT, .class16 = 0x1812 };
    const sdp_vendor = bluetooth.BTService{ .flags = bluetooth.BTSF_SDP, .class = vendor };
    try testing.expect(drivers.takes(.{ .over = btprofile.BTMATCH_BREDR, .class16 = 0x1124 }, &sdp_hid));
    try testing.expect(!drivers.takes(.{ .over = btprofile.BTMATCH_BREDR, .class16 = 0x1108 }, &sdp_hid));
    try testing.expect(!drivers.takes(.{ .over = btprofile.BTMATCH_LE, .class16 = 0x1124 }, &sdp_hid));
    try testing.expect(drivers.takes(.{ .over = btprofile.BTMATCH_LE, .class16 = 0x1812 }, &gatt_hid));
    try testing.expect(!drivers.takes(.{ .over = btprofile.BTMATCH_BREDR, .class16 = 0x1812 }, &gatt_hid));
    try testing.expect(drivers.takes(.{ .over = btprofile.BTMATCH_BREDR, .class = vendor }, &sdp_vendor));
    try testing.expect(!drivers.takes(.{ .over = btprofile.BTMATCH_BREDR, .class = other }, &sdp_vendor));
    // A class of 16 bits is not looked for in the 128.
    try testing.expect(!drivers.takes(.{ .over = btprofile.BTMATCH_BREDR, .class16 = 0x1124 }, &sdp_vendor));

    var table: drivers.Drivers = .{ .count = 1 };
    setDriver(&table.list[0], "bluetooth/hid.device", .{ .over = btprofile.BTMATCH_BREDR, .class16 = 0x1124 });
    try testing.expect(drivers.wants(&table, btprofile.BTMATCH_BREDR));
    try testing.expect(!drivers.wants(&table, btprofile.BTMATCH_LE));
    try testing.expectEqualStrings("hid.device", drivers.nameOf(&table.list[0]));
}

/// The services `kept.parse` hands over, copied: a record's bytes, or a
/// GATT service.
const Collected = struct {
    count: usize = 0,
    records: [4][64]u8 = undefined,
    lengths: [4]usize = @splat(0),
    gatt: [4]?att_client.ServiceRecord = @splat(null),

    fn each(collected: *Collected, service: kept.Kept) void {
        if (collected.count == collected.records.len) return;
        switch (service) {
            .record => |record| {
                @memcpy(collected.records[collected.count][0..record.len], record);
                collected.lengths[collected.count] = record.len;
            },
            .gatt => |gatt| collected.gatt[collected.count] = gatt,
        }
        collected.count += 1;
    }

    fn at(collected: *const Collected, index: usize) []const u8 {
        return collected.records[index][0..collected.lengths[index]];
    }
};

test "the services kept with a bond: beside its file, a line a record or a GATT service, read again in their order, a line that is neither passed over; a service made from one, and copied" {
    const kub = try utility_library.setUp();
    const made = kexec.InitResident(kexec.SysBase, &bluetooth_init.bluetooth_library_tag, null) orelse return error.NoLibrary;
    const lib: *exec.Library = @ptrCast(@alignCast(made));
    const base = _base.bluetoothBase(lib);
    const sys = base.sys_base;

    const path = kept.pathOf(&controller_address, &device);
    try testing.expectEqualStrings("ENVARC:Sys/bluetooth/00005EEF1001/00005EEF1002.services", std.mem.sliceTo(&path, 0));
    const le_device: bluetooth.BTAddress = .{ .bytes = device.bytes, .kind = bluetooth.BTADDR_LE_RANDOM };
    const le_path = kept.pathOf(&controller_address, &le_device);
    try testing.expectEqualStrings("ENVARC:Sys/bluetooth/00005EEF1001/00005EEF1002.random.services", std.mem.sliceTo(&le_path, 0));

    // Two records written and read again.
    const first = hidRecord(0x00);
    const second = hidRecord(0x01);
    const one = bluetooth.BTService{ .record = &first, .record_length = first.len };
    const two = bluetooth.BTService{ .record = &second, .record_length = second.len };
    const services = [_]*const bluetooth.BTService{ &one, &two };
    var text: [512]u8 = undefined;
    const size = kept.textSize(&services);
    const length = kept.format(&services, text[0..size]);
    try testing.expectEqual(size, length);
    try testing.expect(std.mem.indexOf(u8, text[0..length], "\nRecord 35220900000A00010000090001350319112409") != null);
    var collected: Collected = .{};
    kept.parse(text[0..length], &collected, Collected.each);
    try testing.expectEqual(@as(usize, 2), collected.count);
    try testing.expectEqualSlices(u8, &first, collected.at(0));
    try testing.expectEqualSlices(u8, &second, collected.at(1));

    // A file edited by hand: a bad digit, an odd count of digits, another
    // keyword or this one in lower case passed over; a digit in lower
    // case, a space and a CR at the end taken.
    var edited = "Record 3G00\nRecord 350\nOther 3500\nRecord 35 00\nrecord 3500\nRecord 35\nRecord 3a00 \r\n".*;
    collected = .{};
    kept.parse(&edited, &collected, Collected.each);
    try testing.expectEqual(@as(usize, 2), collected.count);
    try testing.expectEqualSlices(u8, &.{0x35}, collected.at(0));
    try testing.expectEqualSlices(u8, &.{ 0x3A, 0x00 }, collected.at(1));

    // A GATT service beside a record: its handles and UUID on a line of
    // its own, read back; one a handle short, or with a bad digit or a
    // space in its UUID, passed over.
    const hid_uuid = [16]u8{ 0x00, 0x00, 0x18, 0x12, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB };
    const over_le = bluetooth.BTService{ .flags = bluetooth.BTSF_GATT, .class = .{ .bytes = hid_uuid }, .class16 = 0x1812, .handle = 0x0010, .end_handle = 0x002F };
    const both = [_]*const bluetooth.BTService{ &over_le, &one };
    const both_size = kept.textSize(&both);
    const both_length = kept.format(&both, text[0..both_size]);
    try testing.expectEqual(both_size, both_length);
    try testing.expect(std.mem.indexOf(u8, text[0..both_length], "\nGatt 0010 002F 0000181200001000800000805F9B34FB\nRecord 3522") != null);
    collected = .{};
    kept.parse(text[0..both_length], &collected, Collected.each);
    try testing.expectEqual(@as(usize, 2), collected.count);
    const read_back = collected.gatt[0].?;
    try testing.expectEqual(@as(u16, 0x0010), read_back.start);
    try testing.expectEqual(@as(u16, 0x002F), read_back.end);
    try testing.expectEqualSlices(u8, &hid_uuid, &read_back.uuid);
    try testing.expectEqualSlices(u8, &first, collected.at(1));
    var broken = "Gatt 0010 0000181200001000800000805F9B34FB\nGatt 0010 002F 0000181200001000800000805F9B34FG\nGatt 0001 0005 00001800000010008000 00805F9B34F\n".*;
    collected = .{};
    kept.parse(&broken, &collected, Collected.each);
    try testing.expectEqual(@as(usize, 0), collected.count);

    // A GATT service made from its line, as ObtainBTServices lists a
    // device's over LE.
    var gatt_list: ?*exec.List = null;
    try testing.expectEqual(@as(i32, 0), _service.makeGatt(base, 3, le_device, @as([*]const u8, @ptrCast(&read_back))[0..@sizeOf(att_client.ServiceRecord)], &gatt_list));
    const made_gatt: *const bluetooth.BTService = @ptrCast(@alignCast(gatt_list.?.first().?));
    try testing.expectEqual(bluetooth.BTSF_GATT, made_gatt.flags);
    try testing.expectEqual(@as(u16, 0x1812), made_gatt.class16);
    try testing.expectEqual(@as(u32, 0x0010), made_gatt.handle);
    try testing.expectEqual(@as(u32, 0x002F), made_gatt.end_handle);
    _base.interface(base).ReleaseBTServices(gatt_list);

    // A record made a service, as ObtainBTServices lists a device's; bytes
    // that are no whole record refused.
    var list: ?*exec.List = null;
    try testing.expectEqual(bluetooth.BTERR_PROTOCOL, _service.makeOne(base, 3, device, &.{0x35}, &list));
    try testing.expectEqual(bluetooth.BTERR_PROTOCOL, _service.makeOne(base, 3, device, &(first ++ [_]u8{0x00}), &list));
    try testing.expectEqual(bluetooth.BTERR_PROTOCOL, _service.makeOne(base, 3, device, &.{ 0x09, 0x00, 0x00 }, &list));
    try testing.expect(list == null);
    try testing.expectEqual(@as(i32, 0), _service.makeOne(base, 3, device, &first, &list));
    const service: *const bluetooth.BTService = @ptrCast(@alignCast(list.?.first().?));
    try testing.expectEqual(@as(u32, 3), service.controller);
    try testing.expectEqualSlices(u8, &device.bytes, &service.address.bytes);
    try testing.expectEqual(bluetooth.BTSF_SDP, service.flags);
    try testing.expectEqual(@as(u16, 0x1124), service.class16);
    try testing.expectEqual(@as(u16, 0x11), service.psm);
    try testing.expectEqual(@as(u32, 0x0001_0000), service.handle);
    try testing.expectEqualSlices(u8, &first, service.record.?[0..service.record_length]);
    var entries: usize = 0;
    var it = list.?.iterator();
    while (it.next()) |_| entries += 1;
    try testing.expectEqual(@as(usize, 1), entries);

    // Copied into a list of its own: its record and name its own too.
    const copied = _service.copy(base, service) orelse return error.NoMemory;
    const copy: *const bluetooth.BTService = @ptrCast(@alignCast(copied.first().?));
    try testing.expectEqual(@as(u16, 0x1124), copy.class16);
    try testing.expectEqual(@as(u32, 0x0001_0000), copy.handle);
    try testing.expect(copy.record.? != service.record.?);
    try testing.expectEqualSlices(u8, &first, copy.record.?[0..copy.record_length]);
    try testing.expectEqualStrings("", std.mem.span(copy.node.name.?));
    const bt = _base.interface(base);
    bt.ReleaseBTServices(copied);
    bt.ReleaseBTServices(list);

    _ = sys.RemLibrary(lib);
    try utility_library.tearDown(kub);
    kexec.deinit();
}

test "the binder's messages: kept for the start the task makes, tried again while the library's lock is taken, done with where it cannot start; none sent where it neither runs nor is to start" {
    const kub = try utility_library.setUp();
    const made = kexec.InitResident(kexec.SysBase, &bluetooth_init.bluetooth_library_tag, null) orelse return error.NoLibrary;
    const lib: *exec.Library = @ptrCast(@alignCast(made));
    const base = _base.bluetoothBase(lib);
    const sys = base.sys_base;

    // Neither running nor to start: a message that does not start it is
    // not sent, and UnpairBTDevice's returns at once.
    try testing.expect(!_profile.tell(base, .gone, 3, controller_address, .{}, false));
    _profile.forget(base, 3, device);
    try testing.expect(!_profile.startPending(base));
    try testing.expect(_profile.startWanted(base));

    // One that starts it is kept, and one that does not behind it.
    try testing.expect(_profile.tell(base, .up, 3, controller_address, .{}, true));
    try testing.expect(_profile.startPending(base));
    try testing.expect(_profile.tell(base, .gone, 3, controller_address, .{}, false));
    var waiting: usize = 0;
    var it = base.binder_queue.iterator();
    while (it.next()) |_| waiting += 1;
    try testing.expectEqual(@as(usize, 2), waiting);

    // The library's lock held, as an opener holds it: the start left for
    // the task's next pass.
    sys.ObtainSemaphoreShared(&base.lib.lock);
    try testing.expect(_profile.startWanted(base));
    try testing.expect(_profile.startPending(base));
    sys.ReleaseSemaphore(&base.lib.lock);
    try testing.expect(!base.binder_queue.isEmpty());

    // Without dos the process cannot be made: both done with - freed -
    // and the open count as it was.
    const open_count = lib.open_cnt;
    try testing.expect(!_profile.startWanted(base));
    try testing.expect(!_profile.startPending(base));
    try testing.expect(base.binder_queue.isEmpty());
    try testing.expect(base.binder == null);
    try testing.expectEqual(open_count, lib.open_cnt);
    try testing.expect(!_profile.tell(base, .gone, 3, controller_address, .{}, false));

    _ = sys.RemLibrary(lib);
    try utility_library.tearDown(kub);
    kexec.deinit();
}
