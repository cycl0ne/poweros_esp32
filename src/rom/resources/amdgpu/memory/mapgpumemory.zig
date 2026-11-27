// SPDX-License-Identifier: MPL-2.0
//! MapGPUMemory: a range of the machine's memory mapped into the graphics
//! block's memory hub, so that its engines reach it where it is - or a
//! range of the device's own memory answered with its address to them.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _arena = @import("_arena.zig");
const _memory = @import("_memory.zig");
const _graphics = @import("../graphics/_graphics.zig");

/// A range of the machine's memory mapped for the graphics block's
/// engines: its pages written into the block's memory hub's page table,
/// and where the engines reach it answered - or, for the device's own
/// memory, where they reach it through the hub's aperture.
///
/// SYNOPSIS:
/// ```zig
/// fn MapGPUMemory(ab: *AMDGPUBase, address: *anyopaque, bytes: u32, flags: u32, memory: *amdgpu.GPUMemory) bool
/// ```
///
/// SINCE: 1.11, `flags` 1.23. LVO -68.
///
/// INPUTS:
/// - `address` - the range's first byte, as the CPU reaches it: any
///   memory of the machine's, at any byte, or of the device's own - where
///   the machine has it, as AllocGPUMemory answers it, or in the device's
///   memory window.
/// - `bytes` - how long it is; more than 0.
/// - `flags` - 0, or GPUMAP_CACHED: a range of the machine's memory
///   cached in the graphics block's second level.
/// - `memory` - where to say where it is.
///
/// RESULT:
/// True with `memory` filled in: `cpu` the address given, `device` where
/// the graphics block's engines reach the same byte, `bytes` its length.
/// False, `memory` untouched, where StartGPUGraphics has not turned the
/// hub on, `bytes` is 0, `flags` holds a bit not named here, the range
/// lies partly in the device's own memory and partly not, in the device's
/// own memory with GPUMAP_CACHED, or in the memory window where the
/// device's host data path cannot be flushed, the hub's page table has no
/// room left for the range - it maps 512 MiB, in at most 64 ranges at a
/// time - or the hub does not take its new entries; and on a machine
/// without the device.
///
/// BEHAVIOR:
/// A range wholly in the device's own memory (since 1.15) - where the
/// machine has it, or in the memory window, which shows its first
/// `window_bytes` - takes no entry: `device` is its place in that memory
/// to the engines (GPUInfo's `memory_start` and on), which the hub's
/// aperture sends them to, uncached in the block. The CPU's reads and
/// writes in the window pass the device's host data path, which holds
/// writes back: for a range there the CPU's gathered writes are fenced
/// and the path is flushed, its flush posted by a read of the bus block
/// (amdgpu_hdp_generic_flush). Any other range is handed to CachePreDMA,
/// which says where a device sees it.
/// Each page of 4 KiB it lies in, the first and the last whole, gets an
/// entry in the table, one after another in the first run of free
/// entries that holds them all, as the vendor's driver maps a page into
/// its GART: valid, in the machine's memory, snooped, readable, writable
/// and executable, uncached in the block - or, with GPUMAP_CACHED, of the
/// memory type it maps a buffer of a program's with where nothing asks
/// otherwise, cached in the block's second level (gmc_v11_0_get_vm_pte:
/// MTYPE_NC). Then the hub's TLB is dropped for its first context. The
/// answer's `device` is the run's start, plus the range's place in its
/// first page.
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
/// by hand around a job. The device's own memory it does not snoop, and
/// the CPU reaches that gathered or uncached - the pieces AllocGPUMemory
/// hands out are written gathered - so what the CPU wrote there is the
/// engines' once the writes are fenced, which sending a job does; what it
/// wrote in the window, once the range is mapped, which flushes the path
/// its writes take. What the engines write in the device's memory the CPU
/// reads at once either way.
///
/// A range mapped GPUMAP_CACHED goes through the block's second-level
/// cache. What a compute job writes there is written back as the job
/// ends, and is the CPU's once it is done; what the CPU writes there is
/// the compute engine's from the next job sent to it, whose start writes
/// the cache back and drops it. The DMA engine writes past the cache,
/// but its reads may be answered from lines the cache still holds, which
/// nothing drops before its jobs: a range it reads is mapped without
/// GPUMAP_CACHED. A job given up by a reset may leave what it wrote in
/// the cache, to be written back at any time after, over what the CPU
/// wrote since: such a range is neither written by the CPU nor given
/// away until a job sent after the reset is done.
///
/// NOTES:
/// Only the graphics block's engines reach a mapping - its DMA engine's
/// packets name it by `device`. The display and the video decoder read
/// through the other hub, and reach the device's own memory only.
/// Uncached, each read and each write of an engine's is one of the
/// memory's; GPUMAP_CACHED is for what a kernel reads and writes in small
/// pieces, many to a line.
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
/// if (!ab.MapGPUMemory(buffer.ptr, @intCast(buffer.len), 0, &mapped)) return error.NoMapping;
/// defer ab.UnmapGPUMemory(&mapped);
/// // a job's packets name the buffer by mapped.device
/// ```
pub fn MapGPUMemory(ab: *AMDGPUBase, address: *anyopaque, bytes: u32, flags: u32, memory: *amdgpu.GPUMemory) bool {
    if (ab.device == null or !ab.graphics_started or bytes == 0 or flags & ~amdgpu.GPUMAP_CACHED != 0) return false;
    const cached = flags & amdgpu.GPUMAP_CACHED != 0;
    switch (ownPlace(ab, @intFromPtr(address), bytes)) {
        .apart => {},
        .across => return false,
        .machine => |device| {
            if (cached) return false;
            memory.* = .{ .cpu = @intFromPtr(address), .device = device, .bytes = bytes };
            return true;
        },
        .window => |device| {
            if (cached or !_memory.flushHostPath(ab)) return false;
            memory.* = .{ .cpu = @intFromPtr(address), .device = device, .bytes = bytes };
            return true;
        },
    }
    const sys = ab.sys_base;
    var length = bytes;
    const machine: u64 = @intFromPtr(sys.CachePreDMA(address, &length, exec.DMAF_ReadFromRAM));
    if (length < bytes) return false;
    const pages = _graphics.pagesOf(machine, bytes);
    sys.ObtainSemaphore(&ab.gart_lock);
    defer sys.ReleaseSemaphore(&ab.gart_lock);
    const offset = _arena.place(&ab.gart_arena, pages.count * _graphics.page_bytes, @intCast(_graphics.page_bytes)) orelse return false;
    const index = offset / _graphics.page_bytes;
    _graphics.writeEntries(ab, index, pages.count, pages.first, cached);
    if (!_graphics.dropTlb(ab)) {
        _graphics.writeEntries(ab, index, pages.count, null, false);
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

/// Where a range lies against the device's own memory: apart from it,
/// across an edge of it, or in it - where the machine has it or in the
/// memory window - at that address to the device.
const OwnPlace = union(enum) { apart, across, machine: u64, window: u64 };

/// `bytes` from `address`, as the CPU reaches them, against the device's
/// own memory where the machine has it and in its memory window, which
/// shows its first `window_bytes`.
fn ownPlace(ab: *const AMDGPUBase, address: u64, bytes: u32) OwnPlace {
    const end = address + bytes;
    const machine_end = ab.memory_machine + ab.memory_bytes;
    const window_end = ab.info.window + @min(ab.info.window_bytes, ab.memory_bytes);
    if (ab.memory_bytes == 0) return .apart;
    if (end > ab.memory_machine and address < machine_end) {
        if (address < ab.memory_machine or end > machine_end) return .across;
        return .{ .machine = ab.memory_device + (address - ab.memory_machine) };
    }
    if (end > ab.info.window and address < window_end) {
        if (address < ab.info.window or end > window_end) return .across;
        return .{ .window = ab.memory_device + (address - ab.info.window) };
    }
    return .apart;
}
