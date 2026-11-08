// SPDX-License-Identifier: MIT
//! Gpu: an AMD graphics device tried a part at a time, each step said:
//! its security processor started and the video decoder's firmware loaded
//! by it, the display's interrupt at each frame counted, or one flip of
//! the picture the display reads. Built against the SDK only.
//!
//!   Gpu TOC/K,FIRMWARE/K,FRAMES/S,FLIP/S,PIPE/K/N,FETCHER/K/N,WATCHDOG/A/K/N
//!
//! Without FRAMES or FLIP the two files are read from
//! DEVS:firmware/amdgpu/, named for the blocks that use them as the
//! device's table gives their versions - psp_13_0_4_toc.bin for the
//! security processor 13.0.4, vcn_4_0_2.bin for the video decoder 4.0.2 -
//! unless TOC and FIRMWARE name others. amdgpu.resource is asked to make
//! the processor ready (StartGPUSecurity) and to load the firmware
//! (LoadGPUFirmware), and where it put it is printed. What the processor
//! answered to each command is on the system's lines (C:Log).
//!
//! FRAMES hooks the interrupt the display's pipe PIPE (0 unless given)
//! raises at each frame, where it takes up its double-buffered registers
//! (AddGPUIntServer), switches it on, and counts it for three seconds
//! beside the pipe's own count of frames; then switches it off. The first
//! server starts the device's interrupt ring, which says so on the
//! system's lines.
//!
//! FLIP has the fetcher FETCHER (0 unless given) of that pipe read a
//! frame of the device's own memory instead of the firmware's screen:
//! the frame holds a copy of the default public screen, rows as far
//! apart as the fetcher reads them, so the display shows what it showed -
//! but for the pointer, which is not in the screen's buffer. The flip is
//! the fetcher's new address, taken up at the pipe's next update; it is
//! waited for by the interrupt FRAMES counts, and how many frames and how
//! long it took is printed, with the address the fetcher then reads. Held
//! three seconds, then flipped back the same way, and the frame given
//! back.
//!
//! WATCHDOG is the watchdog's time in milliseconds, armed before the
//! first write to the device, fed after each step and disarmed at the
//! end: a block that stops the machine has it reset. It is required,
//! since nothing else brings a machine back that stopped there.

const sdk = @import("sdk");
const dos = sdk.dos;
const datatypes = sdk.datatypes;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const watchdog = sdk.resources.watchdog;
const WatchdogBase = sdk.interface.watchdog.WatchdogBase;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = sdk.interface.amdgpu.AMDGPUBase;
const exec = sdk.exec;
const intuition = sdk.intuition;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const timer = sdk.devices.timer;
const TimerBase = sdk.interface.timer.TimerBase;
const dcn = sdk.hardware.amd_dcn;
const reg = sdk.hardware.mmio.reg;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Gpu";
const VERSION_STRING = "\x00$VER: Gpu 1.1 (08.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TOC/K,FIRMWARE/K,FRAMES/S,FLIP/S,PIPE/K/N,FETCHER/K/N,WATCHDOG/A/K/N";
const arg_toc = 0;
const arg_firmware = 1;
const arg_frames = 2;
const arg_flip = 3;
const arg_pipe = 4;
const arg_fetcher = 5;
const arg_watchdog = 6;

/// Where the files are.
const directory = "DEVS:firmware/amdgpu/";

