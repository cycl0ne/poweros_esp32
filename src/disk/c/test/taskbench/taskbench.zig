// SPDX-License-Identifier: MIT
//! TaskBench: what a task costs - made, started, ended - and what handing
//! it work costs, against ShareWork. Built against the SDK only.
//!
//!   TaskBench ROUNDS/N,HELD/S
//!
//! Each test is timed as a whole and given as the time per round:
//!
//! - **started**: CreateTask of a task that tells its maker it runs, and
//!   ends; until the maker hears it (8 KiB and 32 KiB of stack).
//! - **ended**: the same until the task's end message is back, its memory
//!   given back.
//! - **process**: CreateNewProc of a process that ends at once, until its
//!   end message is back.
//! - **signal**: a signal to a waiting task and one back: on the same core,
//!   and on another.
//! - **ShareWork**: a job of nothing in four parts.
//! - **jobs**: a job of nothing posted (PostWork) until it is replied; and
//!   four at once until all four are, the time given per job.
//! - **posters**: three tasks posting jobs at once while the maker shares
//!   work beside them; every job must run once and come back.
//!
//! **HELD** runs instead how a shared job fares beside tasks that keep
//! cores busy: each of a priority above TaskBench's, kept to a core of its
//! own, never waiting for 200 ms. TaskBench, kept to core 0, shares a job
//! of 32 ms of spinning in a part for each core - with no core held, with
//! core 1 held, and with every core but its own held - and while core 1 is
//! held, a task of a priority above the holder's, kept to the last core,
//! shares the same job 20 ms after TaskBench began its own. Each line says
//! how long the job took, the parts it was cut into and which of them its
//! asker did itself; every part must be done once. ROUNDS is then how many
//! times each pass runs, 3 if not given.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const TimerBase = sdk.interface.timer.TimerBase;
const TagItem = sdk.utility.TagItem;
const Task = exec.Task;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "TaskBench";
const VERSION_STRING = "\x00$VER: TaskBench 1.4 (28.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "ROUNDS/N,HELD/S";
const arg_rounds = 0;
const arg_held = 1;
const default_rounds: u32 = 1000;

/// HELD's figures: how long a holder keeps its core, how long the parts of
/// a job spin between them, the most parts a job is cut into, how long
/// after TaskBench's own the second asker shares, and the passes' rounds.
const hold_us: u64 = 200_000;
const job_us: u64 = 32_000;
const parts_max = 64;
const beside_after_us: u64 = 20_000;
const held_rounds_default: u32 = 3;

/// What the maker and its tasks share.
const Bench = struct {
    maker: ?*Task = null,
    /// The maker's signal, and the partner's.
    back: u32 = 0,
    go: u32 = 0,
    partner: ?*Task = null,
    stop: bool = false,
    /// The posters' rounds, the jobs that ran, the jobs that came back,
    /// and how many posters are still at it.
    poster_rounds: u32 = 0,
    jobs_run: u32 = 0,
    jobs_back: u32 = 0,
    posters: u32 = 0,
};
var bench: Bench = .{};

/// A posted job that counts itself.
fn countJob(_: *exec.WorkJob) callconv(.c) void {
    _ = @atomicRmw(u32, &bench.jobs_run, .Add, 1, .monotonic);
}

/// Posts its rounds of jobs, two at a time, and counts what comes back;
/// the last poster done tells the maker.
fn posterCode(sys: *ExecBase) callconv(.c) void {
    var back: u32 = 0;
    if (sys.CreateMsgPort()) |port| {
        var jobs: [2]exec.WorkJob = undefined;
        for (&jobs) |*job| job.* = .{ .message = .{ .reply_port = port }, .work = &countJob };
        var posted: u32 = 0;
        while (posted < bench.poster_rounds) : (posted += 2) {
            for (&jobs) |*job| sys.PostWork(job);
            var here: u32 = 0;
            while (here < 2) {
                _ = sys.WaitPort(port);
                while (sys.GetMsg(port) != null) here += 1;
            }
            back += here;
        }
        sys.DeleteMsgPort(port);
    }
    _ = @atomicRmw(u32, &bench.jobs_back, .Add, back, .monotonic);
    if (@atomicRmw(u32, &bench.posters, .Sub, 1, .acq_rel) == 1) sys.Signal(bench.maker.?, bench.back);
}

fn startedCode(sys: *ExecBase) callconv(.c) void {
    sys.Signal(bench.maker.?, bench.back);
}

