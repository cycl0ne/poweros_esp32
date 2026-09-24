# exec.library

exec.library's jump table: libraries, lists, task switching and
interrupts, memory, tasks and signals, messages and ports, semaphores,
devices and I/O, and resident modules. New functions only ever go at
the end, so a slot never moves.

Generated from the source by `./zig build autodoc`.

## Index

- [AbortIO](#abortio) - Asks a device to stop a request it is working on.
- [AddDevice](#adddevice) - Puts a device on the device list, where `OpenDevice` finds it.
- [AddHead](#addhead) - Puts a node at the head of a list.
- [AddIntServer](#addintserver) - Adds a server to an interrupt number's chain.
- [AddLibrary](#addlibrary) - Puts a library on the system library list, where `OpenLibrary` finds it.
- [AddMemHandler](#addmemhandler) - Adds a handler that is asked to free memory when an allocation fails.
- [AddMemList](#addmemlist) - Hands a block of memory to the system, for anyone to allocate from.
- [AddPort](#addport) - Makes a port public, so that anything can find it by name.
- [AddResource](#addresource) - Puts a resource on the resource list, where `OpenResource` finds it.
- [AddSemaphore](#addsemaphore) - Makes a semaphore public, so that anything can find it by name.
- [AddTail](#addtail) - Puts a node at the tail of a list.
- [AddTask](#addtask) - Starts a task the caller has laid out, and makes it ready to run.
- [Alert](#alert) - Reports that the system has a problem, and for a dead end stops.
- [AllocMem](#allocmem) - Allocates memory from the system, from the first region that suits.
- [AllocPooled](#allocpooled) - Takes a block of memory from a pool.
- [AllocSignal](#allocsignal) - Takes a signal bit for the calling task's own use.
- [AllocVec](#allocvec) - Allocates memory that remembers how big it is.
- [Allocate](#allocate) - Takes a block from one memory region, with no locking of any kind.
- [AttemptSemaphore](#attemptsemaphore) - Takes a semaphore exclusively if that can be done without waiting.
- [AttemptSemaphoreShared](#attemptsemaphoreshared) - Takes a semaphore shared if that can be done without waiting.
- [AvailMem](#availmem) - How much memory of a kind there is.
- [CacheClearE](#cachecleare) - Clears the caches over one range of addresses.
- [CacheClearU](#cacheclearu) - Makes code written through the data bus runnable.
- [CachePostDMA](#cachepostdma) - Finishes with memory a DMA engine has used, so the CPU reads what was written.
- [CachePreDMA](#cachepredma) - Prepares memory for a DMA engine to read or write, and says where that engine should look.
- [Cause](#cause) - Queues a software interrupt, to run when no hardware interrupt is being handled.
- [CheckIO](#checkio) - Asks whether a device is done with a request, without waiting.
- [CloseDevice](#closedevice) - Closes a request's device.
- [CloseLibrary](#closelibrary) - Closes a library opened with `OpenLibrary`, through its Close vector.
- [CodeAddress](#codeaddress) - Says where memory written as data can be executed from.
- [ColdReboot](#coldreboot) - Resets the machine.
- [CopyMem](#copymem) - Copies bytes, whatever their alignment and however they overlap.
- [CopyMemQuick](#copymemquick) - Copies whole words between word-aligned addresses.
- [CreateIORequest](#createiorequest) - Allocates a cleared I/O request for a reply port.
- [CreateLibrary](#createlibrary) - Makes a library from one description and adds it, name and all.
- [CreateMemHeader](#creatememheader) - Lays a MemHeader over a block of memory, without adding it to the system.
- [CreateMsgPort](#createmsgport) - Makes a private port that signals the calling task.
- [CreatePool](#createpool) - Makes a pool to take many small blocks from.
- [CreateTask](#createtask) - Allocates a task with a stack of its own, and starts it.
- [Deallocate](#deallocate) - Gives a block back to the region it came from, merging it with its free neighbours.
- [DeleteIORequest](#deleteiorequest) - Frees a request from `CreateIORequest`.
- [DeleteMsgPort](#deletemsgport) - Frees a port from `CreateMsgPort`, and its signal bit.
- [DeletePool](#deletepool) - Frees everything a pool holds, and the pool with it.
- [Disable](#disable) - Masks every interrupt until the matching `Enable`.
- [DoIO](#doio) - Does one I/O request and waits for it to finish.
- [Enable](#enable) - Unmasks interrupts again, and takes any task switch that came due.
- [Enqueue](#enqueue) - Puts a node on a list in priority order.
- [ExecList](#execlist) - Hands back one of exec's own lists.
- [FindName](#findname) - Finds the first node of a list with a given name.
- [FindPort](#findport) - Finds a public port by name.
- [FindResident](#findresident) - Finds a resident module by name.
- [FindSemaphore](#findsemaphore) - Finds a public semaphore by name.
- [FindTask](#findtask) - Finds a task by name, or answers the calling task.
- [Forbid](#forbid) - Holds task switching until the matching `Permit`.
- [FreeMem](#freemem) - Gives memory back to the system.
- [FreePooled](#freepooled) - Gives a block from `AllocPooled` back to its pool.
- [FreeSignal](#freesignal) - Gives a signal bit back.
- [FreeVec](#freevec) - Gives back memory from `AllocVec`.
- [GetMsg](#getmsg) - Takes the oldest message off a port, without waiting.
- [InitCode](#initcode) - Starts every resident module of a start class, highest priority first.
- [InitResident](#initresident) - Starts one resident module.
- [InitSemaphore](#initsemaphore) - Prepares a semaphore for use.
- [Insert](#insert) - Puts a node on a list after a given node.
- [IntVector](#intvector) - Hands back one interrupt number's vector.
- [MakeLibrary](#makelibrary) - Builds a library in memory and runs its init routine, without putting it on the library list.
- [NewList](#newlist) - Makes a list empty and ready to use.
- [NewStackRun](#newstackrun) - Runs a function on a stack of its own, and comes back.
- [ObtainSemaphore](#obtainsemaphore) - Takes a semaphore exclusively, waiting until it is free.
- [ObtainSemaphoreList](#obtainsemaphorelist) - Takes every semaphore on a list, exclusively, all or nothing.
- [ObtainSemaphoreShared](#obtainsemaphoreshared) - Takes a semaphore shared, alongside other shared holders.
- [OpenDevice](#opendevice) - Opens a unit of a device, for a request to use.
- [OpenLibrary](#openlibrary) - Opens a library by name at a version, through its own Open vector.
- [OpenResource](#openresource) - Finds a resource by name.
- [Permit](#permit) - Lets task switching happen again, and takes any switch that came due.
- [Procure](#procure) - Bids for a semaphore with a message, instead of waiting for it.
- [PutMsg](#putmsg) - Sends a message to a port, and does whatever that port asks for on arrival.
- [RamLib](#ramlib) - The module loader's base, as `SetRamLib` left it.
- [RawDoFmt](#rawdofmt) - Formats text, handing each character to a function of the caller's.
- [RawIOInit](#rawioinit) - Sets exec's own console up, before anything can be printed.
- [RawMayGetChar](#rawmaygetchar) - Takes a character from exec's own console if one is waiting.
- [RawPutChar](#rawputchar) - Sends one character to exec's own console.
- [ReleaseSemaphore](#releasesemaphore) - Gives back one obtain, and hands the semaphore on when it was the last.
- [ReleaseSemaphoreList](#releasesemaphorelist) - Gives back every semaphore on a list.
- [RemDevice](#remdevice) - Asks a device to go away, through its own Expunge vector.
- [RemHead](#remhead) - Takes the first node off a list and answers it.
- [RemIntServer](#remintserver) - Takes a server off an interrupt number's chain.
- [RemLibrary](#remlibrary) - Asks a library to go away, through its own Expunge vector.
- [RemMemHandler](#remmemhandler) - Takes a low-memory handler off the list.
- [RemPort](#remport) - Takes a port off the public list.
- [RemResource](#remresource) - Takes a resource off the resource list.
- [RemSemaphore](#remsemaphore) - Takes a semaphore off the public list.
- [RemTail](#remtail) - Takes the last node off a list and answers it.
- [RemTask](#remtask) - Ends a task, and frees what `CreateTask` allocated for it.
- [Remove](#remove) - Takes a node off whatever list it is on.
- [ReplyIO](#replyio) - For a device: finishes a request and sends it back.
- [ReplyMsg](#replymsg) - Sends a message back to whoever sent it.
- [ResModules](#resmodules) - Hands back the table of resident modules.
- [SendIO](#sendio) - Starts an I/O request and returns at once.
- [SetExcept](#setexcept) - Chooses which of the calling task's signals raise its exception code.
- [SetFunction](#setfunction) - Replaces one entry of a library's jump table and answers the old one.
- [SetIntVector](#setintvector) - Installs the one handler of an interrupt number.
- [SetMem](#setmem) - Fills memory with one byte value.
- [SetRamLib](#setramlib) - Tells exec where the module loader's base is.
- [SetSignal](#setsignal) - Reads or changes the calling task's signals without waiting.
- [SetTaskPri](#settaskpri) - Changes a task's priority, and reschedules if that changed who should run.
- [SetTrapCode](#settrapcode) - Sets the running task's trap code, which takes its CPU exceptions.
- [Signal](#signal) - Sends signals to a task, waking it if it was waiting for one of them.
- [Vacate](#vacate) - Withdraws a bid, or gives back the semaphore it won.
- [Wait](#wait) - Sleeps until one of a set of signals arrives.
- [WaitIO](#waitio) - Waits until a device is done with a request, and takes it back.
- [WaitPort](#waitport) - Waits until a port has a message, and answers the first one without taking it.

## AbortIO

Asks a device to stop a request it is working on.

**SYNOPSIS**

```zig
fn AbortIO(_: *ExecBase, io: *IORequest) i32
```

**SINCE**

1.0. LVO -348.

**INPUTS**

- `io` - a request from `SendIO`.

**RESULT**

0 if the device took the request back, or its own error if it could not.
`IOERR_OPENFAIL` if the device is not open.

**BEHAVIOR**

It **asks**. A device that can abort replies the request with
`IOERR_ABORTED`; one that cannot - a transfer already under way in
hardware - answers an error and the request finishes normally.

Either way **the request must still be collected with `WaitIO`**: this
does not take it back, it only asks for it to end sooner. That is the
step most easily forgotten, and skipping it leaves a request outstanding
on a port whose owner has moved on.

**CONTEXT**

- Waits: no.
- Interrupts: no; the device's AbortIO may do anything.
- Forbid: no.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands here. `WaitIO` is what gives the request back.

**BUGS**

None known.

**SEE ALSO**

`SendIO`, `WaitIO`, `CloseDevice`

**EXAMPLES**

```zig
_ = sys.AbortIO(@ptrCast(io));
_ = sys.WaitIO(@ptrCast(io)); // still owed
```

## AddDevice

Puts a device on the device list, where `OpenDevice` finds it.

**SYNOPSIS**

```zig
fn AddDevice(base: *ExecBase, dev: *Device) void
```

**SINCE**

1.0. LVO -312.

**INPUTS**

- `dev` - a built device, with its name, version and priority set.

**RESULT**

Nothing.

**BEHAVIOR**

As `AddLibrary`, on the device list instead: the node's type becomes a
device, it is enqueued by priority, and its jump table is summed.

The two lists are separate, so a name may be on both - a library and a
device of the same name are two different things and neither hides the
other.

**CONTEXT**

- Waits: no.
- Interrupts: no. It takes Forbid.
- Forbid: taken here, around the list.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The system holds the pointer until the device
expunges.

**NOTES**

The jump table is marked changed and summed before the device goes on
the list, so a device that asked for a checksum has one from the first
moment anyone can open it.

**BUGS**

None known.

**SEE ALSO**

`RemDevice`, `OpenDevice`, `AddLibrary`

**EXAMPLES**

```zig
sys.AddDevice(dev);
```

## AddHead

Puts a node at the head of a list.

**SYNOPSIS**

```zig
fn AddHead(base: *ExecBase, list: *List, node: *Node) void
```

**SINCE**

1.0. LVO -64.

**INPUTS**

- `list` - the list to add to.
- `node` - the node to add. Not already on a list.

**RESULT**

Nothing.

**BEHAVIOR**

`Insert` with no predecessor. The node's priority is not looked at, so a
list kept in priority order must be added to with `Enqueue` instead.

**CONTEXT**

- Waits: no.
- Interrupts: safe in itself; the caller's locking is what decides.
- Forbid: not taken here, and the caller's to take.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The list now holds the node.

**BUGS**

None known.

**SEE ALSO**

`AddTail`, `RemHead`, `Insert`

**EXAMPLES**

```zig
sys.AddHead(&list, &node);
```

## AddIntServer

Adds a server to an interrupt number's chain.

**SYNOPSIS**

```zig
fn AddIntServer(base: *ExecBase, int_number: u32,
    interrupt: *Interrupt) void
```

**SINCE**

1.0. LVO -132.

**INPUTS**

- `int_number` - a source from `sdk.hardware.intbits`.
- `interrupt` - an `Interrupt` whose `code` is an `IntServerFn` and
  whose `pri` decides its place in the chain.

**RESULT**

Nothing.

**BEHAVIOR**

Servers are kept in priority order and run in that order when the number
fires, **until one answers non-zero**, which means "this was mine and it
is dealt with" and ends the chain. A server that did not cause the
interrupt must answer 0 and let the next one look.

That is also why a server's source may share a CPU line: every chain on
the line runs, and each server decides for itself whether its hardware
raised it. A server that answers non-zero without checking will swallow
another peripheral's interrupt.

**CONTEXT**

- Waits: no. **The server itself must not wait**, allocate, or call
  anything that reaches a handler process.
- Interrupts: safe. It takes Disable.
- Forbid: not needed; Disable is what guards the chains.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The `Interrupt` stays the caller's and must
outlive its place on the chain.

**NOTES**

Work that cannot be done in an interrupt is passed on from one: `Signal`
a task, or `Cause` a software interrupt, and do it there.

**BUGS**

None known.

**SEE ALSO**

`RemIntServer`, `SetIntVector`, `Cause`, `Signal`

**EXAMPLES**

```zig
var server: exec.Interrupt = .{
    .node = .{ .pri = 0, .name = "my device" },
    .code = @ptrCast(&myServer),
    .data = self,
};
sys.AddIntServer(intbits.INTB_GPIO, &server);
```

## AddLibrary

Puts a library on the system library list, where `OpenLibrary` finds it.

**SYNOPSIS**

```zig
fn AddLibrary(base: *ExecBase, lib: *Library) void
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `lib` - a built library, from `MakeLibrary` or laid out by hand. Its
  `node.name`, `version` and `node.pri` are read here and must already
  be set.

**RESULT**

Nothing.

**BEHAVIOR**

The node's type becomes `.library` and it is enqueued by priority, so a
higher-priority library of the same name is the one `OpenLibrary`
finds. The jump table's checksum is taken now, since adding the library
is the last legitimate change before anyone can call it.

**CONTEXT**

- Waits: no.
- Interrupts: no. It takes Forbid, which an interrupt must not.
- Forbid: taken here, around the list.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The system now holds the pointer, and the library
must stay where it is until it expunges.

**NOTES**

A device goes on the device list instead, with `AddDevice`; the two
lists are separate and a name may appear on both.

The jump table is marked changed and summed before the library goes on
the list, so a library that asked for a checksum has one from the first
moment anyone can open it.

**BUGS**

None known.

**SEE ALSO**

`MakeLibrary`, `RemLibrary`, `CreateLibrary`, `AddDevice`

**EXAMPLES**

```zig
lib.node.name = "my.library";
lib.version = 1;
sys.AddLibrary(lib);
```

## AddMemHandler

Adds a handler that is asked to free memory when an allocation fails.

**SYNOPSIS**

```zig
fn AddMemHandler(base: *ExecBase, handler: *Interrupt) void
```

**SINCE**

1.0. LVO -120.

**INPUTS**

- `handler` - an `Interrupt` whose `code` is a `MemHandlerFn` and whose
  `pri` decides when it is asked. It is called with a `MemHandlerData`
  saying how much was wanted and with what requirements, and answers
  `MEM_DID_NOTHING`, `MEM_TRY_AGAIN` or `MEM_ALL_DONE`.

**RESULT**

Nothing.

**BEHAVIOR**

Handlers are enqueued by priority and asked highest first, and the
allocation is retried after each one that did something.
`MEM_TRY_AGAIN` asks the same handler again with `MEMHF_RECYCLE` set, so
one that frees a little at a time can be driven until the allocation
succeeds - which is how exec's own expunges one library per call rather
than emptying the machine on the first failed allocation.

**CONTEXT**

- Waits: no. **The handler itself must not wait either**: it runs inside
  `AllocMem`'s Forbid, where waiting stops the machine.
- Interrupts: no. It takes Forbid.
- Forbid: taken here for the list. The handler is later *called* under
  Forbid, which is the constraint that matters.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The `Interrupt` stays the caller's and must
outlive its place on the list.

**NOTES**

A handler is reached from inside an allocation, so anything it calls
must be safe to call there - which rules out allocating, and rules out
anything that reaches a handler process.

**BUGS**

None known.

**SEE ALSO**

`RemMemHandler`, `AllocMem`

**EXAMPLES**

```zig
var handler: exec.Interrupt = .{
    .node = .{ .pri = 0, .name = "my flusher" },
    .code = @ptrCast(&myFlusher),
};
sys.AddMemHandler(&handler);
```

## AddMemList

Hands a block of memory to the system, for anyone to allocate from.

**SYNOPSIS**

```zig
fn AddMemList(base: *ExecBase, size: usize, attributes: u32, pri: i8,
    region: *anyopaque, name: ?[*:0]const u8) ?*MemHeader
```

**SINCE**

1.0. LVO -96.

**INPUTS**

As `CreateMemHeader`, which this calls: `size` bytes at `region`,
`attributes` saying what the memory is, `pri` its place on the list, and
`name` for a listing.

**RESULT**

The header, now on the system memory list, or null if the block was too
small.

**BEHAVIOR**

The region is enqueued by priority, and from that moment any `AllocMem`
whose requirements it satisfies may take memory from it.

**CONTEXT**

- Waits: no.
- Interrupts: no. It takes Forbid for the memory list.
- Forbid: taken here, around the list.
- Process: a Task will do.

**OWNERSHIP**

The system holds it from here. There is no call that takes a region
back: memory given to exec stays given, because anything already
allocated from it would be left pointing into nothing.

**NOTES**

The machine's own regions are added at boot from `src/arch/esp32s3/ram.zig`,
with internal memory at the higher priority so that `MEMF_ANY` spends
external memory first and leaves what interrupts and DMA need.

**BUGS**

None known.

**SEE ALSO**

`CreateMemHeader`, `AllocMem`, `AvailMem`

**EXAMPLES**

```zig
_ = sys.AddMemList(size, exec.MEMF_EXTERNAL, -10, base, "external memory");
```

## AddPort

Makes a port public, so that anything can find it by name.

**SYNOPSIS**

```zig
fn AddPort(base: *ExecBase, port: *MsgPort) void
```

**SINCE**

1.0. LVO -220.

**INPUTS**

- `port` - the port, with its name and priority set and its action and
  signal already arranged.

**RESULT**

Nothing.

**BEHAVIOR**

The message list is initialised here, so a port need not have been
through `CreateMsgPort` - a port in a structure the caller allocated is
added the same way.

It is enqueued by priority, so a higher-priority port of the same name
is the one `FindPort` answers.

**CONTEXT**

- Waits: no.
- Interrupts: no. It takes Forbid.
- Forbid: taken here, around the list.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The port stays the caller's, and must not be freed
until it has been removed - anything may be sending to it.

**NOTES**

The port's message list is made empty here, so a port declared rather
than created needs nothing else before it is added.

**BUGS**

None known.

**SEE ALSO**

`RemPort`, `FindPort`, `CreateMsgPort`

**EXAMPLES**

```zig
port.node.name = "my.port";
sys.AddPort(port);
```

## AddResource

Puts a resource on the resource list, where `OpenResource` finds it.

**SYNOPSIS**

```zig
fn AddResource(base: *ExecBase, resource: *anyopaque) void
```

**SINCE**

1.0. LVO -388.

**INPUTS**

- `resource` - anything beginning with a Node whose name and priority
  are set. In practice a library base, so that callers reach it through
  a jump table.

**RESULT**

Nothing.

**BEHAVIOR**

The node's type becomes a resource and it is enqueued by priority.

`InitResident` does this for a ROM tag whose type is a resource, so a
resource in the image is added without anyone calling this.

**CONTEXT**

- Waits: no.
- Interrupts: no. It takes Forbid.
- Forbid: taken here, around the list.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The resource must outlive its place on the list,
which in practice means for ever.

**BUGS**

None known.

**SEE ALSO**

`OpenResource`, `RemResource`, `InitResident`

**EXAMPLES**

```zig
sys.AddResource(base);
```

## AddSemaphore

Makes a semaphore public, so that anything can find it by name.

**SYNOPSIS**

```zig
fn AddSemaphore(base: *ExecBase, sem: *SignalSemaphore) void
```

**SINCE**

1.0. LVO -268.

**INPUTS**

- `sem` - the semaphore, with its name and priority set. It is
  **initialised here**, so it must not already be held.

**RESULT**

Nothing.

**BEHAVIOR**

It is enqueued by priority, so a higher-priority semaphore of the same
name is the one `FindSemaphore` answers.

**CONTEXT**

- Waits: no.
- Interrupts: no. It takes Forbid.
- Forbid: taken here, around the list.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The semaphore stays the caller's and must outlive
every holder.

**BUGS**

None known.

**SEE ALSO**

`RemSemaphore`, `FindSemaphore`, `InitSemaphore`

**EXAMPLES**

```zig
sem.link.name = "my.lock";
sys.AddSemaphore(&sem);
```

## AddTail

Puts a node at the tail of a list.

**SYNOPSIS**

```zig
fn AddTail(base: *ExecBase, list: *List, node: *Node) void
```

**SINCE**

1.0. LVO -68.

**INPUTS**

- `list` - the list to add to.
- `node` - the node to add. Not already on a list.

**RESULT**

Nothing.

**BEHAVIOR**

`Insert` behind the last node. With `RemHead` it makes a queue that
keeps its order, which is what a message port is.

**CONTEXT**

- Waits: no.
- Interrupts: safe in itself; the caller's locking is what decides.
- Forbid: not taken here, and the caller's to take.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The list now holds the node.

**BUGS**

None known.

**SEE ALSO**

`AddHead`, `RemHead`, `Enqueue`

**EXAMPLES**

```zig
sys.AddTail(&list, &node);
```

## AddTask

Starts a task the caller has laid out, and makes it ready to run.

**SYNOPSIS**

```zig
fn AddTask(base: *ExecBase, task: *Task, init_pc: TaskFn,
    final_pc: ?TaskFn) *Task
```

**SINCE**

1.0. LVO -160.

**INPUTS**

- `task` - a `Task` the caller has filled in: its name and priority, and
  its stack in `sp_lower`/`sp_upper`. The memory must outlive the task.
- `init_pc` - where it starts. It is handed the SDK's `ExecBase`, which
  is how a task reaches the system without a global.
- `final_pc` - run when `init_pc` returns, or null. The task is removed
  afterwards either way, so this is the last chance to clean up.

**RESULT**

The task, so that `CreateTask` can hand it straight on.

**BEHAVIOR**

The node's type becomes a task unless it is already a process, which is
how dos's processes stay processes through the call that starts them.

The new task is enqueued as ready, and **if its priority is higher than
the running task's it runs at once** - before this call returns, since
the `Enable` at the end of it is a point at which a switch is taken.

**CONTEXT**

- Waits: no, but it may switch, so the caller may lose the processor
  here.
- Interrupts: no. It takes Disable and touches the scheduler's lists.
- Forbid: not needed. Under Forbid the switch is postponed to the
  matching `Permit`, which is a way to add several tasks before any of
  them runs.
- Process: a Task will do.

**OWNERSHIP**

The `Task` and its stack stay the caller's to free, and must not be
freed while the task can still run. `CreateTask` is the call that owns
them instead.

**NOTES**

The stack has to be big enough for the register windows the ABI spills
into it, which is why `CreateTask`'s smallest is 8 KiB rather than
something nominal.

**BUGS**

None known.

**SEE ALSO**

`CreateTask`, `RemTask`, `FindTask`, `SetTaskPri`

**EXAMPLES**

```zig
task.node.name = "my task";
task.node.pri = 0;
task.sp_lower = @intFromPtr(stack);
task.sp_upper = task.sp_lower + stack_size;
_ = sys.AddTask(task, &myTask, null);
```

## Alert

Reports that the system has a problem, and for a dead end stops.

**SYNOPSIS**

```zig
fn Alert(_: *ExecBase, alert_num: u32) void
```

**SINCE**

1.0. LVO -152.

**INPUTS**

- `alert_num` - what went wrong, with `AT_DeadEnd` set if the machine
  cannot carry on and `AT_Recovery` if it can.

**RESULT**

Nothing, and for `AT_DeadEnd` it does not return at all.

**BEHAVIOR**

The alert goes to whatever the kernel installed to show it, with the
**caller's own return address** as the second number - which is what
makes the display worth reading, since it names where the trouble was
found. The wrapper takes that address itself rather than calling
`Alert`, which would name the wrapper.

**CONTEXT**

- Waits: no, and it must not: the machine it would wait for is the one
  being reported.
- Interrupts: safe, and it is reached from one - a CPU exception ends
  here when no trap code takes it.
- Forbid: not needed, and not taken. It cannot be, since what is broken
  may be the scheduler.
- Process: a Task will do. It must work with no task at all, since it is
  reached before there are any.

**OWNERSHIP**

Nothing is allocated, on purpose: allocating to report a failure fails
when the failure is memory.

**NOTES**

The path that reports a broken machine does not go through the jump
table, and must not: a patched vector is one of the things that may be
what is broken.

The alert goes to exec's raw port, which needs no display and no
library: a library that shows the alert has to be working for the
alert to appear, and what is being reported may be the reason it is
not.

This names *its* caller as the place the trouble was found, which is
right for kernel code calling it directly. The jump-table wrapper takes
its own return address instead, so that a caller coming through the
table is named rather than the wrapper.

**BUGS**

None known.

**SEE ALSO**

`SetTrapCode`, `ColdReboot`

**EXAMPLES**

```zig
sys.Alert(exec.AT_DeadEnd | exec.AN_KernelPanic);
```

## AllocMem

Allocates memory from the system, from the first region that suits.

**SYNOPSIS**

```zig
fn AllocMem(base: *ExecBase, byte_size: usize,
    requirements: u32) ?*anyopaque
```

**SINCE**

1.0. LVO -108.

**INPUTS**

- `byte_size` - bytes wanted. Rounded up to `MEM_BLOCKSIZE`.
- `requirements` - what the memory must be, and how to take it:
  - `MEMF_ANY` - anywhere. On this machine that is external memory
    first, since internal memory is at the higher priority and kept for
    what needs it.
  - `MEMF_INTERNAL` - internal SRAM. What an interrupt reads, and what
    survives the caches being suspended.
  - `MEMF_EXTERNAL` - PSRAM. Where the big buffers go.
  - `MEMF_DMA` - reachable by a DMA descriptor's twenty address bits,
    and needing no cache maintenance.
  - `MEMF_CLEAR` - zero the block before answering.
  - `MEMF_REVERSE` - take it from the top of the region.
  - `MEMF_NO_EXPUNGE` - fail rather than ask the low-memory handlers.

**RESULT**

The block, `MEM_BLOCKSIZE`-aligned, or null: 0 bytes, or nothing fits
even after the handlers have run.

**BEHAVIOR**

Regions are tried in priority order and the first that has every
attribute bit asked for and room for the block wins.

**When nothing fits**, and `MEMF_NO_EXPUNGE` was not asked for, the
low-memory handlers are called highest priority first, and the
allocation is retried after each one that says it did something. One
handler is exec's own, which expunges libraries and devices nobody has
open - one per call, so only as much goes as the allocation needed.

**CONTEXT**

- Waits: no, and it must not - the handlers run inside its Forbid and
  are forbidden to wait for the same reason.
- Interrupts: no. It takes Forbid, and an interrupt must not allocate.
- Forbid: taken here, around the search, the handlers and the clear.
- Process: a Task will do.

**OWNERSHIP**

The caller's until `FreeMem` with the same size. Nothing tracks it, so a
block whose size is lost is a leak - which is what `AllocVec` exists to
prevent.

**NOTES**

The size a region actually gives up is the request rounded up, which is
why `memtrace`'s outstanding figure and the fall in what `AvailMem`
reports are the same number.

**BUGS**

None known.

**SEE ALSO**

`FreeMem`, `AllocVec`, `AvailMem`, `AddMemHandler`

**EXAMPLES**

```zig
const buf = sys.AllocMem(1024, exec.MEMF_INTERNAL | exec.MEMF_CLEAR)
    orelse return;
defer sys.FreeMem(buf, 1024);
```

## AllocPooled

Takes a block of memory from a pool.

**SYNOPSIS**

```zig
fn AllocPooled(base: *ExecBase, pool_handle: ?*anyopaque,
    byte_size: usize) ?*anyopaque
```

**SINCE**

1.0. LVO -456.

**INPUTS**

- `pool` - what CreatePool answered, or null.
- `byte_size` - how many bytes.

**RESULT**

The memory, or null: no pool, no bytes asked for, or the system had
none left to make a puddle from.

**BEHAVIOR**

A request below the pool's threshold is cut from a puddle that has
room, or from a new one. At or above it the request gets a puddle to
itself, which goes back to the system when the block is freed. The
memory is cleared only if the pool was made with MEMF_CLEAR.

**CONTEXT**

- Waits: no. - Interrupts: no; it may allocate. - Forbid: taken here,
  so one pool may be used from more than one task. - Process: a Task
  will do.

**OWNERSHIP**

The caller's until `FreePooled`, or until `DeletePool` takes the lot.

**NOTES**

The size has to be remembered by the caller, since the block carries no
header saying it. Where that is inconvenient, `AllocVec` is the call
that remembers instead - at the cost of a block per allocation.

**BUGS**

None known.

**SEE ALSO**

`FreePooled`, `DeletePool`, `AllocVec`

## AllocSignal

Takes a signal bit for the calling task's own use.

**SYNOPSIS**

```zig
fn AllocSignal(base: *ExecBase, signal_num: i8) i8
```

**SINCE**

1.0. LVO -188.

**INPUTS**

- `signal_num` - the bit wanted, 0 to 31; or **-1 for any free one**,
  which is what nearly every caller passes.

**RESULT**

The bit number, 0 to 31, or **-1** if it was taken or out of range. Not
a mask: `1 << bit` is the mask.

**BEHAVIOR**

Any free bit is searched from 31 down, so the low 16 the system uses are
reached last. The bit is cleared as it is handed out, so a stale signal
from a previous owner is not delivered to the new one.

**CONTEXT**

- Waits: no.
- Interrupts: no - it is the running task's bits.
- Forbid: not needed. Only the task itself can allocate its own signals.
- Process: a Task will do.

**OWNERSHIP**

The bit is the task's until `FreeSignal`. It belongs to **that task
alone**: a signal bit allocated by one task means nothing in another,
which is why a port carries its bit with it.

**NOTES**

There are 16 to hand out and no more. A task that allocates one per
request rather than one per port runs out, and -1 is easy to miss
because it looks like a bit number until it is shifted.

**BUGS**

None known.

**SEE ALSO**

`FreeSignal`, `Wait`, `CreateMsgPort`

**EXAMPLES**

```zig
const bit = sys.AllocSignal(-1);
if (bit < 0) return;
defer sys.FreeSignal(bit);
const mask = @as(u32, 1) << @intCast(bit);
```

## AllocVec

Allocates memory that remembers how big it is.

**SYNOPSIS**

```zig
fn AllocVec(base: *ExecBase, byte_size: usize,
    requirements: u32) ?*anyopaque
```

**SINCE**

1.0. LVO -292.

**INPUTS**

- `byte_size` - bytes wanted.
- `requirements` - exactly as `AllocMem` takes them. `MEMF_CLEAR` clears
  what the caller gets, not the header.

**RESULT**

The block, or null: 0 bytes, the size plus the header overflows, or
there was no memory.

**BEHAVIOR**

It allocates the header and the block as one and answers the address
past the header, with the whole size in the word immediately below it.

**CONTEXT**

- Waits: no.
- Interrupts: no. `AllocMem` takes Forbid.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's until `FreeVec`. It must not be freed with `FreeMem`: the
address is past the header, so the region would be handed the wrong
block.

**NOTES**

It costs `MEM_BLOCKSIZE` more than `AllocMem`, which is why the
alternative for many small blocks that die together is a pool, whose
blocks carry no header at all.

**BUGS**

None known.

**SEE ALSO**

`FreeVec`, `AllocMem`, `AllocPooled`

**EXAMPLES**

```zig
const buf = sys.AllocVec(1024, exec.MEMF_ANY | exec.MEMF_CLEAR)
    orelse return;
defer sys.FreeVec(buf);
```

## Allocate

Takes a block from one memory region, with no locking of any kind.

**SYNOPSIS**

```zig
fn Allocate(_: *ExecBase, mh: *MemHeader, byte_size: usize) ?*anyopaque
```

**SINCE**

1.0. LVO -100.

**INPUTS**

- `mh` - the region to take from. The caller's, or one on the system
  list with the caller holding Forbid.
- `byte_size` - bytes wanted. Rounded up to `MEM_BLOCKSIZE`, so the
  block that is actually spent may be larger than what was asked for.

**RESULT**

The block, `MEM_BLOCKSIZE`-aligned, or null: 0 bytes, or no free chunk
is big enough. The memory is **not** cleared.

**BEHAVIOR**

First fit: the first free chunk that is big enough, and the block comes
off its start. What is left over stays a chunk in the chain.

It takes no Forbid, on purpose. Keeping others away from `mh` is the
caller's job, which is what lets a pool use the same code on a puddle
nobody else can see - and what makes it the wrong call to reach for on a
system region.

**CONTEXT**

- Waits: no.
- Interrupts: only on a region the interrupt owns outright. On anything
  a task may be allocating from, no.
- Forbid: not taken here. The caller's, and needed for any region on the
  system list.
- Process: a Task will do.

**OWNERSHIP**

The caller's until `Deallocate` on the same region, with the same size.

**NOTES**

`byte_size` must be handed back to `Deallocate` unchanged: the block
carries no header saying how big it is, which is the whole reason a
pooled block costs no more than its own bytes.

The block comes off the chunk's start, and what is left of the chunk
stays where it was on the chain, so the chain stays in address order
without being walked again.

**BUGS**

None known.

**SEE ALSO**

`Deallocate`, `AllocMem`, `AllocPooled`

**EXAMPLES**

```zig
const block = sys.Allocate(mh, 256) orelse return;
defer sys.Deallocate(mh, block, 256);
```

## AttemptSemaphore

Takes a semaphore exclusively if that can be done without waiting.

**SYNOPSIS**

```zig
fn AttemptSemaphore(base: *ExecBase, sem: *SignalSemaphore) bool
```

**SINCE**

1.0. LVO -252.

**INPUTS**

- `sem` - an initialised semaphore.

**RESULT**

True if it is now the caller's - and then it must be released - or false
if someone else holds it, in which case nothing was taken.

**BEHAVIOR**

It succeeds if the semaphore is free or this task already holds it, so
it nests like `ObtainSemaphore`.

**CONTEXT**

- Waits: **no, and that is the point of it.** This is how a lock is
  taken from somewhere that must not block - an interrupt's task, or
  code holding another lock.
- Interrupts: no. It takes Forbid.
- Forbid: taken here, and not broken, since nothing waits.
- Process: a Task will do.

**OWNERSHIP**

On true, the caller holds it until `ReleaseSemaphore`. On false it owes
nothing.

**NOTES**

Releasing after a false is the mistake this call invites, and it raises
`AN_SemCorrupt` rather than passing quietly.

**BUGS**

None known.

**SEE ALSO**

`ObtainSemaphore`, `AttemptSemaphoreShared`, `ReleaseSemaphore`

**EXAMPLES**

```zig
if (!sys.AttemptSemaphore(&self.lock)) return false;
defer sys.ReleaseSemaphore(&self.lock);
```

## AttemptSemaphoreShared

Takes a semaphore shared if that can be done without waiting.

**SYNOPSIS**

```zig
fn AttemptSemaphoreShared(base: *ExecBase, sem: *SignalSemaphore) bool
```

**SINCE**

1.0. LVO -280.

**INPUTS**

- `sem` - an initialised semaphore.

**RESULT**

True if it is now the caller's to read, false if someone holds it
exclusively.

**BEHAVIOR**

It succeeds if the semaphore is free, held shared, or held by this task.

**CONTEXT**

- Waits: no.
- Interrupts: no. It takes Forbid.
- Forbid: taken here, and not broken.
- Process: a Task will do.

**OWNERSHIP**

On true, until `ReleaseSemaphore`. On false, nothing.

**BUGS**

None known.

**SEE ALSO**

`ObtainSemaphoreShared`, `AttemptSemaphore`

**EXAMPLES**

```zig
if (!sys.AttemptSemaphoreShared(&self.lock)) return null;
defer sys.ReleaseSemaphore(&self.lock);
```

## AvailMem

How much memory of a kind there is.

**SYNOPSIS**

```zig
fn AvailMem(base: *ExecBase, requirements: u32) usize
```

**SINCE**

1.0. LVO -116.

**INPUTS**

- `requirements` - which regions to count, by the same attribute bits
  `AllocMem` takes, and which question to ask:
  - nothing further - the free bytes.
  - `MEMF_LARGEST` - the largest single free chunk, which is the biggest
    allocation that could succeed.
  - `MEMF_TOTAL` - the regions' whole size, free or not. It wins over
    `MEMF_LARGEST`.

**RESULT**

The number of bytes. 0 if no region has the attributes asked for.

**BEHAVIOR**

Free and largest differ by fragmentation, and the gap between them is
the only measure of it the system offers.

**CONTEXT**

- Waits: no.
- Interrupts: no. It takes Forbid.
- Forbid: taken here, around the walk.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

The answer is out of date as soon as it is given, on a machine where
another task may allocate the moment Forbid is let go. It is worth
having as a measurement and not as a decision: allocate and test the
result instead.

**BUGS**

None known.

**SEE ALSO**

`AllocMem`, `AddMemList`

**EXAMPLES**

```zig
const free = sys.AvailMem(exec.MEMF_INTERNAL);
const biggest = sys.AvailMem(exec.MEMF_INTERNAL | exec.MEMF_LARGEST);
```

## CacheClearE

Clears the caches over one range of addresses.

**SYNOPSIS**

```zig
fn CacheClearE(base: *ExecBase, address: *anyopaque, length: u32,
    caches: u32) void
```

**SINCE**

1.0. LVO -408.

**INPUTS**

- `address` - the start of the range.
- `length` - its size in bytes, or `0xFFFFFFFF` for every address,
  which is then the same as `CacheClearU`.
- `caches` - `CACRF_ClearD`, `CACRF_ClearI`, or both.

**RESULT**

Nothing.

**BEHAVIOR**

`CACRF_ClearD` writes the range's dirty data lines back and invalidates
them.

`CACRF_ClearI` invalidates the range's instruction lines. For a range
given as a **data-bus** address the whole instruction cache is
invalidated instead, because where that memory is executed from is not
known here.

**CONTEXT**

- Waits: no.
- Interrupts: safe, though a partly covered line is handled with
  interrupts off.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`CacheClearU`, `CachePreDMA`, `CachePostDMA`

**EXAMPLES**

```zig
sys.CacheClearE(buf, len, exec.CACRF_ClearD);
```

## CacheClearU

Makes code written through the data bus runnable.

**SYNOPSIS**

```zig
fn CacheClearU(_: *ExecBase) void
```

**SINCE**

1.0. LVO -404.

**INPUTS**

None.

**RESULT**

Nothing.

**BEHAVIOR**

The whole data cache is written back and the whole instruction cache
invalidated, so instructions stored as data are actually in memory and
the processor will fetch them again rather than serve stale ones.

The data cache is **not** invalidated. Doing so would drop live data -
task stacks live in PSRAM - and a data line only goes stale through DMA,
which `CachePostDMA` covers.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

This is what a loader calls after relocating a program and before
running it. `CodeAddress` is the other half: this makes the code real,
that says where it can be executed from.

**BUGS**

None known.

**SEE ALSO**

`CacheClearE`, `CodeAddress`

**EXAMPLES**

```zig
sys.CacheClearU();
```

## CachePostDMA

Finishes with memory a DMA engine has used, so the CPU reads what was written.

**SYNOPSIS**

```zig
fn CachePostDMA(base: *ExecBase, address: *anyopaque, length: *u32,
    flags: u32) void
```

**SINCE**

1.0. LVO -416.

**INPUTS**

- `address` - the buffer, as given to `CachePreDMA`.
- `length` - in and out, the same way.
- `flags` - the same flags the transfer was prepared with.

**RESULT**

Nothing.

**BEHAVIOR**

The range is invalidated, so the next read comes from memory and not
from a line the cache held from before the transfer. Without this a
device's data is written and then read straight past.

**Nothing is done for `DMAF_ReadFromRAM` or `DMAF_NoModify`**: the
engine only read, so nothing in memory changed and there is nothing
stale to drop.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The buffer is the caller's to read again.

**BUGS**

None known.

**SEE ALSO**

`CachePreDMA`, `CacheClearE`

**EXAMPLES**

```zig
sys.CachePostDMA(buf.ptr, &len, 0);
```

## CachePreDMA

Prepares memory for a DMA engine to read or write, and says where that engine should look.

**SYNOPSIS**

```zig
fn CachePreDMA(_: *ExecBase, address: *anyopaque, length: *u32,
    flags: u32) *anyopaque
```

**SINCE**

1.0. LVO -412.

**INPUTS**

- `address` - the buffer. Should be 64-byte aligned.
- `length` - in and out: how many bytes, and how many this call has
  prepared. **It is never shortened here** - the range is not split -
  but a caller should still use what comes back rather than what it
  passed.
- `flags` - `DMAF_ReadFromRAM` when the engine will read, and
  `DMAF_Continue` for a later part of the same transfer.

**RESULT**

The address the DMA engine should use. On this machine it is the same
address, since the engine reaches PSRAM through the same numbers, and a
caller that relies on that rather than on the answer will be wrong on a
machine where it is not.

**BEHAVIOR**

Dirty lines over the range are written back, so what is in memory is
what the CPU last wrote.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The buffer must not be touched by the CPU while
the transfer runs.

**BUGS**

None known.

**SEE ALSO**

`CachePostDMA`, `CacheClearE`

**EXAMPLES**

```zig
var len: u32 = @intCast(buf.len);
const dma_addr = sys.CachePreDMA(buf.ptr, &len, exec.DMAF_ReadFromRAM);
```

## Cause

Queues a software interrupt, to run when no hardware interrupt is being handled.

**SYNOPSIS**

```zig
fn Cause(base: *ExecBase, interrupt: *Interrupt) void
```

**SINCE**

1.0. LVO -148.

**INPUTS**

- `interrupt` - an `Interrupt` whose `code` is a `SoftIntFn`, called
  with its `data` alone. Its `pri` is rounded down to one of -32, -16,
  0, 16, 32, which are the five queues.

**RESULT**

Nothing.

**BEHAVIOR**

It runs as soon as no hardware interrupt is being handled, highest
priority first, and still before any task - so it is where an interrupt
puts work that is too long for an interrupt but too urgent for a task.

**Causing one that is already queued does nothing**, which is what makes
it safe to call on every interrupt without counting: the flag is the
node's type, cleared the moment it is taken off the queue, so it may be
caused again from inside its own run.

**CONTEXT**

- Waits: no. **The software interrupt itself must not wait** either: it
  runs on no task's time and has no task to be suspended.
- Interrupts: safe, and this is its main caller.
- Forbid: not needed; it takes Disable.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The `Interrupt` must outlive its time on the
queue, so it cannot be freed between causing it and its running.

**NOTES**

It may allocate nothing and reach no handler, exactly as a hardware
interrupt may not. What it usefully can do is `Signal` a task, which is
how a device's interrupt reaches the process waiting on it.

**BUGS**

None known.

**SEE ALSO**

`Signal`, `AddIntServer`

**EXAMPLES**

```zig
sys.Cause(&self.soft_int);
```

## CheckIO

Asks whether a device is done with a request, without waiting.

**SYNOPSIS**

```zig
fn CheckIO(_: *ExecBase, io: *IORequest) ?*IORequest
```

**SINCE**

1.0. LVO -344.

**INPUTS**

- `io` - a request from `SendIO`.

**RESULT**

The request if the device is done with it, null if it is still working.

**BEHAVIOR**

**A non-null answer does not make the request the caller's again.** It
is still on the reply port, and `WaitIO` is what takes it off - which
after a successful check returns at once. Reusing a request on the
strength of this alone leaves it on a port it is no longer on terms
with.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It reads two fields.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands. `WaitIO` is still owed.

**BUGS**

None known.

**SEE ALSO**

`WaitIO`, `SendIO`, `AbortIO`

**EXAMPLES**

```zig
if (sys.CheckIO(@ptrCast(io)) != null) {
    _ = sys.WaitIO(@ptrCast(io)); // returns at once, and collects it
}
```

## CloseDevice

Closes a request's device.

**SYNOPSIS**

```zig
fn CloseDevice(base: *ExecBase, io: *IORequest) void
```

**SINCE**

1.0. LVO -324.

**INPUTS**

- `io` - a request that was opened. One whose open failed, or that was
  closed already, does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The device and unit fields are cleared, so closing twice is safe and a
closed request cannot be sent by mistake - `DoIO` on one answers
`IOERR_OPENFAIL` rather than calling into a device that is not open.

**Every request started must be finished first.** A device asked to
close while it still holds a request has no way to give it back.

**CONTEXT**

- Waits: no, though a device's own Close may.
- Interrupts: no. It takes Forbid.
- Forbid: taken here, around the vector.
- Process: a Task will do.

**OWNERSHIP**

The open count is given up. The request itself is still the caller's and
is freed with `DeleteIORequest`.

**BUGS**

None known.

**SEE ALSO**

`OpenDevice`, `AbortIO`, `DeleteIORequest`

**EXAMPLES**

```zig
defer sys.CloseDevice(io);
```

## CloseLibrary

Closes a library opened with `OpenLibrary`, through its Close vector.

**SYNOPSIS**

```zig
fn CloseLibrary(base: *ExecBase, library: ?*Library) void
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `lib` - what `OpenLibrary` answered, or null, which does nothing. The
  null case is so that a cleanup path need not test what it is closing.

**RESULT**

Nothing.

**BEHAVIOR**

The standard Close (`libClose`) drops `open_cnt` and, when that reaches
zero and `LIBF_DELEXP` is set, expunges the library there and then - so
a library marked for expunging while it was open goes on its last close.

A non-null result from the Close vector is the seglist of a library that
expunged, and exec drops it: nothing here loads a module, so nothing
here unloads one. Whatever has replaced this slot is what takes that up.

**CONTEXT**

- Waits: no.
- Interrupts: no. It takes Forbid.
- Forbid: taken here, around the vector.
- Process: a Task will do.

**OWNERSHIP**

The caller's open count is given up and the base must not be called
again. The library may be gone the moment this returns.

**BUGS**

None known.

**SEE ALSO**

`OpenLibrary`, `RemLibrary`

**EXAMPLES**

```zig
const ub = sys.OpenLibrary("utility.library", 1) orelse return;
defer sys.CloseLibrary(ub);
```

## CodeAddress

Says where memory written as data can be executed from.

**SYNOPSIS**

```zig
fn CodeAddress(_: *ExecBase, address: *anyopaque, length: u32) ?*anyopaque
```

**SINCE**

1.0. LVO -424.

**INPUTS**

- `address` - the memory, as a data-bus address - what `AllocMem`
  answered.
- `length` - how many bytes of it hold code.

**RESULT**

The same memory as the processor can fetch it, or null when the whole
range is not reachable on the instruction bus.

**BEHAVIOR**

The same PSRAM is reachable through two windows, one for data and one
for instructions, and only the second can be executed from. So a loader
writes the code through the address it allocated and **runs it through
this one**.

The range must lie wholly inside the executable window, which is the
eight megabytes PSRAM's page table covers.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It is arithmetic on two constants.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The answer is another view of the caller's own
memory, not a copy, and it is freed by freeing the original.

**NOTES**

`CacheClearU` must be called after writing the code and before running
it, or the processor may fetch what was there before.

**BUGS**

None known.

**SEE ALSO**

`CacheClearU`, `AllocMem`

**EXAMPLES**

```zig
const code = sys.AllocMem(size, exec.MEMF_EXTERNAL) orelse return;
// ... relocate into `code` ...
sys.CacheClearU();
const entry = sys.CodeAddress(code, size) orelse return;
```

## ColdReboot

Resets the machine.

**SYNOPSIS**

```zig
fn ColdReboot(base: *ExecBase) noreturn
```

**SINCE**

1.0. LVO -400.

**INPUTS**

None.

**RESULT**

It does not return.

**BEHAVIOR**

Interrupts go off and the chip's software system reset is set. Nothing
is shut down first: **no file system is flushed**, no device is told, no
task is asked to finish. Anything that has to survive must be on the
medium before this is called.

**CONTEXT**

- Waits: no.
- Interrupts: safe - it turns them off itself.
- Forbid: not needed. Nothing that follows cares.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated, and nothing is given back either.

**BUGS**

None known.

**SEE ALSO**

`Alert`

**EXAMPLES**

```zig
sys.ColdReboot();
```

## CopyMem

Copies bytes, whatever their alignment and however they overlap.

**SYNOPSIS**

```zig
fn CopyMem(_: *ExecBase, source: *const anyopaque, dest: *anyopaque,
    size: usize) void
```

**SINCE**

1.0. LVO -300.

**INPUTS**

- `source` - where the bytes come from. Any alignment.
- `dest` - where they go. Any alignment.
- `size` - how many. 0 does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

**Overlapping areas come out right**, in either direction: the copy runs
whichever way keeps it from overwriting what it has yet to read. That is
worth stating because it is the one thing a caller cannot test for
cheaply and the one that fails intermittently when it is wrong.

Word-sized loads and stores are used where the alignment allows.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It touches nothing but the two blocks.
- Forbid: not needed, and not taken.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`CopyMemQuick`, `SetMem`

**EXAMPLES**

```zig
sys.CopyMem(src, dst, len);
```

## CopyMemQuick

Copies whole words between word-aligned addresses.

**SYNOPSIS**

```zig
fn CopyMemQuick(base: *ExecBase, source: *const anyopaque,
    dest: *anyopaque, size: usize) void
```

**SINCE**

1.0. LVO -304.

**INPUTS**

- `source`, `dest` - 4-aligned.
- `size` - a multiple of 4.

**RESULT**

Nothing.

**BEHAVIOR**

Arguments that do not meet the conditions are **handed to `CopyMem`**
rather than giving a wrong answer, so this is always safe to call and
only sometimes faster. Overlap is handled, as there.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Forbid: not needed, and not taken.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`CopyMem`, `SetMem`

**EXAMPLES**

```zig
sys.CopyMemQuick(src, dst, words * 4);
```

## CreateIORequest

Allocates a cleared I/O request for a reply port.

**SYNOPSIS**

```zig
fn CreateIORequest(base: *ExecBase, reply_port: ?*MsgPort,
    size: u32) ?*IORequest
```

**SINCE**

1.0. LVO -364.

**INPUTS**

- `reply_port` - where replies go. Null answers null, so a failed
  `CreateMsgPort` may be passed straight in.
- `size` - bytes to allocate: `@sizeOf(IORequest)` at least, and **the
  size the device expects** - `IOStdReq`, `IOExtSer`, whatever its own
  header is. Too small for an `IORequest`, or past what the length field
  holds, answers null.

**RESULT**

The request, cleared, with its reply port and length set, or null.

**BEHAVIOR**

It is marked as replied - "finished" - so `CheckIO` on a fresh request
says it is idle rather than outstanding.

The size is kept in the request, which is what lets `DeleteIORequest`
free it without being told again.

**CONTEXT**

- Waits: no.
- Interrupts: no. It allocates.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's until `DeleteIORequest`, and its device must be closed
first.

**NOTES**

Getting the size wrong is the mistake that does not show up here.
A device handed a request smaller than its own type writes past the end
of the allocation, and what breaks is whatever was next in memory.

**BUGS**

None known.

**SEE ALSO**

`DeleteIORequest`, `CreateMsgPort`, `OpenDevice`

**EXAMPLES**

```zig
const port = sys.CreateMsgPort() orelse return;
defer sys.DeleteMsgPort(port);
const io = sys.CreateIORequest(port, @sizeOf(IOStdReq)) orelse return;
defer sys.DeleteIORequest(io);
```

## CreateLibrary

Makes a library from one description and adds it, name and all.

**SYNOPSIS**

```zig
fn CreateLibrary(base: *ExecBase, desc: *const LibraryInit) ?*Library
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `desc` - what the library is to be. `data_size` must be at least
  `@sizeOf(Library)`; `vectors` is the library's whole jump table, the
  four standard vectors first; `name` is required and `id_string` is
  not; `init` is run before the library is added, and null to refuse.

**RESULT**

The library base, already on the library list, or null: `data_size` was
too small, there was no memory, or `init` refused - in which case the
memory is freed before returning.

**BEHAVIOR**

It is `MakeLibrary` and `AddLibrary` with one difference that matters:
the name and the ID string are **copied into the library's own
memory**, past the module's data. So the library is a single block, and
its Expunge frees the name with it - which is what lets a library be
created by code that then goes away, and what `MakeLibrary` alone
cannot offer.

The init routine runs while the library is still off the list, so
nothing can open it half-built; it is added only if the init agrees.

**CONTEXT**

- Waits: no, unless `init` does.
- Interrupts: no. It allocates and takes Forbid.
- Forbid: not needed; `AddLibrary` takes it for the list.
- Process: a Task will do, unless `init` needs more.

**OWNERSHIP**

The system holds it from here. It goes with `RemLibrary`, or on the last
`CloseLibrary` after something marked it.

**NOTES**

A resource is made the same way and put on the resource list with
`AddResource` instead, which is why no shape of vector table is
required.

**BUGS**

None known.

**SEE ALSO**

`MakeLibrary`, `AddLibrary`, `AddResource`

**EXAMPLES**

```zig
const lib = sys.CreateLibrary(&.{
    .name = "my.library",
    .version = 1,
    .data_size = @sizeOf(MyBase),
    .vectors = &my_vectors,
    .init = &myInit,
}) orelse return;
```

## CreateMemHeader

Lays a MemHeader over a block of memory, without adding it to the system.

**SYNOPSIS**

```zig
fn CreateMemHeader(_: *ExecBase, size: usize, attributes: u32, pri: i8,
    region: *anyopaque, name: ?[*:0]const u8) ?*MemHeader
```

**SINCE**

1.0. LVO -92.

**INPUTS**

- `size` - bytes at `region`, header included.
- `attributes` - what this memory *is*: `MEMF_INTERNAL`, `MEMF_EXTERNAL`,
  `MEMF_DMA`. The allocation options (`MEMF_CLEAR` and the rest) are not
  region attributes and are ignored here.
- `pri` - where the region goes on the memory list. `AllocMem` tries
  higher priorities first, so the memory that should be spent last is
  given the lower number.
- `region` - the block. Aligned up to the header's alignment inside, so an
  unaligned base costs a few bytes rather than failing.
- `name` - what a listing calls it, or null. Not copied: it must outlive
  the region, which for a region named by the kernel is the ROM image.

**RESULT**

The header, which sits at the start of the block, or null: the block is
too small for a header and one chunk, or the free space will not fit a
`u32`.

**BEHAVIOR**

The free space is one chunk covering everything from behind the header,
rounded up to `MEM_BLOCKSIZE`, to the top rounded down - so a region
never hands out a block that straddles its own end.

The region is not on the memory list, so `AllocMem` cannot reach it.
`AddMemList` is both steps; this one exists for memory that is to be cut
up privately, which is what a pool's puddle is.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It touches only the caller's block.
- Forbid: not needed. Nothing else knows about this memory yet.
- Process: a Task will do.

**OWNERSHIP**

The header lives in the caller's block, so the two cannot be separated:
freeing the block frees the region.

**NOTES**

This is how exec's own regions are made at boot, and how a pool lays a
header over a puddle - exec's allocator over a smaller arena rather than
a second allocator.

**BUGS**

None known.

**SEE ALSO**

`AddMemList`, `Allocate`, `CreatePool`

**EXAMPLES**

```zig
const mh = sys.CreateMemHeader(block_size, exec.MEMF_INTERNAL,
    0, block, "scratch") orelse return;
```

## CreateMsgPort

Makes a private port that signals the calling task.

**SYNOPSIS**

```zig
fn CreateMsgPort(base: *ExecBase) ?*MsgPort
```

**SINCE**

1.0. LVO -232.

**INPUTS**

None.

**RESULT**

The port, or null if there was no memory or no free signal bit.

**BEHAVIOR**

It allocates the port, takes a signal bit and sets the port to signal
**the calling task** with it - which is why the task that creates a port
is the only one that can usefully wait on it.

The port is private: it has no name and is not on the public list, so
nothing can find it. It is reached by being handed the pointer, which is
what every reply port is.

**CONTEXT**

- Waits: no.
- Interrupts: no. It allocates and takes a signal.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's until `DeleteMsgPort`, which must be called **by the same
task**, since the signal bit is that task's.

**BUGS**

None known.

**SEE ALSO**

`DeleteMsgPort`, `AddPort`, `AllocSignal`, `CreateIORequest`

**EXAMPLES**

```zig
const port = sys.CreateMsgPort() orelse return;
defer sys.DeleteMsgPort(port);
```

## CreatePool

Makes a pool to take many small blocks from.

**SYNOPSIS**

```zig
fn CreatePool(base: *ExecBase, requirements: u32, puddle_size: usize,
    thresh_size: usize) ?*anyopaque
```

**SINCE**

1.0. LVO -448.

**INPUTS**

- `requirements` - MEMF_* as AllocMem takes them, for every puddle the
  pool goes on to take. MEMF_CLEAR here means every block handed out is
  cleared, not only the first.
- `puddle_size` - what the pool asks the system for at a time. A
  puddle's own header comes out of this, so it must be bigger than one.
- `thresh_size` - a request this big or bigger gets memory of its own
  rather than a share of a puddle. Larger than a puddle can hold is
  taken as the largest it can hold, and 0 means no threshold at all -
  only a request too big for a puddle gets its own.

**RESULT**

The pool, or null: there was no memory, or `puddle_size` was too small
to hold a puddle's header.

**BEHAVIOR**

Nothing is taken from the system yet. The first `AllocPooled` takes the
first puddle.

**CONTEXT**

- Waits: no. - Interrupts: no; it allocates. - Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

The caller's until `DeletePool`, which frees the pool and everything
still in it.

**NOTES**

A pool is worth having where the blocks are small and die together. A
pooled block carries no header, so a 24-byte node costs 24 bytes rather
than a whole block more for a size word in front of it.

**BUGS**

None known.

**SEE ALSO**

`DeletePool`, `AllocPooled`, `FreePooled`

**EXAMPLES**

```zig
const pool = sys.CreatePool(exec.MEMF_ANY, 4096, 1024) orelse return;
defer sys.DeletePool(pool);
```

## CreateTask

Allocates a task with a stack of its own, and starts it.

**SYNOPSIS**

```zig
fn CreateTask(base: *ExecBase, name: [:0]const u8, pri: i8,
    init_pc: TaskFn, stack_size: usize) ?*Task
```

**SINCE**

1.0. LVO -196.

**INPUTS**

- `name` - what the task is called. **Copied** into the task's own
  memory, so the caller's string need not outlive the call.
- `pri` - its priority.
- `init_pc` - where it starts, handed the SDK's `ExecBase`.
- `stack_size` - bytes of stack, or 0 for the default 8 KiB. Rounded up
  to at least a task's smallest.

**RESULT**

The task, already running or ready, or null if there was no memory.

**BEHAVIOR**

The `Task`, its name and its stack are one allocation, so `RemTask`
frees the whole of it in one call - which is what makes this the pair to
use when nothing else owns the task's memory.

As with `AddTask`, a task of higher priority than the caller's runs
before this returns.

**CONTEXT**

- Waits: no, but it may switch.
- Interrupts: no. It allocates.
- Forbid: not needed.
- Process: a Task will do. This makes a Task and not a Process - dos's
  `CreateNewProc` is what makes one of those, and only a Process may
  reach a file system.

**OWNERSHIP**

The task owns its memory and `RemTask` frees it. The caller must not
free anything, and must not use the pointer after the task has ended.

**NOTES**

The pointer is worth only as much as the task's life. A task that ends
on its own leaves the caller holding freed memory, so either the caller
outlives the task or the two arrange something between them.

**BUGS**

None known.

**SEE ALSO**

`AddTask`, `RemTask`, `SetTaskPri`

**EXAMPLES**

```zig
const task = sys.CreateTask("my task", 0, &myTask, 0) orelse return;
```

## Deallocate

Gives a block back to the region it came from, merging it with its free neighbours.

**SYNOPSIS**

```zig
fn Deallocate(_: *ExecBase, mh: *MemHeader, memory_block: ?*anyopaque,
    byte_size: usize) void
```

**SINCE**

1.0. LVO -104.

**INPUTS**

- `mh` - the region the block came from. The wrong region is fatal.
- `memory_block` - what `Allocate` answered, or null, which does
  nothing.
- `byte_size` - the size that was allocated. 0 does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The block is rounded out to `MEM_BLOCKSIZE`, put into the
address-ordered free chain and merged with a free chunk on either side,
so a region that is emptied ends up with one chunk again rather than a
chain of the pieces it was cut into.

Two things are fatal rather than ignored, because both mean memory is
already being handed to two owners and carrying on would hide that until
somewhere else:

**Outside the region.** The block is not between the region's bounds.

**Freed twice.** The block overlaps free memory - a chunk below it
reaches into it, or the chunk above starts before its end.

**CONTEXT**

- Waits: no.
- Interrupts: only on a region the interrupt owns outright.
- Forbid: not taken here. The caller's, as with `Allocate`.
- Process: a Task will do.

**OWNERSHIP**

The memory is the region's again and must not be touched.

**NOTES**

A block outside the region, or one that overlaps free memory, stops the
machine: either is a caller that has lost track of its memory, and
carrying on would hand the same bytes out twice.

**BUGS**

None known.

**SEE ALSO**

`Allocate`, `FreeMem`

**EXAMPLES**

```zig
sys.Deallocate(mh, block, 256);
```

## DeleteIORequest

Frees a request from `CreateIORequest`.

**SYNOPSIS**

```zig
fn DeleteIORequest(base: *ExecBase, io: ?*IORequest) void
```

**SINCE**

1.0. LVO -368.

**INPUTS**

- `io` - one from `CreateIORequest`, or null, which does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The size is read from the request itself, so the caller need not
remember it.

**Its device must be closed first**, and nothing may still be
outstanding on it: a device holding a freed request writes into memory
that is now someone else's.

**CONTEXT**

- Waits: no.
- Interrupts: no. It frees memory.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

The memory is the system's again.

**BUGS**

None known.

**SEE ALSO**

`CreateIORequest`, `CloseDevice`

**EXAMPLES**

```zig
defer sys.DeleteIORequest(io);
```

## DeleteMsgPort

Frees a port from `CreateMsgPort`, and its signal bit.

**SYNOPSIS**

```zig
fn DeleteMsgPort(base: *ExecBase, port: ?*MsgPort) void
```

**SINCE**

1.0. LVO -236.

**INPUTS**

- `port` - one from `CreateMsgPort`, or null, which does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The signal bit goes back and the memory with it.

**A public port must be removed with `RemPort` first**, and any messages
still queued replied, since neither is done here - freeing a port with
messages on it loses them, and their senders wait for ever.

**CONTEXT**

- Waits: no.
- Interrupts: no. It frees memory and a signal.
- Forbid: not needed.
- Process: a Task will do, and it must be **the task that created it**.

**OWNERSHIP**

The memory is the system's again.

**BUGS**

None known.

**SEE ALSO**

`CreateMsgPort`, `RemPort`, `FreeSignal`

**EXAMPLES**

```zig
defer sys.DeleteMsgPort(port);
```

## DeletePool

Frees everything a pool holds, and the pool with it.

**SYNOPSIS**

```zig
fn DeletePool(base: *ExecBase, pool_handle: ?*anyopaque) void
```

**SINCE**

1.0. LVO -452.

**INPUTS**

- `pool` - what CreatePool answered, or null, which does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

Every puddle goes back to the system. Nothing needs to have been freed
first, and no block in the pool may be touched afterwards.

**CONTEXT**

- Waits: no. - Interrupts: no; it frees memory. - Forbid: taken here.
- Process: a Task will do.

**OWNERSHIP**

Every puddle goes back to the system, and nothing the pool handed out
may be touched again.

**BUGS**

None known.

**SEE ALSO**

`CreatePool`, `FreePooled`

## Disable

Masks every interrupt until the matching `Enable`.

**SYNOPSIS**

```zig
fn Disable(base: *ExecBase) void
```

**SINCE**

1.0. LVO -140.

**INPUTS**

None.

**RESULT**

Nothing.

**BEHAVIOR**

It nests, and the state from before the **outermost** Disable is what
the outermost Enable puts back - so a Disable/Enable pair inside an
interrupt leaves interrupts masked, which is what they already were.

It guards what interrupts themselves touch: the interrupt vectors, the
server chains and the software interrupt queues. What only tasks touch -
the library, device, memory, port and semaphore lists - is Forbid's, and
Disable is the heavier of the two because it stops the machine
responding to its hardware.

**CONTEXT**

- Waits: no. Never `Wait` while holding it, for the same reason as
  Forbid and more so.
- Interrupts: safe, and the nesting is what makes it so.
- Forbid: neither implies the other. Task switching is not stopped by
  this, except that a switch cannot be delivered while interrupts are
  masked.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The caller owes an `Enable`.

**NOTES**

Hold it for as short a span as will do. Every interrupt the machine has
is late by however long it is held, and on this board that includes the
panel's refill, which has 460 microseconds to do 230 microseconds of
work before the picture tears.

The count starts at -1, so one Disable brings it to 0, which is the
point at which the state to be put back is saved.

**BUGS**

None known.

**SEE ALSO**

`Enable`, `Forbid`, `Cause`

**EXAMPLES**

```zig
sys.Disable();
defer sys.Enable();
```

## DoIO

Does one I/O request and waits for it to finish.

**SYNOPSIS**

```zig
fn DoIO(base: *ExecBase, io: *IORequest) i32
```

**SINCE**

1.0. LVO -328.

**INPUTS**

- `io` - a request on an open device, with its command and arguments
  filled in.

**RESULT**

The request's error: 0 for success, a negative `IOERR_*` or a device's
own code otherwise. `IOERR_OPENFAIL` if the device is not open.

**BEHAVIOR**

It asks for a quick answer by setting `IOF_QUICK`, and the device
decides:

**Finished inside BeginIO.** The flag is still set, no message was sent,
and the error is read straight out of the request. Nothing waits and
nothing is queued - which is what lets a short transfer cost no more
than a function call.

**Finished later.** The device cleared the flag and kept the request,
and this waits with `WaitIO`.

The error starts as `IOERR_OPENFAIL`, so a device that answers without
setting it reports failure rather than a false success.

**CONTEXT**

- Waits: **usually** - only a request the device finished inside BeginIO
  comes back without waiting, and which those are is the device's to
  say, not the caller's to rely on.
- Interrupts: no. It may wait.
- Forbid: no. It may wait, and a device's work may reach a handler.
- Process: a Task will do, unless the device wants more.

**OWNERSHIP**

The request is the device's until this returns, and the caller's again
afterwards. Its buffers must stay put and untouched for that time.

**NOTES**

The request needs a reply port for the slow path. A request with none
that the device does not finish quickly cannot be waited for.

The error starts as `IOERR_OPENFAIL`, so a device that answers without
setting it reports a failure rather than a false success.

**BUGS**

None known.

**SEE ALSO**

`SendIO`, `WaitIO`, `CheckIO`, `AbortIO`

**EXAMPLES**

```zig
io.command = CMD_WRITE;
io.data = buf.ptr;
io.length = buf.len;
if (sys.DoIO(@ptrCast(io)) != 0) return error.WriteFailed;
```

## Enable

Unmasks interrupts again, and takes any task switch that came due.

**SYNOPSIS**

```zig
fn Enable(base: *ExecBase) void
```

**SINCE**

1.0. LVO -144.

**INPUTS**

None.

**RESULT**

Nothing.

**BEHAVIOR**

Only the outermost Enable unmasks, and it restores the state from before
the outermost Disable rather than simply enabling - so this never turns
interrupts on in a context that had them off.

A switch asked for while interrupts were masked - by a `Signal` or an
`AddTask` from inside one - is taken here, so like `Permit` this is a
point at which the caller may lose the processor.

**CONTEXT**

- Waits: no, but it may switch.
- Interrupts: safe. Inside one, the nesting means it does not unmask.
- Forbid: unrelated.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`Disable`, `Permit`

**EXAMPLES**

```zig
sys.Disable();
defer sys.Enable();
```

## Enqueue

Puts a node on a list in priority order.

**SYNOPSIS**

```zig
fn Enqueue(base: *ExecBase, list: *List, node: *Node) void
```

**SINCE**

1.0. LVO -84.

**INPUTS**

- `list` - a list already in priority order. On a list that is not, the
  result is not ordered either: this places one node, it does not sort.
- `node` - the node to add, its `pri` already set. Not already on a list.

**RESULT**

Nothing.

**BEHAVIOR**

It walks from the head and goes in behind every node of the same or
higher priority - so equal priorities keep the order they were added in,
first in nearer the head. That fairness is what makes a ready queue of
equal-priority tasks round-robin rather than starving the later ones.

Highest priority at the head is why `FindName` answering the first match
answers the best one.

**CONTEXT**

- Waits: no.
- Interrupts: safe in itself; the caller's locking is what decides.
- Forbid: not taken here, and the caller's to take.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The list now holds the node.

**NOTES**

It walks the list, so it is the one list call whose cost grows with the
list's length.

It goes in behind every node of the same or higher priority, so equal
priorities keep the order they arrived in - which is what makes a ready
queue of equal tasks round-robin.

**BUGS**

None known.

**SEE ALSO**

`AddTail`, `FindName`, `AddLibrary`, `AddIntServer`

**EXAMPLES**

```zig
node.pri = 10;
sys.Enqueue(&list, &node);
```

## ExecList

Hands back one of exec's own lists.

**SYNOPSIS**

```zig
fn ExecList(base: *ExecBase, which: u32) ?*List
```

**SINCE**

1.0. LVO -428.

**INPUTS**

- `which` - `EXECLIST_MEMORY`, `_LIBRARIES`, `_DEVICES`, `_RESOURCES`,
  `_PORTS`, `_SEMAPHORES`, `_TASK_READY`, `_TASK_WAIT` or
  `_MEM_HANDLERS`.

**RESULT**

The list, or null for a number exec has no list for - which is how a
program built against a later version degrades rather than faults.

**BEHAVIOR**

It is the live list. Nothing is copied and nothing is locked.

**The caller's side of the bargain**: hold Forbid while walking, or
Disable for the two task queues, since those are what a switch touches.
Write nothing. Keep no node past the lock - copy out the fields wanted
and let go before doing anything with them.

That last rule is not advice. Printing reaches a file system, a file
system is a process, and a process cannot run while the scheduler is
held - so a listing that prints as it walks stops the machine. It is why
every listing in this tree copies a node's fields out under the lock and
prints them after.

**CONTEXT**

- Waits: no.
- Interrupts: safe - it returns a pointer and reads nothing.
- Forbid: not taken here. The caller's, and required for the walk.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. Everything on the list belongs to whoever put it
there.

**NOTES**

`C:Show` is what this was added for.

**BUGS**

None known.

**SEE ALSO**

`FindName`, `IntVector`, `ResModules`, `Forbid`

**EXAMPLES**

```zig
sys.Forbid();
var it = sys.ExecList(EXECLIST_LIBRARIES).?.iterator();
while (it.next()) |node| {
    // ... copy out what is wanted ...
}
sys.Permit();
// ... print it now ...
```

## FindName

Finds the first node of a list with a given name.

**SYNOPSIS**

```zig
fn FindName(_: *ExecBase, list: *List, name: [*:0]const u8) ?*Node
```

**SINCE**

1.0. LVO -48.

**INPUTS**

- `list` - the list to walk. Any exec list; the system's own are reached
  with `ExecList`.
- `name` - what to match. Compared exactly, case included.

**RESULT**

The node, or null if no node of that name is on the list. A node with no
name is skipped rather than matched against.

**BEHAVIOR**

It walks from the head and answers the first match, so where two nodes
share a name the one nearer the head wins - which on a list kept by
priority is the higher-priority one. That is how a library or a device
is replaced by adding a better one in front of it.

To find the second match, carry on from the node this answered rather
than calling again.

**CONTEXT**

- Waits: no.
- Interrupts: safe in itself. On a system list, only if the caller can
  be sure nothing is changing it, which from an interrupt it cannot.
- Forbid: not taken here, and needed by the caller for any list another
  task may change - which is every list exec owns.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The node belongs to whatever put it on the list,
and is only worth the pointer for as long as the lock is held.

**NOTES**

Case matters. A name that is typed by a user is matched somewhere else,
with utility.library's `Stricmp`, before it reaches this.

**BUGS**

None known.

**SEE ALSO**

`Enqueue`, `ExecList`, `FindPort`, `FindSemaphore`

**EXAMPLES**

```zig
sys.Forbid();
defer sys.Permit();
const node = sys.FindName(sys.ExecList(EXECLIST_DEVICE).?, "timer.device");
```

## FindPort

Finds a public port by name.

**SYNOPSIS**

```zig
fn FindPort(base: *ExecBase, name: [*:0]const u8) ?*MsgPort
```

**SINCE**

1.0. LVO -228.

**INPUTS**

- `name` - the port's name, matched exactly, case included.

**RESULT**

The port, or null if there is none of that name.

**BEHAVIOR**

**The port may go away as soon as Forbid is let go**, and this call
takes and releases Forbid itself. So the pointer is only trustworthy
while the caller holds Forbid *across* both this and the `PutMsg` that
follows - which is the usual shape and the reason the two are almost
always written together.

**CONTEXT**

- Waits: no.
- Interrupts: no. It takes Forbid.
- Forbid: taken here for the search, and needed by the caller around
  the call and the send.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`AddPort`, `PutMsg`, `FindName`

**EXAMPLES**

```zig
sys.Forbid();
defer sys.Permit();
const port = sys.FindPort("my.port") orelse return;
sys.PutMsg(port, &msg);
```

## FindResident

Finds a resident module by name.

**SYNOPSIS**

```zig
fn FindResident(base: *ExecBase, name: [*:0]const u8) ?*const Resident
```

**SINCE**

1.0. LVO -352.

**INPUTS**

- `name` - the tag's name, matched exactly.

**RESULT**

The tag, or null if there is none of that name.

**BEHAVIOR**

Where two tags share a name the boot scan kept only the higher version,
so this answers that one and there is no second to find.

**CONTEXT**

- Waits: no.
- Interrupts: safe. **The list does not change after the boot scan**,
  which is why this needs no lock at all.
- Forbid: not needed, for the same reason.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The tag is in the ROM image and outlives
everything.

**NOTES**

This is how dos finds a handler: a device node names its handler, and
the first use looks the tag up here rather than loading anything.

**BUGS**

None known.

**SEE ALSO**

`InitResident`, `InitCode`, `ResModules`

**EXAMPLES**

```zig
const tag = sys.FindResident("con-handler") orelse return;
```

## FindSemaphore

Finds a public semaphore by name.

**SYNOPSIS**

```zig
fn FindSemaphore(base: *ExecBase, name: [*:0]const u8) ?*SignalSemaphore
```

**SINCE**

1.0. LVO -264.

**INPUTS**

- `name` - the semaphore's name, matched exactly.

**RESULT**

The semaphore, or null if there is none of that name.

**BEHAVIOR**

As with `FindPort`, the semaphore may go away as soon as Forbid is let
go, so the caller holds Forbid from before this until it has obtained
it. Obtaining breaks that Forbid, but by then the semaphore is held and
cannot be removed from under the caller.

**CONTEXT**

- Waits: no.
- Interrupts: no. It takes Forbid.
- Forbid: taken here for the search, and needed by the caller across
  this and the obtain.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated, and nothing is obtained.

**BUGS**

None known.

**SEE ALSO**

`AddSemaphore`, `ObtainSemaphore`, `FindPort`

**EXAMPLES**

```zig
sys.Forbid();
const sem = sys.FindSemaphore("my.lock");
if (sem) |x| sys.ObtainSemaphore(x);
sys.Permit();
```

## FindTask

Finds a task by name, or answers the calling task.

**SYNOPSIS**

```zig
fn FindTask(base: *ExecBase, name: ?[*:0]const u8) ?*Task
```

**SINCE**

1.0. LVO -168.

**INPUTS**

- `name` - the task's name, matched exactly; or **null, which answers
  the running task** without searching anything.

**RESULT**

The task, or null if no task of that name exists.

**BEHAVIOR**

The running task is checked first, then the ready and waiting lists -
which is what makes the null case free and the named case a search of
every task there is.

**CONTEXT**

- Waits: no.
- Interrupts: the null case only, and even then the answer is whichever
  task was interrupted. A named search takes Disable.
- Forbid: not needed; Disable is taken here, since the task lists are
  what an interrupt's switch touches.
- Process: a Task will do. `FindTask(null)` is also how code finds out
  whether it is a task or a process, from the node's type.

**OWNERSHIP**

Nothing is allocated. The pointer is only good while the task exists,
and nothing here stops it ending the moment Disable is let go - which is
why a task is usually found in order to `Signal` it immediately.

**NOTES**

Two tasks may share a name, and then which one is answered is not worth
relying on. dos gives each shell process a number in its name for that
reason, and finds its own with `FindCliProc` rather than by name.

**BUGS**

None known.

**SEE ALSO**

`AddTask`, `Signal`, `FindPort`

**EXAMPLES**

```zig
const me = sys.FindTask(null).?;
if (sys.FindTask("timer.device")) |t| sys.Signal(t, 1 << sig);
```

## Forbid

Holds task switching until the matching `Permit`.

**SYNOPSIS**

```zig
fn Forbid(base: *ExecBase) void
```

**SINCE**

1.0. LVO -52.

**INPUTS**

None.

**RESULT**

Nothing.

**BEHAVIOR**

It raises a nesting count, so Forbid and Permit pair and may be nested.
While it is held the running task keeps the processor until it gives it
up, and a switch that comes due in the meantime is taken at the `Permit`
that lets the count go negative again.

**It does not disable interrupts.** What it guards is what only tasks
touch: the library list, the device list, the memory list and its
handlers, the port and semaphore lists. Interrupt code must not touch
any of those - no `AllocMem`, no `OpenLibrary` from an interrupt - and
what interrupts *do* touch, the interrupt vectors and the software
interrupt queues, is guarded by `Disable` instead.

**CONTEXT**

- Waits: no. Never `Wait` while holding it: the task that would signal
  you cannot run, so it is a machine that has stopped rather than a
  deadlock that resolves.
- Interrupts: pointless rather than unsafe. An interrupt cannot be
  switched away from, so it is already as forbidden as it can be.
- Forbid: this is it. Nesting is fine and is the normal case.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The caller owes a `Permit`, and an error path that
returns without one stops the machine - which is why every use in this
tree is `defer`red on the next line.

**NOTES**

Anything that reaches a file system cannot run under Forbid, because a
handler is a process and a process cannot run while the scheduler is
held. That is why a listing copies its fields out under the lock and
prints them after letting it go.

The count starts at -1, so one Forbid brings it to 0 and "held" is
"not negative".

**BUGS**

None known.

**SEE ALSO**

`Permit`, `Disable`, `ObtainSemaphore`

**EXAMPLES**

```zig
sys.Forbid();
defer sys.Permit();
// ... walk a system list, copying out what is wanted ...
```

## FreeMem

Gives memory back to the system.

**SYNOPSIS**

```zig
fn FreeMem(base: *ExecBase, memory_block: ?*anyopaque,
    byte_size: usize) void
```

**SINCE**

1.0. LVO -112.

**INPUTS**

- `memory_block` - what `AllocMem` answered, or null, which does
  nothing so that a cleanup path need not test it.
- `byte_size` - **the size that was allocated**, not the size that was
  used. 0 does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The region holding that address is found on the memory list and the
block goes back to it. A block in no region at all is fatal: it is
either an address that was never allocated or one already freed and
handed to someone else, and both are worth stopping for.

**CONTEXT**

- Waits: no.
- Interrupts: no. It takes Forbid.
- Forbid: taken here, around the search and the free.
- Process: a Task will do.

**OWNERSHIP**

The memory is the system's again and must not be touched.

**NOTES**

The size has to be right. Too small leaves the difference unreachable;
too large frees memory that was never the caller's, which `Deallocate`
catches as a double free only if it happens to overlap something free.

A block in no region stops the machine: it is a caller freeing memory
the system never gave out.

**BUGS**

None known.

**SEE ALSO**

`AllocMem`, `FreeVec`, `Deallocate`

**EXAMPLES**

```zig
defer sys.FreeMem(buf, 1024);
```

## FreePooled

Gives a block from `AllocPooled` back to its pool.

**SYNOPSIS**

```zig
fn FreePooled(base: *ExecBase, pool_handle: ?*anyopaque,
    memory_block: ?*anyopaque, byte_size: usize) void
```

**SINCE**

1.0. LVO -460.

**INPUTS**

- `pool` - the pool it came from, or null, which does nothing.
- `memory_block` - the block, or null, which does nothing.
- `byte_size` - **what was asked for**. A pooled block carries no
  header saying how big it is, which is the point of a pool, so this
  number is how the pool knows.

**RESULT**

Nothing.

**BEHAVIOR**

The space goes back to its puddle and is merged with what is free
either side of it, so the next request can have it. An ordinary puddle
stays with the pool even when nothing is left in it; `DeletePool` is
how memory goes back to the system.

**CONTEXT**

- Waits: no. - Interrupts: no. - Forbid: taken here. - Process: a Task
  will do.

**OWNERSHIP**

The space is the pool's again and must not be touched.

**NOTES**

A block in none of the pool's puddles stops the machine: it is a caller
freeing into the wrong pool, and by the time it is noticed the heap is
already wrong - the same answer `FreeMem` gives to a block freed twice.

The size is the caller's word and nothing checks it: a pooled block
keeps no record of its size, which is what makes a pool cost nothing
per block. A size that runs into free space stops the machine as a
double free does; one that is too small leaves the rest of the block
taken until `DeletePool`, and one that is too big frees whatever lies
after the block.

**BUGS**

None known.

**SEE ALSO**

`AllocPooled`, `DeletePool`

## FreeSignal

Gives a signal bit back.

**SYNOPSIS**

```zig
fn FreeSignal(base: *ExecBase, signal_num: i8) void
```

**SINCE**

1.0. LVO -192.

**INPUTS**

- `signal_num` - a bit from `AllocSignal`. Out of range does nothing, so
  a failed allocation's -1 may be passed on without testing.

**RESULT**

Nothing.

**BEHAVIOR**

The bit is free to be allocated again. Whether it is currently *set* is
not looked at, so anything still signalling it will set a bit its next
owner did not expect - which is why what signals it is taken down first.

**CONTEXT**

- Waits: no.
- Interrupts: no - it is the running task's bits.
- Forbid: not needed.
- Process: a Task will do, and it must be **the task that allocated
  it**.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`AllocSignal`, `DeleteMsgPort`

**EXAMPLES**

```zig
defer sys.FreeSignal(bit);
```

## FreeVec

Gives back memory from `AllocVec`.

**SYNOPSIS**

```zig
fn FreeVec(base: *ExecBase, memory_block: ?*anyopaque) void
```

**SINCE**

1.0. LVO -296.

**INPUTS**

- `memory_block` - what `AllocVec` answered, or null, which does
  nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The size is read from the word below the block and the whole thing,
header included, goes back.

**CONTEXT**

- Waits: no.
- Interrupts: no. `FreeMem` takes Forbid.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

The memory is the system's again.

**NOTES**

Only on a block from `AllocVec`. On anything else it reads whatever is
in front of the address as a size and frees that much.

**BUGS**

None known.

**SEE ALSO**

`AllocVec`, `FreeMem`

**EXAMPLES**

```zig
defer sys.FreeVec(buf);
```

## GetMsg

Takes the oldest message off a port, without waiting.

**SYNOPSIS**

```zig
fn GetMsg(base: *ExecBase, port: *MsgPort) ?*Message
```

**SINCE**

1.0. LVO -208.

**INPUTS**

- `port` - the caller's own port.

**RESULT**

The message, or null if the queue is empty.

**BEHAVIOR**

It never waits, which is what makes the drain loop right: a signal may
stand for any number of messages, so what follows a wakeup is `while
(GetMsg())` and not one `GetMsg` per signal.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It takes Disable, which is how a port with
  `PA_SOFTINT` is drained.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

The message is the receiver's until it replies. If it has a reply port
it must be replied, or the sender waits for ever.

**NOTES**

The list is taken from under Disable, because an interrupt may be
putting a message on it.

**BUGS**

None known.

**SEE ALSO**

`PutMsg`, `ReplyMsg`, `WaitPort`

**EXAMPLES**

```zig
_ = sys.Wait(mask);
while (sys.GetMsg(port)) |msg| {
    // ... deal with it ...
    sys.ReplyMsg(msg);
}
```

## InitCode

Starts every resident module of a start class, highest priority first.

**SYNOPSIS**

```zig
fn InitCode(base: *ExecBase, start_class: u32, version: u32) ?*anyopaque
```

**SINCE**

1.0. LVO -356.

**INPUTS**

- `start_class` - the flag bits a tag must **all** have:
  `RTF_SINGLETASK` before multitasking, `RTF_COLDSTART` for the ordinary
  boot, `RTF_AFTERDOS` once dos.library is up.
- `min_version` - the lowest version to start, or 0 for any.

**RESULT**

SysBase if every one of them started, or null if one failed - and the
rest are then not started at all.

**BEHAVIOR**

Priority order is the machine's boot order, and it is the only thing
sequencing the modules: a driver at a lower priority than the library it
registers with can rely on that library being there.

**A module that fails stops the boot.** For an `RTF_AUTOINIT` tag that
is a dead-end alert rather than a return, since a library that could not
be built leaves everything above it with nothing to open.

**CONTEXT**

- Waits: whatever the modules do. Cold start runs on the exec task after
  `Permit`, so a module may wait, allocate and open other modules.
- Interrupts: no.
- Forbid: **not held.** A module that needs the machine to itself takes
  Forbid for itself - which is what the display driver does, since the
  panel is held in reset for tens of milliseconds.
- Process: a Task. There is no Process until dos.library is up, which is
  itself a cold-start module.

**OWNERSHIP**

Each module owns what it made.

**BUGS**

None known.

**SEE ALSO**

`InitResident`, `FindResident`

**EXAMPLES**

```zig
_ = sys.InitCode(exec.RTF_AFTERDOS, 0);
```

## InitResident

Starts one resident module.

**SYNOPSIS**

```zig
fn InitResident(base: *ExecBase, tag: *const Resident,
    seg_list: ?*anyopaque) ?*anyopaque
```

**SINCE**

1.0. LVO -360.

**INPUTS**

- `tag` - the ROM tag, from `FindResident` or found in a loaded image.
- `seg_list` - the module's segments, for a module that was loaded, or
  null for one in the ROM. It is handed to the init routine and kept by
  the library, so that expunging it can give the code back.

**RESULT**

The library, device or resource base for an `RTF_AUTOINIT` tag; whatever
the init routine answered otherwise, or SysBase if it had none. Null if
the tag is not one, or the module refused.

**BEHAVIOR**

**With `RTF_AUTOINIT`**: exec builds the module from the InitTable, puts
the tag's name, type, version and ID string into the base, runs the
table's init routine, and then adds it to the library, device or
resource list according to the tag's type. A refused init has its memory
freed before returning.

**Without it**: the tag's init routine is called with `seg_list` and
SysBase, and does whatever it likes - starting a process, for instance,
which is what a dos handler's tag does.

exec's own tag is refused: exec is built once, by the bootstrap, before
there is anything to build it with.

**CONTEXT**

- Waits: whatever the module does.
- Interrupts: no. It allocates.
- Forbid: not taken, and not needed.
- Process: a Task will do, unless the module wants more.

**OWNERSHIP**

The module owns itself from here and goes on its expunge.

**NOTES**

This is the call that makes a module loaded from a disk no different
from one in the ROM: ramlib loads the file, finds the tag in it and
calls this, and what comes out is on the same list as everything else.

**BUGS**

None known.

**SEE ALSO**

`InitCode`, `FindResident`, `MakeLibrary`

**EXAMPLES**

```zig
const base = sys.InitResident(tag, seg_list) orelse return;
```

## InitSemaphore

Prepares a semaphore for use.

**SYNOPSIS**

```zig
fn InitSemaphore(_: *ExecBase, sem: *SignalSemaphore) void
```

**SINCE**

1.0. LVO -240.

**INPUTS**

- `sem` - the semaphore to prepare. Whatever state it was in is
  forgotten, so this must not be done to one that anything holds.

**RESULT**

Nothing.

**BEHAVIOR**

It must be done before the first obtain. A zeroed semaphore is not an
initialised one: the count that says "free" is -1 rather than 0, and its
queue is a list that must be made empty before anything is added to it.

**CONTEXT**

- Waits: no.
- Interrupts: safe in itself, though nothing else about a semaphore is.
- Forbid: not needed. Nothing can be holding a semaphore that does not
  exist yet.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The semaphore lives in the caller's memory, which
must outlive every holder.

**NOTES**

`AddSemaphore` does this itself, so a public semaphore is not
initialised twice.

A free semaphore has a queue count of -1: the count is one less than
the obtains outstanding, held or queued, so the first takes it to 0.

**BUGS**

None known.

**SEE ALSO**

`ObtainSemaphore`, `AddSemaphore`

**EXAMPLES**

```zig
sys.InitSemaphore(&self.lock);
```

## Insert

Puts a node on a list after a given node.

**SYNOPSIS**

```zig
fn Insert(_: *ExecBase, list: *List, node: *Node, pred: ?*Node) void
```

**SINCE**

1.0. LVO -60.

**INPUTS**

- `list` - the list to insert into.
- `node` - the node to insert. Not already on a list.
- `pred` - the node to go behind, which must be on `list`; null puts it
  at the head.

**RESULT**

Nothing.

**BEHAVIOR**

Four pointer writes and no test for the ends, because the list header is
the sentinel at both: inserting at the head and inserting in the middle
are the same four writes.

**CONTEXT**

- Waits: no.
- Interrupts: safe in itself; the caller's locking is what decides.
- Forbid: not taken here. Needed by the caller on any list another task
  may be walking.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The list now holds the node, which must outlive
its place on it.

**NOTES**

Four pointer writes and no test for the ends: with no predecessor the
list header's head sentinel stands in for one, so the head insert and
the middle insert are the same writes.

**BUGS**

None known.

**SEE ALSO**

`AddHead`, `AddTail`, `Enqueue`, `Remove`

**EXAMPLES**

```zig
sys.Insert(&list, &node, after);
```

## IntVector

Hands back one interrupt number's vector.

**SYNOPSIS**

```zig
fn IntVector(base: *ExecBase, int_number: u32) ?*sdk.exec.IntVector
```

**SINCE**

1.0. LVO -432.

**INPUTS**

- `int_number` - a source from `sdk.hardware.intbits`.

**RESULT**

The vector - its handler, its server chain and how many times the source
has fired - or null if the number is out of range.

**BEHAVIOR**

The live vector, as `ExecList` hands back a live list. **Hold Disable**
while reading it: this is state an interrupt itself changes, so Forbid
is not enough.

The count is raised whether or not anything is listening, so a source
that fires while its driver is not being woken still shows here - which
is what makes it worth reading when a device seems dead.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Forbid: not enough. Disable is what guards the vectors.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`SetIntVector`, `AddIntServer`, `ExecList`

**EXAMPLES**

```zig
sys.Disable();
const count = if (sys.IntVector(n)) |v| v.count else 0;
sys.Enable();
```

## MakeLibrary

Builds a library in memory and runs its init routine, without putting it on the library list.

**SYNOPSIS**

```zig
fn MakeLibrary( base: *ExecBase, vectors: []const *const anyopaque,
    data_size: usize, init: ?InitFn, seg_list: ?*anyopaque, ) ?*Library
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `vectors` - the jump table, in slot order: Open, Close, Expunge,
  ExtFunc, then the library's own functions. Every library brings its
  own table; a resource has no standard vectors and starts at its own
  first function, which is why no shape is required beyond "at least
  one".
- `count` - how many entries `vectors` has. At least 1.
- `data_size` - bytes of base, `@sizeOf(Library)` at least. The Library
  header is at the front and the module's own state follows it.
- `init_fn` - run on the built library, or null for none. It is handed
  the library, `seg_list` and the SDK's `ExecBase`, and answers the
  library or null to refuse.
- `seg_list` - passed to `init_fn` untouched. Null for a module in the
  ROM; a loaded module's segments otherwise.

**RESULT**

The library base, or null: `count` was 0, `data_size` was smaller than a
Library header, the table or the base would not fit a `u16`, there was
no memory, or `init_fn` refused - in which case the memory is freed
before returning.

**BEHAVIOR**

The block is cleared, the vectors are written below the base and the
header's `neg_size` and `pos_size` are filled in. The base is 8-aligned
whatever the vector count, because a module's data may hold 64-bit
fields; the table is rounded up to that and the spare word sits at its
far end, below the last vector.

The library is not on any list when this returns, so nothing can open
it yet. `AddLibrary` is the second step, and `CreateLibrary` is both in
one.

**CONTEXT**

- Waits: no.
- Interrupts: no. It allocates, and `init_fn` may do anything.
- Forbid: not needed, and not taken here.
- Process: a Task will do, unless `init_fn` needs more.

**OWNERSHIP**

The caller's until it is added and expunged, or freed by hand. The name
and ID string are *not* copied: whatever the init routine puts in
`node.name` must outlive the library, which for a ROM module is the ROM
image. `CreateLibrary` is the call that copies them.

**NOTES**

`count` and `vectors` are two arguments here and one slice inside,
because a jump table cannot carry a Zig slice.

**BUGS**

None known.

**SEE ALSO**

`AddLibrary`, `CreateLibrary`, `RemLibrary`

**EXAMPLES**

```zig
const vectors = [_]*const anyopaque{
    exec.vec(myOpen), exec.vec(myClose), exec.vec(myExpunge),
    exec.vec(myExtFunc), exec.vec(myFunc),
};
const lib = sys.MakeLibrary(&vectors, vectors.len,
    @sizeOf(MyBase), &myInit, null) orelse return;
sys.AddLibrary(lib);
```

## NewList

Makes a list empty and ready to use.

**SYNOPSIS**

```zig
fn NewList(_: *ExecBase, list: *List) void
```

**SINCE**

1.0. LVO -88.

**INPUTS**

- `list` - the header to prepare. Whatever was on it is forgotten rather
  than freed.

**RESULT**

Nothing.

**BEHAVIOR**

The two sentinels are pointed at each other, which is what an empty list
is. The list's type is left alone, so a header whose type was set when
it was declared keeps it.

A list must go through this before anything is added to it. A zeroed
header is not an empty list - its sentinels are null rather than
pointing at each other, and the first `AddTail` writes through one.

**CONTEXT**

- Waits: no.
- Interrupts: safe in itself; the caller's locking is what decides.
- Forbid: not needed. Nothing can be walking a list that does not exist
  yet.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated, and nothing on the old list is freed.

**BUGS**

None known.

**SEE ALSO**

`AddTail`, `Enqueue`

**EXAMPLES**

```zig
var list: exec.List = undefined;
sys.NewList(&list);
```

## NewStackRun

Runs a function on a stack of its own, and comes back.

**SYNOPSIS**

```zig
fn NewStackRun(base: *ExecBase, code: sdk.exec.StackFn, arg: ?*anyopaque,
    stack_size: u32) i32
```

**SINCE**

1.0. LVO -420.

**INPUTS**

- `code` - what to run. It is handed `arg` and answers an `i32`.
- `arg` - passed through untouched.
- `stack_size` - bytes of stack to allocate, at least a task's smallest.

**RESULT**

What `code` answered, or -1 if there was no memory for the stack.

**BEHAVIOR**

The running task's `sp_lower` and `sp_upper` follow the new stack while
the code runs and are put back afterwards, so anything that checks how
much stack is left sees the right one.

It is a call, not a task: the same task runs `code`, on different
memory, and control comes back when it returns.

**CONTEXT**

- Waits: only if `code` does.
- Interrupts: no. It allocates.
- Forbid: not needed.
- Process: whatever `code` needs. It stays the same task, so a Process
  is still a Process inside it.

**OWNERSHIP**

The stack is allocated and freed here. `code` must leave nothing
pointing into it: the memory is gone when this returns.

**NOTES**

This is how a command gets a big stack without being a task of its own -
dos's `RunCommand` is the caller that matters.

A stack cannot simply be swapped under compiled code here, because the
register windows have to be spilled and the caller's save area moved
with the stack pointer. That is done in `src/arch/esp32s3/stack.S` around one
call, which is why this is a call and not a pair of "set the stack" and
"put it back" functions.

**BUGS**

None known.

**SEE ALSO**

`CreateTask`, `AddTask`

**EXAMPLES**

```zig
const rc = sys.NewStackRun(&runIt, ctx, 16 * 1024);
```

## ObtainSemaphore

Takes a semaphore exclusively, waiting until it is free.

**SYNOPSIS**

```zig
fn ObtainSemaphore(base: *ExecBase, sem: *SignalSemaphore) void
```

**SINCE**

1.0. LVO -244.

**INPUTS**

- `sem` - an initialised semaphore.

**RESULT**

Nothing. It returns when the semaphore is the caller's.

**BEHAVIOR**

The owner may obtain it again and again; **every obtain needs its
release**, which is what makes it safe for one of a module's functions
to call another that also takes the lock.

A waiter is queued in order and handed the semaphore directly when it
comes free, so it cannot be overtaken.

**CONTEXT**

- Waits: yes, whenever another task holds it.
- Interrupts: no. It waits.
- Forbid: it takes Forbid, and the `Wait` inside breaks it while
  waiting - so a caller must **not** hold Forbid across this expecting
  it to be held throughout.
- Process: a Task will do.

**OWNERSHIP**

The caller holds it until `ReleaseSemaphore`. An error path that returns
without releasing locks the semaphore for good, which is why every use
in this tree is `defer`red.

**NOTES**

A task already holding it shared must not then ask for it exclusively:
that waits for a release that only it can do. Two locks must be taken in
the same order by everyone, for the same reason.

**BUGS**

None known.

**SEE ALSO**

`ReleaseSemaphore`, `AttemptSemaphore`,
`ObtainSemaphoreShared`, `Procure`

**EXAMPLES**

```zig
sys.ObtainSemaphore(&self.lock);
defer sys.ReleaseSemaphore(&self.lock);
```

## ObtainSemaphoreList

Takes every semaphore on a list, exclusively, all or nothing.

**SYNOPSIS**

```zig
fn ObtainSemaphoreList(base: *ExecBase, list: *List) void
```

**SINCE**

1.0. LVO -256.

**INPUTS**

- `list` - a list of semaphores, linked through their own node.

**RESULT**

Nothing. It returns when all of them are the caller's.

**BEHAVIOR**

**Every request is queued before any is waited for**, which is the whole
reason this call exists: two tasks each taking the same semaphores one
at a time can end up each holding half and waiting for the other, and
queueing them all at once cannot.

Only one task at a time may do this over the same semaphores, because
each semaphore has one request built into it for the purpose. Two tasks
doing it at once want another semaphore between them to arbitrate.

**CONTEXT**

- Waits: yes, until the last one is granted.
- Interrupts: no. It waits.
- Forbid: taken here and broken by the waiting, as with
  `ObtainSemaphore`.
- Process: a Task will do.

**OWNERSHIP**

The caller holds them all until `ReleaseSemaphoreList`.

**NOTES**

A semaphore created while a list is held has to be accounted for: it
joins a list that will be released as a list, so it must inherit the
hold rather than start free. Getting that wrong shows up as an alert
from the release rather than at the creation.

**BUGS**

None known.

**SEE ALSO**

`ReleaseSemaphoreList`, `ObtainSemaphore`

**EXAMPLES**

```zig
sys.ObtainSemaphoreList(&li.lock_list);
defer sys.ReleaseSemaphoreList(&li.lock_list);
```

## ObtainSemaphoreShared

Takes a semaphore shared, alongside other shared holders.

**SYNOPSIS**

```zig
fn ObtainSemaphoreShared(base: *ExecBase, sem: *SignalSemaphore) void
```

**SINCE**

1.0. LVO -276.

**INPUTS**

- `sem` - an initialised semaphore.

**RESULT**

Nothing. It returns when the semaphore is the caller's to read.

**BEHAVIOR**

Several tasks may hold it shared at once, and none may hold it
exclusively while they do - which is what makes it the lock for
something read often and written rarely.

**A shared request is granted while the semaphore is held shared, even
with exclusive waiters queued ahead of it.** So a steady stream of
readers can keep a writer waiting indefinitely, and that is a property
of the lock rather than a bug in it.

The exclusive owner asking for it shared simply nests.

**CONTEXT**

- Waits: yes, whenever someone holds it exclusively.
- Interrupts: no. It waits.
- Forbid: taken here and broken by the waiting.
- Process: a Task will do.

**OWNERSHIP**

The caller holds it until `ReleaseSemaphore` - the same release for
both kinds.

**NOTES**

A shared holder must not then ask for it exclusively. That waits for
every shared holder to let go, itself included, so it never returns.

**BUGS**

None known.

**SEE ALSO**

`ObtainSemaphore`, `AttemptSemaphoreShared`, `ReleaseSemaphore`

**EXAMPLES**

```zig
sys.ObtainSemaphoreShared(&self.lock);
defer sys.ReleaseSemaphore(&self.lock);
```

## OpenDevice

Opens a unit of a device, for a request to use.

**SYNOPSIS**

```zig
fn OpenDevice(base: *ExecBase, name: [*:0]const u8, unit: u32,
    io: *IORequest, flags: u32) i32
```

**SINCE**

1.0. LVO -320.

**INPUTS**

- `name` - the device's name, matched exactly.
- `unit` - which unit. What a unit number means is the device's own.
- `io` - the request that will be used with this device. **It must be
  big enough for what the device expects**: serial.device wants an
  `IOExtSer`, and a plain `IORequest` there is memory the device will
  write past.
- `flags` - device-specific open flags. Not the request's own flags: a
  serial device's shared-access bit goes in the request, not here.

**RESULT**

0 if it opened. Otherwise the device's error, which is also left in the
request's error byte; `IOERR_OPENFAIL` when there is no device of that
name.

**BEHAVIOR**

The request's device field is set before the Open vector runs and
cleared again if it refuses, so a failed open leaves a request that is
safe to pass to `CloseDevice` and to `DoIO` - both of which check it.

The device's Open picks the unit and writes it into the request. From
then on the request carries both, which is why a request is what is
opened rather than a handle being answered.

**CONTEXT**

- Waits: no as exec has it, though a device's own Open may. With
  ramlib.library in front of it, it may: the replacement loads the
  device from DEVS:.
- Interrupts: no. It takes Forbid.
- Forbid: taken here, around the search and the vector.
- Process: a Task will do for exec's own. ramlib's replacement needs a
  Process, and sends the work to its own when a Task calls it.

**OWNERSHIP**

The caller holds an open count and must `CloseDevice` the request.
Several requests may be opened on one unit, and each is closed.

**NOTES**

exec searches the device list and nothing else. What loads a device from
DEVS: is ramlib.library, which replaces this slot.

**BUGS**

None known.

**SEE ALSO**

`CloseDevice`, `DoIO`, `CreateIORequest`, `OpenLibrary`

**EXAMPLES**

```zig
const io = sys.CreateIORequest(port, @sizeOf(IOExtSer)) orelse return;
defer sys.DeleteIORequest(io);
if (sys.OpenDevice("serial.device", 0, io, 0) != 0) return;
defer sys.CloseDevice(io);
```

## OpenLibrary

Opens a library by name at a version, through its own Open vector.

**SYNOPSIS**

```zig
fn OpenLibrary(base: *ExecBase, name: [*:0]const u8,
    version: u32) ?*Library
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `name` - the library's name, as it is on its node. Matched exactly,
  case included.
- `ver` - the lowest version that will do. 0 takes whatever is there.

**RESULT**

The library base to call through, or null: there is no library of that
name, it is older than `ver`, or its Open vector refused.

**BEHAVIOR**

The version check is here rather than in the library, so every library
gets it without writing it. It is also the only thing standing between a
caller and a slot that does not exist: a jump table only grows at the
end, so a library that is new enough has every slot an older one had.
A caller that asks for 0 and then calls a function only a later version
has has ignored the mechanism built for it.

The Open vector is what counts the opener. The standard one
(`libOpen`) raises `open_cnt` and clears `LIBF_DELEXP`, so a library
marked for expunging is reprieved by being opened again.

**CONTEXT**

- Waits: no as exec has it. With ramlib.library in front of it, it may:
  the replacement loads the module from LIBS:, which reaches a handler.
- Interrupts: no. It takes Forbid, and the Open vector may do anything.
- Forbid: taken here, around the search and the vector.
- Process: a Task will do for exec's own. ramlib's replacement needs a
  Process to load from a disk, and sends the work to its own when a bare
  Task calls it.

**OWNERSHIP**

The caller now holds an open count and must `CloseLibrary` it. Until
then the library cannot expunge.

**NOTES**

exec's own search is the library list and nothing else. What loads a
module from LIBS: is ramlib.library, which replaces this slot with
`SetFunction` - which is the whole reason a module's own calls go
through the jump table.

**BUGS**

None known.

**SEE ALSO**

`CloseLibrary`, `OpenDevice`, `SetRamLib`

**EXAMPLES**

```zig
const ub = sys.OpenLibrary("utility.library", 1) orelse return;
defer sys.CloseLibrary(ub);
```

## OpenResource

Finds a resource by name.

**SYNOPSIS**

```zig
fn OpenResource(base: *ExecBase, res_name: [*:0]const u8) ?*anyopaque
```

**SINCE**

1.0. LVO -396.

**INPUTS**

- `res_name` - the resource's name, matched exactly.

**RESULT**

The resource, or null if there is none of that name - which for a
resource that only exists on some boards is the ordinary answer and not
an error.

**BEHAVIOR**

It is called "open" for the shape of the thing, but **nothing is
counted and there is no close**. The pointer is good for as long as the
machine is running.

**CONTEXT**

- Waits: no.
- Interrupts: no. It takes Forbid.
- Forbid: taken here, around the search.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated and nothing is owed.

**NOTES**

A resource is how a program reaches a fact of the machine it cannot
import: platform.resource holds the chip's, expander.resource a pin
that is not the chip's own. What is soldered on the board comes from
expansion.library.

**BUGS**

None known.

**SEE ALSO**

`AddResource`, `OpenLibrary`

**EXAMPLES**

```zig
const pb = sys.OpenResource("platform.resource") orelse return;
```

## Permit

Lets task switching happen again, and takes any switch that came due.

**SYNOPSIS**

```zig
fn Permit(base: *ExecBase) void
```

**SINCE**

1.0. LVO -56.

**INPUTS**

None.

**RESULT**

Nothing.

**BEHAVIOR**

It drops the nesting count, and when that takes it below zero - no
Forbid outstanding - a switch that fell due while the scheduler was held
is taken here. So `Permit` is a point at which the caller may lose the
processor, which the call before it was not.

This is also what starts multitasking: the boot code holds Forbid from
before there are any tasks, and the `Permit` that matches it is the
moment the machine becomes preemptive.

**CONTEXT**

- Waits: no, but it may switch, which looks the same to the caller.
- Interrupts: no. An interrupt that let the scheduler go would switch
  tasks from inside an interrupt.
- Forbid: it is the release of it. One more `Permit` than `Forbid`
  leaves the count wrong and the next Forbid holding nothing.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

Because a switch may happen here, nothing may be held across it that a
switch would invalidate - a pointer into a list that another task is now
free to change has to be finished with before the Permit, not after.

**BUGS**

None known.

**SEE ALSO**

`Forbid`, `Enable`

**EXAMPLES**

```zig
sys.Forbid();
defer sys.Permit();
```

## Procure

Bids for a semaphore with a message, instead of waiting for it.

**SYNOPSIS**

```zig
fn Procure(base: *ExecBase, sem: *SignalSemaphore,
    bid: *SemaphoreMessage) void
```

**SINCE**

1.0. LVO -284.

**INPUTS**

- `sem` - an initialised semaphore.
- `bid` - a `SemaphoreMessage` with a reply port. Its name says whether
  the bid is shared.

**RESULT**

Nothing is answered here. **The bid comes back to its reply port** when
the semaphore is granted - at once if it is free - with its semaphore
field set to say which one was won.

**BEHAVIOR**

This is how a task waits for a lock *and* for other things at the same
time: the bid arrives as a message, so it can be waited for beside a
port, a timer and Ctrl-C in one `Wait`.

A bid is granted at once only if the semaphore is free or its holder is
what the bid asks for. So, unlike `ObtainSemaphoreShared`, **a shared
bid from the exclusive owner waits** until that hold is released.

The lock belongs to the task that called this, whatever task later
receives the reply.

**CONTEXT**

- Waits: no. Not waiting is the whole point.
- Interrupts: no. It takes Forbid and may reply a message.
- Forbid: taken here.
- Process: a Task will do.

**OWNERSHIP**

The bid is the semaphore's until it is replied, and must not be touched
or freed before then. It is given back with `Vacate`, never with
`ReleaseSemaphore`.

**NOTES**

A bid is granted at once only if the semaphore is free or its holder is
what the bid asks for: this task for an exclusive bid, the shared
holders for a shared one. That is why a shared bid from the exclusive
owner waits where `ObtainSemaphoreShared` would simply nest.

**BUGS**

None known.

**SEE ALSO**

`Vacate`, `ObtainSemaphore`, `Wait`

**EXAMPLES**

```zig
var bid: exec.SemaphoreMessage = .init(reply_port, false);
sys.Procure(&sem, &bid);
_ = sys.Wait(port_mask | exec.SIGBREAKF_CTRL_C);
```

## PutMsg

Sends a message to a port, and does whatever that port asks for on arrival.

**SYNOPSIS**

```zig
fn PutMsg(base: *ExecBase, port: *MsgPort, msg: *Message) void
```

**SINCE**

1.0. LVO -204.

**INPUTS**

- `port` - where it goes. It must still exist; for a public port that
  means holding Forbid from the `FindPort` to here.
- `msg` - the message. Its `reply_port` should be set if a reply is
  wanted, and its length if the receiver reads one.

**RESULT**

Nothing.

**BEHAVIOR**

The message goes on the end of the port's queue, so messages are taken
in the order they were sent. Then the port's action: signal its task,
`Cause` its software interrupt, or nothing at all.

**The message now belongs to the receiver.** The sender must not read or
write it, and must not free it, until it comes back.

**CONTEXT**

- Waits: no. Sending is never blocking - a port's queue has no limit,
  and flow control is something the two ends arrange between them.
- Interrupts: safe. It takes Disable, and it is how an interrupt hands
  work to a task.
- Forbid: not needed for the send itself; needed by the caller around
  `FindPort` and this, so that a public port cannot go away in between.
- Process: a Task will do.

**OWNERSHIP**

The message passes to the receiver and comes back on `ReplyMsg`. It must
stay allocated for all of that time, which is why a message on a
sender's stack is only safe if the sender waits for the reply.

**BUGS**

None known.

**SEE ALSO**

`GetMsg`, `ReplyMsg`, `WaitPort`, `FindPort`

**EXAMPLES**

```zig
sys.Forbid();
if (sys.FindPort("some.port")) |port| sys.PutMsg(port, &msg);
sys.Permit();
```

## RamLib

The module loader's base, as `SetRamLib` left it.

**SYNOPSIS**

```zig
fn RamLib(base: *ExecBase) ?*anyopaque
```

**SINCE**

1.0. LVO -444.

**INPUTS**

None.

**RESULT**

What `SetRamLib` was given, or null if it was never called - which means
nothing loads modules from a disk on this machine.

**BEHAVIOR**

The replaced `OpenLibrary` calls this to find its own state, which is
the whole purpose of the pair.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It is one load.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`SetRamLib`

**EXAMPLES**

```zig
const rb: *RamLibBase = @ptrCast(@alignCast(sys.RamLib() orelse return));
```

## RawDoFmt

Formats text, handing each character to a function of the caller's.

**SYNOPSIS**

```zig
fn RawDoFmt(_: *ExecBase, format_string: [*:0]const u8,
    data_stream: ?*const anyopaque, put_ch_proc: ?PutChProc,
    put_ch_data: ?*anyopaque) ?*const anyopaque
```

**SINCE**

1.0. LVO -372.

**INPUTS**

- `format_string` - `%[-][0][width][.limit][l]{d,D,u,U,x,X,s,c}`.
  `%d %u %x %c` take 32 bits and `%l...` 64; `%s` takes a pointer to a
  NUL-terminated string. An unknown conversion prints its own character,
  so `%%` prints one per cent.
- `data_stream` - the values, packed and read with unaligned loads. Null
  gives 0 and null for every value rather than faulting.
- `put_ch_proc` - called with each character and `put_ch_data`, and with
  a final NUL. **Null instead stores the characters into `put_ch_data`
  as a buffer**, which is how a string is formatted without a function.
- `put_ch_data` - passed to `put_ch_proc` untouched, or the buffer.

**RESULT**

The data stream past the values that were used, so a second format can
carry on where the first stopped.

**BEHAVIOR**

Hex is upper case with no leading zeros, and 0 prints as "0". With zero
fill the sign comes before the zeros, so `%03d` of -5 is "-05". A
`.limit` cuts the text, and a null `%s` prints nothing at all - not even
padding. A format ending in a lone `%` ends there rather than reading
past the NUL.

**CONTEXT**

- Waits: no, though `put_ch_proc` may.
- Interrupts: safe in itself; it depends entirely on what
  `put_ch_proc` does.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. With a null `put_ch_proc` the buffer is the
caller's and **nothing checks its size**.

**NOTES**

These are not Zig's format strings. `sdk.exec.checkFormat` rejects a
mismatch at compile time, which is what stops `%d` being handed a
64-bit value.

**BUGS**

None known.

**SEE ALSO**

`RawPutChar`, `RawIOInit`

**EXAMPLES**

```zig
_ = sys.RawDoFmt("%-14s %08x %ld\n", &args, &putCh, ctx);
```

## RawIOInit

Sets exec's own console up, before anything can be printed.

**SYNOPSIS**

```zig
fn RawIOInit(_: *ExecBase) void
```

**SINCE**

1.0. LVO -384.

**INPUTS**

None.

**RESULT**

Nothing.

**BEHAVIOR**

exec's init does this **first**, before anything else it does, because
nothing printed before it goes anywhere - so a fault earlier than this
is silent, and that is worth keeping to as short a span as possible.

Whatever the boot ROM was still sending is let out before the port is
retimed, so its output and the kernel's do not run together.

**CONTEXT**

- Waits: no, but it waits for the port to drain.
- Interrupts: safe.
- Forbid: not needed.
- Process: a Task will do. It runs before there are any.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

Calling it again re-times the port, which is how a machine whose clock
has changed keeps a readable console.

**BUGS**

None known.

**SEE ALSO**

`RawPutChar`, `RawDoFmt`

**EXAMPLES**

```zig
sys.RawIOInit();
```

## RawMayGetChar

Takes a character from exec's own console if one is waiting.

**SYNOPSIS**

```zig
fn RawMayGetChar(_: *ExecBase) i32
```

**SINCE**

1.0. LVO -380.

**INPUTS**

None.

**RESULT**

The character, or **-1** if none is waiting. It never waits, which is
what "may" means here.

**BEHAVIOR**

The port is polled and has no buffer of its own, so a character that
arrives while nobody is asking is lost. That is acceptable for what this
is - a debug console typed at by a person - and is why serial.device,
which buffers on an interrupt, is what a program uses.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Forbid: not needed.
- Process: a Task will do. It works with no task at all.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`RawPutChar`, `RawIOInit`

**EXAMPLES**

```zig
const c = sys.RawMayGetChar();
if (c >= 0) { ... }
```

## RawPutChar

Sends one character to exec's own console.

**SYNOPSIS**

```zig
fn RawPutChar(_: *ExecBase, character: u8) void
```

**SINCE**

1.0. LVO -376.

**INPUTS**

- `ch` - the character. A NUL is dropped, so the terminating NUL that
  `RawDoFmt` sends costs nothing.

**RESULT**

Nothing.

**BEHAVIOR**

A newline goes out as carriage return and newline, so a terminal need
not be in any particular mode to be readable.

It is **polled**: the call returns when the character has been handed to
the hardware, which at the port's speed is slow enough to matter in a
tight loop. Nothing before `RawIOInit` goes anywhere.

**CONTEXT**

- Waits: no, but it spins on the transmitter.
- Interrupts: safe, and that is why kernel output uses it: it needs no
  task, no device and no memory.
- Forbid: not needed.
- Process: a Task will do. It works with no task at all.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

This is the kernel's output, not a program's. A program writes to its
own output stream, which reaches a console or a file; this always goes
to UART0 whatever else the machine is doing, which is what makes it
worth having when the rest has stopped.

**BUGS**

None known.

**SEE ALSO**

`RawDoFmt`, `RawMayGetChar`, `RawIOInit`

**EXAMPLES**

```zig
sys.RawPutChar('!');
```

## ReleaseSemaphore

Gives back one obtain, and hands the semaphore on when it was the last.

**SYNOPSIS**

```zig
fn ReleaseSemaphore(base: *ExecBase, sem: *SignalSemaphore) void
```

**SINCE**

1.0. LVO -248.

**INPUTS**

- `sem` - a semaphore this task holds.

**RESULT**

Nothing.

**BEHAVIOR**

The last release gives it to the next waiter: **an exclusive waiter
alone, or every shared waiter at the head of the queue together.** The
semaphore is never let go for whoever asks next, so the order of the
queue is the order it is granted in.

Releasing one this task does not hold raises `AN_SemCorrupt`. It is an
alert rather than an ignored mistake because the alternative is a
semaphore whose count no longer means anything, which fails later and
somewhere else.

**CONTEXT**

- Waits: no, but handing the semaphore on signals a task, which may
  switch.
- Interrupts: no. It takes Forbid and may signal.
- Forbid: taken here.
- Process: a Task will do, and it must be **the task that obtained
  it**.

**OWNERSHIP**

One obtain is given back. Whatever the semaphore guarded must not be
touched after the last release.

**BUGS**

None known.

**SEE ALSO**

`ObtainSemaphore`, `ReleaseSemaphoreList`, `Vacate`

**EXAMPLES**

```zig
defer sys.ReleaseSemaphore(&self.lock);
```

## ReleaseSemaphoreList

Gives back every semaphore on a list.

**SYNOPSIS**

```zig
fn ReleaseSemaphoreList(base: *ExecBase, list: *List) void
```

**SINCE**

1.0. LVO -260.

**INPUTS**

- `list` - the list that was obtained. It must hold **the same
  semaphores**: one that joined it since is released too, and one that
  left is not.

**RESULT**

Nothing.

**BEHAVIOR**

Each is released in turn, and each may hand itself to its next waiter.
A semaphore on the list that this task does not hold raises
`AN_SemCorrupt`, which is how a list that changed under the holder makes
itself known.

**CONTEXT**

- Waits: no, but it may signal and so may switch.
- Interrupts: no. It takes Forbid.
- Forbid: taken here.
- Process: a Task will do, and it must be the task that obtained them.

**OWNERSHIP**

Every hold is given back.

**BUGS**

None known.

**SEE ALSO**

`ObtainSemaphoreList`, `ReleaseSemaphore`

**EXAMPLES**

```zig
defer sys.ReleaseSemaphoreList(&li.lock_list);
```

## RemDevice

Asks a device to go away, through its own Expunge vector.

**SYNOPSIS**

```zig
fn RemDevice(base: *ExecBase, dev: *Device) ?*anyopaque
```

**SINCE**

1.0. LVO -316.

**INPUTS**

- `dev` - a device on the device list.

**RESULT**

What the Expunge vector answered: null, or the seglist of a loaded
module the caller should unload.

**BEHAVIOR**

As `RemLibrary`: it asks rather than tells. A device with anything open
marks itself and goes on its last `CloseDevice`; a device in the ROM
keeps itself, which is read from it still being on the list.

**CONTEXT**

- Waits: no, and the vector must not either - the low-memory handler
  reaches this from inside `AllocMem`.
- Interrupts: no. It takes Forbid.
- Forbid: taken here, around the vector.
- Process: a Task will do.

**OWNERSHIP**

If the device went, its memory is gone. A non-null result is a seglist
the caller now owns.

**BUGS**

None known.

**SEE ALSO**

`AddDevice`, `CloseDevice`, `RemLibrary`

**EXAMPLES**

```zig
_ = sys.RemDevice(dev);
```

## RemHead

Takes the first node off a list and answers it.

**SYNOPSIS**

```zig
fn RemHead(base: *ExecBase, list: *List) ?*Node
```

**SINCE**

1.0. LVO -76.

**INPUTS**

- `list` - the list to take from.

**RESULT**

The node that was at the head, or null if the list was empty.

**BEHAVIOR**

The test for empty is what makes this different from `Remove` on the
first node, and is why a queue is drained with this rather than by
asking whether the list is empty first - the question and the answer are
one call, so nothing can change between them.

**CONTEXT**

- Waits: no.
- Interrupts: safe in itself; the caller's locking is what decides.
- Forbid: not taken here, and the caller's to take.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The node is the caller's again.

**BUGS**

None known.

**SEE ALSO**

`RemTail`, `AddTail`, `GetMsg`

**EXAMPLES**

```zig
while (sys.RemHead(&list)) |node| {
    // ... this one is ours now ...
}
```

## RemIntServer

Takes a server off an interrupt number's chain.

**SYNOPSIS**

```zig
fn RemIntServer(base: *ExecBase, int_number: u32,
    interrupt: *Interrupt) void
```

**SINCE**

1.0. LVO -136.

**INPUTS**

- `int_number` - the number the server is on.
- `interrupt` - the server to remove.

**RESULT**

Nothing.

**BEHAVIOR**

Removing the last user of a number releases its CPU line, which is what
keeps the twelve from being spent on devices that are no longer open.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It takes Disable.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The `Interrupt` is the caller's again. It is safe
to free once this returns: Disable is held across the removal, so no
interrupt can be part-way through the chain.

**BUGS**

None known.

**SEE ALSO**

`AddIntServer`, `SetIntVector`

**EXAMPLES**

```zig
sys.RemIntServer(intbits.INTB_GPIO, &server);
```

## RemLibrary

Asks a library to go away, through its own Expunge vector.

**SYNOPSIS**

```zig
fn RemLibrary(base: *ExecBase, lib: *Library) ?*anyopaque
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `lib` - a library on the library list.

**RESULT**

What the Expunge vector answered: null, or the seglist of a loaded
module the caller should now unload. A module in the ROM always answers
null, since it has no segments.

**BEHAVIOR**

It asks rather than tells, and the library decides. The standard
Expunge (`libExpunge`) takes the library off the list and frees it when
nobody has it open, and otherwise only sets `LIBF_DELEXP` so that it
goes on its last `CloseLibrary`. A library in the ROM keeps itself by
answering without doing anything, and exec reads that from the library
still being on its list when the vector returns.

So a caller cannot conclude from the result that the library went. What
it went by is whether it is still on the list.

**CONTEXT**

- Waits: no, and the vector it calls must not either - the low-memory
  handler reaches this from inside `AllocMem`.
- Interrupts: no. It takes Forbid.
- Forbid: taken here, around the vector.
- Process: a Task will do.

**OWNERSHIP**

If the library went, its memory is gone and the base must not be touched
again. A non-null result is a seglist the caller now owns.

**NOTES**

This is also how memory is reclaimed under pressure:
`flushLibraries` (library/_library.zig) is a low-memory handler that
walks the library and device lists calling this on everything nobody
has open.

**BUGS**

None known.

**SEE ALSO**

`AddLibrary`, `CloseLibrary`, `RemDevice`

**EXAMPLES**

```zig
if (sys.RemLibrary(lib)) |seg_list| {
    dos.UnLoadSeg(seg_list);
}
```

## RemMemHandler

Takes a low-memory handler off the list.

**SYNOPSIS**

```zig
fn RemMemHandler(base: *ExecBase, handler: *Interrupt) void
```

**SINCE**

1.0. LVO -124.

**INPUTS**

- `handler` - one that was added with `AddMemHandler`.

**RESULT**

Nothing.

**BEHAVIOR**

It comes off the list and is not asked again.

**CONTEXT**

- Waits: no.
- Interrupts: no. It takes Forbid.
- Forbid: taken here, around the list.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The `Interrupt` is the caller's again and may be
freed.

**BUGS**

None known.

**SEE ALSO**

`AddMemHandler`

**EXAMPLES**

```zig
sys.RemMemHandler(&handler);
```

## RemPort

Takes a port off the public list.

**SYNOPSIS**

```zig
fn RemPort(base: *ExecBase, port: *MsgPort) void
```

**SINCE**

1.0. LVO -224.

**INPUTS**

- `port` - a port that was added with `AddPort`.

**RESULT**

Nothing.

**BEHAVIOR**

Nothing new can find it. Messages already on its queue are still there
and are still the caller's to deal with - removing a port does not empty
it, and anything already replied to will still arrive.

**CONTEXT**

- Waits: no.
- Interrupts: no. It takes Forbid.
- Forbid: taken here, around the list.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. Draining the queue before freeing the port is the
caller's.

**BUGS**

None known.

**SEE ALSO**

`AddPort`, `DeleteMsgPort`

**EXAMPLES**

```zig
sys.RemPort(port);
while (sys.GetMsg(port)) |msg| sys.ReplyMsg(msg);
```

## RemResource

Takes a resource off the resource list.

**SYNOPSIS**

```zig
fn RemResource(base: *ExecBase, resource: *anyopaque) void
```

**SINCE**

1.0. LVO -392.

**INPUTS**

- `resource` - one that was added.

**RESULT**

Nothing.

**BEHAVIOR**

Nothing new can find it. **Whoever already has the pointer still has
it**, and since a resource is never closed there is no count to say who
that is - so removing one is only safe when the caller knows by other
means that nobody is using it.

**CONTEXT**

- Waits: no.
- Interrupts: no. It takes Forbid.
- Forbid: taken here, around the list.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`AddResource`, `OpenResource`

**EXAMPLES**

```zig
sys.RemResource(base);
```

## RemSemaphore

Takes a semaphore off the public list.

**SYNOPSIS**

```zig
fn RemSemaphore(base: *ExecBase, sem: *SignalSemaphore) void
```

**SINCE**

1.0. LVO -272.

**INPUTS**

- `sem` - a semaphore that was added with `AddSemaphore`.

**RESULT**

Nothing.

**BEHAVIOR**

Nothing new can find it. Whoever already holds it still does, and
whoever is queued is still queued - so this is not a way to take a lock
away from its holder.

**CONTEXT**

- Waits: no.
- Interrupts: no. It takes Forbid.
- Forbid: taken here, around the list.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. Making sure nobody holds or wants it before
freeing it is the caller's.

**BUGS**

None known.

**SEE ALSO**

`AddSemaphore`, `FindSemaphore`

**EXAMPLES**

```zig
sys.RemSemaphore(&sem);
```

## RemTail

Takes the last node off a list and answers it.

**SYNOPSIS**

```zig
fn RemTail(base: *ExecBase, list: *List) ?*Node
```

**SINCE**

1.0. LVO -80.

**INPUTS**

- `list` - the list to take from.

**RESULT**

The node that was at the tail, or null if the list was empty.

**BEHAVIOR**

With `AddTail` it makes a stack, as with `RemHead` it makes a queue.

**CONTEXT**

- Waits: no.
- Interrupts: safe in itself; the caller's locking is what decides.
- Forbid: not taken here, and the caller's to take.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The node is the caller's again.

**BUGS**

None known.

**SEE ALSO**

`RemHead`, `AddTail`

**EXAMPLES**

```zig
const last = sys.RemTail(&list) orelse return;
```

## RemTask

Ends a task, and frees what `CreateTask` allocated for it.

**SYNOPSIS**

```zig
fn RemTask(base: *ExecBase, task: ?*Task) void
```

**SINCE**

1.0. LVO -164.

**INPUTS**

- `task` - the task to end, or **null for the calling task**.

**RESULT**

Nothing, and for null it does not return at all.

**BEHAVIOR**

**Removing yourself** cannot free your own stack, because you are still
running on it. The task is marked and the processor given up, and the
scheduler frees the memory once nothing is running on it any more.

**Removing another task** takes it off whichever list it is on and frees
its memory there and then.

Either way, only what `CreateTask` allocated is freed. A task the caller
laid out by hand has its own memory back and nothing has been done to
it.

**CONTEXT**

- Waits: no. For null it never returns, which is not the same thing.
- Interrupts: no. It takes Disable and may free memory.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Memory from `CreateTask` goes back to the system. Anything the task
itself allocated is not freed - signals, ports, memory - so a task that
is removed from outside leaks whatever it was holding. That is why a
task is normally asked to end itself.

**NOTES**

It does not warn the task or give it a chance to clean up. `Signal` with
`SIGBREAKF_CTRL_C` is how a task is asked rather than told.

**BUGS**

None known.

**SEE ALSO**

`AddTask`, `CreateTask`, `Signal`

**EXAMPLES**

```zig
sys.RemTask(null); // does not return
```

## Remove

Takes a node off whatever list it is on.

**SYNOPSIS**

```zig
fn Remove(_: *ExecBase, node: *Node) void
```

**SINCE**

1.0. LVO -72.

**INPUTS**

- `node` - a node that is **on** a list. It is not checked, and removing
  one that is not writes through whatever its links happen to hold.

**RESULT**

Nothing.

**BEHAVIOR**

The list is not named because the node's own links are enough to find
its neighbours. Two pointer writes, and the node's own links are left as
they were - so a node just removed still points into the list and must
not be removed twice.

**CONTEXT**

- Waits: no.
- Interrupts: safe in itself; the caller's locking is what decides.
- Forbid: not taken here, and the caller's to take.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The node is the caller's again and may now be
freed.

**NOTES**

Removing while walking a list works, because the iterator reads the
successor before handing a node over.

**BUGS**

None known.

**SEE ALSO**

`RemHead`, `RemTail`, `Insert`

**EXAMPLES**

```zig
sys.Remove(&node);
```

## ReplyIO

For a device: finishes a request and sends it back.

**SYNOPSIS**

```zig
fn ReplyIO(base: *ExecBase, io: *IORequest) void
```

**SINCE**

1.0. LVO -340.

**INPUTS**

- `io` - the request the device has finished, its error already set.

**RESULT**

Nothing.

**BEHAVIOR**

A request still marked `IOF_QUICK` was finished inside BeginIO and needs
no reply - the caller is reading the error directly - so nothing is
sent. Any other goes back to its reply port.

That single test is what lets a device write one ending for both paths.

**CONTEXT**

- Waits: no.
- Interrupts: **safe, and that is what it is for.** A device's interrupt
  finishes the request the task started.
- Forbid: not needed.
- Process: a Task will do; an interrupt will do.

**OWNERSHIP**

The request goes back to whoever sent it and the device must not touch
it again.

**NOTES**

This is a device's call, not a caller's. A request must not be finished
twice, which is what a device's own done flag is for.

**BUGS**

None known.

**SEE ALSO**

`DoIO`, `SendIO`, `ReplyMsg`

**EXAMPLES**

```zig
io.err = 0;
sys.ReplyIO(io);
```

## ReplyMsg

Sends a message back to whoever sent it.

**SYNOPSIS**

```zig
fn ReplyMsg(base: *ExecBase, msg: *Message) void
```

**SINCE**

1.0. LVO -212.

**INPUTS**

- `msg` - a message the caller took with `GetMsg`.

**RESULT**

Nothing.

**BEHAVIOR**

It goes on the sender's reply port and that port's action is done, so
replying wakes the sender exactly as sending woke the receiver.

**A message with no reply port** is marked as free and nothing else
happens. That is how a sender says "this one is one-way, do not answer
it" - and how the receiver tells one from the other without being told.

The message's type says which way round it is, so a sender can check
that what came back is a reply.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It takes Disable.
- Forbid: not needed. The reply port belongs to the sender, which is
  waiting for this and so cannot have gone away.
- Process: a Task will do.

**OWNERSHIP**

The message goes back to the sender and must not be touched again. For a
one-way message with no reply port, it is the receiver's to free.

**BUGS**

None known.

**SEE ALSO**

`GetMsg`, `PutMsg`, `ReplyIO`

**EXAMPLES**

```zig
sys.ReplyMsg(msg);
```

## ResModules

Hands back the table of resident modules.

**SYNOPSIS**

```zig
fn ResModules(base: *ExecBase) ?[*]const ?*const Resident
```

**SINCE**

1.0. LVO -436.

**INPUTS**

None.

**RESULT**

The tags in priority order, **null-terminated**, or null if the scan
never ran - which is the case in a host test, where exec is built
without a boot image.

**BEHAVIOR**

Priority order is boot order, so reading this is reading the order the
machine started its modules in.

**No lock is needed**: the table is built once by the boot scan and
never changes afterwards. It is the one piece of exec's state that can
be walked freely.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The table is exec's and the tags are in the ROM
image.

**BUGS**

None known.

**SEE ALSO**

`FindResident`, `InitCode`, `ExecList`

**EXAMPLES**

```zig
const table = sys.ResModules() orelse return;
var i: usize = 0;
while (table[i]) |tag| : (i += 1) { ... }
```

## SendIO

Starts an I/O request and returns at once.

**SYNOPSIS**

```zig
fn SendIO(_: *ExecBase, io: *IORequest) void
```

**SINCE**

1.0. LVO -332.

**INPUTS**

- `io` - a request on an open device, with a reply port.

**RESULT**

Nothing. What happened is learned from `WaitIO` or `CheckIO`.

**BEHAVIOR**

`IOF_QUICK` is **cleared**, so the device always replies and the request
always comes back to its port - even one the device could have finished
at once. That is what makes the request waitable beside everything else
the task is waiting for.

With no device open the request is left marked quick with
`IOERR_OPENFAIL`, so the `WaitIO` that follows answers that immediately
instead of waiting for a reply that will never come.

**CONTEXT**

- Waits: no. That is the point of it.
- Interrupts: no.
- Forbid: no; the device's BeginIO may do anything.
- Process: a Task will do.

**OWNERSHIP**

The request and its buffers belong to the device from here until it is
collected. Neither may be touched or freed in between - a request on the
stack of a function that returns is the mistake this invites.

**NOTES**

Every `SendIO` owes a `WaitIO` or an `AbortIO` then a `WaitIO`. A
request left outstanding cannot be freed and its device cannot be
closed.

With no device open the request is left marked quick with
`IOERR_OPENFAIL`, so the `WaitIO` that follows answers at once instead
of waiting for a reply that can never come.

**BUGS**

None known.

**SEE ALSO**

`WaitIO`, `CheckIO`, `AbortIO`, `DoIO`

**EXAMPLES**

```zig
sys.SendIO(@ptrCast(io));
const got = sys.Wait(port_mask | exec.SIGBREAKF_CTRL_C);
if (got & exec.SIGBREAKF_CTRL_C != 0) _ = sys.AbortIO(@ptrCast(io));
_ = sys.WaitIO(@ptrCast(io));
```

## SetExcept

Chooses which of the calling task's signals raise its exception code.

**SYNOPSIS**

```zig
fn SetExcept(base: *ExecBase, new_signals: u32, signal_set: u32) u32
```

**SINCE**

1.0. LVO -200.

**INPUTS**

- `new_signals` - the values to write, for the bits in `signal_set`.
- `signal_set` - which bits to change.

**RESULT**

The exception set as it was before the change.

**BEHAVIOR**

A signal in the exception set runs the task's exception code rather than
waking it in the ordinary way - so it interrupts the task wherever it
is, instead of waiting for it to come round to a `Wait`.

The task's exception code must already be set when this is called: if
one of the chosen signals is **already** present, the exception runs
straight away.

**CONTEXT**

- Waits: no.
- Interrupts: no - it is the running task's.
- Forbid: not needed; it takes Disable. Under Forbid the exception is
  postponed to the `Permit`.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

The exception code runs on the task's own stack, in the middle of
whatever it was doing, so it is under an interrupt's constraints rather
than a task's: it must not wait, and what it touches must be safe to
touch at any point in the task's own code.

**BUGS**

None known.

**SEE ALSO**

`Signal`, `Wait`, `SetTrapCode`

**EXAMPLES**

```zig
const old = sys.SetExcept(exec.SIGBREAKF_CTRL_C, exec.SIGBREAKF_CTRL_C);
```

## SetFunction

Replaces one entry of a library's jump table and answers the old one.

**SYNOPSIS**

```zig
fn SetFunction(base: *ExecBase, lib: *Library, offset: isize,
    new: *const anyopaque) *const anyopaque
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `lib` - the library to patch.
- `offset` - the slot's LVO. Negative, and a whole number of slots, and
  within the table: `-offset <= lib.neg_size`.
- `new` - the function to put there. It is called with the library's own
  base as its first argument, exactly as the one it replaces was, so it
  must have that signature.

**RESULT**

The function that was in the slot. A patch keeps it and calls it to pass
the work on, which is how a replacement adds behaviour rather than
replacing it.

**BEHAVIOR**

The table's checksum is taken again, so a patched library does not look
corrupted afterwards.

This is the one place an LVO arrives at run time rather than as a
constant, so it is the one place the range is worth checking: writing
outside the table would put a function pointer into somebody else's
memory and be found later, somewhere else. The check costs nothing,
because it runs when a module patches a vector and not when anything
calls one.

**CONTEXT**

- Waits: no.
- Interrupts: no. It takes Forbid.
- Forbid: taken here, around the write and the checksum. That stops
  another task being switched to mid-patch; it does not stop one that is
  already inside the old function.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The old function pointer is the caller's to keep
and to put back.

**NOTES**

A task may be executing the old function while it is replaced, so a
patch cannot assume the old one is idle, and code that is patched out
cannot be freed on the strength of having been patched out.

This is the mechanism the whole tree's first rule exists for: every call
to a function that has an LVO goes through the jump table, so that
anything can be stood in front of. A module that calls its own
implementation directly has a private door that no patch can see.

**BUGS**

None known.

**SEE ALSO**

`SetRamLib`, `MakeLibrary`

**EXAMPLES**

```zig
const old = sys.SetFunction(&sys.lib, exec.LVO.OpenLibrary,
    exec.vec(myOpenLibrary));
```

## SetIntVector

Installs the one handler of an interrupt number.

**SYNOPSIS**

```zig
fn SetIntVector(base: *ExecBase, int_number: u32,
    interrupt: ?*Interrupt) ?*Interrupt
```

**SINCE**

1.0. LVO -128.

**INPUTS**

- `int_number` - a source from `sdk.hardware.intbits`. Out of range is
  fatal.
- `interrupt` - an `Interrupt` whose `code` is an `IntHandlerFn`, called
  with its `data` and the number; or null, which removes the handler.

**RESULT**

The handler that was there, or null if there was none.

**BEHAVIOR**

A number with a handler gets a CPU line of its own, because a handler is
not required to say whether its hardware raised the interrupt. So
installing one may take the last free line, and finding none is fatal -
there is no useful way to carry on with an interrupt that cannot be
delivered.

Adding the first handler or server routes the number; removing the last
releases it; gaining or losing a handler routes it again, because that
is what changes whether it may share.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It takes Disable, which an interrupt may.
- Forbid: not needed. Disable is what guards the vectors, since they are
  what interrupts themselves touch.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. The `Interrupt` stays the caller's and must
outlive its place in the vector - and must stay reachable with the
caches in whatever state an interrupt finds them.

**NOTES**

A handler's state belongs in internal memory. `MEMF_ANY` takes PSRAM
first on this machine, and an interrupt reading its own state out of
memory that two DMA channels are working is measurably slower - 262 late
refills in 62 idle seconds, against 0 for the same code in internal
memory.

**BUGS**

None known.

**SEE ALSO**

`AddIntServer`, `RemIntServer`, `IntVector`, `Cause`

**EXAMPLES**

```zig
const old = sys.SetIntVector(intbits.INTB_UART0, &my_handler);
```

## SetMem

Fills memory with one byte value.

**SYNOPSIS**

```zig
fn SetMem(_: *ExecBase, dest: *anyopaque, value: u8, size: usize) void
```

**SINCE**

1.0. LVO -308.

**INPUTS**

- `dest` - where to fill. Any alignment.
- `value` - the byte to write everywhere.
- `size` - how many bytes. 0 does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

Word-sized stores where the alignment allows.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Forbid: not needed, and not taken.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

`MEMF_CLEAR` on an allocation does this for the zero case without a
second pass over the memory.

**BUGS**

None known.

**SEE ALSO**

`CopyMem`, `AllocMem`

**EXAMPLES**

```zig
sys.SetMem(buf, 0, len);
```

## SetRamLib

Tells exec where the module loader's base is.

**SYNOPSIS**

```zig
fn SetRamLib(base: *ExecBase, loader: ?*anyopaque) void
```

**SINCE**

1.0. LVO -440.

**INPUTS**

- `loader` - the loader's own base, or null to say there is none.

**RESULT**

Nothing.

**BEHAVIOR**

exec stores the word and **never looks at what it points to**. It is one
pointer that a module has nowhere else to put.

The reason it has nowhere else is worth stating, since it is the only
thing this call is for. ramlib.library replaces exec's `OpenLibrary` and
`OpenDevice` with `SetFunction`, and a replaced vector is handed exec's
base, not the replacement's - so it has no way to reach its own state.
It cannot keep that state in its own image either, since a ROM image is
read only. So exec holds the word.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It is one store.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated, and exec takes no responsibility for what the
pointer names.

**BUGS**

None known.

**SEE ALSO**

`RamLib`, `SetFunction`, `OpenLibrary`

**EXAMPLES**

```zig
sys.SetRamLib(base);
```

## SetSignal

Reads or changes the calling task's signals without waiting.

**SYNOPSIS**

```zig
fn SetSignal(base: *ExecBase, new_signals: u32, signal_mask: u32) u32
```

**SINCE**

1.0. LVO -184.

**INPUTS**

- `new_signals` - the values to write, for the bits in `signal_mask`.
- `signal_mask` - which bits to change. 0 changes nothing.

**RESULT**

The whole received set as it was **before** the change.

**BEHAVIOR**

`SetSignal(0, 0)` changes nothing and answers the current signals, which
is how a program checks for Ctrl-C without waiting and without taking
the signal away from anyone.

`SetSignal(0, mask)` clears those bits and says what they were, which is
how one is consumed.

**CONTEXT**

- Waits: no. It is the call for when waiting is what you do not want.
- Interrupts: no - it reads the running task, and an interrupt has none
  of its own.
- Forbid: not needed; it takes Disable.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`Wait`, `Signal`

**EXAMPLES**

```zig
if (sys.SetSignal(0, 0) & exec.SIGBREAKF_CTRL_C != 0) {
    // asked to stop; the signal is still set for whoever else looks
}
```

## SetTaskPri

Changes a task's priority, and reschedules if that changed who should run.

**SYNOPSIS**

```zig
fn SetTaskPri(base: *ExecBase, task: *Task, pri: i8) i8
```

**SINCE**

1.0. LVO -172.

**INPUTS**

- `task` - the task to change. Its own, or another's.
- `pri` - the new priority, -128 to 127. Higher runs first.

**RESULT**

The priority it had.

**BEHAVIOR**

A ready task is requeued, so it takes its new place among its equals -
and since `Enqueue` puts it behind the ones already there, raising a
task to a priority it already had moves it to the back of that group.

A switch is asked for when the change made one right: the task lowered
itself below a ready task, or another task was raised above the running
one. It is taken at the `Enable` here, or postponed by a Forbid.

**CONTEXT**

- Waits: no, but it may switch.
- Interrupts: no. It takes Disable.
- Forbid: not needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

Priority is not a share of the processor. A higher-priority task that is
ready runs, and the ones below it do not run at all until it waits - so
a busy task at a high priority starves everything under it rather than
being favoured over it.

**BUGS**

None known.

**SEE ALSO**

`AddTask`, `FindTask`, `Wait`

**EXAMPLES**

```zig
const old = sys.SetTaskPri(sys.FindTask(null).?, 5);
defer _ = sys.SetTaskPri(sys.FindTask(null).?, old);
```

## SetTrapCode

Sets the running task's trap code, which takes its CPU exceptions.

**SYNOPSIS**

```zig
fn SetTrapCode(base: *ExecBase, code: ?TrapFn, data: ?*anyopaque) ?TrapFn
```

**SINCE**

1.0. LVO -156.

**INPUTS**

- `code` - called with a `TrapInfo` and `data` when this task takes a
  CPU exception; null to have none. It answers non-zero if it dealt with
  the exception.
- `data` - passed to `code` untouched.

**RESULT**

The trap code that was there, to be put back.

**BEHAVIOR**

It is the **running** task's that is set, so a task can only do this to
itself.

When an exception arrives the trap code runs, and answering non-zero
means "handled": execution then carries on at `info.pc`, which the trap
code may have changed to step over the instruction that faulted. Any
other answer, or no trap code at all, ends in a dead-end alert.

**CONTEXT**

- Waits: no. **The trap code itself must not wait**: it runs in the
  exception, not on the task's own time.
- Interrupts: no - it reads the running task, and an interrupt has none
  of its own.
- Forbid: not needed. The field belongs to the one task that can write
  it.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. `data` stays the caller's and must outlive the
trap code's time installed.

**BUGS**

None known.

**SEE ALSO**

`Alert`, `AddTask`

**EXAMPLES**

```zig
const old = sys.SetTrapCode(&myTrap, self);
defer _ = sys.SetTrapCode(old, null);
```

## Signal

Sends signals to a task, waking it if it was waiting for one of them.

**SYNOPSIS**

```zig
fn Signal(base: *ExecBase, task: *Task, signals: u32) void
```

**SINCE**

1.0. LVO -176.

**INPUTS**

- `task` - who to signal. It must still exist, which is the caller's to
  be sure of.
- `signals` - a mask of bits to set. Several at once is fine.

**RESULT**

Nothing.

**BEHAVIOR**

The bits are set in the task's received set. If it was waiting for any
of them it becomes ready, and **runs at once if its priority is higher
than the caller's** - so this call may cost the caller the processor.

A bit that is in the task's exception set raises its exception instead,
which also wakes a waiting task.

Signalling a task that is not waiting simply leaves the bits set, and
its next `Wait` for them returns immediately. Nothing is lost by
signalling early; what is lost is the second of two signals on a bit
that was already set.

**CONTEXT**

- Waits: no, but it may switch.
- Interrupts: **safe, and this is the main way out of one.** An
  interrupt cannot wait, allocate or reach a handler; what it can do is
  signal the task that can.
- Forbid: not needed; it takes Disable. Under Forbid the switch is
  postponed to the `Permit`.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

Signalling a task that has ended writes through a freed pointer. Where
the task may end on its own, what is signalled is a port it owns and the
arrangement to take it down is made between the two.

**BUGS**

None known.

**SEE ALSO**

`Wait`, `AllocSignal`, `SetExcept`, `PutMsg`

**EXAMPLES**

```zig
sys.Signal(waiting_task, @as(u32, 1) << @intCast(bit));
```

## Vacate

Withdraws a bid, or gives back the semaphore it won.

**SYNOPSIS**

```zig
fn Vacate(base: *ExecBase, sem: *SignalSemaphore,
    bid: *SemaphoreMessage) void
```

**SINCE**

1.0. LVO -288.

**INPUTS**

- `sem` - the semaphore the bid was made on.
- `bid` - the bid.

**RESULT**

Nothing. The bid's semaphore field is cleared either way.

**BEHAVIOR**

**One call for both cases**, which is what lets a caller give up without
having to know whether the bid was granted while it was deciding - the
race that would otherwise have no safe answer.

Still waiting: it is taken off the queue and replied with no semaphore,
so the waiter hears that it lost rather than waiting for ever.

Already granted: the semaphore is released. The bid was replied when it
was granted and is not replied again.

A bid never made, or vacated twice, does nothing.

**CONTEXT**

- Waits: no, but releasing may signal and so may switch.
- Interrupts: no. It takes Forbid.
- Forbid: taken here.
- Process: a Task will do. **Any task may vacate a bid**, though the
  lock belongs to whoever procured it.

**OWNERSHIP**

The bid is the caller's again and may be freed.

**NOTES**

A bid that was never procured, or vacated a second time, changes
nothing - which is what the waiter field is read for before anything
else is touched.

**BUGS**

None known.

**SEE ALSO**

`Procure`, `ReleaseSemaphore`

**EXAMPLES**

```zig
sys.Vacate(&sem, &bid);
```

## Wait

Sleeps until one of a set of signals arrives.

**SYNOPSIS**

```zig
fn Wait(base: *ExecBase, signal_set: u32) u32
```

**SINCE**

1.0. LVO -180.

**INPUTS**

- `signal_set` - the bits to wait for. Any one of them wakes the task.
  A set of 0 waits for ever.

**RESULT**

Which of `signal_set` arrived - possibly more than one - and those bits
are **cleared** as they are answered. Bits outside the set are left
alone for a later Wait.

**BEHAVIOR**

It returns at once if one of the bits is already set, so a task that
checks its port before waiting never sleeps through a message that
arrived while it was working.

The task's exception code runs here when an exception signal has
arrived, before the wait is considered.

**CONTEXT**

- Waits: **yes - this is the call that does.** Everything that waits in
  this system waits here in the end.
- Interrupts: no, and it is fatal to try. An interrupt has no task to
  suspend, so there would be nothing to wake.
- Forbid: it switches even under Forbid, which is the one exception to
  the scheduler being held. That makes waiting under Forbid *work*
  mechanically while still being wrong: the task that would signal you
  cannot run.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**NOTES**

Wait for everything that can wake you in one call, not in several one
after another: a task waiting on its port alone will not hear Ctrl-C,
and one waiting on Ctrl-C alone will not hear its port. `SIGBREAKF_CTRL_C`
belongs in nearly every set.

**BUGS**

None known.

**SEE ALSO**

`Signal`, `SetSignal`, `WaitPort`, `WaitIO`

**EXAMPLES**

```zig
const got = sys.Wait(port_mask | exec.SIGBREAKF_CTRL_C);
if (got & exec.SIGBREAKF_CTRL_C != 0) return;
while (sys.GetMsg(port)) |msg| { ... }
```

## WaitIO

Waits until a device is done with a request, and takes it back.

**SYNOPSIS**

```zig
fn WaitIO(base: *ExecBase, io: *IORequest) i32
```

**SINCE**

1.0. LVO -336.

**INPUTS**

- `io` - a request from `SendIO`, or one already finished.

**RESULT**

The request's error. `IOERR_NOREPLYPORT` if it was not finished and has
no port to wait on.

**BEHAVIOR**

A request still marked `IOF_QUICK` was finished inside BeginIO, so there
is nothing to wait for and the error is read straight out.

Otherwise it waits on the reply port until the request is replied, and
**takes it off the port**, which is what makes the request the caller's
again. A reply arriving between the check and the wait leaves the signal
set, so the wait returns at once rather than missing it.

**CONTEXT**

- Waits: yes, unless the request is already finished.
- Interrupts: no.
- Forbid: no. It waits.
- Process: a Task will do.

**OWNERSHIP**

The request and its buffers are the caller's again and may be reused or
freed.

**NOTES**

It waits on the port's signal alone, so a task that must also hear
Ctrl-C waits with `Wait` on the whole mask first and calls this only to
collect - which is the shape in `SendIO`'s example.

Other requests on the same port are left alone, so one port serves many
requests.

The node type is read through a volatile pointer because it is written
by the device - from an interrupt, in the usual case - and nothing in
the loop would otherwise make the compiler read it again.

**BUGS**

None known.

**SEE ALSO**

`SendIO`, `CheckIO`, `AbortIO`, `Wait`

**EXAMPLES**

```zig
const err = sys.WaitIO(@ptrCast(io));
```

## WaitPort

Waits until a port has a message, and answers the first one without taking it.

**SYNOPSIS**

```zig
fn WaitPort(base: *ExecBase, port: *MsgPort) *Message
```

**SINCE**

1.0. LVO -216.

**INPUTS**

- `port` - the caller's own port, which must signal the calling task
  (`PA_SIGNAL`, and its `sig_task` the caller).

**RESULT**

The first message on the queue. **It is still on the queue** - `GetMsg`
is what takes it - so this is the call for finding out that something
arrived rather than for receiving it.

**BEHAVIOR**

It returns at once if a message is already there.

**CONTEXT**

- Waits: yes, on the port's signal.
- Interrupts: no. It waits.
- Forbid: no - it waits, and waiting under Forbid stops the machine.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated. Nothing has been received yet either.

**NOTES**

It waits on the port's signal alone, so a task that also has to hear
Ctrl-C or a second port cannot use it - `Wait` with the whole mask is
what such a task calls instead. That is why most loops in this tree use
`Wait` and not this.

The list is looked at under Disable, because an interrupt may be putting
a message on it; the wait itself is on the port's signal, so a message
that arrives in between leaves the signal set and the wait returns at
once.

**BUGS**

None known.

**SEE ALSO**

`GetMsg`, `Wait`, `CreateMsgPort`

**EXAMPLES**

```zig
_ = sys.WaitPort(port);
while (sys.GetMsg(port)) |msg| { ... }
```
