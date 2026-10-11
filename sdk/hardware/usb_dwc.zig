// SPDX-License-Identifier: MIT
//! The Synopsys DWC2 USB OTG core's registers, as offsets from a
//! controller's base: the core's own, the host's, and a host channel's.
//! The same core sits in both chips - the ESP32-S3's full-speed
//! controller, the ESP32-P4's high-speed and full-speed ones - so the
//! layout is one file; where each controller is, its interrupt and the
//! PHY around it are each chip's (`sdk.hardware.usb_otg`).
//!
//! Only names and numbers: nothing here touches the hardware. A register
//! is `mmio.reg(base + GINTSTS)`; a channel's is `base + hc(n) + HCCHAR`.
//! Bits that are cleared by writing 1 to them say so.

// --- the core -----------------------------------------------------------------------

/// OTG control and status: the session comparators' overrides.
pub const GOTGCTL: usize = 0x000;
/// AHB configuration: the interrupt line, DMA, the burst length.
pub const GAHBCFG: usize = 0x008;
/// USB configuration: the PHY, host or device mode forced.
pub const GUSBCFG: usize = 0x00C;
/// Resets: the core, the FIFOs.
pub const GRSTCTL: usize = 0x010;
/// The core's interrupts, and the mask over them.
pub const GINTSTS: usize = 0x014;
pub const GINTMSK: usize = 0x018;
/// The receive FIFO's size, in 32-bit words.
pub const GRXFSIZ: usize = 0x024;
/// The non-periodic transmit FIFO: where it starts, and its size.
pub const GNPTXFSIZ: usize = 0x028;
/// The core's version: 0x4F54_xxxA.
pub const GSNPSID: usize = 0x040;
/// What the core was built with: GHWCFG2 its channels, GHWCFG3 its FIFO.
pub const GHWCFG1: usize = 0x044;
pub const GHWCFG2: usize = 0x048;
pub const GHWCFG3: usize = 0x04C;
pub const GHWCFG4: usize = 0x050;
/// The periodic transmit FIFO: where it starts, and its size.
pub const HPTXFSIZ: usize = 0x100;

// --- the host -----------------------------------------------------------------------

/// Host configuration: the PHY clock, full and low speed only.
pub const HCFG: usize = 0x400;
/// The frame interval, in PHY clocks.
pub const HFIR: usize = 0x404;
/// The frame number, and how long the frame has left.
pub const HFNUM: usize = 0x408;
/// Which channels have interrupts, a bit each, and the mask over them.
pub const HAINT: usize = 0x414;
pub const HAINTMSK: usize = 0x418;
/// The root port: connection, enable, reset, power, speed.
pub const HPRT: usize = 0x440;

/// Where host channel `n`'s registers start.
pub inline fn hc(n: u32) usize {
    return 0x500 + @as(usize, n) * 0x20;
}
/// A channel's registers, from `hc(n)`.
pub const HCCHAR: usize = 0x00;
pub const HCSPLT: usize = 0x04;
pub const HCINT: usize = 0x08;
pub const HCINTMSK: usize = 0x0C;
pub const HCTSIZ: usize = 0x10;
pub const HCDMA: usize = 0x14;

/// Power and clock gating.
pub const PCGCCTL: usize = 0xE00;

// --- GOTGCTL --------------------------------------------------------------------------

/// The session comparators overridden: VBUS valid, A-session valid,
/// B-session valid, each an enable and the value it reads as.
pub const GOTGCTL_VBVALIDOVEN: u32 = 1 << 2;
pub const GOTGCTL_VBVALIDOVVAL: u32 = 1 << 3;
pub const GOTGCTL_AVALIDOVEN: u32 = 1 << 4;
pub const GOTGCTL_AVALIDOVVAL: u32 = 1 << 5;
pub const GOTGCTL_BVALIDOVEN: u32 = 1 << 6;
pub const GOTGCTL_BVALIDOVVAL: u32 = 1 << 7;

// --- GAHBCFG --------------------------------------------------------------------------

/// The interrupt line enabled.
pub const GAHBCFG_GLBLINTRMSK: u32 = 1 << 0;
/// The burst length (bits 1-4): 0 single, 1 INCR, 3 INCR4, 5 INCR8, 7 INCR16.
pub const GAHBCFG_HBSTLEN_SHIFT: u5 = 1;
pub const GAHBCFG_HBSTLEN_MASK: u32 = 0xF << 1;
/// The core's own DMA: channels read and write memory at HCDMA.
pub const GAHBCFG_DMAEN: u32 = 1 << 5;

// --- GUSBCFG --------------------------------------------------------------------------

