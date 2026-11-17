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
//! driver/, device/, board/, mode/, monitor/, bitmap/, display/, engine/,
//! frame/, transport/, tag/, pointer/, video/ and errors/ - and memory/
//! holds the arena display memory is cut from.
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
const modes = @import("mode/_mode.zig");
const frame_state = @import("frame/_frame.zig");
const monitors = @import("monitor/_monitor.zig");
const edid = @import("monitor/_edid.zig");
const flips = @import("compose/_flip.zig");
const settings = @import("settings/_settings.zig");

test {
    _ = rtg_base;
    _ = rtg_init;
    _ = @import("rtg_lvo.zig");
    _ = @import("bitmap/_bitmap.zig");
    _ = @import("bitmap/allocbitmap.zig");
    _ = @import("bitmap/attachbitmap.zig");
    _ = @import("bitmap/freebitmap.zig");
    _ = @import("bitmap/lockbitmap.zig");
    _ = @import("bitmap/unlockbitmap.zig");
    _ = @import("bitmap/refreshrect.zig");
    _ = @import("compose/_compose.zig");
    _ = @import("compose/_damage.zig");
    _ = @import("compose/_flip.zig");
    _ = @import("compose/_scale.zig");
    _ = @import("compose/composelines.zig");
    _ = @import("bitmap/rtgformatbits.zig");
    _ = @import("bitmap/rtgrowbytes.zig");
    _ = @import("video/rtgcicp.zig");
    _ = @import("board/_board.zig");
    _ = @import("board/boardcontrol.zig");
    _ = @import("board/createboard.zig");
    _ = @import("board/deleteboard.zig");
    _ = @import("board/findboard.zig");
    _ = @import("board/getboardinfo.zig");
    _ = @import("board/getboardstats.zig");
    _ = @import("board/nextboard.zig");
    _ = @import("display/boarddisplaybitmap.zig");
    _ = @import("display/mirrorboard.zig");
    _ = @import("display/setboardbrightness.zig");
    _ = @import("display/setboardaudio.zig");
    _ = @import("display/setboardpower.zig");
    _ = @import("display/showbitmap.zig");
    _ = @import("display/showboard.zig");
    _ = @import("display/waitvblank.zig");
    _ = @import("driver/_driver.zig");
    _ = @import("driver/addrtgdriver.zig");
    _ = @import("driver/getrtgdrivers.zig");
    _ = @import("driver/remrtgdriver.zig");
    _ = @import("device/_device.zig");
    _ = @import("device/addrtgdevice.zig");
    _ = @import("device/bindrtgdrivers.zig");
    _ = @import("device/getrtgdevices.zig");
    _ = @import("device/remrtgdevice.zig");
    _ = @import("engine/_engine.zig");
    _ = @import("engine/blitpattern.zig");
    _ = @import("engine/blittemplate.zig");
    _ = @import("engine/copyrect.zig");
    _ = @import("engine/fillrect.zig");
    _ = @import("errors/rtgerrortext.zig");
    _ = @import("frame/_frame.zig");
    _ = @import("frame/framedone.zig");
    _ = @import("memory/_memory.zig");
    _ = @import("mode/_mode.zig");
    _ = @import("mode/addboardmode.zig");
    _ = @import("mode/bestboardmode.zig");
    _ = @import("mode/findboardmode.zig");
    _ = @import("mode/getboardmodes.zig");
    _ = @import("mode/readtimingtags.zig");
    _ = @import("monitor/_edid.zig");
    _ = @import("monitor/_monitor.zig");
    _ = @import("monitor/findstandardtimings.zig");
    _ = @import("monitor/buildaviinfoframe.zig");
    _ = @import("monitor/hdmiaudioclock.zig");
    _ = @import("monitor/getboardmonitor.zig");
    _ = @import("monitor/monitorchanged.zig");
    _ = @import("monitor/readboardedid.zig");
    _ = @import("board/addrtgnotify.zig");
    _ = @import("board/remrtgnotify.zig");
    _ = @import("tag/getrtgtagdata.zig");
    _ = @import("transport/_transport.zig");
    _ = @import("transport/opentransport.zig");
    _ = @import("transport/closetransport.zig");
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
const fakebus = @import("../rtg_driver/fakeboard/fakebus.zig");
const devices = @import("device/_device.zig");
const registry = @import("driver/_driver.zig");
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
/// board's driver put on the list: exec has no ROM here whose tags the
/// library could read for drivers.
fn setUp() !*RtgBase {
    try kexec.setUp();
    _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
    try FakeTimer.add();
    const made = kexec.InitResident(kexec.SysBase, &rtg_library_tag, null) orelse return error.NoRtg;
    const rb: *RtgBase = @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
    _ = fake.add(rb.sys_base, rb) orelse return error.NoDriver;
    return rb;
}

/// The test board's own state, found through its node: the driver of its
/// name on the library's list.
fn fakeOf(rb: *RtgBase) *fake.State {
    return fake.stateOf(driverNamed(rb, fake.DRIVER_NAME).?);
}

/// The driver of that name on the library's list, or null.
fn driverNamed(rb: *RtgBase, name: [*:0]const u8) ?*rtg.RtgDriver {
    return registry.driverOf(kexec.FindName(kexec.SysBase, &rb.drivers, name) orelse return null);
}

/// The drivers on the library's list, in its order, as their names.
fn driverNames(rb: *RtgBase, into: *[8]rtg.RtgDriverInfo) u32 {
    return base(rb).GetRtgDrivers(into, into.len);
}

/// Neither library expunges itself: take the driver off, close utility
/// and the timer for rtg, free all three, and check that nothing is left -
/// no memory, and no signal of the test's task that a wait took.
fn tearDown(rb: *RtgBase) !void {
    try testing.expect(fake.remove(fakeOf(rb)));
    // The monitor task, where a board with a connector had it made.
    monitors.stop(rb);
    // The settings' lines, which nothing gives back while the machine
    // runs.
    settings.clear(rb);
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

/// The library through its second interface, the way a driver reaches it.
fn driverBase(rb: *RtgBase) *sdk.interface.rtgdriver.RtgDriverBase {
    return @ptrCast(rb);
}

/// A board put in the mode of that number - its default for 0 - showing
/// nothing.
fn setMode(rb: *RtgBase, board: *rtg.RtgBoard, mode_id: u32) i32 {
    const id = if (mode_id != 0) mode_id else base(rb).FindBoardMode(board, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY);
    if (id == 0) return rtg.errors.RTGERR_BAD_MODE;
    return base(rb).ShowBoard(board, id, null, 0);
}

/// A device of the test board's kind offered, and the board its driver
/// made of it.
fn makeBoard(rb: *RtgBase) !*rtg.RtgBoard {
    return fake.makeBoard(fakeOf(rb)) orelse error.NoBoard;
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

test "a driver's node: its description, the library's bases, its own state cleared" {
    const rb = try setUp();
    defer kexec.deinit();

    // A driver that asks for state gets it behind its node, cleared.
    const Kept = extern struct { first: u64, last: u32 };
    const ops = rtg.RtgDriverOps{ .attach = @ptrFromInt(0x1000) };
    const with_state = rtg.RtgDriverSpec{
        .name = "kept",
        .id_string = "kept 2.5",
        .version = 2,
        .revision = 5,
        .kind = rtg.drivers.RTGDT_BOARD,
        .ops = &ops,
        .state_size = @sizeOf(Kept),
    };
    var seg: u32 = 0;
    const driver = driverBase(rb).AddRtgDriver(&with_state, &seg).?;
    try testing.expectEqual(&with_state, driver.spec);
    try testing.expectEqualStrings("kept", std.mem.span(driver.node.name.?));
    try testing.expectEqual(rb.sys_base, driver.sys_base);
    try testing.expectEqual(driverBase(rb), driver.rtg_base);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&seg)), driver.seg_list);
    try testing.expectEqual(@as(u32, 0), driver.devices);
    try testing.expectEqual(@as(u32, 0), driver.boards);
    try testing.expectEqual(@as(u32, 0), driver.buses);
    const kept: *Kept = @ptrCast(@alignCast(driver.state.?));
    try testing.expectEqual(@as(u64, 0), kept.first);
    try testing.expectEqual(@as(u32, 0), kept.last);
    // Its own, and past the node.
    try testing.expect(@intFromPtr(kept) >= @intFromPtr(driver) + @sizeOf(rtg.RtgDriver));
    kept.* = .{ .first = 0x1122_3344_5566_7788, .last = 7 };
    try testing.expectEqual(&with_state, driver.spec);
    try testing.expect(driverBase(rb).RemRtgDriver(driver));

    // One that asks for none has none.
    const without = rtg.RtgDriverSpec{ .name = "bare", .kind = rtg.drivers.RTGDT_BOARD, .ops = &ops };
    const bare = driverBase(rb).AddRtgDriver(&without, null).?;
    try testing.expect(bare.state == null);
    try testing.expect(driverBase(rb).RemRtgDriver(bare));
    try tearDown(rb);
}

/// Two drivers' ROM tags, as a boot scan would have found them.
const RomTags = struct {
    const ops = rtg.RtgDriverOps{ .attach = @ptrFromInt(0x1000) };
    const low: rtg.ResidentRtgDriver = .{
        .resident = .{ .match_tag = &low.resident, .type = .rtg_driver, .name = "rtg-low" },
        .spec = .{ .name = "low", .priority = -5, .kind = rtg.drivers.RTGDT_BOARD, .ops = &ops },
    };
    const high: rtg.ResidentRtgDriver = .{
        .resident = .{ .match_tag = &high.resident, .type = .rtg_driver, .name = "rtg-high" },
        .spec = .{ .name = "high", .priority = 5, .kind = rtg.drivers.RTGDT_BOARD, .ops = &ops },
    };
};

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

test "a board: its own name, its own instance, its driver and its device held" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);

    const board = try makeBoard(rb);
    try testing.expectEqual(@as(u32, 1), fk.log.offered);
    try testing.expectEqual(@as(u32, 1), fk.log.created);
    try testing.expectEqual(@as(u32, 1), fk.driver.boards);
    try testing.expectEqual(@as(u32, 1), fk.driver.devices);
    // Named after its driver and a number, and the name is the library's.
    try testing.expectEqualStrings("fake.0", std.mem.span(board.node.name.?));
    try testing.expectEqual(board, base(rb).FindBoard("fake.0").?);
    try testing.expectEqual(board, base(rb).NextBoard(null).?);
    try testing.expect(base(rb).NextBoard(board) == null);
    // It is its device's first output, and says which device that is.
    try testing.expectEqual(fk.devices[0].?, board.device.?);
    try testing.expectEqual(fk.driver, board.device.?.driver.?);
    try testing.expectEqual(@as(u32, 0), board.unit);
    // The driver's data is its own, and the library cleared it.
    const instance: *fake.Instance = @ptrCast(@alignCast(board.instance.?));
    try testing.expectEqual(fake.instance_pattern, instance.pattern);
    // What it can do is what it filled in, and nothing else.
    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expect(info.caps & rtg.boards.RTGBC_FILL_RECT != 0);
    try testing.expect(info.caps & rtg.boards.RTGBC_BLIT_TEMPLATE == 0);
    try testing.expectEqual(@as(u32, 3), info.modes);
    try testing.expectEqualStrings("fake.0", std.mem.span(info.name.?));
    try testing.expectEqualStrings("panel.0", std.mem.span(info.device.?));
    try testing.expectEqualStrings("Fake 0", std.mem.span(info.label.?));

    driverBase(rb).DeleteBoard(board);
    try testing.expectEqual(@as(u32, 1), fk.log.destroyed);
    try testing.expectEqual(@as(u32, 0), fk.driver.boards);
    try testing.expect(base(rb).NextBoard(null) == null);
    // The device is still the driver's, with no board of it left.
    try testing.expectEqual(@as(u32, 1), fk.driver.devices);
    try tearDown(rb);
}

test "a device from tags: named, offered at once, and listed with its driver" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);

    // Nothing of the machine's is on the list before the first bind, and
    // the host has neither a board's list nor PCI to find any on.
    var listed: [4]rtg.RtgDeviceInfo = undefined;
    try testing.expectEqual(@as(u32, 0), base(rb).GetRtgDevices(&listed, listed.len));
    try testing.expectEqual(@as(u32, 0), base(rb).BindRtgDrivers());
    try testing.expectEqual(@as(u32, 0), base(rb).GetRtgDevices(null, 0));

    const device = fake.addDevice(fk, null).?;
    try testing.expectEqualStrings("panel.0", std.mem.span(device.node.name.?));
    try testing.expectEqual(rtg.drivers.RTGDEV_PART, device.kind);
    try testing.expectEqual(fake.chip, device.chip);
    try testing.expectEqual(fake.bus, device.bus);
    try testing.expect(device.part == null and device.pci == null);
    try testing.expectEqual(@as(?[*]const TagItem, fake.deviceTags()), device.tags);
    // Offered as it was added: the fake has it, and made its board.
    try testing.expectEqual(fk.driver, device.driver.?);
    try testing.expectEqual(@as(u32, 1), fk.driver.devices);
    const board = base(rb).NextBoard(null).?;
    try testing.expectEqual(device, board.device.?);

    try testing.expectEqual(@as(u32, 1), base(rb).GetRtgDevices(&listed, listed.len));
    try testing.expectEqualStrings("panel.0", std.mem.sliceTo(&listed[0].name, 0));
    try testing.expectEqualStrings("fake display", std.mem.sliceTo(&listed[0].chip_name, 0));
    try testing.expectEqualStrings("fake", std.mem.sliceTo(&listed[0].driver, 0));
    try testing.expectEqual(@as(u32, 1), listed[0].boards);
    try testing.expectEqual(@as(u32, 0), listed[0].flags);
    try testing.expectEqual(@as(u8, 0), listed[0].behind[0]);

    // A second one takes the next number, and one bind later nothing is
    // left to offer.
    const second = fake.addDevice(fk, null).?;
    try testing.expectEqualStrings("panel.1", std.mem.span(second.node.name.?));
    try testing.expectEqual(@as(u32, 2), base(rb).GetRtgDevices(null, 0));
    try testing.expectEqual(@as(u32, 0), base(rb).BindRtgDrivers());
    try tearDown(rb);
}

test "a driver that declines: nothing kept, the device left for a driver that comes later" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);

    fk.create_answer = rtg.errors.RTGERR_NO_DISPLAY;
    const device = fake.addDevice(fk, null).?;
    try testing.expectEqual(@as(u32, 1), fk.log.offered);
    try testing.expectEqual(@as(u32, 0), fk.log.created);
    try testing.expectEqual(@as(u32, 0), fk.driver.boards);
    try testing.expectEqual(@as(u32, 0), fk.driver.devices);
    try testing.expect(device.driver == null);
    try testing.expect(base(rb).NextBoard(null) == null);

    // Offered again by the next bind, and taken this time.
    fk.create_answer = rtg.errors.RTGERR_OK;
    try testing.expectEqual(@as(u32, 1), base(rb).BindRtgDrivers());
    try testing.expectEqual(@as(u32, 2), fk.log.offered);
    try testing.expectEqual(fk.driver, device.driver.?);
    try testing.expectEqualStrings("fake.0", std.mem.span(base(rb).NextBoard(null).?.node.name.?));
    // The leak check in tearDown is what proves nothing of the refusal
    // stayed.
    try tearDown(rb);
}

/// A driver of the tests' own that makes a board and leaves it, declining:
/// what an attach may not do, which the library puts right.
const Careless = struct {
    const board_ops = rtg.RtgBoardOps{};
    fn attach(driver: *rtg.RtgDriver, device: *rtg.RtgDevice, _: ?[*]const TagItem) callconv(.c) i32 {
        _ = driver.rtg_base.CreateBoard(driver, device, &.{ .ops = &board_ops, .instance_size = 24 });
        return rtg.errors.RTGERR_IO;
    }
    const ops = rtg.RtgDriverOps{ .attach = &attach };
    const matches = [_]rtg.RtgMatch{ .{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = fake.chip, .priority = 5 }, .{} };
    const spec = rtg.RtgDriverSpec{ .name = "careless", .kind = rtg.drivers.RTGDT_BOARD, .matches = &matches, .ops = &ops };
};

test "who is asked first: the closer entry, then the entry's priority, and a board left behind is freed" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);

    // A driver that names the bus alone is asked after the fake, which
    // names the chip - whatever its place on the list.
    const Taker = struct {
        var offered: u32 = 0;
        fn attach(_: *rtg.RtgDriver, _: *rtg.RtgDevice, _: ?[*]const TagItem) callconv(.c) i32 {
            offered += 1;
            return rtg.errors.RTGERR_NO_DISPLAY;
        }
        const ops = rtg.RtgDriverOps{ .attach = &attach };
        const matches = [_]rtg.RtgMatch{ .{ .fields = rtg.drivers.RTGMATCH_BUS, .bus = fake.bus }, .{} };
        const spec = rtg.RtgDriverSpec{ .name = "by-bus", .priority = 50, .kind = rtg.drivers.RTGDT_BOARD, .matches = &matches, .ops = &ops };
    };
    Taker.offered = 0;
    const by_bus = driverBase(rb).AddRtgDriver(&Taker.spec, null).?;
    const device = fake.addDevice(fk, null).?;
    try testing.expectEqual(fk.driver, device.driver.?);
    try testing.expectEqual(@as(u32, 0), Taker.offered);

    // One that names the chip with a higher entry priority is asked
    // before the fake. It makes a board and declines: the board is freed,
    // and the fake takes the device.
    const careless = driverBase(rb).AddRtgDriver(&Careless.spec, null).?;
    const before = fk.log.offered;
    const next = fake.addDevice(fk, null).?;
    try testing.expectEqual(fk.driver, next.driver.?);
    try testing.expectEqual(before + 1, fk.log.offered);
    try testing.expectEqual(@as(u32, 0), careless.boards);
    try testing.expectEqual(@as(u32, 0), careless.devices);
    try testing.expectEqual(@as(u32, 0), Taker.offered);

    // With the fake declining too, the bus's driver is asked last.
    fk.create_answer = rtg.errors.RTGERR_NO_DISPLAY;
    const last = fake.addDevice(fk, null).?;
    try testing.expect(last.driver == null);
    try testing.expectEqual(@as(u32, 1), Taker.offered);

    // The closeness itself: a chip, or a vendor with a device, above a
    // bus, a vendor alone or a class; nothing for a field that is not the
    // device's.
    const m = rtg.drivers;
    try testing.expectEqual(@as(?u32, 2), devices.closeness(&.{ .fields = m.RTGMATCH_CHIP, .chip = fake.chip }, device));
    try testing.expectEqual(@as(?u32, 2), devices.closeness(&.{ .fields = m.RTGMATCH_CHIP | m.RTGMATCH_BUS, .chip = fake.chip, .bus = fake.bus }, device));
    try testing.expectEqual(@as(?u32, 1), devices.closeness(&.{ .fields = m.RTGMATCH_BUS, .bus = fake.bus }, device));
    try testing.expectEqual(@as(?u32, null), devices.closeness(&.{ .fields = m.RTGMATCH_CHIP, .chip = fake.chip + 1 }, device));
    try testing.expectEqual(@as(?u32, null), devices.closeness(&.{ .fields = m.RTGMATCH_CHIP | m.RTGMATCH_BUS, .chip = fake.chip, .bus = 1 }, device));
    // A part is no function on PCI.
    try testing.expectEqual(@as(?u32, null), devices.closeness(&.{ .fields = m.RTGMATCH_VENDOR, .vendor = 0x1AF4 }, device));
    var function = sdk.pci.PCIDevice{ .vendor_id = 0x1AF4, .device_id = 0x1050, .class_code = 0x03_8000 };
    const on_pci = rtg.RtgDevice{ .kind = m.RTGDEV_PCI, .pci = &function, .bus = sdk.expansion.systemtags.BUS_PCI };
    try testing.expectEqual(@as(?u32, 2), devices.closeness(&.{ .fields = m.RTGMATCH_VENDOR | m.RTGMATCH_DEVICE, .vendor = 0x1AF4, .device = 0x1050 }, &on_pci));
    try testing.expectEqual(@as(?u32, 1), devices.closeness(&.{ .fields = m.RTGMATCH_VENDOR, .vendor = 0x1AF4 }, &on_pci));
    try testing.expectEqual(@as(?u32, 1), devices.closeness(&.{ .fields = m.RTGMATCH_CLASS, .class_code = 0x03_0000, .class_mask = 0xFF_0000 }, &on_pci));
    try testing.expectEqual(@as(?u32, null), devices.closeness(&.{ .fields = m.RTGMATCH_VENDOR | m.RTGMATCH_DEVICE, .vendor = 0x1AF4, .device = 0x1010 }, &on_pci));
    try testing.expectEqual(@as(?u32, null), devices.closeness(&.{ .fields = m.RTGMATCH_CLASS, .class_code = 0x02_0000, .class_mask = 0xFF_0000 }, &on_pci));
    // A function is no part of a chip.
    try testing.expectEqual(@as(?u32, null), devices.closeness(&.{ .fields = m.RTGMATCH_CHIP, .chip = 0 }, &on_pci));

    fk.create_answer = rtg.errors.RTGERR_OK;
    try testing.expect(fake.remove(fk));
    try testing.expect(driverBase(rb).RemRtgDriver(careless));
    try testing.expect(driverBase(rb).RemRtgDriver(by_bus));
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

