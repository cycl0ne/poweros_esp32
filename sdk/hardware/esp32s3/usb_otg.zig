// SPDX-License-Identifier: MIT
//! The ESP32-S3's USB OTG controller: where it is, its interrupt, and
//! what turns it on. One controller, full and low speed, on the chip's
//! one PHY (GPIO19 D-, GPIO20 D+), which USB-Serial-JTAG uses as the chip
//! starts; handing the PHY over is usbport.resource's (todo), so `powerOn`
//! does not touch it. The core's registers are `sdk.hardware.usb_dwc`.

const map = @import("map.zig");
const intbits = @import("intbits.zig");
const system = @import("system.zig");

/// A controller: its registers, its interrupt source, and whether its PHY
/// is the high-speed UTMI one.
pub const Controller = struct { base: usize, interrupt: u32, utmi: bool };

/// The chip's controllers, by `PART_BusUnit`.
pub const controllers = [_]Controller{
    .{ .base = map.USB_OTG, .interrupt = intbits.INTB_USB, .utmi = false },
};

/// Controller `unit`'s clocks on and the controller through a reset.
pub inline fn powerOn(unit: u32) void {
    _ = unit;
    system.enable(.usb_otg);
}

/// Controller `unit` held in reset and its clock off.
pub inline fn powerOff(unit: u32) void {
    _ = unit;
    system.holdInReset(.usb_otg);
    system.clockOff(.usb_otg);
}
