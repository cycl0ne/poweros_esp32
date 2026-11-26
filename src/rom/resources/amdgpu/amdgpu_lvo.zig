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
const StartGPUSecurity = @import("security/startgpusecurity.zig").StartGPUSecurity;
const LoadGPUFirmware = @import("security/loadgpufirmware.zig").LoadGPUFirmware;
const AddGPUIntServer = @import("interrupt/addgpuintserver.zig").AddGPUIntServer;
const RemGPUIntServer = @import("interrupt/remgpuintserver.zig").RemGPUIntServer;
const GetGPUBios = @import("device/getgpubios.zig").GetGPUBios;
const GetGPUConnector = @import("device/getgpuconnector.zig").GetGPUConnector;
const StartGPUGraphics = @import("security/startgpugraphics.zig").StartGPUGraphics;
const StartGPUDMA = @import("dma/startgpudma.zig").StartGPUDMA;
const SendGPUDMA = @import("dma/sendgpudma.zig").SendGPUDMA;
const WaitGPUDMA = @import("dma/waitgpudma.zig").WaitGPUDMA;
const GetGPUDMAState = @import("dma/getgpudmastate.zig").GetGPUDMAState;
const MapGPUMemory = @import("memory/mapgpumemory.zig").MapGPUMemory;
const UnmapGPUMemory = @import("memory/unmapgpumemory.zig").UnmapGPUMemory;
const StartGPUCompute = @import("compute/startgpucompute.zig").StartGPUCompute;
const SendGPUCompute = @import("compute/sendgpucompute.zig").SendGPUCompute;
const SendGPUKernel = @import("compute/sendgpukernel.zig").SendGPUKernel;
const WaitGPUCompute = @import("compute/waitgpucompute.zig").WaitGPUCompute;
const GetGPUComputeState = @import("compute/getgpucomputestate.zig").GetGPUComputeState;
const LoadGPUCode = @import("code/loadgpucode.zig").LoadGPUCode;
const FindGPUKernel = @import("code/findgpukernel.zig").FindGPUKernel;
const FreeGPUCode = @import("code/freegpucode.zig").FreeGPUCode;

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

// Every call's contract is in the list, once, and documents the LVO the
// .fd gives it.
comptime {
    @setEvalBranchQuota(10_000_000);
    exec.libraries.checkContractFiles(&contract_files, LVO, "amdgpu.resource", "pub fn ");
}

