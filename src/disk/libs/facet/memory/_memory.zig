// SPDX-License-Identifier: MIT
//! A block of the device's memory as AllocateMemory keeps it, and what its
//! types say of it. The types themselves are the driver's to describe, and
//! what is behind a block the driver's to allocate.

const sdk = @import("sdk");
const facet = sdk.facet;
const Device = @import("../device/_device.zig").Device;

/// How a block's memory is aligned: a cache line, so that an image's rows
/// start on one, and the most any buffer or image asks of its offset.
pub const alignment = 64;

/// Whether memory type `index` of `properties` is the lazily allocated
/// one.
pub fn isLazy(properties: *const facet.PhysicalDeviceMemoryProperties, index: u32) bool {
    return properties.memory_types[index].property_flags & facet.MEMORY_PROPERTY_LAZILY_ALLOCATED != 0;
}

/// A block of device memory.
pub const DeviceMemory = struct {
    device: *Device,
    /// Its bytes, as asked for, and its type.
    size: u64,
    type_index: u32,
    /// What the driver allocated and how much; null for the lazily
    /// allocated type, which has nothing behind it.
    block: ?[*]u8 = null,
    block_bytes: usize = 0,
    /// Its first byte: `block` moved up to `alignment`.
    data: ?[*]u8 = null,
    /// MapMemory has handed out its address, and UnmapMemory not ended it.
    mapped: bool = false,
};

/// The memory at `offset` of a block, for what is bound there: null for a
/// lazily allocated one.
pub fn at(memory: *const DeviceMemory, offset: u64) ?[*]u8 {
    const data = memory.data orelse return null;
    return data + @as(usize, @intCast(offset));
}

/// The memory types with something behind them, as memory_type_bits.
pub fn backedTypes(properties: *const facet.PhysicalDeviceMemoryProperties) u32 {
    return allTypes(properties) & ~lazyTypes(properties);
}

/// Every memory type, as memory_type_bits.
pub fn allTypes(properties: *const facet.PhysicalDeviceMemoryProperties) u32 {
    return (@as(u32, 1) << @intCast(properties.memory_type_count)) - 1;
}

fn lazyTypes(properties: *const facet.PhysicalDeviceMemoryProperties) u32 {
    var bits: u32 = 0;
    for (properties.memory_types[0..properties.memory_type_count], 0..) |kind, index| {
        if (kind.property_flags & facet.MEMORY_PROPERTY_LAZILY_ALLOCATED != 0) bits |= @as(u32, 1) << @intCast(index);
    }
    return bits;
}

/// Whether something with `wanted` can be bound into `memory` at
/// `offset`: a type it may be in, the offset aligned, and room for it.
pub fn suits(memory: *const DeviceMemory, offset: u64, wanted: facet.MemoryRequirements) bool {
    if (wanted.memory_type_bits >> @intCast(memory.type_index) & 1 == 0) return false;
    if (offset % wanted.alignment != 0 or offset > memory.size) return false;
    return wanted.size <= memory.size - offset;
}
