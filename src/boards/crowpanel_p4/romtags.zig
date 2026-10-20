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
    // The speakers' amplifiers on I2S: rta.library, the I2S line's driver
    // and the amplifiers', the file sink, and audio.device over them.
    @import("../../rom/libs/rta/rta.zig"),
    @import("../../rom/libs/rta_driver/i2s/i2s.zig"),
    @import("../../rom/libs/rta_driver/i2samp/i2samp.zig"),
    @import("../../rom/libs/rta_driver/file/file.zig"),
    @import("../../rom/devs/audio/audio.zig"),
};
