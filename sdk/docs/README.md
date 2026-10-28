# The SDK's documentation

Two kinds of document live here: a **reference** for every call a module
has (`autodocs/`), generated from the source, and **guides** to how the
calls of one area work together (`guides/`), written by hand. Below them
is every module of the system, by kind, with where it lives and where
its reference is.

## The reference

`autodocs/` holds a reference for every module the SDK has a `.fd` file
for - every module with calls of its own - one file per module, in two
forms:

- `<module>.doc` - plain text: a table of contents, then each call on a
  page of its own (separated by form feeds), with NAME, SYNOPSIS, INPUTS,
  RESULT, BEHAVIOR, CONTEXT, OWNERSHIP, NOTES, BUGS, SEE ALSO and EXAMPLES.
- `<module>.md` - the same as Markdown, its index linking to each call.

The files are generated: `./zig build autodoc` writes them from the doc
comment above each call's `pub fn` in the source, and `./zig build test`
fails when one no longer matches. A call without such a comment is
described by the text of its `.fd` file.

A module with no calls of its own - a device that only answers commands,
a class that only takes attributes - has no autodoc. Its reference is
its SDK header, named in the tables below: the commands, structures,
tags and constants, each with its doc comment.

## Guides

- [Writing programs](guides/programs.md) - a window drawn into, and a
  window of gadgets laid out by a layout and a window object; when a
  check fails, the system log, semaphores, spinlocks and exec's list
  locks, and what several cores change.
- [Debugging](guides/debugging.md) - what a failure prints and asks, from
  an address to a line, the ROM debugger with its breakpoints and
  watchpoints, the serial console's commands, the log, memory debugging,
  what to reach for by symptom, emulators, JTAG and the host tests.
- [exec.library](guides/exec.md) - the base, opening libraries, devices
  and resources, memory and pools and who owns each block, lists, tasks
  and what a task's end gives back, Kill, signals, messages and ports,
  I/O requests and a timed wait, interrupts, and a library or a device of
  one's own.
- [dos.library](guides/dos.md) - files, buffered reading and writing,
  names and paths, locks and directories, patterns, command arguments,
  errors and Ctrl-C, processes, running commands, variables, being told
  of a change (notification), the device list and assigns, handlers and
  packets, disks at boot, and consoles.
- [utility.library](guides/utility.md) - tag lists, pack tables, hooks,
  dates, arithmetic, strings and case, patterns, named objects, unique
  numbers, and comparing records.
- [Intuition](guides/intuition.md) - screens and their pens, windows and
  their messages, window objects, BOOPSI objects and how they are
  connected, gadgets and layouts, the keyboard, gadgets in the border,
  how a gadget is drawn again, menus and requesters.
- [Fonts](guides/fonts.md) - the font image, drawing text, text from a
  description (IntuiText), choosing a font, sizes in points, font files
  and `FONTS:`, diskfont.library, outline fonts, the system's fonts, and
  the tools.
- [Styles](guides/styles.md) - what a style is, parts, states and
  properties, where a style comes from and how a property is found,
  `style.prefs`, drawing a part in a class, hover and focus.
- [Motion](guides/motion.md) - motion.library: the clock, curves and
  ease hooks, animations and turning them, hearing of them by a signal
  or a hook, mixing colours and boxes, timers (timeouts, repeating
  keys), timelines (there and back, scrubbing), moving a gadget, what
  moves on its own, and a whole program.
- [Datatypes](guides/datatypes.md) - what a file is to datatypes.library,
  working an object, pictures, text, animations, showing one in a
  window, and writing a class.
- [The desktop](guides/anvil.md) - anvil.library: starting the desktop
  and its startup drawer, the ground and the disks, drawers, opening and
  dragging, working with files, Information, scripts and shells, the
  calls programs take part with, and the menus.
- [Icons](guides/icons.md) - the icon file, reading one and its
  picture, tool types, writing one, the defaults, and making icons on
  the host.
- [Compression](guides/compression.md) - compression.library: a
  stream and its results, unpacking a buffer at a time and where a
  stream ends, packing and flushing, the calls that do either in one go,
  CRC-32 and Adler-32.
