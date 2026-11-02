// SPDX-License-Identifier: MIT
//! CreateDescriptorSetLayout: what a descriptor set holds.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const exec = sdk.exec;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const _descriptor = @import("_descriptor.zig");

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
/// facet.library does not have, for a binding with samplers of the
/// layout's own (`immutable_samplers`), a binding numbered past 255, or
/// more than 65535 descriptors; `error_initialization_failed` for a
/// binding given twice; `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// The kinds are sampler, combined_image_sampler, sampled_image,
/// uniform_buffer and storage_buffer. A binding not given has no
/// descriptors, and neither has one given with a count of 0. A binding's
/// descriptors are an array, read by a shader as element 0 on
/// (shader.Resources).
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
/// image sampler is for. A sampler of the layout's own is refused rather
/// than ignored, so that a program is not left thinking a write of its own
/// took: `PhysicalDeviceFeatures.immutable_samplers`. Stage flags are not
/// looked at: every stage reads every binding.
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
    for (given) |binding| {
        if (!_descriptor.known(binding.descriptor_type) or binding.binding > 255) return .error_feature_not_present;
        // A storage image is written through the texture the library keeps,
        // which a device with a layout of its own does not use.
        if (binding.descriptor_type == .storage_image and !owner.physical.features.storage_images) return .error_feature_not_present;
        if (_descriptor.ofTexels(binding.descriptor_type) and !owner.physical.features.texel_buffers) return .error_feature_not_present;
        // A sampler the layout holds, which a write could not change.
        if (binding.immutable_samplers != null and binding.descriptor_count != 0) return .error_feature_not_present;
        binding_count = @max(binding_count, binding.binding + 1);
    }
    const memory = base.sys_base.AllocVec(@sizeOf(_descriptor.SetLayout) + binding_count * @sizeOf(_descriptor.Binding), exec.MEMF_CLEAR) orelse return .error_out_of_host_memory;
    const made: *_descriptor.SetLayout = @ptrCast(@alignCast(memory));
    const bindings: [*]_descriptor.Binding = @ptrFromInt(@intFromPtr(made) + @sizeOf(_descriptor.SetLayout));
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
    made.* = .{ .device = owner, .binding_count = binding_count, .slot_count = slots };
    layout.* = _objects.handle(facet.DescriptorSetLayout, made);
    return .success;
}
