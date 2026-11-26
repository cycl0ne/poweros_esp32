#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Fetch the firmware an AMD graphics device's video decoder, display
# controller and graphics block run, and the table of contents its
# security processor is given before it loads them, as linux-firmware
# ships them, with AMD's licence for them - each at a pinned commit and
# checked against its sha256. Nothing of it is
# committed: it lands in toolchain/amdgpu, which the build looks for;
# without it the x86-64 disk has no DEVS:firmware/amdgpu/ and
# amdgpu.resource loads no firmware.
#
# The files are named for the block that runs them, as the device's table
# gives its version: vcn_4_0_2 for the video decoder 4.0.2, dcn_3_1_4 for
# the display engine 3.1.4 (its controller's, _dmcub), psp_13_0_4 for the
# security processor 13.0.4, gc_11_0_1 for the graphics block 11.0.1 (its
# command processor's _pfp, _me and _mec, its RLC's, its scheduler's two
# pipes' _mes_2 and _mes1, its power controller's _imu) and sdma_6_0_1
# for its DMA engine 6.0.1.
set -eu

commit=a4748ebfe8e9ed5c8df30d5be849eb2e3fb415da
from="https://gitlab.com/kernel-firmware/linux-firmware/-/raw/$commit"

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/toolchain/amdgpu"
mkdir -p "$out"
cd "$out"

curl -sSfL -o vcn_4_0_2.bin "$from/amdgpu/vcn_4_0_2.bin"
curl -sSfL -o psp_13_0_4_toc.bin "$from/amdgpu/psp_13_0_4_toc.bin"
curl -sSfL -o dcn_3_1_4_dmcub.bin "$from/amdgpu/dcn_3_1_4_dmcub.bin"
for part in pfp me mec rlc mes_2 mes1 imu; do
    curl -sSfL -o "gc_11_0_1_$part.bin" "$from/amdgpu/gc_11_0_1_$part.bin"
done
curl -sSfL -o sdma_6_0_1.bin "$from/amdgpu/sdma_6_0_1.bin"
curl -sSfL -o LICENSE.amdgpu "$from/LICENSES/LICENSE.amdgpu"

sha256sum -c --quiet <<'SUMS'
5633a5212d41e1f3932c1e7e630b1f2c8c4d27bc53ce8149c3be75d1d832053c  vcn_4_0_2.bin
11e3529d748e2b6b204681183360a6ead80665b8deda996dfcf35973f789fc3d  psp_13_0_4_toc.bin
454d3eb73045d0a46f9014c42c76df9e65ae9e5da45b8c331584443fe49a8516  dcn_3_1_4_dmcub.bin
449c72cae1c57838185197ad4003aeee7ccbdba892a28bb2624d9e85f57a2df1  gc_11_0_1_pfp.bin
62c5e749ad848941e5d8b85f66eeb2b969ee82919724dfd94dbf6e354be8befc  gc_11_0_1_me.bin
b0a4006b3934adc1d7996e6d901206dea37203b4839debe4a5ed4e393a615cbb  gc_11_0_1_mec.bin
5f07dc1f0a75ecd9cb56d805ea869184a50ed9e43d811ebf833b8906534650ef  gc_11_0_1_rlc.bin
962f56c7e661479e3cabf89c1fcd6344f10cfa8b8d1f672fc445bb21414c1392  gc_11_0_1_mes_2.bin
3a8b60ea88b7adbbc71da0ddee0370d5d65c1d66186fd4f4ba9d16a854b24db8  gc_11_0_1_mes1.bin
ac71f4eec713fc35b4a1fe27531e3eb04edd81eeac2cef64df01ac50d8510805  gc_11_0_1_imu.bin
708c2c2c45262c98ebe8e34e32c3f1ce8eb5b007bab560c9ea9b576a8e4d6768  sdma_6_0_1.bin
572872598565dc3513470de971a32bf9db301f47afeef3636345eadae33b2eee  LICENSE.amdgpu
SUMS
echo "AMD graphics firmware in $out"
