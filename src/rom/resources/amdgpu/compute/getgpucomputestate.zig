// SPDX-License-Identifier: MPL-2.0
//! GetGPUComputeState: the compute engine's queue as it is.

const sdk = @import("sdk");
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _compute = @import("_compute.zig");
const _graphics = @import("../graphics/_graphics.zig");

/// The compute engine's queue as it is: its ring, how far it has been
/// read and written, its jobs and interrupts, the scheduler's firmware,
/// and the queue's and the engine's registers.
///
/// SYNOPSIS:
/// ```zig
/// fn GetGPUComputeState(ab: *AMDGPUBase, state: *amdgpu.GPUComputeState) bool
/// ```
///
/// SINCE: 1.12. LVO -92.
///
/// INPUTS:
/// - `state` - where the queue's state goes (GPUComputeState).
///
/// RESULT:
/// True with `state` filled; false, `state` untouched, where the queue
/// does not run.
///
/// BEHAVIOR:
/// The ring's address and length; how far the engine has read it, as it
/// last wrote that back, and how far it has been written, in bytes; the
/// last job sent and the last done; the end-of-pipe interrupts taken; the
/// scheduler's firmware versions, of its first pipe and of the mapper;
/// whether the queue is mapped (CP_HQD_ACTIVE) and its read and write
/// pointers in words as its registers read now, with the queue selected;
/// the block's status (GRBM_STATUS) and its compute processor's
/// (CP_CPC_STATUS); since 1.16, the queue's scratch: where it is to the
/// device, its bytes and the waves it holds, 0 until a kernel with
/// private memory has been sent (SendGPUKernel); and since 1.17, how many
/// times the queue was reset and the last job a reset gave up
/// (ResetGPUCompute), 0 until one has; and since 1.22 the scratch
/// SendGPUKernel made for one job alone - where it is, its bytes, its
/// waves and the job, all 0 where none is in use, one whose job is done
/// given back first - and how many have been made.
///
/// CONTEXT:
/// - Waits: only for the queue's lock.
/// - Interrupts: no.
/// - Locks: takes the queue's lock, as the queue's registers are reached
///   through a selection the block holds for everyone.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated; a scratch made for one job whose job is done is
/// given back.
///
/// NOTES:
/// The registers are read while jobs may be running: two calls a moment
/// apart can say different things.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartGPUCompute`, `SendGPUCompute`, `WaitGPUCompute`,
/// `ResetGPUCompute`
///
/// EXAMPLES:
/// ```zig
/// var state: amdgpu.GPUComputeState = .{};
/// if (ab.GetGPUComputeState(&state)) {
///     _ = Printf(dl, "%u jobs sent, %u done\n", .{ state.sent, state.done });
/// }
/// ```
pub fn GetGPUComputeState(ab: *AMDGPUBase, state: *amdgpu.GPUComputeState) bool {
    if (ab.device == null or !ab.compute_running) return false;
    const sys = ab.sys_base;
    const at = _graphics.at;
    sys.ObtainSemaphore(&ab.compute_lock);
    defer sys.ReleaseSemaphore(&ab.compute_lock);
    _compute.giveBackOnce(ab);
    _compute.select(ab, _compute.compute_queue, 0);
    const active = at(ab, _compute.CP_HQD_ACTIVE).*;
    const queue_read = at(ab, _compute.CP_HQD_PQ_RPTR).*;
    const queue_written = at(ab, _compute.CP_HQD_PQ_WPTR_LO).*;
    _compute.select(ab, _compute.no_queue, 0);
    state.* = .{
        .ring = ab.compute.device + _compute.compute_ring_at,
        .ring_bytes = _compute.compute_ring_bytes,
        .read = @as(u64, _compute.readBack(ab)) * 4,
        .written = ab.compute_written * 4,
        .sent = ab.compute_sent,
        .done = _compute.done(ab),
        .interrupts = ab.compute_ends,
        .scheduler = ab.scheduler_version,
        .scheduler_queues = ab.mapper_version,
        .active = active & 1,
        .queue_read = queue_read,
        .queue_written = queue_written,
        .status = at(ab, _compute.GRBM_STATUS).*,
        .compute_status = at(ab, _compute.CP_CPC_STATUS).*,
        .scratch = ab.scratch.device,
        .scratch_bytes = ab.scratch.bytes,
        .scratch_waves = ab.scratch_waves,
        .resets = ab.compute_resets,
        .given_up = ab.compute_given_up,
        .scratch_once = ab.scratch_once.device,
        .scratch_once_bytes = ab.scratch_once.bytes,
        .scratch_once_waves = ab.scratch_once_waves,
        .scratch_once_job = ab.scratch_once_job,
        .scratch_once_made = ab.scratch_once_made,
    };
    return true;
}
