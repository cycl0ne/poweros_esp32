// SPDX-License-Identifier: MPL-2.0
//! The Raspberry Pi 4 Model B: a BCM2711 - four Cortex-A72 cores and a
//! GIC-400 - with its RAM from address 0, started by the bootloader in
//! its EEPROM and the VideoCore's firmware (start4.elf), which reads
//! config.txt from the first FAT partition of the microSD card - or,
//! with no card in, of a USB stick in one of the USB-A ports (the
//! bootloader's BOOT_ORDER, which tries the card first and then USB from
//! its 2020-09-03 release on). The firmware loads kernel.bin at 2 MiB,
//! where it is linked - so the board's first GiB is all it needs, and one
//! with 1 GiB of RAM runs it - the disk image and the device tree where
//! config.txt says, and enters the kernel at EL2 through its armstub.
//! There is no PSCI: the armstub keeps the other three cores in a loop at
//! EL2 that waits for an address at 0xD8, 0xE0 and 0xE8 (the device
//! tree's spin table, cpu1.zig).
//!
//! **The system runs from RAM.** The firmware reads the disk image off
//! the medium beside the kernel, and flash.device serves it from RAM, so
//! nothing written to it outlives the run. The USB-A ports are the
//! VL805's, a USB 3 controller on the chip's PCI Express, which
//! pci.library brings up (`pcie`) and xhci.device drives (`usb`), once
//! the VideoCore's firmware has loaded the VL805's code into it.
//!
//! **The console** is the PL011 UART0 at 0xFE20_1000 on GPIO 14 and 15,
//! pins 8 and 10 of the 40-pin header, which the kernel takes back from
//! the mini UART the firmware gives them to (`pins.zig`). The HDMI port
//! beside the USB-C socket shows the kernel's lines too, on the picture
//! the firmware lit, until the display driver has it (`screen.zig`); the
//! network is the way in once the system is up.
//!
//! The chip is the Compute Module 4's, and so is everything the board
//! asks of its firmware: the files that do it are the Compute Module 4's
//! (src/boards/rpi_cm4/), and read this list through `boards.system`.
//! The chip's peripherals are at 0xFC00_0000 to 0xFFFF_FFFF ("low
//! peripheral" mode, the firmware's default), in the GiB below 4 GiB with
//! RAM up to 0xFC00_0000 (mmu.zig); the VideoCore's own memory is the 76
//! MiB below 1 GiB, which the device tree leaves out of RAM. The GIC-400's
//! distributor is at 0xFF84_1000 and its CPU interface at 0xFF84_2000;
//! the system counter runs at 54 MHz.
//!
//! What is true of the board is written down here once, as the system tag
//! list the ROM carries for expansion.library (a part per SYSTAG_Part). The
//! kernel reads the same list at compile time (`boards.fact`).

const sdk = @import("sdk");
const exec = sdk.exec;
const Tag = sdk.utility.FixedTagItem;
const st = sdk.expansion.systemtags;
const boardpin = sdk.expansion.boardpin;

/// The board, as its maker names it.
const name = "Raspberry Pi 4 Model B";

/// The VideoCore's mailbox (the BCM2835's, at 0x7E00_B880 on the SoC's
/// bus), through which its firmware is asked for the picture
/// (`screen.zig`), the cores' clock (`clock.zig`) and told of a restart
/// (`reset.zig`).
pub const mailbox: usize = 0xFE00_B880;

/// The chip's power manager, whose watchdog restarts the machine
/// (`reset.zig`).
pub const power_manager: usize = 0xFE10_0000;

/// The Ethernet port's station address and the radio's, which the kernel
/// copies in from the device tree the firmware passes - the
/// `local-mac-address` the firmware writes into ethernet@7d580000, the
/// GENET's, and into wifi@1 on the SD host mmcnr@7e300000 - before
/// anything runs; all zero when the tree has none, and the radio then
/// takes its own.
pub var ethernet_station: [6]u8 = @splat(0);
pub var wifi_station: [6]u8 = @splat(0);

