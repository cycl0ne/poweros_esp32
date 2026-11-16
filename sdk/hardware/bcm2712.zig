// SPDX-License-Identifier: MIT
//! The BCM2712's blocks, as a board's list names them where a part is
//! made of several: tables of addresses, with no code.
//!
//! A part of a board's list has one address (`PART_Address`). A part of
//! this chip that is several blocks of registers - an HDMI port is the
//! video scaler, a pixel valve, the HDMI controller's own blocks, its
//! packet RAM and a DDC master - names the rest in a table of this
//! file's shape, which its `PART_Blocks` tag points at. A second port is
//! a second part with a second table.

/// The blocks of one HDMI port beside the video scaler, which the part
/// names by its own address (CHIP_BCM2712_HVS): where each one's
/// registers are on the machine's bus.
pub const HdmiPort = extern struct {
    /// The VideoCore's mailbox, through which its firmware is asked for
    /// the port's clocks.
    mailbox: usize,
    /// The video scaler's IOMMU.
    iommu: usize,
    /// The pixel valve that times the scaler's output for this port.
    pixel_valve: usize,
    /// The HDMI controller's blocks: its own registers, the DVP's, the
    /// PHY's, the rate manager's, the colour space converter's, and the
    /// ones in the HD block - the video's control and the sound's FIFO.
    hdmi: usize,
    dvp: usize,
    phy: usize,
    rate_manager: usize,
    csc: usize,
    hd: usize,
    /// The register that holds the DVP's clock gates, one bit a port.
    dvp_gates: usize,
    /// The controller's packet RAM, which its infoframes are sent from.
    packets: usize,
    /// The port's DDC: a BSC I2C master of its own.
    ddc: usize,
};
