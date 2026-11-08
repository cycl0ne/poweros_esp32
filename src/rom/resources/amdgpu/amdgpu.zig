// SPDX-License-Identifier: MPL-2.0
//! amdgpu.resource: the machine's AMD graphics device, held for every
//! driver that uses a part of it.
//!
//! The device is one function on PCI with several machines behind it,
//! and pci.library gives a function to one driver, so the resource is
//! that driver: it claims the function, reads the table of blocks the
//! device's firmware left (`table/_table.zig`), and answers each part's
//! driver with where that part's registers are. The parts that carry
//! state of their own and that more than one driver needs - the power
//! manager's mailbox (`power/_power.zig`), the security processor's ring
//! (`security/_security.zig`), the memory hub (`memory/_memory.zig`) -
//! are the resource's to drive: SetGPUPower sends the manager its
//! messages, AllocGPUMemory hands out the device's own memory
//! (`memory/_arena.zig`) for the blocks to read and write, and
//! StartGPUSecurity and LoadGPUFirmware have the security processor put
//! a block's firmware into the protected region it runs from.
//!
//! The device is found and read as the resource starts
//! (`device/_device.zig`), and what it says of itself goes on the boot's
//! lines. Each call is a file of its own, under the folder of its area. The jump table
//! is amdgpu_lvo.zig, the ROM tag and init amdgpu_init.zig, the base
//! amdgpu_base.zig. This file holds the names the rest of the kernel
//! reaches the resource by, and the tests of it working as a whole - on
//! the host, without the device.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const amdgpu_base = @import("amdgpu_base.zig");
const amdgpu_init = @import("amdgpu_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from amdgpu.resource.
comptime {
    _ = &amdgpu_init.amdgpu_resource_tag;
}

/// The resource's base.
pub const AMDGPUBase = amdgpu_base.AMDGPUBase;
/// What the resource is on exec's list as.
pub const RESOURCE_NAME = amdgpu_init.RESOURCE_NAME;
/// The ROM tag, for the host tests that make the resource from it.
pub const amdgpu_resource_tag = amdgpu_init.amdgpu_resource_tag;

// --- tests ------------------------------------------------------------------------

const testing = std.testing;
const kexec = @import("../../libs/exec/exec.zig");
const _table = @import("table/_table.zig");

test {
    _ = @import("amdgpu_lvo.zig");
    _ = @import("device/_device.zig");
    _ = @import("device/getgpuinfo.zig");
    _ = @import("device/findgpublock.zig");
    _ = _table;
    _ = @import("memory/_memory.zig");
    _ = @import("security/_security.zig");
    _ = @import("power/_power.zig");
    _ = @import("power/setgpupower.zig");
    _ = @import("memory/_arena.zig");
    _ = @import("memory/allocgpumemory.zig");
    _ = @import("memory/freegpumemory.zig");
    _ = @import("security/startgpusecurity.zig");
    _ = @import("security/loadgpufirmware.zig");
}

fn setUp() !*AMDGPUBase {
    try kexec.setUp();
    const made = kexec.InitResident(kexec.SysBase, &amdgpu_resource_tag, null) orelse return error.NoResource;
    return @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
}

fn tearDown(ab: *AMDGPUBase) !void {
    kexec.RemResource(kexec.SysBase, @ptrCast(&ab.lib));
    kexec.freeLibraryMemory(kexec.SysBase, &ab.lib);
    try kexec.expectNoLeaks();
}

/// The resource as a program calls it, through its jump table.
fn call(ab: *AMDGPUBase) *sdk.interface.amdgpu.AMDGPUBase {
    return @ptrCast(ab);
}

test "a machine without the device has the resource, and it answers false" {
    const ab = try setUp();
    defer kexec.deinit();

    // The host has no pci.library, so no device was found.
    try testing.expect(ab.device == null);
    var info: amdgpu.GPUInfo = .{ .vendor = 7 };
    try testing.expect(!call(ab).GetGPUInfo(&info));
    try testing.expectEqual(@as(u32, 7), info.vendor);
    var block: amdgpu.GPUBlock = .{};
    try testing.expect(!call(ab).FindGPUBlock(amdgpu.GPUBLOCK_DISPLAY, 0, &block));
    try testing.expect(!call(ab).SetGPUPower(amdgpu.GPUPOWER_JPEG, 0, true));
    var memory: amdgpu.GPUMemory = .{ .bytes = 7 };
    try testing.expect(!call(ab).AllocGPUMemory(4096, 4096, &memory));
    try testing.expectEqual(@as(u32, 7), memory.bytes);
    const file = [_]u8{0} ** 64;
    try testing.expect(!call(ab).StartGPUSecurity(&file, file.len));
    var address: u64 = 7;
    try testing.expect(!call(ab).LoadGPUFirmware(amdgpu.GPUFIRMWARE_VIDEO, &file, file.len, &address));
    try testing.expect(!call(ab).LoadGPUFirmware(amdgpu.GPUFIRMWARE_VIDEO_REGISTERS, &file, file.len, &address));
    try testing.expectEqual(@as(u64, 7), address);
    try tearDown(ab);
}

test "the device's memory is handed out in pieces each address of which says the same place" {
    const ab = try setUp();
    defer kexec.deinit();

    // As the resource holds a device whose hub placed 512 MiB at
    // 0x8000000000 to it and 0x840000000 in the machine.
    const mib = 1024 * 1024;
    var device: sdk.pci.PCIDevice = .{};
    ab.device = &device;
    ab.memory_device = 0x80_0000_0000;
    ab.memory_machine = 0x8_4000_0000;
    ab.memory_bytes = 512 * mib;
    ab.arena = @import("memory/_arena.zig").of(ab.memory_bytes);

    var ring: amdgpu.GPUMemory = .{};
    try testing.expect(call(ab).AllocGPUMemory(4096, 4096, &ring));
    try testing.expectEqual(@as(u64, 0x80_0000_0000 + 64 * mib), ring.device);
    try testing.expectEqual(@as(u64, 0x8_4000_0000 + 64 * mib), ring.cpu);
    try testing.expectEqual(@as(u32, 4096), ring.bytes);
    var picture: amdgpu.GPUMemory = .{};
    try testing.expect(call(ab).AllocGPUMemory(3 * mib, 2 * mib, &picture));
    try testing.expectEqual(@as(u64, 0), picture.device % (2 * mib));

    call(ab).FreeGPUMemory(&ring);
    try testing.expectEqual(@as(u32, 0), ring.bytes);
    var again: amdgpu.GPUMemory = .{};
    try testing.expect(call(ab).AllocGPUMemory(4096, 4096, &again));
    try testing.expectEqual(@as(u64, 0x80_0000_0000 + 64 * mib), again.device);
    call(ab).FreeGPUMemory(&again);
    call(ab).FreeGPUMemory(&picture);
    try testing.expectEqual(@as(u32, 0), ab.arena.count);

    // Without a power manager whose messages are known, nothing is sent;
    // nor to a security processor whose ring is not known.
    try testing.expect(!call(ab).SetGPUPower(amdgpu.GPUPOWER_JPEG, 0, true));
    const file = [_]u8{0} ** 64;
    try testing.expect(!call(ab).StartGPUSecurity(&file, file.len));

    ab.device = null;
    try tearDown(ab);
}

test "a device's blocks are answered out of its table" {
    const ab = try setUp();
    defer kexec.deinit();

    // As the resource holds a device it read: a function, what was read
    // of it, and its table.
    var room: [1024]u8 align(4) = undefined;
    _table.makeTable(&room, true);
    var device: sdk.pci.PCIDevice = .{};
    ab.device = &device;
    ab.info = .{ .vendor = 0x1002, .device = 0x15bf, .registers = 0x1000, .registers_bytes = 512 * 1024 };
    ab.table = @intFromPtr(&room);

    var info: amdgpu.GPUInfo = .{};
    try testing.expect(call(ab).GetGPUInfo(&info));
    try testing.expectEqual(@as(u32, 0x15bf), info.device);
    try testing.expectEqual(@as(u64, 512 * 1024), info.registers_bytes);

    var block: amdgpu.GPUBlock = .{};
    try testing.expect(call(ab).FindGPUBlock(amdgpu.GPUBLOCK_VIDEO, 0, &block));
    try testing.expectEqual(@as(u8, 4), block.major);
    try testing.expectEqual(@as(u32, 0x7E00), block.addresses[1]);
    try testing.expect(call(ab).FindGPUBlock(amdgpu.GPUBLOCK_VIDEO, 1, &block));
    try testing.expectEqual(@as(u32, 1), block.instance);
    try testing.expect(!call(ab).FindGPUBlock(amdgpu.GPUBLOCK_MEMORY_HUB, 0, &block));

    // What the test made is the test's: the resource is given back
    // holding nothing.
    ab.device = null;
    ab.table = 0;
    try tearDown(ab);
}
