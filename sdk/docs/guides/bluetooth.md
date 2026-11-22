# Bluetooth

A Bluetooth controller is a radio with its own processor: it is spoken to
in HCI packets - commands and data go to it, events and data come from
it - over whatever carries them, USB or a UART. `bluetooth.library`, in
`LIBS:`, is the stack above the controllers: it is given each one by the
device that drives it, brings it up and keeps what it learned, and tells
the programs that asked when a controller comes, goes or changes.

The library brings controllers up and lists them. It does not yet look
for devices, pair with them or connect to them: those are the stack's
next parts.

This guide is the pieces first, then what a controller device is, how a
controller is brought up, listing the controllers from a program, the USB
controllers and the MediaTek MT7922's firmware, and `C:Bluetooth`.

## The pieces

```
 programs          C:Bluetooth                    a program
                          \                          /
                    ObtainBTControllers, AddBTNotify
 the stack          bluetooth.library: its own task, every controller's
                    HCI traffic, the bring-up
                          |  CMD_READ, CMD_WRITE, HCICMD_QUERY (DEVIF_HCI)
 the controllers    usb/bluetooth.device: a unit per controller plugged in,
                    the MT79xx's setup and firmware
                          |  AddBTController, RemBTController
                          |  pipes (usb.library)
 the bus            usb.library, xhci.device
```

| Piece | Where | What it is |
|---|---|---|
| `bluetooth.library` | `LIBS:` | the stack: the controllers it is given, brought up and listed, and the programs told when they change ([bluetooth](../autodocs/bluetooth.md)) |
| `usb/bluetooth.device` | `DEVS:usb/` | Bluetooth controllers on USB as HCI units, a unit a controller; a class driver |
| `DEVS:usb/firmware/mediatek/` | | the MediaTek MT7922's Bluetooth firmware and MediaTek's licence for it, from `scripts/fetch-mt7922.sh` (the 64-bit machines' disks) |
| `C:Bluetooth` | | the controllers, and with `INFO` what each is |

The library, the device, the firmware and the command are the disk's
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
if (bt.AddBTController("usb/bluetooth.device", unit_number) != 0) {
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
   and SCO data, its address; for LE, its LE buffers (none of its own:
   it shares the BR/EDR ones) and its LE features.
2. **What it is to tell**: the events the stack takes, BR/EDR's and LE's,
   chosen by what it can do.
3. **What it is to be**: Secure Simple Pairing on, LE host support on a
   controller with BR/EDR and LE both, its class of device (a desktop
   computer), and its name: the machine's, the first line of
   `ENVARC:Sys/net/hostname`, or `PowerOS` without one.

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
`BTCS_OPENING`, `BTCS_STARTING` while it is brought up, `BTCS_UP`, or
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

## C:Bluetooth

```
1> Bluetooth
0: 00:00:5E:EF:10:42  up  usb/bluetooth.device unit 0
1> Bluetooth INFO
0: 00:00:5E:EF:10:42  up  usb/bluetooth.device unit 0
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
  name        PowerOS
  class       000104
```

`Bluetooth` lists the controllers: number, address, state and the device
and unit each is. `INFO` adds what each is: the chip and firmware its
device gave it, the versions of its HCI and link manager and who made
it, its buffers, what it can do of note - `(on)` after Secure Simple
Pairing when the stack has switched it on - its name and its class
(`000104`: a desktop computer).
