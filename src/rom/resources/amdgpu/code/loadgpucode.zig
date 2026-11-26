// SPDX-License-Identifier: MPL-2.0
//! LoadGPUCode: a code object for the graphics block's compute engine
//! placed in the device's memory.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _code = @import("_code.zig");
const _dma = @import("../dma/_dma.zig");

/// A code object for the graphics block's compute engine placed in the
/// device's memory, its own addresses set to where it is.
///
/// SYNOPSIS:
/// ```zig
/// fn LoadGPUCode(ab: *AMDGPUBase, image: [*]const u8, bytes: u32, code: *amdgpu.GPUCode) bool
/// ```
///
/// SINCE: 1.12. LVO -96.
///
/// INPUTS:
/// - `image` - the code object: an ELF shared object for the vendor's
///   graphics processors (amdgcn-amdhsa), as the build makes one
///   (`poweros_sdk.addGPUCode`).
/// - `bytes` - its length.
/// - `code` - where the loaded code object is described (GPUCode).
///
/// RESULT:
/// True with `code` filled. False, `code` untouched, where there is no
/// device, its graphics block is not one whose processor is known, the
/// image is not a code object for that processor - gfx1103 on the
/// graphics block 11.0.1 - names a place outside itself, has no loadable
/// segment or segments spanning more than 64 MiB, asks for relocations
/// other than its own addresses', or there is no room in the device's
/// memory. Why an image is refused is said in the system's log.
///
/// BEHAVIOR:
/// The ELF header is checked - 64-bit, little-endian, the vendor's ABI
/// for code object versions 4 to 6, a shared object for this processor -
/// and the program headers read: the loadable segments' span, from the
/// first one's page to the end of the last one, rounded up to a page, is
/// taken from the device's memory, on a page, and cleared, and each
/// segment's bytes copied to its address less the span's start. The
/// object's relocations are applied - each of the kind that adds where
/// the object is to an address of its own (R_AMDGPU_RELATIVE64) - and the
/// writes sent on to the memory. Every relocation is checked before
/// anything is taken.
///
/// CONTEXT:
/// - Waits: only for the memory's lock.
/// - Interrupts: no.
/// - Locks: takes the memory lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The piece of the device's memory is the caller's until FreeGPUCode. The
/// image stays the caller's but must stay where it is while kernels are
/// looked for in it (FindGPUKernel): `code` keeps its address, not a
/// copy.
///
/// NOTES:
/// The engines see the code once a job starts: each job on the compute
/// engine's queue drops the engine's instruction caches first
/// (SendGPUCompute).
///
/// BUGS:
/// Code objects of version 2 and 3, other processors and objects that
/// import symbols are not loaded.
///
/// SEE ALSO:
/// `FindGPUKernel`, `FreeGPUCode`, `SendGPUKernel`, `AllocGPUMemory`
///
/// EXAMPLES:
/// ```zig
/// const image = @embedFile("gpu_code");
/// var code: amdgpu.GPUCode = .{};
/// if (!ab.LoadGPUCode(image.ptr, image.len, &code)) return error.NoCode;
/// defer ab.FreeGPUCode(&code);
/// ```
pub fn LoadGPUCode(ab: *AMDGPUBase, image: [*]const u8, bytes: u32, code: *amdgpu.GPUCode) bool {
    if (ab.device == null or !ab.graphics_known) return false;
    const sys = ab.sys_base;
    const owner = amdgpu.AMDGPUNAME;
    const gpu: *sdk.interface.amdgpu.AMDGPUBase = @ptrCast(&ab.lib);
    const file = image[0..bytes];
    const head = _code.header(file, _code.EF_AMDGPU_MACH_GFX1103) orelse {
        exec.kprintf(sys, "%s: an image of %u bytes is not a code object for the graphics block's processor (gfx1103)\n", .{ owner, bytes });
        return false;
    };
    const covered = _code.span(file, head) orelse {
        exec.kprintf(sys, "%s: a code object of %u bytes has no segments that can be placed\n", .{ owner, bytes });
        return false;
    };
    const asked = _code.relocations(file, head) orelse {
        exec.kprintf(sys, "%s: a code object of %u bytes asks for relocations the loader does not do\n", .{ owner, bytes });
        return false;
    };
    const table = if (asked.bytes == 0) 0 else _code.offsetOf(file, head, asked.address, asked.bytes) orelse {
        exec.kprintf(sys, "%s: a code object's relocations are not in it\n", .{owner});
        return false;
    };
    const count = asked.bytes / _code.relocation_bytes;
    for (0..count) |index| {
        const one = _code.relocation(file, table + index * _code.relocation_bytes) orelse {
            exec.kprintf(sys, "%s: a code object asks for a relocation the loader does not do\n", .{owner});
            return false;
        };
        if (one.address < covered.first or one.address - covered.first > covered.bytes - 8) {
            exec.kprintf(sys, "%s: a code object asks for a relocation outside itself\n", .{owner});
            return false;
        }
    }

    var memory: amdgpu.GPUMemory = .{};
    if (!gpu.AllocGPUMemory(@intCast(covered.bytes), @intCast(_code.page), &memory)) {
        exec.kprintf(sys, "%s: no room in the device's memory for a code object of %lu bytes\n", .{ owner, covered.bytes });
        return false;
    }
    const into: [*]volatile u8 = @ptrFromInt(@as(usize, @intCast(memory.cpu)));
    const doubles: [*]volatile u64 = @ptrFromInt(@as(usize, @intCast(memory.cpu)));
    for (0..@intCast(covered.bytes / 8)) |index| doubles[index] = 0;
    for (0..head.phnum) |index| {
        const one = _code.segment(file, head, @intCast(index)).?;
        if (one.kind != _code.PT_LOAD) continue;
        const start: usize = @intCast(one.address - covered.first);
        const from: usize = @intCast(one.offset);
        for (0..@intCast(one.file_bytes)) |at| into[start + at] = file[from + at];
    }
    for (0..count) |index| {
        const one = _code.relocation(file, table + index * _code.relocation_bytes).?;
        const value = memory.device -% covered.first +% one.addend;
        const start: usize = @intCast(one.address - covered.first);
        for (0..8) |at| into[start + at] = @truncate(value >> @intCast(8 * at));
    }
    _dma.fence();
    code.* = .{ .memory = memory, .first = covered.first, .image = image, .bytes = bytes };
    return true;
}
