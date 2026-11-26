// SPDX-License-Identifier: MPL-2.0
//! FindGPUKernel: a kernel of a loaded code object, by its name.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _code = @import("_code.zig");

/// The kernel `name` of a loaded code object, as SendGPUKernel runs it.
///
/// SYNOPSIS:
/// ```zig
/// fn FindGPUKernel(ab: *AMDGPUBase, code: *const amdgpu.GPUCode, name: [*:0]const u8, kernel: *amdgpu.GPUKernel) bool
/// ```
///
/// SINCE: 1.12. LVO -100.
///
/// INPUTS:
/// - `code` - the code object, as LoadGPUCode loaded it.
/// - `name` - the kernel's name: the function's, as its source exports it.
/// - `kernel` - where the kernel is described (GPUKernel).
///
/// RESULT:
/// True with `kernel` filled. False, `kernel` untouched, where the code
/// object has no kernel of that name, its descriptor or its code is not
/// within what was loaded, or its arguments are to be loaded into its
/// registers before it starts, which a dispatch does not do.
///
/// BEHAVIOR:
/// The kernel's descriptor - 64 bytes the code object holds for each of
/// its kernels - is found by its symbol `<name>.kd`, or, as the build's
/// compiler names a kernel's descriptor after the file it is in, as the
/// descriptor whose code starts where the function `<name>` does. From
/// the descriptor: where the kernel's code is - the device's address,
/// from where the code object was placed - its three resource words, the
/// bytes of its arguments, of group memory and of private memory, and
/// its properties.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The symbols are read in the image LoadGPUCode
/// was given, which must still be there.
///
/// NOTES:
/// A kernel found is not yet checked against what a dispatch hands it:
/// SendGPUKernel refuses one that takes more.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `LoadGPUCode`, `SendGPUKernel`, `FreeGPUCode`
///
/// EXAMPLES:
/// ```zig
/// var kernel: amdgpu.GPUKernel = .{};
/// if (!ab.FindGPUKernel(&code, "fill", &kernel)) return error.NoKernel;
/// ```
pub fn FindGPUKernel(ab: *AMDGPUBase, code: *const amdgpu.GPUCode, name: [*:0]const u8, kernel: *amdgpu.GPUKernel) bool {
    const image = code.image orelse return false;
    if (code.memory.bytes == 0) return false;
    const file = image[0..code.bytes];
    const head = _code.header(file, _code.EF_AMDGPU_MACH_GFX1103) orelse return false;
    const at = _code.kernelDescriptor(file, head, name) orelse return false;
    const offset = _code.offsetOf(file, head, at, _code.descriptor_bytes) orelse return false;
    const found = _code.descriptorAt(file, offset) orelse return false;
    const entry = at +% @as(u64, @bitCast(found.entry));
    if (entry < code.first or entry - code.first >= code.memory.bytes) return false;
    if (found.preloaded != 0) {
        exec.kprintf(ab.sys_base, "%s: the kernel %s has its arguments loaded into its registers, which a dispatch does not do\n", .{ amdgpu.AMDGPUNAME, name });
        return false;
    }
    kernel.* = .{
        .code = code.memory.device + (entry - code.first),
        .rsrc1 = found.rsrc1,
        .rsrc2 = found.rsrc2,
        .rsrc3 = found.rsrc3,
        .argument_bytes = found.argument_bytes,
        .group_bytes = found.group_bytes,
        .private_bytes = found.private_bytes,
        .properties = found.properties,
    };
    return true;
}
