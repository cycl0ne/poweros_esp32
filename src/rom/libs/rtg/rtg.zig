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
//! the rows on with RefreshBitMap. The drawing calls are here so that a
//! board whose own engine is faster than the CPU can offer that, and a
//! board that has no engine answers RTGERR_NOT_SUPPORTED - the library
//! never quietly does the work instead, because the layer that does know
//! how to draw is the one above.
//!
//! The base is opened with OpenLibrary("rtg.library", 1). Its functions
//! are sdk/fd/rtg_lib.fd, its types sdk/libs/rtg/.
//!
//! Each call is a file of its own in the folder for its category -
//! driver/, board/, bitmap/, display/, engine/, event/, transport/, tag/
//! and errors/ - and memory/ holds the arena display memory is cut from.
//! The jump table is rtg_lvo.zig, the ROM tag and init rtg_init.zig, the
//! base rtg_base.zig. This file holds the names the rest of the kernel
//! reaches the library by, and the tests of calls working together. The
//! drivers this machine has are in `../rtg_driver/`: qemuboard/,
//! rgbboard/ and i2cbus/, and fakeboard/ for the host tests.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
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

const testing = std.testing;
/// The library's interface as the SDK has it, for the tests' calls.
const interface = sdk.interface.rtg;
const LIBRARY_VERSION = rtg_init.LIBRARY_VERSION;
const LIBRARY_REVISION = rtg_init.LIBRARY_REVISION;
const memory = @import("memory/_memory.zig");

test {
    _ = rtg_base;
    _ = rtg_init;
    _ = @import("rtg_lvo.zig");
    _ = @import("bitmap/_bitmap.zig");
    _ = @import("bitmap/allocbitmap.zig");
    _ = @import("bitmap/attachbitmap.zig");
    _ = @import("bitmap/freebitmap.zig");
    _ = @import("bitmap/refreshbitmap.zig");
    _ = @import("board/_board.zig");
    _ = @import("board/boardcontrol.zig");
    _ = @import("board/boardmode.zig");
    _ = @import("board/createboardtaglist.zig");
    _ = @import("board/deleteboard.zig");
    _ = @import("board/findboard.zig");
    _ = @import("board/findboardmode.zig");
    _ = @import("board/getboardinfo.zig");
    _ = @import("board/getboardstats.zig");
    _ = @import("board/nextboard.zig");
    _ = @import("board/nextboardmode.zig");
    _ = @import("board/setboardmode.zig");
    _ = @import("display/boardbrightness.zig");
    _ = @import("display/boarddisplaybitmap.zig");
    _ = @import("display/mirrorboard.zig");
    _ = @import("display/setboardbrightness.zig");
    _ = @import("display/setboarddisplay.zig");
    _ = @import("display/setboardgap.zig");
    _ = @import("display/showbitmap.zig");
    _ = @import("display/swapboardaxes.zig");
    _ = @import("display/waitvblank.zig");
    _ = @import("driver/_driver.zig");
    _ = @import("driver/addrtgdriver.zig");
    _ = @import("driver/findrtgdriver.zig");
    _ = @import("driver/lockrtgdrivers.zig");
    _ = @import("driver/nextrtgdriver.zig");
    _ = @import("driver/remrtgdriver.zig");
    _ = @import("driver/unlockrtgdrivers.zig");
    _ = @import("engine/_engine.zig");
    _ = @import("engine/blitpattern.zig");
    _ = @import("engine/blittemplate.zig");
    _ = @import("engine/copyrect.zig");
    _ = @import("engine/fillrect.zig");
    _ = @import("engine/invertrect.zig");
    _ = @import("engine/packrtgcolor.zig");
    _ = @import("engine/unpackrtgcolor.zig");
    _ = @import("engine/waitblit.zig");
    _ = @import("errors/rtgerrortext.zig");
    _ = @import("errors/rtglasterror.zig");
    _ = @import("event/_event.zig");
    _ = @import("event/addrtgeventserver.zig");
    _ = @import("event/remrtgeventserver.zig");
    _ = @import("event/signalrtgevent.zig");
    _ = @import("memory/_memory.zig");
    _ = @import("tag/findrtgtagitem.zig");
    _ = @import("tag/getrtgtagdata.zig");
    _ = @import("transport/_transport.zig");
    _ = @import("transport/createtransporttaglist.zig");
    _ = @import("transport/deletetransport.zig");
    _ = @import("transport/rxparam.zig");
    _ = @import("transport/txcolor.zig");
    _ = @import("transport/txparam.zig");
}

