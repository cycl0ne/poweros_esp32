// SPDX-License-Identifier: MPL-2.0
//! A process and its context: IoErr, making processes, the CLI and the
//! process's names and streams, and variables.
//!
//! Processes: IoErr and SetIoErr on pr_Result2, CreateNewProc and what
//! happens when a process ends, the CLI numbers, CheckSignal and the
//! argument line.
//!
//! CreateNewProc makes one block of the Process, its name, its CLI (with
//! NP_Cli) and its stack, so that exec's RemTask frees everything with
//! the one mem_block it knows about. The steps that can fail - copying the
//! arguments, the variables, the command path, duplicating directories,
//! taking a CLI number - come first, and undo only what dos made; the
//! streams, locks and exit hook the caller hands over are only taken once
//! nothing can fail any more, so a failed call leaves them the caller's.
//!
//! A process ends through exec's finalPC, processEnd, which runs on the
//! process itself: the exit hook, then the CLI number, the variables, the
//! streams (as its flags say), the directories, the command path and the
//! argument copy go - endProcess, which a failed CreateNewProc uses too.
//!
//! The CLI numbers are a table in the base, under its own semaphore: a
//! CLI takes the lowest free slot, and pr_TaskNum is the slot plus 1.
//! NP_StackSize defaults to 8 KiB because compiled code here uses a
//! register window stack and a few KiB is gone before any real work.
//! Without NP_Input/NP_Output a process has no streams at all rather than
//! NIL: - NIL: is itself a handler started through CreateNewProc.
//!
//! IoErr from a plain task is ERROR_NO_PROCESS: a task has no pr_Result2,
//! and a clear error beats a read past the Task. SetIoErr from a task does
//! nothing.
//!
//! The running process's context: its CLI (Cli), the error stream
//! (SelectError, ErrorOutput), the console and default file system
//! handlers, the program's directory, the CLI's names - command name,
//! prompt, current directory's name - and NameFromLock and NameFromFH.
//! CurrentDir, Input, Output, SelectInput and SelectOutput are in lock/
//! and file/.
//!
//! Every call here works on the running process: its fields are the
//! process's own, read and written by no one else while it runs, so
//! nothing is locked. A plain Task has none of them: its getters answer
//! null (or an empty buffer and false) and its setters change nothing.
//!
//! pr_CLI is null unless the process was made with a CLI, so Cli() is
//! also how a program tells whether it runs from a shell. The CLI's
//! names are NUL-terminated strings in buffers of CLI_MAX_* bytes, laid
//! out behind the structure by AllocDosObject(DOS_CLI):
//! - a getter always leaves a string in the caller's buffer; one that
//!   had to cut it answers false with ERROR_LINE_TOO_LONG, so the
//!   caller knows it has a part;
//! - a setter refuses a name that doesn't fit with ERROR_LINE_TOO_LONG
//!   and changes nothing, since a cut name would be a different, wrong
//!   name;
//! - without a CLI the getters answer false with
//!   ERROR_OBJECT_WRONG_TYPE and an empty buffer, the setters false;
//!   GetCurrentDirName then asks NameFromLock for the current
//!   directory.
//!
//! NameFromLock copies the lock, then walks the copy up with
//! ParentDir-style packets to the root, examining each level and
//! putting its name in from the buffer's end, and puts the volume's
//! name in front ("Ram Disk:d/sub"). It sends its packets itself, so it
//! works from a plain task too. Lock 0 names the root of
//! pr_FileSystemTask; a lock without a volume node takes the root's
//! name from examining it; a failure leaves an empty buffer.
//!
//! Variables: SetVar, GetVar, DeleteVar and FindVar.
//!
//! Local variables and aliases are LocalVars on the process's pr_LocalVars,
//! kept sorted by name and found by name (in any case) and type. The type
//! byte holds LVF_IGNORE too, so a variable with it set matches no lookup
//! and is hidden until the flag is cleared. Each LocalVar is one block - the
//! node, then its name, then its value with a NUL after it - so it is made
//! and freed in one piece.
//!
//! Global variables are LV_VAR only, and are the files ENV:name. Nothing
//! here assigns ENV:: S:Startup-Sequence makes the directory and assigns it,
//! so until that has run a global variable does not resolve. When ENV: is a
//! late assign whose directory isn't there yet, SetVar makes the directory
//! from the assign's path and tries again. GVF_SAVE_VAR writes ENVARC:name
//! as well, and deletes it as well; a failure there is ignored, since the
//! variable itself was set.
//!
//! SetVar is local unless GVF_GLOBAL_ONLY; a size of -1 is the string's
//! length; a null buffer deletes, the global variable when there is no local
//! one (unless GVF_LOCAL_ONLY). GetVar looks locally first, then in ENV:
//! (unless GVF_LOCAL_ONLY); text is cut at a newline and ends in a NUL,
//! binary data is as it is (without the NUL for GVF_DONT_NULL_TERM). It
//! answers the bytes copied, with IoErr the whole length, so a caller can
//! tell a cut value.

