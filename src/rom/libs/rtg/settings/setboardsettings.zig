// SPDX-License-Identifier: MPL-2.0
//! SetBoardSettings: A board's line changed, and applied.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const boards = @import("../board/_board.zig");
const settings = @import("_settings.zig");

/// Makes a structure the board's settings line, and applies it.
///
/// SYNOPSIS:
/// ```zig
/// fn SetBoardSettings(rb: *RtgBase, board: *rtg.RtgBoard, line: *const rtg.RtgSettings) i32
/// ```
///
/// SINCE: 1.34. LVO -116.
///
/// INPUTS:
/// - `board` - the board.
/// - `line` - what the line says: the fields whose flags are set. Its
///   `RTGSET_MONITOR`, `maker`, `product` and `serial` are not read.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_BAD_ARG` for a brightness above 100, a mode of
/// no size, or timings without a clock, a size and a sync pulse each
/// way; `RTGERR_NO_MEMORY` without room for a new line. Nothing changes
/// on either.
///
/// BEHAVIOR:
/// The line is for the monitor on the board now: where that monitor
/// says who it is, the line names it and is passed over while another
/// is on the output; on a panel's board, and with nothing or a monitor
/// that says nothing on the connector, the line names none. It takes
/// the place of the line that was there for that monitor; lines for
/// other monitors of the output stay. A line whose flags are all clear
/// takes the line away.
///
/// Applied at once:
/// - `RTGSET_MODE`: the mode of that size - at that refresh to the
///   nearest Hertz, or with a refresh of 0 the one the board prefers of
///   that size - is the board's default, where the board has it:
///   `BestBoardMode` with everything left open answers it. The mode the
///   board is in stays; intuition.library puts a display in the mode
///   its line names when the display's first screen opens. Where the
///   board has not got the mode, the default is its own.
/// - `RTGSET_TIMINGS`: on a board whose monitor names no mode the board
///   can make, a mode of these timings is added and is the default.
/// - `RTGSET_MIRROR`: the picture is mirrored about the axes set, as
///   `MirrorBoard` does it.
/// - `RTGSET_BRIGHTNESS`: as `SetBoardBrightness` sets it.
/// - `RTGSET_RANGE`: the board's `color_range` is the line's, and a
///   board whose driver reads it (`RTGBC_COLOR_RANGE`) is shown again
///   with its link's colours in that range. Without the flag the range
///   is the monitor's own again.
/// - `RTGSET_FIRST`: the board is the first of the library's list,
///   `NextBoard(null)`, and no other output's line says so any more.
///   Without the flag it stands where it was made.
///
/// What a board cannot do - a mirror without the cap, a brightness with
/// no backlight to set - stays in the line and does nothing. The tasks
/// that asked are told where the board's modes or its place changed
/// (`AddRtgNotify`).
///
/// The change is in force and is not on the disk: `SaveBoardSettings`
/// writes it.
///
/// CONTEXT:
/// - Waits: where a driver waits for its display, and while another
///   task holds the board's lock.
/// - Interrupts: no.
/// - Locks: takes the board's lock and the settings' inside it, then
///   the board list's. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The line is copied; `line` is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetBoardSettings`, `SaveBoardSettings`, `MirrorBoard`,
/// `SetBoardBrightness`, `BestBoardMode`
///
/// EXAMPLES:
/// ```zig
/// // The board comes up in 1920x1080 from now on, and is kept so.
/// var line: rtg.RtgSettings = .{};
/// _ = rb.GetBoardSettings(board, &line, @sizeOf(rtg.RtgSettings));
/// line.flags |= rtg.RTGSET_MODE;
/// line.mode_width = 1920;
/// line.mode_height = 1080;
/// line.mode_refresh_mhz = 0;
/// if (rb.SetBoardSettings(board, &line) == rtg.errors.RTGERR_OK) {
///     _ = rb.SaveBoardSettings(rtg.RTG_SETTINGS_ENVARC);
/// }
/// ```
pub fn SetBoardSettings(rb: *RtgBase, board: *rtg.RtgBoard, line: *const rtg.RtgSettings) i32 {
    var kept = line.*;
    if (kept.flags & rtg.RTGSET_BRIGHTNESS != 0 and kept.brightness > 100) return err.RTGERR_BAD_ARG;
    if (kept.flags & rtg.RTGSET_MODE != 0 and (kept.mode_width == 0 or kept.mode_height == 0)) return err.RTGERR_BAD_ARG;
    if (kept.flags & rtg.RTGSET_TIMINGS != 0 and !settings.timingsMakeSense(&kept.timings)) return err.RTGERR_BAD_ARG;

    // For the monitor that is there, and the line put on the list, as one
    // step under the board's lock: a monitor that comes meanwhile finds
    // either the old line or the new.
    boards.obtain(rb, board);
    kept.flags &= ~@as(u32, rtg.RTGSET_MONITOR);
    kept.maker = @splat(0);
    kept.product = 0;
    kept.serial = 0;
    if (settings.identityOf(board)) |who| {
        kept.flags |= rtg.RTGSET_MONITOR;
        kept.maker = who.maker;
        kept.product = who.product;
        kept.serial = who.serial;
    }
    settings.obtain(rb);
    const name = settings.nameOf(board);
    const put = settings.put(rb, name, &kept);
    if (put and kept.flags & rtg.RTGSET_FIRST != 0) settings.onlyFirst(rb, name);
    settings.release(rb);
    boards.release(rb, board);
    if (!put) return err.RTGERR_NO_MEMORY;

    // One board is the first: the others' places are put right before
    // this one's.
    if (kept.flags & rtg.RTGSET_FIRST != 0) {
        var other = rb.iface().NextBoard(null);
        while (other) |one| {
            other = rb.iface().NextBoard(one);
            if (one != board) boards.setFirst(rb, one, false);
        }
    }
    settings.applyTo(rb, board);
    return err.RTGERR_OK;
}

