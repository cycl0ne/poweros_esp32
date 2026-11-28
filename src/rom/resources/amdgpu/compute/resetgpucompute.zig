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
//! came, the given-up one with its own packets made NOPs. Where that does
//! not bring the queue back, or the caller asks for it, the whole graphics
//! block is reset, as the vendor's driver resets this block
//! (soc21_asic_reset_method: MODE2), and started again with its queues.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _compute = @import("_compute.zig");
const _graphics = @import("../graphics/_graphics.zig");
const _dma = @import("../dma/_dma.zig");
const _power = @import("../power/_power.zig");
const _memory = @import("../memory/_memory.zig");

/// How long the DMA engine is given to finish its jobs before a reset of
/// the whole block, and then to rinse the block's caches.
const finish_most_us: u64 = 100_000;

/// The compute engine's queue reset where job `job` is not done: the jobs
/// the reset ends given up, and the jobs after them written to the queue
/// again; where that does not bring it back, the whole graphics block
/// reset and its queues started again.
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
///   only where the queue's own reset does not take. GPURESET_BLOCK
///   (since 1.24) resets the whole block at once, the queue's waves let
///   finish first.
///
/// RESULT:
/// The number of the last job the reset gave up, once the queue runs
/// again: every job from the first not done to it is given up - after a
/// reset of the whole block, every job not done, the last one sent. 0
/// where nothing was: where `job` is 0, not sent or done - WaitGPUCompute
/// says which - or where the queue does not run; and where neither the
/// queue nor the block could be reset: every job not done on the block's
/// queues is given up then, the queues are stopped, and every call that
/// sends a job answers 0 from then on.
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
/// Where the scheduler does not remove the queue or map it again, or the
/// queue does not set the register it is tried with, the whole graphics
/// block is reset, since 1.24 - as the vendor's driver resets this block,
/// the power manager's 13.0.4 (soc21_asic_reset_method: MODE2,
/// smu_v13_0_4_mode2_reset), and resumes it (amdgpu_device_ip_resume) -
/// and at once with GPURESET_BLOCK, the queue's waves let finish first,
/// 100 ms at most. Under the DMA engine's queue's lock, the security
/// processor's, the page table's and the mailbox's, taken after the
/// compute queue's in that order, every job not done on the compute
/// engine is marked given up; the DMA engine is given 100 ms to finish
/// its jobs, then one more job of its own rinses the block's caches
/// (SDMA_OP_GCR_REQ: the second level written back and dropped), so that
/// what the compute engine's waves wrote through the cache is in memory
/// before the cache is lost; where the engine has not done both in time,
/// its jobs not done are given up. The engines are halted - the DMA
/// engine, the command processor's micro engines and the scheduler's
/// pipes - and the power manager resets the block alone
/// (GfxDeviceDriverReset with SMU_RESET_MODE_2), waited for 2 s at most.
/// The reset shuts the memory window: the bus block lets none of the
/// CPU's reads and writes there through (BIF_BX0_BIF_FB_EN), a read
/// answering all ones and a write going nowhere. So what the window let
/// through is read before the reset and set again once the power manager
/// answers, whatever its answer - the firmware's framebuffer is drawn
/// through the window. The security processor and its region are left as they are, as the
/// vendor's driver leaves them in a reset of a block with an IMU
/// (amdgpu_device_ip_suspend_phase2): it loads the IMU and the RLC again
/// from there, and the RLC the engines' code. Then the block is started
/// again as StartGPUGraphics starts it, the loading left out: kept
/// powered (SetGPUPower), its engines' code waited for, the hub turned on
/// over the page table it had - every mapping kept - its values set, the
/// RLC resumed and its clocks let gate. Last StartGPUDMA and
/// StartGPUCompute start both queues again in the memory they had, their
/// jobs' numbers going on and every job before read done, so that one
/// given up is answered false (WaitGPUDMA, WaitGPUCompute). Meanwhile the
/// queues' calls wait for the reset rather than take the queues as
/// stopped. The log says why the block was reset, the jobs given up, and
/// how long it took. The display engine and the video decoders are not
/// part of the block and run on.
///
/// CONTEXT:
/// - Waits: for the queue's waves to finish, 100 ms at most, and then for
///   it to be inactive, 100 ms at most; for each of the scheduler's two
///   calls, 2.1 s at most; for the ring's test, 100 ms at most - a few
///   milliseconds where all goes well, 100 more where a kernel's waves
///   run on. A reset of the whole block waits for the DMA engine, 200 ms
///   at most, for the power manager's reset, 2 s at most, and for the
///   block's start and its queues', each as its own call waits.
/// - Interrupts: no.
/// - Locks: takes the queue's lock; a reset of the whole block takes the
///   DMA engine's queue's, the security processor's, the page table's and
///   the mailbox's locks inside it, in that order.
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
/// arguments and its interrupt are kept as they are, through a reset of
/// the whole block too. A job of the DMA engine's that such a reset gives
/// up may have been done in part. On the NucBox the block runs again 65
/// to 74 ms after a reset of it begins - 1 to 10 waiting for the DMA
/// engine, 40 the power manager's reset, 24 the start - and 174 ms where
/// the DMA engine is held and given its 100; the display counts its
/// frames through it.
///
/// BUGS:
/// A job whose kernels the engine had begun but whose end it had not got
/// to is written again whole: its kernels write again what they wrote. A
/// block that does not come back from its reset is not reset again: its
/// queues stay stopped. Where the DMA engine does not finish in time, the
/// block's caches are lost unrinsed, and what the compute engine's waves
/// wrote through them may be lost with them.
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
    if (flags & amdgpu.GPURESET_BLOCK != 0) {
        const drained = drainQueue(ab);
        return resetBlock(ab, if (drained) "as asked, its waves finished" else "as asked, its waves running on after 100 ms");
    }

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
    if (!_compute.call(ab, &frame, _compute.remove_queue_status_at)) return resetBlock(ab, "the scheduler does not remove the queue");
    _compute.renewQueue(ab);
    frame = _compute.mapFrame(_compute.compute_queue, _compute.compute_doorbell, ab.compute.device + _compute.compute_mqd_at, ab.compute.device + _compute.compute_write_at);
    if (!_compute.call(ab, &frame, _compute.add_queue_status_at)) return resetBlock(ab, "the scheduler does not map the queue again");
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
        return resetBlock(ab, "the queue does not set a register");
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

