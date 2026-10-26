// SPDX-License-Identifier: MIT
//! SemTest: exec's semaphores, timed and against each other.
//!
//!   SemTest SECONDS/N,TASKS/N,PIN/S
//!
//! **Timed**, on this task alone: an ObtainSemaphore and its release, the
//! same shared, an AttemptSemaphore and its release, and - beside them -
//! an AcquireLock and its release, each 100000 times: what a pair costs
//! with nothing in the way. Then TASKS workers for a second each: every
//! one on a semaphore of its own, which no other core touches - the pairs
//! of all of them should add up, as nothing is shared - and all of them
//! on one.
//!
//! **Against each other**, for SECONDS: the workers - on whichever core
//! is free, or pinned to the cores in turn with PIN - take one semaphore
//! every way there is, chosen at random each round: exclusively, around a
//! section that checks it is alone in it; shared, around a look that no
//! exclusive holder is inside; the exclusive holder taking it again, of
//! either kind; AttemptSemaphore and AttemptSemaphoreShared; two
//! semaphores, in their order; and a bid with Procure, waited for at the
//! worker's port and given back with Vacate.
//!
//! What it checks: no two workers are ever in the exclusive section at
//! once, and no reader with a writer; the counts each section keeps
//! inside it - added to without any care - come out as the sum of what
//! the workers counted; every semaphore is free at the end, with nobody
//! queued; and each worker's tables of what it holds are empty as it
//! ends. A second in which no worker got anywhere is a semaphore that
//! was never handed on.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const TimerBase = sdk.interface.timer.TimerBase;
const Task = exec.Task;
const Printf = dos.stdio.Printf;

const NAME = "SemTest";
const VERSION_STRING = "\x00$VER: SemTest 1.0 (26.10.2026)\r\n";
const TEMPLATE = "SECONDS/N,TASKS/N,PIN/S";

const default_seconds = 10;
const default_tasks = 4;
const max_tasks = 8;
const worker_stack = sdk.dos.CLI_DEFAULT_STACK;
/// How often each timed pair runs.
const timed_rounds = 100_000;
/// How many times a worker looks, inside a section, whether it is still
/// alone there: long enough for another core to come in if it could.
const section_looks = 32;

/// A section a worker must be alone in: who is inside (a worker's number
/// and one, or 0), how often it was entered, counted inside without any
/// care, and how often a worker found another inside.
const Section = struct {
    inside: u32 = 0,
    count: u32 = 0,
    overlaps: u32 = 0,
};

/// What a worker does with the semaphores, chosen each round.
const Way = enum(u8) { exclusive, shared, nested, attempt, attempt_shared, pair, procure, procure_shared };
const way_names = [_][*:0]const u8{ "exclusive", "shared", "nested", "attempt", "attempt shared", "two in order", "Procure", "Procure shared" };
const ways = way_names.len;

/// What the workers of a batch do.
const Mode = enum { own, one, mixed };

const Worker = struct {
    task: ?*Task = null,
    /// Its own semaphore, for the batch where nothing is shared.
    own: exec.SignalSemaphore = undefined,
    pairs: u64 align(8) = 0,
    done: [ways]u32 = @splat(0),
    /// Attempts that found the semaphore held, not counted in `done`.
    refused: u32 = 0,
    /// Reads that found a writer inside.
    torn: u32 = 0,
    /// Its tables held something as it ended.
    left_held: bool = false,
    ended: exec.Message = .{},
};

const Run = struct {
    mode: Mode = .mixed,
    workers: [max_tasks]Worker = @splat(.{}),
    count: u32 = 0,
    sem: exec.SignalSemaphore = undefined,
    second: exec.SignalSemaphore = undefined,
    /// The exclusive holders' section on `sem`, and the pair's on both.
    section: Section = .{},
    pair: Section = .{},
    /// Readers inside `sem` shared.
    readers: u32 = 0,
    go_signal: u32 = 0,
    stop: bool = false,
};
var run: Run = .{};

/// `section` entered by worker `number`, which holds its lock: alone, it
/// says so, looks again and again that nobody else came in - nor a
/// reader - counts and leaves.
fn occupy(section: *Section, number: u32) void {
    const shared: *volatile Section = section;
    const me = number + 1;
    if (shared.inside != 0) shared.overlaps +%= 1;
    shared.inside = me;
    for (0..section_looks) |_| {
        if (shared.inside != me or @atomicLoad(u32, &run.readers, .acquire) != 0) shared.overlaps +%= 1;
    }
    shared.count +%= 1;
    shared.inside = 0;
}