// --- tests (host: ./zig build test) -----------------------------------------

const fixture = @import("../_testing.zig");
const std = fixture.std;
const testing = fixture.testing;

test "a board's line: its mode the default, mirror and brightness set, the range in its info, and taken away again" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    fk.color_range = true;
    const board = try fixture.makeDisplay(rb, 16, 16);
    fk.color_range = false;
    const small = fixture.addMode(rb, board, 8, 8);
    const own = fixture.defaultMode(rb, board);
    try testing.expectEqual(@as(u32, 16), own.width);
    try testing.expectEqual(@as(u32, 0), fixture.lineOf(rb, board).flags);
    try testing.expect(fixture.infoOf(rb, board).caps & rtg.boards.RTGBC_COLOR_RANGE != 0);

    const picture = fixture.base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, picture));
    const in_mode = fixture.infoOf(rb, board).mode_id;
    const shown = fk.log.shown;
    const brightness_calls = fk.log.brightness_calls;

    // What is out of its range changes nothing.
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).SetBoardSettings(board, &.{ .flags = rtg.RTGSET_BRIGHTNESS, .brightness = 101 }));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).SetBoardSettings(board, &.{ .flags = rtg.RTGSET_MODE, .mode_width = 8 }));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, fixture.base(rb).SetBoardSettings(board, &.{ .flags = rtg.RTGSET_TIMINGS }));
    try testing.expectEqual(@as(u32, 0), fixture.lineOf(rb, board).flags);

    // The line: the smaller mode is what the board comes up in, the mode
    // it is in stays; mirrored and dimmed at once; the range in its info,
    // and the link brought up again for it.
    const wanted: rtg.RtgSettings = .{
        .flags = rtg.RTGSET_MODE | rtg.RTGSET_MIRROR | rtg.RTGSET_MIRROR_Y | rtg.RTGSET_BRIGHTNESS | rtg.RTGSET_RANGE | rtg.RTGSET_LIMITED_RANGE,
        .mode_width = 8,
        .mode_height = 8,
        .brightness = 40,
        // A panel has no monitor to name: what a caller says of one is
        // not read.
        .maker = .{ 'X', 'Y', 'Z', 0 },
        .product = 7,
    };
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardSettings(board, &wanted));
    try testing.expectEqual(small, fixture.defaultMode(rb, board).id);
    try testing.expect(fixture.defaultMode(rb, board).flags & rtg.modes.RTGMF_DEFAULT != 0);
    var info = fixture.infoOf(rb, board);
    try testing.expectEqual(in_mode, info.mode_id);
    try testing.expectEqual(@as(u8, 0), info.mirror_x);
    try testing.expectEqual(@as(u8, 1), info.mirror_y);
    try testing.expectEqual(@as(u32, 40), info.brightness);
    try testing.expectEqual(brightness_calls + 1, fk.log.brightness_calls);
    try testing.expectEqual(rtg.RTGRANGE_LIMITED, info.color_range);
    // Shown again twice: for the range, and the other way up.
    try testing.expectEqual(shown + 2, fk.log.shown);
    var line = fixture.lineOf(rb, board);
    try testing.expectEqual(wanted.flags, line.flags);
    try testing.expectEqual(@as(u32, 0), line.product);
    try testing.expectEqual(@as(u32, 8), line.mode_width);

    // As the file has it.
    var file: [fixture.settings.header.len + 2 * fixture.settings.line_most]u8 = undefined;
    try testing.expectEqualStrings("OUTPUT=fake.0 MODE=8x8 MIRROR=Y BRIGHTNESS=40 RANGE=LIMITED\n", fixture.settingsText(rb, &file)[fixture.settings.header.len..]);

    // A mode the board has not got stays in the line, and the default is
    // the board's own; the range said full.
    line.mode_width = 640;
    line.mode_height = 480;
    line.flags &= ~@as(u32, rtg.RTGSET_LIMITED_RANGE);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardSettings(board, &line));
    try testing.expectEqual(own.id, fixture.defaultMode(rb, board).id);
    try testing.expectEqual(rtg.RTGRANGE_FULL, fixture.infoOf(rb, board).color_range);
    try testing.expectEqual(@as(u32, 640), fixture.lineOf(rb, board).mode_width);

    // The line taken away: the default and the range the board's own
    // again, the mirror and the brightness left as they are.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardSettings(board, &.{}));
    try testing.expectEqual(@as(u32, 0), fixture.lineOf(rb, board).flags);
    info = fixture.infoOf(rb, board);
    try testing.expectEqual(rtg.RTGRANGE_AUTO, info.color_range);
    try testing.expectEqual(@as(u8, 1), info.mirror_y);
    try testing.expectEqual(@as(u32, 40), info.brightness);
    try testing.expectEqualStrings("", fixture.settingsText(rb, &file)[fixture.settings.header.len..]);

    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).ShowBitMap(board, null));
    fixture.base(rb).FreeBitMap(picture);
    try fixture.tearDown(rb);
}

