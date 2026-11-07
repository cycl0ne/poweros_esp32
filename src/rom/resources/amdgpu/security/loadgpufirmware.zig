// SPDX-License-Identifier: MPL-2.0
//! LoadGPUFirmware: a block's firmware loaded by the security processor
//! into its protected region.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _security = @import("_security.zig");

/// A block's firmware loaded by the security processor into its protected
/// region.
///
/// SYNOPSIS:
/// ```zig
/// fn LoadGPUFirmware(ab: *AMDGPUBase, kind: u32, image: [*]const u8,
///     length: u32, address: *u64) bool
/// ```
///
/// SINCE: 1.2. LVO -28.
///
/// INPUTS:
/// - `kind` - which firmware it is: GPUFIRMWARE_VIDEO, the video
///   decoder's.
/// - `image` - the firmware file, whole, as it is on the disk
///   (DEVS:firmware/amdgpu/vcn_<version>.bin), its vendor's header
///   included.
/// - `length` - the file's length in bytes.
/// - `address` - filled in.
///
/// RESULT:
/// True with `address` holding where the firmware is in the protected
/// region, as the device's blocks reach it - what the block's driver
/// points the block at. False where `kind` is not one there is;
/// StartGPUSecurity has not made the processor ready; the file's header
/// does not fit the file; the processor does not answer within five
/// seconds, or answers no address; the device's memory has no room for
/// the copy it reads from; and on a machine without the device.
/// `address` is then left alone.
///
/// BEHAVIOR:
/// Under the security processor's lock: the part of the file its header
/// names is copied into a piece of its own, which the processor reads,
/// checks and puts into the region; the piece is given back once it
/// answers. The status it answers is put on the system's lines; one that
/// is not 0 stops nothing where an address came with it.
///
/// CONTEXT:
/// - Waits: yes, for the processor - a few milliseconds, at most five
///   seconds.
/// - Interrupts: no.
/// - Locks: takes the security processor's lock, and the memory lock
///   inside it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The file stays the caller's. What the processor put into the region
/// stays there; loading the same kind again puts it there again.
///
/// NOTES:
/// The address is the firmware's start; how large a window onto it the
/// block is given is the block's driver's to work out from the file's
/// part.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartGPUSecurity`, `SetGPUPower`
///
/// EXAMPLES:
/// ```zig
/// var at: u64 = 0;
/// if (!ab.LoadGPUFirmware(amdgpu.GPUFIRMWARE_VIDEO, vcn.ptr, @intCast(vcn.len), &at))
///     return error.NoFirmware;
/// ```
pub fn LoadGPUFirmware(ab: *AMDGPUBase, kind: u32, image: [*]const u8, length: u32, address: *u64) bool {
    if (ab.device == null or !ab.security_known) return false;
    if (kind != amdgpu.GPUFIRMWARE_VIDEO) return false;
    const sys = ab.sys_base;
    const owner = amdgpu.AMDGPUNAME;
    sys.ObtainSemaphore(&ab.security_lock);
    defer sys.ReleaseSemaphore(&ab.security_lock);
    if (ab.security_dead or !ab.security_ready) return false;

    const file = image[0..length];
    const payload = _security.payloadOf(file) orelse {
        exec.kprintf(sys, "%s: the firmware's header does not fit its file of %d bytes\n", .{ owner, length });
        return false;
    };
    const response = _security.staged(ab, file[payload.at..][0..payload.bytes], _security.COMMAND_LOAD_FIRMWARE, &.{
        .{ .at = _security.at_arguments + 12, .value = kind },
    }) orelse return false;
    if (response.address == 0) {
        exec.kprintf(sys, "%s: the security processor names no address for firmware of kind %d\n", .{ owner, kind });
        return false;
    }
    address.* = response.address;
    return true;
}
