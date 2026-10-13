// SPDX-License-Identifier: MIT
//! Top: what each task takes of the machine, looked at again and again
//! until Ctrl-C. Built against the SDK only.
//!
//!   Top INTERVAL/K/N,COUNT/K/N
//!
//! INTERVAL is the time between looks, in seconds (2); COUNT how many
//! looks it shows before it ends - with none, it goes on until Ctrl-C.
//!
//! Each look has a line per core - how much of the interval it spent in
//! tasks, in interrupts and idle (`ReadCoreTimes`) - the free memory,
//! and then every task, the busiest first: its share of one core over
//! the interval, the core it runs on if it is running, its priority, its
//! state and its name. A task's time is exec's own count of it
//! (`Task.timeRun`), taken at every exception, so a task that runs a
//! moment after each tick shows as much as it takes; time in interrupts
//! is no task's. The cores' idle tasks - at the lowest priority, each
//! pinned to its core - are left out: their time is the idle column.
//!
//! On a console each look is written over the one before; into a file or
//! a pipe they follow one another.
//!
//! The tasks are copied out under Disable, as `ShowInfo TASKS` does -
//! all at once, so none is seen twice or missed as it moves between
//! exec's queues - and printed after, since printing waits on a handler.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Top";
const VERSION_STRING = "\x00$VER: Top 1.0 (13.10.2026)\r\n";

const template = "INTERVAL/K/N,COUNT/K/N";
const arg_interval = 0;
const arg_count = 1;

const default_interval = 2;
const longest_interval = 3600;
/// How many tasks one look copies out; the rest are counted, not shown.
const max_tasks = 96;
/// How many cores one look reads.
const max_cores = 4;

const MSG_NOTIMER = "%s: can't open %s\n";
const MSG_NOMEMORY = "%s: no memory to copy the tasks into\n";
const MSG_BADINTERVAL = "%s: INTERVAL is 1 to 3600 seconds\n";

/// The control sequences a console understands: the cursor to the top
/// left, the rest of a line erased, the rest of the window erased.
const csi_home = "\x1b[H";
const csi_erase_line = "\x1b[K";
const csi_erase_below = "\x1b[J";

var sys: *ExecBase = undefined;
var dl: *DosBase = undefined;

/// A task as it was at a look, copied into this program's own memory: it
/// may be gone by the time its line is printed.
const Seen = struct {
    address: usize = 0,
    time_run: u64 = 0,
    /// What it took since the look before.
    spent: u64 = 0,
    pri: i8 = 0,
    state: [*:0]const u8 = "",
    /// The core it runs on, for a running one.
    core: ?u32 = null,
    idle: bool = false,
    name: [32]u8 = @splat(0),
};

/// One look: the cores' times and the tasks, as they were together.
const Look = struct {
    seen: []Seen,
    count: usize = 0,
    missed: u32 = 0,
    cores: [max_cores]exec.CoreTimes = @splat(.{}),
    core_count: u32 = 0,
};

export fn _program_entry(base: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sys = base;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    dl = @ptrCast(dos_lib);

    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const interval: u32 = if (argv[arg_interval] != 0) @as(*const u32, @ptrFromInt(argv[arg_interval])).* else default_interval;
    if (interval == 0 or interval > longest_interval) {
        _ = Printf(dl, MSG_BADINTERVAL, .{COMMAND_NAME});
        return dos.RETURN_ERROR;
    }
    const looks: u32 = if (argv[arg_count] != 0) @as(*const u32, @ptrFromInt(argv[arg_count])).* else 0;

    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    var clock: timer.TimeRequest = .{};
    clock.node.message.reply_port = port;
    clock.node.message.length = @sizeOf(timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &clock.node, 0) != 0) {
        _ = Printf(dl, MSG_NOTIMER, .{ COMMAND_NAME, sdk.interface.timer.NAME });
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(&clock.node);

    const block = sys.AllocVec(2 * max_tasks * @sizeOf(Seen), exec.MEMF_ANY) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(block);
    const all: [*]Seen = @ptrCast(@alignCast(block));
    var looked = [2]Look{ .{ .seen = all[0..max_tasks] }, .{ .seen = all[max_tasks .. 2 * max_tasks] } };

    // On a console each look is written over the one before.
    const on_console = dl.IsInteractive(dl.Output());
    // A Ctrl-C from before this command started is not a request to stop it.
    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C);

    var before: usize = 0;
    look(&looked[before]);
    var shown: u32 = 0;
    while (looks == 0 or shown < looks) : (shown += 1) {
        if (!waitOut(&clock, port, interval)) break;
        const now = 1 - before;
        look(&looked[now]);
        account(&looked[now], &looked[before]);
        if (!on_console and shown != 0) _ = dl.PutStr("\n");
        show(&looked[now], &looked[before], interval, on_console);
        before = now;
    }
    return dos.RETURN_OK;
}

/// `seconds` waited out on the timer: false when Ctrl-C came first.
fn waitOut(clock: *timer.TimeRequest, port: *exec.MsgPort, seconds: u32) bool {
    clock.node.command = timer.TR_ADDREQUEST;
    clock.time = timer.TimeVal.fromMicros(@as(u64, seconds) * 1_000_000);
    sys.SendIO(&clock.node);
    const got = sys.Wait(port.sigMask() | exec.SIGBREAKF_CTRL_C);
    if (got & exec.SIGBREAKF_CTRL_C != 0) {
        _ = sys.AbortIO(&clock.node);
        _ = sys.WaitIO(&clock.node);
        return false;
    }
    _ = sys.WaitIO(&clock.node);
    return true;
}

