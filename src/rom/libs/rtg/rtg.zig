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
//! driver/, board/, bitmap/, display/, engine/, event/, transport/, tag/,
//! pointer/, video/ and errors/ - and memory/ holds the arena display
//! memory is cut from.
//! The jump table is rtg_lvo.zig, the ROM tag and init rtg_init.zig, the
//! base rtg_base.zig. This file holds the names the rest of the kernel
//! reaches the library by, and the tests of calls working together. The
//! drivers are in `../rtg_driver/`, a folder each, with fakeboard/ for
//! the host tests.

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

const testing = std.testing;
/// The library's interface as the SDK has it, for the tests' calls.
const interface = sdk.interface.rtg;
const memory = @import("memory/_memory.zig");
const boards = @import("board/_board.zig");

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
    _ = @import("display/showbitmap.zig");
    _ = @import("display/waitvblank.zig");
    _ = @import("driver/_driver.zig");
    _ = @import("driver/addrtgdriver.zig");
    _ = @import("driver/lockrtgdrivers.zig");
    _ = @import("driver/nextrtgdriver.zig");
    _ = @import("driver/remrtgdriver.zig");
    _ = @import("driver/unlockrtgdrivers.zig");
    _ = @import("engine/_engine.zig");
    _ = @import("engine/blitpattern.zig");
    _ = @import("engine/blittemplate.zig");
    _ = @import("engine/copyrect.zig");
    _ = @import("engine/fillrect.zig");
    _ = @import("errors/rtgerrortext.zig");
    _ = @import("event/_event.zig");
    _ = @import("event/addrtgeventserver.zig");
    _ = @import("event/remrtgeventserver.zig");
    _ = @import("event/signalrtgevent.zig");
    _ = @import("memory/_memory.zig");
    _ = @import("tag/getrtgtagdata.zig");
    _ = @import("transport/_transport.zig");
    _ = @import("transport/createtransporttaglist.zig");
    _ = @import("transport/deletetransport.zig");
    _ = @import("transport/rxparam.zig");
    _ = @import("transport/txcolor.zig");
    _ = @import("transport/txparam.zig");
    _ = @import("pointer/setboardpointer.zig");
    _ = @import("pointer/moveboardpointer.zig");
    _ = @import("pointer/showboardpointer.zig");
    _ = @import("video/openvideolayer.zig");
    _ = @import("video/closevideolayer.zig");
    _ = @import("video/showvideoframe.zig");
    _ = @import("video/movevideolayer.zig");
}

/// The kernel's exec and utility, to set up and tear down around it.
const kexec = @import("../exec/exec.zig");
const kutility = @import("../utility/utility.zig");
/// graphics.library's pen packing, which the pointer's conversion is held
/// to.
const kpens = @import("../graphics/rastport/_rastport.zig");
const fake = @import("../rtg_driver/fakeboard/fakeboard.zig");
const timer = sdk.devices.timer;

/// timer.device for the tests. It serves what the library sends and
/// nothing else: TR_ADDREQUEST on the unit its open gave, which waits
/// until a test lets its time pass (`expire`); any other request is
/// answered IOERR_NOCMD at once, as the device answers a command it does
/// not know. What a request was sent with is kept for the test to read.
/// One request at a time, which is all the library sends.
const FakeTimer = struct {
    var device: ?*exec.Device = null;
    var unit: exec.Unit = .{};
    /// The unit number the device was opened on; `no_unit` before.
    var opened_unit: u32 = no_unit;
    const no_unit = ~@as(u32, 0);
    /// The request whose time has not come.
    var waiting: ?*exec.IORequest = null;
    /// How an abort is answered: with the reply made inside AbortIO, as
    /// the device makes it - or, set, with the request only taken off and
    /// its reply left for `land`, as a device that answers an abort
    /// before the reply is made.
    var abort_replies_later = false;
    /// The request an abort took off whose reply is still to be made.
    var leaving: ?*exec.IORequest = null;
    /// Requests sent and taken back, and the time the last was sent with.
    var sent: u32 = 0;
    var aborted: u32 = 0;
    var last_micros: u64 = 0;
    /// Where the last request sent was. Never read through: its memory
    /// is its sender's, and has gone by the time a test looks.
    var last: ?*exec.IORequest = null;

    fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
        _ = flags;
        dev.open_cnt += 1;
        opened_unit = unit_number;
        io.unit = &unit;
        return 0;
    }
    fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
        _ = io;
        dev.open_cnt -= 1;
        return null;
    }
    /// Never by itself: `remove` takes it off.
    fn expunge(dev: *exec.Device) callconv(.c) ?*anyopaque {
        _ = dev;
        return null;
    }
    fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
        _ = dev;
        io.flags &= ~exec.IOF_QUICK;
        last = io;
        if (io.command != timer.TR_ADDREQUEST or io.unit != &unit) {
            io.err = exec.IOERR_NOCMD;
            kexec.ReplyIO(kexec.SysBase, io);
            return;
        }
        const request: *timer.TimeRequest = @fieldParentPtr("node", io);
        io.err = 0;
        io.message.node.type = .message;
        sent += 1;
        last_micros = request.time.toMicros();
        waiting = io;
    }
    fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
        _ = dev;
        if (waiting != io) return -1;
        waiting = null;
        aborted += 1;
        io.err = exec.IOERR_ABORTED;
        if (abort_replies_later) {
            leaving = io;
        } else {
            kexec.ReplyIO(kexec.SysBase, io);
        }
        return 0;
    }
    /// The waiting request's time has come: it is replied, as the
    /// device's interrupt replies it.
    fn expire() void {
        const io = waiting orelse return;
        waiting = null;
        kexec.ReplyIO(kexec.SysBase, io);
    }
    /// The reply of the request an abort took off, made now.
    fn land() void {
        const io = leaving orelse return;
        leaving = null;
        kexec.ReplyIO(kexec.SysBase, io);
    }

    const vectors = [_]*const anyopaque{
        exec.vec(open),
        exec.vec(close),
        exec.vec(expunge),
        exec.vec(exec.libExtFunc),
        exec.vec(beginIO),
        exec.vec(abortIO),
    };

    /// The device on exec's list, before the library is made and opens it.
    fn add() !void {
        unit = .{};
        opened_unit = no_unit;
        waiting = null;
        abort_replies_later = false;
        leaving = null;
        sent = 0;
        aborted = 0;
        last_micros = 0;
        last = null;
        const dev = kexec.MakeLibrary(kexec.SysBase, &vectors, @sizeOf(exec.Device), null, null) orelse return error.NoTimer;
        dev.node.name = sdk.interface.timer.NAME;
        kexec.AddDevice(kexec.SysBase, dev);
        device = dev;
    }

    /// Off the list and freed, once nothing has it open.
    fn remove() void {
        const dev = device orelse return;
        device = null;
        kexec.Remove(kexec.SysBase, &dev.node);
        kexec.freeLibraryMemory(kexec.SysBase, dev);
    }
};

