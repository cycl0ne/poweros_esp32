// SPDX-License-Identifier: MPL-2.0
//! acpi.resource working as a whole, on the host: made from its ROM tag
//! on the ROM's exec, its memory exec's pool, its calls made through the
//! jump table. These tests are apart from acpi.zig because that file is
//! tools/acpicheck's root as well and holds nothing but the SDK; the
//! interpreter's own tests, which need no exec, are with its code.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const acpi = sdk.resources.acpi;

const acpi_base = @import("acpi_base.zig");
const acpi_init = @import("acpi_init.zig");
const AcpiBase = acpi_base.AcpiBase;
const namespace = @import("namespace/_namespace.zig");
const Node = namespace.Node;
const load = @import("aml/load.zig");
const builder = @import("tests/builder.zig");

const testing = std.testing;
const kexec = @import("../../libs/exec/exec.zig");

test {
    _ = @import("acpi.zig");
    _ = @import("acpi_lvo.zig");
    _ = @import("object/_object.zig");
    _ = @import("namespace/_namespace.zig");
    _ = @import("namespace/findacpinode.zig");
    _ = @import("namespace/nextacpidevice.zig");
    _ = @import("aml/_aml.zig");
    _ = @import("aml/opcodes.zig");
    _ = @import("aml/load.zig");
    _ = @import("tables/_tables.zig");
    _ = @import("interpreter/convert.zig");
    _ = @import("interpreter/store.zig");
    _ = @import("interpreter/operators.zig");
    _ = @import("region/_region.zig");
    _ = @import("tests/executor.zig");
    _ = @import("tests/fields.zig");
}

fn setUp() !*AcpiBase {
    try kexec.setUp();
    const made = kexec.InitResident(kexec.SysBase, &acpi_init.acpi_resource_tag, null) orelse return error.NoResource;
    return @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(made))));
}

/// The namespace given back name by name, so that a block it forgets is
/// a leak, then the pool, then the resource.
fn tearDown(ab: *AcpiBase) !void {
    namespace.discard(ab);
    ab.sys_base.DeletePool(ab.pool);
    kexec.RemResource(kexec.SysBase, @ptrCast(&ab.lib));
    kexec.freeLibraryMemory(kexec.SysBase, &ab.lib);
    try kexec.expectNoLeaks();
}

/// The resource as a program calls it, through its jump table.
fn call(ab: *AcpiBase) *sdk.interface.acpi.AcpiBase {
    return @ptrCast(ab);
}

test "made on a machine without the firmware's tables: the names it starts with, and nothing loaded" {
    const ab = try setUp();
    defer kexec.deinit();
    try testing.expect(ab.root != null);
    try testing.expectEqual(@as(u16, 0), ab.tables);
    try testing.expect(call(ab).FindAcpiNode(null, "\\_SB") != null);
    try testing.expect(call(ab).FindAcpiNode(null, "_OSI") != null);
    try testing.expect(call(ab).FindAcpiNode(null, "\\_SB.PCI0") == null);
    // \_SB and \_TZ are the only devices: the scopes the namespace has
    // from the start.
    const first = call(ab).NextAcpiDevice(null, null) orelse return error.NoDevice;
    try testing.expectEqual(namespace.nameOf("_SB"), @as(*Node, @ptrCast(@alignCast(first))).name);
    const second = call(ab).NextAcpiDevice(first, null) orelse return error.NoDevice;
    try testing.expectEqual(namespace.nameOf("_TZ"), @as(*Node, @ptrCast(@alignCast(second))).name);
    try testing.expect(call(ab).NextAcpiDevice(second, null) == null);
    try tearDown(ab);
}

test "a table loaded into exec's pool, its devices found through the jump table, all of it given back" {
    const ab = try setUp();
    defer kexec.deinit();
    var table = builder.Table.init(testing.allocator, "DSDT", 2);
    defer table.deinit();
    try table.scope("\\_SB", struct {
        fn body(sb: *builder.Table) anyerror!void {
            try sb.device("PWRB", struct {
                fn body(button: *builder.Table) anyerror!void {
                    try button.nameInteger("_HID", 0x0C0CD041); // EisaId ("PNP0C0C")
                    try button.method("_STA", 0, &.{ 0xA4, 0x0A, 0x0F }); // Return (0x0F)
                }
            }.body);
            try sb.device("PCI0", struct {
                fn body(pci: *builder.Table) anyerror!void {
                    try pci.nameText("_HID", "PNP0A08");
                    try pci.nameOf("_CRS", struct {
                        fn data(crs: *builder.Table) anyerror!void {
                            try crs.buffer(4, &.{ 0x79, 0x00 });
                        }
                    }.data);
                    try pci.region("PCFG", 2, 0, 0x100);
                    try pci.field("PCFG", 0x01, &.{
                        .{ .name = "VID", .bits = 16 },
                        .{ .name = "DID", .bits = 16 },
                    });
                }
            }.body);
        }
    }.body);
    const loaded = load.loadTable(ab, .{ .code = try table.finish(), .index = 1 });
    try testing.expectEqual(@as(u32, 0), loaded.unknown + loaded.broken + loaded.missing + loaded.again);
    try testing.expectEqual(@as(u32, 9), loaded.names);
    const button = call(ab).NextAcpiDevice(null, "PNP0C0C") orelse return error.NoButton;
    try testing.expect(call(ab).FindAcpiNode(button, "_STA") != null);
    const pci = call(ab).NextAcpiDevice(null, "PNP0A08") orelse return error.NoBus;
    try testing.expectEqual(pci, call(ab).FindAcpiNode(null, "\\_SB.PCI0").?);
    try testing.expect(call(ab).FindAcpiNode(pci, "DID") != null);
    try tearDown(ab);
}
