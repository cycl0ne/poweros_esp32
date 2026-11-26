// SPDX-License-Identifier: MPL-2.0
//! SendGPUCompute: a job of the compute engine's packets put on its queue.

const sdk = @import("sdk");
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _compute = @import("_compute.zig");

/// A job of the compute engine's packets put on its queue: the engine's
/// caches made to see memory as the CPU left it, the packets, and the
/// job's end, which writes its number and raises the engine's interrupt.
///
/// SYNOPSIS:
/// ```zig
/// fn SendGPUCompute(ab: *AMDGPUBase, packets: [*]const u32, words: u32) u32
/// ```
///
/// SINCE: 1.12. LVO -80.
///
/// INPUTS:
/// - `packets` - the command processor's packets (GPUPACKET), one after
///   another.
/// - `words` - how many words they are; 0 makes a job of nothing, whose
///   end says every job before it is done.
///
/// RESULT:
/// The job's number, which WaitGPUCompute waits for: never 0, one more
/// than the last job's, past 0 to 1. 0 where the queue does not run
/// (StartGPUCompute), where the job with its start and end would take the
/// whole ring (some 16 thousand words), or where the engine has not read
/// enough of the ring to make room for it within a second.
///
/// BEHAVIOR:
/// Under the queue's lock the job waits for room in the ring - the engine
/// writes back how far it has read - then the ring is given: a packet
/// that drops the engine's caches below the memory and writes the second
/// level's back (ACQUIRE_MEM), the caller's packets, and one that, once
/// they are done, writes the caches back, writes the job's number into
/// the queue's page and raises the engine's end-of-pipe interrupt
/// (RELEASE_MEM); then NOPs to the next 256 words, and the engine is told
/// through the queue's doorbell. It starts on the job at once where it is
/// idle, else after the jobs before it. The packets are not looked at:
/// what they name is the caller's to have right.
///
/// CONTEXT:
/// - Waits: only for room in the ring, a second at most.
/// - Interrupts: no.
/// - Locks: takes the queue's lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The packets are copied: they are the caller's again on return. The
/// memory they name must stay where it is until the job is done.
///
/// NOTES:
/// Addresses in the packets are the device's: a piece of its own memory
/// by its `device` address (AllocGPUMemory), the machine's by where it is
/// mapped (MapGPUMemory). A job takes at least 256 words of the ring: at
/// most 63 jobs wait in it at once.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartGPUCompute`, `SendGPUKernel`, `WaitGPUCompute`,
/// `GetGPUComputeState`
///
/// EXAMPLES:
/// ```zig
/// // A word written into the device's memory.
/// const write = [_]u32{
///     amdgpu.GPUPACKET | amdgpu.GPUPACKET_WRITE_DATA << amdgpu.GPUPACKET_OP_SHIFT | 3 << amdgpu.GPUPACKET_COUNT_SHIFT,
///     amdgpu.GPUWRITE_MEMORY | amdgpu.GPUWRITE_CONFIRM,
///     @truncate(piece.device), @truncate(piece.device >> 32), 0x1234_5678,
/// };
/// const job = ab.SendGPUCompute(&write, write.len);
/// if (job == 0 or !ab.WaitGPUCompute(job, 1000)) return error.NoCompute;
/// ```
pub fn SendGPUCompute(ab: *AMDGPUBase, packets: [*]const u32, words: u32) u32 {
    if (ab.device == null or !ab.compute_running) return 0;
    if (_compute.jobWords(words) >= _compute.compute_ring_words) return 0;
    const sys = ab.sys_base;
    sys.ObtainSemaphore(&ab.compute_lock);
    defer sys.ReleaseSemaphore(&ab.compute_lock);
    return _compute.send(ab, packets[0..words]);
}
