// SPDX-License-Identifier: MPL-2.0
//! Code: segments dos keeps by name, programs loaded from files, and
//! running a command or a shell.
//!
//! Resident segments: named code that dos keeps - AddSegment,
//! FindSegment, RemSegment, and LockSegmentList and UnLockSegmentList
//! around a walk of the list.
//!
//! A segment holds its code as a SegCode (a process entry, a command's
//! function) and a name, a C string compared without regard to case.
//! seg_UC tells kinds apart: below 0 is system code (CMD_SYSTEM, a
//! handler's entry), internal and disabled commands; 0 and up is a user
//! command, and then the number is its use count - raised by whoever
//! runs it, under the list's lock, and lowered when done. RemSegment
//! only takes a user segment whose count is 0, so a command that is
//! running cannot be freed under it.
//!
//! A semaphore in the base guards the list, rather than Forbid:
//! FindSegment is called with it held (shared is enough), and a caller
//! that keeps a segment raises seg_UC before letting go. AddSegment and
//! RemSegment take it exclusive themselves, so they must not be called
//! with it held. dos's init adds the ROM's handlers and the shell as
//! system segments, and a device's handler is found here by name when
//! it is first started.
//!
//! LoadSeg and UnLoadSeg: code from a file, ready to run.
//!
//! The file is a load file (`sdk/libs/dos/loadfile.zig`, made from a linked
//! program by `sdk/tools/elf2seg`): a header, then each segment's header,
//! bytes and padding, then every segment's relocation groups. The result is
//! a chain of `SegList`s, one per segment, sizes in bytes and the chain a
//! plain pointer; the first one also carries the entry point.
//!
//! Per segment: one block of memory the CPU can also run code from
//! (MEMF_EXTERNAL: PSRAM, which one MMU table shows on both buses), the
//! bytes copied in, the rest cleared, then the relocations applied - the
//! 32-bit word at each offset gets the target segment's base added. A code
//! segment's base is its address on the instruction bus (exec's
//! CodeAddress), a data or bss segment's its ordinary address, so a function
//! pointer ends up executable and a data pointer readable.
//!
//! The relocations of a segment may point at a later one, so they are
//! applied in a second pass, once every segment has its address. After that,
//! CacheClearU: the bytes went through the data cache, and the instruction
//! cache must not serve what was there before. Each segment is one block, so
//! UnLoadSeg frees the chain one block at a time and needs nothing else.
//!
//! RunCommand: a command's code run on the calling process, on a stack
//! of its own (exec's NewStackRun), with its argument line as Input()'s
//! read-ahead - so ReadArgs reads it first - and as pr_Arguments
//! (GetArgStr).
//!
//! The code is a SegCode's command: it gets SysBase, the arguments and
//! their length, and returns the return code. The stack comes from
//! NewStackRun because a stack can't be swapped under compiled code on
//! a machine with register windows. The arguments are always copied, so
//! the caller's line may go as soon as the call returns and the command
//! may keep pr_Arguments for its whole run. Afterwards Input()'s buffer
//! and pr_Arguments are what they were before; what the command left
//! unread of its line goes.
//!
//! Shells started from dos: SystemTagList and Execute, both through
//! `startShell`.
//!
//! dos finds the shell's code among the resident segments ("BootShell";
//! "shell" with SYS_UserShell; another with SYS_CustomShell), makes a CLI
//! process with CreateNewProc, sets its CLI up, and sends it ACTION_STARTUP
//! with a ShellMode and SHF_* flags. Setting the CLI up here, before the
//! shell runs, keeps the shell's own start to one packet that says only the
//! mode and the flags.
//!
//! The CLI: cli_StandardInput and cli_StandardOutput are the given streams
//! (SYS_Input, SYS_Output; by default Input() and Output()), which are the
//! process's Input() and Output() too. cli_CurrentInput, what the shell
//! reads its commands from, is the command line as a stream without a
//! handler (`stringHandle`), or for an interactive shell a script
//! (SYS_ScriptFile) and then the standard input. The new CLI takes its
//! prompt, directory name, fail level, path and default stack from the
//! caller's CLI, and its current directory is a copy of the caller's.
//!
//! A missing input or output is NIL:, which the shell closes. An interactive
//! shell on a console that another foreground shell reads is refused with
//! ERROR_OBJECT_IN_USE: two shells would share the terminal's lines. A
//! synchronous start waits for the shell to end and answers its last return
//! code (IoErr its Result2), or -1 when it can't start; SYS_Asynch answers
//! at once, with the new CLI's number, and the shell closes the streams. The
//! caller's tags go on to CreateNewProc, except the ones dos sets
//! (`not_allowed`); NP_CurrentDir, NP_Name and NP_Priority are honoured.