/// The task switch for the tests, in place of the CPU's: a task that
/// waits is switched away from by exec's own dispatcher, `meanwhile` runs
/// as an interrupt would while it sleeps - again for as long as the task
/// is not woken - and the dispatcher brings the task back once it is. A
/// wait nothing ends stops the test instead of spinning.
const Sleep = struct {
    /// What an interrupt does while the task sleeps.
    var meanwhile: ?*const fn () void = null;
    /// How often a task slept, and how many interrupts came meanwhile.
    var sleeps: u32 = 0;
    var interrupts: u32 = 0;
    var switching = false;
    /// The switch that was there before.
    var before: *const fn () void = undefined;
    /// More interrupts than this in one sleep is a wait nothing ends.
    const patience = 16;

    fn switchNow() void {
        const sys = kexec.SysBase;
        const task = kexec.FindTask(sys, null).?;
        // A switch that is merely due changes nothing here: there is one
        // task, and it runs.
        if (task.state != .wait or switching) return;
        switching = true;
        defer switching = false;
        sleeps += 1;
        // Out of the task: the core goes on with its idle task. A task's
        // context is the task, as with no CPU to save one.
        kexec.interruptEnter(sys);
        var idle = kexec.interruptExit(sys, task);
        // Interrupts, until one wakes the task: at that one's end the
        // dispatcher goes back to it.
        var came: u32 = 0;
        while (task.state == .wait) : (came += 1) {
            if (came == patience) @panic("a task waits and nothing wakes it");
            kexec.interruptEnter(sys);
            interrupts += 1;
            if (meanwhile) |happens| happens();
            idle = kexec.interruptExit(sys, idle);
        }
        if (task.state != .run) @panic("a task was woken and the core did not go back to it");
    }

    fn install(happens: *const fn () void) void {
        meanwhile = happens;
        sleeps = 0;
        interrupts = 0;
        before = kexec.task_hardware.switch_now;
        kexec.task_hardware.switch_now = switchNow;
    }

    fn uninstall() void {
        meanwhile = null;
        kexec.task_hardware.switch_now = before;
    }
};

test {
    _ = @import("../rtg_driver/fakeboard/fakeboard.zig");
}

/// exec on its test RAM, utility.library and rtg.library from their tags,
/// the tests' timer.device there for the library to open, and the test
/// board's driver registered.
fn setUp() !*RtgBase {
    try kexec.setUp();
    _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
    try FakeTimer.add();
    const made = kexec.InitResident(kexec.SysBase, &rtg_library_tag, null) orelse return error.NoRtg;
    const rb: *RtgBase = @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
    const state = fake.create(rb.sys_base) orelse return error.NoDriver;
    if (!base(rb).AddRtgDriver(&state.driver)) return error.NoDriver;
    return rb;
}

/// The test board's own state, found through the node it registered: the
/// driver of its name on the library's list.
fn fakeOf(rb: *RtgBase) *fake.State {
    base(rb).LockRtgDrivers();
    defer base(rb).UnlockRtgDrivers();
    var driver = base(rb).NextRtgDriver(null);
    while (driver) |one| : (driver = base(rb).NextRtgDriver(one)) {
        if (std.mem.orderZ(u8, one.node.name.?, fake.DRIVER_NAME) == .eq) return fake.stateOf(one);
    }
    unreachable;
}

/// Neither library expunges itself: take the driver off, close utility
/// and the timer for rtg, free all three, and check that nothing is left -
/// no memory, and no signal of the test's task that a wait took.
fn tearDown(rb: *RtgBase) !void {
    const state = fakeOf(rb);
    _ = base(rb).RemRtgDriver(&state.driver);
    fake.destroy(state);
    const ub: *kutility.UtilityBase = @ptrCast(@alignCast(rb.utility_base));
    _ = kexec.CloseLibrary(kexec.SysBase, &ub.lib);
    if (rb.timer_io.node.device != null) kexec.CloseDevice(kexec.SysBase, &rb.timer_io.node);
    FakeTimer.remove();
    kexec.Remove(kexec.SysBase, &rb.lib.node);
    kexec.freeLibraryMemory(kexec.SysBase, &rb.lib);
    kutility.freeForTests(ub);
    try testing.expectEqual(exec.tasks.system_signals, kexec.FindTask(kexec.SysBase, null).?.sig_alloc);
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

test "drivers: walked by priority, and never twice" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);

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
    const tag_list = [_]TagItem{
        .{ .tag = rtg.tags.RTGA_BoardName, .data = @intFromPtr("screen") },
        .{ .tag = rtg.tags.RTGA_UserData, .data = @intFromPtr(&mine) },
        .{},
    };
    const board = base(rb).CreateBoardTagList("fake", &tag_list).?;
    try testing.expectEqualStrings("screen", std.mem.span(board.node.name.?));
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&mine)), board.user_data);
    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a driver that is not there, and a create that fails, leave nothing" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);

    const tag_list = [_]TagItem{.{}};
    try testing.expect(base(rb).CreateBoardTagList("nothing", &tag_list) == null);

    fk.create_answer = rtg.errors.RTGERR_NO_DISPLAY;
    try testing.expect(base(rb).CreateBoardTagList("fake", &tag_list) == null);
    try testing.expectEqual(@as(u32, 0), fk.log.created);
    try testing.expectEqual(@as(u16, 0), fk.driver.open_cnt);
    try testing.expect(base(rb).NextBoard(null) == null);
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

    var before: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &before, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u32, 0), before.flags & rtg.boards.RTGBF_MODE_SET);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardMode(board, second));
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

test "display memory from the system: taken as asked for, aligned, held to its limit, given back" {
    const rb = try setUp();
    defer kexec.deinit();
    const sys = rb.sys_base;
    var arena: memory.Arena = .{};
    arena.initSystem(sys, 3 * 2560, 64, 0);
    try testing.expect(arena.usable());
    try testing.expectEqual(@as(usize, 3 * 2560), arena.free_bytes);
    var pieces: [3]memory.Piece = undefined;
    for (&pieces) |*piece| {
        piece.* = arena.take(sys, 2560) orelse return error.NoMemory;
        try testing.expectEqual(@as(usize, 0), piece.pixels % 64);
        try testing.expect(piece.pixels >= piece.offset and piece.pixels + 2560 <= piece.offset + piece.taken);
    }
    try testing.expectEqual(@as(usize, 0), arena.free_bytes);
    try testing.expect(arena.take(sys, 2560) == null);
    try testing.expectEqual(@as(usize, 0), arena.largest(sys));
    for (pieces) |piece| arena.give(sys, piece.offset, piece.taken);
    try testing.expectEqual(@as(usize, 3 * 2560), arena.free_bytes);
    arena.deinit(sys);
    try tearDown(rb);
}

