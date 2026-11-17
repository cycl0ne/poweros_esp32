// SPDX-License-Identifier: MPL-2.0
//! BindRtgDrivers: Offer every device no driver has to the drivers on the
//! list.

const RtgBase = @import("../rtg.zig").RtgBase;
const _device = @import("_device.zig");

/// Offers every device no driver has to the drivers on the list.
///
/// SYNOPSIS:
/// ```zig
/// fn BindRtgDrivers(rb: *RtgBase) u32
/// ```
///
/// SINCE: 1.18. LVO -208.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// How many boards were made by this call. 0 on a machine with no display
/// a driver takes, and when every device has its driver already.
///
/// BEHAVIOR:
/// The first call puts the machine's own devices on the list: every panel
/// part of the board's list, in the list's order, then every function on
/// PCI whose class is a display, where the machine has pci.library. Each
/// device that has no driver is then offered to the drivers whose table
/// names it, the closest first - a chip, or a vendor and a device, above
/// a bus, a vendor alone or a class - and among those as close by the
/// entry's priority and the driver's. A driver is asked through its
/// `attach`: it looks at the hardware and makes a board for each output.
/// The first that answers `RTGERR_OK` has the device for good, and its
/// boards join the list, each named after its driver and a number; one
/// that declines has given back what it took, and the next is asked. A
/// device no driver takes stays on the list and is offered again by the
/// next call - to a driver that has joined the list since.
///
/// The boards are walked with `NextBoard`: the first is the machine's
/// display, the firmware's picture the last. graphics.library calls this
/// as the machine starts, and takes the first board.
///
/// CONTEXT:
/// - Waits: yes. A driver brings its hardware up in its `attach` - a
///   panel is held in reset for tens of milliseconds.
/// - Interrupts: no.
/// - Locks: takes the device list's lock, and inside it the driver
///   list's and the board list's. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The devices and the boards are the library's. A board is never freed
/// for a program.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NextBoard`, `GetRtgDevices`, `GetRtgDrivers`, `AddRtgDevice`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.BindRtgDrivers();
/// const display = rb.NextBoard(null) orelse return;
/// ```
pub fn BindRtgDrivers(rb: *RtgBase) u32 {
    const sys = rb.sys_base;
    sys.ObtainSemaphore(&rb.device_lock);
    defer sys.ReleaseSemaphore(&rb.device_lock);
    _device.listMachine(rb);
    var made: u32 = 0;
    var node = rb.devices.first();
    while (node) |one| : (node = one.next()) {
        made += _device.offer(rb, _device.deviceOf(one));
    }
    return made;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const std = fixture.std;
const rtg = fixture.rtg;
const testing = fixture.testing;

test "a driver that declines: nothing kept, the device left for a driver that comes later" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);

    fk.create_answer = rtg.errors.RTGERR_NO_DISPLAY;
    const device = fixture.fake.addDevice(fk, null).?;
    try testing.expectEqual(@as(u32, 1), fk.log.offered);
    try testing.expectEqual(@as(u32, 0), fk.log.created);
    try testing.expectEqual(@as(u32, 0), fk.driver.boards);
    try testing.expectEqual(@as(u32, 0), fk.driver.devices);
    try testing.expect(device.driver == null);
    try testing.expect(fixture.base(rb).NextBoard(null) == null);

    // Offered again by the next bind, and taken this time.
    fk.create_answer = rtg.errors.RTGERR_OK;
    try testing.expectEqual(@as(u32, 1), fixture.base(rb).BindRtgDrivers());
    try testing.expectEqual(@as(u32, 2), fk.log.offered);
    try testing.expectEqual(fk.driver, device.driver.?);
    try testing.expectEqualStrings("fake.0", std.mem.span(fixture.base(rb).NextBoard(null).?.node.name.?));
    // The leak check in tearDown is what proves nothing of the refusal
    // stayed.
    try fixture.tearDown(rb);
}
