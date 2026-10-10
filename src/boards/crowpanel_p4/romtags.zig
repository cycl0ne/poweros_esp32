// SPDX-License-Identifier: MPL-2.0
//! The ROM tags the CrowPanel's image carries beyond the ones every image
//! has: the drivers for the parts this board has.

comptime {
    // The panel on MIPI-DSI.
    _ = @import("../../rom/libs/rtg_driver/dsiboard/dsiboard.zig");
    // The I2C bus, and the GT911 on it.
    _ = @import("../../rom/devs/i2c/i2c.zig");
    _ = @import("../../rom/devs/touch/touch.zig");
}
