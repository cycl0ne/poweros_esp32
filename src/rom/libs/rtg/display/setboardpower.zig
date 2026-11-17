// SPDX-License-Identifier: MPL-2.0
//! SetBoardPower: The picture shown, black, or the display asleep.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _display = @import("_display.zig");
const boards = @import("../board/_board.zig");

/// Puts a board in a power state: on, blank or asleep.
///
/// SYNOPSIS:
/// ```zig
/// fn SetBoardPower(rb: *RtgBase, board: *rtg.RtgBoard, state: u32) i32
/// ```
///
/// SINCE: 1.29. LVO -68.
///
/// INPUTS:
/// - `board` - the board.
/// - `state` - `RTGPWR_ON`: the picture shown. `RTGPWR_BLANK`: the
///   picture black, everything else running. `RTGPWR_ASLEEP`: the
///   display asleep - its backlight off, a panel's display off, a
///   monitor sent to sleep.
///
/// RESULT:
/// The state the board is in then: the one asked for, or `RTGPWR_BLANK`
/// where it was asked to sleep and its display does not sleep by itself
/// (`RTGBC_POWER` clear). Below 0, an error, and the board as it was:
/// `RTGERR_BAD_ARG` for a state there is none of, `RTGERR_NO_DISPLAY` on
/// a board whose device has gone, `RTGERR_NOT_SUPPORTED` on a board with
/// no operations, or what the driver answered.
///
/// BEHAVIOR:
/// A board starts on. The library keeps the state (`GetBoardInfo`,
/// `power`), and everything the board showed through it: what is shown,
/// drawn or moved while the board is dark is kept, and is on the glass
/// when it is put on again, with its backlight at the brightness it had
/// (`SetBoardBrightness`, which a board asleep keeps and does not
/// apply). Nobody remembers what to put back.
///
/// Blank is the library's work on every board whose picture it
/// composes: the display is delivered a black picture, and nothing of
/// what changes until the board is on again. A board whose display
/// reads its buffers of alone is put in each state by its driver; one
/// of those whose driver has no such operation is shown nothing while
/// it is dark, its buffers still marked showing. Asleep is the driver's
/// (`power`), asked once the picture is black, and undone before the
/// picture comes back.
///
/// The tasks that asked are told of a change (`AddRtgNotify`), and the
/// board's `changes` are raised. A wait for a frame of a board asleep
/// is by the clock (`WaitVBlank`).
///
/// CONTEXT:
/// - Waits: for the picture delivered or the display to take the state,
///   where the driver waits, and while another task holds the board's
///   lock.
/// - Interrupts: no. The driver may wait on its bus.
/// - Locks: takes the board's lock, and inside it the board's compose
///   lock, so no picture is shown or handed on between the states. No
///   spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetBoardBrightness`, `GetBoardInfo`, `ShowBoard`, `AddRtgNotify`
///
/// EXAMPLES:
/// ```zig
/// // Nothing to see: the display sleeps until a key is pressed.
/// _ = rb.SetBoardPower(board, rtg.boards.RTGPWR_ASLEEP);
/// // ...
/// _ = rb.SetBoardPower(board, rtg.boards.RTGPWR_ON);
/// ```
pub fn SetBoardPower(rb: *RtgBase, board: *rtg.RtgBoard, state: u32) i32 {
    boards.obtain(rb, board);
    defer boards.release(rb, board);
    return _display.power(rb, board, state);
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const testing = fixture.testing;

test "blank is the library's: a black picture, what is shown and drawn meanwhile kept, and on the glass again" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    const direct = rtg.boards.RTGSHOW_DIRECT;
    const on = rtg.boards.RTGPWR_ON;
    const blank = rtg.boards.RTGPWR_BLANK;
    const asleep = rtg.boards.RTGPWR_ASLEEP;

    // A display that reads one buffer itself, whose driver has no power
    // of its own: it never sleeps, and starts on.
    const board = try fixture.makeComposed(rb, 16, 12, 1);
    var info = fixture.infoOf(rb, board);
    try testing.expectEqual(@as(u32, 0), info.caps & rtg.boards.RTGBC_POWER);
    try testing.expectEqual(on, info.power);
    const back = fixture.base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    const front = fixture.base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    fixture.paint(back, 1);
    fixture.paint(front, 2);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, back));
    try testing.expect(fk.log.last_flags & direct != 0);
    const changes = info.changes;

    // Blank: the display is shown the library's picture, which is
    // black, and the board says so.
    try testing.expectEqual(@as(i32, @intCast(blank)), fixture.base(rb).SetBoardPower(board, blank));
    try testing.expectEqual(@as(u32, 0), fk.log.last_flags & direct);
    info = fixture.infoOf(rb, board);
    try testing.expectEqual(blank, info.power);
    try testing.expect(info.changes != changes);
    try testing.expect(back.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);
    var y: u32 = 0;
    while (y < 12) : (y += 1) {
        var x: u32 = 0;
        while (x < 16) : (x += 1) try testing.expectEqual(@as(u16, 0), fixture.onGlass(board, x, y));
    }
    // What is drawn, moved and shown meanwhile reaches no glass.
    const updates = fk.log.updates;
    fixture.poke(back, 4, 4, fixture.white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RefreshRect(back, null));
    fixture.base(rb).MoveBoardPointer(board, 5, 5);
    try testing.expectEqual(updates, fk.log.updates);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, front));
    try testing.expectEqual(@as(u32, 0), fk.log.last_flags & direct);
    try testing.expectEqual(@as(u16, 0), fixture.onGlass(board, 4, 4));
    try testing.expectEqual(front, fixture.base(rb).BoardDisplayBitMap(board).?);
    // Asleep on a board that does not sleep is blank, and nothing
    // changes; a state there is none of is refused.
    try testing.expectEqual(@as(i32, @intCast(blank)), fixture.base(rb).SetBoardPower(board, asleep));
    try testing.expectEqual(blank, fixture.infoOf(rb, board).power);
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).SetBoardPower(board, 3));

    // On again: what was shown meanwhile, read by the display itself.
    try testing.expectEqual(@as(i32, @intCast(on)), fixture.base(rb).SetBoardPower(board, on));
    try testing.expect(fk.log.last_flags & direct != 0);
    try testing.expectEqual(front, fk.log.bands[0].bitmap);
    try testing.expectEqual(on, fixture.infoOf(rb, board).power);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, null));
    fixture.base(rb).FreeBitMap(front);
    fixture.base(rb).FreeBitMap(back);
    fixture.driverBase(rb).DeleteBoard(board);

    // A display with a picture of its own alone: delivered black, then
    // the picture with what was drawn meanwhile.
    const own = try fixture.makeComposed(rb, 16, 12, 0);
    const picture = fixture.base(rb).AllocBitMap(own, 16, 12, format, displayable).?;
    fixture.paint(picture, 3);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(own, picture));
    try testing.expectEqual(@as(i32, @intCast(blank)), fixture.base(rb).SetBoardPower(own, blank));
    try testing.expectEqual(@as(u16, 0), fixture.onGlass(own, 9, 9));
    var fetched: [2]u16 = .{ 7, 7 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.driverBase(rb).ComposeLines(own, &.{ .x = 3, .y = 3, .width = 2, .height = 1 }, @ptrCast(&fetched), 4));
    try testing.expectEqual([2]u16{ 0, 0 }, fetched);
    fixture.poke(picture, 9, 9, fixture.white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RefreshRect(picture, &.{ .x = 9, .y = 9, .width = 1, .height = 1 }));
    try testing.expectEqual(@as(u16, 0), fixture.onGlass(own, 9, 9));
    try testing.expectEqual(@as(i32, @intCast(on)), fixture.base(rb).SetBoardPower(own, on));
    try testing.expectEqual(fixture.white, fixture.onGlass(own, 9, 9));
    try testing.expectEqual(fixture.painted(3, 2, 2), fixture.onGlass(own, 2, 2));
    // A black picture the driver cannot deliver leaves the board on.
    fk.update_answer = rtg.errors.RTGERR_NO_DISPLAY;
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, fixture.base(rb).SetBoardPower(own, blank));
    fk.update_answer = rtg.errors.RTGERR_OK;
    try testing.expectEqual(on, fixture.infoOf(rb, own).power);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RefreshRect(picture, null));
    try testing.expectEqual(fixture.painted(3, 2, 2), fixture.onGlass(own, 2, 2));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(own, null));
    fixture.base(rb).FreeBitMap(picture);
    fixture.driverBase(rb).DeleteBoard(own);

    // A flipped board: the next picture is black, nothing is made of
    // what is drawn meanwhile, and the whole picture when it is on.
    const flipped = try fixture.makeFlipped(rb, 16, 12);
    const frame = fixture.base(rb).AllocBitMap(flipped, 16, 12, format, displayable).?;
    fixture.paint(frame, 4);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(flipped, frame));
    try testing.expectEqual(@as(i32, @intCast(blank)), fixture.base(rb).SetBoardPower(flipped, blank));
    fixture.flips.service(rb, flipped);
    try testing.expectEqual(@as(u16, 0), fixture.glassAt(flipped, 0, 0));
    try testing.expectEqual(@as(u16, 0), fixture.glassAt(flipped, 15, 11));
    const flipped_before = fk.log.flips;
    fixture.poke(frame, 6, 6, fixture.white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).RefreshRect(frame, &.{ .x = 6, .y = 6, .width = 1, .height = 1 }));
    fixture.flips.service(rb, flipped);
    try testing.expectEqual(flipped_before, fk.log.flips);
    try testing.expectEqual(@as(i32, @intCast(on)), fixture.base(rb).SetBoardPower(flipped, on));
    fixture.flips.service(rb, flipped);
    try testing.expect(fixture.glassIs(flipped, 4, &.{.{ 6, 6, fixture.white }}));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(flipped, null));
    fixture.base(rb).FreeBitMap(frame);
    fixture.driverBase(rb).DeleteBoard(flipped);
    try fixture.tearDown(rb);
}

