// SPDX-License-Identifier: MPL-2.0
//! dma.resource's channels on the JH7110: no general ones and no 2D-DMA,
//! but the four of its DesignWare AXI DMA controller, which their owners
//! drive through `sdk.hardware.dwdma`. The resource finds the controller
//! in the board's parts (CHIP_JH7110_DMAC), clocks it, lets it out of
//! reset - U-Boot holds it there - and turns it on, every channel
//! stopped. A board without the part has none of the channels.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const dwdma = sdk.hardware.dwdma;

pub const general = 0;
pub const dma2d_channels = 0;
pub const dw_channels = dwdma.channels;

/// The STG domain's clock and reset generator, laid out as the system's:
/// a clock's register is its number times four, bit 31 lets it through;
/// a reset is held while its bit is set in ASSERT and is out once it is
/// set in STATUS.
const STG_CRG: usize = 0x1023_0000;
const STGCLK_DMA1P_AXI = STG_CRG + 27 * 4;
const STGCLK_DMA1P_AHB = STG_CRG + 28 * 4;
const STG_RESET_ASSERT = STG_CRG + 0x74;
const STG_RESET_STATUS = STG_CRG + 0x78;
/// The controller's AXI and AHB sides.
const STGRST_DMA1P: u32 = 1 << 5 | 1 << 6;
const CLK_ENABLE: u32 = 1 << 31;

/// The controller clocked, out of reset and on, its channels stopped:
/// where its registers are, or 0 where the board has none.
pub fn controller() usize {
    const found = dwdma.find() orelse return 0;
    reg(STGCLK_DMA1P_AXI).* |= CLK_ENABLE;
    reg(STGCLK_DMA1P_AHB).* |= CLK_ENABLE;
    if (reg(STG_RESET_STATUS).* & STGRST_DMA1P != STGRST_DMA1P) {
        reg(STG_RESET_ASSERT).* &= ~STGRST_DMA1P;
        var tries: u32 = 0;
        while (reg(STG_RESET_STATUS).* & STGRST_DMA1P != STGRST_DMA1P and tries < 1_000_000) : (tries += 1) {}
    }
    dwdma.enable(found.base);
    for (0..dw_channels) |channel| dwdma.stop(found.base, @intCast(channel));
    return found.base;
}

/// Channel `channel` of the controller at `base` stopped, its interrupts
/// off.
pub const stopChannel = dwdma.stop;