/// The kernel's exec and utility, to set up and tear down around it.
const kexec = @import("../exec/exec.zig");
const kutility = @import("../utility/utility.zig");
const fake = @import("../rtg_driver/fakeboard/fakeboard.zig");

test {
    _ = @import("../rtg_driver/fakeboard/fakeboard.zig");
    _ = @import("../rtg_driver/i2cbus/frame.zig");
}

/// exec on its test RAM, utility.library and rtg.library from their tags,
/// with the test board's driver registered.
fn setUp() !*RtgBase {
    try kexec.setUp();
    _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
    const made = kexec.InitResident(kexec.SysBase, &rtg_library_tag, null) orelse return error.NoRtg;
    const rb: *RtgBase = @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
    const state = fake.create(rb.sys_base) orelse return error.NoDriver;
    if (!base(rb).AddRtgDriver(&state.driver)) return error.NoDriver;
    return rb;
}

/// The test board's own state, found the way anything finds a driver's:
/// through the node it registered.
fn fakeOf(rb: *RtgBase) *fake.State {
    return fake.stateOf(base(rb).FindRtgDriver(fake.DRIVER_NAME).?);
}

/// Neither library expunges itself: take the driver off, close utility for
/// rtg, free both, and check that nothing is left.
fn tearDown(rb: *RtgBase) !void {
    const state = fakeOf(rb);
    _ = base(rb).RemRtgDriver(&state.driver);
    fake.destroy(state);
    const ub: *kutility.UtilityBase = @ptrCast(@alignCast(rb.utility_base));
    _ = kexec.CloseLibrary(kexec.SysBase, &ub.lib);
    kexec.Remove(kexec.SysBase, &rb.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &rb.lib);
    kutility.freeForTests(ub);
    try kexec.expectNoLeaks();
}

/// The library through the SDK's interface, the way a caller reaches it.
fn base(rb: *RtgBase) *interface.RtgBase {
    return @ptrCast(rb);
}

fn makeBoard(rb: *RtgBase) !*rtg.RtgBoard {
    const tag_list = [_]TagItem{.{}};
    return base(rb).CreateBoardTagList("fake", &tag_list) orelse error.NoBoard;
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
    try testing.expectEqual(@as(usize, 640), base(rb).GetRtgTagData(rtg.tags.RTGA_Width, 0, &tag_list));
    try testing.expectEqual(@as(usize, 7), base(rb).GetRtgTagData(rtg.tags.RTGA_Height, 7, &tag_list));
    try tearDown(rb);
}

test "drivers: found by name, walked by priority, and never twice" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);

    try testing.expectEqual(&fk.driver, base(rb).FindRtgDriver("fake").?);
    try testing.expect(base(rb).FindRtgDriver("nothing") == null);
    // The same name is refused, and so is a driver that makes nothing.
    try testing.expect(!base(rb).AddRtgDriver(&fk.driver));

    var empty_ops = rtg.RtgDriverOps{};
    var empty = rtg.RtgDriver{ .node = .{ .name = "empty" }, .ops = &empty_ops };
    try testing.expect(!base(rb).AddRtgDriver(&empty));

    var second_ops = rtg.RtgDriverOps{ .create_transport = @ptrFromInt(0x1000) };
    var second = rtg.RtgDriver{
        .node = .{ .name = "second", .pri = 10 },
        .ops = &second_ops,
        .type = rtg.boards.RTGDT_TRANSPORT,
    };
    try testing.expect(base(rb).AddRtgDriver(&second));

    base(rb).LockRtgDrivers();
    // Highest priority first: "second" at 10 before "fake" at 0.
    try testing.expectEqual(&second, base(rb).NextRtgDriver(null).?);
    try testing.expectEqual(&fk.driver, base(rb).NextRtgDriver(&second).?);
    try testing.expect(base(rb).NextRtgDriver(&fk.driver) == null);
    base(rb).UnlockRtgDrivers();

    try testing.expect(base(rb).RemRtgDriver(&second));
    try testing.expect(!base(rb).RemRtgDriver(&second));
    try tearDown(rb);
}

