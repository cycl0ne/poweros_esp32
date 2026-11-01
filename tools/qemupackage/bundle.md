# PowerOS in QEMU

Everything in this directory is one machine: a kernel, a system disk, a
work disk, and a script that starts QEMU on them.

```sh
./run.sh
```

That is all it takes. The machine this package is for is named in
`machine.conf`: `qemu_virt` is QEMU's RISC-V 64 `virt` machine, four
cores under the OpenSBI firmware QEMU brings; `qemu_virt_a64` is its
AArch64 one, four Cortex-A76 cores. You need QEMU for that architecture
and nothing else: `qemu-system-riscv64` or `qemu-system-aarch64`, which
Arch has in `qemu-system-riscv` and `qemu-system-aarch64`, Debian and
Ubuntu in `qemu-system-misc` and `qemu-system-arm`, Fedora in
`qemu-system-riscv` and `qemu-system-aarch64`, and Homebrew in `qemu`.
`run.sh` asks QEMU what it was built with and leaves out what is missing,
saying so: a window needs a display backend (`gtk` or `sdl`), sound an
audio driver, the network QEMU's user-mode one. Some systems package
each of those apart from QEMU itself.

```
run.sh          starts the machine
machine.conf    which machine it is, and the files below
kernel.bin      the system itself: everything up to the file systems
system.bin      the system disk, SYS: and DH0: - 256 MB, a GPT with one
                PowerOS container and one bootable posfs partition
work.bin        a disk to keep work on, DH1: - 1 GB, empty
README.md       this
```

## What you see

The console is the terminal you started it in: the kernel's log first,
then `s3>`, which is the ROM's own debug shell - `help` lists what it
takes. **Type `newshell` there** for a shell of the system's own, where
the commands on `C:` are:

```
List SYS:                 what is on the system disk
Info                      the volumes, their sizes and what is free
Avail                     memory, and the largest block there is
ShowConfig                what this machine has; ShowConfig DEVICES for its devices
Version                   the system's release; Version dos.library for one module
Dir C: ALL                every command there is
List SYS:Tests/datatypes  a small file of every format the system reads
```

With a window, the desktop comes up in it a moment after the start, with
its own shell in `SYS:System/Shell` and the programs in `SYS:Programs`
(`Prefs` for the look and the settings, `MultiView` for a picture or a
document - `SYS:Tests/datatypes` holds one of each - `Notepad`, `Sheet`,
`Player`, `Terminal`, and `HDToolBox` for the disks). The pointer is the
host's own over the window.

Quit the machine with **Ctrl-A X** on the console. Nothing stops it from
the inside yet, and Ctrl-A X is a power cut as far as the machine is
concerned: give it a few seconds after writing something, so that what
was written has reached the disk. What has not is rolled back when the
machine next starts, as the file system does after a power cut.

## The two disks

`SYS:` is the system disk, and what the machine writes to either disk
stays in the file beside this README - the settings you change, the files
you save. `./run.sh --snapshot` throws those writes away when QEMU quits
instead, and unpacking the archive again gives a system as it was built.

The work disk starts empty; `Info` shows it as `DH1:` (Work). Its writes
are not synced to the host as they happen, so a crash of the host itself
can lose the last of them - what the machine wrote is otherwise there
when QEMU quits or is killed.

## The network

The machine has a USB Ethernet adapter on QEMU's user network, where it
is 10.0.2.15 and the host is 10.0.2.2. The system does not bring that
adapter up by itself, so in a shell:

```
C:net/AddNetInterface USB0
C:net/NetStatus
C:net/Ping 10.0.2.2
C:net/HttpGet http://10.0.2.2:8080/ TO RAM:page
```

A name needs a name server that answers through QEMU's network
(`ENVARC:Sys/net/nameservers`); an address always works. Nothing in the
machine is reachable from outside unless QEMU is told to forward a port.

## Sound

Where the host's QEMU has an audio driver, the machine is given a USB
speaker and the system prefers it:

```
C:Audio                           what the system plays through, and its mixer
C:Play DH1:song.mp3               a sound file - WAV, MP3, FLAC, Ogg, AAC, AC-3
SYS:Programs/Player               the same, with a window and a playlist
```

Neither disk holds a sound file: fetch one over the network, or give QEMU
a drive of its own as below and copy from it.

`./run.sh --audio none` leaves the speaker out; `--audio alsa` and the
like name another driver, one QEMU was built with.

## run.sh

```
--serial         no window: the console alone
--snapshot       throw away what the machine writes to either disk
--display SPEC   QEMU's -display, such as sdl,show-cursor=off
--size WxH       the screen, where the GPU takes one
--audio DRIVER   a QEMU audio driver, or none
--memory SIZE    the machine's RAM
--cores N        the cores it runs on
--print          print the QEMU command and do nothing else
--help           all of it
```

Anything after `--` goes to QEMU as it stands, so another disk, another
network or a port forward is one argument away:

```sh
./run.sh -- -device nvme,serial=2,drive=extra -drive if=none,id=extra,format=raw,file=extra.img
```

## Where this comes from

PowerOS is a kernel and a system written in Zig for ESP32-S3 and ESP32-P4
boards, for 64-bit RISC-V machines under SBI firmware and for AArch64
machines under PSCI - the StarFive VisionFive 2, the Raspberry Pi Compute
Module 5, and QEMU's two `virt` machines, which is what this package runs.
The source, the boards and the guides are at
<https://github.com/cycl0ne/poweros_esp32>.
