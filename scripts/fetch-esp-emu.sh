#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Fetch Espressif's esp-emulator, the emulator the ESP32-P4 runs in: both
# HP cores, the CLIC, UART0 on the terminal, the system timer, flash with
# its cache and MMU, PSRAM, the Ethernet MAC and a GDB stub, booting the
# chip's own mask ROM. Released as binaries under Apache-2.0, at a pinned
# version checked against its sha256 for the host it runs on. And the ROM
# it boots: the emulator carries a v3.x chip's; the boards' chips are
# v1.x, whose ROM comes from Espressif's ROM ELFs (esp-rom-elfs), pinned
# and checked the same way. Nothing of it is committed: it lands in
# toolchain/esp-emu/ (esp-emu, esp32p4_rev0_rom.elf).
set -eu

version=0.48.0
rom_elfs=20241011
rom_elfs_sha256=921f000164a421c7628fbfee55b173384aafaa51883adc65cd27bf9b0af9e9a9

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

roms="esp-rom-elfs-$rom_elfs.tar.gz"
curl -sSfL -o "$work/$roms" "https://github.com/espressif/esp-rom-elfs/releases/download/$rom_elfs/$roms"
(cd "$work" && echo "$rom_elfs_sha256  $roms" | sha256sum -c --quiet && tar xzf "$roms" -C "$out" esp32p4_rev0_rom.elf)
echo "esp-emulator and the ESP32-P4 v1.x ROM in $out"
