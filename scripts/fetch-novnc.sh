#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Fetch noVNC, a VNC client that runs in a browser, at a pinned release
# checked against its sha256. `scripts/qemu-web.sh` serves it beside a
# QEMU that shows the machine's picture over VNC, so the display can be
# watched and used in a browser tab - a headless machine one develops on
# over the network, or another room. Nothing of it is committed: it
# lands in toolchain/novnc.
set -eu

version=1.7.0
sha256=b1003a11b6e6e8d8f7f5e5586daae7f8ca651d8aee0aa155ff9ac841c48f52c6

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/toolchain/novnc"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

tarball="noVNC-$version.tar.gz"
curl -sSfL -o "$work/$tarball" "https://github.com/novnc/noVNC/archive/refs/tags/v$version.tar.gz"
(cd "$work" && echo "$sha256  $tarball" | sha256sum -c --quiet && tar xzf "$tarball")
rm -rf "$out"
mkdir -p "$(dirname "$out")"
mv "$work/noVNC-$version" "$out"

echo "noVNC $version in $out"
