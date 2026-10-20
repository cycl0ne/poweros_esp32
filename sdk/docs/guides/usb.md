# USB

A USB socket on a board is a bus: the machine's controller is its host, and
keyboards, mice, sticks and hubs are plugged into it and pulled out while
the system runs. `usb.library`, in `LIBS:`, runs a bus: it finds what is
plugged in, gives each device an address and a configuration, drives
the hubs itself, and hands every other interface to a class driver in
`DEVS:usb/`. A class driver is the device the rest of the system already
speaks to: a USB keyboard is keyboard.device's keyboard, so nothing
above it knows where the keys came from.

This guide is the bus first, then looking at what is on it, driving a
device from a program, writing a class driver, the drivers there are -
keyboards and mice, sticks, serial and Ethernet adapters, Wi-Fi sticks -
and writing a controller.

## The pieces

```
 above them             keyboard.device,   fat-handler      con-handler       bsdsocket.library  audio.device
                        mouse.device       on DU<n>:        on AUX2:, AUX3:   on usb0            (rta.library)
                             ^                  ^                ^                 ^                  ^
 class drivers,         usb/hid.device     usb/disk.device  usb/ftdi.device   usb/ecm.device     usb/uac.device
 DEVS:usb/                                                  usb/acm.device    usb/aic8800.device
                             |  USBClassBind, USBClassUnbind (DEVIF_USBCLASS)
 the bus                usb.library: a process per bus, hubs, pipes
                             |  DEVIF_USBHC: UHCMD_CONTROLXFER, ...
 the controller         usbotg.device (the chip's      xhci.device (xHCI on PCI),
                        DWC2), a unit per socket       a unit per controller
                             |  OwnUSBPort,                 |  ClaimPCIDevice
                             |  ReleaseUSBPort              |
 the port, PCI          usbport.resource (ROM):        pci.library: the
                        who holds the chip's ports     machine's PCI functions
                             |                              |
 the board              PARTKIND_USB in its system tag list, PARTKIND_PCI
```

| Piece | Where | What it is |
|---|---|---|
| `usbport.resource` | ROM | who holds each of the chip's USB ports, and which controller it is given to |
| `usbotg.device` | `DEVS:` | the chip's USB OTG controller as a host controller: transfers to devices on its bus, its root port answered as a hub; on the ESP32s' disks |
| `xhci.device` | `DEVS:` | xHCI controllers on PCI as host controllers - the VisionFive 2's VL805, QEMU's qemu-xhci - a unit per controller, its USB 2 root ports answered as a hub; on the RISC-V 64 disk |
| `pci.library` | `LIBS:` | the machine's PCI functions, among which xhci.device finds its controllers ([pci](../autodocs/pci.md)); on the RISC-V 64 disk |
| `usb.library` | `LIBS:` | the bus: devices, hubs, descriptors, pipes, binding, notification |
| `usb/hid.device` | `DEVS:usb/` | keyboards, mice and tablets, into keyboard.device and mouse.device |
| `usb/disk.device` | `DEVS:usb/` | sticks and card readers (mass storage, SCSI over Bulk-Only) as block devices, a drive `DU<n>:` each |
| `usb/ftdi.device` | `DEVS:usb/` | FTDI's serial chips as serial lines, with serial.device's API |
| `usb/acm.device` | `DEVS:usb/` | the communications class's serial lines (CDC-ACM), with serial.device's API |
| `usb/ecm.device` | `DEVS:usb/` | Ethernet adapters of the communications class (CDC-ECM) as a network device |
| `usb/aic8800.device` | `DEVS:usb/` | AIC8800 Wi-Fi sticks as a wireless network device, their firmware loaded from `DEVS:usb/firmware/aic8800/` |
| `usb/uac.device` | `DEVS:usb/` | speakers, headsets and sound adapters of the audio class as sound outputs, a sink of rta.library each, on a controller with isochronous transfers |
| `C:USB` | | starts and stops a bus |
| `C:USBInfo` | | lists what is on the buses, and who holds the ports |

## A bus

A bus is one of the board's USB sockets that may be a host: the
`PARTKIND_USB` parts of the board's system tag list with `USBROLE_HOST`,
numbered from 0 in the order the board lists them. Opening the library
starts nothing; `StartUSB` starts a bus, `StopUSB` stops it.