test "a board: its own name, its own instance, its driver held" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);

    const board = try makeBoard(rb);
    try testing.expectEqual(@as(u32, 1), fk.log.created);
    try testing.expectEqual(@as(u16, 1), fk.driver.open_cnt);
    // Named after its driver, and the name is the library's copy.
    try testing.expectEqualStrings("fake0", std.mem.span(board.node.name.?));
    try testing.expectEqual(board, base(rb).FindBoard("fake0").?);
    try testing.expectEqual(board, base(rb).NextBoard(null).?);
    try testing.expect(base(rb).NextBoard(board) == null);
    // The driver's data is its own, and the library cleared it.
    const instance: *fake.Instance = @ptrCast(@alignCast(board.instance.?));
    try testing.expectEqual(fake.instance_pattern, instance.pattern);
    // What it can do is what it filled in, and nothing else.
    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expect(info.caps & rtg.boards.RTGBC_FILL_RECT != 0);
    try testing.expect(info.caps & rtg.boards.RTGBC_BLIT_TEMPLATE == 0);
    try testing.expectEqual(@as(u32, 3), info.modes);

    base(rb).DeleteBoard(board);
    try testing.expectEqual(@as(u32, 1), fk.log.destroyed);
    try testing.expectEqual(@as(u16, 0), fk.driver.open_cnt);
    try testing.expect(base(rb).NextBoard(null) == null);
    try tearDown(rb);
}

test "a board is named, and its user data kept, when the tags say so" {
    const rb = try setUp();
    defer kexec.deinit();

    var mine: u32 = 5;
    var code: i32 = 123;
    const tag_list = [_]TagItem{
        .{ .tag = rtg.tags.RTGA_BoardName, .data = @intFromPtr("screen") },
        .{ .tag = rtg.tags.RTGA_UserData, .data = @intFromPtr(&mine) },
        .{ .tag = rtg.tags.RTGA_ErrorPtr, .data = @intFromPtr(&code) },
        .{},
    };
    const board = base(rb).CreateBoardTagList("fake", &tag_list).?;
    try testing.expectEqualStrings("screen", std.mem.span(board.node.name.?));
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&mine)), board.user_data);
    try testing.expectEqual(rtg.errors.RTGERR_OK, code);
    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a driver that is not there, and a create that fails, leave nothing" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);

    const tag_list = [_]TagItem{.{}};
    try testing.expect(base(rb).CreateBoardTagList("nothing", &tag_list) == null);
    try testing.expectEqual(rtg.errors.RTGERR_NO_DRIVER, base(rb).RtgLastError());

    fk.create_answer = rtg.errors.RTGERR_NO_DISPLAY;
    var code: i32 = 0;
    const with_error = [_]TagItem{
        .{ .tag = rtg.tags.RTGA_ErrorPtr, .data = @intFromPtr(&code) },
        .{},
    };
    try testing.expect(base(rb).CreateBoardTagList("fake", &with_error) == null);
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, code);
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, base(rb).RtgLastError());
    try testing.expectEqual(@as(u16, 0), fk.driver.open_cnt);
    // The leak check in tearDown is what proves the handle came back.
    try tearDown(rb);
}

