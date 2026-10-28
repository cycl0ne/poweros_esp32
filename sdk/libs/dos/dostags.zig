// SPDX-License-Identifier: MIT
//! dos's tags: CreateNewProc's (NP_*), SystemTagList's (SYS_*) and
//! FormatTags's (FORMAT_*). Each set has a base of its own, so that no
//! two sets meet in one list. Which of them a call honours, and how, is
//! that call's contract.
const TAG_USER = @import("../utility/utility.zig").TAG_USER;

pub const NP_Dummy = TAG_USER + 1000;
/// A `SegCode` whose process entry runs, instead of NP_Entry.
pub const NP_Seglist = NP_Dummy + 1;
/// Free the seglist when the process ends. Not read: CreateNewProc frees
/// no code.
pub const NP_FreeSeglist = NP_Dummy + 2;
/// The code to run: a TaskFn, which gets SysBase.
pub const NP_Entry = NP_Dummy + 3;
/// The process's input and output file handles.
pub const NP_Input = NP_Dummy + 4;
pub const NP_Output = NP_Dummy + 5;
pub const NP_CloseInput = NP_Dummy + 6;
pub const NP_CloseOutput = NP_Dummy + 7;
pub const NP_Error = NP_Dummy + 8;
pub const NP_CloseError = NP_Dummy + 9;
/// A lock on the process's current directory.
pub const NP_CurrentDir = NP_Dummy + 10;
/// The stack in bytes.
pub const NP_StackSize = NP_Dummy + 11;
/// The name, copied.
pub const NP_Name = NP_Dummy + 12;
/// The priority (default: the parent's).
pub const NP_Priority = NP_Dummy + 13;
/// pr_ConsoleTask (default: the parent's).
pub const NP_ConsoleTask = NP_Dummy + 14;
/// pr_WindowPtr (default: the parent's, if 0 or -1).
pub const NP_WindowPtr = NP_Dummy + 15;
pub const NP_HomeDir = NP_Dummy + 16;
pub const NP_CopyVars = NP_Dummy + 17;
pub const NP_Cli = NP_Dummy + 18;
pub const NP_Path = NP_Dummy + 19;
pub const NP_CommandName = NP_Dummy + 20;
pub const NP_Arguments = NP_Dummy + 21;
pub const NP_NotifyOnDeath = NP_Dummy + 22;
pub const NP_Synchronous = NP_Dummy + 23;
pub const NP_ExitCode = NP_Dummy + 24;
pub const NP_ExitData = NP_Dummy + 25;
/// tc_UserData of the new process, set before it first runs: a pointer
/// its code finds with FindTask(null), which is how a module hands its
/// own process its base.
pub const NP_UserData = NP_Dummy + 26;
/// The cores the new process runs on (exec's TF_CORE0 to TF_CORE3, or 0
/// for any), set before it first runs.
pub const NP_Affinity = NP_Dummy + 27;
/// A message replied to its reply port once the new process has ended and
/// nothing runs on its stack any more (exec's SetTaskEndMsg): when the code
/// it ran may be unloaded. Null (the default): none.
pub const NP_EndMsg = NP_Dummy + 28;
/// A library whose code the new process runs, with an open count the
/// caller hands over: dos closes it once the process's code has returned,
/// so the library cannot go while its code still runs. Null (the
/// default): none.
pub const NP_HoldLibrary = NP_Dummy + 29;
/// The files the new process is started with: a `[*]const WBArg`, the
/// program itself first, and NP_NumArgs how many. CreateNewProc copies
/// them - each lock duplicated, each name copied - and the copy is the
/// process's, freed when it ends; the caller keeps its own. GetArgList
/// reads them.
pub const NP_ArgList = NP_Dummy + 30;
pub const NP_NumArgs = NP_Dummy + 31;

// SystemTagList's tags.
pub const SYS_Dummy = TAG_USER + 32;
/// The shell's input (default Input()).
pub const SYS_Input = SYS_Dummy + 1;
/// Its output (default Output()).
pub const SYS_Output = SYS_Dummy + 2;
/// Return at once; the shell closes SYS_Input and SYS_Output at its end.
pub const SYS_Asynch = SYS_Dummy + 3;
/// The resident "shell" instead of "BootShell".
pub const SYS_UserShell = SYS_Dummy + 4;
/// Another resident shell, by name.
pub const SYS_CustomShell = SYS_Dummy + 5;
/// An open file the new shell reads before its SYS_Input: the script a
/// NewShell starts with. The shell closes it at its end and carries on
/// with SYS_Input. Ignored when a command is given, which is already the
/// shell's first input.
pub const SYS_ScriptFile = SYS_Dummy + 6;
/// The console the new shell talks on, as a name to open ("CON:...",
/// "AUX:"), when SYS_Input and SYS_Output say nothing. dos opens it once
/// and gives the shell both directions of it, which is the only way to ask
/// for a console that is one window per Open: opening such a name twice
/// makes two windows. The shell closes it at its end.
pub const SYS_Window = SYS_Dummy + 7;

// FormatTags's tags.
pub const FORMAT_Dummy = TAG_USER + 3000;
/// The new volume's unit of allocation, in bytes: a file system's block,
/// FAT's cluster. 0, or the tag left out, for the file system's own
/// choice. A size the file system or the medium cannot have is refused
/// with ERROR_INVALID_ARGUMENT before anything is written.
pub const FORMAT_BlockSize = FORMAT_Dummy + 1;

// AllocDosObject's tags, after the Amiga's.
pub const ADO_Dummy = TAG_USER + 2000;
/// DOS_REQUEST: the port it comes back to, which other requests and the
/// program's own messages may share. Without it the request has a port of
/// its own, and a signal with it.
pub const ADO_ReplyPort = ADO_Dummy + 20;
