#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
#
# PowerOS in QEMU: boots the kernel and the two disks that lie beside this
# script. `./run.sh --help` says what it takes.
#
# What QEMU has differs from host to host - a display backend, an audio
# driver, the user-mode network, the virtio GPU - so each is asked for
# before it is used (`-display help`, `-audiodev help`, `-netdev help`,
# `-device help`) and left out, with a word about it, where it is missing.
# Naming an audio driver QEMU was built without makes QEMU stop with a
# fault rather than an error, which is why that one is asked for too.
#
# No value here holds a blank, so the arguments are built as one word list.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$here"

if [ ! -f machine.conf ]; then
    echo "run.sh: no machine.conf beside it - run it where the package was unpacked" >&2
    exit 1
fi
# BOARD, QEMU, QEMU_PACKAGE, MACHINE, CPU, MEMORY, CORES, SIZE, KERNEL,
# SYSTEM, WORK.
. ./machine.conf

serial=no
snapshot=no
display=
audio=
size=$SIZE
memory=$MEMORY
cores=$CORES
print=no

usage() {
    cat <<EOF
usage: ./run.sh [options] [-- <arguments for QEMU>]

  --serial         no window: the console on this terminal and nothing drawn
  --snapshot       throw away what the machine writes to either disk
  --display SPEC   QEMU's -display (default: gtk or sdl, whichever it has)
  --size WxH       the screen, where the GPU takes one (default: $SIZE)
  --audio DRIVER   QEMU's audio driver, or none (default: the first it has)
  --memory SIZE    the machine's RAM (default: $MEMORY)
  --cores N        the cores it runs on (default: $CORES)
  --print          print the QEMU command and do nothing else
  --help           this

The console is this terminal either way: the kernel's log, then the ROM
debug shell's "s3>", where "newshell" opens a shell of the system's own.
Quit the machine with Ctrl-A X.
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
    --serial) serial=yes ;;
    --snapshot) snapshot=yes ;;
    --display)
        display=${2:-}
        [ -n "$display" ] || { echo "run.sh: --display takes a QEMU display, such as gtk" >&2; exit 1; }
        shift
        ;;
    --size)
        size=${2:-}
        [ -n "$size" ] || { echo "run.sh: --size takes WxH, such as 1280x720" >&2; exit 1; }
        shift
        ;;
    --audio)
        audio=${2:-}
        [ -n "$audio" ] || { echo "run.sh: --audio takes a QEMU audio driver, or none" >&2; exit 1; }
        shift
        ;;
    --memory)
        memory=${2:-}
        [ -n "$memory" ] || { echo "run.sh: --memory takes a size, such as 512M" >&2; exit 1; }
        shift
        ;;
    --cores)
        cores=${2:-}
        [ -n "$cores" ] || { echo "run.sh: --cores takes a number" >&2; exit 1; }
        shift
        ;;
    --print) print=yes ;;
    --help | -h)
        usage
        exit 0
        ;;
    --)
        shift
        break
        ;;
    *)
        echo "run.sh: $1: no such option - ./run.sh --help" >&2
        exit 1
        ;;
    esac
    shift
done

if ! command -v "$QEMU" >/dev/null 2>&1; then
    echo "run.sh: $QEMU is not on the path: install $QEMU_PACKAGE" >&2
    exit 1
fi
for file in "$KERNEL" "$SYSTEM" "$WORK"; do
    [ -f "$file" ] || { echo "run.sh: $file is missing from this directory" >&2; exit 1; }
done

has_device() { "$QEMU" -device help 2>&1 | grep -q "name \"$1\""; }
has_display() { "$QEMU" -display help 2>&1 | grep -qx "$1"; }
has_audio() { "$QEMU" -audiodev help 2>&1 | grep -qx "$1"; }
has_netdev() { "$QEMU" $MACHINE -netdev help 2>&1 | grep -qx "$1"; }

# The screen: the virtio GPU, which is told each rectangle drawn, or the
# ramfb, which reads the picture out of memory itself and takes the size
# the system gives it. Either needs a window to show it in.
screen=
if [ "$serial" = no ]; then
    if [ -z "$display" ]; then
        for one in gtk sdl; do
            if has_display "$one"; then
                case $one in
                gtk) display=gtk,zoom-to-fit=off ;;
                sdl) display=sdl,show-cursor=off ;;
                esac
                break
            fi
        done
    fi
    if [ -z "$display" ]; then
        echo "run.sh: this QEMU has neither gtk nor sdl, so there is no window (its display packages are apart on some systems, such as qemu-ui-gtk): the console alone"
        serial=yes
    elif has_device virtio-gpu-device; then
        screen="-device virtio-gpu-device,xres=${size%x*},yres=${size#*x}"
    elif has_device ramfb; then
        echo "run.sh: no virtio GPU in this QEMU (qemu-hw-display-virtio-gpu on some systems): the ramfb instead, at the size the system picks"
        screen="-device ramfb"
    else
        echo "run.sh: this QEMU has no display device at all: the console alone"
        serial=yes
        display=
    fi
fi
if [ "$serial" = yes ]; then
    screen=
    display=none
fi

# Sound through a USB speaker, on the first driver this QEMU was built
# with: at 48000 Hz, which is what the system plays, so nothing resamples.
sound=
if [ "$audio" != none ]; then
    if [ -z "$audio" ]; then
        for one in pipewire pa alsa coreaudio sdl dsound; do
            if has_audio "$one"; then
                audio=$one
                break
            fi
        done
    fi
    if [ -n "$audio" ]; then
        sound="-audiodev $audio,id=snd,out.frequency=48000 -device usb-audio,audiodev=snd"
    else
        echo "run.sh: this QEMU has no audio driver (its audio packages are apart on some systems, such as qemu-audio-pa): no speaker"
    fi
fi

# The network, through a USB Ethernet adapter on QEMU's user network: the
# machine is 10.0.2.15 and the host 10.0.2.2. The system does not bring
# the adapter up by itself - `C:net/AddNetInterface USB0` in its shell
# does, and the package's README says so.
network=
if has_netdev user; then
    network="-netdev user,id=net0 -device usb-net,netdev=net0"
else
    echo "run.sh: this QEMU has no user-mode network (libslirp): no network in the machine"
fi

keep=
[ "$snapshot" = no ] || keep=,snapshot=on

# The work disk's writes are not synced to the host as they happen
# (`cache=unsafe`): each sync would be a write of the image file for every
# flush the file system makes. What the machine wrote is in the host's own
# cache and stays there when QEMU quits or is killed; only a crash of the
# host itself can lose the last of it.
set -- \
    $MACHINE $CPU -m "$memory" -smp "$cores" \
    -kernel "$KERNEL" \
    -serial mon:stdio -display "$display" \
    -drive "if=none,id=system,format=raw,file=$SYSTEM$keep" \
    -device nvme,serial=system,drive=system \
    -drive "if=none,id=work,format=raw,cache=unsafe,file=$WORK$keep" \
    -device nvme,serial=1,drive=work \
    -device qemu-xhci -device usb-kbd -device usb-tablet \
    $screen $sound $network "$@"

if [ "$print" = yes ]; then
    printf '%s' "$QEMU"
    for one in "$@"; do printf ' %s' "$one"; done
    printf '\n'
    exit 0
fi

if [ "$serial" = yes ]; then
    echo "run.sh: PowerOS on $BOARD, $memory, $cores cores, no window (quit with Ctrl-A X)"
else
    echo "run.sh: PowerOS on $BOARD, $memory, $cores cores, $display (quit with Ctrl-A X)"
fi
exec "$QEMU" "$@"