- [Network](guides/network.md) - sockets, multicast groups, waiting on
  them, names, TLS, HTTP requests (http.library), interfaces and their files, the network device API,
  wireless devices, SLIP over a serial line, writing a network driver,
  telnet.device, SSH both ways (ShellServer SSH with sftp and scp,
  `C:net/SSH`, `C:net/SCP`, ssh.device), a packet filter and the packet hooks under it, and the
  commands.
- [posfs](guides/posfs.md) - the journaling file system: when a change
  is durable, names and attributes, files, checksums and compression,
  links, Recycled and undelete, snapshots and rollback, `C:PosFS` and
  the check, putting it on a drive, its limits.
- [Disks and partitions](guides/rdb.md) - the RigidDiskBlock and its
  partitions, rdb.library: reading a disk's table, changing it, a fresh
  one, file systems kept in the table, errors, when a change is seen,
  and `C:RDB`.
- [Modbus](guides/modbus.md) - a device's tables, the RS-485 bus
  (rs485.device), modbus.library as a client over RTU and TCP, what a
  call answers, a server from a program's tables, the commands, and
  the bus in QEMU.
- [Sound](guides/audio.md) - audio.device: a stream and its form,
  writing buffers as they play, what the board has, choosing and
  preferring an output, a volume per output and `audio.prefs`, WAV and
  MP3 decoded by audiocodec.library, the outputs and their drivers
  (rta.library), recording, `C:Audio`, `C:Play` and `C:test/AudioTest`.
- [USB](guides/usb.md) - a bus and starting it, what is on it, driving
  a device from a program (claims, pipes, control transfers), writing a
  class driver, keyboards and mice as sources, sticks, serial and
  Ethernet adapters, writing a controller, and USB in QEMU.
- [Displays](guides/rtg.md) - rtg.library: drivers and boards, modes,
  buffers, handing on what was drawn, showing a buffer, several at once
  in bands, the engine, turning the picture, the pointer, events,
  asking a board, writing a driver, and the boards of this machine.

## Who uses whom

[How the modules use each other](modules.md) - three charts of which
module opens which: the ROM, the modules on the disk, and the classes.

## Libraries

Opened with `OpenLibrary`; their calls go through the jump table, and
`sdk.interface.<name>` has them as methods of the base. A library in the
ROM is there from the start; one on the disk is loaded from `LIBS:` the
first time something opens it.

