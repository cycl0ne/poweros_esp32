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
///   start the video decoder; GPUFIRMWARE_DISPLAY (since 1.7), the
///   display controller's firmware.
/// - `image` - for firmware the file, whole, as it is on the disk
///   (DEVS:firmware/amdgpu/vcn_<version>.bin,
///   dcn_<version>_dmcub.bin), its vendor's header included; for the
///   writes the list itself, pairs of 32-bit words -
///   a register's offset as the block itself numbers it, then its value -
///   at most 512 pairs.
/// - `length` - its length in bytes.
/// - `address` - filled in.
///
/// RESULT:
/// True with `address` holding where the firmware is in the protected
/// region, as the device's blocks reach it - what the block's driver
/// points the block at - or, for the writes and the display controller's
/// firmware, what the processor answered as an address, 0 where it named
/// none: the processor points the display controller at its firmware
/// itself. False where `kind` is not one there is; StartGPUSecurity has not made the processor ready; the
/// file's header does not fit the file, or the list is empty, longer
/// than 512 pairs or not of whole pairs; the processor does not answer
/// within five seconds, or answers no address for firmware; the device's
/// memory has no room for the copy it reads from; and on a machine
/// without the device. `address` is then left alone.
///
/// BEHAVIOR:
/// Under the security processor's lock: the part of the file its header
/// names - for the display controller's firmware the code its header's
/// own field counts, signature and all - or the list whole, is copied
/// into a piece of its own, which the
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
    if (kind != amdgpu.GPUFIRMWARE_VIDEO and kind != amdgpu.GPUFIRMWARE_VIDEO_REGISTERS and
        kind != amdgpu.GPUFIRMWARE_DISPLAY) return false;
    const sys = ab.sys_base;
    const owner = amdgpu.AMDGPUNAME;
    sys.ObtainSemaphore(&ab.security_lock);
    defer sys.ReleaseSemaphore(&ab.security_lock);
    if (ab.security_dead or !ab.security_ready) return false;

    const file = image[0..length];
    const part = if (kind == amdgpu.GPUFIRMWARE_VIDEO_REGISTERS) writesOf(file) orelse {
        exec.kprintf(sys, "%s: a list of register writes of %d bytes is not one of whole pairs, 1 to %d of them\n", .{ owner, length, most_writes });
        return false;
    } else if (kind == amdgpu.GPUFIRMWARE_DISPLAY) displayPartOf(file) orelse {
        exec.kprintf(sys, "%s: the display controller's firmware header does not fit its file of %d bytes\n", .{ owner, length });
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
    if (kind != amdgpu.GPUFIRMWARE_VIDEO) {
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

/// Where in the display controller's firmware file its header counts the
/// code's bytes, and the header's least size with that field.
const display_code_bytes_at = 0x20;
const display_header_least = 0x28;

/// The part of the display controller's firmware file the processor is
/// given: from where the common header says the firmware starts, as many
/// bytes as its own header's code count - the code with the signature
/// before and after it, not the data that may follow. Null where the
/// headers do not fit the file.
fn displayPartOf(file: []const u8) ?[]const u8 {
    const payload = _security.payloadOf(file) orelse return null;
    const header = @as(u32, file[4]) | @as(u32, file[5]) << 8 | @as(u32, file[6]) << 16 | @as(u32, file[7]) << 24;
    if (header < display_header_least) return null;
    const at = display_code_bytes_at;
    const code = @as(u32, file[at]) | @as(u32, file[at + 1]) << 8 | @as(u32, file[at + 2]) << 16 | @as(u32, file[at + 3]) << 24;
    if (code == 0 or code > payload.bytes) return null;
    return file[payload.at..][0..code];
}

test "the display controller's part is the code its header counts" {
    const testing = @import("std").testing;
    var file = [_]u8{0} ** 0x200;
    const put = struct {
        fn f(room: []u8, at: usize, value: u32) void {
            room[at] = @truncate(value);
            room[at + 1] = @truncate(value >> 8);
            room[at + 2] = @truncate(value >> 16);
            room[at + 3] = @truncate(value >> 24);
        }
    }.f;
    put(&file, 0x00, file.len);
    put(&file, 0x04, 0x28);
    put(&file, 0x14, 0x100);
    put(&file, 0x18, 0x100);
    put(&file, 0x20, 0xc0);
    const part = displayPartOf(&file) orelse return error.NotFound;
    try testing.expectEqual(@as(usize, 0xc0), part.len);
    try testing.expectEqual(@intFromPtr(&file) + 0x100, @intFromPtr(part.ptr));
    // A count past the firmware's part, or a header without the field.
    put(&file, 0x20, 0x101);
    try testing.expect(displayPartOf(&file) == null);
    put(&file, 0x20, 0xc0);
    put(&file, 0x04, 0x20);
    try testing.expect(displayPartOf(&file) == null);
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
