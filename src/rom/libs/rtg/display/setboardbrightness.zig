// SPDX-License-Identifier: MPL-2.0
//! SetBoardBrightness: The backlight, 0 to 100, the right way round
//! whatever the part does.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const boards = @import("../board/_board.zig");

/// Sets the brightness of a board's backlight.
///
/// SYNOPSIS:
/// ```zig
/// fn SetBoardBrightness(rb: *RtgBase, board: *rtg.RtgBoard, percent: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -72.
///
/// INPUTS:
/// - `board` - the board.
/// - `percent` - 0 to 100; more is 100.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_NOT_SUPPORTED` on a board with no backlight to
/// set (`RTGBC_BRIGHTNESS` clear); or what the driver answered, and the
/// brightness as it was.
///
/// BEHAVIOR:
/// 0 is dark and 100 is full, whichever way round the part itself
/// counts. A backlight that is a line on or off (`brightness_steps` 2 in
/// `GetBoardInfo`) is on for anything above 0. The library keeps the
/// value: `GetBoardInfo` answers it (`brightness`), and a board that was
/// asleep comes back with it. On a board that is asleep it is kept and
/// not applied until the board wakes (`SetBoardPower`) - but a monitor,
/// which keeps the value itself, is asked at once, and the call
/// answers what it did.
///
/// A panel's backlight is lit with its board's first picture, at what
/// its device's tags ask (`RTGA_Brightness`), else in full; a brightness
/// set before that is applied at once, and the first picture leaves it.
///
/// A monitor on a connector (`RTGBF_CONNECTOR`) keeps a brightness of
/// its own, and it is left as the monitor has it: nothing sets it but
/// this call and a brightness its device's tags ask. `GetBoardInfo`
/// asks the monitor what it is at, so `brightness` follows the
/// monitor's own buttons too.
///
/// Dimmed is not asleep: `SetBoardPower` is what puts a display to
/// sleep.
///
/// CONTEXT:
/// - Waits: only if the driver does, and while another task holds the
///   board's lock.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: takes the board's lock. No spinlock may be held: a driver
///   may wait.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetBoardInfo`, `SetBoardPower`
///
/// EXAMPLES:
/// ```zig
/// _ = rb.SetBoardBrightness(board, 60);
/// ```
pub fn SetBoardBrightness(rb: *RtgBase, board: *rtg.RtgBoard, percent: u32) i32 {
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    if (board.info.caps & rtg.boards.RTGBC_BRIGHTNESS == 0) return err.RTGERR_NOT_SUPPORTED;
    const want = @min(percent, 100);
    // A board asleep has its backlight off: it wakes with this. A
    // display that keeps the value itself is told at once.
    if (board.info.power != rtg.boards.RTGPWR_ASLEEP or board.ops.?.brightness != null) {
        const code = board.ops.?.set_brightness.?(board, want);
        if (code != err.RTGERR_OK) return code;
    }
    board.info.brightness = want;
    boards.privateOf(board).lit = true;
    return err.RTGERR_OK;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const std = fixture.std;
const utility = fixture.utility;
const TagItem = fixture.TagItem;
const testing = fixture.testing;

test "the backlight: its levels, kept by the library, lit with the first picture" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const board = try fixture.makeDisplay(rb, 16, 16);

    // A level for each per cent, full until something else is said, and
    // nothing lit yet.
    var info = fixture.infoOf(rb, board);
    try testing.expect(info.caps & rtg.boards.RTGBC_BRIGHTNESS != 0);
    try testing.expectEqual(@as(u32, 101), info.brightness_steps);
    try testing.expectEqual(@as(u32, 100), info.brightness);
    try testing.expectEqual(@as(u32, 0), fk.log.brightness_calls);

    // Set: applied, and kept by the library.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardBrightness(board, 60));
    try testing.expectEqual(@as(u32, 60), fk.log.brightness);
    try testing.expectEqual(@as(u32, 60), fixture.infoOf(rb, board).brightness);
    // Above the top of the range is the top of the range.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardBrightness(board, 400));
    try testing.expectEqual(@as(u32, 100), fk.log.brightness);
    try testing.expectEqual(@as(u32, 100), fixture.infoOf(rb, board).brightness);
    // One the driver could not set leaves what was.
    fk.brightness_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, fixture.base(rb).SetBoardBrightness(board, 20));
    try testing.expectEqual(@as(u32, 100), fixture.infoOf(rb, board).brightness);
    fk.brightness_answer = rtg.errors.RTGERR_OK;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardBrightness(board, 45));
    // The first picture leaves a brightness that was set.
    const calls = fk.log.brightness_calls;
    const picture = fixture.base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, picture));
    try testing.expectEqual(calls, fk.log.brightness_calls);
    try testing.expectEqual(@as(u32, 45), fk.log.brightness);

    // A control the driver knows, and the one every board takes.
    try testing.expectEqual(@as(isize, 8), fixture.base(rb).BoardControl(board, rtg.tags.RTGCTRL_RGB_SHIFT, 7));
    try testing.expectEqual(rtg.tags.RTGCTRL_RGB_SHIFT, fk.log.last_control);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, null));
    fixture.base(rb).FreeBitMap(picture);
    fixture.driverBase(rb).DeleteBoard(board);

    // A board nobody set: dark until its first picture, lit with it at
    // what its device's tags ask, and left alone by the next.
    const dimmed = [_]TagItem{
        .{ .tag = rtg.tags.RTGA_Brightness, .data = 40 },
        .{ .tag = utility.TAG_MORE, .data = @intFromPtr(fixture.fake.deviceTags()) },
    };
    fk.display = .{ .timings = .{ .h_active = 16, .v_active = 16 }, .format = .rgb565, .flags = rtg.modes.RTGMF_DEFAULT };
    const lit = fixture.fake.makeBoardFrom(fk, &dimmed) orelse return error.NoBoard;
    fk.display = null;
    try testing.expectEqual(@as(u32, 40), fixture.infoOf(rb, lit).brightness);
    const before = fk.log.brightness_calls;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.setMode(rb, lit, 0));
    try testing.expectEqual(before, fk.log.brightness_calls);
    const first = fixture.base(rb).AllocBitMap(lit, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(lit, first));
    try testing.expectEqual(before + 1, fk.log.brightness_calls);
    try testing.expectEqual(@as(u32, 40), fk.log.brightness);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(lit, first));
    try testing.expectEqual(before + 1, fk.log.brightness_calls);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(lit, null));
    fixture.base(rb).FreeBitMap(first);
    fixture.driverBase(rb).DeleteBoard(lit);

    // A line that is on or off has two levels; a driver with no line
    // wired has none, and the board no backlight to set.
    fk.brightness_steps = 2;
    const line = try fixture.makeBoard(rb);
    try testing.expectEqual(@as(u32, 2), fixture.infoOf(rb, line).brightness_steps);
    fixture.driverBase(rb).DeleteBoard(line);
    fk.brightness_steps = 0;
    const unwired = try fixture.makeBoard(rb);
    info = fixture.infoOf(rb, unwired);
    try testing.expectEqual(@as(u32, 0), info.caps & rtg.boards.RTGBC_BRIGHTNESS);
    try testing.expectEqual(@as(u32, 0), info.brightness_steps);
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, fixture.base(rb).SetBoardBrightness(unwired, 50));
    fixture.driverBase(rb).DeleteBoard(unwired);
    try fixture.tearDown(rb);
}