```sh
USB START          ; bus 0
USB STOP BUS 0
USB AUTO           ; every bus whose socket can only be a host
USB                ; which buses run
```

`S:Startup-Sequence` runs `USB AUTO` before the desktop comes up, so on a
board whose keyboard and mouse are USB - the ESP32-P4-PC, whose four
USB-A sockets are behind a hub, and the VisionFive 2 - they work from the
first picture on. A
socket that is also the console's - the ESP32-S3 boards', whose one USB
port is the serial console and the JTAG as the chip starts - is left to
`USB START` by hand.

**The ESP32-S3's port.** The chip has one USB port, GPIO19 and GPIO20,
and two controllers that can have it: USB-Serial-JTAG - the console and
the JTAG, whose it is as the chip starts - and the OTG controller.
`usbport.resource` keeps who holds it. usbserial.device bids for it at
the lowest priority; a bus that starts bids above it, the console lets
go between two of its writes, and the resource switches the port to the
OTG controller and sets its pads for a host. `USB STOP` gives it back.
While the bus has the port, the console and the JTAG are off the cable:
`USB START` typed on the USB console ends that session, and the bus is
reached through the board's other console or the screen. A board whose
socket's lines are shared with something else has them switched to the
port as the bus starts (`PART_PinSwitch`: the 7B's CAN transceiver).

```
1.System:> USBInfo PORTS
port 0: usbserial.device
1.System:> USB START
1.System:> USBInfo PORTS
port 0: usbotg.device
```

On the ESP32-P4 each controller has a port of its own - USB-Serial-JTAG
port 0, the full-speed OTG controller port 1, the high-speed one port 2
- and nothing is switched; the resource only keeps who holds which.

A controller on PCI has no port to share. xhci.device bids for none: its
root ports are its own, and its bus is the board's `PARTKIND_USB` part
on `BUS_PCI`, the nth xHCI function pci.library found (`PART_BusUnit`).

A started bus has a process of its own. It sets up the root hub, then
each device as it comes: the port debounced and reset, the device asked
at address 0 for its first eight bytes, given an address, asked for its
descriptors and its strings, and set to a configuration: the first of
its configurations with an interface some driver in `DEVS:usb/` takes,
or its first if none has. A hub is the library's own; every other
interface is offered to the class drivers. A device that goes takes everything that
hangs off it with it: each driver is told, the device leaves the list,
and its address is free again.

| Board | The socket | As a host |
|---|---|---|
| ESP32-P4-PC | four USB-A behind an FE1.1s hub, on the P4's high-speed controller | started at boot; the hub gives each socket its 5 V |
| CrowPanel | USB-C, wired as a device | - |
| 7B, ES3C35P | the console's USB-C | by hand (`USB START`), the console giving up the port; not yet tried on the boards |
| QEMU | the emulator's DWC2, with what `-Dusb` plugs in | started at boot |
| VisionFive 2 | four USB-A on the VL805, an xHCI controller on PCI Express port 0, their USB 2 lines through the VL805's own hub | started at boot; the hub, keyboards and mice work; USB 2 only, so a USB 3 device is reached at high speed |
| QEMU's RISC-V virt | qemu-xhci, with `-device qemu-xhci` on QEMU's command line | started at boot when the controller is there |

**Speeds.** The ESP32-S3's port and the P4's full-speed controller run
at full speed, 12 Mbit/s, a low-speed device on them at 1.5 Mbit/s. The
P4's high-speed controller runs at high speed, 480 Mbit/s, where what is
plugged in has it. Behind a high-speed hub - the ESP32-P4-PC's - a full-
or low-speed device, most keyboards and mice, is reached through the
hub's transaction translator: the controller sends it split
transactions, a packet at a time, and the hub talks to it at its own
speed. An xHCI controller's USB 2 root ports run at high, full or low
speed, as what is plugged in has it; its USB 3 ports are not driven, and
a USB 3 device is reached on its USB 2 half. Behind a high-speed hub,
xhci.device tells the controller which hub and port a full- or
low-speed device hangs off, and the controller does the split
transactions itself. `USBInfo` shows each device's speed.

## What is on it

`USBInfo` lists every device: its bus and address, the hub and port it
is plugged into, its speed, vendor and product, its name, and who drives
each of its interfaces. `USBInfo FULL` adds the interfaces and
endpoints.

```
bus addr hub port speed  id         class  device
  0    1   0    0 full   0000:0000  hub    DWC2 root hub
                                    interface 0: usb.library
  0    2   1    1 full   0409:55AA  hub    QEMU USB Hub, QEMU
                                    interface 0: usb.library
  0    3   2    1 full   0627:0001  -      QEMU USB Keyboard, QEMU
                                    interface 0: usb/hid.device
```

A program reads the same from the library's list, a `USBDevice` per
device, between `ObtainUSBDeviceList` and `ReleaseUSBDeviceList`. The
list is held shared: copy what is wanted and let go before printing, or
a device plugged in meanwhile waits.

```zig
const ub: *UsbBase = @ptrCast(sys.OpenLibrary(usb.USBNAME, 1) orelse return);
defer sys.CloseLibrary(ub.lib());
const list = ub.ObtainUSBDeviceList();
var it = list.iterator();
while (it.next()) |node| {
    const device: *usb.USBDevice = @fieldParentPtr("node", node);
    // device.address, device.descriptor.vendor_id, device.product ...
}
ub.ReleaseUSBDeviceList();
```

`AddUSBNotify(task, signals)` sends the signals whenever a device comes,
goes or is bound; the program reads the list again.

A device's descriptors are kept as they came, in its `config`.
`FindUSBInterface` finds an interface by class, subclass and protocol,
`FindUSBEndpoint` an interface's endpoint by direction and type, and
`NextUSBDescriptor` any descriptor - a class's own, a HID descriptor
after its interface. Their fields wider than a byte are `align(1)`: a
descriptor sits wherever the device put it.

## Driving a device from a program

A device no class driver took - a microcontroller with a protocol of its
own, a test - is driven by a program. `ClaimUSBInterface` takes an
interface for it, as a driver would; `ReleaseUSBInterface` gives it
back.

A **pipe** is a request already filled in for one endpoint:
`OpenUSBPipe(device, endpoint_address, reply_port)` gives an `IOUsbHC`
whose command, address, speed, endpoint, packet size, interval and hub
are set. The program sets the data and sends it, as often as it likes;
the endpoint's data toggle stays in the pipe.

```zig
if (!ub.ClaimUSBInterface(device, 0, "MyTool")) return fail("interface 0 is taken");
defer ub.ReleaseUSBInterface(device, 0);
const interface = ub.FindUSBInterface(device, null, d.USB_CLASS_VENDOR_SPEC, -1, -1) orelse return;
const in = ub.FindUSBEndpoint(device, interface, d.USB_DIR_IN, d.USB_ENDPOINT_XFER_BULK) orelse return;
const pipe = ub.OpenUSBPipe(device, in.endpoint_address, port) orelse return;
defer ub.CloseUSBPipe(pipe);

var buffer: [64]u8 = undefined;
pipe.io.std.data = &buffer;
pipe.io.std.length = buffer.len;
if (sys.DoIO(&pipe.io.std.req) == 0) use(buffer[0..@intCast(pipe.io.std.actual)]);
```

- A **bulk** read waits until the device sends; a short packet ends it.
  `nak_timeout` (milliseconds) gives up on a device that never does.
- An **interrupt** read is asked for every `interval` milliseconds until
  the device has something; it holds none of the controller's channels
  while it waits. After 100 ms with nothing, usbotg.device asks only
  every 8 ms until the device answers, so an idle keyboard or mouse
  costs little, and the first report after a pause is at most 8 ms
  late. Read one packet at a time: a device sends a report a packet.
- An **isochronous** write is a run of packets, one each `interval`:
  `std.length` bytes cut into packets of `iso_packet` (the endpoint's
  packet size unless set smaller), at most `UHC_ISO_PACKETS` of them,
  nothing resent. A stream keeps two or more on the controller, a pipe
  each on the endpoint: each starts in the interval after the one
  before ends, so one sent before the last has played leaves no gap.
  The endpoint is in a setting of its own, chosen with
  `SET_INTERFACE` first. xhci.device has them, OUT only; usbotg.device
  answers `IOERR_NOCMD`. A high-speed endpoint asking more often than
  once a millisecond gets no pipe.
- A **stall** ends a transfer with `UHIOERR_STALL`; `ClearUSBStall`
  clears the endpoint's halt and its toggle.
- A device that goes ends its transfers with `UHIOERR_DETACHED`.

`DoUSBControl(device, &setup, data, &actual)` makes a control transfer
on endpoint 0 and waits for it; any task may make one at any time.

## Writing a class driver

A class driver is a device in `DEVS:usb/` that speaks `DEVIF_USBCLASS`
(sdk/devices/usbclass.zig): two calls after BeginIO and AbortIO,
`USBClassBind` and `USBClassUnbind` (sdk/fd/usbclass_lib.fd), and a ROM
tag that says what it drives. usb.library reads that tag from the file
without loading it, when the first bus starts; a driver is loaded only
when something it drives is plugged in, and closed again when it drives
nothing.

**The tag** is a `ResidentUSBClass`: a `ResidentDevice` with
`RTF_DEVICEINFO`, whose `speaks` lists `DEVIF_USBCLASS`, and a table of
what it drives, ended by an empty entry.

```zig
const speaks = [_]u32{ devices.DEVIF_USBCLASS, 0 };
const matches = [_]usbclass.USBMatch{
    .{ .fields = usbclass.USBMATCH_CLASS | usbclass.USBMATCH_SUBCLASS | usbclass.USBMATCH_PROTOCOL,
       .interface_class = d.USB_CLASS_HID, .interface_subclass = d.HID_SUBCLASS_BOOT,
       .interface_protocol = d.HID_PROTOCOL_KEYBOARD },
    .{},
};
export const my_device_tag: usbclass.ResidentUSBClass linksection(".resident") = .{
    .device = .{
        .resident = .{ .match_tag = @ptrCast(&my_device_tag), .flags = exec.RTF_AUTOINIT | exec.RTF_DEVICEINFO,
            .version = 1, .type = .device, .name = "my.device", .id_string = ..., .init = &init_table },
        .speaks = &speaks,
        .units = 0,
    },
    .matches = &matches,
};
```

An entry names a vendor and product, or a class, subclass and protocol,
or any mix (`USBMATCH_*`). An interface is offered to the drivers whose
entries match it, the most specific first - a vendor and product above
any class - and among equals the higher `priority`. A driver for one
chip of a class, an FTDI serial adapter, is offered its chip before the
class's driver is.

**The calls.** usb.library opens the driver on `USBCLASS_UNIT_BIND` - the
driver itself, none of its units - and calls through its jump table:

- `USBClassBind(binding)`: take the interface, or decline it. It runs on
  the bus's process, which sets up nothing else meanwhile: check the
  interface, make the control transfers it needs (`DoUSBControl`), open
  the pipes, fill a unit, send the first read, and return. A read's
  reply goes to the driver's own task, which is where the waiting is
  done. `binding.unit` says which unit it filled, `binding.driver_data`
  is the driver's.
- `USBClassUnbind(binding)`: the device went, or the bus stops. Every
  request outstanding on it is taken back, its pipes closed, its unit
  left empty. A request's reply comes to the driver's task, so it is the
  task that takes them back: the call asks the task and waits for it.

`usb/hid.device` is the example: one task for every keyboard and mouse
it drives, a source on keyboard.device or mouse.device per interface
(`KBDF_SOURCE`, `KBD_ADDEVENT`), each report turned into key-downs and
key-ups, or into moves, buttons and the wheel. A keyboard or a mouse
is read by its own report descriptor - where its report keeps the
keys, or the buttons, X, Y and the wheel, and its report ID - since
many send another report than the boot one (a mouse 16-bit moves, a
keyboard a bit for every key, or its keys in a report of their own)
and do not switch when asked; only one whose descriptor says nothing
it can use is put in the boot protocol. A keyboard's Caps Lock light
goes out in the LED report its descriptor gives.

A device's name in exec is its name after the last `/`: a driver in
`DEVS:usb/` must not be called as a device in the ROM is -
`usb/serial.device` would open the ROM's serial.device.

## Keyboards and mice

keyboard.device and mouse.device are in every board's ROM, and take
what they report from **sources**: an open with `KBDF_SOURCE` or
`MOUSEF_SOURCE` hands them events with `KBD_ADDEVENT` or
`MOUSE_ADDEVENT`. A key held by two keyboards is down once; a keyboard
that goes lets go of what it held. Repeat, the qualifiers and dead keys
stay keyboard.device's and input.device's, whichever keyboard the keys
came from. A USB mouse says how far it went; intuition adds that up into
where the pointer is. A tablet says where it is on a surface of its own
- QEMU's `usb-tablet`, which follows the host's pointer over the
emulator's window: hid.device hands mouse.device that place as a
fraction of the surface (`IESUBCLASS_TABLET`, 0 to `IETABLET_MAX`), and
intuition puts the pointer as far across the front screen. hid.device
takes the boot subclass's keyboards and mice, and any other HID interface
whose report descriptor describes a keyboard or a mouse; a mouse with an
absolute X and Y is a tablet. `C:test/KeySource` is a source from the shell, and
`KBD_READSOURCES` says how many keyboards there are - the keyboard on
the screen comes up only while there is none.

## Sticks and card readers

`usb/disk.device` drives mass storage that speaks SCSI over Bulk-Only
Transport - nearly every stick and card reader. Its units are drives:
each logical unit of what is plugged in takes the lowest unit free, so
a stick is `DU0:`, a second one `DU1:`, and a card reader's two slots
are two drives. A stick pulled out frees its unit, and the next one
plugged in is `DU0:` again.

**The drives are made by the device.** The first time a medium comes
into unit n, the device makes its drives, as MountList entries would,
and starts their handlers, which read the stick and put its volumes on
the list; the desktop shows them. What the first stick holds says which
drives:

- **A RigidDiskBlock** ([disks guide](rdb.md)): a drive per partition
  not marked `PBFF_NOMOUNT`, named as the table says, with the handler
  its DosType asks for. The unit gets no drive of its own. A partition
  whose file system cannot go on a stick - the flash file system, or
  `MSH`/`POS\1` inside a partition - is passed over.
- **A GPT**, as a PC partitions a stick: a drive per partition of the
  RigidDiskBlock in its PowerOS container, as above, and one for each
  other GPT partition that holds a FAT32, exFAT or posfs volume and is
  not marked to be left alone (attribute bit 63) - the first `DU<n>`,
  every later one `DU<n>P<entry>`, `DU0P3:`. The unit gets no drive of
  its own.
- **No table**: `DU<n>` over the whole stick, with the handler its
  first block asks for. A posfs volume (`POS\0`) or a partition table
  with a posfs partition (`POS\1`) gives posfs-handler
  ([posfs guide](posfs.md)); anything else fat-handler, DosType
  `MSH\0`, which reads the stick's partition table and the boot sector
  of its first FAT partition. A stick with no partition table needs a
  MountList entry of the unit with DosType `MSD\0`, mounted before it
  is plugged in.

A name already on the list gets a dot added, as often as it takes: a
stick whose table names a partition `DH0`, plugged in beside the flash
disk's `DH0:`, gives `DH0.:`. A unit that a device node already opens -
a MountList entry mounted by hand - gets no drive of its own making:
that entry is the unit's drive, and its handler is started as the
device's own would be.

The drives stay from then on, with the handlers they got: a stick going
takes only its volumes, and the next one in the unit is read through the
same drives - a stick with another table needs a restart to be mounted
as that table says. Nothing in the MountList is needed, and nothing USB
is loaded at boot where no stick is plugged in.

**A card reader's slots** are looked at once a second (TEST UNIT
READY): a card put in comes in as a stick does, one taken out goes.
A stick pulled out in the middle of a transfer ends that transfer at
once; the handler then asks about the volume, as for a card pulled out
of the board's slot.