const sdk = @import("sdk");
const process = @import("../process/_process.zig");
const DosBase = @import("../dos_base.zig").DosBase;
const objects = @import("../packet/_packet.zig");
const dos = sdk.dos;
const exec = sdk.exec;
const loadfile = dos.loadfile;
const SegList = dos.SegList;
const ExecBase = sdk.interface.exec.ExecBase;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const FileHandle = dos.FileHandle;

/// Makes the list empty and its semaphore ready, for dos's init.
///
/// INPUTS:
/// - `db` - the library's base.
pub fn initSegments(db: *DosBase) void {
    db.segments = null;
    db.sys_base.InitSemaphore(&db.seg_lock);
}

/// The most segments a file may have: the loader keeps a note per segment
/// on its stack.
pub const max_segments = 16;
/// A segment bigger than this is refused: a wrong file would otherwise take
/// memory before it failed.
const max_segment = 4 << 20;

/// Sets IoErr to `code` and answers null, the way LoadSeg fails.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `code` - the error code (ERROR_*).
pub fn fail(db: *DosBase, code: i32) ?*SegList {
    const dos_lib = db.iface();
    _ = dos_lib.SetIoErr(code);
    return null;
}

/// Sets IoErr to `code` and answers false.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `code` - the error code (ERROR_*).
fn failBool(db: *DosBase, code: i32) bool {
    const dos_lib = db.iface();
    _ = dos_lib.SetIoErr(code);
    return false;
}

/// Fills `buf` from the file; false when the file ends first.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `fh` - the load file.
/// - `buf` - what to fill.
fn readAll(db: *DosBase, fh: *dos.FileHandle, buf: []u8) bool {
    const dos_lib = db.iface();
    return dos_lib.Read(fh, buf.ptr, @intCast(buf.len)) == @as(isize, @intCast(buf.len));
}

/// The next `@sizeOf(T)` bytes of the file as a `T`, or null when the file
/// ends first.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `fh` - the load file.
/// - `T` - the type to read.
pub fn readValue(db: *DosBase, fh: *dos.FileHandle, comptime T: type) ?T {
    var value: T = undefined;
    if (!readAll(db, fh, @as([*]u8, @ptrCast(&value))[0..@sizeOf(T)])) return null;
    return value;
}

/// What the loader keeps about a segment while it reads the file.
pub const Loaded = struct {
    /// The base its relocations add: the instruction address for code. It
    /// is a usize because the host tests run on a 64-bit machine; only the
    /// low 32 bits reach the word being patched.
    base: usize = 0,
    /// Relocation groups still to read for it.
    groups: u32 = 0,
};

/// Reads one segment: its header, a block for it, its bytes, the rest
/// cleared. Its relocation groups stay in the file for `relocate`. Null
/// with ERROR_BAD_HUNK for a header that makes no sense or a file that ends
/// early, ERROR_NO_FREE_STORE when there is no memory.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `fh` - the load file, at the segment's header.
/// - `note` - where the segment's base and relocation count go.
pub fn readSegment(db: *DosBase, fh: *dos.FileHandle, note: *Loaded) ?*SegList {
    const sys = db.sys_base;
    const head = readValue(db, fh, loadfile.SegmentHeader) orelse return fail(db, dos.ERROR_BAD_HUNK);
    if (head.file_size > head.mem_size or head.mem_size > max_segment or head.mem_size == 0)
        return fail(db, dos.ERROR_BAD_HUNK);
    if (head.kind == .bss and head.file_size != 0) return fail(db, dos.ERROR_BAD_HUNK);

    const block_size: u32 = @sizeOf(SegList) + loadfile.alignUp(head.mem_size);
    const block = sys.AllocMem(block_size, exec.MEMF_EXTERNAL | exec.MEMF_CLEAR) orelse
        return fail(db, dos.ERROR_NO_FREE_STORE);
    const bytes: [*]u8 = @ptrFromInt(@intFromPtr(block) + @sizeOf(SegList));
    const seg: *SegList = @ptrCast(@alignCast(block));
    seg.* = .{
        .block_size = block_size,
        .mem_size = head.mem_size,
        .kind = head.kind,
        .data = bytes,
    };
    note.groups = head.reloc_groups;
    note.base = @intFromPtr(bytes);
    if (head.kind == .code) {
        // Where it runs: the same bytes on the instruction bus.
        const run = sys.CodeAddress(bytes, head.mem_size) orelse {
            sys.FreeMem(block, block_size);
            return fail(db, dos.ERROR_NO_FREE_STORE);
        };
        seg.run_address = @ptrCast(run);
        note.base = @intFromPtr(run);
    }
    if (head.file_size != 0 and !readAll(db, fh, bytes[0..head.file_size])) {
        sys.FreeMem(block, block_size);
        return fail(db, dos.ERROR_BAD_HUNK);
    }
    const pad = loadfile.alignUp(head.file_size) - head.file_size;
    var skip: [loadfile.ALIGN]u8 = undefined;
    if (pad != 0 and !readAll(db, fh, skip[0..pad])) {
        sys.FreeMem(block, block_size);
        return fail(db, dos.ERROR_BAD_HUNK);
    }
    return seg;
}

