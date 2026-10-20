// SPDX-License-Identifier: MIT
//! A buffer: bytes of a block of device memory, once bound into one.

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;
const Device = @import("../device/_device.zig").Device;
const _memory = @import("../memory/_memory.zig");
const DeviceMemory = _memory.DeviceMemory;

pub const Buffer = struct {
    device: *Device,
    size: u64,
    usage: u32,
    /// Where it is bound, and its first byte there.
    memory: ?*DeviceMemory = null,
    offset: u64 = 0,
    data: ?[*]u8 = null,
};

/// How a buffer's offset in its memory is aligned: enough for any value
/// a shader reads from it.
pub const alignment = 16;

/// What a buffer needs of its memory: any type with something behind it.
pub fn requirements(buffer: *const Buffer) facet.MemoryRequirements {
    return .{
        .size = std.mem.alignForward(u64, buffer.size, alignment),
        .alignment = alignment,
        .memory_type_bits = _memory.backedTypes(&buffer.device.physical.memory),
    };
}

/// The bytes of a bound buffer from `offset` on, `size` of them
/// (WHOLE_SIZE: to its end); null for a range past it, or a buffer not
/// bound.
pub fn bytes(buffer: *const Buffer, offset: u64, size: u64) ?[]u8 {
    const data = buffer.data orelse return null;
    if (offset > buffer.size) return null;
    const length = if (size == facet.WHOLE_SIZE) buffer.size - offset else size;
    if (length > buffer.size - offset) return null;
    return data[@intCast(offset)..][0..@intCast(length)];
}