test "a device taken away: its boards gone from the walk, still handles, and showing nothing" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);

    const board = try makeDisplay(rb, 8, 8);
    const device = board.device.?;
    const mode = base(rb).FindBoardMode(board, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY);
    try testing.expectEqual(rtg.errors.RTGERR_OK, setMode(rb, board, mode));
    const bm = base(rb).AllocBitMap(board, 8, 8, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, bm));

    driverBase(rb).RemRtgDevice(device);
    fk.devices[0] = null;
    try testing.expectEqual(@as(u32, 1), fk.log.detached);
    try testing.expectEqual(@as(u32, 0), fk.driver.devices);
    try testing.expectEqual(@as(u32, 0), base(rb).GetRtgDevices(null, 0));
    // The board is passed over, and still found by its name.
    try testing.expect(base(rb).NextBoard(null) == null);
    try testing.expectEqual(board, base(rb).FindBoard("fake.0").?);
    try testing.expect(board.device == null);
    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expect(info.flags & rtg.boards.RTGBF_GONE != 0);
    try testing.expect(info.flags & rtg.boards.RTGBF_NO_DISPLAY != 0);
    // It still says which device it was an output of.
    try testing.expectEqualStrings("panel.0", std.mem.span(info.device.?));
    // What it showed was taken down, so the buffer can go; nothing more
    // is shown on it, and it is put in no mode.
    try testing.expect(base(rb).BoardDisplayBitMap(board) == null);
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, base(rb).ShowBitMap(board, bm));
    const one = [_]rtg.RtgBand{.{ .bitmap = bm }};
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, base(rb).ShowBoard(board, 0, &one, one.len));
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, setMode(rb, board, mode));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(bm);

    // A board made after it takes the next number, and is the display.
    const next = try makeBoard(rb);
    try testing.expectEqualStrings("fake.1", std.mem.span(next.node.name.?));
    try testing.expectEqual(next, base(rb).NextBoard(null).?);
    try testing.expect(base(rb).NextBoard(next) == null);
    // The walk goes on behind a board that is gone.
    try testing.expectEqual(next, base(rb).NextBoard(board).?);

    // A device of the machine's own never goes: only one that was added.
    driverBase(rb).RemRtgDevice(null);
    // The driver deletes its boards as it is removed, the gone one too.
    try tearDown(rb);
}

test "a bus opened by a driver: made by the driver that names the device's bus, and given back" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);

    // With no transport driver on the list the bus cannot be opened, and
    // the board's driver declines.
    fk.opens_bus = true;
    const unreached = fake.addDevice(fk, null).?;
    try testing.expect(unreached.driver == null);
    try testing.expectEqual(@as(u32, 0), fk.driver.boards);

    const buses = fakebus.add(rb) orelse return error.NoDriver;
    // A bus its driver cannot make is no bus either.
    buses.create_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(@as(u32, 0), base(rb).BindRtgDrivers());
    try testing.expectEqual(@as(u32, 0), buses.driver.buses);
    buses.create_answer = rtg.errors.RTGERR_OK;

    try testing.expectEqual(@as(u32, 1), base(rb).BindRtgDrivers());
    try testing.expectEqual(@as(u32, 1), buses.created);
    try testing.expectEqual(@as(u32, 1), buses.driver.buses);
    // Made from the device's own tags.
    try testing.expectEqual(@as(?[*]const TagItem, fake.deviceTags()), buses.last_tags);
    const board = base(rb).NextBoard(null).?;
    const io = fake.instanceOf(board).bus.?;
    try testing.expectEqualStrings("fakebus", std.mem.span(io.node.name.?));
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(buses.driver)), io.driver);
    // The library cleared the bus's own data, which is its driver's.
    const line = fakebus.instanceOf(io);
    try testing.expectEqual(@as(u32, 0), line.sends);

    // The three transfers reach the bus's driver, with what they were
    // given, and its answer comes back.
    var bytes: [4]u8 = .{ 1, 2, 3, 4 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, driverBase(rb).TxParam(io, 0x2A, &bytes, bytes.len));
    try testing.expectEqual(@as(u32, 1), line.sends);
    try testing.expectEqual(@as(i32, 0x2A), line.last_cmd);
    try testing.expectEqual(@as(u32, 4), line.last_size);
    try testing.expectEqual(rtg.errors.RTGERR_OK, driverBase(rb).TxColor(io, 0x2C, &bytes, 2));
    try testing.expectEqual(@as(u32, 1), line.colors);
    try testing.expectEqual(@as(u32, 2), line.last_size);
    try testing.expectEqual(rtg.errors.RTGERR_OK, driverBase(rb).RxParam(io, 0x04, &bytes, 3));
    try testing.expectEqual(@as(u32, 1), line.reads);
    try testing.expectEqualSlices(u8, &.{ 4, 4, 4, 4 }, &bytes);
    line.answer = rtg.errors.RTGERR_TIMEOUT;
    try testing.expectEqual(rtg.errors.RTGERR_TIMEOUT, driverBase(rb).TxParam(io, 0x29, null, 0));
    // A bus whose driver filled in no transfer says so.
    var bare = rtg.RtgTransport{};
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, driverBase(rb).TxParam(&bare, 0, null, 0));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, driverBase(rb).TxColor(&bare, 0, null, 0));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, driverBase(rb).RxParam(&bare, 0, null, 0));

    // A driver that neither has the device nor is being offered it opens
    // no bus of it; null closes nothing.
    try testing.expect(driverBase(rb).OpenTransport(buses.driver, board.device.?) == null);
    driverBase(rb).CloseTransport(null);

    // The bus's driver stays while a bus of it is open, and the bus goes
    // with the board that opened it.
    try testing.expect(!fakebus.remove(buses));
    driverBase(rb).DeleteBoard(board);
    try testing.expectEqual(@as(u32, 1), buses.destroyed);
    try testing.expectEqual(@as(u32, 0), buses.driver.buses);
    try testing.expect(fakebus.remove(buses));
    try tearDown(rb);
}

/// The board's modes, copied out; how many of them there are.
fn modesOf(rb: *RtgBase, board: *rtg.RtgBoard, into: *[8]rtg.RtgMode) u32 {
    return base(rb).GetBoardModes(board, into, into.len);
}

test "modes: copied out the larger picture first, named and numbered as they were made" {
    const rb = try setUp();
    defer kexec.deinit();
    const board = try makeBoard(rb);

    // How many there are, asked alone, and no more copied than there is
    // room for.
    try testing.expectEqual(@as(u32, 3), base(rb).GetBoardModes(board, null, 0));
    var one: [1]rtg.RtgMode = undefined;
    try testing.expectEqual(@as(u32, 3), base(rb).GetBoardModes(board, &one, one.len));
    try testing.expectEqual(@as(u32, 640), one[0].width);

    var found: [8]rtg.RtgMode = undefined;
    try testing.expectEqual(@as(u32, 3), modesOf(rb, board, &found));
    // The second the driver added is the largest, and has kept its number.
    try testing.expectEqual(@as(u32, 2), found[0].id);
    try testing.expectEqualStrings("640x480", std.mem.sliceTo(&found[0].name, 0));
    try testing.expectEqual(@as(u32, 60_000), found[0].refresh_mhz);
    try testing.expectEqual(@as(u32, 25_200_000), found[0].pixel_clock_hz);
    // A row is the width in the format, on what the display memory is
    // aligned to: what a buffer of the mode has.
    try testing.expectEqual(@as(u32, 1280), found[0].pitch);
    try testing.expectEqual(@as(u32, 1), found[1].id);
    try testing.expectEqualStrings("320x200", std.mem.sliceTo(&found[1].name, 0));
    try testing.expectEqual(rtg.modes.RTGMF_DEFAULT, found[1].flags);
    // A display with no clock says no refresh; a row of one bit a pixel is
    // rounded up as any other.
    try testing.expectEqual(@as(u32, 3), found[2].id);
    try testing.expectEqualStrings("64x64", std.mem.sliceTo(&found[2].name, 0));
    try testing.expectEqual(rtg.PixelFormat.mono1, found[2].format);
    try testing.expectEqual(@as(u32, 0), found[2].refresh_mhz);
    try testing.expectEqual(@as(u32, 64), found[2].pitch);

    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a mode: found by its figures, set by its number, and the board says what it is in" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    const any = rtg.RTG_ANY;
    const rgb565 = @intFromEnum(rtg.PixelFormat.rgb565);

    // Nothing asked for is the board's default.
    try testing.expectEqual(@as(u32, 1), base(rb).FindBoardMode(board, any, any, any, any));
    try testing.expectEqual(@as(u32, 2), base(rb).FindBoardMode(board, 640, any, any, any));
    try testing.expectEqual(@as(u32, 2), base(rb).FindBoardMode(board, 640, 480, 60_000, rgb565));
    // Only what is exactly that: a size it has not, a refresh it has not,
    // and a format the mode of that size is not in. Format 0 is a format.
    try testing.expectEqual(@as(u32, 0), base(rb).FindBoardMode(board, 800, 600, any, any));
    try testing.expectEqual(@as(u32, 0), base(rb).FindBoardMode(board, 640, 480, 75_000, any));
    try testing.expectEqual(@as(u32, 0), base(rb).FindBoardMode(board, 640, 480, any, @intFromEnum(rtg.PixelFormat.rgba32)));
    try testing.expectEqual(@as(u32, 3), base(rb).FindBoardMode(board, any, any, 0, any));

    var before: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &before, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u32, 0), before.flags & rtg.boards.RTGBF_MODE_SET);
    try testing.expectEqual(@as(u32, 0), before.mode_id);

    // A number the board has no mode of is refused, and the driver not
    // asked.
    try testing.expectEqual(rtg.errors.RTGERR_BAD_MODE, setMode(rb, board, 9));
    try testing.expectEqual(@as(u32, 0), fk.log.set_mode);

    try testing.expectEqual(rtg.errors.RTGERR_OK, setMode(rb, board, 2));
    // The driver was handed the mode and its timings.
    try testing.expectEqual(@as(u32, 2), fk.log.last_mode.id);
    try testing.expectEqual(@as(u32, 640), fk.log.last_timings.h_active);
    try testing.expectEqual(@as(u32, 96), fk.log.last_timings.h_sync);
    try testing.expectEqual(@as(u32, 25_200_000), fk.log.last_timings.pixel_clock_hz);

    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u32, 640), info.width);
    try testing.expectEqual(@as(u32, 480), info.height);
    try testing.expectEqual(@as(u32, 1280), info.pitch);
    try testing.expectEqual(@as(u32, 2), info.mode_id);
    try testing.expectEqual(@as(u32, 60_000), info.refresh_mhz);
    try testing.expectEqual(@as(u32, 25_200_000), info.pixel_clock_hz);
    try testing.expect(info.flags & rtg.boards.RTGBF_MODE_SET != 0);

    // The copies say which mode the board is in; 0 is the default.
    var found: [8]rtg.RtgMode = undefined;
    _ = modesOf(rb, board, &found);
    try testing.expect(found[0].flags & rtg.modes.RTGMF_CURRENT != 0);
    try testing.expect(found[1].flags & rtg.modes.RTGMF_CURRENT == 0);
    try testing.expectEqual(rtg.errors.RTGERR_OK, setMode(rb, board, 0));
    _ = modesOf(rb, board, &found);
    try testing.expect(found[0].flags & rtg.modes.RTGMF_CURRENT == 0);
    try testing.expectEqual(rtg.modes.RTGMF_DEFAULT | rtg.modes.RTGMF_CURRENT, found[1].flags);
    // A mode with no clock leaves the board saying none.
    try testing.expectEqual(rtg.errors.RTGERR_OK, setMode(rb, board, 3));
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u32, 0), info.refresh_mhz);
    try testing.expectEqual(@as(u32, 0), info.pixel_clock_hz);

    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "the nearest mode to a wish: on a board of one mode always that mode" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    fk.modes = 1;
    const board = try makeBoard(rb);
    const any = rtg.RTG_ANY;

    var got: rtg.RtgMode = .{};
    // Whoever asks for another size gets the board's, and sees which.
    try testing.expectEqual(@as(u32, 1), base(rb).BestBoardMode(board, 640, 800, any, any, &got));
    try testing.expectEqual(@as(u32, 320), got.width);
    try testing.expectEqual(@as(u32, 200), got.height);
    try testing.expectEqual(@as(u32, 1), base(rb).BestBoardMode(board, 16, 16, 75_000, @intFromEnum(rtg.PixelFormat.bgra32), null));
    try testing.expectEqual(@as(u32, 1), base(rb).BestBoardMode(board, any, any, any, any, null));
    // The exact one is still asked for exactly.
    try testing.expectEqual(@as(u32, 0), base(rb).FindBoardMode(board, 640, 800, any, any));

    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "the nearest mode to a wish: by format, then size, then refresh; none on a board with no mode" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const any = rtg.RTG_ANY;
    const rgb565 = @intFromEnum(rtg.PixelFormat.rgb565);
    const mono1 = @intFromEnum(rtg.PixelFormat.mono1);

    // A board with no mode answers 0 and leaves the copy alone.
    fk.modes = 0;
    const bare = try makeBoard(rb);
    var got: rtg.RtgMode = .{ .id = 77 };
    try testing.expectEqual(@as(u32, 0), base(rb).BestBoardMode(bare, 320, 200, any, any, &got));
    try testing.expectEqual(@as(u32, 77), got.id);
    try testing.expectEqual(rtg.errors.RTGERR_BAD_MODE, setMode(rb, bare, 0));
    driverBase(rb).DeleteBoard(bare);

    fk.modes = fake.mode_table.len;
    const board = try makeBoard(rb);
    // The size itself.
    try testing.expectEqual(@as(u32, 1), base(rb).BestBoardMode(board, 320, 200, any, any, &got));
    try testing.expectEqual(@as(u32, 320), got.width);
    // Else the smallest that holds it.
    try testing.expectEqual(@as(u32, 2), base(rb).BestBoardMode(board, 400, 300, any, any, null));
    try testing.expectEqual(@as(u32, 1), base(rb).BestBoardMode(board, 100, 100, any, any, null));
    try testing.expectEqual(@as(u32, 3), base(rb).BestBoardMode(board, 32, 32, any, any, null));
    // Else the largest.
    try testing.expectEqual(@as(u32, 2), base(rb).BestBoardMode(board, 800, 600, any, any, &got));
    try testing.expectEqual(@as(u32, 640), got.width);
    // One side left open holds whatever it is.
    try testing.expectEqual(@as(u32, 2), base(rb).BestBoardMode(board, any, 480, any, any, null));
    // A format wished for is looked for among the modes of that format.
    try testing.expectEqual(@as(u32, 1), base(rb).BestBoardMode(board, 32, 32, any, rgb565, null));
    try testing.expectEqual(@as(u32, 3), base(rb).BestBoardMode(board, 640, 480, any, mono1, null));
    // One the board has none of leaves the size to decide.
    try testing.expectEqual(@as(u32, 2), base(rb).BestBoardMode(board, 640, 480, any, @intFromEnum(rtg.PixelFormat.bgra32), null));
    // Nothing wished for is the default.
    try testing.expectEqual(@as(u32, 1), base(rb).BestBoardMode(board, any, any, any, any, null));

    // The size at a second refresh: 840 by 500 at 31.5 MHz is 75 a second.
    const faster: rtg.RtgTimings = .{ .pixel_clock_hz = 31_500_000, .h_active = 640, .h_front = 16, .h_sync = 64, .h_back = 120, .v_active = 480, .v_front = 1, .v_sync = 3, .v_back = 16 };
    try testing.expectEqual(@as(u32, 4), driverBase(rb).AddBoardMode(board, &faster, rgb565, 0));
    try testing.expectEqual(@as(u32, 4), base(rb).BestBoardMode(board, 640, 480, 75_000, any, null));
    try testing.expectEqual(@as(u32, 2), base(rb).BestBoardMode(board, 640, 480, 61_000, any, null));
    try testing.expectEqual(@as(u32, 4), base(rb).BestBoardMode(board, 640, 480, 70_000, any, null));
    // The refresh left open: the higher, unless the default is of that
    // size.
    try testing.expectEqual(@as(u32, 4), base(rb).BestBoardMode(board, 640, 480, any, any, null));
    try testing.expectEqual(@as(u32, 1), base(rb).BestBoardMode(board, 320, 200, any, any, null));

    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a mode added: its name with the refresh where a size has two, the default moved, the same figures the same mode" {
    const rb = try setUp();
    defer kexec.deinit();
    const board = try makeBoard(rb);
    const rgb565 = @intFromEnum(rtg.PixelFormat.rgb565);
    var found: [8]rtg.RtgMode = undefined;

    const faster: rtg.RtgTimings = .{ .pixel_clock_hz = 31_500_000, .h_active = 640, .h_front = 16, .h_sync = 64, .h_back = 120, .v_active = 480, .v_front = 1, .v_sync = 3, .v_back = 16 };
    try testing.expectEqual(@as(u32, 4), driverBase(rb).AddBoardMode(board, &faster, rgb565, rtg.modes.RTGMF_DEFAULT));
    try testing.expectEqual(@as(u32, 4), modesOf(rb, board, &found));
    // Of one size the higher refresh first, and both say which they are.
    try testing.expectEqual(@as(u32, 4), found[0].id);
    try testing.expectEqualStrings("640x480@75", std.mem.sliceTo(&found[0].name, 0));
    try testing.expectEqualStrings("640x480@60", std.mem.sliceTo(&found[1].name, 0));
    try testing.expectEqualStrings("320x200", std.mem.sliceTo(&found[2].name, 0));
    // The default is the one added as it, and no other.
    try testing.expectEqual(rtg.modes.RTGMF_DEFAULT, found[0].flags);
    try testing.expectEqual(@as(u32, 0), found[2].flags);
    try testing.expectEqual(@as(u32, 4), base(rb).FindBoardMode(board, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY));
    // A row was set as it was added: the board has its display memory.
    try testing.expectEqual(@as(u32, 1280), found[0].pitch);

    // The same figures again are the mode that is there, with the timings
    // handed over now.
    var again = faster;
    again.h_front = 24;
    again.h_back = 112;
    try testing.expectEqual(@as(u32, 4), driverBase(rb).AddBoardMode(board, &again, rgb565, 0));
    try testing.expectEqual(@as(u32, 4), base(rb).GetBoardModes(board, null, 0));
    try testing.expectEqual(rtg.errors.RTGERR_OK, setMode(rb, board, 4));
    try testing.expectEqual(@as(u32, 24), fakeOf(rb).log.last_timings.h_front);
    // It stays the default: a mode is not made less by being added again.
    try testing.expectEqual(@as(u32, 4), base(rb).FindBoardMode(board, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY));

    // A picture a quarter turn round is a mode of its own, and says so;
    // an interlaced one is named for it.
    const turned: rtg.RtgTimings = .{ .h_active = 64, .v_active = 64 };
    try testing.expectEqual(@as(u32, 5), driverBase(rb).AddBoardMode(board, &turned, @intFromEnum(rtg.PixelFormat.mono1), rtg.modes.RTGMF_TURNED));
    var fields = faster;
    fields.h_active = 720;
    fields.flags = rtg.modes.RTGTM_INTERLACED;
    try testing.expectEqual(@as(u32, 6), driverBase(rb).AddBoardMode(board, &fields, rgb565, 0));
    try testing.expectEqual(@as(u32, 6), modesOf(rb, board, &found));
    try testing.expectEqualStrings("720x480i", std.mem.sliceTo(&found[0].name, 0));
    try testing.expect(found[0].flags & rtg.modes.RTGMF_INTERLACED != 0);
    try testing.expect(found[5].flags & rtg.modes.RTGMF_TURNED != 0);

    // What is no mode: an empty picture, and a format that is none.
    const empty: rtg.RtgTimings = .{ .h_active = 640 };
    try testing.expectEqual(@as(u32, 0), driverBase(rb).AddBoardMode(board, &empty, rgb565, 0));
    try testing.expectEqual(@as(u32, 0), driverBase(rb).AddBoardMode(board, &faster, 200, 0));
    try testing.expectEqual(@as(u32, 0), driverBase(rb).AddBoardMode(board, &faster, 0x1_0004, 0));
    try testing.expectEqual(@as(u32, 6), base(rb).GetBoardModes(board, null, 0));

    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a panel's timings from its tags: the size, the clock and the blanking; what is no panel" {
    const rb = try setUp();
    defer kexec.deinit();
    const tags = rtg.tags;

    const panel = [_]TagItem{
        .{ .tag = tags.RTGA_Width, .data = 1024 },
        .{ .tag = tags.RTGA_Height, .data = 600 },
        .{ .tag = tags.RTGA_PixelClock, .data = 30_000_000 },
        .{ .tag = tags.RTGA_HSyncPulse, .data = 162 },
        .{ .tag = tags.RTGA_HBackPorch, .data = 152 },
        .{ .tag = tags.RTGA_HFrontPorch, .data = 48 },
        .{ .tag = tags.RTGA_VSyncPulse, .data = 45 },
        .{ .tag = tags.RTGA_VBackPorch, .data = 13 },
        .{ .tag = tags.RTGA_VFrontPorch, .data = 3 },
        .{ .tag = tags.RTGA_TimingFlags, .data = rtg.modes.RTGTM_PCLK_FALLING },
        .{},
    };
    var timings: rtg.RtgTimings = .{};
    try testing.expect(driverBase(rb).ReadTimingTags(&panel, &timings));
    try testing.expectEqual(@as(u32, 1024), timings.h_active);
    try testing.expectEqual(@as(u32, 600), timings.v_active);
    try testing.expectEqual(@as(u32, 30_000_000), timings.pixel_clock_hz);
    try testing.expectEqual(@as(u32, 162), timings.h_sync);
    try testing.expectEqual(@as(u32, 152), timings.h_back);
    try testing.expectEqual(@as(u32, 48), timings.h_front);
    try testing.expectEqual(@as(u32, 45), timings.v_sync);
    try testing.expectEqual(@as(u32, 13), timings.v_back);
    try testing.expectEqual(@as(u32, 3), timings.v_front);
    try testing.expectEqual(rtg.modes.RTGTM_PCLK_FALLING, timings.flags);
    // 30 MHz over 1386 by 661: what the mode made of them says.
    try testing.expectEqual(@as(u32, 32_745), modes.refreshOf(&timings));

    // A display behind a bus is its size and no more.
    const bus_panel = [_]TagItem{
        .{ .tag = tags.RTGA_Width, .data = 320 },
        .{ .tag = tags.RTGA_Height, .data = 480 },
        .{},
    };
    try testing.expect(driverBase(rb).ReadTimingTags(&bus_panel, &timings));
    try testing.expectEqual(@as(u32, 320), timings.h_active);
    try testing.expectEqual(@as(u32, 0), timings.pixel_clock_hz);
    try testing.expectEqual(@as(u32, 0), timings.flags);

    // No size, and a clock without a sync pulse: refused, and what was
    // there is left.
    const before = timings;
    const sizeless = [_]TagItem{ .{ .tag = tags.RTGA_Width, .data = 320 }, .{} };
    try testing.expect(!driverBase(rb).ReadTimingTags(&sizeless, &timings));
    const pulseless = [_]TagItem{
        .{ .tag = tags.RTGA_Width, .data = 320 },
        .{ .tag = tags.RTGA_Height, .data = 480 },
        .{ .tag = tags.RTGA_PixelClock, .data = 8_000_000 },
        .{ .tag = tags.RTGA_HSyncPulse, .data = 4 },
        .{},
    };
    try testing.expect(!driverBase(rb).ReadTimingTags(&pulseless, &timings));
    try testing.expect(!driverBase(rb).ReadTimingTags(null, &timings));
    try testing.expectEqual(before, timings);

    try tearDown(rb);
}

