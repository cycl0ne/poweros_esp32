#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Fetch the pictures of the disk's icons: the Tango Desktop Project's icon
# library, released into the public domain, at a pinned release checked
# against its sha256. The ones the disk uses are drawn from their SVG
# sources at the sizes the boards show icons at - 48 pixels on a
# 1024x600 screen, 40 on a 480x320 one - with rsvg-convert, or without it
# taken from the release's 32-pixel pictures. Nothing of it is committed:
# it lands in toolchain/icons/<size>, which the build looks for; without
# it the disk has no icons of its own and icon.library's built-in ones
# stand in.
set -eu

tango=0.8.90
tango_sha256=e94004fa9aa6a7250ac4db6180e96f9c147db617c0d8e7fc8c9e2c42924e990c

# The pictures, as <folder>/<name> in the release.
pictures="
devices/drive-harddisk
places/folder
places/user-trash
mimetypes/application-x-executable
mimetypes/text-x-generic
mimetypes/text-x-script
mimetypes/image-x-generic
mimetypes/x-office-document
mimetypes/audio-x-generic
devices/audio-card
devices/multimedia-player
mimetypes/video-x-generic
apps/accessories-text-editor
actions/system-search
apps/preferences-desktop-font
categories/preferences-system
apps/utilities-system-monitor
devices/battery
apps/utilities-terminal
categories/preferences-desktop
categories/applications-system
categories/applications-other
"
sizes="48 40"

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/toolchain/icons"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

tarball="tango-icon-theme-$tango.tar.bz2"
curl -sSfL -o "$work/$tarball" "https://tango.freedesktop.org/releases/$tarball"
(cd "$work" && echo "$tango_sha256  $tarball" | sha256sum -c --quiet && tar xjf "$tarball")
theme="$work/tango-icon-theme-$tango"
cp "$theme/COPYING" "$out/COPYING"

for size in $sizes; do
    mkdir -p "$out/$size"
    for picture in $pictures; do
        name=$(basename "$picture")
        if command -v rsvg-convert >/dev/null 2>&1; then
            rsvg-convert -w "$size" -h "$size" -o "$out/$size/$name.png" "$theme/scalable/$picture.svg"
        else
            cp "$theme/32x32/$picture.png" "$out/$size/$name.png"
        fi
    done
done
if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "no rsvg-convert: the icons are the release's 32-pixel pictures"
fi
echo "icons in $out"
