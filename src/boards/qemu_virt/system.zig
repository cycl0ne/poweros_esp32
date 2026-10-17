// SPDX-License-Identifier: MPL-2.0
//! QEMU's RISC-V 64 `virt` machine under the OpenSBI QEMU brings
//! (`./zig build virt`): 512 MiB of RAM at 0x80000000, a 16550 console
//! at 0x10000000 with byte-wide registers one after the other (QEMU
//! gives its divisor a 3.6864 MHz clock) on PLIC source 10, a 10 MHz
//! timebase, and the PLIC's contexts two per hart, machine mode first.
//! With `-device ramfb` a display too, 1920x1080 as the VisionFive 2's.
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
    .value(tags.RTGA_Buffers, 3),
    .done,
};

/// The root list: the board's own facts and a SYSTAG_Part per part.
/// `boards.fact` reads it at compile time for the kernel.
pub const root = [_]Tag{
    .pointer(st.SYSTAG_Name, name),
    .value(st.SYSTAG_RamBase, 0x8000_0000),
    .value(st.SYSTAG_RamSize, 512 * 1024 * 1024),
    .value(st.SYSTAG_Timebase, 10_000_000),
    .value(st.SYSTAG_Console, st.CONSOLE_UART0),
    .value(st.SYSTAG_ConsoleBase, 0x1000_0000),
    .value(st.SYSTAG_ConsoleShift, 0),
    .value(st.SYSTAG_ConsoleWide, 0),
    .value(st.SYSTAG_ConsoleClock, 3_686_400),
    .value(st.SYSTAG_ConsoleIrq, 10),
    .value(st.SYSTAG_PlicFirst, 1),
    .value(st.SYSTAG_PlicStride, 2),
    .value(st.SYSTAG_Cores, 1),
    .value(st.SYSTAG_ScreenWidth, screen.width),
    .value(st.SYSTAG_ScreenHeight, screen.height),
    .pointer(st.SYSTAG_Part, &display),
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
