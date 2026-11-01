#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
#
# Writes PowerOS to the board this package is for, over USB, with
# esptool. `./flash.sh --help` says what it takes.
#
# By default it writes the kernel and a fresh flash disk in one go, the
# disk area erased first - the pairing that matters, since the disk holds
# the programs and the libraries this kernel was built with. `--kernel`
# writes the kernel alone and leaves the disk as it is; `--disk` the other
# way round.
#
# No value here holds a blank, so the arguments are built as one word
# list; the kernel's parts are `<offset>=<file>` pairs.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$here"

if [ ! -f machine.conf ]; then
    echo "flash.sh: no machine.conf beside it - run it where the package was unpacked" >&2
    exit 1
fi
# BOARD, CHIP, KERNEL, DISK, DISK_SIZE, PORT, BAUD, CONSOLE.
. ./machine.conf

port=
baud=$BAUD
what=all
print=no

usage() {
    cat <<EOF
usage: ./flash.sh [options]

  --port PATH    the board's serial port (default: the first that is there)
  --baud RATE    how fast to write (default: $BAUD)
  --kernel       the kernel alone, leaving the flash disk as it is
  --disk         a fresh flash disk alone, erasing what is on it
  --print        print the esptool commands and do nothing else
  --help         this

With neither --kernel nor --disk it writes both, which is what a board
wants: the disk holds the programs and libraries this kernel was built
with, and a kernel from one build with a disk from another fails in ways
that look like anything but a stale disk.
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
    --port)
        port=${2:-}
        [ -n "$port" ] || { echo "flash.sh: --port takes the board's serial port" >&2; exit 1; }
        shift
        ;;
    --baud)
        baud=${2:-}
        [ -n "$baud" ] || { echo "flash.sh: --baud takes a rate, such as 921600" >&2; exit 1; }
        shift
        ;;
    --kernel) what=kernel ;;
    --disk) what=disk ;;
    --print) print=yes ;;
    --help | -h)
        usage
        exit 0
        ;;
    *)
        echo "flash.sh: $1: no such option - ./flash.sh --help" >&2
        exit 1
        ;;
    esac
    shift
done

tool=
for one in esptool esptool.py; do
    if command -v "$one" >/dev/null 2>&1; then
        tool=$one
        break
    fi
done
if [ -z "$tool" ]; then
    echo "flash.sh: esptool is not on the path: install it with \"pip install esptool\" (version 5 or newer), or from your system's packages" >&2
    exit 1
fi

# The port: the one that was given, else the first of the names a board
# of this kind comes up as.
if [ -z "$port" ]; then
    for one in "$PORT" /dev/ttyACM0 /dev/ttyACM1 /dev/ttyUSB0 /dev/ttyUSB1 /dev/cu.usbmodem* /dev/cu.usbserial-*; do
        if [ -e "$one" ]; then
            port=$one
            break
        fi
    done
fi
if [ -z "$port" ]; then
    echo "flash.sh: no serial port found - plug the board in, or name it with --port (it is $PORT on this kind of board)" >&2
    exit 1
fi

for pair in $KERNEL $DISK; do
    file=${pair#*=}
    [ -f "$file" ] || { echo "flash.sh: $file is missing from this directory" >&2; exit 1; }
done

common="--chip $CHIP --port $port --baud $baud"

# What goes where: the kernel's parts, the disk, or both. The disk area is
# erased before a disk is written - and that is not belt and braces. The
# image holds only the blocks the file system touched, and the file system
# is a log: what replay believes is whatever carries the highest sequence
# number, so writing a fresh image over a disk that has been used leaves
# older, further-along segments in place, and those outrank it.
kernel_parts=
for pair in $KERNEL; do
    kernel_parts="$kernel_parts ${pair%%=*} ${pair#*=}"
done
disk_parts=
for pair in $DISK; do
    disk_parts="$disk_parts ${pair%%=*} ${pair#*=}"
    disk_at=${pair%%=*}
done

erase=
write=
case $what in
all)
    erase="$tool $common erase-region $disk_at $DISK_SIZE"
    write="$tool $common write-flash$kernel_parts$disk_parts"
    ;;
kernel)
    write="$tool $common write-flash$kernel_parts"
    ;;
disk)
    erase="$tool $common erase-region $disk_at $DISK_SIZE"
    write="$tool $common write-flash$disk_parts"
    ;;
esac

if [ "$print" = yes ]; then
    [ -z "$erase" ] || echo "$erase"
    echo "$write"
    exit 0
fi

echo "flash.sh: PowerOS for $BOARD onto $port at $baud baud"
if [ -n "$erase" ]; then
    # shellcheck disable=SC2086
    $erase
fi
# shellcheck disable=SC2086
$write
echo "flash.sh: written. The console is $CONSOLE - \"tio $port\" or \"screen $port 115200\" reads it - and the board starts as it is reset."
