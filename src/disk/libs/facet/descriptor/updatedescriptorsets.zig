// SPDX-License-Identifier: MIT
//! UpdateDescriptorSets: descriptors written into sets.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _descriptor = @import("_descriptor.zig");
const _buffer = @import("../buffer/_buffer.zig");
const _image = @import("../image/_image.zig");
const ImageView = @import("../image/_image.zig").ImageView;
const Sampler = @import("../sampler/_sampler.zig").Sampler;
const BufferView = @import("../buffer/_bufferview.zig").BufferView;

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
///   and a sampler's sampler from `image_info` - a combined image sampler
///   takes both from it - a buffer's range from `buffer_info`, one for each
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
/// buffer's range is what lies inside the buffer, which has to be bound. A
/// combined image sampler whose `sampler` is null is written with the
/// texture and no sampler, which the fixed forms that sample through one
/// paint `shader.missing` for rather than sampling some other way.
///
/// An input attachment is written from `image_info` too, and its view has
/// to be of an image made with IMAGE_USAGE_INPUT_ATTACHMENT, of a format
/// whose pixels are kept in rows; anything else leaves the descriptor
/// empty, and a fragment function then finds nothing
/// (`shader.Resources.input` answers null). What the set holds is the
/// view's rows, so the attachment is read wherever the image's memory
/// stands when the draw runs - which is what the subpass before it drew
/// (CreateRenderPass).
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The arrays are read during the call alone. What a set holds is the
/// address of each buffer's range, of each view's texture and of what each
/// sampler keeps: the buffers, the views and the samplers have to last as
/// long as the set is used.
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
            // Which of the set's offsets shifts the slot is the set's own
            // doing, not the write's: it stays as the set was made. So
            // does a sampler the set layout holds (since 1.49): a write of
            // a combined image sampler takes its image and leaves that
            // sampler, and a write of a sampler alone changes nothing.
            const dynamic = found.slot.dynamic;
            const fixed = found.slot.fixed_sampler;
            const held = found.slot.sampler;
            if (fixed and write.descriptor_type == .sampler) continue;
            found.slot.* = switch (write.descriptor_type) {
                .input_attachment => attachment: {
                    const info = (write.image_info orelse break)[k];
                    const view = _objects.of(ImageView, info.image_view orelse break :attachment .{});
                    // Rows in memory, made to be read as one: an image of
                    // another kind is left unwritten rather than handed
                    // over to be read as pixels it has not got.
                    if (view.image.kind != .rows or view.image.usage & facet.IMAGE_USAGE_INPUT_ATTACHMENT == 0) break :attachment .{};
                    if (view.rows.format == .none or view.rows.bytes == null) break :attachment .{};
                    break :attachment .{ .pointer = &view.rows, .range = @intCast(@min(view.image.bytes, 0xFFFF_FFFF)) };
                },
                .sampled_image, .combined_image_sampler, .sampler, .storage_image => sampled: {
                    const info = (write.image_info orelse break)[k];
                    // A sampler of its own has no image, and a sampled
                    // image no sampler; a combined one has both.
                    const with: ?*const facet.texture.Sampler = if (write.descriptor_type == .sampled_image or write.descriptor_type == .storage_image) null else sampler: {
                        const with_sampler = info.sampler orelse break :sampler null;
                        break :sampler &_objects.of(Sampler, with_sampler).kept;
                    };
                    if (write.descriptor_type == .sampler) break :sampled .{ .sampler = with };
                    const view = _objects.of(ImageView, info.image_view orelse break :sampled .{ .sampler = with });
                    // A texture, or a depth attachment sampled where it
                    // lies (`_image.sampledDepth`, since 1.39).
                    const kept = view.image.kind == .texture or _image.sampledDepth(view.image);
                    if (!kept or view.image.data == null) break :sampled .{ .sampler = with };
                    // A storage image is written through, so the image has
                    // to have been made for it; one that was not is left
                    // unwritten rather than handed over to be written.
                    const writable = _descriptor.written(write.descriptor_type);
                    if (writable and view.image.usage & facet.IMAGE_USAGE_STORAGE == 0) break :sampled .{};
                    // A depth texture is read, never written through.
                    if (writable and _image.sampledDepth(view.image)) break :sampled .{};
                    break :sampled .{ .pointer = &view.texels, .sampler = with, .writable = writable };
                },
                .uniform_texel_buffer, .storage_texel_buffer => texels: {
                    const views = write.texel_buffer_view orelse break;
                    const view = _objects.of(BufferView, views[k]);
                    const bytes = _buffer.bytes(view.buffer, view.offset, view.bytes) orelse break :texels .{};
                    break :texels .{
                        .pointer = bytes.ptr,
                        .range = @intCast(@min(bytes.len - bytes.len % view.texels.bytes(), 0xFFFF_FFFF)),
                        .texels = view.texels,
                        .writable = write.descriptor_type == .storage_texel_buffer,
                    };
                },
                else => bound: {
                    const info = (write.buffer_info orelse break)[k];
                    const buffer = _objects.of(_buffer.Buffer, info.buffer orelse break :bound .{});
                    const bytes = _buffer.bytes(buffer, info.offset, info.range) orelse break :bound .{};
                    break :bound .{ .pointer = bytes.ptr, .range = @intCast(@min(bytes.len, 0xFFFF_FFFF)) };
                },
            };
            found.slot.dynamic = dynamic;
            if (fixed) {
                found.slot.sampler = held;
                found.slot.fixed_sampler = true;
            }
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
            const dynamic = target.slot.dynamic;
            const fixed = target.slot.fixed_sampler;
            const held = target.slot.sampler;
            target.slot.* = source.slot.*;
            target.slot.dynamic = dynamic;
            if (fixed) {
                target.slot.sampler = held;
                target.slot.fixed_sampler = true;
            }
        }
    };
}
