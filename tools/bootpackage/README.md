# The archive of a 64-bit board

`./zig build archive -Dboard=visionfive2 -Ddisk-tree=false` packs what a
board's firmware loads, for somebody who wants to run the system on one
without building it.

```
release/poweros-visionfive2.tar.gz    9.1 MB, the download
release/poweros-visionfive2/          the same files, to try before handing out
  write.sh        ./write.sh <the mounted boot partition>
  machine.conf    the board, the files it loads, and what its console is
  kernel.bin      the system: everything up to the file systems
  disk-rv64.bin   the disk it runs from, 32 MB (disk-a64.bin on an AArch64 board)
  config.txt      on the Compute Module 5: what its bootloader reads
  README.md       what it is and how it is used (`bundle.md` here)
```

This is what `archive` packs for the VisionFive 2 and the Compute Module
5. The other boards get an archive of their own kind: QEMU's machines one
that starts them ([qemupackage](../qemupackage/README.md)), the ESP32
boards one that writes their flash ([espackage](../espackage/README.md)).

**Two files are a whole system.** The loader puts the disk image in RAM
beside the kernel, flash.device serves it as `DH0:`, and the system runs
from there - so a board starts and is used without anything on its own
storage. A card or an SSD is partitioned, formatted and filled from the
running system (`SYS:System/HDToolBox`, or `C:RDB` and `C:Format` in a
shell; the disks guide has the recipe, and `C:Install` will do it in one
command once part 2 of the install list is built). That also means the
image is the rescue system when an installed disk will not come up.

The image's own `SYS:Storage/Boot` - where a running system keeps a copy
of these files, to write a boot partition from - is filled when the
archive was built with this board's `-Dboard=`, and empty in a release
built for another machine, since one disk image serves both boards of a
chip. The files are in the archive either way, which is what the board
needs to start; `./zig build archive -Dboard=visionfive2` is how to have
both.

**`write.sh` only copies.** The board's boot partition - a FAT partition
on its card, or on the module's own storage - is mounted by whoever runs
the script, and named on the command line; the script checks that it is a
directory it may write to, that it is not the host's own, and that the
room is there (the files need some 34 MB), copies each file under its own
name, syncs, and says what the board's console is. Which socket a board
starts from, and what its loader is told, is the board's business, and
the script does not guess at it:

- **The VisionFive 2's** U-Boot loads the kernel and starts it with
  `booti`, with the disk image as the ramdisk and U-Boot's own device
  tree. The kernel's image carries the header `booti` reads and its first
  address is 0x80200000. What that board's U-Boot is told to load is its
  own environment's business.
- **The Compute Module 5's** bootloader reads `config.txt` from the first
  FAT partition of the eMMC - or of a card, on a module without eMMC -
  and from there the kernel, the disk image and Raspberry Pi's device tree
  for the module (`bcm2712-rpi-cm5-cm5io.dtb`), which is their file and
  not in the package. `-Dboot=<path to it>` puts a copy in, and then
  `write.sh` copies that too.

**`-Ddisk-tree=false`, and why the step insists.** The `disk/` tree in the
repository's root is the builder's own files, and among them are the
network settings - which hold a passphrase. They go on every image this
build makes, so an archive built with nothing said about them would hand
them out. The step refuses while that tree is on the image and says what to
pass; `-Ddisk-tree=true` packs it deliberately.

**Proved** (01.11.2026): both archives hold what their board loads - the
Compute Module 5's with `config.txt`, the VisionFive 2's without - and the
disk image in each is the build's own. Unpacked into an empty directory it
is 34 MB with `write.sh` executable; `--print` says what it would copy,
a path that is no directory, one that cannot be written to and one of the
host's own are each refused with the reason, and copying onto a directory
standing for a mounted partition puts both files there under their own
names. A board starting from them is the user's own to do: nothing here
has been on hardware yet.