/// A shared holder's look: no exclusive holder inside while it is.
fn read(worker: *Worker) void {
    _ = @atomicRmw(u32, &run.readers, .Add, 1, .acq_rel);
    const section: *volatile Section = &run.section;
    for (0..section_looks / 4) |_| {
        if (section.inside != 0) worker.torn += 1;
    }
    _ = @atomicRmw(u32, &run.readers, .Sub, 1, .acq_rel);
}

fn numberOf(task: *Task) u32 {
    for (run.workers[0..run.count], 0..) |*worker, number| {
        if (worker.task == task) return @intCast(number);
    }
    unreachable;
}

fn workerCode(sys: *ExecBase) callconv(.c) void {
    _ = sys.Wait(run.go_signal);
    const me = sys.FindTask(null).?;
    const number = numberOf(me);
    const worker = &run.workers[number];
    const stop: *volatile bool = &run.stop;
    switch (run.mode) {
        .own, .one => {
            const sem = if (run.mode == .own) &worker.own else &run.sem;
            while (!stop.*) {
                sys.ObtainSemaphore(sem);
                sys.ReleaseSemaphore(sem);
                @as(*volatile u64, &worker.pairs).* += 1;
            }
        },
        .mixed => mixed(sys, worker, number),
    }
    for ([_][]const exec.SemaphoreHold{ &me.holds, &me.bid_holds }) |table| {
        for (table) |*hold| {
            if (hold.semaphore != null) worker.left_held = true;
        }
    }
    if (me.holds_lost != 0 or me.bid_holds_lost != 0) worker.left_held = true;
}

/// The semaphores taken every way, at random, until the stop.
fn mixed(sys: *ExecBase, worker: *Worker, number: u32) void {
    const port = sys.CreateMsgPort() orelse return;
    defer sys.DeleteMsgPort(port);
    const stop: *volatile bool = &run.stop;
    var seed: u32 = 0x9E37_79B9 *% (number + 1);
    while (!stop.*) {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        const way: Way = @enumFromInt(seed % ways);
        switch (way) {
            .exclusive => {
                sys.ObtainSemaphore(&run.sem);
                occupy(&run.section, number);
                sys.ReleaseSemaphore(&run.sem);
            },
            .shared => {
                sys.ObtainSemaphoreShared(&run.sem);
                read(worker);
                sys.ReleaseSemaphore(&run.sem);
            },
            .nested => {
                sys.ObtainSemaphore(&run.sem);
                sys.ObtainSemaphoreShared(&run.sem);
                if (!sys.AttemptSemaphore(&run.sem)) worker.torn += 1; // its own: always had
                occupy(&run.section, number);
                sys.ReleaseSemaphore(&run.sem);
                sys.ReleaseSemaphore(&run.sem);
                sys.ReleaseSemaphore(&run.sem);
            },
            .attempt => {
                if (!sys.AttemptSemaphore(&run.sem)) {
                    worker.refused += 1;
                    continue;
                }
                occupy(&run.section, number);
                sys.ReleaseSemaphore(&run.sem);
            },
            .attempt_shared => {
                if (!sys.AttemptSemaphoreShared(&run.sem)) {
                    worker.refused += 1;
                    continue;
                }
                read(worker);
                sys.ReleaseSemaphore(&run.sem);
            },
            .pair => {
                sys.ObtainSemaphore(&run.sem);
                sys.ObtainSemaphore(&run.second);
                occupy(&run.pair, number);
                occupy(&run.section, number);
                sys.ReleaseSemaphore(&run.second);
                sys.ReleaseSemaphore(&run.sem);
            },
            .procure, .procure_shared => {
                const shared = way == .procure_shared;
                var bid = exec.SemaphoreMessage.init(port, shared);
                sys.Procure(&run.sem, &bid);
                while (sys.GetMsg(port) == null) _ = sys.WaitPort(port);
                if (shared) read(worker) else occupy(&run.section, number);
                sys.Vacate(&run.sem, &bid);
            },
        }
        worker.done[@intFromEnum(way)] += 1;
    }
}

/// The E-clock in nanoseconds.
fn nanoseconds(timer_base: *TimerBase) u64 {
    var value: timer.EClockVal = .{};
    const rate: u64 = timer_base.ReadEClock(&value);
    const count = @as(u64, value.hi) << 32 | value.lo;
    return count / rate * 1_000_000_000 + count % rate * 1_000_000_000 / rate;
}

