// SPDX-License-Identifier: MPL-2.0
//! rtg.library: the displays of this machine, and the drivers that drive
//! them.
//!
//! The library itself drives nothing. It holds a list of drivers, makes
//! the handles a driver fills in, keeps the buffers a board's display
//! memory is cut into, and passes the calls through. What is on the other
//! side - a panel wired straight to the pixels, a controller on a bus, a
//! window somewhere else - is the driver's business and nobody else's.
//!
//! It does not draw either. A buffer is memory with a width, a height, a
//! pitch and a format, and whoever holds one writes into it and then hands
//! what it wrote on with RefreshRect. The drawing calls are here so that a
//! board whose own engine is faster than the CPU can offer that, and a
//! board that has no engine answers RTGERR_NOT_SUPPORTED - the library
//! never quietly does the work instead, because the layer that does know
//! how to draw is the one above.
//!
//! The base is opened with OpenLibrary("rtg.library", 1). Its functions
//! are two interfaces of the one jump table: sdk/fd/rtg_lib.fd for
//! programs, sdk/fd/rtgdriver_lib.fd for drivers. Its types are
//! sdk/libs/rtg/.
//!
//! Each call is a file of its own in the folder for its category -
//! driver/, device/, load/, board/, mode/, monitor/, bitmap/, display/,
//! engine/, frame/, transport/, tag/, pointer/, video/, settings/ and
//! errors/ - compose/ holds the picture the library makes for a board
//! (in place, and flipped between two frames), and memory/ the arena
//! display memory is cut from.
//! The jump table is rtg_lvo.zig, the ROM tag and init rtg_init.zig, the
//! base rtg_base.zig. This file holds the names the rest of the kernel
//! reaches the library by, and the tests of calls working together; a
//! call's own tests are at the end of its file, and what the tests share
//! is `_testing.zig`. The drivers are in `../rtg_driver/`, a folder
//! each, with fakeboard/ for the host tests.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const rtg = sdk.rtg;

/// rtg.library's base (rtg_base.zig).
const rtg_base = @import("rtg_base.zig");
/// rtg.library's ROM tag and init routine (rtg_init.zig).
const rtg_init = @import("rtg_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from rtg.library.
comptime {
    _ = &rtg_init.rtg_library_tag;
}

/// The library's base, for the modules that keep a pointer to it.
pub const RtgBase = rtg_base.RtgBase;
/// What the library is on exec's list as.
pub const LIBRARY_NAME = rtg_init.LIBRARY_NAME;
/// The ROM tag, for the host tests that make the library from it.
pub const rtg_library_tag = rtg_init.rtg_library_tag;

// --- tests (host: ./zig build test) -----------------------------------------

/// What the tests share: the library made from its tag with the kernel's
/// exec and utility around it, the tests' board and its driver, and the
/// helpers that make boards and read what they did (`_testing.zig`).
const fixture = @import("_testing.zig");
const testing = fixture.testing;
const boards = fixture.boards;
const monitors = fixture.monitors;
const flips = fixture.flips;
const kexec = fixture.kexec;
const kutility = fixture.kutility;
const kpens = fixture.kpens;
const fake = fixture.fake;
const FakeTimer = fixture.FakeTimer;
const Sleep = fixture.Sleep;
const setUp = fixture.setUp;
const fakeOf = fixture.fakeOf;
const driverNamed = fixture.driverNamed;
const driverNames = fixture.driverNames;
const tearDown = fixture.tearDown;
const base = fixture.base;
const driverBase = fixture.driverBase;
const setMode = fixture.setMode;
const makeBoard = fixture.makeBoard;
const RomTags = fixture.RomTags;
const makeConnector = fixture.makeConnector;
const infoOf = fixture.infoOf;
const smallTiming = fixture.smallTiming;
const smallMonitor = fixture.smallMonitor;
const makeDisplay = fixture.makeDisplay;
const addMode = fixture.addMode;
const Held = fixture.Held;
const freeOf = fixture.freeOf;
const endOneFrame = fixture.endOneFrame;
const rowOf = fixture.rowOf;
const rgba = fixture.rgba;
const makeComposed = fixture.makeComposed;
const painted = fixture.painted;
const paint = fixture.paint;
const poke = fixture.poke;
const onGlass = fixture.onGlass;
const seesOnly = fixture.seesOnly;
const red = fixture.red;
const green = fixture.green;
const blue = fixture.blue;
const white = fixture.white;
const Composing = fixture.Composing;
const flood = fixture.flood;
const makeFlipped = fixture.makeFlipped;
const glassAt = fixture.glassAt;
const glassIs = fixture.glassIs;
const Flipping = fixture.Flipping;

// Every file of the library, so that each call's own tests run.
test {
    _ = @import("bitmap/_bitmap.zig");
    _ = @import("bitmap/allocbitmap.zig");
    _ = @import("bitmap/attachbitmap.zig");
    _ = @import("bitmap/freebitmap.zig");
    _ = @import("bitmap/lockbitmap.zig");
    _ = @import("bitmap/refreshrect.zig");
    _ = @import("bitmap/rehomebitmap.zig");
    _ = @import("bitmap/rtgformatbits.zig");
    _ = @import("bitmap/rtgrowbytes.zig");
    _ = @import("bitmap/unlockbitmap.zig");
    _ = @import("board/_board.zig");
    _ = @import("board/addrtgnotify.zig");
    _ = @import("board/boardcontrol.zig");
    _ = @import("board/createboard.zig");
    _ = @import("board/deleteboard.zig");
    _ = @import("board/findboard.zig");
    _ = @import("board/getboardinfo.zig");
    _ = @import("board/getboardstats.zig");
    _ = @import("board/nextboard.zig");
    _ = @import("board/remrtgnotify.zig");
    _ = @import("compose/_compose.zig");
    _ = @import("compose/_damage.zig");
    _ = @import("compose/_flip.zig");
    _ = @import("compose/_scale.zig");
    _ = @import("compose/composelines.zig");
    _ = @import("device/_device.zig");
    _ = @import("device/addrtgdevice.zig");
    _ = @import("device/bindrtgdrivers.zig");
    _ = @import("device/getrtgdevices.zig");
    _ = @import("device/remrtgdevice.zig");
    _ = @import("display/_display.zig");
    _ = @import("display/boarddisplaybitmap.zig");
    _ = @import("display/mirrorboard.zig");
    _ = @import("display/rtgdelay.zig");
    _ = @import("display/setboardaudio.zig");
    _ = @import("display/setboardbrightness.zig");
    _ = @import("display/setboardpower.zig");
    _ = @import("display/showbitmap.zig");
    _ = @import("display/showboard.zig");
    _ = @import("display/waitvblank.zig");
    _ = @import("driver/_driver.zig");
    _ = @import("driver/addrtgdriver.zig");
    _ = @import("driver/getrtgdrivers.zig");
    _ = @import("driver/remrtgdriver.zig");
    _ = @import("engine/_engine.zig");
    _ = @import("engine/blendpixels.zig");
    _ = @import("engine/blendrect.zig");
    _ = @import("engine/blitpattern.zig");
    _ = @import("engine/blittemplate.zig");
    _ = @import("engine/copyrect.zig");
    _ = @import("engine/copyrects.zig");
    _ = @import("engine/fillrect.zig");
    _ = @import("engine/scalepixels.zig");
    _ = @import("errors/rtgerrortext.zig");
    _ = @import("frame/_frame.zig");
    _ = @import("frame/framedone.zig");
    _ = @import("load/_load.zig");
    _ = @import("load/loadrtgdrivers.zig");
    _ = @import("memory/_memory.zig");
    _ = @import("mode/_mode.zig");
    _ = @import("mode/addboardmode.zig");
    _ = @import("mode/bestboardmode.zig");
    _ = @import("mode/findboardmode.zig");
    _ = @import("mode/getboardmodes.zig");
    _ = @import("mode/readtimingtags.zig");
    _ = @import("monitor/_edid.zig");
    _ = @import("monitor/_monitor.zig");
    _ = @import("monitor/buildaviinfoframe.zig");
    _ = @import("monitor/findstandardtimings.zig");
    _ = @import("monitor/getboardmonitor.zig");
    _ = @import("monitor/hdmiaudioclock.zig");
    _ = @import("monitor/getmonitorcontrol.zig");
    _ = @import("monitor/setmonitorcontrol.zig");
    _ = @import("monitor/_ddcci.zig");
    _ = @import("monitor/monitorchanged.zig");
    _ = @import("monitor/readboardedid.zig");
    _ = @import("pointer/moveboardoverlay.zig");
    _ = @import("pointer/moveboardpointer.zig");
    _ = @import("pointer/setboardoverlay.zig");
    _ = @import("pointer/setboardpointer.zig");
    _ = @import("pointer/showboardpointer.zig");
    _ = @import("rtg_base.zig");
    _ = @import("rtg_init.zig");
    _ = @import("rtg_lvo.zig");
    _ = @import("settings/_settings.zig");
    _ = @import("settings/getboardsettings.zig");
    _ = @import("settings/loadboardsettings.zig");
    _ = @import("settings/saveboardsettings.zig");
    _ = @import("settings/setboardsettings.zig");
    _ = @import("settings/setrtgdevicedriver.zig");
    _ = @import("tag/getrtgtagdata.zig");
    _ = @import("transport/_transport.zig");
    _ = @import("transport/closetransport.zig");
    _ = @import("transport/opentransport.zig");
    _ = @import("transport/runpanelsequence.zig");
    _ = @import("transport/rxparam.zig");
    _ = @import("transport/txcolor.zig");
    _ = @import("transport/txparam.zig");
    _ = @import("video/closevideolayer.zig");
    _ = @import("video/movevideolayer.zig");
    _ = @import("video/openvideolayer.zig");
    _ = @import("video/rtgcicp.zig");
    _ = @import("video/showvideoframe.zig");
}

// The tests' board runs its own tests too.
test {
    _ = @import("../rtg_driver/fakeboard/fakeboard.zig");
}

test "rtg.library: made from its tag, opened by name, utility of its own" {
    const rb = try setUp();
    defer kexec.deinit();
    try testing.expectEqual(&rb.lib, kexec.OpenLibrary(kexec.SysBase, LIBRARY_NAME, 1).?);
    try testing.expectEqual(@as(u16, 1), rb.lib.version);
    try testing.expect(kexec.OpenLibrary(kexec.SysBase, LIBRARY_NAME, 2) == null);
    kexec.CloseLibrary(kexec.SysBase, &rb.lib);
    // utility.library is open for the tag calls, and answers through it.
    const tag_list = [_]TagItem{ .{ .tag = rtg.tags.RTGA_Width, .data = 640 }, .{} };
    try testing.expectEqual(@as(usize, 640), driverBase(rb).GetRtgTagData(rtg.tags.RTGA_Width, 0, &tag_list));
    try testing.expectEqual(@as(usize, 7), driverBase(rb).GetRtgTagData(rtg.tags.RTGA_Height, 7, &tag_list));
    try tearDown(rb);
}

test "drivers: walked by priority, and never twice" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);

    // The same name is refused, and so is a driver that makes nothing.
    try testing.expect(driverBase(rb).AddRtgDriver(&fake.spec, null) == null);

    const empty_ops = rtg.RtgDriverOps{};
    const empty = rtg.RtgDriverSpec{ .name = "empty", .ops = &empty_ops };
    try testing.expect(driverBase(rb).AddRtgDriver(&empty, null) == null);

    const second_ops = rtg.RtgDriverOps{ .create_transport = @ptrFromInt(0x1000) };
    const second_spec = rtg.RtgDriverSpec{
        .name = "second",
        .priority = 10,
        .ops = &second_ops,
        .kind = rtg.drivers.RTGDT_TRANSPORT,
    };
    const second = driverBase(rb).AddRtgDriver(&second_spec, null).?;

    // Highest priority first: "second" at 10 before "fake" at 0.
    var listed: [8]rtg.RtgDriverInfo = undefined;
    try testing.expectEqual(@as(u32, 2), driverNames(rb, &listed));
    try testing.expectEqualStrings("second", std.mem.sliceTo(&listed[0].name, 0));
    try testing.expectEqualStrings("fake", std.mem.sliceTo(&listed[1].name, 0));
    try testing.expectEqual(second, driverNamed(rb, "second").?);
    try testing.expectEqual(fk.driver, driverNamed(rb, "fake").?);

    // Off the list once: a node that is not on it is not read.
    try testing.expect(driverBase(rb).RemRtgDriver(second));
    try testing.expect(!driverBase(rb).RemRtgDriver(second));
    try tearDown(rb);
}

