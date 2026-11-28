// SPDX-License-Identifier: MIT
//! What Acpi FIXED shows: the fixed description read whole - each register
//! block with its space, address and width, the line the hardware raises
//! and the port it is put into its mode on, the clock's alarm registers,
//! the reset register, the flags and the boot architecture's by their
//! names - then the control structure it points at, and the embedded
//! controller's table where the list has one. Each field is shown under
//! the name the tables give it, so that what is shown can be held against
//! the specification and against a disassembler's reading of the same
//! bytes.

const sdk = @import("sdk");
const dos = sdk.dos;
const acpi = sdk.hardware.acpi;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

/// A flag and the name the tables give it.
const Named = struct {
    bit: u32,
    name: [*:0]const u8,
};

const flag_names = [_]Named{
    .{ .bit = acpi.FLAG_WBINVD, .name = "WBINVD" },
    .{ .bit = acpi.FLAG_WBINVD_FLUSH, .name = "WBINVD_FLUSH" },
    .{ .bit = acpi.FLAG_PROC_C1, .name = "PROC_C1" },
    .{ .bit = acpi.FLAG_P_LVL2_UP, .name = "P_LVL2_UP" },
    .{ .bit = acpi.FLAG_PWR_BUTTON, .name = "PWR_BUTTON" },
    .{ .bit = acpi.FLAG_SLP_BUTTON, .name = "SLP_BUTTON" },
    .{ .bit = acpi.FLAG_FIX_RTC, .name = "FIX_RTC" },
    .{ .bit = acpi.FLAG_RTC_S4, .name = "RTC_S4" },
    .{ .bit = acpi.FLAG_TMR_VAL_EXT, .name = "TMR_VAL_EXT" },
    .{ .bit = acpi.FLAG_DCK_CAP, .name = "DCK_CAP" },
    .{ .bit = acpi.FLAG_RESET_REG_SUP, .name = "RESET_REG_SUP" },
    .{ .bit = acpi.FLAG_SEALED_CASE, .name = "SEALED_CASE" },
    .{ .bit = acpi.FLAG_HEADLESS, .name = "HEADLESS" },
    .{ .bit = acpi.FLAG_CPU_SW_SLP, .name = "CPU_SW_SLP" },
    .{ .bit = acpi.FLAG_PCI_EXP_WAK, .name = "PCI_EXP_WAK" },
    .{ .bit = acpi.FLAG_USE_PLATFORM_CLOCK, .name = "USE_PLATFORM_CLOCK" },
    .{ .bit = acpi.FLAG_S4_RTC_STS_VALID, .name = "S4_RTC_STS_VALID" },
    .{ .bit = acpi.FLAG_REMOTE_POWER_ON_CAPABLE, .name = "REMOTE_POWER_ON_CAPABLE" },
    .{ .bit = acpi.FLAG_FORCE_APIC_CLUSTER_MODEL, .name = "FORCE_APIC_CLUSTER_MODEL" },
    .{ .bit = acpi.FLAG_FORCE_APIC_PHYSICAL_DESTINATION_MODE, .name = "FORCE_APIC_PHYSICAL_DESTINATION_MODE" },
    .{ .bit = acpi.FLAG_HW_REDUCED_ACPI, .name = "HW_REDUCED_ACPI" },
    .{ .bit = acpi.FLAG_LOW_POWER_S0_IDLE_CAPABLE, .name = "LOW_POWER_S0_IDLE_CAPABLE" },
};

const boot_names = [_]Named{
    .{ .bit = acpi.BOOT_LEGACY_DEVICES, .name = "LEGACY_DEVICES" },
    .{ .bit = acpi.BOOT_8042, .name = "8042" },
    .{ .bit = acpi.BOOT_VGA_NOT_PRESENT, .name = "VGA_NOT_PRESENT" },
    .{ .bit = acpi.BOOT_MSI_NOT_SUPPORTED, .name = "MSI_NOT_SUPPORTED" },
    .{ .bit = acpi.BOOT_PCIE_ASPM_CONTROLS, .name = "PCIE_ASPM_CONTROLS" },
    .{ .bit = acpi.BOOT_CMOS_RTC_NOT_PRESENT, .name = "CMOS_RTC_NOT_PRESENT" },
};