/// A first block made an EDID's: its header put in front and the sum of
/// its bytes brought to zero.
fn sealed(block: edid.Block) edid.Block {
    var whole = block;
    const header = [8]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    @memcpy(whole[0..8], &header);
    whole[127] = 0;
    var sum: u8 = 0;
    for (whole) |byte| sum +%= byte;
    whole[127] = 0 -% sum;
    return whole;
}

/// An extension block summed to zero.
fn summed(block: edid.Block) edid.Block {
    var whole = block;
    whole[127] = 0;
    var sum: u8 = 0;
    for (whole) |byte| sum +%= byte;
    whole[127] = 0 -% sum;
    return whole;
}

/// The portable 1080p monitor's EDID, as a driver's `detect` hands it
/// over.
const portable_bytes: []const u8 = std.mem.sliceAsBytes(&edid.portable_1080p);

/// A 3840x2160 monitor: 4K at 60 preferred, at 594 MHz, and in its
/// extension CEA's numbers 95 (4K at 30) and 16 (1080p at 60).
const uhd_monitor: [2]edid.Block = blocks: {
    var first: edid.Block = @splat(0);
    for (38..54) |i| first[i] = 0x01;
    const uhd60 = [18]u8{ 0x08, 0xE8, 0x00, 0x30, 0xF2, 0x70, 0x5A, 0x80, 0xB0, 0x58, 0x8A, 0x00, 0x50, 0x1D, 0x74, 0x00, 0x00, 0x1E };
    @memcpy(first[54..72], &uhd60);
    first[126] = 1;
    var cea: edid.Block = @splat(0);
    cea[0] = 0x02;
    cea[1] = 0x03;
    cea[2] = 7;
    cea[4] = 2 << 5 | 2;
    cea[5] = 95;
    cea[6] = 16;
    break :blocks .{ sealed(first), summed(cea) };
};
const uhd_bytes: []const u8 = std.mem.sliceAsBytes(&uhd_monitor);

/// A 2560x1440 monitor that names its one mode in full and nothing else.
const qhd_monitor: [1]edid.Block = blocks: {
    var first: edid.Block = @splat(0);
    for (38..54) |i| first[i] = 0x01;
    const qhd = [18]u8{ 0x56, 0x5E, 0x00, 0xA0, 0xA0, 0xA0, 0x29, 0x50, 0x30, 0x20, 0x35, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1A };
    @memcpy(first[54..72], &qhd);
    break :blocks .{sealed(first)};
};
const qhd_bytes: []const u8 = std.mem.sliceAsBytes(&qhd_monitor);

/// A board of the test driver's with a connector, the monitor of `bytes`
/// on it, and none of the driver's own modes unless `own` says how many.
fn makeConnector(rb: *RtgBase, bytes: ?[]const u8, own: u32) !*rtg.RtgBoard {
    const fk = fakeOf(rb);
    fk.connector = true;
    fk.modes = own;
    fk.monitor_there = bytes != null;
    fk.monitor_edid = bytes;
    return makeBoard(rb);
}

/// What the board says of itself now.
fn infoOf(rb: *RtgBase, board: *rtg.RtgBoard) rtg.RtgBoardInfo {
    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    return info;
}

/// What is on the board's connector, as the library last saw it.
fn monitorOf(rb: *RtgBase, board: *rtg.RtgBoard) rtg.RtgMonitorInfo {
    var said: rtg.RtgMonitorInfo = .{};
    _ = base(rb).GetBoardMonitor(board, &said, @sizeOf(rtg.RtgMonitorInfo));
    return said;
}

test "a panel is a monitor that is always there, called what its part is called" {
    const rb = try setUp();
    defer kexec.deinit();
    const board = try makeBoard(rb);
    const said = monitorOf(rb, board);
    try testing.expectEqual(rtg.modes.RTGMON_PRESENT | rtg.modes.RTGMON_PANEL, said.flags);
    try testing.expectEqualStrings("fake display", std.mem.sliceTo(&said.name, 0));
    try testing.expectEqual(@as(u32, 0), said.edid_size);
    // As much of the answer as the caller has room for.
    var short: rtg.RtgMonitorInfo = .{};
    try testing.expectEqual(@as(u32, 4), base(rb).GetBoardMonitor(board, &short, 4));
    try testing.expectEqual(said.flags, short.flags);
    try testing.expectEqual(@as(u8, 0), short.name[0]);
    // It has no EDID, its board no connector, and nothing asked its driver.
    try testing.expectEqual(@as(u32, 0), base(rb).ReadBoardEDID(board, null, 0));
    const info = infoOf(rb, board);
    try testing.expectEqual(@as(u32, 0), info.flags & rtg.boards.RTGBF_CONNECTOR);
    try testing.expectEqual(@as(u32, 0), info.caps & rtg.boards.RTGBC_MONITOR);
    try testing.expectEqual(@as(u32, 0), fakeOf(rb).log.detects);
    // A word of its driver's about a connector it has not is not heard.
    driverBase(rb).MonitorChanged(board);
    monitors.service(rb);
    try testing.expectEqual(@as(u32, 0), fakeOf(rb).log.detects);
    try testing.expect(rb.monitor_task == null);

    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a monitor's modes: made of its EDID as the board joins the list, the one it prefers the default" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeConnector(rb, portable_bytes, fake.mode_table.len);

    // The connector was asked once, in the task that made the board, and
    // the task that looks again is there.
    try testing.expectEqual(@as(u32, 1), fk.log.detects);
    try testing.expect(rb.monitor_task != null);
    var info = infoOf(rb, board);
    try testing.expect(info.flags & rtg.boards.RTGBF_CONNECTOR != 0);
    try testing.expect(info.caps & rtg.boards.RTGBC_MONITOR != 0);
    try testing.expectEqual(@as(u32, 0), info.flags & rtg.boards.RTGBF_NO_DISPLAY);

    // What it names that the standards time, the larger picture first:
    // its own 1080p in full, then sizes by a bit, a size or a number.
    const expected = [_][2]u32{
        .{ 1920, 1080 }, .{ 1280, 1024 }, .{ 1440, 900 }, .{ 1280, 960 }, .{ 1280, 720 },
        .{ 1024, 768 },  .{ 800, 600 },   .{ 720, 480 },  .{ 640, 480 },
    };
    var found: [16]rtg.RtgMode = undefined;
    try testing.expectEqual(@as(u32, expected.len), base(rb).GetBoardModes(board, &found, found.len));
    try testing.expectEqual(@as(u32, expected.len), info.modes);
    for (expected, found[0..expected.len]) |want, *got| {
        try testing.expectEqual(want[0], got.width);
        try testing.expectEqual(want[1], got.height);
        // In the format the board said a monitor's modes are made in.
        try testing.expectEqual(rtg.PixelFormat.rgb565, got.format);
        try testing.expect(got.refresh_mhz > 59_000 and got.refresh_mhz < 61_000);
    }
    // The driver's own three stand by: none of them is listed.
    try testing.expectEqual(@as(u32, 0), base(rb).FindBoardMode(board, 320, 200, rtg.RTG_ANY, rtg.RTG_ANY));
    // The mode it prefers is the default, with the timing it gave - the
    // sync a line early - and CEA's number for it.
    try testing.expectEqual(rtg.modes.RTGMF_DEFAULT, found[0].flags);
    try testing.expectEqualStrings("1920x1080", std.mem.sliceTo(&found[0].name, 0));
    try testing.expectEqual(rtg.errors.RTGERR_OK, setMode(rb, board, 0));
    try testing.expectEqual(found[0].id, fk.log.last_mode.id);
    try testing.expectEqual(@as(u32, 148_500_000), fk.log.last_timings.pixel_clock_hz);
    try testing.expectEqual(@as(u32, 3), fk.log.last_timings.v_front);
    try testing.expectEqual(@as(u8, 16), fk.log.last_timings.vic);
    try testing.expectEqual(rtg.modes.RTGTM_HSYNC_HIGH | rtg.modes.RTGTM_VSYNC_HIGH, fk.log.last_timings.flags);
    // A mode named by a number has the standard's timing and that number.
    try testing.expectEqual(rtg.errors.RTGERR_OK, setMode(rb, board, found[7].id));
    try testing.expectEqual(@as(u8, 3), fk.log.last_timings.vic);
    try testing.expectEqual(@as(u32, 27_000_000), fk.log.last_timings.pixel_clock_hz);

    // What the monitor says of itself, and its EDID as it was read.
    const said = monitorOf(rb, board);
    const m = rtg.modes;
    try testing.expectEqual(m.RTGMON_PRESENT | m.RTGMON_EDID | m.RTGMON_HDMI | m.RTGMON_AUDIO | m.RTGMON_RANGE_SELECTABLE, said.flags);
    try testing.expectEqualStrings("BOE", std.mem.sliceTo(&said.maker, 0));
    try testing.expectEqualStrings("Display", std.mem.sliceTo(&said.name, 0));
    try testing.expectEqual(@as(u32, 0x2556), said.product);
    try testing.expectEqual(@as(u32, 350), said.width_mm);
    try testing.expectEqual(@as(u16, 2024), said.year);
    try testing.expectEqual(@as(u32, 300_000), said.max_tmds_khz);
    try testing.expectEqual(@as(u32, 256), said.edid_size);
    try testing.expectEqual(@as(u32, 256), base(rb).ReadBoardEDID(board, null, 0));
    var bytes: [rtg.modes.RTG_EDID_MAX]u8 = @splat(0xEE);
    try testing.expectEqual(@as(u32, 256), base(rb).ReadBoardEDID(board, &bytes, 130));
    try testing.expectEqualSlices(u8, portable_bytes[0..130], bytes[0..130]);
    try testing.expectEqual(@as(u8, 0xEE), bytes[130]);

    info = infoOf(rb, board);
    try testing.expectEqual(found[7].id, info.mode_id);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a monitor that prefers what the board cannot make gets 1080p at 60; one mode in full is its one mode" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    // A board that makes no clock past 300 MHz, as an HDMI 1.4 port.
    fk.fastest_hz = 300_000_000;
    const board = try makeConnector(rb, uhd_bytes, 0);
    var found: [16]rtg.RtgMode = undefined;
    try testing.expectEqual(@as(u32, 2), base(rb).GetBoardModes(board, &found, found.len));
    try testing.expectEqual(@as(u32, 3840), found[0].width);
    try testing.expectEqual(@as(u32, 30_000), found[0].refresh_mhz);
    try testing.expectEqual(@as(u32, 0), found[0].flags);
    try testing.expectEqual(@as(u32, 1080), found[1].height);
    try testing.expectEqual(rtg.modes.RTGMF_DEFAULT, found[1].flags);
    // The board was asked of the two the monitor's own clock allows: it
    // says no faster one than HDMI 1.4's, so 4K at 60 is not its to take.
    try testing.expectEqual(@as(u32, 2), fk.log.checks);
    driverBase(rb).DeleteBoard(board);

    // One detailed timing and no more: that mode, as the monitor times it.
    fk.fastest_hz = 0xFFFF_FFFF;
    const other = try makeConnector(rb, qhd_bytes, 0);
    try testing.expectEqual(@as(u32, 1), base(rb).GetBoardModes(other, &found, found.len));
    try testing.expectEqual(@as(u32, 2560), found[0].width);
    try testing.expectEqual(@as(u32, 241_500_000), found[0].pixel_clock_hz);
    try testing.expectEqual(rtg.errors.RTGERR_OK, setMode(rb, other, 0));
    try testing.expectEqual(rtg.modes.RTGTM_HSYNC_HIGH, fk.log.last_timings.flags);
    try testing.expectEqual(@as(u8, 0), fk.log.last_timings.vic);
    // A monitor without an extension is a DVI monitor, of no sound.
    const said = monitorOf(rb, other);
    try testing.expectEqual(rtg.modes.RTGMON_PRESENT | rtg.modes.RTGMON_EDID, said.flags);
    driverBase(rb).DeleteBoard(other);
    try tearDown(rb);
}

test "a monitor that names nothing: the board's own modes, or its device's size at 60 a second" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);

    // No monitor on the connector: the driver's own modes stand, and the
    // board says it has no display - and is shown on all the same.
    const board = try makeConnector(rb, null, fake.mode_table.len);
    var found: [16]rtg.RtgMode = undefined;
    try testing.expectEqual(@as(u32, 3), base(rb).GetBoardModes(board, &found, found.len));
    try testing.expectEqual(@as(u32, 1), base(rb).FindBoardMode(board, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY));
    try testing.expect(infoOf(rb, board).flags & rtg.boards.RTGBF_NO_DISPLAY != 0);
    try testing.expectEqual(@as(u32, 0), monitorOf(rb, board).flags);
    // In its mode of one bit a pixel, whose picture the tests' display
    // memory holds.
    const bm = base(rb).AllocBitMap(board, 64, 64, @intFromEnum(rtg.PixelFormat.mono1), rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const in_mono = [_]rtg.RtgBand{.{ .bitmap = bm }};
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 3, &in_mono, in_mono.len));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(bm);
    driverBase(rb).DeleteBoard(board);

    // A monitor whose EDID does not read, on a board that added no mode:
    // the size its device's tags give, in the standard's timing.
    const sized = [_]TagItem{
        .{ .tag = rtg.tags.RTGA_Width, .data = 1280 },
        .{ .tag = rtg.tags.RTGA_Height, .data = 720 },
        .{ .tag = utility.TAG_MORE, .data = @intFromPtr(fake.deviceTags()) },
    };
    fk.connector = true;
    fk.modes = 0;
    fk.monitor_there = true;
    fk.monitor_edid = null;
    const bare = fake.makeBoardFrom(fk, &sized) orelse return error.NoBoard;
    try testing.expectEqual(@as(u32, 1), base(rb).GetBoardModes(bare, &found, found.len));
    try testing.expectEqualStrings("1280x720", std.mem.sliceTo(&found[0].name, 0));
    try testing.expectEqual(@as(u32, 74_250_000), found[0].pixel_clock_hz);
    try testing.expectEqual(rtg.modes.RTGMF_DEFAULT, found[0].flags);
    try testing.expectEqual(rtg.modes.RTGMON_PRESENT, monitorOf(rb, bare).flags);
    try testing.expectEqual(@as(u32, 0), infoOf(rb, bare).flags & rtg.boards.RTGBF_NO_DISPLAY);
    driverBase(rb).DeleteBoard(bare);

    // Bytes that do not sum to zero are no EDID: not kept, and the same
    // one mode.
    var broken: [256]u8 = undefined;
    @memcpy(&broken, portable_bytes);
    broken[20] ^= 0xFF;
    fk.monitor_edid = &broken;
    const doubtful = fake.makeBoardFrom(fk, &sized) orelse return error.NoBoard;
    try testing.expectEqual(@as(u32, 1), base(rb).GetBoardModes(doubtful, null, 0));
    try testing.expectEqual(@as(u32, 0), base(rb).ReadBoardEDID(doubtful, null, 0));
    try testing.expectEqual(rtg.modes.RTGMON_PRESENT, monitorOf(rb, doubtful).flags);
    // A driver that cannot say what is on its connector has none there.
    fk.detect_answer = rtg.errors.RTGERR_IO;
    driverBase(rb).MonitorChanged(doubtful);
    monitors.service(rb);
    try testing.expectEqual(@as(u32, 0), monitorOf(rb, doubtful).flags);
    try testing.expect(infoOf(rb, doubtful).flags & rtg.boards.RTGBF_NO_DISPLAY != 0);
    try testing.expectEqual(@as(u32, 1), base(rb).GetBoardModes(doubtful, null, 0));
    driverBase(rb).DeleteBoard(doubtful);
    try tearDown(rb);
}

test "two monitors in turn: the list made again, a mode's number kept, the task told" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const sys = rb.sys_base;
    const board = try makeConnector(rb, portable_bytes, fake.mode_table.len);
    var first: [16]rtg.RtgMode = undefined;
    try testing.expectEqual(@as(u32, 9), base(rb).GetBoardModes(board, &first, first.len));
    // The driver's own took the first three numbers, the monitor's the
    // next nine.
    try testing.expectEqual(@as(u32, 4), first[0].id);

    // A task that asked is told.
    const bit = sys.AllocSignal(-1);
    try testing.expect(bit >= 0);
    const mask = @as(u32, 1) << @intCast(bit);
    const notify = base(rb).AddRtgNotify(sys.FindTask(null).?, mask).?;
    try testing.expectEqual(@as(?*rtg.RtgNotify, null), base(rb).AddRtgNotify(sys.FindTask(null).?, 0));
    const changes = infoOf(rb, board).changes;

    // A look that finds the monitor it found changes nothing, and tells
    // nobody.
    driverBase(rb).MonitorChanged(board);
    driverBase(rb).MonitorChanged(board);
    monitors.service(rb);
    try testing.expectEqual(@as(u32, 2), fk.log.detects);
    try testing.expectEqual(changes, infoOf(rb, board).changes);
    try testing.expectEqual(@as(u32, 0), sys.SetSignal(0, mask) & mask);

    // Another monitor: its one mode is the list, with a number of its own.
    fk.monitor_edid = qhd_bytes;
    driverBase(rb).MonitorChanged(board);
    monitors.service(rb);
    var second: [16]rtg.RtgMode = undefined;
    try testing.expectEqual(@as(u32, 1), base(rb).GetBoardModes(board, &second, second.len));
    try testing.expectEqual(@as(u32, 2560), second[0].width);
    try testing.expectEqual(@as(u32, 13), second[0].id);
    try testing.expectEqual(rtg.modes.RTGMF_DEFAULT, second[0].flags);
    try testing.expectEqual(changes + 1, infoOf(rb, board).changes);
    try testing.expect(sys.SetSignal(0, mask) & mask != 0);
    try testing.expectEqualStrings("", std.mem.sliceTo(&monitorOf(rb, board).name, 0));

    // The monitor taken off: the driver's own modes again, as they were.
    fk.monitor_there = false;
    driverBase(rb).MonitorChanged(board);
    monitors.service(rb);
    try testing.expectEqual(@as(u32, 3), base(rb).GetBoardModes(board, &second, second.len));
    try testing.expectEqual(@as(u32, 2), second[0].id);
    try testing.expectEqual(@as(u32, 1), base(rb).FindBoardMode(board, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY));
    try testing.expect(infoOf(rb, board).flags & rtg.boards.RTGBF_NO_DISPLAY != 0);
    try testing.expect(sys.SetSignal(0, mask) & mask != 0);

    // The first monitor again: every mode has the number it had.
    fk.monitor_there = true;
    fk.monitor_edid = portable_bytes;
    driverBase(rb).MonitorChanged(board);
    monitors.service(rb);
    try testing.expectEqual(@as(u32, 9), base(rb).GetBoardModes(board, &second, second.len));
    for (first[0..9], second[0..9]) |before, after| {
        try testing.expectEqual(before.id, after.id);
        try testing.expectEqual(before.width, after.width);
        try testing.expectEqual(before.flags, after.flags);
    }

    // A notification given back tells no more.
    _ = sys.SetSignal(0, mask);
    base(rb).RemRtgNotify(notify);
    base(rb).RemRtgNotify(null);
    fk.monitor_edid = uhd_bytes;
    driverBase(rb).MonitorChanged(board);
    monitors.service(rb);
    try testing.expectEqual(@as(u32, 0), sys.SetSignal(0, mask) & mask);
    try testing.expectEqual(@as(u32, 2), base(rb).GetBoardModes(board, null, 0));

    sys.FreeSignal(bit);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

/// A detailed timing of a small picture at 60 a second: `width` by
/// `height` in a line of `width + 36` clocks and a frame of
/// `height + 18` lines, the horizontal front porch `h_front`, both sync
/// pulses high.
fn smallTiming(width: u8, height: u8, h_front: u8) [18]u8 {
    const whole: u32 = (@as(u32, width) + 36) * (@as(u32, height) + 18);
    const clock_10khz: u16 = @intCast(whole * 60 / 10_000);
    return .{ @truncate(clock_10khz), @truncate(clock_10khz >> 8), width, 36, 0, height, 18, 0, h_front, 8, 0x22, 0, 0, 0, 0, 0, 0, 0x1E };
}

/// A monitor of one or two small modes, named in full: the first is the
/// one it prefers.
fn smallMonitor(first: [18]u8, second: ?[18]u8) [1]edid.Block {
    var block: edid.Block = @splat(0);
    for (38..54) |i| block[i] = 0x01;
    @memcpy(block[54..72], &first);
    if (second) |timing| @memcpy(block[72..90], &timing);
    return .{sealed(block)};
}