test "the drivers of the ROM: read from their tags at the library's init, by their priority" {
    try kexec.setUp();
    defer kexec.deinit();
    _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
    try FakeTimer.add();
    // What a boot scan leaves: the tags, a driver's among them.
    var table = [_]?*const exec.Resident{ &RomTags.low.resident, &kutility.utility_library_tag, &RomTags.high.resident, null };
    kexec.SysBase.res_modules = &table;
    const made = kexec.InitResident(kexec.SysBase, &rtg_library_tag, null) orelse return error.NoRtg;
    kexec.SysBase.res_modules = null;
    const rb: *RtgBase = @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));

    // Both drivers are on the list, the higher first; the library's tag
    // is none of them.
    var listed: [8]rtg.RtgDriverInfo = undefined;
    try testing.expectEqual(@as(u32, 2), driverNames(rb, &listed));
    try testing.expectEqualStrings("high", std.mem.sliceTo(&listed[0].name, 0));
    try testing.expectEqualStrings("low", std.mem.sliceTo(&listed[1].name, 0));
    try testing.expectEqual(@as(u8, 0), listed[0].loaded);
    const high = driverNamed(rb, "high").?;
    const low = driverNamed(rb, "low").?;
    try testing.expectEqual(&RomTags.high.spec, high.spec);
    try testing.expectEqual(&RomTags.low.spec, low.spec);
    try testing.expect(high.seg_list == null);

    try testing.expect(driverBase(rb).RemRtgDriver(high));
    try testing.expect(driverBase(rb).RemRtgDriver(low));
    _ = fake.add(rb.sys_base, rb) orelse return error.NoDriver;
    try tearDown(rb);
}

test "two boards of one device: each an output, numbered as they were made, the first the display" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);

    fk.outputs = 2;
    const device = fake.addDevice(fk, null).?;
    try testing.expectEqual(@as(u32, 2), fk.driver.boards);
    try testing.expectEqual(@as(u32, 1), fk.driver.devices);
    const first = base(rb).NextBoard(null).?;
    const second = base(rb).NextBoard(first).?;
    try testing.expect(base(rb).NextBoard(second) == null);
    try testing.expectEqualStrings("fake.0", std.mem.span(first.node.name.?));
    try testing.expectEqualStrings("fake.1", std.mem.span(second.node.name.?));
    try testing.expectEqual(@as(u32, 0), first.unit);
    try testing.expectEqual(@as(u32, 1), second.unit);
    try testing.expectEqual(device, first.device.?);
    try testing.expectEqual(device, second.device.?);
    try testing.expect(fake.instanceOf(first) != fake.instanceOf(second));
    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(second, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqualStrings("Fake 1", std.mem.span(info.label.?));
    try testing.expectEqualStrings("panel.0", std.mem.span(info.device.?));

    var listed: [2]rtg.RtgDeviceInfo = undefined;
    try testing.expectEqual(@as(u32, 1), base(rb).GetRtgDevices(&listed, listed.len));
    try testing.expectEqual(@as(u32, 2), listed[0].boards);

    // Outside its attach a driver makes no board of the device.
    const full = rtg.RtgBoardOps{};
    try testing.expect(driverBase(rb).CreateBoard(fk.driver, device, &.{ .ops = &full }) == null);
    try tearDown(rb);
}

test "memory a display is already using is never handed out twice" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    fk.claims_display = true;
    const board = try makeBoard(rb);

    // The buffer the board came up showing is the caller's to look at and
    // nobody's to allocate.
    const shown = base(rb).BoardDisplayBitMap(board).?;
    try testing.expect(shown.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);
    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expect(info.memory_free < info.memory_total);
    try testing.expect(info.memory_total - info.memory_free <= fake.claimed_bytes);
    try testing.expect(info.memory_total - info.memory_free + 64 > fake.claimed_bytes);

    // What is allocated next starts past it.
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const next = base(rb).AllocBitMap(board, 16, 16, format, 0).?;
    try testing.expect(@intFromPtr(next.pixels.?) >= @intFromPtr(shown.pixels.?) + fake.claimed_bytes);

    base(rb).FreeBitMap(next);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "the board's lock: held around the driver's show, free after every call" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeDisplay(rb, 16, 16);
    const wide_mode = addMode(rb, board, 32, 8);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    Held.seen = 0;
    Held.missed = 0;
    fk.meanwhile = &Held.look;
    try testing.expect(Held.free(board));

    // A mode with nothing in it: the driver is asked under the lock.
    try testing.expectEqual(rtg.errors.RTGERR_OK, setMode(rb, board, 0));
    try testing.expectEqual(@as(u32, 1), Held.seen);
    try testing.expect(Held.free(board));

    // Buffers made and described: the lock is free again, also where the
    // call was refused.
    const back = base(rb).AllocBitMap(board, 16, 16, format, displayable).?;
    try testing.expect(Held.free(board));
    const front = base(rb).AllocBitMap(board, 16, 16, format, displayable).?;
    try testing.expect(base(rb).AllocBitMap(board, 0, 4, format, 0) == null);
    try testing.expect(base(rb).AllocBitMap(board, 4, 4, 99, 0) == null);
    try testing.expect(base(rb).AllocBitMap(board, 4096, 4096, format, 0) == null);
    try testing.expect(Held.free(board));
    var pixels: [64]u8 = undefined;
    var described = rtg.RtgBitMap{ .pixels = &pixels, .width = 4, .height = 4, .format = .rgb565 };
    const attached = base(rb).AttachBitMap(board, &described).?;
    try testing.expect(Held.free(board));
    described.width = 0;
    try testing.expect(base(rb).AttachBitMap(board, &described) == null);
    try testing.expect(Held.free(board));

    // A show of one buffer, of bands, one refused by the library and one
    // by the driver.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, back));
    try testing.expectEqual(@as(u32, 2), Held.seen);
    try testing.expect(Held.free(board));
    const two = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = front, .line = 6, .origin = 6 } };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, &two, two.len));
    try testing.expectEqual(@as(u32, 3), Held.seen);
    try testing.expect(Held.free(board));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_DISPLAYABLE, base(rb).ShowBitMap(board, attached));
    try testing.expectEqual(@as(u32, 3), Held.seen);
    try testing.expect(Held.free(board));
    const out_of_order = [_]rtg.RtgBand{ .{ .bitmap = back, .line = 2 }, .{ .bitmap = front, .line = 6, .origin = 6 } };
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).ShowBoard(board, 0, &out_of_order, out_of_order.len));
    try testing.expect(Held.free(board));
    fk.show_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, base(rb).ShowBitMap(board, front));
    try testing.expectEqual(@as(u32, 4), Held.seen);
    try testing.expect(Held.free(board));

    // A buffer still shown is refused, one not shown given back.
    base(rb).FreeBitMap(front);
    try testing.expect(front.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);
    try testing.expect(Held.free(board));
    base(rb).FreeBitMap(attached);
    try testing.expect(Held.free(board));

    // What the display memory has free is read under it as well.
    _ = freeOf(rb, board);
    try testing.expect(Held.free(board));

    // Another mode refused, and what was shown asked for again: both
    // under the lock.
    fk.show_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, base(rb).ShowBoard(board, wide_mode, null, 0));
    try testing.expectEqual(@as(u32, 6), Held.seen);
    try testing.expect(Held.free(board));

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    try testing.expectEqual(@as(u32, 7), Held.seen);
    // The driver never worked without it.
    try testing.expectEqual(@as(u32, 0), Held.missed);
    base(rb).FreeBitMap(front);
    base(rb).FreeBitMap(back);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "the picture the firmware lit is the last board of the walk" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);

    // A device that says it is the firmware's framebuffer, of a chip the
    // fake is made to take: a driver of the tests' own, by its bus.
    const st = sdk.expansion.systemtags;
    const lit_tags = [_]TagItem{
        .{ .tag = st.PART_Chip, .data = st.CHIP_UEFI_FB },
        .{ .tag = st.PART_Bus, .data = fake.bus },
        .{ .tag = st.PART_Address, .data = 0x8000_0000 },
        .{},
    };
    const Lit = struct {
        const board_ops = rtg.RtgBoardOps{};
        fn attach(driver: *rtg.RtgDriver, device: *rtg.RtgDevice, _: ?[*]const TagItem) callconv(.c) i32 {
            _ = driver.rtg_base.CreateBoard(driver, device, &.{ .ops = &board_ops }) orelse return rtg.errors.RTGERR_NO_MEMORY;
            return rtg.errors.RTGERR_OK;
        }
        const ops = rtg.RtgDriverOps{ .attach = &attach };
        const matches = [_]rtg.RtgMatch{ .{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = st.CHIP_UEFI_FB }, .{} };
        const spec = rtg.RtgDriverSpec{ .name = "lit", .kind = rtg.drivers.RTGDT_BOARD, .matches = &matches, .ops = &ops };
    };
    const lit = driverBase(rb).AddRtgDriver(&Lit.spec, null).?;
    const device = driverBase(rb).AddRtgDevice(&lit_tags).?;
    try testing.expect(device.flags & rtg.drivers.RTGDVF_FIRMWARE != 0);
    // It lies behind no function on PCI: the host has none.
    try testing.expect(device.behind == null);
    const firmware = base(rb).NextBoard(null).?;
    try testing.expectEqualStrings("lit.0", std.mem.span(firmware.node.name.?));
    try testing.expect(firmware.info.flags & rtg.boards.RTGBF_FIRMWARE != 0);

    // A board made after it stands before it: the machine's display.
    const board = try makeBoard(rb);
    try testing.expectEqual(board, base(rb).NextBoard(null).?);
    try testing.expectEqual(firmware, base(rb).NextBoard(board).?);
    try testing.expect(base(rb).NextBoard(firmware) == null);
    try testing.expect(board.info.flags & rtg.boards.RTGBF_FIRMWARE == 0);
    var listed: [4]rtg.RtgDeviceInfo = undefined;
    try testing.expectEqual(@as(u32, 2), base(rb).GetRtgDevices(&listed, listed.len));
    try testing.expect(listed[0].flags & rtg.drivers.RTGDVF_FIRMWARE != 0);
    try testing.expectEqualStrings("lit", std.mem.sliceTo(&listed[0].driver, 0));

    driverBase(rb).DeleteBoard(firmware);
    driverBase(rb).RemRtgDevice(device);
    try testing.expect(driverBase(rb).RemRtgDriver(lit));
    _ = fk;
    try tearDown(rb);
}

