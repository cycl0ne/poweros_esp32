// SPDX-License-Identifier: MIT
//! Packets and processes (dos/dosextens.h).
//!
//! The exec Message is the packet's first field, so there is no dp_Link
//! and no ln_Name pointing back (a StandardPacket is simply the packet),
//! and the arguments have typed views (PacketArgs). STARTUP is action 1,
//! apart from NIL.
//!
//! The Process has the classic fields in their order, without the BCPL
//! ones (pr_Pad, pr_GlobVec, pr_ReturnAddr). Fields are pointer-sized, no BPTRs;
//! the CLI is opaque until its type exists.

const ports = @import("../exec/ports.zig");
const tasks = @import("../exec/tasks.zig");
const lists = @import("../exec/lists.zig");
const loadfile = @import("loadfile.zig");
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const DateStamp = @import("dos.zig").DateStamp;
const FileInfoBlock = @import("dos.zig").FileInfoBlock;
const InfoData = @import("dos.zig").InfoData;
const ExAllControl = @import("exall.zig").ExAllControl;
const Resident = @import("../exec/resident.zig").Resident;

const Message = ports.Message;
const MsgPort = ports.MsgPort;
const Task = tasks.Task;
const TaskFn = tasks.TaskFn;
const MinList = lists.MinList;

/// dp_Type: what a handler is asked to do (ACTION_*).
pub const ActionCode = enum(i32) {
    nil = 0,
    startup = 1,
    get_block = 2,
    set_map = 4,
    die = 5,
    event = 6,
    current_volume = 7,
    locate_object = 8,
    rename_disk = 9,
    free_lock = 15,
    delete_object = 16,
    rename_object = 17,
    more_cache = 18,
    copy_dir = 19,
    wait_char = 20,
    set_protect = 21,
    create_dir = 22,
    examine_object = 23,
    examine_next = 24,
    disk_info = 25,
    info = 26,
    flush = 27,
    set_comment = 28,
    parent = 29,
    timer = 30,
    inhibit = 31,
    disk_type = 32,
    disk_change = 33,
    set_date = 34,
    same_lock = 40,
    read = 'R',
    write = 'W',
    screen_mode = 994,
    change_signal = 995,
    read_return = 1001,
    write_return = 1002,
    findupdate = 1004,
    findinput = 1005,
    findoutput = 1006,
    end = 1007,
    seek = 1008,
    format = 1020,
    make_link = 1021,
    set_file_size = 1022,
    write_protect = 1023,
    read_link = 1024,
    fh_from_lock = 1026,
    is_filesystem = 1027,
    change_mode = 1028,
    copy_dir_fh = 1030,
    parent_fh = 1031,
    examine_all = 1033,
    examine_fh = 1034,
    examine_all_end = 1035,
    set_owner = 1036,
    /// Text a console is to read as though it had been typed into it, put
    /// in front of whatever is already waiting and started at once
    /// (dp_Arg2 the characters, dp_Arg3 how many; the answer is how many
    /// were taken, or -1).
    force = 2001,
    /// The same, in front of what is waiting, without starting it.
    stack = 2002,
    /// The same, behind what is waiting.
    queue = 2003,
    /// Whatever was handed in that way and not yet read is thrown away.
    drop = 2004,
    lock_record = 2008,
    free_record = 2009,
    add_notify = 4097,
    remove_notify = 4098,
    serialize_disk = 4200,
    _,
};

/// ACTION_WAIT_CHAR's arguments.
pub const WaitArgs = extern struct {
    /// Microseconds to wait for a character.
    timeout: isize,
};

/// ACTION_INHIBIT's arguments.
pub const InhibitArgs = extern struct {
    /// DOSTRUE to inhibit, DOSFALSE to allow again.
    on_off: isize,
};

/// ACTION_MORE_CACHE's arguments.
pub const CacheArgs = extern struct {
    /// Buffers to add (or remove, if negative).
    number: isize,
};