test "a board that shows when its monitor changes: the mode again where the new one has it, none where it has not" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    // Three monitors of pictures small enough for the tests' display
    // memory: one of 64 by 32; one that prefers 32 by 32 and has 64 by 32
    // too, with another front porch; one of 32 by 32 alone.
    const wide_only = smallMonitor(smallTiming(64, 32, 8), null);
    const both = smallMonitor(smallTiming(32, 32, 8), smallTiming(64, 32, 12));
    const square_only = smallMonitor(smallTiming(32, 32, 8), null);
    const board = try makeConnector(rb, std.mem.sliceAsBytes(&wide_only), 0);
    const wide = base(rb).FindBoardMode(board, 64, 32, rtg.RTG_ANY, rtg.RTG_ANY);
    try testing.expect(wide != 0);
    const bm = base(rb).AllocBitMap(board, 64, 32, @intFromEnum(rtg.PixelFormat.rgb565), rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, bm));
    try testing.expectEqual(@as(u32, 1), fk.log.set_mode);
    try testing.expectEqual(@as(u32, 8), fk.log.last_timings.h_front);

    // A monitor that has the mode too: the board stays in it, its driver
    // handed the mode again with the timing this monitor gives it, and
    // what was shown with it - it stays shown.
    fk.monitor_edid = std.mem.sliceAsBytes(&both);
    driverBase(rb).MonitorChanged(board);
    monitors.service(rb);
    try testing.expectEqual(@as(u32, 2), fk.log.set_mode);
    try testing.expectEqual(rtg.boards.RTGSHOW_MODE_CHANGED | rtg.boards.RTGSHOW_DIRECT, fk.log.last_flags);
    try testing.expectEqual(wide, fk.log.last_mode.id);
    try testing.expectEqual(@as(u32, 12), fk.log.last_timings.h_front);
    try testing.expectEqual(@as(u32, 1), fk.log.band_count);
    try testing.expectEqual(bm, fk.log.bands[0].bitmap);
    try testing.expectEqual(bm, base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(bm.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);
    var info = infoOf(rb, board);
    try testing.expectEqual(wide, info.mode_id);
    try testing.expect(info.flags & rtg.boards.RTGBF_MODE_SET != 0);
    // The new monitor's list: the mode the board is in, and the one this
    // monitor prefers, which is the default.
    var found: [16]rtg.RtgMode = undefined;
    try testing.expectEqual(@as(u32, 2), base(rb).GetBoardModes(board, &found, found.len));
    try testing.expectEqual(@as(u32, 64), found[0].width);
    try testing.expectEqual(rtg.modes.RTGMF_CURRENT, found[0].flags);
    try testing.expectEqual(rtg.modes.RTGMF_DEFAULT, found[1].flags);

    // A monitor that has not got the mode: the board shows nothing and is
    // in none, and the buffer can go.
    fk.monitor_edid = std.mem.sliceAsBytes(&square_only);
    driverBase(rb).MonitorChanged(board);
    monitors.service(rb);
    try testing.expectEqual(@as(u32, 2), fk.log.set_mode);
    try testing.expectEqual(@as(u32, 0), fk.log.band_count);
    try testing.expect(base(rb).BoardDisplayBitMap(board) == null);
    try testing.expect(bm.flags & rtg.bitmaps.RTGBMF_SHOWING == 0);
    info = infoOf(rb, board);
    try testing.expectEqual(@as(u32, 0), info.mode_id);
    try testing.expectEqual(@as(u32, 0), info.flags & rtg.boards.RTGBF_MODE_SET);
    try testing.expectEqual(@as(u32, 1), base(rb).GetBoardModes(board, &found, found.len));
    try testing.expectEqual(rtg.modes.RTGMF_DEFAULT, found[0].flags);
    // The mode it was in is not the board's to be put in until a monitor
    // has it, nor its buffer one to show in the mode that is.
    try testing.expectEqual(rtg.errors.RTGERR_BAD_MODE, setMode(rb, board, wide));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_DISPLAYABLE, base(rb).ShowBitMap(board, bm));
    try testing.expectEqual(rtg.errors.RTGERR_OK, setMode(rb, board, 0));
    try testing.expectEqual(@as(u32, 32), infoOf(rb, board).width);

    // The driver that cannot bring the link up again for a monitor that
    // came leaves the board in no mode, showing nothing.
    const square = base(rb).AllocBitMap(board, 32, 32, @intFromEnum(rtg.PixelFormat.rgb565), rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, square));
    fk.monitor_edid = std.mem.sliceAsBytes(&both);
    fk.show_answer = rtg.errors.RTGERR_NO_DISPLAY;
    driverBase(rb).MonitorChanged(board);
    monitors.service(rb);
    try testing.expectEqual(@as(u32, 0), infoOf(rb, board).mode_id);
    try testing.expect(base(rb).BoardDisplayBitMap(board) == null);
    try testing.expectEqual(@as(u32, 0), fake.instanceOf(board).showing_count);

    base(rb).FreeBitMap(square);
    base(rb).FreeBitMap(bm);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "notifications: a board made, put in a mode and gone, each told and counted" {
    const rb = try setUp();
    defer kexec.deinit();
    const sys = rb.sys_base;
    const bit = sys.AllocSignal(-1);
    try testing.expect(bit >= 0);
    const mask = @as(u32, 1) << @intCast(bit);
    const notify = base(rb).AddRtgNotify(sys.FindTask(null).?, mask).?;

    const board = try makeBoard(rb);
    try testing.expect(sys.SetSignal(0, mask) & mask != 0);
    const made = infoOf(rb, board).changes;
    try testing.expectEqual(rtg.errors.RTGERR_OK, setMode(rb, board, 2));
    try testing.expect(sys.SetSignal(0, mask) & mask != 0);
    try testing.expectEqual(made + 1, infoOf(rb, board).changes);
    // A mode refused changes nothing and tells nobody.
    try testing.expectEqual(rtg.errors.RTGERR_BAD_MODE, setMode(rb, board, 9));
    try testing.expectEqual(@as(u32, 0), sys.SetSignal(0, mask) & mask);
    // Its device taken away: the board is gone, and says so.
    driverBase(rb).RemRtgDevice(board.device.?);
    fakeOf(rb).devices[0] = null;
    try testing.expect(sys.SetSignal(0, mask) & mask != 0);
    try testing.expectEqual(made + 2, infoOf(rb, board).changes);

    base(rb).RemRtgNotify(notify);
    sys.FreeSignal(bit);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "the standards' timings, for a driver that has a size and no monitor's word" {
    const rb = try setUp();
    defer kexec.deinit();
    var timings: rtg.RtgTimings = .{};
    try testing.expect(driverBase(rb).FindStandardTimings(1920, 1080, 60, &timings));
    try testing.expectEqual(@as(u32, 148_500_000), timings.pixel_clock_hz);
    try testing.expectEqual(@as(u32, 88), timings.h_front);
    try testing.expectEqual(@as(u32, 44), timings.h_sync);
    try testing.expectEqual(@as(u32, 148), timings.h_back);
    try testing.expectEqual(@as(u32, 4), timings.v_front);
    try testing.expectEqual(@as(u8, 16), timings.vic);
    try testing.expectEqual(rtg.modes.RTGTM_HSYNC_HIGH | rtg.modes.RTGTM_VSYNC_HIGH, timings.flags);
    try testing.expectEqual(@as(u32, 60_000), modes.refreshOf(&timings));
    // VESA's 1024x768: both pulses low, and no number of CEA's.
    try testing.expect(driverBase(rb).FindStandardTimings(1024, 768, 60, &timings));
    try testing.expectEqual(@as(u32, 65_000_000), timings.pixel_clock_hz);
    try testing.expectEqual(@as(u32, 0), timings.flags);
    try testing.expectEqual(@as(u8, 0), timings.vic);
    // What no standard here times is left as it was.
    const before = timings;
    try testing.expect(!driverBase(rb).FindStandardTimings(1920, 1200, 60, &timings));
    try testing.expect(!driverBase(rb).FindStandardTimings(1920, 1080, 75, &timings));
    try testing.expectEqual(before, timings);
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

    driverBase(rb).DeleteBoard(board);
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

/// A board of the test driver's with one mode of that size in RGB565: a
/// display small enough for its pictures to fit the tests' memory.
fn makeDisplay(rb: *RtgBase, width: u32, height: u32) !*rtg.RtgBoard {
    return fake.makeDisplay(fakeOf(rb), width, height, .rgb565) orelse error.NoBoard;
}

/// A second mode on a display, of that size: its number.
fn addMode(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32) u32 {
    const timings: rtg.RtgTimings = .{ .h_active = width, .v_active = height };
    return driverBase(rb).AddBoardMode(board, &timings, @intFromEnum(rtg.PixelFormat.rgb565), 0);
}

test "the mode and the bands as one step; a buffer lives through a mode change" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeDisplay(rb, 16, 16);
    try testing.expectEqual(@as(u32, 2), addMode(rb, board, 32, 8));
    const glass = fake.instanceOf(board);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    const showing = rtg.bitmaps.RTGBMF_SHOWING;
    const changed = rtg.boards.RTGSHOW_MODE_CHANGED;
    // A picture this board is shown is one its display reads itself.
    const direct = rtg.boards.RTGSHOW_DIRECT;
    // Buffers are the board's, in a mode or not.
    const square = base(rb).AllocBitMap(board, 16, 16, format, displayable).?;
    const wide = base(rb).AllocBitMap(board, 32, 8, format, displayable).?;
    const square_pixels = square.pixels.?;
    const free_before = freeOf(rb, board);

    // The first show of a board in no mode puts it in its default: one
    // call of the driver's, with the mode and the picture.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, square));
    try testing.expectEqual(@as(u32, 1), fk.log.shown);
    try testing.expectEqual(changed | direct, fk.log.last_flags);
    try testing.expectEqual(@as(u32, 1), fk.log.last_mode.id);
    try testing.expectEqual(@as(u32, 1), infoOf(rb, board).mode_id);

    // Another mode and what is shown in it: one step, one call.
    const in_wide = [_]rtg.RtgBand{.{ .bitmap = wide }};
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 2, &in_wide, in_wide.len));
    try testing.expectEqual(@as(u32, 2), fk.log.shown);
    try testing.expectEqual(changed | direct, fk.log.last_flags);
    try testing.expectEqual(@as(u32, 2), fk.log.last_mode.id);
    try testing.expectEqual(@as(u32, 32), fk.log.last_timings.h_active);
    try testing.expectEqual(wide, fk.log.last_show_bitmap.?);
    try testing.expectEqual(@as(u32, 2), glass.mode_id);
    var info = infoOf(rb, board);
    try testing.expectEqual(@as(u32, 2), info.mode_id);
    try testing.expectEqual(@as(u32, 32), info.width);
    try testing.expectEqual(@as(u32, 8), info.height);
    try testing.expectEqual(wide.pitch, info.pitch);
    try testing.expect(wide.flags & showing != 0);
    try testing.expect(square.flags & showing == 0);
    try testing.expectEqual(wide, base(rb).BoardDisplayBitMap(board).?);
    // The buffer of the other mode was not touched: its memory is its
    // own, and none was given back.
    try testing.expectEqual(square_pixels, square.pixels.?);
    try testing.expectEqual(free_before, freeOf(rb, board));
    // It is no picture of this mode, and the driver is not asked.
    try testing.expectEqual(rtg.errors.RTGERR_NOT_DISPLAYABLE, base(rb).ShowBitMap(board, square));
    try testing.expectEqual(@as(u32, 2), fk.log.shown);

    // Shown again in the mode of its size.
    const in_square = [_]rtg.RtgBand{.{ .bitmap = square }};
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 1, &in_square, in_square.len));
    try testing.expect(square.flags & showing != 0);
    try testing.expect(wide.flags & showing == 0);
    try testing.expectEqual(@as(u32, 16), infoOf(rb, board).width);
    // The mode it is in, named or kept, is no mode set anew.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 1, &in_square, in_square.len));
    try testing.expectEqual(direct, fk.log.last_flags);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, &in_square, in_square.len));
    try testing.expectEqual(direct, fk.log.last_flags);

    // A mode with nothing shown in it.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 2, null, 0));
    try testing.expectEqual(changed, fk.log.last_flags);
    try testing.expectEqual(@as(u32, 0), fk.log.band_count);
    try testing.expect(base(rb).BoardDisplayBitMap(board) == null);
    info = infoOf(rb, board);
    try testing.expectEqual(@as(u32, 2), info.mode_id);
    try testing.expectEqual(@as(u32, 0), info.flags & rtg.boards.RTGBF_SHOWING);

    // A number the board has no mode of, and more bands than a display
    // shows: refused before anything is asked.
    const shown = fk.log.shown;
    try testing.expectEqual(rtg.errors.RTGERR_BAD_MODE, base(rb).ShowBoard(board, 9, null, 0));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).ShowBoard(board, 0, &in_wide, rtg.RTG_MAX_BANDS + 1));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).ShowBoard(board, 0, null, 1));
    try testing.expectEqual(shown, fk.log.shown);

    base(rb).FreeBitMap(wide);
    base(rb).FreeBitMap(square);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "another mode refused leaves the mode and what was shown; where that is gone too, the board is in none" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeDisplay(rb, 16, 16);
    _ = addMode(rb, board, 32, 8);
    const glass = fake.instanceOf(board);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    const showing = rtg.bitmaps.RTGBMF_SHOWING;
    const square = base(rb).AllocBitMap(board, 16, 16, format, displayable).?;
    const wide = base(rb).AllocBitMap(board, 32, 8, format, displayable).?;
    const in_wide = [_]rtg.RtgBand{.{ .bitmap = wide }};

    // A board in no mode whose first show is refused stays in none.
    fk.show_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, base(rb).ShowBitMap(board, square));
    try testing.expectEqual(@as(u32, 1), fk.log.shown);
    try testing.expectEqual(@as(u32, 0), infoOf(rb, board).mode_id);
    try testing.expect(square.flags & showing == 0);

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, square));
    const swaps = swapsOf(rb, board);
    const changes = infoOf(rb, board).changes;
    const shown = fk.log.shown;

    // Another mode the driver refuses: it shows nothing then, and is
    // asked for what was shown before, in the mode before. Neither side
    // has moved when the call comes back.
    fk.show_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, base(rb).ShowBoard(board, 2, &in_wide, in_wide.len));
    try testing.expectEqual(shown + 2, fk.log.shown);
    try testing.expectEqual(@as(u32, 1), fk.log.last_mode.id);
    try testing.expectEqual(square, fk.log.last_show_bitmap.?);
    try testing.expectEqual(@as(u32, 1), glass.mode_id);
    try testing.expectEqual(@as(u32, 1), glass.showing_count);
    try testing.expectEqual(square, glass.showing[0].bitmap);
    var info = infoOf(rb, board);
    try testing.expectEqual(@as(u32, 1), info.mode_id);
    try testing.expectEqual(@as(u32, 16), info.width);
    try testing.expectEqual(changes, info.changes);
    try testing.expectEqual(square, base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(square.flags & showing != 0);
    try testing.expect(wide.flags & showing == 0);
    try testing.expectEqual(swaps, swapsOf(rb, board));
    // The buffer refused can go, the one shown cannot.
    base(rb).FreeBitMap(square);
    try testing.expectEqual(square, base(rb).BoardDisplayBitMap(board).?);

    // Where the driver cannot show what was shown either, the board is in
    // no mode and shows nothing, on both sides, and says so.
    fk.show_answer = rtg.errors.RTGERR_NO_MEMORY;
    fk.show_refusals = 2;
    try testing.expectEqual(rtg.errors.RTGERR_NO_MEMORY, base(rb).ShowBoard(board, 2, &in_wide, in_wide.len));
    try testing.expectEqual(@as(u32, 0), glass.showing_count);
    info = infoOf(rb, board);
    try testing.expectEqual(@as(u32, 0), info.mode_id);
    try testing.expectEqual(@as(u32, 0), info.flags & (rtg.boards.RTGBF_MODE_SET | rtg.boards.RTGBF_SHOWING));
    try testing.expectEqual(changes + 1, info.changes);
    try testing.expect(base(rb).BoardDisplayBitMap(board) == null);
    try testing.expect(square.flags & showing == 0);
    var found: [4]rtg.RtgMode = undefined;
    _ = modesOf4(rb, board, &found);
    try testing.expectEqual(@as(u32, 0), (found[0].flags | found[1].flags) & rtg.modes.RTGMF_CURRENT);

    // The next show puts it in a mode again.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 2, &in_wide, in_wide.len));
    try testing.expectEqual(rtg.boards.RTGSHOW_MODE_CHANGED | rtg.boards.RTGSHOW_DIRECT, fk.log.last_flags);
    try testing.expectEqual(@as(u32, 2), infoOf(rb, board).mode_id);

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(wide);
    base(rb).FreeBitMap(square);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

/// The board's modes into a short list; how many there are.
fn modesOf4(rb: *RtgBase, board: *rtg.RtgBoard, into: *[4]rtg.RtgMode) u32 {
    return base(rb).GetBoardModes(board, into, into.len);
}

test "showing a buffer, and what may not be shown" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeDisplay(rb, 16, 16);
    const other = try makeDisplay(rb, 16, 16);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;

    const hidden = base(rb).AllocBitMap(board, 16, 16, format, 0).?;
    const up = base(rb).AllocBitMap(board, 16, 16, format, displayable).?;
    const small = base(rb).AllocBitMap(board, 8, 16, format, displayable).?;
    const short = base(rb).AllocBitMap(board, 16, 8, format, displayable).?;
    const deep = base(rb).AllocBitMap(board, 16, 16, @intFromEnum(rtg.PixelFormat.bgra32), displayable).?;
    const elsewhere = base(rb).AllocBitMap(other, 16, 16, format, displayable).?;

    // Not made to be shown, not the mode's size, not its format, not this
    // board's: each refused by the library, the driver not asked.
    try testing.expectEqual(rtg.errors.RTGERR_NOT_DISPLAYABLE, base(rb).ShowBitMap(board, hidden));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_DISPLAYABLE, base(rb).ShowBitMap(board, small));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_DISPLAYABLE, base(rb).ShowBitMap(board, short));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_FORMAT, base(rb).ShowBitMap(board, deep));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).ShowBitMap(board, elsewhere));
    try testing.expectEqual(@as(u32, 0), fk.log.shown);
    try testing.expectEqual(@as(u32, 0), infoOf(rb, board).mode_id);

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, up));
    try testing.expectEqual(up, base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(up.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);
    // The driver was handed the one buffer as a band from the top.
    try testing.expectEqual(@as(u32, 1), fk.log.band_count);
    try testing.expectEqual(up, fk.log.bands[0].bitmap);
    try testing.expectEqual(@as(u32, 0), fk.log.bands[0].line);

    // What the board is reading is not the caller's to take away.
    base(rb).FreeBitMap(up);
    try testing.expectEqual(up, base(rb).BoardDisplayBitMap(board).?);

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    try testing.expect(base(rb).BoardDisplayBitMap(board) == null);
    try testing.expect(up.flags & rtg.bitmaps.RTGBMF_SHOWING == 0);
    // The board stays in its mode with nothing shown.
    try testing.expectEqual(@as(u32, 1), infoOf(rb, board).mode_id);

    base(rb).FreeBitMap(elsewhere);
    base(rb).FreeBitMap(deep);
    base(rb).FreeBitMap(short);
    base(rb).FreeBitMap(small);
    base(rb).FreeBitMap(up);
    base(rb).FreeBitMap(hidden);
    driverBase(rb).DeleteBoard(other);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "showing buffers in bands, and what may not be shown so" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeDisplay(rb, 16, 16);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);

    const back = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const front = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const hidden = base(rb).AllocBitMap(board, 16, 16, format, 0).?;
    const small = base(rb).AllocBitMap(board, 16, 8, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;

    // The back buffer from the top, the front one from line 6 on, its own
    // first row there.
    const two = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = front, .line = 6, .origin = 6 } };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, &two, two.len));
    try testing.expectEqual(@as(u32, 2), fk.log.band_count);
    try testing.expectEqual(@as(u32, 6), fk.log.bands[1].line);
    try testing.expectEqual(front, base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(back.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);
    try testing.expect(front.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);

    // Lines out of order, a first band below the top, a buffer that
    // cannot be shown, one that is not the mode's size.
    const unordered = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = front, .line = 6 }, .{ .bitmap = back, .line = 4 } };
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).ShowBoard(board, 0, &unordered, unordered.len));
    const low = [_]rtg.RtgBand{.{ .bitmap = back, .line = 2 }};
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).ShowBoard(board, 0, &low, low.len));
    const unseen = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = hidden, .line = 8 } };
    try testing.expectEqual(rtg.errors.RTGERR_NOT_DISPLAYABLE, base(rb).ShowBoard(board, 0, &unseen, unseen.len));
    const short = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = small, .line = 4 } };
    try testing.expectEqual(rtg.errors.RTGERR_NOT_DISPLAYABLE, base(rb).ShowBoard(board, 0, &short, short.len));
    try testing.expectEqual(@as(u32, 1), fk.log.shown);
    // One row repeated over a band; a buffer of no rows refused for it.
    const row = base(rb).AllocBitMap(board, 16, 1, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const repeated = [_]rtg.RtgBand{ .{ .bitmap = row, .flags = rtg.RTGBANDF_REPEAT }, .{ .bitmap = front, .line = 6, .origin = 6 } };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, &repeated, repeated.len));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, &two, two.len));
    base(rb).FreeBitMap(row);
    try testing.expectEqual(@as(u32, 3), fk.log.shown);

    // One buffer again: the other is no longer read. No bands at all
    // show nothing.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, back));
    try testing.expect(front.flags & rtg.bitmaps.RTGBMF_SHOWING == 0);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, null, 0));
    try testing.expect(base(rb).BoardDisplayBitMap(board) == null);
    try testing.expect(back.flags & rtg.bitmaps.RTGBMF_SHOWING == 0);

    base(rb).FreeBitMap(small);
    base(rb).FreeBitMap(hidden);
    base(rb).FreeBitMap(front);
    base(rb).FreeBitMap(back);
    driverBase(rb).DeleteBoard(board);

    // A board that shows one whole buffer takes no bands, and says so:
    // one buffer from its own top is what ShowBitMap shows.
    fk.without_engine = true;
    const plain = try makeDisplay(rb, 16, 16);
    try testing.expectEqual(@as(u32, 0), infoOf(rb, plain).caps & rtg.boards.RTGBC_BANDS);
    const one = base(rb).AllocBitMap(plain, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const another = base(rb).AllocBitMap(plain, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const banded = [_]rtg.RtgBand{ .{ .bitmap = one }, .{ .bitmap = another, .line = 6, .origin = 6 } };
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).ShowBoard(plain, 0, &banded, banded.len));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(plain, 0, &banded, 1));
    try testing.expectEqual(one, base(rb).BoardDisplayBitMap(plain).?);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(plain, null));
    base(rb).FreeBitMap(another);
    base(rb).FreeBitMap(one);
    driverBase(rb).DeleteBoard(plain);
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

test "a buffer: a format that is none, and a board with no display memory" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);

    // A number past every format is refused as a format not known.
    const board = try makeBoard(rb);
    try testing.expect(base(rb).AllocBitMap(board, 8, 8, 256, 0) == null);
    try testing.expect(base(rb).AllocBitMap(board, 8, 8, ~@as(u32, 0), 0) == null);
    driverBase(rb).DeleteBoard(board);

    // A board that reports no display memory says so, and no memory was
    // taken for the buffer's handle: the leak check holds that.
    fk.region_size = 0;
    const dark = try makeBoard(rb);
    try testing.expect(base(rb).AllocBitMap(dark, 8, 8, format, 0) == null);
    driverBase(rb).DeleteBoard(dark);
    try tearDown(rb);
}