test "a monitor's brightness is its own: read from it, and set with the first picture only where the device's tags ask it" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const dimmed = [_]TagItem{
        .{ .tag = rtg.tags.RTGA_Brightness, .data = 40 },
        .{ .tag = utility.TAG_MORE, .data = @intFromPtr(fixture.fake.deviceTags()) },
    };
    // A monitor on a connector keeps the brightness it has: its first
    // picture sets none, and one that is set is set.
    const small = fixture.smallMonitor(fixture.smallTiming(64, 32, 8), null);
    const monitor = try fixture.makeConnector(rb, std.mem.sliceAsBytes(&small), 0);
    fk.connector = false;
    try testing.expect(fixture.infoOf(rb, monitor).flags & rtg.boards.RTGBF_CONNECTOR != 0);
    try testing.expect(fixture.infoOf(rb, monitor).caps & rtg.boards.RTGBC_BRIGHTNESS != 0);
    const untouched = fk.log.brightness_calls;
    // What it is at is the monitor's to say, before a picture and after.
    fk.own_brightness = 35;
    try testing.expectEqual(@as(u32, 35), fixture.infoOf(rb, monitor).brightness);
    const seen = fixture.base(rb).AllocBitMap(monitor, 64, 32, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(monitor, seen));
    try testing.expectEqual(untouched, fk.log.brightness_calls);
    try testing.expectEqual(@as(u32, 35), fixture.infoOf(rb, monitor).brightness);
    // Its own buttons are followed.
    fk.own_brightness = 20;
    try testing.expectEqual(@as(u32, 20), fixture.infoOf(rb, monitor).brightness);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardBrightness(monitor, 70));
    try testing.expectEqual(untouched + 1, fk.log.brightness_calls);
    try testing.expectEqual(@as(u32, 70), fk.log.brightness);
    try testing.expectEqual(@as(u32, 70), fixture.infoOf(rb, monitor).brightness);
    // One that does not answer leaves what was last heard.
    fk.own_brightness = 10;
    fk.read_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(@as(u32, 70), fixture.infoOf(rb, monitor).brightness);
    fk.read_answer = rtg.errors.RTGERR_OK;
    try testing.expectEqual(@as(u32, 10), fixture.infoOf(rb, monitor).brightness);
    // Asleep it is not asked what it is at, and is still told one that
    // is set: the monitor keeps it.
    try testing.expectEqual(@as(i32, @intCast(rtg.boards.RTGPWR_ASLEEP)), fixture.base(rb).SetBoardPower(monitor, rtg.boards.RTGPWR_ASLEEP));
    const reads = fk.log.brightness_reads;
    fk.own_brightness = 5;
    try testing.expectEqual(@as(u32, 10), fixture.infoOf(rb, monitor).brightness);
    try testing.expectEqual(reads, fk.log.brightness_reads);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardBrightness(monitor, 60));
    try testing.expectEqual(untouched + 2, fk.log.brightness_calls);
    try testing.expectEqual(@as(i32, @intCast(rtg.boards.RTGPWR_ON)), fixture.base(rb).SetBoardPower(monitor, rtg.boards.RTGPWR_ON));
    try testing.expectEqual(@as(u32, 60), fixture.infoOf(rb, monitor).brightness);
    // Awake again it was asked, the once.
    try testing.expectEqual(reads + 1, fk.log.brightness_reads);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(monitor, null));
    fixture.base(rb).FreeBitMap(seen);
    fixture.driverBase(rb).DeleteBoard(monitor);
    // One whose device's tags ask a brightness has it with the first
    // picture.
    fk.connector = true;
    fk.monitor_there = true;
    fk.monitor_edid = std.mem.sliceAsBytes(&small);
    fk.modes = 0;
    const asked = fixture.fake.makeBoardFrom(fk, &dimmed) orelse return error.NoBoard;
    fk.connector = false;
    const unasked = fk.log.brightness_calls;
    const shown = fixture.base(rb).AllocBitMap(asked, 64, 32, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(asked, shown));
    try testing.expectEqual(unasked + 1, fk.log.brightness_calls);
    try testing.expectEqual(@as(u32, 40), fk.log.brightness);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(asked, null));
    fixture.base(rb).FreeBitMap(shown);
    fixture.driverBase(rb).DeleteBoard(asked);
    try fixture.tearDown(rb);
}
