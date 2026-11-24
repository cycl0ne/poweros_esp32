# bluetooth.library

bluetooth.library's functions: the Bluetooth controllers, brought up
and run by the library's task, the devices they find, their links to
them and their bonds with them, the channels to the devices' protocols
and the services they offer, and who is told when they change.
Open it with OpenLibrary("bluetooth.library", 1); the structures are
in sdk.bluetooth.

Generated from the source by `./zig build autodoc`.

## Index

- [AddBTAgent](#addbtagent) - Adds an agent: a port the library sends what a pairing needs to know, and what its user can do.
- [AddBTController](#addbtcontroller) - Offers a controller to the stack: the library's task opens the unit and brings the controller up.
- [AddBTListener](#addbtlistener) - Serves a PSM: the channels devices open to it are taken, and come to a port.
- [AddBTNotify](#addbtnotify) - Asks for signals whenever a controller is added, comes up, fails or goes, is set otherwise, finds a device, or a link, a pairing or a bond begins or ends.
- [AddBTService](#addbtservice) - Serves a record of the program's own: the SDP server answers devices with it beside its own.
- [AttemptSendBTChannel](#attemptsendbtchannel) - Sends a frame on a channel to the device's protocol where its link's share of the controller's queue has room for it now, and answers at once where it has none.
- [BTDeviceKind](#btdevicekind) - Says what a device is, as one of the kinds programs name.
- [CloseBTChannel](#closebtchannel) - Closes a channel - one OpenBTChannel opened or StartBTChannel began, or one a device opened to a listener - and gives it back.
- [CloseBTGatt](#closebtgatt) - Closes a block OpenBTGatt opened, and gives it back.
- [ConnectBTDevice](#connectbtdevice) - Makes a link to a device - a page over BR/EDR, LE's initiating over LE - and waits until it is up.
- [DisconnectBTDevice](#disconnectbtdevice) - Ends a link to a device, and waits until it is down.
- [FindBTServiceAttribute](#findbtserviceattribute) - Reads the value of one of a record's attributes.
- [NextBTDataElement](#nextbtdataelement) - Reads the data element some bytes begin with.
- [ObtainBTBonds](#obtainbtbonds) - Lists the bonds of a controller, or of every controller.
- [ObtainBTCharacteristics](#obtainbtcharacteristics) - Asks a device which characteristics a service of its GATT server has, with their descriptors, and lists them.
- [ObtainBTConnections](#obtainbtconnections) - Lists a controller's links to devices: a copy of each as it is at the moment of the call.
- [ObtainBTControllers](#obtainbtcontrollers) - Lists the controllers: a copy of each as it is at the moment of the call.
- [ObtainBTDevices](#obtainbtdevices) - Lists the devices a controller found: a copy of each as it is at the moment of the call.
- [ObtainBTServices](#obtainbtservices) - Asks a device which services it offers - its SDP server over BR/EDR, its GATT server over LE - and lists them.
- [OpenBTChannel](#openbtchannel) - Opens an L2CAP channel to a protocol of a device, named by its PSM, and waits until it is open.
- [OpenBTGatt](#openbtgatt) - Opens the attribute protocol to an LE device, as GATT's client, and waits until it is open - or opens a block that waits for the device.
- [PairBTDevice](#pairbtdevice) - Begins a pairing with a device, over BR/EDR or LE: a bond the two keep, which authenticates and encrypts their links from then on.
- [ReadBTAttribute](#readbtattribute) - Reads the value of an attribute of a device's GATT server - a characteristic's (BTCharacteristic.value_handle), a descriptor's.
- [ReleaseBTBonds](#releasebtbonds) - Gives back a list from ObtainBTBonds.
- [ReleaseBTCharacteristics](#releasebtcharacteristics) - Gives back a list from ObtainBTCharacteristics.
- [ReleaseBTConnections](#releasebtconnections) - Gives back what ObtainBTConnections answered.
- [ReleaseBTControllers](#releasebtcontrollers) - Gives back what ObtainBTControllers answered.
- [ReleaseBTDevices](#releasebtdevices) - Gives back what ObtainBTDevices answered.
- [ReleaseBTServices](#releasebtservices) - Gives back a list from ObtainBTServices.
- [RemBTAgent](#rembtagent) - Ends what AddBTAgent began: the agent is asked nothing more.
- [RemBTController](#rembtcontroller) - Takes a controller from the stack: everything the library had out on the unit is taken back, the unit closed, and the controller gone from the list.
- [RemBTListener](#rembtlistener) - Ends what AddBTListener began: devices' channels to its PSM are refused again.
- [RemBTNotify](#rembtnotify) - Ends what AddBTNotify asked for.
- [RemBTService](#rembtservice) - Gives back a record AddBTService served.
- [SendBTChannel](#sendbtchannel) - Sends a frame on a channel to the device's protocol.
- [SetBTControllerAttrs](#setbtcontrollerattrs) - Changes what a controller does: whether it is on, the name it shows others, whether they find it.
- [StartBTChannel](#startbtchannel) - Begins opening an L2CAP channel to a protocol of a device, named by its PSM, and returns without waiting for it: the port is told once it is open, or why it is not.
- [StartBTDiscovery](#startbtdiscovery) - Makes a controller look for the devices around it: LE's advertisers, then the BR/EDR devices that answer an inquiry, then the names not yet heard.
- [StopBTDiscovery](#stopbtdiscovery) - Ends a controller's discovery now.
- [SubscribeBTAttribute](#subscribebtattribute) - Has a device send a characteristic's value to the block as it changes.
- [UnpairBTDevice](#unpairbtdevice) - Ends a bond: the controller forgets the device's key.
- [UnsubscribeBTAttribute](#unsubscribebtattribute) - Ends a block's subscription to a characteristic's value.
- [WriteBTAttribute](#writebtattribute) - Writes the value of an attribute of a device's GATT server.

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
BTIO_DISPLAYYESNO: they have no such capability; LE's have it.

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
asked what it is - its address, versions, features, commands, buffers -
then told which events to send, what it is (a desktop computer) and
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

## AddBTListener

Serves a PSM: the channels devices open to it are taken, and come to a port.

**SYNOPSIS**

```zig
fn AddBTListener(base: *BluetoothBase, psm: u32, port: *exec.MsgPort,
    flags: u32) ?*bluetooth.BTListener
```

**SINCE**

1.7. LVO -116.

**INPUTS**

- `psm` - the protocol's: odd, the low bit of its upper byte clear;
  one of l2cap.PSM_DYNAMIC_FIRST's and above for one of the program's
  own. Not l2cap.PSM_SDP, which the library serves.
- `port` - where the channels come, and their messages.
- `flags` - BTLSF_SECURE: a channel only over a link made secure with
  a bond; 0 for any link.

**RESULT**

A handle for RemBTListener; null without memory, for a PSM another
listener serves, PSM_SDP, or one no channel can name.

**BEHAVIOR**

A device that opens a channel to the PSM, over a BR/EDR link of any
controller, has it taken. Once its configuration is agreed - as
OpenBTChannel's is - the channel comes to `port` as a BTCM_OPENED
message, `channel` its block, BTCHF_INCOMING in its flags; its frames
and its end come to the same port as an opened channel's do. A device
that opens one to a PSM nobody serves is told there is no such
protocol.

With BTLSF_SECURE a channel is taken only over a link that is
encrypted after an authentication with the key of the bond the two
have. A device with a bond whose link is not so yet is told to wait
while the library makes it so - or the device does - and its channel
is taken once it is; a device without a bond, a link that cannot be
made secure, and one that is not so within a minute are refused for
their security. A device's keys and moves, say, then come only from
a device paired with.

**CONTEXT**

- Waits: yes, for the listeners' list.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The handle is the caller's until RemBTListener; the port must be
there until then. A channel that comes is the port's task's - given to
it - until CloseBTChannel, whether the listener is still there or not.

**NOTES**

The link a device opens a channel over is the device's: it stays when
the channel closes. `flags` since 1.9.

**BUGS**

None known.

**SEE ALSO**

`RemBTListener`, `OpenBTChannel`, `CloseBTChannel`

**EXAMPLES**

```zig
const listener = bt.AddBTListener(0x1001, port, 0) orelse return;
defer bt.RemBTListener(listener);
```

## AddBTNotify

Asks for signals whenever a controller is added, comes up, fails or goes, is set otherwise, finds a device, or a link, a pairing or a bond begins or ends.

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
begun or over, a device it found, a name it heard; a link being made,
up, failed or ended; a pairing begun or over - with a bond made or
not - and a bond forgotten. They say that something changed, not what; the task lists
again, with ObtainBTControllers, ObtainBTDevices, ObtainBTConnections
and ObtainBTBonds. Changes close together may come as one signal.

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

`RemBTNotify`, `ObtainBTControllers`, `ObtainBTDevices`,
`ObtainBTConnections`, `ObtainBTBonds`

**EXAMPLES**

```zig
const signal = sys.AllocSignal(-1);
const handle = bt.AddBTNotify(sys.FindTask(null).?, @as(u32, 1) << @intCast(signal)) orelse return;
defer bt.RemBTNotify(handle);
```

## AddBTService

Serves a record of the program's own: the SDP server answers devices with it beside its own.

**SYNOPSIS**

```zig
fn AddBTService(base: *BluetoothBase, record: [*]const u8, length: u32) ?*bluetooth.BTRecord
```

**SINCE**

1.9. LVO -172.

**INPUTS**

- `record`, `length` - the record: a sequence of attribute ids, each
  a 16-bit unsigned integer followed by its value, the ids rising
  (sdk.bluetooth.sdp) - the service's classes, its protocols, its
  profile and what the profile adds.

**RESULT**

The record, for RemBTService; null for no memory, for bytes that are
not a record whole, and for a record of more than 2048 bytes as it is
served.

**BEHAVIOR**

The record is copied and given a handle of its own - from
sdp.SDP_HANDLE_FIRST on, never one another record has - as its
attribute 0x0000, in place of any the bytes name. Until RemBTService
the SDP server answers every controller's devices with it, after its
own record and those added before it: a device's search finds it by
the UUIDs it holds, and its attributes are read in the parts the
device asks for.

**CONTEXT**

- Waits: yes, for the records' list.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The bytes stay the caller's: the record served is a copy, the
library's. The handle is the caller's until RemBTService, which gives
it back before the library is closed.

**NOTES**

A record says what a service is and where it is reached; its PSMs are
served with AddBTListener. Answers hold 4 KiB of records' attributes
at most: a device's search that asks for more is told the server has
no room.

**BUGS**

The server's record says its database's state is 1, always: a device
that keeps what it read by that state does not see records added or
given back.

**SEE ALSO**

`RemBTService`, `AddBTListener`, `ObtainBTServices`

**EXAMPLES**

```zig
// A service of the class 0x1101, reached over L2CAP's PSM 0x1001.
const record = [_]u8{
    0x35, 0x15,
    0x09, 0x00, 0x01, 0x35, 0x03, 0x19, 0x11, 0x01,
    0x09, 0x00, 0x04, 0x35, 0x08, 0x35, 0x06, 0x19, 0x01, 0x00, 0x09, 0x10, 0x01,
};
const served = bt.AddBTService(&record, record.len) orelse return;
defer bt.RemBTService(served);
```

## AttemptSendBTChannel

Sends a frame on a channel to the device's protocol where its link's share of the controller's queue has room for it now, and answers at once where it has none.

**SYNOPSIS**

```zig
fn AttemptSendBTChannel(base: *BluetoothBase, channel: *bluetooth.BTChannel, data: [*]const u8, length: u32) i32
```

**SINCE**

1.14. LVO -188.

**INPUTS**

- `channel` - an open one, from OpenBTChannel or a BTCM_OPENED
  message.
- `data`, `length` - the frame: as long as the device takes at the
  most (BTChannel.mtu_out), an empty one too.

**RESULT**

0 once the frame is in the controller's queue. BTERR_BUSY where it
would have to wait for room, and the frame is not sent. Otherwise
BTERR_TOOLONG for a frame longer than the device takes, or
BTERR_NOTCONNECTED for a channel that is closed.

**BEHAVIOR**

The frame is copied into the controller's queue where its link's
share of the queue has room and no frame SendBTChannel waits to queue
to the same device is before it - a device's frames go in the order
they are queued, the channel's and its other channels'. Otherwise
nothing is sent, and the caller decides: a stream lets the frame go
and keeps its time, a protocol sends it again later or with
SendBTChannel. A link's share fills where the controller sends to the
device more slowly than frames come - a link far off or busy, the
radio scanning, paging or pairing, a device gone until its link is
lost - and empties as it catches up; other devices' frames do not
fill it.

**CONTEXT**

- Waits: only for the library's task to take the call, not for room.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The data is the caller's again once the call returns.

**NOTES**

In the queue is not at the device: a frame queued when the link goes
down is lost, and nothing says it was.

**BUGS**

None known.

**SEE ALSO**

`SendBTChannel`, `StartBTChannel`, `OpenBTChannel`

**EXAMPLES**

```zig
// A packet of a stream: one that finds no room is let go of, and the
// stream keeps its time.
if (bt.AttemptSendBTChannel(channel, packet.ptr, @intCast(packet.len)) != 0) lost += 1;
```

## BTDeviceKind

Says what a device is, as one of the kinds programs name.

**SYNOPSIS**

```zig
fn BTDeviceKind(base: *BluetoothBase, class_of_device: u32, appearance: u32) u32
```

**SINCE**

1.11. LVO -180.

**INPUTS**

- `class_of_device` - BTDevice.class_of_device, BTBond's or
  BTConnection's: the major and minor class in its low 13 bits; 0 for
  none.
- `appearance` - BTDevice.appearance: an LE device's category in its
  bits 6 to 15, the subcategory below; 0 for none.

**RESULT**

BTDK_*: what the device is; BTDK_NONE where it says neither.

**BEHAVIOR**

The class of device is read first: its major class, and where that
tells kinds apart, its minor class - a laptop from a computer,
headphones from a headset, a keyboard from a mouse or both in one, a
gamepad from a joystick. A class that names no kind (miscellaneous,
uncategorized) leaves the appearance to say it: its subcategory where
it names a kind (a keyboard, a mouse, earbuds), else its category. A
class or a category this library does not know is BTDK_NONE, and so
are both 0.

**CONTEXT**

- Waits: no.
- Interrupts: yes - it reads nothing but its inputs.
- Locks: any may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing is handed over.

**NOTES**

A kind is a number, for the program to name in its own words and
language. A kind past the ones a program names is shown as it shows
BTDK_NONE; BTDK_LAST is the highest there is.

**BUGS**

None known.

**SEE ALSO**

`ObtainBTDevices`, `ObtainBTBonds`, `ObtainBTConnections`

**EXAMPLES**

```zig
const kind = bt.BTDeviceKind(found.class_of_device, found.appearance);
if (kind == bluetooth.BTDK_KEYBOARD) ... ;
```

## CloseBTChannel

Closes a channel - one OpenBTChannel opened or StartBTChannel began, or one a device opened to a listener - and gives it back.

**SYNOPSIS**

```zig
fn CloseBTChannel(base: *BluetoothBase, channel: ?*bluetooth.BTChannel) void
```

**SINCE**

1.7. LVO -108.

**INPUTS**

- `channel` - from OpenBTChannel, StartBTChannel or a BTCM_OPENED
  message, closed already or not; null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

A channel that is open is closed: the device is asked to close it, and
the call returns without waiting for its answer. A channel closed
already - by the device, with its link or its controller - is only
given back. One that StartBTChannel began and is not open yet is given
up: a device that takes it after is told it is closed. Either way
nothing about it is on its port once the call returns: the messages
about it the caller has not taken (GetMsg) are taken back, and no more
come.

**CONTEXT**

- Waits: only for the library's task to take the call, not for the
  device.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The channel is gone, and the messages about it that were taken back.
One the caller took before the call is still replied, without reading
its `channel`, whose block is gone with the channel.

**NOTES**

The device answers after the call has returned. Until it does - five
seconds at the most - its link counts the channel as its own: a link
made for the channel ends two seconds after that.

**BUGS**

None known.

**SEE ALSO**

`OpenBTChannel`, `StartBTChannel`, `AddBTListener`

**EXAMPLES**

```zig
sys.ReplyMsg(&told.message); // a BTCM_CLOSED, read first
bt.CloseBTChannel(channel);
```

## CloseBTGatt

Closes a block OpenBTGatt opened, and gives it back.

**SYNOPSIS**

```zig
fn CloseBTGatt(base: *BluetoothBase, gatt: ?*bluetooth.BTGatt) void
```

**SINCE**

1.8. LVO -136.

**INPUTS**

- `gatt` - from OpenBTGatt, closed already or not; null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The block's subscriptions end: the device is told to send no more of
each value that no other block on the link wants, its answer not
waited for. A link made for GATT ends two seconds after nothing is
left on it. Either way nothing about the block is on its port once
the call returns: the messages about it the caller has not taken
(GetMsg) are taken back, and no more come.

**CONTEXT**

- Waits: for the library's task, not for the device.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The block is gone, and the messages about it that were taken back.
One the caller took before the call is still replied, without reading
its `gatt`, whose block is gone.

**BUGS**

None known.

**SEE ALSO**

`OpenBTGatt`, `UnsubscribeBTAttribute`

**EXAMPLES**

```zig
sys.ReplyMsg(&told.message); // a BTGM_CLOSED, read first
bt.CloseBTGatt(gatt);
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
page, HCI_ERR_FAILED_TO_ESTABLISH for an LE device that never
answered on the link; HCI_ERR_LOCAL_HOST_TERMINATED when
DisconnectBTDevice, or the controller's power going off, took it back
while it was being made - or BTERR_TIMEOUT for an LE device that did
not advertise within 20 seconds, BTERR_BUSY while the controller
makes another link of the kind or ends this one, BTERR_NOCONTROLLER,
BTERR_NOTUP, BTERR_OFF, BTERR_UNSUPPORTED for a controller without
the kind of link, and BTERR_NOMEM when it has no room for another (it
keeps 8). For a device
with a bond, a link that is up but could not be made secure: the
controller's status - HCI_ERR_PIN_OR_KEY_MISSING when the device no
longer has the bond.

**BEHAVIOR**

A discovery the controller runs is stopped first. Over BR/EDR the
controller pages the device - by what its discovery heard of it in
the last minute, how often it listens for pages and its clock - and is
the link's central unless the device takes the role over; it gives up
after its page timeout, about five seconds. Over LE it listens for the
device's advertising and connects as its central; since 1.6 the link
is up once the device has answered on it - its features read - and
one the device never answers on is given up after six connection
events. Calls that wait for a link being made have it as it comes. A
device that pages the controller is taken on by itself: its link is
listed as well.

The device's name, where the discovery did not hear it, is asked for
over a BR/EDR link once it is up. AddBTNotify's signal comes when the
link is up, and again when it is down.

Since 1.4, a BR/EDR link to a device the controller has a bond with
(PairBTDevice) is authenticated with the bond's key and encrypted
before the call returns; one that could not be stays up. Since 1.5 an
LE link to one is encrypted with the bond's long term key the same
way - the device found by its address, or by the identity resolving
key that made the private address it uses.

**CONTEXT**

- Waits: yes, until the link is up or not made.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing.

**NOTES**

A device may end a link that carries nothing it has a use for - some
do, seconds after its last channel. The links OpenBTChannel,
ObtainBTServices and OpenBTGatt make end two seconds after their last
channel, block and request; one this call asks for meanwhile stays.

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

## FindBTServiceAttribute

Reads the value of one of a record's attributes.

**SYNOPSIS**

```zig
fn FindBTServiceAttribute(base: *BluetoothBase, record: [*]const u8,
    length: u32, id: u32, element: *bluetooth.BTDataElement) bool
```

**SINCE**

1.9. LVO -168.

**INPUTS**

- `record`, `length` - a record: a sequence of attribute ids each
  followed by its value (BTService.record and record_length).
- `id` - the attribute (sdp.ATTR_*, or a profile's own).
- `element` - filled in with its value.

**RESULT**

True with `element` filled in; false where the record has no such
attribute, or the bytes are not a record - `element` then left as it
was.

**BEHAVIOR**

The record's attributes are read in turn until the one with the id;
its value is described in `element` as NextBTDataElement describes an
element. Nothing is read past `length`.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

`element.data` points into the record; nothing is allocated.

**BUGS**

None known.

**SEE ALSO**

`NextBTDataElement`, `ObtainBTServices`

**EXAMPLES**

```zig
var name: bluetooth.BTDataElement = .{};
if (bt.FindBTServiceAttribute(service.record.?, service.record_length, sdp.ATTR_SERVICE_NAME, &name) and name.kind == sdp.DE_TEXT) {
    _ = dos.Write(output, name.data.?, name.length);
}
```

## NextBTDataElement

Reads the data element some bytes begin with.

**SYNOPSIS**

```zig
fn NextBTDataElement(base: *BluetoothBase, data: [*]const u8, length: u32,
    element: *bluetooth.BTDataElement) bool
```

**SINCE**

1.9. LVO -164.

**INPUTS**

- `data`, `length` - the bytes: a record (BTService.record), an
  attribute's value, a sequence's data, or what is left of it.
- `element` - filled in.

**RESULT**

True with `element` filled in; false where the bytes do not begin with
a data element whole - nothing read past `length` - `element` then
left as it was.

**BEHAVIOR**

`kind` is the element's type (sdp.DE_*); `data` and `length` its data
past its descriptor and its length, within the bytes given; `whole`
the bytes it takes in all, so that the next element begins `whole` on.
An unsigned integer's or a boolean's value of up to 8 bytes is in
`value`, a signed integer's with its sign kept (`@bitCast` to `i64`);
a UUID of 16, 32 or 128 bits is in `uuid` as 128 bits, the shorter
ones on the base UUID. A sequence's or an alternative's elements are
read by calling again on its `data`, from one element to the next.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

`element.data` points into the bytes given; nothing is allocated.

**NOTES**

What a profile reads of a device's record that ObtainBTServices does
not: a HID device's descriptor (sdk.bluetooth.sdp), an audio sink's
features.

**BUGS**

None known.

**SEE ALSO**

`FindBTServiceAttribute`, `ObtainBTServices`

**EXAMPLES**

```zig
// The elements of a sequence, one after the other.
var list: bluetooth.BTDataElement = .{};
if (!bt.FindBTServiceAttribute(service.record.?, service.record_length, sdp.ATTR_PROFILE_DESCRIPTOR_LIST, &list)) return;
var at: u32 = 0;
var item: bluetooth.BTDataElement = .{};
while (at < list.length and bt.NextBTDataElement(list.data.? + at, list.length - at, &item)) : (at += item.whole) {
    // item.kind, item.value, item.uuid
}
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
were at its pairing, the kind of its key and its size, and whether its
pairing was confirmed (BTBF_AUTHENTICATED), made with Secure
Connections (BTBF_SECURE) or with a PIN (BTBF_LEGACY). An LE bond's
address is an LE one - the device's identity where it gave it, with
the key that resolves its private addresses (BTBF_IDENTITY) - its key
kind 0. Since 1.9 each names the profile drivers its device's services
are bound to (BTBond.drivers). A controller's bonds are there once it
has read them, as it comes up.

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

## ObtainBTCharacteristics

Asks a device which characteristics a service of its GATT server has, with their descriptors, and lists them.

**SYNOPSIS**

```zig
fn ObtainBTCharacteristics(base: *BluetoothBase, gatt: *bluetooth.BTGatt,
    service: *const bluetooth.BTService, list: *?*exec.List) i32
```

**SINCE**

1.8. LVO -140.

**INPUTS**

- `gatt` - an open block to the device.
- `service` - one of the device's GATT services, as ObtainBTServices
  lists them (BTSF_GATT).
- `list` - set to the list of BTCharacteristic once the device has
  answered; null otherwise.

**RESULT**

0 once the device has answered - the list empty for a service without
characteristics. Otherwise why not: BTERR_UNSUPPORTED for a service
that is not a GATT service of the block's device, BTERR_NOTCONNECTED
for a block that is closed, BTERR_PROTOCOL for an answer that is not
well made, BTERR_NOMEM for more than 16 KiB of them or without memory,
BTERR_TIMEOUT for a device that did not answer within 30 seconds,
BTERR_ATT less the device's reason for a request it refused; for a
link down meanwhile, its reason.

**BEHAVIOR**

The characteristics' declarations within the service are read (Read
By Type), then the handles between each one's value and the next
declaration (Find Information): its descriptors. Each characteristic
is a BTCharacteristic: its UUID, its properties - what may be done
with its value - the handles of its declaration, its value and its
last, its descriptors in handle order, and among them its Client
Characteristic Configuration's handle, which SubscribeBTAttribute
writes. The list is in handle order.

**CONTEXT**

- Waits: yes, until the device has answered or not.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The list is the caller's - made in its context - until
ReleaseBTCharacteristics, the descriptors with it.

**BUGS**

None known.

**SEE ALSO**

`ReleaseBTCharacteristics`, `ObtainBTServices`, `ReadBTAttribute`,
`SubscribeBTAttribute`

**EXAMPLES**

```zig
var characteristics: ?*exec.List = null;
if (bt.ObtainBTCharacteristics(gatt, service, &characteristics) != 0) return;
defer bt.ReleaseBTCharacteristics(characteristics);
var it = characteristics.?.iterator();
while (it.next()) |node| {
    const characteristic: *bluetooth.BTCharacteristic = @fieldParentPtr("node", node);
    // The battery's level, sent as it changes.
    if (characteristic.uuid16 == 0x2A19) _ = bt.SubscribeBTAttribute(gatt, characteristic, 0);
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
being made is not listed until it is up - over LE, since 1.6, until
the device has answered on it.

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

A list of `bluetooth.BTController` nodes in the order they were added -
empty when there is none - or null without memory.

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

## ObtainBTServices

Asks a device which services it offers - its SDP server over BR/EDR, its GATT server over LE - and lists them.

**SYNOPSIS**

```zig
fn ObtainBTServices(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress,
    list: *?*exec.List) i32
```

**SINCE**

1.7. LVO -124.

**INPUTS**

- `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
  for the one with a link to the device, else the one whose discovery
  found it, else the first that is up and on.
- `address` - the device's: a BTADDR_BREDR address for its SDP
  records, an LE one for its GATT services.
- `list` - set to the list of BTService once the device has answered;
  null otherwise.

**RESULT**

0 once the device has answered - its list empty where it offers
nothing. Otherwise why not: BTERR_BUSY while the controller asks
another device over BR/EDR, BTERR_PROTOCOL for an answer that is not
well made or the device's error, BTERR_NOMEM for one past 32 KiB or
without memory, BTERR_TIMEOUT for a device that does not answer within
10 seconds - 30 over LE - BTERR_ATT less the device's reason for a
request of GATT's it refused; what OpenBTChannel answers for a channel
to its SDP server that could not be opened, what OpenBTGatt answers for
an LE link that could not be made.

**BEHAVIOR**

A channel is opened to the device's SDP server (l2cap.PSM_SDP) - its
link made where there is none, which ends two seconds after the
channel unless ConnectBTDevice asks for it meanwhile - and every
service record that names L2CAP asked for with all its attributes, in
as many parts as the device sends; the channel is closed once the
answer is whole. Each record is a BTService: what it is - its class,
and its profile with the profile's version - the PSM and RFCOMM
channel it is reached on, its name and its handle, and the record
itself, from which a profile reads attributes of its own (sdp.zig).

Over LE the device's GATT server is asked for its primary services
(Read By Group Type), from the first handle to the last in as many
requests as that takes, over the link to the device - made where there
is none, as for OpenBTGatt, and ended two seconds after - in their turn
among the requests of the link's blocks. Each service is a BTService
with BTSF_GATT: its UUID as its class, the handles of its first
attribute and its last (`handle`, `end_handle`), whose
characteristics ObtainBTCharacteristics lists; no name, PSM or
record.

**CONTEXT**

- Waits: yes, until the device has answered or not.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The list is the caller's - made in its context - until
ReleaseBTServices, the records and names with it.

**NOTES**

Over LE the primary services are listed; a service another includes,
a secondary one, is not.

**BUGS**

None known.

**SEE ALSO**

`ReleaseBTServices`, `OpenBTChannel`

**EXAMPLES**

```zig
var services: ?*exec.List = null;
if (bt.ObtainBTServices(bluetooth.BT_ALL_CONTROLLERS, &device, &services) != 0) return;
defer bt.ReleaseBTServices(services);
var it = services.?.iterator();
while (it.next()) |node| {
    const service: *bluetooth.BTService = @fieldParentPtr("node", node);
    _ = service.psm;
}
```

## OpenBTChannel

Opens an L2CAP channel to a protocol of a device, named by its PSM, and waits until it is open.

**SYNOPSIS**

```zig
fn OpenBTChannel(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress,
    psm: u32, port: *exec.MsgPort, channel: *?*bluetooth.BTChannel) i32
```

**SINCE**

1.7. LVO -104.

**INPUTS**

- `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
  for the one with a link to the device, else the one whose discovery
  found it, else the first that is up and on.
- `address` - the device's, a BTADDR_BREDR address.
- `psm` - the protocol's (l2cap.PSM_*, or one the device's services
  name: BTService.psm): odd, the low bit of its upper byte clear.
- `port` - where the channel's messages go (BTChannelMessage).
- `channel` - set to the channel once it is open; null otherwise.

**RESULT**

0 once the channel is open. Otherwise why not: BTERR_REFUSED for a
device that refused it - for want of security, say - or closed it
while it was configured, BTERR_BUSY for one without the resources for
it, BTERR_UNSUPPORTED for a PSM the device does not have, an LE
address or a PSM no channel can name, BTERR_NOMEM for a controller
with no room for another, BTERR_TIMEOUT for a device that did not
answer within 10
seconds (60 where it said it would answer later), BTERR_PROTOCOL for
an answer that made no sense; for a link that could not be made, what
ConnectBTDevice answers.

**BEHAVIOR**

The channel is asked for over the link to the device; a link that is
not there is made first - and ends two seconds after its last channel
has closed, unless ConnectBTDevice asks for it meanwhile. A link that
is being made secure with its bond is waited for. Once the device has
taken the channel, its configuration is agreed both ways: this
machine takes frames of up to 1024 bytes (BTChannel.mtu_in), the
device what it says - 672 where it says nothing, 48 at least
(BTChannel.mtu_out) - in basic mode, a frame as it is.

What comes on the open channel comes to `port`: each frame as a
BTCM_DATA message, the frame in `data` and `length`; at most 32 of
them out unreplied, those past them let go and counted in
BTChannel.dropped. Its end - the device's close (`result` 0), its
link's (the link's reason), its controller's (BTERR_DETACHED) - comes
as BTCM_CLOSED, and BTCHF_CLOSED set in the channel's flags. A
controller keeps 16 channels.

**CONTEXT**

- Waits: yes, until the channel is open or not - StartBTChannel does
  not.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The channel is the caller's - made in its context - until
CloseBTChannel, closed or not. The port must be there until then;
each message that comes to it is the library's, to be replied
(ReplyMsg) once read, which frees it.

**NOTES**

Channels go over BR/EDR alone: none over LE, whose credit-based
channels the profiles here do not use.

**BUGS**

None known.

**SEE ALSO**

`StartBTChannel`, `CloseBTChannel`, `SendBTChannel`, `AddBTListener`,
`ObtainBTServices`

**EXAMPLES**

```zig
var channel: ?*bluetooth.BTChannel = null;
if (bt.OpenBTChannel(bluetooth.BT_ALL_CONTROLLERS, &device, 0x1001, port, &channel) != 0) return;
_ = bt.SendBTChannel(channel.?, "hello", 5);
bt.CloseBTChannel(channel);
```

## OpenBTGatt

Opens the attribute protocol to an LE device, as GATT's client, and waits until it is open - or opens a block that waits for the device.

**SYNOPSIS**

```zig
fn OpenBTGatt(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress,
    port: *exec.MsgPort, gatt: *?*bluetooth.BTGatt, flags: u32) i32
```

**SINCE**

1.8, `flags` 1.10. LVO -132.

**INPUTS**

- `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
  for the one with a link to the device, else the one whose discovery
  found it, else the first that is up and on.
- `address` - the device's, an LE address (BTADDR_LE_PUBLIC,
  BTADDR_LE_RANDOM); for a device with a bond, the bond's.
- `port` - where the block's messages go (BTGattMessage).
- `gatt` - set to the block once it is open - with BTGO_WAIT, at once;
  null otherwise.
- `flags` - BTGO_WAIT for a block that waits for its device; 0.

**RESULT**

0 once it is open - with BTGO_WAIT, once it waits. Otherwise why not:
BTERR_UNSUPPORTED for a BR/EDR address or a controller that cannot
initiate over LE - or, with BTGO_WAIT, scan - BTERR_NOMEM for a
controller with no room for another block or call, BTERR_TIMEOUT for
a link over which the device stopped answering already; for a link
that could not be made, what ConnectBTDevice answers.

**BEHAVIOR**

The link to the device is made where there is none - the device
advertising - and then ends two seconds after its last block has
closed and its last request has been answered, unless ConnectBTDevice
asks for it meanwhile. A link to a device with a bond is encrypted
with the bond's key first. Before this machine's first request on a
link the two exchange their MTUs: this machine takes PDUs of up to 517
bytes, and the smaller of the two is the link's (BTGatt.mtu).

The block asks the device's GATT server: ObtainBTServices lists its
services, ObtainBTCharacteristics a service's characteristics,
ReadBTAttribute and WriteBTAttribute read and write a value,
SubscribeBTAttribute has a value sent as it changes. The requests of
all the blocks on a link go one at a time, in the order they were
asked for. A device that does not answer one within 30 seconds is
asked nothing more over the link: every block on it is closed,
BTERR_TIMEOUT, and a new block needs the link made again.

What comes for the block comes to `port`: a value it subscribed to as
BTGM_VALUE, the attribute in `handle`, the value in `data` and
`length` - at most 32 of them out unreplied, those past them let go
and counted in BTGatt.dropped. Its end - its link's (the link's
reason), its controller's (BTERR_DETACHED), a request not answered
(BTERR_TIMEOUT) - comes as BTGM_CLOSED, and BTGF_CLOSED set in its
flags. A controller keeps 16 blocks.

**A block that waits** (BTGO_WAIT) is given back at once, BTGF_WAITING
set, and opens whenever a link to its device is up - one the device
makes, or ConnectBTDevice, or the library itself: while a block
waits for a device without a link the library listens for LE's
advertising (a passive scan, off while a discovery runs or an LE link
is being made), and makes the link as soon as the device advertises -
at its address, or at a private one its bond's identity resolving
key made. Such a link is made secure with the bond's key and ends two
seconds after the last block on it closes. Each time the block opens
it is told BTGM_OPENED, BTGF_WAITING cleared and its `mtu` the link's;
its calls then go to the device. When the link ends it is told
BTGM_WAITING - `result` why - and waits again; what it subscribed to
stays, written to the device again each time it opens, and a value
may come before BTGM_OPENED. A link over which the device stops
answering is ended. It closes only with its controller (BTGM_CLOSED,
BTERR_DETACHED) or by CloseBTGatt.

**CONTEXT**

- Waits: yes, until the block is open or not.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The block is the caller's - made in its context - until CloseBTGatt,
closed or not. The port must be there until then; each message that
comes to it is the library's, to be replied (ReplyMsg) once read,
which frees it.

**NOTES**

GATT goes over LE alone. The library serves GATT itself, to the
device's client on the same link: the machine's name and appearance,
and Service Changed. A block that waits suits a device that comes and
goes - a keyboard, a sensor - and a waiting block's calls while it
waits answer BTERR_NOTCONNECTED.

**BUGS**

Without BTGO_WAIT, a device that advertises at private addresses is
reached only over a link that is up: the link is made to the address
given.

**SEE ALSO**

`CloseBTGatt`, `ObtainBTServices`, `ObtainBTCharacteristics`,
`ReadBTAttribute`, `WriteBTAttribute`, `SubscribeBTAttribute`

**EXAMPLES**

```zig
var gatt: ?*bluetooth.BTGatt = null;
if (bt.OpenBTGatt(bluetooth.BT_ALL_CONTROLLERS, &device, port, &gatt, 0) != 0) return;
defer bt.CloseBTGatt(gatt);
var services: ?*exec.List = null;
if (bt.ObtainBTServices(gatt.?.controller, &device, &services) != 0) return;
defer bt.ReleaseBTServices(services);

// A sensor read each time it is in reach.
if (bt.OpenBTGatt(controller, &sensor, port, &gatt, bluetooth.BTGO_WAIT) != 0) return;
// ... BTGM_OPENED: ReadBTAttribute; BTGM_WAITING: out of reach.
```

## PairBTDevice

Begins a pairing with a device, over BR/EDR or LE: a bond the two keep, which authenticates and encrypts their links from then on.

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
- `address` - the device's: a BTADDR_BREDR address for a pairing over
  BR/EDR, an LE address (BTADDR_LE_PUBLIC, BTADDR_LE_RANDOM) for one
  over LE.
- `agent` - from AddBTAgent: asked what the pairing needs to know, and
  told its end; null for a pairing that asks nobody.

**RESULT**

0 once the pairing has begun: its end comes to the agent. Otherwise
why it has not: BTERR_BONDED for a device the controller has a bond
with already, BTERR_BUSY while the device is being paired or its link
ended, BTERR_UNSUPPORTED for a controller without the kind of link -
or, over LE, without its encryption or crypto.library -
BTERR_NOCONTROLLER, BTERR_NOTUP, BTERR_OFF, BTERR_NOMEM.

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

Over LE the library is the link's central and asks the device to pair -
with Secure Connections where the device has it, a P-256 key pair of
the pairing's own, and with legacy pairing otherwise - for a key of up
to 16 bytes; a device that takes fewer than 7 is refused. The agent is
asked as over BR/EDR: BTAK_CONFIRM for the number both show,
BTAK_PASSKEY for one the device shows, BTAK_SHOW for one to be typed
on it. The link is encrypted with the key the pairing made, and the
device's keys are taken: its long term key where Secure Connections
did not make one, and its identity - the address the bond is then
kept by, and the key that resolves the private addresses it uses.

The end goes to the agent as BTAK_DONE, its `result` 0 for a bond
made - kept by the controller's address and the device's in
`ENVARC:Sys/bluetooth/` - or why not: the controller's status
(hci.HCI_ERR_AUTHENTICATION_FAILURE when the numbers did not match or
the device said no, HCI_ERR_PAGE_TIMEOUT for a device that did not
answer its page, HCI_ERR_FAILED_TO_ESTABLISH for an LE link the
device never answered on), BTERR_REFUSED when the agent said no or did
not answer within 30 seconds, BTERR_TIMEOUT for a pairing not over
within a minute - or an LE device not heard advertising within 20
seconds - BTERR_NOMEM when the controller has its 32 bonds already.
Over LE the device's reasons are the same statuses: a confirm or check
that did not match, or a passkey that failed, is
HCI_ERR_AUTHENTICATION_FAILURE; a device that does not pair, or not
so, HCI_ERR_PAIRING_NOT_ALLOWED; too short a key
HCI_ERR_INSUFFICIENT_SECURITY; HCI_ERR_REPEATED_ATTEMPTS.
AddBTNotify's signal comes when the bond is made.

Since 1.12 a link the pairing made is ended two seconds after a
pairing that made no bond, unless ConnectBTDevice asked for it, or a
channel or a GATT block uses it, meanwhile; a link that was there
before the pairing stays, as does the link of a bond made.

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
pairing a device begins goes to the agent added last - over LE, a
device asks for it with a Security Request. A bond is kept only where
both sides ask for one; a pairing with the specification's debug key
keeps none.

**BUGS**

Over LE this side gives the device none of its own keys: it uses its
public address and signs nothing. A device that advertises only
private addresses is reached by the address a discovery heard, not by
its identity.

**SEE ALSO**

`AddBTAgent`, `UnpairBTDevice`, `ObtainBTBonds`, `ConnectBTDevice`

**EXAMPLES**

```zig
const agent = bt.AddBTAgent(port, bluetooth.BTIO_DISPLAYYESNO) orelse return;
defer bt.RemBTAgent(agent);
if (bt.PairBTDevice(bluetooth.BT_ALL_CONTROLLERS, &device, agent) != 0) return;
// What comes to `port` answered and replied, until BTAK_DONE.
```

## ReadBTAttribute

Reads the value of an attribute of a device's GATT server - a characteristic's (BTCharacteristic.value_handle), a descriptor's.

**SYNOPSIS**

```zig
fn ReadBTAttribute(base: *BluetoothBase, gatt: *bluetooth.BTGatt, handle: u32,
    buffer: [*]u8, length: u32, actual: *u32) i32
```

**SINCE**

1.8. LVO -148.

**INPUTS**

- `gatt` - an open block to the device.
- `handle` - the attribute's, 1 to 0xFFFF.
- `buffer`, `length` - where the value goes, and how much of it.
- `actual` - set to how much of the buffer the value fills; 0 where
  it is not read.

**RESULT**

0 once it is read. Otherwise why not: BTERR_ATT less the device's
reason for a value it does not give - BTERR_ATT -
att.ATT_ERR_READ_NOT_PERMITTED for one that may not be read, BTERR_ATT -
att.ATT_ERR_INSUFFICIENT_ENCRYPTION or
att.ATT_ERR_INSUFFICIENT_AUTHENTICATION for one that needs the link
encrypted by a bond (PairBTDevice), BTERR_ATT -
att.ATT_ERR_INVALID_HANDLE for a handle the device does not have;
BTERR_NOTCONNECTED for a block that is closed, BTERR_TIMEOUT for a
device that did not answer within 30 seconds, BTERR_NOMEM; for a link
down meanwhile, its reason.

**BEHAVIOR**

The value is asked for (Read Request) and, where the answer fills its
PDU - so that the value may go on - the rest from where it ended (Read
Blob), until the device says there is no more or the buffer is full. A
value longer than the buffer is cut at its end; values are 512 bytes
at the most (att.ATT_VALUE_MOST).

**CONTEXT**

- Waits: yes, until the device has answered or not.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The buffer stays the caller's: the library writes it while the call
waits.

**BUGS**

None known.

**SEE ALSO**

`WriteBTAttribute`, `ObtainBTCharacteristics`, `SubscribeBTAttribute`

**EXAMPLES**

```zig
var value: [att.ATT_VALUE_MOST]u8 = undefined;
var length: u32 = 0;
if (bt.ReadBTAttribute(gatt, characteristic.value_handle, &value, value.len, &length) == 0) {
    _ = value[0..length];
}
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

## ReleaseBTCharacteristics

Gives back a list from ObtainBTCharacteristics.

**SYNOPSIS**

```zig
fn ReleaseBTCharacteristics(base: *BluetoothBase, list: ?*exec.List) void
```

**SINCE**

1.8. LVO -144.

**INPUTS**

- `list` - from ObtainBTCharacteristics; null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The list, its nodes and their descriptors are freed.

**CONTEXT**

- Waits: no.
- Interrupts: no.
- Locks: none.
- Process: a Task will do.

**OWNERSHIP**

The list is gone. A subscription to one of its characteristics is
not: it lasts until UnsubscribeBTAttribute or CloseBTGatt.

**BUGS**

None known.

**SEE ALSO**

`ObtainBTCharacteristics`

**EXAMPLES**

```zig
bt.ReleaseBTCharacteristics(characteristics);
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

## ReleaseBTServices

Gives back a list from ObtainBTServices.

**SYNOPSIS**

```zig
fn ReleaseBTServices(base: *BluetoothBase, list: ?*exec.List) void
```

**SINCE**

1.7. LVO -128.

**INPUTS**

- `list` - from ObtainBTServices; null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The list, its nodes, their names and records are freed.

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

`ObtainBTServices`

**EXAMPLES**

```zig
bt.ReleaseBTServices(services);
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

## RemBTListener

Ends what AddBTListener began: devices' channels to its PSM are refused again.

**SYNOPSIS**

```zig
fn RemBTListener(base: *BluetoothBase, listener: ?*bluetooth.BTListener) void
```

**SINCE**

1.7. LVO -120.

**INPUTS**

- `listener` - from AddBTListener; null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

No channel comes to its port once the call returns; one a device is
still opening to it is closed. The channels that came stay open.

**CONTEXT**

- Waits: yes, for the listeners' list.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The handle is gone. The channels that came are the caller's still, to
close with CloseBTChannel; a BTCM_OPENED message still on the port
brings one of them.

**BUGS**

None known.

**SEE ALSO**

`AddBTListener`, `CloseBTChannel`

**EXAMPLES**

```zig
bt.RemBTListener(listener);
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

## RemBTService

Gives back a record AddBTService served.

**SYNOPSIS**

```zig
fn RemBTService(base: *BluetoothBase, record: ?*bluetooth.BTRecord) void
```

**SINCE**

1.9. LVO -176.

**INPUTS**

- `record` - from AddBTService; null does nothing.

**RESULT**

Nothing.

**BEHAVIOR**

The SDP server answers with the record no more - a device's search
does not find it, its handle is not known - and its copy is freed.

**CONTEXT**

- Waits: yes, for the records' list.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The handle is gone.

**BUGS**

An answer in parts is made again from the records for each part: a
device that reads one while a record is added or given back reads the
parts after that from the records as they are then.

**SEE ALSO**

`AddBTService`

**EXAMPLES**

```zig
bt.RemBTService(served);
```

## SendBTChannel

Sends a frame on a channel to the device's protocol.

**SYNOPSIS**

```zig
fn SendBTChannel(base: *BluetoothBase, channel: *bluetooth.BTChannel, data: [*]const u8, length: u32) i32
```

**SINCE**

1.7. LVO -112.

**INPUTS**

- `channel` - an open one, from OpenBTChannel or a BTCM_OPENED
  message.
- `data`, `length` - the frame: as long as the device takes at the
  most (BTChannel.mtu_out), an empty one too.

**RESULT**

0 once the frame is in the controller's queue. Otherwise
BTERR_TOOLONG for a frame longer than the device takes, or
BTERR_NOTCONNECTED for a channel that is closed.

**BEHAVIOR**

The frame is copied, and the call waits while its link's share of the
controller's queue is full - until the controller has sent what is
before it, or the channel has closed. Every link keeps a share of its
own, so a device that stops taking frames holds up only the sends to
it. A device's frames go in the order they are sent, the channel's
and its other channels'; other devices' take turns with them.
AttemptSendBTChannel answers at once instead, for a caller that must
not wait.

**CONTEXT**

- Waits: yes, for room in its link's share of the controller's queue.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The data is the caller's again once the call returns.

**NOTES**

In the queue is not at the device: a frame queued when the link goes
down is lost, and nothing says it was. A protocol that must know
answers frames of its own.

**BUGS**

None known.

**SEE ALSO**

`AttemptSendBTChannel`, `OpenBTChannel`, `CloseBTChannel`

**EXAMPLES**

```zig
const line = "hello";
if (bt.SendBTChannel(channel, line, line.len) != 0) return;
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
  - `BTCA_Visible` (u32) - found by others who look - inquiries
    answered, and advertising over LE - for that many seconds; 0 for
    not at all, BT_VISIBLE_ALWAYS until told otherwise.

**RESULT**

0 once it is done; BTERR_NOCONTROLLER for no such controller,
BTERR_NOTUP for one that is not up (or, with BT_ALL_CONTROLLERS, when
none is), BTERR_UNSUPPORTED for visible asked of a controller that can
neither answer inquiries nor advertise, BTERR_NOMEM when its commands
could not be queued. With
BT_ALL_CONTROLLERS, the first failure of any.

**BEHAVIOR**

The controller is told at once: Write Scan Enable for on and visible -
pages answered while it is on, inquiries too while it is visible -
Write Local Name and its extended inquiry response for the name. The
call returns once the commands are queued, not when they are answered.

Over LE it advertises while it is on and visible, so that a device may
link to it: its name, and that it is a computer, every 100 to 150 ms
from its public address. It makes way for a scan or a link it cannot
advertise beside - LE Read Supported States says which - and goes on
after, BTCF_ADVERTISING set while it advertises; a name changed is
advertised at once.

On, visible until told otherwise and the name are kept for the
controller's next start, by its address: in
`ENVARC:Sys/bluetooth/<address>/` (`settings`, `name`). Visible for a
time is not: it ends at its time, and a start ends it.

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

A controller without settings of its own is on and not visible. Visible
advertises over LE since 1.16.

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

## StartBTChannel

Begins opening an L2CAP channel to a protocol of a device, named by its PSM, and returns without waiting for it: the port is told once it is open, or why it is not.

**SYNOPSIS**

```zig
fn StartBTChannel(base: *BluetoothBase, controller: u32, address: *const bluetooth.BTAddress,
    psm: u32, port: *exec.MsgPort, channel: *?*bluetooth.BTChannel) i32
```

**SINCE**

1.13. LVO -184.

**INPUTS**

- `controller` - its number (BTController.id), or BT_ALL_CONTROLLERS
  for the one with a link to the device, else the one whose discovery
  found it, else the first that is up and on.
- `address` - the device's, a BTADDR_BREDR address.
- `psm` - the protocol's (l2cap.PSM_*, or one the device's services
  name: BTService.psm): odd, the low bit of its upper byte clear.
- `port` - where the channel's messages go (BTChannelMessage).
- `channel` - set to the channel once its opening has begun; null
  otherwise.

**RESULT**

0 once the opening has begun. Otherwise why it could not begin:
BTERR_NOCONTROLLER for no controller, BTERR_NOTUP or BTERR_OFF for
one that is not up or not on, BTERR_UNSUPPORTED for an LE address or a
PSM no channel can name, BTERR_NOMEM for a controller with no room for
another, BTERR_BUSY for a link to the device that is being ended; for
a link that could not be asked for, what ConnectBTDevice answers.

**BEHAVIOR**

The channel is opened as OpenBTChannel opens it - its link made first
where there is none, a link being made secure with its bond waited
for, its configuration agreed both ways - while the caller goes on.
Once it is open, BTCM_OPENED comes to `port` about it, its fields
(BTChannel) filled in, and its frames come after. Where it ends
before - refused, not answered, its link or its controller gone -
BTCM_CLOSED comes instead, `result` what OpenBTChannel would have
answered, never 0, and BTCHF_CLOSED is set in its flags.

**CONTEXT**

- Waits: only for the library's task to take the call, not for the
  device.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The channel is the caller's - made in its context - until
CloseBTChannel, which also gives up one that is still opening: no
message about it comes after. The port must be there until then; each
message that comes to it is the library's, to be replied (ReplyMsg)
once read, which frees it.

**NOTES**

For a program that serves several devices from one task: a device
that answers slowly - one that says it will answer later is waited
for a minute - holds up none of the others. A listener's BTCM_OPENED
may come to the same port; the channel the call handed back tells the
two apart, as BTCHF_INCOMING in its flags does.

**BUGS**

None known.

**SEE ALSO**

`OpenBTChannel`, `CloseBTChannel`, `SendBTChannel`, `AddBTListener`

**EXAMPLES**

```zig
var opening: ?*bluetooth.BTChannel = null;
if (bt.StartBTChannel(bluetooth.BT_ALL_CONTROLLERS, &device, 0x1001, port, &opening) != 0) return;
_ = sys.WaitPort(port);
const told: *bluetooth.BTChannelMessage = @fieldParentPtr("message", sys.GetMsg(port).?);
const open = told.kind == bluetooth.BTCM_OPENED;
sys.ReplyMsg(&told.message);
if (open) _ = bt.SendBTChannel(opening.?, "hello", 5);
bt.CloseBTChannel(opening);
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
scan turned off, the inquiry cancelled, the name being asked for too -
and BTCF_DISCOVERING cleared; whoever asked with AddBTNotify is
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

## SubscribeBTAttribute

Has a device send a characteristic's value to the block as it changes.

**SYNOPSIS**

```zig
fn SubscribeBTAttribute(base: *BluetoothBase, gatt: *bluetooth.BTGatt,
    which: *const bluetooth.BTCharacteristic, flags: u32) i32
```

**SINCE**

1.8. LVO -156.

**INPUTS**

- `gatt` - an open block to the device.
- `which` - the characteristic, from ObtainBTCharacteristics on the
  block's device.
- `flags` - BTGS_INDICATE for its value indicated, each confirmed to
  the device as it comes - for a characteristic with
  att.GATT_PROP_INDICATE; 0 for it notified (att.GATT_PROP_NOTIFY).

**RESULT**

0 once the device has taken the subscription. Otherwise why not:
BTERR_UNSUPPORTED for a characteristic without the property asked for
or without a Client Characteristic Configuration, BTERR_NOMEM for a
block with 16 subscriptions or without memory, BTERR_ATT less the
device's reason for one it refused - a device that wants the link
encrypted by a bond first, say - BTERR_NOTCONNECTED for a block that
is closed, BTERR_TIMEOUT for a device that did not answer within 30
seconds; for a link down meanwhile, its reason.

**BEHAVIOR**

The characteristic's Client Characteristic Configuration is written
with what the open blocks on the link want of it together - one
block's notifications and another's indications both - and each value
the device then sends of it comes to the port of every block
subscribed to it, as BTGM_VALUE. A block subscribed already is
subscribed again, notified or indicated as it asks now. A
subscription the device refuses is taken back.

**CONTEXT**

- Waits: yes, until the device has answered or not.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

Each message that comes is the library's, to be replied once read.

**NOTES**

A device with a bond may keep its configuration over its links, and
send a value before a block has subscribed again: a value no block
wants is let go.

**BUGS**

None known.

**SEE ALSO**

`UnsubscribeBTAttribute`, `ObtainBTCharacteristics`, `OpenBTGatt`

**EXAMPLES**

```zig
if (bt.SubscribeBTAttribute(gatt, characteristic, 0) != 0) return;
_ = sys.WaitPort(port);
while (sys.GetMsg(port)) |message| {
    const told: *bluetooth.BTGattMessage = @fieldParentPtr("message", message);
    if (told.kind == bluetooth.BTGM_VALUE) _ = told.data.?[0..told.length];
    sys.ReplyMsg(message);
}
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

The profile drivers bound to the device's services let go of it
first, told that it is forgotten (BTPU_FORGET), while its link is
still there to tell the device so. Then the key is forgotten, its file
and the services kept with it deleted before the call returns, and a
link to the device ended. AddBTNotify's signal comes.

**CONTEXT**

- Waits: yes, for the profile drivers, the library's task and the
  files' deletion.
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

`PairBTDevice`, `ObtainBTBonds`, `BTProfileUnbind`

**EXAMPLES**

```zig
_ = bt.UnpairBTDevice(bluetooth.BT_ALL_CONTROLLERS, &device);
```

## UnsubscribeBTAttribute

Ends a block's subscription to a characteristic's value.

**SYNOPSIS**

```zig
fn UnsubscribeBTAttribute(base: *BluetoothBase, gatt: *bluetooth.BTGatt,
    which: *const bluetooth.BTCharacteristic) i32
```

**SINCE**

1.8. LVO -160.

**INPUTS**

- `gatt` - an open block to the device.
- `which` - the characteristic SubscribeBTAttribute was given.

**RESULT**

0 once the device has taken the change, or for a value the block is
not subscribed to. Otherwise why not: BTERR_ATT less the device's
reason, BTERR_NOTCONNECTED for a block that is closed, BTERR_TIMEOUT
for a device that did not answer within 30 seconds, BTERR_NOMEM; for a
link down meanwhile, its reason. The subscription is ended either
way.

**BEHAVIOR**

The block is sent the value no more, and the characteristic's Client
Characteristic Configuration is written with what the other open
blocks on the link want of it - nothing, where none does, and the
device sends it no more. A message of the value already on the port
stays there.

**CONTEXT**

- Waits: yes, until the device has answered or not.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

Nothing changes hands.

**BUGS**

None known.

**SEE ALSO**

`SubscribeBTAttribute`, `CloseBTGatt`

**EXAMPLES**

```zig
_ = bt.UnsubscribeBTAttribute(gatt, characteristic);
```

## WriteBTAttribute

Writes the value of an attribute of a device's GATT server.

**SYNOPSIS**

```zig
fn WriteBTAttribute(base: *BluetoothBase, gatt: *bluetooth.BTGatt, handle: u32,
    data: [*]const u8, length: u32, flags: u32) i32
```

**SINCE**

1.8. LVO -152.

**INPUTS**

- `gatt` - an open block to the device.
- `handle` - the attribute's, 1 to 0xFFFF: a characteristic's value
  (BTCharacteristic.value_handle), a descriptor.
- `data`, `length` - the value, BTGatt.mtu - 3 bytes at the most.
- `flags` - BTGW_NORESPONSE for a Write Command: the value sent, the
  device not asked to answer - for a characteristic with
  att.GATT_PROP_WRITE_NO_RESPONSE; 0 for a Write Request, whose
  answer is waited for.

**RESULT**

0 once the device has taken the value - with BTGW_NORESPONSE, once it
is sent. Otherwise why not: BTERR_TOOLONG for a value longer than the
link's MTU less 3, BTERR_ATT less the device's reason for one it does
not take - BTERR_ATT - att.ATT_ERR_WRITE_NOT_PERMITTED for an
attribute that may not be written, BTERR_ATT -
att.ATT_ERR_INSUFFICIENT_ENCRYPTION for one that needs the link
encrypted by a bond - BTERR_NOTCONNECTED for a block that is closed,
BTERR_TIMEOUT for a device that did not answer within 30 seconds,
BTERR_NOMEM; for a link down meanwhile, its reason.

**BEHAVIOR**

The value goes in its turn among the requests of the link's blocks. A
Write Command is not answered: a device may let one go.

**CONTEXT**

- Waits: yes, until the device has answered - or the value is sent.
- Interrupts: no.
- Locks: none may be held.
- Process: a Task will do.

**OWNERSHIP**

The value stays the caller's: the library reads it while the call
waits.

**NOTES**

A value is written in one request: one longer than the MTU carries is
not cut into parts.

**BUGS**

None known.

**SEE ALSO**

`ReadBTAttribute`, `SubscribeBTAttribute`

**EXAMPLES**

```zig
const on = [_]u8{1};
_ = bt.WriteBTAttribute(gatt, characteristic.value_handle, &on, on.len, 0);
```
