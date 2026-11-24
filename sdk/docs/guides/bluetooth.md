# Bluetooth

A Bluetooth controller is a radio with its own processor: it is spoken to
in HCI packets - commands and data go to it, events and data come from
it - over whatever carries them, USB or a UART. `bluetooth.library`, in
`LIBS:`, is the stack above the controllers: it is given each one by the
device that drives it, brings it up and keeps what it learned, and tells
the programs that asked when a controller comes, goes or changes.

The library brings controllers up, lists them, sets them - on or off,
their name, whether others find them - finds the devices around them,
makes links to them and takes the links they make, pairs with them over
BR/EDR and LE, keeping the bonds, and opens L2CAP channels over BR/EDR's
links to the protocols programs speak, taking those the devices open; it
says what this machine offers - its own record and those programs add -
and asks a device what it offers (SDP). Over LE it asks a device's GATT
server for its services and characteristics, reads and writes their
values and has them sent as they change - over a link it makes again
whenever the device comes back, where asked to - and answers the
device's questions with a server of its own. Each service of a device
it bonds with is offered to the profile drivers in `DEVS:bluetooth/`:
`bthid.device` drives keyboards and mice, over BR/EDR and over LE, and
`btaudio.device` headphones and speakers, as outputs audio.device plays
through: the sound goes as a stream of SBC over AVDTP, which
`C:test/BTAudio` plays on its own too. LE's channels are the stack's
next part.

This guide is the pieces first, then what a controller device is, how a
controller is brought up, listing the controllers from a program, a
controller's settings, finding devices, links to devices and what a
link carries, pairing and bonds, channels and services, attributes over
LE, profile drivers, keyboards and mice, sound to a headphone,
headphones and speakers as outputs, the USB controllers and the
MediaTek MT7922's firmware, the Raspberry Pi 4 Model
B's controller, `SYS:System/Bluetooth`, `C:Bluetooth`, `C:test/BTEcho`,
`C:test/BTGatt`, `C:test/BTHidDevice` and `C:test/BTAudio`.

## The pieces

```
 programs     SYS:System/Bluetooth   C:Bluetooth      a program
                          \            |             /
           ObtainBTControllers, SetBTControllerAttrs, AddBTNotify,
           StartBTDiscovery, ObtainBTDevices, ConnectBTDevice,
           DisconnectBTDevice, ObtainBTConnections, AddBTAgent,
           PairBTDevice, UnpairBTDevice, ObtainBTBonds, OpenBTChannel,
           SendBTChannel, CloseBTChannel, AddBTListener, ObtainBTServices,
           AddBTService, OpenBTGatt, ObtainBTCharacteristics,
           ReadBTAttribute, WriteBTAttribute, SubscribeBTAttribute
 the stack          bluetooth.library: its own task, every controller's
                    HCI traffic, the bring-up, the settings, the
                    discoveries, the links and their data, the pairings
                    and the bonds, the channels, SDP's server and client,
                    GATT's server and client; its binder, which offers
                    the bonded devices' services to the profile drivers
                          |  BTProfileBind, BTProfileUnbind (DEVIF_BTPROFILE)
 the profiles       bluetooth/bthid.device: keyboards and mice, their
                    reports to hid.library, from there to keyboard.device
                    and mouse.device; bluetooth/btaudio.device:
                    headphones and speakers, each a sink of rta.library
                    while its stream is open, played through by
                    audio.device
                          |  CMD_READ, CMD_WRITE, HCICMD_QUERY (DEVIF_HCI)
                          |  AddBTController, RemBTController
 the controllers    usb/bluetooth.device:           bluetooth/cyw43455bt.device:
                    a unit per controller plugged   the board's own controller,
                    in, the MT79xx's firmware       its setup and its patch
                          |  pipes (usb.library)          |  the mini UART
 the bus            usb.library, xhci.device        the BCM2711's AUX block
```

