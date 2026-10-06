# exec.library

exec.library is the kernel every other module stands on: it finds
libraries, devices and resources by name, hands out memory, keeps the
lists the system is made of, runs tasks on both cores, wakes them with
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

The chip has two kinds of memory, and exec keeps each as a region with
attributes and a priority. Internal SRAM is `MEMF_INTERNAL` and
`MEMF_DMA`, at priority -10: fast, with no cache in the way, reachable by
the DMA engines, and readable while the caches are suspended. PSRAM is
`MEMF_EXTERNAL`, at priority 0: the bulk of the memory, behind the data
cache. An allocation comes from the first region, by priority, that has
every attribute asked for and room - so `MEMF_ANY` takes PSRAM first
where there is PSRAM, and internal memory is kept for what only it can do.

| Flag | |
|---|---|
| `MEMF_ANY` | anywhere |
| `MEMF_INTERNAL` | internal SRAM: what an interrupt reads often, and what is used while the caches are off |
| `MEMF_EXTERNAL` | PSRAM: big buffers |
| `MEMF_DMA` | what a DMA engine addresses directly, with no cache maintenance: descriptor chains and their buffers |
| `MEMF_CLEAR` | zeroed before it is handed out |
| `MEMF_REVERSE` | taken from the top of the region |
| `MEMF_NO_EXPUNGE` | fail rather than ask the low-memory handlers |

A buffer in PSRAM that a DMA engine reads or writes goes through
`CachePreDMA` before the transfer and `CachePostDMA` after it.

**Two ways to allocate.** `AllocMem(size, flags)` answers a block that
`FreeMem` takes back with the same size, which the caller remembers.
`AllocVec(size, flags)` keeps the size in front of the block, and
`FreeVec` needs only the pointer. Both answer null when there is no
memory; both free calls do nothing for null, so they fit a `defer`.

```zig
const table = sys.AllocMem(1024, exec.MEMF_INTERNAL | exec.MEMF_CLEAR) orelse return;
defer sys.FreeMem(table, 1024);

const name = sys.AllocVec(len + 1, exec.MEMF_ANY) orelse return;
defer sys.FreeVec(name);
```

A block is rounded up to `MEM_BLOCKSIZE` (8 bytes) and aligned to it, and
`AllocVec` costs one block more. A block freed with the other call, or
with another size, corrupts its region; one that is in no region at all
stops the machine.

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

**How much there is.** `AvailMem(flags)` answers the free bytes of the
regions with those attributes; with `MEMF_LARGEST` the largest single
block, with `MEMF_TOTAL` the regions' whole size. Another task, on either
core, may allocate the moment it has answered, so a program allocates and
tests the answer rather than asking first. `C:Avail` prints the numbers.

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
copy and fill.

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
one. Both cores take tasks from one ready list, so two tasks do run at
once; [Two cores](programs.md#two-cores) has what that changes.

**Starting one.** `CreateTask(name, pri, code, stack_size)` allocates the
task, its name and its stack in one block (8 KiB of stack for 0), starts
it, and frees the block when it ends. It takes no argument, and the new
task may be running on the other core before the call returns. A task
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
`RemTask(null)`. `RemTask(task)` ends another at once, without warning,
and leaks whatever it held - signals, ports, memory - so a task is asked
to end instead, usually with `SIGBREAKF_CTRL_C`, and ends itself. A task
running code that goes when the program returns must be gone first,
which its end message says ([When the code goes](programs.md#when-the-code-goes)).

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
const server = sys.FindPort("counter.port") orelse return sdk.dos.RETURN_WARN;
const reply_port = sys.CreateMsgPort() orelse return sdk.dos.RETURN_FAIL;
defer sys.DeleteMsgPort(reply_port);
var request: AddMsg = .{ .add = 5 };
request.msg.reply_port = reply_port;
request.msg.length = @sizeOf(AddMsg);
sys.PutMsg(server, &request.msg);
_ = sys.WaitPort(reply_port);
_ = sys.GetMsg(reply_port); // request.total is the answer
```

`FindPort` answers what is on the list at that moment. The port stays as
long as its owner keeps it, and the owner takes it off and answers what
is left before it deletes it, as above. A port laid out by hand - in a
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
it off). `Disable` and `Enable` hold every interrupt off, on both cores,
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
either core; which one fits depends on whether the holder waits and
whether an interrupt touches the data. Nothing that may wait is called
with a spinlock held, and `Wait` with one held is a dead end. The table,
the rules exec checks and the lock order are in
[Keeping others out](programs.md#keeping-others-out-semaphores-spinlocks-and-disable).

## More of exec

| Calls | |
|---|---|
| `ReadLog`, `SetLogSignal`, `LogControl` | the system log: [The system log](programs.md#the-system-log) |
| `Alert`, `AlertAt`, `Debug` | a Guru, and the ROM debugger: [When a check fails](programs.md#when-a-check-fails), [When it stops](programs.md#when-it-stops) |
| `LockExecList`, `UnlockExecList` | exec's own lists, read under their lock |
| `SetTaskAffinity`, `CoreTask`, `ReadCoreTimes` | tasks and cores: [Two cores](programs.md#two-cores) |
| `SetTaskEndMsg`, `AddTaskEndHook`, `RemTaskEndHook` | told when a task has ended; a library letting go of what it holds for a task |
| `NewStackRun` | a function run on a bigger stack of its own, and back |
| `RawDoFmt`, `RawPutChar` | formatting, and the raw serial port; `sdk.exec.kprintf` is the two together |
| `CachePreDMA`, `CachePostDMA`, `CacheClearE`, `CacheClearU`, `CodeAddress` | caches around DMA, and code written as data made runnable |
| `CreateMemHeader`, `AddMemList`, `Allocate`, `Deallocate` | a region of memory: a module's own to allocate from, or one handed to the system |
| `FindResident`, `InitResident`, `ResModules` | the ROM's modules |
| `SetTrapCode` | the running task's CPU exceptions, taken by code of its own |
| `SetFunction` | one slot of a library's jump table replaced |
| `ColdReboot` | the machine reset |
