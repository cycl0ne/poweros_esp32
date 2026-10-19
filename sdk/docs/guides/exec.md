# exec.library

exec.library is the kernel every other module stands on: it finds
libraries, devices and resources by name, hands out memory, keeps the
lists the system is made of, runs tasks on every core, wakes them with
signals and carries messages between them. This guide is how those pieces
fit together, for a program and for a module of the system. Each call is
in the reference, [exec](../autodocs/exec.md); locking, the system log and
what happens when a check fails are in [Writing programs](programs.md).

- [The base](#the-base)
- [Libraries, devices and resources](#libraries-devices-and-resources)
- [Memory](#memory)
- [Lists](#lists)
- [Tasks](#tasks)
- [Signals](#signals)
- [Messages and ports](#messages-and-ports)
- [Devices and I/O requests](#devices-and-io-requests)
- [Interrupts](#interrupts)
- [A library or a device of your own](#a-library-or-a-device-of-your-own)
- [Keeping others out](#keeping-others-out)
- [More of exec](#more-of-exec)

## The base

Every call is a method of exec's base, `*ExecBase`, and goes through its
jump table. Nothing opens exec: its base is handed to whatever starts - a
program's `_program_entry` gets it as its first argument
([Hello, world](programs.md#hello-world---in-the-shell)), and so does a
task's code (`exec.TaskFn`) and a module's init routine (`exec.InitFn`,
`exec.ResidentInitFn`). The examples below use these names:

```zig
const sdk = @import("sdk");
const exec = sdk.exec; // structures and constants
const ExecBase = sdk.interface.exec.ExecBase; // sys: the base and its calls
```

Code that is handed the base keeps it and passes it on. The one fixed
address, `sdk.exec.AbsExecBase`, is for code that is handed nothing - a
panic handler ([When a check fails](programs.md#when-a-check-fails)).

exec is version 1. The calls added since are counted in its revision -
each call's SINCE line in the reference says which - and
`sys.lib().revision` answers the revision running.

## Libraries, devices and resources

A **library** is opened by name and a lowest version. The answer is
exec's `*exec.Library`, and the library's SDK interface is a cast away:

```zig
const UtilityBase = sdk.interface.utility.UtilityBase;

const lib = sys.OpenLibrary(sdk.utility.UTILITYNAME, 1) orelse return sdk.dos.RETURN_FAIL;
defer sys.CloseLibrary(lib);
const ub: *UtilityBase = @ptrCast(lib);
```

The name is matched exactly, case included. The version guards against
calling a slot the library has not got: a jump table only grows at its
end, so a library at the version asked for has every call that version
had. Null means there is no such library, it is older than asked, or its
Open refused. A library in the ROM is there from the start; one on the
disk is loaded from `LIBS:` the first time something opens it. Each open
owes one `CloseLibrary`, after which the base is not used again - the
library may be expunged the moment its last opener has gone.
`CloseLibrary(null)` does nothing, so a cleanup path need not test.

A **device** is opened with an I/O request rather than for a base; see
[Devices and I/O requests](#devices-and-io-requests).

A **resource** is found with `OpenResource(name)`. Nothing is counted and
there is no close: the pointer is good for as long as the machine runs,
and null is an ordinary answer for a resource only some boards have.

```zig
const platform = sdk.resources.platform;
const found = sys.OpenResource(platform.PLATFORMNAME) orelse return sdk.dos.RETURN_WARN;
const pr: *sdk.interface.platform.PlatformBase = @ptrCast(@alignCast(found));
```

## Memory

An ESP32 has two kinds of memory, and exec keeps each as a region with
attributes and a priority. Internal SRAM is `MEMF_INTERNAL` and
`MEMF_DMA`, at priority -10: fast, with no cache in the way, reachable by
the DMA engines, and readable while the caches are suspended. PSRAM is
`MEMF_EXTERNAL`, at priority 0: the bulk of the memory, behind the data
cache. An allocation comes from the first region, by priority, that has
every attribute asked for and room - so `MEMF_ANY` takes PSRAM first
where there is PSRAM, and internal memory is kept for what only it can do.

A RISC-V 64 machine has one kind, its DRAM: every region is
`MEMF_INTERNAL` and `MEMF_EXTERNAL` at once, at priority 0. The regions
are the RAM the device tree names less what is in use - the kernel, the
disk image the loader put in RAM, and the ranges the tree reserves for
the firmware. Only RAM below 4 GiB is `MEMF_DMA`, since the DMA engines'
descriptors hold 32-bit addresses, so a region that crosses 4 GiB is cut
there; and no region is larger than 2 GiB, as exec counts a region's free
bytes in 32 bits. Such a board says so with `SYSTAG_UnifiedMemory`, so a
program shows one figure of free memory rather than the same one twice.

| Flag | |
|---|---|
| `MEMF_ANY` | anywhere |
| `MEMF_INTERNAL` | internal SRAM: what an interrupt reads often, and what is used while the caches are off |
| `MEMF_EXTERNAL` | PSRAM: big buffers |
| `MEMF_DMA` | what a DMA engine addresses directly, with no cache maintenance: descriptor chains and their buffers |
| `MEMF_PRIVATE` | the owner's alone: nothing in it is passed to another task or a library |
| `MEMF_CLEAR` | zeroed before it is handed out |
| `MEMF_REVERSE` | taken from the top of the region |
| `MEMF_SYSTEM` | the system's, not the calling task's |
| `MEMF_NO_EXPUNGE` | fail rather than ask the low-memory handlers |

A buffer in PSRAM that a DMA engine reads or writes goes through
`CachePreDMA` before the transfer and `CachePostDMA` after it. On the
VisionFive 2 the devices do not see the cores' caches either: there the
cache calls write each line of the range back and drop it through the L2
cache controller's Flush64 register, which the board names
(`SYSTAG_CacheFlush`). QEMU's virt names none, as its devices see the
caches, and the calls do nothing there.

**Two ways to allocate.** `AllocMem(size, flags)` answers a block that
`FreeMem` takes back with the same size, which the caller remembers.
`AllocVec(size, flags)` is the same block, and `FreeVec` needs only the
pointer: the block knows its size. Both answer null when there is no
memory; both free calls do nothing for null, so they fit a `defer`.

```zig
const table = sys.AllocMem(1024, exec.MEMF_INTERNAL | exec.MEMF_CLEAR) orelse return;
defer sys.FreeMem(table, 1024);

const name = sys.AllocVec(len + 1, exec.MEMF_ANY) orelse return;
defer sys.FreeVec(name);
```

A block is rounded up to `MEM_BLOCKSIZE` (8 bytes) and aligned to it.

**Every block says who holds it.** In front of each one is a `MemBlock`,
one `MEM_BLOCKSIZE` more taken from the region: the owner, the size and
whether the block is private. The owner is the task that allocated it -
its number, `Task.id`, which `AddTask` gives every task - and that is the
caller even inside library code, which runs on its caller's task. A block
is the system's instead when the call asks for `MEMF_SYSTEM`, when one of
exec's own tasks allocates, and while a task is between
`BeginSystemMemory()` and `EndSystemMemory()`:

```zig
// A library's cache outlives the call that made it: the system's.
const cache = sys.AllocMem(4096, exec.MEMF_SYSTEM) orelse return null;

// A loader making a module: everything it allocates meanwhile.
sys.BeginSystemMemory();
defer sys.EndSystemMemory();
```

`InitResident` runs a module's init inside such a pair, ramlib loads
modules and dos loads handlers inside one, and a library's base is the
system's whoever opened it first. A task's own block - its TCB and stack -
is its own once it runs. A pool and its puddles belong to whoever made
the pool.

Memory one task makes for another is given to it with
`SetMemOwner(block, task)` - null gives it to the system. A task not
started yet will do: it gets its number there, and `AddTask` keeps it.
dos gives a new process the variables and path it copies for it so:

```zig
_ = sys.SetMemOwner(startup, &child.task); // the child's, though made here
_ = sys.AddTask(&child.task, &childCode, null);
```

`MEMF_PRIVATE` says a block is its owner's alone; without it a block is
shared, which suits anything. Neither is enforced: no access is checked
against them. **A private block goes with its owner**: one the owner has
not freed when it ends is freed then (see [Ending](#tasks)), which is
why nothing in it may be put in a message, an I/O request or another
task's hands. `NewStackRun`'s stacks are private, so a command's stack
goes with a task that ends while the command runs.

**`FreeMem` checks the block.** One that is not in use - freed already,
or its `MemBlock` written over by a block below running past its end - or
a size that is not the block's is refused: the block stays as it is, the
system log names it, and a recoverable alert says which (`AN_FreeTwice`,
`AN_BadFreeSize`). A size that rounds up to the same multiple of
`MEM_BLOCKSIZE` is the block's. One in no region at all stops the machine.

**Memory debugging.** `MemDebug(MEMDEBUG_ON, ...)` puts a wall behind
every new block, which `FreeMem` checks, fills new memory with
`0xABADCAFE` and freed memory with `0xDEADBEEF`, which `AllocMem` checks
when it hands it out again, and gives new tasks a wide stack guard;
`MEMDEBUG_CHECK` looks at all of it at once and hands back what is wrong
as `MemDamage` records, `MEMDEBUG_ASK` the counts. `C:MemDebug` and the
serial console's `s3> memdebug` are the same call, and a kernel built
with `-Dmemdebug=true` has the mode on from exec's start. The
[programs guide](programs.md) has the details.

**Who holds what.** `C:Avail OWNERS` lists every owner with its blocks
and bytes: the system, each task by number and name, and the numbers of
tasks that have ended with what they left. `C:Top` adds a column of what
each task holds, `SYS:System/MemMap` draws the regions with each block
in its owner's colour - on a machine whose RAM is one kind all of them
in one band, by address - and the ROM debugger's `memowners` lists them on
the serial console, or one owner's blocks. A program walks the blocks
itself with `exec.RegionWalk` under `LockExecList(EXECLIST_MEMORY)`, or
sums them with `exec.memowners.Tally`.

**Pools.** Many small blocks that go together - the nodes of a list, the
entries of a table - come from a pool. It takes memory from the system a
puddle at a time, its blocks carry no header, and `DeletePool` gives all
of it back at once:

```zig
const pool = sys.CreatePool(exec.MEMF_ANY, 4096, 1024) orelse return;
defer sys.DeletePool(pool); // every block with it

const entry = sys.AllocPooled(pool, @sizeOf(Entry)) orelse return;
sys.FreePooled(pool, entry, @sizeOf(Entry)); // the size asked for
```

A request at or above the threshold (1024 here) gets memory of its own. A
pool made with `MEMF_CLEAR` clears every block it hands out, and a pool
has a lock of its own, so several tasks may share one.

**A growing array.** `exec.Array(T)`, in the SDK and compiled into the
program, keeps its items in one block from `AllocVec` and makes it twice
as large whenever it is full. Each call that may grow it takes the
ExecBase and answers false with no memory, the array as it was:

```zig
var keys: exec.Array(u32) = .{};
defer keys.deinit(sys);
if (!keys.append(sys, 42) or !keys.appendSlice(sys, &.{ 7, 8 })) return;
for (keys.slice()) |key| use(key);
```

**How much there is.** `AvailMem(flags)` answers the free bytes of the
regions with those attributes; with `MEMF_LARGEST` the largest block
`AllocMem` could answer, with `MEMF_TOTAL` the regions' whole size. Another task, on any
core, may allocate the moment it has answered, so a program allocates and
tests the answer rather than asking first. `C:Avail` prints the numbers:
internal, external and the total, or on a machine whose RAM is one kind
(the board's `SYSTAG_UnifiedMemory`), where every region is both, the
total alone.

**When memory runs short.** An allocation that finds no room asks the
low-memory handlers, highest priority first, and tries again after each
one that freed something. exec's own, at priority 0, expunges a library
or device nobody has open, one per call. A module with a cache adds one
with `AddMemHandler`: an `exec.Interrupt` whose code is an
`exec.MemHandlerFn`, answering `MEM_DID_NOTHING`, `MEM_TRY_AGAIN` or
`MEM_ALL_DONE`. It runs inside someone's `AllocMem`, whose caller may hold
anything, so it neither waits nor allocates: it tries the locks it needs
and passes over what is busy. `C:Avail FLUSH` asks for more than there
is, which runs every handler.

Memory is not allocated or freed in an interrupt, and not allocated while
a spinlock is held. `CopyMem`, `CopyMemQuick` (word-aligned) and `SetMem`
copy and fill: `CopyMem` whatever the alignment and however the two areas
overlap, a word at a time where it can, in loops chosen for the CPU the
kernel is built for. They are the kernel's `memcpy`, `memmove`
and `memset` as well, and a program's through the jump table
(`sdk/program.zig`), so every `@memcpy`, `@memset` and structure copy the
compiler leaves to a call runs them. A program whose root declares
`own_memory_calls` keeps memory calls of its own.

## Lists

A `List` is doubly linked, and its header is the sentinel at both ends,
so adding and removing never test for an end. A `Node` carries a type, a
priority and a name; a `MinList` of `MinNode`s has the links only.

**A list is made empty before it is used.** A header of zeros is not an
empty list - its sentinels are null - and the first add writes through
one. `sys.NewList(&list)` or the SDK's `list.init(type)` makes it empty;
`min_list.init()` does the same for a `MinList`.

| Call | |
|---|---|
| `AddHead`, `AddTail` | a node at either end; `AddTail` with `RemHead` is a queue |
| `Insert(list, node, pred)` | behind `pred`, or at the head for null |
| `Enqueue` | by `pri`, behind every node of the same or higher priority |
| `Remove(node)` | off whatever list it is on |
| `RemHead`, `RemTail` | the first or last node taken off, or null |
| `FindName(list, name)` | the first node of that name, or null |

A list is walked with the SDK's `first()` and `next()`, or an iterator,
which reads each successor before it hands a node over - so the node it
has answered may be removed:

```zig
var it = list.iterator();
while (it.next()) |node| {
    if (node.pri < 0) { // nodes from AllocVec
        sys.Remove(node);
        sys.FreeVec(node);
    }
}
```

`AddHead`, `AddTail`, `Insert`, `Remove`, `RemHead` and `RemTail` touch
only the links, so they serve a `MinList` too, cast to a `List`.
`Enqueue` and `FindName` read the priority and the name, which a
`MinNode` has not got.

**The list calls lock nothing: whoever owns a list guards it.** A list one
task touches needs nothing. One that several tasks share is guarded by a
semaphore or a spinlock of the owner's, and one an interrupt touches too
by a `LOCKF_INTERRUPT` spinlock. exec's own lists - the libraries, the
ports, the tasks - are each under a lock of exec's, which a program that
walks one takes with `LockExecList` and gives back with `UnlockExecList`
([an example](programs.md#keeping-others-out-semaphores-spinlocks-and-disable)).

## Tasks

A task is code with a stack of its own and a priority. A **process** is a
task dos.library made and keeps more about - a current directory, input
and output - and only a process may use a file system. A program runs as
a process. `FindTask(null)` answers the running task, and its node's type
says which kind it is.

**Who runs.** A ready task of higher priority always runs before a lower
one, which does not run at all until the higher one waits. Equal
priorities take turns, four ticks each. A program normally runs at 0, and
the system's own tasks above it - input at 20, motion.library's clock at
10 - so a program that never waits starves everything below it and
nothing above it. `SetTaskPri` changes a priority and answers the old
one. Every core takes tasks from one ready list, so tasks do run at
once; [Several cores](programs.md#several-cores) has what that changes.

**Starting one.** `CreateTask(name, pri, code, stack_size)` allocates the
task, its name and its stack in one block (8 KiB of stack for 0), starts
it, and frees the block when it ends. It takes no argument, and the new
task may be running on another core before the call returns. A task
that needs something handed to it is laid out by the caller, in a
structure of its own, and started with `AddTask`; its code finds the
structure from its `Task`:

```zig
const Worker = struct {
    task: exec.Task = .{},
    ended: exec.Message = .{},
    count: u32 = 0,
};

fn workerCode(sys: *ExecBase) callconv(.c) void {
    const worker: *Worker = @fieldParentPtr("task", sys.FindTask(null).?);
    worker.count += 1; // the work; returning ends the task
}

// In the program:
const ended_port = sys.CreateMsgPort() orelse return sdk.dos.RETURN_FAIL;
defer sys.DeleteMsgPort(ended_port);
const stack_size = 8192;
const stack = sys.AllocVec(stack_size, exec.MEMF_ANY) orelse return sdk.dos.RETURN_FAIL;
defer sys.FreeVec(stack);

var worker: Worker = .{ .task = .{
    .node = .{ .name = "worker" },
    .sp_lower = @intFromPtr(stack),
    .sp_upper = @intFromPtr(stack) + stack_size,
} };
worker.ended.reply_port = ended_port;
worker.task.end_msg = &worker.ended; // replied once the task is gone
_ = sys.AddTask(&worker.task, &workerCode, null);

_ = sys.WaitPort(ended_port);
_ = sys.GetMsg(ended_port); // nothing runs on the stack any more
```

**Ending.** A task ends when its code returns or when it calls
`RemTask(null)`. `RemTask(task)` ends another at once, without warning.
Either way its end gives back what the system can tell is the task's:

1. the **semaphores** it still holds, each as often as it holds it, so
   whoever is queued behind it goes on - whatever the data under the
   lock was left like. Every task keeps a table of what it holds
   (`Task.holds`), which the ROM debugger's `locks` shows;
2. then its **end hooks** run (`AddTaskEndHook`): what libraries hold for
   it - intuition closes the **windows** it left open;
3. then its **private memory** is freed.

Each is a line on the system log when there was anything to give back:
a task that ends holding a lock, a window or a private block has a bug,
and the line names it. Its shared memory, its ports and its signals are
not given back - something else may still use them - so a task is asked
to end instead, usually with `SIGBREAKF_CTRL_C`, and ends itself. A task
running code that goes when the program returns must be gone first,
which its end message says ([When the code goes](programs.md#when-the-code-goes)).

**Kill.** A task that failed is held and asked about on the display
(Software Failure: Suspend, Kill or Reboot); the ROM debugger's `kill
<number>` does the same to any task. Kill drops what the task was doing,
starts it again on its own stack, and has it end as though its code had
returned: its semaphores are let go first, then its final code runs - a
process's closes its streams, so a shell's window goes - and then the
rest of its end, as above. Its Task stays where it was, its stack given
back: a port or a request may still name it
([When a program fails](programs.md#when-a-check-fails)).

The bottom 16 bytes of every stack are a guard exec checks at each
switch; a task that ran past its end stops the machine there
([A stack that runs out](programs.md#a-stack-that-runs-out)).

## Signals

Each task has 32 signal bits. Bits 0 to 15 are the system's; 12 to 15 of
them are `SIGBREAKF_CTRL_C` to `SIGBREAKF_CTRL_F`, which a console sends
the process using it when Ctrl-C to Ctrl-F are typed. Bits 16 to 31 are
handed out by `AllocSignal(-1)`, which answers the bit's number, or -1
when none is free; `FreeSignal` gives it back. A bit belongs to the task
that allocated it, means nothing in another, and is freed by that task.

`Signal(task, mask)` sets bits in a task's received set and wakes it if
it waits for one of them. `Wait(mask)` sleeps until one of the bits is
set, answers which are, and clears those. A bit already set answers at
once, so what arrives while the task is busy is not missed; two signals
on one bit before the task looks are one.

**Wait for everything that can wake the task in one call.** A task
waiting on its port alone does not hear Ctrl-C:

```zig
const got = sys.Wait(port.sigMask() | exec.SIGBREAKF_CTRL_C);
if (got & exec.SIGBREAKF_CTRL_C != 0) return sdk.dos.RETURN_WARN;
```

`SetSignal(new, mask)` reads or changes the running task's bits without
waiting and answers them as they were: `SetSignal(0, 0)` looks,
`SetSignal(0, mask)` clears. A process checks for Ctrl-C between steps of
its work with `SetSignal(0, 0)`, or with dos.library's `CheckSignal`,
which also clears what it found.

`Signal` may be called from an interrupt, and is how an interrupt hands
work to a task. `Wait` may not: an interrupt has no task to put to sleep.
A signal in a task's exception set (`SetExcept`) runs its exception code
wherever the task is, rather than waking a `Wait`.

## Messages and ports

A message is a structure that starts with an `exec.Message`, sent to a
`MsgPort`. **A message is never copied**: sender and receiver share it,
and the sender leaves it alone from `PutMsg` until the reply. A port says
what an arriving message does - signal its task (`PA_SIGNAL`), cause a
software interrupt (`PA_SOFTINT`) or nothing (`PA_IGNORE`).

`CreateMsgPort()` makes a private port that signals the calling task with
a bit of its own, `port.sigMask()`; `DeleteMsgPort` frees it, from the
same task.

| Call | |
|---|---|
| `PutMsg(port, msg)` | queues the message and does the port's action |
| `GetMsg(port)` | the oldest message, taken off, or null |
| `ReplyMsg(msg)` | back to the message's `reply_port`; with none it is marked free instead |
| `WaitPort(port)` | waits for a message and answers it without taking it off |

A port is public when it has a name and is on exec's list: `AddPort` puts
it there by priority, `FindPort(name)` finds it, `RemPort` takes it off.
A server and one of its clients:

```zig
const AddMsg = extern struct {
    msg: exec.Message = .{},
    add: u32 = 0,
    total: u32 = 0,
};

// The server.
const port = sys.CreateMsgPort() orelse return sdk.dos.RETURN_FAIL;
defer sys.DeleteMsgPort(port);
port.node.name = "counter.port";
sys.AddPort(port);
defer {
    sys.RemPort(port);
    while (sys.GetMsg(port)) |msg| sys.ReplyMsg(msg); // nobody left waiting
}
var total: u32 = 0;
while (sys.Wait(port.sigMask() | exec.SIGBREAKF_CTRL_C) & exec.SIGBREAKF_CTRL_C == 0) {
    while (sys.GetMsg(port)) |msg| {
        const asked: *AddMsg = @fieldParentPtr("msg", msg);
        total +%= asked.add;
        asked.total = total;
        sys.ReplyMsg(msg);
    }
}

// A client: the message on its stack, since it waits for the reply.
const reply_port = sys.CreateMsgPort() orelse return sdk.dos.RETURN_FAIL;
defer sys.DeleteMsgPort(reply_port);
var request: AddMsg = .{ .add = 5 };
request.msg.reply_port = reply_port;
request.msg.length = @sizeOf(AddMsg);
if (!sys.SafePutToPort(&request.msg, "counter.port")) return sdk.dos.RETURN_WARN;
_ = sys.WaitPort(reply_port);
_ = sys.GetMsg(reply_port); // request.total is the answer
```

**A message to a port known by its name goes with `SafePutToPort`**,
which finds the port and puts the message under one hold of exec's port
lock. `FindPort` answers what is on the list at that moment, and the
owner may take the port off and delete it before a `PutMsg` that follows
reaches it. The owner takes it off and answers what is left before it
deletes it, as above, so every message `SafePutToPort` delivered is
answered. A port laid out by hand - in a
structure, with `PA_IGNORE` or `PA_SOFTINT` - has its message list made
empty with `port.msg_list.init(.message)`, or by `AddPort`.

## Devices and I/O requests

A request is a message to a device: an `exec.IORequest` at the start of
the structure the device takes - `exec.IOStdReq` for most, a
`TimeRequest` for timer.device, an `IOExtSer` for serial.device, each in
its header under `sdk.devices`. It is made with
`CreateIORequest(reply_port, size)`, opened on a unit, used, closed and
deleted, in that order:

```zig
const td = sdk.devices.trackdisk;

const port = sys.CreateMsgPort() orelse return sdk.dos.RETURN_FAIL;
defer sys.DeleteMsgPort(port);
const request = sys.CreateIORequest(port, @sizeOf(exec.IOStdReq)) orelse return sdk.dos.RETURN_FAIL;
defer sys.DeleteIORequest(request);
if (sys.OpenDevice(td.FLASHNAME, 0, request, 0) != 0) return sdk.dos.RETURN_FAIL;
defer sys.CloseDevice(request);
const io: *exec.IOStdReq = @ptrCast(@alignCast(request));

var block: [512]u8 = undefined;
io.req.command = exec.CMD_READ;
io.data = &block;
io.length = block.len;
io.offset = 0;
if (sys.DoIO(request) != 0) return sdk.dos.RETURN_ERROR;
```

**The size is the device's.** A request smaller than the type the device
expects is memory the device writes past. `OpenDevice` answers 0, or the
device's error, which is also left in the request's `err`.

**Doing one.** `DoIO` sends the request, waits for it and answers its
error. `SendIO` sends it and returns at once; the request and its buffers
then belong to the device, and **every `SendIO` owes a `WaitIO`**, which
waits if need be and takes the reply off the port. `CheckIO` answers
whether the device is done, without waiting and without collecting the
request - `WaitIO` still does, at once. `AbortIO` asks the device to
finish early: the request comes back with `IOERR_ABORTED`, or as usual if
it was too late, and is collected with `WaitIO` all the same. One port
serves any number of requests, since `WaitIO` takes only its own. A
request is closed only when nothing is outstanding on it, and deleted
only after it is closed.

**Quick I/O.** `DoIO` sets `IOF_QUICK` to ask for a quick answer, and a
device that can finish the request inside the call leaves the flag set
and sends no reply, so a short command costs a function call and no
message. `SendIO` clears the flag, so the request always comes back to
its port and can be waited for beside everything else.

**Flags of the command's own.** `IOF_QUICK` is the only flag `DoIO` and
`SendIO` touch. The rest belong to the command - SANA-II's
`SANA2IOF_RAW`, say - and reach the device as they were set. A request used again keeps the flags it was last given, so
they are set for every command that takes any. `sdk.exec.BeginIO` hands
a request over with `IOF_QUICK` as the caller left it: set, it asks for
an answer at once without committing to wait - one that comes back
without the flag is collected with `WaitIO`.

**A timed wait.** `WaitIO` waits on its port's signal alone. A task that
waits for a reply, a timeout and Ctrl-C together waits with `Wait` on all
of them and collects with `WaitIO` after:

```zig
const timer = sdk.devices.timer;

/// Up to `micros` for one of `signals`, with `tr` an open timer request on
/// a port of its own. The signals that came, or 0 when the time ran out.
fn waitFor(sys: *ExecBase, tr: *timer.TimeRequest, signals: u32, micros: u64) u32 {
    const timer_port = tr.node.message.reply_port.?;
    _ = sys.SetSignal(0, timer_port.sigMask()); // see below
    tr.node.command = timer.TR_ADDREQUEST;
    tr.time = timer.TimeVal.fromMicros(micros);
    sys.SendIO(&tr.node);
    const got = sys.Wait(signals | timer_port.sigMask());
    if (sys.CheckIO(&tr.node) == null) _ = sys.AbortIO(&tr.node);
    _ = sys.WaitIO(&tr.node);
    return got & signals;
}
```

**The reply port's signal is cleared before each timed `SendIO`.** When
one of `signals` comes first, the aborted request is replied at once,
`WaitIO` finds it done and does not wait - and the port's signal, set by
that reply, stays set. Without the `SetSignal`, the next round's `Wait`
returns on it straight away, aborts that request too and leaves the
signal set again: the task spins instead of sleeping.

## Interrupts

A driver hooks a peripheral's interrupt by its number, from
`sdk.hardware.intbits`, with an `exec.Interrupt`: its `code`, the `data`
handed to the code, and `pri` for its place.

- `AddIntServer(number, &interrupt)` puts a server on the number's chain.
  Servers run by priority until one answers non-zero, so a server answers
  0 for an interrupt its hardware did not raise.
- `SetIntVector(number, &interrupt)` installs the number's one handler,
  on a CPU line of its own; null takes it away.
- `Cause(&interrupt)` queues a software interrupt, which runs as soon as
  no hardware interrupt is being handled, before any task.

```zig
const Driver = struct {
    sys: *ExecBase,
    task: *exec.Task, // the driver's own task, which does the work
    done_mask: u32,
    int: exec.Interrupt = .{},
    // ... and transferDone(), which asks the driver's hardware
};

fn server(data: ?*anyopaque, _: u32) callconv(.c) i32 {
    const driver: *Driver = @ptrCast(@alignCast(data.?));
    if (!driver.transferDone()) return 0; // not this driver's
    driver.sys.Signal(driver.task, driver.done_mask);
    return 1;
}

// `driver` is in internal memory (MEMF_INTERNAL), and so is the Interrupt in it.
driver.int = .{ .node = .{ .type = .interrupt, .name = "mydev" }, .data = driver, .code = &server };
sys.AddIntServer(sdk.hardware.intbits.INTB_SPI3, &driver.int);
```

An interrupt does no waiting, allocates nothing and reaches no handler.
It may `Signal`, `Cause`, `PutMsg`, `ReplyMsg` and `ReplyIO`, which is how
it hands its work to a task. What it reads belongs in internal memory,
and the `Interrupt` outlives its place on the chain (`RemIntServer` takes
it off). `Disable` and `Enable` hold every interrupt off, on every core,
around the few lines that change what an interrupt also reads.

## A library or a device of your own

A module is found by its ROM tag, an `exec.Resident`. With `RTF_AUTOINIT`
the tag points to an `exec.InitTable` - the base's size, the vectors and
an init routine - from which exec builds the jump table and the base
(`MakeLibrary`) and puts it on the list its type names (`AddLibrary`,
`AddDevice`, `AddResource`); `CreateLibrary` does the same from one
description, for a library that is not in a tag. Every library's table
starts with Open, Close, Expunge and ExtFunc; a device's has BeginIO and
AbortIO after them. The rules exec keeps around those vectors are in
[A library's or a device's own calls](programs.md#a-librarys-or-a-devices-own-calls),
and `LIBS:hello.library` (`src/disk/libs/hello/`) is the smallest one to
start from.

A device's BeginIO works the quick-I/O protocol from the other side:

- A request it finishes inside BeginIO keeps `IOF_QUICK` as it came and
  ends with `ReplyIO`, which sends nothing for a quick one.
- A request it keeps for later has `IOF_QUICK` cleared and goes on the
  unit's port with `PutMsg`, which also marks it as a message. One queued
  with `AddTail` instead keeps the type of its last reply, and `WaitIO`
  takes it for done at once. When it is done, `ReplyIO` sends it back,
  from a task or an interrupt.
- AbortIO takes a request that has not started off the port with
  `RemoveMsg`, sets `IOERR_ABORTED` and replies it.

## Keeping others out

Semaphores (`ObtainSemaphore`), spinlocks (`AcquireLock`) and `Disable`
each keep two pieces of code from changing the same thing at once, on
any core; which one fits depends on whether the holder waits and
whether an interrupt touches the data. Nothing that may wait is called
with a spinlock held, and `Wait` with one held is a dead end. The table,
the rules exec checks and the lock order are in
[Keeping others out](programs.md#keeping-others-out-semaphores-spinlocks-and-disable).

## More of exec

| Calls | |
|---|---|
| `ReadLog`, `SetLogSignal`, `LogControl` | the system log: [The system log](programs.md#the-system-log) |
| `Alert`, `AlertAt`, `Debug`, `MemDebug` | a Guru, the ROM debugger and memory debugging: [Debugging](debugging.md), [When a check fails](programs.md#when-a-check-fails), [When it stops](programs.md#when-it-stops) |
| `LockExecList`, `UnlockExecList` | exec's own lists, read under their lock |
| `SetTaskAffinity`, `CoreTask`, `ReadCoreTimes` | tasks and cores: [Several cores](programs.md#several-cores) |
| `SetTaskEndMsg`, `AddTaskEndHook`, `RemTaskEndHook` | told when a task has ended; a library letting go of what it holds for a task - run before the task's private memory is freed, after its semaphores are let go |
| `NewStackRun` | a function run on a bigger stack of its own, and back |
| `RawDoFmt`, `RawPutChar` | formatting, and the raw serial port; `sdk.exec.kprintf` is the two together |
| `CachePreDMA`, `CachePostDMA`, `CacheClearE`, `CacheClearU`, `CodeAddress` | caches around DMA, and code written as data made runnable |
| `CreateMemHeader`, `AddMemList`, `Allocate`, `Deallocate` | a region of memory: a module's own to allocate from, or one handed to the system |
| `FindResident`, `InitResident`, `ResModules` | the ROM's modules |
| `SetTrapCode` | the running task's CPU exceptions, taken by code of its own |
| `SetFunction` | one slot of a library's jump table replaced |
| `ColdReboot` | the machine reset |
