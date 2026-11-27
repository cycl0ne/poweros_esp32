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
//! a block's firmware into the protected region it runs from -
//! StartGPUGraphics the graphics block's whole set, which the block's
//! RLC then hands its engines, and turns on the block's memory hub
//! (`graphics/_graphics.zig`). The block's DMA engine runs one queue of
//! jobs for every driver (`dma/_dma.zig`): StartGPUDMA starts it,
//! SendGPUDMA puts a job of its packets on it, WaitGPUDMA waits for one
//! to be done, GetGPUDMAState says how far it is. MapGPUMemory maps a
//! range of the machine's memory into the hub's page table, so that the
//! engines reach a buffer where it is, and UnmapGPUMemory takes it out.
//! The block's compute engine runs one queue of jobs too, mapped by the
//! block's scheduler (`compute/_compute.zig`): StartGPUCompute starts the
//! scheduler and the queue, SendGPUCompute puts a job of its packets on
//! it, SendGPUKernel a kernel's dispatch, WaitGPUCompute waits for one,
//! GetGPUComputeState says how far it is. LoadGPUCode places a code
//! object for the engine in the device's memory (`code/_code.zig`),
//! FindGPUKernel finds a kernel in it by its name, and FreeGPUCode gives
//! the memory back.
//!
//! The device's video BIOS image - the copy the machine's firmware keeps
//! in its tables (`device/_bios.zig`) - is the resource's to find too,
//! since every block's driver reads its tables out of it: GetGPUBios
//! hands it out, and the display's connectors, read from its display
//! object table (`device/_connectors.zig`), are answered by
//! GetGPUConnector.
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
    _ = @import("security/startgpugraphics.zig");
    _ = @import("graphics/_graphics.zig");
    _ = @import("graphics/_clearstate.zig");
    _ = @import("dma/_dma.zig");
    _ = @import("dma/startgpudma.zig");
    _ = @import("dma/sendgpudma.zig");
    _ = @import("dma/waitgpudma.zig");
    _ = @import("dma/getgpudmastate.zig");
    _ = @import("memory/mapgpumemory.zig");
    _ = @import("memory/unmapgpumemory.zig");
    _ = @import("compute/_compute.zig");
    _ = @import("compute/startgpucompute.zig");
    _ = @import("compute/sendgpucompute.zig");
    _ = @import("compute/sendgpukernel.zig");
    _ = @import("compute/waitgpucompute.zig");
    _ = @import("compute/getgpucomputestate.zig");
    _ = @import("compute/resetgpucompute.zig");
    _ = @import("code/_code.zig");
    _ = @import("code/loadgpucode.zig");
    _ = @import("code/findgpukernel.zig");
    _ = @import("code/freegpucode.zig");
    _ = @import("device/_bios.zig");
    _ = @import("device/getgpubios.zig");
    _ = @import("device/_connectors.zig");
    _ = @import("device/getgpuconnector.zig");
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
    try testing.expect(!call(ab).SetGPUPower(amdgpu.GPUPOWER_GRAPHICS, 0, true));
    try testing.expectEqual(@as(u32, 0), call(ab).GetGPUClock(amdgpu.GPUCLOCK_GRAPHICS));
    try testing.expectEqual(@as(u32, 0), call(ab).GetGPUClock(amdgpu.GPUCLOCK_FABRIC));
    try testing.expectEqual(@as(u32, 0), call(ab).ResetGPUCompute(1, 0));
    try testing.expectEqual(@as(u32, 0), call(ab).ResetGPUCompute(1, amdgpu.GPURESET_PIPE));
    var memory: amdgpu.GPUMemory = .{ .bytes = 7 };
    try testing.expect(!call(ab).AllocGPUMemory(4096, 4096, &memory));
    try testing.expectEqual(@as(u32, 7), memory.bytes);
    const file = [_]u8{0} ** 64;
    try testing.expect(!call(ab).StartGPUSecurity(&file, file.len));
    var address: u64 = 7;
    try testing.expect(!call(ab).LoadGPUFirmware(amdgpu.GPUFIRMWARE_VIDEO, &file, file.len, &address));
    try testing.expect(!call(ab).LoadGPUFirmware(amdgpu.GPUFIRMWARE_VIDEO_REGISTERS, &file, file.len, &address));
    try testing.expectEqual(@as(u64, 7), address);
    var server: exec.Interrupt = .{};
    try testing.expect(!call(ab).AddGPUIntServer(amdgpu.GPUINT_CLIENT_DISPLAY, amdgpu.GPUINT_DISPLAY_UPDATE, &server));
    var bios: amdgpu.GPUBios = .{ .bytes = 7 };
    try testing.expect(!call(ab).GetGPUBios(&bios));
    try testing.expectEqual(@as(u32, 7), bios.bytes);
    var connector: amdgpu.GPUConnector = .{ .number = 7 };
    try testing.expect(!call(ab).GetGPUConnector(0, &connector));
    try testing.expectEqual(@as(u32, 7), connector.number);
    const graphics: amdgpu.GPUGraphicsFiles = .{ .pfp = .{ .image = &file, .bytes = file.len } };
    try testing.expect(!call(ab).StartGPUGraphics(&graphics));
    try testing.expect(!call(ab).StartGPUDMA());
    const nop = [_]u32{amdgpu.GPUDMA_OP_NOP};
    try testing.expectEqual(@as(u32, 0), call(ab).SendGPUDMA(&nop, nop.len));
    try testing.expect(!call(ab).WaitGPUDMA(1, 0));
    var state: amdgpu.GPUDMAState = .{ .sent = 7 };
    try testing.expect(!call(ab).GetGPUDMAState(&state));
    try testing.expectEqual(@as(u32, 7), state.sent);
    var buffer: [64]u8 = @splat(0);
    var mapped: amdgpu.GPUMemory = .{ .bytes = 7 };
    try testing.expect(!call(ab).MapGPUMemory(&buffer, buffer.len, &mapped));
    try testing.expectEqual(@as(u32, 7), mapped.bytes);
    call(ab).UnmapGPUMemory(&mapped);
    try testing.expectEqual(@as(u32, 0), mapped.bytes);
    call(ab).RemGPUIntServer(&server);
    try testing.expect(!ab.ih_running);
    try tearDown(ab);
}

