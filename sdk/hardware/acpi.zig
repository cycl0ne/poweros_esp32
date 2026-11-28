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
//! what is read here is plain structures.
//!
//! **Where this lives, and why it is not a library or a resource.** It is
//! read before exec exists - the memory exec is made with is part of what
//! it says - so there is nothing to open and no base to call through. It is
//! SDK code for the same reason the device-tree readers are hardware code:
//! it is a format, and what it finds goes into the board's description,
//! which stays the one thing every module asks.
//!
//! **The walk.** Besides the facts the kernel takes (`read`), the root and
//! the list it points at can be walked table by table (`rootAt`, then
//! `Root.table` and `Root.find`), each table's header read (`headerOf`),
//! and the two tables the root does not list found through the fixed
//! description (`dsdtOf`, `facsOf`): what a program that lists or saves
//! the tables walks them with. The tables stay where the firmware put
//! them for as long as the machine runs, so this may be done at any time.
//!
//! **The fixed description, whole.** `readFadt` reads every register block
//! and flag of the fixed description the system acts on - the power
//! management hardware's, the general events', the clock's alarm, the
//! reset register, a hardware-reduced machine's sleep registers - and the
//! kernel takes its own facts through it; `readFacs` reads the control
//! structure, with the lock the firmware and the system share, and
//! `readEcdt` the embedded controller's table. Their fields are named as
//! the tables name them.
//!
//! **Byte by byte.** The tables are packed and a field may sit on any
//! boundary, so every field is read a byte at a time. These are read once
//! each, at boot.

/// A table's header, which every one of them starts with.
const HEADER_SIZE = 36;
const HEADER_LENGTH = 4;
const HEADER_REVISION = 8;
const HEADER_CHECKSUM = 9;
const HEADER_OEM = 10;
const HEADER_OEM_TABLE = 16;
const HEADER_OEM_REVISION = 24;
const HEADER_CREATOR = 28;
const HEADER_CREATOR_REVISION = 32;

/// No table is longer than this. A length beyond it is a table written
/// over, and summing that far could run off the memory the firmware has.
const MOST_TABLE_BYTES: u32 = 16 << 20;

