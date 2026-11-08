// SPDX-License-Identifier: MPL-2.0
//! FreeGPUMemory: a piece of the device's memory given back.

const sdk = @import("sdk");
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _arena = @import("_arena.zig");

/// A piece of the device's memory given back.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeGPUMemory(ab: *AMDGPUBase, memory: *GPUMemory) void
/// ```
///
/// SINCE: 1.1. LVO -20.
///
/// INPUTS:
/// - `memory` - a piece from AllocGPUMemory, or one all zero.
///
/// RESULT:
/// None. `memory` is all zero after.
///
/// BEHAVIOR:
/// The piece's place is free for the next AllocGPUMemory. A zero piece,
/// or one the resource did not hand out, is cleared and nothing else.
///
/// CONTEXT:
/// - Waits: for another task handing out or giving back.
/// - Interrupts: no.
/// - Locks: takes the resource's memory lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The piece is the resource's again; no block of the device may still
/// be reading or writing it.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocGPUMemory`
///
/// EXAMPLES:
/// ```zig
/// ab.FreeGPUMemory(&ring);
/// ```
pub fn FreeGPUMemory(ab: *AMDGPUBase, memory: *amdgpu.GPUMemory) void {
    defer memory.* = .{};
    if (memory.bytes == 0 or memory.device < ab.memory_device) return;
    const sys = ab.sys_base;
    sys.ObtainSemaphore(&ab.arena_lock);
    defer sys.ReleaseSemaphore(&ab.arena_lock);
    _ = _arena.remove(&ab.arena, memory.device - ab.memory_device);
}
