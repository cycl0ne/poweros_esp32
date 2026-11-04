// SPDX-License-Identifier: MIT
//! The firmware's description tables, read.
//!
//! A machine started by UEFI firmware is described by a set of tables in
//! memory rather than by a device tree: a root that lists them, and under
//! it one table per thing the firmware has to say. What the kernel wants
//! out of them is a short list - where the interrupt controllers are, how
//! many cores there are and what their controllers are called, how the
//! machine's old interrupt lines are wired, which port the clock whose
//! rate is fixed is on, and where PCI's configuration space is - and
//! that is what this reads. Nothing here interprets the tables' bytecode:
//! the tables that matter are plain structures, and the one language in
//! them describes what a driver would ask a device for anyway.
//!
//! **Where this lives, and why it is not a library or a resource.** It is
//! read before exec exists - the memory exec is made with is part of what
//! it says - so there is nothing to open and no base to call through. It is
//! SDK code for the same reason the device-tree readers are hardware code:
//! it is a format, and what it finds goes into the board's description,
//! which stays the one thing every module asks.
//!
//! **Byte by byte.** The tables are packed and a field may sit on any
//! boundary, so every field is read a byte at a time. These are read once
//! each, at boot.

/// A table's header, which every one of them starts with.
const HEADER_SIZE = 36;
const HEADER_LENGTH = 4;
const HEADER_REVISION = 8;
const HEADER_CHECKSUM = 9;

/// How many of each the reader records.
pub const MAX_CORES = 16;
pub const MAX_IO_CONTROLLERS = 4;
pub const MAX_OVERRIDES = 24;

/// One of the machine's I/O interrupt controllers.
pub const IoController = struct {
    address: u64 = 0,
    /// The machine's first interrupt line this controller takes.
    first_line: u32 = 0,
};

/// One of the machine's old interrupt lines wired somewhere other than
/// where its number says, or taken other than the way its number implies.
pub const Override = struct {
    /// The old line's number, 0 to 15.
    source: u8 = 0,
    /// The controller input it is actually on.
    line: u32 = 0,
    /// Level-triggered rather than edge-triggered.
    level: bool = false,
    /// Active low rather than active high.
    low_active: bool = false,
};

/// What the tables said. Everything is 0 or empty where they did not say.
pub const Facts = struct {
    /// Whether a root was found and its checksum held.
    found: bool = false,
    /// The root's revision: 0 is the old 32-bit root, 2 and up the one
    /// with 64-bit pointers.
    revision: u8 = 0,
    /// How many tables the root listed, and how many of those were read.
    listed: u32 = 0,

    /// Where a core's own interrupt controller is mapped.
    lapic_base: u64 = 0,
    /// The cores' controller ids, the boot core's among them: only the
    /// ones the firmware says may be used.
    cores: [MAX_CORES]u32 = @splat(0),
    core_count: u32 = 0,

    io: [MAX_IO_CONTROLLERS]IoController = @splat(.{}),
    io_count: u32 = 0,

    overrides: [MAX_OVERRIDES]Override = @splat(.{}),
    override_count: u32 = 0,

    /// The port of the timer whose rate the architecture fixes
    /// (3.579545 MHz), and how many bits of its counter count.
    pm_timer_port: u16 = 0,
    pm_timer_bits: u8 = 0,

    /// Where PCI's configuration space is, and the buses it covers.
    ecam_base: u64 = 0,
    ecam_first_bus: u8 = 0,
    ecam_last_bus: u8 = 0,

    /// Where the machine's other timer is, if it has one.
    hpet_base: u64 = 0,

    /// Whether the machine has the battery-backed clock a PC has always
    /// had. True unless the tables say it has none, since that is what
    /// they are read for: a machine old enough to say nothing has one.
    rtc: bool = true,
    /// Which of that clock's registers holds the century, 0 where the
    /// tables name none and the year's two digits are all there is.
    rtc_century: u8 = 0,

    /// The cores' ids as a slice.
    pub fn coreIds(facts: *const Facts) []const u32 {
        return facts.cores[0..facts.core_count];
    }

    /// The I/O controllers as a slice.
    pub fn controllers(facts: *const Facts) []const IoController {
        return facts.io[0..facts.io_count];
    }

    /// The wiring the tables named, as a slice.
    pub fn wiring(facts: *const Facts) []const Override {
        return facts.overrides[0..facts.override_count];
    }
};

// --- reading memory a byte at a time -----------------------------------------------

fn byteAt(at: usize) u8 {
    return @as(*const volatile u8, @ptrFromInt(at)).*;
}

