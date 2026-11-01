# qemu-package

`./zig build qemu-package -Dboard=qemu_virt -Ddisk-tree=false` packs a
machine someone can run without building it: the kernel, the system disk,
a work disk, and a script that starts QEMU on them.

```
release/poweros-qemu_virt.tar.gz    7.4 MB, the download
release/poweros-qemu_virt/          the same files, to try before handing out
  run.sh          starts QEMU on what is beside it
  machine.conf    which machine it is, and the files below (written by the build)
  kernel.bin      the board's kernel
  system.bin      the system disk, 256 MB (tools/mkfs --gpt)
  work.bin        a blank work disk, 1 GB (tools/mkfs --blank)
  README.md       what it is and how it is used (`bundle.md` here)
```

It is for QEMU's two `virt` machines - `-Dboard=qemu_virt` (RISC-V 64)
and `-Dboard=qemu_virt_a64` (AArch64) - whose kernel and disks a plain
QEMU runs. The ESP32 boards' QEMU is Espressif's own
(`scripts/build-qemu.sh`), which nobody has by downloading an archive, so
the step refuses for those boards and says why; a board is packed by
`esp-package` instead, and `./zig build release` makes every board's
artifact at once.

**The files in it are mostly holes, and stay holes.** `tools/mkfs` writes
only the blocks it touches, so `system.bin` is some 17 MB of its 256 and
`work.bin` 108 KB of its 1 GB; the build's copy keeps the holes,
`tar -czS` stores them as holes, and tar makes them holes again where the
archive is unpacked. So the download is under 8 MB and what it leaves on a
disk is 18 MB, though the two images are 1.3 GB long.

**`run.sh` asks QEMU what it has.** A display backend (`gtk`, then `sdl`),
the virtio GPU or the ramfb, an audio driver, QEMU's user-mode network:
each is asked for (`-display help`, `-device help`, `-audiodev help`,
`-netdev help`) and left out, with a word about it, where it is missing -
so the script runs on a host that packages QEMU's parts apart, which many
do. Naming an audio driver QEMU was built without ends QEMU in a fault
rather than an error, which is the reason that one is asked for too.
`machine.conf` holds what the build knows and the script cannot ask for:
the QEMU to start, the machine's own arguments as the project's README
gives them for that board, and the file names.

**`-Ddisk-tree=false`, and why the step insists.** The `disk/` tree in the
repository's root is the builder's own files, and among them are the
network settings - which hold a passphrase. They go on every image this
build makes, so a package built without a word about them would hand them
out. The step refuses while the tree is on the image and says what to
pass: `-Ddisk-tree=false` leaves it off, and `-Ddisk-tree=true` packs it
deliberately. `-Dextra=` and `-Dgames` are named one by one on the
command line, so they are nobody's surprise, but they do go on the virt
machines' system disk and from there into the package.

**Proved** (01.11.2026, `-Dboard=qemu_virt`): the archive unpacked into an
empty directory is 18 MB on disk with `run.sh` still executable;
`./run.sh --print` gives the same machine the `virt-display` step runs,
and with `--serial` one without a window; the machine boots from
`system.bin`, `Info` shows `System` and the work disk mounts on first use;
a file written to `DH1:` is there in the next run, from the same two
files; and the step refuses with the reason both for an ESP32 board and
while the `disk/` tree is on the image.
