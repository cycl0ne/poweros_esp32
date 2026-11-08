// SPDX-License-Identifier: MPL-2.0
//! LoadGPUFirmware: a block's firmware loaded by the security processor
//! into its protected region, or a list of a block's register writes
//! applied by it.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _security = @import("_security.zig");

/// A block's firmware loaded by the security processor into its protected
/// region, or a list of a block's register writes applied by it.
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
/// - `kind` - what it is: GPUFIRMWARE_VIDEO, the video decoder's
///   firmware; GPUFIRMWARE_VIDEO_REGISTERS (since 1.3), the writes that
///   start the video decoder.
/// - `image` - for firmware the file, whole, as it is on the disk
///   (DEVS:firmware/amdgpu/vcn_<version>.bin), its vendor's header
///   included; for the writes the list itself, pairs of 32-bit words -
///   a register's offset as the block itself numbers it, then its value -
///   at most 512 pairs.
/// - `length` - its length in bytes.
/// - `address` - filled in.
///
/// RESULT:
/// True with `address` holding where the firmware is in the protected
/// region, as the device's blocks reach it - what the block's driver
/// points the block at - or, for the writes, what the processor answered
/// as an address, 0 where it named none. False where `kind` is not one
/// there is; StartGPUSecurity has not made the processor ready; the
/// file's header does not fit the file, or the list is empty, longer
/// than 512 pairs or not of whole pairs; the processor does not answer
/// within five seconds, or answers no address for firmware; the device's
/// memory has no room for the copy it reads from; and on a machine
/// without the device. `address` is then left alone.
///
/// BEHAVIOR:
/// Under the security processor's lock: the part of the file its header
/// names, or the list whole, is copied into a piece of its own, which the
/// processor reads - firmware it checks and puts into the region, writes
/// it applies to the block in their order. The piece is given back once
/// it answers. The status it answers is put on the
/// system's lines; one that is not 0 stops nothing where an address came
/// with firmware.
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
/// The file or list stays the caller's. What the processor put into the
/// region stays there; loading the same kind again puts it there again.
///
/// NOTES:
/// The address is the firmware's start; how large a window onto it the
/// block is given is the block's driver's to work out from the file's
/// part. The writes are the block's start as its driver puts it together;
/// the processor checks the firmware, not them.
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
/// // The decoder's processor out of reset: its control register, 0xd6
/// // inside the block.
/// const writes = [_]u32{ 0xd6, 0x0ff00200 };
/// _ = ab.LoadGPUFirmware(amdgpu.GPUFIRMWARE_VIDEO_REGISTERS, @ptrCast(&writes), 8, &at);
/// ```
pub fn LoadGPUFirmware(ab: *AMDGPUBase, kind: u32, image: [*]const u8, length: u32, address: *u64) bool {
    if (ab.device == null or !ab.security_known) return false;
    if (kind != amdgpu.GPUFIRMWARE_VIDEO and kind != amdgpu.GPUFIRMWARE_VIDEO_REGISTERS) return false;
    const sys = ab.sys_base;
    const owner = amdgpu.AMDGPUNAME;
    sys.ObtainSemaphore(&ab.security_lock);
    defer sys.ReleaseSemaphore(&ab.security_lock);
    if (ab.security_dead or !ab.security_ready) return false;

    const file = image[0..length];
    const part = if (kind == amdgpu.GPUFIRMWARE_VIDEO_REGISTERS) writesOf(file) orelse {
        exec.kprintf(sys, "%s: a list of register writes of %d bytes is not one of whole pairs, 1 to %d of them\n", .{ owner, length, most_writes });
        return false;
    } else blk: {
        const payload = _security.payloadOf(file) orelse {
            exec.kprintf(sys, "%s: the firmware's header does not fit its file of %d bytes\n", .{ owner, length });
            return false;
        };
        break :blk file[payload.at..][0..payload.bytes];
    };
    const response = _security.staged(ab, part, _security.COMMAND_LOAD_FIRMWARE, &.{
        .{ .at = _security.at_arguments + 12, .value = kind },
    }) orelse return false;
    if (kind == amdgpu.GPUFIRMWARE_VIDEO_REGISTERS) {
        address.* = response.address;
        return true;
    }
    if (response.address == 0) {
        exec.kprintf(sys, "%s: the security processor names no address for firmware of kind %d\n", .{ owner, kind });
        return false;
    }
    address.* = response.address;
    return true;
}

/// The most register writes a list holds.
const most_writes = 512;

/// `file` as a list of register writes: whole pairs of words, at least
/// one and at most `most_writes`. Null otherwise.
fn writesOf(file: []const u8) ?[]const u8 {
    if (file.len == 0 or file.len % 8 != 0 or file.len / 8 > most_writes) return null;
    return file;
}

test "a list of register writes is whole pairs, and not too many" {
    const testing = @import("std").testing;
    const room = [_]u8{0} ** (most_writes * 8 + 8);
    try testing.expect(writesOf(room[0..8]) != null);
    try testing.expect(writesOf(room[0 .. most_writes * 8]) != null);
    try testing.expect(writesOf(room[0..0]) == null);
    try testing.expect(writesOf(room[0..12]) == null);
    try testing.expect(writesOf(room[0 .. most_writes * 8 + 8]) == null);
}
