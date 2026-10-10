// SPDX-License-Identifier: MPL-2.0
//! The ROM tags the ESP32-P4-PC's image carries beyond the ones every
//! image has: the drivers for the parts this board has.

comptime {
    // The display on the MIPI-DSI connector.
    _ = @import("../../rom/libs/rtg_driver/dsiboard/dsiboard.zig");
}
