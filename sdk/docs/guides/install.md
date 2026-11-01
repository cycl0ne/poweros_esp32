# Installing a system

A 64-bit machine starts with its disk image in RAM: what is written to it
is gone at the next power off. A microSD card or an NVMe SSD keeps it,
and both are driven - sdcard.device, nvme.device with pci.library, and
posfs-handler for the volumes - so a medium is where a system lives,
boots from and is brought up to date on. Installing is making that
medium: a partition table on it, a volume for the system and one for what
is done with it, every file copied in, and the partition the machine's
firmware reads filled with the kernel so that the machine starts from it.

`C:Install` does all of that in one command, on a machine with nothing
but a console, from the running system itself or from a release package.
It is on the 64-bit machines' disks - the VisionFive 2, the Compute
Module 5 and the two `virt` machines; the ESP32 boards' system lives in
their flash and is written from the host (`./zig build flash-disk`).

This guide is what an install leaves on the disk, the command and each of
its keywords, the two sources it copies from, the release package's form,
what it writes down about itself, and what the machine then starts from.

## What it leaves on the disk

| Where | What |
|---|---|
| block 0 | a protective MBR, so other systems see the disk as taken |
| block 1 | the GPT |
| `BOOT` | FAT32, 256 MB: the partition the firmware reads |
| `BOOTB` | the second one, where a firmware starts from either |
| container | the PowerOS container over the rest, with the table in its first block |
| `DH0` | posfs, `System`, bootable, boot priority 5 |
| `DH1` | posfs, `Work`, the rest of the container |

The boot partitions come first because a firmware looks for its files in
the first partitions of a disk, and the container takes what they leave.
How many there are is the board's own fact (`SYSTAG_BootSlots`): one
where the firmware reads one partition, two where it can be sent to the
other for a single start. Both hold the same files, so either starts the
machine.

The two partitions in the container are posfs, the journaling file system
([its guide](posfs.md)): `DH0` is the system and `DH1` is everything
else, which is why a new system can be installed over the first without
touching the second. `SIZE` says how much of the container the system
gets; without it 32 GB, or half the container where half of it is less.
The smallest medium an install fits on is the board's boot partitions plus
128 MB of container - 640 MB where there are two - and a disk below that
is refused before anything is written to it.

## The command

```
Install DEVICE,UNIT/N,SYSTEM/K,WORK/K,BOOT/K,SIZE/K,FROM/K,NAME/K,
        FORCE/S,QUIET/S,RESTART/S
```

```
Install                              the units it can go onto
Install nvme.device                  unit 0 of it, after one question
Install nvme.device 1 FORCE          unit 1, asking nothing
Install nvme.device SIZE 8G          8 GB for the system, the rest for work
Install nvme.device FROM WORK:package      from a release package
Install sdcard.device NAME Tools RESTART   and start from it at once
```

- **DEVICE** and **UNIT** are the block device and its unit, as exec has
  them (`nvme.device`, `sdcard.device`); unit 0 without one.
- **SYSTEM**, **WORK** and **BOOT** name the drives the partitions get -
  `DH0`, `DH1` and `BOOT` without them. Where the board has two boot
  partitions the second is that name with `B` after it.
- **NAME** is the system volume's name, `System` without it; the work
  volume is `Work`.
- **SIZE** is the system partition's size, in bytes or with `K`, `M`,
  `G` or `T` after it.
- **FROM** is a release package to install from; without it the running
  system is the source.
- **FORCE** answers the question before it is asked, and installs a
  package built for another board of the chip.
- **QUIET** leaves out the lines that say what is happening; what went
  wrong is still said.
- **RESTART** starts the machine again at the end.

With a device it says what it is about to do - the disk, its size, the
partitions and their sizes, where the files come from - and waits:

```
Press RETURN to install, or CTRL-C to stop:
```

A blank line is enough, so a script answers it with one; `FORCE` skips
it. Everything that can be refused is refused before the first block is
written: a device that has no such unit, a unit with no medium, a medium
too small for the board's layout, a package whose list does not add up or
was built for another chip, and the disk the running system is on. The
return code is 0 for a system installed, 5 for one stopped at the
question or with Ctrl-C, and 20 for one that could not be made, with the
reason said.

It needs rdb.library revision 7 or later, which is where a GPT's FAT
partition can be made and mounted, and asks expansion.library what the
board's layout is.

## The units it can go onto

`Install` with no device at all lists them:

```
The units an install can go onto:

  Device             Unit      Size  What it holds
  flash.device          0    160 MB  a table over the whole disk, 1 partition - the running system is on it
  nvme.device           0    256 GB  a GPT, a PowerOS container in it, 2 partitions
  (14 other units have no medium in them; a card or a stick put in now shows up here)
```

Every unit of every device that speaks the block language is asked
(`ObtainDeviceUnits`), so a card put in while the machine runs shows up
without anything being mounted or loaded to find out. A unit with no
medium is counted rather than listed. The last column says what is on the
medium - a table, a GPT, a container, how many partitions - and which
unit the running system is on, which is the one not to install over:
`SYS:`'s handler is found through dos and the device node of that same
handler task says which unit it opened.

## Where the files come from

**The running system.** Without `FROM`, `SYS:` is the source for the
volume's files and `SYS:Storage/Boot` for what the firmware reads. A
machine therefore installs a medium with no network and nothing else at
hand - the one it is running from, a card for another machine, a system
onto an SSD from the image in RAM. Two files are not copied, since they
describe the machine doing the copying and not the files: the list in
`SYS:System/manifest` and `ENVARC:Sys/install.prefs`. Each file's
protection bits, date and comment go with it, and the drawers are made in
the order the names sort in.

