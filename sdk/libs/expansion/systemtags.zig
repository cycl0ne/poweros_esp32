// SPDX-License-Identifier: MIT
//! The system tag list: what a board is and what is soldered on it, as
//! utility tags. A board's ROM carries one, in a ROM tag named "system"
//! whose rt_Init points at it; expansion.library reads it, and a module
//! asks expansion.library rather than knowing any board.
//!
//! **Absent means absent.** A board without a battery has no battery
//! part; a part without a reset line has no PART_PinReset. A new fact is a
//! new tag, which a reader that does not know it passes over, so a module
//! built against an older SDK still reads a newer board, and the other way
//! round.
//!
//! The root list holds the board's own facts and one SYSTAG_Part per part,
//! whose `ti_Data` is that part's tag list. A part's list says what it is
//! (PART_Kind, PART_Chip), how it is reached (PART_Bus, PART_BusUnit,
//! PART_Address) and where its lines are (the PART_Pin* tags, each a
//! `BoardPin` - boardpin.zig). A part may carry tags of the library that
//! drives it as well: a panel carries rtg.library's RTGA_* tags, which go
//! to its display driver as they are.

const TAG_USER = @import("../utility/tagitem.zig").TAG_USER;

// --- the board -----------------------------------------------------------------

pub const SYSTAG_Dummy = TAG_USER + 0x50000;