test "modes: walked, found, and set" {
    const rb = try setUp();
    defer kexec.deinit();
    const board = try makeBoard(rb);

    const first = base(rb).NextBoardMode(board, null).?;
    try testing.expectEqualStrings("320x200", std.mem.span(first.node.name.?));
    const second = base(rb).NextBoardMode(board, first).?;
    try testing.expectEqual(@as(u32, 640), second.width);

    // Nothing asked for is the board's default.
    try testing.expectEqual(first, base(rb).FindBoardMode(board, 0, 0, 0).?);
    try testing.expectEqual(second, base(rb).FindBoardMode(board, 640, 0, 0).?);
    try testing.expect(base(rb).FindBoardMode(board, 800, 600, 0) == null);

    try testing.expect(base(rb).BoardMode(board) == null);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardMode(board, second));
    try testing.expectEqual(second, base(rb).BoardMode(board).?);
    try testing.expect(second.flags & rtg.boards.RTGMF_CURRENT != 0);
    try testing.expect(first.flags & rtg.boards.RTGMF_CURRENT == 0);

    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u32, 640), info.width);
    try testing.expectEqual(@as(u32, 480), info.height);
    try testing.expectEqual(@as(u32, 2), info.mode_id);

    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "display memory: cut up, aligned, and put back together" {
    const rb = try setUp();
    defer kexec.deinit();
    const board = try makeBoard(rb);

    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    // What is usable is the region less the lead-in to its first aligned
    // address: the fake hands over plain allocated memory, as a driver
    // that has not aligned its own may.
    const whole = info.memory_total;
    try testing.expect(whole <= fake.region_bytes);
    try testing.expect(whole + 64 >= fake.region_bytes);

    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const one = base(rb).AllocBitMap(board, 100, 10, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    // A row is rounded up to the board's alignment, so every row of it
    // starts on one.
    try testing.expectEqual(@as(u32, 256), one.pitch);
    try testing.expectEqual(@as(usize, 2560), one.size_bytes);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(one.pixels.?) % 64);
    try testing.expect(one.flags & rtg.bitmaps.RTGBMF_BOARD_MEMORY != 0);
    try testing.expect(one.flags & rtg.bitmaps.RTGBMF_CACHED != 0);

    const two = base(rb).AllocBitMap(board, 100, 10, format, 0).?;
    try testing.expect(one.pixels.? != two.pixels.?);
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(whole - 2 * 2560, info.memory_free);

    // Freed in the other order, the two pieces join up again.
    base(rb).FreeBitMap(one);
    base(rb).FreeBitMap(two);
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(whole, info.memory_free);
    try testing.expectEqual(whole, info.memory_largest);

    // More than there is, and a format that is not a format.
    try testing.expect(base(rb).AllocBitMap(board, 1024, 1024, format, 0) == null);
    try testing.expectEqual(rtg.errors.RTGERR_NO_MEMORY, base(rb).RtgLastError());
    try testing.expect(base(rb).AllocBitMap(board, 8, 8, 99, 0) == null);
    try testing.expectEqual(rtg.errors.RTGERR_BAD_FORMAT, base(rb).RtgLastError());

    base(rb).DeleteBoard(board);
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
    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a buffer that keeps its memory stops a mode change" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);

    const fixed = base(rb).AllocBitMap(board, 32, 32, format, 0).?;
    try testing.expectEqual(rtg.errors.RTGERR_IN_USE, base(rb).SetBoardMode(board, null));
    try testing.expectEqual(@as(u32, 0), fk.log.set_mode);
    base(rb).FreeBitMap(fixed);

    // One that agreed to lose it keeps its handle and loses its pixels.
    const loose = base(rb).AllocBitMap(board, 32, 32, format, rtg.bitmaps.RTGBMF_VOLATILE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardMode(board, null));
    try testing.expect(loose.pixels == null);
    try testing.expectEqual(
        rtg.errors.RTGERR_BAD_ARG,
        base(rb).FillRect(loose, &rtg.RtgRect{ .width = 4, .height = 4 }, 0),
    );
    base(rb).FreeBitMap(loose);

    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "showing a buffer, and what may not be shown" {
    const rb = try setUp();
    defer kexec.deinit();
    const board = try makeBoard(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);

    const hidden = base(rb).AllocBitMap(board, 16, 16, format, 0).?;
    const up = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;

    try testing.expectEqual(rtg.errors.RTGERR_NOT_DISPLAYABLE, base(rb).ShowBitMap(board, hidden, 0, 0));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, up, 0, 0));
    try testing.expectEqual(up, base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(up.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);

    // What the board is reading is not the caller's to take away.
    base(rb).FreeBitMap(up);
    try testing.expectEqual(up, base(rb).BoardDisplayBitMap(board).?);
    try testing.expectEqual(rtg.errors.RTGERR_IN_USE, base(rb).RtgLastError());

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null, 0, 0));
    try testing.expect(base(rb).BoardDisplayBitMap(board) == null);
    try testing.expect(up.flags & rtg.bitmaps.RTGBMF_SHOWING == 0);

    base(rb).FreeBitMap(up);
    base(rb).FreeBitMap(hidden);
    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "what is written is handed on by the row" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const bitmap = base(rb).AllocBitMap(board, 32, 20, format, 0).?;

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshBitMap(bitmap, 4, 6));
    try testing.expectEqual(@as(u32, 4), fk.log.last_refresh_y);
    try testing.expectEqual(@as(u32, 6), fk.log.last_refresh_rows);
    // No count is all of the rows there are, from where it was asked.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshBitMap(bitmap, 0, 0));
    try testing.expectEqual(@as(u32, 20), fk.log.last_refresh_rows);
    // More rows than it has is as many as it has.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshBitMap(bitmap, 18, 40));
    try testing.expectEqual(@as(u32, 2), fk.log.last_refresh_rows);
    try testing.expectEqual(rtg.errors.RTGERR_BOUNDS, base(rb).RefreshBitMap(bitmap, 20, 1));

    base(rb).FreeBitMap(bitmap);
    base(rb).DeleteBoard(board);
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

    var stats: rtg.RtgBoardStats = .{};
    try testing.expectEqual(@as(u32, @sizeOf(rtg.RtgBoardStats)), base(rb).GetBoardStats(board, &stats, @sizeOf(rtg.RtgBoardStats)));
    try testing.expectEqual(@as(u32, 42), stats.frames);
    try testing.expectEqual(@as(u32, 1), stats.starved_frames);

    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

