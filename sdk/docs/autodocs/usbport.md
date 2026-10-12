# usbport.resource

usbport.resource's functions: who holds each of the chip's USB ports,
and which controller it is given to - on the ESP32-S3 the console's
USB-Serial-JTAG port or the USB OTG controller, which share the one.
A resource: no Open or Close, its first function in the first slot.
The base comes from OpenResource("usbport.resource").

Generated from the source by `./zig build autodoc`.

## Index

- [OwnUSBPort](#ownusbport) - Bid for the port of `handle`'s controller.
- [ReleaseUSBPort](#releaseusbport) - Let go of the port `handle` holds, or of its bid.
- [USBPortOwner](#usbportowner) - Who holds `port`.

## OwnUSBPort

Bid for the port of `handle`'s controller.

**SYNOPSIS**

```zig
fn OwnUSBPort(pb: *UsbPortBase, handle: *usbport.USBPortHandle) bool
```

**SINCE**

1.0. LVO -4.

**INPUTS**

- `handle` - the bid, filled in by the caller: `node.pri` its
  priority (USBPORTPRI_*) and `node.name` who bids; `task` and
  `signals` what it is told by; `controller`, `unit` and `role` the
  controller the port is to be given to and what it is on it. `state`
  is the resource's.

**RESULT**

True if the port is the caller's now, switched to its controller.
False if it waits for it - or if the chip has no such controller,
when `state` stays USBPORT_IDLE and nothing is ever sent.

**BEHAVIOR**

The handle joins the port's bidders, by priority. A port nobody holds
is given to it at once. A holder of lower priority is told the port is
wanted: its `state` becomes USBPORT_WANTED and its signals are sent;
it lets go with ReleaseUSBPort when what it is doing is done. Whenever
the port then comes to this handle, its `state` becomes USBPORT_HELD
and its signals are sent. A holder of the same or higher priority
keeps the port until it lets go of its own accord. Bidding again with
a handle that is already a bidder changes nothing.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: takes the resource's spinlock for the list.
- Process: a Task will do.

**OWNERSHIP**

The handle stays the caller's memory, kept by the resource until
ReleaseUSBPort with USBPORTF_REMOVE; it must not move or be freed
before. The signals stay the caller's.

**NOTES**

The signals say only that `state` changed: the bidder reads it when
they come. A bidder that waits for the port waits for its signals, with
a time limit of its own if the holder may take long.

**BUGS**

None known.

**SEE ALSO**

`ReleaseUSBPort`, `USBPortOwner`

**EXAMPLES**

```zig
handle.* = .{
    .node = .{ .pri = usbport.USBPORTPRI_HOST, .name = "usbotg.device" },
    .task = sys.FindTask(null),
    .signals = @as(u32, 1) << @intCast(bit),
    .controller = usbport.USBCTL_OTG,
    .role = st.USBROLE_HOST,
};
if (!pb.OwnUSBPort(handle)) _ = sys.Wait(handle.signals);
```

## ReleaseUSBPort

Let go of the port `handle` holds, or of its bid.

**SYNOPSIS**

```zig
fn ReleaseUSBPort(pb: *UsbPortBase, handle: *usbport.USBPortHandle, flags: u32) void
```

**SINCE**

1.0. LVO -8.

**INPUTS**

- `handle` - a bid made with OwnUSBPort.
- `flags` - USBPORTF_REMOVE: leave the bidders too.

**RESULT**

None.

**BEHAVIOR**

A holder lets go: the port goes to the highest bidder left - switched
to its controller, its `state` USBPORT_HELD and its signals sent - or,
with no bidder left, back to the controller the chip starts with.
Without USBPORTF_REMOVE the caller stays a bidder (`state`
USBPORT_WAITING) and has the port again, told by its signals, once
everyone above it has let go; a caller nobody outranks keeps the port
(`state` USBPORT_HELD, no signal). With USBPORTF_REMOVE it leaves
(`state` USBPORT_IDLE). A bidder that does not hold the port withdraws
with USBPORTF_REMOVE; its holder is no longer wanted if nobody else
above it waits. A handle that is no bidder is left alone.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: takes the resource's spinlock for the list.
- Process: a Task will do.

**OWNERSHIP**

After USBPORTF_REMOVE the handle is the caller's alone again.

**NOTES**

A holder lets go only between two pieces of its work: the port is
switched at once, under whatever it was sending.

**BUGS**

None known.

**SEE ALSO**

`OwnUSBPort`, `USBPortOwner`

**EXAMPLES**

```zig
if (handle.state == usbport.USBPORT_WANTED) pb.ReleaseUSBPort(handle, 0);
pb.ReleaseUSBPort(handle, usbport.USBPORTF_REMOVE);
```

## USBPortOwner

Who holds `port`.

**SYNOPSIS**

```zig
fn USBPortOwner(pb: *UsbPortBase, port: u32) ?[*:0]const u8
```

**SINCE**

1.0. LVO -12.

**INPUTS**

- `port` - 0 to USBPORT_PORTS - 1.

**RESULT**

The holder's name, as its handle's node gives it; null if nobody
holds the port, or there is no such port.

**BEHAVIOR**

Reads who holds the port now; the answer may be out of date by the
time it is looked at.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: takes the resource's spinlock for the read.
- Process: a Task will do.

**OWNERSHIP**

The name is the holder's, valid while it holds the port: copy it, or
print it at once.

**NOTES**

A port nobody holds is with the controller the chip starts with.

**BUGS**

None known.

**SEE ALSO**

`OwnUSBPort`, `ReleaseUSBPort`

**EXAMPLES**

```zig
var port: u32 = 0;
while (port < usbport.USBPORT_PORTS) : (port += 1) {
    if (pb.USBPortOwner(port)) |name| _ = Printf(dl, "port %u: %s\n", .{ port, name });
}
```
