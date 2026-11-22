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
controllers and the MediaTek MT7922's firmware, the Raspberry Pi 4 Model
B's controller, and `C:Bluetooth`.

## The pieces

```
 programs          C:Bluetooth                    a program
                          \                          /
                    ObtainBTControllers, AddBTNotify
 the stack          bluetooth.library: its own task, every controller's
                    HCI traffic, the bring-up
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
| `bluetooth.library` | `LIBS:` | the stack: the controllers it is given, brought up and listed, and the programs told when they change ([bluetooth](../autodocs/bluetooth.md)) |
| `usb/bluetooth.device` | `DEVS:usb/` | Bluetooth controllers on USB as HCI units, a unit a controller; a class driver |
| `DEVS:usb/firmware/mediatek/` | | the MediaTek MT7922's Bluetooth firmware and MediaTek's licence for it, from `scripts/fetch-mt7922.sh` (the 64-bit machines' disks) |
| `bluetooth/cyw43455bt.device` | `DEVS:bluetooth/` | the Raspberry Pi 4 Model B's controller - the Bluetooth of its CYW43455, on the BCM2711's mini UART - as an HCI unit (the BCM2711 boards' disk) |
| `DEVS:bluetooth/firmware/broadcom/` | | the CYW43455's Bluetooth patch, `BCM4345C0.hcd`, and the licence for passing it on, from `scripts/fetch-cyw43455.sh` (the BCM2711 boards' disk) |
| `C:Bluetooth` | | the controllers, and with `INFO` what each is |

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

`scripts/fetch-cyw43455.sh` fetches the patch with the Wi-Fi's firmware,
at a pinned commit of Raspberry Pi's bluez-firmware package, checked
against its sha256, with the licence that package names for it
(`LICENCE.cypress`, from linux-firmware); the BCM2711 boards' disk has
them.

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

`Bluetooth` lists the controllers: number, address - dashes until the
controller has said it - state and the device and unit each is. `INFO`
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
0: 98:FE:54:CF:67:48  up  bluetooth/cyw43455bt.device unit 0
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
  name        PowerOS
  class       000104
```