/// The files whose call carries its contract, above `pub fn <Name>`.
const contract_files = [_][]const u8{
    @embedFile("device/getgpuinfo.zig"),
    @embedFile("device/findgpublock.zig"),
    @embedFile("power/setgpupower.zig"),
    @embedFile("memory/allocgpumemory.zig"),
    @embedFile("memory/freegpumemory.zig"),
    @embedFile("security/startgpusecurity.zig"),
    @embedFile("security/loadgpufirmware.zig"),
    @embedFile("interrupt/addgpuintserver.zig"),
    @embedFile("interrupt/remgpuintserver.zig"),
    @embedFile("device/getgpubios.zig"),
    @embedFile("device/getgpuconnector.zig"),
    @embedFile("security/startgpugraphics.zig"),
    @embedFile("dma/startgpudma.zig"),
    @embedFile("dma/sendgpudma.zig"),
    @embedFile("dma/waitgpudma.zig"),
    @embedFile("dma/getgpudmastate.zig"),
    @embedFile("memory/mapgpumemory.zig"),
    @embedFile("memory/unmapgpumemory.zig"),
    @embedFile("compute/startgpucompute.zig"),
    @embedFile("compute/sendgpucompute.zig"),
    @embedFile("compute/sendgpukernel.zig"),
    @embedFile("compute/waitgpucompute.zig"),
    @embedFile("compute/getgpucomputestate.zig"),
    @embedFile("code/loadgpucode.zig"),
    @embedFile("code/findgpukernel.zig"),
    @embedFile("code/freegpucode.zig"),
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
fn lvoStartGPUSecurity(ab: *AMDGPUBase, toc: [*]const u8, length: u32) callconv(.c) bool {
    return StartGPUSecurity(ab, toc, length);
}
fn lvoLoadGPUFirmware(ab: *AMDGPUBase, kind: u32, image: [*]const u8, length: u32, address: *u64) callconv(.c) bool {
    return LoadGPUFirmware(ab, kind, image, length, address);
}
fn lvoAddGPUIntServer(ab: *AMDGPUBase, client: u32, source: u32, server: *exec.Interrupt) callconv(.c) bool {
    return AddGPUIntServer(ab, client, source, server);
}
fn lvoRemGPUIntServer(ab: *AMDGPUBase, server: *exec.Interrupt) callconv(.c) void {
    RemGPUIntServer(ab, server);
}
fn lvoGetGPUBios(ab: *AMDGPUBase, bios: *amdgpu.GPUBios) callconv(.c) bool {
    return GetGPUBios(ab, bios);
}
fn lvoGetGPUConnector(ab: *AMDGPUBase, index: u32, connector: *amdgpu.GPUConnector) callconv(.c) bool {
    return GetGPUConnector(ab, index, connector);
}
fn lvoStartGPUGraphics(ab: *AMDGPUBase, files: *const amdgpu.GPUGraphicsFiles) callconv(.c) bool {
    return StartGPUGraphics(ab, files);
}
fn lvoStartGPUDMA(ab: *AMDGPUBase) callconv(.c) bool {
    return StartGPUDMA(ab);
}
fn lvoSendGPUDMA(ab: *AMDGPUBase, packets: [*]const u32, words: u32) callconv(.c) u32 {
    return SendGPUDMA(ab, packets, words);
}
fn lvoWaitGPUDMA(ab: *AMDGPUBase, job: u32, most_ms: u32) callconv(.c) bool {
    return WaitGPUDMA(ab, job, most_ms);
}
fn lvoGetGPUDMAState(ab: *AMDGPUBase, state: *amdgpu.GPUDMAState) callconv(.c) bool {
    return GetGPUDMAState(ab, state);
}
fn lvoMapGPUMemory(ab: *AMDGPUBase, address: *anyopaque, bytes: u32, memory: *amdgpu.GPUMemory) callconv(.c) bool {
    return MapGPUMemory(ab, address, bytes, memory);
}
fn lvoUnmapGPUMemory(ab: *AMDGPUBase, memory: *amdgpu.GPUMemory) callconv(.c) void {
    UnmapGPUMemory(ab, memory);
}
fn lvoStartGPUCompute(ab: *AMDGPUBase) callconv(.c) bool {
    return StartGPUCompute(ab);
}
fn lvoSendGPUCompute(ab: *AMDGPUBase, packets: [*]const u32, words: u32) callconv(.c) u32 {
    return SendGPUCompute(ab, packets, words);
}
fn lvoSendGPUKernel(ab: *AMDGPUBase, kernel: *const amdgpu.GPUKernel, dispatch: *const amdgpu.GPUDispatch) callconv(.c) u32 {
    return SendGPUKernel(ab, kernel, dispatch);
}
fn lvoWaitGPUCompute(ab: *AMDGPUBase, job: u32, most_ms: u32) callconv(.c) bool {
    return WaitGPUCompute(ab, job, most_ms);
}
fn lvoGetGPUComputeState(ab: *AMDGPUBase, state: *amdgpu.GPUComputeState) callconv(.c) bool {
    return GetGPUComputeState(ab, state);
}
fn lvoLoadGPUCode(ab: *AMDGPUBase, image: [*]const u8, bytes: u32, code: *amdgpu.GPUCode) callconv(.c) bool {
    return LoadGPUCode(ab, image, bytes, code);
}
fn lvoFindGPUKernel(ab: *AMDGPUBase, code: *const amdgpu.GPUCode, name: [*:0]const u8, kernel: *amdgpu.GPUKernel) callconv(.c) bool {
    return FindGPUKernel(ab, code, name, kernel);
}
fn lvoFreeGPUCode(ab: *AMDGPUBase, code: *amdgpu.GPUCode) callconv(.c) void {
    FreeGPUCode(ab, code);
}

/// The jump table, in slot order: a resource has no standard vectors, so
/// its first function is in the first slot.
pub const vectors = [_]*const anyopaque{
    vec(lvoGetGPUInfo),
    vec(lvoFindGPUBlock),
    vec(lvoSetGPUPower),
    vec(lvoAllocGPUMemory),
    vec(lvoFreeGPUMemory),
    vec(lvoStartGPUSecurity),
    vec(lvoLoadGPUFirmware),
    vec(lvoAddGPUIntServer),
    vec(lvoRemGPUIntServer),
    vec(lvoGetGPUBios),
    vec(lvoGetGPUConnector),
    vec(lvoStartGPUGraphics),
    vec(lvoStartGPUDMA),
    vec(lvoSendGPUDMA),
    vec(lvoWaitGPUDMA),
    vec(lvoGetGPUDMAState),
    vec(lvoMapGPUMemory),
    vec(lvoUnmapGPUMemory),
    vec(lvoStartGPUCompute),
    vec(lvoSendGPUCompute),
    vec(lvoSendGPUKernel),
    vec(lvoWaitGPUCompute),
    vec(lvoGetGPUComputeState),
    vec(lvoLoadGPUCode),
    vec(lvoFindGPUKernel),
    vec(lvoFreeGPUCode),
};
