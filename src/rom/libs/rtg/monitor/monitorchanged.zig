// SPDX-License-Identifier: MPL-2.0
//! MonitorChanged: Something happened at a board's connector.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _monitor = @import("_monitor.zig");

/// Has a board's connector looked at again.
///
/// SYNOPSIS:
/// ```zig
/// fn MonitorChanged(rb: *RtgBase, board: *rtg.RtgBoard) void
/// ```
///
/// SINCE: 1.20. LVO -308.
///
/// INPUTS:
/// - `board` - the board at whose connector something happened: one of
///   the caller's own, whose ops fill in `detect`.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The board is marked and the library's monitor task woken; the call
/// does no more. The task then asks the board's `detect`, keeps what the
/// monitor now there says of itself, and makes the board's modes again
/// of the timings it names that the board's `check_mode` takes - a mode
/// of the figures of one the board had keeps that mode's number. A board
/// that shows is handed the mode it is in and what it shows again
/// (`show`), with the timings the new monitor gives it, where the new
/// list has that mode; where it has not, what it showed is shown in the
/// mode the new monitor prefers, scaled by the widths, on a board that
/// scales its bands (`RTGBC_SCALE_BANDS`), and a board that does not
/// shows nothing and is in no mode until it is shown in one. The
/// board's `changes` are raised and the tasks that asked are told
/// (`AddRtgNotify`).
///
/// A driver calls it from its hot-plug interrupt, or from a task of its
/// own that looks at the port. Several calls before the task has looked
/// are one look, and a look that finds what the last one found - the same
/// monitor, or none still - changes nothing: a driver whose connector has
/// no interrupt may call it now and then, or have FrameDone ask for a
/// look every so many frames (`RtgBoardSpec.look_frames`), whose looks
/// then settle while the board shows. On a board without `detect` it
/// does nothing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: yes: a flag is written and a task signalled.
/// - Locks: none taken.
/// - Process: any, or none.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetBoardMonitor`, `AddRtgNotify`, `AddBoardMode`
///
/// EXAMPLES:
/// ```zig
/// // The hot-plug line's interrupt.
/// rb.MonitorChanged(board);
/// ```
pub fn MonitorChanged(rb: *RtgBase, board: *rtg.RtgBoard) void {
    _monitor.mark(rb, board);
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;
const boards = @import("../board/_board.zig");

/// One look at the board's connector, as the monitor task takes it.
fn lookAt(rb: *RtgBase, board: *rtg.RtgBoard) void {
    fixture.driverBase(rb).MonitorChanged(board);
    _monitor.service(rb);
}

fn present(rb: *RtgBase, board: *rtg.RtgBoard) bool {
    return fixture.monitorOf(rb, board).flags & rtg.modes.RTGMON_PRESENT != 0;
}

test "a connector looked at by its frames: a monitor that stays is not read again" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    fk.look_frames = 30;
    fk.keeps_edid = true;
    const board = try fixture.makeConnector(rb, fixture.qhd_bytes, 0);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.setMode(rb, board, 0));
    const reads = fk.log.edid_reads;
    try testing.expectEqual(@as(u32, 1), reads);

    lookAt(rb, board);
    lookAt(rb, board);
    try testing.expectEqual(reads, fk.log.edid_reads);
    try testing.expect(fixture.monitorOf(rb, board).flags & rtg.modes.RTGMON_EDID != 0);

    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}

test "a connector looked at by its frames, on a board that shows: a change settles, and an EDID that does not read is asked for three times" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    fk.look_frames = 30;
    // Nothing on the connector: the board in its driver's one mode.
    const board = try fixture.makeConnector(rb, null, 1);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.setMode(rb, board, 0));
    try testing.expect(boards.privateOf(board).mode != null);
    try testing.expect(!present(rb, board));

    // A monitor comes whose EDID does not read: the first look leaves
    // the connector empty, the second takes the monitor.
    fk.monitor_there = true;
    lookAt(rb, board);
    try testing.expect(!present(rb, board));
    lookAt(rb, board);
    try testing.expect(present(rb, board));
    try testing.expect(boards.privateOf(board).mode != null);
    // Its EDID asked for at two more looks, then no longer.
    lookAt(rb, board);
    try testing.expect(fk.log.edid_room != 0);
    lookAt(rb, board);
    try testing.expect(fk.log.edid_room != 0);
    const reads = fk.log.edid_reads;
    lookAt(rb, board);
    try testing.expectEqual(@as(u32, 0), fk.log.edid_room);
    try testing.expectEqual(reads, fk.log.edid_reads);

    // Taken off: what stood stands for one look.
    fk.monitor_there = false;
    lookAt(rb, board);
    try testing.expect(present(rb, board));
    lookAt(rb, board);
    try testing.expect(!present(rb, board));

    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}

test "a connector its driver says changes itself takes every look as it is" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const board = try fixture.makeConnector(rb, fixture.qhd_bytes, 0);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.setMode(rb, board, 0));
    fk.monitor_there = false;
    lookAt(rb, board);
    try testing.expect(!present(rb, board));
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}
