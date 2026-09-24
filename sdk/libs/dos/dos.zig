// SPDX-License-Identifier: MIT
//! dos.library (dos/dos.h): its name, the object types for AllocDosObject,
//! the error codes IoErr() returns and the commands' return codes. The
//! errors from 400 up are the system's own additions. Packets and
//! processes are in dosextens.zig, CreateNewProc's tags in dostags.zig;
//! everything is also here by name.

pub const dosextens = @import("dosextens.zig");
pub const dostags = @import("dostags.zig");
pub const path = @import("path.zig");
pub const exall = @import("exall.zig");
pub const dosasl = @import("dosasl.zig");
pub const datetime = @import("datetime.zig");
pub const stdio = @import("stdio.zig");
pub const rdargs = @import("rdargs.zig");
pub const vars = @import("var.zig");
pub const loadfile = @import("loadfile.zig");
pub const filehandler = @import("filehandler.zig");
pub const hardblocks = @import("hardblocks.zig");
pub const flashfs = @import("flashfs.zig");
pub const fat = @import("fat.zig");
pub const workfile = @import("workfile.zig");

/// The library's name, for OpenLibrary.
pub const DOSNAME = "dos.library";

/// What dos functions return for true and false (DOSTRUE is -1).
pub const DOSTRUE: isize = -1;
pub const DOSFALSE: isize = 0;

/// struct DateStamp: days since 1 Jan 1978, minutes past midnight, ticks
/// (1/50 s) past the minute.
pub const DateStamp = extern struct {
    days: i32 = 0,
    minute: i32 = 0,
    tick: i32 = 0,

    pub fn eql(a: DateStamp, b: DateStamp) bool {
        return a.days == b.days and a.minute == b.minute and a.tick == b.tick;
    }
};

/// struct FileInfoBlock: what EXAMINE_OBJECT and EXAMINE_NEXT fill in.
/// The key is pointer-sized, the sizes 64-bit, and there are no reserved
/// bytes (no binary compatibility to keep).
pub const FileInfoBlock = extern struct {
    /// fib_DiskKey: the handler's (ExNext goes on from it).
    disk_key: usize = 0,
    /// fib_DirEntryType: above 0 a directory, below 0 a file (ST_*).
    dir_entry_type: i32 = 0,
    /// fib_FileName: NUL-terminated.
    file_name: [108]u8 = @splat(0),
    /// fib_Protection: FIBF_*.
    protection: u32 = 0,
    /// fib_EntryType: ST_*, as dir_entry_type.
    entry_type: i32 = 0,
    /// fib_Size: in bytes.
    size: u64 align(4) = 0,
    /// fib_NumBlocks
    num_blocks: u64 align(4) = 0,
    /// fib_Date: last changed.
    date: DateStamp = .{},
    /// fib_Comment: NUL-terminated.
    comment: [80]u8 = @splat(0),
    owner_uid: u16 = 0,
    owner_gid: u16 = 0,
};

// FileInfoBlock's entry types.
pub const ST_ROOT: i32 = 1;
pub const ST_USERDIR: i32 = 2;
pub const ST_SOFTLINK: i32 = 3;
pub const ST_LINKDIR: i32 = 4;
pub const ST_FILE: i32 = -3;
pub const ST_LINKFILE: i32 = -4;

// FileInfoBlock's protection bits (the low four are set to forbid).
pub const FIBF_DELETE: u32 = 1 << 0;
pub const FIBF_EXECUTE: u32 = 1 << 1;
pub const FIBF_WRITE: u32 = 1 << 2;
pub const FIBF_READ: u32 = 1 << 3;
pub const FIBF_ARCHIVE: u32 = 1 << 4;
pub const FIBF_PURE: u32 = 1 << 5;
pub const FIBF_SCRIPT: u32 = 1 << 6;

// Open's modes: they are the FIND actions' numbers.
/// An existing file, for reading or writing (ACTION_FINDINPUT).
pub const MODE_OLDFILE: i32 = 1005;
/// A new file, or an existing one emptied, for writing (ACTION_FINDOUTPUT).
pub const MODE_NEWFILE: i32 = 1006;
/// An existing file, or a new one, with a shared lock (ACTION_FINDUPDATE).
pub const MODE_READWRITE: i32 = 1004;