/// The board's name, as its maker gives it (a C string).
pub const SYSTAG_Name = SYSTAG_Dummy + 1;
/// Bytes of flash the module has.
pub const SYSTAG_FlashSize = SYSTAG_Dummy + 2;
/// Bytes of PSRAM the module has, and how it is wired (PSRAM_*).
pub const SYSTAG_PsramSize = SYSTAG_Dummy + 3;
pub const SYSTAG_PsramMode = SYSTAG_Dummy + 4;
/// Where the machine's console is (CONSOLE_*): what con-handler's AUX:
/// and the debug shell open.
pub const SYSTAG_Console = SYSTAG_Dummy + 5;
/// One part: `ti_Data` is its tag list. Given once per part.
pub const SYSTAG_Part = SYSTAG_Dummy + 6;
/// The screen the machine runs, in pixels: the panel's own size, or the
/// two exchanged for a panel mounted on its side. Left out where the
/// monitor says (a port whose board reads its EDID): the screen is then
/// the board's default mode.
pub const SYSTAG_ScreenWidth = SYSTAG_Dummy + 7;
pub const SYSTAG_ScreenHeight = SYSTAG_Dummy + 8;
/// Where the flash disk starts on the chip, in bytes: flash.device's unit
/// 0 runs from here to the end of the flash. A whole 64 KiB page, above
/// the kernel image; the build sets it (`-Ddisk-offset`).
pub const SYSTAG_DiskOffset = SYSTAG_Dummy + 9;
/// How many pixels an inch of the screen holds, across and down alike: a
/// font asked for in points is this many rows per 72 of them. Absent,
/// 72, and a point is a pixel.
pub const SYSTAG_ScreenDPI = SYSTAG_Dummy + 10;
/// Bytes of internal memory the system log keeps (`ReadLog`). Absent,
/// 16 KiB.
pub const SYSTAG_LogSize = SYSTAG_Dummy + 11;
/// 1: the log goes to the USB console from the boot on - for a board
/// whose raw port (UART0) reaches no host, so that the USB port is the
/// only way to read it. Absent, 0; `C:Log MIRROR` changes it.
pub const SYSTAG_LogMirror = SYSTAG_Dummy + 12;
/// How many cores the kernel runs tasks on: 1 or 2 on the ESP32s, up to 4
/// on a RISC-V 64 machine, which uses as many as its device tree has harts
/// for. Absent, 1. The build's `-Dcores` has the last word.
pub const SYSTAG_Cores = SYSTAG_Dummy + 13;
/// The PSRAM's bus clock in MHz: as fast as the board's wiring holds it
/// without errors. The ESP32-P4 runs it at 200 or 80; absent, 80.
pub const SYSTAG_PsramSpeed = SYSTAG_Dummy + 14;
/// The millivolts the board wants from the chip's fourth adjustable LDO
/// (VO4) from the start, before any driver uses a pin: a board that runs
/// a bank of I/O pins or their pull-ups from it. The ESP32-P4 only;
/// absent, 0, and the channel is left as the ROM left it.
pub const SYSTAG_Ldo4Voltage = SYSTAG_Dummy + 15;
/// The machine's RAM, where it starts and how many bytes: a machine under
/// SBI or PSCI firmware, whose device tree says more where it has more
/// than one block. The firmware's own part at its start is left out by
/// the kernel, which links above it.
pub const SYSTAG_RamBase = SYSTAG_Dummy + 16;
pub const SYSTAG_RamSize = SYSTAG_Dummy + 17;
/// The rate of RISC-V's `time` counter, in Hz: what the SBI timer counts
/// in. A whole number of MHz. On AArch64 the generic timer's, which the
/// kernel reads from CNTFRQ_EL0 and checks against this.
pub const SYSTAG_Timebase = SYSTAG_Dummy + 18;
/// The console UART, a 16550 (a PL011 on AArch64), as the machine has
/// it: its address; its registers' spacing, as a shift (register n at
/// base + n << shift); 1 when its registers want 32-bit accesses; the
/// clock its divisor divides, in Hz; and its interrupt source on the PLIC
/// (its interrupt ID on the GIC).
pub const SYSTAG_ConsoleBase = SYSTAG_Dummy + 19;
pub const SYSTAG_ConsoleShift = SYSTAG_Dummy + 20;
pub const SYSTAG_ConsoleWide = SYSTAG_Dummy + 21;
pub const SYSTAG_ConsoleClock = SYSTAG_Dummy + 22;
pub const SYSTAG_ConsoleIrq = SYSTAG_Dummy + 23;
/// Which PLIC context is supervisor mode of hart n: first + stride * n.
pub const SYSTAG_PlicFirst = SYSTAG_Dummy + 24;
pub const SYSTAG_PlicStride = SYSTAG_Dummy + 25;
/// The L2 cache controller's Flush64 register (SiFive's ccache), on a
/// machine whose devices do not see the cores' caches: what exec writes
/// a line's address to, to have it written back to RAM and dropped.
/// Absent, the devices see the caches - QEMU's virt - and DMA wants
/// nothing written back.
pub const SYSTAG_CacheFlush = SYSTAG_Dummy + 26;
/// 1: the machine's RAM is one kind - every region is internal and
/// external memory at once, as on a machine under SBI firmware - so there
/// is one figure of free memory to show, not two. Absent, 0: internal
/// memory and PSRAM apart, as on the ESP32s.
pub const SYSTAG_UnifiedMemory = SYSTAG_Dummy + 27;
/// The generic interrupt controller of an AArch64 machine (a GICv2):
/// where its distributor and its CPU interface are.
pub const SYSTAG_GicDist = SYSTAG_Dummy + 28;
pub const SYSTAG_GicCpu = SYSTAG_Dummy + 29;
/// Where the devices' DMA stops reaching: one past the highest address
/// a descriptor may name, on a machine whose RAM goes beyond it. Absent,
/// 4 GiB.
pub const SYSTAG_DmaLimit = SYSTAG_Dummy + 30;
/// One past RAM's last byte at most, on a machine whose RAM the device
/// tree describes: the window the kernel's boot maps as normal memory
/// from SYSTAG_RamBase, before it has read the tree. Absent,
/// SYSTAG_RamBase + SYSTAG_RamSize.
pub const SYSTAG_RamEnd = SYSTAG_Dummy + 31;
/// The cores' clock the board wants, in MHz: a speed its chip has an
/// operating point for, which the kernel sets as it starts - before
/// anything else runs - with the supply the point wants, through the
/// board's own code. The JH7110: 1000, as its firmware leaves it, or
/// 1500. Absent, 0: the clock is left as the firmware left it.
pub const SYSTAG_CpuSpeed = SYSTAG_Dummy + 32;
/// 1: the machine's devices see the cores' data caches - QEMU's virt,
/// whose devices read and write the machine's RAM through the host's
/// caches - so what a DMA engine or a display reads is what a core wrote,
/// with nothing written back first, and what it writes a core reads.
/// Absent, 0: they go past the caches, and a range a device reads or
/// writes is written back or dropped (CacheClearE, CachePreDMA,
/// CachePostDMA). Read on an AArch64 machine; a RISC-V one names its
/// cache controller instead (SYSTAG_CacheFlush).
pub const SYSTAG_DmaCoherent = SYSTAG_Dummy + 33;
/// How many sources the PLIC has after source 0, as its device tree node
/// says (`riscv,ndev`): QEMU's virt 95, the JH7110 136. Only those are
/// set up and taken. Absent, the most any machine here has.
pub const SYSTAG_PlicSources = SYSTAG_Dummy + 34;