const facs_names = [_]Named{
    .{ .bit = acpi.FACS_S4BIOS_F, .name = "S4BIOS_F" },
    .{ .bit = acpi.FACS_64BIT_WAKE_SUPPORTED_F, .name = "64BIT_WAKE_SUPPORTED_F" },
};

const lock_names = [_]Named{
    .{ .bit = acpi.LOCK_PENDING, .name = "pending" },
    .{ .bit = acpi.LOCK_OWNED, .name = "owned" },
};

/// The fixed description the list names first, the control structure it
/// points at, and the embedded controller's table: false where the list
/// names no fixed description whose checksum holds.
pub fn show(dl: *DosBase, root: *const acpi.Root) bool {
    const at = root.find("FACP", 0);
    if (at == 0) {
        _ = dl.PutStr("no fixed description: the list names none whose checksum holds\n");
        return false;
    }
    const fixed = acpi.readFadt(at);
    _ = Printf(dl, "FACP at 0x%016lx: revision %u.%u, %u bytes, %s\n", .{
        @as(u64, at), @as(u32, fixed.revision),                @as(u32, fixed.minor_version),
        fixed.length, profileName(fixed.preferred_pm_profile),
    });
    _ = Printf(dl, "  %-18s%u\n", .{ @as([*:0]const u8, "SCI_INT"), @as(u32, fixed.sci_int) });
    _ = Printf(dl, "  %-18s0x%x: ACPI_ENABLE 0x%x, ACPI_DISABLE 0x%x, PSTATE_CNT 0x%x, CST_CNT 0x%x\n", .{
        @as([*:0]const u8, "SMI_CMD"), fixed.smi_cmd,              @as(u32, fixed.acpi_enable),
        @as(u32, fixed.acpi_disable),  @as(u32, fixed.pstate_cnt), @as(u32, fixed.cst_cnt),
    });
    printBlock(dl, "PM1a_EVT_BLK", fixed.pm1a_evt_blk, fixed.pm1_evt_len);
    printBlock(dl, "PM1b_EVT_BLK", fixed.pm1b_evt_blk, fixed.pm1_evt_len);
    printBlock(dl, "PM1a_CNT_BLK", fixed.pm1a_cnt_blk, fixed.pm1_cnt_len);
    printBlock(dl, "PM1b_CNT_BLK", fixed.pm1b_cnt_blk, fixed.pm1_cnt_len);
    printBlock(dl, "PM2_CNT_BLK", fixed.pm2_cnt_blk, fixed.pm2_cnt_len);
    printBlock(dl, "PM_TMR_BLK", fixed.pm_tmr_blk, fixed.pm_tmr_len);
    printEvents(dl, "GPE0_BLK", fixed.gpe0_blk, fixed.gpe0_blk_len, 0);
    printEvents(dl, "GPE1_BLK", fixed.gpe1_blk, fixed.gpe1_blk_len, fixed.gpe1_base);
    _ = Printf(dl, "  %-18s0x%x, MON_ALRM 0x%x, CENTURY 0x%x\n", .{
        @as([*:0]const u8, "DAY_ALRM"), @as(u32, fixed.day_alrm), @as(u32, fixed.mon_alrm), @as(u32, fixed.century),
    });
    printRegister(dl, "RESET_REG", fixed.reset_reg);
    if (fixed.reset_reg.present()) _ = Printf(dl, "  %-18s0x%x\n", .{ @as([*:0]const u8, "RESET_VALUE"), @as(u32, fixed.reset_value) });
    printRegister(dl, "SLEEP_CONTROL_REG", fixed.sleep_control_reg);
    printRegister(dl, "SLEEP_STATUS_REG", fixed.sleep_status_reg);
    printFlags(dl, "IAPC_BOOT_ARCH", fixed.iapc_boot_arch, &boot_names);
    printFlags(dl, "Flags", fixed.flags, &flag_names);
    showFacs(dl, fixed.facs);
    const ecdt = root.find("ECDT", 0);
    if (ecdt != 0) showEcdt(dl, ecdt);
    return true;
}