/// Applies every segment's relocation groups, in the order the file has
/// them: the word at each offset gets the target segment's base added.
/// False with ERROR_BAD_HUNK for a group that names no segment, an offset
/// outside its segment, or a file that ends early.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `fh` - the load file, after the last segment's bytes.
/// - `first` - the chain of segments, in the file's order.
/// - `loaded` - each segment's base and relocation count.
///
pub fn relocate(db: *DosBase, fh: *dos.FileHandle, first: ?*SegList, loaded: *const [max_segments]Loaded) bool {
    var seg = first;
    var index: usize = 0;
    while (seg) |s| : ({
        seg = s.next;
        index += 1;
    }) {
        var g: u32 = 0;
        while (g < loaded[index].groups) : (g += 1) {
            const group = readValue(db, fh, loadfile.RelocGroup) orelse return failBool(db, dos.ERROR_BAD_HUNK);
            if (group.target_segment >= max_segments) return failBool(db, dos.ERROR_BAD_HUNK);
            const base = loaded[group.target_segment].base;
            if (base == 0) return failBool(db, dos.ERROR_BAD_HUNK); // no such segment
            var n: u32 = 0;
            while (n < group.count) : (n += 1) {
                const offset = readValue(db, fh, u32) orelse return failBool(db, dos.ERROR_BAD_HUNK);
                // A word must fit whole; a segment under 4 bytes has room for none.
                if (s.mem_size < 4 or offset > s.mem_size - 4) return failBool(db, dos.ERROR_BAD_HUNK);
                const word: *align(1) u32 = @ptrCast(s.data.? + offset);
                word.* +%= @truncate(base);
            }
        }
    }
    return true;
}

/// What NewStackRun hands callCommand: the command and what it is
/// called with.
pub const Call = struct {
    sys: *ExecBase,
    command: dos.CommandFn,
    args: [*]const u8,
    len: usize,
    /// Set once the command is called: NewStackRun's -1 without it is a
    /// stack that couldn't be had, with it the command's own answer.
    started: bool = false,
};

/// NewStackRun's code: calls the command, on its own stack.
///
/// INPUTS:
/// - `arg` - the Call.
///
/// RESULT:
/// The command's return code.
pub fn callCommand(arg: ?*anyopaque) callconv(.c) i32 {
    const call: *Call = @ptrCast(@alignCast(arg.?));
    call.started = true;
    return call.command(call.sys, call.args, call.len);
}

/// Sets IoErr to `code` and answers -1, RunCommand's answer when the
/// command can't run.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `code` - the error for IoErr.
pub fn failRun(db: *DosBase, code: i32) i32 {
    const dos_lib = db.iface();
    _ = dos_lib.SetIoErr(code);
    return -1;
}

/// The tags a caller's list doesn't pass on to CreateNewProc: dos sets them
/// itself.
const not_allowed = [_]utility.Tag{
    dos.NP_Seglist,     dos.NP_FreeSeglist, dos.NP_Entry,
    dos.NP_Input,       dos.NP_Output,      dos.NP_CloseInput,
    dos.NP_CloseOutput, dos.NP_Cli,         utility.TAG_DONE,
};

/// Sets IoErr to `code` and answers -1, the way a start fails.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `code` - the error code (ERROR_*).
fn failWith(db: *DosBase, code: i32) i32 {
    const dos_lib = db.iface();
    _ = dos_lib.SetIoErr(code);
    return -1;
}