const sdk = @import("sdk");
const objects = @import("../packet/_packet.zig");
const locks = @import("../lock/_lock.zig");
const files = @import("../file/_file.zig");
const DosBase = @import("../dos_base.zig").DosBase;
const doslist = @import("../doslist/_doslist.zig");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const TagItem = sdk.utility.TagItem;
const Process = dos.Process;
const PathNode = dos.PathNode;
const CommandLineInterface = dos.CommandLineInterface;
const x = dos.dosextens;
const MsgPort = sdk.exec.MsgPort;
const FileLock = dos.FileLock;
const FileInfoBlock = dos.FileInfoBlock;
const ActionCode = dos.ActionCode;
const asArg = locks.asArg;
const LocalVar = dos.LocalVar;
const MinNode = exec.MinNode;
const MinList = exec.MinList;

/// The calling task as a Process, or null if it is a plain task.
///
/// INPUTS:
/// - `sys` - exec.library's base.
pub fn currentProcess(sys: *ExecBase) ?*Process {
    const task = sys.FindTask(null).?;
    if (task.node.type != .process) return null;
    return @fieldParentPtr("task", task);
}

/// Sets IoErr() to `code` and returns false.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `code` - the error.
pub fn fail(db: *DosBase, code: i32) bool {
    const dos_lib = db.iface();
    _ = dos_lib.SetIoErr(code);
    return false;
}

/// Makes pr_MsgPort ready for packets: it signals the process with
/// SIGB_DOS.
///
/// INPUTS:
/// - `proc` - the
pub fn initMsgPort(proc: *Process) void {
    proc.msg_port = .{ .flags = exec.PA_SIGNAL, .sig_bit = exec.tasks.SIGB_DOS, .sig_task = &proc.task };
    proc.msg_port.msg_list.init(.message);
}

/// Gives a new process what the tags and the parent give it besides its
/// block: the argument copy, the variables, the CLI number and command
/// path, the directories, the streams and the exit hook.
///
/// The steps that can fail come first and undo only what dos made; what
/// the caller hands over is taken only when nothing can fail any more.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `proc` - the new process, not yet running.
/// - `parent` - the calling process, or null for a plain task.
/// - `tags` - CreateNewProc's tags.
///
/// RESULT:
/// True, or false with IoErr() set.
pub fn setUpContext(db: *DosBase, proc: *Process, parent: ?*Process, tags: ?[*]const TagItem) bool {
    const dos_lib = db.iface();
    const ub = db.utility_base;
    if (@as(?[*:0]const u8, @ptrFromInt(ub.GetTagData(dos.NP_Arguments, 0, tags)))) |args| {
        proc.arguments = copyString(db, args) orelse return false;
        proc.own_arguments = proc.arguments;
        proc.flags |= x.PRF_FREEARGS;
    }
    if (parent) |p| {
        if (ub.GetTagData(dos.NP_CopyVars, 1, tags) != 0 and !copyVars(db, p, proc)) return false;
    }
    if (proc.cli) |c| {
        if (!takeCliNumber(db, proc)) return false;
        nameCli(db, proc);
        const from: ?*PathNode = if (ub.FindTagItem(dos.NP_Path, tags)) |t|
            @ptrFromInt(t.data)
        else if (parent) |p| (if (p.cli) |pc| pc.command_dir else null) else null;
        c.command_dir = copyPath(db, from) catch return false;
    }
    const current_dir: ?*dos.FileLock = if (ub.FindTagItem(dos.NP_CurrentDir, tags)) |t|
        @ptrFromInt(t.data)
    else if (parent) |p| (if (p.current_dir) |d| (dos_lib.DupLock(d) orelse return false) else null) else null;
    proc.current_dir = current_dir;
    if (current_dir != null) proc.flags |= x.PRF_FREECURRDIR;
    proc.home_dir = if (ub.FindTagItem(dos.NP_HomeDir, tags)) |t|
        @ptrFromInt(t.data)
    else if (parent) |p| (if (p.home_dir) |d| (dos_lib.DupLock(d) orelse return false) else null) else null;

    proc.cis = @ptrFromInt(ub.GetTagData(dos.NP_Input, 0, tags));
    proc.cos = @ptrFromInt(ub.GetTagData(dos.NP_Output, 0, tags));
    proc.ces = @ptrFromInt(ub.GetTagData(dos.NP_Error, 0, tags));
    if (proc.cis != null and ub.GetTagData(dos.NP_CloseInput, 1, tags) != 0) proc.flags |= x.PRF_CLOSEINPUT;
    if (proc.cos != null and ub.GetTagData(dos.NP_CloseOutput, 1, tags) != 0) proc.flags |= x.PRF_CLOSEOUTPUT;
    if (proc.ces != null and ub.GetTagData(dos.NP_CloseError, 0, tags) != 0) proc.flags |= x.PRF_CLOSEERROR;
    proc.exit_code = @ptrFromInt(ub.GetTagData(dos.NP_ExitCode, 0, tags));
    proc.exit_data = @bitCast(ub.GetTagData(dos.NP_ExitData, 0, tags));
    return true;
}