| Piece | Where | What it is |
|---|---|---|
| `bluetooth.library` | `LIBS:` | the stack: the controllers it is given, brought up, listed and set, the devices they find, the links to them and the bonds with them, the channels over the links, the services the devices offer and the attributes of LE's, and the programs told when they change ([bluetooth](../autodocs/bluetooth.md)) |
| `ENVARC:Sys/bluetooth/` | | each controller's settings and bonds, and the services of the bonded devices the profile drivers took, kept by its address |
| `usb/bluetooth.device` | `DEVS:usb/` | Bluetooth controllers on USB as HCI units, a unit a controller; a class driver |
| `DEVS:usb/firmware/mediatek/` | | the MediaTek MT7922's Bluetooth firmware and MediaTek's licence for it, from `scripts/fetch-mt7922.sh` (the 64-bit machines' disks) |
| `bluetooth/cyw43455bt.device` | `DEVS:bluetooth/` | the Raspberry Pi 4 Model B's controller - the Bluetooth of its CYW43455, on the BCM2711's mini UART - as an HCI unit (the BCM2711 boards' disk) |
| `DEVS:bluetooth/firmware/broadcom/` | | the CYW43455's Bluetooth patch, `BCM4345C0.hcd`, and the licence for passing it on, from `scripts/fetch-cyw43455.sh` (the BCM2711 boards' disk) |
| `SYS:System/Bluetooth` | | the controllers set - on or off, their name, visible - and the devices around found, paired with, linked to and forgotten, in a window that answers the pairings |
| `C:Bluetooth` | | the controllers - listed, with `INFO` what each is, and set - the devices around them (`SCAN`), the links to them (`CONNECT`, `DISCONNECT`, `LIST`), the bonds (`PAIR`, `UNPAIR`, `BONDS`, `AGENT`), and what a device offers (`SERVICES`), over LE with its characteristics |
| `C:test/BTEcho` | | channels to and from the devices around: a PSM served, each frame sent back, or a channel opened to a device's PSM, each line typed sent; in the disk's `tests` set |
| `C:test/BTGatt` | | the attributes of an LE device's GATT server read, written and watched as they change, with `WAIT` across the link's ends; in the disk's `tests` set |
| `bluetooth/bthid.device` | `DEVS:bluetooth/` | keyboards, mice and media keys over BR/EDR and over LE: a profile driver, their reports read by hid.library ([btprofile](../autodocs/btprofile.md)) |
| `bluetooth/btaudio.device` | `DEVS:bluetooth/` | headphones and speakers over BR/EDR as sound outputs: a profile driver, a sink of rta.library for each device while its stream is open ([btprofile](../autodocs/btprofile.md)) |
| `C:test/BTHidDevice` | | this machine as a keyboard and a mouse over BR/EDR, for a host to be tried with; in the disk's `tests` set |
| `C:test/BTAudio` | | a sound file or a tone played to a headphone or a speaker over BR/EDR, the stream's configuration and its packets said; in the disk's `tests` set |

The library, the devices - the controllers' and the profile drivers' -
their firmware, the window and the command are the disk's `bluetooth`
set.

## A controller device

A device whose units are controllers says so with `DEVIF_HCI` in its ROM
tag's list of what it speaks (`sdk/devices/hci.zig`). Every controller
looks alike through it, so that the stack needs nothing of the chip:

- **A request is one packet**: an `IOHciReq`, whose `packet_type` says
  which kind - `HCI_COMMAND_PKT`, `HCI_ACLDATA_PKT`, `HCI_SCODATA_PKT`,
  `HCI_EVENT_PKT`, `HCI_ISODATA_PKT` - and whose `io_Data` holds the
  packet from its own header on, without the framing its transport adds.
  `CMD_WRITE` sends one and is answered once the transport has taken it;
  a command's answer is an event of its own. `CMD_READ` takes the next
  packet the controller sent, whatever its kind, and says which in
  `packet_type`; several reads may wait, and are answered in turn. A
  packet longer than a read's `io_Length` stays for the next read, and
  this one is answered `HCIERR_TOOLONG` with `io_Actual` the length the
  packet needs.
- **`HCICMD_QUERY`** fills in an `HCIInfo`: how the controller is reached
  (`HCIBUS_USB`, `HCIBUS_UART` with its rate) and the device's word for
  its chip and its firmware. It is answered at once, in the caller's
  task.
- **The unit opens once its controller is ready**: whatever the chip
  needs first - its firmware, its line's rate, its address - is the
  device's to do before. A controller that goes away answers every
  request `HCIERR_DETACHED`, those it held as well.

A device whose controllers are plugged in offers each to the library
when it is ready, and takes it back before it closes its pipes:

```zig
const bt: *BluetoothBase = @ptrCast(sys.OpenLibrary(sdk.bluetooth.BLUETOOTHNAME, 1) orelse return);
if (bt.AddBTController("usb/bluetooth.device", unit_number) < 0) {
    // not taken: no memory, or the unit would not open
}
// ... unplugged: every request the unit held answered first
bt.RemBTController("usb/bluetooth.device", unit_number);
```

`AddBTController` returns once the library has opened the unit and sent
it its first command; the bring-up goes on in the library's task. The
device must answer the open and `HCICMD_QUERY` without waiting for the
task that called `AddBTController`, and `AbortIO` must take back a read
or a write it has not started, since `RemBTController` closes the unit
before it returns.

**A controller on the board** is there from the start, before anything
has loaded its device. Its device's ROM tag names the board's part its
units are (`unit_part`, `unit_chip`: a `PARTKIND_BLUETOOTH` part and its
chip), and the library adds every such unit itself, the first time a
process opens it (`ObtainDeviceUnits` lists them): opening the unit loads
the device, whose init starts setting the controller up. Until it is set
up, the open answers `HCIERR_NOTREADY` and the controller waits on the
list as `BTCS_OPENING`; the device then offers it with `AddBTController`,
and the library opens it and brings it up. A controller its device could
not set up is offered all the same, its open answering `IOERR_OPENFAIL`:
it stays on the list as `BTCS_FAILED`, with `BTERR_OPENFAIL`, and the log
says what of the setup failed. The boot opens the library:
`S:Startup-Sequence` runs `C:Bluetooth` in a shell of its own on a disk
with Bluetooth, so that a board's controller comes up with the machine -
and a bonded keyboard or mouse comes back by itself - the library's task
holding the library open from then on. Without that line it comes up
with the first program that opens the library.

## Bringing a controller up

The library's task owns every controller's traffic. It sends a command
only within the controller's credits - how many commands it said it
takes now, one at the start - matches each `Command Complete` and
`Command Status` to the command it answers, and gives each command a time
to be answered in: a controller that lets one go unanswered fails, with
`BTERR_TIMEOUT`.

A controller is brought up command by command:

1. **Reset**, and what it is: its local version, the commands it takes,
   its features (pages 1 and 2 where it has them), its buffers for ACL
   and SCO data, its address; for LE, its LE buffers - or none of its
   own, when LE's links share BR/EDR's - and its LE features. Once its address is
   known, the settings kept for it are read, and the rest waits for
   them.
2. **What it is to tell**: the events the stack takes, BR/EDR's and LE's,
   chosen by what it can do.
3. **What it is to be**: Secure Simple Pairing on, LE host support on a
   controller with BR/EDR and LE both, its class of device (a desktop
   computer), and its name: the one kept for it, or the machine's - the
   first line of `ENVARC:Sys/net/hostname` that is neither blank nor a
   comment, or `PowerOS` without one.
   For BR/EDR also: inquiry results with each device's signal, and with
   what it says of itself where the controller has extended results;
   inquiries listened for on both of the inquiry's trains in each
   interval (interlaced), so that a device that looks finds it within
   the first; its extended inquiry response - its name - and what it
   answers: pages while it is on, inquiries too while it is visible.

A step the controller does not take - by the commands it said it takes,
or by `Unknown HCI Command` - is passed over, unless the controller is
nothing without it: the reset, the version, the features, the buffer
sizes and the address. A controller that cannot do one of those fails
with the status it answered. A `Hardware Error` event brings the
controller up again from its reset, twice at most.

## The controllers from a program

`ObtainBTControllers` answers a copy of the library's list, made for the
caller, which `ReleaseBTControllers` gives back; nothing on it changes
while the program reads it.

```zig
const list = bt.ObtainBTControllers() orelse return;
defer bt.ReleaseBTControllers(list);
var it = list.iterator();
while (it.next()) |node| {
    const controller: *const sdk.bluetooth.BTController = @fieldParentPtr("node", node);
    // controller.id, .state (BTCS_*), .address, .hci_version, .manufacturer,
    // .chip, .firmware, .features, .le_features, .commands, ...
}
```

A controller's `id` is its number from 0, the same for as long as it is
there; `ln_Name` and `unit` say which device's unit it is. Its `state` is
`BTCS_OPENING` - while its device sets it up, for one on the board -
`BTCS_STARTING` while it is brought up, `BTCS_UP`, or
`BTCS_FAILED` with the reason in `failure`: a `BTERR_*`, or the status
the controller answered the command that did not work. Its features are
the bits it answered, feature `n` bit `n % 8` of byte `n / 8`
(`sdk.bluetooth.hci`'s `LMP_*`, `LE_FEATURE_*` and `CMDBIT_*` name
them).

A program that wants to know when a controller comes, goes or changes
state asks for a signal:

```zig
const signal = sys.AllocSignal(-1);
const notify = bt.AddBTNotify(sys.FindTask(null).?, @as(u32, 1) << @intCast(signal));
// ... Wait for it, then ObtainBTControllers again
bt.RemBTNotify(notify);
```

The signal comes for every change of any controller: one added, up,
failed or gone; set otherwise; a discovery begun or over, a device it
found, a name it heard; a link being made, up, failed or ended; a
pairing begun or over, a bond made or forgotten. It says that something
changed, not what - the program lists again what it shows, with
`ObtainBTControllers`, `ObtainBTDevices`, `ObtainBTConnections` and
`ObtainBTBonds` - and changes close together may come as one.

## A controller's settings

What a controller shows others is set with `SetBTControllerAttrs`, for
one controller or for every one that is up (`BT_ALL_CONTROLLERS`), with
a tag for each setting that is to change:

```zig
const tags = [_]utility.TagItem{
    .{ .tag = bluetooth.BTCA_Name, .data = @intFromPtr("Desk") },
    .{ .tag = bluetooth.BTCA_Visible, .data = 120 }, // seconds
    .{},
};
const result = bt.SetBTControllerAttrs(bluetooth.BT_ALL_CONTROLLERS, &tags);
// 0, or BTERR_NOCONTROLLER, BTERR_NOTUP, BTERR_UNSUPPORTED, BTERR_NOMEM
```

- **`BTCA_Powered`** - on, or off. Off, the controller answers nobody
  and looks for nothing: a discovery it runs stops.
- **`BTCA_Name`** - the name it shows others, UTF-8, cut at a whole
  character to 247 bytes - one fewer than a name may have, so that a NUL
  always ends it: a controller that reads its own to a NUL, as the
  CYW43455 does, tells others a wrong length for one of 248 - and an
  empty one is the machine's again.
- **`BTCA_Visible`** - found by others who look - inquiries answered -
  for that many seconds, until told otherwise (`BT_VISIBLE_ALWAYS`), or
  not at all (0). Only BR/EDR is found: the controller does not
  advertise on LE, and one without BR/EDR answers `BTERR_UNSUPPORTED`.

A controller that is up says how it is now in its `flags` -
`BTCF_POWERED`, `BTCF_CONNECTABLE` (pages answered), `BTCF_VISIBLE` with
`visible_left` the seconds left or `BT_VISIBLE_ALWAYS`, and
`BTCF_DISCOVERING` - and its name in `name`.

**What is set is kept** for the controller's next start, by its address,
in `ENVARC:Sys/bluetooth/<address>/` - the address's twelve hex digits,
the most significant first (`00005EEF1042`):

| File | What it holds |
|---|---|
| `settings` | `Powered = YES` or `NO`, and `Visible = YES` - found until told otherwise - or `NO` |
| `name` | the name, its first line; without the file, the machine's |

Visible for a time is not kept: it ends at its time, and a start ends it.
A controller without files starts on, not visible, with the machine's
name.

## Finding devices

`StartBTDiscovery` makes a controller - or every one that is up and on -
look for the devices around it, for about as many seconds as it is
given (2 to 60; 0 for about ten), in three parts:

1. **LE's advertising**, for a third of the time: listened to actively,
   every advertiser asked for its scan response, which often has its
   name.
2. **An inquiry**, for the rest: the BR/EDR devices that are visible
   answer, with their signal and, from a controller with extended
   results, their names and services.
3. **The names**: each BR/EDR device that has said no complete name is
   asked for it, the strongest first, up to ten seconds each.

A controller without LE, or without BR/EDR, gives the whole time to the
part it has. The devices it found before are forgotten as it begins;
`BTCF_DISCOVERING` is set on it until the last part is over, and
`StopBTDiscovery` ends it before. A device is in the list as soon as it
is heard, and a name as soon as it comes:

```zig
const list = bt.ObtainBTDevices(bluetooth.BT_ALL_CONTROLLERS) orelse return;
defer bt.ReleaseBTDevices(list);
var it = list.iterator();
while (it.next()) |node| {
    const found: *const bluetooth.BTDevice = @fieldParentPtr("node", node);
    // found.node.name, .address (.kind: BTADDR_BREDR, _LE_PUBLIC, _LE_RANDOM),
    // .flags (BTDF_*), .rssi, .class_of_device, .appearance, .company,
    // .uuid16[0..uuid16_count], .uuid128[0..uuid128_count], .age, ...
}
```

Each node is a copy made for the caller, as the device was at the call.
What a device is heard to say of itself is gathered, over BR/EDR from
its extended inquiry response and over LE from its advertising and its
scan response:

| Field | What it is |
|---|---|
| `node.name` | its name; `BTDF_SHORT_NAME` while only a shortened one has come, `BTDF_NO_NAME` when it was asked and had none |
| `flags` | `BTDF_BREDR`, `BTDF_LE` - how it was heard, both for a device that answered an inquiry and advertised from the same public address - and `BTDF_CONNECTABLE` for an advertiser that takes connections |
| `rssi` | its signal as last heard, in dBm; `BT_RSSI_NONE` for none |
| `tx_power` | the power it says it sends at, in dBm; `BT_TX_POWER_NONE` for none |
| `class_of_device` | BR/EDR's class: what it is (`COD_MAJOR_*`) and which services it has |
| `appearance` | LE's word for what it is: a category and a kind in it |
| `company` | the maker named in its manufacturer data; `BT_COMPANY_NONE` for none |
| `uuid16`, `uuid128` | the services it named, eight 16-bit and two 128-bit at most; 32-bit ones are kept as 128-bit |
| `ad_flags` | LE's flags: found for a time or in general, and without BR/EDR |
| `age` | how many milliseconds ago it was last heard |

What a device is - a keyboard, headphones, a phone - comes from two
places: BR/EDR's class of device and LE's appearance. `BTDeviceKind`
reads them both into one of the kinds `BTDK_*`, for a program to name in
its own words and language: the class first - its major class, and its
minor class where that tells kinds apart (a laptop from a computer,
headphones from a headset, a keyboard from a mouse) - and the appearance
where the class names none; `BTDK_NONE` where neither says. A bond's and
a link's `class_of_device` are read the same way.

```zig
const kind = bt.BTDeviceKind(found.class_of_device, found.appearance);
if (kind == bluetooth.BTDK_KEYBOARD or kind == bluetooth.BTDK_KEYBOARD_MOUSE) { ... }
```

A controller keeps up to 64 devices; when more are heard, it keeps those
heard strongest. The list stays until its next discovery.

## Links to devices

`ConnectBTDevice` makes a link to a device and waits until it is up -
over BR/EDR for a `BTADDR_BREDR` address, over LE for an LE one:

```zig
// 00:00:5E:EF:10:01, over BR/EDR.
const device = bluetooth.BTAddress{ .bytes = .{ 0x01, 0x10, 0xEF, 0x5E, 0x00, 0x00 } };
const result = bt.ConnectBTDevice(bluetooth.BT_ALL_CONTROLLERS, &device);
// 0 once it is up; else the controller's status - HCI_ERR_PAGE_TIMEOUT
// for a device that did not answer - or BTERR_TIMEOUT, BTERR_BUSY, ...
```

- **Over BR/EDR** the controller pages the device, by what its discovery
  heard of it in the last minute - how often the device listens for
  pages, and its clock - or, without that, as a device that listens at
  its slowest. The controller is the link's central unless the device
  takes the role over; a device that does not answer is given up on
  after the controller's page timeout, about five seconds.
- **Over LE** the controller listens for the device's advertising and
  connects as its central, asking for an interval of 30 to 50 ms, no
  latency, and the link lost after 420 ms unheard. A device that does not
  advertise within 20 seconds is given up on (`BTERR_TIMEOUT`). The
  controller has a link as soon as it has sent its request, so the link
  is up once the device has answered on it: its features read (LE Read
  Remote Features), or a frame of its come. One the device never answers
  on is given up after six connection events and was not made
  (`HCI_ERR_FAILED_TO_ESTABLISH`).

A controller pages one device at a time and initiates to one: another
link of the same kind asked for meanwhile is `BTERR_BUSY`. A discovery
it runs is stopped first. With `BT_ALL_CONTROLLERS` the link is made by
the controller with a link to the device already, else by the one whose
discovery found it, else by the first that is up and on.

**A link the device makes** - a page the controller hears - is taken on
by itself while the controller is on, the controller staying the link's
peripheral; a link for sound is refused. A controller keeps eight
links.

`DisconnectBTDevice` ends a link and waits until it is down; a link
being made is taken back, and the call that makes it answered
`HCI_ERR_LOCAL_HOST_TERMINATED`. A controller switched off ends its
links, telling each device why. The log says each link up, not made or
down, with the controller's reason (`C:Log`).

`ObtainBTConnections` lists them, a copy for the caller as
`ObtainBTDevices`' is:

```zig
const list = bt.ObtainBTConnections(bluetooth.BT_ALL_CONTROLLERS) orelse return;
defer bt.ReleaseBTConnections(list);
var it = list.iterator();
while (it.next()) |node| {
    const link: *const bluetooth.BTConnection = @fieldParentPtr("node", node);
    // link.node.name, .controller, .address, .flags (BTLF_*), .handle,
    // .age, .class_of_device, .interval, .latency, .supervision
}
```

| Field | What it is |
|---|---|
| `node.name` | the device's name: what the discovery heard, or - over BR/EDR - what the device answers over the link once it is up |
| `flags` | `BTLF_LE` for a link over LE, `BTLF_INCOMING` for one the device made, `BTLF_CENTRAL` while the controller is its central, `BTLF_ENCRYPTED` while it is encrypted, `BTLF_AUTHENTICATED` once the two have shown each other a link key, `BTLF_BONDED` for a device with a bond, `BTLF_PAIRING` while it is being paired or made secure |
| `handle` | the controller's number for the link |
| `age` | how many milliseconds it has been up |
| `class_of_device` | the device's class, as its page said or the discovery heard |
| `interval`, `latency`, `supervision` | LE's: how often the two speak, in units of 1.25 ms; how many of those times the peripheral may let pass; how long the link lasts unheard, in units of 10 ms |

A link being ended is listed until it is down.

**What a link carries.** Its data goes as L2CAP frames of up to 1024
bytes, cut into the packets the controller takes, sent within its
buffers - a packet holds one until the controller says it is sent - and
put together again from the packets it hands up. Every link that is up
keeps one of the controller's buffers, and one place in the library's
queue of frames, for itself; the rest go to the links that send, which
take turns, a packet each. So a device that stops taking packets -
switched off or out of range, until its link is lost - holds up only
its own frames. On the signalling
channel the library answers what a device asks of any link: what it
supports - its fixed channels, the signalling one alone - and an echo.
Over BR/EDR it opens and takes the channels to protocols (Channels and
services, below); LE's credit-based ones are refused. Over LE, a
peripheral's wish for other parameters is taken while they are within
the specification's bounds and the controller is the link's central;
the attribute protocol's channel carries GATT both ways (Attributes
over LE, below); the security manager's channel is the pairing's
(below). A device may end a link it has no use for.

