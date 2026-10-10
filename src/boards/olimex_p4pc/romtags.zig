// SPDX-License-Identifier: MPL-2.0
//! The ROM tags the ESP32-P4-PC's image carries beyond the ones every
//! image has: the drivers for the parts this board has.

comptime {
    // The chip's JPEG codec.
    _ = @import("../../rom/resources/jpeg/jpeg.zig");
    // The display on the MIPI-DSI connector.
    _ = @import("../../rom/libs/rtg_driver/dsiboard/dsiboard.zig");
    // The I2C bus.
    _ = @import("../../rom/devs/i2c/i2c.zig");
}
