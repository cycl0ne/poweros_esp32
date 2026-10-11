# USB

A USB socket on a board is a bus: the chip's controller is its host, and
keyboards, mice and hubs are plugged into it and pulled out while the
system runs. `usb.library`, in `LIBS:`, runs a bus: it finds what is
plugged in, gives each device an address and a configuration, drives
the hubs itself, and hands every other interface to a class driver in
`DEVS:usb/`. A class driver is the device the rest of the system already
speaks to: a USB keyboard is keyboard.device's keyboard, so nothing
above it knows where the keys came from.

This guide is the bus first, then looking at what is on it, driving a
device from a program, and writing a class driver or a controller.

## The pieces

```
 programs, input.device      keyboard.device, mouse.device (sources)
                                        ^
 class drivers, DEVS:usb/     usb/hid.device  (DEVIF_USBCLASS)
                                        |  USBClassBind, USBClassUnbind
 the bus                      usb.library: a process per bus, hubs, pipes
                                        |  DEVIF_USBHC: UHCMD_CONTROLXFER, ...
 the controller               usbotg.device (the chip's DWC2), a unit per socket
                                        |
 the board                    PARTKIND_USB in its system tag list
```

| Piece | Where | What it is |
|---|---|---|
| `usbotg.device` | `DEVS:` | the chip's USB OTG controller as a host controller: transfers to devices on its bus, its root port answered as a hub |
| `usb.library` | `LIBS:` | the bus: devices, hubs, descriptors, pipes, binding, notification |
| `usb/hid.device` | `DEVS:usb/` | keyboards and mice of the boot class, into keyboard.device and mouse.device |
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
descriptors, its first configuration and its strings, and set to that
configuration. A hub is the library's own; every other interface is
offered to the class drivers. A device that goes takes everything that
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
key-ups, or into moves, buttons and the wheel. A keyboard is put in its
boot protocol. A mouse is read by its own report descriptor - where
its report keeps the buttons, X, Y and the wheel, and its report ID -
since many mice send a wider report than the boot one (16-bit moves)
and do not switch when asked; only a mouse whose descriptor says
nothing it can use is put in the boot protocol.

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