fn wordAt(at: usize) u16 {
    return @as(u16, byteAt(at)) | @as(u16, byteAt(at + 1)) << 8;
}

fn longAt(at: usize) u32 {
    return @as(u32, wordAt(at)) | @as(u32, wordAt(at + 2)) << 16;
}

fn quadAt(at: usize) u64 {
    return @as(u64, longAt(at)) | @as(u64, longAt(at + 4)) << 32;
}

/// Whether `length` bytes at `at` sum to zero, which is how every one of
/// these tables says it was not written over.
fn sums(at: usize, length: usize) bool {
    var total: u8 = 0;
    var index: usize = 0;
    while (index < length) : (index += 1) total +%= byteAt(at + index);
    return total == 0;
}

/// Whether the four bytes at `at` are `signature`.
fn named(at: usize, signature: *const [4]u8) bool {
    for (signature, 0..) |char, index| {
        if (byteAt(at + index) != char) return false;
    }
    return true;
}

// --- the tables --------------------------------------------------------------------

/// The root, as the firmware's configuration table points at it: its
/// signature, the old 32-bit list and, from revision 2, the 64-bit one.
const RSDP_SIGNATURE = "RSD PTR ";
const RSDP_REVISION = 15;
const RSDP_RSDT = 16;
const RSDP_LENGTH = 20;
const RSDP_XSDT = 24;

/// What the tables say, read from the root the firmware pointed at. A root
/// whose checksum does not hold, or that points at no list, gives facts
/// that say nothing - and the kernel says so rather than acting on
/// whatever was there.
pub fn read(rsdp: usize) Facts {
    var facts: Facts = .{};
    if (rsdp == 0) return facts;
    for (RSDP_SIGNATURE, 0..) |char, index| {
        if (byteAt(rsdp + index) != char) return facts;
    }
    // The first twenty bytes are the old root and sum on their own; the
    // rest of a newer one sums with them.
    if (!sums(rsdp, 20)) return facts;
    facts.revision = byteAt(rsdp + RSDP_REVISION);
    var list: usize = 0;
    var wide = false;
    if (facts.revision >= 2) {
        const length = longAt(rsdp + RSDP_LENGTH);
        if (length >= 33 and sums(rsdp, length)) {
            const xsdt = quadAt(rsdp + RSDP_XSDT);
            if (xsdt != 0) {
                list = @intCast(xsdt);
                wide = true;
            }
        }
    }
    if (list == 0) list = longAt(rsdp + RSDP_RSDT);
    if (list == 0) return facts;
    if (!named(list, if (wide) "XSDT" else "RSDT")) return facts;
    const list_length = longAt(list + HEADER_LENGTH);
    if (list_length < HEADER_SIZE or !sums(list, list_length)) return facts;
    facts.found = true;

    const stride: usize = if (wide) 8 else 4;
    const count = (list_length - HEADER_SIZE) / stride;
    facts.listed = @intCast(count);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const at = list + HEADER_SIZE + index * stride;
        const table: usize = if (wide) @intCast(quadAt(at)) else longAt(at);
        if (table == 0) continue;
        const length = longAt(table + HEADER_LENGTH);
        if (length < HEADER_SIZE or !sums(table, length)) continue;
        if (named(table, "APIC")) takeInterrupts(&facts, table, length);
        if (named(table, "FACP")) takeFixed(&facts, table, length);
        if (named(table, "MCFG")) takeConfigSpace(&facts, table, length);
        if (named(table, "HPET")) takeHpet(&facts, table, length);
    }
    return facts;
}

/// The interrupt table (MADT): where a core's own controller is, which
/// cores there are, where the I/O controllers are and what line each
/// starts at, and the old lines that are wired elsewhere.
const MADT_LAPIC = HEADER_SIZE;
const MADT_FLAGS = HEADER_SIZE + 4;
const MADT_ENTRIES = HEADER_SIZE + 8;

const MADT_LOCAL: u8 = 0;
const MADT_IO: u8 = 1;
const MADT_OVERRIDE: u8 = 2;
const MADT_LAPIC_ADDRESS: u8 = 5;
const MADT_LOCAL_WIDE: u8 = 9;

/// A core's flags: it can be used, or it could be brought online later.
const CORE_ENABLED: u32 = 1 << 0;
const CORE_CAPABLE: u32 = 1 << 1;

