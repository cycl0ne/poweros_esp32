// SPDX-License-Identifier: MIT
//! TaskBench: what a task costs - made, started, ended - and what handing
//! it work costs, against ShareWork. Built against the SDK only.
//!
//!   TaskBench ROUNDS/N
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
const VERSION_STRING = "\x00$VER: TaskBench 1.2 (31.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "ROUNDS/N";
const default_rounds: u32 = 1000;

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
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const rounds: u32 = if (argv[0] == 0) default_rounds else @max(@as(*const u32, @ptrFromInt(argv[0])).*, 1);

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

    // The partner on this core, then on another.
    const here = sys.SetTaskAffinity(null, 0);
    _ = sys.SetTaskAffinity(null, exec.coreFlag(1));
    for ([_]u32{ 1, 2 }) |core| {
        bench.stop = false;
        _ = sys.SetSignal(0, bench.back);
        const task = sys.CreateTask("TaskBench partner", 0, &partnerCode, 8192) orelse break;
        _ = sys.SetTaskAffinity(task, exec.coreFlag(core));
        _ = sys.Wait(bench.back);
        const go = @atomicLoad(u32, &bench.go, .acquire);
        var count: u32 = 0;
        const started = run.now();
        while (count < rounds * 10) : (count += 1) {
            sys.Signal(task, go);
            _ = sys.Wait(bench.back);
        }
        run.report(if (core == 1) "signal and back, the same core" else "signal and back, another core", count, run.now() - started);
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
