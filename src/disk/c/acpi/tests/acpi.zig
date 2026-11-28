// SPDX-License-Identifier: MIT
//! Host tests of the firmware tables' walk (`sdk.hardware.acpi`: the root,
//! its list, the headers, the two tables the fixed description points at)
//! and of the names Acpi saves them under (names.zig), on a root, a list
//! and tables built in memory as a firmware lays them out.

const std = @import("std");
const acpi = @import("sdk").hardware.acpi;
const names = @import("../names.zig");

const testing = std.testing;

/// Where each piece is in the built memory.
const RSDP = 0;
const XSDT = 64;
const FACP = 192;
const DSDT = 512;
const FACS = 640;
const SSDT_FIRST = 768;
const SSDT_SECOND = 832;
const APIC = 896;
const SIZE = 1024;

const FACP_LENGTH = 276;
const LAPIC: u32 = 0xFEE0_0000;

fn put32(memory: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, memory[at..][0..4], value, .little);
}

fn put64(memory: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, memory[at..][0..8], value, .little);
}

/// A table's header at `at`: its letters, length and revision, a maker
/// and a name, and its checksum left for `seal`.
fn header(memory: []u8, at: usize, letters: *const [4]u8, length: u32, revision: u8) void {
    @memcpy(memory[at..][0..4], letters);
    put32(memory, at + 4, length);
    memory[at + 8] = revision;
    @memcpy(memory[at + 10 ..][0..6], "PWROS ");
    @memcpy(memory[at + 16 ..][0..8], "TESTTBL ");
    put32(memory, at + 24, 1);
    @memcpy(memory[at + 28 ..][0..4], "ZIG ");
    put32(memory, at + 32, 16);
}

/// The byte at `checksum` set so that `length` bytes from `at` sum to 0.
fn seal(memory: []u8, at: usize, length: usize, checksum: usize) void {
    memory[checksum] = 0;
    var sum: u8 = 0;
    for (memory[at .. at + length]) |byte| sum +%= byte;
    memory[checksum] = 0 -% sum;
}

/// A newer root, its 64-bit list of four tables - the fixed description,
/// two of bytecode with the main table's companions, the interrupt
/// controllers' - and the main table and control structure the fixed
/// description points at, each through its 64-bit field (the 32-bit ones
/// cannot name memory above four gibibytes, which is where a host's is).
fn build(memory: *[SIZE]u8) void {
    @memset(memory, 0);
    const base: u64 = @intFromPtr(memory);

    @memcpy(memory[RSDP..][0..8], "RSD PTR ");
    @memcpy(memory[RSDP + 9 ..][0..6], "PWROS ");
    memory[RSDP + 15] = 2;
    put32(memory, RSDP + 20, 36);
    put64(memory, RSDP + 24, base + XSDT);

    const listed = [_]usize{ FACP, SSDT_FIRST, APIC, SSDT_SECOND };
    header(memory, XSDT, "XSDT", 36 + listed.len * 8, 1);
    for (listed, 0..) |table, index| put64(memory, XSDT + 36 + index * 8, base + table);

    header(memory, FACP, "FACP", FACP_LENGTH, 6);
    put64(memory, FACP + 132, base + FACS);
    put64(memory, FACP + 140, base + DSDT);

    header(memory, DSDT, "DSDT", 44, 2);
    @memcpy(memory[DSDT + 36 ..][0..8], &[_]u8{ 0x10, 0x06, 0x5C, 0x5F, 0x53, 0x42, 0x5F, 0x00 });

    @memcpy(memory[FACS..][0..4], "FACS");
    put32(memory, FACS + 4, 64);
    memory[FACS + 32] = 2;

    header(memory, SSDT_FIRST, "SSDT", 40, 2);
    header(memory, SSDT_SECOND, "SSDT", 40, 2);
    header(memory, APIC, "APIC", 44, 5);
    put32(memory, APIC + 36, LAPIC);

    sealAll(memory);
}

fn sealAll(memory: *[SIZE]u8) void {
    seal(memory, RSDP, 20, RSDP + 8);
    seal(memory, RSDP, 36, RSDP + 32);
    seal(memory, XSDT, 36 + 4 * 8, XSDT + 9);
    seal(memory, FACP, FACP_LENGTH, FACP + 9);
    seal(memory, DSDT, 44, DSDT + 9);
    seal(memory, SSDT_FIRST, 40, SSDT_FIRST + 9);
    seal(memory, SSDT_SECOND, 40, SSDT_SECOND + 9);
    seal(memory, APIC, 44, APIC + 9);
}

fn addressOf(memory: *[SIZE]u8, at: usize) usize {
    return @intFromPtr(memory) + at;
}

test "the root and its list are found, and each table by its letters and its place" {
    var memory: [SIZE]u8 align(16) = undefined;
    build(&memory);
    const root = acpi.rootAt(addressOf(&memory, RSDP)).?;
    try testing.expectEqual(@as(u8, 2), root.revision);
    try testing.expectEqual(@as(u32, 36), root.length);
    try testing.expect(root.wide);
    try testing.expectEqual(addressOf(&memory, XSDT), root.list);
    try testing.expectEqual(@as(u32, 4), root.count);
    try testing.expectEqual(addressOf(&memory, APIC), root.table(2));
    try testing.expectEqual(@as(usize, 0), root.table(4));
    try testing.expectEqual(addressOf(&memory, SSDT_FIRST), root.find("SSDT", 0));
    try testing.expectEqual(addressOf(&memory, SSDT_SECOND), root.find("SSDT", 1));
    try testing.expectEqual(@as(usize, 0), root.find("SSDT", 2));
    try testing.expectEqual(@as(usize, 0), root.find("HPET", 0));

    const fixed = acpi.headerOf(root.find("FACP", 0));
    try testing.expect(fixed.sound);
    try testing.expectEqualSlices(u8, "FACP", &fixed.signature);
    try testing.expectEqual(@as(u32, FACP_LENGTH), fixed.length);
    try testing.expectEqual(@as(u8, 6), fixed.revision);
    try testing.expectEqualSlices(u8, "PWROS ", &fixed.oem);
    try testing.expectEqualSlices(u8, "TESTTBL ", &fixed.oem_table);
    try testing.expectEqualSlices(u8, "ZIG ", &fixed.creator);
}

