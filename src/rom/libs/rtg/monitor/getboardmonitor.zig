// SPDX-License-Identifier: MPL-2.0
//! GetBoardMonitor: What is on a board's connector.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const _monitor = @import("_monitor.zig");

/// Reads what is on a board's connector.
///
/// SYNOPSIS:
/// ```zig
/// fn GetBoardMonitor(rb: *RtgBase, board: *rtg.RtgBoard, info: *rtg.RtgMonitorInfo, size: u32) u32
/// ```
///
/// SINCE: 1.20. LVO -228.
///
/// INPUTS:
/// - `board` - the board.
/// - `info` - where the answer goes.
/// - `size` - how many bytes `info` has: `@sizeOf(RtgMonitorInfo)`.
///
/// RESULT:
/// How many bytes were written. A caller built against an older SDK with a
/// smaller structure gets that much; check the count before trusting a
/// field near the end.
///
/// BEHAVIOR:
/// The answer is what the board's connector was last seen to have: the
/// library asks the driver when the board is made and whenever the driver
/// says the monitor changed, not at this call. `RTGMON_PRESENT` says a
/// monitor is there; with `RTGMON_EDID` its description was read, and the
/// maker's letters, the product and serial numbers, the name, the
/// picture's size in millimetres and when it was made are from it, as is
/// what it takes: HDMI's packets (`RTGMON_HDMI`), sound (`RTGMON_AUDIO`),
/// a choice of its RGB range, scrambling, and its fastest clock. Since
/// 1.43 the sound is described: the most channels, the rates and sample
/// sizes of uncompressed sound its audio data block names, the rates two
/// channels take, and its speakers - basic audio's two channels at 32,
/// 44.1 and 48 kHz in 16 bits to the front pair where it plays sound and
/// names none of it. A panel
/// is a monitor that is always there (`RTGMON_PANEL`), called what its
/// part is called. A board whose device has gone says what it last had.
///
/// CONTEXT:
/// - Waits: while another task holds the board's lock - through a show,
///   which may last a frame, or a look at the connector.
/// - Interrupts: no.
/// - Locks: takes the board's lock. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated: the copy is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReadBoardEDID`, `GetBoardModes`, `AddRtgNotify`
///
/// EXAMPLES:
/// ```zig
/// var monitor: rtg.RtgMonitorInfo = .{};
/// _ = rb.GetBoardMonitor(board, &monitor, @sizeOf(rtg.RtgMonitorInfo));
/// if (monitor.flags & rtg.modes.RTGMON_PRESENT == 0) return;
/// ```
pub fn GetBoardMonitor(rb: *RtgBase, board: *rtg.RtgBoard, info: *rtg.RtgMonitorInfo, size: u32) u32 {
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    var said: rtg.RtgMonitorInfo = undefined;
    _monitor.infoOf(rb, board, &said);
    return boards.copyOut(rtg.RtgMonitorInfo, &said, info, size);
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const std = fixture.std;
const testing = fixture.testing;

test "a panel is a monitor that is always there, called what its part is called" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const board = try fixture.makeBoard(rb);
    const said = fixture.monitorOf(rb, board);
    try testing.expectEqual(rtg.modes.RTGMON_PRESENT | rtg.modes.RTGMON_PANEL, said.flags);
    try testing.expectEqualStrings("fake display", std.mem.sliceTo(&said.name, 0));
    try testing.expectEqual(@as(u32, 0), said.edid_size);
    // As much of the answer as the caller has room for.
    var short: rtg.RtgMonitorInfo = .{};
    try testing.expectEqual(@as(u32, 4), fixture.base(rb).GetBoardMonitor(board, &short, 4));
    try testing.expectEqual(said.flags, short.flags);
    try testing.expectEqual(@as(u8, 0), short.name[0]);
    // It has no EDID, its board no connector, and nothing asked its driver.
    try testing.expectEqual(@as(u32, 0), fixture.base(rb).ReadBoardEDID(board, null, 0));
    const info = fixture.infoOf(rb, board);
    try testing.expectEqual(@as(u32, 0), info.flags & rtg.boards.RTGBF_CONNECTOR);
    try testing.expectEqual(@as(u32, 0), info.caps & rtg.boards.RTGBC_MONITOR);
    try testing.expectEqual(@as(u32, 0), fixture.fakeOf(rb).log.detects);
    // A word of its driver's about a connector it has not is not heard.
    fixture.driverBase(rb).MonitorChanged(board);
    fixture.monitors.service(rb);
    try testing.expectEqual(@as(u32, 0), fixture.fakeOf(rb).log.detects);
    try testing.expect(rb.monitor_task == null);

    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}
