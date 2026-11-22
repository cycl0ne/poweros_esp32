// SPDX-License-Identifier: MIT
//! The MT7922's registers and the way to them.
//!
//! **Everything is in BAR0**, a megabyte of 32-bit registers. The
//! chip's own addresses are wider than that, so they are reached two
//! ways (`far`): a block the bus maps at a fixed place in BAR0 - the
//! DMA engine, the power and firmware state, the chip's software
//! settings - or, for the rest, a window: the upper half of the address
//! written to the window's register, the lower half then an offset into
//! BAR0 at 0x40000. The window is one for the whole chip, so only the
//! worker uses it.
//!
//! The names are the chip's: WFDMA is its DMA engine, the "own" bits are
//! who holds the chip's power - the driver or the firmware - and WF is
//! the Wi-Fi part of the chip.

const barrier = @import("sdk").hardware.barrier;

// --- registers BAR0 holds directly -------------------------------------------

/// The window's register, and where in BAR0 the window is.
pub const HIF_REMAP_L1: u32 = 0xfe24c;
pub const REMAP_BASE_L1: u32 = 0x40000;

/// Who holds the chip: SET_OWN hands it to the firmware, CLR_OWN takes it
/// back; OWN_SYNC reads 1 while the firmware has it.
pub const CONN_ON_LPCTL: u32 = 0xe0010;
pub const LPCTL_SET_OWN: u32 = 1 << 0;
pub const LPCTL_CLR_OWN: u32 = 1 << 1;
pub const LPCTL_OWN_SYNC: u32 = 1 << 2;

/// The firmware's state: powered on (1 in bits 2:0), and its processor
/// running too (bits 1:0 both set).
pub const CONN_ON_MISC: u32 = 0xe00f0;
pub const MISC_FW_STATE: u32 = 0x7;
pub const MISC_FW_PWR_ON: u32 = 1;
pub const MISC_FW_N9_RDY: u32 = 0x3;

/// The chip's software settings: 0 runs it normally.
pub const SWDEF_MODE: u32 = 0x9f23c;

/// A bit of the driver's own in a register the chip clears when it loses
/// its DMA set-up.
pub const WFDMA_DUMMY_CR: u32 = 0x02120;
pub const DUMMY_NEED_REINIT: u32 = 1 << 1;

/// The DMA scheduler's control: bypassed, frames go straight to the rings.
pub const DMASHDL_SW_CONTROL: u32 = 0xd6004;
pub const DMASHDL_BYPASS: u32 = 1 << 28;

/// The PCI Express side: every interrupt of the chip let through, and
/// the link's L0s state off inside the chip.
pub const PCIE_MAC_INT_ENABLE: u32 = 0x10188;
pub const PCIE_MAC_PM: u32 = 0x10194;
pub const PCIE_L0S_DIS: u32 = 1 << 8;

// --- the DMA engine (WFDMA0) ------------------------------------------------

pub const WFDMA0_RST: u32 = 0xd4100;
pub const RST_LOGIC: u32 = 1 << 4;
pub const RST_DMASHDL_ALL: u32 = 1 << 5;

/// The firmware's own interrupt to the host, acknowledged by writing back
/// what was read, and its enable.
pub const MCU_CMD: u32 = 0xd41f0;
pub const MCU2HOST_SW_INT_ENA: u32 = 0xd41f4;
pub const MCU_CMD_WAKE_RX_PCIE: u32 = 1 << 0;

/// The interrupt causes, written 1 to clear, and their enable.
pub const HOST_INT_STA: u32 = 0xd4200;
pub const HOST_INT_ENA: u32 = 0xd4204;
/// Events on RX ring 0 (before the download) and 4 (after it); frames on
/// RX ring 2.
pub const INT_RX_DONE_WM: u32 = 1 << 0;
pub const INT_RX_DONE_DATA: u32 = 1 << 2;
pub const INT_RX_DONE_WM2: u32 = 1 << 22;
pub const INT_RX_DONE_ALL: u32 = INT_RX_DONE_WM | INT_RX_DONE_DATA | INT_RX_DONE_WM2;
/// TX rings 0 to 14, and the command ring 17. The firmware ring's own
/// (16) stays off: it is reclaimed by reading its index.
pub const INT_TX_DONE_ALL: u32 = 0x0807fff0;
pub const INT_MCU_CMD: u32 = 1 << 29;
pub const INT_WANTED: u32 = INT_TX_DONE_ALL | INT_RX_DONE_ALL | INT_MCU_CMD;

