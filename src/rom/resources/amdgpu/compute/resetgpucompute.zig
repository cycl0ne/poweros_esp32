// SPDX-License-Identifier: MPL-2.0
//! ResetGPUCompute: the compute engine's queue reset where a job on it
//! does not end, as the vendor's driver resets a kernel compute queue on
//! this block with the scheduler (amdgpu_gfx_mes_reset_queue_start,
//! amdgpu_ring_reset_helper_end): every job not done marked given up, the
//! queue dequeued with its waves let finish - or reset where they do not,
//! or its pipe reset - the jobs whose ends come as it stops left given
//! up, or the first job not done where
//! none comes, the queue removed by the scheduler, made new, mapped again
//! and tried, and the jobs after those written to it again - where none
//! came, the given-up one with its own packets made NOPs.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _compute = @import("_compute.zig");
const _graphics = @import("../graphics/_graphics.zig");

/// The compute engine's queue reset where job `job` is not done: the jobs
/// the reset ends given up, and the jobs after them written to the queue
/// again.
///
/// SYNOPSIS:
/// ```zig
/// fn ResetGPUCompute(ab: *AMDGPUBase, job: u32, flags: u32) u32
/// ```
///
/// SINCE: 1.17. LVO -112.
///
/// INPUTS:
/// - `job` - a job's number, as SendGPUCompute or SendGPUKernel answered
///   it, that WaitGPUCompute found not done in time.
/// - `flags` - GPURESET_PIPE resets the compute engine's pipe, every
///   queue on it, rather than the queue alone; with 0 the pipe is reset
///   only where the queue's own reset does not take.
///
/// RESULT:
/// The number of the last job the reset gave up, once the queue runs
/// again: every job from the first not done to it is given up. 0 where
/// nothing was: where `job` is 0, not sent or done - WaitGPUCompute says
/// which - or where the queue does not run; and where the queue could not
/// be reset: every job not done is given up then, the queue is stopped,
/// and every call that sends a job answers 0 from then on.
///
/// BEHAVIOR:
/// Under the queue's lock, as the vendor's driver resets a kernel compute
/// queue on this block (amdgpu_gfx_mes_reset_queue_start, by its
/// registers, as it does for compute): in the RLC's safe mode the queue
/// is selected, every job not done marked given up, and its dequeue asked
/// with its waves let finish and no group of its dispatches started any
/// more (CP_HQD_DEQUEUE_REQUEST 1, since 1.23), as the vendor's compute
/// driver takes a queue off the engine whose work is to stay right
/// (hqd_destroy_v11's DRAIN_PIPE, update_queue); the queue is waited for
/// to be inactive, 100 ms at most. Where it is not, its dequeue is asked
/// with its waves reset (CP_HQD_DEQUEUE_REQUEST 2), the shader input's
/// state of it reset (SPI_COMPUTE_QUEUE_RESET) and the queue waited for
/// the same way (mes_v11_0_reset_queue_mmio). Where it is still not - and
/// at once with GPURESET_PIPE - the compute engine's pipe is
/// held in reset while each of its eight queues is set inactive, then let
/// go (mes_v11_0_reset_compute_pipe_mmio), and taken to have worked, as
/// the vendor's driver takes it: the ring's test says.
///
/// The engine goes on to a job's next packets while its kernels run, and
/// a job's end waits for the kernels of every job before it. So where the
/// reset ends waves still running, the end of every job the engine had
/// got to comes as the queue stops: those jobs stay given up - the kernels
/// of some ended, of others perhaps done, which nothing tells apart - and
/// the jobs after them are written to the queue again as they were sent.
/// Where no end comes - the waves let finish, or the engine itself held
/// in a job's packets, by a wait on memory (GPUPACKET_WAIT_REG_MEM) - only
/// the first job not done stays given up: it is written again with its
/// own packets made NOPs, so
/// that its end - its number written, its interrupt raised - comes in its
/// place, and every job after it with it
/// (amdgpu_ring_set_fence_errors_and_reemit). The words of the jobs to be
/// written again are kept aside (amdgpu_ring_backup_unprocessed_commands);
/// the scheduler is told the queue is removed after its reset
/// (REMOVE_QUEUE); the queue's description is made again as its start
/// made it, its ring filled with NOPs and its pointers set to 0
/// (amdgpu_gfx_mqd_reset_restore); the scheduler maps it again
/// (ADD_QUEUE) and it is tried with a register it sets
/// (amdgpu_ring_reset_helper_end); last the jobs kept are written to it
/// from its start, in order. Where the first job not done is one a reset
/// gave up before, so that the NOPs in its place did not end either, or
/// there is no memory to keep the jobs' words in, nothing is written
/// again: every job not done stays given up and the last one's number is
/// written as done (amdgpu_fence_driver_force_completion), as it is where
/// the queue could not be reset. The tasks waiting for jobs are woken to
/// look again.
///
/// CONTEXT:
/// - Waits: for the queue's waves to finish, 100 ms at most, and then for
///   it to be inactive, 100 ms at most; for each of the scheduler's two
///   calls, 2.1 s at most; for the ring's test, 100 ms at most - a few
///   milliseconds where all goes well, 100 more where a kernel's waves
///   run on.
/// - Interrupts: no.
/// - Locks: takes the queue's lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The words kept aside are in memory taken for the reset, given back
/// before it returns.
///
/// NOTES:
/// A job given up is gone: what its kernels wrote before the reset stays
/// written, the rest never is - and one given up with others may have
/// been done whole. Where the queue's waves are let finish, each group of
/// a job given up has run whole or not begun; only where they are reset
/// may a wave have been ended between two of its instructions - on the
/// NucBox, nine resets that did so in the middle of jobs of the board's
/// left 1009 pixels laid twice, a wave's at a time. WaitGPUCompute answers
/// false at once for a job a reset
/// gave up, while fewer than 64 jobs have been sent after it. A job
/// written again runs from its start. The queue's scratch, its slots of
/// arguments and its interrupt are kept as they are.
///
/// BUGS:
/// A job whose kernels the engine had begun but whose end it had not got
/// to is written again whole: its kernels write again what they wrote. A
/// queue that cannot be reset is not started again: nothing resets the
/// whole graphics block.
///
/// SEE ALSO:
/// `WaitGPUCompute`, `SendGPUKernel`, `SendGPUCompute`,
/// `GetGPUComputeState`
///
/// EXAMPLES:
/// ```zig
/// const job = ab.SendGPUKernel(&kernel, &dispatch);
/// if (job == 0) return error.NoCompute;
/// // A job written again is waited for again; one given up is answered
/// // false at once.
/// while (!ab.WaitGPUCompute(job, 1000)) {
///     if (ab.ResetGPUCompute(job, 0) == 0) break;
/// }
/// if (!ab.WaitGPUCompute(job, 0)) return error.NotDone;
/// ```
pub fn ResetGPUCompute(ab: *AMDGPUBase, job: u32, flags: u32) u32 {
    if (ab.device == null or job == 0) return 0;
    const sys = ab.sys_base;
    const owner = amdgpu.AMDGPUNAME;
    sys.ObtainSemaphore(&ab.compute_lock);
    defer sys.ReleaseSemaphore(&ab.compute_lock);
    if (!ab.compute_running) return 0;
    if (_compute.passed(_compute.done(ab), job) or !_compute.passed(ab.compute_sent, job)) return 0;

    const stopped = stopQueue(ab, flags & amdgpu.GPURESET_PIPE != 0);

    // The jobs given up: those whose ends came as the queue stopped, or
    // the first job not done where none came, written again with its own
    // packets made NOPs; the words of the jobs to be written again kept
    // aside, unless that one is one a reset gave up before.
    const sent = ab.compute_sent;
    const first = _compute.nextJob(stopped.before);
    const after = _compute.done(ab);
    const ended = _compute.passed(after, first);
    var given_up = if (ended) after else first;
    const again_from = if (ended) _compute.nextJob(after) else first;
    const anything_again = !ended or !_compute.passed(after, sent);
    var kept: ?[]u32 = null;
    defer if (kept) |words| sys.FreeVec(@ptrCast(words.ptr));
    if (anything_again and (ended or !stopped.repeated)) {
        if (_compute.record(ab, again_from)) |from| {
            const count = @min(ab.compute_written -% from.start, _compute.compute_ring_words);
            if (count >= _compute.acquire.len + from.packets) {
                if (sys.AllocVec(@intCast(count * 4), exec.MEMF_ANY)) |memory| {
                    const room: [*]u32 = @ptrCast(@alignCast(memory));
                    kept = room[0..@intCast(count)];
                    _compute.keepJobs(ab, from.start, kept.?);
                }
            }
        }
    }

    // Removed by the scheduler, made new, mapped again and tried.
    const version = ab.scheduler_version & _compute.scheduler_version_mask;
    var frame = _compute.removeFrame(_compute.compute_queue, _compute.compute_doorbell, version >= _compute.scheduler_removes_after_reset_from);
    if (!_compute.call(ab, &frame, _compute.remove_queue_status_at)) return failed(ab, "the scheduler does not remove it");
    _compute.renewQueue(ab);
    frame = _compute.mapFrame(_compute.compute_queue, _compute.compute_doorbell, ab.compute.device + _compute.compute_mqd_at, ab.compute.device + _compute.compute_write_at);
    if (!_compute.call(ab, &frame, _compute.add_queue_status_at)) return failed(ab, "the scheduler does not map it again");
    if (!_compute.tryRing(ab, .compute)) {
        const at = _graphics.at;
        _compute.select(ab, _compute.compute_queue, 0);
        const active = at(ab, _compute.CP_HQD_ACTIVE).*;
        const queue_read = at(ab, _compute.CP_HQD_PQ_RPTR).*;
        const queue_written = at(ab, _compute.CP_HQD_PQ_WPTR_LO).*;
        _compute.select(ab, _compute.no_queue, 0);
        exec.kprintf(sys, "%s: the compute engine's queue after its reset: active %x, read %x, written %x, CP_CPC_STATUS %x\n", .{
            owner, active, queue_read, queue_written, at(ab, _compute.CP_CPC_STATUS).*,
        });
        return failed(ab, "it does not set a register");
    }

    // The jobs after those given up written again - no longer given up -
    // or, where their words are not kept, every job not done given up.
    ab.compute_resets +%= 1;
    const with: [*:0]const u8 = if (stopped.pipe) " with its pipe" else if (stopped.drained) ", its waves let finish" else ", its waves reset";
    if (anything_again and kept == null) {
        _compute.forceDone(ab);
        given_up = sent;
        exec.kprintf(sys, "%s: the compute engine's queue was reset%s: jobs %u to %u given up\n", .{ owner, with, first, sent });
    } else {
        const again = if (_compute.passed(given_up, sent)) 0 else _compute.markGivenUp(ab, _compute.nextJob(given_up), sent, false);
        if (kept) |words| _compute.writeAgain(ab, words, again_from, !ended);
        if (ended) {
            exec.kprintf(sys, "%s: the compute engine's queue was reset%s: jobs %u to %u given up, their ends having come as it stopped; the %u after them written again\n", .{
                owner, with, first, given_up, again,
            });
        } else {
            exec.kprintf(sys, "%s: the compute engine's queue was reset%s: job %u given up, no end having come as it stopped; the %u after it written again\n", .{
                owner, with, first, again,
            });
        }
    }
    ab.compute_given_up = given_up;
    sys.SignalWaitable(&ab.compute_end);
    return given_up;
}