/// The station addresses the kernel takes from the device tree: for the
/// port whose registers are at the first - by the address in the tree's
/// name for it - into the second.
pub const stations = .{ .{ 0x7D58_0000, &ethernet_station }, .{ 0x7E30_0000, &wifi_station } };

/// Where the bootloader started this system from: the kernel copies the
/// device tree's `/chosen/bootloader` `partition` and `tryboot` in before
/// anything runs.
pub var boot_start: st.BootStart = .{};

/// How the bootloader came by the kernel - the `/chosen/bootloader`
/// `boot-mode` the kernel copies in with `boot_start`: 1 from the card, 4
/// from a USB stick, 3 when a PC sent it over USB (rpiboot), when the
/// firmware is told of no restart (`reset.zig`); 0 where the tree did not
/// say.
pub var boot_mode: u32 = 0;

/// The Ethernet socket: the BCM2711's GENET v5 at 0xFD58_0000, on RGMII
/// to the board's BCM54213PE at address 1 of the GENET's management bus.
/// The PHY delays what it receives (the device tree's rgmii-rxid), the
/// GENET what it sends. GIC interrupts 157 and 158; the default queue's
/// come on the first.
const ethernet = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_NET),
    .value(st.PART_Chip, st.CHIP_BCM54213),
    .pointer(st.PART_ChipName, "bcm54213pe"),
    .value(st.PART_Bus, st.BUS_RGMII),
    .value(st.PART_BusUnit, 0),
    .value(st.PART_Address, 1),
    .value(st.PART_Irq, 32 + 157),
    .value(st.PART_RxDelay, 2000),
    .value(st.PART_TxDelay, 0),
    .pointer(st.PART_StationAddress, &ethernet_station),
    .pointer(st.PART_Label, "Ethernet eth0"),
    .done,
};

/// The microSD slot, on the BCM2711's EMMC2: an SDHCI at 0xFE34_0000,
/// GIC interrupt 126, four data lines and no line that says a card is in
/// (the device tree's `broken-cd`), so sdcard.device finds a card by
/// asking for one. The card's supply and its lines' voltage are the
/// firmware's, on its GPIO expander, and left as the bootloader left them
/// (`sdhci.zig`). sdcard.device's unit 0.
const sd_slot = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_SDSLOT),
    .pointer(st.PART_ChipName, "bcm2711 emmc2"),
    .value(st.PART_Bus, st.BUS_SDIO),
    .value(st.PART_Address, 0xFE34_0000),
    .value(st.PART_Irq, 32 + 126),
    .pointer(st.PART_Label, "SD card"),
    .done,
};

/// The radio, an Infineon CYW43455 (on a module of its own), on the
/// BCM2711's older SD host ("mmcnr") at 0xFE30_0000, whose interrupt, GIC
/// 126, it shares with the card slot's EMMC2. Its lines are GPIO34 to 39,
/// the host's in their ALT3 function; WL_REG_ON is line 1 of the
/// firmware's GPIO expander (WL_ON), which the firmware raises as it
/// starts the ARM. No antenna switch. cyw43455.device's unit 0.
const wifi = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_NET),
    .value(st.PART_Chip, st.CHIP_CYW43455),
    .pointer(st.PART_ChipName, "cyw43455"),
    .value(st.PART_Bus, st.BUS_SDIO),
    .value(st.PART_Address, 0xFE30_0000),
    .value(st.PART_Irq, 32 + 126),
    .value(st.PART_PinPower, boardpin.expander(1)),
    .value(st.PART_PinClock, boardpin.gpio(34)),
    .value(st.PART_PinCommand, boardpin.gpio(35)),
    .value(st.PART_PinData0, boardpin.gpio(36)),
    .pointer(st.PART_StationAddress, &wifi_station),
    .pointer(st.PART_Label, "Wi-Fi"),
    .done,
};