/// A file's name, put together from its parts.
const Name = struct {
    room: [64]u8 = undefined,
    len: usize = 0,

    fn text(name: *Name, part: []const u8) void {
        for (part) |c| {
            if (name.len + 1 >= name.room.len) return;
            name.room[name.len] = c;
            name.len += 1;
        }
    }

    fn number(name: *Name, value: u32) void {
        var digits: [10]u8 = undefined;
        var count: usize = 0;
        var left = value;
        while (true) {
            digits[count] = @intCast('0' + left % 10);
            count += 1;
            left /= 10;
            if (left == 0) break;
        }
        while (count > 0) {
            count -= 1;
            name.text(digits[count .. count + 1]);
        }
    }

    /// `prefix` with the block's version, `suffix` after it.
    fn of(prefix: []const u8, block: amdgpu.GPUBlock, suffix: []const u8) Name {
        var name: Name = .{};
        name.text(directory);
        name.text(prefix);
        name.number(block.major);
        name.text("_");
        name.number(block.minor);
        name.text("_");
        name.number(block.revision);
        name.text(suffix);
        name.room[name.len] = 0;
        return name;
    }

    fn string(name: *const Name) [*:0]const u8 {
        return @ptrCast(&name.room);
    }
};

/// The file `name` read whole into memory of its own (FreeVec), or null
/// with why said.
fn readFile(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8) ?[]u8 {
    const lock = dl.Lock(name, dos.SHARED_LOCK) orelse {
        _ = Printf(dl, "%s: cannot be found\n", .{name});
        return null;
    };
    defer dl.UnLock(lock);
    return switch (datatypes.subclass.readWhole(sys, dl, lock)) {
        .got => |bytes| bytes,
        else => {
            _ = Printf(dl, "%s: cannot be read\n", .{name});
            return null;
        },
    };
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [7]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const millis: u32 = @intCast(@max(1, @as(*const i32, @ptrFromInt(argv[arg_watchdog])).*));

    const ab: *AMDGPUBase = @ptrCast(sys.OpenResource(amdgpu.AMDGPUNAME) orelse {
        _ = Printf(dl, "No %s\n", .{amdgpu.AMDGPUNAME});
        return dos.RETURN_FAIL;
    });
    var info: amdgpu.GPUInfo = .{};
    if (!ab.GetGPUInfo(&info)) {
        _ = Printf(dl, "No AMD graphics device\n", .{});
        return dos.RETURN_WARN;
    }
    if (argv[arg_frames] != 0 or argv[arg_flip] != 0) {
        const pipe = number(argv[arg_pipe]);
        const fetcher = number(argv[arg_fetcher]);
        return display(sys, dl, ab, info, millis, pipe, fetcher, argv[arg_flip] != 0);
    }
    var security: amdgpu.GPUBlock = .{};
    var video: amdgpu.GPUBlock = .{};
    if (!ab.FindGPUBlock(amdgpu.GPUBLOCK_SECURITY, 0, &security) or !ab.FindGPUBlock(amdgpu.GPUBLOCK_VIDEO, 0, &video)) {
        _ = Printf(dl, "The device %04x:%04x names no security processor or no video decoder\n", .{ info.vendor, info.device });
        return dos.RETURN_FAIL;
    }
    _ = Printf(dl, "Device %04x:%04x: security processor %u.%u.%u, video decoder %u.%u.%u\n", .{
        info.vendor,                 info.device,           @as(u32, security.major), @as(u32, security.minor),
        @as(u32, security.revision), @as(u32, video.major), @as(u32, video.minor),    @as(u32, video.revision),
    });

    const toc_name = Name.of("psp_", security, "_toc.bin");
    const firmware_name = Name.of("vcn_", video, ".bin");
    const toc_path: [*:0]const u8 = if (argv[arg_toc] != 0) @ptrFromInt(argv[arg_toc]) else toc_name.string();
    const firmware_path: [*:0]const u8 = if (argv[arg_firmware] != 0) @ptrFromInt(argv[arg_firmware]) else firmware_name.string();
    const toc = readFile(sys, dl, toc_path) orelse return dos.RETURN_ERROR;
    defer sys.FreeVec(toc.ptr);
    const firmware = readFile(sys, dl, firmware_path) orelse return dos.RETURN_ERROR;
    defer sys.FreeVec(firmware.ptr);
    _ = Printf(dl, "%s: %lu bytes\n%s: %lu bytes\n", .{ toc_path, @as(u64, toc.len), firmware_path, @as(u64, firmware.len) });

    const wb: *WatchdogBase = @ptrCast(sys.OpenResource(watchdog.WATCHDOGNAME) orelse {
        _ = Printf(dl, "No %s\n", .{watchdog.WATCHDOGNAME});
        return dos.RETURN_FAIL;
    });
    if (!wb.ArmWatchdog(millis, watchdog.WATCHDOG_RESET_SYSTEM)) {
        _ = Printf(dl, "The watchdog refuses %u ms\n", .{millis});
        return dos.RETURN_FAIL;
    }
    defer wb.DisarmWatchdog();
    _ = Printf(dl, "Watchdog armed: %u ms\n", .{millis});

    if (!ab.StartGPUSecurity(toc.ptr, @intCast(toc.len))) {
        wb.FeedWatchdog();
        _ = Printf(dl, "The security processor is not ready: see C:Log\n", .{});
        return dos.RETURN_ERROR;
    }
    wb.FeedWatchdog();
    _ = Printf(dl, "The security processor is ready\n", .{});

    var address: u64 = 0;
    if (!ab.LoadGPUFirmware(amdgpu.GPUFIRMWARE_VIDEO, firmware.ptr, @intCast(firmware.len), &address)) {
        wb.FeedWatchdog();
        _ = Printf(dl, "The video decoder's firmware is not loaded: see C:Log\n", .{});
        return dos.RETURN_ERROR;
    }
    wb.FeedWatchdog();
    _ = Printf(dl, "The video decoder's firmware is at 0x%lx\n", .{address});
    return dos.RETURN_OK;
}

