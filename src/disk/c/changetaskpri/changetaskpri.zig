// SPDX-License-Identifier: MIT
//! ChangeTaskPri: the priority of a process, its own by default. Built against
//! the SDK only.
//!
//!   ChangeTaskPri PRI=PRIORITY/A/N,PROCESS/K/N
//!
//! PROCESS is a CLI number, as `clis` and `Status` show them. Without it
//! the shell running the command is the one that changes, which is what a
//! script uses to put itself out of the way.
//!
//! A process can end between FindCliProc and SetTaskPri, and leave a
//! pointer to nothing behind. So the change is made under Disable, and
//! only once the task is found there on one of exec's task lists or
//! running on a core: one that has ended is on neither.
//!
//! The range is checked against MaxCli before FindCliProc is asked, although
//! FindCliProc refuses a number past it itself: the check is what makes
//! "Process 99 does not exist" come out instead of a plain failure.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "ChangeTaskPri";
const VERSION_STRING = "\x00$VER: ChangeTaskPri 1.1 (04.11.2026)\r\n";

const template = "PRI=PRIORITY/A/N,PROCESS/K/N";
const arg_pri = 0;
const arg_process = 1;

const MSG_NOPROC = "Process %d does not exist\n";
const MSG_BADPRI = "Priority out of range (-128 to +127)\n";

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

    // /A/N, so it is there.
    const pri = rdargs.number(argv[arg_pri]).?;
    if (pri < -128 or pri > 127) {
        _ = dl.PutStr(MSG_BADPRI);
        return dos.RETURN_FAIL;
    }

    var task = sys.FindTask(null);
    var missing: i32 = 0;
    if (rdargs.number(argv[arg_process])) |number| {
        if (number < 1 or number > @as(i32, @intCast(dl.MaxCli()))) {
            missing = number;
        } else if (dl.FindCliProc(@intCast(number))) |proc| {
            task = &proc.task;
        } else {
            missing = number;
        }
    }
    if (missing == 0 and !setIfThere(sys, task.?, @intCast(pri))) missing = rdargs.number(argv[arg_process]).?;

    if (missing != 0) {
        _ = Printf(dl, MSG_NOPROC, .{missing});
        return dos.RETURN_FAIL;
    }
    return dos.RETURN_OK;
}

/// `task`'s priority set, if it is still there: under Disable, running on
/// a core or on one of exec's task queues. False when it has ended.
fn setIfThere(sys: *ExecBase, task: *exec.Task, pri: i8) bool {
    // Each core's tasks under that core's lock, one core at a time: the
    // priority is set while the core the task was found on is still
    // held, so it cannot have ended in between.
    var core: u32 = 0;
    while (sys.LockCoreTasks(core)) |tasks| : (core += 1) {
        defer sys.UnlockCoreTasks(core);
        if (sys.CoreTask(core) != task and !onLists(tasks, task)) continue;
        _ = sys.SetTaskPri(task, pri);
        return true;
    }
    return false;
}

/// Whether `task` is on either of `tasks`' lists, with that core's lock
/// held.
fn onLists(tasks: *exec.CoreTasks, task: *exec.Task) bool {
    for ([_]*exec.List{ &tasks.ready, &tasks.wait }) |list| {
        var it = list.iterator();
        while (it.next()) |node| {
            if (node == &task.node) return true;
        }
    }
    return false;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