| Library | Where | What | Reference |
|---|---|---|---|
| exec.library | ROM | tasks, signals, messages, memory, lists, libraries and devices | [md](autodocs/exec.md) · [doc](autodocs/exec.doc) |
| utility.library | ROM | tag lists, hooks, dates, strings, patterns | [md](autodocs/utility.md) · [doc](autodocs/utility.doc) |
| dos.library | ROM | processes, files, locks, handlers, assigns, `ReadArgs` | [md](autodocs/dos.md) · [doc](autodocs/dos.doc) |
| expansion.library | ROM | the board: which parts it has and how they are wired; the devices by what they speak, with their units on this board; the disks' partitions until dos takes them in | [md](autodocs/expansion.md) · [doc](autodocs/expansion.doc) |
| rtg.library | ROM | displays and their boards | [md](autodocs/rtg.md) · [doc](autodocs/rtg.doc) |
| rta.library | ROM, on a board with sound and in QEMU | sound outputs and the drivers behind them | [md](autodocs/rta.md) · [doc](autodocs/rta.doc), [`rta.zig`](../libs/rta/rta.zig) |
| graphics.library | ROM | drawing: RastPorts, bitmaps, text, fonts | [md](autodocs/graphics.md) · [doc](autodocs/graphics.doc) |
| layers.library | ROM | overlapping layers and their clipping | [md](autodocs/layers.md) · [doc](autodocs/layers.doc) |
| intuition.library | ROM | screens, windows, gadgets, menus, requesters, BOOPSI, styles | [md](autodocs/intuition.md) · [doc](autodocs/intuition.doc) |
| keymap.library | ROM | raw keys into characters | [md](autodocs/keymap.md) · [doc](autodocs/keymap.doc) |
| motion.library | ROM | one clock for animations, timers and timelines | [md](autodocs/motion.md) · [doc](autodocs/motion.doc) |
| asl.library | `LIBS:` | the file, font and device requesters | [md](autodocs/asl.md) · [doc](autodocs/asl.doc) |
| bsdsocket.library | `LIBS:` | TCP/IP: sockets, names, interfaces, packet hooks | [md](autodocs/bsdsocket.md) · [doc](autodocs/bsdsocket.doc) |
| compression.library | `LIBS:` | DEFLATE packed and unpacked, bare or in a zlib or gzip wrapping, a buffer at a time or in one go; CRC-32 and Adler-32 | [md](autodocs/compression.md) · [doc](autodocs/compression.doc), [`compression.zig`](../libs/compression/compression.zig), [guide](guides/compression.md) |
| crypto.library | `LIBS:` | random bytes, SHA, HMAC, HKDF, AES-GCM and RSA on the chip's engines where it has them; X25519, P-256, P-384 and Ed25519; signatures checked and made; ML-KEM-768 | [md](autodocs/crypto.md) · [doc](autodocs/crypto.doc) |
| datatypes.library | `LIBS:` | a file opened by what is in it | [md](autodocs/datatypes.md) · [doc](autodocs/datatypes.doc) |
| facet.library | `LIBS:` | three-dimensional drawing as Vulkan's model has it, on the machine's cores: memory, buffers and images, command buffers and a queue, render passes, pipelines with the program's own shaders, fences and semaphores, swapchains on a screen or in a window | [md](autodocs/facet.md) · [doc](autodocs/facet.doc) |
| filter.library | `LIBS:` | a packet filter: rules on what comes in, on bsdsocket.library's packet hooks | [md](autodocs/filter.md) · [doc](autodocs/filter.doc) |
| http.library | `LIBS:` | HTTP/1.1 requests over plain connections or TLS: a client keeping its connections for the next request, bodies sent and read in pieces, redirects followed, packed answers unpacked | [md](autodocs/http.md) · [doc](autodocs/http.doc), [`http.zig`](../libs/http/http.zig), [guide](guides/network.md#http-httplibrary) |
| icon.library | `LIBS:` | icons: the picture a file is shown with and its fields; the default that fits a file without one | [md](autodocs/icon.md) · [doc](autodocs/icon.doc) |
| diskfont.library | `LIBS:` | fonts from `FONTS:`, bitmap and outline | [md](autodocs/diskfont.md) · [doc](autodocs/diskfont.doc) |
| iffparse.library | `LIBS:` | reading and writing IFF | [md](autodocs/iffparse.md) · [doc](autodocs/iffparse.doc) |
| pci.library | `LIBS:` | PCI Express: every function behind every bridge of the board's host bridges, their memory placed, found by class and claimed by a driver; MSI and MSI-X; a function reset (RISC-V 64 disk) | [md](autodocs/pci.md) · [doc](autodocs/pci.doc), [`pci.zig`](../libs/pci/pci.zig) |
| rdb.library | `LIBS:` | a disk's RigidDiskBlock and partitions | [md](autodocs/rdb.md) · [doc](autodocs/rdb.doc) |
| modbus.library | `LIBS:` | Modbus over RTU and TCP, as a client and as a server | [md](autodocs/modbus.md) · [doc](autodocs/modbus.doc) |
| tls.library | `LIBS:` | TLS 1.3 and 1.2 sessions over a connected socket, the server's certificates checked | [md](autodocs/tls.md) · [doc](autodocs/tls.doc) |
| truetype.library | `LIBS:` | TrueType outlines into glyphs | [md](autodocs/truetype.md) · [doc](autodocs/truetype.doc) |
| usb.library | `LIBS:` | USB buses: their devices, descriptors, pipes to endpoints, class drivers | [md](autodocs/usb.md) · [doc](autodocs/usb.doc), [`usb.zig`](../libs/usb/usb.zig), [`descriptors.zig`](../libs/usb/descriptors.zig) |
| wpa.library | `LIBS:` | WPA2-Personal for a Wi-Fi driver: a network's key from its passphrase, the station's RSN element, the key handshakes | [md](autodocs/wpa.md) · [doc](autodocs/wpa.doc), [`wpa.zig`](../libs/wpa/wpa.zig) |

## Devices

Opened with `OpenDevice` and spoken to with I/O requests. Most answer
commands only, and their header holds the commands and the request they
take; console, input and timer have calls of their own too. A device in
the ROM is there from the start (on a board that has the part); one on
the disk is loaded from `DEVS:` the first time something opens it.

| Device | Where | What | Reference |
|---|---|---|---|
| timer.device | ROM | time, delays and alarms | [md](autodocs/timer.md) · [doc](autodocs/timer.doc), [`timer.zig`](../devices/timer.zig) |
| input.device | ROM | every input as one stream of events, down a chain of handlers | [md](autodocs/input.md) · [doc](autodocs/input.doc), [`input.zig`](../devices/input.zig), [`inputevent.zig`](../devices/inputevent.zig) |
| console.device | ROM | a terminal in a window | [md](autodocs/console.md) · [doc](autodocs/console.doc) |
| keyboard.device | ROM | the keyboards, as raw keys, from sources | [`keyboard.zig`](../devices/keyboard.zig) |
| mouse.device | ROM | the mice, as raw events, from sources | [`mouse.zig`](../devices/mouse.zig) |
| touch.device | ROM | a touch panel, as contacts | [`touch.zig`](../devices/touch.zig) |
| serial.device | ROM | the chip's UARTs, a unit each; the console's UART on a RISC-V 64 machine | [`serial.zig`](../devices/serial.zig) |
| usbserial.device | ROM | the USB-Serial-JTAG port, with serial.device's API | [`usbserial.zig`](../devices/usbserial.zig) |
| flash.device | ROM | the flash chip as a block device; unit 0 is the flash disk - on a RISC-V 64 machine the disk image the loader put in RAM | [`trackdisk.zig`](../devices/trackdisk.zig) |
| i2c.device | ROM | the two I2C controllers | [`i2c.zig`](../devices/i2c.zig) |
| audio.device | ROM | streams of sound, up to sixteen mixed into one of the machine's outputs; the output preferred, a volume each | [`audio.zig`](../devices/audio.zig), [`audiocontrol.zig`](../devices/audiocontrol.zig) |
| sdcard.device | `DEVS:`; ROM on the VisionFive 2 | the card slot as a block device; in the ROM, the card's partitions as disks to start from | [`trackdisk.zig`](../devices/trackdisk.zig) |
| nvme.device | `DEVS:` | NVMe SSDs on PCI Express as block devices, a unit a namespace, with TRIM; their drives mounted when it starts (RISC-V 64 disk) | [`trackdisk.zig`](../devices/trackdisk.zig) |
| rs485.device | `DEVS:` | the RS-485 port, in frames | [`rs485.zig`](../devices/rs485.zig) |
| clipboard.device | `DEVS:` | what is cut, copied and pasted, a unit a clip | [`clipboard.zig`](../devices/clipboard.zig) |
| telnet.device | `DEVS:` | a TCP connection as a stream, for a console | [`telnet.zig`](../devices/telnet.zig) |
| ssh.device | `DEVS:` | an SSH connection as a stream, either end: the server's for a console, the client's for a shell elsewhere | [`ssh.zig`](../devices/ssh.zig), [`ssh/keys.zig`](../devices/ssh/keys.zig) |
| openeth.device | `DEVS:networks/` | QEMU's Ethernet | [`network.zig`](../devices/network.zig) |
| emac.device | `DEVS:networks/` | the chip's own Ethernet MAC: the ESP32-P4's on RMII, the JH7110's gigabit GMAC on RGMII | [`network.zig`](../devices/network.zig) |
| esp32s3wifi.device | `DEVS:networks/` | the ESP32-S3's Wi-Fi, WPA2 | [`network.zig`](../devices/network.zig), [`wireless.zig`](../devices/wireless.zig) |
| slip.device | `DEVS:networks/` | IP over a serial line (SLIP), on any device with serial.device's API | [`network.zig`](../devices/network.zig), [`slip.zig`](../devices/slip.zig) |
| usbotg.device | `DEVS:` | the chip's USB OTG controller as a USB host controller, a unit per socket (the ESP32s' disks) | [`usbhc.zig`](../devices/usbhc.zig) |
| xhci.device | `DEVS:` | an xHCI controller on PCI Express as a USB host controller (RISC-V 64 disk) | [`usbhc.zig`](../devices/usbhc.zig) |
| usb/hid.device | `DEVS:usb/` | USB keyboards, mice and tablets, into keyboard.device and mouse.device; a class driver | [md](autodocs/usbclass.md) · [doc](autodocs/usbclass.doc), [`usbclass.zig`](../devices/usbclass.zig) |
| usb/disk.device | `DEVS:usb/` | USB sticks and card readers as block devices, a unit a drive (`DU<n>:`), and SCSI commands to them; a class driver | [`trackdisk.zig`](../devices/trackdisk.zig), [`scsidisk.zig`](../devices/scsidisk.zig) |
| usb/ftdi.device | `DEVS:usb/` | FTDI's USB serial chips, a unit a line, with serial.device's API; a class driver | [`serial.zig`](../devices/serial.zig), [`serialunit.zig`](../devices/serialunit.zig) |
| usb/acm.device | `DEVS:usb/` | the communications class's USB serial lines (CDC-ACM), with serial.device's API; a class driver | [`serial.zig`](../devices/serial.zig), [`serialunit.zig`](../devices/serialunit.zig) |
| usb/ecm.device | `DEVS:usb/` | USB Ethernet adapters (CDC-ECM) as a network device, a unit a link; a class driver | [`network.zig`](../devices/network.zig) |
| usb/aic8800.device | `DEVS:usb/` | AIC8800 USB Wi-Fi sticks, WPA2, their firmware loaded; a class driver | [`network.zig`](../devices/network.zig), [`wireless.zig`](../devices/wireless.zig) |

