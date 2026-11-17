// SPDX-License-Identifier: MIT
//! The BCM2711's blocks, as a board's list names them where a part is
//! made of several: tables of addresses, with no code.
//!
//! A part of a board's list has one address (`PART_Address`). A part of
//! this chip that is several blocks of registers - the first HDMI port as
//! its firmware lit it is the video scaler, the pixel valve that times
//! it, the HDMI controller, its packet RAM and the block it shares with
//! the second port - names the rest in a table of this file's shape,
//! which its `PART_Blocks` tag points at.

/// The blocks of the HDMI port beside the video scaler, which the part
/// names by its own address (CHIP_BCM2711_HVS): where each one's
/// registers are on the machine's bus.
pub const HdmiPort = extern struct {
    /// The pixel valve that times the scaler's channel out to the port.
    pixel_valve: usize,
    /// The HDMI controller's own registers.
    hdmi: usize,
    /// The controller's packet RAM, which its infoframes are sent from.
    packets: usize,
    /// The block the two ports share, which holds each one's MAI - the
    /// sound's way in - its video's control and the frames it sent.
    hd: usize,
};
