# pci.library

pci.library's functions: the machine's PCI functions found, claimed,
their configuration space read and written, their interrupts hooked.
Open it with OpenLibrary("pci.library", 1); the structures are in
sdk.pci.

Generated from the source by `./zig build autodoc`.

## Index

- [AddPCIIntServer](#addpciintserver) - A server run whenever a function raises its INTx line.
- [AddPCIVectorServer](#addpcivectorserver) - A server run whenever a function signals one of its vectors.
- [AllocPCIVectors](#allocpcivectors) - Message-signalled interrupts for a function, MSI-X where it has it, MSI otherwise.
- [ClaimPCIDevice](#claimpcidevice) - A function taken by the driver that is to use it.
- [FindPCICapability](#findpcicapability) - Where a function's capability is, on the list its configuration space starts at PCI_CAPABILITY_LIST.
- [FindPCIClass](#findpciclass) - The next function of a class.
- [FindPCIDevice](#findpcidevice) - The next function made by a vendor, as a device.
- [FindPCIExtCapability](#findpciextcapability) - Where a PCI Express function's extended capability is, on the list from 0x100 of its 4 KiB.
- [FreePCIVectors](#freepcivectors) - A function's message-signalled interrupts given back, and its INTx line on again.
- [ReadPCIConfig](#readpciconfig) - A register of a function's configuration space, read.
- [ReleasePCIDevice](#releasepcidevice) - A claimed function given back, its bus mastering off and its vectors with it.
- [RemPCIIntServer](#rempciintserver) - A server taken off a function's INTx line.
- [RemPCIVectorServer](#rempcivectorserver) - A server taken off one of a function's vectors.
- [ResetPCIDevice](#resetpcidevice) - A function reset on its own, and what the library and its driver set up in it put back.
- [WritePCIConfig](#writepciconfig) - A register of a function's configuration space, written.

## AddPCIIntServer

A server run whenever a function raises its INTx line.

**SYNOPSIS**

```zig
fn AddPCIIntServer(base: *PCIBase, device: *pci.PCIDevice, server: *exec.Interrupt) bool
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `device` - a function the caller has claimed.
- `server` - an `Interrupt` whose `code` is an `IntServerFn`, as
  AddIntServer takes one.

**RESULT**

True when the server is on the line; false for a function that has
no INTx line (`interrupt_pin` 0), or signals messages instead
(AllocPCIVectors), which switched it off.

**BEHAVIOR**

Where the host bridge's lines are sources of the interrupt controller
of their own (QEMU's), the server goes on the source's chain with
AddIntServer. Where the bridge gathers them on one interrupt (the
JH7110's), it goes on the library's chain for the line, which the
library's own server on the bridge's interrupt runs whenever the
bridge has seen the line raised; the bridge's interrupt is hooked
with the first server and the line let through.

Either way the server is run as AddIntServer runs it, with the exec
interrupt number the line ends up on, and answers non-zero when the
interrupt was its function's: the line may be shared with other
functions, whose servers come after.

**CONTEXT**

- Waits: no. The server itself must not wait.
- Interrupts: safe. It takes Disable.
- Locks: takes Disable, which guards the chains.
- Process: a Task will do.

**OWNERSHIP**

The `Interrupt` stays the caller's and must outlive its place on the
chain: RemPCIIntServer before it goes.

**NOTES**

INTx is a level: a server makes its function let go of the line
before it answers, or it is run again at once.

A function with message-signalled interrupts is hooked with
AddPCIVectorServer: its messages do not share a line, and a bridge
with many functions behind it has no more lines than four.

**BUGS**

None known.

**SEE ALSO**

`RemPCIIntServer`, `AllocPCIVectors`, `AddIntServer`

**EXAMPLES**

```zig
unit.server = .{ .node = .{ .type = .interrupt, .name = "xhci.device" }, .data = unit, .code = @ptrCast(&intServer) };
if (!pb.AddPCIIntServer(function, &unit.server)) return poll(unit);
```

## AddPCIVectorServer

A server run whenever a function signals one of its vectors.

**SYNOPSIS**

```zig
fn AddPCIVectorServer(base: *PCIBase, device: *pci.PCIDevice, vector: u32, server: *exec.Interrupt) bool
```

**SINCE**

2.0. LVO -68.

**INPUTS**

- `device` - a function the caller has claimed, with vectors from
  AllocPCIVectors.
- `vector` - which of them, from 0.
- `server` - an `Interrupt` whose `code` is an `IntServerFn`, as
  AddIntServer takes one.

**RESULT**

True when the server is on the vector; false for a vector the
function was not given.

**BEHAVIOR**

The server goes on the vector's chain, which the host bridge's
interrupt runs whenever the function's message for the vector has
come - after the bridge's note of it is cleared, so a message that
comes while the servers run is seen again. The vector is let through
at the function once it has its first server, and the bridge's
interrupt hooked.

The server is run as AddIntServer runs it, with the bridge's exec
interrupt number, and answers non-zero when it handled the message;
the servers after it on the vector are not run then.

**CONTEXT**

- Waits: no. The server itself must not wait.
- Interrupts: safe. It takes Disable.
- Locks: takes Disable, which guards the chains.
- Process: a Task will do.

**OWNERSHIP**

The `Interrupt` stays the caller's and must outlive its place on the
chain: RemPCIVectorServer before it goes.

**NOTES**

A message is an edge, not a level: the function sends it once, and
the server need not quieten anything for it to stop. What the event
was is the function's to say - its own registers, its queues.

**BUGS**

None known.

**SEE ALSO**

`AllocPCIVectors`, `RemPCIVectorServer`, `AddPCIIntServer`

**EXAMPLES**

```zig
unit.server = .{ .node = .{ .type = .interrupt, .name = "nvme.device" }, .data = unit, .code = @ptrCast(&queueServer) };
if (!pb.AddPCIVectorServer(function, 0, &unit.server)) return poll(unit);
```

## AllocPCIVectors

Message-signalled interrupts for a function, MSI-X where it has it, MSI otherwise.

**SYNOPSIS**

```zig
fn AllocPCIVectors(base: *PCIBase, device: *pci.PCIDevice, count: u32) u32
```

**SINCE**

2.0. LVO -60.

**INPUTS**

- `device` - a function the caller has claimed.
- `count` - how many vectors the driver can use, from 1.

**RESULT**

How many vectors the function got, 1 to `count`: its vectors 0 to
that less one, which AddPCIVectorServer hooks. 0 for none: the host
bridge takes no messages, the function sends none, or the bridge's
vectors are given to other functions - and the function keeps its
INTx line, which AddPCIIntServer hooks.

**BEHAVIOR**

The host bridge's vectors are given out in runs. With MSI-X the
function gets as many as it has table entries, the driver asks for,
and the bridge has free; each entry is written with the bridge's
address and its vector, and masked. With MSI it gets the largest
power of two of them that is no more than that, aligned to its size,
as MSI has the function count them; each vector is masked where the
function can mask them one by one. Either way the function's MSI or
MSI-X is switched on and its INTx off (PCI_COMMAND_INTX_DISABLE), and
`vector_kind` and `vectors` in its PCIDevice say what it has.

A vector is let through once a server is on it (AddPCIVectorServer),
and masked again once none is.

A function that has vectors already gets no more: the result is how
many it has.

**CONTEXT**

- Waits: yes, for the library's claim lock.
- Interrupts: no.
- Locks: takes the claim lock.
- Process: a Task will do.

**OWNERSHIP**

The vectors are the function's until FreePCIVectors or
ReleasePCIDevice, which gives them back.

**NOTES**

What a function signals with each of its vectors is its own: an NVMe
controller one queue each, an xHCI one interrupter each. A driver
that asks for one has every event on vector 0.

The MSI-X table is in one of the function's BARs: where that one was
not placed, or its memory is not decoded, MSI is tried.

**BUGS**

QEMU's virt machine as the library knows it has no bridge that takes
messages: every function there gets 0 and keeps its INTx line.

**SEE ALSO**

`AddPCIVectorServer`, `FreePCIVectors`, `AddPCIIntServer`

**EXAMPLES**

```zig
if (pb.AllocPCIVectors(function, 1) == 1 and pb.AddPCIVectorServer(function, 0, &unit.server)) return;
_ = pb.AddPCIIntServer(function, &unit.server);
```

## ClaimPCIDevice

A function taken by the driver that is to use it.

**SYNOPSIS**

```zig
fn ClaimPCIDevice(base: *PCIBase, device: *pci.PCIDevice, owner: [*:0]const u8) ?[*:0]const u8
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `device` - from FindPCIDevice or FindPCIClass.
- `owner` - the driver's name, as a listing shows it: "xhci.device".

**RESULT**

Null when the function is the caller's now; the name of the driver
that has it otherwise.

**BEHAVIOR**

One driver at a time has a function: the claim is on record in its
PCIDevice (`owner`) until ReleasePCIDevice.

A function that was reset since the library set it up - its BARs or
what it decodes are not what they were - has what the library set up
in it written back first, and the library says so on the debug
output. A function resets itself where its link goes down and comes
back, as it does when its power dips. Otherwise nothing of the
function is changed.

**CONTEXT**

- Waits: yes, for the library's claim lock.
- Interrupts: no.
- Locks: takes the claim lock.
- Process: a Task will do.

**OWNERSHIP**

`owner` is kept, not copied: it lives as long as the claim.

**NOTES**

A function reset while a driver has it is the driver's to notice - its
registers behind the BARs no longer answer - and ResetPCIDevice puts
it back.

**BUGS**

None known.

**SEE ALSO**

`ReleasePCIDevice`, `FindPCIClass`, `ResetPCIDevice`

**EXAMPLES**

```zig
if (pb.ClaimPCIDevice(function, "xhci.device")) |holder| return fail(holder);
```

## FindPCICapability

Where a function's capability is, on the list its configuration space starts at PCI_CAPABILITY_LIST.

**SYNOPSIS**

```zig
fn FindPCICapability(base: *PCIBase, device: *pci.PCIDevice, id: u32, after: u32) u32
```

**SINCE**

2.0. LVO -52.

**INPUTS**

- `device` - from FindPCIDevice or FindPCIClass.
- `id` - the capability's ID (PCI_CAP_ID_*).
- `after` - 0 for the first with that ID; where one was found, for the
  next after it.

**RESULT**

Where the capability starts in the function's configuration space -
its ID byte, the next one's pointer after it; 0 for none.

**BEHAVIOR**

The list is followed as the function has it, from PCI_CAPABILITY_LIST
or from the capability at `after`: a function whose status says it
has no list has none, and a list that runs in a circle ends after the
48 a configuration space has room for.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is kept.

**NOTES**

A function may have more than one capability with an ID - vendor
specific ones (PCI_CAP_ID_VNDR) most of all: `after` goes through
them.

**BUGS**

None known.

**SEE ALSO**

`FindPCIExtCapability`, `ReadPCIConfig`

**EXAMPLES**

```zig
const pm = pb.FindPCICapability(function, pci.PCI_CAP_ID_PM, 0);
if (pm != 0) power = pb.ReadPCIConfig(function, pm + pci.PCI_PM_CTRL, 2);
```

## FindPCIClass

The next function of a class.

**SYNOPSIS**

```zig
fn FindPCIClass(base: *PCIBase, previous: ?*pci.PCIDevice, class_code: u32, mask: u32) ?*pci.PCIDevice
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `previous` - where to go on from; null: from the first function.
- `class_code` - class, subclass and programming interface, PCI's
  24-bit class code (PCI_CLASS_*).
- `mask` - the bits of it that are compared: PCI_CLASS_MASK for all,
  0xFF0000 for the class alone.

**RESULT**

The function, or null when no more are.

**BEHAVIOR**

As FindPCIDevice, in the same order: a function whose class code and
`class_code` agree in every bit of `mask`.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

The function is the library's.

**NOTES**

The nth function a driver finds of its class is the unit n it gives
that function: xhci.device's units are the xHCI functions in order.

**BUGS**

None known.

**SEE ALSO**

`FindPCIDevice`, `ClaimPCIDevice`

**EXAMPLES**

```zig
const xhci = pb.FindPCIClass(null, pci.PCI_CLASS_SERIAL_USB_XHCI, pci.PCI_CLASS_MASK) orelse return;
```

## FindPCIDevice

The next function made by a vendor, as a device.

**SYNOPSIS**

```zig
fn FindPCIDevice(base: *PCIBase, previous: ?*pci.PCIDevice, vendor: u32, device: u32) ?*pci.PCIDevice
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `previous` - where to go on from; null: from the first function.
- `vendor` - its vendor ID, or PCI_ANY.
- `device` - its device ID, or PCI_ANY.

**RESULT**

The function, or null when no more are.

**BEHAVIOR**

The functions are in the order the library found them: the board's
host bridges one after the other, and behind each its buses in the
order they were walked, deep first. With PCI_ANY for both every
function comes, bridges too.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none needed: the chain does not change once the library is
  open.
- Process: a Task will do.

**OWNERSHIP**

The function is the library's, there for as long as the library is
open; a driver claims it with ClaimPCIDevice before it uses it.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`FindPCIClass`, `ClaimPCIDevice`

**EXAMPLES**

```zig
var it = pb.FindPCIDevice(null, pci.PCI_ANY, pci.PCI_ANY);
while (it) |function| : (it = pb.FindPCIDevice(function, pci.PCI_ANY, pci.PCI_ANY)) {
    list(function);
}
```

## FindPCIExtCapability

Where a PCI Express function's extended capability is, on the list from 0x100 of its 4 KiB.

**SYNOPSIS**

```zig
fn FindPCIExtCapability(base: *PCIBase, device: *pci.PCIDevice, id: u32, after: u32) u32
```

**SINCE**

2.0. LVO -56.

**INPUTS**

- `device` - from FindPCIDevice or FindPCIClass.
- `id` - the extended capability's ID (PCI_EXT_CAP_ID_*).
- `after` - 0 for the first with that ID; where one was found, for the
  next after it.

**RESULT**

Where the capability's header is in the function's configuration
space - its ID in the low 16 bits, its version, and the next one's
offset in the top 12; 0 for none.

**BEHAVIOR**

The list is followed from 0x100, or from the capability at `after`.
A function without the PCI Express capability has no extended space
(`express_type` PCI_EXP_TYPE_NONE) and none; one whose extended space
reads all ones or nothing has none either.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is kept.

**NOTES**

The list holds what the function has, Advanced Error Reporting, its
serial number (PCI_EXT_CAP_ID_DSN), the resizable BAR, L1 substates,
and vendor specific ones among them.

**BUGS**

None known.

**SEE ALSO**

`FindPCICapability`, `ReadPCIConfig`

**EXAMPLES**

```zig
const dsn = pb.FindPCIExtCapability(function, pci.PCI_EXT_CAP_ID_DSN, 0);
if (dsn != 0) low = pb.ReadPCIConfig(function, dsn + 4, 4);
```

## FreePCIVectors

A function's message-signalled interrupts given back, and its INTx line on again.

**SYNOPSIS**

```zig
fn FreePCIVectors(base: *PCIBase, device: *pci.PCIDevice) void
```

**SINCE**

2.0. LVO -64.

**INPUTS**

- `device` - a function the caller has claimed.

**RESULT**

Nothing.

**BEHAVIOR**

The function's MSI or MSI-X is switched off - MSI-X with every vector
masked - and its INTx back on. A server still on one of its vectors
is taken off and not run again. The host bridge's vectors are free
for the next function, and `vectors` in the PCIDevice is 0 again.
Nothing happens to a function that has none.

**CONTEXT**

- Waits: yes, for the library's claim lock.
- Interrupts: no.
- Locks: takes the claim lock, and Disable.
- Process: a Task will do.

**OWNERSHIP**

The servers that were on the vectors are the caller's again.

**NOTES**

ReleasePCIDevice gives them back too.

**BUGS**

None known.

**SEE ALSO**

`AllocPCIVectors`, `RemPCIVectorServer`

**EXAMPLES**

```zig
pb.RemPCIVectorServer(function, 0, &unit.server);
pb.FreePCIVectors(function);
```

## ReadPCIConfig

A register of a function's configuration space, read.

**SYNOPSIS**

```zig
fn ReadPCIConfig(base: *PCIBase, device: *pci.PCIDevice, offset: u32, size: u32) u32
```

**SINCE**

1.0. LVO -28.

**INPUTS**

- `device` - from FindPCIDevice or FindPCIClass.
- `offset` - where in its 4 KiB (PCI_*), a multiple of `size`.
- `size` - 1, 2 or 4 bytes.

**RESULT**

The register's value; all ones for a size or an offset that is not
one, as a function that is not there answers.

**BEHAVIOR**

One read of the register, as wide as asked: a register that changes
when it is read - a status that is cleared - is read once.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is kept.

**NOTES**

What the library hides of a bridge's own - the JH7110 root port's
BAR0 and BAR1 - reads 0.

**BUGS**

None known.

**SEE ALSO**

`WritePCIConfig`

**EXAMPLES**

```zig
const command = pb.ReadPCIConfig(function, pci.PCI_COMMAND, 2);
```

## ReleasePCIDevice

A claimed function given back, its bus mastering off and its vectors with it.

**SYNOPSIS**

```zig
fn ReleasePCIDevice(base: *PCIBase, device: *pci.PCIDevice) void
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `device` - a function the caller claimed.

**RESULT**

Nothing.

**BEHAVIOR**

The claim is taken off the record, and the function's bus mastering
switched off: what it was set up to move into memory cannot reach
memory a driver no longer holds. Its memory decoding stays on. Its
message-signalled interrupts are given back as FreePCIVectors gives
them, and its INTx line is on again.

**CONTEXT**

- Waits: yes, for the library's claim lock.
- Interrupts: no.
- Locks: takes the claim lock.
- Process: a Task will do.

**OWNERSHIP**

The function is free for the next driver.

**NOTES**

Its interrupt servers are the driver's to take off first
(RemPCIIntServer, RemPCIVectorServer): a server still on one of its
vectors is taken off, one on its INTx line is not.

**BUGS**

None known.

**SEE ALSO**

`ClaimPCIDevice`, `FreePCIVectors`

**EXAMPLES**

```zig
pb.RemPCIIntServer(function, &server);
pb.ReleasePCIDevice(function);
```

## RemPCIIntServer

A server taken off a function's INTx line.

**SYNOPSIS**

```zig
fn RemPCIIntServer(base: *PCIBase, device: *pci.PCIDevice, server: *exec.Interrupt) void
```

**SINCE**

1.0. LVO -48.

**INPUTS**

- `device` - the function AddPCIIntServer put it on.
- `server` - the server.

**RESULT**

Nothing.

**BEHAVIOR**

The server is off its chain when this returns and is not run again.
Where the bridge gathers the lines, a line with no server left is
masked, and the bridge's interrupt let go once no line has one.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It takes Disable.
- Locks: takes Disable.
- Process: a Task will do.

**OWNERSHIP**

The `Interrupt` is the caller's again.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`AddPCIIntServer`

**EXAMPLES**

```zig
pb.RemPCIIntServer(function, &unit.server);
```

## RemPCIVectorServer

A server taken off one of a function's vectors.

**SYNOPSIS**

```zig
fn RemPCIVectorServer(base: *PCIBase, device: *pci.PCIDevice, vector: u32, server: *exec.Interrupt) void
```

**SINCE**

2.0. LVO -72.

**INPUTS**

- `device` - the function AddPCIVectorServer put it on.
- `vector` - the vector it put it on.
- `server` - the server.

**RESULT**

Nothing.

**BEHAVIOR**

The server is off the vector's chain when this returns and is not
run again. A vector with no server left is masked at the function,
and the host bridge's interrupt let go once nothing is on it.

**CONTEXT**

- Waits: no.
- Interrupts: safe. It takes Disable.
- Locks: takes Disable.
- Process: a Task will do.

**OWNERSHIP**

The `Interrupt` is the caller's again.

**NOTES**

The vector stays the function's: AddPCIVectorServer may put a server
on it again. FreePCIVectors gives it back.

**BUGS**

None known.

**SEE ALSO**

`AddPCIVectorServer`, `FreePCIVectors`

**EXAMPLES**

```zig
pb.RemPCIVectorServer(function, 0, &unit.server);
```

## ResetPCIDevice

A function reset on its own, and what the library and its driver set up in it put back.

**SYNOPSIS**

```zig
fn ResetPCIDevice(base: *PCIBase, device: *pci.PCIDevice) bool
```

**SINCE**

2.0. LVO -76.

**INPUTS**

- `device` - a function the caller has claimed.

**RESULT**

True when the function was reset, or had been, and answers again;
false when it cannot be reset on its own, or did not answer within a
minute - when asked, or after its reset.

**BEHAVIOR**

The first way the function has is taken, as Linux takes them:

1. its function level reset (PCI Express, PCI_EXP_DEVCAP_FLR);
2. the same through the Advanced Features capability (PCI);
3. a trip to D3hot and back, for a function that resets itself
   there (power management, no PCI_PM_CTRL_NO_SOFT_RESET);
4. a reset of the bus it is on, through the bridge above it - only
   where it is the one function on that bus.

**A function that does not answer** is waited for first: one whose
power dipped takes its link down and brings it up again, and what
reads back meanwhile is neither its configuration nor the way it
resets. **One that answers having lost its configuration** - reset
behind the library's back since it was set up - has had its reset:
what the library set up in it is written back, and it is not reset
again.

Otherwise its configuration is kept - its command, BARs, expansion
ROM, cache line, interrupt line, and its PCI Express control - and
its decoding and bus mastering switched off. A function level reset
waits up to 700 ms for the transactions the function has out to be
done. The reset is given 100 ms (a bus reset its link's training
first, and 1 s on conventional PCI), and then the function is waited
for to answer its configuration; all that was kept is written back,
the command last, and its MSI or MSI-X as AllocPCIVectors set it up,
each vector let through that has a server.

**A function is waited for up to a minute**, as Linux waits for one:
PCI Express gives a function a second to answer after its reset, and
not every one keeps to it - a Micron 2550 answers 1.4 s after its
function level reset.

**CONTEXT**

- Waits: yes, on timer.device: up to a minute for a function that
  does not answer, and as long again after its reset.
- Interrupts: no.
- Locks: none taken.
- Process: a Task: it waits on a message port of its own.

**OWNERSHIP**

The function stays the caller's.

**NOTES**

What a reset clears of the function's own - its registers behind the
BARs, its queues - is its driver's to set up again; so is its bus
mastering, where the function had lost its configuration before. Its servers stay
on their lines and vectors: what the function signals before its
driver has set it up again, they answer.

**BUGS**

A PCI-to-PCI bridge is not reset: what is behind it would lose what
the library set up in it.

**SEE ALSO**

`ClaimPCIDevice`, `AllocPCIVectors`

**EXAMPLES**

```zig
if (!pb.ResetPCIDevice(function)) return error.NoReset;
try unit.start();
```

## WritePCIConfig

A register of a function's configuration space, written.

**SYNOPSIS**

```zig
fn WritePCIConfig(base: *PCIBase, device: *pci.PCIDevice, offset: u32, size: u32, value: u32) void
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `device` - a function the caller has claimed.
- `offset` - where in its 4 KiB (PCI_*), a multiple of `size`.
- `size` - 1, 2 or 4 bytes.
- `value` - what is written, its low `size` bytes.

**RESULT**

Nothing. A size or an offset that is not one writes nothing.

**BEHAVIOR**

One write of the register, as wide as asked: the bytes beside it are
not touched, so a status's write-one-to-clear bits stay as they are
when its command is written.

**CONTEXT**

- Waits: no.
- Interrupts: safe.
- Locks: none needed.
- Process: a Task will do.

**OWNERSHIP**

Nothing is kept.

**NOTES**

The BARs and a bridge's bus numbers and windows are the library's, set
as it walked the buses; a driver that moves them is on its own.

**BUGS**

None known.

**SEE ALSO**

`ReadPCIConfig`, `ClaimPCIDevice`

**EXAMPLES**

```zig
const command = pb.ReadPCIConfig(function, pci.PCI_COMMAND, 2);
pb.WritePCIConfig(function, pci.PCI_COMMAND, 2, command | pci.PCI_COMMAND_MASTER);
```
