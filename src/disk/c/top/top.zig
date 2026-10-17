// SPDX-License-Identifier: MIT
//! Top: what each task takes of the machine, looked at again and again
//! until Ctrl-C. Built against the SDK only.
//!
//!   Top INTERVAL/K/N,COUNT/K/N
//!
//! INTERVAL is the time between looks, in seconds (2); COUNT how many
//! looks it shows before it ends - with none, it goes on until Ctrl-C, or
//! on a console until q.
//!
//! Each look has a line per core - how much of the interval it spent in
//! tasks, in interrupts and idle (`ReadCoreTimes`) - the free memory and
//! what the system and the tasks that have ended hold, and then every
//! task: those running first, then those ready to run, then those
//! waiting, and in each the busiest first. A task's line has its share of
//! one core over the interval, the core it runs on if it is running, its
//! priority, its state, the memory it holds - "system" for exec's own
//! tasks, whose memory is the system's - and its name. What a task holds
//! is what its blocks' MemBlocks say, summed over every region
//! (`sdk.exec.memowners`). A task's time is exec's own count of it
//! (`Task.timeRun`), taken at every exception, so a task that runs a
//! moment after each tick shows as much as it takes; time in interrupts
//! is no task's. The cores' idle tasks - at the lowest priority, each
//! pinned to its core - are left out: their time is the idle column.
//!
//! On a console each look is written over the one before, and fits it:
//! the console is asked its size before every look (`CSI 18 t`, answered
//! `CSI 8;rows;cols t` - a window's console, and a terminal at the far
//! end of a serial line, do), so a window made larger shows more tasks.
//! A line is cut at the width, and the tasks that do not fit are counted
//! on the last row. A console that does not answer is taken for 24 rows
//! of 80. Into a file or a pipe the looks follow one another, whole.
//!
//! The tasks are copied out under Disable, as `ShowInfo TASKS` does -
//! all at once, so none is seen twice or missed as it moves between
//! exec's queues - and printed after, since printing waits on a handler.
//! The memory is walked after, under exec's memory lock.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const FileHandle = dos.FileHandle;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Top";
const VERSION_STRING = "\x00$VER: Top 1.3 (17.10.2026)\r\n";

const template = "INTERVAL/K/N,COUNT/K/N";
const arg_interval = 0;
const arg_count = 1;

const default_interval = 2;
const longest_interval = 3600;
/// How many tasks one look copies out; the rest are counted, not shown.
const max_tasks = 96;
/// How many cores one look reads.
const max_cores = 4;
/// A console that does not say its size.
const default_rows = 24;
const default_cols = 80;
/// How long a key is waited for at a time between looks, in microseconds:
/// how late a q is seen.
const key_wait = 100_000;

const MSG_NOTIMER = "%s: can't open %s\n";
const MSG_NOMEMORY = "%s: no memory to copy the tasks into\n";
const MSG_BADINTERVAL = "%s: INTERVAL is 1 to 3600 seconds\n";

/// The control sequences a console understands: the cursor to the top
/// left, the rest of a line erased, the rest of the window erased, and
/// the question for the window's size.
const csi_home = "\x1b[H";
const csi_erase_line = "\x1b[K";
const csi_erase_below = "\x1b[J";
const csi_ask_size = "\x1b[18t";

var sys: *ExecBase = undefined;
var dl: *DosBase = undefined;
/// Who holds the memory, at the last look: walked under exec's memory lock,
/// which allows no allocating, into this program's own memory.
var holders: exec.memowners.Tally(max_tasks + 8) = .{};

/// Where a look found a task: on a core, in the queue for one, or waiting.
/// A look lists them in this order.
const State = enum(u8) { run, ready, wait };

