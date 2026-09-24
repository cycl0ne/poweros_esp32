// SPDX-License-Identifier: MPL-2.0
//! The ROM tags the emulator's image carries beyond the ones every image
//! has: the drivers for its virtual display and for the window's keys and
//! pointer. It has no I2C, touch panel, codec or card slot, so none of
//! their drivers is here.

comptime {
    _ = @import("../../rom/devs/keyboard/keyboard.zig");
    _ = @import("../../rom/devs/mouse/mouse.zig");
    _ = @import("../../rom/libs/rtg_driver/qemuboard/qemuboard.zig");
}
