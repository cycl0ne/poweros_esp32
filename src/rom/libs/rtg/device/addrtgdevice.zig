// SPDX-License-Identifier: MPL-2.0
//! AddRtgDevice: A device the library cannot find by itself, made from
//! tags and offered.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const RtgBase = @import("../rtg.zig").RtgBase;
const _device = @import("_device.zig");

/// Makes a device from tags and offers it to the drivers.
///
/// SYNOPSIS:
/// ```zig
/// fn AddRtgDevice(rb: *RtgBase, tag_list: ?[*]const TagItem) ?*rtg.RtgDevice
/// ```
///
/// SINCE: 1.18. LVO -284.
///
/// INPUTS:
/// - `tag_list` - what the device is, in the tags a panel part of the
///   board's list has: `PART_Chip`, `PART_Bus`, `PART_ChipName`, and the
///   `RTGA_` tags its driver reads. Read for as long as the device lives.
///
/// RESULT:
/// The device, or null without memory. It is answered whether a driver
/// took it or not: `device.driver` says.
///
/// BEHAVIOR:
/// For hardware the library cannot find by itself - a display that is
/// neither a panel of the board's list nor a function on PCI, and the
/// tests' own. The device joins the list as one of the part kind, named
/// `panel.` and the next number, and is offered at once as
/// `BindRtgDrivers` offers one: to the drivers whose table names it, the
/// closest first. The boards its driver makes join the library's list.
///
/// CONTEXT:
/// - Waits: yes. A driver brings its hardware up in its `attach`.
/// - Interrupts: no.
/// - Locks: takes the device list's lock, and inside it the driver
///   list's and the board list's. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The device is the library's until `RemRtgDevice`. The tags stay the
/// caller's and are kept valid until then.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemRtgDevice`, `BindRtgDrivers`, `CreateBoard`
///
/// EXAMPLES:
/// ```zig
/// const device = rb.AddRtgDevice(&found_tags) orelse return error.NoMemory;
/// ```
pub fn AddRtgDevice(rb: *RtgBase, tag_list: ?[*]const TagItem) ?*rtg.RtgDevice {
    const sys = rb.sys_base;
    sys.ObtainSemaphore(&rb.device_lock);
    defer sys.ReleaseSemaphore(&rb.device_lock);
    const private = _device.addPart(rb, null, tag_list) orelse return null;
    private.added = true;
    _ = _device.offer(rb, &private.device);
    return &private.device;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const std = fixture.std;
const testing = fixture.testing;

test "a device from tags: named, offered at once, and listed with its driver" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);

    // Nothing of the machine's is on the list before the first bind, and
    // the host has neither a board's list nor PCI to find any on.
    var listed: [4]rtg.RtgDeviceInfo = undefined;
    try testing.expectEqual(@as(u32, 0), fixture.base(rb).GetRtgDevices(&listed, listed.len));
    try testing.expectEqual(@as(u32, 0), fixture.base(rb).BindRtgDrivers());
    try testing.expectEqual(@as(u32, 0), fixture.base(rb).GetRtgDevices(null, 0));

    const device = fixture.fake.addDevice(fk, null).?;
    try testing.expectEqualStrings("panel.0", std.mem.span(device.node.name.?));
    try testing.expectEqual(rtg.drivers.RTGDEV_PART, device.kind);
    try testing.expectEqual(fixture.fake.chip, device.chip);
    try testing.expectEqual(fixture.fake.bus, device.bus);
    try testing.expect(device.part == null and device.pci == null);
    try testing.expectEqual(@as(?[*]const TagItem, fixture.fake.deviceTags()), device.tags);
    // Offered as it was added: the fake has it, and made its board.
    try testing.expectEqual(fk.driver, device.driver.?);
    try testing.expectEqual(@as(u32, 1), fk.driver.devices);
    const board = fixture.base(rb).NextBoard(null).?;
    try testing.expectEqual(device, board.device.?);

    try testing.expectEqual(@as(u32, 1), fixture.base(rb).GetRtgDevices(&listed, listed.len));
    try testing.expectEqualStrings("panel.0", std.mem.sliceTo(&listed[0].name, 0));
    try testing.expectEqualStrings("fake display", std.mem.sliceTo(&listed[0].chip_name, 0));
    try testing.expectEqualStrings("fake", std.mem.sliceTo(&listed[0].driver, 0));
    try testing.expectEqual(@as(u32, 1), listed[0].boards);
    try testing.expectEqual(@as(u32, 0), listed[0].flags);
    try testing.expectEqual(@as(u8, 0), listed[0].behind[0]);

    // A second one takes the next number, and one bind later nothing is
    // left to offer.
    const second = fixture.fake.addDevice(fk, null).?;
    try testing.expectEqualStrings("panel.1", std.mem.span(second.node.name.?));
    try testing.expectEqual(@as(u32, 2), fixture.base(rb).GetRtgDevices(null, 0));
    try testing.expectEqual(@as(u32, 0), fixture.base(rb).BindRtgDrivers());
    try fixture.tearDown(rb);
}