test "info and stats: as much as the caller has room for, whole fields" {
    const rb = try setUp();
    defer kexec.deinit();
    const board = try makeBoard(rb);

    var bytes: [@sizeOf(rtg.RtgBoardInfo) + 8]u8 align(@alignOf(rtg.RtgBoardInfo)) = undefined;
    @memset(&bytes, 0xA5);
    const info: *rtg.RtgBoardInfo = @ptrCast(@alignCast(&bytes));
    // Nothing asked for is nothing written.
    try testing.expectEqual(@as(u32, 0), base(rb).GetBoardInfo(board, info, 0));
    try testing.expectEqual(@as(u8, 0xA5), bytes[0]);
    // A short structure gets what fits, and nothing past it.
    const short = @offsetOf(rtg.RtgBoardInfo, "modes");
    try testing.expectEqual(@as(u32, short), base(rb).GetBoardInfo(board, info, short));
    try testing.expectEqual(@as(u8, 0xA5), bytes[short]);
    // A longer one gets the whole structure and no more.
    const whole = @sizeOf(rtg.RtgBoardInfo);
    try testing.expectEqual(@as(u32, whole), base(rb).GetBoardInfo(board, info, whole + 8));
    try testing.expectEqual(@as(u8, 0xA5), bytes[whole]);

    // The driver's counters, and the library's beside them.
    const fk = fakeOf(rb);
    const picture = base(rb).AllocBitMap(board, 16, 8, @intFromEnum(rtg.PixelFormat.rgb565), 0).?;
    var stats: rtg.RtgBoardStats = .{};
    try testing.expectEqual(@as(u32, @sizeOf(rtg.RtgBoardStats)), base(rb).GetBoardStats(board, &stats, @sizeOf(rtg.RtgBoardStats)));
    const before = stats.refreshes;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(picture, null));
    _ = base(rb).GetBoardStats(board, &stats, @sizeOf(rtg.RtgBoardStats));
    try testing.expectEqual(fk.log.refreshed, stats.refreshes);
    try testing.expectEqual(before + 1, stats.refreshes);
    base(rb).FreeBitMap(picture);

    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "pixels and a colour laid over a buffer: cut down, the picture moved with the cut" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const bitmap = base(rb).AllocBitMap(board, 16, 8, format, 0).?;

    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expect(info.caps & rtg.boards.RTGBC_BLEND_PIXELS != 0);
    try testing.expect(info.caps & rtg.boards.RTGBC_BLEND_RECT != 0);
    try testing.expect(info.caps & rtg.boards.RTGBC_SCALE_PIXELS != 0);

    // A picture of four columns: white fully covering, half covering, and
    // not covering at all.
    const picture = [4]u32{ 0xFFFF_FFFF, 0x80FF_FFFF, 0x0000_0000, 0xFFFF_FFFF };
    const pixels = rtg.RtgPixels{ .pixels = @ptrCast(&picture), .pitch = 16, .format = .bgra32 };
    // Off the left by one: the driver gets the rest, and the picture's
    // corner moves one along with it.
    const area = rtg.RtgRect{ .x = -1, .y = 0, .width = 4, .height = 1 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).BlendPixels(bitmap, &area, &pixels, 255));
    try testing.expectEqual(@as(i32, 0), fk.log.last_rect.x);
    try testing.expectEqual(@as(i32, 3), fk.log.last_rect.width);
    try testing.expectEqual(@as(i32, 1), fk.log.last_pixels.x);
    const row: [*]u16 = @ptrCast(@alignCast(rowOf(bitmap, 0)));
    try testing.expectEqual(@as(u16, 0x8410), row[0]);
    try testing.expectEqual(@as(u16, 0), row[1]);
    try testing.expectEqual(@as(u16, 0xFFFF), row[2]);
    // An alpha above the top is the top.
    _ = base(rb).BlendPixels(bitmap, &area, &pixels, 1000);
    try testing.expectEqual(@as(u32, 255), fk.log.last_alpha);
    // No picture is a bad argument; nothing inside is no work.
    const none = rtg.RtgPixels{};
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).BlendPixels(bitmap, &area, &none, 255));
    const blends = fk.log.blends;
    const outside = rtg.RtgRect{ .x = 100, .y = 0, .width = 4, .height = 1 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).BlendPixels(bitmap, &outside, &pixels, 255));
    try testing.expectEqual(blends, fk.log.blends);

    // A colour by its alpha, cut to the buffer.
    const plate = rtg.RtgRect{ .x = 14, .y = 6, .width = 8, .height = 8 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).BlendRect(bitmap, &plate, 0xFF00_00FF));
    try testing.expectEqual(@as(i32, 2), fk.log.last_rect.width);
    try testing.expectEqual(@as(i32, 2), fk.log.last_rect.height);
    try testing.expectEqual(@as(u16, 0x001F), @as([*]u16, @ptrCast(@alignCast(rowOf(bitmap, 7))))[15]);

    // A scale is not cut: one over the edge is not the board's to try.
    const scales = fk.log.scales;
    const over_edge = rtg.RtgRect{ .x = 8, .y = 0, .width = 16, .height = 2 };
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).ScalePixels(bitmap, &over_edge, &pixels, 4, 1));
    try testing.expectEqual(scales, fk.log.scales);
    const inside = rtg.RtgRect{ .x = 0, .y = 0, .width = 8, .height = 2 };
    _ = base(rb).ScalePixels(bitmap, &inside, &pixels, 4, 1);
    try testing.expectEqual(scales + 1, fk.log.scales);
    try testing.expectEqual(@as(u32, 4), fk.log.last_scale_width);
    try testing.expectEqual(@as(u32, 1), fk.log.last_scale_height);

    base(rb).FreeBitMap(bitmap);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a board with no engine says so, and the library does not draw" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    fk.without_engine = true;
    const board = try makeBoard(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const bitmap = base(rb).AllocBitMap(board, 8, 8, format, 0).?;

    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u32, 0), info.caps & rtg.boards.RTGBC_FILL_RECT);

    const area = rtg.RtgRect{ .width = 4, .height = 4 };
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).FillRect(bitmap, &area, 0xFFFF));
    const copy = rtg.RtgCopy{ .width = 4, .height = 4 };
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).CopyRect(bitmap, bitmap, &copy));
    const shape = rtg.RtgTemplate{ .bits = @ptrCast("x"), .pitch = 1 };
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).BlitTemplate(bitmap, &area, &shape));
    const picture = [1]u32{0xFFFF_FFFF};
    const pixels = rtg.RtgPixels{ .pixels = @ptrCast(&picture), .pitch = 4 };
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).BlendPixels(bitmap, &area, &pixels, 255));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).BlendRect(bitmap, &area, 0xFFFF_FFFF));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).ScalePixels(bitmap, &area, &pixels, 1, 1));
    // Nothing was written, because nothing drew.
    const row: [*]u16 = @ptrCast(@alignCast(rowOf(bitmap, 0)));
    try testing.expectEqual(@as(u16, 0), row[0]);

    base(rb).FreeBitMap(bitmap);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a display with a picture of its own: the bands composed, what was written delivered as the display's rectangle" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeComposed(rb, 16, 12, 0);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;

    // Its driver wrote neither bands nor a pointer nor an overlay, and
    // the board has all three.
    const caps = infoOf(rb, board).caps;
    try testing.expect(caps & rtg.boards.RTGBC_BANDS != 0);
    try testing.expect(caps & rtg.boards.RTGBC_POINTER != 0 and caps & rtg.boards.RTGBC_OVERLAY != 0);
    try testing.expect(caps & rtg.boards.RTGBC_REFRESH != 0);

    const back = base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    const front = base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    const row = base(rb).AllocBitMap(board, 16, 1, format, displayable).?;
    paint(back, 1);
    paint(front, 2);
    paint(row, 3);

    // One buffer: not read direct, and delivered whole while the driver
    // is asked.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, back));
    try testing.expectEqual(@as(u32, 0), fk.log.last_flags & rtg.boards.RTGSHOW_DIRECT);
    try testing.expectEqual(@as(u32, 1), fk.log.updates);
    try testing.expectEqual(rtg.RtgRect{ .width = 16, .height = 12 }, fk.log.last_update);
    try testing.expect(seesOnly(board, 1));

    // Two in bands: each line from the band that covers it, the buffer's
    // row that far below the band's origin.
    const bands = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = front, .line = 5, .origin = 5 } };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, &bands, bands.len));
    try testing.expectEqual(painted(1, 3, 4), onGlass(board, 3, 4));
    try testing.expectEqual(painted(2, 3, 0), onGlass(board, 3, 5));
    try testing.expectEqual(painted(2, 15, 6), onGlass(board, 15, 11));

    // What is written into a band's buffer is delivered as the display's
    // rectangle: its lines, not the buffer's rows - and only that.
    const updates = fk.log.updates;
    poke(front, 3, 2, white);
    poke(front, 9, 2, white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(front, &.{ .x = 3, .y = 2, .width = 3, .height = 1 }));
    try testing.expectEqual(updates + 1, fk.log.updates);
    try testing.expectEqual(rtg.RtgRect{ .x = 3, .y = 7, .width = 3, .height = 1 }, fk.log.last_update);
    try testing.expectEqual(white, onGlass(board, 3, 7));
    try testing.expectEqual(painted(2, 9, 2), onGlass(board, 9, 7));
    // The driver heard of the buffer's own rectangle too.
    try testing.expectEqual(rtg.RtgRect{ .x = 3, .y = 2, .width = 3, .height = 1 }, fk.log.last_refresh);

    // Rows no band shows are handed on and delivered nowhere: below what
    // the band shows, and under the band over them.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(front, &.{ .x = 0, .y = 9, .width = 16, .height = 2 }));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(back, &.{ .x = 0, .y = 6, .width = 16, .height = 3 }));
    try testing.expectEqual(updates + 1, fk.log.updates);
    // A rectangle across the edge of a band: the lines the band shows.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(back, &.{ .x = 2, .y = 3, .width = 4, .height = 6 }));
    try testing.expectEqual(rtg.RtgRect{ .x = 2, .y = 3, .width = 4, .height = 2 }, fk.log.last_update);

    // A band that repeats one row: every line of it shows the row, and
    // the row written is all its lines.
    const repeating = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = row, .line = 8, .origin = 8, .flags = rtg.RTGBANDF_REPEAT } };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, &repeating, repeating.len));
    try testing.expectEqual(painted(1, 4, 7), onGlass(board, 4, 7));
    try testing.expectEqual(painted(3, 4, 0), onGlass(board, 4, 8));
    try testing.expectEqual(painted(3, 4, 0), onGlass(board, 4, 11));
    poke(row, 2, 0, white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(row, &.{ .x = 2, .y = 0, .width = 2, .height = 1 }));
    try testing.expectEqual(rtg.RtgRect{ .x = 2, .y = 8, .width = 2, .height = 4 }, fk.log.last_update);
    try testing.expectEqual(white, onGlass(board, 2, 10));

    // A buffer no band shows: its driver hears of it, the display not.
    const refreshed = fk.log.refreshed;
    const shown_updates = fk.log.updates;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(front, null));
    try testing.expectEqual(refreshed + 1, fk.log.refreshed);
    try testing.expectEqual(shown_updates, fk.log.updates);

    // A delivery the driver could not make is what the hand-on answers.
    fk.update_answer = rtg.errors.RTGERR_NO_DISPLAY;
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, base(rb).RefreshRect(back, null));
    // And a show that could not be delivered changes nothing: the bands
    // before are the library's still.
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, base(rb).ShowBitMap(board, front));
    try testing.expectEqual(row, base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(front.flags & rtg.bitmaps.RTGBMF_SHOWING == 0);
    fk.update_answer = rtg.errors.RTGERR_OK;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(back, null));
    try testing.expectEqual(painted(3, 5, 0), onGlass(board, 5, 9));

    // Nothing shown: nothing is delivered, and what is composed is black.
    const before_nothing = fk.log.updates;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, null, 0));
    try testing.expectEqual(before_nothing, fk.log.updates);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(back, null));
    try testing.expectEqual(before_nothing, fk.log.updates);
    var fetched: [4]u16 = .{ 7, 7, 7, 7 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, driverBase(rb).ComposeLines(board, &.{ .x = 6, .y = 6, .width = 2, .height = 2 }, @ptrCast(&fetched), 4));
    try testing.expectEqual([4]u16{ 0, 0, 0, 0 }, fetched);

    base(rb).FreeBitMap(row);
    base(rb).FreeBitMap(front);
    base(rb).FreeBitMap(back);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "the library's pointer: laid over the picture at every edge, moved, changed and hidden, the buffer never touched" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeComposed(rb, 16, 12, 0);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const picture = base(rb).AllocBitMap(board, 16, 12, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    paint(picture, 1);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, picture));

    // Three by two: red, clear, green; blue, clear, blue.
    var pixels = [_]u32{ rgba(0xFF0000FF), rgba(0x12345600), rgba(0x00FF00FF), rgba(0x0000FFFF), rgba(0x0000FF7F), rgba(0x0000FFFF) };
    const image = rtg.Surface{ .pixels = @ptrCast(&pixels), .width = 3, .height = 2, .pitch = 12, .format = .rgba32 };

    // An image, and a place: nothing is seen, and nothing delivered,
    // until the pointer is shown.
    var updates = fk.log.updates;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, &image, 0, 0));
    base(rb).MoveBoardPointer(board, 5, 4);
    try testing.expectEqual(updates, fk.log.updates);
    try testing.expect(seesOnly(board, 1));
    // The driver was asked for none of it.
    try testing.expectEqual(@as(u32, 0), fk.log.pointer_sets + fk.log.pointer_moves);

    // Shown: its rectangle delivered, the picture through its clear
    // pixels.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoardPointer(board, true));
    try testing.expect(infoOf(rb, board).flags & rtg.boards.RTGBF_POINTER != 0);
    try testing.expectEqual(updates + 1, fk.log.updates);
    try testing.expectEqual(rtg.RtgRect{ .x = 5, .y = 4, .width = 3, .height = 2 }, fk.log.last_update);
    try testing.expectEqual(red, onGlass(board, 5, 4));
    try testing.expectEqual(painted(1, 6, 4), onGlass(board, 6, 4));
    try testing.expectEqual(green, onGlass(board, 7, 4));
    try testing.expectEqual(blue, onGlass(board, 5, 5));
    try testing.expectEqual(painted(1, 6, 5), onGlass(board, 6, 5));
    try testing.expectEqual(painted(1, 8, 4), onGlass(board, 8, 4));

    // A short move: where it was and where it is as one rectangle, the
    // picture back where it left.
    updates = fk.log.updates;
    base(rb).MoveBoardPointer(board, 6, 4);
    try testing.expectEqual(updates + 1, fk.log.updates);
    try testing.expectEqual(rtg.RtgRect{ .x = 5, .y = 4, .width = 4, .height = 2 }, fk.log.last_update);
    try testing.expectEqual(painted(1, 5, 4), onGlass(board, 5, 4));
    try testing.expectEqual(red, onGlass(board, 6, 4));
    // The same place again is no move, and a long one is two rectangles.
    base(rb).MoveBoardPointer(board, 6, 4);
    try testing.expectEqual(updates + 1, fk.log.updates);
    base(rb).MoveBoardPointer(board, 12, 9);
    try testing.expectEqual(updates + 3, fk.log.updates);
    try testing.expectEqual(painted(1, 6, 4), onGlass(board, 6, 4));
    try testing.expectEqual(red, onGlass(board, 12, 9));

    // Past the top left: the part of the image that is on the picture.
    base(rb).MoveBoardPointer(board, -1, -1);
    try testing.expectEqual(rtg.RtgRect{ .x = 0, .y = 0, .width = 2, .height = 1 }, fk.log.last_update);
    try testing.expectEqual(painted(1, 0, 0), onGlass(board, 0, 0));
    try testing.expectEqual(blue, onGlass(board, 1, 0));
    try testing.expectEqual(painted(1, 12, 9), onGlass(board, 12, 9));
    // The bottom right corner: its first pixel alone.
    base(rb).MoveBoardPointer(board, 15, 11);
    try testing.expectEqual(red, onGlass(board, 15, 11));
    try testing.expectEqual(painted(1, 14, 11), onGlass(board, 14, 11));
    try testing.expectEqual(painted(1, 1, 0), onGlass(board, 1, 0));
    // Off the picture altogether, as far as a place goes: nothing of it.
    base(rb).MoveBoardPointer(board, std.math.maxInt(i32), std.math.minInt(i32));
    try testing.expect(seesOnly(board, 1));
    base(rb).MoveBoardPointer(board, std.math.minInt(i32), std.math.maxInt(i32));
    try testing.expect(seesOnly(board, 1));

    // What is drawn under it is delivered with the pointer over it.
    base(rb).MoveBoardPointer(board, 2, 2);
    poke(picture, 2, 2, white);
    poke(picture, 3, 2, white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(picture, &.{ .x = 2, .y = 2, .width = 2, .height = 1 }));
    try testing.expectEqual(red, onGlass(board, 2, 2));
    try testing.expectEqual(white, onGlass(board, 3, 2));

    // Another image while it is shown: the new one where the old was, the
    // old one's rectangle put right.
    var block = [_]u32{ rgba(0xFFFFFFFF), rgba(0xFFFFFFFF) };
    const small = rtg.Surface{ .pixels = @ptrCast(&block), .width = 1, .height = 2, .pitch = 4, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, &small, 0, 1));
    try testing.expectEqual(white, onGlass(board, 2, 1));
    try testing.expectEqual(white, onGlass(board, 2, 2));
    try testing.expectEqual(painted(1, 4, 2), onGlass(board, 4, 2));
    try testing.expectEqual(painted(1, 2, 3), onGlass(board, 2, 3));

    // Hidden, and taken away: the picture as it was drawn. The buffer
    // itself never held the pointer.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoardPointer(board, false));
    try testing.expectEqual(painted(1, 2, 1), onGlass(board, 2, 1));
    try testing.expectEqual(white, onGlass(board, 2, 2));
    poke(picture, 2, 2, painted(1, 2, 2));
    poke(picture, 3, 2, painted(1, 3, 2));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(picture, null));
    try testing.expect(seesOnly(board, 1));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoardPointer(board, true));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, null, 0, 0));
    try testing.expect(board.pointer == null);
    try testing.expect(seesOnly(board, 1));

    // An image still set when the board goes is freed with it.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, &image, 0, 0));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(picture);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "the library's overlay: under the pointer, following it, placed on its own, in every band" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeComposed(rb, 16, 12, 0);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    const back = base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    const front = base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    paint(back, 1);
    paint(front, 2);
    const bands = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = front, .line = 6, .origin = 6 } };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, &bands, bands.len));

    // A pointer of one red pixel, and an overlay three by three, green,
    // whose point is its middle.
    var dot = [_]u32{rgba(0xFF0000FF)};
    const pointer = rtg.Surface{ .pixels = @ptrCast(&dot), .width = 1, .height = 1, .pitch = 4, .format = .rgba32 };
    var block: [9]u32 = @splat(rgba(0x00FF00FF));
    const icon = rtg.Surface{ .pixels = @ptrCast(&block), .width = 3, .height = 3, .pitch = 12, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, &pointer, 0, 0));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoardPointer(board, true));
    base(rb).MoveBoardPointer(board, 8, 6);

    // The overlay comes up around the pointer's point, across the two
    // bands, the pointer over it.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardOverlay(board, &icon, 1, 1));
    try testing.expectEqual(@as(u32, 0), fk.log.overlay_sets + fk.log.overlay_moves);
    try testing.expectEqual(green, onGlass(board, 7, 5));
    try testing.expectEqual(green, onGlass(board, 9, 7));
    try testing.expectEqual(red, onGlass(board, 8, 6));
    try testing.expectEqual(painted(1, 6, 5), onGlass(board, 6, 5));
    try testing.expectEqual(painted(2, 10, 1), onGlass(board, 10, 7));

    // It follows the pointer, and the picture is back where both were.
    base(rb).MoveBoardPointer(board, 2, 2);
    try testing.expectEqual(painted(1, 7, 5), onGlass(board, 7, 5));
    try testing.expectEqual(painted(2, 8, 0), onGlass(board, 8, 6));
    try testing.expectEqual(green, onGlass(board, 1, 1));
    try testing.expectEqual(red, onGlass(board, 2, 2));
    try testing.expectEqual(green, onGlass(board, 3, 3));

    // Put somewhere of its own - half off the right edge - it stays
    // there, and the pointer goes on alone.
    base(rb).MoveBoardOverlay(board, 15, 9);
    try testing.expectEqual(painted(1, 1, 1), onGlass(board, 1, 1));
    try testing.expectEqual(red, onGlass(board, 2, 2));
    try testing.expectEqual(green, onGlass(board, 14, 8));
    try testing.expectEqual(green, onGlass(board, 15, 10));
    base(rb).MoveBoardPointer(board, 0, 0);
    try testing.expectEqual(red, onGlass(board, 0, 0));
    try testing.expectEqual(green, onGlass(board, 14, 8));
    try testing.expectEqual(@as(i32, 15), board.overlay_x);

    // It is seen whether the pointer is or not, and goes with null.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoardPointer(board, false));
    try testing.expectEqual(painted(1, 0, 0), onGlass(board, 0, 0));
    try testing.expectEqual(green, onGlass(board, 15, 9));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardOverlay(board, null, 0, 0));
    try testing.expect(board.overlay == null);
    try testing.expectEqual(painted(2, 15, 3), onGlass(board, 15, 9));
    try testing.expectEqual(painted(2, 14, 2), onGlass(board, 14, 8));

    // An overlay still set when the board goes is freed with it.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardOverlay(board, &icon, 1, 1));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, null, 0));
    base(rb).FreeBitMap(front);
    base(rb).FreeBitMap(back);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "direct while plain: the display reads the buffer itself until something lies over the picture" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeComposed(rb, 16, 12, 1);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    const direct = rtg.boards.RTGSHOW_DIRECT;
    const back = base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    const front = base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    const row = base(rb).AllocBitMap(board, 16, 1, format, displayable).?;
    paint(back, 1);
    paint(front, 2);
    paint(row, 3);

    // One whole buffer: read by the display, nothing delivered - at the
    // show, and when it is drawn into.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, back));
    try testing.expect(fk.log.last_flags & direct != 0);
    try testing.expect(fake.instanceOf(board).direct);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(back, null));
    try testing.expectEqual(@as(u32, 0), fk.log.updates);
    try testing.expectEqual(@as(u32, 1), fk.log.refreshed);

    // An image alone changes nothing; shown, the board is shown again
    // with its own picture, the pointer in it.
    var dot = [_]u32{rgba(0xFF0000FF)};
    const pointer = rtg.Surface{ .pixels = @ptrCast(&dot), .width = 1, .height = 1, .pitch = 4, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, &pointer, 0, 0));
    base(rb).MoveBoardPointer(board, 4, 4);
    try testing.expectEqual(@as(u32, 1), fk.log.shown);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoardPointer(board, true));
    try testing.expectEqual(@as(u32, 2), fk.log.shown);
    try testing.expectEqual(@as(u32, 0), fk.log.last_flags & (direct | rtg.boards.RTGSHOW_MODE_CHANGED));
    try testing.expectEqual(back, fk.log.last_show_bitmap.?);
    try testing.expect(!fake.instanceOf(board).direct);
    try testing.expectEqual(red, onGlass(board, 4, 4));
    try testing.expectEqual(painted(1, 5, 4), onGlass(board, 5, 4));
    // From then on a move and a drawing are delivered.
    base(rb).MoveBoardPointer(board, 5, 4);
    try testing.expectEqual(red, onGlass(board, 5, 4));
    poke(back, 0, 0, white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(back, &.{ .width = 1, .height = 1 }));
    try testing.expectEqual(white, onGlass(board, 0, 0));
    poke(back, 0, 0, painted(1, 0, 0));

    // Hidden: plain again, and read by the display again.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoardPointer(board, false));
    try testing.expectEqual(@as(u32, 3), fk.log.shown);
    try testing.expect(fk.log.last_flags & direct != 0);
    const delivered = fk.log.updates;
    base(rb).MoveBoardPointer(board, 6, 6);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(back, null));
    try testing.expectEqual(delivered, fk.log.updates);

    // Another buffer shown stays direct; an overlay over it is not plain,
    // and neither are two bands, nor one that repeats a row.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, front));
    try testing.expect(fk.log.last_flags & direct != 0);
    var block: [4]u32 = @splat(rgba(0x00FF00FF));
    const icon = rtg.Surface{ .pixels = @ptrCast(&block), .width = 2, .height = 2, .pitch = 8, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardOverlay(board, &icon, 0, 0));
    try testing.expectEqual(@as(u32, 0), fk.log.last_flags & direct);
    try testing.expectEqual(green, onGlass(board, 7, 7));
    try testing.expectEqual(painted(2, 8, 8), onGlass(board, 8, 8));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardOverlay(board, null, 0, 0));
    try testing.expect(fk.log.last_flags & direct != 0);

    const bands = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = front, .line = 6, .origin = 6 } };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, &bands, bands.len));
    try testing.expectEqual(@as(u32, 0), fk.log.last_flags & direct);
    try testing.expectEqual(painted(2, 3, 0), onGlass(board, 3, 6));
    const repeating = [_]rtg.RtgBand{.{ .bitmap = row, .flags = rtg.RTGBANDF_REPEAT }};
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, &repeating, repeating.len));
    try testing.expectEqual(@as(u32, 0), fk.log.last_flags & direct);
    try testing.expectEqual(painted(3, 9, 0), onGlass(board, 9, 11));

    // A driver that will not show its own picture: the pointer is
    // refused with its answer, and the display reads the buffer as
    // before.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, back));
    try testing.expect(fk.log.last_flags & direct != 0);
    fk.show_answer = rtg.errors.RTGERR_NO_MEMORY;
    try testing.expectEqual(rtg.errors.RTGERR_NO_MEMORY, base(rb).ShowBoardPointer(board, true));
    try testing.expectEqual(@as(u32, 0), infoOf(rb, board).flags & rtg.boards.RTGBF_POINTER);
    try testing.expect(fake.instanceOf(board).direct);
    const untouched = fk.log.updates;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(back, null));
    try testing.expectEqual(untouched, fk.log.updates);
    // It works the next time.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoardPointer(board, true));
    try testing.expectEqual(red, onGlass(board, 6, 6));
    // One that will not go back to reading the buffer shows its own
    // picture still, without the pointer.
    fk.show_answer = rtg.errors.RTGERR_NO_DISPLAY;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoardPointer(board, false));
    try testing.expect(!fake.instanceOf(board).direct);
    try testing.expectEqual(painted(1, 6, 6), onGlass(board, 6, 6));

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(row);
    base(rb).FreeBitMap(front);
    base(rb).FreeBitMap(back);
    driverBase(rb).DeleteBoard(board);

    // A display that reads bands itself reads two of them, and a board
    // that composes nothing is always read direct.
    const many = try makeComposed(rb, 16, 12, rtg.RTG_MAX_BANDS);
    const upper = base(rb).AllocBitMap(many, 16, 12, format, displayable).?;
    const lower = base(rb).AllocBitMap(many, 16, 12, format, displayable).?;
    const two = [_]rtg.RtgBand{ .{ .bitmap = upper }, .{ .bitmap = lower, .line = 6, .origin = 6 } };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(many, 0, &two, two.len));
    try testing.expect(fk.log.last_flags & direct != 0);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(many, 0, null, 0));
    base(rb).FreeBitMap(lower);
    base(rb).FreeBitMap(upper);
    driverBase(rb).DeleteBoard(many);
    const plain = try makeDisplay(rb, 16, 12);
    const alone = base(rb).AllocBitMap(plain, 16, 12, format, displayable).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(plain, alone));
    try testing.expect(fk.log.last_flags & direct != 0);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(plain, null));
    base(rb).FreeBitMap(alone);
    driverBase(rb).DeleteBoard(plain);
    try tearDown(rb);
}

