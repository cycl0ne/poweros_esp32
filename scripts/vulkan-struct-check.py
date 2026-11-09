#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""facet's physical-device structures against Vulkan's own, member for member.

Driven by vulkan-struct-check.sh, which says why this exists. Reads the
installed vulkan_core.h and sdk/libs/facet/facet.zig and compares the four
structures a physical device is described by. Nothing here knows a member
name by heart: both lists are read, and the comparison is positional.

A name matches when the two spellings agree once underscores are dropped
and the case is forgotten - maxImageDimension2D and max_image_dimension_2d
both reduce to maximagedimension2d. That lets facet.zig keep readable Zig
names without this script holding a table of exceptions it would have to be
told about.

  --prove tells the comparison five lies and expects each to come back
  caught, which is the only way to know the loop ran.
"""

import os
import re
import sys

# The structures compared, Vulkan's name to facet's.
PAIRS = [
    ("VkPhysicalDeviceLimits", "PhysicalDeviceLimits"),
    ("VkPhysicalDeviceFeatures", "PhysicalDeviceFeatures"),
    ("VkPhysicalDeviceSparseProperties", "PhysicalDeviceSparseProperties"),
    ("VkPhysicalDeviceProperties", "PhysicalDeviceProperties"),
]

# What a C type may be written as in a Zig extern struct. VkBool32 is a
# uint32_t and must stay 32 bits wide: a Zig bool is one byte, which is how
# facet's own features structure came to be 49 bytes where Vulkan's is 220.
ALLOWED = {
    "uint32_t": ("u32",),
    "int32_t": ("i32",),
    "uint8_t": ("u8",),
    "char": ("u8",),
    "float": ("f32",),
    "VkBool32": ("u32", "Bool32"),
    "VkDeviceSize": ("u64", "DeviceSize"),
    "VkSampleCountFlags": ("u32", "SampleCountFlags"),
    "size_t": ("usize",),
    "VkPhysicalDeviceType": ("PhysicalDeviceType",),
    "VkPhysicalDeviceLimits": ("PhysicalDeviceLimits",),
    "VkPhysicalDeviceSparseProperties": ("PhysicalDeviceSparseProperties",),
}

# A C array bound to the Zig length it must have. The two sizes are read
# out of the header rather than written here.
DEFINES = ("VK_MAX_PHYSICAL_DEVICE_NAME_SIZE", "VK_UUID_SIZE")


def key(name):
    """The spelling-independent name: underscores dropped, case forgotten."""
    return name.replace("_", "").lower()


class Member:
    def __init__(self, name, type_name, count):
        self.name = name
        self.type_name = type_name
        self.count = count          # the array length as written, or None
        self.aligned = None        # an explicit align(N), or None

    def __repr__(self):
        return "%s %s%s" % (self.type_name, self.name,
                            "[%s]" % self.count if self.count else "")


def c_structs(path):
    """Every member of every structure in PAIRS, from the C header."""
    text = open(path, encoding="utf-8", errors="replace").read()
    defines = {}
    for name in DEFINES:
        found = re.search(r"#define\s+%s\s+(\d+)U?" % name, text)
        if not found:
            raise SystemExit("%s does not define %s" % (path, name))
        defines[name] = int(found.group(1))

    out = {}
    for c_name, _ in PAIRS:
        block = re.search(r"typedef struct %s \{(.*?)\n\} %s;" % (c_name, c_name),
                          text, re.S)
        if not block:
            raise SystemExit("%s holds no struct %s" % (path, c_name))
        members = []
        for line in block.group(1).splitlines():
            line = line.strip()
            if not line or line.startswith("//") or line.startswith("/*"):
                continue
            form = re.match(
                r"^([A-Za-z_][A-Za-z0-9_]*(?:\s+[A-Za-z_][A-Za-z0-9_]*)*?)"
                r"\s+([A-Za-z_][A-Za-z0-9_]*)"
                r"\s*(?:\[\s*([A-Za-z0-9_]+)\s*\])?\s*;$", line)
            if not form:
                raise SystemExit("%s: cannot read %r" % (c_name, line))
            c_type, name, count = form.group(1), form.group(2), form.group(3)
            if count is not None and count in defines:
                count = defines[count]
            elif count is not None:
                count = int(count)
            members.append(Member(name, c_type, count))
        out[c_name] = members
    return out, defines


def zig_structs(path):
    """Every field of every structure in PAIRS, from facet.zig."""
    text = open(path, encoding="utf-8", errors="replace").read()
    out = {}
    for _, z_name in PAIRS:
        start = re.search(r"^pub const %s = extern struct \{$" % z_name,
                          text, re.M)
        if not start:
            # Reported as a disagreement rather than thrown, so that one run
            # says everything that is wrong instead of only the first thing.
            out[z_name] = None
            continue
        fields = []
        depth = 1
        for line in text[start.end():].splitlines():
            bare = line.strip()
            depth += line.count("{") - line.count("}")
            if depth == 0:
                break
            if not bare or bare.startswith("//"):
                continue
            # name: type, or name: type = default,
            form = re.match(r"^([a-z_][a-z0-9_]*)\s*:\s*([^=,]+?)\s*(?:=.*)?,$",
                            bare)
            if not form:
                continue
            name, z_type = form.group(1), form.group(2).strip()
            # `u64 align(4)` is one type here: every 64-bit field of this SDK
            # carries it, for the ESP32's stack (sdk/sdk.zig), so the
            # alignment is held apart and checked on its own below.
            aligned = None
            spelled = re.match(r"^(.*?)\s+align\((\d+)\)$", z_type)
            if spelled:
                z_type, aligned = spelled.group(1).strip(), int(spelled.group(2))
            count = None
            array = re.match(r"^\[\s*([^\]]+?)\s*\](.+)$", z_type)
            if array:
                count, z_type = array.group(1).strip(), array.group(2).strip()
            member = Member(name, z_type, count)
            member.aligned = aligned
            fields.append(member)
        out[z_name] = fields
    return out


def compare(c_all, z_all, defines, lie=None):
    """Every disagreement between the two, as a list of sentences."""
    wrong = []
    for c_name, z_name in PAIRS:
        c_members = list(c_all[c_name])
        if z_all[z_name] is None:
            wrong.append("facet.zig holds no `pub const %s = extern struct`, "
                         "where Vulkan has %s with %d members"
                         % (z_name, c_name, len(c_members)))
            continue
        z_fields = list(z_all[z_name])
        if lie == "count" and c_name == "VkPhysicalDeviceLimits":
            z_fields = z_fields[:-1]
        if lie == "order" and c_name == "VkPhysicalDeviceLimits" and len(z_fields) > 3:
            z_fields[1], z_fields[2] = z_fields[2], z_fields[1]
        if lie == "type" and c_name == "VkPhysicalDeviceLimits":
            z_fields = [Member(f.name, "u16" if i == 0 else f.type_name, f.count)
                        for i, f in enumerate(z_fields)]
        if lie == "align" and c_name == "VkPhysicalDeviceLimits":
            z_fields = [Member(f.name, f.type_name, f.count) for f in z_fields]
            for f, o in zip(z_fields, c_all[c_name]):
                f.aligned = None if o.type_name in ("VkDeviceSize", "size_t") else 4
        if lie == "length" and c_name == "VkPhysicalDeviceProperties":
            z_fields = [Member(f.name, f.type_name,
                               "7" if f.name == "device_name" else f.count)
                        for f in z_fields]

        if len(c_members) != len(z_fields):
            wrong.append("%s has %d fields where %s has %d members"
                         % (z_name, len(z_fields), c_name, len(c_members)))

        for i, c_member in enumerate(c_members):
            if i >= len(z_fields):
                wrong.append("%s: no field for %s's %s (member %d)"
                             % (z_name, c_name, c_member.name, i + 1))
                continue
            z_field = z_fields[i]
            if key(c_member.name) != key(z_field.name):
                wrong.append("%s member %d is %s where %s has %s"
                             % (c_name, i + 1, c_member.name, z_name, z_field.name))
                continue
            allowed = ALLOWED.get(c_member.type_name)
            if allowed is None:
                wrong.append("%s.%s: this script knows no Zig type for %s"
                             % (c_name, c_member.name, c_member.type_name))
            elif z_field.type_name not in allowed:
                wrong.append("%s.%s is %s where %s.%s is %s (wanted %s)"
                             % (c_name, c_member.name, c_member.type_name,
                                z_name, z_field.name, z_field.type_name,
                                " or ".join(allowed)))
            if c_member.type_name in ("VkDeviceSize", "size_t") and z_field.aligned != 4:
                wrong.append("%s.%s is 64 bits and does not say align(4), which "
                             "every 64-bit field of this SDK must (sdk/sdk.zig)"
                             % (z_name, z_field.name))
            if (c_member.count is None) != (z_field.count is None):
                wrong.append("%s.%s %s an array where %s.%s %s"
                             % (c_name, c_member.name,
                                "is" if c_member.count else "is not",
                                z_name, z_field.name,
                                "is" if z_field.count else "is not"))
            elif c_member.count is not None:
                named = {"MAX_PHYSICAL_DEVICE_NAME_SIZE":
                         defines["VK_MAX_PHYSICAL_DEVICE_NAME_SIZE"],
                         "UUID_SIZE": defines["VK_UUID_SIZE"]}
                asked = z_field.count
                length = named.get(asked)
                if length is None:
                    try:
                        length = int(asked)
                    except ValueError:
                        wrong.append("%s.%s: cannot read the length %r"
                                     % (z_name, z_field.name, asked))
                        continue
                if length != c_member.count:
                    wrong.append("%s.%s holds %d where %s.%s holds %d"
                                 % (z_name, z_field.name, length,
                                    c_name, c_member.name, c_member.count))
    return wrong


def main():
    args = sys.argv[1:]
    prove = "--prove" in args
    rest = [a for a in args if not a.startswith("--")]
    header = rest[0] if rest else "/usr/include/vulkan/vulkan_core.h"
    facet = rest[1] if len(rest) > 1 else None
    if facet is None:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        facet = os.path.join(root, "sdk", "libs", "facet", "facet.zig")

    c_all, defines = c_structs(header)
    z_all = zig_structs(facet)

    version = "?"
    found = re.search(r"#define\s+VK_HEADER_VERSION\s+(\d+)",
                      open(header, encoding="utf-8", errors="replace").read())
    if found:
        version = found.group(1)

    print("vulkan_core.h %s (VK_HEADER_VERSION %s)" % (header, version))
    for c_name, z_name in PAIRS:
        held = z_all[z_name]
        print("  %-34s %3d members   %-34s %s"
              % (c_name, len(c_all[c_name]), z_name,
                 "%3d fields" % len(held) if held is not None else "  absent"))

    wrong = compare(c_all, z_all, defines)
    if wrong:
        print("\n%d disagreement%s:" % (len(wrong), "" if len(wrong) == 1 else "s"))
        for line in wrong:
            print("  " + line)
        return 1
    print("\nEvery member, in order, with the right name, type and length.")

    if prove:
        print("\n--prove: five lies, each of which has to come back caught.")
        failed = False
        for lie, what in (("count", "a field dropped from the end of the limits"),
                          ("order", "two limits swapped"),
                          ("type", "a u32 limit narrowed to u16"),
                          ("length", "device_name shortened to 7 bytes"),
                          ("align", "align(4) dropped from the 64-bit limits")):
            caught = compare(c_all, z_all, defines, lie=lie)
            print("  %-44s %s" % (what, "caught: " + caught[0] if caught
                                  else "NOT CAUGHT - this check proves nothing"))
            if not caught:
                failed = True
        if failed:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
