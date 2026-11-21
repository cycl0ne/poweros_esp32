// SPDX-License-Identifier: MIT
//! Kill: a task that is stuck ended from outside it. Built against the
//! SDK only.
//!
//!   Kill TASK/A
//!
//! TASK is a task's number, as `Tasks` shows it, or its name. The task is
//! ended as Kill on the Software Failure requester ends one (`KillTask`):
//! whatever it is doing is dropped, it lets go of the semaphores it
//! holds, its end runs on its own stack and its private memory is freed.
//! A file it had open stays open, and what it allocated and did not free
//! stays allocated, as an ended task's: it is the way out of a task that
//! does not answer Ctrl-C (`Break`), not a way to stop one that does.
//!
//! Not the shell Kill runs in, and not one of exec's own tasks: those are
//! refused, and so is a number no task has, with RETURN_WARN.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Kill";
const VERSION_STRING = "\x00$VER: Kill 1.0 (21.11.2026)\r\n";

const template = "TASK/A";
const arg_task = 0;
const arg_count = 1;

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
    const wanted = rdargs.string(argv[arg_task]).?;

    const task = findTask(sys, dl, wanted) orelse {
        _ = Printf(dl, "No task %s\n", .{wanted});
        return dos.RETURN_WARN;
    };
    const id = task.id;
    var name: [40]u8 = undefined;
    const from = task.node.name orelse "";
    var i: usize = 0;
    while (i < name.len - 1 and from[i] != 0) : (i += 1) name[i] = from[i];
    name[i] = 0;

    if (!sys.KillTask(task)) {
        _ = Printf(dl, "Task %u \"%s\" cannot be killed: it is this shell, one of exec's own, or has ended\n", .{ id, @as([*:0]const u8, @ptrCast(&name)) });
        return dos.RETURN_WARN;
    }
    _ = Printf(dl, "Task %u \"%s\" ends\n", .{ id, @as([*:0]const u8, @ptrCast(&name)) });
    return dos.RETURN_OK;
}

/// The task `text` names: its number, or else its name.
fn findTask(sys: *ExecBase, dl: *DosBase, text: [*:0]const u8) ?*exec.Task {
    var number: i32 = 0;
    const used = dl.StrToLong(text, &number);
    if (used > 0 and text[@intCast(used)] == 0 and number >= 0) return sys.FindTaskById(@intCast(number));
    return sys.FindTask(text);
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
