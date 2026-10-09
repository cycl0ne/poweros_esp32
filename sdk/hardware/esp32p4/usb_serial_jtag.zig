// SPDX-License-Identifier: MIT
//! The chip's own USB port, USB Serial/JTAG: a serial line and a JTAG
//! adapter on one USB connection. Endpoint 1 is the serial line.

const map = @import("map.zig");

pub const EP1: usize = map.USB_SERIAL_JTAG + 0x00;
pub const EP1_CONF: usize = map.USB_SERIAL_JTAG + 0x04;

// EP1_CONF's bits.
pub const EP1_WR_DONE: u32 = 1 << 0;
pub const EP1_IN_EP_DATA_FREE: u32 = 1 << 1;
pub const EP1_OUT_EP_DATA_AVAIL: u32 = 1 << 2;
