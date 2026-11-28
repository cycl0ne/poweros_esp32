// SPDX-License-Identifier: MIT
//! Host tests of the firmware tables' walk (`sdk.hardware.acpi`: the root,
//! its list, the headers, the two tables the fixed description points at),
//! of the fixed description, the control structure and the embedded
//! controller's table read whole, and of the names Acpi saves the tables
//! under (names.zig), on a root, a list and tables built in memory as a
//! firmware lays them out - the fixed description as the NucBox K6's
//! firmware fills it in.

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

fn put16(memory: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, memory[at..][0..2], value, .little);
}

/// A register (a generic address) at `at`: its space, width, first bit,
/// access size and address.
fn putRegister(memory: []u8, at: usize, space: u8, bits: u8, shift: u8, access: u8, address: u64) void {
    memory[at] = space;
    memory[at + 1] = bits;
    memory[at + 2] = shift;
    memory[at + 3] = access;
    put64(memory, at + 4, address);
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

/// The fixed description's fields as the K6's firmware fills them in: the
/// first revision's ports and, from the second revision on, the same
/// blocks as registers, with the K6's flags, alarm registers and reset
/// register (`sources.md`, "The box's tables").
fn fillLikeTheBox(memory: *[SIZE]u8) void {
    const at = FACP;
    memory[at + 45] = 2;
    put16(memory, at + 46, 9);
    put32(memory, at + 48, 0xB2);
    memory[at + 52] = 0xA0;
    memory[at + 53] = 0xA1;
    put32(memory, at + 56, 0x800);
    put32(memory, at + 64, 0x804);
    put32(memory, at + 72, 0xB4);
    put32(memory, at + 76, 0x808);
    put32(memory, at + 80, 0x820);
    memory[at + 88] = 4;
    memory[at + 89] = 2;
    memory[at + 90] = 1;
    memory[at + 91] = 4;
    memory[at + 92] = 8;
    memory[at + 106] = 0x0D;
    memory[at + 108] = 0x32;
    put32(memory, at + 112, 0x0020_C5BD);
    putRegister(memory, at + 116, 1, 8, 0, 0, 0xB2);
    memory[at + 128] = 0xBE;
    memory[at + 131] = 4;
    putRegister(memory, at + 148, 1, 32, 0, 2, 0x800);
    putRegister(memory, at + 160, 1, 0, 0, 2, 0);
    putRegister(memory, at + 172, 1, 16, 0, 2, 0x804);
    putRegister(memory, at + 184, 1, 0, 0, 2, 0);
    putRegister(memory, at + 196, 1, 8, 0, 1, 0xB4);
    putRegister(memory, at + 208, 1, 32, 0, 3, 0x808);
    putRegister(memory, at + 220, 1, 64, 0, 1, 0x820);
    putRegister(memory, at + 232, 1, 0, 0, 1, 0);
    seal(memory, FACP, FACP_LENGTH, FACP + 9);
}

fn expectRegister(register: acpi.Register, space: u8, bits: u8, access: u8, address: u64) !void {
    try testing.expectEqual(space, register.space_id);
    try testing.expectEqual(bits, register.bit_width);
    try testing.expectEqual(@as(u8, 0), register.bit_offset);
    try testing.expectEqual(access, register.access_size);
    try testing.expectEqual(address, register.address);
}

test "the fixed description is read whole, each block as its register" {
    var memory: [SIZE]u8 align(16) = undefined;
    build(&memory);
    fillLikeTheBox(&memory);
    const fixed = acpi.readFadt(addressOf(&memory, FACP));
    try testing.expectEqual(@as(u8, 6), fixed.revision);
    try testing.expectEqual(@as(u8, 4), fixed.minor_version);
    try testing.expectEqual(@as(u32, FACP_LENGTH), fixed.length);
    try testing.expectEqual(addressOf(&memory, DSDT), fixed.dsdt);
    try testing.expectEqual(addressOf(&memory, FACS), fixed.facs);
    try testing.expectEqual(@as(u8, 2), fixed.preferred_pm_profile);
    try testing.expectEqual(@as(u16, 9), fixed.sci_int);
    try testing.expectEqual(@as(u32, 0xB2), fixed.smi_cmd);
    try testing.expectEqual(@as(u8, 0xA0), fixed.acpi_enable);
    try testing.expectEqual(@as(u8, 0xA1), fixed.acpi_disable);
    try testing.expectEqual(@as(u8, 0), fixed.cst_cnt);
    try expectRegister(fixed.pm1a_evt_blk, acpi.SPACE_SYSTEM_IO, 32, acpi.ACCESS_WORD, 0x800);
    try testing.expect(!fixed.pm1b_evt_blk.present());
    try expectRegister(fixed.pm1a_cnt_blk, acpi.SPACE_SYSTEM_IO, 16, acpi.ACCESS_WORD, 0x804);
    try testing.expect(!fixed.pm1b_cnt_blk.present());
    try expectRegister(fixed.pm2_cnt_blk, acpi.SPACE_SYSTEM_IO, 8, acpi.ACCESS_BYTE, 0xB4);
    try expectRegister(fixed.pm_tmr_blk, acpi.SPACE_SYSTEM_IO, 32, acpi.ACCESS_DWORD, 0x808);
    try expectRegister(fixed.gpe0_blk, acpi.SPACE_SYSTEM_IO, 64, acpi.ACCESS_BYTE, 0x820);
    try testing.expectEqual(@as(u8, 8), fixed.gpe0_blk_len);
    try testing.expect(!fixed.gpe1_blk.present());
    try testing.expectEqual(@as(u8, 4), fixed.pm1_evt_len);
    try testing.expectEqual(@as(u8, 2), fixed.pm1_cnt_len);
    try testing.expectEqual(@as(u8, 0x0D), fixed.day_alrm);
    try testing.expectEqual(@as(u8, 0), fixed.mon_alrm);
    try testing.expectEqual(@as(u8, 0x32), fixed.century);
    try testing.expectEqual(@as(u16, 0), fixed.iapc_boot_arch);
    try testing.expect(fixed.flags & acpi.FLAG_PWR_BUTTON != 0);
    try testing.expect(fixed.flags & acpi.FLAG_SLP_BUTTON != 0);
    try testing.expect(fixed.flags & acpi.FLAG_LOW_POWER_S0_IDLE_CAPABLE != 0);
    try testing.expect(fixed.flags & acpi.FLAG_HW_REDUCED_ACPI == 0);
    try testing.expect(fixed.flags & acpi.FLAG_RESET_REG_SUP != 0);
    try expectRegister(fixed.reset_reg, acpi.SPACE_SYSTEM_IO, 8, acpi.ACCESS_UNDEFINED, 0xB2);
    try testing.expectEqual(@as(u8, 0xBE), fixed.reset_value);
    try testing.expectEqual(@as(?u16, 0x804), fixed.pm1a_cnt_blk.ioPort());
    try testing.expect(!fixed.sleep_control_reg.present());
    try testing.expect(!fixed.sleep_status_reg.present());
}

test "a block whose register is empty is its port, as wide as its length says" {
    var memory: [SIZE]u8 align(16) = undefined;
    build(&memory);
    fillLikeTheBox(&memory);
    putRegister(&memory, FACP + 148, 0, 0, 0, 0, 0);
    // A block of general events longer than a register's width can say.
    memory[FACP + 92] = 40;
    putRegister(&memory, FACP + 220, 0, 0, 0, 0, 0);
    seal(&memory, FACP, FACP_LENGTH, FACP + 9);
    const fixed = acpi.readFadt(addressOf(&memory, FACP));
    try expectRegister(fixed.pm1a_evt_blk, acpi.SPACE_SYSTEM_IO, 32, acpi.ACCESS_UNDEFINED, 0x800);
    try expectRegister(fixed.gpe0_blk, acpi.SPACE_SYSTEM_IO, 255, acpi.ACCESS_UNDEFINED, 0x820);
    try testing.expectEqual(@as(u8, 40), fixed.gpe0_blk_len);
}

test "a first revision's fixed description is its ports alone" {
    var memory: [SIZE]u8 align(16) = undefined;
    build(&memory);
    fillLikeTheBox(&memory);
    put32(&memory, FACP + 4, 116);
    memory[FACP + 8] = 1;
    seal(&memory, FACP, 116, FACP + 9);
    const fixed = acpi.readFadt(addressOf(&memory, FACP));
    try testing.expectEqual(@as(u8, 1), fixed.revision);
    try testing.expectEqual(@as(u8, 0), fixed.minor_version);
    try expectRegister(fixed.pm1a_evt_blk, acpi.SPACE_SYSTEM_IO, 32, acpi.ACCESS_UNDEFINED, 0x800);
    try expectRegister(fixed.pm_tmr_blk, acpi.SPACE_SYSTEM_IO, 32, acpi.ACCESS_UNDEFINED, 0x808);
    try testing.expect(!fixed.reset_reg.present());
    try testing.expectEqual(@as(u8, 0), fixed.reset_value);
    try testing.expectEqual(@as(u32, 0x0020_C5BD), fixed.flags);
    // Shorter than the first revision's flags: its revision and length,
    // and nothing else.
    put32(&memory, FACP + 4, 100);
    const short = acpi.readFadt(addressOf(&memory, FACP));
    try testing.expectEqual(@as(u32, 100), short.length);
    try testing.expect(!short.pm1a_evt_blk.present());
    try testing.expectEqual(@as(u32, 0), short.flags);
}

test "a machine without the fixed hardware has its sleep registers" {
    var memory: [SIZE]u8 align(16) = undefined;
    build(&memory);
    put32(&memory, FACP + 112, acpi.FLAG_HW_REDUCED_ACPI | acpi.FLAG_LOW_POWER_S0_IDLE_CAPABLE);
    putRegister(&memory, FACP + 244, acpi.SPACE_SYSTEM_MEMORY, 8, 0, acpi.ACCESS_BYTE, 0xFED8_0000);
    putRegister(&memory, FACP + 256, acpi.SPACE_SYSTEM_MEMORY, 8, 0, acpi.ACCESS_BYTE, 0xFED8_0001);
    seal(&memory, FACP, FACP_LENGTH, FACP + 9);
    const fixed = acpi.readFadt(addressOf(&memory, FACP));
    try testing.expect(fixed.flags & acpi.FLAG_HW_REDUCED_ACPI != 0);
    try expectRegister(fixed.sleep_control_reg, acpi.SPACE_SYSTEM_MEMORY, 8, acpi.ACCESS_BYTE, 0xFED8_0000);
    try expectRegister(fixed.sleep_status_reg, acpi.SPACE_SYSTEM_MEMORY, 8, acpi.ACCESS_BYTE, 0xFED8_0001);
    try testing.expect(!fixed.pm1a_evt_blk.present());
    try testing.expectEqual(@as(?u16, null), fixed.sleep_control_reg.ioPort());
}

test "the kernel's facts of the power hardware come through the same reading" {
    var memory: [SIZE]u8 align(16) = undefined;
    build(&memory);
    fillLikeTheBox(&memory);
    const facts = acpi.read(addressOf(&memory, RSDP));
    try testing.expectEqual(@as(u16, 0x800), facts.pm1_event);
    try testing.expectEqual(@as(u16, 0), facts.pm1_event2);
    try testing.expectEqual(@as(u16, 0x804), facts.pm1_control);
    try testing.expectEqual(@as(u16, 0), facts.pm1_control2);
    try testing.expectEqual(@as(u8, 4), facts.pm1_event_bytes);
    try testing.expectEqual(@as(u8, 2), facts.pm1_control_bytes);
    try testing.expectEqual(@as(u32, 9), facts.sci_line);
    try testing.expectEqual(@as(u16, 0xB2), facts.mode_port);
    try testing.expectEqual(@as(u8, 0xA0), facts.mode_value);
    try testing.expect(!facts.fixed_power_button);
    try testing.expectEqual(@as(u16, 0x808), facts.pm_timer_port);
    try testing.expectEqual(@as(u8, 32), facts.pm_timer_bits);
    try testing.expect(facts.rtc);
    try testing.expectEqual(@as(u8, 0x32), facts.rtc_century);
    // A button that is a fixed feature, a 24-bit timer, no clock.
    put32(&memory, FACP + 112, 0);
    put16(&memory, FACP + 109, acpi.BOOT_CMOS_RTC_NOT_PRESENT);
    seal(&memory, FACP, FACP_LENGTH, FACP + 9);
    const other = acpi.read(addressOf(&memory, RSDP));
    try testing.expect(other.fixed_power_button);
    try testing.expectEqual(@as(u8, 24), other.pm_timer_bits);
    try testing.expect(!other.rtc);
}

test "the control structure, with the lock where it is" {
    var memory: [SIZE]u8 align(16) = undefined;
    build(&memory);
    put32(&memory, FACS + 8, 0x1234_5678);
    put32(&memory, FACS + 12, 0x9A000);
    put32(&memory, FACS + 16, acpi.LOCK_OWNED);
    put32(&memory, FACS + 20, acpi.FACS_64BIT_WAKE_SUPPORTED_F);
    put64(&memory, FACS + 24, 0x1_0000_0000);
    const control = acpi.readFacs(addressOf(&memory, FACS));
    try testing.expectEqual(@as(u32, 64), control.length);
    try testing.expectEqual(@as(u8, 2), control.version);
    try testing.expectEqual(@as(u32, 0x1234_5678), control.hardware_signature);
    try testing.expectEqual(@as(u32, 0x9A000), control.firmware_waking_vector);
    try testing.expectEqual(@as(u64, 0x1_0000_0000), control.x_firmware_waking_vector);
    try testing.expectEqual(addressOf(&memory, FACS + 16), control.global_lock);
    try testing.expectEqual(acpi.FACS_64BIT_WAKE_SUPPORTED_F, control.flags);
    try testing.expectEqual(@as(u32, 0), acpi.readFacs(addressOf(&memory, DSDT)).length);
    try testing.expectEqual(@as(usize, 0), acpi.readFacs(0).global_lock);
}

test "the embedded controller's table, its path read in place" {
    var table: [128]u8 align(8) = @splat(0);
    const path = "\\_SB.PCI0.SBRG.EC0";
    const length: u32 = 65 + path.len + 1;
    @memcpy(table[0..4], "ECDT");
    put32(&table, 4, length);
    table[8] = 1;
    putRegister(&table, 36, acpi.SPACE_SYSTEM_IO, 8, 0, acpi.ACCESS_BYTE, 0x66);
    putRegister(&table, 48, acpi.SPACE_SYSTEM_IO, 8, 0, acpi.ACCESS_BYTE, 0x62);
    put32(&table, 60, 1);
    table[64] = 0x0B;
    @memcpy(table[65..][0..path.len], path);
    const at = @intFromPtr(&table);
    const controller = acpi.readEcdt(at);
    try expectRegister(controller.ec_control, acpi.SPACE_SYSTEM_IO, 8, acpi.ACCESS_BYTE, 0x66);
    try expectRegister(controller.ec_data, acpi.SPACE_SYSTEM_IO, 8, acpi.ACCESS_BYTE, 0x62);
    try testing.expectEqual(@as(u32, 1), controller.uid);
    try testing.expectEqual(@as(u8, 0x0B), controller.gpe_bit);
    try testing.expectEqual(at + 65, controller.ec_id);
    try testing.expectEqual(@as(u32, path.len), controller.ec_id_length);
    const text: [*]const u8 = @ptrFromInt(controller.ec_id);
    try testing.expectEqualStrings(path, text[0..controller.ec_id_length]);
    // A path with no NUL ends with the table.
    put32(&table, 4, 65 + 4);
    try testing.expectEqual(@as(u32, 4), acpi.readEcdt(at).ec_id_length);
    // Too short to be one.
    put32(&table, 4, 60);
    try testing.expect(!acpi.readEcdt(at).ec_control.present());
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