// SEEK's modes.
pub const OFFSET_BEGINNING: i32 = -1;
pub const OFFSET_CURRENT: i32 = 0;
pub const OFFSET_END: i32 = 1;

// Disk types (dol_DiskType, id_DiskType).
pub const ID_NO_DISK_PRESENT: u32 = 0xFFFF_FFFF;
/// "BAD\0"
pub const ID_UNREADABLE_DISK: u32 = 0x4241_4400;
/// "DOS\0": the old file system; RAM: says it too.
pub const ID_DOS_DISK: u32 = 0x444F_5300;
pub const ID_FFS_DISK: u32 = 0x444F_5301;
pub const ID_INTER_DOS_DISK: u32 = 0x444F_5302;
pub const ID_INTER_FFS_DISK: u32 = 0x444F_5303;
pub const ID_FASTDIR_DOS_DISK: u32 = 0x444F_5304;
pub const ID_FASTDIR_FFS_DISK: u32 = 0x444F_5305;
/// "NDOS"
pub const ID_NOT_REALLY_DOS: u32 = 0x4E44_4F53;
/// "CON\0" and "RAW\0": a console's DISK_INFO, cooked or raw.
pub const ID_CON: u32 = 0x434F_4E00;
pub const ID_RAWCON: u32 = 0x5241_5700;
/// "KICK"
pub const ID_KICKSTART_DISK: u32 = 0x4B49_434B;
/// "MSD\0"
pub const ID_MSDOS_DISK: u32 = 0x4D53_4400;

// id_DiskState
pub const ID_WRITE_PROTECTED: i32 = 80;
pub const ID_VALIDATING: i32 = 81;
pub const ID_VALIDATED: i32 = 82;

/// struct InfoData: what Info (ACTION_INFO, ACTION_DISK_INFO) tells about
/// a volume. The block counts are 64-bit, as the FIB's sizes.
pub const InfoData = extern struct {
    /// id_NumSoftErrors: errors the handler got over.
    num_soft_errors: i32 = 0,
    /// id_UnitNumber: the device's unit (-1: none).
    unit_number: i32 = 0,
    /// id_DiskState: ID_WRITE_PROTECTED, ID_VALIDATING or ID_VALIDATED.
    disk_state: i32 = 0,
    /// id_NumBlocks, id_NumBlocksUsed
    num_blocks: u64 align(4) = 0,
    num_blocks_used: u64 align(4) = 0,
    /// id_BytesPerBlock
    bytes_per_block: u32 = 0,
    /// id_DiskType: ID_*.
    disk_type: u32 = 0,
    /// id_VolumeNode: the volume's DosList node.
    volume_node: ?*dosextens.DosList = null,
    /// id_InUse: -1 (DOSTRUE) while something uses the volume.
    in_use: i32 = 0,
};

// ChangeMode's kinds.
pub const CHANGE_LOCK: i32 = 0;
pub const CHANGE_FH: i32 = 1;

// Lock modes (Lock's `mode`, fl_Access).
pub const SHARED_LOCK: i32 = -2;
pub const ACCESS_READ: i32 = -2;
pub const EXCLUSIVE_LOCK: i32 = -1;
pub const ACCESS_WRITE: i32 = -1;

// SameLock's results.
pub const LOCK_SAME: i32 = 0;
pub const LOCK_SAME_VOLUME: i32 = 1;
pub const LOCK_DIFFERENT: i32 = -1;

// AllocDosObject's types.
pub const DOS_FILEHANDLE: u32 = 0;
pub const DOS_EXALLCONTROL: u32 = 1;
pub const DOS_FIB: u32 = 2;
/// A DosPacket, for packet-level I/O.
pub const DOS_STDPKT: u32 = 3;
pub const DOS_CLI: u32 = 4;
pub const DOS_RDARGS: u32 = 5;