## Pairing and bonds

Pairing makes a bond with a device: a key the two keep, which
authenticates their links from then on and encrypts them. The library
pairs over BR/EDR - with Secure Simple Pairing, P-256's Secure
Connections where the controller has them, or with a PIN for a device
without it - and over LE with the security manager; it keeps each bond
by the controller's address and the device's.

**An agent** answers what a pairing needs to know. `AddBTAgent` gives the
library a port, and what the agent's user can do - see a number, answer
yes or no, type a number:

```zig
const port = sys.CreateMsgPort() orelse return;
const agent = bt.AddBTAgent(port, bluetooth.BTIO_DISPLAYYESNO) orelse return;
```

Each question comes to the port as a `BTAgentMessage`, the library's;
the agent fills in its answer and replies it (`ReplyMsg`):

| `kind` | What it asks | The answer |
|---|---|---|
| `BTAK_CONFIRM` | whether the device shows `number` - or, with `BT_NO_NUMBER`, whether the device may pair at all | `accept` |
| `BTAK_PASSKEY` | the number the device shows | `accept`, `passkey` |
| `BTAK_PIN` | the PIN, for a device without Secure Simple Pairing | `accept`, `pin`, `pin_length` |
| `BTAK_SHOW` | nothing: `number` is to be typed on the device | replied at once |
| `BTAK_DONE` | nothing: the pairing is over, `result` says how | replied at once |

`name` holds the device's name where the controller knows it, `ours`
whether this machine began the pairing. A question not answered within
30 seconds is refused, its reply let go when it comes. `RemBTAgent`
ends an agent: the pairings that ask it are refused, and what is still
on its port is the caller's to reply before the port goes.

**PairBTDevice** begins a pairing and returns; its questions and its end
go to the agent it names:

```zig
if (bt.PairBTDevice(bluetooth.BT_ALL_CONTROLLERS, &device, agent) != 0) return;
// What comes to `port` answered and replied, until BTAK_DONE: its
// result 0 for a bond made, else the controller's status, BTERR_REFUSED, ...
```

A link to the device is made first where there is none; it ends two
seconds after a pairing that made no bond, unless `ConnectBTDevice`
asked for it, or a channel or a GATT block uses it, meanwhile. The two
say what their users can do, and that decides what is asked: where both can
show a number and answer, and one of them wants protection from a man
in the middle, each user confirms that the two show the same number
(`BTAK_CONFIRM`); where one side can only type, the other shows the
number to be typed (`BTAK_SHOW`, `BTAK_PASSKEY`); where a side can show
or type nothing, there is nothing to compare, and the pairing goes on
unconfirmed - as it does without an agent. The link is then
authenticated with the new key and encrypted; an encryption key shorter
than 7 bytes ends it. The bond is made where both sides asked for one.

**A device's pairing** - one the device begins - goes to the agent added
last, and is refused while there is none. Where there is nothing to
compare, an agent that can answer is asked whether the device may pair
(`BTAK_CONFIRM` with `BT_NO_NUMBER`); one that cannot lets it.

**The bonds** are kept in `ENVARC:Sys/bluetooth/<controller>/<device>`,
each address its twelve hex digits: a keyword file a bond - the device's
name and class at the pairing, the link key and its kind, whether a PIN
made it - read again as the controller comes up. A controller keeps 32.
`ObtainBTBonds` lists them - the keys stay the library's - and
`UnpairBTDevice` ends one: the profile drivers that drive the device let
go of it - told to have it forget this machine too - the key forgotten,
its files deleted, a link to the device ended. The device keeps its side
until it is told otherwise.

**A link to a device with a bond** that `ConnectBTDevice` makes is
authenticated with the bond's key and encrypted before the call
returns; a device that lost the bond answers
`HCI_ERR_PIN_OR_KEY_MISSING`, the link staying up. A device with a bond
that makes a link and authenticates it is given the bond's key.

**Over LE** the library is the link's central and begins every pairing
as the security manager's initiator: for `PairBTDevice` with an LE
address, or for a device's Security Request - which goes to the agent as
a device's pairing does. It asks for a bond, for protection from a man
in the middle where the agent's user can give it, for Secure
Connections, and for a key of up to 16 bytes; a device that takes fewer
than 7 is refused. With Secure Connections - where the device has them -
each side makes a P-256 key pair and the two share a secret; the
methods are BR/EDR's: a number both show (`BTAK_CONFIRM`), a passkey the
device shows (`BTAK_PASSKEY`) or one shown here to be typed on it
(`BTAK_SHOW`), or nothing to compare. Without them it is legacy
pairing, with a passkey or none. The link is encrypted with the key the
pairing made, and the device's keys are taken: its long term key where
Secure Connections did not make one, and its identity - the address its
bond is kept by, and the key that resolves the private addresses it
uses. A pairing with the specification's debug key keeps no bond.

An LE bond's file is `<device>.le` for a public address, `<device>.random`
for a static random one: the device's name, the long term key and what
it goes by (`LTK`, `EDIV`, `Rand`), the key's size, whether the pairing
was protected (`Authenticated`) and used Secure Connections, and the
device's identity resolving key (`IRK`). `ConnectBTDevice` to an LE
device with a bond encrypts the link with the bond's key before it
returns, as over BR/EDR; a link from a private address the bond's key
resolves is that bond's, and so is a Security Request on it.

The log says each pairing over, and why one failed (`C:Log`). Over LE
this side gives a device none of its own keys - it uses its public
address and signs nothing - and a device that advertises only private
addresses is reached by the address a discovery heard, not by its
identity.

## Channels and services

A channel is L2CAP's way to a protocol over a BR/EDR link. Each end
knows it by an identifier of its own (its CID), and the protocol it
reaches is named by a PSM: one of the specification's (`l2cap.PSM_SDP`,
`PSM_RFCOMM`, `PSM_HID_CONTROL`, ...), or a dynamic one, from
`l2cap.PSM_DYNAMIC_FIRST` (0x1001), that a program serves. A PSM is odd,
and the lowest bit of its upper byte is clear.

**OpenBTChannel** opens one to a device's PSM and waits until it is
open:

```zig
const port = sys.CreateMsgPort() orelse return;
var channel: ?*bluetooth.BTChannel = null;
if (bt.OpenBTChannel(bluetooth.BT_ALL_CONTROLLERS, &device, 0x2001, port, &channel) != 0) return;
defer bt.CloseBTChannel(channel);
_ = bt.SendBTChannel(channel.?, "hello", 5);
```

- **The link** is made where there is none - it ends two seconds after
  its last channel closes, unless `ConnectBTDevice` asks for it
  meanwhile - and a link to a device with a bond is authenticated and
  encrypted before the channel is asked for.
- **The device answers** at once, or says the channel is pending - while
  it makes the link secure, or while its user is asked whether to allow
  it - and is then waited for up to a minute. One without such a
  protocol answers `BTERR_UNSUPPORTED`, one without room `BTERR_BUSY`,
  one that refuses `BTERR_REFUSED`, one that does not answer within ten
  seconds `BTERR_TIMEOUT`.
- **The two then agree** on the channel: frames of up to 1024 bytes to
  this machine (`mtu_in`), and to the device what it takes (`mtu_out`) -
  672 bytes unless it says otherwise, never fewer than 48. A device that
  asks for a mode with retransmission is told the basic mode instead.

