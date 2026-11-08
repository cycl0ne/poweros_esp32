// SPDX-License-Identifier: MIT
//! Synopsys's DesignWare USB 3 controller (CHIP_DWC3) as a host: an xHCI
//! whose own global registers sit above the xHCI's, from 0xC100 on. The
//! xHCI's reset leaves them alone, so the driver sets them before it,
//! as Linux's dwc3 core does with the quirks the CM5's device tree gives
//! the RP1's two:
//!
//! - the port a host's (GCTL's PRTCAPDIR), not a device's or OTG;
//! - park mode off at SuperSpeed and at full and low speed (GUCTL1): the
//!   controller does not keep serving one bulk endpoint ahead of the
//!   others, which some devices hang on;
//! - more handshakes scheduled to full-speed control and bulk endpoints
//!   (GUCTL1's NAK_PER_ENH_FS, `snps,enhanced-nak-fs-quirk`): a device
//!   behind a hub's transaction translator that answers NAK is asked
//!   again sooner;
//! - the USB 3 PHY not detecting a receiver while it is in P3
//!   (GUSB3PIPECTL's DISRXDETINP3);
//! - a packet sent once two of a burst of up to eight are fetched from
//!   memory, rather than once the whole burst is (GTXTHRCFG,
//!   `snps,tx-thr-num-pkt` and `snps,tx-max-burst`): the RP1 reads
//!   memory across PCI Express, slowly and in bursts;
//! - at most eight transfers outstanding on its AXI bus at a time
//!   (GSBUSCFG1's PIPETRANSLIMIT, `snps,axi-pipe-limit`).
//!
//! A host needs no reset of the controller's own: the xHCI's resets
//! everything a host uses.

const reg = @import("_xhci.zig").reg;

const GSBUSCFG1 = 0xC104;
/// One less than the transfers that may be outstanding on the AXI bus.
const GSBUSCFG1_PIPETRANSLIMIT_MASK: u32 = 0xF << 8;
const GTXTHRCFG = 0xC108;
const GTXTHRCFG_PKTCNTSEL: u32 = 1 << 29;
const GTXTHRCFG_TXPKTCNT_MASK: u32 = 0xF << 24;
const GTXTHRCFG_MAXTXBURSTSIZE_MASK: u32 = 0xFF << 16;
const GCTL = 0xC110;
const GCTL_PRTCAPDIR_MASK: u32 = 3 << 12;
const GCTL_PRTCAPDIR_HOST: u32 = 1 << 12;
const GUCTL1 = 0xC11C;
const GUCTL1_PARKMODE_DISABLE_FSLS: u32 = 1 << 15;
const GUCTL1_PARKMODE_DISABLE_SS: u32 = 1 << 17;
const GUCTL1_NAK_PER_ENH_FS: u32 = 1 << 19;
const GUSB3PIPECTL0 = 0xC2C0;
const GUSB3PIPECTL_DISRXDETINP3: u32 = 1 << 28;

/// The transfers outstanding on the AXI bus at most.
const axi_pipe_limit: u32 = 8;
/// The packets of a burst fetched before the first is sent, and the
/// burst that counts for.
const tx_thr_num_pkt: u32 = 2;
const tx_max_burst: u32 = 8;

/// The controller at `base` set up as a host, ahead of the xHCI's reset.
pub fn asHost(base: usize) void {
    const gctl = reg(base + GCTL);
    gctl.* = (gctl.* & ~GCTL_PRTCAPDIR_MASK) | GCTL_PRTCAPDIR_HOST;
    const guctl1 = reg(base + GUCTL1);
    guctl1.* = hostUctl1(guctl1.*);
    reg(base + GUSB3PIPECTL0).* |= GUSB3PIPECTL_DISRXDETINP3;
    const gtxthrcfg = reg(base + GTXTHRCFG);
    gtxthrcfg.* = hostTxThreshold(gtxthrcfg.*);
    const gsbuscfg1 = reg(base + GSBUSCFG1);
    gsbuscfg1.* = hostBusCfg1(gsbuscfg1.*);
}

/// GUCTL1 with park mode off at SuperSpeed and at full and low speed,
/// and more handshakes to full-speed control and bulk endpoints.
pub fn hostUctl1(value: u32) u32 {
    return value | GUCTL1_PARKMODE_DISABLE_FSLS | GUCTL1_PARKMODE_DISABLE_SS | GUCTL1_NAK_PER_ENH_FS;
}

/// GTXTHRCFG with its threshold on: a packet sent once `tx_thr_num_pkt`
/// of a burst of up to `tx_max_burst` are in.
pub fn hostTxThreshold(value: u32) u32 {
    const kept = value & ~(GTXTHRCFG_TXPKTCNT_MASK | GTXTHRCFG_MAXTXBURSTSIZE_MASK);
    return kept | GTXTHRCFG_PKTCNTSEL | (tx_thr_num_pkt << 24) | (tx_max_burst << 16);
}

/// GSBUSCFG1 with at most `axi_pipe_limit` transfers outstanding on the
/// AXI bus; the field holds one less.
pub fn hostBusCfg1(value: u32) u32 {
    return (value & ~GSBUSCFG1_PIPETRANSLIMIT_MASK) | ((axi_pipe_limit - 1) << 8);
}
