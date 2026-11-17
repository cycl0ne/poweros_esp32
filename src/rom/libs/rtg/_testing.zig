// SPDX-License-Identifier: MPL-2.0
//! What rtg.library's host tests share: the library made from its tag
//! with the kernel's exec and utility around it, the tests' timer.device,
//! the tests' board and its driver (`../rtg_driver/fakeboard/`), and the
//! helpers that make boards of the kinds the tests need and read what
//! the library and the driver did.
//!
//! A test sets up with `setUp()` and `defer kexec.deinit()`, and ends
//! with `try tearDown(rb)`, which takes the driver off, gives everything
//! back and checks that nothing is left. A call's own tests are at the
//! end of the call's file and name what is here as `fixture.<name>`;
//! the tests of calls working together are in `rtg.zig`.
//!
//! Nothing here is part of the library: no other file imports it but
//! for its tests.

pub const std = @import("std");
pub const sdk = @import("sdk");
pub const exec = sdk.exec;
pub const utility = sdk.utility;
pub const TagItem = utility.TagItem;
pub const rtg = sdk.rtg;

const rtg_base = @import("rtg_base.zig");
const rtg_init = @import("rtg_init.zig");
pub const RtgBase = rtg_base.RtgBase;
pub const LIBRARY_NAME = rtg_init.LIBRARY_NAME;
pub const rtg_library_tag = rtg_init.rtg_library_tag;

pub const testing = std.testing;

/// The library's interface as the SDK has it, for the tests' calls.
pub const interface = sdk.interface.rtg;

pub const memory = @import("memory/_memory.zig");

pub const boards = @import("board/_board.zig");

pub const modes = @import("mode/_mode.zig");

pub const frame_state = @import("frame/_frame.zig");

pub const monitors = @import("monitor/_monitor.zig");

pub const edid = @import("monitor/_edid.zig");

pub const flips = @import("compose/_flip.zig");

pub const settings = @import("settings/_settings.zig");

pub const load = @import("load/_load.zig");

/// The kernel's exec and utility, to set up and tear down around it.
pub const kexec = @import("../exec/exec.zig");

pub const kutility = @import("../utility/utility.zig");

/// graphics.library's pen packing, which the pointer's conversion is held
/// to.
pub const kpens = @import("../graphics/rastport/_rastport.zig");

pub const fake = @import("../rtg_driver/fakeboard/fakeboard.zig");

pub const fakebus = @import("../rtg_driver/fakeboard/fakebus.zig");

pub const devices = @import("device/_device.zig");

pub const registry = @import("driver/_driver.zig");

pub const timer = sdk.devices.timer;

