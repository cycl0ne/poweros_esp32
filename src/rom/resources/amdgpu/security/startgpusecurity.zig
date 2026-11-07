// SPDX-License-Identifier: MPL-2.0
//! StartGPUSecurity: the security processor made ready to load firmware -
//! its ring, its table of contents, and the protected region it asks for.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _security = @import("_security.zig");

/// The security processor made ready to load firmware: its ring made, its
/// table of contents loaded, and the protected region it asks for set up.
///
/// SYNOPSIS:
/// ```zig
/// fn StartGPUSecurity(ab: *AMDGPUBase, toc: [*]const u8, length: u32) bool
/// ```
///
/// SINCE: 1.2. LVO -24.
///
/// INPUTS:
/// - `toc` - the processor's table of contents, the whole file as it is
///   on the disk (DEVS:firmware/amdgpu/psp_<version>_toc.bin), its
///   vendor's header included.
/// - `length` - the file's length in bytes.
///
/// RESULT:
/// True once the processor is ready for LoadGPUFirmware, and at once
/// where it already is. False where the file's header does not say the
/// file's own length or where its part lies in it; where the processor
/// does not take the ring, does not answer a command within five seconds,
/// or answers the table of contents without the region's size; where the
/// device's memory has no room for the ring or the region; where the
/// processor is one whose ring the resource does not know; and on a
/// machine without the device.
///
/// BEHAVIOR:
/// Under the security processor's lock. The first call makes the ring: a
/// piece of the device's memory with the ring, the page a command is
/// written to and the fence the processor answers on. Then the table of
/// contents - the part of the file its header names - is copied into a
/// piece of its own and loaded, the processor answering with the size of
/// the protected region its firmware needs; that region is taken from the
/// device's memory, on a mebibyte, and set up, at its address to the
/// device and in the machine. Every status the processor answers is put
/// on the system's lines; one that is not 0 stops nothing where the
/// processor still answered what was asked of it.
///
/// CONTEXT:
/// - Waits: yes, for the processor - 20 ms for the ring, a few for each
///   command, at most five seconds for one.
/// - Interrupts: no.
/// - Locks: takes the security processor's lock, and the memory lock
///   inside it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The file stays the caller's; what the processor needs of it is copied.
/// The ring and the protected region are the resource's, and kept: the
/// firmware loaded into the region runs from it.
///
/// NOTES:
/// The protected region is the processor's alone once it is set up:
/// nothing on the CPU reads or writes it. Its size is the table of
/// contents' to say, and the region is as large as that, whichever of the
/// firmware it names is loaded.
///
/// A processor that did not answer in time is taken as gone: every later
/// call answers false, and the pieces it may still read are kept.
///
/// BUGS:
/// The region is not given back, nor the ring taken down, before the
/// machine restarts.
///
/// SEE ALSO:
/// `LoadGPUFirmware`, `SetGPUPower`
///
/// EXAMPLES:
/// ```zig
/// const toc = try readWhole(dos, "DEVS:firmware/amdgpu/psp_13_0_4_toc.bin");
/// if (!ab.StartGPUSecurity(toc.ptr, @intCast(toc.len))) return error.NoSecurity;
/// ```
pub fn StartGPUSecurity(ab: *AMDGPUBase, toc: [*]const u8, length: u32) bool {
    if (ab.device == null or !ab.security_known) return false;
    const sys = ab.sys_base;
    const owner = amdgpu.AMDGPUNAME;
    sys.ObtainSemaphore(&ab.security_lock);
    defer sys.ReleaseSemaphore(&ab.security_lock);
    if (ab.security_dead) return false;
    if (ab.security_ready) return true;

    const file = toc[0..length];
    const payload = _security.payloadOf(file) orelse {
        exec.kprintf(sys, "%s: the table of contents' header does not fit its file of %d bytes\n", .{ owner, length });
        return false;
    };
    const gpu: *amdgpu.AMDGPUBase = @ptrCast(&ab.lib);
    if (!ab.security_made) {
        if (ab.security_ring.bytes == 0 and !gpu.AllocGPUMemory(_security.piece_bytes, 4096, &ab.security_ring)) {
            exec.kprintf(sys, "%s: no room in the device's memory for the security processor's ring\n", .{owner});
            return false;
        }
        if (!_security.makeRing(ab)) return false;
        ab.security_made = true;
    }

    const contents = _security.staged(ab, file[payload.at..][0..payload.bytes], _security.COMMAND_LOAD_CONTENTS, &.{}) orelse return false;
    if (contents.region_bytes == 0) {
        exec.kprintf(sys, "%s: the security processor names no protected region for its table of contents\n", .{owner});
        return false;
    }

    if (ab.protected.bytes == 0) {
        const bytes = (contents.region_bytes + 4095) / 4096 * 4096;
        if (!gpu.AllocGPUMemory(bytes, _security.staging_alignment, &ab.protected)) {
            exec.kprintf(sys, "%s: no room in the device's memory for a protected region of %dK\n", .{ owner, bytes / 1024 });
            return false;
        }
    }
    const region = ab.protected;
    const at = _security.at_arguments;
    const setup = _security.submit(ab, _security.COMMAND_SETUP_REGION, &.{
        .{ .at = at, .value = @truncate(region.device) },
        .{ .at = at + 4, .value = @truncate(region.device >> 32) },
        .{ .at = at + 8, .value = region.bytes },
        .{ .at = at + 12, .value = _security.REGION_MACHINE_ADDRESS },
        .{ .at = at + 16, .value = @truncate(region.cpu) },
        .{ .at = at + 20, .value = @truncate(region.cpu >> 32) },
    }) orelse {
        ab.security_dead = true;
        return false;
    };
    exec.kprintf(sys, "%s: the protected region is %dK at 0x%lx (status %x)\n", .{ owner, region.bytes / 1024, region.device, setup.status });
    ab.security_ready = true;
    return true;
}
