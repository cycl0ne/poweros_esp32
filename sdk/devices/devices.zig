// SPDX-License-Identifier: MIT
//! The devices' structures and constants, a file per device (include/devices).

pub const timer = @import("timer.zig");
pub const serial = @import("serial.zig");
pub const trackdisk = @import("trackdisk.zig");
pub const usbserial = @import("usbserial.zig");
pub const i2c = @import("i2c.zig");
pub const touch = @import("touch.zig");
pub const keyboard = @import("keyboard.zig");
pub const mouse = @import("mouse.zig");
pub const inputevent = @import("inputevent.zig");
pub const input = @import("input.zig");
pub const audio = @import("audio.zig");
