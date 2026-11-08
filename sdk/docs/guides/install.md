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
Module 5, the x86-64 machine and the two `virt` machines; the ESP32
boards' system lives in their flash and is written from the host
(`./zig build flash-disk`).

This guide is the medium a machine is first reached with, what an install
leaves on the disk, the command and each of its keywords, the two sources
it copies from, the release package's form, what it writes down about
itself, what the machine then starts from, how a system that is installed
already is brought up to date from a later package (`C:Update`, or
`SYS:System/Update` in a window), how its
kernel is replaced with a way back from one that does not come up, and
how a machine looks for a newer system by itself.

## The medium a machine is first reached with

A machine with nothing on its disk has to be started from something else,
and on a machine whose firmware is UEFI that something is a USB stick.
`./zig build stick -Dboard=<board>` makes its image:

```sh
./zig build stick -Dboard=qemu_q35      # release/stick-qemu_q35.img
sudo dd if=release/stick-qemu_q35.img of=/dev/sdX bs=4M conv=fsync status=progress
```

The step prints what it made - the medium's size, the partition, the
volume and what is on it - and the `dd` line above with the path the image
was put at. Which device `/dev/sdX` is, `lsblk` says: the removable one of
the size of the stick. Everything on it is written over, so look at what
is there first, and unmount the volume the desktop mounted before writing
(`udisksctl unmount -b /dev/sdX1`).

The image holds a protective MBR, a GPT whose one partition is an EFI
System partition over the medium from the first mebibyte, and a FAT32
volume on it with three files: `EFI/BOOT/BOOTX64.EFI`, which is the one
name such a firmware reads off a boot partition; `kernel.bin`, which that
loader reads from beside itself; and `disk-x64.bin`, the disk image the
machine runs on. So the stick carries a whole machine - it comes up to a
console and a desktop with `SYS:` in RAM, and nothing has to be installed
to try one. Its disk image boots above any system partition `C:Install`
makes, so a machine started from the stick runs the stick's system even
where a disk of its own holds one: that is how a machine whose own system
no longer starts is installed afresh.

From there the machine installs itself onto a disk of its own with no
network and no second machine, because the running system is a source
`C:Install` can copy from:

```
3.System:> C:Install nvme.device FORCE
Installing onto nvme.device unit 0, 2.0G:
...
576 files, 18.9M: the system on DH0.:, the boot files on BOOT:.
The disk starts the machine at its next cold start.
```

Pull the stick out, start the machine again, and its firmware finds the
EFI System partition the install wrote and starts the kernel from there.
The loader on it is beside no disk image, so the machine comes up with
nothing in RAM to boot from and dos takes the system partition instead -
which is why nothing has to be said to make the disk the system.

The medium is 320 MiB unless `-Dstick-size=` says otherwise - the least a
FAT32 volume of 4 KiB clusters can be, with room over - and the image
holds only the blocks that were written, so it takes some 35 MiB on the
host until it is written out. Two builds of the same files give the same
image, byte for byte: the identifiers and the one date everything on it
carries are drawn from what the medium is, not from the clock.

The volume is laid down by the file system's own format, the same code
that mounts it on the machine
(`src/disk/devs/handlers/fat/fat32/format.zig`); the tool adds the files
itself, with names that fit a directory entry as it stands, and refuses
one that does not rather than shortening it.