/// ACTION_SCREEN_MODE's arguments.
pub const ScreenModeArgs = extern struct {
    /// 1: raw, 0: cooked.
    mode: isize,
};

/// FINDINPUT, FINDOUTPUT, FINDUPDATE's arguments: the handler sets the
/// handle's `key` (and `interactive`).
pub const FindArgs = extern struct {
    fh: ?*FileHandle,
    /// The directory the name is from (null: the root).
    lock: ?*FileLock,
    name: ?[*:0]const u8,
};

/// READ and WRITE's arguments.
pub const IOArgs = extern struct {
    fh: ?*FileHandle,
    buffer: ?[*]u8,
    length: isize,
};

/// SEEK's arguments; it answers the old position, or -1.
pub const SeekArgs = extern struct {
    fh: ?*FileHandle,
    position: isize,
    /// OFFSET_BEGINNING, OFFSET_CURRENT or OFFSET_END.
    mode: isize,
};

/// EXAMINE_OBJECT and EXAMINE_NEXT's arguments.
pub const ExamineArgs = extern struct {
    lock: ?*FileLock,
    fib: ?*FileInfoBlock,
};

/// EXAMINE_FH's arguments.
pub const ExamineFHArgs = extern struct {
    fh: ?*FileHandle,
    fib: ?*FileInfoBlock,
};

/// EXAMINE_ALL and EXAMINE_ALL_END's arguments.
pub const ExAllArgs = extern struct {
    lock: ?*FileLock,
    buffer: ?[*]u8,
    size: isize,
    /// ED_*
    data_type: isize,
    control: ?*ExAllControl,
};

/// RENAME_OBJECT's arguments: from (a directory's lock, a name) to another.
pub const RenameArgs = extern struct {
    from_lock: ?*FileLock,
    from_name: ?[*:0]const u8,
    to_lock: ?*FileLock,
    to_name: ?[*:0]const u8,
};

/// SET_PROTECT, SET_COMMENT, SET_DATE and SET_OWNER's arguments, the lock
/// first. The value is the bits, the comment
/// (a C string), the DateStamp's address, or user << 16 | group.
pub const PropertyArgs = extern struct {
    lock: ?*FileLock,
    name: ?[*:0]const u8,
    value: isize,
};

/// CHANGE_MODE's arguments: CHANGE_LOCK with a lock, CHANGE_FH with a
/// handle.
pub const ChangeModeArgs = extern struct {
    kind: isize,
    object: ?*anyopaque,
    mode: isize,
};

/// INFO's arguments (DISK_INFO has only the InfoData, first).
pub const InfoArgs = extern struct {
    lock: ?*FileLock,
    info: ?*InfoData,
};

/// FH_FROM_LOCK's arguments: the handle to open, the lock it takes over.
pub const FhFromLockArgs = extern struct {
    fh: ?*FileHandle,
    lock: ?*FileLock,
};

/// END's arguments; PARENT_FH and COPY_DIR_FH's too.
pub const FileHandleArgs = extern struct {
    fh: ?*FileHandle,
};

/// dp_Arg1..dp_Arg7, raw or as an action's layout. Every packet about an
/// open file carries its FileHandle.
pub const PacketArgs = extern union {
    raw: [7]isize,
    wait: WaitArgs,
    inhibit: InhibitArgs,
    cache: CacheArgs,
    screen_mode: ScreenModeArgs,
    find: FindArgs,
    io: IOArgs,
    seek: SeekArgs,
    examine: ExamineArgs,
    examine_fh: ExamineFHArgs,
    examine_all: ExAllArgs,
    file: FileHandleArgs,
    rename: RenameArgs,
    property: PropertyArgs,
    change_mode: ChangeModeArgs,
    info: InfoArgs,
    fh_from_lock: FhFromLockArgs,
};

/// What a FileHandle's buffer holds.
pub const BufferState = enum(u8) {
    /// Nothing: the handler's position is the file's.
    empty,
    /// Bytes read ahead (pos to end still to give), or pushed-back
    /// characters.
    read,
    /// Bytes waiting to be written (0 to pos).
    write,
};