test "the compose lock: held around every show and every delivery, free after every call" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeComposed(rb, 16, 12, 1);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const picture = base(rb).AllocBitMap(board, 16, 12, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    Composing.seen_held = 0;
    Composing.missed = 0;
    fk.meanwhile = &Composing.look;
    fk.while_handed = &Composing.look;

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, picture));
    try testing.expect(Composing.free(board));
    var dot = [_]u32{rgba(0xFF0000FF)};
    const pointer = rtg.Surface{ .pixels = @ptrCast(&dot), .width = 1, .height = 1, .pitch = 4, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, &pointer, 0, 0));
    try testing.expect(Composing.free(board));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoardPointer(board, true));
    try testing.expect(Composing.free(board));
    base(rb).MoveBoardPointer(board, 3, 3);
    try testing.expect(Composing.free(board));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(picture, null));
    try testing.expect(Composing.free(board));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardOverlay(board, &pointer, 0, 0));
    base(rb).MoveBoardOverlay(board, 9, 9);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardOverlay(board, null, 0, 0));
    // Refused by the driver: the locks are free all the same.
    fk.show_answer = rtg.errors.RTGERR_NO_DISPLAY;
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, base(rb).ShowBitMap(board, picture));
    try testing.expect(Composing.free(board));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    try testing.expect(Composing.free(board));

    // The driver was asked under the lock every time: for its shows, its
    // refreshes and its deliveries.
    try testing.expect(Composing.seen_held > 8);
    try testing.expectEqual(@as(u32, 0), Composing.missed);

    fk.meanwhile = null;
    fk.while_handed = null;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, null, 0, 0));
    base(rb).FreeBitMap(picture);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a picture of four bytes a pixel is composed as one of two is; one of a bit a pixel is not" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    fk.composed = true;
    const board = fake.makeDisplay(fk, 8, 4, .bgra32) orelse return error.NoBoard;
    const picture = base(rb).AllocBitMap(board, 8, 4, @intFromEnum(rtg.PixelFormat.bgra32), rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const words: [*]u32 = @ptrCast(@alignCast(picture.pixels.?));
    for (0..4) |y| {
        for (0..8) |x| words[y * picture.pitch / 4 + x] = @intCast(0xFF00_0000 | y << 8 | x);
    }
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, picture));
    const instance = fake.instanceOf(board);
    try testing.expectEqual(@as(u32, 4), instance.picture_bytes);
    const out: [*]const u32 = @ptrCast(@alignCast(instance.picture.?));
    try testing.expectEqual(@as(u32, 0xFF00_0305), out[3 * 8 + 5]);

    // The pointer, in the board's own bytes: red is 0xFFFF0000 here.
    var dot = [_]u32{rgba(0xFF0000FF)};
    const pointer = rtg.Surface{ .pixels = @ptrCast(&dot), .width = 1, .height = 1, .pitch = 4, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, &pointer, 0, 0));
    base(rb).MoveBoardPointer(board, 7, 3);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoardPointer(board, true));
    try testing.expectEqual(@as(u32, 0xFFFF_0000), out[3 * 8 + 7]);
    try testing.expectEqual(@as(u32, 0xFF00_0306), out[3 * 8 + 6]);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, null, 0, 0));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(picture);
    driverBase(rb).DeleteBoard(board);

    // A bit a pixel: no picture is composed of that, and the show says
    // so - on a display that reads no buffer itself, every show.
    const mono = fake.makeDisplay(fk, 16, 4, .mono1) orelse return error.NoBoard;
    fk.composed = false;
    const bits = base(rb).AllocBitMap(mono, 16, 4, @intFromEnum(rtg.PixelFormat.mono1), rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_BAD_FORMAT, base(rb).ShowBitMap(mono, bits));
    try testing.expect(base(rb).BoardDisplayBitMap(mono) == null);
    base(rb).FreeBitMap(bits);
    driverBase(rb).DeleteBoard(mono);
    try tearDown(rb);
}

