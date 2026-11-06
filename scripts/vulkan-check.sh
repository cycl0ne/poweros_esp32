#!/bin/sh
# SPDX-License-Identifier: MIT
# Rung 8 of docs/facet-ir.md: the SPIR-V modules in
# src/disk/libs/facet/tests/spirv_reference.zig drawn with by every Vulkan
# driver this machine has, and every pixel held against the arithmetic the
# rest of the ladder holds facet to.
#
# spirv-check.sh says Khronos' validator takes the modules. That is not
# the same as a driver reading them as facet means them: a Location on the
# wrong variable, an execution mode left out, or an interface facet alone
# agrees with would pass the validator and draw the wrong picture. This
# makes a real pipeline out of them and looks at what comes out.
#
# It is a script and not a build step for the same reason spirv-check.sh
# is: a machine with no Vulkan driver, no glslc and no C compiler must
# still be able to build PowerOS.
#
#   sh scripts/vulkan-check.sh            check, and say what came out
#   sh scripts/vulkan-check.sh /tmp/shots the pictures as .ppm as well
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
reference="$root/src/disk/libs/facet/tests/spirv_reference.zig"
pictures="${1:-}"

for tool in cc glslc; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "$tool is not here: nothing drawn." >&2
        echo "cc is in any compiler package; glslc is in shaderc on Arch, glslc on Debian." >&2
        exit 0
    fi
done

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# Whether a program against libvulkan builds at all, which is the test for
# the headers and the loader both. A machine without them is skipped, not
# failed.
cat > "$out/probe.c" <<'C'
#include <vulkan/vulkan.h>
int main(void) { return (int)sizeof(VkInstance) - (int)sizeof(VkInstance); }
C
if ! cc -o "$out/probe" "$out/probe.c" -lvulkan > "$out/probe.log" 2>&1; then
    echo "vulkan.h and libvulkan are not both here: nothing drawn." >&2
    echo "They are in vulkan-headers and vulkan-icd-loader on Arch," >&2
    echo "libvulkan-dev on Debian." >&2
    exit 0
fi

# The modules out of the reference arrays, as spirv-check.sh reads them.
python3 -I - "$reference" "$out" <<'PY'
import re, struct, sys
text = open(sys.argv[1], encoding="utf-8").read()
for name, body in re.findall(r"pub const (\w+) = \[_\]u32\{(.*?)\};", text, re.S):
    words = [int(w, 16) for w in re.findall(r"0x([0-9A-Fa-f]{8})", body)]
    if not words:
        continue
    with open("%s/%s.spv" % (sys.argv[2], name), "wb") as file:
        file.write(struct.pack("<%dI" % len(words), *words))
PY

for module in min_flat min_interp min_scaled min_vert min_tex min_texmod; do
    if [ ! -e "$out/$module.spv" ]; then
        echo "$module is not in $reference" >&2
        exit 1
    fi
done

# The vertex shaders for the fragment modules whose varyings facet's own
# vertex module does not hand on. There are two because they disagree
# about location 0: the sampler modules read a vec2 coordinate where the
# colour ones read a vec4 colour, and one shader cannot write both.
glslc -fshader-stage=vert -o "$out/own_vert.spv" "$root/scripts/vulkan-check.vert"
glslc -fshader-stage=vert -o "$out/uv_vert.spv" "$root/scripts/vulkan-check-uv.vert"

cc -O2 -Wall -Wextra -o "$out/vulkan-check" "$root/scripts/vulkan-check.c" -lvulkan

if [ -n "$pictures" ]; then
    mkdir -p "$pictures"
    "$out/vulkan-check" "$out" -o "$pictures"
    echo "The pictures are in $pictures."
else
    "$out/vulkan-check" "$out"
fi
