// SPDX-License-Identifier: MPL-2.0
//! MapGPUMemory: a range of the machine's memory mapped into the graphics
//! block's memory hub, so that its engines reach it where it is.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _arena = @import("_arena.zig");
const _graphics = @import("../graphics/_graphics.zig");

/// A range of the machine's memory mapped for the graphics block's
/// engines: its pages written into the block's memory hub's page table,
/// and where the engines reach it answered.
///
/// SYNOPSIS:
/// ```zig
/// fn MapGPUMemory(ab: *AMDGPUBase, address: *anyopaque, bytes: u32, memory: *amdgpu.GPUMemory) bool
/// ```
///
/// SINCE: 1.11. LVO -68.
///
/// INPUTS:
/// - `address` - the range's first byte, as the CPU reaches it: any
///   memory of the machine's, at any byte.
/// - `bytes` - how long it is; more than 0.
/// - `memory` - where to say where it is.
///
/// RESULT:
/// True with `memory` filled in: `cpu` the address given, `device` where
/// the graphics block's engines reach the same byte, `bytes` its length.
/// False, `memory` untouched, where StartGPUGraphics has not turned the
/// hub on, `bytes` is 0, the hub's page table has no room left for the
/// range - it maps 512 MiB, in at most 64 ranges at a time - or the hub
/// does not take its new entries; and on a machine without the device.
///
/// BEHAVIOR:
/// The range is handed to CachePreDMA, which says where a device sees it.
/// Each page of 4 KiB it lies in, the first and the last whole, gets an
/// entry in the table, one after another in the first run of free
/// entries that holds them all, as the vendor's driver maps a page into
/// its GART: valid, in the machine's memory, snooped, readable, writable
/// and executable, uncached in the block. Then the hub's TLB is dropped
/// for its first context. The answer's `device` is the run's start, plus
/// the range's place in its first page.
///
/// CONTEXT:
/// - Waits: for another task mapping or unmapping, and for the hub's
///   acknowledgement, some microseconds.
/// - Interrupts: no.
/// - Locks: takes the mappings' lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The memory stays the caller's, and must stay where it is - not freed -
/// until UnmapGPUMemory has taken it out again. What the engines write
/// there is the CPU's to read at once, and what the CPU writes theirs:
/// the hub snoops the CPUs' caches, so nothing is written back or dropped
/// by hand around a job.
///
/// NOTES:
/// Only the graphics block's engines reach a mapping - its DMA engine's
/// packets name it by `device`. The display and the video decoder read
/// through the other hub, and reach the device's own memory only.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `UnmapGPUMemory`, `AllocGPUMemory`, `SendGPUDMA`, `CachePreDMA`
///
/// EXAMPLES:
/// ```zig
/// var mapped: amdgpu.GPUMemory = .{};
/// if (!ab.MapGPUMemory(buffer.ptr, @intCast(buffer.len), &mapped)) return error.NoMapping;
/// defer ab.UnmapGPUMemory(&mapped);
/// // a job's packets name the buffer by mapped.device
/// ```
pub fn MapGPUMemory(ab: *AMDGPUBase, address: *anyopaque, bytes: u32, memory: *amdgpu.GPUMemory) bool {
    if (ab.device == null or !ab.graphics_started or bytes == 0) return false;
    const sys = ab.sys_base;
    var length = bytes;
    const machine: u64 = @intFromPtr(sys.CachePreDMA(address, &length, exec.DMAF_ReadFromRAM));
    if (length < bytes) return false;
    const pages = _graphics.pagesOf(machine, bytes);
    sys.ObtainSemaphore(&ab.gart_lock);
    defer sys.ReleaseSemaphore(&ab.gart_lock);
    const offset = _arena.place(&ab.gart_arena, pages.count * _graphics.page_bytes, @intCast(_graphics.page_bytes)) orelse return false;
    const index = offset / _graphics.page_bytes;
    _graphics.writeEntries(ab, index, pages.count, pages.first);
    if (!_graphics.dropTlb(ab)) {
        _graphics.writeEntries(ab, index, pages.count, null);
        _ = _arena.remove(&ab.gart_arena, offset);
        return false;
    }
    memory.* = .{
        .cpu = @intFromPtr(address),
        .device = ab.gart_start + offset + (machine - pages.first),
        .bytes = bytes,
    };
    return true;
}
