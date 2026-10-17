// SPDX-License-Identifier: MPL-2.0
//! The ROM tags QEMU's virt machine carries beyond the ones every image
//! has: the display driver for its ramfb.

pub const modules = .{
    @import("../../rom/libs/rtg_driver/fbboard/fbboard.zig"),
};
