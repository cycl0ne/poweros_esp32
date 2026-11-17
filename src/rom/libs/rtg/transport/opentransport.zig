// SPDX-License-Identifier: MPL-2.0
//! OpenTransport: The bus a device is reached over.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const Private = _transport.Private;
const err = rtg.errors;
const registry = @import("../driver/_driver.zig");
const devices = @import("../device/_device.zig");
const _transport = @import("_transport.zig");

/// Opens the bus a device is reached over.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenTransport(rb: *RtgBase, driver: *rtg.RtgDriver, device: *rtg.RtgDevice) ?*rtg.RtgTransport
/// ```
///
/// SINCE: 1.18. LVO -292.
///
/// INPUTS:
/// - `driver` - the driver that asks: the one that has `device`, or is
///   being offered it.
/// - `device` - the device on the bus.
///
/// RESULT:
/// The bus, or null: when `driver` neither has the device nor is being
/// offered it, for a bus no transport driver's table names, without
/// memory, and when no transport driver could make it.
///
/// BEHAVIOR:
/// A panel on a bus is two drivers: one for the panel, which takes the
/// device, and one for the bus. The transport drivers whose table names
/// the device - its bus, most often - are asked in turn, the closest
/// first, to make the bus from the device's tags (`create_transport`):
/// the pads, the clock and the framing are tags of the part. The first
/// that answers `RTGERR_OK` has made it. The handle and the driver's
/// instance come from memory the bus's driver can read from its
/// interrupts. The panel's driver talks over the bus with `TxParam`,
/// `TxColor` and `RxParam`.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the driver list or the board
///   list, and if the bus's driver does.
/// - Interrupts: no.
/// - Locks: takes the driver list's lock and the board list's. No
///   spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bus is the caller's until `CloseTransport`. Its driver is one bus
/// more.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseTransport`, `TxParam`, `TxColor`, `RxParam`
///
/// EXAMPLES:
/// ```zig
/// const io = rb.OpenTransport(driver, device) orelse return rtg.errors.RTGERR_NO_DISPLAY;
/// ```
pub fn OpenTransport(rb: *RtgBase, driver: *rtg.RtgDriver, device: *rtg.RtgDevice) ?*rtg.RtgTransport {
    const sys = rb.sys_base;
    // The bus is its device's driver's to open.
    if (device.driver != driver and devices.privateOf(device).offered_to != driver) return null;

    sys.ObtainSemaphore(&rb.driver_lock);
    defer sys.ReleaseSemaphore(&rb.driver_lock);
    var asked: [devices.max_candidates]devices.Candidate = undefined;
    const count = devices.candidates(rb, device, rtg.drivers.RTGDT_TRANSPORT, &asked);
    for (asked[0..count]) |candidate| {
        const maker = candidate.driver;
        const spec = maker.spec;
        const create = spec.ops.create_transport orelse continue;

        const where = registry.memoryFor(spec);
        const memory = sys.AllocVec(@sizeOf(Private), where) orelse return null;
        const private: *Private = @ptrCast(@alignCast(memory));
        private.* = .{};
        const io = &private.io;
        io.rtg_base = @ptrCast(rb);
        io.driver = @ptrCast(maker);
        io.node.name = spec.name;
        if (spec.instance_size != 0) {
            io.instance = sys.AllocVec(spec.instance_size, where) orelse {
                sys.FreeVec(memory);
                return null;
            };
            io.instance_size = spec.instance_size;
        }

        if (create(maker, io, device.tags) != err.RTGERR_OK) {
            if (io.instance) |instance| sys.FreeVec(instance);
            sys.FreeVec(memory);
            continue;
        }
        maker.buses += 1;
        sys.ObtainSemaphore(&rb.board_lock);
        sys.AddTail(&rb.transports, &io.node);
        sys.ReleaseSemaphore(&rb.board_lock);
        return io;
    }
    return null;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const std = fixture.std;
const TagItem = fixture.TagItem;
const testing = fixture.testing;

test "a bus opened by a driver: made by the driver that names the device's bus, and given back" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);

    // With no transport driver on the list the bus cannot be opened, and
    // the board's driver declines.
    fk.opens_bus = true;
    const unreached = fixture.fake.addDevice(fk, null).?;
    try testing.expect(unreached.driver == null);
    try testing.expectEqual(@as(u32, 0), fk.driver.boards);

    const buses = fixture.fakebus.add(rb) orelse return error.NoDriver;
    // A bus its driver cannot make is no bus either.
    buses.create_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(@as(u32, 0), fixture.base(rb).BindRtgDrivers());
    try testing.expectEqual(@as(u32, 0), buses.driver.buses);
    buses.create_answer = rtg.errors.RTGERR_OK;

    try testing.expectEqual(@as(u32, 1), fixture.base(rb).BindRtgDrivers());
    try testing.expectEqual(@as(u32, 1), buses.created);
    try testing.expectEqual(@as(u32, 1), buses.driver.buses);
    // Made from the device's own tags.
    try testing.expectEqual(@as(?[*]const TagItem, fixture.fake.deviceTags()), buses.last_tags);
    const board = fixture.base(rb).NextBoard(null).?;
    const io = fixture.fake.instanceOf(board).bus.?;
    try testing.expectEqualStrings("fakebus", std.mem.span(io.node.name.?));
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(buses.driver)), io.driver);
    // The library cleared the bus's own data, which is its driver's.
    const line = fixture.fakebus.instanceOf(io);
    try testing.expectEqual(@as(u32, 0), line.sends);

    // The three transfers reach the bus's driver, with what they were
    // given, and its answer comes back.
    var bytes: [4]u8 = .{ 1, 2, 3, 4 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.driverBase(rb).TxParam(io, 0x2A, &bytes, bytes.len));
    try testing.expectEqual(@as(u32, 1), line.sends);
    try testing.expectEqual(@as(i32, 0x2A), line.last_cmd);
    try testing.expectEqual(@as(u32, 4), line.last_size);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.driverBase(rb).TxColor(io, 0x2C, &bytes, 2));
    try testing.expectEqual(@as(u32, 1), line.colors);
    try testing.expectEqual(@as(u32, 2), line.last_size);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.driverBase(rb).RxParam(io, 0x04, &bytes, 3));
    try testing.expectEqual(@as(u32, 1), line.reads);
    try testing.expectEqualSlices(u8, &.{ 4, 4, 4, 4 }, &bytes);
    line.answer = rtg.errors.RTGERR_TIMEOUT;
    try testing.expectEqual(rtg.errors.RTGERR_TIMEOUT, fixture.driverBase(rb).TxParam(io, 0x29, null, 0));
    // A bus whose driver filled in no transfer says so.
    var bare = rtg.RtgTransport{};
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, fixture.driverBase(rb).TxParam(&bare, 0, null, 0));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, fixture.driverBase(rb).TxColor(&bare, 0, null, 0));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, fixture.driverBase(rb).RxParam(&bare, 0, null, 0));

    // A driver that neither has the device nor is being offered it opens
    // no bus of it; null closes nothing.
    try testing.expect(fixture.driverBase(rb).OpenTransport(buses.driver, board.device.?) == null);
    fixture.driverBase(rb).CloseTransport(null);

    // The bus's driver stays while a bus of it is open, and the bus goes
    // with the board that opened it.
    try testing.expect(!fixture.fakebus.remove(buses));
    fixture.driverBase(rb).DeleteBoard(board);
    try testing.expectEqual(@as(u32, 1), buses.destroyed);
    try testing.expectEqual(@as(u32, 0), buses.driver.buses);
    try testing.expect(fixture.fakebus.remove(buses));
    try fixture.tearDown(rb);
}