// Errors from IoErr().
pub const ERROR_NO_FREE_STORE: i32 = 103;
pub const ERROR_TASK_TABLE_FULL: i32 = 105;
pub const ERROR_BAD_TEMPLATE: i32 = 114;
pub const ERROR_BAD_NUMBER: i32 = 115;
pub const ERROR_REQUIRED_ARG_MISSING: i32 = 116;
pub const ERROR_KEY_NEEDS_ARG: i32 = 117;
pub const ERROR_TOO_MANY_ARGS: i32 = 118;
pub const ERROR_UNMATCHED_QUOTES: i32 = 119;
pub const ERROR_LINE_TOO_LONG: i32 = 120;
pub const ERROR_FILE_NOT_OBJECT: i32 = 121;
pub const ERROR_INVALID_RESIDENT_LIBRARY: i32 = 122;
pub const ERROR_NO_DEFAULT_DIR: i32 = 201;
pub const ERROR_OBJECT_IN_USE: i32 = 202;
pub const ERROR_OBJECT_EXISTS: i32 = 203;
pub const ERROR_DIR_NOT_FOUND: i32 = 204;
pub const ERROR_OBJECT_NOT_FOUND: i32 = 205;
pub const ERROR_BAD_STREAM_NAME: i32 = 206;
pub const ERROR_OBJECT_TOO_LARGE: i32 = 207;
pub const ERROR_ACTION_NOT_KNOWN: i32 = 209;
pub const ERROR_INVALID_COMPONENT_NAME: i32 = 210;
pub const ERROR_INVALID_LOCK: i32 = 211;
pub const ERROR_OBJECT_WRONG_TYPE: i32 = 212;
pub const ERROR_DISK_NOT_VALIDATED: i32 = 213;
pub const ERROR_DISK_WRITE_PROTECTED: i32 = 214;
pub const ERROR_RENAME_ACROSS_DEVICES: i32 = 215;
pub const ERROR_DIRECTORY_NOT_EMPTY: i32 = 216;
pub const ERROR_TOO_MANY_LEVELS: i32 = 217;
pub const ERROR_DEVICE_NOT_MOUNTED: i32 = 218;
pub const ERROR_SEEK_ERROR: i32 = 219;
pub const ERROR_COMMENT_TOO_BIG: i32 = 220;
pub const ERROR_DISK_FULL: i32 = 221;
pub const ERROR_DELETE_PROTECTED: i32 = 222;
pub const ERROR_WRITE_PROTECTED: i32 = 223;
pub const ERROR_READ_PROTECTED: i32 = 224;
pub const ERROR_NOT_A_DOS_DISK: i32 = 225;
pub const ERROR_NO_DISK: i32 = 226;
pub const ERROR_NO_MORE_ENTRIES: i32 = 232;
pub const ERROR_IS_SOFT_LINK: i32 = 233;
pub const ERROR_OBJECT_LINKED: i32 = 234;
pub const ERROR_BAD_HUNK: i32 = 235;
pub const ERROR_NOT_IMPLEMENTED: i32 = 236;
pub const ERROR_RECORD_NOT_LOCKED: i32 = 240;
pub const ERROR_LOCK_COLLISION: i32 = 241;
pub const ERROR_LOCK_TIMEOUT: i32 = 242;
pub const ERROR_UNLOCK_ERROR: i32 = 243;
pub const ERROR_BUFFER_OVERFLOW: i32 = 303;
pub const ERROR_BREAK: i32 = 304;
pub const ERROR_NOT_EXECUTABLE: i32 = 305;
// The system's own.
pub const ERROR_INVALID_ARGUMENT: i32 = 400;
pub const ERROR_INVALID_DOS_ENTRY: i32 = 401;
pub const ERROR_NO_INPUT_STREAM: i32 = 402;
pub const ERROR_BUFFER_TOO_SMALL: i32 = 403;
/// A process-only function was called from a plain task.
pub const ERROR_NO_PROCESS: i32 = 404;
pub const ERROR_NO_HANDLER: i32 = 405;
/// DoPkt got another packet back than the one it sent.
pub const ERROR_PACKET_ASYNC: i32 = 406;
pub const ERROR_ERROR_IN_PACKET: i32 = 407;
pub const ERROR_NO_CURRENT_DIRECTORY: i32 = 408;
pub const ERROR_HANDLER_NOT_LOADED: i32 = 409;
pub const ERROR_HANDLER_START_ERROR: i32 = 410;
/// A write to a pipe whose reader has gone, rather than the data thrown
/// away unseen.
pub const ERROR_BROKEN_PIPE: i32 = 411;

