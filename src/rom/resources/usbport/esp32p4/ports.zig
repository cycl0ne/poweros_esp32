// SPDX-License-Identifier: MPL-2.0
//! The ESP32-P4's USB ports: port 0 the first full-speed PHY (GPIO24 D-,
//! GPIO25 D+), USB-Serial-JTAG's; port 1 the second (GPIO26, GPIO27), the
//! full-speed OTG controller's (unit 1); port 2 the high-speed UTMI PHY,
//! the high-speed OTG controller's (unit 0). Each controller has its own
//! as the chip starts, so nothing is switched: the resource only keeps
//! who holds which.

const usbport = @import("sdk").resources.usbport;

pub const count = 3;

/// The port `controller`'s unit `unit` is on, or null for a controller
/// the chip does not have.
pub fn portOf(controller: u8, unit: u8) ?u32 {
    return switch (controller) {
        usbport.USBCTL_SERIALJTAG => if (unit == 0) 0 else null,
        usbport.USBCTL_OTG => switch (unit) {
            0 => 2,
            1 => 1,
            else => null,
        },
        else => null,
    };
}

/// Nothing to switch: every port stays with its own controller.
pub fn route(port: u32, controller: ?u8, role: u8) void {
    _ = port;
    _ = controller;
    _ = role;
}