test "asleep is the driver's, asked once the picture is black; the backlight is kept through it" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const on = rtg.boards.RTGPWR_ON;
    const blank = rtg.boards.RTGPWR_BLANK;
    const asleep = rtg.boards.RTGPWR_ASLEEP;
    fk.hardware = true;
    const board = try fixture.makeComposed(rb, 16, 12, 0);
    fk.hardware = false;
    try testing.expect(fixture.infoOf(rb, board).caps & rtg.boards.RTGBC_POWER != 0);
    const picture = fixture.base(rb).AllocBitMap(board, 16, 12, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    fixture.paint(picture, 1);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, picture));
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardBrightness(board, 70));

    // Blank asks the driver nothing: the picture is black, and that is
    // all.
    try testing.expectEqual(@as(i32, @intCast(blank)), fixture.base(rb).SetBoardPower(board, blank));
    try testing.expectEqual(@as(u32, 0), fk.log.power_calls);
    try testing.expectEqual(@as(u16, 0), fixture.onGlass(board, 3, 3));
    // Asleep from there: the driver alone.
    const updates = fk.log.updates;
    try testing.expectEqual(@as(i32, @intCast(asleep)), fixture.base(rb).SetBoardPower(board, asleep));
    try testing.expectEqual(@as(u32, 1), fk.log.power_calls);
    try testing.expectEqual(asleep, fk.log.last_power);
    try testing.expectEqual(updates, fk.log.updates);
    try testing.expectEqual(asleep, fixture.infoOf(rb, board).power);
    // A brightness set while it sleeps is kept, and not applied.
    const calls = fk.log.brightness_calls;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardBrightness(board, 30));
    try testing.expectEqual(calls, fk.log.brightness_calls);
    try testing.expectEqual(@as(u32, 30), fixture.infoOf(rb, board).brightness);
    try testing.expectEqual(@as(u32, 0), fk.log.brightness);
    // Blank again: awake, and black still.
    try testing.expectEqual(@as(i32, @intCast(blank)), fixture.base(rb).SetBoardPower(board, blank));
    try testing.expectEqual(on, fk.log.last_power);
    try testing.expectEqual(@as(u32, 30), fk.log.brightness);
    try testing.expectEqual(@as(u16, 0), fixture.onGlass(board, 3, 3));
    try testing.expectEqual(@as(i32, @intCast(on)), fixture.base(rb).SetBoardPower(board, on));
    try testing.expect(fixture.seesOnly(board, 1));

    // From on: black first, then asleep; and awake before the picture.
    try testing.expectEqual(@as(i32, @intCast(asleep)), fixture.base(rb).SetBoardPower(board, asleep));
    try testing.expectEqual(@as(u16, 0), fixture.onGlass(board, 3, 3));
    try testing.expectEqual(@as(i32, @intCast(on)), fixture.base(rb).SetBoardPower(board, on));
    try testing.expectEqual(on, fk.log.last_power);
    try testing.expect(fixture.seesOnly(board, 1));

    // A display that only goes blank says so; one that will not sleep
    // leaves the board on, its picture back.
    fk.sleep_answer = @intCast(blank);
    try testing.expectEqual(@as(i32, @intCast(blank)), fixture.base(rb).SetBoardPower(board, asleep));
    try testing.expectEqual(blank, fixture.infoOf(rb, board).power);
    try testing.expectEqual(@as(i32, @intCast(on)), fixture.base(rb).SetBoardPower(board, on));
    fk.sleep_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, fixture.base(rb).SetBoardPower(board, asleep));
    try testing.expectEqual(on, fixture.infoOf(rb, board).power);
    try testing.expect(fixture.seesOnly(board, 1));
    fk.sleep_answer = @intCast(asleep);

    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, null));
    fixture.base(rb).FreeBitMap(picture);
    fixture.driverBase(rb).DeleteBoard(board);
    try fixture.tearDown(rb);
}

