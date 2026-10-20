// SPDX-License-Identifier: MIT
//! The device's memory: its types, made from exec's regions, and a block
//! of it as AllocateMemory keeps it.
//!
//! **A heap is a set of attributes.** The regions exec has are walked in
//! the order it prefers them, and each new set of the attributes that say
//! where memory is and who reaches it - MEMF_INTERNAL, MEMF_EXTERNAL,
//! MEMF_DMA - is a heap, as large as its regions are together, with one
//! memory type of its own. Memory of a type is allocated with its heap's
//! attributes, so it comes from regions that have them all. Every type is
//! local to the device, visible to the program and coherent with it: the
//! device is the processor. After them comes one type with nothing
//! behind it, for attachments whose pixels live only in the tiles.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const ExecBase = sdk.interface.exec.ExecBase;
const Device = @import("../device/_device.zig").Device;

/// The attributes that make a heap.
const heap_attributes = exec.MEMF_INTERNAL | exec.MEMF_EXTERNAL | exec.MEMF_DMA;

/// How a block's memory is aligned: a cache line, so that an image's rows
/// start on one, and the most any buffer or image asks of its offset.
pub const alignment = 64;

/// The device's memory types and heaps, from the regions exec has now.
pub fn describe(sys: *ExecBase, into: *facet.PhysicalDeviceMemoryProperties) void {
    into.* = std.mem.zeroes(facet.PhysicalDeviceMemoryProperties);
    // The last type, the lazily allocated one, takes no heap of its own.
    const most_heaps = @min(facet.MAX_MEMORY_HEAPS, facet.MAX_MEMORY_TYPES - 1);
    var count: u32 = 0;
    if (sys.LockExecList(exec.EXECLIST_MEMORY)) |list| {
        var it = list.iterator();
        while (it.next()) |node| {
            const region: *const exec.MemHeader = @fieldParentPtr("node", node);
            const attributes = region.attributes & heap_attributes;
            const size = @intFromPtr(region.upper) - @intFromPtr(region.lower);
            const heap = for (into.memory_heaps[0..count]) |*heap| {
                if (heap.attributes == attributes) break heap;
            } else if (count < most_heaps) heap: {
                count += 1;
                into.memory_heaps[count - 1] = .{ .size = 0, .flags = facet.MEMORY_HEAP_DEVICE_LOCAL, .attributes = attributes };
                break :heap &into.memory_heaps[count - 1];
            } else continue;
            heap.size += size;
        }
        sys.UnlockExecList(exec.EXECLIST_MEMORY);
    }
    for (into.memory_heaps[0..count], into.memory_types[0..count], 0..) |heap, *memory_type, index| {
        memory_type.* = .{ .property_flags = propertiesOf(heap.attributes), .heap_index = @intCast(index) };
    }
    into.memory_types[count] = .{ .property_flags = facet.MEMORY_PROPERTY_DEVICE_LOCAL | facet.MEMORY_PROPERTY_LAZILY_ALLOCATED, .heap_index = 0 };
    into.memory_heap_count = count;
    into.memory_type_count = count + 1;
}

/// What memory with these attributes is.
fn propertiesOf(attributes: u32) u32 {
    var flags = facet.MEMORY_PROPERTY_DEVICE_LOCAL | facet.MEMORY_PROPERTY_HOST_VISIBLE | facet.MEMORY_PROPERTY_HOST_COHERENT;
    if (attributes & exec.MEMF_EXTERNAL != 0) flags |= facet.MEMORY_PROPERTY_HOST_CACHED;
    if (attributes & exec.MEMF_DMA != 0) flags |= facet.MEMORY_PROPERTY_DMA;
    return flags;
}

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
    /// What AllocMem gave and how much; null for the lazily allocated
    /// type, which has nothing behind it.
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
