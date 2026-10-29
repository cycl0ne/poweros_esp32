// SPDX-License-Identifier: MIT
//! The resources' structures and constants, a file per resource
//! (include/resources).

pub const watchdog = @import("watchdog.zig");
pub const dma = @import("dma.zig");
pub const platform = @import("platform.zig");
pub const expander = @import("expander.zig");
pub const gpio = @import("gpio.zig");
pub const jpeg = @import("jpeg.zig");
pub const videodec = @import("videodec.zig");
pub const battery = @import("battery.zig");
pub const usbport = @import("usbport.zig");
pub const battclock = @import("battclock.zig");
pub const battmem = @import("battmem.zig");
pub const battmembits = @import("battmembits.zig");
pub const thermal = @import("thermal.zig");
