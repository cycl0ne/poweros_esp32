# PowerOS on a 64-bit board

The files in this directory are what the board's firmware loads: the
system itself, and the disk image it runs from. `machine.conf` names the
board this package is for.

```sh
./write.sh /run/media/you/BOOT     # the board's boot partition, mounted
```

```
write.sh        copies the files onto a partition you have mounted
machine.conf    which board it is, which files it loads, and what its console is
kernel.bin      the system: everything up to the file systems
disk-rv64.bin   the disk it starts with, 32 MB (disk-a64.bin on an AArch64 board)
config.txt      on the Compute Module 5: what its bootloader reads
README.md       this
```

**The whole system runs from that disk image, in RAM.** The loader puts it
there beside the kernel, flash.device serves it as `DH0:`, and what is
written to it is gone when the machine stops. So these two files are a
system to start and use without touching the machine's own storage. A card
or an SSD is what keeps anything, and one is partitioned, formatted and
filled from the running system - the last section here says how.

## A VisionFive 2

Its U-Boot loads the kernel and starts it with `booti`, with the disk
image as the ramdisk and U-Boot's own device tree; the kernel's image
carries the header `booti` reads, and its first address is 0x80200000.
The files go on a FAT partition of the card - `./write.sh` copies them
there - and the card keeps its PC partition table, so that one FAT volume
is both U-Boot's and the system's. What the board's U-Boot is told to load
is its own environment's business; the project's README has the board's
section.

The console is the debug UART on pins 8 and 10 of the 40-pin header,
115200 8N1, through a 3.3 V serial adapter.

## A Compute Module 5

Its bootloader reads `config.txt` from the first FAT partition of the
eMMC - or of a card, on a module without eMMC - and from the same
partition the kernel, the disk image and Raspberry Pi's device tree for
the module, `bcm2712-rpi-cm5-cm5io.dtb`. That device tree is Raspberry
Pi's own file and is not in this package: put it on the partition beside
the rest. `config.txt` here names what goes where and nothing else is
needed.

With the IO board's nRPIBOOT jumper fitted - the module's EMMC-DISABLE
line, the chip's GPIO 20, pulled low - Raspberry Pi's `rpiboot` starts
the same files over USB from a directory holding usbboot's
`bootfiles.bin`, a `config.txt` saying `boot_ramdisk=1` and the
partition's image as `boot.img`; its `mass-storage-gadget64` makes the
eMMC a USB disk to write that partition on.

The console is the RP1's UART0 on pins 8 and 10 of the 40-pin header,
115200 8N1, on which the firmware's second stage logs too
(`uart_2ndstage=1` in `config.txt`).

Where the firmware looks for that partition is `BOOT_ORDER` in the
bootloader's own settings - in the EEPROM, not in `config.txt`. It is a
hex number read from its lowest digit up, each digit one place to try: 1
the card or eMMC, 4 a USB mass-storage device, 6 an NVMe SSD, 2 the
network, 7 HTTP, 3 USB device mode, f start the sequence again, e stop.
So `0xf16` tries the SSD, then the eMMC, then starts over - the order a
system on an SSD wants, with the eMMC left as the way back in. Raspberry
Pi documents `0xf41` as the value used when the setting is empty, and
documents none for a module as it comes, so a module's own order is read
off it rather than assumed.

The settings are read and written with Raspberry Pi's
`rpi-eeprom-config` from a system on the module that has their tools, or
from a PC with the module in rpiboot mode: `boot.conf` in usbboot's
`recovery5` directory holds them, `./update-pieeprom.sh` builds the
image and `../rpiboot -d .` writes it. `BOOT_UART=1` among them makes
the bootloader print each place it tries, on the firmware's own debug
UART (UART10) - not on the console above, which carries the second stage
and the system.

They can also be read from the chip itself, which wants nothing on the
module: `rpiboot -d usbboot/mass-storage-gadget64` starts a small Linux
on it with the eMMC and the SSD as USB disks and a console of its own
(`root`, no password), and the EEPROM is on its SPI:

```
flashrom -p linux_spi:dev=/dev/spidev10.0 -r ee.bin
strings ee.bin | grep -A3 '^\[all\]'
```

The settings are plain text in the image, so that prints them as they
are - a read of the chip rather than of a file that is meant to be on
it.

## The first start

The console says what the kernel finds and ends at `s3>`, the ROM's own
debug shell - `help` lists what it takes. **Type `newshell`** there for a
shell of the system's own:

```
List SYS:                 what is on the disk
Info                      the volumes, their sizes and what is free
Avail                     memory, and the largest block there is
ShowConfig                what this board has; ShowConfig DEVICES for its devices
Version                   the system's release; Version dos.library for one module
Dir C: ALL                every command there is
```

With a monitor on the board's HDMI the desktop comes up on it, with its
own shell in `SYS:System/Shell` and the programs in `SYS:Programs`. A USB
keyboard and mouse are found as they are plugged in.

## Keeping anything

The disk in RAM is gone at power off. A microSD card or an NVMe SSD keeps
a system, and both are driven: `SYS:System/HDToolBox` partitions a drive
in a window, `C:RDB` and `C:Format` do it from the shell, and the disks
guide in the project's documentation has the whole recipe. A partition on
such a medium that is bootable above the RAM disk's priority is what the
machine starts from next time, and the RAM disk is still there when the
medium is not.

## Where this comes from

PowerOS is a kernel and a system written in Zig for ESP32-S3 and ESP32-P4
boards, for 64-bit RISC-V machines under SBI firmware and for AArch64
machines under PSCI. The source, the boards and the guides are at
<https://github.com/cycl0ne/poweros_esp32>, and the same system runs in
QEMU from an archive of its own.