var first_server_ran: u32 = 0;
var second_server_ran: u32 = 0;
var stop_the_chain = false;

fn firstServer(_: ?*anyopaque, _: *anyopaque, _: u32) callconv(.c) i32 {
    first_server_ran += 1;
    return if (stop_the_chain) 1 else 0;
}

fn secondServer(_: ?*anyopaque, _: *anyopaque, _: u32) callconv(.c) i32 {
    second_server_ran += 1;
    return 0;
}

test "events: highest first, and the first to answer ends it" {
    const rb = try setUp();
    defer kexec.deinit();
    const board = try makeBoard(rb);
    first_server_ran = 0;
    second_server_ran = 0;
    stop_the_chain = false;

    var high = exec.Interrupt{ .node = .{ .type = .interrupt, .pri = 10, .name = "high" }, .code = @ptrCast(&firstServer) };
    var low = exec.Interrupt{ .node = .{ .type = .interrupt, .pri = 0, .name = "low" }, .code = @ptrCast(&secondServer) };
    try testing.expect(base(rb).AddRtgEventServer(board, rtg.events.RTGEV_VBLANK, &high));
    try testing.expect(base(rb).AddRtgEventServer(board, rtg.events.RTGEV_VBLANK, &low));
    try testing.expect(!base(rb).AddRtgEventServer(board, 99, &low));

    _ = base(rb).SignalRtgEvent(board, rtg.events.RTGEV_VBLANK);
    try testing.expectEqual(@as(u32, 1), first_server_ran);
    try testing.expectEqual(@as(u32, 1), second_server_ran);

    // The one with the higher priority keeps the event to itself.
    stop_the_chain = true;
    _ = base(rb).SignalRtgEvent(board, rtg.events.RTGEV_VBLANK);
    try testing.expectEqual(@as(u32, 2), first_server_ran);
    try testing.expectEqual(@as(u32, 1), second_server_ran);

    // An event nobody is listening for, and one that does not exist.
    _ = base(rb).SignalRtgEvent(board, rtg.events.RTGEV_SHOWN);
    try testing.expectEqual(@as(i32, 0), base(rb).SignalRtgEvent(board, 99));

    base(rb).RemRtgEventServer(board, rtg.events.RTGEV_VBLANK, &high);
    stop_the_chain = false;
    _ = base(rb).SignalRtgEvent(board, rtg.events.RTGEV_VBLANK);
    try testing.expectEqual(@as(u32, 2), first_server_ran);
    try testing.expectEqual(@as(u32, 2), second_server_ran);

    // A board with a server still on it is not deleted from under it.
    base(rb).DeleteBoard(board);
    try testing.expectEqual(rtg.errors.RTGERR_IN_USE, base(rb).RtgLastError());
    try testing.expectEqual(board, base(rb).NextBoard(null).?);
    base(rb).RemRtgEventServer(board, rtg.events.RTGEV_VBLANK, &low);

    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "the engine: the rectangle is cut down before the board sees it" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const bitmap = base(rb).AllocBitMap(board, 16, 8, format, 0).?;

    // Over the right-hand edge and over the top: what reaches the driver
    // is what is inside the buffer.
    const over = rtg.RtgRect{ .x = 12, .y = -4, .width = 10, .height = 8 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).FillRect(bitmap, &over, 0xBEEF));
    try testing.expectEqual(@as(i32, 12), fk.log.last_rect.x);
    try testing.expectEqual(@as(i32, 0), fk.log.last_rect.y);
    try testing.expectEqual(@as(i32, 4), fk.log.last_rect.width);
    try testing.expectEqual(@as(i32, 4), fk.log.last_rect.height);

    // And the bytes really moved, inside the rectangle and nowhere else.
    const row: [*]u16 = @ptrCast(@alignCast(bitmap.rowPtr(0)));
    try testing.expectEqual(@as(u16, 0), row[11]);
    try testing.expectEqual(@as(u16, 0xBEEF), row[12]);
    try testing.expectEqual(@as(u16, 0xBEEF), row[15]);
    const past: [*]u16 = @ptrCast(@alignCast(bitmap.rowPtr(4)));
    try testing.expectEqual(@as(u16, 0), past[12]);

    // Nothing of it inside is no work at all, and no error.
    const outside = rtg.RtgRect{ .x = 100, .y = 100, .width = 4, .height = 4 };
    const fills = fk.log.fills;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).FillRect(bitmap, &outside, 0));
    try testing.expectEqual(fills, fk.log.fills);
    const empty = rtg.RtgRect{ .x = 0, .y = 0, .width = 0, .height = 4 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).FillRect(bitmap, &empty, 0));
    try testing.expectEqual(fills, fk.log.fills);

    // A rectangle that would run off the end of the numbers does not.
    const huge = rtg.RtgRect{ .x = std.math.maxInt(i32) - 1, .y = 0, .width = 16, .height = 4 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).FillRect(bitmap, &huge, 0));
    try testing.expectEqual(fills, fk.log.fills);

    base(rb).FreeBitMap(bitmap);
    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a copy is cut down to both buffers at once" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const source = base(rb).AllocBitMap(board, 16, 8, format, 0).?;
    const target = base(rb).AllocBitMap(board, 8, 8, format, 0).?;

    // Eight columns is all the destination has room for.
    const copy = rtg.RtgCopy{ .src_x = 0, .src_y = 0, .width = 16, .height = 8, .dest_x = 0, .dest_y = 0 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).CopyRect(source, target, &copy));
    try testing.expectEqual(@as(i32, 8), fk.log.last_copy.width);
    try testing.expectEqual(@as(i32, 8), fk.log.last_copy.height);

    // A corner before the start of either moves both corners in, so the
    // two stay in step.
    const from_before = rtg.RtgCopy{ .src_x = -2, .src_y = 0, .width = 6, .height = 4, .dest_x = 3, .dest_y = 0 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).CopyRect(source, target, &from_before));
    try testing.expectEqual(@as(i32, 0), fk.log.last_copy.src_x);
    try testing.expectEqual(@as(i32, 5), fk.log.last_copy.dest_x);
    // And then the destination runs out three columns later.
    try testing.expectEqual(@as(i32, 3), fk.log.last_copy.width);

    // A copy onto itself, one pixel along: the classic overlap.
    const row: [*]u16 = @ptrCast(@alignCast(source.rowPtr(0)));
    for (0..16) |x| row[x] = @intCast(x + 1);
    const shift = rtg.RtgCopy{ .src_x = 0, .src_y = 0, .width = 8, .height = 1, .dest_x = 1, .dest_y = 0 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).CopyRect(source, source, &shift));
    try testing.expectEqual(@as(u16, 1), row[1]);
    try testing.expectEqual(@as(u16, 8), row[8]);

    base(rb).FreeBitMap(target);
    base(rb).FreeBitMap(source);
    base(rb).DeleteBoard(board);
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
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).InvertRect(bitmap, &area));
    const copy = rtg.RtgCopy{ .width = 4, .height = 4 };
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).CopyRect(bitmap, bitmap, &copy));
    const shape = rtg.RtgTemplate{ .bits = @ptrCast("x"), .pitch = 1 };
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).BlitTemplate(bitmap, &area, &shape));
    // Nothing was written, because nothing drew.
    const row: [*]u16 = @ptrCast(@alignCast(bitmap.rowPtr(0)));
    try testing.expectEqual(@as(u16, 0), row[0]);
    // Waiting for an engine that is not there comes straight back.
    base(rb).WaitBlit(board);

    base(rb).FreeBitMap(bitmap);
    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "the display: on, off, and how bright" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardDisplay(board, true));
    try testing.expect(fk.log.display_on);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardBrightness(board, 60));
    try testing.expectEqual(@as(u32, 60), base(rb).BoardBrightness(board));
    // Above the top of the range is the top of the range.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardBrightness(board, 400));
    try testing.expectEqual(@as(u32, 100), base(rb).BoardBrightness(board));

    // A control the driver knows, and the one every board takes.
    try testing.expectEqual(@as(isize, 8), base(rb).BoardControl(board, rtg.tags.RTGCTRL_RGB_SHIFT, 7));
    try testing.expectEqual(rtg.tags.RTGCTRL_RGB_SHIFT, fk.log.last_control);

    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "turning the picture: what the board can do, and what it cannot" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);

    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expect(info.caps & rtg.boards.RTGBC_MIRROR != 0);
    try testing.expect(info.caps & rtg.boards.RTGBC_SWAP_XY != 0);
    try testing.expect(info.caps & rtg.boards.RTGBC_GAP != 0);
    // A board reports itself the right way up until it is turned.
    try testing.expectEqual(@as(u8, 0), info.mirror_x);
    try testing.expectEqual(@as(u8, 0), info.swapped);

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardMode(board, null));
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    const was_width = info.width;
    const was_height = info.height;

    // Mirroring is remembered and handed to the board as asked.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).MirrorBoard(board, true, false));
    try testing.expectEqual(@as(u32, 1), fk.log.mirrors);
    try testing.expect(fk.log.last_mirror_x and !fk.log.last_mirror_y);
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u8, 1), info.mirror_x);
    try testing.expectEqual(@as(u8, 0), info.mirror_y);

    // Exchanging the axes turns what a caller draws on with it.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SwapBoardAxes(board, true));
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u8, 1), info.swapped);
    try testing.expectEqual(was_height, info.width);
    try testing.expectEqual(was_width, info.height);

    // Asking for what it is already doing is not asking again.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SwapBoardAxes(board, true));
    try testing.expectEqual(@as(u32, 1), fk.log.swaps);
    // And back, which turns the sides back too.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SwapBoardAxes(board, false));
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(was_width, info.width);
    try testing.expectEqual(@as(u8, 0), info.swapped);

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardGap(board, 4, 8));
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u32, 4), info.gap_x);
    try testing.expectEqual(@as(u32, 8), info.gap_y);

    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a board whose pixels go out as they are written will not turn" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    fk.cannot_turn = true;
    const board = try makeBoard(rb);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardMode(board, null));

    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u32, 0), info.caps & rtg.boards.RTGBC_MIRROR);
    try testing.expectEqual(@as(u32, 0), info.caps & rtg.boards.RTGBC_SWAP_XY);
    try testing.expectEqual(@as(u32, 0), info.caps & rtg.boards.RTGBC_GAP);

    const width = info.width;
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).MirrorBoard(board, true, true));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).SwapBoardAxes(board, true));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).SetBoardGap(board, 1, 1));
    // Refused means nothing moved: what it says about itself is unchanged.
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(width, info.width);
    try testing.expectEqual(@as(u8, 0), info.mirror_x);
    try testing.expectEqual(@as(u8, 0), info.swapped);
    try testing.expectEqual(@as(u32, 0), info.gap_x);
    try testing.expectEqual(@as(u32, 0), fk.log.mirrors);

    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "colours: packed into a format and taken apart again" {
    const rb = try setUp();
    defer kexec.deinit();
    const rgb565 = @intFromEnum(rtg.PixelFormat.rgb565);

    try testing.expectEqual(@as(u32, 0xFFFF), base(rb).PackRtgColor(rgb565, 255, 255, 255));
    try testing.expectEqual(@as(u32, 0), base(rb).PackRtgColor(rgb565, 0, 0, 0));
    try testing.expectEqual(@as(u32, 0xF800), base(rb).PackRtgColor(rgb565, 255, 0, 0));
    try testing.expectEqual(@as(u32, 0x001F), base(rb).PackRtgColor(rgb565, 0, 0, 255));

    var out: rtg.RtgRGB = .{};
    base(rb).UnpackRtgColor(rgb565, 0xFFFF, &out);
    try testing.expectEqual(@as(u8, 255), out.red);
    try testing.expectEqual(@as(u8, 255), out.green);
    try testing.expectEqual(@as(u8, 255), out.blue);
    base(rb).UnpackRtgColor(rgb565, 0xF800, &out);
    try testing.expectEqual(@as(u8, 255), out.red);
    try testing.expectEqual(@as(u8, 0), out.green);

    const rgba32 = @intFromEnum(rtg.PixelFormat.rgba32);
    try testing.expectEqual(@as(u32, 0x1020_30FF), base(rb).PackRtgColor(rgba32, 0x10, 0x20, 0x30));
    base(rb).UnpackRtgColor(rgba32, 0x1020_30FF, &out);
    try testing.expectEqual(@as(u8, 0x10), out.red);
    try testing.expectEqual(@as(u8, 0x30), out.blue);
    try testing.expectEqual(@as(u8, 0xFF), out.alpha);

    // A format nobody knows packs to nothing rather than to rubbish.
    try testing.expectEqual(@as(u32, 0), base(rb).PackRtgColor(99, 255, 255, 255));
    try tearDown(rb);
}

test "every error has words, and so has one that does not exist" {
    const rb = try setUp();
    defer kexec.deinit();
    inline for (@typeInfo(rtg.errors).@"struct".decls) |d| {
        const value = @field(rtg.errors, d.name);
        if (@TypeOf(value) != i32) continue;
        const words = std.mem.span(base(rb).RtgErrorText(value));
        try testing.expect(words.len != 0);
        if (value != rtg.errors.RTGERR_OK) {
            try testing.expect(!std.mem.eql(u8, words, "unknown error"));
        }
    }
    try testing.expectEqualStrings("unknown error", std.mem.span(base(rb).RtgErrorText(-999)));
    try tearDown(rb);
}
