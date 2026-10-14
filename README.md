# PowerOS for ESP32

PowerOS is an operating system for Espressif's ESP32 microcontrollers,
written in Zig. It boots straight from the chip's ROM loader and brings up
a complete little system: a multitasking kernel with libraries and
devices, a DOS with file systems and a shell, a TCP/IP stack, and a
windowed desktop on the board's display. Programs are loaded from disk at
run time and built against a separate SDK.

**Status: release 0.2.** It runs on two ESP32-S3 boards, on two
ESP32-P4 boards and in Espressif's QEMU.

[![PowerOS multitasking on the 7" Waveshare board](docs/screenshots/board-waveshare-7b.jpg)](docs/screenshots/README.md#on-the-board)

<p>
<a href="docs/screenshots/README.md#music-sysprogramsplayer"><img src="docs/screenshots/player-wave.png" width="49%" alt="Player on the Olimex's 2.8-inch panel: a mix's cover, tags and chapter, and its wave"></a>
<a href="docs/screenshots/README.md#music-sysprogramsplayer"><img src="docs/screenshots/player-bars.png" width="49%" alt="Player on the Olimex's 2.8-inch panel: the same mix as the spectrum's bars"></a>
</p>
<p>
<a href="docs/screenshots/README.md#the-desktop-anvil"><img src="docs/screenshots/desktop.png" width="49%" alt="The desktop: the System disk opened, its drawers and its programs"></a>
<a href="docs/screenshots/README.md#notepad-sysprogramsnotepad"><img src="docs/screenshots/notepad.png" width="49%" alt="Notepad with S:Startup-Sequence, line numbers on"></a>
</p>
<p>
<a href="docs/screenshots/README.md#on-the-board"><img src="docs/screenshots/board-olimex-p4pc.jpg" width="49%" alt="The Olimex ESP32-P4-PC on a television over HDMI, with a USB keyboard and mouse: Plasma, Lines and CPU Load"></a>
<a href="docs/screenshots/README.md#on-the-board"><img src="docs/screenshots/board-es3c35p.jpg" width="49%" alt="The ES3C35P's 3.5-inch panel with the shell after boot"></a>
</p>

## Contents

| | |
|---|---|
| [Screenshots](docs/screenshots/README.md) | the Player, the shell, Notepad, CPU load, drawing, a game, fonts, menus, gadgets, on the boards |
| [What PowerOS is - and what it is not](#what-poweros-is---and-what-it-is-not) | the idea, and what is in it |
| [Quick start](#quick-start) | boards, building, [QEMU the first time](#first-time-in-qemu), flashing |
| [Writing programs](sdk/docs/guides/programs.md) | examples: hello in the shell, a window, buttons |
| [The SDK](sdk/) | the package a program builds against |
| [Autodocs](sdk/docs/README.md) | every call, and every module by kind |
| [Guides](sdk/docs/README.md#guides) | how the calls work together: [exec](sdk/docs/guides/exec.md), [dos](sdk/docs/guides/dos.md), [utility](sdk/docs/guides/utility.md), [intuition](sdk/docs/guides/intuition.md), [desktop](sdk/docs/guides/anvil.md), [icons](sdk/docs/guides/icons.md), [fonts](sdk/docs/guides/fonts.md), [styles](sdk/docs/guides/styles.md), [motion](sdk/docs/guides/motion.md), [datatypes](sdk/docs/guides/datatypes.md), [network](sdk/docs/guides/network.md), [USB](sdk/docs/guides/usb.md), [disks](sdk/docs/guides/rdb.md), [Modbus](sdk/docs/guides/modbus.md), [sound](sdk/docs/guides/audio.md), [displays](sdk/docs/guides/rtg.md) |
| [Wi-Fi](docs/esp32s3wifi.md) | the ESP32-S3's radio's device, and how it is built |
| [USB Wi-Fi](docs/aic8800.md) | the AIC8800 stick's device, and how it is built |
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
- **It is** young. 0.2 works end to end, but the API may change before
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
- **It does not (yet)** have Bluetooth.

### What is in it

- **Kernel (exec):** preemptive multitasking on both of the chip's cores,
  signals, message ports, semaphores and checked spinlocks, every system
  list under a lock of its own; libraries and devices opened by name,
  loaded from disk when wanted and expunged when memory runs short;
  internal SRAM and PSRAM as memory with attributes. A system log from
  the first byte of the boot (`C:Log` sends it to a syslog server), a
  Guru with a ROM debugger on the serial ports, and a program that fails
  held and asked about while the system runs on. `C:Top` and
  `SYS:Programs/CPULoad` show what each task and core takes.
- **DOS:** processes, handlers, assigns, patterns, `ReadArgs`; a
  log-structured flash file system (`DH0:`), FAT32 and exFAT on SD cards
  (`SD0:`) and USB sticks (`DU0:`), `RAM:`, `PIPE:`, `NIL:`; partitions
  from a RigidDiskBlock ([disks guide](sdk/docs/guides/rdb.md));
  notification when a file changes; consoles with line editing, file
  name completion, and copy and paste; a shell with scripts and 48
  commands in `C:` - `ScreenDump` saves a screen as a PNG - test programs
  in `C:test` and network tools in `C:net`.
- **Desktop and programs:** `LIBS:anvil.library` puts the disks, drawers
  and icons on the Workbench screen, with drag and drop, a trash and
  Information on any file ([desktop guide](sdk/docs/guides/anvil.md));
  `LIBS:icon.library` reads icons drawn as PNGs
  ([icons guide](sdk/docs/guides/icons.md)). In `SYS:Programs`, each with
  its readme in `SYS:Programs/Docs`: MultiView, Notepad, Sheet (a
  spreadsheet with formulas, reading and writing CSV), Terminal (a VT100
  on a serial line), Player (WAV and MP3 with their cover, tags and
  chapters, and a plasma, the wave or the spectrum of what is heard),
  FontView, CPULoad, Battery and Prefs.
- **Graphics and windows:** rtg.library for the displays - on the
  ESP32-P4 its 2D engine fills, copies, blends and scales;
  graphics.library with smooth curves, gradients, shadows and scaled
  pictures; layers.library; intuition.library with screens, windows,
  menus, requesters and gadget classes in layouts that fit any display,
  everything drawn from a style a screen carries
  ([styles guide](sdk/docs/guides/styles.md)). More gadgets in
  `SYS:classes/gadgets/` - tabs, charts, dials, a calendar, rich text, QR
  codes, a keyboard on the screen, text to edit with undo - the
  requesters of `LIBS:asl.library`, and motion.library for whatever moves
  ([motion guide](sdk/docs/guides/motion.md)).
- **Datatypes and fonts:** `LIBS:datatypes.library` opens pictures (ILBM,
  BMP, PNG, GIF, JPEG - on the ESP32-P4 by its codec), text (plain, FTXT,
  Markdown), animations (GIF, Lottie) and sounds (WAV, MP3, 8SVX, played
  as they are read) by what is in them
  ([datatypes guide](sdk/docs/guides/datatypes.md)); fonts bitmap and
  TrueType, at any size ([fonts guide](sdk/docs/guides/fonts.md)).
- **Sound:** `audio.device` mixes up to sixteen streams, each in its own
  form, rate, volume and pan, out of an ES8311 codec or I2S amplifiers;
  `LIBS:audiocodec.library` decodes WAV and MP3 as they play and reads
  their tags, covers and chapters (`C:Play`,
  [sound guide](sdk/docs/guides/audio.md)).
- **Network:** a TCP/IP stack of its own (`LIBS:bsdsocket.library`: TCP,
  UDP, IPv4 and IPv6, DHCP, DNS, multicast) on Ethernet, USB Ethernet
  adapters, the ESP32-S3's Wi-Fi, USB Wi-Fi sticks (AIC8800) and SLIP;
  WPA2-Personal in `LIBS:wpa.library`; a shell over Telnet or SSH with
  sftp and scp, an SSH client, a packet filter, and TLS 1.3 and 1.2 for
  `C:net/HTTPGet` ([network guide](sdk/docs/guides/network.md)).
- **USB:** a host stack on the chip's OTG controller - at high speed on
  the ESP32-P4, through hubs - with class drivers loaded as their devices
  are plugged in: keyboards, mice and tablets, sticks and card readers,
  FTDI and CDC-ACM serial adapters, CDC Ethernet, AIC8800 Wi-Fi sticks
  ([USB guide](sdk/docs/guides/usb.md)).
- **Modbus:** `LIBS:modbus.library` over RS-485 and TCP, asking and
  answering; `C:Modbus` in the shell, and `SYS:Programs/Battery` for a
  battery a Victron GX device reports
  ([Modbus guide](sdk/docs/guides/modbus.md)).
- **Devices and resources:** timer, serial, USB serial, RS-485, flash, SD
  card, I2C, touch, keyboard and mouse from any source, console,
  watchdog, DMA, GPIO, IO expander, the JPEG codec, the battery
  (`C:Battery`), the date kept while the system is off
  (`C:SetClock`), and `LIBS:crypto.library` on the chip's SHA, AES and
  RSA engines.
- **Boards are data:** which parts are fitted and how they are wired is a
  description in the ROM; drivers ask for their part at run time.

## Quick start

### Boards

| `-Dboard=` | Board | State |
|---|---|---|
| `waveshare_7b` (default) | Waveshare ESP32-S3-Touch-LCD-7B: 7" 1024×600 RGB panel, GT911 touch, 16 MB flash, 8 MB PSRAM, microSD slot on SPI, RS-485, CAN, battery charger | runs: panel, touch, Wi-Fi, the card slot; not yet tried on the board: RS-485, the battery's voltage, a USB host on its USB-C socket; CAN not driven |
| `es3c35p` | LCDwiki ES3C35P: 3.5" 480×320 QSPI panel, touch, ES8311 audio codec, SD card slot | runs: panel, touch, speaker, card; not yet tried on the board: audio.device 2's streams, the battery's voltage, a USB host |
| `qemu` | Espressif QEMU's ESP32-S3, with display, keyboard and a mouse with a wheel, an RS-485 port on its second serial port, and a USB controller with what `-Dusb` plugs in | runs, USB devices plugged in and out while it does (`-Dusb`, `-Dusb-disk`); no sound |
| `esp32p4_emu` | Espressif's esp-emulator running an ESP32-P4 on the boards' v1.x ROM: both cores, UART0, 32 MB PSRAM (`./zig build emu`) | the shell on UART0, dos with the flash disk and its RISC-V commands, a Guru with the ROM debugger; `-Dselftest` checks the chip; no screen |
| `olimex_p4pc` | Olimex ESP32-P4-PC: ESP32-P4NRW32 (16 MB flash, 32 MB PSRAM), console on the chip's USB port, 10/100 Ethernet (IP101GRR), HDMI, a MIPI-DSI connector (here Olimex's MIPI-LCD2.8, 480×640), four USB host ports, ES8311 audio, microSD | runs: the USB console, Ethernet, the desktop on the DSI panel or at 800×600 over HDMI ([photo](docs/screenshots/README.md#on-the-board)), both cores, PSRAM at 200 MHz, the 2D engine and the JPEG codec, USB keyboards, mice and sticks through its hub, the microSD card, sound on the jack (the codec's one output on both sides) - the [Player](docs/screenshots/README.md#music-sysprogramsplayer) on its panel; an AIC8800 USB Wi-Fi stick, joined to WPA2 networks; the battery once its solder jumpers are closed |
| `crowpanel_p4` | Elecrow CrowPanel Advanced 10.1": ESP32-P4NRW32, console on UART0 through a CH340K, 1024×600 MIPI-DSI panel, GT911 touch, ESP32-C6 for Wi-Fi, two speakers on NS4168 I2S amplifiers, two PDM microphones, SD slot | runs: the shell on UART0, the desktop on its panel with touch, both cores, PSRAM at 200 MHz, the 2D engine and the JPEG codec, stereo on its speakers; not yet tried on the board: audio.device 2's streams, the UART1 and UART3-IN connectors |

`C:ShowConfig` lists what the running board has, and `ShowConfig DEVICES`
every device by what it speaks - serial lines, block devices, network
devices, ... (`SPEAKS=serial`) - with its units on this board, none of
them opened or loaded to find out.

You need Linux or macOS, `esptool` (v5) to flash, and for the emulator
Espressif's QEMU. Always build with the `./zig` wrapper: it fetches the
Espressif Zig toolchain (`0.16.0-xtensa`) into `toolchain/` on first use.

```sh
./zig build                  # the kernel and a flash disk: zig-out/bin/flash.bin
./zig build test             # host tests; every board and every program compiles
./zig build qemu             # boot in QEMU on the serial console (quit: Ctrl-A X)
./zig build qemu-display     # the same with the display in a window
./zig build emu              # the ESP32-P4 kernel in esp-emulator (quit: Ctrl-C)
./zig build flash-all -Dport=/dev/ttyACM0   # kernel and a fresh disk onto a board
```

Fetched once into `toolchain/`, pinned and checked, never committed:

| Script | For |
|---|---|
| `scripts/build-qemu.sh` | QEMU with the 1024×600 display, keyboard, mouse and wheel, and the USB controller, at 240 MHz (an older QEMU runs too, without what it lacks - run the script again for the wheel and USB) |
| `scripts/fetch-wifi.sh` | the radio's vendor libraries for `DEVS:networks/esp32s3wifi.device` |
| `scripts/fetch-aic8800.sh` | the AIC8800 USB Wi-Fi stick's firmware, which `DEVS:usb/aic8800.device` loads into it (the ESP32-P4's disk) |
| `scripts/fetch-fonts.sh` | the fonts in `FONTS:` (Spleen, Go) |
| `scripts/fetch-certs.sh` | Mozilla's root certificates, made into the trust store `SYS:Certificates/Roots` |
| `scripts/fetch-icons.sh` | the pictures of the disk's icons (Tango, public domain), drawn at the boards' sizes |
| `scripts/fetch-esp-emu.sh` | Espressif's esp-emulator, which runs the ESP32-P4: both cores, its interrupt controller, UART0 on the terminal, the system timer, flash, PSRAM, the Ethernet MAC and a GDB stub, from the chip's own ROM; no display. With it the v1.x chips' ROM (Espressif's ROM ELFs), which `./zig build emu` boots |

Without them the disk has everything but that part. On a board the serial
console is the chip's USB port (e.g. `tio /dev/ttyACM0`); the display
comes up with the desktop, which S:Startup-Sequence starts at its end
before it puts its own shell window away - `SYS:System/Shell` opens
another. A desktop that cannot start leaves that shell on the display.

### First time in QEMU

From a fresh clone to the desktop in a window:

```sh
scripts/build-qemu.sh        # once: QEMU with the display, into toolchain/qemu
scripts/fetch-icons.sh       # optional: the desktop's icons
scripts/fetch-fonts.sh       # optional: the fonts
./zig build qemu-display     # the first run also fetches the Zig toolchain
```

`scripts/build-qemu.sh` runs on Linux. It needs a C compiler, git,
Python 3, ninja, pkg-config, and the development files of glib, pixman,
SDL2, libgcrypt and libslirp:

```sh
# Debian, Ubuntu
sudo apt install build-essential git python3 python3-venv ninja-build pkg-config \
    libglib2.0-dev libpixman-1-dev libsdl2-dev libgcrypt20-dev libslirp-dev
# Arch
sudo pacman -S --needed base-devel git python ninja glib2 pixman sdl2 libgcrypt libslirp
```

`scripts/fetch-icons.sh` draws the icons at each board's size with
`rsvg-convert` (`librsvg2-bin`, `librsvg`); without it they are the
release's 32-pixel pictures.

The window shows the boot and then the desktop; `SYS:System/Shell` opens
a shell on it. The terminal QEMU runs in is the serial console: `s3>`
there is the ROM's debug shell, `newshell` starts a CLI (`List`, `Info`,
...), and Ctrl-A X quits QEMU. `qemu-display` also forwards host port
2323 to the machine's Telnet port and 2222 to its SSH port, for
`C:net/ShellServer`.

More build steps and options:

| Command | What it does |
|---|---|
| `./zig build -Dboard=es3c35p` | any step for another board |
| `./zig build flash` | the kernel only; the disk is kept |
| `./zig build flash-disk` | a fresh, empty file system on the board's disk |
| `./zig build qemu-disk` | QEMU on an image whose disk keeps what is written |
| `./zig build fd` | regenerate the SDK's interfaces from its `.fd` files |
| `./zig build autodoc` | regenerate the SDK's autodocs from the doc comments |
| `./zig build modchart` | regenerate the charts of which module uses which (`sdk/docs/modules.md`) |
| `-Dextra=c/hello=path/to/hello.seg` | put a file built elsewhere on the disk image |
| `-Dnet=none` | the `qemu*` steps without a network, or another QEMU `-nic` backend |
| `-Dnet-dump=net.pcap` | every frame of the `qemu*` steps' network, for Wireshark |
| `-Dtelnet=2323` | forward that host port to the machine's port 23 (`C:net/ShellServer`) |
| `-Dssh=2222` | forward that host port to the machine's port 22 (`C:net/ShellServer SSH`); qemu-display forwards 2222 itself |
| `-Drs485=tcp::5020,server,nowait` | the `qemu*` steps' RS-485 port (`rs485.device`) on that QEMU serial backend |
| `-Dslip=tcp::5021,server,nowait` | the `qemu*` steps' UART1 (`serial.device` unit 1, a SLIP line) on that QEMU serial backend; not with `-Drs485` |
| `-Dusb=usb-hub,usb-kbd,usb-mouse` | the `qemu*` steps' USB devices, QEMU's names (`usb-tablet`, `usb-serial` on a pty, `usb-net` on a network of its own, 10.0.3.0/24, too); an item with `=` is a property of the one before (`usb-kbd,id=kb1`, for `device_del kb1` in the monitor) |
| `-Dusb-disk=stick.img` | a USB stick in the `qemu*` steps, its contents that image |
| `-Dcores=1` | the cores the kernel runs on: 1 or 2 (default: what the board says - two on every board and in `qemu`) |
| `-Dselftest` | the ESP32-P4's boot task checks the chip (its blocks, DMA, PSRAM, the flash) and runs test tasks on both cores, rather than the shell |

## Repository layout

```
src/arch/      the chip: boot, exceptions, clock, MMU, PSRAM, interrupts
src/rom/       what is in the ROM: libraries, devices, handlers, resources, shell
src/boards/    one folder per board: its parts and wiring, and its drivers
src/disk/      what goes on the disk: commands, test programs, disk-loaded
               libraries, devices and handlers, startup scripts (a package)
sdk/           the SDK: types, constants, jump tables, autodocs, tools (a package)
tools/         build helpers: mkfs, ressize, ramimage, mkicon, the autodocs, the module charts, checks
scripts/       the QEMU build and its patches, the pinned fetches (Wi-Fi libraries and firmware, fonts, certificates, icons, esp-emulator), a serial terminal
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
- The patches in `scripts/qemu/` change QEMU and are under QEMU's
  license, GPL-2.0-or-later.
- `C:test/BsdSockTest` (`src/disk/c/test/bsdsocktest/`) is Thomas Dye's
  bsdsocktest in Zig and under its license,
  [GPL-3.0-only](src/disk/c/test/bsdsocktest/LICENSE); the disk image
  holds it as a program of its own.

Every source file names its license in its first line
(`SPDX-License-Identifier`).