fn number(arg: usize) u32 {
    if (arg == 0) return 0;
    return @intCast(@max(0, @as(*const i32, @ptrFromInt(arg)).*));
}

// --- the display ---------------------------------------------------------------------

/// The display engine's registers, and the pipe and fetcher tried.
const Display = struct {
    registers: usize,
    segment: u32,
    pipe: u32,
    fetcher: u32,

    fn at(display_: Display, offset: u32) *volatile u32 {
        return reg(display_.registers + @as(usize, display_.segment + offset) * 4);
    }

    fn otg(display_: Display, offset: u32) *volatile u32 {
        return display_.at(offset + dcn.OTG_STRIDE * display_.pipe);
    }

    fn hubp(display_: Display, offset: u32) *volatile u32 {
        return display_.at(offset + dcn.HUBP_STRIDE * display_.fetcher);
    }

    /// The address the fetcher is told to read, and the one it reads.
    fn told(display_: Display) u64 {
        return @as(u64, display_.hubp(dcn.DCSURF_PRIMARY_SURFACE_ADDRESS_HIGH).* & dcn.ADDRESS_HIGH_MASK) << 32 |
            display_.hubp(dcn.DCSURF_PRIMARY_SURFACE_ADDRESS).*;
    }

    fn reading(display_: Display) u64 {
        return @as(u64, display_.hubp(dcn.DCSURF_SURFACE_EARLIEST_INUSE_HIGH).* & dcn.ADDRESS_HIGH_MASK) << 32 |
            display_.hubp(dcn.DCSURF_SURFACE_EARLIEST_INUSE).*;
    }
};

/// The pipe's interrupt at each frame: counted, acknowledged, and the
/// task told.
const Frames = struct {
    sys: *ExecBase,
    display: Display,
    count: u32 = 0,
    came: exec.Waitable = .{},
    server: exec.Interrupt = .{},
};

fn frameServer(data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const frames: *Frames = @ptrCast(@alignCast(data.?));
    const status = frames.display.otg(dcn.OTG_GLOBAL_SYNC_STATUS);
    status.* = status.* | dcn.VUPDATE_NO_LOCK_EVENT_CLEAR;
    @atomicStore(u32, &frames.count, frames.count +% 1, .release);
    frames.sys.SignalWaitable(&frames.came);
    return 1;
}

