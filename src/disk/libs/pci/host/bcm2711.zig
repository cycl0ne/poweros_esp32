// SPDX-License-Identifier: MIT
//! The BCM2711's PCI Express root port (CHIP_BCM2711_PCIE): Broadcom's
//! STB bridge, the generation before the BCM2712's (`bcm2712.zig`), one
//! lane at up to 5 GT/s. On the Raspberry Pi 4 Model B the VL805 behind
//! it is the four USB-A sockets.
//!
//! **Bringing the port up** is done as Linux does it (pcie-brcmstb.c, its
//! bcm2711 configuration), from the state the firmware leaves it in - it
//! resets the port before it starts the ARM:
//!
//! 1. the bridge reset and PERST# held, both bits of the bridge's own
//!    reset register (RGR1_SW_INIT_1), then the bridge let go again;
//! 2. the SerDes powered (HARD_DEBUG's SERDES_IDDQ cleared);
//! 3. the bridge's side towards memory (MISC_CTRL): reads and writes of
//!    memory let through, an unanswered configuration read reading all
//!    ones, bursts of 128 bytes - what this generation is given -, memory
//!    controller 0 4 GiB;
//! 4. RAM where it is on the bus: the inbound window RC_BAR2, the 4 GiB
//!    from 0 onto RAM from 0, so a driver gives a function the
//!    processor's addresses; RC_BAR1 and RC_BAR3 off. The bridge reaches
//!    the first 3 GiB of RAM through it (the device tree's dma-ranges);
//!    the board's MEMF_DMA is below that;
//! 5. that it is a root port, not an endpoint (PCIE_STATUS's PORT), and
//!    its own interrupts for messages masked and cleared: the library
//!    takes no messages here;
//! 6. the root port's class code a PCI-to-PCI bridge's, the board's
//!    memory window as outbound window 0 (`bcm2712.outbound`), and the
//!    inbound window little-endian;
//! 7. PERST# let go after 100 ms (`release`) and the link waited for
//!    (`linkUp`), the library's steps for every port. Once it is up, the
//!    reference clock is driven all the time - nothing here puts a link
//!    to sleep - and spread over its band, as the board's device tree
//!    asks (brcm,enable-ssc): an override in the PHY over MDIO, which is
//!    left as it is where the PHY does not take it.
//!
//! **Configuration space**, the root port's hidden BARs and the INTx
//! lines are the BCM2712's: the index register and the data window
//! (`bcm2712.read`, `write`, `hidden`), and INTA to INTD four GIC
//! interrupts of their own, PART_Irq and the three after it, level
//! triggered. Message-signalled interrupts are not taken: a function's
//! driver uses its line.

const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const _host = @import("_host.zig");
const Host = _host.Host;
const bcm2712 = @import("bcm2712.zig");
const Window = @import("../scan/place.zig").Window;

fn reg(address: usize) *volatile u32 {
    return @ptrFromInt(address);
}

/// `bits` of the register at `address` set to `value`.
fn update(address: usize, bits: u32, value: u32) void {
    reg(address).* = (reg(address).* & ~bits) | (value & bits);
}

/// Whether this is built for the BCM2711's chip, whose counter the
/// short waits here read. The library is built for every chip; elsewhere
/// no port is started, and none of that is built.
const on_bcm2711 = sdk.hardware.chip == .a64v80;

// --- the bridge ------------------------------------------------------------------------

const PCIE_RC_CFG_VENDOR_SPECIFIC_REG1 = 0x0188;
const ENDIAN_MODE_BAR2_MASK: u32 = 0xC;
const PCIE_RC_CFG_PRIV1_ID_VAL3 = 0x043C;
const CLASS_CODE_MASK: u32 = 0xFF_FFFF;
const PCIE_RC_DL_MDIO_ADDR = 0x1100;
const PCIE_RC_DL_MDIO_RD_DATA = 0x1108;

const PCIE_MISC_MISC_CTRL = 0x4008;
const MISC_CTRL_RCB_64B_MODE: u32 = 1 << 7;
const MISC_CTRL_RCB_MPS_MODE: u32 = 1 << 10;
const MISC_CTRL_SCB_ACCESS_EN: u32 = 1 << 12;
const MISC_CTRL_CFG_READ_UR_MODE: u32 = 1 << 13;
const MISC_CTRL_MAX_BURST_SIZE_MASK: u32 = 3 << 20;
const MISC_CTRL_MAX_BURST_128: u32 = 0 << 20;
const MISC_CTRL_SCB0_SIZE_MASK: u32 = 0x1F << 27;
/// Memory controller 0's size, log2 of it less 15: 4 GiB, the inbound
/// window's.
const MISC_CTRL_SCB0_SIZE_4G: u32 = (32 - 15) << 27;