/// What its maker says the machine is.
fn profileName(profile: u8) [*:0]const u8 {
    return switch (profile) {
        0 => "profile unspecified",
        1 => "a desktop",
        2 => "a mobile machine",
        3 => "a workstation",
        4 => "an enterprise server",
        5 => "a small office's server",
        6 => "an appliance",
        7 => "a performance server",
        8 => "a tablet",
        else => "a profile not known here",
    };
}

/// A register's line: its space and address, its width and first bit,
/// how wide each access is; "-" where it is not there.
fn printRegister(dl: *DosBase, label: [*:0]const u8, register: acpi.Register) void {
    _ = Printf(dl, "  %-18s", .{label});
    _ = describe(dl, register);
    _ = dl.PutStr("\n");
}

/// A register block's line, and the length its port field gives it.
fn printBlock(dl: *DosBase, label: [*:0]const u8, register: acpi.Register, bytes: u8) void {
    _ = Printf(dl, "  %-18s", .{label});
    if (describe(dl, register)) _ = Printf(dl, "; %u %s", .{ @as(u32, bytes), byteWord(bytes) });
    _ = dl.PutStr("\n");
}

/// A block of general events' line, its length and the events it holds:
/// a status half and an enable half, eight events to a byte of each.
fn printEvents(dl: *DosBase, label: [*:0]const u8, register: acpi.Register, bytes: u8, first: u8) void {
    _ = Printf(dl, "  %-18s", .{label});
    if (describe(dl, register)) {
        const events: u32 = @as(u32, bytes) / 2 * 8;
        if (events == 0) {
            _ = Printf(dl, "; %u bytes, no events", .{@as(u32, bytes)});
        } else {
            _ = Printf(dl, "; %u bytes, events %u to %u", .{ @as(u32, bytes), @as(u32, first), @as(u32, first) + events - 1 });
        }
    }
    _ = dl.PutStr("\n");
}

/// The register, in a line already begun: false, and "-", where it is not
/// there.
fn describe(dl: *DosBase, register: acpi.Register) bool {
    if (!register.present()) {
        _ = dl.PutStr("-");
        return false;
    }
    if (spaceName(register.space_id)) |name| {
        _ = Printf(dl, "%s 0x%lx", .{ name, register.address });
    } else {
        _ = Printf(dl, "space 0x%x at 0x%lx", .{ @as(u32, register.space_id), register.address });
    }
    _ = Printf(dl, ", %u bits", .{@as(u32, register.bit_width)});
    if (register.bit_offset != 0) _ = Printf(dl, " from bit %u", .{@as(u32, register.bit_offset)});
    if (register.access_size >= acpi.ACCESS_BYTE and register.access_size <= acpi.ACCESS_QWORD) {
        const each = @as(u32, 1) << @intCast(register.access_size - 1);
        _ = Printf(dl, ", %u %s at a time", .{ each, byteWord(each) });
    }
    return true;
}

/// A set of flags' line: the value, then the name of each that is set,
/// and what is set that has no name.
fn printFlags(dl: *DosBase, label: [*:0]const u8, value: u32, names: []const Named) void {
    _ = Printf(dl, "  %-18s", .{label});
    describeFlags(dl, value, names);
    _ = dl.PutStr("\n");
}

/// Flags in a line already begun.
fn describeFlags(dl: *DosBase, value: u32, names: []const Named) void {
    _ = Printf(dl, "0x%08x", .{value});
    var rest = value;
    for (names) |entry| {
        if (value & entry.bit == 0) continue;
        _ = Printf(dl, " %s", .{entry.name});
        rest &= ~entry.bit;
    }
    if (rest != 0) _ = Printf(dl, " and 0x%x", .{rest});
}

fn byteWord(count: u32) [*:0]const u8 {
    return if (count == 1) "byte" else "bytes";
}

