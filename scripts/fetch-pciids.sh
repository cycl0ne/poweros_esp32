#!/bin/sh
# SPDX-License-Identifier: MIT
# Fetch the PCI ID Repository's list (pci.ids, https://pci-ids.ucw.cz),
# which C:PCIInfo names vendors, devices and subsystems from as
# DEVS:pci.ids on the RISC-V disk. The host's copy is taken where it has
# one (hwdata, pciutils); otherwise the repository's current list is
# downloaded. Nothing of it is committed: it lands in toolchain/pciids,
# which the build looks for; without it PCIInfo names functions by
# their class alone. The list is the repository's, under the
# GPL-2.0-or-later or the 3-clause BSD licence (its header says so).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/toolchain/pciids"
mkdir -p "$out"

for host in /usr/share/hwdata/pci.ids /usr/share/misc/pci.ids /usr/share/pci.ids; do
    if [ -f "$host" ]; then
        cp "$host" "$out/pci.ids"
        echo "pci.ids from $host in $out/pci.ids"
        exit 0
    fi
done
curl -sSfL -o "$out/pci.ids" "https://pci-ids.ucw.cz/v2.2/pci.ids"
grep -q '^C 0c  Serial bus controller' "$out/pci.ids"
echo "pci.ids in $out/pci.ids"