pub const PSRAM_NONE: usize = 0;
pub const PSRAM_QUAD: usize = 1;
pub const PSRAM_OCTAL: usize = 2;

/// UART0, which the boot ROM talks on too.
pub const CONSOLE_UART0: usize = 0;
/// The chip's own USB port, as a serial line (usbserial.device).
pub const CONSOLE_USBJTAG: usize = 1;

// --- a part --------------------------------------------------------------------

pub const PART_Dummy = TAG_USER + 0x50100;

/// What the part is for (PARTKIND_*).
pub const PART_Kind = PART_Dummy + 1;
/// Which chip it is (CHIP_*), and its name as a C string.
pub const PART_Chip = PART_Dummy + 2;
pub const PART_ChipName = PART_Dummy + 3;
/// How it is reached (BUS_*), which unit of that bus, and at which
/// address on it.
pub const PART_Bus = PART_Dummy + 4;
pub const PART_BusUnit = PART_Dummy + 5;
pub const PART_Address = PART_Dummy + 6;
/// How far it is turned against the screen, in degrees (a touch panel
/// mounted on its side).
pub const PART_Turn = PART_Dummy + 7;
/// Non-zero: a stereo output whose speakers take the I2S frame the other
/// way round - its first half, the one I2S calls left, plays on the right
/// speaker and its second on the left.
pub const PART_SidesSwapped = PART_Dummy + 8;
/// A USB socket's roles (USBROLE_* or'd): what the board's wiring lets
/// its controller be on it.
pub const PART_UsbRoles = PART_Dummy + 9;
/// The fastest a USB socket is wired for (USBSPEED_*).
pub const PART_UsbSpeed = PART_Dummy + 10;
/// Where the 5 V a USB host gives what is plugged in comes from
/// (USBVBUS_*). Absent, USBVBUS_NONE.
pub const PART_UsbVbus = PART_Dummy + 11;
/// What the board calls the part, for a person choosing it: a string,
/// "header UART2", "USB-C UART1". ObtainDeviceUnits gives it as the
/// label of the unit the part is.
pub const PART_Label = PART_Dummy + 12;
/// The interrupt the part raises, as exec numbers it (sdk.hardware.intbits),
/// on a machine whose interrupt controller the board wires: a PLIC source.
/// A chip that numbers a part's interrupt once for every board needs none.
pub const PART_Irq = PART_Dummy + 13;
/// A PCI host bridge's configuration space (ECAM: a function's 4 KiB at
/// bus << 20 | device << 15 | function << 12), and the windows the
/// processor reaches its buses' memory through: one below 4 GiB on the
/// bus, and one for prefetchable memory, which may be above. A window's
/// size 0: none. Where a window is at another address on the bus than
/// for the processor, PART_PciMemBus and PART_PciPrefBus say where;
/// absent, it is at the same.
pub const PART_PciConfig = PART_Dummy + 14;
pub const PART_PciMem = PART_Dummy + 15;
pub const PART_PciMemSize = PART_Dummy + 16;
pub const PART_PciPref = PART_Dummy + 17;
pub const PART_PciPrefSize = PART_Dummy + 18;
/// Where the station address the board gives a network port is: six
/// bytes, all zero while there is none. The VisionFive 2's are in its
/// EEPROM, which U-Boot writes into the device tree it passes, and the
/// kernel copies them from there into the bytes before anything runs.
pub const PART_StationAddress = PART_Dummy + 19;
/// The delays a PHY adds on RGMII, in picoseconds: to the receive clock
/// against its data, and to the send clock. A board whose traces delay
/// the clocks themselves says 0.
pub const PART_RxDelay = PART_Dummy + 20;
pub const PART_TxDelay = PART_Dummy + 21;
/// The link speeds a PHY sends its RGMII clock inverted at (LINKSPEED_*
/// or'd): what the board's wiring needs at each.
pub const PART_TxClockInverted = PART_Dummy + 22;
/// How hard a PHY drives the RGMII clock and data lines it sends the MAC,
/// in microamperes.
pub const PART_RxClockDrive = PART_Dummy + 23;
pub const PART_RxDataDrive = PART_Dummy + 24;
/// A PCI host bridge's window onto its buses' I/O space: where the
/// processor reaches it, its size (0: none), and the first port it is
/// on the bus - absent, port 0.
pub const PART_PciIo = PART_Dummy + 25;
pub const PART_PciIoSize = PART_Dummy + 26;
pub const PART_PciIoBus = PART_Dummy + 27;
/// Where a PCI host bridge's windows (PART_PciMem, PART_PciPref) are on
/// the bus, where that is not where the processor reaches them.
pub const PART_PciMemBus = PART_Dummy + 28;
pub const PART_PciPrefBus = PART_Dummy + 29;
/// A row of like register windows the part is behind one of, not known
/// which until they are looked at - QEMU's virtio-mmio transports:
/// PART_Address the first, PART_Windows how many, PART_WindowSize how
/// far apart.
pub const PART_Windows = PART_Dummy + 30;
pub const PART_WindowSize = PART_Dummy + 31;