test "a band of another width: scaled by the widths as it is composed, both ways the same" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeComposed(rb, 16, 12, 0);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    try testing.expect(infoOf(rb, board).caps & rtg.boards.RTGBC_SCALE_BANDS != 0);

    // Half the width: every pixel twice across and on two lines, none
    // mixed.
    const half = base(rb).AllocBitMap(board, 8, 6, format, displayable).?;
    paint(half, 4);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, half));
    var y: u32 = 0;
    while (y < 12) : (y += 1) {
        var x: u32 = 0;
        while (x < 16) : (x += 1) try testing.expectEqual(painted(4, x / 2, y / 2), onGlass(board, x, y));
    }
    // One pixel written is the four that show it, delivered as that.
    poke(half, 3, 2, white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(half, &.{ .x = 3, .y = 2, .width = 1, .height = 1 }));
    try testing.expectEqual(rtg.RtgRect{ .x = 6, .y = 4, .width = 2, .height = 2 }, fk.log.last_update);
    try testing.expectEqual(white, onGlass(board, 6, 4));
    try testing.expectEqual(white, onGlass(board, 7, 5));
    try testing.expectEqual(painted(4, 4, 2), onGlass(board, 8, 4));
    try testing.expectEqual(painted(4, 3, 3), onGlass(board, 6, 6));
    poke(half, 3, 2, painted(4, 3, 2));

    // In a band under a buffer of the picture's size: its first row at
    // the band's origin, and the lines its rows do not reach black.
    const back = base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    paint(back, 1);
    const bands = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = half, .line = 4, .origin = 2 } };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, &bands, bands.len));
    try testing.expectEqual(painted(1, 3, 3), onGlass(board, 3, 3));
    try testing.expectEqual(painted(4, 2, 1), onGlass(board, 5, 4));
    try testing.expectEqual(painted(4, 7, 4), onGlass(board, 15, 11));
    const lower = [_]rtg.RtgBand{.{ .bitmap = half }};
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, &lower, lower.len));
    base(rb).FreeBitMap(back);

    // One and a half times the width: neighbours mixed. The left half
    // red and the right half green stay so, and what is written is
    // delivered with the pixels beside it.
    const wide = base(rb).AllocBitMap(board, 24, 18, format, displayable).?;
    flood(wide, red);
    y = 0;
    while (y < 18) : (y += 1) {
        var x: u32 = 12;
        while (x < 24) : (x += 1) poke(wide, x, y, green);
    }
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, wide));
    y = 0;
    while (y < 12) : (y += 1) {
        try testing.expectEqual(red, onGlass(board, 0, y));
        try testing.expectEqual(red, onGlass(board, 6, y));
        try testing.expectEqual(green, onGlass(board, 9, y));
        try testing.expectEqual(green, onGlass(board, 15, y));
    }
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(wide, &.{ .x = 12, .y = 9, .width = 3, .height = 3 }));
    const told = fk.log.last_update;
    try testing.expect(told.x <= 8 and told.x + told.width >= 10);
    try testing.expect(told.y <= 6 and told.y + told.height >= 8);
    try testing.expect(told.width <= 5 and told.height <= 5);

    // A buffer of the picture's width and fewer rows: the lines past its
    // last are black.
    const short = base(rb).AllocBitMap(board, 16, 5, format, displayable).?;
    paint(short, 6);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, short));
    try testing.expectEqual(painted(6, 9, 4), onGlass(board, 9, 4));
    try testing.expectEqual(@as(u16, 0), onGlass(board, 9, 5));
    try testing.expectEqual(@as(u16, 0), onGlass(board, 15, 11));

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(short);
    base(rb).FreeBitMap(wide);
    base(rb).FreeBitMap(half);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a band of another size is never read direct, but by planes that scale; a board with neither refuses it" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    const direct = rtg.boards.RTGSHOW_DIRECT;

    // A display that reads one whole buffer itself: one of its size is
    // read, a smaller one is the library's picture.
    const board = try makeComposed(rb, 16, 12, 1);
    const whole = base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    const half = base(rb).AllocBitMap(board, 8, 6, format, displayable).?;
    paint(whole, 1);
    paint(half, 2);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, whole));
    try testing.expect(fk.log.last_flags & direct != 0);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, half));
    try testing.expectEqual(@as(u32, 0), fk.log.last_flags & direct);
    try testing.expectEqual(painted(2, 7, 5), onGlass(board, 15, 11));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, whole));
    try testing.expect(fk.log.last_flags & direct != 0);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(half);
    base(rb).FreeBitMap(whole);
    driverBase(rb).DeleteBoard(board);

    // Planes that scale: the driver is handed the band as it is.
    fk.scales = true;
    const planes = try makeDisplay(rb, 16, 12);
    fk.scales = false;
    try testing.expect(infoOf(rb, planes).caps & rtg.boards.RTGBC_SCALE_BANDS != 0);
    const small = base(rb).AllocBitMap(planes, 8, 6, format, displayable).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(planes, small));
    try testing.expect(fk.log.last_flags & direct != 0);
    try testing.expectEqual(small, fk.log.bands[0].bitmap);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(planes, null));
    base(rb).FreeBitMap(small);
    driverBase(rb).DeleteBoard(planes);

    // Neither: only a buffer of the mode's size.
    const fixed = try makeDisplay(rb, 16, 12);
    try testing.expectEqual(@as(u32, 0), infoOf(rb, fixed).caps & rtg.boards.RTGBC_SCALE_BANDS);
    const other = base(rb).AllocBitMap(fixed, 8, 6, format, displayable).?;
    const shown_before = fk.log.shown;
    try testing.expectEqual(rtg.errors.RTGERR_NOT_DISPLAYABLE, base(rb).ShowBitMap(fixed, other));
    try testing.expectEqual(shown_before, fk.log.shown);
    base(rb).FreeBitMap(other);
    driverBase(rb).DeleteBoard(fixed);
    try tearDown(rb);
}

