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
  check fails, the system log, Forbid, semaphores and spinlocks, and what
  two cores change.
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
  working an object, pictures, text, showing one in a window, and
  writing a class.
- [Network](guides/network.md) - sockets, waiting on them, names, TLS,
  interfaces and their files, the network device API, wireless devices,
  writing a network driver, telnet.device, and the commands.
- [Disks and partitions](guides/rdb.md) - the RigidDiskBlock and its
  partitions, rdb.library: reading a disk's table, changing it, a fresh
  one, errors, when a change is seen, and `C:RDB`.
- [Modbus](guides/modbus.md) - a device's tables, the RS-485 bus
  (rs485.device), modbus.library as a client over RTU and TCP, what a
  call answers, a server from a program's tables, the commands, and
  the bus in QEMU.
- [Displays](guides/rtg.md) - rtg.library: drivers and boards, modes,
  buffers, handing on what was drawn, showing a buffer, several at once
  in bands, the engine, turning the picture, the pointer, events,
  asking a board, writing a driver, and the boards of this machine.

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
| expansion.library | ROM | the board: which parts it has and how they are wired | [md](autodocs/expansion.md) · [doc](autodocs/expansion.doc) |
| rtg.library | ROM | displays and their boards | [md](autodocs/rtg.md) · [doc](autodocs/rtg.doc) |
| graphics.library | ROM | drawing: RastPorts, bitmaps, text, fonts | [md](autodocs/graphics.md) · [doc](autodocs/graphics.doc) |
| layers.library | ROM | overlapping layers and their clipping | [md](autodocs/layers.md) · [doc](autodocs/layers.doc) |
| intuition.library | ROM | screens, windows, gadgets, menus, requesters, BOOPSI, styles | [md](autodocs/intuition.md) · [doc](autodocs/intuition.doc) |
| keymap.library | ROM | raw keys into characters | [md](autodocs/keymap.md) · [doc](autodocs/keymap.doc) |
| motion.library | ROM | one clock for animations, timers and timelines | [md](autodocs/motion.md) · [doc](autodocs/motion.doc) |
| asl.library | `LIBS:` | the file and font requesters | [md](autodocs/asl.md) · [doc](autodocs/asl.doc) |
| bsdsocket.library | `LIBS:` | TCP/IP: sockets, names, interfaces | [md](autodocs/bsdsocket.md) · [doc](autodocs/bsdsocket.doc) |
| crypto.library | `LIBS:` | random bytes, SHA, HMAC, HKDF, AES-GCM and RSA on the chip's engines; X25519, P-256, P-384 and Ed25519; signatures checked and made | [md](autodocs/crypto.md) · [doc](autodocs/crypto.doc) |
| datatypes.library | `LIBS:` | a file opened by what is in it | [md](autodocs/datatypes.md) · [doc](autodocs/datatypes.doc) |
| diskfont.library | `LIBS:` | fonts from `FONTS:`, bitmap and outline | [md](autodocs/diskfont.md) · [doc](autodocs/diskfont.doc) |
| iffparse.library | `LIBS:` | reading and writing IFF | [md](autodocs/iffparse.md) · [doc](autodocs/iffparse.doc) |
| rdb.library | `LIBS:` | a disk's RigidDiskBlock and partitions | [md](autodocs/rdb.md) · [doc](autodocs/rdb.doc) |
| modbus.library | `LIBS:` | Modbus over RTU and TCP, as a client and as a server | [md](autodocs/modbus.md) · [doc](autodocs/modbus.doc) |
| tls.library | `LIBS:` | TLS 1.3 and 1.2 sessions over a connected socket, the server's certificates checked | [md](autodocs/tls.md) · [doc](autodocs/tls.doc) |
| truetype.library | `LIBS:` | TrueType outlines into glyphs | [md](autodocs/truetype.md) · [doc](autodocs/truetype.doc) |

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
| keyboard.device | ROM | a keyboard, as raw keys | [`keyboard.zig`](../devices/keyboard.zig) |
| mouse.device | ROM | a mouse, as raw events | [`mouse.zig`](../devices/mouse.zig) |
| touch.device | ROM | a touch panel, as contacts | [`touch.zig`](../devices/touch.zig) |
| serial.device | ROM | the chip's UARTs, a unit each | [`serial.zig`](../devices/serial.zig) |
| usbserial.device | ROM | the USB-Serial-JTAG port, with serial.device's API | [`usbserial.zig`](../devices/usbserial.zig) |
| flash.device | ROM | the flash chip as a block device; unit 0 is the flash disk | [`trackdisk.zig`](../devices/trackdisk.zig) |
| i2c.device | ROM | the two I2C controllers | [`i2c.zig`](../devices/i2c.zig) |
| audio.device | ROM | four channels of sound | [`audio.zig`](../devices/audio.zig) |
| sdcard.device | `DEVS:` | the card slot as a block device | [`trackdisk.zig`](../devices/trackdisk.zig) |
| rs485.device | `DEVS:` | the RS-485 port, in frames | [`rs485.zig`](../devices/rs485.zig) |
| clipboard.device | `DEVS:` | what is cut, copied and pasted, a unit a clip | [`clipboard.zig`](../devices/clipboard.zig) |
| telnet.device | `DEVS:` | a TCP connection as a stream, for a console | [`telnet.zig`](../devices/telnet.zig) |
| openeth.device | `DEVS:networks/` | QEMU's Ethernet | [`network.zig`](../devices/network.zig) |
| wifi.device | `DEVS:networks/` | the chip's Wi-Fi, WPA2 | [`network.zig`](../devices/network.zig), [`wireless.zig`](../devices/wireless.zig) |

