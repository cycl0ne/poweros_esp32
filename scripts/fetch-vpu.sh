#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Fetch the firmware the JH7110's video decoder (Chips&Media's WAVE511)
# runs, as StarFive ships it for their kernel's wave5 driver, and
# Chips&Media's licence for it, each at a pinned commit and checked
# against its sha256. Nothing of it is committed: it lands in
# toolchain/wave511, which the build looks for; without it the RISC-V 64
# disk has no DEVS:firmware/ and videodec.resource opens no decoder.
set -eu

firmware="https://raw.githubusercontent.com/starfive-tech/buildroot/8c06ed2f3e5811f27537b9613891f0111364d2d1/package/starfive/wave511/wave511_dec_fw.bin"
licence="https://raw.githubusercontent.com/starfive-tech/soft_3rdpart/5b9ddff6da7d29b7b6fb2ffb5620b8d3410f4e25/wave511/firmware/LICENSE.txt"

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/toolchain/wave511"
mkdir -p "$out"
cd "$out"

curl -sSfL -o wave511_dec_fw.bin "$firmware"
curl -sSfL -o LICENSE.txt "$licence"

sha256sum -c --quiet <<'SUMS'
398eb201cf4d6c5050856de5660764a743b8879a69b8684d12aadb556409b79c  wave511_dec_fw.bin
8c15e1830a2e7638ca982f22db27c226df3f4b05771f8b28369549e0298cea2c  LICENSE.txt
SUMS
echo "WAVE511 firmware in $out"
