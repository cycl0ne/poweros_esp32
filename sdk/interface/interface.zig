//! The libraries' jump tables, generated from sdk/fd by sdk/tools/fd2zig
//! (`zig build fd`). For each library: its name, its LVOs, its function
//! types, and its base type with the library's functions as methods.

pub const exec = @import("exec.zig");
pub const utility = @import("utility.zig");
pub const timer = @import("timer.zig");
pub const watchdog = @import("watchdog.zig");
pub const dma = @import("dma.zig");
pub const platform = @import("platform.zig");
pub const expander = @import("expander.zig");
pub const expansion = @import("expansion.zig");
pub const gpio = @import("gpio.zig");
pub const dos = @import("dos.zig");
pub const rtg = @import("rtg.zig");
pub const graphics = @import("graphics.zig");
pub const layers = @import("layers.zig");
pub const intuition = @import("intuition.zig");
pub const input = @import("input.zig");
pub const keymap = @import("keymap.zig");
pub const console = @import("console.zig");
pub const colorwheel = @import("colorwheel.zig");
pub const bsdsocket = @import("bsdsocket.zig");
pub const crypto = @import("crypto.zig");
pub const diskfont = @import("diskfont.zig");
pub const truetype = @import("truetype.zig");
pub const asl = @import("asl.zig");
pub const iffparse = @import("iffparse.zig");
pub const datatypes = @import("datatypes.zig");
pub const motion = @import("motion.zig");
pub const rdb = @import("rdb.zig");