/// A task as it was at a look, copied into this program's own memory: it
/// may be gone by the time its line is printed.
const Seen = struct {
    address: usize = 0,
    time_run: u64 = 0,
    /// What it took since the look before.
    spent: u64 = 0,
    pri: i8 = 0,
    state: State = .wait,
    /// The core it runs on, for a running one.
    core: ?u32 = null,
    idle: bool = false,
    /// Its number (`Task.id`), and the memory it holds.
    id: u32 = 0,
    memory: usize = 0,
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

/// Where a look is written: a console of so many rows and columns - the
/// keys read from it in raw mode, when it gives them - or a file or a
/// pipe, which has no end on either side.
const Screen = struct {
    out: ?*FileHandle,
    on_console: bool,
    keys: ?*FileHandle = null,
    /// Whether the console says its size; asked again at every look.
    answers: bool = false,
    rows: u32 = default_rows,
    cols: u32 = default_cols,
    /// The rows this look has written.
    written: u32 = 0,
    /// q was typed.
    quit: bool = false,

    /// The size asked for: `CSI 18 t`, and `CSI 8;rows;cols t` read back.
    /// What has not answered in half a second does not answer. A q typed
    /// meanwhile is kept; anything else typed is passed over.
    fn askSize(screen: *Screen) bool {
        const keys = screen.keys orelse return false;
        if (dl.Write(screen.out, csi_ask_size, csi_ask_size.len) < 0) return false;
        var reply: [24]u8 = undefined;
        var len: usize = 0;
        var waits: u32 = 0;
        while (len < reply.len and waits < 5) {
            if (!dl.WaitForChar(keys, 100_000)) {
                waits += 1;
                continue;
            }
            var byte: u8 = 0;
            if (dl.Read(keys, @ptrCast(&byte), 1) != 1) return false;
            if (len == 0 and byte != 0x1B) {
                if (byte == 'q' or byte == 'Q') screen.quit = true;
                continue;
            }
            reply[len] = byte;
            len += 1;
            if (byte == 't') break;
        }
        // ESC [ 8 ; rows ; cols t
        if (len < 6 or reply[1] != '[' or reply[2] != '8' or reply[3] != ';' or reply[len - 1] != 't') return false;
        var values: [2]u32 = .{ 0, 0 };
        var which: usize = 0;
        for (reply[4 .. len - 1]) |byte| {
            if (byte == ';') {
                which += 1;
                if (which == values.len) return false;
            } else if (byte >= '0' and byte <= '9') {
                values[which] = values[which] * 10 + (byte - '0');
            } else return false;
        }
        // A window of one row or one column is an answer nothing fits in.
        if (which != 1 or values[0] < 2 or values[1] < 2) return false;
        screen.rows = values[0];
        screen.cols = values[1];
        return true;
    }

    fn begin(screen: *Screen) void {
        screen.written = 0;
        if (screen.on_console) _ = dl.Write(screen.out, csi_home, csi_home.len);
    }

    /// The rows left in this look; no end into a file.
    fn room(screen: *const Screen) u32 {
        if (!screen.on_console) return ~@as(u32, 0);
        return screen.rows -| screen.written;
    }

    /// One row, formatted, cut short of the last column - a character
    /// there would have a terminal wrap - and written. On a console the
    /// row goes over the one the look before had there, and the new line
    /// comes before it rather than after: a line feed on the last row
    /// would scroll the window.
    fn line(screen: *Screen, comptime format: [:0]const u8, args: anytype) void {
        comptime exec.checkFormat(format, @TypeOf(args));
        if (screen.room() == 0) return;
        var text: [192]u8 = undefined;
        var at: usize = 0;
        if (screen.on_console and screen.written != 0) {
            text[0] = '\n';
            at = 1;
        }
        const stream = exec.fmtStream(args);
        _ = sys.RawDoFmt(format, &stream, null, @ptrCast(text[at..].ptr));
        var len: usize = 0;
        while (text[at + len] != 0) len += 1;
        if (screen.on_console) {
            len = @min(len, screen.cols - 1);
            @memcpy(text[at + len ..][0..csi_erase_line.len], csi_erase_line);
            len += csi_erase_line.len;
        } else {
            text[at + len] = '\n';
            len += 1;
        }
        _ = dl.Write(screen.out, &text, @intCast(at + len));
        screen.written += 1;
    }

    fn end(screen: *Screen) void {
        if (screen.on_console) _ = dl.Write(screen.out, csi_erase_below, csi_erase_below.len);
    }
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

    // On a console each look is written over the one before, at the
    // console's size; its keys, in raw mode, answer the question for it.
    const out = dl.Output();
    var screen: Screen = .{ .out = out, .on_console = dl.IsInteractive(out) };
    if (screen.on_console) {
        if (dl.Open("*", dos.MODE_OLDFILE)) |keys| {
            if (dl.IsInteractive(keys) and dl.SetMode(keys, 1)) {
                screen.keys = keys;
            } else {
                _ = dl.Close(keys);
            }
        }
    }
    defer if (screen.keys) |keys| {
        _ = dl.SetMode(keys, 0);
        _ = dl.Close(keys);
    };
    screen.answers = screen.askSize();
    // A Ctrl-C from before this command started is not a request to stop it.
    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C);

    var before: usize = 0;
    look(&looked[before]);
    var shown: u32 = 0;
    while (looks == 0 or shown < looks) : (shown += 1) {
        if (!waitOut(&clock, port, interval, &screen)) break;
        const now = 1 - before;
        look(&looked[now]);
        account(&looked[now], &looked[before]);
        if (screen.answers) _ = screen.askSize();
        if (screen.quit) break;
        if (!screen.on_console and shown != 0) _ = dl.PutStr("\n");
        show(&screen, &looked[now], &looked[before], interval);
        before = now;
    }
    // The prompt after the last look, not over it.
    if (screen.on_console) _ = dl.PutStr("\n");
    return dos.RETURN_OK;
}

