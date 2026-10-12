# USB

A USB socket on a board is a bus: the chip's controller is its host, and
keyboards, mice, sticks and hubs are plugged into it and pulled out while
the system runs. `usb.library`, in `LIBS:`, runs a bus: it finds what is
plugged in, gives each device an address and a configuration, drives
the hubs itself, and hands every other interface to a class driver in
`DEVS:usb/`. A class driver is the device the rest of the system already
speaks to: a USB keyboard is keyboard.device's keyboard, so nothing
above it knows where the keys came from.

This guide is the bus first, then looking at what is on it, driving a
device from a program, writing a class driver, the drivers there are -
keyboards and mice, sticks, serial and Ethernet adapters - and writing a
controller.

## The pieces

```
 above them             keyboard.device,   fat-handler      con-handler       bsdsocket.library
                        mouse.device       on USB<n>:       on AUX2:, AUX3:   on usb0
                             ^                  ^                ^                 ^
 class drivers,         usb/hid.device     usb/disk.device  usb/ftdi.device   usb/ecm.device
 DEVS:usb/                                                  usb/acm.device
                             |  USBClassBind, USBClassUnbind (DEVIF_USBCLASS)
 the bus                usb.library: a process per bus, hubs, pipes
                             |  DEVIF_USBHC: UHCMD_CONTROLXFER, ...
 the controller         usbotg.device (the chip's DWC2), a unit per socket
                             |
 the board              PARTKIND_USB in its system tag list
```

| Piece | Where | What it is |
|---|---|---|
| `usbotg.device` | `DEVS:` | the chip's USB OTG controller as a host controller: transfers to devices on its bus, its root port answered as a hub |
| `usb.library` | `LIBS:` | the bus: devices, hubs, descriptors, pipes, binding, notification |
| `usb/hid.device` | `DEVS:usb/` | keyboards and mice of the boot class, into keyboard.device and mouse.device |
| `usb/disk.device` | `DEVS:usb/` | sticks and card readers (mass storage, SCSI over Bulk-Only) as block devices, a drive `USB<n>:` each |
| `usb/ftdi.device` | `DEVS:usb/` | FTDI's serial chips as serial lines, with serial.device's API |
| `usb/acm.device` | `DEVS:usb/` | the communications class's serial lines (CDC-ACM), with serial.device's API |
| `usb/ecm.device` | `DEVS:usb/` | Ethernet adapters of the communications class (CDC-ECM) as a network device |
| `C:USB` | | starts and stops a bus |
| `C:USBInfo` | | lists what is on the buses |

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
USB-A sockets are behind a hub - they work from the first picture on. A
socket that is also the console's - the ESP32-S3 boards', whose one USB
port is the serial console and the JTAG as the chip starts - is left to
`USB START` by hand.

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
| 7B, ES3C35P | the console's USB-C | not yet: the port stays the console's |
| QEMU | the emulator's DWC2, with what `-Dusb` plugs in | started at boot |

The high-speed controller runs its port at full speed for now: a hub on
it is a full-speed hub, and a low-speed keyboard behind it is reached as
on any full-speed port.

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
  while it waits. Read one packet at a time: a device sends a report a
  packet.
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
where the pointer is. `C:test/KeySource` is a source from the shell, and
`KBD_READSOURCES` says how many keyboards there are - the keyboard on
the screen comes up only while there is none.

## Sticks and card readers

`usb/disk.device` drives mass storage that speaks SCSI over Bulk-Only
Transport - nearly every stick and card reader. Its units are drives:
each logical unit of what is plugged in takes the lowest unit free, so
a stick is `USB0:`, a second one `USB1:`, and a card reader's two slots
are two drives. A stick pulled out frees its unit, and the next one
plugged in is `USB0:` again.

**The drive is made by the device.** The first time a medium comes into
unit n, the device puts `USB<n>` on the device list, as a MountList
entry would - fat-handler, FAT's DosType - and starts the handler, which
reads the stick's partition table and boot sector and puts its volume
on the list; the desktop shows it. The node stays from then on: a stick
going takes only its volume, and the next one in the unit brings its
own. Nothing in the MountList is needed, and nothing USB is loaded at
boot where no stick is plugged in.

**A card reader's slots** are looked at once a second (TEST UNIT
READY): a card put in comes in as a stick does, one taken out goes.
A stick pulled out in the middle of a transfer ends that transfer at
once; the handler then asks about the volume, as for a card pulled out
of the board's slot.

Beside the block commands the units answer `HD_SCSICMD`
(sdk/devices/scsidisk.zig): a SCSI command block sent to the unit as it
is, with its data and, on request, the sense of a command that fails.
`C:test/SCSI` asks a unit what it is and whether a medium is in:

```
1.System:> C:test/SCSI 0
usb/disk.device unit 0: QEMU QEMU HARDDISK, disk
ready
```

The bus runs at full speed, as for every device so far, so a stick
moves at most about a megabyte a second.

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
driver takes; QEMU's `usb-net` has RNDIS first and ECM second. The bus
runs at full speed: an adapter moves at most about a megabyte a second.

## Writing a controller

A host controller is a device that speaks `DEVIF_USBHC`
(sdk/devices/usbhc.zig). A request is one transfer to one endpoint of
one device, an `IOUsbHC` that carries everything the controller needs:
the device's address and speed, the endpoint, its packet size and
interval, the hub a low- or full-speed device hangs off, the setup
packet of a control transfer, the data and its toggle. The controller
keeps no table of devices.

- `UHCMD_CONTROLXFER`, `UHCMD_BULKXFER`, `UHCMD_INTXFER`;
  `UHCMD_ISOXFER` is in the set, `IOERR_NOCMD` until a controller does it.
- An interrupt endpoint is asked once per interval: one with nothing
  to say is asked again when its interval has passed, and a request's
  next transfer after an answer waits out the interval too, so a device
  that always answers is not asked as fast as its driver sends.
- Its root port is a hub: control transfers to the root hub's address -
  0 until SET_ADDRESS gives it one - are answered with a hub's
  descriptors and the port's status, and an interrupt transfer on its
  endpoint 1 waits for the port to change.
- Errors are `UHIOERR_*`: a stall, a timeout, a device gone.

A controller is found by its board part: `PARTKIND_USB`, its chip, which
of the chip's controllers (`PART_BusUnit`), and how the socket is wired
- its roles (`PART_UsbRoles`), its speed (`PART_UsbSpeed`), where its
5 V comes from (`PART_UsbVbus`), a hub's reset line (`PART_PinReset`),
a switch that gives it its pads (`PART_PinSwitch`).

## In QEMU

`-Dusb` plugs QEMU's devices into the emulator's controller:

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
