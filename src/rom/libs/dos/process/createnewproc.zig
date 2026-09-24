// SPDX-License-Identifier: MPL-2.0
//! CreateNewProc: starts a process.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _process = @import("_process.zig");
const objects = @import("../packet/_packet.zig");
const processEnd = _process.processEnd;
const endProcess = _process.endProcess;
const setUpContext = _process.setUpContext;
const makeCli = _process.makeCli;
const initMsgPort = _process.initMsgPort;
/// The least stack CreateNewProc gives, whatever NP_StackSize says.
const min_stack_size = 1024;
/// What " [nn]" costs, with room for the NUL: the table holds 32 CLIs, so
/// the number is never more than two digits.
const cli_suffix_max = 6;
/// The stack a process gets without NP_StackSize.
const default_stack_size = 8192;
/// The name a process gets without NP_Name.
const default_name = "New Process";
const currentProcess = _process.currentProcess;
const Process = dos.Process;
const TagItem = sdk.utility.TagItem;

/// Starts a new process, set up from a tag list.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateNewProc(db: *DosBase, tags: ?[*]const TagItem) ?*Process
/// ```
///
/// SINCE: 1.0. LVO -56.
///
/// INPUTS:
/// - `tags` - the process's description:
///   NP_Entry (the TaskFn it runs; required unless NP_Seglist),
///   NP_Seglist (a SegCode whose entry runs instead),
///   NP_Name (default "New Process"), NP_StackSize (default 8192, at least
///   1024), NP_Priority (default the caller's),
///   NP_ConsoleTask, NP_WindowPtr,
///   NP_Input, NP_Output, NP_Error (the streams; default none) with
///   NP_CloseInput, NP_CloseOutput (default true) and NP_CloseError
///   (default false),
///   NP_CurrentDir, NP_HomeDir (taken over; default a DupLock of the
///   caller's),
///   NP_Arguments (copied), NP_ExitCode and NP_ExitData,
///   NP_UserData (tc_UserData, there before the process first runs),
///   NP_CopyVars (default true: the caller's local variables are copied),
///   NP_Cli (a CLI of its own) with NP_CommandName and NP_Path.
///
/// RESULT:
/// The running process, or null with IoErr(): ERROR_REQUIRED_ARG_MISSING
/// without an entry, ERROR_OBJECT_WRONG_TYPE for a SegCode without one,
/// ERROR_LINE_TOO_LONG for an NP_CommandName that doesn't fit a CLI,
/// ERROR_TASK_TABLE_FULL when all CLI numbers are taken,
/// ERROR_NO_FREE_STORE, or the error of a DupLock.
///
/// BEHAVIOR:
/// The Process, its name, its CLI and its stack are one block, which exec
/// frees when the process is gone. From a calling process it takes
/// pr_ConsoleTask, pr_FileSystemTask and a pr_WindowPtr of 0 or -1. With
/// NP_Cli the process gets a CLI with the caller's prompt (or
/// CLI_DEFAULT_PROMPT), command name, directory name and fail level, its
/// stack size, the command path of NP_Path or of the caller's CLI (each
/// node's lock copied), and the lowest free CLI number in pr_TaskNum -
/// which is also put after its name, as " [n]", so that two shells can be
/// told apart in a list of tasks.
/// When the process's code returns, its exit hook (NP_ExitCode) is called
/// with NP_ExitData, then its CLI number, local variables, streams (as the
/// close flags say), directories, command path and argument copy go.
/// If a step after the block was made fails, what dos made is undone and
/// the block freed.
///
/// CONTEXT:
/// - Waits: yes: DupLock sends packets, and the CLI table is a semaphore.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Task will do; it then passes nothing on and there is
///   nothing to copy.
///
/// OWNERSHIP:
/// The process owns what the tags hand it - the streams it will close, the
/// directories, the exit hook - from the moment the call succeeds. On
/// failure the caller keeps them.
///
/// BUGS:
/// If duplicating the caller's home directory fails after NP_CurrentDir was
/// given, the given current directory is unlocked although the caller keeps
/// it.
///
/// SEE ALSO:
/// `SystemTagList`, `RunCommand`, `FindCliProc`
///
/// EXAMPLES:
/// ```zig
/// const tags = [_]TagItem{
///     .{ .tag = dos.NP_Entry, .data = @intFromPtr(&worker) },
///     .{ .tag = dos.NP_Name, .data = @intFromPtr("worker") },
///     .{},
/// };
/// _ = dos_lib.CreateNewProc(&tags) orelse return dos_lib.IoErr();
/// ```
pub fn CreateNewProc(db: *DosBase, tags: ?[*]const TagItem) ?*Process {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    const ub = db.utility_base;
    const seg_code: ?*const dos.SegCode = @ptrFromInt(ub.GetTagData(dos.NP_Seglist, 0, tags));
    const entry: exec.TaskFn = if (seg_code) |c| c.entry orelse {
        _ = dos_lib.SetIoErr(dos.ERROR_OBJECT_WRONG_TYPE);
        return null;
    } else @as(?exec.TaskFn, @ptrFromInt(ub.GetTagData(dos.NP_Entry, 0, tags))) orelse {
        _ = dos_lib.SetIoErr(dos.ERROR_REQUIRED_ARG_MISSING);
        return null;
    };
    const parent_task = sys.FindTask(null).?;
    const parent = currentProcess(sys);

    const name: [*:0]const u8 = @ptrFromInt(ub.GetTagData(dos.NP_Name, @intFromPtr(default_name), tags));
    const name_len = db.utility_base.Strlen(name);
    const pri_data: isize = @bitCast(ub.GetTagData(dos.NP_Priority, @bitCast(@as(isize, parent_task.node.pri)), tags));
    const pri: i8 = @truncate(pri_data);
    const stack_request = ub.GetTagData(dos.NP_StackSize, default_stack_size, tags);

    const with_cli = ub.GetTagData(dos.NP_Cli, 0, tags) != 0;
    const command_name: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(dos.NP_CommandName, 0, tags));
    if (with_cli) if (command_name) |n| if (db.utility_base.Strlen(n) >= dos.CLI_MAX_COMMAND_NAME) {
        _ = dos_lib.SetIoErr(dos.ERROR_LINE_TOO_LONG);
        return null;
    };

    // A process with a CLI is told which one it is, in its own name, so
    // room is left here for " [nn]": the name is copied in at the length
    // it came with, and the number is only known once a slot is taken.
    const cli_at = ub.AlignUp(@sizeOf(Process) + name_len + 1 + (if (with_cli) @as(usize, cli_suffix_max) else 0), 16);
    const header = if (with_cli) ub.AlignUp(cli_at + objects.cli_block_size, 16) else cli_at;
    const stack = ub.AlignUp(@max(stack_request, min_stack_size), 16);
    const total = header + stack;
    const block = sys.AllocMem(total, exec.MEMF_CLEAR) orelse {
        _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return null;
    };
    const bytes: [*]u8 = @ptrCast(block);
    const name_dst = bytes + @sizeOf(Process);
    @memcpy(name_dst[0..name_len], name[0..name_len]);
    name_dst[name_len] = 0;

    const proc: *Process = @ptrCast(@alignCast(block));
    proc.* = .{
        .task = .{
            .node = .{ .type = .process, .pri = pri, .name = @ptrCast(name_dst) },
            .sp_lower = @intFromPtr(bytes + header),
            .sp_upper = @intFromPtr(bytes + total),
            .mem_block = block,
            .mem_size = total,
            .user_data = @ptrFromInt(ub.GetTagData(dos.NP_UserData, 0, tags)),
        },
        .stack_size = @intCast(stack),
        .stack_base = @intFromPtr(bytes + total),
    };
    initMsgPort(proc);
    proc.local_vars.init();

    if (parent) |p| {
        proc.console_task = p.console_task;
        proc.file_system_task = p.file_system_task;
        const wp = @intFromPtr(p.window_ptr);
        if (wp == 0 or wp == std.math.maxInt(usize)) proc.window_ptr = p.window_ptr;
    }
    proc.console_task = @ptrFromInt(ub.GetTagData(dos.NP_ConsoleTask, @intFromPtr(proc.console_task), tags));
    proc.window_ptr = @ptrFromInt(ub.GetTagData(dos.NP_WindowPtr, @intFromPtr(proc.window_ptr), tags));
    if (with_cli) proc.cli = makeCli(db, bytes + cli_at, if (parent) |p| p.cli else null, command_name, stack);

    if (!setUpContext(db, proc, parent, tags)) {
        const code = dos_lib.IoErr();
        endProcess(db, proc);
        sys.FreeMem(block, total);
        _ = dos_lib.SetIoErr(code);
        return null;
    }
    _ = sys.AddTask(&proc.task, entry, &processEnd);
    return proc;
}