**StartBTChannel** takes the same inputs and begins the same opening
without waiting for it: for a program that serves several devices from
one task, so that a device slow to answer - one that holds a channel
pending for its minute - holds up none of the others. It answers at
once, 0 and `channel` set once the opening has begun, and the port is
told the rest: `BTCM_OPENED` once the channel is open, its block filled
in and its frames after it, or `BTCM_CLOSED` where it ends before,
`result` what `OpenBTChannel` would have answered - never 0.
`CloseBTChannel` gives up one that is still opening, and nothing more
comes about it.

```zig
var opening: ?*bluetooth.BTChannel = null;
if (bt.StartBTChannel(bluetooth.BT_ALL_CONTROLLERS, &device, 0x2001, port, &opening) != 0) return;
// On the port: BTCM_OPENED with told.channel == opening - open, its
// frames follow - or BTCM_CLOSED for it, told.result why it did not.
```

Most systems want the link encrypted before they take a channel to
anything but their SDP server - a Linux machine does - and an encrypted
link needs a bond: pair with the device first (`PairBTDevice`). Without
one, the pairing the device begins goes to the agent added last, and
with none it is refused and the channel with it.

What comes over a channel goes to its port as `BTChannelMessage`s, the
library's, each replied once it is read:

| `kind` | What it says |
|---|---|
| `BTCM_DATA` | a frame of the device's: `data`, `length` bytes, there until the message is replied |
| `BTCM_CLOSED` | the channel closed - by the device, with its link or its controller - and why: `result` 0, `BTERR_*`, or the link's reason; for one `StartBTChannel` began that never opened, why not, never 0 |
| `BTCM_OPENED` | a channel a device opened to a listener, `channel` its block (below); or the one `StartBTChannel` began, now open |

A channel has at most 32 of its frames out unreplied: those past them
are let go and counted in its block (`dropped`). `SendBTChannel` sends
a frame of at most `mtu_out` bytes - `BTERR_TOOLONG` past it - waiting
while its link's share of the controller's queue is full, and answers
`BTERR_NOTCONNECTED` once the channel is closed. A link's share fills
where the controller sends to the device more slowly than frames come:
a link far off or busy, the radio scanning, paging or pairing, a device
gone until its link is lost - the other links' frames go on meanwhile.
`AttemptSendBTChannel` answers `BTERR_BUSY` at once instead, the frame
not sent, for a caller that must not wait - a stream lets the frame go
and keeps its time. `CloseBTChannel` asks the device to close the
channel and gives its block back without waiting for the answer; what
was on the port about it and not taken is taken back, so that a port
several channels share holds nothing of one that is closed. Until the
device answers - five seconds at the most - the channel is its link's,
and a link made for it ends two seconds after.

**A listener** takes the channels devices open to a PSM:

```zig
const listener = bt.AddBTListener(0x2001, port, 0) orelse return; // served already
defer bt.RemBTListener(listener);
// BTCM_OPENED: told.channel - BTCHF_INCOMING in its flags - is this
// task's, until CloseBTChannel.
```

Once its configuration is agreed, each channel comes to the port as
`BTCM_OPENED`, and its frames and its end follow as an opened channel's
do. A device that opens one to a PSM nobody serves is told there is no
such protocol. `RemBTListener` takes no more; the channels that came
stay open, and a `BTCM_OPENED` still on the port brings one to close.
The link a device opened a channel over is the device's, and stays when
the channel closes.

With `BTLSF_SECURE` a channel is taken only over a link encrypted after
the two have authenticated with the key of their bond: a device without
a bond is refused for its security, and one whose link is not so yet is
told to wait while it is made so - refused if it is not within a minute.
A protocol whose frames must come from a device paired with - a
keyboard's keys - is served so.

**Which PSM.** A Linux machine hands the dynamic PSMs from 0x1001 to
0x10FF to its own services as they start - its object and file
exchange, for one - and holds a channel to one of those pending while
its user is asked. A protocol of one's own does better past 0x10FF.

**The SDP server.** Over PSM 1 the library says what this machine
offers: searches for services by their UUIDs, a record's attributes, and
both at once, each answer in as many parts as the device's MTU and the
size it asked for allow. Its records are the server's own (handle 0,
class 0x1000) and those programs add.

**A record of one's own.** `AddBTService` has the server answer with a
record a program makes - its attributes, each an ID and a value, in one
sequence as SDP lays them out (`sdk/libs/bluetooth/sdp.zig`) - until
`RemBTService`. The record is copied and given a handle of its own, from
`sdp.SDP_HANDLE_FIRST` on, as its attribute 0, and answered with after
the server's and those added before it. `FindBTServiceAttribute` reads
an attribute's value from a record - one `ObtainBTServices` listed, or
one's own - and `NextBTDataElement` reads one data element, and a
sequence's elements one by one when it is called on the sequence's
data:

```zig
var list: bluetooth.BTDataElement = .{};
if (!bt.FindBTServiceAttribute(service.record.?, service.record_length, sdp.ATTR_PROTOCOL_DESCRIPTOR_LIST, &list)) return;
var at: u32 = 0;
var element: bluetooth.BTDataElement = .{};
while (at < list.length and bt.NextBTDataElement(list.data.? + at, list.length - at, &element)) : (at += element.whole) {
    // element.kind (sdp.DE_*), .data and .length, .value, .uuid
}
```

**ObtainBTServices** asks a device what it offers - its SDP server, over
BR/EDR; over LE its GATT server (Attributes over LE, below) - and lists
what it answers:

```zig
var services: ?*exec.List = null;
if (bt.ObtainBTServices(bluetooth.BT_ALL_CONTROLLERS, &device, &services) != 0) return;
defer bt.ReleaseBTServices(services);
var it = services.?.iterator();
while (it.next()) |node| {
    const service: *const bluetooth.BTService = @fieldParentPtr("node", node);
    // service.node.name, .class16, .psm, .rfcomm_channel, .profile16, ...
}
```

Every record that names L2CAP is asked for, with all its attributes, in
as many parts as the device sends them; the link is made and ended as
`OpenBTChannel`'s is. A controller asks one device at a time
(`BTERR_BUSY`); a device that does not answer within ten seconds is
`BTERR_TIMEOUT`.

| Field | What it is |
|---|---|
| `node.name` | the service's name, in the language its record names first; empty where it has none |
| `class`, `class16` | what it is: the first class its record names, as a UUID and as its 16 bits where it has them, else 0 |
| `psm`, `rfcomm_channel` | where it is reached: L2CAP's PSM, and for a service over RFCOMM its channel (`psm` then `l2cap.PSM_RFCOMM`) |
| `profile16`, `profile_version` | the first profile its record names, and its version, the major one in the upper byte |
| `handle` | its record's handle on the device |
| `record`, `record_length` | the record as the device sent it, for a profile that reads more of it (`sdk/libs/bluetooth/sdp.zig`) |

## Attributes over LE

An LE device says what it offers through GATT: its server holds
attributes, each with a handle - 1 to 0xFFFF - and a type, a UUID. A
service is a run of them, from its declaration to its last handle; a
characteristic in it is a value and what may be done with it - read,
written, written without an answer, notified or indicated as it
changes - followed by its descriptors, among them the Client
Characteristic Configuration (0x2902) a client writes to have the value
sent to it. The protocol's constants are `sdk/libs/bluetooth/att.zig`'s.

**OpenBTGatt** opens a block to a device's server and waits until it is
open:

```zig
const port = sys.CreateMsgPort() orelse return;
var gatt: ?*bluetooth.BTGatt = null;
if (bt.OpenBTGatt(bluetooth.BT_ALL_CONTROLLERS, &device, port, &gatt, 0) != 0) return;
defer bt.CloseBTGatt(gatt);
```

- **The link** is made where there is none - the device advertising -
  and ends two seconds after its last block has closed and its last
  request has been answered, unless `ConnectBTDevice` asks for it
  meanwhile. A link to a device with a bond is encrypted with the
  bond's key first.
- **The MTU.** Before this machine's first request on a link the two
  say how long a PDU each takes - this machine 517 bytes - and the
  smaller is the link's, in the block's `mtu`.
- **The requests** of all the blocks on a link go one at a time, in the
  order they were asked for. A device that does not answer one within
  30 seconds is asked nothing more over that link: each block on it is
  closed, `BTERR_TIMEOUT`, and a new block needs the link made again.
- **A refusal** is `BTERR_ATT` less the device's reason, an
  `att.ATT_ERR_*` - `BTERR_ATT - att.ATT_ERR_READ_NOT_PERMITTED` for a
  value that may not be read. A value that wants the link encrypted
  (`ATT_ERR_INSUFFICIENT_ENCRYPTION`, `ATT_ERR_INSUFFICIENT_AUTHENTICATION`)
  needs a bond: pair with the device first (`PairBTDevice`).

**A block that waits.** With `BTGO_WAIT` the call returns at once, with
a block that waits for its device - `BTGF_WAITING` in its `flags` - and
opens each time the device is reached, for as long as the block lasts:

```zig
if (bt.OpenBTGatt(controller, &keyboard, port, &gatt, bluetooth.BTGO_WAIT) != 0) return;
```

- **The link.** While a block waits, the library listens to LE's
  advertising in the background - passively, half the radio's time -
  and makes a link to the device as soon as it advertises so that it
  may be connected: at the block's address, or at a private address
  the identity resolving key of the device's bond made, so that a
  device that changes its address is found by its bond. A link to a
  device with a bond is encrypted with the bond's key before the block
  opens. The scan pauses while a discovery runs and while the library
  makes another LE link, and stops with the last block that waits.
- **Open:** `BTGM_OPENED` comes, the link's MTU in the block's `mtu`;
  what the block subscribed to is written again first, so that its
  values come from the start. **The link's end:** `BTGM_WAITING`, the
  block waiting again - its requests answered `BTERR_NOTCONNECTED`
  meanwhile - until the device comes back or `CloseBTGatt`. A value the
  device sends while the block is opened is the block's too.
- A link already up is taken at once: the block may open before the
  call returns. A block without `BTGO_WAIT` reaches a device that
  advertises at private addresses only over a link that is up.

**ObtainBTServices**, given an LE address, asks the device's server for
its primary services, each a `BTService` with `BTSF_GATT`: its UUID in
`class` and `class16`, its first and last handles in `handle` and
`end_handle`; it needs no block. **ObtainBTCharacteristics** lists a
service's characteristics, each a `BTCharacteristic`, in handle order:

```zig
var characteristics: ?*exec.List = null;
if (bt.ObtainBTCharacteristics(gatt.?, service, &characteristics) != 0) return;
defer bt.ReleaseBTCharacteristics(characteristics);
```