/// Waits for the go (its end message is set by then), and ends.
fn endedCode(sys: *ExecBase) callconv(.c) void {
    _ = sys.Wait(exec.SIGF_SINGLE);
}

fn processCode(sys: *ExecBase) callconv(.c) void {
    _ = sys;
}

fn partnerCode(sys: *ExecBase) callconv(.c) void {
    const bit = sys.AllocSignal(-1);
    if (bit < 0) return;
    @atomicStore(u32, &bench.go, @as(u32, 1) << @intCast(bit), .release);
    sys.Signal(bench.maker.?, bench.back);
    while (true) {
        _ = sys.Wait(bench.go);
        if (@atomicLoad(bool, &bench.stop, .acquire)) break;
        sys.Signal(bench.maker.?, bench.back);
    }
    sys.FreeSignal(bit);
    sys.Signal(bench.maker.?, bench.back);
}

fn nothing(data: ?*anyopaque, part: u32, parts: u32) callconv(.c) void {
    _ = data;
    _ = part;
    _ = parts;
}

/// A posted job of nothing.
fn noJob(_: *exec.WorkJob) callconv(.c) void {}

/// A job HELD shares: each part spins its share of `job_us`, counts itself
/// and notes who did it; the sharer puts in what ShareWork answered and
/// how long it took.
const Spun = struct {
    sys: *ExecBase,
    done: [parts_max]u32 = @splat(0),
    by: [parts_max]?*Task = @splat(null),
    parts: u32 = 0,
    took_us: u64 = 0,
};

fn spunPart(data: ?*anyopaque, part: u32, parts: u32) callconv(.c) void {
    const spun: *Spun = @ptrCast(@alignCast(data.?));
    if (part < parts_max) {
        _ = @atomicRmw(u32, &spun.done[part], .Add, 1, .monotonic);
        spun.by[part] = spun.sys.FindTask(null);
    }
    spun.sys.SpinUs(job_us / parts);
}

/// `spun` shared out in as many as `parts`, and timed.
fn shareSpun(sys: *ExecBase, spun: *Spun, parts: u32) void {
    spun.* = .{ .sys = sys };
    const began = sys.UptimeUs();
    spun.parts = sys.ShareWork(&spunPart, spun, parts);
    spun.took_us = sys.UptimeUs() - began;
}

/// What HELD's holders and its second asker share with TaskBench.
const Held = struct {
    /// When the holders let go, by UptimeUs: 0 until every one spins.
    until: u64 = 0,
    /// How many holders are spinning.
    holding: u32 = 0,
    /// The second asker, its job and how many parts it asks for.
    beside_task: ?*Task = null,
    beside: Spun = undefined,
    parts: u32 = 0,
};
var held: Held = .{};

/// Keeps its core from its go until `held.until` is set and past, never
/// waiting.
fn holderCode(sys: *ExecBase) callconv(.c) void {
    _ = sys.Wait(exec.SIGF_SINGLE);
    _ = @atomicRmw(u32, &held.holding, .Add, 1, .acq_rel);
    while (true) {
        const until = @atomicLoad(u64, &held.until, .acquire);
        if (until != 0 and sys.UptimeUs() >= until) break;
    }
}

/// From its go waits `beside_after_us` - waiting, its core free - and
/// shares the job beside TaskBench's.
fn besideCode(sys: *ExecBase) callconv(.c) void {
    _ = sys.Wait(exec.SIGF_SINGLE);
    var never: exec.Waitable = .{};
    const list = [_]*exec.Waitable{&never};
    _ = sys.WaitForAny(&list, list.len, beside_after_us);
    shareSpun(sys, &held.beside, held.parts);
}

