// SPDX-License-Identifier: MPL-2.0
//! FindAcpiNode: a name in the namespace found by its path.

const sdk = @import("sdk");
const acpi = sdk.resources.acpi;
const AcpiBase = @import("../acpi_base.zig").AcpiBase;
const _namespace = @import("_namespace.zig");
const Node = _namespace.Node;

/// The name at `path` from `scope`.
///
/// SYNOPSIS:
/// ```zig
/// fn FindAcpiNode(ab: *AcpiBase, scope: ?*acpi.AcpiNode, path: [*:0]const u8) ?*acpi.AcpiNode
/// ```
///
/// SINCE: 1.0. LVO -4.
///
/// INPUTS:
/// - `scope` - the name the path starts from; null for the root.
/// - `path` - names of up to four characters, separated by dots: from
///   the root where it starts with `\` ("\\_SB.PCI0"), from as many
///   scopes above `scope` as it has `^` in front ("^_PRT"), from `scope`
///   itself otherwise ("PCI0._HID"). A name shorter than four characters
///   is filled out with `_`, as the bytecode writes it: "_SB" is "_SB_".
///   Lower-case letters are taken as upper-case.
///
/// RESULT:
/// The node, or null where the path names nothing - one of its names is
/// not there, it goes above the root - or is not a path.
///
/// BEHAVIOR:
/// Every name of the path must be there, each among the children of the
/// one before. A single name is looked for in `scope` alone, never in the
/// scopes above it as the bytecode's own references are: the device's
/// `_HID` is the device's, not its parent's. A name that is another name
/// for a node (an Alias) answers that node. "\\" alone is the root.
///
/// CONTEXT:
/// - Waits: for the namespace, while a method changes it.
/// - Interrupts: no.
/// - Locks: takes the namespace, shared with other readers.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The node is the resource's and stays where it is for as long as the
/// system runs.
///
/// NOTES:
/// On a machine whose firmware has no tables, or before any are loaded,
/// the namespace has only the names it starts with: `\_GPE`, `\_PR`,
/// `\_SB`, `\_SI`, `\_TZ`, `\_REV`, `\_OS`, `\_GL` and `\_OSI`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NextAcpiDevice`
///
/// EXAMPLES:
/// ```zig
/// const pci = ab.FindAcpiNode(null, "\\_SB.PCI0") orelse return;
/// const routing = ab.FindAcpiNode(pci, "_PRT");
/// ```
pub fn FindAcpiNode(ab: *AcpiBase, scope: ?*acpi.AcpiNode, path: [*:0]const u8) ?*acpi.AcpiNode {
    var text: _namespace.TextPath = undefined;
    if (!_namespace.parseText(path, &text)) return null;
    ab.machine.lock(ab, true);
    defer ab.machine.unlock(ab);
    const root = ab.root orelse return null;
    const from: *Node = if (scope) |given| @ptrCast(@alignCast(given)) else root;
    return @ptrCast(_namespace.find(ab, from, text.path, .exact) orelse return null);
}

// --- tests ------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;
const testmachine = @import("../tests/machine.zig");
const builder = @import("../tests/builder.zig");
const load = @import("../aml/load.zig");

test "a name found from the root, from a scope and from above one, the lock given back" {
    var test_machine: testmachine.TestMachine = .{};
    const ab = test_machine.base();
    try testing.expect(_namespace.make(ab));
    defer _namespace.discard(ab);
    var table = builder.Table.init(testing.allocator, "DSDT", 2);
    defer table.deinit();
    try table.scope("\\_SB_", struct {
        fn body(inner: *builder.Table) anyerror!void {
            try inner.device("PCI0", struct {
                fn body(device: *builder.Table) anyerror!void {
                    try device.nameInteger("_ADR", 0);
                    try device.device("LPC0", struct {
                        fn body(lpc: *builder.Table) anyerror!void {
                            try lpc.nameInteger("_ADR", 0x140003);
                        }
                    }.body);
                }
            }.body);
        }
    }.body);
    const code = try table.finish();
    _ = load.loadTable(ab, .{ .code = code, .index = 1 });

    const pci = FindAcpiNode(ab, null, "\\_SB.PCI0") orelse return error.NotFound;
    const lpc = FindAcpiNode(ab, pci, "LPC0") orelse return error.NotFound;
    try testing.expectEqual(lpc, FindAcpiNode(ab, null, "\\_sb_.pci0.lpc0").?);
    try testing.expect(FindAcpiNode(ab, lpc, "^_ADR") != null);
    try testing.expect(FindAcpiNode(ab, lpc, "^^PCI0") != null);
    // A single name is the scope's own, never looked for above it.
    try testing.expectEqual(@as(?*acpi.AcpiNode, null), FindAcpiNode(ab, lpc, "PCI0"));
    try testing.expectEqual(@as(?*acpi.AcpiNode, null), FindAcpiNode(ab, null, "\\_SB.PCI0.NONE"));
    try testing.expectEqual(@as(?*acpi.AcpiNode, null), FindAcpiNode(ab, null, "\\_SB.TOOLONG"));
    try testing.expectEqual(@as(?*acpi.AcpiNode, null), FindAcpiNode(ab, null, "^_SB"));
    try testing.expectEqual(@as(?*acpi.AcpiNode, @ptrCast(ab.root.?)), FindAcpiNode(ab, null, "\\"));
    try testing.expectEqual(@as(i32, 0), test_machine.held);
}
