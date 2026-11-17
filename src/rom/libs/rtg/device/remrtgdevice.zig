// SPDX-License-Identifier: MPL-2.0
//! RemRtgDevice: A device AddRtgDevice made is gone.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const _device = @import("_device.zig");

/// Takes away a device `AddRtgDevice` made.
///
/// SYNOPSIS:
/// ```zig
/// fn RemRtgDevice(rb: *RtgBase, device: ?*rtg.RtgDevice) void
/// ```
///
/// SINCE: 1.18. LVO -288.
///
/// INPUTS:
/// - `device` - the device, as `AddRtgDevice` answered it. Null does
///   nothing, and so does one of the machine's own: a panel part and a
///   function on PCI never go.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// Every board its driver made of it is marked as gone first
/// (`RTGBF_GONE`, `RTGBF_NO_DISPLAY`): taken off the display, passed over
/// by `NextBoard` from now on, and answering `RTGERR_NO_DISPLAY` to a
/// show - but still a handle, with its buffers, for whoever holds it.
/// Then the driver's `detach` is called, where it has one, to stop the
/// hardware, and the device leaves the list and is freed. The boards are
/// the driver's to delete (`DeleteBoard`) when it is removed itself.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the device list or a board's
///   lock, and if the driver does.
/// - Interrupts: no.
/// - Locks: takes the device list's lock, and inside it each board's. No
///   spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The device is gone, and its tags are the caller's again. Its boards
/// stay the library's. The driver is one device less.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddRtgDevice`, `DeleteBoard`, `NextBoard`
///
/// EXAMPLES:
/// ```zig
/// rb.RemRtgDevice(device);
/// ```
pub fn RemRtgDevice(rb: *RtgBase, device: ?*rtg.RtgDevice) void {
    const gone = device orelse return;
    const sys = rb.sys_base;
    const private = _device.privateOf(gone);
    if (!private.added) return;
    sys.ObtainSemaphore(&rb.device_lock);
    defer sys.ReleaseSemaphore(&rb.device_lock);

    // Its boards say so before the hardware stops.
    while (private.boards.first()) |link| boards.retire(rb, boards.ofDeviceLink(link));
    if (gone.driver) |driver| {
        if (driver.spec.ops.detach) |detach| detach(driver, gone);
        if (driver.devices != 0) driver.devices -= 1;
    }
    sys.Remove(&gone.node);
    sys.FreeVec(private);
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const std = fixture.std;
const testing = fixture.testing;

test "a device taken away: its boards gone from the walk, still handles, and showing nothing" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);

    const board = try fixture.makeDisplay(rb, 8, 8);
    const device = board.device.?;
    const mode = fixture.base(rb).FindBoardMode(board, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.setMode(rb, board, mode));
    const bm = fixture.base(rb).AllocBitMap(board, 8, 8, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, bm));

    fixture.driverBase(rb).RemRtgDevice(device);
    fk.devices[0] = null;
    try testing.expectEqual(@as(u32, 1), fk.log.detached);
    try testing.expectEqual(@as(u32, 0), fk.driver.devices);
    try testing.expectEqual(@as(u32, 0), fixture.base(rb).GetRtgDevices(null, 0));
    // The board is passed over, and still found by its name.
    try testing.expect(fixture.base(rb).NextBoard(null) == null);
    try testing.expectEqual(board, fixture.base(rb).FindBoard("fake.0").?);
    try testing.expect(board.device == null);
    var info: rtg.RtgBoardInfo = .{};
    _ = fixture.base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expect(info.flags & rtg.boards.RTGBF_GONE != 0);
    try testing.expect(info.flags & rtg.boards.RTGBF_NO_DISPLAY != 0);
    // It still says which device it was an output of.
    try testing.expectEqualStrings("panel.0", std.mem.span(info.device.?));
    // What it showed was taken down, so the buffer can go; nothing more
    // is shown on it, and it is put in no mode.
    try testing.expect(fixture.base(rb).BoardDisplayBitMap(board) == null);
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, fixture.base(rb).ShowBitMap(board, bm));
    const one = [_]rtg.RtgBand{.{ .bitmap = bm }};
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, fixture.base(rb).ShowBoard(board, 0, &one, one.len));
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, fixture.setMode(rb, board, mode));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, null));
    fixture.base(rb).FreeBitMap(bm);

    // A board made after it takes the next number, and is the display.
    const next = try fixture.makeBoard(rb);
    try testing.expectEqualStrings("fake.1", std.mem.span(next.node.name.?));
    try testing.expectEqual(next, fixture.base(rb).NextBoard(null).?);
    try testing.expect(fixture.base(rb).NextBoard(next) == null);
    // The walk goes on behind a board that is gone.
    try testing.expectEqual(next, fixture.base(rb).NextBoard(board).?);

    // A device of the machine's own never goes: only one that was added.
    fixture.driverBase(rb).RemRtgDevice(null);
    // The driver deletes its boards as it is removed, the gone one too.
    try fixture.tearDown(rb);
}
