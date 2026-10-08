// SPDX-License-Identifier: MPL-2.0
//! GetArgList: the files the running process was started with.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _process = @import("_process.zig");
const currentProcess = _process.currentProcess;

/// Returns the files the calling process was started with, each a lock
/// and a name.
///
/// SYNOPSIS:
/// ```zig
/// fn GetArgList(db: *DosBase, num_args: ?*u32) ?[*]const WBArg
/// ```
///
/// SINCE: 1.4. LVO -564.
///
/// INPUTS:
/// - `num_args` - where to put how many there are; may be null.
///
/// RESULT:
/// The process's pairs (pr_ArgList), and their count in `num_args`; null
/// and 0 for a process started without them, and from a plain task.
///
/// BEHAVIOR:
/// What the launcher handed CreateNewProc as NP_ArgList, as the process's
/// own copy: the program itself first - a lock on its drawer and its
/// name - then each file it was given, a lock on the drawer the file is in
/// and its name, or for a drawer or a volume a lock on itself and an
/// empty name. A program started from a shell has none. The same files
/// are on its command line, which ReadArgs reads; the pairs are for a
/// program that wants them as locks, to work in the drawer a file is in
/// or to stay with a file renamed meanwhile.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a process; a plain task gets null.
///
/// OWNERSHIP:
/// The pairs, their locks and their names stay the process's and are
/// freed when it ends. A program that wants a lock past that, or wants to
/// give it to another process, DupLocks it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetArgStr`, `CreateNewProc`, `SystemTagList`
///
/// EXAMPLES:
/// ```zig
/// var count: u32 = 0;
/// if (dos_lib.GetArgList(&count)) |files| {
///     for (files[1..count]) |file| {
///         const old = dos_lib.CurrentDir(file.lock);
///         defer _ = dos_lib.CurrentDir(old);
///         // open file.name here
///     }
/// }
/// ```
pub fn GetArgList(db: *DosBase, num_args: ?*u32) ?[*]const dos.WBArg {
    const sys = db.sys_base;
    const proc = currentProcess(sys) orelse {
        if (num_args) |count| count.* = 0;
        return null;
    };
    if (num_args) |count| count.* = if (proc.arg_list != null) proc.num_args else 0;
    return proc.arg_list;
}
