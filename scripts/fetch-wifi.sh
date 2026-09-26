#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Fetch the radio's vendor libraries that wifi.device links: Espressif's
# closed Wi-Fi and PHY archives for the ESP32-S3, and the chip ROM's linker
# scripts (the addresses of the functions and data the archives use from
# mask ROM). Each comes at a pinned commit and is checked against its
# sha256, so every build links the same bytes. Nothing of it is committed:
# it lands in toolchain/espressif-wifi, which the build looks for; without
# it the disk has everything but wifi.device.
set -eu

wifi_lib=7cd4d7b2b4acc38aead43b029ac9409c3eba9c54 # espressif/esp32-wifi-lib
phy_lib=5695f4f38108658bc4a33e4712c1ebcb34911434  # espressif/esp-phy-lib
idf=4dc1c65503e98e9a6b4c3c5646237280ba79829b      # espressif/esp-idf v6.1

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/toolchain/espressif-wifi"
work="$root/toolchain/espressif-wifi-src"

# fetch <repo> <commit> <dir> [<sparse path>]
fetch() {
    if [ ! -d "$3/.git" ]; then
        git init -q "$3"
        git -C "$3" remote add origin "https://github.com/espressif/$1.git"
    fi
    if [ $# -ge 4 ]; then
        git -C "$3" sparse-checkout set --no-cone "$4"
    fi
    git -C "$3" fetch -q --depth 1 --filter=blob:none origin "$2"
    git -C "$3" checkout -q FETCH_HEAD
}

mkdir -p "$work" "$out"
fetch esp32-wifi-lib "$wifi_lib" "$work/wifi"
fetch esp-phy-lib "$phy_lib" "$work/phy"
fetch esp-idf "$idf" "$work/idf" "/components/esp_rom/esp32s3/ld/"

for name in libcore libnet80211 libpp; do
    cp "$work/wifi/esp32s3/$name.a" "$out/"
done
cp "$work/phy/esp32s3/libphy.a" "$out/"
for name in esp32s3.rom esp32s3.rom.libc esp32s3.rom.libgcc esp32s3.rom.api; do
    cp "$work/idf/components/esp_rom/esp32s3/ld/$name.ld" "$out/"
done

cd "$out"
sha256sum -c --quiet <<EOF
7f4292928b5d6b6620ec89d603198ff4f720cb9aab8eca6cdfecac78eaa182ed  libcore.a
265e5c89ac0d2a9444b5b466afee49f631ec549f96774f91a721ab5069c58e20  libnet80211.a
ae7004d00c2c5e1cf106548b22e2ed5bb3a059d65393f4e15791019658191cdb  libpp.a
038ac2bc37dc297e295811bc095d2b360a49aa0dddaa51ccb4b60ce2d1b2b73f  libphy.a
3abed7ef1f85a810335b8f639ddee19f18fa9f7083253601548c25a17af62dc9  esp32s3.rom.ld
1e3109bd7da3b57bbc918be215536ef97472896518ccc46a79ac906a43f0e0df  esp32s3.rom.libc.ld
12f69326e7449fe102b7df3d1d6582c4d7220daed6e852b129dc2c3ed77d7685  esp32s3.rom.libgcc.ld
073eff064f4e6b679267f14e1bd379e06e2a15010667c41978316a9de8ec80eb  esp32s3.rom.api.ld
EOF
echo "vendor libraries in $out"