/// A copy of a string in a block of its own, or null with
/// ERROR_NO_FREE_STORE.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `text` - the string.
fn copyString(db: *DosBase, text: [*:0]const u8) ?[*:0]const u8 {
    const len = db.utility_base.Strlen(text);
    const block = db.sys_base.AllocVec(len + 1, exec.MEMF_ANY) orelse {
        _ = fail(db, dos.ERROR_NO_FREE_STORE);
        return null;
    };
    const copy: [*]u8 = @ptrCast(block);
    @memcpy(copy[0..len], text[0..len]);
    copy[len] = 0;
    return @ptrCast(copy);
}

/// A command path with nodes and locks of its own (DupLock each).
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `from` - the path to copy, or null.
///
/// RESULT:
/// The copy (null for an empty path), or error.Failed with IoErr() set and
/// nothing left over.
fn copyPath(db: *DosBase, from: ?*PathNode) error{Failed}!?*PathNode {
    const dos_lib = db.iface();
    var head: ?*PathNode = null;
    var tail: *?*PathNode = &head;
    var it = from;
    while (it) |n| : (it = n.next) {
        const block = db.sys_base.AllocVec(@sizeOf(PathNode), exec.MEMF_CLEAR) orelse {
            freePath(db, head);
            _ = fail(db, dos.ERROR_NO_FREE_STORE);
            return error.Failed;
        };
        const node: *PathNode = @ptrCast(@alignCast(block));
        node.* = .{ .lock = if (n.lock) |l| dos_lib.DupLock(l) else null };
        tail.* = node;
        tail = &node.next;
        if (n.lock != null and node.lock == null) {
            freePath(db, head);
            return error.Failed;
        }
    }
    return head;
}

/// Frees a command path: each node's lock is unlocked and the node freed.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `path` - the first node, or null.
pub fn freePath(db: *DosBase, path: ?*PathNode) void {
    const dos_lib = db.iface();
    var it = path;
    while (it) |n| {
        it = n.next;
        dos_lib.UnLock(n.lock);
        db.sys_base.FreeVec(n);
    }
}

/// Sets up a new process's CLI in its cleared block: the prompt (the
/// caller's, else CLI_DEFAULT_PROMPT), the command name, the directory
/// name and fail level of the caller's CLI, and the stack size.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `block` - the cleared room for the CLI and its name buffers.
/// - `mine` - the calling process's CLI, or null.
/// - `command_name` - NP_CommandName, or null for the caller's.
/// - `stack` - the process's stack size.
pub fn makeCli(db: *DosBase, block: [*]u8, mine: ?*CommandLineInterface, command_name: ?[*:0]const u8, stack: usize) *CommandLineInterface {
    const c = objects.initCli(block);
    copyName(db, c.prompt.?, if (mine) |m| m.prompt else null, dos.CLI_MAX_PROMPT);
    if (c.prompt.?[0] == 0) copyName(db, c.prompt.?, dos.CLI_DEFAULT_PROMPT, dos.CLI_MAX_PROMPT);
    copyName(db, c.command_name.?, command_name orelse if (mine) |m| m.command_name else null, dos.CLI_MAX_COMMAND_NAME);
    if (mine) |m| {
        copyName(db, c.set_name.?, m.set_name, dos.CLI_MAX_SET_NAME);
        c.fail_level = m.fail_level;
    }
    c.default_stack = @intCast(stack);
    return c;
}

