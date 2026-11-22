#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Fetch what a MediaTek MT7922 card runs: its Wi-Fi's patch for the ROM
# and RAM code, and its Bluetooth's RAM code, as linux-firmware has them,
# at a pinned commit and each checked against its sha256, with MediaTek's
# licence for passing them on (to be used with devices that have MediaTek
# chips). Nothing of it is committed - it lands in toolchain/mt7922, which
# the build looks for; without it the 64-bit disks have no
# DEVS:networks/firmware/mt7922/ and DEVS:usb/firmware/mediatek/, and
# networks/mt7922.device and usb/bluetooth.device find the card but cannot
# start it.
set -eu

commit=a1ebb5ad7eae3caca60b8b3db5792cf43339ba58
base="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain"

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/toolchain/mt7922"
mkdir -p "$out"
cd "$out"

curl -sSfL -o WIFI_MT7922_patch_mcu_1_1_hdr.bin "$base/mediatek/WIFI_MT7922_patch_mcu_1_1_hdr.bin?id=$commit"
curl -sSfL -o WIFI_RAM_CODE_MT7922_1.bin "$base/mediatek/WIFI_RAM_CODE_MT7922_1.bin?id=$commit"
curl -sSfL -o BT_RAM_CODE_MT7922_1_1_hdr.bin "$base/mediatek/BT_RAM_CODE_MT7922_1_1_hdr.bin?id=$commit"
curl -sSfL -o LICENCE.mediatek "$base/LICENSES/LICENCE.mediatek?id=$commit"

sha256sum -c --quiet <<'SUMS'
5356256c3a361ce6a06165f67cb01b55aecaac0e2f8d2d9cbde6312c4cf1a91c  WIFI_MT7922_patch_mcu_1_1_hdr.bin
ae4dab06cc1849682e254fe97183ed093c51382baca9b3f8a00fd6809ab71884  WIFI_RAM_CODE_MT7922_1.bin
cedd2d9326dafd5d14f509a8e77a49a8d4fe0571c8a8a34a16242bd41450b6b7  BT_RAM_CODE_MT7922_1_1_hdr.bin
a90d3f66704d85889945fec5525ea77622549da83aced1aac99828383f8f1805  LICENCE.mediatek
SUMS
echo "MT7922 firmware in $out"
