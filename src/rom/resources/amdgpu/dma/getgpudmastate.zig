// SPDX-License-Identifier: MPL-2.0
//! GetGPUDMAState: the DMA engine's queue as it is - its ring, how far it
//! is read and written, its jobs and the engine's interrupts.

const sdk = @import("sdk");
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _dma = @import("_dma.zig");
const _graphics = @import("../graphics/_graphics.zig");

/// The DMA engine's queue as it is, read into `state`.
///
/// SYNOPSIS:
/// ```zig
/// fn GetGPUDMAState(ab: *AMDGPUBase, state: *amdgpu.GPUDMAState) bool
/// ```
///
/// SINCE: 1.10. LVO -64.
///
/// INPUTS:
/// - `state` - where to put it.
///
/// RESULT:
/// True with `state` filled in; false, `state` untouched, where the queue
/// does not run.
///
/// BEHAVIOR:
/// The ring's device address and length; how far the engine has read it,
/// as it last wrote it back, and how far it has been written, in bytes
/// since the queue started; the number of the last job sent and of the
/// last done; the interrupts the engine raised at the ends of jobs; and
/// the engine's status register - its bit 0 set while it is idle.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none: what is read is a moment's, and moves on as the engine
///   works.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `state` is the caller's.
///
/// NOTES:
/// The engine writes how far it has read after every few packets, not at
/// once; `done` is the job's fence, which is written at the job's end.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartGPUDMA`, `SendGPUDMA`, `WaitGPUDMA`
///
/// EXAMPLES:
/// ```zig
/// var state: amdgpu.GPUDMAState = .{};
/// if (ab.GetGPUDMAState(&state)) Printf(dl, "%u of %u done\n", .{ state.done, state.sent });
/// ```
pub fn GetGPUDMAState(ab: *AMDGPUBase, state: *amdgpu.GPUDMAState) bool {
    if (ab.device == null or !ab.dma_running) return false;
    state.* = .{
        .ring = ab.dma_ring.device,
        .ring_bytes = _dma.ring_bytes,
        .read = _dma.readBack(ab),
        .written = ab.dma_written,
        .sent = ab.dma_sent,
        .done = _dma.done(ab),
        .traps = ab.dma_traps,
        .status = _graphics.at(ab, _dma.STATUS_REG).*,
    };
    return true;
}