test "a monitor changed for one without the board's mode: what was shown, scaled, in the mode the new one prefers" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    const wide_only = smallMonitor(smallTiming(64, 32, 8), null);
    const square_only = smallMonitor(smallTiming(32, 32, 8), null);
    fk.composed = true;
    const board = try makeConnector(rb, std.mem.sliceAsBytes(&wide_only), 0);
    fk.composed = false;
    const wide = base(rb).FindBoardMode(board, 64, 32, rtg.RTG_ANY, rtg.RTG_ANY);
    try testing.expect(wide != 0);

    // Two screens in bands: one red from the top, a blue one pulled down
    // to the middle.
    const back = base(rb).AllocBitMap(board, 64, 32, format, displayable).?;
    const front = base(rb).AllocBitMap(board, 64, 32, format, displayable).?;
    flood(back, red);
    flood(front, blue);
    const bands = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = front, .line = 16, .origin = 16 } };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, &bands, bands.len));
    try testing.expectEqual(wide, infoOf(rb, board).mode_id);
    const changes = infoOf(rb, board).changes;

    // A monitor of 32 by 32 alone: the board is in that mode, and shows
    // the same two half as large - the blue one from line 8, its 32 rows
    // on 16 lines, and nothing below them.
    fk.monitor_edid = std.mem.sliceAsBytes(&square_only);
    driverBase(rb).MonitorChanged(board);
    monitors.service(rb);
    const info = infoOf(rb, board);
    const square = base(rb).FindBoardMode(board, 32, 32, rtg.RTG_ANY, rtg.RTG_ANY);
    try testing.expect(square != 0 and square != wide);
    try testing.expectEqual(square, info.mode_id);
    try testing.expectEqual(@as(u32, 32), info.width);
    try testing.expect(info.changes != changes);
    try testing.expectEqual(rtg.boards.RTGSHOW_MODE_CHANGED, fk.log.last_flags);
    try testing.expectEqual(@as(u32, 2), fk.log.band_count);
    try testing.expectEqual(@as(u32, 8), fk.log.bands[1].line);
    try testing.expectEqual(@as(u32, 8), fk.log.bands[1].origin);
    try testing.expectEqual(front, base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(back.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);
    try testing.expectEqual(@as(u32, 32), fake.instanceOf(board).picture_width);
    for ([_]u32{ 0, 15, 31 }) |x| {
        try testing.expectEqual(red, onGlass(board, x, 0));
        try testing.expectEqual(red, onGlass(board, x, 7));
        try testing.expectEqual(blue, onGlass(board, x, 8));
        try testing.expectEqual(blue, onGlass(board, x, 23));
        try testing.expectEqual(@as(u16, 0), onGlass(board, x, 24));
        try testing.expectEqual(@as(u16, 0), onGlass(board, x, 31));
    }
    // What is drawn in the screen goes on being delivered, scaled.
    flood(front, green);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(front, null));
    try testing.expectEqual(green, onGlass(board, 20, 12));
    try testing.expectEqual(red, onGlass(board, 20, 4));

    // The first monitor back: its mode is the board's to be shown in
    // again, the buffers in it as they are.
    fk.monitor_edid = std.mem.sliceAsBytes(&wide_only);
    driverBase(rb).MonitorChanged(board);
    monitors.service(rb);
    try testing.expectEqual(wide, infoOf(rb, board).mode_id);
    try testing.expectEqual(@as(u32, 16), fk.log.bands[1].line);
    try testing.expectEqual(green, onGlass(board, 40, 16));
    try testing.expectEqual(red, onGlass(board, 40, 15));

    // A driver that cannot be put in the new monitor's mode leaves the
    // board in none, showing nothing.
    fk.monitor_edid = std.mem.sliceAsBytes(&square_only);
    fk.show_answer = rtg.errors.RTGERR_NO_DISPLAY;
    driverBase(rb).MonitorChanged(board);
    monitors.service(rb);
    try testing.expectEqual(@as(u32, 0), infoOf(rb, board).mode_id);
    try testing.expect(base(rb).BoardDisplayBitMap(board) == null);
    try testing.expect(back.flags & rtg.bitmaps.RTGBMF_SHOWING == 0);

    base(rb).FreeBitMap(front);
    base(rb).FreeBitMap(back);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a board with planes of its own: the library lays the pointer and the overlay for as long as it mirrors the picture" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    // Flipped, a cursor plane and an overlay plane, and hardware that
    // turns no axis: the library mirrors.
    fk.hardware = true;
    fk.mirror_axes = 0;
    const board = try makeFlipped(rb, 16, 12);
    fk.hardware = false;
    fk.mirror_axes = rtg.boards.RTGBC_MIRROR_X | rtg.boards.RTGBC_MIRROR_Y;
    const picture = base(rb).AllocBitMap(board, 16, 12, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    paint(picture, 1);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, picture));

    // Unturned, the pointer is the plane's: nothing of it in the picture.
    var dot = [_]u32{rgba(0xFF0000FF)};
    const pointer = rtg.Surface{ .pixels = @ptrCast(&dot), .width = 1, .height = 1, .pitch = 4, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, &pointer, 0, 0));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoardPointer(board, true));
    base(rb).MoveBoardPointer(board, 3, 2);
    flips.service(rb, board);
    try testing.expect(fk.log.pointer_image != null and fk.log.pointer_shown);
    try testing.expectEqual(@as(i32, 3), fk.log.pointer_left);
    try testing.expectEqual(painted(1, 3, 2), glassAt(board, 3, 2));

    // Mirrored by the library: the plane is given no image, and the
    // pointer is in the picture, where the display shows its place.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).MirrorBoard(board, true, false));
    try testing.expectEqual(@as(u32, 0), fk.log.mirrors);
    try testing.expect(fk.log.pointer_image == null and !fk.log.pointer_shown);
    flips.service(rb, board);
    try testing.expectEqual(red, glassAt(board, 12, 2));
    try testing.expectEqual(painted(1, 4, 2), glassAt(board, 11, 2));
    // A move is the library's, and the plane hears of none.
    const moves = fk.log.pointer_moves;
    base(rb).MoveBoardPointer(board, 5, 6);
    try testing.expectEqual(moves, fk.log.pointer_moves);
    flips.service(rb, board);
    try testing.expectEqual(red, glassAt(board, 10, 6));
    try testing.expectEqual(painted(1, 3, 2), glassAt(board, 12, 2));

    // Unturned again: the plane has the image, its place and is shown;
    // the picture has none.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).MirrorBoard(board, false, false));
    try testing.expect(fk.log.pointer_image != null and fk.log.pointer_shown);
    try testing.expectEqual(@as(i32, 5), fk.log.pointer_left);
    try testing.expectEqual(@as(i32, 6), fk.log.pointer_top);
    flips.service(rb, board);
    try testing.expect(glassIs(board, 1, &.{}));

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, null, 0, 0));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(picture);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a flipped board: the first picture with the mode, each next one made in the frame the display is not reading" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeFlipped(rb, 16, 12);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    const state = &boards.privateOf(board).compose.flip;

    // Its driver wrote neither bands nor a pointer nor an overlay.
    const caps = infoOf(rb, board).caps;
    try testing.expect(caps & rtg.boards.RTGBC_BANDS != 0 and caps & rtg.boards.RTGBC_REFRESH != 0);
    try testing.expect(caps & rtg.boards.RTGBC_POINTER != 0 and caps & rtg.boards.RTGBC_OVERLAY != 0);

    const back = base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    const front = base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    paint(back, 1);
    paint(front, 2);
    const free_before = freeOf(rb, board);

    // The first show puts the board in its mode: the driver is handed the
    // frame the display starts on, with the whole picture in it, and no
    // flip is made. The frames are not buffers of the board's.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, back));
    try testing.expectEqual(state.frames[0].?, fk.log.last_show_frame.?);
    try testing.expectEqual(@as(u32, 0), fk.log.last_flags & rtg.boards.RTGSHOW_DIRECT);
    try testing.expectEqual(@as(u32, 0), fk.log.flips);
    try testing.expect(state.frames[1] != null and state.frames[1] != state.frames[0]);
    try testing.expect(state.frames[0].?.pixels != back.pixels);
    try testing.expect(glassIs(board, 1, &.{}));
    try testing.expect(state.task != null);

    // Something drawn is noted, and no more: the display reads its frame
    // on. The board's task then makes the next picture in the other
    // frame - what was drawn, and all the first picture had, which that
    // frame never got - and the display is flipped to it.
    poke(back, 3, 2, white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(back, &.{ .x = 3, .y = 2, .width = 1, .height = 1 }));
    try testing.expectEqual(@as(u32, 0), fk.log.flips);
    try testing.expectEqual(painted(1, 3, 2), glassAt(board, 3, 2));
    flips.service(rb, board);
    try testing.expectEqual(@as(u32, 1), fk.log.flips);
    try testing.expectEqual(state.frames[1].?, fake.glassOf(board).?);
    try testing.expect(glassIs(board, 1, &.{.{ 3, 2, white }}));
    // The frame was handed on to the driver before the flip, the buffer
    // drawn in never.
    try testing.expectEqual(state.frames[1].?, fk.log.last_refresh_bitmap.?);

    // The next picture goes back into the first frame, which has not had
    // the drawing before: both are in it.
    poke(back, 9, 7, green);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(back, &.{ .x = 9, .y = 7, .width = 1, .height = 1 }));
    flips.service(rb, board);
    try testing.expectEqual(state.frames[0].?, fake.glassOf(board).?);
    try testing.expect(glassIs(board, 1, &.{ .{ 3, 2, white }, .{ 9, 7, green } }));
    // With nothing noted no picture is made.
    flips.service(rb, board);
    try testing.expectEqual(@as(u32, 2), fk.log.flips);

    // Bands: the show makes the picture itself, and returns with it on
    // the glass. What is written under a band is not noted.
    const bands = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = front, .line = 6, .origin = 6 } };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, &bands, bands.len));
    try testing.expectEqual(@as(u32, 3), fk.log.flips);
    try testing.expectEqual(white, glassAt(board, 3, 2));
    try testing.expectEqual(painted(2, 2, 0), glassAt(board, 2, 6));
    try testing.expectEqual(painted(2, 15, 5), glassAt(board, 15, 11));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(back, &.{ .x = 0, .y = 8, .width = 16, .height = 2 }));
    flips.service(rb, board);
    try testing.expectEqual(@as(u32, 3), fk.log.flips);

    // The library's pointer: where it is seen is noted, and the next
    // picture has it; a move, and the picture after has the place it
    // left put right - in both frames.
    var dot = [_]u32{rgba(0xFF0000FF)};
    const pointer = rtg.Surface{ .pixels = @ptrCast(&dot), .width = 1, .height = 1, .pitch = 4, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, &pointer, 0, 0));
    base(rb).MoveBoardPointer(board, 4, 4);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoardPointer(board, true));
    try testing.expectEqual(painted(1, 4, 4), glassAt(board, 4, 4));
    flips.service(rb, board);
    try testing.expectEqual(red, glassAt(board, 4, 4));
    base(rb).MoveBoardPointer(board, 10, 9);
    flips.service(rb, board);
    try testing.expectEqual(painted(1, 4, 4), glassAt(board, 4, 4));
    try testing.expectEqual(red, glassAt(board, 10, 9));
    base(rb).MoveBoardPointer(board, 11, 9);
    flips.service(rb, board);
    try testing.expectEqual(painted(1, 4, 4), glassAt(board, 4, 4));
    try testing.expectEqual(painted(2, 10, 3), glassAt(board, 10, 9));
    try testing.expectEqual(red, glassAt(board, 11, 9));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, null, 0, 0));
    flips.service(rb, board);

    // A flip the driver refuses: the display reads what it read, and the
    // next picture is made whole.
    const flips_before = fk.log.flips;
    const reading = fake.glassOf(board).?;
    poke(back, 0, 0, blue);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(back, &.{ .width = 1, .height = 1 }));
    fk.flip_answer = rtg.errors.RTGERR_IO;
    flips.service(rb, board);
    try testing.expectEqual(flips_before + 1, fk.log.flips);
    try testing.expectEqual(reading, fake.glassOf(board).?);
    fk.flip_answer = rtg.boards.RTGFLIP_TAKEN;
    flips.service(rb, board);
    try testing.expect(reading != fake.glassOf(board).?);
    try testing.expectEqual(blue, glassAt(board, 0, 0));
    try testing.expectEqual(white, glassAt(board, 3, 2));
    try testing.expectEqual(painted(2, 7, 2), glassAt(board, 7, 8));

    // And a show whose flip is refused changes nothing in the library:
    // the bands before are what it holds.
    fk.flip_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, base(rb).ShowBitMap(board, front));
    try testing.expectEqual(front, base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(back.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);
    fk.flip_answer = rtg.boards.RTGFLIP_TAKEN;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, front));
    try testing.expect(glassIs(board, 2, &.{}));
    try testing.expect(back.flags & rtg.bitmaps.RTGBMF_SHOWING == 0);

    // Nothing shown is a black picture, made and flipped to.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, null, 0));
    try testing.expectEqual(@as(u16, 0), glassAt(board, 8, 8));
    try testing.expectEqual(@as(u16, 0), glassAt(board, 0, 0));

    // This board's display memory is one block: its two frames are two
    // pictures out of it, and nothing else went.
    try testing.expectEqual(free_before - 2 * 12 * @as(usize, back.pitch), freeOf(rb, board));
    base(rb).FreeBitMap(front);
    base(rb).FreeBitMap(back);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a flipped board scales a band as one with a picture of its own does, and notes what was written scaled" {
    const rb = try setUp();
    defer kexec.deinit();
    const board = try makeFlipped(rb, 16, 12);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    try testing.expect(infoOf(rb, board).caps & rtg.boards.RTGBC_SCALE_BANDS != 0);
    const half = base(rb).AllocBitMap(board, 8, 6, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    paint(half, 4);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, half));
    var y: u32 = 0;
    while (y < 12) : (y += 1) {
        var x: u32 = 0;
        while (x < 16) : (x += 1) try testing.expectEqual(painted(4, x / 2, y / 2), glassAt(board, x, y));
    }
    // One pixel written: the four that show it are in the next picture.
    poke(half, 5, 1, white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(half, &.{ .x = 5, .y = 1, .width = 1, .height = 1 }));
    flips.service(rb, board);
    try testing.expectEqual(white, glassAt(board, 10, 2));
    try testing.expectEqual(white, glassAt(board, 11, 3));
    try testing.expectEqual(painted(4, 6, 1), glassAt(board, 12, 2));
    try testing.expectEqual(painted(4, 5, 2), glassAt(board, 10, 4));

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(half);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a flip is waited for: the frame read until then is not written before the display's next frame" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeFlipped(rb, 16, 12);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const picture = base(rb).AllocBitMap(board, 16, 12, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    paint(picture, 1);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, picture));

    // A driver that only tells the display: the library waits for the
    // frame itself, with both locks of the picture let go - the task
    // sleeps, and the frame that ends meanwhile wakes it.
    fk.flip_answer = rtg.errors.RTGERR_OK;
    fixture.frames_board = board;
    // The tests' switch has one task to go back to: the board's own is
    // taken off, and the pictures made by hand.
    flips.stopTask(rb, board);
    Sleep.install(&endOneFrame);
    defer Sleep.uninstall();
    // The board's driver says its frames: one was said.
    fake.endFrame(board);
    const ended = fk.log.frames_ended;
    poke(picture, 1, 1, white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(picture, &.{ .x = 1, .y = 1, .width = 1, .height = 1 }));
    flips.service(rb, board);
    try testing.expectEqual(@as(u32, 1), fk.log.flips);
    try testing.expect(Sleep.sleeps >= 1);
    try testing.expect(fk.log.frames_ended > ended);
    try testing.expectEqual(white, glassAt(board, 1, 1));
    try testing.expect(Composing.free(board));
    const flip_lock = &boards.privateOf(board).compose.flip.lock;
    try testing.expect(flip_lock.owner == null and flip_lock.nestCount() == 0);

    // A show waits the same way, before it returns.
    const sleeps = Sleep.sleeps;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, null, 0));
    try testing.expect(Sleep.sleeps > sleeps);
    try testing.expect(flip_lock.owner == null and flip_lock.nestCount() == 0);

    fk.flip_answer = rtg.boards.RTGFLIP_TAKEN;
    base(rb).FreeBitMap(picture);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a driver's flip runs with the flip lock and without the compose lock: a pointer moves while it waits" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeFlipped(rb, 16, 12);
    flips.stopTask(rb, board);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const picture = base(rb).AllocBitMap(board, 16, 12, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const next = base(rb).AllocBitMap(board, 16, 12, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    paint(picture, 1);
    paint(next, 2);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, picture));

    Flipping.flips_seen = 0;
    Flipping.compose_held = 0;
    Flipping.flip_lock_missed = 0;
    fk.while_flipping = &Flipping.look;
    // A picture made by the task's own work, and one made inside a show.
    poke(picture, 2, 2, white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(picture, &.{ .x = 2, .y = 2, .width = 1, .height = 1 }));
    flips.service(rb, board);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, next));
    fk.while_flipping = null;

    try testing.expect(Flipping.flips_seen >= 2);
    try testing.expectEqual(@as(u32, 0), Flipping.compose_held);
    try testing.expectEqual(@as(u32, 0), Flipping.flip_lock_missed);
    try testing.expect(Composing.free(board));
    try testing.expect(glassIs(board, 2, &.{}));

    base(rb).FreeBitMap(next);
    base(rb).FreeBitMap(picture);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "frames of a driver's own: asked for with the mode and after a flip refused; the same one twice is one frame" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;

    // Two of its own: the library makes its pictures in them, and takes
    // none of its own.
    fk.own_frames = .two;
    const board = try makeFlipped(rb, 16, 12);
    const instance = fake.instanceOf(board);
    const state = &boards.privateOf(board).compose.flip;
    const picture = base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    paint(picture, 1);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, picture));
    try testing.expectEqual(@as(u32, 1), fk.log.frames_asked);
    try testing.expect(!state.owned);
    try testing.expectEqual(&instance.frames[0], fake.glassOf(board).?);
    try testing.expect(glassIs(board, 1, &.{}));
    poke(picture, 2, 2, white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(picture, &.{ .x = 2, .y = 2, .width = 1, .height = 1 }));
    flips.service(rb, board);
    try testing.expectEqual(&instance.frames[1], fake.glassOf(board).?);
    try testing.expect(glassIs(board, 1, &.{.{ 2, 2, white }}));

    // A flip refused: the frames are asked for again - here the driver
    // goes over to one frame for both - and the next picture is whole.
    fk.own_frames = .one;
    fk.flip_answer = rtg.errors.RTGERR_IO;
    poke(picture, 5, 5, green);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(picture, &.{ .x = 5, .y = 5, .width = 1, .height = 1 }));
    flips.service(rb, board);
    try testing.expectEqual(@as(u32, 2), fk.log.frames_asked);
    try testing.expectEqual(state.frames[0].?, state.frames[1].?);
    fk.flip_answer = rtg.boards.RTGFLIP_TAKEN;
    flips.service(rb, board);
    try testing.expectEqual(&instance.frames[0], fake.glassOf(board).?);
    try testing.expect(glassIs(board, 1, &.{ .{ 2, 2, white }, .{ 5, 5, green } }));
    // One frame: what is drawn goes into the frame the display reads,
    // that rectangle alone.
    poke(picture, 7, 7, blue);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(picture, &.{ .x = 7, .y = 7, .width = 1, .height = 1 }));
    flips.service(rb, board);
    try testing.expectEqual(rtg.RtgRect{ .x = 7, .y = 7, .width = 1, .height = 1 }, fk.log.last_refresh);
    try testing.expect(glassIs(board, 1, &.{ .{ 2, 2, white }, .{ 5, 5, green }, .{ 7, 7, blue } }));

    fk.own_frames = .library;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(picture);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a buffer read in place of a frame: shown after another nothing was written in, until something is written in it" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    fk.direct_flip = true;
    const board = try makeFlipped(rb, 16, 12);
    fk.direct_flip = false;
    try testing.expect(infoOf(rb, board).flags & rtg.boards.RTGBF_DIRECT_FLIP != 0);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    const direct = rtg.boards.RTGSHOW_DIRECT;
    const state = &boards.privateOf(board).compose.flip;
    const one = base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    const other = base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    paint(one, 1);
    paint(other, 2);

    // The first picture is a frame's.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, one));
    try testing.expectEqual(state.frames[0].?, fake.glassOf(board).?);
    // The next buffer, shown in place of one nothing was written in: the
    // display is flipped to the buffer itself, handed on whole, and
    // nothing is copied.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, other));
    try testing.expect(fk.log.last_flags & direct != 0);
    try testing.expectEqual(other, fk.log.last_flip.?);
    try testing.expectEqual(other, fake.glassOf(board).?);
    try testing.expectEqual(other, fk.log.last_refresh_bitmap.?);
    try testing.expectEqual(rtg.RtgRect{ .width = 16, .height = 12 }, fk.log.last_refresh);
    try testing.expectEqual(@as(u32, 0), state.pictures);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, one));
    try testing.expectEqual(one, fake.glassOf(board).?);
    try testing.expectEqual(@as(u32, 2), state.direct_flips);

    // Something written in the buffer the display reads: handed on at
    // once, and the task takes the frames up again with a whole picture.
    poke(one, 4, 4, white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(one, &.{ .x = 4, .y = 4, .width = 1, .height = 1 }));
    try testing.expectEqual(one, fk.log.last_refresh_bitmap.?);
    try testing.expectEqual(rtg.RtgRect{ .x = 4, .y = 4, .width = 1, .height = 1 }, fk.log.last_refresh);
    flips.service(rb, board);
    try testing.expect(fake.glassOf(board).? == state.frames[0].? or fake.glassOf(board).? == state.frames[1].?);
    try testing.expect(glassIs(board, 1, &.{.{ 4, 4, white }}));
    // The buffer shown next takes the place of one that was written in:
    // a frame's again. The one after that, not: read as it is.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, other));
    try testing.expectEqual(@as(u32, 0), fk.log.last_flags & direct);
    try testing.expect(fake.glassOf(board).? != other);
    try testing.expect(glassIs(board, 2, &.{}));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, one));
    try testing.expectEqual(one, fake.glassOf(board).?);

    // The library's pointer over the picture: the board is shown frames,
    // the pointer in them, and stays so with it gone.
    var dot = [_]u32{rgba(0xFF0000FF)};
    const pointer = rtg.Surface{ .pixels = @ptrCast(&dot), .width = 1, .height = 1, .pitch = 4, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, &pointer, 0, 0));
    base(rb).MoveBoardPointer(board, 8, 8);
    try testing.expectEqual(one, fake.glassOf(board).?);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoardPointer(board, true));
    try testing.expect(fake.glassOf(board).? != one);
    try testing.expectEqual(red, glassAt(board, 8, 8));
    try testing.expectEqual(white, glassAt(board, 4, 4));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoardPointer(board, false));
    flips.service(rb, board);
    try testing.expect(fake.glassOf(board).? != one);
    try testing.expectEqual(painted(1, 8, 8), glassAt(board, 8, 8));
    // Two bands are never a buffer read direct.
    const bands = [_]rtg.RtgBand{ .{ .bitmap = one }, .{ .bitmap = other, .line = 6, .origin = 6 } };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, &bands, bands.len));
    try testing.expectEqual(@as(u32, 0), fk.log.last_flags & direct);
    try testing.expectEqual(painted(2, 3, 0), glassAt(board, 3, 6));

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, null, 0, 0));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, null, 0));
    base(rb).FreeBitMap(other);
    base(rb).FreeBitMap(one);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "bands a flipped board's display reads itself: handed over with the show while none is written in, made in frames once one is or where the driver refuses them" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    fk.direct_bands = 4;
    const board = try makeFlipped(rb, 16, 12);
    fk.direct_bands = null;
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    const direct = rtg.boards.RTGSHOW_DIRECT;
    const ok = rtg.errors.RTGERR_OK;
    const one = base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    const other = base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    paint(one, 1);
    paint(other, 2);

    // The first picture is a frame's.
    try testing.expectEqual(ok, base(rb).ShowBitMap(board, one));
    const flipped = fk.log.flips;
    // A screen pulled down over another: the bands handed over with the
    // show, no picture made and nothing flipped.
    const pulled = [_]rtg.RtgBand{ .{ .bitmap = one }, .{ .bitmap = other, .line = 6, .origin = 6 } };
    try testing.expectEqual(ok, base(rb).ShowBoard(board, 0, &pulled, pulled.len));
    try testing.expect(fk.log.last_flags & direct != 0);
    try testing.expectEqual(@as(u32, 2), fk.log.band_count);
    try testing.expectEqual(flipped, fk.log.flips);
    // Pulled further, nothing written in meanwhile: handed over again.
    const further = [_]rtg.RtgBand{ .{ .bitmap = one }, .{ .bitmap = other, .line = 8, .origin = 8 } };
    try testing.expectEqual(ok, base(rb).ShowBoard(board, 0, &further, further.len));
    try testing.expect(fk.log.last_flags & direct != 0);
    try testing.expectEqual(flipped, fk.log.flips);

    // Written in while the display reads it: the next picture made whole
    // in a frame and flipped to.
    poke(other, 3, 2, white);
    try testing.expectEqual(ok, base(rb).RefreshRect(other, &.{ .x = 3, .y = 2, .width = 1, .height = 1 }));
    flips.service(rb, board);
    try testing.expectEqual(flipped + 1, fk.log.flips);
    try testing.expect(fake.glassOf(board).? != one and fake.glassOf(board).? != other);
    try testing.expectEqual(painted(1, 3, 0), glassAt(board, 3, 0));
    try testing.expectEqual(painted(2, 3, 0), glassAt(board, 3, 8));
    try testing.expectEqual(white, glassAt(board, 3, 10));
    // A show right after it: made in a frame. The next, with nothing
    // written in since: read by the display again.
    try testing.expectEqual(ok, base(rb).ShowBoard(board, 0, &pulled, pulled.len));
    try testing.expectEqual(@as(u32, 0), fk.log.last_flags & direct);
    try testing.expectEqual(painted(2, 3, 0), glassAt(board, 3, 6));
    try testing.expectEqual(ok, base(rb).ShowBoard(board, 0, &further, further.len));
    try testing.expect(fk.log.last_flags & direct != 0);

    // Refused by the driver: asked again without the flag, and made in a
    // frame.
    const asked = fk.log.shown;
    fk.show_answer = rtg.errors.RTGERR_NOT_SUPPORTED;
    try testing.expectEqual(ok, base(rb).ShowBoard(board, 0, &pulled, pulled.len));
    try testing.expectEqual(asked + 2, fk.log.shown);
    try testing.expectEqual(@as(u32, 0), fk.log.last_flags & direct);
    try testing.expectEqual(painted(1, 3, 5), glassAt(board, 3, 5));
    try testing.expectEqual(painted(2, 3, 0), glassAt(board, 3, 6));

    try testing.expectEqual(ok, base(rb).ShowBoard(board, 0, null, 0));
    base(rb).FreeBitMap(other);
    base(rb).FreeBitMap(one);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a buffer the driver will not read in place of a frame is made in a frame" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    fk.direct_flip = true;
    const board = try makeFlipped(rb, 16, 12);
    fk.direct_flip = false;
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    const ok = rtg.errors.RTGERR_OK;
    const one = base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    const other = base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    paint(one, 1);
    paint(other, 2);
    try testing.expectEqual(ok, base(rb).ShowBitMap(board, one));
    // The flip to the buffer refused, the one to a frame taken.
    fk.flip_answer = rtg.errors.RTGERR_NOT_SUPPORTED;
    fk.while_flipping = &takeFlipsAgain;
    try testing.expectEqual(ok, base(rb).ShowBitMap(board, other));
    fk.while_flipping = null;
    try testing.expect(fake.glassOf(board).? != other);
    try testing.expect(glassIs(board, 2, &.{}));

    try testing.expectEqual(ok, base(rb).ShowBoard(board, 0, null, 0));
    base(rb).FreeBitMap(other);
    base(rb).FreeBitMap(one);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

