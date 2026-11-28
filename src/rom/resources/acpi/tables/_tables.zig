// SPDX-License-Identifier: MPL-2.0
//! The firmware's tables of bytecode, in the order they are loaded: the
//! DSDT the fixed description points at, then each SSDT the root lists
//! and each PSDT - the older name for the same kind of table - in the
//! order of the root's list. Each table is loaded once, with its place in
//! that order, from 1, and its place among the tables of its signature,
//! from 1 in the list's order, which is the number C:Acpi saves it under
//! (SSDT22.aml).
//!
//! A table whose length is not one a table can have is left out. One
//! whose checksum does not hold is loaded all the same, with a warning:
//! the length is what says where its bytecode ends, and a firmware that
//! changed a byte of a table after summing it still means the table.

const sdk = @import("sdk");
const exec = sdk.exec;
const hardware_acpi = sdk.hardware.acpi;
const AcpiBase = @import("../acpi_base.zig").AcpiBase;
const machine = @import("../machine/_machine.zig");
const load = @import("../aml/load.zig");

/// The tables `root` lists, and the DSDT, loaded in their order.
pub fn loadFirmware(ab: *AcpiBase, root: *const hardware_acpi.Root) void {
    var index: u16 = 0;
    const fadt = root.find("FACP", 0);
    if (fadt != 0) {
        const dsdt = hardware_acpi.dsdtOf(fadt);
        if (dsdt != 0) loadAt(ab, dsdt, &index, 1);
    }
    var ssdts: u16 = 0;
    var psdts: u16 = 0;
    var at: u32 = 0;
    while (at < root.count) : (at += 1) {
        const table = root.table(at);
        if (table == 0) continue;
        const signature = hardware_acpi.headerOf(table).signature;
        if (same(&signature, "SSDT")) {
            ssdts += 1;
            loadAt(ab, table, &index, ssdts);
        } else if (same(&signature, "PSDT")) {
            psdts += 1;
            loadAt(ab, table, &index, psdts);
        }
    }
}

fn same(signature: *const [4]u8, letters: *const [4]u8) bool {
    for (signature, letters) |one, other| {
        if (one != other) return false;
    }
    return true;
}

/// The table at `table` loaded as the next, `place` among its kind.
fn loadAt(ab: *AcpiBase, table: usize, index: *u16, place: u16) void {
    const header = hardware_acpi.headerOf(table);
    var signature: [5]u8 = .{ 0, 0, 0, 0, 0 };
    @memcpy(signature[0..4], &header.signature);
    if (header.length < load.HEADER_SIZE or header.length > hardware_acpi.MOST_TABLE_BYTES) {
        machine.log(ab, exec.LOG_ERROR, "%s %u at 0x%lx says it is %u bytes long, and is left out\n", .{
            @as([*:0]const u8, @ptrCast(&signature)), @as(u32, place), @as(u64, table), header.length,
        });
        return;
    }
    if (!header.sound) {
        machine.log(ab, exec.LOG_WARNING, "%s %u at 0x%lx: its checksum does not hold; loaded all the same\n", .{
            @as([*:0]const u8, @ptrCast(&signature)), @as(u32, place), @as(u64, table),
        });
    }
    index.* += 1;
    const code: [*]const u8 = @ptrFromInt(table);
    _ = load.loadTable(ab, .{ .code = code[0..header.length], .index = index.*, .place = place });
}
