# The archive of an ESP32 board

`./zig build archive -Dboard=waveshare_7b -Ddisk-tree=false` packs a board
somebody can write and run without building it: the kernel, the flash disk
that holds the programs and libraries it was built with, and a script that
writes both over USB.

```
release/poweros-waveshare_7b.tar.gz    6.2 MB, the download
release/poweros-waveshare_7b/          the same files, to try before handing out
  flash.sh        ./flash.sh [--port ...] [--kernel|--disk] [--print]
  machine.conf    the board, the chip, where each piece goes, which port is its console
  kernel.bin      the kernel - on the ESP32-P4 the part the ROM loads into memory
  kernel-flash.bin  on the ESP32-P4 only: the part that runs in place from flash
  disk.bin        the flash disk (disk-esp32p4.bin on the ESP32-P4)
  README.md       what it is and how it is used (`bundle.md` here)
```

This is what `archive` packs for the ESP32 boards - the two ESP32-S3 ones
and the two ESP32-P4 ones. The other boards get an archive of their own
kind: QEMU's machines one that starts them
([qemupackage](../qemupackage/README.md)), the 64-bit boards the files
their firmware loads ([bootpackage](../bootpackage/README.md)).

**What `flash.sh` runs is what `flash-all` runs.** The disk area is erased,
then the kernel's parts and the disk are written in one esptool pass, at
the offsets this build used (`-Ddisk-offset`): on the ESP32-S3 the kernel
at 0, on the ESP32-P4 the two parts at 0x2000 and 0x40000. `--kernel` and
`--disk` are `flash` and `flash-disk`, and the script says in its help why
writing both is what a board wants - the disk holds what this kernel was
built with, and a kernel from one build with a disk from another fails in
ways that look like anything but a stale disk.

The merged 16 MB `flash.bin` is not in the package: it holds the same
kernel and the same disk a second time, and the archive would be twice the
size for nothing. The parts at their offsets are what esptool writes
anyway.

**`flash.sh` asks the host what it has.** esptool under either of its
names, and the board's port: the one `--port` names, else the first that
is there of the names a board of this kind comes up as. Neither being
there is said plainly, with what to install (`pip install esptool`) or
what to plug in. The script needs nothing else, and runs on any POSIX
shell.

`machine.conf` holds what the build knows and the script cannot ask for:
the chip, the kernel's parts as `<offset>=<file>` pairs, where the disk
goes and how large its area is, the port a board of this kind usually is,
and what the board's console is - which the script prints once it has
written the flash, with the command that reads it.

**`-Ddisk-tree=false`, and why the step insists.** The `disk/` tree in the
repository's root is the builder's own files, and among them are the
network settings - which hold a passphrase. They go on every image this
build makes, so a package built with nothing said about them would hand
them out. The step refuses while that tree is on the image and says what to
pass; `-Ddisk-tree=true` packs it deliberately.

**Proved** (01.11.2026): the archive unpacked into an empty directory has
`flash.sh` executable, and `--print` gives exactly the commands `flash`,
`flash-disk` and `flash-all` run for that board, with the port it found;
the ESP32-P4's two kernel parts in the package are byte for byte what the
build installs as `kernel.bin` and `kernel-flash.bin`; and no file of the
`disk/` tree is in the disk image. Writing a board is the user's own to
do: nothing here has been on hardware yet.
