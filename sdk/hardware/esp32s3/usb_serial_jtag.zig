// SPDX-License-Identifier: MIT
//! The USB-Serial-JTAG port's registers: a serial line to the USB host,
//! a CDC-ACM port there, through one 64-byte endpoint each way.
//!
//! Only names and numbers: nothing here touches the hardware.

const map = @import("map.zig");

/// EP1: a byte written is one for the host; a byte read, one from it.
pub const EP1: usize = map.USB_SERIAL_JTAG + 0x00;
pub const EP1_CONF: usize = map.USB_SERIAL_JTAG + 0x04;
pub const INT_RAW: usize = map.USB_SERIAL_JTAG + 0x08;
pub const INT_ST: usize = map.USB_SERIAL_JTAG + 0x0C;
pub const INT_ENA: usize = map.USB_SERIAL_JTAG + 0x10;
pub const INT_CLR: usize = map.USB_SERIAL_JTAG + 0x14;

// EP1_CONF
/// Written: what is in the IN FIFO goes to the host.
pub const EP1_WR_DONE: u32 = 1 << 0;
/// The IN FIFO has room.
pub const EP1_IN_EP_DATA_FREE: u32 = 1 << 1;
/// The OUT FIFO holds a byte from the host.
pub const EP1_OUT_EP_DATA_AVAIL: u32 = 1 << 2;

// INT_*
/// The host sent a packet.
pub const INT_SERIAL_OUT_RECV_PKT: u32 = 1 << 2;
