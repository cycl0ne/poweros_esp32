// SPDX-License-Identifier: MPL-2.0
//! Cli: the running process's CommandLineInterface.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const process = @import("_process.zig");

/// Returns the running process's CommandLineInterface, or null when it
/// has none.
///
/// SYNOPSIS:
/// ```zig
/// fn Cli(db: *DosBase) ?*dos.CommandLineInterface
/// ```
///
/// SINCE: 1.0. LVO -252.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// pr_CLI of the running process: the CLI structure of a shell or of a
/// program it runs, or null for a process started without one and for a
/// plain Task.
///
/// BEHAVIOR:
/// A process has a CLI only when it was created with NP_Cli, so the
/// answer also tells a CLI process from any other. Nothing is allocated
/// or checked.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not safe; it reads the running task's Process.
/// - Forbid: not needed, and not taken.
/// - Process: a Process for an answer; a plain Task gets null.
///
/// OWNERSHIP:
/// The structure belongs to the process; the caller may read and change
/// its fields while it runs, and never frees it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetProgramName`, `GetPrompt`, `CreateNewProc`
///
/// EXAMPLES:
/// ```zig
/// const cli = dos_lib.Cli() orelse return error.NotACli;
/// const fail_level = cli.fail_level;
/// ```
pub fn Cli(db: *DosBase) ?*dos.CommandLineInterface {
    const proc = process.currentProcess(db.sys_base) orelse return null;
    return proc.cli;
}