## Resources

Opened with `OpenResource`; calls only, no requests, and no open count.
All are in the ROM.

| Resource | What | Reference |
|---|---|---|
| platform.resource | what machine this is: the chip, its clocks, where the code and the stacks are, whether there is PSRAM | [md](autodocs/platform.md) · [doc](autodocs/platform.doc) |
| gpio.resource | who holds which of the chip's pads | [md](autodocs/gpio.md) · [doc](autodocs/gpio.doc) |
| usbport.resource | who holds each of the chip's USB ports, and which controller it is given to: on the ESP32-S3 the console's USB-Serial-JTAG or the OTG controller | [md](autodocs/usbport.md) · [doc](autodocs/usbport.doc) |
| dma.resource | the chip's DMA engines, their channels one owner each | [md](autodocs/dma.md) · [doc](autodocs/dma.doc) |
| jpeg.resource | the ESP32-P4's JPEG codec: a file decoded into pixels | [md](autodocs/jpeg.md) · [doc](autodocs/jpeg.doc) |
| expander.resource | the board's IO expander: the pins the panel, the touch controller and the card hang on, the backlight, an analogue input | [md](autodocs/expander.md) · [doc](autodocs/expander.doc) |
| battery.resource | the board's battery: whether a cell is there, its voltage and charge, external power and charging, a signal when that changes | [md](autodocs/battery.md) · [doc](autodocs/battery.doc) |
| battclock.resource | the date kept while the system is off or restarts: the board's clock chip, else the chip's RTC timer; the system time set from it at the boot | [md](autodocs/battclock.md) · [doc](autodocs/battclock.doc) |
| battmem.resource | a few hundred bits of settings that need no file read, kept over a reset where the chip can (the ESP32s' RTC memory): the time zone the file systems stamp with | [md](autodocs/battmem.md) · [doc](autodocs/battmem.doc) |
| thermal.resource | the board's temperatures as its sensors read them (the JH7110's own), each with its chip's hot and critical limits, a signal when a reading passes one | [md](autodocs/thermal.md) · [doc](autodocs/thermal.doc) |
| watchdog.resource | the chip's watchdog timer, armed, fed and disarmed by programs | [md](autodocs/watchdog.md) · [doc](autodocs/watchdog.doc) |