/// A command line as a stream without a handler: its bytes and a newline
/// are the handle's read-ahead, then it ends. Close frees the handle and
/// its buffer. Null with IoErr when there is no memory.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `text` - the command line, copied.
fn stringHandle(db: *DosBase, text: [*:0]const u8) ?*FileHandle {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    const len = db.utility_base.Strlen(text);
    const fh: *FileHandle = @ptrCast(@alignCast(dos_lib.AllocDosObject(dos.DOS_FILEHANDLE, null) orelse return null));
    const block = sys.AllocVec(len + 1, exec.MEMF_ANY) orelse {
        dos_lib.FreeDosObject(dos.DOS_FILEHANDLE, fh);
        _ = failWith(db, dos.ERROR_NO_FREE_STORE);
        return null;
    };
    const bytes: [*]u8 = @ptrCast(block);
    @memcpy(bytes[0..len], text[0..len]);
    bytes[len] = '\n';
    fh.buf = bytes;
    fh.buf_size = @intCast(len + 1);
    fh.end = fh.buf_size;
    fh.state = .read;
    fh.buf_owned = true;
    return fh;
}

/// Whether a foreground shell (a CLI that isn't a background one) reads its
/// commands from the console at `port`.
///
/// INPUTS:
/// - `db` - the library's base; its CLI list is read under cli_lock.
/// - `port` - the console's handler, or null for none.
fn consoleBusy(db: *DosBase, port: ?*exec.MsgPort) bool {
    const console = port orelse return false;
    db.sys_base.ObtainSemaphoreShared(&db.cli_lock);
    defer db.sys_base.ReleaseSemaphore(&db.cli_lock);
    for (db.clis) |slot| {
        const cli = (slot orelse continue).cli orelse continue;
        if (cli.background) continue;
        const in = cli.standard_input orelse continue;
        if (in.interactive and in.task == console) return true;
    }
    return false;
}

/// Undoes a start that failed: the command's stream closes, and so do the
/// streams dos opened or was to close for a synchronous start; IoErr stays
/// as it was. Answers -1.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `input` - the shell's input.
/// - `output` - the shell's output.
/// - `flags` - the SHF_* flags, which say which streams are dos's to close.
/// - `command_fh` - the command line's stream, or null.
fn giveUp(db: *DosBase, input: ?*FileHandle, output: ?*FileHandle, flags: isize, command_fh: ?*FileHandle) i32 {
    const dos_lib = db.iface();
    const err = dos_lib.IoErr();
    if (command_fh) |fh| _ = dos_lib.Close(fh);
    if (flags & dos.SHF_CLOSE_INPUT != 0 and flags & dos.SHF_ASYNCH == 0) _ = dos_lib.Close(input);
    if (flags & dos.SHF_CLOSE_OUTPUT != 0 and flags & dos.SHF_ASYNCH == 0) _ = dos_lib.Close(output);
    _ = dos_lib.SetIoErr(err);
    return -1;
}

