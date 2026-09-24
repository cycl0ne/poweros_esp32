// SPDX-License-Identifier: MPL-2.0
//! The USB-Serial-JTAG port: a serial line to the USB host (a CDC-ACM port
//! there), without a line of its own. usbserial.device drives it (through
//! unit.zig, which it shares with serial.device).

const intbits = @import("sdk").hardware.intbits;
const reg = @import("sdk").hardware.mmio.reg;
const usj = @import("sdk").hardware.usb_serial_jtag;

/// ETS_USB_SERIAL_JTAG_INTR_SOURCE.
pub const source = intbits.INTB_USB_SERIAL_JTAG;

/// Cleared when the USB FIFO stays full (no host attached), so output does
/// not stall on every byte. Re-armed as soon as the FIFO drains.
var usb_alive = true;

/// One byte into the FIFO for the host.
pub fn put(c: u8) void {
    if (!usb_alive) {
        if (reg(usj.EP1_CONF).* & usj.EP1_IN_EP_DATA_FREE == 0) return;
        usb_alive = true;
    }
    var spins: u32 = 0;
    while (reg(usj.EP1_CONF).* & usj.EP1_IN_EP_DATA_FREE == 0) : (spins += 1) {
        if (spins > 50_000) {
            usb_alive = false;
            return;
        }
    }
    reg(usj.EP1).* = c;
}

/// Send what the FIFO holds.
pub fn flush() void {
    if (usb_alive) reg(usj.EP1_CONF).* = usj.EP1_WR_DONE;
}

/// The next byte from the host, if any.
pub fn read() ?u8 {
    if (usb_alive and reg(usj.EP1_CONF).* & usj.EP1_OUT_EP_DATA_AVAIL != 0) return @truncate(reg(usj.EP1).*);
    return null;
}

/// The receive interrupt on: for every packet from the host. Route the
/// source first; an interrupt raised before that is lost.
pub fn enableRx() void {
    reg(usj.INT_CLR).* = usj.INT_SERIAL_OUT_RECV_PKT;
    reg(usj.INT_ENA).* |= usj.INT_SERIAL_OUT_RECV_PKT;
}

pub fn disableRx() void {
    reg(usj.INT_ENA).* &= ~usj.INT_SERIAL_OUT_RECV_PKT;
    reg(usj.INT_CLR).* = usj.INT_SERIAL_OUT_RECV_PKT;
}

/// Whether the receive interrupt was raised; clears it. Clear first, then
/// read the port empty: a packet that comes in between raises it again.
pub fn takeRxInterrupt() bool {
    if (reg(usj.INT_ST).* & usj.INT_SERIAL_OUT_RECV_PKT == 0) return false;
    reg(usj.INT_CLR).* = usj.INT_SERIAL_OUT_RECV_PKT;
    return true;
}