fn takeInterrupts(facts: *Facts, table: usize, length: u32) void {
    facts.lapic_base = longAt(table + MADT_LAPIC);
    var at = table + MADT_ENTRIES;
    const end = table + length;
    while (at + 2 <= end) {
        const kind = byteAt(at);
        const size = byteAt(at + 1);
        if (size < 2 or at + size > end) break;
        switch (kind) {
            MADT_LOCAL => if (size >= 8) {
                const flags = longAt(at + 4);
                if (flags & (CORE_ENABLED | CORE_CAPABLE) != 0 and facts.core_count < MAX_CORES) {
                    facts.cores[facts.core_count] = byteAt(at + 3);
                    facts.core_count += 1;
                }
            },
            MADT_IO => if (size >= 12 and facts.io_count < MAX_IO_CONTROLLERS) {
                facts.io[facts.io_count] = .{ .address = longAt(at + 4), .first_line = longAt(at + 8) };
                facts.io_count += 1;
            },
            MADT_OVERRIDE => if (size >= 10 and facts.override_count < MAX_OVERRIDES) {
                const flags = wordAt(at + 8);
                const source = byteAt(at + 3);
                // The low two bits say the polarity, the next two the
                // trigger; 0 in either means "as the line's number
                // implies", which for the old lines is active high and
                // edge-triggered.
                facts.overrides[facts.override_count] = .{
                    .source = source,
                    .line = longAt(at + 4),
                    .low_active = (flags & 0x3) == 0x3,
                    .level = (flags >> 2 & 0x3) == 0x3,
                };
                facts.override_count += 1;
            },
            MADT_LAPIC_ADDRESS => if (size >= 12) {
                facts.lapic_base = quadAt(at + 4);
            },
            MADT_LOCAL_WIDE => if (size >= 16) {
                const flags = longAt(at + 8);
                if (flags & (CORE_ENABLED | CORE_CAPABLE) != 0 and facts.core_count < MAX_CORES) {
                    facts.cores[facts.core_count] = longAt(at + 4);
                    facts.core_count += 1;
                }
            },
            else => {},
        }
        at += size;
    }
}

/// The fixed description (FADT): the port of the timer whose rate the
/// architecture fixes, whether its counter is 24 or 32 bits wide, and
/// what the machine's battery-backed clock is.
const FADT_PM_TIMER = 76;
const FADT_PM_TIMER_LENGTH = 91;
/// Which register of the battery-backed clock holds the century, and the
/// two bytes about the hardware a PC has always had, of which bit 5 says
/// that this machine has no such clock. Both are later additions to the
/// table, so a table too short for them says nothing about either.
const FADT_CENTURY = 108;
const FADT_PC_HARDWARE = 109;
const FADT_NO_RTC: u32 = 1 << 5;
const FADT_FLAGS = 112;
/// FADT's flags, bit 8: the timer's counter is 32 bits and not 24.
const FADT_TIMER_WIDE: u32 = 1 << 8;

fn takeFixed(facts: *Facts, table: usize, length: u32) void {
    if (length < FADT_FLAGS + 4) return;
    if (length >= FADT_PC_HARDWARE + 2) {
        facts.rtc_century = byteAt(table + FADT_CENTURY);
        facts.rtc = wordAt(table + FADT_PC_HARDWARE) & FADT_NO_RTC == 0;
    }
    if (byteAt(table + FADT_PM_TIMER_LENGTH) != 4) return;
    const port = longAt(table + FADT_PM_TIMER);
    if (port == 0 or port > 0xFFFF) return;
    facts.pm_timer_port = @intCast(port);
    facts.pm_timer_bits = if (longAt(table + FADT_FLAGS) & FADT_TIMER_WIDE != 0) 32 else 24;
}

/// The configuration space table (MCFG): where PCI's configuration space
/// is, and which buses it covers. Only the first segment is taken: a
/// machine with more than one is beyond what the system drives.
const MCFG_ENTRIES = HEADER_SIZE + 8;

fn takeConfigSpace(facts: *Facts, table: usize, length: u32) void {
    if (length < MCFG_ENTRIES + 16) return;
    const at = table + MCFG_ENTRIES;
    facts.ecam_base = quadAt(at);
    facts.ecam_first_bus = byteAt(at + 10);
    facts.ecam_last_bus = byteAt(at + 11);
}

/// The other timer (HPET), whose address is in a generic address
/// structure: its kind, three bytes about its width, and the address.
const HPET_ADDRESS = HEADER_SIZE + 4;

fn takeHpet(facts: *Facts, table: usize, length: u32) void {
    if (length < HPET_ADDRESS + 12) return;
    // Only one in memory is any use here; one in the port space is not
    // what this timer ever is.
    if (byteAt(table + HPET_ADDRESS) != 0) return;
    facts.hpet_base = quadAt(table + HPET_ADDRESS + 4);
}