// Its lines, each a BoardPin. Which ones a part has depends on its kind.
pub const PART_PinClock = PART_Dummy + 0x20;
pub const PART_PinCommand = PART_Dummy + 0x21;
pub const PART_PinData0 = PART_Dummy + 0x22;
pub const PART_PinData1 = PART_Dummy + 0x23;
pub const PART_PinData2 = PART_Dummy + 0x24;
pub const PART_PinData3 = PART_Dummy + 0x25;
pub const PART_PinDetect = PART_Dummy + 0x26;
pub const PART_PinWriteProtect = PART_Dummy + 0x27;
pub const PART_PinInt = PART_Dummy + 0x28;
pub const PART_PinReset = PART_Dummy + 0x29;
pub const PART_PinSCL = PART_Dummy + 0x2A;
pub const PART_PinSDA = PART_Dummy + 0x2B;
pub const PART_PinMCLK = PART_Dummy + 0x2C;
pub const PART_PinBCLK = PART_Dummy + 0x2D;
pub const PART_PinWS = PART_Dummy + 0x2E;
pub const PART_PinDataOut = PART_Dummy + 0x2F;
pub const PART_PinDataIn = PART_Dummy + 0x30;
/// A line that switches the part on: an amplifier's shutdown, a
/// transceiver's select.
pub const PART_PinEnable = PART_Dummy + 0x31;
/// The one line of a part that has only one: an LED's data, a battery's
/// sense.
pub const PART_Pin = PART_Dummy + 0x32;
/// A panel's backlight, and the chip select of a part on a shared bus.
pub const PART_PinBacklight = PART_Dummy + 0x33;
pub const PART_PinSelect = PART_Dummy + 0x34;
/// The line that switches a part's supply on.
pub const PART_PinPower = PART_Dummy + 0x35;
/// The line that gives a part pads it shares with another: asserted, the
/// pads are this part's; not asserted, the other's.
pub const PART_PinSwitch = PART_Dummy + 0x36;
/// An Ethernet PHY's RMII lines: two data lines and an enable from the
/// chip, two data lines and carrier sense / data valid to it, and the
/// 50 MHz reference clock both sides run on, which comes in from the
/// PHY. Then the management bus the PHY's registers are read over: its
/// clock and its data line.
pub const PART_PinTxd0 = PART_Dummy + 0x37;
pub const PART_PinTxd1 = PART_Dummy + 0x38;
pub const PART_PinTxEnable = PART_Dummy + 0x39;
pub const PART_PinRxd0 = PART_Dummy + 0x3A;
pub const PART_PinRxd1 = PART_Dummy + 0x3B;
pub const PART_PinCrsDv = PART_Dummy + 0x3C;
pub const PART_PinRefClock = PART_Dummy + 0x3D;
pub const PART_PinMDC = PART_Dummy + 0x3E;
pub const PART_PinMDIO = PART_Dummy + 0x3F;
/// A battery's lines beside its sense (PART_Pin): asserted while
/// external power is there, and while the charger charges.
pub const PART_PinExternal = PART_Dummy + 0x40;
pub const PART_PinCharging = PART_Dummy + 0x41;
/// What a sensed voltage is multiplied by to give the one it was
/// divided down from, in thousandths: 2000 behind a divider that
/// halves it, 3000 behind one that leaves a third.
pub const PART_SenseScale = PART_Dummy + 0x42;
/// A stereo output's two lines, each a side of its own: a PWM DAC's
/// pulses, which the board filters into its jack.
pub const PART_PinLeft = PART_Dummy + 0x43;
pub const PART_PinRight = PART_Dummy + 0x44;

