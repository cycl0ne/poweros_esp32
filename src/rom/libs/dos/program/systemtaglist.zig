// SPDX-License-Identifier: MPL-2.0
//! SystemTagList: runs a command line, or an interactive shell, in a new
//! shell.

const sdk = @import("sdk");
const dos = sdk.dos;
const utility = sdk.utility;
const DosBase = @import("../dos_base.zig").DosBase;
const _program = @import("_program.zig");
const files = @import("../file/_file.zig");
const startShell = _program.startShell;
const FileHandle = dos.FileHandle;
const TagItem = utility.TagItem;

/// Runs a command line, or an interactive shell, in a new shell process.
///
/// SYNOPSIS:
/// ```zig
/// fn SystemTagList(db: *DosBase, command: ?[*:0]const u8, tags: ?[*]const TagItem) i32
/// ```
///
/// SINCE: 1.0. LVO -536.
///
/// INPUTS:
/// - `command` - the command line, one line or several; null starts an
///   interactive shell reading SYS_Input.
/// - `tags` - SYS_Input, SYS_Output, SYS_Asynch, SYS_UserShell,
///   SYS_CustomShell, SYS_Window, SYS_ScriptFile, and CreateNewProc's own
///   NP_* tags, which pass through (except the ones that make the process a
///   shell: NP_Seglist, NP_Entry, NP_Input, NP_Output, NP_Close*, NP_Cli).
///
/// RESULT:
/// The shell's last return code, with IoErr its Result2. With SYS_Asynch,
/// the new CLI's number. -1 when the shell could not start, with IoErr set:
/// ERROR_OBJECT_NOT_FOUND when there is no such shell, ERROR_OBJECT_IN_USE
/// for an interactive shell on a console another shell reads,
/// ERROR_NO_FREE_STORE, or the error of opening a stream.
///
/// BEHAVIOR:
/// The shell is "BootShell", "shell" with SYS_UserShell, or the resident
/// SYS_CustomShell names. Its streams are SYS_Input and SYS_Output, by
/// default the caller's Input() and Output(); a missing one is NIL:.
/// SYS_Window, when no stream is given, opens that console once and gives
/// the shell both directions of it, since a console that makes a window
/// makes one per Open; the shell closes them. Without SYS_Asynch the call
/// waits for the shell to end; with it the call returns at once, and the
/// shell closes the streams it was given. SYS_ScriptFile, for an
/// interactive shell, is read before the input and closed by the shell.
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
/// Without SYS_Asynch the streams stay the caller's. With SYS_Asynch they
/// become the shell's, and so does a SYS_ScriptFile. The tag list is
/// copied.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Execute`, `CreateNewProc`, `RunCommand`
///
/// EXAMPLES:
/// ```zig
/// const rc = dos_lib.SystemTagList("dir RAM:", null);
/// if (rc < 0) _ = dos_lib.PrintFault(dos_lib.IoErr(), "SystemTagList");
/// ```
pub fn SystemTagList(db: *DosBase, command: ?[*:0]const u8, tags: ?[*]const TagItem) i32 {
    const dos_lib = db.iface();
    const ub = db.utility_base;
    const asynch = ub.GetTagData(dos.SYS_Asynch, 0, tags) != 0;
    var extra: isize = 0;
    // SYS_Window: the console named is opened here, once, and the shell
    // gets both directions of the one handler - a console name that makes
    // a window makes one per Open, so opening it twice would be two
    // windows. Only when neither stream is given: a caller that hands over
    // streams has said what it wants.
    const window: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(dos.SYS_Window, 0, tags));
    const streams_given = ub.FindTagItem(dos.SYS_Input, tags) != null or ub.FindTagItem(dos.SYS_Output, tags) != null;
    var input: ?*FileHandle = null;
    var output: ?*FileHandle = null;
    if (window != null and !streams_given) {
        const name = window.?;
        output = dos_lib.Open(name, dos.MODE_NEWFILE) orelse return -1;
        // A name with no handler behind it (NIL:) is no console to read.
        const console = output.?.task orelse {
            _ = dos_lib.Close(output);
            _ = dos_lib.SetIoErr(dos.ERROR_OBJECT_WRONG_TYPE);
            return -1;
        };
        input = files.openOnPort(db, console, name, dos.MODE_OLDFILE) orelse {
            const err = dos_lib.IoErr();
            _ = dos_lib.Close(output);
            _ = dos_lib.SetIoErr(err);
            return -1;
        };
        // The shell closes what dos opened for it.
        extra = dos.SHF_CLOSE_INPUT | dos.SHF_CLOSE_OUTPUT;
    } else {
        input = @ptrFromInt(ub.GetTagData(dos.SYS_Input, @intFromPtr(dos_lib.Input()), tags));
        output = @ptrFromInt(ub.GetTagData(dos.SYS_Output, @intFromPtr(dos_lib.Output()), tags));
    }
    const boot_shell: [*:0]const u8 = "BootShell";
    const shell_name: [*:0]const u8 = if (ub.GetTagData(dos.SYS_UserShell, 0, tags) != 0)
        "shell"
    else
        @ptrFromInt(ub.GetTagData(dos.SYS_CustomShell, @intFromPtr(boot_shell), tags));
    const mode: dos.ShellMode = if (command == null) .interactive else .system;
    const flags: isize = extra | (if (asynch) dos.SHF_ASYNCH | dos.SHF_CLOSE_INPUT | dos.SHF_CLOSE_OUTPUT else 0);
    return startShell(db, command, shell_name, mode, input, output, flags, tags);
}