| Field | What it is |
|---|---|
| `uuid`, `uuid16` | what it is, as a UUID and as its 16 bits where it has them, else 0 |
| `properties` | what may be done with its value: `att.GATT_PROP_READ`, `GATT_PROP_WRITE`, `GATT_PROP_WRITE_NO_RESPONSE`, `GATT_PROP_NOTIFY`, `GATT_PROP_INDICATE`, ... |
| `handle`, `value_handle`, `end_handle` | its declaration's handle, its value's, and its last |
| `descriptors`, `descriptor_count` | its descriptors, each a `BTDescriptor`: its UUID and handle |
| `configuration_handle` | its Client Characteristic Configuration's handle; 0 for none |

**ReadBTAttribute** reads a value by its handle - a characteristic's
`value_handle`, a descriptor's - in as many requests as it takes: an
answer that fills its PDU is read on from where it ended, until the
device says there is no more or the buffer is full. A value is 512
bytes at the most. **WriteBTAttribute** writes one in a single request,
the link's MTU less 3 bytes at the most (`BTERR_TOOLONG` past it), and
waits for the device's answer; with `BTGW_NORESPONSE` it goes as a Write
Command, which the device does not answer, and the call returns once it
is sent.

**SubscribeBTAttribute** has the device send a characteristic's value as
it changes, notified or - with `BTGS_INDICATE` - indicated, each
indication confirmed as it comes. What is written into its configuration
is what the open blocks on the link want of the value together, so that
the blocks of several programs share it; `UnsubscribeBTAttribute` and
`CloseBTGatt` write it again with what the others still want, nothing
where none does. A subscription the device refuses is taken back.

What comes for a block goes to its port as `BTGattMessage`s, the
library's, each replied once it is read:

| `kind` | What it says |
|---|---|
| `BTGM_VALUE` | a value the block subscribed to: the attribute in `handle`, the value in `data` and `length`, there until the message is replied |
| `BTGM_OPENED` | a block that waits open, its device reached |
| `BTGM_WAITING` | a block that waits waiting again: its link ended, and why, in `result` |
| `BTGM_CLOSED` | the block closed - with its link, its controller, or a request not answered; a block that waits only with its controller - and why, in `result`; `BTGF_CLOSED` is set in its `flags` |

A block has at most 32 values out unreplied: those past them are let go
and counted in its `dropped`. `CloseBTGatt` takes back what is still on
the port about the block, as `CloseBTChannel` does.

**The GATT server.** Over each LE link the library answers the device's
client too: the machine's name (Device Name), that it is a computer
(Appearance), and Service Changed, whose configuration each link keeps -
the attributes never change, so it is never indicated. Its values are
read, and the configuration alone is written; a request it does not
take is answered as not supported. A device reaches it over the links
this machine makes: the library does not advertise.

## Profile drivers

A profile is what a kind of device does over the channels or the
attributes - a keyboard's keys, a speaker's sound. A profile driver
drives one for the rest of the system: a device in `DEVS:bluetooth/`
(`sdk/devices/btprofile.zig`) with two calls after BeginIO and AbortIO,
`BTProfileBind` and `BTProfileUnbind`
([btprofile](../autodocs/btprofile.md)), and a ROM tag that says what it
drives. The library reads the tag from the file without loading it; a
driver is loaded when it is first offered a service.

**Which services are offered.** A pairing that makes a bond has the
device's services listed, as `ObtainBTServices` lists them, and each is
offered to every driver whose table has an entry it matches - the kind
of link it is reached over, `BTMATCH_BREDR` for a service of an SDP
record and `BTMATCH_LE` for a GATT one, and its class, in 16 bits or as
a UUID - the entry with the higher `priority` first, until one takes
it:

```zig
const speaks = [_]u32{ devices.DEVIF_BTPROFILE, 0 };
const matches = [_]btprofile.BTMatch{
    .{ .over = btprofile.BTMATCH_BREDR, .class16 = hidp.UUID_HID },
    .{},
};
export const driver_tag: btprofile.ResidentBTProfile linksection(".resident") = .{
    .device = .{
        .resident = .{ .flags = exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO, ... },
        .speaks = &speaks,
        .units = 0,
    },
    .matches = &matches,
};
```

The services taken are kept beside the bond, in
`ENVARC:Sys/bluetooth/<controller>/<device>.services` - for an LE bond
`<device>.le.services` or `<device>.random.services` - a line each: an
SDP record as a `Record` line of hexadecimal digits, a GATT service as
a `Gatt` line of its first and last handles and its UUID
(`Gatt 0010 002F 0000181200001000800000805F9B34FB`); whenever the
controller comes up they are offered again from the file, the device
not asked. A device bonded
while no driver on the disk drove any of its services keeps no such
file, and is offered once it is paired again.

**The calls.** The library opens the driver on `BTPROFILE_UNIT_BIND` and
calls `BTProfileBind` with a `BTBinding`: the controller, the device's
address and the service - one of BR/EDR with its record, for
`FindBTServiceAttribute` to read, or a GATT one with its handles, for
`ObtainBTCharacteristics` over a block of the driver's. The driver takes it - true, with
`unit` and `driver_data` its own - or declines it, and the next driver
is asked. The binding is the driver's until `BTProfileUnbind`: when the
controller goes, or when the bond ends (`UnpairBTDevice`) - then with
`BTPU_FORGET`, for the driver to tell the device to forget this machine
too while the link is still up. A driver that drives nothing more is
closed.

Both calls are made on the library's binder, a process of its own that
starts when there is something to offer and ends once nothing is bound.
It serves nothing else meanwhile, so a driver may call the library -
read the record, add listeners, open channels - and wait for it.
`ObtainBTBonds` names the drivers that drive each bond's device
(`BTBond.drivers`, the names joined by ", "), and the log says each
service bound (`C:Log`).

## Keyboards and mice

`bluetooth/bthid.device` drives keyboards and mice over BR/EDR, a
profile driver of the HID service (0x1124). It takes a device whose
record's report descriptor (`hidp.ATTR_HID_DESCRIPTOR_LIST`) describes a
keyboard, a mouse or media keys (a consumer control), or several, and
hands each report the device sends to hid.library, which makes it into
key-downs and key-ups for keyboard.device and into moves, buttons and
the wheel for mouse.device: a Bluetooth keyboard is the machine's
keyboard as a USB one is, its media keys among its keys.

```
1> Bluetooth PAIR 00:00:5E:EF:10:46
Pairing with 00:00:5E:EF:10:46 over BR/EDR; CTRL-C stops
Type 058213 on 00:00:5E:EF:10:46
Paired with Keyboard
1> Bluetooth BONDS INFO
  00:00:5E:EF:10:46  BR/EDR     confirmed    Keyboard
      controller 0, key type 8, Secure Connections
      driven by bthid.device
```

A HID device is reached over two L2CAP channels, control (PSM 17) and
interrupt (PSM 19), each frame beginning with a byte that says what it
is (`sdk/libs/bluetooth/hidp.zig`). The driver opens them, control
first, right after the pairing that bonded the device, and waits for
neither (`StartBTChannel`): a device slow to answer holds up no other
device's keys. After that the device opens them itself when it has
something to send, as a keyboard does when a key is pressed. So while it drives a device the driver
serves both PSMs - with `BTLSF_SECURE`, so that keys come only from a
device paired with - and closes again a channel of a device it does not
drive. A device that waits for its host to open the channels - one that
never opens them itself - is reached only right after its pairing.

The input reports come on the interrupt channel, and a keyboard's LEDs -
Caps Lock's light as it changes - go back on it as an output report.
The interrupt channel closing lets go of whatever keys or buttons the
device still held. A device that unplugs itself (`VIRTUAL_CABLE_UNPLUG`
on the control channel) has both channels closed, its bond kept for the
user to end; `Bluetooth UNPAIR` has the device unplug before the bond
ends. The log says each device driven, connected and disconnected.

A machine is a HID host or a HID device on these PSMs, not both: while
bthid.device drives a device, `C:test/BTHidDevice` finds them served.

**Over LE** the driver takes every HID service (0x1812) a bonded
device's GATT server has, and reaches the device through a block that
waits for it (`BTGO_WAIT`): the library makes the link whenever the
device advertises - a keyboard does when a key is pressed - encrypted
with the bond's key. At the block's first open the driver reads the
service (`sdk/libs/bluetooth/hidp.zig`): its Report Map is the report
descriptor, each Report's Report Reference says the report's ID and
kind, and the input reports are subscribed to. At each open Protocol
Mode is written the report protocol. A report the device notifies goes
to hid.library behind its ID; the LEDs go back to the Report of their
ID and kind, as a Write Command where the device takes one. The link's end lets go of whatever the device
held, and the block waits for the device again. A device whose report
map describes no keyboard and no mouse is let be, its block closed;
the log says so, and each device driven, connected and disconnected.

```
1> Bluetooth PAIR 00:00:5E:EF:10:47 LE
Pairing with 00:00:5E:EF:10:47 over LE; CTRL-C stops
Does 00:00:5E:EF:10:47 show 095452? (y/n) y
Paired with 00:00:5E:EF:10:47
1> Bluetooth BONDS INFO
  00:00:5E:EF:10:47  LE         confirmed
      controller 0, a key of 16 bytes, Secure Connections
      driven by bthid.device
```

## Sound to a headphone

A headphone or a speaker takes its sound over A2DP: this machine is the
source, the device the sink, and the sound goes as SBC frames over two
L2CAP channels to the device's PSM 25 (AVDTP) - the signalling first,
the media after it (`sdk/libs/bluetooth/avdtp.zig`). Both are opened to
a device bonded over BR/EDR, so the link is encrypted with the bond's
key.

**The signalling** finds the device's stream end points (DISCOVER) - a
headphone has one for each codec it takes - and asks each audio sink
not in use what it takes (GET_ALL_CAPABILITIES, or GET_CAPABILITIES of
a device that does not answer that). Of the first that takes SBC it
asks for a configuration (SET_CONFIGURATION): the sound's own rate - or
48 kHz, then 44.1 - in joint stereo, then stereo, dual channel and mono,
with the most blocks and subbands the device takes, loudness before
SNR, and a bitpool of 53 - 31 for mono and dual channel - within the
device's least and most. A configuration refused, the next is asked,
and the next end point after the last; a rate refused is passed over
whole. OPEN opens the stream and the media channel is opened after it,
START starts it, SUSPEND pauses it, CLOSE ends it - ABORT where the
device refuses to close it. Delay reporting is asked for where the
device offers it, and the device then says, in DELAYREPORT, how long
its sound takes from the radio to the ear. The device's own commands
are answered: its questions about this machine's end point - a source
of SBC at 44.1 and 48 kHz - the stream started, suspended, closed or
aborted by the device, its delay kept.