test "boards are numbered as they are made, and one that was not made takes no number" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);

    const first = try makeBoard(rb);
    try testing.expectEqualStrings("fake.0", std.mem.span(first.node.name.?));
    fk.create_answer = rtg.errors.RTGERR_NO_DISPLAY;
    try testing.expect(fake.makeBoard(fk) == null);
    fk.create_answer = rtg.errors.RTGERR_OK;
    const second = try makeBoard(rb);
    try testing.expectEqualStrings("fake.1", std.mem.span(second.node.name.?));
    try testing.expectEqual(second.node.name, second.info.name);

    driverBase(rb).DeleteBoard(second);
    driverBase(rb).DeleteBoard(first);
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
    const board = try makeDisplay(rb, 16, 16);
    const glass = fake.instanceOf(board);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const showing = rtg.bitmaps.RTGBMF_SHOWING;
    const first = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const second = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;

    // The board is handed what was asked for: the buffer.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, first));
    try testing.expectEqual(first, fk.log.last_show_bitmap.?);
    try testing.expectEqual(@as(u32, 1), glass.showing_count);
    try testing.expectEqual(first, glass.showing[0].bitmap);
    // A show that works is a picture counted.
    const swaps = swapsOf(rb, board);
    try testing.expectEqual(@as(u32, 1), swaps);

    // Refused: the answer is the driver's, and neither side has moved -
    // the library's marks, what it answers, its count of pictures, and
    // what the board itself shows.
    fk.show_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, base(rb).ShowBitMap(board, second));
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
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, base(rb).ShowBitMap(board, null));
    try testing.expectEqual(first, base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(first.flags & showing != 0);
    try testing.expect(board.info.flags & rtg.boards.RTGBF_SHOWING != 0);
    try testing.expectEqual(@as(u32, 1), glass.showing_count);

    // The refusal was that show's alone: the next one works.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    try testing.expect(base(rb).BoardDisplayBitMap(board) == null);
    try testing.expectEqual(@as(u32, 0), glass.showing_count);

    base(rb).FreeBitMap(first);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "bands that fail change nothing: what was shown stays, in the library and on the board" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeDisplay(rb, 16, 16);
    const glass = fake.instanceOf(board);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const showing = rtg.bitmaps.RTGBMF_SHOWING;
    const back = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const front = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const third = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    const two = [_]rtg.RtgBand{ .{ .bitmap = back }, .{ .bitmap = front, .line = 6, .origin = 6 } };

    // One buffer up, then bands the board refuses: the one buffer stays,
    // and no picture is counted.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, back));
    const swaps = swapsOf(rb, board);
    fk.show_answer = rtg.errors.RTGERR_NO_MEMORY;
    try testing.expectEqual(rtg.errors.RTGERR_NO_MEMORY, base(rb).ShowBoard(board, 0, &two, two.len));
    try testing.expectEqual(swaps, swapsOf(rb, board));
    try testing.expectEqual(@as(u32, 2), fk.log.band_count); // it was asked
    try testing.expectEqual(back, base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(back.flags & showing != 0);
    try testing.expect(front.flags & showing == 0);
    try testing.expectEqual(@as(u32, 1), glass.showing_count);
    try testing.expectEqual(back, glass.showing[0].bitmap);

    // The same bands again, and they are up on both sides: a picture.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoard(board, 0, &two, two.len));
    try testing.expectEqual(swaps + 1, swapsOf(rb, board));
    try testing.expectEqual(front, base(rb).BoardDisplayBitMap(board).?);
    try testing.expectEqual(@as(u32, 2), glass.showing_count);
    try testing.expectEqual(@as(u32, 6), glass.showing[1].line);

    // A buffer refused over bands: the bands stay, and the buffer can go.
    fk.show_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, base(rb).ShowBitMap(board, third));
    try testing.expectEqual(front, base(rb).BoardDisplayBitMap(board).?);
    try testing.expect(back.flags & showing != 0 and front.flags & showing != 0);
    try testing.expect(third.flags & showing == 0);
    try testing.expectEqual(@as(u32, 2), glass.showing_count);
    base(rb).FreeBitMap(third);

    // One of the bands' own buffers refused alone: it is still up in its
    // band, so it stays marked.
    fk.show_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, base(rb).ShowBitMap(board, front));
    try testing.expect(front.flags & showing != 0);
    try testing.expectEqual(@as(u32, 2), glass.showing_count);

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(front);
    base(rb).FreeBitMap(back);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "what is written is handed on as the rectangle it is, cut to the buffer" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const bitmap = base(rb).AllocBitMap(board, 32, 20, format, 0).?;

    // The driver is told the buffer and the rectangle, shown or not.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(bitmap, &.{ .x = 3, .y = 4, .width = 5, .height = 6 }));
    try testing.expectEqual(bitmap, fk.log.last_refresh_bitmap.?);
    try testing.expectEqual(rtg.RtgRect{ .x = 3, .y = 4, .width = 5, .height = 6 }, fk.log.last_refresh);
    // No rectangle is all of the buffer.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(bitmap, null));
    try testing.expectEqual(rtg.RtgRect{ .x = 0, .y = 0, .width = 32, .height = 20 }, fk.log.last_refresh);
    // One that reaches past the buffer is as much of it as is inside; one
    // with nothing inside reaches no driver.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(bitmap, &.{ .x = 30, .y = -2, .width = 8, .height = 5 }));
    try testing.expectEqual(rtg.RtgRect{ .x = 30, .y = 0, .width = 2, .height = 3 }, fk.log.last_refresh);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(bitmap, &.{ .x = 0, .y = 18, .width = 32, .height = 40 }));
    try testing.expectEqual(rtg.RtgRect{ .x = 0, .y = 18, .width = 32, .height = 2 }, fk.log.last_refresh);
    const refreshed = fk.log.refreshed;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(bitmap, &.{ .x = 32, .y = 0, .width = 4, .height = 4 }));
    try testing.expectEqual(refreshed, fk.log.refreshed);

    base(rb).FreeBitMap(bitmap);
    driverBase(rb).DeleteBoard(board);
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

    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

/// The frames `board` has counted, as its stats say.
fn blanksOf(rb: *RtgBase, board: *rtg.RtgBoard) u32 {
    var stats: rtg.RtgBoardStats = .{};
    _ = base(rb).GetBoardStats(board, &stats, @sizeOf(rtg.RtgBoardStats));
    return stats.blanks;
}

/// Whether `board` says its frames just now, as its info says.
fn saysFrames(rb: *RtgBase, board: *rtg.RtgBoard) bool {
    return infoOf(rb, board).caps & rtg.boards.RTGBC_VBLANK != 0;
}

test "frames: counted as the driver says them, and the board says that it does" {
    const rb = try setUp();
    defer kexec.deinit();
    const board = try makeBoard(rb);

    // A board whose driver has said no frame counts none and says none.
    try testing.expectEqual(@as(u32, 0), blanksOf(rb, board));
    try testing.expect(!saysFrames(rb, board));

    fake.endFrame(board);
    fake.endFrame(board);
    fake.endFrame(board);
    try testing.expectEqual(@as(u32, 3), blanksOf(rb, board));
    try testing.expect(saysFrames(rb, board));
    // The frames only go up: the counters' reset leaves them.
    try testing.expectEqual(@as(isize, rtg.errors.RTGERR_OK), base(rb).BoardControl(board, rtg.boards.RTGCTRL_RESET_STATS, 0));
    try testing.expectEqual(@as(u32, 3), blanksOf(rb, board));
    // Another board's frames are its own.
    const other = try makeBoard(rb);
    try testing.expectEqual(@as(u32, 0), blanksOf(rb, other));
    try testing.expect(!saysFrames(rb, other));

    // A board a task waits for a frame of is not deleted from under it.
    const frames = &boards.privateOf(board).frames;
    var waiter: frame_state.Waiter = .{ .task = kexec.FindTask(kexec.SysBase, null).?, .mask = 0, .left = 2 };
    frame_state.add(rb.sys_base, frames, &waiter);
    driverBase(rb).DeleteBoard(board);
    try testing.expectEqual(board, base(rb).NextBoard(null).?);
    try testing.expectEqual(other, base(rb).NextBoard(board).?);
    fake.endFrame(board);
    try testing.expectEqual(@as(u32, 1), waiter.left);
    // Taken off with a frame still to come: the board is held to say
    // none until the next is said.
    try testing.expectEqual(@as(u32, 1), frame_state.remove(rb.sys_base, frames, &waiter));
    try testing.expect(!saysFrames(rb, board));
    fake.endFrame(board);
    try testing.expect(saysFrames(rb, board));
    try testing.expectEqual(@as(u32, 1), waiter.left);

    driverBase(rb).DeleteBoard(other);
    driverBase(rb).DeleteBoard(board);
    try testing.expect(base(rb).NextBoard(null) == null);
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
    const frames = &boards.privateOf(board).frames;
    // The library's own request, which every wait copies and none sends.
    const opened = rb.timer_io;
    try testing.expectEqual(timer.UNIT_MICROHZ, FakeTimer.opened_unit);
    frames_board = board;
    Sleep.install(&endOneFrame);
    defer Sleep.uninstall();
    // The board's driver says its frames: one was said.
    fake.endFrame(board);

    // The next frame: the task sleeps once, and the frame that ends
    // meanwhile wakes it. The limit never came, and is taken back; the
    // wait's waiter is off the board.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).WaitVBlank(board, 0));
    try testing.expect(frames.waiters == null);
    try testing.expectEqual(@as(u32, 1), Sleep.sleeps);
    try testing.expectEqual(@as(u32, 2), fk.log.frames_ended);
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
    try testing.expect(frames.waiters == null);
    try testing.expectEqual(@as(u32, 2), Sleep.sleeps);
    try testing.expectEqual(@as(u32, 4), Sleep.interrupts);
    try testing.expectEqual(@as(u32, 5), fk.log.frames_ended);
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
    try testing.expect(frames.waiters == null);
    try testing.expectEqual(@as(u32, 4), Sleep.sleeps);
    try testing.expectEqual(@as(u32, 6), Sleep.interrupts);
    try testing.expectEqual(@as(u32, 6), fk.log.frames_ended);
    try testing.expectEqual(@as(u32, 3), FakeTimer.aborted);
    try testing.expectEqual(opened, rb.timer_io);
    FakeTimer.abort_replies_later = false;
    // The frames the waits saw are the frames counted, and the board
    // still says them.
    try testing.expectEqual(@as(u32, 6), blanksOf(rb, board));
    try testing.expect(saysFrames(rb, board));

    driverBase(rb).DeleteBoard(board);
    try testing.expect(base(rb).NextBoard(null) == null);
    try tearDown(rb);
}

test "WaitVBlank: frames that stop are waited for no longer than the limit, and by the clock from then on" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    const frames = &boards.privateOf(board).frames;
    Sleep.install(&FakeTimer.expire);
    defer Sleep.uninstall();

    // A board that has said no frame is waited for by the clock: the
    // frames' time, no waiter on the board, and nothing taken back.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).WaitVBlank(board, 0));
    try testing.expectEqual(@as(u32, 1), Sleep.sleeps);
    try testing.expectEqual(@as(u32, 1), FakeTimer.sent);
    try testing.expectEqual(@as(u64, 16_667), FakeTimer.last_micros);
    try testing.expectEqual(@as(u32, 0), FakeTimer.aborted);
    try testing.expect(FakeTimer.waiting == null);
    try testing.expect(frames.waiters == null);
    // By the board's own rate, for each frame asked for.
    board.info.refresh_mhz = 50_000;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).WaitVBlank(board, 3));
    try testing.expectEqual(@as(u64, 3 * 20_000), FakeTimer.last_micros);
    board.info.refresh_mhz = 0;

    // It says a frame, and then no more: the limit's time passes while
    // the task sleeps, the waiter is off the board all the same, and the
    // board is held to say none.
    fake.endFrame(board);
    try testing.expect(saysFrames(rb, board));
    try testing.expectEqual(rtg.errors.RTGERR_TIMEOUT, base(rb).WaitVBlank(board, 2));
    try testing.expect(frames.waiters == null);
    try testing.expectEqual(@as(u32, 3), Sleep.sleeps);
    try testing.expectEqual(@as(u32, 1), fk.log.frames_ended);
    try testing.expectEqual(@as(u64, 2 * 2 * 16_667), FakeTimer.last_micros);
    try testing.expectEqual(@as(u32, 0), FakeTimer.aborted);
    try testing.expect(FakeTimer.waiting == null);
    try testing.expect(!saysFrames(rb, board));

    // From then on by the clock, and answered as a wait that was kept.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).WaitVBlank(board, 2));
    try testing.expectEqual(@as(u64, 2 * 16_667), FakeTimer.last_micros);
    try testing.expectEqual(@as(u32, 4), FakeTimer.sent);

    // The frames come again, one of the two asked for, and then no more:
    // the frame wakes nobody, and the limit ends the wait all the same.
    fake.endFrame(board);
    frames_board = board;
    frames_then_time = 0;
    Sleep.meanwhile = &oneFrameThenTime;
    const interrupts = Sleep.interrupts;
    try testing.expectEqual(rtg.errors.RTGERR_TIMEOUT, base(rb).WaitVBlank(board, 2));
    try testing.expect(frames.waiters == null);
    try testing.expectEqual(@as(u32, 3), fk.log.frames_ended);
    try testing.expectEqual(@as(u32, 5), Sleep.sleeps);
    try testing.expectEqual(interrupts + 2, Sleep.interrupts);
    try testing.expectEqual(@as(u32, 3), blanksOf(rb, board));
    try testing.expect(!saysFrames(rb, board));

    // With no clock to wait by nothing is waited for, on a board that
    // says its frames or not.
    const device = rb.timer_io.node.device;
    rb.timer_io.node.device = null;
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).WaitVBlank(board, 1));
    fake.endFrame(board);
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).WaitVBlank(board, 1));
    rb.timer_io.node.device = device;
    try testing.expectEqual(@as(u32, 5), FakeTimer.sent);

    driverBase(rb).DeleteBoard(board);
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
    const row: [*]u16 = @ptrCast(@alignCast(rowOf(bitmap, 0)));
    try testing.expectEqual(@as(u16, 0), row[11]);
    try testing.expectEqual(@as(u16, 0xBEEF), row[12]);
    try testing.expectEqual(@as(u16, 0xBEEF), row[15]);
    const past: [*]u16 = @ptrCast(@alignCast(rowOf(bitmap, 4)));
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
    driverBase(rb).DeleteBoard(board);
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
    const row: [*]u16 = @ptrCast(@alignCast(rowOf(source, 0)));
    for (0..16) |x| row[x] = @intCast(x + 1);
    const shift = rtg.RtgCopy{ .src_x = 0, .src_y = 0, .width = 8, .height = 1, .dest_x = 1, .dest_y = 0 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).CopyRect(source, source, &shift));
    try testing.expectEqual(@as(u16, 1), row[1]);
    try testing.expectEqual(@as(u16, 8), row[8]);

    base(rb).FreeBitMap(target);
    base(rb).FreeBitMap(source);
    driverBase(rb).DeleteBoard(board);
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
        const row: [*]u16 = @ptrCast(@alignCast(rowOf(source, @intCast(y))));
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
    const row1: [*]u16 = @ptrCast(@alignCast(rowOf(target, 1)));
    const row7: [*]u16 = @ptrCast(@alignCast(rowOf(target, 7)));
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
    var engine = board.ops.?.engine.?.*;
    engine.copy_rects = null;
    var ops = board.ops.?.*;
    ops.engine = &engine;
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

test "the backlight: its levels, kept by the library, lit with the first picture" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const board = try makeDisplay(rb, 16, 16);

    // A level for each per cent, full until something else is said, and
    // nothing lit yet.
    var info = infoOf(rb, board);
    try testing.expect(info.caps & rtg.boards.RTGBC_BRIGHTNESS != 0);
    try testing.expectEqual(@as(u32, 101), info.brightness_steps);
    try testing.expectEqual(@as(u32, 100), info.brightness);
    try testing.expectEqual(@as(u32, 0), fk.log.brightness_calls);

    // Set: applied, and kept by the library.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardBrightness(board, 60));
    try testing.expectEqual(@as(u32, 60), fk.log.brightness);
    try testing.expectEqual(@as(u32, 60), infoOf(rb, board).brightness);
    // Above the top of the range is the top of the range.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardBrightness(board, 400));
    try testing.expectEqual(@as(u32, 100), fk.log.brightness);
    try testing.expectEqual(@as(u32, 100), infoOf(rb, board).brightness);
    // One the driver could not set leaves what was.
    fk.brightness_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, base(rb).SetBoardBrightness(board, 20));
    try testing.expectEqual(@as(u32, 100), infoOf(rb, board).brightness);
    fk.brightness_answer = rtg.errors.RTGERR_OK;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardBrightness(board, 45));
    // The first picture leaves a brightness that was set.
    const calls = fk.log.brightness_calls;
    const picture = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, picture));
    try testing.expectEqual(calls, fk.log.brightness_calls);
    try testing.expectEqual(@as(u32, 45), fk.log.brightness);

    // A control the driver knows, and the one every board takes.
    try testing.expectEqual(@as(isize, 8), base(rb).BoardControl(board, rtg.tags.RTGCTRL_RGB_SHIFT, 7));
    try testing.expectEqual(rtg.tags.RTGCTRL_RGB_SHIFT, fk.log.last_control);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(picture);
    driverBase(rb).DeleteBoard(board);

    // A board nobody set: dark until its first picture, lit with it at
    // what its device's tags ask, and left alone by the next.
    const dimmed = [_]TagItem{
        .{ .tag = rtg.tags.RTGA_Brightness, .data = 40 },
        .{ .tag = utility.TAG_MORE, .data = @intFromPtr(fake.deviceTags()) },
    };
    fk.display = .{ .timings = .{ .h_active = 16, .v_active = 16 }, .format = .rgb565, .flags = rtg.modes.RTGMF_DEFAULT };
    const lit = fake.makeBoardFrom(fk, &dimmed) orelse return error.NoBoard;
    fk.display = null;
    try testing.expectEqual(@as(u32, 40), infoOf(rb, lit).brightness);
    const before = fk.log.brightness_calls;
    try testing.expectEqual(rtg.errors.RTGERR_OK, setMode(rb, lit, 0));
    try testing.expectEqual(before, fk.log.brightness_calls);
    const first = base(rb).AllocBitMap(lit, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(lit, first));
    try testing.expectEqual(before + 1, fk.log.brightness_calls);
    try testing.expectEqual(@as(u32, 40), fk.log.brightness);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(lit, first));
    try testing.expectEqual(before + 1, fk.log.brightness_calls);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(lit, null));
    base(rb).FreeBitMap(first);
    driverBase(rb).DeleteBoard(lit);

    // A line that is on or off has two levels; a driver with no line
    // wired has none, and the board no backlight to set.
    fk.brightness_steps = 2;
    const line = try makeBoard(rb);
    try testing.expectEqual(@as(u32, 2), infoOf(rb, line).brightness_steps);
    driverBase(rb).DeleteBoard(line);
    fk.brightness_steps = 0;
    const unwired = try makeBoard(rb);
    info = infoOf(rb, unwired);
    try testing.expectEqual(@as(u32, 0), info.caps & rtg.boards.RTGBC_BRIGHTNESS);
    try testing.expectEqual(@as(u32, 0), info.brightness_steps);
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).SetBoardBrightness(unwired, 50));
    driverBase(rb).DeleteBoard(unwired);
    try tearDown(rb);
}

test "a monitor's brightness is its own: read from it, and set with the first picture only where the device's tags ask it" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const dimmed = [_]TagItem{
        .{ .tag = rtg.tags.RTGA_Brightness, .data = 40 },
        .{ .tag = utility.TAG_MORE, .data = @intFromPtr(fake.deviceTags()) },
    };
    // A monitor on a connector keeps the brightness it has: its first
    // picture sets none, and one that is set is set.
    const small = smallMonitor(smallTiming(64, 32, 8), null);
    const monitor = try makeConnector(rb, std.mem.sliceAsBytes(&small), 0);
    fk.connector = false;
    try testing.expect(infoOf(rb, monitor).flags & rtg.boards.RTGBF_CONNECTOR != 0);
    try testing.expect(infoOf(rb, monitor).caps & rtg.boards.RTGBC_BRIGHTNESS != 0);
    const untouched = fk.log.brightness_calls;
    // What it is at is the monitor's to say, before a picture and after.
    fk.own_brightness = 35;
    try testing.expectEqual(@as(u32, 35), infoOf(rb, monitor).brightness);
    const seen = base(rb).AllocBitMap(monitor, 64, 32, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(monitor, seen));
    try testing.expectEqual(untouched, fk.log.brightness_calls);
    try testing.expectEqual(@as(u32, 35), infoOf(rb, monitor).brightness);
    // Its own buttons are followed.
    fk.own_brightness = 20;
    try testing.expectEqual(@as(u32, 20), infoOf(rb, monitor).brightness);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardBrightness(monitor, 70));
    try testing.expectEqual(untouched + 1, fk.log.brightness_calls);
    try testing.expectEqual(@as(u32, 70), fk.log.brightness);
    try testing.expectEqual(@as(u32, 70), infoOf(rb, monitor).brightness);
    // One that does not answer leaves what was last heard.
    fk.own_brightness = 10;
    fk.read_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(@as(u32, 70), infoOf(rb, monitor).brightness);
    fk.read_answer = rtg.errors.RTGERR_OK;
    try testing.expectEqual(@as(u32, 10), infoOf(rb, monitor).brightness);
    // Asleep it is not asked what it is at, and is still told one that
    // is set: the monitor keeps it.
    try testing.expectEqual(@as(i32, @intCast(rtg.boards.RTGPWR_ASLEEP)), base(rb).SetBoardPower(monitor, rtg.boards.RTGPWR_ASLEEP));
    const reads = fk.log.brightness_reads;
    fk.own_brightness = 5;
    try testing.expectEqual(@as(u32, 10), infoOf(rb, monitor).brightness);
    try testing.expectEqual(reads, fk.log.brightness_reads);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardBrightness(monitor, 60));
    try testing.expectEqual(untouched + 2, fk.log.brightness_calls);
    try testing.expectEqual(@as(i32, @intCast(rtg.boards.RTGPWR_ON)), base(rb).SetBoardPower(monitor, rtg.boards.RTGPWR_ON));
    try testing.expectEqual(@as(u32, 60), infoOf(rb, monitor).brightness);
    // Awake again it was asked, the once.
    try testing.expectEqual(reads + 1, fk.log.brightness_reads);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(monitor, null));
    base(rb).FreeBitMap(seen);
    driverBase(rb).DeleteBoard(monitor);
    // One whose device's tags ask a brightness has it with the first
    // picture.
    fk.connector = true;
    fk.monitor_there = true;
    fk.monitor_edid = std.mem.sliceAsBytes(&small);
    fk.modes = 0;
    const asked = fake.makeBoardFrom(fk, &dimmed) orelse return error.NoBoard;
    fk.connector = false;
    const unasked = fk.log.brightness_calls;
    const shown = base(rb).AllocBitMap(asked, 64, 32, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(asked, shown));
    try testing.expectEqual(unasked + 1, fk.log.brightness_calls);
    try testing.expectEqual(@as(u32, 40), fk.log.brightness);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(asked, null));
    base(rb).FreeBitMap(shown);
    driverBase(rb).DeleteBoard(asked);
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
    const board = try makeDisplay(rb, 16, 16);
    const shown = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, shown));
    try testing.expectEqual(@as(u32, 1), swapsOf(rb, board));
    try testing.expectEqual(@as(isize, rtg.errors.RTGERR_OK), base(rb).BoardControl(board, reset, 7));
    try testing.expectEqual(reset, fk.log.last_control);
    try testing.expectEqual(@as(u32, 0), swapsOf(rb, board));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(shown);
    driverBase(rb).DeleteBoard(board);

    // A board whose driver has none takes it all the same, and no other
    // code.
    fk.without_engine = true;
    const plain = try makeDisplay(rb, 16, 16);
    const picture = base(rb).AllocBitMap(plain, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(plain, picture));
    try testing.expectEqual(@as(u32, 1), swapsOf(rb, plain));
    const controls = fk.log.control_calls;
    try testing.expectEqual(@as(isize, rtg.errors.RTGERR_OK), base(rb).BoardControl(plain, reset, 0));
    try testing.expectEqual(@as(u32, 0), swapsOf(rb, plain));
    try testing.expectEqual(controls, fk.log.control_calls);
    try testing.expectEqual(@as(isize, rtg.errors.RTGERR_NOT_SUPPORTED), base(rb).BoardControl(plain, rtg.tags.RTGCTRL_RGB_SHIFT, 7));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(plain, null));
    base(rb).FreeBitMap(picture);
    driverBase(rb).DeleteBoard(plain);
    try tearDown(rb);
}