test "the fixed description points at the main table and the control structure" {
    var memory: [SIZE]u8 align(16) = undefined;
    build(&memory);
    const fadt = addressOf(&memory, FACP);
    try testing.expectEqual(addressOf(&memory, DSDT), acpi.dsdtOf(fadt));
    try testing.expectEqual(addressOf(&memory, FACS), acpi.facsOf(fadt));
    try testing.expectEqual(@as(u32, 64), acpi.facsLength(acpi.facsOf(fadt)));
    try testing.expectEqual(@as(u8, 2), acpi.facsVersion(acpi.facsOf(fadt)));
    try testing.expect(acpi.headerOf(acpi.dsdtOf(fadt)).sound);
    // Not a control structure: no signature there.
    try testing.expectEqual(@as(u32, 0), acpi.facsLength(addressOf(&memory, DSDT)));
    try testing.expectEqual(@as(u32, 0), acpi.facsLength(0));
}

test "a fixed description too short for the 64-bit fields is read by its 32-bit ones" {
    var memory: [SIZE]u8 align(16) = undefined;
    build(&memory);
    // A first revision's fixed description: 116 bytes, which ends before
    // either 64-bit field. Its 32-bit fields are 0 here, for they cannot
    // name a host's memory: so it points nowhere.
    put32(&memory, FACP + 4, 116);
    seal(&memory, FACP, 116, FACP + 9);
    const fadt = addressOf(&memory, FACP);
    try testing.expectEqual(@as(usize, 0), acpi.dsdtOf(fadt));
    try testing.expectEqual(@as(usize, 0), acpi.facsOf(fadt));
    put32(&memory, FACP + 40, 0x1234_5000);
    try testing.expectEqual(@as(usize, 0x1234_5000), acpi.dsdtOf(fadt));
}

test "a table whose checksum does not hold is not sound and not found" {
    var memory: [SIZE]u8 align(16) = undefined;
    build(&memory);
    memory[SSDT_FIRST + 36] ^= 0xFF;
    const root = acpi.rootAt(addressOf(&memory, RSDP)).?;
    try testing.expect(!acpi.headerOf(addressOf(&memory, SSDT_FIRST)).sound);
    try testing.expectEqual(addressOf(&memory, SSDT_SECOND), root.find("SSDT", 0));
    try testing.expectEqual(@as(usize, 0), root.find("SSDT", 1));
}

test "a root is not taken where its checksums, or its list's, do not hold" {
    var memory: [SIZE]u8 align(16) = undefined;
    build(&memory);
    try testing.expectEqual(@as(?acpi.Root, null), acpi.rootAt(0));
    try testing.expectEqual(@as(?acpi.Root, null), acpi.rootAt(addressOf(&memory, XSDT)));
    // The newer part's checksum broken: the old list is taken, and this
    // root has none.
    memory[RSDP + 32] +%= 1;
    try testing.expectEqual(@as(?acpi.Root, null), acpi.rootAt(addressOf(&memory, RSDP)));
    build(&memory);
    // The list's own checksum broken.
    memory[XSDT + 9] +%= 1;
    try testing.expectEqual(@as(?acpi.Root, null), acpi.rootAt(addressOf(&memory, RSDP)));
}

test "what the kernel reads, it reads through the same walk" {
    var memory: [SIZE]u8 align(16) = undefined;
    build(&memory);
    const facts = acpi.read(addressOf(&memory, RSDP));
    try testing.expect(facts.found);
    try testing.expectEqual(@as(u8, 2), facts.revision);
    try testing.expectEqual(@as(u32, 4), facts.listed);
    try testing.expectEqual(@as(u64, LAPIC), facts.lapic_base);
    memory[RSDP] = 'X';
    try testing.expect(!acpi.read(addressOf(&memory, RSDP)).found);
}

fn expectName(expected: []const u8, root: *const acpi.Root, index: u32) !void {
    var name: [names.NAME_ROOM:0]u8 = @splat(0);
    const letters = acpi.headerOf(root.table(index)).signature;
    try testing.expectEqualStrings(expected, std.mem.span(names.nameOf(letters, names.placeOf(root, index), &name)));
}

test "a table is saved under its letters, numbered where the list has several with them" {
    var memory: [SIZE]u8 align(16) = undefined;
    build(&memory);
    const root = acpi.rootAt(addressOf(&memory, RSDP)).?;
    try expectName("FACP.aml", &root, 0);
    try expectName("SSDT1.aml", &root, 1);
    try expectName("APIC.aml", &root, 2);
    try expectName("SSDT2.aml", &root, 3);
    const place = names.placeOf(&root, 3);
    try testing.expectEqual(@as(u32, 2), place.place);
    try testing.expectEqual(@as(u32, 2), place.of);

    var name: [names.NAME_ROOM:0]u8 = @splat(0);
    try testing.expectEqualStrings("A_B_.aml", std.mem.span(names.nameOf(.{ 'A', '/', 'B', 0 }, .{}, &name)));
    try testing.expectEqualStrings("SSDT12.aml", std.mem.span(names.nameOf("SSDT".*, .{ .place = 12, .of = 40 }, &name)));
}