test "display memory a DMA engine reaches: taken from there and nowhere else" {
    const rb = try setUp();
    defer kexec.deinit();
    const sys = rb.sys_base;
    var arena: memory.Arena = .{};
    arena.initSystem(sys, 2 * 2560, 64, memory.attributesOf(rtg.boards.RTGRF_SYSTEM_MEMORY | rtg.boards.RTGRF_DMA_MEMORY));
    // The test RAM says nothing of DMA, so it is no answer.
    try testing.expect(arena.take(sys, 2560) == null);
    try testing.expectEqual(@as(usize, 0), arena.largest(sys));
    var dma_ram: [8192]u8 align(64) = undefined;
    _ = kexec.AddMemList(kexec.SysBase, dma_ram.len, exec.MEMF_DMA, -20, &dma_ram, "dma") orelse return error.NoRegion;
    const piece = arena.take(sys, 2560) orelse return error.NoMemory;
    try testing.expectEqual(@as(usize, 0), piece.pixels % 64);
    try testing.expect(piece.offset >= @intFromPtr(&dma_ram) and piece.offset + piece.taken <= @intFromPtr(&dma_ram) + dma_ram.len);
    try testing.expect(arena.largest(sys) != 0);
    arena.give(sys, piece.offset, piece.taken);
    try testing.expectEqual(@as(usize, 2 * 2560), arena.free_bytes);
    arena.deinit(sys);
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
    try testing.expect(base(rb).AllocBitMap(board, 8, 8, 99, 0) == null);

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

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null, 0, 0));
    try testing.expect(base(rb).BoardDisplayBitMap(board) == null);
    try testing.expect(up.flags & rtg.bitmaps.RTGBMF_SHOWING == 0);

    base(rb).FreeBitMap(up);
    base(rb).FreeBitMap(hidden);
    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "showing buffers in bands, and what may not be shown so" {
    const rb = try setUp();
    defer kexec.deinit();
    const board = try makeBoard(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    board.info.width = 16;
    board.info.height = 16;
    const fk = fakeOf(rb);

    const back = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const front = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const hidden = base(rb).AllocBitMap(board, 16, 16, format, 0).?;
    const small = base(rb).AllocBitMap(board, 16, 8, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;

    // The back buffer from the top, the front one from line 6 on, its own
    // first row there.
    const two = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = front, .line = 6, .origin = 6 } };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMapBands(board, &two, two.len));
    try testing.expectEqual(@as(u32, 2), fk.log.band_count);
    try testing.expectEqual(@as(u32, 6), fk.log.bands[1].line);
    try testing.expectEqual(front, base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(back.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);
    try testing.expect(front.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);

    // Lines out of order, a first band below the top, a buffer that
    // cannot be shown, one too short for its lines, none at all.
    const unordered = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = front, .line = 6 }, .{ .bitmap = back, .line = 4 } };
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).ShowBitMapBands(board, &unordered, unordered.len));
    const low = [_]rtg.RtgBand{.{ .bitmap = back, .line = 2 }};
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).ShowBitMapBands(board, &low, low.len));
    const unseen = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = hidden, .line = 8 } };
    try testing.expectEqual(rtg.errors.RTGERR_NOT_DISPLAYABLE, base(rb).ShowBitMapBands(board, &unseen, unseen.len));
    const short = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = small, .line = 4 } };
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).ShowBitMapBands(board, &short, short.len));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).ShowBitMapBands(board, &two, 0));
    // One row repeated over a band; a buffer of no rows refused for it.
    const row = base(rb).AllocBitMap(board, 16, 1, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const repeated = [_]rtg.RtgBand{ .{ .bitmap = row, .flags = rtg.RTGBANDF_REPEAT }, .{ .bitmap = front, .line = 6, .origin = 6 } };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMapBands(board, &repeated, repeated.len));
    try testing.expectEqual(@as(u32, 0), repeated[0].rowAt(5));
    try testing.expectEqual(@as(u32, 0), repeated[0].linesOf(0, 1, 6).first);
    try testing.expectEqual(@as(u32, 6), repeated[0].linesOf(0, 1, 6).end);
    try testing.expectEqual(@as(u32, 4), repeated[1].rowAt(10));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMapBands(board, &two, two.len));
    base(rb).FreeBitMap(row);
    try testing.expectEqual(@as(u32, 3), fk.log.bands_shown);

    // One buffer again: the other is no longer read.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, back, 0, 0));
    try testing.expect(front.flags & rtg.bitmaps.RTGBMF_SHOWING == 0);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null, 0, 0));

    base(rb).FreeBitMap(small);
    base(rb).FreeBitMap(hidden);
    base(rb).FreeBitMap(front);
    base(rb).FreeBitMap(back);
    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

/// What the driver saw of the board's lock while it worked: how often it
/// was held by the task that called, and how often not.
const Held = struct {
    var seen: u32 = 0;
    var missed: u32 = 0;

    /// The fake board's `meanwhile`: the lock of the board it works on is
    /// the calling task's.
    fn look(board: *rtg.RtgBoard) void {
        const lock = &boards.privateOf(board).lock;
        if (lock.owner == kexec.FindTask(kexec.SysBase, null) and lock.nestCount() != 0) seen += 1 else missed += 1;
    }

    /// Whether nothing holds the lock of `board`.
    fn free(board: *rtg.RtgBoard) bool {
        const lock = &boards.privateOf(board).lock;
        return lock.owner == null and lock.nestCount() == 0;
    }
};

test "the board's lock: held around the driver's show and mode, free after every call" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    Held.seen = 0;
    Held.missed = 0;
    fk.meanwhile = &Held.look;
    try testing.expect(Held.free(board));

    // The mode: the driver is asked under the lock, and the picture taken
    // down inside it is too.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardMode(board, null));
    try testing.expectEqual(@as(u32, 1), Held.seen);
    try testing.expect(Held.free(board));
    board.info.width = 16;
    board.info.height = 16;

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
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, back, 0, 0));
    try testing.expectEqual(@as(u32, 2), Held.seen);
    try testing.expect(Held.free(board));
    const two = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = front, .line = 6, .origin = 6 } };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMapBands(board, &two, two.len));
    try testing.expectEqual(@as(u32, 3), Held.seen);
    try testing.expect(Held.free(board));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_DISPLAYABLE, base(rb).ShowBitMap(board, attached, 0, 0));
    try testing.expectEqual(@as(u32, 3), Held.seen);
    try testing.expect(Held.free(board));
    const out_of_order = [_]rtg.RtgBand{ .{ .bitmap = back, .line = 2 }, .{ .bitmap = front, .line = 6, .origin = 6 } };
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).ShowBitMapBands(board, &out_of_order, out_of_order.len));
    try testing.expect(Held.free(board));
    fk.show_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, base(rb).ShowBitMap(board, front, 0, 0));
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

    // A mode change refused for a buffer that keeps its memory.
    try testing.expectEqual(rtg.errors.RTGERR_IN_USE, base(rb).SetBoardMode(board, null));
    try testing.expect(Held.free(board));

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null, 0, 0));
    try testing.expectEqual(@as(u32, 5), Held.seen);
    // The driver never worked without it.
    try testing.expectEqual(@as(u32, 0), Held.missed);
    base(rb).FreeBitMap(front);
    base(rb).FreeBitMap(back);
    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a buffer: a format that is none, and a board with no display memory" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);

    // A number past every format is refused as a format not known.
    const board = try makeBoard(rb);
    try testing.expect(base(rb).AllocBitMap(board, 8, 8, 256, 0) == null);
    try testing.expect(base(rb).AllocBitMap(board, 8, 8, ~@as(u32, 0), 0) == null);
    base(rb).DeleteBoard(board);

    // A board that reports no display memory says so, and no memory was
    // taken for the buffer's handle: the leak check holds that.
    fk.region_size = 0;
    const dark = try makeBoard(rb);
    try testing.expect(base(rb).AllocBitMap(dark, 8, 8, format, 0) == null);
    base(rb).DeleteBoard(dark);
    try tearDown(rb);
}

test "boards are numbered as they are made, and one that was not made takes no number" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);

    const first = try makeBoard(rb);
    try testing.expectEqualStrings("fake0", std.mem.span(first.node.name.?));
    fk.create_answer = rtg.errors.RTGERR_NO_DISPLAY;
    try testing.expect(base(rb).CreateBoardTagList("fake", null) == null);
    fk.create_answer = rtg.errors.RTGERR_OK;
    const second = try makeBoard(rb);
    try testing.expectEqualStrings("fake1", std.mem.span(second.node.name.?));
    try testing.expectEqual(second.node.name, second.info.name);

    base(rb).DeleteBoard(second);
    base(rb).DeleteBoard(first);
    try tearDown(rb);
}

