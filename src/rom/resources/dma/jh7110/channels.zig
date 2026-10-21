// SPDX-License-Identifier: MPL-2.0
//! dma.resource's channels on the JH7110: no general ones and no 2D-DMA,
//! but the four of its DesignWare AXI DMA controller, which their owners
//! drive through `sdk.hardware.dwdma`. The resource finds the controller
//! in the board's parts (CHIP_JH7110_DMAC), clocks it, lets it out of
//! reset - U-Boot holds it there - and turns it on, every channel
//! stopped. A board without the part has none of the channels.

const sdk = @import("sdk");
const system = sdk.hardware.system;
const dwdma = sdk.hardware.dwdma;
const ExecBase = sdk.interface.exec.ExecBase;

pub const general = 0;
pub const dma2d_channels = 0;
pub const dw_channels = dwdma.channels;

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