/// The first HDMI port's sound - the port beside the USB-C socket:
/// channel 12 of the chip's 40-bit DMA4 channels (the device tree's
/// dma40, channels 11 to 14 at 0xFE00_7B00, 0x100 apart, of which 12 and
/// 13 are the ARM's), its interrupt SPI 90, feeding the HDMI0
/// controller's MAI - in the mode the firmware lit, and only where it lit
/// it as HDMI (rta_driver/hdmi/bcm2711.zig). The MAI's FIFO takes the
/// samples at 0xFEF2_001C, which the 40-bit channels reach at
/// 0x4_7EF2_001C (the scb bus's dma-ranges: the peripherals at
/// 0x4_7C00_0000), and asks the channel for them on request line 10.
const hdmi_sound = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_CODEC),
    .value(st.PART_Chip, st.CHIP_BCM2711_HDMI_AUDIO),
    .pointer(st.PART_ChipName, "bcm2711 hdmi0 audio"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_Address, 0xFE00_7C00),
    .value(st.PART_Irq, 32 + 90),
    .value(st.PART_DataAddress, 0x4_7EF2_001C),
    .value(st.PART_DmaRequest, 10),
    .pointer(st.PART_Label, "HDMI 0 sound"),
    .done,
};

/// The chip's H.265 decoder: its registers at 0xFEB0_0000 and the
/// interrupt controller in front of them 0x1_0000 above, GIC SPI 98; its
/// clock is the firmware's (videodec.resource).
const hevc = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_VIDEODEC),
    .value(st.PART_Chip, st.CHIP_BCM2711_HEVC),
    .pointer(st.PART_ChipName, "bcm2711 hevc"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_Address, 0xFEB0_0000),
    .value(st.PART_Irq, 32 + 98),
    .done,
};

/// The memory the VideoCore's message queue is in: a block of 2 MiB the
/// kernel keeps in the first GiB, which the VideoCore reaches at
/// 0xC000_0000 and above, mapped without caches.
pub var vchiq_memory: st.SharedMemory = .{ .bytes = 2 * 1024 * 1024, .below = 0x4000_0000 };

/// What the kernel keeps for the board's parts when it starts.
pub const shared = .{&vchiq_memory};

/// The VideoCore's message queue: its doorbells at 0xFE00_B840, beside
/// the mailbox, the one the VideoCore rings the ARM with, GIC SPI 34, and
/// its memory. The firmware runs the chip's H.264 and JPEG decoders
/// behind it (vchiq.resource).
const vchiq = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_FIRMWARE),
    .value(st.PART_Chip, st.CHIP_BCM2711_VCHIQ),
    .pointer(st.PART_ChipName, "vchiq"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_Address, 0xFE00_B840),
    .value(st.PART_Irq, 32 + 34),
    .pointer(st.PART_SharedMemory, &vchiq_memory),
    .done,
};

/// The BCM2711's random number generator, the RNG200 at 0xFE10_4000
/// (the device tree's rng@7e104000), which the firmware has running when
/// the kernel starts; the kernel starts it where it has not, and
/// sdk.hardware.rng takes its words.
const rng = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_RNG),
    .value(st.PART_Chip, st.CHIP_BCM2711_RNG200),
    .pointer(st.PART_ChipName, "bcm2711 rng200"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_Address, 0xFE10_4000),
    .done,
};

/// The PCI Express root port, and the VL805 behind it that the four
/// USB-A sockets are: the bridge's registers at 0xFD50_0000, its
/// configuration space through them; its memory window 1 GiB at
/// 0x6_0000_0000, at 0xC000_0000 on the bus, above the 3 GiB of RAM the
/// bridge reaches, which is on the bus where it is (pci.library's
/// `bcm2711.zig`). INTA to INTD are the GIC's SPIs 143 to 146.
const pcie = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_PCI),
    .value(st.PART_Chip, st.CHIP_BCM2711_PCIE),
    .pointer(st.PART_ChipName, "bcm2711 pcie"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_BusUnit, 0),
    .value(st.PART_Address, 0xFD50_0000),
    .value(st.PART_PciConfig, 0xFD50_0000),
    .value(st.PART_PciMem, 0x6_0000_0000),
    .value(st.PART_PciMemBus, 0xC000_0000),
    .value(st.PART_PciMemSize, 0x4000_0000),
    .value(st.PART_Irq, 32 + 143),
    .pointer(st.PART_Label, "PCIe: the USB sockets' VL805"),
    .done,
};