The other boards are reached their own ways: the ESP32 boards over USB
from the host (`./zig build flash-all`), the VisionFive 2 and the Compute
Module 5 from a card or over the network with a release package
([below](#a-release-package)).

## What it leaves on the disk

| Where | What |
|---|---|
| block 0 | a protective MBR, so other systems see the disk as taken |
| block 1 | the GPT |
| `BOOT` | FAT32, 256 MB: the partition the firmware reads, not mounted at a later start |
| `BOOTB` | the second one, where a firmware starts from either |
| container | the PowerOS container over the rest, with the table in its first block |
| `DH0` | posfs, `System`, bootable, boot priority 5 |
| `DH1` | posfs, `Work`, the rest of the container |

The boot partitions come first because a firmware looks for its files in
the first partitions of a disk, and the container takes what they leave.
They are marked not to be mounted when the medium comes in (the GPT's
`ATTR_NO_AUTOMOUNT`, which `C:RDB` lists as `nomount` and sets with
`ADDGPT ... NOMOUNT`): they are the firmware's, nothing here works in
them, and a drive for each at every start is one more name in `Info` than
there is a use for. The install mounts them itself to write them, and
rdb.library mounts one when it is asked to, so an update finds them by
the names `install.prefs` keeps; `RDB <device> MOUNTGPT BOOT` gives one a
drive on the spot, which is how to look inside or put a file there by
hand.
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
kernel, and where the board wants them a device tree, a `config.txt`, the
disk image or - on a machine whose firmware is UEFI -
`EFI/BOOT/BOOTX64.EFI`, the loader that firmware starts. The loader has
to be there as surely as the kernel: a boot partition written without it
is one the firmware finds nothing in. `-Dboot=[<name>=]<file>` adds a file this tree does not
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
| A machine whose firmware is UEFI | the loader `EFI/BOOT/BOOTX64.EFI` in an EFI System partition, and `kernel.bin` beside it | the machine itself: both are on its own disk, under `SYS:Storage/Boot`, and the install writes them into the partition it makes |

Where the firmware can be sent to the other of a pair of boot partitions
for one start, both are made and both are filled, so a machine that does
not come up on the one can be started from the other.

**A file the firmware wants that this tree does not hold** - a board's
device tree is one - reaches `SYS:Storage/Boot` only when the build was
given `-Dboot=[<name>=]<file>`, and a package's `boot/` only then as
well. An install copies what is there and nothing it has not got, so a
boot partition written from an image built without it is short of that
file, and the machine goes on starting from wherever it started before
until the file is put there.

## By hand

The same thing line by line is `RDB INIT GPT`, `RDB ADD`, `Format`,
`Copy SYS: TO ... ALL CLONE` and `RDB CHANGE ... BOOTABLE BOOTPRI`, which
the [disks guide](rdb.md#from-the-shell) has with what each one is for,
and `SYS:System/HDToolBox` does the table in a window with the partitions
as a bar that is dragged. `C:Install` is those lines with the checks and
the list added; the library under both is rdb.library.

## Bringing it up to date

`C:Update` reads a package over a system that is installed already and
takes from it what differs:

```
Update FROM/K,CHECK/S,BOOT/S,FORCE/S,QUIET/S,CONFIRM/S,RESTART/S,AUTO/S
```

```
Update                              from where the machine was installed
Update CHECK                        what would happen, and nothing else
Update FROM WORK:package            from a package on a volume
Update FROM http://10.0.2.2:8080/   from one a server hands out
Update BOOT                         the files the firmware reads as well
Update BOOT RESTART                 and the machine started on them
Update CONFIRM                      the kernel that came up, kept
Update AUTO                         what the machine was told to do
```

- **FROM** is the package. An argument with `://` in it is an address,
  read through `LIBS:http.library`; anything else is a path, so a stick,
  a second disk or a mounted share wants no network and no server.
  Without it the source is the one `update.prefs` names, and failing
  that the one the install wrote down in `install.prefs`.
- **CHECK** says what would happen and writes nothing.
- **BOOT** writes the package's `boot` half too, into the partition the
  firmware reads - [the kernel](#the-kernel-and-the-way-back) below.
- **FORCE** lets the package win over a file that was changed here.
- **QUIET** leaves out the lines, but not what went wrong.
- **CONFIRM** keeps the kernel that was tried, which is the started
  system's own step.
- **RESTART** starts the machine again at the end, through `C:Reboot`.
- **AUTO** does what `update.prefs` says - [by itself](#by-itself-at-every-start)
  below - and nothing at all where there is no such file.

The return code is 0 for a run that did something or found nothing to
do, 5 from `CHECK` where there is something to do and from a run stopped
with Ctrl-C between two files, and 20 for one that could not finish, with
the reason said - Ctrl-C in the middle of a file read from an address is
one, said as the break it was.

Three things are compared, not two - the list the machine was given
(`SYS:System/manifest`), the list in the package, and the file itself:

| installed | file | package | what happens |
|---|---|---|---|
| = | there | = | nothing; the file is not read |
| = | gone | = | written again |
| = | = | differs | fetched and written |
| = | differs | any | changed here: kept, and said |
| not in it | - | in it | new: fetched |
| in it | - | not in it | the build dropped it: deleted |
| not in it | - | not in it | the machine's own: never touched |

So an edited `ENVARC:Sys/style.prefs` or a `DEVS:NetInterfaces/WLAN0`
with a passphrase in it lives through every update with no list of
exceptions, and `FORCE` is how the package wins instead. Where the two
lists agree about a path the file is looked for and not read, so an
update costs one name a path for everything the build left as it was -
over a 50 MB package that differs in two files, 4.7 KB is fetched - and
a file that went missing comes back.

A line is said for every path something happens to, the first word
saying what: `new` for one the build has begun to ship, `newer` for one
it changed, `again` for one that was not there, `kept` for one changed on
this machine, `gone` for one the build dropped, `drawer` for a drawer
made, `list` for the package's list written as the machine's own, and -
with `BOOT` - `slot` for the partition the firmware reads, `boot` for a
file written into it, `same` for one already right and `tried` for
`autoboot.txt`:

```
  new     SYS:c/Mixer
  gone    SYS:programs/Docs/Battery.md
  kept    SYS:s/startup-sequence
  list    SYS:System/manifest
Done: 1 written (39), 1 deleted, 1 kept as they are, 0 drawers made.
What is kept was changed on this machine; FORCE takes the package's own.
```

Every file is fetched to a name of its own on the volume, held against
the length and the CRC-32 the list gives, and renamed into place, so a
run that is cut leaves either the old file or the new one and never half
of either. What the build dropped goes last and in reverse, a drawer
after what was in it. The package's list is written as the machine's own
at the very end and byte for byte, so a run that never got there looks
like one that never happened, while every file it did write is already
what the package says and the next run passes over it.

A file that was kept is written into that list as the package's, so it is
named once and then left to the machine; a later package that changes
that path again names it again.

Without `BOOT` the files the firmware reads are counted and left alone,
and the line that says how many of them the package holds says so.

## In a window

`SYS:System/Update` is the same run in a window, started from the
desktop or as `SYS:System/Update FROM <package>`. It checks as it opens -
the package FROM gives, else the one `update.prefs` names, else the one
the install wrote down - and puts the package it read in the field at
the top, a row in the list for every path something would happen to,
with how much is written for it, and what the check comes to in the two
lines above the list.

- **Check** looks again, at what the field holds: another package is
  typed in and checked, Return in the field doing the same.
- **With the kernel** is `BOOT`, and starts as BOOT in `update.prefs`
  has it; **Replace changed files** is `FORCE`. Changing either checks
  again.
- **Update** writes what the check found, the gauge filling by the bytes
  written. It is there only once a check has found something to do.
- **Stop** ends the run where it is: what was written stays, the
  machine's list stays as it was, and the next check finds the rest.
- **Restart**, once an update has written something, is `RESTART`: the
  machine started again through `C:Reboot`, on the partition written for
  a try where there is one.
- **Keep this system** is `CONFIRM`, there while the firmware is told to
  try a partition - for the system that came up on it.

The run goes on a process of its own, so the window answers while a
package is read over the network; closing the window stops the run
first.

## The kernel and the way back

`Update BOOT` writes the package's `boot` half into the partition the
firmware reads, after the system volume's files: a system whose files are
all there is of no use if the machine still loads the kernel it was
installed with, and a kernel written before them would be the one that
came up beside files it has never seen.

That partition is not mounted while the machine runs, so it is found the
way the install left it to be found: `install.prefs` names the device,
the unit and the partition's name in the GPT, and rdb.library walks the
table and mounts the entry of that name. Nothing in it is deleted - it is
the firmware's, and what else is in there is somebody's business - and
each file is held against the length and the CRC-32 the package's list
gives, as on the system volume. One that is already what the list says is
left alone, so writing the partition again costs nothing. The partition
comes off the list again when the writing is done
(`rdb.library`'s `UnmountPartition`, 1.8), so it is no more on the screen
afterwards than it was before; one that was already mounted by hand stays
as it was.

**Where the firmware starts from either of a pair** (`SYSTAG_BootSlots`
is 2) the one not in use is written and `autoboot.txt` in the first of
them is pointed at it for a single start:

```
[all]
tryboot_a_b=1
boot_partition=1
[tryboot]
boot_partition=2
```

`[all] boot_partition` is where the firmware starts from, `[tryboot]` the
one it starts from instead when it was reset with the flag for that set -
which is `C:Reboot TRYBOOT`, or `RESTART` on the update that wrote the
partition. The flag goes away by itself: a kernel that does not come up
costs one start, and the machine is back on the partition that worked. A
system that did come up keeps the new one with `Update CONFIRM`, which
writes the two numbers the other way round.

So the whole of it, on a machine with a pair:

```
Update BOOT RESTART        the files, the kernel, and a start on it
Update CONFIRM             once it came up: keep it
```

**Where it reads one partition** the file being replaced is kept beside
the new one as `<name>.old`, since there is nothing else to fall back on.
What loads that file then is the firmware's own prompt, over the console
such a machine has attached: on the VisionFive 2, U-Boot's
`load mmc 1:1 0x40200000 kernel.bin.old` and `booti`.

**Before the first file is written** the system volume is given a
snapshot, where it is a file system that keeps them (posfs):

```
  back to SYS: before this, as the snapshot before-update
```

There is one of it, made again each run, since a volume is only ever put
back to its newest snapshot. A system that comes up and is wrong is put
back with `C:PosFS SYS: ROLLBACK before-update` - from a system that is
not the one being rolled back, since a volume is not rolled back while it
is in use, which means a card or a kernel that loads a disk image beside
the medium.

## By itself, at every start

`ENVARC:Sys/update.prefs` is what a machine was told about newer systems,
and without that file nothing looks anywhere - a machine says nothing to
a server it was never told about. One line:

```
SOURCE="http://poweros.local/rpi_cm5/" ATSTART=YES APPLY=NO BOOT=NO
```

- **SOURCE** is the package to look at - a path or an address - which any
  run of `C:Update` uses when it is told no other; empty, the one the
  install wrote down is used.
- **ATSTART** is whether to look once at every start.
- **APPLY** is whether what was found is written without being asked for.
  `NO` says what there is and waits, which is what a machine does unless
  it was told otherwise: a build changes daily, and an unproven one
  should not land on a machine unasked.
- **BOOT** is whether the files the firmware reads are written with it,
  where what was found is applied.

`S:Network-Startup` runs `C:Update AUTO` once the network is up, in the
shell of its own that the start gives that script. Its return code is 5
where something was found and not written, and 0 where there was nothing
or where it was written. AUTO does what the
file says and nothing where there is no file: it looks, puts what it
found in the system log (`C:Log`), and, where there is a desktop, offers
it in a requester - **Update now** writes it there and then, **Later**
leaves it. With `APPLY=YES` it writes what it finds without asking. A
machine on a serial console with no screen is left with the line in the
log, among the start's own words.

The page for all of it is **Update** in `SYS:Programs/Prefs`: where to
look, and the three switches. Save keeps the file in `ENVARC:Sys` and
puts it in `ENV:Sys`, so the next start reads it; the page itself looks
nowhere.

**The restart itself** is `C:Reboot`:

```
Reboot                     after one question
Reboot FORCE               asking nothing
Reboot TRYBOOT             from the other boot partition, this once
```

Every drive a device feeds is held still first, so that what its file
system is holding is written out - a reset writes nothing out - and one
that will not stop is named, with the restart going ahead all the same.
`TRYBOOT` sets the firmware's flag for a single start from the other
partition and says so and does nothing on a board whose firmware has no
such flag.

## From a program

The work under `C:Update` is `LIBS:update.library`'s, and a program
calls it the same way (`sdk.update`, the calls in
[autodocs](../autodocs/update.md)): a run is made for one package, done
as often as wanted - a check, then the writing - and let go.

```zig
const upd: *UpdateBase = @ptrCast(sys.OpenLibrary(update.UPDATENAME, 1) orelse return);
defer sys.CloseLibrary(upd.lib());
const run = upd.CreateUpdate(&[_]utility.TagItem{
    .{ .tag = update.UPD_Hook, .data = @intFromPtr(&hook) },
    .{},
}) orelse return; // why is said, through the hook
defer upd.DeleteUpdate(run);
if (upd.DoUpdate(run, &[_]utility.TagItem{ .{ .tag = update.UPD_Check, .data = 1 }, .{} }) == dos.RETURN_WARN) {
    _ = upd.DoUpdate(run, null);
}
var info: update.UpdateInfo = .{};
upd.GetUpdateInfo(run, &info); // what it came to, `tried` among it
```

- **CreateUpdate** takes the package (`UPD_Source`; left out, the one
  `update.prefs` names, else the one the install wrote down) and opens
  what it is read with. **DoUpdate** walks it - `UPD_Check`, `UPD_Boot`,
  `UPD_Force` are CHECK, BOOT and FORCE - and answers as the command does.
  **ConfirmUpdate** is CONFIRM.
- **What a run says** goes to the program's output, or with `UPD_Hook`
  to a hook: an `UpdateMessage` for each line, for each path with what
  happens to it and the bytes written for it, and for each file once it
  is in place - enough for a list and a gauge.
- **A run belongs to the task that made it**, which it checks for Ctrl-C
  between files, and whose wait on the network Ctrl-C breaks: a program
  that runs it on a process of its own stops it with
  `Signal(process, SIGBREAKF_CTRL_C)` - `SYS:System/Update` does.
- Restarting is the program's: `C:Reboot TRYBOOT` where `info.tried`
  says a partition was written to be tried.

## See also

- [Disks and partitions](rdb.md) - the table, the GPT and the container,
  rdb.library and `C:RDB`.
- [posfs](posfs.md) - the file system the volumes hold, its snapshots
  and the rollback an update's snapshot is for.
- `sdk/libs/install/` - the package and its list, as the host's tools and
  the machine both read them.
- `tools/mkpackage/README.md` - the host side of a package.
