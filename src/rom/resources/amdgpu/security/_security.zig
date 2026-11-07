// SPDX-License-Identifier: MPL-2.0
//! The security processor: a processor of the device's own that loads
//! every firmware the device's other processors run, and checks it
//! before they run it. Its own system is started by the machine's
//! firmware; a driver talks to it through a command ring it makes, whose
//! state is in the processor's second segment.
//!
//! What is read here is whether its system runs - a register that holds
//! the system's version once it does - and what the ring's control
//! register holds, which says whether a ring was left behind by whatever
//! ran before.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const reg = sdk.hardware.mmio.reg;
const AMDGPUBase = @import("../amdgpu_base.zig").AMDGPUBase;

/// Its registers, counted in 32-bit words from its second address: the
/// ring's control, and the version of its system.
const segment = 1;
const ring_control = 0x80;
const system_version = 0x91;

/// The processor's state, said.
pub fn tell(ab: *AMDGPUBase, processor: amdgpu.GPUBlock) void {
    const sys = ab.sys_base;
    const owner = sdk.resources.amdgpu.AMDGPUNAME;
    if (processor.count <= segment) return;
    const at = @as(usize, @intCast(ab.info.registers)) + @as(usize, processor.addresses[segment]) * 4;
    const version = reg(at + system_version * 4).*;
    const control = reg(at + ring_control * 4).*;
    exec.kprintf(sys, "%s: the security processor's system %s (%x), its ring control reads %x\n", .{
        owner,
        @as([*:0]const u8, if (version != 0) "runs" else "does not run"),
        version,
        control,
    });
}