/// How often a new picture was shown on `board`, as the library counts.
fn swapsOf(rb: *RtgBase, board: *rtg.RtgBoard) u32 {
    var stats: rtg.RtgBoardStats = .{};
    _ = base(rb).GetBoardStats(board, &stats, @sizeOf(rtg.RtgBoardStats));
    return stats.buffer_swaps;
}

/// The display memory of `board` not handed out.
fn freeOf(rb: *RtgBase, board: *rtg.RtgBoard) usize {
    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    return info.memory_free;
}

test "a show that fails changes nothing: the buffer shown stays, the one refused can go" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    const glass = fake.instanceOf(board);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const showing = rtg.bitmaps.RTGBMF_SHOWING;
    const first = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const second = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;

    // The board is handed what was asked for: the buffer, and x and y.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, first, 3, 5));
    try testing.expectEqual(first, fk.log.last_show_bitmap.?);
    try testing.expectEqual(@as(u32, 3), fk.log.last_show_x);
    try testing.expectEqual(@as(u32, 5), fk.log.last_show_y);
    try testing.expectEqual(@as(u32, 1), glass.showing_count);
    try testing.expectEqual(first, glass.showing[0].bitmap);
    // A show that works is a picture counted.
    const swaps = swapsOf(rb, board);
    try testing.expectEqual(@as(u32, 1), swaps);

    // Refused: the answer is the driver's, and neither side has moved -
    // the library's marks, what it answers, its count of pictures, and
    // what the board itself shows.
    fk.show_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, base(rb).ShowBitMap(board, second, 0, 0));
    try testing.expectEqual(second, fk.log.last_show_bitmap.?);
    try testing.expectEqual(first, base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(first.flags & showing != 0);
    try testing.expect(second.flags & showing == 0);
    try testing.expectEqual(swaps, swapsOf(rb, board));
    try testing.expectEqual(@as(u32, 1), glass.showing_count);
    try testing.expectEqual(first, glass.showing[0].bitmap);

    // The one still shown cannot be freed; the one refused can.
    base(rb).FreeBitMap(first);
    try testing.expectEqual(first, base(rb).BoardDisplayBitMap(board).?);
    const free_before = freeOf(rb, board);
    base(rb).FreeBitMap(second);
    try testing.expect(freeOf(rb, board) > free_before);

    // Showing nothing refused: the picture stays up, and stays marked.
    fk.show_answer = rtg.errors.RTGERR_NO_DISPLAY;
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, base(rb).ShowBitMap(board, null, 0, 0));
    try testing.expectEqual(first, base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(first.flags & showing != 0);
    try testing.expect(board.info.flags & rtg.boards.RTGBF_SHOWING != 0);
    try testing.expectEqual(@as(u32, 1), glass.showing_count);

    // The refusal was that show's alone: the next one works.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null, 0, 0));
    try testing.expect(base(rb).BoardDisplayBitMap(board) == null);
    try testing.expectEqual(@as(u32, 0), glass.showing_count);

    base(rb).FreeBitMap(first);
    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "bands that fail change nothing: what was shown stays, in the library and on the board" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    const glass = fake.instanceOf(board);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const showing = rtg.bitmaps.RTGBMF_SHOWING;
    board.info.width = 16;
    board.info.height = 16;
    const back = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const front = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const third = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const two = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = front, .line = 6, .origin = 6 } };

    // One buffer up, then bands the board refuses: the one buffer stays,
    // and no picture is counted.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, back, 0, 0));
    const swaps = swapsOf(rb, board);
    fk.show_answer = rtg.errors.RTGERR_NO_MEMORY;
    try testing.expectEqual(rtg.errors.RTGERR_NO_MEMORY, base(rb).ShowBitMapBands(board, &two, two.len));
    try testing.expectEqual(swaps, swapsOf(rb, board));
    try testing.expectEqual(@as(u32, 2), fk.log.band_count); // it was asked
    try testing.expectEqual(back, base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(back.flags & showing != 0);
    try testing.expect(front.flags & showing == 0);
    try testing.expectEqual(@as(u32, 1), glass.showing_count);
    try testing.expectEqual(back, glass.showing[0].bitmap);

    // The same bands again, and they are up on both sides: a picture.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMapBands(board, &two, two.len));
    try testing.expectEqual(swaps + 1, swapsOf(rb, board));
    try testing.expectEqual(front, base(rb).BoardDisplayBitMap(board).?);
    try testing.expectEqual(@as(u32, 2), glass.showing_count);
    try testing.expectEqual(@as(u32, 6), glass.showing[1].line);

    // A buffer refused over bands: the bands stay, and the buffer can go.
    fk.show_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, base(rb).ShowBitMap(board, third, 0, 0));
    try testing.expectEqual(front, base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(back.flags & showing != 0 and front.flags & showing != 0);
    try testing.expect(third.flags & showing == 0);
    try testing.expectEqual(@as(u32, 2), glass.showing_count);
    base(rb).FreeBitMap(third);

    // One of the bands' own buffers refused alone: it is still up in its
    // band, so it stays marked.
    fk.show_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, base(rb).ShowBitMap(board, front, 0, 0));
    try testing.expect(front.flags & showing != 0);
    try testing.expectEqual(@as(u32, 2), glass.showing_count);

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null, 0, 0));
    base(rb).FreeBitMap(front);
    base(rb).FreeBitMap(back);
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

    // A rectangle, on a board with no way of its own: its rows, cut to
    // the buffer; one with nothing inside reaches no driver.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(bitmap, &.{ .x = 3, .y = 4, .width = 5, .height = 6 }));
    try testing.expectEqual(@as(u32, 4), fk.log.last_refresh_y);
    try testing.expectEqual(@as(u32, 6), fk.log.last_refresh_rows);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(bitmap, &.{ .x = 30, .y = -2, .width = 8, .height = 5 }));
    try testing.expectEqual(@as(u32, 0), fk.log.last_refresh_y);
    try testing.expectEqual(@as(u32, 3), fk.log.last_refresh_rows);
    const refreshed = fk.log.refreshed;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(bitmap, &.{ .x = 32, .y = 0, .width = 4, .height = 4 }));
    try testing.expectEqual(refreshed, fk.log.refreshed);

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
    try testing.expectEqual(board, base(rb).NextBoard(null).?);
    base(rb).RemRtgEventServer(board, rtg.events.RTGEV_VBLANK, &low);

    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

/// The board the frames of the next tests end on.
var frames_board: ?*rtg.RtgBoard = null;

fn endOneFrame() void {
    fake.endFrame(frames_board.?);
}

/// A frame ends - or, where an abort's reply is still to be made, that
/// reply lands.
fn frameOrLanding() void {
    if (FakeTimer.leaving != null) FakeTimer.land() else endOneFrame();
}

