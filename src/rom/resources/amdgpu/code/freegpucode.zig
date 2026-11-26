// SPDX-License-Identifier: MPL-2.0
//! FreeGPUCode: a loaded code object taken out of the device's memory.

const sdk = @import("sdk");
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;

/// A code object from LoadGPUCode taken out of the device's memory.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeGPUCode(ab: *AMDGPUBase, code: *amdgpu.GPUCode) void
/// ```
///
/// SINCE: 1.12. LVO -104.
///
/// INPUTS:
/// - `code` - the code object, as LoadGPUCode loaded it; one already
///   cleared is passed over.
///
/// RESULT:
/// None. `code` is cleared.
///
/// BEHAVIOR:
/// The piece of the device's memory the code object was placed in is
/// given back (FreeGPUMemory).
///
/// CONTEXT:
/// - Waits: only for the memory's lock.
/// - Interrupts: no.
/// - Locks: takes the memory lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The piece goes back to the device's memory; the image is the caller's
/// as it was.
///
/// NOTES:
/// A job still running one of its kernels must be waited for first
/// (WaitGPUCompute): the engine would run on whatever the memory is given
/// to next.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LoadGPUCode`, `FindGPUKernel`, `FreeGPUMemory`
///
/// EXAMPLES:
/// ```zig
/// _ = ab.WaitGPUCompute(job, 1000);
/// ab.FreeGPUCode(&code);
/// ```
pub fn FreeGPUCode(ab: *AMDGPUBase, code: *amdgpu.GPUCode) void {
    const gpu: *sdk.interface.amdgpu.AMDGPUBase = @ptrCast(&ab.lib);
    if (code.memory.bytes != 0) gpu.FreeGPUMemory(&code.memory);
    code.* = .{};
}