## Resources

Opened with `OpenResource`; calls only, no requests, and no open count.
All are in the ROM.

| Resource | What | Reference |
|---|---|---|
| platform.resource | what machine this is: the chip, its clocks, where the code and the stacks are, whether there is PSRAM | [md](autodocs/platform.md) · [doc](autodocs/platform.doc) |
| gpio.resource | who holds which of the chip's pads | [md](autodocs/gpio.md) · [doc](autodocs/gpio.doc) |
| dma.resource | the chip's general DMA engine, its channels one owner each | [md](autodocs/dma.md) · [doc](autodocs/dma.doc) |
| expander.resource | the board's IO expander: the pins the panel, the touch controller and the card hang on, the backlight, an analogue input | [md](autodocs/expander.md) · [doc](autodocs/expander.doc) |
| watchdog.resource | the chip's watchdog timer, armed, fed and disarmed by programs | [md](autodocs/watchdog.md) · [doc](autodocs/watchdog.doc) |

## Handlers

What answers the packets of a DOS device: a program reaches them through
dos.library's calls, never directly. dos starts a handler the first time
its device is used.

| Handler | Where | Serves | Reference |
|---|---|---|---|
| ram-handler | ROM | `RAM:`, a file system in memory | dos.library |
| con-handler | ROM | `CON:` and `RAW:`, a console in a window | dos.library |
| pipe-handler | ROM | `PIPE:`, a pipe between two processes | dos.library |
| nil-handler | ROM | `NIL:`, which swallows what is written | dos.library |
| flashfs-handler | ROM | `DH0:` and every partition of type `FLS\0` | [`flashfs.zig`](../libs/dos/flashfs.zig) |
| fat-handler | `HANDLERS:` | `SD0:`, FAT32 and exFAT on a card | dos.library |

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
| tapedeck.gadget | the buttons of a tape deck or a player | [`tapedeck.zig`](../libs/gadgets/tapedeck.zig) |
| calendar.gadget | a month, to pick a day from | [`calendar.zig`](../libs/gadgets/calendar.zig) |
| canvas.gadget | a picture a program draws into | [`canvas.zig`](../libs/gadgets/canvas.zig) |
| chart.gadget | values over time, as lines or bars | [`chart.zig`](../libs/gadgets/chart.zig) |
| qrcode.gadget | a text as a QR code | [`qrcode.zig`](../libs/gadgets/qrcode.zig) |
| barcode.gadget | a text as a Code 128 or an EAN-13 barcode | [`barcode.zig`](../libs/gadgets/barcode.zig) |
| keyboard.gadget | keys on the screen, for a board with none | [`keyboard.zig`](../libs/gadgets/keyboard.zig) |

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
