// SPDX-License-Identifier: MPL-2.0
//! PostWork: a job run beside its poster, on another core's worker.

const sdk = @import("sdk");
const _workers = @import("_workers.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const WorkJob = sdk.exec.WorkJob;

/// Runs a job beside the task that posts it, and replies it when done.
///
/// SYNOPSIS:
/// ```zig
/// fn PostWork(base: *ExecBase, job: *WorkJob) void
/// ```
///
/// SINCE: 1.27. LVO -580.
///
/// INPUTS:
/// - `job` - the job: its message, whose `reply_port` it is replied to;
///   its code, `work`; and its `data`.
///
/// RESULT:
/// Nothing. The job comes back on its reply port once its code has run.
///
/// BEHAVIOR:
/// exec keeps a worker task on each core, pinned to it - the ones
/// ShareWork hands its parts to. The job is queued at the poster's
/// priority, and an idle worker woken for it, another core's before the
/// poster's own. The worker calls `job.work(job)` at that priority and
/// replies the job; meanwhile the poster goes on, and waits for the reply
/// when it wants it, with whatever else it waits for.
///
/// While every worker is busy the jobs wait their turn, the highest
/// priority first, and in the order posted among the same; a worker done
/// with a part or a job takes the next. A worker running posted jobs is not
/// handed parts by ShareWork, which does without it.
///
/// On a machine with one core - or before multitasking - the poster runs
/// the job itself, and it is replied before PostWork returns.
///
/// A job runs on a worker, not on its poster: its code may not use dos, nor
/// obtain a semaphore its poster may hold, and should not wait at all - a
/// job that waits keeps a core's worker from the queue. It may allocate and
/// free memory, signal, put messages, post jobs and share work. Its stack
/// is the worker's: 32 KiB on a 64-bit machine, 16 KiB on a 32-bit one.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: any spinlock of a program's or a driver's may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The job stays the caller's memory, lent to exec until it is replied: it
/// is not changed, freed or posted again before then. PostWork sets its
/// message's node - type and priority.
///
/// NOTES:
/// Posting a job and having it back costs a few signals between the cores,
/// some microseconds: a job worth posting takes longer than that.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ShareWork`, `ReplyMsg`, `WaitPort`
///
/// EXAMPLES:
/// ```zig
/// fn sumRun(job: *exec.WorkJob) callconv(.c) void {
///     const run: *Run = @ptrCast(@alignCast(job.data.?));
///     run.sum = checksum(run.bytes);
/// }
/// var job = exec.WorkJob{ .message = .{ .reply_port = port }, .work = &sumRun, .data = &run };
/// sys.PostWork(&job);
/// serveNextPacket();
/// _ = sys.WaitPort(port);
/// _ = sys.GetMsg(port);
/// ```
pub fn PostWork(base: *ExecBase, job: *WorkJob) void {
    _workers.post(base, job);
}