test "the device's memory as the hub places it is said by GetGPUInfo, to the device and in the machine" {
    const ab = try setUp();
    defer kexec.deinit();

    // The hub's registers as the machine's firmware leaves them on the
    // NucBox: 512 MiB at 0x8000000000 to the device, at 0x840000000 in
    // the machine, each counted in 16 MiB.
    var device: sdk.pci.PCIDevice = .{};
    ab.device = &device;
    var registers = [_]u32{0} ** 0x900;
    registers[0x8ec] = 0x8000;
    registers[0x8ed] = 0x801f;
    registers[0x8d7] = 0x840;
    ab.info.registers = @intFromPtr(&registers);
    var hub: amdgpu.GPUBlock = .{ .major = 3, .minor = 0, .revision = 1, .count = 2 };
    hub.addresses[1] = 0;
    @import("memory/_memory.zig").take(ab, hub);
    var info: amdgpu.GPUInfo = .{};
    try testing.expect(call(ab).GetGPUInfo(&info));
    try testing.expectEqual(@as(u64, 0x80_0000_0000), info.memory_start);
    try testing.expectEqual(@as(u64, 0x8_4000_0000), info.memory_machine);
    try testing.expectEqual(@as(u64, 512 * 1024 * 1024), ab.memory_bytes);

    // A hub of another version says nothing of it.
    ab.info = .{};
    hub.minor = 1;
    @import("memory/_memory.zig").take(ab, hub);
    try testing.expect(call(ab).GetGPUInfo(&info));
    try testing.expectEqual(@as(u64, 0), info.memory_machine);
    ab.device = null;
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

    // With the hub on, a range of a piece is answered with its place to
    // the device and takes no entry in the table - where the machine has
    // it, and in the memory window, which shows the first 256 MiB and
    // whose host data path is flushed for it. A range across an edge of
    // either is refused, and one in the window where the path cannot be
    // flushed.
    ab.graphics_started = true;
    ab.info.window = 0x7c_0000_0000;
    ab.info.window_bytes = 256 * mib;
    var bus_words = [_]u32{ 7, 9 };
    ab.host_flush = @intFromPtr(&bus_words[0]);
    ab.host_posted = @intFromPtr(&bus_words[1]);
    var mapped: amdgpu.GPUMemory = .{};
    try testing.expect(call(ab).MapGPUMemory(@ptrFromInt(@as(usize, @intCast(ring.cpu)) + 16), 64, &mapped));
    try testing.expectEqual(ring.device + 16, mapped.device);
    try testing.expectEqual(@as(u32, 64), mapped.bytes);
    try testing.expectEqual(@as(u32, 7), bus_words[0]);
    call(ab).UnmapGPUMemory(&mapped);
    try testing.expectEqual(@as(u32, 0), mapped.bytes);
    try testing.expect(call(ab).MapGPUMemory(@ptrFromInt(0x7c_0000_0000 + 64 * mib), 4096, &mapped));
    try testing.expectEqual(@as(u64, 0x80_0000_0000 + 64 * mib), mapped.device);
    try testing.expectEqual(@as(u32, 0), bus_words[0]);
    call(ab).UnmapGPUMemory(&mapped);
    try testing.expect(!call(ab).MapGPUMemory(@ptrFromInt(0x7c_0000_0000 + 256 * mib - 64), 128, &mapped));
    try testing.expect(!call(ab).MapGPUMemory(@ptrFromInt(0x8_4000_0000 - 64), 128, &mapped));
    try testing.expect(!call(ab).MapGPUMemory(@ptrFromInt(0x8_4000_0000 + 512 * mib - 64), 128, &mapped));
    ab.host_flush = 0;
    try testing.expect(!call(ab).MapGPUMemory(@ptrFromInt(0x7c_0000_0000), 64, &mapped));
    try testing.expectEqual(@as(u32, 0), mapped.bytes);
    try testing.expectEqual(@as(u32, 0), ab.gart_arena.count);
    ab.graphics_started = false;
    ab.host_posted = 0;
    ab.info = .{};

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

test "a decoder powered down before SetGPUPower has powered it up is left as it is" {
    const ab = try setUp();
    defer kexec.deinit();

    // As the resource holds a device whose power manager's messages are
    // known, the manager's last message answered.
    var device: sdk.pci.PCIDevice = .{};
    ab.device = &device;
    var registers = [_]u32{0} ** 0x300;
    registers[0x282] = 0xffff;
    registers[0x29a] = 1;
    ab.info.registers = @intFromPtr(&registers);
    var manager: amdgpu.GPUBlock = .{ .major = 13, .minor = 0, .revision = 4, .count = 2 };
    manager.addresses[1] = 0;
    @import("power/_power.zig").take(ab, manager);
    try testing.expect(ab.power_known);

    // Nothing is sent, and the call says done.
    try testing.expect(call(ab).SetGPUPower(amdgpu.GPUPOWER_JPEG, 0, false));
    try testing.expectEqual(@as(u32, 0xffff), registers[0x282]);
    try testing.expectEqual(@as(u32, 1), registers[0x29a]);
    try testing.expectEqual(@as(u32, 0), ab.powered_decoders);
    // A video decoder the device does not have is no decoder at all.
    try testing.expect(!call(ab).SetGPUPower(amdgpu.GPUPOWER_VIDEO, 31, false));

    ab.power_known = false;
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