/// A name into one of the CLI's buffers, cut to fit; nothing for null.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `dst` - the buffer.
/// - `src` - the name, or null.
/// - `max` - the buffer's size, the NUL included.
fn copyName(db: *DosBase, dst: [*:0]u8, src: ?[*:0]const u8, max: usize) void {
    const text = src orelse return;
    _ = db.utility_base.Strlcpy(dst, max, text);
}

// --- The end ---

/// exec's finalPC for dos's processes: runs on the process when its code
/// returns, before RemTask, and has endProcess free what it holds.
///
/// INPUTS:
/// - `sys` - exec.library's base.
pub fn processEnd(sys: *ExecBase) callconv(.c) void {
    const proc = currentProcess(sys) orelse return;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return;
    defer sys.CloseLibrary(lib);
    endProcess(@fieldParentPtr("lib", lib), proc);
}

/// Frees what a process holds: its exit hook is called, then its CLI
/// number, variables, streams (as its flags say), directories, command
/// path and argument copy go, and a handler loaded from a file is given
/// back when this was the last process running it.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `proc` - the
pub fn endProcess(db: *DosBase, proc: *Process) void {
    const dos_lib = db.iface();
    if (proc.exit_code) |hook| _ = hook(0, proc.exit_data);
    proc.exit_code = null;
    releaseCliNumber(db, proc);
    freeVars(db, proc);
    if (proc.flags & x.PRF_CLOSEINPUT != 0) _ = dos_lib.Close(proc.cis);
    if (proc.flags & x.PRF_CLOSEOUTPUT != 0) _ = dos_lib.Close(proc.cos);
    if (proc.flags & x.PRF_CLOSEERROR != 0) _ = dos_lib.Close(proc.ces);
    proc.cis = null;
    proc.cos = null;
    proc.ces = null;
    if (proc.flags & x.PRF_FREECURRDIR != 0) dos_lib.UnLock(proc.current_dir);
    proc.current_dir = null;
    dos_lib.UnLock(proc.home_dir);
    proc.home_dir = null;
    if (proc.cli) |c| {
        freePath(db, c.command_dir);
        c.command_dir = null;
    }
    // The copy dos made, not whatever line SetArgStr put in its place.
    if (proc.flags & x.PRF_FREEARGS != 0) {
        if (proc.own_arguments) |args| db.sys_base.FreeVec(@ptrCast(@constCast(args)));
    }
    proc.own_arguments = null;
    proc.arguments = null;
    proc.flags &= ~(x.PRF_CLOSEINPUT | x.PRF_CLOSEOUTPUT | x.PRF_CLOSEERROR | x.PRF_FREECURRDIR | x.PRF_FREEARGS);
    // A handler whose code came from a file: the last of its processes to
    // end gives the code back. Its own code has returned by now.
    if (proc.handler_node) |node| {
        proc.handler_node = null;
        doslist.releaseHandlerCode(db, node);
    }
}

// --- CLI numbers (rn_CliList) ---

/// Puts a CLI's number after its process's name, as " [n]".
///
/// Two shells are otherwise two tasks with the same name, and a list of
/// tasks cannot tell them apart; the name is where everything that lists
/// tasks looks anyway. CreateNewProc left room for it.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `proc` - the process, with its number taken.
fn nameCli(db: *DosBase, proc: *Process) void {
    const name: [*:0]u8 = @constCast(proc.task.node.name orelse return);
    var at = db.utility_base.Strlen(name);
    name[at] = ' ';
    at += 1;
    name[at] = '[';
    at += 1;
    if (proc.task_num >= 10) {
        name[at] = '0' + @as(u8, @intCast(proc.task_num / 10));
        at += 1;
    }
    name[at] = '0' + @as(u8, @intCast(proc.task_num % 10));
    at += 1;
    name[at] = ']';
    at += 1;
    name[at] = 0;
}

/// Gives a process the lowest free CLI number, in pr_TaskNum.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `proc` - the
///
/// RESULT:
/// True, or false with ERROR_TASK_TABLE_FULL.
fn takeCliNumber(db: *DosBase, proc: *Process) bool {
    db.sys_base.ObtainSemaphore(&db.cli_lock);
    defer db.sys_base.ReleaseSemaphore(&db.cli_lock);
    for (&db.clis, 0..) |*slot, i| {
        if (slot.* != null) continue;
        slot.* = proc;
        proc.task_num = @intCast(i + 1);
        return true;
    }
    return fail(db, dos.ERROR_TASK_TABLE_FULL);
}