/// One pair `timed_rounds` times, and what each took.
fn timed(dl: *DosBase, timer_base: *TimerBase, what: [*:0]const u8, comptime pair: fn (*ExecBase, *exec.SignalSemaphore, *exec.Lock) void, sys: *ExecBase, sem: *exec.SignalSemaphore, lock: *exec.Lock) void {
    const started = nanoseconds(timer_base);
    for (0..timed_rounds) |_| pair(sys, sem, lock);
    const took = nanoseconds(timer_base) - started;
    const tenths: u32 = @intCast(took * 10 / timed_rounds);
    _ = Printf(dl, "  %-26s %5u.%u ns\n", .{ what, tenths / 10, tenths % 10 });
}

fn obtainPair(sys: *ExecBase, sem: *exec.SignalSemaphore, _: *exec.Lock) void {
    sys.ObtainSemaphore(sem);
    sys.ReleaseSemaphore(sem);
}

fn sharedPair(sys: *ExecBase, sem: *exec.SignalSemaphore, _: *exec.Lock) void {
    sys.ObtainSemaphoreShared(sem);
    sys.ReleaseSemaphore(sem);
}

fn attemptPair(sys: *ExecBase, sem: *exec.SignalSemaphore, _: *exec.Lock) void {
    if (sys.AttemptSemaphore(sem)) sys.ReleaseSemaphore(sem);
}

fn lockPair(sys: *ExecBase, _: *exec.SignalSemaphore, lock: *exec.Lock) void {
    sys.AcquireLock(lock);
    sys.ReleaseLock(lock);
}

/// A batch of workers in `mode` for `seconds`: made, pinned when asked,
/// let go together, stopped and waited for. False when a second passed
/// in which none of them got anywhere - they are waited for all the same,
/// since their code is this program's.
fn batch(sys: *ExecBase, dl: *DosBase, mode: Mode, wanted: u32, seconds: u32, pin: bool, cores: u32) bool {
    const ended = sys.CreateMsgPort() orelse return false;
    defer sys.DeleteMsgPort(ended);
    run.mode = mode;
    run.stop = false;
    run.count = 0;
    run.workers = @splat(.{});
    var names: [max_tasks][16:0]u8 = undefined;
    for (0..wanted) |number| {
        const name = &names[number];
        @memcpy(name[0..13], "SemTest task ");
        name[13] = '0' + @as(u8, @intCast(number));
        name[14] = 0;
        const worker = &run.workers[number];
        sys.InitSemaphore(&worker.own);
        const task = sys.CreateTask(@ptrCast(name), -1, &workerCode, worker_stack) orelse break;
        worker.ended = .{ .reply_port = ended };
        sys.SetTaskEndMsg(task, &worker.ended);
        if (pin) _ = sys.SetTaskAffinity(task, exec.coreFlag(@intCast(number % cores)));
        worker.task = task;
        run.count += 1;
    }
    for (run.workers[0..run.count]) |*worker| sys.Signal(worker.task.?, run.go_signal);

    var moving = true;
    var last: u64 = 0;
    for (0..seconds) |_| {
        dl.Delay(50);
        const now = progress();
        if (now == last) moving = false;
        last = now;
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) break;
    }
    if (!moving) {
        _ = Printf(dl, "FAILED: the workers stopped - state 0x%08x, 0x%08x\n", .{ run.sem.state, run.second.state });
        _ = dl.Flush(dl.Output());
    }
    @as(*volatile bool, &run.stop).* = true;
    var gone: u32 = 0;
    while (gone < run.count) {
        _ = sys.WaitPort(ended);
        while (sys.GetMsg(ended)) |_| gone += 1;
    }
    return moving;
}