const Run = struct {
    sys: *ExecBase,
    dl: *DosBase,
    timer_base: *TimerBase,

    fn now(run: *Run) u64 {
        var value: timer.EClockVal = .{};
        const rate = run.timer_base.ReadEClock(&value);
        const count = value.toTicks();
        return count / rate * 1_000_000_000 + count % rate * 1_000_000_000 / rate;
    }

    fn report(run: *Run, what: [*:0]const u8, rounds: u64, nanos: u64) void {
        const each = nanos * 10 / @max(rounds, 1);
        _ = Printf(run.dl, "  %-40s %7lu rounds %8lu.%03lu ms %8lu.%lu ns each\n", .{ what, rounds, nanos / 1_000_000, nanos / 1000 % 1000, each / 10, each % 10 });
    }

    /// A job HELD shared: its time, its parts, the ones `asker` did; and
    /// whether every part was done once.
    fn reportSpun(run: *Run, what: [*:0]const u8, spun: *const Spun, asker: ?*Task, whose: [*:0]const u8) bool {
        var mine: u32 = 0;
        var right = true;
        for (spun.done, 0..) |count, part| {
            if (count != @intFromBool(part < spun.parts)) right = false;
            if (part < spun.parts and spun.by[part] == asker) mine += 1;
        }
        _ = Printf(run.dl, "  %-26s %3u parts %5lu.%lu ms, %s %u:", .{ what, spun.parts, spun.took_us / 1000, spun.took_us / 100 % 10, whose, mine });
        for (spun.by[0..@min(spun.parts, parts_max)], 0..) |by, part| {
            if (by == asker) _ = Printf(run.dl, " %u", .{@as(u32, @intCast(part))});
        }
        if (right) {
            _ = Printf(run.dl, "\n", .{});
        } else {
            _ = Printf(run.dl, "  - a part not done once\n", .{});
        }
        return right;
    }
};

/// HELD's passes, each `rounds` times: TaskBench's job with no core held,
/// with core 1 held and a second asker beside it, and with every core but
/// its own held. RETURN_WARN where a part was not done once or a holder
/// did not start.
fn heldPasses(run: *Run, port: *exec.MsgPort, rounds: u32) i32 {
    const sys = run.sys;
    const dl = run.dl;
    const cores = sys.CoreCount();
    if (cores < 2) {
        _ = Printf(dl, "  the machine runs on one core\n", .{});
        return dos.RETURN_OK;
    }
    const parts: u32 = @min(cores, parts_max);
    const me = sys.FindTask(null).?;
    const pri: i16 = me.node.pri;
    const above: i8 = @intCast(@min(pri + 1, 127));
    const beside_pri: i8 = @intCast(@min(pri + 2, 127));
    const here = sys.SetTaskAffinity(null, 0);
    defer _ = sys.SetTaskAffinity(null, here);
    _ = Printf(dl, "  ShareWork beside cores held %lu ms by tasks above it: a job of %lu ms in %u parts\n", .{ hold_us / 1000, job_us / 1000, parts });
    var result: i32 = dos.RETURN_OK;
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        // None held; core 1, and a second asker on the last core when
        // there is a core besides; every core but this one.
        const passes = [_]u32{ 0, 1, cores - 1 };
        for (passes, 0..) |holders, pass| {
            if (pass == 2 and cores < 3) continue;
            const beside = holders == 1 and cores >= 3;
            var ends: [parts_max]exec.Message = undefined;
            var made: u32 = 0;
            held.holding = 0;
            held.until = 0;
            var tasks: [parts_max]?*Task = @splat(null);
            while (made < holders and made + 1 < parts_max) : (made += 1) {
                const task = sys.CreateTask("TaskBench holder", @intCast(pri), &holderCode, 8192) orelse break;
                _ = sys.SetTaskAffinity(task, made + 1);
                ends[made] = .{ .reply_port = port };
                sys.SetTaskEndMsg(task, &ends[made]);
                _ = sys.SetTaskPri(task, above);
                tasks[made] = task;
            }
            var waited_for = made;
            if (beside) {
                held.parts = parts;
                held.beside = .{ .sys = sys };
                if (sys.CreateTask("TaskBench beside", @intCast(pri), &besideCode, 8192)) |task| {
                    _ = sys.SetTaskAffinity(task, cores - 1);
                    ends[waited_for] = .{ .reply_port = port };
                    sys.SetTaskEndMsg(task, &ends[waited_for]);
                    _ = sys.SetTaskPri(task, beside_pri);
                    held.beside_task = task;
                    waited_for += 1;
                } else held.beside_task = null;
            }
            // The holders let go `hold_us` from when they all spin: one
            // whose core a task of its own priority has waits for that
            // task's slice to end.
            for (tasks[0..made]) |task| sys.Signal(task.?, exec.SIGF_SINGLE);
            const asked = sys.UptimeUs();
            while (@atomicLoad(u32, &held.holding, .acquire) < made and sys.UptimeUs() - asked < 500_000) sys.SpinUs(50);
            const spinning = @atomicLoad(u32, &held.holding, .acquire);
            @atomicStore(u64, &held.until, sys.UptimeUs() + hold_us, .release);
            if (made < holders or spinning < made) {
                _ = Printf(dl, "  %u of %u holders spinning\n", .{ spinning, holders });
                result = dos.RETURN_WARN;
            }
            if (beside) {
                if (held.beside_task) |task| sys.Signal(task, exec.SIGF_SINGLE);
            }
            var mine: Spun = undefined;
            shareSpun(sys, &mine, parts);
            var back: u32 = 0;
            while (back < waited_for) {
                _ = sys.WaitPort(port);
                while (sys.GetMsg(port) != null) back += 1;
            }
            var name: [32]u8 = undefined;
            const what: [*:0]const u8 = switch (pass) {
                0 => "none held",
                1 => "core 1 held",
                else => heldName(&name, cores - 1),
            };
            if (!run.reportSpun(what, &mine, me, "TaskBench's")) result = dos.RETURN_WARN;
            if (beside and held.beside_task != null) {
                if (!run.reportSpun("  beside, 20 ms on", &held.beside, held.beside_task, "its asker's")) result = dos.RETURN_WARN;
            }
        }
    }
    return result;
}