/// The inbound windows: RC_BAR2 onto RAM, its size log2 less 15 in the
/// low five bits, RC_BAR1 and RC_BAR3 off (size 0).
const PCIE_MISC_RC_BAR1_CONFIG_LO = 0x402C;
const PCIE_MISC_RC_BAR2_CONFIG_LO = 0x4034;
const PCIE_MISC_RC_BAR2_CONFIG_HI = 0x4038;
const PCIE_MISC_RC_BAR3_CONFIG_LO = 0x403C;
const RC_BAR_SIZE_MASK: u32 = 0x1F;
const IBAR_SIZE_4G: u32 = 32 - 15;

const PCIE_MISC_PCIE_STATUS = 0x4068;
const STATUS_PHYLINKUP: u32 = 1 << 4;
const STATUS_DL_ACTIVE: u32 = 1 << 5;
const STATUS_PORT: u32 = 1 << 7;

const HARD_DEBUG = 0x4204;
const HARD_DEBUG_CLKREQ_DEBUG_ENABLE: u32 = 1 << 1;
const HARD_DEBUG_L1SS_ENABLE: u32 = 1 << 21;
const HARD_DEBUG_SERDES_IDDQ: u32 = 1 << 27;

/// The bridge's interrupt for messages: what is pending, cleared by
/// writing it, and the mask.
const PCIE_MSI_INTR2_CLR = 0x4508;
const PCIE_MSI_INTR2_MASK_SET = 0x4510;

/// The bridge's own reset register: PERST# held while bit 0 is set, the
/// bridge while bit 1 is.
const PCIE_RGR1_SW_INIT_1 = 0x9210;
const SW_INIT_PERST: u32 = 1 << 0;
const SW_INIT_BRIDGE: u32 = 1 << 1;

/// The PHY's registers over MDIO: a read's packet and its answer, and the
/// spread spectrum's block - its control register, whose override the
/// two bits are, and its status, which says the clock spreads and its
/// PLL is locked.
const MDIO_SET_ADDR = 0x1F;
const MDIO_CMD_READ: u32 = 1 << 20;
const MDIO_DATA_DONE: u32 = 1 << 31;
const MDIO_DATA_MASK: u32 = 0x7FFF_FFFF;
const ssc_block: u16 = 0x1100;
const SSC_CNTL = 0x02;
const SSC_CNTL_OVRD_EN: u32 = 0x8000;
const SSC_CNTL_OVRD_VAL: u32 = 0x4000;
const SSC_STATUS = 0x01;
const SSC_STATUS_SSC: u32 = 0x400;
const SSC_STATUS_PLL_LOCK: u32 = 0x800;

/// The port up as far as PERST#, which is held (`_host.start`). False
/// for a part that does not say where its registers are, or names a
/// port the chip does not have - it has one - or a bridge that is set up
/// as an endpoint.
pub fn start(host: *Host) bool {
    return if (on_bcm2711) bringUp(host) else false;
}