test "WaitVBlank: woken by the board's frames, the limit's request taken back" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    const blankings = &board.event_lists[rtg.events.RTGEV_VBLANK];
    // The library's own request, which every wait copies and none sends.
    const opened = rb.timer_io;
    try testing.expectEqual(timer.UNIT_MICROHZ, FakeTimer.opened_unit);
    frames_board = board;
    Sleep.install(&endOneFrame);
    defer Sleep.uninstall();

    // The next blanking: the task sleeps once, and the frame that ends
    // meanwhile wakes it. The limit never came, and is taken back; the
    // wait's server is off the board.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).WaitVBlank(board, 0));
    try testing.expect(blankings.isEmpty());
    try testing.expectEqual(@as(u32, 1), Sleep.sleeps);
    try testing.expectEqual(@as(u32, 1), fk.log.frames_ended);
    try testing.expectEqual(@as(u32, 1), FakeTimer.sent);
    try testing.expectEqual(@as(u32, 1), FakeTimer.aborted);
    try testing.expect(FakeTimer.waiting == null);
    try testing.expect(FakeTimer.last.? != &rb.timer_io.node);
    try testing.expectEqual(opened, rb.timer_io);
    // Two frames' time for the one asked, a frame a sixtieth of a second
    // on a board that names no rate.
    try testing.expectEqual(@as(u64, 2 * 16_667), FakeTimer.last_micros);

    // Three of them: one sleep through all three, woken by the third,
    // and the limit three times as long - by the board's own rate, 50 a
    // second here.
    board.info.refresh_mhz = 50_000;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).WaitVBlank(board, 3));
    try testing.expect(blankings.isEmpty());
    try testing.expectEqual(@as(u32, 2), Sleep.sleeps);
    try testing.expectEqual(@as(u32, 4), Sleep.interrupts);
    try testing.expectEqual(@as(u32, 4), fk.log.frames_ended);
    try testing.expectEqual(@as(u64, 3 * 2 * 20_000), FakeTimer.last_micros);
    try testing.expectEqual(@as(u32, 2), FakeTimer.aborted);
    try testing.expectEqual(opened, rb.timer_io);

    // An abort answered before its reply is made: the wait goes on until
    // the reply has landed - a sleep more - so none is left to land on a
    // port that has gone with the call.
    FakeTimer.abort_replies_later = true;
    Sleep.meanwhile = &frameOrLanding;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).WaitVBlank(board, 1));
    try testing.expect(FakeTimer.leaving == null);
    try testing.expect(blankings.isEmpty());
    try testing.expectEqual(@as(u32, 4), Sleep.sleeps);
    try testing.expectEqual(@as(u32, 6), Sleep.interrupts);
    try testing.expectEqual(@as(u32, 5), fk.log.frames_ended);
    try testing.expectEqual(@as(u32, 3), FakeTimer.aborted);
    try testing.expectEqual(opened, rb.timer_io);
    FakeTimer.abort_replies_later = false;

    base(rb).DeleteBoard(board);
    try testing.expect(base(rb).NextBoard(null) == null);
    try tearDown(rb);
}

test "WaitVBlank: a board that sends no frames is waited for no longer than the limit" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    const blankings = &board.event_lists[rtg.events.RTGEV_VBLANK];
    Sleep.install(&FakeTimer.expire);
    defer Sleep.uninstall();

    // No frame ends: the limit's time passes while the task sleeps, and
    // the wait's server is off the board all the same.
    try testing.expectEqual(rtg.errors.RTGERR_TIMEOUT, base(rb).WaitVBlank(board, 2));
    try testing.expect(blankings.isEmpty());
    try testing.expectEqual(@as(u32, 1), Sleep.sleeps);
    try testing.expectEqual(@as(u32, 0), fk.log.frames_ended);
    try testing.expectEqual(@as(u64, 2 * 2 * 16_667), FakeTimer.last_micros);
    try testing.expectEqual(@as(u32, 0), FakeTimer.aborted);
    try testing.expect(FakeTimer.waiting == null);

    // One frame of the two, and then no more: the frame wakes nobody,
    // and the limit ends the wait all the same.
    frames_board = board;
    frames_then_time = 0;
    Sleep.meanwhile = &oneFrameThenTime;
    try testing.expectEqual(rtg.errors.RTGERR_TIMEOUT, base(rb).WaitVBlank(board, 2));
    try testing.expect(blankings.isEmpty());
    try testing.expectEqual(@as(u32, 1), fk.log.frames_ended);
    try testing.expectEqual(@as(u32, 2), Sleep.sleeps);
    try testing.expectEqual(@as(u32, 3), Sleep.interrupts);

    // A board that signals no blankings is not waited for, and neither is
    // one where there is no clock to end the wait by.
    board.info.flags &= ~rtg.boards.RTGBF_STREAMING;
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).WaitVBlank(board, 1));
    board.info.flags |= rtg.boards.RTGBF_STREAMING;
    const device = rb.timer_io.node.device;
    rb.timer_io.node.device = null;
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).WaitVBlank(board, 1));
    rb.timer_io.node.device = device;
    try testing.expectEqual(@as(u32, 2), FakeTimer.sent);

    // A driver with a wait of its own is asked, with the count as given,
    // and what it answers is the call's answer.
    var ops = board.ops.?.*;
    ops.wait_vblank = &fake.waitVBlank;
    const kept = board.ops;
    board.ops = &ops;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).WaitVBlank(board, 0));
    try testing.expectEqual(@as(u32, 1), fk.log.vblank_waits);
    try testing.expectEqual(@as(u32, 0), fk.log.last_wait_frames);
    fk.wait_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, base(rb).WaitVBlank(board, 7));
    try testing.expectEqual(@as(u32, 7), fk.log.last_wait_frames);
    try testing.expectEqual(@as(u32, 2), FakeTimer.sent);
    board.ops = kept;

    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

/// How often `oneFrameThenTime` ran.
var frames_then_time: u32 = 0;

