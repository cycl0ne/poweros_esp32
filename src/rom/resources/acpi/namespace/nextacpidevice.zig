// SPDX-License-Identifier: MPL-2.0
//! NextAcpiDevice: the namespace's devices gone through, all of them or
//! those of one identity.

const sdk = @import("sdk");
const acpi = sdk.resources.acpi;
const AcpiBase = @import("../acpi_base.zig").AcpiBase;
const _namespace = @import("_namespace.zig");
const Node = _namespace.Node;
const object = @import("../object/_object.zig");
const Object = object.Object;

/// The device after `old` whose identity or compatible identity is `id`.
///
/// SYNOPSIS:
/// ```zig
/// fn NextAcpiDevice(ab: *AcpiBase, old: ?*acpi.AcpiNode, id: ?[*:0]const u8) ?*acpi.AcpiNode
/// ```
///
/// SINCE: 1.0. LVO -8.
///
/// INPUTS:
/// - `old` - the device the last call answered, or any other node; null
///   to start at the beginning.
/// - `id` - the identity wanted, as the firmware writes it: a device's
///   hardware identity ("PNP0C0C", "AMDI0030", "ACPI0007") or one it is
///   compatible with; null for every device.
///
/// RESULT:
/// The next device in the namespace's order, or null after the last.
///
/// BEHAVIOR:
/// The namespace's order is the order the names were defined in, each
/// name followed by those inside it: `\_SB`, then its first device, the
/// devices inside that one, then its second device. A device is a name
/// that holds a Device; processors, thermal zones and power resources
/// are not.
///
/// Its identity is its `_HID`, and the identities it is compatible with
/// its `_CID`: a string, the integer the source's `EisaId ("PNP0C0C")`
/// makes, or a package of either. `id` is matched against each exactly,
/// as text, upper and lower case being different.
///
/// CONTEXT:
/// - Waits: for the namespace, while a method changes it.
/// - Interrupts: no.
/// - Locks: takes the namespace, shared with other readers.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The node is the resource's and stays where it is for as long as the
/// system runs. `id` is the caller's, read during the call.
///
/// NOTES:
/// Whether a device is there at all is its `_STA`'s to say, which this
/// call does not ask: it goes through what the firmware describes.
///
/// BUGS:
/// An identity the firmware gives as a method, which answers it only when
/// run, is not read: the device is not found by it.
///
/// SEE ALSO:
/// `FindAcpiNode`
///
/// EXAMPLES:
/// ```zig
/// var button: ?*acpi.AcpiNode = null;
/// while (ab.NextAcpiDevice(button, "PNP0C0C")) |found| : (button = found) {
///     // a power button the firmware describes
/// }
/// ```
pub fn NextAcpiDevice(ab: *AcpiBase, old: ?*acpi.AcpiNode, id: ?[*:0]const u8) ?*acpi.AcpiNode {
    ab.machine.lock(ab, true);
    defer ab.machine.unlock(ab);
    const root = ab.root orelse return null;
    const from: *Node = if (old) |given| @ptrCast(@alignCast(given)) else root;
    var at = _namespace.next(root, from);
    while (at) |node| : (at = _namespace.next(root, node)) {
        if (node.kind() != .device) continue;
        if (id) |wanted| {
            if (!identifies(node, wanted)) continue;
        }
        return @ptrCast(node);
    }
    return null;
}

/// Whether `device`'s identity, or one it is compatible with, is `id`.
fn identifies(device: *Node, id: [*:0]const u8) bool {
    if (_namespace.child(device, _namespace.nameOf("_HID"))) |hid| {
        if (matches(_namespace.target(hid).object, id)) return true;
    }
    const cid = _namespace.child(device, _namespace.nameOf("_CID")) orelse return false;
    const held = _namespace.target(cid).object orelse return false;
    switch (held.value) {
        .package => |package| {
            for (package.elements[0..package.count]) |element| {
                if (matches(element, id)) return true;
            }
            return false;
        },
        else => return matches(held, id),
    }
}

/// Whether `held` is the identity `id`: a string of the same text, or an
/// EISA identity whose text it is.
fn matches(maybe: ?*Object, id: [*:0]const u8) bool {
    const held = maybe orelse return false;
    switch (held.value) {
        .string => |text| return same(text.slice(), id),
        .integer => |value| {
            var text: [8]u8 = undefined;
            if (!object.eisaText(value, &text)) return false;
            return same(text[0..7], id);
        },
        else => return false,
    }
}

