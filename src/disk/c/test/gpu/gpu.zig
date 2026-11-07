// SPDX-License-Identifier: MIT
//! Gpu: an AMD graphics device's security processor started and the
//! video decoder's firmware loaded by it, each step said. Built against
//! the SDK only.
//!
//!   Gpu TOC/K,FIRMWARE/K,WATCHDOG/A/K/N
//!
//! The two files are read from DEVS:firmware/amdgpu/, named for the
//! blocks that use them as the device's table gives their versions -
//! psp_13_0_4_toc.bin for the security processor 13.0.4, vcn_4_0_2.bin
//! for the video decoder 4.0.2 - unless TOC and FIRMWARE name others.
//! amdgpu.resource is asked to make the processor ready
//! (StartGPUSecurity) and to load the firmware (LoadGPUFirmware), and
//! where it put it is printed. What the processor answered to each
//! command is on the system's lines (C:Log).
//!
//! WATCHDOG is the watchdog's time in milliseconds, armed before the
//! first write to the processor, fed after each step and disarmed at the
//! end: a processor that stops the machine has it reset. It is required,
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
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Gpu";
const VERSION_STRING = "\x00$VER: Gpu 1.0 (07.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TOC/K,FIRMWARE/K,WATCHDOG/A/K/N";
const arg_toc = 0;
const arg_firmware = 1;
const arg_watchdog = 2;

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
    var argv: [3]usize = @splat(0);
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
