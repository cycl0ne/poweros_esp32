// SPDX-License-Identifier: MPL-2.0
//! amdgpu.resource's ROM tag, and the init routine it names: the device
//! found, claimed and its table of blocks read, then what the device says
//! of itself put on the boot's lines.
//!
//! **What is said, and why all of it.** The blocks the system's drivers
//! use - their versions and where their registers are - then the memory
//! hub as the firmware left it, whether the security processor's system
//! runs, and the power manager's firmware version, which is asked for
//! through its mailbox and is the one thing written. Every other block of
//! the table goes on the debug lines. These are the facts every driver of
//! the device starts from, and the machines they are read on are not the
//! author's, so the numbers themselves are the finding.
//!
//! On a machine without the device the resource is made all the same:
//! GetGPUInfo and FindGPUBlock answer false.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const ExecBase = sdk.interface.exec.ExecBase;
const amdgpu_lvo = @import("amdgpu_lvo.zig");
const AMDGPUBase = @import("amdgpu_base.zig").AMDGPUBase;
const _device = @import("device/_device.zig");
const _table = @import("table/_table.zig");
const _memory = @import("memory/_memory.zig");
const _security = @import("security/_security.zig");
const _power = @import("power/_power.zig");

/// The name it is opened by. The SDK's.
pub const RESOURCE_NAME = amdgpu.AMDGPUNAME;
pub const RESOURCE_VERSION = 1;
pub const RESOURCE_REVISION = 1;
const BUILD_DATE = "07.11.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn amdgpuBase(lib: *exec.Library) *AMDGPUBase {
    return @alignCast(@fieldParentPtr("lib", lib));
}

/// ResInit: the device taken, where the machine has one, and what it
/// says of itself told.
///
/// CONTEXT:
/// - Waits: for the power manager's mailbox, a millisecond or so. -
///   Interrupts: no; it runs on the exec task at cold start.
/// - Locks: none needed. - Process: a Task will do.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const ab = amdgpuBase(lib);
    lib.revision = RESOURCE_REVISION;
    ab.sys_base = sys_base;
    ab.device = null;
    ab.pci_lib = null;
    ab.pci = null;
    ab.info = .{};
    ab.table = 0;
    ab.table_room = null;
    ab.power = .{};
    ab.power_known = false;
    sys_base.InitSemaphore(&ab.mailbox_lock);
    ab.memory_device = 0;
    ab.memory_machine = 0;
    ab.memory_bytes = 0;
    ab.memory_gathered = false;
    ab.arena = .{};
    sys_base.InitSemaphore(&ab.arena_lock);
    if (_device.take(ab)) {
        const gpu: *sdk.interface.amdgpu.AMDGPUBase = @ptrCast(&ab.lib);
        var block: amdgpu.GPUBlock = .{};
        if (gpu.FindGPUBlock(amdgpu.GPUBLOCK_MEMORY_HUB, 0, &block)) _memory.take(ab, block);
        if (gpu.FindGPUBlock(amdgpu.GPUBLOCK_POWER, 0, &block)) _power.take(ab, block);
        tell(ab);
    }
    return lib;
}

/// The kinds of block the system's drivers use, and what each is called
/// on the boot's lines.
const named = [_]struct { id: u32, name: [*:0]const u8 }{
    .{ .id = amdgpu.GPUBLOCK_DISPLAY, .name = "display engine" },
    .{ .id = amdgpu.GPUBLOCK_VIDEO, .name = "video" },
    .{ .id = amdgpu.GPUBLOCK_SECURITY, .name = "security processor" },
    .{ .id = amdgpu.GPUBLOCK_POWER, .name = "power manager" },
    .{ .id = amdgpu.GPUBLOCK_MEMORY_HUB, .name = "memory hub" },
    .{ .id = amdgpu.GPUBLOCK_BUS, .name = "bus" },
};

/// What the device says of itself, on the boot's lines.
fn tell(ab: *AMDGPUBase) void {
    const sys = ab.sys_base;
    const gpu: *sdk.interface.amdgpu.AMDGPUBase = @ptrCast(&ab.lib);
    var info: amdgpu.GPUInfo = .{};
    if (!gpu.GetGPUInfo(&info)) return;
    exec.kprintf(sys, "%s: registers 0x%lx %ldK, memory window 0x%lx %ldM, memory %ldM\n", .{
        RESOURCE_NAME,
        info.registers,
        info.registers_bytes / 1024,
        info.window,
        info.window_bytes / (1024 * 1024),
        info.memory_bytes / (1024 * 1024),
    });

    var count: u32 = 0;
    if (_table.Walk.begin(ab.table)) |first| {
        var walk = first;
        while (walk.next()) |entry| {
            count += 1;
            exec.klog(sys, exec.LOG_DEBUG, "%s:   block %d.%d %d.%d.%d, %d addresses: %x %x %x %x\n", .{
                RESOURCE_NAME,
                entry.id,
                entry.instance,
                @as(u32, entry.major),
                @as(u32, entry.minor),
                @as(u32, entry.revision),
                @as(u32, entry.count),
                entry.addresses[0],
                entry.addresses[1],
                entry.addresses[2],
                entry.addresses[3],
            });
        }
    }
    exec.kprintf(sys, "%s: %d blocks in the table\n", .{ RESOURCE_NAME, count });

    for (named) |kind| {
        var block: amdgpu.GPUBlock = .{};
        if (!gpu.FindGPUBlock(kind.id, 0, &block)) {
            exec.kprintf(sys, "%s:   no %s\n", .{ RESOURCE_NAME, kind.name });
            continue;
        }
        exec.kprintf(sys, "%s:   %s %d.%d.%d at %x %x %x\n", .{
            RESOURCE_NAME,
            kind.name,
            @as(u32, block.major),
            @as(u32, block.minor),
            @as(u32, block.revision),
            block.addresses[0],
            block.addresses[1],
            block.addresses[2],
        });
    }

    var block: amdgpu.GPUBlock = .{};
    if (gpu.FindGPUBlock(amdgpu.GPUBLOCK_MEMORY_HUB, 0, &block)) _memory.tell(ab, block);
    if (gpu.FindGPUBlock(amdgpu.GPUBLOCK_SECURITY, 0, &block)) _security.tell(ab, block);
    if (gpu.FindGPUBlock(amdgpu.GPUBLOCK_POWER, 0, &block)) _power.tell(ab, block);
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(AMDGPUBase),
    .vectors = &amdgpu_lvo.vectors,
    .vector_count = amdgpu_lvo.vectors.len,
    .init = &init,
};

/// Cold start at 45: after pci.library (49), which places and lists the
/// device's function, and before every driver of a part of the device -
/// the display driver among them (23).
pub export const amdgpu_resource_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &amdgpu_resource_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = RESOURCE_VERSION,
    .type = .resource,
    .pri = 45,
    .name = RESOURCE_NAME,
    .id_string = RESOURCE_VERSION_STRING[1..],
    .init = &init_table,
};