/// The server on and the interrupt switched on at the pipe; false where
/// the resource takes no server.
fn hook(ab: *AMDGPUBase, frames: *Frames) bool {
    frames.server = .{
        .node = .{ .type = .interrupt, .pri = 0, .name = COMMAND_NAME },
        .data = frames,
        .code = &frameServer,
    };
    if (!ab.AddGPUIntServer(amdgpu.GPUINT_CLIENT_DISPLAY, amdgpu.GPUINT_DISPLAY_UPDATE + frames.display.pipe, &frames.server)) return false;
    const status = frames.display.otg(dcn.OTG_GLOBAL_SYNC_STATUS);
    frames.sys.Disable();
    status.* = status.* | dcn.VUPDATE_NO_LOCK_EVENT_CLEAR | dcn.VUPDATE_NO_LOCK_INT_EN;
    frames.sys.Enable();
    return true;
}

fn unhook(ab: *AMDGPUBase, frames: *Frames) void {
    const status = frames.display.otg(dcn.OTG_GLOBAL_SYNC_STATUS);
    frames.sys.Disable();
    status.* = status.* & ~dcn.VUPDATE_NO_LOCK_INT_EN | dcn.VUPDATE_NO_LOCK_EVENT_CLEAR;
    frames.sys.Enable();
    ab.RemGPUIntServer(&frames.server);
}

/// The E-clock in microseconds.
fn micros(tb: *TimerBase) u64 {
    var value: timer.EClockVal = .{};
    const rate = tb.ReadEClock(&value);
    const count = value.toTicks();
    return count / rate * 1_000_000 + count % rate * 1_000_000 / rate;
}

/// Half-seconds waited, the watchdog fed after each.
fn hold(dl: *DosBase, wb: *WatchdogBase, halves: u32) void {
    for (0..halves) |_| {
        dl.Delay(25);
        wb.FeedWatchdog();
    }
}

/// FRAMES or FLIP, the watchdog armed for both.
fn display(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, info: amdgpu.GPUInfo, millis: u32, pipe: u32, fetcher: u32, flipping: bool) i32 {
    var block: amdgpu.GPUBlock = .{};
    if (!ab.FindGPUBlock(amdgpu.GPUBLOCK_DISPLAY, 0, &block) or block.count < 3) {
        _ = Printf(dl, "The device %04x:%04x names no display engine\n", .{ info.vendor, info.device });
        return dos.RETURN_FAIL;
    }
    const engine = Display{ .registers = @intCast(info.registers), .segment = block.addresses[2], .pipe = pipe, .fetcher = fetcher };
    _ = Printf(dl, "Display engine %u.%u.%u: pipe %u, frame %u, interrupts %x; fetcher %u reads 0x%lx, told 0x%lx, flip control %x\n", .{
        @as(u32, block.major),                         @as(u32, block.minor),                      @as(u32, block.revision),
        pipe,                                          engine.otg(dcn.OTG_STATUS_FRAME_COUNT).*,   engine.otg(dcn.OTG_GLOBAL_SYNC_STATUS).*,
        fetcher,                                       engine.reading(),                           engine.told(),
        engine.hubp(dcn.DCSURF_FLIP_CONTROL).*,
    });

    var clock: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &clock.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&clock.node);
    const tb: *TimerBase = @ptrCast(@alignCast(clock.node.device.?));

    const wb: *WatchdogBase = @ptrCast(sys.OpenResource(watchdog.WATCHDOGNAME) orelse {
        _ = Printf(dl, "No %s\n", .{watchdog.WATCHDOGNAME});
        return dos.RETURN_FAIL;
    });
    if (!wb.ArmWatchdog(millis, watchdog.WATCHDOG_RESET_SYSTEM)) {
        _ = Printf(dl, "The watchdog refuses %u ms\n", .{millis});
        return dos.RETURN_FAIL;
    }
    defer wb.DisarmWatchdog();
    _ = Printf(dl, "Watchdog armed: %u ms\n", .{millis});
    _ = dl.Flush(dl.Output());

    var frames = Frames{ .sys = sys, .display = engine };
    if (!hook(ab, &frames)) {
        wb.FeedWatchdog();
        _ = Printf(dl, "No server for the pipe's interrupt: see C:Log\n", .{});
        return dos.RETURN_ERROR;
    }
    defer unhook(ab, &frames);
    wb.FeedWatchdog();
    _ = Printf(dl, "Its interrupt is on: %x\n", .{engine.otg(dcn.OTG_GLOBAL_SYNC_STATUS).*});
    _ = dl.Flush(dl.Output());

    if (!flipping) {
        const first_frame = engine.otg(dcn.OTG_STATUS_FRAME_COUNT).*;
        const first_count = @atomicLoad(u32, &frames.count, .acquire);
        const started = micros(tb);
        hold(dl, wb, 6);
        const took = micros(tb) - started;
        const counted = @atomicLoad(u32, &frames.count, .acquire) - first_count;
        const scanned = engine.otg(dcn.OTG_STATUS_FRAME_COUNT).* -% first_frame;
        _ = Printf(dl, "%u interrupts and %u frames in %lu ms: %lu a second\n", .{
            counted, scanned, took / 1000, @as(u64, counted) * 1_000_000 / @max(took, 1),
        });
        return if (counted == 0) dos.RETURN_ERROR else dos.RETURN_OK;
    }
    return flipOnce(sys, dl, ab, tb, wb, &frames);
}