/// Frees a process's CLI number, if it has one.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `proc` - the
fn releaseCliNumber(db: *DosBase, proc: *Process) void {
    if (proc.task_num == 0 or proc.task_num > db.clis.len) return;
    db.sys_base.ObtainSemaphore(&db.cli_lock);
    defer db.sys_base.ReleaseSemaphore(&db.cli_lock);
    if (db.clis[proc.task_num - 1] == proc) db.clis[proc.task_num - 1] = null;
    proc.task_num = 0;
}

// --- The CLI's names ---

/// Which of the CLI's name buffers a shared getter or setter works on.
pub const Name = enum { set_name, command_name, prompt };

/// How many bytes a name buffer holds, the NUL included.
///
/// INPUTS:
/// - `which` - the buffer.
fn capacity(comptime which: Name) usize {
    return switch (which) {
        .set_name => dos.CLI_MAX_SET_NAME,
        .command_name => dos.CLI_MAX_COMMAND_NAME,
        .prompt => dos.CLI_MAX_PROMPT,
    };
}

/// The answer of a getter without a CLI: an empty buffer, false and
/// ERROR_OBJECT_WRONG_TYPE.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `buffer` - the caller's buffer, emptied when it has room.
/// - `size` - its size in bytes.
pub fn noCli(db: *DosBase, buffer: [*]u8, size: u32) bool {
    if (size > 0) buffer[0] = 0;
    return fail(db, dos.ERROR_OBJECT_WRONG_TYPE);
}

/// Copies `text` into the caller's buffer and ends it with a NUL, cut
/// to fit.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `text` - what to copy.
/// - `buffer` - the caller's buffer.
/// - `size` - its size in bytes, the NUL included.
///
/// RESULT:
/// True when all of `text` fitted; false with ERROR_LINE_TOO_LONG when
/// it was cut or `size` is 0.
pub fn copyOut(db: *DosBase, text: []const u8, buffer: [*]u8, size: u32) bool {
    if (size == 0) return fail(db, dos.ERROR_LINE_TOO_LONG);
    const n = @min(text.len, size - 1);
    if (n != 0) db.sys_base.CopyMem(text.ptr, buffer, n);
    buffer[n] = 0;
    if (n < text.len) return fail(db, dos.ERROR_LINE_TOO_LONG);
    return true;
}

/// The body of GetProgramName and GetPrompt: one of the CLI's names
/// into the caller's buffer.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `which` - the name buffer to read.
/// - `buffer` - the caller's buffer.
/// - `size` - its size in bytes, the NUL included.
///
/// RESULT:
/// As copyOut; without a CLI or without that buffer, noCli's answer.
pub fn getName(db: *DosBase, comptime which: Name, buffer: [*]u8, size: u32) bool {
    const dos_lib = db.iface();
    const c = dos_lib.Cli() orelse return noCli(db, buffer, size);
    const text = @field(c, @tagName(which)) orelse return noCli(db, buffer, size);
    return copyOut(db, text[0..db.utility_base.Strlen(text)], buffer, size);
}

/// The body of SetProgramName, SetPrompt and SetCurrentDirName: `name`
/// into one of the CLI's name buffers, or false and nothing changed.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `which` - the name buffer to write.
/// - `name` - the new text; it may be the buffer itself, since the copy
///   handles an overlap.
///
/// RESULT:
/// True when set; false with ERROR_OBJECT_WRONG_TYPE without a CLI, or
/// ERROR_LINE_TOO_LONG when it doesn't fit.
pub fn setName(db: *DosBase, comptime which: Name, name: [*:0]const u8) bool {
    const dos_lib = db.iface();
    const c = dos_lib.Cli() orelse return fail(db, dos.ERROR_OBJECT_WRONG_TYPE);
    const dst = @field(c, @tagName(which)) orelse return fail(db, dos.ERROR_OBJECT_WRONG_TYPE);
    const len = db.utility_base.Strlen(name);
    if (len >= capacity(which)) return fail(db, dos.ERROR_LINE_TOO_LONG);
    db.sys_base.CopyMem(name, dst, len);
    dst[len] = 0;
    return true;
}

// --- NameFromLock ---

/// A handler's answer to one packet: dp_Res1 and dp_Res2.
const Answer = struct { res1: isize, res2: i32 };

