#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Fetch what the Raspberry Pi CM5's radio, a CYW43455, runs: Infineon's
# firmware for it, its CLM blob (the rules of each country's channels
# and powers) and the board's NVRAM, as Raspberry Pi's firmware-nonfree
# package has them, at a pinned commit and each checked against its
# sha256. Nothing of it is committed - its licence for passing it on is
# Infineon's - it lands in toolchain/cyw43455, which the build looks for;
# without it the AArch64 disk has no DEVS:networks/firmware/cyw43455/
# and networks/cyw43455.device finds the chip but cannot start it.
set -eu

commit=c91cd2804cf7463aab913e7247c176049f16bbd6
base="https://raw.githubusercontent.com/RPi-Distro/firmware-nonfree/$commit/debian/config/brcm80211"

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/toolchain/cyw43455"
mkdir -p "$out"
cd "$out"

# The firmware is the "standard" one, which Raspberry Pi OS runs; the
# names are the ones the device asks for.
curl -sSfL -o cyfmac43455-sdio.bin "$base/cypress/cyfmac43455-sdio-standard.bin"
curl -sSfL -o cyfmac43455-sdio.clm_blob "$base/cypress/cyfmac43455-sdio.clm_blob"
curl -sSfL -o brcmfmac43455-sdio.txt "$base/brcm/brcmfmac43455-sdio.txt"

sha256sum -c --quiet <<'SUMS'
d608f866582519c0a28d86db43040f4f1b98dd1d153e72e9752586546b4a36c3  cyfmac43455-sdio.bin
9823842cae9fb9a5dd1e5fb31f595516ec7deee341354bef30bb3026eee29cc1  cyfmac43455-sdio.clm_blob
ca709be81a78bdb6932936374f39943acbd7af07fae6151011127599a3ce9e3d  brcmfmac43455-sdio.txt
SUMS
echo "CYW43455 firmware in $out"
