# Bluetooth

A Bluetooth controller is a radio with its own processor: it is spoken to
in HCI packets - commands and data go to it, events and data come from
it - over whatever carries them, USB or a UART. `bluetooth.library`, in
`LIBS:`, is the stack above the controllers: it is given each one by the
device that drives it, brings it up and keeps what it learned, and tells
the programs that asked when a controller comes, goes or changes.

The library brings controllers up, lists them, sets them - on or off,
their name, whether others find them - finds the devices around them,
makes links to them and takes the links they make, and pairs with them
over BR/EDR and LE, keeping the bonds. A link carries nothing but what
the link itself needs and its pairing: the protocols over a link are
the stack's next part.

This guide is the pieces first, then what a controller device is, how a
controller is brought up, listing the controllers from a program, a
controller's settings, finding devices, links to devices and what a
link carries, pairing and bonds, the USB controllers and the MediaTek
MT7922's firmware, the Raspberry Pi 4 Model B's controller, and
`C:Bluetooth`.

## The pieces

```
 programs          C:Bluetooth                    a program
                          \                          /
           ObtainBTControllers, SetBTControllerAttrs, AddBTNotify,
           StartBTDiscovery, ObtainBTDevices, ConnectBTDevice,
           DisconnectBTDevice, ObtainBTConnections, AddBTAgent,
           PairBTDevice, UnpairBTDevice, ObtainBTBonds
 the stack          bluetooth.library: its own task, every controller's
                    HCI traffic, the bring-up, the settings, the
                    discoveries, the links and their data, the pairings
                    and the bonds
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
| `bluetooth.library` | `LIBS:` | the stack: the controllers it is given, brought up, listed and set, the devices they find, the links to them and the bonds with them, and the programs told when they change ([bluetooth](../autodocs/bluetooth.md)) |
| `ENVARC:Sys/bluetooth/` | | each controller's settings and bonds, kept by its address |
| `usb/bluetooth.device` | `DEVS:usb/` | Bluetooth controllers on USB as HCI units, a unit a controller; a class driver |
| `DEVS:usb/firmware/mediatek/` | | the MediaTek MT7922's Bluetooth firmware and MediaTek's licence for it, from `scripts/fetch-mt7922.sh` (the 64-bit machines' disks) |
| `bluetooth/cyw43455bt.device` | `DEVS:bluetooth/` | the Raspberry Pi 4 Model B's controller - the Bluetooth of its CYW43455, on the BCM2711's mini UART - as an HCI unit (the BCM2711 boards' disk) |
| `DEVS:bluetooth/firmware/broadcom/` | | the CYW43455's Bluetooth patch, `BCM4345C0.hcd`, and the licence for passing it on, from `scripts/fetch-cyw43455.sh` (the BCM2711 boards' disk) |
| `C:Bluetooth` | | the controllers - listed, with `INFO` what each is, and set - the devices around them (`SCAN`), the links to them (`CONNECT`, `DISCONNECT`, `LIST`), and the bonds (`PAIR`, `UNPAIR`, `BONDS`, `AGENT`) |

The library, the devices, their firmware and the command are the disk's
`bluetooth` set.

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
says what of the setup failed. Nothing opens the library at the start, so
a board's controller comes up with the first program that does -
`C:Bluetooth`, for one.

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
found, a name it heard; a link up or down. It says that something changed, not what, and
changes close together may come as one.

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
  advertise within 20 seconds is given up on (`BTERR_TIMEOUT`).

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
put together again from the packets it hands up. On the signalling
channel the library answers what a device asks of any link: what it
supports - its fixed channels, the signalling one alone - and an echo.
A channel to a protocol is refused, there being none yet, and so is
LE's credit-based one. Over LE, a peripheral's wish for other
parameters is taken while they are within the specification's bounds
and the controller is the link's central; a request of the attribute
protocol is answered as not supported; the security manager's channel
is the pairing's (below). A device may end a link it has no use for.

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

A link to the device is made first where there is none. The two say
what their users can do, and that decides what is asked: where both can
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
`UnpairBTDevice` ends one: the key forgotten, its file deleted, a link
to the device ended. The device keeps its side until it is told
otherwise.

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
than 7 is refused. With Secure Connections - where the device has them
- each side makes a P-256 key pair and the two share a secret; the
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
`-` until one has come, `(no name)` for one that was asked and has none
- and what it is, by its class of device or its LE appearance. A device
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
heard over LE, and for an address given with `LE` - its public address
- or `RANDOM` - its random one; over BR/EDR otherwise. A link not made
says why: the device did not answer, did not answer in time - an LE
device that does not advertise - or refused, the controller is making
another such link, or what the controller answered. A link to a device
with a bond that could not be made secure is up still, and says so and
why: the device has no key for this machine any more, or did not take
it. `DISCONNECT` ends
the link to a device, by its address or its name (`DisconnectBTDevice`).

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
device a scan heard over LE or an address with `LE` or `RANDOM` - and
asks here what the pairing needs:
whether the device shows the same number - `y` or `n` - the number it
shows, its PIN - `PIN` gives that beforehand - or it shows a number to
type on the device. It ends when the pairing is over, saying why one
failed; CTRL-C stops it. `AGENT` answers the pairings devices begin the
same way, until CTRL-C. `BONDS` lists the bonds (`ObtainBTBonds`): the
device's address, the kind of link the bond is for, how its pairing was
confirmed - `confirmed`, `unconfirmed`, or `PIN` - and its name; with
`INFO`, the controller, the device's class where the pairing learned it
- a link the device made says it - the kind of its key, or an LE key's
size, whether it was made with Secure Connections, and whether the
device gave its identity. `UNPAIR` ends a bond, by the device's address
or name (`UnpairBTDevice`).

`CONTROLLER` makes any of these for one controller, by its number;
without it, they are for every one - for `CONNECT` and `PAIR`, the one
with a link to the device, else the one whose scan found it, else the
first that is on.
