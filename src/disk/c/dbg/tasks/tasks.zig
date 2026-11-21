// SPDX-License-Identifier: MIT
//! Tasks: every task of the machine with what a search for a stuck one
//! needs - its number, the signals it waits for and has, its stack, and
//! the semaphore it waits in. Built against the SDK only.
//!
//!   Tasks NAME/K
//!
//! A line a task, those running first, then those ready, then those
//! waiting:
//!
//!       #  state core  pri  waits for received  stack used/size  name
//!      12  run      2    0  00000000  00000000        -/65536    Paint
//!       7  wait     0   20  00001000  00000000     1520/16384    input.device
//!
//! `#` is the task's number, which `Where` and `Kill` take and the memory
//! listings show. `core` is the core it runs on, or whose lists it is on.
//! `waits for` and `received` are its signal masks (bit 12 is Ctrl-C).
//! The stack's use is how far below its top the task's stack pointer is
//! (`GetTaskSpot`, which reads a running task on its core without
//! stopping it); a dash where it is outside the task's stack, or the
//! task has ended since it was copied.
//! A task that waits in a semaphore has its name after its own, `on`
//! "name", and one that holds semaphores says how many. NAME shows only
//! the tasks of that name, without case.
//!
//! The tasks are copied out a core at a time, each under that core's
//! lists (`LockCoreTasks`), and printed after, since printing waits on a
//! handler: a task that moves between cores just then may be seen twice
//! or not at all. Their stack pointers are asked for after
//! (`GetTaskSpot`), which looks for each on its core's lists before it
//! reads anything of it: one that ended meanwhile answers nothing.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Tasks";
const VERSION_STRING = "\x00$VER: Tasks 1.0 (21.11.2026)\r\n";

const template = "NAME/K";
const arg_name = 0;
const arg_count = 1;

/// How many tasks one listing copies out; the rest are counted.
const max_seen = 128;
/// How much of a task's and a semaphore's name is kept.
const name_room = 32;

/// What is shown of one task, copied under its core's lists.
const Seen = struct {
    id: u32,
    state: exec.TaskState,
    core: u32,
    pri: i8,
    sig_wait: u32,
    sig_recvd: u32,
    /// How far below its stack's top its stack pointer is; null where
    /// that is not known.
    used: ?usize,
    size: usize,
    task: *exec.Task,
    holds: u32,
    name: [name_room]u8,
    on: [name_room]u8,
};

/// The tasks copied so far, and how many did not fit.
const Copied = struct {
    seen: []Seen,
    count: usize = 0,
    missed: u32 = 0,

    fn take(copied: *Copied, task: *exec.Task, core: u32, running: bool) void {
        if (copied.count == copied.seen.len) {
            copied.missed += 1;
            return;
        }
        const seen = &copied.seen[copied.count];
        copied.count += 1;
        seen.* = .{
            .id = task.id,
            .state = if (running) .run else task.state,
            .core = core,
            .pri = task.node.pri,
            .sig_wait = task.sig_wait,
            .sig_recvd = task.sig_recvd,
            .used = null,
            .size = task.sp_upper -% task.sp_lower,
            .task = task,
            .holds = 0,
            .name = undefined,
            .on = undefined,
        };
        for (task.holds) |hold| {
            if (hold.semaphore != null) seen.holds += 1;
        }
        copyName(&seen.name, task.node.name);
        seen.on[0] = 0;
        if (task.waiting_for) |semaphore| copyName(&seen.on, semaphore.link.name orelse "(no name)");
    }
};

fn copyName(into: *[name_room]u8, name: ?[*:0]const u8) void {
    const from = name orelse "";
    var i: usize = 0;
    while (i < into.len - 1 and from[i] != 0) : (i += 1) into[i] = from[i];
    into[i] = 0;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(utility_lib);
    const ub: *UtilityBase = @ptrCast(utility_lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const wanted = rdargs.string(argv[arg_name]);

    const block = sys.AllocVec(max_seen * @sizeOf(Seen), 0) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(block);
    var copied: Copied = .{ .seen = @as([*]Seen, @ptrCast(@alignCast(block)))[0..max_seen] };

    var core: u32 = 0;
    while (sys.LockCoreTasks(core)) |of_core| : (core += 1) {
        defer sys.UnlockCoreTasks(core);
        if (sys.CoreTask(core)) |task| copied.take(task, core, true);
        for ([_]*exec.List{ &of_core.ready, &of_core.wait }) |list| {
            var it = list.iterator();
            while (it.next()) |node| copied.take(@fieldParentPtr("node", node), core, false);
        }
    }

    // The stack pointers, the caller's its own; a task that ended since
    // it was copied answers nothing.
    const self = sys.FindTask(null).?;
    var here: u8 = 0;
    for (copied.seen[0..copied.count]) |*seen| {
        var spot: exec.TaskSpot = .{};
        const sp = if (seen.task == self) @intFromPtr(&here) else if (sys.GetTaskSpot(seen.task, &spot)) spot.sp else continue;
        const upper = seen.task.sp_upper;
        if (sp <= upper and upper - sp <= seen.size) seen.used = upper - sp;
    }

    _ = dl.PutStr("     #  state core  pri  waits for received  stack used/size  name\n");
    var shown: u32 = 0;
    for ([_]exec.TaskState{ .run, .ready, .wait }) |state| {
        for (copied.seen[0..copied.count]) |*seen| {
            if (seen.state != state and !(state == .wait and isOther(seen.state))) continue;
            if (wanted) |name| {
                if (ub.Stricmp(name, @ptrCast(&seen.name)) != 0) continue;
            }
            show(dl, seen);
            shown += 1;
        }
    }
    if (copied.missed != 0) _ = Printf(dl, "... and %u more\n", .{copied.missed});
    if (wanted != null and shown == 0) {
        _ = Printf(dl, "No task is called %s\n", .{wanted.?});
        return dos.RETURN_WARN;
    }
    return dos.RETURN_OK;
}

/// A state that is neither running, ready nor waiting - held by a
/// failure, being added or taken away: shown with the waiting ones.
fn isOther(state: exec.TaskState) bool {
    return state != .run and state != .ready and state != .wait;
}

fn stateName(state: exec.TaskState) [*:0]const u8 {
    return switch (state) {
        .run => "run",
        .ready => "ready",
        .wait => "wait",
        .except => "except",
        .added => "added",
        .removed => "gone",
        else => "?",
    };
}

fn show(dl: *DosBase, seen: *const Seen) void {
    _ = Printf(dl, "%6u  %-6s%4u %4d  %08x  %08x  ", .{
        seen.id,       stateName(seen.state), seen.core, @as(i32, seen.pri),
        seen.sig_wait, seen.sig_recvd,
    });
    if (seen.used) |used| {
        _ = Printf(dl, "%7zu/%-8zu ", .{ used, seen.size });
    } else {
        _ = Printf(dl, "      -/%-8zu ", .{seen.size});
    }
    _ = Printf(dl, "%s", .{@as([*:0]const u8, @ptrCast(&seen.name))});
    if (seen.on[0] != 0) _ = Printf(dl, "  on \"%s\"", .{@as([*:0]const u8, @ptrCast(&seen.on))});
    if (seen.holds != 0) _ = Printf(dl, "  holds %u", .{seen.holds});
    _ = dl.PutStr("\n");
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