/// The PHY's timeout calibration, in PHY clocks (bits 0-2).
pub const GUSBCFG_TOUTCAL_MASK: u32 = 0x7;
/// The UTMI+ interface 16 bits wide.
pub const GUSBCFG_PHYIF: u32 = 1 << 3;
/// ULPI rather than UTMI+.
pub const GUSBCFG_ULPIUTMISEL: u32 = 1 << 4;
/// The full-speed serial PHY rather than the high-speed one.
pub const GUSBCFG_PHYSEL: u32 = 1 << 6;
pub const GUSBCFG_SRPCAP: u32 = 1 << 8;
pub const GUSBCFG_HNPCAP: u32 = 1 << 9;
/// Host mode, whatever the ID pin says. Takes 25 ms to take hold.
pub const GUSBCFG_FORCEHSTMODE: u32 = 1 << 29;
pub const GUSBCFG_FORCEDEVMODE: u32 = 1 << 30;

// --- GRSTCTL --------------------------------------------------------------------------

/// The core's soft reset: set, and the core clears it when done.
pub const GRSTCTL_CSFTRST: u32 = 1 << 0;
/// The receive FIFO flushed.
pub const GRSTCTL_RXFFLSH: u32 = 1 << 4;
/// The transmit FIFOs flushed - all of them with GRSTCTL_TXFNUM_ALL.
pub const GRSTCTL_TXFFLSH: u32 = 1 << 5;
pub const GRSTCTL_TXFNUM_ALL: u32 = 0x10 << 6;
/// The AHB master is idle: what to wait for before and after a reset.
pub const GRSTCTL_AHBIDL: u32 = 1 << 31;

// --- GINTSTS / GINTMSK ----------------------------------------------------------------

/// Read: 1 while the core is a host.
pub const GINTSTS_CURMOD: u32 = 1 << 0;
/// The start of a frame (write 1 to clear).
pub const GINTSTS_SOF: u32 = 1 << 3;
/// The root port changed: read HPRT.
pub const GINTSTS_PRTINT: u32 = 1 << 24;
/// A channel has an interrupt: read HAINT.
pub const GINTSTS_HCHINT: u32 = 1 << 25;
/// The device on the root port went away (write 1 to clear).
pub const GINTSTS_DISCONNINT: u32 = 1 << 29;

// --- GHWCFG ---------------------------------------------------------------------------

/// GHWCFG2: the OTG mode (bits 0-2), the high-speed PHY's kind (6-7, 0
/// none), the host channels less one (14-17).
pub const GHWCFG2_OTGMODE_MASK: u32 = 0x7;
pub const GHWCFG2_HSPHYTYPE_SHIFT: u5 = 6;
pub const GHWCFG2_NUMHSTCHNL_SHIFT: u5 = 14;
/// GHWCFG3: the FIFO's depth in 32-bit words (bits 16-31).
pub const GHWCFG3_DFIFODEPTH_SHIFT: u5 = 16;

// --- HCFG -----------------------------------------------------------------------------

/// The PHY clock for full and low speed (bits 0-1): 0 30/60 MHz (UTMI+),
/// 1 48 MHz (the full-speed PHY).
pub const HCFG_FSLSPCLKSEL_MASK: u32 = 0x3;
pub const HCFG_FSLSPCLKSEL_48MHZ: u32 = 1;
pub const HCFG_FSLSPCLKSEL_30_60MHZ: u32 = 0;
/// Full and low speed only: a high-speed controller enumerates every
/// device at full speed, and a high-speed hub is a full-speed hub.
pub const HCFG_FSLSSUPP: u32 = 1 << 2;

// --- HPRT -----------------------------------------------------------------------------

/// Something is connected.
pub const HPRT_PRTCONNSTS: u32 = 1 << 0;
/// A connection was seen (write 1 to clear).
pub const HPRT_PRTCONNDET: u32 = 1 << 1;
/// The port is enabled. Writing 1 disables it, so it is masked out of
/// every read-modify-write.
pub const HPRT_PRTENA: u32 = 1 << 2;
/// The port's enable changed (write 1 to clear).
pub const HPRT_PRTENCHNG: u32 = 1 << 3;
pub const HPRT_PRTOVRCURRACT: u32 = 1 << 4;
/// The over-current state changed (write 1 to clear).
pub const HPRT_PRTOVRCURRCHNG: u32 = 1 << 5;
pub const HPRT_PRTRES: u32 = 1 << 6;
pub const HPRT_PRTSUSP: u32 = 1 << 7;
/// The port held in reset while set.
pub const HPRT_PRTRST: u32 = 1 << 8;
/// The port powered.
pub const HPRT_PRTPWR: u32 = 1 << 12;
/// What a device was found as (bits 17-18): HPRT_SPD_*.
pub const HPRT_PRTSPD_SHIFT: u5 = 17;
pub const HPRT_SPD_HIGH: u32 = 0;
pub const HPRT_SPD_FULL: u32 = 1;
pub const HPRT_SPD_LOW: u32 = 2;
/// The bits a write of 1 changes something by: kept out of a
/// read-modify-write of HPRT so it does not clear them or disable the
/// port.
pub const HPRT_W1C_MASK: u32 = HPRT_PRTCONNDET | HPRT_PRTENA | HPRT_PRTENCHNG | HPRT_PRTOVRCURRCHNG;