/// What one flip took.
const Flip = struct { frames: u32, micros: u64, pending: bool, reading: u64 };

/// The fetcher told to read `address` from the pipe's next update, and
/// that waited for: until the flip is no longer pending and the fetcher
/// reads it, or four frames.
fn flipTo(frames: *Frames, tb: *TimerBase, address: u64) Flip {
    const sys = frames.sys;
    const engine = frames.display;
    const control = engine.hubp(dcn.DCSURF_FLIP_CONTROL);
    control.* = control.* & ~(dcn.SURFACE_FLIP_TYPE | dcn.SURFACE_UPDATE_LOCK);
    // Every write of the frame reaches the device's memory before the
    // fetcher is told: a locked instruction drains the gathered writes.
    var drain: u32 = 0;
    _ = @atomicRmw(u32, &drain, .Add, 0, .seq_cst);
    const first = @atomicLoad(u32, &frames.count, .acquire);
    const started = micros(tb);
    engine.hubp(dcn.DCSURF_PRIMARY_SURFACE_ADDRESS_HIGH).* = @truncate(address >> 32 & dcn.ADDRESS_HIGH_MASK);
    engine.hubp(dcn.DCSURF_PRIMARY_SURFACE_ADDRESS).* = @truncate(address);
    var waited: u32 = 0;
    while (waited < 4) {
        sys.ResetWaitable(&frames.came);
        if (@atomicLoad(u32, &frames.count, .acquire) == first +% waited) {
            _ = sys.WaitForAny(&[_]*exec.Waitable{&frames.came}, 1, 50_000);
        }
        waited = @atomicLoad(u32, &frames.count, .acquire) -% first;
        if (control.* & dcn.SURFACE_FLIP_PENDING == 0 and engine.reading() == address) break;
    }
    return .{
        .frames = waited,
        .micros = micros(tb) - started,
        .pending = control.* & dcn.SURFACE_FLIP_PENDING != 0,
        .reading = engine.reading(),
    };
}

fn sayFlip(dl: *DosBase, what: [*:0]const u8, address: u64, flip: Flip) bool {
    const taken = !flip.pending and flip.reading == address;
    _ = Printf(dl, "%s 0x%lx: %s after %u frames, %lu us; the fetcher reads 0x%lx\n", .{
        what,                                                              address,
        if (taken) @as([*:0]const u8, "taken") else "NOT taken", flip.frames,
        flip.micros,                                                       flip.reading,
    });
    _ = dl.Flush(dl.Output());
    return taken;
}

