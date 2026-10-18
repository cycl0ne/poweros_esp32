// SPDX-License-Identifier: MIT
//! Host tests of PCIInfo's names: a class code's, from the table made
//! of the PCI ID Repository's classes (classes.zig), and a vendor's, a
//! device's and a subsystem's, looked up in a pci.ids text (ids.zig).

const std = @import("std");
const classes = @import("../classes.zig");
const Ids = @import("../ids.zig").Ids;

const testing = std.testing;

fn expectName(expected: ?[]const u8, actual: ?[*:0]const u8) !void {
    if (expected) |text| {
        try testing.expectEqualStrings(text, std.mem.span(actual.?));
    } else try testing.expectEqual(@as(?[*:0]const u8, null), actual);
}

test "a class code is named by its class, its subclass and its programming interface" {
    const xhci = classes.describe(0x0C0330);
    try expectName("Serial bus controller", xhci.class);
    try expectName("USB controller", xhci.subclass);
    try expectName("XHCI", xhci.interface);
    const nvme = classes.describe(0x010802);
    try expectName("Non-Volatile memory controller", nvme.subclass);
    try expectName("NVM Express", nvme.interface);
    const bridge = classes.describe(0x060400);
    try expectName("PCI bridge", bridge.subclass);
    // A subclass the table does not have, of a class it does.
    const odd = classes.describe(0x0C7700);
    try expectName("Serial bus controller", odd.class);
    try expectName(null, odd.subclass);
    try expectName(null, classes.describe(0xEE0000).class);
}

const sample =
    "# a comment\n" ++
    "\n" ++
    "1106  VIA Technologies, Inc.\n" ++
    "\t3483  VL805/806 xHCI USB 3.0 Controller\n" ++
    "\t\t1106 3483  VL805/806 xHCI USB 3.0 Controller\n" ++
    "1344  Micron Technology Inc\n" ++
    "# its devices\n" ++
    "\t5416  2500 NVMe SSD\r\n" ++
    "\t\t1344 1100  Crucial P3 Plus\n" ++
    "\t5417  something else\n" ++
    "1b36  Red Hat, Inc.\n" ++
    "C 0c  Serial bus controller\n" ++
    "\t03  USB controller\n";

test "pci.ids: a vendor's name, its device's, and a subsystem's, as the list has them" {
    const ids = Ids{ .text = sample };
    try testing.expectEqualStrings("VIA Technologies, Inc.", ids.vendor(0x1106).?);
    try testing.expectEqualStrings("VL805/806 xHCI USB 3.0 Controller", ids.device(0x1106, 0x3483).?);
    try testing.expectEqualStrings("2500 NVMe SSD", ids.device(0x1344, 0x5416).?);
    try testing.expectEqualStrings("Crucial P3 Plus", ids.subsystem(0x1344, 0x5416, 0x1344, 0x1100).?);
    try testing.expectEqualStrings("something else", ids.device(0x1344, 0x5417).?);
    try testing.expectEqualStrings("Red Hat, Inc.", ids.vendor(0x1b36).?);
    // None past the vendor's own devices, nor past the vendors.
    try testing.expectEqual(@as(?[]const u8, null), ids.device(0x1106, 0x5416));
    try testing.expectEqual(@as(?[]const u8, null), ids.subsystem(0x1344, 0x5417, 0x1344, 0x1100));
    try testing.expectEqual(@as(?[]const u8, null), ids.device(0x1b36, 0x0003));
    try testing.expectEqual(@as(?[]const u8, null), ids.vendor(0x0c03));
    try testing.expectEqual(@as(?[]const u8, null), ids.vendor(0x8086));
}