// --- HCCHAR ---------------------------------------------------------------------------

/// The endpoint's max packet size (bits 0-10).
pub const HCCHAR_MPS_MASK: u32 = 0x7FF;
/// The endpoint's number (bits 11-14).
pub const HCCHAR_EPNUM_SHIFT: u5 = 11;
/// IN.
pub const HCCHAR_EPDIR: u32 = 1 << 15;
/// A low-speed device.
pub const HCCHAR_LSPDDEV: u32 = 1 << 17;
/// The transfer type (bits 18-19): HCCHAR_EPTYPE_*.
pub const HCCHAR_EPTYPE_SHIFT: u5 = 18;
pub const HCCHAR_EPTYPE_CONTROL: u32 = 0;
pub const HCCHAR_EPTYPE_ISOCHRONOUS: u32 = 1;
pub const HCCHAR_EPTYPE_BULK: u32 = 2;
pub const HCCHAR_EPTYPE_INTERRUPT: u32 = 3;
/// Transactions per (micro)frame for a periodic endpoint (bits 20-21).
pub const HCCHAR_EC_SHIFT: u5 = 20;
/// The device's address (bits 22-28).
pub const HCCHAR_DEVADDR_SHIFT: u5 = 22;
/// A periodic transfer goes out in odd frames.
pub const HCCHAR_ODDFRM: u32 = 1 << 29;
/// Halt the channel: with HCCHAR_CHENA, and wait for HCINT_CHHLTD.
pub const HCCHAR_CHDIS: u32 = 1 << 30;
/// Start the channel.
pub const HCCHAR_CHENA: u32 = 1 << 31;

// --- HCSPLT ---------------------------------------------------------------------------

/// The hub's port and the hub's address of a split transaction, and the
/// split on.
pub const HCSPLT_PRTADDR_MASK: u32 = 0x7F;
pub const HCSPLT_HUBADDR_SHIFT: u5 = 7;
pub const HCSPLT_COMPSPLT: u32 = 1 << 16;
pub const HCSPLT_SPLTENA: u32 = 1 << 31;

// --- HCINT / HCINTMSK -----------------------------------------------------------------

/// The transfer is done, all of it or a short packet.
pub const HCINT_XFERCOMPL: u32 = 1 << 0;
/// The channel has stopped: the reason is in the other bits.
pub const HCINT_CHHLTD: u32 = 1 << 1;
/// The DMA could not reach memory.
pub const HCINT_AHBERR: u32 = 1 << 2;
pub const HCINT_STALL: u32 = 1 << 3;
pub const HCINT_NAK: u32 = 1 << 4;
pub const HCINT_ACK: u32 = 1 << 5;
pub const HCINT_NYET: u32 = 1 << 6;
/// A transaction error: CRC, bit stuffing, timeout, a bad PID.
pub const HCINT_XACTERR: u32 = 1 << 7;
/// Babble: the device sent more than the packet's size.
pub const HCINT_BBLERR: u32 = 1 << 8;
pub const HCINT_FRMOVRUN: u32 = 1 << 9;
pub const HCINT_DATATGLERR: u32 = 1 << 10;
/// Every bit at once, to clear them.
pub const HCINT_ALL: u32 = 0x7FF;

// --- HCTSIZ ---------------------------------------------------------------------------

/// The transfer's bytes (bits 0-18), its packets (19-28), and the data
/// PID to start with (29-30): HCTSIZ_PID_*.
pub const HCTSIZ_XFERSIZE_MASK: u32 = 0x7FFFF;
pub const HCTSIZ_PKTCNT_SHIFT: u5 = 19;
pub const HCTSIZ_PKTCNT_MASK: u32 = 0x3FF << 19;
pub const HCTSIZ_PID_SHIFT: u5 = 29;
pub const HCTSIZ_PID_MASK: u32 = 0x3 << 29;
pub const HCTSIZ_PID_DATA0: u32 = 0;
pub const HCTSIZ_PID_DATA2: u32 = 1;
pub const HCTSIZ_PID_DATA1: u32 = 2;
/// A control transfer's SETUP stage (and MDATA for a periodic one).
pub const HCTSIZ_PID_SETUP: u32 = 3;
/// Ask with PING before an OUT at high speed.
pub const HCTSIZ_DOPNG: u32 = 1 << 31;

// --- PCGCCTL --------------------------------------------------------------------------

/// The PHY's clock stopped.
pub const PCGCCTL_STOPPCLK: u32 = 1 << 0;
