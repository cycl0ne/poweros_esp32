#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Fetch what the Raspberry Pi CM5's and 4 Model B's radio, a CYW43455,
# runs: Infineon's firmware for it, its CLM blob (the rules of each
# country's channels and powers) and the boards' NVRAM - one file for
# both - as Raspberry Pi's firmware-nonfree package has them; and its
# Bluetooth's patch, BCM4345C0.hcd, as Raspberry Pi's bluez-firmware
# package has it, with the licence for passing it on that package names,
# linux-firmware's LICENCE.cypress. Each at a pinned commit and checked
# against its sha256. Nothing of it is committed - it lands in
# toolchain/cyw43455, which the build looks for; without it the AArch64
# disks have no DEVS:networks/firmware/cyw43455/ and
# DEVS:bluetooth/firmware/broadcom/, networks/cyw43455.device finds the
# chip but cannot start it, and bluetooth/cyw43455bt.device runs the
# controller on the firmware in its ROM.
set -eu

commit=c91cd2804cf7463aab913e7247c176049f16bbd6
base="https://raw.githubusercontent.com/RPi-Distro/firmware-nonfree/$commit/debian/config/brcm80211"
bluez_commit=cdf61dc691a49ff01a124752bd04194907f0f9cd
bluez="https://raw.githubusercontent.com/RPi-Distro/bluez-firmware/$bluez_commit/debian/firmware/broadcom"
linux_commit=a1ebb5ad7eae3caca60b8b3db5792cf43339ba58
linux="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain"

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/toolchain/cyw43455"
mkdir -p "$out"
cd "$out"

# The firmware is the "standard" one, which Raspberry Pi OS runs; the
# names are the ones the device asks for.
curl -sSfL -o cyfmac43455-sdio.bin "$base/cypress/cyfmac43455-sdio-standard.bin"
curl -sSfL -o cyfmac43455-sdio.clm_blob "$base/cypress/cyfmac43455-sdio.clm_blob"
curl -sSfL -o brcmfmac43455-sdio.txt "$base/brcm/brcmfmac43455-sdio.txt"
curl -sSfL -o BCM4345C0.hcd "$bluez/BCM4345C0.hcd"
curl -sSfL -o LICENCE.cypress "$linux/LICENSES/LICENCE.cypress?id=$linux_commit"

sha256sum -c --quiet <<'SUMS'
d608f866582519c0a28d86db43040f4f1b98dd1d153e72e9752586546b4a36c3  cyfmac43455-sdio.bin
9823842cae9fb9a5dd1e5fb31f595516ec7deee341354bef30bb3026eee29cc1  cyfmac43455-sdio.clm_blob
ca709be81a78bdb6932936374f39943acbd7af07fae6151011127599a3ce9e3d  brcmfmac43455-sdio.txt
51c45e77ddad91a19e96dc8fb75295b2087c279940df2634b23baf71b6dea42c  BCM4345C0.hcd
ae0db6cc4db33941148df0f67de53e76a77b1b5a46b3165edb7040aa2750015f  LICENCE.cypress
SUMS
echo "CYW43455 firmware in $out"