/// A line's role, short, for a listing: "RESET", "SCL", "D0". Null for a
/// tag that is not a line.
pub fn lineName(tag: u32) ?[*:0]const u8 {
    return switch (tag) {
        PART_PinClock => "CLK",
        PART_PinCommand => "CMD",
        PART_PinData0 => "D0",
        PART_PinData1 => "D1",
        PART_PinData2 => "D2",
        PART_PinData3 => "D3",
        PART_PinDetect => "DETECT",
        PART_PinWriteProtect => "WP",
        PART_PinInt => "INT",
        PART_PinReset => "RESET",
        PART_PinSCL => "SCL",
        PART_PinSDA => "SDA",
        PART_PinMCLK => "MCLK",
        PART_PinBCLK => "BCLK",
        PART_PinWS => "WS",
        PART_PinDataOut => "DOUT",
        PART_PinDataIn => "DIN",
        PART_PinEnable => "EN",
        PART_Pin => "PIN",
        PART_PinBacklight => "BL",
        PART_PinSelect => "CS",
        PART_PinPower => "PWR",
        PART_PinSwitch => "SEL",
        PART_PinTxd0 => "TXD0",
        PART_PinTxd1 => "TXD1",
        PART_PinTxEnable => "TX_EN",
        PART_PinRxd0 => "RXD0",
        PART_PinRxd1 => "RXD1",
        PART_PinCrsDv => "CRS_DV",
        PART_PinRefClock => "REF_CLK",
        PART_PinMDC => "MDC",
        PART_PinMDIO => "MDIO",
        PART_PinExternal => "EXT",
        PART_PinCharging => "CHRG",
        PART_PinLeft => "LEFT",
        PART_PinRight => "RIGHT",
        else => null,
    };
}

// What a part is for.
pub const PARTKIND_ANY: u32 = 0xFFFF_FFFF;
pub const PARTKIND_I2CBUS: u32 = 1;
pub const PARTKIND_SDSLOT: u32 = 2;
pub const PARTKIND_TOUCH: u32 = 3;
pub const PARTKIND_CODEC: u32 = 4;
pub const PARTKIND_AMPLIFIER: u32 = 5;
pub const PARTKIND_EXPANDER: u32 = 6;
pub const PARTKIND_PANEL: u32 = 7;
pub const PARTKIND_LED: u32 = 8;
pub const PARTKIND_BATTERY: u32 = 9;
pub const PARTKIND_KEYBOARD: u32 = 10;
/// A pointer that moves and has buttons: a mouse, or a window's pointer.
pub const PARTKIND_MOUSE: u32 = 11;
/// A network interface: a MAC, and the link behind it.
pub const PARTKIND_NET: u32 = 12;
/// A CAN bus transceiver and its connector.
pub const PARTKIND_CAN: u32 = 13;
/// An RS-485 transceiver and its connector.
pub const PARTKIND_RS485: u32 = 14;
/// A push button a program can read.
pub const PARTKIND_BUTTON: u32 = 15;
/// A connector that brings a pad out for whatever is plugged into it.
pub const PARTKIND_HEADER: u32 = 16;
/// A USB controller and the socket the board brings it out to: its
/// PART_BusUnit says which of the chip's controllers, PART_UsbRoles,
/// PART_UsbSpeed and PART_UsbVbus how the socket is wired, PART_PinReset
/// a hub on the board held in reset until the bus starts, and
/// PART_PinSwitch the line that gives the socket's pads to it.
pub const PARTKIND_USB: u32 = 17;
/// A UART a program may use: PART_BusUnit says which of the chip's UARTs
/// - serial.device's unit - and PART_Label where the board brings it
/// out. One the system keeps for itself, a console, is not listed.
pub const PARTKIND_UART: u32 = 18;
/// A clock that keeps the date: a chip on its own cell, which keeps it
/// while the board is off - PART_Bus and PART_BusUnit the I2C bus,
/// PART_Address the chip - or the chip's own RTC (BUS_MEMORY,
/// PART_Address its registers). battclock.resource keeps the date in it.
pub const PARTKIND_RTC: u32 = 19;
/// A random number generator in the chip, which sdk.hardware.rng reads:
/// PART_Address where its registers are (BUS_MEMORY).
pub const PARTKIND_RNG: u32 = 20;
/// A PCI or PCI Express host bridge, which pci.library brings up and
/// walks: PART_Chip which bridge, PART_PciConfig its configuration space,
/// PART_PciMem, PART_PciPref and PART_PciIo its windows (and where each
/// is on the bus, if not where the processor has it), PART_BusUnit which
/// of the chip's bridges it is, PART_Irq its interrupt -
/// the first of its INTA to INTD where they are sources of their own -
/// and PART_PinReset the line that holds what is plugged in in reset
/// (PERST#).
pub const PARTKIND_PCI: u32 = 21;
/// A DMA controller in the chip, whose channels dma.resource hands out:
/// PART_Chip which, PART_Address its registers (BUS_MEMORY), PART_Irq the
/// interrupt its channels share.
pub const PARTKIND_DMA: u32 = 22;
/// A temperature sensor, which thermal.resource reads: PART_Chip which,
/// PART_Address its registers (BUS_MEMORY), PART_Label what it measures
/// ("SoC"). The board's sensors are thermal.resource's units in the order
/// the board lists them.
pub const PARTKIND_THERMAL: u32 = 23;
/// A crypto engine in the chip, which crypto.library hands its work to:
/// PART_Chip which, PART_Address its registers (BUS_MEMORY), PART_Irq its
/// interrupt.
pub const PARTKIND_CRYPTO: u32 = 24;
/// A JPEG codec in the chip, which jpeg.resource decodes with: PART_Chip
/// which, PART_Address its registers (BUS_MEMORY), PART_Irq its
/// interrupt.
pub const PARTKIND_JPEG: u32 = 25;
/// A video decoder in the chip, which videodec.resource decodes with:
/// PART_Chip which, PART_Address its registers (BUS_MEMORY), PART_Irq its
/// interrupt.
pub const PARTKIND_VIDEODEC: u32 = 26;

