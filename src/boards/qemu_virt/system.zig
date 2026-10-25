// SPDX-License-Identifier: MPL-2.0
//! QEMU's RISC-V 64 `virt` machine under the OpenSBI QEMU brings
//! (`./zig build virt`): 512 MiB of RAM at 0x80000000, a 16550 console
//! at 0x10000000 with byte-wide registers one after the other (QEMU
//! gives its divisor a 3.6864 MHz clock) on PLIC source 10, a 10 MHz
//! timebase, and the PLIC's 95 sources and its contexts two per hart,
//! machine mode first.
//! With `-device virtio-gpu-device` or `-device ramfb` a display too,
//! 1920x1080 as the VisionFive 2's.
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

/// The machine, as QEMU names it.
const name = "QEMU RISC-V virt";

/// The picture: the VisionFive 2's, so what is seen in the window is
/// what its HDMI port shows.
const screen = struct {
    pub const width: u32 = 1920;
    pub const height: u32 = 1080;
};

/// The firmware configuration device, which the ramfb is set up through.
const fw_cfg: usize = 0x1010_0000;

// --- the display ------------------------------------------------------------------

/// QEMU's virtio GPU, there when QEMU is started with `-device
/// virtio-gpu-device`: behind one of the machine's 8 virtio-mmio
/// transports, 0x1000 bytes apart from 0x1000_1000, of which QEMU gives the
/// first device added the last. The picture is as large as QEMU's window
/// has it (`xres`, `yres`), the part's size where it says none. Listed
/// before the ramfb, so a machine with both shows the GPU.
const gpu = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_PANEL),
    .value(st.PART_Chip, st.CHIP_VIRTIO_GPU),
    .pointer(st.PART_ChipName, "virtio-gpu"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_Address, 0x1000_1000),
    .value(st.PART_Windows, 8),
    .value(st.PART_WindowSize, 0x1000),
    .value(tags.RTGA_Width, screen.width),
    .value(tags.RTGA_Height, screen.height),
    .value(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.bgra32)),
    // At most sixteen pictures at once - screens, and the buffers behind
    // them - each taken from memory as it is opened: a ceiling, not memory
    // set aside.
    .value(tags.RTGA_Buffers, 16),
    // The windows of a screen each draw into a buffer of their own, and
    // what can be seen of them is copied into the screen's: memory here
    // reads back fast, and nothing a window loses to being covered has to
    // be drawn again.
    .value(tags.RTGA_Compose, 1),
    .done,
};

/// QEMU's ramfb, there when QEMU is started with `-device ramfb`: a
/// picture in RAM the emulator shows in its window. What the fb rtg driver
/// is told comes with it.
const display = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_PANEL),
    .value(st.PART_Chip, st.CHIP_QEMU_RAMFB),
    .pointer(st.PART_ChipName, "qemu ramfb"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_Address, fw_cfg),
    .value(tags.RTGA_Width, screen.width),
    .value(tags.RTGA_Height, screen.height),
    .value(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.bgra32)),
    // At most sixteen pictures at once - screens, and the buffers behind
    // them - each taken from memory as it is opened: a ceiling, not memory
    // set aside.
    .value(tags.RTGA_Buffers, 16),
    // The windows of a screen each draw into a buffer of their own, and
    // what can be seen of them is copied into the screen's: memory here
    // reads back fast, and nothing a window loses to being covered has to
    // be drawn again.
    .value(tags.RTGA_Compose, 1),
    .done,
};

// --- PCI ---------------------------------------------------------------------------

/// The machine's PCI Express host bridge, which QEMU sets up itself: its
/// configuration space at 0x30000000 (256 buses), memory below 4 GiB at
/// 0x40000000 and above it at 16 GiB, its I/O space's 64 KiB at
/// 0x03000000, its slots' INTA to INTD on PLIC sources 32 to 35. What
/// `-device` adds is behind it.
const pci_host = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_PCI),
    .value(st.PART_Chip, st.CHIP_PCI_ECAM),
    .pointer(st.PART_ChipName, "pci-host-ecam-generic"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_PciConfig, 0x3000_0000),
    .value(st.PART_PciMem, 0x4000_0000),
    .value(st.PART_PciMemSize, 0x4000_0000),
    .value(st.PART_PciPref, 0x4_0000_0000),
    .value(st.PART_PciPrefSize, 0x4_0000_0000),
    .value(st.PART_PciIo, 0x0300_0000),
    .value(st.PART_PciIoSize, 0x1_0000),
    .value(st.PART_Irq, 32),
    .pointer(st.PART_Label, "PCI Express"),
    .done,
};

/// The USB bus of an xHCI controller added with `-device qemu-xhci`: the
/// first xHCI function on PCI. Without one, xhci.device finds none and
/// the bus does not start.
const usb = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_USB),
    .value(st.PART_Chip, st.CHIP_XHCI),
    .pointer(st.PART_ChipName, "qemu-xhci"),
    .value(st.PART_Bus, st.BUS_PCI),
    .value(st.PART_BusUnit, 0),
    .value(st.PART_UsbRoles, st.USBROLE_HOST),
    .value(st.PART_UsbSpeed, st.USBSPEED_HIGH),
    .value(st.PART_UsbVbus, st.USBVBUS_ALWAYS),
    .pointer(st.PART_Label, "USB (qemu-xhci)"),
    .done,
};

/// The root list: the board's own facts and a SYSTAG_Part per part.
/// `boards.fact` reads it at compile time for the kernel.
pub const root = [_]Tag{
    .pointer(st.SYSTAG_Name, name),
    .value(st.SYSTAG_RamBase, 0x8000_0000),
    .value(st.SYSTAG_RamSize, 512 * 1024 * 1024),
    .value(st.SYSTAG_UnifiedMemory, 1),
    .value(st.SYSTAG_Timebase, 10_000_000),
    .value(st.SYSTAG_Console, st.CONSOLE_UART0),
    .value(st.SYSTAG_ConsoleBase, 0x1000_0000),
    .value(st.SYSTAG_ConsoleShift, 0),
    .value(st.SYSTAG_ConsoleWide, 0),
    .value(st.SYSTAG_ConsoleClock, 3_686_400),
    .value(st.SYSTAG_ConsoleIrq, 10),
    .value(st.SYSTAG_PlicFirst, 1),
    .value(st.SYSTAG_PlicStride, 2),
    .value(st.SYSTAG_PlicSources, 95),
    // As many as `-smp` gives the machine, up to four.
    .value(st.SYSTAG_Cores, 4),
    .value(st.SYSTAG_ScreenWidth, screen.width),
    .value(st.SYSTAG_ScreenHeight, screen.height),
    .pointer(st.SYSTAG_Part, &gpu),
    .pointer(st.SYSTAG_Part, &display),
    .pointer(st.SYSTAG_Part, &pci_host),
    .pointer(st.SYSTAG_Part, &usb),
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
