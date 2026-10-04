// SPDX-License-Identifier: MIT
//! Cores: the two cores against each other.
//!
//! Worker tasks - as many as TASKS says, on whichever core is free, or
//! half pinned to each with PIN - go round every way exec keeps code
//! apart, for SECONDS: Forbid, Disable, a semaphore and a spinlock, each
//! around a section that checks it is alone in it; memory allocated,
//! filled, checked and freed; and a ring of signals, each worker passing
//! a token on to the next and waiting for one from the one before. The
//! ring keeps the workers nearly in step; FREE leaves it out, and they
//! run flat out against each other on both cores.
//!
//! What it checks: no two workers are ever in the same section at once;
//! the count each section keeps inside it - added to without any care -
//! comes out as the sum of what the workers counted, so no count was
//! lost; no block of memory held another worker's bytes; and the ring
//! went on to the end, so no signal was lost. A worker that ends signals
//! the program from inside Forbid, so the program goes on - and frees the
//! workers' code - only once that worker is gone.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Task = exec.Task;
const Printf = dos.stdio.Printf;

const NAME = "Cores";
const VERSION_STRING = "\x00$VER: Cores 1.0 (04.10.2026)\r\n";
const TEMPLATE = "SECONDS/N,TASKS/N,PIN/S,FREE/S";

const default_seconds = 5;
const default_tasks = 4;
const max_tasks = 8;
const worker_stack = 4096;
/// How many times a worker looks, inside a section, whether it is still
/// alone there: long enough for another core to come in if it could.
const section_looks = 64;

/// A section a worker must be alone in: who is inside (a worker's number
/// and one, or 0), how often it was entered, counted inside without any
/// care, and how often a worker found another inside.
const Section = struct {
    inside: u32 = 0,
    count: u32 = 0,
    overlaps: u32 = 0,
};

const forbid = 0;
const disable = 1;
const semaphore = 2;
const spinlock = 3;
const section_names = [_][*:0]const u8{ "Forbid", "Disable", "Semaphore", "Spinlock" };

/// What a worker counted itself, and where it stands.
const Worker = struct {
    task: ?*Task = null,
    entered: [section_names.len]u32 = @splat(0),
    blocks: u32 = 0,
    bad_blocks: u32 = 0,
    tokens: u32 = 0,
    done: bool = false,
};

/// The run, shared by the program and its workers.
const Run = struct {
    sections: [section_names.len]Section = @splat(.{}),
    workers: [max_tasks]Worker = @splat(.{}),
    count: u32 = 0,
    sem: exec.SignalSemaphore = undefined,
    lock: exec.Lock = .{},
    parent: *Task = undefined,
    /// The program's signal for a worker that has ended, and the workers'
    /// for a token; CTRL-C ends a worker's wait for one.
    done_signal: u32 = 0,
    token_signal: u32 = 0,
    ring: bool = true,
    stop: bool = false,
};
var run: Run = .{};

/// `section` entered by worker `number`: alone, it says so, looks again
/// and again that nobody else came in, counts and leaves.
fn occupy(section: *Section, number: u32) void {
    const shared: *volatile Section = section;
    const me = number + 1;
    if (shared.inside != 0) shared.overlaps +%= 1;
    shared.inside = me;
    for (0..section_looks) |_| {
        if (shared.inside != me) shared.overlaps +%= 1;
    }
    shared.count +%= 1;
    shared.inside = 0;
}

/// The worker's number: its task's place in the run.
fn numberOf(task: *Task) u32 {
    for (run.workers[0..run.count], 0..) |*worker, number| {
        if (worker.task == task) return @intCast(number);
    }
    unreachable;
}