/// The first interrupt ends a frame, which is not yet the count; the
/// next lets the limit's time pass.
fn oneFrameThenTime() void {
    frames_then_time += 1;
    if (frames_then_time == 1) endOneFrame() else FakeTimer.expire();
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

test "several copies go to the board as one job, each cut down, or one by one" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const source = base(rb).AllocBitMap(board, 16, 8, format, 0).?;
    const target = base(rb).AllocBitMap(board, 8, 8, format, 0).?;
    for (0..8) |y| {
        const row: [*]u16 = @ptrCast(@alignCast(source.rowPtr(@intCast(y))));
        for (0..16) |x| row[x] = @intCast(y * 16 + x + 1);
    }

    // Three pieces: one whole, one cut at the destination's edge, one
    // wholly off it, which the board never sees.
    const pieces = [_]rtg.RtgCopy{
        .{ .src_x = 0, .src_y = 0, .width = 4, .height = 2, .dest_x = 0, .dest_y = 0 },
        .{ .src_x = 8, .src_y = 4, .width = 6, .height = 3, .dest_x = 4, .dest_y = 5 },
        .{ .src_x = 0, .src_y = 0, .width = 4, .height = 4, .dest_x = 9, .dest_y = 0 },
    };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).CopyRects(source, target, &pieces, pieces.len));
    try testing.expectEqual(@as(u32, 1), fk.log.copy_jobs);
    try testing.expectEqual(@as(u32, 2), fk.log.last_copy_count);
    try testing.expectEqual(@as(u32, 2), fk.log.copies);
    try testing.expectEqual(@as(i32, 4), fk.log.last_copy.width);
    const row1: [*]u16 = @ptrCast(@alignCast(target.rowPtr(1)));
    const row7: [*]u16 = @ptrCast(@alignCast(target.rowPtr(7)));
    try testing.expectEqual(@as(u16, 1 * 16 + 3 + 1), row1[3]);
    try testing.expectEqual(@as(u16, 6 * 16 + 11 + 1), row7[7]);

    // More than a call takes is cut into calls.
    var many: [rtg.RTG_MAX_COPIES + 3]rtg.RtgCopy = undefined;
    for (&many, 0..) |*one, i| one.* = .{ .src_x = @intCast(i % 16), .src_y = 0, .width = 1, .height = 1, .dest_x = @intCast(i % 8), .dest_y = @intCast(i / 8) };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).CopyRects(source, target, &many, many.len));
    try testing.expectEqual(@as(u32, 3), fk.log.copy_jobs);
    try testing.expectEqual(@as(u32, 3), fk.log.last_copy_count);

    // A board without the call is given them one at a time.
    const kept = board.ops;
    var ops = board.ops.?.*;
    ops.copy_rects = null;
    board.ops = &ops;
    const copies = fk.log.copies;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).CopyRects(source, target, &pieces, pieces.len));
    try testing.expectEqual(@as(u32, 3), fk.log.copy_jobs);
    try testing.expectEqual(copies + 2, fk.log.copies);
    board.ops = kept;

    // Onto itself is not several copies at once.
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).CopyRects(source, source, &pieces, 1));

    base(rb).FreeBitMap(target);
    base(rb).FreeBitMap(source);
    base(rb).DeleteBoard(board);
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
    const row: [*]u16 = @ptrCast(@alignCast(bitmap.rowPtr(0)));
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
    try testing.expectEqual(@as(u16, 0x001F), @as([*]u16, @ptrCast(@alignCast(bitmap.rowPtr(7))))[15]);

    // A scale is not cut: one over the edge is not the board's to try.
    const scales = fk.log.scales;
    const over_edge = rtg.RtgRect{ .x = 8, .y = 0, .width = 16, .height = 2 };
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).ScalePixels(bitmap, &over_edge, &pixels, 4, 1));
    try testing.expectEqual(scales, fk.log.scales);
    const inside = rtg.RtgRect{ .x = 0, .y = 0, .width = 8, .height = 2 };
    _ = base(rb).ScalePixels(bitmap, &inside, &pixels, 4, 1);
    try testing.expectEqual(scales + 1, fk.log.scales);
    try testing.expectEqual(@as(u32, 4), fk.log.last_scale_width);

    base(rb).FreeBitMap(bitmap);
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
    const row: [*]u16 = @ptrCast(@alignCast(bitmap.rowPtr(0)));
    try testing.expectEqual(@as(u16, 0), row[0]);

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

test "the counters are reset on every board, with a control of its own or without" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const reset = rtg.boards.RTGCTRL_RESET_STATS;

    // A board whose driver has a control: the library's count is cleared,
    // the driver is handed the code for its own, and the answer is the
    // library's, whatever the driver made of it.
    const board = try makeBoard(rb);
    const shown = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, shown, 0, 0));
    try testing.expectEqual(@as(u32, 1), swapsOf(rb, board));
    try testing.expectEqual(@as(isize, rtg.errors.RTGERR_OK), base(rb).BoardControl(board, reset, 7));
    try testing.expectEqual(reset, fk.log.last_control);
    try testing.expectEqual(@as(u32, 0), swapsOf(rb, board));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null, 0, 0));
    base(rb).FreeBitMap(shown);
    base(rb).DeleteBoard(board);

    // A board whose driver has none takes it all the same, and no other
    // code.
    fk.without_engine = true;
    const plain = try makeBoard(rb);
    const picture = base(rb).AllocBitMap(plain, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(plain, picture, 0, 0));
    try testing.expectEqual(@as(u32, 1), swapsOf(rb, plain));
    const controls = fk.log.control_calls;
    try testing.expectEqual(@as(isize, rtg.errors.RTGERR_OK), base(rb).BoardControl(plain, reset, 0));
    try testing.expectEqual(@as(u32, 0), swapsOf(rb, plain));
    try testing.expectEqual(controls, fk.log.control_calls);
    try testing.expectEqual(@as(isize, rtg.errors.RTGERR_NOT_SUPPORTED), base(rb).BoardControl(plain, rtg.tags.RTGCTRL_RGB_SHIFT, 7));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(plain, null, 0, 0));
    base(rb).FreeBitMap(picture);
    base(rb).DeleteBoard(plain);
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
    // A board reports itself the right way up until it is turned.
    try testing.expectEqual(@as(u8, 0), info.mirror_x);
    try testing.expectEqual(@as(u8, 0), info.mirror_y);

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardMode(board, null));
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    const was_width = info.width;
    const was_height = info.height;

    // Mirroring is remembered and handed to the board as asked, and what
    // a caller draws on keeps its sides.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).MirrorBoard(board, true, false));
    try testing.expectEqual(@as(u32, 1), fk.log.mirrors);
    try testing.expect(fk.log.last_mirror_x and !fk.log.last_mirror_y);
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u8, 1), info.mirror_x);
    try testing.expectEqual(@as(u8, 0), info.mirror_y);
    try testing.expectEqual(was_width, info.width);
    try testing.expectEqual(was_height, info.height);

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

    const width = info.width;
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).MirrorBoard(board, true, true));
    // Refused means nothing moved: what it says about itself is unchanged.
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(width, info.width);
    try testing.expectEqual(@as(u8, 0), info.mirror_x);
    try testing.expectEqual(@as(u8, 0), info.mirror_y);
    try testing.expectEqual(@as(u32, 0), fk.log.mirrors);

    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

/// A pixel written 0xRRGGBBAA as rgba32 lays it out in memory: red,
/// green, blue and alpha, a byte each.
fn rgba(value: u32) u32 {
    return @byteSwap(value);
}

