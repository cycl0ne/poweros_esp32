// SPDX-License-Identifier: MPL-2.0
//! The ROM tags the CrowPanel's image carries beyond the ones every image
//! has: the drivers for the parts this board has.

pub const modules = .{
    // The chip's JPEG codec.
    @import("../../rom/resources/jpeg/jpeg.zig"),
    // The panel on MIPI-DSI.
    @import("../../rom/libs/rtg_driver/dsiboard/dsiboard.zig"),
    // The I2C bus, and the GT911 on it.
    @import("../../rom/devs/i2c/i2c.zig"),
    @import("../../rom/devs/touch/touch.zig"),
    // The speakers' amplifiers on I2S.
    @import("../../rom/devs/audio/audio.zig"),
};