/// "cores 1 to N held", in `room`.
fn heldName(room: *[32]u8, last: u32) [*:0]const u8 {
    const head = "cores 1 to ";
    const tail = " held";
    var at: usize = 0;
    for (head) |char| {
        room[at] = char;
        at += 1;
    }
    var digits: [10]u8 = undefined;
    var count: usize = 0;
    var value = last;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(value % 10));
        count += 1;
        value /= 10;
        if (value == 0) break;
    }
    while (count > 0) {
        count -= 1;
        room[at] = digits[count];
        at += 1;
    }
    for (tail) |char| {
        room[at] = char;
        at += 1;
    }
    room[at] = 0;
    return @ptrCast(room);
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const rounds: u32 = if (argv[arg_rounds] == 0)
        (if (argv[arg_held] != 0) held_rounds_default else default_rounds)
    else
        @max(@as(*const u32, @ptrFromInt(argv[arg_rounds])).*, 1);

    var clock: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &clock.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&clock.node);
    var run = Run{ .sys = sys, .dl = dl, .timer_base = @ptrCast(@alignCast(clock.node.device.?)) };

    const bit = sys.AllocSignal(-1);
    if (bit < 0) return dos.RETURN_FAIL;
    defer sys.FreeSignal(bit);
    bench = .{ .maker = sys.FindTask(null), .back = @as(u32, 1) << @intCast(bit) };
    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    if (argv[arg_held] != 0) return heldPasses(&run, port, rounds);

    for ([_]usize{ 8 * 1024, 32 * 1024 }) |stack| {
        var count: u32 = 0;
        var started = run.now();
        while (count < rounds) : (count += 1) {
            _ = sys.SetSignal(0, bench.back);
            _ = sys.CreateTask("TaskBench started", 0, &startedCode, stack) orelse break;
            _ = sys.Wait(bench.back);
        }
        run.report(if (stack == 8192) "started, 8 KiB of stack" else "started, 32 KiB of stack", count, run.now() - started);
        // Those still being given back, before the next.
        dl.Delay(2);

        count = 0;
        var ended: exec.Message = .{ .reply_port = port };
        started = run.now();
        while (count < rounds) : (count += 1) {
            const task = sys.CreateTask("TaskBench ended", 0, &endedCode, stack) orelse break;
            sys.SetTaskEndMsg(task, &ended);
            sys.Signal(task, exec.SIGF_SINGLE);
            _ = sys.WaitPort(port);
            _ = sys.GetMsg(port);
        }
        run.report(if (stack == 8192) "ended, 8 KiB of stack" else "ended, 32 KiB of stack", count, run.now() - started);
    }

    // As a shell starts one - its directories locked again and its
    // variables copied - and with nothing of the maker's.
    for ([_]bool{ true, false }) |inherits| {
        var count: u32 = 0;
        var ended: exec.Message = .{ .reply_port = port };
        const started = run.now();
        while (count < rounds) : (count += 1) {
            const tags = [_]TagItem{
                .{ .tag = dos.NP_Entry, .data = @intFromPtr(&processCode) },
                .{ .tag = dos.NP_Name, .data = @intFromPtr("TaskBench process") },
                .{ .tag = dos.NP_EndMsg, .data = @intFromPtr(&ended) },
                .{ .tag = if (inherits) sdk.utility.TAG_IGNORE else dos.NP_CurrentDir, .data = 0 },
                .{ .tag = if (inherits) sdk.utility.TAG_IGNORE else dos.NP_HomeDir, .data = 0 },
                .{ .tag = if (inherits) sdk.utility.TAG_IGNORE else dos.NP_CopyVars, .data = 0 },
                .{},
            };
            if (dl.CreateNewProc(&tags) == null) break;
            _ = sys.WaitPort(port);
            _ = sys.GetMsg(port);
        }
        run.report(if (inherits) "process, ended" else "process, nothing inherited", count, run.now() - started);
    }

    // The partner on this core, then on another: this task keeps to core
    // 0, which every machine has, and the second round wants a core
    // beside it - a machine that runs on one core is told so instead.
    const here = sys.SetTaskAffinity(null, 0);
    for ([_]u32{ 0, 1 }) |core| {
        if (sys.CoreTask(core) == null) {
            _ = Printf(dl, "  signal and back, another core               the machine runs on one core\n", .{});
            break;
        }
        bench.stop = false;
        _ = sys.SetSignal(0, bench.back);
        const task = sys.CreateTask("TaskBench partner", 0, &partnerCode, 8192) orelse break;
        _ = sys.SetTaskAffinity(task, core);
        _ = sys.Wait(bench.back);
        const go = @atomicLoad(u32, &bench.go, .acquire);
        var count: u32 = 0;
        const started = run.now();
        while (count < rounds * 10) : (count += 1) {
            sys.Signal(task, go);
            _ = sys.Wait(bench.back);
        }
        run.report(if (core == 0) "signal and back, the same core" else "signal and back, another core", count, run.now() - started);
        @atomicStore(bool, &bench.stop, true, .release);
        sys.Signal(task, go);
        _ = sys.Wait(bench.back);
        dl.Delay(2);
    }
    _ = sys.SetTaskAffinity(null, here);

    {
        var count: u32 = 0;
        var parts: u32 = 0;
        const started = run.now();
        while (count < rounds * 10) : (count += 1) parts = sys.ShareWork(&nothing, null, 4);
        run.report("ShareWork, nothing in 4 parts", count, run.now() - started);
        _ = Printf(dl, "  (in %u parts)\n", .{parts});
    }

    var jobs: [4]exec.WorkJob = undefined;
    for (&jobs) |*job| job.* = .{ .message = .{ .reply_port = port }, .work = &noJob };
    for ([_]u32{ 1, 4 }) |at_once| {
        var count: u32 = 0;
        const started = run.now();
        while (count < rounds * 10) : (count += at_once) {
            for (jobs[0..at_once]) |*job| sys.PostWork(job);
            var back: u32 = 0;
            while (back < at_once) {
                _ = sys.WaitPort(port);
                while (sys.GetMsg(port) != null) back += 1;
            }
        }
        run.report(if (at_once == 1) "a job posted and back" else "four jobs at once, each", count, run.now() - started);
    }

    // Three posters at once, and work shared beside them.
    bench.poster_rounds = rounds * 10;
    bench.jobs_run = 0;
    bench.jobs_back = 0;
    bench.posters = 3;
    _ = sys.SetSignal(0, bench.back);
    var started_posters: u32 = 0;
    while (started_posters < 3) : (started_posters += 1) {
        if (sys.CreateTask("TaskBench poster", 0, &posterCode, 4096 * @sizeOf(usize)) == null) break;
    }
    if (started_posters < 3) _ = @atomicRmw(u32, &bench.posters, .Sub, 3 - started_posters, .acq_rel);
    var shared: u32 = 0;
    var parts_seen: u32 = 0;
    while (@atomicLoad(u32, &bench.posters, .acquire) != 0) {
        parts_seen += sys.ShareWork(&nothing, null, 4);
        shared += 1;
        _ = sys.SetSignal(0, 0);
    }
    _ = sys.Wait(bench.back);
    const wanted = started_posters * bench.poster_rounds;
    _ = Printf(dl, "  posters: %u jobs of %u run, %u back; ShareWork %u times beside them, %u parts\n", .{ bench.jobs_run, wanted, bench.jobs_back, shared, parts_seen });
    if (bench.jobs_run != wanted or bench.jobs_back != wanted) return dos.RETURN_WARN;
    return dos.RETURN_OK;
}
