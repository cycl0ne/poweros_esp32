// SPDX-License-Identifier: MIT
//! The driver of the BCM2712's V3D 7.1, the 3D core of its VideoCore VII.
//!
//! A module, as the rasterizer is: compiled into what uses it, which is
//! the driver's table in facet.library (driver.zig, _play.zig, beside this)
//! and its test program (c/test/v3d). The hardware is one: the two are not
//! run at the same time.

pub const regs = @import("regs.zig");
pub const Gpu = @import("gpu.zig").Gpu;
pub const Clock = @import("gpu.zig").Clock;
pub const Clocks = @import("gpu.zig").Clocks;
pub const Ident = @import("gpu.zig").Ident;
pub const Block = @import("space.zig").Block;
pub const Space = @import("space.zig").Space;
pub const Engine = @import("engine.zig").Engine;
pub const cl = @import("cl.zig");
pub const frame = @import("frame.zig");
pub const qpu = @import("qpu.zig");
pub const tiling = @import("tiling.zig");

test {
    _ = qpu;
    _ = cl;
    _ = tiling;
}
