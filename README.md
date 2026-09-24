# PowerOS for ESP32

PowerOS is an operating system for Espressif's ESP32 microcontrollers,
written in Zig. It boots straight from the chip's ROM loader - no ESP-IDF,
no second-stage bootloader - and brings up a complete little system:
a multitasking kernel with libraries and devices behind jump tables,
message passing, a DOS with processes, file systems and a shell, and a
windowed desktop with screens, windows, menus, gadgets and requesters on
the board's display.

Programs are loaded from the flash disk or an SD card at run time, and are
built against a separate SDK package - so writing one needs nothing of the
kernel's source.

**Status: release 0.1.** It runs on the ESP32-S3 boards below and in
Espressif's QEMU. The ESP32-P4 is next.

[![PowerOS drawing with graphics.library](docs/screenshots/anim.png)](docs/screenshots/README.md)

[![The shell](docs/screenshots/shell.png)](docs/screenshots/README.md#the-shell)

More in [the screenshots](docs/screenshots/README.md): fonts, menus, a
requester and gadgets.

## What is in it

**Kernel (exec)**
- Preemptive multitasking with priorities, signals, message ports,
  semaphores and software interrupts.
- Libraries and devices with jump tables, opened by name, loaded from disk
  on demand and expunged when memory runs short.
- Internal SRAM and 8 MiB of octal PSRAM, managed as memory with
  attributes (`MEMF_INTERNAL`, `MEMF_EXTERNAL`, `MEMF_DMA`).
- The CPU at 240 MHz, code executing from flash through the cache and MMU,
  interrupts routed through the chip's interrupt matrix.

**DOS**
- Processes, packets, handlers started on first use, assigns and paths,
  pattern matching, `ReadArgs` templates, and load files (`.seg`) read by
  `LoadSeg`.
- File systems: a log-structured flash file system that survives power
  cuts and levels wear (`DH0:`), FAT32 on SD cards with long names (`SD0:`),
  `RAM:`, `PIPE:` and `NIL:`.
- Consoles `CON:`, `RAW:` and `AUX:` with line editing, history, and
  copy and paste by mouse and keyboard.
- A shell with variables, aliases, redirection, scripts and resident
  commands, and 26 commands in `C:` - `Dir`, `List`, `Copy`, `Assign`,
  `Info`, `Format`, `Mount`, `Version` and more - with test programs for
  the devices and libraries in `C:test`.

**Graphics and windows**
- rtg.library for the displays and their drivers, graphics.library for
  drawing (lines, fills, blits, text, the system's own `pospaz.font` at 8
  and 16 rows), layers.library for overlapping windows.
- intuition.library: screens, windows, menus, requesters, and an object
  system of classes for gadgets and images (buttons, sliders, string
  fields, groups).

**Devices**
- Timer, serial, USB serial, flash, SD card, I2C, touch, keyboard, mouse,
  input, console and four-channel audio; watchdog, DMA, GPIO and platform
  resources.
- Board facts - which parts are fitted and how they are wired - are data
  in a board description, and drivers ask for their part at run time.

## Boards

| `-Dboard=` | Board | State |
|---|---|---|
| `waveshare_7b` (default) | Waveshare ESP32-S3-Touch-LCD-7B: 7" 1024×600 RGB panel, GT911 touch, 16 MB flash, 8 MB PSRAM | runs |
| `es3c35p` | LCDwiki ES3C35P: 3.5" 480×320 QSPI panel, touch, ES8311 audio codec, SD card slot | runs: panel, touch, speaker, card |
| `qemu` | Espressif QEMU's ESP32-S3, with display, keyboard and mouse | runs |

`C:ShowConfig` lists what the running board has.

## Quick start

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

For the display in QEMU, build the patched QEMU once with
`scripts/build-qemu.sh` (into `toolchain/qemu/`): it adds the 1024×600
display with keyboard and mouse, and runs the core at 240 MHz.

More build steps and options:

| Command | What it does |
|---|---|
| `./zig build -Dboard=es3c35p` | any step for another board |
| `./zig build flash` | the kernel only; the disk is kept |
| `./zig build flash-disk` | a fresh, empty file system on the board's disk |
| `./zig build qemu-disk` | QEMU on an image whose disk keeps what is written |
| `./zig build fd` | regenerate the SDK's interfaces from its `.fd` files |
| `-Dextra=c/hello=path/to/hello.seg` | put a file built elsewhere on the disk image |

On a board the serial console is the chip's USB port
(e.g. `tio /dev/ttyACM0`); the display comes up with a shell window.

## Writing a program

The SDK (`sdk/`) is a Zig package of its own. A program depends on it and
builds with `addProgram`, which knows the chip, the linker script and how
to make the load file:

```zig
// build.zig
const std = @import("std");
const poweros_sdk = @import("poweros_sdk");

pub fn build(b: *std.Build) void {
    const sdk = b.dependency("poweros_sdk", .{});
    const seg = poweros_sdk.addProgram(b, sdk, .{ .name = "hello", .root = b.path("hello.zig") });
    b.getInstallStep().dependOn(&b.addInstallBinFile(seg, "hello.seg").step);
}
```

The programs in `src/disk/c/` are all built this way and are the best
examples: each opens its libraries, reads its arguments with a `ReadArgs`
template and carries a `$VER:` string.

## Repository layout

```
src/arch/      the chip: boot, exceptions, clock, MMU, PSRAM, interrupts
src/rom/       what is in the ROM: libraries, devices, handlers, resources, shell
src/boards/    one folder per board: its parts and wiring, and its drivers
src/disk/      what goes on the disk: commands, test programs, disk-loaded
               libraries, devices and handlers, startup scripts (a package)
sdk/           the SDK: types, constants, jump tables, tools (a package)
tools/         build helpers: mkfs, ressize, checks
scripts/       the QEMU build and a serial terminal
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

Every source file names its license in its first line
(`SPDX-License-Identifier`).