test "a line is for the monitor it names: another on the output and it is not used, the first back and it is" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    const fk = fixture.fakeOf(rb);
    // A panel's board first, then one with a connector and a 4K monitor.
    const panel = try fixture.makeDisplay(rb, 16, 16);
    fk.display = null;
    const board = try fixture.makeConnector(rb, fixture.uhd_bytes, 0);
    try testing.expectEqual(panel, fixture.base(rb).NextBoard(null).?);
    try testing.expectEqual(@as(u32, 1920), fixture.defaultMode(rb, board).width);
    const who = fixture.monitorOf(rb, board);

    // Its line: 4K at 30, where it would come up in 1080p, and this
    // board the first.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardSettings(board, &.{
        .flags = rtg.RTGSET_MODE | rtg.RTGSET_FIRST,
        .mode_width = 3840,
        .mode_height = 2160,
        .mode_refresh_mhz = 30_000,
    }));
    try testing.expectEqual(@as(u32, 3840), fixture.defaultMode(rb, board).width);
    try testing.expectEqual(board, fixture.base(rb).NextBoard(null).?);
    try testing.expectEqual(panel, fixture.base(rb).NextBoard(board).?);
    var line = fixture.lineOf(rb, board);
    try testing.expect(line.flags & rtg.RTGSET_MONITOR != 0);
    try testing.expectEqualStrings(std.mem.sliceTo(&who.maker, 0), std.mem.sliceTo(&line.maker, 0));
    try testing.expectEqual(who.product, line.product);
    try testing.expectEqual(who.serial, line.serial);

    // Another monitor that names the same modes: the line is not its own.
    // It comes up in the mode it prefers, and the board stands where it
    // was made.
    const other = fixture.otherUhd();
    fk.monitor_edid = std.mem.sliceAsBytes(&other);
    fixture.driverBase(rb).MonitorChanged(board);
    fixture.monitors.service(rb);
    try testing.expectEqual(@as(u32, 0), fixture.lineOf(rb, board).flags);
    try testing.expectEqual(@as(u32, 1920), fixture.defaultMode(rb, board).width);
    try testing.expectEqual(panel, fixture.base(rb).NextBoard(null).?);

    // A line of its own for this one, by the file: both are kept.
    var file: [fixture.settings.header.len + 4 * fixture.settings.line_most]u8 = undefined;
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardSettings(board, &.{ .flags = rtg.RTGSET_BRIGHTNESS, .brightness = 55 }));
    const kept = fixture.settingsText(rb, &file)[fixture.settings.header.len..];
    try testing.expect(std.mem.indexOf(u8, kept, ":0000:00000000 MODE=3840x2160@30 FIRST=YES\n") != null);
    try testing.expect(std.mem.indexOf(u8, kept, ":1234:00000000 BRIGHTNESS=55\n") != null);

    // The first monitor back: its line is in force again.
    fk.monitor_edid = fixture.uhd_bytes;
    fixture.driverBase(rb).MonitorChanged(board);
    fixture.monitors.service(rb);
    line = fixture.lineOf(rb, board);
    try testing.expectEqual(rtg.RTGSET_MONITOR | rtg.RTGSET_MODE | rtg.RTGSET_FIRST, line.flags);
    try testing.expectEqual(@as(u32, 3840), fixture.defaultMode(rb, board).width);
    try testing.expectEqual(board, fixture.base(rb).NextBoard(null).?);

    // A line that names no monitor is for whatever is there, where the
    // monitor has none of its own: read from a file, it is the other
    // monitor's and not this one's.
    try testing.expectEqual(@as(u32, 0), fixture.readSettings(rb, "OUTPUT=fake.1 MODE=3840x2160@30\nOUTPUT=fake.1 MONITOR=???:1234:0 MODE=1920x1080\n"));
    fixture.settings.applyAll(rb);
    try testing.expectEqual(@as(u32, 3840), fixture.defaultMode(rb, board).width);
    try testing.expectEqual(@as(u32, 30_000), fixture.defaultMode(rb, board).refresh_mhz);
    try testing.expectEqual(panel, fixture.base(rb).NextBoard(null).?);
    fk.monitor_edid = std.mem.sliceAsBytes(&other);
    fixture.driverBase(rb).MonitorChanged(board);
    fixture.monitors.service(rb);
    try testing.expectEqual(@as(u32, 1920), fixture.defaultMode(rb, board).width);

    // One board is the first: said of the panel's, the other's line no
    // longer says it.
    try testing.expectEqual(@as(u32, 0), fixture.readSettings(rb, "OUTPUT=fake.1 FIRST=YES\n"));
    fixture.settings.applyAll(rb);
    try testing.expectEqual(board, fixture.base(rb).NextBoard(null).?);
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardSettings(panel, &.{ .flags = rtg.RTGSET_FIRST }));
    try testing.expectEqual(panel, fixture.base(rb).NextBoard(null).?);
    try testing.expectEqualStrings("OUTPUT=fake.0 FIRST=YES\n", fixture.settingsText(rb, &file)[fixture.settings.header.len..]);
    try fixture.tearDown(rb);
}

