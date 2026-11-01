# PowerOS on an ESP32 board

Everything in this directory goes into one board's flash: the kernel, the
flash disk that holds the programs and libraries it was built with, and a
script that writes both over USB.

```sh
./flash.sh
```

`machine.conf` names the board this package is for and what goes where in
its flash. You need [esptool](https://docs.espressif.com/projects/esptool)
version 5 or newer - `pip install esptool`, or your system's package - a
USB cable, and something to read a serial port with (`tio`, `picocom`,
`screen`, or a terminal program with a serial window).

```
flash.sh        writes it to the board
machine.conf    which board it is, what goes where, and which port is its console
kernel.bin      the system itself: everything up to the file systems
kernel-flash.bin  on the ESP32-P4, the part of the kernel that runs from flash
disk.bin        the flash disk: C:, LIBS:, DEVS:, S:, the programs, the fonts
README.md       this
```

## Writing it

`./flash.sh` erases the disk area, then writes the kernel and the disk in
one pass. It finds esptool and the board's port itself; `--port` names
another, `--baud` writes at another rate, and `--print` shows the esptool
commands without running them.

The kernel and the disk belong together: the disk holds the programs and
the libraries this kernel was built with, and a kernel from one build with
a disk from another fails in ways that look like anything but a stale
disk. So write both unless you know why not. `--kernel` writes the kernel
alone and leaves the disk as it is; `--disk` writes a fresh disk alone,
erasing what was on it - every file saved on the board goes with it.

If esptool cannot reach the board: the console and the writing both go
through the chip's own USB port on most of these boards, and the port must
be opened with its DTR and RTS lines low or the chip resets. Close any
terminal that has the port open and try again.

## The first start

The board starts as it is reset, and the console says so. On it: the ROM's
log, then `s3>`, which is the ROM's own debug shell - `help` lists what it
takes. **Type `newshell`** there for a shell of the system's own:

```
List SYS:                 what is on the flash disk
Info                      the disk, its size and what is free
Avail                     memory, and the largest block there is
ShowConfig                what this board has; ShowConfig DEVICES for its devices
Version                   the system's release; Version dos.library for one module
Dir C: ALL                every command there is
```

A board with a panel draws the desktop on it a moment after the start,
with its own shell in `SYS:System/Shell` and the programs in
`SYS:Programs`. A board whose panel is touched is driven by touch; the
pointer follows a mouse on the USB port where there is one.

The flash disk keeps what is written to it, so the settings you change and
the files you save are there at the next start.

## What is not in it

The radio's driver is on the disk only when the build that made this
package had the vendor libraries for it; without it a board's Wi-Fi is
not there, and `C:net/Wireless` says so. Everything else the board has is
driven from the disk or the kernel.

## Where this comes from

PowerOS is a kernel and a system written in Zig for ESP32-S3 and ESP32-P4
boards, for 64-bit RISC-V machines under SBI firmware and for AArch64
machines under PSCI. The source, the boards and the guides are at
<https://github.com/cycl0ne/poweros_esp32>, and the same system runs in
QEMU from an archive of its own.
