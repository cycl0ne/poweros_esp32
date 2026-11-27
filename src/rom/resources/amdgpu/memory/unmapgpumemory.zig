// SPDX-License-Identifier: MPL-2.0
//! UnmapGPUMemory: a range of the machine's memory taken out of the
//! graphics block's memory hub again.

const sdk = @import("sdk");
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _arena = @import("_arena.zig");
const _graphics = @import("../graphics/_graphics.zig");

/// A range MapGPUMemory mapped taken out of the hub's page table again.
///
/// SYNOPSIS:
/// ```zig
/// fn UnmapGPUMemory(ab: *AMDGPUBase, memory: *amdgpu.GPUMemory) void
/// ```
///
/// SINCE: 1.11. LVO -72.
///
/// INPUTS:
/// - `memory` - a mapping from MapGPUMemory, or one all zero.
///
/// RESULT:
/// None. `memory` is all zero after.
///
/// BEHAVIOR:
/// The range's entries are written 0, which is not valid, as the vendor's
/// driver takes a page out of its GART, the hub's TLB is dropped for its
/// first context, and the entries are free for the next MapGPUMemory. An
/// engine that reaches the range after is sent to the hub's scratch page
/// and does not reach the memory. A zero piece, a range of the device's
/// own memory - which took no entry - one not in the hub's range or one
/// it does not hold mapped is cleared and nothing else.
///
/// CONTEXT:
/// - Waits: for another task mapping or unmapping, and for the hub's
///   acknowledgement, some microseconds.
/// - Interrupts: no.
/// - Locks: takes the mappings' lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The memory is the caller's alone again, to free or to keep.
///
/// NOTES:
/// Every job that names the range must be done first (WaitGPUDMA): one
/// still running when it is taken out reads the scratch page and writes
/// nowhere.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `MapGPUMemory`, `FreeGPUMemory`, `WaitGPUDMA`
///
/// EXAMPLES:
/// ```zig
/// if (!ab.WaitGPUDMA(job, 1000)) return error.Late;
/// ab.UnmapGPUMemory(&mapped);
/// ```
pub fn UnmapGPUMemory(ab: *AMDGPUBase, memory: *amdgpu.GPUMemory) void {
    defer memory.* = .{};
    if (ab.device == null or memory.bytes == 0 or ab.gart_bytes == 0) return;
    if (memory.device < ab.gart_start or memory.device - ab.gart_start >= ab.gart_bytes) return;
    const sys = ab.sys_base;
    const pages = _graphics.pagesOf(memory.device - ab.gart_start, memory.bytes);
    sys.ObtainSemaphore(&ab.gart_lock);
    defer sys.ReleaseSemaphore(&ab.gart_lock);
    if (!_arena.remove(&ab.gart_arena, pages.first)) return;
    _graphics.writeEntries(ab, pages.first / _graphics.page_bytes, pages.count, null);
    _ = _graphics.dropTlb(ab);
}
