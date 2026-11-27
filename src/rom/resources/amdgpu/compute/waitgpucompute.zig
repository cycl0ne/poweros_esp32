// SPDX-License-Identifier: MPL-2.0
//! WaitGPUCompute: the wait for a job of the compute engine's queue.

const sdk = @import("sdk");
const exec = sdk.exec;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _compute = @import("_compute.zig");

/// The longest the wait sleeps before it looks at the job's number again,
/// whatever wakes it: so that a number the interrupt arrived before is
/// not waited past.
const look_us: u64 = 10_000;

/// Waits until the compute engine has done job `job`, for `most_ms`
/// milliseconds at most.
///
/// SYNOPSIS:
/// ```zig
/// fn WaitGPUCompute(ab: *AMDGPUBase, job: u32, most_ms: u32) bool
/// ```
///
/// SINCE: 1.12. LVO -88.
///
/// INPUTS:
/// - `job` - a job's number, as SendGPUCompute or SendGPUKernel answered
///   it.
/// - `most_ms` - how long to wait at most, in milliseconds; 0 only looks.
///
/// RESULT:
/// True once the engine has done the job and every one before it, at once
/// where it already has. False where it has not within `most_ms`, where
/// `job` is 0 or the queue does not run, and at once for a job a reset
/// gave up (ResetGPUCompute).
///
/// BEHAVIOR:
/// The engine writes each job's number into the queue's page once its
/// work is done and the caches are written back, and raises its
/// end-of-pipe interrupt, whose server signals the queue's waitable. The
/// wait looks at the number written, and sleeps on the waitable until the
/// job is done or the time is up - looking again at least every 10 ms,
/// whatever wakes it. Numbers are compared modulo 2^32, so a job more
/// than two thousand million jobs old is taken as one not sent yet. A job
/// a reset gave up has its number written as done, as its record says;
/// since 1.17 it is answered false, while fewer than 64 jobs have been
/// sent after it - past that, as done. Since 1.22, once the job is done,
/// a scratch SendGPUKernel made for one job alone is given back where
/// that job is done too and the queue's lock is free.
///
/// CONTEXT:
/// - Waits: yes, until the job is done, `most_ms` at most.
/// - Interrupts: no.
/// - Locks: takes the queue's waiting lock: tasks wait one after another,
///   each for its own job; once the job is done, the queue's lock where
///   it is free.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated; a scratch made for one job whose job is done may
/// be given back.
///
/// NOTES:
/// What a job's kernels wrote is in the memory once the job is done. A
/// job the engine has not done after a long wait points at a packet or a
/// kernel it cannot finish, which holds every job after it;
/// GetGPUComputeState says how far it has read, and ResetGPUCompute gives
/// the first job not done up and lets the others run.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SendGPUCompute`, `SendGPUKernel`, `ResetGPUCompute`,
/// `GetGPUComputeState`, `WaitForAny`
///
/// EXAMPLES:
/// ```zig
/// const job = ab.SendGPUKernel(&kernel, &dispatch);
/// if (job == 0 or !ab.WaitGPUCompute(job, 1000)) return error.NoCompute;
/// ```
pub fn WaitGPUCompute(ab: *AMDGPUBase, job: u32, most_ms: u32) bool {
    if (ab.device == null or !ab.compute_running or job == 0) return false;
    if (!ended(ab, job, most_ms)) return false;
    giveBack(ab);
    return !_compute.givenUp(ab, job);
}

/// Whether the engine has done job `job` within `most_ms`, under the
/// queue's waiting lock where it has not already.
fn ended(ab: *AMDGPUBase, job: u32, most_ms: u32) bool {
    if (_compute.passed(_compute.done(ab), job)) return true;
    const sys = ab.sys_base;
    const until = sys.UptimeUs() + @as(u64, most_ms) * 1000;
    sys.ObtainSemaphore(&ab.compute_wait_lock);
    defer sys.ReleaseSemaphore(&ab.compute_wait_lock);
    const list = [_]*exec.Waitable{&ab.compute_end};
    while (true) {
        sys.ResetWaitable(&ab.compute_end);
        if (_compute.passed(_compute.done(ab), job)) return true;
        const now = sys.UptimeUs();
        if (now >= until) return false;
        _ = sys.WaitForAny(&list, 1, @min(until - now, look_us));
    }
}

/// The scratch made for one job given back where that job is done, so
/// that a program that waits for its own job gets the device's memory
/// back: only where the queue's lock is free, as a sender that holds it
/// gives it back itself.
fn giveBack(ab: *AMDGPUBase) void {
    if (@atomicLoad(u32, &ab.scratch_once_job, .monotonic) == 0) return;
    const sys = ab.sys_base;
    if (!sys.AttemptSemaphore(&ab.compute_lock)) return;
    defer sys.ReleaseSemaphore(&ab.compute_lock);
    _compute.giveBackOnce(ab);
}