fn spaceName(space: u8) ?[*:0]const u8 {
    return switch (space) {
        acpi.SPACE_SYSTEM_MEMORY => "memory",
        acpi.SPACE_SYSTEM_IO => "io",
        acpi.SPACE_PCI_CONFIG => "pci",
        acpi.SPACE_EMBEDDED_CONTROL => "ec",
        acpi.SPACE_SMBUS => "smbus",
        acpi.SPACE_SYSTEM_CMOS => "cmos",
        acpi.SPACE_PCI_BAR_TARGET => "pci bar",
        acpi.SPACE_IPMI => "ipmi",
        acpi.SPACE_GENERAL_PURPOSE_IO => "gpio",
        acpi.SPACE_GENERIC_SERIAL_BUS => "serial bus",
        acpi.SPACE_PCC => "pcc",
        acpi.SPACE_PRM => "prm",
        acpi.SPACE_FUNCTIONAL_FIXED => "fixed hardware",
        else => null,
    };
}

/// The control structure: its version and length, the machine's hardware
/// signature, where the firmware goes on waking, the shared lock as it
/// stands now, and the flags.
fn showFacs(dl: *DosBase, at: usize) void {
    const control = acpi.readFacs(at);
    if (control.length == 0) {
        if (at != 0) _ = Printf(dl, "FACS: the fixed description points at 0x%016lx, where there is none\n", .{@as(u64, at)});
        return;
    }
    _ = Printf(dl, "FACS at 0x%016lx: version %u, %u bytes\n", .{ @as(u64, at), @as(u32, control.version), control.length });
    _ = Printf(dl, "  %-26s0x%08x\n", .{ @as([*:0]const u8, "Hardware Signature"), control.hardware_signature });
    _ = Printf(dl, "  %-26s0x%08x\n", .{ @as([*:0]const u8, "Firmware_Waking_Vector"), control.firmware_waking_vector });
    _ = Printf(dl, "  %-26s0x%016lx\n", .{ @as([*:0]const u8, "X_Firmware_Waking_Vector"), control.x_firmware_waking_vector });
    // The lock changes under the firmware's hands as much as under the
    // system's: read once, as it is now.
    const lock = @as(*align(1) const volatile u32, @ptrFromInt(control.global_lock)).*;
    _ = Printf(dl, "  %-26s", .{@as([*:0]const u8, "Global_Lock")});
    describeFlags(dl, lock, &lock_names);
    _ = Printf(dl, ", at 0x%016lx\n", .{@as(u64, control.global_lock)});
    _ = Printf(dl, "  %-26s", .{@as([*:0]const u8, "Flags")});
    describeFlags(dl, control.flags, &facs_names);
    _ = dl.PutStr("\n");
    _ = Printf(dl, "  %-26s0x%08x\n", .{ @as([*:0]const u8, "OSPM Flags"), control.ospm_flags });
}

/// Room for the embedded controller's path, shown; a longer one is cut.
const PATH_ROOM = 96;

/// The embedded controller's table: its device's path, its two registers
/// and the general event it raises.
fn showEcdt(dl: *DosBase, at: usize) void {
    const controller = acpi.readEcdt(at);
    if (!controller.ec_control.present()) {
        _ = Printf(dl, "ECDT at 0x%016lx: too short to say anything\n", .{@as(u64, at)});
        return;
    }
    var path: [PATH_ROOM:0]u8 = @splat(0);
    const text: [*]const u8 = @ptrFromInt(controller.ec_id);
    const count = @min(controller.ec_id_length, PATH_ROOM);
    for (text[0..count], 0..) |char, index| path[index] = if (char >= 0x20 and char < 0x7F) char else '?';
    _ = Printf(dl, "ECDT at 0x%016lx: EC_ID %s, UID %u, GPE_BIT 0x%x\n", .{
        @as(u64, at), @as([*:0]const u8, &path), controller.uid, @as(u32, controller.gpe_bit),
    });
    printRegister(dl, "EC_CONTROL", controller.ec_control);
    printRegister(dl, "EC_DATA", controller.ec_data);
}