/// The cores' times and every task, copied out under one Disable: what
/// each core runs (CoreTask, from core 0 up until one is not running),
/// then the two queues, whose own lock is Disable too and nests.
fn look(into: *Look) void {
    into.count = 0;
    into.missed = 0;
    sys.Disable();
    var core: u32 = 0;
    while (core < max_cores and sys.ReadCoreTimes(core, &into.cores[core])) core += 1;
    into.core_count = core;
    core = 0;
    while (sys.CoreTask(core)) |task| : (core += 1) take(into, task, "run", core);
    for ([_]struct { state: [*:0]const u8, which: u32 }{
        .{ .state = "ready", .which = exec.EXECLIST_TASK_READY },
        .{ .state = "wait", .which = exec.EXECLIST_TASK_WAIT },
    }) |queue| {
        const list = sys.LockExecList(queue.which).?;
        var it = list.iterator();
        while (it.next()) |node| take(into, @fieldParentPtr("node", node), queue.state, null);
        sys.UnlockExecList(queue.which);
    }
    sys.Enable();
}

fn take(into: *Look, task: *const exec.Task, state: [*:0]const u8, core: ?u32) void {
    if (into.count == into.seen.len) {
        into.missed += 1;
        return;
    }
    const pins = task.flags & (exec.TF_CORE0 | exec.TF_CORE1);
    const seen = &into.seen[into.count];
    into.count += 1;
    seen.* = .{
        .address = @intFromPtr(task),
        .time_run = task.timeRun(),
        .pri = task.node.pri,
        .state = state,
        .core = core,
        .idle = task.node.pri == -128 and (pins == exec.TF_CORE0 or pins == exec.TF_CORE1),
    };
    copyName(&seen.name, task.node.name);
}

/// What each task took since the look before: the difference of its
/// time, found by its address. A task that was not there before - or a
/// new one at an old one's address, whose time is lower - took all of
/// its own.
fn account(now: *Look, before: *const Look) void {
    for (now.seen[0..now.count]) |*task| {
        task.spent = task.time_run;
        for (before.seen[0..before.count]) |*earlier| {
            if (earlier.address != task.address) continue;
            if (earlier.time_run <= task.time_run) task.spent = task.time_run - earlier.time_run;
            break;
        }
    }
}

fn show(now: *const Look, before: *const Look, interval: u32, on_console: bool) void {
    const eol: [*:0]const u8 = if (on_console) csi_erase_line ++ "\n" else "\n";
    if (on_console) _ = dl.PutStr(csi_home);
    _ = Printf(dl, "Top, every %u s - Ctrl-C ends it%s", .{ interval, eol });

    // A task's share is of one core over the interval: the most cycles
    // any core counted in it. The cores run on one clock, but an emulator
    // may count each core's on its own.
    var span: u64 = 0;
    for (0..now.core_count) |core| {
        const t = now.cores[core];
        const b = before.cores[core];
        const tasks = t.tasks -% b.tasks;
        const idle = t.idle -% b.idle;
        const interrupts = t.interrupts -% b.interrupts;
        const all = tasks + idle + interrupts;
        span = @max(span, all);
        _ = Printf(dl, "core %u   tasks %3u.%u%%   interrupts %3u.%u%%   idle %3u.%u%%%s", .{
            @as(u32, @intCast(core)),
            whole(tasks, all),
            tenth(tasks, all),
            whole(interrupts, all),
            tenth(interrupts, all),
            whole(idle, all),
            tenth(idle, all),
            eol,
        });
    }
    _ = Printf(dl, "memory   %u KiB free internal, %u KiB external%s%s", .{
        sys.AvailMem(exec.MEMF_INTERNAL) / 1024,
        sys.AvailMem(exec.MEMF_EXTERNAL) / 1024,
        eol,
        eol,
    });

    // The tasks, busiest first; an insertion sort keeps the ones that
    // took the same in the order they were found.
    var order: [max_tasks]u8 = undefined;
    var count: usize = 0;
    for (now.seen[0..now.count], 0..) |*task, index| {
        if (task.idle) continue;
        var at = count;
        while (at > 0 and now.seen[order[at - 1]].spent < task.spent) : (at -= 1) order[at] = order[at - 1];
        order[at] = @intCast(index);
        count += 1;
    }

    _ = Printf(dl, "   cpu  core   pri  state  name%s", .{eol});
    for (order[0..count]) |index| {
        const task = &now.seen[index];
        var core_text: [2:0]u8 = .{ '-', 0 };
        if (task.core) |number| core_text[0] = '0' + @as(u8, @intCast(number % 10));
        _ = Printf(dl, "%3u.%u%%  %-4s %5d  %-5s  %s%s", .{
            whole(task.spent, span),
            tenth(task.spent, span),
            @as([*:0]const u8, &core_text),
            @as(i32, task.pri),
            task.state,
            @as([*:0]const u8, @ptrCast(&task.name)),
            eol,
        });
    }
    if (now.missed != 0) _ = Printf(dl, "... and %u more%s", .{ now.missed, eol });
    if (on_console) _ = dl.PutStr(csi_erase_below);
}

/// `part` of `all` in tenths of a percent, at most 999.9 %.
fn tenths(part: u64, all: u64) u32 {
    if (all == 0) return 0;
    const value: u64 = @min(part * 1000 / all, 9999);
    return @intCast(value);
}

fn whole(part: u64, all: u64) u32 {
    return tenths(part, all) / 10;
}

fn tenth(part: u64, all: u64) u32 {
    return tenths(part, all) % 10;
}

/// A name out of a list, into memory of this program's own.
fn copyName(into: []u8, from: ?[*:0]const u8) void {
    const text = from orelse "?";
    var i: usize = 0;
    while (text[i] != 0 and i + 1 < into.len) : (i += 1) into[i] = text[i];
    into[i] = 0;
}

/// The "$VER:" string `Version <file>` looks for: exported, in a section
/// program.ld keeps.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