/// Sends one packet and waits for the answer, with dp_Res2 in hand even
/// from a plain task (which has no IoErr).
///
/// INPUTS:
/// - `db` - the library's base.
/// - `port` - the handler's port.
/// - `action` - the packet's action.
/// - `arg1`, `arg2` - dp_Arg1 and dp_Arg2; the rest are 0.
///
/// RESULT:
/// The answer; res1 0 with ERROR_NO_FREE_STORE when the packet couldn't
/// be made.
fn ask(db: *DosBase, port: *MsgPort, action: ActionCode, arg1: isize, arg2: isize) Answer {
    const answer = objects.exchange(db.sys_base, port, @intFromEnum(action), .{ arg1, arg2, 0, 0, 0 }) orelse
        return .{ .res1 = 0, .res2 = dos.ERROR_NO_FREE_STORE };
    return .{ .res1 = answer.res1, .res2 = answer.res2 };
}

/// Frees a lock NameFromLock made on the way, with ACTION_FREE_LOCK to
/// its handler.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `l` - the lock.
fn free(db: *DosBase, l: *FileLock) void {
    _ = ask(db, l.task.?, .free_lock, asArg(l), 0);
}

/// The name NameFromLock builds, from the buffer's end backwards:
/// `out[pos..]` so far, its NUL last.
pub const Path = struct {
    out: []u8,
    pos: usize,

    /// Puts `text` in front of the name so far.
    ///
    /// INPUTS:
    /// - `p` - the name being built.
    /// - `text` - the part to put in front.
    ///
    /// RESULT:
    /// False when it doesn't fit; nothing is then written.
    fn put(p: *Path, text: []const u8) bool {
        if (text.len > p.pos) return false;
        p.pos -= text.len;
        @memcpy(p.out[p.pos..][0..text.len], text);
        return true;
    }
};

/// The name in a FileInfoBlock, as a slice.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `fib` - the block Examine filled.
fn fibName(db: *DosBase, fib: *const FileInfoBlock) []const u8 {
    return fib.file_name[0..db.utility_base.Strlen(@ptrCast(&fib.file_name))];
}

/// The body of NameFromLock: `lock`'s full name into `path`.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `lock` - the object to name; null is the root of
///   pr_FileSystemTask.
/// - `fib` - a FileInfoBlock to examine into.
/// - `path` - the name, built from its buffer's end.
///
/// RESULT:
/// 0, or the error that stopped it. Every lock made on the way is freed
/// either way.
pub fn build(db: *DosBase, lock: ?*FileLock, fib: *FileInfoBlock, path: *Path) i32 {
    const start = lock orelse {
        // Lock 0: the root of the process's file system.
        const port = locks.fileSystemTask(db) orelse return dos.ERROR_DEVICE_NOT_MOUNTED;
        const root = ask(db, port, .examine_object, 0, asArg(fib));
        if (root.res1 == 0) return root.res2;
        if (!path.put(":") or !path.put(fibName(db, fib))) return dos.ERROR_LINE_TOO_LONG;
        return 0;
    };
    const port = start.task orelse return dos.ERROR_INVALID_LOCK;
    // A copy to walk with: examining the caller's lock could upset an
    // ExNext running on it.
    const copy = ask(db, port, .copy_dir, asArg(start), 0);
    if (copy.res1 == 0) return if (copy.res2 != 0) copy.res2 else dos.ERROR_INVALID_LOCK;
    var cur: *FileLock = @ptrFromInt(@as(usize, @bitCast(copy.res1)));
    var first = true;
    while (true) {
        const up = ask(db, port, .parent, asArg(cur), 0);
        if (up.res1 == 0) {
            if (up.res2 == 0) break; // cur is the root
            free(db, cur);
            return up.res2;
        }
        const parent: *FileLock = @ptrFromInt(@as(usize, @bitCast(up.res1)));
        const ex = ask(db, port, .examine_object, asArg(cur), asArg(fib));
        const code: i32 = if (ex.res1 == 0)
            ex.res2
        else if ((!first and !path.put("/")) or !path.put(fibName(db, fib)))
            dos.ERROR_LINE_TOO_LONG
        else
            0;
        free(db, cur);
        cur = parent;
        if (code != 0) {
            free(db, cur);
            return code;
        }
        first = false;
    }
    defer free(db, cur);
    const volume: []const u8 = if (cur.volume) |v| v.name[0..db.utility_base.Strlen(v.name)] else blk: {
        const root = ask(db, port, .examine_object, asArg(cur), asArg(fib));
        if (root.res1 == 0) return root.res2;
        break :blk fibName(db, fib);
    };
    if (!path.put(":") or !path.put(volume)) return dos.ERROR_LINE_TOO_LONG;
    return 0;
}

/// A process's pr_LocalVars, set up first if it never was.
///
/// INPUTS:
/// - `proc` - the
fn list(proc: *Process) *MinList {
    if (proc.local_vars.head == null) proc.local_vars.init();
    return &proc.local_vars;
}