## Handlers

What answers the packets of a DOS device: a program reaches them through
dos.library's calls, never directly. dos starts a handler the first time
its device is used.

| Handler | Where | Serves | Reference |
|---|---|---|---|
| ram-handler | ROM | `RAM:`, a file system in memory | dos.library |
| con-handler | ROM | `CON:` and `RAW:`, a console in a window; `AUX:`, and a console on any stream device (ShellServer's `TELNET<n>:` and `SSH<n>:`) | dos.library |
| pipe-handler | ROM | `PIPE:`, a pipe between two processes | dos.library |
| nil-handler | ROM | `NIL:`, which swallows what is written | dos.library |
| flashfs-handler | ROM | `DH0:` and every partition of type `FLS\0` | [`flashfs.zig`](../libs/dos/flashfs.zig) |
| fat-handler | `HANDLERS:`; ROM on the VisionFive 2 | `SD0:`, FAT32 and exFAT on a card, a stick or a partition | dos.library |
| posfs-handler | `HANDLERS:` | posfs, `POS\0` and `POS\1`: a partition of the flash disk, a card, a stick | [posfs guide](guides/posfs.md), [`packets.zig`](../libs/dos/posfs/packets.zig) |

## intuition's classes

BOOPSI classes in the ROM, as part of intuition.library: made with
`NewObjectTagList(null, <name>, tags)`, no library to open. The names
are in [`classusr.zig`](../libs/intuition/classusr.zig).

| Class | What | Reference |
|---|---|---|
| rootclass | what every object is | [`classusr.zig`](../libs/intuition/classusr.zig) |
| imageclass, frameiclass, sysiclass, fillrectclass, itexticlass | images: frames, the system's gadget imagery, boxes, text | [`imageclass.zig`](../libs/intuition/imageclass.zig) |
| icclass, modelclass | objects that pass attributes on to others | [`icclass.zig`](../libs/intuition/icclass.zig) |
| gadgetclass | what every gadget is | [`gadgetclass.zig`](../libs/intuition/gadgetclass.zig) |
| buttongclass, frbuttonclass | buttons, plain and framed | [`gadgetclass.zig`](../libs/intuition/gadgetclass.zig) |
| propgclass | a proportional knob in a container | [`propgclass.zig`](../libs/intuition/propgclass.zig) |
| strgclass | a line of text to type | [`gadgetclass.zig`](../libs/intuition/gadgetclass.zig) |
| groupgclass | gadgets kept together | [`classusr.zig`](../libs/intuition/classusr.zig) |
| layoutgclass | gadgets laid out in rows and columns | [`layoutgclass.zig`](../libs/intuition/layoutgclass.zig) |
| windowclass | a window as an object, with its layout | [`windowclass.zig`](../libs/intuition/windowclass.zig) |
| pointerclass | a pointer's image | [`pointerclass.zig`](../libs/intuition/pointerclass.zig) |

## Gadget classes

Each a library of its own in `SYS:classes/gadgets/`, which is part of
`LIBS:`: opened as `gadgets/<name>.gadget`, then made with
`NewObjectTagList(null, "<name>.gadget", tags)`. They take attributes
only, so their header is their reference; colorwheel.gadget has calls
of its own besides. How a class is written is in
[`classlibrary.zig`](../libs/gadgets/classlibrary.zig) and
[`support.zig`](../libs/gadgets/support.zig).

| Gadget | What | Reference |
|---|---|---|
| checkbox.gadget | a box that is ticked or not | [`checkbox.zig`](../libs/gadgets/checkbox.zig) |
| radiobutton.gadget | a column of choices, one on | [`radiobutton.zig`](../libs/gadgets/radiobutton.zig) |
| cycle.gadget | a button that steps through choices | [`cycle.zig`](../libs/gadgets/cycle.zig) |
| chooser.gadget | a button that pops up a list to pick from | [`chooser.zig`](../libs/gadgets/chooser.zig) |
| string.gadget | a line of text, or a number, to type | [`string.zig`](../libs/gadgets/string.zig) |
| integer.gadget | a number in a range, with arrows that step it | [`integer.zig`](../libs/gadgets/integer.zig) |
| text.gadget | a line that shows a text or a number | [`text.zig`](../libs/gadgets/text.zig) |
| slider.gadget | a whole number picked between two ends | [`slider.zig`](../libs/gadgets/slider.zig) |
| scroller.gadget | a scroll bar | [`scroller.zig`](../libs/gadgets/scroller.zig) |
| listview.gadget | a scrolling list of an exec `List`'s nodes | [`listview.zig`](../libs/gadgets/listview.zig) |
| palette.gadget | a grid of colours, one picked | [`palette.zig`](../libs/gadgets/palette.zig) |
| colorwheel.gadget | a wheel of hues and saturations to pick a colour on | [md](autodocs/colorwheel.md) · [doc](autodocs/colorwheel.doc), [`colorwheel.zig`](../libs/gadgets/colorwheel.zig) |
| gradientslider.gadget | a slider over a gradient of colours | [`gradientslider.zig`](../libs/gadgets/gradientslider.zig) |
| fuelgauge.gadget | a bar that shows how far along something is | [`fuelgauge.zig`](../libs/gadgets/fuelgauge.zig) |
| spinner.gadget | a ring of dots going round while something goes on | [`spinner.zig`](../libs/gadgets/spinner.zig) |
| meter.gadget | a dial with a needle | [`meter.zig`](../libs/gadgets/meter.zig) |
| arc.gadget | a ring filled to a level, or turned like a knob | [`arc.zig`](../libs/gadgets/arc.zig) |
| roller.gadget | a wheel of choices, turned by dragging | [`roller.zig`](../libs/gadgets/roller.zig) |
| page.gadget | several gadgets in one place, one shown | [`page.zig`](../libs/gadgets/page.zig) |
| clicktab.gadget | a row of tabs, one in front | [`clicktab.zig`](../libs/gadgets/clicktab.zig) |
| getfile.gadget | a file name, typed or asked for | [`getfile.zig`](../libs/gadgets/getfile.zig) |
| getfont.gadget | a font, named or asked for | [`getfont.zig`](../libs/gadgets/getfont.zig) |
| getdevice.gadget | a device's unit, named or asked for among those that speak a command set | [`getdevice.zig`](../libs/gadgets/getdevice.zig) |
| tapedeck.gadget | the buttons of a tape deck or a player | [`tapedeck.zig`](../libs/gadgets/tapedeck.zig) |
| calendar.gadget | a month, to pick a day from | [`calendar.zig`](../libs/gadgets/calendar.zig) |
| canvas.gadget | a picture a program draws into | [`canvas.zig`](../libs/gadgets/canvas.zig) |
| chart.gadget | values over time, as lines or bars | [`chart.zig`](../libs/gadgets/chart.zig) |
| qrcode.gadget | a text as a QR code | [`qrcode.zig`](../libs/gadgets/qrcode.zig) |
| barcode.gadget | a text as a Code 128 or an EAN-13 barcode | [`barcode.zig`](../libs/gadgets/barcode.zig) |
| keyboard.gadget | keys on the screen, for a board with none | [`keyboard.zig`](../libs/gadgets/keyboard.zig) |
| textedit.gadget | text of many lines to edit: selection, clipboard, undo, find and replace, word wrap, line numbers | [`textedit.zig`](../libs/gadgets/textedit.zig) |
| scrollgroup.gadget | a layout larger than its room, seen through it and moved by scrollers and the wheel; what lies outside is cut off | [`scrollgroup.zig`](../libs/gadgets/scrollgroup.zig) |
| listbrowser.gadget | a list in columns under headings that sort it, its rows a tree whose branches open and close | [`listbrowser.zig`](../libs/gadgets/listbrowser.zig) |
| toolbutton.gadget | a button with a picture and a label in three sizes, as a tool bar or a ribbon has them; a command or a toggle, flat until the pointer is over it | [`toolbutton.zig`](../libs/gadgets/toolbutton.zig) |
| ribbon.gadget | a program's commands in tabs and named groups across the top of its window, as an office program has them | [`ribbon.zig`](../libs/gadgets/ribbon.zig) |

## Docklets

The dock's small pictures of the machine, each a library of its own in
`SYS:classes/docklets/`: opened as `docklets/<name>.docklet`, then made
with `NewObjectTagList(null, "<name>.docklet", null)`. A docklet is an
image class: the dock draws it fitted to its entry (`IM_DRAWFRAME`) at
every size, sets `DOCKLET_Look` as often as it asks, and runs its
command when it is clicked. What every docklet answers, and the class
library that makes one from a few functions, are in
[`docklets.zig`](../libs/docklets/docklets.zig).

| Docklet | What | A click runs |
|---|---|---|
| clock.docklet | the time, as a clock face; the date in its words | nothing |
| battery.docklet | the board's battery (battery.resource), filled to its charge | nothing |
| volume.docklet | how loud the machine plays, as a speaker and its waves | `SYS:Programs/Volume` |
| cpu.docklet | how busy each core is, a bar each | `SYS:System/CPULoad` |
| network.docklet | an arrow for what comes in, one for what goes out | `SYS:System/NetLoad` |

## Image classes

Pictures drawn to any size, each a library of its own in
`SYS:classes/images/`: opened as `images/<name>.image`, then made with
`NewObjectTagList(null, "<name>.image", tags)`. An image class draws in
its own box (`IM_DRAW`) or fitted to the one it is given
(`IM_DRAWFRAME`), so one image serves a menu's 16 pixels and a large
button's 48. What they draw with - smooth shapes in a square, a palette
of eleven hues in three tones, a shadow, shading and gloss - is
[`shapes.zig`](../libs/gadgets/shapes.zig), which the docklets draw on
too; their tags start at `IMAGES_Dummy` in
[`images.zig`](../libs/images/images.zig).

| Class | What | Header |
|---|---|---|
| command.image | the pictures of a program's commands - new, open, save, cut, copy, paste, undo, find, bold, align, sort, rows and columns - in colour, for tool buttons and ribbons | [`command.zig`](../libs/images/command.zig) |
| media.image | the pictures of a player's controls - play, pause, stop, wind, the song before and after, shuffle, repeat, the speaker and its sound off - for a tape deck and tool buttons, and a note for a song without a cover | [`media.zig`](../libs/images/media.zig) |

## Datatype classes

Each a library of its own in `SYS:classes/datatypes/`, opened by
datatypes.library for a file it recognises - a program asks
datatypes.library for an object and never opens these itself. Every
picture is a `picture.datatype` object, every piece of text a
`text.datatype` object and every animation an `animation.datatype`
object, whatever format it came out of; see the
[datatypes guide](guides/datatypes.md).

| Class | What | Reference |
|---|---|---|
| picture.datatype | every still picture: kept, drawn, scrolled, scaled, written out | [`pictureclass.zig`](../libs/datatypes/pictureclass.zig) |
| ilbm.datatype | IFF ILBM | [`pictureclass.zig`](../libs/datatypes/pictureclass.zig) |
| bmp.datatype | Windows bitmaps | [`pictureclass.zig`](../libs/datatypes/pictureclass.zig) |
| png.datatype | PNG | [`pictureclass.zig`](../libs/datatypes/pictureclass.zig) |
| gif.datatype | GIF | [`pictureclass.zig`](../libs/datatypes/pictureclass.zig) |
| jpeg.datatype | baseline JPEG | [`pictureclass.zig`](../libs/datatypes/pictureclass.zig) |
| font.datatype | font families, as a sheet of their characters and sizes | [`pictureclass.zig`](../libs/datatypes/pictureclass.zig) |
| animation.datatype | every animation: frames drawn ahead on a process of its own, played in time | [`animationclass.zig`](../libs/datatypes/animationclass.zig) |
| gifanim.datatype | GIF with more than one picture | [`animationclass.zig`](../libs/datatypes/animationclass.zig) |
| lottie.datatype | Lottie vector animations | [`animationclass.zig`](../libs/datatypes/animationclass.zig) |
| text.datatype | every piece of text: runs in fonts, styles and pens, wrapped, marked and copied | [`textclass.zig`](../libs/datatypes/textclass.zig) |
| ascii.datatype | plain text and IFF FTXT | [`textclass.zig`](../libs/datatypes/textclass.zig) |
| markdown.datatype | Markdown | [`textclass.zig`](../libs/datatypes/textclass.zig) |

What every format's class does the same way is in
[`subclass.zig`](../libs/datatypes/subclass.zig), and what every data
type object is in [`datatypesclass.zig`](../libs/datatypes/datatypesclass.zig).

## Examples

The smallest of each kind, to start one of your own from:
`LIBS:hello.library` (`src/disk/libs/hello/`) and
`SYS:classes/gadgets/hello.gadget` (`src/disk/classes/gadgets/hello/`);
[Writing programs](guides/programs.md) has the programs.
