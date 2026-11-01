# mkpackage

Gathers a release package - the volume's files, the kernel and the files
the board's firmware loads - into one directory and writes the manifest
over it, so a machine installs from that directory and is later brought up
to date against it.

```
mkpackage --into=<dir> --chip=<chip> [--board=<name>] [--system=<dir>] [<path in the package>=<file> ...]
mkpackage --check <dir>
```

A package has two halves, and every path in it begins with one:

```
package-visionfive2/
  manifest              every drawer and file below, with each file's length and CRC-32
  system/...            the volume, as it is under SYS: on an installed disk
  boot/kernel.bin       the kernel the firmware loads
  boot/disk-rv64.bin    the disk image it loads beside it, which is also the rescue system
  boot/config.txt       what else that firmware reads, under the name it looks for
```

`--system=<dir>` copies a whole tree in under `system/`, drawers with
nothing in them included - an empty `WBStartup` or `Trashcan` is part of an
installed system. An argument with `=` is one file:
`boot/kernel.bin=zig-out/bin/kernel.bin`.

Then the finished directory is walked and `<dir>/manifest` written from
what is in it (the format is `sdk/libs/install/manifest.zig`, read and
written there for this tool and for the commands on the machine). So the
manifest is of the package as it is rather than as a build meant it to be,
and since it is written last it is also the mark of a package that was
gathered to the end.

**CHIP and BOARD.** Every machine's package holds the same paths, so the
manifest says which chip the files are built for; and two boards share a
chip while their kernels differ in what the board has and where it is, so
a package with a kernel says which board as well. A command on the machine
compares both against the machine it is installing onto before it writes
anything.

`--check <dir>` is the other direction: the manifest is read and held
against the directory - every line's length and sum as the file has them,
and every file and drawer in the directory named by a line. It prints a
line for each difference and ends with how many there were. `./zig build
package` runs it over the package it has just gathered, so a package that
is installed from is one that was checked; by hand it says whether a
package copied onto a stick or fetched over the network arrived whole.

The build makes a package for the board it is building
(`./zig build package -Dboard=visionfive2`, into
`release/package-visionfive2/`), and `-Dboot=[<name>=]<file>` adds a file
to `boot/` that this tree does not hold - the Compute Module 5's device
tree is Raspberry Pi's. `./zig build release` makes every board's at once.
The machines whose disk is in RAM are what a package is for; an ESP32
board's disk is the flash its kernel is written with, which `flash-disk`
writes and `esp-package` packs.

One thing a package made by `release` does not carry: the `SYS:Storage/Boot`
of the image inside it is filled for the board the build was for
(`-Dboard=`) and empty for the others, since one disk image serves both
boards of a chip. It matters only to a machine installing itself from an
image somebody handed it with no package beside it; installing from the
package has the same files in `boot/` either way. Build the release with
`-Dboard=` set to the machine you care about, or once for each.
