// SPDX-License-Identifier: MIT
//! UpdateDescriptorSets: descriptors written into sets.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _descriptor = @import("_descriptor.zig");
const _buffer = @import("../buffer/_buffer.zig");
const ImageView = @import("../image/_image.zig").ImageView;

/// Descriptors written into sets, and copied from one set to another.
///
/// SYNOPSIS:
/// ```zig
/// fn UpdateDescriptorSets(base: *FacetBase, device: *facet.Device, write_count: u32, writes: ?[*]const facet.WriteDescriptorSet, copy_count: u32, copies: ?[*]const facet.CopyDescriptorSet) void
/// ```
///
/// SINCE: 1.0. LVO -264.
///
/// INPUTS:
/// - `device` - the device.
/// - `write_count`, `writes` - descriptors written: a sampled image's view
///   from `image_info`, a buffer's range from `buffer_info`, one for each
///   descriptor.
/// - `copy_count`, `copies` - descriptors copied, after the writes.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A write or a copy of more descriptors than are left in its binding runs
/// on into the bindings after it. A descriptor of another kind than the
/// binding's, or past the set's last, is passed over.
///
/// A sampled image's view has to be of an image made to be sampled; a
/// buffer's range is what lies inside the buffer, which has to be bound.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The arrays are read during the call alone. What a set holds is the
/// address of each buffer's range and of each view's texture: the buffers
/// and views have to last as long as the set is used.
///
/// NOTES:
/// A set is read as the draws that bound it run: written before the
/// command buffer is submitted, it is drawn with as written then. It may
/// not be written while a command buffer that bound it is pending.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AllocateDescriptorSets`, `CmdBindDescriptorSets`
///
/// EXAMPLES:
/// ```zig
/// const image = facet.DescriptorImageInfo{ .image_view = view };
/// const write = facet.WriteDescriptorSet{ .dst_set = set.?, .dst_binding = 0, .descriptor_type = .sampled_image, .image_info = @ptrCast(&image) };
/// fb.UpdateDescriptorSets(device, 1, @ptrCast(&write), 0, null);
/// ```
pub fn UpdateDescriptorSets(base: *FacetBase, device: *facet.Device, write_count: u32, writes: ?[*]const facet.WriteDescriptorSet, copy_count: u32, copies: ?[*]const facet.CopyDescriptorSet) void {
    _ = device;
    _ = base;
    if (writes) |given| for (given[0..write_count]) |write| {
        const set = _objects.of(_descriptor.Set, write.dst_set);
        for (0..write.descriptor_count) |k| {
            const found = _descriptor.slotAt(set, write.dst_binding, write.dst_array_element + @as(u32, @intCast(k))) orelse break;
            if (found.kind != write.descriptor_type) continue;
            found.slot.* = switch (write.descriptor_type) {
                .sampled_image => sampled: {
                    const info = (write.image_info orelse break)[k];
                    const view = _objects.of(ImageView, info.image_view orelse break :sampled .{});
                    if (view.image.kind != .texture or view.image.data == null) break :sampled .{};
                    break :sampled .{ .pointer = &view.texels };
                },
                else => bound: {
                    const info = (write.buffer_info orelse break)[k];
                    const buffer = _objects.of(_buffer.Buffer, info.buffer orelse break :bound .{});
                    const bytes = _buffer.bytes(buffer, info.offset, info.range) orelse break :bound .{};
                    break :bound .{ .pointer = bytes.ptr, .range = @intCast(@min(bytes.len, 0xFFFF_FFFF)) };
                },
            };
        }
    };
    if (copies) |given| for (given[0..copy_count]) |copy| {
        const from = _objects.of(_descriptor.Set, copy.src_set);
        const into = _objects.of(_descriptor.Set, copy.dst_set);
        for (0..copy.descriptor_count) |k| {
            const step: u32 = @intCast(k);
            const source = _descriptor.slotAt(from, copy.src_binding, copy.src_array_element + step) orelse break;
            const target = _descriptor.slotAt(into, copy.dst_binding, copy.dst_array_element + step) orelse break;
            if (source.kind != target.kind) continue;
            target.slot.* = source.slot.*;
        }
    };
}
