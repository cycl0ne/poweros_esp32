#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Fetch the firmware an AMD graphics device's video decoder runs, and the
# table of contents its security processor is given before it loads it,
# as linux-firmware ships them, with AMD's licence for them - each at a
# pinned commit and checked against its sha256. Nothing of it is
# committed: it lands in toolchain/amdgpu, which the build looks for;
# without it the x86-64 disk has no DEVS:firmware/amdgpu/ and
# amdgpu.resource loads no firmware.
#
# The files are named for the block that runs them, as the device's table
# gives its version: vcn_4_0_2 for the video decoder 4.0.2, psp_13_0_4 for
# the security processor 13.0.4.
set -eu

commit=a4748ebfe8e9ed5c8df30d5be849eb2e3fb415da
from="https://gitlab.com/kernel-firmware/linux-firmware/-/raw/$commit"

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/toolchain/amdgpu"
mkdir -p "$out"
cd "$out"

curl -sSfL -o vcn_4_0_2.bin "$from/amdgpu/vcn_4_0_2.bin"
curl -sSfL -o psp_13_0_4_toc.bin "$from/amdgpu/psp_13_0_4_toc.bin"
curl -sSfL -o LICENSE.amdgpu "$from/LICENSES/LICENSE.amdgpu"

sha256sum -c --quiet <<'SUMS'
5633a5212d41e1f3932c1e7e630b1f2c8c4d27bc53ce8149c3be75d1d832053c  vcn_4_0_2.bin
11e3529d748e2b6b204681183360a6ead80665b8deda996dfcf35973f789fc3d  psp_13_0_4_toc.bin
572872598565dc3513470de971a32bf9db301f47afeef3636345eadae33b2eee  LICENSE.amdgpu
SUMS
echo "AMD graphics firmware in $out"
