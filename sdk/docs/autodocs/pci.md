# pci.library

pci.library's functions: the machine's PCI functions found, claimed,
their configuration space read and written, their interrupts hooked.
Open it with OpenLibrary("pci.library", 1); the structures are in
sdk.pci.

Generated from the source by `./zig build autodoc`.

## Index

- [AddPCIIntServer](#addpciintserver) - A server run whenever a function raises its INTx line.
- [ClaimPCIDevice](#claimpcidevice) - A function taken by the driver that is to use it.
- [FindPCIClass](#findpciclass) - The next function of a class.
- [FindPCIDevice](#findpcidevice) - The next function made by a vendor, as a device.
- [ReadPCIConfig](#readpciconfig) - A register of a function's configuration space, read.
- [ReleasePCIDevice](#releasepcidevice) - A claimed function given back, its bus mastering off.
- [RemPCIIntServer](#rempciintserver) - A server taken off a function's INTx line.
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
no INTx line (`interrupt_pin` 0).

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

**BUGS**

MSI and MSI-X are not set up: every function interrupts on its INTx
line.

**SEE ALSO**

`RemPCIIntServer`, `AddIntServer`

**EXAMPLES**

```zig
unit.server = .{ .node = .{ .type = .interrupt, .name = "xhci.device" }, .data = unit, .code = @ptrCast(&intServer) };
if (!pb.AddPCIIntServer(function, &unit.server)) return poll(unit);
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
PCIDevice (`owner`) until ReleasePCIDevice. Nothing of the function
is changed.

**CONTEXT**

- Waits: yes, for the library's claim lock.
- Interrupts: no.
- Locks: takes the claim lock.
- Process: a Task will do.

**OWNERSHIP**

`owner` is kept, not copied: it lives as long as the claim.

**NOTES**

None.

**BUGS**

None known.

**SEE ALSO**

`ReleasePCIDevice`, `FindPCIClass`

**EXAMPLES**

```zig
if (pb.ClaimPCIDevice(function, "xhci.device")) |holder| return fail(holder);
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

A claimed function given back, its bus mastering off.

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
memory a driver no longer holds. Its memory decoding stays on.

**CONTEXT**

- Waits: yes, for the library's claim lock.
- Interrupts: no.
- Locks: takes the claim lock.
- Process: a Task will do.

**OWNERSHIP**

The function is free for the next driver.

**NOTES**

Its interrupt servers are the driver's to take off first
(RemPCIIntServer).

**BUGS**

None known.

**SEE ALSO**

`ClaimPCIDevice`

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