// The commands' return codes (FAILAT, IF).
pub const RETURN_OK: i32 = 0;
pub const RETURN_WARN: i32 = 5;
pub const RETURN_ERROR: i32 = 10;
pub const RETURN_FAIL: i32 = 20;

pub const DosPacket = dosextens.DosPacket;
pub const PacketArgs = dosextens.PacketArgs;
pub const ActionCode = dosextens.ActionCode;
pub const WaitArgs = dosextens.WaitArgs;
pub const InhibitArgs = dosextens.InhibitArgs;
pub const CacheArgs = dosextens.CacheArgs;
pub const ScreenModeArgs = dosextens.ScreenModeArgs;
pub const Process = dosextens.Process;
pub const PktWaitFn = dosextens.PktWaitFn;
pub const ExitFn = dosextens.ExitFn;
pub const PRF_FREESEGLIST = dosextens.PRF_FREESEGLIST;
pub const PRF_FREECURRDIR = dosextens.PRF_FREECURRDIR;
pub const PRF_FREECLI = dosextens.PRF_FREECLI;
pub const PRF_CLOSEINPUT = dosextens.PRF_CLOSEINPUT;
pub const PRF_CLOSEOUTPUT = dosextens.PRF_CLOSEOUTPUT;
pub const PRF_FREEARGS = dosextens.PRF_FREEARGS;
pub const DosList = dosextens.DosList;
pub const DosListType = dosextens.DosListType;
pub const DosListMisc = dosextens.DosListMisc;
pub const DosListHandler = dosextens.DosListHandler;
pub const DosListVolume = dosextens.DosListVolume;
pub const DosListAssign = dosextens.DosListAssign;
pub const AssignList = dosextens.AssignList;
pub const DevProc = dosextens.DevProc;
pub const DLT_PRIVATE = dosextens.DLT_PRIVATE;
pub const DLT_DEVICE = dosextens.DLT_DEVICE;
pub const DLT_DIRECTORY = dosextens.DLT_DIRECTORY;
pub const DLT_VOLUME = dosextens.DLT_VOLUME;
pub const DLT_LATE = dosextens.DLT_LATE;
pub const DLT_NONBINDING = dosextens.DLT_NONBINDING;
pub const DVPF_UNLOCK = dosextens.DVPF_UNLOCK;
pub const DVPF_ASSIGN = dosextens.DVPF_ASSIGN;
pub const LDF_READ = dosextens.LDF_READ;
pub const LDF_WRITE = dosextens.LDF_WRITE;
pub const LDF_DEVICES = dosextens.LDF_DEVICES;
pub const LDF_VOLUMES = dosextens.LDF_VOLUMES;
pub const LDF_ASSIGNS = dosextens.LDF_ASSIGNS;
pub const LDF_ENTRY = dosextens.LDF_ENTRY;
pub const LDF_DELETE = dosextens.LDF_DELETE;
pub const LDF_ALL = dosextens.LDF_ALL;
pub const Segment = dosextens.Segment;
pub const SegList = dosextens.SegList;
pub const FileLock = dosextens.FileLock;
pub const FileHandle = dosextens.FileHandle;
pub const FindArgs = dosextens.FindArgs;
pub const IOArgs = dosextens.IOArgs;
pub const SeekArgs = dosextens.SeekArgs;
pub const ExamineArgs = dosextens.ExamineArgs;
pub const FileHandleArgs = dosextens.FileHandleArgs;
pub const ExamineFHArgs = dosextens.ExamineFHArgs;
pub const ExAllArgs = dosextens.ExAllArgs;
pub const RenameArgs = dosextens.RenameArgs;
pub const PropertyArgs = dosextens.PropertyArgs;
pub const ChangeModeArgs = dosextens.ChangeModeArgs;
pub const InfoArgs = dosextens.InfoArgs;
pub const FhFromLockArgs = dosextens.FhFromLockArgs;
pub const ExAllControl = exall.ExAllControl;
pub const CommandLineInterface = dosextens.CommandLineInterface;
pub const CLI_MAX_SET_NAME = dosextens.CLI_MAX_SET_NAME;
pub const CLI_MAX_COMMAND_NAME = dosextens.CLI_MAX_COMMAND_NAME;
pub const CLI_MAX_PROMPT = dosextens.CLI_MAX_PROMPT;
pub const CLI_MAX_COMMAND_FILE = dosextens.CLI_MAX_COMMAND_FILE;
pub const CLI_INITIAL_FAIL_LEVEL = dosextens.CLI_INITIAL_FAIL_LEVEL;
pub const CLI_DEFAULT_PROMPT = dosextens.CLI_DEFAULT_PROMPT;
pub const ExAllData = exall.ExAllData;
pub const AnchorPath = dosasl.AnchorPath;
/// struct DateTime: what DateToStr writes and StrToDate reads
/// (datetime.zig).
pub const DateTime = datetime.DateTime;
pub const LEN_DATSTRING = datetime.LEN_DATSTRING;
pub const DTB_SUBST = datetime.DTB_SUBST;
pub const DTF_SUBST = datetime.DTF_SUBST;
pub const DTB_FUTURE = datetime.DTB_FUTURE;
pub const DTF_FUTURE = datetime.DTF_FUTURE;
pub const FORMAT_DOS = datetime.FORMAT_DOS;
pub const FORMAT_INT = datetime.FORMAT_INT;
pub const FORMAT_USA = datetime.FORMAT_USA;
pub const FORMAT_CDN = datetime.FORMAT_CDN;
pub const FORMAT_MAX = datetime.FORMAT_MAX;
/// struct FileSysStartupMsg: the device a handler works on
/// (a device node's dol_Startup).
pub const FileSysStartupMsg = filehandler.FileSysStartupMsg;
/// struct DosEnvec: a medium's geometry and a file system's parameters.
pub const DosEnvec = filehandler.DosEnvec;
/// struct RigidDiskBlock: what a disk says about itself, and the chain of
/// PartitionBlocks that says what to mount from it.
pub const RigidDiskBlock = hardblocks.RigidDiskBlock;
pub const PartitionBlock = hardblocks.PartitionBlock;
pub const AChain = dosasl.AChain;
pub const APF_DOWILD = dosasl.APF_DOWILD;
pub const APF_ITSWILD = dosasl.APF_ITSWILD;
pub const APF_DODIR = dosasl.APF_DODIR;
pub const APF_DIDDIR = dosasl.APF_DIDDIR;
pub const APF_NOMEMERR = dosasl.APF_NOMEMERR;
pub const APF_DODOT = dosasl.APF_DODOT;
pub const APF_DirChanged = dosasl.APF_DirChanged;
pub const APF_FollowHLinks = dosasl.APF_FollowHLinks;
pub const DDF_PatternBit = dosasl.DDF_PatternBit;
pub const DDF_ExaminedBit = dosasl.DDF_ExaminedBit;
pub const DDF_Completed = dosasl.DDF_Completed;
pub const DDF_AllBit = dosasl.DDF_AllBit;
pub const DDF_Single = dosasl.DDF_Single;
pub const ED_NAME = exall.ED_NAME;
pub const ED_TYPE = exall.ED_TYPE;
pub const ED_SIZE = exall.ED_SIZE;
pub const ED_PROTECTION = exall.ED_PROTECTION;
pub const ED_DATE = exall.ED_DATE;
pub const ED_COMMENT = exall.ED_COMMENT;
pub const ED_OWNER = exall.ED_OWNER;
pub const CMD_SYSTEM = dosextens.CMD_SYSTEM;
pub const CMD_INTERNAL = dosextens.CMD_INTERNAL;
pub const CMD_DISABLED = dosextens.CMD_DISABLED;
pub const ParsedPath = path.ParsedPath;
pub const PathType = path.PathType;
pub const MAX_DEVICE_NAME = path.MAX_DEVICE_NAME;

