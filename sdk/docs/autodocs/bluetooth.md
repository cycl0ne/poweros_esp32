# bluetooth.library

bluetooth.library's functions: the Bluetooth controllers, brought up
and run by the library's task, the devices they find, their links to
them and their bonds with them, and who is told when they change.
Open it with OpenLibrary("bluetooth.library", 1); the structures are
in sdk.bluetooth.

Generated from the source by `./zig build autodoc`.

## Index

- [AddBTAgent](#addbtagent) - Adds an agent: a port the library sends what a pairing needs to know, and what its user can do.
- [AddBTController](#addbtcontroller) - Offers a controller to the stack: the library's task opens the unit and brings the controller up.
- [AddBTNotify](#addbtnotify) - Asks for signals whenever a controller is added, comes up, fails or goes, is set otherwise, or finds a device.
- [ConnectBTDevice](#connectbtdevice) - Makes a link to a device - a page over BR/EDR, LE's initiating over LE - and waits until it is up.
- [DisconnectBTDevice](#disconnectbtdevice) - Ends a link to a device, and waits until it is down.
- [ObtainBTBonds](#obtainbtbonds) - Lists the bonds of a controller, or of every controller.
- [ObtainBTConnections](#obtainbtconnections) - Lists a controller's links to devices: a copy of each as it is at the moment of the call.
- [ObtainBTControllers](#obtainbtcontrollers) - Lists the controllers: a copy of each as it is at the moment of the call.
- [ObtainBTDevices](#obtainbtdevices) - Lists the devices a controller found: a copy of each as it is at the moment of the call.
- [PairBTDevice](#pairbtdevice) - Begins a pairing with a device over BR/EDR: a bond the two keep, which authenticates and encrypts their links from then on.
- [ReleaseBTBonds](#releasebtbonds) - Gives back a list from ObtainBTBonds.
- [ReleaseBTConnections](#releasebtconnections) - Gives back what ObtainBTConnections answered.
- [ReleaseBTControllers](#releasebtcontrollers) - Gives back what ObtainBTControllers answered.
- [ReleaseBTDevices](#releasebtdevices) - Gives back what ObtainBTDevices answered.
- [RemBTAgent](#rembtagent) - Ends what AddBTAgent began: the agent is asked nothing more.
- [RemBTController](#rembtcontroller) - Takes a controller from the stack: everything the library had out on the unit is taken back, the unit closed, and the controller gone from the list.
- [RemBTNotify](#rembtnotify) - Ends what AddBTNotify asked for.
- [SetBTControllerAttrs](#setbtcontrollerattrs) - Changes what a controller does: whether it is on, the name it shows others, whether they find it.
- [StartBTDiscovery](#startbtdiscovery) - Makes a controller look for the devices around it: LE's advertisers, then the BR/EDR devices that answer an inquiry, then the names not yet heard.
- [StopBTDiscovery](#stopbtdiscovery) - Ends a controller's discovery now.
- [UnpairBTDevice](#unpairbtdevice) - Ends a bond: the controller forgets the device's key.

## AddBTAgent

Adds an agent: a port the library sends what a pairing needs to know, and what its user can do.

**SYNOPSIS**

```zig
fn AddBTAgent(base: *BluetoothBase, port: *exec.MsgPort, capability: u32) ?*bluetooth.BTAgent
```

**SINCE**

1.4. LVO -88.

**INPUTS**

- `port` - where the BTAgentMessages go; the caller's.
- `capability` - BTIO_*: whether its user can see a number, answer
  yes or no, type a number. Any other value is BTIO_NOINPUTNOOUTPUT.

**RESULT**

A handle for PairBTDevice and RemBTAgent, or null without memory.

**BEHAVIOR**

The agent is asked about the pairings PairBTDevice begins with it,
and about every pairing a device begins while it is the agent added
last - without an agent, a device's pairing is refused. Each message
is the library's: for BTAK_CONFIRM the agent sets `accept` to 1 when
the device shows `number` (or, without one, when the device may
pair); for BTAK_PASSKEY `accept` and `passkey`; for BTAK_PIN `accept`,
`pin` and `pin_length`; then it replies the message (ReplyMsg).
BTAK_SHOW and BTAK_DONE only tell, and are replied at once. A question
not answered within 30 seconds is refused, its reply let go when it
comes.

**CONTEXT**

- Waits: yes, for the agents' list and the library's task.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The handle is the caller's until RemBTAgent; the port must be there
until then, and what comes to it replied.

**NOTES**

With BTIO_KEYBOARDDISPLAY, BR/EDR's pairings ask as for
BTIO_DISPLAYYESNO: they have no such capability.

**BUGS**

None known.

**SEE ALSO**

`RemBTAgent`, `PairBTDevice`

**EXAMPLES**

```zig
const port = sys.CreateMsgPort() orelse return;
const agent = bt.AddBTAgent(port, bluetooth.BTIO_DISPLAYYESNO) orelse return;
while (sys.GetMsg(port)) |message| {
    const asked: *bluetooth.BTAgentMessage = @fieldParentPtr("message", message);
    if (asked.kind == bluetooth.BTAK_CONFIRM) asked.accept = 1;
    sys.ReplyMsg(message);
}
```

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

A unit whose open answers HCIERR_NOTREADY - a controller on the board,
which its device is still setting up - is kept on the list unopened,
BTCS_OPENING, and the call answers its number: the device offers it
with this call once it is ready, and the task opens it then. A device
that could not set its controller up offers it all the same, its open
answering an error: the controller stays on the list, BTCS_FAILED with
BTERR_OPENFAIL, and the call answers BTERR_OPENFAIL. The library adds
the board's controllers itself, at its first open from a process:
every unit of a device that speaks DEVIF_HCI for a part of the board
(ObtainDeviceUnits).

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
the caller waits: they must not wait for the caller. A board device's
init runs there too, under the library's lock (the first Open adds
its controllers): it must not open the library itself - its own task
does, later.

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

Asks for signals whenever a controller is added, comes up, fails or goes, is set otherwise, or finds a device.

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

On every change of any controller the signals are sent: one added,
up, failed or gone; on or off, visible or not, its name; its discovery
begun or over, a device it found, a name it heard. They say that
something changed, not what; the task lists again, with
ObtainBTControllers and ObtainBTDevices. Changes close together may
come as one signal.

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

`RemBTNotify`, `ObtainBTControllers`, `ObtainBTDevices`

**EXAMPLES**

```zig
const signal = sys.AllocSignal(-1);
const handle = bt.AddBTNotify(sys.FindTask(null).?, @as(u32, 1) << @intCast(signal)) orelse return;
defer bt.RemBTNotify(handle);
```

## ConnectBTDevice

Makes a link to a device - a page over BR/EDR, LE's initiating over LE - and waits until it is up.

**SYNOPSIS**

```zig
fn ConnectBTDevice(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress) i32
```

**SINCE**

1.3. LVO -64.

**INPUTS**

- `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
  for the one that has a link to the device already, else the one
  whose discovery found it, else the first that is up and on.
- `address` - the device's: a BTADDR_BREDR address for a link over
  BR/EDR, an LE address (BTADDR_LE_PUBLIC, BTADDR_LE_RANDOM) for one
  over LE.

**RESULT**

0 once the link is up - at once for one that is up already.
Otherwise why it is not: the controller's status (hci.HCI_ERR_*,
positive) - HCI_ERR_PAGE_TIMEOUT for a device that did not answer its
page; HCI_ERR_LOCAL_HOST_TERMINATED when DisconnectBTDevice, or the
controller's power going off, took it back while it was being made -
or BTERR_TIMEOUT for an LE device that did not advertise within 20
seconds, BTERR_BUSY while the controller makes another link of the
kind or ends this one, BTERR_NOCONTROLLER, BTERR_NOTUP, BTERR_OFF,
BTERR_UNSUPPORTED for a controller without the kind of link, and
BTERR_NOMEM when it has no room for another (it keeps 8). For a device
with a bond, a link that is up but could not be made secure: the
controller's status - HCI_ERR_PIN_OR_KEY_MISSING when the device no
longer has the bond.

**BEHAVIOR**

A discovery the controller runs is stopped first. Over BR/EDR the
controller pages the device - by what its discovery heard of it in
the last minute, how often it listens for pages and its clock - and is
the link's central unless the device takes the role over; it gives up
after its page timeout, about five seconds. Over LE it listens for the
device's advertising and connects as its central. Calls that wait for
a link being made have it as it comes. A device that pages the
controller is taken on by itself: its link is listed as well.

The device's name, where the discovery did not hear it, is asked for
over a BR/EDR link once it is up. AddBTNotify's signal comes when the
link is up, and again when it is down.

Since 1.4, a BR/EDR link to a device the controller has a bond with
(PairBTDevice) is authenticated with the bond's key and encrypted
before the call returns; one that could not be stays up.

**CONTEXT**

- Waits: yes, until the link is up or not made.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing.

**NOTES**

A link carries no protocol of the library's yet: a device may end one
it has no use for.

**BUGS**

None known.

**SEE ALSO**

`DisconnectBTDevice`, `ObtainBTConnections`, `StartBTDiscovery`,
`PairBTDevice`

**EXAMPLES**

```zig
// 00:00:5E:EF:10:01, over BR/EDR.
const device = bluetooth.BTAddress{ .bytes = .{ 0x01, 0x10, 0xEF, 0x5E, 0x00, 0x00 } };
if (bt.ConnectBTDevice(bluetooth.BT_ALL_CONTROLLERS, &device) != 0) return;
```

## DisconnectBTDevice

Ends a link to a device, and waits until it is down.

**SYNOPSIS**

```zig
fn DisconnectBTDevice(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress) i32
```

**SINCE**

1.3. LVO -68.

**INPUTS**

- `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
  for the one that has the link.
- `address` - the device's, as the link has it (BTConnection.address):
  BTADDR_BREDR for a link over BR/EDR, its LE address for one over LE.

**RESULT**

0 once the link is down; BTERR_NOTCONNECTED for no link to the
device, BTERR_TIMEOUT when the controller did not say it ended within
ten seconds - the library takes it to be down all the same - the
controller's status (hci.HCI_ERR_*, positive) when it refused, and
BTERR_NOCONTROLLER, BTERR_NOTUP, BTERR_NOMEM.

**BEHAVIOR**

A link that is up is ended, the device told that the user ended it.
One being made is taken back, or ended as soon as it is up, and
ConnectBTDevice's call for it answered HCI_ERR_LOCAL_HOST_TERMINATED.
The data the link was sending goes with it. AddBTNotify's signal comes
once it is down.

**CONTEXT**

- Waits: yes, until the link is down.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing.

**NOTES**

A device ends a link as it likes; the list shows it gone then.

**BUGS**

None known.

**SEE ALSO**

`ConnectBTDevice`, `ObtainBTConnections`

**EXAMPLES**

```zig
_ = bt.DisconnectBTDevice(bluetooth.BT_ALL_CONTROLLERS, &link.address);
```

## ObtainBTBonds

Lists the bonds of a controller, or of every controller.

**SYNOPSIS**

```zig
fn ObtainBTBonds(base: *BluetoothBase, controller: u32) ?*exec.List
```

**SINCE**

1.4. LVO -96.

**INPUTS**

- `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS.

**RESULT**

A list of BTBond, empty for none; null without memory.

**BEHAVIOR**

Each bond the device's address, its name and class of device as they
were at its pairing, the kind of its key, and whether its pairing was
confirmed (BTBF_AUTHENTICATED), made with Secure Connections
(BTBF_SECURE) or with a PIN (BTBF_LEGACY). A controller's bonds are
there once it has read them, as it comes up.

**CONTEXT**

- Waits: yes, for the controllers' lock.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The list and its nodes are the caller's until ReleaseBTBonds; they do
not change.

**NOTES**

The keys are not listed.

**BUGS**

None known.

**SEE ALSO**

`ReleaseBTBonds`, `PairBTDevice`, `UnpairBTDevice`

**EXAMPLES**

```zig
const list = bt.ObtainBTBonds(bluetooth.BT_ALL_CONTROLLERS) orelse return;
defer bt.ReleaseBTBonds(list);
var it = list.iterator();
while (it.next()) |node| {
    const bond: *bluetooth.BTBond = @fieldParentPtr("node", node);
    _ = bond.address;
}
```

## ObtainBTConnections

Lists a controller's links to devices: a copy of each as it is at the moment of the call.

**SYNOPSIS**

```zig
fn ObtainBTConnections(base: *BluetoothBase, controller: u32) ?*exec.List
```

**SINCE**

1.3. LVO -72.

**INPUTS**

- `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
  for every controller's, one controller's after the other's.

**RESULT**

A list of `bluetooth.BTConnection` nodes - empty for no link or no
such controller - or null without memory.

**BEHAVIOR**

The links are those that are up - made by ConnectBTDevice, or by a
device that paged the controller - and those being ended: each with
the device's address, what sort of link it is (BTLF_*: since 1.4 also
whether it is authenticated, to a device with a bond, being paired),
the controller's handle for it, LE's parameters, how long it has been
up, and the device's name and class where they are known. A link
being made is not listed until it is up.

Each node is a copy, its name with it: nothing the library does later
reaches it.

**CONTEXT**

- Waits: yes, for the controllers' lock, which the task holds while it
  takes a packet.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The list and its nodes are the caller's, given back whole with
ReleaseBTConnections.

**NOTES**

A controller keeps up to 8 links.

**BUGS**

None known.

**SEE ALSO**

`ReleaseBTConnections`, `ConnectBTDevice`, `DisconnectBTDevice`,
`AddBTNotify`

**EXAMPLES**

```zig
const list = bt.ObtainBTConnections(bluetooth.BT_ALL_CONTROLLERS) orelse return;
defer bt.ReleaseBTConnections(list);
var it = list.iterator();
while (it.next()) |node| {
    const link: *bluetooth.BTConnection = @fieldParentPtr("node", node);
    _ = link.flags & bluetooth.BTLF_LE;
}
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

## ObtainBTDevices

Lists the devices a controller found: a copy of each as it is at the moment of the call.

**SYNOPSIS**

```zig
fn ObtainBTDevices(base: *BluetoothBase, controller: u32) ?*exec.List
```

**SINCE**

1.2. LVO -56.

**INPUTS**

- `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
  for every controller's, one controller's after the other's.

**RESULT**

A list of `bluetooth.BTDevice` nodes - empty when nothing was found or
there is no such controller - or null without memory.

**BEHAVIOR**

The devices are those of the controller's last discovery
(StartBTDiscovery), kept until its next begins: each with its address,
how it was heard (BTDF_*), its signal, and what it said of itself -
its name, class of device, services, appearance, maker - and how long
ago it was last heard. A device heard both ways, BR/EDR and LE from
the same public address, is one node. A discovery still running shows
what it has heard so far: a name may come later, and the list again
then has it.

Each node is a copy, its name with it: what it says does not change
after the call, and nothing the library does later reaches it.

**CONTEXT**

- Waits: yes, for the controllers' lock, which the task holds while it
  takes a packet.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The list and its nodes are the caller's, given back whole with
ReleaseBTDevices.

**NOTES**

A controller keeps up to 64 devices; when more are heard it keeps
those heard strongest.

**BUGS**

None known.

**SEE ALSO**

`ReleaseBTDevices`, `StartBTDiscovery`, `AddBTNotify`

**EXAMPLES**

```zig
const list = bt.ObtainBTDevices(0) orelse return;
defer bt.ReleaseBTDevices(list);
var it = list.iterator();
while (it.next()) |node| {
    const found: *bluetooth.BTDevice = @fieldParentPtr("node", node);
    _ = found.rssi;
}
```

## PairBTDevice

Begins a pairing with a device over BR/EDR: a bond the two keep, which authenticates and encrypts their links from then on.

**SYNOPSIS**

```zig
fn PairBTDevice(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress, agent: ?*bluetooth.BTAgent) i32
```

**SINCE**

1.4. LVO -80.

**INPUTS**

- `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
  for the one that has a link to the device already, else the one
  whose discovery found it, else the first that is up and on.
- `address` - the device's, a BTADDR_BREDR address.
- `agent` - from AddBTAgent: asked what the pairing needs to know, and
  told its end; null for a pairing that asks nobody.

**RESULT**

0 once the pairing has begun: its end comes to the agent. Otherwise
why it has not: BTERR_BONDED for a device the controller has a bond
with already, BTERR_BUSY while the device is being paired or its link
ended, BTERR_UNSUPPORTED for an LE address or a controller without
BR/EDR, BTERR_NOCONTROLLER, BTERR_NOTUP, BTERR_OFF, BTERR_NOMEM.

**BEHAVIOR**

A link to the device is made first where there is none, as
ConnectBTDevice makes one, and the pairing begins once it is up. With
Secure Simple Pairing the two say what their users can do, and the
agent is asked what that calls for: BTAK_CONFIRM, whether the device
shows the same number; BTAK_PASSKEY, the number the device shows;
BTAK_SHOW, a number to be typed on the device. A device without it
asks for a PIN: BTAK_PIN. Where there is nothing to compare - a side
that can show or type nothing - the pairing is confirmed by nobody
(Just Works), as it is without an agent. The link is then
authenticated and encrypted; an encryption key shorter than 7 bytes
ends it.

The end goes to the agent as BTAK_DONE, its `result` 0 for a bond
made - kept by the controller's address and the device's in
`ENVARC:Sys/bluetooth/` - or why not: the controller's status
(hci.HCI_ERR_AUTHENTICATION_FAILURE when the numbers did not match or
the device said no, HCI_ERR_PAGE_TIMEOUT for a device that did not
answer its page), BTERR_REFUSED when the agent said no or did not
answer within 30 seconds, BTERR_TIMEOUT for a pairing not over within
a minute, BTERR_NOMEM when the controller has its 32 bonds already.
AddBTNotify's signal comes when the bond is made.

**CONTEXT**

- Waits: yes, for the library's task - not for the pairing.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The agent stays the caller's; it is asked and told until BTAK_DONE,
or until RemBTAgent, which refuses the pairing.

**NOTES**

The link stays up after the pairing; DisconnectBTDevice ends it. A
pairing a device begins goes to the agent added last.

**BUGS**

LE devices are not paired yet.

**SEE ALSO**

`AddBTAgent`, `UnpairBTDevice`, `ObtainBTBonds`, `ConnectBTDevice`

**EXAMPLES**

```zig
const agent = bt.AddBTAgent(port, bluetooth.BTIO_DISPLAYYESNO) orelse return;
defer bt.RemBTAgent(agent);
if (bt.PairBTDevice(bluetooth.BT_ALL_CONTROLLERS, &device, agent) != 0) return;
// What comes to `port` answered and replied, until BTAK_DONE.
```

## ReleaseBTBonds

Gives back a list from ObtainBTBonds.

**SYNOPSIS**

```zig
fn ReleaseBTBonds(base: *BluetoothBase, list: ?*exec.List) void
```

**SINCE**

1.4. LVO -100.

**INPUTS**

- `list` - from ObtainBTBonds; null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The list and its nodes are freed.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The list is gone.

**BUGS**

None known.

**SEE ALSO**

`ObtainBTBonds`

**EXAMPLES**

```zig
bt.ReleaseBTBonds(list);
```

## ReleaseBTConnections

Gives back what ObtainBTConnections answered.

**SYNOPSIS**

```zig
fn ReleaseBTConnections(base: *BluetoothBase, list: ?*exec.List) void
```

**SINCE**

1.3. LVO -76.

**INPUTS**

- `list` - from ObtainBTConnections; null does nothing.

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

The list is gone, and so is every node and name it held.

**BUGS**

None known.

**SEE ALSO**

`ObtainBTConnections`

**EXAMPLES**

```zig
bt.ReleaseBTConnections(list);
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

## ReleaseBTDevices

Gives back what ObtainBTDevices answered.

**SYNOPSIS**

```zig
fn ReleaseBTDevices(base: *BluetoothBase, list: ?*exec.List) void
```

**SINCE**

1.2. LVO -60.

**INPUTS**

- `list` - from ObtainBTDevices; null does nothing.

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

The list is gone, and so is every node and name it held.

**BUGS**

None known.

**SEE ALSO**

`ObtainBTDevices`

**EXAMPLES**

```zig
bt.ReleaseBTDevices(list);
```

## RemBTAgent

Ends what AddBTAgent began: the agent is asked nothing more.

**SYNOPSIS**

```zig
fn RemBTAgent(base: *BluetoothBase, agent: ?*bluetooth.BTAgent) void
```

**SINCE**

1.4. LVO -92.

**INPUTS**

- `agent` - from AddBTAgent; null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

Nothing is sent to its port once the call returns. The pairings that
ask it are refused - the question it has not answered, and whatever
they would ask next - and their end is not told. The agent added
before it answers the devices' pairings again.

**CONTEXT**

- Waits: yes, for the agents' list and the library's task.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The handle is gone. What the agent was sent and has not replied is
still on its port, the library's: the caller replies it (GetMsg,
ReplyMsg) before the port goes, and the library lets it go.

**BUGS**

None known.

**SEE ALSO**

`AddBTAgent`

**EXAMPLES**

```zig
bt.RemBTAgent(agent);
while (sys.GetMsg(port)) |message| sys.ReplyMsg(message);
sys.DeleteMsgPort(port);
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

## SetBTControllerAttrs

Changes what a controller does: whether it is on, the name it shows others, whether they find it.

**SYNOPSIS**

```zig
fn SetBTControllerAttrs(base: *BluetoothBase, controller: u32, tags: ?[*]const utility.TagItem) i32
```

**SINCE**

1.2. LVO -44.

**INPUTS**

- `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
  for every controller that is up.
- `tags` - what is to change; a tag not given leaves its setting as
  it is:
  - `BTCA_Powered` (bool) - on, or off: off, it answers nobody and
    looks for nothing, and a discovery it runs is stopped.
  - `BTCA_Name` ([*:0]const u8) - the name it shows others, UTF-8, cut
    to 247 bytes (whole characters); an empty one, or null, gives it
    the machine's again (`ENVARC:Sys/net/hostname`, or "PowerOS").
  - `BTCA_Visible` (u32) - found by others who look, for that many
    seconds; 0 for not at all, BT_VISIBLE_ALWAYS until told otherwise.

**RESULT**

0 once it is done; BTERR_NOCONTROLLER for no such controller,
BTERR_NOTUP for one that is not up (or, with BT_ALL_CONTROLLERS, when
none is), BTERR_UNSUPPORTED for visible asked of a controller without
BR/EDR, BTERR_NOMEM when its commands could not be queued. With
BT_ALL_CONTROLLERS, the first failure of any.

**BEHAVIOR**

The controller is told at once: Write Scan Enable for on and visible -
pages answered while it is on, inquiries too while it is visible -
Write Local Name and its extended inquiry response for the name. The
call returns once the commands are queued, not when they are answered.

On, visible until told otherwise and the name are kept for the
controller's next start, by its address: in
`ENVARC:Sys/bluetooth/<address>/` (`settings`, `name`). Visible for a
time is not: it ends at its time, and a start ends it. Over LE the
controller is not seen at all: it does not advertise.

Whoever asked with AddBTNotify is told, and BTController's `flags`,
`visible_left` and `name` say what it does now.

**CONTEXT**

- Waits: yes, for the library's task, which writes the settings'
  files before it answers.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The tags and the name are the caller's: the name is copied.

**NOTES**

A controller without settings of its own is on and not visible.

**BUGS**

None known.

**SEE ALSO**

`ObtainBTControllers`, `StartBTDiscovery`, `AddBTNotify`

**EXAMPLES**

```zig
// Found by others for two minutes.
_ = bt.SetBTControllerAttrs(0, &[_]utility.TagItem{
    .{ .tag = bluetooth.BTCA_Visible, .data = 120 },
    .{},
});
```

## StartBTDiscovery

Makes a controller look for the devices around it: LE's advertisers, then the BR/EDR devices that answer an inquiry, then the names not yet heard.

**SYNOPSIS**

```zig
fn StartBTDiscovery(base: *BluetoothBase, controller: u32, seconds: u32) i32
```

**SINCE**

1.2. LVO -48.

**INPUTS**

- `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
  for every controller that is up and on.
- `seconds` - how long the first two parts take together, from 2 to
  60; 0 for about ten.

**RESULT**

0 once it looks; BTERR_NOCONTROLLER for no such controller,
BTERR_NOTUP for one that is not up (or, with BT_ALL_CONTROLLERS, when
none is), BTERR_OFF for one that is off (or, with BT_ALL_CONTROLLERS,
when every one that is up is), BTERR_UNSUPPORTED
for one that can neither scan LE's advertising nor inquire,
BTERR_NOMEM when its commands could not be queued. With
BT_ALL_CONTROLLERS, the first failure of any.

**BEHAVIOR**

The devices the controller found before are forgotten, and it looks
in three parts, one after the other:

- LE's advertising listened to, actively - every advertiser asked for
  its scan response, which often has its name - for a third of the
  time;
- an inquiry for the rest: the BR/EDR devices that are visible answer,
  with their signal and, from a controller that has extended results,
  their names and services;
- each BR/EDR device that has said no complete name asked for it, the
  strongest first, up to ten seconds each.

A controller without LE, or without BR/EDR, gives all of the time to
the part it has. Each device found, and each name, is in the list
ObtainBTDevices answers as soon as it is heard, and whoever asked with
AddBTNotify is told; BTCF_DISCOVERING is set on the controller until
the last part is over. A controller that looks already goes on as it
is.

**CONTEXT**

- Waits: yes, for the library's task.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing.

**NOTES**

Two controllers that look at the same time can miss each other: one
that inquires has little of its radio left for answering inquiries.
The names take longer where many devices have not said theirs.

**BUGS**

None known.

**SEE ALSO**

`StopBTDiscovery`, `ObtainBTDevices`, `AddBTNotify`

**EXAMPLES**

```zig
if (bt.StartBTDiscovery(0, 10) != 0) return;
// ... Wait for the notify's signal, then ObtainBTDevices(0).
```

## StopBTDiscovery

Ends a controller's discovery now.

**SYNOPSIS**

```zig
fn StopBTDiscovery(base: *BluetoothBase, controller: u32) void
```

**SINCE**

1.2. LVO -52.

**INPUTS**

- `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
  for every controller.

**RESULT**

Nothing.

**BEHAVIOR**

Whatever part of it runs is taken back from the controller - LE's
scan turned off, the inquiry cancelled, the name being asked for too
- and BTCF_DISCOVERING cleared; whoever asked with AddBTNotify is
told. The devices found stay in the list ObtainBTDevices answers. A
controller that does not look, or that is not there, is left as it
is.

**CONTEXT**

- Waits: yes, for the library's task.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing.

**BUGS**

None known.

**SEE ALSO**

`StartBTDiscovery`, `ObtainBTDevices`

**EXAMPLES**

```zig
bt.StopBTDiscovery(bluetooth.BT_ALL_CONTROLLERS);
```

## UnpairBTDevice

Ends a bond: the controller forgets the device's key.

**SYNOPSIS**

```zig
fn UnpairBTDevice(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress) i32
```

**SINCE**

1.4. LVO -84.

**INPUTS**

- `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
  for every controller with a bond with the device.
- `address` - the device's.

**RESULT**

0 once the bond is ended; BTERR_NOTBONDED for a controller - or, with
BT_ALL_CONTROLLERS, every controller - without one, BTERR_NOCONTROLLER.

**BEHAVIOR**

The key is forgotten and its file deleted before the call returns,
and a link to the device is ended. AddBTNotify's signal comes.

**CONTEXT**

- Waits: yes, for the library's task and the file's deletion.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing.

**NOTES**

The device keeps its side of the bond until it is told otherwise; it
cannot authenticate a link to the controller any more, and a pairing
with it begins afresh.

**BUGS**

None known.

**SEE ALSO**

`PairBTDevice`, `ObtainBTBonds`

**EXAMPLES**

```zig
_ = bt.UnpairBTDevice(bluetooth.BT_ALL_CONTROLLERS, &device);
```
