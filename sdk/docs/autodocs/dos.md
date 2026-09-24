# dos.library

dos.library's functions: packets, dos objects, IoErr and processes,
the device list, paths, segments, locks, dates, files, examining, the
CLI, assigns, pattern searches, buffered I/O, argument parsing, faults,
variables and loading code. The functions come in the order they were
written.

Generated from the source by `./zig build autodoc`.

## Index

- [AbortPkt](#abortpkt) - Asks for a packet sent with SendPkt to be abandoned.
- [AddDosEntry](#adddosentry) - Puts a device, volume or assign node on the device list.
- [AddPart](#addpart) - Appends a name to a path in the caller's buffer.
- [AddSegment](#addsegment) - Adds named code to dos's resident segments.
- [AllocDosObject](#allocdosobject) - Allocates one of dos's objects by type.
- [AssignAdd](#assignadd) - Adds a directory to an assign, after the ones it has.
- [AssignLate](#assignlate) - Makes a name a late-binding assign to a path.
- [AssignLock](#assignlock) - Makes a name an assign to a directory, or removes the assign.
- [AssignPath](#assignpath) - Makes a name a non-binding assign to a path.
- [AttemptLockDosList](#attemptlockdoslist) - Locks the device list only if that can be done without waiting.
- [ChangeMode](#changemode) - Changes a lock or an open file between shared and exclusive access.
- [CheckSignal](#checksignal) - Tells which of some signals have come, and clears them.
- [Cli](#cli) - Returns the running process's CommandLineInterface, or null when it has none.
- [Close](#close) - Closes a file and frees its handle.
- [CompareDates](#comparedates) - Compares two DateStamps.
- [CreateDir](#createdir) - Makes a directory and returns an exclusive lock on it.
- [CreateNewProc](#createnewproc) - Starts a new process, set up from a tag list.
- [CurrentDir](#currentdir) - Makes a lock the calling process's current directory and returns the one before.
- [DateStamp](#datestamp) - Reads the time now into a DateStamp.
- [DateToStr](#datetostr) - Writes a DateStamp out as text.
- [Delay](#delay) - Waits a number of fiftieths of a second.
- [DeleteFile](#deletefile) - Deletes a file or an empty directory.
- [DeleteVar](#deletevar) - Deletes a local variable or alias, or a global variable.
- [DoPkt](#dopkt) - Sends a packet to a handler and waits for it to come back.
- [DupLock](#duplock) - Makes another shared lock on the object a lock is on.
- [DupLockFromFH](#duplockfromfh) - Gives a shared lock on an open file.
- [ErrorOutput](#erroroutput) - Returns the running process's error stream (pr_CES).
- [ExAll](#exall) - Reads entries of a directory into a buffer, as many as fit.
- [ExAllEnd](#exallend) - Stops an ExAll listing before its end.
- [ExNext](#exnext) - Fills in a FileInfoBlock with the next entry of a directory.
- [Examine](#examine) - Fills in a FileInfoBlock about the object a lock is on.
- [ExamineFH](#examinefh) - Fills in a FileInfoBlock about an open file.
- [Execute](#execute) - Runs a command in a new shell, which then reads more commands from a stream.
- [FGetC](#fgetc) - Reads the next byte of a file.
- [FGets](#fgets) - Reads a line from a file.
- [FPutC](#fputc) - Writes one byte to a file.
- [FPuts](#fputs) - Writes a string to a file.
- [FRead](#fread) - Reads up to `length` bytes from a file through its buffer.
- [FWrite](#fwrite) - Writes `length` bytes to a file through its buffer.
- [Fault](#fault) - Puts the text for an error code into a buffer.
- [FilePart](#filepart) - Finds the last component of a path.
- [FindArg](#findarg) - Finds which item of a template a keyword names.
- [FindCliProc](#findcliproc) - Returns the CLI process with a given number.
- [FindDosEntry](#finddosentry) - Finds the first node of some types, and optionally of a name, from a node on.
- [FindSegment](#findsegment) - Finds the next resident segment of a name.
- [FindVar](#findvar) - Finds a process's local variable or alias by name.
- [Flush](#flush) - Empties a file handle's buffer.
- [FreeArgs](#freeargs) - Frees what ReadArgs allocated.
- [FreeDeviceProc](#freedeviceproc) - Frees a DevProc GetDeviceProc gave.
- [FreeDosEntry](#freedosentry) - Frees a node MakeDosEntry made.
- [FreeDosObject](#freedosobject) - Frees an object AllocDosObject made.
- [GetArgStr](#getargstr) - Returns the argument line of the command the calling process runs.
- [GetConsoleTask](#getconsoletask) - Returns the running process's console handler's port (pr_ConsoleTask).
- [GetCurrentDirName](#getcurrentdirname) - Copies the name of the running process's current directory into the caller's buffer.
- [GetDeviceProc](#getdeviceproc) - Finds the handler a name's packets go to, and the directory the name is relative to.
- [GetFileSysTask](#getfilesystask) - Returns the running process's default file system's port (pr_FileSystemTask).
- [GetProgramDir](#getprogramdir) - Returns the running process's program directory (pr_HomeDir), the directory PROGDIR: names.
- [GetProgramName](#getprogramname) - Copies the running CLI's command name into the caller's buffer.
- [GetPrompt](#getprompt) - Copies the running CLI's prompt into the caller's buffer.
- [GetVar](#getvar) - Reads a variable's value into a buffer.
- [Info](#info) - Fills in an InfoData about the volume a lock is on.
- [Input](#input) - Gives the running process's input handle.
- [IoErr](#ioerr) - Returns the secondary result of the calling process's last dos call.
- [IsFileSystem](#isfilesystem) - Tells whether a name is on a file system.
- [IsInteractive](#isinteractive) - Tells whether a file is a console.
- [LoadSeg](#loadseg) - Loads a program or module file into memory, ready to run.
- [Lock](#lock) - Locks a file or directory by name.
- [LockDosList](#lockdoslist) - Locks the device list for reading or writing.
- [LockSegmentList](#locksegmentlist) - Locks the resident segment list and returns its first segment.
- [MakeDosEntry](#makedosentry) - Makes a device list node with a copy of its name.
- [MatchEnd](#matchend) - Ends a pattern search, freeing what it holds.
- [MatchFirst](#matchfirst) - Starts a pattern search and finds the first object the pattern names.
- [MatchNext](#matchnext) - Finds the next object a pattern search names.
- [MaxCli](#maxcli) - Returns the highest CLI number in use.
- [NameFromFH](#namefromfh) - Writes the full name of the file an open handle is on into the caller's buffer.
- [NameFromLock](#namefromlock) - Writes the full name of the object a lock is on, volume first, into the caller's buffer.
- [NextDosEntry](#nextdosentry) - Finds the node after a given one that is of some types.
- [Open](#open) - Opens a file by name.
- [OpenFromLock](#openfromlock) - Opens the file a lock is on.
- [Output](#output) - Gives the running process's output handle.
- [ParentDir](#parentdir) - Locks the directory an object is in.
- [ParentOfFH](#parentoffh) - Gives a shared lock on the directory of an open file.
- [ParsePath](#parsepath) - Splits a path into its device and the rest.
- [PathPart](#pathpart) - Finds where the directory part of a path ends.
- [PrintFault](#printfault) - Writes the text for an error code, and a newline, to Output().
- [PutStr](#putstr) - Writes a string to the process's output.
- [Read](#read) - Reads up to `length` bytes from a file.
- [ReadArgs](#readargs) - Parses a command line by a template into the caller's slots.
- [ReadItem](#readitem) - Reads the next item of a command line into a buffer.
- [RemAssignList](#remassignlist) - Removes one directory from an assign.
- [RemDosEntry](#remdosentry) - Takes a node off the device list.
- [RemSegment](#remsegment) - Takes a user segment nobody runs off the list and frees it.
- [Rename](#rename) - Renames or moves an object on its volume.
- [ReplyPkt](#replypkt) - Sends a packet back to its sender with its results.
- [RunCommand](#runcommand) - Runs a command's code on the calling process, on a stack of its own, with an argument line.
- [SameDevice](#samedevice) - Tells whether two locks are on the same device.
- [SameLock](#samelock) - Tells whether two locks are on the same object, the same volume, or neither.
- [Seek](#seek) - Moves a file's position.
- [SelectError](#selecterror) - Sets the running process's error stream (pr_CES) and returns the one it replaces.
- [SelectInput](#selectinput) - Makes a handle the running process's input.
- [SelectOutput](#selectoutput) - Makes a handle the running process's output.
- [SendPkt](#sendpkt) - Sends a packet to a handler without waiting for it.
- [SetArgStr](#setargstr) - Sets the argument line of the calling process, and returns the one before.
- [SetComment](#setcomment) - Sets or removes an object's comment.
- [SetConsoleTask](#setconsoletask) - Sets the running process's console handler's port (pr_ConsoleTask) and returns the one it replaces.
- [SetCurrentDirName](#setcurrentdirname) - Sets the running CLI's name for its current directory.
- [SetFileDate](#setfiledate) - Sets an object's date.
- [SetFileSize](#setfilesize) - Sets the size of an open file.
- [SetFileSysTask](#setfilesystask) - Sets the running process's default file system's port (pr_FileSystemTask) and returns the one it replaces.
- [SetIoErr](#setioerr) - Sets the calling process's secondary result, what IoErr() returns.
- [SetMode](#setmode) - Sets a console's mode.
- [SetOwner](#setowner) - Sets an object's owner.
- [SetProgramDir](#setprogramdir) - Sets the running process's program directory (pr_HomeDir) and returns the one it replaces.
- [SetProgramName](#setprogramname) - Sets the running CLI's command name.
- [SetPrompt](#setprompt) - Sets the running CLI's prompt.
- [SetProtection](#setprotection) - Sets an object's protection bits.
- [SetVBuf](#setvbuf) - Sets a file handle's buffering and buffer.
- [SetVar](#setvar) - Sets or deletes a local variable or alias, or a global variable.
- [SplitName](#splitname) - Copies one component of a path into a buffer.
- [StrToDate](#strtodate) - Reads a date and a time from text into a DateStamp.
- [StrToLong](#strtolong) - Reads a decimal number from the start of a string.
- [SystemTagList](#systemtaglist) - Runs a command line, or an interactive shell, in a new shell process.
- [UnGetC](#ungetc) - Pushes a character back onto a file handle.
- [UnLoadSeg](#unloadseg) - Frees a chain of segments LoadSeg made.
- [UnLock](#unlock) - Gives a lock back to the handler that made it.
- [UnLockDosList](#unlockdoslist) - Unlocks what LockDosList or AttemptLockDosList locked.
- [UnLockSegmentList](#unlocksegmentlist) - Unlocks the resident segment list.
- [VFPrintf](#vfprintf) - Writes formatted text to a file.
- [VPrintf](#vprintf) - Writes formatted text to the process's output.
- [WaitForChar](#waitforchar) - Tells whether a console has input within a time.
- [WaitPkt](#waitpkt) - Waits for a packet at the running process's msg_port and takes it off.
- [Write](#write) - Writes `length` bytes to a file.
- [WriteChars](#writechars) - Writes bytes to the process's output.

## AbortPkt

Asks for a packet sent with SendPkt to be abandoned.

**SYNOPSIS**

```zig
fn AbortPkt(_: *DosBase, _: *MsgPort, _: *DosPacket) void
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `port` - the handler's port the packet went to.
- `packet` - the packet.

**RESULT**

Nothing.

**BEHAVIOR**

Does nothing. A packet a handler has taken can't be pulled back from
it without the handler's help, and there is no packet type to ask for
that, so the call is kept for its slot and the caller still waits for
the packet to come back.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

The packet stays the handler's until it comes back.

**BUGS**

None known.

**SEE ALSO**

`SendPkt`, `WaitPkt`

**EXAMPLES**

```zig
dos_lib.AbortPkt(handler_port, &pkt);
_ = dos_lib.WaitPkt(); // it comes back all the same
```

## AddDosEntry

Puts a device, volume or assign node on the device list.

**SYNOPSIS**

```zig
fn AddDosEntry(db: *DosBase, dlist: *DosList) bool
```

**SINCE**

1.0. LVO -72.

**INPUTS**

- `dlist` - the node, from MakeDosEntry, not on the list.

**RESULT**

True if it is on the list; false with IoErr() ERROR_OBJECT_EXISTS if its
name is taken.

**BEHAVIOR**

Names are compared without case. A name is taken by any node of that
name, except that a volume may sit beside a device or an assign of its
name, and beside another volume of its name with a different creation
date - two disks of one name are two volumes. The node goes at the front
of the list. The list is locked with LDF_ALL | LDF_WRITE for the call.

**CONTEXT**

- Waits: yes, for the device list's semaphores.
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do.

**OWNERSHIP**

The node is the list's from now on, until RemDosEntry takes it off.

**BUGS**

None known.

**SEE ALSO**

`MakeDosEntry`, `RemDosEntry`, `FindDosEntry`

**EXAMPLES**

```zig
const node = dos_lib.MakeDosEntry("WORK", dos.DLT_DIRECTORY) orelse return false;
if (!dos_lib.AddDosEntry(node)) {
    dos_lib.FreeDosEntry(node);
    return false;
}
```

## AddPart

Appends a name to a path in the caller's buffer.

**SYNOPSIS**

```zig
fn AddPart(db: *DosBase, dirname: [*:0]u8, filename: [*:0]const u8, size: u32) bool
```

**SINCE**

1.0. LVO -104.

**INPUTS**

- `dirname` - the path, in a buffer that gets the result.
- `filename` - the name to add.
- `size` - the buffer's size in bytes, the NUL included.

**RESULT**

True with the joined path in `dirname`; false, with IoErr
ERROR_LINE_TOO_LONG, when it would not fit (a `size` of 0 included).
`dirname` is then unchanged.

**BEHAVIOR**

A '/' goes between the two unless `dirname` is empty or already ends in
':' or '/'. A `filename` with a colon is a whole path of its own: it
replaces `dirname`, except that one starting with ':' - the root of a
volume - keeps `dirname`'s device part and replaces what follows it.

**CONTEXT**

- Waits: no.
- Interrupts: no; it sets IoErr.
- Forbid: not needed.
- Process: a Task will do; IoErr is then not set.

**OWNERSHIP**

Nothing is allocated. Both strings stay the caller's.

**BUGS**

None known.

**SEE ALSO**

`FilePart`, `PathPart`, `SplitName`

**EXAMPLES**

```zig
var path: [256]u8 = undefined;
_ = utility_lib.Strlcpy(&path, path.len, "SYS:c");
if (!dos_lib.AddPart(@ptrCast(&path), "dir", path.len)) return dos_lib.IoErr();
// path is "SYS:c/dir"
```

## AddSegment

Adds named code to dos's resident segments.

**SYNOPSIS**

```zig
fn AddSegment(db: *DosBase, name: [*:0]const u8, code: ?*const dos.SegCode, seg_type: i32) bool
```

**SINCE**

1.0. LVO -124.

**INPUTS**

- `name` - the segment's name; it is copied.
- `code` - the code: a process entry, a command, or both; null for
  none.
- `seg_type` - its seg_UC: CMD_SYSTEM (or another negative kind) for
  system code, 0 for a user command nobody runs yet.

**RESULT**

True when added; false with ERROR_NO_FREE_STORE when there was no
memory.

**BEHAVIOR**

The segment and a copy of its name are one allocation. It goes in at
the front of the list, so a newer segment of the same name is found
first; a name already on the list is not checked for.

**CONTEXT**

- Waits: yes, for the segment list's semaphore.
- Interrupts: not safe.
- Forbid: not to be held; it may wait.
- Process: a Task will do. Not while holding LockSegmentList, which
  it takes exclusive.

**OWNERSHIP**

The segment is dos's from then on; `code` is copied and `name` stays
the caller's.

**BUGS**

None known.

**SEE ALSO**

`FindSegment`, `RemSegment`, `LockSegmentList`

**EXAMPLES**

```zig
const code: dos.SegCode = .{ .command = &myCommand };
if (!dos_lib.AddSegment("Mine", &code, 0)) return dos_lib.IoErr();
```

## AllocDosObject

Allocates one of dos's objects by type.

**SYNOPSIS**

```zig
fn AllocDosObject(db: *DosBase, obj_type: u32, tags: ?[*]const TagItem) ?*anyopaque
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `obj_type` - what to make: DOS_STDPKT, DOS_FILEHANDLE, DOS_FIB,
  DOS_EXALLCONTROL, DOS_CLI or DOS_RDARGS.
- `tags` - options for the object; none are read yet, so null will
  do.

**RESULT**

The object, ready to use, or null: with ERROR_NO_FREE_STORE when
there was no memory, and with IoErr unchanged for a type it doesn't
know.

**BEHAVIOR**

Each type is made as the area's header lists: cleared, with its
defaults, and for a CLI with its name buffers in the same block. A
DosPacket's message length is set so it can be sent at once.

**CONTEXT**

- Waits: no.
- Interrupts: not safe; it allocates.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

The object is the caller's, to give back with FreeDosObject and the
same type.

**BUGS**

None known.

**SEE ALSO**

`FreeDosObject`

**EXAMPLES**

```zig
const fib: *dos.FileInfoBlock = @ptrCast(@alignCast(dos_lib.AllocDosObject(dos.DOS_FIB, null) orelse return null));
defer dos_lib.FreeDosObject(dos.DOS_FIB, fib);
```

## AssignAdd

Adds a directory to an assign, after the ones it has.

**SYNOPSIS**

```zig
fn AssignAdd(db: *DosBase, name: [*:0]const u8, lock: *FileLock) bool
```

**SINCE**

1.0. LVO -328.

**INPUTS**

- `name` - the assign's name, without the colon.
- `lock` - the directory to add.

**RESULT**

True on success. False otherwise, with IoErr set: ERROR_OBJECT_NOT_FOUND
when there is no assign of that name, ERROR_OBJECT_WRONG_TYPE for a late
or non-binding assign, ERROR_NO_FREE_STORE when there is no memory for
the entry.

**BEHAVIOR**

The directory goes at the end of the assign's list, so a name looked up
through the assign is tried in it last. The assign must already exist;
AssignLock makes one.

**CONTEXT**

- Waits: yes. It takes the device list's lock for writing.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: a Task will do; only a process gets IoErr.

**OWNERSHIP**

On success dos keeps `lock` and unlocks it when the directory or the
assign goes; on failure it stays the caller's.

**BUGS**

None known.

**SEE ALSO**

`AssignLock`, `RemAssignList`, `GetDeviceProc`

**EXAMPLES**

```zig
const more = dos_lib.Lock("RAM:c", dos.SHARED_LOCK) orelse return false;
if (!dos_lib.AssignAdd("C", more)) dos_lib.UnLock(more);
```

## AssignLate

Makes a name a late-binding assign to a path.

**SYNOPSIS**

```zig
fn AssignLate(db: *DosBase, name: [*:0]const u8, path: [*:0]const u8) bool
```

**SINCE**

1.0. LVO -320.

**INPUTS**

- `name` - the assign's name, without the colon, 1 to 30 characters.
- `path` - the path it stands for, as Lock takes one.

**RESULT**

True on success. False otherwise, with IoErr set:
ERROR_INVALID_COMPONENT_NAME for an empty or too long name,
ERROR_OBJECT_EXISTS when a device or volume has the name,
ERROR_NO_FREE_STORE when there is no memory for the copy or the node.

**BEHAVIOR**

The path is not looked at now. The first time the assign is used,
GetDeviceProc locks the path and the assign becomes a plain assign to
that directory; until then a path that doesn't exist costs nothing. An
assign of the same name is replaced and its locks unlocked. dos keeps a
copy of `path`.

**CONTEXT**

- Waits: yes. It takes the device list's lock for writing, and unlocking
  a replaced assign's locks sends packets.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: a Task will do; only a process gets IoErr.

**OWNERSHIP**

`path` stays the caller's; dos's copy goes with the assign.

**BUGS**

None known.

**SEE ALSO**

`AssignLock`, `AssignLate`, `AssignPath`, `GetDeviceProc`

**EXAMPLES**

```zig
if (!dos_lib.AssignLate("C", "SYS:c")) return false;
```

## AssignLock

Makes a name an assign to a directory, or removes the assign.

**SYNOPSIS**

```zig
fn AssignLock(db: *DosBase, name: [*:0]const u8, lock: ?*FileLock) bool
```

**SINCE**

1.0. LVO -316.

**INPUTS**

- `name` - the assign's name, without the colon, 1 to 30 characters.
- `lock` - the directory it stands for; null removes the assign.

**RESULT**

True on success, removing an assign that isn't there included. False
otherwise, with IoErr set: ERROR_INVALID_COMPONENT_NAME for an empty or
too long name, ERROR_OBJECT_EXISTS when a device or volume has the name,
ERROR_NO_FREE_STORE when there is no memory for the node.

**BEHAVIOR**

An assign of that name is replaced: its locks are unlocked (unless one
is `lock` itself), its further directories and any late or non-binding
path freed. Without one a new node is made and added to the device list.
A null lock takes the assign off the list and frees it.

**CONTEXT**

- Waits: yes. It takes the device list's lock for writing, and unlocking
  a replaced assign's locks sends packets.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: a Task will do; only a process gets IoErr.

**OWNERSHIP**

On success dos keeps `lock` and unlocks it when the assign goes; on
failure it stays the caller's.

**BUGS**

None known.

**SEE ALSO**

`AssignLate`, `AssignPath`, `AssignAdd`, `RemAssignList`,
`GetDeviceProc`

**EXAMPLES**

```zig
const dir = dos_lib.Lock("RAM:work", dos.SHARED_LOCK) orelse return false;
if (!dos_lib.AssignLock("WORK", dir)) dos_lib.UnLock(dir);
```

## AssignPath

Makes a name a non-binding assign to a path.

**SYNOPSIS**

```zig
fn AssignPath(db: *DosBase, name: [*:0]const u8, path: [*:0]const u8) bool
```

**SINCE**

1.0. LVO -324.

**INPUTS**

- `name` - the assign's name, without the colon, 1 to 30 characters.
- `path` - the path it stands for, as Lock takes one.

**RESULT**

True on success. False otherwise, with IoErr set:
ERROR_INVALID_COMPONENT_NAME for an empty or too long name,
ERROR_OBJECT_EXISTS when a device or volume has the name,
ERROR_NO_FREE_STORE when there is no memory for the copy or the node.

**BEHAVIOR**

The path is not looked at now. Each time the assign is used,
GetDeviceProc locks the path afresh, so the assign follows whatever the
path names at that moment - another disk in the same drive, say. An
assign of the same name is replaced and its locks unlocked. dos keeps a
copy of `path`.

**CONTEXT**

- Waits: yes. It takes the device list's lock for writing, and unlocking
  a replaced assign's locks sends packets.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: a Task will do; only a process gets IoErr.

**OWNERSHIP**

`path` stays the caller's; dos's copy goes with the assign.

**BUGS**

None known.

**SEE ALSO**

`AssignLock`, `AssignLate`, `AssignPath`, `GetDeviceProc`

**EXAMPLES**

```zig
if (!dos_lib.AssignPath("C", "SYS:c")) return false;
```

## AttemptLockDosList

Locks the device list only if that can be done without waiting.

**SYNOPSIS**

```zig
fn AttemptLockDosList(db: *DosBase, flags: u32) ?*DosList
```

**SINCE**

1.0. LVO -68.

**INPUTS**

- `flags` - as for LockDosList.

**RESULT**

The list's head node, or null for bad flags or when a semaphore is held
by someone else.

**BEHAVIOR**

The semaphores are tried in LockDosList's order, shared for LDF_READ and
exclusive for LDF_WRITE. When one can't be had, those already taken are
released again, so a null result holds nothing.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: allowed.
- Process: a Task will do; this is the form for a handler, which must
  not wait for the list.

**OWNERSHIP**

On success, as LockDosList.

**BUGS**

None known.

**SEE ALSO**

`LockDosList`, `UnLockDosList`

**EXAMPLES**

```zig
const flags = dos.LDF_VOLUMES | dos.LDF_WRITE;
const list = dos_lib.AttemptLockDosList(flags) orelse return retryLater();
defer dos_lib.UnLockDosList(flags);
```

## ChangeMode

Changes a lock or an open file between shared and exclusive access.

**SYNOPSIS**

```zig
fn ChangeMode(db: *DosBase, kind: i32, object: ?*anyopaque, mode: i32) bool
```

**SINCE**

1.0. LVO -388.

**INPUTS**

- `kind` - CHANGE_LOCK for a FileLock, CHANGE_FH for a FileHandle.
- `object` - the lock or the handle.
- `mode` - for a lock SHARED_LOCK or EXCLUSIVE_LOCK; for a handle
  MODE_NEWFILE for exclusive, anything else for shared.

**RESULT**

True if the access changed; false with IoErr(): ERROR_INVALID_LOCK for a
null object or one without a handler, ERROR_OBJECT_WRONG_TYPE for an
unknown `kind`, ERROR_OBJECT_IN_USE while others hold it, or the
handler's error.

**BEHAVIOR**

The object's handler is sent ACTION_CHANGE_MODE with `kind`, the object
and `mode`; the handler decides.

**CONTEXT**

- Waits: yes, for the handler's answer to a packet.
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do; a process gets IoErr().

**OWNERSHIP**

The object stays the caller's.

**BUGS**

None known.

**SEE ALSO**

`Lock`, `Open`

**EXAMPLES**

```zig
if (!dos_lib.ChangeMode(dos.CHANGE_LOCK, lock, dos.EXCLUSIVE_LOCK)) return error.InUse;
```

## CheckSignal

Tells which of some signals have come, and clears them.

**SYNOPSIS**

```zig
fn CheckSignal(db: *DosBase, mask: u32) u32
```

**SINCE**

1.0. LVO -508.

**INPUTS**

- `mask` - the signals to look at, usually SIGBREAKF_CTRL_C ..
  SIGBREAKF_CTRL_F.

**RESULT**

The signals of `mask` that were set.

**BEHAVIOR**

The signals in `mask` are read and cleared in one step; the others are
left alone. It doesn't wait.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: allowed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**BUGS**

None known.

**SEE ALSO**

`Wait` (exec), `SetSignal` (exec)

**EXAMPLES**

```zig
if (dos_lib.CheckSignal(dos.SIGBREAKF_CTRL_C) != 0) {
    _ = dos_lib.PrintFault(dos.ERROR_BREAK, null);
    return;
}
```

## Cli

Returns the running process's CommandLineInterface, or null when it has none.

**SYNOPSIS**

```zig
fn Cli(db: *DosBase) ?*dos.CommandLineInterface
```

**SINCE**

1.0. LVO -252.

**INPUTS**

None.

**RESULT**

pr_CLI of the running process: the CLI structure of a shell or of a
program it runs, or null for a process started without one and for a
plain Task.

**BEHAVIOR**

A process has a CLI only when it was created with NP_Cli, so the
answer also tells a CLI process from any other. Nothing is allocated
or checked.

**CONTEXT**

- Waits: no.
- Interrupts: not safe; it reads the running task's Process.
- Forbid: not needed, and not taken.
- Process: a Process for an answer; a plain Task gets null.

**OWNERSHIP**

The structure belongs to the process; the caller may read and change
its fields while it runs, and never frees it.

**BUGS**

None known.

**SEE ALSO**

`GetProgramName`, `GetPrompt`, `CreateNewProc`

**EXAMPLES**

```zig
const cli = dos_lib.Cli() orelse return error.NotACli;
const fail_level = cli.fail_level;
```

## Close

Closes a file and frees its handle.

**SYNOPSIS**

```zig
fn Close(db: *DosBase, file: ?*FileHandle) bool
```

**SINCE**

1.0. LVO -196.

**INPUTS**

- `file` - the handle from `Open` or `OpenFromLock`, or null.

**RESULT**

True when the waiting bytes went out and the handler closed the file.
False for a null `file`, when the write-out failed, or when the handler
refused; `IoErr()` then holds the reason (`ERROR_NO_FREE_STORE` when no
packet could be sent). On success `IoErr()` is what it was before the
call.

**BEHAVIOR**

The buffered bytes that wait to be written are written first, and a
buffer dos allocated is freed. Then `ACTION_END` goes to the handler
with the handle. The handle is freed whatever the outcome - a failed
close cannot be retried with it.

**CONTEXT**

- Waits: yes: it sends the handler a packet and waits for the answer.
- Interrupts: no. It waits.
- Forbid: not taken, and never to be held around it: it waits.
- Process: a Task will do; the answer comes back on a port of its own.

**OWNERSHIP**

The handle is gone after the call, even when it answers false. A buffer
the caller gave `SetVBuf` stays the caller's.

**NOTES**

A handle is closed once. A second `Close` of the same pointer frees
freed memory; nothing checks for it. When no packet can be sent the
handle is freed all the same, and the handler still thinks the file is
open.

**BUGS**

None known.

**SEE ALSO**

`Open`, `Flush`, `SetVBuf`

**EXAMPLES**

```zig
if (!dos_lib.Close(fh)) return dos_lib.IoErr();
```

## CompareDates

Compares two DateStamps.

**SYNOPSIS**

```zig
fn CompareDates(_: *DosBase, date1: *const dos.DateStamp, date2: *const dos.DateStamp) i32
```

**SINCE**

1.0. LVO -180.

**INPUTS**

- `date1` - the first date.
- `date2` - the second date.

**RESULT**

Negative when `date1` is earlier, 0 when they are the same, positive
when `date2` is earlier. The result is -1, 0 or 1.

**BEHAVIOR**

Days, then minutes, then ticks.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It only reads its inputs.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`DateStamp`

**EXAMPLES**

```zig
if (dos_lib.CompareDates(&fib.date, &since) < 0) continue; // older
```

## CreateDir

Makes a directory and returns an exclusive lock on it.

**SYNOPSIS**

```zig
fn CreateDir(db: *DosBase, name: [*:0]const u8) ?*FileLock
```

**SINCE**

1.0. LVO -168.

**INPUTS**

- `name` - the new directory's name, as for Lock.

**RESULT**

An exclusive lock on the new directory, or null with IoErr()
(ERROR_OBJECT_EXISTS, ERROR_DISK_FULL, ERROR_LINE_TOO_LONG, the
handler's error).

**BEHAVIOR**

The name's handler is sent ACTION_CREATE_DIR with the directory the name
is relative to and the whole name. On a multi-directory assign, the next
directory is tried while the answer is ERROR_OBJECT_NOT_FOUND.

**CONTEXT**

- Waits: yes, for the handler's answer to a packet.
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do; a process gets IoErr().

**OWNERSHIP**

The lock is the caller's, to UnLock; the directory stays.

**BUGS**

None known.

**SEE ALSO**

`Lock`, `DeleteFile`

**EXAMPLES**

```zig
dos_lib.UnLock(dos_lib.CreateDir("RAM:T") orelse return false);
```

## CreateNewProc

Starts a new process, set up from a tag list.

**SYNOPSIS**

```zig
fn CreateNewProc(db: *DosBase, tags: ?[*]const TagItem) ?*Process
```

**SINCE**

1.0. LVO -56.

**INPUTS**

- `tags` - the process's description:
  NP_Entry (the TaskFn it runs; required unless NP_Seglist),
  NP_Seglist (a SegCode whose entry runs instead),
  NP_Name (default "New Process"), NP_StackSize (default 8192, at least
  1024), NP_Priority (default the caller's),
  NP_ConsoleTask, NP_WindowPtr,
  NP_Input, NP_Output, NP_Error (the streams; default none) with
  NP_CloseInput, NP_CloseOutput (default true) and NP_CloseError
  (default false),
  NP_CurrentDir, NP_HomeDir (taken over; default a DupLock of the
  caller's),
  NP_Arguments (copied), NP_ExitCode and NP_ExitData,
  NP_UserData (tc_UserData, there before the process first runs),
  NP_CopyVars (default true: the caller's local variables are copied),
  NP_Cli (a CLI of its own) with NP_CommandName and NP_Path.

**RESULT**

The running process, or null with IoErr(): ERROR_REQUIRED_ARG_MISSING
without an entry, ERROR_OBJECT_WRONG_TYPE for a SegCode without one,
ERROR_LINE_TOO_LONG for an NP_CommandName that doesn't fit a CLI,
ERROR_TASK_TABLE_FULL when all CLI numbers are taken,
ERROR_NO_FREE_STORE, or the error of a DupLock.

**BEHAVIOR**

The Process, its name, its CLI and its stack are one block, which exec
frees when the process is gone. From a calling process it takes
pr_ConsoleTask, pr_FileSystemTask and a pr_WindowPtr of 0 or -1. With
NP_Cli the process gets a CLI with the caller's prompt (or
CLI_DEFAULT_PROMPT), command name, directory name and fail level, its
stack size, the command path of NP_Path or of the caller's CLI (each
node's lock copied), and the lowest free CLI number in pr_TaskNum -
which is also put after its name, as " [n]", so that two shells can be
told apart in a list of tasks.
When the process's code returns, its exit hook (NP_ExitCode) is called
with NP_ExitData, then its CLI number, local variables, streams (as the
close flags say), directories, command path and argument copy go.
If a step after the block was made fails, what dos made is undone and
the block freed.

**CONTEXT**

- Waits: yes: DupLock sends packets, and the CLI table is a semaphore.
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do; it then passes nothing on and there is
  nothing to copy.

**OWNERSHIP**

The process owns what the tags hand it - the streams it will close, the
directories, the exit hook - from the moment the call succeeds. On
failure the caller keeps them.

**BUGS**

If duplicating the caller's home directory fails after NP_CurrentDir was
given, the given current directory is unlocked although the caller keeps
it.

**SEE ALSO**

`SystemTagList`, `RunCommand`, `FindCliProc`

**EXAMPLES**

```zig
const tags = [_]TagItem{
    .{ .tag = dos.NP_Entry, .data = @intFromPtr(&worker) },
    .{ .tag = dos.NP_Name, .data = @intFromPtr("worker") },
    .{},
};
_ = dos_lib.CreateNewProc(&tags) orelse return dos_lib.IoErr();
```

## CurrentDir

Makes a lock the calling process's current directory and returns the one before.

**SYNOPSIS**

```zig
fn CurrentDir(db: *DosBase, lock: ?*FileLock) ?*FileLock
```

**SINCE**

1.0. LVO -164.

**INPUTS**

- `lock` - the new current directory; null means the root of the
  process's file system.

**RESULT**

The previous current directory (possibly null). Null from a plain task,
which has none.

**BEHAVIOR**

pr_CurrentDir is swapped; no packet is sent. The lock is neither
checked, copied nor unlocked.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: allowed.
- Process: needed; a plain task changes nothing and gets null.

**OWNERSHIP**

The process holds `lock` from now on without owning it: the caller still
gives it back, once it is no longer the current directory. The returned
lock goes back to the caller, the same way.

**BUGS**

None known.

**SEE ALSO**

`Lock`, `UnLock`, `GetCurrentDirName`

**EXAMPLES**

```zig
const old = dos_lib.CurrentDir(dir);
defer _ = dos_lib.CurrentDir(old);
```

## DateStamp

Reads the time now into a DateStamp.

**SYNOPSIS**

```zig
fn DateStamp(db: *DosBase, date: *dos.DateStamp) *dos.DateStamp
```

**SINCE**

1.0. LVO -176.

**INPUTS**

- `date` - where the time goes.

**RESULT**

`date`, filled in: days since 1 Jan 1978, minutes past midnight, ticks
of 1/50 s past the minute.

**BEHAVIOR**

The time is timer.device's GetSysTime, on the request dos keeps open,
so the call neither waits nor allocates. Without timer.device every
field is 0.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. `date` is the caller's.

**BUGS**

None known.

**SEE ALSO**

`CompareDates`, `DateToStr`, `Delay`

**EXAMPLES**

```zig
var now: dos.DateStamp = .{};
_ = dos_lib.DateStamp(&now);
```

## DateToStr

Writes a DateStamp out as text.

**SYNOPSIS**

```zig
fn DateToStr(db: *DosBase, datetime: *dos.DateTime) bool
```

**SINCE**

1.0. LVO -184.

**INPUTS**

- `datetime` - dat_Stamp the date to write, dat_Format and dat_Flags
  how, and the three string buffers (dat_StrDay, dat_StrDate,
  dat_StrTime) it is written to. A null buffer is skipped; each other
  one holds LEN_DATSTRING bytes.

**RESULT**

True with the strings written; false, and nothing written, when the
stamp is no date (a negative field, a minute past the day, a tick past
the minute).

**BEHAVIOR**

dat_StrDay gets the weekday's name. dat_StrTime gets "hh:mm:ss".
dat_StrDate gets the date in dat_Format (an unknown one is FORMAT_DOS):
"dd-Mmm-yyyy", "yyyy-mm-dd", "mm-dd-yyyy" or "dd-mm-yyyy". With
FORMAT_DOS and DTF_SUBST a date near today is a word instead: "Today",
"Yesterday", "Tomorrow", "Future" for anything later, and the weekday's
name for the week before yesterday.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The buffers are the caller's.

**NOTES**

Without timer.device today is day 0, so DTF_SUBST calls every date
from 1978 on "Future".

**BUGS**

A year past 9999 is written with only its last four digits.

**SEE ALSO**

`StrToDate`, `DateStamp`

**EXAMPLES**

```zig
var date: [dos.LEN_DATSTRING]u8 = undefined;
var dt: dos.DateTime = .{ .stamp = fib.date, .format = dos.FORMAT_INT, .str_date = @ptrCast(&date) };
if (dos_lib.DateToStr(&dt)) {
    // date holds "2026-09-21"
}
```

## Delay

Waits a number of fiftieths of a second.

**SYNOPSIS**

```zig
fn Delay(db: *DosBase, ticks: u32) void
```

**SINCE**

1.0. LVO -512.

**INPUTS**

- `ticks` - how long, in 1/50 s.

**RESULT**

Nothing; IoErr says whether it waited: 0 when it did,
ERROR_OBJECT_NOT_FOUND without timer.device, ERROR_NO_FREE_STORE when
no message port could be made (then it returns at once).

**BEHAVIOR**

A copy of dos's timer request, with a reply port of the caller's own,
is sent with TR_ADDREQUEST and waited for, so several tasks can wait at
once. 0 returns at once.

**CONTEXT**

- Waits: yes.
- Interrupts: no.
- Forbid: never under Forbid.
- Process: a Task will do.

**OWNERSHIP**

A message port is made and freed within the call.

**BUGS**

None known.

**SEE ALSO**

`DateStamp`, `WaitForChar`

**EXAMPLES**

```zig
dos_lib.Delay(50); // a second
```

## DeleteFile

Deletes a file or an empty directory.

**SYNOPSIS**

```zig
fn DeleteFile(db: *DosBase, name: [*:0]const u8) bool
```

**SINCE**

1.0. LVO -172.

**INPUTS**

- `name` - the object, as for Lock.

**RESULT**

True if it is gone; false with IoErr() (ERROR_OBJECT_NOT_FOUND,
ERROR_DIRECTORY_NOT_EMPTY, ERROR_OBJECT_IN_USE, ERROR_DELETE_PROTECTED,
the handler's error).

**BEHAVIOR**

The name's handler is sent ACTION_DELETE_OBJECT with the directory the
name is relative to and the whole name, along a multi-directory assign
while the object isn't found.

**CONTEXT**

- Waits: yes, for the handler's answer to a packet.
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do; a process gets IoErr().

**OWNERSHIP**

Nothing changes hands.

**BUGS**

None known.

**SEE ALSO**

`CreateDir`, `Rename`

**EXAMPLES**

```zig
if (!dos_lib.DeleteFile("T:work")) _ = dos_lib.PrintFault(dos_lib.IoErr(), "Delete");
```

## DeleteVar

Deletes a local variable or alias, or a global variable.

**SYNOPSIS**

```zig
fn DeleteVar(db: *DosBase, name: [*:0]const u8, flags: u32) bool
```

**SINCE**

1.0. LVO -500.

**INPUTS**

- `name` - the variable's name.
- `flags` - the type in the low byte (LV_VAR or LV_ALIAS), with
  GVF_GLOBAL_ONLY, GVF_LOCAL_ONLY and GVF_SAVE_VAR, as for SetVar.

**RESULT**

True when the variable was deleted. False otherwise, with IoErr set, as
SetVar answers.

**BEHAVIOR**

The same as SetVar with a null buffer: the local variable if there is
one, else the global file ENV:name (unless GVF_LOCAL_ONLY), and
ENVARC:name as well with GVF_SAVE_VAR.

**CONTEXT**

- Waits: yes, for a global variable (file system packets); not for a
  local one.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: a Task will do for a global variable; only a process has
  local ones and gets IoErr.

**OWNERSHIP**

Nothing is kept.

**BUGS**

None known.

**SEE ALSO**

`SetVar`, `GetVar`

**EXAMPLES**

```zig
_ = dos_lib.DeleteVar("Editor", dos.LV_VAR | dos.GVF_GLOBAL_ONLY);
```

## DoPkt

Sends a packet to a handler and waits for it to come back.

**SYNOPSIS**

```zig
fn DoPkt(db: *DosBase, port: *MsgPort, action: i32, arg1: isize, arg2: isize, arg3: isize, arg4: isize, arg5: isize) isize
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `port` - the handler's port.
- `action` - the packet type, an ACTION_* value.
- `arg1`..`arg5` - dp_Arg1 to dp_Arg5, as the action defines them.

**RESULT**

dp_Res1 as the handler set it; 0 when a plain task can't get a port for
the reply.

**BEHAVIOR**

The packet is built on the caller's stack, sent, and waited for. A
process waits at its msg_port (through pr_PktWait if it has one) and
gets dp_Res2 as its IoErr. A plain task gets a port of its own for the
call and freed after it. Packets that reach the reply port before this
one are kept and put back on it afterwards, in the order they came, so
nothing else the caller has in flight is lost.

**CONTEXT**

- Waits: yes, until the handler replies.
- Interrupts: no.
- Forbid: never under Forbid.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated for a process; a task's reply port is made and
freed within the call. What the arguments point to stays the caller's.

**NOTES**

A plain task has no IoErr, so dp_Res2 reaches only a process. A task
that needs it sends the packet itself (`AllocDosObject(DOS_STDPKT)`,
`SendPkt` to a port of its own) and reads it off the packet.

**BUGS**

None known.

**SEE ALSO**

`SendPkt`, `WaitPkt`, `ReplyPkt`, `IoErr`

**EXAMPLES**

```zig
const ok = dos_lib.DoPkt(port, @intFromEnum(dos.ActionCode.is_filesystem), 0, 0, 0, 0, 0);
if (ok == 0) return dos_lib.IoErr();
```

## DupLock

Makes another shared lock on the object a lock is on.

**SYNOPSIS**

```zig
fn DupLock(db: *DosBase, lock: ?*FileLock) ?*FileLock
```

**SINCE**

1.0. LVO -152.

**INPUTS**

- `lock` - the lock to copy; null gives null.

**RESULT**

The new lock, or null with IoErr() (ERROR_OBJECT_IN_USE for an exclusive
lock, or the handler's error). DupLock(null) is null without a packet,
and IoErr() is then not set.

**BEHAVIOR**

The lock's handler is sent ACTION_COPY_DIR with the lock.

**CONTEXT**

- Waits: yes, for the handler's answer to a packet.
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do; a process gets IoErr().

**OWNERSHIP**

The new lock is the caller's, given back with UnLock; the original stays
the caller's too.

**BUGS**

None known.

**SEE ALSO**

`Lock`, `UnLock`, `DupLockFromFH`

**EXAMPLES**

```zig
const copy = dos_lib.DupLock(proc.current_dir) orelse return false;
```

## DupLockFromFH

Gives a shared lock on an open file.

**SYNOPSIS**

```zig
fn DupLockFromFH(db: *DosBase, file: ?*FileHandle) ?*FileLock
```

**SINCE**

1.0. LVO -372.

**INPUTS**

- `file` - the handle.

**RESULT**

A shared lock on the file, or null with `IoErr()` set
(`ERROR_INVALID_LOCK` for a null handle or one without a handler,
`ERROR_NO_FREE_STORE`, or the handler's code).

**BEHAVIOR**

`ACTION_COPY_DIR_FH` with the handle to its handler, which makes the
lock.

**CONTEXT**

- Waits: yes: it sends the handler a packet and waits for the answer.
- Interrupts: no. It waits.
- Forbid: not taken, and never to be held around it: it waits.
- Process: a Task will do; the answer comes back on a port of its own.

**OWNERSHIP**

The lock is the caller's, for `UnLock`. The handle stays open.

**BUGS**

None known.

**SEE ALSO**

`ParentOfFH`, `OpenFromLock`, `UnLock`

**EXAMPLES**

```zig
const l = dos_lib.DupLockFromFH(fh) orelse return dos_lib.IoErr();
defer dos_lib.UnLock(l);
```

## ErrorOutput

Returns the running process's error stream (pr_CES).

**SYNOPSIS**

```zig
fn ErrorOutput(db: *DosBase) ?*FileHandle
```

**SINCE**

1.0. LVO -260.

**INPUTS**

None.

**RESULT**

The error stream, or null when none has been set (or for a plain
Task). A caller with no error stream writes its errors to Output().

**BEHAVIOR**

Reads pr_CES of the running process. Nothing is checked or changed.

**CONTEXT**

- Waits: no.
- Interrupts: not safe; it reads the running task's Process.
- Forbid: not needed, and not taken.
- Process: a Process for an answer; from a plain Task it does
  nothing and answers null.

**OWNERSHIP**

The handle belongs to whoever set it with SelectError; the caller
doesn't Close it.

**BUGS**

None known.

**SEE ALSO**

`SelectError`, `Output`, `PrintFault`

**EXAMPLES**

```zig
const errors = dos_lib.ErrorOutput() orelse dos_lib.Output();
```

## ExAll

Reads entries of a directory into a buffer, as many as fit.

**SYNOPSIS**

```zig
fn ExAll(db: *DosBase, lock: ?*FileLock, buffer: [*]u8, size: isize, data_type: i32, control: *dos.ExAllControl) bool
```

**SINCE**

1.0. LVO -244.

**INPUTS**

- `lock` - the directory; null is the current file system's root.
- `buffer` - where the ExAllData records go, linked through `next`.
- `size` - the buffer's size in bytes.
- `data_type` - which fields each record has, ED_NAME .. ED_OWNER.
- `control` - from AllocDosObject(DOS_EXALLCONTROL), last_key 0 at the
  start; match_string and match_func choose entries.

**RESULT**

True: records are in the buffer (control.entries of them, which may be
0) and more are to come, so call again. False: the listing is over,
with IoErr ERROR_NO_MORE_ENTRIES, or failed. When dos does the listing,
a buffer that cannot hold even one record ends it with
ERROR_BUFFER_OVERFLOW. A `data_type` outside
ED_NAME .. ED_OWNER fails with ERROR_BAD_NUMBER before the handler is
asked; no handler for a null lock is ERROR_DEVICE_NOT_MOUNTED.

**BEHAVIOR**

ACTION_EXAMINE_ALL to the handler. A handler that doesn't know it gets
the listing done for it with EXAMINE_OBJECT and EXAMINE_NEXT, which
comes out the same: records aligned for their pointers, the strings
after the fields, match_string (a pattern from ParsePatternNoCase)
tried before match_func, and an entry either leaves out taking no room.

**CONTEXT**

- Waits: yes, for the handler.
- Interrupts: no.
- Forbid: never under Forbid.
- Process: a Process, for IoErr.

**OWNERSHIP**

The buffer is the caller's; a listing done for the handler holds a
FileInfoBlock of dos's until it ends or `ExAllEnd` stops it. Stop a
listing that isn't run to its end with `ExAllEnd`.

**BUGS**

None known.

**SEE ALSO**

`ExAllEnd`, `Examine`, `ExNext`, `AllocDosObject`

**EXAMPLES**

```zig
const control: *dos.ExAllControl = @ptrCast(@alignCast(dos_lib.AllocDosObject(dos.DOS_EXALLCONTROL, null).?));
defer dos_lib.FreeDosObject(dos.DOS_EXALLCONTROL, control);
var buffer: [1024]u8 align(8) = undefined;
while (true) {
    const more = dos_lib.ExAll(dir, &buffer, buffer.len, dos.ED_SIZE, control);
    var rec: ?*dos.ExAllData = if (control.entries > 0) @ptrCast(&buffer) else null;
    while (rec) |r| : (rec = r.next) {
        // r.name, r.size
    }
    if (!more) break;
}
```

## ExAllEnd

Stops an ExAll listing before its end.

**SYNOPSIS**

```zig
fn ExAllEnd(db: *DosBase, lock: ?*FileLock, buffer: [*]u8, size: isize, data_type: i32, control: *dos.ExAllControl) void
```

**SINCE**

1.0. LVO -248.

**INPUTS**

- `lock` - the directory, as given to `ExAll`.
- `buffer` - the buffer, as given to `ExAll`.
- `size` - its size.
- `data_type` - the level, as given to `ExAll`.
- `control` - the listing's control.

**RESULT**

Nothing. IoErr is as it was before the call.

**BEHAVIOR**

ACTION_EXAMINE_ALL_END to the handler. One that doesn't know it has
its listing run to the end instead, with a MatchFunc that takes nothing
so the buffer isn't written; the caller's hook is put back after. A
listing dos was doing for the handler has its FileInfoBlock freed and
last_key set to 0.

**CONTEXT**

- Waits: yes, for the handler.
- Interrupts: no.
- Forbid: never under Forbid.
- Process: a Process.

**OWNERSHIP**

Whatever the listing held is freed. The control is the caller's, ready
for a new listing.

**BUGS**

None known.

**SEE ALSO**

`ExAll`

**EXAMPLES**

```zig
if (found) dos_lib.ExAllEnd(dir, &buffer, buffer.len, dos.ED_NAME, control);
```

## ExNext

Fills in a FileInfoBlock with the next entry of a directory.

**SYNOPSIS**

```zig
fn ExNext(db: *DosBase, lock: ?*FileLock, fib: *dos.FileInfoBlock) bool
```

**SINCE**

1.0. LVO -236.

**INPUTS**

- `lock` - the directory, as given to `Examine`. Null fails with
  ERROR_INVALID_LOCK.
- `fib` - the block `Examine` filled in, and each ExNext after it; the
  handler keeps its place there.

**RESULT**

True with the next entry in `fib`; false at the end, with IoErr
ERROR_NO_MORE_ENTRIES, or on an error.

**BEHAVIOR**

ACTION_EXAMINE_NEXT to the lock's handler, the owner fields zeroed
first.

**CONTEXT**

- Waits: yes, for the handler.
- Interrupts: no.
- Forbid: never under Forbid.
- Process: a Process, for IoErr.

**OWNERSHIP**

Nothing is allocated. The block and the lock stay the caller's.

**BUGS**

None known.

**SEE ALSO**

`Examine`, `ExAll`

**EXAMPLES**

```zig
if (!dos_lib.Examine(dir, fib)) return false;
while (dos_lib.ExNext(dir, fib)) {
    // fib.file_name is the entry
}
if (dos_lib.IoErr() != dos.ERROR_NO_MORE_ENTRIES) return false;
```

## Examine

Fills in a FileInfoBlock about the object a lock is on.

**SYNOPSIS**

```zig
fn Examine(db: *DosBase, lock: ?*FileLock, fib: *dos.FileInfoBlock) bool
```

**SINCE**

1.0. LVO -232.

**INPUTS**

- `lock` - the object; null is the root of the current file system.
- `fib` - the block to fill in, from AllocDosObject(DOS_FIB).

**RESULT**

True with `fib` filled in; false with IoErr set.

**BEHAVIOR**

ACTION_EXAMINE_OBJECT to the lock's handler. The owner fields are
zeroed first. A directory's block is also the place to start `ExNext`
from: pass the same lock and block to it.

**CONTEXT**

- Waits: yes, for the handler.
- Interrupts: no.
- Forbid: never under Forbid.
- Process: a Process, for IoErr and the current directory.

**OWNERSHIP**

Nothing is allocated. The block and the lock stay the caller's.

**BUGS**

None known.

**SEE ALSO**

`ExNext`, `ExamineFH`, `ExAll`, `AllocDosObject`

**EXAMPLES**

```zig
const fib: *dos.FileInfoBlock = @ptrCast(@alignCast(dos_lib.AllocDosObject(dos.DOS_FIB, null) orelse return false));
defer dos_lib.FreeDosObject(dos.DOS_FIB, fib);
if (!dos_lib.Examine(lock, fib)) return false;
```

## ExamineFH

Fills in a FileInfoBlock about an open file.

**SYNOPSIS**

```zig
fn ExamineFH(db: *DosBase, file: ?*FileHandle, fib: *dos.FileInfoBlock) bool
```

**SINCE**

1.0. LVO -240.

**INPUTS**

- `file` - the open file; null, or one with no handler, fails with
  ERROR_INVALID_LOCK.
- `fib` - the block to fill in.

**RESULT**

True with `fib` filled in; false with IoErr set.

**BEHAVIOR**

The file's buffer is written out first, so the size the handler gives
counts what was written with FWrite and FPutC. Then ACTION_EXAMINE_FH,
the owner fields zeroed before.

**CONTEXT**

- Waits: yes, for the handler.
- Interrupts: no.
- Forbid: never under Forbid.
- Process: a Process, for IoErr.

**OWNERSHIP**

Nothing is allocated. The block and the handle stay the caller's.

**BUGS**

None known.

**SEE ALSO**

`Examine`, `Flush`

**EXAMPLES**

```zig
if (dos_lib.ExamineFH(fh, fib)) {
    const size = fib.size;
    _ = size;
}
```

## Execute

Runs a command in a new shell, which then reads more commands from a stream.

**SYNOPSIS**

```zig
fn Execute(db: *DosBase, command: [*:0]const u8, input: ?*FileHandle, output: ?*FileHandle) bool
```

**SINCE**

1.0. LVO -540.

**INPUTS**

- `command` - the command line to run first; "" runs nothing first.
- `input` - where the shell reads its commands from after `command`;
  null is NIL:, so the shell ends after the command.
- `output` - where the shell writes; null is the caller's Output().

**RESULT**

True when the shell ran, false with IoErr set when it could not start
(as SystemTagList).

**BEHAVIOR**

"BootShell" is started in execute mode at priority 0 and waited for. The
command line is its first input, then `input`.

**CONTEXT**

- Waits: yes. It sends packets, and a synchronous start waits for the
  shell to end.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: a Task will do; a process's CLI and current directory are
  passed on, and only a process gets IoErr.

**OWNERSHIP**

The streams stay the caller's.

**BUGS**

None known.

**SEE ALSO**

`SystemTagList`

**EXAMPLES**

```zig
_ = dos_lib.Execute("echo hello", null, null);
```

## FGetC

Reads the next byte of a file.

**SYNOPSIS**

```zig
fn FGetC(db: *DosBase, file: ?*FileHandle) i32
```

**SINCE**

1.0. LVO -408.

**INPUTS**

- `file` - the handle.

**RESULT**

The byte, 0 to 255; -1 at the end of the file (a pushed-back end
included), with `IoErr()` 0, or on
an error, with `IoErr()` the reason (`ERROR_INVALID_LOCK` for a null
handle, `ERROR_NO_FREE_STORE` when no buffer can be had, the handler's
code).

**BEHAVIOR**

A character pushed back with `UnGetC` comes first, the last pushed
first. Then the buffer; when it is empty it is refilled with one
`ACTION_READ` of the buffer's size (one byte with `BUF_NONE`). Bytes
waiting to be written are written out before reading. The end is not
remembered: after -1 the next call asks the handler again, so a console
can be read on after an end of input.

**CONTEXT**

- Waits: only when the buffer has to go to or come from the handler;
  then it sends a packet and waits for the answer.
- Interrupts: no. It may wait.
- Forbid: not taken, and never to be held around it: it may wait.
- Process: a Task will do. One handle is one caller's: two tasks sharing
  a handle take turns themselves.

**OWNERSHIP**

The first buffered call on a handle allocates its buffer; `Close` frees
it.

**BUGS**

None known.

**SEE ALSO**

`UnGetC`, `FGets`, `FRead`, `Read`

**EXAMPLES**

```zig
while (true) {
    const c = dos_lib.FGetC(fh);
    if (c < 0) break;
    _ = dos_lib.FPutC(out, c);
}
```

## FGets

Reads a line from a file.

**SYNOPSIS**

```zig
fn FGets(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, size: u32) ?[*]u8
```

**SINCE**

1.0. LVO -428.

**INPUTS**

- `file` - the handle.
- `buffer` - where the line goes.
- `size` - the buffer's size, the NUL included.

**RESULT**

`buffer`, holding at most `size - 1` bytes, the newline kept when it
fitted, and a NUL. Null when `size` is 0, or when the end or an error
comes before any byte (`IoErr()` 0 at the end, the reason on an error).

**BEHAVIOR**

Bytes come from `FGetC` until a '\n', the end, or a full buffer. A line
longer than the buffer comes in pieces: the next call reads on where
this one stopped.

**CONTEXT**

- Waits: only when the buffer has to go to or come from the handler;
  then it sends a packet and waits for the answer.
- Interrupts: no. It may wait.
- Forbid: not taken, and never to be held around it: it may wait.
- Process: a Task will do. One handle is one caller's: two tasks sharing
  a handle take turns themselves.

**OWNERSHIP**

Nothing is allocated. The line is in the caller's buffer.

**BUGS**

None known.

**SEE ALSO**

`FGetC`, `FPuts`, `ReadItem`

**EXAMPLES**

```zig
var line: [256]u8 = undefined;
while (dos_lib.FGets(fh, &line, line.len)) |text| {
    _ = dos_lib.PutStr(@ptrCast(text));
}
```

## FPutC

Writes one byte to a file.

**SYNOPSIS**

```zig
fn FPutC(db: *DosBase, file: ?*FileHandle, character: i32) i32
```

**SINCE**

1.0. LVO -416.

**INPUTS**

- `file` - the handle.
- `character` - the byte, in the low 8 bits.

**RESULT**

The byte written (0 to 255), or -1 with `IoErr()` set
(`ERROR_INVALID_LOCK` for a null handle, `ERROR_NO_FREE_STORE`,
`ERROR_DISK_FULL`, the handler's code).

**BEHAVIOR**

The byte goes into the buffer, which is written out when it is full, at
once with `BUF_NONE`, and at '\n' or '\r' when the handle is line
buffered and a console. A handle that was reading turns around first:
read-ahead is given back by seeking over it - except on a console, where
the byte goes straight out and what was read ahead stays to be read.

**CONTEXT**

- Waits: only when the buffer has to go to or come from the handler;
  then it sends a packet and waits for the answer.
- Interrupts: no. It may wait.
- Forbid: not taken, and never to be held around it: it may wait.
- Process: a Task will do. One handle is one caller's: two tasks sharing
  a handle take turns themselves.

**OWNERSHIP**

The first buffered call on a handle allocates its buffer; `Close` frees
it.

**BUGS**

None known.

**SEE ALSO**

`FPuts`, `FWrite`, `Flush`, `SetVBuf`

**EXAMPLES**

```zig
if (dos_lib.FPutC(fh, '\n') < 0) return dos_lib.IoErr();
```

## FPuts

Writes a string to a file.

**SYNOPSIS**

```zig
fn FPuts(db: *DosBase, file: ?*FileHandle, string: [*:0]const u8) i32
```

**SINCE**

1.0. LVO -432.

**INPUTS**

- `file` - the handle.
- `string` - the string; its NUL is not written.

**RESULT**

0, or -1 with `IoErr()` set as for `FWrite`.

**BEHAVIOR**

`FWrite` of the string's length.

**CONTEXT**

- Waits: only when the buffer has to go to or come from the handler;
  then it sends a packet and waits for the answer.
- Interrupts: no. It may wait.
- Forbid: not taken, and never to be held around it: it may wait.
- Process: a Task will do. One handle is one caller's: two tasks sharing
  a handle take turns themselves.

**OWNERSHIP**

Nothing is allocated. The string stays the caller's.

**BUGS**

None known.

**SEE ALSO**

`FWrite`, `PutStr`, `FGets`

**EXAMPLES**

```zig
if (dos_lib.FPuts(fh, "done\n") < 0) return dos_lib.IoErr();
```

## FRead

Reads up to `length` bytes from a file through its buffer.

**SYNOPSIS**

```zig
fn FRead(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, length: isize) isize
```

**SINCE**

1.0. LVO -420.

**INPUTS**

- `file` - the handle.
- `buffer` - where the bytes go; `length` bytes of room.
- `length` - how many are wanted. 0 or less reads nothing.

**RESULT**

The number read, which is less than `length` only at the end of the file
or from a console; 0 at the end (and for a `length` of 0 or less); -1 on
an error before any byte, with `IoErr()` set (`ERROR_INVALID_LOCK`,
`ERROR_NO_FREE_STORE`, the handler's code). An error after some bytes
answers the bytes, and `IoErr()` keeps the error.

**BEHAVIOR**

Pushed-back characters come first, then the buffer. The rest is read in
a loop: a part of the buffer's size or more goes straight into `buffer`,
a smaller one through a refill. It stops at the end of the file, and on
a console as soon as it has anything, so a line typed is not waited
past. At the end `IoErr()` is 0.

**CONTEXT**

- Waits: only when the buffer has to go to or come from the handler;
  then it sends a packet and waits for the answer.
- Interrupts: no. It may wait.
- Forbid: not taken, and never to be held around it: it may wait.
- Process: a Task will do. One handle is one caller's: two tasks sharing
  a handle take turns themselves.

**OWNERSHIP**

The first buffered call on a handle allocates its buffer; `Close` frees
it.

**BUGS**

None known.

**SEE ALSO**

`FWrite`, `Read`, `FGetC`

**EXAMPLES**

```zig
var buf: [512]u8 = undefined;
const n = dos_lib.FRead(fh, &buf, buf.len);
if (n < 0) return dos_lib.IoErr();
```

## FWrite

Writes `length` bytes to a file through its buffer.

**SYNOPSIS**

```zig
fn FWrite(db: *DosBase, file: ?*FileHandle, buffer: [*]const u8, length: isize) isize
```

**SINCE**

1.0. LVO -424.

**INPUTS**

- `file` - the handle.
- `buffer` - the bytes.
- `length` - how many. 0 or less writes nothing.

**RESULT**

`length` (0 for 0 or less), or -1 with `IoErr()` set
(`ERROR_INVALID_LOCK`, `ERROR_NO_FREE_STORE`, `ERROR_DISK_FULL`, the
handler's code).

**BEHAVIOR**

Bytes are copied into the buffer, which is written out whenever it
fills, and at the end when the bytes held a '\n' or '\r' and the handle
is a line-buffered console. With `BUF_NONE`, or `length` the buffer's
size or more, the buffer is written out and the bytes go straight to the
handler. A reading handle turns around first as for `FPutC`; on a
console the bytes go straight out.

**CONTEXT**

- Waits: only when the buffer has to go to or come from the handler;
  then it sends a packet and waits for the answer.
- Interrupts: no. It may wait.
- Forbid: not taken, and never to be held around it: it may wait.
- Process: a Task will do. One handle is one caller's: two tasks sharing
  a handle take turns themselves.

**OWNERSHIP**

The first buffered call on a handle allocates its buffer; `Close` frees
it. The bytes stay the caller's.

**NOTES**

When the bytes go straight to the handler the answer is the handler's
count, which can be less than `length`.

**BUGS**

None known.

**SEE ALSO**

`FRead`, `Write`, `FPuts`, `Flush`

**EXAMPLES**

```zig
const line = "a line\n";
if (dos_lib.FWrite(fh, line, line.len) < 0) return dos_lib.IoErr();
```

## Fault

Puts the text for an error code into a buffer.

**SYNOPSIS**

```zig
fn Fault(db: *DosBase, code: i32, header: ?[*:0]const u8, buffer: [*]u8, len: i32) i32
```

**SINCE**

1.0. LVO -484.

**INPUTS**

- `code` - the error code: an IoErr code, or one of the shell's
  (negative).
- `header` - put before the text with ": " after it; null for none.
- `buffer` - where the text goes.
- `len` - the buffer's size in bytes, the NUL included.

**RESULT**

The length of the text put in the buffer, the NUL not counted. 0 for a
code of 0 or a `len` of 0 or less.

**BEHAVIOR**

The text is "header: text", or the text alone for a null header; a code
without a text gives "Error <code>". The whole is cut to `len - 1` bytes
and ended with a NUL; nothing is written for a code of 0 but the NUL.
IoErr is not touched.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It only reads its inputs and writes the caller's
  buffer.
- Forbid: not needed, and not taken.
- Process: a Task will do.

**OWNERSHIP**

The buffer is the caller's.

**BUGS**

None known.

**SEE ALSO**

`PrintFault`, `IoErr`

**EXAMPLES**

```zig
var why: [80]u8 = undefined;
_ = dos_lib.Fault(dos_lib.IoErr(), "copy", &why, why.len);
```

## FilePart

Finds the last component of a path.

**SYNOPSIS**

```zig
fn FilePart(db: *DosBase, name: [*:0]const u8) [*:0]const u8
```

**SINCE**

1.0. LVO -108.

**INPUTS**

- `name` - the path.

**RESULT**

A pointer into `name` where its last component starts:
"xxx:yyy/zzz/qqq" gives "qqq", "xxx:yyy" gives "yyy", a name without
a colon or a slash gives itself. A path that ends in '/' gives "".

**BEHAVIOR**

`PathPart`, past the slash it stops at.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It only reads `name`.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The result points into `name`.

**BUGS**

None known.

**SEE ALSO**

`PathPart`, `AddPart`

**EXAMPLES**

```zig
const leaf = dos_lib.FilePart("SYS:c/dir"); // "dir"
```

## FindArg

Finds which item of a template a keyword names.

**SYNOPSIS**

```zig
fn FindArg(db: *DosBase, template: [*:0]const u8, keyword: [*:0]const u8) i32
```

**SINCE**

1.0. LVO -468.

**INPUTS**

- `template` - a ReadArgs template.
- `keyword` - the word to look for.

**RESULT**

The item's number, from 0; -1 when no item has that name.

**BEHAVIOR**

Every alias of every item counts ("Q=QUIET/S" is found by "q" and by
"quiet"), case ignored; the modifiers after '/' are not part of a name.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`ReadArgs`, `ReadItem`

**EXAMPLES**

```zig
const n = dos_lib.FindArg("FROM/M/A,TO/A,Q=QUIET/S", "quiet"); // 2
```

## FindCliProc

Returns the CLI process with a given number.

**SYNOPSIS**

```zig
fn FindCliProc(db: *DosBase, num: u32) ?*Process
```

**SINCE**

1.0. LVO -528.

**INPUTS**

- `num` - the CLI number, pr_TaskNum; 1 is the first.

**RESULT**

The process, or null if the number is free or out of range.

**BEHAVIOR**

The CLI table is read under its lock.

**CONTEXT**

- Waits: yes, for the CLI table's semaphore.
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do.

**OWNERSHIP**

The process is not the caller's. It can end at any time after the call;
a caller that looks into it holds Forbid meanwhile.

**BUGS**

None known.

**SEE ALSO**

`MaxCli`

**EXAMPLES**

```zig
if (dos_lib.FindCliProc(1)) |shell| _ = shell;
```

## FindDosEntry

Finds the first node of some types, and optionally of a name, from a node on.

**SYNOPSIS**

```zig
fn FindDosEntry(db: *DosBase, dlist: *DosList, name: ?[*:0]const u8, flags: u32) ?*DosList
```

**SINCE**

1.0. LVO -80.

**INPUTS**

- `dlist` - where to start: the head LockDosList gave, or a node found
  before (it is itself looked at).
- `name` - the name, without the colon, in any case; null for any name.
- `flags` - the types: LDF_DEVICES, LDF_VOLUMES, LDF_ASSIGNS; other bits
  are ignored.

**RESULT**

The node, or null if none from `dlist` on matches.

**BEHAVIOR**

Directory, late and non-binding assigns all answer to LDF_ASSIGNS. The
head node and private nodes are never found. Names are compared without
case.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: allowed.
- Process: a Task will do. The caller holds the list (LockDosList).

**OWNERSHIP**

The node stays the list's; it is valid while the list is locked.

**BUGS**

None known.

**SEE ALSO**

`LockDosList`, `NextDosEntry`

**EXAMPLES**

```zig
const list = dos_lib.LockDosList(dos.LDF_DEVICES | dos.LDF_READ).?;
const found = dos_lib.FindDosEntry(list, "DH0", dos.LDF_DEVICES) != null;
dos_lib.UnLockDosList(dos.LDF_DEVICES | dos.LDF_READ);
```

## FindSegment

Finds the next resident segment of a name.

**SYNOPSIS**

```zig
fn FindSegment(db: *DosBase, name: [*:0]const u8, start: ?*Segment, system: bool) ?*Segment
```

**SINCE**

1.0. LVO -128.

**INPUTS**

- `name` - the name, in any case.
- `start` - the segment to search after; null to search from the
  first.
- `system` - true for system segments (seg_UC below 0), false for
  user ones (0 and up).

**RESULT**

The segment, or null with ERROR_OBJECT_NOT_FOUND when there is none
after `start`.

**BEHAVIOR**

Walks the list from after `start`, comparing names without regard to
case, and returns the first of the wanted kind. Passing the last
answer as `start` finds the next of the same name.

**CONTEXT**

- Waits: no.
- Interrupts: not safe.
- Forbid: not needed; the list must be locked with LockSegmentList.
- Process: a Task will do.

**OWNERSHIP**

The segment stays dos's. A caller that keeps a user segment after
UnLockSegmentList raises its seg_UC while the list is still locked,
and lowers it the same way when done.

**BUGS**

None known.

**SEE ALSO**

`LockSegmentList`, `AddSegment`, `RemSegment`

**EXAMPLES**

```zig
_ = dos_lib.LockSegmentList(true);
defer dos_lib.UnLockSegmentList();
const seg = dos_lib.FindSegment("dir", null, false) orelse return null;
```

## FindVar

Finds a process's local variable or alias by name.

**SYNOPSIS**

```zig
fn FindVar(db: *DosBase, name: [*:0]const u8, var_type: u32) ?*dos.LocalVar
```

**SINCE**

1.0. LVO -504.

**INPUTS**

- `name` - the variable's name, matched in any case.
- `var_type` - LV_VAR or LV_ALIAS, in the low byte.

**RESULT**

The LocalVar, or null when the running process has none of that name and
type, or the caller is a plain task.

**BEHAVIOR**

Only the local list is searched, never ENV:. A variable with LVF_IGNORE
set matches nothing. IoErr is not set.

**CONTEXT**

- Waits: no.
- Interrupts: not callable.
- Forbid: not needed, and not taken.
- Process: required for a result; a plain task gets null.

**OWNERSHIP**

The LocalVar stays the process's. It is valid until the variable is set
or deleted, and only the process itself should use it.

**BUGS**

None known.

**SEE ALSO**

`GetVar`, `SetVar`

**EXAMPLES**

```zig
if (dos_lib.FindVar("ll", dos.LV_ALIAS)) |alias| run(alias.value[0..alias.len]);
```

## Flush

Empties a file handle's buffer.

**SYNOPSIS**

```zig
fn Flush(db: *DosBase, file: ?*FileHandle) bool
```

**SINCE**

1.0. LVO -404.

**INPUTS**

- `file` - the handle.

**RESULT**

True when the buffer is empty and the handler's position is the
caller's. False with `IoErr()` set when writing the waiting bytes failed
(`ERROR_DISK_FULL`, the handler's code) or when seeking back over the
read-ahead failed; `ERROR_INVALID_LOCK` for a null handle.

**BEHAVIOR**

Bytes waiting to be written are written; what doesn't go out stays at
the front of the buffer for the next try. Bytes read ahead, and
characters pushed back that stand for bytes the file gave, are given
back by seeking the handler back over them; a character the caller
pushed back that the file never gave is dropped. A console keeps what it read ahead: it has no position to seek,
and what was typed would otherwise be lost.

**CONTEXT**

- Waits: only when the buffer has to go to or come from the handler;
  then it sends a packet and waits for the answer.
- Interrupts: no. It may wait.
- Forbid: not taken, and never to be held around it: it may wait.
- Process: a Task will do. One handle is one caller's: two tasks sharing
  a handle take turns themselves.

**OWNERSHIP**

Nothing is allocated. The buffer stays with the handle.

**BUGS**

None known.

**SEE ALSO**

`Seek`, `SetVBuf`, `Close`, `FWrite`

**EXAMPLES**

```zig
_ = dos_lib.PutStr("Name: ");
_ = dos_lib.Flush(dos_lib.Output());
```

## FreeArgs

Frees what ReadArgs allocated.

**SYNOPSIS**

```zig
fn FreeArgs(db: *DosBase, rdargs: ?*dos.RDArgs) void
```

**SINCE**

1.0. LVO -460.

**INPUTS**

- `rdargs` - what `ReadArgs` returned; null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

Every block on the DAList is freed, the buffer pointer cleared and
ReadArgs' own flags taken off; the caller's flags stay, so a caller's
RDArgs can go to ReadArgs again as it is.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

The strings, numbers and arrays in the slots are gone. An RDArgs that
ReadArgs made is freed too; one the caller gave stays the caller's.

**NOTES**

A second call is safe on an RDArgs the caller gave. One ReadArgs made
is freed by the first call and must not be passed again.

**BUGS**

None known.

**SEE ALSO**

`ReadArgs`

**EXAMPLES**

```zig
const rda = dos_lib.ReadArgs(template, &argv, null) orelse return;
defer dos_lib.FreeArgs(rda);
```

## FreeDeviceProc

Frees a DevProc GetDeviceProc gave.

**SYNOPSIS**

```zig
fn FreeDeviceProc(db: *DosBase, dp: ?*DevProc) void
```

**SINCE**

1.0. LVO -100.

**INPUTS**

- `dp` - the DevProc; null does nothing.

**RESULT**

None.

**BEHAVIOR**

A lock GetDeviceProc made for it (DVPF_UNLOCK, a non-binding
assign's) is unlocked, then the DevProc is freed. A lock it only
borrowed - an assign's directory, the current directory - is left
alone.

**CONTEXT**

- Waits: yes, when it unlocks a lock (a packet to its handler).
- Interrupts: not safe.
- Forbid: not to be held; it may wait.
- Process: a Task will do.

**OWNERSHIP**

`dp` is gone and must not be used again.

**BUGS**

None known.

**SEE ALSO**

`GetDeviceProc`

**EXAMPLES**

```zig
defer dos_lib.FreeDeviceProc(dp);
```

## FreeDosEntry

Frees a node MakeDosEntry made.

**SYNOPSIS**

```zig
fn FreeDosEntry(db: *DosBase, dlist: ?*DosList) void
```

**SINCE**

1.0. LVO -92.

**INPUTS**

- `dlist` - the node, not on the list; null does nothing.

**RESULT**

None.

**BEHAVIOR**

The node's block, name included, is freed. Nothing it points to is: a
lock or a path it holds is the caller's to free first.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: allowed.
- Process: a Task will do.

**OWNERSHIP**

The node is gone.

**BUGS**

None known.

**SEE ALSO**

`MakeDosEntry`, `RemDosEntry`

**EXAMPLES**

```zig
if (dos_lib.RemDosEntry(node)) dos_lib.FreeDosEntry(node);
```

## FreeDosObject

Frees an object AllocDosObject made.

**SYNOPSIS**

```zig
fn FreeDosObject(db: *DosBase, obj_type: u32, ptr: ?*anyopaque) void
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `obj_type` - the type it was made as.
- `ptr` - the object; null does nothing.

**RESULT**

None.

**BEHAVIOR**

The object's block is freed. Nothing it points to is: a FileHandle's
buffer, a CLI's streams and an RDArgs' memory are their owners' to
free first (Close, FreeArgs). An unknown type does nothing.

**CONTEXT**

- Waits: no.
- Interrupts: not safe; it frees memory.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

The object is gone; `ptr` must not be used again.

**BUGS**

None known.

**SEE ALSO**

`AllocDosObject`

**EXAMPLES**

```zig
dos_lib.FreeDosObject(dos.DOS_FIB, fib);
```

## GetArgStr

Returns the argument line of the command the calling process runs.

**SYNOPSIS**

```zig
fn GetArgStr(db: *DosBase) ?[*:0]const u8
```

**SINCE**

1.0. LVO -516.

**INPUTS**

None.

**RESULT**

pr_Arguments, or null when there is none and from a plain task.

**BEHAVIOR**

pr_Arguments is read.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: allowed.
- Process: a process; a plain task gets null.

**OWNERSHIP**

The string stays the process's; it is valid while the command runs.

**BUGS**

None known.

**SEE ALSO**

`SetArgStr`, `ReadArgs`

**EXAMPLES**

```zig
const line = dos_lib.GetArgStr() orelse "";
```

## GetConsoleTask

Returns the running process's console handler's port (pr_ConsoleTask).

**SYNOPSIS**

```zig
fn GetConsoleTask(db: *DosBase) ?*MsgPort
```

**SINCE**

1.0. LVO -264.

**INPUTS**

None.

**RESULT**

The port of the handler that "*" and CONSOLE: open, or null when the
process has no console (or is a plain Task).

**BEHAVIOR**

Reads pr_ConsoleTask of the running process. Nothing is checked or
changed.

**CONTEXT**

- Waits: no.
- Interrupts: not safe; it reads the running task's Process.
- Forbid: not needed, and not taken.
- Process: a Process for an answer; from a plain Task it does
  nothing and answers null.

**OWNERSHIP**

The port belongs to its handler; the caller only sends to it.

**BUGS**

None known.

**SEE ALSO**

`SetConsoleTask`, `GetDeviceProc`, `Open`

**EXAMPLES**

```zig
if (dos_lib.GetConsoleTask() == null) return error.NoConsole;
```

## GetCurrentDirName

Copies the name of the running process's current directory into the caller's buffer.

**SYNOPSIS**

```zig
fn GetCurrentDirName(db: *DosBase, buffer: [*]u8, size: u32) bool
```

**SINCE**

1.0. LVO -308.

**INPUTS**

- `buffer` - where the name goes, NUL-terminated.
- `size` - how many bytes `buffer` has, the NUL included.

**RESULT**

True when the whole name fitted. False, with IoErr, when it was cut
or `size` is 0 (ERROR_LINE_TOO_LONG), when a CLI has no name buffer
or the caller is a plain Task (ERROR_OBJECT_WRONG_TYPE), or whatever
NameFromLock says.

**BEHAVIOR**

A CLI answers with the name it keeps (SetCurrentDirName), copied as
GetProgramName copies. A process without a CLI has no such name, so
the current directory's full name is asked of NameFromLock instead.
The buffer holds a string after every call: the name, a cut one, or
an empty one.

**CONTEXT**

- Waits: yes, when there is no CLI: NameFromLock sends packets to
  the directory's handler.
- Interrupts: not safe.
- Forbid: not to be held; it may wait.
- Process: a Process; a plain Task gets an empty buffer and false.

**OWNERSHIP**

Nothing is kept. The buffer is the caller's.

**BUGS**

None known.

**SEE ALSO**

`SetCurrentDirName`, `NameFromLock`, `GetProgramName`

**EXAMPLES**

```zig
var dir: [256]u8 = undefined;
if (dos_lib.GetCurrentDirName(&dir, dir.len)) _ = dos_lib.PutStr(@ptrCast(&dir));
```

## GetDeviceProc

Finds the handler a name's packets go to, and the directory the name is relative to.

**SYNOPSIS**

```zig
fn GetDeviceProc(db: *DosBase, name: [*:0]const u8, olddp: ?*DevProc) ?*DevProc
```

**SINCE**

1.0. LVO -96.

**INPUTS**

- `name` - the name: "DF0:file", "NIL:", "CONSOLE:", an assign, or a
  path without a device.
- `olddp` - null for a new lookup; the last answer to move on to the
  next directory of a multi-assign.

**RESULT**

A DevProc with the handler's port (dvp_Port), the directory's lock
or null (dvp_Lock), DVPF_ASSIGN when a multi-assign has more
directories, and the node it came from. Null with IoErr on failure:
ERROR_DEVICE_NOT_MOUNTED, ERROR_NO_PROCESS, ERROR_OBJECT_NOT_FOUND,
ERROR_TOO_MANY_LEVELS, ERROR_NO_FREE_STORE, ERROR_NO_MORE_ENTRIES
(with `olddp`), or what a starting handler answered.

**BEHAVIOR**

The name is parsed with ParsePath. Without a device it goes to the
current directory's handler with the directory (":name": the
volume's root), or to pr_FileSystemTask. CONSOLE: is pr_ConsoleTask
and PROGDIR: pr_HomeDir. Anything else is looked up on the device
list: a device whose handler isn't running has it started; a volume
gives its handler; an assign gives its directory, a late one binding
it first, a non-binding one locking it anew with DVPF_UNLOCK. With
`olddp` the next directory of the assign is given in `olddp` itself,
after unlocking a lock made for it.

**CONTEXT**

- Waits: yes: for the device list's locks, and for a starting
  handler's answer.
- Interrupts: not safe.
- Forbid: not to be held; it waits.
- Process: a Task will do for a name with a device; a name without
  one, CONSOLE: and PROGDIR: need a Process.

**OWNERSHIP**

The DevProc is the caller's, to give back with FreeDeviceProc; when
a call with `olddp` answers null, `olddp` is still the caller's to
free. The port and node stay dos's and the handler's.

**BUGS**

None known.

**SEE ALSO**

`FreeDeviceProc`, `Lock`, `Open`, `AssignAdd`

**EXAMPLES**

```zig
var dp = dos_lib.GetDeviceProc("C:dir", null) orelse return dos_lib.IoErr();
while (true) {
    if (tryIn(dp)) break;
    dp = dos_lib.GetDeviceProc("C:dir", dp) orelse break;
}
dos_lib.FreeDeviceProc(dp);
```

## GetFileSysTask

Returns the running process's default file system's port (pr_FileSystemTask).

**SYNOPSIS**

```zig
fn GetFileSysTask(db: *DosBase) ?*MsgPort
```

**SINCE**

1.0. LVO -272.

**INPUTS**

None.

**RESULT**

The port of the handler that lock 0 means - the file system a null
lock and a name without a device resolve on when there is no current
directory - or null.

**BEHAVIOR**

Reads pr_FileSystemTask of the running process. Nothing is checked
or changed.

**CONTEXT**

- Waits: no.
- Interrupts: not safe; it reads the running task's Process.
- Forbid: not needed, and not taken.
- Process: a Process for an answer; from a plain Task it does
  nothing and answers null.

**OWNERSHIP**

The port belongs to its handler; the caller only sends to it.

**BUGS**

None known.

**SEE ALSO**

`SetFileSysTask`, `CurrentDir`, `GetDeviceProc`

**EXAMPLES**

```zig
const fs = dos_lib.GetFileSysTask() orelse return error.NoFileSystem;
```

## GetProgramDir

Returns the running process's program directory (pr_HomeDir), the directory PROGDIR: names.

**SYNOPSIS**

```zig
fn GetProgramDir(db: *DosBase) ?*FileLock
```

**SINCE**

1.0. LVO -280.

**INPUTS**

None.

**RESULT**

The lock on the directory the program came from, or null when it has
none (a program from ROM, or a plain Task). Without one, PROGDIR: is
looked up as an ordinary name.

**BEHAVIOR**

Reads pr_HomeDir of the running process. Nothing is checked or
changed.

**CONTEXT**

- Waits: no.
- Interrupts: not safe; it reads the running task's Process.
- Forbid: not needed, and not taken.
- Process: a Process for an answer; from a plain Task it does
  nothing and answers null.

**OWNERSHIP**

The lock stays the process's; the caller must not UnLock it.

**BUGS**

None known.

**SEE ALSO**

`SetProgramDir`, `GetDeviceProc`

**EXAMPLES**

```zig
const dir = dos_lib.GetProgramDir() orelse return error.NoProgramDir;
```

## GetProgramName

Copies the running CLI's command name into the caller's buffer.

**SYNOPSIS**

```zig
fn GetProgramName(db: *DosBase, buffer: [*]u8, size: u32) bool
```

**SINCE**

1.0. LVO -292.

**INPUTS**

- `buffer` - where the text goes, NUL-terminated.
- `size` - how many bytes `buffer` has, the NUL included;
  CLI_MAX_COMMAND_NAME holds any command name.

**RESULT**

True when the whole text fitted. False, with IoErr, when it was cut
(ERROR_LINE_TOO_LONG), when `size` is 0 (ERROR_LINE_TOO_LONG,
nothing written) or when there is no CLI (ERROR_OBJECT_WRONG_TYPE).

**BEHAVIOR**

The command name is copied up to `size - 1` bytes and a NUL put
after it, so the buffer always holds a string, even when the answer
is false because it was cut. Without a CLI, or from a plain Task,
the buffer is made empty.

**CONTEXT**

- Waits: no.
- Interrupts: not safe; it reads the running task's Process.
- Forbid: not needed, and not taken.
- Process: a CLI process for an answer; any other caller gets an
  empty buffer and false.

**OWNERSHIP**

Nothing is allocated. The buffer is the caller's.

**BUGS**

None known.

**SEE ALSO**

`SetProgramName`, `GetPrompt`, `GetCurrentDirName`

**EXAMPLES**

```zig
var name: [dos.CLI_MAX_COMMAND_NAME]u8 = undefined;
if (!dos_lib.GetProgramName(&name, name.len)) return error.NoName;
```

## GetPrompt

Copies the running CLI's prompt into the caller's buffer.

**SYNOPSIS**

```zig
fn GetPrompt(db: *DosBase, buffer: [*]u8, size: u32) bool
```

**SINCE**

1.0. LVO -300.

**INPUTS**

- `buffer` - where the text goes, NUL-terminated.
- `size` - how many bytes `buffer` has, the NUL included;
  CLI_MAX_PROMPT holds any prompt.

**RESULT**

True when the whole text fitted. False, with IoErr, when it was cut
(ERROR_LINE_TOO_LONG), when `size` is 0 (ERROR_LINE_TOO_LONG,
nothing written) or when there is no CLI (ERROR_OBJECT_WRONG_TYPE).

**BEHAVIOR**

The prompt is copied up to `size - 1` bytes and a NUL put after it,
so the buffer always holds a string, even when the answer is false
because it was cut. Without a CLI, or from a plain Task, the buffer
is made empty.

**CONTEXT**

- Waits: no.
- Interrupts: not safe; it reads the running task's Process.
- Forbid: not needed, and not taken.
- Process: a CLI process for an answer; any other caller gets an
  empty buffer and false.

**OWNERSHIP**

Nothing is allocated. The buffer is the caller's.

**BUGS**

None known.

**SEE ALSO**

`SetPrompt`, `GetProgramName`

**EXAMPLES**

```zig
var prompt: [dos.CLI_MAX_PROMPT]u8 = undefined;
_ = dos_lib.GetPrompt(&prompt, prompt.len);
```

## GetVar

Reads a variable's value into a buffer.

**SYNOPSIS**

```zig
fn GetVar(db: *DosBase, name: [*:0]const u8, buffer: [*]u8, size: isize, flags: u32) isize
```

**SINCE**

1.0. LVO -496.

**INPUTS**

- `name` - the variable's name.
- `buffer` - where the value goes.
- `size` - the buffer's size in bytes, at least 1.
- `flags` - the type in the low byte (LV_VAR or LV_ALIAS), with
  GVF_GLOBAL_ONLY, GVF_LOCAL_ONLY, GVF_BINARY_VAR and
  GVF_DONT_NULL_TERM.

**RESULT**

The bytes put in the buffer, the NUL not counted, with IoErr set to the
value's whole length - more than the result when it was cut. -1 on
failure, with IoErr set: ERROR_BAD_NUMBER for a size below 1,
ERROR_OBJECT_NOT_FOUND when there is no such variable,
ERROR_LINE_TOO_LONG for a name that makes too long a path.

**BEHAVIOR**

The process's local variable of that name and type comes first (unless
GVF_GLOBAL_ONLY), then the file ENV:name (unless GVF_LOCAL_ONLY; only
for LV_VAR). A text value is cut at its first newline and ended with a
NUL, which takes one byte of `size`. With GVF_BINARY_VAR the value is
copied as it is, and with GVF_DONT_NULL_TERM as well, no NUL is added.

**CONTEXT**

- Waits: yes, for a global variable (file system packets); not for a
  local one.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: a Task will do for a global variable; only a process has
  local ones and gets IoErr.

**OWNERSHIP**

The buffer is the caller's. Nothing is kept.

**BUGS**

None known.

**SEE ALSO**

`SetVar`, `FindVar`, `DeleteVar`

**EXAMPLES**

```zig
var value: [64]u8 = undefined;
if (dos_lib.GetVar("Editor", &value, value.len, dos.LV_VAR) < 0) return;
```

## Info

Fills in an InfoData about the volume a lock is on.

**SYNOPSIS**

```zig
fn Info(db: *DosBase, lock: ?*FileLock, data: *dos.InfoData) bool
```

**SINCE**

1.0. LVO -392.

**INPUTS**

- `lock` - a lock on anything on the volume; null asks the current
  process's file system.
- `data` - the InfoData to fill in.

**RESULT**

True if `data` is filled in; false with IoErr()
(ERROR_DEVICE_NOT_MOUNTED for null from a plain task, the handler's
error).

**BEHAVIOR**

The lock's handler (for null, pr_FileSystemTask) is sent ACTION_INFO
with the lock and `data`.

**CONTEXT**

- Waits: yes, for the handler's answer to a packet.
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do; a process gets IoErr().

**OWNERSHIP**

`data` is the caller's; the handler only writes it.

**BUGS**

None known.

**SEE ALSO**

`Lock`, `IsFileSystem`

**EXAMPLES**

```zig
var info: dos.InfoData = .{};
if (dos_lib.Info(lock, &info)) used = info.num_blocks_used;
```

## Input

Gives the running process's input handle.

**SYNOPSIS**

```zig
fn Input(db: *DosBase) ?*FileHandle
```

**SINCE**

1.0. LVO -212.

**INPUTS**

None.

**RESULT**

`pr_CIS`, the process's input; null when there is none or the caller is
a plain Task.

**BEHAVIOR**

Reads the field; nothing is opened.

**CONTEXT**

- Waits: no.
- Interrupts: no. It reads the running task.
- Forbid: not needed, and not taken.
- Process: a Process; from a plain Task the answer is null and nothing
  changes.

**OWNERSHIP**

The handle is the process's. Don't close it: whoever set it closes it.

**BUGS**

None known.

**SEE ALSO**

`Output`, `SelectInput`, `FGetC`

**EXAMPLES**

```zig
const in = dos_lib.Input() orelse return;
const c = dos_lib.FGetC(in);
```

## IoErr

Returns the secondary result of the calling process's last dos call.

**SYNOPSIS**

```zig
fn IoErr(db: *DosBase) i32
```

**SINCE**

1.0. LVO -48.

**INPUTS**

None.

**RESULT**

pr_Result2: the error code (ERROR_*) a failed call left, or what a call
that answers with a count or a length left there. ERROR_NO_PROCESS from
a plain task.

**BEHAVIOR**

pr_Result2 is read; it is not cleared. Every dos call that fails sets
it, and many that succeed set it too (a packet's dp_Res2 always lands
there), so it is read right after the call it belongs to.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: allowed.
- Process: a process; a plain task gets ERROR_NO_PROCESS.

**OWNERSHIP**

Nothing changes hands.

**BUGS**

None known.

**SEE ALSO**

`SetIoErr`, `Fault`, `PrintFault`

**EXAMPLES**

```zig
const lock = dos_lib.Lock(name, dos.SHARED_LOCK) orelse {
    _ = dos_lib.PrintFault(dos_lib.IoErr(), name);
    return;
};
```

## IsFileSystem

Tells whether a name is on a file system.

**SYNOPSIS**

```zig
fn IsFileSystem(db: *DosBase, name: [*:0]const u8) bool
```

**SINCE**

1.0. LVO -396.

**INPUTS**

- `name` - a name, as for Lock; "*" is the console.

**RESULT**

True for a file system. False for a handler that isn't one, for "*"
(IoErr() ERROR_ACTION_NOT_KNOWN), and when the name has no handler
(IoErr() says why).

**BEHAVIOR**

A name without a device part is on the current directory's volume and so
on a file system, without asking anyone. Otherwise the name's handler is
sent ACTION_IS_FILESYSTEM; a handler that doesn't know that packet is a
file system if its root ("DEV:") can be locked.

**CONTEXT**

- Waits: yes, for the handler's answer to a packet.
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do; a process gets IoErr().

**OWNERSHIP**

Nothing changes hands.

**BUGS**

None known.

**SEE ALSO**

`GetDeviceProc`, `Info`, `Lock`

**EXAMPLES**

```zig
if (!dos_lib.IsFileSystem(target)) return error.NotAFileSystem;
```

## IsInteractive

Tells whether a file is a console.

**SYNOPSIS**

```zig
fn IsInteractive(_: *DosBase, file: ?*FileHandle) bool
```

**SINCE**

1.0. LVO -228.

**INPUTS**

- `file` - the handle, or null.

**RESULT**

True when the handler marked the handle interactive at open - a console,
typed at by someone; false otherwise and for null.

**BEHAVIOR**

Reads `fh_Interactive`, which the handler set when it opened the file;
no packet is sent.

**CONTEXT**

- Waits: no.
- Interrupts: safe: it reads one field.
- Forbid: not needed, and not taken.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`SetMode`, `WaitForChar`

**EXAMPLES**

```zig
if (dos_lib.IsInteractive(dos_lib.Input())) _ = dos_lib.PutStr("> ");
```

## LoadSeg

Loads a program or module file into memory, ready to run.

**SYNOPSIS**

```zig
fn LoadSeg(db: *DosBase, name: [*:0]const u8) ?*dos.SegList
```

**SINCE**

1.0. LVO -544.

**INPUTS**

- `name` - the load file's name, as for Open.

**RESULT**

The chain of segments, the first one with the entry point in its
`entry`, for RunCommand and CreateNewProc and later UnLoadSeg; IoErr is
0. Null on failure, with IoErr set: ERROR_OBJECT_WRONG_TYPE for a file
that isn't a load file of this version, ERROR_BAD_HUNK for one that is
damaged (too many or too large segments, relocations outside them, an
entry point outside the code), ERROR_NO_FREE_STORE, or Open's error.

**BEHAVIOR**

Each segment gets one block of memory the CPU can run code from, its
bytes read in and the rest cleared. Once all are in, the relocations are
applied: each word named gets the base of its target segment added, the
instruction-bus address for a code segment. The caches are cleared
before the chain is answered, so the new code is what runs. On failure
everything loaded so far is freed.

**CONTEXT**

- Waits: yes, for the file system.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: a Task will do; only a process gets IoErr.

**OWNERSHIP**

The chain is the caller's until UnLoadSeg, which frees it.

**BUGS**

None known.

**SEE ALSO**

`UnLoadSeg`, `RunCommand`, `CreateNewProc`

**EXAMPLES**

```zig
const seg = dos_lib.LoadSeg("C:dir") orelse return dos_lib.IoErr();
defer dos_lib.UnLoadSeg(seg);
const entry = seg.entry orelse return dos.ERROR_FILE_NOT_OBJECT; // a program's CommandFn
```

## Lock

Locks a file or directory by name.

**SYNOPSIS**

```zig
fn Lock(db: *DosBase, name: [*:0]const u8, mode: i32) ?*FileLock
```

**SINCE**

1.0. LVO -144.

**INPUTS**

- `name` - the object: "DEV:path", "ASSIGN:path", ":path" (the current
  volume's root) or a path from the current directory. At most 255
  characters.
- `mode` - SHARED_LOCK (others may lock it too) or EXCLUSIVE_LOCK
  (nobody else may).

**RESULT**

The lock, or null with IoErr() saying why: ERROR_LINE_TOO_LONG,
ERROR_OBJECT_NOT_FOUND, ERROR_OBJECT_IN_USE, ERROR_DEVICE_NOT_MOUNTED,
ERROR_NO_FREE_STORE, or whatever the handler answers.

**BEHAVIOR**

GetDeviceProc finds the name's handler and the directory the name is
relative to, and the handler is sent ACTION_LOCATE_OBJECT with that
directory's lock, the whole name (device part included) and `mode`. On a
multi-directory assign, a directory that answers ERROR_OBJECT_NOT_FOUND
passes the question to the assign's next directory; any other error ends
the search.

**CONTEXT**

- Waits: yes, for the handler's answer to a packet.
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do; a process gets IoErr().

**OWNERSHIP**

The lock belongs to the caller, who gives it back with UnLock. The
handler allocated it; dos never frees one itself.

**BUGS**

None known.

**SEE ALSO**

`UnLock`, `DupLock`, `CreateDir`, `GetDeviceProc`, `Examine`

**EXAMPLES**

```zig
const dir = dos_lib.Lock("SYS:c", dos.SHARED_LOCK) orelse return dos_lib.IoErr();
defer dos_lib.UnLock(dir);
```

## LockDosList

Locks the device list for reading or writing.

**SYNOPSIS**

```zig
fn LockDosList(db: *DosBase, flags: u32) ?*DosList
```

**SINCE**

1.0. LVO -60.

**INPUTS**

- `flags` - what to lock: any of LDF_DEVICES, LDF_VOLUMES, LDF_ASSIGNS
  (or LDF_ALL) for the list, LDF_ENTRY while a handler is being started,
  LDF_DELETE while a node is being removed; with exactly one of LDF_READ
  and LDF_WRITE.

**RESULT**

The list's head node, to start FindDosEntry and NextDosEntry at; null
for flags without exactly one of LDF_READ and LDF_WRITE, or with an
unknown bit.

**BEHAVIOR**

Up to three semaphores are taken, always in the same order - the list,
the entry lock, the delete lock - shared for LDF_READ and exclusive for
LDF_WRITE. Any of the three type flags selects the one list semaphore:
the types are not locked apart. The head node is a private node, never
found by FindDosEntry.

**CONTEXT**

- Waits: yes, for the device list's semaphores.
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do.

**OWNERSHIP**

The locks are the caller's until UnLockDosList with the same flags. The
nodes stay dos's.

**NOTES**

A handler must not take the list with LDF_WRITE while it could be asked
something by a process that holds it; AttemptLockDosList is for that.

**BUGS**

None known.

**SEE ALSO**

`UnLockDosList`, `AttemptLockDosList`, `FindDosEntry`, `NextDosEntry`

**EXAMPLES**

```zig
const flags = dos.LDF_VOLUMES | dos.LDF_READ;
const list = dos_lib.LockDosList(flags) orelse return;
defer dos_lib.UnLockDosList(flags);
var node = dos_lib.NextDosEntry(list, dos.LDF_VOLUMES);
```

## LockSegmentList

Locks the resident segment list and returns its first segment.

**SYNOPSIS**

```zig
fn LockSegmentList(db: *DosBase, shared: bool) ?*Segment
```

**SINCE**

1.0. LVO -136.

**INPUTS**

- `shared` - true for a shared lock, enough to walk and search the
  list; false for an exclusive one, to change it.

**RESULT**

The first segment, or null when the list is empty.

**BEHAVIOR**

Obtains the list's semaphore shared or exclusive. The list stays as
it is until UnLockSegmentList.

**CONTEXT**

- Waits: yes, for the segment list's semaphore.
- Interrupts: not safe.
- Forbid: not to be held; it may wait.
- Process: a Task will do.

**OWNERSHIP**

The lock is the caller's until UnLockSegmentList; the segments stay
dos's.

**BUGS**

None known.

**SEE ALSO**

`UnLockSegmentList`, `FindSegment`

**EXAMPLES**

```zig
var seg = dos_lib.LockSegmentList(true);
defer dos_lib.UnLockSegmentList();
while (seg) |s| : (seg = s.next) count += 1;
```

## MakeDosEntry

Makes a device list node with a copy of its name.

**SYNOPSIS**

```zig
fn MakeDosEntry(db: *DosBase, name: [*:0]const u8, dlt: i32) ?*DosList
```

**SINCE**

1.0. LVO -88.

**INPUTS**

- `name` - the name, without the colon.
- `dlt` - the node's type, a DLT_* value.

**RESULT**

The node, cleared apart from its type and name, or null with IoErr()
ERROR_NO_FREE_STORE, or ERROR_BAD_NUMBER for a `dlt` that is no DLT_*
value.

**BEHAVIOR**

The node and its name are one allocation, the name right after the node.
It is not put on the list.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: allowed.
- Process: a Task will do.

**OWNERSHIP**

The node is the caller's, freed with FreeDosEntry - or the list's once
AddDosEntry took it.

**BUGS**

None known.

**SEE ALSO**

`FreeDosEntry`, `AddDosEntry`

**EXAMPLES**

```zig
const node = dos_lib.MakeDosEntry("RAM", dos.DLT_DEVICE) orelse return null;
node.misc.handler.handler = "ram-handler";
```

## MatchEnd

Ends a pattern search, freeing what it holds.

**SYNOPSIS**

```zig
fn MatchEnd(db: *DosBase, anchor: *dos.AnchorPath) void
```

**SINCE**

1.0. LVO -344.

**INPUTS**

- `anchor` - the search MatchFirst started.

**RESULT**

None.

**BEHAVIOR**

Every level's lock is unlocked and its memory freed; ap_Base and ap_Last
are cleared, so a second MatchEnd, or one after a search that ended on
an error, does nothing.

**CONTEXT**

- Waits: yes, unlocking sends packets.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: a Task will do.

**OWNERSHIP**

The anchor itself stays the caller's.

**BUGS**

None known.

**SEE ALSO**

`MatchFirst`, `MatchNext`

**EXAMPLES**

```zig
defer dos_lib.MatchEnd(&anchor);
```

## MatchFirst

Starts a pattern search and finds the first object the pattern names.

**SYNOPSIS**

```zig
fn MatchFirst(db: *DosBase, pattern: [*:0]const u8, anchor: *dos.AnchorPath) i32
```

**SINCE**

1.0. LVO -336.

**INPUTS**

- `pattern` - the pattern, in utility.library's syntax after a literal
  device part ("RAM:d/#?.txt").
- `anchor` - the search's state: ap_BreakBits, ap_Flags and ap_Strlen
  set by the caller, the rest cleared. When ap_Strlen isn't 0, that many
  bytes follow the AnchorPath for the full path.

**RESULT**

0 when an object was found: its FileInfoBlock is in ap_Info, and its
full path in the buffer when ap_Strlen isn't 0. Otherwise an error, also
in IoErr: ERROR_NO_MORE_ENTRIES when nothing matches,
ERROR_BUFFER_OVERFLOW when the path was cut to fit (the search goes on),
ERROR_BAD_TEMPLATE for a pattern that doesn't parse, ERROR_BREAK when
one of ap_BreakBits came, or a handler's error.

**BEHAVIOR**

The pattern becomes a chain of levels on the anchor, and the first one
is looked for as MatchNext looks. APF_ITSWILD is set when the pattern
has a wildcard. "*" and the name of a handler that isn't a file system
(NIL:, CON:) give one entry, the name itself. An error other than
ERROR_BUFFER_OVERFLOW frees the chain.

**CONTEXT**

- Waits: yes, for the handlers' answers.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: a Task will do for a pattern with a device; without one the
  search starts in the current directory, which only a process has.

**OWNERSHIP**

The anchor holds locks and memory until MatchEnd, which the caller calls
whatever MatchFirst answered.

**BUGS**

None known.

**SEE ALSO**

`MatchNext`, `MatchEnd`, `ParsePattern`

**EXAMPLES**

```zig
var anchor: dos.AnchorPath = .{};
var rc = dos_lib.MatchFirst("RAM:#?.txt", &anchor);
while (rc == 0) : (rc = dos_lib.MatchNext(&anchor)) show(&anchor.info);
dos_lib.MatchEnd(&anchor);
```

## MatchNext

Finds the next object a pattern search names.

**SYNOPSIS**

```zig
fn MatchNext(db: *DosBase, anchor: *dos.AnchorPath) i32
```

**SINCE**

1.0. LVO -340.

**INPUTS**

- `anchor` - the search MatchFirst started. Set APF_DODIR in ap_Flags
  first to go into the directory just found.

**RESULT**

0 when an object was found, as MatchFirst. Otherwise an error, also in
IoErr: ERROR_NO_MORE_ENTRIES when the search is done,
ERROR_BUFFER_OVERFLOW when the path was cut to fit, ERROR_BREAK when one
of ap_BreakBits came (ap_FoundBreak says which), ERROR_NO_FREE_STORE, or
a handler's error.

**BEHAVIOR**

With APF_DODIR the directory just found is gone into (a hard link to a
directory only with APF_FollowHLinks); once it is read through it comes
once more, with APF_DIDDIR set, which stays set until the caller clears
it. APF_DirChanged says the entry is in another directory than the one
before. The break signals are checked, and cleared, between entries. Any
error but ERROR_BUFFER_OVERFLOW frees the chain.

**CONTEXT**

- Waits: yes, for the handlers' answers.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: a Task will do for a pattern with a device; without one the
  search starts in the current directory, which only a process has.

**OWNERSHIP**

As MatchFirst: the anchor holds locks and memory until MatchEnd.

**BUGS**

None known.

**SEE ALSO**

`MatchFirst`, `MatchEnd`

**EXAMPLES**

```zig
while (dos_lib.MatchNext(&anchor) == 0) {
    if (anchor.info.dir_entry_type > 0 and anchor.flags & dos.APF_DIDDIR == 0) anchor.flags |= dos.APF_DODIR;
    anchor.flags &= ~dos.APF_DIDDIR;
}
```

## MaxCli

Returns the highest CLI number in use.

**SYNOPSIS**

```zig
fn MaxCli(db: *DosBase) u32
```

**SINCE**

1.0. LVO -524.

**INPUTS**

None.

**RESULT**

The highest number a CLI process has, or 0 when there is none.

**BEHAVIOR**

The CLI table is read under its lock. Numbers below the result may be
free.

**CONTEXT**

- Waits: yes, for the CLI table's semaphore.
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**BUGS**

None known.

**SEE ALSO**

`FindCliProc`

**EXAMPLES**

```zig
var num: u32 = 1;
while (num <= dos_lib.MaxCli()) : (num += 1) {
    if (dos_lib.FindCliProc(num)) |proc| show(num, proc);
}
```

## NameFromFH

Writes the full name of the file an open handle is on into the caller's buffer.

**SYNOPSIS**

```zig
fn NameFromFH(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, size: u32) bool
```

**SINCE**

1.0. LVO -380.

**INPUTS**

- `file` - the open file.
- `buffer` - where the name goes, NUL-terminated.
- `size` - how many bytes `buffer` has, the NUL included.

**RESULT**

True with the name in `buffer` ("Ram Disk:d/file"). False with IoErr
and an empty buffer: ERROR_LINE_TOO_LONG when it doesn't fit or
`size` is 0, or whatever ParentOfFH, ExamineFH, NameFromLock or
AllocDosObject said.

**BEHAVIOR**

The file's directory comes from ParentOfFH and is named with
NameFromLock; the file's own name, from ExamineFH, is added with
AddPart. The parent lock and the FileInfoBlock used on the way are
freed before it returns.

**CONTEXT**

- Waits: yes, for the handler's answers.
- Interrupts: not safe.
- Forbid: not to be held; it waits.
- Process: a Task will do.

**OWNERSHIP**

The handle stays the caller's and stays open. The buffer is the
caller's.

**BUGS**

None known.

**SEE ALSO**

`NameFromLock`, `ParentOfFH`, `ExamineFH`

**EXAMPLES**

```zig
var name: [256]u8 = undefined;
if (dos_lib.NameFromFH(fh, &name, name.len)) _ = dos_lib.PutStr(@ptrCast(&name));
```

## NameFromLock

Writes the full name of the object a lock is on, volume first, into the caller's buffer.

**SYNOPSIS**

```zig
fn NameFromLock(db: *DosBase, lock: ?*FileLock, buffer: [*]u8, size: u32) bool
```

**SINCE**

1.0. LVO -312.

**INPUTS**

- `lock` - the file or directory to name; null is the root of the
  process's default file system.
- `buffer` - where the name goes, NUL-terminated.
- `size` - how many bytes `buffer` has, the NUL included.

**RESULT**

True with the name in `buffer` ("Ram Disk:d/file", or "Ram Disk:"
for a root). False, with IoErr and an empty buffer:
ERROR_LINE_TOO_LONG when it doesn't fit or `size` is 0,
ERROR_NO_FREE_STORE, ERROR_INVALID_LOCK, ERROR_DEVICE_NOT_MOUNTED
for a null lock without a default file system, or what the handler
answered.

**BEHAVIOR**

The lock is copied (ACTION_COPY_DIR) and the copy walked up to the
root with ACTION_PARENT, each level's name taken from
ACTION_EXAMINE_OBJECT and put in from the buffer's end; the caller's
own lock is never examined, so an ExNext running on it is not
disturbed. The volume's name comes from its volume node, or from
examining the root when the lock has none. The finished name is then
moved to the buffer's start. The packets are sent directly, so a
plain Task can call it too.

**CONTEXT**

- Waits: yes, for the handler's answers.
- Interrupts: not safe.
- Forbid: not to be held; it waits.
- Process: a Task will do; a null lock needs a Process (its
  pr_FileSystemTask).

**OWNERSHIP**

The lock stays the caller's and is unchanged. Every lock made on the
way is freed. The buffer is the caller's.

**BUGS**

None known.

**SEE ALSO**

`NameFromFH`, `ParentDir`, `Examine`, `GetCurrentDirName`

**EXAMPLES**

```zig
var name: [256]u8 = undefined;
if (!dos_lib.NameFromLock(lock, &name, name.len)) return dos_lib.IoErr();
```

## NextDosEntry

Finds the node after a given one that is of some types.

**SYNOPSIS**

```zig
fn NextDosEntry(db: *DosBase, dlist: *DosList, flags: u32) ?*DosList
```

**SINCE**

1.0. LVO -84.

**INPUTS**

- `dlist` - the node to go on from, or the head LockDosList gave.
- `flags` - the types, as for FindDosEntry.

**RESULT**

The next matching node, or null at the end of the list.

**BEHAVIOR**

FindDosEntry from the node after `dlist`, for any name.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: allowed.
- Process: a Task will do. The caller holds the list (LockDosList).

**OWNERSHIP**

As FindDosEntry.

**BUGS**

None known.

**SEE ALSO**

`FindDosEntry`, `LockDosList`

**EXAMPLES**

```zig
var node = dos_lib.NextDosEntry(list, dos.LDF_VOLUMES);
while (node) |volume| : (node = dos_lib.NextDosEntry(volume, dos.LDF_VOLUMES)) {
    show(volume.name);
}
```

## Open

Opens a file by name.

**SYNOPSIS**

```zig
fn Open(db: *DosBase, name: [*:0]const u8, mode: i32) ?*FileHandle
```

**SINCE**

1.0. LVO -192.

**INPUTS**

- `name` - the file's name: a path with or without a device, or "*" for
  the process's console.
- `mode` - `MODE_OLDFILE` (an existing file), `MODE_NEWFILE` (a new
  file, or an existing one emptied) or `MODE_READWRITE` (an existing
  file, or a new one, opened shared).

**RESULT**

The file's handle, or null. On null, `IoErr()` says why:
`ERROR_ACTION_NOT_KNOWN` for another `mode`, `ERROR_NO_FREE_STORE` when
the handle can't be allocated, or the handler's code
(`ERROR_OBJECT_NOT_FOUND`, `ERROR_OBJECT_IN_USE`,
`ERROR_DEVICE_NOT_MOUNTED`, ...).

**BEHAVIOR**

The mode picks the packet: `ACTION_FINDINPUT`, `ACTION_FINDOUTPUT` or
`ACTION_FINDUPDATE`. The name is resolved to its handler and directory
as `Lock` resolves one, and the packet carries the new handle, the
directory's lock and the name. Along a multi-assign the next directory
is tried while the file isn't found - except for `MODE_NEWFILE`, which
creates the file in the first directory rather than looking for one to
replace.

"*" is the process's console, as CONSOLE:, or NIL: when the process has
none (or the caller is a plain Task). The handle starts line buffered,
with no buffer until the first buffered call.

**CONTEXT**

- Waits: yes: it sends the handler a packet and waits for the answer.
- Interrupts: no. It waits.
- Forbid: not taken, and never to be held around it: it waits.
- Process: a Task will do; the answer comes back on a port of its own.

**OWNERSHIP**

The handle is the caller's, to give to `Close` once. It is allocated
with `AllocDosObject(DOS_FILEHANDLE)` and freed again if the open fails.

**BUGS**

None known.

**SEE ALSO**

`Close`, `Read`, `Write`, `OpenFromLock`, `Lock`

**EXAMPLES**

```zig
const fh = dos_lib.Open("S:Startup-Sequence", dos.MODE_OLDFILE) orelse return dos_lib.IoErr();
defer _ = dos_lib.Close(fh);
```

## OpenFromLock

Opens the file a lock is on.

**SYNOPSIS**

```zig
fn OpenFromLock(db: *DosBase, lock: ?*FileLock) ?*FileHandle
```

**SINCE**

1.0. LVO -384.

**INPUTS**

- `lock` - a lock on a file (not a directory).

**RESULT**

The handle, or null with `IoErr()` set: `ERROR_OBJECT_WRONG_TYPE` for a
null lock, `ERROR_INVALID_LOCK` for one without a handler,
`ERROR_NO_FREE_STORE`, or the handler's code.

**BEHAVIOR**

`ACTION_FH_FROM_LOCK` goes to the lock's handler with a new handle and
the lock. On success the handler has taken the lock into the open file.

**CONTEXT**

- Waits: yes: it sends the handler a packet and waits for the answer.
- Interrupts: no. It waits.
- Forbid: not taken, and never to be held around it: it waits.
- Process: a Task will do; the answer comes back on a port of its own.

**OWNERSHIP**

On success the lock belongs to the file: it is not unlocked by the
caller, and `Close` ends both. On failure the lock stays the caller's,
to unlock. The handle is the caller's, for `Close`.

**BUGS**

None known.

**SEE ALSO**

`Open`, `DupLockFromFH`, `Lock`

**EXAMPLES**

```zig
const l = dos_lib.Lock("RAM:notes", dos.SHARED_LOCK) orelse return dos_lib.IoErr();
const fh = dos_lib.OpenFromLock(l) orelse {
    dos_lib.UnLock(l);
    return dos_lib.IoErr();
};
defer _ = dos_lib.Close(fh);
```

## Output

Gives the running process's output handle.

**SYNOPSIS**

```zig
fn Output(db: *DosBase) ?*FileHandle
```

**SINCE**

1.0. LVO -216.

**INPUTS**

None.

**RESULT**

`pr_COS`, the process's output; null when there is none or the caller is
a plain Task.

**BEHAVIOR**

Reads the field; nothing is opened.

**CONTEXT**

- Waits: no.
- Interrupts: no. It reads the running task.
- Forbid: not needed, and not taken.
- Process: a Process; from a plain Task the answer is null and nothing
  changes.

**OWNERSHIP**

The handle is the process's. Don't close it: whoever set it closes it.

**BUGS**

None known.

**SEE ALSO**

`Input`, `SelectOutput`, `PutStr`

**EXAMPLES**

```zig
_ = dos_lib.FPuts(dos_lib.Output(), "done\n");
```

## ParentDir

Locks the directory an object is in.

**SYNOPSIS**

```zig
fn ParentDir(db: *DosBase, lock: ?*FileLock) ?*FileLock
```

**SINCE**

1.0. LVO -156.

**INPUTS**

- `lock` - a lock on the object; null asks the current process's file
  system about its root.

**RESULT**

A shared lock on the parent directory, or null: at the root with IoErr()
0, else with the error.

**BEHAVIOR**

The lock's handler (for null, pr_FileSystemTask) is sent ACTION_PARENT
with the lock.

**CONTEXT**

- Waits: yes, for the handler's answer to a packet.
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do; a process gets IoErr().
  With a null lock, a plain task has no file system and gets
ERROR_DEVICE_NOT_MOUNTED.

**OWNERSHIP**

The new lock is the caller's; `lock` stays the caller's.

**BUGS**

None known.

**SEE ALSO**

`Lock`, `ParentOfFH`, `NameFromLock`

**EXAMPLES**

```zig
const up = dos_lib.ParentDir(here) orelse {
    if (dos_lib.IoErr() == 0) return; // `here` is the root
    return error.NoParent;
};
```

## ParentOfFH

Gives a shared lock on the directory of an open file.

**SYNOPSIS**

```zig
fn ParentOfFH(db: *DosBase, file: ?*FileHandle) ?*FileLock
```

**SINCE**

1.0. LVO -376.

**INPUTS**

- `file` - the handle.

**RESULT**

A shared lock on the directory, or null with `IoErr()` set
(`ERROR_INVALID_LOCK` for a null handle or one without a handler,
`ERROR_NO_FREE_STORE`, or the handler's code).

**BEHAVIOR**

`ACTION_PARENT_FH` with the handle to its handler, which makes the lock.

**CONTEXT**

- Waits: yes: it sends the handler a packet and waits for the answer.
- Interrupts: no. It waits.
- Forbid: not taken, and never to be held around it: it waits.
- Process: a Task will do; the answer comes back on a port of its own.

**OWNERSHIP**

The lock is the caller's, for `UnLock`. The handle stays open.

**BUGS**

None known.

**SEE ALSO**

`DupLockFromFH`, `ParentDir`, `NameFromFH`

**EXAMPLES**

```zig
const dir = dos_lib.ParentOfFH(fh) orelse return dos_lib.IoErr();
defer dos_lib.UnLock(dir);
```

## ParsePath

Splits a path into its device and the rest.

**SYNOPSIS**

```zig
fn ParsePath(db: *DosBase, name: [*:0]const u8, parsed: *dos.ParsedPath) bool
```

**SINCE**

1.0. LVO -120.

**INPUTS**

- `name` - the path.
- `parsed` - filled in: the kind of path, the device name, the rest.

**RESULT**

True with `parsed` filled in; false, with IoErr
ERROR_INVALID_COMPONENT_NAME, when the part before the colon is longer
than MAX_DEVICE_NAME.

**BEHAVIOR**

"DEV:rest" is absolute: `volume` is "DEV" and `remainder` "rest".
":rest" is from the current volume's root: `path_type` is root and
`volume` empty. Anything without a colon is relative, `remainder` the
whole name. Only the first colon counts. `parsed` is cleared first, so
it holds the defaults when the call fails.

**CONTEXT**

- Waits: no.
- Interrupts: no; it sets IoErr.
- Forbid: not needed.
- Process: a Task will do; IoErr is then not set.

**OWNERSHIP**

Nothing is allocated. `remainder` points into `name`.

**BUGS**

None known.

**SEE ALSO**

`PathPart`, `GetDeviceProc`

**EXAMPLES**

```zig
var parsed: dos.ParsedPath = .{};
if (!dos_lib.ParsePath("SYS:s/startup", &parsed)) return dos_lib.IoErr();
// parsed.path_type == .absolute, volume "SYS", remainder "s/startup"
```

## PathPart

Finds where the directory part of a path ends.

**SYNOPSIS**

```zig
fn PathPart(db: *DosBase, name: [*:0]const u8) [*:0]const u8
```

**SINCE**

1.0. LVO -112.

**INPUTS**

- `name` - the path.

**RESULT**

A pointer into `name` just past the directory part: "xxx:yyy/zzz/qqq"
gives "/qqq", "xxx:yyy" gives "yyy", a name with neither gives itself.
Writing a NUL there leaves the directory.

**BEHAVIOR**

The last '/' ends the directory, unless it follows another '/' or a
colon, or starts the name: such a slash is a way up and belongs to the
directory, so the result is past it. Without a slash the part after the
colon is the name.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It only reads `name`.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The result points into `name`.

**BUGS**

None known.

**SEE ALSO**

`FilePart`, `AddPart`

**EXAMPLES**

```zig
const end = dos_lib.PathPart(path);
end[0] = 0; // path is now the directory it named a file in
```

## PrintFault

Writes the text for an error code, and a newline, to Output().

**SYNOPSIS**

```zig
fn PrintFault(db: *DosBase, code: i32, header: ?[*:0]const u8) bool
```

**SINCE**

1.0. LVO -488.

**INPUTS**

- `code` - the error code, as for Fault.
- `header` - put before the text with ": " after it; null for none.

**RESULT**

True when the line was written, or there was nothing to write (a code of
0). False when the process has no Output() or the write fails.

**BEHAVIOR**

The line is Fault's text, at most 254 characters, and a newline, written
with FWrite. IoErr is set to `code` afterwards whatever happened, so the
caller can report an error and still hand it on.

**CONTEXT**

- Waits: yes, for the output's handler.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: required for output; a plain task has no Output() and gets
  false.

**OWNERSHIP**

Nothing is kept.

**BUGS**

None known.

**SEE ALSO**

`Fault`, `IoErr`

**EXAMPLES**

```zig
if (dos_lib.Lock(name, dos.SHARED_LOCK) == null) {
    _ = dos_lib.PrintFault(dos_lib.IoErr(), name);
    return dos.RETURN_FAIL;
}
```

## PutStr

Writes a string to the process's output.

**SYNOPSIS**

```zig
fn PutStr(db: *DosBase, string: [*:0]const u8) i32
```

**SINCE**

1.0. LVO -448.

**INPUTS**

- `string` - the string; its NUL is not written.

**RESULT**

0, or -1 with `IoErr()` set as for `FPuts` (`ERROR_INVALID_LOCK` from a
Task or a process without output).

**BEHAVIOR**

`FPuts` to `Output()`, through its buffer.

**CONTEXT**

- Waits: only when the buffer has to go to or come from the handler;
  then it sends a packet and waits for the answer.
- Interrupts: no. It may wait.
- Forbid: not taken, and never to be held around it: it may wait.
- Process: a Task will do. One handle is one caller's: two tasks sharing
  a handle take turns themselves.

**OWNERSHIP**

Nothing is allocated. The string stays the caller's.

**BUGS**

None known.

**SEE ALSO**

`FPuts`, `WriteChars`, `Output`

**EXAMPLES**

```zig
_ = dos_lib.PutStr("Ready.\n");
```

## Read

Reads up to `length` bytes from a file.

**SYNOPSIS**

```zig
fn Read(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, length: isize) isize
```

**SINCE**

1.0. LVO -200.

**INPUTS**

- `file` - the handle to read from.
- `buffer` - where the bytes go; `length` bytes of room.
- `length` - how many bytes are wanted.

**RESULT**

The number of bytes read; 0 at the end of the file; -1 on an error, with
`IoErr()` set (`ERROR_INVALID_LOCK` for a null handle or one without a
handler, `ERROR_NO_FREE_STORE`, or the handler's code).

**BEHAVIOR**

What the handle already holds comes first: pushed-back characters, then
bytes read ahead by the buffered calls. The rest is one `ACTION_READ` to
the handler, straight into `buffer`. A console gives what the buffer
held and stops there, so a line typed is not waited past. Bytes waiting
to be written are written out before anything is read.

The count can be less than `length` without the end being reached - a
console answers with what has been typed.

**CONTEXT**

- Waits: yes: it sends the handler a packet and waits for the answer.
- Interrupts: no. It waits.
- Forbid: not taken, and never to be held around it: it waits.
- Process: a Task will do; the answer comes back on a port of its own.

**OWNERSHIP**

Nothing is allocated. The bytes are the caller's.

**BUGS**

None known.

**SEE ALSO**

`Write`, `FRead`, `Seek`

**EXAMPLES**

```zig
var buf: [256]u8 = undefined;
const n = dos_lib.Read(fh, &buf, buf.len);
if (n < 0) return dos_lib.IoErr();
```

## ReadArgs

Parses a command line by a template into the caller's slots.

**SYNOPSIS**

```zig
fn ReadArgs(db: *DosBase, template: [*:0]const u8, argv: [*]usize, rdargs: ?*dos.RDArgs) ?*dos.RDArgs
```

**SINCE**

1.0. LVO -456.

**INPUTS**

- `template` - the items, comma-separated, e.g. "FROM/M/A,TO/A,Q=QUIET/S":
  '=' joins aliases; /A required, /K only after its keyword, /S a switch,
  /N a number, /T a toggle (YES, NO, ON, OFF), /M many, /F the rest of
  the line.
- `argv` - one pointer-sized slot per item, set to its default by the
  caller. Filled with a string, an i32's address (/N), DOSTRUE (/S, /T
  on) or 0 (/T off), or a null-terminated array of strings or i32
  addresses (/M).
- `rdargs` - a CSource to read instead of Input(), an ExtHelp and
  RDAF_* flags (AllocDosObject(DOS_RDARGS) makes a cleared one); null
  makes one.

**RESULT**

The RDArgs, to give to `FreeArgs` once the slots are no longer needed;
null on failure, with IoErr: ERROR_REQUIRED_ARG_MISSING,
ERROR_TOO_MANY_ARGS, ERROR_KEY_NEEDS_ARG, ERROR_BAD_NUMBER,
ERROR_BAD_TEMPLATE, ERROR_LINE_TOO_LONG, ERROR_NO_FREE_STORE.

**BEHAVIOR**

A keyword fills its own item; any other item fills the next one that
is free and not /K, /S or /T, and a /M collects all of them. At the end
an empty /A takes the last /M item when the /M has two or more. A lone
'?' at the end of the line (unless RDAF_NOPROMPT) prints the template -
ExtHelp the second time - to Output() and reads the line again from
Input(). The line's end is read; after a failure the rest of the line is
skipped.

**CONTEXT**

- Waits: yes, when it reads Input().
- Interrupts: no.
- Forbid: never under Forbid.
- Process: a Process for Input(); a Task will do with a CSource.

**OWNERSHIP**

Strings, numbers and /M arrays are in the RDArgs' buffer, which the
call allocates (unless RDAF_NOALLOC) and `FreeArgs` frees; the slots
point into it until then. A null `rdargs` makes an RDArgs that
`FreeArgs` frees too.

**BUGS**

None known.

**SEE ALSO**

`FreeArgs`, `ReadItem`, `FindArg`, `StrToLong`

**EXAMPLES**

```zig
var argv = [_]usize{ 0, 0, 0 };
const rda = dos_lib.ReadArgs("FROM/M/A,TO/A,Q=QUIET/S", &argv, null) orelse return dos_lib.IoErr();
defer dos_lib.FreeArgs(rda);
const from: [*]const ?[*:0]const u8 = @ptrFromInt(argv[0]);
```

## ReadItem

Reads the next item of a command line into a buffer.

**SYNOPSIS**

```zig
fn ReadItem(db: *DosBase, buffer: [*]u8, maxchars: i32, csource: ?*dos.CSource) i32
```

**SINCE**

1.0. LVO -464.

**INPUTS**

- `buffer` - where the item goes, ended with a NUL.
- `maxchars` - the buffer's size, the NUL included.
- `csource` - the text to read; null, or one without a buffer, reads
  Input().

**RESULT**

ITEM_UNQUOTED or ITEM_QUOTED with the item in `buffer`; ITEM_NOTHING
at the line's end; ITEM_EQUAL for a '=' where an item should start;
ITEM_ERROR when the item doesn't fit, a quote isn't closed, or
`maxchars` is below 1.

**BEHAVIOR**

Blanks before the item are skipped. An unquoted item ends at a blank,
a '=' or a ';', which starts a comment. In a quoted one "*E" is an
escape, "*N" a newline, and '*' before anything else is that
character. The blank after an item is read; the line's end, a ';' or the
input's end is put back for the next reader.

**CONTEXT**

- Waits: yes, when it reads Input().
- Interrupts: no.
- Forbid: never under Forbid.
- Process: a Process for Input(); a Task will do with a CSource.

**OWNERSHIP**

Nothing is allocated. The buffer and the CSource are the caller's.

**BUGS**

None known.

**SEE ALSO**

`ReadArgs`, `FindArg`

**EXAMPLES**

```zig
var word: [64]u8 = undefined;
var cs: dos.CSource = .{ .buffer = line, .length = line_len };
while (dos_lib.ReadItem(&word, word.len, &cs) > 0) {
    // word holds the next item
}
```

## RemAssignList

Removes one directory from an assign.

**SYNOPSIS**

```zig
fn RemAssignList(db: *DosBase, name: [*:0]const u8, lock: *FileLock) bool
```

**SINCE**

1.0. LVO -332.

**INPUTS**

- `name` - the assign's name, without the colon.
- `lock` - a lock on the directory to remove; any lock that SameLock
  finds the same will do.

**RESULT**

True when the directory was removed. False otherwise, with IoErr set:
ERROR_OBJECT_NOT_FOUND when there is no assign of that name or the
directory isn't one of its, ERROR_OBJECT_WRONG_TYPE for a late or
non-binding assign.

**BEHAVIOR**

The first directory can be removed too: the next one moves up to take
its place. When the last directory goes, the assign goes with it. The
removed directory's own lock - dos's, not `lock` - is unlocked.

**CONTEXT**

- Waits: yes. It takes the device list's lock for writing, and SameLock
  and UnLock send packets.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: a Task will do; only a process gets IoErr.

**OWNERSHIP**

`lock` stays the caller's.

**BUGS**

None known.

**SEE ALSO**

`AssignAdd`, `AssignLock`, `SameLock`

**EXAMPLES**

```zig
const dir = dos_lib.Lock("RAM:c", dos.SHARED_LOCK) orelse return false;
defer dos_lib.UnLock(dir);
_ = dos_lib.RemAssignList("C", dir);
```

## RemDosEntry

Takes a node off the device list.

**SYNOPSIS**

```zig
fn RemDosEntry(db: *DosBase, dlist: *DosList) bool
```

**SINCE**

1.0. LVO -76.

**INPUTS**

- `dlist` - the node.

**RESULT**

True if it was on the list and is off it now; false if it wasn't there.

**BEHAVIOR**

The entry and delete locks (LDF_ENTRY | LDF_DELETE | LDF_WRITE) are
taken for the call, so no handler is being started for the node and
nobody else is removing one. The node's `next` is cleared.

**CONTEXT**

- Waits: yes, for the entry and delete locks.
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do. The caller holds the list with LDF_WRITE.

**OWNERSHIP**

The node is the caller's again, to free with FreeDosEntry or put back.

**BUGS**

None known.

**SEE ALSO**

`AddDosEntry`, `FreeDosEntry`, `LockDosList`

**EXAMPLES**

```zig
const flags = dos.LDF_ASSIGNS | dos.LDF_WRITE;
const list = dos_lib.LockDosList(flags).?;
if (dos_lib.FindDosEntry(list, "WORK", dos.LDF_ASSIGNS)) |node| {
    if (dos_lib.RemDosEntry(node)) dos_lib.FreeDosEntry(node);
}
dos_lib.UnLockDosList(flags);
```

## RemSegment

Takes a user segment nobody runs off the list and frees it.

**SYNOPSIS**

```zig
fn RemSegment(db: *DosBase, seg: *Segment) bool
```

**SINCE**

1.0. LVO -132.

**INPUTS**

- `seg` - the segment, as FindSegment gave it.

**RESULT**

True when removed and freed. False with ERROR_OBJECT_IN_USE when its
seg_UC isn't 0 (a system segment, or a user one in use), or
ERROR_OBJECT_NOT_FOUND when it isn't on the list.

**BEHAVIOR**

Under the list's exclusive lock, the segment is unlinked, a segment
list it was loaded with is unloaded, and its memory freed.

**CONTEXT**

- Waits: yes, for the segment list's semaphore.
- Interrupts: not safe.
- Forbid: not to be held; it may wait.
- Process: a Task will do. Not while holding LockSegmentList, which
  it takes exclusive.

**OWNERSHIP**

On success the segment is gone and `seg` must not be used again.

**BUGS**

None known.

**SEE ALSO**

`AddSegment`, `FindSegment`, `UnLoadSeg`

**EXAMPLES**

```zig
if (!dos_lib.RemSegment(seg)) return dos_lib.IoErr();
```

## Rename

Renames or moves an object on its volume.

**SYNOPSIS**

```zig
fn Rename(db: *DosBase, from: [*:0]const u8, to: [*:0]const u8) bool
```

**SINCE**

1.0. LVO -348.

**INPUTS**

- `from` - the object's name, as for Lock.
- `to` - its new name, which may be in another directory of the same
  volume ("RAM:a" to "RAM:d/b").

**RESULT**

True when the object was renamed. False otherwise, with IoErr set:
ERROR_LINE_TOO_LONG for a name over 255 characters,
ERROR_RENAME_ACROSS_DEVICES when the two names are on different
handlers, ERROR_DEVICE_NOT_MOUNTED for a node with no handler,
ERROR_NO_FREE_STORE when the packet could not be sent, and whatever the
handler answers - ERROR_OBJECT_EXISTS when `to` is already there,
ERROR_OBJECT_NOT_FOUND when `from` isn't.

**BEHAVIOR**

Both names are resolved with GetDeviceProc. `to` is taken in the first
directory of its path, where a new object would be made. `from` is
looked for along its multi-assign: while the handler answers
ERROR_OBJECT_NOT_FOUND and the name is an assign, the next directory is
tried. ACTION_RENAME_OBJECT is sent as (source directory, `from`, target
directory, `to`); the handler strips the device part of each name.

**CONTEXT**

- Waits: yes, for the handler's answer.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: a Task will do; only a process gets IoErr.

**OWNERSHIP**

Nothing is kept. The strings stay the caller's; the handler copies what
it needs.

**BUGS**

None known.

**SEE ALSO**

`Lock`, `DeleteFile`, `GetDeviceProc`

**EXAMPLES**

```zig
if (!dos_lib.Rename("RAM:draft", "RAM:done/final")) {
    _ = dos_lib.PrintFault(dos_lib.IoErr(), "Rename");
}
```

## ReplyPkt

Sends a packet back to its sender with its results.

**SYNOPSIS**

```zig
fn ReplyPkt(db: *DosBase, packet: ?*DosPacket, res1: isize, res2: i32) void
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `packet` - the packet to answer; null does nothing.
- `res1` - dp_Res1, the result.
- `res2` - dp_Res2, the error code when `res1` says it failed.

**RESULT**

Nothing.

**BEHAVIOR**

The packet goes to its dp_Port, the port its sender named, and dp_Port
becomes the running process's msg_port, so the packet carries the way
back to whoever answered it. From a plain task dp_Port is left null.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

The packet is its sender's again.

**BUGS**

None known.

**SEE ALSO**

`WaitPkt`, `SendPkt`

**EXAMPLES**

```zig
dos_lib.ReplyPkt(pkt, dos.DOSTRUE, 0);
```

## RunCommand

Runs a command's code on the calling process, on a stack of its own, with an argument line.

**SYNOPSIS**

```zig
fn RunCommand(db: *DosBase, code: ?*const dos.SegCode, stack_size: u32, args: [*]const u8, length: isize) i32
```

**SINCE**

1.0. LVO -532.

**INPUTS**

- `code` - the code; its `command` is what runs.
- `stack_size` - the stack the command gets, in bytes.
- `args` - the argument line; it should end in a newline, as a
  shell's does, since past it ReadArgs reads Input() itself.
- `length` - how many bytes of `args`; 0 or less for none.

**RESULT**

The command's return code, or -1 with IoErr when it couldn't run:
ERROR_OBJECT_WRONG_TYPE for code without a command, ERROR_NO_PROCESS
from a plain Task, ERROR_NO_FREE_STORE for no memory for the
arguments' copy or the stack.

**BEHAVIOR**

The line is copied and NUL-terminated. While the command runs, the
copy is pr_Arguments (GetArgStr) and is lent to Input()'s buffer as
read-ahead; pr_Result2 starts at 0. The command is called on a stack
of `stack_size` bytes from NewStackRun. Afterwards pr_Arguments and
Input()'s buffer are put back as they were.

**CONTEXT**

- Waits: whatever the command does.
- Interrupts: not safe.
- Forbid: not to be held; the command may wait.
- Process: a Process.

**OWNERSHIP**

The copy of the line and the stack are freed when the command
returns. `code` and `args` stay the caller's. The command frees
whatever it allocates.

**BUGS**

None known.

**SEE ALSO**

`SystemTagList`, `GetArgStr`, `ReadArgs`, `FindSegment`

**EXAMPLES**

```zig
const line = "ram:\n";
const rc = dos_lib.RunCommand(&seg.code, 8192, line, line.len);
if (rc == -1) return dos_lib.IoErr();
```

## SameDevice

Tells whether two locks are on the same device.

**SYNOPSIS**

```zig
fn SameDevice(db: *DosBase, lock1: ?*FileLock, lock2: ?*FileLock) bool
```

**SINCE**

1.0. LVO -400.

**INPUTS**

- `lock1` - one lock.
- `lock2` - the other lock.

**RESULT**

True if they are on one device, false otherwise and if either is null.

**BEHAVIOR**

Two locks are on one device if they are the same lock, name the same
volume, or come from the same handler. Otherwise the two handlers'
device nodes are looked up, and their FileSysStartupMsgs compared: the
same exec device name and unit is one medium under two handlers, read
while the device list stays locked. A node whose startup is a plain
number (RAW:, a window) has no medium to compare. No packet is sent.

**CONTEXT**

- Waits: yes, for the device list (LockDosList, LDF_READ).
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do.

**OWNERSHIP**

Both locks stay the caller's.

**BUGS**

None known.

**SEE ALSO**

`SameLock`, `Info`

**EXAMPLES**

```zig
if (!dos_lib.SameDevice(from, to)) return copyAcross(from, to);
```

## SameLock

Tells whether two locks are on the same object, the same volume, or neither.

**SYNOPSIS**

```zig
fn SameLock(db: *DosBase, lock1: ?*FileLock, lock2: ?*FileLock) i32
```

**SINCE**

1.0. LVO -160.

**INPUTS**

- `lock1` - one lock, or null.
- `lock2` - the other lock, or null.

**RESULT**

LOCK_SAME for one object, LOCK_SAME_VOLUME for two objects on one
volume, LOCK_DIFFERENT otherwise. Two nulls are LOCK_SAME; one null is
LOCK_DIFFERENT.

**BEHAVIOR**

Locks with different volumes or handlers are different without asking
anyone. Otherwise the handler is sent ACTION_SAME_LOCK; a handler that
doesn't know the packet is answered for by comparing the locks' keys. A
lock without a handler port is judged by its key alone. If no packet can
be sent the answer is LOCK_SAME_VOLUME.

**CONTEXT**

- Waits: yes, for the handler's answer to a packet.
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do; a process gets IoErr().

**OWNERSHIP**

Both locks stay the caller's.

**BUGS**

None known.

**SEE ALSO**

`SameDevice`, `Lock`

**EXAMPLES**

```zig
if (dos_lib.SameLock(a, b) == dos.LOCK_SAME) return; // nothing to move
```

## Seek

Moves a file's position.

**SYNOPSIS**

```zig
fn Seek(db: *DosBase, file: ?*FileHandle, position: isize, mode: i32) isize
```

**SINCE**

1.0. LVO -208.

**INPUTS**

- `file` - the handle.
- `position` - the offset, which may be negative.
- `mode` - what it counts from: `OFFSET_BEGINNING`, `OFFSET_CURRENT` or
  `OFFSET_END`.

**RESULT**

The position before the move, or -1 with `IoErr()` set
(`ERROR_INVALID_LOCK`, `ERROR_SEEK_ERROR` from the handler for a place
before the start or past the end, ...).

**BEHAVIOR**

The handle's buffer is flushed first - waiting bytes written, read-ahead
given back - so the handler's position is the caller's. Then
`ACTION_SEEK` moves it. `Seek(fh, 0, OFFSET_CURRENT)` is how the
position is read.

**CONTEXT**

- Waits: yes: it sends the handler a packet and waits for the answer.
- Interrupts: no. It waits.
- Forbid: not taken, and never to be held around it: it waits.
- Process: a Task will do; the answer comes back on a port of its own.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`Read`, `Write`, `SetFileSize`, `Flush`

**EXAMPLES**

```zig
const old = dos_lib.Seek(fh, 0, dos.OFFSET_END);
const size = dos_lib.Seek(fh, old, dos.OFFSET_BEGINNING);
```

## SelectError

Sets the running process's error stream (pr_CES) and returns the one it replaces.

**SYNOPSIS**

```zig
fn SelectError(db: *DosBase, file: ?*FileHandle) ?*FileHandle
```

**SINCE**

1.0. LVO -256.

**INPUTS**

- `file` - the stream errors go to from now on; null for none, so
  that callers fall back to Output().

**RESULT**

The error stream (pr_CES) that was set before, or null if there was
none - or if the caller is a plain Task, which has none to set.

**BEHAVIOR**

Writes `file` into pr_CES of the running process as it is: nothing
is checked, and the old value is only handed back, never closed or
freed.

**CONTEXT**

- Waits: no.
- Interrupts: not safe; it reads and changes the running task's
  Process.
- Forbid: not needed, and not taken; only the running process
  touches these fields.
- Process: a Process for an answer; from a plain Task it does
  nothing and answers null.

**OWNERSHIP**

The process doesn't take `file` over: the caller still closes it,
after putting the old one back.

**BUGS**

None known.

**SEE ALSO**

`ErrorOutput`, `SelectOutput`, `SelectInput`

**EXAMPLES**

```zig
const old = dos_lib.SelectError(log);
defer _ = dos_lib.SelectError(old);
```

## SelectInput

Makes a handle the running process's input.

**SYNOPSIS**

```zig
fn SelectInput(db: *DosBase, file: ?*FileHandle) ?*FileHandle
```

**SINCE**

1.0. LVO -220.

**INPUTS**

- `file` - the new input, or null for none.

**RESULT**

The input it replaces; null when there was none, or when the caller is a
plain Task (and then nothing is set).

**BEHAVIOR**

Sets `pr_CIS`. The old handle is neither closed nor flushed.

**CONTEXT**

- Waits: no.
- Interrupts: no. It reads the running task.
- Forbid: not needed, and not taken.
- Process: a Process; from a plain Task the answer is null and nothing
  changes.

**OWNERSHIP**

The process doesn't take the handle over: whoever opened it still closes
it, after putting the old one back.

**BUGS**

None known.

**SEE ALSO**

`Input`, `SelectOutput`

**EXAMPLES**

```zig
const old = dos_lib.SelectInput(script);
defer _ = dos_lib.SelectInput(old);
```

## SelectOutput

Makes a handle the running process's output.

**SYNOPSIS**

```zig
fn SelectOutput(db: *DosBase, file: ?*FileHandle) ?*FileHandle
```

**SINCE**

1.0. LVO -224.

**INPUTS**

- `file` - the new output, or null for none.

**RESULT**

The output it replaces; null when there was none, or when the caller is
a plain Task (and then nothing is set).

**BEHAVIOR**

Sets `pr_COS`. The old handle is neither closed nor flushed.

**CONTEXT**

- Waits: no.
- Interrupts: no. It reads the running task.
- Forbid: not needed, and not taken.
- Process: a Process; from a plain Task the answer is null and nothing
  changes.

**OWNERSHIP**

The process doesn't take the handle over: whoever opened it still closes
it, after putting the old one back.

**BUGS**

None known.

**SEE ALSO**

`Output`, `SelectInput`

**EXAMPLES**

```zig
const old = dos_lib.SelectOutput(log);
defer _ = dos_lib.SelectOutput(old);
```

## SendPkt

Sends a packet to a handler without waiting for it.

**SYNOPSIS**

```zig
fn SendPkt(db: *DosBase, packet: *DosPacket, port: *MsgPort, reply_port: *MsgPort) void
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `packet` - the packet, its dp_Type and arguments filled in.
- `port` - the handler's port.
- `reply_port` - where the packet comes back to; a process's msg_port
  to take it with `WaitPkt`.

**RESULT**

Nothing.

**BEHAVIOR**

dp_Port and the message's reply port are set to `reply_port`, and the
packet is put on `port`. The handler answers with `ReplyPkt`, which
sends it back to dp_Port.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

The packet is the handler's until it comes back; it must stay valid,
and untouched, until then.

**BUGS**

None known.

**SEE ALSO**

`WaitPkt`, `DoPkt`, `AbortPkt`

**EXAMPLES**

```zig
dos_lib.SendPkt(&pkt, handler_port, &proc.msg_port);
const back = dos_lib.WaitPkt().?;
```

## SetArgStr

Sets the argument line of the calling process, and returns the one before.

**SYNOPSIS**

```zig
fn SetArgStr(db: *DosBase, string: ?[*:0]const u8) ?[*:0]const u8
```

**SINCE**

1.0. LVO -520.

**INPUTS**

- `string` - the new line, or null.

**RESULT**

The previous pr_Arguments; null from a plain task, which changes
nothing.

**BEHAVIOR**

pr_Arguments is set to `string`. A copy CreateNewProc made of
NP_Arguments stays the process's and is freed when it ends, whichever
line is set then; `string` is never freed by dos.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: allowed.
- Process: a process; a plain task changes nothing.

**OWNERSHIP**

`string` stays the caller's, and must outlive its use as the argument
line. The returned line goes back to the caller.

**BUGS**

None known.

**SEE ALSO**

`GetArgStr`, `RunCommand`

**EXAMPLES**

```zig
const old = dos_lib.SetArgStr("-v\n");
defer _ = dos_lib.SetArgStr(old);
```

## SetComment

Sets or removes an object's comment.

**SYNOPSIS**

```zig
fn SetComment(db: *DosBase, name: [*:0]const u8, comment: [*:0]const u8) bool
```

**SINCE**

1.0. LVO -356.

**INPUTS**

- `name` - the object, as for Lock.
- `comment` - the new comment, at most 79 characters; "" removes it.

**RESULT**

True when the handler made the change. False otherwise, with IoErr set:
ERROR_LINE_TOO_LONG for a name over 255 characters,
ERROR_DEVICE_NOT_MOUNTED for a node with no handler, ERROR_NO_FREE_STORE
when the packet could not be sent, or the handler's own answer -
ERROR_OBJECT_NOT_FOUND, ERROR_ACTION_NOT_KNOWN from a handler that
doesn't keep this, ERROR_COMMENT_TOO_BIG for one over 79 characters.

**BEHAVIOR**

ACTION_SET_COMMENT carries the comment's address; the handler copies it
and refuses one that is too long. The name is resolved with
GetDeviceProc and the packet sent as (the directory's lock, `name`, the
value); along a multi-assign each directory is tried in turn while the
object isn't found.

**CONTEXT**

- Waits: yes, for the handler's answer.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: a Task will do; only a process gets IoErr.

**OWNERSHIP**

Nothing is kept by dos. The string stays the caller's.

**BUGS**

None known.

**SEE ALSO**

`Examine`, `Lock`, `Rename`

**EXAMPLES**

```zig
_ = dos_lib.SetComment("RAM:notes", "shopping list");
```

## SetConsoleTask

Sets the running process's console handler's port (pr_ConsoleTask) and returns the one it replaces.

**SYNOPSIS**

```zig
fn SetConsoleTask(db: *DosBase, port: ?*MsgPort) ?*MsgPort
```

**SINCE**

1.0. LVO -268.

**INPUTS**

- `port` - the handler "*" and CONSOLE: go to from now on; null for
  none.

**RESULT**

The console handler's port (pr_ConsoleTask) that was set before, or
null if there was none - or if the caller is a plain Task, which has
none to set.

**BEHAVIOR**

Writes `port` into pr_ConsoleTask of the running process as it is:
nothing is checked, and the old value is only handed back, never
closed or freed.

**CONTEXT**

- Waits: no.
- Interrupts: not safe; it reads and changes the running task's
  Process.
- Forbid: not needed, and not taken; only the running process
  touches these fields.
- Process: a Process for an answer; from a plain Task it does
  nothing and answers null.

**OWNERSHIP**

The port stays its handler's; nothing is counted or held.

**BUGS**

None known.

**SEE ALSO**

`GetConsoleTask`, `GetDeviceProc`

**EXAMPLES**

```zig
const old = dos_lib.SetConsoleTask(window_port);
defer _ = dos_lib.SetConsoleTask(old);
```

## SetCurrentDirName

Sets the running CLI's name for its current directory.

**SYNOPSIS**

```zig
fn SetCurrentDirName(db: *DosBase, name: [*:0]const u8) bool
```

**SINCE**

1.0. LVO -304.

**INPUTS**

- `name` - the new text; it may point into the CLI's own buffer.

**RESULT**

True when it was set. False, with IoErr, when there is no CLI
(ERROR_OBJECT_WRONG_TYPE) or the text doesn't fit
(ERROR_LINE_TOO_LONG).

**BEHAVIOR**

The text is copied into the CLI's own buffer, which holds
CLI_MAX_SET_NAME bytes with the NUL. A text that doesn't fit is
refused whole and the old one kept, rather than stored cut. The name
is only text: it isn't checked against the current directory, and
CurrentDir doesn't change it, so a shell that changes directory sets
both.

**CONTEXT**

- Waits: no.
- Interrupts: not safe; it reads and changes the running task's
  Process.
- Forbid: not needed, and not taken; only the running process
  touches these fields.
- Process: a CLI process; any other caller gets false.

**OWNERSHIP**

The text is copied; `name` stays the caller's.

**BUGS**

None known.

**SEE ALSO**

`GetCurrentDirName`, `CurrentDir`, `NameFromLock`

**EXAMPLES**

```zig
if (dos_lib.NameFromLock(dir, &path, path.len)) _ = dos_lib.SetCurrentDirName(@ptrCast(&path));
```

## SetFileDate

Sets an object's date.

**SYNOPSIS**

```zig
fn SetFileDate(db: *DosBase, name: [*:0]const u8, date: *const dos.DateStamp) bool
```

**SINCE**

1.0. LVO -360.

**INPUTS**

- `name` - the object, as for Lock.
- `date` - the new date, a DateStamp as DateStamp() fills one.

**RESULT**

True when the handler made the change. False otherwise, with IoErr set:
ERROR_LINE_TOO_LONG for a name over 255 characters,
ERROR_DEVICE_NOT_MOUNTED for a node with no handler, ERROR_NO_FREE_STORE
when the packet could not be sent, or the handler's own answer -
ERROR_OBJECT_NOT_FOUND, ERROR_ACTION_NOT_KNOWN from a handler that
doesn't keep this.

**BEHAVIOR**

ACTION_SET_DATE carries the DateStamp's address; the handler copies the
stamp. The name is resolved with GetDeviceProc and the packet sent as
(the directory's lock, `name`, the value); along a multi-assign each
directory is tried in turn while the object isn't found.

**CONTEXT**

- Waits: yes, for the handler's answer.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: a Task will do; only a process gets IoErr.

**OWNERSHIP**

Nothing is kept by dos. The value stays the caller's.

**BUGS**

None known.

**SEE ALSO**

`Examine`, `Lock`, `Rename`

**EXAMPLES**

```zig
var now: dos.DateStamp = undefined;
_ = dos_lib.SetFileDate("RAM:notes", dos_lib.DateStamp(&now));
```

## SetFileSize

Sets the size of an open file.

**SYNOPSIS**

```zig
fn SetFileSize(db: *DosBase, file: ?*FileHandle, offset: isize, mode: i32) isize
```

**SINCE**

1.0. LVO -368.

**INPUTS**

- `file` - the handle.
- `offset` - where the new end is, counted from `mode`.
- `mode` - `OFFSET_BEGINNING`, `OFFSET_CURRENT` or `OFFSET_END`.

**RESULT**

The new size, or -1 with `IoErr()` set (`ERROR_INVALID_LOCK`,
`ERROR_ACTION_NOT_KNOWN` from a handler without the packet, or its own
code).

**BEHAVIOR**

The buffer is flushed first, so waiting bytes are in the file before it
is cut. Then `ACTION_SET_FILE_SIZE` goes to the handler; bytes a grown
file gains are 0.

**CONTEXT**

- Waits: yes: it sends the handler a packet and waits for the answer.
- Interrupts: no. It waits.
- Forbid: not taken, and never to be held around it: it waits.
- Process: a Task will do; the answer comes back on a port of its own.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`Seek`, `Flush`

**EXAMPLES**

```zig
if (dos_lib.SetFileSize(fh, 0, dos.OFFSET_BEGINNING) < 0) return dos_lib.IoErr();
```

## SetFileSysTask

Sets the running process's default file system's port (pr_FileSystemTask) and returns the one it replaces.

**SYNOPSIS**

```zig
fn SetFileSysTask(db: *DosBase, port: ?*MsgPort) ?*MsgPort
```

**SINCE**

1.0. LVO -276.

**INPUTS**

- `port` - the handler lock 0 means from now on; null for none.

**RESULT**

The default file system's port (pr_FileSystemTask) that was set
before, or null if there was none - or if the caller is a plain
Task, which has none to set.

**BEHAVIOR**

Writes `port` into pr_FileSystemTask of the running process as it
is: nothing is checked, and the old value is only handed back, never
closed or freed.

**CONTEXT**

- Waits: no.
- Interrupts: not safe; it reads and changes the running task's
  Process.
- Forbid: not needed, and not taken; only the running process
  touches these fields.
- Process: a Process for an answer; from a plain Task it does
  nothing and answers null.

**OWNERSHIP**

The port stays its handler's; nothing is counted or held.

**BUGS**

None known.

**SEE ALSO**

`GetFileSysTask`, `CurrentDir`

**EXAMPLES**

```zig
const old = dos_lib.SetFileSysTask(disk_port);
defer _ = dos_lib.SetFileSysTask(old);
```

## SetIoErr

Sets the calling process's secondary result, what IoErr() returns.

**SYNOPSIS**

```zig
fn SetIoErr(db: *DosBase, code: i32) i32
```

**SINCE**

1.0. LVO -52.

**INPUTS**

- `code` - the new value, usually an ERROR_* code or 0.

**RESULT**

The value before; 0 from a plain task.

**BEHAVIOR**

pr_Result2 is set. From a plain task nothing is set.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: allowed.
- Process: a process; a plain task changes nothing.

**OWNERSHIP**

Nothing changes hands.

**BUGS**

None known.

**SEE ALSO**

`IoErr`

**EXAMPLES**

```zig
if (argument == null) {
    _ = dos_lib.SetIoErr(dos.ERROR_REQUIRED_ARG_MISSING);
    return false;
}
```

## SetMode

Sets a console's mode.

**SYNOPSIS**

```zig
fn SetMode(db: *DosBase, file: ?*FileHandle, mode: i32) bool
```

**SINCE**

1.0. LVO -476.

**INPUTS**

- `file` - the console's handle.
- `mode` - 1 raw (bytes as typed, no echo or line editing), 0 cooked
  (edited lines).

**RESULT**

True when the console switched. False with `IoErr()` set:
`ERROR_INVALID_LOCK` for a null handle or one without a handler,
`ERROR_NO_FREE_STORE`, or the handler's code (`ERROR_ACTION_NOT_KNOWN`
from one that isn't a console).

**BEHAVIOR**

Bytes waiting in the buffer are written first, so output given before
the switch appears before it. Then `ACTION_SCREEN_MODE` with `mode` goes
to the handler.

**CONTEXT**

- Waits: yes: it sends the handler a packet and waits for the answer.
- Interrupts: no. It waits.
- Forbid: not taken, and never to be held around it: it waits.
- Process: a Task will do; the answer comes back on a port of its own.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

The packet names the mode only, not the handle: a console handler
answers for the window or port it serves, whichever of its handles
asked.

**BUGS**

None known.

**SEE ALSO**

`WaitForChar`, `IsInteractive`

**EXAMPLES**

```zig
if (!dos_lib.SetMode(dos_lib.Input(), 1)) return dos_lib.IoErr();
defer _ = dos_lib.SetMode(dos_lib.Input(), 0);
```

## SetOwner

Sets an object's owner.

**SYNOPSIS**

```zig
fn SetOwner(db: *DosBase, name: [*:0]const u8, owner_info: u32) bool
```

**SINCE**

1.0. LVO -364.

**INPUTS**

- `name` - the object, as for Lock.
- `owner_info` - the owner, the user in the high 16 bits and the group
  in the low 16.

**RESULT**

True when the handler made the change. False otherwise, with IoErr set:
ERROR_LINE_TOO_LONG for a name over 255 characters,
ERROR_DEVICE_NOT_MOUNTED for a node with no handler, ERROR_NO_FREE_STORE
when the packet could not be sent, or the handler's own answer -
ERROR_OBJECT_NOT_FOUND, ERROR_ACTION_NOT_KNOWN from a handler that
doesn't keep this.

**BEHAVIOR**

ACTION_SET_OWNER carries `owner_info` as it is. The name is resolved
with GetDeviceProc and the packet sent as (the directory's lock, `name`,
the value); along a multi-assign each directory is tried in turn while
the object isn't found.

**CONTEXT**

- Waits: yes, for the handler's answer.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: a Task will do; only a process gets IoErr.

**OWNERSHIP**

Nothing is kept by dos. The value stays the caller's.

**BUGS**

None known.

**SEE ALSO**

`Examine`, `Lock`, `Rename`

**EXAMPLES**

```zig
_ = dos_lib.SetOwner("RAM:notes", (uid << 16) | gid);
```

## SetProgramDir

Sets the running process's program directory (pr_HomeDir) and returns the one it replaces.

**SYNOPSIS**

```zig
fn SetProgramDir(db: *DosBase, lock: ?*FileLock) ?*FileLock
```

**SINCE**

1.0. LVO -284.

**INPUTS**

- `lock` - the directory PROGDIR: names from now on; null for none.

**RESULT**

The program directory (pr_HomeDir) that was set before, or null if
there was none - or if the caller is a plain Task, which has none to
set.

**BEHAVIOR**

Writes `lock` into pr_HomeDir of the running process as it is:
nothing is checked, and the old value is only handed back, never
closed or freed.

**CONTEXT**

- Waits: no.
- Interrupts: not safe; it reads and changes the running task's
  Process.
- Forbid: not needed, and not taken; only the running process
  touches these fields.
- Process: a Process for an answer; from a plain Task it does
  nothing and answers null.

**OWNERSHIP**

The process takes `lock` over only in the sense that PROGDIR: uses
it; whoever set it unlocks it after setting the old one back. The
returned lock is the caller's to UnLock (or to restore).

**BUGS**

None known.

**SEE ALSO**

`GetProgramDir`, `UnLock`

**EXAMPLES**

```zig
const old = dos_lib.SetProgramDir(dir);
defer dos_lib.UnLock(dos_lib.SetProgramDir(old));
```

## SetProgramName

Sets the running CLI's command name.

**SYNOPSIS**

```zig
fn SetProgramName(db: *DosBase, name: [*:0]const u8) bool
```

**SINCE**

1.0. LVO -288.

**INPUTS**

- `name` - the new text; it may point into the CLI's own buffer.

**RESULT**

True when it was set. False, with IoErr, when there is no CLI
(ERROR_OBJECT_WRONG_TYPE) or the text doesn't fit
(ERROR_LINE_TOO_LONG).

**BEHAVIOR**

The text is copied into the CLI's own buffer, which holds
CLI_MAX_COMMAND_NAME bytes with the NUL. A text that doesn't fit is
refused whole and the old one kept, rather than stored cut.

**CONTEXT**

- Waits: no.
- Interrupts: not safe; it reads and changes the running task's
  Process.
- Forbid: not needed, and not taken; only the running process
  touches these fields.
- Process: a CLI process; any other caller gets false.

**OWNERSHIP**

The text is copied; `name` stays the caller's.

**BUGS**

None known.

**SEE ALSO**

`GetProgramName`, `SetPrompt`

**EXAMPLES**

```zig
if (!dos_lib.SetProgramName("List")) return error.NameTooLong;
```

## SetPrompt

Sets the running CLI's prompt.

**SYNOPSIS**

```zig
fn SetPrompt(db: *DosBase, name: [*:0]const u8) bool
```

**SINCE**

1.0. LVO -296.

**INPUTS**

- `name` - the new text; it may point into the CLI's own buffer.

**RESULT**

True when it was set. False, with IoErr, when there is no CLI
(ERROR_OBJECT_WRONG_TYPE) or the text doesn't fit
(ERROR_LINE_TOO_LONG).

**BEHAVIOR**

The text is copied into the CLI's own buffer, which holds
CLI_MAX_PROMPT bytes with the NUL. A text that doesn't fit is
refused whole and the old one kept, rather than stored cut.

**CONTEXT**

- Waits: no.
- Interrupts: not safe; it reads and changes the running task's
  Process.
- Forbid: not needed, and not taken; only the running process
  touches these fields.
- Process: a CLI process; any other caller gets false.

**OWNERSHIP**

The text is copied; `name` stays the caller's.

**BUGS**

None known.

**SEE ALSO**

`GetPrompt`, `SetProgramName`

**EXAMPLES**

```zig
_ = dos_lib.SetPrompt("%N.%S> ");
```

## SetProtection

Sets an object's protection bits.

**SYNOPSIS**

```zig
fn SetProtection(db: *DosBase, name: [*:0]const u8, bits: u32) bool
```

**SINCE**

1.0. LVO -352.

**INPUTS**

- `name` - the object, as for Lock.
- `bits` - the protection bits (FIBF_*); the low four (read, write,
  execute, delete) forbid when set.

**RESULT**

True when the handler made the change. False otherwise, with IoErr set:
ERROR_LINE_TOO_LONG for a name over 255 characters,
ERROR_DEVICE_NOT_MOUNTED for a node with no handler, ERROR_NO_FREE_STORE
when the packet could not be sent, or the handler's own answer -
ERROR_OBJECT_NOT_FOUND, ERROR_ACTION_NOT_KNOWN from a handler that
doesn't keep this.

**BEHAVIOR**

ACTION_SET_PROTECT carries the bits as they are, all 32 of them. The
name is resolved with GetDeviceProc and the packet sent as (the
directory's lock, `name`, the value); along a multi-assign each
directory is tried in turn while the object isn't found.

**CONTEXT**

- Waits: yes, for the handler's answer.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: a Task will do; only a process gets IoErr.

**OWNERSHIP**

Nothing is kept by dos. The value stays the caller's.

**BUGS**

None known.

**SEE ALSO**

`Examine`, `Lock`, `Rename`

**EXAMPLES**

```zig
if (!dos_lib.SetProtection("RAM:notes", dos.FIBF_DELETE)) return false; // can't be deleted
```

## SetVBuf

Sets a file handle's buffering and buffer.

**SYNOPSIS**

```zig
fn SetVBuf(db: *DosBase, file: ?*FileHandle, buffer: ?[*]u8, mode: i32, size: isize) i32
```

**SINCE**

1.0. LVO -436.

**INPUTS**

- `file` - the handle.
- `buffer` - the caller's memory for the buffer, or null to have one
  allocated. Not looked at when `size` is -1.
- `mode` - `BUF_LINE` (written out at a line's end on a console),
  `BUF_FULL` (written out when full) or `BUF_NONE` (every byte written
  at once).
- `size` - the buffer's size in bytes, or -1 to keep the buffer and
  change the mode only.

**RESULT**

0, or -1 with `IoErr()` set: `ERROR_INVALID_LOCK` for a null handle,
`ERROR_BAD_NUMBER` for another mode or a size of 0, below -1 or over 32
bits, `ERROR_NO_FREE_STORE`, or what `Flush` failed with.

**BEHAVIOR**

The handle is flushed first: waiting bytes are written, and bytes read
ahead, and pushed-back characters that stand for bytes the file gave,
are given back by seeking over them - on a console, where there is
nothing to seek, they are dropped. Then the mode is set and, unless
`size` is -1, the new buffer put in; a buffer dos had allocated for the
handle is freed. There is no smallest size.

**CONTEXT**

- Waits: only when the buffer has to go to or come from the handler;
  then it sends a packet and waits for the answer.
- Interrupts: no. It may wait.
- Forbid: not taken, and never to be held around it: it may wait.
- Process: a Task will do. One handle is one caller's: two tasks sharing
  a handle take turns themselves.

**OWNERSHIP**

A buffer the caller gives stays the caller's and must outlive the handle
- until `Close`, or a later `SetVBuf`. One allocated here is freed by
`Close`.

**BUGS**

None known.

**SEE ALSO**

`Flush`, `FWrite`, `FGetC`

**EXAMPLES**

```zig
var big: [8192]u8 = undefined;
if (dos_lib.SetVBuf(fh, &big, dos.stdio.BUF_FULL, big.len) < 0) return dos_lib.IoErr();
```

## SetVar

Sets or deletes a local variable or alias, or a global variable.

**SYNOPSIS**

```zig
fn SetVar(db: *DosBase, name: [*:0]const u8, buffer: ?[*]const u8, size: isize, flags: u32) bool
```

**SINCE**

1.0. LVO -492.

**INPUTS**

- `name` - the variable's name.
- `buffer` - its value; null deletes the variable.
- `size` - the value's length in bytes; -1 takes `buffer` as a string
  and counts it.
- `flags` - the type in the low byte (LV_VAR or LV_ALIAS), with
  GVF_GLOBAL_ONLY, GVF_LOCAL_ONLY, GVF_BINARY_VAR and GVF_SAVE_VAR.

**RESULT**

True on success. False otherwise, with IoErr set: ERROR_NO_FREE_STORE,
ERROR_OBJECT_NOT_FOUND when deleting a local variable that isn't there
with GVF_LOCAL_ONLY or deleting an alias that isn't there,
ERROR_OBJECT_WRONG_TYPE for setting a global alias,
ERROR_LINE_TOO_LONG for a global name that makes a path over 255
characters, or the file system's error for a global one.

**BEHAVIOR**

Without GVF_GLOBAL_ONLY, a process's local variable of that name and
type is replaced by a new one (or deleted), kept sorted by name. A null
`buffer` with no local variable goes on to delete the global one, unless
GVF_LOCAL_ONLY. A global variable is the file ENV:name, written whole;
when ENV: is a late assign whose directory is missing, the directory is
made and the write tried again. GVF_SAVE_VAR writes, or deletes,
ENVARC:name too, and a failure there is ignored. A plain task has no
local variables, so it always sets the global one.

**CONTEXT**

- Waits: yes, for a global variable (file system packets); not for a
  local one.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: a Task will do for a global variable; only a process has
  local ones and gets IoErr.

**OWNERSHIP**

dos keeps a copy of the name and value; `buffer` stays the caller's.

**BUGS**

None known.

**SEE ALSO**

`GetVar`, `DeleteVar`, `FindVar`

**EXAMPLES**

```zig
_ = dos_lib.SetVar("Editor", "Ed", -1, dos.LV_VAR | dos.GVF_GLOBAL_ONLY);
```

## SplitName

Copies one component of a path into a buffer.

**SYNOPSIS**

```zig
fn SplitName(db: *DosBase, name: [*:0]const u8, separator: u8, buf: [*]u8, oldpos: i32, size: u32) i32
```

**SINCE**

1.0. LVO -116.

**INPUTS**

- `name` - the path.
- `separator` - the byte between components, '/' or ':'.
- `buf` - where the component goes.
- `oldpos` - where in `name` to start: 0 first, then what the last call
  returned.
- `size` - `buf`'s size, the NUL included.

**RESULT**

The position after the separator, for the next call; -1 when the
component was the last one, when `oldpos` is outside `name`, or when
`size` is 0.

**BEHAVIOR**

The text from `oldpos` up to the next `separator` (or the end) goes to
`buf`, cut to `size` - 1 bytes and ended with a NUL. A cut component
still returns the position after its separator, so the walk goes on.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It reads `name` and writes `buf`.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. Both buffers stay the caller's.

**BUGS**

None known.

**SEE ALSO**

`FilePart`, `PathPart`

**EXAMPLES**

```zig
var part: [32]u8 = undefined;
var pos: i32 = 0;
while (pos >= 0) {
    pos = dos_lib.SplitName("dir/sub/file", '/', &part, pos, part.len);
    // part holds "dir", then "sub", then "file"
}
```

## StrToDate

Reads a date and a time from text into a DateStamp.

**SYNOPSIS**

```zig
fn StrToDate(db: *DosBase, datetime: *dos.DateTime) bool
```

**SINCE**

1.0. LVO -188.

**INPUTS**

- `datetime` - dat_StrDate and dat_StrTime the text to read (a null
  one leaves its part of dat_Stamp as it is), dat_Format the order of
  a date's parts, dat_Flags DTF_FUTURE; dat_Stamp gets the result.

**RESULT**

True with dat_Stamp set; false when a string is no date or time. The
parts read before the failing one may already be set.

**BEHAVIOR**

dat_StrDate is "Today", "Yesterday", "Tomorrow" or a weekday's name,
case ignored, or a date with its parts in dat_Format's order, separated
by '-': the month as a number or as a name (its first three letters
count). A two-digit year is 1978-1999 for 78-99 and 2000-2077 below
that; more digits stand for themselves. A weekday is the one just gone,
or with DTF_FUTURE the one coming; today's own name is a week away
either way. dat_StrTime is "hh:mm" or "hh:mm:ss". The date sets
ds_Days, the time ds_Minute and ds_Tick.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The strings stay the caller's.

**BUGS**

The calendar is right only up to the end of February 2100.

**SEE ALSO**

`DateToStr`, `DateStamp`

**EXAMPLES**

```zig
var dt: dos.DateTime = .{ .format = dos.FORMAT_DOS, .str_date = @constCast("21-Sep-2026"), .str_time = @constCast("12:30") };
if (!dos_lib.StrToDate(&dt)) return false;
```

## StrToLong

Reads a decimal number from the start of a string.

**SYNOPSIS**

```zig
fn StrToLong(_: *DosBase, string: [*:0]const u8, value: *i32) i32
```

**SINCE**

1.0. LVO -472.

**INPUTS**

- `string` - the text.
- `value` - where the number goes.

**RESULT**

How many characters were used, blanks and sign included; -1, with
`value` 0, when there is no digit or the number is beyond an i32.

**BEHAVIOR**

Spaces and tabs are skipped, then an optional '-', then the digits;
reading stops at the first byte that is not a digit. There is no '+'.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It reads `string` and writes `value`.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`ReadArgs`

**EXAMPLES**

```zig
var n: i32 = 0;
if (dos_lib.StrToLong(text, &n) < 0) return dos.ERROR_BAD_NUMBER;
```

## SystemTagList

Runs a command line, or an interactive shell, in a new shell process.

**SYNOPSIS**

```zig
fn SystemTagList(db: *DosBase, command: ?[*:0]const u8, tags: ?[*]const TagItem) i32
```

**SINCE**

1.0. LVO -536.

**INPUTS**

- `command` - the command line, one line or several; null starts an
  interactive shell reading SYS_Input.
- `tags` - SYS_Input, SYS_Output, SYS_Asynch, SYS_UserShell,
  SYS_CustomShell, SYS_Window, SYS_ScriptFile, and CreateNewProc's own
  NP_* tags, which pass through (except the ones that make the process a
  shell: NP_Seglist, NP_Entry, NP_Input, NP_Output, NP_Close*, NP_Cli).

**RESULT**

The shell's last return code, with IoErr its Result2. With SYS_Asynch,
the new CLI's number. -1 when the shell could not start, with IoErr set:
ERROR_OBJECT_NOT_FOUND when there is no such shell, ERROR_OBJECT_IN_USE
for an interactive shell on a console another shell reads,
ERROR_NO_FREE_STORE, or the error of opening a stream.

**BEHAVIOR**

The shell is "BootShell", "shell" with SYS_UserShell, or the resident
SYS_CustomShell names. Its streams are SYS_Input and SYS_Output, by
default the caller's Input() and Output(); a missing one is NIL:.
SYS_Window, when no stream is given, opens that console once and gives
the shell both directions of it, since a console that makes a window
makes one per Open; the shell closes them. Without SYS_Asynch the call
waits for the shell to end; with it the call returns at once, and the
shell closes the streams it was given. SYS_ScriptFile, for an
interactive shell, is read before the input and closed by the shell.

**CONTEXT**

- Waits: yes. It sends packets, and a synchronous start waits for the
  shell to end.
- Interrupts: not callable.
- Forbid: must not be held.
- Process: a Task will do; a process's CLI and current directory are
  passed on, and only a process gets IoErr.

**OWNERSHIP**

Without SYS_Asynch the streams stay the caller's. With SYS_Asynch they
become the shell's, and so does a SYS_ScriptFile. The tag list is
copied.

**BUGS**

None known.

**SEE ALSO**

`Execute`, `CreateNewProc`, `RunCommand`

**EXAMPLES**

```zig
const rc = dos_lib.SystemTagList("dir RAM:", null);
if (rc < 0) _ = dos_lib.PrintFault(dos_lib.IoErr(), "SystemTagList");
```

## UnGetC

Pushes a character back onto a file handle.

**SYNOPSIS**

```zig
fn UnGetC(db: *DosBase, file: ?*FileHandle, character: i32) bool
```

**SINCE**

1.0. LVO -412.

**INPUTS**

- `file` - the handle, or null.
- `character` - the character (its low 8 bits), or -1 for the last one
  `FGetC` gave, the end included.

**RESULT**

True when it was pushed. False for a null handle, when four are already
waiting, when -1 asks for a last character and there is none (nothing
read since the last push or since the handle turned around), or when
bytes waiting to be written couldn't go out. `IoErr()` is only changed
by that last case.

**BEHAVIOR**

The characters wait on a stack of `UNGET_MAX` (4) and come back last in,
first out, before the buffer. The handle is a reading one from then on.

**CONTEXT**

- Waits: only when the buffer has to go to or come from the handler;
  then it sends a packet and waits for the answer.
- Interrupts: no. It may wait.
- Forbid: not taken, and never to be held around it: it may wait.
- Process: a Task will do. One handle is one caller's: two tasks sharing
  a handle take turns themselves.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`FGetC`, `Flush`, `ReadArgs`

**EXAMPLES**

```zig
const c = dos_lib.FGetC(fh);
if (c != '-') _ = dos_lib.UnGetC(fh, -1);
```

## UnLoadSeg

Frees a chain of segments LoadSeg made.

**SYNOPSIS**

```zig
fn UnLoadSeg(db: *DosBase, seg_list: ?*dos.SegList) void
```

**SINCE**

1.0. LVO -548.

**INPUTS**

- `seg_list` - the chain LoadSeg answered; null does nothing.

**RESULT**

None.

**BEHAVIOR**

Each segment is one block, freed with its own size, so the whole chain
goes. Nothing must still run in it.

**CONTEXT**

- Waits: no.
- Interrupts: not callable.
- Forbid: not needed, and not taken.
- Process: a Task will do.

**OWNERSHIP**

The chain is gone after the call.

**BUGS**

None known.

**SEE ALSO**

`LoadSeg`

**EXAMPLES**

```zig
dos_lib.UnLoadSeg(seg);
```

## UnLock

Gives a lock back to the handler that made it.

**SYNOPSIS**

```zig
fn UnLock(db: *DosBase, lock: ?*FileLock) void
```

**SINCE**

1.0. LVO -148.

**INPUTS**

- `lock` - the lock, from Lock, DupLock, CreateDir, ParentDir and the
  like; null is allowed.

**RESULT**

None.

**BEHAVIOR**

The lock's handler is sent ACTION_FREE_LOCK. A null lock, or one without
a handler port, does nothing. IoErr() is the same afterwards as before,
so UnLock can go in a cleanup path without hiding the error that led
there.

**CONTEXT**

- Waits: yes, for the handler's answer to a packet.
- Interrupts: no.
- Forbid: must not be held.
- Process: a Task will do; a process gets IoErr().

**OWNERSHIP**

The lock is gone afterwards; the handler frees it.

**BUGS**

None known.

**SEE ALSO**

`Lock`, `DupLock`

**EXAMPLES**

```zig
dos_lib.UnLock(dos_lib.CurrentDir(old));
```

## UnLockDosList

Unlocks what LockDosList or AttemptLockDosList locked.

**SYNOPSIS**

```zig
fn UnLockDosList(db: *DosBase, flags: u32) void
```

**SINCE**

1.0. LVO -64.

**INPUTS**

- `flags` - the flags the list was locked with.

**RESULT**

None.

**BEHAVIOR**

Each semaphore the flags select is released once. The LDF_READ/LDF_WRITE
bits are not looked at.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Forbid: allowed.
- Process: a Task will do; the task that locked the list.

**OWNERSHIP**

The locks go; nothing else changes hands.

**BUGS**

None known.

**SEE ALSO**

`LockDosList`, `AttemptLockDosList`

**EXAMPLES**

```zig
dos_lib.UnLockDosList(dos.LDF_ALL | dos.LDF_READ);
```

## UnLockSegmentList

Unlocks the resident segment list.

**SYNOPSIS**

```zig
fn UnLockSegmentList(db: *DosBase) void
```

**SINCE**

1.0. LVO -140.

**INPUTS**

None.

**RESULT**

None.

**BEHAVIOR**

Releases the semaphore LockSegmentList obtained; each
LockSegmentList wants one UnLockSegmentList.

**CONTEXT**

- Waits: no.
- Interrupts: not safe.
- Forbid: not needed.
- Process: the Task that locked it.

**OWNERSHIP**

Segments found under the lock may not be used after it, unless their
seg_UC was raised.

**BUGS**

None known.

**SEE ALSO**

`LockSegmentList`

**EXAMPLES**

```zig
_ = dos_lib.LockSegmentList(true);
defer dos_lib.UnLockSegmentList();
```

## VFPrintf

Writes formatted text to a file.

**SYNOPSIS**

```zig
fn VFPrintf(db: *DosBase, file: ?*FileHandle, format: [*:0]const u8, args: ?*const anyopaque) i32
```

**SINCE**

1.0. LVO -440.

**INPUTS**

- `file` - the handle.
- `format` - the format: RawDoFmt's (`%d %u %x %c` for 32-bit values,
  `%ld` for 64, `%s` for a string).
- `args` - the values, packed as RawDoFmt's data stream;
  `sdk.dos.stdio.FPrintf` packs them from a tuple.

**RESULT**

The number of bytes written, or -1 when a write failed (`IoErr()` as for
`FPutC`).

**BEHAVIOR**

exec's `RawDoFmt` does the formatting and each character goes out
through `FPutC`. The NUL the format ends with is not written. After a
failed write the rest is formatted and dropped.

**CONTEXT**

- Waits: only when the buffer has to go to or come from the handler;
  then it sends a packet and waits for the answer.
- Interrupts: no. It may wait.
- Forbid: not taken, and never to be held around it: it may wait.
- Process: a Task will do. One handle is one caller's: two tasks sharing
  a handle take turns themselves.

**OWNERSHIP**

Nothing is allocated beyond the handle's buffer.

**BUGS**

None known.

**SEE ALSO**

`VPrintf`, `FPuts`, `RawDoFmt`

**EXAMPLES**

```zig
const stream = sdk.exec.fmtStream(.{ count, name });
_ = dos_lib.VFPrintf(fh, "%d files in %s\n", &stream);
```

## VPrintf

Writes formatted text to the process's output.

**SYNOPSIS**

```zig
fn VPrintf(db: *DosBase, format: [*:0]const u8, args: ?*const anyopaque) i32
```

**SINCE**

1.0. LVO -444.

**INPUTS**

- `format` - the format, as for `VFPrintf`.
- `args` - the values, packed as RawDoFmt's data stream;
  `sdk.dos.stdio.Printf` packs them from a tuple.

**RESULT**

As `VFPrintf`: the bytes written, or -1. -1 with `ERROR_INVALID_LOCK`
from a Task or a process without output.

**BEHAVIOR**

`VFPrintf` to `Output()`.

**CONTEXT**

- Waits: only when the buffer has to go to or come from the handler;
  then it sends a packet and waits for the answer.
- Interrupts: no. It may wait.
- Forbid: not taken, and never to be held around it: it may wait.
- Process: a Task will do. One handle is one caller's: two tasks sharing
  a handle take turns themselves.

**OWNERSHIP**

Nothing is allocated beyond the output's buffer.

**BUGS**

None known.

**SEE ALSO**

`VFPrintf`, `PutStr`, `Output`

**EXAMPLES**

```zig
const stream = sdk.exec.fmtStream(.{code});
_ = dos_lib.VPrintf("error %d\n", &stream);
```

## WaitForChar

Tells whether a console has input within a time.

**SYNOPSIS**

```zig
fn WaitForChar(db: *DosBase, file: ?*FileHandle, timeout: isize) bool
```

**SINCE**

1.0. LVO -480.

**INPUTS**

- `file` - the console's handle.
- `timeout` - how long to wait, in microseconds; 0 only asks.

**RESULT**

True when there is input to read. False when the time ran out, or on an
error with `IoErr()` set (`ERROR_INVALID_LOCK`, `ERROR_NO_FREE_STORE`,
or the handler's code).

**BEHAVIOR**

Bytes the handle already holds - read ahead or pushed back - answer true
at once. Otherwise `ACTION_WAIT_CHAR` goes to the handler, which answers
when input comes or the time is up. In cooked mode input means a whole
line.

**CONTEXT**

- Waits: yes: up to `timeout`, for the handler's answer.
- Interrupts: no. It waits.
- Forbid: not taken, and never to be held around it: it waits.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

The packet names the time only, not the handle: a console handler
answers for the window or port it serves.

**BUGS**

None known.

**SEE ALSO**

`SetMode`, `FGetC`, `Read`

**EXAMPLES**

```zig
if (dos_lib.WaitForChar(dos_lib.Input(), 50_000)) {
    const c = dos_lib.FGetC(dos_lib.Input());
    _ = c;
}
```

## WaitPkt

Waits for a packet at the running process's msg_port and takes it off.

**SYNOPSIS**

```zig
fn WaitPkt(db: *DosBase) ?*DosPacket
```

**SINCE**

1.0. LVO -28.

**INPUTS**

None.

**RESULT**

The packet; null from a plain task, which has no msg_port.

**BEHAVIOR**

Through the process's pr_PktWait when it has one, so a process that
routes its port itself decides what counts as the next packet;
otherwise the next message at msg_port, waiting for one.

**CONTEXT**

- Waits: yes.
- Interrupts: no.
- Forbid: never under Forbid.
- Process: a Process; a Task gets null.

**OWNERSHIP**

The packet is the caller's again: one it sent has come back, one it
received is its to answer with `ReplyPkt`.

**BUGS**

None known.

**SEE ALSO**

`SendPkt`, `ReplyPkt`

**EXAMPLES**

```zig
while (dos_lib.WaitPkt()) |pkt| {
    dos_lib.ReplyPkt(pkt, dos.DOSFALSE, dos.ERROR_ACTION_NOT_KNOWN);
}
```

## Write

Writes `length` bytes to a file.

**SYNOPSIS**

```zig
fn Write(db: *DosBase, file: ?*FileHandle, buffer: [*]const u8, length: isize) isize
```

**SINCE**

1.0. LVO -204.

**INPUTS**

- `file` - the handle to write to.
- `buffer` - the bytes.
- `length` - how many.

**RESULT**

The number of bytes written, or -1 with `IoErr()` set
(`ERROR_INVALID_LOCK`, `ERROR_NO_FREE_STORE`, or the handler's code,
e.g. `ERROR_DISK_FULL`). A count below `length` is what the handler
managed.

**BEHAVIOR**

The handle is made ready first: bytes waiting in its buffer are written
out, and bytes read ahead are given back by seeking over them, so the
write lands where the caller's position is. A console keeps what it read
ahead, since it has no position to give back. Then one `ACTION_WRITE`
carries the bytes.

**CONTEXT**

- Waits: yes: it sends the handler a packet and waits for the answer.
- Interrupts: no. It waits.
- Forbid: not taken, and never to be held around it: it waits.
- Process: a Task will do; the answer comes back on a port of its own.

**OWNERSHIP**

Nothing is allocated. The bytes stay the caller's.

**BUGS**

None known.

**SEE ALSO**

`Read`, `FWrite`, `Flush`

**EXAMPLES**

```zig
const text = "hello\n";
if (dos_lib.Write(fh, text, text.len) != text.len) return dos_lib.IoErr();
```

## WriteChars

Writes bytes to the process's output.

**SYNOPSIS**

```zig
fn WriteChars(db: *DosBase, buffer: [*]const u8, length: isize) isize
```

**SINCE**

1.0. LVO -452.

**INPUTS**

- `buffer` - the bytes.
- `length` - how many.

**RESULT**

As `FWrite`: `length`, or -1 with `IoErr()` set (`ERROR_INVALID_LOCK`
from a Task or a process without output).

**BEHAVIOR**

`FWrite` to `Output()`, through its buffer.

**CONTEXT**

- Waits: only when the buffer has to go to or come from the handler;
  then it sends a packet and waits for the answer.
- Interrupts: no. It may wait.
- Forbid: not taken, and never to be held around it: it may wait.
- Process: a Task will do. One handle is one caller's: two tasks sharing
  a handle take turns themselves.

**OWNERSHIP**

Nothing is allocated. The bytes stay the caller's.

**BUGS**

None known.

**SEE ALSO**

`FWrite`, `PutStr`, `Output`

**EXAMPLES**

```zig
const word = "ok";
_ = dos_lib.WriteChars(word, word.len);
```