/// The queue's waves let finish and no group of its dispatches started any
/// more, before a reset of the whole block asked for at once: its dequeue
/// asked in the RLC's safe mode (CP_HQD_DEQUEUE_REQUEST 1) and the queue
/// waited for to be inactive, 100 ms at most - the block is reset after,
/// whatever comes of it. Whether it was.
fn drainQueue(ab: *AMDGPUBase) bool {
    const safe = _graphics.enterSafeMode(ab);
    _compute.select(ab, _compute.compute_queue, 0);
    _graphics.at(ab, _compute.CP_HQD_DEQUEUE_REQUEST).* = _compute.DEQUEUE_DRAIN_PIPE;
    const inactive = inactiveWithin(ab, _compute.drain_most_us);
    _compute.select(ab, _compute.no_queue, 0);
    _graphics.leaveSafeMode(ab, safe);
    return inactive;
}

/// The whole graphics block reset and started again, its queues with it,
/// said with `why` - under the compute queue's lock, which the caller
/// holds, and the DMA queue's, the security processor's, the page table's
/// and the mailbox's, taken in that order: the number of the last job
/// given up, every one of the compute engine's not done; 0 where the
/// block does not come back, every queue stopped then
/// (`blockFailed`). The calls of the queues wait meanwhile rather than
/// take them as stopped (`resetting_block`).
fn resetBlock(ab: *AMDGPUBase, why: [*:0]const u8) u32 {
    const sys = ab.sys_base;
    const owner = amdgpu.AMDGPUNAME;
    const gpu: *sdk.interface.amdgpu.AMDGPUBase = @ptrCast(&ab.lib);
    const at = _graphics.at;
    const began = sys.UptimeUs();
    @atomicStore(bool, &ab.resetting_block, true, .release);
    defer @atomicStore(bool, &ab.resetting_block, false, .release);

    // Every job of the compute engine's not done given up: its queue is
    // made new.
    const sent = ab.compute_sent;
    const first = _compute.nextJob(_compute.done(ab));
    if (!_compute.passed(_compute.done(ab), sent)) _ = _compute.markGivenUp(ab, first, sent, true);

    // The DMA engine's jobs let finish and the block's caches rinsed by a
    // job of its own, so that what the compute engine's waves wrote
    // through the second level - the board's marks - is in memory before
    // the reset; where it does not do both in time, its jobs not done are
    // given up.
    sys.ObtainSemaphore(&ab.dma_lock);
    defer sys.ReleaseSemaphore(&ab.dma_lock);
    const dma = ab.dma_running;
    const dma_first = _dma.nextJob(_dma.done(ab));
    const rinsed = dma and finishDma(ab);
    if (dma and !rinsed) giveUpDma(ab);

    sys.ObtainSemaphore(&ab.security_lock);
    defer sys.ReleaseSemaphore(&ab.security_lock);
    sys.ObtainSemaphore(&ab.gart_lock);
    defer sys.ReleaseSemaphore(&ab.gart_lock);

    // The engines halted, as the vendor's driver halts them before the
    // reset (sdma_v6_0_hw_fini, gfx_v11_0_cp_enable, mes_v11_0_enable).
    if (dma) {
        at(ab, _dma.RB_CNTL).* &= ~_dma.RB_ENABLE;
        at(ab, _dma.F32_CNTL).* |= _dma.HALT;
    }
    at(ab, _compute.CP_MES_CNTL).* = at(ab, _compute.CP_MES_CNTL).* & ~(_compute.MES_PIPE0_ACTIVE | _compute.MES_PIPE1_ACTIVE) |
        _compute.MES_INVALIDATE_ICACHE | _compute.MES_PIPE0_RESET | _compute.MES_PIPE1_RESET | _compute.MES_HALT;
    at(ab, _compute.CP_ME_CNTL).* |= _compute.ME_HALT | _compute.PFP_HALT;
    at(ab, _compute.CP_MEC_CNTL).* |= _compute.MEC_ME1_HALT | _compute.MEC_ME2_HALT;

    // The block alone reset by the power manager (smu_v13_0_4_mode2_reset),
    // the security processor and its region left as they are: it loads the
    // IMU and the RLC again from there itself. The reset shuts the memory
    // window - the CPU's reads there answer all ones, its writes go
    // nowhere - which is let through again as it was once it answers,
    // whatever the answer.
    const window = _memory.windowOpen(ab);
    const reset_from = sys.UptimeUs();
    const finish_us = reset_from - began;
    const answer = blk: {
        sys.ObtainSemaphore(&ab.mailbox_lock);
        defer sys.ReleaseSemaphore(&ab.mailbox_lock);
        break :blk _power.sendWithin(ab, ab.power, _power.MESSAGE_RESET_GRAPHICS, _power.RESET_BLOCK_ALONE, _power.reset_most_us);
    };
    const reset_us = sys.UptimeUs() - reset_from;
    const window_shut = _memory.openWindow(ab, window);
    const done_right = if (answer) |given| given.answer == _power.ANSWER_DONE else false;
    if (!done_right) return blockFailed(ab, why, "the power manager does not reset it", dma, began);

    // The block started again as the vendor's driver resumes it after the
    // reset, the security processor's part left out (gfx_v11_0_hw_init):
    // kept powered, its engines' code waited for, the hub on over its page
    // table, the block's values, the RLC resumed and its clocks let gate.
    if (!gpu.SetGPUPower(amdgpu.GPUPOWER_GRAPHICS, 0, true)) return blockFailed(ab, why, "the power manager does not keep it powered", dma, began);
    if (!_graphics.waitForEngines(ab)) return blockFailed(ab, why, "its engines do not have their code again", dma, began);
    if (!_graphics.hubAgain(ab)) return blockFailed(ab, why, "its hub does not drop its TLB", dma, began);
    _graphics.tune(ab);
    if (!_graphics.resumeRlc(ab)) return blockFailed(ab, why, "its RLC is not resumed", dma, began);
    _graphics.gateClocks(ab);

    // Its queues started again, the DMA engine's first, each in the
    // memory it had, its jobs' numbers going on.
    if (dma) {
        ab.dma_running = false;
        if (!gpu.StartGPUDMA()) return blockFailed(ab, why, "the DMA engine's queue does not start again", true, began);
    }
    ab.compute_running = false;
    if (!gpu.StartGPUCompute()) return blockFailed(ab, why, "the compute engine's queue does not start again", dma, began);

    ab.block_resets +%= 1;
    ab.compute_resets +%= 1;
    ab.compute_given_up = sent;
    const back_us = sys.UptimeUs() - began;
    const start_us = back_us - finish_us - reset_us;
    const window_said: [*:0]const u8 = if (window_shut) "; the memory window, shut by the reset, let through again" else "";
    if (dma and !rinsed) {
        exec.kprintf(sys, "%s: the graphics block was reset whole (%s): the compute engine's jobs %u to %u given up, and the DMA engine's %u to %u, which it had not done within 100 ms, its caches not rinsed; it ran again %lu us on - %lu waiting for the DMA engine, %lu the power manager's reset, %lu starting the block and its queues again%s\n", .{
            owner, why, first, sent, dma_first, ab.dma_sent, back_us, finish_us, reset_us, start_us, window_said,
        });
    } else {
        const before: [*:0]const u8 = if (dma) "the DMA engine's jobs done and its caches rinsed first" else "no DMA queue to rinse its caches";
        exec.kprintf(sys, "%s: the graphics block was reset whole (%s): the compute engine's jobs %u to %u given up, %s; it ran again %lu us on - %lu waiting for the DMA engine, %lu the power manager's reset, %lu starting the block and its queues again%s\n", .{
            owner, why, first, sent, before, back_us, finish_us, reset_us, start_us, window_said,
        });
    }
    sys.SignalWaitable(&ab.compute_end);
    if (dma) sys.SignalWaitable(&ab.dma_trap);
    return sent;
}