/// struct FileHandle: the handler's part, then dos's buffer. Every packet
/// about the open file carries the handle. Handlers don't touch the
/// buffer; AllocDosObject(DOS_FILEHANDLE) gives these defaults.
pub const FileHandle = extern struct {
    /// fh_Type: the handler's port, where the file's packets go.
    task: ?*MsgPort = null,
    /// fh_Port: an interactive handle (a console); the handler sets it on
    /// open.
    interactive: bool = false,
    /// The handler's own reference for the open file (fh_Arg1), set on FINDINPUT, FINDOUTPUT or FINDUPDATE.
    key: ?*anyopaque = null,

    /// fh_Buf: the buffer, null until the first buffered call.
    buf: ?[*]u8 = null,
    /// fh_BufSize: its size (stdio.BUFFER_SIZE, or SetVBuf's).
    buf_size: u32 = 0,
    /// fh_Pos: the next byte to give (reading), or how many bytes wait
    /// (writing).
    pos: u32 = 0,
    /// fh_End: how many bytes the last read brought (reading).
    end: u32 = 0,
    state: BufferState = .empty,
    /// stdio.BUF_LINE, BUF_FULL or BUF_NONE (SetVBuf).
    buf_mode: u8 = 0,
    /// Whether dos allocated the buffer (Close frees it), or SetVBuf's
    /// caller gave it.
    buf_owned: bool = false,
    /// How many characters UnGetC pushed back onto `unget`.
    unget_count: u8 = 0,
    /// Which of them stand for a byte the file gave (bit n for `unget[n]`):
    /// only those are seeked back over when the buffer is given back.
    unget_backed: u8 = 0,
    /// RunCommand lent the buffer (the argument line): past it, a refill
    /// takes a buffer of the handle's own.
    lent: bool = false,
    /// UnGetC's characters, the last one on top; -1 is the end.
    unget: [4]i16 = @splat(0),
    /// The last character given (-1: the end), for UnGetC(-1); NO_CHAR
    /// when there is none to push back.
    last: i16 = NO_CHAR,

    pub const NO_CHAR: i16 = -2;
};

/// struct DosPacket, with its Message in front: the packet travels as that
/// message (a StandardPacket, without dp_Link).
pub const DosPacket = extern struct {
    /// The exec message the packet travels in.
    msg: Message = .{},
    /// dp_Port: where the packet goes back to. SendPkt and DoPkt set it to
    /// the reply port; ReplyPkt sets it to the replier's port, so a second
    /// ReplyPkt returns the packet there.
    port: ?*MsgPort = null,
    /// dp_Type (dp_Action): an ActionCode.
    action: i32 = 0,
    /// dp_Res1: the result, as the function's return value (DOSFALSE on
    /// failure, mostly).
    res1: isize = 0,
    /// dp_Res2: the secondary result, what IoErr() would return.
    res2: i32 = 0,
    /// dp_Arg1..dp_Arg7.
    args: PacketArgs = .{ .raw = @splat(0) },

    /// A packet for `action`, its message's length set.
    pub fn init(action: ActionCode, args: PacketArgs) DosPacket {
        return .{ .msg = .{ .length = @sizeOf(DosPacket) }, .action = @intFromEnum(action), .args = args };
    }

    /// The packet a message is.
    pub fn fromMessage(msg: *Message) *DosPacket {
        return @fieldParentPtr("msg", msg);
    }

    pub fn getAction(pkt: *const DosPacket) ActionCode {
        return @enumFromInt(pkt.action);
    }
};

/// pr_PktWait: waits for the next message at the process's msg_port and
/// takes it off the port, instead of WaitPkt's GetMsg/Wait loop.
pub const PktWaitFn = *const fn (proc: *Process, sys_base: *ExecBase) callconv(.c) *Message;

/// pr_ExitCode: gets the return code and pr_ExitData, returns the new code.
pub const ExitFn = *const fn (return_code: i32, exit_data: isize) callconv(.c) i32;