/// What the workers have done so far.
fn progress() u64 {
    var total: u64 = 0;
    for (run.workers[0..run.count]) |*worker| {
        total += @as(*volatile u64, &worker.pairs).*;
        for (&worker.done) |*done| total += @as(*volatile u32, done).*;
    }
    return total;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(TEMPLATE, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const seconds_given = dos.rdargs.number(argv[0]) orelse default_seconds;
    const tasks_given = dos.rdargs.number(argv[1]) orelse default_tasks;
    const pin = argv[2] != 0;
    if (tasks_given < 2 or tasks_given > max_tasks or seconds_given < 1) {
        _ = Printf(dl, "%s: TASKS is 2 to %u, SECONDS at least 1\n", .{ @as([*:0]const u8, NAME), @as(u32, max_tasks) });
        return dos.RETURN_ERROR;
    }
    const seconds: u32 = @intCast(seconds_given);
    const wanted: u32 = @intCast(tasks_given);

    var clock: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &clock.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&clock.node);
    const timer_base: *TimerBase = @ptrCast(@alignCast(clock.node.device.?));

    run = .{};
    run.go_signal = @as(u32, 1) << 30;
    sys.InitSemaphore(&run.sem);
    sys.InitSemaphore(&run.second);
    var cores: u32 = 0;
    var times: exec.CoreTimes = .{};
    while (cores < 4 and sys.ReadCoreTimes(cores, &times)) cores += 1;
    cores = @max(cores, 1);

    // Each pair alone.
    _ = Printf(dl, "A pair, alone (%u times):\n", .{@as(u32, timed_rounds)});
    var sem: exec.SignalSemaphore = undefined;
    sys.InitSemaphore(&sem);
    var lock: exec.Lock = .{};
    sys.InitLock(&lock, "SemTest", exec.LOCKORDER_DRIVER, 0);
    timed(dl, timer_base, "ObtainSemaphore+Release", obtainPair, sys, &sem, &lock);
    timed(dl, timer_base, "ObtainSemaphoreShared+Rel.", sharedPair, sys, &sem, &lock);
    timed(dl, timer_base, "AttemptSemaphore+Release", attemptPair, sys, &sem, &lock);
    timed(dl, timer_base, "AcquireLock+ReleaseLock", lockPair, sys, &sem, &lock);
    _ = dl.Flush(dl.Output());

    // Many at once: each on its own, then all on one.
    var failed = false;
    for ([_]Mode{ .own, .one }) |mode| {
        const started = nanoseconds(timer_base);
        if (!batch(sys, dl, mode, wanted, 1, pin, cores)) failed = true;
        const took = @max(nanoseconds(timer_base) - started, 1);
        var pairs: u64 = 0;
        for (run.workers[0..run.count]) |*worker| pairs += worker.pairs;
        const per_second: u64 = pairs * 1_000_000_000 / took;
        _ = Printf(dl, "%u tasks, %s: %lu pairs a second\n", .{
            run.count,
            @as([*:0]const u8, if (mode == .own) "a semaphore each" else "all on one"),
            per_second,
        });
        _ = dl.Flush(dl.Output());
    }

    // Against each other.
    _ = Printf(dl, "%u tasks%s against each other for %u seconds\n", .{ wanted, @as([*:0]const u8, if (pin) ", pinned to the cores in turn" else ""), seconds });
    _ = dl.Flush(dl.Output());
    if (!batch(sys, dl, .mixed, wanted, seconds, pin, cores)) failed = true;

    var done: [ways]u32 = @splat(0);
    var refused: u32 = 0;
    var torn: u32 = 0;
    var left: u32 = 0;
    for (run.workers[0..run.count]) |*worker| {
        for (&done, worker.done) |*sum, each| sum.* += each;
        refused += worker.refused;
        torn += worker.torn;
        left += @intFromBool(worker.left_held);
    }
    for (way_names, done) |way_name, count| _ = Printf(dl, "  %-16s %8u\n", .{ way_name, count });
    const exclusive_entries = done[@intFromEnum(Way.exclusive)] + done[@intFromEnum(Way.nested)] + done[@intFromEnum(Way.attempt)] +
        done[@intFromEnum(Way.pair)] + done[@intFromEnum(Way.procure)];
    const sections_right = run.section.overlaps == 0 and run.section.count == exclusive_entries and
        run.pair.overlaps == 0 and run.pair.count == done[@intFromEnum(Way.pair)];
    _ = Printf(dl, "%-12s %u entered, %u counted inside, %u overlaps  %s\n", .{
        @as([*:0]const u8, "Exclusive"), exclusive_entries, run.section.count, run.section.overlaps, @as([*:0]const u8, if (sections_right) "ok" else "FAILED"),
    });
    _ = Printf(dl, "%-12s %u reads saw a writer, %u attempts refused  %s\n", .{
        @as([*:0]const u8, "Shared"), torn, refused, @as([*:0]const u8, if (torn == 0) "ok" else "FAILED"),
    });
    const free = run.sem.state == 0 and run.second.state == 0 and run.sem.wait_queue.isEmpty() and run.second.wait_queue.isEmpty();
    _ = Printf(dl, "%-12s state 0x%08x and 0x%08x, %u tasks ended holding  %s\n", .{
        @as([*:0]const u8, "At the end"), run.sem.state, run.second.state, left, @as([*:0]const u8, if (free and left == 0) "ok" else "FAILED"),
    });
    if (!sections_right or torn != 0 or !free or left != 0) failed = true;
    _ = Printf(dl, "%s\n", .{@as([*:0]const u8, if (failed) "FAILED" else "passed")});
    return if (failed) dos.RETURN_FAIL else dos.RETURN_OK;
}

/// The "$VER:" string, kept by program.ld's `.version`.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
