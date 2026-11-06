// SPDX-License-Identifier: MIT
//! CreateDescriptorSetLayout: what a descriptor set holds.

const sdk = @import("sdk");
const facet = sdk.facet;
const shader = facet.shader;
const texture = facet.texture;
const FacetBase = @import("../facet_base.zig").FacetBase;
const exec = sdk.exec;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const _descriptor = @import("_descriptor.zig");
const Sampler = @import("../sampler/_sampler.zig").Sampler;

/// A descriptor set layout: a set's bindings, each of a kind, with its descriptors.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateDescriptorSetLayout(base: *FacetBase, device: *facet.Device, info: *const facet.DescriptorSetLayoutCreateInfo, layout: *?*facet.DescriptorSetLayout) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -228.
///
/// INPUTS:
/// - `device` - the device.
/// - `info` - the bindings, in any order.
/// - `layout` - where the layout is written; null when it fails.
///
/// RESULT:
/// `success`; `error_feature_not_present` for a kind of descriptor
/// facet.library does not have, for samplers of the layout's own on a
/// device without `Capabilities.immutable_samplers`, a binding
/// numbered past 255, or more than 65535 descriptors;
/// `error_initialization_failed` for a binding given twice;
/// `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// The kinds are sampler, combined_image_sampler, sampled_image,
/// storage_image, uniform_buffer, storage_buffer, uniform_texel_buffer,
/// storage_texel_buffer, uniform_buffer_dynamic, storage_buffer_dynamic
/// and, since 1.37, input_attachment: all eleven of Vulkan's. A binding
/// not given has no descriptors, and neither has one given with a count
/// of 0. A binding's descriptors are an array, read by a shader as
/// element 0 on (shader.Resources).
///
/// Some kinds want a device that has them, others answering
/// `error_feature_not_present`: a storage image `storage_images`, a texel
/// buffer `texel_buffers`, a dynamic buffer `dynamic_descriptors` (and no
/// more of them in one set than
/// `PhysicalDeviceLimits.max_descriptor_set_dynamic_buffers`), and an
/// input attachment `input_attachments` - the cores, not the V3D, whose
/// fragment functions are of fixed forms and read none.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The layout is the caller's, until DestroyDescriptorSetLayout. The
/// bindings are read during the call alone.
///
/// NOTES:
/// A fragment function of a fixed form samples either as it was compiled
/// to (sdk.facet.shader.textured) or through the sampler bound beside the
/// texture (shader.FixedKind.texture_sampled), which is what a combined
/// image sampler is for. Stage flags are not looked at: every stage reads
/// every binding.
///
/// **A sampler of the layout's own** is taken since 1.49
/// (`immutable_samplers`, `Capabilities.immutable_samplers`): on
/// a `sampler` or `combined_image_sampler` binding the layout holds one
/// sampler for each of the binding's descriptors, and every set made of
/// the layout starts with them in its slots. A write of a combined image
/// sampler into such a binding brings the texture and leaves the sampler;
/// a write of a sampler alone changes nothing. The samplers have to last
/// as long as the sets do, as a written one does. On a binding of another
/// kind the pointer is passed over, as Vulkan passes it over.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreatePipelineLayout`, `AllocateDescriptorSets`, `UpdateDescriptorSets`
///
/// EXAMPLES:
/// ```zig
/// const binding = facet.DescriptorSetLayoutBinding{ .binding = 0, .descriptor_type = .sampled_image, .stage_flags = facet.SHADER_STAGE_FRAGMENT };
/// var set_layout: ?*facet.DescriptorSetLayout = null;
/// _ = fb.CreateDescriptorSetLayout(device, &.{ .binding_count = 1, .bindings = @ptrCast(&binding) }, &set_layout);
/// ```
pub fn CreateDescriptorSetLayout(base: *FacetBase, device: *facet.Device, info: *const facet.DescriptorSetLayoutCreateInfo, layout: *?*facet.DescriptorSetLayout) facet.Result {
    layout.* = null;
    const owner = _objects.of(Device, device);
    const given: []const facet.DescriptorSetLayoutBinding = if (info.bindings) |bindings| bindings[0..info.binding_count] else &.{};
    var binding_count: u32 = 0;
    var dynamic: u32 = 0;
    // Whether any binding holds a sampler of the layout's own, and the
    // slots they all take: the layout keeps one for each of its slots.
    var holds_samplers = false;
    var held_slots: u32 = 0;
    for (given) |binding| {
        if (!_descriptor.known(binding.descriptor_type) or binding.binding > 255) return .error_feature_not_present;
        // A storage image is written through the texture the library keeps,
        // which a device with a layout of its own does not use.
        if (binding.descriptor_type == .storage_image and !owner.physical.can.storage_images) return .error_feature_not_present;
        if (_descriptor.ofTexels(binding.descriptor_type) and !owner.physical.can.texel_buffers) return .error_feature_not_present;
        if (_descriptor.ofDynamic(binding.descriptor_type) and !owner.physical.can.dynamic_descriptors) return .error_feature_not_present;
        // An input attachment is read by a fragment function of the
        // program's, which a device with programs of its own has not got.
        if (binding.descriptor_type == .input_attachment and !owner.physical.can.input_attachments) return .error_feature_not_present;
        // A sampler the layout holds, which a write cannot change (since
        // 1.49): for a kind that carries one, and on a device that keeps
        // them.
        if (binding.immutable_samplers != null and binding.descriptor_count != 0 and _descriptor.ofSampler(binding.descriptor_type)) {
            if (!owner.physical.can.immutable_samplers) return .error_feature_not_present;
            holds_samplers = true;
            held_slots += @min(binding.descriptor_count, 0xFFFF);
        }
        binding_count = @max(binding_count, binding.binding + 1);
        // Each dynamic buffer descriptor takes one of the set's offsets,
        // and there are only so many of those.
        if (_descriptor.ofDynamic(binding.descriptor_type)) {
            dynamic += binding.descriptor_count;
            if (dynamic > shader.MAX_DYNAMIC_OFFSETS) return .error_feature_not_present;
        }
    }
    const bindings_bytes = binding_count * @sizeOf(_descriptor.Binding);
    const samplers_bytes = if (holds_samplers) held_slots * @sizeOf(?*const texture.Sampler) else 0;
    const memory = base.sys_base.AllocVec(@sizeOf(_descriptor.SetLayout) + bindings_bytes + samplers_bytes, exec.MEMF_CLEAR) orelse return .error_out_of_host_memory;
    const made: *_descriptor.SetLayout = @ptrCast(@alignCast(memory));
    const bindings: [*]_descriptor.Binding = @ptrFromInt(@intFromPtr(made) + @sizeOf(_descriptor.SetLayout));
    const samplers: [*]?*const texture.Sampler = @ptrFromInt(@intFromPtr(bindings) + bindings_bytes);
    for (bindings[0..binding_count]) |*binding| binding.* = .{ .kind = .sampled_image, .first = 0, .count = 0 };
    var named: [256]bool = @splat(false);
    for (given) |binding| {
        if (named[binding.binding]) {
            base.sys_base.FreeVec(memory);
            return .error_initialization_failed;
        }
        named[binding.binding] = true;
        bindings[binding.binding].kind = binding.descriptor_type;
        bindings[binding.binding].count = @intCast(@min(binding.descriptor_count, 0xFFFF));
    }
    // The slots in the bindings' order.
    var slots: u32 = 0;
    for (bindings[0..binding_count]) |*binding| {
        binding.first = @intCast(@min(slots, 0xFFFF));
        slots += binding.count;
    }
    if (slots > 0xFFFF) {
        base.sys_base.FreeVec(memory);
        return .error_feature_not_present;
    }
    // The samplers the layout holds, each in its slot's place: a set made
    // of this layout starts with them, and a write leaves them be.
    if (holds_samplers) {
        for (samplers[0..held_slots]) |*each| each.* = null;
        for (given) |binding| {
            const kept = binding.immutable_samplers orelse continue;
            if (binding.descriptor_count == 0 or !_descriptor.ofSampler(binding.descriptor_type)) continue;
            const place = bindings[binding.binding];
            for (0..place.count) |element| {
                if (place.first + element >= held_slots) break;
                samplers[place.first + element] = &_objects.of(Sampler, kept[element]).kept;
            }
        }
    }
    made.* = .{ .device = owner, .binding_count = binding_count, .slot_count = slots, .holds_samplers = holds_samplers };
    layout.* = _objects.handle(facet.DescriptorSetLayout, made);
    return .success;
}