/// The local variable or alias `name` of type `var_type` on a process's
/// list, or null. The name matches in any case; one with LVF_IGNORE set in
/// its type never matches.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `proc` - the process whose variables are searched.
/// - `name` - the variable's name.
/// - `var_type` - LV_VAR or LV_ALIAS.
pub fn findIn(db: *DosBase, proc: *Process, name: [*:0]const u8, var_type: u8) ?*LocalVar {
    var it = list(proc).head;
    while (it) |n| : (it = n.succ) {
        if (n.succ == null) break; // the list's end
        const v: *LocalVar = @ptrCast(n);
        if (v.var_type == var_type and db.utility_base.Stricmp(v.name, name) == 0) return v;
    }
    return null;
}

/// Takes a node off its list.
///
/// INPUTS:
/// - `n` - the node, which is on a list.
fn unlink(n: *MinNode) void {
    n.pred.?.succ = n.succ;
    n.succ.?.pred = n.pred;
}

/// Puts a variable on a process's list, before the first one whose name
/// comes later in any-case order.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `proc` - the
/// - `v` - the variable, on no list.
pub fn insertSorted(db: *DosBase, proc: *Process, v: *LocalVar) void {
    var it = list(proc).head.?;
    while (it.succ) |next| : (it = next) {
        const other: *LocalVar = @ptrCast(it);
        if (db.utility_base.Stricmp(v.name, other.name) < 0) break;
    }
    v.node.succ = it;
    v.node.pred = it.pred;
    it.pred.?.succ = &v.node;
    it.pred = &v.node;
}

/// A LocalVar with its name and value (and a NUL after the value) in one
/// cleared block, on no list. Null when there is no memory.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `name` - the variable's name, copied.
/// - `value` - its value, copied.
/// - `var_type` - LV_VAR or LV_ALIAS.
/// - `flags` - lv_Flags (GVF_BINARY_VAR).
pub fn newVar(db: *DosBase, name: [*:0]const u8, value: []const u8, var_type: u8, flags: u16) ?*LocalVar {
    const name_len = db.utility_base.Strlen(name);
    const block = db.sys_base.AllocVec(@sizeOf(LocalVar) + name_len + 1 + value.len + 1, exec.MEMF_CLEAR) orelse return null;
    const bytes: [*]u8 = @ptrCast(block);
    const name_at = bytes + @sizeOf(LocalVar);
    @memcpy(name_at[0..name_len], name[0..name_len]);
    name_at[name_len] = 0;
    const value_at = name_at + name_len + 1;
    @memcpy(value_at[0..value.len], value);
    value_at[value.len] = 0;
    const v: *LocalVar = @ptrCast(@alignCast(block));
    v.* = .{ .var_type = var_type, .flags = flags, .name = @ptrCast(name_at), .value = value_at, .len = @intCast(value.len) };
    return v;
}

/// Takes a variable off its list and frees it.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `v` - the variable.
pub fn freeVar(db: *DosBase, v: *LocalVar) void {
    unlink(&v.node);
    db.sys_base.FreeVec(v);
}

/// Frees all of a process's local variables, at its end.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `proc` - the
pub fn freeVars(db: *DosBase, proc: *Process) void {
    const l = list(proc);
    while (!l.isEmpty()) freeVar(db, @ptrCast(l.head.?));
}

/// NP_CopyVars: copies one process's local variables onto another's list.
/// False with ERROR_NO_FREE_STORE when there is no memory; what was copied
/// so far stays.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `from` - the process whose variables are copied.
/// - `to` - the new
pub fn copyVars(db: *DosBase, from: *Process, to: *Process) bool {
    var it = list(from).head;
    while (it) |n| : (it = n.succ) {
        if (n.succ == null) break;
        const v: *LocalVar = @ptrCast(n);
        const copy = newVar(db, v.name, v.value[0..v.len], v.var_type, v.flags) orelse return fail(db, dos.ERROR_NO_FREE_STORE);
        insertSorted(db, to, copy);
    }
    return true;
}

/// `prefix` and `name` one after the other in `path`, ended with a NUL;
/// null if they don't fit.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `path` - the buffer.
/// - `prefix` - the directory part, "ENV:" or "ENVARC:".
/// - `name` - the variable's name.
pub fn varPath(db: *DosBase, path: *[256]u8, prefix: []const u8, name: [*:0]const u8) ?[*:0]const u8 {
    const name_len = db.utility_base.Strlen(name);
    if (prefix.len + name_len + 1 > path.len) return null;
    @memcpy(path[0..prefix.len], prefix);
    @memcpy(path[prefix.len..][0..name_len], name[0..name_len]);
    path[prefix.len + name_len] = 0;
    return @ptrCast(path);
}

