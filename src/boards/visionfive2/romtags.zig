// SPDX-License-Identifier: MPL-2.0
//! The ROM tags the VisionFive 2 carries beyond the ones every image has:
//! the display driver for its HDMI port.

pub const modules = .{
    @import("../../rom/libs/rtg_driver/fbboard/fbboard.zig"),
};