/// Starts the shell `shell_name` as a CLI process in `mode`, reading
/// `command` first when there is one. Answers the shell's return code, the
/// CLI's number with SHF_ASYNCH, or -1 with IoErr.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `command` - the command line, or null for an interactive shell.
/// - `shell_name` - the resident segment the shell's code is.
/// - `mode` - system, interactive or execute.
/// - `given_input` - the shell's input; null is NIL:.
/// - `given_output` - the shell's output; null is NIL:.
/// - `given_flags` - SHF_* flags for the startup packet.
/// - `tags` - the caller's tags for CreateNewProc, or null.
///
pub fn startShell(db: *DosBase, command: ?[*:0]const u8, shell_name: [*:0]const u8, mode: dos.ShellMode, given_input: ?*FileHandle, given_output: ?*FileHandle, given_flags: isize, tags: ?[*]const TagItem) i32 {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    const ub = db.utility_base;
    var code: dos.SegCode = undefined;
    {
        _ = dos_lib.LockSegmentList(true);
        defer dos_lib.UnLockSegmentList();
        const seg = dos_lib.FindSegment(shell_name, null, true) orelse return failWith(db, dos.ERROR_OBJECT_NOT_FOUND);
        code = seg.code;
    }
    if (code.entry == null) return failWith(db, dos.ERROR_OBJECT_WRONG_TYPE);

    // Without a stream, NIL:, which the shell closes.
    var flags = given_flags;
    var input = given_input;
    var output = given_output;
    if (input == null) {
        input = dos_lib.Open("NIL:", dos.MODE_OLDFILE);
        if (input != null) flags |= dos.SHF_CLOSE_INPUT;
    }
    if (output == null) {
        output = dos_lib.Open("NIL:", dos.MODE_NEWFILE);
        if (output != null) flags |= dos.SHF_CLOSE_OUTPUT;
    }

    // One shell per console: another one there would share the terminal's
    // lines with it.
    if (mode == .interactive) if (input) |fh| if (fh.interactive and consoleBusy(db, fh.task)) {
        _ = dos_lib.SetIoErr(dos.ERROR_OBJECT_IN_USE);
        return giveUp(db, input, output, flags, null);
    };
    const command_fh: ?*FileHandle = if (command) |c| (stringHandle(db, c) orelse return giveUp(db, input, output, flags, null)) else null;
    // A script the shell reads before its own input, and closes at its end
    // (NewShell's FROM, or S:Shell-startup). A command is already the
    // shell's first input, so the two never meet.
    const script: ?*FileHandle = if (command == null) @ptrFromInt(ub.GetTagData(dos.SYS_ScriptFile, 0, tags)) else null;
    const passed: ?[*]TagItem = if (tags != null) (ub.CloneTagItems(tags) orelse {
        if (script) |fh| _ = dos_lib.Close(fh);
        _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return giveUp(db, input, output, flags, command_fh);
    }) else null;
    defer if (passed) |p| ub.FreeTagItems(p);
    if (passed) |p| _ = ub.FilterTagItems(p, &not_allowed, utility.TAGFILTER_NOT);
    const theirs: ?[*]const TagItem = passed;

    const name: [*:0]const u8 = if (command == null) "Shell Process" else "Background CLI";
    const console: ?*exec.MsgPort = if (input) |fh| (if (fh.interactive) fh.task else null) else null;
    var own = [_]TagItem{
        .{ .tag = dos.NP_Seglist, .data = @intFromPtr(&code) },
        .{ .tag = dos.NP_Cli, .data = 1 },
        .{ .tag = dos.NP_Input, .data = @intFromPtr(input) },
        .{ .tag = dos.NP_Output, .data = @intFromPtr(output) },
        .{ .tag = dos.NP_CloseInput, .data = 0 },
        .{ .tag = dos.NP_CloseOutput, .data = 0 },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(name) },
        .{ .tag = dos.NP_Priority, .data = 0 }, // Execute's
        .{ .tag = dos.NP_ConsoleTask, .data = @intFromPtr(console) }, // "*" in the shell
        .{ .tag = if (theirs != null) utility.TAG_MORE else utility.TAG_DONE, .data = @intFromPtr(theirs) },
    };
    if (ub.FindTagItem(dos.NP_Name, theirs) != null) own[6].tag = utility.TAG_IGNORE;
    if (mode != .execute or ub.FindTagItem(dos.NP_Priority, theirs) != null) own[7].tag = utility.TAG_IGNORE;
    if (console == null or ub.FindTagItem(dos.NP_ConsoleTask, theirs) != null) own[8].tag = utility.TAG_IGNORE;

    const caller = process.currentProcess(sys);
    const caller_cli = if (caller) |p| p.cli else null;
    // The reply port first: once the process is made, the startup must go.
    const reply_port = if (caller) |p| &p.msg_port else sys.CreateMsgPort() orelse {
        if (script) |fh| _ = dos_lib.Close(fh);
        _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return giveUp(db, input, output, flags, command_fh);
    };
    defer if (caller == null) sys.DeleteMsgPort(reply_port);
    const proc = dos_lib.CreateNewProc(&own) orelse {
        if (script) |fh| _ = dos_lib.Close(fh);
        return giveUp(db, input, output, flags, command_fh);
    };
    const cli = proc.cli.?;
    cli.standard_input = input;
    cli.current_input = command_fh orelse script orelse input;
    cli.standard_output = output;
    cli.current_output = output;
    cli.background = command != null;
    if (caller_cli) |c| cli.default_stack = c.default_stack;
    const number = proc.task_num;

    const answer = objects.exchangeVia(sys, caller, reply_port, &proc.msg_port, @intFromEnum(dos.ActionCode.startup), .{ @intFromEnum(mode), flags, 0, 0, 0 });
    if (flags & dos.SHF_ASYNCH != 0) return @intCast(number);
    _ = dos_lib.SetIoErr(answer.res2);
    return @intCast(answer.res1);
}