/// `seconds` waited out on the timer: false when Ctrl-C came first, or a
/// q from the console's keys, which are looked at every `key_wait`.
fn waitOut(clock: *timer.TimeRequest, port: *exec.MsgPort, seconds: u32, screen: *Screen) bool {
    clock.node.command = timer.TR_ADDREQUEST;
    clock.time = timer.TimeVal.fromMicros(@as(u64, seconds) * 1_000_000);
    sys.SendIO(&clock.node);
    const keys = screen.keys orelse {
        const got = sys.Wait(port.sigMask() | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return stopClock(clock);
        _ = sys.WaitIO(&clock.node);
        return true;
    };
    while (sys.CheckIO(&clock.node) == null) {
        if (sys.SetSignal(0, exec.SIGBREAKF_CTRL_C) & exec.SIGBREAKF_CTRL_C != 0) return stopClock(clock);
        if (!dl.WaitForChar(keys, key_wait)) continue;
        var byte: u8 = 0;
        if (dl.Read(keys, @ptrCast(&byte), 1) == 1 and (byte == 'q' or byte == 'Q')) {
            screen.quit = true;
            return stopClock(clock);
        }
    }
    _ = sys.WaitIO(&clock.node);
    return true;
}

/// The wait taken back: false, for the caller to stop on.
fn stopClock(clock: *timer.TimeRequest) bool {
    _ = sys.AbortIO(&clock.node);
    _ = sys.WaitIO(&clock.node);
    return false;
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
    while (sys.CoreTask(core)) |task| : (core += 1) take(into, task, .run, core);
    for ([_]struct { state: State, which: u32 }{
        .{ .state = .ready, .which = exec.EXECLIST_TASK_READY },
        .{ .state = .wait, .which = exec.EXECLIST_TASK_WAIT },
    }) |queue| {
        const list = sys.LockExecList(queue.which).?;
        var it = list.iterator();
        while (it.next()) |node| take(into, @fieldParentPtr("node", node), queue.state, null);
        sys.UnlockExecList(queue.which);
    }
    sys.Enable();
    holders.take(sys);
    for (into.seen[0..into.count]) |*task| {
        task.memory = if (holders.of(task.id)) |owner| owner.bytes else 0;
    }
}

fn take(into: *Look, task: *const exec.Task, state: State, core: ?u32) void {
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
        .id = task.id,
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

fn show(screen: *Screen, now: *const Look, before: *const Look, interval: u32) void {
    screen.begin();
    if (screen.keys != null) {
        screen.line("Top, every %u s - q or Ctrl-C ends it", .{interval});
    } else {
        screen.line("Top, every %u s - Ctrl-C ends it", .{interval});
    }

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
        screen.line("core %u  tasks%4u.%u%%  interrupts%4u.%u%%  idle%4u.%u%%", .{
            @as(u32, @intCast(core)),
            whole(tasks, all),
            tenth(tasks, all),
            whole(interrupts, all),
            tenth(interrupts, all),
            whole(idle, all),
            tenth(idle, all),
        });
    }
    screen.line("memory   %u KiB free internal, %u KiB external", .{
        sys.AvailMem(exec.MEMF_INTERNAL) / 1024,
        sys.AvailMem(exec.MEMF_EXTERNAL) / 1024,
    });
    // What no task of this look holds: the system's, and what tasks that
    // have ended left.
    var system_bytes: usize = 0;
    var ended_bytes: usize = 0;
    var ended: u32 = 0;
    for (holders.owners[0..holders.used]) |*owner| {
        if (owner.system()) {
            system_bytes += owner.bytes;
            continue;
        }
        const living = for (now.seen[0..now.count]) |*task| {
            if (task.id == owner.id) break true;
        } else false;
        if (living) continue;
        ended_bytes += owner.bytes;
        ended += 1;
    }
    screen.line("held     %u KiB by the system, %u KiB by %u tasks that have ended", .{
        system_bytes / 1024,
        ended_bytes / 1024,
        ended,
    });
    screen.line("", .{});

    // The tasks running, then ready, then waiting, and in each the busiest
    // first; an insertion sort keeps the ones that are alike in the order
    // they were found.
    var order: [max_tasks]u8 = undefined;
    var count: usize = 0;
    for (now.seen[0..now.count], 0..) |*task, index| {
        if (task.idle) continue;
        var at = count;
        while (at > 0 and goesBefore(task, &now.seen[order[at - 1]])) : (at -= 1) order[at] = order[at - 1];
        order[at] = @intCast(index);
        count += 1;
    }

    screen.line("   cpu  core   pri  state  memory  name", .{});
    // What fits under the heading; with more tasks than that, the last row
    // counts the rest.
    const not_copied = now.missed;
    var shown: usize = count;
    if (count + @intFromBool(not_copied != 0) > screen.room()) shown = screen.room() -| 1;
    for (order[0..shown]) |index| {
        const task = &now.seen[index];
        var core_text: [2:0]u8 = .{ '-', 0 };
        if (task.core) |number| core_text[0] = '0' + @as(u8, @intCast(number % 10));
        // exec's own tasks allocate as the system: theirs is the line
        // above, not a task's.
        if (task.id == exec.MEMOWNER_SYSTEM) {
            screen.line("%3u.%u%%  %-4s %5d  %-5s  system  %s", .{
                whole(task.spent, span),
                tenth(task.spent, span),
                @as([*:0]const u8, &core_text),
                @as(i32, task.pri),
                @tagName(task.state).ptr,
                @as([*:0]const u8, @ptrCast(&task.name)),
            });
            continue;
        }
        screen.line("%3u.%u%%  %-4s %5d  %-5s %6uK  %s", .{
            whole(task.spent, span),
            tenth(task.spent, span),
            @as([*:0]const u8, &core_text),
            @as(i32, task.pri),
            @tagName(task.state).ptr,
            @as(u32, @intCast(task.memory / 1024)),
            @as([*:0]const u8, @ptrCast(&task.name)),
        });
    }
    const rest: u32 = @intCast(count - shown + not_copied);
    if (rest != 0) screen.line("... and %u more", .{rest});
    screen.end();
}

/// Whether `one` is listed above `other`: by its state, and in the same
/// state by what it took.
fn goesBefore(one: *const Seen, other: *const Seen) bool {
    if (one.state != other.state) return @intFromEnum(one.state) < @intFromEnum(other.state);
    return one.spent > other.spent;
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