test "mirrored by the board's own hardware: the axes its driver said, handed on as asked, the picture shown again" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const board = try makeDisplay(rb, 16, 16);
    const both = rtg.boards.RTGBC_MIRROR_X | rtg.boards.RTGBC_MIRROR_Y;

    var info = infoOf(rb, board);
    try testing.expectEqual(both, info.caps & both);
    // A board reports itself the right way up until it is turned.
    try testing.expectEqual(@as(u8, 0), info.mirror_x);
    try testing.expectEqual(@as(u8, 0), info.mirror_y);
    const picture = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, picture));
    const shown = fk.log.shown;
    const changes = info.changes;

    // Mirroring is handed to the board as asked and remembered, what a
    // caller draws on keeps its sides, and the driver is asked for what
    // it shows again: a stream sends its lines the other way round.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).MirrorBoard(board, true, false));
    try testing.expectEqual(@as(u32, 1), fk.log.mirrors);
    try testing.expect(fk.log.last_mirror_x and !fk.log.last_mirror_y);
    try testing.expectEqual(shown + 1, fk.log.shown);
    try testing.expectEqual(picture, fk.log.bands[0].bitmap);
    info = infoOf(rb, board);
    try testing.expectEqual(@as(u8, 1), info.mirror_x);
    try testing.expectEqual(@as(u8, 0), info.mirror_y);
    try testing.expectEqual(@as(u32, 16), info.width);
    try testing.expect(info.changes != changes);
    // The same again changes nothing and asks nobody.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).MirrorBoard(board, true, false));
    try testing.expectEqual(@as(u32, 1), fk.log.mirrors);
    try testing.expectEqual(shown + 1, fk.log.shown);

    // A turn the driver refuses leaves the picture as it was turned.
    fk.mirror_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, base(rb).MirrorBoard(board, true, true));
    fk.mirror_answer = rtg.errors.RTGERR_OK;
    info = infoOf(rb, board);
    try testing.expectEqual(@as(u8, 1), info.mirror_x);
    try testing.expectEqual(@as(u8, 0), info.mirror_y);
    // And one whose picture cannot be shown again is turned back.
    fk.show_answer = rtg.errors.RTGERR_NO_DISPLAY;
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, base(rb).MirrorBoard(board, false, true));
    try testing.expect(fk.log.last_mirror_x and !fk.log.last_mirror_y);
    try testing.expectEqual(@as(u8, 0), infoOf(rb, board).mirror_y);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).MirrorBoard(board, false, false));
    try testing.expect(!fk.log.last_mirror_x and !fk.log.last_mirror_y);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(picture);
    driverBase(rb).DeleteBoard(board);

    // A stream that can send its lines last first and cannot turn one
    // round: top to bottom alone, and the other axis refused whole.
    fk.mirror_axes = rtg.boards.RTGBC_MIRROR_Y;
    const stream = try makeBoard(rb);
    fk.mirror_axes = both;
    try testing.expectEqual(rtg.boards.RTGBC_MIRROR_Y, infoOf(rb, stream).caps & both);
    const mirrors = fk.log.mirrors;
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).MirrorBoard(stream, true, true));
    try testing.expectEqual(mirrors, fk.log.mirrors);
    try testing.expectEqual(@as(u8, 0), infoOf(rb, stream).mirror_y);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).MirrorBoard(stream, false, true));
    try testing.expect(!fk.log.last_mirror_x and fk.log.last_mirror_y);
    try testing.expectEqual(@as(u8, 1), infoOf(rb, stream).mirror_y);
    driverBase(rb).DeleteBoard(stream);
    try tearDown(rb);
}

test "a board whose pixels go out as they are written will not turn" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    fk.cannot_turn = true;
    const board = try makeBoard(rb);
    try testing.expectEqual(rtg.errors.RTGERR_OK, setMode(rb, board, 0));

    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(@as(u32, 0), info.caps & (rtg.boards.RTGBC_MIRROR_X | rtg.boards.RTGBC_MIRROR_Y));

    const width = info.width;
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).MirrorBoard(board, true, true));
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).MirrorBoard(board, false, true));
    // Refused means nothing moved: what it says about itself is unchanged.
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    try testing.expectEqual(width, info.width);
    try testing.expectEqual(@as(u8, 0), info.mirror_x);
    try testing.expectEqual(@as(u8, 0), info.mirror_y);
    try testing.expectEqual(@as(u32, 0), fk.log.mirrors);
    // Unturned is what it is.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).MirrorBoard(board, false, false));

    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

/// The first byte of a buffer's row.
fn rowOf(bitmap: *const rtg.RtgBitMap, y: u32) [*]u8 {
    return bitmap.pixels.? + @as(usize, y) * bitmap.pitch;
}

/// Whether pixel (x, y) of a converted image is the image's own, by its
/// mask.
fn opaqueAt(image: *const rtg.RtgPointerImage, x: u32, y: u32) bool {
    return image.mask[y * image.mask_pitch + x / 8] & (@as(u8, 0x80) >> @intCast(x % 8)) != 0;
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
    try testing.expectEqual(rtg.errors.RTGERR_OK, setMode(rb, board, 0));
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
    try testing.expect(opaqueAt(made, 0, 0) and !opaqueAt(made, 1, 0) and opaqueAt(made, 2, 0));
    try testing.expect(opaqueAt(made, 0, 1) and !opaqueAt(made, 1, 1) and opaqueAt(made, 2, 1));
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
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "the pointer on a 32-bit board: its channels in the order the format names them" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    try testing.expectEqual(rtg.errors.RTGERR_OK, setMode(rb, board, 0));
    board.info.format = .bgra32;

    // A red pixel and a grey one, rgba32.
    var pixels = [_]u32{ rgba(0xFF0000FF), rgba(0x102030FF) };
    const image = rtg.Surface{ .pixels = @ptrCast(&pixels), .width = 2, .height = 1, .pitch = 8, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, &image, 0, 0));
    const made = fk.log.pointer_image.?;
    try testing.expectEqual(rtg.PixelFormat.bgra32, made.format);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0xFF, 0xFF, 0x30, 0x20, 0x10, 0xFF }, made.pixels[0..8]);

    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "the overlay: its coverage dithered, following the pointer, placed on its own, freed with the board" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    try testing.expectEqual(rtg.errors.RTGERR_OK, setMode(rb, board, 0));
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
        try testing.expect(opaqueAt(made, @intCast(x), 0)); // full: every pixel
        try testing.expect(!opaqueAt(made, @intCast(x), 1)); // none: no pixel
    }
    var half: u32 = 0;
    for (2..4) |y| for (0..8) |x| {
        if (opaqueAt(made, @intCast(x), @intCast(y))) half += 1;
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
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

// --- the picture the library composes ----------------------------------------

/// A board of the test driver's whose display has a picture of its own,
/// with one mode of that size in RGB565, whose display reads `reads` bands
/// by itself.
fn makeComposed(rb: *RtgBase, width: u32, height: u32, reads: u32) !*rtg.RtgBoard {
    const fk = fakeOf(rb);
    fk.composed = true;
    fk.direct_bands = reads;
    defer fk.composed = false;
    defer fk.direct_bands = null;
    return makeDisplay(rb, width, height);
}

/// What `paint` writes at (x, y) of a buffer marked `mark`: a pixel that
/// says where it came from.
fn painted(mark: u16, x: u32, y: u32) u16 {
    return mark << 12 | @as(u16, @intCast(y)) << 6 | @as(u16, @intCast(x));
}

/// Every pixel of an RGB565 buffer written with its own place and `mark`.
fn paint(bitmap: *rtg.RtgBitMap, mark: u16) void {
    var y: u32 = 0;
    while (y < bitmap.height) : (y += 1) {
        const row: [*]u16 = @ptrCast(@alignCast(bitmap.pixels.? + @as(usize, y) * bitmap.pitch));
        var x: u32 = 0;
        while (x < bitmap.width) : (x += 1) row[x] = painted(mark, x, y);
    }
}

/// One pixel of an RGB565 buffer written.
fn poke(bitmap: *rtg.RtgBitMap, x: u32, y: u32, value: u16) void {
    const row: [*]u16 = @ptrCast(@alignCast(bitmap.pixels.? + @as(usize, y) * bitmap.pitch));
    row[x] = value;
}

/// The pixel at (x, y) of the picture the test board was last delivered.
fn onGlass(board: *rtg.RtgBoard, x: u32, y: u32) u16 {
    const instance = fake.instanceOf(board);
    const row: [*]const u16 = @ptrCast(@alignCast(instance.picture.? + @as(usize, y) * instance.picture_pitch));
    return row[x];
}

/// Whether the picture the test board was delivered is the buffer marked
/// `mark`, whole, with nothing over it.
fn seesOnly(board: *rtg.RtgBoard, mark: u16) bool {
    const instance = fake.instanceOf(board);
    var y: u32 = 0;
    while (y < instance.picture_height) : (y += 1) {
        var x: u32 = 0;
        while (x < instance.picture_width) : (x += 1) {
            if (onGlass(board, x, y) != painted(mark, x, y)) return false;
        }
    }
    return true;
}

const red: u16 = 0xF800;
const green: u16 = 0x07E0;
const blue: u16 = 0x001F;
const white: u16 = 0xFFFF;

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

test "ComposeLines: a rectangle of the picture, and what is none" {
    const rb = try setUp();
    defer kexec.deinit();
    const board = try makeComposed(rb, 16, 12, 0);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    var into: [8 * 4]u16 = undefined;
    const whole_lines = rtg.RtgRect{ .x = 4, .y = 2, .width = 8, .height = 4 };

    // A board never shown has no picture to say the size of.
    try testing.expectEqual(rtg.errors.RTGERR_BAD_FORMAT, driverBase(rb).ComposeLines(board, &whole_lines, @ptrCast(&into), 16));

    const picture = base(rb).AllocBitMap(board, 16, 12, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    paint(picture, 5);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, picture));

    // The rectangle's rows, its own pitch apart, and nothing past them.
    @memset(&into, 0xAAAA);
    try testing.expectEqual(rtg.errors.RTGERR_OK, driverBase(rb).ComposeLines(board, &.{ .x = 4, .y = 2, .width = 3, .height = 2 }, @ptrCast(&into), 16));
    try testing.expectEqual(painted(5, 4, 2), into[0]);
    try testing.expectEqual(painted(5, 6, 2), into[2]);
    try testing.expectEqual(@as(u16, 0xAAAA), into[3]);
    try testing.expectEqual(painted(5, 4, 3), into[8]);
    try testing.expectEqual(@as(u16, 0xAAAA), into[16]);

    // The last pixel of the picture is inside; a rectangle that is empty,
    // starts before the picture or ends past it is none.
    try testing.expectEqual(rtg.errors.RTGERR_OK, driverBase(rb).ComposeLines(board, &.{ .x = 15, .y = 11, .width = 1, .height = 1 }, @ptrCast(&into), 2));
    try testing.expectEqual(painted(5, 15, 11), into[0]);
    for ([_]rtg.RtgRect{
        .{ .x = 0, .y = 0, .width = 0, .height = 4 },
        .{ .x = 0, .y = 0, .width = 4, .height = -1 },
        .{ .x = -1, .y = 0, .width = 4, .height = 4 },
        .{ .x = 0, .y = -1, .width = 4, .height = 4 },
        .{ .x = 13, .y = 0, .width = 4, .height = 4 },
        .{ .x = 0, .y = 9, .width = 4, .height = 4 },
        .{ .x = std.math.maxInt(i32), .y = 0, .width = std.math.maxInt(i32), .height = 1 },
    }) |area| {
        try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, driverBase(rb).ComposeLines(board, &area, @ptrCast(&into), 16));
    }

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(picture);
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

/// What the driver saw of the board's compose lock while it delivered.
const Composing = struct {
    var seen_held: u32 = 0;
    var missed: u32 = 0;

    /// The fake board's `meanwhile`: the compose lock of the board it
    /// works on is the calling task's.
    fn look(board: *rtg.RtgBoard) void {
        const lock = &boards.privateOf(board).compose.lock;
        if (lock.owner == kexec.FindTask(kexec.SysBase, null) and lock.nestCount() != 0) seen_held += 1 else missed += 1;
    }

    /// Whether nothing holds either lock of `board`.
    fn free(board: *rtg.RtgBoard) bool {
        const lock = &boards.privateOf(board).compose.lock;
        return lock.owner == null and lock.nestCount() == 0 and Held.free(board);
    }
};

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

// --- a band of another size ---------------------------------------------------

/// Every pixel of an RGB565 buffer written with one colour.
fn flood(bitmap: *rtg.RtgBitMap, colour: u16) void {
    var y: u32 = 0;
    while (y < bitmap.height) : (y += 1) {
        var x: u32 = 0;
        while (x < bitmap.width) : (x += 1) poke(bitmap, x, y, colour);
    }
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

// --- mirrored, and dark -------------------------------------------------------

test "mirrored by the library: the picture, the pointer and what is written, each way, in the display's own coordinates" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeComposed(rb, 16, 12, 1);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const direct = rtg.boards.RTGSHOW_DIRECT;
    const both = rtg.boards.RTGBC_MIRROR_X | rtg.boards.RTGBC_MIRROR_Y;
    // Its driver wrote no mirror, and the board has both axes.
    try testing.expectEqual(both, infoOf(rb, board).caps & both);

    const picture = base(rb).AllocBitMap(board, 16, 12, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    paint(picture, 1);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, picture));
    try testing.expect(fk.log.last_flags & direct != 0);
    const changes = infoOf(rb, board).changes;

    // Left to right: the display reads the buffer no more, and is
    // delivered the picture with each row turned round.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).MirrorBoard(board, true, false));
    try testing.expectEqual(@as(u32, 0), fk.log.last_flags & direct);
    var info = infoOf(rb, board);
    try testing.expectEqual(@as(u8, 1), info.mirror_x);
    try testing.expectEqual(@as(u8, 0), info.mirror_y);
    try testing.expect(info.changes != changes);
    var y: u32 = 0;
    while (y < 12) : (y += 1) {
        var x: u32 = 0;
        while (x < 16) : (x += 1) try testing.expectEqual(painted(1, 15 - x, y), onGlass(board, x, y));
    }
    // What is written is delivered where the display shows it.
    poke(picture, 2, 1, white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(picture, &.{ .x = 2, .y = 1, .width = 3, .height = 2 }));
    try testing.expectEqual(rtg.RtgRect{ .x = 11, .y = 1, .width = 3, .height = 2 }, fk.log.last_update);
    try testing.expectEqual(white, onGlass(board, 13, 1));
    try testing.expectEqual(painted(1, 3, 1), onGlass(board, 12, 1));
    poke(picture, 2, 1, painted(1, 2, 1));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(picture, null));

    // The pointer is placed in the picture's coordinates, and laid
    // where the display shows that place.
    var dot = [_]u32{rgba(0xFF0000FF)};
    const pointer = rtg.Surface{ .pixels = @ptrCast(&dot), .width = 1, .height = 1, .pitch = 4, .format = .rgba32 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, &pointer, 0, 0));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBoardPointer(board, true));
    base(rb).MoveBoardPointer(board, 3, 2);
    try testing.expectEqual(red, onGlass(board, 12, 2));
    try testing.expectEqual(rtg.RtgRect{ .x = 12, .y = 2, .width = 1, .height = 1 }, fk.log.last_update);
    try testing.expectEqual(painted(1, 0, 0), onGlass(board, 15, 0));

    // Both ways: the picture upside down as well, the pointer with it.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).MirrorBoard(board, true, true));
    y = 0;
    while (y < 12) : (y += 1) {
        var x: u32 = 0;
        while (x < 16) : (x += 1) {
            const expected = if (x == 12 and y == 9) red else painted(1, 15 - x, 11 - y);
            try testing.expectEqual(expected, onGlass(board, x, y));
        }
    }
    // Top to bottom alone, and a rectangle fetched is the display's.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).MirrorBoard(board, false, true));
    try testing.expectEqual(red, onGlass(board, 3, 9));
    var fetched: [6]u16 = undefined;
    try testing.expectEqual(rtg.errors.RTGERR_OK, driverBase(rb).ComposeLines(board, &.{ .x = 4, .y = 2, .width = 3, .height = 2 }, @ptrCast(&fetched), 6));
    try testing.expectEqual([6]u16{ painted(1, 4, 9), painted(1, 5, 9), painted(1, 6, 9), painted(1, 4, 8), painted(1, 5, 8), painted(1, 6, 8) }, fetched);

    // Unturned with nothing over it, the display reads the buffer again.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardPointer(board, null, 0, 0));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).MirrorBoard(board, false, false));
    try testing.expect(fk.log.last_flags & direct != 0);
    info = infoOf(rb, board);
    try testing.expectEqual(@as(u8, 0), info.mirror_x);
    try testing.expectEqual(@as(u8, 0), info.mirror_y);

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(picture);
    driverBase(rb).DeleteBoard(board);

    // A flipped board the same: the next picture is made mirrored, and
    // what is written is noted where the display shows it.
    const flipped = try makeFlipped(rb, 16, 12);
    const frame = base(rb).AllocBitMap(flipped, 16, 12, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    paint(frame, 2);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(flipped, frame));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).MirrorBoard(flipped, true, true));
    flips.service(rb, flipped);
    y = 0;
    while (y < 12) : (y += 1) {
        var x: u32 = 0;
        while (x < 16) : (x += 1) try testing.expectEqual(painted(2, 15 - x, 11 - y), glassAt(flipped, x, y));
    }
    poke(frame, 1, 0, white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(frame, &.{ .x = 1, .y = 0, .width = 1, .height = 1 }));
    flips.service(rb, flipped);
    try testing.expectEqual(white, glassAt(flipped, 14, 11));
    try testing.expectEqual(painted(2, 2, 0), glassAt(flipped, 13, 11));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(flipped, null));
    base(rb).FreeBitMap(frame);
    driverBase(rb).DeleteBoard(flipped);
    try tearDown(rb);
}

test "an axis the board's hardware turns is the hardware's, the other the library's; the whole picture is delivered again" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    fk.hardware = true;
    fk.mirror_axes = rtg.boards.RTGBC_MIRROR_X;
    const board = try makeComposed(rb, 16, 12, 0);
    fk.hardware = false;
    fk.mirror_axes = rtg.boards.RTGBC_MIRROR_X | rtg.boards.RTGBC_MIRROR_Y;
    const picture = base(rb).AllocBitMap(board, 16, 12, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    paint(picture, 1);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, picture));

    // Left to right is the hardware's: the driver is told, the picture
    // delivered again whole and as it lies - a controller whose scan
    // direction changed holds a picture written the other way round.
    const updates = fk.log.updates;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).MirrorBoard(board, true, false));
    try testing.expectEqual(@as(u32, 1), fk.log.mirrors);
    try testing.expect(fk.log.last_mirror_x and !fk.log.last_mirror_y);
    try testing.expectEqual(updates + 1, fk.log.updates);
    try testing.expectEqual(rtg.RtgRect{ .width = 16, .height = 12 }, fk.log.last_update);
    try testing.expect(seesOnly(board, 1));

    // Top to bottom is the library's: the driver hears of its own axis
    // alone, and is delivered the picture upside down.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).MirrorBoard(board, true, true));
    try testing.expectEqual(@as(u32, 1), fk.log.mirrors);
    try testing.expectEqual(painted(1, 5, 11), onGlass(board, 5, 0));
    try testing.expectEqual(painted(1, 15, 0), onGlass(board, 15, 11));
    const info = infoOf(rb, board);
    try testing.expectEqual(@as(u8, 1), info.mirror_x);
    try testing.expectEqual(@as(u8, 1), info.mirror_y);
    // The hardware's axis back: the driver is told, the library's stays.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).MirrorBoard(board, false, true));
    try testing.expectEqual(@as(u32, 2), fk.log.mirrors);
    try testing.expect(!fk.log.last_mirror_x);
    try testing.expectEqual(painted(1, 5, 11), onGlass(board, 5, 0));

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(picture);
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