pub const NP_Dummy = dostags.NP_Dummy;
pub const NP_Seglist = dostags.NP_Seglist;
pub const NP_FreeSeglist = dostags.NP_FreeSeglist;
pub const NP_Entry = dostags.NP_Entry;
pub const NP_Input = dostags.NP_Input;
pub const NP_Output = dostags.NP_Output;
pub const NP_CloseInput = dostags.NP_CloseInput;
pub const NP_CloseOutput = dostags.NP_CloseOutput;
pub const NP_Error = dostags.NP_Error;
pub const NP_CloseError = dostags.NP_CloseError;
pub const NP_CurrentDir = dostags.NP_CurrentDir;
pub const NP_StackSize = dostags.NP_StackSize;
pub const NP_Name = dostags.NP_Name;
pub const NP_Priority = dostags.NP_Priority;
pub const NP_ConsoleTask = dostags.NP_ConsoleTask;
pub const NP_WindowPtr = dostags.NP_WindowPtr;
pub const NP_HomeDir = dostags.NP_HomeDir;
pub const NP_CopyVars = dostags.NP_CopyVars;
pub const NP_Cli = dostags.NP_Cli;
pub const NP_Path = dostags.NP_Path;
pub const NP_CommandName = dostags.NP_CommandName;
pub const NP_Arguments = dostags.NP_Arguments;
pub const NP_NotifyOnDeath = dostags.NP_NotifyOnDeath;
pub const NP_Synchronous = dostags.NP_Synchronous;
pub const NP_ExitCode = dostags.NP_ExitCode;
pub const NP_ExitData = dostags.NP_ExitData;
pub const NP_UserData = dostags.NP_UserData;

