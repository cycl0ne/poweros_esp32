// SPDX-License-Identifier: MPL-2.0
//! The ROM tags the emulator's image carries beyond the ones every image
//! has: the driver for its virtual display, and sound that plays into
//! nothing - rta.library, the null sink and audio.device - so a program
//! that plays runs as it would on a board. The window's keys and pointer
//! are keyboard.device's and mouse.device's, which every image has, and
//! which find the emulator's by the board's parts. It has no I2C, touch
//! panel, codec or card slot, so none of their drivers is here.

pub const modules = .{
    @import("../../rom/libs/rtg_driver/qemuboard/qemuboard.zig"),
    @import("../../rom/libs/rta/rta.zig"),
    @import("../../rom/libs/rta_driver/null/null.zig"),
    @import("../../rom/devs/audio/audio.zig"),
};