/// How the queue was stopped: whether its pipe was reset, or else whether
/// its waves finished as it was drained; the last job done just before it
/// was told to stop - every job after it marked given up then - and
/// whether the first job not done was one a reset had given up before.
const Stopped = struct { pipe: bool, drained: bool, before: u32, repeated: bool };

/// Every job not done marked given up, just before the queue is told to
/// stop - the ends of those it ends come at once, to tasks waiting for
/// them - with the last job done read then.
fn markNotDone(ab: *AMDGPUBase, stopped: *Stopped) void {
    const before = _compute.done(ab);
    const first = _compute.nextJob(before);
    stopped.before = before;
    stopped.repeated = _compute.givenUp(ab, first);
    if (!_compute.passed(before, ab.compute_sent)) _ = _compute.markGivenUp(ab, first, ab.compute_sent, true);
}

/// The queue stopped in the RLC's safe mode (mes_v11_0_reset_queue_mmio):
/// selected, every job not done marked given up, its dequeue asked with
/// its waves let finish and no group of its dispatches started any more
/// (hqd_destroy_v11's DRAIN_PIPE), and waited for to be inactive, 100 ms
/// at most; where it is not, its dequeue asked with its waves reset, the
/// shader input's state of it reset, and waited for the same way; where it
/// is still not, or `pipe_at_once` says so, the compute engine's pipe reset
/// (mes_v11_0_reset_compute_pipe_mmio) - held in reset while each queue
/// on it is set inactive and its dequeue cleared, then let go, its first
/// instruction's place said.
fn stopQueue(ab: *AMDGPUBase, pipe_at_once: bool) Stopped {
    const sys = ab.sys_base;
    const owner = amdgpu.AMDGPUNAME;
    const at = _graphics.at;
    const queue = _compute.compute_queue;
    var stopped: Stopped = .{ .pipe = pipe_at_once, .drained = false, .before = 0, .repeated = false };
    if (!stopped.pipe) {
        const safe = _graphics.enterSafeMode(ab);
        _compute.select(ab, queue, 0);
        markNotDone(ab, &stopped);
        at(ab, _compute.CP_HQD_DEQUEUE_REQUEST).* = _compute.DEQUEUE_DRAIN_PIPE;
        stopped.drained = inactiveWithin(ab, _compute.drain_most_us);
        if (!stopped.drained) {
            at(ab, _compute.CP_HQD_DEQUEUE_REQUEST).* = _compute.DEQUEUE_RESET_WAVES;
            at(ab, _compute.SPI_COMPUTE_QUEUE_RESET).* = _compute.QUEUE_RESET;
            if (!inactiveWithin(ab, _compute.dequeue_most_us)) {
                exec.kprintf(sys, "%s: the compute engine's queue stays active after its dequeue: CP_HQD_DEQUEUE_REQUEST %x; its pipe is reset\n", .{
                    owner, at(ab, _compute.CP_HQD_DEQUEUE_REQUEST).*,
                });
                stopped.pipe = true;
            }
        }
        _compute.select(ab, _compute.no_queue, 0);
        _graphics.leaveSafeMode(ab, safe);
    }
    if (stopped.pipe) {
        const safe = _graphics.enterSafeMode(ab);
        _compute.select(ab, queue, 0);
        if (pipe_at_once) markNotDone(ab, &stopped);
        const control = at(ab, _compute.CP_MEC_CNTL).*;
        const reset = _compute.MEC_ME1_PIPE0_RESET << @intCast(queue.pipe);
        at(ab, _compute.CP_MEC_CNTL).* = control | reset;
        for (0.._compute.queues_per_pipe) |each| {
            _compute.select(ab, .{ .me = queue.me, .pipe = queue.pipe, .queue = @intCast(each) }, 0);
            at(ab, _compute.CP_HQD_ACTIVE).* = 0;
            at(ab, _compute.CP_HQD_DEQUEUE_REQUEST).* = 0;
        }
        at(ab, _compute.CP_MEC_CNTL).* = control & ~reset;
        const pointer = at(ab, _compute.CP_MEC1_INSTR_PNTR).*;
        _compute.select(ab, _compute.no_queue, 0);
        _graphics.leaveSafeMode(ab, safe);
        exec.kprintf(sys, "%s: the compute engine's pipe %u was reset: CP_MEC1_INSTR_PNTR %x\n", .{ owner, queue.pipe, pointer });
    }
    return stopped;
}

/// Whether the queue selected is inactive within `most_us`.
fn inactiveWithin(ab: *AMDGPUBase, most_us: u64) bool {
    const sys = ab.sys_base;
    const until = sys.UptimeUs() + most_us;
    while (_graphics.at(ab, _compute.CP_HQD_ACTIVE).* & _compute.HQD_ACTIVE != 0) {
        if (sys.UptimeUs() > until) return false;
    }
    return true;
}

/// A reset that did not bring the queue back, said with `what`: every job
/// not done given up - each is marked so - and the last one's number
/// written as done, the tasks waiting for them woken; the queue is taken
/// as stopped, and no job is sent to it from then on. 0, for the caller
/// to answer.
fn failed(ab: *AMDGPUBase, what: [*:0]const u8) u32 {
    exec.kprintf(ab.sys_base, "%s: the compute engine's queue is not reset - %s: it is stopped, every job not done given up\n", .{ amdgpu.AMDGPUNAME, what });
    _compute.forceDone(ab);
    ab.compute_given_up = ab.compute_sent;
    ab.compute_running = false;
    ab.compute_failed = true;
    ab.sys_base.SignalWaitable(&ab.compute_end);
    return 0;
}