pub const GLO_CFG: u32 = 0xd4208;
pub const GLO_TX_DMA_EN: u32 = 1 << 0;
pub const GLO_TX_DMA_BUSY: u32 = 1 << 1;
pub const GLO_RX_DMA_EN: u32 = 1 << 2;
pub const GLO_RX_DMA_BUSY: u32 = 1 << 3;
/// What is cleared to stop the engine: both directions, the pointer
/// chain and the descriptors' info words.
pub const GLO_STOP: u32 = 0x18208005;
/// What the engine runs with: written-back done bits, little-endian
/// FIFOs, no clock gating, no TX info, the largest bursts, the pointer
/// chain.
pub const GLO_RUN: u32 = 0x5020b870;

pub const RST_DTX_PTR: u32 = 0xd420c;
pub const GLO_CFG_EXT0: u32 = 0xd42b0;
pub const EXT0_TX_DMASHDL_EN: u32 = 1 << 6;
pub const PRI_DLY_INT_CFG0: u32 = 0xd42f0;
pub const TX_RING0_EXT_CTRL: u32 = 0xd4600;

/// Each ring's four registers - its descriptors' address, their count,
/// the host's index, the engine's - 16 bytes apart from a block's base.
pub const TX_RING_BASE: u32 = 0xd4300;
pub const RX_RING_BASE: u32 = 0xd4500;
pub const RING_STEP: u32 = 0x10;
pub const RING_DESC_BASE: u32 = 0x0;
pub const RING_COUNT: u32 = 0x4;
pub const RING_CPU_IDX: u32 = 0x8;
pub const RING_DMA_IDX: u32 = 0xc;

/// Each ring's prefetch: where its share of the engine's prefetch memory
/// starts (bits 31:16) and how many descriptors it takes (7:0).
pub const Prefetch = struct { at: u32, value: u32 };
pub const prefetch = [_]Prefetch{
    .{ .at = 0xd4680, .value = 0x00000004 }, // RX 0
    .{ .at = 0xd4688, .value = 0x00400004 }, // RX 2
    .{ .at = 0xd468c, .value = 0x00800004 }, // RX 3
    .{ .at = 0xd4690, .value = 0x00c00004 }, // RX 4
    .{ .at = 0xd4694, .value = 0x01000004 }, // RX 5
    .{ .at = 0xd4600, .value = 0x01400004 }, // TX 0
    .{ .at = 0xd4604, .value = 0x01800004 }, // TX 1
    .{ .at = 0xd4608, .value = 0x01c00004 }, // TX 2
    .{ .at = 0xd460c, .value = 0x02000004 }, // TX 3
    .{ .at = 0xd4610, .value = 0x02400004 }, // TX 4
    .{ .at = 0xd4614, .value = 0x02800004 }, // TX 5
    .{ .at = 0xd4618, .value = 0x02c00004 }, // TX 6
    .{ .at = 0xd4640, .value = 0x03400004 }, // TX 16
    .{ .at = 0xd4644, .value = 0x03800004 }, // TX 17
};

// --- the chip's addresses, reached through `far` ------------------------------

pub const HW_CHIPID: u32 = 0x70010200;
pub const HW_REV: u32 = 0x70010204;
/// The Wi-Fi part's reset: RST_B low holds it, INIT_DONE says it came out.
pub const WFSYS_SW_RST: u32 = 0x18000140;
pub const WFSYS_RST_B: u32 = 1 << 0;
pub const WFSYS_INIT_DONE: u32 = 1 << 4;
/// The host's side of the power handshake, seen from the chip: DRV_OWN
/// asks for the chip, FW_OWN reads 1 while the firmware still has it.
pub const TOP_LPCR_HOST_BAND0: u32 = 0x18060010;
pub const LPCR_FW_OWN: u32 = 1 << 0;
pub const LPCR_DRV_OWN: u32 = 1 << 1;