test "the pointer: converted once, placed by its point, shown and hidden" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardMode(board, null));
    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expect(info.caps & rtg.boards.RTGBC_POINTER != 0);

    // Three by two, rgba32: a red pixel, a clear one, a green one, and a
    // row of blue with a half-clear pixel in the middle.
    var pixels = [_]u32{ rgba(0xFF0000FF), rgba(0x12345600), rgba(0x00FF00FF), rgba(0x0000FFFF), rgba(0x0000FF7F), rgba(0x0000FFFF) };
    const image = rtg.Surface{ .pixels = @ptrCast(&pixels), .width = 3, .height = 2, .pitch = 12, .format = .rgba32 };

    // Placed before there is an image: the image arrives there.
    base(rb).MoveBoardPointer(board, 20, 30);
    try testing.expectEqual(@as(u32, 0), fk.log.pointer_moves);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, &image, 1, 1));
    const made = fk.log.pointer_image.?;
    try testing.expectEqual(made, board.pointer.?);
    try testing.expectEqual(rtg.PixelFormat.rgb565, made.format);
    try testing.expect(made.opaqueAt(0, 0) and !made.opaqueAt(1, 0) and made.opaqueAt(2, 0));
    try testing.expect(made.opaqueAt(0, 1) and !made.opaqueAt(1, 1) and made.opaqueAt(2, 1));
    const row0: [*]const u16 = @ptrCast(@alignCast(made.pixels));
    const row1: [*]const u16 = @ptrCast(@alignCast(made.pixels + made.pitch));
    try testing.expectEqual(@as(u16, 0xF800), row0[0]);
    try testing.expectEqual(@as(u16, 0x07E0), row0[2]);
    try testing.expectEqual(@as(u16, 0x001F), row1[0]);
    // The top left, from the point.
    try testing.expectEqual(@as(i32, 19), fk.log.pointer_left);
    try testing.expectEqual(@as(i32, 29), fk.log.pointer_top);

    base(rb).MoveBoardPointer(board, -1, 5);
    try testing.expectEqual(@as(i32, -2), fk.log.pointer_left);
    try testing.expectEqual(@as(i32, 4), fk.log.pointer_top);
    // The same place again is no move.
    const moves = fk.log.pointer_moves;
    base(rb).MoveBoardPointer(board, -1, 5);
    try testing.expectEqual(moves, fk.log.pointer_moves);

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoardPointer(board, true));
    try testing.expect(fk.log.pointer_shown);
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expect(info.flags & rtg.boards.RTGBF_POINTER != 0);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoardPointer(board, false));
    try testing.expect(!fk.log.pointer_shown);

    // What will not do leaves the image it had.
    var opaque_only = [_]u16{ 0xF800, 0x001F };
    const no_alpha = rtg.Surface{ .pixels = @ptrCast(&opaque_only), .width = 2, .height = 1, .pitch = 4, .format = .rgb565 };
    try testing.expectEqual(rtg.errors.RTGERR_BAD_FORMAT, base(rb).SetBoardPointer(board, &no_alpha, 0, 0));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).SetBoardPointer(board, &image, 3, 0));
    const huge = rtg.Surface{ .pixels = @ptrCast(&pixels), .width = rtg.boards.RTG_POINTER_MAX + 1, .height = 1, .pitch = 4, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).SetBoardPointer(board, &huge, 0, 0));
    try testing.expectEqual(made, board.pointer.?);

    // A second image replaces the first; null takes it away.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, &image, 0, 0));
    try testing.expectEqual(@as(u32, 2), fk.log.pointer_sets);
    try testing.expectEqual(@as(i32, -1), fk.log.pointer_left);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, null, 0, 0));
    try testing.expect(board.pointer == null);
    try testing.expect(fk.log.pointer_image == null);

    // An image still set when the board goes is freed with it.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, &image, 0, 0));
    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "the pointer on a 32-bit board: its channels in the order the format names them" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardMode(board, null));
    board.info.format = .bgra32;

    // A red pixel and a grey one, rgba32.
    var pixels = [_]u32{ rgba(0xFF0000FF), rgba(0x102030FF) };
    const image = rtg.Surface{ .pixels = @ptrCast(&pixels), .width = 2, .height = 1, .pitch = 8, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, &image, 0, 0));
    const made = fk.log.pointer_image.?;
    try testing.expectEqual(rtg.PixelFormat.bgra32, made.format);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0xFF, 0xFF, 0x30, 0x20, 0x10, 0xFF }, made.pixels[0..8]);

    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "the overlay: its coverage dithered, following the pointer, placed on its own, freed with the board" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardMode(board, null));
    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expect(info.caps & rtg.boards.RTGBC_OVERLAY != 0);

    // Eight by four, rgba32: a row of full coverage, a row of none, two
    // rows at half.
    var pixels: [32]u32 = undefined;
    for (&pixels, 0..) |*pixel, i| pixel.* = rgba(switch (i / 8) {
        0 => 0xFF0000FF,
        1 => 0xFF000000,
        else => 0x00FF0080,
    });
    const image = rtg.Surface{ .pixels = @ptrCast(&pixels), .width = 8, .height = 4, .pitch = 32, .format = .rgba32 };

    base(rb).MoveBoardPointer(board, 100, 50);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardOverlay(board, &image, 4, 2));
    const made = fk.log.overlay_image.?;
    try testing.expectEqual(made, board.overlay.?);
    for (0..8) |x| {
        try testing.expect(made.opaqueAt(@intCast(x), 0)); // full: every pixel
        try testing.expect(!made.opaqueAt(@intCast(x), 1)); // none: no pixel
    }
    var half: u32 = 0;
    for (2..4) |y| for (0..8) |x| {
        if (made.opaqueAt(@intCast(x), @intCast(y))) half += 1;
    };
    try testing.expectEqual(@as(u32, 8), half); // half: half of them, as dots
    // Its point at the pointer's, and with the pointer when it moves.
    try testing.expectEqual(@as(i32, 96), fk.log.overlay_left);
    try testing.expectEqual(@as(i32, 48), fk.log.overlay_top);
    base(rb).MoveBoardPointer(board, 110, 60);
    try testing.expectEqual(@as(i32, 106), fk.log.overlay_left);
    try testing.expectEqual(@as(i32, 58), fk.log.overlay_top);

    // Placed on its own, it stays when the pointer moves on.
    base(rb).MoveBoardOverlay(board, 20, 30);
    try testing.expectEqual(@as(i32, 16), fk.log.overlay_left);
    try testing.expectEqual(@as(i32, 28), fk.log.overlay_top);
    const moves = fk.log.overlay_moves;
    base(rb).MoveBoardPointer(board, 200, 200);
    try testing.expectEqual(moves, fk.log.overlay_moves);
    base(rb).MoveBoardOverlay(board, 20, 30); // the same place: no move
    try testing.expectEqual(moves, fk.log.overlay_moves);

    // A new image follows the pointer again; too large is refused and the
    // one there stays.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardOverlay(board, &image, 0, 0));
    try testing.expectEqual(@as(i32, 200), fk.log.overlay_left);
    const huge = rtg.Surface{ .pixels = @ptrCast(&pixels), .width = rtg.boards.RTG_OVERLAY_MAX + 1, .height = 1, .pitch = 4, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).SetBoardOverlay(board, &huge, 0, 0));
    try testing.expect(board.overlay != null);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardOverlay(board, null, 0, 0));
    try testing.expect(board.overlay == null and fk.log.overlay_image == null);

    // One still set when the board goes is freed with it.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardOverlay(board, &image, 0, 0));
    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a board with no pointer says so" {
    const rb = try setUp();
    defer kexec.deinit();
    fakeOf(rb).without_engine = true;
    const board = try makeBoard(rb);
    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u32, 0), info.caps & rtg.boards.RTGBC_POINTER);
    var pixel = [_]u32{0xFFFFFFFF};
    const image = rtg.Surface{ .pixels = @ptrCast(&pixel), .width = 1, .height = 1, .pitch = 4, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).SetBoardPointer(board, &image, 0, 0));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).ShowBoardPointer(board, true));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).SetBoardOverlay(board, &image, 0, 0));
    base(rb).MoveBoardPointer(board, 3, 3);
    base(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "video layers: one to a board, a picture needs its part, the limits kept, closed before the board goes" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expect(info.caps & rtg.boards.RTGBC_VIDEO != 0);

    // A layer is asked for a kind of picture, and a board whose converter
    // cannot make the display's colours out of it hands out none: a film
    // of high dynamic range, one in BT.2020's colours, one of ten bits.
    // Nothing is taken by a refusal.
    const kinds = [_]TagItem{
        .{ .tag = rtg.RTGVA_Transfer, .data = rtg.RTGYUV_PQ },
        .{ .tag = rtg.RTGVA_Transfer, .data = rtg.RTGYUV_HLG },
        .{ .tag = rtg.RTGVA_Primaries, .data = rtg.RTGYUV_BT2020 },
        .{ .tag = rtg.RTGVA_Matrix, .data = rtg.RTGYUV_BT2020 },
        .{ .tag = rtg.RTGVA_Depth, .data = 10 },
    };
    for (kinds) |one| {
        try testing.expect(base(rb).OpenVideoLayer(board, &[_]TagItem{ one, .{} }) == null);
    }
    try testing.expectEqual(@as(u32, 0), fk.log.video_opens);

    // Under the picture unless asked otherwise, with its key and limits;
    // the board's one layer is then taken. What it was asked for stays in
    // its fields, where the driver read them.
    const layer = base(rb).OpenVideoLayer(board, &[_]TagItem{ .{ .tag = rtg.RTGVA_Matrix, .data = rtg.RTGYUV_BT601 }, .{ .tag = rtg.RTGVA_Range, .data = rtg.RTGYUV_FULL }, .{} }) orelse return error.NoLayer;
    try testing.expectEqual(rtg.RTGYUV_BT601, layer.matrix);
    try testing.expectEqual(rtg.RTGYUV_FULL, layer.range);
    try testing.expectEqual(rtg.RTGYUV_SDR, layer.transfer);
    try testing.expectEqual(rtg.RTGYUV_BT709, layer.primaries);
    try testing.expectEqual(@as(u8, 8), layer.depth);
    try testing.expectEqual(board, layer.board);
    try testing.expect(layer.flags & rtg.RTGVLF_UNDER != 0);
    try testing.expectEqual(@as(u32, 0x0008_0008), layer.key);
    try testing.expectEqual(@as(u32, 3), layer.max_up);
    try testing.expect(base(rb).OpenVideoLayer(board, null) == null);

    // A picture is shown with its part, which says how big it is.
    var luma: [16]u8 = @splat(16);
    var chroma: [8]u8 = @splat(128);
    const picture = rtg.RtgYuv{ .y = &luma, .cb = &chroma, .y_pitch = 4, .c_pitch = 4 };
    const all = rtg.RtgRect{ .width = 4, .height = 4 };
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).ShowVideoFrame(layer, &picture, null));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).ShowVideoFrame(layer, &picture, &.{ .width = 0, .height = 4 }));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).ShowVideoFrame(layer, &picture, &.{ .x = 4090, .width = 8, .height = 4 }));
    // A part at the end of the numbers is past the limit too, each way.
    const far = std.math.maxInt(i32);
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).ShowVideoFrame(layer, &picture, &.{ .x = far, .width = 8, .height = 4 }));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).ShowVideoFrame(layer, &picture, &.{ .y = far, .width = 4, .height = 8 }));
    try testing.expectEqual(@as(u32, 0), fk.log.video_shows);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).MoveVideoLayer(layer, &.{ .x = 10, .y = 20, .width = 12, .height = 12 }));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowVideoFrame(layer, &picture, &all));
    try testing.expectEqual(&picture, fk.log.video_picture.?);
    try testing.expectEqual(all, fk.log.video_src);

    // A place the picture cannot be scaled into is the driver's to refuse;
    // nothing shown takes no part.
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).MoveVideoLayer(layer, &.{ .width = 13, .height = 12 }));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowVideoFrame(layer, null, &all));
    try testing.expect(fk.log.video_picture == null);

    // The board is not deleted under an open layer.
    base(rb).DeleteBoard(board);
    try testing.expectEqual(@as(u32, 0), fk.log.destroyed);
    base(rb).CloseVideoLayer(layer);
    base(rb).CloseVideoLayer(null);
    try testing.expectEqual(@as(u32, 1), fk.log.video_closes);

    // Over the picture when asked, or when the board cannot lay its
    // picture over a layer: no key then.
    const over = base(rb).OpenVideoLayer(board, &[_]TagItem{ .{ .tag = rtg.RTGVA_Under, .data = 0 }, .{} }) orelse return error.NoLayer;
    try testing.expectEqual(@as(u32, 0), over.flags & rtg.RTGVLF_UNDER);
    base(rb).CloseVideoLayer(over);
    fk.video_over_only = true;
    const forced = base(rb).OpenVideoLayer(board, null) orelse return error.NoLayer;
    try testing.expectEqual(@as(u32, 0), forced.flags & rtg.RTGVLF_UNDER);
    try testing.expectEqual(@as(u32, 0), forced.key);
    base(rb).CloseVideoLayer(forced);
    base(rb).DeleteBoard(board);
    try testing.expectEqual(@as(u32, 1), fk.log.destroyed);
    try tearDown(rb);
}