fn same(text: []const u8, id: [*:0]const u8) bool {
    for (text, 0..) |char, index| {
        if (id[index] != char) return false;
    }
    return id[text.len] == 0;
}

// --- tests ------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;
const testmachine = @import("../tests/machine.zig");
const builder = @import("../tests/builder.zig");
const load = @import("../aml/load.zig");

test "devices gone through in order, by an identity of either form, the lock given back" {
    var test_machine: testmachine.TestMachine = .{};
    const ab = test_machine.base();
    try testing.expect(_namespace.make(ab));
    defer _namespace.discard(ab);
    var table = builder.Table.init(testing.allocator, "DSDT", 2);
    defer table.deinit();
    try table.scope("\\_SB_", struct {
        fn body(sb: *builder.Table) anyerror!void {
            try sb.device("PCI0", struct {
                fn body(pci: *builder.Table) anyerror!void {
                    try pci.nameInteger("_HID", 0x080AD041); // EisaId ("PNP0A08")
                    try pci.nameInteger("_CID", 0x030AD041); // EisaId ("PNP0A03")
                    try pci.device("PWRB", struct {
                        fn body(button: *builder.Table) anyerror!void {
                            try button.nameText("_HID", "PNP0C0C");
                        }
                    }.body);
                }
            }.body);
            try sb.device("GPIO", struct {
                fn body(gpio: *builder.Table) anyerror!void {
                    try gpio.nameText("_HID", "AMDI0030");
                    try gpio.nameOf("_CID", struct {
                        fn data(cid: *builder.Table) anyerror!void {
                            try cid.packageOf(2, struct {
                                fn elements(list: *builder.Table) anyerror!void {
                                    try list.string("AMDIFFFF");
                                    try list.integer(0x0C0CD041); // EisaId ("PNP0C0C")
                                }
                            }.elements);
                        }
                    }.data);
                }
            }.body);
            try sb.thermalZone("TZ01", struct {
                fn body(_: *builder.Table) anyerror!void {}
            }.body);
        }
    }.body);
    _ = load.loadTable(ab, .{ .code = try table.finish(), .index = 1 });

    var names: [8]u32 = undefined;
    var count: usize = 0;
    var at: ?*acpi.AcpiNode = null;
    while (NextAcpiDevice(ab, at, null)) |found| : (at = found) {
        const node: *Node = @ptrCast(@alignCast(found));
        names[count] = node.name;
        count += 1;
    }
    try testing.expectEqualSlices(u32, &.{
        _namespace.nameOf("_SB"),  _namespace.nameOf("PCI0"), _namespace.nameOf("PWRB"),
        _namespace.nameOf("GPIO"), _namespace.nameOf("_TZ"),
    }, names[0..count]);

    const pci = NextAcpiDevice(ab, null, "PNP0A08") orelse return error.NotFound;
    try testing.expectEqual(pci, NextAcpiDevice(ab, null, "PNP0A03").?);
    // The button, by its string, then the GPIO controller compatible with
    // it by the package's EISA identity.
    const button = NextAcpiDevice(ab, null, "PNP0C0C") orelse return error.NotFound;
    try testing.expectEqual(_namespace.nameOf("PWRB"), @as(*Node, @ptrCast(@alignCast(button))).name);
    const gpio = NextAcpiDevice(ab, button, "PNP0C0C") orelse return error.NotFound;
    try testing.expectEqual(_namespace.nameOf("GPIO"), @as(*Node, @ptrCast(@alignCast(gpio))).name);
    try testing.expectEqual(@as(?*acpi.AcpiNode, null), NextAcpiDevice(ab, gpio, "PNP0C0C"));
    try testing.expectEqual(gpio, NextAcpiDevice(ab, null, "AMDIFFFF").?);
    try testing.expectEqual(@as(?*acpi.AcpiNode, null), NextAcpiDevice(ab, null, "pnp0c0c"));
    try testing.expectEqual(@as(?*acpi.AcpiNode, null), NextAcpiDevice(ab, null, "PNP0C0"));
    try testing.expectEqual(@as(i32, 0), test_machine.held);
}
