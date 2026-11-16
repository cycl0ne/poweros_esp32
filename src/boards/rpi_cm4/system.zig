// SPDX-License-Identifier: MPL-2.0
//! The Raspberry Pi Compute Module 4 on Waveshare's CM4-NANO-B: a
//! BCM2711 - four Cortex-A72 cores and a GIC-400 - with its RAM from
//! address 0, started by the bootloader in its EEPROM and the VideoCore's
//! firmware (start4.elf), which reads config.txt from the eMMC's first
//! FAT partition - or, with the board's BOOT switch on, everything from a
//! PC over the USB-C port (rpiboot). The firmware loads kernel.bin at
//! 2 MiB - the kernel copies itself to 0x40200000 (start.S) - the disk
//! image and the device tree where config.txt says, and enters the kernel
//! at EL2 through its armstub. There is no PSCI: the armstub keeps the
//! other three cores in a loop at EL2 that waits for an address at
//! 0xD8, 0xE0 and 0xE8 (the device tree's spin table, cpu1.zig).
//!
//! The chip's peripherals are at 0xFC00_0000 to 0xFFFF_FFFF ("low
//! peripheral" mode, the firmware's default), in the GiB below 4 GiB with
//! RAM up to 0xFC00_0000 (mmu.zig); the VideoCore's own memory is the 76
//! MiB below 1 GiB, which the device tree leaves out of RAM. The GIC-400's
//! distributor is at 0xFF84_1000 and its CPU interface at 0xFF84_2000;
//! the system counter runs at 54 MHz.
//!
//! **This board has no serial console.** The CM4-NANO-B brings out no
//! pins: what the kernel says goes on the HDMI port, on the picture the
//! VideoCore's firmware shows, until the display driver has it
//! (`screen.zig`), and the network is the way in after that. The PL011
//! UART0 at 0xFE20_1000 is still the raw port - config.txt switches it
//! on and its clock with it, so writing to it costs a character's time
//! and nothing more.
//!
//! What is true of the board is written down here once, as the system tag
//! list the ROM carries for expansion.library (a part per SYSTAG_Part). The
//! kernel reads the same list at compile time (`boards.fact`).

const sdk = @import("sdk");
const exec = sdk.exec;
const Tag = sdk.utility.FixedTagItem;
const st = sdk.expansion.systemtags;

/// The module and its board, as their makers name them.
const name = "Raspberry Pi Compute Module 4 on a CM4-NANO-B";

/// The VideoCore's mailbox (the BCM2835's, at 0x7E00_B880 on the SoC's
/// bus), through which its firmware is asked for the picture
/// (`screen.zig`), the cores' clock (`clock.zig`) and the next start's
/// flags.
pub const mailbox: usize = 0xFE00_B880;

/// The chip's power manager, whose watchdog restarts the machine
/// (`reset.zig`).
pub const power_manager: usize = 0xFE10_0000;

/// The Ethernet port's station address, which the kernel copies in from
/// the device tree the firmware passes - the `local-mac-address` the
/// firmware writes into ethernet@7d580000, the GENET's - before anything
/// runs; all zero when the tree has none.
pub var ethernet_station: [6]u8 = @splat(0);

/// The station addresses the kernel takes from the device tree: for the
/// port whose registers are at the first - by the address in the tree's
/// name for it - into the second.
pub const stations = .{.{ 0x7D58_0000, &ethernet_station }};

/// Where the bootloader started this system from: the kernel copies the
/// device tree's `/chosen/bootloader` `partition` and `tryboot` in before
/// anything runs. Keeping a tried partition goes by it.
pub var boot_start: st.BootStart = .{};

/// How the bootloader came by the kernel - the `/chosen/bootloader`
/// `boot-mode` the kernel copies in with `boot_start`: 3 when a PC sent
/// it over USB (rpiboot), when the firmware must not be asked to power
/// USB (`domains.zig`); 0 where the tree did not say.
pub var boot_mode: u32 = 0;

/// The module's USB 2.0 port as the BCM2711's own xHCI, which config.txt's
/// `otg_mode=1` gives it instead of the DWC2: unit 0 of xhci.device, GIC
/// interrupt 176. The CM4-NANO-B's BOOT switch picks where the port goes:
/// off, to the board's USB-A socket - on, to the USB-C socket, where a PC
/// is the host.
const usb = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_USB),
    .value(st.PART_Chip, st.CHIP_XHCI),
    .pointer(st.PART_ChipName, "bcm2711 xhci"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_BusUnit, 0),
    .value(st.PART_Address, 0xFE9C_0000),
    .value(st.PART_Irq, 32 + 176),
    .value(st.PART_UsbRoles, st.USBROLE_HOST),
    .pointer(st.PART_Label, "USB"),
    .done,
};

/// The Ethernet socket: the BCM2711's GENET v5 at 0xFD58_0000, on RGMII
/// to the module's BCM54213PE at address 0 of the GENET's management bus.
/// The PHY delays what it receives (the device tree's rgmii-rxid), the
/// GENET what it sends. GIC interrupts 157 and 158; the default queue's
/// come on the first.
const ethernet = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_NET),
    .value(st.PART_Chip, st.CHIP_BCM54213),
    .pointer(st.PART_ChipName, "bcm54213pe"),
    .value(st.PART_Bus, st.BUS_RGMII),
    .value(st.PART_BusUnit, 0),
    .value(st.PART_Address, 0),
    .value(st.PART_Irq, 32 + 157),
    .value(st.PART_RxDelay, 2000),
    .value(st.PART_TxDelay, 0),
    .pointer(st.PART_StationAddress, &ethernet_station),
    .pointer(st.PART_Label, "Ethernet eth0"),
    .done,
};

