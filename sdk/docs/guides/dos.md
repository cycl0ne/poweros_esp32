# Files and processes: dos.library

dos.library gives a program files, directories and the names they are
found by, reads a command's arguments, and starts processes and shells.
It stores nothing itself: every name leads to a handler, a process that
serves one device - a file system, a console, a pipe - and dos turns
each call into a packet for it. The guide goes from what a command uses
most (files, names, locks, patterns, arguments, errors) to processes,
variables, the device list and the handlers underneath. Every call is in
the [reference](../autodocs/dos.md), the structures and constants are in
`sdk/libs/dos/`, and [Writing programs](programs.md) builds a whole
command, from `build.zig` to the shell.

- [The layers](#the-layers)
- [Files](#files)
- [Buffered reading and writing](#buffered-reading-and-writing)
- [Names and paths](#names-and-paths)
- [Locks and directories](#locks-and-directories)
- [Patterns](#patterns)
- [Command arguments](#command-arguments)
- [Errors, return codes and Ctrl-C](#errors-return-codes-and-ctrl-c)
- [Processes](#processes)
- [Running commands and shells](#running-commands-and-shells)
- [Variables](#variables)
- [Being told of a change](#being-told-of-a-change)
- [The device list and assigns](#the-device-list-and-assigns)
- [Handlers and packets](#handlers-and-packets)
- [Disks at boot](#disks-at-boot)
- [Consoles](#consoles)

The examples are pieces of a command whose `_program_entry` has opened
the library as `dl`, as in
[Hello, world - in the shell](programs.md#hello-world---in-the-shell),
with `dos`, `exec`, `rdargs`, `Printf` and `TagItem` standing for
`sdk.dos`, `sdk.exec`, `sdk.dos.rdargs`, `sdk.dos.stdio.Printf` and
`sdk.utility.TagItem`, and `ExecBase` and `DosBase` for
`sdk.interface.exec.ExecBase` and `sdk.interface.dos.DosBase`.

## The layers

```
 program        Open, Read, Lock, MatchFirst, ReadArgs, CreateNewProc ...
    |
 dos.library    names to handlers, buffers, processes, the device list
    |  DosPacket (ACTION_FINDINPUT, ACTION_READ, ACTION_LOCATE_OBJECT ...)
 handler        flashfs-handler (DH0:), fat-handler (SD0:), ram-handler,
    |           con-handler (CON:, RAW:, AUX:), pipe-handler, nil-handler
 exec device    flash.device, sdcard.device, console.device, serial.device
```

Names are C strings, locks and file handles are pointers, and the sizes
in a `FileInfoBlock`, an `ExAllData` record and an `InfoData` are 64-bit.

A process is a task that dos knows: it has a port for packets, a current
directory, an input and an output, local variables, and the error code
`IoErr()` reads. A command runs on its shell's process. Many calls work
from a plain task too, which has none of those; each call's CONTEXT in
the reference says which.

## Files

`Open(name, mode)` answers a `FileHandle`, or null with the reason in
`IoErr()`. `MODE_OLDFILE` opens an existing file, `MODE_NEWFILE` a new
one or an existing one emptied, `MODE_READWRITE` an existing one or a new
one, shared with others. `Read` and `Write` move bytes, one packet each:
`Read` answers how many it read, 0 at the end and -1 on an error; `Write`
how many were written, or -1. `Seek(fh, position, mode)` counts from
`OFFSET_BEGINNING`, `OFFSET_CURRENT` or `OFFSET_END` and answers the
position before the move, so `Seek(fh, 0, OFFSET_CURRENT)` reads where
the file is. `Close` gives the handle back, once, even when it answers
false.

```zig
/// One file into another, a kilobyte at a time.
fn copyFile(dl: *DosBase, from_name: [*:0]const u8, to_name: [*:0]const u8) bool {
    const from = dl.Open(from_name, dos.MODE_OLDFILE) orelse return false;
    defer _ = dl.Close(from);
    const to = dl.Open(to_name, dos.MODE_NEWFILE) orelse return false;
    var buffer: [1024]u8 = undefined;
    while (true) {
        const got = dl.Read(from, &buffer, buffer.len);
        if (got == 0) return dl.Close(to);
        if (got < 0 or dl.Write(to, &buffer, got) != got) {
            _ = dl.Close(to); // IoErr keeps the Read's or Write's reason
            return false;
        }
    }
}
```

A console answers a `Read` with what has been typed, which can be fewer
bytes than asked without being the end. `OpenFromLock`, `DupLockFromFH`,
`ParentOfFH`, `ExamineFH` and `NameFromFH` lead from a lock to an open
file and back; `SetFileSize` cuts or grows a file.

## Buffered reading and writing

Each handle has a buffer, allocated on its first buffered call
(`dos.stdio.BUFFER_SIZE`, 1024 bytes), and the buffered calls send a
packet only when it is empty or full. They read with `FGetC`, `UnGetC`
(up to four characters pushed back), `FGets` (a line, its newline kept)
and `FRead`, and write with `FPutC`, `FPuts`, `FWrite` and `VFPrintf`;
`PutStr`, `WriteChars` and `VPrintf` write to `Output()`.

`dos.stdio` packs a format's values: `Printf(dl, format, .{...})` writes
to `Output()`, `FPrintf(dl, fh, format, .{...})` to a file. The format is
RawDoFmt's, checked when the program is compiled: `%d %u %x %c` take
values of up to 32 bits, `%ld %lu %lx` 64-bit ones, `%s` a
NUL-terminated string.

```zig
// Every line of a file, numbered.
const fh = dl.Open(name, dos.MODE_OLDFILE) orelse return dos.RETURN_ERROR;
defer _ = dl.Close(fh);
var line: [256]u8 = undefined;
var count: u32 = 0;
while (dl.FGets(fh, &line, line.len)) |text| {
    count += 1;
    _ = Printf(dl, "%4u %s", .{ count, @as([*:0]const u8, @ptrCast(text)) });
}
```

Every handle starts in `BUF_LINE`: written out at each newline on a console,
when the buffer is full on anything else. `SetVBuf` picks `BUF_FULL` or
`BUF_NONE` instead, and can give the handle a buffer of the caller's.
`Flush` writes out what waits and gives back what was read ahead. `Close`,
`Seek`, `Read` and `Write` take what the buffer holds into account
themselves, so buffered and unbuffered calls mix on one handle. A prompt
without a newline needs `Flush(Output())` to be seen.

`Input()` and `Output()` are the process's streams: for a command, its
shell's console, or what `<` and `>` named on its line. They belong to
the process, and a program never closes them. `SelectInput` and
`SelectOutput` put others in their place and answer the old ones, to be
put back; `SelectError` and `ErrorOutput` set and give an error stream.
`IsInteractive` tells whether a handle is a console.

## Names and paths

Before a colon is a device, a volume or an assign; after it, a path
whose parts are separated by `/`. `DH0:c/Dir` starts at the root of the
device DH0:, `System:c/Dir` at the same root by the name of the volume
in it, `C:Dir` in the directory the assign C: stands for. `:c/Dir` starts
at the root of the current directory's volume, `c/Dir` in the current
directory, and `/Dir` in its parent, each further `/` one more level up.
`*` and `CONSOLE:` are the process's console, and `PROGDIR:` the
directory the running program was loaded from.

Names are compared without regard to case. A file's or directory's name
is at most `dos.name_max` (255) bytes, a whole path `dos.path_max`
(1024), and a device, volume or assign name `dos.MAX_DEVICE_NAME` (30)
characters.

| Name | What it is |
|---|---|
| `DH0:` | the flash disk's partition, volume `System` |
| `SD0:` | the card in the slot, FAT32 or exFAT, once `Mount SD0:` has run |
| `RAM:` | a file system in memory, volume `Ram Disk` |
| `CON:`, `RAW:`, `AUX:` | [consoles](#consoles) |
| `PIPE:` | pipes: `PIPE:name` meets whoever opens the same name |
| `NIL:` | swallows what is written and reads as empty |
| `SYS:` | the partition the system started from |
| `C:`, `S:`, `DEVS:`, `HANDLERS:` | `SYS:c`, `SYS:s`, `SYS:devs`, `SYS:devs/handlers` |
| `LIBS:`, `FONTS:` | `SYS:libs` and `SYS:classes`; `SYS:fonts` |
| `ENV:`, `ENVARC:`, `T:`, `CLIPS:` | the running variables (`RAM:ENV`), the kept ones (`SYS:Prefs/Env-Archive`), work files (`RAM:T`), the clipboard's units (`RAM:Clipboards`) |

dos makes `SYS:`, `C:`, `S:`, `LIBS:`, `DEVS:` and `HANDLERS:` at boot;
`S:Startup-Sequence` makes the others.

The path calls work on strings and send no packet. `AddPart(dirname,
filename, size)` adds a name to a path in the caller's buffer of `size`
bytes, with a `/` where one is needed - `SYS:c` and `Dir` make
`SYS:c/Dir` - and a name with a colon replaces the path. `FilePart`
points at a path's last part, `PathPart` at where its directory part
ends, `SplitName` takes a path apart a part at a time, and `ParsePath`
splits off the device or volume into a `ParsedPath`.

The current directory is a lock. `CurrentDir(lock)` makes `lock` the
process's current directory and answers the one before. Neither is
copied or unlocked: the caller puts the old one back with another
`CurrentDir`, and unlocks its own once it is no longer current.
`NameFromLock` writes any lock's full name, volume first
(`Ram Disk:notes`); `GetCurrentDirName` gives the shell's name for its
current directory.

## Locks and directories

A lock holds on to a file or directory without opening it.
`Lock(name, SHARED_LOCK)` lets others lock it too; `EXCLUSIVE_LOCK`
keeps them out. The handler makes the lock, and `UnLock` gives it back,
once for every lock. `DupLock` makes another shared lock on the same
object, `ParentDir` one on the directory it is in (null at the root),
and `SameLock` tells whether two locks are on one object or one volume.

`CreateDir(name)` makes a directory and answers an exclusive lock on
it, to be unlocked. `DeleteFile(name)` deletes a file or an empty
directory, `Rename(from, to)` renames or moves within one volume
(`ERROR_RENAME_ACROSS_DEVICES` otherwise), and `SetProtection`,
`SetComment`, `SetFileDate` and `SetOwner` change the rest. Of the
`FIBF_*` protection bits the low four (`FIBF_DELETE`, `FIBF_EXECUTE`,
`FIBF_WRITE`, `FIBF_READ`) forbid what they name when set; `FIBF_SCRIPT`
marks a file the shell runs as a script. `Info(lock, &data)` fills an
`InfoData` about the volume: block counts, block size, state.

`Examine(lock, &fib)` fills a `FileInfoBlock` about the locked object.
On a directory, `ExNext` with the same lock and block then gives each
entry in turn, and false at the end, with `IoErr()`
`ERROR_NO_MORE_ENTRIES`.

| Field | Holds |
|---|---|
| `file_name` | the name, NUL-terminated |
| `dir_entry_type` | above 0 a directory, below 0 a file (`ST_USERDIR`, `ST_FILE`, ...) |
| `size`, `num_blocks` | its size in bytes and in blocks, 64-bit |
| `protection` | the `FIBF_*` bits |
| `date` | when it last changed, a `DateStamp` (`DateToStr` makes it text) |
| `comment` | up to 79 characters, NUL-terminated |

```zig
const dir = dl.Lock("SYS:c", dos.SHARED_LOCK) orelse return dos.RETURN_ERROR;
defer dl.UnLock(dir);
var fib: dos.FileInfoBlock = .{};
if (!dl.Examine(dir, &fib)) return dos.RETURN_ERROR;
while (dl.ExNext(dir, &fib)) {
    const kind: [*:0]const u8 = if (fib.dir_entry_type > 0) "dir" else "file";
    _ = Printf(dl, "%s %s %lu\n", .{ @as([*:0]const u8, @ptrCast(&fib.file_name)), kind, fib.size });
}
if (dl.IoErr() != dos.ERROR_NO_MORE_ENTRIES) return dos.RETURN_ERROR;
```

`ExAll(lock, buffer, size, level, &control)` reads many entries per call
into the caller's buffer, as `ExAllData` records chained by `next`, with
the fields of the level asked for (`ED_NAME` up to `ED_OWNER`). It
answers true while more are to come, with `control.entries` records this
time. The `ExAllControl` starts cleared, keeps the place, and can choose
entries by a pattern (`match_string`, from utility.library's
`ParsePatternNoCase`) or a hook (`match_func`); `ExAllEnd` stops a
listing before its end.

## Patterns

`MatchFirst(pattern, &anchor)` and then `MatchNext(&anchor)` find each
object a pattern names, one at a time; `MatchEnd` frees what the search
holds, whatever the last answer was. The pattern's device part is taken
as it stands; the rest is utility.library's pattern syntax (`#?` any
text, `?` one character, `(a|b)`, `~`, `[a-z]`; see the
[utility guide](utility.md#patterns)), matched without regard to case, one
directory level after another: `SYS:c/#?`, `RAM:#?/#?.txt`.

The `AnchorPath` is the search's state, cleared before `MatchFirst`
apart from three fields. `break_bits` are signals that stop the search
with `ERROR_BREAK`. `strlen` is the size of a buffer that follows the
AnchorPath directly in memory, for each entry's full path; with 0 there
is none, and `info.file_name` is the name alone, in the directory of
`last.lock`. `APF_DODIR` set in `flags` makes the next `MatchNext` go
into the directory it has found, which comes once more, with
`APF_DIDDIR` set, when it is done. `APF_ITSWILD` says whether the
pattern had a wildcard.

Each answer is 0, with the entry in `info`, or an error:
`ERROR_NO_MORE_ENTRIES` at the end, or a plain name's own error
(`ERROR_OBJECT_NOT_FOUND`) when it is not there. After
`ERROR_BUFFER_OVERFLOW` (the path was cut to fit) the search goes on;
any other error ends it.

```zig
const Anchor = extern struct {
    ap: dos.AnchorPath = .{},
    path: [dos.path_max]u8 = @splat(0), // right after the AnchorPath
};

var anchor: Anchor = .{};
anchor.ap.strlen = anchor.path.len;
anchor.ap.break_bits = exec.SIGBREAKF_CTRL_C;
var rc = dl.MatchFirst("RAM:#?.txt", &anchor.ap);
while (rc == 0) : (rc = dl.MatchNext(&anchor.ap)) {
    if (anchor.ap.info.dir_entry_type < 0) _ = Printf(dl, "%s\n", .{@as([*:0]const u8, @ptrCast(&anchor.path))});
}
dl.MatchEnd(&anchor.ap);
if (rc != dos.ERROR_NO_MORE_ENTRIES) _ = dl.PrintFault(rc, "RAM:#?.txt");
```

## Command arguments

A command reads its arguments with `ReadArgs(template, &argv, null)`.
The template lists the items, separated by commas, each a keyword with
its options:

| Option | The item is |
|---|---|
| none | a word, by its place on the line or after its keyword |
| `/A` | required |
| `/K` | given only after its keyword: `TO RAM:x` |
| `/S`, `/T` | a switch, the keyword alone; a toggle, `YES`, `NO`, `ON` or `OFF` after it |
| `/N` | a number |
| `/M` | any number of words |
| `/F` | the rest of the line, as it stands |
| `=` | an alias: `Q=QUIET/S` |

Each item has one pointer-sized slot in `argv`, set by the caller to its
default, which an item not given keeps. A slot holds a string, the
address of an `i32` (/N), `DOSTRUE` or 0 (/S, /T), or the address of a
null-terminated array (/M). `dos.rdargs` reads them: `string(slot)` and
`number(slot)` answer null for an item not given, `multi(slot)` the
strings of a /M. They live in memory ReadArgs allocated, so `FreeArgs`
comes after the last use of a slot.

```zig
const template = "FROM/M/A,TO/K,LINES/K/N,QUIET/S";
var argv: [4]usize = @splat(0);
const rda = dl.ReadArgs(template, &argv, null) orelse {
    _ = dl.PrintFault(dl.IoErr(), "Head");
    return dos.RETURN_FAIL;
};
defer dl.FreeArgs(rda);
const lines: i32 = rdargs.number(argv[2]) orelse 10;
const quiet = argv[3] != 0;
for (rdargs.multi(argv[0])) |name| {
    if (!quiet) _ = Printf(dl, "%s: %d lines\n", .{ name, lines });
}
```

The shell hands a command the rest of its line as the first bytes of
`Input()`, and ReadArgs reads it from there; `GetArgStr()` is the line
itself. A lone `?` prints the template and reads the line again. With
`FROM/M,TO/A` the last word fills `TO` when no `TO` keyword came, so
`Copy a b RAM:` reads as it looks. To parse text of its own, a program
passes an `RDArgs` from `AllocDosObject(DOS_RDARGS)` with the text in
its `source` (a `CSource`). The commands in `src/disk/c/` all start this
way: a `template` constant, an `arg_<name>` constant for each slot, and
`PrintFault` with the command's name when ReadArgs fails.

## Errors, return codes and Ctrl-C

A call that fails answers null, false or -1 and leaves the reason in
`IoErr()`, an `ERROR_*` code from `sdk/libs/dos/dos.zig`. Many calls
that succeed set it too - every packet's second result lands there - so
it is read right after the call it belongs to. `SetIoErr` sets it, for
the shell to see once the command has returned. `Fault(code, header,
buffer, len)` writes a code's text into a buffer; `PrintFault(code,
header)` writes it to `Output()` with a newline (`RAM:x: object not
found`) and leaves `IoErr()` at the code.

A command returns `RETURN_OK` (0) when it is done, `RETURN_WARN` (5)
when it is done with something to say - nothing matched, Ctrl-C stopped
it - `RETURN_ERROR` (10) when it failed, and `RETURN_FAIL` (20) when it
could not run at all. The shell keeps the code in the local variable
`RC` and `IoErr()` in `Result2`, and a script stops at a code at or above
the shell's fail level (`FailAt`, 10 to start with).

Ctrl-C typed at a console raises `exec.SIGBREAKF_CTRL_C` in the process
that last read from it and the one that last wrote to it; Ctrl-D to
Ctrl-F raise the other three. `CheckSignal(mask)` answers which have
come and clears them, without waiting. A long loop asks once a round:

```zig
if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
    _ = dl.PrintFault(dos.ERROR_BREAK, null); // "***Break"
    return dos.RETURN_WARN;
}
```

## Processes

`CreateNewProc(tags)` starts a process running a `TaskFn`,
`fn (sys: *ExecBase) callconv(.c) void`:

| Tag | Gives |
|---|---|
| `NP_Entry` | the function; required |
| `NP_Name`, `NP_Priority` | its name, copied (default `New Process`); its priority (default the caller's) |
| `NP_StackSize` | its stack in bytes (default 8192, at least 1024) |
| `NP_UserData` | a pointer it finds as `FindTask(null).?.user_data` |
| `NP_Input`, `NP_Output`, `NP_Error` | its streams (default none), the first two closed at its end unless `NP_CloseInput`, `NP_CloseOutput` say false |
| `NP_CurrentDir`, `NP_HomeDir` | locks it takes over (default copies of the caller's) |
| `NP_Cli` | a CLI of its own, with the caller's prompt and command path |
| `NP_Affinity` | the cores it runs on: `exec.TF_CORE0`, `exec.TF_CORE1`, or 0 for either |
| `NP_EndMsg`, `NP_HoldLibrary` | a message replied once it is gone; a library open count dos closes after its code has returned |

**The code a process runs must stay loaded until the process is gone.**
The shell unloads a program when it returns, so a program that starts a
process on one of its own functions waits for that process first:
`NP_EndMsg` has a message replied once nothing runs on the process's
stack any more ([When the code goes](programs.md#when-the-code-goes)).

```zig
const Job = struct { done: u32 = 0 };

fn worker(sys: *ExecBase) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(sys.FindTask(null).?.user_data.?));
    job.done += 1; // the work
}

// In _program_entry:
const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
defer sys.DeleteMsgPort(port);
var ended: exec.Message = .{ .reply_port = port };
var job: Job = .{};
_ = dl.CreateNewProc(&[_]TagItem{
    .{ .tag = dos.NP_Entry, .data = @intFromPtr(&worker) },
    .{ .tag = dos.NP_Name, .data = @intFromPtr("worker") },
    .{ .tag = dos.NP_UserData, .data = @intFromPtr(&job) },
    .{ .tag = dos.NP_EndMsg, .data = @intFromPtr(&ended) },
    .{},
}) orelse return dos.RETURN_FAIL;
_ = sys.WaitPort(port); // the worker is gone, and its code may go
_ = sys.GetMsg(port);
```

## Running commands and shells

`SystemTagList(command, tags)` runs a command line in a new shell
process, with everything the shell does to a line - the command path,
`<` and `>`, pipes, variables - and waits for it. It answers the last
return code, with `IoErr()` its `Result2`, or -1 when the shell could
not start. `SYS_Input` and `SYS_Output` give the shell's streams
(default the caller's), `SYS_Window` a console name opened once for both
directions, `SYS_UserShell` the resident `shell` rather than
`BootShell`, and `SYS_Asynch` returns at once with the new CLI's number,
the shell closing its streams at its end. `CreateNewProc`'s tags pass on.
`SystemTagList("Copy RAM:a TO RAM:b", null)` runs one line; a null
command is an interactive shell:

```zig
// A shell of its own, in a window, running on after the call returns.
const number = dl.SystemTagList(null, &[_]TagItem{
    .{ .tag = dos.SYS_Window, .data = @intFromPtr("CON:40/40/600/300/Work/CLOSE") },
    .{ .tag = dos.SYS_UserShell, .data = 1 },
    .{ .tag = dos.SYS_Asynch, .data = 1 },
    .{},
});
if (number < 0) _ = dl.PrintFault(dl.IoErr(), "NewShell");
```

`Execute(command, input, output)` runs a command in a new shell that
then reads more commands from `input`. `RunCommand(code, stack_size,
args, length)` runs a command's code on the calling process instead, on
a stack of its own, its argument line ending in a newline; it is how the
shell runs every command. `LoadSeg(name)` loads a program file, whose
first segment's `entry` is the program's `_program_entry`, and
`UnLoadSeg` frees it:

```zig
const seg = dl.LoadSeg("C:Type") orelse return dos.RETURN_FAIL;
defer dl.UnLoadSeg(seg);
const entry = seg.entry orelse return dos.RETURN_FAIL;
const code = dos.SegCode{ .command = @ptrCast(@alignCast(entry)) };
const line = "S:Startup-Sequence\n";
if (dl.RunCommand(&code, dos.CLI_DEFAULT_STACK, line, line.len) == -1) return dos.RETURN_FAIL;
```

The shell looks for a command first among dos's resident segments,
where `Resident` puts one it has loaded; `AddSegment`, `FindSegment`
and `RemSegment`, under `LockSegmentList`, keep that list.

### Starting a program with files

A launcher - the desktop, a program that opens a file in another - runs
the program as a shell runs one, with the files twice over: on its
command line, each full name quoted, for `ReadArgs`; and as pairs of a
lock and a name, for a program that wants locks. The pairs are
`WBArg`s, the program itself first: a file is a lock on the drawer it
is in and its name, a drawer or a volume a lock on itself and an empty
name.

```zig
// MultiView with RAM:Notes.txt: the line, then the shell that runs it.
var line: [512]u8 = undefined;
var at = dos.rdargs.quote(&line, "SYS:Programs/MultiView").?;
line[at] = ' ';
at += 1;
at += dos.rdargs.quote(line[at..], "RAM:Notes.txt").?;
line[at] = 0;

const pairs = [_]dos.WBArg{
    .{ .lock = programs, .name = "MultiView" }, // locks the launcher holds
    .{ .lock = ram, .name = "Notes.txt" },
};
const output = dl.Open("CON:40/60/560/240/MultiView/AUTO/CLOSE/WAIT", dos.MODE_NEWFILE);
const rc = dl.SystemTagList(@ptrCast(&line), &[_]TagItem{
    .{ .tag = dos.SYS_Asynch, .data = 1 },
    .{ .tag = dos.SYS_Input, .data = @intFromPtr(dl.Open("NIL:", dos.MODE_OLDFILE)) },
    .{ .tag = dos.SYS_Output, .data = @intFromPtr(output) },
    .{ .tag = dos.NP_StackSize, .data = 32768 },
    .{ .tag = dos.NP_ArgList, .data = @intFromPtr(&pairs) },
    .{ .tag = dos.NP_NumArgs, .data = pairs.len },
    .{ .tag = dos.NP_ExitCode, .data = @intFromPtr(&ended) }, // hear of its end
    .{},
});
```

`dos.rdargs.quote` writes a name as `ReadArgs` reads it back whole -
blanks, quotes (`*"`), stars (`**`), line ends (`*N`). The output
console with `AUTO` opens its window only when the program prints, and
`WAIT` keeps it until it is closed; a console nothing reads gets no
banner. `NP_StackSize` is the stack the program runs on. CreateNewProc
copies the pairs, each lock duplicated, so the launcher keeps and frees
its own; the copy is the process's until it ends. The program reads
them with `GetArgList`, beside `GetArgStr`'s line:

```zig
var count: u32 = 0;
if (dl.GetArgList(&count)) |files| {
    for (files[1..count]) |file| {
        const old = dl.CurrentDir(file.lock);
        defer _ = dl.CurrentDir(old);
        // file.name, opened in the drawer it is in
    }
}
```

A program started from a shell has none, and every program reads its
line with `ReadArgs` either way. `C:test/Launch TOOL/A,FILES/M,STACK/K/N,PRI/K/N`
starts a program like this; `C:test/EchoArgs` prints what it was given.

## Variables

A local variable belongs to a process: a shell's own, copied to each
process started from it (`NP_CopyVars`). A global one is a file in
`ENV:`, which every process sees; a name with a `/` is a file in a
directory there (`Sys/loglevel`). `ENVARC:` holds the globals that last
past a restart, and `S:Startup-Sequence` copies it into `RAM:ENV` at
boot and assigns `ENV:` there.

`GetVar(name, buffer, size, flags)` finds the local variable first, then
the global one (only one of them with `GVF_LOCAL_ONLY` or
`GVF_GLOBAL_ONLY`); a text value is cut at a newline and ended with a
NUL, and the answer is its length, or -1. `SetVar(name, value, size,
flags)` sets a local variable, or with `GVF_GLOBAL_ONLY` the file in
`ENV:`, and with `GVF_SAVE_VAR` the one in `ENVARC:` as well; a size of
-1 counts a string. `DeleteVar` deletes one, and `FindVar` answers a
local one's `LocalVar`. The low byte of `flags` is the type: `LV_VAR`, or
`LV_ALIAS` for the shell's aliases.

```zig
_ = dl.SetVar("Editor", "Notepad", -1, dos.LV_VAR | dos.GVF_GLOBAL_ONLY | dos.GVF_SAVE_VAR);
var value: [64]u8 = undefined;
if (dl.GetVar("Editor", &value, value.len, dos.LV_VAR) >= 0) {
    _ = Printf(dl, "Editor is %s\n", .{@as([*:0]const u8, @ptrCast(&value))});
}
```

In the shell, `Set`, `Get` and `Unset` work on local variables;
`Setenv`, `Getenv` and `Unsetenv` on global ones.

## Being told of a change

A program that keeps something a file says - a setting in `ENV:` or
`ENVARC:` - can be told when the file changes, instead of reading it
again and again. It fills in a `dos.notify.NotifyRequest` and hands it
to `StartNotify`; the request is the program's, and stays where it is
until `EndNotify`.

```zig
const notify = dos.notify;
var request: notify.NotifyRequest = .{
    .name = "ENVARC:Sys/net/hostname",
    .flags = notify.NRF_SEND_MESSAGE,
    .port = port,
};
if (!dl.StartNotify(&request)) return; // IoErr(): the handler cannot watch
defer dl.EndNotify(&request);
while (true) {
    _ = sys.WaitPort(port);
    while (sys.GetMsg(port)) |message| {
        sys.ReplyMsg(message); // a NotifyMessage; its `request` says which
        // ... read the file again
    }
}
```

- **How it is told**: `NRF_SEND_MESSAGE` puts a `NotifyMessage` on
  `port` - `class` `NOTIFY_CLASS`, `code` `NOTIFY_CODE`, `request` the
  request - which the program replies; `NRF_SEND_SIGNAL` signals `task`
  with `signal_number`, for a program that only needs to know that
  something changed. With `NRF_WAIT_REPLY` no second message comes while
  one is out, and a change meanwhile is told once it is replied.
  `NRF_NOTIFY_INITIAL` tells once at the start when the object is there.
- **What is a change**: a file - a handle that wrote to it closed (not
  each write, so a file half written is never reported), deleted,
  renamed away or onto, its protection, comment, date or owner set. A
  directory - an entry in it made, deleted, renamed, or closed after
  writing.
- **A name that is not there yet** is watched until it appears; a watch
  follows the object it found until that is deleted or renamed, and then
  waits for the name again.
- **Where**: dos writes the handler's own path into `full_name` - an
  assign's directory written out, so `ENV:Sys/x` is `Ram Disk:ENV/Sys/x`
  - and the handler keeps the request. RAM:, the flash file system and
  fat-handler watch, so `ENV:`, `ENVARC:` and the cards in `SD0:` can be
  watched; `StartNotify` fails with `ERROR_ACTION_NOT_KNOWN` on a handler
  that does not. Of a multi-directory assign, the first directory is
  watched.
- **A card** taken out lets go of what its watches found; the card put
  back - or another with the same volume name - finds their names again
  and tells each watcher. A name given on the device (`SD0:Work`)
  is watched on whichever card is in.
- **The end**: `EndNotify` takes back the request's messages still on the
  port; reply the ones already taken, before or after.

`C:test/Notify NAME/M` watches names and prints each change.
bsdsocket.library watches `ENVARC:Sys/net/hostname` this way, so a new
name in the file is in force at once.

## The device list and assigns

dos keeps one list of names. Each node is a `DosList`: its `name`
without the colon; its `type`, a device (`DLT_DEVICE`, a handler and
what it serves), a volume (`DLT_VOLUME`, a disk that is in) or an assign
(`DLT_DIRECTORY`, `DLT_LATE`, `DLT_NONBINDING`); its handler's port in
`task`, null until the handler runs; and the part for its kind in
`misc`.

Assigns are made with calls of their own. `AssignLock("WORK", lock)`
makes `WORK:` an assign to a locked directory and keeps the lock - on
failure it stays the caller's, to unlock - and a null lock removes the
assign. `AssignLate(name, path)` locks the path the first time the
assign is used, `AssignPath` looks it up every time. `AssignAdd` and
`RemAssignList` give a name one directory more or less, and a name with
several, as `LIBS:` has, is looked for in each in turn.

`LockDosList(flags)` locks the list for the kinds named (`LDF_DEVICES`,
`LDF_VOLUMES`, `LDF_ASSIGNS`, or `LDF_ALL`) with exactly one of
`LDF_READ` and `LDF_WRITE`, and answers the start for `FindDosEntry` (by
name) and `NextDosEntry` (the next node of those kinds);
`UnLockDosList` with the same flags lets it go. The list is held
briefly: what is wanted is copied, and printed once the list is let go,
as `C:Info` does, since a write to a console can wait.

```zig
const flags = dos.LDF_VOLUMES | dos.LDF_READ;
const list = dl.LockDosList(flags) orelse return dos.RETURN_FAIL;
const mounted = dl.FindDosEntry(list, "System", dos.LDF_VOLUMES) != null;
dl.UnLockDosList(flags);
if (!mounted) return dos.RETURN_WARN;
```

A node of a program's own is made with `MakeDosEntry(name, DLT_DEVICE)`,
filled in (`misc.handler.handler` the handler's name, its `stack_size`,
`priority` and `startup`) and put on the list with `AddDosEntry`, which
locks the list itself; `C:net/ShellServer` adds a console on
telnet.device that way for each session. `RemDosEntry` takes a node off,
with the list held for `LDF_WRITE`, and `FreeDosEntry` frees it.

**A handler never waits for the device list while it serves a packet.**
A program may hold the list while it sends packets: `C:Info` holds it as
it asks each handler for `ACTION_DISK_INFO`. A handler that waited for
the list there would never get it, and the program would never get its
answer. A handler that changes a node of its own - a volume that comes
or goes - takes the list with `AttemptLockDosList`, which answers null
rather than wait, and makes the change later when it cannot have it. A
volume node that locks still point at stays on the list, with no handler
behind it, until the last of those locks is gone.

## Handlers and packets

A handler is a process that answers the packets for the names of its
node, started by dos the first time one of them is used. Its code is
found by the node's handler name: among dos's resident segments, where
the ROM's handlers are (`nil-handler`, `ram-handler`, `con-handler`,
`pipe-handler`, `flashfs-handler`), or else as a file, a bare name from
`HANDLERS:`, where `fat-handler` is, unloaded again when the last
process running it ends.

A `DosPacket` carries an `action` (a `dos.ActionCode`: `.findinput`,
`.read`, `.locate_object`, `.disk_info`, ...) and up to seven arguments
(`args`, raw or through the typed views of `PacketArgs`). It comes back
with `res1`, the call's answer, and `res2`, which becomes the caller's
`IoErr()`; each call's BEHAVIOR in the reference names the packet it
sends. `DoPkt(port, action, arg1, ..., arg5)` sends one and waits for
it - `C:Info` asks each handler for `.disk_info` so, with a node's `task`
as the port. `SendPkt` sends one without waiting, `WaitPkt` takes the
next one that reaches the process's port, `ReplyPkt(pkt, res1, res2)`
sends one back.

A handler's first packet is `ACTION_STARTUP`, with the name in
`args.raw[0]`, the node's `startup` in `args.raw[1]` and the node itself
in `args.raw[2]`. The handler puts its process's `msg_port` in the
node's `task` and replies, and from then on takes packets with `WaitPkt`
and answers each with `ReplyPkt` - `ERROR_ACTION_NOT_KNOWN` in `res2`
for an action it does not do. A file system also adds a `DLT_VOLUME`
node for the disk it serves.

A file system that watches answers `ACTION_ADD_NOTIFY` and
`ACTION_REMOVE_NOTIFY` (the request in `args.raw[0]`) with a
`dos.notify.Watchers`: it hands the watchers the node a request's
`full_name` names, or none, and tells them as nodes change, are made,
renamed or go (`changed`, `adopt`, `orphan`). A file system that keeps
nothing in memory for an object nobody holds - fat-handler - hands them
its key for the object instead, holds that key while it is watched, and
has the watches waiting for a name look again with `settle` when an
entry is made or renamed and when a volume is mounted. The watchers send the
messages and take them back on a port of their own, which the handler
waits on beside its packets and empties with `collect`. `src/rom/handler/nil/nil.zig` is the
smallest whole handler, with the `exec.ResidentHandler` tag dos finds it
by; `src/disk/devs/handlers/fat/` is one that is loaded from `HANDLERS:`.

## Disks at boot

dos does not look for disks. A disk's driver reads its RigidDiskBlock
and makes a device node per partition with expansion.library's
`MakeDosNode`, named as the partition says and with the handler its
DosType asks for (`FLS\0` flashfs-handler, `MSD\0` fat-handler), and
hands it over with `AddBootNode`. `flash.device` does this at cold
start, before dos is up, so expansion.library keeps the nodes until
dos's init takes them in with `EnterBootNodes`; a node handed over later
goes on the list at once. dos then makes `SYS:` a late assign to the
bootable partition with the highest boot priority, `C:`, `S:`, `LIBS:`,
`DEVS:` and `HANDLERS:` late assigns to its directories, and starts the
first shell, in a console window, reading `S:Startup-Sequence`.
`Mount SD0:` puts a device on the list from its entry in
`DEVS:MountList`. [Disks and partitions](rdb.md) has the partition
table and how to change it.

`Relabel(drive, name)` - and `C:Relabel DRIVE/A,NAME/A` - gives a volume
a new name, which its handler writes where its format keeps one: the
flash disk's root record, a FAT card's label in upper case and at most
eleven characters, an exFAT card's label as written. The volume's node
keeps its place on the device list and takes the new name, so a lock
on the volume names it by that at once. A handler that does this gives
its node the name with `dos.volumename.VolumeName`, after the packet is
answered and only when the device list can be had at once.

## Consoles

`CON:` is a console in a window, and **each Open of a `CON:` name is a
window of its own**, closed when its last handle is. The name describes
the window: `CON:left/top/width/height/title/options`, an empty or 0
number being as much as the screen has left. Among the options after
the title, `CLOSE` gives it a close gadget, which ends the input;
`AUTO` opens it at the first read or write; `WAIT` keeps it after the
last close until a key is pressed; `WINDOW address` hands it a window
the program opened (`src/rom/handler/con/window.zig` lists them all).
One handle, `Open("CON:20/20/400/150/Output/CLOSE/WAIT", MODE_NEWFILE)`,
reads and writes the window. `RAW:` is the same window, starting raw.
`AUX:` is a console on the machine's console port - the USB port on the
boards, UART0 in QEMU - which every Open of it shares. The same handler
runs a console on any device that reads and writes a stream: a node
whose startup is a FileSysStartupMsg naming the device and its unit, as
`C:net/ShellServer` adds one for each connection (`TELNET<n>:` on
telnet.device, `SSH<n>:` on ssh.device). Such a device's
`IOERR_ENDOFSTREAM` - the peer gone, or its input ended - ends the
console's input as Ctrl-\ does, raw or cooked.

Each console writes the system's banner before the first thing written
to it, so it stands above a shell's first prompt. A console set raw
before anything was written gets none: it is a program's channel - one
command run over SSH - not a terminal somebody reads. Nor does a console
only ever opened for writing, such as the window a program started from
the desktop prints into.

A console starts cooked: it edits a line, with a history and copy and
paste, and a read answers once Return is pressed. Tab completes the
file or directory name before the cursor, looked up from the reading
program's current directory; when several names fit, it goes as far as
they agree, and a second Tab lists them - as wide as the window, or as
the terminal at the line's other end when the device knows its size
(serial.device's `SDCMD_TERMSIZE`, which ssh.device answers with the
client's window), or 80 columns. `SetMode(fh, 1)` makes
it raw - each byte as typed, without echo or editing - and
`SetMode(fh, 0)` cooked again. `WaitForChar(fh, microseconds)` tells
whether input comes within that time (a whole line, when cooked)
without reading it. Ctrl-C to Ctrl-F raise their signals in either mode,
and when raw the byte comes as well; Ctrl-\ is the end of the input.

A console window speaks VT100 and the parts of xterm programs use:
the cursor, 256 colours, scroll regions, the other screen, the mouse;
its characters are Latin-1. Asked `CSI 18 t`, it answers its size as
`CSI 8 ; rows ; columns t` in its input, and `CSI 6 n` with the cursor's
place; on a console over a device the terminal at the other end
answers, if it can. A program that wants the size reads the answer in
raw mode, with WaitForChar giving up after a moment - which is how
`C:net/SSH` sizes its terminal.

```zig
const in = dl.Input() orelse return dos.RETURN_FAIL;
if (!dl.IsInteractive(in) or !dl.SetMode(in, 1)) return dos.RETURN_FAIL;
defer _ = dl.SetMode(in, 0);
while (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) {
    if (!dl.WaitForChar(in, 100_000)) continue; // a tenth of a second
    const key = dl.FGetC(in);
    if (key < 0 or key == 'q') break;
    _ = Printf(dl, "key %x\n", .{key});
}
```