**The media** goes in RTP packets: a header of 12 bytes - its sequence
number counting the packets, its timestamp the samples sent before its
first - a byte counting its frames, and as many SBC frames as the media
channel's MTU takes, 15 at the most. At 48 kHz in joint stereo, with 16
blocks, 8 subbands and a bitpool of 53, a frame is 119 bytes for 128
samples of each channel - 357 kbit/s - and a channel taking 1021 bytes
carries 8 of them a packet, 21.3 ms of sound. A packet that finds no
room in the controller's queue is let go of, its number and its samples
counted all the same: the device hears the gap, and the sound after it
stays in time. The log says how many packets found no room once the
sound stops.

## Headphones and speakers as outputs

`bluetooth/btaudio.device` drives headphones and speakers bonded over
BR/EDR - a device whose SDP record is an audio sink (0x110B) - as sound
outputs: while a device's stream is open it is a sink of rta.library,
which audio.device plays through as it does any other (the [sound
guide](audio.md#bluetooth-headphones-and-speakers)). It drives four
devices at most, a stream each, on a task of its own, which waits for
no channel it opens (`StartBTChannel`) or closes, and for no room for a
packet (`AttemptSendBTChannel`): a device slow to answer - one that
holds a channel pending while its user is asked - stops no other
device's sound, nor does one switched off while it plays, whose packets
wait in its own share of the controller's buffers.

**The stream** is set up by whichever side comes first. The driver
serves PSM 25 - a listener for the channels of bonded devices, and a
record of this machine as an audio source (0x110A) in its SDP server -
and offers each device it drives an end point of its own to configure:
a source of SBC at 48 kHz, in any of SBC's channel modes, blocks,
subbands and allocations, at a bitpool of 2 to 53. A device that opens
the signalling channel itself - a headphone as it connects, a computer
to a source it knows - configures that end point and opens the stream,
and its media channel is waited for four seconds. Where the device has
opened none two seconds after its link came up, the stream is set up
from here (Sound to a headphone, above), the channel asked for again
two seconds after a refusal, four times in all. The link is the
device's to make - a headphone switched on pages the machine it was
last with - or `Bluetooth CONNECT`'s.

**The sink** is made as the stream opens, named as the bond names the
device - cut before a whole character at 31 bytes, `Bluetooth audio`
where it has no name - at priority -20, after the board's own outputs:
the sound goes to the device once it is picked (`Audio OUTPUT`) or
preferred (`Audio PREFER`), and a preferred device takes the sound over
each time its stream opens. Its one mode is 48000 Hz stereo. Its
buffers of 512 frames come due on timer.device's E-clock - one
audio.device was late for is handed out at once, 16 at the most, so
that the sound stays whole - and go to the driver's task through a ring
of 32, 341 ms, to be gathered into packets, each sent as it is full.
The stream ends as the device goes - switched off, out of reach, its
channels closed - and its sink with it: audio.device goes on through
the next output, every sound where it was.

**Playing and pausing.** The stream is started once something other
than silence plays - the silence before it let go of - and suspended
after five seconds of nothing but silence, so that the device can rest
its radio. A device that suspends the stream itself stays suspended
until a new sound begins after a second of silence.

**The volume** is set on a device that takes an absolute volume (AVRCP
1.4 and later). The driver serves PSM 23 - a listener for the control
channels of bonded devices, and a record of this machine as a remote
control's controller (0x110E, for an amplifier) - takes the channel the
device opens, or opens it a second after the stream opened, and asks
what the device has. A device with the volume's event has the output's
volume - `Audio VOLUME`, Prefs - set on it as the same share of its
loudest as the volume's percent is of a hundred, and the sound leaves at
full scale; past 100% the device is at its loudest and the sound
carries the rest. A volume changed on the device - its buttons - becomes
the output's volume, as `Audio LIST` shows it. A device without it, or
without the channel, has the volume in the sound, on top of its own.
Its commands as a controller - of a player - are answered as not
implemented. The log says which it is - `the volume set on the device`,
or `takes no absolute volume: the volume in the sound` - and, at
`C:Log LEVEL debug`, each volume set on the device and each changed
there.

**Pairing one** makes its bond over BR/EDR, where its sound goes: a
headphone that advertises over LE as well - a scan hears it so - is
paired with `Bluetooth PAIR <device> BREDR`.

**A bond made before the driver** keeps no service for it: the binder
offers a device's services as it bonds, so a device bonded while
`btaudio.device` was not on the disk is driven once it is paired again
(`Bluetooth UNPAIR`, then `PAIR`). The same goes the other way: a device
that keeps the records it read as it paired - a computer, say - knows
the controller's record, and offers its volume, once it pairs again.

The log says each stream's configuration -
`SBC at 48000 Hz, joint stereo, bitpool 53, 8 frames a packet, 357 kbit/s` -
and, at `C:Log LEVEL debug`, each delay the device reports, the buffers
waiting as the stream starts, and at each pause the packets sent and
not, how far apart two were at the most, and the buffers missed.

```
1> Bluetooth PAIR 00:00:5E:EF:10:52
Pairing with 00:00:5E:EF:10:52 over BR/EDR; CTRL-C stops
Does Speaker show 391197? (y/n) y
Paired with Speaker
1> Audio LIST
HDMI                 8AD3078F  two sides, 44100 48000 Hz, volume 71%, playing
Speaker              BD79EC89  two sides, 48000 Hz, volume 71%
null                 24B61A00  two sides, 44100 48000 Hz, volume 26%
1> Audio PREFER Speaker
1> Play Work:lr44.wav
```

## Controllers on USB

`usb/bluetooth.device` drives the interface of USB's Bluetooth class
(wireless controller, radio frequency, Bluetooth: 224/1/1) that has an
interrupt endpoint in and bulk endpoints in and out - commands go on the
control endpoint as class requests, events come on the interrupt
endpoint, ACL data on the bulk ones. It takes up to four controllers at
once, a unit each; its ROM tag lists no units, since they come and go
with what is plugged in.

A controller plugged in is set up on the device's worker, its unit
opened to the stack when it is ready, and offered to bluetooth.library.
The packets that come are put together from the endpoints' transfers and
kept, eight at most, until the stack reads them: while none is read, the
endpoints are not asked for more, and the controller holds what it has.
Unplugged, the unit is taken from the library and every request it held
is answered `HCIERR_DETACHED`.

**A MediaTek MT79xx** - the MT7922 card's Bluetooth, a USB device of its
own beside the card's Wi-Fi on PCI Express - is no controller until its
RAM code is in. The device asks the chip which it is, reads the file the
chip wants from `DEVS:usb/firmware/mediatek/`
(`BT_RAM_CODE_MT7922_1_1_hdr.bin` for the MT7922), gives it to the chip
section by section with the chip's own WMT commands, and switches its
Bluetooth on. A chip that has its firmware already - its controller let
go of and taken again, or the machine restarted with its power on - is
sent none of it. Without the file the controller stays a
USB device that nothing uses, and the log says which file was missing.

`scripts/fetch-mt7922.sh` fetches the file with the Wi-Fi's, at a pinned
commit of linux-firmware, checked against its sha256, with MediaTek's
licence; the 64-bit machines' disks have them.

## The Raspberry Pi 4 Model B's controller

The board's radio, an Infineon CYW43455, has its Bluetooth as a
controller of its own beside the Wi-Fi: on the BCM2711's mini UART (GPIO
32 and 33 for the data, 30 and 31 for CTS and RTS, each in its ALT5
function), its power on line 0 of the firmware's GPIO expander
(BT_REG_ON), which the VideoCore's mailbox switches. The PL011 stays the
console on the header's pins 8 and 10 (`dtoverlay=disable-bt` in
`config.txt`). The board's system tag list has it as a
`PARTKIND_BLUETOOTH` part with `CHIP_CYW43455` on `BUS_UART`, with the
UART's registers and interrupt, its four pins and the power line.

`bluetooth/cyw43455bt.device` sets it up on a worker of its own:

1. The pins given to the mini UART, the line started at 115200 bit/s
   with RTS held up, and the controller's power taken away for 50 ms and
   given back, with 120 ms for it to start: a controller that finds its
   CTS asserted as it starts would wait to learn the line's rate from
   the first command.
2. RTS and CTS handed to the mini UART - RTS let go when its receive FIFO
   has four places left, the transmitter held while the controller's RTS
   is up - so that a late interrupt costs time and no bytes. Both are
   asserted low, which the mini UART is told: by itself it asserts its
   own high.
3. A reset, the line raised to 921600 bit/s on both ends (919117 from
   the core clock), and the controller asked what it is: an LMP
   subversion of 0x6119 is a BCM4345C0.
4. Its patch, `DEVS:bluetooth/firmware/broadcom/BCM4345C0.hcd`, given
   command by command - Download Minidriver, then the file's Write RAM
   commands and its Launch RAM, each waiting for its answer. The patched
   controller starts again at 115200 bit/s, and is reset and raised to
   the working rate again. Without the file it runs the firmware in its
   ROM, and the log says which file was missing.
5. Its address: the one the VideoCore's firmware writes into the device
   tree (`local-bd-address`), which the kernel hands to the board's part
   (`PART_StationAddress`). It outlasts the reset the library brings the
   controller up with.

The mini UART counts its rate from the chip's core clock, which the
firmware lowers while the chip is idle unless `config.txt` holds it:
`core_freq_min=500` keeps it at 500 MHz. The packets in are put together
from the bytes the interrupt takes - the Broadcom controller's own kinds
of packet passed over - and kept, eight at most, while none is read;
the packets out go one at a time.

**The radio is shared** with the board's Wi-Fi, which takes turns with
the Bluetooth at the air of 2.4 GHz. `networks/cyw43455.device` keeps its
radio awake - no power saving - and while its station is on a 2.4 GHz
channel, most of the LE links the controller makes are not established:
the device never hears from it on them, and the controller gives each up
after six of its connection events (`HCI_ERR_FAILED_TO_ESTABLISH`,
0x3E), as `ConnectBTDevice` and `PairBTDevice` then say. With the
station on 5 GHz the two do not meet, and the links come up.

`scripts/fetch-cyw43455.sh` fetches the patch with the Wi-Fi's firmware,
at a pinned commit of Raspberry Pi's bluez-firmware package, checked
against its sha256, with the licence that package names for it
(`LICENCE.cypress`, from linux-firmware); the BCM2711 boards' disk has
them.

## SYS:System/Bluetooth

