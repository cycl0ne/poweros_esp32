// SPDX-License-Identifier: MPL-2.0
//! amdgpu.resource's jump table: every `lvo<Name>` wrapper, the table of
//! them in slot order, and the checks that hold the table to the SDK's
//! contract - the signatures and the documented LVOs at compile time.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const vec = exec.vec;
const AMDGPUBase = @import("amdgpu_base.zig").AMDGPUBase;
const GetGPUInfo = @import("device/getgpuinfo.zig").GetGPUInfo;
const FindGPUBlock = @import("device/findgpublock.zig").FindGPUBlock;
const SetGPUPower = @import("power/setgpupower.zig").SetGPUPower;
const AllocGPUMemory = @import("memory/allocgpumemory.zig").AllocGPUMemory;
const FreeGPUMemory = @import("memory/freegpumemory.zig").FreeGPUMemory;

/// amdgpu.resource's interface, as the SDK generates it from
/// sdk/fd/amdgpu_lib.fd.
const interface = sdk.interface.amdgpu;
const LVO = interface.LVO;

comptime {
    for (@typeInfo(LVO).@"struct".decls) |d| {
        const f = @field(@This(), "lvo" ++ d.name);
        if (!exec.libraries.sameSignature(@TypeOf(&f), @field(interface.Fn, d.name))) {
            @compileError("amdgpu.resource: lvo" ++ d.name ++ " does not match the SDK's type");
        }
    }
}

// Every slot's documented LVO is the one the .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    for (contract_files) |source| {
        exec.libraries.checkDocumentedLvosAt(source, LVO, "amdgpu.resource", "pub fn ");
    }
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("device/getgpuinfo.zig"),
    @embedFile("device/findgpublock.zig"),
    @embedFile("power/setgpupower.zig"),
    @embedFile("memory/allocgpumemory.zig"),
    @embedFile("memory/freegpumemory.zig"),
};

fn lvoGetGPUInfo(ab: *AMDGPUBase, info: *amdgpu.GPUInfo) callconv(.c) bool {
    return GetGPUInfo(ab, info);
}
fn lvoFindGPUBlock(ab: *AMDGPUBase, id: u32, instance: u32, block: *amdgpu.GPUBlock) callconv(.c) bool {
    return FindGPUBlock(ab, id, instance, block);
}
fn lvoSetGPUPower(ab: *AMDGPUBase, part: u32, instance: u32, on: bool) callconv(.c) bool {
    return SetGPUPower(ab, part, instance, on);
}
fn lvoAllocGPUMemory(ab: *AMDGPUBase, bytes: u32, alignment: u32, memory: *amdgpu.GPUMemory) callconv(.c) bool {
    return AllocGPUMemory(ab, bytes, alignment, memory);
}
fn lvoFreeGPUMemory(ab: *AMDGPUBase, memory: *amdgpu.GPUMemory) callconv(.c) void {
    FreeGPUMemory(ab, memory);
}

/// The jump table, in slot order: a resource has no standard vectors, so
/// its first function is in the first slot.
pub const vectors = [_]*const anyopaque{
    vec(lvoGetGPUInfo),
    vec(lvoFindGPUBlock),
    vec(lvoSetGPUPower),
    vec(lvoAllocGPUMemory),
    vec(lvoFreeGPUMemory),
};