**A release package.** `FROM` names one: a directory holding `manifest`,
`system/` and `boot/`, on a disk, a stick or a share. Every file is held
against the length and the CRC-32 its list gives as it is copied, so a
package that arrived damaged stops the install on the file that is wrong,
and the list the install leaves is the package's own text, byte for byte.
A package whose kernel was built for the other board of the chip is
refused - that kernel would start with no console - and `FORCE` installs
it anyway.

## A release package

`./zig build package -Dboard=<board>` gathers one into
`release/package-<board>/`:

```
manifest              every drawer and file below, with sizes and sums
system/...            the system volume's files
boot/...              what that board's firmware reads
```

Each path begins with the half it is in, so one list covers both halves
and one walk compares them. What is in `boot/` is the board's business: a
kernel, and where the board wants them a device tree, a `config.txt` or
the disk image. `-Dboot=[<name>=]<file>` adds a file this tree does not
hold - the Compute Module 5's device tree is Raspberry Pi's own - and it
goes into the list with the rest.

The list is a settings line and then a line per entry:

```
FORMAT=1 CHIP=a64psci BOARD=rpi_cm5 DRAWERS=48 FILES=511 BYTES=11793248
drawer system/WBStartup
7f3a21b0 5120 system/C/List
```

`CHIP` is why the header is not optional: every machine's package holds
the same paths, so without it an update would write another machine's
programs over a working system. `BOARD` says which board's kernel is in
`boot/`. `DRAWERS`, `FILES` and `BYTES` are what must follow, so a body
that was cut short - a fetch that ended early, a disk that filled - is
caught instead of read as "the build dropped these files". The entries
are sorted by path with letters as if upper case, the order the file
systems compare names in, and a reader refuses a line that is not after
the one before it: two lists are compared by walking both at once with
nothing held in memory but the two lines in hand.

`./zig build serve -Dboard=<board>` hands the same package out over HTTP
(`-Dserve-port=`, 8080 by default): GET and HEAD only, no directory
listing, and only the paths a list may name. In QEMU's user network the
host is 10.0.2.2, so a machine there reads `http://10.0.2.2:8080/`.
`./zig build archive -Dboard=<board>` packs instead what somebody needs
to run the machine without building it, and `./zig build release` does
every board's archive and package at once; both write into `release/`.

## What it writes down about itself

On the new system volume, `SYS:System/manifest` - the list of what it was
given, which an update compares against - and `ENVARC:Sys/install.prefs`,
one line:

```
DEVICE=nvme.device UNIT=0 SYSTEM=DH0 WORK=DH1 BOOT=BOOT BOOTB=BOOTB
BOARD=rpi_cm5 SOURCE=SYS: INSTALLED="01.11.2026 21:30:04"
```

`DEVICE` and `UNIT` are the medium, `SYSTEM` and `WORK` the drives in the
container, `BOOT` and `BOOTB` the names in the GPT of the partitions the
firmware reads, `BOARD` the board the files were built for, `SOURCE`
where they came from and `INSTALLED` when, in the machine's own time.

`BOOT` is a name to find that partition by through rdb.library, not one
to open: a GPT's partitions are mounted at the next start under the
**unit's** own name, whatever the GPT calls them - the first `NV0:`, the
second `NV0P2:`. The file is `ENVARC:`'s alone, since it says what was
done to this machine and not what the machine is to do.

The running system also keeps its own copy of what the firmware reads, in
`SYS:Storage/Boot` with `SYS:Storage/manifest` over it saying which chip
and board those files are for. That is what makes an install from the
running system possible at all, and what a boot partition is written
again from.

## What starts the machine then

Of the bootable partitions of every disk, dos starts from the one with
the highest boot priority. An install gives the system partition 5 and a
disk image's `DH0` has none, so the medium wins; a loader can leave the
image out altogether and the machine then starts from the medium alone.
`RESTART` does that at once: every drive of a block device is held still
first, so that what it holds is written out, and the machine is started
again.

The kernel is the other half, and it comes from a partition the firmware
reads itself, not from posfs:

| Board | What its firmware reads | Where the kernel comes from |
|---|---|---|
| VisionFive 2 | U-Boot, from the card's FAT partition | the machine itself: sdcard.device and FAT's handler are in its ROM |
| Compute Module 5 | the bootloader in its EEPROM, from a FAT partition in the order `BOOT_ORDER` gives ([bundle notes](../../../tools/bootpackage/bundle.md)) | the eMMC or `rpiboot`, from another machine; no driver here reaches the eMMC |
| QEMU's `virt` machines | the kernel is handed to QEMU | the host's command line |

Where the firmware can be sent to the other of a pair of boot partitions
for one start, both are made and both are filled, so a machine that does
not come up on the one can be started from the other.

## By hand

The same thing line by line is `RDB INIT GPT`, `RDB ADD`, `Format`,
`Copy SYS: TO ... ALL CLONE` and `RDB CHANGE ... BOOTABLE BOOTPRI`, which
the [disks guide](rdb.md#from-the-shell) has with what each one is for,
and `SYS:System/HDToolBox` does the table in a window with the partitions
as a bar that is dragged. `C:Install` is those lines with the checks and
the list added; the library under both is rdb.library.

What reads a package to bring an installed system up to date, rather than
making a new one, is being written.

## See also

- [Disks and partitions](rdb.md) - the table, the GPT and the container,
  rdb.library and `C:RDB`.
- [posfs](posfs.md) - the file system the volumes hold.
- `sdk/libs/install/` - the package and its list, as the host's tools and
  the machine both read them.
- `tools/mkpackage/README.md` - the host side of a package.