**What is written reaches the stick itself** when the handler asks: a
stick may hold writes in memory of its own and put them down later, in
an order of its own. `CMD_UPDATE` goes to the stick as SYNCHRONIZE
CACHE for the whole medium, and once it is answered everything written
before it is on the stick; fat-handler sends it when a file is closed.
A stick that does not know the command holds nothing to put down, and
is not asked again until another medium comes into the unit.
`TDCMD_ERASE` and `CMD_CLEAR` are answered at once: a stick erases for
itself, and the device holds nothing.

Beside the block commands the units answer `HD_SCSICMD`
(sdk/devices/scsidisk.zig): a SCSI command block sent to the unit as it
is, with its data and, on request, the sense of a command that fails.
`C:test/SCSI` asks a unit what it is and whether a medium is in:

```
1.System:> C:test/SCSI 0
usb/disk.device unit 0: QEMU QEMU HARDDISK, disk
ready
```

A stick moves at most about a megabyte a second at full speed. On the
ESP32-P4-PC, at high speed, a SanDisk stick read a 300 MB file at about
22 MB/s (`Copy` to `NIL:`).

## Serial adapters

`usb/ftdi.device` drives FTDI's serial chips - the FT232R and FT232BM,
the FT2232, FT232H and FT230X - matched by vendor and product, since
they say nothing of a class. `usb/acm.device` drives the communications
class's serial lines (CDC-ACM): a microcontroller board's USB port, a
modem, an ESP32-S3's own USB-Serial-JTAG port. Both have serial.device's
API (sdk/devices/serial.zig) through the same unit code as the ROM's
serial ports (sdk/devices/serialunit.zig): the rate and the frame with
SDCMD_SETPARAMS, breaks, the modem lines in SDCMD_QUERY, reads that end
at a termination character.