/// timer.device for the tests. It serves what the library sends and
/// nothing else: TR_ADDREQUEST on the unit its open gave, which waits
/// until a test lets its time pass (`expire`); any other request is
/// answered IOERR_NOCMD at once, as the device answers a command it does
/// not know. What a request was sent with is kept for the test to read.
/// One request at a time, which is all the library sends.
pub const FakeTimer = struct {
    pub var device: ?*exec.Device = null;
    pub var unit: exec.Unit = .{};
    /// The unit number the device was opened on; `no_unit` before.
    pub var opened_unit: u32 = no_unit;
    pub const no_unit = ~@as(u32, 0);
    /// The request whose time has not come.
    pub var waiting: ?*exec.IORequest = null;
    /// How an abort is answered: with the reply made inside AbortIO, as
    /// the device makes it - or, set, with the request only taken off and
    /// its reply left for `land`, as a device that answers an abort
    /// before the reply is made.
    pub var abort_replies_later = false;
    /// The request an abort took off whose reply is still to be made.
    pub var leaving: ?*exec.IORequest = null;
    /// Requests sent and taken back, and the time the last was sent with.
    pub var sent: u32 = 0;
    pub var aborted: u32 = 0;
    pub var last_micros: u64 = 0;
    /// Where the last request sent was. Never read through: its memory
    /// is its sender's, and has gone by the time a test looks.
    pub var last: ?*exec.IORequest = null;

    pub fn open(dev: *exec.Device, io: *exec.IORequest, unit_number: u32, flags: u32) callconv(.c) i32 {
        _ = flags;
        dev.open_cnt += 1;
        opened_unit = unit_number;
        io.unit = &unit;
        return 0;
    }
    pub fn close(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
        _ = io;
        dev.open_cnt -= 1;
        return null;
    }
    /// Never by itself: `remove` takes it off.
    pub fn expunge(dev: *exec.Device) callconv(.c) ?*anyopaque {
        _ = dev;
        return null;
    }
    pub fn beginIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) void {
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
    pub fn abortIO(dev: *exec.Device, io: *exec.IORequest) callconv(.c) i32 {
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
    pub fn expire() void {
        const io = waiting orelse return;
        waiting = null;
        kexec.ReplyIO(kexec.SysBase, io);
    }
    /// The reply of the request an abort took off, made now.
    pub fn land() void {
        const io = leaving orelse return;
        leaving = null;
        kexec.ReplyIO(kexec.SysBase, io);
    }

    pub const vectors = [_]*const anyopaque{
        exec.vec(open),
        exec.vec(close),
        exec.vec(expunge),
        exec.vec(exec.libExtFunc),
        exec.vec(beginIO),
        exec.vec(abortIO),
    };

    /// The device on exec's list, before the library is made and opens it.
    pub fn add() !void {
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
    pub fn remove() void {
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
pub const Sleep = struct {
    /// What an interrupt does while the task sleeps.
    pub var meanwhile: ?*const fn () void = null;
    /// How often a task slept, and how many interrupts came meanwhile.
    pub var sleeps: u32 = 0;
    pub var interrupts: u32 = 0;
    pub var switching = false;
    /// The switch that was there before.
    pub var before: *const fn () void = undefined;
    /// More interrupts than this in one sleep is a wait nothing ends.
    pub const patience = 16;

    pub fn switchNow() void {
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

    pub fn install(happens: *const fn () void) void {
        meanwhile = happens;
        sleeps = 0;
        interrupts = 0;
        before = kexec.task_hardware.switch_now;
        kexec.task_hardware.switch_now = switchNow;
    }

    pub fn uninstall() void {
        meanwhile = null;
        kexec.task_hardware.switch_now = before;
    }
};

/// exec on its test RAM, utility.library and rtg.library from their tags,
/// the tests' timer.device there for the library to open, and the test
/// board's driver put on the list: exec has no ROM here whose tags the
/// library could read for drivers.
pub fn setUp() !*RtgBase {
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
pub fn fakeOf(rb: *RtgBase) *fake.State {
    return fake.stateOf(driverNamed(rb, fake.DRIVER_NAME).?);
}

/// The driver of that name on the library's list, or null.
pub fn driverNamed(rb: *RtgBase, name: [*:0]const u8) ?*rtg.RtgDriver {
    return registry.driverOf(kexec.FindName(kexec.SysBase, &rb.drivers, name) orelse return null);
}

/// The drivers on the library's list, in its order, as their names.
pub fn driverNames(rb: *RtgBase, into: *[8]rtg.RtgDriverInfo) u32 {
    return base(rb).GetRtgDrivers(into, into.len);
}

/// Neither library expunges itself: take the driver off, close utility
/// and the timer for rtg, free all three, and check that nothing is left -
/// no memory, and no signal of the test's task that a wait took.
pub fn tearDown(rb: *RtgBase) !void {
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
pub fn base(rb: *RtgBase) *interface.RtgBase {
    return @ptrCast(rb);
}

/// The library through its second interface, the way a driver reaches it.
pub fn driverBase(rb: *RtgBase) *sdk.interface.rtgdriver.RtgDriverBase {
    return @ptrCast(rb);
}

/// A board put in the mode of that number - its default for 0 - showing
/// nothing.
pub fn setMode(rb: *RtgBase, board: *rtg.RtgBoard, mode_id: u32) i32 {
    const id = if (mode_id != 0) mode_id else base(rb).FindBoardMode(board, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY);
    if (id == 0) return rtg.errors.RTGERR_BAD_MODE;
    return base(rb).ShowBoard(board, id, null, 0);
}

/// A device of the test board's kind offered, and the board its driver
/// made of it.
pub fn makeBoard(rb: *RtgBase) !*rtg.RtgBoard {
    return fake.makeBoard(fakeOf(rb)) orelse error.NoBoard;
}

/// Two drivers' ROM tags, as a boot scan would have found them.
pub const RomTags = struct {
    pub const ops = rtg.RtgDriverOps{ .attach = @ptrFromInt(0x1000) };
    pub const low: rtg.ResidentRtgDriver = .{
        .resident = .{ .match_tag = &low.resident, .type = .rtg_driver, .name = "rtg-low" },
        .spec = .{ .name = "low", .priority = -5, .kind = rtg.drivers.RTGDT_BOARD, .ops = &ops },
    };
    pub const high: rtg.ResidentRtgDriver = .{
        .resident = .{ .match_tag = &high.resident, .type = .rtg_driver, .name = "rtg-high" },
        .spec = .{ .name = "high", .priority = 5, .kind = rtg.drivers.RTGDT_BOARD, .ops = &ops },
    };
};

/// A driver of the tests' own that makes a board and leaves it, declining:
/// what an attach may not do, which the library puts right.
pub const Careless = struct {
    pub const board_ops = rtg.RtgBoardOps{};
    pub fn attach(driver: *rtg.RtgDriver, device: *rtg.RtgDevice, _: ?[*]const TagItem) callconv(.c) i32 {
        _ = driver.rtg_base.CreateBoard(driver, device, &.{ .ops = &board_ops, .instance_size = 24 });
        return rtg.errors.RTGERR_IO;
    }
    pub const ops = rtg.RtgDriverOps{ .attach = &attach };
    pub const matches = [_]rtg.RtgMatch{ .{ .fields = rtg.drivers.RTGMATCH_CHIP, .chip = fake.chip, .priority = 5 }, .{} };
    pub const spec = rtg.RtgDriverSpec{ .name = "careless", .kind = rtg.drivers.RTGDT_BOARD, .matches = &matches, .ops = &ops };
};

/// The board's modes, copied out; how many of them there are.
pub fn modesOf(rb: *RtgBase, board: *rtg.RtgBoard, into: *[8]rtg.RtgMode) u32 {
    return base(rb).GetBoardModes(board, into, into.len);
}

/// A first block made an EDID's: its header put in front and the sum of
/// its bytes brought to zero.
pub fn sealed(block: edid.Block) edid.Block {
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
pub fn summed(block: edid.Block) edid.Block {
    var whole = block;
    whole[127] = 0;
    var sum: u8 = 0;
    for (whole) |byte| sum +%= byte;
    whole[127] = 0 -% sum;
    return whole;
}

/// The portable 1080p monitor's EDID, as a driver's `detect` hands it
/// over.
pub const portable_bytes: []const u8 = std.mem.sliceAsBytes(&edid.portable_1080p);

/// A 3840x2160 monitor: 4K at 60 preferred, at 594 MHz, and in its
/// extension CEA's numbers 95 (4K at 30) and 16 (1080p at 60).
pub const uhd_monitor: [2]edid.Block = blocks: {
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

pub const uhd_bytes: []const u8 = std.mem.sliceAsBytes(&uhd_monitor);

/// A 2560x1440 monitor that names its one mode in full and nothing else.
pub const qhd_monitor: [1]edid.Block = blocks: {
    var first: edid.Block = @splat(0);
    for (38..54) |i| first[i] = 0x01;
    const qhd = [18]u8{ 0x56, 0x5E, 0x00, 0xA0, 0xA0, 0xA0, 0x29, 0x50, 0x30, 0x20, 0x35, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1A };
    @memcpy(first[54..72], &qhd);
    break :blocks .{sealed(first)};
};

pub const qhd_bytes: []const u8 = std.mem.sliceAsBytes(&qhd_monitor);

/// A board of the test driver's with a connector, the monitor of `bytes`
/// on it, and none of the driver's own modes unless `own` says how many.
pub fn makeConnector(rb: *RtgBase, bytes: ?[]const u8, own: u32) !*rtg.RtgBoard {
    const fk = fakeOf(rb);
    fk.connector = true;
    fk.modes = own;
    fk.monitor_there = bytes != null;
    fk.monitor_edid = bytes;
    return makeBoard(rb);
}

/// What the board says of itself now.
pub fn infoOf(rb: *RtgBase, board: *rtg.RtgBoard) rtg.RtgBoardInfo {
    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    return info;
}

/// What is on the board's connector, as the library last saw it.
pub fn monitorOf(rb: *RtgBase, board: *rtg.RtgBoard) rtg.RtgMonitorInfo {
    var said: rtg.RtgMonitorInfo = .{};
    _ = base(rb).GetBoardMonitor(board, &said, @sizeOf(rtg.RtgMonitorInfo));
    return said;
}

/// A detailed timing of a small picture at 60 a second: `width` by
/// `height` in a line of `width + 36` clocks and a frame of
/// `height + 18` lines, the horizontal front porch `h_front`, both sync
/// pulses high.
pub fn smallTiming(width: u8, height: u8, h_front: u8) [18]u8 {
    const whole: u32 = (@as(u32, width) + 36) * (@as(u32, height) + 18);
    const clock_10khz: u16 = @intCast(whole * 60 / 10_000);
    return .{ @truncate(clock_10khz), @truncate(clock_10khz >> 8), width, 36, 0, height, 18, 0, h_front, 8, 0x22, 0, 0, 0, 0, 0, 0, 0x1E };
}

/// A monitor of one or two small modes, named in full: the first is the
/// one it prefers.
pub fn smallMonitor(first: [18]u8, second: ?[18]u8) [1]edid.Block {
    var block: edid.Block = @splat(0);
    for (38..54) |i| block[i] = 0x01;
    @memcpy(block[54..72], &first);
    if (second) |timing| @memcpy(block[72..90], &timing);
    return .{sealed(block)};
}

/// A board of the test driver's with one mode of that size in RGB565: a
/// display small enough for its pictures to fit the tests' memory.
pub fn makeDisplay(rb: *RtgBase, width: u32, height: u32) !*rtg.RtgBoard {
    return fake.makeDisplay(fakeOf(rb), width, height, .rgb565) orelse error.NoBoard;
}

/// A second mode on a display, of that size: its number.
pub fn addMode(rb: *RtgBase, board: *rtg.RtgBoard, width: u32, height: u32) u32 {
    const timings: rtg.RtgTimings = .{ .h_active = width, .v_active = height };
    return driverBase(rb).AddBoardMode(board, &timings, @intFromEnum(rtg.PixelFormat.rgb565), 0);
}

/// The board's modes into a short list; how many there are.
pub fn modesOf4(rb: *RtgBase, board: *rtg.RtgBoard, into: *[4]rtg.RtgMode) u32 {
    return base(rb).GetBoardModes(board, into, into.len);
}

/// What the driver saw of the board's lock while it worked: how often it
/// was held by the task that called, and how often not.
pub const Held = struct {
    pub var seen: u32 = 0;
    pub var missed: u32 = 0;

    /// The fake board's `meanwhile`: the lock of the board it works on is
    /// the calling task's.
    pub fn look(board: *rtg.RtgBoard) void {
        const lock = &boards.privateOf(board).lock;
        if (lock.owner == kexec.FindTask(kexec.SysBase, null) and lock.nestCount() != 0) seen += 1 else missed += 1;
    }

    /// Whether nothing holds the lock of `board`.
    pub fn free(board: *rtg.RtgBoard) bool {
        const lock = &boards.privateOf(board).lock;
        return lock.owner == null and lock.nestCount() == 0;
    }
};

/// How often a new picture was shown on `board`, as the library counts.
pub fn swapsOf(rb: *RtgBase, board: *rtg.RtgBoard) u32 {
    var stats: rtg.RtgBoardStats = .{};
    _ = base(rb).GetBoardStats(board, &stats, @sizeOf(rtg.RtgBoardStats));
    return stats.buffer_swaps;
}

/// The display memory of `board` not handed out.
pub fn freeOf(rb: *RtgBase, board: *rtg.RtgBoard) usize {
    var info: rtg.RtgBoardInfo = .{};
    _ = base(rb).GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    return info.memory_free;
}

/// The frames `board` has counted, as its stats say.
pub fn blanksOf(rb: *RtgBase, board: *rtg.RtgBoard) u32 {
    var stats: rtg.RtgBoardStats = .{};
    _ = base(rb).GetBoardStats(board, &stats, @sizeOf(rtg.RtgBoardStats));
    return stats.blanks;
}

/// Whether `board` says its frames just now, as its info says.
pub fn saysFrames(rb: *RtgBase, board: *rtg.RtgBoard) bool {
    return infoOf(rb, board).caps & rtg.boards.RTGBC_VBLANK != 0;
}

/// The board the frames of the next tests end on.
pub var frames_board: ?*rtg.RtgBoard = null;

pub fn endOneFrame() void {
    fake.endFrame(frames_board.?);
}

/// A frame ends - or, where an abort's reply is still to be made, that
/// reply lands.
pub fn frameOrLanding() void {
    if (FakeTimer.leaving != null) FakeTimer.land() else endOneFrame();
}

/// How often `oneFrameThenTime` ran.
pub var frames_then_time: u32 = 0;

/// The first interrupt ends a frame, which is not yet the count; the
/// next lets the limit's time pass.
pub fn oneFrameThenTime() void {
    frames_then_time += 1;
    if (frames_then_time == 1) endOneFrame() else FakeTimer.expire();
}

/// The first byte of a buffer's row.
pub fn rowOf(bitmap: *const rtg.RtgBitMap, y: u32) [*]u8 {
    return bitmap.pixels.? + @as(usize, y) * bitmap.pitch;
}

/// Whether pixel (x, y) of a converted image is the image's own, by its
/// mask.
pub fn opaqueAt(image: *const rtg.RtgPointerImage, x: u32, y: u32) bool {
    return image.mask[y * image.mask_pitch + x / 8] & (@as(u8, 0x80) >> @intCast(x % 8)) != 0;
}

/// A pixel written 0xRRGGBBAA as rgba32 lays it out in memory: red,
/// green, blue and alpha, a byte each.
pub fn rgba(value: u32) u32 {
    return @byteSwap(value);
}

// --- the picture the library composes ----------------------------------------

/// A board of the test driver's whose display has a picture of its own,
/// with one mode of that size in RGB565, whose display reads `reads` bands
/// by itself.
pub fn makeComposed(rb: *RtgBase, width: u32, height: u32, reads: u32) !*rtg.RtgBoard {
    const fk = fakeOf(rb);
    fk.composed = true;
    fk.direct_bands = reads;
    defer fk.composed = false;
    defer fk.direct_bands = null;
    return makeDisplay(rb, width, height);
}

/// What `paint` writes at (x, y) of a buffer marked `mark`: a pixel that
/// says where it came from.
pub fn painted(mark: u16, x: u32, y: u32) u16 {
    return mark << 12 | @as(u16, @intCast(y)) << 6 | @as(u16, @intCast(x));
}

/// Every pixel of an RGB565 buffer written with its own place and `mark`.
pub fn paint(bitmap: *rtg.RtgBitMap, mark: u16) void {
    var y: u32 = 0;
    while (y < bitmap.height) : (y += 1) {
        const row: [*]u16 = @ptrCast(@alignCast(bitmap.pixels.? + @as(usize, y) * bitmap.pitch));
        var x: u32 = 0;
        while (x < bitmap.width) : (x += 1) row[x] = painted(mark, x, y);
    }
}

/// One pixel of an RGB565 buffer written.
pub fn poke(bitmap: *rtg.RtgBitMap, x: u32, y: u32, value: u16) void {
    const row: [*]u16 = @ptrCast(@alignCast(bitmap.pixels.? + @as(usize, y) * bitmap.pitch));
    row[x] = value;
}

/// The pixel at (x, y) of the picture the test board was last delivered.
pub fn onGlass(board: *rtg.RtgBoard, x: u32, y: u32) u16 {
    const instance = fake.instanceOf(board);
    const row: [*]const u16 = @ptrCast(@alignCast(instance.picture.? + @as(usize, y) * instance.picture_pitch));
    return row[x];
}

/// Whether the picture the test board was delivered is the buffer marked
/// `mark`, whole, with nothing over it.
pub fn seesOnly(board: *rtg.RtgBoard, mark: u16) bool {
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

pub const red: u16 = 0xF800;

pub const green: u16 = 0x07E0;

pub const blue: u16 = 0x001F;

pub const white: u16 = 0xFFFF;

/// What the driver saw of the board's compose lock while it delivered.
pub const Composing = struct {
    pub var seen_held: u32 = 0;
    pub var missed: u32 = 0;

    /// The fake board's `meanwhile`: the compose lock of the board it
    /// works on is the calling task's.
    pub fn look(board: *rtg.RtgBoard) void {
        const lock = &boards.privateOf(board).compose.lock;
        if (lock.owner == kexec.FindTask(kexec.SysBase, null) and lock.nestCount() != 0) seen_held += 1 else missed += 1;
    }

    /// Whether nothing holds either lock of `board`.
    pub fn free(board: *rtg.RtgBoard) bool {
        const lock = &boards.privateOf(board).compose.lock;
        return lock.owner == null and lock.nestCount() == 0 and Held.free(board);
    }
};

// --- a band of another size ---------------------------------------------------

/// Every pixel of an RGB565 buffer written with one colour.
pub fn flood(bitmap: *rtg.RtgBitMap, colour: u16) void {
    var y: u32 = 0;
    while (y < bitmap.height) : (y += 1) {
        var x: u32 = 0;
        while (x < bitmap.width) : (x += 1) poke(bitmap, x, y, colour);
    }
}

// --- mirrored, and dark -------------------------------------------------------

// --- a board that is flipped between frames ---------------------------------

/// A board of the test driver's that is flipped between frames, with one
/// mode of that size in RGB565.
pub fn makeFlipped(rb: *RtgBase, width: u32, height: u32) !*rtg.RtgBoard {
    const fk = fakeOf(rb);
    fk.flipped = true;
    defer fk.flipped = false;
    return makeDisplay(rb, width, height);
}

/// The pixel at (x, y) of the frame the test board's display reads.
pub fn glassAt(board: *rtg.RtgBoard, x: u32, y: u32) u16 {
    const glass = fake.glassOf(board).?;
    const row: [*]const u16 = @ptrCast(@alignCast(glass.pixels.? + @as(usize, y) * glass.pitch));
    return row[x];
}

/// Whether the frame the display reads is the buffer marked `mark`,
/// whole, but for the pixels a test names as changed.
pub fn glassIs(board: *rtg.RtgBoard, mark: u16, changed: []const [3]u16) bool {
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

/// What a flipped board's driver saw of the locks while it flipped.
pub const Flipping = struct {
    pub var flips_seen: u32 = 0;
    pub var compose_held: u32 = 0;
    pub var flip_lock_missed: u32 = 0;

    pub fn look(board: *rtg.RtgBoard) void {
        const me = kexec.FindTask(kexec.SysBase, null);
        const compose = &boards.privateOf(board).compose;
        flips_seen += 1;
        if (compose.lock.owner != null or compose.lock.nestCount() != 0) compose_held += 1;
        if (compose.flip.lock.owner != me or compose.flip.lock.nestCount() == 0) flip_lock_missed += 1;
    }
};

/// What a watch hook was told: how often, and the last rectangle.
pub const Told = struct {
    calls: u32 = 0,
    rect: rtg.RtgRect = .{},

    pub fn hear(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
        _ = object;
        const told: *Told = @ptrCast(@alignCast(hook.data.?));
        told.calls += 1;
        told.rect = @as(*const rtg.RtgRect, @ptrCast(@alignCast(message.?))).*;
        return 0;
    }
};

// --- settings -----------------------------------------------------------------

/// The settings' file as the library writes it, into `into`.
pub fn settingsText(rb: *RtgBase, into: []u8) []const u8 {
    settings.obtain(rb);
    defer settings.release(rb);
    return into[0..settings.write(rb, into)];
}

/// A file's text read in place of the lines held; how many lines could
/// not be read.
pub fn readSettings(rb: *RtgBase, file: []const u8) u32 {
    settings.obtain(rb);
    defer settings.release(rb);
    return settings.read(rb, file);
}

/// The board's line in force.
pub fn lineOf(rb: *RtgBase, board: *rtg.RtgBoard) rtg.RtgSettings {
    var line: rtg.RtgSettings = .{};
    _ = base(rb).GetBoardSettings(board, &line, @sizeOf(rtg.RtgSettings));
    return line;
}

/// The board's default mode.
pub fn defaultMode(rb: *RtgBase, board: *rtg.RtgBoard) rtg.RtgMode {
    var mode: rtg.RtgMode = .{};
    _ = base(rb).BestBoardMode(board, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY, rtg.RTG_ANY, &mode);
    return mode;
}

/// The 3840x2160 monitor with a product number of its own: another
/// monitor than `uhd_monitor`, which names the same modes.
pub fn otherUhd() [2]edid.Block {
    var other = uhd_monitor;
    other[0][10] = 0x34;
    other[0][11] = 0x12;
    other[0] = sealed(other[0]);
    return other;
}

// --- drivers from the disk ----------------------------------------------------

/// A driver's load file made in memory: one data segment with a word of
/// something, the driver's tag, its name and its table - each pointer an
/// offset into the segment, as a file has them.
pub fn driverFile(into: []u8, name: []const u8, kind: exec.NodeType, entries: []const rtg.RtgMatch) []const u8 {
    const loadfile = sdk.dos.loadfile;
    const tag_at: usize = 16;
    const name_at = tag_at + @sizeOf(rtg.ResidentRtgDriver);
    const table_at = std.mem.alignForward(usize, name_at + name.len + 1, 8);
    const size = table_at + (entries.len + 1) * @sizeOf(rtg.RtgMatch);
    const start = @sizeOf(loadfile.Header) + @sizeOf(loadfile.SegmentHeader);
    @memset(into[0 .. start + size], 0);
    const header: loadfile.Header = .{ .segments = 1, .entry_segment = 0, .entry_offset = 0 };
    @memcpy(into[0..@sizeOf(loadfile.Header)], std.mem.asBytes(&header));
    const segment: loadfile.SegmentHeader = .{ .kind = .data, .file_size = @intCast(size), .mem_size = @intCast(size), .reloc_groups = 0 };
    @memcpy(into[@sizeOf(loadfile.Header)..][0..@sizeOf(loadfile.SegmentHeader)], std.mem.asBytes(&segment));

    const bytes = into[start..][0..size];
    const tag = bytes[tag_at..];
    std.mem.writeInt(u16, tag[0..2], exec.RTC_MATCHWORD, .little);
    // The tag's pointer to itself: its own offset, in the word after the
    // match word's.
    std.mem.writeInt(u32, tag[loadfile.native_word_size..][0..4], @intCast(tag_at), .little);
    tag[@offsetOf(exec.Resident, "type")] = @intFromEnum(kind);
    const spec = tag[@offsetOf(rtg.ResidentRtgDriver, "spec")..];
    std.mem.writeInt(u32, spec[@offsetOf(rtg.RtgDriverSpec, "name")..][0..4], @intCast(name_at), .little);
    std.mem.writeInt(u32, spec[@offsetOf(rtg.RtgDriverSpec, "kind")..][0..4], rtg.drivers.RTGDT_BOARD, .little);
    std.mem.writeInt(u32, spec[@offsetOf(rtg.RtgDriverSpec, "matches")..][0..4], @intCast(table_at), .little);
    @memcpy(bytes[name_at..][0..name.len], name);
    @memcpy(bytes[table_at..][0 .. entries.len * @sizeOf(rtg.RtgMatch)], std.mem.sliceAsBytes(entries));
    return into[0 .. start + size];
}
