// SPDX-License-Identifier: MIT
//! The ESP32-P4's USB OTG controllers: where they are, their interrupts,
//! what turns each on, and their session inputs as a host. Unit 0 is the high-speed one on its own UTMI
//! PHY (the chip's DP/DM pins); unit 1 the full-speed one on the second
//! full-speed PHY (GPIO26 D-, GPIO27 D+), USB-Serial-JTAG being on the
//! first. The core's registers are `sdk.hardware.usb_dwc`.
//!
//! From ESP-IDF v6.1's hw_ver1 registers and its UTMI bring-up
//! (esp_hal_usb/usb_utmi_hal.c), for the chip before v3.

const map = @import("map.zig");
const intbits = @import("intbits.zig");
const system = @import("system.zig");
const gpio = @import("gpio.zig");
const signals = @import("signals.zig");

/// A controller: its registers, its interrupt source, and whether its PHY
/// is the high-speed UTMI one.
pub const Controller = struct { base: usize, interrupt: u32, utmi: bool };

/// The chip's controllers, by `PART_BusUnit`.
pub const controllers = [_]Controller{
    .{ .base = map.USB2, .interrupt = intbits.INTB_USB_OTG, .utmi = true },
    .{ .base = map.USB11, .interrupt = intbits.INTB_USB_OTG11_CH0, .utmi = false },
};

/// HP_SYSTEM's USBOTG20_CTRL: OTG_SUSPENDM, which the chip does not tie
/// high itself; without it a device going away is not seen.
pub const HP_SYSTEM_USBOTG20_CTRL: usize = map.HP_SYS + 0x15C;
pub const OTG_SUSPENDM: u32 = 1 << 21;

/// The UTMI PHY's FC_06: low-speed packets kept parallel, and the
/// low-speed keep-alive.
pub const UTMI_FC_06: usize = map.USBPHY + 0x18;
pub const UTMI_LS_PAR_EN: u32 = 1 << 0;
pub const UTMI_LS_KPALV_EN: u32 = 1 << 3;

/// Controller `unit`'s clocks on and the controller through a reset; the
/// high-speed one's PHY set up for a host.
pub inline fn powerOn(unit: u32) void {
    if (unit == 0) {
        system.enable(.usb_otg20);
        system.update(HP_SYSTEM_USBOTG20_CTRL, OTG_SUSPENDM, 0);
        system.update(UTMI_FC_06, UTMI_LS_PAR_EN | UTMI_LS_KPALV_EN, 0);
    } else {
        system.enable(.usb_otg11);
    }
}

/// Controller `unit` held in reset and its clocks off.
pub inline fn powerOff(unit: u32) void {
    if (unit == 0) {
        system.holdInReset(.usb_otg20);
        system.clockOff(.usb_otg20);
    } else {
        system.holdInReset(.usb_otg11);
        system.clockOff(.usb_otg11);
    }
}

/// Controller `unit` told it is a host. The full-speed one's session
/// inputs are held through the GPIO matrix at the A end of a cable, with
/// a valid VBUS, as ESP-IDF sets them (usb_phy.c); the high-speed one's
/// session is overridden in its own registers as it is brought up.
pub fn hostMode(unit: u32) void {
    if (unit == 0) return;
    gpio.connectIn(signals.USB_OTG11_IDDIG, gpio.in_low);
    gpio.connectIn(signals.USB_SRP_BVALID, gpio.in_low);
    gpio.connectIn(signals.USB_OTG11_VBUSVALID, gpio.in_high);
    gpio.connectIn(signals.USB_OTG11_AVALID, gpio.in_high);
}