test "a board with no video layer says so" {
    const rb = try setUp();
    defer kexec.deinit();
    fakeOf(rb).without_engine = true;
    const board = try makeBoard(rb);
    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u32, 0), info.caps & rtg.boards.RTGBC_VIDEO);
    try testing.expect(base(rb).OpenVideoLayer(board, null) == null);
    base(rb).DeleteBoard(board);
    try tearDown(rb);
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

/// What a watch hook was told: how often, and the last rectangle.
const Told = struct {
    calls: u32 = 0,
    rect: rtg.RtgRect = .{},

    fn hear(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
        _ = object;
        const told: *Told = @ptrCast(@alignCast(hook.data.?));
        told.calls += 1;
        told.rect = @as(*const rtg.RtgRect, @ptrCast(@alignCast(message.?))).*;
        return 0;
    }
};

test "a buffer with a watch hook: the hook is told what was written, and the board is not" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);

    // RTGA_Compose is the board's to keep, for intuition to read.
    const composing = [_]TagItem{ .{ .tag = rtg.tags.RTGA_Compose, .data = 1 }, .{} };
    const board = base(rb).CreateBoardTagList(fake.DRIVER_NAME, &composing) orelse return error.NoBoard;
    try testing.expect(board.info.flags & rtg.boards.RTGBF_COMPOSE != 0);
    const plain = try makeBoard(rb);
    try testing.expect(plain.info.flags & rtg.boards.RTGBF_COMPOSE == 0);

    var pixels: [8 * 4 * 2]u8 = @splat(0);
    const described = rtg.RtgBitMap{ .pixels = &pixels, .width = 8, .height = 4, .pitch = 16, .size_bytes = pixels.len, .format = .rgb565 };
    const bm = base(rb).AttachBitMap(board, &described) orelse return error.NoBitMap;
    var told: Told = .{};
    var hook = utility.Hook{ .entry = &Told.hear, .data = &told };
    bm.watch = &hook;

    const before = fk.log.refreshed;
    // Cut to the buffer, as the board would have had it.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(bm, &.{ .x = 2, .y = 1, .width = 20, .height = 2 }));
    try testing.expectEqual(@as(u32, 1), told.calls);
    try testing.expectEqual(rtg.RtgRect{ .x = 2, .y = 1, .width = 6, .height = 2 }, told.rect);
    // Rows are a rectangle the buffer's width.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshBitMap(bm, 3, 0));
    try testing.expectEqual(@as(u32, 2), told.calls);
    try testing.expectEqual(rtg.RtgRect{ .x = 0, .y = 3, .width = 8, .height = 1 }, told.rect);
    try testing.expectEqual(before, fk.log.refreshed);

    // Without the hook, the board hears of it again.
    bm.watch = null;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(bm, &.{ .width = 8, .height = 4 }));
    try testing.expectEqual(before + 1, fk.log.refreshed);
    try testing.expectEqual(@as(u32, 2), told.calls);

    base(rb).FreeBitMap(bm);
    base(rb).DeleteBoard(plain);
    base(rb).DeleteBoard(board);
    try tearDown(rb);
}