`SYS:System/Bluetooth` sets the controllers and finds the devices
around in a window (`SYS:System/Docs/Bluetooth.md`). A chooser picks the
controller, and the line under it says where it is: being set up,
failed and why, off, or on - and whether devices that search find this
one, counted down where `Bluetooth VISIBLE <seconds>` made it visible
for a while. **On**, **Name** and **Visible to others** set it as
`BTCA_Powered`, `BTCA_Name` and `BTCA_Visible` do; the library keeps
them for the next start. The list holds the controller's bonds, its
links and what its last **Search** found - ten seconds of
`StartBTDiscovery` - one line a device: its name, what it is
(`BTDeviceKind`), the signal it was heard with, its state - paired,
connected, encrypted, the drivers that drive it - and its address. A
device reached over BR/EDR and over LE at one address is one line.

The window is an agent while it runs (`AddBTAgent` with
`BTIO_KEYBOARDDISPLAY`): **Pair** begins a pairing with the device
picked (`PairBTDevice`), and the pairings devices begin are answered
there too. What a pairing asks opens a window of its own - the number to
compare, with Yes and No; a field for the passkey the device shows, or
for a PIN; the number to type on the device; whether a device with
nothing to compare may pair - which closes at the pairing's end
(`BTAK_DONE`), the line saying how it ended. **Connect**,
**Disconnect** and **Forget...** call `ConnectBTDevice`,
`DisconnectBTDevice` and `UnpairBTDevice` - Forget once a requester has
asked - on a process of the window's own, "Bluetooth worker", one call
at a time, so that the window draws and answers the pairings while a
device is paged or does not answer. A double click pairs with a device
without a bond and connects to a bonded one without a link.

The window follows the library through `AddBTNotify`: whatever changes,
it lists again - twice a second at the most - and hands the list gadget
new rows only where one differs from what it shows.

## C:Bluetooth

```
1> Bluetooth
0: 00:00:5E:EF:10:42  up, on  usb/bluetooth.device unit 0
1> Bluetooth INFO
0: 00:00:5E:EF:10:42  up, on  usb/bluetooth.device unit 0
  chip        MediaTek MT7922
  firmware    BT_RAM_CODE_MT7922_1_1_hdr.bin (20261027203403)
  bus         USB
  HCI         5.3, revision 10016
  LMP         5.3, subversion 9744
  made by     MediaTek (70)
  radio       BR/EDR and LE
  ACL         6 packets of 1021 bytes; SCO 8 of 240
  LE ACL      32 packets of 251 bytes
  features    EDR 2 Mbit/s EDR 3 Mbit/s eSCO Secure Simple Pairing
              (on) Secure Connections extended inquiry sniff subrating
              LE encryption LE data length LE privacy LE 2M PHY
              LE Coded PHY extended advertising
  name        poweros
  class       000104
```

`Bluetooth` lists the controllers: number, address - dashes until the
controller has said it - state, and once it is up whether it is on or
off, visible - for how long more - and looking, and the device and unit
each is. `INFO`
adds what each is: the chip and firmware its device gave it, how it is
reached - USB, or a UART and its rate - the versions of its HCI and link
manager and who made it, its buffers, what it can do of note - `(on)`
after Secure Simple Pairing when the stack has switched it on - its name
and its class (`000104`: a desktop computer).

The Raspberry Pi 4 Model B's, the first time it is asked - its device
still setting the controller up - and a moment later:

```
1> Bluetooth
0: --:--:--:--:--:--  opening  bluetooth/cyw43455bt.device unit 0
1> Bluetooth INFO
0: 00:00:5E:EF:10:46  up, on  bluetooth/cyw43455bt.device unit 0
  chip        Infineon CYW43455 (BCM4345C0)
  firmware    BCM4345C0.hcd (build 0382)
  bus         UART, 919117 bit/s
  HCI         5.0, revision 382
  LMP         5.0, subversion 24857
  made by     Cypress (305)
  radio       BR/EDR and LE
  ACL         8 packets of 1021 bytes; SCO 1 of 64
  LE ACL      7 packets of 251 bytes
  features    EDR 2 Mbit/s EDR 3 Mbit/s eSCO Secure Simple Pairing
              (on) Secure Connections extended inquiry sniff subrating
              LE encryption LE data length
  name        poweros
  class       000104
```

Set, and looking:

```
1> Bluetooth NAME Desk VISIBLE 120
0: 00:00:5E:EF:10:42  up, on, visible for 120 s  usb/bluetooth.device unit 0
1> Bluetooth SCAN INFO
Looking for about 10 s, then for the names; CTRL-C stops
  F2:03:00:00:10:01  LE random   -32 dBm  Sensor
  00:00:5E:EF:10:43  BR/EDR      -42 dBm  poweros                   computer
2 found

  F2:03:00:00:10:01  LE random   -32 dBm  Sensor
      controller 0, heard 10852 ms ago, connectable
      service 6E400001-B5A3-F393-E0A9-E50E24DCCA9E

  00:00:5E:EF:10:43  BR/EDR      -42 dBm  poweros                   computer
      controller 0, heard 6725 ms ago, class 000104
```

`POWER ON` or `OFF`, `NAME` and `VISIBLE` - `ON` until told otherwise,
`OFF`, or a number of seconds - set the controllers
(`SetBTControllerAttrs`), which are then listed; `NAME ""` gives a
controller the machine's name again.

`SCAN` makes them look (`StartBTDiscovery`) for about `TIME` seconds -
ten without - and shows each device as it is found: its address, how it
was heard (`BR/EDR`, `LE`, `LE random` for an LE device's random
address, `BR/EDR+LE` for one heard both ways), its signal, its name -
`-` until one has come, `(no name)` for one that was asked and has none -
and what it is, by its class of device or its LE appearance. A device
is shown again when its name comes, and when its whole name comes after
a shortened one. After the inquiry, the names not yet heard are asked
for; CTRL-C stops it all. With `INFO`, what each device said of itself
follows: its whole name where its line has no room for it, the
controller that heard it and how long ago, its class and appearance,
the power it sends at, whether it takes connections, its maker, and its
services, named where they are well known.

Linked:

```
1> Bluetooth CONNECT 00:00:5E:EF:10:43
Connecting to 00:00:5E:EF:10:43 over BR/EDR
  00:00:5E:EF:10:43  BR/EDR     central          0 s
1> Bluetooth LIST INFO
  00:00:5E:EF:10:43  BR/EDR     central         19 s  poweros
      made by this machine, not encrypted; controller 0, handle 51
1> Bluetooth DISCONNECT poweros
Disconnected from 00:00:5E:EF:10:43
1> Bluetooth CONNECT 00:00:5E:EF:10:44 LE
Connecting to 00:00:5E:EF:10:44 over LE
  00:00:5E:EF:10:44  LE         central          0 s
1> Bluetooth LIST INFO
  00:00:5E:EF:10:44  LE         central          6 s
      made by this machine, not encrypted; controller 0, handle 512
      every 48.75 ms, latency 0, lost after 420 ms unheard
```

and the other end of the first link, the machine that was paged:

```
1> Bluetooth LIST INFO
  00:00:5E:EF:10:42  BR/EDR     peripheral      19 s  poweros
      made by the device, not encrypted; controller 0, handle 11, class 000104
```

`CONNECT` makes a link to a device (`ConnectBTDevice`) and shows it once
it is up: the device by its address, written as `Bluetooth` shows one,
or by a name a `SCAN` heard. The link is over LE for a device the scan
heard over LE, and for an address given with `LE` - its public address -
or `RANDOM` - its random one; over BR/EDR otherwise, and with `BREDR`
for a device the scan heard over LE too, as a headphone that advertises
as well is heard. A link not made
says why: the device did not answer, did not answer in time - an LE
device that does not advertise - or refused, the controller is making
another such link, or what the controller answered. A link to a device
with a bond that could not be made secure is up still, and says so and
why: the device has no key for this machine any more, or did not take
it. `DISCONNECT` ends
the link to a device, by its address or its name (`DisconnectBTDevice`),
with `LE`, `RANDOM` or `BREDR` its link of that kind.

`LIST` shows the links (`ObtainBTConnections`): the device's address,
the kind of link - `BR/EDR`, `LE`, `LE random` - which side the
controller is, how long the link has been up, and the device's name;
with `INFO`, who made it, whether it is encrypted, its controller and
handle, the device's class, and an LE link's interval, latency and how
long it lasts unheard.

Paired - the one machine answering with `AGENT`, the other pairing:

```
1> Bluetooth AGENT
Answering the pairings devices begin; CTRL-C stops
Does poweros show 492187? (y/n) y
Paired with poweros
```

```
1> Bluetooth PAIR 00:00:5E:EF:10:43
Pairing with 00:00:5E:EF:10:43 over BR/EDR; CTRL-C stops
Does poweros show 492187? (y/n) y
Paired with poweros
1> Bluetooth PAIR Sensor
Pairing with 00:00:5E:EF:10:44 over LE; CTRL-C stops
Type 058213 on 00:00:5E:EF:10:44
Paired with 00:00:5E:EF:10:44
1> Bluetooth BONDS INFO
  00:00:5E:EF:10:43  BR/EDR     confirmed    poweros
      controller 0, class 000104, key type 8, Secure Connections
  00:00:5E:EF:10:44  LE         confirmed    Sensor
      controller 0, a key of 16 bytes, Secure Connections, its identity kept
1> Bluetooth LIST INFO
  00:00:5E:EF:10:43  BR/EDR     central         12 s  poweros
      made by this machine, encrypted, authenticated, bonded; controller 0, handle 51
```

`PAIR` makes a bond with a device (`PairBTDevice`), by its address or a
name a `SCAN` heard - over LE where `CONNECT` would link over LE, a
device a scan heard over LE without `BREDR` or an address with `LE` or
`RANDOM` - and asks here what the pairing needs:
whether the device shows the same number - `y` or `n` - the number it
shows, its PIN - `PIN` gives that beforehand - or it shows a number to
type on the device. It ends when the pairing is over, saying why one
failed; CTRL-C stops it. `AGENT` answers the pairings devices begin the
same way, until CTRL-C. `BONDS` lists the bonds (`ObtainBTBonds`): the
device's address, the kind of link the bond is for, how its pairing was
confirmed - `confirmed`, `unconfirmed`, or `PIN` - and its name; with
`INFO`, the controller, the device's class where the pairing learned it -
a link the device made says it - the kind of its key, or an LE key's
size, whether it was made with Secure Connections, whether the device
gave its identity, and the profile drivers that drive it. `UNPAIR` ends
a bond, by the device's address or name (`UnpairBTDevice`) - with `LE`,
`RANDOM` or `BREDR` the bond of that kind, for a device with two - a
driver that drives the device telling it first.

