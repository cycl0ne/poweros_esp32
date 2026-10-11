// SPDX-License-Identifier: MIT
//! The chip's own USB port, USB Serial/JTAG: a serial line and a JTAG
//! adapter on one USB connection. Endpoint 1 is the serial line. The same
//! registers, at the same offsets, as the ESP32-S3's.

const map = @import("map.zig");

pub const EP1: usize = map.USB_SERIAL_JTAG + 0x00;
pub const EP1_CONF: usize = map.USB_SERIAL_JTAG + 0x04;
pub const INT_RAW: usize = map.USB_SERIAL_JTAG + 0x08;
pub const INT_ST: usize = map.USB_SERIAL_JTAG + 0x0C;
pub const INT_ENA: usize = map.USB_SERIAL_JTAG + 0x10;
pub const INT_CLR: usize = map.USB_SERIAL_JTAG + 0x14;
/// The block's version, and what it reads after reset.
pub const DATE: usize = map.USB_SERIAL_JTAG + 0x88;
pub const DATE_RESET: u32 = 0x0211_2010;

// EP1_CONF's bits.
pub const EP1_WR_DONE: u32 = 1 << 0;
pub const EP1_IN_EP_DATA_FREE: u32 = 1 << 1;
pub const EP1_OUT_EP_DATA_AVAIL: u32 = 1 << 2;

// INT_*: a packet came in from the host.
pub const INT_SERIAL_OUT_RECV_PKT: u32 = 1 << 2;