/// Sets or deletes the global variable ENV:name, and ENVARC:name as well
/// with GVF_SAVE_VAR. False with IoErr on failure.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `name` - the variable's name.
/// - `buffer` - the value, or null to delete the variable.
/// - `len` - the value's length.
/// - `flags` - SetVar's flags; GVF_SAVE_VAR is the one read.
pub fn setGlobal(db: *DosBase, name: [*:0]const u8, buffer: ?[*]const u8, len: usize, flags: u32) bool {
    const dos_lib = db.iface();
    var path: [256]u8 = undefined;
    const env = varPath(db, &path, "ENV:", name) orelse return fail(db, dos.ERROR_LINE_TOO_LONG);
    const data = buffer orelse {
        const gone = dos_lib.DeleteFile(env);
        // The archived copy goes with it, or it would come back.
        if (flags & dos.GVF_SAVE_VAR != 0) {
            if (varPath(db, &path, "ENVARC:", name)) |archive| _ = dos_lib.DeleteFile(archive);
        }
        return gone;
    };
    if (!writeFile(db, env, data, len)) {
        if (!makeEnv(db) or !writeFile(db, env, data, len)) return false;
    }
    if (flags & dos.GVF_SAVE_VAR != 0) {
        if (varPath(db, &path, "ENVARC:", name)) |archive| _ = writeFile(db, archive, data, len);
    }
    return true;
}

/// Writes `len` bytes to a new file at `path`; false if it can't be opened,
/// written in full or closed.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `path` - the file's name.
/// - `data` - the bytes.
/// - `len` - how many.
fn writeFile(db: *DosBase, path: [*:0]const u8, data: [*]const u8, len: usize) bool {
    const dos_lib = db.iface();
    const fh = dos_lib.Open(path, dos.MODE_NEWFILE) orelse return false;
    const wrote = dos_lib.Write(fh, data, @intCast(len)) == @as(isize, @intCast(len));
    return dos_lib.Close(fh) and wrote;
}

/// Makes ENV:'s directory when it isn't there: the path of the ENV assign,
/// if that is a late one. A bound assign already has its directory, and
/// without any assign there is nothing to make, so both are false.
///
/// INPUTS:
/// - `db` - the library's base.
fn makeEnv(db: *DosBase) bool {
    const dos_lib = db.iface();
    var target: [256]u8 = undefined;
    const read = dos.LDF_ASSIGNS | dos.LDF_READ;
    const start = dos_lib.LockDosList(read).?;
    const node = dos_lib.FindDosEntry(start, "ENV", dos.LDF_ASSIGNS);
    const path: ?[*:0]const u8 = if (node) |n| (if (n.type == .late) n.misc.assign.assign_name else null) else null;
    const len = if (path) |p| db.utility_base.Strlen(p) else 0;
    const fits = path != null and len < target.len;
    if (fits) {
        @memcpy(target[0..len], path.?[0..len]);
        target[len] = 0;
    }
    dos_lib.UnLockDosList(read);
    if (!fits) return false;
    const dir = dos_lib.CreateDir(@ptrCast(&target)) orelse return false;
    dos_lib.UnLock(dir);
    return true;
}

/// A value into GetVar's buffer: text cut at a newline, `room` respected, a
/// NUL after it when `null_term`. IoErr is set to `whole`; the result is
/// the bytes copied.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `value` - the value; it may be `buffer` itself.
/// - `whole` - the value's full length, for IoErr.
/// - `buffer` - the caller's buffer.
/// - `room` - its size, at least 1.
/// - `binary` - the value is copied as it is, newlines included.
/// - `null_term` - a NUL goes after it, and takes one byte of `room`.
pub fn deliver(db: *DosBase, value: []const u8, whole: usize, buffer: [*]u8, room: usize, binary: bool, null_term: bool) isize {
    const dos_lib = db.iface();
    var n = value.len;
    if (!binary) {
        for (value, 0..) |c, at| {
            if (c == '\n' or c == '\r') {
                n = at;
                break;
            }
        }
    }
    n = @min(n, if (null_term) room - 1 else room);
    if (n != 0) db.sys_base.CopyMem(value.ptr, buffer, n);
    if (null_term) buffer[n] = 0;
    _ = dos_lib.SetIoErr(@intCast(whole));
    return @intCast(n);
}