fn workerCode(sys: *ExecBase) callconv(.c) void {
    const number = numberOf(sys.FindTask(null).?);
    const worker = &run.workers[number];
    const next = run.workers[(number + 1) % run.count].task.?;
    const stop: *volatile bool = &run.stop;
    var round: u32 = 0;
    while (!stop.*) : (round +%= 1) {
        // A block of memory, filled with this worker's bytes, held across
        // the sections and checked at the end.
        const size: usize = 16 + (round *% 37 +% number *% 101) % 2000;
        const fill: u8 = @truncate(number *% 16 +% round);
        const block: ?[*]u8 = @ptrCast(sys.AllocMem(size, 0));
        if (block) |bytes| @memset(bytes[0..size], fill);

        sys.Forbid();
        occupy(&run.sections[forbid], number);
        sys.Permit();
        worker.entered[forbid] += 1;

        sys.Disable();
        occupy(&run.sections[disable], number);
        sys.Enable();
        worker.entered[disable] += 1;

        sys.ObtainSemaphore(&run.sem);
        occupy(&run.sections[semaphore], number);
        sys.ReleaseSemaphore(&run.sem);
        worker.entered[semaphore] += 1;

        sys.AcquireLock(&run.lock);
        occupy(&run.sections[spinlock], number);
        sys.ReleaseLock(&run.lock);
        worker.entered[spinlock] += 1;

        if (block) |bytes| {
            for (bytes[0..size]) |byte| {
                if (byte != fill) {
                    worker.bad_blocks += 1;
                    break;
                }
            }
            sys.FreeMem(bytes, size);
            worker.blocks += 1;
        }

        // The ring: a token on to the next worker, and one from the one
        // before waited for.
        if (!run.ring) continue;
        sys.Signal(next, run.token_signal);
        const got = sys.Wait(run.token_signal | exec.SIGBREAKF_CTRL_C);
        if (got & run.token_signal != 0) worker.tokens += 1;
    }
    // Ended inside Forbid: the program, woken here, runs once this task
    // is gone, and frees its code only then.
    sys.Forbid();
    worker.done = true;
    sys.Signal(run.parent, run.done_signal);
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [4]usize = @splat(0);
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

    run = .{};
    run.ring = argv[3] == 0;
    run.parent = sys.FindTask(null).?;
    const done_bit = sys.AllocSignal(-1);
    if (done_bit < 0) return dos.RETURN_FAIL;
    defer sys.FreeSignal(done_bit);
    run.done_signal = @as(u32, 1) << @intCast(done_bit);
    // The workers' token signal: one they all have free, as new tasks.
    run.token_signal = @as(u32, 1) << 31;
    sys.InitSemaphore(&run.sem);
    sys.InitLock(&run.lock, "Cores test", exec.LOCKORDER_DRIVER, 0);

    _ = Printf(dl, "%u tasks%s for %u seconds\n", .{ wanted, @as([*:0]const u8, if (pin) ", half on each core" else ""), seconds });
    _ = dl.Flush(dl.Output());

    // Made inside Forbid, so none runs before all are counted in and
    // pinned: neither core switches to a new task until the Permit.
    var names: [max_tasks][16:0]u8 = undefined;
    sys.Forbid();
    for (0..wanted) |number| {
        const name = &names[number];
        @memcpy(name[0..11], "Cores task ");
        name[11] = '0' + @as(u8, @intCast(number));
        name[12] = 0;
        const task = sys.CreateTask(@ptrCast(name), -1, &workerCode, worker_stack) orelse break;
        if (pin) task.flags |= if (number % 2 == 0) exec.TF_CORE0 else exec.TF_CORE1;
        run.workers[number].task = task;
        run.count += 1;
    }
    sys.Permit();
    if (run.count < wanted) _ = Printf(dl, "only %u tasks could be made\n", .{run.count});

    // The run, a second at a time, the ring watched: a second in which no
    // token went round is a lost signal. Without the ring, the sections.
    var stalled = false;
    var last_tokens: u32 = 0;
    for (0..seconds) |_| {
        dl.Delay(50);
        var tokens: u32 = 0;
        for (run.workers[0..run.count]) |*worker| {
            tokens +%= if (run.ring) @as(*volatile u32, &worker.tokens).* else @as(*volatile u32, &worker.entered[forbid]).*;
        }
        if (tokens == last_tokens) stalled = true;
        last_tokens = tokens;
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) break;
    }
    @as(*volatile bool, &run.stop).* = true;
    for (run.workers[0..run.count]) |*worker| sys.Signal(worker.task.?, exec.SIGBREAKF_CTRL_C);
    while (true) {
        var ended: u32 = 0;
        for (run.workers[0..run.count]) |*worker| {
            if (@as(*volatile bool, &worker.done).*) ended += 1;
        }
        if (ended == run.count) break;
        _ = sys.Wait(run.done_signal);
    }

    var failed = stalled;
    for (section_names, 0..) |section_name, index| {
        const section = &run.sections[index];
        var counted: u32 = 0;
        for (run.workers[0..run.count]) |*worker| counted += worker.entered[index];
        const right = section.overlaps == 0 and section.count == counted;
        if (!right) failed = true;
        _ = Printf(dl, "%-10s %8u entered, %u inside, %u overlaps  %s\n", .{
            section_name,
            counted,
            section.count,
            section.overlaps,
            @as([*:0]const u8, if (right) "ok" else "FAILED"),
        });
    }
    var blocks: u32 = 0;
    var bad: u32 = 0;
    var tokens: u32 = 0;
    for (run.workers[0..run.count]) |*worker| {
        blocks += worker.blocks;
        bad += worker.bad_blocks;
        tokens += worker.tokens;
    }
    if (bad != 0) failed = true;
    _ = Printf(dl, "%-10s %8u blocks, %u with another's bytes  %s\n", .{
        @as([*:0]const u8, "Memory"), blocks, bad, @as([*:0]const u8, if (bad == 0) "ok" else "FAILED"),
    });
    if (run.ring) {
        _ = Printf(dl, "%-10s %8u tokens passed  %s\n", .{
            @as([*:0]const u8, "Signals"), tokens, @as([*:0]const u8, if (stalled) "FAILED: the ring stopped" else "ok"),
        });
    } else if (stalled) {
        _ = Printf(dl, "FAILED: the workers stopped\n", .{});
    }
    _ = Printf(dl, "%s\n", .{@as([*:0]const u8, if (failed) "FAILED" else "passed")});
    return if (failed) dos.RETURN_FAIL else dos.RETURN_OK;
}

/// The "$VER:" string, kept by program.ld's `.version`.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