// pr_Flags: what goes when the process ends.
pub const PRF_FREESEGLIST: u32 = 1 << 0;
pub const PRF_FREECURRDIR: u32 = 1 << 1;
pub const PRF_FREECLI: u32 = 1 << 2;
pub const PRF_CLOSEINPUT: u32 = 1 << 3;
pub const PRF_CLOSEOUTPUT: u32 = 1 << 4;
pub const PRF_FREEARGS: u32 = 1 << 5;

/// A command's code, as RunCommand runs it on the calling
/// process: SysBase, the argument line (ending in a newline; Input() reads
/// it first too) and its length; the return code (RETURN_*; -1 is
/// RunCommand's "couldn't run").
pub const CommandFn = *const fn (sys_base: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32;

/// What a resident segment's code is, rather than a seglist, which ROM
/// code has none of: a process entry (a handler, a shell: CreateNewProc's
/// NP_Seglist runs it), a command (RunCommand runs it), or both.
pub const SegCode = extern struct {
    entry: ?TaskFn = null,
    command: ?CommandFn = null,
};

/// What a shell dos starts is for, ACTION_STARTUP's dp_Arg1
/// (dp_Arg2: SHF_*). dos has set the shell's CLI up before: its streams
/// (cli_StandardInput, cli_CurrentInput, cli_StandardOutput), current
/// directory, prompt and path.
pub const ShellMode = enum(isize) {
    /// Commands from cli_StandardInput (a console gets a prompt) until its
    /// end or EndCLI: NewShell, a shell of its own.
    interactive = 0,
    /// The commands of cli_CurrentInput, then the end: System().
    system = 1,
    /// The commands of cli_CurrentInput, then cli_StandardInput's:
    /// Execute().
    execute = 2,
};

/// Reply to the startup packet at once, not with the return code at the
/// end.
pub const SHF_ASYNCH: isize = 1 << 0;
/// Close cli_StandardInput at the end.
pub const SHF_CLOSE_INPUT: isize = 1 << 1;
/// Close cli_StandardOutput at the end.
pub const SHF_CLOSE_OUTPUT: isize = 1 << 2;
/// Close pr_CES, the error stream, at the end.
pub const PRF_CLOSEERROR: u32 = 1 << 6;

/// A node of a CLI's command path (cli_CommandDir): a directory's lock
/// and the next node. dos copies it for a new CLI
/// (NP_Path, the parent's) and frees it at the process's end.
pub const PathNode = extern struct {
    next: ?*PathNode = null,
    lock: ?*FileLock = null,
};

/// struct Process: a task that dos knows. Its msg_port is where packets
/// for it arrive and where its own packets come back.
/// The bytes of a CLI's name buffers, the NUL included: 128 each. A current directory's name is a whole path,
/// so it gets as much as a name dos takes (255 and the NUL).
pub const CLI_MAX_SET_NAME: usize = 256;
pub const CLI_MAX_COMMAND_NAME: usize = 128;
pub const CLI_MAX_PROMPT: usize = 128;
pub const CLI_MAX_COMMAND_FILE: usize = 128;
/// A new CLI's fail level.
pub const CLI_INITIAL_FAIL_LEVEL: i32 = 10;
/// A new CLI's prompt when its parent has none.
pub const CLI_DEFAULT_PROMPT = "%N.%S> ";

/// struct CommandLineInterface, without BCPL: the names are
/// NUL-terminated strings in buffers of CLI_MAX_* bytes, allocated with it
/// (AllocDosObject(DOS_CLI), or CreateNewProc's NP_Cli).
pub const CommandLineInterface = extern struct {
    /// cli_Result2: IoErr of the last command.
    result2: i32 = 0,
    /// cli_SetName: the current directory's name (SetCurrentDirName).
    set_name: ?[*:0]u8 = null,
    /// cli_CommandDir: the command path (to come with the shell).
    command_dir: ?*PathNode = null,
    /// cli_ReturnCode: the last command's return code.
    return_code: i32 = 0,
    /// cli_CommandName: the command running (SetProgramName).
    command_name: ?[*:0]u8 = null,
    /// cli_FailLevel: set by FAILAT.
    fail_level: i32 = CLI_INITIAL_FAIL_LEVEL,
    /// cli_Prompt: set by PROMPT (SetPrompt).
    prompt: ?[*:0]u8 = null,
    /// cli_StandardInput, cli_CurrentInput: the terminal, and what the CLI
    /// reads now (a script, say).
    standard_input: ?*FileHandle = null,
    current_input: ?*FileHandle = null,
    /// cli_CommandFile: the EXECUTE script's name.
    command_file: ?[*:0]u8 = null,
    /// cli_Interactive: prompts wanted.
    interactive: bool = false,
    /// cli_Background: made by RUN.
    background: bool = true,
    /// cli_CurrentOutput, cli_StandardOutput
    current_output: ?*FileHandle = null,
    /// cli_DefaultStack: in bytes.
    default_stack: u32 = 0,
    standard_output: ?*FileHandle = null,
    /// cli_Module: the loaded command's segment list.
    module: ?*anyopaque = null,
};

pub const Process = extern struct {
    /// pr_Task: ln_Type is NT_PROCESS.
    task: Task = .{ .node = .{ .type = .process } },
    /// pr_MsgPort: signals SIGB_DOS.
    msg_port: MsgPort = .{},
    /// pr_SegList: the process's code (none yet: no LoadSeg).
    seg_list: ?*anyopaque = null,
    /// pr_StackSize: in bytes.
    stack_size: u32 = 0,
    /// pr_TaskNum: its CLI number, 0 if not a CLI.
    task_num: u32 = 0,
    /// pr_StackBase: the high end of the stack.
    stack_base: usize = 0,
    /// pr_Result2: what IoErr() returns.
    result2: i32 = 0,
    /// pr_CurrentDir: a lock on the current directory (null: the root of
    /// pr_FileSystemTask).
    current_dir: ?*FileLock = null,
    /// pr_CIS, pr_COS: the current input and output (Input, Output).
    cis: ?*FileHandle = null,
    cos: ?*FileHandle = null,
    /// pr_ConsoleTask: the console handler's port.
    console_task: ?*MsgPort = null,
    /// pr_FileSystemTask: the default file system's port.
    file_system_task: ?*MsgPort = null,
    /// pr_CLI: the CommandLineInterface, null if not a CLI.
    cli: ?*CommandLineInterface = null,
    /// pr_PktWait: called by WaitPkt and DoPkt to wait for a packet.
    pkt_wait: ?PktWaitFn = null,
    /// pr_WindowPtr: where requesters go (0: the default, -1: none).
    window_ptr: ?*anyopaque = null,
    /// pr_HomeDir: a lock on the program's directory.
    home_dir: ?*FileLock = null,
    /// pr_Flags: PRF_*.
    flags: u32 = 0,
    /// pr_ExitCode, pr_ExitData: called when the process ends.
    exit_code: ?ExitFn = null,
    exit_data: isize = 0,
    /// pr_Arguments: the arguments it was started with.
    arguments: ?[*:0]const u8 = null,
    /// The copy of NP_Arguments CreateNewProc made (with PRF_FREEARGS):
    /// freed when the process ends, whatever pr_Arguments has become since
    /// SetArgStr, so a line set and set back again is still freed once.
    own_arguments: ?[*:0]const u8 = null,
    /// pr_LocalVars: local shell variables.
    local_vars: MinList = .{},
    /// pr_ShellPrivate
    shell_private: u32 = 0,
    /// pr_CES: the error stream (null: use pr_COS).
    ces: ?*FileHandle = null,
    /// The device node whose handler this process runs, when
    /// that handler's code was loaded from a file. dos counts the
    /// processes running it, and the last one to end gives the code back.
    handler_node: ?*DosList = null,
};

/// dol_Type: what a DosList node is.
pub const DosListType = enum(i32) {
    /// Never found by FindDosEntry (a late assign while it binds).
    private = -1,
    /// A handler or file system: "DF0", "NIL".
    device = 0,
    /// An assign to a directory: "LIBS".
    directory = 1,
    /// A mounted disk: "System".
    volume = 2,
    /// A late assign, bound on first use.
    late = 3,
    /// A non-binding assign, a path looked up each time.
    nonbinding = 4,
    _,
};

pub const DLT_PRIVATE: i32 = -1;
pub const DLT_DEVICE: i32 = 0;
pub const DLT_DIRECTORY: i32 = 1;
pub const DLT_VOLUME: i32 = 2;
pub const DLT_LATE: i32 = 3;
pub const DLT_NONBINDING: i32 = 4;

/// A device's part of a DosList: its handler.
pub const DosListHandler = extern struct {
    /// dol_Handler: the handler's name: a ROM segment's, or the file to
    /// load.
    handler: ?[*:0]const u8 = null,
    /// dol_StackSize: in bytes (0: 8 KiB).
    stack_size: u32 = 0,
    /// dol_Priority
    priority: i32 = 0,
    /// dol_Startup: handed to the handler in ACTION_STARTUP's dp_Arg2.
    startup: usize = 0,
    /// dol_SegList: the handler's code, when it was loaded from a file.
    seg_list: ?*anyopaque = null,
    /// The handler's code as a process entry - a ROM
    /// segment's, or the one found in `seg_list`. dol_GlobVec (BCPL) is
    /// gone.
    entry: ?TaskFn = null,
    /// How many processes are running the code in
    /// `seg_list`. When the last one ends the code is unloaded and the
    /// next use loads it again.
    users: u32 = 0,
};

/// A volume's part of a DosList.
pub const DosListVolume = extern struct {
    /// dol_VolumeDate: tells volumes of the same name apart.
    volume_date: DateStamp = .{},
    /// dol_LockList: locks kept while the volume is out.
    lock_list: ?*FileLock = null,
    /// dol_DiskType: ID_DOS_DISK and the like.
    disk_type: u32 = 0,
};

/// An assign's part of a DosList.
pub const DosListAssign = extern struct {
    /// dol_AssignName: the path of a late or non-binding assign.
    assign_name: ?[*:0]const u8 = null,
    /// dol_List: the further directories of a multi-assign.
    list: ?*AssignList = null,
};

/// dol_misc
pub const DosListMisc = extern union {
    handler: DosListHandler,
    volume: DosListVolume,
    assign: DosListAssign,
};

/// struct DosList: a node of dos's device list (devices, volumes and
/// assigns). Walk it only between LockDosList and UnLockDosList.
pub const DosList = extern struct {
    /// dol_Next
    next: ?*DosList = null,
    /// dol_Type
    type: DosListType = .device,
    /// dol_Task: the handler's port (null: not started; for an assign,
    /// its directory's handler).
    task: ?*MsgPort = null,
    /// dol_Lock: an assign's directory lock.
    lock: ?*FileLock = null,
    /// dol_misc
    misc: DosListMisc = .{ .handler = .{} },
    /// dol_Name: without the colon; a C string, not a BSTR.
    name: [*:0]const u8 = "",
};

/// struct AssignList: a further directory of a multi-assign.
pub const AssignList = extern struct {
    next: ?*AssignList = null,
    lock: ?*FileLock = null,
};

/// struct DevProc: what GetDeviceProc found for a name.
pub const DevProc = extern struct {
    /// dvp_Port: the handler to send packets to.
    port: ?*MsgPort = null,
    /// dvp_Lock: the directory to start from (an assign's, the current
    /// one), null for the root.
    lock: ?*FileLock = null,
    /// dvp_Flags: DVPF_*.
    flags: u32 = 0,
    /// dvp_DevNode: the DosList node it came from (null for CONSOLE: and
    /// names without a colon).
    dev_node: ?*DosList = null,
};

/// dvp_Flags: dvp_Lock is a temporary lock FreeDeviceProc unlocks.
pub const DVPF_UNLOCK: u32 = 1 << 0;
/// dvp_Flags: a multi-assign; GetDeviceProc with this DevProc gives the next.
pub const DVPF_ASSIGN: u32 = 1 << 1;

// LockDosList's flags: exactly one of LDF_READ and LDF_WRITE, and what to
// lock (the list for LDF_DEVICES/VOLUMES/ASSIGNS, or the entry or delete
// lock); FindDosEntry and NextDosEntry take the types to look at.
pub const LDF_READ: u32 = 1 << 0;
pub const LDF_WRITE: u32 = 1 << 1;
pub const LDF_DEVICES: u32 = 1 << 2;
pub const LDF_VOLUMES: u32 = 1 << 3;
pub const LDF_ASSIGNS: u32 = 1 << 4;
pub const LDF_ENTRY: u32 = 1 << 5;
pub const LDF_DELETE: u32 = 1 << 6;
pub const LDF_ALL: u32 = LDF_DEVICES | LDF_VOLUMES | LDF_ASSIGNS;

/// seg_UC of system code (a file system, handler or shell): never counted
/// or removed.
pub const CMD_SYSTEM: i32 = -1;
/// seg_UC of a shell's internal command.
pub const CMD_INTERNAL: i32 = -2;
/// seg_UC of a disabled internal command: to be ignored.
pub const CMD_DISABLED: i32 = -999;

/// One loaded segment of a program or module file: the block LoadSeg
/// allocated, with the next one after it. `data` is the
/// first of `mem_size` bytes; for a code segment `run_address` is where the
/// same bytes are on the instruction bus, which is where it runs.
pub const SegList = extern struct {
    next: ?*SegList = null,
    /// Bytes of the whole block, for FreeMem.
    block_size: u32 = 0,
    /// Bytes of this segment.
    mem_size: u32 = 0,
    kind: loadfile.SegmentKind = .code,
    pad: [3]u8 = @splat(0),
    /// Where its bytes are (the data bus).
    data: ?[*]u8 = null,
    /// Where they run, for a code segment (exec's CodeAddress).
    run_address: ?[*]const u8 = null,
    /// The first node only: where the program starts, ready to call. A
    /// program's entry is a CommandFn, a module's a stub that refuses to
    /// run (its ROM tag is what matters).
    entry: ?*const anyopaque = null,
};

/// struct Segment: a resident segment, named code dos keeps (AddSegment).
pub const Segment = extern struct {
    /// seg_Next
    next: ?*Segment = null,
    /// seg_UC: CMD_SYSTEM, CMD_INTERNAL, CMD_DISABLED, or (0 and up) how
    /// many use it. Changed only with the list locked (LockSegmentList).
    uc: i32 = 0,
    /// seg_Seg: what LoadSeg made, for code that came from a file.
    seg_list: ?*SegList = null,
    /// Its code: a process entry, a command.
    code: SegCode = .{},
    /// seg_Name: a C string, not a BSTR.
    name: [*:0]const u8 = "",
};

/// struct FileLock: a lock on a file or directory. The handler makes it
/// (ACTION_LOCATE_OBJECT, COPY_DIR, PARENT, CREATE_DIR) and frees it
/// (ACTION_FREE_LOCK); dos only reads `task`, `volume` and `key`. A handler
/// that needs more can give out a bigger struct with the FileLock first.
pub const FileLock = extern struct {
    /// fl_Link: the handler's (a list of its locks).
    link: ?*FileLock = null,
    /// fl_Key: the handler's key for the object (a block, a pointer).
    key: usize = 0,
    /// fl_Access: SHARED_LOCK or EXCLUSIVE_LOCK, as asked for.
    access: i32 = -2,
    /// fl_Task: the handler's port, where packets about the lock go.
    task: ?*MsgPort = null,
    /// fl_Volume: the volume's DosList node.
    volume: ?*DosList = null,
};
