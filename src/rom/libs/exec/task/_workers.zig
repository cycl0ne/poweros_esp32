// SPDX-License-Identifier: MPL-2.0
//! The workers: a task on each core, pinned to it, that does its part of
//! a job another task shares out between the cores (ShareWork). exec's
//! own long cache write-backs are shared through them too
//! (cache/_cache.zig), and so is the drawing of a display board that has
//! no engine but the cores.
//!
//! They are made by the exec task, once multitasking runs, and live for
//! good: a worker waits on a signal of its own, does its part, counts
//! itself out, and waits again. The task that shares a job does part 0
//! itself, hands a part to the worker of each other core, and waits until
//! the last of them has counted itself out and signalled it. A worker
//! runs at the priority of the task whose job it does.
//!
//! One job at a time. A job shared while another is under way is done by
//! its asker alone, rather than waiting for the cores; so is one shared
//! from where a task may not wait - an interrupt, inside Disable, holding
//! a spinlock, before multitasking, an idle task - since its asker waits
//! for the workers. Whatever is shared from within a part - a write-back
//! a part asks for - is then done alone as well.

const sdk = @import("sdk");
const exec_base = @import("../exec_base.zig");
const _interrupt = @import("../interrupt/_interrupt.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Task = sdk.exec.Task;
const SignalSemaphore = sdk.exec.SignalSemaphore;
const WorkFn = sdk.exec.WorkFn;
const SIGF_SINGLE = sdk.exec.tasks.SIGF_SINGLE;
const max_cores = exec_base.max_cores;

/// Each worker's stack: a part runs on it.
const worker_stack = 16 * 1024;

const worker_names = [4][*:0]const u8{ "exec worker 0", "exec worker 1", "exec worker 2", "exec worker 3" };

const Worker = extern struct {
    task: ?*Task = null,
    /// The core it is pinned to.
    core: u32 = 0,
    /// The signal it waits for a part on.
    go: u32 = 0,
    /// Its part of the job under way.
    part: u32 = 0,
};

/// The workers, in ExecBase.
pub const Pool = extern struct {
    /// Held while a job is shared out.
    lock: SignalSemaphore = .{},
    workers: [max_cores]Worker = @splat(.{}),
    /// How many there are: none until the exec task has made them, and on
    /// a machine with one core.
    count: u32 = 0,
    /// The job under way, how many parts it is in, the task that shared
    /// it, and how many workers are still at it.
    work: ?WorkFn = null,
    data: ?*anyopaque = null,
    parts: u32 = 0,
    asker: ?*Task = null,
    remaining: u32 = 0,
};

/// A worker's code. It waits until it has been told which worker it is,
/// takes a signal, and counts itself in; then it does its part of each
/// job it is handed.
fn workerCode(sys: *sdk.interface.exec.ExecBase) callconv(.c) void {
    const base: *ExecBase = @ptrCast(@alignCast(sys));
    const pool = &base.workers;
    const me = sys.FindTask(null).?;
    while (@atomicLoad(?*anyopaque, &me.user_data, .acquire) == null) _ = sys.Wait(SIGF_SINGLE);
    const worker: *Worker = @ptrCast(@alignCast(me.user_data.?));
    const bit = sys.AllocSignal(-1);
    worker.go = if (bit < 0) SIGF_SINGLE else @as(u32, 1) << @intCast(bit);
    finished(sys, pool);
    while (true) {
        _ = sys.Wait(worker.go);
        pool.work.?(pool.data, worker.part, pool.parts);
        finished(sys, pool);
    }
}

/// A worker's part done: counted out, and the asker told by the last.
/// Who to tell is read first - once the count is out, the asker may go on.
fn finished(sys: *sdk.interface.exec.ExecBase, pool: *Pool) void {
    const asker = pool.asker.?;
    if (@atomicRmw(u32, &pool.remaining, .Sub, 1, .acq_rel) == 1) sys.Signal(asker, SIGF_SINGLE);
}

/// Until every worker handed something has counted itself out.
fn join(sys: *sdk.interface.exec.ExecBase, pool: *Pool) void {
    while (@atomicLoad(u32, &pool.remaining, .acquire) != 0) _ = sys.Wait(SIGF_SINGLE);
    _ = sys.SetSignal(0, SIGF_SINGLE);
}

/// A worker on each core that runs, pinned to it: what the exec task does
/// first. None on a machine with one core, or when they cannot all be
/// made; every job is then its asker's.
pub fn setUp(base: *ExecBase) void {
    const sys = base.iface();
    const pool = &base.workers;
    sys.InitSemaphore(&pool.lock);
    var cores: u32 = 0;
    var times: sdk.exec.CoreTimes = .{};
    for (0..max_cores) |core| {
        if (!sys.ReadCoreTimes(@intCast(core), &times)) continue;
        pool.workers[cores] = .{ .core = @intCast(core) };
        cores += 1;
    }
    if (cores < 2) return;
    pool.asker = sys.FindTask(null);
    _ = sys.SetSignal(0, SIGF_SINGLE);
    @atomicStore(u32, &pool.remaining, cores, .release);
    var made: u32 = 0;
    sys.BeginSystemMemory();
    for (pool.workers[0..cores]) |*worker| {
        const task = sys.CreateTask(worker_names[worker.core], 0, &workerCode, worker_stack) orelse break;
        _ = sys.SetTaskAffinity(task, sdk.exec.coreFlag(worker.core));
        worker.task = task;
        @atomicStore(?*anyopaque, &task.user_data, worker, .release);
        sys.Signal(task, SIGF_SINGLE);
        made += 1;
    }
    sys.EndSystemMemory();
    // The ones not made will not count themselves in.
    if (made < cores) _ = @atomicRmw(u32, &pool.remaining, .Sub, cores - made, .acq_rel);
    join(sys, pool);
    // Fewer than one a core would leave a core out of every job: the
    // workers made wait for good, and every job is its asker's.
    if (made == cores) pool.count = made;
}

/// `work` done in as many as `wanted` parts, shared between the asker and
/// the workers of the other cores; the parts it was done in. Alone - one
/// part - when one is asked for, there are no workers, they are busy, or
/// the asker may not wait.
pub fn share(base: *ExecBase, work: WorkFn, data: ?*anyopaque, wanted: u32) u32 {
    const pool = &base.workers;
    if (wanted < 2 or pool.count < 2 or !canWait(base)) return alone(work, data);
    const sys = base.iface();
    if (!sys.AttemptSemaphore(&pool.lock)) return alone(work, data);
    defer sys.ReleaseSemaphore(&pool.lock);
    // Shared again from within a part of the job under way, by its asker:
    // the workers are at the first.
    if (@atomicLoad(u32, &pool.remaining, .acquire) != 0) return alone(work, data);
    const me = sys.FindTask(null).?;
    // Where the asker is now; should it move, a worker shares its core,
    // which is slower but no less right.
    const here = exec_base.coreId();
    var chosen: [max_cores]*Worker = undefined;
    var helpers: u32 = 0;
    for (pool.workers[0..pool.count]) |*worker| {
        if (helpers + 1 >= wanted) break;
        if (worker.core == here) continue;
        chosen[helpers] = worker;
        helpers += 1;
    }
    if (helpers == 0) return alone(work, data);
    pool.work = work;
    pool.data = data;
    pool.parts = helpers + 1;
    pool.asker = me;
    _ = sys.SetSignal(0, SIGF_SINGLE);
    @atomicStore(u32, &pool.remaining, helpers, .release);
    for (chosen[0..helpers], 1..) |worker, part| {
        worker.part = @intCast(part);
        const task = worker.task.?;
        if (task.node.pri != me.node.pri) _ = sys.SetTaskPri(task, me.node.pri);
        sys.Signal(task, worker.go);
    }
    work(data, 0, pool.parts);
    join(sys, pool);
    return helpers + 1;
}

fn alone(work: WorkFn, data: ?*anyopaque) u32 {
    work(data, 0, 1);
    return 1;
}

/// Whether the calling code may wait for the workers: a task other than
/// a core's idle task, multitasking running, and none of an interrupt,
/// Disable or a spinlock about it. Read with the core's interrupts masked,
/// so the state is the core's the caller is on.
fn canWait(base: *ExecBase) bool {
    if (base.multitasking == 0) return false;
    const hardware = _interrupt.interrupt_hardware;
    const state = hardware.disable();
    defer hardware.restore(state);
    const cpu = base.cpu();
    if (cpu.int_depth != 0 or cpu.id_nest_cnt >= 0) return false;
    if (cpu.lock_count != 0 or cpu.hold_count != 0) return false;
    return cpu.idle_task != cpu.this_task;
}
