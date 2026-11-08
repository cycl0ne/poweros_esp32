// SPDX-License-Identifier: MPL-2.0
//! The memory hub: what the video, display and security blocks' memory
//! traffic goes through, and so what decides which addresses they can
//! reach.
//!
//! The device's own memory - the part of the machine's set aside for it -
//! has two addresses: where it is in the machine (`FB_OFFSET`, counted in
//! 16 MiB) and where it is in the device's own addresses
//! (`FB_LOCATION_BASE` and `_TOP`, the same units). The machine's
//! firmware sets both. Beside them are the apertures a block's address
//! may fall in without a page table - the system aperture, and in it the
//! one onto the machine's memory - and the default page a stray address
//! lands on; then the page-table machinery, its first context and the
//! last fault it took.
//!
//! What is read here is all of that as the machine's firmware left it.
//! The lit screen proves none of it: the display engine keeps copies of
//! its own. Nothing here is written: with the hub's system access mode
//! as the firmware leaves it - physical addresses alone, no page table -
//! an address in the device's memory is that memory to every block, which
//! is what AllocGPUMemory's pieces are reached by.
//!
//! **What the CPU sees of it.** The machine's map has the device's memory
//! uncached, since it lies past the memory the firmware lists, and the
//! device does not look into the CPU's caches. The part that is handed
//! out is made write-combining as it is taken (platform.resource's
//! SetMemoryType): writes are gathered into bursts and a fence sends them
//! on, and a driver reads it back by streaming loads, a line at a time -
//! a 1024 x 600 picture's samples, 912 KiB, read word by word took 15 ms
//! on a Radeon 780M, by streaming loads 0.2 ms. Nothing of it is cached, so nothing has to be dropped
//! around a block's use of it. Where the machine's map cannot mark it, it
//! stays uncached, which is slower and as correct.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const reg = sdk.hardware.mmio.reg;
const AMDGPUBase = @import("../amdgpu_base.zig").AMDGPUBase;
const _arena = @import("_arena.zig");

/// Its registers, counted in 32-bit words from its second address, as
/// the version this reads has them (3.0.1); another version numbers them
/// otherwise, and is said so of instead.
const segment = 1;
const known = .{ .major = 3, .minor = 0, .revision = 1 };
const fb_location_base = 0x8ec;
const fb_location_top = 0x8ed;
const fb_offset = 0x8d7;
const agp_top = 0x8ee;
const agp_bottom = 0x8ef;
const agp_base = 0x8f0;
const aperture_low = 0x8f1;
const aperture_high = 0x8f2;
const aperture_default_low = 0x8d8;
const aperture_default_high = 0x8d9;
const tlb_control = 0x8f3;
const top_of_dram = 0x8d4;
const aperture_control = 0x8e1;
const l2_control = 0x700;
const fault_control = 0x708;
const fault_status = 0x70c;
const context0_control = 0x740;

/// The units the hub counts its addresses in: the device's memory and
/// the machine's in 16 MiB, the system aperture in 256 KiB, the default
/// page in 4 KiB.
const memory_shift = 24;
const aperture_shift = 18;
const page_shift = 12;
const field_24 = 0xff_ffff;
const field_30 = 0x3fff_ffff;

fn isKnown(hub: amdgpu.GPUBlock) bool {
    return hub.major == known.major and hub.minor == known.minor and hub.revision == known.revision;
}

fn word(base: usize, offset: u32) u32 {
    return reg(base + offset * 4).*;
}

/// Where the device's memory is, as the hub places it, kept in the base
/// with the part of it that is handed out; nothing where the hub is one
/// whose registers are not known.
pub fn take(ab: *AMDGPUBase, hub: amdgpu.GPUBlock) void {
    if (!isKnown(hub) or hub.count <= segment) return;
    const at = @as(usize, @intCast(ab.info.registers)) + @as(usize, hub.addresses[segment]) * 4;
    const base = @as(u64, word(at, fb_location_base) & field_24) << memory_shift;
    const top = @as(u64, word(at, fb_location_top) & field_24) << memory_shift;
    if (top < base) return;
    ab.memory_device = base;
    ab.memory_machine = @as(u64, word(at, fb_offset) & field_24) << memory_shift;
    ab.memory_bytes = top - base + (@as(u64, 1) << memory_shift);
    ab.arena = _arena.of(ab.memory_bytes);
    ab.memory_gathered = gather(ab);
}

/// The part that is handed out made write-combining to the CPU: true when
/// it is.
fn gather(ab: *AMDGPUBase) bool {
    if (ab.arena.end == 0) return false;
    const sys = ab.sys_base;
    const pb: *sdk.interface.platform.PlatformBase = @ptrCast(@alignCast(sys.OpenResource(sdk.resources.platform.PLATFORMNAME) orelse return false));
    const start = ab.memory_machine + ab.arena.start;
    return pb.SetMemoryType(@intCast(start), @intCast(ab.arena.end - ab.arena.start), sdk.resources.platform.MEMTYPE_GATHERED);
}

/// The hub's state as the firmware left it, said.
pub fn tell(ab: *AMDGPUBase, hub: amdgpu.GPUBlock) void {
    const sys = ab.sys_base;
    const owner = sdk.resources.amdgpu.AMDGPUNAME;
    if (!isKnown(hub)) {
        exec.kprintf(sys, "%s: the memory hub is %d.%d.%d, whose registers this does not know\n", .{
            owner, @as(u32, hub.major), @as(u32, hub.minor), @as(u32, hub.revision),
        });
        return;
    }
    if (hub.count <= segment) return;
    const at = @as(usize, @intCast(ab.info.registers)) + @as(usize, hub.addresses[segment]) * 4;
    const read = word;

    const base = @as(u64, read(at, fb_location_base) & field_24) << memory_shift;
    const top = @as(u64, read(at, fb_location_top) & field_24) << memory_shift;
    const machine = @as(u64, read(at, fb_offset) & field_24) << memory_shift;
    exec.kprintf(sys, "%s: the device's memory is 0x%lx-0x%lx to it, 0x%lx in the machine\n", .{
        owner, base, top | ((@as(u64, 1) << memory_shift) - 1), machine,
    });
    exec.kprintf(sys, "%s:   onto the machine's memory 0x%lx-0x%lx from 0x%lx, system aperture 0x%lx-0x%lx, default page 0x%lx\n", .{
        owner,
        @as(u64, read(at, agp_bottom) & field_24) << memory_shift,
        @as(u64, read(at, agp_top) & field_24) << memory_shift,
        @as(u64, read(at, agp_base) & field_24) << memory_shift,
        @as(u64, read(at, aperture_low) & field_30) << aperture_shift,
        @as(u64, read(at, aperture_high) & field_30) << aperture_shift,
        (@as(u64, read(at, aperture_default_high) & 0xf) << 32 | read(at, aperture_default_low)) << page_shift,
    });
    exec.kprintf(sys, "%s:   tlb %x, l2 %x, context 0 %x, faults %x (status %x), top of memory %x, apertures %x\n", .{
        owner,
        read(at, tlb_control),
        read(at, l2_control),
        read(at, context0_control),
        read(at, fault_control),
        read(at, fault_status),
        read(at, top_of_dram),
        read(at, aperture_control),
    });
    if (ab.arena.end != 0) {
        exec.kprintf(sys, "%s:   handed out: 0x%lx-0x%lx of it, %s\n", .{
            owner,
            ab.memory_device + ab.arena.start,
            ab.memory_device + ab.arena.end - 1,
            @as([*:0]const u8, if (ab.memory_gathered) "written gathered" else "uncached: the map would not gather it"),
        });
    }
}
