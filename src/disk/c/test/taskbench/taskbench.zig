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
const VERSION_STRING = "\x00$VER: TaskBench 1.1 (31.10.2026)\r\n";
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
};
var bench: Bench = .{};

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
    return dos.RETURN_OK;
}
