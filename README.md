# PowerOS for ESP32

PowerOS is an operating system for Espressif's ESP32 microcontrollers,
written in Zig. It boots straight from the chip's ROM loader and brings up
a complete little system: a multitasking kernel with libraries and
devices, a DOS with file systems and a shell, a TCP/IP stack, and a
windowed desktop on the board's display. Programs are loaded from disk at
run time and built against a separate SDK.

**Status: release 0.1.** It runs on two ESP32-S3 boards and in
Espressif's QEMU. The ESP32-P4 is next.

[![PowerOS multitasking on the 7" Waveshare board](docs/screenshots/board-waveshare-7b.jpg)](docs/screenshots/README.md#on-the-board)

## Contents

| | |
|---|---|
| [Screenshots](docs/screenshots/README.md) | the shell, drawing, a game, fonts, menus, gadgets, on the boards |
| [What PowerOS is - and what it is not](#what-poweros-is---and-what-it-is-not) | the idea, and what is in it |
| [Quick start](#quick-start) | boards, building, QEMU, flashing |
| [Writing programs](sdk/docs/guides/programs.md) | examples: hello in the shell, a window, buttons |
| [The SDK](sdk/) | the package a program builds against |
| [Autodocs](sdk/docs/README.md) | every library, device and resource call |
| [Guides](sdk/docs/README.md#guides) | how the calls work together: [fonts](sdk/docs/guides/fonts.md), [styles](sdk/docs/guides/styles.md), [network](sdk/docs/guides/network.md) |
| [Wi-Fi](docs/wifi.md) | the radio's device, and how it is built |
| [Example programs](src/disk/c/) | every command on the disk, built the same way |
| [Repository layout](#repository-layout) | where things are |
| [License](#license) | MPL-2.0 for the system, MIT for the SDK and programs |

## What PowerOS is - and what it is not

- **It is** a desktop-style operating system small enough to read: kernel,
  DOS, file systems, network, graphics and windows in well under a
  megabyte of code, on a microcontroller that costs a few euros. It is
  built from small modules that talk through message ports and jump
  tables; a library or a device can be replaced, loaded from disk or
  patched at run time.
- **It is** made for the ESP32 family. It drives the chip itself, register
  by register, so everything between power-on and the desktop is in this
  tree.
- **It is** young. 0.1 works end to end, but the API may change before
  1.0, and not every part has run on every board.
- **It is not** a Linux, a POSIX system or an RTOS in the usual sense:
  programs use the system's own API - libraries opened by name, tag lists,
  messages - with no `libc` and no `fork`.
- **It is not** an AmigaOS clone or emulator. It takes AmigaOS's ideas -
  exec's libraries, devices and message ports, dos with handlers and
  packets, screens, windows and gadget classes - and builds them anew for
  this machine: no BCPL pointers or strings, 32- and 64-bit data,
  retargetable true-colour graphics, boards described as data. It runs no
  Amiga software.
- **It is not** a protected system. All tasks share one address space; it
  is a machine for one person at a time.
- **It does not (yet)** have Bluetooth, USB host support, or use the
  chip's second core.

### What is in it

- **Kernel (exec):** preemptive multitasking, signals, message ports,
  semaphores; libraries and devices opened by name, loaded from disk on
  demand and expunged when memory runs short; internal SRAM and 8 MiB of
  PSRAM as memory with attributes; a system log of everything written to
  the serial console since the boot (`C:Log`), and a Guru that names the
  failed check and the file and offset it is in, and offers a ROM
  debugger - registers, memory, a backtrace, breakpoints, watchpoints
  and single step - on both serial ports at once, reachable with
  whichever cable is plugged in.
- **DOS:** processes, handlers, assigns, patterns, `ReadArgs`; names of
  255 characters and paths of 1024 throughout; `ErrorReport` asking
  "Please insert volume ..." on the screen, or on the console where there
  is none; a
  log-structured flash file system (`DH0:`), FAT32 and exFAT on SD cards (`SD0:`),
  `RAM:`, `PIPE:`, `NIL:`; consoles with line editing and copy and paste;
  a shell with scripts and resident commands, 36 commands in `C:`, test
  programs in `C:test` and network tools in `C:net`.
  `LIBS:iffparse.library` reads and writes IFF, the shape a picture, a
  piece of text or a sound is kept in when one program hands it to
  another, and `DEVS:clipboard.device` is where it is handed over: a
  unit is a clip, kept as a file in `CLIPS:`.
  `LIBS:datatypes.library` opens a file by what is in it: the kinds the
  system knows are text descriptors in `DEVS:DataTypes`, and a program
  gets an object it can put in a window without knowing the format. The
  classes that read the formats are in `SYS:classes/datatypes/`: every
  still picture is a `picture.datatype` object, kept as pens and drawn,
  scrolled, scaled and written out by that class whatever file it came
  out of - and one larger than the machine can hold is kept at half, a
  quarter or an eighth of its size rather than refused, and `ilbm.datatype` reads IFF `ILBM` - packed rows, the
  half-bright and hold-and-modify displays, and twenty-four planes -
  `bmp.datatype` Windows bitmaps at every depth, packed or plain,
  `png.datatype` PNG - every colour kind, every depth,
  interlaced or not - `gif.datatype` GIF, with the see-through colour and
  the picture placed on the screen the file names, and `jpeg.datatype`
  baseline JPEG, its colour planes taken smoothly. Every piece of text is
  a `text.datatype` object - runs of it in their own fonts, styles and
  pens, wrapped to the window, marked with the pointer and copied to the
  clipboard - and `ascii.datatype` reads a plain file or an IFF `FTXT`,
  `markdown.datatype` a Markdown document with its headings, emphasis,
  listings, lists and links.
  A small file of each
  format is in
  `SYS:Tests/datatypes/`, and `SYS:Programs/MultiView` shows any of them
  in a window with scroll bars, knowing no formats itself. See the
  [datatypes guide](sdk/docs/guides/datatypes.md).
- **Graphics and windows:** rtg.library for the displays, graphics.library
  for drawing - including a picture of one's own pixels put down as it
  is, laid over what is there by its own coverage, or at another size;
  rectangles with rounded corners, pies and rings, outlines of any width
  that grow inward so a shape keeps its size, curves and slanted lines
  with smooth edges and pictures scaled smoothly, any filled shape in a
  gradient (linear or radial, dithered on 16-bit displays) or a tile, a
  surface laid down through a coverage that can be softened into a
  shadow, and a string drawn to fit a width with dots where it was cut -
  layers.library for overlapping windows, and
  intuition.library - screens, windows, menus, requesters, a mouse
  pointer, and an object system of gadget classes with layouts that fit
  any display - a layout in a frame with a title in its edge groups the
  settings of a window, a grid lines labelled fields up in columns, a row
  too narrow for its gadgets wraps them onto the next line, and a child
  sits at the start, the middle or the end of its room. Everything intuition draws - frames, buttons,
  fields, scroll bars, check boxes, radio buttons, window borders and title
  bars, the screen's bar, menus and requesters, and the disk's gadget
  classes with them, down to a list's chosen line and a gauge's level - is
  drawn from a style: the look of each
  part of a gadget in each state - pressed, checked, disabled, under the
  pointer, holding the keyboard - given as a tag list that a screen
  carries for all its windows and a single gadget may override, so a
  screen can look different with no program changed (`C:test/Styles`).
  The system's own style comes from `ENV:Sys/style.prefs`, a line per
  part and state, which `C:StylePrefs` hands over at boot and again
  whenever it is run: every open window is drawn again in it. See the
  [styles guide](sdk/docs/guides/styles.md).
  More gadget classes on the disk in
  `SYS:classes/gadgets/`, worked by the pointer or by the letter
  underlined in each label: among them a row of tabs over pages of
  gadgets, a number field with stepping arrows, a button that pops a list
  up to pick from, a bar that shows how far along something is, and a
  field with a button that opens the file or font requester.
  Settings a program can change while it runs (`SetPrefs`), and messages
  for a medium going in or out. `LIBS:asl.library` asks which file or
  which font, from a program or from the shell (`C:RequestFile`,
  `C:RequestChoice`).
- **Fonts:** of any size, proportional, in ink, smooth or colour; bitmap
  fonts and TrueType outlines in `FONTS:`, sizes in points, and the
  system's fonts set in `ENVARC:Sys/font.prefs`. `SYS:Programs/FontView`
  shows them all. See the [fonts guide](sdk/docs/guides/fonts.md).
- **Network:** a TCP/IP stack written here (`LIBS:bsdsocket.library`:
  TCP, UDP, IPv4 and IPv6, DHCP, DNS), network devices for QEMU's Ethernet
  and the chip's Wi-Fi (WPA2), brought up at boot from
  `DEVS:NetInterfaces/`, and a shell over Telnet (`C:net/ShellServer`).
  See the [network guide](sdk/docs/guides/network.md).
- **Devices:** timer, serial, USB serial, flash, SD card, I2C, touch,
  keyboard, mouse, input, console, four-channel audio; watchdog, DMA, GPIO
  and platform resources; `LIBS:crypto.library` on the chip's SHA, AES and
  RSA engines.
- **Boards are data:** which parts are fitted and how they are wired is a
  description in the ROM; drivers ask for their part at run time.

## Quick start

### Boards

| `-Dboard=` | Board | State |
|---|---|---|
| `waveshare_7b` (default) | Waveshare ESP32-S3-Touch-LCD-7B: 7" 1024×600 RGB panel, GT911 touch, 16 MB flash, 8 MB PSRAM, microSD slot on SPI, RS-485, CAN, battery charger | runs: panel, touch, Wi-Fi, card slot on SPI; RS-485 and CAN described but not driven |
| `es3c35p` | LCDwiki ES3C35P: 3.5" 480×320 QSPI panel, touch, ES8311 audio codec, SD card slot | runs: panel, touch, speaker, card |
| `qemu` | Espressif QEMU's ESP32-S3, with display, keyboard and mouse | runs |

`C:ShowConfig` lists what the running board has.

You need Linux or macOS, `esptool` (v5) to flash, and for the emulator
Espressif's QEMU. Always build with the `./zig` wrapper: it fetches the
Espressif Zig toolchain (`0.16.0-xtensa`) into `toolchain/` on first use.

```sh
./zig build                  # the kernel and a flash disk: zig-out/bin/flash.bin
./zig build test             # host tests; every board and every program compiles
./zig build qemu             # boot in QEMU on the serial console (quit: Ctrl-A X)
./zig build qemu-display     # the same with the display in a window
./zig build flash-all -Dport=/dev/ttyACM0   # kernel and a fresh disk onto a board
```

Fetched once into `toolchain/`, pinned and checked, never committed:

| Script | For |
|---|---|
| `scripts/build-qemu.sh` | QEMU with the 1024×600 display, keyboard and mouse, at 240 MHz (an older QEMU runs too, without the mouse pointer) |
| `scripts/fetch-wifi.sh` | the radio's vendor libraries for `DEVS:networks/wifi.device` |
| `scripts/fetch-fonts.sh` | the fonts in `FONTS:` (Spleen, Go) |

Without them the disk has everything but that part. On a board the serial
console is the chip's USB port (e.g. `tio /dev/ttyACM0`); the display
comes up with a shell window.

More build steps and options:

| Command | What it does |
|---|---|
| `./zig build -Dboard=es3c35p` | any step for another board |
| `./zig build flash` | the kernel only; the disk is kept |
| `./zig build flash-disk` | a fresh, empty file system on the board's disk |
| `./zig build qemu-disk` | QEMU on an image whose disk keeps what is written |
| `./zig build fd` | regenerate the SDK's interfaces from its `.fd` files |
| `./zig build autodoc` | regenerate the SDK's autodocs from the doc comments |
| `-Dextra=c/hello=path/to/hello.seg` | put a file built elsewhere on the disk image |
| `-Dnet=none` | the `qemu*` steps without a network, or another QEMU `-nic` backend |
| `-Dnet-dump=net.pcap` | every frame of the `qemu*` steps' network, for Wireshark |
| `-Dtelnet=2323` | forward that host port to the machine's port 23 (`C:net/ShellServer`) |

## Repository layout

```
src/arch/      the chip: boot, exceptions, clock, MMU, PSRAM, interrupts
src/rom/       what is in the ROM: libraries, devices, handlers, resources, shell
src/boards/    one folder per board: its parts and wiring, and its drivers
src/disk/      what goes on the disk: commands, test programs, disk-loaded
               libraries, devices and handlers, startup scripts (a package)
sdk/           the SDK: types, constants, jump tables, autodocs, tools (a package)
tools/         build helpers: mkfs, ressize, checks
scripts/       the QEMU build, the pinned fetches (Wi-Fi libraries, fonts), a serial terminal
```

## License

Copyright (c) 2026 Claus Herrmann and the PowerOS contributors.

- **The system** - everything outside `sdk/` and `src/disk/` - is under
  the [Mozilla Public License 2.0](LICENSE): a changed file stays under it
  and its source is published with what ships it; new files of one's own,
  such as a driver or a board, may be under any license.
- **The SDK** (`sdk/`) and **the disk's programs** (`src/disk/`) are under
  the [MIT license](sdk/LICENSE), so a program built against the SDK is
  its author's to license as they like.
- `scripts/qemu/esp_rgb_input.patch` changes QEMU and is under QEMU's
  license, GPL-2.0-or-later.
- `C:test/BsdSockTest` (`src/disk/c/test/bsdsocktest/`) is Thomas Dye's
  bsdsocktest in Zig and under its license,
  [GPL-3.0-only](src/disk/c/test/bsdsocktest/LICENSE); the disk image
  holds it as a program of its own.

Every source file names its license in its first line
(`SPDX-License-Identifier`).