/// The DMA engine's jobs let finish, then one more job of its own that
/// rinses the block's caches (`_dma.rinse`), each waited for 100 ms at
/// most, under the DMA queue's lock: whether the engine did both.
fn finishDma(ab: *AMDGPUBase) bool {
    if (!dmaDone(ab, ab.dma_sent)) return false;
    const number = _dma.nextJob(ab.dma_sent);
    _dma.putJob(ab, &_dma.rinse(), number);
    _dma.tell(ab);
    ab.dma_sent = number;
    return dmaDone(ab, number);
}

/// Whether the DMA engine has done job `job` within `finish_most_us`.
fn dmaDone(ab: *AMDGPUBase, job: u32) bool {
    const sys = ab.sys_base;
    const until = sys.UptimeUs() + finish_most_us;
    while (!_dma.passed(_dma.done(ab), job)) {
        if (sys.UptimeUs() > until) return false;
        _compute.pause(ab, 100);
    }
    return true;
}

/// The DMA engine's jobs not done given up: those after the last done up
/// to the last sent, which WaitGPUDMA answers false once their numbers
/// read done.
fn giveUpDma(ab: *AMDGPUBase) void {
    const last = _dma.done(ab);
    if (_dma.passed(last, ab.dma_sent)) return;
    @atomicStore(u32, &ab.dma_lost_after, last, .release);
    @atomicStore(u32, &ab.dma_given_up, ab.dma_sent, .release);
}

/// A reset of the whole block begun at `began` that did not bring it
/// back, said with `why` it was reset and `what` failed: the DMA engine's
/// queue, where `dma` says it ran, stopped with every job not done given
/// up and read done, the block taken as failed, and the compute engine's
/// queue stopped as `failed` stops it. 0, for the caller to answer.
fn blockFailed(ab: *AMDGPUBase, why: [*:0]const u8, what: [*:0]const u8, dma: bool, began: u64) u32 {
    const sys = ab.sys_base;
    exec.kprintf(sys, "%s: the graphics block is not reset whole (%s) - %s, %lu us on: its queues are stopped\n", .{ amdgpu.AMDGPUNAME, why, what, sys.UptimeUs() - began });
    if (dma) {
        giveUpDma(ab);
        _dma.word(ab, _dma.fence_at).* = ab.dma_sent;
        _dma.fence();
        ab.dma_running = false;
        ab.dma_failed = true;
        sys.SignalWaitable(&ab.dma_trap);
    }
    ab.graphics_started = false;
    ab.graphics_failed = true;
    return failed(ab, "the block is not reset whole");
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
