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
const rtg = sdk.rtg;
const tags = rtg.tags;
const Tag = sdk.utility.FixedTagItem;
const st = sdk.expansion.systemtags;
const pins = sdk.expansion.boardpin;
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

/// The VideoCore's mailbox, through which its firmware is asked what it
/// keeps for the ARM: the RTC's count (`rtc`) and the cores' clock
/// (`clock.zig`).
pub const mailbox: usize = 0x10_7C01_3880;

/// The radio's station address and the Ethernet port's. The kernel copies
/// them in from the device tree the firmware passes - the
/// `local-mac-address` the firmware writes into wifi@1, on the SD host
/// mmc@1100000, and into the RP1's ethernet@100000 - before anything runs;
/// all zero when the tree has none.
pub var wifi_station: [6]u8 = @splat(0);
pub var ethernet_station: [6]u8 = @splat(0);

/// The station addresses the kernel takes from the device tree: for the
/// port whose registers are at the first - by the address in the tree's
/// name for it - into the second.
pub const stations = .{ .{ 0x0110_0000, &wifi_station }, .{ 0x10_0000, &ethernet_station } };

/// The IO board's Ethernet socket: the RP1's MAC, its source 6, on RGMII to
/// the module's BCM54210PE, at address 0 on the MAC's management bus. The
/// PHY adds both delays (the device tree's rgmii-id), and its reset line is
/// the RP1's GPIO32, which networks/emac.device lets go.
const ethernet = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_NET),
    .value(st.PART_Chip, st.CHIP_BCM54210),
    .pointer(st.PART_ChipName, "bcm54210pe"),
    .value(st.PART_Bus, st.BUS_RGMII),
    .value(st.PART_BusUnit, 0),
    .value(st.PART_Address, 0),
    .value(st.PART_Irq, rp1.irq(rp1.INT_ETH)),
    .value(st.PART_RxDelay, 2000),
    .value(st.PART_TxDelay, 2000),
    .pointer(st.PART_StationAddress, &ethernet_station),
    .pointer(st.PART_Label, "Ethernet eth0"),
    .done,
};

/// The module's Wi-Fi, a CYW43455 on the BCM2712's second SD host
/// ("sdio2", an SDHCI at 0x10_0110_0000 with a 200 MHz clock, GIC
/// interrupt 306), four data lines. The bootloader leaves the radio off
/// and the host's pins GPIOs: WL_REG_ON is GPIO28 of the SoC's own GPIO
/// block, and the lines GPIO30 to 35 in their "sd2" function. The
/// antenna switch is on the always-on GPIO block, which the radio's
/// driver drives itself: pin 5 (ANT1) picks the module's own antenna, pin
/// 6 (ANT2) the U.FL connector's - the first, as Raspberry Pi's device
/// tree has it unless told otherwise.
const wifi = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_NET),
    .value(st.PART_Chip, st.CHIP_CYW43455),
    .pointer(st.PART_ChipName, "cyw43455"),
    .value(st.PART_Bus, st.BUS_SDIO),
    .value(st.PART_Address, 0x10_0110_0000),
    .value(st.PART_Irq, 306),
    .value(st.PART_PinPower, pins.gpio(28)),
    .value(st.PART_PinClock, pins.gpio(30)),
    .value(st.PART_PinCommand, pins.gpio(31)),
    .value(st.PART_PinData0, pins.gpio(32)),
    .value(st.PART_PinAntenna, pins.driver(5)),
    .value(st.PART_PinAntennaExternal, pins.driver(6)),
    .pointer(st.PART_StationAddress, &wifi_station),
    .pointer(st.PART_Label, "Wi-Fi"),
    .done,
};

/// The module's RTC, in its power chip, read and set by the VideoCore's
/// firmware through its mailbox at 0x10_7C01_3880 (the BCM2835's, on the
/// SoC's bus at 0x7C01_3880). It counts while the module has power; the
/// IO board's BAT connector takes a cell for it to count through a power
/// cut.
const rtc = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_RTC),
    .value(st.PART_Chip, st.CHIP_RPI_RTC),
    .pointer(st.PART_ChipName, "rpi rtc"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_Address, mailbox),
    .pointer(st.PART_Label, "RTC"),
    .done,
};

/// The BCM2712's own temperature sensor, in its AVS monitor at
/// 0x10_7D54_2000 (the SoC's bus at 0x7D54_2000).
const temperature = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_THERMAL),
    .value(st.PART_Chip, st.CHIP_BCM2712_TEMP),
    .pointer(st.PART_ChipName, "bcm2712 temp"),
    .pointer(st.PART_Label, "SoC"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_Address, 0x10_7D54_2000),
    .done,
};

/// The VideoCore VII's 3D core, a V3D 7.1: its hub's registers at
/// 0x10_0200_0000, GIC interrupt 281 from its core and 282 from its hub
/// (the device tree's SPIs 249 and 250), its reset in the power manager
/// at 0x10_7D20_0000.
const gpu = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_GPU),
    .value(st.PART_Chip, st.CHIP_BCM2712_V3D),
    .pointer(st.PART_ChipName, "bcm2712 v3d"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_Address, 0x10_0200_0000),
    .value(st.PART_Irq, 281),
    .value(st.PART_PowerManager, 0x10_7D20_0000),
    .pointer(st.PART_Label, "3D"),
    .done,
};