What a device offers:

```
1> Bluetooth SERVICES 00:00:5E:EF:10:47 INFO
Asking 00:00:5E:EF:10:47 for its services
  generic access                PSM 31       Generic Access Profile
      no profile, record 00010001, 165 bytes
  remote control target         PSM 23       AVRCP TG
      remote control 1.6, record 00010005, 102 bytes
  hands-free audio gateway      RFCOMM 13    Hands-Free Voice gateway
      hands-free 1.9, record 00010006, 99 bytes
  audio source                  PSM 25       Audio Source
      advanced audio 1.4, record 00010008, 83 bytes
  object push                   RFCOMM 9     Object Push
      object push 1.2, record 00010012, 102 bytes
```

Over LE:

```
1> Bluetooth SERVICES 00:00:5E:EF:10:51 LE INFO
Asking 00:00:5E:EF:10:51 for its services over LE
  PDUs of up to 517 bytes
  generic access                handles 0001-0005
      device name                     0003  read
      appearance                      0005  read
  generic attribute             handles 0006-000F
      service changed                 0008  indicate, a descriptor
      client supported features       000B  read, write
      database hash                   000D  read
  device information            handles 0010-0012
      PnP ID                          0012  read
  5F1E0000-7A3C-4B8E-9D21-6C0E5A4B3F10  handles 001D-0024
      5F1E0001-7A3C-4B8E-9D21-6C0E5A4B3F10  001F  read
      5F1E0002-7A3C-4B8E-9D21-6C0E5A4B3F10  0021  read, write, write without answer
      5F1E0003-7A3C-4B8E-9D21-6C0E5A4B3F10  0023  read, notify, indicate, a descriptor
```

`SERVICES` asks a device what it offers (`ObtainBTServices`), by its
address or a name a `SCAN` heard: each service on a line - what it is,
named where it is well known, else its UUID - where it is reached, and
its own name. Over BR/EDR it asks the device's SDP server, a service
reached by a PSM or an RFCOMM channel, and with `INFO` says its profile
and the profile's version, and its record's handle and size. Over LE -
for a device a scan heard over LE alone, without `BREDR`, or with `LE`
or `RANDOM` - it asks the device's GATT server over one block
(`OpenBTGatt`), a service being a run of handles; with `INFO` it says
the link's MTU and each service's characteristics
(`ObtainBTCharacteristics`): what each is, its value's handle - the one
`C:test/BTGatt` takes - what may be done with it, and how many
descriptors it has.

`CONTROLLER` makes any of these for one controller, by its number;
without it, they are for every one - for `CONNECT`, `PAIR` and
`SERVICES`, the one with a link to the device, else the one whose scan
found it, else the first that is on.

## C:test/BTEcho

```
1> C:test/BTEcho
Serving PSM 8193; CTRL-C stops
00:00:5E:EF:10:47 opened a channel, frames of 672 bytes each way at most
00:00:5E:EF:10:47 closed its channel
***Break
1> C:test/BTEcho TO 00:00:5E:EF:10:47
Opening a channel to PSM 8193 of 00:00:5E:EF:10:47
Open, frames of 672 bytes each way at most; each line typed is sent, CTRL-C stops
hello
< hello
***Break
```

`BTEcho` serves a PSM (`AddBTListener`) - 8193 (0x2001) without `PSM` -
and sends each frame of each channel a device opens to it back as it
came, eight channels at once, until CTRL-C. With `TO` it opens a channel
to a device's PSM (`OpenBTChannel`), by its address: each line typed
goes as a frame, without its end of line, and each frame that comes is
shown after `<`, until CTRL-C or the device closes it. `CONTROLLER`
names the controller, as `Bluetooth`'s does. A device that wants its
links encrypted takes a channel from a machine it has a bond with
(`Bluetooth PAIR`).

## C:test/BTGatt

```
1> C:test/BTGatt 00:00:5E:EF:10:51 READ 001F
Opening GATT to 00:00:5E:EF:10:51
Open, PDUs of up to 517 bytes
001F: 300 bytes
  0000  76 61 6C 75 65 20 30 30 30 20 76 61 6C 75 65 20  value 000 value
  0010  30 30 31 20 76 61 6C 75 65 20 30 30 32 20 76 61  001 value 002 va
...
1> C:test/BTGatt 00:00:5E:EF:10:51 WRITE 0021 TEXT hello
Opening GATT to 00:00:5E:EF:10:51
Open, PDUs of up to 517 bytes
0021: 5 bytes written
1> C:test/BTGatt 00:00:5E:EF:10:51 WATCH 0023 INDICATE
Opening GATT to 00:00:5E:EF:10:51
Open, PDUs of up to 517 bytes
Watching 0023, indicated; CTRL-C stops
0023: 01  .
0023: 02  .
***Break
1> C:test/BTGatt 00:00:5E:EF:10:51 WATCH 0023 WAIT
Waiting for 00:00:5E:EF:10:51; CTRL-C stops
Open, PDUs of up to 517 bytes
Watching 0023, notified; CTRL-C stops
0023: 01  .
0023: 02  .
The link ended (the device ended the link): waiting
Open, PDUs of up to 517 bytes
0023: 03  .
***Break
```

`BTGatt` opens a block to an LE device (`OpenBTGatt`) - by its address,
public or with `RANDOM` random, or a name a `SCAN` heard - and does one
thing with an attribute, its handle written in hexadecimal as
`Bluetooth SERVICES <device> INFO` shows it. `READ` reads the value
(`ReadBTAttribute`) and shows it in rows of 16 bytes, in hexadecimal and
as text. `WRITE` writes the bytes `DATA` gives in hexadecimal - `0100`,
or `01:00` - or `TEXT`'s characters (`WriteBTAttribute`), with
`NORESPONSE` as a Write Command. `WATCH` finds the characteristic whose
value has that handle, subscribes to it (`SubscribeBTAttribute`) -
notified, or with `INDICATE` indicated - and shows each value as it
comes, until CTRL-C or the link ends. With `WAIT` the block waits for
the device (`BTGO_WAIT`): `READ` and `WRITE` are done once the device is
reached, and `WATCH` goes on across the link's ends, each end and each
open shown, the subscription written again at each. `CONTROLLER` names
the controller, as `Bluetooth`'s does. A value that wants the link
encrypted is read once the two have a bond (`Bluetooth PAIR`).

## C:test/BTHidDevice

```
1> C:test/BTHidDevice
A keyboard and a mouse, waiting for a bonded host's channels; CTRL-C stops
00:00:5E:EF:10:43 connected; each line typed is sent
hello
CAPS
LEDs: Num Lock off, Caps Lock on, Scroll Lock off
MOVE 20 -10
The host unplugged: its channels closed
***Break
1> C:test/BTHidDevice TO 00:00:5E:EF:10:43
Opening the channels to 00:00:5E:EF:10:43
Connected; each line typed is sent, CTRL-C stops
```

`BTHidDevice` makes this machine a keyboard and a mouse over BR/EDR, for
a host to be tried with. It adds a HID record of its own
(`AddBTService`), its report descriptor a keyboard's and a mouse's, and
takes a bonded host's channels to PSMs 17 and 19 (`AddBTListener` with
`BTLSF_SECURE`), until CTRL-C. With `TO` it opens the channels to the
host itself, control first, as a keyboard reconnects, until CTRL-C or
the host closes them. Each line typed goes as key presses, a key down
and up for each character - letters, digits, the space and `-=;,./`, as
a US keyboard has them - without its end of line; `MOVE <x> <y>` moves
the pointer by -127 to 127 each way, `CLICK` presses and lets go of the
first button, `CAPS` presses Caps Lock. The LEDs the host sends back are
shown, and so is the host's `VIRTUAL_CABLE_UNPLUG`, which closes the
channels. The host pairs with this machine first - `Bluetooth AGENT`
here answers it - and bthid.device here drives no keyboard (Keyboards
and mice, above). `CONTROLLER` names the controller, as `Bluetooth`'s
does.

## C:test/BTAudio

```
1> C:test/BTAudio 00:00:5E:EF:10:52 TONE 1000 SECONDS 30
Opening the stream to 00:00:5E:EF:10:52
The device's delay: 0.0 ms
Sink end point 10: SBC at 48000 Hz, joint stereo, 16 blocks, 8 subbands, loudness, bitpool 53
Frames of 119 bytes, 8 to a packet (the media channel takes 1021 bytes), 357 kbit/s
Playing; CTRL-C stops
The device's delay: 56.0 ms
The device's delay: 50.6 ms
1407 packets sent, 0 dropped; the latest left 0.4 ms after its time
1> C:test/BTAudio 00:00:5E:EF:10:52 FILE Work:lr44.wav
Work:lr44.wav: 44100 Hz, stereo
Opening the stream to 00:00:5E:EF:10:52
The device refused the channel; trying again
Sink end point 10: SBC at 44100 Hz, joint stereo, 16 blocks, 8 subbands, loudness, bitpool 53
Frames of 119 bytes, 8 to a packet (the media channel takes 1021 bytes), 327 kbit/s
Playing; CTRL-C stops
The device's delay: 57.4 ms
345 packets sent, 0 dropped; the latest left 0.4 ms after its time
```

`BTAudio` plays a sound to a headphone or a speaker bonded with this
machine over BR/EDR, by its address, without audio.device: a file
audiocodec.library reads, at its own rate - 16, 32, 44.1 or 48 kHz -
a mono one on both sides, or with `TONE` a sine of that frequency at
-20 dBFS on both sides, 1000 Hz where neither is given. `SECONDS` says
how long: a tone 10 seconds where it is not given, a file to its end.
It opens the stream (Sound to a headphone, above), says the end point
and the configuration taken - the rate, the channel mode, blocks,
subbands, the allocation and the bitpool - the frame's length, the
frames to a packet, the bytes the media channel takes and the bit rate,
and each delay the device reports, and follows a device that suspends
the stream and starts it again. The packets go as the sound's time
passes, on timer.device's E-clock, two ahead of it; the stream is
closed once the last has played - after the delay the device reported,
or 150 ms - and the packets sent and dropped are said, and how late the
latest was handed on. A device that refuses the signalling channel is
asked again, two seconds later, four times in all: one opening its own
channel to this machine meanwhile - as a computer does to a source it
knows, as the link comes up - refuses this one. CTRL-C stops;
`CONTROLLER` names the controller, as `Bluetooth`'s does. The device is
paired with first (`Bluetooth PAIR`). A device `btaudio.device` drives
has a stream of the driver's open, so `BTAudio` is for one it does not
drive.
