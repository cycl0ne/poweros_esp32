// SPDX-License-Identifier: MPL-2.0
//! StarFive's VisionFive 2 (v1.3B): a JH7110 - four SiFive U74 harts
//! (1-4; hart 0 is the S7 monitor core, with no supervisor mode) - with 8
//! GiB of LPDDR4 from 0x40000000, booted by its SPI flash's SPL, OpenSBI
//! and U-Boot, whose `booti` enters the kernel in supervisor mode on the
//! hart OpenSBI picked. UART0, the debug console on header pins 8 and 10,
//! is a DesignWare APB UART: 32-bit registers four bytes apart, a 24 MHz
//! clock, PLIC source 32. The timebase is 4 MHz. The PLIC's contexts are
//! two per hart, machine mode first, hart 0's machine context alone at 0:
//! hart n's supervisor context is 2n. (docs/memory-map.md in the port's
//! repository has the board as read from it.)
//!
//! What is true of the board is written down here once, as the system tag
//! list the ROM carries for expansion.library (a part per SYSTAG_Part). The
//! kernel reads the same list at compile time (`boards.fact`). RAM is as
//! the device tree U-Boot passes says, where it says.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const tags = rtg.tags;
const Tag = sdk.utility.FixedTagItem;
const st = sdk.expansion.systemtags;

/// The board, as StarFive names it.
const name = "StarFive VisionFive 2";

/// The TRNG in the JH7110's security block.
const trng = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_RNG),
    .value(st.PART_Chip, st.CHIP_JH7110_TRNG),
    .pointer(st.PART_ChipName, "jh7110 trng"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_Address, 0x1600_C000),
    .done,
};

/// The HDMI port's picture: the one mode the display path is set up for.
const screen = struct {
    pub const width: u32 = 1920;
    pub const height: u32 = 1080;
};

/// The display controller behind the HDMI port, which reads its picture
/// out of RAM: what the fb rtg driver is told comes with it.
const display = [_]Tag{
    .value(st.PART_Kind, st.PARTKIND_PANEL),
    .value(st.PART_Chip, st.CHIP_JH7110_DC8200),
    .pointer(st.PART_ChipName, "jh7110 dc8200 hdmi"),
    .value(st.PART_Bus, st.BUS_MEMORY),
    .value(st.PART_Address, 0x2940_0000),
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
    .value(st.SYSTAG_RamBase, 0x4000_0000),
    .value(st.SYSTAG_RamSize, 4 * 1024 * 1024 * 1024),
    .value(st.SYSTAG_UnifiedMemory, 1),
    .value(st.SYSTAG_Timebase, 4_000_000),
    .value(st.SYSTAG_Console, st.CONSOLE_UART0),
    .value(st.SYSTAG_ConsoleBase, 0x1000_0000),
    .value(st.SYSTAG_ConsoleShift, 2),
    .value(st.SYSTAG_ConsoleWide, 1),
    .value(st.SYSTAG_ConsoleClock, 24_000_000),
    .value(st.SYSTAG_ConsoleIrq, 32),
    .value(st.SYSTAG_PlicFirst, 0),
    .value(st.SYSTAG_PlicStride, 2),
    // The L2 cache controller's Flush64: the JH7110's devices do not see
    // the U74s' caches.
    .value(st.SYSTAG_CacheFlush, 0x0201_0200),
    .value(st.SYSTAG_Cores, 1),
    .value(st.SYSTAG_ScreenWidth, screen.width),
    .value(st.SYSTAG_ScreenHeight, screen.height),
    .pointer(st.SYSTAG_Part, &display),
    .pointer(st.SYSTAG_Part, &trng),
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
