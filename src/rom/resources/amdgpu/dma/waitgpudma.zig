// SPDX-License-Identifier: MPL-2.0
//! WaitGPUDMA: a wait until the DMA engine has done a job, woken by the
//! engine's interrupt at each job's end.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _dma = @import("_dma.zig");

/// The longest the wait sleeps before it looks at the job's fence again,
/// whatever wakes it: so that a fence the interrupt arrived before is not
/// waited past.
const look_us: u64 = 10_000;

/// Waits until the DMA engine has done job `job`, for `most_ms`
/// milliseconds at most.
///
/// SYNOPSIS:
/// ```zig
/// fn WaitGPUDMA(ab: *AMDGPUBase, job: u32, most_ms: u32) bool
/// ```
///
/// SINCE: 1.10. LVO -60.
///
/// INPUTS:
/// - `job` - a job's number, as SendGPUDMA answered it.
/// - `most_ms` - how long to wait at most, in milliseconds; 0 only looks.
///
/// RESULT:
/// True once the engine has done the job and every one before it, at once
/// where it already has. False where it has not within `most_ms`, where
/// `job` is 0 or the queue does not run, and at once for a job a reset of
/// the whole block gave up (since 1.24) - the reset ResetGPUCompute makes
/// where nothing less brings its own queue back.
///
/// BEHAVIOR:
/// The engine writes each job's number into the queue's page as it ends
/// it, and raises its interrupt, whose server signals the queue's
/// waitable. The wait looks at the number written, and sleeps on the
/// waitable until the job is done or the time is up - looking again at
/// least every 10 ms, whatever wakes it. Numbers are compared modulo
/// 2^32, so a job more than two thousand million jobs old is taken as one
/// not sent yet. A reset of the whole block lets the engine finish its
/// jobs first, 100 ms at most; those it has not done by then it gives
/// up, and the queue, started again, reads them done. While the reset is
/// under way the wait goes on as before.
///
/// CONTEXT:
/// - Waits: yes, until the job is done, `most_ms` at most.
/// - Interrupts: no.
/// - Locks: takes the queue's waiting lock: tasks wait one after another,
///   each for its own job.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// NOTES:
/// A job the engine has not done after a long wait points at a packet it
/// cannot do; GetGPUDMAState says how far it has read.
///
/// BUGS:
/// A job the engine never ends - a packet it hangs on - holds every job
/// after it: the queue has no reset of its own, and only a reset of the
/// whole block, which ResetGPUCompute makes for the compute engine's
/// queue, gives its jobs up.
///
/// SEE ALSO:
/// `SendGPUDMA`, `GetGPUDMAState`, `WaitForAny`
///
/// EXAMPLES:
/// ```zig
/// const job = ab.SendGPUDMA(&packets, packets.len);
/// if (job == 0 or !ab.WaitGPUDMA(job, 1000)) return error.NoDma;
/// ```
pub fn WaitGPUDMA(ab: *AMDGPUBase, job: u32, most_ms: u32) bool {
    if (ab.device == null or !_dma.runs(ab) or job == 0) return false;
    if (_dma.passed(_dma.done(ab), job)) return !_dma.givenUp(ab, job);
    const sys = ab.sys_base;
    const until = sys.UptimeUs() + @as(u64, most_ms) * 1000;
    sys.ObtainSemaphore(&ab.dma_wait_lock);
    defer sys.ReleaseSemaphore(&ab.dma_wait_lock);
    const list = [_]*exec.Waitable{&ab.dma_trap};
    while (true) {
        sys.ResetWaitable(&ab.dma_trap);
        if (_dma.passed(_dma.done(ab), job)) return !_dma.givenUp(ab, job);
        const now = sys.UptimeUs();
        if (now >= until) return false;
        _ = sys.WaitForAny(&list, 1, @min(until - now, look_us));
    }
}