/// The four USB-A sockets: the VL805 behind the PCI Express port, the
/// first xHCI function on PCI, whose code the VideoCore's firmware loads
/// into it when xhci.device asks (through `firmware`). The two blue
/// sockets are USB 3; the USB 2 lines of all four go through the VL805's
/// own hub.
const usb = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_USB),
    .value(st.PART_Chip, st.CHIP_XHCI),
    .pointer(st.PART_ChipName, "vl805"),
    .value(st.PART_Bus, st.BUS_PCI),
    .value(st.PART_BusUnit, 0),
    .value(st.PART_UsbRoles, st.USBROLE_HOST),
    .value(st.PART_UsbSpeed, st.USBSPEED_HIGH),
    .value(st.PART_UsbVbus, st.USBVBUS_ALWAYS),
    .pointer(st.PART_Label, "USB-A sockets"),
    .done,
};

/// The VideoCore's firmware, start4.elf, through its mailbox (`mailbox`):
/// where C:Reboot and C:CpuClock find it, and xhci.device, which asks it
/// to load the VL805's code.
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
    // has the board's own RAM, in pieces: 1, 2, 4 or 8 GiB. The first GiB
    // is what every one of them has, and holds the kernel.
    .value(st.SYSTAG_RamBase, 0),
    .value(st.SYSTAG_RamSize, 1024 * 1024 * 1024),
    // The VideoCore's firmware reads its messages from RAM's first GiB,
    // and the chip's older DMA masters reach no further: MEMF_DMA is that
    // GiB.
    .value(st.SYSTAG_DmaLimit, 0x4000_0000),
    .value(st.SYSTAG_UnifiedMemory, 1),
    .value(st.SYSTAG_Timebase, 54_000_000),
    // The PL011, with the 48 MHz clock the firmware gives it, on pins 8
    // and 10 of the header (pins.zig).
    .value(st.SYSTAG_Console, st.CONSOLE_UART0),
    .value(st.SYSTAG_ConsoleBase, 0xFE20_1000),
    .value(st.SYSTAG_ConsoleClock, 48_000_000),
    .value(st.SYSTAG_ConsoleIrq, 32 + 121),
    .value(st.SYSTAG_GicDist, 0xFF84_1000),
    .value(st.SYSTAG_GicCpu, 0xFF84_2000),
    .value(st.SYSTAG_Cores, 4),
    // The A72s at 1.8 GHz, or as fast as the firmware lets them where
    // that is slower: 1.8 GHz on a board with the chip's C0 stepping
    // (from the board's revision 1.4 on), 1.5 GHz on one before. The
    // firmware sets the clock and the supply with it, asked through its
    // mailbox (clock.zig), and goes past 1.5 GHz only as config.txt's
    // arm_boost lets it.
    .value(st.SYSTAG_CpuSpeed, 1800),
    .pointer(st.SYSTAG_BootStart, &boot_start),
    .pointer(st.SYSTAG_Part, &ethernet),
    .pointer(st.SYSTAG_Part, &sd_slot),
    .pointer(st.SYSTAG_Part, &wifi),
    .pointer(st.SYSTAG_Part, &pcie),
    .pointer(st.SYSTAG_Part, &usb),
    .pointer(st.SYSTAG_Part, &firmware),
    .pointer(st.SYSTAG_Part, &hdmi_sound),
    .pointer(st.SYSTAG_Part, &hevc),
    .pointer(st.SYSTAG_Part, &vchiq),
    .pointer(st.SYSTAG_Part, &rng),
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
