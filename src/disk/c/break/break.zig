// SPDX-License-Identifier: MIT
//! Break: Ctrl-C, or Ctrl-D to Ctrl-F, raised in another process, as if
//! typed at its console. Built against the SDK only.
//!
//!   Break PROCESS/N,NAME/K,ALL/S,C/S,D/S,E/S,F/S
//!
//! PROCESS is a CLI number: the one `Run` prints as `[CLI 3]`, the one a
//! shell's prompt starts with, the one `Status` shows. NAME is a pattern,
//! without case, for the command a process runs: its name as it was
//! started, path and all, then without the path, so "Copy" finds `C:Copy`
//! too and "Dir#?" every Dir. Every process whose command matches gets the
//! signals; with PROCESS as well only that one, if it matches. The shell
//! Break itself runs in is never one of them. One of PROCESS and NAME has
//! to be there.
//!
//! C, D, E and F say which signals; ALL is all four; none of them is C.
//! What the process does then is its own: a command that asks stops, a
//! process that does not ask goes on. A number no process has, or a name
//! no process runs, is said, and returns RETURN_WARN: a script that stops
//! a job that has ended goes on.
//!
//! The command a process runs is its CLI's command name, which the shell
//! sets while a command runs and empties when it has ended: a shell
//! waiting at its prompt runs nothing, and no NAME finds it.
//!
//! A process can end between FindCliProc and Signal, and leave a pointer
//! to nothing behind. So its name is read, and the signal sent, under
//! Disable, and only once the task is found there on one of exec's task
//! lists or running on a core: one that has ended is on neither.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Break";
const VERSION_STRING = "\x00$VER: Break 1.0 (27.10.2026)\r\n";

const template = "PROCESS/N,NAME/K,ALL/S,C/S,D/S,E/S,F/S";
const arg_process = 0;
const arg_name = 1;
const arg_all = 2;
/// C, D, E and F, in the order of their signals.
const arg_first_letter = 3;
const arg_count = 7;

const MSG_NOPROC = "Process %d does not exist\n";
const MSG_NONAME = "No process runs %s\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const number = rdargs.number(argv[arg_process]);
    const name = rdargs.string(argv[arg_name]);
    if (number == null and name == null) {
        _ = dl.PrintFault(dos.ERROR_REQUIRED_ARG_MISSING, COMMAND_NAME);
        return dos.RETURN_FAIL;
    }
    const signals = signalsOf(&argv);

    // The range is checked first, though FindCliProc refuses a number past
    // it itself: so the answer says which process is not there.
    var proc: ?*dos.Process = null;
    if (number) |n| {
        if (n >= 1 and n <= @as(i32, @intCast(dl.MaxCli()))) proc = dl.FindCliProc(@intCast(n));
        if (proc == null) {
            _ = Printf(dl, MSG_NOPROC, .{n});
            return dos.RETURN_WARN;
        }
    }

    const pattern = name orelse {
        if (!signalIfThere(sys, &proc.?.task, signals)) {
            _ = Printf(dl, MSG_NOPROC, .{number.?});
            return dos.RETURN_WARN;
        }
        return dos.RETURN_OK;
    };
    return byName(sys, dl, pattern, proc, signals);
}

/// The signals sent to every process whose command matches `name`, or to
/// `only` if it does.
fn byName(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8, only: ?*dos.Process, signals: u32) i32 {
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(utility_lib);
    const ub: *UtilityBase = @ptrCast(utility_lib);

    // Longer than a command name only by its wildcards.
    var pattern: [sdk.utility.pattern.parsedSize(dos.CLI_MAX_COMMAND_NAME)]u8 = undefined;
    if (ub.ParsePatternNoCase(name, &pattern, pattern.len) < 0) {
        _ = dl.PrintFault(dos.ERROR_BAD_TEMPLATE, name);
        return dos.RETURN_FAIL;
    }
    const parsed: [*:0]const u8 = @ptrCast(&pattern);

    const self = sys.FindTask(null).?;
    var hits: u32 = 0;
    var number: u32 = 1;
    const last = dl.MaxCli();
    while (number <= last) : (number += 1) {
        const proc = only orelse dl.FindCliProc(number) orelse continue;
        if (&proc.task != self) {
            var command: [dos.CLI_MAX_COMMAND_NAME]u8 = undefined;
            if (commandIfThere(sys, proc, &command) and command[0] != 0 and matches(ub, dl, parsed, @ptrCast(&command))) {
                if (signalIfThere(sys, &proc.task, signals)) hits += 1;
            }
        }
        if (only != null) break;
    }
    if (hits == 0) {
        _ = Printf(dl, MSG_NONAME, .{name});
        return dos.RETURN_WARN;
    }
    return dos.RETURN_OK;
}

/// Whether `command` matches the pattern: as it is, then without its path.
fn matches(ub: *UtilityBase, dl: *DosBase, parsed: [*:0]const u8, command: [*:0]const u8) bool {
    if (ub.MatchPatternNoCase(parsed, command)) return true;
    const file = dl.FilePart(command);
    return file != command and ub.MatchPatternNoCase(parsed, file);
}

/// The signals the switches ask for: ALL is the four, none is Ctrl-C.
fn signalsOf(argv: *const [arg_count]usize) u32 {
    const all = exec.SIGBREAKF_CTRL_C | exec.SIGBREAKF_CTRL_D | exec.SIGBREAKF_CTRL_E | exec.SIGBREAKF_CTRL_F;
    if (argv[arg_all] != 0) return all;
    var signals: u32 = 0;
    for (0..4) |i| {
        if (argv[arg_first_letter + i] != 0) signals |= exec.SIGBREAKF_CTRL_C << @intCast(i);
    }
    return if (signals != 0) signals else exec.SIGBREAKF_CTRL_C;
}

/// `signals` raised in `task`, if it is still there. False when it has
/// ended.
fn signalIfThere(sys: *ExecBase, task: *exec.Task, signals: u32) bool {
    sys.Disable();
    defer sys.Enable();
    if (!isThere(sys, task)) return false;
    sys.Signal(task, signals);
    return true;
}

/// The command `proc` runs, copied into `into` - empty when it runs none -
/// if it is still there. False when it has ended.
fn commandIfThere(sys: *ExecBase, proc: *dos.Process, into: *[dos.CLI_MAX_COMMAND_NAME]u8) bool {
    into[0] = 0;
    sys.Disable();
    defer sys.Enable();
    if (!isThere(sys, &proc.task)) return false;
    const cli = proc.cli orelse return true;
    const command = cli.command_name orelse return true;
    var i: usize = 0;
    while (i < into.len - 1 and command[i] != 0) : (i += 1) into[i] = command[i];
    into[i] = 0;
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
