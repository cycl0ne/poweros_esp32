// SPDX-License-Identifier: MPL-2.0
//! The ROM tags the ES3C35P's image carries beyond the ones every image
//! has: the drivers for the parts this board has. What is not needed to
//! boot is not here - sd.device and fat-handler are on the disk - and a
//! part the board lacks has no driver in the image.

comptime {
    // The I2C bus, and rtg's transport over it.
    _ = @import("../../rom/devs/i2c/i2c.zig");
    _ = @import("../../rom/libs/rtg_driver/i2cbus/i2cbus.zig");
    // The panel's own touch controller.
    _ = @import("../../rom/devs/touch/touch.zig");
    // The codec and its amplifier.
    _ = @import("../../rom/devs/audio/audio.zig");
    // The panel: a DCS controller on a QSPI bus.
    _ = @import("../../rom/libs/rtg_driver/qspibus/qspibus.zig");
    _ = @import("../../rom/libs/rtg_driver/dcsboard/dcsboard.zig");
}