/// The blocks the bus maps at a fixed place in BAR0: a chip address
/// from `chip` up to `chip + size` is at `bar + (address - chip)`.
const Fixed = struct { chip: u32, bar: u32, size: u32 };
const fixed_map = [_]Fixed{
    .{ .chip = 0x820d0000, .bar = 0x30000, .size = 0x10000 },
    .{ .chip = 0x820ed000, .bar = 0x24800, .size = 0x00800 },
    .{ .chip = 0x820e4000, .bar = 0x21000, .size = 0x00400 },
    .{ .chip = 0x820e7000, .bar = 0x21e00, .size = 0x00200 },
    .{ .chip = 0x820eb000, .bar = 0x24200, .size = 0x00400 },
    .{ .chip = 0x820e2000, .bar = 0x20800, .size = 0x00400 },
    .{ .chip = 0x820e3000, .bar = 0x20c00, .size = 0x00400 },
    .{ .chip = 0x820e5000, .bar = 0x21400, .size = 0x00800 },
    .{ .chip = 0x00400000, .bar = 0x80000, .size = 0x10000 },
    .{ .chip = 0x00410000, .bar = 0x90000, .size = 0x10000 },
    .{ .chip = 0x40000000, .bar = 0x70000, .size = 0x10000 },
    .{ .chip = 0x54000000, .bar = 0x02000, .size = 0x01000 },
    .{ .chip = 0x55000000, .bar = 0x03000, .size = 0x01000 },
    .{ .chip = 0x58000000, .bar = 0x06000, .size = 0x01000 },
    .{ .chip = 0x59000000, .bar = 0x07000, .size = 0x01000 },
    .{ .chip = 0x7c000000, .bar = 0xf0000, .size = 0x10000 },
    .{ .chip = 0x7c020000, .bar = 0xd0000, .size = 0x10000 },
    .{ .chip = 0x7c060000, .bar = 0xe0000, .size = 0x10000 },
    .{ .chip = 0x80020000, .bar = 0xb0000, .size = 0x10000 },
    .{ .chip = 0x81020000, .bar = 0xc0000, .size = 0x10000 },
    .{ .chip = 0x820c0000, .bar = 0x08000, .size = 0x04000 },
    .{ .chip = 0x820c8000, .bar = 0x0c000, .size = 0x02000 },
    .{ .chip = 0x820cc000, .bar = 0x0e000, .size = 0x01000 },
    .{ .chip = 0x820cd000, .bar = 0x0f000, .size = 0x01000 },
    .{ .chip = 0x74030000, .bar = 0x10000, .size = 0x10000 },
    .{ .chip = 0x820ce000, .bar = 0x21c00, .size = 0x00200 },
    .{ .chip = 0x820cf000, .bar = 0x22000, .size = 0x01000 },
    .{ .chip = 0x820e0000, .bar = 0x20000, .size = 0x00400 },
    .{ .chip = 0x820e1000, .bar = 0x20400, .size = 0x00200 },
    .{ .chip = 0x820e9000, .bar = 0x23400, .size = 0x00200 },
    .{ .chip = 0x820ea000, .bar = 0x24000, .size = 0x00200 },
    .{ .chip = 0x820ec000, .bar = 0x24600, .size = 0x00200 },
};

/// BAR0, and the reads and writes of it.
pub const Regs = struct {
    base: usize,

    pub fn rd(regs: Regs, offset: u32) u32 {
        const at: *const volatile u32 = @ptrFromInt(regs.base + offset);
        return at.*;
    }

    pub fn wr(regs: Regs, offset: u32, value: u32) void {
        const at: *volatile u32 = @ptrFromInt(regs.base + offset);
        at.* = value;
    }

    /// The bits of `mask` replaced by `value`'s.
    pub fn rmw(regs: Regs, offset: u32, mask: u32, value: u32) void {
        regs.wr(offset, (regs.rd(offset) & ~mask) | value);
    }

    pub fn set(regs: Regs, offset: u32, bits: u32) void {
        regs.rmw(offset, 0, bits);
    }

    pub fn clear(regs: Regs, offset: u32, bits: u32) void {
        regs.rmw(offset, bits, 0);
    }

    /// Where a chip address is in BAR0: below a megabyte it is the offset
    /// itself, in a fixed block where the bus maps it, and otherwise in
    /// the window, which is moved to it first - read back, so that the
    /// move is done before the access through it.
    pub fn far(regs: Regs, address: u32) u32 {
        if (address < 0x100000) return address;
        for (fixed_map) |block| {
            if (address >= block.chip and address - block.chip < block.size) return block.bar + (address - block.chip);
        }
        regs.rmw(HIF_REMAP_L1, 0xffff, address >> 16);
        _ = regs.rd(HIF_REMAP_L1);
        return REMAP_BASE_L1 + (address & 0xffff);
    }

    pub fn rdFar(regs: Regs, address: u32) u32 {
        return regs.rd(regs.far(address));
    }

    pub fn wrFar(regs: Regs, address: u32, value: u32) void {
        regs.wr(regs.far(address), value);
    }

    pub fn rmwFar(regs: Regs, address: u32, mask: u32, value: u32) void {
        const at = regs.far(address);
        regs.wr(at, (regs.rd(at) & ~mask) | value);
    }

    /// A ring's register: `block` its block's base, `ring` its number.
    pub fn ring(block: u32, number: u32, register: u32) u32 {
        return block + number * RING_STEP + register;
    }

    /// The memory written before it is there for the chip before the
    /// register write after it.
    pub fn toDevice() void {
        barrier.toDevice();
    }

    pub fn fromDevice() void {
        barrier.fromDevice();
    }
};
