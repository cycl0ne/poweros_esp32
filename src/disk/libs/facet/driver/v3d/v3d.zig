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
pub const compile = @import("compile.zig");
pub const tiling = @import("tiling.zig");
/// The QPU's instructions as Mesa has them (src/broadcom/qpu), which the
/// compiler is ported onto: unpacked, packed, and printed.
pub const qpu_instr = @import("qpu/instr.zig");
pub const qpu_pack = @import("qpu/pack.zig");
pub const qpu_disasm = @import("qpu/disasm.zig");

test {
    _ = qpu;
    _ = compile;
    _ = cl;
    _ = tiling;
    _ = @import("qpu/tests.zig");
    _ = @import("compiler/validate.zig");
    _ = @import("compiler/list.zig");
    _ = @import("compiler/tests.zig");
}