/// How many of each the reader records. The cores are not among them:
/// there are as many as the machine has, which is any number at all, so
/// they are counted here and read again into the room the caller then has
/// for them (`fillCores`).
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
    /// How many cores the firmware says may be used, the boot core
    /// among them, and where their description is so that their
    /// controller ids can be read out of it (`fillCores`).
    core_count: u32 = 0,
    madt: usize = 0,
    madt_length: u32 = 0,

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

    /// The machine's power hardware, as the fixed description gives it:
    /// the two register blocks the architecture's power management has
    /// had since it was written down - an event block, whose first half
    /// is what happened and whose second is what may be reported, and a
    /// control block - and the second pair a machine with two of them
    /// has (0 where it has one, which nearly every machine does). All of
    /// them are in the I/O port space.
    pm1_event: u16 = 0,
    pm1_event2: u16 = 0,
    pm1_control: u16 = 0,
    pm1_control2: u16 = 0,
    /// How many bytes a whole event block is, both halves together, and a
    /// control block.
    pm1_event_bytes: u8 = 0,
    pm1_control_bytes: u8 = 0,
    /// The interrupt line the machine's power management raises, as a
    /// controller input.
    sci_line: u32 = 0,
    /// The port a machine that is not in this mode yet is told to enter
    /// it on, and what is written there; both 0 where it is in it
    /// already and there is nothing to ask.
    mode_port: u16 = 0,
    mode_value: u8 = 0,
    /// Whether the power button is one of this hardware's own fixed
    /// features, which is what makes it readable without interpreting
    /// anything: a machine whose button is described in the tables'
    /// language instead says so, and this is false.
    fixed_power_button: bool = false,

    /// Whether the machine has the battery-backed clock a PC has always
    /// had. True unless the tables say it has none, since that is what
    /// they are read for: a machine old enough to say nothing has one.
    rtc: bool = true,
    /// Which of that clock's registers holds the century, 0 where the
    /// tables name none and the year's two digits are all there is.
    rtc_century: u8 = 0,

    /// Where the table of video BIOS images is (VFCT): the firmware's
    /// copy of each display device's own BIOS, which the device's driver
    /// reads its tables and its command tables out of. 0 where the
    /// firmware left none. Nothing here reads it: the kernel hands it on
    /// as a part (PARTKIND_VIDEO_BIOS).
    vfct: u64 = 0,

    /// The cores' controller ids into `into`, as many of them as it
    /// holds, by the walk that counted them: how many were written. The
    /// description is in the firmware's own memory, which the kernel
    /// keeps, so this may be asked at any time.
    pub fn fillCores(facts: *const Facts, into: []u32) u32 {
        if (facts.madt == 0) return 0;
        var count: u32 = 0;
        var at = facts.madt + MADT_ENTRIES;
        const end = facts.madt + facts.madt_length;
        while (at + 2 <= end and count < into.len) {
            const kind = byteAt(at);
            const size = byteAt(at + 1);
            if (size < 2 or at + size > end) break;
            switch (kind) {
                MADT_LOCAL => if (size >= 8 and longAt(at + 4) & (CORE_ENABLED | CORE_CAPABLE) != 0) {
                    into[count] = byteAt(at + 3);
                    count += 1;
                },
                MADT_LOCAL_WIDE => if (size >= 16 and longAt(at + 8) & (CORE_ENABLED | CORE_CAPABLE) != 0) {
                    into[count] = longAt(at + 4);
                    count += 1;
                },
                else => {},
            }
            at += size;
        }
        return count;
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

/// Whether the bytes at `at` are `signature`.
fn named(at: usize, signature: []const u8) bool {
    for (signature, 0..) |char, index| {
        if (byteAt(at + index) != char) return false;
    }
    return true;
}

/// Whether a table of `length` bytes at `at` is long enough for its
/// header, no longer than any table is, and sums to zero.
fn sound(at: usize, length: u32) bool {
    return length >= HEADER_SIZE and length <= MOST_TABLE_BYTES and sums(at, length);
}

// --- the tables --------------------------------------------------------------------

/// The root, as the firmware's configuration table points at it: its
/// signature, the old 32-bit list and, from revision 2, the 64-bit one.
const RSDP_SIGNATURE = "RSD PTR ";
const RSDP_REVISION = 15;
const RSDP_RSDT = 16;
const RSDP_LENGTH = 20;
const RSDP_XSDT = 24;

/// The longest root there is: revision 2's is 36 bytes, and a length far
/// beyond that is a root written over.
const RSDP_MOST: u32 = 1024;

/// What the tables say, read from the root the firmware pointed at. A root
/// whose checksum does not hold, or that points at no list, gives facts
/// that say nothing - and the kernel says so rather than acting on
/// whatever was there.
pub fn read(rsdp: usize) Facts {
    var facts: Facts = .{};
    const root = rootAt(rsdp) orelse return facts;
    facts.revision = root.revision;
    facts.found = true;
    facts.listed = root.count;
    var index: u32 = 0;
    while (index < root.count) : (index += 1) {
        const table = root.table(index);
        if (table == 0) continue;
        const length = longAt(table + HEADER_LENGTH);
        if (!sound(table, length)) continue;
        if (named(table, "APIC")) takeInterrupts(&facts, table, length);
        if (named(table, "FACP")) takeFixed(&facts, table);
        if (named(table, "MCFG")) takeConfigSpace(&facts, table, length);
        if (named(table, "HPET")) takeHpet(&facts, table, length);
        if (named(table, "VFCT")) facts.vfct = table;
    }
    return facts;
}

// --- the walk ----------------------------------------------------------------------

/// The root and the list of tables it points at, found and checked.
pub const Root = struct {
    /// Where the root itself is, its revision, and how many of its bytes
    /// hold: 20 for the old root, its own figure for a newer one whose
    /// whole checksum holds.
    at: usize = 0,
    revision: u8 = 0,
    length: u32 = 0,
    /// The list of tables: the one with 64-bit pointers (XSDT) where the
    /// root has one, the 32-bit one (RSDT) otherwise; and how many
    /// tables it lists.
    list: usize = 0,
    wide: bool = false,
    count: u32 = 0,

    /// Where the list's `index`th table is, 0 the first: 0 where the
    /// list has none there.
    pub fn table(root: *const Root, index: u32) usize {
        if (index >= root.count) return 0;
        const stride: usize = if (root.wide) 8 else 4;
        const at = root.list + HEADER_SIZE + @as(usize, index) * stride;
        return if (root.wide) @intCast(quadAt(at)) else longAt(at);
    }

    /// The `nth` table, 0 the first, of those the list has with
    /// `signature` and whose checksum holds: 0 where there are fewer.
    pub fn find(root: *const Root, signature: *const [4]u8, nth: u32) usize {
        var seen: u32 = 0;
        var index: u32 = 0;
        while (index < root.count) : (index += 1) {
            const at = root.table(index);
            if (at == 0 or !named(at, signature)) continue;
            if (!sound(at, longAt(at + HEADER_LENGTH))) continue;
            if (seen == nth) return at;
            seen += 1;
        }
        return 0;
    }
};

/// The root at `rsdp`, checked: its signature, its checksums, and the
/// list it points at, with that list's own signature and checksum. The
/// first twenty bytes are the old root and sum on their own; the rest of
/// a newer one sums with them, and the newer list is taken only where
/// that holds. Null where there is no root, or no list that holds.
pub fn rootAt(rsdp: usize) ?Root {
    if (rsdp == 0) return null;
    if (!named(rsdp, RSDP_SIGNATURE)) return null;
    if (!sums(rsdp, 20)) return null;
    var root: Root = .{ .at = rsdp, .revision = byteAt(rsdp + RSDP_REVISION), .length = 20 };
    if (root.revision >= 2) {
        const length = longAt(rsdp + RSDP_LENGTH);
        if (length >= 33 and length <= RSDP_MOST and sums(rsdp, length)) {
            root.length = length;
            const xsdt = quadAt(rsdp + RSDP_XSDT);
            if (xsdt != 0) {
                root.list = @intCast(xsdt);
                root.wide = true;
            }
        }
    }
    if (root.list == 0) root.list = longAt(rsdp + RSDP_RSDT);
    if (root.list == 0) return null;
    if (!named(root.list, if (root.wide) "XSDT" else "RSDT")) return null;
    const list_length = longAt(root.list + HEADER_LENGTH);
    if (!sound(root.list, list_length)) return null;
    const stride: u32 = if (root.wide) 8 else 4;
    root.count = (list_length - HEADER_SIZE) / stride;
    return root;
}

/// What a table's header says.
pub const Header = struct {
    /// Its four letters: "FACP", "DSDT", "SSDT", ...
    signature: [4]u8 = @splat(0),
    /// How many bytes the table is, its header among them.
    length: u32 = 0,
    revision: u8 = 0,
    /// Whether its length is one a table can have and its bytes sum to
    /// zero.
    sound: bool = false,
    /// Who made it: the maker's six letters, the maker's eight for this
    /// table, and the table's revision by the maker's count.
    oem: [6]u8 = @splat(0),
    oem_table: [8]u8 = @splat(0),
    oem_revision: u32 = 0,
    /// What it was made with - for a table of bytecode, the compiler's
    /// four letters - and that tool's revision.
    creator: [4]u8 = @splat(0),
    creator_revision: u32 = 0,
};

/// The header of the table at `table`, which must be one the root or the
/// fixed description points at.
pub fn headerOf(table: usize) Header {
    var header: Header = .{};
    for (&header.signature, 0..) |*char, index| char.* = byteAt(table + index);
    header.length = longAt(table + HEADER_LENGTH);
    header.revision = byteAt(table + HEADER_REVISION);
    for (&header.oem, 0..) |*char, index| char.* = byteAt(table + HEADER_OEM + index);
    for (&header.oem_table, 0..) |*char, index| char.* = byteAt(table + HEADER_OEM_TABLE + index);
    header.oem_revision = longAt(table + HEADER_OEM_REVISION);
    for (&header.creator, 0..) |*char, index| char.* = byteAt(table + HEADER_CREATOR + index);
    header.creator_revision = longAt(table + HEADER_CREATOR_REVISION);
    header.sound = sound(table, header.length);
    return header;
}

/// Where the fixed description (FACP) at `fadt` points for the table of
/// the machine's bytecode the root does not list (DSDT): its 64-bit field
/// where the table is long enough to have one and it is not 0, its
/// 32-bit field otherwise. 0 where it points nowhere.
pub fn dsdtOf(fadt: usize) usize {
    if (wideField(fadt, FADT_X_DSDT)) |at| return at;
    return narrowField(fadt, FADT_DSDT);
}

/// Where the fixed description at `fadt` points for the firmware's
/// control structure (FACS): its 32-bit field where it is not 0, its
/// 64-bit one otherwise. Firmware that fills in both, and differently,
/// has been found to wake only from the structure the 32-bit field
/// names. 0 where it points nowhere.
pub fn facsOf(fadt: usize) usize {
    const narrow = narrowField(fadt, FADT_FIRMWARE_CTRL);
    if (narrow != 0) return narrow;
    return wideField(fadt, FADT_X_FIRMWARE_CTRL) orelse 0;
}

/// How long the control structure at `facs` says it is - it has a
/// signature and a length of its own but none of a table's other
/// header, and no checksum: 0 where it is not one.
pub fn facsLength(facs: usize) u32 {
    if (facs == 0 or !named(facs, "FACS")) return 0;
    const length = longAt(facs + HEADER_LENGTH);
    if (length < FACS_LEAST or length > MOST_TABLE_BYTES) return 0;
    return length;
}

/// The control structure's version, 0 where `facs` is not one.
pub fn facsVersion(facs: usize) u8 {
    if (facsLength(facs) == 0) return 0;
    return byteAt(facs + FACS_VERSION);
}

/// The fixed description's pointers to the two tables the root does not
/// list, each with a 32-bit field from the first revision and a 64-bit
/// one later; and the control structure's own few fields.
const FADT_FIRMWARE_CTRL = 36;
const FADT_DSDT = 40;
const FADT_X_FIRMWARE_CTRL = 132;
const FADT_X_DSDT = 140;
const FACS_LEAST: u32 = 64;
const FACS_VERSION = 32;

fn wideField(fadt: usize, offset: u32) ?usize {
    if (longAt(fadt + HEADER_LENGTH) < offset + 8) return null;
    const at = quadAt(fadt + offset);
    return if (at != 0) @intCast(at) else null;
}

fn narrowField(fadt: usize, offset: u32) usize {
    if (longAt(fadt + HEADER_LENGTH) < offset + 4) return 0;
    return longAt(fadt + offset);
}

// --- the fixed description, whole --------------------------------------------------

/// A register as the tables give it from their second revision on (a
/// generic address): the space it is in, how many of its bits there are
/// and where they start, how wide each access to it is, and its address
/// in that space. A register that is not there has address 0.
pub const Register = struct {
    /// SPACE_*.
    space_id: u8 = 0,
    bit_width: u8 = 0,
    bit_offset: u8 = 0,
    /// ACCESS_*.
    access_size: u8 = 0,
    address: u64 = 0,

    /// Whether the register is there at all.
    pub fn present(register: Register) bool {
        return register.address != 0;
    }

    /// The register's port: null where it is not there, or is in another
    /// space than the I/O ports.
    pub fn ioPort(register: Register) ?u16 {
        if (register.space_id != SPACE_SYSTEM_IO or register.address == 0 or register.address > 0xFFFF) return null;
        return @intCast(register.address);
    }
};

/// The spaces a register, or a region the bytecode declares, is in.
pub const SPACE_SYSTEM_MEMORY: u8 = 0;
pub const SPACE_SYSTEM_IO: u8 = 1;
pub const SPACE_PCI_CONFIG: u8 = 2;
pub const SPACE_EMBEDDED_CONTROL: u8 = 3;
pub const SPACE_SMBUS: u8 = 4;
pub const SPACE_SYSTEM_CMOS: u8 = 5;
pub const SPACE_PCI_BAR_TARGET: u8 = 6;
pub const SPACE_IPMI: u8 = 7;
pub const SPACE_GENERAL_PURPOSE_IO: u8 = 8;
pub const SPACE_GENERIC_SERIAL_BUS: u8 = 9;
pub const SPACE_PCC: u8 = 0x0A;
pub const SPACE_PRM: u8 = 0x0B;
pub const SPACE_FUNCTIONAL_FIXED: u8 = 0x7F;

/// How wide each access to a register is: left to the register
/// (ACCESS_UNDEFINED), or 1, 2, 4 or 8 bytes.
pub const ACCESS_UNDEFINED: u8 = 0;
pub const ACCESS_BYTE: u8 = 1;
pub const ACCESS_WORD: u8 = 2;
pub const ACCESS_DWORD: u8 = 3;
pub const ACCESS_QWORD: u8 = 4;

fn registerAt(at: usize) Register {
    return .{
        .space_id = byteAt(at),
        .bit_width = byteAt(at + 1),
        .bit_offset = byteAt(at + 2),
        .access_size = byteAt(at + 3),
        .address = quadAt(at + 4),
    };
}

/// What the fixed description (FACP) holds that the system acts on: the
/// power management hardware's register blocks and the general events',
/// the line the hardware raises and the port it is put into this mode on,
/// the battery-backed clock's alarm registers, the register a restart is
/// asked through, the sleep registers of a machine without the fixed
/// hardware, the flags and the boot architecture's, and the two tables it
/// points at. Each field is named as the table names it; one the table is
/// too short to have is as `Fadt` sets it.
pub const Fadt = struct {
    revision: u8 = 0,
    /// The revision's second number, from 5.1 on; 0 before.
    minor_version: u8 = 0,
    length: u32 = 0,
    /// The two tables the root does not list (`dsdtOf`, `facsOf`).
    dsdt: usize = 0,
    facs: usize = 0,
    /// What its maker says the machine is: 1 a desktop, 2 a mobile one, 3
    /// a workstation, 4 an enterprise server, 5 a small office's server,
    /// 6 an appliance, 7 a performance server, 8 a tablet; 0 unspecified.
    preferred_pm_profile: u8 = 0,
    /// The interrupt line the hardware raises, as a controller input.
    sci_int: u16 = 0,
    /// The port the hardware is put into this mode on, and taken out of
    /// it again; what is written there for each, what says the system
    /// takes over the cores' performance states, and what says it reads
    /// their idle states from `_CST`. A value of 0 is nothing to write.
    smi_cmd: u32 = 0,
    acpi_enable: u8 = 0,
    acpi_disable: u8 = 0,
    pstate_cnt: u8 = 0,
    cst_cnt: u8 = 0,
    /// The register blocks - events (a status half, then an enable half),
    /// control, the second control block, the timer - and how many bytes
    /// each one's port field says it has. A machine with one block of a
    /// pair has no `b`.
    pm1a_evt_blk: Register = .{},
    pm1b_evt_blk: Register = .{},
    pm1a_cnt_blk: Register = .{},
    pm1b_cnt_blk: Register = .{},
    pm2_cnt_blk: Register = .{},
    pm_tmr_blk: Register = .{},
    pm1_evt_len: u8 = 0,
    pm1_cnt_len: u8 = 0,
    pm2_cnt_len: u8 = 0,
    pm_tmr_len: u8 = 0,
    /// The two blocks of general events, each a status half and an enable
    /// half, `gpe0_blk_len` and `gpe1_blk_len` bytes in all; the second's
    /// events are numbered from `gpe1_base`.
    gpe0_blk: Register = .{},
    gpe1_blk: Register = .{},
    gpe0_blk_len: u8 = 0,
    gpe1_blk_len: u8 = 0,
    gpe1_base: u8 = 0,
    /// The battery-backed clock's registers for an alarm's day of the
    /// month and its month, and the century's; 0 where it has none.
    day_alrm: u8 = 0,
    mon_alrm: u8 = 0,
    century: u8 = 0,
    /// BOOT_*.
    iapc_boot_arch: u16 = 0,
    /// FLAG_*.
    flags: u32 = 0,
    /// Where a restart is asked for, and what is written there; only
    /// where FLAG_RESET_REG_SUP is set.
    reset_reg: Register = .{},
    reset_value: u8 = 0,
    /// The sleep registers of a machine without the fixed hardware
    /// (FLAG_HW_REDUCED_ACPI).
    sleep_control_reg: Register = .{},
    sleep_status_reg: Register = .{},
};

/// The fixed description's flags.
pub const FLAG_WBINVD: u32 = 1 << 0;
pub const FLAG_WBINVD_FLUSH: u32 = 1 << 1;
pub const FLAG_PROC_C1: u32 = 1 << 2;
pub const FLAG_P_LVL2_UP: u32 = 1 << 3;
/// The power button, and the sleep button, are devices the bytecode
/// describes rather than fixed features of the hardware.
pub const FLAG_PWR_BUTTON: u32 = 1 << 4;
pub const FLAG_SLP_BUTTON: u32 = 1 << 5;
/// The clock's alarm is not reported in the fixed event block.
pub const FLAG_FIX_RTC: u32 = 1 << 6;
pub const FLAG_RTC_S4: u32 = 1 << 7;
/// The timer's counter is 32 bits, not 24.
pub const FLAG_TMR_VAL_EXT: u32 = 1 << 8;
pub const FLAG_DCK_CAP: u32 = 1 << 9;
pub const FLAG_RESET_REG_SUP: u32 = 1 << 10;
pub const FLAG_SEALED_CASE: u32 = 1 << 11;
pub const FLAG_HEADLESS: u32 = 1 << 12;
pub const FLAG_CPU_SW_SLP: u32 = 1 << 13;
pub const FLAG_PCI_EXP_WAK: u32 = 1 << 14;
pub const FLAG_USE_PLATFORM_CLOCK: u32 = 1 << 15;
pub const FLAG_S4_RTC_STS_VALID: u32 = 1 << 16;
pub const FLAG_REMOTE_POWER_ON_CAPABLE: u32 = 1 << 17;
pub const FLAG_FORCE_APIC_CLUSTER_MODEL: u32 = 1 << 18;
pub const FLAG_FORCE_APIC_PHYSICAL_DESTINATION_MODE: u32 = 1 << 19;
/// No fixed hardware: the sleep registers instead of its blocks.
pub const FLAG_HW_REDUCED_ACPI: u32 = 1 << 20;
/// The machine's low-power state is an idle one rather than a sleep
/// state.
pub const FLAG_LOW_POWER_S0_IDLE_CAPABLE: u32 = 1 << 21;

/// The boot architecture's flags.
pub const BOOT_LEGACY_DEVICES: u16 = 1 << 0;
pub const BOOT_8042: u16 = 1 << 1;
pub const BOOT_VGA_NOT_PRESENT: u16 = 1 << 2;
pub const BOOT_MSI_NOT_SUPPORTED: u16 = 1 << 3;
pub const BOOT_PCIE_ASPM_CONTROLS: u16 = 1 << 4;
pub const BOOT_CMOS_RTC_NOT_PRESENT: u16 = 1 << 5;

/// The rest of the fixed description's fields, beside those the kernel's
/// facts and the walk use further down.
const FADT_PROFILE = 45;
const FADT_MODE_OFF = 53;
const FADT_PSTATE = 55;
const FADT_PM2_CONTROL = 72;
const FADT_GPE0 = 80;
const FADT_GPE1 = 84;
const FADT_PM2_CONTROL_LENGTH = 90;
const FADT_GPE0_LENGTH = 92;
const FADT_GPE1_LENGTH = 93;
const FADT_GPE1_BASE = 94;
const FADT_CST = 95;
const FADT_DAY_ALARM = 106;
const FADT_MONTH_ALARM = 107;
const FADT_RESET = 116;
const FADT_RESET_VALUE = 128;
const FADT_MINOR = 131;
const FADT_X_PM1A_EVENT = 148;
const FADT_X_PM1B_EVENT = 160;
const FADT_X_PM1A_CONTROL = 172;
const FADT_X_PM1B_CONTROL = 184;
const FADT_X_PM2_CONTROL = 196;
const FADT_X_PM_TIMER = 208;
const FADT_X_GPE0 = 220;
const FADT_X_GPE1 = 232;
const FADT_SLEEP_CONTROL = 244;
const FADT_SLEEP_STATUS = 256;

/// The fixed description at `fadt`, read whole. A table too short for
/// the first revision's fields gives its revision and length and nothing
/// else.
pub fn readFadt(fadt: usize) Fadt {
    const length = longAt(fadt + HEADER_LENGTH);
    var fixed: Fadt = .{ .revision = byteAt(fadt + HEADER_REVISION), .length = length };
    if (length < FADT_FLAGS + 4 or length > MOST_TABLE_BYTES) return fixed;
    fixed.dsdt = dsdtOf(fadt);
    fixed.facs = facsOf(fadt);
    fixed.preferred_pm_profile = byteAt(fadt + FADT_PROFILE);
    fixed.sci_int = wordAt(fadt + FADT_SCI_LINE);
    fixed.smi_cmd = longAt(fadt + FADT_MODE_PORT);
    fixed.acpi_enable = byteAt(fadt + FADT_MODE_VALUE);
    fixed.acpi_disable = byteAt(fadt + FADT_MODE_OFF);
    fixed.pstate_cnt = byteAt(fadt + FADT_PSTATE);
    fixed.cst_cnt = byteAt(fadt + FADT_CST);
    fixed.pm1_evt_len = byteAt(fadt + FADT_PM1_EVENT_LENGTH);
    fixed.pm1_cnt_len = byteAt(fadt + FADT_PM1_CONTROL_LENGTH);
    fixed.pm2_cnt_len = byteAt(fadt + FADT_PM2_CONTROL_LENGTH);
    fixed.pm_tmr_len = byteAt(fadt + FADT_PM_TIMER_LENGTH);
    fixed.gpe0_blk_len = byteAt(fadt + FADT_GPE0_LENGTH);
    fixed.gpe1_blk_len = byteAt(fadt + FADT_GPE1_LENGTH);
    fixed.gpe1_base = byteAt(fadt + FADT_GPE1_BASE);
    fixed.pm1a_evt_blk = blockOf(fadt, length, FADT_X_PM1A_EVENT, FADT_PM1A_EVENT, fixed.pm1_evt_len);
    fixed.pm1b_evt_blk = blockOf(fadt, length, FADT_X_PM1B_EVENT, FADT_PM1B_EVENT, fixed.pm1_evt_len);
    fixed.pm1a_cnt_blk = blockOf(fadt, length, FADT_X_PM1A_CONTROL, FADT_PM1A_CONTROL, fixed.pm1_cnt_len);
    fixed.pm1b_cnt_blk = blockOf(fadt, length, FADT_X_PM1B_CONTROL, FADT_PM1B_CONTROL, fixed.pm1_cnt_len);
    fixed.pm2_cnt_blk = blockOf(fadt, length, FADT_X_PM2_CONTROL, FADT_PM2_CONTROL, fixed.pm2_cnt_len);
    fixed.pm_tmr_blk = blockOf(fadt, length, FADT_X_PM_TIMER, FADT_PM_TIMER, fixed.pm_tmr_len);
    fixed.gpe0_blk = blockOf(fadt, length, FADT_X_GPE0, FADT_GPE0, fixed.gpe0_blk_len);
    fixed.gpe1_blk = blockOf(fadt, length, FADT_X_GPE1, FADT_GPE1, fixed.gpe1_blk_len);
    fixed.day_alrm = byteAt(fadt + FADT_DAY_ALARM);
    fixed.mon_alrm = byteAt(fadt + FADT_MONTH_ALARM);
    fixed.century = byteAt(fadt + FADT_CENTURY);
    fixed.iapc_boot_arch = wordAt(fadt + FADT_PC_HARDWARE);
    fixed.flags = longAt(fadt + FADT_FLAGS);
    if (length >= FADT_RESET_VALUE + 1) {
        fixed.reset_reg = registerAt(fadt + FADT_RESET);
        fixed.reset_value = byteAt(fadt + FADT_RESET_VALUE);
    }
    if (length >= FADT_MINOR + 1) fixed.minor_version = byteAt(fadt + FADT_MINOR) & 0x0F;
    if (length >= FADT_SLEEP_STATUS + 12) {
        fixed.sleep_control_reg = registerAt(fadt + FADT_SLEEP_CONTROL);
        fixed.sleep_status_reg = registerAt(fadt + FADT_SLEEP_STATUS);
    }
    return fixed;
}

/// One of the fixed description's register blocks, which it gives twice:
/// a port in the first revision's field with its length in bytes beside
/// it, and from the second revision a register. The register where the
/// table is long enough to hold it and it is there - it says what the
/// port cannot: the space, the width, how it is reached - and the port
/// otherwise, as a register of the I/O space with as many bits as its
/// bytes make: 255 at most, all a register's width can say, for a block
/// of general events can be longer and is counted by its length.
fn blockOf(fadt: usize, length: u32, wide: u32, narrow: u32, bytes: u8) Register {
    if (length >= wide + 12) {
        const register = registerAt(fadt + wide);
        if (register.present()) return register;
    }
    if (length < narrow + 4) return .{};
    const port = longAt(fadt + narrow);
    if (port == 0) return .{};
    return .{ .space_id = SPACE_SYSTEM_IO, .bit_width = if (bytes > 31) 255 else bytes * 8, .address = port };
}

// --- the control structure ----------------------------------------------------------

/// What the firmware's control structure (FACS) holds: the machine's
/// hardware signature, which changes when its hardware does; where the
/// firmware goes on waking, as a 32-bit address and a 64-bit one; and the
/// lock the firmware and the system share. Each field is named as the
/// structure names it.
pub const Facs = struct {
    length: u32 = 0,
    version: u8 = 0,
    hardware_signature: u32 = 0,
    firmware_waking_vector: u32 = 0,
    x_firmware_waking_vector: u64 = 0,
    /// Where the lock's 32 bits are (LOCK_*): the structure's own field,
    /// which the system and the firmware both change in place.
    global_lock: usize = 0,
    /// FACS_S4BIOS_F, FACS_64BIT_WAKE_SUPPORTED_F.
    flags: u32 = 0,
    /// FACS_64BIT_WAKE_F.
    ospm_flags: u32 = 0,
};

/// The control structure's flags - the firmware can enter the deepest
/// sleep itself; it can wake into 64-bit code - and the one the system
/// sets in its own to have it do that.
pub const FACS_S4BIOS_F: u32 = 1 << 0;
pub const FACS_64BIT_WAKE_SUPPORTED_F: u32 = 1 << 1;
pub const FACS_64BIT_WAKE_F: u32 = 1 << 0;
/// The shared lock's two bits: someone waits for it; someone holds it.
pub const LOCK_PENDING: u32 = 1 << 0;
pub const LOCK_OWNED: u32 = 1 << 1;

const FACS_HARDWARE_SIGNATURE = 8;
const FACS_WAKING_VECTOR = 12;
const FACS_GLOBAL_LOCK = 16;
const FACS_FLAGS = 20;
const FACS_X_WAKING_VECTOR = 24;
const FACS_OSPM_FLAGS = 36;

/// The control structure at `facs`, or one that says nothing (length 0)
/// where there is none.
pub fn readFacs(facs: usize) Facs {
    const length = facsLength(facs);
    if (length == 0) return .{};
    return .{
        .length = length,
        .version = byteAt(facs + FACS_VERSION),
        .hardware_signature = longAt(facs + FACS_HARDWARE_SIGNATURE),
        .firmware_waking_vector = longAt(facs + FACS_WAKING_VECTOR),
        .x_firmware_waking_vector = quadAt(facs + FACS_X_WAKING_VECTOR),
        .global_lock = facs + FACS_GLOBAL_LOCK,
        .flags = longAt(facs + FACS_FLAGS),
        .ospm_flags = longAt(facs + FACS_OSPM_FLAGS),
    };
}

// --- the embedded controller's table ------------------------------------------------

/// The embedded controller as its own table (ECDT) gives it, for the
/// methods that read it before its device in the bytecode is reached: its
/// command and status register, its data register, the general event it
/// raises, and its device's path in the namespace. Each field is named as
/// the table names it.
pub const Ecdt = struct {
    ec_control: Register = .{},
    ec_data: Register = .{},
    uid: u32 = 0,
    gpe_bit: u8 = 0,
    /// Where the device's path is - the table's own text, read in place -
    /// and how many bytes it has before its NUL.
    ec_id: usize = 0,
    ec_id_length: u32 = 0,
};

const ECDT_CONTROL = HEADER_SIZE;
const ECDT_DATA = HEADER_SIZE + 12;
const ECDT_UID = HEADER_SIZE + 24;
const ECDT_GPE = HEADER_SIZE + 28;
const ECDT_ID = HEADER_SIZE + 29;

/// The embedded controller's table at `ecdt`; one that says nothing - no
/// register there - where it is too short to be one.
pub fn readEcdt(ecdt: usize) Ecdt {
    const length = longAt(ecdt + HEADER_LENGTH);
    if (length < ECDT_ID + 1 or length > MOST_TABLE_BYTES) return .{};
    var controller: Ecdt = .{
        .ec_control = registerAt(ecdt + ECDT_CONTROL),
        .ec_data = registerAt(ecdt + ECDT_DATA),
        .uid = longAt(ecdt + ECDT_UID),
        .gpe_bit = byteAt(ecdt + ECDT_GPE),
        .ec_id = ecdt + ECDT_ID,
    };
    var count: u32 = 0;
    while (ECDT_ID + count < length and byteAt(controller.ec_id + count) != 0) count += 1;
    controller.ec_id_length = count;
    return controller;
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
    facts.madt = table;
    facts.madt_length = length;
    var at = table + MADT_ENTRIES;
    const end = table + length;
    while (at + 2 <= end) {
        const kind = byteAt(at);
        const size = byteAt(at + 1);
        if (size < 2 or at + size > end) break;
        switch (kind) {
            MADT_LOCAL => if (size >= 8) {
                if (longAt(at + 4) & (CORE_ENABLED | CORE_CAPABLE) != 0) facts.core_count += 1;
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
                if (longAt(at + 8) & (CORE_ENABLED | CORE_CAPABLE) != 0) facts.core_count += 1;
            },
            else => {},
        }
        at += size;
    }
}

/// The fixed description's fields the kernel takes and the walk reads:
/// the timer whose rate the architecture fixes, the battery-backed clock's
/// century and the flags of the hardware a PC has always had, the power
/// management hardware - the line it raises, the port it is put into this
/// mode on and what is written there, its two pairs of register blocks
/// with their lengths - and the flags.
const FADT_PM_TIMER = 76;
const FADT_PM_TIMER_LENGTH = 91;
const FADT_CENTURY = 108;
const FADT_PC_HARDWARE = 109;
const FADT_FLAGS = 112;
const FADT_SCI_LINE = 46;
const FADT_MODE_PORT = 48;
const FADT_MODE_VALUE = 52;
const FADT_PM1A_EVENT = 56;
const FADT_PM1B_EVENT = 60;
const FADT_PM1A_CONTROL = 64;
const FADT_PM1B_CONTROL = 68;
const FADT_PM1_EVENT_LENGTH = 88;
const FADT_PM1_CONTROL_LENGTH = 89;

/// What the kernel takes of the fixed description (`readFadt`): the
/// timer's port and how many bits of its counter count, whether the
/// machine has the battery-backed clock and which of its registers holds
/// the century, and the power management hardware. A table too short for
/// the first revision's flags says nothing about any of them.
fn takeFixed(facts: *Facts, table: usize) void {
    const fixed = readFadt(table);
    if (fixed.length < FADT_FLAGS + 4) return;
    facts.rtc_century = fixed.century;
    facts.rtc = fixed.iapc_boot_arch & BOOT_CMOS_RTC_NOT_PRESENT == 0;
    takePower(facts, &fixed);
    if (fixed.pm_tmr_len != 4) return;
    facts.pm_timer_port = fixed.pm_tmr_blk.ioPort() orelse return;
    facts.pm_timer_bits = if (fixed.flags & FLAG_TMR_VAL_EXT != 0) 32 else 24;
}

/// The power management hardware: the blocks it is reached through, taken
/// where they are ports - which on every machine of this architecture they
/// are - the line it raises, and whether its power button is one of its
/// fixed features.
fn takePower(facts: *Facts, fixed: *const Fadt) void {
    facts.pm1_event = fixed.pm1a_evt_blk.ioPort() orelse return;
    facts.pm1_control = fixed.pm1a_cnt_blk.ioPort() orelse return;
    facts.pm1_event2 = fixed.pm1b_evt_blk.ioPort() orelse 0;
    facts.pm1_control2 = fixed.pm1b_cnt_blk.ioPort() orelse 0;
    facts.pm1_event_bytes = fixed.pm1_evt_len;
    facts.pm1_control_bytes = fixed.pm1_cnt_len;
    facts.sci_line = fixed.sci_int;
    if (fixed.smi_cmd != 0 and fixed.smi_cmd <= 0xFFFF and fixed.acpi_enable != 0) {
        facts.mode_port = @intCast(fixed.smi_cmd);
        facts.mode_value = fixed.acpi_enable;
    }
    facts.fixed_power_button = fixed.flags & FLAG_PWR_BUTTON == 0;
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