/// The module's eMMC, on the BCM2711's EMMC2: an SDHCI at 0xFE34_0000,
/// GIC interrupt 126, its lines its own - eight data lines to the eMMC,
/// which sdcard.device finds out for itself. The eMMC's supply and its
/// lines' voltage are the firmware's, on its GPIO expander, and left on
/// (`sdhci.zig`). On a module without an eMMC the same host is the IO
/// board's card slot. sdcard.device's unit 0 either way.
const emmc = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_SDSLOT),
    .pointer(st.PART_ChipName, "bcm2711 emmc2"),
    .value(st.PART_Bus, st.BUS_SDIO),
    .value(st.PART_Address, 0xFE34_0000),
    .value(st.PART_Irq, 32 + 126),
    .pointer(st.PART_Label, "eMMC"),
    .done,
};

/// The VideoCore's firmware, start4.elf, through its mailbox (`mailbox`):
/// where C:Reboot TRYBOOT and C:CpuClock find it.
const firmware = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_FIRMWARE),
    .value(st.PART_Chip, st.CHIP_RPI_FIRMWARE),
    .pointer(st.PART_ChipName, "videocore"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_Address, mailbox),
    .done,
};

/// The board's facts. The parts only the firmware can describe - the
/// picture it lit - follow in `list`.
pub const root = [_]Tag{
    .pointer(st.SYSTAG_Name, name),
    // The window the boot maps before it reads the device tree, which
    // has the module's own RAM, in pieces: 8 GiB on this one.
    .value(st.SYSTAG_RamBase, 0),
    .value(st.SYSTAG_RamSize, 2 * 1024 * 1024 * 1024),
    // The VideoCore's firmware reads its messages from RAM's first GiB,
    // and the chip's older DMA masters reach no further: MEMF_DMA is that
    // GiB.
    .value(st.SYSTAG_DmaLimit, 0x4000_0000),
    .value(st.SYSTAG_UnifiedMemory, 1),
    .value(st.SYSTAG_Timebase, 54_000_000),
    // The PL011, with the 48 MHz clock the firmware gives it: on no pin
    // of this board, but where the raw port writes all the same.
    .value(st.SYSTAG_Console, st.CONSOLE_UART0),
    .value(st.SYSTAG_ConsoleBase, 0xFE20_1000),
    .value(st.SYSTAG_ConsoleClock, 48_000_000),
    .value(st.SYSTAG_ConsoleIrq, 32 + 121),
    .value(st.SYSTAG_GicDist, 0xFF84_1000),
    .value(st.SYSTAG_GicCpu, 0xFF84_2000),
    .value(st.SYSTAG_Cores, 4),
    // The A72s at 1.5 GHz, the CM4's own: the firmware sets the clock
    // and the supply with it, asked through its mailbox (clock.zig).
    .value(st.SYSTAG_CpuSpeed, 1500),
    // The bootloader reads `autoboot.txt` and takes a tryboot flag, so a
    // new kernel is tried on the second boot partition for one start,
    // with the one that worked still on the first - a bootloader from
    // 2022-10-18 on (`reset.zig`).
    .value(st.SYSTAG_BootSlots, 2),
    .pointer(st.SYSTAG_BootStart, &boot_start),
    .pointer(st.SYSTAG_Part, &usb),
    .pointer(st.SYSTAG_Part, &ethernet),
    .pointer(st.SYSTAG_Part, &emmc),
    .pointer(st.SYSTAG_Part, &firmware),
    .done,
};

/// How many parts only the firmware can describe: the picture it lit.
pub const firmware_parts = 1;

/// The list expansion.library reads: the board's own facts, then a slot
/// for each part the firmware described, then the end. Until the kernel
/// fills a slot it is the end of the list (as on the x86-64 machines,
/// `qemu_q35/system.zig`).
pub var list: [root.len + firmware_parts]Tag = made: {
    var assembled: [root.len + firmware_parts]Tag = @splat(.done);
    for (root[0 .. root.len - 1], 0..) |item, at| assembled[at] = item;
    break :made assembled;
};

/// `part`'s tag list added to the board's, in the first slot left: the
/// kernel's to call, before expansion.library starts. False where the
/// slots are full.
pub fn addPart(part: [*]const Tag) bool {
    var at = root.len - 1;
    while (at + 1 < list.len) : (at += 1) {
        if (list[at].tag != sdk.utility.TAG_DONE) continue;
        list[at] = .pointer(st.SYSTAG_Part, part);
        list[at + 1] = .done;
        return true;
    }
    return false;
}

/// The ROM tag the list is in. No start flags: there is nothing to start,
/// and expansion.library finds it by name.
pub export const system_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &system_tag,
    .version = 1,
    .type = .board,
    .name = sdk.expansion.SYSTEM_RESIDENT,
    .id_string = name,
    .init = &list,
};