// Which chip. CHIP_NONE is a part that is no chip of its own: a bus, a
// slot, a pad.
pub const CHIP_ANY: u32 = 0xFFFF_FFFF;
pub const CHIP_NONE: u32 = 0;
pub const CHIP_GT911: u32 = 1;
pub const CHIP_ST7123: u32 = 2;
pub const CHIP_ES8311: u32 = 3;
pub const CHIP_CH422G: u32 = 4;
pub const CHIP_ST77922: u32 = 5;
pub const CHIP_WS2812: u32 = 6;
pub const CHIP_SC8002B: u32 = 7;
/// An RGB panel driven straight by LCD_CAM, with no controller to talk to.
pub const CHIP_RGB_PANEL: u32 = 8;
/// The emulator's virtual display, which gives its window's pointer and
/// keys as well: the display, the keyboard and the mouse parts of the
/// qemu board are all this one.
pub const CHIP_QEMU_DISPLAY: u32 = 9;
/// The emulator's OpenCores Ethernet MAC.
pub const CHIP_OPENETH: u32 = 10;
/// The chip's own 2.4 GHz radio, on a board whose module gives it an
/// antenna (esp32s3wifi.device).
pub const CHIP_ESP32S3_RADIO: u32 = 11;
pub const CHIP_TJA1051: u32 = 12;
pub const CHIP_SP3485: u32 = 13;
/// A battery charger, with the battery's voltage for a program to read.
pub const CHIP_CS8501: u32 = 14;
/// An Ethernet PHY, 10/100 Mbit/s (PARTKIND_NET on BUS_RMII; its
/// PART_Address is its address on the management bus).
pub const CHIP_IP101: u32 = 15;
/// Panel controllers on MIPI-DSI (PARTKIND_PANEL on BUS_MIPI_DSI).
pub const CHIP_ST7701: u32 = 16;
pub const CHIP_EK79007: u32 = 17;
/// A MIPI-DSI to HDMI bridge (PARTKIND_PANEL on BUS_MIPI_DSI): set up over
/// I2C (PART_BusUnit, PART_Address its main page), RGB888 on the link, a
/// monitor behind it.
pub const CHIP_LT8912B: u32 = 18;
/// A class-D amplifier that takes I2S itself (PARTKIND_AMPLIFIER on
/// BUS_I2S): bit clock, word clock and data, no master clock and nothing
/// to set up; PART_PinEnable switches it on.
pub const CHIP_NS4168: u32 = 19;
/// The chip's own Synopsys DWC2 USB OTG controller (PARTKIND_USB on
/// BUS_MEMORY): on the ESP32-S3 the full-speed one, unit 0; on the
/// ESP32-P4 the high-speed one, unit 0, and the full-speed one, unit 1.
pub const CHIP_DWC2: u32 = 20;
/// A one-cell lithium charger whose status reaches only its LED.
pub const CHIP_TP4054: u32 = 21;
/// NXP's PCF8563 clock (PARTKIND_RTC), at 0x51 on I2C; the BM8563 is the
/// same chip to a driver.
pub const CHIP_PCF8563: u32 = 22;
/// The JH7110's TRNG, in its security block (PARTKIND_RNG on
/// BUS_MEMORY), which the kernel starts.
pub const CHIP_JH7110_TRNG: u32 = 23;
/// QEMU's ramfb (PARTKIND_PANEL on BUS_MEMORY): a picture in RAM the
/// emulator shows, set up through its firmware configuration device, whose
/// registers PART_Address names.
pub const CHIP_QEMU_RAMFB: u32 = 24;
/// The JH7110's display controller and its HDMI transmitter
/// (PARTKIND_PANEL on BUS_MEMORY, PART_Address the controller): 1920x1080
/// at 60 Hz, as the board's firmware sets it up.
pub const CHIP_JH7110_DC8200: u32 = 25;
/// A PCI host bridge that is nothing but its configuration space and its
/// windows, as the firmware or the emulator set them up (PARTKIND_PCI on
/// BUS_MEMORY): QEMU's "pci-host-ecam-generic". A slot's INTA to INTD are
/// PART_Irq on, rotated by the slot's number.
pub const CHIP_PCI_ECAM: u32 = 26;
/// One of the JH7110's two PCI Express root ports, PLDA's XpressRICH
/// (PARTKIND_PCI on BUS_MEMORY): PART_BusUnit which one, PART_Address its
/// bridge's registers; its INTA to INTD are gathered on PART_Irq.
pub const CHIP_JH7110_PCIE: u32 = 27;
/// An xHCI USB host controller, found on PCI (PARTKIND_USB on BUS_PCI):
/// PART_BusUnit says which, counting the machine's xHCI functions in the
/// order pci.library has them (xhci.device's unit).
pub const CHIP_XHCI: u32 = 28;
/// Motorcomm's YT8531, a 10/100/1000 Mbit/s Ethernet PHY (PARTKIND_NET on
/// BUS_RGMII): PART_BusUnit the MAC it is wired to, PART_Address its
/// address on that MAC's management bus.
pub const CHIP_YT8531: u32 = 29;
/// The JH7110's HDMI transmitter as the machine's sound (PARTKIND_CODEC on
/// BUS_MEMORY, PART_Address the transmitter): I2STX0's stream, which a
/// channel of the chip's DMA controller (CHIP_JH7110_DMAC) feeds, with the
/// board's 12.288 MHz oscillator as its master clock, in on PART_PinMCLK.
/// Only while the picture (CHIP_JH7110_DC8200) is up.
pub const CHIP_JH7110_HDMI: u32 = 30;
/// The JH7110's DMA controller, Synopsys's DesignWare AXI DMA with four
/// channels (PARTKIND_DMA on BUS_MEMORY), which dma.resource clocks and
/// hands out as its DWDMA channels.
pub const CHIP_JH7110_DMAC: u32 = 31;
/// The JH7110's own temperature sensor (PARTKIND_THERMAL on BUS_MEMORY),
/// beside its cores: one reading, 12 bits, which thermal.resource clocks
/// and turns into degrees.
pub const CHIP_JH7110_TEMP: u32 = 32;
/// QEMU's virtio GPU on a virtio-mmio transport (PARTKIND_PANEL on
/// BUS_MEMORY, the transports PART_Address, PART_Windows and
/// PART_WindowSize): a picture in RAM copied into the emulator's window a
/// rectangle at a time, and a pointer of its own.
pub const CHIP_VIRTIO_GPU: u32 = 33;
/// The JH7110's PWM-DAC as the machine's sound (PARTKIND_CODEC on
/// BUS_MEMORY, PART_Address the DAC): a stereo stream of 16-bit samples,
/// which a channel of the chip's DMA controller (CHIP_JH7110_DMAC) feeds,
/// turned into pulses on PART_PinLeft and PART_PinRight - the VisionFive
/// 2's audio jack.
pub const CHIP_JH7110_PWMDAC: u32 = 34;
/// The JH7110's own RTC (PARTKIND_RTC on BUS_MEMORY, PART_Address its
/// registers): the date in BCD from 2000 to 2099, counted from the
/// board's 32.768 kHz oscillator. A reset stops it and keeps the date; a
/// power cut loses it.
pub const CHIP_JH7110_RTC: u32 = 35;
/// The DMA controller in the JH7110's security block, ARM's PL080 with
/// eight channels (PARTKIND_DMA on BUS_MEMORY), which feeds the crypto
/// engine (CHIP_JH7110_CRYPTO) and which dma.resource hands out as its
/// PL080 channels.
pub const CHIP_JH7110_SDMA: u32 = 36;
/// The JH7110's crypto engine, in its security block (PARTKIND_CRYPTO on
/// BUS_MEMORY): AES with 128-, 192- and 256-bit keys in ECB, CBC, CTR,
/// CCM and GCM, SHA-2 and SM3 with HMAC, and a big-number unit, its data
/// moved by the block's DMA controller (CHIP_JH7110_SDMA).
pub const CHIP_JH7110_CRYPTO: u32 = 37;
/// The JH7110's JPEG codec, Chips&Media's CODAJ12 (PARTKIND_JPEG on
/// BUS_MEMORY): baseline files of 8-bit samples into YCbCr planes, in the
/// video decoder's power domain.
pub const CHIP_JH7110_JPU: u32 = 38;
/// The JH7110's video decoder, Chips&Media's WAVE511 (PARTKIND_VIDEODEC
/// on BUS_MEMORY): H.264 and H.265 into 4:2:0 frames, run by a firmware
/// the host loads, in the video decoder's power domain beside the JPU.
pub const CHIP_JH7110_VDEC: u32 = 39;