/// A test driver's flip refused once and taken after: its answer
/// RTGERR_NOT_SUPPORTED is turned into RTGERR_BAD_ARG as the first is
/// refused, and that into RTGFLIP_TAKEN for the next.
fn takeFlipsAgain(board: *rtg.RtgBoard) void {
    const fk = fake.stateOf(board.driver.?);
    fk.flip_answer = switch (fk.flip_answer) {
        rtg.errors.RTGERR_NOT_SUPPORTED => rtg.errors.RTGERR_BAD_ARG,
        else => rtg.boards.RTGFLIP_TAKEN,
    };
}

test "the pointer's colours: a pixel of each format as every drawing call writes one" {
    const pointers = @import("pointer/setboardpointer.zig");
    const colour = pointers.Colour{ .red = 0x10, .green = 0x20, .blue = 0x30 };
    // Opaque, in graphics.library's own order: a pen of full coverage.
    const pen: u32 = 0xFF10_2030;
    const formats = [_]rtg.PixelFormat{ .rgba32, .bgra32, .rgb24, .bgr24, .rgb565, .argb1555, .gray8 };
    for (formats) |format| {
        try testing.expectEqual(kpens.packPen(format, pen).?, pointers.pack(format, colour));
    }
    // The 24- and 32-bit ones, as their bytes lie in memory: the word's
    // low byte first.
    try testing.expectEqual(@as(u32, 0xFF30_2010), pointers.pack(.rgba32, colour)); // r, g, b, a
    try testing.expectEqual(@as(u32, 0xFF10_2030), pointers.pack(.bgra32, colour)); // b, g, r, a
    try testing.expectEqual(@as(u32, 0x0030_2010), pointers.pack(.rgb24, colour)); // r, g, b
    try testing.expectEqual(@as(u32, 0x0010_2030), pointers.pack(.bgr24, colour)); // b, g, r
    // A format with no colour of its own packs to nothing.
    try testing.expectEqual(@as(u32, 0), pointers.pack(.indexed8, colour));
    try testing.expectEqual(@as(u32, 0), pointers.pack(.mono1, colour));
    try testing.expectEqual(@as(u32, 0), pointers.pack(@enumFromInt(99), colour));
}

