// SPDX-License-Identifier: MIT
//! The devices' structures and constants, a file per device (include/devices).

pub const timer = @import("timer.zig");
pub const serial = @import("serial.zig");
/// A serial unit over any line, for the devices that speak serial.device's API.
pub const serialunit = @import("serialunit.zig");
pub const trackdisk = @import("trackdisk.zig");
pub const scsidisk = @import("scsidisk.zig");
pub const usbserial = @import("usbserial.zig");
pub const rs485 = @import("rs485.zig");
pub const i2c = @import("i2c.zig");
pub const touch = @import("touch.zig");
pub const keyboard = @import("keyboard.zig");
pub const mouse = @import("mouse.zig");
pub const inputevent = @import("inputevent.zig");
pub const input = @import("input.zig");
pub const audio = @import("audio.zig");
pub const network = @import("network.zig");
pub const wireless = @import("wireless.zig");
pub const slip = @import("slip.zig");
pub const ssh = @import("ssh.zig");
pub const telnet = @import("telnet.zig");
pub const clipboard = @import("clipboard.zig");
pub const usbhc = @import("usbhc.zig");
pub const usbclass = @import("usbclass.zig");
/// A removable unit's drives, made from its first medium: a table's
/// partitions, or the unit's own drive.
pub const automount = @import("automount.zig");
