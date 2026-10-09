#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Fetch Espressif's esp-emulator, the emulator the ESP32-P4 runs in: both
# HP cores, the CLIC, UART0 on the terminal, the system timer, flash with
# its cache and MMU, PSRAM, the Ethernet MAC and a GDB stub, booting the
# chip's own mask ROM. Released as binaries under Apache-2.0, at a pinned
# version checked against its sha256 for the host it runs on. Nothing of it
# is committed: it lands in toolchain/esp-emu/esp-emu.
set -eu

version=0.48.0

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)
        target=x86_64-unknown-linux-gnu
        sha256=d29d41dbc5f6926284a5daeaf199a1500740992087e088c1211ffc2546e764bd
        ;;
    Linux-aarch64 | Linux-arm64)
        target=aarch64-unknown-linux-gnu
        sha256=fdcf3b906c08823703eb6f4bee620b6ec5d7a5c7186db848d26790fdf14702a5
        ;;
    Darwin-arm64)
        target=aarch64-apple-darwin
        sha256=9f1040eac290e43e7f7c1a568886b5aaf25e3ecd768b5a068155e9391de372d5
        ;;
    *)
        echo "esp-emulator has no release for $(uname -s) $(uname -m)" >&2
        exit 1
        ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/toolchain/esp-emu"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

tarball="esp-emu-$version-$target.tar.gz"
curl -sSfL -o "$work/$tarball" "https://github.com/espressif/esp-emulator/releases/download/v$version/$tarball"
(cd "$work" && echo "$sha256  $tarball" | sha256sum -c --quiet && mkdir unpacked && tar xzf "$tarball" -C unpacked)

binary=$(find "$work/unpacked" -type f -name esp-emu | head -n 1)
if [ -z "$binary" ]; then
    echo "no esp-emu in $tarball" >&2
    exit 1
fi
mkdir -p "$out"
cp "$binary" "$out/esp-emu"
chmod +x "$out/esp-emu"
"$out/esp-emu" --version
echo "esp-emulator in $out"
