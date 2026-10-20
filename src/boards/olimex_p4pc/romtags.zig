// SPDX-License-Identifier: MPL-2.0
//! The ROM tags the ESP32-P4-PC's image carries beyond the ones every
//! image has: the drivers for the parts this board has.

pub const modules = .{
    // The chip's JPEG codec.
    @import("../../rom/resources/jpeg/jpeg.zig"),
    // The display on the MIPI-DSI connector.
    @import("../../rom/libs/rtg_driver/dsiboard/dsiboard.zig"),
    // The I2C bus.
    @import("../../rom/devs/i2c/i2c.zig"),
    // The codec behind the audio jack: rta.library, the I2S line's driver
    // and the codec's, the file sink, and audio.device over them.
    @import("../../rom/libs/rta/rta.zig"),
    @import("../../rom/libs/rta_driver/i2s/i2s.zig"),
    @import("../../rom/libs/rta_driver/es8311/es8311.zig"),
    @import("../../rom/libs/rta_driver/file/file.zig"),
    @import("../../rom/devs/audio/audio.zig"),
};
