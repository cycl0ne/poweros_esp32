// SPDX-License-Identifier: MPL-2.0
//! dma.resource's channels on the JH7110: no general ones and no 2D-DMA,
//! but the four of its DesignWare AXI DMA controller, which their owners
//! drive through `sdk.hardware.dwdma`, and the eight of the PL080 in its
//! security block, which feeds the crypto engine, driven through
//! `sdk.hardware.pl080`. The resource finds each controller in the
//! board's parts (CHIP_JH7110_DMAC, CHIP_JH7110_SDMA), clocks it, lets it
//! out of reset - U-Boot holds both there - and turns it on, every
//! channel stopped. A board without a part has none of its channels.

const sdk = @import("sdk");
const system = sdk.hardware.system;
const dwdma = sdk.hardware.dwdma;
const pl080 = sdk.hardware.pl080;
const ExecBase = sdk.interface.exec.ExecBase;

pub const general = 0;
pub const dma2d_channels = 0;
pub const dw_channels = dwdma.channels;
pub const pl_channels = pl080.channels;

/// The controller's clocks and resets in the STG domain's generator:
/// its AXI and its AHB side.
const clocks = [_]u32{ system.STGCLK_DMA1P_AXI, system.STGCLK_DMA1P_AHB };
const resets = [_]u32{ system.STGRST_DMA1P_AXI, system.STGRST_DMA1P_AHB };

/// The controller clocked, out of reset and on, its channels stopped:
/// where its registers are, or 0 where the board has none. The STG
/// domain's reset word is shared with PCIe and the security block, so it
/// changes under Disable.
pub fn controller(sys: *ExecBase) usize {
    const found = dwdma.find() orelse return 0;
    sys.Disable();
    for (clocks) |clock| system.clockOn(.stg, clock);
    for (resets) |reset| system.releaseReset(.stg, reset);
    sys.Enable();
    for (resets) |reset| _ = system.waitOutOfReset(.stg, reset);
    dwdma.enable(found.base);
    for (0..dw_channels) |channel| dwdma.stop(found.base, @intCast(channel));
    return found.base;
}

/// Channel `channel` of the controller at `base` stopped, its interrupts
/// off.
pub const stopChannel = dwdma.stop;

/// The security block's clocks - its AHB, which the PL080 runs on, and
/// the block's other AHB - and its reset, which the TRNG and the crypto
/// engine share with the PL080.
const sec_clocks = [_]u32{ system.STGCLK_SEC_AHB, system.STGCLK_SEC_MISC_AHB };

/// The PL080 clocked, out of reset and on, its channels stopped: where
/// its registers are, or 0 where the board has none. The block is let out
/// of reset, never put back in it: the kernel's TRNG is in it.
pub fn plController(sys: *ExecBase) usize {
    const found = pl080.find() orelse return 0;
    sys.Disable();
    for (sec_clocks) |clock| system.clockOn(.stg, clock);
    system.releaseReset(.stg, system.STGRST_SEC_AHB);
    sys.Enable();
    _ = system.waitOutOfReset(.stg, system.STGRST_SEC_AHB);
    pl080.enable(found.base);
    for (0..pl_channels) |channel| pl080.stop(found.base, @intCast(channel));
    return found.base;
}

/// Channel `channel` of the PL080 at `base` stopped, its interrupts
/// cleared.
pub const stopPlChannel = pl080.stop;