/// One flip to a copy of the screen in the device's memory, held, and
/// one back.
fn flipOnce(sys: *ExecBase, dl: *DosBase, ab: *AMDGPUBase, tb: *TimerBase, wb: *WatchdogBase, frames: *Frames) i32 {
    const engine = frames.display;
    const lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const ib: *IntuitionBase = @ptrCast(lib);
    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, "No default public screen\n", .{});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);
    const buffer = ib.AllocScreenBuffer(screen, intuition.screens.SB_SCREEN_BITMAP) orelse {
        _ = Printf(dl, "The screen's buffer cannot be had\n", .{});
        return dos.RETURN_FAIL;
    };
    defer ib.FreeScreenBuffer(screen, buffer);
    const bitmap = buffer.bitmap;
    const pixels = bitmap.pixels orelse return dos.RETURN_FAIL;
    const pitch_pixels = (engine.hubp(dcn.DCSURF_SURFACE_PITCH).* & dcn.PITCH_MASK) + 1;
    const pitch: usize = @as(usize, pitch_pixels) * 4;
    if (bitmap.width > pitch_pixels or bitmap.pitch < bitmap.width * 4) {
        _ = Printf(dl, "The screen is %u wide, the fetcher's rows %u\n", .{ bitmap.width, pitch_pixels });
        return dos.RETURN_FAIL;
    }
    var frame: amdgpu.GPUMemory = .{};
    if (!ab.AllocGPUMemory(@intCast(pitch * bitmap.height), 4096, &frame)) {
        _ = Printf(dl, "No %lu bytes of the device's memory\n", .{@as(u64, pitch * bitmap.height)});
        return dos.RETURN_FAIL;
    }
    defer ab.FreeGPUMemory(&frame);
    const into: [*]u8 = @ptrFromInt(@as(usize, @intCast(frame.cpu)));
    for (0..bitmap.height) |y| {
        sys.CopyMem(pixels + y * bitmap.pitch, into + y * pitch, bitmap.width * 4);
    }
    _ = Printf(dl, "The screen, %ux%u, copied to 0x%lx (0x%lx to the device), rows %lu bytes apart\n", .{
        bitmap.width, bitmap.height, frame.cpu, frame.device, @as(u64, pitch),
    });
    _ = dl.Flush(dl.Output());
    wb.FeedWatchdog();

    const firmware = engine.told();
    const there = flipTo(frames, tb, frame.device);
    wb.FeedWatchdog();
    const went = sayFlip(dl, "Flipped to", frame.device, there);
    hold(dl, wb, 6);
    const back = flipTo(frames, tb, firmware);
    wb.FeedWatchdog();
    const came = sayFlip(dl, "Flipped back to", firmware, back);
    if (!came) {
        // Told again at once, wherever the scan is, so that the screen is
        // the firmware's whatever the update point did.
        const control = engine.hubp(dcn.DCSURF_FLIP_CONTROL);
        control.* = control.* | dcn.SURFACE_FLIP_TYPE;
        engine.hubp(dcn.DCSURF_PRIMARY_SURFACE_ADDRESS_HIGH).* = @truncate(firmware >> 32 & dcn.ADDRESS_HIGH_MASK);
        engine.hubp(dcn.DCSURF_PRIMARY_SURFACE_ADDRESS).* = @truncate(firmware);
        dl.Delay(5);
        control.* = control.* & ~dcn.SURFACE_FLIP_TYPE;
        _ = Printf(dl, "Told the firmware's screen at once: the fetcher reads 0x%lx\n", .{engine.reading()});
        // The frame may still be read: it is not given back.
        frame = .{};
    }
    return if (went and came) dos.RETURN_OK else dos.RETURN_ERROR;
}
