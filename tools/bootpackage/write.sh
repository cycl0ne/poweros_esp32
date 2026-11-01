#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
#
# Copies the files this board's firmware loads onto the partition it reads
# them from - a FAT partition on a card or the module's own storage, which
# you mount and name here. `./write.sh --help` says what it takes.
#
# It only copies: which card or socket a board starts from, and what its
# loader is told, is the board's business and this script does not guess
# at it. The README beside it says what each board does with these files.

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$here"

if [ ! -f machine.conf ]; then
    echo "write.sh: no machine.conf beside it - run it where the package was unpacked" >&2
    exit 1
fi
# BOARD, CHIP, FILES, CONSOLE.
. ./machine.conf

print=no
target=

usage() {
    cat <<EOF
usage: ./write.sh [--print] <directory of the mounted boot partition>

  --print   say what would be copied, and copy nothing
  --help    this

The files this board's firmware loads are:$(for one in $FILES; do printf ' %s' "$one"; done)

Mount the board's boot partition - a FAT partition on its card or its own
storage - and name the directory it is mounted on. The README beside this
script says what each board then does with them, and what its console is.
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
    --print) print=yes ;;
    --help | -h)
        usage
        exit 0
        ;;
    -*)
        echo "write.sh: $1: no such option - ./write.sh --help" >&2
        exit 1
        ;;
    *)
        if [ -n "$target" ]; then
            echo "write.sh: one directory at a time" >&2
            exit 1
        fi
        target=$1
        ;;
    esac
    shift
done

for one in $FILES; do
    [ -f "$one" ] || { echo "write.sh: $one is missing from this directory" >&2; exit 1; }
done

if [ "$print" = yes ]; then
    for one in $FILES; do
        printf 'cp %s %s\n' "$one" "${target:-<the boot partition>}"
    done
    exit 0
fi

if [ -z "$target" ]; then
    usage >&2
    exit 1
fi
if [ ! -d "$target" ]; then
    echo "write.sh: $target is not a directory - mount the board's boot partition and name where it is mounted" >&2
    exit 1
fi
if [ ! -w "$target" ]; then
    echo "write.sh: $target cannot be written to - mount it so that you may write, or run this as the owner" >&2
    exit 1
fi
case $(CDPATH= cd -- "$target" && pwd) in
/ | /boot | /etc | /usr | /home)
    echo "write.sh: $target is the host's own - name the directory the board's boot partition is mounted on" >&2
    exit 1
    ;;
esac

# The room the files need, against what is free where they go: a disk
# image is tens of megabytes and a boot partition is often small.
need=$(du -kc $FILES | awk 'END { print $1 }')
free=$(df -Pk "$target" | awk 'NR == 2 { print $4 }')
case $free in
'' | *[!0-9]*) free=$need ;;
esac
if [ "$free" -lt "$need" ]; then
    echo "write.sh: $target has ${free} KiB free and the files need ${need} KiB" >&2
    exit 1
fi

for one in $FILES; do
    printf 'write.sh: %s -> %s/%s\n' "$one" "$target" "$one"
    cp -- "$one" "$target/$one"
done
sync
echo "write.sh: written. The console is $CONSOLE; the board loads these files as it starts."
