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
//! - the USB 3 PHY not detecting a receiver while it is in P3
//!   (GUSB3PIPECTL's DISRXDETINP3).
//!
//! A host needs no reset of the controller's own: the xHCI's resets
//! everything a host uses.

const reg = @import("_xhci.zig").reg;

const GCTL = 0xC110;
const GCTL_PRTCAPDIR_MASK: u32 = 3 << 12;
const GCTL_PRTCAPDIR_HOST: u32 = 1 << 12;
const GUCTL1 = 0xC11C;
const GUCTL1_PARKMODE_DISABLE_FSLS: u32 = 1 << 15;
const GUCTL1_PARKMODE_DISABLE_SS: u32 = 1 << 17;
const GUSB3PIPECTL0 = 0xC2C0;
const GUSB3PIPECTL_DISRXDETINP3: u32 = 1 << 28;

/// The controller at `base` set up as a host, ahead of the xHCI's reset.
pub fn asHost(base: usize) void {
    const gctl = reg(base + GCTL);
    gctl.* = (gctl.* & ~GCTL_PRTCAPDIR_MASK) | GCTL_PRTCAPDIR_HOST;
    reg(base + GUCTL1).* |= GUCTL1_PARKMODE_DISABLE_FSLS | GUCTL1_PARKMODE_DISABLE_SS;
    reg(base + GUSB3PIPECTL0).* |= GUSB3PIPECTL_DISRXDETINP3;
}
