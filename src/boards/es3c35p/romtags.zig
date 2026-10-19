// SPDX-License-Identifier: MPL-2.0
//! The ROM tags the ES3C35P's image carries beyond the ones every image
//! has: the drivers for the parts this board has. What is not needed to
//! boot is not here - sdcard.device and fat-handler are on the disk - and a
//! part the board lacks has no driver in the image.

pub const modules = .{
    // The I2C bus, and rtg's transport over it.
    @import("../../rom/devs/i2c/i2c.zig"),
    @import("../../rom/libs/rtg_driver/i2cbus/i2cbus.zig"),
    // The panel's own touch controller.
    @import("../../rom/devs/touch/touch.zig"),
    // The codec and its amplifier: rta.library, the I2S line's driver and
    // the codec's, and audio.device over them.
    @import("../../rom/libs/rta/rta.zig"),
    @import("../../rom/libs/rta_driver/i2s/i2s.zig"),
    @import("../../rom/libs/rta_driver/es8311/es8311.zig"),
    @import("../../rom/devs/audio/audio.zig"),
    // The panel: a DCS controller on a QSPI bus.
    @import("../../rom/libs/rtg_driver/qspibus/qspibus.zig"),
    @import("../../rom/libs/rtg_driver/dcsboard/dcsboard.zig"),
};
