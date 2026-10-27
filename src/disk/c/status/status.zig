// SPDX-License-Identifier: MIT
//! Status: the CLI processes, and the command each one runs. Built against
//! the SDK only.
//!
//!   Status PROCESS/N,FULL/S,TCB/S,CLI=ALL/S,COM=COMMAND/K
//!
//! Without arguments every CLI process by its number, with the command it
//! runs:
//!
//!   Process 1: Loaded as command: Status
//!   Process 2: No command loaded
//!
//! PROCESS shows that one only. TCB shows, in place of the command, the
//! stack its commands get (the CLI's, in bytes, as `Stack` sets it) and
//! the process's priority; FULL shows both; CLI, or ALL, the command
//! only, as no switch does. The Amiga's "gv", the size of a BCPL global
//! vector, has nothing to stand for here and is left out.
//!
//! COMMAND names a command: the numbers of the processes running it, one
//! a line, and RETURN_OK; none, and RETURN_WARN. It is compared without
//! case with the name the command was started by, then with that name
//! without its path: COMMAND=Copy finds `C:Copy`. The line is what Break
//! reads with "?":
//!
//!   Status >T:job COMMAND=Copy
//!   Break <T:job >NIL: ?
//!
//! The command is the CLI's command name, which the shell sets while a
//! command runs and empties when it has ended: a shell waiting at its
//! prompt has none loaded. A process with a CLI and no shell - the
//! desktop - shows the name it was started with. A number no process has
//! is said, and returns RETURN_WARN.
//!
//! A process can end between FindCliProc and the reading of it, and leave
//! a pointer to nothing behind. So each one is read under Disable, and
//! only once its task is found there on one of exec's task lists or
//! running on a core: one that has ended is on neither, and is left out.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Status";
const VERSION_STRING = "\x00$VER: Status 1.0 (27.10.2026)\r\n";

const template = "PROCESS/N,FULL/S,TCB/S,CLI=ALL/S,COM=COMMAND/K";
const arg_process = 0;
const arg_full = 1;
const arg_tcb = 2;
const arg_cli = 3;
const arg_command = 4;
const arg_count = 5;

const MSG_NOPROC = "Process %d does not exist\n";

/// What is shown of one process, read under Disable.
const Seen = struct {
    command: [dos.CLI_MAX_COMMAND_NAME]u8 = undefined,
    stack: u32 = 0,
    pri: i8 = 0,
};

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

    const full = argv[arg_full] != 0;
    const tcb = full or argv[arg_tcb] != 0;
    const loaded = full or argv[arg_cli] != 0 or !tcb;
    const wanted = rdargs.string(argv[arg_command]);

    // The range is checked first, though FindCliProc refuses a number past
    // it itself: so the answer says which process is not there.
    const only = rdargs.number(argv[arg_process]);
    var first: u32 = 1;
    var last = dl.MaxCli();
    if (only) |n| {
        if (n < 1 or n > @as(i32, @intCast(last)) or dl.FindCliProc(@intCast(n)) == null) {
            _ = Printf(dl, MSG_NOPROC, .{n});
            return dos.RETURN_WARN;
        }
        first = @intCast(n);
        last = first;
    }

    var hits: u32 = 0;
    var number = first;
    while (number <= last) : (number += 1) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            _ = dl.PrintFault(dos.ERROR_BREAK, null);
            return dos.RETURN_WARN;
        }
        const proc = dl.FindCliProc(number) orelse continue;
        var seen: Seen = .{};
        if (!readIfThere(sys, proc, &seen)) {
            if (only != null) {
                _ = Printf(dl, MSG_NOPROC, .{number});
                return dos.RETURN_WARN;
            }
            continue;
        }
        const command: [*:0]const u8 = @ptrCast(&seen.command);
        if (wanted) |name| {
            if (command[0] != 0 and runs(ub, dl, command, name)) {
                _ = Printf(dl, "%d\n", .{number});
                hits += 1;
            }
            continue;
        }
        _ = Printf(dl, "Process %d: ", .{number});
        if (tcb) _ = Printf(dl, "stk %d, pri %d", .{ seen.stack, seen.pri });
        if (tcb and loaded) _ = dl.PutStr(" ");
        if (loaded) {
            if (command[0] != 0) {
                _ = Printf(dl, "Loaded as command: %s", .{command});
            } else {
                _ = dl.PutStr("No command loaded");
            }
        }
        _ = dl.PutStr("\n");
    }
    if (wanted != null and hits == 0) return dos.RETURN_WARN;
    return dos.RETURN_OK;
}

/// Whether `command` is `name`, without case: as it is, then without its
/// path.
fn runs(ub: *UtilityBase, dl: *DosBase, command: [*:0]const u8, name: [*:0]const u8) bool {
    if (ub.Stricmp(command, name) == 0) return true;
    const file = dl.FilePart(command);
    return file != command and ub.Stricmp(file, name) == 0;
}

/// `proc`'s command, its CLI's stack and its priority, copied into `seen`
/// if it is still there. False when it has ended.
fn readIfThere(sys: *ExecBase, proc: *dos.Process, seen: *Seen) bool {
    seen.command[0] = 0;
    sys.Disable();
    defer sys.Enable();
    if (!isThere(sys, &proc.task)) return false;
    seen.pri = proc.task.node.pri;
    const cli = proc.cli orelse return true;
    seen.stack = cli.default_stack;
    const command = cli.command_name orelse return true;
    var i: usize = 0;
    while (i < seen.command.len - 1 and command[i] != 0) : (i += 1) seen.command[i] = command[i];
    seen.command[i] = 0;
    return true;
}

/// Whether `task` is there, asked under Disable: running on a core or on
/// one of exec's task queues.
fn isThere(sys: *ExecBase, task: *exec.Task) bool {
    var core: u32 = 0;
    while (sys.CoreTask(core)) |running| : (core += 1) {
        if (running == task) return true;
    }
    for ([_]u32{ exec.EXECLIST_TASK_READY, exec.EXECLIST_TASK_WAIT }) |which| {
        const list = sys.LockExecList(which) orelse continue;
        defer sys.UnlockExecList(which);
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