// How a part is reached.
pub const BUS_NONE: u32 = 0;
pub const BUS_I2C: u32 = 1;
pub const BUS_SPI: u32 = 2;
pub const BUS_I2S: u32 = 3;
pub const BUS_SDIO: u32 = 4;
pub const BUS_RMT: u32 = 5;
pub const BUS_ADC: u32 = 6;
/// LCD_CAM's parallel bus.
pub const BUS_LCD: u32 = 7;
/// Memory-mapped: the emulator's devices.
pub const BUS_MEMORY: u32 = 8;
/// A UART of the chip.
pub const BUS_UART: u32 = 9;
/// The chip's CAN controller (TWAI).
pub const BUS_TWAI: u32 = 10;
/// The chip's Ethernet MAC, to a PHY over RMII.
pub const BUS_RMII: u32 = 11;
/// The chip's MIPI-DSI host, to a panel or a bridge.
pub const BUS_MIPI_DSI: u32 = 12;
/// A function on PCI, reached through pci.library.
pub const BUS_PCI: u32 = 13;
/// One of the chip's Ethernet MACs, to a PHY over RGMII: PART_BusUnit
/// which MAC.
pub const BUS_RGMII: u32 = 14;

// A network link's speeds (PART_TxClockInverted).
pub const LINKSPEED_10: u32 = 1 << 0;
pub const LINKSPEED_100: u32 = 1 << 1;
pub const LINKSPEED_1000: u32 = 1 << 2;

// A USB socket's roles (PART_UsbRoles).
/// The controller may be the host: it gives the bus its frames, and
/// keyboards, sticks and hubs are plugged in.
pub const USBROLE_HOST: u32 = 1 << 0;
/// The controller may be a device another host drives.
pub const USBROLE_DEVICE: u32 = 1 << 1;

// How fast a USB socket is wired (PART_UsbSpeed).
pub const USBSPEED_LOW: u32 = 0;
pub const USBSPEED_FULL: u32 = 1;
pub const USBSPEED_HIGH: u32 = 2;

// Where a USB host's 5 V comes from (PART_UsbVbus).
/// The board gives none: what is plugged in needs a supply of its own,
/// a powered hub or an adapter that feeds 5 V in.
pub const USBVBUS_NONE: u32 = 0;
/// The board gives it whenever it runs; a hub on the board may switch
/// each of its sockets itself.
pub const USBVBUS_ALWAYS: u32 = 1;
/// The board switches it with the part's PART_PinPower.
pub const USBVBUS_PIN: u32 = 2;