**Units are lines, not adapters.** An adapter plugged in takes the
lowest free unit (four in each driver); pulled out, it leaves the unit
without a line - a read waits, a write fails with `SerErr_NoDSR` - until
the next one comes. A program may open a unit before anything is
plugged in, as it may a serial port with nothing on its cable.

`DEVS:MountList` has `AUX2:` on usb/ftdi.device unit 0 and `AUX3:` on
usb/acm.device unit 0, both con-handler at 115200 baud, 8N1: a shell on
the far end of an FTDI cable is

```
1.System:> Mount AUX2:
1.System:> Run NewShell AUX2:
```

DTR and RTS are both on while an adapter is bound - on together, so a
board that resets on DTR alone, as an ESP32 does, is not reset. An FTDI
chip sends what came in every 4 ms at the latest; a CDC-ACM device when
it likes, usually at once. The line's errors and breaks the adapter
reports come as the ROM's ports' do: `io_Status` and SDCMD_QUERY.

## Ethernet adapters

`usb/ecm.device` drives Ethernet adapters of the communications class's
Ethernet Control Model (CDC-ECM) - adapters that speak it, a phone's or
a Linux board's USB network, QEMU's `usb-net` - as a network device
(sdk/devices/network.zig). Its units are links: an adapter plugged in
takes the lowest free unit (two), and the unit runs with the adapter's
Ethernet address. Pulled out, the unit loses its carrier and goes off
line - what was waiting is answered - until the next one comes, whose
address it then takes.

