// SPDX-License-Identifier: MPL-2.0
//! The ROM tags the 7B's image carries beyond the ones every image has:
//! the drivers for the parts this board has. What is not needed to boot is
//! not here, and a part the board lacks has no driver in the image.

pub const modules = .{
    // The I2C bus, and rtg's transport over it.
    @import("../../rom/devs/i2c/i2c.zig"),
    @import("../../rom/libs/rtg_driver/i2cbus/i2cbus.zig"),
    // The GT911.
    @import("../../rom/devs/touch/touch.zig"),
    // The CH422G, which holds the panel's and the touch controller's lines.
    @import("../../rom/resources/expander/expander.zig"),
    // The panel: RGB on LCD_CAM.
    @import("../../rom/libs/rtg_driver/rgbboard/rgbboard.zig"),
};
