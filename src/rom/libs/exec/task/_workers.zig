// SPDX-License-Identifier: MPL-2.0
//! The workers: a task on each core, pinned to it, that does its part of
//! a job another task shares out between the cores (ShareWork), and the
//! jobs tasks post to run beside them (PostWork, SINCE 1.27). exec's own
//! long cache write-backs are shared through them too (cache/_cache.zig),
//! and so is the drawing of a display board that has no engine but the
//! cores.
//!
//! They are made by the exec task, once multitasking runs, and live for
//! good: a worker waits on a signal of its own, does what it was handed,
//! and waits again. A worker runs at the priority of the task whose job it
//! does.
//!
//! **Shared jobs.** The task that shares a job does part 0 itself, hands a
//! part to each idle worker of the other cores, and waits until the last
//! of them has counted itself out and signalled it. One shared job at a
//! time: one shared while another is under way is done by its asker alone,
//! rather than waiting for the cores; so is one shared from where a task
//! may not wait - an interrupt, inside Disable, holding a spinlock, before
//! multitasking, an idle task - since its asker waits for the workers, and
//! one shared while every other core's worker runs posted jobs. Whatever
//! is shared from within a part - a write-back a part asks for - is then
//! done alone as well.
//!
//! **Posted jobs** queue by priority - the poster's - and a worker that
//! has nothing to do takes the first: PostWork wakes an idle worker,
//! another core's before the poster's own, and a worker done with a part
//! or a job looks at the queue before it waits again. A worker running
//! posted jobs is not handed a part: a job is not cut short, and a shared
//! job does without it. With one core the poster runs its job itself.
//!
//! What a worker is about - idle, a part, posted jobs - and the queue are
//! under one spinlock, `job_lock`: a worker is claimed under it, by
//! ShareWork for a part or by PostWork for the queue, so no two claim one.

const sdk = @import("sdk");
const exec_base = @import("../exec_base.zig");
const _interrupt = @import("../interrupt/_interrupt.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Task = sdk.exec.Task;
const SignalSemaphore = sdk.exec.SignalSemaphore;
const WorkFn = sdk.exec.WorkFn;
const WorkJob = sdk.exec.WorkJob;
const SIGF_SINGLE = sdk.exec.tasks.SIGF_SINGLE;
const max_cores = exec_base.max_cores;

/// Each worker's stack, the standard one: a part and a posted job run on
/// it.
pub const worker_stack = 4096 * @sizeOf(usize);

/// The job lock's place: after every lock a program or a driver holds -
/// PostWork may be called holding one - and before exec's own.
pub const order_jobs: u16 = sdk.exec.LOCKORDER_SYSTEM + 50;

/// What a worker is about. Changed under the job lock.
pub const State = enum(u32) {
    /// Waiting: a part or the queue may claim it.
    idle,
    /// Claimed by ShareWork for a part of the job under way.
    part,
    /// Running posted jobs until the queue is empty.
    jobs,
};

const worker_names = [4][*:0]const u8{ "exec worker 0", "exec worker 1", "exec worker 2", "exec worker 3" };

pub const Worker = extern struct {
    task: ?*Task = null,
    /// The core it is pinned to.
    core: u32 = 0,
    /// The signal it waits for a part on.
    go: u32 = 0,
    /// Its part of the job under way.
    part: u32 = 0,
    state: State = .idle,
    /// Set by ShareWork once the part is ready to be done - after the job's
    /// fields, before the signal - and taken by the worker: the claim alone
    /// comes before the job is filled in.
    handed: u32 = 0,
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
    /// Posted jobs not yet taken, by priority, and the lock over them and
    /// the workers' states.
    jobs: sdk.exec.List = .{},
    job_lock: sdk.exec.Lock = .{},
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
        serve(sys, pool, worker);
    }
}

