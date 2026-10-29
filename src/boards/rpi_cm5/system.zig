// SPDX-License-Identifier: MPL-2.0
//! The Raspberry Pi Compute Module 5 on its IO board: a BCM2712 - four
//! Cortex-A76 cores and a GIC-400 - with its RAM from address 0, started
//! by the bootloader in its EEPROM and Trusted Firmware, which enter the
//! kernel at EL2, PSCI by SMC. The bootloader reads config.txt from the
//! eMMC's FAT partition (`config.txt` beside this file): it loads
//! kernel.bin at 2 MiB - nothing above RAM's first GiB, so not at
//! 0x40200000, where the kernel copies itself (start.S) - and the disk
//! image where config.txt puts it, and its device tree names RAM - in
//! pieces - the disk image, and the firmware's own memory at the start of
//! RAM (/reserved-memory).
//!
//! The console is the RP1's UART0 on pins 8 and 10 of the 40-pin header
//! (GPIO14 and 15), 115200 8N1: a PL011 with a 50 MHz clock, behind the
//! RP1's PCI Express link. The bootloader sets it up and leaves the RP1
//! running for the kernel (`enable_rp1_uart=1`, `pciex4_reset=0`), its
//! registers at 0x1C_0003_0000: the RP1's peripherals are where the
//! bootloader's outbound window puts them, as it says on the UART
//! ("RP1_UART"); Linux moves them to 0x1F_0003_0000. Its interrupt, RP1
//! source 25, comes as an MSI-X message, on the GIC as interrupt 185
//! (`rp1.zig`). The GIC-400's distributor is at 0x10_7FFF_9000 and its
//! CPU interface at 0x10_7FFF_A000; the system counter runs at 54 MHz.
//!
//! What is true of the board is written down here once, as the system tag
//! list the ROM carries for expansion.library (a part per SYSTAG_Part). The
//! kernel reads the same list at compile time (`boards.fact`).

const sdk = @import("sdk");
const exec = sdk.exec;
const Tag = sdk.utility.FixedTagItem;
const st = sdk.expansion.systemtags;
const rp1 = @import("rp1.zig");

/// The module, as Raspberry Pi names it.
const name = "Raspberry Pi Compute Module 5";

/// The IO board's two USB 3 sockets, one on each of the RP1's DWC3
/// controllers, xhci.device's units 0 and 1: each a USB 3 port and a USB
/// 2 one. Their 5 V is switched by the RP1's GPIO42 (USB_VBUS_EN), which
/// the bootloader leaves on.
const usb0 = usbPart(0, rp1.usb0, rp1.INT_USBHOST0_0, "USB 3 socket (RP1 USB 0)");
const usb1 = usbPart(1, rp1.usb1, rp1.INT_USBHOST1_0, "USB 3 socket (RP1 USB 1)");

fn usbPart(comptime unit: u32, comptime registers: usize, comptime source: u32, comptime label: [*:0]const u8) [12]Tag {
    return .{
        .value(st.PART_Kind, st.PARTKIND_USB),
        .value(st.PART_Chip, st.CHIP_DWC3),
        .pointer(st.PART_ChipName, "rp1 dwc3"),
        .value(st.PART_Bus, st.BUS_MEMORY),
        .value(st.PART_BusUnit, unit),
        .value(st.PART_Address, registers),
        .value(st.PART_Irq, rp1.irq(source)),
        .value(st.PART_UsbRoles, st.USBROLE_HOST),
        .value(st.PART_UsbSpeed, st.USBSPEED_HIGH),
        .value(st.PART_UsbVbus, st.USBVBUS_ALWAYS),
        .pointer(st.PART_Label, label),
        .done,
    };
}

/// PCI Express port 1, the IO board's M.2 slot (M key, one lane, 5 GT/s),
/// which the bootloader leaves alone: the bridge's registers at
/// 0x10_0011_0000, its configuration space through them. Its memory
/// window is 4 MiB at 0x1B_8000_0000, at 0x3FC0_0000 on the bus - where
/// RAM has the firmware's hole, so no buffer a function moves data to is
/// in it - and its prefetchable one 14 GiB at 0x18_0000_0000, from 16 GiB
/// on the bus, above RAM; RAM is on the bus where it is (`bcm2712.zig`).
/// INTA to INTD are GIC interrupts 251 to 254. The slot's 3.3 V is the
/// RP1's GPIO28 (PCIE_PWR_EN), which the bootloader leaves on.
const pcie1 = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_PCI),
    .value(st.PART_Chip, st.CHIP_BCM2712_PCIE),
    .pointer(st.PART_ChipName, "bcm2712 pcie1"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_BusUnit, 1),
    .value(st.PART_Address, 0x10_0011_0000),
    .value(st.PART_PciConfig, 0x10_0011_0000),
    .value(st.PART_PciMem, 0x1B_8000_0000),
    .value(st.PART_PciMemBus, 0x3FC0_0000),
    .value(st.PART_PciMemSize, 0x40_0000),
    .value(st.PART_PciPref, 0x18_0000_0000),
    .value(st.PART_PciPrefBus, 0x4_0000_0000),
    .value(st.PART_PciPrefSize, 0x3_8000_0000),
    .value(st.PART_Irq, 251),
    .pointer(st.PART_Label, "PCIe 1: the M.2 slot"),
    .done,
};

/// The root list: the board's own facts and a SYSTAG_Part per part.
/// `boards.fact` reads it at compile time for the kernel.
pub const root = [_]Tag{
    .pointer(st.SYSTAG_Name, name),
    // The smallest CM5's; the device tree has the module's own, in pieces.
    .value(st.SYSTAG_RamBase, 0),
    .value(st.SYSTAG_RamSize, 2 * 1024 * 1024 * 1024),
    .value(st.SYSTAG_UnifiedMemory, 1),
    .value(st.SYSTAG_Timebase, 54_000_000),
    .value(st.SYSTAG_Console, st.CONSOLE_UART0),
    .value(st.SYSTAG_ConsoleBase, rp1.peripherals + 0x3_0000),
    .value(st.SYSTAG_ConsoleClock, 50_000_000),
    .value(st.SYSTAG_ConsoleIrq, rp1.irq(rp1.INT_UART0)),
    .value(st.SYSTAG_GicDist, 0x10_7FFF_9000),
    .value(st.SYSTAG_GicCpu, 0x10_7FFF_A000),
    .value(st.SYSTAG_Cores, 4),
    .pointer(st.SYSTAG_Part, &usb0),
    .pointer(st.SYSTAG_Part, &usb1),
    .pointer(st.SYSTAG_Part, &pcie1),
    .done,
};

/// The ROM tag the list is in. No start flags: there is nothing to start,
/// and expansion.library finds it by name.
pub export const system_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &system_tag,
    .version = 1,
    .type = .board,
    .name = sdk.expansion.SYSTEM_RESIDENT,
    .id_string = name,
    .init = &root,
};
