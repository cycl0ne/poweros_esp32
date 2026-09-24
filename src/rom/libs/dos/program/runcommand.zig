// SPDX-License-Identifier: MPL-2.0
//! RunCommand: runs a command's code on the calling process, on a stack
//! of its own.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _program = @import("_program.zig");
const process = @import("../process/_process.zig");
const buffered = @import("../file/_file.zig");
const callCommand = _program.callCommand;
const Call = _program.Call;
const failRun = _program.failRun;

/// Runs a command's code on the calling process, on a stack of its own,
/// with an argument line.
///
/// SYNOPSIS:
/// ```zig
/// fn RunCommand(db: *DosBase, code: ?*const dos.SegCode, stack_size: u32, args: [*]const u8, length: isize) i32
/// ```
///
/// SINCE: 1.0. LVO -532.
///
/// INPUTS:
/// - `code` - the code; its `command` is what runs.
/// - `stack_size` - the stack the command gets, in bytes.
/// - `args` - the argument line; it should end in a newline, as a
///   shell's does, since past it ReadArgs reads Input() itself.
/// - `length` - how many bytes of `args`; 0 or less for none.
///
/// RESULT:
/// The command's return code, or -1 with IoErr when it couldn't run:
/// ERROR_OBJECT_WRONG_TYPE for code without a command, ERROR_NO_PROCESS
/// from a plain Task, ERROR_NO_FREE_STORE for no memory for the
/// arguments' copy or the stack.
///
/// BEHAVIOR:
/// The line is copied and NUL-terminated. While the command runs, the
/// copy is pr_Arguments (GetArgStr) and is lent to Input()'s buffer as
/// read-ahead; pr_Result2 starts at 0. The command is called on a stack
/// of `stack_size` bytes from NewStackRun. Afterwards pr_Arguments and
/// Input()'s buffer are put back as they were.
///
/// CONTEXT:
/// - Waits: whatever the command does.
/// - Interrupts: not safe.
/// - Forbid: not to be held; the command may wait.
/// - Process: a Process.
///
/// OWNERSHIP:
/// The copy of the line and the stack are freed when the command
/// returns. `code` and `args` stay the caller's. The command frees
/// whatever it allocates.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SystemTagList`, `GetArgStr`, `ReadArgs`, `FindSegment`
///
/// EXAMPLES:
/// ```zig
/// const line = "ram:\n";
/// const rc = dos_lib.RunCommand(&seg.code, 8192, line, line.len);
/// if (rc == -1) return dos_lib.IoErr();
/// ```
pub fn RunCommand(db: *DosBase, code: ?*const dos.SegCode, stack_size: u32, args: [*]const u8, length: isize) i32 {
    const sys = db.sys_base;
    const command = (if (code) |c| c.command else null) orelse return failRun(db, dos.ERROR_OBJECT_WRONG_TYPE);
    const proc = process.currentProcess(sys) orelse return failRun(db, dos.ERROR_NO_PROCESS);
    const len: usize = if (length > 0) @intCast(length) else 0;
    const block = sys.AllocVec(len + 1, exec.MEMF_ANY) orelse return failRun(db, dos.ERROR_NO_FREE_STORE);
    defer sys.FreeVec(block);
    const copy: [*]u8 = @ptrCast(block);
    @memcpy(copy[0..len], args[0..len]);
    copy[len] = 0;

    const input = proc.cis;
    var lent: buffered.Lent = undefined;
    if (input) |fh| lent = buffered.lend(db, fh, copy[0..len]);
    const old_args = proc.arguments;
    proc.arguments = @ptrCast(copy);
    proc.result2 = 0;

    var call: Call = .{ .sys = sys, .command = command, .args = copy, .len = len };
    const rc = sys.NewStackRun(&callCommand, &call, stack_size);

    proc.arguments = old_args;
    if (input) |fh| buffered.giveBack(db, fh, lent);
    // The command never ran: its stack couldn't be had.
    if (!call.started) proc.result2 = dos.ERROR_NO_FREE_STORE;
    return rc;
}
