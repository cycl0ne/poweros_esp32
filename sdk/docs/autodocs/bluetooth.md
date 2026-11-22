# bluetooth.library

bluetooth.library's functions: the Bluetooth controllers, brought up
and run by the library's task, and who is told when they change. Open
it with OpenLibrary("bluetooth.library", 1); the structures are in
sdk.bluetooth.

Generated from the source by `./zig build autodoc`.

## Index

- [AddBTController](#addbtcontroller) - Offers a controller to the stack: the library's task opens the unit and brings the controller up.
- [AddBTNotify](#addbtnotify) - Asks for signals whenever a controller is added, comes up, fails or goes.
- [ObtainBTControllers](#obtainbtcontrollers) - Lists the controllers: a copy of each as it is at the moment of the call.
- [ReleaseBTControllers](#releasebtcontrollers) - Gives back what ObtainBTControllers answered.
- [RemBTController](#rembtcontroller) - Takes a controller from the stack: everything the library had out on the unit is taken back, the unit closed, and the controller gone from the list.
- [RemBTNotify](#rembtnotify) - Ends what AddBTNotify asked for.

## AddBTController

Offers a controller to the stack: the library's task opens the unit and brings the controller up.

**SYNOPSIS**

```zig
fn AddBTController(base: *BluetoothBase, device_name: [*:0]const u8, unit: u32) i32
```

**SINCE**

1.0. LVO -20.

**INPUTS**

- `device_name` - the device, as OpenDevice takes its name
  ("usb/bluetooth.device"); it speaks DEVIF_HCI.
- `unit` - the unit that is the controller.

**RESULT**

The controller's number (BTController.id), from 0; or BTERR_NOMEM
when there is no memory or the task cannot be started, BTERR_OPENFAIL
when the unit would not open.

**BEHAVIOR**

The task is started if it does not run. It opens the unit, asks the
device what it knows of the controller (HCICMD_QUERY), keeps reads
queued on it and begins the bring-up: the controller is reset and
asked what it is - its address, versions, features, commands, buffers
- then told which events to send, what it is (a desktop computer) and
what it is called (the machine's network name, `ENVARC:Sys/net/hostname`,
or "PowerOS"). The call returns once the unit is open; the bring-up
goes on, and whoever asked with AddBTNotify is told when the
controller is up or has failed. A controller already added answers
its own number.

**CONTEXT**

- Waits: yes, for the task.
- Interrupts: no.
- Locks: none may be held.
- Process: yes; the task is a process, and starting it needs one.

**OWNERSHIP**

The unit is the library's until RemBTController: the driver keeps
answering it, and nobody else opens it.

**NOTES**

The device's Open and BeginIO are called on the library's task while
the caller waits: they must not wait for the caller.

**BUGS**

None known.

**SEE ALSO**

`RemBTController`, `ObtainBTControllers`, `AddBTNotify`

**EXAMPLES**

```zig
const id = bt.AddBTController("usb/bluetooth.device", 0);
if (id < 0) return; // not taken
```

## AddBTNotify

Asks for signals whenever a controller is added, comes up, fails or goes.

**SYNOPSIS**

```zig
fn AddBTNotify(base: *BluetoothBase, task: *exec.Task, signals: u32) ?*bluetooth.BTNotify
```

**SINCE**

1.0. LVO -36.

**INPUTS**

- `task` - who is told, usually the caller.
- `signals` - the signals sent; allocated by the task.

**RESULT**

A handle for RemBTNotify, or null without memory.

**BEHAVIOR**

On every change of any controller the signals are sent. They say that
something changed, not what; the task lists the controllers again with
ObtainBTControllers. Changes close together may come as one signal.

**CONTEXT**

- Waits: yes, for the notification list.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The handle is the caller's until RemBTNotify, which it must call
before the task ends.

**BUGS**

None known.

**SEE ALSO**

`RemBTNotify`, `ObtainBTControllers`

**EXAMPLES**

```zig
const signal = sys.AllocSignal(-1);
const handle = bt.AddBTNotify(sys.FindTask(null).?, @as(u32, 1) << @intCast(signal)) orelse return;
defer bt.RemBTNotify(handle);
```

## ObtainBTControllers

Lists the controllers: a copy of each as it is at the moment of the call.

**SYNOPSIS**

```zig
fn ObtainBTControllers(base: *BluetoothBase) ?*exec.List
```

**SINCE**

1.0. LVO -28.

**INPUTS**

None.

**RESULT**

A list of `bluetooth.BTController` nodes in the order they were added
- empty when there is none - or null without memory.

**BEHAVIOR**

Each node is a copy, its strings with it: what it says does not change
after the call, and nothing the library does later reaches it. A
controller seen between two of its packets: a bring-up half done shows
what it has read so far.

**CONTEXT**

- Waits: yes, for the controllers' lock, which the task holds while it
  takes a packet.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The list and its nodes are the caller's, given back whole with
ReleaseBTControllers.

**BUGS**

None known.

**SEE ALSO**

`ReleaseBTControllers`, `AddBTNotify`

**EXAMPLES**

```zig
const list = bt.ObtainBTControllers() orelse return;
defer bt.ReleaseBTControllers(list);
var it = list.iterator();
while (it.next()) |node| {
    const controller: *bluetooth.BTController = @fieldParentPtr("node", node);
    _ = controller.address;
}
```

## ReleaseBTControllers

Gives back what ObtainBTControllers answered.

**SYNOPSIS**

```zig
fn ReleaseBTControllers(base: *BluetoothBase, list: ?*exec.List) void
```

**SINCE**

1.0. LVO -32.

**INPUTS**

- `list` - from ObtainBTControllers; null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The list and every node on it are freed in one.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The list is gone, and so is every node and string it held.

**BUGS**

None known.

**SEE ALSO**

`ObtainBTControllers`

**EXAMPLES**

```zig
bt.ReleaseBTControllers(list);
```

## RemBTController

Takes a controller from the stack: everything the library had out on the unit is taken back, the unit closed, and the controller gone from the list.

**SYNOPSIS**

```zig
fn RemBTController(base: *BluetoothBase, device_name: [*:0]const u8, unit: u32) void
```

**SINCE**

1.0. LVO -24.

**INPUTS**

- `device_name` - the device, as AddBTController was given it.
- `unit` - the unit.

**RESULT**

Nothing.

**BEHAVIOR**

The task aborts the reads and writes it has on the unit, waits for
them, and closes it; by the time the call returns, the device has no
request of the library's and its unit is closed. A controller not
added does nothing. The task ends with its last controller.

**CONTEXT**

- Waits: yes, for the task, which waits for the device to answer what
  it takes back.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The unit is the driver's again.

**NOTES**

The device's AbortIO and Close are called on the library's task while
the caller waits: they must not wait for the caller. A request being
sent when it is taken back must still be answered.

**BUGS**

None known.

**SEE ALSO**

`AddBTController`

**EXAMPLES**

```zig
bt.RemBTController("usb/bluetooth.device", 0);
```

## RemBTNotify

Ends what AddBTNotify asked for.

**SYNOPSIS**

```zig
fn RemBTNotify(base: *BluetoothBase, notify: ?*bluetooth.BTNotify) void
```

**SINCE**

1.0. LVO -40.

**INPUTS**

- `notify` - from AddBTNotify; null does nothing.

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

`AddBTNotify`

**EXAMPLES**

```zig
bt.RemBTNotify(handle);
```
