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
//! It is Forbid()den across the lookup and the change: a
//! process that ends between FindCliProc and SetTaskPri would leave a
//! pointer to nothing behind.
//!
//! The range is checked against MaxCli before FindCliProc is asked, although
//! FindCliProc refuses a number past it itself: the check is what makes
//! "Process 99 does not exist" come out instead of a plain failure.

const sdk = @import("sdk");
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "ChangeTaskPri";
const VERSION_STRING = "\x00$VER: ChangeTaskPri 1.0 (16.9.2026)\r\n";

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

    // Nothing may end between finding the process and changing it.
    sys.Forbid();
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
    if (missing == 0) _ = sys.SetTaskPri(task.?, @intCast(pri));
    sys.Permit();

    if (missing != 0) {
        // Printing breaks the Forbid; by then there is nothing left to hold
        // still.
        _ = Printf(dl, MSG_NOPROC, .{missing});
        return dos.RETURN_FAIL;
    }
    return dos.RETURN_OK;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