**The interface is made by the device.** The first time an adapter
comes into unit n, the device's own DOS process runs `C:net/AddNetInterface
USB<n>`, which brings up `DEVS:NetInterfaces/USB<n>` as `usb<n>` - DHCP,
in the file `USB0` has. The file says `Start = DEVICE`, so the boot's
`AddNetInterface ALL` leaves it out, and nothing of the device is loaded
where no adapter is ever plugged in. The interface stays from then on:
down while the unit has no adapter, up with the next, whose address the
stack then takes - IPv6 makes its link-local address again from it - and
DHCP asks again:

```
1.System:> NetStatus INTERFACES
Name     Address         Netmask         State               MTU ...
usb0     10.0.3.15       255.255.255.0   up dhcp bound      1500 ...
         40:54:00:12:34:57 on usb/ecm.device unit 0, 12 Mbit/s, gateway 10.0.3.2
```

Many adapters speak a vendor's own protocol, or Microsoft's RNDIS,
beside or instead of ECM. One that has an ECM configuration as well is
set to it, as usb.library sets a device to the first configuration a
driver takes; QEMU's `usb-net` has RNDIS first and ECM second. At full
speed an adapter moves at most about a megabyte a second.

## Wi-Fi sticks

`usb/aic8800.device` drives the AICSemi AIC8800 sticks (A69C:8800): a
stick plugged in is its boot ROM, which the device gives its firmware -
read from `DEVS:usb/firmware/aic8800/`, which `scripts/fetch-aic8800.sh`
fetches and the build puts on the ESP32-P4's disk - and starts. The stick
then leaves the bus and comes back as the Wi-Fi itself (A69C:8801), which
the device brings up to a station and runs as unit 0, a wireless network
device with the requests of `sdk/devices/wireless.zig`. The boot ROM wants
a high-speed port: the ESP32-P4's; on a slower one the stick is left as it
is, and said so in the log.

The interface is the device's to bring up, as `usb/ecm.device`'s:
`DEVS:NetInterfaces/WLAN1` (`Start = DEVICE`) the first time a stick
comes up, as `wlan1`. A `Network` line there has that network joined,
with its passphrase from `ENVARC:Sys/net/networks/<network>`;
`C:net/Wireless DEVICE usb/aic8800.device` scans and joins by hand. The
network stays wanted: a stick pulled out and plugged in again joins it
again.

```
1.System:> C:net/Wireless DEVICE usb/aic8800.device SCAN
Network                          Access point       Chan Signal Security
HomeNet                          02:11:22:33:44:55   36  -62   WPA2
```

How it is built - the firmware's load, its messages, the frames, the
join - is `docs/aic8800.md`.

## Speakers and headsets

`usb/uac.device` drives the audio class: a streaming interface with a
setting it can play through - an isochronous OUT endpoint, linear PCM,
one or two channels of 16, 24 or 32 bits, at 48 kHz - becomes a sink of
rta.library, named as the device names its product, which audio.device
plays through as it does a board's codec (`C:test/Audio OUTPUTS` lists
it, `OUTPUT` picks it; the [sound guide](audio.md)). A function's
microphone, another streaming interface, is declined, and so is every
interface on a bus without isochronous transfers: a packet of silence
sent as the interface is offered comes back `IOERR_NOCMD` on
usbotg.device.

Started, the interface is put in its setting, its rate set where the
endpoint has that control, and its feature unit's mute lifted and its
volume set to 0 dB - or the most it has, below that. Three transfers of
ten milliseconds go round, each refilled as it comes back; one that
comes back with nothing else left on the bus is counted as a gap
(`underruns`). Pulled out while it plays, its sink is deleted, and
audio.device goes on through the next output on the list.

## Writing a controller

A host controller is a device that speaks `DEVIF_USBHC`
(sdk/devices/usbhc.zig). A request is one transfer to one endpoint of
one device, an `IOUsbHC` that carries everything the controller needs:
the device's address and speed, the endpoint, its packet size and
interval, the hub a low- or full-speed device hangs off, the setup
packet of a control transfer, the data and its toggle. The controller
keeps no table of devices.

A controller whose hardware does keep one works it out from the bus's
own requests. An xHCI controller wants a device slot for each device,
made before the device has an address and told where in the tree it is,
and xhci.device follows the bus:

- A hub's port reset - the root hub's, or one sent to a hub on the bus -
  says where the next device is, and whatever was on that port before
  is let go.
- The first request to address 0 after it is for that device: a slot is
  enabled and set up with the device's address held back (Address Device
  with BSR), so the device answers its first descriptor at address 0.
  The route and the root port come from the hub's slot, the speed and
  the transaction translator from the request.
- The `SET_ADDRESS` that follows is the controller's to send: the slot is
  addressed for real, and the bus's address bound to it.
- `SET_CONFIGURATION` has the configuration's endpoints added first, every
  interface's first setting, from the configuration as it was last read
  whole; an endpoint of another setting is added when a transfer names
  it.
- A hub's descriptor, once read, makes its slot a hub - its ports and its
  TT think time - before anything behind it is reset.
- A device its hub's port shows gone has its slot let go, and every slot
  below it.

- `UHCMD_CONTROLXFER`, `UHCMD_BULKXFER`, `UHCMD_INTXFER`, and on
  xhci.device `UHCMD_ISOXFER`, OUT only: a TD a packet - an Isoch TRB,
  Start Isoch ASAP - and up to four requests on the endpoint's ring at
  once, each request's packets in a slice of the endpoint's buffer.
  Only a request's last TRB interrupts, and its event answers it and
  any before it the controller reported missed. Nothing halts;
  AbortIO of one on the ring stops the endpoint and answers every one
  on it. usbotg.device answers `IOERR_NOCMD`.
- An interrupt endpoint is asked once per interval: one with nothing
  to say is asked again when its interval has passed, and a request's
  next transfer after an answer waits out the interval too, so a device
  that always answers is not asked as fast as its driver sends. One
  that has had nothing for a while may be asked less often: usbotg.device
  asks every 8 ms after 100 ms of nothing.
- Its root port is a hub: control transfers to the root hub's address -
  0 until SET_ADDRESS gives it one - are answered with a hub's
  descriptors and the port's status, and an interrupt transfer on its
  endpoint 1 waits for the port to change.
- A low- or full-speed device behind a high-speed hub comes with
  `hub_address` and `hub_port` set: the transaction translator its
  transfers go to as split transactions. They are 0 for a device the
  port reaches at its own speed.
- Errors are `UHIOERR_*`: a stall, a timeout, a device gone.

A controller is found by its board part: `PARTKIND_USB`, its chip -
`StartUSB` opens usbotg.device for `CHIP_DWC2` and xhci.device for
`CHIP_XHCI` - which of the chip's controllers (`PART_BusUnit`), and how
the socket is wired
- its roles (`PART_UsbRoles`), its speed (`PART_UsbSpeed`), where its
5 V comes from (`PART_UsbVbus`), a hub's reset line (`PART_PinReset`),
a switch that gives it its pads (`PART_PinSwitch`).

A controller that shares a port starts by bidding for it with `OwnUSBPort`
(`sdk/resources/usbport.zig`): a `USBPortHandle` with its priority
(`USBPORTPRI_HOST`), its name, the task and signals it is told by, its
controller (`USBCTL_OTG`, the unit) and its role. A port held by someone
of lower priority is wanted from that holder, which lets go when it can;
the bidder waits for its signals - usbotg.device a second at most - and
reads `state`: `USBPORT_HELD` once the port is switched to it. A
controller that stops lets go with `ReleaseUSBPort(USBPORTF_REMOVE)`
before it powers down, and the port goes to the next bidder.

A controller on PCI starts with its function instead. xhci.device's
first `OpenDevice` of a unit claims the function (`ClaimPCIDevice`),
resets the controller, sets its rings up, hooks its interrupt - a
message-signalled one (MSI or MSI-X) where pci.library gives it one, its
INTx line otherwise - and runs it; the last `CloseDevice` answers every
transfer and halts it. Everything the controller reads or writes is DMA
memory below 4 GiB, in whole cache lines, written back before the
controller is told and dropped from the caches before it is read.

## In QEMU

`-Dusb` plugs QEMU's devices into the ESP32-S3 emulator's controller:

```sh
./zig build qemu-display -Dusb=usb-kbd,usb-mouse
./zig build qemu -Dusb=usb-hub,usb-kbd,id=kb1,usb-mouse
```

A device not put on the root port itself goes behind a hub QEMU adds.
In the monitor (Ctrl-A C on the serial console), `device_del kb1` pulls
the keyboard out, `device_add usb-kbd,id=kb2` plugs one in, `info usb`
lists them. QEMU's keyboards and mice are full speed, and its controller
has no device mode.

`usb-serial` is an FTDI FT232. Without a `chardev=` it gets a pty of its
own, whose name QEMU prints as it starts (`char device redirected to
/dev/pts/5`); a terminal on it (`screen /dev/pts/5 115200`) is the far
end of `AUX2:`. QEMU attaches the device only once the pty is open.

`usb-net` is a CDC Ethernet adapter. Without a `netdev=` it gets a user
network of its own, 10.0.3.0/24 - DHCP hands out 10.0.3.15, the gateway
is 10.0.3.2 - beside the machine's Ethernet on 10.0.2.0/24. In the
monitor, `netdev_add user,id=n1,net=10.0.3.0/24` and `device_add
usb-net,netdev=n1,id=un1` plug one in, `device_del un1` pulls it out.

`-Dusb-disk=<image>` plugs in a stick whose blocks are a raw image file
- one made with `mkfs.fat` will do; `qemu` leaves the file as it was,
`qemu-disk` writes to it. The stick is `usbstick` in the monitor:
`device_del usbstick` pulls it out, and another goes in with
`drive_add 0 if=none,id=s2,format=raw,file=<image>` and
`device_add usb-storage,drive=s2,id=stick2`.

`./zig build virt` starts QEMU's RISC-V virt machine without a USB
controller, so its bus does not start. A QEMU started with `-device
qemu-xhci` has one, and `-device usb-kbd`, `-device usb-mouse` or a
`usb-storage` device go on its bus; the machine's `USB AUTO` starts it at
boot. `-device usb-audio,audiodev=snd,id=spk` with an audiodev (`-audiodev
pa,id=snd`, or `wav,id=snd,path=out.wav,out.frequency=48000` for a file)
is a speaker for `usb/uac.device`; `device_del spk` pulls it out while it
plays. QEMU's own mixing engine plays 0 dB at 240/255 of full scale.