test "a format's size: bits a pixel, bytes a row, nothing for a format that is none" {
    const rb = try setUp();
    defer kexec.deinit();
    const bits = [_]struct { format: rtg.PixelFormat, bits: u32 }{
        .{ .format = .rgba32, .bits = 32 },
        .{ .format = .bgra32, .bits = 32 },
        .{ .format = .rgb24, .bits = 24 },
        .{ .format = .bgr24, .bits = 24 },
        .{ .format = .rgb565, .bits = 16 },
        .{ .format = .argb1555, .bits = 16 },
        .{ .format = .indexed8, .bits = 8 },
        .{ .format = .gray8, .bits = 8 },
        .{ .format = .mono1, .bits = 1 },
    };
    for (bits) |one| {
        const format = @intFromEnum(one.format);
        try testing.expectEqual(one.bits, base(rb).RtgFormatBits(format));
        // A row of whole bytes a pixel; one bit a pixel rounds up.
        try testing.expectEqual((one.bits * 13 + 7) / 8, base(rb).RtgRowBytes(format, 13));
        try testing.expectEqual(@as(u32, 0), base(rb).RtgRowBytes(format, 0));
    }
    try testing.expectEqual(@as(u32, 640), base(rb).RtgRowBytes(@intFromEnum(rtg.PixelFormat.rgb565), 320));
    try testing.expectEqual(@as(u32, 2), base(rb).RtgRowBytes(@intFromEnum(rtg.PixelFormat.mono1), 9));
    // A number past the formats, and one no format's byte holds.
    for ([_]u32{ 9, 99, 255, 256, ~@as(u32, 0) }) |none| {
        try testing.expectEqual(@as(u32, 0), base(rb).RtgFormatBits(none));
        try testing.expectEqual(@as(u32, 0), base(rb).RtgRowBytes(none, 320));
    }
    // A row that does not fit in 32 bits is no row.
    const bgra32 = @intFromEnum(rtg.PixelFormat.bgra32);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFC), base(rb).RtgRowBytes(bgra32, 0x3FFF_FFFF));
    try testing.expectEqual(@as(u32, 0), base(rb).RtgRowBytes(bgra32, 0x4000_0000));
    try testing.expectEqual(@as(u32, 0), base(rb).RtgRowBytes(bgra32, ~@as(u32, 0)));
    try tearDown(rb);
}

/// Whether a declaration of an SDK file is a function, or a type with a
/// function of its own.
fn holdsFunction(comptime value: anytype) bool {
    if (@TypeOf(value) != type) return @typeInfo(@TypeOf(value)) == .@"fn";
    const decls = switch (@typeInfo(value)) {
        .@"struct" => |info| info.decls,
        .@"union" => |info| info.decls,
        .@"enum" => |info| info.decls,
        .@"opaque" => |info| info.decls,
        else => return false,
    };
    inline for (decls) |decl| {
        if (@typeInfo(@TypeOf(@field(value, decl.name))) == .@"fn") return true;
    }
    return false;
}

test "the SDK's rtg files hold types and numbers, and no function" {
    // What a program or a driver would call is a call of the library's,
    // through the jump table: a function in one of these files would be
    // code built into every caller. The two bases are the generated
    // interfaces, whose methods are the calls themselves.
    const files = .{ rtg, rtg.bitmaps, rtg.boards, rtg.drivers, rtg.modes, rtg.errors, rtg.tags, rtg.transport, rtg.video, rtg.settings };
    comptime {
        @setEvalBranchQuota(200_000);
        for (files) |file| {
            for (@typeInfo(file).@"struct".decls) |decl| {
                if (std.mem.eql(u8, decl.name, "RtgBase") or std.mem.eql(u8, decl.name, "RtgDriverBase")) continue;
                if (holdsFunction(@field(file, decl.name))) @compileError("sdk/libs/rtg: '" ++ decl.name ++ "' is or holds a function");
            }
        }
    }
}
