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
//! registers at 0x1C_0003_0000 - in the link's prefetchable window, where
//! the bootloader put them and says so on the UART ("RP1_UART"); Linux
//! moves them to 0x1F_0003_0000. Its interrupt comes as an MSI-X message, which
//! nothing routes yet, so the board names none and serial.device polls it.
//! The GIC-400's distributor is at 0x10_7FFF_9000 and its CPU interface
//! at 0x10_7FFF_A000; the system counter runs at 54 MHz.
//!
//! What is true of the board is written down here once, as the system tag
//! list the ROM carries for expansion.library (a part per SYSTAG_Part). The
//! kernel reads the same list at compile time (`boards.fact`).

const sdk = @import("sdk");
const exec = sdk.exec;
const Tag = sdk.utility.FixedTagItem;
const st = sdk.expansion.systemtags;

/// The module, as Raspberry Pi names it.
const name = "Raspberry Pi Compute Module 5";

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
    .value(st.SYSTAG_ConsoleBase, 0x1C_0003_0000),
    .value(st.SYSTAG_ConsoleClock, 50_000_000),
    .value(st.SYSTAG_GicDist, 0x10_7FFF_9000),
    .value(st.SYSTAG_GicCpu, 0x10_7FFF_A000),
    .value(st.SYSTAG_Cores, 4),
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