test "timings by hand: the mode of a monitor that names none, and gone with its line" {
    const rb = try fixture.setUp();
    defer fixture.kexec.deinit();
    // A monitor that is there and says nothing, on a board with modes of
    // its own.
    const fk = fixture.fakeOf(rb);
    fk.connector = true;
    fk.modes = fixture.fake.mode_table.len;
    fk.monitor_there = true;
    fk.monitor_edid = null;
    const board = try fixture.makeBoard(rb);
    const own = fixture.base(rb).GetBoardModes(board, null, 0);
    const own_default = fixture.defaultMode(rb, board);

    const by_hand: rtg.RtgSettings = .{
        .flags = rtg.RTGSET_TIMINGS,
        .timings = .{
            .pixel_clock_hz = 40_000_000,
            .h_active = 800,
            .h_front = 40,
            .h_sync = 128,
            .h_back = 88,
            .v_active = 600,
            .v_front = 1,
            .v_sync = 4,
            .v_back = 23,
            .flags = rtg.modes.RTGTM_HSYNC_HIGH | rtg.modes.RTGTM_VSYNC_HIGH,
        },
    };
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardSettings(board, &by_hand));
    try testing.expectEqual(own + 1, fixture.base(rb).GetBoardModes(board, null, 0));
    const made = fixture.defaultMode(rb, board);
    try testing.expectEqual(@as(u32, 800), made.width);
    try testing.expectEqual(@as(u32, 600), made.height);
    try testing.expectEqual(@as(u32, 40_000_000), made.pixel_clock_hz);
    // A monitor that says nothing is not named.
    try testing.expectEqual(rtg.RTGSET_TIMINGS, fixture.lineOf(rb, board).flags);

    // The line gone, the mode is gone, and the default the board's own.
    try testing.expectEqual(rtg.errors.RTGERR_OK, fixture.base(rb).SetBoardSettings(board, &.{}));
    try testing.expectEqual(own, fixture.base(rb).GetBoardModes(board, null, 0));
    try testing.expectEqual(own_default.id, fixture.defaultMode(rb, board).id);
    try fixture.tearDown(rb);
}