test "a display that reads its buffers of alone: every state its driver's, or nothing shown where it has none" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    const on = rtg.boards.RTGPWR_ON;
    const blank = rtg.boards.RTGPWR_BLANK;
    const asleep = rtg.boards.RTGPWR_ASLEEP;

    // With a power of its own: asked for each state, and shown nothing
    // other than it was.
    const board = try fixture.makeDisplay(rb, 16, 16);
    const picture = fixture.base(rb).AllocBitMap(board, 16, 16, format, displayable).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, picture));
    const shown = fk.log.shown;
    try testing.expectEqual(@as(i32, @intCast(blank)), fixture.base(rb).SetBoardPower(board, blank));
    try testing.expectEqual(blank, fk.log.last_power);
    try testing.expectEqual(@as(i32, @intCast(asleep)), fixture.base(rb).SetBoardPower(board, asleep));
    try testing.expectEqual(asleep, fk.log.last_power);
    try testing.expectEqual(asleep, fixture.infoOf(rb, board).power);
    try testing.expectEqual(@as(i32, @intCast(on)), fixture.base(rb).SetBoardPower(board, on));
    try testing.expectEqual(@as(u32, 3), fk.log.power_calls);
    try testing.expectEqual(shown, fk.log.shown);
    // The same state again asks nobody.
    try testing.expectEqual(@as(i32, @intCast(on)), fixture.base(rb).SetBoardPower(board, on));
    try testing.expectEqual(@as(u32, 3), fk.log.power_calls);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, null));
    fixture.base(rb).FreeBitMap(picture);
    fixture.driverBase(rb).DeleteBoard(board);

    // With none: its driver is shown nothing while the board is dark,
    // the buffers stay the board's, and what is shown meanwhile is what
    // it is shown when it is on again.
    fk.without_engine = true;
    const plain = try fixture.makeDisplay(rb, 16, 16);
    fk.without_engine = false;
    try testing.expectEqual(@as(u32, 0), fixture.infoOf(rb, plain).caps & rtg.boards.RTGBC_POWER);
    const one = fixture.base(rb).AllocBitMap(plain, 16, 16, format, displayable).?;
    const other = fixture.base(rb).AllocBitMap(plain, 16, 16, format, displayable).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(plain, one));
    try testing.expectEqual(@as(i32, @intCast(blank)), fixture.base(rb).SetBoardPower(plain, asleep));
    try testing.expectEqual(@as(u32, 0), fk.log.band_count);
    try testing.expectEqual(@as(u32, 0), fixture.fake.instanceOf(plain).showing_count);
    try testing.expectEqual(one, fixture.base(rb).BoardDisplayBitMap(plain).?);
    try testing.expect(one.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(plain, other));
    try testing.expectEqual(@as(u32, 0), fk.log.band_count);
    try testing.expectEqual(other, fixture.base(rb).BoardDisplayBitMap(plain).?);
    try testing.expectEqual(@as(i32, @intCast(on)), fixture.base(rb).SetBoardPower(plain, on));
    try testing.expectEqual(@as(u32, 1), fk.log.band_count);
    try testing.expectEqual(other, fk.log.bands[0].bitmap);
    try testing.expectEqual(@as(u32, 1), fixture.fake.instanceOf(plain).showing_count);
    // A driver that will not show nothing leaves the board on.
    fk.show_answer = rtg.errors.RTGERR_NO_DISPLAY;
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, fixture.base(rb).SetBoardPower(plain, blank));
    try testing.expectEqual(on, fixture.infoOf(rb, plain).power);

    // A board whose device has gone has no display to put in a state.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(plain, null));
    fixture.base(rb).FreeBitMap(other);
    fixture.base(rb).FreeBitMap(one);
    fixture.boards.retire(rb, plain);
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, fixture.base(rb).SetBoardPower(plain, blank));
    fixture.driverBase(rb).DeleteBoard(plain);
    try fixture.tearDown(rb);
}
