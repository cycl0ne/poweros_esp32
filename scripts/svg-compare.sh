#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# svg.datatype against rsvg-convert: every SVG file of the Tango release
# the disk's icons come from (scripts/fetch-icons.sh's pinned tarball),
# or the files given, drawn by rsvg-convert and by svg.datatype's own
# code on the host (tools/svgcompare), and compared.
#
#   scripts/svg-compare.sh [--size N] [--detail] [--out DIR] [--zoom Z] [--disk] [file.svg ...]
#
# --disk compares only the pictures the disk's icons are made from.
# --out DIR keeps a picture of each comparison there: ours, rsvg's, and
# the difference four times over, each pixel Z by Z. Needs rsvg-convert.
set -eu

tango=0.8.90
tango_sha256=e94004fa9aa6a7250ac4db6180e96f9c147db617c0d8e7fc8c9e2c42924e990c

size=48
out=
zoom=1
detail=
disk=no
while [ $# -gt 0 ]; do
    case "$1" in
        --size) size=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        --zoom) zoom=$2; shift 2 ;;
        --detail) detail=--detail; shift ;;
        --disk) disk=yes; shift ;;
        *) break ;;
    esac
done

command -v rsvg-convert >/dev/null 2>&1 || { echo "svg-compare: needs rsvg-convert"; exit 1; }
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ $# -eq 0 ]; then
    tarball="tango-icon-theme-$tango.tar.bz2"
    curl -sSfL -o "$work/$tarball" "https://tango.freedesktop.org/releases/$tarball"
    (cd "$work" && echo "$tango_sha256  $tarball" | sha256sum -c --quiet && tar xjf "$tarball")
    theme="$work/tango-icon-theme-$tango/scalable"
    if [ "$disk" = yes ]; then
        # The pictures fetch-icons.sh draws, from its own list.
        pictures=$(sed -n '/^pictures="/,/^"/p' "$root/scripts/fetch-icons.sh" | grep -v '"')
        set --
        for picture in $pictures; do set -- "$@" "$theme/$picture.svg"; done
    else
        set -- $(find "$theme" -name '*.svg' | sort)
    fi
fi

mkdir -p "$work/drawn"
[ -n "$out" ] && mkdir -p "$out"
pairs=
n=0
for file in "$@"; do
    n=$((n + 1))
    png="$work/drawn/$n.png"
    rsvg-convert -w "$size" -h "$size" -o "$png" "$file"
    pairs="$pairs $file $png"
done
cd "$root"
# shellcheck disable=SC2086
./zig build svgcompare -- --size "$size" $detail ${out:+--out "$out" --zoom "$zoom"} $pairs