/// The IO board's fan connector: a PWM fan, on the RP1's PWM1 channel 3
/// out on its GPIO45, its speed counted by the RP1.
const fan = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_FAN),
    .value(st.PART_Chip, st.CHIP_RP1_PWM),
    .pointer(st.PART_ChipName, "rp1 pwm"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_Address, rp1.peripherals),
    .value(st.PART_Pin, pins.driver(45)),
    .pointer(st.PART_Label, "fan"),
    .done,
};

/// The HDMI port's picture when the monitor gives no EDID: 1920x1080 at
/// 60 Hz. With one, the monitor's modes are the board's, and the screen
/// is the one it prefers (`rtg_driver/fbboard/monitor.zig`).
const screen = struct {
    pub const width: u32 = 1920;
    pub const height: u32 = 1080;
};

/// The display behind the IO board's first HDMI port (HDMI0): the
/// BCM2712's video scaler at 0x10_7C58_0000, which reads its picture out
/// of RAM, the HDMI0 controller, and pixel valve 0 between them, which
/// raises GIC interrupt 133 at each frame - what the fb rtg driver is
/// told comes with it (`rtg_driver/fbboard/bcm2712.zig`). Its clocks are
/// the VideoCore firmware's, asked through the mailbox the RTC is read
/// through.
const display = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_PANEL),
    .value(st.PART_Chip, st.CHIP_BCM2712_HVS),
    .pointer(st.PART_ChipName, "bcm2712 hvs hdmi0"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_Address, 0x10_7C58_0000),
    .value(st.PART_Irq, 133),
    .value(tags.RTGA_Width, screen.width),
    .value(tags.RTGA_Height, screen.height),
    .value(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.bgra32)),
    // At most sixteen pictures at once - screens, and the buffers behind
    // them - each taken from memory as it is opened: a ceiling, not memory
    // set aside.
    .value(tags.RTGA_Buffers, 16),
    // The windows of a screen each draw into a buffer of their own, and
    // what can be seen of them is copied into the screen's: memory here
    // reads back fast through the caches, and the display is shown only
    // the driver's own frames, never a buffer drawn in.
    .value(tags.RTGA_Compose, 1),
    .pointer(st.PART_Label, "HDMI 0"),
    .done,
};

/// The first HDMI port's sound: channel 10 of the DMA controller's
/// 40-bit channels (the device tree's dma40, whose channels 6 to 10 are
/// the ARM's), at 0x10_0001_0A00, its interrupt SPI 90, feeding the
/// HDMI0 controller's MAI.
const hdmi_sound = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_CODEC),
    .value(st.PART_Chip, st.CHIP_BCM2712_HDMI_AUDIO),
    .pointer(st.PART_ChipName, "bcm2712 hdmi0 audio"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_Address, 0x10_0001_0A00),
    .value(st.PART_Irq, 122),
    .pointer(st.PART_Label, "HDMI 0 sound"),
    .done,
};

/// The root list: the board's own facts and a SYSTAG_Part per part.
/// `boards.fact` reads it at compile time for the kernel.
pub const root = [_]Tag{
    .pointer(st.SYSTAG_Name, name),
    // The smallest CM5's; the device tree has the module's own, in pieces.
    .value(st.SYSTAG_RamBase, 0),
    .value(st.SYSTAG_RamSize, 2 * 1024 * 1024 * 1024),
    // The VideoCore's firmware reads its messages from RAM's first GiB,
    // where Linux keeps every buffer for DMA on this board (the device
    // tree's CMA): MEMF_DMA is that GiB.
    .value(st.SYSTAG_DmaLimit, 0x4000_0000),
    .value(st.SYSTAG_UnifiedMemory, 1),
    .value(st.SYSTAG_Timebase, 54_000_000),
    .value(st.SYSTAG_Console, st.CONSOLE_UART0),
    .value(st.SYSTAG_ConsoleBase, rp1.peripherals + 0x3_0000),
    .value(st.SYSTAG_ConsoleClock, 50_000_000),
    .value(st.SYSTAG_ConsoleIrq, rp1.irq(rp1.INT_UART0)),
    .value(st.SYSTAG_GicDist, 0x10_7FFF_9000),
    .value(st.SYSTAG_GicCpu, 0x10_7FFF_A000),
    .value(st.SYSTAG_Cores, 4),
    // The A76s at 2.4 GHz, as Linux runs them: the firmware sets the
    // clock and the supply with it, asked through its mailbox
    // (clock.zig), as far as config.txt's arm_freq lets it; unasked it
    // leaves them at 1 GHz.
    .value(st.SYSTAG_CpuSpeed, 2400),
    .pointer(st.SYSTAG_Part, &usb0),
    .pointer(st.SYSTAG_Part, &usb1),
    .pointer(st.SYSTAG_Part, &pcie1),
    .pointer(st.SYSTAG_Part, &wifi),
    .pointer(st.SYSTAG_Part, &ethernet),
    .pointer(st.SYSTAG_Part, &rtc),
    .pointer(st.SYSTAG_Part, &display),
    .pointer(st.SYSTAG_Part, &hdmi_sound),
    .pointer(st.SYSTAG_Part, &temperature),
    .pointer(st.SYSTAG_Part, &fan),
    .pointer(st.SYSTAG_Part, &gpu),
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