// Buffered I/O (stdio.zig).
pub const BufferState = dosextens.BufferState;
pub const BUF_LINE = stdio.BUF_LINE;
pub const BUF_FULL = stdio.BUF_FULL;
pub const BUF_NONE = stdio.BUF_NONE;
pub const ENDSTREAMCH = stdio.ENDSTREAMCH;

// ReadArgs (rdargs.zig).
pub const RDArgs = rdargs.RDArgs;
pub const CSource = rdargs.CSource;
pub const RDAF_STDIN = rdargs.RDAF_STDIN;
pub const RDAF_NOALLOC = rdargs.RDAF_NOALLOC;
pub const RDAF_NOPROMPT = rdargs.RDAF_NOPROMPT;
pub const ITEM_EQUAL = rdargs.ITEM_EQUAL;
pub const ITEM_ERROR = rdargs.ITEM_ERROR;
pub const ITEM_NOTHING = rdargs.ITEM_NOTHING;
pub const ITEM_UNQUOTED = rdargs.ITEM_UNQUOTED;
pub const ITEM_QUOTED = rdargs.ITEM_QUOTED;

// Variables (var.zig).
pub const LocalVar = vars.LocalVar;
pub const LV_VAR = vars.LV_VAR;
pub const LV_ALIAS = vars.LV_ALIAS;
pub const LVB_IGNORE = vars.LVB_IGNORE;
pub const LVF_IGNORE = vars.LVF_IGNORE;
pub const GVF_GLOBAL_ONLY = vars.GVF_GLOBAL_ONLY;
pub const GVF_LOCAL_ONLY = vars.GVF_LOCAL_ONLY;
pub const GVF_BINARY_VAR = vars.GVF_BINARY_VAR;
pub const GVF_DONT_NULL_TERM = vars.GVF_DONT_NULL_TERM;
pub const GVF_SAVE_VAR = vars.GVF_SAVE_VAR;

pub const PathNode = dosextens.PathNode;
pub const SegCode = dosextens.SegCode;
pub const CommandFn = dosextens.CommandFn;
pub const ShellMode = dosextens.ShellMode;
pub const SHF_ASYNCH = dosextens.SHF_ASYNCH;
pub const SHF_CLOSE_INPUT = dosextens.SHF_CLOSE_INPUT;
pub const SHF_CLOSE_OUTPUT = dosextens.SHF_CLOSE_OUTPUT;
pub const SYS_Dummy = dostags.SYS_Dummy;
pub const SYS_Input = dostags.SYS_Input;
pub const SYS_Output = dostags.SYS_Output;
pub const SYS_Asynch = dostags.SYS_Asynch;
pub const SYS_UserShell = dostags.SYS_UserShell;
pub const SYS_CustomShell = dostags.SYS_CustomShell;
pub const SYS_ScriptFile = dostags.SYS_ScriptFile;
pub const SYS_Window = dostags.SYS_Window;