fn bringUp(host: *Host) bool {
    if (host.unit != 0 or host.registers == 0) return false;
    const r = host.registers;

    update(r + PCIE_RGR1_SW_INIT_1, SW_INIT_BRIDGE | SW_INIT_PERST, SW_INIT_BRIDGE | SW_INIT_PERST);
    bcm2712.wait(200);
    update(r + PCIE_RGR1_SW_INIT_1, SW_INIT_BRIDGE, 0);
    update(r + HARD_DEBUG, HARD_DEBUG_SERDES_IDDQ, 0);
    bcm2712.wait(200);

    update(r + PCIE_MISC_MISC_CTRL, MISC_CTRL_RCB_64B_MODE | MISC_CTRL_RCB_MPS_MODE | MISC_CTRL_SCB_ACCESS_EN |
        MISC_CTRL_CFG_READ_UR_MODE | MISC_CTRL_MAX_BURST_SIZE_MASK | MISC_CTRL_SCB0_SIZE_MASK, MISC_CTRL_RCB_64B_MODE |
        MISC_CTRL_RCB_MPS_MODE | MISC_CTRL_SCB_ACCESS_EN | MISC_CTRL_CFG_READ_UR_MODE | MISC_CTRL_MAX_BURST_128 |
        MISC_CTRL_SCB0_SIZE_4G);
    reg(r + PCIE_MISC_RC_BAR2_CONFIG_LO).* = IBAR_SIZE_4G;
    reg(r + PCIE_MISC_RC_BAR2_CONFIG_HI).* = 0;
    update(r + PCIE_MISC_RC_BAR1_CONFIG_LO, RC_BAR_SIZE_MASK, 0);
    update(r + PCIE_MISC_RC_BAR3_CONFIG_LO, RC_BAR_SIZE_MASK, 0);

    if (reg(r + PCIE_MISC_PCIE_STATUS).* & STATUS_PORT == 0) {
        sdk.exec.kprintf(host.sys, "%s: bcm2711 pcie: the bridge is set up as an endpoint\n", .{pci.PCINAME});
        return false;
    }
    reg(r + PCIE_MSI_INTR2_MASK_SET).* = 0xFFFF_FFFF;
    reg(r + PCIE_MSI_INTR2_CLR).* = 0xFFFF_FFFF;

    update(r + PCIE_RC_CFG_PRIV1_ID_VAL3, CLASS_CODE_MASK, 0x06_0400);
    var window: u32 = 0;
    for ([_]Window{ host.windows.mem, host.windows.pref }) |w| {
        if (w.size == 0) continue;
        bcm2712.outbound(r, window, w);
        window += 1;
    }
    update(r + PCIE_RC_CFG_VENDOR_SPECIFIC_REG1, ENDIAN_MODE_BAR2_MASK, 0);
    return true;
}

/// PERST# let go (`_host.release`).
pub fn release(host: *Host) void {
    if (on_bcm2711) update(host.registers + PCIE_RGR1_SW_INIT_1, SW_INIT_PERST, 0);
}

/// PERST# held again (`_host.hold`): the bridge itself stays out of its
/// reset.
pub fn hold(host: *Host) void {
    if (on_bcm2711) update(host.registers + PCIE_RGR1_SW_INIT_1, SW_INIT_PERST, SW_INIT_PERST);
}

/// Whether the link is up, its PHY and its data link layer
/// (`_host.linkUp`). Once it is, the reference clock is driven for good
/// and spread.
pub fn linkUp(host: *const Host) bool {
    if (!on_bcm2711) return false;
    const r = host.registers;
    const both = STATUS_PHYLINKUP | STATUS_DL_ACTIVE;
    if (reg(r + PCIE_MISC_PCIE_STATUS).* & both != both) return false;
    update(r + HARD_DEBUG, HARD_DEBUG_CLKREQ_DEBUG_ENABLE | HARD_DEBUG_L1SS_ENABLE, 0);
    if (!spread(r)) {
        sdk.exec.klog(host.sys, exec.LOG_DEBUG, "%s: bcm2711 pcie: the reference clock is not spread\n", .{pci.PCINAME});
    }
    return true;
}

/// The reference clock spread over its band: the PHY's override set,
/// and whether the PHY says it spreads with its PLL locked a millisecond
/// later.
fn spread(r: usize) bool {
    if (!bcm2712.mdioWrite(r, MDIO_SET_ADDR, ssc_block)) return false;
    const control = mdioRead(r, SSC_CNTL) orelse return false;
    if (!bcm2712.mdioWrite(r, SSC_CNTL, @truncate(control | SSC_CNTL_OVRD_EN | SSC_CNTL_OVRD_VAL))) return false;
    bcm2712.wait(1000);
    const status = mdioRead(r, SSC_STATUS) orelse return false;
    return status & SSC_STATUS_SSC != 0 and status & SSC_STATUS_PLL_LOCK != 0;
}

/// One of the PHY's registers read over MDIO, port 0: null if the PHY did
/// not answer within 100 µs.
fn mdioRead(r: usize, at: u8) ?u32 {
    reg(r + PCIE_RC_DL_MDIO_ADDR).* = MDIO_CMD_READ | at;
    _ = reg(r + PCIE_RC_DL_MDIO_ADDR).*;
    var waited: u32 = 0;
    while (true) : (waited += 10) {
        const data = reg(r + PCIE_RC_DL_MDIO_RD_DATA).*;
        if (data & MDIO_DATA_DONE != 0) return data & MDIO_DATA_MASK;
        if (waited >= 100) return null;
        bcm2712.wait(10);
    }
}