test "blank is the library's: a black picture, what is shown and drawn meanwhile kept, and on the glass again" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    const direct = rtg.boards.RTGSHOW_DIRECT;
    const on = rtg.boards.RTGPWR_ON;
    const blank = rtg.boards.RTGPWR_BLANK;
    const asleep = rtg.boards.RTGPWR_ASLEEP;

    // A display that reads one buffer itself, whose driver has no power
    // of its own: it never sleeps, and starts on.
    const board = try makeComposed(rb, 16, 12, 1);
    var info = infoOf(rb, board);
    try testing.expectEqual(@as(u32, 0), info.caps & rtg.boards.RTGBC_POWER);
    try testing.expectEqual(on, info.power);
    const back = base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    const front = base(rb).AllocBitMap(board, 16, 12, format, displayable).?;
    paint(back, 1);
    paint(front, 2);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, back));
    try testing.expect(fk.log.last_flags & direct != 0);
    const changes = info.changes;

    // Blank: the display is shown the library's picture, which is
    // black, and the board says so.
    try testing.expectEqual(@as(i32, @intCast(blank)), base(rb).SetBoardPower(board, blank));
    try testing.expectEqual(@as(u32, 0), fk.log.last_flags & direct);
    info = infoOf(rb, board);
    try testing.expectEqual(blank, info.power);
    try testing.expect(info.changes != changes);
    try testing.expect(back.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);
    var y: u32 = 0;
    while (y < 12) : (y += 1) {
        var x: u32 = 0;
        while (x < 16) : (x += 1) try testing.expectEqual(@as(u16, 0), onGlass(board, x, y));
    }
    // What is drawn, moved and shown meanwhile reaches no glass.
    const updates = fk.log.updates;
    poke(back, 4, 4, white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(back, null));
    base(rb).MoveBoardPointer(board, 5, 5);
    try testing.expectEqual(updates, fk.log.updates);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, front));
    try testing.expectEqual(@as(u32, 0), fk.log.last_flags & direct);
    try testing.expectEqual(@as(u16, 0), onGlass(board, 4, 4));
    try testing.expectEqual(front, base(rb).BoardDisplayBitMap(board).?);
    // Asleep on a board that does not sleep is blank, and nothing
    // changes; a state there is none of is refused.
    try testing.expectEqual(@as(i32, @intCast(blank)), base(rb).SetBoardPower(board, asleep));
    try testing.expectEqual(blank, infoOf(rb, board).power);
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).SetBoardPower(board, 3));

    // On again: what was shown meanwhile, read by the display itself.
    try testing.expectEqual(@as(i32, @intCast(on)), base(rb).SetBoardPower(board, on));
    try testing.expect(fk.log.last_flags & direct != 0);
    try testing.expectEqual(front, fk.log.bands[0].bitmap);
    try testing.expectEqual(on, infoOf(rb, board).power);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(front);
    base(rb).FreeBitMap(back);
    driverBase(rb).DeleteBoard(board);

    // A display with a picture of its own alone: delivered black, then
    // the picture with what was drawn meanwhile.
    const own = try makeComposed(rb, 16, 12, 0);
    const picture = base(rb).AllocBitMap(own, 16, 12, format, displayable).?;
    paint(picture, 3);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(own, picture));
    try testing.expectEqual(@as(i32, @intCast(blank)), base(rb).SetBoardPower(own, blank));
    try testing.expectEqual(@as(u16, 0), onGlass(own, 9, 9));
    var fetched: [2]u16 = .{ 7, 7 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, driverBase(rb).ComposeLines(own, &.{ .x = 3, .y = 3, .width = 2, .height = 1 }, @ptrCast(&fetched), 4));
    try testing.expectEqual([2]u16{ 0, 0 }, fetched);
    poke(picture, 9, 9, white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(picture, &.{ .x = 9, .y = 9, .width = 1, .height = 1 }));
    try testing.expectEqual(@as(u16, 0), onGlass(own, 9, 9));
    try testing.expectEqual(@as(i32, @intCast(on)), base(rb).SetBoardPower(own, on));
    try testing.expectEqual(white, onGlass(own, 9, 9));
    try testing.expectEqual(painted(3, 2, 2), onGlass(own, 2, 2));
    // A black picture the driver cannot deliver leaves the board on.
    fk.update_answer = rtg.errors.RTGERR_NO_DISPLAY;
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, base(rb).SetBoardPower(own, blank));
    fk.update_answer = rtg.errors.RTGERR_OK;
    try testing.expectEqual(on, infoOf(rb, own).power);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(picture, null));
    try testing.expectEqual(painted(3, 2, 2), onGlass(own, 2, 2));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(own, null));
    base(rb).FreeBitMap(picture);
    driverBase(rb).DeleteBoard(own);

    // A flipped board: the next picture is black, nothing is made of
    // what is drawn meanwhile, and the whole picture when it is on.
    const flipped = try makeFlipped(rb, 16, 12);
    const frame = base(rb).AllocBitMap(flipped, 16, 12, format, displayable).?;
    paint(frame, 4);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(flipped, frame));
    try testing.expectEqual(@as(i32, @intCast(blank)), base(rb).SetBoardPower(flipped, blank));
    flips.service(rb, flipped);
    try testing.expectEqual(@as(u16, 0), glassAt(flipped, 0, 0));
    try testing.expectEqual(@as(u16, 0), glassAt(flipped, 15, 11));
    const flipped_before = fk.log.flips;
    poke(frame, 6, 6, white);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(frame, &.{ .x = 6, .y = 6, .width = 1, .height = 1 }));
    flips.service(rb, flipped);
    try testing.expectEqual(flipped_before, fk.log.flips);
    try testing.expectEqual(@as(i32, @intCast(on)), base(rb).SetBoardPower(flipped, on));
    flips.service(rb, flipped);
    try testing.expect(glassIs(flipped, 4, &.{.{ 6, 6, white }}));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(flipped, null));
    base(rb).FreeBitMap(frame);
    driverBase(rb).DeleteBoard(flipped);
    try tearDown(rb);
}

test "asleep is the driver's, asked once the picture is black; the backlight is kept through it" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const on = rtg.boards.RTGPWR_ON;
    const blank = rtg.boards.RTGPWR_BLANK;
    const asleep = rtg.boards.RTGPWR_ASLEEP;
    fk.hardware = true;
    const board = try makeComposed(rb, 16, 12, 0);
    fk.hardware = false;
    try testing.expect(infoOf(rb, board).caps & rtg.boards.RTGBC_POWER != 0);
    const picture = base(rb).AllocBitMap(board, 16, 12, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    paint(picture, 1);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, picture));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardBrightness(board, 70));

    // Blank asks the driver nothing: the picture is black, and that is
    // all.
    try testing.expectEqual(@as(i32, @intCast(blank)), base(rb).SetBoardPower(board, blank));
    try testing.expectEqual(@as(u32, 0), fk.log.power_calls);
    try testing.expectEqual(@as(u16, 0), onGlass(board, 3, 3));
    // Asleep from there: the driver alone.
    const updates = fk.log.updates;
    try testing.expectEqual(@as(i32, @intCast(asleep)), base(rb).SetBoardPower(board, asleep));
    try testing.expectEqual(@as(u32, 1), fk.log.power_calls);
    try testing.expectEqual(asleep, fk.log.last_power);
    try testing.expectEqual(updates, fk.log.updates);
    try testing.expectEqual(asleep, infoOf(rb, board).power);
    // A brightness set while it sleeps is kept, and not applied.
    const calls = fk.log.brightness_calls;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardBrightness(board, 30));
    try testing.expectEqual(calls, fk.log.brightness_calls);
    try testing.expectEqual(@as(u32, 30), infoOf(rb, board).brightness);
    try testing.expectEqual(@as(u32, 0), fk.log.brightness);
    // Blank again: awake, and black still.
    try testing.expectEqual(@as(i32, @intCast(blank)), base(rb).SetBoardPower(board, blank));
    try testing.expectEqual(on, fk.log.last_power);
    try testing.expectEqual(@as(u32, 30), fk.log.brightness);
    try testing.expectEqual(@as(u16, 0), onGlass(board, 3, 3));
    try testing.expectEqual(@as(i32, @intCast(on)), base(rb).SetBoardPower(board, on));
    try testing.expect(seesOnly(board, 1));

    // From on: black first, then asleep; and awake before the picture.
    try testing.expectEqual(@as(i32, @intCast(asleep)), base(rb).SetBoardPower(board, asleep));
    try testing.expectEqual(@as(u16, 0), onGlass(board, 3, 3));
    try testing.expectEqual(@as(i32, @intCast(on)), base(rb).SetBoardPower(board, on));
    try testing.expectEqual(on, fk.log.last_power);
    try testing.expect(seesOnly(board, 1));

    // A display that only goes blank says so; one that will not sleep
    // leaves the board on, its picture back.
    fk.sleep_answer = @intCast(blank);
    try testing.expectEqual(@as(i32, @intCast(blank)), base(rb).SetBoardPower(board, asleep));
    try testing.expectEqual(blank, infoOf(rb, board).power);
    try testing.expectEqual(@as(i32, @intCast(on)), base(rb).SetBoardPower(board, on));
    fk.sleep_answer = rtg.errors.RTGERR_IO;
    try testing.expectEqual(rtg.errors.RTGERR_IO, base(rb).SetBoardPower(board, asleep));
    try testing.expectEqual(on, infoOf(rb, board).power);
    try testing.expect(seesOnly(board, 1));
    fk.sleep_answer = @intCast(asleep);

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(picture);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

test "a display that reads its buffers of alone: every state its driver's, or nothing shown where it has none" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    const on = rtg.boards.RTGPWR_ON;
    const blank = rtg.boards.RTGPWR_BLANK;
    const asleep = rtg.boards.RTGPWR_ASLEEP;

    // With a power of its own: asked for each state, and shown nothing
    // other than it was.
    const board = try makeDisplay(rb, 16, 16);
    const picture = base(rb).AllocBitMap(board, 16, 16, format, displayable).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, picture));
    const shown = fk.log.shown;
    try testing.expectEqual(@as(i32, @intCast(blank)), base(rb).SetBoardPower(board, blank));
    try testing.expectEqual(blank, fk.log.last_power);
    try testing.expectEqual(@as(i32, @intCast(asleep)), base(rb).SetBoardPower(board, asleep));
    try testing.expectEqual(asleep, fk.log.last_power);
    try testing.expectEqual(asleep, infoOf(rb, board).power);
    try testing.expectEqual(@as(i32, @intCast(on)), base(rb).SetBoardPower(board, on));
    try testing.expectEqual(@as(u32, 3), fk.log.power_calls);
    try testing.expectEqual(shown, fk.log.shown);
    // The same state again asks nobody.
    try testing.expectEqual(@as(i32, @intCast(on)), base(rb).SetBoardPower(board, on));
    try testing.expectEqual(@as(u32, 3), fk.log.power_calls);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(picture);
    driverBase(rb).DeleteBoard(board);

    // With none: its driver is shown nothing while the board is dark,
    // the buffers stay the board's, and what is shown meanwhile is what
    // it is shown when it is on again.
    fk.without_engine = true;
    const plain = try makeDisplay(rb, 16, 16);
    fk.without_engine = false;
    try testing.expectEqual(@as(u32, 0), infoOf(rb, plain).caps & rtg.boards.RTGBC_POWER);
    const one = base(rb).AllocBitMap(plain, 16, 16, format, displayable).?;
    const other = base(rb).AllocBitMap(plain, 16, 16, format, displayable).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(plain, one));
    try testing.expectEqual(@as(i32, @intCast(blank)), base(rb).SetBoardPower(plain, asleep));
    try testing.expectEqual(@as(u32, 0), fk.log.band_count);
    try testing.expectEqual(@as(u32, 0), fake.instanceOf(plain).showing_count);
    try testing.expectEqual(one, base(rb).BoardDisplayBitMap(plain).?);
    try testing.expect(one.flags & rtg.bitmaps.RTGBMF_SHOWING != 0);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(plain, other));
    try testing.expectEqual(@as(u32, 0), fk.log.band_count);
    try testing.expectEqual(other, base(rb).BoardDisplayBitMap(plain).?);
    try testing.expectEqual(@as(i32, @intCast(on)), base(rb).SetBoardPower(plain, on));
    try testing.expectEqual(@as(u32, 1), fk.log.band_count);
    try testing.expectEqual(other, fk.log.bands[0].bitmap);
    try testing.expectEqual(@as(u32, 1), fake.instanceOf(plain).showing_count);
    // A driver that will not show nothing leaves the board on.
    fk.show_answer = rtg.errors.RTGERR_NO_DISPLAY;
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, base(rb).SetBoardPower(plain, blank));
    try testing.expectEqual(on, infoOf(rb, plain).power);

    // A board whose device has gone has no display to put in a state.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(plain, null));
    base(rb).FreeBitMap(other);
    base(rb).FreeBitMap(one);
    boards.retire(rb, plain);
    try testing.expectEqual(rtg.errors.RTGERR_NO_DISPLAY, base(rb).SetBoardPower(plain, blank));
    driverBase(rb).DeleteBoard(plain);
    try tearDown(rb);
}

test "WaitVBlank on a board asleep is by the clock, though its frames were said" {
    const rb = try setUp();
    defer kexec.deinit();
    const board = try makeBoard(rb);
    Sleep.install(&FakeTimer.expire);
    defer Sleep.uninstall();
    // Its driver says its frames.
    fake.endFrame(board);
    try testing.expect(saysFrames(rb, board));
    try testing.expectEqual(@as(i32, @intCast(rtg.boards.RTGPWR_ASLEEP)), base(rb).SetBoardPower(board, rtg.boards.RTGPWR_ASLEEP));
    // A frame's time, and no waiter on the board's list meanwhile.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).WaitVBlank(board, 0));
    try testing.expectEqual(@as(u64, 16_667), FakeTimer.last_micros);
    try testing.expectEqual(@as(u32, 0), FakeTimer.aborted);
    try testing.expect(boards.privateOf(board).frames.waiters == null);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

// --- a board that is flipped between frames ---------------------------------

/// A board of the test driver's that is flipped between frames, with one
/// mode of that size in RGB565.
fn makeFlipped(rb: *RtgBase, width: u32, height: u32) !*rtg.RtgBoard {
    const fk = fakeOf(rb);
    fk.flipped = true;
    defer fk.flipped = false;
    return makeDisplay(rb, width, height);
}

/// The pixel at (x, y) of the frame the test board's display reads.
fn glassAt(board: *rtg.RtgBoard, x: u32, y: u32) u16 {
    const glass = fake.glassOf(board).?;
    const row: [*]const u16 = @ptrCast(@alignCast(glass.pixels.? + @as(usize, y) * glass.pitch));
    return row[x];
}

/// Whether the frame the display reads is the buffer marked `mark`,
/// whole, but for the pixels a test names as changed.
fn glassIs(board: *rtg.RtgBoard, mark: u16, changed: []const [3]u16) bool {
    const glass = fake.glassOf(board).?;
    var y: u32 = 0;
    while (y < glass.height) : (y += 1) {
        var x: u32 = 0;
        next: while (x < glass.width) : (x += 1) {
            for (changed) |one| {
                if (one[0] == x and one[1] == y) {
                    if (glassAt(board, x, y) != one[2]) return false;
                    continue :next;
                }
            }
            if (glassAt(board, x, y) != painted(mark, x, y)) return false;
        }
    }
    return true;
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
    frames_board = board;
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

/// What a flipped board's driver saw of the locks while it flipped.
const Flipping = struct {
    var flips_seen: u32 = 0;
    var compose_held: u32 = 0;
    var flip_lock_missed: u32 = 0;

    fn look(board: *rtg.RtgBoard) void {
        const me = kexec.FindTask(kexec.SysBase, null);
        const compose = &boards.privateOf(board).compose;
        flips_seen += 1;
        if (compose.lock.owner != null or compose.lock.nestCount() != 0) compose_held += 1;
        if (compose.flip.lock.owner != me or compose.flip.lock.nestCount() == 0) flip_lock_missed += 1;
    }
};

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

test "SetBoardAudio: the link's driver told the sound, and none; a board whose link carries none" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const board = try makeBoard(rb);
    try testing.expect(infoOf(rb, board).caps & rtg.boards.RTGBC_AUDIO != 0);

    const stereo = rtg.RtgAudio{ .sample_rate = 48_000, .channels = 2, .bits = 16 };
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardAudio(board, &stereo));
    try testing.expectEqual(@as(u32, 1), fk.log.audio_calls);
    try testing.expectEqual(@as(u32, 48_000), fk.log.last_audio.?.sample_rate);
    try testing.expectEqual(@as(u32, 2), fk.log.last_audio.?.channels);
    // What the driver answers is the answer.
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).SetBoardAudio(board, &.{ .sample_rate = 44_100 }));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardAudio(board, null));
    try testing.expectEqual(@as(u32, 3), fk.log.audio_calls);
    try testing.expect(fk.log.last_audio == null);

    // A board whose driver has no such op: no sound, and none to take off.
    fk.without_engine = true;
    const plain = try makeBoard(rb);
    fk.without_engine = false;
    try testing.expectEqual(@as(u32, 0), infoOf(rb, plain).caps & rtg.boards.RTGBC_AUDIO);
    try testing.expectEqual(rtg.errors.RTGERR_NOT_SUPPORTED, base(rb).SetBoardAudio(plain, &stereo));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardAudio(plain, null));
    try testing.expectEqual(@as(u32, 3), fk.log.audio_calls);
    try tearDown(rb);
}

test "BuildAviInfoFrame: the header, the aspect, the range and the number, summing to zero" {
    const rb = try setUp();
    defer kexec.deinit();
    var frame: [rtg.RTG_AVI_BYTES + 1]u8 = @splat(0xAA);
    // 1920x1080, CEA's 16: a computer's picture in the whole range.
    var timings = rtg.RtgTimings{ .h_active = 1920, .v_active = 1080, .vic = 16 };
    try testing.expectEqual(@as(u32, rtg.RTG_AVI_BYTES), driverBase(rb).BuildAviInfoFrame(&timings, rtg.RTGAVI_IT | rtg.RTGAVI_RANGE_FULL, &frame));
    try testing.expectEqualSlices(u8, &.{ 0x82, 0x02, 0x0D }, frame[0..3]);
    try testing.expectEqual(@as(u8, 0x12), frame[4]);
    try testing.expectEqual(@as(u8, 0x28), frame[5]);
    try testing.expectEqual(@as(u8, 0x88), frame[6]);
    try testing.expectEqual(@as(u8, 16), frame[7]);
    var sum: u8 = 0;
    for (frame[0..rtg.RTG_AVI_BYTES]) |byte| sum +%= byte;
    try testing.expectEqual(@as(u8, 0), sum);
    // Nothing past the frame is written.
    try testing.expectEqual(@as(u8, 0xAA), frame[rtg.RTG_AVI_BYTES]);

    // The range said limited, no computer's picture, the number left out.
    _ = driverBase(rb).BuildAviInfoFrame(&timings, rtg.RTGAVI_RANGE_LIMITED | rtg.RTGAVI_NO_VIC, &frame);
    try testing.expectEqual(@as(u8, 0x10), frame[4]);
    try testing.expectEqual(@as(u8, 0x04), frame[6]);
    try testing.expectEqual(@as(u8, 0), frame[7]);
    // No range said: the monitor's own for the mode.
    _ = driverBase(rb).BuildAviInfoFrame(&timings, 0, &frame);
    try testing.expectEqual(@as(u8, 0), frame[6]);

    // 720x480 is 4:3 under its first number and 16:9 under its second; a
    // mode with no number has the picture's own shape, or none.
    timings = .{ .h_active = 720, .v_active = 480, .vic = 2 };
    _ = driverBase(rb).BuildAviInfoFrame(&timings, 0, &frame);
    try testing.expectEqual(@as(u8, 0x18), frame[5]);
    timings.vic = 3;
    _ = driverBase(rb).BuildAviInfoFrame(&timings, 0, &frame);
    try testing.expectEqual(@as(u8, 0x28), frame[5]);
    timings = .{ .h_active = 1024, .v_active = 768 };
    _ = driverBase(rb).BuildAviInfoFrame(&timings, 0, &frame);
    try testing.expectEqual(@as(u8, 0x18), frame[5]);
    timings = .{ .h_active = 1280, .v_active = 800 };
    _ = driverBase(rb).BuildAviInfoFrame(&timings, 0, &frame);
    try testing.expectEqual(@as(u8, 0x08), frame[5]);
    try tearDown(rb);
}

test "HdmiAudioClock: N the rate's own, CTS the clock in kilohertz for it" {
    const rb = try setUp();
    defer kexec.deinit();
    var n: u32 = 7;
    var cts: u32 = 7;
    try testing.expect(driverBase(rb).HdmiAudioClock(148_500_000, 48_000, &n, &cts));
    try testing.expectEqual(@as(u32, 6144), n);
    try testing.expectEqual(@as(u32, 148_500), cts);
    try testing.expect(driverBase(rb).HdmiAudioClock(25_175_000, 32_000, &n, &cts));
    try testing.expectEqual(@as(u32, 4096), n);
    try testing.expectEqual(@as(u32, 25_175), cts);
    try testing.expect(driverBase(rb).HdmiAudioClock(74_250_000, 44_100, &n, &cts));
    try testing.expectEqual(@as(u32, 6272), n);
    try testing.expectEqual(@as(u32, 82_500), cts);
    try testing.expect(driverBase(rb).HdmiAudioClock(148_500_000, 96_000, &n, &cts));
    try testing.expectEqual(@as(u32, 12_288), n);
    try testing.expectEqual(@as(u32, 148_500), cts);
    // A rate that is none of HDMI's: 128 times it over 1000.
    try testing.expect(driverBase(rb).HdmiAudioClock(148_500_000, 22_050, &n, &cts));
    try testing.expectEqual(@as(u32, 2822), n);
    // No clock or no rate: no numbers.
    n = 7;
    try testing.expect(!driverBase(rb).HdmiAudioClock(0, 48_000, &n, &cts));
    try testing.expect(!driverBase(rb).HdmiAudioClock(148_500_000, 0, &n, &cts));
    try testing.expectEqual(@as(u32, 7), n);
    try tearDown(rb);
}

