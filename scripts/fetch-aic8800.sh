#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Fetch the firmware an AICSemi AIC8800 USB Wi-Fi stick runs: the files
# its boot ROM is given before it comes back as a Wi-Fi device, as
# AICSemi ships them for its Linux driver, at a pinned commit and each
# checked against its sha256. Nothing of it is committed - its licence
# for passing it on is not clear - it lands in toolchain/aic8800, which
# the build looks for; without it the disk has no
# DEVS:usb/firmware/aic8800/ and usb/aic8800.device leaves the stick as
# it found it.
set -eu

commit=e9e43ed79c50483080e9bcdfb08caeeb869d7191
base="https://raw.githubusercontent.com/radxa-pkg/aic8800/$commit/src/USB/driver_fw/fw/aic8800"

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/toolchain/aic8800"
mkdir -p "$out"
cd "$out"

for file in fmacfw.bin fw_adid.bin fw_adid_u03.bin fw_patch.bin fw_patch_u03.bin \
    fw_patch_table.bin fw_patch_table_u03.bin; do
    curl -sSfL -o "$file" "$base/$file"
done

sha256sum -c --quiet <<'EOF'
a5d142031150b33771ec80772b1e7c96d57a1c7dccc8151a4f729408d7bd0f57  fmacfw.bin
1a54cd5f56552b1df20ae20377194ea1e0b1c6e65df8873c3d6a5ab0f4760828  fw_adid.bin
6c7cc9d899d2a4e5b91b0f009aa6679498131adc27d220b96ec162536370a190  fw_adid_u03.bin
d9e164c90fd76f767bb7f5d5041a1e0f7b69096d7a408ff605920f909207ee14  fw_patch.bin
5f024e0b80802a30797d5afb3d06e3a8d02efe74d7ed0f7d4ee807093a579067  fw_patch_u03.bin
38d572126d767d2fe34b011076675195ddcb108c67dbaca0c14dbc9dc9617964  fw_patch_table.bin
0b1f6c1f1c845e3b0665a1bd1a5cd433d55bd24b79a86bbb6b06c8446453e1a1  fw_patch_table_u03.bin
EOF
echo "AIC8800 firmware in $out"
