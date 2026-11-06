#!/bin/sh
# SPDX-License-Identifier: MIT
# The SPIR-V modules in src/disk/libs/facet/tests/spirv_reference.zig and
# src/disk/libs/facet/driver/v3d/glslc_reference.zig, handed back to
# Khronos' validator.
#
# Those arrays are what `spirv.Emit` is held to, word for word, by
# `./zig build test`. That comparison is only worth what the arrays are
# worth, which is what this checks: every one of them is still a module
# spirv-val accepts, under Vulkan 1.0. Together the two say that what
# facet emits is valid SPIR-V, without the build ever needing a tool that
# may not be installed - which is why this is a script and not a build
# step.
#
# With -d it also disassembles each one, which is the quickest way to see
# what a module actually says.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
reference="$root/src/disk/libs/facet/tests/spirv_reference.zig"
# glslc's own module sits in the V3D driver's module, which is the only
# place compile.zig's tests can import it from.
glslc="$root/src/disk/libs/facet/driver/v3d/glslc_reference.zig"
show=no
[ "${1:-}" = "-d" ] && show=yes

if ! command -v spirv-val > /dev/null 2>&1; then
    echo "spirv-val is not here: nothing checked." >&2
    echo "It is in the spirv-tools package on Arch and on Debian." >&2
    exit 0
fi

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

python3 -I - "$out" "$reference" "$glslc" <<'PY'
import re, struct, sys
for source in sys.argv[2:]:
    text = open(source, encoding="utf-8").read()
    for name, body in re.findall(r"pub const (\w+) = \[_\]u32\{(.*?)\};", text, re.S):
        words = [int(w, 16) for w in re.findall(r"0x([0-9A-Fa-f]{8})", body)]
        if not words:
            continue
        with open("%s/%s.spv" % (sys.argv[1], name), "wb") as file:
            file.write(struct.pack("<%dI" % len(words), *words))
        print("%s %d" % (name, len(words)))
PY

count=0
bad=0
for module in "$out"/*.spv; do
    [ -e "$module" ] || continue
    name=$(basename "$module" .spv)
    words=$(( $(wc -c < "$module") / 4 ))
    count=$((count + 1))
    if spirv-val --target-env vulkan1.0 "$module" 2>&1; then
        printf '%-12s %4d words  valid\n' "$name" "$words"
    else
        printf '%-12s %4d words  REFUSED\n' "$name" "$words"
        bad=$((bad + 1))
    fi
    [ "$show" = yes ] && spirv-dis --no-header "$module"
done

if [ "$count" -eq 0 ]; then
    echo "no modules found in $reference" >&2
    exit 1
fi
echo "$count modules, $bad refused."
[ "$bad" -eq 0 ]