/// What a woken worker does until there is nothing left: its part, when
/// ShareWork claimed it, and the posted jobs queued. It goes idle when the
/// queue is empty - under the job lock, so a job posted after that wakes
/// it again.
fn serve(sys: *sdk.interface.exec.ExecBase, pool: *Pool, worker: *Worker) void {
    while (true) {
        if (@atomicRmw(u32, &worker.handed, .Xchg, 0, .acq_rel) != 0) {
            pool.work.?(pool.data, worker.part, pool.parts);
            sys.AcquireLock(&pool.job_lock);
            worker.state = .idle;
            sys.ReleaseLock(&pool.job_lock);
            finished(sys, pool);
            continue;
        }
        // Claimed for a part meanwhile: its signal is on its way.
        const job = take(sys, pool, worker) orelse return;
        const task = worker.task.?;
        if (task.node.pri != job.message.node.pri) _ = sys.SetTaskPri(task, job.message.node.pri);
        run(sys, job);
    }
}

/// The first posted job for `worker`, which then runs posted jobs; null
/// when the queue is empty - the worker idle - or ShareWork claimed it for
/// a part.
pub fn take(sys: *sdk.interface.exec.ExecBase, pool: *Pool, worker: *Worker) ?*WorkJob {
    sys.AcquireLock(&pool.job_lock);
    defer sys.ReleaseLock(&pool.job_lock);
    if (worker.state == .part) return null;
    const node = sys.RemHead(&pool.jobs) orelse {
        worker.state = .idle;
        return null;
    };
    worker.state = .jobs;
    const message: *sdk.exec.Message = @fieldParentPtr("node", node);
    return @fieldParentPtr("message", message);
}

/// A job's code run and the job replied: from then on it is its poster's
/// again, and not looked at.
fn run(sys: *sdk.interface.exec.ExecBase, job: *WorkJob) void {
    job.work(job);
    sys.ReplyMsg(&job.message);
}

/// `job` posted: queued at the poster's priority, and an idle worker woken
/// for it - another core's before the poster's own. With no idle worker
/// it waits for the first that is done. Without workers - one core,
/// before multitasking - the poster runs it at once.
pub fn post(base: *ExecBase, job: *WorkJob) void {
    const sys = base.iface();
    const pool = &base.workers;
    job.message.node.type = .message;
    job.message.node.pri = sys.FindTask(null).?.node.pri;
    if (pool.count < 2) {
        run(sys, job);
        return;
    }
    sys.AcquireLock(&pool.job_lock);
    sys.Enqueue(&pool.jobs, &job.message.node);
    const woken = idleWorker(pool, exec_base.coreId());
    if (woken) |worker| worker.state = .jobs;
    sys.ReleaseLock(&pool.job_lock);
    if (woken) |worker| sys.Signal(worker.task.?, worker.go);
}

/// An idle worker, one of a core other than `here` if there is one. Under
/// the job lock.
fn idleWorker(pool: *Pool, here: u32) ?*Worker {
    var found: ?*Worker = null;
    for (pool.workers[0..pool.count]) |*worker| {
        if (worker.state != .idle) continue;
        if (worker.core != here) return worker;
        found = worker;
    }
    return found;
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
    initQueue(base);
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
    // Idle ones only, claimed: a worker running posted jobs is not waited
    // for.
    sys.AcquireLock(&pool.job_lock);
    for (pool.workers[0..pool.count]) |*worker| {
        if (helpers + 1 >= wanted) break;
        if (worker.core == here or worker.state != .idle) continue;
        worker.state = .part;
        chosen[helpers] = worker;
        helpers += 1;
    }
    sys.ReleaseLock(&pool.job_lock);
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
        @atomicStore(u32, &worker.handed, 1, .release);
        sys.Signal(task, worker.go);
    }
    work(data, 0, pool.parts);
    join(sys, pool);
    return helpers + 1;
}

/// The queue of posted jobs and its lock, empty.
pub fn initQueue(base: *ExecBase) void {
    const pool = &base.workers;
    pool.jobs.init(.message);
    base.iface().InitLock(&pool.job_lock, "exec jobs", order_jobs, 0);
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
