// SPDX-License-Identifier: MPL-2.0
//! Execute: runs a command in a new shell, then the commands of a stream.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _program = @import("_program.zig");
const startShell = _program.startShell;
const FileHandle = dos.FileHandle;

/// Runs a command in a new shell, which then reads more commands from a
/// stream.
///
/// SYNOPSIS:
/// ```zig
/// fn Execute(db: *DosBase, command: [*:0]const u8, input: ?*FileHandle, output: ?*FileHandle) bool
/// ```
///
/// SINCE: 1.0. LVO -540.
///
/// INPUTS:
/// - `command` - the command line to run first; "" runs nothing first.
/// - `input` - where the shell reads its commands from after `command`;
///   null is NIL:, so the shell ends after the command.
/// - `output` - where the shell writes; null is the caller's Output().
///
/// RESULT:
/// True when the shell ran, false with IoErr set when it could not start
/// (as SystemTagList).
///
/// BEHAVIOR:
/// "BootShell" is started in execute mode at priority 0 and waited for. The
/// command line is its first input, then `input`.
///
/// CONTEXT:
/// - Waits: yes. It sends packets, and a synchronous start waits for the
///   shell to end.
/// - Interrupts: not callable.
/// - Forbid: must not be held.
/// - Process: a Task will do; a process's CLI and current directory are
///   passed on, and only a process gets IoErr.
///
/// OWNERSHIP:
/// The streams stay the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SystemTagList`
///
/// EXAMPLES:
/// ```zig
/// _ = dos_lib.Execute("echo hello", null, null);
/// ```
pub fn Execute(db: *DosBase, command: [*:0]const u8, input: ?*FileHandle, output: ?*FileHandle) bool {
    const dos_lib = db.iface();
    return startShell(db, command, "BootShell", .execute, input, output orelse dos_lib.Output(), 0, null) >= 0;
}
