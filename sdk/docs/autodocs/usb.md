# usb.library

usb.library's functions: the USB buses, the devices on them, their
descriptors, and pipes to their endpoints. Open it with
OpenLibrary("usb.library", 1); the structures are in sdk.usb.

Generated from the source by `./zig build autodoc`.

## Index

- [AddUSBNotify](#addusbnotify) - Asks for signals whenever a device comes, goes or is bound.
- [ClaimUSBInterface](#claimusbinterface) - Takes an interface of a device for a program that drives it itself.
- [ClearUSBStall](#clearusbstall) - Clears a stalled endpoint's halt, and its data toggle with it.
- [CloseUSBPipe](#closeusbpipe) - Closes a pipe.
- [DoUSBControl](#dousbcontrol) - Makes a control transfer on a device's endpoint 0, and waits for it.
- [FindUSBEndpoint](#findusbendpoint) - Finds an interface's first endpoint of a direction and transfer type.
- [FindUSBInterface](#findusbinterface) - Finds a device's next interface of a class, subclass and protocol.
- [GetUSBString](#getusbstring) - Reads one of a device's strings, as Latin-1.
- [NextUSBDescriptor](#nextusbdescriptor) - Finds the next descriptor of a kind in a device's configuration.
- [ObtainUSBDeviceList](#obtainusbdevicelist) - Takes the list of every device on every bus, for reading.
- [OpenUSBPipe](#openusbpipe) - Opens a pipe to one endpoint of a device: a request already filled in for it.
- [ReleaseUSBDeviceList](#releaseusbdevicelist) - Lets go of the list ObtainUSBDeviceList took.
- [ReleaseUSBInterface](#releaseusbinterface) - Gives back an interface ClaimUSBInterface took.
- [RemUSBNotify](#remusbnotify) - Ends what AddUSBNotify asked for.
- [StartUSB](#startusb) - Starts a bus: its controller opened, its root hub set up, and from then on whatever is plugged in.
- [StopUSB](#stopusb) - Stops a bus: every device on it let go, its controller closed.

## AddUSBNotify

Asks for signals whenever a device comes, goes or is bound.

**SYNOPSIS**

```zig
fn AddUSBNotify(base: *UsbBase, task: *exec.Task, signals: u32) ?*usb.USBNotify
```

**SINCE**

1.0. LVO -76.

**INPUTS**

- `task` - who is told, usually the caller.
- `signals` - the signals sent; allocated by the task.

**RESULT**

A handle for RemUSBNotify, or null without memory.

**BEHAVIOR**

On every change of any bus the signals are sent: a device added to or
removed from the list, an interface bound. They say that something
changed, not what; the task reads the list again. Changes close
together may come as one signal.

**CONTEXT**

- Waits: yes, for the notification list.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The handle is the caller's until RemUSBNotify, which it must call
before the task ends.

**BUGS**

None known.

**SEE ALSO**

`RemUSBNotify`, `ObtainUSBDeviceList`

**EXAMPLES**

```zig
const signal = sys.AllocSignal(-1);
const handle = ub.AddUSBNotify(sys.FindTask(null).?, @as(u32, 1) << @intCast(signal)) orelse return;
defer ub.RemUSBNotify(handle);
```

## ClaimUSBInterface

Takes an interface of a device for a program that drives it itself.

**SYNOPSIS**

```zig
fn ClaimUSBInterface(base: *UsbBase, device: *usb.USBDevice, interface_number: u32, name: [*:0]const u8) bool
```

**SINCE**

1.0. LVO -68.

**INPUTS**

- `device` - the device, from the list.
- `interface_number` - bInterfaceNumber, below `USB_MAX_INTERFACES`.
- `name` - who takes it, for a listing; must outlive the claim.

**RESULT**

True if it is now the program's; false if a class driver or another
program has it.

**BEHAVIOR**

A claim is a binding with a program instead of a driver: the program
opens pipes to the interface's endpoints and does what a driver would.
A microcontroller's own protocol, a device no driver is written for,
a test, need no device of their own.

**CONTEXT**

- Waits: yes, for the device list.
- Interrupts: no.
- Locks: takes the device list's semaphore; it may not be held.
- Process: a Task will do.

**OWNERSHIP**

The interface is the program's until ReleaseUSBInterface - or until
the device goes, which a program learns from its transfers' errors
or from AddUSBNotify; it then closes its pipes and releases nothing.

**BUGS**

A device that goes while claimed takes the claim with it silently.

**SEE ALSO**

`ReleaseUSBInterface`, `OpenUSBPipe`

**EXAMPLES**

```zig
if (!ub.ClaimUSBInterface(device, 0, "test/USB")) return fail("interface 0 is taken");
defer ub.ReleaseUSBInterface(device, 0);
```

## ClearUSBStall

Clears a stalled endpoint's halt, and its data toggle with it.

**SYNOPSIS**

```zig
fn ClearUSBStall(base: *UsbBase, pipe: *usb.USBPipe) i32
```

**SINCE**

1.0. LVO -64.

**INPUTS**

- `pipe` - the endpoint's pipe, with nothing outstanding.

**RESULT**

0, or the control transfer's io_Error.

**BEHAVIOR**

CLEAR_FEATURE(ENDPOINT_HALT) to the endpoint, and the pipe's toggle
back to DATA0, which is where the device's goes too. A control pipe
has no halt to clear: 0 at once.

**CONTEXT**

- Waits: yes, for the device.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`OpenUSBPipe`, `DoUSBControl`

**EXAMPLES**

```zig
if (pipe.io.std.req.err == usbhc.UHIOERR_STALL) _ = ub.ClearUSBStall(pipe);
```

## CloseUSBPipe

Closes a pipe.

**SYNOPSIS**

```zig
fn CloseUSBPipe(base: *UsbBase, pipe: ?*usb.USBPipe) void
```

**SINCE**

1.0. LVO -56.

**INPUTS**

- `pipe` - from OpenUSBPipe, with nothing outstanding; null does
  nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The pipe's memory is given back. A transfer still outstanding must be
aborted (AbortIO, WaitIO) first.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The pipe is gone.

**BUGS**

None known.

**SEE ALSO**

`OpenUSBPipe`

**EXAMPLES**

```zig
_ = sys.AbortIO(&pipe.io.std.req);
_ = sys.WaitIO(&pipe.io.std.req);
ub.CloseUSBPipe(pipe);
```

## DoUSBControl

Makes a control transfer on a device's endpoint 0, and waits for it.

**SYNOPSIS**

```zig
fn DoUSBControl(base: *UsbBase, device: *usb.USBDevice, setup: *const usb.SetupPacket, data: ?*anyopaque, actual: ?*u32) i32
```

**SINCE**

1.0. LVO -60.

**INPUTS**

- `device` - the device.
- `setup` - the setup packet; its `length` is the data stage's bytes,
  its `request_type` their direction.
- `data` - the data stage's bytes, `setup.length` of them; null when
  there are none.
- `actual` - where the bytes moved go; null if not wanted.

**RESULT**

0, or the transfer's io_Error (`UHIOERR_STALL` for a request the
device refused, `UHIOERR_NAKTIMEOUT` for one it never answered in a
second, `UHIOERR_DETACHED` for a device that went).

**BEHAVIOR**

The transfer is the caller's own request, on a port made for it: two
tasks may each make one on the same device at once, and the device
answers them in turn.

**CONTEXT**

- Waits: yes, for the device.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

`data` is the caller's.

**BUGS**

None known.

**SEE ALSO**

`OpenUSBPipe`, `GetUSBString`

**EXAMPLES**

```zig
const idle = usb.SetupPacket{ .request_type = d.USB_TYPE_CLASS | d.USB_RECIP_INTERFACE,
    .request = d.HID_REQ_SET_IDLE, .value = 0, .index = number, .length = 0 };
_ = ub.DoUSBControl(device, &idle, null, null);
```

## FindUSBEndpoint

Finds an interface's first endpoint of a direction and transfer type.

**SYNOPSIS**

```zig
fn FindUSBEndpoint(base: *UsbBase, device: *usb.USBDevice, interface_desc: *const usb.InterfaceDescriptor, direction: u32, transfer_type: u32) ?*const usb.EndpointDescriptor
```

**SINCE**

1.0. LVO -44.

**INPUTS**

- `device` - the device the interface is of.
- `interface_desc` - one of its interfaces, from FindUSBInterface or a
  binding.
- `direction` - `USB_DIR_IN` or `USB_DIR_OUT`.
- `transfer_type` - `USB_ENDPOINT_XFER_*`.

**RESULT**

The endpoint's descriptor, or null if the interface has none such.

**BEHAVIOR**

Only the interface's own endpoints are looked at: the walk ends at the
next interface.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none; the device must not go meanwhile.
- Process: a Task will do.

**OWNERSHIP**

The descriptor stays the device's.

**BUGS**

None known.

**SEE ALSO**

`FindUSBInterface`, `OpenUSBPipe`

**EXAMPLES**

```zig
const in = ub.FindUSBEndpoint(device, interface, d.USB_DIR_IN, d.USB_ENDPOINT_XFER_INT) orelse return false;
const pipe = ub.OpenUSBPipe(device, in.endpoint_address, port) orelse return false;
```

## FindUSBInterface

Finds a device's next interface of a class, subclass and protocol.

**SYNOPSIS**

```zig
fn FindUSBInterface(base: *UsbBase, device: *usb.USBDevice, previous: ?*const usb.InterfaceDescriptor, class: i32, subclass: i32, protocol: i32) ?*const usb.InterfaceDescriptor
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `device` - a device on the list, or the one a driver was bound to.
- `previous` - an interface this call answered, or null for the first.
- `class`, `subclass`, `protocol` - what the interface must be; -1
  for any.

**RESULT**

The interface's descriptor in the device's configuration, or null.

**BEHAVIOR**

Every setting of every interface is looked at, alternate settings
too, in the order the device sent them.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none; the device must not go meanwhile.
- Process: a Task will do.

**OWNERSHIP**

The descriptor stays the device's.

**BUGS**

None known.

**SEE ALSO**

`NextUSBDescriptor`, `FindUSBEndpoint`

**EXAMPLES**

```zig
const hid = ub.FindUSBInterface(device, null, d.USB_CLASS_HID, -1, -1) orelse return;
```

## GetUSBString

Reads one of a device's strings, as Latin-1.

**SYNOPSIS**

```zig
fn GetUSBString(base: *UsbBase, device: *usb.USBDevice, index: u32, buffer: [*]u8, size: u32) i32
```

**SINCE**

1.0. LVO -48.

**INPUTS**

- `device` - the device.
- `index` - the string's index, as a descriptor gives it (1 to 255).
- `buffer`, `size` - where it goes, NUL-ended; at least 1 byte.

**RESULT**

Its length, without the NUL; -1 if the device has no such string, did
not answer, or `size` is 0.

**BEHAVIOR**

The device is asked in the language it listed first. A character
Latin-1 has not is `?`; what does not fit is cut off.

**CONTEXT**

- Waits: yes, for the device to answer: a control transfer.
- Interrupts: no.
- Locks: none may be held; the device must not go meanwhile.
- Process: a Task will do.

**OWNERSHIP**

The buffer is the caller's.

**NOTES**

The device's manufacturer, product and serial number are read when it
is set up and kept in its `USBDevice`.

**BUGS**

None known.

**SEE ALSO**

`NextUSBDescriptor`

**EXAMPLES**

```zig
var name: [64]u8 = undefined;
if (ub.GetUSBString(device, interface.interface_string, &name, name.len) > 0) show(&name);
```

## NextUSBDescriptor

Finds the next descriptor of a kind in a device's configuration.

**SYNOPSIS**

```zig
fn NextUSBDescriptor(base: *UsbBase, device: *usb.USBDevice, previous: ?*const usb.DescriptorHeader, descriptor_type: u32) ?*const usb.DescriptorHeader
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `device` - a device on the list, or the one a driver was bound to.
- `previous` - a descriptor this call answered for the device, or null
  to start after the configuration's own.
- `descriptor_type` - `USB_DT_*`, or 0 for any.

**RESULT**

The descriptor, in the device's configuration as it came; null past
the last, or for a device with no configuration.

**BEHAVIOR**

The descriptors are walked by their lengths, as the device sent them:
an interface's endpoints and its class's own descriptors follow it.
A length that would run past the end ends the walk.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none; the device must not go meanwhile - hold the list, or
  be its driver.
- Process: a Task will do.

**OWNERSHIP**

The descriptor stays the device's: it lives as long as the device.

**NOTES**

A descriptor is not aligned: its fields wider than a byte are read
through the SDK's structures, whose fields are `align(1)`.

**BUGS**

None known.

**SEE ALSO**

`FindUSBInterface`, `FindUSBEndpoint`

**EXAMPLES**

```zig
var at = ub.NextUSBDescriptor(device, null, usb.descriptors.USB_DT_HID);
if (at) |hid| report_length = readReportLength(hid);
```

## ObtainUSBDeviceList

Takes the list of every device on every bus, for reading.

**SYNOPSIS**

```zig
fn ObtainUSBDeviceList(base: *UsbBase) *exec.List
```

**SINCE**

1.0. LVO -28.

**INPUTS**

None.

**RESULT**

The list: its nodes are `USBDevice`s, the root hubs among them, in
the order they were set up.

**BEHAVIOR**

The list is held shared: other readers read it too, and no device is
added or removed - a bus's process that has one to add or remove
waits - until ReleaseUSBDeviceList.

**CONTEXT**

- Waits: yes, while a bus's process changes the list.
- Interrupts: no.
- Locks: takes the list's semaphore, shared; no spinlock may be held.
- Process: a Task will do.

**OWNERSHIP**

The list and its devices stay the library's: read them, change
nothing, and keep nothing of them after ReleaseUSBDeviceList.

**NOTES**

Hold it briefly: a device plugged in meanwhile is not set up until it
is let go. A program that prints the list copies what it wants and
prints after.

**BUGS**

None known.

**SEE ALSO**

`ReleaseUSBDeviceList`, `AddUSBNotify`

**EXAMPLES**

```zig
const list = ub.ObtainUSBDeviceList();
var it = list.iterator();
while (it.next()) |node| {
    const device: *usb.USBDevice = @fieldParentPtr("node", node);
    count += 1;
    _ = device;
}
ub.ReleaseUSBDeviceList();
```

## OpenUSBPipe

Opens a pipe to one endpoint of a device: a request already filled in for it.

**SYNOPSIS**

```zig
fn OpenUSBPipe(base: *UsbBase, device: *usb.USBDevice, endpoint_address: u32, reply_port: *exec.MsgPort) ?*usb.USBPipe
```

**SINCE**

1.0. LVO -52.

**INPUTS**

- `device` - the device, which the caller drives (a binding, or a
  claimed interface).
- `endpoint_address` - the endpoint's bEndpointAddress, its number
  with `USB_DIR_IN` for one that sends; 0 for the control endpoint.
- `reply_port` - where the request is replied.

**RESULT**

The pipe, or null if the device has no such endpoint, it is an
isochronous one asking for packets more often than once a
millisecond, or there is no memory.

**BEHAVIOR**

The pipe's `io` is an `IOUsbHC` on the device's bus's controller, its
command set by the endpoint's type (`UHCMD_CONTROLXFER`,
`UHCMD_BULKXFER`, `UHCMD_INTXFER`, `UHCMD_ISOXFER`), the device's
address, speed and hub, the endpoint, its packet size and its interval
in milliseconds, its data toggle at DATA0. The caller sets io_Data and
io_Length - and a control pipe's setup packet, an isochronous pipe's
`iso_packet` if its packets are smaller than the endpoint's - and
sends it with SendIO or DoIO, as often as it likes; the toggle stays
in it.

An isochronous endpoint's interval is 2^(bInterval - 1) frames or, at
high speed, microframes; it is taken only at a millisecond or more,
which every endpoint of a full-speed device is.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The pipe is the caller's until CloseUSBPipe; nothing of it may be
outstanding then. When the device goes, its driver closes its pipes
in USBClassUnbind; a transfer outstanding meanwhile ends with
`UHIOERR_DETACHED` or another error.

**NOTES**

One request per pipe: two transfers at once on one endpoint want two
pipes, and then the toggle is not theirs to share. An isochronous
stream wants two or more, so the next is with the controller before
the last has played: each a pipe of its own on the endpoint (Since
1.6).

**BUGS**

None known.

**SEE ALSO**

`CloseUSBPipe`, `FindUSBEndpoint`, `ClearUSBStall`

**EXAMPLES**

```zig
const pipe = ub.OpenUSBPipe(device, in.endpoint_address, port) orelse return false;
pipe.io.std.data = &report;
pipe.io.std.length = report.len;
sys.SendIO(&pipe.io.std.req);
```

## ReleaseUSBDeviceList

Lets go of the list ObtainUSBDeviceList took.

**SYNOPSIS**

```zig
fn ReleaseUSBDeviceList(base: *UsbBase) void
```

**SINCE**

1.0. LVO -32.

**INPUTS**

None.

**RESULT**

Nothing.

**BEHAVIOR**

Once every reader has let go, the buses' processes may change the
list again.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: releases the list's semaphore, which the caller holds.
- Process: a Task will do; the same one that took it.

**OWNERSHIP**

Nothing of the list may be used after it.

**BUGS**

None known.

**SEE ALSO**

`ObtainUSBDeviceList`

**EXAMPLES**

```zig
_ = ub.ObtainUSBDeviceList();
defer ub.ReleaseUSBDeviceList();
```

## ReleaseUSBInterface

Gives back an interface ClaimUSBInterface took.

**SYNOPSIS**

```zig
fn ReleaseUSBInterface(base: *UsbBase, device: *usb.USBDevice, interface_number: u32) void
```

**SINCE**

1.0. LVO -72.

**INPUTS**

- `device` - the device.
- `interface_number` - the interface the program claimed.

**RESULT**

Nothing.

**BEHAVIOR**

The interface is free again; it is not offered to the class drivers
until the device is plugged in again.

**CONTEXT**

- Waits: yes, for the device list.
- Interrupts: no.
- Locks: takes the device list's semaphore; it may not be held.
- Process: a Task will do.

**OWNERSHIP**

The program's pipes to it are closed first.

**BUGS**

None known.

**SEE ALSO**

`ClaimUSBInterface`

**EXAMPLES**

```zig
ub.ReleaseUSBInterface(device, 0);
```

## RemUSBNotify

Ends what AddUSBNotify asked for.

**SYNOPSIS**

```zig
fn RemUSBNotify(base: *UsbBase, notify: ?*usb.USBNotify) void
```

**SINCE**

1.0. LVO -80.

**INPUTS**

- `notify` - from AddUSBNotify; null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

No signal is sent after it returns.

**CONTEXT**

- Waits: yes, for the notification list.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The handle is gone.

**BUGS**

None known.

**SEE ALSO**

`AddUSBNotify`

**EXAMPLES**

```zig
ub.RemUSBNotify(handle);
```

## StartUSB

Starts a bus: its controller opened, its root hub set up, and from then on whatever is plugged in.

**SYNOPSIS**

```zig
fn StartUSB(base: *UsbBase, bus: u32) i32
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `bus` - which bus, from 0: the board's USB sockets that may be a
  host (`PARTKIND_USB`, `USBROLE_HOST`), in the order its parts list
  them.

**RESULT**

0 when the bus runs (or already did); `USBERR_NOBUS` if the board has
no such bus, `USBERR_CONTROLLER` if its controller could not be
opened, `USBERR_NOMEM` without memory or a process.

**BEHAVIOR**

A process of the bus's own opens the controller and sets up its root
hub; this returns once the controller is open, without waiting for
what is plugged in to be set up - a device found later is set up as
it comes either way, and a program that waits for one uses
AddUSBNotify. A bus that runs is left as it is. The library stays
open while a bus runs.

**CONTEXT**

- Waits: yes, until the bus's process has opened the controller.
- Interrupts: no.
- Locks: takes the library's bus lock; none may be held.
- Process: a Task will do; the bus's own process is a dos process.

**OWNERSHIP**

The bus is the library's until StopUSB.

**NOTES**

The buses are the board's `PARTKIND_USB` parts that may be hosts,
each on the device that drives its chip (`CHIP_DWC2`:
usbotg.device; `CHIP_XHCI`: xhci.device).

**BUGS**

None known.

**SEE ALSO**

`StopUSB`, `ObtainUSBDeviceList`, `AddUSBNotify`

**EXAMPLES**

```zig
if (ub.StartUSB(0) != 0) return fail("no USB bus");
```

## StopUSB

Stops a bus: every device on it let go, its controller closed.

**SYNOPSIS**

```zig
fn StopUSB(base: *UsbBase, bus: u32) void
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `bus` - which bus, as StartUSB took it. One that does not run is
  left as it is.

**RESULT**

Nothing.

**BEHAVIOR**

The bus's process lets go of every device from the root down: a hub's
children before the hub, each interface's driver told with
USBClassUnbind, each device off the list. Then it closes the
controller - which stops it and unpowers its port - and ends.

**CONTEXT**

- Waits: yes, until the bus's process has ended.
- Interrupts: no.
- Locks: takes the library's bus lock; none may be held - nor the
  device list, which the process takes to change it.
- Process: a Task will do.

**OWNERSHIP**

The USBDevices of the bus are gone when this returns: nothing of them
may be kept.

**BUGS**

None known.

**SEE ALSO**

`StartUSB`

**EXAMPLES**

```zig
ub.StopUSB(0);
```
