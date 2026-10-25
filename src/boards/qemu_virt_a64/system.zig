// SPDX-License-Identifier: MPL-2.0
//! QEMU's AArch64 `virt` machine with Cortex-A76 cores and a GICv2, all
//! of it below 4 GiB (`./zig build virt64`: `-M virt,gic-version=2,
//! highmem=off -cpu cortex-a76`): 512 MiB of RAM at 0x40000000, a PL011
//! console at 0x09000000 with a 24 MHz clock on interrupt ID 33, the
//! GIC's distributor at 0x08000000 and its CPU interface at 0x08010000.
//! The generic timer's rate is the core's own (CNTFRQ_EL0). With
//! `-device virtio-gpu-device` or `-device ramfb` a display too,
//! 1920x1080 as on the RISC-V board.
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
const name = "QEMU AArch64 virt";

/// The picture: 1920x1080, as the RISC-V virt board's.
const screen = struct {
    pub const width: u32 = 1920;
    pub const height: u32 = 1080;
};

/// The firmware configuration device, which the ramfb is set up through.
const fw_cfg: usize = 0x0902_0000;

// --- the display ------------------------------------------------------------------

/// QEMU's virtio GPU, there when QEMU is started with `-device
/// virtio-gpu-device`: behind one of the machine's 32 virtio-mmio
/// transports, 0x200 bytes apart from 0x0A00_0000, of which QEMU gives the
/// first device added the last. The picture is as large as QEMU's window
/// has it (`xres`, `yres`), the part's size where it says none. Listed
/// before the ramfb, so a machine with both shows the GPU.
const gpu = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_PANEL),
    .value(st.PART_Chip, st.CHIP_VIRTIO_GPU),
    .pointer(st.PART_ChipName, "virtio-gpu"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_Address, 0x0A00_0000),
    .value(st.PART_Windows, 32),
    .value(st.PART_WindowSize, 0x200),
    .value(tags.RTGA_Width, screen.width),
    .value(tags.RTGA_Height, screen.height),
    .value(tags.RTGA_PixelFormat, @intFromEnum(rtg.PixelFormat.bgra32)),
    // At most sixteen pictures at once - screens, and the buffers behind
    // them - each taken from memory as it is opened: a ceiling, not memory
    // set aside.
    .value(tags.RTGA_Buffers, 16),
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
    .done,
};

// --- PCI ---------------------------------------------------------------------------

/// The machine's PCI Express host bridge, which QEMU sets up itself: with
/// highmem=off its configuration space at 0x3F000000 (16 buses), memory
/// at 0x10000000 up to the I/O space's 64 KiB at 0x3EFF0000, and no
/// window above 4 GiB; its slots' INTA to INTD on interrupt IDs 35 to 38
/// (shared interrupts 3 to 6). What `-device` adds is behind it.
const pci_host = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_PCI),
    .value(st.PART_Chip, st.CHIP_PCI_ECAM),
    .pointer(st.PART_ChipName, "pci-host-ecam-generic"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_PciConfig, 0x3F00_0000),
    .value(st.PART_PciMem, 0x1000_0000),
    .value(st.PART_PciMemSize, 0x2EFF_0000),
    .value(st.PART_PciIo, 0x3EFF_0000),
    .value(st.PART_PciIoSize, 0x1_0000),
    .value(st.PART_Irq, 35),
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
    .value(st.SYSTAG_RamBase, 0x4000_0000),
    .value(st.SYSTAG_RamSize, 512 * 1024 * 1024),
    // What -m may give it below the 4 GiB line, with highmem=off.
    .value(st.SYSTAG_RamEnd, 0x1_0000_0000),
    .value(st.SYSTAG_UnifiedMemory, 1),
    // QEMU's devices reach RAM through the host's caches.
    .value(st.SYSTAG_DmaCoherent, 1),
    .value(st.SYSTAG_Timebase, 62_500_000),
    .value(st.SYSTAG_Console, st.CONSOLE_UART0),
    .value(st.SYSTAG_ConsoleBase, 0x0900_0000),
    .value(st.SYSTAG_ConsoleClock, 24_000_000),
    .value(st.SYSTAG_ConsoleIrq, 33),
    .value(st.SYSTAG_GicDist, 0x0800_0000),
    .value(st.SYSTAG_GicCpu, 0x0801_0000),
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
