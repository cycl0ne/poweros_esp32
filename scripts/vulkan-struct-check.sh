#!/bin/sh
# SPDX-License-Identifier: MIT
# facet's physical-device structures held against Vulkan's own, member for
# member, by reading the installed vulkan_core.h.
#
# docs/facet-vulkan10.md's numbers table carries a warning: the Vulkan
# column "is not in this tree - there is no vk.xml and no vulkan_core.h
# anywhere under it, so the right-hand column is quoted from Khronos'
# published spec and cannot be checked offline". That is true of the tree
# and was taken to mean the numbers could not be checked at all. It only
# means they cannot be checked *from the tree*: this machine has the
# registry header installed, because scripts/vulkan-check.sh compiles
# against it, and the header is the registry's own output. So the claim
# that PhysicalDeviceLimits now has Vulkan's 106 members in Vulkan's order
# is a claim this can settle, and it settles it every time it is run.
#
# What it compares, for VkPhysicalDeviceLimits, VkPhysicalDeviceFeatures,
# VkPhysicalDeviceSparseProperties and VkPhysicalDeviceProperties:
#
#   - the number of members, and that each facet field sits at the same
#     position in the declaration as its Vulkan member
#   - the names, which must agree once underscores are dropped and the
#     case forgotten: maxImageDimension2D is max_image_dimension_2d
#   - the types, so that a VkBool32 is a u32 and not a Zig bool - one byte
#     against four is how facet's features structure came to be 49 bytes
#     where Vulkan's is 220
#   - the array lengths, against the header's own VK_UUID_SIZE and
#     VK_MAX_PHYSICAL_DEVICE_NAME_SIZE
#
# What it does not compare is the *values*. A structure of the right shape
# can still report a limit the device cannot meet, and that is what
# docs/facet-vulkan10.md's items 17 to 30 are for. This says the shape is
# right, which is what the reshape promised.
#
# It is a script and not a build step for the same reason spirv-check.sh
# and vulkan-check.sh are: a machine with no Vulkan headers must still be
# able to build PowerOS. The build's own gate is the test block in
# sdk/libs/facet/facet.zig, which holds the member counts and the sizes
# without needing the header.
#
# A check that passes is worth nothing on its own: one whose loop never
# runs passes too. --prove tells the comparison five lies - a field
# dropped, two swapped, a type narrowed, an array shortened, and align(4)
# left off a 64-bit member - and every one has to come back caught.
#
#   sh scripts/vulkan-struct-check.sh          compare, and say what differs
#   sh scripts/vulkan-struct-check.sh --prove  compare, then show it can fail
#   sh scripts/vulkan-struct-check.sh /path/to/vulkan_core.h
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
header=""
prove=""
for arg in "$@"; do
    case $arg in
        --prove) prove=--prove ;;
        *) header=$arg ;;
    esac
done

if ! command -v python3 > /dev/null 2>&1; then
    echo "python3 is not here: nothing compared." >&2
    exit 0
fi

if [ -z "$header" ]; then
    for try in /usr/include/vulkan/vulkan_core.h \
               /usr/local/include/vulkan/vulkan_core.h \
               "${VULKAN_SDK:-/nonexistent}/include/vulkan/vulkan_core.h"; do
        if [ -r "$try" ]; then header=$try; break; fi
    done
fi

if [ -z "$header" ] || [ ! -r "$header" ]; then
    echo "No vulkan_core.h found: nothing compared." >&2
    echo "It is in the vulkan-headers package on Arch and in" >&2
    echo "libvulkan-dev on Debian, or pass the path as the argument." >&2
    exit 0
fi

exec python3 -I "$root/scripts/vulkan-struct-check.py" ${prove:+$prove} \
    "$header" "$root/sdk/libs/facet/facet.zig"