test "LockBitMap and UnlockBitMap: a flipped board's read lock, nested for its task; nothing held on any other buffer" {
    const rb = try setUp();
    defer kexec.deinit();
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    const board = try makeFlipped(rb, 16, 12);
    const lock = &boards.privateOf(board).compose.flip.read_lock;
    const shown = base(rb).AllocBitMap(board, 16, 12, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, shown));

    try testing.expectEqual(@as(u16, 0), lock.nestCount());
    base(rb).LockBitMap(shown);
    try testing.expectEqual(@as(u16, 1), lock.nestCount());
    // An engine's copy inside it holds the lock a second time, and gives
    // that hold back.
    base(rb).LockBitMap(shown);
    try testing.expectEqual(@as(u16, 2), lock.nestCount());
    base(rb).UnlockBitMap(shown);
    base(rb).UnlockBitMap(shown);
    try testing.expectEqual(@as(u16, 0), lock.nestCount());

    // What was written between the two is on the glass with the next
    // picture, whole.
    base(rb).LockBitMap(shown);
    paint(shown, 4);
    base(rb).UnlockBitMap(shown);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(shown, null));
    flips.service(rb, board);
    try testing.expect(glassIs(board, 4, &.{}));

    // A board that is not flipped, and memory of no board: nothing held.
    const plain = try makeDisplay(rb, 16, 12);
    const other = base(rb).AllocBitMap(plain, 16, 12, format, 0).?;
    base(rb).LockBitMap(other);
    try testing.expectEqual(@as(u16, 0), boards.privateOf(plain).compose.flip.read_lock.nestCount());
    base(rb).UnlockBitMap(other);
    var loose = rtg.RtgBitMap{ .width = 4, .height = 4 };
    base(rb).LockBitMap(&loose);
    base(rb).UnlockBitMap(&loose);

    base(rb).FreeBitMap(other);
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
    driverBase(rb).DeleteBoard(board);
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
    driverBase(rb).DeleteBoard(board);
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
    driverBase(rb).DeleteBoard(board);
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
    driverBase(rb).DeleteBoard(board);
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

test "a stream's colour numbers as a picture says them, and nothing where they say nothing" {
    const rb = try setUp();
    defer kexec.deinit();
    const matrix = rtg.RTGCICP_MATRIX;
    const transfer = rtg.RTGCICP_TRANSFER;
    const primaries = rtg.RTGCICP_PRIMARIES;

    try testing.expectEqual(@as(i32, rtg.RTGYUV_BT709), base(rb).RtgCicp(matrix, 1));
    for ([_]u32{ 4, 5, 6, 7 }) |television| try testing.expectEqual(@as(i32, rtg.RTGYUV_BT601), base(rb).RtgCicp(matrix, television));
    for ([_]u32{ 9, 10 }) |wide| try testing.expectEqual(@as(i32, rtg.RTGYUV_BT2020), base(rb).RtgCicp(matrix, wide));

    for ([_]u32{ 1, 6, 14, 15 }) |curve| try testing.expectEqual(@as(i32, rtg.RTGYUV_SDR), base(rb).RtgCicp(transfer, curve));
    try testing.expectEqual(@as(i32, rtg.RTGYUV_PQ), base(rb).RtgCicp(transfer, 16));
    try testing.expectEqual(@as(i32, rtg.RTGYUV_HLG), base(rb).RtgCicp(transfer, 18));

    for ([_]u32{ 1, 5, 6, 7 }) |television| try testing.expectEqual(@as(i32, rtg.RTGYUV_BT709), base(rb).RtgCicp(primaries, television));
    try testing.expectEqual(@as(i32, rtg.RTGYUV_BT2020), base(rb).RtgCicp(primaries, 9));
    for ([_]u32{ 11, 12 }) |cinema| try testing.expectEqual(@as(i32, rtg.RTGYUV_P3), base(rb).RtgCicp(primaries, cinema));

    // "Unspecified", a number nothing here shows, one past a byte, and a
    // table that is none of the three.
    for ([_]u32{ matrix, transfer, primaries }) |kind| {
        for ([_]u32{ 0, 2, 3, 8, 13, 255, 256, ~@as(u32, 0) }) |silent| {
            try testing.expect(base(rb).RtgCicp(kind, silent) < 0);
        }
    }
    try testing.expect(base(rb).RtgCicp(3, 1) < 0);
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

    // RTGA_Compose is the board's to keep, for intuition to read: a tag of
    // its device.
    const composing = [_]TagItem{
        .{ .tag = rtg.tags.RTGA_Compose, .data = 1 },
        .{ .tag = utility.TAG_MORE, .data = @intFromPtr(fake.deviceTags()) },
    };
    const board = fake.makeBoardFrom(fk, &composing) orelse return error.NoBoard;
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
    // No rectangle is the whole buffer.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(bm, null));
    try testing.expectEqual(@as(u32, 2), told.calls);
    try testing.expectEqual(rtg.RtgRect{ .x = 0, .y = 0, .width = 8, .height = 4 }, told.rect);
    try testing.expectEqual(before, fk.log.refreshed);

    // Without the hook, the board hears of it again.
    bm.watch = null;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).RefreshRect(bm, &.{ .width = 8, .height = 4 }));
    try testing.expectEqual(before + 1, fk.log.refreshed);
    try testing.expectEqual(@as(u32, 2), told.calls);

    base(rb).FreeBitMap(bm);
    driverBase(rb).DeleteBoard(plain);
    driverBase(rb).DeleteBoard(board);
    try tearDown(rb);
}

// --- settings -----------------------------------------------------------------

/// The settings' file as the library writes it, into `into`.
fn settingsText(rb: *RtgBase, into: []u8) []const u8 {
    settings.obtain(rb);
    defer settings.release(rb);
    return into[0..settings.write(rb, into)];
}

/// A file's text read in place of the lines held; how many lines could
/// not be read.
fn readSettings(rb: *RtgBase, file: []const u8) u32 {
    settings.obtain(rb);
    defer settings.release(rb);
    return settings.read(rb, file);
}

/// The board's line in force.
fn lineOf(rb: *RtgBase, board: *rtg.RtgBoard) rtg.RtgSettings {
    var line: rtg.RtgSettings = .{};
    _ = base(rb).GetBoardSettings(board, &line, @sizeOf(rtg.RtgSettings));
    return line;
}

/// The board's default mode.
fn defaultMode(rb: *RtgBase, board: *rtg.RtgBoard) rtg.RtgMode {
    var mode: rtg.RtgMode = .{};
    _ = base(rb).BestBoardMode(board, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY, &mode);
    return mode;
}

test "settings: lines read, written and read again; a line that cannot be read is passed over" {
    const rb = try setUp();
    defer kexec.deinit();
    const file =
        "# the displays\n" ++
        "DEVICE=pci.01:00.0 DRIVER=OFF BUFFERS=3 COMPOSE=YES\n" ++
        "output=amd.0 monitor=del:a0c4:12345 mode=2560X1440@60 first=yes mirror=x brightness=80 range=limited\n" ++
        "\n" ++
        "; a monitor that says nothing\n" ++
        "OUTPUT=jh7110.0 TIMINGS=148500000,1920,88,44,148,1080,4,5,36,+H,+V\n" ++
        "OUTPUT=amd.0 MODE=1920x1080 MIRROR=NONE RANGE=FULL\n" ++
        "DEVICE=panel.0 COMPOSE=NO\n";
    try testing.expectEqual(@as(u32, 0), readSettings(rb, file));

    // Written: the devices' lines, then the outputs', each in the one
    // form, a monitor's numbers in full.
    var first: [settings.header.len + 8 * settings.line_most]u8 = undefined;
    const written = settingsText(rb, &first);
    try testing.expect(std.mem.startsWith(u8, written, settings.header));
    try testing.expectEqualStrings(
        "DEVICE=pci.01:00.0 DRIVER=OFF BUFFERS=3 COMPOSE=YES\n" ++
            "DEVICE=panel.0 COMPOSE=NO\n" ++
            "OUTPUT=amd.0 MONITOR=DEL:A0C4:00012345 MODE=2560x1440@60 FIRST=YES MIRROR=X BRIGHTNESS=80 RANGE=LIMITED\n" ++
            "OUTPUT=jh7110.0 TIMINGS=148500000,1920,88,44,148,1080,4,5,36,+H,+V\n" ++
            "OUTPUT=amd.0 MODE=1920x1080 MIRROR=NONE RANGE=FULL\n",
        written[settings.header.len..],
    );
    // And read again, it is written the same.
    try testing.expectEqual(@as(u32, 0), readSettings(rb, written));
    var second: [first.len]u8 = undefined;
    try testing.expectEqualStrings(written, settingsText(rb, &second));

    // A line that names nothing, a key its kind has not got, a value out
    // of its range, a quote left open: each passed over, the rest kept.
    const doubtful =
        "MODE=640x480\n" ++
        "OUTPUT=a.0 MODE=0x480\n" ++
        "OUTPUT=a.0 MODE=640x480@\n" ++
        "OUTPUT=a.0 BRIGHTNESS=101\n" ++
        "OUTPUT=a.0 DRIVER=OFF\n" ++
        "OUTPUT=a.0 MONITOR=DELL:1:2\n" ++
        "OUTPUT=a.0 TIMINGS=1,2,3\n" ++
        "OUTPUT=a.0 TIMINGS=148500000,1920,88,44,148,1080,4,5,36,+X\n" ++
        "DEVICE=d.0 BUFFERS=0\n" ++
        "DEVICE=d.0 DRIVER=MAYBE\n" ++
        "OUTPUT=\"a.0 MODE=640x480\n" ++
        "OUTPUT=kept.0 MIRROR=XY\n" ++
        // A line that says nothing is no line.
        "OUTPUT=bare.0\n" ++
        "DEVICE=bare.1 DRIVER=ON\n";
    try testing.expectEqual(@as(u32, 11), readSettings(rb, doubtful));
    try testing.expectEqualStrings("OUTPUT=kept.0 MIRROR=XY\n", settingsText(rb, &second)[settings.header.len..]);

    // A device's driver switched off and on again; a line left saying
    // nothing goes.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetRtgDeviceDriver("pci.02:00.0", false));
    try testing.expectEqualStrings("DEVICE=pci.02:00.0 DRIVER=OFF\nOUTPUT=kept.0 MIRROR=XY\n", settingsText(rb, &second)[settings.header.len..]);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetRtgDeviceDriver("pci.02:00.0", true));
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetRtgDeviceDriver("pci.03:00.0", true));
    try testing.expectEqualStrings("OUTPUT=kept.0 MIRROR=XY\n", settingsText(rb, &second)[settings.header.len..]);
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).SetRtgDeviceDriver("", false));
    try tearDown(rb);
}

test "a board's line: its mode the default, mirror and brightness set, the range in its info, and taken away again" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    const format = @intFromEnum(rtg.PixelFormat.rgb565);
    fk.color_range = true;
    const board = try makeDisplay(rb, 16, 16);
    fk.color_range = false;
    const small = addMode(rb, board, 8, 8);
    const own = defaultMode(rb, board);
    try testing.expectEqual(@as(u32, 16), own.width);
    try testing.expectEqual(@as(u32, 0), lineOf(rb, board).flags);
    try testing.expect(infoOf(rb, board).caps & rtg.boards.RTGBC_COLOR_RANGE != 0);

    const picture = base(rb).AllocBitMap(board, 16, 16, format, rtg.bitmaps.RTGBMF_DISPLAYABLE).?;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, picture));
    const in_mode = infoOf(rb, board).mode_id;
    const shown = fk.log.shown;
    const brightness_calls = fk.log.brightness_calls;

    // What is out of its range changes nothing.
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).SetBoardSettings(board, &.{ .flags = rtg.RTGSET_BRIGHTNESS, .brightness = 101 }));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).SetBoardSettings(board, &.{ .flags = rtg.RTGSET_MODE, .mode_width = 8 }));
    try testing.expectEqual(rtg.errors.RTGERR_BAD_ARG, base(rb).SetBoardSettings(board, &.{ .flags = rtg.RTGSET_TIMINGS }));
    try testing.expectEqual(@as(u32, 0), lineOf(rb, board).flags);

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
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardSettings(board, &wanted));
    try testing.expectEqual(small, defaultMode(rb, board).id);
    try testing.expect(defaultMode(rb, board).flags & rtg.modes.RTGMF_DEFAULT != 0);
    var info = infoOf(rb, board);
    try testing.expectEqual(in_mode, info.mode_id);
    try testing.expectEqual(@as(u8, 0), info.mirror_x);
    try testing.expectEqual(@as(u8, 1), info.mirror_y);
    try testing.expectEqual(@as(u32, 40), info.brightness);
    try testing.expectEqual(brightness_calls + 1, fk.log.brightness_calls);
    try testing.expectEqual(rtg.RTGRANGE_LIMITED, info.color_range);
    // Shown again twice: for the range, and the other way up.
    try testing.expectEqual(shown + 2, fk.log.shown);
    var line = lineOf(rb, board);
    try testing.expectEqual(wanted.flags, line.flags);
    try testing.expectEqual(@as(u32, 0), line.product);
    try testing.expectEqual(@as(u32, 8), line.mode_width);

    // As the file has it.
    var file: [settings.header.len + 2 * settings.line_most]u8 = undefined;
    try testing.expectEqualStrings("OUTPUT=fake.0 MODE=8x8 MIRROR=Y BRIGHTNESS=40 RANGE=LIMITED\n", settingsText(rb, &file)[settings.header.len..]);

    // A mode the board has not got stays in the line, and the default is
    // the board's own; the range said full.
    line.mode_width = 640;
    line.mode_height = 480;
    line.flags &= ~@as(u32, rtg.RTGSET_LIMITED_RANGE);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardSettings(board, &line));
    try testing.expectEqual(own.id, defaultMode(rb, board).id);
    try testing.expectEqual(rtg.RTGRANGE_FULL, infoOf(rb, board).color_range);
    try testing.expectEqual(@as(u32, 640), lineOf(rb, board).mode_width);

    // The line taken away: the default and the range the board's own
    // again, the mirror and the brightness left as they are.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardSettings(board, &.{}));
    try testing.expectEqual(@as(u32, 0), lineOf(rb, board).flags);
    info = infoOf(rb, board);
    try testing.expectEqual(rtg.RTGRANGE_AUTO, info.color_range);
    try testing.expectEqual(@as(u8, 1), info.mirror_y);
    try testing.expectEqual(@as(u32, 40), info.brightness);
    try testing.expectEqualStrings("", settingsText(rb, &file)[settings.header.len..]);

    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).ShowBitMap(board, null));
    base(rb).FreeBitMap(picture);
    try tearDown(rb);
}

/// The 3840x2160 monitor with a product number of its own: another
/// monitor than `uhd_monitor`, which names the same modes.
fn otherUhd() [2]edid.Block {
    var other = uhd_monitor;
    other[0][10] = 0x34;
    other[0][11] = 0x12;
    other[0] = sealed(other[0]);
    return other;
}

test "a line is for the monitor it names: another on the output and it is not used, the first back and it is" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    // A panel's board first, then one with a connector and a 4K monitor.
    const panel = try makeDisplay(rb, 16, 16);
    fk.display = null;
    const board = try makeConnector(rb, uhd_bytes, 0);
    try testing.expectEqual(panel, base(rb).NextBoard(null).?);
    try testing.expectEqual(@as(u32, 1920), defaultMode(rb, board).width);
    const who = monitorOf(rb, board);

    // Its line: 4K at 30, where it would come up in 1080p, and this
    // board the first.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardSettings(board, &.{
        .flags = rtg.RTGSET_MODE | rtg.RTGSET_FIRST,
        .mode_width = 3840,
        .mode_height = 2160,
        .mode_refresh_mhz = 30_000,
    }));
    try testing.expectEqual(@as(u32, 3840), defaultMode(rb, board).width);
    try testing.expectEqual(board, base(rb).NextBoard(null).?);
    try testing.expectEqual(panel, base(rb).NextBoard(board).?);
    var line = lineOf(rb, board);
    try testing.expect(line.flags & rtg.RTGSET_MONITOR != 0);
    try testing.expectEqualStrings(std.mem.sliceTo(&who.maker, 0), std.mem.sliceTo(&line.maker, 0));
    try testing.expectEqual(who.product, line.product);
    try testing.expectEqual(who.serial, line.serial);

    // Another monitor that names the same modes: the line is not its own.
    // It comes up in the mode it prefers, and the board stands where it
    // was made.
    const other = otherUhd();
    fk.monitor_edid = std.mem.sliceAsBytes(&other);
    driverBase(rb).MonitorChanged(board);
    monitors.service(rb);
    try testing.expectEqual(@as(u32, 0), lineOf(rb, board).flags);
    try testing.expectEqual(@as(u32, 1920), defaultMode(rb, board).width);
    try testing.expectEqual(panel, base(rb).NextBoard(null).?);

    // A line of its own for this one, by the file: both are kept.
    var file: [settings.header.len + 4 * settings.line_most]u8 = undefined;
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardSettings(board, &.{ .flags = rtg.RTGSET_BRIGHTNESS, .brightness = 55 }));
    const kept = settingsText(rb, &file)[settings.header.len..];
    try testing.expect(std.mem.indexOf(u8, kept, ":0000:00000000 MODE=3840x2160@30 FIRST=YES\n") != null);
    try testing.expect(std.mem.indexOf(u8, kept, ":1234:00000000 BRIGHTNESS=55\n") != null);

    // The first monitor back: its line is in force again.
    fk.monitor_edid = uhd_bytes;
    driverBase(rb).MonitorChanged(board);
    monitors.service(rb);
    line = lineOf(rb, board);
    try testing.expectEqual(rtg.RTGSET_MONITOR | rtg.RTGSET_MODE | rtg.RTGSET_FIRST, line.flags);
    try testing.expectEqual(@as(u32, 3840), defaultMode(rb, board).width);
    try testing.expectEqual(board, base(rb).NextBoard(null).?);

    // A line that names no monitor is for whatever is there, where the
    // monitor has none of its own: read from a file, it is the other
    // monitor's and not this one's.
    try testing.expectEqual(@as(u32, 0), readSettings(rb, "OUTPUT=fake.1 MODE=3840x2160@30\nOUTPUT=fake.1 MONITOR=???:1234:0 MODE=1920x1080\n"));
    settings.applyAll(rb);
    try testing.expectEqual(@as(u32, 3840), defaultMode(rb, board).width);
    try testing.expectEqual(@as(u32, 30_000), defaultMode(rb, board).refresh_mhz);
    try testing.expectEqual(panel, base(rb).NextBoard(null).?);
    fk.monitor_edid = std.mem.sliceAsBytes(&other);
    driverBase(rb).MonitorChanged(board);
    monitors.service(rb);
    try testing.expectEqual(@as(u32, 1920), defaultMode(rb, board).width);

    // One board is the first: said of the panel's, the other's line no
    // longer says it.
    try testing.expectEqual(@as(u32, 0), readSettings(rb, "OUTPUT=fake.1 FIRST=YES\n"));
    settings.applyAll(rb);
    try testing.expectEqual(board, base(rb).NextBoard(null).?);
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardSettings(panel, &.{ .flags = rtg.RTGSET_FIRST }));
    try testing.expectEqual(panel, base(rb).NextBoard(null).?);
    try testing.expectEqualStrings("OUTPUT=fake.0 FIRST=YES\n", settingsText(rb, &file)[settings.header.len..]);
    try tearDown(rb);
}

test "timings by hand: the mode of a monitor that names none, and gone with its line" {
    const rb = try setUp();
    defer kexec.deinit();
    // A monitor that is there and says nothing, on a board with modes of
    // its own.
    const fk = fakeOf(rb);
    fk.connector = true;
    fk.modes = fake.mode_table.len;
    fk.monitor_there = true;
    fk.monitor_edid = null;
    const board = try makeBoard(rb);
    const own = base(rb).GetBoardModes(board, null, 0);
    const own_default = defaultMode(rb, board);

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
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardSettings(board, &by_hand));
    try testing.expectEqual(own + 1, base(rb).GetBoardModes(board, null, 0));
    const made = defaultMode(rb, board);
    try testing.expectEqual(@as(u32, 800), made.width);
    try testing.expectEqual(@as(u32, 600), made.height);
    try testing.expectEqual(@as(u32, 40_000_000), made.pixel_clock_hz);
    // A monitor that says nothing is not named.
    try testing.expectEqual(rtg.RTGSET_TIMINGS, lineOf(rb, board).flags);

    // The line gone, the mode is gone, and the default the board's own.
    try testing.expectEqual(rtg.errors.RTGERR_OK, base(rb).SetBoardSettings(board, &.{}));
    try testing.expectEqual(own, base(rb).GetBoardModes(board, null, 0));
    try testing.expectEqual(own_default.id, defaultMode(rb, board).id);
    try tearDown(rb);
}

test "a device's line: in front of its tags for the driver it is offered to" {
    const rb = try setUp();
    defer kexec.deinit();
    const fk = fakeOf(rb);
    // A device its driver does not take yet, and a line for it.
    fk.create_answer = rtg.errors.RTGERR_NO_DISPLAY;
    const device = fake.addDevice(fk, null).?;
    try testing.expect(device.driver == null);
    try testing.expectEqual(@as(u32, 0), readSettings(rb, "DEVICE=panel.0 COMPOSE=YES BUFFERS=4\n"));
    settings.dressAll(rb);
    try testing.expectEqual(@as(usize, 4), driverBase(rb).GetRtgTagData(rtg.tags.RTGA_Buffers, 0, device.tags));
    try testing.expectEqual(@as(usize, 1), driverBase(rb).GetRtgTagData(rtg.tags.RTGA_Compose, 0, device.tags));
    // Its own tags follow.
    try testing.expectEqual(driverBase(rb).GetRtgTagData(rtg.tags.RTGA_Width, 0, fake.deviceTags()), driverBase(rb).GetRtgTagData(rtg.tags.RTGA_Width, 0, device.tags));

    // The line gone, the device has its own tags again.
    try testing.expectEqual(@as(u32, 0), readSettings(rb, ""));
    settings.dressAll(rb);
    try testing.expectEqual(fake.deviceTags(), device.tags.?);

    // With the line, the board its driver then makes of it has its
    // windows composed.
    try testing.expectEqual(@as(u32, 0), readSettings(rb, "DEVICE=panel.0 COMPOSE=YES\n"));
    settings.dressAll(rb);
    fk.create_answer = rtg.errors.RTGERR_OK;
    try testing.expectEqual(@as(u32, 1), base(rb).BindRtgDrivers());
    const board = base(rb).NextBoard(null).?;
    try testing.expect(infoOf(rb, board).flags & rtg.boards.RTGBF_COMPOSE != 0);
    // A device a driver has keeps what it was offered with.
    try testing.expectEqual(@as(u32, 0), readSettings(rb, ""));
    settings.dressAll(rb);
    try testing.expectEqual(@as(usize, 1), driverBase(rb).GetRtgTagData(rtg.tags.RTGA_Compose, 0, device.tags));
    try tearDown(rb);
}
